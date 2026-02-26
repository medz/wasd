import 'dart:typed_data';

import 'component.dart';
import 'component_canonical_abi.dart';
import 'features.dart';
import 'imports.dart';
import 'instance.dart';
import 'memory.dart';

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
        coreInstances.add(
          WasmInstance.fromBytes(
            component.coreModules[moduleIndex],
            imports: imports,
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
