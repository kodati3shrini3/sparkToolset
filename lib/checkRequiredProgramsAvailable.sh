#!/bin/bash
# checkRequiredProgramsAvailable.sh: shared check that the software a sparkToolset program needs is installed (sourced by the programs, not run on its own)

# hint_for TOOL: prints how to install a missing tool (apt package on Ubuntu / DGX OS, or the official page)
hint_for() {
  case "$1" in   # chooses the hint by tool name
    kubectl) echo "kubectl: https://kubernetes.io/docs/tasks/tools/ (the k3s installer also provides it: https://docs.k3s.io/quick-start)";;   # kubectl is not in the default apt sources
    k3s) echo "k3s (Kubernetes): https://docs.k3s.io/quick-start";;   # Kubernetes service used by the Kubernetes and vLLM programs
    docker) echo "docker: https://docs.docker.com/engine/install/ubuntu/";;   # Docker Engine and the compose plugin
    helm) echo "helm: https://helm.sh/docs/intro/install/";;   # only needed to install models, not by the start/stop programs
    jq) echo "jq: sudo apt install jq";;   # reads model information from JSON
    curl) echo "curl: sudo apt install curl";;   # checks that services answer
    zenity) echo "zenity (dialog windows): sudo apt install zenity";;   # question and message windows
    notify-send) echo "notify-send (desktop notices): sudo apt install libnotify-bin";;   # the package that provides notify-send
    flock) echo "flock: sudo apt install util-linux";;   # prevents two actions from running at once
    ss) echo "ss: sudo apt install iproute2";;   # finds which program listens on a port
    xdg-open) echo "xdg-open: sudo apt install xdg-utils";;   # opens the browser
    *) echo "$1: please install it";;   # any tool without a specific hint
  esac
}

# require_tools PROGRAM TOOL...: returns 0 if every tool exists; otherwise shows what is missing and returns 1
require_tools() {
  local PROG="$1"; shift   # first argument is the program name used in the message; the rest are tool names
  local MISSING="" T   # list of missing tools and the loop variable
  for T in "$@"; do command -v "$T" >/dev/null 2>&1 || MISSING+="$T "; done   # collects every tool that is not found on the PATH
  [ -z "$MISSING" ] && return 0   # nothing missing: the program may continue
  local MSG="$PROG cannot start. This software is not installed:"$'\n'   # first line of the message
  for T in $MISSING; do MSG+=$'\n'"  - $(hint_for "$T")"; done   # adds one install hint per missing tool
  echo "$MSG" >&2   # always prints to the terminal
  command -v zenity >/dev/null 2>&1 && zenity --error --title="$PROG" --width=560 --text="$MSG" 2>/dev/null   # also shows a window, needed when the program is started from an icon without a terminal
  return 1   # tells the calling program to stop
}

# notify-send is optional: without it, desktop notices are printed in the terminal instead of stopping the program
if ! command -v notify-send >/dev/null 2>&1; then   # runs only when notify-send is not installed
  notify-send() { echo "[notice] $*"; }   # stand-in function that prints the notice text
fi
