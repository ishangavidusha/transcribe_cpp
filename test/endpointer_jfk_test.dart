import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:transcribe_cpp/transcribe_cpp.dart';

/// Replays the per-window probabilities onnxruntime produced for jfk.wav.
///
/// The scripted tests in endpointer_test.dart prove the state machine does what
/// the config says. These ask a different question — how that behaviour lands on
/// real speech — and answer it without loading native code, by reusing the same
/// reference trace the C implementation is validated against.
class _ReplayVad implements VadModel {
  _ReplayVad(this.probabilities);

  final Float32List probabilities;
  int index = 0;

  @override
  double process(Float32List samples, {int offset = 0}) =>
      index < probabilities.length ? probabilities[index++] : 0.0;

  /// No-op: the replay position belongs to the fixture, not to model state, and
  /// rewinding it would make post-flush assertions depend on the reset call.
  @override
  void reset() {}
}

/// Reads the `SVRF` blob written alongside the C test fixture.
Float32List _referenceProbabilities() {
  final bytes = File(
    'test/fixtures/silero_jfk_reference.bin',
  ).readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  expect(String.fromCharCodes(bytes.sublist(0, 4)), 'SVRF');
  expect(data.getUint32(8, Endian.little), vadWindowSamples);
  final count = data.getUint32(16, Endian.little);
  return Float32List.fromList([
    for (var i = 0; i < count; i++) data.getFloat32(20 + i * 4, Endian.little),
  ]);
}

/// Runs the whole clip through an endpointer and returns what it produced.
(List<EndpointerEvent>, Float32List) _runJfk(EndpointerConfig config) {
  final probabilities = _referenceProbabilities();
  final ep = Endpointer(_ReplayVad(probabilities), config: config);
  final events = ep.add(Float32List(probabilities.length * vadWindowSamples))
    ..addAll(ep.flush());
  return (events, probabilities);
}

List<Utterance> _utterances(List<EndpointerEvent> events) =>
    events.whereType<SpeechEnded>().map((e) => e.utterance).toList();

void main() {
  // jfk.wav is 11.0 s of oratory, and Kennedy pauses like an orator: the trace
  // holds three gaps of 544, 992 and 1056 ms. That is much longer than
  // conversational pausing, which makes this clip a good stress case for the
  // hangover — it is long enough to split at every setting a product would
  // plausibly ship.
  group('jfk.wav', () {
    test(
      'default config splits at his rhetorical pauses, losing no speech',
      () {
        final (events, probabilities) = _runJfk(const EndpointerConfig());
        final utterances = _utterances(events);

        // One split per rhetorical pause, and no more. At 250 ms there was a
        // fifth: the 320 ms gap before his last word, a mid-sentence pause
        // that 400 ms is meant to bridge.
        expect(utterances, hasLength(4));
        expect(utterances.every((u) => !u.truncated), isTrue);
        expect(
          events.whereType<SpeechDiscarded>(),
          isEmpty,
          reason: 'nothing on this clip should be filtered as a transient',
        );

        // Every window Silero called speech must land inside some utterance,
        // with no exceptions. Splitting is a tuning choice; dropping audio is
        // a bug.
        for (var w = 0; w < probabilities.length; w++) {
          if (probabilities[w] < 0.5) continue;
          final t = Duration(milliseconds: w * 32);
          expect(
            utterances.any((u) => u.start <= t && t < u.end),
            isTrue,
            reason: 'speech at window $w (${t.inMilliseconds} ms) was dropped',
          );
        }

        // Chunks must tile the timeline: no overlap, so nothing is transcribed
        // twice, and in order.
        for (var i = 1; i < utterances.length; i++) {
          expect(
            utterances[i].start,
            greaterThanOrEqualTo(utterances[i - 1].end),
            reason: 'utterance $i overlaps its predecessor',
          );
        }

        // The final utterance exists only because flush() emitted it — his
        // last word is followed by 384 ms of silence, and nothing closes an
        // utterance at end of stream. Without flush, "your country" would
        // never arrive.
        expect(utterances.last.end.inMilliseconds, greaterThan(10500));
      },
    );

    test('the trailing burst is re-attached to the turn it belongs to', () {
      // Replaces the test that used to pin this as a known hole. Windows
      // 341-342 — 64 ms of speech closing the clip — sit 320 ms after the
      // previous *speech* window, which is why the 250 ms hangover ended the
      // utterance before them and left two windows unable to clear
      // minSpeechDuration's eight.
      //
      // But that gap is the wrong measurement. The utterance that closed
      // carried its post-roll through window 338, so the burst begins 64 ms
      // after the audio actually stopped, and reattachWithin sees it for what
      // it is: the rest of the same sentence.
      //
      // The default hangover no longer creates this case — 400 ms bridges the
      // 320 ms gap outright — so it is pinned at 250 ms, where it arises.
      // Re-attachment still matters at the default: any pause just longer
      // than the hangover produces the same shape.
      const tail = Duration(milliseconds: 341 * 32);
      const hangover = Duration(milliseconds: 250);

      final kept = _utterances(
        _runJfk(const EndpointerConfig(hangover: hangover)).$1,
      );
      expect(kept.any((u) => u.start <= tail && tail < u.end), isTrue);

      // Turn re-attachment off and the old behaviour is back — except that it
      // is now reported. This is the one place in the suite where the event
      // fires on real audio rather than a script, so it also pins what the
      // event says: a 64 ms burst, peaking well above the speech threshold,
      // which is precisely why a peak-probability rule could not have saved
      // it and proximity could.
      final (events, _) = _runJfk(
        const EndpointerConfig(
          hangover: hangover,
          reattachWithin: Duration.zero,
        ),
      );
      expect(
        _utterances(events).any((u) => u.start <= tail && tail < u.end),
        isFalse,
      );
      final discarded = events.whereType<SpeechDiscarded>().single;
      expect(discarded.speechStart, tail);
      expect(discarded.duration, const Duration(milliseconds: 64));
      expect(discarded.peakProbability, closeTo(0.876, 0.001));
    });

    test('a hangover longer than his longest pause yields one utterance', () {
      // Longest gap in the trace is 1056 ms.
      final utterances = _utterances(
        _runJfk(
          const EndpointerConfig(hangover: Duration(milliseconds: 1200)),
        ).$1,
      );

      expect(utterances, hasLength(1));
      expect(utterances.single.duration.inMilliseconds, greaterThan(10500));
      // Speech begins at window 11; the pre-roll must reach back before it.
      expect(utterances.single.start.inMilliseconds, lessThan(11 * 32));
    });

    test('hangover trades latency against how badly sentences fragment', () {
      // Same audio, three settings. This is the tuning curve made explicit: a
      // shorter hangover means the user waits less, and gets punctuation and
      // casing decided over smaller fragments, because the model only ever
      // sees one chunk at a time.
      const sweep = [100, 200, 400, 600, 800, 1000, 1200];
      final counts = [
        for (final ms in sweep)
          _utterances(
            _runJfk(EndpointerConfig(hangover: Duration(milliseconds: ms))).$1,
          ).length,
      ];

      // Monotone, not strictly so: the curve is a step function whose steps sit
      // at the clip's actual pause lengths, and settings between two pauses are
      // indistinguishable. On this clip it runs 6, 5, 4, 3, 3, 2, 1.
      for (var i = 1; i < counts.length; i++) {
        expect(
          counts[i],
          lessThanOrEqualTo(counts[i - 1]),
          reason:
              'a longer hangover must never fragment more '
              '(${sweep[i]} ms gave ${counts[i]}, '
              '${sweep[i - 1]} ms gave ${counts[i - 1]})',
        );
      }
      expect(counts.first, greaterThan(counts.last));
    });
  });
}
