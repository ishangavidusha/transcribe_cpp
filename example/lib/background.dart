import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps a session listening after the app leaves the screen.
///
/// Not part of transcribe_cpp: background listening is a decision about the
/// app's permissions and its store listing, so it belongs to the app. See
/// "Listening in the background" in the package README.
///
/// On Android this starts the example's foreground service of type
/// `microphone` (ListeningService.kt). On iOS there is nothing to do at run
/// time: the `audio` background mode in Info.plist keeps an active audio
/// session running.
abstract final class BackgroundListening {
  static const _channel = MethodChannel('transcribe_cpp_example/background');

  /// Call after `TranscribeSession.start()`, while the app is in front.
  static Future<void> begin() => _call('start');

  /// Call after `TranscribeSession.stop()`.
  static Future<void> end() => _call('stop');

  static Future<void> _call(String method) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>(method);
    } on PlatformException catch (e) {
      // Listening in front still works; only leaving the app would stop it.
      debugPrint('background listening: $e');
    }
  }
}
