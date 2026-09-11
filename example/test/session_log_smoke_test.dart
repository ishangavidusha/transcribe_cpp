import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcribe_cpp/transcribe_cpp.dart';
import 'package:transcribe_cpp_example/session_log.dart';

Utterance _utterance({bool truncated = false}) => Utterance(
  audio: Float32List.fromList(List<double>.filled(16000, 0.2)),
  start: const Duration(seconds: 3),
  end: const Duration(seconds: 4),
  speechStart: const Duration(milliseconds: 3300),
  speechEnd: const Duration(milliseconds: 3900),
  truncated: truncated,
);

UtteranceResult _result(String text, {bool isFinal = true, String? stable}) =>
    UtteranceResult(
      utterance: _utterance(),
      transcript: Transcript(
        text: text,
        segments: const [],
        words: const [],
        tokens: const [],
      ),
      isFinal: isFinal,
      decode: const Duration(milliseconds: 87),
      stableText: stable,
    );

void main() {
  // The log is only useful if it survives the awkward runs, which are exactly
  // the runs worth reporting: nothing said at all, an empty decode, a dropout.
  // A format string that throws on a zero denominator would take the session's
  // evidence with it.
  group('SessionLog', () {
    SessionLog build({
      NormalizerConfig? normalizer = const NormalizerConfig(),
    }) => SessionLog(
      model: 'parakeet-tdt_ctc-110m',
      info: null,
      endpointer: const EndpointerConfig(),
      normalizer: normalizer,
      provisionalInterval: const Duration(milliseconds: 350),
      stableAgreement: 2,
    );

    test('a session where nobody said anything', () {
      final log = build()
        ..start()
        ..stop();
      expect(log.transcript, isEmpty);
    });

    test('a normal session', () {
      final log = build()
        ..start()
        ..level(
          const LiveLevel(
            probability: 0.9,
            gain: 3.4,
            noise: 0.0021,
            inputRms: 0.012,
          ),
        )
        ..provisional(_result('ask not', isFinal: false, stable: 'ask'))
        ..utterance(_result('ask not what'))
        ..utterance(_result('your country can do'))
        ..stop();
      expect(log.transcript, 'ask not what your country can do');
    });

    // The row's gain used to be a parameter, and the replay loop passed the
    // live capture's level — reset to 1.0x and never updated during a replay.
    // Every replay row in session_004 read `gain=1.0x` while its own in/out
    // levels implied 4.3x. The row now reads the level stream, same as the
    // summary always did.
    test('the utterance row reports the gain from the level stream', () {
      final lines = <String>[];
      final saved = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) lines.add(message);
      };
      addTearDown(() => debugPrint = saved);

      build()
        ..start()
        ..level(
          const LiveLevel(
            probability: 0.9,
            gain: 4.3,
            noise: 0.0021,
            inputRms: 0.012,
          ),
        )
        ..utterance(_result('ask not what'))
        ..stop();

      final row = lines.firstWhere((l) => l.startsWith('[1  ]'));
      expect(row, contains('gain=4.3x'));
    });

    test('empty decodes, truncation, dropouts, discards and errors', () {
      final log = build(normalizer: null)
        ..start()
        ..dropout(const Dropout(8000))
        ..discarded(
          const SpeechDiscarded(
            Duration(milliseconds: 2400),
            speechStart: Duration(milliseconds: 2080),
            speechEnd: Duration(milliseconds: 2144),
            peakProbability: 0.88,
          ),
        )
        ..captureState(const CaptureStatus(CaptureState.interrupted, 'call'))
        ..error(StateError('decode blew up'))
        ..utterance(_result(''))
        ..utterance(
          UtteranceResult(
            utterance: _utterance(truncated: true),
            transcript: const Transcript(
              text: 'a very long sentence',
              segments: [],
              words: [],
              tokens: [],
            ),
            decode: Duration.zero,
          ),
        )
        ..stop();
      expect(log.transcript, 'a very long sentence');
    });
  });
}
