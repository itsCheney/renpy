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
