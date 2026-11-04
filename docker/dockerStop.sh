#!/bin/bash
# Load the shared settings and helper functions
source "$(dirname "$0")/dockerCommon.sh"
source "$(dirname "$0")/../lib/checkRequirements.sh"   # shared check that the needed software is installed
require_tools "Stop Docker" docker flock systemctl sudo || exit 1   # stops with a clear message if something is missing
# Allow only one Docker action at a time; a second click gets the live status window
take_lock "Stop Docker"
# Remove the phase file when this script ends, whatever the reason
trap 'rm -f "$STATUS"' EXIT
# phase "n/4" "text": write the current phase for the live view and print it in this window
phase() { echo "$1|$2|$(date +%s)" > "$STATUS"; echo "[$1] $2"; }
# If the Docker service is not running there is nothing to stop
systemctl is-active --quiet docker || { say "Docker is already stopped. Nothing to do."; exit 0; }
# Take a snapshot of what is running now: one line per container "name|compose project|compose service"
RUNFILE="$STATE/runningNow.tmp"
docker ps --format '{{.Names}}' | while read -r N; do
  P=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$N" 2>/dev/null)
  V=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$N" 2>/dev/null)
  echo "$N|$P|$V"
done > "$RUNFILE"
# Names of the running containers, and how many there are
NAMES=$(cut -d'|' -f1 "$RUNFILE" | sort)
COUNT=$(echo "$NAMES" | grep -c .)
# Build a short readable list of the names for the warning
LIST=$(echo "$NAMES" | paste -sd, - | sed 's/,/, /g' | fold -s -w 64)
# Build the warning text
MSG="This stops ALL of Docker: $COUNT running containers:\n\n$LIST\n\nThe Docker service stops too, so Portainer and every container above go down.\nKubernetes and vLLM are NOT affected.\n\nCheck the applications that use them first (for example Open WebUI chats, SNOMED tools, Kafka consumers).\n\nTO USE THEM AGAIN: click Start Docker.\n\nPress OK to stop gently (each container may take up to $GRACE s), or Cancel."
# Show the warning and ask OK / Cancel
ask_ok "$MSG" || { echo "Cancelled. Docker keeps running."; sleep 3; exit 0; }
# Remember when the real work starts (for the real duration)
T0=$(date +%s)
# Ask for the administrator password once, in this window (needed to stop the service)
echo "=== Stopping Docker gently ==="; echo "Your password is needed to stop the Docker service."
sudo -v || { say "Password not accepted. Nothing was stopped."; exit 1; }
# Save the list for Start; an empty snapshot never overwrites an earlier saved list
[ -s "$RUNFILE" ] && cp "$RUNFILE" "$SAVED"
# Compose services (stopped together in dependency order) and other containers (stopped one by one)
SERVICES=$(awk -F'|' -v p="$PROJECT" '$2==p && $3!="" {print $3}' "$RUNFILE" | tr '\n' ' ')
OTHERS=$(awk -F'|' -v p="$PROJECT" '!($2==p && $3!="") {print $1}' "$RUNFILE")
# Phase 1: stop the AI-Stack containers; Compose closes the apps before the databases they use
phase "1/4" "Stopping the AI-Stack containers in dependency order (up to $GRACE s each)"
[ -n "$SERVICES" ] && dc stop -t "$GRACE" $SERVICES || echo "  no AI-Stack containers were running"
# Phase 2: stop any container that is not part of the AI-Stack
phase "2/4" "Stopping other containers"
for N in $OTHERS; do docker stop -t "$GRACE" "$N"; done
[ -z "$OTHERS" ] && echo "  none"
# Phase 3: stop the Docker service and its socket (the socket would otherwise restart the service on the next docker command)
phase "3/4" "Stopping the Docker service"
sudo systemctl stop docker.socket docker
# Phase 4: verify that the service and its container processes are gone
phase "4/4" "Checking the result"
LEFT=$(pgrep -fc 'containerd-shim.* -namespace moby' || true)
echo "  Docker service: $(systemctl is-active docker)   Docker container processes left: ${LEFT:-0}   k3s is untouched: $(systemctl is-active k3s)"
if [ "$(systemctl is-active docker)" != "active" ] && [ "${LEFT:-0}" = "0" ]; then
  # Remember how long this stop really took, for the comparison line in the live view
  record_duration "Stop Docker" "$T0"
  echo "=== STOPPED in $(fmt_s $(( $(date +%s) - T0 ))): Docker is down ==="
  echo "TO USE THE CONTAINERS AGAIN: click Start Docker."
  notify-send "Docker" "STOPPED - Docker is down"
  # Count down 8 seconds, then the window closes by itself
  for s in 8 7 6 5 4 3 2 1; do printf '\rClosing in %s s ' $s; sleep 1; done
else
  echo "=== Docker did not stop completely - check: systemctl status docker ==="; read -p "Press Enter to close"
fi
