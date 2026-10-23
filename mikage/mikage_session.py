# Runs one Ren'Py game inside Mikage. The bridge (MikageRenPyRuntime.mm)
# imports this module on the engine stack and calls run(); _mikage is the
# bridge's own built-in module.

import os
import sys

import _mikage


class _LogWriter(object):
    """
    Sends what Ren'Py prints to Mikage's log, one line at a time.
    """

    encoding = "utf-8"
    errors = "replace"

    def __init__(self, level):
        self.level = level
        self.buffer = ""

    def write(self, s):
        if not isinstance(s, str):
            s = str(s)

        lines = (self.buffer + s).split("\n")
        self.buffer = lines.pop()

        for line in lines:
            if line:
                _mikage.log(self.level, line)

        return len(s)

    def flush(self):
        if self.buffer:
            _mikage.log(self.level, self.buffer)
            self.buffer = ""

    def isatty(self):
        return False

    def writable(self):
        return True


def run(renpy_base, basedir, savedir):
    """
    Runs renpy.py for the game in `basedir`, saving to `savedir`. Returns the
    exit status Ren'Py ends with.
    """

    sys.stdout = _LogWriter(3)
    sys.stderr = _LogWriter(4)

    script = os.path.join(renpy_base, "renpy.py")
    sys.argv = [script, basedir, "--savedir", savedir]

    import runpy

    try:
        runpy.run_path(script, run_name="__main__")
    except SystemExit as e:
        code = e.code

        if code is None:
            return 0
        if isinstance(code, int):
            return code

        print(code, file=sys.stderr)
        return 1
    finally:
        sys.stdout.flush()
        sys.stderr.flush()

    return 0


def prepare_quit():
    """
    Called when Mikage asks the game to quit, before the quit event arrives:
    the game ends without asking "Are you sure you want to quit?".
    """

    try:
        import renpy

        if renpy.store is not None:
            renpy.store._confirm_quit = False
    except Exception:
        pass


# Mikage's quick actions and game menu. Each command the game's own UI
# would run is bound to a spare key (F13 and up) in a keymap under every
# screen, and Mikage presses that key: the action then runs inside Ren'Py's
# event handling, exactly as if the game's button were clicked. These
# numbers match MikageRenPyCommand.

_KEYS = {
    1: "K_F13",  # auto
    2: "K_F14",  # skip
    3: "K_F15",  # quick save
    4: "K_F16",  # quick load
    5: "K_F17",  # backlog
    6: "K_F18",  # save
    7: "K_F19",  # load
}

_keymap_installed = False

# The skip_unseen preference from before Ctrl was held, or None.
_held_skip_unseen = None


def _in_game():
    import renpy

    try:
        return not renpy.store.main_menu and not renpy.game.context().init_phase
    except Exception:
        return False


def _show_menu(screen):
    import renpy

    def run():
        if _in_game() and renpy.exports.has_screen(screen):
            renpy.store.ShowMenu(screen)()

    return run


def _toggle_auto():
    import renpy

    prefs = renpy.game.preferences
    if not prefs.afm_enable and renpy.config.skipping:
        renpy.config.skipping = None
    prefs.afm_enable = not prefs.afm_enable
    renpy.exports.restart_interaction()


def _toggle_skip():
    import renpy

    if not renpy.config.skipping:
        renpy.game.preferences.afm_enable = False
    # The game's own Skip action, which also stops it: it follows the "skip
    # unseen text" preference and the game's rules for where skipping runs.
    renpy.store.Skip()()


def _quick_save():
    import renpy

    if _in_game():
        renpy.store.QuickSave()()


def _quick_load():
    import renpy

    if _in_game():
        renpy.store.QuickLoad(confirm=False)()


def install_keymap():
    """
    Binds Mikage's keys, once. Called before the bridge first presses one.
    """

    global _keymap_installed

    import renpy

    if not _keymap_installed:
        actions = {
            1: _toggle_auto,
            2: _toggle_skip,
            3: _quick_save,
            4: _quick_load,
            5: _show_menu("history"),
            6: _show_menu("save"),
            7: _show_menu("load"),
        }

        bindings = {}
        for number, key in _KEYS.items():
            name = "mikage_%d" % number
            renpy.config.keymap[name] = [key]
            bindings[name] = actions[number]

        renpy.config.underlay.append(renpy.display.behavior.Keymap(**bindings))
        renpy.display.behavior.clear_keymap_cache()
        renpy.exports.restart_interaction()
        _keymap_installed = True


def set_control_skip(held):
    """
    Holds or releases Ctrl as a quick action: unlike the game's own Ctrl,
    it skips unseen text too, by turning on "skip unseen text" while held.
    """

    global _held_skip_unseen

    import renpy

    prefs = renpy.game.preferences
    if held:
        if not renpy.config.allow_skipping or not renpy.store._skipping:
            return
        if _held_skip_unseen is None:
            _held_skip_unseen = prefs.skip_unseen
        prefs.skip_unseen = True
        prefs.afm_enable = False
        renpy.config.skipping = "slow"
    else:
        if _held_skip_unseen is not None:
            prefs.skip_unseen = _held_skip_unseen
            _held_skip_unseen = None
        renpy.config.skipping = None
    renpy.exports.restart_interaction()


def controls():
    """
    What the game menu shows, as MikageRenPyControl bits.
    """

    import renpy

    try:
        prefs = renpy.game.preferences
        bits = 0x100
        if prefs.afm_enable:
            bits |= 0x1
        if renpy.config.skipping and _held_skip_unseen is None:
            bits |= 0x2
        if renpy.config.allow_skipping and renpy.store._skipping:
            bits |= 0x200
        if _in_game():
            bits |= 0x400
            if renpy.exports.can_load("quick-1"):
                bits |= 0x800
            if renpy.exports.has_screen("history"):
                bits |= 0x1000
            if renpy.exports.has_screen("save"):
                bits |= 0x2000
            if renpy.exports.has_screen("load"):
                bits |= 0x4000
        return bits
    except Exception:
        return 0


def game_size():
    """
    The game's own size, as width << 16 | height, or 0 before it is known.
    """

    import renpy

    try:
        width = int(renpy.config.screen_width)
        height = int(renpy.config.screen_height)
        if not (0 < width < 0x8000 and 0 < height < 0x10000):
            return 0
        return (width << 16) | height
    except Exception:
        return 0
