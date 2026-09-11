import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:transcribe_cpp/transcribe_cpp.dart';

class _ScriptedVad implements VadModel {
  _ScriptedVad(this.script);
  final List<double> script;
  int index = 0;

  @override
  double process(Float32List samples, {int offset = 0}) =>
      index < script.length ? script[index++] : 0.0;

  @override
  void reset() {}
}

/// Stands in for the model. The delay matters: it forces each decode onto a
/// later turn of the event loop, which is what makes delivery ordering and the
/// flush guarantee observable at all.
class _FakeDecoder implements UtteranceDecoder {
  final calls = <int>[];

  @override
  Future<Transcript> transcribe(Float32List pcm) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    calls.add(pcm.length);
    return Transcript(
      text: 'utterance ${calls.length}',
      segments: const [],
      words: const [],
      tokens: const [],
    );
  }
}

List<double> _script(List<(int, double)> runs) => [
  for (final (count, p) in runs) ...List<double>.filled(count, p),
];

/// Replays a fixed list of decodes so a seam can be staged exactly.
class _ScriptedDecoder implements UtteranceDecoder {
  _ScriptedDecoder(this.lines);
  final List<String> lines;
  int index = 0;

  @override
  Future<Transcript> transcribe(Float32List pcm) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return Transcript(
      text: lines[index++],
      segments: const [],
      words: const [],
      tokens: const [],
    );
  }
}

Utterance _utterance({required bool truncated, int at = 0}) => Utterance(
  audio: Float32List(vadWindowSamples),
  start: Duration(seconds: at),
  end: Duration(seconds: at + 1),
  speechStart: Duration(seconds: at),
  speechEnd: Duration(seconds: at + 1),
  truncated: truncated,
);

void main() {
  group('VoicePipeline', () {
    test(
      'delivers every utterance, including the one flush produces',
      () async {
        // Three utterances closed by silence, plus a fourth still in progress
        // when the audio runs out — that last one only exists because flush()
        // emits it, and it is the one a delivery race drops.
        final vad = _ScriptedVad(
          _script([
            (5, 0.0),
            (20, 0.9), (25, 0.0),
            (20, 0.9), (25, 0.0),
            (20, 0.9), (25, 0.0),
            (20, 0.9), // still speaking at end of stream
          ]),
        );
        final decoder = _FakeDecoder();
        final pipeline = VoicePipeline(decoder, Endpointer(vad));

        final received = <UtteranceResult>[];
        final subscription = pipeline.results.listen(received.add);

        pipeline.add(Float32List(180 * vadWindowSamples));
        await pipeline.flush();
        // Cancelling immediately is the point: awaiting flush() must already
        // mean delivered.
        await subscription.cancel();

        expect(decoder.calls, hasLength(4), reason: 'four utterances decoded');
        expect(
          received,
          hasLength(4),
          reason:
              'the utterance flush() produced was decoded but never '
              'delivered — see the drain in VoicePipeline.flush',
        );
        expect(received.map((r) => r.transcript.text), [
          'utterance 1',
          'utterance 2',
          'utterance 3',
          'utterance 4',
        ]);
      },
    );

    test('results arrive in utterance order', () async {
      final vad = _ScriptedVad(
        _script([
          (5, 0.0),
          for (var i = 0; i < 5; i++) ...[(20, 0.9), (25, 0.0)],
        ]),
      );
      final pipeline = VoicePipeline(_FakeDecoder(), Endpointer(vad));
      final received = <UtteranceResult>[];
      final subscription = pipeline.results.listen(received.add);

      pipeline.add(Float32List(230 * vadWindowSamples));
      await pipeline.flush();
      await subscription.cancel();

      expect(received, hasLength(5));
      for (var i = 1; i < received.length; i++) {
        expect(received[i].start, greaterThan(received[i - 1].start));
      }
    });

    test(
      'provisional results are marked, and never delay a final one',
      () async {
        final decoder = _FakeDecoder();
        final transcriber = UtteranceTranscriber(decoder);
        final got = <UtteranceResult>[];
        final subscription = transcriber.results.listen(got.add);

        Utterance snapshot(int id) => Utterance(
          audio: Float32List(id * 100),
          start: Duration.zero,
          end: Duration.zero,
          speechStart: Duration.zero,
          speechEnd: Duration.zero,
          truncated: false,
        );

        transcriber.submitProvisional(snapshot(1));
        // The next two arrive while the first is still decoding. Queueing them
        // would show stale text and push the final decode behind work nobody
        // needs, so they are dropped.
        transcriber.submitProvisional(snapshot(2));
        transcriber.submitProvisional(snapshot(3));
        transcriber.submit(snapshot(4));
        await transcriber.drain();
        await subscription.cancel();

        expect(
          decoder.calls,
          [100, 400],
          reason: 'only the first provisional and the final were decoded',
        );
        expect(got.map((r) => r.isFinal), [false, true]);
      },
    );

    test(
      'a decode failure surfaces as a stream error, not a lost utterance',
      () async {
        final vad = _ScriptedVad(_script([(5, 0.0), (20, 0.9), (25, 0.0)]));
        final pipeline = VoicePipeline(_ThrowingDecoder(), Endpointer(vad));

        final errors = <Object>[];
        final subscription = pipeline.results.listen(
          (_) {},
          onError: errors.add,
        );

        pipeline.add(Float32List(50 * vadWindowSamples));
        await pipeline.flush();
        await subscription.cancel();

        expect(errors, hasLength(1));
      },
    );
  });

  group('UtteranceTranscriber seam joining', () {
    test('drops the pre-roll repeat after a truncated utterance', () async {
      // The pre-roll rewind hands ~300 ms of audio to both decodes, so the
      // second one re-transcribes the words the first one ended on.
      final decoder = _ScriptedDecoder([
        'call and they say hey we have',
        'we have some news Hillary Clinton is announcing',
      ]);
      final t = UtteranceTranscriber(decoder);
      final got = <UtteranceResult>[];
      t.results.listen(got.add);

      t.submit(_utterance(truncated: true));
      t.submit(_utterance(truncated: false, at: 20));
      await t.drain();

      expect(got.map((r) => r.text), [
        'call and they say hey we have',
        'some news Hillary Clinton is announcing',
      ]);
      // The raw decode is preserved; only the joined view is trimmed.
      expect(got[1].transcript.text, startsWith('we have'));
    });

    test('leaves the join alone after a natural endpoint', () async {
      final decoder = _ScriptedDecoder(['hey we have', 'we have some news']);
      final t = UtteranceTranscriber(decoder);
      final got = <UtteranceResult>[];
      t.results.listen(got.add);

      t.submit(_utterance(truncated: false));
      t.submit(_utterance(truncated: false, at: 5));
      await t.drain();

      expect(got.map((r) => r.text), ['hey we have', 'we have some news']);
    });

    test(
      'trims provisional decodes too, so live text never stutters',
      () async {
        final decoder = _ScriptedDecoder([
          'they would be promising miracle solutions to any problem',
          'to any problem having',
          'to any problem having snake oil being sold',
        ]);
        final t = UtteranceTranscriber(decoder);
        final got = <UtteranceResult>[];
        t.results.listen(got.add);

        t.submit(_utterance(truncated: true));
        await t.drain();
        t.submitProvisional(_utterance(truncated: false, at: 20));
        await t.drain();
        t.submit(_utterance(truncated: false, at: 20));
        await t.drain();

        expect(got[1].isFinal, isFalse);
        expect(got[1].text, 'having');
        expect(got[2].text, 'having snake oil being sold');
      },
    );
  });
}

class _ThrowingDecoder implements UtteranceDecoder {
  @override
  Future<Transcript> transcribe(Float32List pcm) async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    throw StateError('decode failed');
  }
}
