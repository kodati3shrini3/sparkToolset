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
