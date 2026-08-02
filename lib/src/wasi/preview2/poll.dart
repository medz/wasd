import 'dart:async';
import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../component/resource_table.dart';
import '../component/wit_adapter.dart';

/// Readiness source for WASI 0.2 `wasi:io/poll.pollable`.
final class WASIPreview2Pollable {
  /// Creates a pollable backed by readiness and wait callbacks.
  WASIPreview2Pollable({
    required bool Function() isReady,
    required Future<void> Function() waitReady,
  }) : _isReady = isReady,
       _waitReady = waitReady;

  final bool Function() _isReady;
  final Future<void> Function() _waitReady;

  /// Whether this pollable can complete without blocking.
  bool get isReady => _isReady();

  /// Waits until this pollable becomes ready.
  Future<void> block() async {
    while (!_isReady()) {
      await _waitReady();
    }
  }
}

/// WASI 0.2 `wasi:io/poll` host imports.
final class WASIPreview2PollHost {
  /// Creates a poll host backed by [table] or a new component resource table.
  WASIPreview2PollHost({WASIComponentResourceTable? table})
    : table = table ?? WASIComponentResourceTable();

  /// Component resource table that owns `pollable` handles.
  final WASIComponentResourceTable table;

  late final WASIComponentResourceType<WASIPreview2Pollable> _pollableType =
      table.defineType<WASIPreview2Pollable>('wasi:io/poll@0.2.0.pollable');

  /// Standard `wasi:io/poll@0.2.0` import callbacks.
  late final Map<String, WASIComponentWitAdapterCallback> imports =
      Map<String, WASIComponentWitAdapterCallback>.unmodifiable({
        'wasi:io/poll@0.2.0.pollable.ready': (args) =>
            _ready(_handle(args.single)),
        'wasi:io/poll@0.2.0.pollable.block': (args) =>
            _block(_handle(args.single)),
        'wasi:io/poll@0.2.0.poll': (args) => _poll(args.single),
      });

  /// Inserts [pollable] and returns an owned component handle.
  int insert(WASIPreview2Pollable pollable) {
    return table.insert<WASIPreview2Pollable>(_pollableType, pollable);
  }

  bool _ready(int handle) {
    return table.borrow<WASIPreview2Pollable, bool>(
      _pollableType,
      handle,
      (pollable) => pollable.isReady,
    );
  }

  FutureOr<void> _block(int handle) {
    final pollable = table.get<WASIPreview2Pollable>(_pollableType, handle);
    if (pollable.isReady) {
      return null;
    }
    return pollable.block();
  }

  FutureOr<WasmComponentValueData> _poll(Object? value) {
    final handles = _handles(value);
    if (handles.isEmpty) {
      throw StateError('WASI poll requires at least one pollable.');
    }
    final ready = _readyIndexes(handles);
    if (ready.isNotEmpty) {
      return _u32List(ready);
    }
    return _pollAsync(handles);
  }

  Future<WasmComponentValueData> _pollAsync(List<int> handles) async {
    while (true) {
      await Future.any([
        for (final handle in handles)
          table.get<WASIPreview2Pollable>(_pollableType, handle).block(),
      ]);
      final ready = _readyIndexes(handles);
      if (ready.isNotEmpty) {
        return _u32List(ready);
      }
    }
  }

  List<int> _readyIndexes(List<int> handles) {
    final ready = <int>[];
    for (var i = 0; i < handles.length; i++) {
      if (_ready(handles[i])) {
        ready.add(i);
      }
    }
    return ready;
  }
}

int _handle(Object? value) {
  return switch (value) {
    int() when value >= 0 && value <= _maxU32 => value,
    BigInt() when value >= BigInt.zero && value <= BigInt.from(_maxU32) =>
      value.toInt(),
    _ => throw StateError(
      'Expected WASI pollable resource handle, got $value.',
    ),
  };
}

List<int> _handles(Object? value) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.list) {
    throw StateError('Expected list<borrow<pollable>>.');
  }
  return [
    for (final item in value.items)
      if (item.kind == WasmComponentValueDataKind.integer)
        _handle(item.integer)
      else
        throw StateError('Expected pollable resource handle list item.'),
  ];
}

WasmComponentValueData _u32List(List<int> values) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    items: [
      for (final value in values)
        WasmComponentValueData(
          kind: WasmComponentValueDataKind.integer,
          rawBytes: Uint8List(0),
          integer: value,
        ),
    ],
  );
}

const int _maxU32 = 0xffffffff;
