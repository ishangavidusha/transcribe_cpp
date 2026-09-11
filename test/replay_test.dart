import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:transcribe_cpp/src/reader.dart';
import 'package:transcribe_cpp/transcribe_cpp.dart';

/// Replays a fixed probability trace, so the "VAD" is a pure function of how
/// many windows it has seen — which is what makes two runs comparable at all.
class _ScriptedVad implements VadModel {
  _ScriptedVad(this.script);
  final List<double> script;
  int index = 0;

  @override
  double process(Float32List samples, {int offset = 0}) =>
      index < script.length ? script[index++] : 0.0;

  @override
  void reset() => index = 0;
}

List<double> _script(List<(int, double)> runs) => [
  for (final (count, p) in runs) ...List<double>.filled(count, p),
];

Segmenter _segmenter(
  List<double> script,
  List<Object> out, {
  Duration? every,
}) => Segmenter(
  endpointer: Endpointer(_ScriptedVad(script)),
  normalizer: null,
  provisionalInterval: every ?? Duration.zero,
  emit: out.add,
);

/// A stand-in for captured audio. Content is irrelevant — the scripted VAD
/// ignores it — but the length drives the window clock.
Float32List _audio(int windows) => Float32List(windows * vadWindowSamples);

/// Feeds [audio] in chunks of [chunk] samples.
void _feed(Segmenter s, Float32List audio, int chunk) {
  for (var i = 0; i < audio.length; i += chunk) {
    final end = math.min(i + chunk, audio.length);
    s.add(Float32List.sublistView(audio, i, end));
  }
}

String _describe(List<Object> events) => events
    .map(
      (e) => switch (e) {
        Utterance u =>
          'utt ${u.start.inMilliseconds}-${u.end.inMilliseconds}'
              '/${u.audio.length}${u.truncated ? '/cut' : ''}',
        SpeechStarted s => 'start ${s.at.inMilliseconds}',
        Snapshot s => 'snap ${s.start.inMilliseconds}/${s.audio.length}',
        _ => '',
      },
    )
    .where((s) => s.isNotEmpty)
    .join('\n');

void main() {
  final script = _script([
    (5, 0.0),
    (30, 0.9),
    (25, 0.0),
    (18, 0.9),
    (25, 0.0),
    (40, 0.9),
    (30, 0.0),
  ]);

  group('Segmenter', () {
    test('is deterministic across runs', () {
      // The property the whole replay path rests on. If feeding identical
      // samples twice could produce different utterances, comparing two
      // configurations would be comparing noise.
      final a = <Object>[];
      final b = <Object>[];
      _feed(_segmenter(script, a), _audio(180), vadWindowSamples);
      _feed(_segmenter(script, b), _audio(180), vadWindowSamples);
      expect(_describe(a), _describe(b));
      expect(a.whereType<Utterance>(), isNotEmpty);
    });

    test('chunk size does not change what the endpointer sees', () {
      // This is what makes a replay valid evidence about the microphone. The
      // ring hands over whatever happened to accumulate — a few hundred samples,
      // never aligned to anything — while a replay feeds neat 512-sample
      // windows. If those disagreed, offline results would not describe the
      // live pipeline and the instrument would be worthless.
      final reference = <Object>[];
      _feed(_segmenter(script, reference), _audio(180), vadWindowSamples);

      for (final chunk in [1, 97, 256, 511, 512, 1000, 4096, 180 * 512]) {
        final got = <Object>[];
        _feed(_segmenter(script, got), _audio(180), chunk);
        expect(
          _describe(got),
          _describe(reference),
          reason: 'a $chunk-sample chunking produced different utterances',
        );
      }
    });

    test('snapshots are paced by audio position, not wall clock', () {
      // The distinction is visible precisely because a replay feeds 5.8 s of
      // audio in a few milliseconds. Pacing off a Stopwatch would yield at most
      // one snapshot; pacing off the audio yields one per 350 ms of speech.
      final events = <Object>[];
      _feed(
        _segmenter(script, events, every: const Duration(milliseconds: 350)),
        _audio(180),
        vadWindowSamples,
      );
      final snaps = events.whereType<Snapshot>().toList();
      expect(snaps.length, inInclusiveRange(3, 20));
      // And they are snapshots of a growing utterance, so they get longer.
      final byStart = <Duration, List<int>>{};
      for (final s in snaps) {
        byStart.putIfAbsent(s.start, () => []).add(s.audio.length);
      }
      for (final lengths in byStart.values) {
        expect(lengths, orderedEquals(lengths.toList()..sort()));
      }
    });

    test('snapshot pacing has chunk granularity', () {
      // Honest about a limit rather than asserting an invariance that does not
      // hold: the snapshot check runs once per add(), so a caller handing over
      // large blocks gets fewer, later snapshots. Utterances are unaffected
      // (see above), and it does not bite in practice — the ring delivers ~16 ms
      // at a time, and replay switches provisional decoding off entirely.
      final fine = <Object>[];
      final coarse = <Object>[];
      const every = Duration(milliseconds: 350);
      _feed(
        _segmenter(script, fine, every: every),
        _audio(180),
        vadWindowSamples,
      );
      _feed(_segmenter(script, coarse, every: every), _audio(180), 16384);

      expect(
        coarse.whereType<Snapshot>().length,
        lessThan(fine.whereType<Snapshot>().length),
      );
      // The utterances still match, which is the part replay depends on.
      expect(
        _describe(coarse.whereType<Utterance>().toList()),
        _describe(fine.whereType<Utterance>().toList()),
      );
    });

    test('flush emits an utterance still open when the audio ends', () {
      // A recording that stops mid-sentence still has to yield that sentence,
      // or every replay silently loses its tail.
      final events = <Object>[];
      final s = _segmenter(_script([(5, 0.0), (30, 0.9)]), events);
      _feed(s, _audio(35), vadWindowSamples);
      expect(
        events.whereType<Utterance>(),
        isEmpty,
        reason: 'speech is still open; nothing should have been emitted yet',
      );

      s.flush();
      expect(events.whereType<Utterance>(), hasLength(1));
    });

    test('reset clears the utterance in progress', () {
      final events = <Object>[];
      final s = _segmenter(script, events);
      _feed(s, _audio(20), vadWindowSamples);
      s.reset();
      s.flush();
      expect(events.whereType<Utterance>(), isEmpty);
    });
  });
}
