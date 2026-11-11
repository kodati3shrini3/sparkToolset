#!/bin/bash
# Load the shared settings and helper functions
source "$(dirname "$0")/vllmCommon.sh"
source "$(dirname "$0")/../lib/checkRequiredProgramsAvailable.sh"   # shared check that the needed software is installed
require_tools "Start vLLM" kubectl jq curl flock systemctl || exit 1   # stops with a clear message if something is missing
# Allow only one action at a time
take_lock "Start vLLM"
# If the cluster cannot be reached, say so and stop
need_k8s start
# If no vLLM model is installed at all, say so and stop
[ -n "$(list_models)" ] || { say "No vLLM model is installed in Kubernetes."; exit 1; }
# Several GPU slots (time-slicing on) and several models installed: multi-select, the models start one after another (Step 108)
if [ "$(slots_offered)" -ge 2 ] && [ "$(list_models | grep -c .)" -ge 2 ]; then   # in every other case the old single-choice code below runs unchanged
  PICKED=$(pick_models start) || { echo "Cancelled or nothing ticked. Nothing was started."; sleep 3; exit 0; }   # checklist; Cancel changes nothing
  TOSTART=""   # the models that really have to be started
  for M in $PICKED; do   # one ticked model at a time
    W=$(list_models | awk -v m="$M" '$1==m{print $3}')   # wanted pods of this model (1 or more means it is on already)
    if [ "${W:-0}" -ge 1 ]; then echo "  $M is already on (running or starting): left alone"; else TOSTART+="$M "; fi   # a model that is on is never touched
  done
  [ -n "$TOSTART" ] || { say "The ticked models are already running. Nothing to do."; exit 0; }   # nothing new to start
  WILLRUN=$( { running_models; for M in $TOSTART; do echo "$M"; done; } | awk '!s[$0]++')   # models that will run: already on plus new ones, no duplicates
  [ "$(echo "$WILLRUN" | grep -c .)" -ge 2 ] && warn_resources $WILLRUN   # warning (OK only) when more than one model will run; nothing is stopped
  for M in $TOSTART; do   # start one after another, in list order
    if ! start_model_wait "$M"; then   # the start failed or the model was not ready after 15 minutes
      echo "=== $M did NOT become ready. The next models were not started. ==="; notify_model "Start FAILED or timed out: $M"   # report and do not start the next ones
      use_model "$M"; P=$(kubectl get pods -n $NS -l $LABEL --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -n 1)   # newest pod of the failed model
      echo "Last log lines of $P:"; kubectl logs $P -n $NS --tail=15 2>&1 | cut -c1-160   # shows the reason
      read -p "Press Enter to close"; exit 1   # keeps the window open so the error can be read
    fi
  done
  echo "=== READY: all selected models are serving ==="   # final message
  notify_model "READY - all selected models are serving: $TOSTART"   # one summary notification as well
  for s in 8 7 6 5 4 3 2 1; do printf '\rClosing in %s s ' $s; sleep 1; done   # the window closes by itself after 8 seconds
  exit 0   # done; the old single-model code below is not used
fi
# Let the user choose the model (no question if only one is installed)
M=$(pick_model)
# If nothing was chosen (Cancel), leave without changing anything
[ -n "$M" ] || { echo "Cancelled. Nothing was started."; sleep 3; exit 0; }
# Look up the names of the chosen model and show it in the live status of a second click
use_model "$M"; lock_model "$M"
# If the chosen model is already running, say so and stop
[ "$(desired)" = "1" ] && [ "$(ready)" = "1" ] && { say "$M is already running. Nothing to do."; exit 0; }
# Find the other models that are running or starting (only one can use the single GPU)
OTHERS=$(running_models | grep -v -x "$M")
if [ -n "$OTHERS" ]; then
  # Warn and ask OK / Cancel before stopping them
  ask_ok "Only one model can run at a time (one GPU).\n\nThese models are running now and will be stopped first:\n$(echo "$OTHERS" | sed 's/^/  - /')\n\nCheck the applications that use them first (Open WebUI chats, scripts calling the API).\n\nPress OK to stop them and start $M, or Cancel." || { echo "Cancelled. Nothing was changed."; sleep 3; exit 0; }
  echo "=== Stopping the running model first ==="
  # Stop each one and wait until its pod is really gone, otherwise the GPU is still taken
  for O in $OTHERS; do stop_model "$O" || { say "Could not stop $O within 3 minutes.\n\n$M was NOT started."; exit 1; }; done
  # stop_model changed the lookup values, so look up the chosen model again
  use_model "$M"
fi
# Window heading
echo "=== Starting vLLM: $M (model loads from disk, about 5 minutes) ==="
# Pop-up so you know the click was received
notify-send "vLLM" "Starting $M... the model needs about 5 minutes to load"
# Ask Kubernetes for 1 pod of the chosen model (safe to repeat)
kubectl scale deployment/$DEP -n $NS --replicas=1 || { say "Start FAILED: cluster not reachable."; exit 1; }
# Check every 5 seconds for up to 15 minutes (180 rounds)
for i in $(seq 1 180); do
  # Number of ready pods (empty means 0)
  READY=$(ready)
  # Name, state and last log line of the newest pod of this model
  POD=$(kubectl get pods -n $NS -l $LABEL --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -n 1)
  STATE=$(kubectl get $POD -n $NS --no-headers 2>/dev/null | awk '{print $2" "$3}')
  LAST=$(kubectl logs $POD -n $NS --tail=1 2>/dev/null | cut -c1-90)
  # Print one status line with the time
  printf '[%s] ready=%s  pod=%s  %s\n' "$(date +%H:%M:%S)" "${READY:-0}" "$STATE" "$LAST"
  # Stop waiting as soon as one pod is ready
  [ "${READY:-0}" = "1" ] && break
  sleep 5
done
# Report the final result
if [ "${READY:-0}" = "1" ]; then
  echo "=== READY: $M is serving the model ==="; notify-send "vLLM" "READY - $M is being served"
  # Count down 8 seconds, then the window closes by itself
  for s in 8 7 6 5 4 3 2 1; do printf '\rClosing in %s s ' $s; sleep 1; done
else
  echo "=== NOT READY after 15 minutes - check the pod in k9s ==="; notify-send "vLLM" "Start FAILED or timed out"
  # Keep the window open so the error can be read
  read -p "Press Enter to close"
fi
