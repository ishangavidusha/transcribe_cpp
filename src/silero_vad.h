/*
 * silero_vad — a direct C implementation of Silero VAD v5/v6 (16 kHz).
 *
 * Why hand-written rather than a runtime: the model is ~310k parameters —
 * an STFT, four conv1d layers, one LSTM cell, and a sigmoid. Running that
 * through onnxruntime or ggml means carrying a whole inference runtime to
 * evaluate about 680k multiply-accumulates per 32 ms of audio. Written
 * directly it is a few hundred lines of dependency-free C that ports to any
 * platform unchanged.
 *
 * The weights come from the official ONNX via tool/extract_silero_weights.py.
 * Correctness is pinned by test/fixtures/silero_jfk_reference.bin, which holds
 * per-window probabilities produced by onnxruntime itself.
 *
 * Three details in this model are easy to get wrong, produce no error, and
 * silently ruin the output. All three are handled here and called out at the
 * point they matter:
 *
 *   1. Each call consumes SILERO_VAD_WINDOW (512) new samples but the network
 *      sees 576: the previous window's last SILERO_VAD_CONTEXT (64) samples
 *      are prepended. Feeding a bare 512 returns confident silence forever.
 *   2. The LSTM gate order is PyTorch's **ifgo**, even though the weights feed
 *      an ONNX LSTM op (whose spec says iofc). Getting this wrong yields a
 *      plausible-looking trace that never fires on speech.
 *   3. The STFT reflect-pads 64 samples on the RIGHT ONLY (ONNX pads [0, 64]),
 *      not symmetrically.
 *
 * Not thread-safe: one instance is a single stream of audio with carried
 * state. Use one per stream.
 */
#ifndef SILERO_VAD_H
#define SILERO_VAD_H

#include <stdbool.h>
#include <stddef.h>

#include "tc_export.h"

#ifdef __cplusplus
extern "C" {
#endif

/* The only sample rate this build supports. The ONNX carries an 8 kHz variant
 * in a parallel branch; we extract and implement the 16 kHz one. */
#define SILERO_VAD_SAMPLE_RATE 16000

/* New samples consumed per call — 32 ms at 16 kHz. */
#define SILERO_VAD_WINDOW 512

/* Samples carried from the previous window into the next call's input. */
#define SILERO_VAD_CONTEXT 64

struct silero_vad;

/* Load weights from a file produced by tool/extract_silero_weights.py.
 * Returns NULL if the file is missing, truncated, or not a SVAD blob. */
TC_EXPORT struct silero_vad * silero_vad_create(const char * weights_path);

/* Same, from a caller-owned buffer. The bytes are copied; the caller may free
 * them immediately. Useful when the weights ship as an app asset. */
TC_EXPORT struct silero_vad * silero_vad_create_from_memory(const void * data, size_t size);

TC_EXPORT void silero_vad_free(struct silero_vad * vad);

/* Clear the LSTM state and carried context. Call between unrelated streams;
 * leaving stale state makes the first windows of a new stream unreliable. */
TC_EXPORT void silero_vad_reset(struct silero_vad * vad);

/*
 * Run one window. `window` must be exactly SILERO_VAD_WINDOW mono float32
 * samples at 16 kHz in [-1, 1]. Returns the speech probability in [0, 1].
 *
 * Advances the carried context and LSTM state, so windows must be fed in
 * order and without gaps for the result to mean anything.
 */
TC_EXPORT float silero_vad_process(struct silero_vad * vad, const float * window);

/* Human-readable reason the last create() failed, or NULL. Static storage. */
TC_EXPORT const char * silero_vad_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* SILERO_VAD_H */
