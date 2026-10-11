/*
 * backend_loader — picks the engine's CPU code for this phone, on Android.
 *
 * The Android engine is built with ggml's backends as separate modules, one
 * per CPU tier (see tool/build_android.sh), and something has to load one
 * before the first model does. ggml's own loader cannot: it finds modules by
 * listing a directory, and an app's native libraries are not in one — they
 * sit uncompressed inside the APK, where the dynamic linker can open them by
 * name but nothing can list them. So this loads them by name, best tier
 * first. Each module's score function rejects a CPU that lacks its features,
 * which is what keeps an i8mm build off a phone without i8mm.
 *
 * Only built for Android; iOS links its backends statically.
 */
#ifndef BACKEND_LOADER_H
#define BACKEND_LOADER_H

#include "tc_export.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Loads the best CPU backend module this device can run and registers it with
 * ggml. Runs once per process however many isolates call it, and returns the
 * same answer each time: the module's file name, or NULL if none loaded —
 * libggml.so missing, or no tier this CPU supports. */
TC_EXPORT const char * tcshim_load_cpu_backend(void);

#ifdef __cplusplus
}
#endif

#endif /* BACKEND_LOADER_H */
