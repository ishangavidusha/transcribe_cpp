/*
 * Stress test for the SPSC ring. Two real threads, because the interesting
 * failures here are memory-ordering bugs that a single-threaded test cannot
 * express: a missing release/acquire pair reads uninitialised memory, and no
 * amount of sequential calling will show it.
 *
 * Build and run, including under ThreadSanitizer, which understands C11
 * atomics and will flag a wrong ordering even on a run that happens to pass:
 *
 *   clang -std=c11 -O2 -I src test/audio_ring_test.c src/audio_ring.c -o /tmp/ring
 *   clang -std=c11 -g -fsanitize=thread -I src test/audio_ring_test.c \
 *         src/audio_ring.c -o /tmp/ring_tsan
 */
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "audio_ring.h"

static int failures = 0;

static void check(bool ok, const char * what) {
    printf("%-58s %s\n", what, ok ? "ok" : "FAILED");
    if (!ok) failures++;
}

/* Every sample carries its own index, so the consumer can prove it saw the
 * stream in order with nothing torn, duplicated, or skipped. Floats represent
 * integers exactly up to 2^24, which bounds the run length. */
#define TOTAL 4000000
#define CHUNK 160 /* 10 ms at 16 kHz, a plausible CoreAudio buffer */

static struct audio_ring * ring;

static void * producer(void * unused) {
    (void)unused;
    float chunk[CHUNK];
    size_t written = 0;
    while (written < TOTAL) {
        const size_t n = (TOTAL - written) < CHUNK ? (TOTAL - written) : CHUNK;
        for (size_t i = 0; i < n; i++) chunk[i] = (float)(written + i);

        /* Back-pressure rather than drop: this test is about ordering, and
         * the drop path is exercised separately below. Retrying is safe only
         * because writes are all-or-nothing — a partial write would count the
         * shortfall as dropped on every spin. */
        while (!audio_ring_write(ring, chunk, n)) {
            /* Spin instead of calling audio_ring_note_dropped: nothing is lost,
             * so nothing should be counted. A real audio thread cannot spin —
             * it reports the drop and moves on. */
        }
        written += n;
    }
    return NULL;
}

int main(void) {
    /* --- geometry ------------------------------------------------------ */
    struct audio_ring * r = audio_ring_create(1000);
    check(audio_ring_capacity(r) == 1024, "capacity rounds up to a power of two");
    check(audio_ring_available(r) == 0, "a fresh ring is empty");
    audio_ring_free(r);
    check(audio_ring_create(0) == NULL, "a zero-length ring is refused");

    /* --- overflow accounting ------------------------------------------- */
    r = audio_ring_create(8);
    float in[16];
    for (int i = 0; i < 16; i++) in[i] = (float)i;

    check(audio_ring_write(r, in, 8), "a write that exactly fills succeeds");
    check(!audio_ring_write(r, in + 8, 4), "a write into a full ring takes nothing");
    check(audio_ring_dropped(r) == 0, "a rejected write is not itself a loss");
    audio_ring_note_dropped(r, 4);
    check(audio_ring_dropped(r) == 4, "discarded samples are counted when reported");

    float out[16];
    check(audio_ring_read(r, out, 16) == 8, "read returns only what is there");
    bool intact = true;
    for (int i = 0; i < 8; i++) intact = intact && out[i] == (float)i;
    check(intact, "the ring keeps the older audio, not the incoming");

    audio_ring_reset(r);
    check(audio_ring_dropped(r) == 0 && audio_ring_available(r) == 0,
          "reset clears both the contents and the drop count");
    audio_ring_free(r);

    /* --- wrap-around --------------------------------------------------- */
    r = audio_ring_create(8);
    for (int round = 0; round < 5; round++) {
        bool ok = audio_ring_write(r, in, 6) && audio_ring_read(r, out, 6) == 6;
        for (int i = 0; i < 6; i++) ok = ok && out[i] == (float)i;
        if (!ok) check(false, "data survives the wrap");
    }
    check(true, "five wraps preserve every sample");
    audio_ring_free(r);

    /* --- two threads --------------------------------------------------- */
    /* 8192 floats is about half a second at 16 kHz — small enough that the
     * consumer must actually keep up, so the full/empty edges get hit hard. */
    ring = audio_ring_create(8192);

    pthread_t thread;
    pthread_create(&thread, NULL, producer, NULL);

    float * buffer = malloc(CHUNK * sizeof(float));
    size_t read_total = 0;
    bool ordered = true;
    while (read_total < TOTAL) {
        const size_t got = audio_ring_read(ring, buffer, CHUNK);
        for (size_t i = 0; i < got; i++) {
            if (buffer[i] != (float)(read_total + i)) ordered = false;
        }
        read_total += got;
    }
    pthread_join(thread, NULL);

    check(ordered, "4M samples arrive in order, none torn or duplicated");
    check(read_total == TOTAL, "every sample written was read exactly once");
    check(audio_ring_dropped(ring) == 0, "back-pressured producer dropped nothing");
    check(audio_ring_available(ring) == 0, "the ring drains empty");

    free(buffer);
    audio_ring_free(ring);

    printf("\n%s\n", failures == 0 ? "PASS" : "FAIL");
    return failures == 0 ? 0 : 1;
}
