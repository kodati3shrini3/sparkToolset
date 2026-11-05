#!/bin/bash
# Load the shared settings, lock and message helpers
SPARK_TOOLSET_ROOT="$(dirname "$(dirname "$(readlink -f "$0")")")"   # toolset root = folder above this script, so the scripts work wherever the toolset is placed
source "$SPARK_TOOLSET_ROOT/vllm/vllmCommon.sh"   # shared vLLM helper functions, loaded from the vllm folder
source "$SPARK_TOOLSET_ROOT/lib/checkRequirements.sh"   # shared check that the needed software is installed
require_tools "Stop Kubernetes" kubectl jq curl flock systemctl sudo ss || exit 1   # stops with a clear message if something is missing
# Window title of the dialogs
TITLE="Kubernetes"
# Allow only one action at a time; a second click gets the live status window
take_lock "Stop Kubernetes"
# Remove the phase file when this script ends, whatever the reason
trap 'rm -f "$STATUS"' EXIT
# phase "n/5" "text": write the current phase for the live view and print it in this window
phase() { echo "$1|$2|$(date +%s)" > "$STATUS"; echo "[$1] $2"; }
# If k3s is not running there is nothing to stop
systemctl is-active --quiet k3s || { say "Kubernetes (k3s) is already stopped. Nothing to do."; exit 0; }
# Find the node name; if the cluster does not answer, say so
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "$NODE" ] && { say "k3s is running but the cluster does not answer. Wait a minute and try again."; exit 1; }
# has_pod "regex": true if any pod name in any namespace matches (used to detect installed apps)
has_pod() { kubectl get pods -A --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep -q -i -E "$1"; }
# Detect what is installed: vLLM, the monitoring apps and the GPU Operator
HAS_VLLM=no; [ -n "$(list_models)" ] && HAS_VLLM=yes
HAS_GRAF=no; has_pod 'grafana' && HAS_GRAF=yes
HAS_PROM=no; has_pod '^prometheus-' && HAS_PROM=yes
HAS_ALERT=no; has_pod '^alertmanager-' && HAS_ALERT=yes
HAS_GPU=no; kubectl get ns gpu-operator >/dev/null 2>&1 && HAS_GPU=yes
# Build the list of things that will stop (only what exists)
LIST=""
[ "$HAS_VLLM" = yes ] && LIST+=$'\n  - vLLM (Open WebUI loses its vLLM model)'
MON=""
[ "$HAS_GRAF" = yes ] && MON+="Grafana, "
[ "$HAS_PROM" = yes ] && MON+="Prometheus, "
[ "$HAS_ALERT" = yes ] && MON+="Alertmanager, "
[ -n "$MON" ] && LIST+=$'\n  - '"${MON%, }"
[ "$HAS_GPU" = yes ] && LIST+=$'\n  - GPU Operator'
# Build the warning text
if [ -n "$LIST" ]; then MSG="This stops ALL of Kubernetes (k3s):$LIST"; else MSG="This stops ALL of Kubernetes (k3s) and every pod in it."; fi
[ "$HAS_GRAF" = yes ] && MSG+=$'\n\nThe Grafana tunnel on port 23000 closes.'
[ "$HAS_ALERT" = yes ] && MSG+=$'\nAlertmanager silences are lost.'
MSG+=$'\nDocker containers (AI-Stack) are NOT affected.\n\nCheck the applications that use it first.'
[ "$HAS_VLLM" = yes ] && MSG+=$'\n\nAFTER THIS: to use vLLM again, click Start Kubernetes FIRST (blue), then Start vLLM (green).'
MSG+=$'\n\nPress OK to stop gently, or Cancel.'
# Show the warning and ask OK / Cancel
ask_ok "$MSG" || { echo "Cancelled. Kubernetes keeps running."; sleep 3; exit 0; }
# Remember when the real work starts (for the real duration)
T0=$(date +%s)
# Ask for the administrator password once, in this window
echo "=== Stopping Kubernetes gently ==="; echo "Administrator rights are needed to stop the k3s service. You are asked for your password only if sudo does not remember it yet."
sudo -v || { say "Password not accepted. Nothing was stopped."; exit 1; }
# Phase 1: stop vLLM first (if it exists), so it stays off after the next start
phase "1/5" "Stopping vLLM first (so it stays off after the next start)"
if [ "$HAS_VLLM" = yes ]; then
  for R in $(running_models); do stop_model "$R"; done
else echo "  vLLM is not installed, skipped"; fi
# Phase 2: close any open tunnels (normal termination signal)
phase "2/5" "Closing open tunnels (for example Grafana on port 23000)"
TPIDS=$(ss -ltnp 2>/dev/null | grep '"kubectl"' | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u || true)   # PIDs of kubectl processes that listen on a port; kubectl hides its arguments, so pkill -f cannot find them
if [ -n "$TPIDS" ]; then kill -TERM $TPIDS; echo "  tunnels closed"; else echo "  no tunnels were open"; fi   # closes every open tunnel, or says there were none
# Phase 3: drain the node, every pod gets a normal shutdown signal and time to finish; if it does not finish, do NOT stop k3s
phase "3/5" "Draining the node: every pod is asked to shut down normally"
if ! kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=300s; then
  notify-send "Kubernetes" "Drain did not finish - k3s was NOT stopped"
  echo; echo "DRAIN DID NOT FINISH. k3s was NOT stopped. Use Start Kubernetes to allow pods again, or retry Stop."
  read -p "Press Enter to close"; exit 1
fi
# Phase 4: stop the k3s service, then stop the remaining helper pods (they hold no data)
phase "4/5" "Stopping the k3s service and the remaining helper pods"
sudo systemctl stop k3s
sudo /usr/local/bin/k3s-killall.sh > /tmp/k3s-killall.log 2>&1
# Phase 5: verify that k3s and its containers are gone and that Docker is untouched
phase "5/5" "Checking the result"
LEFT=$(pgrep -fc "run/k3s/containerd" || true)
echo "  k3s service: $(systemctl is-active k3s)   k3s containers left: ${LEFT:-0}   Docker containers still running: $(docker ps -q 2>/dev/null | wc -l)"
if [ "${LEFT:-0}" = "0" ]; then
  # Remember how long this stop really took, for the comparison line in the live view
  record_duration "Stop Kubernetes" "$T0"
  echo "=== STOPPED in $(fmt_s $(( $(date +%s) - T0 ))): Kubernetes is down ==="
  [ "$HAS_VLLM" = yes ] && echo "TO USE vLLM AGAIN: click Start Kubernetes FIRST (blue), then Start vLLM (green)."
  notify-send "Kubernetes" "STOPPED - k3s is down"
  # Count down 8 seconds, then the window closes by itself
  for s in 8 7 6 5 4 3 2 1; do printf '\rClosing in %s s ' $s; sleep 1; done
else
  echo "=== Some k3s containers are still running - check with: sudo k3s crictl ps ==="; read -p "Press Enter to close"
fi
