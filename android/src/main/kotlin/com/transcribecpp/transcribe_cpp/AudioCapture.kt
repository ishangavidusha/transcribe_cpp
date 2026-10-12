package com.transcribecpp.transcribe_cpp

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioRecordingConfiguration
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Process
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * What the capture layer is doing. Codes match the Dart `CaptureState` and the
 * iOS enum, which are indexed by them.
 */
internal enum class CaptureState(val code: Int) {
    IDLE(0),
    STARTING(1),
    RUNNING(2),
    INTERRUPTED(3),
    RECOVERING(4),
    FAILED(5),
}

/**
 * Continuous microphone capture at the 16 kHz mono float32 the engine takes,
 * delivered through the same lock-free ring as on iOS.
 *
 * Much of what the iOS capture layer has to survive, AudioRecord handles
 * itself. It resamples to 16 kHz from whatever the hardware runs at, and when
 * the route changes — a headset plugged in or pulled out — it moves to the
 * new device and keeps delivering at the rate it was opened with, so there is
 * no converter to rebuild. What is left:
 *
 *   * **Silencing.** Android does not stop a recording when something more
 *     important needs the microphone. A phone call, the assistant, another app
 *     with priority, the app going to the background without a foreground
 *     service, the privacy toggle: in each case the recording keeps running
 *     and delivers zeros. On Android 10+ the recording callback says so, and
 *     that is reported as `INTERRUPTED`, and `RUNNING` again when it lifts.
 *     Without it, a call mid-dictation looks like the user went quiet.
 *   * **A dead stream.** If the audio server restarts, reads fail with
 *     ERROR_DEAD_OBJECT and the recording has to be built again. That is
 *     `RECOVERING`, like a media-services reset on iOS.
 *
 * Bluetooth headset microphones are not used yet, unlike on iOS. A plain
 * recording gets the built-in or a wired microphone; reaching a headset's
 * needs its narrowband SCO link brought up and torn down around the
 * recording, which this does not do.
 *
 * Audio never crosses a platform channel. A capture thread reads AudioRecord
 * into a direct buffer and hands it to the ring through JNI (capture_jni.c);
 * a Dart isolate drains the ring over FFI.
 *
 * Everything else — start, stop, recovery, state — runs on [handler]'s
 * thread and only there, never the main thread. Stopping joins the capture
 * thread, and since Flutter 3.29 Dart runs on the main thread, so a stop
 * there would hold up the app's frames for as long as the join takes.
 */
internal class AudioCapture private constructor(
    private val context: Context,
    private val voiceProcessing: Boolean,
    private val handler: Handler,
    /** Address of the ring, for Dart. Stable for this object's lifetime. */
    val ringAddress: Long,
) {
    companion object {
        /** The rate the engine takes. The models are trained here. */
        const val SAMPLE_RATE = 16000

        /** As on iOS: far beyond the 16 ms drain loop, so that a Dart isolate
         *  stalled by a long GC pause still loses nothing. */
        private const val RING_SECONDS = 8

        /** 20 ms per read: short enough that the endpointer sees audio about
         *  as soon as iOS delivers it, long enough not to spin. */
        private const val CHUNK_FRAMES = SAMPLE_RATE / 50

        init {
            System.loadLibrary("transcribe_cpp")
        }

        @JvmStatic private external fun nativeRingCreate(frames: Int): Long
        @JvmStatic private external fun nativeRingFree(ring: Long)
        @JvmStatic private external fun nativeWriteFloat(ring: Long, buffer: ByteBuffer, frames: Int): Boolean
        @JvmStatic private external fun nativeWritePcm16(ring: Long, buffer: ByteBuffer, frames: Int): Boolean

        /** Null only if the ring allocation fails — half a megabyte, so in
         *  practice under genuine memory pressure. */
        fun create(context: Context, voiceProcessing: Boolean, handler: Handler): AudioCapture? {
            val ring = nativeRingCreate(SAMPLE_RATE * RING_SECONDS)
            return if (ring == 0L) null else AudioCapture(context, voiceProcessing, handler, ring)
        }
    }

    /** Called on [handler]'s thread whenever [state] changes. */
    var onStateChange: ((CaptureState, String?) -> Unit)? = null

    var state = CaptureState.IDLE
        private set

    private val audioManager = context.getSystemService(AudioManager::class.java)

    private var record: AudioRecord? = null
    private var isFloat = true
    private var thread: Thread? = null
    @Volatile private var running = false
    private var callbackRegistered = false
    private var freed = false

    private val recordingCallback = object : AudioManager.AudioRecordingCallback() {
        override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>) {
            onRecordingChanged(configs)
        }
    }

    private fun setState(next: CaptureState, message: String? = null) {
        if (next == state) return
        state = next
        onStateChange?.invoke(next, message)
    }

    fun start() {
        if (state == CaptureState.RUNNING || state == CaptureState.STARTING) return
        setState(CaptureState.STARTING)
        try {
            open()
            setState(CaptureState.RUNNING)
        } catch (e: Exception) {
            teardown()
            setState(CaptureState.FAILED, e.message)
            throw e
        }
    }

    /** Stops the microphone. Audio already in the ring stays for the reader. */
    fun stop() {
        teardown()
        setState(CaptureState.IDLE)
    }

    fun dispose() {
        stop()
        // A capture thread that did not exit still holds the ring's address.
        // Leaking half a megabyte is the lesser fault than freeing memory
        // something may write to.
        if (thread == null && !freed) {
            nativeRingFree(ringAddress)
            freed = true
        }
    }

    @SuppressLint("MissingPermission") // checked first, with a message of our own
    private fun open() {
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            throw IllegalStateException("Microphone permission has not been granted.")
        }

        // VOICE_RECOGNITION is the counterpart of iOS's .measurement mode: the
        // platform's compatibility rules ask for no noise suppression and no
        // gain control on it, which is the cleanest signal the models can get.
        // VOICE_COMMUNICATION turns on echo cancellation for apps that play
        // audio while they listen.
        val source = if (voiceProcessing) {
            MediaRecorder.AudioSource.VOICE_COMMUNICATION
        } else {
            MediaRecorder.AudioSource.VOICE_RECOGNITION
        }

        // Float where the device allows it, 16-bit where it does not; the
        // CDD only guarantees 16-bit.
        val made = build(source, AudioFormat.ENCODING_PCM_FLOAT)
            ?: build(source, AudioFormat.ENCODING_PCM_16BIT)
            ?: throw IllegalStateException("No audio input could be opened at $SAMPLE_RATE Hz.")
        isFloat = made.audioFormat == AudioFormat.ENCODING_PCM_FLOAT

        made.startRecording()
        if (made.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            made.release()
            throw IllegalStateException("The microphone did not start; another app may hold it.")
        }
        record = made

        audioManager.registerAudioRecordingCallback(recordingCallback, handler)
        callbackRegistered = true

        running = true
        thread = Thread({ readLoop(made) }, "transcribe_cpp capture").apply { start() }
    }

    @SuppressLint("MissingPermission")
    private fun build(source: Int, encoding: Int): AudioRecord? {
        val min = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, encoding)
        if (min <= 0) return null
        val bytesPerFrame = if (encoding == AudioFormat.ENCODING_PCM_FLOAT) 4 else 2
        // 200 ms of slack inside AudioRecord, so a capture thread descheduled
        // for a moment drains a backlog instead of the platform discarding it.
        val size = maxOf(min, SAMPLE_RATE / 5 * bytesPerFrame)
        return try {
            val r = AudioRecord.Builder()
                .setAudioSource(source)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(encoding)
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                        .build(),
                )
                .setBufferSizeInBytes(size)
                .build()
            if (r.state == AudioRecord.STATE_INITIALIZED) r else {
                r.release()
                null
            }
        } catch (e: UnsupportedOperationException) {
            null
        }
    }

    /** The capture thread. No allocation per read; the buffer is reused. */
    private fun readLoop(source: AudioRecord) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val bytesPerFrame = if (isFloat) 4 else 2
        val buffer = ByteBuffer.allocateDirect(CHUNK_FRAMES * bytesPerFrame)
            .order(ByteOrder.nativeOrder())

        while (running) {
            buffer.clear()
            val read = source.read(buffer, buffer.capacity(), AudioRecord.READ_BLOCKING)
            if (read < 0) {
                if (running) {
                    val error = read
                    handler.post { onReadFailed(error) }
                }
                return
            }
            val frames = read / bytesPerFrame
            if (frames == 0) continue
            // A rejected write is recorded as dropped by the native side,
            // which the reader sees and resets across.
            if (isFloat) {
                nativeWriteFloat(ringAddress, buffer, frames)
            } else {
                nativeWritePcm16(ringAddress, buffer, frames)
            }
        }
    }

    private fun teardown() {
        running = false
        // stop() then dispose() both land here; AudioManager logs a warning
        // for a second unregister.
        if (callbackRegistered) {
            audioManager.unregisterAudioRecordingCallback(recordingCallback)
            callbackRegistered = false
        }
        record?.let {
            // Unblocks the read the capture thread is waiting in.
            try {
                it.stop()
            } catch (_: IllegalStateException) {
            }
        }
        thread?.let {
            it.join(1000)
            if (!it.isAlive) thread = null
        }
        record?.release()
        record = null
    }

    /** Rebuilds once. A stream that cannot be reopened is reported rather than
     *  retried in a loop, for the same reason as on iOS: a route that will not
     *  open does not fix itself by being asked again immediately. */
    private fun onReadFailed(code: Int) {
        // Posted from the capture thread; a stop may have landed since.
        if (state != CaptureState.RUNNING && state != CaptureState.INTERRUPTED) return
        val reason = if (code == AudioRecord.ERROR_DEAD_OBJECT) "audio server restarted" else "read failed ($code)"
        setState(CaptureState.RECOVERING, reason)
        teardown()
        try {
            open()
            setState(CaptureState.RUNNING)
        } catch (e: Exception) {
            teardown()
            setState(CaptureState.FAILED, "$reason: ${e.message}")
        }
    }

    private fun onRecordingChanged(configs: List<AudioRecordingConfiguration>) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val session = record?.audioSessionId ?: return
        val ours = configs.firstOrNull { it.clientAudioSessionId == session } ?: return
        when {
            ours.isClientSilenced && state == CaptureState.RUNNING ->
                setState(CaptureState.INTERRUPTED, "the system silenced the microphone")
            !ours.isClientSilenced && state == CaptureState.INTERRUPTED ->
                setState(CaptureState.RUNNING)
        }
    }
}
