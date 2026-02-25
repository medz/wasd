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
    required this.memory,
    required this.tables,
    required this.functions,
    required this.globals,
    required List<Uint8List?> dataSegments,
    required List<List<int?>?> elementSegments,
    required Map<String, int> functionExports,
    required Map<String, int> globalExports,
    required Map<String, WasmMemory> memoryExports,
    required Map<String, WasmTable> tableExports,
  }) : _functionExports = functionExports,
       _globalExports = globalExports,
       _memoryExports = memoryExports,
       _tableExports = tableExports,
       _vm = WasmVm(
         functions: functions,
         types: module.types,
         tables: tables,
         memory: memory,
         globals: globals,
         dataSegments: dataSegments,
         elementSegments: elementSegments,
       );

  final WasmModule module;
  final WasmMemory? memory;
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

    if (module.importedMemoryCount + module.memories.length > 1) {
      throw UnsupportedError(
        'This runtime currently supports at most one linear memory.',
      );
    }

    final functions = <RuntimeFunction>[];
    final globals = <RuntimeGlobal>[];
    final tables = <WasmTable>[];
    WasmMemory? memory;

    for (final import in module.imports) {
      switch (import.kind) {
        case WasmImportKind.function:
          final typeIndex = import.functionTypeIndex;
          if (typeIndex == null || typeIndex >= module.types.length) {
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

          if (importedTable.length < expected.min) {
            throw StateError(
              'Imported table `${import.key}` has length ${importedTable.length} '
              'but requires at least ${expected.min}.',
            );
          }

          tables.add(importedTable);

        case WasmImportKind.memory:
          if (memory != null) {
            throw UnsupportedError('Only one memory import is supported.');
          }

          final importedMemory = imports.memories[import.key];
          if (importedMemory == null) {
            throw StateError('Missing memory import `${import.key}`.');
          }

          final expected = import.memoryType;
          if (expected == null) {
            throw FormatException('Malformed memory import `${import.key}`.');
          }

          if (importedMemory.pageCount < expected.minPages) {
            throw StateError(
              'Imported memory `${import.key}` has ${importedMemory.pageCount} pages '
              'but requires at least ${expected.minPages}.',
            );
          }

          memory = importedMemory;

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

    if (module.memories.isNotEmpty) {
      if (memory != null) {
        throw UnsupportedError(
          'A module cannot have both imported and defined memory.',
        );
      }
      if (module.memories.length > 1) {
        throw UnsupportedError('Only one defined memory is supported.');
      }

      final memoryType = module.memories.first;
      memory = WasmMemory(
        minPages: memoryType.minPages,
        maxPages: memoryType.maxPages,
      );
    }

    for (final tableType in module.tables) {
      tables.add(
        WasmTable(
          refType: tableType.refType,
          min: tableType.min,
          max: tableType.max,
        ),
      );
    }

    for (final globalDef in module.globals) {
      final value = _evaluateConstExpr(globalDef.initExpr, globals);
      globals.add(
        RuntimeGlobal(
          valueType: globalDef.type.valueType,
          mutable: globalDef.type.mutable,
          value: value,
        ),
      );
    }

    for (var i = 0; i < module.codes.length; i++) {
      final typeIndex = module.functionTypeIndices[i];
      if (typeIndex < 0 || typeIndex >= module.types.length) {
        throw FormatException('Function $i has invalid type index $typeIndex.');
      }

      final predecoded = WasmPredecoder.decode(
        module.codes[i],
        module.types,
        features: features,
      );
      functions.add(
        DefinedRuntimeFunction(
          type: module.types[typeIndex],
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
          if (memory == null) {
            throw FormatException(
              'Export `${export.name}` references memory but module has none.',
            );
          }
          if (export.index != 0) {
            throw UnsupportedError('Only memory index 0 is supported.');
          }
          memoryExports[export.name] = memory;

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
      memory: memory,
      tables: List.unmodifiable(tables),
      functions: List.unmodifiable(functions),
      globals: globals,
      dataSegments: dataSegments,
      elementSegments: elementSegments,
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
    if (result is! int) {
      throw StateError('Export `$exportName` does not return an i64 value.');
    }
    return WasmI64.signed(result);
  }

  Future<int> invokeI64Async(
    String exportName, [
    List<Object?> args = const [],
  ]) async {
    final result = await invokeAsync(exportName, args);
    if (result is! int) {
      throw StateError('Export `$exportName` does not return an i64 value.');
    }
    return WasmI64.signed(result);
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
    if (value is! int) {
      throw StateError('Global `$exportName` is not i64.');
    }
    return WasmI64.signed(value);
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
      final offsetValue = _evaluateConstExpr(element.offsetExpr!, globals);
      final offset = offsetValue.castTo(WasmValueType.i32).asI32();

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

      table.initialize(offset, element.functionIndices);
    }
  }

  void _initializeActiveDataSegments() {
    if (module.dataSegments.isEmpty) {
      return;
    }

    final mem = memory;
    for (final data in module.dataSegments) {
      if (data.isPassive) {
        continue;
      }

      if (data.memoryIndex != 0) {
        throw UnsupportedError(
          'Only memory index 0 is supported for data init.',
        );
      }

      if (mem == null) {
        throw StateError('Module has active data segments but no memory.');
      }

      final offset = _evaluateConstExpr(
        data.offsetExpr!,
        globals,
      ).castTo(WasmValueType.i32).asI32();
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
    int popI64() => pop().castTo(WasmValueType.i64).asI64();
    double popF32() => pop().castTo(WasmValueType.f32).asF32();
    double popF64() => pop().castTo(WasmValueType.f64).asF64();

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
          WasmRefTypeCodec.fromByte(reader.readByte());
          stack.add(WasmValue.i32(-1));

        case Opcodes.refFunc:
          stack.add(WasmValue.i32(reader.readVarUint32()));

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
