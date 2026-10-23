import 'dart:collection';

import '../../host_control_flow.dart';
import '../../module.dart' show WasmFunction;
import 'exception.dart' as native_exception;
import 'interpreter/module.dart';
import 'interpreter/value.dart';
import 'interpreter/vm.dart';

final class HostCallbackFailure implements WasmHostControlFlowException {
  HostCallbackFailure(this.error, this.stack);

  final Object error;
  final StackTrace stack;

  Never rethrowOriginal() => Error.throwWithStackTrace(error, stack);
}

final class _ExternalReference {
  const _ExternalReference(this.id, this.value);

  final int id;
  final Object value;
}

final class _FunctionReference {
  const _FunctionReference(this.id, this.owner);

  final int id;
  final ReferenceValues owner;
}

/// Public embedding values, kept separate from the interpreter's raw carriers.
final class ReferenceValues {
  static var _nextExternal = 0x30000000;
  static final _objects = Expando<_ExternalReference>();
  static final _primitives =
      HashMap<Object, WeakReference<_ExternalReference>>.identity();
  static final _externals = <int, WeakReference<_ExternalReference>>{};
  static final _externalFinalizer = Finalizer<(int, Object?)>((entry) {
    final (id, primitive) = entry;
    _externals.remove(id);
    if (primitive != null && _primitives[primitive]?.target == null) {
      _primitives.remove(primitive);
    }
  });
  static final _functionOwners = Expando<_FunctionReference>();
  static int? functionReference(Function function) =>
      _functionOwners[function]?.id;

  static _FunctionReference? _checkedFunction(Object? value) {
    if (value == null) return null;
    final reference = value is Function ? _functionOwners[value] : null;
    if (reference == null) {
      throw ArgumentError('funcref requires a function from this backend.');
    }
    return reference;
  }

  static void validateFunction(Object? value) {
    _checkedFunction(value);
  }

  static bool functionNeedsAsync(Function function) {
    final reference = _functionOwners[function];
    return reference != null &&
        WasmVm.functionReferenceNeedsAsync(reference.id);
  }

  static final _functions = <int, WeakReference<WasmFunction>>{};
  static final _functionFinalizer = Finalizer<int>((id) {
    if (_functions[id]?.target == null) _functions.remove(id);
  });

  // Connected instances/globals share a store lifetime, including references
  // copied into guest locals/tables after their original global is overwritten.
  // The global directories above do not strongly retain these stores/objects.
  final _values = <int, _ExternalReference>{};
  final _records = HashMap<Object, _ExternalReference>.identity();
  final _peers = <ReferenceValues>{};

  void connect(ReferenceValues other) {
    if (identical(this, other)) return;
    _peers.add(other);
    other._peers.add(this);
  }

  _ExternalReference? _record(Object value) {
    final existing = _records[value];
    if (existing != null) return existing;
    final visited = <ReferenceValues>{this};
    final pending = _peers.toList();
    while (pending.isNotEmpty) {
      final peer = pending.removeLast();
      if (!visited.add(peer)) continue;
      final entry = peer._records[value];
      if (entry != null) return _records[value] = entry;
      pending.addAll(peer._peers);
    }
    return null;
  }

  static bool isExtern(String? signature) =>
      signature == '6f' || signature == '636f';

  static bool isFunction(String? signature) =>
      signature == '70' || signature == '6370';

  static bool needsConversion(WasmFunctionType type) =>
      type.paramTypeSignatures.any(_isReferenceSignature) ||
      type.resultTypeSignatures.any(_isReferenceSignature);

  static bool _isReferenceSignature(String signature) =>
      !const {'7f', '7e', '7d', '7c', '7b'}.contains(signature);

  static void checkFunctionSignature(WasmFunctionType type) {
    for (final signature in [
      ...type.paramTypeSignatures,
      ...type.resultTypeSignatures,
    ]) {
      if (_isReferenceSignature(signature)) checkSignature(signature);
    }
  }

  static void checkSignature(String? signature) {
    if (signature == null ||
        const {'7f', '7e', '7d', '7c'}.contains(signature) ||
        isExtern(signature) ||
        isFunction(signature)) {
      return;
    }
    throw UnsupportedError(
      'Native public reference bindings support nullable externref and '
      'funcref only; unsupported signature `$signature`.',
    );
  }

  Object? encode(String? signature, Object? value) {
    checkSignature(signature);
    if (isExtern(signature)) {
      if (value == null) return -1;
      final primitive =
          value is num || value is bool || value is String || value is Record;
      final record = value is Record;
      var entry = record
          ? _record(value)
          : primitive
          ? _primitives[value]?.target
          : _objects[value];
      if (entry == null) {
        if (_nextExternal >= 0x40000000) {
          throw StateError('External reference id space exhausted.');
        }
        entry = _ExternalReference(_nextExternal++, value);
        final weak = WeakReference(entry);
        _externals[entry.id] = weak;
        if (record) {
          _records[value] = entry;
        } else if (primitive) {
          _primitives[value] = weak;
        } else {
          _objects[value] = entry;
        }
        _externalFinalizer.attach(entry, (
          entry.id,
          primitive && !record ? value : null,
        ));
      }
      _values[entry.id] = entry;
      return entry.id;
    }
    if (isFunction(signature)) {
      final reference = _checkedFunction(value);
      if (reference == null) return -1;
      connect(reference.owner);
      return reference.id;
    }
    return value;
  }

  Object? decode(String? signature, Object? value) {
    checkSignature(signature);
    if (isExtern(signature)) {
      if (value == -1) return null;
      final entry = _externals[value]?.target;
      if (entry == null) throw StateError('Unknown external reference.');
      _values[entry.id] = entry;
      if (entry.value is Record) _records[entry.value] = entry;
      return entry.value;
    }
    if (isFunction(signature)) {
      if (value == -1) return null;
      return function(value as int);
    }
    return value;
  }

  WasmFunction registerFunction(int reference, WasmFunction function) {
    final existing = _functions[reference]?.target;
    if (existing != null) {
      connect(_functionOwners[existing]!.owner);
      return existing;
    }
    _functionOwners[function] = _FunctionReference(reference, this);
    _functions[reference] = WeakReference(function);
    _functionFinalizer.attach(function, reference);
    return function;
  }

  WasmFunction function(int reference) {
    final existing = _functions[reference]?.target;
    if (existing != null) {
      connect(_functionOwners[existing]!.owner);
      return existing;
    }
    final type = WasmVm.functionReferenceType(reference);
    return registerFunction(reference, (List<Object?> args) {
      try {
        final encoded = _typedArguments(reference, type, args);
        if (WasmVm.functionReferenceNeedsAsync(reference)) {
          return WasmVm.invokePublicFunctionReferenceAsync(
            reference,
            encoded,
          ).then(
            (results) => _publicResults(type, results),
            onError: (Object error, StackTrace stack) =>
                rethrowPublicError(error, stack),
          );
        }
        return _publicResults(
          type,
          WasmVm.invokePublicFunctionReference(reference, encoded),
        );
      } catch (error, stack) {
        rethrowPublicError(error, stack);
      }
    });
  }

  List<WasmValue> _typedArguments(
    int reference,
    WasmFunctionType type,
    List<Object?> args,
  ) {
    checkFunctionSignature(type);
    if (args.length != type.params.length) {
      throw ArgumentError('Function expects ${type.params.length} arguments.');
    }
    final encoded = encodeArguments(type, args);
    for (var i = 0; i < encoded.length; i++) {
      if (isFunction(type.paramTypeSignatures[i])) {
        WasmVm.retainFunctionReferenceDependency(reference, encoded[i]! as int);
      }
    }
    return [
      for (var i = 0; i < encoded.length; i++)
        WasmValue.fromExternal(type.params[i], encoded[i]),
    ];
  }

  Object? _publicResults(WasmFunctionType type, List<WasmValue> results) =>
      decodeResults(
        type,
        results.length == 1
            ? results.single.toExternal()
            : results.isEmpty
            ? null
            : WasmValue.encodeResults(results),
      );

  List<Object?> encodeArguments(WasmFunctionType type, List<Object?> args) =>
      args.length != type.params.length
      ? args
      : [
          for (var i = 0; i < args.length; i++)
            encode(type.paramTypeSignatures[i], args[i]),
        ];

  List<Object?> decodeArguments(WasmFunctionType type, List<Object?> args) => [
    for (var i = 0; i < args.length; i++)
      decode(type.paramTypeSignatures[i], args[i]),
  ];

  Object? encodeResults(WasmFunctionType type, Object? value) {
    final signatures = type.resultTypeSignatures;
    if (signatures.isEmpty) return value;
    if (signatures.length == 1) return encode(signatures.single, value);
    if (value is! List || value.length != signatures.length) return value;
    return [
      for (var i = 0; i < signatures.length; i++)
        encode(signatures[i], value[i]),
    ];
  }

  Object? decodeResults(WasmFunctionType type, Object? value) {
    final signatures = type.resultTypeSignatures;
    if (signatures.isEmpty) return value;
    if (signatures.length == 1) return decode(signatures.single, value);
    final values = value as List;
    return [
      for (var i = 0; i < signatures.length; i++)
        decode(signatures[i], values[i]),
    ];
  }

  Never rethrowPublicError(Object error, StackTrace stack) {
    if (error is HostCallbackFailure) error.rethrowOriginal();
    if (error is WasmGuestException) {
      Error.throwWithStackTrace(
        native_exception.Exception.fromRuntime(error, this),
        stack,
      );
    }
    Error.throwWithStackTrace(error, stack);
  }
}
