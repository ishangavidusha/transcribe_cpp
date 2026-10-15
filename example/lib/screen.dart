import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps the screen on while something needs it.
///
/// Listening: a dictation app whose screen dims mid-sentence is fighting its
/// user. Downloading: on iOS a locked phone suspends the app and the download
/// with it; it can be resumed, but not finishing is the better experience.
///
/// Like background listening, this is the app's decision, not the package's.
abstract final class Screen {
  static const _channel = MethodChannel('transcribe_cpp_example/screen');
  static final _reasons = <String>{};

  /// Keeps the screen on for [reason] until called again with [on] false.
  static Future<void> keepOn(String reason, bool on) async {
    final before = _reasons.isNotEmpty;
    on ? _reasons.add(reason) : _reasons.remove(reason);
    if (_reasons.isNotEmpty == before) return;
    try {
      await _channel.invokeMethod<void>('keepOn', _reasons.isNotEmpty);
    } on PlatformException catch (e) {
      debugPrint('keep screen on: $e');
    }
  }
}
