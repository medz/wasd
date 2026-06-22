import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../../wasm/memory.dart' as wasm;
import 'string_memory.dart';
import 'unicode_scalar.dart';

/// Canonical ABI memory codec for one component value type.
///
/// This is intentionally internal. It implements the Canonical ABI
/// `alignment`/`elem_size`/`load`/`store` path used by stream/future copy
/// buffers. Dynamic string/list values are represented by their canonical
/// `(ptr, len)` record and use [WASIComponentCanonicalRealloc] when storing
/// payloads.
/// Resource handle-table semantics and borrow tracking are reported as
/// unsupported instead of being approximated. Resource and error-context
/// handles can be represented as plain canonical `u32` values when the caller
/// supplies a handle-aware adapter plan. Owned resource handles can also use
/// that same canonical `u32` memory representation for stream/future element
/// copy buffers.
final class WASIComponentCanonicalValueMemoryCodec {
  const WASIComponentCanonicalValueMemoryCodec._(this._layout);

  /// Canonical memory codec for handle values represented as `u32`.
  static const canonicalU32Handle = WASIComponentCanonicalValueMemoryCodec._(
    _canonicalU32HandleLayout,
  );

  /// Builds a Canonical ABI memory codec for [type].
  ///
  /// Returns `null` when [type] contains component resource handles, borrows,
  /// nested stream/future values, or an invalid type index.
  static WASIComponentCanonicalValueMemoryCodec? fromValueType(
    WasmComponentValueType type,
    List<WasmComponentTypeDefinition> definitions,
  ) {
    final layout = _LayoutResolver(definitions).resolveValueType(type);
    return layout == null
        ? null
        : WASIComponentCanonicalValueMemoryCodec._(layout);
  }

  /// Builds a Canonical ABI memory codec for adapter value boundaries.
  ///
  /// Unlike [fromValueType], this treats `own` and `borrow` resource handles as
  /// canonical `u32` memory values. It does not validate resource ownership,
  /// drop, or borrow lifetime semantics; adapter hosts must keep those tied to
  /// the component resource table.
  static WASIComponentCanonicalValueMemoryCodec? fromAdapterValueType(
    WasmComponentValueType type,
    List<WasmComponentTypeDefinition> definitions,
  ) {
    final layout = _LayoutResolver(
      definitions,
      handleMode: _ResourceHandleMemoryMode.ownAndBorrow,
    ).resolveValueType(type);
    return layout == null
        ? null
        : WASIComponentCanonicalValueMemoryCodec._(layout);
  }

  /// Builds a Canonical ABI memory codec for stream/future element buffers.
  ///
  /// This treats owned resource handles as canonical `u32` values. Borrowed
  /// handles remain unsupported here because stream/future payload storage
  /// cannot extend a borrow lifetime through the byte codec.
  static WASIComponentCanonicalValueMemoryCodec? fromAsyncElementType(
    WasmComponentValueType type,
    List<WasmComponentTypeDefinition> definitions,
  ) {
    final layout = _LayoutResolver(
      definitions,
      handleMode: _ResourceHandleMemoryMode.ownOnly,
    ).resolveValueType(type);
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

  /// Whether storing this value may need a canonical realloc callback.
  bool get requiresRealloc => _layout.requiresRealloc;

  /// Loads one value from [memory] at [pointer].
  Object? load(
    wasm.Memory memory,
    int pointer, {
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
  }) {
    final bytes = Uint8List.view(memory.buffer);
    _checkMemoryRange(bytes, pointer, _layout.byteLength, _layout.alignment);
    return _layout.load(
      memory,
      ByteData.view(memory.buffer),
      bytes,
      pointer,
      stringEncoding,
    );
  }

  /// Loads one typed value from [memory] at [pointer].
  T loadAs<T>(
    wasm.Memory memory,
    int pointer,
    String name, {
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
  }) {
    final bytes = Uint8List.view(memory.buffer);
    _checkMemoryRange(bytes, pointer, _layout.byteLength, _layout.alignment);
    return _loadAs<T>(
      memory,
      ByteData.view(memory.buffer),
      bytes,
      pointer,
      name,
      stringEncoding,
    );
  }

  /// Loads [elementCount] contiguous values from [memory].
  List<Object?> loadMany(
    wasm.Memory memory,
    int pointer,
    int elementCount, {
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
  }) {
    RangeError.checkNotNegative(elementCount, 'elementCount');
    final bytes = Uint8List.view(memory.buffer);
    _checkMemoryRange(
      bytes,
      pointer,
      elementCount * _layout.byteLength,
      _layout.alignment,
    );
    final data = ByteData.view(memory.buffer);
    return List<Object?>.generate(
      elementCount,
      (index) => _layout.load(
        memory,
        data,
        bytes,
        pointer + index * _layout.byteLength,
        stringEncoding,
      ),
      growable: false,
    );
  }

  /// Loads [elementCount] typed contiguous values from [memory].
  List<T> loadManyAs<T>(
    wasm.Memory memory,
    int pointer,
    int elementCount,
    String name, {
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
  }) {
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
      (index) => _loadAs<T>(
        memory,
        data,
        bytes,
        pointer + index * _layout.byteLength,
        name,
        stringEncoding,
      ),
      growable: false,
    );
  }

  /// Stores one [value] into [memory] at [pointer].
  void store(
    wasm.Memory memory,
    int pointer,
    Object? value, {
    WASIComponentCanonicalRealloc? realloc,
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
  }) {
    final bytes = Uint8List.view(memory.buffer);
    _checkMemoryRange(bytes, pointer, _layout.byteLength, _layout.alignment);
    _layout.store(
      memory,
      ByteData.view(memory.buffer),
      pointer,
      value,
      realloc,
      stringEncoding,
    );
  }

  /// Stores contiguous [values] into [memory].
  void storeMany(
    wasm.Memory memory,
    int pointer,
    List<Object?> values, {
    WASIComponentCanonicalRealloc? realloc,
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
  }) {
    final bytes = Uint8List.view(memory.buffer);
    _checkMemoryRange(
      bytes,
      pointer,
      values.length * _layout.byteLength,
      _layout.alignment,
    );
    final data = ByteData.view(memory.buffer);
    for (var i = 0; i < values.length; i++) {
      _layout.store(
        memory,
        data,
        pointer + i * _layout.byteLength,
        values[i],
        realloc,
        stringEncoding,
      );
    }
  }

  /// Loads a dynamic list value from a flat Canonical ABI `(ptr, len)` pair.
  WasmComponentValueData loadFlatList(
    wasm.Memory memory,
    int pointer,
    int length, {
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
  }) {
    final layout = _layout;
    if (layout is! _ListLayout) {
      throw StateError('WASI component canonical value expected list layout.');
    }
    final bytes = Uint8List.view(memory.buffer);
    return layout.loadFlat(
      memory,
      ByteData.view(memory.buffer),
      bytes,
      pointer,
      length,
      stringEncoding,
    );
  }

  /// Stores a dynamic list value and returns its flat `(ptr, len)` pair.
  ({int pointer, int length}) storeFlatList(
    wasm.Memory memory,
    Object? value, {
    WASIComponentCanonicalRealloc? realloc,
    WASIComponentCanonicalStringEncoding stringEncoding =
        WASIComponentCanonicalStringEncoding.utf8,
  }) {
    final layout = _layout;
    if (layout is! _ListLayout) {
      throw StateError('WASI component canonical value expected list layout.');
    }
    if (value is! WasmComponentValueData ||
        value.kind != WasmComponentValueDataKind.list) {
      throw StateError('WASI component canonical value expected list data.');
    }
    validate('list', value);
    return layout.storeFlat(
      memory,
      ByteData.view(memory.buffer),
      value,
      realloc,
      stringEncoding,
    );
  }

  /// Validates [value] against this canonical value shape.
  void validate(String name, Object? value) {
    _layout.validate(name, value);
  }

  T _loadAs<T>(
    wasm.Memory memory,
    ByteData data,
    Uint8List bytes,
    int pointer,
    String name,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    final value = _layout.load(memory, data, bytes, pointer, stringEncoding);
    // Layout loads either produce the canonical shape or throw while decoding.
    if (value is T) {
      return value;
    }
    throw StateError('WASI component canonical value $name expected $T.');
  }
}

final class _LayoutResolver {
  _LayoutResolver(
    this.definitions, {
    this.handleMode = _ResourceHandleMemoryMode.none,
  });

  final List<WasmComponentTypeDefinition> definitions;
  final _ResourceHandleMemoryMode handleMode;
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
      case WasmComponentDefinedValueTypeKind.list:
        final elementType = type.elementType;
        if (elementType == null) {
          return null;
        }
        final elementLayout = resolveValueType(elementType);
        return elementLayout == null ? null : _ListLayout(elementLayout);
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
      case WasmComponentDefinedValueTypeKind.own:
      case WasmComponentDefinedValueTypeKind.borrow:
        final typeIndex = type.typeIndex;
        if (!_allowsResourceHandle(type.kind) ||
            typeIndex == null ||
            typeIndex < 0 ||
            typeIndex >= definitions.length ||
            definitions[typeIndex].kind != WasmComponentTypeKind.resource) {
          return null;
        }
        return _canonicalU32HandleLayout;
      case WasmComponentDefinedValueTypeKind.stream:
      case WasmComponentDefinedValueTypeKind.future:
        return null;
    }
  }

  bool _allowsResourceHandle(WasmComponentDefinedValueTypeKind kind) {
    return switch (handleMode) {
      _ResourceHandleMemoryMode.none => false,
      _ResourceHandleMemoryMode.ownOnly =>
        kind == WasmComponentDefinedValueTypeKind.own,
      _ResourceHandleMemoryMode.ownAndBorrow =>
        kind == WasmComponentDefinedValueTypeKind.own ||
            kind == WasmComponentDefinedValueTypeKind.borrow,
    };
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

enum _ResourceHandleMemoryMode { none, ownOnly, ownAndBorrow }

const _canonicalU32HandleLayout = _PrimitiveLayout(
  WasmComponentPrimitiveValueType.u32,
  4,
  4,
);

abstract final class _CanonicalValueLayout {
  const _CanonicalValueLayout();

  int get byteLength;
  int get alignment;
  WasmComponentPrimitiveValueType? get primitive => null;
  bool get requiresRealloc => false;

  Object? load(
    wasm.Memory memory,
    ByteData data,
    Uint8List bytes,
    int pointer,
    WASIComponentCanonicalStringEncoding stringEncoding,
  );
  WasmComponentValueData loadData(
    wasm.Memory memory,
    ByteData data,
    Uint8List bytes,
    int pointer,
    WASIComponentCanonicalStringEncoding stringEncoding,
  );
  void store(
    wasm.Memory memory,
    ByteData data,
    int pointer,
    Object? value,
    WASIComponentCanonicalRealloc? realloc,
    WASIComponentCanonicalStringEncoding stringEncoding,
  );
  void storeData(
    wasm.Memory memory,
    ByteData data,
    int pointer,
    WasmComponentValueData value,
    WASIComponentCanonicalRealloc? realloc,
    WASIComponentCanonicalStringEncoding stringEncoding,
  );
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
  Object load(
    wasm.Memory memory,
    ByteData data,
    Uint8List bytes,
    int pointer,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    return _readPrimitive(data, pointer, primitive);
  }

  @override
  WasmComponentValueData loadData(
    wasm.Memory memory,
    ByteData data,
    Uint8List bytes,
    int pointer,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    final value = load(memory, data, bytes, pointer, stringEncoding);
    return _primitiveData(
      primitive,
      value,
      _copyRawBytes(bytes, pointer, byteLength),
    );
  }

  @override
  void store(
    wasm.Memory memory,
    ByteData data,
    int pointer,
    Object? value,
    WASIComponentCanonicalRealloc? realloc,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    _writePrimitive(
      data,
      pointer,
      primitive,
      _primitiveValue(primitive, value),
    );
  }

  @override
  void storeData(
    wasm.Memory memory,
    ByteData data,
    int pointer,
    WasmComponentValueData value,
    WASIComponentCanonicalRealloc? realloc,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    store(
      memory,
      data,
      pointer,
      _primitiveValueFromData(primitive, value),
      realloc,
      stringEncoding,
    );
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

final class _StringLayout extends _CanonicalValueLayout {
  const _StringLayout();

  @override
  int get byteLength => 8;

  @override
  int get alignment => 4;

  @override
  WasmComponentPrimitiveValueType get primitive =>
      WasmComponentPrimitiveValueType.string;

  @override
  bool get requiresRealloc => true;

  @override
  String load(
    wasm.Memory memory,
    ByteData data,
    Uint8List bytes,
    int pointer,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    return readWASIComponentCanonicalStringRecord(
      memory,
      pointer,
      stringEncoding,
    );
  }

  @override
  WasmComponentValueData loadData(
    wasm.Memory memory,
    ByteData data,
    Uint8List bytes,
    int pointer,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    return WasmComponentValueData(
      kind: WasmComponentValueDataKind.string,
      rawBytes: _copyRawBytes(bytes, pointer, byteLength),
      string: load(memory, data, bytes, pointer, stringEncoding),
    );
  }

  @override
  void store(
    wasm.Memory memory,
    ByteData data,
    int pointer,
    Object? value,
    WASIComponentCanonicalRealloc? realloc,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    final string = _stringValue(value);
    final memoryString = writeWASIComponentCanonicalString(
      memory,
      _requireRealloc(realloc, 'string'),
      string,
      stringEncoding,
    );
    writeWASIComponentMemoryStringRecord(memory, pointer, memoryString);
  }

  @override
  void storeData(
    wasm.Memory memory,
    ByteData data,
    int pointer,
    WasmComponentValueData value,
    WASIComponentCanonicalRealloc? realloc,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    store(memory, data, pointer, value, realloc, stringEncoding);
  }

  @override
  void validate(String name, Object? value) {
    if (value is String) {
      return;
    }
    if (value is WasmComponentValueData &&
        value.kind == WasmComponentValueDataKind.string &&
        value.string != null) {
      return;
    }
    throw StateError(
      'WASI component canonical value $name expected string data.',
    );
  }

  String _stringValue(Object? value) {
    if (value is String) {
      return value;
    }
    if (value is WasmComponentValueData &&
        value.kind == WasmComponentValueDataKind.string &&
        value.string != null) {
      return value.string!;
    }
    throw StateError('WASI component canonical value expected string data.');
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
  Object load(
    wasm.Memory memory,
    ByteData data,
    Uint8List bytes,
    int pointer,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    return loadData(memory, data, bytes, pointer, stringEncoding);
  }

  @override
  WasmComponentValueData loadData(
    wasm.Memory memory,
    ByteData data,
    Uint8List bytes,
    int pointer,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    var cursor = pointer;
    final items = List<WasmComponentValueData>.generate(fields.length, (index) {
      final field = fields[index];
      cursor = _alignTo(cursor, field.layout.alignment);
      final item = field.layout.loadData(
        memory,
        data,
        bytes,
        cursor,
        stringEncoding,
      );
      cursor += field.layout.byteLength;
      return item;
    }, growable: false);
    return WasmComponentValueData(
      kind: kind,
      rawBytes: _copyRawBytes(bytes, pointer, byteLength),
      items: List<WasmComponentValueData>.unmodifiable(items),
    );
  }

  @override
  void store(
    wasm.Memory memory,
    ByteData data,
    int pointer,
    Object? value,
    WASIComponentCanonicalRealloc? realloc,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    if (value is! WasmComponentValueData || value.kind != kind) {
      throw StateError(
        'WASI component canonical value expected ${kind.name} data.',
      );
    }
    storeData(memory, data, pointer, value, realloc, stringEncoding);
  }

  @override
  void storeData(
    wasm.Memory memory,
    ByteData data,
    int pointer,
    WasmComponentValueData value,
    WASIComponentCanonicalRealloc? realloc,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
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
      field.layout.storeData(
        memory,
        data,
        cursor,
        value.items[i],
        realloc,
        stringEncoding,
      );
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
  bool get requiresRealloc => elementLayout.requiresRealloc;

  @override
  Object load(
    wasm.Memory memory,
    ByteData data,
    Uint8List bytes,
    int pointer,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    return loadData(memory, data, bytes, pointer, stringEncoding);
  }

  @override
  WasmComponentValueData loadData(
    wasm.Memory memory,
    ByteData data,
    Uint8List bytes,
    int pointer,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    final items = List<WasmComponentValueData>.generate(
      length,
      (index) => elementLayout.loadData(
        memory,
        data,
        bytes,
        pointer + index * elementLayout.byteLength,
        stringEncoding,
      ),
      growable: false,
    );
    return WasmComponentValueData(
      kind: WasmComponentValueDataKind.fixedList,
      rawBytes: _copyRawBytes(bytes, pointer, byteLength),
      items: List<WasmComponentValueData>.unmodifiable(items),
    );
  }

  @override
  void store(
    wasm.Memory memory,
    ByteData data,
    int pointer,
    Object? value,
    WASIComponentCanonicalRealloc? realloc,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    if (value is! WasmComponentValueData ||
        value.kind != WasmComponentValueDataKind.fixedList) {
      throw StateError(
        'WASI component canonical value expected fixedList data.',
      );
    }
    storeData(memory, data, pointer, value, realloc, stringEncoding);
  }

  @override
  void storeData(
    wasm.Memory memory,
    ByteData data,
    int pointer,
    WasmComponentValueData value,
    WASIComponentCanonicalRealloc? realloc,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    if (value.kind != WasmComponentValueDataKind.fixedList ||
        value.items.length != length) {
      throw StateError(
        'WASI component canonical value expected fixedList with $length items.',
      );
    }
    for (var i = 0; i < length; i++) {
      elementLayout.storeData(
        memory,
        data,
        pointer + i * elementLayout.byteLength,
        value.items[i],
        realloc,
        stringEncoding,
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

final class _ListLayout extends _CanonicalValueLayout {
  const _ListLayout(this.elementLayout);

  final _CanonicalValueLayout elementLayout;

  @override
  int get byteLength => 8;

  @override
  int get alignment => 4;

  @override
  bool get requiresRealloc => true;

  @override
  Object load(
    wasm.Memory memory,
    ByteData data,
    Uint8List bytes,
    int pointer,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    return loadData(memory, data, bytes, pointer, stringEncoding);
  }

  @override
  WasmComponentValueData loadData(
    wasm.Memory memory,
    ByteData data,
    Uint8List bytes,
    int pointer,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    final payloadPointer = data.getUint32(pointer, Endian.little);
    final length = data.getUint32(pointer + 4, Endian.little);
    return loadFlat(
      memory,
      data,
      bytes,
      payloadPointer,
      length,
      stringEncoding,
      rawBytes: _copyRawBytes(bytes, pointer, byteLength),
    );
  }

  WasmComponentValueData loadFlat(
    wasm.Memory memory,
    ByteData data,
    Uint8List bytes,
    int payloadPointer,
    int length,
    WASIComponentCanonicalStringEncoding stringEncoding, {
    Uint8List? rawBytes,
  }) {
    _checkU32(length, 'list length');
    final payloadByteLength = _listPayloadByteLength(elementLayout, length);
    if (length > 0) {
      _checkMemoryRange(
        bytes,
        payloadPointer,
        payloadByteLength,
        elementLayout.alignment,
      );
    }
    final items = List<WasmComponentValueData>.generate(
      length,
      (index) => elementLayout.loadData(
        memory,
        data,
        bytes,
        payloadPointer + index * elementLayout.byteLength,
        stringEncoding,
      ),
      growable: false,
    );
    return WasmComponentValueData(
      kind: WasmComponentValueDataKind.list,
      rawBytes: rawBytes ?? Uint8List(0),
      items: List<WasmComponentValueData>.unmodifiable(items),
    );
  }

  @override
  void store(
    wasm.Memory memory,
    ByteData data,
    int pointer,
    Object? value,
    WASIComponentCanonicalRealloc? realloc,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    if (value is! WasmComponentValueData ||
        value.kind != WasmComponentValueDataKind.list) {
      throw StateError('WASI component canonical value expected list data.');
    }
    storeData(memory, data, pointer, value, realloc, stringEncoding);
  }

  @override
  void storeData(
    wasm.Memory memory,
    ByteData data,
    int pointer,
    WasmComponentValueData value,
    WASIComponentCanonicalRealloc? realloc,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    if (value.kind != WasmComponentValueDataKind.list) {
      throw StateError('WASI component canonical value expected list data.');
    }
    final payloadPointer = _storeListPayload(
      memory,
      data,
      value,
      realloc,
      stringEncoding,
    );
    data.setUint32(pointer, payloadPointer, Endian.little);
    data.setUint32(pointer + 4, value.items.length, Endian.little);
  }

  ({int pointer, int length}) storeFlat(
    wasm.Memory memory,
    ByteData data,
    WasmComponentValueData value,
    WASIComponentCanonicalRealloc? realloc,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    if (value.kind != WasmComponentValueDataKind.list) {
      throw StateError('WASI component canonical value expected list data.');
    }
    return (
      pointer: _storeListPayload(memory, data, value, realloc, stringEncoding),
      length: value.items.length,
    );
  }

  @override
  void validate(String name, Object? value) {
    if (value is WasmComponentValueData &&
        value.kind == WasmComponentValueDataKind.list) {
      for (var i = 0; i < value.items.length; i++) {
        elementLayout.validate('$name[$i]', value.items[i]);
      }
      return;
    }
    throw StateError(
      'WASI component canonical value $name expected list data.',
    );
  }

  int _storeListPayload(
    wasm.Memory memory,
    ByteData data,
    WasmComponentValueData value,
    WASIComponentCanonicalRealloc? realloc,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    _checkU32(value.items.length, 'list length');
    if (value.items.isEmpty) {
      return 0;
    }
    final canonicalRealloc = _requireRealloc(realloc, 'list');
    final payloadByteLength = _listPayloadByteLength(
      elementLayout,
      value.items.length,
    );
    final payloadPointer = canonicalRealloc(
      0,
      0,
      elementLayout.alignment,
      payloadByteLength,
    );
    _checkDataRange(
      data,
      payloadPointer,
      payloadByteLength,
      elementLayout.alignment,
    );
    for (var i = 0; i < value.items.length; i++) {
      elementLayout.storeData(
        memory,
        data,
        payloadPointer + i * elementLayout.byteLength,
        value.items[i],
        canonicalRealloc,
        stringEncoding,
      );
    }
    return payloadPointer;
  }
}

int _listPayloadByteLength(_CanonicalValueLayout elementLayout, int length) {
  _checkU32(length, 'list length');
  final byteLength = elementLayout.byteLength * length;
  if (length > 0 && byteLength ~/ length != elementLayout.byteLength) {
    throw RangeError('WASI component list payload byte length overflow.');
  }
  return byteLength;
}

final class _FlagsLayout extends _CanonicalValueLayout {
  _FlagsLayout(this.labels) : byteLength = _flagsByteLength(labels.length);

  final List<String> labels;

  @override
  final int byteLength;

  @override
  int get alignment => byteLength;

  @override
  Object load(
    wasm.Memory memory,
    ByteData data,
    Uint8List bytes,
    int pointer,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    return loadData(memory, data, bytes, pointer, stringEncoding);
  }

  @override
  WasmComponentValueData loadData(
    wasm.Memory memory,
    ByteData data,
    Uint8List bytes,
    int pointer,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
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
  void store(
    wasm.Memory memory,
    ByteData data,
    int pointer,
    Object? value,
    WASIComponentCanonicalRealloc? realloc,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    if (value is! WasmComponentValueData ||
        value.kind != WasmComponentValueDataKind.flags) {
      throw StateError('WASI component canonical value expected flags data.');
    }
    storeData(memory, data, pointer, value, realloc, stringEncoding);
  }

  @override
  void storeData(
    wasm.Memory memory,
    ByteData data,
    int pointer,
    WasmComponentValueData value,
    WASIComponentCanonicalRealloc? realloc,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    validate('flags', value);
    var bits = 0;
    for (final label in value.labels) {
      bits |= 1 << labels.indexOf(label);
    }
    _writeUnsigned(data, pointer, byteLength, bits);
  }

  @override
  void validate(String name, Object? value) {
    if (value is WasmComponentValueData &&
        value.kind == WasmComponentValueDataKind.flags) {
      final seen = <String>{};
      for (final label in value.labels) {
        if (!labels.contains(label)) {
          throw StateError(
            'WASI component canonical value $name has unknown flag $label.',
          );
        }
        if (!seen.add(label)) {
          throw StateError(
            'WASI component canonical value $name has duplicate flag $label.',
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
  Object load(
    wasm.Memory memory,
    ByteData data,
    Uint8List bytes,
    int pointer,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    return loadData(memory, data, bytes, pointer, stringEncoding);
  }

  @override
  WasmComponentValueData loadData(
    wasm.Memory memory,
    ByteData data,
    Uint8List bytes,
    int pointer,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    final index = _readUnsigned(data, pointer, _discriminantByteLength);
    if (index >= cases.length) {
      throw StateError('Invalid WASI component variant case index: $index.');
    }
    final case_ = cases[index];
    final payloadOffset = _alignTo(
      pointer + _discriminantByteLength,
      _maxCaseAlignment,
    );
    final associated = case_.layout?.loadData(
      memory,
      data,
      bytes,
      payloadOffset,
      stringEncoding,
    );
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
  void store(
    wasm.Memory memory,
    ByteData data,
    int pointer,
    Object? value,
    WASIComponentCanonicalRealloc? realloc,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    if (value is! WasmComponentValueData || value.kind != kind) {
      throw StateError(
        'WASI component canonical value expected ${kind.name} data.',
      );
    }
    storeData(memory, data, pointer, value, realloc, stringEncoding);
  }

  @override
  void storeData(
    wasm.Memory memory,
    ByteData data,
    int pointer,
    WasmComponentValueData value,
    WASIComponentCanonicalRealloc? realloc,
    WASIComponentCanonicalStringEncoding stringEncoding,
  ) {
    if (value.kind != kind) {
      throw StateError(
        'WASI component canonical value expected ${kind.name} data.',
      );
    }
    final index = _caseIndex(value);
    final layout = cases[index].layout;
    final associated = value.associatedValue;
    if (layout == null) {
      if (associated != null) {
        throw StateError(
          'WASI component canonical value ${cases[index].label} must not have '
          'payload.',
        );
      }
      _writeUnsigned(data, pointer, _discriminantByteLength, index);
      return;
    }

    final payload = associated;
    if (payload == null) {
      throw StateError(
        'WASI component canonical value ${cases[index].label} needs payload.',
      );
    }
    layout.validate('${kind.name}.${cases[index].label}', payload);
    _writeUnsigned(data, pointer, _discriminantByteLength, index);
    final payloadOffset = _alignTo(
      pointer + _discriminantByteLength,
      _maxCaseAlignment,
    );
    layout.storeData(
      memory,
      data,
      payloadOffset,
      payload,
      realloc,
      stringEncoding,
    );
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
    int? selectedIndex;

    void selectIndex(int index) {
      if (selectedIndex != null && selectedIndex != index) {
        throw StateError(
          'Conflicting WASI component ${kind.name} case selectors.',
        );
      }
      selectedIndex = index;
    }

    final index = value.index;
    if (index != null) {
      if (index < 0 || index >= cases.length) {
        throw StateError('Invalid WASI component variant case index: $index.');
      }
      selectIndex(index);
    }
    final label = value.label;
    if (label != null) {
      final index = cases.indexWhere((case_) => case_.label == label);
      if (index < 0) {
        throw StateError(
          'Unknown WASI component ${kind.name} case label: $label.',
        );
      }
      selectIndex(index);
    }
    if (kind == WasmComponentValueDataKind.option && value.isSome != null) {
      selectIndex(value.isSome! ? 1 : 0);
    }
    if (kind == WasmComponentValueDataKind.result && value.isOk != null) {
      selectIndex(value.isOk! ? 0 : 1);
    }
    final resolvedIndex = selectedIndex;
    if (resolvedIndex != null) {
      return resolvedIndex;
    }
    throw StateError('WASI component canonical variant value needs a case.');
  }
}

_CanonicalValueLayout? _primitiveLayout(
  WasmComponentPrimitiveValueType primitive,
) {
  switch (primitive) {
    case WasmComponentPrimitiveValueType.boolean:
    case WasmComponentPrimitiveValueType.s8:
    case WasmComponentPrimitiveValueType.u8:
      return _PrimitiveLayout(primitive, 1, 1);
    case WasmComponentPrimitiveValueType.s16:
    case WasmComponentPrimitiveValueType.u16:
      return _PrimitiveLayout(primitive, 2, 2);
    case WasmComponentPrimitiveValueType.s32:
    case WasmComponentPrimitiveValueType.u32:
    case WasmComponentPrimitiveValueType.f32:
    case WasmComponentPrimitiveValueType.char:
    case WasmComponentPrimitiveValueType.errorContext:
      return _PrimitiveLayout(primitive, 4, 4);
    case WasmComponentPrimitiveValueType.s64:
    case WasmComponentPrimitiveValueType.u64:
    case WasmComponentPrimitiveValueType.f64:
      return _PrimitiveLayout(primitive, 8, 8);
    case WasmComponentPrimitiveValueType.string:
      return const _StringLayout();
  }
}

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
    WasmComponentPrimitiveValueType.errorContext => data.getUint32(
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
    WasmComponentPrimitiveValueType.string => throw StateError(
      'Unsupported canonical primitive read: ${primitive.name}.',
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
    case WasmComponentPrimitiveValueType.errorContext:
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
      final scalar = singleWASIComponentUnicodeScalar(value);
      if (scalar == null) {
        throw StateError(
          'WASI component canonical value expected Unicode scalar char.',
        );
      }
      data.setUint32(offset, scalar, Endian.little);
    case WasmComponentPrimitiveValueType.string:
      throw StateError(
        'Unsupported canonical primitive write: ${primitive.name}.',
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
    case WasmComponentPrimitiveValueType.errorContext:
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
      throw StateError(
        'Unsupported canonical primitive data: ${primitive.name}.',
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
    case WasmComponentPrimitiveValueType.errorContext:
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
      break;
  }
  throw StateError(
    'WASI component canonical value data does not match ${primitive.name}.',
  );
}

Object? _primitiveValue(
  WasmComponentPrimitiveValueType primitive,
  Object? value,
) {
  final candidate = value is WasmComponentValueData
      ? _primitiveValueFromData(primitive, value)
      : value;
  if (_primitiveValueMatches(primitive, candidate)) {
    return candidate;
  }
  throw StateError(
    'WASI component canonical value expected ${primitive.name}.',
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
      singleWASIComponentUnicodeScalar(value) != null,
    WasmComponentPrimitiveValueType.string => value is String,
    WasmComponentPrimitiveValueType.errorContext =>
      value is int && value >= 0 && value <= 0xffffffff,
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
  if (isWASIComponentUnicodeScalar(value)) {
    return String.fromCharCode(value);
  }
  throw StateError('Canonical char memory value is not a Unicode scalar.');
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

void _checkDataRange(
  ByteData data,
  int pointer,
  int byteLength,
  int alignment,
) {
  RangeError.checkNotNegative(pointer, 'pointer');
  if (alignment > 1 && pointer % alignment != 0) {
    throw StateError('pointer must be $alignment-byte aligned.');
  }
  if (pointer > data.lengthInBytes ||
      byteLength > data.lengthInBytes - pointer) {
    throw RangeError.range(
      pointer + byteLength,
      0,
      data.lengthInBytes,
      'pointer + byteLength',
    );
  }
}

void _checkU32(int value, String name) {
  RangeError.checkValueInInterval(value, 0, 0xffffffff, name);
}

WASIComponentCanonicalRealloc _requireRealloc(
  WASIComponentCanonicalRealloc? realloc,
  String name,
) {
  if (realloc != null) {
    return realloc;
  }
  throw UnsupportedError(
    'WASI component canonical value $name requires a realloc callback.',
  );
}

Uint8List _copyRawBytes(Uint8List bytes, int pointer, int byteLength) {
  return Uint8List(byteLength)..setRange(0, byteLength, bytes, pointer);
}

int _alignTo(int value, int alignment) {
  return ((value + alignment - 1) ~/ alignment) * alignment;
}

int _max(int a, int b) => a > b ? a : b;

final int _u64Max = (BigInt.one << 64).toInt() - 1;
