/*
 * audio_ring — a single-producer/single-consumer float32 ring buffer.
 *
 * This is the seam between the microphone and Dart. The producer is
 * CoreAudio's render thread, which is a hard real-time context: it may not
 * allocate, take a lock, or call into the Objective-C or Swift runtimes, and
 * missing its deadline is an audible glitch rather than a slow frame. The
 * consumer is a Dart isolate that wakes on a timer. So the boundary between
 * them is plain C and two atomics, and nothing else.
 *
 * Lock-free and wait-free on both sides for exactly one producer and exactly
 * one consumer. Two of either is undefined behaviour, not a slow path.
 *
 * On overflow the ring drops the *incoming* samples and counts them rather than
 * overwriting unread audio. Both choices lose data; this one loses it at a
 * known place, keeps the reader's view of the past contiguous, and — because a
 * drop means the consumer stalled for the whole buffer depth — is a fault to
 * report rather than a condition to absorb. Audio after a drop is discontiguous
 * with audio before it, so a consumer that sees the count move must reset any
 * carried state (VAD, endpointer) instead of feeding across the seam.
 *
 * Writes are all-or-nothing: a partial write would tear the producer's buffer
 * across a gap, which is worse than losing the whole buffer.
 *
 * The ring does not decide what a failed write means — only the producer knows
 * whether it will retry or discard, and a ring that counted every rejection
 * would report a retrying caller as lossy. So `audio_ring_write` reports
 * failure and `audio_ring_note_dropped` records loss, and the counter means
 * exactly "samples the producer threw away".
 */
#ifndef AUDIO_RING_H
#define AUDIO_RING_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "tc_export.h"

#ifdef __cplusplus
extern "C" {
#endif

struct audio_ring;

/* Allocates a ring holding at least `capacity_frames` floats; the real
 * capacity is rounded up to a power of two, so query it rather than assume.
 * Returns NULL on OOM or a zero request. */
TC_EXPORT struct audio_ring * audio_ring_create(size_t capacity_frames);

TC_EXPORT void audio_ring_free(struct audio_ring * ring);

TC_EXPORT size_t audio_ring_capacity(const struct audio_ring * ring);

/* Producer side. Writes all `n` floats or none of them. Returns false when the
 * ring had no room, in which case all `n` are added to the drop count. A write
 * larger than the capacity can never succeed. Real-time safe: no allocation, no
 * locks, no runtime calls. */
TC_EXPORT bool audio_ring_write(struct audio_ring * ring, const float * src, size_t n);

/* Producer side. Records that `n` floats were discarded. Call this after a
 * failed write that you do not intend to retry. Real-time safe. */
TC_EXPORT void audio_ring_note_dropped(struct audio_ring * ring, size_t n);

/* Consumer side. Reads up to `n` floats, returns how many it got. */
TC_EXPORT size_t audio_ring_read(struct audio_ring * ring, float * dst, size_t n);

/* Floats waiting to be read. A snapshot: the producer may add more the instant
 * after this returns, so treat it as a lower bound. */
TC_EXPORT size_t audio_ring_available(const struct audio_ring * ring);

/* Total floats the producer reported discarding since creation or the last
 * reset. Poll this every drain: a change means the audio stream has a hole in
 * it, and carried state downstream is no longer valid across that seam. */
TC_EXPORT uint64_t audio_ring_dropped(const struct audio_ring * ring);

/* Discards everything buffered and clears the drop count. Only safe while the
 * producer is stopped — call it between capture sessions, not during one. */
TC_EXPORT void audio_ring_reset(struct audio_ring * ring);

#ifdef __cplusplus
}
#endif

#endif /* AUDIO_RING_H */
