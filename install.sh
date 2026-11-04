#!/bin/bash
# install.sh: creates start/stop icons (desktop launchers) for the sparkToolset programs whose software is installed
# usage: install.sh [--dry-run] [--no-desktop] [--remove]

ROOT="$(dirname "$(readlink -f "$0")")"   # folder that holds this script = toolset root, so the paths work wherever the toolset lives
DRY=no; DESK=yes; REMOVE=no   # defaults: really install, and also place icons on the Desktop
for A in "$@"; do   # reads the command-line options
  case "$A" in   # one case per option
    --dry-run) DRY=yes;;   # only show what would happen
    --no-desktop) DESK=no;;   # use the applications menu only
    --remove) REMOVE=yes;;   # delete the launchers this script manages
    *) echo "unknown option: $A"; exit 1;;   # anything else is an error
  esac   # end of the option check
done   # end of the option loop

MENU="$HOME/.local/share/applications"   # folder of the applications menu entries
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"   # the user's Desktop folder (language independent)
BACKUPS="$HOME/.local/state/sparkToolset/launcherBackups"   # where replaced launchers are kept

has_tools() { local T; for T in "$@"; do command -v "$T" >/dev/null 2>&1 || { MISSING="$T"; return 1; }; done; return 0; }   # true if every tool exists; otherwise remembers the first missing one in MISSING
has_unit() { systemctl list-unit-files "$1" 2>/dev/null | grep -q "^$1"; }   # true if the systemd service exists, meaning the software is installed
act() { if [ "$DRY" = yes ]; then echo "    (dry run) $*"; else "$@"; fi; }   # runs a command, or only prints it in dry-run mode

# Table of programs: file id | icon name | comment | script | icon file | needs a terminal window | systemd service | required tools
PROGRAMS=(
"StartVllm|Start vLLM|Start the vLLM model server (about 5 minutes to load)|vllm/vllmStart.sh|vllm/vllmStartIcon.svg|true|k3s.service|kubectl jq curl flock systemctl"
"StopVllm|Stop vLLM|Stop the vLLM model server and free the GPU memory|vllm/vllmStop.sh|vllm/vllmStopIcon.svg|true|k3s.service|kubectl jq curl flock systemctl"
"StartKubernetes|Start Kubernetes|Start k3s (Kubernetes)|kubernetes/k3sStart.sh|kubernetes/k3sStartIcon.svg|true|k3s.service|kubectl jq curl flock systemctl sudo"
"StopKubernetes|Stop Kubernetes|Stop k3s (Kubernetes) gently|kubernetes/k3sStop.sh|kubernetes/k3sStopIcon.svg|true|k3s.service|kubectl jq curl flock systemctl sudo ss"
"OpenGrafana|Open Grafana|Open the tunnel to Grafana and show the page|grafana/openGrafana.sh|grafana/grafanaIcon.svg|false|k3s.service|kubectl curl flock systemctl ss xdg-open"
"StartDocker|Start Docker|Start the Docker service and bring back the containers that were running before Stop|docker/dockerStart.sh|docker/dockerStartIcon.svg|true|docker.service|docker flock systemctl sudo"
"StopDocker|Stop Docker|Stop all Docker containers gently, then the Docker service|docker/dockerStop.sh|docker/dockerStopIcon.svg|true|docker.service|docker flock systemctl sudo"
)

echo "sparkToolset installer  (toolset: $ROOT)"; [ "$DRY" = yes ] && echo "DRY RUN: nothing will be changed"   # header line
[ "$DRY" = no ] && mkdir -p "$MENU" "$DESKTOP_DIR" "$BACKUPS"   # makes sure the target folders exist
for P in "${PROGRAMS[@]}"; do   # one pass per program
  IFS='|' read -r ID NAME COMMENT SCRIPT ICON NEEDTERM UNIT TOOLS <<< "$P"   # splits the table row into its fields
  if [ "$REMOVE" = yes ]; then   # remove mode: delete both copies of the launcher
    for F in "$MENU/$ID.desktop" "$DESKTOP_DIR/$ID.desktop"; do [ -e "$F" ] && { echo "remove   $NAME  ($F)"; act rm -f "$F"; }; done   # deletes each launcher that exists
    continue   # next program
  fi   # end of remove mode
  MISSING=""   # forgets the previous program's result
  if ! has_unit "$UNIT"; then echo "skipped  $NAME  (service $UNIT is not installed)"; continue; fi   # no software, no icon
  if ! has_tools $TOOLS; then echo "skipped  $NAME  (tool missing: $MISSING)"; continue; fi   # a needed tool is missing, so no icon
  CONTENT=$(printf '[Desktop Entry]\nType=Application\nName=%s\nComment=%s\nExec=%s\nIcon=%s\nTerminal=%s' "$NAME" "$COMMENT" "$ROOT/$SCRIPT" "$ROOT/$ICON" "$NEEDTERM")   # builds the launcher text
  TARGETS=("$MENU/$ID.desktop"); [ "$DESK" = yes ] && TARGETS+=("$DESKTOP_DIR/$ID.desktop")   # menu always, Desktop unless --no-desktop
  for F in "${TARGETS[@]}"; do   # one pass per target file
    if [ -e "$F" ] && [ "$(cat "$F")" = "$CONTENT" ]; then echo "unchanged $NAME  ($F)"; continue; fi   # identical launcher exists: nothing to do
    if [ -e "$F" ]; then echo "update   $NAME  ($F, old version backed up)"; act cp -p "$F" "$BACKUPS/$ID.$(date +%Y%m%d%H%M%S).$(basename "$(dirname "$F")").desktop"; else echo "create   $NAME  ($F)"; fi   # backs up a different existing launcher, or announces a new one
    if [ "$DRY" = no ]; then printf '%s\n' "$CONTENT" > "$F"; chmod +x "$F"; fi   # writes the launcher and makes it executable
    case "$F" in "$DESKTOP_DIR"/*) act gio set "$F" metadata::trusted true 2>/dev/null;; esac   # marks Desktop launchers as trusted so they start on a double-click
  done   # end of the target loop
done   # end of the program loop
[ "$DRY" = no ] && update-desktop-database "$MENU" 2>/dev/null   # refreshes the applications menu index
echo "done."   # last line
