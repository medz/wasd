import 'dart:convert';
import 'dart:typed_data';

import 'byte_reader.dart';
import 'component.dart';
import 'component_canonical_abi.dart';
import 'features.dart';
import 'imports.dart';
import 'instance.dart';
import 'memory.dart';
import 'module.dart';
import 'runtime_global.dart';
import 'table.dart';
import 'value.dart';

typedef _CoreImportBindingAttempt = ({bool bound, String? incompatibility});
typedef _ComponentExportAliasBinding = ({
  int instanceIndex,
  String coreExportName,
  WasmComponentImportKind kind,
});
typedef _ResolvedCoreSortExport = ({WasmInstance instance, String exportName});
typedef _ResolvedFromExportsBinding = ({
  String exportName,
  WasmComponentImportKind kind,
  WasmInstance sourceInstance,
  String sourceExportName,
});
typedef _TypedFunctionImportRequirement = ({
  String componentImportName,
  List<String> parameterSignatures,
  List<String> resultSignatures,
});
typedef _TypedGlobalImportRequirement = ({
  String componentImportName,
  String valueSignature,
});
typedef _TypedMemoryImportRequirement = ({
  String componentImportName,
  WasmMemoryType memoryType,
});
typedef _TypedTableImportRequirement = ({
  String componentImportName,
  WasmTableType tableType,
});
typedef _TypedTagImportRequirement = ({
  String componentImportName,
  List<String> parameterSignatures,
});

final Uint8List _emptyCoreModuleBytes = Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x01,
  0x00,
  0x00,
  0x00,
]);

/// Component-level runtime that instantiates embedded core modules.
///
/// Current scope:
/// - Instantiates embedded core modules discovered in section `0x01`.
/// - Exposes direct core export invocation.
/// - Exposes component export aliases decoded from section `0x03` for
///   function/memory/table/global/tag exports.
/// - Provides canonical ABI lowering/lifting wrappers over a selected memory.
final class WasmComponentInstance {
  WasmComponentInstance._({
    required this.component,
    required this.imports,
    required this.features,
    required this.coreInstances,
    required Map<String, int> coreInstanceAliases,
    required Map<String, _ComponentExportAliasBinding> coreExportAliases,
  }) : _coreInstanceAliases = coreInstanceAliases,
       _coreExportAliases = coreExportAliases;

  final WasmComponent component;
  final WasmImports imports;
  final WasmFeatureSet features;
  final List<WasmInstance> coreInstances;
  final Map<String, int> _coreInstanceAliases;
  final Map<String, _ComponentExportAliasBinding> _coreExportAliases;

  factory WasmComponentInstance.fromBytes(
    Uint8List componentBytes, {
    WasmImports imports = const WasmImports(),
    WasmFeatureSet features = const WasmFeatureSet(componentModel: true),
    bool bestEffortDecode = false,
  }) {
    final component = bestEffortDecode
        ? WasmComponent.decodeBestEffort(componentBytes, features: features)
        : WasmComponent.decode(componentBytes, features: features);
    return WasmComponentInstance.fromComponent(
      component,
      imports: imports,
      features: features,
    );
  }

  factory WasmComponentInstance.fromComponent(
    WasmComponent component, {
    WasmImports imports = const WasmImports(),
    WasmFeatureSet features = const WasmFeatureSet(componentModel: true),
  }) {
    if (!features.componentModel) {
      throw UnsupportedError(
        'Component instantiation requires `componentModel` feature to be enabled.',
      );
    }
    if (component.coreModules.isEmpty) {
      throw const FormatException(
        'Component does not contain embedded core modules.',
      );
    }
    final typedFunctionImportRequirements =
        _collectTypedFunctionImportRequirements(component);
    final typedGlobalImportRequirements = _collectTypedGlobalImportRequirements(
      component,
    );
    final typedMemoryImportRequirements = _collectTypedMemoryImportRequirements(
      component,
    );
    final typedTableImportRequirements = _collectTypedTableImportRequirements(
      component,
    );
    final typedTagImportRequirements = _collectTypedTagImportRequirements(
      component,
    );
    _validateComponentImportRequirements(component, imports);
    final coreInstances = <WasmInstance>[];
    if (component.coreInstances.isEmpty) {
      for (
        var moduleIndex = 0;
        moduleIndex < component.coreModules.length;
        moduleIndex++
      ) {
        final moduleBytes = component.coreModules[moduleIndex];
        _validateTypedImportBindingsForCoreModule(
          moduleBytes: moduleBytes,
          moduleIndex: moduleIndex,
          features: features,
          typedFunctionRequirementsByImportKey: typedFunctionImportRequirements,
          typedGlobalRequirementsByImportKey: typedGlobalImportRequirements,
          typedMemoryRequirementsByImportKey: typedMemoryImportRequirements,
          typedTableRequirementsByImportKey: typedTableImportRequirements,
          typedTagRequirementsByImportKey: typedTagImportRequirements,
        );
        coreInstances.add(
          WasmInstance.fromBytes(
            moduleBytes,
            imports: imports,
            features: features,
          ),
        );
      }
    } else {
      for (final declaration in component.coreInstances) {
        if (declaration.isFromExports) {
          coreInstances.add(
            _instantiateCoreInstanceFromExports(
              declaration: declaration,
              instantiatedCoreInstances: coreInstances,
              features: features,
            ),
          );
          continue;
        }
        final moduleIndex = declaration.moduleIndex;
        if (moduleIndex < 0 || moduleIndex >= component.coreModules.length) {
          throw FormatException(
            'Component core-instance module index out of range: $moduleIndex '
            '(count=${component.coreModules.length}).',
          );
        }
        for (final argumentIndex in declaration.argumentInstanceIndices) {
          if (argumentIndex < 0 || argumentIndex >= coreInstances.length) {
            throw FormatException(
              'Component core-instance argument index out of range: '
              '$argumentIndex (instantiated=${coreInstances.length}).',
            );
          }
        }
        final moduleBytes = component.coreModules[moduleIndex];
        _validateTypedImportBindingsForCoreModule(
          moduleBytes: moduleBytes,
          moduleIndex: moduleIndex,
          features: features,
          typedFunctionRequirementsByImportKey: typedFunctionImportRequirements,
          typedGlobalRequirementsByImportKey: typedGlobalImportRequirements,
          typedMemoryRequirementsByImportKey: typedMemoryImportRequirements,
          typedTableRequirementsByImportKey: typedTableImportRequirements,
          typedTagRequirementsByImportKey: typedTagImportRequirements,
        );
        final declarationImports = _composeCoreInstanceImports(
          moduleBytes: moduleBytes,
          declaration: declaration,
          baseImports: imports,
          instantiatedCoreInstances: coreInstances,
          features: features,
        );
        coreInstances.add(
          WasmInstance.fromBytes(
            moduleBytes,
            imports: declarationImports,
            features: features,
          ),
        );
      }
    }
    if (coreInstances.isEmpty) {
      throw const FormatException(
        'Component does not define any instantiable core instance.',
      );
    }
    final instanceAliasMap = <String, int>{};
    for (final alias in component.coreInstanceAliases) {
      final instanceIndex = alias.instanceIndex;
      if (instanceIndex < 0 || instanceIndex >= coreInstances.length) {
        throw FormatException(
          'Component core-instance alias `${alias.aliasName}` references '
          'invalid core instance index $instanceIndex '
          '(count=${coreInstances.length}).',
        );
      }
      instanceAliasMap[alias.aliasName] = instanceIndex;
    }
    final aliasMap = <String, _ComponentExportAliasBinding>{};
    for (final alias in component.coreExportAliases) {
      final instanceIndex = alias.instanceIndex;
      if (instanceIndex < 0 || instanceIndex >= coreInstances.length) {
        throw FormatException(
          'Component export alias `${alias.componentExportName}` references '
          'invalid core instance index $instanceIndex '
          '(count=${coreInstances.length}).',
        );
      }
      final sourceInstance = coreInstances[instanceIndex];
      final kind = _resolveCoreExportKind(sourceInstance, alias.coreExportName);
      if (kind == null) {
        throw FormatException(
          'Component export alias `${alias.componentExportName}` references '
          'missing core export `${alias.coreExportName}` in '
          'instance $instanceIndex.',
        );
      }
      aliasMap[alias.componentExportName] = (
        instanceIndex: instanceIndex,
        coreExportName: alias.coreExportName,
        kind: kind,
      );
    }
    _validateTypedCoreExportAliasBindings(
      component: component,
      coreInstances: coreInstances,
    );
    return WasmComponentInstance._(
      component: component,
      imports: imports,
      features: features,
      coreInstances: List<WasmInstance>.unmodifiable(coreInstances),
      coreInstanceAliases: Map<String, int>.unmodifiable(instanceAliasMap),
      coreExportAliases: Map<String, _ComponentExportAliasBinding>.unmodifiable(
        aliasMap,
      ),
    );
  }

  WasmInstance coreInstance([int moduleIndex = 0]) {
    _checkModuleIndex(moduleIndex);
    return coreInstances[moduleIndex];
  }

  WasmInstance coreInstanceByAlias(String aliasName) {
    final index = _coreInstanceAliases[aliasName];
    if (index == null) {
      throw ArgumentError.value(
        aliasName,
        'aliasName',
        'Core instance alias not found',
      );
    }
    return coreInstance(index);
  }

  Object? invokeCore(
    String exportName, {
    List<Object?> args = const [],
    int moduleIndex = 0,
  }) {
    return coreInstance(moduleIndex).invoke(exportName, args);
  }

  Future<Object?> invokeCoreAsync(
    String exportName, {
    List<Object?> args = const [],
    int moduleIndex = 0,
  }) {
    return coreInstance(moduleIndex).invokeAsync(exportName, args);
  }

  Object? invokeComponentExport(
    String exportName, {
    List<Object?> args = const [],
  }) {
    final binding = _componentExportBinding(exportName);
    if (binding.kind != WasmComponentImportKind.function) {
      throw StateError(
        'Component export alias `$exportName` is not a function export '
        '(kind=${binding.kind.name}).',
      );
    }
    return coreInstance(
      binding.instanceIndex,
    ).invoke(binding.coreExportName, args);
  }

  Future<Object?> invokeComponentExportAsync(
    String exportName, {
    List<Object?> args = const [],
  }) {
    final binding = _componentExportBinding(exportName);
    if (binding.kind != WasmComponentImportKind.function) {
      throw StateError(
        'Component export alias `$exportName` is not a function export '
        '(kind=${binding.kind.name}).',
      );
    }
    return coreInstance(
      binding.instanceIndex,
    ).invokeAsync(binding.coreExportName, args);
  }

  _ComponentExportAliasBinding _componentExportBinding(String exportName) {
    final binding = _coreExportAliases[exportName];
    if (binding == null) {
      throw ArgumentError.value(
        exportName,
        'exportName',
        'Component export alias not found',
      );
    }
    return binding;
  }

  static WasmComponentImportKind? _resolveCoreExportKind(
    WasmInstance instance,
    String exportName,
  ) {
    if (instance.exportedFunctions.contains(exportName)) {
      return WasmComponentImportKind.function;
    }
    if (instance.exportedMemories.contains(exportName)) {
      return WasmComponentImportKind.memory;
    }
    if (instance.exportedTables.contains(exportName)) {
      return WasmComponentImportKind.table;
    }
    if (instance.exportedGlobals.contains(exportName)) {
      return WasmComponentImportKind.global;
    }
    if (instance.exportedTags.contains(exportName)) {
      return WasmComponentImportKind.tag;
    }
    return null;
  }

  WasmComponentImportKind componentExportKind(String exportName) {
    return _componentExportBinding(exportName).kind;
  }

  WasmMemory componentExportMemory(String exportName) {
    final binding = _componentExportBinding(exportName);
    if (binding.kind != WasmComponentImportKind.memory) {
      throw StateError(
        'Component export alias `$exportName` is not a memory export '
        '(kind=${binding.kind.name}).',
      );
    }
    return coreInstance(
      binding.instanceIndex,
    ).exportedMemory(binding.coreExportName);
  }

  WasmTable componentExportTable(String exportName) {
    final binding = _componentExportBinding(exportName);
    if (binding.kind != WasmComponentImportKind.table) {
      throw StateError(
        'Component export alias `$exportName` is not a table export '
        '(kind=${binding.kind.name}).',
      );
    }
    return coreInstance(
      binding.instanceIndex,
    ).exportedTable(binding.coreExportName);
  }

  Object? readComponentExportGlobal(String exportName) {
    final binding = _componentExportBinding(exportName);
    if (binding.kind != WasmComponentImportKind.global) {
      throw StateError(
        'Component export alias `$exportName` is not a global export '
        '(kind=${binding.kind.name}).',
      );
    }
    return coreInstance(
      binding.instanceIndex,
    ).readGlobal(binding.coreExportName);
  }

  RuntimeGlobal componentExportGlobalBinding(String exportName) {
    final binding = _componentExportBinding(exportName);
    if (binding.kind != WasmComponentImportKind.global) {
      throw StateError(
        'Component export alias `$exportName` is not a global export '
        '(kind=${binding.kind.name}).',
      );
    }
    return coreInstance(
      binding.instanceIndex,
    ).exportedGlobalBinding(binding.coreExportName);
  }

  WasmTagImport componentExportTag(String exportName) {
    final binding = _componentExportBinding(exportName);
    if (binding.kind != WasmComponentImportKind.tag) {
      throw StateError(
        'Component export alias `$exportName` is not a tag export '
        '(kind=${binding.kind.name}).',
      );
    }
    return coreInstance(
      binding.instanceIndex,
    ).exportedTagImport(binding.coreExportName);
  }

  static WasmInstance _instantiateCoreInstanceFromExports({
    required WasmComponentCoreInstance declaration,
    required List<WasmInstance> instantiatedCoreInstances,
    required WasmFeatureSet features,
  }) {
    if (declaration.exports.isEmpty) {
      return WasmInstance.fromBytes(_emptyCoreModuleBytes, features: features);
    }

    final resolved = _resolveFromExportsBindings(
      declaration: declaration,
      instantiatedCoreInstances: instantiatedCoreInstances,
    );
    final synthetic = _buildFromExportsSyntheticModule(resolved);
    return WasmInstance.fromBytes(
      synthetic.moduleBytes,
      imports: synthetic.imports,
      features: features,
    );
  }

  static List<_ResolvedFromExportsBinding> _resolveFromExportsBindings({
    required WasmComponentCoreInstance declaration,
    required List<WasmInstance> instantiatedCoreInstances,
  }) {
    final functionExports = <_ResolvedCoreSortExport>[];
    final memoryExports = <_ResolvedCoreSortExport>[];
    final tableExports = <_ResolvedCoreSortExport>[];
    final globalExports = <_ResolvedCoreSortExport>[];
    final tagExports = <_ResolvedCoreSortExport>[];

    for (final instance in instantiatedCoreInstances) {
      for (final exportName in instance.exportedFunctions) {
        functionExports.add((instance: instance, exportName: exportName));
      }
      for (final exportName in instance.exportedMemories) {
        memoryExports.add((instance: instance, exportName: exportName));
      }
      for (final exportName in instance.exportedTables) {
        tableExports.add((instance: instance, exportName: exportName));
      }
      for (final exportName in instance.exportedGlobals) {
        globalExports.add((instance: instance, exportName: exportName));
      }
      for (final exportName in instance.exportedTags) {
        tagExports.add((instance: instance, exportName: exportName));
      }
    }

    final seenExportNames = <String>{};
    final resolved = <_ResolvedFromExportsBinding>[];
    for (final export in declaration.exports) {
      if (!seenExportNames.add(export.exportName)) {
        throw FormatException(
          'Duplicate core-instance from-exports export name: '
          '`${export.exportName}`.',
        );
      }
      switch (export.kind) {
        case 0x00:
          resolved.add(
            _resolveFromExportsBindingByKind(
              declarationExport: export,
              kind: WasmComponentImportKind.function,
              candidates: functionExports,
            ),
          );
        case 0x01:
          resolved.add(
            _resolveFromExportsBindingByKind(
              declarationExport: export,
              kind: WasmComponentImportKind.memory,
              candidates: memoryExports,
            ),
          );
        case 0x02:
          resolved.add(
            _resolveFromExportsBindingByKind(
              declarationExport: export,
              kind: WasmComponentImportKind.table,
              candidates: tableExports,
            ),
          );
        case 0x03:
          resolved.add(
            _resolveFromExportsBindingByKind(
              declarationExport: export,
              kind: WasmComponentImportKind.global,
              candidates: globalExports,
            ),
          );
        case 0x04:
          resolved.add(
            _resolveFromExportsBindingByKind(
              declarationExport: export,
              kind: WasmComponentImportKind.tag,
              candidates: tagExports,
            ),
          );
        default:
          throw UnsupportedError(
            'Unsupported component core-instance from-exports kind: '
            '0x${export.kind.toRadixString(16)}.',
          );
      }
    }
    return List<_ResolvedFromExportsBinding>.unmodifiable(resolved);
  }

  static _ResolvedFromExportsBinding _resolveFromExportsBindingByKind({
    required WasmComponentCoreInstanceExport declarationExport,
    required WasmComponentImportKind kind,
    required List<_ResolvedCoreSortExport> candidates,
  }) {
    final index = declarationExport.index;
    if (index < 0 || index >= candidates.length) {
      throw FormatException(
        'Component core-instance from-exports `${declarationExport.exportName}` '
        '(kind=${kind.name}) index out of range: $index '
        '(available=${candidates.length}).',
      );
    }
    final candidate = candidates[index];
    return (
      exportName: declarationExport.exportName,
      kind: kind,
      sourceInstance: candidate.instance,
      sourceExportName: candidate.exportName,
    );
  }

  static ({Uint8List moduleBytes, WasmImports imports})
  _buildFromExportsSyntheticModule(List<_ResolvedFromExportsBinding> bindings) {
    const importModuleName = '__wasd_from_exports';
    final typeEntries = <List<int>>[];
    final importPayload = <int>[..._u32Leb(bindings.length)];
    final exportPayload = <int>[..._u32Leb(bindings.length)];
    final functions = <String, WasmHostFunction>{};
    final asyncFunctions = <String, WasmAsyncHostFunction>{};
    final functionTypes = <String, WasmFunctionType>{};
    final functionTypeDepths = <String, int>{};
    final memories = <String, WasmMemory>{};
    final tables = <String, WasmTable>{};
    final globalTypes = <String, WasmGlobalType>{};
    final globalBindings = <String, RuntimeGlobal>{};
    final tags = <String, WasmTagImport>{};
    var functionImportCount = 0;
    var memoryImportCount = 0;
    var tableImportCount = 0;
    var globalImportCount = 0;
    var tagImportCount = 0;

    for (var i = 0; i < bindings.length; i++) {
      final binding = bindings[i];
      final fieldName = 'b$i';
      final importKey = WasmImports.key(importModuleName, fieldName);
      importPayload
        ..addAll(_encodeName(importModuleName))
        ..addAll(_encodeName(fieldName));
      switch (binding.kind) {
        case WasmComponentImportKind.function:
          final functionType = binding.sourceInstance.exportedFunctionType(
            binding.sourceExportName,
          );
          importPayload
            ..add(WasmImportKind.function)
            ..addAll(_u32Leb(typeEntries.length));
          typeEntries.add(_encodeFunctionType(functionType));
          functions[importKey] = (args) =>
              binding.sourceInstance.invoke(binding.sourceExportName, args);
          asyncFunctions[importKey] = (args) => binding.sourceInstance
              .invokeAsync(binding.sourceExportName, args);
          functionTypes[importKey] = functionType;
          functionTypeDepths[importKey] = binding.sourceInstance
              .exportedFunctionTypeDepth(binding.sourceExportName);
          exportPayload
            ..addAll(_encodeName(binding.exportName))
            ..add(WasmExportKind.function)
            ..addAll(_u32Leb(functionImportCount));
          functionImportCount++;
        case WasmComponentImportKind.memory:
          final memory = binding.sourceInstance.exportedMemory(
            binding.sourceExportName,
          );
          importPayload
            ..add(WasmImportKind.memory)
            ..addAll(_encodeMemoryImportType(memory));
          memories[importKey] = memory;
          exportPayload
            ..addAll(_encodeName(binding.exportName))
            ..add(WasmExportKind.memory)
            ..addAll(_u32Leb(memoryImportCount));
          memoryImportCount++;
        case WasmComponentImportKind.table:
          final table = binding.sourceInstance.exportedTable(
            binding.sourceExportName,
          );
          importPayload
            ..add(WasmImportKind.table)
            ..addAll(_encodeTableImportType(table));
          tables[importKey] = table;
          exportPayload
            ..addAll(_encodeName(binding.exportName))
            ..add(WasmExportKind.table)
            ..addAll(_u32Leb(tableImportCount));
          tableImportCount++;
        case WasmComponentImportKind.global:
          final globalType = binding.sourceInstance.exportedGlobalType(
            binding.sourceExportName,
          );
          final globalBinding = binding.sourceInstance.exportedGlobalBinding(
            binding.sourceExportName,
          );
          importPayload
            ..add(WasmImportKind.global)
            ..addAll(_encodeGlobalType(globalType));
          globalTypes[importKey] = globalType;
          globalBindings[importKey] = globalBinding;
          exportPayload
            ..addAll(_encodeName(binding.exportName))
            ..add(WasmExportKind.global)
            ..addAll(_u32Leb(globalImportCount));
          globalImportCount++;
        case WasmComponentImportKind.tag:
          final tagImport = binding.sourceInstance.exportedTagImport(
            binding.sourceExportName,
          );
          importPayload
            ..add(WasmImportKind.tag)
            ..add(0x00)
            ..addAll(_u32Leb(typeEntries.length));
          typeEntries.add(_encodeFunctionType(tagImport.type));
          tags[importKey] = tagImport;
          exportPayload
            ..addAll(_encodeName(binding.exportName))
            ..add(WasmExportKind.tag)
            ..addAll(_u32Leb(tagImportCount));
          tagImportCount++;
      }
    }

    final moduleBytes = <int>[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
    if (typeEntries.isNotEmpty) {
      final typePayload = <int>[..._u32Leb(typeEntries.length)];
      for (final entry in typeEntries) {
        typePayload.addAll(entry);
      }
      moduleBytes.addAll(_encodeSection(0x01, typePayload));
    }
    moduleBytes.addAll(_encodeSection(0x02, importPayload));
    moduleBytes.addAll(_encodeSection(0x07, exportPayload));

    return (
      moduleBytes: Uint8List.fromList(moduleBytes),
      imports: WasmImports(
        functions: functions,
        asyncFunctions: asyncFunctions,
        functionTypes: functionTypes,
        functionTypeDepths: functionTypeDepths,
        memories: memories,
        tables: tables,
        globalTypes: globalTypes,
        globalBindings: globalBindings,
        tags: tags,
      ),
    );
  }

  static List<int> _encodeFunctionType(WasmFunctionType type) {
    final out = <int>[0x60];
    final paramTypes = _encodeTypeVector(
      valueTypes: type.params,
      signatures: type.paramTypeSignatures,
    );
    final resultTypes = _encodeTypeVector(
      valueTypes: type.results,
      signatures: type.resultTypeSignatures,
    );
    out
      ..addAll(_u32Leb(paramTypes.length))
      ..addAll(paramTypes.expand((entry) => entry))
      ..addAll(_u32Leb(resultTypes.length))
      ..addAll(resultTypes.expand((entry) => entry));
    return out;
  }

  static List<List<int>> _encodeTypeVector({
    required List<WasmValueType> valueTypes,
    required List<String> signatures,
  }) {
    if (signatures.length == valueTypes.length && signatures.isNotEmpty) {
      return signatures
          .map((signature) => _signatureToBytes(signature))
          .toList(growable: false);
    }
    return valueTypes
        .map((valueType) => <int>[_valueTypeCode(valueType)])
        .toList(growable: false);
  }

  static List<int> _encodeMemoryImportType(WasmMemory memory) {
    final pageSizeLog2 = _pageSizeLog2(memory.pageSizeBytes);
    final hasPageSize = pageSizeLog2 != 16;
    final hasMax = memory.maxPages != null;
    final flags =
        (hasMax ? 0x01 : 0x00) |
        (memory.shared ? 0x02 : 0x00) |
        (memory.isMemory64 ? 0x04 : 0x00) |
        (hasPageSize ? 0x08 : 0x00);
    final out = <int>[flags];
    out.addAll(
      memory.isMemory64 ? _u64Leb(memory.pageCount) : _u32Leb(memory.pageCount),
    );
    final maxPages = memory.maxPages;
    if (maxPages != null) {
      out.addAll(memory.isMemory64 ? _u64Leb(maxPages) : _u32Leb(maxPages));
    }
    if (hasPageSize) {
      out.addAll(_u32Leb(pageSizeLog2));
    }
    return out;
  }

  static List<int> _encodeTableImportType(WasmTable table) {
    final refTypeBytes = table.refTypeSignature == null
        ? <int>[_refTypeCode(table.refType)]
        : _signatureToBytes(table.refTypeSignature!);
    final hasMax = table.max != null;
    final flags = (hasMax ? 0x01 : 0x00) | (table.isTable64 ? 0x02 : 0x00);
    final out = <int>[...refTypeBytes, flags];
    out.addAll(table.isTable64 ? _u64Leb(table.length) : _u32Leb(table.length));
    final max = table.max;
    if (max != null) {
      out.addAll(table.isTable64 ? _u64Leb(max) : _u32Leb(max));
    }
    return out;
  }

  static List<int> _encodeGlobalType(WasmGlobalType globalType) {
    final valueTypeBytes = globalType.valueTypeSignature == null
        ? <int>[_valueTypeCode(globalType.valueType)]
        : _signatureToBytes(globalType.valueTypeSignature!);
    return <int>[...valueTypeBytes, globalType.mutable ? 1 : 0];
  }

  static int _valueTypeCode(WasmValueType valueType) {
    return switch (valueType) {
      WasmValueType.i32 => 0x7f,
      WasmValueType.i64 => 0x7e,
      WasmValueType.f32 => 0x7d,
      WasmValueType.f64 => 0x7c,
    };
  }

  static int _refTypeCode(WasmRefType refType) {
    return switch (refType) {
      WasmRefType.funcref => 0x70,
      WasmRefType.externref => 0x6f,
    };
  }

  static int _pageSizeLog2(int pageSizeBytes) {
    if (pageSizeBytes <= 0 || (pageSizeBytes & (pageSizeBytes - 1)) != 0) {
      throw FormatException('Invalid Wasm memory page size: $pageSizeBytes.');
    }
    var log2 = 0;
    var value = pageSizeBytes;
    while (value > 1) {
      value >>= 1;
      log2++;
    }
    return log2;
  }

  static List<int> _signatureToBytes(String signature) {
    if (signature.isEmpty || (signature.length & 1) != 0) {
      throw FormatException('Invalid type signature encoding: `$signature`.');
    }
    final out = <int>[];
    for (var i = 0; i < signature.length; i += 2) {
      final byte = int.tryParse(signature.substring(i, i + 2), radix: 16);
      if (byte == null) {
        throw FormatException('Invalid type signature encoding: `$signature`.');
      }
      out.add(byte);
    }
    return out;
  }

  static List<int> _encodeName(String value) {
    final encoded = utf8.encode(value);
    return <int>[..._u32Leb(encoded.length), ...encoded];
  }

  static List<int> _encodeSection(int id, List<int> payload) {
    return <int>[id, ..._u32Leb(payload.length), ...payload];
  }

  static List<int> _u32Leb(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'must be >= 0');
    }
    final out = <int>[];
    var remaining = value;
    do {
      var byte = remaining & 0x7f;
      remaining >>= 7;
      if (remaining != 0) {
        byte |= 0x80;
      }
      out.add(byte);
    } while (remaining != 0);
    return out;
  }

  static List<int> _u64Leb(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'must be >= 0');
    }
    final out = <int>[];
    var remaining = value;
    do {
      var byte = remaining & 0x7f;
      remaining >>= 7;
      if (remaining != 0) {
        byte |= 0x80;
      }
      out.add(byte);
    } while (remaining != 0);
    return out;
  }

  static void _validateComponentImportRequirements(
    WasmComponent component,
    WasmImports imports,
  ) {
    for (final requirement in component.importRequirements) {
      final key = WasmImports.key(
        requirement.moduleName,
        requirement.fieldName,
      );
      final satisfied = switch (requirement.kind) {
        WasmComponentImportKind.function =>
          imports.functions.containsKey(key) ||
              imports.asyncFunctions.containsKey(key),
        WasmComponentImportKind.memory => imports.memories.containsKey(key),
        WasmComponentImportKind.table => imports.tables.containsKey(key),
        WasmComponentImportKind.global =>
          imports.globals.containsKey(key) ||
              imports.globalBindings.containsKey(key),
        WasmComponentImportKind.tag => imports.tags.containsKey(key),
      };
      if (!satisfied) {
        throw FormatException(
          'Missing component import `${requirement.componentImportName}` '
          '($key, kind=${requirement.kind.name}).',
        );
      }
    }
    _validateTypedComponentImportRequirements(component, imports);
  }

  static void _validateTypedComponentImportRequirements(
    WasmComponent component,
    WasmImports imports,
  ) {
    for (final binding in component.typeBindings) {
      if (binding.targetKind !=
          WasmComponentTypeBindingTargetKind.importRequirement) {
        continue;
      }
      if (binding.targetIndex < 0 ||
          binding.targetIndex >= component.importRequirements.length) {
        continue;
      }
      final requirement = component.importRequirements[binding.targetIndex];
      final declaration = _resolveComponentTypeDeclaration(
        component.typeDeclarations,
        binding.typeDeclarationIndex,
      );
      final key = WasmImports.key(
        requirement.moduleName,
        requirement.fieldName,
      );
      switch (requirement.kind) {
        case WasmComponentImportKind.memory:
          final memoryType = declaration.memoryType;
          if (declaration.kind != WasmComponentTypeKind.memory ||
              memoryType == null) {
            throw FormatException(
              'Component memory import `${requirement.componentImportName}` '
              'must bind to a memory type declaration.',
            );
          }
          final memory = imports.memories[key];
          if (memory != null) {
            final mismatch = _typedMemoryImportMismatch(
              expected: memoryType,
              actual: memory,
            );
            if (mismatch != null) {
              throw FormatException(
                'Component memory import `${requirement.componentImportName}` '
                'type mismatch: $mismatch.',
              );
            }
          }
          break;
        case WasmComponentImportKind.table:
          final tableType = declaration.tableType;
          if (declaration.kind != WasmComponentTypeKind.table ||
              tableType == null) {
            throw FormatException(
              'Component table import `${requirement.componentImportName}` '
              'must bind to a table type declaration.',
            );
          }
          final table = imports.tables[key];
          if (table != null) {
            final mismatch = _typedTableImportMismatch(
              expected: tableType,
              actual: table,
            );
            if (mismatch != null) {
              throw FormatException(
                'Component table import `${requirement.componentImportName}` '
                'type mismatch: $mismatch.',
              );
            }
          }
          break;
        case WasmComponentImportKind.tag:
          final tagParameterTypeCodes = declaration.tagParameterTypeCodes;
          final tagParameterTypeSignatures =
              declaration.tagParameterTypeSignatures;
          if (declaration.kind != WasmComponentTypeKind.tag ||
              tagParameterTypeCodes == null) {
            throw FormatException(
              'Component tag import `${requirement.componentImportName}` '
              'must bind to a tag type declaration.',
            );
          }
          final importedTag = imports.tags[key];
          if (importedTag != null) {
            _validateExpectedFunctionSignaturesAgainstCoreType(
              expectedParameters: _componentTypesToSignatures(
                typeCodes: tagParameterTypeCodes,
                typeSignatures: tagParameterTypeSignatures,
              ),
              expectedResults: const <String>[],
              actualType: importedTag.type,
              context:
                  'Component tag import '
                  '`${requirement.componentImportName}` ($key)',
            );
          }
          break;
        case WasmComponentImportKind.global:
          final valueTypeCode = declaration.valueTypeCode;
          final declarationValueSignature = declaration.valueTypeSignature;
          if (declaration.kind != WasmComponentTypeKind.value ||
              valueTypeCode == null) {
            throw FormatException(
              'Component global import `${requirement.componentImportName}` '
              'must bind to a value type declaration.',
            );
          }
          final expectedSignature =
              declarationValueSignature ??
              _componentValueTypeCodeToSignature(valueTypeCode);
          if (expectedSignature == null) {
            throw UnsupportedError(
              'Component global import `${requirement.componentImportName}` '
              'uses unsupported value type code 0x${valueTypeCode.toRadixString(16)}.',
            );
          }
          final expectedType = _decodeCoreValueTypeCode(valueTypeCode);
          final importedGlobalType = imports.globalTypes[key];
          if (importedGlobalType != null) {
            final actualSignature =
                importedGlobalType.valueTypeSignature ??
                _coreValueTypeSignature(importedGlobalType.valueType);
            if (!_referenceTypeSignaturesMatch(
              expectedSignature,
              actualSignature,
            )) {
              throw FormatException(
                'Component global import `${requirement.componentImportName}` '
                'type mismatch: expected $expectedSignature, '
                'actual $actualSignature.',
              );
            }
            if (!_isNumericValueTypeSignature(expectedSignature) &&
                importedGlobalType.valueType != WasmValueType.i32) {
              throw FormatException(
                'Component global import `${requirement.componentImportName}` '
                'uses reference signature $expectedSignature, but '
                '`imports.globalTypes[$key]` carrier type is '
                '${importedGlobalType.valueType.name} (expected i32).',
              );
            }
          }

          final bindingGlobal = imports.globalBindings[key];
          if (bindingGlobal != null) {
            final bindingSignature = bindingGlobal.valueTypeSignature;
            if (bindingSignature != null &&
                !_referenceTypeSignaturesMatch(
                  expectedSignature,
                  bindingSignature,
                )) {
              throw FormatException(
                'Component global import `${requirement.componentImportName}` '
                'type mismatch: expected $expectedSignature, '
                'actual $bindingSignature.',
              );
            }
            if (expectedType == null &&
                importedGlobalType == null &&
                bindingSignature == null) {
              throw UnsupportedError(
                'Component global import `${requirement.componentImportName}` '
                'requires `imports.globalTypes[$key]` or '
                '`imports.globalBindings[$key].valueTypeSignature` for '
                'non-numeric typed globals.',
              );
            }
            if (importedGlobalType != null &&
                bindingGlobal.valueType != importedGlobalType.valueType) {
              throw FormatException(
                'Component global import `${requirement.componentImportName}` '
                'type mismatch: `imports.globalBindings[$key]` carrier type '
                '${bindingGlobal.valueType.name} does not match '
                '`imports.globalTypes[$key]` carrier type '
                '${importedGlobalType.valueType.name}.',
              );
            }
            if (expectedType != null &&
                bindingGlobal.valueType != expectedType) {
              throw FormatException(
                'Component global import '
                '`${requirement.componentImportName}` type mismatch: '
                'expected ${expectedType.name}, '
                'actual ${bindingGlobal.valueType.name}.',
              );
            }
            if (!_isNumericValueTypeSignature(expectedSignature) &&
                bindingGlobal.valueType != WasmValueType.i32) {
              throw FormatException(
                'Component global import `${requirement.componentImportName}` '
                'uses reference signature $expectedSignature, but '
                '`imports.globalBindings[$key]` carrier type is '
                '${bindingGlobal.valueType.name} (expected i32).',
              );
            }
            break;
          }
          if (imports.globals.containsKey(key)) {
            final value = imports.globals[key];
            if (expectedType == null && importedGlobalType == null) {
              throw UnsupportedError(
                'Component global import `${requirement.componentImportName}` '
                'requires `imports.globalTypes[$key]` for non-numeric '
                'typed globals.',
              );
            }
            try {
              WasmValue.fromExternal(
                expectedType ?? importedGlobalType!.valueType,
                value,
              );
            } catch (_) {
              throw FormatException(
                'Component global import `${requirement.componentImportName}` '
                'is not compatible with expected type '
                '${expectedType?.name ?? expectedSignature}.',
              );
            }
          }
          break;
        case WasmComponentImportKind.function:
          final parameterTypeCodes = declaration.parameterTypeCodes;
          final resultTypeCodes = declaration.resultTypeCodes;
          if (declaration.kind != WasmComponentTypeKind.function ||
              parameterTypeCodes == null ||
              resultTypeCodes == null) {
            throw FormatException(
              'Component function import `${requirement.componentImportName}` '
              'must bind to a function type declaration.',
            );
          }
          final expectedParameters = _componentTypesToSignatures(
            typeCodes: parameterTypeCodes,
            typeSignatures: declaration.parameterTypeSignatures,
          );
          final expectedResults = _componentTypesToSignatures(
            typeCodes: resultTypeCodes,
            typeSignatures: declaration.resultTypeSignatures,
          );
          final importedFunctionType = imports.functionTypes[key];
          if (importedFunctionType == null) {
            if (_hasNonNumericValueSignature(expectedParameters) ||
                _hasNonNumericValueSignature(expectedResults)) {
              throw UnsupportedError(
                'Component function import '
                '`${requirement.componentImportName}` uses non-numeric typed '
                'signatures and requires `imports.functionTypes[$key]`.',
              );
            }
            break;
          }
          if (!importedFunctionType.isFunctionType) {
            throw FormatException(
              'Component function import `${requirement.componentImportName}` '
              'has non-function host signature in `imports.functionTypes[$key]`.',
            );
          }
          _validateExpectedFunctionSignaturesAgainstCoreType(
            expectedParameters: expectedParameters,
            expectedResults: expectedResults,
            actualType: importedFunctionType,
            context:
                'Component function import '
                '`${requirement.componentImportName}` ($key)',
          );
          _validateReferenceFunctionCarrierTypes(
            expectedSignatures: expectedParameters,
            carrierTypes: importedFunctionType.params,
            context:
                'Component function import '
                '`${requirement.componentImportName}` ($key)',
            kind: 'parameter',
          );
          _validateReferenceFunctionCarrierTypes(
            expectedSignatures: expectedResults,
            carrierTypes: importedFunctionType.results,
            context:
                'Component function import '
                '`${requirement.componentImportName}` ($key)',
            kind: 'result',
          );
          break;
      }
    }
  }

  static String? _typedMemoryImportMismatch({
    required WasmMemoryType expected,
    required WasmMemory actual,
  }) {
    final expectedPageSize = 1 << expected.pageSizeLog2;
    if (actual.isMemory64 != expected.isMemory64) {
      return 'expected memory64=${expected.isMemory64}, '
          'actual=${actual.isMemory64}';
    }
    if (actual.shared != expected.shared) {
      return 'expected shared=${expected.shared}, actual=${actual.shared}';
    }
    if (actual.pageSizeBytes != expectedPageSize) {
      return 'expected pageSize=$expectedPageSize, '
          'actual=${actual.pageSizeBytes}';
    }
    if (actual.pageCount < expected.minPages) {
      return 'expected minPages>=${expected.minPages}, '
          'actual=${actual.pageCount}';
    }
    final expectedMax = expected.maxPages;
    if (expectedMax != null) {
      final actualMax = actual.maxPages;
      if (actualMax == null || actualMax > expectedMax) {
        return 'expected maxPages<=$expectedMax, '
            'actual=${actualMax ?? 'unbounded'}';
      }
    }
    return null;
  }

  static String? _typedMemoryTypeMismatch({
    required WasmMemoryType expected,
    required WasmMemoryType actual,
  }) {
    if (actual.isMemory64 != expected.isMemory64) {
      return 'expected memory64=${expected.isMemory64}, '
          'actual=${actual.isMemory64}';
    }
    if (actual.shared != expected.shared) {
      return 'expected shared=${expected.shared}, actual=${actual.shared}';
    }
    if (actual.pageSizeLog2 != expected.pageSizeLog2) {
      return 'expected pageSizeLog2=${expected.pageSizeLog2}, '
          'actual=${actual.pageSizeLog2}';
    }
    if (actual.minPages != expected.minPages) {
      return 'expected minPages=${expected.minPages}, '
          'actual=${actual.minPages}';
    }
    if (actual.maxPages != expected.maxPages) {
      return 'expected maxPages=${expected.maxPages ?? 'unbounded'}, '
          'actual=${actual.maxPages ?? 'unbounded'}';
    }
    return null;
  }

  static String? _typedTableImportMismatch({
    required WasmTableType expected,
    required WasmTable actual,
  }) {
    final expectedSignature = expected.refTypeSignature;
    final actualSignature = actual.refTypeSignature;
    final refTypeMatches = expectedSignature != null && actualSignature != null
        ? _referenceTypeSignaturesMatch(expectedSignature, actualSignature)
        : actual.refType == expected.refType;
    if (!refTypeMatches) {
      return 'expected table type ${_formatTableType(expected)}, '
          'actual ${_formatTable(actual)}';
    }
    if (actual.isTable64 != expected.isTable64) {
      return 'expected table64=${expected.isTable64}, '
          'actual=${actual.isTable64}';
    }
    if (actual.length < expected.min) {
      return 'expected min>=${expected.min}, actual=${actual.length}';
    }
    final expectedMax = expected.max;
    if (expectedMax != null) {
      final actualMax = actual.max;
      if (actualMax == null || actualMax > expectedMax) {
        return 'expected max<=$expectedMax, actual=${actualMax ?? 'unbounded'}';
      }
    }
    return null;
  }

  static String? _typedTableTypeMismatch({
    required WasmTableType expected,
    required WasmTableType actual,
  }) {
    final expectedSignature = expected.refTypeSignature;
    final actualSignature = actual.refTypeSignature;
    final refTypeMatches = expectedSignature != null && actualSignature != null
        ? _referenceTypeSignaturesMatch(expectedSignature, actualSignature)
        : actual.refType == expected.refType;
    if (!refTypeMatches) {
      return 'expected table type ${_formatTableType(expected)}, '
          'actual ${_formatTableType(actual)}';
    }
    if (actual.isTable64 != expected.isTable64) {
      return 'expected table64=${expected.isTable64}, '
          'actual=${actual.isTable64}';
    }
    if (actual.min != expected.min) {
      return 'expected min=${expected.min}, actual=${actual.min}';
    }
    if (actual.max != expected.max) {
      return 'expected max=${expected.max ?? 'unbounded'}, '
          'actual=${actual.max ?? 'unbounded'}';
    }
    return null;
  }

  static WasmComponentTypeDeclaration _resolveComponentTypeDeclaration(
    List<WasmComponentTypeDeclaration> declarations,
    int index,
  ) {
    if (index < 0 || index >= declarations.length) {
      throw FormatException(
        'Component type binding references invalid type index '
        '$index (count=${declarations.length}).',
      );
    }
    var current = index;
    final seen = <int>{};
    while (true) {
      if (!seen.add(current)) {
        throw const FormatException('Component type alias cycle detected.');
      }
      final declaration = declarations[current];
      if (declaration.kind != WasmComponentTypeKind.alias) {
        return declaration;
      }
      final target = declaration.aliasTargetIndex;
      if (target == null || target < 0 || target >= declarations.length) {
        throw FormatException(
          'Component type alias `${declaration.name}` target out of range: '
          '$target (count=${declarations.length}).',
        );
      }
      current = target;
    }
  }

  static WasmValueType? _decodeCoreValueTypeCode(int code) {
    return switch (code) {
      0x7f => WasmValueType.i32,
      0x7e => WasmValueType.i64,
      0x7d => WasmValueType.f32,
      0x7c => WasmValueType.f64,
      _ => null,
    };
  }

  static String? _componentValueTypeCodeToSignature(int code) {
    switch (code & 0xff) {
      case 0x7f:
      case 0x7e:
      case 0x7d:
      case 0x7c:
      case 0x7b:
      case 0x70:
      case 0x71:
      case 0x72:
      case 0x73:
      case 0x74:
      case 0x75:
      case 0x6f:
      case 0x6e:
      case 0x6d:
      case 0x6c:
      case 0x6b:
      case 0x6a:
      case 0x69:
      case 0x68:
      case 0x67:
      case 0x66:
      case 0x65:
      case 0x62:
      case 0x61:
      case 0x60:
        return (code & 0xff).toRadixString(16).padLeft(2, '0');
      default:
        return null;
    }
  }

  static Map<String, _TypedFunctionImportRequirement>
  _collectTypedFunctionImportRequirements(WasmComponent component) {
    final out = <String, _TypedFunctionImportRequirement>{};
    for (final binding in component.typeBindings) {
      if (binding.targetKind !=
          WasmComponentTypeBindingTargetKind.importRequirement) {
        continue;
      }
      if (binding.targetIndex < 0 ||
          binding.targetIndex >= component.importRequirements.length) {
        continue;
      }
      final requirement = component.importRequirements[binding.targetIndex];
      if (requirement.kind != WasmComponentImportKind.function) {
        continue;
      }
      final declaration = _resolveComponentTypeDeclaration(
        component.typeDeclarations,
        binding.typeDeclarationIndex,
      );
      if (declaration.kind != WasmComponentTypeKind.function) {
        continue;
      }

      final key = WasmImports.key(
        requirement.moduleName,
        requirement.fieldName,
      );
      final entry = (
        componentImportName: requirement.componentImportName,
        parameterSignatures: _componentTypesToSignatures(
          typeCodes: declaration.parameterTypeCodes,
          typeSignatures: declaration.parameterTypeSignatures,
        ),
        resultSignatures: _componentTypesToSignatures(
          typeCodes: declaration.resultTypeCodes,
          typeSignatures: declaration.resultTypeSignatures,
        ),
      );
      final existing = out[key];
      if (existing != null &&
          (!_sameSignatureLists(
                existing.parameterSignatures,
                entry.parameterSignatures,
              ) ||
              !_sameSignatureLists(
                existing.resultSignatures,
                entry.resultSignatures,
              ))) {
        throw FormatException(
          'Conflicting typed function bindings for component import '
          '`${requirement.componentImportName}` ($key).',
        );
      }
      out[key] = entry;
    }
    return out;
  }

  static Map<String, _TypedGlobalImportRequirement>
  _collectTypedGlobalImportRequirements(WasmComponent component) {
    final out = <String, _TypedGlobalImportRequirement>{};
    for (final binding in component.typeBindings) {
      if (binding.targetKind !=
          WasmComponentTypeBindingTargetKind.importRequirement) {
        continue;
      }
      if (binding.targetIndex < 0 ||
          binding.targetIndex >= component.importRequirements.length) {
        continue;
      }
      final requirement = component.importRequirements[binding.targetIndex];
      if (requirement.kind != WasmComponentImportKind.global) {
        continue;
      }
      final declaration = _resolveComponentTypeDeclaration(
        component.typeDeclarations,
        binding.typeDeclarationIndex,
      );
      final valueTypeCode = declaration.valueTypeCode;
      final declarationValueSignature = declaration.valueTypeSignature;
      if (declaration.kind != WasmComponentTypeKind.value ||
          valueTypeCode == null) {
        continue;
      }
      final key = WasmImports.key(
        requirement.moduleName,
        requirement.fieldName,
      );
      final entry = (
        componentImportName: requirement.componentImportName,
        valueSignature:
            declarationValueSignature ??
            _componentTypeCodesToSignatures(<int>[valueTypeCode]).single,
      );
      final existing = out[key];
      if (existing != null && existing.valueSignature != entry.valueSignature) {
        throw FormatException(
          'Conflicting typed global bindings for component import '
          '`${requirement.componentImportName}` ($key).',
        );
      }
      out[key] = entry;
    }
    return out;
  }

  static Map<String, _TypedMemoryImportRequirement>
  _collectTypedMemoryImportRequirements(WasmComponent component) {
    final out = <String, _TypedMemoryImportRequirement>{};
    for (final binding in component.typeBindings) {
      if (binding.targetKind !=
          WasmComponentTypeBindingTargetKind.importRequirement) {
        continue;
      }
      if (binding.targetIndex < 0 ||
          binding.targetIndex >= component.importRequirements.length) {
        continue;
      }
      final requirement = component.importRequirements[binding.targetIndex];
      if (requirement.kind != WasmComponentImportKind.memory) {
        continue;
      }
      final declaration = _resolveComponentTypeDeclaration(
        component.typeDeclarations,
        binding.typeDeclarationIndex,
      );
      final memoryType = declaration.memoryType;
      if (declaration.kind != WasmComponentTypeKind.memory ||
          memoryType == null) {
        continue;
      }
      final key = WasmImports.key(
        requirement.moduleName,
        requirement.fieldName,
      );
      final entry = (
        componentImportName: requirement.componentImportName,
        memoryType: memoryType,
      );
      final existing = out[key];
      if (existing != null &&
          _typedMemoryTypeMismatch(
                expected: existing.memoryType,
                actual: entry.memoryType,
              ) !=
              null) {
        throw FormatException(
          'Conflicting typed memory bindings for component import '
          '`${requirement.componentImportName}` ($key).',
        );
      }
      out[key] = entry;
    }
    return out;
  }

  static Map<String, _TypedTableImportRequirement>
  _collectTypedTableImportRequirements(WasmComponent component) {
    final out = <String, _TypedTableImportRequirement>{};
    for (final binding in component.typeBindings) {
      if (binding.targetKind !=
          WasmComponentTypeBindingTargetKind.importRequirement) {
        continue;
      }
      if (binding.targetIndex < 0 ||
          binding.targetIndex >= component.importRequirements.length) {
        continue;
      }
      final requirement = component.importRequirements[binding.targetIndex];
      if (requirement.kind != WasmComponentImportKind.table) {
        continue;
      }
      final declaration = _resolveComponentTypeDeclaration(
        component.typeDeclarations,
        binding.typeDeclarationIndex,
      );
      final tableType = declaration.tableType;
      if (declaration.kind != WasmComponentTypeKind.table ||
          tableType == null) {
        continue;
      }
      final key = WasmImports.key(
        requirement.moduleName,
        requirement.fieldName,
      );
      final entry = (
        componentImportName: requirement.componentImportName,
        tableType: tableType,
      );
      final existing = out[key];
      if (existing != null &&
          _typedTableTypeMismatch(
                expected: existing.tableType,
                actual: entry.tableType,
              ) !=
              null) {
        throw FormatException(
          'Conflicting typed table bindings for component import '
          '`${requirement.componentImportName}` ($key).',
        );
      }
      out[key] = entry;
    }
    return out;
  }

  static Map<String, _TypedTagImportRequirement>
  _collectTypedTagImportRequirements(WasmComponent component) {
    final out = <String, _TypedTagImportRequirement>{};
    for (final binding in component.typeBindings) {
      if (binding.targetKind !=
          WasmComponentTypeBindingTargetKind.importRequirement) {
        continue;
      }
      if (binding.targetIndex < 0 ||
          binding.targetIndex >= component.importRequirements.length) {
        continue;
      }
      final requirement = component.importRequirements[binding.targetIndex];
      if (requirement.kind != WasmComponentImportKind.tag) {
        continue;
      }
      final declaration = _resolveComponentTypeDeclaration(
        component.typeDeclarations,
        binding.typeDeclarationIndex,
      );
      final tagParameterTypeCodes = declaration.tagParameterTypeCodes;
      final tagParameterTypeSignatures = declaration.tagParameterTypeSignatures;
      if (declaration.kind != WasmComponentTypeKind.tag ||
          tagParameterTypeCodes == null) {
        continue;
      }
      final key = WasmImports.key(
        requirement.moduleName,
        requirement.fieldName,
      );
      final entry = (
        componentImportName: requirement.componentImportName,
        parameterSignatures: _componentTypesToSignatures(
          typeCodes: tagParameterTypeCodes,
          typeSignatures: tagParameterTypeSignatures,
        ),
      );
      final existing = out[key];
      if (existing != null &&
          !_sameSignatureLists(
            existing.parameterSignatures,
            entry.parameterSignatures,
          )) {
        throw FormatException(
          'Conflicting typed tag bindings for component import '
          '`${requirement.componentImportName}` ($key).',
        );
      }
      out[key] = entry;
    }
    return out;
  }

  static void _validateTypedImportBindingsForCoreModule({
    required Uint8List moduleBytes,
    required int moduleIndex,
    required WasmFeatureSet features,
    required Map<String, _TypedFunctionImportRequirement>
    typedFunctionRequirementsByImportKey,
    required Map<String, _TypedGlobalImportRequirement>
    typedGlobalRequirementsByImportKey,
    required Map<String, _TypedMemoryImportRequirement>
    typedMemoryRequirementsByImportKey,
    required Map<String, _TypedTableImportRequirement>
    typedTableRequirementsByImportKey,
    required Map<String, _TypedTagImportRequirement>
    typedTagRequirementsByImportKey,
  }) {
    if (typedFunctionRequirementsByImportKey.isEmpty &&
        typedGlobalRequirementsByImportKey.isEmpty &&
        typedMemoryRequirementsByImportKey.isEmpty &&
        typedTableRequirementsByImportKey.isEmpty &&
        typedTagRequirementsByImportKey.isEmpty) {
      return;
    }
    final module = WasmModule.decode(moduleBytes, features: features);
    for (final imported in module.imports) {
      switch (imported.kind) {
        case WasmImportKind.function:
        case WasmImportKind.exactFunction:
          final typedRequirement =
              typedFunctionRequirementsByImportKey[imported.key];
          if (typedRequirement == null) {
            continue;
          }
          final typeIndex = imported.functionTypeIndex;
          if (typeIndex == null ||
              typeIndex < 0 ||
              typeIndex >= module.types.length) {
            throw FormatException(
              'Malformed function import `${imported.key}` in core module '
              '#$moduleIndex: invalid type index $typeIndex.',
            );
          }
          final actualType = module.types[typeIndex];
          if (!actualType.isFunctionType) {
            throw FormatException(
              'Malformed function import `${imported.key}` in core module '
              '#$moduleIndex: type index $typeIndex is not a function type.',
            );
          }
          _validateExpectedFunctionSignaturesAgainstCoreType(
            expectedParameters: typedRequirement.parameterSignatures,
            expectedResults: typedRequirement.resultSignatures,
            actualType: actualType,
            context:
                'Component typed function import '
                '`${typedRequirement.componentImportName}` (${imported.key}) '
                'in core module #$moduleIndex',
          );
          break;
        case WasmImportKind.global:
          final typedRequirement =
              typedGlobalRequirementsByImportKey[imported.key];
          if (typedRequirement == null) {
            continue;
          }
          final globalType = imported.globalType;
          if (globalType == null) {
            throw FormatException(
              'Malformed global import `${imported.key}` in core module '
              '#$moduleIndex: missing global type.',
            );
          }
          final actualSignature =
              globalType.valueTypeSignature ??
              _coreValueTypeSignature(globalType.valueType);
          if (actualSignature != typedRequirement.valueSignature) {
            throw FormatException(
              'Component typed global import '
              '`${typedRequirement.componentImportName}` (${imported.key}) '
              'in core module #$moduleIndex has incompatible value type: '
              'expected ${typedRequirement.valueSignature}, '
              'actual $actualSignature.',
            );
          }
          break;
        case WasmImportKind.memory:
          final typedRequirement =
              typedMemoryRequirementsByImportKey[imported.key];
          if (typedRequirement == null) {
            continue;
          }
          final memoryType = imported.memoryType;
          if (memoryType == null) {
            throw FormatException(
              'Malformed memory import `${imported.key}` in core module '
              '#$moduleIndex: missing memory type.',
            );
          }
          final mismatch = _typedMemoryTypeMismatch(
            expected: typedRequirement.memoryType,
            actual: memoryType,
          );
          if (mismatch != null) {
            throw FormatException(
              'Component typed memory import '
              '`${typedRequirement.componentImportName}` (${imported.key}) '
              'in core module #$moduleIndex has incompatible type: $mismatch.',
            );
          }
          break;
        case WasmImportKind.table:
          final typedRequirement =
              typedTableRequirementsByImportKey[imported.key];
          if (typedRequirement == null) {
            continue;
          }
          final tableType = imported.tableType;
          if (tableType == null) {
            throw FormatException(
              'Malformed table import `${imported.key}` in core module '
              '#$moduleIndex: missing table type.',
            );
          }
          final mismatch = _typedTableTypeMismatch(
            expected: typedRequirement.tableType,
            actual: tableType,
          );
          if (mismatch != null) {
            throw FormatException(
              'Component typed table import '
              '`${typedRequirement.componentImportName}` (${imported.key}) '
              'in core module #$moduleIndex has incompatible type: $mismatch.',
            );
          }
          break;
        case WasmImportKind.tag:
          final typedRequirement =
              typedTagRequirementsByImportKey[imported.key];
          if (typedRequirement == null) {
            continue;
          }
          final tagType = imported.tagType;
          final typeIndex = tagType?.typeIndex;
          if (tagType == null ||
              typeIndex == null ||
              typeIndex < 0 ||
              typeIndex >= module.types.length) {
            throw FormatException(
              'Malformed tag import `${imported.key}` in core module '
              '#$moduleIndex: invalid type index ${tagType?.typeIndex}.',
            );
          }
          final actualType = module.types[typeIndex];
          if (!actualType.isFunctionType) {
            throw FormatException(
              'Malformed tag import `${imported.key}` in core module '
              '#$moduleIndex: type index $typeIndex is not a function type.',
            );
          }
          _validateExpectedFunctionSignaturesAgainstCoreType(
            expectedParameters: typedRequirement.parameterSignatures,
            expectedResults: const <String>[],
            actualType: actualType,
            context:
                'Component typed tag import '
                '`${typedRequirement.componentImportName}` (${imported.key}) '
                'in core module #$moduleIndex',
          );
          break;
        default:
          continue;
      }
    }
  }

  static void _validateTypedCoreExportAliasBindings({
    required WasmComponent component,
    required List<WasmInstance> coreInstances,
  }) {
    for (final binding in component.typeBindings) {
      if (binding.targetKind !=
          WasmComponentTypeBindingTargetKind.coreExportAlias) {
        continue;
      }
      if (binding.targetIndex < 0 ||
          binding.targetIndex >= component.coreExportAliases.length) {
        continue;
      }
      final alias = component.coreExportAliases[binding.targetIndex];
      final declaration = _resolveComponentTypeDeclaration(
        component.typeDeclarations,
        binding.typeDeclarationIndex,
      );
      final instanceIndex = alias.instanceIndex;
      if (instanceIndex < 0 || instanceIndex >= coreInstances.length) {
        continue;
      }
      final instance = coreInstances[instanceIndex];
      final exportKind = _resolveCoreExportKind(instance, alias.coreExportName);
      if (exportKind == null) {
        continue;
      }
      final context =
          'Component export alias `${alias.componentExportName}` '
          '(instance=$instanceIndex, export=`${alias.coreExportName}`)';
      switch (declaration.kind) {
        case WasmComponentTypeKind.function:
          if (exportKind != WasmComponentImportKind.function) {
            throw FormatException(
              '$context has incompatible kind: expected function export, '
              'actual ${exportKind.name}.',
            );
          }
          final actualType = instance.exportedFunctionType(
            alias.coreExportName,
          );
          _validateComponentFunctionDeclarationAgainstCoreType(
            declaration: declaration,
            actualType: actualType,
            context: context,
          );
          break;
        case WasmComponentTypeKind.value:
          if (exportKind != WasmComponentImportKind.global) {
            throw FormatException(
              '$context has incompatible kind: expected global export, '
              'actual ${exportKind.name}.',
            );
          }
          final valueTypeCode = declaration.valueTypeCode;
          final declarationValueSignature = declaration.valueTypeSignature;
          if (valueTypeCode == null) {
            throw FormatException(
              '$context has malformed value type declaration '
              '`${declaration.name}`.',
            );
          }
          final expectedSignature =
              declarationValueSignature ??
              _componentValueTypeCodeToSignature(valueTypeCode);
          if (expectedSignature == null) {
            throw UnsupportedError(
              '$context uses unsupported value type code '
              '0x${valueTypeCode.toRadixString(16)}.',
            );
          }
          final actualGlobalType = instance.exportedGlobalType(
            alias.coreExportName,
          );
          final actualSignature =
              actualGlobalType.valueTypeSignature ??
              _coreValueTypeSignature(actualGlobalType.valueType);
          if (!_referenceTypeSignaturesMatch(
            expectedSignature,
            actualSignature,
          )) {
            throw FormatException(
              '$context has incompatible typed global signature: expected '
              '$expectedSignature, actual $actualSignature.',
            );
          }
          break;
        case WasmComponentTypeKind.memory:
          if (exportKind != WasmComponentImportKind.memory) {
            throw FormatException(
              '$context has incompatible kind: expected memory export, '
              'actual ${exportKind.name}.',
            );
          }
          final memoryType = declaration.memoryType;
          if (memoryType == null) {
            throw FormatException(
              '$context has malformed memory type declaration '
              '`${declaration.name}`.',
            );
          }
          final mismatch = _typedMemoryImportMismatch(
            expected: memoryType,
            actual: instance.exportedMemory(alias.coreExportName),
          );
          if (mismatch != null) {
            throw FormatException(
              '$context has incompatible typed memory export: $mismatch.',
            );
          }
          break;
        case WasmComponentTypeKind.table:
          if (exportKind != WasmComponentImportKind.table) {
            throw FormatException(
              '$context has incompatible kind: expected table export, '
              'actual ${exportKind.name}.',
            );
          }
          final tableType = declaration.tableType;
          if (tableType == null) {
            throw FormatException(
              '$context has malformed table type declaration '
              '`${declaration.name}`.',
            );
          }
          final mismatch = _typedTableImportMismatch(
            expected: tableType,
            actual: instance.exportedTable(alias.coreExportName),
          );
          if (mismatch != null) {
            throw FormatException(
              '$context has incompatible typed table export: $mismatch.',
            );
          }
          break;
        case WasmComponentTypeKind.tag:
          if (exportKind != WasmComponentImportKind.tag) {
            throw FormatException(
              '$context has incompatible kind: expected tag export, '
              'actual ${exportKind.name}.',
            );
          }
          final tagParameterTypeCodes = declaration.tagParameterTypeCodes;
          final tagParameterTypeSignatures =
              declaration.tagParameterTypeSignatures;
          if (tagParameterTypeCodes == null) {
            throw FormatException(
              '$context has malformed tag type declaration `${declaration.name}`.',
            );
          }
          _validateExpectedFunctionSignaturesAgainstCoreType(
            expectedParameters: _componentTypesToSignatures(
              typeCodes: tagParameterTypeCodes,
              typeSignatures: tagParameterTypeSignatures,
            ),
            expectedResults: const <String>[],
            actualType: instance.exportedTagImport(alias.coreExportName).type,
            context: '$context for tag declaration `${declaration.name}`',
          );
          break;
        case WasmComponentTypeKind.alias:
          throw FormatException(
            '$context resolved to an alias type declaration, which is invalid.',
          );
      }
    }
  }

  static void _validateComponentFunctionDeclarationAgainstCoreType({
    required WasmComponentTypeDeclaration declaration,
    required WasmFunctionType actualType,
    required String context,
  }) {
    _validateExpectedFunctionSignaturesAgainstCoreType(
      expectedParameters: _componentTypesToSignatures(
        typeCodes: declaration.parameterTypeCodes,
        typeSignatures: declaration.parameterTypeSignatures,
      ),
      expectedResults: _componentTypesToSignatures(
        typeCodes: declaration.resultTypeCodes,
        typeSignatures: declaration.resultTypeSignatures,
      ),
      actualType: actualType,
      context: '$context for function declaration `${declaration.name}`',
    );
  }

  static List<String> _componentTypesToSignatures({
    required List<int>? typeCodes,
    required List<String>? typeSignatures,
  }) {
    if (typeSignatures != null && typeSignatures.isNotEmpty) {
      return List<String>.from(typeSignatures, growable: false);
    }
    return _componentTypeCodesToSignatures(typeCodes);
  }

  static List<String> _componentTypeCodesToSignatures(List<int>? typeCodes) {
    if (typeCodes == null || typeCodes.isEmpty) {
      return const <String>[];
    }
    return typeCodes
        .map((code) => (code & 0xff).toRadixString(16).padLeft(2, '0'))
        .toList(growable: false);
  }

  static List<String> _coreFunctionSignatures({
    required List<WasmValueType> valueTypes,
    required List<String> signatures,
  }) {
    if (signatures.length == valueTypes.length) {
      return List<String>.from(signatures, growable: false);
    }
    return valueTypes.map(_coreValueTypeSignature).toList(growable: false);
  }

  static String _coreValueTypeSignature(WasmValueType type) {
    return switch (type) {
      WasmValueType.i32 => '7f',
      WasmValueType.i64 => '7e',
      WasmValueType.f32 => '7d',
      WasmValueType.f64 => '7c',
    };
  }

  static void _validateExpectedFunctionSignaturesAgainstCoreType({
    required List<String> expectedParameters,
    required List<String> expectedResults,
    required WasmFunctionType actualType,
    required String context,
  }) {
    final actualParams = _coreFunctionSignatures(
      valueTypes: actualType.params,
      signatures: actualType.paramTypeSignatures,
    );
    final actualResults = _coreFunctionSignatures(
      valueTypes: actualType.results,
      signatures: actualType.resultTypeSignatures,
    );

    if (expectedParameters.length != actualParams.length ||
        expectedResults.length != actualResults.length) {
      throw FormatException(
        '$context has incompatible typed function signature: expected '
        '(${expectedParameters.join(', ')}) -> (${expectedResults.join(', ')}), '
        'actual (${actualParams.join(', ')}) -> (${actualResults.join(', ')}).',
      );
    }
    for (var i = 0; i < expectedParameters.length; i++) {
      if (expectedParameters[i] != actualParams[i]) {
        throw FormatException(
          '$context has incompatible typed function parameter at index $i: '
          'expected ${expectedParameters[i]}, actual ${actualParams[i]}.',
        );
      }
    }
    for (var i = 0; i < expectedResults.length; i++) {
      if (expectedResults[i] != actualResults[i]) {
        throw FormatException(
          '$context has incompatible typed function result at index $i: '
          'expected ${expectedResults[i]}, actual ${actualResults[i]}.',
        );
      }
    }
  }

  static bool _sameSignatureLists(List<String> lhs, List<String> rhs) {
    if (lhs.length != rhs.length) {
      return false;
    }
    for (var i = 0; i < lhs.length; i++) {
      if (lhs[i] != rhs[i]) {
        return false;
      }
    }
    return true;
  }

  static bool _hasNonNumericValueSignature(List<String> signatures) {
    for (final signature in signatures) {
      if (!_isNumericValueTypeSignature(signature)) {
        return true;
      }
    }
    return false;
  }

  static void _validateReferenceFunctionCarrierTypes({
    required List<String> expectedSignatures,
    required List<WasmValueType> carrierTypes,
    required String context,
    required String kind,
  }) {
    for (var i = 0; i < expectedSignatures.length; i++) {
      final signature = expectedSignatures[i];
      if (_isNumericValueTypeSignature(signature)) {
        continue;
      }
      if (carrierTypes[i] != WasmValueType.i32) {
        throw FormatException(
          '$context uses reference signature $signature at $kind index $i, '
          'but carrier type is ${carrierTypes[i].name} (expected i32).',
        );
      }
    }
  }

  static WasmImports _composeCoreInstanceImports({
    required Uint8List moduleBytes,
    required WasmComponentCoreInstance declaration,
    required WasmImports baseImports,
    required List<WasmInstance> instantiatedCoreInstances,
    required WasmFeatureSet features,
  }) {
    if (declaration.argumentInstanceIndices.isEmpty) {
      return baseImports;
    }

    final module = WasmModule.decode(moduleBytes, features: features);
    final functions = Map<String, WasmHostFunction>.from(baseImports.functions);
    final asyncFunctions = Map<String, WasmAsyncHostFunction>.from(
      baseImports.asyncFunctions,
    );
    final functionTypes = Map<String, WasmFunctionType>.from(
      baseImports.functionTypes,
    );
    final functionTypeDepths = Map<String, int>.from(
      baseImports.functionTypeDepths,
    );
    final memories = Map<String, WasmMemory>.from(baseImports.memories);
    final tables = Map<String, WasmTable>.from(baseImports.tables);
    final globals = Map<String, Object?>.from(baseImports.globals);
    final globalTypes = Map<String, WasmGlobalType>.from(
      baseImports.globalTypes,
    );
    final globalBindings = Map<String, RuntimeGlobal>.from(
      baseImports.globalBindings,
    );
    final tags = Map<String, WasmTagImport>.from(baseImports.tags);
    var changed = false;

    for (final imported in module.imports) {
      final key = imported.key;
      if (_isImportSatisfied(
        imported: imported,
        key: key,
        functions: functions,
        asyncFunctions: asyncFunctions,
        memories: memories,
        tables: tables,
        globals: globals,
        globalBindings: globalBindings,
        tags: tags,
      )) {
        continue;
      }

      var bound = false;
      String? incompatibility;
      for (final argumentIndex in declaration.argumentInstanceIndices) {
        final sourceInstance = instantiatedCoreInstances[argumentIndex];
        final attempt = _tryBindImportFromCoreInstance(
          imported: imported,
          key: key,
          importingModule: module,
          sourceInstance: sourceInstance,
          sourceInstanceIndex: argumentIndex,
          functions: functions,
          asyncFunctions: asyncFunctions,
          functionTypes: functionTypes,
          functionTypeDepths: functionTypeDepths,
          memories: memories,
          tables: tables,
          globals: globals,
          globalTypes: globalTypes,
          globalBindings: globalBindings,
          tags: tags,
        );
        if (attempt.bound) {
          bound = true;
          changed = true;
          break;
        }
        incompatibility ??= attempt.incompatibility;
      }
      if (!bound && incompatibility != null) {
        throw FormatException(incompatibility);
      }
    }

    if (!changed) {
      return baseImports;
    }
    return WasmImports(
      functions: functions,
      asyncFunctions: asyncFunctions,
      functionTypes: functionTypes,
      functionTypeDepths: functionTypeDepths,
      memories: memories,
      tables: tables,
      globals: globals,
      globalTypes: globalTypes,
      globalBindings: globalBindings,
      tags: tags,
    );
  }

  static bool _isImportSatisfied({
    required WasmImport imported,
    required String key,
    required Map<String, WasmHostFunction> functions,
    required Map<String, WasmAsyncHostFunction> asyncFunctions,
    required Map<String, WasmMemory> memories,
    required Map<String, WasmTable> tables,
    required Map<String, Object?> globals,
    required Map<String, RuntimeGlobal> globalBindings,
    required Map<String, WasmTagImport> tags,
  }) {
    return switch (imported.kind) {
      WasmImportKind.function || WasmImportKind.exactFunction =>
        functions.containsKey(key) || asyncFunctions.containsKey(key),
      WasmImportKind.memory => memories.containsKey(key),
      WasmImportKind.table => tables.containsKey(key),
      WasmImportKind.global =>
        globals.containsKey(key) || globalBindings.containsKey(key),
      WasmImportKind.tag => tags.containsKey(key),
      _ => false,
    };
  }

  static _CoreImportBindingAttempt _tryBindImportFromCoreInstance({
    required WasmImport imported,
    required String key,
    required WasmModule importingModule,
    required WasmInstance sourceInstance,
    required int sourceInstanceIndex,
    required Map<String, WasmHostFunction> functions,
    required Map<String, WasmAsyncHostFunction> asyncFunctions,
    required Map<String, WasmFunctionType> functionTypes,
    required Map<String, int> functionTypeDepths,
    required Map<String, WasmMemory> memories,
    required Map<String, WasmTable> tables,
    required Map<String, Object?> globals,
    required Map<String, WasmGlobalType> globalTypes,
    required Map<String, RuntimeGlobal> globalBindings,
    required Map<String, WasmTagImport> tags,
  }) {
    final exportName = imported.name;
    switch (imported.kind) {
      case WasmImportKind.function:
      case WasmImportKind.exactFunction:
        if (!sourceInstance.exportedFunctions.contains(exportName)) {
          return (bound: false, incompatibility: null);
        }
        final compatibility = _isFunctionImportCompatibleWithExport(
          imported: imported,
          importKey: key,
          importingModule: importingModule,
          sourceInstance: sourceInstance,
          sourceInstanceIndex: sourceInstanceIndex,
          sourceExportName: exportName,
        );
        if (compatibility != null) {
          return (bound: false, incompatibility: compatibility);
        }
        functions[key] = (args) => sourceInstance.invoke(exportName, args);
        asyncFunctions[key] = (args) =>
            sourceInstance.invokeAsync(exportName, args);
        functionTypes[key] = sourceInstance.exportedFunctionType(exportName);
        functionTypeDepths[key] = sourceInstance.exportedFunctionTypeDepth(
          exportName,
        );
        return (bound: true, incompatibility: null);
      case WasmImportKind.memory:
        if (!sourceInstance.exportedMemories.contains(exportName)) {
          return (bound: false, incompatibility: null);
        }
        final compatibility = _isMemoryImportCompatibleWithExport(
          imported: imported,
          importKey: key,
          sourceInstance: sourceInstance,
          sourceInstanceIndex: sourceInstanceIndex,
          sourceExportName: exportName,
        );
        if (compatibility != null) {
          return (bound: false, incompatibility: compatibility);
        }
        memories[key] = sourceInstance.exportedMemory(exportName);
        return (bound: true, incompatibility: null);
      case WasmImportKind.table:
        if (!sourceInstance.exportedTables.contains(exportName)) {
          return (bound: false, incompatibility: null);
        }
        final compatibility = _isTableImportCompatibleWithExport(
          imported: imported,
          importKey: key,
          sourceInstance: sourceInstance,
          sourceInstanceIndex: sourceInstanceIndex,
          sourceExportName: exportName,
        );
        if (compatibility != null) {
          return (bound: false, incompatibility: compatibility);
        }
        tables[key] = sourceInstance.exportedTable(exportName);
        return (bound: true, incompatibility: null);
      case WasmImportKind.global:
        if (!sourceInstance.exportedGlobals.contains(exportName)) {
          return (bound: false, incompatibility: null);
        }
        final compatibility = _isGlobalImportCompatibleWithExport(
          imported: imported,
          importKey: key,
          sourceInstance: sourceInstance,
          sourceInstanceIndex: sourceInstanceIndex,
          sourceExportName: exportName,
        );
        if (compatibility != null) {
          return (bound: false, incompatibility: compatibility);
        }
        globals[key] = sourceInstance.readGlobal(exportName);
        globalTypes[key] = sourceInstance.exportedGlobalType(exportName);
        globalBindings[key] = sourceInstance.exportedGlobalBinding(exportName);
        return (bound: true, incompatibility: null);
      case WasmImportKind.tag:
        if (!sourceInstance.exportedTags.contains(exportName)) {
          return (bound: false, incompatibility: null);
        }
        final compatibility = _isTagImportCompatibleWithExport(
          imported: imported,
          importKey: key,
          importingModule: importingModule,
          sourceInstance: sourceInstance,
          sourceInstanceIndex: sourceInstanceIndex,
          sourceExportName: exportName,
        );
        if (compatibility != null) {
          return (bound: false, incompatibility: compatibility);
        }
        tags[key] = sourceInstance.exportedTagImport(exportName);
        return (bound: true, incompatibility: null);
      default:
        return (bound: false, incompatibility: null);
    }
  }

  static String? _isFunctionImportCompatibleWithExport({
    required WasmImport imported,
    required String importKey,
    required WasmModule importingModule,
    required WasmInstance sourceInstance,
    required int sourceInstanceIndex,
    required String sourceExportName,
  }) {
    final expectedTypeIndex = imported.functionTypeIndex;
    if (expectedTypeIndex == null ||
        expectedTypeIndex < 0 ||
        expectedTypeIndex >= importingModule.types.length) {
      return 'Malformed function import `$importKey`: invalid type index '
          '$expectedTypeIndex.';
    }
    final expectedType = importingModule.types[expectedTypeIndex];
    if (!expectedType.isFunctionType) {
      return 'Malformed function import `$importKey`: type index '
          '$expectedTypeIndex is not a function type.';
    }
    final actualType = sourceInstance.exportedFunctionType(sourceExportName);
    if (!_sameFunctionSignature(expectedType, actualType)) {
      return 'Component core-instance argument #$sourceInstanceIndex '
          'export `$sourceExportName` has incompatible function signature '
          'for import `$importKey`: expected '
          '${_formatFunctionType(expectedType)} but got '
          '${_formatFunctionType(actualType)}.';
    }
    return null;
  }

  static String? _isMemoryImportCompatibleWithExport({
    required WasmImport imported,
    required String importKey,
    required WasmInstance sourceInstance,
    required int sourceInstanceIndex,
    required String sourceExportName,
  }) {
    final expectedType = imported.memoryType;
    if (expectedType == null) {
      return 'Malformed memory import `$importKey`: missing memory type.';
    }
    final actualMemory = sourceInstance.exportedMemory(sourceExportName);
    final expectedPageSize = 1 << expectedType.pageSizeLog2;
    if (actualMemory.isMemory64 != expectedType.isMemory64) {
      return 'Component core-instance argument #$sourceInstanceIndex export '
          '`$sourceExportName` has incompatible memory index type for '
          'import `$importKey`: expected memory64=${expectedType.isMemory64}, '
          'actual=${actualMemory.isMemory64}.';
    }
    if (actualMemory.shared != expectedType.shared) {
      return 'Component core-instance argument #$sourceInstanceIndex export '
          '`$sourceExportName` has incompatible memory shared flag for '
          'import `$importKey`: expected=${expectedType.shared}, '
          'actual=${actualMemory.shared}.';
    }
    if (actualMemory.pageSizeBytes != expectedPageSize) {
      return 'Component core-instance argument #$sourceInstanceIndex export '
          '`$sourceExportName` has incompatible memory page size for '
          'import `$importKey`: expected=$expectedPageSize, '
          'actual=${actualMemory.pageSizeBytes}.';
    }
    if (actualMemory.pageCount < expectedType.minPages) {
      return 'Component core-instance argument #$sourceInstanceIndex export '
          '`$sourceExportName` has insufficient memory pages for '
          'import `$importKey`: expected at least ${expectedType.minPages}, '
          'actual=${actualMemory.pageCount}.';
    }
    final expectedMax = expectedType.maxPages;
    if (expectedMax != null) {
      final actualMax = actualMemory.maxPages;
      if (actualMax == null || actualMax > expectedMax) {
        return 'Component core-instance argument #$sourceInstanceIndex export '
            '`$sourceExportName` has incompatible memory max pages for '
            'import `$importKey`: expected <= $expectedMax, '
            'actual=${actualMax ?? 'unbounded'}.';
      }
    }
    return null;
  }

  static String? _isTableImportCompatibleWithExport({
    required WasmImport imported,
    required String importKey,
    required WasmInstance sourceInstance,
    required int sourceInstanceIndex,
    required String sourceExportName,
  }) {
    final expectedType = imported.tableType;
    if (expectedType == null) {
      return 'Malformed table import `$importKey`: missing table type.';
    }
    final actualTable = sourceInstance.exportedTable(sourceExportName);
    final expectedSignature = expectedType.refTypeSignature;
    final actualSignature = actualTable.refTypeSignature;
    final refTypeMatches = expectedSignature != null && actualSignature != null
        ? _referenceTypeSignaturesMatch(expectedSignature, actualSignature)
        : actualTable.refType == expectedType.refType;
    if (!refTypeMatches) {
      return 'Component core-instance argument #$sourceInstanceIndex export '
          '`$sourceExportName` has incompatible table reference type for '
          'import `$importKey`: expected ${_formatTableType(expectedType)}, '
          'actual ${_formatTable(actualTable)}.';
    }
    if (actualTable.isTable64 != expectedType.isTable64) {
      return 'Component core-instance argument #$sourceInstanceIndex export '
          '`$sourceExportName` has incompatible table index type for '
          'import `$importKey`: expected table64=${expectedType.isTable64}, '
          'actual=${actualTable.isTable64}.';
    }
    if (actualTable.length < expectedType.min) {
      return 'Component core-instance argument #$sourceInstanceIndex export '
          '`$sourceExportName` has insufficient table length for '
          'import `$importKey`: expected at least ${expectedType.min}, '
          'actual=${actualTable.length}.';
    }
    final expectedMax = expectedType.max;
    if (expectedMax != null) {
      final actualMax = actualTable.max;
      if (actualMax == null || actualMax > expectedMax) {
        return 'Component core-instance argument #$sourceInstanceIndex export '
            '`$sourceExportName` has incompatible table max for import '
            '`$importKey`: expected <= $expectedMax, '
            'actual=${actualMax ?? 'unbounded'}.';
      }
    }
    return null;
  }

  static String? _isGlobalImportCompatibleWithExport({
    required WasmImport imported,
    required String importKey,
    required WasmInstance sourceInstance,
    required int sourceInstanceIndex,
    required String sourceExportName,
  }) {
    final expectedType = imported.globalType;
    if (expectedType == null) {
      return 'Malformed global import `$importKey`: missing global type.';
    }
    final actualType = sourceInstance.exportedGlobalType(sourceExportName);
    if (!_isGlobalImportTypeCompatible(
      expected: expectedType,
      actual: actualType,
    )) {
      return 'Component core-instance argument #$sourceInstanceIndex export '
          '`$sourceExportName` has incompatible global type for '
          'import `$importKey`: expected ${_formatGlobalType(expectedType)}, '
          'actual ${_formatGlobalType(actualType)}.';
    }
    return null;
  }

  static String? _isTagImportCompatibleWithExport({
    required WasmImport imported,
    required String importKey,
    required WasmModule importingModule,
    required WasmInstance sourceInstance,
    required int sourceInstanceIndex,
    required String sourceExportName,
  }) {
    final tagType = imported.tagType;
    if (tagType == null) {
      return 'Malformed tag import `$importKey`: missing tag type.';
    }
    final typeIndex = tagType.typeIndex;
    if (typeIndex < 0 ||
        typeIndex >= importingModule.types.length ||
        !importingModule.types[typeIndex].isFunctionType) {
      return 'Malformed tag import `$importKey`: invalid type index '
          '$typeIndex.';
    }
    final expectedType = importingModule.types[typeIndex];
    final expectedTypeKey = _tagNominalTypeKey(importingModule, typeIndex);
    final actualTag = sourceInstance.exportedTagImport(sourceExportName);
    if (!_sameFunctionSignature(expectedType, actualTag.type) ||
        expectedTypeKey != actualTag.typeKey) {
      return 'Component core-instance argument #$sourceInstanceIndex export '
          '`$sourceExportName` has incompatible tag type for import '
          '`$importKey`: expected ${_formatFunctionType(expectedType)} '
          '(nominal=$expectedTypeKey), actual '
          '${_formatFunctionType(actualTag.type)} '
          '(nominal=${actualTag.typeKey}).';
    }
    return null;
  }

  static bool _sameFunctionSignature(
    WasmFunctionType expected,
    WasmFunctionType actual,
  ) {
    if (expected.params.length != actual.params.length ||
        expected.results.length != actual.results.length) {
      return false;
    }
    for (var i = 0; i < expected.params.length; i++) {
      if (expected.params[i] != actual.params[i]) {
        return false;
      }
    }
    for (var i = 0; i < expected.results.length; i++) {
      if (expected.results[i] != actual.results[i]) {
        return false;
      }
    }

    final expectedHasParamSignatures =
        expected.paramTypeSignatures.length == expected.params.length;
    final actualHasParamSignatures =
        actual.paramTypeSignatures.length == actual.params.length;
    if (expectedHasParamSignatures || actualHasParamSignatures) {
      if (!expectedHasParamSignatures || !actualHasParamSignatures) {
        return false;
      }
      for (var i = 0; i < expected.paramTypeSignatures.length; i++) {
        if (expected.paramTypeSignatures[i] != actual.paramTypeSignatures[i]) {
          return false;
        }
      }
    }

    final expectedHasResultSignatures =
        expected.resultTypeSignatures.length == expected.results.length;
    final actualHasResultSignatures =
        actual.resultTypeSignatures.length == actual.results.length;
    if (expectedHasResultSignatures || actualHasResultSignatures) {
      if (!expectedHasResultSignatures || !actualHasResultSignatures) {
        return false;
      }
      for (var i = 0; i < expected.resultTypeSignatures.length; i++) {
        if (expected.resultTypeSignatures[i] !=
            actual.resultTypeSignatures[i]) {
          return false;
        }
      }
    }

    return true;
  }

  static String _formatFunctionType(WasmFunctionType type) {
    List<String> formatTypes(
      List<WasmValueType> types,
      List<String> signatures,
    ) {
      if (signatures.length == types.length) {
        return signatures;
      }
      return types.map((type) => type.name).toList(growable: false);
    }

    final params = formatTypes(
      type.params,
      type.paramTypeSignatures,
    ).join(', ');
    final results = formatTypes(
      type.results,
      type.resultTypeSignatures,
    ).join(', ');
    return '($params) -> ($results)';
  }

  static String _formatTableType(WasmTableType type) {
    final refType = type.refTypeSignature ?? type.refType.name;
    return '(ref=$refType, min=${type.min}, max=${type.max ?? 'unbounded'}, '
        'table64=${type.isTable64})';
  }

  static String _formatTable(WasmTable table) {
    final refType = table.refTypeSignature ?? table.refType.name;
    return '(ref=$refType, min=${table.min}, max=${table.max ?? 'unbounded'}, '
        'table64=${table.isTable64}, len=${table.length})';
  }

  static String _formatGlobalType(WasmGlobalType type) {
    final valueType = type.valueTypeSignature ?? type.valueType.name;
    return '(value=$valueType, mutable=${type.mutable})';
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

  List<Object?> invokeCanonical({
    required String exportName,
    required List<WasmCanonicalAbiType> parameterTypes,
    required List<Object?> parameters,
    required List<WasmCanonicalAbiType> resultTypes,
    int moduleIndex = 0,
    int memoryIndex = 0,
    WasmCanonicalAbiAllocator? allocator,
  }) {
    final instance = coreInstance(moduleIndex);
    final memory = _memoryForIndex(instance, memoryIndex);
    final effectiveAllocator =
        allocator ??
        WasmCanonicalAbiAllocator(cursor: 0, maxOffset: memory.lengthInBytes);
    final flatArgs = WasmCanonicalAbi.lowerValues(
      types: parameterTypes,
      values: parameters,
      memory: memory,
      allocator: effectiveAllocator,
    );
    final rawFlatResults = instance.invokeMulti(exportName, flatArgs);
    final flatResults = _canonicalFlatResults(rawFlatResults);
    return WasmCanonicalAbi.liftValues(
      types: resultTypes,
      flatValues: flatResults,
      memory: memory,
    );
  }

  Future<List<Object?>> invokeCanonicalAsync({
    required String exportName,
    required List<WasmCanonicalAbiType> parameterTypes,
    required List<Object?> parameters,
    required List<WasmCanonicalAbiType> resultTypes,
    int moduleIndex = 0,
    int memoryIndex = 0,
    WasmCanonicalAbiAllocator? allocator,
  }) async {
    final instance = coreInstance(moduleIndex);
    final memory = _memoryForIndex(instance, memoryIndex);
    final effectiveAllocator =
        allocator ??
        WasmCanonicalAbiAllocator(cursor: 0, maxOffset: memory.lengthInBytes);
    final flatArgs = WasmCanonicalAbi.lowerValues(
      types: parameterTypes,
      values: parameters,
      memory: memory,
      allocator: effectiveAllocator,
    );
    final rawFlatResults = await instance.invokeMultiAsync(
      exportName,
      flatArgs,
    );
    final flatResults = _canonicalFlatResults(rawFlatResults);
    return WasmCanonicalAbi.liftValues(
      types: resultTypes,
      flatValues: flatResults,
      memory: memory,
    );
  }

  WasmMemory _memoryForIndex(WasmInstance instance, int memoryIndex) {
    if (memoryIndex < 0 || memoryIndex >= instance.memories.length) {
      throw RangeError(
        'Component memory index out of range: $memoryIndex '
        '(count=${instance.memories.length}).',
      );
    }
    return instance.memories[memoryIndex];
  }

  List<Object> _canonicalFlatResults(List<Object?> rawFlatResults) {
    final flatResults = <Object>[];
    for (final value in rawFlatResults) {
      if (value == null) {
        throw const FormatException(
          'Canonical ABI result values cannot contain `null`.',
        );
      }
      flatResults.add(value);
    }
    return flatResults;
  }

  void _checkModuleIndex(int moduleIndex) {
    if (moduleIndex < 0 || moduleIndex >= coreInstances.length) {
      throw RangeError(
        'Component core module index out of range: $moduleIndex '
        '(count=${coreInstances.length}).',
      );
    }
  }
}
