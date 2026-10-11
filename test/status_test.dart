import 'package:flutter_test/flutter_test.dart';
import 'package:transcribe_cpp/src/bindings.g.dart';
import 'package:transcribe_cpp/src/status.dart';

void main() {
  // TranscribeStatus is hand-written, so an engine update can add a code it
  // does not know. fromCode then falls back to invalidArg, and a
  // result-bearing code is thrown instead of read: engine 0.3.0 added
  // OUTPUT_REPETITION (19) and every looping utterance would have been lost.
  test('every engine status code has a TranscribeStatus', () {
    final mirrored = {for (final s in TranscribeStatus.values) s.code};
    final missing = [
      for (final s in transcribe_status.values)
        if (!mirrored.contains(s.value)) '${s.name} (${s.value})',
    ];
    expect(missing, isEmpty);
  });

  test('a decode stopped for repetition keeps its partial transcript', () {
    expect(TranscribeStatus.fromCode(19), TranscribeStatus.outputRepetition);
    expect(TranscribeStatus.outputRepetition.hasPartialResult, isTrue);
  });
}
