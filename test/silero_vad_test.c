/*
 * Validates src/silero_vad.c against onnxruntime's own output.
 *
 * The fixture (test/fixtures/silero_jfk_reference.bin) holds one speech
 * probability per 512-sample window of samples/jfk.wav, produced by the
 * official ONNX under onnxruntime. If this passes, the C port is the same
 * function as the reference to within float tolerance — which is the only
 * claim worth making about a reimplementation.
 *
 * Build:
 *   clang -std=c11 -O2 -I src test/silero_vad_test.c src/silero_vad.c -lm \
 *     -o /tmp/silero_test
 */
#include "silero_vad.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Absolute tolerance per window. The reference is float32 and our
 * accumulation order differs, so exact equality is not the target. */
static const float TOLERANCE = 2e-3f;

static float * read_wav_16k_mono(const char * path, size_t * out_n) {
    FILE * f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return NULL; }

    uint8_t hdr[12];
    if (fread(hdr, 1, 12, f) != 12 || memcmp(hdr, "RIFF", 4) || memcmp(hdr + 8, "WAVE", 4)) {
        fprintf(stderr, "%s is not a RIFF/WAVE file\n", path);
        fclose(f); return NULL;
    }
    /* Walk chunks rather than assuming a 44-byte header. */
    for (;;) {
        uint8_t ch[8];
        if (fread(ch, 1, 8, f) != 8) { fclose(f); return NULL; }
        uint32_t size;
        memcpy(&size, ch + 4, 4);
        if (!memcmp(ch, "data", 4)) {
            const size_t n = size / 2;
            int16_t * pcm16 = (int16_t *) malloc(size);
            float *   pcm   = (float *) malloc(n * sizeof(float));
            if (!pcm16 || !pcm || fread(pcm16, 1, size, f) != size) {
                free(pcm16); free(pcm); fclose(f); return NULL;
            }
            for (size_t i = 0; i < n; i++) pcm[i] = pcm16[i] / 32768.0f;
            free(pcm16);
            fclose(f);
            *out_n = n;
            return pcm;
        }
        fseek(f, (long) size + (size & 1), SEEK_CUR);
    }
}

int main(int argc, char ** argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s <weights.bin> <audio.wav> <reference.bin>\n", argv[0]);
        return 2;
    }

    size_t n_samples = 0;
    float * pcm = read_wav_16k_mono(argv[2], &n_samples);
    if (!pcm) return 1;

    FILE * rf = fopen(argv[3], "rb");
    if (!rf) { fprintf(stderr, "cannot open %s\n", argv[3]); return 1; }
    char magic[4];
    uint32_t version, window, context, count;
    if (fread(magic, 1, 4, rf) != 4 || memcmp(magic, "SVRF", 4)) {
        fprintf(stderr, "bad reference fixture magic\n"); return 1;
    }
    if (fread(&version, 4, 1, rf) != 1 || fread(&window, 4, 1, rf) != 1 ||
        fread(&context, 4, 1, rf) != 1 || fread(&count, 4, 1, rf) != 1) {
        fprintf(stderr, "truncated reference header\n"); return 1;
    }
    float * ref = (float *) malloc(count * sizeof(float));
    if (fread(ref, sizeof(float), count, rf) != count) {
        fprintf(stderr, "truncated reference data\n"); return 1;
    }
    fclose(rf);

    printf("reference: %u windows, window=%u context=%u\n", count, window, context);
    if (window != SILERO_VAD_WINDOW || context != SILERO_VAD_CONTEXT) {
        fprintf(stderr, "fixture geometry disagrees with the implementation\n");
        return 1;
    }

    struct silero_vad * vad = silero_vad_create(argv[1]);
    if (!vad) {
        fprintf(stderr, "silero_vad_create failed: %s\n", silero_vad_last_error());
        return 1;
    }

    double max_abs = 0.0, sum_abs = 0.0;
    int    worst = -1, failures = 0, agree = 0;
    for (uint32_t i = 0; i < count; i++) {
        const size_t off = (size_t) i * SILERO_VAD_WINDOW;
        if (off + SILERO_VAD_WINDOW > n_samples) break;
        const float got = silero_vad_process(vad, pcm + off);
        const double d = fabs((double) got - (double) ref[i]);
        sum_abs += d;
        if (d > max_abs) { max_abs = d; worst = (int) i; }
        if (d > TOLERANCE) {
            if (failures < 8) {
                printf("  window %4u: got %.6f  want %.6f  (delta %.6f)\n",
                       i, got, ref[i], d);
            }
            failures++;
        }
        if ((got > 0.5f) == (ref[i] > 0.5f)) agree++;
    }

    printf("\nmax abs error : %.3e (window %d)\n", max_abs, worst);
    printf("mean abs error: %.3e\n", sum_abs / count);
    printf("speech/silence decisions matching at 0.5: %d/%u\n", agree, count);
    printf("windows over tolerance (%.0e): %d\n", (double) TOLERANCE, failures);

    silero_vad_free(vad);
    free(pcm);
    free(ref);

    if (failures) { printf("\nFAIL\n"); return 1; }
    printf("\nPASS\n");
    return 0;
}
