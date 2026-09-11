#include "audio_ring.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct audio_ring {
    float * data;
    size_t capacity; /* always a power of two */
    size_t mask;     /* capacity - 1 */

    /* Free-running counts, never wrapped. The difference is the fill level,
     * and masking happens only at the point of indexing — which is what keeps
     * "full" and "empty" from aliasing the way equal wrapped indices would. */
    _Atomic size_t write_pos;
    _Atomic size_t read_pos;

    _Atomic uint64_t dropped;
};

static size_t round_up_pow2(size_t n) {
    size_t p = 1;
    while (p < n) {
        size_t next = p << 1;
        if (next < p) return 0; /* overflow */
        p = next;
    }
    return p;
}

struct audio_ring * audio_ring_create(size_t capacity_frames) {
    if (capacity_frames == 0) return NULL;

    const size_t capacity = round_up_pow2(capacity_frames);
    if (capacity == 0) return NULL;

    struct audio_ring * ring = calloc(1, sizeof(struct audio_ring));
    if (ring == NULL) return NULL;

    ring->data = malloc(capacity * sizeof(float));
    if (ring->data == NULL) {
        free(ring);
        return NULL;
    }

    ring->capacity = capacity;
    ring->mask = capacity - 1;
    atomic_store_explicit(&ring->write_pos, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->read_pos, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->dropped, 0, memory_order_relaxed);
    return ring;
}

void audio_ring_free(struct audio_ring * ring) {
    if (ring == NULL) return;
    free(ring->data);
    free(ring);
}

size_t audio_ring_capacity(const struct audio_ring * ring) {
    return ring == NULL ? 0 : ring->capacity;
}

bool audio_ring_write(struct audio_ring * ring, const float * src, size_t n) {
    if (ring == NULL || src == NULL || n == 0) return false;

    /* Only this thread advances write_pos, so a relaxed load of our own
     * counter is enough. read_pos is the other thread's, and must be acquired
     * so the space it freed is actually visible to us. */
    const size_t write = atomic_load_explicit(&ring->write_pos, memory_order_relaxed);
    const size_t read = atomic_load_explicit(&ring->read_pos, memory_order_acquire);

    const size_t free_space = ring->capacity - (write - read);
    if (n > free_space) return false;
    const size_t take = n;

    /* One or two memcpys depending on whether the run wraps the end. */
    const size_t offset = write & ring->mask;
    const size_t first = (ring->capacity - offset) < take
                             ? (ring->capacity - offset)
                             : take;
    memcpy(ring->data + offset, src, first * sizeof(float));
    if (take > first) {
        memcpy(ring->data, src + first, (take - first) * sizeof(float));
    }

    /* Release: the copies above must be visible before the reader can see the
     * advanced position, or it reads uninitialised memory. */
    atomic_store_explicit(&ring->write_pos, write + take, memory_order_release);
    return true;
}

void audio_ring_note_dropped(struct audio_ring * ring, size_t n) {
    if (ring == NULL || n == 0) return;
    atomic_fetch_add_explicit(&ring->dropped, (uint64_t)n, memory_order_relaxed);
}

size_t audio_ring_read(struct audio_ring * ring, float * dst, size_t n) {
    if (ring == NULL || dst == NULL || n == 0) return 0;

    const size_t read = atomic_load_explicit(&ring->read_pos, memory_order_relaxed);
    const size_t write = atomic_load_explicit(&ring->write_pos, memory_order_acquire);

    const size_t available = write - read;
    const size_t take = n < available ? n : available;
    if (take == 0) return 0;

    const size_t offset = read & ring->mask;
    const size_t first = (ring->capacity - offset) < take
                             ? (ring->capacity - offset)
                             : take;
    memcpy(dst, ring->data + offset, first * sizeof(float));
    if (take > first) {
        memcpy(dst + first, ring->data, (take - first) * sizeof(float));
    }

    atomic_store_explicit(&ring->read_pos, read + take, memory_order_release);
    return take;
}

size_t audio_ring_available(const struct audio_ring * ring) {
    if (ring == NULL) return 0;
    const size_t write = atomic_load_explicit(&ring->write_pos, memory_order_acquire);
    const size_t read = atomic_load_explicit(&ring->read_pos, memory_order_acquire);
    return write - read;
}

uint64_t audio_ring_dropped(const struct audio_ring * ring) {
    return ring == NULL
               ? 0
               : atomic_load_explicit(&ring->dropped, memory_order_relaxed);
}

void audio_ring_reset(struct audio_ring * ring) {
    if (ring == NULL) return;
    atomic_store_explicit(&ring->write_pos, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->read_pos, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->dropped, 0, memory_order_relaxed);
}
