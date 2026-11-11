#!/usr/bin/env python3
# sparkTerminal - a separate terminal program; it never changes GNOME Terminal or ~/.bashrc
# Steps 121-124: per-tab settings (prompt, theme, text colour, font size) with live preview,
# program defaults for new tabs (gear button), saved only in sparkTerminal's own config file,
# close button on every tab (asks first when a program is still running in it), window icon,
# copy and paste (Ctrl+Shift+C / Ctrl+Shift+V and a right-click menu inside the terminal)
# directories shown bold and italic by ls and other LS_COLORS tools (only inside sparkTerminal)
# MIT License, copyright Kodati (see LICENSE in the repo root)

import configparser  # read and write the program's own settings file
import getpass  # user name for the live preview
import os  # folders, file permissions and the user's environment
import shutil  # delete the program's private temporary folder at the end
import signal  # SIGHUP: the signal a terminal sends to its shell when the tab is closed
import socket  # host name for the live preview
import sys  # exit with a status code at the end
import time  # current date and time for the live preview

import gi  # GObject introspection: lets Python use the GTK and VTE libraries

gi.require_version("Gdk", "3.0")  # pin Gdk to 3.0 (matches GTK 3); without this PyGObject loads Gdk 4.0 first and GTK 3 fails
gi.require_version("Gtk", "3.0")  # use GTK 3 (same toolkit as the ports widget)
gi.require_version("Pango", "1.0")  # font descriptions (family and size)
gi.require_version("Vte", "2.91")  # use VTE 2.91 (the terminal engine inside GNOME Terminal, 0.76 here)

from gi.repository import Gdk, Gio, GLib, Gtk, Pango, Vte  # Gio reads GNOME settings (read only); the rest as named above

APP_TITLE = "sparkTerminal"  # window title shown in the title bar and the task bar
SHELL = "/bin/bash"  # the shell started in each tab (bash, as agreed)
CONFIG_FILE = os.path.join(GLib.get_user_config_dir(), "sparkTerminal", "settings.conf")  # ~/.config/sparkTerminal/settings.conf, only written on Apply
RUNTIME_DIR = os.path.join(GLib.get_user_runtime_dir(), f"sparkTerminal-{os.getpid()}")  # private temporary folder for this run, deleted at the end

PROMPT_STYLES = [  # (stored value, text shown in the settings box)
    ("dir", "Working directory only"),  # ~/sparkToolset$
    ("timestamp", "Date + time + directory"),  # [2026-11-10 19:57] ~/sparkToolset$
    ("datedaytime", "Date + day + time + directory"),  # [2026-11-10 Tue 19:57] ~/sparkToolset$
    ("date", "Date + directory"),  # [2026-11-10] ~/sparkToolset$
    ("dateday", "Date + day + directory"),  # [2026-11-10 Tue] ~/sparkToolset$
    ("time", "Time + directory"),  # [19:57] ~/sparkToolset$
    ("bare", "Prompt only ($)"),  # $
]  # end of the list above
PROMPT_TIME_FORMATS = {  # date/time part per style ("Tue" = short day)
    "timestamp": "%Y-%m-%d %H:%M",  # 2026-11-10 19:57
    "datedaytime": "%Y-%m-%d %a %H:%M",  # 2026-11-10 Tue 19:57
    "date": "%Y-%m-%d",  # 2026-11-10
    "dateday": "%Y-%m-%d %a",  # 2026-11-10 Tue
    "time": "%H:%M",  # 19:57
}  # end of the table above

THEMES = [("dark", "Dark"), ("light", "Light"), ("auto", "Auto (follows the GNOME light/dark setting)")]  # theme choices
BACKGROUNDS = {"dark": "#000000", "light": "#ffffff"}  # background colour per theme
TEXT_COLOURS = [("green", "Green"), ("white", "White (black on the light theme)"), ("amber", "Amber"), ("cyan", "Cyan")]  # text colour choices
TEXT_RGB = {  # text colour per theme; darker shades on the light theme so the text stays readable on white
    "dark": {"green": "#33cc33", "white": "#e6e6e6", "amber": "#ffb000", "cyan": "#00c8c8"},  # bright shades on black
    "light": {"green": "#1a7f1a", "white": "#202020", "amber": "#9a5b00", "cyan": "#007a7a"},  # dark shades on white
}  # end of the table above
FONT_SIZES = ["medium", "large"]  # only two sizes, as agreed (large = medium x 1.25)

BUILT_IN_DEFAULTS = {  # defaults agreed with the user; used when no settings file exists or Reset is pressed
    "prompt_style": "timestamp",  # date + time + directory (like the current GNOME Terminal prompt)
    "system_name": "yes",  # always prefix with user@system
    "theme": "dark",  # dark theme
    "text_colour": "green",  # green text
    "font_size": "medium",  # system monospace size
}  # end of the table above


def system_font():  # the GNOME monospace font, read only (e.g. "Monospace 12")
    try:  # GNOME settings may be missing on other desktops
        name = Gio.Settings.new("org.gnome.desktop.interface").get_string("monospace-font-name")  # read the system monospace font
    except Exception:  # schema not installed
        name = "Monospace 12"  # safe fallback
    desc = Pango.FontDescription.from_string(name)  # turn the text into a font description
    if desc.get_size() == 0:  # no size given in the setting
        desc.set_size(12 * Pango.SCALE)  # use 12 points
    return desc  # family and size of the system font


def font_points(size_name):  # size in points for "medium" or "large"
    medium = system_font().get_size() / Pango.SCALE  # system size in points (12 here)
    return medium * 1.25 if size_name == "large" else medium  # large is 25% bigger (15 here)


def gnome_prefers_dark():  # read (never change) the GNOME light/dark setting for the Auto theme
    try:  # the key does not exist on older or other desktops
        return Gio.Settings.new("org.gnome.desktop.interface").get_string("color-scheme") == "prefer-dark"  # True when GNOME is dark
    except Exception:  # setting not available
        return True  # treat as dark (the agreed default theme)


def effective_theme(settings):  # "dark" or "light" after resolving Auto
    if settings["theme"] == "auto":  # Auto follows GNOME at the moment it is applied
        return "dark" if gnome_prefers_dark() else "light"  # pick from the GNOME setting
    return settings["theme"]  # Dark or Light as chosen


def build_ps1(settings):  # bash prompt text (PS1) for the chosen style
    style = settings["prompt_style"]  # chosen prompt style
    ps1 = ""  # start empty
    if style in PROMPT_TIME_FORMATS:  # styles that show a date or time
        ps1 += "[\\D{" + PROMPT_TIME_FORMATS[style] + "}] "  # bash's \D{format} shows the time when the prompt is drawn
    if settings["system_name"] == "yes":  # system-name switch on
        ps1 += "\\u@\\h"  # user@host, e.g. alice@myhost
    if style != "bare":  # every style except "prompt only" shows the folder
        ps1 += (":" if settings["system_name"] == "yes" else "") + "\\w"  # current folder, ~ for home
    return ps1 + "\\$ "  # $ for a normal user, # for root, then a space


def sample_prompt(settings):  # the same prompt as plain text, for the live preview
    style = settings["prompt_style"]  # chosen prompt style
    text = ""  # start empty
    if style in PROMPT_TIME_FORMATS:  # styles that show a date or time
        text += "[" + time.strftime(PROMPT_TIME_FORMATS[style]) + "] "  # real current date or time
    if settings["system_name"] == "yes":  # system-name switch on
        text += getpass.getuser() + "@" + socket.gethostname().split(".")[0]  # real user and short host name (like \u@\h)
    if style != "bare":  # every style except "prompt only" shows the folder
        text += (":" if settings["system_name"] == "yes" else "") + "~/sparkToolset"  # example folder
    return text + "$ ls"  # prompt sign and an example command


def load_defaults():  # program defaults from the settings file, checked against the allowed values
    values = dict(BUILT_IN_DEFAULTS)  # start from the agreed defaults
    parser = configparser.ConfigParser()  # reader for the simple key = value file
    parser.read(CONFIG_FILE)  # a missing file is simply ignored
    if parser.has_section("defaults"):  # the file has our section
        allowed = {  # values that are accepted per key
            "prompt_style": [v for v, _ in PROMPT_STYLES],  # the six styles
            "system_name": ["yes", "no"],  # on or off
            "theme": [v for v, _ in THEMES],  # dark, light, auto
            "text_colour": [v for v, _ in TEXT_COLOURS],  # four colours
            "font_size": FONT_SIZES,  # medium, large
        }  # end of the table above
        for key, options in allowed.items():  # check every key
            value = parser.get("defaults", key, fallback=values[key])  # value from the file, or the default
            if value in options:  # only accept known values
                values[key] = value  # use the value from the file
    return values  # complete, valid settings


def save_defaults(values):  # write the program defaults to sparkTerminal's own file (nothing else is touched)
    os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)  # create ~/.config/sparkTerminal if needed
    parser = configparser.ConfigParser()  # writer for the key = value file
    parser["defaults"] = values  # one section with all settings
    with open(CONFIG_FILE, "w", encoding="utf-8") as handle:  # overwrite the file
        parser.write(handle)  # save it


def apply_look(terminal, settings):  # colours and font of one terminal widget (tab or preview)
    theme = effective_theme(settings)  # dark or light
    foreground = Gdk.RGBA()  # text colour object
    foreground.parse(TEXT_RGB[theme][settings["text_colour"]])  # chosen text colour for this theme
    background = Gdk.RGBA()  # background colour object
    background.parse(BACKGROUNDS[theme])  # black or white
    terminal.set_color_foreground(foreground)  # set the text colour
    terminal.set_color_background(background)  # set the background colour
    desc = system_font()  # start from the system monospace font
    desc.set_size(int(font_points(settings["font_size"]) * Pango.SCALE))  # medium or large size
    terminal.set_font(desc)  # set the font of this terminal only


class SparkTerminalWindow(Gtk.Window):  # the main window of the program
    def __init__(self):  # build the window when the program starts
        super().__init__(title=APP_TITLE)  # create a normal window with the program name as title
        self.set_default_size(1000, 600)  # start at 1000 x 600 pixels (resizable)
        icon_path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "sparkTerminalIcon.svg")  # icon file next to the program
        if os.path.isfile(icon_path):  # only when the icon was installed with the program
            self.set_icon_from_file(icon_path)  # show it in the title bar and the task bar
        self.tab_counter = 0  # counts tabs ever opened, used for default names and file names
        self.tabs = {}  # per tab (keyed by its scroll area): terminal widget, settings, prompt file
        self.defaults = load_defaults()  # program defaults for new tabs

        os.makedirs(RUNTIME_DIR, mode=0o700, exist_ok=True)  # private folder (only this user can read it) for the per-tab startup files

        self.notebook = Gtk.Notebook()  # tab container
        self.notebook.set_scrollable(True)  # let many tabs scroll instead of squeezing
        self.add(self.notebook)  # place the tab container inside the window

        buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=2)  # holder for the "+" and gear buttons
        plus_button = Gtk.Button.new_from_icon_name("list-add-symbolic", Gtk.IconSize.MENU)  # the "+" button with the standard add icon
        plus_button.set_relief(Gtk.ReliefStyle.NONE)  # flat look, like a tab bar button
        plus_button.set_tooltip_text("New tab: choose its name and settings (Ctrl+Shift+T)")  # plain-language hint on hover
        plus_button.connect("clicked", self.on_new_tab_clicked)  # clicking it opens the new-tab box
        gear_button = Gtk.Button.new_from_icon_name("emblem-system-symbolic", Gtk.IconSize.MENU)  # gear button for program defaults
        gear_button.set_relief(Gtk.ReliefStyle.NONE)  # flat look
        gear_button.set_tooltip_text("Default settings for new tabs (open tabs keep their own settings)")  # hint on hover
        gear_button.connect("clicked", self.on_defaults_clicked)  # clicking it opens the defaults box
        buttons.pack_start(plus_button, False, False, 0)  # "+" first
        buttons.pack_start(gear_button, False, False, 0)  # then the gear
        buttons.show_all()  # action widgets must be shown explicitly
        self.notebook.set_action_widget(buttons, Gtk.PackType.END)  # put both buttons at the right end of the tab bar

        self.connect("key-press-event", self.on_key_press)  # listen for the keyboard shortcuts
        self.connect("destroy", Gtk.main_quit)  # closing the window ends the program

        self.tab_counter += 1  # count the first tab
        self.add_tab("Shell", dict(self.defaults))  # open the first tab with the defaults, without asking

    # ---------- settings box (used for new tabs, tab settings and program defaults) ----------

    def settings_dialog(self, title, settings, reset_to, ok_label, name=None):  # returns (name, settings) or None on Cancel
        dialog = Gtk.Dialog(title=title, transient_for=self, modal=True)  # box on top of the main window
        dialog.add_buttons("Reset", 1, "Cancel", Gtk.ResponseType.CANCEL, ok_label, Gtk.ResponseType.OK)  # Reset, Cancel, Apply/Open tab
        dialog.set_default_response(Gtk.ResponseType.OK)  # Enter key means OK
        grid = Gtk.Grid(column_spacing=12, row_spacing=8, border_width=12)  # two-column layout: label, control
        dialog.get_content_area().add(grid)  # put the layout in the box
        row = 0  # current row in the layout

        name_entry = None  # name field only for tabs, not for program defaults
        if name is not None:  # a tab is being created or changed
            name_entry = Gtk.Entry(text=name, width_chars=30, activates_default=True)  # tab name field, Enter presses OK
            grid.attach(Gtk.Label(label="Tab name", xalign=0), 0, row, 1, 1)  # label
            grid.attach(name_entry, 1, row, 1, 1)  # field
            row += 1  # next row

        def combo(label_text, options, active):  # helper: a labelled drop-down list
            nonlocal row  # use the row counter of the outer function
            box = Gtk.ComboBoxText()  # drop-down list
            for value, text in options:  # add every choice
                box.append(value, text)  # stored value and visible text
            box.set_active_id(active)  # select the current value
            grid.attach(Gtk.Label(label=label_text, xalign=0), 0, row, 1, 1)  # label
            grid.attach(box, 1, row, 1, 1)  # list
            row += 1  # next row
            return box  # caller reads the choice from it

        prompt_box = combo("Prompt", PROMPT_STYLES, settings["prompt_style"])  # prompt style list
        system_check = Gtk.CheckButton(label="Always prefix with the system name (user@system)")  # system-name switch
        system_check.set_active(settings["system_name"] == "yes")  # current state
        grid.attach(system_check, 1, row, 1, 1)  # under the prompt list
        row += 1  # next row
        theme_box = combo("Theme", THEMES, settings["theme"])  # theme list
        colour_box = combo("Text colour", TEXT_COLOURS, settings["text_colour"])  # text colour list
        sizes = [(s, f"{s.capitalize()} ({font_points(s):g} pt)") for s in FONT_SIZES]  # "Medium (12 pt)", "Large (15 pt)"
        size_box = combo("Font size", sizes, settings["font_size"])  # font size list

        grid.attach(Gtk.Label(label="Preview (before Apply)", xalign=0), 0, row, 2, 1)  # preview heading
        row += 1  # next row
        preview = Vte.Terminal()  # a real terminal widget used only to show the sample; no shell runs in it
        preview.set_size_request(560, 70)  # room for the sample line
        preview.set_can_focus(False)  # it cannot be typed into
        grid.attach(preview, 0, row, 2, 1)  # full width under the controls

        def current():  # the settings currently chosen in the box
            return {  # one value per setting
                "prompt_style": prompt_box.get_active_id(),  # chosen style
                "system_name": "yes" if system_check.get_active() else "no",  # switch state
                "theme": theme_box.get_active_id(),  # chosen theme
                "text_colour": colour_box.get_active_id(),  # chosen colour
                "font_size": size_box.get_active_id(),  # chosen size
            }  # end of the table above

        def refresh(*_args):  # redraw the preview after any change
            chosen = current()  # read the controls
            apply_look(preview, chosen)  # same colour and font code as the real tabs
            preview.feed(b"\x1b[2J\x1b[H")  # clear the preview and move to the top left
            preview.feed(("\r\n " + sample_prompt(chosen)).encode("utf-8"))  # show the sample prompt line

        def set_controls(values):  # put a set of values into the controls (used by Reset)
            prompt_box.set_active_id(values["prompt_style"])  # style
            system_check.set_active(values["system_name"] == "yes")  # switch
            theme_box.set_active_id(values["theme"])  # theme
            colour_box.set_active_id(values["text_colour"])  # colour
            size_box.set_active_id(values["font_size"])  # size

        for widget in (prompt_box, theme_box, colour_box, size_box):  # every drop-down list
            widget.connect("changed", refresh)  # refresh the preview on change
        system_check.connect("toggled", refresh)  # refresh the preview when the switch changes

        dialog.show_all()  # show the box
        refresh()  # first preview
        if name_entry is not None:  # tab box
            name_entry.select_region(0, -1)  # select the name so typing replaces it
        result = None  # stays None on Cancel
        while True:  # Reset keeps the box open
            response = dialog.run()  # wait for a button
            if response == 1:  # Reset
                set_controls(reset_to)  # fill in the reset values (still needs Apply)
                continue  # keep the box open
            if response == Gtk.ResponseType.OK:  # Apply / Open tab
                new_name = name_entry.get_text().strip() if name_entry is not None else None  # typed name, if any
                result = (new_name, current())  # name and chosen settings
            break  # OK, Cancel or window closed
        dialog.destroy()  # close the box
        return result  # None means Cancel

    # ---------- tabs ----------

    def write_prompt_file(self, record):  # (re)write the tab's prompt file; the shell reads it before each prompt
        with open(record["prompt_file"], "w", encoding="utf-8") as handle:  # overwrite the file
            handle.write("PS1='" + build_ps1(record["settings"]) + "'\n")  # one line setting the prompt (contains no single quotes)

    def add_tab(self, name, settings):  # create one tab with its own bash shell and its own settings
        tab_id = self.tab_counter  # number used in the file names of this tab
        prompt_file = os.path.join(RUNTIME_DIR, f"tab{tab_id}.prompt")  # file with this tab's prompt
        rc_file = os.path.join(RUNTIME_DIR, f"tab{tab_id}.rc")  # startup file for this tab's shell
        with open(rc_file, "w", encoding="utf-8") as handle:  # write the startup file (private folder, not your home files)
            handle.write('[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"\n')  # first load your normal ~/.bashrc unchanged (read only)
            handle.write('[ -n "$LS_COLORS" ] || eval "$(dircolors -b 2>/dev/null)"\n')  # make sure ls colours exist (system defaults if ~/.bashrc set none)
            handle.write('for __sparkKey in di ow tw st; do\n')  # directory types: normal, other-writable, sticky+other-writable, sticky
            handle.write('  case ":$LS_COLORS:" in\n')  # does this directory type already have a colour?
            handle.write('    *":$__sparkKey="*) LS_COLORS=$(printf "%s" "$LS_COLORS" | sed -E "s/(^|:)($__sparkKey)=([^:]*)/\\1\\2=\\3;01;03/") ;;\n')  # yes: add bold (01) and italic (03) to its existing colour
            handle.write('    *) [ "$__sparkKey" = di ] && LS_COLORS="di=01;03;34:$LS_COLORS" ;;\n')  # no colour for normal directories: bold italic blue
            handle.write('  esac\n')  # end of the check
            handle.write('done; unset __sparkKey; export LS_COLORS\n')  # only this tab's shell gets the changed colours
            handle.write(f'__sparkPrompt() {{ [ -r "{prompt_file}" ] && . "{prompt_file}"; }}\n')  # function that loads this tab's prompt
            handle.write('PROMPT_COMMAND="__sparkPrompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}"\n')  # run it before every prompt, keeping any existing PROMPT_COMMAND

        terminal = Vte.Terminal()  # a new terminal widget for this tab
        terminal.set_scrollback_lines(10000)  # keep 10000 lines of history to scroll back
        scroller = Gtk.ScrolledWindow()  # adds a scroll bar next to the terminal
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)  # vertical scroll bar only, when needed
        scroller.add(terminal)  # put the terminal inside the scroll area

        record = {"terminal": terminal, "settings": settings, "prompt_file": prompt_file, "rc_file": rc_file, "pid": None}  # everything about this tab (pid filled in when bash starts)
        self.tabs[scroller] = record  # remember it
        self.write_prompt_file(record)  # write the tab's prompt before the shell starts
        apply_look(terminal, settings)  # colours and font of this tab

        self.notebook.append_page(scroller, self.make_tab_label(name, scroller, record))  # add the tab with its clickable title and close button
        self.notebook.set_tab_reorderable(scroller, True)  # tabs can be dragged into another order

        terminal.spawn_async(  # start bash inside this terminal, without blocking the window
            Vte.PtyFlags.DEFAULT,  # normal pseudo-terminal settings
            os.environ.get("HOME", "/"),  # start in the home folder
            [SHELL, "--rcfile", rc_file],  # bash with this tab's startup file (which loads ~/.bashrc first)
            None,  # keep the user's own environment variables
            GLib.SpawnFlags.DEFAULT,  # normal start flags
            None,  # no setup function before the shell starts
            None,  # no data for that setup function
            -1,  # no time limit for starting
            None,  # no way to cancel the start
            self.on_shell_started,  # called when bash has started, to remember its process number
            record,  # this tab's information, passed to that function
        )  # end of the start command

        terminal.connect("child-exited", self.on_shell_exited, scroller)  # when bash ends (e.g. "exit"), close its tab
        terminal.connect("button-press-event", self.on_terminal_clicked)  # right-click inside the terminal opens Copy/Paste/Select all
        self.show_all()  # make the new tab and its widgets visible
        self.notebook.set_current_page(self.notebook.page_num(scroller))  # switch to the new tab
        terminal.grab_focus()  # put the keyboard cursor in the terminal so you can type at once

    def on_shell_started(self, _terminal, pid, _error, record):  # bash has started (or failed to start)
        if pid and pid > 0:  # a real process number
            record["pid"] = pid  # remember it, used to check for running programs and to close the tab

    def make_tab_label(self, name, scroller, record):  # tab title with click handling and a close button
        label = Gtk.Label(label=name)  # the visible tab text
        record["label"] = label  # remember the label so it can be renamed later
        event_box = Gtk.EventBox()  # a plain label cannot receive clicks, an EventBox around it can
        event_box.set_visible_window(False)  # keep the tab's normal look
        event_box.add(label)  # put the text inside the click area
        event_box.set_tooltip_text("Double-click to rename; right-click for rename, tab settings or close")  # hint on hover
        event_box.connect("button-press-event", self.on_tab_label_clicked, scroller)  # handle the mouse clicks
        close_button = Gtk.Button.new_from_icon_name("window-close-symbolic", Gtk.IconSize.MENU)  # small x button
        close_button.set_relief(Gtk.ReliefStyle.NONE)  # flat look, like other tab close buttons
        close_button.set_focus_on_click(False)  # clicking it does not take the keyboard away from the terminal
        close_button.set_tooltip_text("Close this tab (Ctrl+Shift+W)")  # hint on hover
        close_button.connect("clicked", lambda _b: self.close_tab(scroller))  # clicking it closes this tab
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)  # name and x side by side
        box.pack_start(event_box, True, True, 0)  # name on the left
        box.pack_start(close_button, False, False, 0)  # x on the right
        box.show_all()  # make both visible
        return box  # used as the tab's title widget

    def tab_label(self, scroller):  # the Gtk.Label of a tab
        return self.tabs[scroller]["label"]  # label remembered when the tab was made

    def current_scroller(self):  # the tab in front, or None
        page = self.notebook.get_current_page()  # index of the tab in front (-1 if none)
        return self.notebook.get_nth_page(page) if page >= 0 else None  # its scroll area

    def on_tab_label_clicked(self, _widget, event, scroller):  # mouse click on a tab title
        if event.type == Gdk.EventType._2BUTTON_PRESS and event.button == 1:  # left double-click
            self.rename_tab(scroller)  # open the rename box
            return True  # click handled
        if event.type == Gdk.EventType.BUTTON_PRESS and event.button == 3:  # right-click
            menu = Gtk.Menu()  # small pop-up menu
            rename_item = Gtk.MenuItem(label="Rename tab…")  # first entry
            rename_item.connect("activate", lambda _i: self.rename_tab(scroller))  # opens the rename box
            settings_item = Gtk.MenuItem(label="Tab settings…")  # second entry
            settings_item.connect("activate", lambda _i: self.tab_settings(scroller))  # opens the tab settings box
            menu.append(rename_item)  # add the first entry
            menu.append(settings_item)  # add the second entry
            close_item = Gtk.MenuItem(label="Close tab")  # third entry
            close_item.connect("activate", lambda _i: self.close_tab(scroller))  # closes this tab
            menu.append(close_item)  # add the third entry
            menu.show_all()  # make the entries visible
            menu.popup_at_pointer(event)  # show the menu where the mouse is
            return True  # click handled
        return False  # other clicks: normal behaviour (a single click switches tab)

    def rename_tab(self, scroller=None):  # quick rename (name only)
        scroller = scroller or self.current_scroller()  # the given tab, or the one in front
        if scroller is None:  # no tab at all
            return  # nothing to rename
        dialog = Gtk.Dialog(title="Rename tab", transient_for=self, modal=True)  # small box on top of the window
        dialog.add_buttons("Cancel", Gtk.ResponseType.CANCEL, "OK", Gtk.ResponseType.OK)  # Cancel and OK buttons
        dialog.set_default_response(Gtk.ResponseType.OK)  # Enter key means OK
        entry = Gtk.Entry(text=self.tab_label(scroller).get_text(), width_chars=30, activates_default=True)  # current name, Enter presses OK
        box = dialog.get_content_area()  # area above the buttons
        box.set_border_width(10)  # margin
        box.add(entry)  # the name field
        dialog.show_all()  # show the box
        entry.select_region(0, -1)  # select the name so typing replaces it
        response = dialog.run()  # wait for a button
        name = entry.get_text().strip()  # typed name without spaces at the ends
        dialog.destroy()  # close the box
        if response == Gtk.ResponseType.OK and name:  # OK with a non-empty name (Cancel or empty keeps the old name)
            self.tab_label(scroller).set_text(name)  # show the new name

    def tab_settings(self, scroller=None):  # change the name and settings of one tab only
        scroller = scroller or self.current_scroller()  # the given tab, or the one in front
        if scroller is None:  # no tab at all
            return  # nothing to change
        record = self.tabs[scroller]  # this tab's information
        result = self.settings_dialog("Tab settings", record["settings"], self.defaults, "Apply", self.tab_label(scroller).get_text())  # Reset = program defaults
        if result is None:  # Cancel
            return  # nothing changes
        name, settings = result  # chosen name and settings
        if name:  # empty name keeps the old one
            self.tab_label(scroller).set_text(name)  # new tab name
        record["settings"] = settings  # remember the new settings for this tab
        apply_look(record["terminal"], settings)  # colours and font change at once
        self.write_prompt_file(record)  # the prompt changes at the next prompt (press Enter)

    def on_new_tab_clicked(self, _button=None):  # "+" button or Ctrl+Shift+T
        suggested = f"Shell {self.tab_counter + 1}"  # suggested name
        result = self.settings_dialog("New tab", self.defaults, self.defaults, "Open tab", suggested)  # name + settings, starting from the defaults
        if result is None:  # Cancel
            return  # no tab is created
        name, settings = result  # chosen name and settings
        self.tab_counter += 1  # count the new tab
        self.add_tab(name or suggested, settings)  # empty name falls back to the suggestion

    def on_defaults_clicked(self, _button=None):  # gear button: defaults for new tabs
        result = self.settings_dialog("Default settings for new tabs", self.defaults, BUILT_IN_DEFAULTS, "Apply")  # Reset = agreed built-in defaults
        if result is None:  # Cancel
            return  # nothing changes
        self.defaults = result[1]  # new defaults (open tabs keep their own settings)
        save_defaults(self.defaults)  # save to ~/.config/sparkTerminal/settings.conf

    def current_terminal(self):  # the terminal widget of the tab in front, or None
        scroller = self.current_scroller()  # the tab in front
        record = self.tabs.get(scroller) if scroller is not None else None  # its information
        return record["terminal"] if record else None  # its terminal widget

    def copy_text(self, terminal):  # copy the selected text to the clipboard
        if terminal is not None and terminal.get_has_selection():  # only when some text is selected
            terminal.copy_clipboard_format(Vte.Format.TEXT)  # put the selection on the clipboard as plain text

    def paste_text(self, terminal):  # paste the clipboard into the terminal (as if typed)
        if terminal is not None:  # a tab exists
            terminal.paste_clipboard()  # VTE inserts the clipboard text at the prompt

    def on_terminal_clicked(self, terminal, event):  # mouse click inside a terminal
        if event.type != Gdk.EventType.BUTTON_PRESS or event.button != 3:  # only a single right-click
            return False  # left/middle clicks keep their normal behaviour (select, middle-click paste)
        menu = Gtk.Menu()  # small pop-up menu
        copy_item = Gtk.MenuItem(label="Copy (Ctrl+Shift+C)")  # first entry
        copy_item.set_sensitive(terminal.get_has_selection())  # greyed out when nothing is selected
        copy_item.connect("activate", lambda _i: self.copy_text(terminal))  # copies the selection
        paste_item = Gtk.MenuItem(label="Paste (Ctrl+Shift+V)")  # second entry
        paste_item.connect("activate", lambda _i: self.paste_text(terminal))  # pastes the clipboard
        select_item = Gtk.MenuItem(label="Select all")  # third entry
        select_item.connect("activate", lambda _i: terminal.select_all())  # selects all text in this tab
        for item in (copy_item, paste_item, select_item):  # every entry
            menu.append(item)  # add it to the menu
        menu.show_all()  # make the entries visible
        menu.popup_at_pointer(event)  # show the menu where the mouse is
        return True  # click handled (the terminal does not receive it)

    def on_key_press(self, _widget, event):  # keyboard shortcuts of the window
        ctrl_shift = Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.SHIFT_MASK  # Ctrl and Shift held together
        if (event.state & ctrl_shift) == ctrl_shift:  # only react when both are held
            key = Gdk.keyval_name(event.keyval).lower()  # name of the pressed key, lower case
            if key == "t":  # Ctrl+Shift+T
                self.on_new_tab_clicked()  # new tab box
                return True  # shortcut handled, not sent to the shell
            if key == "r":  # Ctrl+Shift+R
                self.rename_tab()  # rename the tab in front
                return True  # shortcut handled, not sent to the shell
            if key == "c":  # Ctrl+Shift+C
                self.copy_text(self.current_terminal())  # copy the selection of the tab in front
                return True  # shortcut handled, not sent to the shell
            if key == "v":  # Ctrl+Shift+V
                self.paste_text(self.current_terminal())  # paste into the tab in front
                return True  # shortcut handled, not sent to the shell
            if key == "w":  # Ctrl+Shift+W
                scroller = self.current_scroller()  # the tab in front
                if scroller is not None:  # there is one
                    self.close_tab(scroller)  # close it
                return True  # shortcut handled, not sent to the shell
        return False  # every other key goes to the shell as normal

    def program_running(self, record):  # True when a program (not just the prompt) runs in the tab
        try:  # the terminal may already be closing
            group = os.tcgetpgrp(record["terminal"].get_pty().get_fd())  # process group that currently owns the keyboard of this tab
        except Exception:  # no terminal device any more
            return False  # nothing to protect
        return record["pid"] is not None and group != record["pid"]  # owner is not bash itself, so a program is running

    def close_tab(self, scroller):  # close one tab (x button, right-click menu or Ctrl+Shift+W)
        record = self.tabs.get(scroller)  # this tab's information
        if record is None:  # already closed
            return  # nothing to do
        if self.program_running(record):  # something is still running in it
            dialog = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.WARNING,  # warning box on top of the window
                                       buttons=Gtk.ButtonsType.OK_CANCEL,  # OK and Cancel buttons
                                       text=f"Close tab \"{record['label'].get_text()}\"?")  # question with the tab name
            dialog.format_secondary_text("A program is still running in this tab. Closing the tab stops it.")  # plain-language explanation
            response = dialog.run()  # wait for a button
            dialog.destroy()  # close the box
            if response != Gtk.ResponseType.OK:  # Cancel or closed
                return  # keep the tab
        if record["pid"] is not None:  # bash was started
            try:  # bash may already have ended
                os.kill(record["pid"], signal.SIGHUP)  # same signal a normal terminal sends when a tab is closed
            except OSError:  # process already gone
                pass  # nothing to do
        self.on_shell_exited(None, 0, scroller)  # remove the tab and its private files now

    def on_shell_exited(self, _terminal, _status, scroller):  # called when the shell in a tab ends, or by close_tab
        if scroller not in self.tabs:  # already removed (e.g. closed with the x, then bash reported its end)
            return  # nothing more to do
        record = self.tabs.pop(scroller, None)  # forget the tab
        if record:  # it was known
            for path in (record["prompt_file"], record["rc_file"]):  # its two private files
                try:  # the file may already be gone
                    os.remove(path)  # delete it
                except OSError:  # missing file
                    pass  # nothing to do
        self.notebook.remove_page(self.notebook.page_num(scroller))  # remove that tab
        if self.notebook.get_n_pages() == 0:  # if no tabs are left
            Gtk.main_quit()  # close the program


def main():  # program entry point
    window = SparkTerminalWindow()  # build the window
    window.show_all()  # show it on screen
    try:  # make sure the private folder is removed however the program ends
        Gtk.main()  # run until the window is closed
    finally:  # always runs
        shutil.rmtree(RUNTIME_DIR, ignore_errors=True)  # delete this run's temporary startup files
    return 0  # normal exit status


if __name__ == "__main__":  # only run when started directly, not when imported
    sys.exit(main())  # start the program and pass its exit status to the system
