#!/usr/bin/env bash
# installSparkTerminal.sh - installs sparkTerminal into a folder you choose, plus a Desktop icon and a menu entry
# It touches only: the chosen program folder, ~/Desktop/sparkTerminal.desktop,
# ~/.local/share/applications/sparkTerminal.desktop and ~/.local/state/sparkTerminal (install record, backups).
# It never uses sudo, never installs system packages and never changes other programs or launchers.
# Options: --dry-run (show what would happen), --remove (runs uninstallSparkTerminal.sh), --folder DIR (skip the folder picker), --help
# MIT License, copyright Kodati (see LICENSE in the repo root)

set -euo pipefail  # stop on errors, on unset variables and on failures inside pipes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # folder of this installer (the repo's terminal/ folder)
REPO_DIR="$(dirname "$SCRIPT_DIR")"  # repo root, where LICENSE lives
APP="sparkTerminal"  # program name used in file names
DEFAULT_PARENT="$HOME/.local/share"  # suggested parent folder; the program goes into <parent>/sparkTerminal
STATE_DIR="$HOME/.local/state/$APP"  # install record and backups of replaced files
RECORD_FILE="$STATE_DIR/installPath"  # remembers where the program was installed (used by --remove)
MENU_FILE="$HOME/.local/share/applications/$APP.desktop"  # applications-menu entry
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"  # the Desktop folder (also works with translated names)
DESKTOP_FILE="$DESKTOP_DIR/$APP.desktop"  # Desktop icon
PROGRAM_FILES=("sparkTerminal.py" "sparkTerminalIcon.svg" "uninstallSparkTerminal.sh")  # files copied from terminal/ (the uninstaller too)
STAMP="$(date +%Y%m%d-%H%M%S)"  # time stamp for backup folder names

DRY_RUN=0  # 1 = only show the actions
REMOVE=0  # 1 = uninstall
FOLDER_ARG=""  # folder given with --folder, empty = ask

say() { printf '%s\n' "$*"; }  # print one line
run() { if [ "$DRY_RUN" -eq 1 ]; then say "  [dry run] $*"; else "$@"; fi; }  # run a command, or only show it in a dry run
has_gui() { command -v zenity >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; }  # zenity present and a screen available

confirm() {  # ask yes/no; returns 0 for yes
    local question="$1"  # the question text
    if [ "$DRY_RUN" -eq 1 ]; then say "  [dry run] would ask: $question"; return 0; fi  # a dry run never blocks
    if has_gui; then zenity --question --title="$APP installer" --width=520 --text="$question"; return $?; fi  # window question
    local answer  # typed answer
    read -r -p "$question [y/N] " answer  # ask in the terminal
    [ "$answer" = "y" ] || [ "$answer" = "Y" ]  # only y or Y means yes
}  # end of the function

usage() {  # help text
    say "Usage: $0 [--dry-run] [--remove] [--folder DIR] [--help]"  # syntax
    say "  (no option)   choose a parent folder; the program goes into <parent>/$APP"  # normal install
    say "  --folder DIR  use DIR as the parent folder without asking"  # non-interactive folder
    say "  --dry-run     show what would be done, change nothing"  # preview
    say "  --remove      move the installed files, the Desktop icon and the menu entry to the Trash"  # uninstall
}  # end of the function

while [ $# -gt 0 ]; do  # read the options
    case "$1" in  # which option
        --dry-run) DRY_RUN=1 ;;  # preview only
        --remove) REMOVE=1 ;;  # uninstall
        --folder) FOLDER_ARG="${2:-}"; shift ;;  # parent folder given on the command line
        -h|--help) usage; exit 0 ;;  # help
        *) say "Unknown option: $1"; usage; exit 2 ;;  # anything else is an error
    esac  # end of the option check
    shift  # next option
done  # all options read

check_requirements() {  # stop with a clear message when software is missing (nothing is installed automatically)
    local missing=()  # list of missing items
    command -v python3 >/dev/null 2>&1 || missing+=("python3 (Ubuntu package: python3)")  # Python 3
    if command -v python3 >/dev/null 2>&1; then  # only test the libraries when Python exists
        python3 -c "import gi; gi.require_version('Gtk','3.0'); from gi.repository import Gtk" >/dev/null 2>&1 || missing+=("Python GTK 3 (Ubuntu packages: python3-gi gir1.2-gtk-3.0)")  # GTK 3 for Python
        python3 -c "import gi; gi.require_version('Vte','2.91'); from gi.repository import Vte" >/dev/null 2>&1 || missing+=("VTE terminal widget (Ubuntu package: gir1.2-vte-2.91)")  # VTE for Python
    fi  # end of the library tests
    if [ ${#missing[@]} -gt 0 ]; then  # something is missing
        say "Cannot install $APP; missing software:"  # heading
        printf '  - %s\n' "${missing[@]}"  # one line per missing item
        say "Install it with your package manager (free Ubuntu packages), then run this installer again."  # what to do
        exit 1  # stop without changing anything
    fi  # end of the missing check
}  # end of the function

backup() {  # move an existing file or folder into the backup folder before it is replaced
    local path="$1"  # what to back up
    [ -e "$path" ] || return 0  # nothing there, nothing to do
    local dest="$STATE_DIR/backups/$STAMP"  # this run's backup folder
    say "  backing up existing $path -> $dest/"  # tell the user
    run mkdir -p "$dest"  # create the backup folder
    run mv "$path" "$dest/"  # move the old item there
}  # end of the function

write_desktop_entry() {  # write one launcher file (menu or Desktop)
    local file="$1" target="$2"  # launcher path and program folder
    say "  writing $file"  # tell the user
    [ "$DRY_RUN" -eq 1 ] && return 0  # a dry run stops here
    mkdir -p "$(dirname "$file")"  # make sure the folder exists
    cat > "$file" <<EOF
[Desktop Entry]
Type=Application
Name=$APP
Comment=Terminal with named tabs, per-tab prompt, theme, colour and font settings
Exec="$target/sparkTerminal.py"
Icon=$target/sparkTerminalIcon.svg
Terminal=false
Categories=System;TerminalEmulator;
EOF
    chmod +x "$file"  # launchers must be executable to start from the Desktop
}  # end of the function

do_remove() {  # uninstall: handled by the separate uninstaller, so there is only one remove logic
    local args=()  # options passed on
    [ "$DRY_RUN" -eq 1 ] && args+=("--dry-run")  # keep the dry-run choice
    exec "$SCRIPT_DIR/uninstallSparkTerminal.sh" "${args[@]}"  # hand over to the uninstaller
}  # end of the function

choose_parent() {  # pick the parent folder (folder picker window, or typed in the terminal)
    if [ -n "$FOLDER_ARG" ]; then printf '%s' "$FOLDER_ARG"; return; fi  # given with --folder
    if [ "$DRY_RUN" -eq 1 ]; then printf '%s' "$DEFAULT_PARENT"; return; fi  # a dry run uses the suggestion
    if has_gui; then  # window available
        zenity --file-selection --directory --title="$APP installer: choose the parent folder (the program goes into <folder>/$APP)" --filename="$DEFAULT_PARENT/"  # folder picker starting at the suggestion
        return  # the picked folder was printed by zenity (Cancel gives an empty answer)
    fi  # end of the window case
    local answer  # typed folder
    read -r -e -i "$DEFAULT_PARENT" -p "Parent folder (the program goes into <folder>/$APP): " answer  # editable suggestion
    printf '%s' "$answer"  # return it
}  # end of the function

do_install() {  # copy the program, then create the launchers
    check_requirements  # stop early when software is missing
    for f in "${PROGRAM_FILES[@]}"; do [ -f "$SCRIPT_DIR/$f" ] || { say "Missing $SCRIPT_DIR/$f (run the installer from the repo's terminal folder)."; exit 1; }; done  # source files present
    [ -f "$REPO_DIR/LICENSE" ] || { say "Missing $REPO_DIR/LICENSE."; exit 1; }  # licence file present

    local parent  # chosen parent folder
    parent="$(choose_parent)" || true  # Cancel in the picker is handled below
    if [ -z "$parent" ]; then say "Cancelled, nothing changed."; exit 0; fi  # no folder chosen
    parent="${parent/#\~/$HOME}"  # expand a leading ~ typed by hand
    case "$parent" in /*) ;; *) say "Please give a full path starting with / (got: $parent)."; exit 1 ;; esac  # absolute paths only
    case "$parent" in *'"'*|*'`'*|*'$'*|*'\'*) say "The folder name must not contain \" \` \$ or \\ (launcher files cannot quote them safely)."; exit 1 ;; esac  # unsafe characters
    local target="${parent%/}/$APP"  # final program folder
    case "$target/" in "$SCRIPT_DIR/"*|"$REPO_DIR/"*) say "Choose a folder outside the repo ($REPO_DIR)."; exit 1 ;; esac  # never install into the source folder
    local probe="$parent"  # find the nearest existing folder to test write permission
    while [ ! -d "$probe" ]; do probe="$(dirname "$probe")"; done  # walk up until a folder exists
    [ -w "$probe" ] || { say "No write permission in $probe (this installer never uses sudo; choose a folder in your home)."; exit 1; }  # must be writable without admin rights

    say "Plan:"  # summary before anything changes
    say "  program folder : $target"  # where the program goes
    say "  uninstaller    : $target/uninstallSparkTerminal.sh"  # how to remove it later
    say "  Desktop icon   : $DESKTOP_FILE"  # Desktop launcher
    say "  menu entry     : $MENU_FILE"  # menu launcher
    say "  install record : $RECORD_FILE"  # where the location is remembered
    confirm "Install $APP into $target and create the Desktop icon and menu entry?" || { say "Cancelled, nothing changed."; exit 0; }  # ask first

    if [ -e "$target/sparkTerminal.py" ]; then backup "$target"; fi  # an older install in the same place is kept as a backup
    run mkdir -p "$target"  # create the program folder
    for f in "${PROGRAM_FILES[@]}"; do run cp "$SCRIPT_DIR/$f" "$target/$f"; done  # copy program and icon
    run cp "$REPO_DIR/LICENSE" "$target/LICENSE"  # copy the licence (MIT requires it with copies)
    run chmod 755 "$target/sparkTerminal.py" "$target/uninstallSparkTerminal.sh"  # make the program and the uninstaller runnable
    backup "$MENU_FILE"  # keep an existing menu entry as a backup
    write_desktop_entry "$MENU_FILE" "$target"  # new menu entry
    backup "$DESKTOP_FILE"  # keep an existing Desktop icon as a backup
    write_desktop_entry "$DESKTOP_FILE" "$target"  # new Desktop icon
    run gio set "$DESKTOP_FILE" metadata::trusted true || true  # mark the Desktop icon as trusted so GNOME allows launching (may need a right-click "Allow Launching" on some setups)
    run mkdir -p "$STATE_DIR"  # folder for the install record
    if [ "$DRY_RUN" -eq 1 ]; then say "  [dry run] would record $target in $RECORD_FILE"; else printf '%s\n' "$target" > "$RECORD_FILE"; fi  # remember the location for --remove
    if [ "$DRY_RUN" -eq 1 ]; then say "Dry run finished: nothing was changed."; return 0; fi  # a dry run reports honestly
    say "Done: $APP installed in $target. Start it from the Desktop icon or the applications menu."  # final message
}  # end of the function

if [ "$REMOVE" -eq 1 ]; then do_remove; else do_install; fi  # run the chosen action
