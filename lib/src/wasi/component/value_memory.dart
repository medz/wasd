import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../../wasm/memory.dart' as wasm;

/// Canonical ABI memory codec for one component value type.
///
/// This is intentionally internal. It implements the fixed-size Canonical ABI
/// `alignment`/`elem_size`/`load`/`store` path used by stream/future copy
/// buffers. Dynamic values that require allocation, handle-table semantics, or
/// borrow tracking are reported as unsupported instead of being approximated.
final class WASIComponentCanonicalValueMemoryCodec {
  const WASIComponentCanonicalValueMemoryCodec._(this._layout);

  /// Builds a fixed-size Canonical ABI codec for [type].
  ///
  /// Returns `null` when [type] contains dynamic list/string data, component
  /// handles, borrows, nested stream/future values, or an invalid type index.
  static WASIComponentCanonicalValueMemoryCodec? fromValueType(
    WasmComponentValueType type,
    List<WasmComponentTypeDefinition> definitions,
  ) {
    final layout = _LayoutResolver(definitions).resolveValueType(type);
    return layout == null
        ? null
        : WASIComponentCanonicalValueMemoryCodec._(layout);
  }

  final _CanonicalValueLayout _layout;

  /// Number of guest-memory bytes occupied by one value.
  int get byteLength => _layout.byteLength;

  /// Required guest-memory pointer alignment for one value.
  int get alignment => _layout.alignment;

  /// Primitive type for primitive layouts; otherwise `null`.
  WasmComponentPrimitiveValueType? get primitive => _layout.primitive;

  /// Loads one value from [memory] at [pointer].
  Object? load(wasm.Memory memory, int pointer) {
    final bytes = Uint8List.view(memory.buffer);
    _checkMemoryRange(bytes, pointer, _layout.byteLength, _layout.alignment);
    return _layout.load(ByteData.view(memory.buffer), bytes, pointer);
  }

  /// Loads one typed value from [memory] at [pointer].
  T loadAs<T>(wasm.Memory memory, int pointer, String name) {
    final bytes = Uint8List.view(memory.buffer);
    _checkMemoryRange(bytes, pointer, _layout.byteLength, _layout.alignment);
    return _loadAs<T>(ByteData.view(memory.buffer), bytes, pointer, name);
  }

  /// Loads [elementCount] contiguous values from [memory].
  List<Object?> loadMany(wasm.Memory memory, int pointer, int elementCount) {
    RangeError.checkNotNegative(elementCount, 'elementCount');
    final bytes = Uint8List.view(memory.buffer);
    _checkMemoryRange(
      bytes,
      pointer,
      elementCount * _layout.byteLength,
      _layout.alignment,
    );
    final data = ByteData.view(memory.buffer);
    final values = <Object?>[];
    for (var i = 0; i < elementCount; i++) {
      values.add(_layout.load(data, bytes, pointer + i * _layout.byteLength));
    }
    return values;
  }

  /// Loads [elementCount] typed contiguous values from [memory].
  List<T> loadManyAs<T>(
    wasm.Memory memory,
    int pointer,
    int elementCount,
    String name,
  ) {
    RangeError.checkNotNegative(elementCount, 'elementCount');
    final bytes = Uint8List.view(memory.buffer);
    _checkMemoryRange(
      bytes,
      pointer,
      elementCount * _layout.byteLength,
      _layout.alignment,
    );
    final data = ByteData.view(memory.buffer);
    return List<T>.generate(
      elementCount,
      (index) =>
          _loadAs<T>(data, bytes, pointer + index * _layout.byteLength, name),
      growable: false,
    );
  }

  /// Stores one [value] into [memory] at [pointer].
  void store(wasm.Memory memory, int pointer, Object? value) {
    final bytes = Uint8List.view(memory.buffer);
    _checkMemoryRange(bytes, pointer, _layout.byteLength, _layout.alignment);
    _layout.store(ByteData.view(memory.buffer), pointer, value);
  }

  /// Stores contiguous [values] into [memory].
  void storeMany(wasm.Memory memory, int pointer, List<Object?> values) {
    final bytes = Uint8List.view(memory.buffer);
    _checkMemoryRange(
      bytes,
      pointer,
      values.length * _layout.byteLength,
      _layout.alignment,
    );
    final data = ByteData.view(memory.buffer);
    for (var i = 0; i < values.length; i++) {
      _layout.store(data, pointer + i * _layout.byteLength, values[i]);
    }
  }

  /// Validates [value] against this canonical value shape.
  void validate(String name, Object? value) {
    _layout.validate(name, value);
  }

  T _loadAs<T>(ByteData data, Uint8List bytes, int pointer, String name) {
    final value = _layout.load(data, bytes, pointer);
    // Layout loads either produce the canonical shape or throw while decoding.
    if (value is T) {
      return value;
    }
    throw StateError('WASI component canonical value $name expected $T.');
  }
}

final class _LayoutResolver {
  _LayoutResolver(this.definitions);

  final List<WasmComponentTypeDefinition> definitions;
  final Map<int, _CanonicalValueLayout?> _cache =
      <int, _CanonicalValueLayout?>{};
  final Set<int> _visiting = <int>{};

  _CanonicalValueLayout? resolveValueType(WasmComponentValueType type) {
    switch (type.kind) {
      case WasmComponentValueTypeKind.primitive:
        final primitive = type.primitive;
        return primitive == null ? null : _primitiveLayout(primitive);
      case WasmComponentValueTypeKind.typeIndex:
        final typeIndex = type.typeIndex;
        if (typeIndex == null ||
            typeIndex < 0 ||
            typeIndex >= definitions.length) {
          return null;
        }
        if (_cache.containsKey(typeIndex)) {
          return _cache[typeIndex];
        }
        if (!_visiting.add(typeIndex)) {
          return null;
        }
        _cache[typeIndex] = null;
        final definition = definitions[typeIndex];
        final definedValue = definition.definedValue;
        final layout =
            definition.kind == WasmComponentTypeKind.definedValue &&
                definedValue != null
            ? _resolveDefinedValue(definedValue)
            : null;
        _visiting.remove(typeIndex);
        _cache[typeIndex] = layout;
        return layout;
    }
  }

  _CanonicalValueLayout? _resolveDefinedValue(
    WasmComponentDefinedValueType type,
  ) {
    switch (type.kind) {
      case WasmComponentDefinedValueTypeKind.primitive:
        final primitive = type.primitive;
        return primitive == null ? null : _primitiveLayout(primitive);
      case WasmComponentDefinedValueTypeKind.record:
        final fields = <_FieldLayout>[];
        for (final field in type.fields) {
          final layout = resolveValueType(field.type);
          if (layout == null) {
            return null;
          }
          fields.add(_FieldLayout(field.label, layout));
        }
        return _RecordLayout(WasmComponentValueDataKind.record, fields);
      case WasmComponentDefinedValueTypeKind.tuple:
        final fields = <_FieldLayout>[];
        for (var i = 0; i < type.types.length; i++) {
          final layout = resolveValueType(type.types[i]);
          if (layout == null) {
            return null;
          }
          fields.add(_FieldLayout('$i', layout));
        }
        return _RecordLayout(WasmComponentValueDataKind.tuple, fields);
      case WasmComponentDefinedValueTypeKind.fixedList:
        final elementType = type.elementType;
        final fixedLength = type.fixedLength;
        if (elementType == null || fixedLength == null) {
          return null;
        }
        final elementLayout = resolveValueType(elementType);
        return elementLayout == null
            ? null
            : _FixedListLayout(elementLayout, fixedLength);
      case WasmComponentDefinedValueTypeKind.flags:
        return _FlagsLayout(type.labels);
      case WasmComponentDefinedValueTypeKind.variant:
        return _variantLayout(type.cases, WasmComponentValueDataKind.variant);
      case WasmComponentDefinedValueTypeKind.enumeration:
        return _variantLayout([
          for (final label in type.labels)
            WasmComponentVariantCase(label: label),
        ], WasmComponentValueDataKind.enumeration);
      case WasmComponentDefinedValueTypeKind.option:
        final cases = <WasmComponentVariantCase>[
          const WasmComponentVariantCase(label: 'none'),
          WasmComponentVariantCase(label: 'some', type: type.elementType),
        ];
        return _variantLayout(cases, WasmComponentValueDataKind.option);
      case WasmComponentDefinedValueTypeKind.result:
        final cases = <WasmComponentVariantCase>[
          WasmComponentVariantCase(label: 'ok', type: type.okType),
          WasmComponentVariantCase(label: 'error', type: type.errorType),
        ];
        return _variantLayout(cases, WasmComponentValueDataKind.result);
      case WasmComponentDefinedValueTypeKind.list:
      case WasmComponentDefinedValueTypeKind.own:
      case WasmComponentDefinedValueTypeKind.borrow:
      case WasmComponentDefinedValueTypeKind.stream:
      case WasmComponentDefinedValueTypeKind.future:
        return null;
    }
  }

  _CanonicalValueLayout? _variantLayout(
    List<WasmComponentVariantCase> cases,
    WasmComponentValueDataKind kind,
  ) {
    final caseLayouts = <_CaseLayout>[];
    for (final case_ in cases) {
      final caseType = case_.type;
      final layout = caseType == null ? null : resolveValueType(caseType);
      if (caseType != null && layout == null) {
        return null;
      }
      caseLayouts.add(_CaseLayout(case_.label, layout));
    }
    return _VariantLayout(kind, caseLayouts);
  }
}

abstract final class _CanonicalValueLayout {
  const _CanonicalValueLayout();

  int get byteLength;
  int get alignment;
  WasmComponentPrimitiveValueType? get primitive => null;

  Object? load(ByteData data, Uint8List bytes, int pointer);
  WasmComponentValueData loadData(ByteData data, Uint8List bytes, int pointer);
  void store(ByteData data, int pointer, Object? value);
  void storeData(ByteData data, int pointer, WasmComponentValueData value);
  void validate(String name, Object? value);
}

final class _PrimitiveLayout extends _CanonicalValueLayout {
  const _PrimitiveLayout(this.primitive, this.byteLength, this.alignment);

  @override
  final WasmComponentPrimitiveValueType primitive;

  @override
  final int byteLength;

  @override
  final int alignment;

  @override
  Object load(ByteData data, Uint8List bytes, int pointer) {
    return _readPrimitive(data, pointer, primitive);
  }

  @override
  WasmComponentValueData loadData(ByteData data, Uint8List bytes, int pointer) {
    final value = load(data, bytes, pointer);
    return _primitiveData(
      primitive,
      value,
      _copyRawBytes(bytes, pointer, byteLength),
    );
  }

  @override
  void store(ByteData data, int pointer, Object? value) {
    validate(primitive.name, value);
    _writePrimitive(data, pointer, primitive, value);
  }

  @override
  void storeData(ByteData data, int pointer, WasmComponentValueData value) {
    store(data, pointer, _primitiveValueFromData(primitive, value));
  }

  @override
  void validate(String name, Object? value) {
    var candidate = value;
    if (value is WasmComponentValueData) {
      try {
        candidate = _primitiveValueFromData(primitive, value);
      } on StateError {
        candidate = value;
      }
    }
    if (_primitiveValueMatches(primitive, candidate)) {
      return;
    }
    throw StateError(
      'WASI component canonical value $name expected ${primitive.name}.',
    );
  }
}

final class _FieldLayout {
  const _FieldLayout(this.label, this.layout);

  final String label;
  final _CanonicalValueLayout layout;
}

final class _RecordLayout extends _CanonicalValueLayout {
  _RecordLayout(this.kind, this.fields)
    : alignment = _maxAlignment(fields.map((field) => field.layout)),
      byteLength = _recordByteLength(fields);

  final WasmComponentValueDataKind kind;
  final List<_FieldLayout> fields;

  @override
  final int byteLength;

  @override
  final int alignment;

  @override
  Object load(ByteData data, Uint8List bytes, int pointer) {
    return loadData(data, bytes, pointer);
  }

  @override
  WasmComponentValueData loadData(ByteData data, Uint8List bytes, int pointer) {
    var cursor = pointer;
    final items = <WasmComponentValueData>[];
    for (final field in fields) {
      cursor = _alignTo(cursor, field.layout.alignment);
      items.add(field.layout.loadData(data, bytes, cursor));
      cursor += field.layout.byteLength;
    }
    return WasmComponentValueData(
      kind: kind,
      rawBytes: _copyRawBytes(bytes, pointer, byteLength),
      items: List<WasmComponentValueData>.unmodifiable(items),
    );
  }

  @override
  void store(ByteData data, int pointer, Object? value) {
    if (value is! WasmComponentValueData || value.kind != kind) {
      throw StateError(
        'WASI component canonical value expected ${kind.name} data.',
      );
    }
    storeData(data, pointer, value);
  }

  @override
  void storeData(ByteData data, int pointer, WasmComponentValueData value) {
    if (value.kind != kind || value.items.length != fields.length) {
      throw StateError(
        'WASI component canonical value expected ${kind.name} with '
        '${fields.length} items.',
      );
    }
    var cursor = pointer;
    for (var i = 0; i < fields.length; i++) {
      final field = fields[i];
      cursor = _alignTo(cursor, field.layout.alignment);
      field.layout.storeData(data, cursor, value.items[i]);
      cursor += field.layout.byteLength;
    }
  }

  @override
  void validate(String name, Object? value) {
    if (value is WasmComponentValueData &&
        value.kind == kind &&
        value.items.length == fields.length) {
      for (var i = 0; i < fields.length; i++) {
        fields[i].layout.validate('$name.${fields[i].label}', value.items[i]);
      }
      return;
    }
    throw StateError(
      'WASI component canonical value $name expected ${kind.name} data.',
    );
  }
}

final class _FixedListLayout extends _CanonicalValueLayout {
  const _FixedListLayout(this.elementLayout, this.length);

  final _CanonicalValueLayout elementLayout;
  final int length;

  @override
  int get byteLength => length * elementLayout.byteLength;

  @override
  int get alignment => elementLayout.alignment;

  @override
  Object load(ByteData data, Uint8List bytes, int pointer) {
    return loadData(data, bytes, pointer);
  }

  @override
  WasmComponentValueData loadData(ByteData data, Uint8List bytes, int pointer) {
    final items = <WasmComponentValueData>[];
    for (var i = 0; i < length; i++) {
      items.add(
        elementLayout.loadData(
          data,
          bytes,
          pointer + i * elementLayout.byteLength,
        ),
      );
    }
    return WasmComponentValueData(
      kind: WasmComponentValueDataKind.fixedList,
      rawBytes: _copyRawBytes(bytes, pointer, byteLength),
      items: List<WasmComponentValueData>.unmodifiable(items),
    );
  }

  @override
  void store(ByteData data, int pointer, Object? value) {
    if (value is! WasmComponentValueData ||
        value.kind != WasmComponentValueDataKind.fixedList) {
      throw StateError(
        'WASI component canonical value expected fixedList data.',
      );
    }
    storeData(data, pointer, value);
  }

  @override
  void storeData(ByteData data, int pointer, WasmComponentValueData value) {
    if (value.kind != WasmComponentValueDataKind.fixedList ||
        value.items.length != length) {
      throw StateError(
        'WASI component canonical value expected fixedList with $length items.',
      );
    }
    for (var i = 0; i < length; i++) {
      elementLayout.storeData(
        data,
        pointer + i * elementLayout.byteLength,
        value.items[i],
      );
    }
  }

  @override
  void validate(String name, Object? value) {
    if (value is WasmComponentValueData &&
        value.kind == WasmComponentValueDataKind.fixedList &&
        value.items.length == length) {
      for (var i = 0; i < length; i++) {
        elementLayout.validate('$name[$i]', value.items[i]);
      }
      return;
    }
    throw StateError(
      'WASI component canonical value $name expected fixedList data.',
    );
  }
}

final class _FlagsLayout extends _CanonicalValueLayout {
  _FlagsLayout(this.labels) : byteLength = _flagsByteLength(labels.length);

  final List<String> labels;

  @override
  final int byteLength;

  @override
  int get alignment => byteLength;

  @override
  Object load(ByteData data, Uint8List bytes, int pointer) {
    return loadData(data, bytes, pointer);
  }

  @override
  WasmComponentValueData loadData(ByteData data, Uint8List bytes, int pointer) {
    final bits = _readUnsigned(data, pointer, byteLength);
    final activeLabels = <String>[];
    for (var i = 0; i < labels.length; i++) {
      if ((bits & (1 << i)) != 0) {
        activeLabels.add(labels[i]);
      }
    }
    return WasmComponentValueData(
      kind: WasmComponentValueDataKind.flags,
      rawBytes: _copyRawBytes(bytes, pointer, byteLength),
      labels: List<String>.unmodifiable(activeLabels),
    );
  }

  @override
  void store(ByteData data, int pointer, Object? value) {
    if (value is! WasmComponentValueData ||
        value.kind != WasmComponentValueDataKind.flags) {
      throw StateError('WASI component canonical value expected flags data.');
    }
    storeData(data, pointer, value);
  }

  @override
  void storeData(ByteData data, int pointer, WasmComponentValueData value) {
    if (value.kind != WasmComponentValueDataKind.flags) {
      throw StateError('WASI component canonical value expected flags data.');
    }
    var bits = 0;
    for (final label in value.labels) {
      final index = labels.indexOf(label);
      if (index < 0) {
        throw StateError('Unknown WASI component flag label: $label.');
      }
      bits |= 1 << index;
    }
    _writeUnsigned(data, pointer, byteLength, bits);
  }

  @override
  void validate(String name, Object? value) {
    if (value is WasmComponentValueData &&
        value.kind == WasmComponentValueDataKind.flags) {
      for (final label in value.labels) {
        if (!labels.contains(label)) {
          throw StateError(
            'WASI component canonical value $name has unknown flag $label.',
          );
        }
      }
      return;
    }
    throw StateError(
      'WASI component canonical value $name expected flags data.',
    );
  }
}

final class _CaseLayout {
  const _CaseLayout(this.label, this.layout);

  final String label;
  final _CanonicalValueLayout? layout;
}

final class _VariantLayout extends _CanonicalValueLayout {
  _VariantLayout(this.kind, this.cases)
    : _discriminantByteLength = _discriminantByteLengthFor(cases.length),
      _maxCaseAlignment = _maxNullableAlignment(
        cases.map((case_) => case_.layout),
      ),
      _maxCaseByteLength = _maxNullableByteLength(
        cases.map((case_) => case_.layout),
      );

  final WasmComponentValueDataKind kind;
  final List<_CaseLayout> cases;
  final int _discriminantByteLength;
  final int _maxCaseAlignment;
  final int _maxCaseByteLength;

  @override
  int get alignment => _max(_discriminantByteLength, _maxCaseAlignment);

  @override
  int get byteLength {
    final payloadOffset = _alignTo(_discriminantByteLength, _maxCaseAlignment);
    return _alignTo(payloadOffset + _maxCaseByteLength, alignment);
  }

  @override
  Object load(ByteData data, Uint8List bytes, int pointer) {
    return loadData(data, bytes, pointer);
  }

  @override
  WasmComponentValueData loadData(ByteData data, Uint8List bytes, int pointer) {
    final index = _readUnsigned(data, pointer, _discriminantByteLength);
    if (index >= cases.length) {
      throw StateError('Invalid WASI component variant case index: $index.');
    }
    final case_ = cases[index];
    final payloadOffset = _alignTo(
      pointer + _discriminantByteLength,
      _maxCaseAlignment,
    );
    final associated = case_.layout?.loadData(data, bytes, payloadOffset);
    return WasmComponentValueData(
      kind: kind,
      rawBytes: _copyRawBytes(bytes, pointer, byteLength),
      index: index,
      label: case_.label,
      associatedValue: associated,
      isSome: kind == WasmComponentValueDataKind.option ? index == 1 : null,
      isOk: kind == WasmComponentValueDataKind.result ? index == 0 : null,
    );
  }

  @override
  void store(ByteData data, int pointer, Object? value) {
    if (value is! WasmComponentValueData || value.kind != kind) {
      throw StateError(
        'WASI component canonical value expected ${kind.name} data.',
      );
    }
    storeData(data, pointer, value);
  }

  @override
  void storeData(ByteData data, int pointer, WasmComponentValueData value) {
    if (value.kind != kind) {
      throw StateError(
        'WASI component canonical value expected ${kind.name} data.',
      );
    }
    final index = _caseIndex(value);
    _writeUnsigned(data, pointer, _discriminantByteLength, index);
    final layout = cases[index].layout;
    if (layout != null) {
      final associated = value.associatedValue;
      if (associated == null) {
        throw StateError(
          'WASI component canonical value ${cases[index].label} needs payload.',
        );
      }
      final payloadOffset = _alignTo(
        pointer + _discriminantByteLength,
        _maxCaseAlignment,
      );
      layout.storeData(data, payloadOffset, associated);
    }
  }

  @override
  void validate(String name, Object? value) {
    if (value is WasmComponentValueData && value.kind == kind) {
      final index = _caseIndex(value);
      final layout = cases[index].layout;
      final associated = value.associatedValue;
      if (layout == null && associated == null) {
        return;
      }
      if (layout != null && associated != null) {
        layout.validate('$name.${cases[index].label}', associated);
        return;
      }
    }
    throw StateError(
      'WASI component canonical value $name expected ${kind.name} data.',
    );
  }

  int _caseIndex(WasmComponentValueData value) {
    final index = value.index;
    if (index != null) {
      if (index < 0 || index >= cases.length) {
        throw StateError('Invalid WASI component variant case index: $index.');
      }
      return index;
    }
    final label = value.label;
    if (label != null) {
      final index = cases.indexWhere((case_) => case_.label == label);
      if (index >= 0) {
        return index;
      }
    }
    throw StateError('WASI component canonical variant value needs a case.');
  }
}

_PrimitiveLayout? _primitiveLayout(WasmComponentPrimitiveValueType primitive) {
  final layout = switch (primitive) {
    WasmComponentPrimitiveValueType.boolean ||
    WasmComponentPrimitiveValueType.s8 ||
    WasmComponentPrimitiveValueType.u8 => const _PrimitiveLayout(
      _primitivePlaceholder,
      1,
      1,
    ),
    WasmComponentPrimitiveValueType.s16 ||
    WasmComponentPrimitiveValueType.u16 => const _PrimitiveLayout(
      _primitivePlaceholder,
      2,
      2,
    ),
    WasmComponentPrimitiveValueType.s32 ||
    WasmComponentPrimitiveValueType.u32 ||
    WasmComponentPrimitiveValueType.f32 ||
    WasmComponentPrimitiveValueType.char => const _PrimitiveLayout(
      _primitivePlaceholder,
      4,
      4,
    ),
    WasmComponentPrimitiveValueType.s64 ||
    WasmComponentPrimitiveValueType.u64 ||
    WasmComponentPrimitiveValueType.f64 => const _PrimitiveLayout(
      _primitivePlaceholder,
      8,
      8,
    ),
    WasmComponentPrimitiveValueType.string ||
    WasmComponentPrimitiveValueType.errorContext => null,
  };
  return layout == null
      ? null
      : _PrimitiveLayout(primitive, layout.byteLength, layout.alignment);
}

const _primitivePlaceholder = WasmComponentPrimitiveValueType.u8;

int _recordByteLength(List<_FieldLayout> fields) {
  var size = 0;
  for (final field in fields) {
    size = _alignTo(size, field.layout.alignment);
    size += field.layout.byteLength;
  }
  return _alignTo(size, _maxAlignment(fields.map((field) => field.layout)));
}

int _maxAlignment(Iterable<_CanonicalValueLayout> layouts) {
  var result = 1;
  for (final layout in layouts) {
    result = _max(result, layout.alignment);
  }
  return result;
}

int _maxNullableAlignment(Iterable<_CanonicalValueLayout?> layouts) {
  var result = 1;
  for (final layout in layouts) {
    if (layout != null) {
      result = _max(result, layout.alignment);
    }
  }
  return result;
}

int _maxNullableByteLength(Iterable<_CanonicalValueLayout?> layouts) {
  var result = 0;
  for (final layout in layouts) {
    if (layout != null) {
      result = _max(result, layout.byteLength);
    }
  }
  return result;
}

int _discriminantByteLengthFor(int caseCount) {
  if (caseCount <= 0) {
    throw StateError('WASI component variants need at least one case.');
  }
  if (caseCount <= 0x100) {
    return 1;
  }
  if (caseCount <= 0x10000) {
    return 2;
  }
  return 4;
}

int _flagsByteLength(int labelCount) {
  if (labelCount <= 0) {
    throw StateError('WASI component flags need at least one label.');
  }
  if (labelCount <= 8) {
    return 1;
  }
  if (labelCount <= 16) {
    return 2;
  }
  return 4;
}

Object _readPrimitive(
  ByteData data,
  int offset,
  WasmComponentPrimitiveValueType primitive,
) {
  return switch (primitive) {
    WasmComponentPrimitiveValueType.boolean => _readCanonicalBool(data, offset),
    WasmComponentPrimitiveValueType.s8 => data.getInt8(offset),
    WasmComponentPrimitiveValueType.u8 => data.getUint8(offset),
    WasmComponentPrimitiveValueType.s16 => data.getInt16(offset, Endian.little),
    WasmComponentPrimitiveValueType.u16 => data.getUint16(
      offset,
      Endian.little,
    ),
    WasmComponentPrimitiveValueType.s32 => data.getInt32(offset, Endian.little),
    WasmComponentPrimitiveValueType.u32 => data.getUint32(
      offset,
      Endian.little,
    ),
    WasmComponentPrimitiveValueType.s64 => data.getInt64(offset, Endian.little),
    WasmComponentPrimitiveValueType.u64 => data.getUint64(
      offset,
      Endian.little,
    ),
    WasmComponentPrimitiveValueType.f32 => data.getFloat32(
      offset,
      Endian.little,
    ),
    WasmComponentPrimitiveValueType.f64 => data.getFloat64(
      offset,
      Endian.little,
    ),
    WasmComponentPrimitiveValueType.char => _readCanonicalChar(data, offset),
    WasmComponentPrimitiveValueType.string ||
    WasmComponentPrimitiveValueType.errorContext => throw StateError(
      'Unsupported fixed-size primitive read: ${primitive.name}.',
    ),
  };
}

void _writePrimitive(
  ByteData data,
  int offset,
  WasmComponentPrimitiveValueType primitive,
  Object? value,
) {
  switch (primitive) {
    case WasmComponentPrimitiveValueType.boolean:
      data.setUint8(offset, (value as bool) ? 1 : 0);
    case WasmComponentPrimitiveValueType.s8:
      data.setInt8(offset, value as int);
    case WasmComponentPrimitiveValueType.u8:
      data.setUint8(offset, value as int);
    case WasmComponentPrimitiveValueType.s16:
      data.setInt16(offset, value as int, Endian.little);
    case WasmComponentPrimitiveValueType.u16:
      data.setUint16(offset, value as int, Endian.little);
    case WasmComponentPrimitiveValueType.s32:
      data.setInt32(offset, value as int, Endian.little);
    case WasmComponentPrimitiveValueType.u32:
      data.setUint32(offset, value as int, Endian.little);
    case WasmComponentPrimitiveValueType.s64:
      data.setInt64(offset, value as int, Endian.little);
    case WasmComponentPrimitiveValueType.u64:
      data.setUint64(offset, value as int, Endian.little);
    case WasmComponentPrimitiveValueType.f32:
      data.setFloat32(offset, (value as num).toDouble(), Endian.little);
    case WasmComponentPrimitiveValueType.f64:
      data.setFloat64(offset, (value as num).toDouble(), Endian.little);
    case WasmComponentPrimitiveValueType.char:
      data.setUint32(offset, (value as String).runes.single, Endian.little);
    case WasmComponentPrimitiveValueType.string:
    case WasmComponentPrimitiveValueType.errorContext:
      throw StateError(
        'Unsupported fixed-size primitive write: ${primitive.name}.',
      );
  }
}

WasmComponentValueData _primitiveData(
  WasmComponentPrimitiveValueType primitive,
  Object? value,
  Uint8List rawBytes,
) {
  switch (primitive) {
    case WasmComponentPrimitiveValueType.boolean:
      return WasmComponentValueData(
        kind: WasmComponentValueDataKind.boolean,
        rawBytes: rawBytes,
        boolean: value as bool,
      );
    case WasmComponentPrimitiveValueType.s8:
    case WasmComponentPrimitiveValueType.u8:
    case WasmComponentPrimitiveValueType.s16:
    case WasmComponentPrimitiveValueType.u16:
    case WasmComponentPrimitiveValueType.s32:
    case WasmComponentPrimitiveValueType.u32:
    case WasmComponentPrimitiveValueType.s64:
    case WasmComponentPrimitiveValueType.u64:
      return WasmComponentValueData(
        kind: WasmComponentValueDataKind.integer,
        rawBytes: rawBytes,
        integer: value,
      );
    case WasmComponentPrimitiveValueType.f32:
    case WasmComponentPrimitiveValueType.f64:
      return WasmComponentValueData(
        kind: WasmComponentValueDataKind.floatingPoint,
        rawBytes: rawBytes,
        floatingPoint: (value as num).toDouble(),
      );
    case WasmComponentPrimitiveValueType.char:
      return WasmComponentValueData(
        kind: WasmComponentValueDataKind.string,
        rawBytes: rawBytes,
        string: value as String,
      );
    case WasmComponentPrimitiveValueType.string:
    case WasmComponentPrimitiveValueType.errorContext:
      throw StateError(
        'Unsupported fixed-size primitive data: ${primitive.name}.',
      );
  }
}

Object? _primitiveValueFromData(
  WasmComponentPrimitiveValueType primitive,
  WasmComponentValueData value,
) {
  switch (primitive) {
    case WasmComponentPrimitiveValueType.boolean:
      if (value.kind == WasmComponentValueDataKind.boolean &&
          value.boolean != null) {
        return value.boolean;
      }
    case WasmComponentPrimitiveValueType.s8:
    case WasmComponentPrimitiveValueType.u8:
    case WasmComponentPrimitiveValueType.s16:
    case WasmComponentPrimitiveValueType.u16:
    case WasmComponentPrimitiveValueType.s32:
    case WasmComponentPrimitiveValueType.u32:
    case WasmComponentPrimitiveValueType.s64:
    case WasmComponentPrimitiveValueType.u64:
      if (value.kind == WasmComponentValueDataKind.integer &&
          value.integer is int) {
        return value.integer;
      }
    case WasmComponentPrimitiveValueType.f32:
    case WasmComponentPrimitiveValueType.f64:
      if (value.kind == WasmComponentValueDataKind.floatingPoint &&
          value.floatingPoint != null) {
        return value.floatingPoint;
      }
    case WasmComponentPrimitiveValueType.char:
      if (value.kind == WasmComponentValueDataKind.string &&
          value.string != null) {
        return value.string;
      }
    case WasmComponentPrimitiveValueType.string:
    case WasmComponentPrimitiveValueType.errorContext:
      break;
  }
  throw StateError(
    'WASI component canonical value data does not match ${primitive.name}.',
  );
}

bool _primitiveValueMatches(
  WasmComponentPrimitiveValueType primitive,
  Object? value,
) {
  return switch (primitive) {
    WasmComponentPrimitiveValueType.boolean => value is bool,
    WasmComponentPrimitiveValueType.s8 =>
      value is int && value >= -0x80 && value <= 0x7f,
    WasmComponentPrimitiveValueType.u8 =>
      value is int && value >= 0 && value <= 0xff,
    WasmComponentPrimitiveValueType.s16 =>
      value is int && value >= -0x8000 && value <= 0x7fff,
    WasmComponentPrimitiveValueType.u16 =>
      value is int && value >= 0 && value <= 0xffff,
    WasmComponentPrimitiveValueType.s32 =>
      value is int && value >= -0x80000000 && value <= 0x7fffffff,
    WasmComponentPrimitiveValueType.u32 =>
      value is int && value >= 0 && value <= 0xffffffff,
    WasmComponentPrimitiveValueType.s64 =>
      value is int &&
          value >= -0x8000000000000000 &&
          value <= 0x7fffffffffffffff,
    WasmComponentPrimitiveValueType.u64 =>
      value is int && value >= 0 && value <= _u64Max,
    WasmComponentPrimitiveValueType.f32 ||
    WasmComponentPrimitiveValueType.f64 => value is num,
    WasmComponentPrimitiveValueType.char =>
      value is String && value.runes.length == 1,
    WasmComponentPrimitiveValueType.string => value is String,
    WasmComponentPrimitiveValueType.errorContext => false,
  };
}

bool _readCanonicalBool(ByteData data, int offset) {
  final value = data.getUint8(offset);
  if (value == 0) {
    return false;
  }
  return true;
}

String _readCanonicalChar(ByteData data, int offset) {
  final value = data.getUint32(offset, Endian.little);
  if (_isUnicodeScalar(value)) {
    return String.fromCharCode(value);
  }
  throw StateError('Canonical char memory value is not a Unicode scalar.');
}

bool _isUnicodeScalar(int value) {
  return value >= 0 && value <= 0x10ffff && (value < 0xd800 || value > 0xdfff);
}

int _readUnsigned(ByteData data, int pointer, int byteLength) {
  return switch (byteLength) {
    1 => data.getUint8(pointer),
    2 => data.getUint16(pointer, Endian.little),
    4 => data.getUint32(pointer, Endian.little),
    _ => throw StateError('Unsupported unsigned integer width: $byteLength.'),
  };
}

void _writeUnsigned(ByteData data, int pointer, int byteLength, int value) {
  switch (byteLength) {
    case 1:
      data.setUint8(pointer, value);
    case 2:
      data.setUint16(pointer, value, Endian.little);
    case 4:
      data.setUint32(pointer, value, Endian.little);
    default:
      throw StateError('Unsupported unsigned integer width: $byteLength.');
  }
}

void _checkMemoryRange(
  Uint8List bytes,
  int pointer,
  int byteLength,
  int alignment,
) {
  RangeError.checkNotNegative(pointer, 'pointer');
  if (alignment > 1 && pointer % alignment != 0) {
    throw StateError('pointer must be $alignment-byte aligned.');
  }
  if (pointer > bytes.length || byteLength > bytes.length - pointer) {
    throw RangeError.range(
      pointer + byteLength,
      0,
      bytes.length,
      'pointer + byteLength',
    );
  }
}

Uint8List _copyRawBytes(Uint8List bytes, int pointer, int byteLength) {
  return Uint8List.fromList(bytes.sublist(pointer, pointer + byteLength));
}

int _alignTo(int value, int alignment) {
  return ((value + alignment - 1) ~/ alignment) * alignment;
}

int _max(int a, int b) => a > b ? a : b;

final int _u64Max = (BigInt.one << 64).toInt() - 1;
