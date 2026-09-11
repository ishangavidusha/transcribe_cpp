import 'package:flutter_test/flutter_test.dart';
import 'package:transcribe_cpp/transcribe_cpp.dart';

void main() {
  group('Live', () {
    test('has a value before anyone is watching', () {
      final c = LiveController<int>(7);
      expect(c.live.value, 7);
    });

    test(
      'a late subscriber receives the current value, not the next one',
      () async {
        // This is the whole reason the type exists. A broadcast controller
        // would hand this subscriber nothing until the value changed again.
        final c = LiveController<String>('');
        c.value = 'hello';
        c.value = 'hello world';

        expect(await c.live.stream.first, 'hello world');
      },
    );

    test('every listener gets its own view of the sequence', () async {
      final c = LiveController<int>(0);
      final a = <int>[];
      final b = <int>[];

      final subA = c.live.stream.listen(a.add);
      c.value = 1;
      final subB = c.live.stream.listen(b.add);
      c.value = 2;
      await Future<void>.delayed(Duration.zero);

      expect(a, [0, 1, 2], reason: 'joined at 0');
      expect(b, [1, 2], reason: 'joined after 1 was already current');
      await subA.cancel();
      await subB.cancel();
    });

    test('an unchanged value is not republished', () async {
      final c = LiveController<int>(1);
      final seen = <int>[];
      final sub = c.live.stream.listen(seen.add);

      c.value = 1;
      c.value = 1;
      c.value = 2;
      await Future<void>.delayed(Duration.zero);

      expect(seen, [1, 2]);
      await sub.cancel();
    });

    test('drives ValueListenable, so it binds to a widget directly', () {
      final c = LiveController<int>(0);
      var notifications = 0;
      void listener() => notifications++;

      c.live.addListener(listener);
      c.value = 1;
      c.value = 2;
      c.value = 2; // unchanged
      expect(notifications, 2);

      c.live.removeListener(listener);
      c.value = 3;
      expect(notifications, 2, reason: 'removed listeners stop hearing');
      expect(c.live.value, 3);
    });

    test('a listener may remove itself while being notified', () {
      final c = LiveController<int>(0);
      var calls = 0;
      late final void Function() once;
      once = () {
        calls++;
        c.live.removeListener(once);
      };
      c.live.addListener(once);

      c.value = 1;
      c.value = 2;
      expect(calls, 1, reason: 'concurrent modification must not throw');
    });

    test('cancelling one subscription leaves the others intact', () async {
      final c = LiveController<int>(0);
      final kept = <int>[];
      final dropped = <int>[];
      c.live.stream.listen(kept.add);
      final b = c.live.stream.listen(dropped.add);

      c.value = 1;
      await Future<void>.delayed(Duration.zero);
      await b.cancel();
      c.value = 2;
      await Future<void>.delayed(Duration.zero);

      expect(kept, [0, 1, 2]);
      expect(dropped, [0, 1], reason: 'saw everything up to its cancel');
    });

    test(
      'a subscriber that cancels before the event loop turns gets nothing',
      () async {
        // Standard Dart stream behaviour, not a defect: no stream delivers
        // during listen(). Callers who need an answer now read `value`.
        final c = LiveController<int>(9);
        final seen = <int>[];
        await c.live.stream.listen(seen.add).cancel();
        await Future<void>.delayed(Duration.zero);

        expect(seen, isEmpty);
        expect(c.live.value, 9);
      },
    );

    test(
      'close ends open streams but leaves the last value readable',
      () async {
        final c = LiveController<String>('idle');
        var done = false;
        final sub = c.live.stream.listen(null, onDone: () => done = true);

        c.value = 'listening';
        await c.close();
        await Future<void>.delayed(Duration.zero);

        expect(done, isTrue);
        // The final state of a finished session is still a fact about it.
        expect(c.live.value, 'listening');
        await sub.cancel();
      },
    );

    test('subscribing after close yields the last value, then done', () async {
      final c = LiveController<int>(5);
      await c.close();
      expect(await c.live.stream.toList(), [5]);
    });

    test('writes after close are ignored', () async {
      final c = LiveController<int>(1);
      await c.close();
      c.value = 2;
      expect(c.live.value, 1);
    });

    test('close is idempotent', () async {
      final c = LiveController<int>(0);
      await c.close();
      await c.close();
      expect(c.live.value, 0);
    });
  });
}
