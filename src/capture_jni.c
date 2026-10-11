/*
 * capture_jni — the Android microphone's way into audio_ring.
 *
 * Kotlin owns AudioRecord; this is the only part of the ring it touches. The
 * buffers are direct ByteBuffers allocated once per capture, so a write is a
 * pointer lookup and a memcpy — no array pinning, no allocation, no copy into
 * the Java heap and back out.
 *
 * Only built for Android.
 */
#include <jni.h>
#include <stdint.h>

#include "audio_ring.h"

#define JNI_FN(name) Java_com_transcribecpp_transcribe_1cpp_AudioCapture_##name

JNIEXPORT jlong JNICALL JNI_FN(nativeRingCreate)(JNIEnv * env, jclass cls, jint frames) {
    (void) env;
    (void) cls;
    return frames > 0 ? (jlong) (intptr_t) audio_ring_create((size_t) frames) : 0;
}

JNIEXPORT void JNICALL JNI_FN(nativeRingFree)(JNIEnv * env, jclass cls, jlong ring) {
    (void) env;
    (void) cls;
    audio_ring_free((struct audio_ring *) (intptr_t) ring);
}

/* All of `frames` or none, as audio_ring_write. A rejected buffer is recorded
 * as dropped rather than retried: the capture thread's next read is already
 * waiting, so a retry would only fall further behind. */
JNIEXPORT jboolean JNICALL JNI_FN(nativeWriteFloat)(JNIEnv * env, jclass cls, jlong ring, jobject buffer,
                                                    jint frames) {
    (void) cls;
    struct audio_ring * r   = (struct audio_ring *) (intptr_t) ring;
    const float *       src = (const float *) (*env)->GetDirectBufferAddress(env, buffer);
    if (r == NULL || src == NULL || frames <= 0) {
        return JNI_FALSE;
    }
    if (audio_ring_write(r, src, (size_t) frames)) {
        return JNI_TRUE;
    }
    audio_ring_note_dropped(r, (size_t) frames);
    return JNI_FALSE;
}

/* For devices whose AudioRecord refuses float input. Converted in slices
 * through a stack buffer; the room check up front keeps the write all-or-
 * nothing, which is safe because only this thread adds to the ring and the
 * reader can only make more room. */
JNIEXPORT jboolean JNICALL JNI_FN(nativeWritePcm16)(JNIEnv * env, jclass cls, jlong ring, jobject buffer,
                                                    jint frames) {
    (void) cls;
    struct audio_ring * r   = (struct audio_ring *) (intptr_t) ring;
    const int16_t *     src = (const int16_t *) (*env)->GetDirectBufferAddress(env, buffer);
    if (r == NULL || src == NULL || frames <= 0) {
        return JNI_FALSE;
    }
    const size_t n = (size_t) frames;
    if (audio_ring_capacity(r) - audio_ring_available(r) < n) {
        audio_ring_note_dropped(r, n);
        return JNI_FALSE;
    }
    float slice[512];
    for (size_t done = 0; done < n;) {
        size_t count = n - done < 512 ? n - done : 512;
        for (size_t i = 0; i < count; i++) {
            slice[i] = (float) src[done + i] / 32768.0f;
        }
        audio_ring_write(r, slice, count);
        done += count;
    }
    return JNI_TRUE;
}
