@JS()
library;

import 'dart:collection';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'doom_runtime.dart';

const int _headerSize = 3;
const int _writeIndexOffset = 0;
const int _readIndexOffset = 1;
const int _capacityOffset = 2;

final class DoomSharedInputQueue {
  factory DoomSharedInputQueue({int capacity = 256}) {
    final reason = _sharedInputUnsupportedReason();
    if (reason != null) {
      return DoomSharedInputQueue._unsupported(
        capacity: capacity,
        unsupportedReason: reason,
      );
    }
    final queue = DoomSharedInputQueue._fromBuffer(
      _createSharedBuffer(capacity),
      capacity,
    );
    queue
      .._store(_writeIndexOffset, 0)
      .._store(_readIndexOffset, 0)
      .._store(_capacityOffset, capacity);
    return queue;
  }

  DoomSharedInputQueue._fromBuffer(JSObject buffer, this.capacity)
    : _buffer = buffer,
      _unsupportedReason = null,
      _view = _createInt32View(buffer, _slotCount(capacity));

  DoomSharedInputQueue._unsupported({
    required this.capacity,
    required String unsupportedReason,
  }) : _buffer = null,
       _view = null,
       _unsupportedReason = unsupportedReason;

  final JSObject? _buffer;
  final JSObject? _view;
  final int capacity;
  final String? _unsupportedReason;

  Object? get handle => _buffer;

  bool get isSupported => _buffer != null && _view != null;

  String? get unsupportedReason => _unsupportedReason;

  void enqueue(DoomInputEvent event) {
    if (!isSupported) {
      return;
    }

    var write = _load(_writeIndexOffset);
    var read = _load(_readIndexOffset);
    final nextWrite = (write + 1) % capacity;
    if (nextWrite == read) {
      read = (read + 1) % capacity;
      _store(_readIndexOffset, read);
    }

    final base = _headerSize + write * 2;
    _store(base, event.type);
    _store(base + 1, event.code);
    _store(_writeIndexOffset, nextWrite);
  }

  void drainInto(Queue<DoomInputEvent> queue) {
    if (!isSupported) {
      return;
    }

    var read = _load(_readIndexOffset);
    final write = _load(_writeIndexOffset);
    while (read != write) {
      final base = _headerSize + read * 2;
      queue.add(DoomInputEvent(type: _load(base), code: _load(base + 1)));
      read = (read + 1) % capacity;
    }
    _store(_readIndexOffset, read);
  }

  int _load(int index) {
    final view = _view;
    if (view == null) {
      return 0;
    }
    final value = _atomics.callMethodVarArgs<JSAny?>('load'.toJS, <JSAny?>[
      view,
      index.toJS,
    ]);
    return (value?.dartify() as num?)?.toInt() ?? 0;
  }

  void _store(int index, int value) {
    final view = _view;
    if (view == null) {
      return;
    }
    _atomics.callMethodVarArgs<JSAny?>('store'.toJS, <JSAny?>[
      view,
      index.toJS,
      value.toJS,
    ]);
  }

  static DoomSharedInputQueue? fromHandle(
    Object? handle, {
    required int capacity,
  }) {
    if (handle == null) {
      return null;
    }
    return DoomSharedInputQueue._fromBuffer(handle as JSObject, capacity);
  }
}

int _slotCount(int capacity) => _headerSize + capacity * 2;

JSObject _createSharedBuffer(int capacity) {
  final constructor = globalContext['SharedArrayBuffer'];
  return (constructor as JSFunction).callAsConstructorVarArgs<JSObject>(
    <JSAny?>[(_slotCount(capacity) * 4).toJS],
  );
}

JSObject _createInt32View(JSObject buffer, int length) {
  final constructor = globalContext['Int32Array'];
  return (constructor as JSFunction).callAsConstructorVarArgs<JSObject>(
    <JSAny?>[buffer, 0.toJS, length.toJS],
  );
}

String? _sharedInputUnsupportedReason() {
  if (globalContext['SharedArrayBuffer'] == null) {
    return 'SharedArrayBuffer is unavailable in this browser.';
  }
  if (globalContext['Atomics'] == null) {
    return 'Atomics is unavailable in this browser.';
  }
  final crossOriginIsolated = globalContext['crossOriginIsolated']?.dartify();
  if (crossOriginIsolated != true) {
    return 'Web keyboard input requires COOP/COEP so SharedArrayBuffer is enabled.';
  }
  return null;
}

JSObject get _atomics {
  final atomics = globalContext['Atomics'];
  if (atomics == null) {
    throw StateError('Atomics is unavailable.');
  }
  return atomics as JSObject;
}
