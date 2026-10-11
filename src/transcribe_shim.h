/*
 * transcribe_shim — the small amount of C the Dart binding cannot express.
 *
 * transcribe.cpp's own C API is clean enough to bind directly with ffigen;
 * the one thing Dart FFI cannot provide is a *synchronous* callback invoked
 * from a native compute thread. `transcribe_set_abort_callback` needs exactly
 * that: it calls back with a `bool` return while the run is in flight.
 * Dart's NativeCallable.listener is asynchronous and cannot return a value,
 * and NativeCallable.isolateLocal only fires on the isolate's own thread.
 *
 * So cancellation goes through a plain atomic flag instead. Dart allocates a
 * flag, hands `tcshim_abort_cb` + the flag to the session as the abort
 * callback, and any isolate can request cancellation by flipping the flag.
 */
#ifndef TRANSCRIBE_SHIM_H
#define TRANSCRIBE_SHIM_H

#include <stdbool.h>

#include "tc_export.h"

#ifdef __cplusplus
extern "C" {
#endif

struct tcshim_cancel;

/* Allocate a cancellation flag, initially not-requested. NULL on OOM. */
TC_EXPORT struct tcshim_cancel * tcshim_cancel_create(void);

/* Free a flag. Must not be called while a run holding it is in flight. */
TC_EXPORT void tcshim_cancel_free(struct tcshim_cancel * c);

/* Request cancellation. Safe to call from any thread or isolate. */
TC_EXPORT void tcshim_cancel_request(struct tcshim_cancel * c);

/* Clear the flag so the same handle can be reused for the next run. */
TC_EXPORT void tcshim_cancel_reset(struct tcshim_cancel * c);

/* Read the flag without consuming it. */
TC_EXPORT bool tcshim_cancel_is_requested(const struct tcshim_cancel * c);

/*
 * Matches transcribe_abort_callback. Pass this together with a
 * `struct tcshim_cancel *` as user_data to transcribe_set_abort_callback.
 * A NULL user_data reads as "never abort".
 */
TC_EXPORT bool tcshim_abort_cb(void * user_data);

/*
 * Log filtering.
 *
 * transcribe_log_set() routes every library message *and* ggml's internal
 * diagnostics to one callback. Left at its default that is a wall of backend
 * and Metal initialisation chatter on every launch, which buries anything
 * worth reading; set to NULL it is silent, including the warnings.
 *
 * Filtering has to happen in C rather than Dart. The callback fires on
 * whatever thread is logging — ggml worker threads included — and `msg` is
 * only valid for the duration of the call. Dart's NativeCallable.listener is
 * the only variant safe to invoke from a foreign thread, and it is
 * asynchronous: by the time Dart ran, the pointer would dangle.
 *
 * TCSHIM_LOG_* mirror transcribe_log_level, which this header deliberately
 * does not include — the shim is built without the engine framework's headers
 * on its search path. The values are ABI, not convenience; they must not drift.
 */
#define TCSHIM_LOG_NONE  0u
#define TCSHIM_LOG_INFO  1u
#define TCSHIM_LOG_WARN  2u
#define TCSHIM_LOG_ERROR 3u
#define TCSHIM_LOG_DEBUG 4u
#define TCSHIM_LOG_CONT  5u

/* Levels worth having on by default: problems, and nothing else. */
#define TCSHIM_LOG_MASK_QUIET ((1u << TCSHIM_LOG_WARN) | (1u << TCSHIM_LOG_ERROR))

/*
 * Matches transcribe_log_callback. Pass this to transcribe_log_set with a
 * bitmask of permitted levels cast to void * as user_data — bit N passes
 * level N. Messages that pass are written to stderr, or to logcat on Android;
 * the rest are dropped.
 *
 * `level` is declared unsigned int rather than the enum because the enum type
 * lives in a header this file cannot see. Same ABI.
 *
 * A NULL user_data is a zero mask, i.e. silence.
 */
TC_EXPORT void tcshim_log_cb(unsigned int level, const char * msg, void * user_data);

#ifdef __cplusplus
}
#endif

#endif /* TRANSCRIBE_SHIM_H */
