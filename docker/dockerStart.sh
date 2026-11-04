#!/bin/bash
# Load the shared settings and helper functions
source "$(dirname "$0")/dockerCommon.sh"
source "$(dirname "$0")/../lib/checkRequirements.sh"   # shared check that the needed software is installed
require_tools "Start Docker" docker flock systemctl sudo || exit 1   # stops with a clear message if something is missing
# Allow only one Docker action at a time; a second click gets the live status window
take_lock "Start Docker"; T0=$(date +%s)
# The list of containers that Stop saved (empty if Stop was never used)
SV=$(grep -c . "$SAVED" 2>/dev/null); SV=${SV:-0}
# If Docker already runs and every saved container is up, there is nothing to do
if systemctl is-active --quiet docker && [ "$SV" -gt 0 ]; then
  MISSING=$(cut -d'|' -f1 "$SAVED" | grep -v -x -F -f <(docker ps --format '{{.Names}}') | wc -l)
  [ "$MISSING" = "0" ] && { say "Docker is already running with all $SV saved containers. Nothing to do."; exit 0; }
fi
# Start the Docker service if it is not running
if ! systemctl is-active --quiet docker; then
  echo "=== Starting Docker ==="; echo "Your password is needed to start the Docker service."
  sudo -v || { say "Password not accepted. Nothing was started."; exit 1; }
  notify-send "Docker" "Starting Docker..."
  sudo systemctl start docker.socket docker || { say "Docker failed to start. Look at: sudo journalctl -u docker -n 50"; read -p "Press Enter to close"; exit 1; }
  # Wait until the Docker engine answers (up to 60 seconds)
  for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
fi
docker info >/dev/null 2>&1 || { say "Docker does not answer. Look at: sudo journalctl -u docker -n 50"; exit 1; }
# Containers with restart rules start by themselves; give them a moment, then start whatever is still missing from the saved list
if [ "$SV" -gt 0 ]; then
  echo "[1/2] Starting the $SV containers that were running before Stop"
  sleep 10
  # Names that should run but do not, split into AI-Stack services and other containers
  docker ps --format '{{.Names}}' > "$STATE/runningNow.tmp"
  TODO=$(grep -v -x -F -f "$STATE/runningNow.tmp" <(cut -d'|' -f1 "$SAVED") || true)
  SERVICES=""; OTHERS=""
  for N in $TODO; do
    LINE=$(grep -m1 "^$N|" "$SAVED"); P=$(echo "$LINE" | cut -d'|' -f2); V=$(echo "$LINE" | cut -d'|' -f3)
    if [ "$P" = "$PROJECT" ] && [ -n "$V" ]; then SERVICES+="$V "; else OTHERS+="$N "; fi
  done
  [ -n "$SERVICES" ] && dc start $SERVICES
  [ -n "$OTHERS" ] && docker start $OTHERS
  [ -z "$TODO" ] && echo "  Docker's own restart rules already started them all"
else
  echo "No saved list from a Stop, so Docker's own restart rules decide what starts."
fi
# Wait until every saved container runs and no health check is still starting (up to 5 minutes)
echo "[2/2] Waiting for the containers to be up and healthy (up to 5 minutes)"
for i in $(seq 1 60); do
  RUN=$(docker ps -q | wc -l)
  HSTART=$(docker ps -q --filter health=starting | wc -l)
  HBAD=$(docker ps -q --filter health=unhealthy | wc -l)
  printf '  [%s] running=%s of %s saved  health checks still starting=%s  unhealthy=%s\n' "$(date +%H:%M:%S)" "$RUN" "$SV" "$HSTART" "$HBAD"
  # Done when all saved containers run and no health check is starting
  [ "$SV" -gt 0 ] && [ "$RUN" -ge "$SV" ] && [ "$HSTART" = "0" ] && break
  [ "$SV" = "0" ] && [ "$i" -ge 6 ] && break
  sleep 5
done
# Report containers that run but were not in the saved list (started by Docker's own restart rule)
if [ "$SV" -gt 0 ]; then
  EXTRA=$(docker ps --format '{{.Names}}' | grep -v -x -F -f <(cut -d'|' -f1 "$SAVED") | paste -sd, - | sed 's/,/, /g')
  [ -n "$EXTRA" ] && echo "Also running (not running before Stop, started by Docker's own restart rule): $EXTRA"
fi
# Final result
if [ "$HBAD" = "0" ] && { [ "$SV" = "0" ] || [ "$RUN" -ge "$SV" ]; }; then
  record_duration "Start Docker" "$T0"
  echo "=== READY in $(fmt_s $(( $(date +%s) - T0 ))): $RUN containers running ==="; notify-send "Docker" "READY - $RUN containers running"
  # Count down 8 seconds, then the window closes by itself
  for s in 8 7 6 5 4 3 2 1; do printf '\rClosing in %s s ' $s; sleep 1; done
else
  echo "=== Not everything is up or healthy - check with: docker ps -a ==="; notify-send "Docker" "Start finished with problems"
  # Keep the window open so the state can be read
  read -p "Press Enter to close"
fi
