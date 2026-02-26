import 'dart:typed_data';

import 'component.dart';
import 'component_canonical_abi.dart';
import 'features.dart';
import 'imports.dart';
import 'instance.dart';
import 'memory.dart';
import 'module.dart';
import 'runtime_global.dart';
import 'table.dart';

/// Component-level runtime that instantiates embedded core modules.
///
/// Current scope:
/// - Instantiates embedded core modules discovered in section `0x01`.
/// - Exposes direct core export invocation.
/// - Exposes component export aliases decoded from section `0x03`.
/// - Provides canonical ABI lowering/lifting wrappers over a selected memory.
final class WasmComponentInstance {
  WasmComponentInstance._({
    required this.component,
    required this.imports,
    required this.features,
    required this.coreInstances,
    required Map<String, int> coreInstanceAliases,
    required Map<String, ({int instanceIndex, String coreExportName})>
    coreExportAliases,
  }) : _coreInstanceAliases = coreInstanceAliases,
       _coreExportAliases = coreExportAliases;

  final WasmComponent component;
  final WasmImports imports;
  final WasmFeatureSet features;
  final List<WasmInstance> coreInstances;
  final Map<String, int> _coreInstanceAliases;
  final Map<String, ({int instanceIndex, String coreExportName})>
  _coreExportAliases;

  factory WasmComponentInstance.fromBytes(
    Uint8List componentBytes, {
    WasmImports imports = const WasmImports(),
    WasmFeatureSet features = const WasmFeatureSet(componentModel: true),
  }) {
    final component = WasmComponent.decode(componentBytes, features: features);
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
    _validateComponentImportRequirements(component, imports);
    final coreInstances = <WasmInstance>[];
    if (component.coreInstances.isEmpty) {
      coreInstances.addAll(
        component.coreModules.map(
          (moduleBytes) => WasmInstance.fromBytes(
            moduleBytes,
            imports: imports,
            features: features,
          ),
        ),
      );
    } else {
      for (final declaration in component.coreInstances) {
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
        final declarationImports = _composeCoreInstanceImports(
          moduleBytes: component.coreModules[moduleIndex],
          declaration: declaration,
          baseImports: imports,
          instantiatedCoreInstances: coreInstances,
          features: features,
        );
        coreInstances.add(
          WasmInstance.fromBytes(
            component.coreModules[moduleIndex],
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
    final aliasMap = <String, ({int instanceIndex, String coreExportName})>{};
    for (final alias in component.coreExportAliases) {
      final instanceIndex = alias.instanceIndex;
      if (instanceIndex < 0 || instanceIndex >= coreInstances.length) {
        throw FormatException(
          'Component export alias `${alias.componentExportName}` references '
          'invalid core instance index $instanceIndex '
          '(count=${coreInstances.length}).',
        );
      }
      aliasMap[alias.componentExportName] = (
        instanceIndex: instanceIndex,
        coreExportName: alias.coreExportName,
      );
    }
    return WasmComponentInstance._(
      component: component,
      imports: imports,
      features: features,
      coreInstances: List<WasmInstance>.unmodifiable(coreInstances),
      coreInstanceAliases: Map<String, int>.unmodifiable(instanceAliasMap),
      coreExportAliases:
          Map<
            String,
            ({int instanceIndex, String coreExportName})
          >.unmodifiable(aliasMap),
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
    final binding = _coreExportAliases[exportName];
    if (binding == null) {
      throw ArgumentError.value(
        exportName,
        'exportName',
        'Component export alias not found',
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
    final binding = _coreExportAliases[exportName];
    if (binding == null) {
      throw ArgumentError.value(
        exportName,
        'exportName',
        'Component export alias not found',
      );
    }
    return coreInstance(
      binding.instanceIndex,
    ).invokeAsync(binding.coreExportName, args);
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

      for (final argumentIndex in declaration.argumentInstanceIndices) {
        final sourceInstance = instantiatedCoreInstances[argumentIndex];
        if (_tryBindImportFromCoreInstance(
          imported: imported,
          key: key,
          sourceInstance: sourceInstance,
          functions: functions,
          asyncFunctions: asyncFunctions,
          functionTypeDepths: functionTypeDepths,
          memories: memories,
          tables: tables,
          globals: globals,
          globalTypes: globalTypes,
          globalBindings: globalBindings,
          tags: tags,
        )) {
          changed = true;
          break;
        }
      }
    }

    if (!changed) {
      return baseImports;
    }
    return WasmImports(
      functions: functions,
      asyncFunctions: asyncFunctions,
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

  static bool _tryBindImportFromCoreInstance({
    required WasmImport imported,
    required String key,
    required WasmInstance sourceInstance,
    required Map<String, WasmHostFunction> functions,
    required Map<String, WasmAsyncHostFunction> asyncFunctions,
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
          return false;
        }
        functions[key] = (args) => sourceInstance.invoke(exportName, args);
        asyncFunctions[key] = (args) =>
            sourceInstance.invokeAsync(exportName, args);
        functionTypeDepths[key] = sourceInstance.exportedFunctionTypeDepth(
          exportName,
        );
        return true;
      case WasmImportKind.memory:
        if (!sourceInstance.exportedMemories.contains(exportName)) {
          return false;
        }
        memories[key] = sourceInstance.exportedMemory(exportName);
        return true;
      case WasmImportKind.table:
        if (!sourceInstance.exportedTables.contains(exportName)) {
          return false;
        }
        tables[key] = sourceInstance.exportedTable(exportName);
        return true;
      case WasmImportKind.global:
        if (!sourceInstance.exportedGlobals.contains(exportName)) {
          return false;
        }
        globals[key] = sourceInstance.readGlobal(exportName);
        globalTypes[key] = sourceInstance.exportedGlobalType(exportName);
        globalBindings[key] = sourceInstance.exportedGlobalBinding(exportName);
        return true;
      case WasmImportKind.tag:
        if (!sourceInstance.exportedTags.contains(exportName)) {
          return false;
        }
        tags[key] = sourceInstance.exportedTagImport(exportName);
        return true;
      default:
        return false;
    }
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
