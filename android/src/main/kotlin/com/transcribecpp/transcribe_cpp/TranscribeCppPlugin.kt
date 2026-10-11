package com.transcribecpp.transcribe_cpp

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * The plugin's control plane, as on iOS: only control and state cross these
 * channels. The engine, the VAD and the capture ring are reached from Dart over
 * FFI.
 */
class TranscribeCppPlugin : FlutterPlugin {

    private val channels = mutableListOf<MethodChannel>()
    private var states: EventChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val messenger = binding.binaryMessenger

        channels += MethodChannel(messenger, "transcribe_cpp/storage").apply {
            setMethodCallHandler(ModelStorage(binding.applicationContext))
        }

        // Microphone capture is not implemented on Android yet. Refusing with
        // a named error beats a MissingPluginException, which reads like a
        // build problem.
        channels += MethodChannel(messenger, "transcribe_cpp/capture").apply {
            setMethodCallHandler { _, result ->
                result.error(
                    "unsupported",
                    "Microphone capture is not available on Android yet. " +
                        "TranscribeSession.replay works.",
                    null,
                )
            }
        }
        // Answers the session's subscription with no events, rather than an
        // error on a stream it listens to before every start.
        states = EventChannel(messenger, "transcribe_cpp/capture_state").apply {
            setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {}
                override fun onCancel(arguments: Any?) {}
            })
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channels.forEach { it.setMethodCallHandler(null) }
        channels.clear()
        states?.setStreamHandler(null)
        states = null
    }
}
