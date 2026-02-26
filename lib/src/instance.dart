import 'dart:async';
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

enum _AsyncSubsetControlKind { block, loop, if_ }

final class _AsyncSubsetControlFrame {
  const _AsyncSubsetControlFrame({
    required this.kind,
    required this.stackBaseHeight,
    required this.startIndex,
    required this.endIndex,
    required this.parameterTypes,
    required this.resultTypes,
  });

  final _AsyncSubsetControlKind kind;
  final int stackBaseHeight;
  final int startIndex;
  final int endIndex;
  final List<WasmValueType> parameterTypes;
  final List<WasmValueType> resultTypes;

  List<WasmValueType> get branchTypes =>
      kind == _AsyncSubsetControlKind.loop ? parameterTypes : resultTypes;
}

final class WasmInstance {
  WasmInstance._({
    required this.module,
    required this.memories,
    required this.tables,
    required this.functions,
    required this.globals,
    required List<WasmGlobalType> globalTypes,
    required List<bool> memory64ByIndex,
    required List<bool> table64ByIndex,
    required List<Uint8List?> dataSegments,
    required List<List<int?>?> elementSegments,
    required List<int> elementSegmentRefTypeCodes,
    required int functionRefNamespace,
    required List<WasmFunctionType> tagTypes,
    required List<String> tagNominalTypeKeys,
    required Map<String, int> functionExports,
    required Map<String, int> globalExports,
    required Map<String, WasmMemory> memoryExports,
    required Map<String, WasmTable> tableExports,
    required Map<String, WasmTagImport> tagExports,
  }) : memory = memories.isEmpty ? null : memories.first,
       _functionExports = functionExports,
       _globalExports = globalExports,
       _memoryExports = memoryExports,
       _tableExports = tableExports,
       _tagExports = tagExports,
       _globalTypes = globalTypes,
       _functionRefNamespace = functionRefNamespace,
       _vm = WasmVm(
         functions: functions,
         types: module.types,
         tagTypes: tagTypes,
         tagNominalTypeKeys: tagNominalTypeKeys,
         tables: tables,
         memories: memories,
         globals: globals,
         functionRefNamespace: functionRefNamespace,
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
  final Map<String, WasmTagImport> _tagExports;
  final List<WasmGlobalType> _globalTypes;
  final int _functionRefNamespace;
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

    final functionRefNamespace = WasmVm.allocateFunctionRefNamespace();
    final functions = <RuntimeFunction>[];
    final globals = <RuntimeGlobal>[];
    final globalTypes = <WasmGlobalType>[];
    final tables = <WasmTable>[];
    final memories = <WasmMemory>[];
    final tagTypes = <WasmTagImport>[];

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
          final syncCallback =
              callback ??
              (List<Object?> _) => throw UnsupportedError(
                'Async-only host import `${import.key}` is not available in '
                'the synchronous VM pipeline. Use invokeAsync on direct '
                'exported host functions.',
              );

          functions.add(
            HostRuntimeFunction(
              type: module.types[typeIndex],
              declaredTypeIndex: typeIndex,
              runtimeTypeDepth:
                  imports.functionTypeDepths[import.key] ??
                  _functionTypeDepth(module, typeIndex),
              callback: syncCallback,
              asyncCallback: asyncCallback,
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

          final expectedRefSignature = expected.refTypeSignature;
          final actualRefSignature = importedTable.refTypeSignature;
          final refTypeMatches =
              expectedRefSignature != null && actualRefSignature != null
              ? _referenceTypeSignaturesMatch(
                  expectedRefSignature,
                  actualRefSignature,
                )
              : importedTable.refType == expected.refType;
          if (!refTypeMatches) {
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
          if (importedMemory.isMemory64 != expected.isMemory64) {
            throw StateError(
              'Imported memory `${import.key}` index type mismatch: '
              'expected memory64=${expected.isMemory64} '
              'actual=${importedMemory.isMemory64}.',
            );
          }

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

          final importedBinding = imports.globalBindings[import.key];
          final hasImportedValue = imports.globals.containsKey(import.key);
          final importedValue = imports.globals[import.key];
          if (importedBinding == null && !hasImportedValue) {
            throw StateError('Missing global import `${import.key}`.');
          }

          final importedType =
              imports.globalTypes[import.key] ??
              (importedBinding == null
                  ? null
                  : WasmGlobalType(
                      valueType: importedBinding.valueType,
                      mutable: importedBinding.mutable,
                    ));
          if (importedType != null &&
              !_isGlobalImportTypeCompatible(
                expected: globalType,
                actual: importedType,
              )) {
            throw StateError(
              'Imported global `${import.key}` has incompatible import type.',
            );
          }

          if (importedBinding != null) {
            globals.add(importedBinding);
          } else {
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
          globalTypes.add(globalType);

        case WasmImportKind.tag:
          final tagType = import.tagType;
          if (tagType == null ||
              tagType.typeIndex < 0 ||
              tagType.typeIndex >= module.types.length ||
              !module.types[tagType.typeIndex].isFunctionType) {
            throw FormatException('Malformed tag import `${import.key}`.');
          }
          final importedTagType = imports.tags[import.key];
          if (importedTagType == null) {
            throw StateError('Missing tag import `${import.key}`.');
          }
          final expectedTagType = module.types[tagType.typeIndex];
          if (!_sameFunctionSignature(importedTagType.type, expectedTagType) ||
              importedTagType.typeKey !=
                  _tagNominalTypeKey(module, tagType.typeIndex)) {
            throw StateError(
              'Imported tag `${import.key}` has incompatible type.',
            );
          }
          tagTypes.add(importedTagType);
      }
    }
    final importedGlobals = List<RuntimeGlobal>.unmodifiable(globals);

    for (final memoryType in module.memories) {
      _validateSupportedMemoryType(
        memoryType,
        features: features,
        context: 'defined memory',
      );
      memories.add(
        WasmMemory(
          minPages: memoryType.minPages,
          maxPages: _runtimeMaxPagesForMemoryType(memoryType),
          shared: memoryType.shared,
          isMemory64: memoryType.isMemory64,
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
          refTypeSignature: tableType.refTypeSignature,
        ),
      );
    }

    for (final globalDef in module.globals) {
      final value = _evaluateConstExpr(
        globalDef.initExpr,
        globals,
        module.types,
        functionRefNamespace: functionRefNamespace,
      );
      globals.add(
        RuntimeGlobal(
          valueType: globalDef.type.valueType,
          mutable: globalDef.type.mutable,
          value: value,
        ),
      );
      globalTypes.add(globalDef.type);
    }
    for (
      var localTagIndex = 0;
      localTagIndex < module.tags.length;
      localTagIndex++
    ) {
      final tag = module.tags[localTagIndex];
      if (tag.typeIndex < 0 ||
          tag.typeIndex >= module.types.length ||
          !module.types[tag.typeIndex].isFunctionType) {
        throw FormatException('Invalid tag type index: ${tag.typeIndex}');
      }
      tagTypes.add(
        WasmTagImport(
          type: module.types[tag.typeIndex],
          nominalTypeKey:
              'inst:$functionRefNamespace:tag:${module.importedTagCount + localTagIndex}',
          typeKey: _tagNominalTypeKey(module, tag.typeIndex),
        ),
      );
    }
    for (var i = 0; i < module.tables.length; i++) {
      final initExpr = module.tables[i].initExpr;
      if (initExpr == null) {
        continue;
      }
      final tableIndex = module.importedTableCount + i;
      if (tableIndex < 0 || tableIndex >= tables.length) {
        throw FormatException(
          'Invalid table index for table initializer: $tableIndex',
        );
      }
      final initValue = _evaluateConstExpr(
        initExpr,
        importedGlobals,
        module.types,
        functionRefNamespace: functionRefNamespace,
      ).castTo(WasmValueType.i32).asI32();
      final refValue = initValue == -1 ? null : initValue;
      final table = tables[tableIndex];
      final fill = List<int?>.filled(table.length, refValue, growable: false);
      table.initialize(0, fill);
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
    final elementSegments = List<List<int?>?>.generate(module.elements.length, (
      index,
    ) {
      final segment = module.elements[index];
      if (!segment.isPassive) {
        return null;
      }
      final carriesFunctionRefs = _elementCarriesFunctionRefs(module, segment);
      return segment.functionIndices
          .map(
            (functionIndex) => functionIndex == null
                ? null
                : _resolveElementReference(
                    functionIndex,
                    carriesFunctionRefs: carriesFunctionRefs,
                    globals: globals,
                    functionCount: functions.length,
                    functionRefNamespace: functionRefNamespace,
                  ),
          )
          .toList(growable: false);
    }, growable: false);
    final elementSegmentRefTypeCodes = List<int>.generate(
      module.elements.length,
      (index) => module.elements[index].refTypeCode,
      growable: false,
    );

    final functionExports = <String, int>{};
    final globalExports = <String, int>{};
    final memoryExports = <String, WasmMemory>{};
    final tableExports = <String, WasmTable>{};
    final tagExports = <String, WasmTagImport>{};

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

        case WasmExportKind.tag:
          if (export.index < 0 || export.index >= tagTypes.length) {
            throw FormatException(
              'Export `${export.name}` has invalid tag index ${export.index}.',
            );
          }
          tagExports[export.name] = tagTypes[export.index];
      }
    }

    final instance = WasmInstance._(
      module: module,
      memories: List.unmodifiable(memories),
      tables: List.unmodifiable(tables),
      functions: List.unmodifiable(functions),
      globals: globals,
      globalTypes: List.unmodifiable(globalTypes),
      memory64ByIndex: memory64ByIndex,
      table64ByIndex: table64ByIndex,
      dataSegments: dataSegments,
      elementSegments: elementSegments,
      elementSegmentRefTypeCodes: elementSegmentRefTypeCodes,
      functionRefNamespace: functionRefNamespace,
      tagTypes: List<WasmFunctionType>.unmodifiable(
        tagTypes.map((tag) => tag.type),
      ),
      tagNominalTypeKeys: List<String>.unmodifiable(
        tagTypes.map((tag) => tag.nominalTypeKey),
      ),
      functionExports: Map.unmodifiable(functionExports),
      globalExports: Map.unmodifiable(globalExports),
      memoryExports: Map.unmodifiable(memoryExports),
      tableExports: Map.unmodifiable(tableExports),
      tagExports: Map.unmodifiable(tagExports),
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

  List<String> get exportedTags => _tagExports.keys.toList(growable: false);

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

  int exportedFunctionTypeIndex(String exportName) {
    final functionIndex = _functionExports[exportName];
    if (functionIndex == null) {
      throw ArgumentError.value(
        exportName,
        'exportName',
        'Function export not found',
      );
    }
    return functions[functionIndex].declaredTypeIndex;
  }

  WasmGlobalType exportedGlobalType(String exportName) {
    final globalIndex = _globalExports[exportName];
    if (globalIndex == null) {
      throw ArgumentError.value(
        exportName,
        'exportName',
        'Global export not found',
      );
    }
    return _globalTypes[globalIndex];
  }

  RuntimeGlobal exportedGlobalBinding(String exportName) {
    final globalIndex = _globalExports[exportName];
    if (globalIndex == null) {
      throw ArgumentError.value(
        exportName,
        'exportName',
        'Global export not found',
      );
    }
    return globals[globalIndex];
  }

  WasmFunctionType exportedTagType(String exportName) {
    final tagType = _tagExports[exportName];
    if (tagType == null) {
      throw ArgumentError.value(
        exportName,
        'exportName',
        'Tag export not found',
      );
    }
    return tagType.type;
  }

  WasmTagImport exportedTagImport(String exportName) {
    final tagImport = _tagExports[exportName];
    if (tagImport == null) {
      throw ArgumentError.value(
        exportName,
        'exportName',
        'Tag export not found',
      );
    }
    return tagImport;
  }

  Object? invoke(String exportName, [List<Object?> args = const []]) {
    final prepared = _prepareInvoke(exportName, args);
    final results = _vm.invokeFunction(
      prepared.functionIndex,
      prepared.typedArgs,
    );
    return _externalizeResults(results);
  }

  Future<Object?> invokeAsync(
    String exportName, [
    List<Object?> args = const [],
  ]) async {
    final prepared = _prepareInvoke(exportName, args);
    final function = functions[prepared.functionIndex];
    if (function is HostRuntimeFunction && function.asyncCallback != null) {
      final externalArgs = prepared.typedArgs
          .map((value) => value.toExternal())
          .toList(growable: false);
      final hostResult = await Future<Object?>.sync(
        () => function.asyncCallback!(externalArgs),
      );
      final results = WasmValue.decodeResults(
        function.type.results,
        hostResult,
      );
      return _externalizeResults(results);
    }
    try {
      return invoke(exportName, args);
    } on UnsupportedError catch (error) {
      final message = error.message?.toString() ?? '';
      if (message.contains('Async-only host import')) {
        if (function is DefinedRuntimeFunction) {
          try {
            final results = await _invokeFunctionAsyncSubset(
              prepared.functionIndex,
              prepared.typedArgs,
              depth: 0,
            );
            return _externalizeResults(results);
          } on UnsupportedError {
            throw UnsupportedError(
              'invokeAsync for wasm-defined functions that call async-only '
              'host imports is not implemented yet.',
            );
          }
        }
        throw UnsupportedError(
          'invokeAsync for wasm-defined functions that call async-only host '
          'imports is not implemented yet.',
        );
      }
      rethrow;
    }
  }

  ({int functionIndex, List<WasmValue> typedArgs}) _prepareInvoke(
    String exportName,
    List<Object?> args,
  ) {
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
    return (functionIndex: functionIndex, typedArgs: typedArgs);
  }

  Future<List<WasmValue>> _invokeFunctionAsyncSubset(
    int functionIndex,
    List<WasmValue> args, {
    required int depth,
  }) async {
    if (depth > _vm.maxCallDepth) {
      throw StateError('Call stack overflow (depth > ${_vm.maxCallDepth}).');
    }
    if (functionIndex < 0 || functionIndex >= functions.length) {
      throw RangeError('Invalid function index: $functionIndex');
    }

    final function = functions[functionIndex];
    final normalizedArgs = _normalizeArgsForType(args, function.type.params);
    if (function is HostRuntimeFunction) {
      final externalArgs = normalizedArgs
          .map((value) => value.toExternal())
          .toList(growable: false);
      final hostResult = function.asyncCallback != null
          ? await Future<Object?>.sync(
              () => function.asyncCallback!(externalArgs),
            )
          : function.callback(externalArgs);
      return WasmValue.decodeResults(function.type.results, hostResult);
    }

    final defined = function as DefinedRuntimeFunction;
    final locals = <WasmValue>[...normalizedArgs];
    for (final localType in defined.localTypes) {
      locals.add(WasmValue.zeroForType(localType));
    }
    final stack = <WasmValue>[];
    final instructions = defined.instructions;
    final memory64ByIndex = _memory64ByIndex(module);
    final controlStack = <_AsyncSubsetControlFrame>[];
    var pc = 0;
    while (pc < instructions.length) {
      final instruction = instructions[pc];
      switch (instruction.opcode) {
        case Opcodes.nop:
          pc++;

        case Opcodes.localGet:
          final index = instruction.immediate!;
          if (index < 0 || index >= locals.length) {
            throw RangeError('local.get index out of range: $index');
          }
          stack.add(locals[index]);
          pc++;

        case Opcodes.localSet:
          final index = instruction.immediate!;
          if (index < 0 || index >= locals.length) {
            throw RangeError('local.set index out of range: $index');
          }
          final value = _popValue(stack, 'local.set');
          locals[index] = value.castTo(locals[index].type);
          pc++;

        case Opcodes.localTee:
          final index = instruction.immediate!;
          if (index < 0 || index >= locals.length) {
            throw RangeError('local.tee index out of range: $index');
          }
          final value = _popValue(stack, 'local.tee');
          final cast = value.castTo(locals[index].type);
          locals[index] = cast;
          stack.add(cast);
          pc++;

        case Opcodes.drop:
          _popValue(stack, 'drop');
          pc++;

        case Opcodes.i32Const:
          stack.add(WasmValue.i32(instruction.immediate!));
          pc++;

        case Opcodes.i64Const:
          final wideImmediate = instruction.wideImmediate;
          if (wideImmediate == null) {
            throw StateError('Malformed i64.const immediate.');
          }
          stack.add(WasmValue.i64(wideImmediate));
          pc++;

        case Opcodes.f32Const:
          final floatBytes = instruction.floatBytesImmediate;
          if (floatBytes != null && floatBytes.length == 4) {
            final bits = ByteData.sublistView(
              floatBytes,
            ).getUint32(0, Endian.little);
            stack.add(WasmValue.f32Bits(bits));
          } else {
            stack.add(WasmValue.f32(instruction.floatImmediate!));
          }
          pc++;

        case Opcodes.f64Const:
          final floatBytes = instruction.floatBytesImmediate;
          if (floatBytes != null && floatBytes.length == 8) {
            final data = ByteData.sublistView(floatBytes);
            final low = data.getUint32(0, Endian.little);
            final high = data.getUint32(4, Endian.little);
            stack.add(
              WasmValue.f64Bits(
                WasmI64.fromU32PairUnsigned(low: low, high: high),
              ),
            );
          } else {
            stack.add(WasmValue.f64(instruction.floatImmediate!));
          }
          pc++;

        case Opcodes.i32Eqz:
          final value = _popValue(stack, 'i32.eqz').castTo(WasmValueType.i32);
          stack.add(WasmValue.i32(value.asI32() == 0 ? 1 : 0));
          pc++;

        case Opcodes.i32Eq:
          final rhs = _popValue(stack, 'i32.eq rhs').castTo(WasmValueType.i32);
          final lhs = _popValue(stack, 'i32.eq lhs').castTo(WasmValueType.i32);
          stack.add(WasmValue.i32(lhs.asI32() == rhs.asI32() ? 1 : 0));
          pc++;

        case Opcodes.i32Ne:
          final rhs = _popValue(stack, 'i32.ne rhs').castTo(WasmValueType.i32);
          final lhs = _popValue(stack, 'i32.ne lhs').castTo(WasmValueType.i32);
          stack.add(WasmValue.i32(lhs.asI32() != rhs.asI32() ? 1 : 0));
          pc++;

        case Opcodes.i32Add:
          final rhs = _popValue(stack, 'i32.add rhs').castTo(WasmValueType.i32);
          final lhs = _popValue(stack, 'i32.add lhs').castTo(WasmValueType.i32);
          stack.add(WasmValue.i32(lhs.asI32() + rhs.asI32()));
          pc++;

        case Opcodes.i32Sub:
          final rhs = _popValue(stack, 'i32.sub rhs').castTo(WasmValueType.i32);
          final lhs = _popValue(stack, 'i32.sub lhs').castTo(WasmValueType.i32);
          stack.add(WasmValue.i32(lhs.asI32() - rhs.asI32()));
          pc++;

        case Opcodes.i32Mul:
          final rhs = _popValue(stack, 'i32.mul rhs').castTo(WasmValueType.i32);
          final lhs = _popValue(stack, 'i32.mul lhs').castTo(WasmValueType.i32);
          stack.add(WasmValue.i32(lhs.asI32() * rhs.asI32()));
          pc++;

        case Opcodes.i32And:
          final rhs = _popValue(stack, 'i32.and rhs').castTo(WasmValueType.i32);
          final lhs = _popValue(stack, 'i32.and lhs').castTo(WasmValueType.i32);
          stack.add(WasmValue.i32(lhs.asI32() & rhs.asI32()));
          pc++;

        case Opcodes.i32Or:
          final rhs = _popValue(stack, 'i32.or rhs').castTo(WasmValueType.i32);
          final lhs = _popValue(stack, 'i32.or lhs').castTo(WasmValueType.i32);
          stack.add(WasmValue.i32(lhs.asI32() | rhs.asI32()));
          pc++;

        case Opcodes.i32Xor:
          final rhs = _popValue(stack, 'i32.xor rhs').castTo(WasmValueType.i32);
          final lhs = _popValue(stack, 'i32.xor lhs').castTo(WasmValueType.i32);
          stack.add(WasmValue.i32(lhs.asI32() ^ rhs.asI32()));
          pc++;

        case Opcodes.i64Add:
          final rhs = _popValue(stack, 'i64.add rhs').castTo(WasmValueType.i64);
          final lhs = _popValue(stack, 'i64.add lhs').castTo(WasmValueType.i64);
          stack.add(WasmValue.i64(lhs.asI64() + rhs.asI64()));
          pc++;

        case Opcodes.i64Sub:
          final rhs = _popValue(stack, 'i64.sub rhs').castTo(WasmValueType.i64);
          final lhs = _popValue(stack, 'i64.sub lhs').castTo(WasmValueType.i64);
          stack.add(WasmValue.i64(lhs.asI64() - rhs.asI64()));
          pc++;

        case Opcodes.i64Mul:
          final rhs = _popValue(stack, 'i64.mul rhs').castTo(WasmValueType.i64);
          final lhs = _popValue(stack, 'i64.mul lhs').castTo(WasmValueType.i64);
          stack.add(WasmValue.i64(lhs.asI64() * rhs.asI64()));
          pc++;

        case Opcodes.f32Add:
          final rhs = _popValue(stack, 'f32.add rhs').castTo(WasmValueType.f32);
          final lhs = _popValue(stack, 'f32.add lhs').castTo(WasmValueType.f32);
          stack.add(WasmValue.f32(lhs.asF32() + rhs.asF32()));
          pc++;

        case Opcodes.f32Sub:
          final rhs = _popValue(stack, 'f32.sub rhs').castTo(WasmValueType.f32);
          final lhs = _popValue(stack, 'f32.sub lhs').castTo(WasmValueType.f32);
          stack.add(WasmValue.f32(lhs.asF32() - rhs.asF32()));
          pc++;

        case Opcodes.f32Mul:
          final rhs = _popValue(stack, 'f32.mul rhs').castTo(WasmValueType.f32);
          final lhs = _popValue(stack, 'f32.mul lhs').castTo(WasmValueType.f32);
          stack.add(WasmValue.f32(lhs.asF32() * rhs.asF32()));
          pc++;

        case Opcodes.f32Div:
          final rhs = _popValue(stack, 'f32.div rhs').castTo(WasmValueType.f32);
          final lhs = _popValue(stack, 'f32.div lhs').castTo(WasmValueType.f32);
          stack.add(WasmValue.f32(lhs.asF32() / rhs.asF32()));
          pc++;

        case Opcodes.f64Add:
          final rhs = _popValue(stack, 'f64.add rhs').castTo(WasmValueType.f64);
          final lhs = _popValue(stack, 'f64.add lhs').castTo(WasmValueType.f64);
          stack.add(WasmValue.f64(lhs.asF64() + rhs.asF64()));
          pc++;

        case Opcodes.f64Sub:
          final rhs = _popValue(stack, 'f64.sub rhs').castTo(WasmValueType.f64);
          final lhs = _popValue(stack, 'f64.sub lhs').castTo(WasmValueType.f64);
          stack.add(WasmValue.f64(lhs.asF64() - rhs.asF64()));
          pc++;

        case Opcodes.f64Mul:
          final rhs = _popValue(stack, 'f64.mul rhs').castTo(WasmValueType.f64);
          final lhs = _popValue(stack, 'f64.mul lhs').castTo(WasmValueType.f64);
          stack.add(WasmValue.f64(lhs.asF64() * rhs.asF64()));
          pc++;

        case Opcodes.f64Div:
          final rhs = _popValue(stack, 'f64.div rhs').castTo(WasmValueType.f64);
          final lhs = _popValue(stack, 'f64.div lhs').castTo(WasmValueType.f64);
          stack.add(WasmValue.f64(lhs.asF64() / rhs.asF64()));
          pc++;

        case Opcodes.memorySize:
          final memoryIndex = instruction.immediate ?? 0;
          if (memoryIndex < 0 || memoryIndex >= memories.length) {
            throw RangeError('memory.size index out of range: $memoryIndex');
          }
          final isMemory64 =
              memoryIndex >= 0 &&
              memoryIndex < memory64ByIndex.length &&
              memory64ByIndex[memoryIndex];
          final pages = memories[memoryIndex].pageCount;
          stack.add(isMemory64 ? WasmValue.i64(pages) : WasmValue.i32(pages));
          pc++;

        case Opcodes.memoryGrow:
          final memoryIndex = instruction.immediate ?? 0;
          if (memoryIndex < 0 || memoryIndex >= memories.length) {
            throw RangeError('memory.grow index out of range: $memoryIndex');
          }
          final isMemory64 =
              memoryIndex >= 0 &&
              memoryIndex < memory64ByIndex.length &&
              memory64ByIndex[memoryIndex];
          final deltaValue = isMemory64
              ? _popValue(
                  stack,
                  'memory.grow delta',
                ).castTo(WasmValueType.i64).asI64()
              : BigInt.from(
                  _popValue(
                    stack,
                    'memory.grow delta',
                  ).castTo(WasmValueType.i32).asI32(),
                );
          final deltaPages = _coerceAsyncSubsetPageDelta(
            deltaValue,
            context: 'memory.grow',
          );
          final oldPages = memories[memoryIndex].grow(deltaPages);
          stack.add(
            isMemory64 ? WasmValue.i64(oldPages) : WasmValue.i32(oldPages),
          );
          pc++;

        case Opcodes.block:
          final endIndex = instruction.endIndex;
          if (endIndex == null) {
            throw StateError('Malformed block without end index.');
          }
          final parameterTypes =
              instruction.blockParameterTypes ?? const <WasmValueType>[];
          final params = _popArgsForTypes(
            stack,
            parameterTypes,
            context: 'block',
          );
          final baseHeight = stack.length;
          stack.addAll(params);
          controlStack.add(
            _AsyncSubsetControlFrame(
              kind: _AsyncSubsetControlKind.block,
              stackBaseHeight: baseHeight,
              startIndex: pc,
              endIndex: endIndex,
              parameterTypes: parameterTypes,
              resultTypes:
                  instruction.blockResultTypes ?? const <WasmValueType>[],
            ),
          );
          pc++;

        case Opcodes.loop:
          final endIndex = instruction.endIndex;
          if (endIndex == null) {
            throw StateError('Malformed loop without end index.');
          }
          final parameterTypes =
              instruction.blockParameterTypes ?? const <WasmValueType>[];
          final params = _popArgsForTypes(
            stack,
            parameterTypes,
            context: 'loop',
          );
          final baseHeight = stack.length;
          stack.addAll(params);
          controlStack.add(
            _AsyncSubsetControlFrame(
              kind: _AsyncSubsetControlKind.loop,
              stackBaseHeight: baseHeight,
              startIndex: pc,
              endIndex: endIndex,
              parameterTypes: parameterTypes,
              resultTypes:
                  instruction.blockResultTypes ?? const <WasmValueType>[],
            ),
          );
          pc++;

        case Opcodes.if_:
          final endIndex = instruction.endIndex;
          if (endIndex == null) {
            throw StateError('Malformed if without end index.');
          }
          final condition = _popValue(
            stack,
            'if condition',
          ).castTo(WasmValueType.i32).asI32();
          final parameterTypes =
              instruction.blockParameterTypes ?? const <WasmValueType>[];
          final params = _popArgsForTypes(stack, parameterTypes, context: 'if');
          final baseHeight = stack.length;
          stack.addAll(params);
          final frame = _AsyncSubsetControlFrame(
            kind: _AsyncSubsetControlKind.if_,
            stackBaseHeight: baseHeight,
            startIndex: pc,
            endIndex: endIndex,
            parameterTypes: parameterTypes,
            resultTypes:
                instruction.blockResultTypes ?? const <WasmValueType>[],
          );
          controlStack.add(frame);
          if (condition == 0) {
            stack.length = baseHeight;
            final elseIndex = instruction.elseIndex;
            if (elseIndex != null) {
              pc = elseIndex + 1;
            } else {
              controlStack.removeLast();
              pc = endIndex + 1;
            }
          } else {
            pc++;
          }

        case Opcodes.else_:
          if (controlStack.isEmpty ||
              controlStack.last.kind != _AsyncSubsetControlKind.if_) {
            throw const FormatException('`else` without matching `if`.');
          }
          final frame = controlStack.removeLast();
          _leaveAsyncSubsetControlFrame(stack, frame, context: 'else');
          final endIndex = instruction.endIndex;
          if (endIndex == null) {
            throw StateError('Malformed else without end index.');
          }
          pc = endIndex + 1;

        case Opcodes.end:
          if (controlStack.isEmpty) {
            return _collectAsyncSubsetResults(
              stack,
              function.type.results,
              context: 'end',
            );
          }
          final frame = controlStack.removeLast();
          _leaveAsyncSubsetControlFrame(stack, frame, context: 'end');
          pc++;

        case Opcodes.br:
          pc = _branchInAsyncSubset(
            depth: instruction.immediate!,
            stack: stack,
            controlStack: controlStack,
            context: 'br',
          );

        case Opcodes.brIf:
          final condition = _popValue(
            stack,
            'br_if condition',
          ).castTo(WasmValueType.i32).asI32();
          if (condition != 0) {
            pc = _branchInAsyncSubset(
              depth: instruction.immediate!,
              stack: stack,
              controlStack: controlStack,
              context: 'br_if',
            );
          } else {
            pc++;
          }

        case Opcodes.call:
          final targetIndex = instruction.immediate!;
          if (targetIndex < 0 || targetIndex >= functions.length) {
            throw RangeError('call target out of range: $targetIndex');
          }
          final target = functions[targetIndex];
          final callArgs = _popArgsForTypes(
            stack,
            target.type.params,
            context: 'call',
          );
          final callResults = await _invokeFunctionAsyncSubset(
            targetIndex,
            callArgs,
            depth: depth + 1,
          );
          stack.addAll(callResults);
          pc++;

        case Opcodes.returnCall:
          final targetIndex = instruction.immediate!;
          if (targetIndex < 0 || targetIndex >= functions.length) {
            throw RangeError('return_call target out of range: $targetIndex');
          }
          final target = functions[targetIndex];
          final callArgs = _popArgsForTypes(
            stack,
            target.type.params,
            context: 'return_call',
          );
          return _invokeFunctionAsyncSubset(
            targetIndex,
            callArgs,
            depth: depth + 1,
          );

        case Opcodes.return_:
          return _collectAsyncSubsetResults(
            stack,
            function.type.results,
            context: 'return',
          );

        default:
          throw UnsupportedError(
            'invokeAsync subset does not support opcode '
            '0x${instruction.opcode.toRadixString(16)}',
          );
      }
    }

    throw StateError(
      'Function execution ended without `end` in invokeAsync subset.',
    );
  }

  void _leaveAsyncSubsetControlFrame(
    List<WasmValue> stack,
    _AsyncSubsetControlFrame frame, {
    required String context,
  }) {
    final results = _popArgsForTypes(
      stack,
      frame.resultTypes,
      context: '$context control-result',
    );
    if (stack.length != frame.stackBaseHeight) {
      throw StateError(
        '$context stack height mismatch: expected ${frame.stackBaseHeight}, '
        'has ${stack.length}.',
      );
    }
    stack.addAll(results);
  }

  int _branchInAsyncSubset({
    required int depth,
    required List<WasmValue> stack,
    required List<_AsyncSubsetControlFrame> controlStack,
    required String context,
  }) {
    if (depth < 0 || depth >= controlStack.length) {
      throw RangeError(
        '$context depth out of range: $depth (labels=${controlStack.length})',
      );
    }

    final targetIndex = controlStack.length - 1 - depth;
    final target = controlStack[targetIndex];
    final branchValues = _popArgsForTypes(
      stack,
      target.branchTypes,
      context: '$context depth=$depth',
    );
    if (stack.length < target.stackBaseHeight) {
      throw StateError(
        '$context stack height underflow for target depth $depth: '
        'base=${target.stackBaseHeight}, has=${stack.length}.',
      );
    }
    stack.length = target.stackBaseHeight;
    stack.addAll(branchValues);

    if (target.kind == _AsyncSubsetControlKind.loop) {
      controlStack.removeRange(targetIndex + 1, controlStack.length);
      return target.startIndex + 1;
    }

    controlStack.removeRange(targetIndex, controlStack.length);
    return target.endIndex + 1;
  }

  int _coerceAsyncSubsetPageDelta(BigInt value, {required String context}) {
    if (value < BigInt.zero) {
      throw RangeError('$context expects non-negative page delta, got $value');
    }
    final max = BigInt.from(0x7fffffff);
    if (value > max) {
      throw RangeError(
        '$context page delta too large for host memory API: $value',
      );
    }
    return value.toInt();
  }

  List<WasmValue> _normalizeArgsForType(
    List<WasmValue> args,
    List<WasmValueType> paramTypes,
  ) {
    if (args.length != paramTypes.length) {
      throw ArgumentError(
        'Function expects ${paramTypes.length} args, got ${args.length}.',
      );
    }
    final normalized = <WasmValue>[];
    for (var i = 0; i < paramTypes.length; i++) {
      normalized.add(args[i].castTo(paramTypes[i]));
    }
    return normalized;
  }

  List<WasmValue> _popArgsForTypes(
    List<WasmValue> stack,
    List<WasmValueType> paramTypes, {
    required String context,
  }) {
    if (stack.length < paramTypes.length) {
      throw StateError(
        '$context stack underflow: needs ${paramTypes.length}, '
        'has ${stack.length}.',
      );
    }
    final args = List<WasmValue>.filled(
      paramTypes.length,
      WasmValue.i32(0),
      growable: false,
    );
    for (var i = paramTypes.length - 1; i >= 0; i--) {
      args[i] = _popValue(stack, '$context arg[$i]').castTo(paramTypes[i]);
    }
    return args;
  }

  WasmValue _popValue(List<WasmValue> stack, String context) {
    if (stack.isEmpty) {
      throw StateError('$context stack underflow.');
    }
    return stack.removeLast();
  }

  List<WasmValue> _collectAsyncSubsetResults(
    List<WasmValue> stack,
    List<WasmValueType> resultTypes, {
    required String context,
  }) {
    if (stack.length < resultTypes.length) {
      throw StateError(
        '$context result underflow: needs ${resultTypes.length}, '
        'has ${stack.length}.',
      );
    }
    if (stack.length != resultTypes.length) {
      throw StateError(
        '$context stack height mismatch: expected ${resultTypes.length}, '
        'has ${stack.length}.',
      );
    }
    final results = <WasmValue>[];
    for (var i = 0; i < resultTypes.length; i++) {
      results.add(stack[i].castTo(resultTypes[i]));
    }
    return results;
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

  static int? _resolveElementReference(
    int rawReference, {
    required bool carriesFunctionRefs,
    required List<RuntimeGlobal> globals,
    required int functionCount,
    required int functionRefNamespace,
  }) {
    final globalIndex = WasmModule.decodeElementGlobalRef(
      rawReference,
      globalCount: globals.length,
    );
    if (globalIndex != null) {
      final globalRaw = globals[globalIndex].value
          .castTo(WasmValueType.i32)
          .asI32();
      if (globalRaw == -1) {
        return null;
      }
      if (carriesFunctionRefs && globalRaw >= 0 && globalRaw < functionCount) {
        return WasmVm.functionRefIdFor(
          namespace: functionRefNamespace,
          functionIndex: globalRaw,
        );
      }
      return globalRaw;
    }
    if (!carriesFunctionRefs) {
      return rawReference;
    }
    if (rawReference < 0) {
      return rawReference;
    }
    return WasmVm.functionRefIdFor(
      namespace: functionRefNamespace,
      functionIndex: rawReference,
    );
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

      final carriesFunctionRefs = _elementCarriesFunctionRefs(module, element);
      if (carriesFunctionRefs) {
        for (final functionIndex in element.functionIndices) {
          if (functionIndex == null) {
            continue;
          }
          if (functionIndex < 0) {
            continue;
          }
          if (functionIndex >= functions.length) {
            throw FormatException(
              'Invalid function index in element: $functionIndex',
            );
          }
        }
      }

      final initializedRefs = element.functionIndices
          .map(
            (functionIndex) => functionIndex == null
                ? null
                : _resolveElementReference(
                    functionIndex,
                    carriesFunctionRefs: carriesFunctionRefs,
                    globals: globals,
                    functionCount: functions.length,
                    functionRefNamespace: _functionRefNamespace,
                  ),
          )
          .toList(growable: false);
      table.initialize(offset, initializedRefs);
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
    List<WasmFunctionType> types, {
    int? functionRefNamespace,
  }) {
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
          stack.add(WasmValue.i64(reader.readVarInt64Value()));

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
          final functionIndex = reader.readVarUint32();
          final functionRef = functionRefNamespace == null
              ? functionIndex
              : WasmVm.functionRefIdFor(
                  namespace: functionRefNamespace,
                  functionIndex: functionIndex,
                );
          stack.add(WasmValue.i32(functionRef));

        case 0xfd:
          final subOpcode = reader.readVarUint32();
          final pseudoOpcode = 0xfd00 | subOpcode;
          switch (pseudoOpcode) {
            case Opcodes.v128Const:
              stack.add(
                WasmValue.i32(WasmVm.internV128Bytes(reader.readBytes(16))),
              );
            default:
              throw UnsupportedError(
                'Unsupported const expr opcode: 0x${pseudoOpcode.toRadixString(16)}',
              );
          }

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
                  for (
                    var fieldIndex = fields.length - 1;
                    fieldIndex >= 0;
                    fieldIndex--
                  ) {
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
                  for (
                    var fieldIndex = fields.length - 1;
                    fieldIndex >= 0;
                    fieldIndex--
                  ) {
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
                  for (
                    var elementIndex = elementCount - 1;
                    elementIndex >= 0;
                    elementIndex--
                  ) {
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
              final value =
                  pop().castTo(WasmValueType.i32).asI32() & 0x7fffffff;
              stack.add(WasmValue.i32(WasmVm.allocateConstI31Ref(value)));
            case Opcodes.anyConvertExtern:
            case Opcodes.externConvertAny:
              final reference = pop().castTo(WasmValueType.i32).asI32();
              stack.add(WasmValue.i32(reference));
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

  static bool _isGlobalImportTypeCompatible({
    required WasmGlobalType expected,
    required WasmGlobalType actual,
  }) {
    if (expected.mutable != actual.mutable) {
      return false;
    }

    final expectedSignature = expected.valueTypeSignature;
    final actualSignature = actual.valueTypeSignature;
    final expectedIsNumeric = _isNumericValueTypeSignature(expectedSignature);
    final actualIsNumeric = _isNumericValueTypeSignature(actualSignature);

    if (expectedIsNumeric || actualIsNumeric) {
      if (expectedSignature != null && actualSignature != null) {
        return expectedSignature == actualSignature;
      }
      return expected.valueType == actual.valueType;
    }

    if (expectedSignature != null && actualSignature != null) {
      final expectedRef = _parseReferenceGlobalType(expectedSignature);
      final actualRef = _parseReferenceGlobalType(actualSignature);
      if (expectedRef != null && actualRef != null) {
        if (expected.mutable) {
          return _referenceGlobalTypeEquals(expectedRef, actualRef);
        }
        return _isReferenceGlobalSubtype(
          actual: actualRef,
          expected: expectedRef,
        );
      }
      if (expected.mutable) {
        return expectedSignature == actualSignature;
      }
    }

    return expected.valueType == actual.valueType;
  }

  static bool _isNumericValueTypeSignature(String? signature) {
    return signature == '7f' ||
        signature == '7e' ||
        signature == '7d' ||
        signature == '7c';
  }

  static ({bool nullable, String kind, String? typeKey})?
  _parseReferenceGlobalType(String signature) {
    final bytes = _signatureBytes(signature);
    if (bytes.isEmpty) {
      return null;
    }

    final first = bytes.first;
    if (bytes.length == 1) {
      return switch (first) {
        0x70 => (nullable: true, kind: 'func', typeKey: null),
        0x6f => (nullable: true, kind: 'extern', typeKey: null),
        _ => null,
      };
    }

    if (first != 0x63 && first != 0x64) {
      return null;
    }

    final nullable = first == 0x63;
    final heapBytes = bytes.sublist(1);
    if (heapBytes.isEmpty) {
      return null;
    }

    if (heapBytes.length == 1) {
      final heapCode = heapBytes.first;
      switch (heapCode) {
        case 0x70:
          return (nullable: nullable, kind: 'func', typeKey: null);
        case 0x6f:
          return (nullable: nullable, kind: 'extern', typeKey: null);
      }
      if (heapCode >= 0x65 && heapCode <= 0x73) {
        return (
          nullable: nullable,
          kind: 'other:${_bytesToSignature(heapBytes)}',
          typeKey: null,
        );
      }
    }

    final heapReader = ByteReader(Uint8List.fromList(heapBytes));
    final heapType = _readSignedLeb33WithFirst(
      heapReader,
      heapReader.readByte(),
    );
    if (!heapReader.isEOF) {
      return (
        nullable: nullable,
        kind: 'other:${_bytesToSignature(heapBytes)}',
        typeKey: null,
      );
    }

    if (heapType >= 0) {
      return (
        nullable: nullable,
        kind: 'typed-func',
        typeKey: _bytesToSignature(heapBytes),
      );
    }

    return switch (heapType) {
      -16 => (nullable: nullable, kind: 'func', typeKey: null),
      -17 => (nullable: nullable, kind: 'extern', typeKey: null),
      _ => (
        nullable: nullable,
        kind: 'other:${_bytesToSignature(heapBytes)}',
        typeKey: null,
      ),
    };
  }

  static bool _referenceGlobalTypeEquals(
    ({bool nullable, String kind, String? typeKey}) lhs,
    ({bool nullable, String kind, String? typeKey}) rhs,
  ) {
    return lhs.nullable == rhs.nullable &&
        lhs.kind == rhs.kind &&
        lhs.typeKey == rhs.typeKey;
  }

  static bool _referenceTypeSignaturesMatch(String expected, String actual) {
    final expectedRef = _parseReferenceGlobalType(expected);
    final actualRef = _parseReferenceGlobalType(actual);
    if (expectedRef != null && actualRef != null) {
      return _referenceGlobalTypeEquals(expectedRef, actualRef);
    }
    return expected == actual;
  }

  static bool _elementCarriesFunctionRefs(
    WasmModule module,
    WasmElementSegment segment,
  ) {
    if (segment.usesLegacyFunctionIndices ||
        segment.refTypeCode == 0x70 ||
        segment.refTypeCode == 0x73) {
      return true;
    }

    final signature = segment.refTypeSignature;
    if (signature == null || signature.isEmpty) {
      return false;
    }
    final parsed = _parseReferenceGlobalType(signature);
    if (parsed == null) {
      return false;
    }
    if (parsed.kind == 'func') {
      return true;
    }
    if (parsed.kind != 'typed-func') {
      return false;
    }
    final typeKey = parsed.typeKey;
    if (typeKey == null || typeKey.isEmpty) {
      return false;
    }
    final typeBytes = _signatureBytes(typeKey);
    if (typeBytes.isEmpty) {
      return false;
    }
    final heapReader = ByteReader(Uint8List.fromList(typeBytes));
    final heapType = _readSignedLeb33WithFirst(
      heapReader,
      heapReader.readByte(),
    );
    if (!heapReader.isEOF || heapType < 0 || heapType >= module.types.length) {
      return false;
    }
    return module.types[heapType].isFunctionType;
  }

  static bool _isReferenceGlobalSubtype({
    required ({bool nullable, String kind, String? typeKey}) actual,
    required ({bool nullable, String kind, String? typeKey}) expected,
  }) {
    if (actual.nullable && !expected.nullable) {
      return false;
    }

    if (actual.kind == expected.kind) {
      if (actual.kind == 'typed-func') {
        return actual.typeKey == expected.typeKey;
      }
      return true;
    }

    if (actual.kind == 'typed-func' && expected.kind == 'func') {
      return true;
    }

    return false;
  }

  static List<int> _signatureBytes(String signature) {
    if (signature.isEmpty || signature.length.isOdd) {
      return const <int>[];
    }
    final bytes = <int>[];
    for (var i = 0; i < signature.length; i += 2) {
      bytes.add(int.parse(signature.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  static String _bytesToSignature(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write((byte & 0xff).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
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
    final maxPagesPerAddress = _maxPagesPerAddressType(memoryType);
    if (BigInt.from(memoryType.minPages) > maxPagesPerAddress) {
      throw FormatException(
        '$context exceeds canonical memory size limits: '
        'minPages=${memoryType.minPages}, '
        'maxPagesPerAddress=$maxPagesPerAddress.',
      );
    }
    final declaredMax = memoryType.maxPages;
    if (declaredMax != null && BigInt.from(declaredMax) > maxPagesPerAddress) {
      throw FormatException(
        '$context exceeds canonical memory size limits: '
        'maxPages=$declaredMax, maxPagesPerAddress=$maxPagesPerAddress.',
      );
    }
    final maxPagesSupported = wasmAddressSpaceBytes ~/ pageSizeBytes;
    if (memoryType.minPages > maxPagesSupported) {
      throw UnsupportedError(
        '$context exceeds runtime memory capacity: minPages=${memoryType.minPages}, '
        'maxSupportedPages=$maxPagesSupported.',
      );
    }
    if (declaredMax != null &&
        declaredMax > maxPagesSupported &&
        !memoryType.isMemory64) {
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

  static BigInt _maxPagesPerAddressType(WasmMemoryType memoryType) {
    final addressBits = memoryType.isMemory64 ? 64 : 32;
    if (memoryType.pageSizeLog2 > addressBits) {
      return BigInt.zero;
    }
    return BigInt.one << (addressBits - memoryType.pageSizeLog2);
  }

  static int? _runtimeMaxPagesForMemoryType(WasmMemoryType memoryType) {
    final declaredMax = memoryType.maxPages;
    if (declaredMax == null) {
      return null;
    }
    final pageSizeBytes = 1 << memoryType.pageSizeLog2;
    final maxPagesSupported = wasmAddressSpaceBytes ~/ pageSizeBytes;
    if (declaredMax <= maxPagesSupported) {
      return declaredMax;
    }
    return memoryType.isMemory64 ? maxPagesSupported : declaredMax;
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

  static int _constExprTableOffset(WasmValue value, {required bool isTable64}) {
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

  static bool _sameFunctionSignature(WasmFunctionType a, WasmFunctionType b) {
    if (a.params.length != b.params.length ||
        a.results.length != b.results.length) {
      return false;
    }
    for (var i = 0; i < a.params.length; i++) {
      if (a.params[i] != b.params[i]) {
        return false;
      }
    }
    for (var i = 0; i < a.results.length; i++) {
      if (a.results[i] != b.results[i]) {
        return false;
      }
    }
    return true;
  }

  static String _tagNominalTypeKey(WasmModule module, int typeIndex) {
    if (typeIndex < 0 || typeIndex >= module.types.length) {
      return 'invalid';
    }
    final type = module.types[typeIndex];
    if (!type.isFunctionType) {
      return 'invalid';
    }
    final paramsKey = type.params.map((value) => value.index).join(',');
    final resultsKey = type.results.map((value) => value.index).join(',');
    final shape = '$paramsKey->$resultsKey';
    if (type.recGroupSize > 1) {
      return '$shape@${type.recGroupPosition}/${type.recGroupSize}';
    }
    return shape;
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
