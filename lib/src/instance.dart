import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'byte_reader.dart';
import 'features.dart';
import 'int64.dart';
import 'imports.dart';
import 'memory.dart';
import 'module.dart';
import 'opcode.dart';
import 'predecode.dart';
import 'runtime_control_ops.dart';
import 'runtime_function.dart';
import 'runtime_global.dart';
import 'runtime_ops.dart';
import 'runtime_stack_ops.dart';
import 'table.dart';
import 'validator.dart';
import 'value.dart';
import 'vm.dart';

enum _AsyncSubsetControlKind { block, loop, if_, tryLegacy }

final class _AsyncSubsetThrownException implements Exception {
  _AsyncSubsetThrownException({
    required this.nominalTypeKey,
    required this.values,
  });

  final String nominalTypeKey;
  final List<WasmValue> values;
}

final class _AsyncSubsetControlFrame {
  _AsyncSubsetControlFrame({
    required this.kind,
    required this.stackBaseHeight,
    required this.startIndex,
    required this.endIndex,
    required this.parameterTypes,
    required this.resultTypes,
    this.tryTableCatches,
    this.legacyCatches,
    this.delegateDepth,
  });

  final _AsyncSubsetControlKind kind;
  final int stackBaseHeight;
  final int startIndex;
  final int endIndex;
  final List<WasmValueType> parameterTypes;
  final List<WasmValueType> resultTypes;
  final List<TryTableCatchClause>? tryTableCatches;
  final List<LegacyCatchClause>? legacyCatches;
  final int? delegateDepth;
  _AsyncSubsetThrownException? activeException;
  int? activeCatchInstructionIndex;

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
       _tagTypes = tagTypes,
       _tagNominalTypeKeys = tagNominalTypeKeys,
       _globalTypes = globalTypes,
       _asyncDataSegments = dataSegments,
       _asyncElementSegments = elementSegments,
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
  final List<WasmFunctionType> _tagTypes;
  final List<String> _tagNominalTypeKeys;
  final List<WasmGlobalType> _globalTypes;
  final List<Uint8List?> _asyncDataSegments;
  final List<List<int?>?> _asyncElementSegments;
  final int _functionRefNamespace;
  final WasmVm _vm;
  final Map<int, _AsyncSubsetThrownException> _asyncExceptionObjects =
      <int, _AsyncSubsetThrownException>{};
  int _nextAsyncExceptionRef = 1;
  late final Map<int, int> _functionRefIdToIndex = _buildFunctionRefIdToIndex();

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
    final table64ByIndex = _table64ByIndex(module);
    final controlStack = <_AsyncSubsetControlFrame>[];
    var pc = 0;
    while (pc < instructions.length) {
      final instruction = instructions[pc];
      try {
        switch (instruction.opcode) {
          case Opcodes.unreachable:
            throw StateError('unreachable trap');

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

          case Opcodes.globalGet:
            final index = instruction.immediate!;
            if (index < 0 || index >= globals.length) {
              throw RangeError('global.get index out of range: $index');
            }
            stack.add(globals[index].value);
            pc++;

          case Opcodes.globalSet:
            final index = instruction.immediate!;
            if (index < 0 || index >= globals.length) {
              throw RangeError('global.set index out of range: $index');
            }
            final global = globals[index];
            if (!global.mutable) {
              throw StateError('Cannot mutate immutable global $index.');
            }
            final value = _popValue(
              stack,
              'global.set',
            ).castTo(global.valueType);
            global.setValue(value);
            pc++;

          case Opcodes.tableGet:
            final tableIndex = instruction.immediate!;
            if (tableIndex < 0 || tableIndex >= tables.length) {
              throw RangeError('table.get index out of range: $tableIndex');
            }
            final elementIndex = _popAsyncSubsetTableOperand(
              stack,
              tableIndex: tableIndex,
              table64ByIndex: table64ByIndex,
              context: 'table.get index',
            );
            final value = tables[tableIndex][elementIndex];
            stack.add(WasmValue.i32(value ?? -1));
            pc++;

          case Opcodes.tableSet:
            final tableIndex = instruction.immediate!;
            if (tableIndex < 0 || tableIndex >= tables.length) {
              throw RangeError('table.set index out of range: $tableIndex');
            }
            final value = _popAsyncSubsetRef(stack, context: 'table.set value');
            final elementIndex = _popAsyncSubsetTableOperand(
              stack,
              tableIndex: tableIndex,
              table64ByIndex: table64ByIndex,
              context: 'table.set index',
            );
            tables[tableIndex][elementIndex] = value;
            pc++;

          case Opcodes.drop:
            _popValue(stack, 'drop');
            pc++;

          case Opcodes.select:
          case Opcodes.selectT:
            final condition = _popValue(
              stack,
              'select condition',
            ).castTo(WasmValueType.i32).asI32();
            final falseValue = _popValue(stack, 'select false');
            final trueValue = _popValue(stack, 'select true');
            if (falseValue.type != trueValue.type) {
              throw StateError(
                'select operands must have the same value type.',
              );
            }
            stack.add(condition != 0 ? trueValue : falseValue);
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

          case Opcodes.refNull:
            stack.add(WasmValue.i32(-1));
            pc++;

          case Opcodes.refFunc:
            final targetIndex = instruction.immediate!;
            if (targetIndex < 0 || targetIndex >= functions.length) {
              throw RangeError('ref.func target out of range: $targetIndex');
            }
            stack.add(
              WasmValue.i32(
                WasmVm.functionRefIdFor(
                  namespace: _functionRefNamespace,
                  functionIndex: targetIndex,
                ),
              ),
            );
            pc++;

          case Opcodes.refIsNull:
            final reference = _popAsyncSubsetRef(
              stack,
              context: 'ref.is_null operand',
            );
            stack.add(WasmValue.i32(reference == null ? 1 : 0));
            pc++;

          case Opcodes.refEq:
            final rhs = _popAsyncSubsetRef(stack, context: 'ref.eq rhs');
            final lhs = _popAsyncSubsetRef(stack, context: 'ref.eq lhs');
            stack.add(WasmValue.i32(lhs == rhs ? 1 : 0));
            pc++;

          case Opcodes.refAsNonNull:
            final reference = _popAsyncSubsetRef(
              stack,
              context: 'ref.as_non_null operand',
            );
            if (reference == null) {
              throw StateError('null reference');
            }
            stack.add(WasmValue.i32(reference));
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

          case Opcodes.v128Const:
            final laneBytes = instruction.floatBytesImmediate;
            if (laneBytes == null || laneBytes.length != 16) {
              throw StateError('Malformed v128.const immediate.');
            }
            stack.add(WasmValue.i32(WasmVm.internV128Bytes(laneBytes)));
            pc++;

          case Opcodes.i8x16Splat:
            _simdI8x16Splat(stack);
            pc++;

          case Opcodes.i8x16Eq:
            _simdI8x16Eq(stack);
            pc++;

          case Opcodes.i8x16Ne:
            _simdI8x16Ne(stack);
            pc++;

          case Opcodes.i8x16Abs:
            _simdI8x16Abs(stack);
            pc++;

          case Opcodes.i8x16Neg:
            _simdI8x16Neg(stack);
            pc++;

          case Opcodes.i8x16Popcnt:
            _simdI8x16Popcnt(stack);
            pc++;

          case Opcodes.i8x16Bitmask:
            _simdI8x16Bitmask(stack);
            pc++;

          case Opcodes.v128AnyTrue:
            _simdI8x16AnyTrue(stack);
            pc++;

          case Opcodes.i16x8Abs:
            _simdI16x8Abs(stack);
            pc++;

          case Opcodes.i16x8Splat:
            _simdI16x8Splat(stack);
            pc++;

          case Opcodes.i16x8Eq:
            _simdI16x8Eq(stack);
            pc++;

          case Opcodes.i16x8Ne:
            _simdI16x8Ne(stack);
            pc++;

          case Opcodes.i16x8LtS:
            _simdI16x8Compare(stack, opcode: Opcodes.i16x8LtS);
            pc++;

          case Opcodes.i16x8LtU:
            _simdI16x8Compare(stack, opcode: Opcodes.i16x8LtU);
            pc++;

          case Opcodes.i16x8GtS:
            _simdI16x8Compare(stack, opcode: Opcodes.i16x8GtS);
            pc++;

          case Opcodes.i16x8GtU:
            _simdI16x8Compare(stack, opcode: Opcodes.i16x8GtU);
            pc++;

          case Opcodes.i16x8LeS:
            _simdI16x8Compare(stack, opcode: Opcodes.i16x8LeS);
            pc++;

          case Opcodes.i16x8LeU:
            _simdI16x8Compare(stack, opcode: Opcodes.i16x8LeU);
            pc++;

          case Opcodes.i16x8GeS:
            _simdI16x8Compare(stack, opcode: Opcodes.i16x8GeS);
            pc++;

          case Opcodes.i16x8GeU:
            _simdI16x8Compare(stack, opcode: Opcodes.i16x8GeU);
            pc++;

          case Opcodes.i16x8Add:
            _simdI16x8Add(stack);
            pc++;

          case Opcodes.i16x8AddSatS:
            _simdI16x8AddSatS(stack);
            pc++;

          case Opcodes.i16x8AddSatU:
            _simdI16x8AddSatU(stack);
            pc++;

          case Opcodes.i16x8Sub:
            _simdI16x8Sub(stack);
            pc++;

          case Opcodes.i16x8SubSatS:
            _simdI16x8SubSatS(stack);
            pc++;

          case Opcodes.i16x8SubSatU:
            _simdI16x8SubSatU(stack);
            pc++;

          case Opcodes.i16x8Shl:
            _simdI16x8Shl(stack);
            pc++;

          case Opcodes.i16x8ShrS:
            _simdI16x8ShrS(stack);
            pc++;

          case Opcodes.i16x8ShrU:
            _simdI16x8ShrU(stack);
            pc++;

          case Opcodes.i16x8Neg:
            _simdI16x8Neg(stack);
            pc++;

          case Opcodes.i16x8Mul:
            _simdI16x8Mul(stack);
            pc++;

          case Opcodes.i16x8MinS:
            _simdI16x8MinS(stack);
            pc++;

          case Opcodes.i16x8MinU:
            _simdI16x8MinU(stack);
            pc++;

          case Opcodes.i16x8MaxS:
            _simdI16x8MaxS(stack);
            pc++;

          case Opcodes.i16x8MaxU:
            _simdI16x8MaxU(stack);
            pc++;

          case Opcodes.i16x8AvgrU:
            _simdI16x8AvgrU(stack);
            pc++;

          case Opcodes.i16x8Bitmask:
            _simdI16x8Bitmask(stack);
            pc++;

          case Opcodes.i32x4Splat:
            _simdI32x4Splat(stack);
            pc++;

          case Opcodes.i32x4Eq:
            _simdI32x4Eq(stack);
            pc++;

          case Opcodes.i32x4Ne:
            _simdI32x4Ne(stack);
            pc++;

          case Opcodes.i32x4LtS:
            _simdI32x4Compare(stack, opcode: Opcodes.i32x4LtS);
            pc++;

          case Opcodes.i32x4LtU:
            _simdI32x4Compare(stack, opcode: Opcodes.i32x4LtU);
            pc++;

          case Opcodes.i32x4GtS:
            _simdI32x4Compare(stack, opcode: Opcodes.i32x4GtS);
            pc++;

          case Opcodes.i32x4GtU:
            _simdI32x4Compare(stack, opcode: Opcodes.i32x4GtU);
            pc++;

          case Opcodes.i32x4LeS:
            _simdI32x4Compare(stack, opcode: Opcodes.i32x4LeS);
            pc++;

          case Opcodes.i32x4LeU:
            _simdI32x4Compare(stack, opcode: Opcodes.i32x4LeU);
            pc++;

          case Opcodes.i32x4GeS:
            _simdI32x4Compare(stack, opcode: Opcodes.i32x4GeS);
            pc++;

          case Opcodes.i32x4GeU:
            _simdI32x4Compare(stack, opcode: Opcodes.i32x4GeU);
            pc++;

          case Opcodes.i32x4Add:
            _simdI32x4Add(stack);
            pc++;

          case Opcodes.i32x4Sub:
            _simdI32x4Sub(stack);
            pc++;

          case Opcodes.i32x4Mul:
            _simdI32x4Mul(stack);
            pc++;

          case Opcodes.i32x4Shl:
            _simdI32x4Shl(stack);
            pc++;

          case Opcodes.i32x4ShrS:
            _simdI32x4ShrS(stack);
            pc++;

          case Opcodes.i32x4ShrU:
            _simdI32x4ShrU(stack);
            pc++;

          case Opcodes.i32x4Abs:
            _simdI32x4Abs(stack);
            pc++;

          case Opcodes.i32x4Neg:
            _simdI32x4Neg(stack);
            pc++;

          case Opcodes.i32x4MinS:
            _simdI32x4MinS(stack);
            pc++;

          case Opcodes.i32x4MinU:
            _simdI32x4MinU(stack);
            pc++;

          case Opcodes.i32x4MaxS:
            _simdI32x4MaxS(stack);
            pc++;

          case Opcodes.i32x4MaxU:
            _simdI32x4MaxU(stack);
            pc++;

          case Opcodes.i32x4Bitmask:
            _simdI32x4Bitmask(stack);
            pc++;

          case Opcodes.i32x4AllTrue:
            _simdI32x4AllTrue(stack);
            pc++;

          case Opcodes.i64x2Splat:
            _simdI64x2Splat(stack);
            pc++;

          case Opcodes.i64x2Eq:
            _simdI64x2Eq(stack);
            pc++;

          case Opcodes.i64x2Ne:
            _simdI64x2Compare(stack, opcode: Opcodes.i64x2Ne);
            pc++;

          case Opcodes.i64x2LtS:
            _simdI64x2Compare(stack, opcode: Opcodes.i64x2LtS);
            pc++;

          case Opcodes.i64x2GtS:
            _simdI64x2Compare(stack, opcode: Opcodes.i64x2GtS);
            pc++;

          case Opcodes.i64x2LeS:
            _simdI64x2Compare(stack, opcode: Opcodes.i64x2LeS);
            pc++;

          case Opcodes.i64x2GeS:
            _simdI64x2Compare(stack, opcode: Opcodes.i64x2GeS);
            pc++;

          case Opcodes.i64x2Shl:
            _simdI64x2Shl(stack);
            pc++;

          case Opcodes.i64x2ShrS:
            _simdI64x2ShrS(stack);
            pc++;

          case Opcodes.i64x2ShrU:
            _simdI64x2ShrU(stack);
            pc++;

          case Opcodes.i64x2Add:
            _simdI64x2Add(stack);
            pc++;

          case Opcodes.i64x2Sub:
            _simdI64x2Sub(stack);
            pc++;

          case Opcodes.i64x2Mul:
            _simdI64x2Mul(stack);
            pc++;

          case Opcodes.i64x2Abs:
            _simdI64x2Abs(stack);
            pc++;

          case Opcodes.i64x2Neg:
            _simdI64x2Neg(stack);
            pc++;

          case Opcodes.i64x2Bitmask:
            _simdI64x2Bitmask(stack);
            pc++;

          case Opcodes.i64x2AllTrue:
            _simdI64x2AllTrue(stack);
            pc++;

          case Opcodes.f32x4Splat:
            _simdF32x4Splat(stack);
            pc++;

          case Opcodes.f32x4Eq:
            _simdF32x4Eq(stack);
            pc++;

          case Opcodes.f32x4Ne:
            _simdF32x4Ne(stack);
            pc++;

          case Opcodes.f32x4Lt:
            _simdF32x4Compare(stack, opcode: Opcodes.f32x4Lt);
            pc++;

          case Opcodes.f32x4Gt:
            _simdF32x4Compare(stack, opcode: Opcodes.f32x4Gt);
            pc++;

          case Opcodes.f32x4Le:
            _simdF32x4Compare(stack, opcode: Opcodes.f32x4Le);
            pc++;

          case Opcodes.f32x4Ge:
            _simdF32x4Compare(stack, opcode: Opcodes.f32x4Ge);
            pc++;

          case Opcodes.f32x4Add:
            _simdF32x4Add(stack);
            pc++;

          case Opcodes.f32x4Sub:
            _simdF32x4Sub(stack);
            pc++;

          case Opcodes.f32x4Mul:
            _simdF32x4Mul(stack);
            pc++;

          case Opcodes.f32x4Div:
            _simdF32x4Div(stack);
            pc++;

          case Opcodes.f32x4Abs:
            _simdF32x4Abs(stack);
            pc++;

          case Opcodes.f32x4Neg:
            _simdF32x4Neg(stack);
            pc++;

          case Opcodes.f32x4Sqrt:
            _simdF32x4Sqrt(stack);
            pc++;

          case Opcodes.f32x4Min:
            _simdF32x4Min(stack);
            pc++;

          case Opcodes.f32x4Max:
            _simdF32x4Max(stack);
            pc++;

          case Opcodes.f32x4Pmin:
            _simdF32x4Pmin(stack);
            pc++;

          case Opcodes.f32x4Pmax:
            _simdF32x4Pmax(stack);
            pc++;

          case Opcodes.f32x4RelaxedMin:
            _simdF32x4Min(stack);
            pc++;

          case Opcodes.f32x4RelaxedMax:
            _simdF32x4Max(stack);
            pc++;

          case Opcodes.f64x2Splat:
            _simdF64x2Splat(stack);
            pc++;

          case Opcodes.f64x2Eq:
            _simdF64x2Eq(stack);
            pc++;

          case Opcodes.f64x2Ne:
            _simdF64x2Ne(stack);
            pc++;

          case Opcodes.f64x2Lt:
            _simdF64x2Compare(stack, opcode: Opcodes.f64x2Lt);
            pc++;

          case Opcodes.f64x2Gt:
            _simdF64x2Compare(stack, opcode: Opcodes.f64x2Gt);
            pc++;

          case Opcodes.f64x2Le:
            _simdF64x2Compare(stack, opcode: Opcodes.f64x2Le);
            pc++;

          case Opcodes.f64x2Ge:
            _simdF64x2Compare(stack, opcode: Opcodes.f64x2Ge);
            pc++;

          case Opcodes.f64x2Add:
            _simdF64x2Add(stack);
            pc++;

          case Opcodes.f64x2Sub:
            _simdF64x2Sub(stack);
            pc++;

          case Opcodes.f64x2Mul:
            _simdF64x2Mul(stack);
            pc++;

          case Opcodes.f64x2Div:
            _simdF64x2Div(stack);
            pc++;

          case Opcodes.f64x2Abs:
            _simdF64x2Abs(stack);
            pc++;

          case Opcodes.f64x2Neg:
            _simdF64x2Neg(stack);
            pc++;

          case Opcodes.f64x2Sqrt:
            _simdF64x2Sqrt(stack);
            pc++;

          case Opcodes.f64x2Min:
            _simdF64x2Min(stack);
            pc++;

          case Opcodes.f64x2Max:
            _simdF64x2Max(stack);
            pc++;

          case Opcodes.f64x2Pmin:
            _simdF64x2Pmin(stack);
            pc++;

          case Opcodes.f64x2Pmax:
            _simdF64x2Pmax(stack);
            pc++;

          case Opcodes.f64x2RelaxedMin:
            _simdF64x2Min(stack);
            pc++;

          case Opcodes.f64x2RelaxedMax:
            _simdF64x2Max(stack);
            pc++;

          case Opcodes.i32Eqz:
            final value = _popValue(stack, 'i32.eqz').castTo(WasmValueType.i32);
            stack.add(WasmValue.i32(value.asI32() == 0 ? 1 : 0));
            pc++;

          case Opcodes.i32Eq:
            final rhs = _popValue(
              stack,
              'i32.eq rhs',
            ).castTo(WasmValueType.i32);
            final lhs = _popValue(
              stack,
              'i32.eq lhs',
            ).castTo(WasmValueType.i32);
            stack.add(WasmValue.i32(lhs.asI32() == rhs.asI32() ? 1 : 0));
            pc++;

          case Opcodes.i32Ne:
            final rhs = _popValue(
              stack,
              'i32.ne rhs',
            ).castTo(WasmValueType.i32);
            final lhs = _popValue(
              stack,
              'i32.ne lhs',
            ).castTo(WasmValueType.i32);
            stack.add(WasmValue.i32(lhs.asI32() != rhs.asI32() ? 1 : 0));
            pc++;

          case Opcodes.i32LtS:
            final rhs = _popValue(
              stack,
              'i32.lt_s rhs',
            ).castTo(WasmValueType.i32);
            final lhs = _popValue(
              stack,
              'i32.lt_s lhs',
            ).castTo(WasmValueType.i32);
            stack.add(WasmValue.i32(lhs.asI32() < rhs.asI32() ? 1 : 0));
            pc++;

          case Opcodes.i32LtU:
            final rhs = _popValue(
              stack,
              'i32.lt_u rhs',
            ).castTo(WasmValueType.i32);
            final lhs = _popValue(
              stack,
              'i32.lt_u lhs',
            ).castTo(WasmValueType.i32);
            stack.add(
              WasmValue.i32(
                lhs.asI32().toUnsigned(32) < rhs.asI32().toUnsigned(32) ? 1 : 0,
              ),
            );
            pc++;

          case Opcodes.i32GtS:
            final rhs = _popValue(
              stack,
              'i32.gt_s rhs',
            ).castTo(WasmValueType.i32);
            final lhs = _popValue(
              stack,
              'i32.gt_s lhs',
            ).castTo(WasmValueType.i32);
            stack.add(WasmValue.i32(lhs.asI32() > rhs.asI32() ? 1 : 0));
            pc++;

          case Opcodes.i32GtU:
            final rhs = _popValue(
              stack,
              'i32.gt_u rhs',
            ).castTo(WasmValueType.i32);
            final lhs = _popValue(
              stack,
              'i32.gt_u lhs',
            ).castTo(WasmValueType.i32);
            stack.add(
              WasmValue.i32(
                lhs.asI32().toUnsigned(32) > rhs.asI32().toUnsigned(32) ? 1 : 0,
              ),
            );
            pc++;

          case Opcodes.i32LeS:
            final rhs = _popValue(
              stack,
              'i32.le_s rhs',
            ).castTo(WasmValueType.i32);
            final lhs = _popValue(
              stack,
              'i32.le_s lhs',
            ).castTo(WasmValueType.i32);
            stack.add(WasmValue.i32(lhs.asI32() <= rhs.asI32() ? 1 : 0));
            pc++;

          case Opcodes.i32LeU:
            final rhs = _popValue(
              stack,
              'i32.le_u rhs',
            ).castTo(WasmValueType.i32);
            final lhs = _popValue(
              stack,
              'i32.le_u lhs',
            ).castTo(WasmValueType.i32);
            stack.add(
              WasmValue.i32(
                lhs.asI32().toUnsigned(32) <= rhs.asI32().toUnsigned(32)
                    ? 1
                    : 0,
              ),
            );
            pc++;

          case Opcodes.i32GeS:
            final rhs = _popValue(
              stack,
              'i32.ge_s rhs',
            ).castTo(WasmValueType.i32);
            final lhs = _popValue(
              stack,
              'i32.ge_s lhs',
            ).castTo(WasmValueType.i32);
            stack.add(WasmValue.i32(lhs.asI32() >= rhs.asI32() ? 1 : 0));
            pc++;

          case Opcodes.i32GeU:
            final rhs = _popValue(
              stack,
              'i32.ge_u rhs',
            ).castTo(WasmValueType.i32);
            final lhs = _popValue(
              stack,
              'i32.ge_u lhs',
            ).castTo(WasmValueType.i32);
            stack.add(
              WasmValue.i32(
                lhs.asI32().toUnsigned(32) >= rhs.asI32().toUnsigned(32)
                    ? 1
                    : 0,
              ),
            );
            pc++;

          case Opcodes.i32Add:
            final rhs = _popValue(
              stack,
              'i32.add rhs',
            ).castTo(WasmValueType.i32);
            final lhs = _popValue(
              stack,
              'i32.add lhs',
            ).castTo(WasmValueType.i32);
            stack.add(WasmValue.i32(lhs.asI32() + rhs.asI32()));
            pc++;

          case Opcodes.i32Sub:
            final rhs = _popValue(
              stack,
              'i32.sub rhs',
            ).castTo(WasmValueType.i32);
            final lhs = _popValue(
              stack,
              'i32.sub lhs',
            ).castTo(WasmValueType.i32);
            stack.add(WasmValue.i32(lhs.asI32() - rhs.asI32()));
            pc++;

          case Opcodes.i32Mul:
            final rhs = _popValue(
              stack,
              'i32.mul rhs',
            ).castTo(WasmValueType.i32);
            final lhs = _popValue(
              stack,
              'i32.mul lhs',
            ).castTo(WasmValueType.i32);
            stack.add(WasmValue.i32(lhs.asI32() * rhs.asI32()));
            pc++;

          case Opcodes.i32DivS:
            final rhs = _popValue(
              stack,
              'i32.div_s rhs',
            ).castTo(WasmValueType.i32).asI32();
            final lhs = _popValue(
              stack,
              'i32.div_s lhs',
            ).castTo(WasmValueType.i32).asI32();
            if (rhs == 0) {
              throw StateError('i32.div_s division by zero trap');
            }
            if (lhs == -2147483648 && rhs == -1) {
              throw StateError('i32.div_s overflow trap');
            }
            stack.add(WasmValue.i32(lhs ~/ rhs));
            pc++;

          case Opcodes.i32DivU:
            final rhs = _popValue(
              stack,
              'i32.div_u rhs',
            ).castTo(WasmValueType.i32).asI32().toUnsigned(32);
            final lhs = _popValue(
              stack,
              'i32.div_u lhs',
            ).castTo(WasmValueType.i32).asI32().toUnsigned(32);
            if (rhs == 0) {
              throw StateError('i32.div_u division by zero trap');
            }
            stack.add(WasmValue.i32(lhs ~/ rhs));
            pc++;

          case Opcodes.i32RemS:
            final rhs = _popValue(
              stack,
              'i32.rem_s rhs',
            ).castTo(WasmValueType.i32).asI32();
            final lhs = _popValue(
              stack,
              'i32.rem_s lhs',
            ).castTo(WasmValueType.i32).asI32();
            if (rhs == 0) {
              throw StateError('i32.rem_s division by zero trap');
            }
            stack.add(WasmValue.i32(lhs.remainder(rhs)));
            pc++;

          case Opcodes.i32RemU:
            final rhs = _popValue(
              stack,
              'i32.rem_u rhs',
            ).castTo(WasmValueType.i32).asI32().toUnsigned(32);
            final lhs = _popValue(
              stack,
              'i32.rem_u lhs',
            ).castTo(WasmValueType.i32).asI32().toUnsigned(32);
            if (rhs == 0) {
              throw StateError('i32.rem_u division by zero trap');
            }
            stack.add(WasmValue.i32(lhs % rhs));
            pc++;

          case Opcodes.i32Clz:
            final value = _popValue(stack, 'i32.clz').castTo(WasmValueType.i32);
            stack.add(WasmValue.i32(_i32Clz(value.asI32())));
            pc++;

          case Opcodes.i32Ctz:
            final value = _popValue(stack, 'i32.ctz').castTo(WasmValueType.i32);
            stack.add(WasmValue.i32(_i32Ctz(value.asI32())));
            pc++;

          case Opcodes.i32Popcnt:
            final value = _popValue(
              stack,
              'i32.popcnt',
            ).castTo(WasmValueType.i32);
            stack.add(WasmValue.i32(_i32Popcnt(value.asI32())));
            pc++;

          case Opcodes.i32And:
            final rhs = _popValue(
              stack,
              'i32.and rhs',
            ).castTo(WasmValueType.i32);
            final lhs = _popValue(
              stack,
              'i32.and lhs',
            ).castTo(WasmValueType.i32);
            stack.add(WasmValue.i32(lhs.asI32() & rhs.asI32()));
            pc++;

          case Opcodes.i32Or:
            final rhs = _popValue(
              stack,
              'i32.or rhs',
            ).castTo(WasmValueType.i32);
            final lhs = _popValue(
              stack,
              'i32.or lhs',
            ).castTo(WasmValueType.i32);
            stack.add(WasmValue.i32(lhs.asI32() | rhs.asI32()));
            pc++;

          case Opcodes.i32Xor:
            final rhs = _popValue(
              stack,
              'i32.xor rhs',
            ).castTo(WasmValueType.i32);
            final lhs = _popValue(
              stack,
              'i32.xor lhs',
            ).castTo(WasmValueType.i32);
            stack.add(WasmValue.i32(lhs.asI32() ^ rhs.asI32()));
            pc++;

          case Opcodes.i32Shl:
            final rhs = _popValue(
              stack,
              'i32.shl rhs',
            ).castTo(WasmValueType.i32);
            final lhs = _popValue(
              stack,
              'i32.shl lhs',
            ).castTo(WasmValueType.i32);
            final shift = rhs.asI32() & 31;
            stack.add(WasmValue.i32(lhs.asI32() << shift));
            pc++;

          case Opcodes.i32ShrS:
            final rhs = _popValue(
              stack,
              'i32.shr_s rhs',
            ).castTo(WasmValueType.i32);
            final lhs = _popValue(
              stack,
              'i32.shr_s lhs',
            ).castTo(WasmValueType.i32);
            final shift = rhs.asI32() & 31;
            stack.add(WasmValue.i32(lhs.asI32() >> shift));
            pc++;

          case Opcodes.i32ShrU:
            final rhs = _popValue(
              stack,
              'i32.shr_u rhs',
            ).castTo(WasmValueType.i32);
            final lhs = _popValue(
              stack,
              'i32.shr_u lhs',
            ).castTo(WasmValueType.i32);
            final shift = rhs.asI32() & 31;
            stack.add(WasmValue.i32(lhs.asI32().toUnsigned(32) >> shift));
            pc++;

          case Opcodes.i32Rotl:
            final rhs = _popValue(
              stack,
              'i32.rotl rhs',
            ).castTo(WasmValueType.i32);
            final lhs = _popValue(
              stack,
              'i32.rotl lhs',
            ).castTo(WasmValueType.i32);
            final shift = rhs.asI32() & 31;
            final value = lhs.asI32().toUnsigned(32);
            final rotated = shift == 0
                ? value
                : ((value << shift) | (value >> (32 - shift))).toUnsigned(32);
            stack.add(WasmValue.i32(rotated));
            pc++;

          case Opcodes.i32Rotr:
            final rhs = _popValue(
              stack,
              'i32.rotr rhs',
            ).castTo(WasmValueType.i32);
            final lhs = _popValue(
              stack,
              'i32.rotr lhs',
            ).castTo(WasmValueType.i32);
            final shift = rhs.asI32() & 31;
            final value = lhs.asI32().toUnsigned(32);
            final rotated = shift == 0
                ? value
                : ((value >> shift) | (value << (32 - shift))).toUnsigned(32);
            stack.add(WasmValue.i32(rotated));
            pc++;

          case Opcodes.i64Eqz:
            final value = _popValue(stack, 'i64.eqz').castTo(WasmValueType.i64);
            stack.add(WasmValue.i32(value.asI64() == BigInt.zero ? 1 : 0));
            pc++;

          case Opcodes.i64Eq:
            final rhs = _popValue(
              stack,
              'i64.eq rhs',
            ).castTo(WasmValueType.i64);
            final lhs = _popValue(
              stack,
              'i64.eq lhs',
            ).castTo(WasmValueType.i64);
            stack.add(WasmValue.i32(lhs.asI64() == rhs.asI64() ? 1 : 0));
            pc++;

          case Opcodes.i64Ne:
            final rhs = _popValue(
              stack,
              'i64.ne rhs',
            ).castTo(WasmValueType.i64);
            final lhs = _popValue(
              stack,
              'i64.ne lhs',
            ).castTo(WasmValueType.i64);
            stack.add(WasmValue.i32(lhs.asI64() != rhs.asI64() ? 1 : 0));
            pc++;

          case Opcodes.i64LtS:
            final rhs = _popValue(
              stack,
              'i64.lt_s rhs',
            ).castTo(WasmValueType.i64);
            final lhs = _popValue(
              stack,
              'i64.lt_s lhs',
            ).castTo(WasmValueType.i64);
            stack.add(
              WasmValue.i32(lhs.asI64().compareTo(rhs.asI64()) < 0 ? 1 : 0),
            );
            pc++;

          case Opcodes.i64LtU:
            final rhs = _popValue(
              stack,
              'i64.lt_u rhs',
            ).castTo(WasmValueType.i64);
            final lhs = _popValue(
              stack,
              'i64.lt_u lhs',
            ).castTo(WasmValueType.i64);
            stack.add(
              WasmValue.i32(
                WasmI64.compareUnsigned(lhs.asI64(), rhs.asI64()) < 0 ? 1 : 0,
              ),
            );
            pc++;

          case Opcodes.i64GtS:
            final rhs = _popValue(
              stack,
              'i64.gt_s rhs',
            ).castTo(WasmValueType.i64);
            final lhs = _popValue(
              stack,
              'i64.gt_s lhs',
            ).castTo(WasmValueType.i64);
            stack.add(
              WasmValue.i32(lhs.asI64().compareTo(rhs.asI64()) > 0 ? 1 : 0),
            );
            pc++;

          case Opcodes.i64GtU:
            final rhs = _popValue(
              stack,
              'i64.gt_u rhs',
            ).castTo(WasmValueType.i64);
            final lhs = _popValue(
              stack,
              'i64.gt_u lhs',
            ).castTo(WasmValueType.i64);
            stack.add(
              WasmValue.i32(
                WasmI64.compareUnsigned(lhs.asI64(), rhs.asI64()) > 0 ? 1 : 0,
              ),
            );
            pc++;

          case Opcodes.i64LeS:
            final rhs = _popValue(
              stack,
              'i64.le_s rhs',
            ).castTo(WasmValueType.i64);
            final lhs = _popValue(
              stack,
              'i64.le_s lhs',
            ).castTo(WasmValueType.i64);
            stack.add(
              WasmValue.i32(lhs.asI64().compareTo(rhs.asI64()) <= 0 ? 1 : 0),
            );
            pc++;

          case Opcodes.i64LeU:
            final rhs = _popValue(
              stack,
              'i64.le_u rhs',
            ).castTo(WasmValueType.i64);
            final lhs = _popValue(
              stack,
              'i64.le_u lhs',
            ).castTo(WasmValueType.i64);
            stack.add(
              WasmValue.i32(
                WasmI64.compareUnsigned(lhs.asI64(), rhs.asI64()) <= 0 ? 1 : 0,
              ),
            );
            pc++;

          case Opcodes.i64GeS:
            final rhs = _popValue(
              stack,
              'i64.ge_s rhs',
            ).castTo(WasmValueType.i64);
            final lhs = _popValue(
              stack,
              'i64.ge_s lhs',
            ).castTo(WasmValueType.i64);
            stack.add(
              WasmValue.i32(lhs.asI64().compareTo(rhs.asI64()) >= 0 ? 1 : 0),
            );
            pc++;

          case Opcodes.i64GeU:
            final rhs = _popValue(
              stack,
              'i64.ge_u rhs',
            ).castTo(WasmValueType.i64);
            final lhs = _popValue(
              stack,
              'i64.ge_u lhs',
            ).castTo(WasmValueType.i64);
            stack.add(
              WasmValue.i32(
                WasmI64.compareUnsigned(lhs.asI64(), rhs.asI64()) >= 0 ? 1 : 0,
              ),
            );
            pc++;

          case Opcodes.f32Eq:
            final rhs = _popValue(
              stack,
              'f32.eq rhs',
            ).castTo(WasmValueType.f32);
            final lhs = _popValue(
              stack,
              'f32.eq lhs',
            ).castTo(WasmValueType.f32);
            stack.add(WasmValue.i32(lhs.asF32() == rhs.asF32() ? 1 : 0));
            pc++;

          case Opcodes.f32Ne:
            final rhs = _popValue(
              stack,
              'f32.ne rhs',
            ).castTo(WasmValueType.f32);
            final lhs = _popValue(
              stack,
              'f32.ne lhs',
            ).castTo(WasmValueType.f32);
            stack.add(WasmValue.i32(lhs.asF32() != rhs.asF32() ? 1 : 0));
            pc++;

          case Opcodes.f32Lt:
            final rhs = _popValue(
              stack,
              'f32.lt rhs',
            ).castTo(WasmValueType.f32);
            final lhs = _popValue(
              stack,
              'f32.lt lhs',
            ).castTo(WasmValueType.f32);
            stack.add(WasmValue.i32(lhs.asF32() < rhs.asF32() ? 1 : 0));
            pc++;

          case Opcodes.f32Gt:
            final rhs = _popValue(
              stack,
              'f32.gt rhs',
            ).castTo(WasmValueType.f32);
            final lhs = _popValue(
              stack,
              'f32.gt lhs',
            ).castTo(WasmValueType.f32);
            stack.add(WasmValue.i32(lhs.asF32() > rhs.asF32() ? 1 : 0));
            pc++;

          case Opcodes.f32Le:
            final rhs = _popValue(
              stack,
              'f32.le rhs',
            ).castTo(WasmValueType.f32);
            final lhs = _popValue(
              stack,
              'f32.le lhs',
            ).castTo(WasmValueType.f32);
            stack.add(WasmValue.i32(lhs.asF32() <= rhs.asF32() ? 1 : 0));
            pc++;

          case Opcodes.f32Ge:
            final rhs = _popValue(
              stack,
              'f32.ge rhs',
            ).castTo(WasmValueType.f32);
            final lhs = _popValue(
              stack,
              'f32.ge lhs',
            ).castTo(WasmValueType.f32);
            stack.add(WasmValue.i32(lhs.asF32() >= rhs.asF32() ? 1 : 0));
            pc++;

          case Opcodes.f64Eq:
            final rhs = _popValue(
              stack,
              'f64.eq rhs',
            ).castTo(WasmValueType.f64);
            final lhs = _popValue(
              stack,
              'f64.eq lhs',
            ).castTo(WasmValueType.f64);
            stack.add(WasmValue.i32(lhs.asF64() == rhs.asF64() ? 1 : 0));
            pc++;

          case Opcodes.f64Ne:
            final rhs = _popValue(
              stack,
              'f64.ne rhs',
            ).castTo(WasmValueType.f64);
            final lhs = _popValue(
              stack,
              'f64.ne lhs',
            ).castTo(WasmValueType.f64);
            stack.add(WasmValue.i32(lhs.asF64() != rhs.asF64() ? 1 : 0));
            pc++;

          case Opcodes.f64Lt:
            final rhs = _popValue(
              stack,
              'f64.lt rhs',
            ).castTo(WasmValueType.f64);
            final lhs = _popValue(
              stack,
              'f64.lt lhs',
            ).castTo(WasmValueType.f64);
            stack.add(WasmValue.i32(lhs.asF64() < rhs.asF64() ? 1 : 0));
            pc++;

          case Opcodes.f64Gt:
            final rhs = _popValue(
              stack,
              'f64.gt rhs',
            ).castTo(WasmValueType.f64);
            final lhs = _popValue(
              stack,
              'f64.gt lhs',
            ).castTo(WasmValueType.f64);
            stack.add(WasmValue.i32(lhs.asF64() > rhs.asF64() ? 1 : 0));
            pc++;

          case Opcodes.f64Le:
            final rhs = _popValue(
              stack,
              'f64.le rhs',
            ).castTo(WasmValueType.f64);
            final lhs = _popValue(
              stack,
              'f64.le lhs',
            ).castTo(WasmValueType.f64);
            stack.add(WasmValue.i32(lhs.asF64() <= rhs.asF64() ? 1 : 0));
            pc++;

          case Opcodes.f64Ge:
            final rhs = _popValue(
              stack,
              'f64.ge rhs',
            ).castTo(WasmValueType.f64);
            final lhs = _popValue(
              stack,
              'f64.ge lhs',
            ).castTo(WasmValueType.f64);
            stack.add(WasmValue.i32(lhs.asF64() >= rhs.asF64() ? 1 : 0));
            pc++;

          case Opcodes.i64Clz:
            final value = _popValue(stack, 'i64.clz').castTo(WasmValueType.i64);
            stack.add(WasmValue.i64(WasmI64.clz(value.asI64())));
            pc++;

          case Opcodes.i64Ctz:
            final value = _popValue(stack, 'i64.ctz').castTo(WasmValueType.i64);
            stack.add(WasmValue.i64(WasmI64.ctz(value.asI64())));
            pc++;

          case Opcodes.i64Popcnt:
            final value = _popValue(
              stack,
              'i64.popcnt',
            ).castTo(WasmValueType.i64);
            stack.add(WasmValue.i64(WasmI64.popcnt(value.asI64())));
            pc++;

          case Opcodes.i64Add:
            final rhs = _popValue(
              stack,
              'i64.add rhs',
            ).castTo(WasmValueType.i64);
            final lhs = _popValue(
              stack,
              'i64.add lhs',
            ).castTo(WasmValueType.i64);
            stack.add(WasmValue.i64(lhs.asI64() + rhs.asI64()));
            pc++;

          case Opcodes.i64Sub:
            final rhs = _popValue(
              stack,
              'i64.sub rhs',
            ).castTo(WasmValueType.i64);
            final lhs = _popValue(
              stack,
              'i64.sub lhs',
            ).castTo(WasmValueType.i64);
            stack.add(WasmValue.i64(lhs.asI64() - rhs.asI64()));
            pc++;

          case Opcodes.i64Mul:
            final rhs = _popValue(
              stack,
              'i64.mul rhs',
            ).castTo(WasmValueType.i64);
            final lhs = _popValue(
              stack,
              'i64.mul lhs',
            ).castTo(WasmValueType.i64);
            stack.add(WasmValue.i64(lhs.asI64() * rhs.asI64()));
            pc++;

          case Opcodes.i64DivS:
            final rhs = _popValue(
              stack,
              'i64.div_s rhs',
            ).castTo(WasmValueType.i64).asI64();
            final lhs = _popValue(
              stack,
              'i64.div_s lhs',
            ).castTo(WasmValueType.i64).asI64();
            if (rhs == BigInt.zero) {
              throw StateError('i64.div_s division by zero trap');
            }
            if (lhs == WasmI64.minSigned && rhs == -BigInt.one) {
              throw StateError('i64.div_s overflow trap');
            }
            stack.add(WasmValue.i64(WasmI64.divS(lhs, rhs)));
            pc++;

          case Opcodes.i64DivU:
            final rhs = _popValue(
              stack,
              'i64.div_u rhs',
            ).castTo(WasmValueType.i64).asI64();
            final lhs = _popValue(
              stack,
              'i64.div_u lhs',
            ).castTo(WasmValueType.i64).asI64();
            if (rhs == BigInt.zero) {
              throw StateError('i64.div_u division by zero trap');
            }
            stack.add(WasmValue.i64(WasmI64.divU(lhs, rhs)));
            pc++;

          case Opcodes.i64RemS:
            final rhs = _popValue(
              stack,
              'i64.rem_s rhs',
            ).castTo(WasmValueType.i64).asI64();
            final lhs = _popValue(
              stack,
              'i64.rem_s lhs',
            ).castTo(WasmValueType.i64).asI64();
            if (rhs == BigInt.zero) {
              throw StateError('i64.rem_s division by zero trap');
            }
            stack.add(WasmValue.i64(WasmI64.remS(lhs, rhs)));
            pc++;

          case Opcodes.i64RemU:
            final rhs = _popValue(
              stack,
              'i64.rem_u rhs',
            ).castTo(WasmValueType.i64).asI64();
            final lhs = _popValue(
              stack,
              'i64.rem_u lhs',
            ).castTo(WasmValueType.i64).asI64();
            if (rhs == BigInt.zero) {
              throw StateError('i64.rem_u division by zero trap');
            }
            stack.add(WasmValue.i64(WasmI64.remU(lhs, rhs)));
            pc++;

          case Opcodes.i64And:
            final rhs = _popValue(
              stack,
              'i64.and rhs',
            ).castTo(WasmValueType.i64);
            final lhs = _popValue(
              stack,
              'i64.and lhs',
            ).castTo(WasmValueType.i64);
            stack.add(WasmValue.i64(WasmI64.and(lhs.asI64(), rhs.asI64())));
            pc++;

          case Opcodes.i64Or:
            final rhs = _popValue(
              stack,
              'i64.or rhs',
            ).castTo(WasmValueType.i64);
            final lhs = _popValue(
              stack,
              'i64.or lhs',
            ).castTo(WasmValueType.i64);
            stack.add(WasmValue.i64(WasmI64.or(lhs.asI64(), rhs.asI64())));
            pc++;

          case Opcodes.i64Xor:
            final rhs = _popValue(
              stack,
              'i64.xor rhs',
            ).castTo(WasmValueType.i64);
            final lhs = _popValue(
              stack,
              'i64.xor lhs',
            ).castTo(WasmValueType.i64);
            stack.add(WasmValue.i64(WasmI64.xor(lhs.asI64(), rhs.asI64())));
            pc++;

          case Opcodes.i64Shl:
            final rhs = _popValue(
              stack,
              'i64.shl rhs',
            ).castTo(WasmValueType.i64).asI64();
            final lhs = _popValue(
              stack,
              'i64.shl lhs',
            ).castTo(WasmValueType.i64).asI64();
            final shift = (rhs & BigInt.from(63)).toInt();
            stack.add(WasmValue.i64(WasmI64.shl(lhs, shift)));
            pc++;

          case Opcodes.i64ShrS:
            final rhs = _popValue(
              stack,
              'i64.shr_s rhs',
            ).castTo(WasmValueType.i64).asI64();
            final lhs = _popValue(
              stack,
              'i64.shr_s lhs',
            ).castTo(WasmValueType.i64).asI64();
            final shift = (rhs & BigInt.from(63)).toInt();
            stack.add(WasmValue.i64(WasmI64.shrS(lhs, shift)));
            pc++;

          case Opcodes.i64ShrU:
            final rhs = _popValue(
              stack,
              'i64.shr_u rhs',
            ).castTo(WasmValueType.i64).asI64();
            final lhs = _popValue(
              stack,
              'i64.shr_u lhs',
            ).castTo(WasmValueType.i64).asI64();
            final shift = (rhs & BigInt.from(63)).toInt();
            stack.add(WasmValue.i64(WasmI64.shrU(lhs, shift)));
            pc++;

          case Opcodes.i64Rotl:
            final rhs = _popValue(
              stack,
              'i64.rotl rhs',
            ).castTo(WasmValueType.i64).asI64();
            final lhs = _popValue(
              stack,
              'i64.rotl lhs',
            ).castTo(WasmValueType.i64).asI64();
            final shift = (rhs & BigInt.from(63)).toInt();
            stack.add(WasmValue.i64(WasmI64.rotl(lhs, shift)));
            pc++;

          case Opcodes.i64Rotr:
            final rhs = _popValue(
              stack,
              'i64.rotr rhs',
            ).castTo(WasmValueType.i64).asI64();
            final lhs = _popValue(
              stack,
              'i64.rotr lhs',
            ).castTo(WasmValueType.i64).asI64();
            final shift = (rhs & BigInt.from(63)).toInt();
            stack.add(WasmValue.i64(WasmI64.rotr(lhs, shift)));
            pc++;

          case Opcodes.i32WrapI64:
            final value = _popValue(
              stack,
              'i32.wrap_i64',
            ).castTo(WasmValueType.i64).asI64();
            stack.add(WasmValue.i32(WasmI64.lowU32(value).toSigned(32)));
            pc++;

          case Opcodes.i64ExtendI32S:
            final value = _popValue(
              stack,
              'i64.extend_i32_s',
            ).castTo(WasmValueType.i32).asI32();
            stack.add(WasmValue.i64(value));
            pc++;

          case Opcodes.i64ExtendI32U:
            final value = _popValue(
              stack,
              'i64.extend_i32_u',
            ).castTo(WasmValueType.i32).asI32();
            stack.add(WasmValue.i64(value.toUnsigned(32)));
            pc++;

          case Opcodes.i32ReinterpretF32:
            final value = _popValue(
              stack,
              'i32.reinterpret_f32',
            ).castTo(WasmValueType.f32).asF32Bits();
            stack.add(WasmValue.i32(value));
            pc++;

          case Opcodes.i64ReinterpretF64:
            final value = _popValue(
              stack,
              'i64.reinterpret_f64',
            ).castTo(WasmValueType.f64).asF64Bits();
            stack.add(WasmValue.i64(value));
            pc++;

          case Opcodes.f32ReinterpretI32:
            final value = _popValue(
              stack,
              'f32.reinterpret_i32',
            ).castTo(WasmValueType.i32).asI32();
            stack.add(WasmValue.f32Bits(value.toUnsigned(32)));
            pc++;

          case Opcodes.f64ReinterpretI64:
            final value = _popValue(
              stack,
              'f64.reinterpret_i64',
            ).castTo(WasmValueType.i64).asI64();
            stack.add(WasmValue.f64Bits(WasmI64.unsigned(value)));
            pc++;

          case Opcodes.i32Extend8S:
            final value = _popValue(
              stack,
              'i32.extend8_s',
            ).castTo(WasmValueType.i32).asI32();
            stack.add(WasmValue.i32(value.toUnsigned(8).toSigned(8)));
            pc++;

          case Opcodes.i32Extend16S:
            final value = _popValue(
              stack,
              'i32.extend16_s',
            ).castTo(WasmValueType.i32).asI32();
            stack.add(WasmValue.i32(value.toUnsigned(16).toSigned(16)));
            pc++;

          case Opcodes.i64Extend8S:
            final value = _popValue(
              stack,
              'i64.extend8_s',
            ).castTo(WasmValueType.i64).asI64();
            stack.add(WasmValue.i64(WasmI64.signExtend(value, 8)));
            pc++;

          case Opcodes.i64Extend16S:
            final value = _popValue(
              stack,
              'i64.extend16_s',
            ).castTo(WasmValueType.i64).asI64();
            stack.add(WasmValue.i64(WasmI64.signExtend(value, 16)));
            pc++;

          case Opcodes.i64Extend32S:
            final value = _popValue(
              stack,
              'i64.extend32_s',
            ).castTo(WasmValueType.i64).asI64();
            stack.add(WasmValue.i64(WasmI64.signExtend(value, 32)));
            pc++;

          case Opcodes.i32TruncF32S:
            final value = _popValue(
              stack,
              'i32.trunc_f32_s',
            ).castTo(WasmValueType.f32).asF32();
            stack.add(WasmValue.i32(_truncToI32S(value)));
            pc++;

          case Opcodes.i32TruncF32U:
            final value = _popValue(
              stack,
              'i32.trunc_f32_u',
            ).castTo(WasmValueType.f32).asF32();
            stack.add(WasmValue.i32(_truncToI32U(value)));
            pc++;

          case Opcodes.i32TruncF64S:
            final value = _popValue(
              stack,
              'i32.trunc_f64_s',
            ).castTo(WasmValueType.f64).asF64();
            stack.add(WasmValue.i32(_truncToI32S(value)));
            pc++;

          case Opcodes.i32TruncF64U:
            final value = _popValue(
              stack,
              'i32.trunc_f64_u',
            ).castTo(WasmValueType.f64).asF64();
            stack.add(WasmValue.i32(_truncToI32U(value)));
            pc++;

          case Opcodes.i64TruncF32S:
            final value = _popValue(
              stack,
              'i64.trunc_f32_s',
            ).castTo(WasmValueType.f32).asF32();
            stack.add(WasmValue.i64(_truncToI64S(value)));
            pc++;

          case Opcodes.i64TruncF32U:
            final value = _popValue(
              stack,
              'i64.trunc_f32_u',
            ).castTo(WasmValueType.f32).asF32();
            stack.add(WasmValue.i64(WasmI64.signed(_truncToI64U(value))));
            pc++;

          case Opcodes.i64TruncF64S:
            final value = _popValue(
              stack,
              'i64.trunc_f64_s',
            ).castTo(WasmValueType.f64).asF64();
            stack.add(WasmValue.i64(_truncToI64S(value)));
            pc++;

          case Opcodes.i64TruncF64U:
            final value = _popValue(
              stack,
              'i64.trunc_f64_u',
            ).castTo(WasmValueType.f64).asF64();
            stack.add(WasmValue.i64(WasmI64.signed(_truncToI64U(value))));
            pc++;

          case Opcodes.i32TruncSatF32S:
            final value = _popValue(
              stack,
              'i32.trunc_sat_f32_s',
            ).castTo(WasmValueType.f32).asF32();
            stack.add(WasmValue.i32(_truncSatToI32S(value)));
            pc++;

          case Opcodes.i32TruncSatF32U:
            final value = _popValue(
              stack,
              'i32.trunc_sat_f32_u',
            ).castTo(WasmValueType.f32).asF32();
            stack.add(WasmValue.i32(_truncSatToI32U(value)));
            pc++;

          case Opcodes.i32TruncSatF64S:
            final value = _popValue(
              stack,
              'i32.trunc_sat_f64_s',
            ).castTo(WasmValueType.f64).asF64();
            stack.add(WasmValue.i32(_truncSatToI32S(value)));
            pc++;

          case Opcodes.i32TruncSatF64U:
            final value = _popValue(
              stack,
              'i32.trunc_sat_f64_u',
            ).castTo(WasmValueType.f64).asF64();
            stack.add(WasmValue.i32(_truncSatToI32U(value)));
            pc++;

          case Opcodes.i64TruncSatF32S:
            final value = _popValue(
              stack,
              'i64.trunc_sat_f32_s',
            ).castTo(WasmValueType.f32).asF32();
            stack.add(WasmValue.i64(_truncSatToI64S(value)));
            pc++;

          case Opcodes.i64TruncSatF32U:
            final value = _popValue(
              stack,
              'i64.trunc_sat_f32_u',
            ).castTo(WasmValueType.f32).asF32();
            stack.add(WasmValue.i64(_truncSatToI64U(value)));
            pc++;

          case Opcodes.i64TruncSatF64S:
            final value = _popValue(
              stack,
              'i64.trunc_sat_f64_s',
            ).castTo(WasmValueType.f64).asF64();
            stack.add(WasmValue.i64(_truncSatToI64S(value)));
            pc++;

          case Opcodes.i64TruncSatF64U:
            final value = _popValue(
              stack,
              'i64.trunc_sat_f64_u',
            ).castTo(WasmValueType.f64).asF64();
            stack.add(WasmValue.i64(_truncSatToI64U(value)));
            pc++;

          case Opcodes.i64Add128:
            final rhsHigh = WasmI64.unsigned(
              _popValue(
                stack,
                'i64.add128 rhs high',
              ).castTo(WasmValueType.i64).asI64(),
            );
            final rhsLow = WasmI64.unsigned(
              _popValue(
                stack,
                'i64.add128 rhs low',
              ).castTo(WasmValueType.i64).asI64(),
            );
            final lhsHigh = WasmI64.unsigned(
              _popValue(
                stack,
                'i64.add128 lhs high',
              ).castTo(WasmValueType.i64).asI64(),
            );
            final lhsLow = WasmI64.unsigned(
              _popValue(
                stack,
                'i64.add128 lhs low',
              ).castTo(WasmValueType.i64).asI64(),
            );
            final lhs = (lhsHigh << 64) | lhsLow;
            final rhs = (rhsHigh << 64) | rhsLow;
            _pushAsyncSubsetI128Result(stack, lhs + rhs);
            pc++;

          case Opcodes.i64Sub128:
            final rhsHigh = WasmI64.unsigned(
              _popValue(
                stack,
                'i64.sub128 rhs high',
              ).castTo(WasmValueType.i64).asI64(),
            );
            final rhsLow = WasmI64.unsigned(
              _popValue(
                stack,
                'i64.sub128 rhs low',
              ).castTo(WasmValueType.i64).asI64(),
            );
            final lhsHigh = WasmI64.unsigned(
              _popValue(
                stack,
                'i64.sub128 lhs high',
              ).castTo(WasmValueType.i64).asI64(),
            );
            final lhsLow = WasmI64.unsigned(
              _popValue(
                stack,
                'i64.sub128 lhs low',
              ).castTo(WasmValueType.i64).asI64(),
            );
            final lhs = (lhsHigh << 64) | lhsLow;
            final rhs = (rhsHigh << 64) | rhsLow;
            _pushAsyncSubsetI128Result(stack, lhs - rhs);
            pc++;

          case Opcodes.i64MulWideS:
            final rhs = _popValue(
              stack,
              'i64.mul_wide_s rhs',
            ).castTo(WasmValueType.i64).asI64();
            final lhs = _popValue(
              stack,
              'i64.mul_wide_s lhs',
            ).castTo(WasmValueType.i64).asI64();
            _pushAsyncSubsetI128Result(stack, lhs * rhs);
            pc++;

          case Opcodes.i64MulWideU:
            final rhs = WasmI64.unsigned(
              _popValue(
                stack,
                'i64.mul_wide_u rhs',
              ).castTo(WasmValueType.i64).asI64(),
            );
            final lhs = WasmI64.unsigned(
              _popValue(
                stack,
                'i64.mul_wide_u lhs',
              ).castTo(WasmValueType.i64).asI64(),
            );
            _pushAsyncSubsetI128Result(stack, lhs * rhs);
            pc++;

          case Opcodes.f32ConvertI32S:
            final value = _popValue(
              stack,
              'f32.convert_i32_s',
            ).castTo(WasmValueType.i32).asI32();
            stack.add(WasmValue.f32(value.toDouble()));
            pc++;

          case Opcodes.f32ConvertI32U:
            final value = _popValue(
              stack,
              'f32.convert_i32_u',
            ).castTo(WasmValueType.i32).asI32().toUnsigned(32);
            stack.add(WasmValue.f32(value.toDouble()));
            pc++;

          case Opcodes.f32ConvertI64S:
            final value = _popValue(
              stack,
              'f32.convert_i64_s',
            ).castTo(WasmValueType.i64).asI64();
            stack.add(WasmValue.f32(_f32FromInteger(value)));
            pc++;

          case Opcodes.f32ConvertI64U:
            final value = _popValue(
              stack,
              'f32.convert_i64_u',
            ).castTo(WasmValueType.i64).asI64();
            stack.add(WasmValue.f32(_f32FromInteger(WasmI64.unsigned(value))));
            pc++;

          case Opcodes.f32DemoteF64:
            final value = _popValue(
              stack,
              'f32.demote_f64',
            ).castTo(WasmValueType.f64).asF64();
            stack.add(WasmValue.f32(value));
            pc++;

          case Opcodes.f64ConvertI32S:
            final value = _popValue(
              stack,
              'f64.convert_i32_s',
            ).castTo(WasmValueType.i32).asI32();
            stack.add(WasmValue.f64(value.toDouble()));
            pc++;

          case Opcodes.f64ConvertI32U:
            final value = _popValue(
              stack,
              'f64.convert_i32_u',
            ).castTo(WasmValueType.i32).asI32().toUnsigned(32);
            stack.add(WasmValue.f64(value.toDouble()));
            pc++;

          case Opcodes.f64ConvertI64S:
            final value = _popValue(
              stack,
              'f64.convert_i64_s',
            ).castTo(WasmValueType.i64).asI64();
            stack.add(WasmValue.f64(value.toDouble()));
            pc++;

          case Opcodes.f64ConvertI64U:
            final value = _popValue(
              stack,
              'f64.convert_i64_u',
            ).castTo(WasmValueType.i64).asI64();
            stack.add(WasmValue.f64(WasmI64.unsignedToDouble(value)));
            pc++;

          case Opcodes.f64PromoteF32:
            final value = _popValue(
              stack,
              'f64.promote_f32',
            ).castTo(WasmValueType.f32).asF32();
            stack.add(WasmValue.f64(value));
            pc++;

          case Opcodes.f32Abs:
            final bits = _popValue(
              stack,
              'f32.abs',
            ).castTo(WasmValueType.f32).asF32Bits();
            stack.add(WasmValue.f32Bits(bits & 0x7fffffff));
            pc++;

          case Opcodes.f32Neg:
            final bits = _popValue(
              stack,
              'f32.neg',
            ).castTo(WasmValueType.f32).asF32Bits();
            stack.add(WasmValue.f32Bits(bits ^ 0x80000000));
            pc++;

          case Opcodes.f32Ceil:
            final value = _popValue(
              stack,
              'f32.ceil',
            ).castTo(WasmValueType.f32).asF32();
            stack.add(WasmValue.f32(value.ceilToDouble()));
            pc++;

          case Opcodes.f32Floor:
            final value = _popValue(
              stack,
              'f32.floor',
            ).castTo(WasmValueType.f32).asF32();
            stack.add(WasmValue.f32(value.floorToDouble()));
            pc++;

          case Opcodes.f32Trunc:
            final value = _popValue(
              stack,
              'f32.trunc',
            ).castTo(WasmValueType.f32).asF32();
            stack.add(WasmValue.f32(value.truncateToDouble()));
            pc++;

          case Opcodes.f32Nearest:
            final value = _popValue(
              stack,
              'f32.nearest',
            ).castTo(WasmValueType.f32).asF32();
            stack.add(WasmValue.f32(_nearest(value)));
            pc++;

          case Opcodes.f32Sqrt:
            final value = _popValue(
              stack,
              'f32.sqrt',
            ).castTo(WasmValueType.f32).asF32();
            stack.add(WasmValue.f32(math.sqrt(value)));
            pc++;

          case Opcodes.f32Add:
            final rhs = _popValue(
              stack,
              'f32.add rhs',
            ).castTo(WasmValueType.f32);
            final lhs = _popValue(
              stack,
              'f32.add lhs',
            ).castTo(WasmValueType.f32);
            stack.add(WasmValue.f32(lhs.asF32() + rhs.asF32()));
            pc++;

          case Opcodes.f32Sub:
            final rhs = _popValue(
              stack,
              'f32.sub rhs',
            ).castTo(WasmValueType.f32);
            final lhs = _popValue(
              stack,
              'f32.sub lhs',
            ).castTo(WasmValueType.f32);
            stack.add(WasmValue.f32(lhs.asF32() - rhs.asF32()));
            pc++;

          case Opcodes.f32Mul:
            final rhs = _popValue(
              stack,
              'f32.mul rhs',
            ).castTo(WasmValueType.f32);
            final lhs = _popValue(
              stack,
              'f32.mul lhs',
            ).castTo(WasmValueType.f32);
            stack.add(WasmValue.f32(lhs.asF32() * rhs.asF32()));
            pc++;

          case Opcodes.f32Div:
            final rhs = _popValue(
              stack,
              'f32.div rhs',
            ).castTo(WasmValueType.f32);
            final lhs = _popValue(
              stack,
              'f32.div lhs',
            ).castTo(WasmValueType.f32);
            stack.add(WasmValue.f32(lhs.asF32() / rhs.asF32()));
            pc++;

          case Opcodes.f32Min:
            final rhs = _popValue(
              stack,
              'f32.min rhs',
            ).castTo(WasmValueType.f32);
            final lhs = _popValue(
              stack,
              'f32.min lhs',
            ).castTo(WasmValueType.f32);
            stack.add(WasmValue.f32(_fMin(lhs.asF32(), rhs.asF32())));
            pc++;

          case Opcodes.f32Max:
            final rhs = _popValue(
              stack,
              'f32.max rhs',
            ).castTo(WasmValueType.f32);
            final lhs = _popValue(
              stack,
              'f32.max lhs',
            ).castTo(WasmValueType.f32);
            stack.add(WasmValue.f32(_fMax(lhs.asF32(), rhs.asF32())));
            pc++;

          case Opcodes.f32CopySign:
            final rhsBits = _popValue(
              stack,
              'f32.copysign rhs',
            ).castTo(WasmValueType.f32).asF32Bits();
            final lhsBits = _popValue(
              stack,
              'f32.copysign lhs',
            ).castTo(WasmValueType.f32).asF32Bits();
            stack.add(
              WasmValue.f32Bits(
                (lhsBits & 0x7fffffff) | (rhsBits & 0x80000000),
              ),
            );
            pc++;

          case Opcodes.f64Abs:
            final bits = _popValue(
              stack,
              'f64.abs',
            ).castTo(WasmValueType.f64).asF64Bits();
            stack.add(
              WasmValue.f64Bits(
                bits & BigInt.parse('7fffffffffffffff', radix: 16),
              ),
            );
            pc++;

          case Opcodes.f64Neg:
            final bits = _popValue(
              stack,
              'f64.neg',
            ).castTo(WasmValueType.f64).asF64Bits();
            stack.add(
              WasmValue.f64Bits(
                bits ^ BigInt.parse('8000000000000000', radix: 16),
              ),
            );
            pc++;

          case Opcodes.f64Ceil:
            final value = _popValue(
              stack,
              'f64.ceil',
            ).castTo(WasmValueType.f64).asF64();
            stack.add(WasmValue.f64(value.ceilToDouble()));
            pc++;

          case Opcodes.f64Floor:
            final value = _popValue(
              stack,
              'f64.floor',
            ).castTo(WasmValueType.f64).asF64();
            stack.add(WasmValue.f64(value.floorToDouble()));
            pc++;

          case Opcodes.f64Trunc:
            final value = _popValue(
              stack,
              'f64.trunc',
            ).castTo(WasmValueType.f64).asF64();
            stack.add(WasmValue.f64(value.truncateToDouble()));
            pc++;

          case Opcodes.f64Nearest:
            final value = _popValue(
              stack,
              'f64.nearest',
            ).castTo(WasmValueType.f64).asF64();
            stack.add(WasmValue.f64(_nearest(value)));
            pc++;

          case Opcodes.f64Sqrt:
            final value = _popValue(
              stack,
              'f64.sqrt',
            ).castTo(WasmValueType.f64).asF64();
            stack.add(WasmValue.f64(math.sqrt(value)));
            pc++;

          case Opcodes.f64Add:
            final rhs = _popValue(
              stack,
              'f64.add rhs',
            ).castTo(WasmValueType.f64);
            final lhs = _popValue(
              stack,
              'f64.add lhs',
            ).castTo(WasmValueType.f64);
            stack.add(WasmValue.f64(lhs.asF64() + rhs.asF64()));
            pc++;

          case Opcodes.f64Sub:
            final rhs = _popValue(
              stack,
              'f64.sub rhs',
            ).castTo(WasmValueType.f64);
            final lhs = _popValue(
              stack,
              'f64.sub lhs',
            ).castTo(WasmValueType.f64);
            stack.add(WasmValue.f64(lhs.asF64() - rhs.asF64()));
            pc++;

          case Opcodes.f64Mul:
            final rhs = _popValue(
              stack,
              'f64.mul rhs',
            ).castTo(WasmValueType.f64);
            final lhs = _popValue(
              stack,
              'f64.mul lhs',
            ).castTo(WasmValueType.f64);
            stack.add(WasmValue.f64(lhs.asF64() * rhs.asF64()));
            pc++;

          case Opcodes.f64Div:
            final rhs = _popValue(
              stack,
              'f64.div rhs',
            ).castTo(WasmValueType.f64);
            final lhs = _popValue(
              stack,
              'f64.div lhs',
            ).castTo(WasmValueType.f64);
            stack.add(WasmValue.f64(lhs.asF64() / rhs.asF64()));
            pc++;

          case Opcodes.f64Min:
            final rhs = _popValue(
              stack,
              'f64.min rhs',
            ).castTo(WasmValueType.f64);
            final lhs = _popValue(
              stack,
              'f64.min lhs',
            ).castTo(WasmValueType.f64);
            stack.add(WasmValue.f64(_fMin(lhs.asF64(), rhs.asF64())));
            pc++;

          case Opcodes.f64Max:
            final rhs = _popValue(
              stack,
              'f64.max rhs',
            ).castTo(WasmValueType.f64);
            final lhs = _popValue(
              stack,
              'f64.max lhs',
            ).castTo(WasmValueType.f64);
            stack.add(WasmValue.f64(_fMax(lhs.asF64(), rhs.asF64())));
            pc++;

          case Opcodes.f64CopySign:
            final rhsBits = _popValue(
              stack,
              'f64.copysign rhs',
            ).castTo(WasmValueType.f64).asF64Bits();
            final lhsBits = _popValue(
              stack,
              'f64.copysign lhs',
            ).castTo(WasmValueType.f64).asF64Bits();
            final signMask = BigInt.parse('8000000000000000', radix: 16);
            final magnitudeMask = BigInt.parse('7fffffffffffffff', radix: 16);
            stack.add(
              WasmValue.f64Bits(
                (lhsBits & magnitudeMask) | (rhsBits & signMask),
              ),
            );
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

          case Opcodes.memoryCopy:
            final destinationMemoryIndex = instruction.immediate!;
            final sourceMemoryIndex = instruction.secondaryImmediate!;
            if (destinationMemoryIndex < 0 ||
                destinationMemoryIndex >= memories.length) {
              throw RangeError(
                'memory.copy destination memory index out of range: '
                '$destinationMemoryIndex',
              );
            }
            if (sourceMemoryIndex < 0 || sourceMemoryIndex >= memories.length) {
              throw RangeError(
                'memory.copy source memory index out of range: '
                '$sourceMemoryIndex',
              );
            }
            final destinationIs64 =
                destinationMemoryIndex >= 0 &&
                destinationMemoryIndex < memory64ByIndex.length &&
                memory64ByIndex[destinationMemoryIndex];
            final sourceIs64 =
                sourceMemoryIndex >= 0 &&
                sourceMemoryIndex < memory64ByIndex.length &&
                memory64ByIndex[sourceMemoryIndex];
            final length = destinationIs64 && sourceIs64
                ? _popAsyncSubsetLinearValue(
                    stack,
                    context: 'memory.copy length',
                    expectedType: WasmValueType.i64,
                  )
                : _popAsyncSubsetLinearValue(
                    stack,
                    context: 'memory.copy length',
                    expectedType: WasmValueType.i32,
                  );
            final sourceOffset = _popAsyncSubsetMemoryOperand(
              stack,
              memoryIndex: sourceMemoryIndex,
              memory64ByIndex: memory64ByIndex,
              context: 'memory.copy source offset',
            );
            final destinationOffset = _popAsyncSubsetMemoryOperand(
              stack,
              memoryIndex: destinationMemoryIndex,
              memory64ByIndex: memory64ByIndex,
              context: 'memory.copy destination offset',
            );
            RuntimeMemoryOps.copy(
              sourceMemory: memories[sourceMemoryIndex],
              destinationMemory: memories[destinationMemoryIndex],
              sourceOffset: sourceOffset,
              destinationOffset: destinationOffset,
              length: length,
            );
            pc++;

          case Opcodes.memoryFill:
            final memoryIndex = instruction.immediate!;
            if (memoryIndex < 0 || memoryIndex >= memories.length) {
              throw RangeError(
                'memory.fill memory index out of range: $memoryIndex',
              );
            }
            final length = _popAsyncSubsetMemoryOperationLength(
              stack,
              context: 'memory.fill length',
            );
            final value = _popValue(
              stack,
              'memory.fill value',
            ).castTo(WasmValueType.i32).asI32();
            final destinationOffset = _popAsyncSubsetMemoryOperand(
              stack,
              memoryIndex: memoryIndex,
              memory64ByIndex: memory64ByIndex,
              context: 'memory.fill destination offset',
            );
            RuntimeMemoryOps.fill(
              memory: memories[memoryIndex],
              destinationOffset: destinationOffset,
              value: value,
              length: length,
            );
            pc++;

          case Opcodes.memoryAtomicNotify:
            _popValue(
              stack,
              'memory.atomic.notify count',
            ).castTo(WasmValueType.i32);
            final access = _resolveAsyncSubsetAtomicMemoryAccess(
              stack,
              instruction: instruction,
              memory64ByIndex: memory64ByIndex,
              widthBytes: 4,
              context: 'memory.atomic.notify',
            );
            stack.add(
              WasmValue.i32(
                RuntimeMemoryOps.atomicNotify(
                  memory: access.memory,
                  address: access.address,
                ),
              ),
            );
            pc++;

          case Opcodes.memoryAtomicWait32:
            _popValue(
              stack,
              'memory.atomic.wait32 timeout',
            ).castTo(WasmValueType.i64);
            final expected = _popValue(
              stack,
              'memory.atomic.wait32 expected',
            ).castTo(WasmValueType.i32).asI32().toUnsigned(32);
            final access = _resolveAsyncSubsetAtomicMemoryAccess(
              stack,
              instruction: instruction,
              memory64ByIndex: memory64ByIndex,
              widthBytes: 4,
              context: 'memory.atomic.wait32',
            );
            stack.add(
              WasmValue.i32(
                RuntimeMemoryOps.atomicWait32(
                  memory: access.memory,
                  address: access.address,
                  expected: expected,
                ),
              ),
            );
            pc++;

          case Opcodes.memoryAtomicWait64:
            _popValue(
              stack,
              'memory.atomic.wait64 timeout',
            ).castTo(WasmValueType.i64);
            final expected = WasmI64.unsigned(
              _popValue(
                stack,
                'memory.atomic.wait64 expected',
              ).castTo(WasmValueType.i64).asI64(),
            );
            final access = _resolveAsyncSubsetAtomicMemoryAccess(
              stack,
              instruction: instruction,
              memory64ByIndex: memory64ByIndex,
              widthBytes: 8,
              context: 'memory.atomic.wait64',
            );
            stack.add(
              WasmValue.i32(
                RuntimeMemoryOps.atomicWait64(
                  memory: access.memory,
                  address: access.address,
                  expected: expected,
                ),
              ),
            );
            pc++;

          case Opcodes.atomicFence:
            pc++;

          case Opcodes.i32AtomicLoad:
          case Opcodes.i64AtomicLoad:
          case Opcodes.i32AtomicLoad8U:
          case Opcodes.i32AtomicLoad16U:
          case Opcodes.i64AtomicLoad8U:
          case Opcodes.i64AtomicLoad16U:
          case Opcodes.i64AtomicLoad32U:
            final widthBytes = RuntimeMemoryOps.atomicLoadWidthByOpcode(
              instruction.opcode,
              context: 'async subset',
            );
            final access = _resolveAsyncSubsetAtomicMemoryAccess(
              stack,
              instruction: instruction,
              memory64ByIndex: memory64ByIndex,
              widthBytes: widthBytes,
              context: 'atomic.load',
            );
            stack.add(
              RuntimeMemoryOps.atomicLoadByOpcode(
                memory: access.memory,
                address: access.address,
                opcode: instruction.opcode,
                context: 'async subset',
              ),
            );
            pc++;

          case Opcodes.i32AtomicStore:
          case Opcodes.i64AtomicStore:
          case Opcodes.i32AtomicStore8:
          case Opcodes.i32AtomicStore16:
          case Opcodes.i64AtomicStore8:
          case Opcodes.i64AtomicStore16:
          case Opcodes.i64AtomicStore32:
            final rawValue = _popValue(stack, 'atomic.store value');
            final widthBytes = RuntimeMemoryOps.atomicStoreWidthByOpcode(
              instruction.opcode,
              context: 'async subset',
            );
            final access = _resolveAsyncSubsetAtomicMemoryAccess(
              stack,
              instruction: instruction,
              memory64ByIndex: memory64ByIndex,
              widthBytes: widthBytes,
              context: 'atomic.store',
            );
            RuntimeMemoryOps.atomicStoreByOpcode(
              memory: access.memory,
              address: access.address,
              opcode: instruction.opcode,
              value: rawValue,
              context: 'async subset',
            );
            pc++;

          case Opcodes.i32AtomicRmwAdd:
          case Opcodes.i32AtomicRmwSub:
          case Opcodes.i32AtomicRmwAnd:
          case Opcodes.i32AtomicRmwOr:
          case Opcodes.i32AtomicRmwXor:
          case Opcodes.i32AtomicRmwXchg:
            final operation = switch (instruction.opcode) {
              Opcodes.i32AtomicRmwAdd => (int a, int b) => a + b,
              Opcodes.i32AtomicRmwSub => (int a, int b) => a - b,
              Opcodes.i32AtomicRmwAnd => (int a, int b) => a & b,
              Opcodes.i32AtomicRmwOr => (int a, int b) => a | b,
              Opcodes.i32AtomicRmwXor => (int a, int b) => a ^ b,
              Opcodes.i32AtomicRmwXchg => (int _, int b) => b,
              _ => throw StateError('Unexpected i32 atomic rmw opcode.'),
            };
            final previous = _executeAsyncSubsetAtomicRmwI32(
              stack,
              instruction: instruction,
              memory64ByIndex: memory64ByIndex,
              operation: operation,
              context: 'i32.atomic.rmw',
            );
            stack.add(WasmValue.i32(previous));
            pc++;

          case Opcodes.i64AtomicRmwAdd:
          case Opcodes.i64AtomicRmwSub:
          case Opcodes.i64AtomicRmwAnd:
          case Opcodes.i64AtomicRmwOr:
          case Opcodes.i64AtomicRmwXor:
          case Opcodes.i64AtomicRmwXchg:
            final operation = switch (instruction.opcode) {
              Opcodes.i64AtomicRmwAdd => (BigInt a, BigInt b) => a + b,
              Opcodes.i64AtomicRmwSub => (BigInt a, BigInt b) => a - b,
              Opcodes.i64AtomicRmwAnd => (BigInt a, BigInt b) => a & b,
              Opcodes.i64AtomicRmwOr => (BigInt a, BigInt b) => a | b,
              Opcodes.i64AtomicRmwXor => (BigInt a, BigInt b) => a ^ b,
              Opcodes.i64AtomicRmwXchg => (BigInt _, BigInt b) => b,
              _ => throw StateError('Unexpected i64 atomic rmw opcode.'),
            };
            final previous = _executeAsyncSubsetAtomicRmwI64(
              stack,
              instruction: instruction,
              memory64ByIndex: memory64ByIndex,
              operation: operation,
              context: 'i64.atomic.rmw',
            );
            stack.add(WasmValue.i64(previous));
            pc++;

          case Opcodes.i32AtomicRmw8AddU:
          case Opcodes.i32AtomicRmw16AddU:
          case Opcodes.i32AtomicRmw8SubU:
          case Opcodes.i32AtomicRmw16SubU:
          case Opcodes.i32AtomicRmw8AndU:
          case Opcodes.i32AtomicRmw16AndU:
          case Opcodes.i32AtomicRmw8OrU:
          case Opcodes.i32AtomicRmw16OrU:
          case Opcodes.i32AtomicRmw8XorU:
          case Opcodes.i32AtomicRmw16XorU:
          case Opcodes.i32AtomicRmw8XchgU:
          case Opcodes.i32AtomicRmw16XchgU:
            final descriptor = switch (instruction.opcode) {
              Opcodes.i32AtomicRmw8AddU => (1, (int a, int b) => a + b),
              Opcodes.i32AtomicRmw16AddU => (2, (int a, int b) => a + b),
              Opcodes.i32AtomicRmw8SubU => (1, (int a, int b) => a - b),
              Opcodes.i32AtomicRmw16SubU => (2, (int a, int b) => a - b),
              Opcodes.i32AtomicRmw8AndU => (1, (int a, int b) => a & b),
              Opcodes.i32AtomicRmw16AndU => (2, (int a, int b) => a & b),
              Opcodes.i32AtomicRmw8OrU => (1, (int a, int b) => a | b),
              Opcodes.i32AtomicRmw16OrU => (2, (int a, int b) => a | b),
              Opcodes.i32AtomicRmw8XorU => (1, (int a, int b) => a ^ b),
              Opcodes.i32AtomicRmw16XorU => (2, (int a, int b) => a ^ b),
              Opcodes.i32AtomicRmw8XchgU => (1, (int _, int b) => b),
              Opcodes.i32AtomicRmw16XchgU => (2, (int _, int b) => b),
              _ => throw StateError('Unexpected i32 narrow atomic rmw opcode.'),
            };
            final previous = _executeAsyncSubsetAtomicRmwI32Narrow(
              stack,
              instruction: instruction,
              memory64ByIndex: memory64ByIndex,
              widthBytes: descriptor.$1,
              operation: descriptor.$2,
              context: 'i32.atomic.rmw.narrow',
            );
            stack.add(WasmValue.i32(previous));
            pc++;

          case Opcodes.i64AtomicRmw8AddU:
          case Opcodes.i64AtomicRmw16AddU:
          case Opcodes.i64AtomicRmw32AddU:
          case Opcodes.i64AtomicRmw8SubU:
          case Opcodes.i64AtomicRmw16SubU:
          case Opcodes.i64AtomicRmw32SubU:
          case Opcodes.i64AtomicRmw8AndU:
          case Opcodes.i64AtomicRmw16AndU:
          case Opcodes.i64AtomicRmw32AndU:
          case Opcodes.i64AtomicRmw8OrU:
          case Opcodes.i64AtomicRmw16OrU:
          case Opcodes.i64AtomicRmw32OrU:
          case Opcodes.i64AtomicRmw8XorU:
          case Opcodes.i64AtomicRmw16XorU:
          case Opcodes.i64AtomicRmw32XorU:
          case Opcodes.i64AtomicRmw8XchgU:
          case Opcodes.i64AtomicRmw16XchgU:
          case Opcodes.i64AtomicRmw32XchgU:
            final descriptor = switch (instruction.opcode) {
              Opcodes.i64AtomicRmw8AddU => (1, (int a, int b) => a + b),
              Opcodes.i64AtomicRmw16AddU => (2, (int a, int b) => a + b),
              Opcodes.i64AtomicRmw32AddU => (4, (int a, int b) => a + b),
              Opcodes.i64AtomicRmw8SubU => (1, (int a, int b) => a - b),
              Opcodes.i64AtomicRmw16SubU => (2, (int a, int b) => a - b),
              Opcodes.i64AtomicRmw32SubU => (4, (int a, int b) => a - b),
              Opcodes.i64AtomicRmw8AndU => (1, (int a, int b) => a & b),
              Opcodes.i64AtomicRmw16AndU => (2, (int a, int b) => a & b),
              Opcodes.i64AtomicRmw32AndU => (4, (int a, int b) => a & b),
              Opcodes.i64AtomicRmw8OrU => (1, (int a, int b) => a | b),
              Opcodes.i64AtomicRmw16OrU => (2, (int a, int b) => a | b),
              Opcodes.i64AtomicRmw32OrU => (4, (int a, int b) => a | b),
              Opcodes.i64AtomicRmw8XorU => (1, (int a, int b) => a ^ b),
              Opcodes.i64AtomicRmw16XorU => (2, (int a, int b) => a ^ b),
              Opcodes.i64AtomicRmw32XorU => (4, (int a, int b) => a ^ b),
              Opcodes.i64AtomicRmw8XchgU => (1, (int _, int b) => b),
              Opcodes.i64AtomicRmw16XchgU => (2, (int _, int b) => b),
              Opcodes.i64AtomicRmw32XchgU => (4, (int _, int b) => b),
              _ => throw StateError('Unexpected i64 narrow atomic rmw opcode.'),
            };
            final previous = _executeAsyncSubsetAtomicRmwI64Narrow(
              stack,
              instruction: instruction,
              memory64ByIndex: memory64ByIndex,
              widthBytes: descriptor.$1,
              operation: descriptor.$2,
              context: 'i64.atomic.rmw.narrow',
            );
            stack.add(WasmValue.i64(previous));
            pc++;

          case Opcodes.i32AtomicRmwCmpxchg:
            final previous = _executeAsyncSubsetAtomicCmpxchgI32(
              stack,
              instruction: instruction,
              memory64ByIndex: memory64ByIndex,
              context: 'i32.atomic.cmpxchg',
            );
            stack.add(WasmValue.i32(previous));
            pc++;

          case Opcodes.i64AtomicRmwCmpxchg:
            final previous = _executeAsyncSubsetAtomicCmpxchgI64(
              stack,
              instruction: instruction,
              memory64ByIndex: memory64ByIndex,
              context: 'i64.atomic.cmpxchg',
            );
            stack.add(WasmValue.i64(previous));
            pc++;

          case Opcodes.i32AtomicRmw8CmpxchgU:
          case Opcodes.i32AtomicRmw16CmpxchgU:
            final widthBytes = switch (instruction.opcode) {
              Opcodes.i32AtomicRmw8CmpxchgU => 1,
              Opcodes.i32AtomicRmw16CmpxchgU => 2,
              _ => throw StateError('Unexpected i32 narrow cmpxchg opcode.'),
            };
            final previous = _executeAsyncSubsetAtomicCmpxchgI32Narrow(
              stack,
              instruction: instruction,
              memory64ByIndex: memory64ByIndex,
              widthBytes: widthBytes,
              context: 'i32.atomic.cmpxchg.narrow',
            );
            stack.add(WasmValue.i32(previous));
            pc++;

          case Opcodes.i64AtomicRmw8CmpxchgU:
          case Opcodes.i64AtomicRmw16CmpxchgU:
          case Opcodes.i64AtomicRmw32CmpxchgU:
            final widthBytes = switch (instruction.opcode) {
              Opcodes.i64AtomicRmw8CmpxchgU => 1,
              Opcodes.i64AtomicRmw16CmpxchgU => 2,
              Opcodes.i64AtomicRmw32CmpxchgU => 4,
              _ => throw StateError('Unexpected i64 narrow cmpxchg opcode.'),
            };
            final previous = _executeAsyncSubsetAtomicCmpxchgI64Narrow(
              stack,
              instruction: instruction,
              memory64ByIndex: memory64ByIndex,
              widthBytes: widthBytes,
              context: 'i64.atomic.cmpxchg.narrow',
            );
            stack.add(WasmValue.i64(previous));
            pc++;

          case Opcodes.memoryInit:
            final dataIndex = instruction.immediate!;
            final memoryIndex = instruction.secondaryImmediate!;
            if (dataIndex < 0 || dataIndex >= _asyncDataSegments.length) {
              throw RangeError(
                'memory.init data segment index out of range: $dataIndex',
              );
            }
            if (memoryIndex < 0 || memoryIndex >= memories.length) {
              throw RangeError(
                'memory.init memory index out of range: $memoryIndex',
              );
            }
            final length = _popAsyncSubsetLinearValue(
              stack,
              context: 'memory.init length',
              expectedType: WasmValueType.i32,
            );
            final sourceOffset = _popAsyncSubsetLinearValue(
              stack,
              context: 'memory.init source offset',
              expectedType: WasmValueType.i32,
            );
            final destinationOffset = _popAsyncSubsetMemoryOperand(
              stack,
              memoryIndex: memoryIndex,
              memory64ByIndex: memory64ByIndex,
              context: 'memory.init destination offset',
            );
            RuntimeMemoryOps.initFromDataSegment(
              segment: _asyncDataSegments[dataIndex],
              segmentIndex: dataIndex,
              memory: memories[memoryIndex],
              sourceOffset: sourceOffset,
              destinationOffset: destinationOffset,
              length: length,
            );
            pc++;

          case Opcodes.dataDrop:
            final dataIndex = instruction.immediate!;
            if (dataIndex < 0 || dataIndex >= _asyncDataSegments.length) {
              throw RangeError(
                'data.drop segment index out of range: $dataIndex',
              );
            }
            _asyncDataSegments[dataIndex] = null;
            pc++;

          case Opcodes.tableInit:
            final elementIndex = instruction.immediate!;
            final tableIndex = instruction.secondaryImmediate!;
            if (elementIndex < 0 ||
                elementIndex >= _asyncElementSegments.length) {
              throw RangeError(
                'table.init element segment index out of range: $elementIndex',
              );
            }
            if (tableIndex < 0 || tableIndex >= tables.length) {
              throw RangeError(
                'table.init table index out of range: $tableIndex',
              );
            }
            final length = _popAsyncSubsetLinearValue(
              stack,
              context: 'table.init length',
              expectedType: WasmValueType.i32,
            );
            final sourceOffset = _popAsyncSubsetLinearValue(
              stack,
              context: 'table.init source offset',
              expectedType: WasmValueType.i32,
            );
            final destinationOffset = _popAsyncSubsetTableOperand(
              stack,
              tableIndex: tableIndex,
              table64ByIndex: table64ByIndex,
              context: 'table.init destination offset',
            );
            RuntimeTableOps.initFromElementSegment(
              segment: _asyncElementSegments[elementIndex],
              segmentIndex: elementIndex,
              table: tables[tableIndex],
              sourceOffset: sourceOffset,
              destinationOffset: destinationOffset,
              length: length,
            );
            pc++;

          case Opcodes.elemDrop:
            final elementIndex = instruction.immediate!;
            if (elementIndex < 0 ||
                elementIndex >= _asyncElementSegments.length) {
              throw RangeError(
                'elem.drop segment index out of range: $elementIndex',
              );
            }
            _asyncElementSegments[elementIndex] = null;
            pc++;

          case Opcodes.tableCopy:
            final destinationTableIndex = instruction.immediate!;
            final sourceTableIndex = instruction.secondaryImmediate!;
            if (destinationTableIndex < 0 ||
                destinationTableIndex >= tables.length) {
              throw RangeError(
                'table.copy destination table index out of range: '
                '$destinationTableIndex',
              );
            }
            if (sourceTableIndex < 0 || sourceTableIndex >= tables.length) {
              throw RangeError(
                'table.copy source table index out of range: $sourceTableIndex',
              );
            }
            final destinationIs64 =
                destinationTableIndex >= 0 &&
                destinationTableIndex < table64ByIndex.length &&
                table64ByIndex[destinationTableIndex];
            final sourceIs64 =
                sourceTableIndex >= 0 &&
                sourceTableIndex < table64ByIndex.length &&
                table64ByIndex[sourceTableIndex];
            final length = destinationIs64 && sourceIs64
                ? _popAsyncSubsetLinearValue(
                    stack,
                    context: 'table.copy length',
                    expectedType: WasmValueType.i64,
                  )
                : _popAsyncSubsetLinearValue(
                    stack,
                    context: 'table.copy length',
                    expectedType: WasmValueType.i32,
                  );
            final sourceOffset = _popAsyncSubsetTableOperand(
              stack,
              tableIndex: sourceTableIndex,
              table64ByIndex: table64ByIndex,
              context: 'table.copy source offset',
            );
            final destinationOffset = _popAsyncSubsetTableOperand(
              stack,
              tableIndex: destinationTableIndex,
              table64ByIndex: table64ByIndex,
              context: 'table.copy destination offset',
            );
            RuntimeTableOps.copy(
              sourceTable: tables[sourceTableIndex],
              destinationTable: tables[destinationTableIndex],
              sourceOffset: sourceOffset,
              destinationOffset: destinationOffset,
              length: length,
            );
            pc++;

          case Opcodes.tableGrow:
            final tableIndex = instruction.immediate!;
            if (tableIndex < 0 || tableIndex >= tables.length) {
              throw RangeError(
                'table.grow table index out of range: $tableIndex',
              );
            }
            final delta = _popAsyncSubsetTableOperand(
              stack,
              tableIndex: tableIndex,
              table64ByIndex: table64ByIndex,
              context: 'table.grow delta',
            );
            final fillValue = _popAsyncSubsetRef(
              stack,
              context: 'table.grow fill value',
            );
            final previousLength = tables[tableIndex].grow(delta, fillValue);
            stack.add(
              _asyncSubsetTableIndexValue(
                tableIndex: tableIndex,
                table64ByIndex: table64ByIndex,
                value: previousLength,
              ),
            );
            pc++;

          case Opcodes.tableSize:
            final tableIndex = instruction.immediate!;
            if (tableIndex < 0 || tableIndex >= tables.length) {
              throw RangeError(
                'table.size table index out of range: $tableIndex',
              );
            }
            stack.add(
              _asyncSubsetTableIndexValue(
                tableIndex: tableIndex,
                table64ByIndex: table64ByIndex,
                value: tables[tableIndex].length,
              ),
            );
            pc++;

          case Opcodes.tableFill:
            final tableIndex = instruction.immediate!;
            if (tableIndex < 0 || tableIndex >= tables.length) {
              throw RangeError(
                'table.fill table index out of range: $tableIndex',
              );
            }
            final length = _popAsyncSubsetTableOperand(
              stack,
              tableIndex: tableIndex,
              table64ByIndex: table64ByIndex,
              context: 'table.fill length',
            );
            final fillValue = _popAsyncSubsetRef(
              stack,
              context: 'table.fill value',
            );
            final destinationOffset = _popAsyncSubsetTableOperand(
              stack,
              tableIndex: tableIndex,
              table64ByIndex: table64ByIndex,
              context: 'table.fill destination offset',
            );
            RuntimeTableOps.fill(
              table: tables[tableIndex],
              destinationOffset: destinationOffset,
              value: fillValue,
              length: length,
            );
            pc++;

          case Opcodes.i32Load:
          case Opcodes.i64Load:
          case Opcodes.f32Load:
          case Opcodes.f64Load:
          case Opcodes.i32Load8S:
          case Opcodes.i32Load8U:
          case Opcodes.i32Load16S:
          case Opcodes.i32Load16U:
          case Opcodes.i64Load8S:
          case Opcodes.i64Load8U:
          case Opcodes.i64Load16S:
          case Opcodes.i64Load16U:
          case Opcodes.i64Load32S:
          case Opcodes.i64Load32U:
            final memArg = instruction.memArg;
            if (memArg == null) {
              throw StateError('Malformed memory load instruction memarg.');
            }
            final target = _resolveAsyncSubsetMemoryTarget(
              memArg: memArg,
              memory64ByIndex: memory64ByIndex,
              context: 'load',
            );
            final addressValue = _popValue(stack, 'memory.load address');
            final address = _resolveAsyncSubsetMemoryAddress(
              memArg: memArg,
              baseAddressValue: addressValue,
              isMemory64: target.isMemory64,
              context: 'memory.load',
            );
            stack.add(
              RuntimeMemoryOps.loadByOpcode(
                memory: target.memory,
                address: address,
                opcode: instruction.opcode,
                context: 'async subset',
              ),
            );
            pc++;

          case Opcodes.i32Store:
          case Opcodes.i64Store:
          case Opcodes.f32Store:
          case Opcodes.f64Store:
          case Opcodes.i32Store8:
          case Opcodes.i32Store16:
          case Opcodes.i64Store8:
          case Opcodes.i64Store16:
          case Opcodes.i64Store32:
            final memArg = instruction.memArg;
            if (memArg == null) {
              throw StateError('Malformed memory store instruction memarg.');
            }
            final target = _resolveAsyncSubsetMemoryTarget(
              memArg: memArg,
              memory64ByIndex: memory64ByIndex,
              context: 'store',
            );
            final rawValue = _popValue(stack, 'memory.store value');
            final addressValue = _popValue(stack, 'memory.store address');
            final address = _resolveAsyncSubsetMemoryAddress(
              memArg: memArg,
              baseAddressValue: addressValue,
              isMemory64: target.isMemory64,
              context: 'memory.store',
            );
            RuntimeMemoryOps.storeByOpcode(
              memory: target.memory,
              address: address,
              opcode: instruction.opcode,
              value: rawValue,
              context: 'async subset',
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
            final params = _popArgsForTypes(
              stack,
              parameterTypes,
              context: 'if',
            );
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

          case Opcodes.tryLegacy:
            final endIndex = instruction.endIndex;
            if (endIndex == null) {
              throw StateError('Malformed try without end index.');
            }
            final parameterTypes =
                instruction.blockParameterTypes ?? const <WasmValueType>[];
            final params = _popArgsForTypes(
              stack,
              parameterTypes,
              context: 'try',
            );
            final baseHeight = stack.length;
            stack.addAll(params);
            controlStack.add(
              _AsyncSubsetControlFrame(
                kind: _AsyncSubsetControlKind.tryLegacy,
                stackBaseHeight: baseHeight,
                startIndex: pc,
                endIndex: endIndex,
                parameterTypes: parameterTypes,
                resultTypes:
                    instruction.blockResultTypes ?? const <WasmValueType>[],
                legacyCatches: instruction.legacyCatches,
                delegateDepth: instruction.delegateDepth,
              ),
            );
            pc++;

          case Opcodes.tryTable:
            final endIndex = instruction.endIndex;
            if (endIndex == null) {
              throw StateError('Malformed try_table without end index.');
            }
            final parameterTypes =
                instruction.blockParameterTypes ?? const <WasmValueType>[];
            final params = _popArgsForTypes(
              stack,
              parameterTypes,
              context: 'try_table',
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
                tryTableCatches: instruction.tryTableCatches,
              ),
            );
            pc++;

          case Opcodes.catchTag:
          case Opcodes.catchAll:
            pc = _handleLegacyCatchBoundaryInAsyncSubset(
              stack: stack,
              controlStack: controlStack,
              pc: pc,
            );

          case Opcodes.delegate:
            if (controlStack.isEmpty ||
                controlStack.last.kind != _AsyncSubsetControlKind.tryLegacy) {
              throw StateError('`delegate` without matching `try`.');
            }
            final frame = controlStack.removeLast();
            frame
              ..activeException = null
              ..activeCatchInstructionIndex = null;
            _leaveAsyncSubsetControlFrame(stack, frame, context: 'delegate');
            pc++;

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

          case Opcodes.brOnNull:
            final value = _popAsyncSubsetRef(
              stack,
              context: 'br_on_null operand',
            );
            if (value == null) {
              pc = _branchInAsyncSubset(
                depth: instruction.immediate!,
                stack: stack,
                controlStack: controlStack,
                context: 'br_on_null',
              );
            } else {
              stack.add(WasmValue.i32(value));
              pc++;
            }

          case Opcodes.brOnNonNull:
            final value = _popAsyncSubsetRef(
              stack,
              context: 'br_on_non_null operand',
            );
            if (value != null) {
              stack.add(WasmValue.i32(value));
              pc = _branchInAsyncSubset(
                depth: instruction.immediate!,
                stack: stack,
                controlStack: controlStack,
                context: 'br_on_non_null',
              );
            } else {
              pc++;
            }

          case Opcodes.brTable:
            final selector = _popValue(
              stack,
              'br_table selector',
            ).castTo(WasmValueType.i32).asI32();
            final targets = instruction.tableDepths;
            if (targets == null || targets.isEmpty) {
              throw StateError('Invalid br_table targets.');
            }
            final defaultDepth = targets.last;
            final depth = selector >= 0 && selector < targets.length - 1
                ? targets[selector]
                : defaultDepth;
            pc = _branchInAsyncSubset(
              depth: depth,
              stack: stack,
              controlStack: controlStack,
              context: 'br_table',
            );

          case Opcodes.throwTag:
            _throwTagInAsyncSubset(stack, instruction);

          case Opcodes.throwRef:
            _throwRefInAsyncSubset(stack);

          case Opcodes.rethrowTag:
            _rethrowLegacyInAsyncSubset(
              controlStack: controlStack,
              depth: instruction.immediate!,
            );

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

          case Opcodes.callRef:
            final typeIndex = instruction.immediate!;
            if (typeIndex < 0 || typeIndex >= module.types.length) {
              throw RangeError('call_ref type index out of range: $typeIndex');
            }
            final expectedType = module.types[typeIndex];
            if (!expectedType.isFunctionType) {
              throw StateError(
                'call_ref expected non-function type $typeIndex.',
              );
            }
            final functionReference = _popAsyncSubsetRef(
              stack,
              context: 'call_ref function reference',
            );
            if (functionReference == null) {
              throw StateError('call_ref to null function reference.');
            }
            final targetIndex = _functionRefIdToIndex[functionReference];
            if (targetIndex == null) {
              throw StateError('call_ref to non-function reference.');
            }
            final target = functions[targetIndex];
            if (!_asyncSubsetFunctionMatchesType(target, typeIndex)) {
              throw StateError('call_ref signature mismatch trap');
            }
            final callArgs = _popArgsForTypes(
              stack,
              expectedType.params,
              context: 'call_ref',
            );
            final callResults = await _invokeFunctionAsyncSubset(
              targetIndex,
              callArgs,
              depth: depth + 1,
            );
            stack.addAll(callResults);
            pc++;

          case Opcodes.callIndirect:
            final typeIndex = instruction.immediate!;
            if (typeIndex < 0 || typeIndex >= module.types.length) {
              throw RangeError(
                'call_indirect type index out of range: $typeIndex',
              );
            }
            final tableIndex = instruction.secondaryImmediate!;
            final tableElementIndex = _popAsyncSubsetTableOperand(
              stack,
              tableIndex: tableIndex,
              table64ByIndex: table64ByIndex,
              context: 'call_indirect table index',
            );
            final targetFunctionRef = tables[tableIndex][tableElementIndex];
            if (targetFunctionRef == null) {
              throw StateError('call_indirect to null table element.');
            }
            final targetIndex = _functionRefIdToIndex[targetFunctionRef];
            if (targetIndex == null) {
              throw StateError('call_indirect to non-function table element.');
            }
            final expectedType = module.types[typeIndex];
            if (!expectedType.isFunctionType) {
              throw StateError(
                'call_indirect expected non-function type $typeIndex.',
              );
            }
            final target = functions[targetIndex];
            if (!_asyncSubsetFunctionMatchesType(target, typeIndex)) {
              throw StateError('call_indirect signature mismatch trap');
            }
            final callArgs = _popArgsForTypes(
              stack,
              expectedType.params,
              context: 'call_indirect',
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

          case Opcodes.returnCallRef:
            final typeIndex = instruction.immediate!;
            if (typeIndex < 0 || typeIndex >= module.types.length) {
              throw RangeError(
                'return_call_ref type index out of range: $typeIndex',
              );
            }
            final expectedType = module.types[typeIndex];
            if (!expectedType.isFunctionType) {
              throw StateError(
                'call_ref expected non-function type $typeIndex.',
              );
            }
            final functionReference = _popAsyncSubsetRef(
              stack,
              context: 'return_call_ref function reference',
            );
            if (functionReference == null) {
              throw StateError('call_ref to null function reference.');
            }
            final targetIndex = _functionRefIdToIndex[functionReference];
            if (targetIndex == null) {
              throw StateError('call_ref to non-function reference.');
            }
            final target = functions[targetIndex];
            if (!_asyncSubsetFunctionMatchesType(target, typeIndex)) {
              throw StateError('call_ref signature mismatch trap');
            }
            final callArgs = _popArgsForTypes(
              stack,
              expectedType.params,
              context: 'return_call_ref',
            );
            return _invokeFunctionAsyncSubset(
              targetIndex,
              callArgs,
              depth: depth + 1,
            );

          case Opcodes.returnCallIndirect:
            final typeIndex = instruction.immediate!;
            if (typeIndex < 0 || typeIndex >= module.types.length) {
              throw RangeError(
                'return_call_indirect type index out of range: $typeIndex',
              );
            }
            final tableIndex = instruction.secondaryImmediate!;
            final tableElementIndex = _popAsyncSubsetTableOperand(
              stack,
              tableIndex: tableIndex,
              table64ByIndex: table64ByIndex,
              context: 'return_call_indirect table index',
            );
            final targetFunctionRef = tables[tableIndex][tableElementIndex];
            if (targetFunctionRef == null) {
              throw StateError('call_indirect to null table element.');
            }
            final targetIndex = _functionRefIdToIndex[targetFunctionRef];
            if (targetIndex == null) {
              throw StateError('call_indirect to non-function table element.');
            }
            final expectedType = module.types[typeIndex];
            if (!expectedType.isFunctionType) {
              throw StateError(
                'call_indirect expected non-function type $typeIndex.',
              );
            }
            final target = functions[targetIndex];
            if (!_asyncSubsetFunctionMatchesType(target, typeIndex)) {
              throw StateError('call_indirect signature mismatch trap');
            }
            final callArgs = _popArgsForTypes(
              stack,
              expectedType.params,
              context: 'return_call_indirect',
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
      } on _AsyncSubsetThrownException catch (thrown) {
        final handledPc = _handleAsyncSubsetThrownException(
          thrown,
          stack: stack,
          controlStack: controlStack,
        );
        if (handledPc == null) {
          rethrow;
        }
        pc = handledPc;
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
    RuntimeControlOps.leaveFrameExact(
      stack: stack,
      stackBaseHeight: frame.stackBaseHeight,
      resultTypes: frame.resultTypes,
      context: context,
    );
  }

  int _handleLegacyCatchBoundaryInAsyncSubset({
    required List<WasmValue> stack,
    required List<_AsyncSubsetControlFrame> controlStack,
    required int pc,
  }) {
    if (controlStack.isEmpty ||
        controlStack.last.kind != _AsyncSubsetControlKind.tryLegacy) {
      throw StateError('`catch` without matching `try`.');
    }
    final frame = controlStack.last;
    final activeCatchInstructionIndex = frame.activeCatchInstructionIndex;
    if (frame.activeException != null) {
      if (activeCatchInstructionIndex == pc) {
        return pc + 1;
      }
      frame
        ..activeException = null
        ..activeCatchInstructionIndex = null;
      controlStack.removeLast();
      _leaveAsyncSubsetControlFrame(stack, frame, context: 'catch');
      return frame.endIndex + 1;
    }

    controlStack.removeLast();
    _leaveAsyncSubsetControlFrame(stack, frame, context: 'catch');
    return frame.endIndex + 1;
  }

  int? _handleAsyncSubsetThrownException(
    _AsyncSubsetThrownException thrown, {
    required List<WasmValue> stack,
    required List<_AsyncSubsetControlFrame> controlStack,
  }) {
    final exceptionRef = _allocateAsyncSubsetExceptionRef(thrown);
    var i = controlStack.length - 1;
    while (i >= 0) {
      final frame = controlStack[i];
      final tryTableCatches = frame.tryTableCatches;
      if (tryTableCatches != null && tryTableCatches.isNotEmpty) {
        TryTableCatchClause? matchedTryTableCatch;
        for (final clause in tryTableCatches) {
          switch (clause.kind) {
            case TryTableCatchKind.catchTag:
            case TryTableCatchKind.catchRef:
              final tagIndex = clause.tagIndex;
              if (tagIndex == null) {
                continue;
              }
              final resolvedTagIndex = _checkAsyncSubsetTagIndex(tagIndex);
              if (_tagNominalTypeKeys[resolvedTagIndex] ==
                  thrown.nominalTypeKey) {
                matchedTryTableCatch = clause;
              }
            case TryTableCatchKind.catchAll:
            case TryTableCatchKind.catchAllRef:
              matchedTryTableCatch = clause;
            default:
              continue;
          }
          if (matchedTryTableCatch != null) {
            break;
          }
        }

        if (matchedTryTableCatch != null) {
          if (i + 1 < controlStack.length) {
            controlStack.removeRange(i + 1, controlStack.length);
          }
          _truncateAsyncSubsetStackToHeight(
            stack,
            frame.stackBaseHeight,
            context: 'exception unwind',
          );
          switch (matchedTryTableCatch.kind) {
            case TryTableCatchKind.catchTag:
              stack.addAll(thrown.values);
            case TryTableCatchKind.catchRef:
              stack
                ..addAll(thrown.values)
                ..add(WasmValue.i32(exceptionRef));
            case TryTableCatchKind.catchAll:
              break;
            case TryTableCatchKind.catchAllRef:
              stack.add(WasmValue.i32(exceptionRef));
            default:
              i--;
              continue;
          }
          return _branchInAsyncSubset(
            depth: matchedTryTableCatch.labelDepth + 1,
            stack: stack,
            controlStack: controlStack,
            context: 'try_table catch',
          );
        }
        i--;
        continue;
      }

      if (frame.kind != _AsyncSubsetControlKind.tryLegacy) {
        i--;
        continue;
      }
      if (frame.activeException != null) {
        i--;
        continue;
      }

      final legacyCatches = frame.legacyCatches ?? const <LegacyCatchClause>[];
      LegacyCatchClause? matched;
      for (final clause in legacyCatches) {
        switch (clause.kind) {
          case LegacyCatchKind.catchTag:
            final tagIndex = clause.tagIndex;
            if (tagIndex == null) {
              continue;
            }
            final resolvedTagIndex = _checkAsyncSubsetTagIndex(tagIndex);
            if (_tagNominalTypeKeys[resolvedTagIndex] ==
                thrown.nominalTypeKey) {
              matched = clause;
            }
          case LegacyCatchKind.catchAll:
            matched = clause;
          default:
            continue;
        }
        if (matched != null) {
          break;
        }
      }

      if (matched != null) {
        if (i + 1 < controlStack.length) {
          controlStack.removeRange(i + 1, controlStack.length);
        }
        _truncateAsyncSubsetStackToHeight(
          stack,
          frame.stackBaseHeight,
          context: 'exception unwind',
        );
        if (matched.kind == LegacyCatchKind.catchTag) {
          stack.addAll(thrown.values);
        }
        frame
          ..activeException = thrown
          ..activeCatchInstructionIndex = matched.handlerIndex;
        return matched.handlerIndex;
      }

      final delegateDepth = frame.delegateDepth;
      if (delegateDepth != null) {
        final delegatedIndex = i - delegateDepth - 1;
        if (delegatedIndex < 0) {
          return null;
        }
        i = delegatedIndex;
        continue;
      }
      i--;
    }
    return null;
  }

  void _truncateAsyncSubsetStackToHeight(
    List<WasmValue> stack,
    int height, {
    required String context,
  }) {
    RuntimeStackOps.truncateToHeight(stack, height, context: context);
  }

  Never _throwTagInAsyncSubset(List<WasmValue> stack, Instruction instruction) {
    final tagIndex = _checkAsyncSubsetTagIndex(instruction.immediate!);
    final tagType = _tagTypes[tagIndex];
    final values = _popArgsForTypes(stack, tagType.params, context: 'throw');
    throw _AsyncSubsetThrownException(
      nominalTypeKey: _tagNominalTypeKeys[tagIndex],
      values: values,
    );
  }

  Never _throwRefInAsyncSubset(List<WasmValue> stack) {
    final exceptionRef = _popAsyncSubsetRef(
      stack,
      context: 'throw_ref operand',
    );
    if (exceptionRef == null) {
      throw StateError('null exception reference');
    }
    final exception = _asyncExceptionObjects[exceptionRef];
    if (exception == null) {
      throw StateError('unknown exception reference');
    }
    throw exception;
  }

  int _allocateAsyncSubsetExceptionRef(_AsyncSubsetThrownException exception) {
    final reference = _nextAsyncExceptionRef++;
    _asyncExceptionObjects[reference] = exception;
    return reference;
  }

  Never _rethrowLegacyInAsyncSubset({
    required List<_AsyncSubsetControlFrame> controlStack,
    required int depth,
  }) {
    if (depth < 0 || depth >= controlStack.length) {
      throw StateError('invalid rethrow label');
    }
    final target = controlStack[controlStack.length - 1 - depth];
    final activeException = target.activeException;
    if (activeException == null) {
      throw StateError('invalid rethrow label');
    }
    throw activeException;
  }

  int _checkAsyncSubsetTagIndex(int tagIndex) {
    if (tagIndex < 0 || tagIndex >= _tagTypes.length) {
      throw RangeError('Invalid tag index: $tagIndex');
    }
    return tagIndex;
  }

  int _branchInAsyncSubset({
    required int depth,
    required List<WasmValue> stack,
    required List<_AsyncSubsetControlFrame> controlStack,
    required String context,
  }) {
    final targetIndex = RuntimeControlOps.targetIndexForDepth(
      depth,
      controlStack.length,
      context: context,
    );
    final target = controlStack[targetIndex];

    RuntimeControlOps.rebaseStackForBranch(
      stack: stack,
      branchTypes: target.branchTypes,
      stackBaseHeight: target.stackBaseHeight,
      context: '$context depth=$depth',
    );

    if (target.kind == _AsyncSubsetControlKind.loop) {
      controlStack.removeRange(targetIndex + 1, controlStack.length);
      return target.startIndex + 1;
    }

    controlStack.removeRange(targetIndex, controlStack.length);
    return target.endIndex + 1;
  }

  int _popAsyncSubsetTableOperand(
    List<WasmValue> stack, {
    required int tableIndex,
    required List<bool> table64ByIndex,
    required String context,
  }) {
    if (tableIndex < 0 || tableIndex >= tables.length) {
      throw RangeError(
        'Invalid table index: $tableIndex (count=${tables.length}).',
      );
    }
    final isTable64 =
        tableIndex >= 0 &&
        tableIndex < table64ByIndex.length &&
        table64ByIndex[tableIndex];
    final operand = isTable64
        ? WasmI64.unsigned(
            _popValue(stack, context).castTo(WasmValueType.i64).asI64(),
          )
        : BigInt.from(
                _popValue(stack, context).castTo(WasmValueType.i32).asI32(),
              ) &
              BigInt.from(0xffffffff);
    final maxSupported = BigInt.from(wasmAddressSpaceBytes);
    if (operand > maxSupported) {
      throw RangeError(
        '$context exceeds supported linear range: '
        '$operand > $wasmAddressSpaceBytes.',
      );
    }
    return operand.toInt();
  }

  int? _popAsyncSubsetRef(List<WasmValue> stack, {required String context}) {
    final rawRef = _popValue(stack, context).castTo(WasmValueType.i32).asI32();
    return rawRef == -1 ? null : rawRef;
  }

  WasmValue _asyncSubsetTableIndexValue({
    required int tableIndex,
    required List<bool> table64ByIndex,
    required int value,
  }) {
    final isTable64 =
        tableIndex >= 0 &&
        tableIndex < table64ByIndex.length &&
        table64ByIndex[tableIndex];
    if (isTable64) {
      final i64Value = value < 0
          ? WasmI64.signed(value)
          : WasmI64.unsigned(value);
      return WasmValue.i64(i64Value);
    }
    return WasmValue.i32(value);
  }

  Map<int, int> _buildFunctionRefIdToIndex() {
    final mapping = <int, int>{};
    for (
      var functionIndex = 0;
      functionIndex < functions.length;
      functionIndex++
    ) {
      final refId = WasmVm.functionRefIdFor(
        namespace: _functionRefNamespace,
        functionIndex: functionIndex,
      );
      mapping[refId] = functionIndex;
    }
    return mapping;
  }

  bool _asyncSubsetFunctionMatchesType(
    RuntimeFunction function,
    int targetTypeIndex,
  ) {
    if (targetTypeIndex < 0 || targetTypeIndex >= module.types.length) {
      return false;
    }
    final targetType = module.types[targetTypeIndex];
    if (!targetType.isFunctionType) {
      return false;
    }
    if (!_sameFunctionSignature(function.type, targetType)) {
      return false;
    }
    if (_isAsyncSubsetTypeSubtype(
      function.declaredTypeIndex,
      targetTypeIndex,
    )) {
      return true;
    }
    final expectedDepth = _functionTypeDepth(module, targetTypeIndex);
    return function.runtimeTypeDepth >= expectedDepth;
  }

  bool _isAsyncSubsetTypeSubtype(int subTypeIndex, int superTypeIndex) {
    if (subTypeIndex == superTypeIndex) {
      return true;
    }
    if (subTypeIndex < 0 ||
        subTypeIndex >= module.types.length ||
        superTypeIndex < 0 ||
        superTypeIndex >= module.types.length) {
      return false;
    }
    final pending = <int>[subTypeIndex];
    final seen = <int>{};
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (!seen.add(current)) {
        continue;
      }
      if (current < 0 || current >= module.types.length) {
        continue;
      }
      for (final parent in module.types[current].superTypeIndices) {
        if (parent == superTypeIndex) {
          return true;
        }
        pending.add(parent);
      }
    }
    return false;
  }

  ({WasmMemory memory, bool isMemory64}) _resolveAsyncSubsetMemoryTarget({
    required MemArg memArg,
    required List<bool> memory64ByIndex,
    required String context,
  }) {
    final memoryIndex = memArg.memoryIndex;
    if (memoryIndex < 0 || memoryIndex >= memories.length) {
      throw RangeError(
        '$context memory index out of range: $memoryIndex '
        '(count=${memories.length}).',
      );
    }
    final isMemory64 =
        memoryIndex >= 0 &&
        memoryIndex < memory64ByIndex.length &&
        memory64ByIndex[memoryIndex];
    return (memory: memories[memoryIndex], isMemory64: isMemory64);
  }

  int _popAsyncSubsetLinearValue(
    List<WasmValue> stack, {
    required String context,
    required WasmValueType expectedType,
  }) {
    final rawValue = _popValue(stack, context).castTo(expectedType);
    final unsigned = expectedType == WasmValueType.i64
        ? WasmI64.unsigned(rawValue.asI64())
        : BigInt.from(rawValue.asI32().toUnsigned(32));
    if (unsigned < BigInt.zero) {
      throw RangeError('$context underflow: $unsigned');
    }
    final maxSupported = BigInt.from(wasmAddressSpaceBytes);
    if (unsigned > maxSupported) {
      throw RangeError(
        '$context exceeds supported linear range: '
        '$unsigned > $wasmAddressSpaceBytes.',
      );
    }
    return unsigned.toInt();
  }

  int _popAsyncSubsetMemoryOperand(
    List<WasmValue> stack, {
    required int memoryIndex,
    required List<bool> memory64ByIndex,
    required String context,
  }) {
    if (memoryIndex < 0 || memoryIndex >= memories.length) {
      throw RangeError(
        'Invalid memory index: $memoryIndex (count=${memories.length}).',
      );
    }
    final isMemory64 =
        memoryIndex >= 0 &&
        memoryIndex < memory64ByIndex.length &&
        memory64ByIndex[memoryIndex];
    return _popAsyncSubsetLinearValue(
      stack,
      context: context,
      expectedType: isMemory64 ? WasmValueType.i64 : WasmValueType.i32,
    );
  }

  int _popAsyncSubsetMemoryOperationLength(
    List<WasmValue> stack, {
    required String context,
  }) {
    final value = _popValue(stack, context);
    return switch (value.type) {
      WasmValueType.i32 => _popAsyncSubsetLinearValue(
        <WasmValue>[value],
        context: context,
        expectedType: WasmValueType.i32,
      ),
      WasmValueType.i64 => _popAsyncSubsetLinearValue(
        <WasmValue>[value],
        context: context,
        expectedType: WasmValueType.i64,
      ),
      _ => throw StateError(
        'Type mismatch: expected i32/i64 length for $context, got ${value.type}.',
      ),
    };
  }

  int _resolveAsyncSubsetMemoryAddress({
    required MemArg memArg,
    required WasmValue baseAddressValue,
    required bool isMemory64,
    required String context,
  }) {
    final base = isMemory64
        ? baseAddressValue.castTo(WasmValueType.i64).asI64().toUnsigned(64)
        : BigInt.from(
            baseAddressValue.castTo(WasmValueType.i32).asI32().toUnsigned(32),
          );
    final offset = BigInt.from(memArg.offset);
    final address = base + offset;
    if (address < BigInt.zero) {
      throw RangeError('$context address underflow: $address');
    }
    final maxAddress = BigInt.from(wasmAddressSpaceBytes - 1);
    if (address > maxAddress) {
      throw RangeError('$context address exceeds 32-bit memory: $address');
    }
    return address.toInt();
  }

  ({WasmMemory memory, int address}) _resolveAsyncSubsetAtomicMemoryAccess(
    List<WasmValue> stack, {
    required Instruction instruction,
    required List<bool> memory64ByIndex,
    required int widthBytes,
    required String context,
  }) {
    final memArg = instruction.memArg;
    if (memArg == null) {
      throw StateError('Malformed $context memarg.');
    }
    final target = _resolveAsyncSubsetMemoryTarget(
      memArg: memArg,
      memory64ByIndex: memory64ByIndex,
      context: context,
    );
    final addressValue = _popValue(stack, '$context address');
    final address = _resolveAsyncSubsetMemoryAddress(
      memArg: memArg,
      baseAddressValue: addressValue,
      isMemory64: target.isMemory64,
      context: context,
    );
    RuntimeMemoryOps.requireAtomicAlignment(
      address,
      widthBytes: widthBytes,
      context: context,
    );
    return (memory: target.memory, address: address);
  }

  int _executeAsyncSubsetAtomicRmwI32(
    List<WasmValue> stack, {
    required Instruction instruction,
    required List<bool> memory64ByIndex,
    required int Function(int current, int operand) operation,
    required String context,
  }) {
    final operand = _popValue(
      stack,
      '$context operand',
    ).castTo(WasmValueType.i32).asI32().toUnsigned(32);
    final access = _resolveAsyncSubsetAtomicMemoryAccess(
      stack,
      instruction: instruction,
      memory64ByIndex: memory64ByIndex,
      widthBytes: 4,
      context: context,
    );
    return RuntimeMemoryOps.atomicRmwI32(
      memory: access.memory,
      address: access.address,
      operand: operand,
      operation: operation,
    );
  }

  BigInt _executeAsyncSubsetAtomicRmwI64(
    List<WasmValue> stack, {
    required Instruction instruction,
    required List<bool> memory64ByIndex,
    required BigInt Function(BigInt current, BigInt operand) operation,
    required String context,
  }) {
    final operand = WasmI64.unsigned(
      _popValue(stack, '$context operand').castTo(WasmValueType.i64).asI64(),
    );
    final access = _resolveAsyncSubsetAtomicMemoryAccess(
      stack,
      instruction: instruction,
      memory64ByIndex: memory64ByIndex,
      widthBytes: 8,
      context: context,
    );
    return RuntimeMemoryOps.atomicRmwI64(
      memory: access.memory,
      address: access.address,
      operand: operand,
      operation: operation,
    );
  }

  int _executeAsyncSubsetAtomicRmwI32Narrow(
    List<WasmValue> stack, {
    required Instruction instruction,
    required List<bool> memory64ByIndex,
    required int widthBytes,
    required int Function(int current, int operand) operation,
    required String context,
  }) {
    final bits = widthBytes * 8;
    final operand = _popValue(
      stack,
      '$context operand',
    ).castTo(WasmValueType.i32).asI32().toUnsigned(bits);
    final access = _resolveAsyncSubsetAtomicMemoryAccess(
      stack,
      instruction: instruction,
      memory64ByIndex: memory64ByIndex,
      widthBytes: widthBytes,
      context: context,
    );
    return RuntimeMemoryOps.atomicRmwNarrowUnsigned(
      memory: access.memory,
      address: access.address,
      widthBytes: widthBytes,
      operand: operand,
      operation: operation,
      context: context,
    );
  }

  int _executeAsyncSubsetAtomicRmwI64Narrow(
    List<WasmValue> stack, {
    required Instruction instruction,
    required List<bool> memory64ByIndex,
    required int widthBytes,
    required int Function(int current, int operand) operation,
    required String context,
  }) {
    final bits = widthBytes * 8;
    final mask = (BigInt.one << bits) - BigInt.one;
    final operand =
        (WasmI64.unsigned(
                  _popValue(
                    stack,
                    '$context operand',
                  ).castTo(WasmValueType.i64).asI64(),
                ) &
                mask)
            .toInt();
    final access = _resolveAsyncSubsetAtomicMemoryAccess(
      stack,
      instruction: instruction,
      memory64ByIndex: memory64ByIndex,
      widthBytes: widthBytes,
      context: context,
    );
    return RuntimeMemoryOps.atomicRmwNarrowUnsigned(
      memory: access.memory,
      address: access.address,
      widthBytes: widthBytes,
      operand: operand,
      operation: operation,
      context: context,
    );
  }

  int _executeAsyncSubsetAtomicCmpxchgI32(
    List<WasmValue> stack, {
    required Instruction instruction,
    required List<bool> memory64ByIndex,
    required String context,
  }) {
    final replacement = _popValue(
      stack,
      '$context replacement',
    ).castTo(WasmValueType.i32).asI32().toUnsigned(32);
    final expected = _popValue(
      stack,
      '$context expected',
    ).castTo(WasmValueType.i32).asI32().toUnsigned(32);
    final access = _resolveAsyncSubsetAtomicMemoryAccess(
      stack,
      instruction: instruction,
      memory64ByIndex: memory64ByIndex,
      widthBytes: 4,
      context: context,
    );
    return RuntimeMemoryOps.atomicCmpxchgI32(
      memory: access.memory,
      address: access.address,
      expected: expected,
      replacement: replacement,
    );
  }

  BigInt _executeAsyncSubsetAtomicCmpxchgI64(
    List<WasmValue> stack, {
    required Instruction instruction,
    required List<bool> memory64ByIndex,
    required String context,
  }) {
    final replacement = WasmI64.unsigned(
      _popValue(
        stack,
        '$context replacement',
      ).castTo(WasmValueType.i64).asI64(),
    );
    final expected = WasmI64.unsigned(
      _popValue(stack, '$context expected').castTo(WasmValueType.i64).asI64(),
    );
    final access = _resolveAsyncSubsetAtomicMemoryAccess(
      stack,
      instruction: instruction,
      memory64ByIndex: memory64ByIndex,
      widthBytes: 8,
      context: context,
    );
    return RuntimeMemoryOps.atomicCmpxchgI64(
      memory: access.memory,
      address: access.address,
      expected: expected,
      replacement: replacement,
    );
  }

  int _executeAsyncSubsetAtomicCmpxchgI32Narrow(
    List<WasmValue> stack, {
    required Instruction instruction,
    required List<bool> memory64ByIndex,
    required int widthBytes,
    required String context,
  }) {
    final bits = widthBytes * 8;
    final replacement = _popValue(
      stack,
      '$context replacement',
    ).castTo(WasmValueType.i32).asI32().toUnsigned(bits);
    final expected = _popValue(
      stack,
      '$context expected',
    ).castTo(WasmValueType.i32).asI32().toUnsigned(bits);
    final access = _resolveAsyncSubsetAtomicMemoryAccess(
      stack,
      instruction: instruction,
      memory64ByIndex: memory64ByIndex,
      widthBytes: widthBytes,
      context: context,
    );
    return RuntimeMemoryOps.atomicCmpxchgNarrowUnsigned(
      memory: access.memory,
      address: access.address,
      widthBytes: widthBytes,
      expected: expected,
      replacement: replacement,
      context: context,
    );
  }

  int _executeAsyncSubsetAtomicCmpxchgI64Narrow(
    List<WasmValue> stack, {
    required Instruction instruction,
    required List<bool> memory64ByIndex,
    required int widthBytes,
    required String context,
  }) {
    final bits = widthBytes * 8;
    final mask = (BigInt.one << bits) - BigInt.one;
    final replacement =
        (WasmI64.unsigned(
                  _popValue(
                    stack,
                    '$context replacement',
                  ).castTo(WasmValueType.i64).asI64(),
                ) &
                mask)
            .toInt();
    final expected =
        (WasmI64.unsigned(
                  _popValue(
                    stack,
                    '$context expected',
                  ).castTo(WasmValueType.i64).asI64(),
                ) &
                mask)
            .toInt();
    final access = _resolveAsyncSubsetAtomicMemoryAccess(
      stack,
      instruction: instruction,
      memory64ByIndex: memory64ByIndex,
      widthBytes: widthBytes,
      context: context,
    );
    return RuntimeMemoryOps.atomicCmpxchgNarrowUnsigned(
      memory: access.memory,
      address: access.address,
      widthBytes: widthBytes,
      expected: expected,
      replacement: replacement,
      context: context,
    );
  }

  void _pushAsyncSubsetI128Result(List<WasmValue> stack, BigInt value) {
    final normalized = value & _u128BigMask;
    final low = _unsignedBigIntToSignedI64(normalized & _u64BigMask);
    final high = _unsignedBigIntToSignedI64((normalized >> 64) & _u64BigMask);
    stack
      ..add(WasmValue.i64(low))
      ..add(WasmValue.i64(high));
  }

  void _simdI8x16Splat(List<WasmValue> stack) {
    final lane = _popValue(
      stack,
      'i8x16.splat',
    ).castTo(WasmValueType.i32).asI32();
    final result = Uint8List(16);
    result.fillRange(0, 16, lane & 0xff);
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI8x16Eq(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i8x16.eq rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i8x16.eq lhs');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      result[lane] = lhs[lane] == rhs[lane] ? 0xff : 0x00;
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI8x16Ne(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i8x16.ne rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i8x16.ne lhs');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      result[lane] = lhs[lane] != rhs[lane] ? 0xff : 0x00;
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI8x16Abs(List<WasmValue> stack) {
    final value = _popAsyncSubsetV128(stack, opName: 'i8x16.abs');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      result[lane] = value[lane].toSigned(8).abs() & 0xff;
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI8x16Neg(List<WasmValue> stack) {
    final value = _popAsyncSubsetV128(stack, opName: 'i8x16.neg');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      result[lane] = (-value[lane].toSigned(8)) & 0xff;
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI8x16Popcnt(List<WasmValue> stack) {
    final value = _popAsyncSubsetV128(stack, opName: 'i8x16.popcnt');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      var byte = value[lane];
      var count = 0;
      while (byte != 0) {
        count += byte & 1;
        byte >>= 1;
      }
      result[lane] = count;
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI8x16Bitmask(List<WasmValue> stack) {
    final value = _popAsyncSubsetV128(stack, opName: 'i8x16.bitmask');
    var mask = 0;
    for (var lane = 0; lane < 16; lane++) {
      if (value[lane].toSigned(8) < 0) {
        mask |= 1 << lane;
      }
    }
    stack.add(WasmValue.i32(mask));
  }

  void _simdI8x16AnyTrue(List<WasmValue> stack) {
    final value = _popAsyncSubsetV128(stack, opName: 'i8x16.any_true');
    var anyTrue = 0;
    for (final byte in value) {
      if (byte != 0) {
        anyTrue = 1;
        break;
      }
    }
    stack.add(WasmValue.i32(anyTrue));
  }

  void _simdI16x8Abs(List<WasmValue> stack) {
    final value = _popAsyncSubsetV128(stack, opName: 'i16x8.abs');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final laneValue = valueData.getInt16(lane * 2, Endian.little).abs();
      resultData.setUint16(lane * 2, laneValue & 0xffff, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI16x8Splat(List<WasmValue> stack) {
    final lane = _popValue(
      stack,
      'i16x8.splat',
    ).castTo(WasmValueType.i32).asI32();
    final data = ByteData(2);
    data.setUint16(0, lane & 0xffff, Endian.little);
    final result = Uint8List.fromList(
      List<int>.generate(16, (index) => data.buffer.asUint8List()[index % 2]),
    );
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI16x8Eq(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i16x8.eq rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i16x8.eq lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final laneEqual =
          lhsData.getUint16(offset, Endian.little) ==
          rhsData.getUint16(offset, Endian.little);
      resultData.setUint16(offset, laneEqual ? 0xffff : 0x0000, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI16x8Compare(List<WasmValue> stack, {required int opcode}) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i16x8.compare rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i16x8.compare lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final aS = lhsData.getInt16(offset, Endian.little);
      final bS = rhsData.getInt16(offset, Endian.little);
      final aU = lhsData.getUint16(offset, Endian.little);
      final bU = rhsData.getUint16(offset, Endian.little);
      final matches = switch (opcode) {
        Opcodes.i16x8LtS => aS < bS,
        Opcodes.i16x8LtU => aU < bU,
        Opcodes.i16x8GtS => aS > bS,
        Opcodes.i16x8GtU => aU > bU,
        Opcodes.i16x8LeS => aS <= bS,
        Opcodes.i16x8LeU => aU <= bU,
        Opcodes.i16x8GeS => aS >= bS,
        Opcodes.i16x8GeU => aU >= bU,
        _ => throw StateError('Unsupported i16x8 compare opcode: $opcode'),
      };
      resultData.setUint16(offset, matches ? 0xffff : 0x0000, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI16x8Add(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i16x8.add rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i16x8.add lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final sum =
          (lhsData.getInt16(offset, Endian.little) +
                  rhsData.getInt16(offset, Endian.little))
              .toSigned(16);
      resultData.setUint16(offset, sum & 0xffff, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI16x8AddSatS(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i16x8.add_sat_s rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i16x8.add_sat_s lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final sum =
          lhsData.getInt16(offset, Endian.little) +
          rhsData.getInt16(offset, Endian.little);
      final clamped = sum.clamp(-32768, 32767);
      resultData.setUint16(offset, clamped & 0xffff, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI16x8AddSatU(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i16x8.add_sat_u rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i16x8.add_sat_u lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final sum =
          lhsData.getUint16(offset, Endian.little) +
          rhsData.getUint16(offset, Endian.little);
      final clamped = sum.clamp(0, 0xffff);
      resultData.setUint16(offset, clamped, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI16x8Sub(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i16x8.sub rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i16x8.sub lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final difference =
          lhsData.getUint16(offset, Endian.little) -
          rhsData.getUint16(offset, Endian.little);
      resultData.setUint16(offset, difference & 0xffff, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI16x8SubSatS(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i16x8.sub_sat_s rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i16x8.sub_sat_s lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final difference =
          lhsData.getInt16(offset, Endian.little) -
          rhsData.getInt16(offset, Endian.little);
      final clamped = difference.clamp(-32768, 32767);
      resultData.setUint16(offset, clamped & 0xffff, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI16x8SubSatU(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i16x8.sub_sat_u rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i16x8.sub_sat_u lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final lhsValue = lhsData.getUint16(offset, Endian.little);
      final rhsValue = rhsData.getUint16(offset, Endian.little);
      final difference = lhsValue - rhsValue;
      resultData.setUint16(
        offset,
        difference < 0 ? 0 : difference & 0xffff,
        Endian.little,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI16x8Shl(List<WasmValue> stack) {
    final shift =
        _popValue(stack, 'i16x8.shl shift').castTo(WasmValueType.i32).asI32() &
        15;
    final value = _popAsyncSubsetV128(stack, opName: 'i16x8.shl');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      resultData.setUint16(
        offset,
        (valueData.getUint16(offset, Endian.little) << shift) & 0xffff,
        Endian.little,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI16x8ShrS(List<WasmValue> stack) {
    final shift =
        _popValue(
          stack,
          'i16x8.shr_s shift',
        ).castTo(WasmValueType.i32).asI32() &
        15;
    final value = _popAsyncSubsetV128(stack, opName: 'i16x8.shr_s');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final laneValue = valueData.getInt16(offset, Endian.little);
      resultData.setUint16(
        offset,
        (laneValue >> shift) & 0xffff,
        Endian.little,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI16x8ShrU(List<WasmValue> stack) {
    final shift =
        _popValue(
          stack,
          'i16x8.shr_u shift',
        ).castTo(WasmValueType.i32).asI32() &
        15;
    final value = _popAsyncSubsetV128(stack, opName: 'i16x8.shr_u');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      resultData.setUint16(
        offset,
        valueData.getUint16(offset, Endian.little) >> shift,
        Endian.little,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI16x8Neg(List<WasmValue> stack) {
    final value = _popAsyncSubsetV128(stack, opName: 'i16x8.neg');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      resultData.setInt16(
        offset,
        -valueData.getInt16(offset, Endian.little),
        Endian.little,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI16x8Mul(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i16x8.mul rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i16x8.mul lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final product =
          lhsData.getInt16(offset, Endian.little) *
          rhsData.getInt16(offset, Endian.little);
      resultData.setUint16(offset, product & 0xffff, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI16x8MinS(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i16x8.min_s rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i16x8.min_s lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final a = lhsData.getInt16(offset, Endian.little);
      final b = rhsData.getInt16(offset, Endian.little);
      resultData.setUint16(offset, (a < b ? a : b) & 0xffff, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI16x8MinU(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i16x8.min_u rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i16x8.min_u lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final a = lhsData.getUint16(offset, Endian.little);
      final b = rhsData.getUint16(offset, Endian.little);
      resultData.setUint16(offset, a < b ? a : b, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI16x8MaxS(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i16x8.max_s rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i16x8.max_s lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final a = lhsData.getInt16(offset, Endian.little);
      final b = rhsData.getInt16(offset, Endian.little);
      resultData.setUint16(offset, (a > b ? a : b) & 0xffff, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI16x8MaxU(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i16x8.max_u rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i16x8.max_u lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final a = lhsData.getUint16(offset, Endian.little);
      final b = rhsData.getUint16(offset, Endian.little);
      resultData.setUint16(offset, a > b ? a : b, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI16x8AvgrU(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i16x8.avgr_u rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i16x8.avgr_u lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final avg =
          lhsData.getUint16(offset, Endian.little) +
          rhsData.getUint16(offset, Endian.little) +
          1;
      resultData.setUint16(offset, avg >> 1, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI16x8Ne(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i16x8.ne rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i16x8.ne lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final laneNotEqual =
          lhsData.getUint16(offset, Endian.little) !=
          rhsData.getUint16(offset, Endian.little);
      resultData.setUint16(
        offset,
        laneNotEqual ? 0xffff : 0x0000,
        Endian.little,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI16x8Bitmask(List<WasmValue> stack) {
    final value = _popAsyncSubsetV128(stack, opName: 'i16x8.bitmask');
    final data = ByteData.sublistView(value);
    var mask = 0;
    for (var lane = 0; lane < 8; lane++) {
      if ((data.getUint16(lane * 2, Endian.little) & 0x8000) != 0) {
        mask |= (1 << lane);
      }
    }
    stack.add(WasmValue.i32(mask));
  }

  void _simdI32x4Splat(List<WasmValue> stack) {
    final lane = _popValue(
      stack,
      'i32x4.splat',
    ).castTo(WasmValueType.i32).asI32();
    final result = Uint8List(16);
    final data = ByteData.sublistView(result);
    final laneBits = lane.toUnsigned(32);
    for (var i = 0; i < 4; i++) {
      data.setUint32(i * 4, laneBits, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI32x4Eq(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i32x4.eq rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i32x4.eq lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final laneEqual =
          lhsData.getUint32(offset, Endian.little) ==
          rhsData.getUint32(offset, Endian.little);
      resultData.setUint32(
        offset,
        laneEqual ? 0xffffffff : 0x00000000,
        Endian.little,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI32x4Ne(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i32x4.ne rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i32x4.ne lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final laneNe =
          lhsData.getUint32(offset, Endian.little) !=
          rhsData.getUint32(offset, Endian.little);
      resultData.setUint32(
        offset,
        laneNe ? 0xffffffff : 0x00000000,
        Endian.little,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI32x4Compare(List<WasmValue> stack, {required int opcode}) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i32x4.compare rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i32x4.compare lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final aS = lhsData.getInt32(offset, Endian.little);
      final bS = rhsData.getInt32(offset, Endian.little);
      final aU = lhsData.getUint32(offset, Endian.little);
      final bU = rhsData.getUint32(offset, Endian.little);
      final matches = switch (opcode) {
        Opcodes.i32x4LtS => aS < bS,
        Opcodes.i32x4LtU => aU < bU,
        Opcodes.i32x4GtS => aS > bS,
        Opcodes.i32x4GtU => aU > bU,
        Opcodes.i32x4LeS => aS <= bS,
        Opcodes.i32x4LeU => aU <= bU,
        Opcodes.i32x4GeS => aS >= bS,
        Opcodes.i32x4GeU => aU >= bU,
        _ => throw StateError('Unsupported i32x4 compare opcode: $opcode'),
      };
      resultData.setUint32(
        offset,
        matches ? 0xffffffff : 0x00000000,
        Endian.little,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI32x4Add(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i32x4.add rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i32x4.add lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final sum =
          lhsData.getUint32(offset, Endian.little) +
          rhsData.getUint32(offset, Endian.little);
      resultData.setUint32(offset, sum & 0xffffffff, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI32x4Sub(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i32x4.sub rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i32x4.sub lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final difference =
          lhsData.getUint32(offset, Endian.little) -
          rhsData.getUint32(offset, Endian.little);
      resultData.setUint32(offset, difference & 0xffffffff, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI32x4Mul(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i32x4.mul rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i32x4.mul lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final product =
          lhsData.getUint32(offset, Endian.little) *
          rhsData.getUint32(offset, Endian.little);
      resultData.setUint32(offset, product & 0xffffffff, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI32x4Shl(List<WasmValue> stack) {
    final shift =
        _popValue(stack, 'i32x4.shl shift').castTo(WasmValueType.i32).asI32() &
        31;
    final value = _popAsyncSubsetV128(stack, opName: 'i32x4.shl');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      resultData.setUint32(
        offset,
        (valueData.getUint32(offset, Endian.little) << shift) & 0xffffffff,
        Endian.little,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI32x4ShrS(List<WasmValue> stack) {
    final shift =
        _popValue(
          stack,
          'i32x4.shr_s shift',
        ).castTo(WasmValueType.i32).asI32() &
        31;
    final value = _popAsyncSubsetV128(stack, opName: 'i32x4.shr_s');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final laneValue = valueData.getInt32(offset, Endian.little);
      resultData.setUint32(
        offset,
        (laneValue >> shift) & 0xffffffff,
        Endian.little,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI32x4ShrU(List<WasmValue> stack) {
    final shift =
        _popValue(
          stack,
          'i32x4.shr_u shift',
        ).castTo(WasmValueType.i32).asI32() &
        31;
    final value = _popAsyncSubsetV128(stack, opName: 'i32x4.shr_u');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      resultData.setUint32(
        offset,
        valueData.getUint32(offset, Endian.little) >> shift,
        Endian.little,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI32x4Abs(List<WasmValue> stack) {
    final value = _popAsyncSubsetV128(stack, opName: 'i32x4.abs');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final laneValue = valueData.getInt32(lane * 4, Endian.little).abs();
      resultData.setUint32(lane * 4, laneValue.toUnsigned(32), Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI32x4Neg(List<WasmValue> stack) {
    final value = _popAsyncSubsetV128(stack, opName: 'i32x4.neg');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final laneValue = -valueData.getInt32(lane * 4, Endian.little);
      resultData.setUint32(lane * 4, laneValue.toUnsigned(32), Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI32x4MinS(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i32x4.min_s rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i32x4.min_s lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final a = lhsData.getInt32(offset, Endian.little);
      final b = rhsData.getInt32(offset, Endian.little);
      resultData.setUint32(
        offset,
        (a < b ? a : b).toUnsigned(32),
        Endian.little,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI32x4MinU(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i32x4.min_u rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i32x4.min_u lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final a = lhsData.getUint32(offset, Endian.little);
      final b = rhsData.getUint32(offset, Endian.little);
      resultData.setUint32(offset, a < b ? a : b, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI32x4MaxS(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i32x4.max_s rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i32x4.max_s lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final a = lhsData.getInt32(offset, Endian.little);
      final b = rhsData.getInt32(offset, Endian.little);
      resultData.setUint32(
        offset,
        (a > b ? a : b).toUnsigned(32),
        Endian.little,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI32x4MaxU(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i32x4.max_u rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i32x4.max_u lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final a = lhsData.getUint32(offset, Endian.little);
      final b = rhsData.getUint32(offset, Endian.little);
      resultData.setUint32(offset, a > b ? a : b, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI32x4Bitmask(List<WasmValue> stack) {
    final value = _popAsyncSubsetV128(stack, opName: 'i32x4.bitmask');
    final data = ByteData.sublistView(value);
    var mask = 0;
    for (var lane = 0; lane < 4; lane++) {
      if ((data.getUint32(lane * 4, Endian.little) & 0x80000000) != 0) {
        mask |= (1 << lane);
      }
    }
    stack.add(WasmValue.i32(mask));
  }

  void _simdI32x4AllTrue(List<WasmValue> stack) {
    final value = _popAsyncSubsetV128(stack, opName: 'i32x4.all_true');
    final data = ByteData.sublistView(value);
    var allTrue = 1;
    for (var lane = 0; lane < 4; lane++) {
      if (data.getUint32(lane * 4, Endian.little) == 0) {
        allTrue = 0;
        break;
      }
    }
    stack.add(WasmValue.i32(allTrue));
  }

  void _simdI64x2Splat(List<WasmValue> stack) {
    final lane = _popValue(
      stack,
      'i64x2.splat',
    ).castTo(WasmValueType.i64).asI64();
    final result = Uint8List(16);
    final data = ByteData.sublistView(result);
    final laneBits = WasmI64.unsigned(lane);
    for (var i = 0; i < 2; i++) {
      _writeAsyncSubsetLaneU64(data, i * 8, laneBits);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI64x2Eq(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i64x2.eq rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i64x2.eq lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _writeAsyncSubsetLaneU64(
        resultData,
        offset,
        _readAsyncSubsetLaneU64(lhsData, offset) ==
                _readAsyncSubsetLaneU64(rhsData, offset)
            ? _u64BigMask
            : BigInt.zero,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI64x2Compare(List<WasmValue> stack, {required int opcode}) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i64x2.compare rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i64x2.compare lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final a = WasmI64.signed(_readAsyncSubsetLaneU64(lhsData, offset));
      final b = WasmI64.signed(_readAsyncSubsetLaneU64(rhsData, offset));
      final matches = switch (opcode) {
        Opcodes.i64x2Ne => a != b,
        Opcodes.i64x2LtS => a < b,
        Opcodes.i64x2GtS => a > b,
        Opcodes.i64x2LeS => a <= b,
        Opcodes.i64x2GeS => a >= b,
        _ => throw StateError('Unsupported i64x2 compare opcode: $opcode'),
      };
      _writeAsyncSubsetLaneU64(
        resultData,
        offset,
        matches ? _u64BigMask : BigInt.zero,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI64x2Shl(List<WasmValue> stack) {
    final shift =
        _popValue(stack, 'i64x2.shl shift').castTo(WasmValueType.i32).asI32() &
        63;
    final value = _popAsyncSubsetV128(stack, opName: 'i64x2.shl');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _writeAsyncSubsetLaneU64(
        resultData,
        offset,
        _readAsyncSubsetLaneU64(valueData, offset) << shift,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI64x2ShrS(List<WasmValue> stack) {
    final shift =
        _popValue(
          stack,
          'i64x2.shr_s shift',
        ).castTo(WasmValueType.i32).asI32() &
        63;
    final value = _popAsyncSubsetV128(stack, opName: 'i64x2.shr_s');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final laneValue = WasmI64.signed(
        _readAsyncSubsetLaneU64(valueData, offset),
      );
      _writeAsyncSubsetLaneU64(resultData, offset, laneValue >> shift);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI64x2ShrU(List<WasmValue> stack) {
    final shift =
        _popValue(
          stack,
          'i64x2.shr_u shift',
        ).castTo(WasmValueType.i32).asI32() &
        63;
    final value = _popAsyncSubsetV128(stack, opName: 'i64x2.shr_u');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _writeAsyncSubsetLaneU64(
        resultData,
        offset,
        _readAsyncSubsetLaneU64(valueData, offset) >> shift,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI64x2Add(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i64x2.add rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i64x2.add lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _writeAsyncSubsetLaneU64(
        resultData,
        offset,
        _readAsyncSubsetLaneU64(lhsData, offset) +
            _readAsyncSubsetLaneU64(rhsData, offset),
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI64x2Sub(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i64x2.sub rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i64x2.sub lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _writeAsyncSubsetLaneU64(
        resultData,
        offset,
        _readAsyncSubsetLaneU64(lhsData, offset) -
            _readAsyncSubsetLaneU64(rhsData, offset),
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI64x2Mul(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'i64x2.mul rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'i64x2.mul lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _writeAsyncSubsetLaneU64(
        resultData,
        offset,
        _readAsyncSubsetLaneU64(lhsData, offset) *
            _readAsyncSubsetLaneU64(rhsData, offset),
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI64x2Abs(List<WasmValue> stack) {
    final value = _popAsyncSubsetV128(stack, opName: 'i64x2.abs');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final laneValue = WasmI64.signed(
        _readAsyncSubsetLaneU64(valueData, offset),
      );
      _writeAsyncSubsetLaneU64(resultData, offset, laneValue.abs());
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI64x2Neg(List<WasmValue> stack) {
    final value = _popAsyncSubsetV128(stack, opName: 'i64x2.neg');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final laneValue = WasmI64.signed(
        _readAsyncSubsetLaneU64(valueData, offset),
      );
      _writeAsyncSubsetLaneU64(resultData, offset, -laneValue);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdI64x2Bitmask(List<WasmValue> stack) {
    final value = _popAsyncSubsetV128(stack, opName: 'i64x2.bitmask');
    final data = ByteData.sublistView(value);
    var mask = 0;
    final signBit = BigInt.one << 63;
    for (var lane = 0; lane < 2; lane++) {
      if ((_readAsyncSubsetLaneU64(data, lane * 8) & signBit) != BigInt.zero) {
        mask |= (1 << lane);
      }
    }
    stack.add(WasmValue.i32(mask));
  }

  void _simdI64x2AllTrue(List<WasmValue> stack) {
    final value = _popAsyncSubsetV128(stack, opName: 'i64x2.all_true');
    final data = ByteData.sublistView(value);
    var allTrue = 1;
    for (var lane = 0; lane < 2; lane++) {
      if (_readAsyncSubsetLaneU64(data, lane * 8) == BigInt.zero) {
        allTrue = 0;
        break;
      }
    }
    stack.add(WasmValue.i32(allTrue));
  }

  void _simdF32x4Splat(List<WasmValue> stack) {
    final lane = _popValue(
      stack,
      'f32x4.splat',
    ).castTo(WasmValueType.f32).asF32();
    final bits = WasmValue.toF32Bits(lane);
    final result = Uint8List(16);
    final data = ByteData.sublistView(result);
    for (var i = 0; i < 4; i++) {
      data.setUint32(i * 4, bits, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF32x4Eq(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'f32x4.eq rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'f32x4.eq lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final laneEqual =
          lhsData.getFloat32(offset, Endian.little) ==
          rhsData.getFloat32(offset, Endian.little);
      resultData.setUint32(
        offset,
        laneEqual ? 0xffffffff : 0x00000000,
        Endian.little,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF32x4Ne(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'f32x4.ne rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'f32x4.ne lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final laneNe =
          lhsData.getFloat32(offset, Endian.little) !=
          rhsData.getFloat32(offset, Endian.little);
      resultData.setUint32(
        offset,
        laneNe ? 0xffffffff : 0x00000000,
        Endian.little,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF32x4Compare(List<WasmValue> stack, {required int opcode}) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'f32x4.compare rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'f32x4.compare lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final a = lhsData.getFloat32(offset, Endian.little);
      final b = rhsData.getFloat32(offset, Endian.little);
      final matches = switch (opcode) {
        Opcodes.f32x4Lt => a < b,
        Opcodes.f32x4Gt => a > b,
        Opcodes.f32x4Le => a <= b,
        Opcodes.f32x4Ge => a >= b,
        _ => throw StateError('Unsupported f32x4 compare opcode: $opcode'),
      };
      resultData.setUint32(
        offset,
        matches ? 0xffffffff : 0x00000000,
        Endian.little,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF32x4Add(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'f32x4.add rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'f32x4.add lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      _setAsyncSubsetF32LaneCanonical(
        resultData,
        offset,
        lhsData.getFloat32(offset, Endian.little) +
            rhsData.getFloat32(offset, Endian.little),
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF32x4Sub(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'f32x4.sub rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'f32x4.sub lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      _setAsyncSubsetF32LaneCanonical(
        resultData,
        offset,
        lhsData.getFloat32(offset, Endian.little) -
            rhsData.getFloat32(offset, Endian.little),
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF32x4Mul(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'f32x4.mul rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'f32x4.mul lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      _setAsyncSubsetF32LaneCanonical(
        resultData,
        offset,
        lhsData.getFloat32(offset, Endian.little) *
            rhsData.getFloat32(offset, Endian.little),
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF32x4Div(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'f32x4.div rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'f32x4.div lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      _setAsyncSubsetF32LaneCanonical(
        resultData,
        offset,
        lhsData.getFloat32(offset, Endian.little) /
            rhsData.getFloat32(offset, Endian.little),
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF32x4Abs(List<WasmValue> stack) {
    final value = _popAsyncSubsetV128(stack, opName: 'f32x4.abs');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final bits = valueData.getUint32(offset, Endian.little);
      resultData.setUint32(offset, bits & 0x7fffffff, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF32x4Neg(List<WasmValue> stack) {
    final value = _popAsyncSubsetV128(stack, opName: 'f32x4.neg');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final bits = valueData.getUint32(offset, Endian.little);
      resultData.setUint32(offset, bits ^ 0x80000000, Endian.little);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF32x4Sqrt(List<WasmValue> stack) {
    final value = _popAsyncSubsetV128(stack, opName: 'f32x4.sqrt');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      _setAsyncSubsetF32LaneCanonical(
        resultData,
        offset,
        math.sqrt(valueData.getFloat32(offset, Endian.little)),
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF32x4Min(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'f32x4.min rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'f32x4.min lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      _setAsyncSubsetF32LaneCanonical(
        resultData,
        offset,
        _fMin(
          lhsData.getFloat32(offset, Endian.little),
          rhsData.getFloat32(offset, Endian.little),
        ),
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF32x4Max(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'f32x4.max rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'f32x4.max lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      _setAsyncSubsetF32LaneCanonical(
        resultData,
        offset,
        _fMax(
          lhsData.getFloat32(offset, Endian.little),
          rhsData.getFloat32(offset, Endian.little),
        ),
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF32x4Pmin(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'f32x4.pmin rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'f32x4.pmin lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final lhsBits = lhsData.getUint32(offset, Endian.little);
      final rhsBits = rhsData.getUint32(offset, Endian.little);
      if (_isF32NaNBits(lhsBits) || _isF32NaNBits(rhsBits)) {
        resultData.setUint32(offset, lhsBits, Endian.little);
        continue;
      }
      final lhsLane = lhsData.getFloat32(offset, Endian.little);
      final rhsLane = rhsData.getFloat32(offset, Endian.little);
      if (lhsLane < rhsLane) {
        resultData.setUint32(offset, lhsBits, Endian.little);
      } else if (lhsLane > rhsLane) {
        resultData.setUint32(offset, rhsBits, Endian.little);
      } else {
        resultData.setUint32(offset, lhsBits, Endian.little);
      }
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF32x4Pmax(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'f32x4.pmax rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'f32x4.pmax lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final lhsBits = lhsData.getUint32(offset, Endian.little);
      final rhsBits = rhsData.getUint32(offset, Endian.little);
      if (_isF32NaNBits(lhsBits) || _isF32NaNBits(rhsBits)) {
        resultData.setUint32(offset, lhsBits, Endian.little);
        continue;
      }
      final lhsLane = lhsData.getFloat32(offset, Endian.little);
      final rhsLane = rhsData.getFloat32(offset, Endian.little);
      if (lhsLane > rhsLane) {
        resultData.setUint32(offset, lhsBits, Endian.little);
      } else if (lhsLane < rhsLane) {
        resultData.setUint32(offset, rhsBits, Endian.little);
      } else {
        resultData.setUint32(offset, lhsBits, Endian.little);
      }
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF64x2Splat(List<WasmValue> stack) {
    final laneBits = _popValue(
      stack,
      'f64x2.splat',
    ).castTo(WasmValueType.f64).asF64Bits();
    final result = Uint8List(16);
    final data = ByteData.sublistView(result);
    for (var i = 0; i < 2; i++) {
      _writeAsyncSubsetLaneU64(data, i * 8, laneBits);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF64x2Eq(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'f64x2.eq rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'f64x2.eq lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final laneEqual =
          lhsData.getFloat64(offset, Endian.little) ==
          rhsData.getFloat64(offset, Endian.little);
      _writeAsyncSubsetLaneU64(
        resultData,
        offset,
        laneEqual ? _u64BigMask : BigInt.zero,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF64x2Ne(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'f64x2.ne rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'f64x2.ne lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final laneNe =
          lhsData.getFloat64(offset, Endian.little) !=
          rhsData.getFloat64(offset, Endian.little);
      _writeAsyncSubsetLaneU64(
        resultData,
        offset,
        laneNe ? _u64BigMask : BigInt.zero,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF64x2Compare(List<WasmValue> stack, {required int opcode}) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'f64x2.compare rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'f64x2.compare lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final a = lhsData.getFloat64(offset, Endian.little);
      final b = rhsData.getFloat64(offset, Endian.little);
      final matches = switch (opcode) {
        Opcodes.f64x2Lt => a < b,
        Opcodes.f64x2Gt => a > b,
        Opcodes.f64x2Le => a <= b,
        Opcodes.f64x2Ge => a >= b,
        _ => throw StateError('Unsupported f64x2 compare opcode: $opcode'),
      };
      _writeAsyncSubsetLaneU64(
        resultData,
        offset,
        matches ? _u64BigMask : BigInt.zero,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF64x2Add(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'f64x2.add rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'f64x2.add lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _setAsyncSubsetF64LaneCanonical(
        resultData,
        offset,
        lhsData.getFloat64(offset, Endian.little) +
            rhsData.getFloat64(offset, Endian.little),
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF64x2Sub(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'f64x2.sub rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'f64x2.sub lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _setAsyncSubsetF64LaneCanonical(
        resultData,
        offset,
        lhsData.getFloat64(offset, Endian.little) -
            rhsData.getFloat64(offset, Endian.little),
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF64x2Mul(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'f64x2.mul rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'f64x2.mul lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _setAsyncSubsetF64LaneCanonical(
        resultData,
        offset,
        lhsData.getFloat64(offset, Endian.little) *
            rhsData.getFloat64(offset, Endian.little),
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF64x2Div(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'f64x2.div rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'f64x2.div lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _setAsyncSubsetF64LaneCanonical(
        resultData,
        offset,
        lhsData.getFloat64(offset, Endian.little) /
            rhsData.getFloat64(offset, Endian.little),
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF64x2Abs(List<WasmValue> stack) {
    final value = _popAsyncSubsetV128(stack, opName: 'f64x2.abs');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final bits =
          _readAsyncSubsetLaneU64(valueData, offset) & (_u64BigMask >> 1);
      _writeAsyncSubsetLaneU64(resultData, offset, bits);
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF64x2Neg(List<WasmValue> stack) {
    final value = _popAsyncSubsetV128(stack, opName: 'f64x2.neg');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    final signBit = BigInt.one << 63;
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _writeAsyncSubsetLaneU64(
        resultData,
        offset,
        _readAsyncSubsetLaneU64(valueData, offset) ^ signBit,
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF64x2Sqrt(List<WasmValue> stack) {
    final value = _popAsyncSubsetV128(stack, opName: 'f64x2.sqrt');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _setAsyncSubsetF64LaneCanonical(
        resultData,
        offset,
        math.sqrt(valueData.getFloat64(offset, Endian.little)),
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF64x2Min(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'f64x2.min rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'f64x2.min lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _setAsyncSubsetF64LaneCanonical(
        resultData,
        offset,
        _fMin(
          lhsData.getFloat64(offset, Endian.little),
          rhsData.getFloat64(offset, Endian.little),
        ),
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF64x2Max(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'f64x2.max rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'f64x2.max lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _setAsyncSubsetF64LaneCanonical(
        resultData,
        offset,
        _fMax(
          lhsData.getFloat64(offset, Endian.little),
          rhsData.getFloat64(offset, Endian.little),
        ),
      );
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF64x2Pmin(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'f64x2.pmin rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'f64x2.pmin lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final lhsBits = _readAsyncSubsetLaneU64(lhsData, offset);
      final rhsBits = _readAsyncSubsetLaneU64(rhsData, offset);
      if (_isF64NaNBits(lhsBits) || _isF64NaNBits(rhsBits)) {
        _writeAsyncSubsetLaneU64(resultData, offset, lhsBits);
        continue;
      }
      final lhsLane = lhsData.getFloat64(offset, Endian.little);
      final rhsLane = rhsData.getFloat64(offset, Endian.little);
      if (lhsLane < rhsLane) {
        _writeAsyncSubsetLaneU64(resultData, offset, lhsBits);
      } else if (lhsLane > rhsLane) {
        _writeAsyncSubsetLaneU64(resultData, offset, rhsBits);
      } else {
        _writeAsyncSubsetLaneU64(resultData, offset, lhsBits);
      }
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _simdF64x2Pmax(List<WasmValue> stack) {
    final rhs = _popAsyncSubsetV128(stack, opName: 'f64x2.pmax rhs');
    final lhs = _popAsyncSubsetV128(stack, opName: 'f64x2.pmax lhs');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final lhsBits = _readAsyncSubsetLaneU64(lhsData, offset);
      final rhsBits = _readAsyncSubsetLaneU64(rhsData, offset);
      if (_isF64NaNBits(lhsBits) || _isF64NaNBits(rhsBits)) {
        _writeAsyncSubsetLaneU64(resultData, offset, lhsBits);
        continue;
      }
      final lhsLane = lhsData.getFloat64(offset, Endian.little);
      final rhsLane = rhsData.getFloat64(offset, Endian.little);
      if (lhsLane > rhsLane) {
        _writeAsyncSubsetLaneU64(resultData, offset, lhsBits);
      } else if (lhsLane < rhsLane) {
        _writeAsyncSubsetLaneU64(resultData, offset, rhsBits);
      } else {
        _writeAsyncSubsetLaneU64(resultData, offset, lhsBits);
      }
    }
    _pushAsyncSubsetV128(stack, result);
  }

  void _setAsyncSubsetF32LaneCanonical(
    ByteData data,
    int offset,
    double value,
  ) {
    final bits = WasmValue.toF32Bits(value);
    data.setUint32(offset, _canonicalizeF32NaNBits(bits), Endian.little);
  }

  void _setAsyncSubsetF64LaneCanonical(
    ByteData data,
    int offset,
    double value,
  ) {
    final bits = WasmValue.toF64Bits(value);
    _writeAsyncSubsetLaneU64(data, offset, _canonicalizeF64NaNBits(bits));
  }

  BigInt _readAsyncSubsetLaneU64(ByteData data, int offset) {
    final low = BigInt.from(data.getUint32(offset, Endian.little));
    final high = BigInt.from(data.getUint32(offset + 4, Endian.little));
    return low | (high << 32);
  }

  void _writeAsyncSubsetLaneU64(ByteData data, int offset, BigInt value) {
    final normalized = value & _u64BigMask;
    final low = (normalized & BigInt.from(0xffffffff)).toInt();
    final high = ((normalized >> 32) & BigInt.from(0xffffffff)).toInt();
    data.setUint32(offset, low, Endian.little);
    data.setUint32(offset + 4, high, Endian.little);
  }

  void _pushAsyncSubsetV128(List<WasmValue> stack, Uint8List bytes) {
    stack.add(WasmValue.i32(WasmVm.internV128Bytes(bytes)));
  }

  Uint8List _popAsyncSubsetV128(
    List<WasmValue> stack, {
    required String opName,
  }) {
    final token = _popValue(stack, opName).castTo(WasmValueType.i32).asI32();
    final bytes = WasmVm.v128BytesForValue(token);
    if (bytes == null) {
      throw StateError('$opName expects v128 operand.');
    }
    return bytes;
  }

  static BigInt _unsignedBigIntToSignedI64(BigInt value) {
    final normalized = value & _u64BigMask;
    if ((normalized & (_u64BigMod >> 1)) != BigInt.zero) {
      return normalized - _u64BigMod;
    }
    return normalized;
  }

  static int _i32Clz(int value) {
    final unsigned = value.toUnsigned(32);
    if (unsigned == 0) {
      return 32;
    }
    return 32 - unsigned.bitLength;
  }

  static int _i32Ctz(int value) {
    var unsigned = value.toUnsigned(32);
    if (unsigned == 0) {
      return 32;
    }
    var count = 0;
    while ((unsigned & 1) == 0) {
      count++;
      unsigned >>= 1;
    }
    return count;
  }

  static int _i32Popcnt(int value) {
    var unsigned = value.toUnsigned(32);
    var count = 0;
    while (unsigned != 0) {
      unsigned &= unsigned - 1;
      count++;
    }
    return count;
  }

  static double _f32FromInteger(Object value) {
    return WasmValue.fromF32Bits(_f32BitsFromInteger(value));
  }

  static int _f32BitsFromInteger(Object value) {
    var integer = value is BigInt ? value : BigInt.from(value as int);
    if (integer == BigInt.zero) {
      return 0;
    }

    var signBit = 0;
    if (integer < BigInt.zero) {
      signBit = 1;
      integer = -integer;
    }

    const significandBits = 24;
    final bitLength = integer.bitLength;
    var exponent = bitLength - 1;
    BigInt significand;

    if (bitLength <= significandBits) {
      significand = integer << (significandBits - bitLength);
    } else {
      final shift = bitLength - significandBits;
      significand = integer >> shift;
      final remainderMask = (BigInt.one << shift) - BigInt.one;
      final remainder = integer & remainderMask;
      final halfway = BigInt.one << (shift - 1);
      final shouldRoundUp =
          remainder > halfway ||
          (remainder == halfway && (significand & BigInt.one) == BigInt.one);
      if (shouldRoundUp) {
        significand += BigInt.one;
        if (significand == (BigInt.one << significandBits)) {
          significand >>= 1;
          exponent++;
        }
      }
    }

    final exponentBits = exponent + 127;
    final fractionBits = (significand & BigInt.from(0x7fffff)).toInt();
    return (signBit << 31) | (exponentBits << 23) | fractionBits;
  }

  static bool _isF32NaNBits(int bits) {
    final normalized = bits.toUnsigned(32);
    return (normalized & 0x7f800000) == 0x7f800000 &&
        (normalized & 0x007fffff) != 0;
  }

  static int _canonicalizeF32NaNBits(int bits) {
    final normalized = bits.toUnsigned(32);
    return _isF32NaNBits(normalized) ? 0x7fc00000 : normalized;
  }

  static bool _isF64NaNBits(BigInt bits) {
    final normalized = WasmI64.unsigned(bits);
    return (normalized & _f64ExponentMask) == _f64ExponentMask &&
        (normalized & _f64FractionMask) != BigInt.zero;
  }

  static BigInt _canonicalizeF64NaNBits(BigInt bits) {
    final normalized = WasmI64.unsigned(bits);
    return _isF64NaNBits(normalized) ? _f64CanonicalNan : normalized;
  }

  static int _truncToI32S(double value) {
    _assertFinite(value);
    final truncated = value.truncate();
    if (truncated < _i32MinValueInt || truncated > _i32MaxValueInt) {
      throw StateError('i32.trunc_*_s overflow trap');
    }
    return truncated.toSigned(32);
  }

  static int _truncToI32U(double value) {
    _assertFinite(value);
    final truncated = value.truncate();
    if (truncated < 0 || truncated > _u32MaxValueInt) {
      throw StateError('i32.trunc_*_u overflow trap');
    }
    return truncated.toUnsigned(32).toSigned(32);
  }

  static BigInt _truncToI64S(double value) {
    _assertFinite(value);
    if (value < _i64Min || value >= _i64MaxPlusOne) {
      throw StateError('i64.trunc_*_s overflow trap');
    }
    final truncated = BigInt.from(value);
    return WasmI64.signed(truncated);
  }

  static BigInt _truncToI64U(double value) {
    _assertFinite(value);
    if (value <= -1.0 || value >= _u64MaxPlusOne) {
      throw StateError('i64.trunc_*_u overflow trap');
    }
    final truncated = BigInt.from(value);
    return WasmI64.unsigned(truncated);
  }

  static void _assertFinite(double value) {
    if (value.isNaN || value.isInfinite) {
      throw StateError('Invalid conversion trap: NaN or infinite value');
    }
  }

  static int _truncSatToI32S(double value) {
    if (value.isNaN) {
      return 0;
    }
    if (value <= _i32Min) {
      return _i32Min.toInt();
    }
    if (value >= _i32Max) {
      return 0x7fffffff;
    }
    return value.truncate().toSigned(32);
  }

  static int _truncSatToI32U(double value) {
    if (value.isNaN || value <= 0) {
      return 0;
    }
    if (value >= _u32Max) {
      return 0xffffffff.toSigned(32);
    }
    return value.truncate().toUnsigned(32).toSigned(32);
  }

  static BigInt _truncSatToI64S(double value) {
    if (value.isNaN) {
      return BigInt.zero;
    }
    if (value <= _i64Min) {
      return _i64MinValue;
    }
    if (value >= _i64Max) {
      return _i64MaxValue;
    }
    return WasmI64.signed(BigInt.from(value));
  }

  static BigInt _truncSatToI64U(double value) {
    if (value.isNaN || value <= 0) {
      return BigInt.zero;
    }
    if (value >= _u64Max) {
      return _u64Mask;
    }
    return WasmI64.unsigned(BigInt.from(value));
  }

  static double _nearest(double value) {
    if (value.isNaN || value.isInfinite || value == 0.0) {
      return value;
    }
    final lower = value.floorToDouble();
    final upper = value.ceilToDouble();
    final lowerDistance = (value - lower).abs();
    final upperDistance = (upper - value).abs();

    double result;
    if (lowerDistance < upperDistance) {
      result = lower;
    } else if (upperDistance < lowerDistance) {
      result = upper;
    } else {
      final lowerEven = lower.toInt().isEven;
      result = lowerEven ? lower : upper;
    }

    if (result == 0.0) {
      return value.isNegative ? -0.0 : 0.0;
    }
    return result;
  }

  static double _fMin(double a, double b) {
    if (a.isNaN || b.isNaN) {
      return double.nan;
    }
    if (a == 0.0 && b == 0.0) {
      if (a.isNegative || b.isNegative) {
        return -0.0;
      }
      return 0.0;
    }
    return a < b ? a : b;
  }

  static double _fMax(double a, double b) {
    if (a.isNaN || b.isNaN) {
      return double.nan;
    }
    if (a == 0.0 && b == 0.0) {
      if (!a.isNegative || !b.isNegative) {
        return 0.0;
      }
      return -0.0;
    }
    return a > b ? a : b;
  }

  static const int _i32MinValueInt = -2147483648;
  static const int _i32MaxValueInt = 2147483647;
  static const int _u32MaxValueInt = 0xffffffff;

  static final BigInt _i64MinValue = WasmI64.minSigned;
  static final BigInt _i64MaxValue = WasmI64.maxSigned;
  static final BigInt _u64Mask = WasmI64.allOnesMask;
  static final BigInt _u64BigMod = BigInt.one << 64;
  static final BigInt _u64BigMask = _u64BigMod - BigInt.one;
  static final BigInt _u128BigMask = (BigInt.one << 128) - BigInt.one;
  static final BigInt _f64ExponentMask = BigInt.parse(
    '7ff0000000000000',
    radix: 16,
  );
  static final BigInt _f64FractionMask = BigInt.parse(
    '000fffffffffffff',
    radix: 16,
  );
  static final BigInt _f64CanonicalNan = BigInt.parse(
    '7ff8000000000000',
    radix: 16,
  );

  static const double _i32Min = -2147483648.0;
  static const double _i32Max = 2147483647.0;
  static const double _u32Max = 4294967295.0;

  static const double _i64Min = -9223372036854775808.0;
  static const double _i64Max = 9223372036854775807.0;
  static const double _i64MaxPlusOne = 9223372036854775808.0;
  static const double _u64Max = 18446744073709551615.0;
  static const double _u64MaxPlusOne = 18446744073709551616.0;

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
    return RuntimeStackOps.popTyped(stack, paramTypes, context: context);
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
    return RuntimeStackOps.collectResultsAtExactHeight(
      stack,
      resultTypes,
      context: context,
    );
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
