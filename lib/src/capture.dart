import 'dart:async';

import 'package:flutter/services.dart';

/// What the microphone is doing.
///
/// [interrupted] and [recovering] are distinct from [idle] because the user did
/// not ask for either and the session is expected to come back. A UI that
/// collapses them into "stopped" tells someone their dictation ended when it is
/// about to resume on its own.
enum CaptureState {
  idle,
  starting,
  running,

  /// A call, the assistant, or another app took the microphone. Capture
  /// resumes by itself if the interrupting app releases it cleanly.
  ///
  /// On Android the recording keeps running and delivers silence instead, and
  /// this is also reported when the app goes to the background without a
  /// microphone foreground service, or the user turns on the microphone
  /// privacy toggle. Android reports silencing from version 10; before that,
  /// it is inferred from a second of exact digital silence, which a live
  /// microphone does not produce, so it arrives about a second late.
  interrupted,

  /// Rebuilding after an interruption, a route change, a media-services reset
  /// (iOS) or an audio-server restart (Android). Audio is not arriving right
  /// now but is expected to shortly.
  recovering,

  /// Capture stopped and will not resume without another [MicrophoneCapture.start].
  failed;

  static CaptureState fromCode(int code) =>
      code >= 0 && code < values.length ? values[code] : CaptureState.failed;
}

/// A capture state change, with the reason when there is one.
class CaptureStatus {
  const CaptureStatus(this.state, [this.message]);

  final CaptureState state;

  /// Why, for [CaptureState.failed] and [CaptureState.recovering] — e.g.
  /// "route changed: ...". Null otherwise.
  final String? message;

  @override
  String toString() => message == null ? '$state' : '$state ($message)';
}

/// Where a started capture session is delivering audio.
class CaptureHandle {
  const CaptureHandle({required this.ringAddress, required this.sampleRate});

  /// Address of the native ring, for [AudioRingReader.attach]. Stable across
  /// restarts, route changes and media-services resets, so a reader attaches
  /// once and never re-attaches.
  final int ringAddress;

  final int sampleRate;
}

/// The microphone, as a control surface.
///
/// Only control and state cross the platform channel. Audio does not — it goes
/// into a native ring that a Dart isolate reads over FFI. Sixty method-channel
/// messages a second would serialise every buffer through the platform thread
/// and make capture latency depend on how busy the UI is, which a hands-free
/// session cannot afford.
class MicrophoneCapture {
  static const MethodChannel _methods = MethodChannel('transcribe_cpp/capture');
  static const EventChannel _events = EventChannel(
    'transcribe_cpp/capture_state',
  );

  static Stream<CaptureStatus>? _states;

  /// Capture state transitions, including ones nobody asked for.
  ///
  /// Broadcast and shared: the native side has one capture object, so there is
  /// one stream of truth about it.
  static Stream<CaptureStatus> get states =>
      _states ??= _events.receiveBroadcastStream().map((dynamic event) {
        final map = (event as Map).cast<Object?, Object?>();
        return CaptureStatus(
          CaptureState.fromCode(map['state']! as int),
          map['message'] as String?,
        );
      }).asBroadcastStream();

  /// Asks for microphone permission, returning whether it was granted.
  ///
  /// A false here can mean "just denied" or "denied some time ago and the
  /// system did not even ask" — iOS prompts once, Android twice. Send the user
  /// to Settings rather than calling this again in a loop.
  static Future<bool> requestPermission() async =>
      await _methods.invokeMethod<bool>('requestPermission') ?? false;

  /// Starts capture and returns where the audio will appear.
  ///
  /// [voiceProcessing] turns on the platform's echo cancellation, noise
  /// suppression and automatic gain (Apple's voice processing; Android's
  /// VOICE_COMMUNICATION source). Off by default: speech models want the cleanest signal
  /// they can get, and the processing chain is tuned for telephony
  /// intelligibility rather than transcription. Turn it on when the app plays
  /// audio while listening — without it the app transcribes its own output.
  ///
  /// The setting is fixed for the life of a capture session; changing it needs
  /// a [dispose] first, because it changes the input node's format and can only
  /// be toggled while the engine is stopped.
  static Future<CaptureHandle> start({bool voiceProcessing = false}) async {
    final result = await _methods.invokeMapMethod<String, Object?>('start', {
      'voiceProcessing': voiceProcessing,
    });
    if (result == null) {
      throw StateError('capture start returned nothing');
    }
    return CaptureHandle(
      ringAddress: result['ringAddress']! as int,
      sampleRate: result['sampleRate']! as int,
    );
  }

  /// Stops capture. Audio already in the ring stays there to be drained.
  static Future<void> stop() => _methods.invokeMethod<void>('stop');

  /// Stops capture and releases the native capture object, invalidating the
  /// ring address. Readers must be disposed first.
  static Future<void> dispose() => _methods.invokeMethod<void>('dispose');
}
