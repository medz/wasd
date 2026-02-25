import 'dart:typed_data';

import 'byte_reader.dart';
import 'features.dart';
import 'int64.dart';
import 'imports.dart';
import 'memory.dart';
import 'module.dart';
import 'opcode.dart';
import 'predecode.dart';
import 'runtime_function.dart';
import 'runtime_global.dart';
import 'table.dart';
import 'validator.dart';
import 'value.dart';
import 'vm.dart';

final class WasmInstance {
  WasmInstance._({
    required this.module,
    required this.memories,
    required this.tables,
    required this.functions,
    required this.globals,
    required List<bool> memory64ByIndex,
    required List<bool> table64ByIndex,
    required List<Uint8List?> dataSegments,
    required List<List<int?>?> elementSegments,
    required List<int> elementSegmentRefTypeCodes,
    required Map<String, int> functionExports,
    required Map<String, int> globalExports,
    required Map<String, WasmMemory> memoryExports,
    required Map<String, WasmTable> tableExports,
  }) : memory = memories.isEmpty ? null : memories.first,
       _functionExports = functionExports,
       _globalExports = globalExports,
       _memoryExports = memoryExports,
       _tableExports = tableExports,
       _vm = WasmVm(
         functions: functions,
         types: module.types,
         tables: tables,
         memories: memories,
         globals: globals,
         memory64ByIndex: memory64ByIndex,
         table64ByIndex: table64ByIndex,
         dataSegments: dataSegments,
         elementSegments: elementSegments,
         elementSegmentRefTypeCodes: elementSegmentRefTypeCodes,
       );

  final WasmModule module;
  final WasmMemory? memory;
  final List<WasmMemory> memories;
  final List<WasmTable> tables;
  final List<RuntimeFunction> functions;
  final List<RuntimeGlobal> globals;

  final Map<String, int> _functionExports;
  final Map<String, int> _globalExports;
  final Map<String, WasmMemory> _memoryExports;
  final Map<String, WasmTable> _tableExports;
  final WasmVm _vm;

  factory WasmInstance.fromBytes(
    Uint8List wasmBytes, {
    WasmImports imports = const WasmImports(),
    WasmFeatureSet features = const WasmFeatureSet(),
  }) {
    return WasmInstance.fromModule(
      WasmModule.decode(wasmBytes, features: features),
      imports: imports,
      features: features,
    );
  }

  factory WasmInstance.fromModule(
    WasmModule module, {
    WasmImports imports = const WasmImports(),
    WasmFeatureSet features = const WasmFeatureSet(),
  }) {
    WasmValidator.validateModule(module, features: features);

    final functions = <RuntimeFunction>[];
    final globals = <RuntimeGlobal>[];
    final tables = <WasmTable>[];
    final memories = <WasmMemory>[];

    for (final import in module.imports) {
      switch (import.kind) {
        case WasmImportKind.function:
        case WasmImportKind.exactFunction:
          final typeIndex = import.functionTypeIndex;
          if (typeIndex == null ||
              typeIndex >= module.types.length ||
              !module.types[typeIndex].isFunctionType) {
            throw FormatException(
              'Invalid function import type index: $typeIndex',
            );
          }

          final callback = imports.functions[import.key];
          final asyncCallback = imports.asyncFunctions[import.key];
          if (callback == null && asyncCallback == null) {
            throw StateError('Missing function import `${import.key}`.');
          }
          if (callback == null && asyncCallback != null) {
            throw UnsupportedError(
              'Async-only host import `${import.key}` is not available in the '
              'synchronous VM pipeline yet. Provide a sync callback for now.',
            );
          }

          functions.add(
            HostRuntimeFunction(
              type: module.types[typeIndex],
              declaredTypeIndex: typeIndex,
              runtimeTypeDepth:
                  imports.functionTypeDepths[import.key] ??
                  _functionTypeDepth(module, typeIndex),
              callback: callback!,
            ),
          );

        case WasmImportKind.table:
          final expected = import.tableType;
          if (expected == null) {
            throw FormatException('Malformed table import `${import.key}`.');
          }

          final importedTable = imports.tables[import.key];
          if (importedTable == null) {
            throw StateError('Missing table import `${import.key}`.');
          }

          if (importedTable.refType != expected.refType) {
            throw StateError(
              'Imported table `${import.key}` ref type mismatch: '
              'expected=${expected.refType} actual=${importedTable.refType}.',
            );
          }
          if (importedTable.isTable64 != expected.isTable64) {
            throw StateError(
              'Imported table `${import.key}` index type mismatch: '
              'expected table64=${expected.isTable64} '
              'actual=${importedTable.isTable64}.',
            );
          }

          if (importedTable.length < expected.min) {
            throw StateError(
              'Imported table `${import.key}` has length ${importedTable.length} '
              'but requires at least ${expected.min}.',
            );
          }

          final expectedMax = expected.max;
          if (expectedMax != null) {
            final importedMax = importedTable.max;
            if (importedMax == null || importedMax > expectedMax) {
              throw StateError(
                'Imported table `${import.key}` max mismatch: '
                'expected <= $expectedMax, actual=${importedMax ?? 'unbounded'}.',
              );
            }
          }

          tables.add(importedTable);

        case WasmImportKind.memory:
          final importedMemory = imports.memories[import.key];
          if (importedMemory == null) {
            throw StateError('Missing memory import `${import.key}`.');
          }

          final expected = import.memoryType;
          if (expected == null) {
            throw FormatException('Malformed memory import `${import.key}`.');
          }
          _validateSupportedMemoryType(
            expected,
            features: features,
            context: 'memory import `${import.key}`',
          );
          final expectedPageSize = 1 << expected.pageSizeLog2;

          if (importedMemory.shared != expected.shared) {
            throw StateError(
              'Imported memory `${import.key}` shared flag mismatch: '
              'expected=${expected.shared} actual=${importedMemory.shared}.',
            );
          }
          if (importedMemory.pageSizeBytes != expectedPageSize) {
            throw StateError(
              'Imported memory `${import.key}` memory types incompatible: '
              'expected pageSize=$expectedPageSize '
              'actual=${importedMemory.pageSizeBytes}.',
            );
          }

          if (importedMemory.minPages < expected.minPages) {
            throw StateError(
              'Imported memory `${import.key}` has min ${importedMemory.minPages} pages '
              'but requires at least ${expected.minPages}.',
            );
          }

          final expectedMax = expected.maxPages;
          if (expectedMax != null) {
            final importedMax = importedMemory.maxPages;
            if (importedMax == null || importedMax > expectedMax) {
              throw StateError(
                'Imported memory `${import.key}` max pages mismatch: '
                'expected <= $expectedMax, actual=${importedMax ?? 'unbounded'}.',
              );
            }
          }

          if (importedMemory.pageCount < expected.minPages) {
            throw StateError(
              'Imported memory `${import.key}` has ${importedMemory.pageCount} pages '
              'but requires at least ${expected.minPages}.',
            );
          }

          memories.add(importedMemory);

        case WasmImportKind.global:
          final globalType = import.globalType;
          if (globalType == null) {
            throw FormatException('Malformed global import `${import.key}`.');
          }

          final importedValue = imports.globals[import.key];
          if (importedValue == null) {
            throw StateError('Missing global import `${import.key}`.');
          }

          globals.add(
            RuntimeGlobal(
              valueType: globalType.valueType,
              mutable: globalType.mutable,
              value: WasmValue.fromExternal(
                globalType.valueType,
                importedValue,
              ),
            ),
          );
      }
    }

    for (final memoryType in module.memories) {
      _validateSupportedMemoryType(
        memoryType,
        features: features,
        context: 'defined memory',
      );
      memories.add(
        WasmMemory(
          minPages: memoryType.minPages,
          maxPages: memoryType.maxPages,
          shared: memoryType.shared,
          pageSizeBytes: 1 << memoryType.pageSizeLog2,
        ),
      );
    }

    for (final tableType in module.tables) {
      tables.add(
        WasmTable(
          refType: tableType.refType,
          min: tableType.min,
          max: tableType.max,
          isTable64: tableType.isTable64,
        ),
      );
    }

    for (final globalDef in module.globals) {
      final value = _evaluateConstExpr(
        globalDef.initExpr,
        globals,
        module.types,
      );
      globals.add(
        RuntimeGlobal(
          valueType: globalDef.type.valueType,
          mutable: globalDef.type.mutable,
          value: value,
        ),
      );
    }

    final memory64ByIndex = _memory64ByIndex(module);
    final table64ByIndex = _table64ByIndex(module);
    for (var i = 0; i < module.codes.length; i++) {
      final typeIndex = module.functionTypeIndices[i];
      if (typeIndex < 0 ||
          typeIndex >= module.types.length ||
          !module.types[typeIndex].isFunctionType) {
        throw FormatException('Function $i has invalid type index $typeIndex.');
      }

      final predecoded = WasmPredecoder.decode(
        module.codes[i],
        module.types,
        features: features,
        memory64ByIndex: memory64ByIndex,
      );
      functions.add(
        DefinedRuntimeFunction(
          type: module.types[typeIndex],
          declaredTypeIndex: typeIndex,
          runtimeTypeDepth: _functionTypeDepth(module, typeIndex),
          localTypes: predecoded.localTypes,
          instructions: predecoded.instructions,
        ),
      );
    }

    final dataSegments = List<Uint8List?>.generate(
      module.dataSegments.length,
      (index) => Uint8List.fromList(module.dataSegments[index].bytes),
      growable: false,
    );
    final elementSegments = List<List<int?>?>.generate(
      module.elements.length,
      (index) => List<int?>.from(module.elements[index].functionIndices),
      growable: false,
    );
    final elementSegmentRefTypeCodes = List<int>.generate(
      module.elements.length,
      (index) => module.elements[index].refTypeCode,
      growable: false,
    );

    final functionExports = <String, int>{};
    final globalExports = <String, int>{};
    final memoryExports = <String, WasmMemory>{};
    final tableExports = <String, WasmTable>{};

    for (final export in module.exports) {
      switch (export.kind) {
        case WasmExportKind.function:
          if (export.index < 0 || export.index >= functions.length) {
            throw FormatException(
              'Export `${export.name}` has invalid function index ${export.index}.',
            );
          }
          functionExports[export.name] = export.index;

        case WasmExportKind.global:
          if (export.index < 0 || export.index >= globals.length) {
            throw FormatException(
              'Export `${export.name}` has invalid global index ${export.index}.',
            );
          }
          globalExports[export.name] = export.index;

        case WasmExportKind.memory:
          if (export.index < 0 || export.index >= memories.length) {
            throw FormatException(
              'Export `${export.name}` has invalid memory index ${export.index}.',
            );
          }
          memoryExports[export.name] = memories[export.index];

        case WasmExportKind.table:
          if (export.index < 0 || export.index >= tables.length) {
            throw FormatException(
              'Export `${export.name}` has invalid table index ${export.index}.',
            );
          }
          tableExports[export.name] = tables[export.index];
      }
    }

    final instance = WasmInstance._(
      module: module,
      memories: List.unmodifiable(memories),
      tables: List.unmodifiable(tables),
      functions: List.unmodifiable(functions),
      globals: globals,
      memory64ByIndex: memory64ByIndex,
      table64ByIndex: table64ByIndex,
      dataSegments: dataSegments,
      elementSegments: elementSegments,
      elementSegmentRefTypeCodes: elementSegmentRefTypeCodes,
      functionExports: Map.unmodifiable(functionExports),
      globalExports: Map.unmodifiable(globalExports),
      memoryExports: Map.unmodifiable(memoryExports),
      tableExports: Map.unmodifiable(tableExports),
    );

    instance._initializeActiveElements();
    instance._initializeActiveDataSegments();
    instance._runStartFunction();

    return instance;
  }

  List<String> get exportedFunctions =>
      _functionExports.keys.toList(growable: false);

  List<String> get exportedGlobals =>
      _globalExports.keys.toList(growable: false);

  List<String> get exportedMemories =>
      _memoryExports.keys.toList(growable: false);

  List<String> get exportedTables => _tableExports.keys.toList(growable: false);

  WasmFunctionType exportedFunctionType(String exportName) {
    final functionIndex = _functionExports[exportName];
    if (functionIndex == null) {
      throw ArgumentError.value(
        exportName,
        'exportName',
        'Function export not found',
      );
    }
    return functions[functionIndex].type;
  }

  int exportedFunctionTypeDepth(String exportName) {
    final functionIndex = _functionExports[exportName];
    if (functionIndex == null) {
      throw ArgumentError.value(
        exportName,
        'exportName',
        'Function export not found',
      );
    }
    return functions[functionIndex].runtimeTypeDepth;
  }

  Object? invoke(String exportName, [List<Object?> args = const []]) {
    final functionIndex = _functionExports[exportName];
    if (functionIndex == null) {
      throw ArgumentError.value(
        exportName,
        'exportName',
        'Function export not found',
      );
    }

    final functionType = functions[functionIndex].type;
    if (args.length != functionType.params.length) {
      throw ArgumentError(
        'Export `$exportName` expects ${functionType.params.length} args, '
        'got ${args.length}.',
      );
    }

    final typedArgs = <WasmValue>[];
    for (var i = 0; i < functionType.params.length; i++) {
      typedArgs.add(WasmValue.fromExternal(functionType.params[i], args[i]));
    }

    final results = _vm.invokeFunction(functionIndex, typedArgs);
    return _externalizeResults(results);
  }

  Future<Object?> invokeAsync(
    String exportName, [
    List<Object?> args = const [],
  ]) async {
    return invoke(exportName, args);
  }

  List<Object?> invokeMulti(
    String exportName, [
    List<Object?> args = const [],
  ]) {
    final result = invoke(exportName, args);
    if (result == null) {
      return const [];
    }
    if (result is List<Object?>) {
      return result;
    }
    return [result];
  }

  Future<List<Object?>> invokeMultiAsync(
    String exportName, [
    List<Object?> args = const [],
  ]) async {
    final result = await invokeAsync(exportName, args);
    if (result == null) {
      return const [];
    }
    if (result is List<Object?>) {
      return result;
    }
    return [result];
  }

  int invokeI32(String exportName, [List<Object?> args = const []]) {
    final result = invoke(exportName, args);
    if (result is! int) {
      throw StateError('Export `$exportName` does not return an i32 value.');
    }
    return result.toSigned(32);
  }

  Future<int> invokeI32Async(
    String exportName, [
    List<Object?> args = const [],
  ]) async {
    final result = await invokeAsync(exportName, args);
    if (result is! int) {
      throw StateError('Export `$exportName` does not return an i32 value.');
    }
    return result.toSigned(32);
  }

  int invokeI64(String exportName, [List<Object?> args = const []]) {
    final result = invoke(exportName, args);
    if (result is! int && result is! BigInt) {
      throw StateError('Export `$exportName` does not return an i64 value.');
    }
    return WasmI64.signed(result as Object).toInt();
  }

  Future<int> invokeI64Async(
    String exportName, [
    List<Object?> args = const [],
  ]) async {
    final result = await invokeAsync(exportName, args);
    if (result is! int && result is! BigInt) {
      throw StateError('Export `$exportName` does not return an i64 value.');
    }
    return WasmI64.signed(result as Object).toInt();
  }

  double invokeF32(String exportName, [List<Object?> args = const []]) {
    final result = invoke(exportName, args);
    if (result is! double) {
      throw StateError('Export `$exportName` does not return an f32 value.');
    }
    return result;
  }

  Future<double> invokeF32Async(
    String exportName, [
    List<Object?> args = const [],
  ]) async {
    final result = await invokeAsync(exportName, args);
    if (result is! double) {
      throw StateError('Export `$exportName` does not return an f32 value.');
    }
    return result;
  }

  double invokeF64(String exportName, [List<Object?> args = const []]) {
    final result = invoke(exportName, args);
    if (result is! double) {
      throw StateError('Export `$exportName` does not return an f64 value.');
    }
    return result;
  }

  Future<double> invokeF64Async(
    String exportName, [
    List<Object?> args = const [],
  ]) async {
    final result = await invokeAsync(exportName, args);
    if (result is! double) {
      throw StateError('Export `$exportName` does not return an f64 value.');
    }
    return result;
  }

  Object readGlobal(String exportName) {
    final globalIndex = _globalExports[exportName];
    if (globalIndex == null) {
      throw ArgumentError.value(
        exportName,
        'exportName',
        'Global export not found',
      );
    }
    return globals[globalIndex].value.toExternal();
  }

  int readGlobalI32(String exportName) {
    final value = readGlobal(exportName);
    if (value is! int) {
      throw StateError('Global `$exportName` is not i32.');
    }
    return value.toSigned(32);
  }

  int readGlobalI64(String exportName) {
    final value = readGlobal(exportName);
    if (value is! int && value is! BigInt) {
      throw StateError('Global `$exportName` is not i64.');
    }
    return WasmI64.signed(value).toInt();
  }

  double readGlobalF32(String exportName) {
    final value = readGlobal(exportName);
    if (value is! double) {
      throw StateError('Global `$exportName` is not f32.');
    }
    return value;
  }

  double readGlobalF64(String exportName) {
    final value = readGlobal(exportName);
    if (value is! double) {
      throw StateError('Global `$exportName` is not f64.');
    }
    return value;
  }

  void writeGlobal(String exportName, Object? value) {
    final globalIndex = _globalExports[exportName];
    if (globalIndex == null) {
      throw ArgumentError.value(
        exportName,
        'exportName',
        'Global export not found',
      );
    }

    final global = globals[globalIndex];
    if (!global.mutable) {
      throw StateError('Global export `$exportName` is immutable.');
    }

    global.setValue(WasmValue.fromExternal(global.valueType, value));
  }

  WasmMemory exportedMemory(String exportName) {
    final exported = _memoryExports[exportName];
    if (exported == null) {
      throw ArgumentError.value(
        exportName,
        'exportName',
        'Memory export not found',
      );
    }
    return exported;
  }

  WasmTable exportedTable(String exportName) {
    final exported = _tableExports[exportName];
    if (exported == null) {
      throw ArgumentError.value(
        exportName,
        'exportName',
        'Table export not found',
      );
    }
    return exported;
  }

  void _initializeActiveElements() {
    if (module.elements.isEmpty) {
      return;
    }
    final table64ByIndex = _table64ByIndex(module);

    for (final element in module.elements) {
      if (!element.isActive) {
        continue;
      }

      if (element.tableIndex < 0 || element.tableIndex >= tables.length) {
        throw FormatException(
          'Invalid table index in element: ${element.tableIndex}',
        );
      }

      final table = tables[element.tableIndex];
      final offsetValue = _evaluateConstExpr(
        element.offsetExpr!,
        globals,
        module.types,
      );
      final isTable64 =
          element.tableIndex >= 0 &&
          element.tableIndex < table64ByIndex.length &&
          table64ByIndex[element.tableIndex];
      final offset = _constExprTableOffset(offsetValue, isTable64: isTable64);

      final carriesFunctionRefs = element.refTypeCode == 0x70;
      if (carriesFunctionRefs) {
        for (final functionIndex in element.functionIndices) {
          if (functionIndex == null) {
            continue;
          }
          if (functionIndex < 0 || functionIndex >= functions.length) {
            throw FormatException(
              'Invalid function index in element: $functionIndex',
            );
          }
        }
      }

      table.initialize(offset, element.functionIndices);
    }
  }

  void _initializeActiveDataSegments() {
    if (module.dataSegments.isEmpty) {
      return;
    }
    final memory64ByIndex = _memory64ByIndex(module);

    for (final data in module.dataSegments) {
      if (data.isPassive) {
        continue;
      }

      if (data.memoryIndex < 0 || data.memoryIndex >= memories.length) {
        throw FormatException(
          'Invalid memory index in data segment: ${data.memoryIndex}.',
        );
      }
      final mem = memories[data.memoryIndex];

      final isMemory64 =
          data.memoryIndex >= 0 &&
          data.memoryIndex < memory64ByIndex.length &&
          memory64ByIndex[data.memoryIndex];
      final offset = _constExprMemoryOffset(
        _evaluateConstExpr(data.offsetExpr!, globals, module.types),
        isMemory64: isMemory64,
      );
      mem.writeBytes(offset, data.bytes);
    }
  }

  void _runStartFunction() {
    final startIndex = module.startFunctionIndex;
    if (startIndex == null) {
      return;
    }

    if (startIndex < 0 || startIndex >= functions.length) {
      throw FormatException('Invalid start function index: $startIndex');
    }

    final startType = functions[startIndex].type;
    if (startType.params.isNotEmpty || startType.results.isNotEmpty) {
      throw FormatException('Start function must have signature [] -> [].');
    }

    final results = _vm.invokeFunction(startIndex, const []);
    if (results.isNotEmpty) {
      throw StateError('Start function must not produce a value.');
    }
  }

  static WasmValue _evaluateConstExpr(
    Uint8List expr,
    List<RuntimeGlobal> globals,
    List<WasmFunctionType> types,
  ) {
    final reader = ByteReader(expr);
    final stack = <WasmValue>[];

    WasmValue pop() {
      if (stack.isEmpty) {
        throw const FormatException('Const expr operand stack underflow.');
      }
      return stack.removeLast();
    }

    int popI32() => pop().castTo(WasmValueType.i32).asI32();
    BigInt popI64() => pop().castTo(WasmValueType.i64).asI64();
    double popF32() => pop().castTo(WasmValueType.f32).asF32();
    double popF64() => pop().castTo(WasmValueType.f64).asF64();

    WasmValue defaultValueForFieldSignature(String fieldSignature) {
      if (fieldSignature.length < 2 || fieldSignature.length.isOdd) {
        return WasmValue.i32(0);
      }
      final typeCode = int.parse(fieldSignature.substring(0, 2), radix: 16);
      return switch (typeCode) {
        0x7e => WasmValue.i64(0),
        0x7d => WasmValue.f32(0),
        0x7c => WasmValue.f64(0),
        0x63 ||
        0x64 ||
        0x70 ||
        0x6f ||
        0x6e ||
        0x6d ||
        0x6c ||
        0x6b ||
        0x6a ||
        0x69 ||
        0x68 ||
        0x67 ||
        0x66 ||
        0x65 ||
        0x71 ||
        0x72 ||
        0x73 => WasmValue.i32(-1),
        _ => WasmValue.i32(0),
      };
    }

    while (!reader.isEOF) {
      final opcode = reader.readByte();
      switch (opcode) {
        case Opcodes.i32Const:
          stack.add(WasmValue.i32(reader.readVarInt32()));

        case Opcodes.i64Const:
          stack.add(WasmValue.i64(reader.readVarInt64()));

        case Opcodes.f32Const:
          final bits = ByteData.sublistView(
            reader.readBytes(4),
          ).getUint32(0, Endian.little);
          stack.add(WasmValue.f32(WasmValue.fromF32Bits(bits)));

        case Opcodes.f64Const:
          final bytes = reader.readBytes(8);
          final data = ByteData.sublistView(bytes);
          final bits = WasmI64.fromU32PairUnsigned(
            low: data.getUint32(0, Endian.little),
            high: data.getUint32(4, Endian.little),
          );
          stack.add(WasmValue.f64(WasmValue.fromF64Bits(bits)));

        case Opcodes.globalGet:
          final globalIndex = reader.readVarUint32();
          if (globalIndex < 0 || globalIndex >= globals.length) {
            throw FormatException(
              'Invalid global index in const expr: $globalIndex',
            );
          }
          stack.add(globals[globalIndex].value);

        case Opcodes.refNull:
          _consumeHeapType(reader);
          stack.add(WasmValue.i32(-1));

        case Opcodes.refFunc:
          stack.add(WasmValue.i32(reader.readVarUint32()));

        case 0xfb:
          final subOpcode = reader.readVarUint32();
          final pseudoOpcode = 0xfb00 | subOpcode;
          switch (pseudoOpcode) {
            case Opcodes.structNew:
            case Opcodes.structNewDefault:
            case Opcodes.structNewDesc:
            case Opcodes.structNewDefaultDesc:
            case Opcodes.arrayNew:
            case Opcodes.arrayNewDefault:
            case Opcodes.arrayNewFixed:
              final typeIndex = reader.readVarUint32();
              if (typeIndex < 0 || typeIndex >= types.length) {
                throw FormatException(
                  'Invalid type index in const expr: $typeIndex',
                );
              }
              final type = types[typeIndex];
              switch (pseudoOpcode) {
                case Opcodes.structNew:
                  if (type.kind != WasmCompositeTypeKind.struct) {
                    throw const FormatException('Const expr type mismatch.');
                  }
                  if (type.descriptorTypeIndex != null) {
                    throw const FormatException('Const expr type mismatch.');
                  }
                  final fields = List<WasmValue>.filled(
                    type.fieldSignatures.length,
                    WasmValue.i32(0),
                    growable: false,
                  );
                  for (var fieldIndex = fields.length - 1;
                      fieldIndex >= 0;
                      fieldIndex--) {
                    fields[fieldIndex] = pop();
                  }
                  stack.add(
                    WasmValue.i32(
                      WasmVm.allocateConstStructRef(
                        typeIndex: typeIndex,
                        fields: fields,
                      ),
                    ),
                  );
                case Opcodes.structNewDefault:
                  if (type.kind != WasmCompositeTypeKind.struct) {
                    throw const FormatException('Const expr type mismatch.');
                  }
                  if (type.descriptorTypeIndex != null) {
                    throw const FormatException('Const expr type mismatch.');
                  }
                  final fields = type.fieldSignatures
                      .map(defaultValueForFieldSignature)
                      .toList(growable: false);
                  stack.add(
                    WasmValue.i32(
                      WasmVm.allocateConstStructRef(
                        typeIndex: typeIndex,
                        fields: fields,
                      ),
                    ),
                  );
                case Opcodes.structNewDesc:
                  if (type.kind != WasmCompositeTypeKind.struct ||
                      type.descriptorTypeIndex == null) {
                    throw const FormatException('Const expr type mismatch.');
                  }
                  final descriptor = pop().castTo(WasmValueType.i32).asI32();
                  if (descriptor == -1) {
                    throw StateError('null descriptor reference');
                  }
                  final fields = List<WasmValue>.filled(
                    type.fieldSignatures.length,
                    WasmValue.i32(0),
                    growable: false,
                  );
                  for (var fieldIndex = fields.length - 1;
                      fieldIndex >= 0;
                      fieldIndex--) {
                    fields[fieldIndex] = pop();
                  }
                  stack.add(
                    WasmValue.i32(
                      WasmVm.allocateConstStructRef(
                        typeIndex: typeIndex,
                        descriptorRef: descriptor,
                        fields: fields,
                      ),
                    ),
                  );
                case Opcodes.structNewDefaultDesc:
                  if (type.kind != WasmCompositeTypeKind.struct ||
                      type.descriptorTypeIndex == null) {
                    throw const FormatException('Const expr type mismatch.');
                  }
                  final descriptor = pop().castTo(WasmValueType.i32).asI32();
                  if (descriptor == -1) {
                    throw StateError('null descriptor reference');
                  }
                  final fields = type.fieldSignatures
                      .map(defaultValueForFieldSignature)
                      .toList(growable: false);
                  stack.add(
                    WasmValue.i32(
                      WasmVm.allocateConstStructRef(
                        typeIndex: typeIndex,
                        descriptorRef: descriptor,
                        fields: fields,
                      ),
                    ),
                  );
                case Opcodes.arrayNew:
                  if (type.kind != WasmCompositeTypeKind.array) {
                    throw const FormatException('Const expr type mismatch.');
                  }
                  final length = pop().castTo(WasmValueType.i32).asI32();
                  final value = pop();
                  if (length < 0) {
                    throw RangeError('Array length out of bounds: $length');
                  }
                  final elements = List<WasmValue>.filled(
                    length,
                    value,
                    growable: false,
                  );
                  stack.add(
                    WasmValue.i32(
                      WasmVm.allocateConstArrayRef(
                        typeIndex: typeIndex,
                        elements: elements,
                      ),
                    ),
                  );
                case Opcodes.arrayNewDefault:
                  if (type.kind != WasmCompositeTypeKind.array) {
                    throw const FormatException('Const expr type mismatch.');
                  }
                  final length = pop().castTo(WasmValueType.i32).asI32();
                  if (length < 0) {
                    throw RangeError('Array length out of bounds: $length');
                  }
                  final defaultValue = defaultValueForFieldSignature(
                    type.fieldSignatures.single,
                  );
                  final elements = List<WasmValue>.filled(
                    length,
                    defaultValue,
                    growable: false,
                  );
                  stack.add(
                    WasmValue.i32(
                      WasmVm.allocateConstArrayRef(
                        typeIndex: typeIndex,
                        elements: elements,
                      ),
                    ),
                  );
                case Opcodes.arrayNewFixed:
                  if (type.kind != WasmCompositeTypeKind.array) {
                    throw const FormatException('Const expr type mismatch.');
                  }
                  final elementCount = reader.readVarUint32();
                  final elements = List<WasmValue>.filled(
                    elementCount,
                    WasmValue.i32(0),
                    growable: false,
                  );
                  for (var elementIndex = elementCount - 1;
                      elementIndex >= 0;
                      elementIndex--) {
                    elements[elementIndex] = pop();
                  }
                  stack.add(
                    WasmValue.i32(
                      WasmVm.allocateConstArrayRef(
                        typeIndex: typeIndex,
                        elements: elements,
                      ),
                    ),
                  );
                default:
                  throw UnsupportedError(
                    'Unsupported const expr opcode: 0x${pseudoOpcode.toRadixString(16)}',
                  );
              }
            case Opcodes.refI31:
              final value = pop().castTo(WasmValueType.i32).asI32() & 0x7fffffff;
              stack.add(WasmValue.i32(WasmVm.allocateConstI31Ref(value)));
            default:
              throw UnsupportedError(
                'Unsupported const expr opcode: 0x${pseudoOpcode.toRadixString(16)}',
              );
          }

        case Opcodes.i32Add:
          final rhs = popI32();
          final lhs = popI32();
          stack.add(WasmValue.i32(lhs + rhs));

        case Opcodes.i32Sub:
          final rhs = popI32();
          final lhs = popI32();
          stack.add(WasmValue.i32(lhs - rhs));

        case Opcodes.i32Mul:
          final rhs = popI32();
          final lhs = popI32();
          stack.add(WasmValue.i32(lhs * rhs));

        case Opcodes.i64Add:
          final rhs = popI64();
          final lhs = popI64();
          stack.add(WasmValue.i64(lhs + rhs));

        case Opcodes.i64Sub:
          final rhs = popI64();
          final lhs = popI64();
          stack.add(WasmValue.i64(lhs - rhs));

        case Opcodes.i64Mul:
          final rhs = popI64();
          final lhs = popI64();
          stack.add(WasmValue.i64(lhs * rhs));

        case Opcodes.f32Add:
          final rhs = popF32();
          final lhs = popF32();
          stack.add(WasmValue.f32(lhs + rhs));

        case Opcodes.f32Sub:
          final rhs = popF32();
          final lhs = popF32();
          stack.add(WasmValue.f32(lhs - rhs));

        case Opcodes.f32Mul:
          final rhs = popF32();
          final lhs = popF32();
          stack.add(WasmValue.f32(lhs * rhs));

        case Opcodes.f32Div:
          final rhs = popF32();
          final lhs = popF32();
          stack.add(WasmValue.f32(lhs / rhs));

        case Opcodes.f64Add:
          final rhs = popF64();
          final lhs = popF64();
          stack.add(WasmValue.f64(lhs + rhs));

        case Opcodes.f64Sub:
          final rhs = popF64();
          final lhs = popF64();
          stack.add(WasmValue.f64(lhs - rhs));

        case Opcodes.f64Mul:
          final rhs = popF64();
          final lhs = popF64();
          stack.add(WasmValue.f64(lhs * rhs));

        case Opcodes.f64Div:
          final rhs = popF64();
          final lhs = popF64();
          stack.add(WasmValue.f64(lhs / rhs));

        case Opcodes.end:
          if (!reader.isEOF) {
            throw const FormatException('Const expr has trailing bytes.');
          }
          if (stack.length != 1) {
            throw FormatException(
              'Const expr must leave exactly one value, got ${stack.length}.',
            );
          }
          return stack.single;

        default:
          throw UnsupportedError(
            'Unsupported const expr opcode: 0x${opcode.toRadixString(16)}',
          );
      }
    }

    throw const FormatException('Const expr missing end opcode.');
  }

  static void _validateSupportedMemoryType(
    WasmMemoryType memoryType, {
    required WasmFeatureSet features,
    required String context,
  }) {
    if (memoryType.pageSizeLog2 != 0 && memoryType.pageSizeLog2 != 16) {
      throw FormatException(
        'Invalid custom page size for $context: '
        'log2=${memoryType.pageSizeLog2} (only log2=0 or log2=16 are supported).',
      );
    }
    final pageSizeBytes = 1 << memoryType.pageSizeLog2;
    final maxPagesSupported = wasmAddressSpaceBytes ~/ pageSizeBytes;
    if (memoryType.minPages > maxPagesSupported) {
      throw UnsupportedError(
        '$context exceeds runtime memory capacity: minPages=${memoryType.minPages}, '
        'maxSupportedPages=$maxPagesSupported.',
      );
    }
    final declaredMax = memoryType.maxPages;
    if (declaredMax != null && declaredMax > maxPagesSupported) {
      throw UnsupportedError(
        '$context exceeds runtime memory capacity: maxPages=$declaredMax, '
        'maxSupportedPages=$maxPagesSupported.',
      );
    }
    if (memoryType.shared && !features.threads) {
      throw UnsupportedError(
        '$context uses shared memory, but threads feature is disabled.',
      );
    }
  }

  static int _constExprMemoryOffset(
    WasmValue value, {
    required bool isMemory64,
  }) {
    final offset = isMemory64
        ? WasmI64.unsigned(value.castTo(WasmValueType.i64).asI64())
        : BigInt.from(value.castTo(WasmValueType.i32).asI32().toUnsigned(32));
    final maxSupported = BigInt.from(wasmAddressSpaceBytes);
    if (offset > maxSupported) {
      throw RangeError(
        'Data segment offset exceeds supported linear-memory range: '
        '$offset > $wasmAddressSpaceBytes.',
      );
    }
    return offset.toInt();
  }

  static int _constExprTableOffset(
    WasmValue value, {
    required bool isTable64,
  }) {
    final offset = isTable64
        ? WasmI64.unsigned(value.castTo(WasmValueType.i64).asI64())
        : BigInt.from(value.castTo(WasmValueType.i32).asI32().toUnsigned(32));
    final maxSupported = BigInt.from(wasmAddressSpaceBytes);
    if (offset > maxSupported) {
      throw RangeError(
        'Element segment offset exceeds supported table range: '
        '$offset > $wasmAddressSpaceBytes.',
      );
    }
    return offset.toInt();
  }

  static int _functionTypeDepth(WasmModule module, int typeIndex) {
    return _functionTypeDepthInternal(module, typeIndex, <int>{});
  }

  static int _functionTypeDepthInternal(
    WasmModule module,
    int typeIndex,
    Set<int> seen,
  ) {
    if (!seen.add(typeIndex)) {
      return 0;
    }
    if (typeIndex < 0 || typeIndex >= module.types.length) {
      return 0;
    }
    final type = module.types[typeIndex];
    if (!type.isFunctionType || type.superTypeIndices.isEmpty) {
      return 0;
    }
    var maxDepth = 0;
    for (final superTypeIndex in type.superTypeIndices) {
      final superDepth = _functionTypeDepthInternal(
        module,
        superTypeIndex,
        seen,
      );
      if (superDepth > maxDepth) {
        maxDepth = superDepth;
      }
    }
    return maxDepth + 1;
  }

  static List<bool> _memory64ByIndex(WasmModule module) {
    final list = <bool>[];
    for (final import in module.imports) {
      if (import.kind == WasmImportKind.memory) {
        list.add(import.memoryType?.isMemory64 ?? false);
      }
    }
    for (final memory in module.memories) {
      list.add(memory.isMemory64);
    }
    return List<bool>.unmodifiable(list);
  }

  static List<bool> _table64ByIndex(WasmModule module) {
    final list = <bool>[];
    for (final import in module.imports) {
      if (import.kind == WasmImportKind.table) {
        list.add(import.tableType?.isTable64 ?? false);
      }
    }
    for (final table in module.tables) {
      list.add(table.isTable64);
    }
    return List<bool>.unmodifiable(list);
  }

  static void _consumeHeapType(ByteReader reader) {
    _consumeHeapTypeWithLeadingByte(reader, reader.readByte());
  }

  static void _consumeHeapTypeWithLeadingByte(ByteReader reader, int lead) {
    if (lead == 0x62 || lead == 0x61) {
      _consumeHeapType(reader);
      return;
    }
    if (lead >= 0x65 && lead <= 0x71) {
      return;
    }
    _readSignedLeb33WithFirst(reader, lead);
  }

  static int _readSignedLeb33WithFirst(ByteReader reader, int firstByte) {
    var result = firstByte & 0x7f;
    var shift = 7;
    var byte = firstByte;
    var multiplier = 128;
    while ((byte & 0x80) != 0) {
      byte = reader.readByte();
      result += (byte & 0x7f) * multiplier;
      multiplier *= 128;
      shift += 7;
      if (shift > 35) {
        throw const FormatException('Invalid signed LEB33 encoding.');
      }
    }
    if (shift < 33 && (byte & 0x40) != 0) {
      result -= multiplier;
    }
    return _normalizeSignedLeb33(result);
  }

  static int _normalizeSignedLeb33(int value) {
    const signBit33 = 0x100000000;
    const width33 = 0x200000000;
    var normalized = value % width33;
    if (normalized < 0) {
      normalized += width33;
    }
    if (normalized >= signBit33) {
      normalized -= width33;
    }
    return normalized;
  }

  static Object? _externalizeResults(List<WasmValue> results) {
    switch (results.length) {
      case 0:
        return null;
      case 1:
        return results.first.toExternal();
      default:
        return WasmValue.encodeResults(results);
    }
  }
}
