#!/usr/bin/env bash
# uninstallSparkTerminal.sh - removes sparkTerminal installed by installSparkTerminal.sh
# Moves to the Trash (restorable): only the files the installer copied, the Desktop icon and the menu entry.
# Keeps your settings (~/.config/sparkTerminal). Never uses sudo and never touches other programs or launchers.
# Works from the repo's terminal/ folder or from the installed program folder (the installer copies it there).
# Options: --dry-run (show what would happen), --help
# MIT License, copyright Kodati (see LICENSE)

set -euo pipefail  # stop on errors, on unset variables and on failures inside pipes

main() {  # everything runs inside a function, so bash has read the whole script before this file moves to the Trash
    local APP="sparkTerminal"  # program name used in file names
    local STATE_DIR="$HOME/.local/state/$APP"  # where the installer keeps its record and backups
    local RECORD_FILE="$STATE_DIR/installPath"  # the installed program folder, written by the installer
    local MENU_FILE="$HOME/.local/share/applications/$APP.desktop"  # applications-menu entry
    local DESKTOP_DIR  # the Desktop folder
    DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"  # also works with translated folder names
    local DESKTOP_FILE="$DESKTOP_DIR/$APP.desktop"  # Desktop icon
    local FILES=("sparkTerminal.py" "sparkTerminalIcon.svg" "uninstallSparkTerminal.sh" "LICENSE")  # files the installer copies
    local DRY_RUN=0  # 1 = only show the actions

    while [ $# -gt 0 ]; do  # read the options
        case "$1" in  # which option
            --dry-run) DRY_RUN=1 ;;  # preview only
            -h|--help) echo "Usage: $0 [--dry-run] [--help]"; return 0 ;;  # help
            *) echo "Unknown option: $1 (use --help)"; return 2 ;;  # anything else is an error
        esac  # end of the option check
        shift  # next option
    done  # all options read

    run() { if [ "$DRY_RUN" -eq 1 ]; then echo "  [dry run] $*"; else "$@"; fi; }  # run a command, or only show it in a dry run
    has_gui() { command -v zenity >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; }  # zenity present and a screen available

    if [ ! -f "$RECORD_FILE" ]; then  # no record: not installed with the installer (or already removed)
        echo "No install record found ($RECORD_FILE); nothing to remove."  # explain
        return 0  # nothing changed
    fi  # end of the record check
    local target  # installed program folder
    target="$(cat "$RECORD_FILE")"  # read the recorded folder
    case "$target" in /*/"$APP") ;; *) echo "Install record looks wrong ($target); stopping without changes."; return 1 ;; esac  # must be a full path ending in /sparkTerminal

    local items=()  # everything that will go to the Trash
    local f  # loop variable
    for f in "${FILES[@]}"; do [ -e "$target/$f" ] && items+=("$target/$f"); done  # installed files that still exist
    [ -e "$DESKTOP_FILE" ] && items+=("$DESKTOP_FILE")  # Desktop icon, if present
    [ -e "$MENU_FILE" ] && items+=("$MENU_FILE")  # menu entry, if present

    echo "Will move to the Trash (restorable):"  # heading
    if [ ${#items[@]} -eq 0 ]; then echo "  (nothing left to remove)"; else printf '  %s\n' "${items[@]}"; fi  # the list
    echo "Kept: your settings in $HOME/.config/$APP (delete that folder yourself if you no longer want them)"  # settings stay

    local question="Remove $APP from $target?"  # confirmation text
    if [ "$DRY_RUN" -eq 1 ]; then  # a dry run never asks
        echo "  [dry run] would ask: $question"  # show the question
    elif has_gui; then  # window available
        zenity --question --title="$APP uninstaller" --width=520 --text="$question" 2>/dev/null || { echo "Cancelled, nothing changed."; return 0; }  # OK/Cancel window
    else  # terminal only
        local answer  # typed answer
        read -r -p "$question [y/N] " answer  # ask in the terminal
        [ "$answer" = "y" ] || [ "$answer" = "Y" ] || { echo "Cancelled, nothing changed."; return 0; }  # only y or Y continues
    fi  # end of the confirmation

    for f in "${items[@]}"; do run gio trash "$f"; done  # move each item to the Trash
    if [ "$DRY_RUN" -eq 0 ] && [ -d "$target" ] && [ -z "$(ls -A "$target")" ]; then rmdir "$target"; fi  # remove the folder only when it is now empty
    run rm -f "$RECORD_FILE"  # forget the install location (backups in $STATE_DIR/backups are kept)

    if [ "$DRY_RUN" -eq 1 ]; then echo "Dry run finished: nothing was changed."; return 0; fi  # a dry run reports honestly
    echo "Done: $APP removed (files are in the Trash and can be restored)."  # final message
}  # end of the function

main "$@"  # run it with the given options
