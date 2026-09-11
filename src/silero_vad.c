#include "silero_vad.h"

#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* Model geometry, read off the ONNX graph rather than assumed.        */
/* ------------------------------------------------------------------ */

#define N_FFT        256
#define HOP          128
#define N_BINS       129 /* N_FFT/2 + 1 */
#define STFT_CH      258 /* N_BINS real followed by N_BINS imaginary */
#define PAD_RIGHT    64  /* ONNX Pad is [0, 64]: reflect on the right only */

#define IN_SAMPLES   (SILERO_VAD_CONTEXT + SILERO_VAD_WINDOW) /* 576 */
#define PADDED       (IN_SAMPLES + PAD_RIGHT)                 /* 640 */
#define N_FRAMES     4 /* (640 - 256)/128 + 1 */

#define HIDDEN       128
#define GATES        (4 * HIDDEN) /* 512, in PyTorch ifgo order */

/* Encoder: conv1d k=3 pad=1, strides 1,2,2,1. Time goes 4 -> 4 -> 2 -> 1 -> 1. */
#define ENC_LAYERS   4
/* Input channels per layer are implied by the previous layer's output
 * (starting from N_BINS), so only the outputs and strides are needed. */
static const int ENC_OUT[ENC_LAYERS]    = { 128, 64, 64, 128 };
static const int ENC_STRIDE[ENC_LAYERS] = { 1, 2, 2, 1 };
#define ENC_K 3
#define ENC_PAD 1

#define MAX_CH 258
#define MAX_T  N_FRAMES

/* ------------------------------------------------------------------ */

static char g_error[256];

static void set_error(const char * fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_error, sizeof(g_error), fmt, ap);
    va_end(ap);
}

const char * silero_vad_last_error(void) {
    return g_error[0] ? g_error : NULL;
}

struct tensor {
    float * data;
    int     dims[4];
    int     ndim;
    size_t  count;
};

struct silero_vad {
    float * blob; /* one allocation backing every tensor below */

    struct tensor stft_basis;              /* (258, 1, 256) */
    struct tensor enc_w[ENC_LAYERS];       /* (out, in, 3)  */
    struct tensor enc_b[ENC_LAYERS];       /* (out,)        */
    struct tensor w_ih, w_hh, b_ih, b_hh;  /* (512,128) x2, (512,) x2 */
    struct tensor out_w, out_b;            /* (1,128,1), (1,) */

    /* Carried state. */
    float context[SILERO_VAD_CONTEXT];
    float h[HIDDEN];
    float c[HIDDEN];

    /* Scratch, preallocated so the hot path never touches the allocator. */
    float input[IN_SAMPLES];
    float padded[PADDED];
    float spec[STFT_CH * N_FRAMES];
    float buf_a[MAX_CH * MAX_T];
    float buf_b[MAX_CH * MAX_T];
    float gates[GATES];
};

/* ------------------------------------------------------------------ */
/* Weight blob loading                                                 */
/* ------------------------------------------------------------------ */

/*
 * Format, little-endian, as written by tool/extract_silero_weights.py:
 *   "SVAD", u32 version, u32 n_tensors,
 *   then per tensor: u32 name_len, u32 ndim, name bytes, u32 dims[ndim],
 *   f32 data[prod(dims)].
 */

struct reader {
    const uint8_t * p;
    const uint8_t * end;
    bool            bad;
};

static uint32_t read_u32(struct reader * r) {
    if (r->bad || (size_t)(r->end - r->p) < 4) {
        r->bad = true;
        return 0;
    }
    uint32_t v;
    memcpy(&v, r->p, 4);
    r->p += 4;
    return v;
}

static const uint8_t * read_bytes(struct reader * r, size_t n) {
    if (r->bad || (size_t)(r->end - r->p) < n) {
        r->bad = true;
        return NULL;
    }
    const uint8_t * p = r->p;
    r->p += n;
    return p;
}

/* Where each named tensor lands in the struct. Order is not assumed; we match
 * by name so a regenerated blob with a different order still loads. */
struct slot {
    const char *    name;
    struct tensor * dst;
};

static bool load_blob(struct silero_vad * v, const void * data, size_t size) {
    struct reader r = { (const uint8_t *) data, (const uint8_t *) data + size, false };

    const uint8_t * magic = read_bytes(&r, 4);
    if (!magic || memcmp(magic, "SVAD", 4) != 0) {
        set_error("not a SVAD weight blob");
        return false;
    }
    const uint32_t version = read_u32(&r);
    if (version != 1) {
        set_error("unsupported SVAD version %u (expected 1)", version);
        return false;
    }
    const uint32_t n_tensors = read_u32(&r);

    struct slot slots[] = {
        { "stft.forward_basis_buffer",     &v->stft_basis },
        { "encoder.0.reparam_conv.weight", &v->enc_w[0] },
        { "encoder.0.reparam_conv.bias",   &v->enc_b[0] },
        { "encoder.1.reparam_conv.weight", &v->enc_w[1] },
        { "encoder.1.reparam_conv.bias",   &v->enc_b[1] },
        { "encoder.2.reparam_conv.weight", &v->enc_w[2] },
        { "encoder.2.reparam_conv.bias",   &v->enc_b[2] },
        { "encoder.3.reparam_conv.weight", &v->enc_w[3] },
        { "encoder.3.reparam_conv.bias",   &v->enc_b[3] },
        { "decoder.rnn.weight_ih",         &v->w_ih },
        { "decoder.rnn.weight_hh",         &v->w_hh },
        { "decoder.rnn.bias_ih",           &v->b_ih },
        { "decoder.rnn.bias_hh",           &v->b_hh },
        { "decoder.decoder.2.weight",      &v->out_w },
        { "decoder.decoder.2.bias",        &v->out_b },
    };
    const size_t n_slots = sizeof(slots) / sizeof(slots[0]);

    /* Copy the whole payload once; tensors point into it. */
    v->blob = (float *) malloc(size);
    if (!v->blob) {
        set_error("out of memory");
        return false;
    }
    memcpy(v->blob, data, size);
    const uint8_t * base = (const uint8_t *) v->blob;

    for (uint32_t i = 0; i < n_tensors; i++) {
        const uint32_t name_len = read_u32(&r);
        const uint32_t ndim     = read_u32(&r);
        if (r.bad || ndim == 0 || ndim > 4) {
            set_error("malformed tensor header at index %u", i);
            return false;
        }
        const uint8_t * name = read_bytes(&r, name_len);
        if (!name) {
            set_error("truncated tensor name at index %u", i);
            return false;
        }
        struct tensor t = { NULL, { 1, 1, 1, 1 }, (int) ndim, 1 };
        for (uint32_t d = 0; d < ndim; d++) {
            t.dims[d] = (int) read_u32(&r);
            t.count *= (size_t) t.dims[d];
        }
        const uint8_t * payload = read_bytes(&r, t.count * sizeof(float));
        if (!payload) {
            set_error("truncated tensor data at index %u", i);
            return false;
        }
        /* Point into our own copy, at the same offset. */
        t.data = (float *) (void *) (base + (payload - (const uint8_t *) data));

        for (size_t s = 0; s < n_slots; s++) {
            if (strlen(slots[s].name) == name_len &&
                memcmp(slots[s].name, name, name_len) == 0) {
                *slots[s].dst = t;
                break;
            }
        }
    }

    for (size_t s = 0; s < n_slots; s++) {
        if (slots[s].dst->data == NULL) {
            set_error("weight blob is missing '%s'", slots[s].name);
            return false;
        }
    }
    return true;
}

/* ------------------------------------------------------------------ */
/* Layers                                                              */
/* ------------------------------------------------------------------ */

/*
 * STFT as the model actually does it: a stride-128 conv1d against a stored
 * 258-channel basis (129 real followed by 129 imaginary), then magnitude.
 * The basis is baked into the weights, so there is no FFT here and no window
 * function to get wrong.
 */
static void stft_magnitude(struct silero_vad * v, float * out /* [N_BINS][N_FRAMES] */) {
    /* Reflect-pad on the RIGHT ONLY. Reflection excludes the edge sample, so
     * padded[N + i] == input[N - 2 - i], matching numpy/torch 'reflect'. */
    memcpy(v->padded, v->input, sizeof(float) * IN_SAMPLES);
    for (int i = 0; i < PAD_RIGHT; i++) {
        v->padded[IN_SAMPLES + i] = v->input[IN_SAMPLES - 2 - i];
    }

    const float * restrict basis = v->stft_basis.data;
    for (int f = 0; f < N_FRAMES; f++) {
        const float * restrict x = v->padded + f * HOP;
        for (int ch = 0; ch < STFT_CH; ch++) {
            const float * restrict w = basis + (size_t) ch * N_FFT;
            float acc = 0.0f;
            for (int t = 0; t < N_FFT; t++) {
                acc += w[t] * x[t];
            }
            v->spec[(size_t) ch * N_FRAMES + f] = acc;
        }
    }

    for (int b = 0; b < N_BINS; b++) {
        for (int f = 0; f < N_FRAMES; f++) {
            const float re = v->spec[(size_t) b * N_FRAMES + f];
            const float im = v->spec[(size_t) (b + N_BINS) * N_FRAMES + f];
            out[(size_t) b * N_FRAMES + f] = sqrtf(re * re + im * im);
        }
    }
}

static int conv_out_len(int t_in, int stride) {
    return (t_in + 2 * ENC_PAD - ENC_K) / stride + 1;
}

/* conv1d + bias + ReLU. Channel-major layout: [channel][time]. */
static int conv1d_relu(const float * restrict in, int c_in, int t_in,
                       const float * restrict w, const float * restrict b,
                       int c_out, int stride,
                       float * restrict out) {
    const int t_out = conv_out_len(t_in, stride);
    for (int oc = 0; oc < c_out; oc++) {
        const float * restrict wo = w + (size_t) oc * c_in * ENC_K;
        for (int ot = 0; ot < t_out; ot++) {
            float acc = b[oc];
            const int base = ot * stride - ENC_PAD;
            for (int ic = 0; ic < c_in; ic++) {
                const float * restrict wi = wo + (size_t) ic * ENC_K;
                const float * restrict xi = in + (size_t) ic * t_in;
                for (int k = 0; k < ENC_K; k++) {
                    const int t = base + k;
                    if (t >= 0 && t < t_in) {
                        acc += wi[k] * xi[t];
                    }
                }
            }
            out[(size_t) oc * t_out + ot] = acc > 0.0f ? acc : 0.0f;
        }
    }
    return t_out;
}

static float sigmoidf(float x) {
    return 1.0f / (1.0f + expf(-x));
}

/*
 * One LSTM step.
 *
 * Gate order is PyTorch's **i, f, g, o** — the convention the tensors are
 * named for. It is worth stating loudly because the surrounding evidence
 * points the other way: these weights feed an ONNX `LSTM` op, whose spec
 * mandates i, o, f, c, and they appear to arrive there through nothing but an
 * `Unsqueeze`. The permutation happens further upstream in the graph. Reading
 * the op signature and concluding "iofc" produces output that is still smooth,
 * still in [0,1], and still looks like a plausible VAD trace — it simply never
 * fires on speech. Verified empirically against onnxruntime: ifgo reproduces
 * the reference to 2e-6, iofc is off by up to 1.0.
 */
static void lstm_step(struct silero_vad * v, const float * restrict x) {
    const float * restrict w_ih = v->w_ih.data;
    const float * restrict w_hh = v->w_hh.data;
    const float * restrict b_ih = v->b_ih.data;
    const float * restrict b_hh = v->b_hh.data;

    for (int r = 0; r < GATES; r++) {
        const float * restrict wi = w_ih + (size_t) r * HIDDEN;
        const float * restrict wh = w_hh + (size_t) r * HIDDEN;
        float acc = b_ih[r] + b_hh[r];
        for (int k = 0; k < HIDDEN; k++) {
            acc += wi[k] * x[k] + wh[k] * v->h[k];
        }
        v->gates[r] = acc;
    }

    const float * gi = v->gates + 0 * HIDDEN; /* input  */
    const float * gf = v->gates + 1 * HIDDEN; /* forget */
    const float * gc = v->gates + 2 * HIDDEN; /* cell   */
    const float * go = v->gates + 3 * HIDDEN; /* output */

    for (int k = 0; k < HIDDEN; k++) {
        const float i_t = sigmoidf(gi[k]);
        const float f_t = sigmoidf(gf[k]);
        const float o_t = sigmoidf(go[k]);
        const float c_t = tanhf(gc[k]);
        v->c[k] = f_t * v->c[k] + i_t * c_t;
        v->h[k] = o_t * tanhf(v->c[k]);
    }
}

/* ------------------------------------------------------------------ */
/* Public API                                                          */
/* ------------------------------------------------------------------ */

struct silero_vad * silero_vad_create_from_memory(const void * data, size_t size) {
    g_error[0] = '\0';
    if (!data || size < 12) {
        set_error("weight buffer is empty or too small");
        return NULL;
    }
    struct silero_vad * v = (struct silero_vad *) calloc(1, sizeof(struct silero_vad));
    if (!v) {
        set_error("out of memory");
        return NULL;
    }
    if (!load_blob(v, data, size)) {
        silero_vad_free(v);
        return NULL;
    }
    silero_vad_reset(v);
    return v;
}

struct silero_vad * silero_vad_create(const char * weights_path) {
    g_error[0] = '\0';
    FILE * f = fopen(weights_path, "rb");
    if (!f) {
        set_error("cannot open '%s'", weights_path ? weights_path : "(null)");
        return NULL;
    }
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        set_error("cannot seek '%s'", weights_path);
        return NULL;
    }
    const long size = ftell(f);
    rewind(f);
    if (size <= 0) {
        fclose(f);
        set_error("'%s' is empty", weights_path);
        return NULL;
    }
    void * buf = malloc((size_t) size);
    if (!buf) {
        fclose(f);
        set_error("out of memory");
        return NULL;
    }
    const size_t got = fread(buf, 1, (size_t) size, f);
    fclose(f);
    if (got != (size_t) size) {
        free(buf);
        set_error("short read on '%s'", weights_path);
        return NULL;
    }
    struct silero_vad * v = silero_vad_create_from_memory(buf, (size_t) size);
    free(buf);
    return v;
}

void silero_vad_free(struct silero_vad * vad) {
    if (!vad) return;
    free(vad->blob);
    free(vad);
}

void silero_vad_reset(struct silero_vad * vad) {
    if (!vad) return;
    memset(vad->context, 0, sizeof(vad->context));
    memset(vad->h, 0, sizeof(vad->h));
    memset(vad->c, 0, sizeof(vad->c));
}

float silero_vad_process(struct silero_vad * vad, const float * window) {
    if (!vad || !window) return 0.0f;

    /* The network sees 576 samples: last window's tail, then this window.
     * Feeding only the 512 new samples returns confident silence forever. */
    memcpy(vad->input, vad->context, sizeof(float) * SILERO_VAD_CONTEXT);
    memcpy(vad->input + SILERO_VAD_CONTEXT, window, sizeof(float) * SILERO_VAD_WINDOW);
    memcpy(vad->context, window + SILERO_VAD_WINDOW - SILERO_VAD_CONTEXT,
           sizeof(float) * SILERO_VAD_CONTEXT);

    stft_magnitude(vad, vad->buf_a);

    float * in  = vad->buf_a;
    float * out = vad->buf_b;
    int c_in = N_BINS, t = N_FRAMES;
    for (int l = 0; l < ENC_LAYERS; l++) {
        t = conv1d_relu(in, c_in, t, vad->enc_w[l].data, vad->enc_b[l].data,
                        ENC_OUT[l], ENC_STRIDE[l], out);
        c_in = ENC_OUT[l];
        float * swap = in; in = out; out = swap;
    }
    /* Encoder collapses time to a single frame, so the LSTM runs one step. */

    lstm_step(vad, in);

    /* decoder: ReLU on the hidden state, conv1d(128 -> 1, k=1), sigmoid. */
    float acc = vad->out_b.data[0];
    const float * restrict w = vad->out_w.data;
    for (int k = 0; k < HIDDEN; k++) {
        const float relu = vad->h[k] > 0.0f ? vad->h[k] : 0.0f;
        acc += w[k] * relu;
    }
    return sigmoidf(acc);
}
