import 'dart:async';
import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../../wasm/backend/native/interpreter/features.dart';
import '../../wasm/backend/native/interpreter/imports.dart' as ir_imports;
import '../../wasm/backend/native/interpreter/instance.dart' as ir_instance;
import '../../wasm/backend/native/interpreter/memory.dart' as ir_memory;
import '../../wasm/backend/native/interpreter/module.dart' as ir_module;
import '../../wasm/backend/native/interpreter/runtime_global.dart';
import '../../wasm/backend/native/interpreter/table.dart' as ir_table;
import '../../wasm/backend/native/memory.dart' as native_memory;
import '../component/adapter_host.dart';
import '../component/host.dart';
import '../component/string_memory.dart';
import 'cli.dart';
import 'component_host.dart';

/// Result returned after executing a WASI Preview2 command component.
final class WASIPreview2CommandResult {
  /// Creates a command execution result.
  const WASIPreview2CommandResult({required this.exitCode});

  /// Process-style exit code. `0` means success.
  final int exitCode;
}

/// Executes WASI Preview2 `wasi:cli/command` components on the native backend.
final class WASIPreview2CommandRunner {
  /// Creates a command runner over [host].
  const WASIPreview2CommandRunner(this.host);

  /// Preview2 host used for standard WASI imports and canonical state.
  final WASIPreview2ComponentHost host;

  /// Instantiates [component] and invokes its exported `wasi:cli/run`.
  Future<WASIPreview2CommandResult> run(WasmComponent component) async {
    final runtime = _Preview2ComponentRuntime(component: component, host: host);
    final exitCode = await runtime.runCommand();
    return WASIPreview2CommandResult(exitCode: exitCode);
  }
}

/// Thrown when a Preview2 component cannot be linked or executed.
final class WASIPreview2ComponentExecutionException implements Exception {
  /// Creates an execution exception with [message].
  const WASIPreview2ComponentExecutionException(this.message);

  /// Human-readable failure message.
  final String message;

  @override
  String toString() => message;
}

final class _Preview2ComponentRuntime {
  _Preview2ComponentRuntime({required this.component, required this.host});

  final WasmComponent component;
  final WASIPreview2ComponentHost host;

  final List<ir_module.WasmModule> _coreModules = <ir_module.WasmModule>[];
  final List<_CoreFunction> _coreFunctions = <_CoreFunction>[];
  final List<_CoreMemory> _coreMemories = <_CoreMemory>[];
  final List<ir_table.WasmTable> _coreTables = <ir_table.WasmTable>[];
  final List<RuntimeGlobal> _coreGlobals = <RuntimeGlobal>[];
  final List<ir_imports.WasmTagImport> _coreTags = <ir_imports.WasmTagImport>[];
  final List<_CoreInstance> _coreInstances = <_CoreInstance>[];
  final List<_ComponentFunction> _componentFunctions = <_ComponentFunction>[];
  final List<_ComponentInstance> _componentInstances = <_ComponentInstance>[];
  final List<WasmComponentTypeDefinition> _visibleTypes =
      <WasmComponentTypeDefinition>[];
  final Map<String, _ComponentFunction> _exportedFunctions =
      <String, _ComponentFunction>{};
  final Map<String, _ComponentInstance> _exportedInstances =
      <String, _ComponentInstance>{};
  final Map<ir_memory.WasmMemory, native_memory.Memory> _memoryWrappers =
      <ir_memory.WasmMemory, native_memory.Memory>{};
  final Map<int, WASIComponentCanonicalAdapterCallback> _adapterCoreCallbacks =
      <int, WASIComponentCanonicalAdapterCallback>{};
  final Map<int, WASIComponentCanonicalAdapterCallback>
  _adapterComponentCallbacks = <int, WASIComponentCanonicalAdapterCallback>{};

  late final WASIComponentHostBinding _binding;
  var _decodedTypeDefinitionCount = 0;

  Future<int> runCommand() async {
    _checkComponent();
    _processDefinitions();
    _binding = host.bindComponent(
      component,
      coreFunctions: _adapterCoreCallbacks,
      componentFunctions: _adapterComponentCallbacks,
    );
    final run = _findCommandRun();
    try {
      final result = await run.invoke(const <Object?>[]);
      return _runResultExitCode(result);
    } on WASIPreview2Exit catch (exit) {
      return exit.statusCode;
    }
  }

  void _checkComponent() {
    final validationErrors = component.validate();
    if (validationErrors.isNotEmpty) {
      throw WASIPreview2ComponentExecutionException(
        _formatErrors(
          'wasd-preview2-runner validation failed',
          validationErrors,
        ),
      );
    }
    final plan = host.prepareComponent(component);
    if (plan.canBindWithAdapters) {
      return;
    }
    throw WASIPreview2ComponentExecutionException(
      _formatErrors('wasd-preview2-runner bind preflight failed', [
        ...plan.versionErrors,
        ...plan.validationErrors,
        ...plan.unsupportedDefinitions,
        ...plan.bindingErrors,
      ]),
    );
  }

  void _processDefinitions() {
    for (final event in component.definitionEvents) {
      switch (event.kind) {
        case WasmComponentDefinitionKind.coreModule:
          _coreModules.add(component.coreModules[event.index]);
        case WasmComponentDefinitionKind.coreInstance:
          _coreInstances.add(
            _instantiateCoreInstance(component.coreInstances[event.index]),
          );
        case WasmComponentDefinitionKind.typeCount:
          _includeTypeDefinitionsTo(event.index);
        case WasmComponentDefinitionKind.import:
          _addComponentImport(component.imports[event.index]);
        case WasmComponentDefinitionKind.alias:
          _addAlias(component.aliases[event.index]);
        case WasmComponentDefinitionKind.canonical:
          _addCanonical(
            event.index,
            component.canonicalDefinitions[event.index],
          );
        case WasmComponentDefinitionKind.instance:
          _componentInstances.add(
            _instantiateComponentInstance(component.instances[event.index]),
          );
        case WasmComponentDefinitionKind.export:
          _addExport(component.exports[event.index]);
        case WasmComponentDefinitionKind.start:
          _runStart(component.starts[event.index]);
        case WasmComponentDefinitionKind.coreType:
        case WasmComponentDefinitionKind.component:
        case WasmComponentDefinitionKind.type:
        case WasmComponentDefinitionKind.value:
          break;
      }
    }
  }

  void _includeTypeDefinitionsTo(int count) {
    if (count <= _decodedTypeDefinitionCount) {
      return;
    }
    _visibleTypes.addAll(
      component.typeDefinitions.getRange(_decodedTypeDefinitionCount, count),
    );
    _decodedTypeDefinitionCount = count;
  }

  void _addComponentImport(WasmComponentImport import) {
    final name = _externName(import.name, import.versionSuffix);
    switch (import.descriptor.kind) {
      case WasmComponentExternKind.function:
        _componentFunctions.add(_hostComponentFunction(name));
      case WasmComponentExternKind.instance:
        _componentInstances.add(
          _hostComponentInstance(name, import.descriptor),
        );
      case WasmComponentExternKind.coreModule:
        throw WASIPreview2ComponentExecutionException(
          'Imported core modules are not supported yet: $name.',
        );
      case WasmComponentExternKind.component:
      case WasmComponentExternKind.componentType:
      case WasmComponentExternKind.value:
        throw WASIPreview2ComponentExecutionException(
          'Unsupported component import `$name` of kind '
          '${import.descriptor.kind.name}.',
        );
    }
  }

  _ComponentInstance _hostComponentInstance(
    String interfaceName,
    WasmComponentExternDescriptor descriptor,
  ) {
    final type = _typeDefinitionAt(descriptor.typeIndex);
    final instanceType = type?.instance;
    if (type == null ||
        type.kind != WasmComponentTypeKind.instance ||
        instanceType == null) {
      throw WASIPreview2ComponentExecutionException(
        'Component import `$interfaceName` does not reference an instance type.',
      );
    }
    final functions = <String, _ComponentFunction>{};
    for (final declaration in instanceType.declarations) {
      final export = declaration.export;
      if (declaration.kind != WasmComponentTypeDeclarationKind.export ||
          export == null ||
          export.descriptor.kind != WasmComponentExternKind.function) {
        continue;
      }
      final functionName = _externName(export.name, export.versionSuffix);
      functions[functionName] = _hostComponentFunction(
        _witCallbackKey(interfaceName, functionName),
      );
    }
    return _ComponentInstance(functions: Map.unmodifiable(functions));
  }

  _ComponentFunction _hostComponentFunction(String key) {
    final callback = host.standardImports[key];
    if (callback == null) {
      throw WASIPreview2ComponentExecutionException(
        'Missing WASI Preview2 import callback `$key`.',
      );
    }
    return _ComponentFunction(name: key, invoke: callback);
  }

  WasmComponentTypeDefinition? _typeDefinitionAt(int? index) {
    if (index == null || index < 0 || index >= _visibleTypes.length) {
      return null;
    }
    return _visibleTypes[index];
  }

  void _addAlias(WasmComponentAlias alias) {
    switch (alias.target.kind) {
      case WasmComponentAliasTargetKind.coreExport:
        final instanceIndex = alias.target.coreInstanceIndex;
        final name = alias.target.name;
        if (instanceIndex == null ||
            name == null ||
            instanceIndex < 0 ||
            instanceIndex >= _coreInstances.length) {
          throw WASIPreview2ComponentExecutionException(
            'Invalid core export alias target.',
          );
        }
        _addCoreSort(alias.sort.coreKind, _coreInstances[instanceIndex], name);
      case WasmComponentAliasTargetKind.export:
        final instanceIndex = alias.target.instanceIndex;
        final name = alias.target.name;
        if (instanceIndex == null ||
            name == null ||
            instanceIndex < 0 ||
            instanceIndex >= _componentInstances.length) {
          throw WASIPreview2ComponentExecutionException(
            'Invalid component export alias target.',
          );
        }
        _addComponentSort(
          alias.sort.kind,
          _componentInstances[instanceIndex],
          name,
        );
      case WasmComponentAliasTargetKind.outer:
        throw const WASIPreview2ComponentExecutionException(
          'Outer aliases are not executable in the Preview2 runner yet.',
        );
    }
  }

  void _addCoreSort(
    WasmComponentCoreSortKind? kind,
    _CoreInstance instance,
    String name,
  ) {
    final export = instance.exports[name];
    if (export == null) {
      throw WASIPreview2ComponentExecutionException(
        'Core export `$name` not found.',
      );
    }
    switch (kind) {
      case WasmComponentCoreSortKind.function:
        _coreFunctions.add(export.requireFunction(name));
      case WasmComponentCoreSortKind.memory:
        _coreMemories.add(export.requireMemory(name));
      case WasmComponentCoreSortKind.table:
        _coreTables.add(export.requireTable(name));
      case WasmComponentCoreSortKind.global:
        _coreGlobals.add(export.requireGlobal(name));
      case WasmComponentCoreSortKind.tag:
        _coreTags.add(export.requireTag(name));
      case WasmComponentCoreSortKind.type:
      case WasmComponentCoreSortKind.module:
      case WasmComponentCoreSortKind.instance:
      case null:
        throw WASIPreview2ComponentExecutionException(
          'Unsupported core alias sort `$kind` for `$name`.',
        );
    }
  }

  void _addComponentSort(
    WasmComponentSortKind kind,
    _ComponentInstance instance,
    String name,
  ) {
    switch (kind) {
      case WasmComponentSortKind.function:
        final function = instance.functions[name];
        if (function == null) {
          throw WASIPreview2ComponentExecutionException(
            'Component function export `$name` not found.',
          );
        }
        _componentFunctions.add(function);
      case WasmComponentSortKind.instance:
      case WasmComponentSortKind.value:
      case WasmComponentSortKind.componentType:
      case WasmComponentSortKind.component:
      case WasmComponentSortKind.core:
        throw WASIPreview2ComponentExecutionException(
          'Unsupported component alias sort `${kind.name}` for `$name`.',
        );
    }
  }

  void _addCanonical(
    int canonicalIndex,
    WasmComponentCanonicalDefinition definition,
  ) {
    switch (definition.kind) {
      case WasmComponentCanonicalKind.lower:
        final functionIndex = definition.functionIndex;
        if (functionIndex == null ||
            functionIndex < 0 ||
            functionIndex >= _componentFunctions.length) {
          throw WASIPreview2ComponentExecutionException(
            'Canonical lower $canonicalIndex references an unknown function.',
          );
        }
        _adapterComponentCallbacks[functionIndex] =
            _componentFunctions[functionIndex].invoke;
        _coreFunctions.add(
          _CoreFunction(
            name: 'canonical[$canonicalIndex].lower',
            invoke: (args) async => _coreHostResult(
              await _binding.program.invokeFlatAsync(
                canonicalIndex,
                args,
                memory: _canonicalMemory(definition),
                realloc: _canonicalRealloc(definition),
              ),
            ),
            invokeSync: (args) => _coreHostResult(
              _binding.program.invokeFlat(
                canonicalIndex,
                args,
                memory: _canonicalMemory(definition),
                realloc: _canonicalRealloc(definition),
              ),
            ),
          ),
        );
      case WasmComponentCanonicalKind.lift:
        final coreFunctionIndex = definition.coreFunctionIndex;
        if (coreFunctionIndex == null ||
            coreFunctionIndex < 0 ||
            coreFunctionIndex >= _coreFunctions.length) {
          throw WASIPreview2ComponentExecutionException(
            'Canonical lift $canonicalIndex references an unknown core function.',
          );
        }
        _adapterCoreCallbacks[coreFunctionIndex] =
            _coreFunctions[coreFunctionIndex].invoke;
        _componentFunctions.add(
          _ComponentFunction(
            name: 'canonical[$canonicalIndex].lift',
            invoke: (args) => _invokeLiftedCoreFunction(
              definition,
              _coreFunctions[coreFunctionIndex],
              args,
            ),
          ),
        );
      default:
        break;
    }
  }

  native_memory.Memory? _canonicalMemory(
    WasmComponentCanonicalDefinition definition,
  ) {
    final memoryIndex = _canonicalOptionIndex(
      definition,
      WasmComponentCanonicalOptionKind.memory,
    );
    if (memoryIndex == null) {
      return null;
    }
    if (memoryIndex < 0 || memoryIndex >= _coreMemories.length) {
      throw WASIPreview2ComponentExecutionException(
        'Canonical ${definition.kind.name} references unknown memory $memoryIndex.',
      );
    }
    return _coreMemories[memoryIndex].memory;
  }

  WASIComponentCanonicalRealloc? _canonicalRealloc(
    WasmComponentCanonicalDefinition definition,
  ) {
    final reallocIndex = _canonicalOptionIndex(
      definition,
      WasmComponentCanonicalOptionKind.realloc,
    );
    if (reallocIndex == null) {
      return null;
    }
    if (reallocIndex < 0 || reallocIndex >= _coreFunctions.length) {
      throw WASIPreview2ComponentExecutionException(
        'Canonical ${definition.kind.name} references unknown realloc $reallocIndex.',
      );
    }
    final function = _coreFunctions[reallocIndex];
    return (oldPointer, oldSize, alignment, newSize) {
      final result = function.invokeSync(<Object?>[
        oldPointer,
        oldSize,
        alignment,
        newSize,
      ]);
      if (result is! int) {
        throw StateError('Canonical realloc did not return an i32 pointer.');
      }
      return result;
    };
  }

  int? _canonicalOptionIndex(
    WasmComponentCanonicalDefinition definition,
    WasmComponentCanonicalOptionKind kind,
  ) {
    for (final option in definition.options) {
      if (option.kind == kind) {
        return option.index;
      }
    }
    return null;
  }

  FutureOr<Object?> _invokeLiftedCoreFunction(
    WasmComponentCanonicalDefinition definition,
    _CoreFunction function,
    List<Object?> args,
  ) async {
    if (args.isNotEmpty) {
      throw WASIPreview2ComponentExecutionException(
        'Preview2 command runner only supports zero-argument lifted exports.',
      );
    }
    final functionType = _componentFunctionType(definition.typeIndex);
    if (functionType == null) {
      throw WASIPreview2ComponentExecutionException(
        'Canonical lift does not reference a component function type.',
      );
    }
    final result = await function.invoke(const <Object?>[]);
    return _liftFlatResult(functionType.result, result);
  }

  WasmComponentFunctionType? _componentFunctionType(int? typeIndex) {
    final type = _typeDefinitionAt(typeIndex);
    if (type == null || type.kind != WasmComponentTypeKind.function) {
      return null;
    }
    return type.function;
  }

  Object? _liftFlatResult(WasmComponentValueType? type, Object? flatResult) {
    if (type == null) {
      return null;
    }
    final definition = _typeDefinitionAt(type.typeIndex);
    if (type.kind == WasmComponentValueTypeKind.typeIndex &&
        definition?.definedValue?.kind ==
            WasmComponentDefinedValueTypeKind.result) {
      final tag = _expectI32(flatResult, 'canonical result');
      if (tag == 0) {
        return WasmComponentValueData(
          kind: WasmComponentValueDataKind.result,
          rawBytes: Uint8List(0),
          index: 0,
          label: 'ok',
          isOk: true,
        );
      }
      if (tag == 1) {
        return WasmComponentValueData(
          kind: WasmComponentValueDataKind.result,
          rawBytes: Uint8List(0),
          index: 1,
          label: 'error',
          isOk: false,
        );
      }
      throw WASIPreview2ComponentExecutionException(
        'Invalid canonical result discriminant $tag.',
      );
    }
    return flatResult;
  }

  _CoreInstance _instantiateCoreInstance(WasmComponentCoreInstance instance) {
    switch (instance.kind) {
      case WasmComponentCoreInstanceKind.instantiate:
        final moduleIndex = instance.moduleIndex;
        if (moduleIndex == null ||
            moduleIndex < 0 ||
            moduleIndex >= _coreModules.length) {
          throw WASIPreview2ComponentExecutionException(
            'Core instance references an unknown module.',
          );
        }
        final runtime = ir_instance.WasmInstance.fromModule(
          _coreModules[moduleIndex],
          imports: _coreImportsFor(
            _coreModules[moduleIndex],
            instance.arguments,
          ),
          features: WasmFeatureSet.layeredDefaults(
            profile: WasmFeatureProfile.full,
          ),
        );
        return _CoreInstance.fromRuntime(runtime, wrapMemory: _wrapMemory);
      case WasmComponentCoreInstanceKind.inlineExports:
        return _CoreInstance(
          exports: Map.unmodifiable({
            for (final export in instance.exports)
              export.name: _coreExportForSort(export.sort),
          }),
        );
    }
  }

  ir_imports.WasmImports _coreImportsFor(
    ir_module.WasmModule module,
    List<WasmComponentCoreInstantiationArgument> arguments,
  ) {
    final argumentInstances = <String, _CoreInstance>{};
    for (final argument in arguments) {
      final instanceIndex = argument.instanceIndex;
      if (instanceIndex < 0 || instanceIndex >= _coreInstances.length) {
        throw WASIPreview2ComponentExecutionException(
          'Core instantiation argument `${argument.name}` references an unknown instance.',
        );
      }
      argumentInstances[argument.name] = _coreInstances[instanceIndex];
    }

    final functions = <String, ir_imports.WasmHostFunction>{};
    final asyncFunctions = <String, ir_imports.WasmAsyncHostFunction>{};
    final memories = <String, ir_memory.WasmMemory>{};
    final tables = <String, ir_table.WasmTable>{};
    final globals = <String, Object?>{};
    final globalBindings = <String, RuntimeGlobal>{};
    final tags = <String, ir_imports.WasmTagImport>{};

    for (final import in module.imports) {
      final instance = argumentInstances[import.module];
      final export = instance?.exports[import.name];
      if (export == null) {
        throw WASIPreview2ComponentExecutionException(
          'Missing core import `${import.module}::${import.name}`.',
        );
      }
      final key = ir_imports.WasmImports.key(import.module, import.name);
      switch (import.kind) {
        case ir_module.WasmImportKind.function:
        case ir_module.WasmImportKind.exactFunction:
          final function = export.requireFunction(import.name);
          functions[key] = function.invokeSync;
          asyncFunctions[key] = function.invoke;
        case ir_module.WasmImportKind.memory:
          memories[key] = export.requireMemory(import.name).runtime;
        case ir_module.WasmImportKind.table:
          tables[key] = export.requireTable(import.name);
        case ir_module.WasmImportKind.global:
          final global = export.requireGlobal(import.name);
          globals[key] = global.value.toExternal();
          globalBindings[key] = global;
        case ir_module.WasmImportKind.tag:
          tags[key] = export.requireTag(import.name);
      }
    }

    return ir_imports.WasmImports(
      functions: functions,
      asyncFunctions: asyncFunctions,
      memories: memories,
      tables: tables,
      globals: globals,
      globalBindings: globalBindings,
      tags: tags,
    );
  }

  _CoreExport _coreExportForSort(WasmComponentCoreSortIndex sort) {
    return switch (sort.kind) {
      WasmComponentCoreSortKind.function => _CoreExport.function(
        _coreFunctions[sort.index],
      ),
      WasmComponentCoreSortKind.memory => _CoreExport.memory(
        _coreMemories[sort.index],
      ),
      WasmComponentCoreSortKind.table => _CoreExport.table(
        _coreTables[sort.index],
      ),
      WasmComponentCoreSortKind.global => _CoreExport.global(
        _coreGlobals[sort.index],
      ),
      WasmComponentCoreSortKind.tag => _CoreExport.tag(_coreTags[sort.index]),
      WasmComponentCoreSortKind.type ||
      WasmComponentCoreSortKind.module ||
      WasmComponentCoreSortKind.instance =>
        throw WASIPreview2ComponentExecutionException(
          'Unsupported inline core export sort `${sort.kind.name}`.',
        ),
    };
  }

  _ComponentInstance _instantiateComponentInstance(
    WasmComponentInstance instance,
  ) {
    switch (instance.kind) {
      case WasmComponentInstanceKind.inlineExports:
        return _ComponentInstance(
          functions: Map.unmodifiable({
            for (final export in instance.exports)
              if (export.sort.kind == WasmComponentSortKind.function)
                _externName(export.name, export.versionSuffix):
                    _componentFunctions[export.sort.index],
          }),
        );
      case WasmComponentInstanceKind.instantiate:
        throw const WASIPreview2ComponentExecutionException(
          'Nested component instantiation is not executable in the Preview2 runner yet.',
        );
    }
  }

  void _addExport(WasmComponentExport export) {
    final name = _externName(export.name, export.versionSuffix);
    switch (export.sort.kind) {
      case WasmComponentSortKind.function:
        _exportedFunctions[name] = _componentFunctions[export.sort.index];
      case WasmComponentSortKind.instance:
        _exportedInstances[name] = _componentInstances[export.sort.index];
      case WasmComponentSortKind.core:
      case WasmComponentSortKind.value:
      case WasmComponentSortKind.componentType:
      case WasmComponentSortKind.component:
        break;
    }
  }

  void _runStart(WasmComponentStart start) {
    if (start.arguments.isNotEmpty || start.resultCount != 0) {
      throw const WASIPreview2ComponentExecutionException(
        'Component starts with values are not executable in the Preview2 runner yet.',
      );
    }
    final function = _componentFunctions[start.functionIndex];
    final result = function.invokeSync(const <Object?>[]);
    if (result is Future) {
      throw const WASIPreview2ComponentExecutionException(
        'Async component start is not executable in the Preview2 runner yet.',
      );
    }
  }

  _ComponentFunction _findCommandRun() {
    for (final entry in _exportedInstances.entries) {
      if (_isPreview2RunExport(entry.key)) {
        final run = entry.value.functions['run'];
        if (run != null) {
          return run;
        }
      }
    }
    for (final entry in _exportedFunctions.entries) {
      if (_isPreview2RunExport(entry.key)) {
        return entry.value;
      }
    }
    throw const WASIPreview2ComponentExecutionException(
      'Component does not export wasi:cli/run@0.2.x.',
    );
  }

  bool _isPreview2RunExport(String name) {
    return RegExp(r'^wasi:cli/run@0\.2\.\d+$').hasMatch(name);
  }

  native_memory.Memory _wrapMemory(ir_memory.WasmMemory memory) {
    return _memoryWrappers.putIfAbsent(
      memory,
      () => native_memory.Memory.fromRuntime(memory),
    );
  }
}

final class _CoreFunction {
  const _CoreFunction({
    required this.name,
    required this.invoke,
    required this.invokeSync,
  });

  final String name;
  final FutureOr<Object?> Function(List<Object?> args) invoke;
  final Object? Function(List<Object?> args) invokeSync;
}

final class _CoreMemory {
  const _CoreMemory({required this.runtime, required this.memory});

  final ir_memory.WasmMemory runtime;
  final native_memory.Memory memory;
}

final class _CoreInstance {
  const _CoreInstance({required this.exports});

  factory _CoreInstance.fromRuntime(
    ir_instance.WasmInstance runtime, {
    required native_memory.Memory Function(ir_memory.WasmMemory memory)
    wrapMemory,
  }) {
    return _CoreInstance(
      exports: Map.unmodifiable({
        for (final name in runtime.exportedFunctions)
          name: _CoreExport.function(
            _CoreFunction(
              name: name,
              invoke: (args) => runtime.invokeAsync(name, args),
              invokeSync: (args) => runtime.invoke(name, args),
            ),
          ),
        for (final name in runtime.exportedMemories)
          name: _CoreExport.memory(
            _CoreMemory(
              runtime: runtime.exportedMemory(name),
              memory: wrapMemory(runtime.exportedMemory(name)),
            ),
          ),
        for (final name in runtime.exportedTables)
          name: _CoreExport.table(runtime.exportedTable(name)),
        for (final name in runtime.exportedGlobals)
          name: _CoreExport.global(runtime.exportedGlobalBinding(name)),
        for (final name in runtime.exportedTags)
          name: _CoreExport.tag(runtime.exportedTagImport(name)),
      }),
    );
  }

  final Map<String, _CoreExport> exports;
}

enum _CoreExportKind { function, memory, table, global, tag }

final class _CoreExport {
  const _CoreExport.function(this.function)
    : kind = _CoreExportKind.function,
      memory = null,
      table = null,
      global = null,
      tag = null;

  const _CoreExport.memory(this.memory)
    : kind = _CoreExportKind.memory,
      function = null,
      table = null,
      global = null,
      tag = null;

  const _CoreExport.table(this.table)
    : kind = _CoreExportKind.table,
      function = null,
      memory = null,
      global = null,
      tag = null;

  const _CoreExport.global(this.global)
    : kind = _CoreExportKind.global,
      function = null,
      memory = null,
      table = null,
      tag = null;

  const _CoreExport.tag(this.tag)
    : kind = _CoreExportKind.tag,
      function = null,
      memory = null,
      table = null,
      global = null;

  final _CoreExportKind kind;
  final _CoreFunction? function;
  final _CoreMemory? memory;
  final ir_table.WasmTable? table;
  final RuntimeGlobal? global;
  final ir_imports.WasmTagImport? tag;

  _CoreFunction requireFunction(String name) {
    final value = function;
    if (value == null) {
      throw WASIPreview2ComponentExecutionException(
        'Core export `$name` is not a function.',
      );
    }
    return value;
  }

  _CoreMemory requireMemory(String name) {
    final value = memory;
    if (value == null) {
      throw WASIPreview2ComponentExecutionException(
        'Core export `$name` is not a memory.',
      );
    }
    return value;
  }

  ir_table.WasmTable requireTable(String name) {
    final value = table;
    if (value == null) {
      throw WASIPreview2ComponentExecutionException(
        'Core export `$name` is not a table.',
      );
    }
    return value;
  }

  RuntimeGlobal requireGlobal(String name) {
    final value = global;
    if (value == null) {
      throw WASIPreview2ComponentExecutionException(
        'Core export `$name` is not a global.',
      );
    }
    return value;
  }

  ir_imports.WasmTagImport requireTag(String name) {
    final value = tag;
    if (value == null) {
      throw WASIPreview2ComponentExecutionException(
        'Core export `$name` is not a tag.',
      );
    }
    return value;
  }
}

final class _ComponentFunction {
  const _ComponentFunction({required this.name, required this.invoke});

  final String name;
  final FutureOr<Object?> Function(List<Object?> args) invoke;

  Object? invokeSync(List<Object?> args) {
    final result = invoke(args);
    if (result is Future) {
      throw WASIPreview2ComponentExecutionException(
        'Component function `$name` is async-only.',
      );
    }
    return result;
  }
}

final class _ComponentInstance {
  const _ComponentInstance({required this.functions});

  final Map<String, _ComponentFunction> functions;
}

Object? _coreHostResult(List<Object?> flatResults) {
  if (flatResults.isEmpty) {
    return null;
  }
  if (flatResults.length == 1) {
    return flatResults.single;
  }
  return flatResults;
}

int _runResultExitCode(Object? value) {
  if (value == null) {
    return 0;
  }
  if (value is WasmComponentValueData &&
      value.kind == WasmComponentValueDataKind.result) {
    return _componentResultIsOk(value) ? 0 : 1;
  }
  if (value is int) {
    return value == 0 ? 0 : 1;
  }
  throw WASIPreview2ComponentExecutionException(
    'Unsupported wasi:cli/run result `${value.runtimeType}`.',
  );
}

bool _componentResultIsOk(WasmComponentValueData value) {
  bool? selected;
  void select(bool next, String source) {
    if (selected != null && selected != next) {
      throw StateError('Conflicting WASI CLI result $source.');
    }
    selected = next;
  }

  final isOk = value.isOk;
  if (isOk != null) {
    select(isOk, 'isOk');
  }
  final index = value.index;
  if (index != null) {
    if (index == 0) {
      select(true, 'index');
    } else if (index == 1) {
      select(false, 'index');
    } else {
      throw StateError('Invalid WASI CLI result index $index.');
    }
  }
  final label = value.label;
  if (label != null) {
    if (label == 'ok') {
      select(true, 'label');
    } else if (label == 'error') {
      select(false, 'label');
    } else {
      throw StateError('Invalid WASI CLI result label $label.');
    }
  }
  return selected ?? false;
}

String _externName(String name, String? versionSuffix) {
  if (versionSuffix == null) {
    return name;
  }
  return '$name@$versionSuffix';
}

String _witCallbackKey(String interfaceName, String functionName) {
  final normalized = functionName.replaceFirst(RegExp(r'^\[[^\]]+\]'), '');
  return '$interfaceName.$normalized';
}

String _formatErrors(String header, Iterable<Object> errors) {
  final buffer = StringBuffer(header);
  for (final error in errors) {
    buffer
      ..write('\n- ')
      ..write(error);
  }
  return buffer.toString();
}

int _expectI32(Object? value, String context) {
  if (value is! int) {
    throw WASIPreview2ComponentExecutionException(
      'Expected i32 for $context, got `${value.runtimeType}`.',
    );
  }
  return value.toSigned(32);
}
