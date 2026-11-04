#!/bin/bash
# Load the shared settings and helper functions
source "$(dirname "$0")/vllmCommon.sh"
# Allow only one action at a time
take_lock "Stop vLLM"
# If the cluster cannot be reached, say so and stop
need_k8s stop
# Find every model that is running or starting
RUNNING=$(running_models)
# If none is running, the GPU is already free
[ -n "$RUNNING" ] || { say "No vLLM model is running (the GPU is free). Nothing to do."; exit 0; }
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
