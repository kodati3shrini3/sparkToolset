#!/bin/bash
# Compose project and file of your Docker stack; override with SPARK_DOCKER_PROJECT and SPARK_DOCKER_COMPOSE_FILE
PROJECT="${SPARK_DOCKER_PROJECT:-ai-stack}"   # compose project name, taken from the environment if set, otherwise ai-stack
COMPOSE_FILE="${SPARK_DOCKER_COMPOSE_FILE:-$HOME/AI-Stack/docker-compose.yaml}"   # compose file path, taken from the environment if set, otherwise under your home folder
# Seconds each container may take to shut down gently before it is force-ended (Neo4j asks for 2 minutes)
GRACE=120
# Lock file of the two Docker icons (separate from the Kubernetes and vLLM lock) and the phase file written by Stop Docker (both cleared at reboot)
LOCK="${XDG_RUNTIME_DIR:-/tmp}/docker-action.lock"
STATUS="${XDG_RUNTIME_DIR:-/tmp}/docker-stop.status"
# Folder that remembers the container list saved by Stop (it survives reboots) and the real durations of past actions
STATE="$HOME/.local/state/dockerStartStopScripts"
SAVED="$STATE/runningContainers.txt"
HIST="$STATE"
# Window title of the dialogs
TITLE="Docker"

# say "text": show an information message (dialog box if zenity exists, otherwise in this window)
say() {
  if command -v zenity >/dev/null 2>&1; then zenity --info --title="${TITLE:-Docker}" --width=460 --text="$1" 2>/dev/null
  else echo; echo "$1"; read -p "Press Enter to close"; fi
}
# ask_ok "text": show an OK / Cancel question; returns success only if the user presses OK
ask_ok() {
  if command -v zenity >/dev/null 2>&1; then zenity --question --title="${TITLE:-Docker}" --width=560 --ok-label="OK" --cancel-label="Cancel" --text="$1" 2>/dev/null
  else echo; echo "$1"; read -p "Type OK and press Enter to continue (anything else cancels): " ANS; [ "$ANS" = "OK" ]; fi
}
# fmt_s SECONDS: format seconds as M:SS
fmt_s() { printf '%d:%02d' $(($1/60)) $(($1%60)); }
# record_duration "action" START_EPOCH: remember how long a successful action really took
record_duration() { [ -n "$2" ] || return 0; mkdir -p "$HIST"; echo $(( $(date +%s) - $2 )) > "$HIST/duration_$(echo "$1" | tr ' ' '_')"; }
# last_duration "action": print the remembered real duration as M:SS (nothing if there is none yet)
last_duration() { local f="$HIST/duration_$(echo "$1" | tr ' ' '_')"; [ -r "$f" ] && fmt_s "$(cat "$f")"; }
# dc ARGS: run docker compose for the AI-Stack project
dc() { docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"; }

# live_status "action" START_EPOCH: print the REAL state of the Docker action that is running now
live_status() {
  local A="$1" S="$2" NOW SV R; NOW=$(date +%s)
  echo "  Running for: $(fmt_s $((NOW-S)))"
  case "$A" in
    "Stop Docker")
      # Phase written by the Stop script
      if [ -r "$STATUS" ]; then IFS='|' read -r PH TXT PS < "$STATUS"; echo "  Phase $PH: $TXT (for $(fmt_s $((NOW-PS))))"; fi
      # Docker service state and the containers that are still running
      echo "  Docker service: $(systemctl is-active docker)"
      R=$(docker ps --format '{{.Names}}' 2>/dev/null)
      echo "  Containers still running: $(echo "$R" | grep -c .)"
      [ -n "$R" ] && echo "    $(echo "$R" | paste -sd' ' - | fold -s -w 70 | sed '2,$s/^/    /')" ;;
    "Start Docker")
      # Docker service state, running containers against the saved list, and health checks
      SV=$(grep -c . "$SAVED" 2>/dev/null)
      echo "  Docker service: $(systemctl is-active docker)"
      echo "  Containers running: $(docker ps -q 2>/dev/null | wc -l) of ${SV:-0} saved"
      echo "  Health checks: still starting: $(docker ps -q --filter health=starting 2>/dev/null | wc -l)   unhealthy: $(docker ps -q --filter health=unhealthy 2>/dev/null | wc -l)" ;;
  esac
}

# wait_for_other: shown when a second click arrives while another Docker action runs; shows its live status until it has finished
wait_for_other() {
  # Read "action|start time" written by the action that holds the lock
  IFS='|' read -r A S _ < "$LOCK"
  A=${A:-another action}; S=${S:-$(date +%s)}
  while true; do
    # If the lock can be taken, the other action has finished
    if flock -n 9; then printf '\033[H\033[J'; echo "=== $A has finished. You can click again now. ==="; break; fi
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

# take_lock "name": allow only one Docker action at a time; a second click gets the live status window
take_lock() {
  # Open the lock file for appending (appending does not wipe the info of the running action)
  mkdir -p "$STATE"; exec 9>>"$LOCK"
  # If another action holds the lock, show its live status and leave
  if ! flock -n 9; then wait_for_other; exit 1; fi
  # Record the action name and the start time
  truncate -s 0 "$LOCK"; echo "$1|$(date +%s)" >&9
}
