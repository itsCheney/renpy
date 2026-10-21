// Runs Ren'Py inside Mikage. See MikageRenPyRuntime.h.
//
// Ren'Py is a Python program that owns its main loop: it blocks in
// SDL_WaitEvent, sleeps with SDL_Delay and leaves by raising SystemExit.
// Mikage can't give up its main thread, and UIKit and SDL's video code must
// stay on it, so the interpreter runs on its own stack on the main thread.
// MikageRenPyHooks.h routes Ren'Py's waits, sleeps and presents here; each
// of them switches back to the host, and the next display refresh switches
// into the engine again.
//
// The GIL goes with the switch: whenever the engine stack is parked, the
// Python thread state is released, so Ren'Py's own worker threads (image
// preloading, for one) keep running while the app draws its frame.

#include <Python.h>

#define MIKAGE_RENPY_BRIDGE 1
#include "MikageRenPyHooks.h"
#include "MikageRenPyRuntime.h"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <SDL3/SDL.h>
// SDL_MAIN_HANDLED (set by CMakeLists.txt) keeps this to SDL_SetMainReady.
#include <SDL3/SDL_main.h>

#include <dlfcn.h>
#include <pthread.h>
#include <sys/mman.h>
#include <unistd.h>

#include <atomic>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#ifndef MIKAGE_RENPY_VERSION
#define MIKAGE_RENPY_VERSION "unknown"
#endif

extern "C" void mikage_renpy_fiber_switch(void **save_sp, void *load_sp);
extern "C" void mikage_renpy_fiber_trampoline(void);
// Generated from Ren'Py's src/Setup by CMakeLists.txt: registers every
// compiled Ren'Py module as a built-in.
extern "C" void mikage_renpy_extend_inittab(void);

namespace {

// Python and Ren'Py expect a desktop-sized main thread stack. Pages are only
// committed when touched.
constexpr size_t kFiberStackSize = 32u << 20;
// How long RequestStop waits for the game to end itself, in steps.
constexpr int kStopGraceSteps = 600;
// A poll for events after this much engine time in one step hands the rest
// of the frame back to the app. Ren'Py polls in a busy loop while it waits
// to draw the next frame.
constexpr Uint64 kPollBudgetNS = 10 * 1000 * 1000;
// Start runs the engine until its window exists, for at most this long.
constexpr Uint64 kStartLimitNS = 180ull * 1000 * 1000 * 1000;

std::atomic<MikageRenPyLogCallback> logCallback{nullptr};
std::mutex errorMutex;
std::string lastEngineError;
std::string lastError;

MikageRenPyMenuCallback menuCallback = nullptr;
MikageRenPyCompletionCallback completionCallback = nullptr;
void *callbackContext = nullptr;

bool running = false;
bool foreground = true;
// Python can't be finalized and started again in one process.
bool processUsed = false;
bool pythonInitialized = false;
PyThreadState *mainThreadState = nullptr;

// Quick actions and game menu commands waiting for the engine, and the
// game's controls as last read. Main thread only.
std::vector<int32_t> pendingCommands;
int pendingControlSkip = -1;
bool controlsRequested = false;
uint32_t cachedControls = 0;

bool stopRequested = false;
bool stopPrepared = false;
int stopSteps = 0;
bool menuGestureEnabled = false;
bool menuGestureActive = false;
bool audioPausedByHost = false;
SDL_AudioStream *audioStream = nullptr;

std::string basePath;
std::string gamePath;
std::string savePath;
std::string savedWorkingDirectory;

void *fiberStack = nullptr;
void *hostStackPointer = nullptr;
void *fiberStackPointer = nullptr;
bool onFiber = false;
bool fiberDone = false;
int exitStatus = 0;

// Frame statistics, reset by each MikageRenPyGetStats.
Uint64 stepStartNS = 0;
Uint64 statsSinceNS = 0;
Uint64 presentCount = 0;
Uint64 stepCount = 0;
Uint64 stepTotalNS = 0;
Uint64 stepMaxNS = 0;

void log(const char *source, int32_t level, const char *message)
{
    if (level >= 5) {
        std::lock_guard<std::mutex> lock(errorMutex);
        lastEngineError = message;
    }
    if (auto callback = logCallback.load(std::memory_order_acquire))
        callback(source, level, message);
}

void log(int32_t level, const std::string &message)
{
    log("bridge", level, message.c_str());
}

bool isEngineContext()
{
    return onFiber && pthread_main_np();
}

void switchToHost()
{
    mikage_renpy_fiber_switch(&fiberStackPointer, hostStackPointer);
}

void afterResume();

// Parks the engine until the host's next step. The GIL is released while
// parked when the engine holds it; inside a `with nogil` block it doesn't.
void yieldFromEngine()
{
    PyThreadState *state = nullptr;
    if (pythonInitialized && PyGILState_Check())
        state = PyEval_SaveThread();
    switchToHost();
    if (state)
        PyEval_RestoreThread(state);
    afterResume();
}

// Runs the engine until it next waits, presents or ends. Returns true when
// it has ended.
bool resumeEngine()
{
    stepStartNS = SDL_GetTicksNS();
    onFiber = true;
    mikage_renpy_fiber_switch(&hostStackPointer, fiberStackPointer);
    onFiber = false;
    return fiberDone;
}

// Python's view of the bridge: a built-in module named _mikage.
PyObject *pyLog(PyObject *, PyObject *args)
{
    int level = 3;
    const char *text = nullptr;
    if (!PyArg_ParseTuple(args, "is", &level, &text))
        return nullptr;
    log("renpy", level, text);
    Py_RETURN_NONE;
}

PyMethodDef mikageMethods[] = {
    {"log", pyLog, METH_VARARGS, "Writes a line to Mikage's log."},
    {nullptr, nullptr, 0, nullptr},
};

PyModuleDef mikageModule = {
    PyModuleDef_HEAD_INIT, "_mikage", "Mikage's Ren'Py bridge.", -1, mikageMethods,
    nullptr, nullptr, nullptr, nullptr,
};

PyMODINIT_FUNC initMikageModule(void)
{
    return PyModule_Create(&mikageModule);
}

// Logs the pending Python exception with its traceback, and returns its
// one-line summary.
std::string takePythonError()
{
    PyObject *type = nullptr, *value = nullptr, *traceback = nullptr;
    PyErr_Fetch(&type, &value, &traceback);
    PyErr_NormalizeException(&type, &value, &traceback);
    std::string summary = "Ren'Py raised an exception.";
    if (value) {
        if (PyObject *text = PyObject_Str(value)) {
            if (const char *utf8 = PyUnicode_AsUTF8(text)) {
                const char *name = type ? reinterpret_cast<PyTypeObject *>(type)->tp_name : "Exception";
                summary = std::string(name) + ": " + utf8;
            }
            Py_DECREF(text);
        }
    }
    PyErr_Clear();
    if (PyObject *module = PyImport_ImportModule("traceback")) {
        PyObject *lines = PyObject_CallMethod(module, "format_exception", "OOO",
                                              type ? type : Py_None, value ? value : Py_None,
                                              traceback ? traceback : Py_None);
        if (lines) {
            PyObject *joined = PyUnicode_Join(PyUnicode_FromString(""), lines);
            if (joined) {
                if (const char *utf8 = PyUnicode_AsUTF8(joined))
                    log("renpy", 5, utf8);
                Py_DECREF(joined);
            }
            Py_DECREF(lines);
        }
        Py_DECREF(module);
    }
    PyErr_Clear();
    Py_XDECREF(type);
    Py_XDECREF(value);
    Py_XDECREF(traceback);
    log(5, summary);
    return summary;
}

std::string frameworkDirectory()
{
    Dl_info info;
    if (!dladdr(reinterpret_cast<const void *>(&frameworkDirectory), &info) || !info.dli_fname)
        return std::string();
    std::string path(info.dli_fname);
    const size_t slash = path.rfind('/');
    return slash == std::string::npos ? std::string() : path.substr(0, slash);
}

bool appendPath(PyWideStringList *list, const std::string &path)
{
    wchar_t *wide = Py_DecodeLocale(path.c_str(), nullptr);
    if (!wide)
        return false;
    PyStatus status = PyWideStringList_Append(list, wide);
    PyMem_RawFree(wide);
    return !PyStatus_Exception(status);
}

bool initializePython()
{
    PyPreConfig preconfig;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    PyStatus status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) {
        log(5, std::string("Python pre-initialization failed: ") + (status.err_msg ? status.err_msg : "?"));
        return false;
    }

    mikage_renpy_extend_inittab();
    if (PyImport_AppendInittab("_mikage", initMikageModule) != 0) {
        log(5, "Couldn't register the _mikage module.");
        return false;
    }

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.site_import = 0;
    config.user_site_directory = 0;
    config.write_bytecode = 0;
    config.install_signal_handlers = 0;
    config.parse_argv = 0;
    config.buffered_stdio = 0;

    bool ok = true;
    status = PyConfig_SetBytesString(&config, &config.home, basePath.c_str());
    ok = ok && !PyStatus_Exception(status);
    status = PyConfig_SetBytesString(&config, &config.program_name, "renpy");
    ok = ok && !PyStatus_Exception(status);
    char *argv[] = {const_cast<char *>("renpy")};
    status = PyConfig_SetBytesArgv(&config, 1, argv);
    ok = ok && !PyStatus_Exception(status);
    config.module_search_paths_set = 1;
    ok = ok && appendPath(&config.module_search_paths, basePath + "/lib/python312.zip");
    ok = ok && appendPath(&config.module_search_paths, basePath + "/lib/python3.12");
    ok = ok && appendPath(&config.module_search_paths, basePath);
    if (!ok) {
        PyConfig_Clear(&config);
        log(5, "Couldn't configure Python.");
        return false;
    }

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        log(5, std::string("Python failed to start: ") + (status.err_msg ? status.err_msg : "?"));
        return false;
    }
    pythonInitialized = true;
    return true;
}

// Runs on the engine stack: Python, then Ren'Py, until the game ends.
void engineMain(void *)
{
    int status = 1;
    bool holdsGIL = false;
    if (!pythonInitialized) {
        holdsGIL = initializePython();
    } else if (mainThreadState) {
        PyEval_RestoreThread(mainThreadState);
        mainThreadState = nullptr;
        holdsGIL = true;
    }

    if (holdsGIL) {
        PyObject *session = PyImport_ImportModule("mikage_session");
        PyObject *result = session ? PyObject_CallMethod(session, "run", "sss", basePath.c_str(),
                                                         gamePath.c_str(), savePath.c_str())
                                   : nullptr;
        if (result) {
            status = static_cast<int>(PyLong_AsLong(result));
            if (PyErr_Occurred())
                status = 1;
            Py_DECREF(result);
        } else {
            takePythonError();
        }
        Py_XDECREF(session);
        PyErr_Clear();
        // Ren'Py's worker threads may still be winding down; let them.
        mainThreadState = PyEval_SaveThread();
    }

    exitStatus = status;
    fiberDone = true;
    switchToHost();
    __builtin_unreachable();
}

SDL_Window *engineWindow();

// Calls mikage_session.name(args); returns its integer result, or -1.
long callSession(const char *name, const char *format = nullptr, int argument = 0)
{
    long value = -1;
    if (PyObject *session = PyImport_ImportModule("mikage_session")) {
        PyObject *result = format ? PyObject_CallMethod(session, name, format, argument)
                                  : PyObject_CallMethod(session, name, nullptr);
        if (result) {
            if (PyLong_Check(result))
                value = PyLong_AsLong(result);
            Py_DECREF(result);
        }
        Py_DECREF(session);
    }
    if (PyErr_Occurred())
        takePythonError();
    PyErr_Clear();
    return value;
}

// Runs on the engine stack with the GIL, between engine steps. Commands
// become presses of the keys mikage_session binds, so they run inside
// Ren'Py's own event handling.
void runHostRequests()
{
    if (pendingCommands.empty() && pendingControlSkip < 0 && !controlsRequested)
        return;
    if (!pendingCommands.empty()) {
        callSession("install_keymap");
        SDL_Window *window = engineWindow();
        for (int32_t command : pendingCommands) {
            SDL_Event event;
            SDL_zero(event);
            event.key.timestamp = SDL_GetTicksNS();
            event.key.windowID = window ? SDL_GetWindowID(window) : 0;
            // F13 and up, as mikage_session._KEYS binds them.
            event.key.scancode = static_cast<SDL_Scancode>(SDL_SCANCODE_F13 + command - 1);
            event.key.key = SDLK_F13 + static_cast<SDL_Keycode>(command - 1);
            event.type = SDL_EVENT_KEY_DOWN;
            event.key.down = true;
            SDL_PushEvent(&event);
            event.type = SDL_EVENT_KEY_UP;
            event.key.down = false;
            SDL_PushEvent(&event);
        }
        pendingCommands.clear();
    }
    if (pendingControlSkip >= 0) {
        callSession("set_control_skip", "i", pendingControlSkip);
        pendingControlSkip = -1;
    }
    if (controlsRequested) {
        const long controls = callSession("controls");
        cachedControls = controls > 0 ? static_cast<uint32_t>(controls) : 0;
        controlsRequested = false;
    }
}

void afterResume()
{
    if (pythonInitialized && running && !stopRequested)
        runHostRequests();
    if (!stopRequested || stopPrepared || !pythonInitialized)
        return;
    stopPrepared = true;
    PyGILState_STATE gil = PyGILState_Ensure();
    if (PyObject *session = PyImport_ImportModule("mikage_session")) {
        PyObject *result = PyObject_CallMethod(session, "prepare_quit", nullptr);
        Py_XDECREF(result);
        Py_DECREF(session);
    }
    PyErr_Clear();
    PyGILState_Release(gil);
}

bool prepareFiber()
{
    void *stack = mmap(nullptr, kFiberStackSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (stack == MAP_FAILED)
        return false;
    // The lowest page stays unmapped so an overflow faults instead of
    // corrupting the heap.
    mprotect(stack, getpagesize(), PROT_NONE);
    fiberStack = stack;

    // The frame mikage_renpy_fiber_switch restores: x19-x28, fp, lr, d8-d15.
    auto top = reinterpret_cast<uintptr_t>(stack) + kFiberStackSize;
    auto *frame = reinterpret_cast<uint64_t *>((top - 160) & ~uintptr_t(15));
    std::memset(frame, 0, 160);
    frame[0] = reinterpret_cast<uint64_t>(&engineMain);                     // x19
    frame[1] = 0;                                                            // x20
    frame[10] = 0;                                                           // fp
    frame[11] = reinterpret_cast<uint64_t>(&mikage_renpy_fiber_trampoline); // lr
    fiberStackPointer = frame;
    fiberDone = false;
    exitStatus = 0;
    return true;
}

void releaseFiber()
{
    if (fiberStack)
        munmap(fiberStack, kFiberStackSize);
    fiberStack = nullptr;
    fiberStackPointer = nullptr;
}

SDL_Window *engineWindow()
{
    int count = 0;
    SDL_Window **windows = SDL_GetWindows(&count);
    SDL_Window *window = windows && count > 0 ? windows[0] : nullptr;
    SDL_free(windows);
    return window;
}

// A three-finger touch opens the host menu. Its touches never reach the
// game, so it doesn't also count as a tap there.
bool SDLCALL filterEvent(void *, SDL_Event *event)
{
    if (!menuGestureEnabled)
        return true;
    switch (event->type) {
    case SDL_EVENT_FINGER_DOWN: {
        if (menuGestureActive)
            return false;
        int fingers = 0;
        SDL_Finger **list = SDL_GetTouchFingers(event->tfinger.touchID, &fingers);
        SDL_free(list);
        if (fingers >= 3) {
            menuGestureActive = true;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (running && menuCallback)
                    menuCallback(callbackContext);
            });
            return false;
        }
        return true;
    }
    case SDL_EVENT_FINGER_MOTION:
        return !menuGestureActive;
    case SDL_EVENT_FINGER_UP: {
        if (!menuGestureActive)
            return true;
        int fingers = 0;
        SDL_Finger **list = SDL_GetTouchFingers(event->tfinger.touchID, &fingers);
        SDL_free(list);
        if (fingers <= 1)
            menuGestureActive = false;
        return false;
    }
    default:
        return true;
    }
}

void setAudioSessionActive(bool active)
{
    NSError *error = nil;
    if (active) {
        [[AVAudioSession sharedInstance] setActive:YES error:&error];
    } else {
        [[AVAudioSession sharedInstance] setActive:NO
                                       withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                             error:&error];
    }
    if (error) {
        lastError = error.localizedDescription.UTF8String;
        log(4, lastError);
    }
}

void tearDown()
{
    SDL_SetEventFilter(nullptr, nullptr);
    audioStream = nullptr;
    audioPausedByHost = false;
    menuGestureActive = false;
    // Ren'Py has quit its display and audio; this also closes anything a
    // forced stop left open, so the next engine starts from a clean SDL.
    SDL_Quit();
    if (!savedWorkingDirectory.empty())
        chdir(savedWorkingDirectory.c_str());
    savedWorkingDirectory.clear();
    setAudioSessionActive(false);
}

std::string endMessage()
{
    std::lock_guard<std::mutex> lock(errorMutex);
    if (!lastEngineError.empty())
        return lastEngineError;
    return "Ren'Py stopped with status " + std::to_string(exitStatus) + ".";
}

void finishSession(bool forced)
{
    const bool success = forced || exitStatus == 0;
    const std::string message = success ? std::string() : endMessage();
    tearDown();
    // A forced stop leaves the engine parked mid-call; its stack can never
    // be resumed or freed.
    if (!forced)
        releaseFiber();
    else
        fiberStack = nullptr;

    running = false;
    foreground = true;
    stopRequested = false;
    stopPrepared = false;
    pendingCommands.clear();
    pendingControlSkip = -1;
    controlsRequested = false;
    cachedControls = 0;
    lastError = message;
    auto callback = completionCallback;
    auto context = callbackContext;
    menuCallback = nullptr;
    completionCallback = nullptr;
    callbackContext = nullptr;
    log(success ? 3 : 5, success ? std::string("session.finished") : message);
    if (callback)
        callback(success, success ? nullptr : lastError.c_str(), context);
}

} // namespace

extern "C" bool MikageRenPyWaitEvent(SDL_Event *event)
{
    if (!isEngineContext())
        return SDL_WaitEvent(event);
    for (;;) {
        if (SDL_PollEvent(event))
            return true;
        yieldFromEngine();
    }
}

extern "C" bool MikageRenPyWaitEventTimeout(SDL_Event *event, Sint32 timeoutMS)
{
    if (!isEngineContext())
        return SDL_WaitEventTimeout(event, timeoutMS);
    const Uint64 deadline = timeoutMS < 0 ? 0 : SDL_GetTicks() + static_cast<Uint64>(timeoutMS);
    for (;;) {
        if (SDL_PollEvent(event))
            return true;
        if (timeoutMS >= 0 && SDL_GetTicks() >= deadline)
            return false;
        yieldFromEngine();
    }
}

extern "C" bool MikageRenPyPollEvent(SDL_Event *event)
{
    if (isEngineContext() && SDL_GetTicksNS() - stepStartNS > kPollBudgetNS)
        yieldFromEngine();
    return SDL_PollEvent(event);
}

extern "C" void MikageRenPyDelay(Uint32 ms)
{
    if (!isEngineContext() || ms == 0) {
        SDL_Delay(ms);
        return;
    }
    const Uint64 deadline = SDL_GetTicks() + ms;
    do {
        yieldFromEngine();
    } while (SDL_GetTicks() < deadline);
}

extern "C" bool MikageRenPySwapWindow(SDL_Window *window)
{
    const bool presented = SDL_GL_SwapWindow(window);
    ++presentCount;
    // Core Animation shows the frame once the host's run loop turn ends.
    if (isEngineContext())
        yieldFromEngine();
    return presented;
}

extern "C" SDL_AudioStream *MikageRenPyOpenAudioDeviceStream(SDL_AudioDeviceID device, const SDL_AudioSpec *spec,
                                                             SDL_AudioStreamCallback callback, void *userdata)
{
    SDL_AudioStream *stream = SDL_OpenAudioDeviceStream(device, spec, callback, userdata);
    if (stream && device == SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK)
        audioStream = stream;
    return stream;
}

extern "C" void MikageRenPySetLogCallback(MikageRenPyLogCallback callback)
{
    logCallback.store(callback, std::memory_order_release);
}

extern "C" bool MikageRenPyCanStart(void)
{
    return !processUsed;
}

extern "C" bool MikageRenPyStart(const MikageRenPyLaunchOptions *options,
                                 MikageRenPyMenuCallback menu,
                                 MikageRenPyCompletionCallback completion,
                                 void *context)
{
    if (running) {
        lastError = "A Ren'Py game is already running.";
        return false;
    }
    if (processUsed) {
        lastError = "Ren'Py can run one game each time Mikage starts. Close Mikage from the app switcher and "
                    "open it again to play another Ren'Py game.";
        return false;
    }
    if (!options || !options->gamePath || !*options->gamePath || !options->saveDirectory ||
        !*options->saveDirectory) {
        lastError = "The Ren'Py game or save folder is missing.";
        return false;
    }

    @autoreleasepool {
        std::string game(options->gamePath);
        while (game.size() > 1 && game.back() == '/')
            game.pop_back();
        std::string saves(options->saveDirectory);
        while (saves.size() > 1 && saves.back() == '/')
            saves.pop_back();

        BOOL isDirectory = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:@(game.c_str()) isDirectory:&isDirectory] ||
            !isDirectory) {
            lastError = "The Ren'Py game folder does not exist.";
            return false;
        }
        [[NSFileManager defaultManager] createDirectoryAtPath:@(saves.c_str())
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];

        const std::string framework = frameworkDirectory();
        basePath = framework + "/base";
        if (access((basePath + "/renpy.py").c_str(), R_OK) != 0) {
            lastError = "This build of Mikage is missing Ren'Py's files.";
            return false;
        }
        gamePath = game;
        savePath = saves;
        {
            std::lock_guard<std::mutex> lock(errorMutex);
            lastEngineError.clear();
        }
        lastError.clear();
        log(3, "session.start renpy=" MIKAGE_RENPY_VERSION " game=" + gamePath);

        if (!prepareFiber()) {
            lastError = "Couldn't allocate the Ren'Py stack.";
            return false;
        }

        // Ren'Py reads a few files relative to the working directory.
        char cwd[PATH_MAX];
        savedWorkingDirectory = getcwd(cwd, sizeof(cwd)) ? cwd : "";
        chdir(gamePath.c_str());

#if TARGET_OS_SIMULATOR
        setenv("RENPY_PLATFORM", "ios-sim-arm64", 1);
#else
        setenv("RENPY_PLATFORM", "ios-arm64", 1);
#endif
        setenv("PYGAME_IOS", "1", 1);

        SDL_SetHint(SDL_HINT_AUDIO_CATEGORY, options->respectSilentMode ? "ambient" : "playback");
        SDL_SetHint(SDL_HINT_ORIENTATIONS, "LandscapeLeft LandscapeRight");
        // Touches reach SDL through the host's run loop between steps; the
        // engine must not spin a nested run loop on its own stack.
        SDL_SetiOSEventPump(false);
        SDL_SetMainReady();

        processUsed = true;
        menuCallback = menu;
        completionCallback = completion;
        callbackContext = context;
        menuGestureEnabled = options->menuGestureEnabled;
        menuGestureActive = false;
        SDL_SetEventFilter(filterEvent, nullptr);
        running = true;
        foreground = true;
        stopRequested = false;
        stopPrepared = false;
        stopSteps = 0;
        audioPausedByHost = false;
        statsSinceNS = 0;
        presentCount = stepCount = stepTotalNS = stepMaxNS = 0;
        setAudioSessionActive(true);

        // Python and Ren'Py start up and load the game's scripts before the
        // window exists; keep going until it does.
        const Uint64 startedNS = SDL_GetTicksNS();
        bool ended = false;
        do {
            ended = resumeEngine();
        } while (!ended && !engineWindow() && SDL_GetTicksNS() - startedNS < kStartLimitNS);

        if (ended || !engineWindow()) {
            const std::string failure = ended ? (exitStatus == 0 ? "The game ended during startup." : endMessage())
                                              : "Ren'Py didn't open its window.";
            completionCallback = nullptr;
            finishSession(!ended);
            lastError = failure;
            return false;
        }
    }
    return true;
}

extern "C" MikageRenPyStepResult MikageRenPyStep(void)
{
    if (!running || onFiber)
        return MIKAGE_RENPY_STEP_IDLE;
    if (stopRequested && ++stopSteps > kStopGraceSteps) {
        log(4, "session.stop.forced");
        finishSession(true);
        return MIKAGE_RENPY_STEP_FINISHED;
    }
    if (!foreground && !stopRequested)
        return MIKAGE_RENPY_STEP_IDLE;
    const Uint64 start = SDL_GetTicksNS();
    const bool ended = resumeEngine();
    const Uint64 elapsed = SDL_GetTicksNS() - start;
    ++stepCount;
    stepTotalNS += elapsed;
    if (elapsed > stepMaxNS)
        stepMaxNS = elapsed;
    if (!ended)
        return MIKAGE_RENPY_STEP_RUNNING;
    const bool success = exitStatus == 0;
    finishSession(false);
    return success ? MIKAGE_RENPY_STEP_FINISHED : MIKAGE_RENPY_STEP_FAILED;
}

extern "C" bool MikageRenPySendBack(void)
{
    SDL_Window *window = running && foreground ? engineWindow() : nullptr;
    if (!window)
        return false;
    SDL_Event event;
    SDL_zero(event);
    event.type = SDL_EVENT_KEY_DOWN;
    event.key.timestamp = SDL_GetTicksNS();
    event.key.windowID = SDL_GetWindowID(window);
    event.key.scancode = SDL_SCANCODE_ESCAPE;
    event.key.key = SDLK_ESCAPE;
    event.key.down = true;
    if (!SDL_PushEvent(&event))
        return false;
    event.type = SDL_EVENT_KEY_UP;
    event.key.down = false;
    return SDL_PushEvent(&event);
}

extern "C" bool MikageRenPyRunCommand(int32_t command)
{
    if (!running || stopRequested || command < MikageRenPyCommandAuto || command > MikageRenPyCommandLoad)
        return false;
    pendingCommands.push_back(command);
    return true;
}

extern "C" uint32_t MikageRenPyGameControls(void)
{
    if (!running)
        return 0;
    // Read on the engine's next step; the menu asks again as it refreshes.
    controlsRequested = true;
    return cachedControls;
}

extern "C" bool MikageRenPySetControlSkip(bool held)
{
    if (!running || stopRequested)
        return false;
    pendingControlSkip = held ? 1 : 0;
    return true;
}

extern "C" bool MikageRenPySendPointer(int32_t phase, float x, float y)
{
    SDL_Window *window = running && foreground ? engineWindow() : nullptr;
    if (!window || phase < 0 || phase > 4)
        return false;
    SDL_Event event;
    SDL_zero(event);
    if (phase == 0) {
        event.type = SDL_EVENT_MOUSE_MOTION;
        event.motion.timestamp = SDL_GetTicksNS();
        event.motion.windowID = SDL_GetWindowID(window);
        event.motion.x = x;
        event.motion.y = y;
        return SDL_PushEvent(&event);
    }
    const bool down = phase == 1 || phase == 3;
    event.type = down ? SDL_EVENT_MOUSE_BUTTON_DOWN : SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.timestamp = SDL_GetTicksNS();
    event.button.windowID = SDL_GetWindowID(window);
    event.button.button = phase >= 3 ? SDL_BUTTON_RIGHT : SDL_BUTTON_LEFT;
    event.button.down = down;
    event.button.clicks = 1;
    event.button.x = x;
    event.button.y = y;
    return SDL_PushEvent(&event);
}

extern "C" void MikageRenPyRequestStop(void)
{
    if (!running || stopRequested)
        return;
    log(3, "session.stop.requested");
    stopRequested = true;
    stopPrepared = false;
    stopSteps = 0;
    SDL_Event event;
    SDL_zero(event);
    event.type = SDL_EVENT_QUIT;
    event.quit.timestamp = SDL_GetTicksNS();
    SDL_PushEvent(&event);
}

extern "C" bool MikageRenPySetForeground(bool value)
{
    if (!running || foreground == value)
        return true;
    lastError.clear();
    if (!value) {
        // One more step, so Ren'Py handles its suspend event (pauses audio,
        // saves) before the app stops stepping it.
        if (!onFiber && !stopRequested && resumeEngine()) {
            finishSession(false);
            return true;
        }
        foreground = false;
        if (audioStream) {
            const SDL_AudioDeviceID device = SDL_GetAudioStreamDevice(audioStream);
            if (device && !SDL_AudioDevicePaused(device)) {
                SDL_PauseAudioStreamDevice(audioStream);
                audioPausedByHost = true;
            }
        }
        return true;
    }
    foreground = true;
    setAudioSessionActive(true);
    if (audioPausedByHost && audioStream)
        SDL_ResumeAudioStreamDevice(audioStream);
    audioPausedByHost = false;
    return lastError.empty();
}

extern "C" bool MikageRenPyIsRunning(void)
{
    return running;
}

extern "C" const char *MikageRenPyLastError(void)
{
    return lastError.c_str();
}

extern "C" const char *MikageRenPyVersion(void)
{
    return MIKAGE_RENPY_VERSION;
}

extern "C" void *MikageRenPyNativeWindow(void)
{
    SDL_Window *window = running ? engineWindow() : nullptr;
    if (!window)
        return nullptr;
    return SDL_GetPointerProperty(SDL_GetWindowProperties(window), SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, nullptr);
}

extern "C" bool MikageRenPyGetStats(MikageRenPyStats *stats)
{
    if (!stats || !running)
        return false;
    std::memset(stats, 0, sizeof(*stats));
    const Uint64 now = SDL_GetTicksNS();
    const double seconds = statsSinceNS ? (now - statsSinceNS) / 1e9 : 0;
    if (seconds > 0 && presentCount) {
        stats->framesPerSecond = presentCount / seconds;
        stats->frameTimeMilliseconds = seconds * 1000.0 / presentCount;
    }
    if (stepCount) {
        stats->cpuFrameTimeMilliseconds = stepTotalNS / 1e6 / stepCount;
        stats->maxCpuFrameTimeMilliseconds = stepMaxNS / 1e6;
    }
    if (SDL_Window *window = engineWindow()) {
        int width = 0, height = 0;
        SDL_GetWindowSizeInPixels(window, &width, &height);
        stats->drawableWidth = width;
        stats->drawableHeight = height;
    }
    std::strncpy(stats->renderer, "MetalANGLE", sizeof(stats->renderer) - 1);
    statsSinceNS = now;
    presentCount = stepCount = stepTotalNS = stepMaxNS = 0;
    return true;
}
