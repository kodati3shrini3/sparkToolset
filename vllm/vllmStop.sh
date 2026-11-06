#!/bin/bash
# Load the shared settings and helper functions
source "$(dirname "$0")/vllmCommon.sh"
source "$(dirname "$0")/../lib/checkRequirements.sh"   # shared check that the needed software is installed
require_tools "Stop vLLM" kubectl jq curl flock systemctl || exit 1   # stops with a clear message if something is missing
# Allow only one action at a time
take_lock "Stop vLLM"
# If the cluster cannot be reached, say so and stop
need_k8s stop
# Find every model that is running or starting
RUNNING=$(running_models)
# If none is running, the GPU is already free
[ -n "$RUNNING" ] || { say "No vLLM model is running (the GPU is free). Nothing to do."; exit 0; }
# Several models running: choose which ones to stop, a notification follows each one (Step 109); with one model running the old code below runs unchanged
if [ "$(echo "$RUNNING" | grep -c .)" -ge 2 ]; then   # otherwise the old code below runs unchanged
  PICKED=$(pick_models stop) || { echo "Cancelled or nothing ticked. vLLM keeps running."; sleep 3; exit 0; }   # checklist of the running models, all pre-ticked
  TXT=""; for R in $PICKED; do use_model "$R"; read RUN WAIT <<< "$(busy)"; TXT+="  - $R: requests running $RUN, waiting $WAIT"$'\n'; done   # request counts of the ticked models only
  use_model "$(echo "$PICKED" | head -n 1)"; lock_model "$NS"   # show the first ticked model in the live status of a second click
  ask_ok "vLLM is running (or starting) and may be in use.\n\nThis stops:\n$TXT\nModels you did not tick keep running.\n\nBefore stopping, check the applications that use it:\n  - Open WebUI chats\n  - any tool or script calling the vLLM API\n\nPress OK to stop, or Cancel to keep it running." || { echo "Cancelled. vLLM keeps running."; sleep 3; exit 0; }   # OK / Cancel warning
  echo "=== Stopping vLLM ==="   # window heading
  FAIL=0   # becomes 1 if one model does not stop in time
  for R in $PICKED; do   # one ticked model at a time
    lock_model "$R"   # live status follows the model being stopped now
    if stop_model "$R"; then echo "=== STOPPED: $R is unloaded. Memory available now: $(mem_available) GiB ==="; notify_model "STOPPED - $R is unloaded"   # notification for this model
    else FAIL=1; echo "=== $R is still stopping after 3 minutes ==="; notify_model "Stop is taking long: $R"; fi   # warning for this model
  done
  if [ "$FAIL" = "0" ]; then   # all ticked models are gone
    echo "=== STOPPED: all selected models are unloaded ==="; notify_model "STOPPED - all selected models are unloaded"   # summary notification
    for s in 5 4 3 2 1; do printf '\rClosing in %s s ' $s; sleep 1; done   # the window closes by itself after 5 seconds
  else read -p "Press Enter to close"; fi   # keeps the window open so the state can be read
  exit 0   # done; the old code below is not used
fi
# Build the list of running models with their current request counts
TXT=""
for R in $RUNNING; do use_model "$R"; read RUN WAIT <<< "$(busy)"; TXT+="  - $R: requests running $RUN, waiting $WAIT"$'\n'; done
# Show the first model in the live status of a second click
use_model "$(echo "$RUNNING" | head -n 1)"; lock_model "$NS"
# Warn the user and ask for OK / Cancel
ask_ok "vLLM is running (or starting) and may be in use.\n\nThis stops:\n$TXT\nBefore stopping, check the applications that use it:\n  - Open WebUI chats\n  - any tool or script calling the vLLM API\n\nPress OK to stop, or Cancel to keep it running." || { echo "Cancelled. vLLM keeps running."; sleep 3; exit 0; }
# Window heading
echo "=== Stopping vLLM ==="
# Stop each running model and wait until its pod is really gone
FAIL=0
for R in $RUNNING; do stop_model "$R" || FAIL=1; done
# Report the final result
if [ "$FAIL" = "0" ]; then
  echo "=== STOPPED: GPU memory is freed ==="; notify-send "vLLM" "STOPPED - GPU memory is freed"
  # Count down 5 seconds, then the window closes by itself
  for s in 5 4 3 2 1; do printf '\rClosing in %s s ' $s; sleep 1; done
else
  echo "=== Still stopping after 3 minutes - check the pod in k9s ==="; notify-send "vLLM" "Stop is taking long"
  # Keep the window open so the state can be read
  read -p "Press Enter to close"
fi
