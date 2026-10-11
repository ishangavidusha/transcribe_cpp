import 'dart:async';

import 'package:flutter/foundation.dart';

/// A value that can be read now and watched over time.
///
/// The plugin publishes two different kinds of thing, and conflating them is
/// what the current API gets wrong. An *event* — an utterance finished, a
/// dropout happened — is a fact about a moment; a listener that arrives later
/// has genuinely missed it, and buffering every one of them forever would mean
/// holding an unbounded transcript inside the plugin. *State* — what has been
/// said so far, whether we are listening, how loud it is — has a current value
/// at every instant, and a listener that arrives late must see it rather than
/// wait for the next change.
///
/// `Stream` alone cannot express the second kind. A broadcast controller drops
/// anything added before someone subscribes, which is not a subtlety: it is
/// why the package's replay API once had to be split into `start()` and
/// `run()`, so a caller could subscribe in the gap. This type is what that
/// workaround was standing in for.
///
/// Implements [ValueListenable] so it drops straight into a
/// `ValueListenableBuilder`, and exposes [stream] for anything that wants to
/// compose. Both views are live at once and neither is preferred — an app
/// using RxDart calls its operators on [stream]; an app using widgets binds
/// the listenable. Deliberately *not* an RxDart type: those operators are
/// extension methods on `Stream`, so exposing plain `Stream` costs an RxDart
/// user nothing, while exposing `ValueStream` would force the dependency on
/// everyone who touches the plugin.
abstract interface class Live<T> implements ValueListenable<T> {
  /// The value as of now. Never null-by-absence: a [Live] always has one.
  @override
  T get value;

  /// [value] now, then every subsequent change.
  ///
  /// Each listener receives the current value as its first event, so there is
  /// no window in which a subscriber sees nothing. Delivery is asynchronous,
  /// like every Dart stream: a subscriber that cancels before the event loop
  /// turns gets nothing, and [value] is the synchronous read for callers who
  /// need an answer now.
  Stream<T> get stream;
}

/// The write side of a [Live], in the shape of `StreamController`.
///
/// Split so the read and write capabilities can be handed out separately: the
/// plugin holds the controller and publishes `controller.live`, and nothing a
/// consumer can reach lets them push a value the pipeline did not produce.
class LiveController<T> {
  LiveController(T initial) : _value = initial;

  T _value;
  final _listeners = <VoidCallback>[];
  final _subscribers = <MultiStreamController<T>>[];
  var _closed = false;

  late final Live<T> _live = _LiveView<T>(this);

  /// The read-only view. Safe to hand to callers.
  Live<T> get live => _live;

  T get value => _value;

  /// Publishes [next], unless it equals the current value.
  ///
  /// The equality check is not an optimisation, it is the contract: a level
  /// meter that republishes an unchanged reading 60 times a second would
  /// rebuild every bound widget for nothing. Callers that need every tick,
  /// changed or not, are describing events and should use a stream.
  set value(T next) {
    if (_closed || next == _value) return;
    _value = next;
    // Copied because a listener is allowed to remove itself, and a subscriber
    // may cancel, while we are part-way through notifying.
    for (final l in List<VoidCallback>.of(_listeners)) {
      l();
    }
    for (final s in List<MultiStreamController<T>>.of(_subscribers)) {
      s.add(next);
    }
  }

  /// Closes every [stream] view. [value] stays readable afterwards — the last
  /// state of a finished session is still a fact about it.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final s in List<MultiStreamController<T>>.of(_subscribers)) {
      s.close();
    }
    _subscribers.clear();
    _listeners.clear();
  }
}

class _LiveView<T> implements Live<T> {
  _LiveView(this._owner);

  final LiveController<T> _owner;

  @override
  T get value => _owner._value;

  @override
  Stream<T> get stream => Stream<T>.multi((controller) {
    controller.add(_owner._value);
    if (_owner._closed) {
      controller.close();
      return;
    }
    _owner._subscribers.add(controller);
    controller.onCancel = () => _owner._subscribers.remove(controller);
  }, isBroadcast: true);

  @override
  void addListener(VoidCallback listener) => _owner._listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _owner._listeners.remove(listener);
}
