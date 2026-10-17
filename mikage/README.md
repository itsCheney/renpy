# Ren'Py in Mikage (iOS)

This folder builds `RenPyRuntime.framework` for [Mikage](https://github.com/itsCheney/Mikage-Next).
Mikage's `scripts/build-renpy-ios.sh` drives it; it is not used by Ren'Py's
own desktop, Android or renpy-build builds.

- `MikageRenPyRuntime.h/.mm`: the host API. Python and Ren'Py run on their
  own stack on the main thread (`MikageRenPyFiber.S`); each step resumes
  Ren'Py until it presents a frame or waits.
- `MikageRenPyHooks.h`: force-included into Ren'Py's C so `SDL_WaitEvent`,
  `SDL_PollEvent`, `SDL_Delay` and `SDL_GL_SwapWindow` hand control back to
  the app.
- `mikage_session.py`: runs `renpy.py` for one game with Mikage's save folder.
- `CMakeLists.txt`: compiles every module in `src/Setup` (from
  `python setup.py generate`) as a built-in module, with CPython 3.12,
  pyobjus and the dependencies in `vcpkg.json`. SDL3 is Mikage's shared
  SDL3.framework; OpenGL ES comes from MetalANGLE, never Apple's OpenGLES.
- `python/`: CPython 3.12 cross-build pieces for iOS, after renpy-build
  (`cross-darwin.diff` patches `configure` directly, so no autoreconf).
- `pylib/`: pure-Python packages Ren'Py imports at startup, shipped next to
  it: `six.py` 1.17.0 (MIT, unmodified from PyPI).

Limits for now: one Ren'Py game per app launch (Python can't be restarted
in a process), no Live2D, no `ssl` module.

The only change outside this folder is `src/renpygl.h`, which takes GL ES
types from MetalANGLE when `RENPY_MIKAGE` is defined.
