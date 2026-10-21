#pragma once

// Host API that lets Mikage run Ren'Py inside its own app.
//
// Ren'Py keeps its blocking main loop, but runs on a separate stack on the
// main thread. Each MikageRenPyStep() resumes it until it presents a frame
// or waits, then returns to the host. Python and Ren'Py are compiled into
// this framework; the Python standard library and Ren'Py's own Python code
// live in its base/ folder. Every call here must be made on the main thread.

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum MikageRenPyStepResult {
    MIKAGE_RENPY_STEP_IDLE = 0,
    MIKAGE_RENPY_STEP_RUNNING = 1,
    MIKAGE_RENPY_STEP_FINISHED = 2,
    MIKAGE_RENPY_STEP_FAILED = 3
} MikageRenPyStepResult;

typedef void (*MikageRenPyMenuCallback)(void *context);
typedef void (*MikageRenPyCompletionCallback)(bool success, const char *message, void *context);
// level follows the KRKR host: 3 info, 4 warning, 5 error. Strings are
// borrowed for the duration of the call. May be called on engine worker
// threads.
typedef void (*MikageRenPyLogCallback)(const char *source, int32_t level, const char *message);

void MikageRenPySetLogCallback(MikageRenPyLogCallback callback);

typedef struct MikageRenPyLaunchOptions {
    // The game folder: the one holding game/ (and usually renpy/ and lib/
    // from the desktop build, which are not used).
    const char *gamePath;
    // Where saves go (Ren'Py's --savedir). Created if missing.
    const char *saveDirectory;
    // Follow the Ring/Silent switch (ambient) instead of always playing.
    bool respectSilentMode;
    // A three-finger touch opens the host menu.
    bool menuGestureEnabled;
} MikageRenPyLaunchOptions;

// Starts the game and runs it until its first frame or wait. Returns false
// with MikageRenPyLastError() set when it can't start; completion is then not
// called. Otherwise completion is called once, from a later step, when the
// game ends.
//
// Python can't be restarted inside one process, so for now each app launch
// runs one Ren'Py game; a second start fails with a message that says so.
bool MikageRenPyStart(const MikageRenPyLaunchOptions *options,
                      MikageRenPyMenuCallback menu,
                      MikageRenPyCompletionCallback completion,
                      void *context);

// Call once per display refresh while running.
MikageRenPyStepResult MikageRenPyStep(void);

// Sends the game an Escape key press, which opens Ren'Py's game menu or
// steps back out of one. Delivered on the next step.
bool MikageRenPySendBack(void);

// Asks the game to quit without its quit confirmation; Ren'Py saves its
// persistent data and ends. If it hasn't ended after a grace period, the
// session ends anyway.
void MikageRenPyRequestStop(void);

// Pauses the game and its audio in the background, and resumes them.
// Going to the background runs one more step first, so Ren'Py sees its
// suspend event (it pauses audio and saves) before stepping stops.
bool MikageRenPySetForeground(bool foreground);

bool MikageRenPyIsRunning(void);
// False once a game has run in this process (see MikageRenPyStart).
bool MikageRenPyCanStart(void);
const char *MikageRenPyLastError(void);
// The engine's UIWindow, or NULL before it exists.
void *MikageRenPyNativeWindow(void);
// The Ren'Py version this runtime was built from, such as "8.6.0".
const char *MikageRenPyVersion(void);

// Frame statistics since the previous call, for the host's performance
// display. False when no game is running.
typedef struct MikageRenPyStats {
    // Frames the game presented per second, and the average gap between them.
    double framesPerSecond;
    double frameTimeMilliseconds;
    // Time the engine ran per step (one display refresh), average and worst.
    double cpuFrameTimeMilliseconds;
    double maxCpuFrameTimeMilliseconds;
    // Size of the window's drawable in pixels.
    int32_t drawableWidth;
    int32_t drawableHeight;
    // The GL renderer, e.g. "MetalANGLE".
    char renderer[32];
} MikageRenPyStats;
bool MikageRenPyGetStats(MikageRenPyStats *stats);

// Quick actions and the game menu's controls. Each runs the game's own
// action (Preference auto-forward, Skip, QuickSave, QuickLoad, ShowMenu)
// inside Ren'Py's event handling on the next step.
typedef enum MikageRenPyCommand {
    MikageRenPyCommandAuto = 1,
    MikageRenPyCommandSkip = 2,
    MikageRenPyCommandQuickSave = 3,
    MikageRenPyCommandQuickLoad = 4,
    MikageRenPyCommandBacklog = 5,
    MikageRenPyCommandSave = 6,
    MikageRenPyCommandLoad = 7,
} MikageRenPyCommand;
typedef enum MikageRenPyControl {
    MikageRenPyControlAuto = 1 << 0,
    MikageRenPyControlSkip = 1 << 1,
    MikageRenPyControlCanAuto = 1 << 8,
    MikageRenPyControlCanSkip = 1 << 9,
    MikageRenPyControlCanQuickSave = 1 << 10,
    MikageRenPyControlCanQuickLoad = 1 << 11,
    MikageRenPyControlCanBacklog = 1 << 12,
    MikageRenPyControlCanSave = 1 << 13,
    MikageRenPyControlCanLoad = 1 << 14,
} MikageRenPyControl;
bool MikageRenPyRunCommand(int32_t command);
// The controls as of the last step; each call asks for a fresh reading.
uint32_t MikageRenPyGameControls(void);
// Holds or releases a skip that, unlike the game's own Ctrl, also skips
// unseen text.
bool MikageRenPySetControlSkip(bool held);
// The host's trackpad cursor, as a mouse at x, y in window points.
// phase: 0 move, 1 left down, 2 left up, 3 right down, 4 right up.
bool MikageRenPySendPointer(int32_t phase, float x, float y);

#ifdef __cplusplus
}
#endif
