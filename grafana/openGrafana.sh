#!/bin/bash
# Load the shared settings, lock and message helpers
SPARK_TOOLSET_ROOT="$(dirname "$(dirname "$(readlink -f "$0")")")"   # toolset root = folder above this script, so the scripts work wherever the toolset is placed
source "$SPARK_TOOLSET_ROOT/vllm/vllmCommon.sh"   # shared vLLM helper functions, loaded from the vllm folder
source "$SPARK_TOOLSET_ROOT/lib/checkRequiredProgramsAvailable.sh"   # shared check that the needed software is installed
require_tools "Open Grafana" kubectl curl flock systemctl ss xdg-open || exit 1   # stops with a clear message if something is missing
# Window title of the dialogs, local port of the tunnel and the page address
TITLE="Grafana"
PORT=23000
URL="http://127.0.0.1:$PORT"
# health: succeeds if Grafana answers through the tunnel
health() { [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' "$URL/api/health")" = "200" ]; }
# Do not run while another action (for example Stop Kubernetes) is in progress
exec 9>>"$LOCK"
if ! flock -n 9; then IFS='|' read -r A _ < "$LOCK"; say "${A:-Another action} is in progress.\n\nPlease try again when it has finished."; exit 1; fi
# Kubernetes must be running; otherwise tell the user exactly what to do first
systemctl is-active --quiet k3s || { say "KUBERNETES IS NOT RUNNING.\n\nGrafana runs inside Kubernetes.\n\nDO THIS FIRST:\n  1. Click the blue 'Start Kubernetes' icon\n  2. Wait until its window closes\n  3. Then click 'Open Grafana' again"; exit 1; }
# The cluster must answer (otherwise it is still starting)
[ -n "$(kc get nodes -o name)" ] || { say "Kubernetes is still STARTING.\n\nPlease wait 1-2 minutes and click again."; exit 1; }
# Grafana must be ready
[ "$(kc get deployment kps-grafana -n monitoring -o jsonpath='{.status.readyReplicas}')" = "1" ] || { say "Grafana is not ready yet (it may still be starting).\n\nPlease wait 1-2 minutes and click again."; exit 1; }
# If the tunnel does not work (missing or broken), remove any old one and open a new one
if ! health; then
  # Remove an old or broken tunnel to Grafana
  ss -ltnp "sport = :$PORT" | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u | xargs -r kill 2>/dev/null; sleep 1
  # Start a new tunnel, detached so it keeps running after this script ends
  setsid nohup kubectl port-forward -n monitoring svc/kps-grafana $PORT:80 9>&- > /tmp/grafana-pf.log 2>&1 &
  # Wait up to 20 seconds for Grafana to answer through the tunnel
  for i in $(seq 1 20); do health && break; sleep 1; done
fi
# If it still does not answer, say so and point to the log
health || { say "Could not open the tunnel to Grafana.\n\nDetails are in /tmp/grafana-pf.log"; exit 1; }
# Open the page in the default browser and show a pop-up
xdg-open "$URL/" 9>&- >/dev/null 2>&1 &
notify-send "Grafana" "Opened $URL"
