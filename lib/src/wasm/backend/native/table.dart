import '../../table.dart' as wasm;
import '../../value.dart';
import 'interpreter/module.dart' as ir;
import 'interpreter/table.dart';
import 'reference_values.dart';

class Table<T extends Value<T, V>, V extends Object?>
    implements wasm.Table<T, V> {
  Table(this.descriptor, [V? value])
    : _values = List<V?>.filled(
        _initialSize(descriptor),
        value,
        growable: true,
      );

  Table._fromRuntime(this.descriptor, WasmTable binding, this._references)
    : _host = binding {
    binding.hostAccessible = true;
  }

  final wasm.TableDescriptor<T, V> descriptor;
  List<V?>? _values;
  WasmTable? _host;
  ReferenceValues? _references;
  ReferenceValues get references => _references ??= ReferenceValues();

  String get _signature =>
      descriptor.element == wasm.TableKind.externref ? '6f' : '70';

  WasmTable get host {
    final binding = prepareBinding(references);
    bind(binding, references);
    return binding;
  }

  WasmTable prepareBinding(ReferenceValues owner) {
    final existing = _host;
    if (existing != null) return existing;
    final values = _values!;
    if (_signature == '70') {
      for (final value in values) {
        ReferenceValues.validateFunction(value);
      }
    }
    final binding = WasmTable(
      refType: descriptor.element == wasm.TableKind.externref
          ? ir.WasmRefType.externref
          : ir.WasmRefType.funcref,
      min: values.length,
      max: descriptor.maximum,
      refTypeSignature: _signature,
    );
    // Connect function owners only when all imports have passed validation.
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      binding[i] = _signature == '70'
          ? value == null
                ? null
                : ReferenceValues.functionReference(value as Function)!
          : _encode(value, owner: owner);
    }
    return binding;
  }

  void bind(WasmTable binding, ReferenceValues owner) {
    final existing = _host;
    if (existing != null && !identical(existing, binding)) {
      throw StateError('Table binding changed during instantiation.');
    }
    if (_signature == '70') {
      for (final value in _values ?? const []) {
        owner.encode(_signature, value);
      }
    }
    _host = binding;
    _values = null;
    _references ??= owner;
    references.connect(owner);
    binding.hostAccessible = true;
  }

  int? _encode(Object? value, {ReferenceValues? owner}) {
    final encoded = (owner ?? references).encode(_signature, value)! as int;
    return encoded == -1 ? null : encoded;
  }

  @override
  int get length => _host?.length ?? _values!.length;

  @override
  V? get(int index) {
    final binding = _host;
    if (binding == null) return _values![index];
    return references.decode(_signature, binding[index] ?? -1) as V?;
  }

  @override
  void set(int index, V? value) {
    final binding = _host;
    if (binding == null) {
      _values![index] = value;
    } else {
      RangeError.checkValidIndex(index, binding, 'index', binding.length);
      binding[index] = _encode(value);
    }
  }

  @override
  int grow(int delta, [V? value]) {
    if (delta < 0) {
      throw ArgumentError.value(delta, 'delta', 'must be >= 0');
    }

    final binding = _host;
    if (binding != null) {
      if (_signature == '70') ReferenceValues.validateFunction(value);
      _checkGrowth(binding.length, delta, binding.max);
      final previous = binding.grow(delta, _encode(value));
      if (previous == -1) throw RangeError('Table maximum exceeded.');
      return previous;
    }
    final values = _values!;
    final oldLength = values.length;
    _checkGrowth(oldLength, delta, descriptor.maximum);
    final nextLength = oldLength + delta;

    values.length = nextLength;
    if (delta > 0) {
      values.fillRange(oldLength, nextLength, value);
    }
    return oldLength;
  }
}

void _checkGrowth(int length, int delta, int? maximum) {
  if (delta > 0x7fffffff - length ||
      (maximum != null && delta > maximum - length)) {
    throw RangeError('Table maximum exceeded.');
  }
}

int _initialSize(wasm.TableDescriptor descriptor) {
  if (descriptor.initial < 0) {
    throw ArgumentError.value(descriptor.initial, 'initial', 'must be >= 0');
  }
  if (descriptor.maximum != null && descriptor.maximum! < descriptor.initial) {
    throw ArgumentError.value(
      descriptor.maximum,
      'maximum',
      'must be >= initial',
    );
  }
  return descriptor.initial;
}

void checkSupportedType(ir.WasmTableType type) {
  if (type.isTable64) {
    throw UnsupportedError('Native public table64 bindings are unsupported.');
  }
  ReferenceValues.checkSignature(type.refTypeSignature);
}

Table fromRuntime(WasmTable binding, ReferenceValues references) {
  final signature =
      binding.refTypeSignature ??
      (binding.refType == ir.WasmRefType.externref ? '6f' : '70');
  if (ReferenceValues.isExtern(signature)) {
    return Table<ExternRef, Object?>._fromRuntime(
      wasm.TableDescriptor(
        wasm.TableKind.externref,
        binding.length,
        binding.max,
      ),
      binding,
      references,
    );
  }
  if (ReferenceValues.isFunction(signature)) {
    return Table<FuncRef, Function?>._fromRuntime(
      wasm.TableDescriptor(wasm.TableKind.funcref, binding.length, binding.max),
      binding,
      references,
    );
  }
  throw UnsupportedError('Unsupported public table element type `$signature`.');
}
