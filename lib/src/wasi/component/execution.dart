// Internal cooperative execution; deliberately absent from package entrypoints.
// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:collection';

import 'backpressure.dart';
import '../../wasm/host_control_flow.dart';
import '../../wasm/backend/native/interpreter/execution_error.dart';

final _executionKey = Object();
final _ownerKey = Object();
final _cleanupKey = Object();

final class _Failure {
  const _Failure(this.error, this.stack, [this.owner]);
  final Object error;
  final StackTrace stack;
  final Object? owner;
  Never rethrowError() => Error.throwWithStackTrace(error, stack);
}

bool _isDisposed(Object error) {
  while (error is WasmExecutionErrorContext) {
    error = error.cause;
  }
  return error is _Disposed;
}

final class _Outcome<T> {
  const _Outcome.value(this.value) : failure = null;
  const _Outcome.failed(this.failure) : value = null;
  final T? value;
  final _Failure? failure;
  T get result {
    failure?.rethrowError();
    return value as T;
  }
}

final class _Disposed implements Exception {
  const _Disposed();
  @override
  String toString() => 'Component execution store is disposed.';
}

/// A store ticks only when the complete nested guest activation has blocked.
final class WASIComponentGuestStore {
  final _running = <WASIComponentGuestCall>[];
  final _ready = Queue<WASIComponentGuestCall>();
  final _live = <WASIComponentGuestCall>{};
  final _exclusive = <Object, WASIComponentGuestCall>{};
  final _deliveries = <void Function(), Object?>{};
  final _pendingCopies = <Future<void> Function(), Object?>{};
  final _aborting = <Future<void>>[];
  final _stopped = Completer<_Failure>();
  _Failure? _failure;
  _Failure? _controlFlow;
  bool _disposed = false;
  bool _aborted = false;

  static T withOwner<T>(Object owner, T Function() body) =>
      runZoned(body, zoneValues: {_ownerKey: owner});

  Object? get _currentOwner =>
      WASIComponentGuestCall.current?._owner ?? Zone.current[_ownerKey];
  Object? get failureOwner => _failure?.owner ?? _controlFlow?.owner;
  bool get stopped => _disposed || _failure != null || _controlFlow != null;
  bool get canRunDestructors =>
      !_aborted && _failure == null && _controlFlow == null;

  T runDestructor<T>(T Function() body) {
    try {
      return runZoned(body, zoneValues: {_cleanupKey: this});
    } catch (error, stack) {
      fail(error, stack);
      rethrow;
    }
  }

  void check() {
    _failure?.rethrowError();
    _controlFlow?.rethrowError();
    if (_disposed && !identical(Zone.current[_cleanupKey], this)) {
      throw const _Disposed();
    }
  }

  WASIComponentGuestCall start({
    required Object instance,
    required Future<void> Function(WASIComponentGuestCall call) body,
    WASIComponentBackpressure? backpressure,
    bool exclusive = false,
    bool lockOnFailure = true,
    void Function()? cancelBeforeStart,
    void Function()? onExit,
  }) {
    check();
    if (_disposed) throw const _Disposed();
    final call = WASIComponentGuestCall._(
      this,
      instance,
      exclusive,
      lockOnFailure,
      backpressure,
      cancelBeforeStart,
      onExit,
    );
    _live.add(call);
    // _execute catches every failure; the store/settle owner observes it.
    unawaited(_execute(call, body));
    return call;
  }

  Future<void> _execute(
    WASIComponentGuestCall call,
    Future<void> Function(WASIComponentGuestCall call) body,
  ) async {
    try {
      final entry = _enter(call);
      if (entry != null) await entry;
      check();
      if (!call._cancelledBeforeStart) {
        await runZoned(() => body(call), zoneValues: {_executionKey: call});
      }
    } catch (error, stack) {
      if (call._lockOnFailure && !_isDisposed(error)) {
        if (error is WasmHostControlFlowException) {
          if (!stopped) {
            _controlFlow = _Failure(error, stack, call._owner);
            _aborted = true;
            _stop(_controlFlow!);
          }
        } else {
          fail(error, stack, owner: call._owner);
        }
      }
      call._resolve(
        _Outcome.failed(
          _failure ?? _controlFlow ?? _Failure(error, stack, call._owner),
        ),
      );
    } finally {
      _finish(call);
    }
  }

  Future<void>? _enter(WASIComponentGuestCall call) {
    final parent = WASIComponentGuestCall.current;
    if ((_running.isEmpty ||
            parent != null && identical(_running.last, parent)) &&
        _eligible(call)) {
      _activate(call);
      return null;
    }
    call._handoff();
    call._permit = Completer<void>();
    _ready.addLast(call);
    final pressure = call._backpressure;
    if (pressure != null && pressure.isActive) {
      unawaited(pressure.waitUntilReleased().then((_) => _tick()));
    }
    final permitted = call._permit!.future;
    _tick();
    return permitted;
  }

  bool _eligible(WASIComponentGuestCall call) =>
      call._cancelledBeforeStart ||
      ((!call._exclusive ||
              _exclusive[call._instance] == null ||
              identical(_exclusive[call._instance], call)) &&
          (call._entered || !(call._backpressure?.isActive ?? false)));

  void _activate(WASIComponentGuestCall call) {
    if (call._exclusive && !call._cancelledBeforeStart) {
      _exclusive[call._instance] = call;
    }
    call._blocked = false;
    call._entered = true;
    _running.add(call);
  }

  void _leave(WASIComponentGuestCall call) {
    if (_running.isEmpty || !identical(_running.last, call)) {
      throw StateError('Component guest activation lost its execution turn.');
    }
    _running.removeLast();
    call._blocked = true;
    call._handoff();
  }

  void _tick() {
    if (_running.isNotEmpty || stopped) return;
    for (final call in _ready.toList(growable: false)) {
      if (!_eligible(call)) continue;
      _ready.remove(call);
      _activate(call);
      final permit = call._permit!;
      call._permit = null;
      permit.complete();
      return;
    }
  }

  void _releaseExclusive(WASIComponentGuestCall call) {
    if (identical(_exclusive[call._instance], call)) {
      _exclusive.remove(call._instance);
    }
  }

  void _finish(WASIComponentGuestCall call) {
    try {
      call._onExit?.call();
    } catch (error, stack) {
      fail(error, stack, owner: call._owner);
    }
    _running.remove(call);
    _ready.remove(call);
    _releaseExclusive(call);
    _live.remove(call);
    call._handoff();
    call._done.complete();
    _tick();
  }

  void fail(Object error, StackTrace stack, {Object? owner}) {
    if (_failure != null) return;
    _failure = _Failure(error, stack, owner ?? _currentOwner);
    _aborted = true;
    _stop(_failure!);
  }

  void _stop(_Failure failure) {
    if (!_stopped.isCompleted) _stopped.complete(failure);
    for (final call in _live.toList(growable: false)) {
      call._resolve(_Outcome.failed(failure));
      call._handoff();
      final permit = call._permit;
      call._permit = null;
      if (permit != null && !permit.isCompleted) permit.complete();
    }
    _ready.clear();
    for (final entry in _pendingCopies.entries.toList(growable: false)) {
      _aborting.add(
        Future<void>.sync(entry.key).then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            _failure ??= _Failure(error, stack, entry.value);
          },
        ),
      );
    }
  }

  void Function() retainPendingCopy(Future<void> Function() abort) {
    _pendingCopies[abort] = _currentOwner;
    return () => _pendingCopies.remove(abort);
  }

  void Function() retainDelivery(void Function() release) {
    var released = false;
    late void Function() deliver;
    deliver = () {
      if (released) return;
      released = true;
      _deliveries.remove(deliver);
      release();
    };
    _deliveries[deliver] = _currentOwner;
    return deliver;
  }

  Future<void> settle() => _settle(includeControlFlow: true);

  Future<void> _settle({required bool includeControlFlow}) async {
    while (_live.isNotEmpty) {
      await Future.wait(_live.map((call) => call._done.future));
    }
    if (stopped) {
      await Future.wait(_aborting);
      for (final entry in _deliveries.entries.toList(growable: false)) {
        try {
          entry.key();
        } catch (error, stack) {
          _failure ??= _Failure(error, stack, entry.value);
        }
      }
    }
    _failure?.rethrowError();
    if (includeControlFlow) _controlFlow?.rethrowError();
  }

  Future<void> dispose() async {
    if (!_disposed) {
      _aborted =
          _aborted ||
          _live.isNotEmpty ||
          _pendingCopies.isNotEmpty ||
          _deliveries.isNotEmpty;
      _disposed = true;
      _stop(
        _failure ??
            _controlFlow ??
            _Failure(const _Disposed(), StackTrace.current),
      );
    }
    await _settle(includeControlFlow: false);
  }
}

/// Result resolution, first guest handoff, and body exit are independent.
final class WASIComponentGuestCall {
  WASIComponentGuestCall._(
    this.store,
    this._instance,
    this._exclusive,
    this._lockOnFailure,
    this._backpressure,
    this._cancelBeforeStart,
    this._onExit,
  ) : _owner = Zone.current[_ownerKey];
  final Object? _owner;
  final WASIComponentGuestStore store;
  final Object _instance;
  final bool _exclusive;
  final bool _lockOnFailure;
  final WASIComponentBackpressure? _backpressure;
  final void Function()? _cancelBeforeStart;
  final void Function()? _onExit;
  final _result = Completer<_Outcome<Object?>>();
  final _initialHandoff = Completer<void>();
  final _done = Completer<void>();
  Completer<void>? _permit;
  bool _entered = false;
  bool _blocked = false;
  bool _cancelledBeforeStart = false;

  static WASIComponentGuestCall? get current =>
      Zone.current[_executionKey] as WASIComponentGuestCall?;

  Future<void> get initialHandoff => _initialHandoff.future;
  Future<void> get bodyDone => _done.future;

  void resolve(Object? value) => _resolve(_Outcome.value(value));
  void _resolve(_Outcome<Object?> outcome) {
    if (!_result.isCompleted) _result.complete(outcome);
  }

  void _handoff() {
    if (!_initialHandoff.isCompleted) _initialHandoff.complete();
  }

  void cancelBeforeStart() {
    if (_entered || _cancelledBeforeStart) return;
    _cancelledBeforeStart = true;
    _cancelBeforeStart?.call();
    resolve(null);
    _handoff();
    // No guest code or argument conversion is run for a cancelled entry.
    store._tick();
  }

  void releaseExclusive() => store._releaseExclusive(this);

  Future<Object?> result() async {
    await initialHandoff;
    final caller = current;
    final outcome = caller != null && !_result.isCompleted
        ? await caller.wait(_result.future)
        : await _result.future;
    store.check();
    return outcome.result;
  }

  Future<T> wait<T>(Future<T> pending, {bool abortable = true}) async {
    if (_blocked) return await pending;
    store.check();
    store._leave(this);
    final value = pending.then<_Outcome<T>>(
      _Outcome<T>.value,
      onError: (Object error, StackTrace stack) =>
          _Outcome<T>.failed(_Failure(error, stack)),
    );
    store._tick();
    final outcome = abortable
        ? await Future.any<_Outcome<T>>([
            value,
            store._stopped.future.then(_Outcome<T>.failed),
          ])
        : await value;
    store.check();
    _permit = Completer<void>();
    store._ready.addLast(this);
    final permitted = _permit!.future;
    store._tick();
    await permitted;
    store.check();
    return outcome.result;
  }

  /// Ordinary implementation Futures never call this hook.
  static Future<T> suspend<T>(Future<T> pending) =>
      current?.wait(pending) ?? pending;
}
