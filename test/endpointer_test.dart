import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:transcribe_cpp/transcribe_cpp.dart';

/// A [VadModel] that replays a fixed probability per window.
///
/// The point of testing against this rather than the real network: the state
/// machine and the model are independently wrong in different ways, and a
/// scripted source makes "the endpointer mishandled a dip" impossible to
/// mistake for "the model scored that window low".
class _ScriptedVad implements VadModel {
  _ScriptedVad(this.script);

  final List<double> script;
  int index = 0;
  int resets = 0;

  @override
  double process(Float32List samples, {int offset = 0}) {
    expect(samples.length - offset, greaterThanOrEqualTo(512));
    return index < script.length ? script[index++] : 0.0;
  }

  /// Deliberately does NOT rewind: the endpointer resets the model as part of
  /// closing a stream, and rewinding here would make post-flush assertions
  /// depend on that call.
  @override
  void reset() => resets++;
}

/// Builds `count` windows where every sample in window *i* holds the value *i*,
/// so an emitted utterance says exactly which windows went into it.
Float32List _markedWindows(int count) {
  final audio = Float32List(count * vadWindowSamples);
  for (var w = 0; w < count; w++) {
    for (var s = 0; s < vadWindowSamples; s++) {
      audio[w * vadWindowSamples + s] = w.toDouble();
    }
  }
  return audio;
}

/// The window indices an utterance's audio was built from.
List<int> _windowsIn(Utterance u) {
  final n = u.audio.length ~/ vadWindowSamples;
  return [for (var i = 0; i < n; i++) u.audio[i * vadWindowSamples].toInt()];
}

List<double> _script(List<(int, double)> runs) => [
  for (final (count, p) in runs) ...List<double>.filled(count, p),
];

void main() {
  // Derived from the defaults; asserted so a config change that shifts these
  // shows up here rather than as a mysterious off-by-one in another test.
  const minSpeechWindows = 8; // 250 ms
  const hangoverWindows = 13; // 400 ms
  const preRollWindows = 10; // 300 ms
  const postRollWindows = 8; // 250 ms
  const reattachWindows = 13; // 400 ms

  group('Endpointer', () {
    test('emits one utterance with pre-roll and post-roll around speech', () {
      // 20 silence, 30 speech, 30 silence.
      final vad = _ScriptedVad(_script([(20, 0.0), (30, 0.9), (30, 0.0)]));
      final ep = Endpointer(vad);
      final events = ep.add(_markedWindows(80));

      expect(events, hasLength(2));

      final started = events[0] as SpeechStarted;
      expect(started.at, const Duration(milliseconds: 640)); // window 20

      final ended = events[1] as SpeechEnded;
      final u = ended.utterance;
      expect(u.truncated, isFalse);

      // Speech runs windows 20..49; the padding reaches back preRollWindows
      // and forward postRollWindows from there.
      expect(_windowsIn(u), [
        for (var w = 20 - preRollWindows; w <= 49 + postRollWindows; w++) w,
      ]);
      expect(u.start, const Duration(milliseconds: 320)); // window 10
      expect(u.speechStart, const Duration(milliseconds: 640)); // window 20
      expect(u.speechEnd, const Duration(milliseconds: 1600)); // past window 49
      expect(u.end, const Duration(milliseconds: 1856)); // past window 57

      // Endpoint declared one hangover after the last speech window: 13
      // windows past window 49. Later than u.end, because post-roll keeps only
      // 250 ms of the 400 ms the hangover waits out — the rest is silence the
      // model never needs to see.
      expect(ended.at, const Duration(milliseconds: 2016)); // past window 62
    });

    test('discards speech too short to confirm, but says so', () {
      final vad = _ScriptedVad(
        _script([(10, 0.0), (minSpeechWindows - 1, 0.9), (30, 0.0)]),
      );
      final ep = Endpointer(vad);
      final events = ep.add(_markedWindows(10 + minSpeechWindows - 1 + 30));

      expect(
        events.whereType<SpeechEnded>(),
        isEmpty,
        reason: 'a cough must never reach the model',
      );
      expect(ep.isSpeaking, isFalse);

      // But the caller is told. A dropped burst and a silent room used to be
      // the same observation from outside, which made the filter impossible to
      // tune against a real session.
      final discarded = events.whereType<SpeechDiscarded>().single;
      expect(discarded.speechStart, Duration(milliseconds: 10 * 32));
      expect(
        discarded.duration,
        Duration(milliseconds: (minSpeechWindows - 1) * 32),
      );
      expect(discarded.peakProbability, 0.9);
    });

    test('the same short burst is kept beside speech and dropped alone', () {
      // The whole rule, as a contrast: one burst, two contexts. Nothing about
      // the audio distinguishes them — same length, same probabilities — so
      // duration and confidence cannot be what decides. Proximity is.
      List<double> burst() => _script([(1, 0.6), (1, 0.95), (1, 0.4)]);

      // Utterance runs windows 5..24, so post-roll carries its audio through
      // window 32 and the next window it does not own is 33.
      const emissionEnd = 33;

      List<EndpointerEvent> at(int onset) {
        final gap = onset - (5 + 20);
        final vad = _ScriptedVad(
          _script([(5, 0.0), (20, 0.9), (gap, 0.0)])
            ..addAll(burst())
            ..addAll(_script([(30, 0.0)])),
        );
        return Endpointer(vad).add(_markedWindows(onset + 3 + 30));
      }

      // Inside the window: this is the tail of a sentence the hangover cut,
      // and it comes back as an utterance of its own.
      final near = at(emissionEnd + reattachWindows);
      expect(near.whereType<SpeechEnded>(), hasLength(2));
      expect(near.whereType<SpeechDiscarded>(), isEmpty);
      expect(
        near.whereType<SpeechStarted>(),
        hasLength(2),
        reason: 're-attachment confirms at onset, so it announces itself too',
      );

      // One window past it, the room has been quiet long enough that a short
      // confident burst is a cough again.
      final far = at(emissionEnd + reattachWindows + 1);
      expect(far.whereType<SpeechEnded>(), hasLength(1));
      final discarded = far.whereType<SpeechDiscarded>().single;
      expect(discarded.duration, const Duration(milliseconds: 96));
      expect(
        discarded.peakProbability,
        0.95,
        reason: 'the peak of the burst, not its first or last window',
      );
    });

    test('re-attached audio does not overlap the utterance before it', () {
      // Re-attachment must not become a second way to transcribe the same
      // audio: the burst opens its own utterance, and the pre-roll it would
      // normally reach back for is clipped to what the last emission left.
      final vad = _ScriptedVad(
        _script([(5, 0.0), (20, 0.9), (15, 0.0), (2, 0.9), (30, 0.0)]),
      );
      final ended = Endpointer(
        vad,
      ).add(_markedWindows(72)).whereType<SpeechEnded>().toList();

      expect(ended, hasLength(2));
      final first = _windowsIn(ended[0].utterance).toSet();
      final second = _windowsIn(ended[1].utterance).toSet();
      expect(first.intersection(second), isEmpty);
      expect(ended[1].utterance.start, ended[0].utterance.end);
    });

    test('reattachWithin: zero judges every burst on its own', () {
      // The escape hatch, for a product that would rather lose a word than
      // ever decode a cough.
      final vad = _ScriptedVad(
        _script([(5, 0.0), (20, 0.9), (15, 0.0), (2, 0.9), (30, 0.0)]),
      );
      final ep = Endpointer(
        vad,
        config: const EndpointerConfig(reattachWithin: Duration.zero),
      );
      final events = ep.add(_markedWindows(72));

      expect(events.whereType<SpeechEnded>(), hasLength(1));
      expect(events.whereType<SpeechDiscarded>(), hasLength(1));
    });

    test(
      'a burst still open when the stream ends is reported, not dropped',
      () {
        // End of stream says nothing about what the audio was — a cough on the
        // last window is still a cough — so flush applies the same floor. What
        // it must not do is let the burst disappear into reset().
        final ep = Endpointer(_ScriptedVad(_script([(5, 0.0), (2, 0.9)])));
        ep.add(_markedWindows(7));

        final events = ep.flush();
        expect(events.whereType<SpeechEnded>(), isEmpty);
        final discarded = events.whereType<SpeechDiscarded>().single;
        expect(discarded.speechStart, Duration(milliseconds: 5 * 32));
        expect(discarded.duration, const Duration(milliseconds: 64));
      },
    );

    test('reset forgets where the last utterance ended', () {
      // Re-attachment reaches across the endpointer's own state, so it must not
      // reach across a reset — a route change or an interruption means the
      // audio either side is not contiguous, and gluing a burst onto an
      // utterance from before the gap would be inventing continuity.
      final vad = _ScriptedVad(
        _script([(5, 0.0), (20, 0.9), (15, 0.0), (2, 0.9), (30, 0.0)]),
      );
      final ep = Endpointer(vad);
      final before = ep.add(_markedWindows(40));
      expect(before.whereType<SpeechEnded>(), hasLength(1));

      ep.reset();
      final after = ep.add(_markedWindows(32));
      expect(after.whereType<SpeechEnded>(), isEmpty);
      expect(after.whereType<SpeechDiscarded>(), hasLength(1));
    });

    test(
      'hysteresis keeps a dip between the thresholds inside the utterance',
      () {
        // A dip to 0.4 is below the 0.5 onset but above the 0.35 offset, so it
        // must not even start the hangover clock — this is the case a single
        // threshold gets wrong, chattering on and off through a long vowel.
        final vad = _ScriptedVad(
          _script([(5, 0.0), (12, 0.9), (20, 0.4), (12, 0.9), (20, 0.0)]),
        );
        final ep = Endpointer(vad);
        final events = ep.add(_markedWindows(69));

        expect(events.whereType<SpeechEnded>(), hasLength(1));
        final u = events.whereType<SpeechEnded>().single.utterance;
        // Speech spans windows 5..48 unbroken despite the 20-window dip.
        expect(u.speechStart, Duration(milliseconds: 5 * 32));
        expect(u.speechEnd, Duration(milliseconds: 49 * 32));
      },
    );

    test(
      'a silence shorter than the hangover does not split the utterance',
      () {
        final vad = _ScriptedVad(
          _script([
            (5, 0.0),
            (12, 0.9),
            (hangoverWindows - 1, 0.0), // a real pause, just not long enough
            (12, 0.9),
            (30, 0.0),
          ]),
        );
        final ep = Endpointer(vad);
        final events = ep.add(
          _markedWindows(5 + 12 + hangoverWindows - 1 + 12 + 30),
        );

        expect(
          events.whereType<SpeechEnded>(),
          hasLength(1),
          reason: 'mid-sentence pauses must stay inside one utterance',
        );
        expect(events.whereType<SpeechStarted>(), hasLength(1));
      },
    );

    test('two separated utterances share no audio', () {
      final vad = _ScriptedVad(
        _script([(5, 0.0), (20, 0.9), (40, 0.0), (20, 0.9), (40, 0.0)]),
      );
      final ep = Endpointer(vad);
      final events = ep.add(_markedWindows(125));

      final ended = events.whereType<SpeechEnded>().toList();
      expect(ended, hasLength(2));

      final first = _windowsIn(ended[0].utterance).toSet();
      final second = _windowsIn(ended[1].utterance).toSet();
      expect(
        first.intersection(second),
        isEmpty,
        reason: 'overlap at a natural endpoint would transcribe audio twice',
      );
    });

    test('caps a long utterance and overlaps the continuation', () {
      const maxWindows = 40;
      final vad = _ScriptedVad(_script([(200, 0.9)]));
      final ep = Endpointer(
        vad,
        config: const EndpointerConfig(
          maxUtterance: Duration(milliseconds: 32 * maxWindows),
        ),
      );
      final events = ep.add(_markedWindows(100));

      final ended = events.whereType<SpeechEnded>().toList();
      expect(ended.length, greaterThanOrEqualTo(2));
      expect(ended.every((e) => e.utterance.truncated), isTrue);

      final first = _windowsIn(ended[0].utterance);
      final second = _windowsIn(ended[1].utterance);
      expect(first.last, maxWindows - 1);
      // The cut deliberately overlaps by the pre-roll so a word straddling the
      // boundary survives whole in one of the two chunks.
      expect(second.first, maxWindows - preRollWindows);
      expect(
        first.toSet().intersection(second.toSet()),
        hasLength(preRollWindows),
      );
    });

    test('chunk size does not change the result', () {
      List<double> script() =>
          _script([(10, 0.0), (25, 0.9), (30, 0.0), (15, 0.8), (30, 0.0)]);
      final audio = _markedWindows(110);

      final whole = Endpointer(_ScriptedVad(script()));
      final expected = whole.add(audio);

      // 300 is coprime with 512, so no chunk boundary ever lands on a window
      // boundary — every window is assembled from at least two chunks.
      final split = Endpointer(_ScriptedVad(script()));
      final actual = <EndpointerEvent>[];
      for (var i = 0; i < audio.length; i += 300) {
        final end = (i + 300).clamp(0, audio.length);
        actual.addAll(split.add(Float32List.sublistView(audio, i, end)));
      }

      expect(actual.length, expected.length);
      for (var i = 0; i < expected.length; i++) {
        expect(actual[i].at, expected[i].at);
        if (expected[i] is SpeechEnded) {
          expect(
            _windowsIn((actual[i] as SpeechEnded).utterance),
            _windowsIn((expected[i] as SpeechEnded).utterance),
          );
        }
      }
    });

    test('flush emits speech in progress, including the partial window', () {
      final vad = _ScriptedVad(_script([(5, 0.0), (20, 0.9)]));
      final ep = Endpointer(vad);

      expect(ep.add(_markedWindows(25)).whereType<SpeechEnded>(), isEmpty);

      // A ragged tail, as a real capture stop would leave.
      ep.add(Float32List(100));
      final events = ep.flush();

      final ended = events.whereType<SpeechEnded>().single;
      expect(ended.utterance.truncated, isFalse);
      expect(
        ended.utterance.audio.length,
        25 * vadWindowSamples + 100,
        reason: 'the last partial window is audio the user spoke',
      );
      expect(ep.isSpeaking, isFalse);
      expect(vad.resets, 1);
    });

    test('flush with nothing in progress emits nothing', () {
      final ep = Endpointer(_ScriptedVad(_script([(30, 0.0)])));
      ep.add(_markedWindows(30));
      expect(ep.flush(), isEmpty);
    });

    test('pendingAudio exposes the utterance in progress, and only then', () {
      final vad = _ScriptedVad(_script([(5, 0.0), (30, 0.9), (30, 0.0)]));
      final ep = Endpointer(vad);

      // Silence: nothing is open.
      ep.add(_markedWindows(5));
      expect(ep.pendingAudio(), isNull);
      expect(ep.pendingStart, isNull);

      // Speech, but not yet confirmed — a snapshot here could be a cough.
      ep.add(
        Float32List.sublistView(
          _markedWindows(40),
          5 * vadWindowSamples,
          9 * vadWindowSamples,
        ),
      );
      expect(
        ep.pendingAudio(),
        isNull,
        reason: 'unconfirmed speech is not text',
      );

      // Past minSpeechDuration: the snapshot is the audio so far, pre-roll
      // included, and it grows as more arrives.
      ep.add(Float32List(20 * vadWindowSamples));
      final first = ep.pendingAudio();
      expect(first, isNotNull);
      expect(ep.pendingStart, Duration.zero, reason: 'pre-roll reaches to 0');

      ep.add(Float32List(5 * vadWindowSamples));
      expect(
        ep.pendingAudio()!.length,
        first!.length + 5 * vadWindowSamples,
        reason: 'the snapshot grows with the utterance',
      );

      // A ragged tail is included: it is audio the user spoke.
      ep.add(Float32List(100));
      expect(
        ep.pendingAudio()!.length,
        first.length + 5 * vadWindowSamples + 100,
      );

      // After the endpoint, nothing is open again.
      ep.add(Float32List(30 * vadWindowSamples));
      expect(ep.pendingAudio(), isNull);
    });

    test('position tracks consumed audio including a partial window', () {
      final ep = Endpointer(_ScriptedVad(_script([(10, 0.0)])));
      ep.add(_markedWindows(10));
      expect(ep.position, Duration(milliseconds: 10 * 32));
      ep.add(Float32List(256));
      expect(ep.position, const Duration(milliseconds: 336));
    });
  });
}
