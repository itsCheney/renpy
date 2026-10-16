// Force-included into every Ren'Py C source by the Mikage build.
//
// Ren'Py owns its main loop: it blocks in SDL_WaitEvent, sleeps with
// SDL_Delay and presents with SDL_GL_SwapWindow. Mikage runs that loop on its
// own stack on the main thread and needs it to hand control back to the app
// whenever it waits or shows a frame. These macros route those calls to the
// bridge (MikageRenPyRuntime.mm), which switches back to the host there.
//
// Off the engine stack (Ren'Py's worker threads, or before a session starts)
// every hook behaves exactly like the SDL call it replaces.

#ifndef MIKAGE_RENPY_HOOKS_H
#define MIKAGE_RENPY_HOOKS_H

#include <SDL3/SDL.h>

#ifdef __cplusplus
extern "C" {
#endif

bool MikageRenPyWaitEvent(SDL_Event *event);
bool MikageRenPyWaitEventTimeout(SDL_Event *event, Sint32 timeoutMS);
bool MikageRenPyPollEvent(SDL_Event *event);
void MikageRenPyDelay(Uint32 ms);
bool MikageRenPySwapWindow(SDL_Window *window);
SDL_AudioStream *MikageRenPyOpenAudioDeviceStream(SDL_AudioDeviceID device, const SDL_AudioSpec *spec,
                                                  SDL_AudioStreamCallback callback, void *userdata);

#ifdef __cplusplus
}
#endif

#ifndef MIKAGE_RENPY_BRIDGE
#define SDL_WaitEvent(event) MikageRenPyWaitEvent(event)
#define SDL_WaitEventTimeout(event, timeout) MikageRenPyWaitEventTimeout(event, timeout)
#define SDL_PollEvent(event) MikageRenPyPollEvent(event)
#define SDL_Delay(ms) MikageRenPyDelay(ms)
#define SDL_GL_SwapWindow(window) MikageRenPySwapWindow(window)
// The bridge pauses Ren'Py's audio device while the app is in the background.
#define SDL_OpenAudioDeviceStream(device, spec, callback, userdata) \
    MikageRenPyOpenAudioDeviceStream(device, spec, callback, userdata)
#endif

#endif
