import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:transcribe_cpp/src/activity.dart' as activity;
import 'package:transcribe_cpp/src/reader.dart';
import 'package:transcribe_cpp/src/session.dart';
import 'package:transcribe_cpp/transcribe_cpp.dart';
import 'package:transcribe_cpp/src/endpointer.dart';
import 'package:transcribe_cpp/src/pipeline.dart';
import 'package:transcribe_cpp/src/vad.dart';

/// A VAD that replays a probability per window, ignoring the audio.
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

List<double> _script(List<(int, double)> runs) => [
  for (final (count, p) in runs) ...List<double>.filled(count, p),
];

/// Silence, one utterance of 40 windows (1.28 s), silence.
final _oneUtterance = _script([(20, 0.0), (40, 0.9), (30, 0.0)]);

/// "w1 w2 ...": one word per 8 windows of audio, so a longer decode of the
/// same utterance extends a shorter one and live text can agree on it.
class _FakeDecoder implements UtteranceDecoder {
  int calls = 0;

  @override
  Future<Transcript> transcribe(Float32List pcm) async {
    calls++;
    final words = math.max(1, pcm.length ~/ (8 * vadWindowSamples));
    return Transcript(
      text: List.generate(words, (i) => 'w${i + 1}').join(' '),
      segments: const [],
      words: const [],
      tokens: const [],
    );
  }
}

/// The real Segmenter, run on the test isolate instead of a reader isolate.
class _FakeSource implements ReaderSource {
  _FakeSource(List<double> script, ReaderSettings settings) {
    segmenter = Segmenter(
      endpointer: Endpointer(_ScriptedVad(script), config: settings.endpointer),
      normalizer: null,
      provisionalInterval: settings.provisionalInterval,
      emit: _messages.add,
    );
  }

  late final Segmenter segmenter;
  final _messages = StreamController<Object?>();
  final states = StreamController<CaptureStatus>.broadcast();
  bool closed = false;

  /// Feeds [windows] VAD windows of audio, one window at a time.
  void feed(int windows) {
    for (var i = 0; i < windows; i++) {
      segmenter.add(Float32List(vadWindowSamples));
    }
  }

  void emit(Object message) => _messages.add(message);

  @override
  Stream<Object?> get messages => _messages.stream;

  @override
  Stream<CaptureStatus> get captureStates => states.stream;

  @override
  void stop() {
    segmenter.flush();
    _messages.add('done');
  }

  @override
  Future<void> close() async {
    closed = true;
    await _messages.close();
    await states.close();
  }
}

void main() {
  late _FakeDecoder decoder;
  late List<_FakeSource> live;
  Object? startError;

  Future<TranscribeSession> open({List<double>? script}) {
    decoder = _FakeDecoder();
    live = [];
    startError = null;
    return openSessionAt(
      'unused',
      decoder: decoder,
      vadWeights: Uint8List(0),
      sources: SessionSources(
        live: (settings) async {
          if (startError != null) throw startError!;
          final s = _FakeSource(script ?? _oneUtterance, settings);
          live.add(s);
          return s;
        },
        replay: (settings, audio) async {
          final s = _FakeSource(script ?? _oneUtterance, settings);
          // Like the replay isolate: feed it all, flush, say done.
          scheduleMicrotask(() {
            s.feed(audio.length ~/ vadWindowSamples);
            s.stop();
          });
          return s;
        },
      ),
    );
  }

  Float32List windows(int n) => Float32List(n * vadWindowSamples);

  /// Every value [live] publishes until [body] completes, starting with the
  /// current one.
  Future<List<T>> record<T>(Live<T> live, Future<void> Function() body) async {
    final seen = <T>[];
    final sub = live.stream.listen(seen.add);
    await body();
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    return seen;
  }

  group('replay', () {
    test('transcribes a recording and returns to idle', () async {
      final session = await open();
      final events = <EndpointerEvent>[];
      session.events.listen(events.add);
      final results = <UtteranceResult>[];
      session.utterances.listen(results.add);

      final states = await record(
        session.state,
        () => session.replay(windows(90)),
      );

      expect(states, [
        SessionState.idle,
        SessionState.replaying,
        SessionState.idle,
      ]);
      expect(results.single.isFinal, isTrue);
      expect(session.text.value.settled, results.single.text);
      expect(session.text.value.interim, isEmpty);
      expect(events.map((e) => e.runtimeType), [SpeechStarted, SpeechEnded]);
      expect(activity.activeSessions, 0);
    });

    test('streams subscribed before replay miss nothing', () async {
      // The reason Replay used to be two-phase: broadcast streams drop
      // events with no listener. A session exists before its audio does.
      final session = await open(
        script: _script([
          (10, 0.0),
          (30, 0.9),
          (30, 0.0),
          (30, 0.9),
          (30, 0.0),
        ]),
      );
      final results = <UtteranceResult>[];
      session.utterances.listen(results.add);
      await session.replay(windows(130));
      expect(results, hasLength(2));
      expect(
        session.text.value.settled,
        '${results[0].text} ${results[1].text}',
      );
    });

    test('stop ends a replay early', () async {
      final session = await open();
      final done = session.replay(windows(90));
      await session.stop();
      await done;
      expect(session.state.value, SessionState.idle);
    });
  });

  group('live', () {
    test('runs through each state, and stop flushes open speech', () async {
      final session = await open();
      final results = <UtteranceResult>[];
      session.utterances.listen(results.add);

      final states = await record(session.state, () async {
        await session.start(provisionalInterval: Duration.zero);
        // Speech still open when the user stops.
        live.single.feed(40);
        await session.stop();
      });

      expect(states, [
        SessionState.idle,
        SessionState.starting,
        SessionState.listening,
        SessionState.finishing,
        SessionState.idle,
      ]);
      expect(results.single.isFinal, isTrue);
      expect(session.text.value.settled, results.single.text);
      expect(live.single.closed, isTrue);
      expect(activity.activeSessions, 0);
    });

    test('live text shows agreed words, then settles', () async {
      final session = await open();
      final texts = await record(session.text, () async {
        await session.start(
          provisionalInterval: const Duration(milliseconds: 300),
        );
        final source = live.single;
        for (var i = 0; i < 90; i++) {
          source.feed(1);
          // Let each provisional decode finish before the next snapshot,
          // as a fast decoder on a phone would.
          await Future<void>.delayed(Duration.zero);
        }
        await session.stop();
      });

      final interims = texts.map((t) => t.interim).where((t) => t.isNotEmpty);
      expect(interims, isNotEmpty);
      expect(texts.last.interim, isEmpty);
      expect(texts.last.settled, isNotEmpty);
      // Agreed words only grow within an utterance.
      final words = interims.map((t) => t.split(' ').length).toList();
      expect(words, orderedEquals([...words]..sort()));
    });

    test('each start clears the text; streams carry on across runs', () async {
      final session = await open();
      final results = <UtteranceResult>[];
      session.utterances.listen(results.add);

      await session.start(provisionalInterval: Duration.zero);
      live.last.feed(90);
      await session.stop();
      expect(session.text.value.settled, isNotEmpty);

      await session.start(provisionalInterval: Duration.zero);
      expect(session.text.value, const LiveText());
      live.last.feed(90);
      await session.stop();

      expect(results, hasLength(2), reason: 'one subscription, two runs');
    });

    test('level, capture state and dropouts are forwarded', () async {
      final session = await open();
      final dropouts = <Dropout>[];
      session.dropouts.listen(dropouts.add);

      await session.start(provisionalInterval: Duration.zero);
      final source = live.single;
      source.feed(10);
      await Future<void>.delayed(Duration.zero);
      expect(session.level.value, isNot(same(LiveLevel.silent)));

      source.states.add(const CaptureStatus(CaptureState.interrupted));
      source.emit(const Dropout(1600));
      await Future<void>.delayed(Duration.zero);
      expect(session.capture.value.state, CaptureState.interrupted);
      expect(dropouts.single.duration, const Duration(milliseconds: 100));

      await session.stop();
      expect(session.level.value, same(LiveLevel.silent));
      expect(session.capture.value.state, CaptureState.idle);
    });

    test('a failed start returns to idle and rethrows', () async {
      final session = await open();
      startError = StateError('Microphone permission denied');
      await expectLater(session.start(), throwsStateError);
      expect(session.state.value, SessionState.idle);
      expect(activity.activeSessions, 0);
      startError = null;
      await session.start();
      await session.stop();
    });

    test('a second start while running is refused', () async {
      final session = await open();
      await session.start();
      expect(() => session.start(), throwsStateError);
      expect(() => session.replay(windows(10)), throwsStateError);
      await session.stop();
    });

    test('stop called during start waits for it, then stops', () async {
      final session = await open();
      final starting = session.start();
      await session.stop();
      await starting;
      expect(session.state.value, SessionState.idle);
      expect(live.single.closed, isTrue);
    });

    test('decode errors arrive on utterances, and the run goes on', () async {
      final session = await openSessionAt(
        'unused',
        decoder: _FailingDecoder(),
        vadWeights: Uint8List(0),
        sources: SessionSources(
          live: (s) async => _FakeSource(_oneUtterance, s)..feed(0),
          replay: (s, a) async {
            final src = _FakeSource(_oneUtterance, s);
            scheduleMicrotask(() {
              src.feed(90);
              src.stop();
            });
            return src;
          },
        ),
      );
      final errors = <Object>[];
      session.utterances.listen((_) {}, onError: errors.add);
      await session.replay(windows(90));
      expect(errors.single, isA<FormatException>());
      expect(session.state.value, SessionState.idle);
    });
  });

  test('dispose stops, closes the streams, and refuses further use', () async {
    final session = await open();
    await session.start();
    final closed = Completer<void>();
    session.utterances.listen((_) {}, onDone: closed.complete);
    await session.dispose();
    await closed.future;
    expect(session.state.value, SessionState.idle);
    expect(() => session.start(), throwsStateError);
    await session.dispose();
  });

  test('a session counts as active only while it runs', () async {
    final session = await open();
    expect(activity.activeSessions, 0);
    await session.start();
    expect(activity.activeSessions, 1);
    await session.stop();
    expect(activity.activeSessions, 0);
  });
}

class _FailingDecoder implements UtteranceDecoder {
  @override
  Future<Transcript> transcribe(Float32List pcm) async =>
      throw const FormatException('bad token');
}
