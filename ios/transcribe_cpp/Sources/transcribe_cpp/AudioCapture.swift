import AVFoundation
import CallKit
import Foundation

// TranscribeCppC is a SwiftPM module name. Under CocoaPods the C and Swift
// compile into one mixed-language pod and the C declarations arrive through the
// generated umbrella header instead, with no module to import — hence the
// guard rather than a plain import.
#if canImport(TranscribeCppC)
    import TranscribeCppC
#endif

/// What the capture layer is doing, as a value the Dart side can render.
///
/// `interrupted` and `recovering` are separate from `stopped` on purpose: the
/// user did not ask for either, the session is expected to come back, and a UI
/// that collapses them into "stopped" tells the user their dictation ended when
/// it is about to resume.
@objc public enum CaptureState: Int {
    case idle = 0
    case starting = 1
    case running = 2
    case interrupted = 3
    case recovering = 4
    case failed = 5
}

/// Continuous microphone capture, resampled to the 16 kHz mono float32 the
/// engine takes, delivered through a lock-free ring.
///
/// The hard part of this class is not starting the microphone; it is staying
/// alive. A hands-free session runs for minutes or hours, during which the user
/// takes a call, walks away from a Bluetooth headset, plugs in earbuds, or
/// triggers a media-services reset. Each of those invalidates something
/// different, and the recovery is different in each case:
///
///   * **Interruption** (call, Siri, another app taking the session): the
///     engine is stopped for us and the session deactivated. On `.ended` with
///     `.shouldResume` we reactivate and restart. Without the `.shouldResume`
///     check, restarting fights whatever still holds the session and fails.
///   * **Route change** (Bluetooth connect/disconnect, headset plug): the input
///     hardware format changes underneath us — built-in mic is 48 kHz, an HFP
///     headset is 16 kHz or even 8 kHz. `AVAudioEngine` will not re-derive the
///     tap format on its own, so the tap and converter are rebuilt against the
///     new format. This is the one people get wrong: capture keeps "working"
///     and silently produces garbage at the wrong rate.
///   * **Media services reset**: every session, engine, and node handle is
///     dead. Nothing is salvageable and everything is rebuilt from scratch.
///   * **A call already in progress at start**: no interruption is posted,
///     because nothing was interrupted, so the session would "start" on a
///     microphone the call owns. Start checks for a call first, reports
///     `interrupted`, and starts when the last call ends.
///
/// Audio never crosses into Dart through a platform channel. The tap writes
/// into `audio_ring`, and a Dart isolate reads it over FFI. A channel hop per
/// buffer would put ~60 messages a second on the platform thread and couple
/// capture to UI-thread latency, which is exactly what a hands-free session
/// cannot afford.
///
/// Everything but the tap runs on `queue` and only there: the caller's
/// start and stop, and the session notifications, which iOS posts from
/// whatever thread it likes. Not the main thread, because deactivating the
/// session and stopping the engine block, and since Flutter 3.29 Dart runs on
/// the main thread, so a stop there freezes the app's animations while it
/// waits.
public final class AudioCapture {

    /// The rate the engine takes. Not configurable — the models are trained
    /// here and transcribe.cpp links no resampler.
    public static let sampleRate: Double = 16000

    /// Ring depth. Eight seconds is far more than the ~16 ms drain loop needs;
    /// it is sized so that a Dart isolate descheduled by a long GC pause or a
    /// busy CPU still loses nothing.
    private static let ringSeconds = 8

    public private(set) var state: CaptureState = .idle {
        didSet {
            if state != oldValue { onStateChange?(state, lastErrorMessage) }
        }
    }

    /// Called on `queue` whenever `state` changes.
    public var onStateChange: ((CaptureState, String?) -> Void)?

    /// Address of the ring, for Dart to attach to over FFI. Stable for the
    /// lifetime of this object, across every restart and recovery — so the
    /// reader never has to re-fetch it when the route changes.
    public var ringAddress: UInt { UInt(bitPattern: ring) }

    private let ring: OpaquePointer
    private let queue: DispatchQueue
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var tapInstalled = false
    private var lastErrorMessage: String?

    /// Sees phone calls and VoIP calls that report through CallKit. Its
    /// delegate callbacks arrive on `queue`.
    private let calls = CXCallObserver()
    private let callWatcher = CallWatcher()

    /// True while we are holding off because a call owned the microphone at
    /// start, as opposed to an interruption iOS told us about.
    private var waitingForCall = false

    /// Reused across callbacks. Allocating a buffer inside the tap would put a
    /// malloc on an audio thread.
    private var outputBuffer: AVAudioPCMBuffer?

    /// Whether the caller asked for Apple's voice processing (AEC, AGC, noise
    /// suppression). Off by default: for speech recognition the cleanest signal
    /// wins, and `.measurement` mode plus raw input is what the models were
    /// trained on. Turn it on when the app plays audio while listening, where
    /// echo cancellation stops the app transcribing its own output.
    private let voiceProcessing: Bool

    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioCapture.sampleRate,
        channels: 1,
        interleaved: false
    )!

    /// Fails only if the ring allocation does — half a megabyte, so in
    /// practice only under genuine memory pressure. Failable rather than
    /// trapping: the host app deserves to handle that itself.
    ///
    /// `queue` must be serial, and every call into this object made on it.
    public init?(voiceProcessing: Bool = false, queue: DispatchQueue) {
        self.voiceProcessing = voiceProcessing
        self.queue = queue
        let frames = Int(AudioCapture.sampleRate) * AudioCapture.ringSeconds
        guard let ring = audio_ring_create(frames) else { return nil }
        self.ring = ring
        observeSessionNotifications()
        callWatcher.onChange = { [weak self] in self?.callsChanged() }
        calls.setDelegate(callWatcher, queue: queue)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        teardownEngine()
        audio_ring_free(ring)
    }

    // MARK: - Lifecycle

    /// Asks for microphone permission. Returns false if the user has denied it,
    /// in which case the app should route them to Settings rather than retry.
    public static func requestPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    public func start() throws {
        guard state != .running && state != .starting else { return }
        if callInProgress {
            waitForCall()
            return
        }
        state = .starting
        do {
            try configureSession()
            try startEngine()
            state = .running
        } catch {
            fail(error)
            throw error
        }
    }

    public func stop() {
        waitingForCall = false
        teardownEngine()
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        // Deliberately not resetting the ring: audio captured before stop() is
        // still the user's, and the reader may not have drained it yet.
        state = .idle
    }

    // MARK: - Session

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()

        // `.record` rather than `.playAndRecord`: a category that can play
        // audio makes iOS reserve an output path and, on some routes, engage
        // processing we do not want. Callers that need playback while
        // listening should be using voiceProcessing anyway.
        //
        // `.allowBluetooth` opts into HFP headsets. Worth knowing what that
        // costs: HFP is a narrowband link, so the audio arrives band-limited
        // and word error rate goes up measurably compared to the built-in mic.
        // It is still the right default — a user wearing headphones expects
        // them to be the microphone — but it is a quality cliff, not a
        // neutral choice.
        try session.setCategory(
            .record,
            mode: voiceProcessing ? .voiceChat : .measurement,
            options: [.allowBluetooth]
        )
        try session.setPreferredSampleRate(AudioCapture.sampleRate)

        // A short buffer keeps the endpointer responsive; the hardware is free
        // to ignore this and often does.
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: [])
    }

    private func startEngine() throws {
        let input = engine.inputNode

        // Voice processing must be set before the tap and while the engine is
        // stopped; toggling it changes the node's format.
        if input.isVoiceProcessingEnabled != voiceProcessing {
            try input.setVoiceProcessingEnabled(voiceProcessing)
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            // Happens when the session is not active or the route is mid-change.
            // Reporting it beats installing a tap that yields silence.
            throw CaptureError.noInputFormat
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.converterUnavailable(
                from: inputFormat.sampleRate,
                channels: inputFormat.channelCount
            )
        }
        self.converter = converter

        // One output buffer, sized for the worst case: a full input buffer's
        // worth of frames after conversion, plus slack for rate mismatch.
        let capacity = AVAudioFrameCount(AudioCapture.sampleRate * 0.5)
        outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) {
            [weak self] buffer, _ in
            self?.handle(buffer)
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
    }

    private func teardownEngine() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        converter = nil
        outputBuffer = nil
    }

    // MARK: - Audio thread

    /// Runs on an audio thread. No allocation, no locks, no Dart.
    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let output = outputBuffer else { return }

        output.frameLength = output.frameCapacity
        var consumed = false
        var error: NSError?

        let status = converter.convert(to: output, error: &error) { _, outStatus in
            // The converter pulls until satisfied; this tap has exactly one
            // buffer to give, so the second pull must report starvation rather
            // than hand the same audio over twice.
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, output.frameLength > 0,
              let channel = output.floatChannelData?[0] else { return }

        let frames = Int(output.frameLength)
        if !audio_ring_write(ring, channel, frames) {
            // The reader has stalled for the whole 8-second depth. Record the
            // hole so the reader can reset its carried state instead of
            // splicing across it.
            audio_ring_note_dropped(ring, frames)
        }
    }

    // MARK: - Calls

    private var callInProgress: Bool {
        calls.calls.contains { !$0.hasEnded }
    }

    private func waitForCall() {
        waitingForCall = true
        lastErrorMessage = "a call is using the microphone"
        state = .interrupted
        lastErrorMessage = nil
    }

    private func callsChanged() {
        guard waitingForCall, !callInProgress else { return }
        waitingForCall = false
        restart(reason: "call ended")
    }

    // MARK: - Disruption

    private func observeSessionNotifications() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleMediaServicesReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
    }

    @objc private func handleInterruption(_ note: Notification) {
        let info = note.userInfo
        queue.async { [weak self] in self?.interruption(info) }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        let info = note.userInfo
        queue.async { [weak self] in self?.routeChange(info) }
    }

    @objc private func handleMediaServicesReset(_: Notification) {
        queue.async { [weak self] in self?.mediaServicesReset() }
    }

    private func interruption(_ info: [AnyHashable: Any]?) {
        guard let info,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            // The session is already inactive and the engine already stopped by
            // the time this arrives; tearing down here only releases our tap.
            guard state == .running else { return }
            teardownEngine()
            state = .interrupted

        case .ended:
            guard state == .interrupted else { return }
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            // Without .shouldResume the interrupting app still holds the
            // session. Restarting anyway fails, and worse, fails in a way that
            // looks like a device problem.
            guard options.contains(.shouldResume) else {
                state = .idle
                return
            }
            restart(reason: "interruption ended")

        @unknown default:
            break
        }
    }

    private func routeChange(_ info: [AnyHashable: Any]?) {
        guard state == .running || state == .interrupted else { return }
        guard let info,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return }

        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .override,
             .routeConfigurationChange:
            // The input format may have changed — 48 kHz built-in mic to a
            // 16 kHz HFP headset and back. The converter and tap are bound to
            // the old format and must be rebuilt, or capture silently produces
            // resampled nonsense.
            restart(reason: "route changed")

        case .categoryChange, .unknown, .wakeFromSleep,
             .noSuitableRouteForCategory:
            break

        @unknown default:
            break
        }
    }

    private func mediaServicesReset() {
        guard state != .idle else { return }
        // Everything is invalid, including handles that still look alive.
        teardownEngine()
        engine.reset()
        restart(reason: "media services reset")
    }

    /// Rebuilds capture in place. Failures are surfaced rather than retried in
    /// a loop: a route that cannot be opened will not fix itself by being
    /// asked again immediately, and a retry loop on an audio session is a
    /// reliable way to wedge the device.
    private func restart(reason: String) {
        state = .recovering
        teardownEngine()
        do {
            try configureSession()
            try startEngine()
            state = .running
        } catch {
            lastErrorMessage = "\(reason): \(error.localizedDescription)"
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        lastErrorMessage = lastErrorMessage ?? error.localizedDescription
        state = .failed
    }
}

/// CallKit's delegate must be an Objective-C object, and `AudioCapture` is
/// not one.
private final class CallWatcher: NSObject, CXCallObserverDelegate {
    var onChange: (() -> Void)?

    func callObserver(_: CXCallObserver, callChanged _: CXCall) {
        onChange?()
    }
}

public enum CaptureError: LocalizedError {
    case noInputFormat
    case converterUnavailable(from: Double, channels: AVAudioChannelCount)

    public var errorDescription: String? {
        switch self {
        case .noInputFormat:
            return "The audio input has no usable format; the session is "
                + "inactive or the route is still changing."
        case let .converterUnavailable(rate, channels):
            return "No converter from \(Int(rate)) Hz / \(channels) ch to "
                + "16 kHz mono."
        }
    }
}
