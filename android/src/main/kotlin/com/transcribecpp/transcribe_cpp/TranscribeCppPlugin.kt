package com.transcribecpp.transcribe_cpp

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * The plugin's control plane, as on iOS: only control and state cross these
 * channels — start, stop, permission, and the capture state machine's
 * transitions. Audio goes into a C ring that a Dart isolate reads over FFI,
 * and Dart gets the ring's address to attach to.
 */
class TranscribeCppPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    PluginRegistry.RequestPermissionsResultListener {

    private companion object {
        /** Arbitrary, but unique enough not to collide with the host app's. */
        const val PERMISSION_REQUEST = 0x7C01
    }

    private lateinit var context: Context
    private var storage: MethodChannel? = null
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var stateSink: EventChannel.EventSink? = null

    private var activity: ActivityPluginBinding? = null
    private val pendingPermission = mutableListOf<MethodChannel.Result>()

    private var capture: AudioCapture? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        val messenger = binding.binaryMessenger

        // File system only; nothing here touches the capture object.
        storage = MethodChannel(messenger, "transcribe_cpp/storage").apply {
            setMethodCallHandler(ModelStorage(context))
        }
        methods = MethodChannel(messenger, "transcribe_cpp/capture").apply {
            setMethodCallHandler(this@TranscribeCppPlugin)
        }
        events = EventChannel(messenger, "transcribe_cpp/capture_state").apply {
            setStreamHandler(this@TranscribeCppPlugin)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        capture?.dispose()
        capture = null
        storage?.setMethodCallHandler(null)
        methods?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        storage = null
        methods = null
        events = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestPermission" -> requestPermission(result)

            "start" -> {
                val voiceProcessing = call.argument<Boolean>("voiceProcessing") ?: false
                val current = capture ?: AudioCapture.create(context, voiceProcessing)?.also {
                    it.onStateChange = ::emit
                    capture = it
                }
                if (current == null) {
                    result.error("ring_alloc_failed", "Could not allocate the capture ring buffer.", null)
                    return
                }
                try {
                    current.start()
                    result.success(
                        mapOf(
                            "ringAddress" to current.ringAddress,
                            "sampleRate" to AudioCapture.SAMPLE_RATE,
                        ),
                    )
                } catch (e: Exception) {
                    result.error("start_failed", e.message, null)
                }
            }

            "stop" -> {
                capture?.stop()
                result.success(null)
            }

            "dispose" -> {
                capture?.dispose()
                capture = null
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    /**
     * Asks only when the answer is not already known. Android stops showing
     * the dialog after the user declines twice and reports a denial at once,
     * which is the same thing the Dart side already tells callers to expect
     * from iOS: send the user to Settings rather than asking again.
     */
    private fun requestPermission(result: MethodChannel.Result) {
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        val host = activity?.activity
        if (host == null) {
            // No activity to show a dialog from: a background engine.
            result.success(false)
            return
        }
        pendingPermission += result
        if (pendingPermission.size == 1) {
            host.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION_REQUEST)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermission.forEach { it.success(granted) }
        pendingPermission.clear()
        return true
    }

    private fun emit(state: CaptureState, message: String?) {
        val payload = mutableMapOf<String, Any>("state" to state.code)
        if (message != null) payload["message"] = message
        stateSink?.success(payload)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        stateSink = events
    }

    override fun onCancel(arguments: Any?) {
        stateSink = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addRequestPermissionsResultListener(this)
    }

    // A rotation recreates the activity under an open dialog, and the answer
    // arrives at the new one; pending requests wait for it.
    override fun onDetachedFromActivityForConfigChanges() {
        activity?.removeRequestPermissionsResultListener(this)
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges()
        // The activity is gone for good, so its dialog will never answer.
        pendingPermission.forEach { it.success(false) }
        pendingPermission.clear()
    }
}
