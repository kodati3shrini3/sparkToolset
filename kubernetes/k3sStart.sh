#!/bin/bash
# Load the shared settings, lock and message helpers of the vLLM scripts
SPARK_TOOLSET_ROOT="$(dirname "$(dirname "$(readlink -f "$0")")")"   # toolset root = folder above this script, so the scripts work wherever the toolset is placed
source "$SPARK_TOOLSET_ROOT/vllm/vllmCommon.sh"   # shared vLLM helper functions, loaded from the vllm folder
source "$SPARK_TOOLSET_ROOT/lib/checkRequirements.sh"   # shared check that the needed software is installed
require_tools "Start Kubernetes" kubectl jq curl flock systemctl sudo || exit 1   # stops with a clear message if something is missing
# Allow only one action at a time
take_lock "Start Kubernetes"; T0=$(date +%s)
# If k3s is running and the node accepts pods, there is nothing to do
if systemctl is-active --quiet k3s; then
  UNSCHED=$(kubectl get nodes -o jsonpath='{.items[0].spec.unschedulable}' 2>/dev/null)
  [ -n "$(kubectl get nodes -o name 2>/dev/null)" ] && [ "$UNSCHED" != "true" ] && { say "Kubernetes (k3s) is already running. Nothing to do."; exit 0; }
fi
# Ask for the administrator password once, in this window
echo "=== Starting Kubernetes ==="; echo "Your password is needed to start the k3s service."
sudo -v || { say "Password not accepted. Nothing was started."; exit 1; }
# Pop-up so you know the click was received
notify-send "Kubernetes" "Starting k3s..."
# Start the k3s service (it recreates the pods from the saved cluster data)
sudo systemctl start k3s || { say "k3s failed to start. Look at: sudo journalctl -u k3s -n 50"; read -p "Press Enter to close"; exit 1; }
# Step 1: wait until the node reports Ready (up to 3 minutes)
echo "[1/3] Waiting for the node to be Ready (up to 3 minutes)"
for i in $(seq 1 36); do
  NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  OK=$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  printf '  [%s] node=%s ready=%s\n' "$(date +%H:%M:%S)" "${NODE:-?}" "${OK:-no answer yet}"
  [ "$OK" = "True" ] && break; sleep 5
done
[ "$OK" = "True" ] || { notify-send "Kubernetes" "Node did not become Ready"; echo "Node did not become Ready in 3 minutes."; read -p "Press Enter to close"; exit 1; }
# Step 2: allow pods to run again (undoes the drain from Stop)
echo "[2/3] Allowing pods to run again"
kubectl uncordon "$NODE"
# Step 3: wait until every pod is Running or Completed (up to 10 minutes)
echo "[3/3] Waiting for the pods to start (up to 10 minutes)"
for i in $(seq 1 120); do
  BAD=$(kubectl get pods -A --no-headers 2>/dev/null | grep -v -E 'Running|Completed' | wc -l)
  RUN=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c Running)
  printf '  [%s] running=%s  not ready yet=%s\n' "$(date +%H:%M:%S)" "$RUN" "$BAD"
  [ "$BAD" = "0" ] && [ "$RUN" -gt 0 ] && break; sleep 5
done
record_duration "Start Kubernetes" "$T0"; echo "=== Kubernetes is up ==="; notify-send "Kubernetes" "READY - k3s is running"
# Ask whether vLLM should be started now (it was stopped by the Stop script and stays off by default)
if ask_ok "Kubernetes is running. vLLM is OFF.\n\nPress OK to start vLLM now (about 5 minutes),\nor Cancel to leave it off (use the Start vLLM icon later)."; then
  # Release the lock so the vLLM script can take it, then run it in this same window
  exec 9>&-
  "$SPARK_TOOLSET_ROOT/vllm/vllmStart.sh"
else
  echo "vLLM stays off."; for s in 6 5 4 3 2 1; do printf '\rClosing in %s s ' $s; sleep 1; done
fi
