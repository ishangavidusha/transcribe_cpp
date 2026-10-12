import Flutter
import UIKit

/// The plugin's control plane.
///
/// Only control and state travel over these channels — start, stop, permission,
/// and the capture state machine's transitions. Audio does not: the tap writes
/// into a C ring and a Dart isolate reads it over FFI. Sending PCM through a
/// method channel would put roughly sixty messages a second on the platform
/// thread, serialise every buffer, and make capture latency a function of how
/// busy the UI is.
///
/// What Dart gets instead is `ringAddress`, an integer it can hand to
/// `Pointer.fromAddress`. That address is stable for the life of the capture
/// object — across restarts, route changes and media-services resets — so the
/// reader never re-attaches.
///
/// Capture calls run on a serial queue and answer on the main thread. Since
/// Flutter 3.29 Dart runs on the main thread, and stopping waits on the audio
/// session, so a stop made there would freeze the app's animations.
public class TranscribeCppPlugin: NSObject, FlutterPlugin {

    /// Owns `capture`: it is only read or written on this queue.
    private let control = DispatchQueue(
        label: "transcribe_cpp.capture",
        qos: .userInitiated
    )
    private var capture: AudioCapture?
    private var stateSink: FlutterEventSink?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = TranscribeCppPlugin()

        let methods = FlutterMethodChannel(
            name: "transcribe_cpp/capture",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: methods)

        let events = FlutterEventChannel(
            name: "transcribe_cpp/capture_state",
            binaryMessenger: registrar.messenger()
        )
        events.setStreamHandler(instance)

        // File system only; nothing here touches the capture object.
        let storage = FlutterMethodChannel(
            name: "transcribe_cpp/storage",
            binaryMessenger: registrar.messenger()
        )
        storage.setMethodCallHandler(ModelStorage.handle)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "requestPermission":
            Task {
                let granted = await AudioCapture.requestPermission()
                await MainActor.run { result(granted) }
            }

        case "start":
            let args = call.arguments as? [String: Any]
            let voiceProcessing = args?["voiceProcessing"] as? Bool ?? false
            control.async { [self] in
                let reply = start(voiceProcessing: voiceProcessing)
                DispatchQueue.main.async { result(reply) }
            }

        case "stop":
            control.async { [self] in
                capture?.stop()
                DispatchQueue.main.async { result(nil) }
            }

        case "dispose":
            control.async { [self] in
                capture?.stop()
                capture = nil
                DispatchQueue.main.async { result(nil) }
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// On `control`. Returns the method call's reply.
    private func start(voiceProcessing: Bool) -> Any {
        // A capture object built for a different processing mode cannot be
        // reused: voice processing changes the input node's format, and it
        // can only be toggled while the engine is stopped.
        if capture == nil {
            guard let created = AudioCapture(
                voiceProcessing: voiceProcessing,
                queue: control
            ) else {
                return FlutterError(
                    code: "ring_alloc_failed",
                    message: "Could not allocate the capture ring buffer.",
                    details: nil
                )
            }
            created.onStateChange = { [weak self] state, message in
                self?.emit(state: state, message: message)
            }
            capture = created
        }

        do {
            try capture?.start()
            return ["ringAddress": capture?.ringAddress ?? 0,
                    "sampleRate": Int(AudioCapture.sampleRate)]
        } catch {
            return FlutterError(
                code: "start_failed",
                message: error.localizedDescription,
                details: nil
            )
        }
    }

    private func emit(state: CaptureState, message: String?) {
        // Channel sends must happen on the platform thread; state changes
        // arrive on the control queue.
        DispatchQueue.main.async { [weak self] in
            var payload: [String: Any] = ["state": state.rawValue]
            if let message { payload["message"] = message }
            self?.stateSink?(payload)
        }
    }
}

extension TranscribeCppPlugin: FlutterStreamHandler {
    public func onListen(
        withArguments _: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        stateSink = events
        return nil
    }

    public func onCancel(withArguments _: Any?) -> FlutterError? {
        stateSink = nil
        return nil
    }
}
