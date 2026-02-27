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
import 'value.dart';

typedef _CoreImportBindingAttempt = ({bool bound, String? incompatibility});
typedef _TypedFunctionImportRequirement = ({
  String componentImportName,
  List<String> parameterSignatures,
  List<String> resultSignatures,
});

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
    final typedFunctionImportRequirements =
        _collectTypedFunctionImportRequirements(component);
    final coreInstances = <WasmInstance>[];
    if (component.coreInstances.isEmpty) {
      for (
        var moduleIndex = 0;
        moduleIndex < component.coreModules.length;
        moduleIndex++
      ) {
        final moduleBytes = component.coreModules[moduleIndex];
        _validateTypedFunctionImportBindingsForCoreModule(
          moduleBytes: moduleBytes,
          moduleIndex: moduleIndex,
          features: features,
          typedRequirementsByImportKey: typedFunctionImportRequirements,
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
        _validateTypedFunctionImportBindingsForCoreModule(
          moduleBytes: moduleBytes,
          moduleIndex: moduleIndex,
          features: features,
          typedRequirementsByImportKey: typedFunctionImportRequirements,
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
      final sourceInstance = coreInstances[instanceIndex];
      if (!sourceInstance.exportedFunctions.contains(alias.coreExportName)) {
        throw FormatException(
          'Component export alias `${alias.componentExportName}` references '
          'missing core function export `${alias.coreExportName}` in '
          'instance $instanceIndex.',
        );
      }
      aliasMap[alias.componentExportName] = (
        instanceIndex: instanceIndex,
        coreExportName: alias.coreExportName,
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
        case WasmComponentImportKind.global:
          final valueTypeCode = declaration.valueTypeCode;
          if (declaration.kind != WasmComponentTypeKind.value ||
              valueTypeCode == null) {
            throw FormatException(
              'Component global import `${requirement.componentImportName}` '
              'must bind to a value type declaration.',
            );
          }
          final expectedType = _decodeCoreValueTypeCode(valueTypeCode);
          if (expectedType == null) {
            throw UnsupportedError(
              'Component global import `${requirement.componentImportName}` '
              'uses unsupported value type code 0x${valueTypeCode.toRadixString(16)}.',
            );
          }

          final bindingGlobal = imports.globalBindings[key];
          if (bindingGlobal != null) {
            if (bindingGlobal.valueType != expectedType) {
              throw FormatException(
                'Component global import `${requirement.componentImportName}` '
                'type mismatch: expected ${expectedType.name}, '
                'actual ${bindingGlobal.valueType.name}.',
              );
            }
            break;
          }
          if (imports.globals.containsKey(key)) {
            final value = imports.globals[key];
            try {
              WasmValue.fromExternal(expectedType, value);
            } catch (_) {
              throw FormatException(
                'Component global import `${requirement.componentImportName}` '
                'is not compatible with expected type ${expectedType.name}.',
              );
            }
          }
          break;
        case WasmComponentImportKind.function:
        case WasmComponentImportKind.memory:
        case WasmComponentImportKind.table:
        case WasmComponentImportKind.tag:
          break;
      }
    }
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
        parameterSignatures: _componentTypeCodesToSignatures(
          declaration.parameterTypeCodes,
        ),
        resultSignatures: _componentTypeCodesToSignatures(
          declaration.resultTypeCodes,
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

  static void _validateTypedFunctionImportBindingsForCoreModule({
    required Uint8List moduleBytes,
    required int moduleIndex,
    required WasmFeatureSet features,
    required Map<String, _TypedFunctionImportRequirement>
    typedRequirementsByImportKey,
  }) {
    if (typedRequirementsByImportKey.isEmpty) {
      return;
    }
    final module = WasmModule.decode(moduleBytes, features: features);
    for (final imported in module.imports) {
      if (imported.kind != WasmImportKind.function &&
          imported.kind != WasmImportKind.exactFunction) {
        continue;
      }
      final typedRequirement = typedRequirementsByImportKey[imported.key];
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
      if (declaration.kind != WasmComponentTypeKind.function) {
        continue;
      }
      final instanceIndex = alias.instanceIndex;
      if (instanceIndex < 0 || instanceIndex >= coreInstances.length) {
        continue;
      }
      final instance = coreInstances[instanceIndex];
      if (!instance.exportedFunctions.contains(alias.coreExportName)) {
        continue;
      }
      final actualType = instance.exportedFunctionType(alias.coreExportName);
      _validateComponentFunctionDeclarationAgainstCoreType(
        declaration: declaration,
        actualType: actualType,
        context:
            'Component export alias `${alias.componentExportName}` '
            '(instance=$instanceIndex, export=`${alias.coreExportName}`)',
      );
    }
  }

  static void _validateComponentFunctionDeclarationAgainstCoreType({
    required WasmComponentTypeDeclaration declaration,
    required WasmFunctionType actualType,
    required String context,
  }) {
    _validateExpectedFunctionSignaturesAgainstCoreType(
      expectedParameters: _componentTypeCodesToSignatures(
        declaration.parameterTypeCodes,
      ),
      expectedResults: _componentTypeCodesToSignatures(
        declaration.resultTypeCodes,
      ),
      actualType: actualType,
      context: '$context for function declaration `${declaration.name}`',
    );
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
        functionTypeDepths[key] = sourceInstance.exportedFunctionTypeDepth(
          exportName,
        );
        return (bound: true, incompatibility: null);
      case WasmImportKind.memory:
        if (!sourceInstance.exportedMemories.contains(exportName)) {
          return (bound: false, incompatibility: null);
        }
        memories[key] = sourceInstance.exportedMemory(exportName);
        return (bound: true, incompatibility: null);
      case WasmImportKind.table:
        if (!sourceInstance.exportedTables.contains(exportName)) {
          return (bound: false, incompatibility: null);
        }
        tables[key] = sourceInstance.exportedTable(exportName);
        return (bound: true, incompatibility: null);
      case WasmImportKind.global:
        if (!sourceInstance.exportedGlobals.contains(exportName)) {
          return (bound: false, incompatibility: null);
        }
        globals[key] = sourceInstance.readGlobal(exportName);
        globalTypes[key] = sourceInstance.exportedGlobalType(exportName);
        globalBindings[key] = sourceInstance.exportedGlobalBinding(exportName);
        return (bound: true, incompatibility: null);
      case WasmImportKind.tag:
        if (!sourceInstance.exportedTags.contains(exportName)) {
          return (bound: false, incompatibility: null);
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
