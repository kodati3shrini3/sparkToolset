#!/bin/bash
# Set the cluster login file explicitly (launchers do not load ~/.bashrc)
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
# Labels that identify a vLLM model server (the Helm chart puts them on every model deployment and service)
VLLM_SEL="app.kubernetes.io/part-of=vllm-stack,app.kubernetes.io/component=serving-engine"
# Lock file shared by all icons, and the phase file written by the Stop Kubernetes script (both cleared at reboot)
LOCK="${XDG_RUNTIME_DIR:-/tmp}/vllm-action.lock"
STATUS="${XDG_RUNTIME_DIR:-/tmp}/k8s-stop.status"
# Folder where the real duration of the last successful actions is remembered
HIST="$HOME/.local/state/k8s-vllm-icons"

# say "text": show an information message (dialog box if zenity exists, otherwise in this window); the title comes from $TITLE
say() {
  if command -v zenity >/dev/null 2>&1; then zenity --info --title="${TITLE:-vLLM}" --width=460 --text="$1" 2>/dev/null
  else echo; echo "$1"; read -p "Press Enter to close"; fi
}

# ask_ok "text": show an OK / Cancel question; returns success only if the user presses OK
ask_ok() {
  if command -v zenity >/dev/null 2>&1; then zenity --question --title="${TITLE:-vLLM}" --width=520 --ok-label="OK" --cancel-label="Cancel" --text="$1" 2>/dev/null
  else echo; echo "$1"; read -p "Type OK and press Enter to continue (anything else cancels): " ANS; [ "$ANS" = "OK" ]; fi
}

# kc: kubectl with a short timeout and no error text, so the live view never hangs when the cluster is down
kc() { kubectl --request-timeout=3s "$@" 2>/dev/null; }
# fmt_s SECONDS: format seconds as M:SS
fmt_s() { printf '%d:%02d' $(($1/60)) $(($1%60)); }
# record_duration "action" START_EPOCH: remember how long a successful action really took
record_duration() { [ -n "$2" ] || return 0; mkdir -p "$HIST"; echo $(( $(date +%s) - $2 )) > "$HIST/$(echo "$1" | tr ' ' '_')"; }
# last_duration "action": print the remembered real duration as M:SS (nothing if there is none yet)
last_duration() { local f="$HIST/$(echo "$1" | tr ' ' '_')"; [ -r "$f" ] && fmt_s "$(cat "$f")"; }

# list_models: one line per installed vLLM model: "namespace deployment wanted-pods ready-pods" (the namespace is the model name)
list_models() { kubectl --request-timeout=5s get deployment -A -l "$VLLM_SEL" -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name} {.spec.replicas} {.status.readyReplicas}{"\n"}{end}' 2>/dev/null; }
# running_models: namespaces of the models that are running or starting (wanted pods is 1 or more)
running_models() { list_models | awk '$3>=1{print $1}'; }
# use_model NAMESPACE: set NS, DEP, LABEL and SVC for that model by looking them up in the cluster
use_model() {
  NS="$1"
  DEP=$(kubectl --request-timeout=5s get deployment -n "$NS" -l "$VLLM_SEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  INST=$(kubectl --request-timeout=5s get deployment -n "$NS" -l "$VLLM_SEL" -o jsonpath='{.items[0].metadata.labels.app\.kubernetes\.io/instance}' 2>/dev/null)
  LABEL="app.kubernetes.io/instance=$INST"
  SVC=$(kubectl --request-timeout=5s get service -n "$NS" -l "$VLLM_SEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
}
# lock_model NAMESPACE: write the chosen model into the lock file, so a second click can show that model's live status
lock_model() { IFS='|' read -r LA LS _ < "$LOCK"; truncate -s 0 "$LOCK"; echo "$LA|$LS|$1" >&9; }
# pods_left: how many pods of the current model still exist, including ones that are closing (the GPU is only free when this is 0)
pods_left() { kubectl --request-timeout=5s get pods -n "$NS" -l "$LABEL" --no-headers 2>/dev/null | wc -l; }
# stop_model NAMESPACE: ask for 0 pods of that model and wait until every pod is really gone (up to 3 minutes)
stop_model() {
  use_model "$1"
  echo "  Stopping $NS"
  kubectl scale deployment/$DEP -n $NS --replicas=0 || return 1
  local i L
  for i in $(seq 1 60); do
    L=$(pods_left); printf '  [%s] %s pods left: %s\n' "$(date +%H:%M:%S)" "$NS" "$L"
    [ "$L" = "0" ] && return 0
    sleep 3
  done
  return 1
}
# pick_model: let the user choose a model; prints the namespace; fails if nothing is installed or the user cancels
pick_model() {
  local ROWS COUNT; ROWS=$(list_models); COUNT=$(echo "$ROWS" | grep -c .)
  # Nothing installed
  [ "$COUNT" = "0" ] && return 1
  # Only one model installed: no question needed
  [ "$COUNT" = "1" ] && { echo "$ROWS" | awk '{print $1}'; return 0; }
  # Several models: build the list with the state of each
  local ARGS=() N D R K ST
  while read -r N D R K; do
    if [ "${R:-0}" -ge 1 ]; then ST="running"; [ "${K:-0}" -ge 1 ] || ST="starting"; else ST="stopped"; fi
    ARGS+=("$N" "$ST")
  done <<< "$ROWS"
  if command -v zenity >/dev/null 2>&1; then
    # Dialog with the list; the selected model name is printed
    zenity --list --title="${TITLE:-vLLM}" --width=480 --height=320 --text="Which model do you want to start?\n\nOnly one model can run at a time (one GPU).\nA model that is running now is stopped first." --column="Model" --column="State" "${ARGS[@]}" 2>/dev/null
  else
    # No dialog tool: numbered list in this window
    local i=0 C; echo "Which model do you want to start?" >&2
    while read -r N _; do i=$((i+1)); echo "  $i) $N" >&2; done <<< "$ROWS"
    read -p "Number: " C; echo "$ROWS" | sed -n "${C}p" | awk '{print $1}'
  fi
}

# live_status "action" START_EPOCH: print the REAL state of the action that is running now
live_status() {
  local A="$1" S="$2" NOW; NOW=$(date +%s)
  echo "  Running for: $(fmt_s $((NOW-S)))"
  case "$A" in
    "Stop Kubernetes")
      # Phase written by the Stop script
      if [ -r "$STATUS" ]; then IFS='|' read -r PH TXT PS < "$STATUS"; echo "  Phase $PH: $TXT (for $(fmt_s $((NOW-PS))))"; fi
      # k3s service state and k3s containers still alive
      echo "  k3s service: $(systemctl is-active k3s)   k3s containers still alive: $(pgrep -fc 'run/k3s/containerd' || true)"
      # Pods still on this node (DaemonSet helpers excluded) with the seconds until Kubernetes force-ends each closing pod
      local J; J=$(kc get pods -A --field-selector spec.nodeName="$(hostname)" -o json)
      if [ -n "$J" ]; then
        echo "  Pods still on the node (helper pods excluded):"
        echo "$J" | jq -r --argjson now "$NOW" '
          [ .items[]
            | select(([.metadata.ownerReferences[]?.kind] | index("DaemonSet")) | not)
            | select(.status.phase == "Running" or .status.phase == "Pending")
          ] as $p
          | if ($p | length) == 0 then "    none"
            else $p[] | "    \(.metadata.namespace)/\(.metadata.name)  " +
                 (if .metadata.deletionTimestamp then
                    "closing - Kubernetes force-ends it in " + ((((.metadata.deletionTimestamp | fromdateiso8601) - $now) | if . < 0 then 0 else . end) | floor | tostring) + " s"
                  else "still running" end)
            end'
      else echo "  (the cluster no longer answers - it is going down)"; fi ;;
    "Start Kubernetes")
      # k3s service, node state and pod counts
      echo "  k3s service: $(systemctl is-active k3s)"
      echo "  Node: $(kc get nodes --no-headers | awk '{print $1" "$2}')"
      echo "  Pods running: $(kc get pods -A --no-headers | grep -c Running)   not ready yet: $(kc get pods -A --no-headers | grep -v -E 'Running|Completed' | wc -l)" ;;
    "Start vLLM")
      # Newest pod of the chosen model, its state and its last log line (NS and LABEL were set by use_model)
      if [ -n "$NS" ]; then
        local P; P=$(kc get pods -n $NS -l $LABEL --sort-by=.metadata.creationTimestamp -o name | tail -n 1)
        echo "  Model: $NS"
        echo "  vLLM ready replicas: $(ready)   newest pod: $(kc get $P -n $NS --no-headers | awk '{print $2" "$3}')"
        echo "  Last log line: $(kc logs $P -n $NS --tail=1 | cut -c1-90)"
      else echo "  (waiting for a model to be chosen)"; fi ;;
    "Stop vLLM")
      # Pods still existing for the model being stopped
      [ -n "$NS" ] && echo "  Model: $NS   vLLM pods left: $(pods_left)" || echo "  (waiting for confirmation)" ;;
  esac
}

# wait_for_other: shown when a second click arrives while another action runs; shows its live status until it has finished
wait_for_other() {
  # Read "action|start time|model" written by the action that holds the lock
  IFS='|' read -r A S M < "$LOCK"
  A=${A:-another action}; S=${S:-$(date +%s)}
  while true; do
    # If the lock can be taken, the other action has finished
    if flock -n 9; then printf '\033[H\033[J'; echo "=== $A has finished. You can click again now. ==="; break; fi
    # Re-read the lock file (the model name appears once it has been chosen) and look up that model
    IFS='|' read -r _ _ M < "$LOCK"; NS=""; [ -n "$M" ] && use_model "$M"
    # Redraw the window: heading, live status, comparison with the last real duration
    printf '\033[H\033[J'
    echo "=== $A is already in progress (started $(date -d @"$S" +%H:%M:%S)) ==="
    echo "This click changed nothing. Live status of the running action (refreshed every 2 s):"
    echo
    live_status "$A" "$S"
    L=$(last_duration "$A"); [ -n "$L" ] && { echo; echo "  For comparison, the last time this really took: $L"; }
    echo; echo "This window closes by itself when the action has finished."
    sleep 2
  done
  # Leave the final message visible for a moment
  sleep 5
}

# take_lock "name": allow only one action at a time; a second click gets the live status window (a second argument is accepted and ignored)
take_lock() {
  # Open the lock file for appending (appending does not wipe the info of the running action)
  exec 9>>"$LOCK"
  # If another action holds the lock, show its live status and leave
  if ! flock -n 9; then wait_for_other; exit 1; fi
  # Record the action name and the start time
  truncate -s 0 "$LOCK"; echo "$1|$(date +%s)" >&9
}

# desired: how many pods of the current model are requested right now (1 = start requested, 0 = stop requested)
desired() { kubectl get deployment/$DEP -n $NS -o jsonpath='{.spec.replicas}' 2>/dev/null; }
# ready: how many pods of the current model are ready right now (empty means 0)
ready() { kubectl get deployment/$DEP -n $NS -o jsonpath='{.status.readyReplicas}' 2>/dev/null; }
# busy: "running waiting" request counts of the current model from the vLLM metrics, or "unknown unknown" if not readable
busy() {
  IP=$(kubectl get svc $SVC -n $NS -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
  curl -s -m 3 "http://$IP/metrics" 2>/dev/null | awk '/^vllm:num_requests_running/{r=$NF} /^vllm:num_requests_waiting/{w=$NF} END{print (r==""?"unknown":r), (w==""?"unknown":w)}'
}

# need_k8s start|stop: check that Kubernetes is usable; otherwise show a clear message and leave
need_k8s() {
  # Case 1: the k3s service is not running at all
  if ! systemctl is-active --quiet k3s; then
    if [ "$1" = "stop" ]; then say "Kubernetes is not running, so vLLM is already stopped.\n\nNothing to do."; exit 0; fi
    say "KUBERNETES IS NOT RUNNING.\n\nvLLM runs inside Kubernetes, so it cannot start now.\n\nDO THIS FIRST:\n  1. Click the blue 'Start Kubernetes' icon\n  2. Wait until its window closes ('Kubernetes is up')\n  3. Then click 'Start vLLM' again"; exit 1
  fi
  # Case 2: k3s is running but the cluster does not answer yet (still starting)
  if [ -z "$(kubectl get nodes -o name 2>/dev/null)" ]; then
    say "Kubernetes is still STARTING (the cluster does not answer yet).\n\nPlease wait 1-2 minutes and click again."; exit 1
  fi
  # Case 3: the node is paused (closed for new pods), for example after an interrupted Stop Kubernetes
  if [ "$1" = "start" ] && [ "$(kubectl get nodes -o jsonpath='{.items[0].spec.unschedulable}' 2>/dev/null)" = "true" ]; then
    say "Kubernetes is PAUSED (closed for new pods).\n\nClick the blue 'Start Kubernetes' icon to reopen it, then click 'Start vLLM' again."; exit 1
  fi
}

# ===== Multi-model support (Step 107, 2026-11-06): new functions only, the functions above are unchanged =====

# slots_offered: number of GPU slots the cluster offers (2 or more means time-slicing is on); prints 1 when it cannot be read, which keeps the old one-model behaviour
slots_offered() {
  local N   # the number read from the node
  N=$(kubectl --request-timeout=5s get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null)   # allocatable GPU count of the node
  [[ "$N" =~ ^[0-9]+$ ]] && echo "$N" || echo 1   # a plain number is used, anything else counts as 1 slot
}

# mem_available: memory that programs can still use, in GiB (the "available" column of free, not the "free" column)
mem_available() { free -g | awk '/^Mem:/{print $7}'; }

# model_state WANTED READY: print running, starting or stopped for one model (the numbers come from list_models)
model_state() {
  if [ "${1:-0}" -ge 1 ]; then   # at least one pod is wanted
    [ "${2:-0}" -ge 1 ] && echo running || echo starting   # ready pods mean running, otherwise it is still loading
  else echo stopped; fi   # no pod wanted
}

# model_mem NAMESPACE: print the vLLM memory setting of that model, for example 0.3 (nothing if unreadable); read from its deployment, so it also works while the model is stopped
model_mem() {
  kubectl --request-timeout=5s get deployment -n "$1" -l "$VLLM_SEL" -o json 2>/dev/null \
    | jq -r '.items[0].spec.template.spec.containers[0] | ((.command // []) + (.args // [])) | join(" ")' 2>/dev/null \
    | grep -oiE 'gpu[-_]memory[-_]utilization[= ]+"?[0-9.]+' | grep -oE '[0-9.]+$' | head -n 1   # only the number is kept, the rest of the command is never printed
}

# pick_models start|stop: checklist of the installed models (rows come from the cluster, so the count is always correct); prints the ticked namespaces one per line; fails when nothing is installed, nothing is ticked or the user cancels
pick_models() {
  local MODE="$1" ROWS COUNT SLOTS TXT OUT RC C x   # MODE is start or stop
  ROWS=$(list_models); COUNT=$(echo "$ROWS" | grep -c .)   # one row per installed model, read from the cluster now
  [ "$COUNT" = "0" ] && return 1   # nothing installed
  SLOTS=$(slots_offered)   # GPU slots offered now
  local ARGS=() NAMES=() N D R K ST TICK   # ARGS feeds the dialog, NAMES feeds the numbered fallback
  while read -r N D R K; do   # one model at a time
    ST=$(model_state "$R" "$K")   # running, starting or stopped
    if [ "$MODE" = "stop" ]; then   # Stop mode
      [ "$ST" = "stopped" ] && continue   # a stopped model cannot be stopped, so it is not offered
      TICK=TRUE   # every running model is pre-ticked
    else TICK=FALSE; fi   # Start mode: nothing is pre-ticked
    ARGS+=("$TICK" "$N" "$ST"); NAMES+=("$N")   # remember this row
  done <<< "$ROWS"
  [ "${#NAMES[@]}" -gt 0 ] || return 1   # nothing to offer
  if [ "$MODE" = "stop" ]; then TXT="Which models do you want to stop?\n\nTick the models to stop. The others keep running."   # question for Stop
  else TXT="$COUNT models installed, $SLOTS GPU slots offered.\n\nTick the models to start. They start one after another.\nA model that is already running is left alone."; fi   # question for Start, with the live numbers
  if command -v zenity >/dev/null 2>&1; then   # dialog available
    OUT=$(zenity --list --checklist --title="${TITLE:-vLLM}" --width=$(dialog_width "${NAMES[@]}") --height=$(dialog_height "${#NAMES[@]}") --text="$TXT" --column="Pick" --column="Model" --column="State" --separator=" " "${ARGS[@]}" 2>/dev/null); RC=$?   # the ticked names come back on one line
    [ "$RC" = "0" ] && [ -n "$OUT" ] && echo "$OUT" | tr ' ' '\n'   # one name per line; fails when cancelled or nothing ticked
  else   # no dialog tool: numbered list in this window
    printf '%b\n' "$TXT" >&2   # shows the question
    for x in "${!NAMES[@]}"; do echo "  $((x+1))) ${NAMES[$x]}" >&2; done   # numbered list
    read -p "Numbers separated by spaces (for example 1 2): " C   # reads the choice
    for x in $C; do [[ "$x" =~ ^[0-9]+$ ]] && [ "$x" -ge 1 ] && [ "$x" -le "${#NAMES[@]}" ] && echo "${NAMES[$((x-1))]}"; done | awk '!seen[$0]++' | grep .   # valid numbers only, no duplicates; fails when nothing valid was typed
  fi
}

# warn_resources NAMESPACE...: OK-only warning for the models that will run at the same time; nothing is stopped and the script continues afterwards
warn_resources() {
  local SLOTS TOT AVAIL N F EST TXT="" CNT=0 EXTRA=""   # live values and the text being built
  SLOTS=$(slots_offered); TOT=$(free -g | awk '/^Mem:/{print $2}'); AVAIL=$(mem_available)   # slots, total memory and available memory now
  for N in "$@"; do   # one line per model that will run
    CNT=$((CNT+1)); F=$(model_mem "$N")   # count it and read its memory setting
    if [ -n "$F" ]; then EST=$(awk -v f="$F" -v t="$TOT" 'BEGIN{printf "%.0f", f*t}'); TXT+="  - $N: memory setting $F, reserves about $EST GiB of $TOT GiB (estimate)"$'\n'   # setting times total memory
    else TXT+="  - $N: memory need unknown"$'\n'; fi   # setting not readable
  done
  [ "$CNT" -gt "$SLOTS" ] && EXTRA="WARNING: $CNT models but only $SLOTS GPU slots. The extra models stay Pending (waiting) until a slot is free.\n\n"   # more models than slots
  MSG="SEVERAL MODELS WILL RUN AT THE SAME TIME.\n\nGPU slots offered: $SLOTS\nModels that will run:\n$TXT\nMemory available now: $AVAIL GiB of $TOT GiB (CPU and GPU share it)\n\n${EXTRA}Limits:\n  - No memory isolation between the models: if memory runs out, the model that asks last fails.\n  - Ollama models in Docker use the same memory.\n\nNothing is stopped. Press OK to continue."   # the warning text (one OK button, no Cancel)
  if command -v zenity >/dev/null 2>&1; then zenity --info --title="${TITLE:-vLLM}" --width=$(dialog_width "$@") --text="$MSG" 2>/dev/null   # dialog whose width follows the model names and whose height is automatic
  else say "$MSG"; fi   # no dialog tool: same text through the old helper
}

# start_model_wait NAMESPACE: start that model (1 pod) and wait until it is ready (up to 15 minutes); returns 0 when ready, 1 when the start failed or timed out
start_model_wait() {
  use_model "$1"; lock_model "$1"   # look up the model and show it in the live status of a second click
  echo "=== Starting vLLM: $NS (the model loads from disk) ==="   # window heading
  notify-send "vLLM" "Starting $NS..."   # pop-up so you know the click was received
  kubectl scale deployment/$DEP -n $NS --replicas=1 || return 1   # ask Kubernetes for 1 pod (safe to repeat)
  local i READY POD STATE LAST   # loop variables
  for i in $(seq 1 180); do   # check every 5 seconds for up to 15 minutes
    READY=$(ready)   # ready pods of this model (empty means 0)
    POD=$(kubectl get pods -n $NS -l $LABEL --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -n 1)   # newest pod
    STATE=$(kubectl get $POD -n $NS --no-headers 2>/dev/null | awk '{print $2" "$3}')   # its state
    LAST=$(kubectl logs $POD -n $NS --tail=1 2>/dev/null | cut -c1-90)   # its last log line
    printf '[%s] %s ready=%s  pod=%s  %s\n' "$(date +%H:%M:%S)" "$NS" "${READY:-0}" "$STATE" "$LAST"   # one status line with the time
    if [ "${READY:-0}" = "1" ]; then echo "=== READY: $NS is serving the model. Memory available now: $(mem_available) GiB ==="; notify_model "READY - $NS is being served"; return 0; fi   # ready: report and stop waiting
    sleep 5   # wait before the next check
  done
  return 1   # not ready after 15 minutes
}

# dialog_width NAME...: window width in pixels from the longest name (at least 520, at most 1000)
dialog_width() {
  local L=0 N   # longest name so far
  for N in "$@"; do [ "${#N}" -gt "$L" ] && L=${#N}; done   # finds the longest name
  local W=$((L*9+330)); [ "$W" -lt 520 ] && W=520; [ "$W" -gt 1000 ] && W=1000   # characters to pixels, within the limits
  echo "$W"   # prints the width
}

# dialog_height ROWS: window height in pixels for that many list rows, never taller than 85% of the screen (a scroll bar appears beyond that)
dialog_height() {
  local H=$((290+36*$1)) M   # title, text, column header and buttons (about 290 pixels) plus one line per row
  M=$(xrandr --current 2>/dev/null | awk '/\*/{split($1,a,"x"); print a[2]; exit}')   # screen height in pixels
  [[ "$M" =~ ^[0-9]+$ ]] || M=800   # unknown screen: assume 800
  M=$((M*85/100)); [ "$H" -gt "$M" ] && H=$M   # keep the window on the screen
  echo "$H"   # prints the height
}

# notify_model "message": desktop notification that closes by itself after 5 seconds, so the notifications of several models do not pile up
notify_model() {
  local ID   # number that the desktop gives to this notification
  ID=$(notify-send -p -u normal -t 5000 -a "vLLM" "vLLM" "$1" 2>/dev/null)   # shows the notification and prints its number
  if [[ "$ID" =~ ^[0-9]+$ ]] && command -v gdbus >/dev/null 2>&1; then   # the number is known and gdbus is available
    setsid -f bash -c "sleep 5; gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications --method org.freedesktop.Notifications.CloseNotification $ID >/dev/null 2>&1" >/dev/null 2>&1   # removes it after 5 seconds, even if the window has closed by then
  elif [ -z "$ID" ]; then notify-send -t 5000 -a "vLLM" "vLLM" "$1" 2>/dev/null   # old notify-send without the number option: plain notification
  fi
}
