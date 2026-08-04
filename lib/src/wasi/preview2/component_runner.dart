import 'dart:async';

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
import '../component/adapter_plan.dart';
import '../component/host.dart';
import '../component/string_memory.dart';
import '../component/subtask.dart';
import '../component/waitable_set.dart';
import '../component/wit_adapter.dart';
import 'cli.dart';
import 'component_host.dart';
import 'http.dart';
import '../preview3/cli.dart';
import '../preview3/component_host.dart';
import '../preview3/http.dart';

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
    final runtime = WASIComponentNativeRuntime.preview2(
      component: component,
      host: host,
    );
    final exitCode = await runtime.runCommand();
    return WASIPreview2CommandResult(exitCode: exitCode);
  }
}

/// Executes WASI Preview2 `wasi:http/proxy` components on the native backend.
final class WASIPreview2ProxyRunner {
  /// Creates a proxy runner over [host].
  const WASIPreview2ProxyRunner(this.host);

  /// Preview2 host used for standard WASI imports and canonical state.
  final WASIPreview2ComponentHost host;

  /// Instantiates [component] and invokes its exported incoming handler for
  /// [request].
  Future<WASIPreview2HttpResponseOutparam> handle(
    WasmComponent component,
    WASIPreview2HttpIncomingRequest request,
  ) {
    return WASIComponentNativeRuntime.preview2(
      component: component,
      host: host,
    ).handleProxy(request);
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

/// Native Component Model executor shared by fixed-version WASI runners.
final class WASIComponentNativeRuntime {
  /// Creates a native executor for a Preview2 [host].
  WASIComponentNativeRuntime.preview2({
    required this.component,
    required WASIPreview2ComponentHost host,
  }) : _preview2Host = host,
       _preview3Host = null;

  /// Creates a native executor for a Preview3 [host].
  WASIComponentNativeRuntime.preview3({
    required this.component,
    required WASIPreview3ComponentHost host,
  }) : _preview2Host = null,
       _preview3Host = host;

  /// Component decoded for this execution.
  final WasmComponent component;
  final WASIPreview2ComponentHost? _preview2Host;
  final WASIPreview3ComponentHost? _preview3Host;

  WASIComponentHost get _componentHost =>
      _preview2Host?.componentHost ?? _preview3Host!.componentHost;

  Map<String, WASIComponentWitAdapterCallback> get _standardImports =>
      _preview2Host?.standardImports ?? _preview3Host!.standardImports;

  final List<ir_module.WasmModule> _coreModules = <ir_module.WasmModule>[];
  final List<_CoreFunction> _coreFunctions = <_CoreFunction>[];
  final List<_CoreMemory> _coreMemories = <_CoreMemory>[];
  final List<ir_table.WasmTable> _coreTables = <ir_table.WasmTable>[];
  final List<RuntimeGlobal> _coreGlobals = <RuntimeGlobal>[];
  final List<ir_imports.WasmTagImport> _coreTags = <ir_imports.WasmTagImport>[];
  final List<_CoreInstance> _coreInstances = <_CoreInstance>[];
  final List<_ComponentFunction> _componentFunctions = <_ComponentFunction>[];
  final List<_ComponentInstance> _componentInstances = <_ComponentInstance>[];
  final List<WasmComponent> _components = <WasmComponent>[];
  final List<WasmComponentTypeDefinition> _visibleTypes =
      <WasmComponentTypeDefinition>[];
  final List<String?> _visibleResourceTypeNames = <String?>[];
  final Map<String, _ComponentFunction> _exportedFunctions =
      <String, _ComponentFunction>{};
  final Map<String, _ComponentInstance> _exportedInstances =
      <String, _ComponentInstance>{};
  final Map<ir_memory.WasmMemory, native_memory.Memory> _memoryWrappers =
      <ir_memory.WasmMemory, native_memory.Memory>{};
  final Map<int, WASIComponentCanonicalAdapterCallback> _adapterCoreCallbacks =
      <int, WASIComponentCanonicalAdapterCallback>{};
  final Map<int, WASIComponentCanonicalAdapterCallback>
  _synchronousAdapterCoreCallbacks =
      <int, WASIComponentCanonicalAdapterCallback>{};
  final Map<int, WASIComponentCanonicalAdapterCallback>
  _adapterComponentCallbacks = <int, WASIComponentCanonicalAdapterCallback>{};
  final Map<int, WASIComponentCanonicalAdapterCallback>
  _synchronousAdapterComponentCallbacks =
      <int, WASIComponentCanonicalAdapterCallback>{};

  late final WASIComponentHostBinding _binding;
  late final WASIComponentCanonicalAdapterProgram _adapterProgram;
  late final WASIComponentCanonicalAdapterProgram _synchronousAdapterProgram;
  var _decodedTypeDefinitionCount = 0;
  var _initialized = false;

  /// Executes the Preview2 command export.
  Future<int> runCommand() => _componentHost.table.runScoped(() async {
    try {
      _initialize();
      final run = _findCommandRun();
      final result = await run.invoke(const <Object?>[]);
      return _runResultExitCode(result);
    } on WASIPreview2Exit catch (exit) {
      return exit.statusCode;
    }
  });

  /// Executes the Preview3 async command export.
  Future<int> runPreview3Command() => _componentHost.table.runScoped(() async {
    try {
      _initialize();
      final run = _findPreview3CommandRun();
      final result = await run.invoke(const <Object?>[]);
      return _runResultExitCode(result);
    } on WASIPreview3Exit catch (exit) {
      return exit.statusCode;
    } on WASIPreview2Exit catch (exit) {
      return exit.statusCode;
    }
  });

  /// Executes a Preview2 HTTP proxy handler export.
  Future<WASIPreview2HttpResponseOutparam> handleProxy(
    WASIPreview2HttpIncomingRequest request,
  ) => _componentHost.table.runScoped(() async {
    final host = _preview2Host;
    if (host == null) {
      throw const WASIPreview2ComponentExecutionException(
        'Preview2 HTTP proxy execution requires a Preview2 host.',
      );
    }
    _initialize();
    final responseOutparam = WASIPreview2HttpResponseOutparam();
    final requestHandle = host.httpHost.insertIncomingRequest(request);
    final responseOutparamHandle = host.httpHost.insertResponseOutparam(
      responseOutparam,
    );
    final result = await _findProxyHandler().invoke(<Object?>[
      requestHandle,
      responseOutparamHandle,
    ]);
    if (result != null) {
      throw WASIPreview2ComponentExecutionException(
        'wasi:http/incoming-handler.handle returned an unexpected value.',
      );
    }
    if (responseOutparam.response == null) {
      throw const WASIPreview2ComponentExecutionException(
        'wasi:http/incoming-handler.handle did not set the response outparam.',
      );
    }
    return responseOutparam;
  });

  /// Executes a Preview3 HTTP service handler export.
  Future<WASIPreview3HttpResult<WASIPreview3HttpResponse>>
  handlePreview3Service(WASIPreview3HttpRequest request) =>
      _componentHost.table.runScoped(() async {
        try {
          final host = _preview3Host;
          if (host == null) {
            throw const WASIPreview2ComponentExecutionException(
              'Preview3 HTTP service execution requires a Preview3 host.',
            );
          }
          _initialize();
          final requestHandle = host.httpHost.insertRequest(request);
          final result = await _findPreview3HttpHandler().invoke(<Object?>[
            requestHandle,
          ]);
          if (result is! WasmComponentValueData ||
              result.kind != WasmComponentValueDataKind.result) {
            throw WASIPreview2ComponentExecutionException(
              'wasi:http/handler.handle returned an invalid result.',
            );
          }
          if (!_componentResultIsOk(result)) {
            return WASIPreview3HttpResult<WASIPreview3HttpResponse>.error(
              _preview3HttpErrorCode(result.payload),
            );
          }
          return WASIPreview3HttpResult<WASIPreview3HttpResponse>.ok(
            host.httpHost.takeResponse(
              _componentResourceHandle(result.payload),
              retainResourceScope: true,
            ),
          );
        } on WASIPreview3Exit {
          return const WASIPreview3HttpResult<WASIPreview3HttpResponse>.error(
            'internal-error',
          );
        } on WASIPreview2Exit {
          return const WASIPreview3HttpResult<WASIPreview3HttpResponse>.error(
            'internal-error',
          );
        }
      });

  void _initialize() {
    if (_initialized) {
      return;
    }
    final plan = _checkComponent();
    _initializeAdapterCallbacks(plan.adapterPlans);
    _adapterProgram = plan.bindAdapters(
      coreFunctions: _adapterCoreCallbacks,
      componentFunctions: _adapterComponentCallbacks,
    );
    _synchronousAdapterProgram = plan.bindAdapters(
      coreFunctions: _synchronousAdapterCoreCallbacks,
      componentFunctions: _synchronousAdapterComponentCallbacks,
    );
    _binding = plan.bind(
      coreFunctions: _adapterCoreCallbacks,
      componentFunctions: _adapterComponentCallbacks,
      maxBufferedElementsForStream: _preview3Host == null ? null : (_) => 0,
    );
    _processDefinitions();
    _initialized = true;
  }

  WASIComponentHostBindingPlan _checkComponent() {
    final validationErrors = component.validate();
    if (validationErrors.isNotEmpty) {
      throw WASIPreview2ComponentExecutionException(
        _formatErrors(
          'wasd-preview2-runner validation failed',
          validationErrors,
        ),
      );
    }
    final plan =
        _preview2Host?.prepareComponent(component) ??
        _preview3Host!.prepareComponent(component);
    if (plan.canBindWithAdapters) {
      return plan.componentPlan;
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

  void _initializeAdapterCallbacks(
    List<WASIComponentCanonicalAdapterPlan> plans,
  ) {
    for (final plan in plans) {
      switch (plan.kind) {
        case WasmComponentCanonicalKind.lift:
          final index = plan.definition.coreFunctionIndex;
          if (index != null) {
            _adapterCoreCallbacks[index] = (args) {
              if (index < 0 || index >= _coreFunctions.length) {
                throw WASIPreview2ComponentExecutionException(
                  'Canonical lift references unavailable core function $index.',
                );
              }
              return _coreFunctions[index].invoke(args);
            };
            _synchronousAdapterCoreCallbacks[index] = (args) {
              if (index < 0 || index >= _coreFunctions.length) {
                throw WASIPreview2ComponentExecutionException(
                  'Canonical lift references unavailable core function $index.',
                );
              }
              return _coreFunctions[index].invokeSynchronously(args);
            };
          }
          final postReturnIndex = plan.postReturnIndex;
          if (postReturnIndex != null) {
            _adapterCoreCallbacks[postReturnIndex] = (args) {
              if (postReturnIndex < 0 ||
                  postReturnIndex >= _coreFunctions.length) {
                throw WASIPreview2ComponentExecutionException(
                  'Canonical lift references unavailable post-return core '
                  'function $postReturnIndex.',
                );
              }
              return _coreFunctions[postReturnIndex].invoke(args);
            };
            _synchronousAdapterCoreCallbacks[postReturnIndex] = (args) {
              if (postReturnIndex < 0 ||
                  postReturnIndex >= _coreFunctions.length) {
                throw WASIPreview2ComponentExecutionException(
                  'Canonical lift references unavailable post-return core '
                  'function $postReturnIndex.',
                );
              }
              return _coreFunctions[postReturnIndex].invokeSynchronously(args);
            };
          }
        case WasmComponentCanonicalKind.lower:
          final index = plan.definition.functionIndex;
          if (index != null) {
            _adapterComponentCallbacks[index] = (args) {
              if (index < 0 || index >= _componentFunctions.length) {
                throw WASIPreview2ComponentExecutionException(
                  'Canonical lower references unavailable component function $index.',
                );
              }
              return _componentFunctions[index].invoke(args);
            };
            _synchronousAdapterComponentCallbacks[index] = (args) {
              if (index < 0 || index >= _componentFunctions.length) {
                throw WASIPreview2ComponentExecutionException(
                  'Canonical lower references unavailable component function $index.',
                );
              }
              return _componentFunctions[index].invokeSynchronously(args);
            };
          }
        default:
          break;
      }
    }
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
        case WasmComponentDefinitionKind.component:
          _components.add(component.components[event.index]);
        case WasmComponentDefinitionKind.coreType:
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
    _visibleResourceTypeNames.addAll(
      List<String?>.filled(count - _decodedTypeDefinitionCount, null),
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
    final types = <String, WasmComponentTypeDefinition>{};
    final resourceTypeNames = <String, String>{};
    final localTypes = <WasmComponentTypeDefinition>[];
    final localResourceTypeNames = <String?>[];
    for (final declaration in instanceType.declarations) {
      final export = declaration.export;
      switch (declaration.kind) {
        case WasmComponentTypeDeclarationKind.type:
          final type = declaration.type;
          if (type != null) {
            localTypes.add(type);
            localResourceTypeNames.add(null);
          }
        case WasmComponentTypeDeclarationKind.export:
          if (export == null) {
            continue;
          }
          final name = _externName(export.name, export.versionSuffix);
          if (export.descriptor.kind == WasmComponentExternKind.function) {
            functions[name] = _hostComponentFunction(
              _witCallbackKey(interfaceName, name),
            );
            continue;
          }
          final type = _typeExportDefinition(export.descriptor, localTypes);
          if (type != null) {
            types[name] = type;
            final resourceTypeName = switch (export.descriptor.boundKind) {
              WasmComponentExternBoundKind.subtypeResource =>
                _standardResourceTypeName(interfaceName, name),
              WasmComponentExternBoundKind.equality =>
                localResourceTypeNames[export.descriptor.typeIndex!],
              _ => null,
            };
            if (resourceTypeName != null) {
              resourceTypeNames[name] = resourceTypeName;
            }
            localTypes.add(type);
            localResourceTypeNames.add(resourceTypeName);
          }
        case WasmComponentTypeDeclarationKind.import:
        case WasmComponentTypeDeclarationKind.coreType:
          break;
        case WasmComponentTypeDeclarationKind.alias:
          final alias = declaration.alias;
          final index = alias?.target.index;
          if (alias?.sort.kind != WasmComponentSortKind.componentType ||
              alias?.target.kind != WasmComponentAliasTargetKind.outer ||
              index == null ||
              index < 0 ||
              index >= _visibleTypes.length) {
            throw WASIPreview2ComponentExecutionException(
              'Unsupported type alias in component import `$interfaceName`.',
            );
          }
          localTypes.add(_visibleTypes[index]);
          localResourceTypeNames.add(_visibleResourceTypeNames[index]);
      }
    }
    return _ComponentInstance(
      functions: Map.unmodifiable(functions),
      types: Map.unmodifiable(types),
      resourceTypeNames: Map.unmodifiable(resourceTypeNames),
    );
  }

  WasmComponentTypeDefinition? _typeExportDefinition(
    WasmComponentExternDescriptor descriptor,
    List<WasmComponentTypeDefinition> localTypes,
  ) {
    if (descriptor.kind != WasmComponentExternKind.componentType) {
      return null;
    }
    if (descriptor.boundKind == WasmComponentExternBoundKind.subtypeResource) {
      return const WasmComponentTypeDefinition(
        kind: WasmComponentTypeKind.resource,
        resource: WasmComponentResourceType.abstract(),
      );
    }
    final index = descriptor.typeIndex;
    if (descriptor.boundKind != WasmComponentExternBoundKind.equality ||
        index == null ||
        index < 0 ||
        index >= localTypes.length) {
      return null;
    }
    return localTypes[index];
  }

  _ComponentFunction _hostComponentFunction(String key) {
    var resolvedKey = key;
    var callback = _standardImports[resolvedKey];
    if (callback == null) {
      final separator = key.lastIndexOf('.');
      if (separator >= 0) {
        final escapedKey =
            '${key.substring(0, separator + 1)}%${key.substring(separator + 1)}';
        final escapedCallback = _standardImports[escapedKey];
        if (escapedCallback != null) {
          resolvedKey = escapedKey;
          callback = escapedCallback;
        }
      }
    }
    if (callback == null) {
      throw WASIPreview2ComponentExecutionException(
        'Missing WASI Preview2 import callback `$key`.',
      );
    }
    return _ComponentFunction(name: resolvedKey, invoke: callback);
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
      case WasmComponentSortKind.componentType:
        final type = instance.types[name];
        if (type == null) {
          throw WASIPreview2ComponentExecutionException(
            'Component type export `$name` not found; available exports: '
            '${instance.types.keys.join(', ')}.',
          );
        }
        _visibleTypes.add(type);
        _visibleResourceTypeNames.add(instance.resourceTypeNames[name]);
      case WasmComponentSortKind.instance:
      case WasmComponentSortKind.value:
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
    final isAsync = _canonicalFunctionIsAsync(definition);
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
        _coreFunctions.add(
          _CoreFunction(
            name: 'canonical[$canonicalIndex].lower',
            invoke: isAsync
                ? (args) => _invokeAsyncLower(canonicalIndex, definition, args)
                : (args) async => _coreHostResult(
                    await _adapterProgram.invokeLoweredCoreAsync(
                      canonicalIndex,
                      args,
                      memory: _canonicalMemory(definition),
                      realloc: _canonicalRealloc(definition),
                    ),
                  ),
            invokeSync: isAsync
                ? (args) => _invokeAsyncLower(canonicalIndex, definition, args)
                : (args) => _coreHostResult(
                    _synchronousAdapterProgram.invokeLoweredCore(
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
        _componentFunctions.add(
          _ComponentFunction(
            name: 'canonical[$canonicalIndex].lift',
            invoke: isAsync
                ? (args) => _invokeAsyncLift(canonicalIndex, definition, args)
                : (args) => _adapterProgram.invokeLiftedCoreAsync(
                    canonicalIndex,
                    args,
                    memory: _canonicalMemory(definition),
                    realloc: _canonicalRealloc(definition),
                  ),
            invokeSync: isAsync
                ? (_) => throw WASIPreview2ComponentExecutionException(
                    'Canonical async lift $canonicalIndex cannot be invoked synchronously.',
                  )
                : (args) => _synchronousAdapterProgram.invokeLiftedCore(
                    canonicalIndex,
                    args,
                    memory: _canonicalMemory(definition),
                    realloc: _canonicalRealloc(definition),
                  ),
          ),
        );
      case WasmComponentCanonicalKind.resourceNew:
      case WasmComponentCanonicalKind.resourceRep:
        _coreFunctions.add(
          _CoreFunction(
            name: 'canonical[$canonicalIndex].${definition.kind.name}',
            invoke: (args) =>
                _binding.program.invokeAsync(canonicalIndex, args),
            invokeSync: (args) => _binding.program.invoke(canonicalIndex, args),
          ),
        );
      case WasmComponentCanonicalKind.resourceDrop:
        final typeIndex = definition.typeIndex;
        final resourceTypeName =
            typeIndex == null ||
                typeIndex < 0 ||
                typeIndex >= _visibleResourceTypeNames.length
            ? null
            : _visibleResourceTypeNames[typeIndex];
        if (resourceTypeName == null) {
          _coreFunctions.add(
            _CoreFunction(
              name: 'canonical[$canonicalIndex].resourceDrop',
              invoke: (args) =>
                  _binding.program.invokeAsync(canonicalIndex, args),
              invokeSync: (args) =>
                  _binding.program.invoke(canonicalIndex, args),
            ),
          );
          break;
        }
        Object? dropImportedResource(List<Object?> args) {
          if (args.length != 1 || args.single is! int) {
            throw WASIPreview2ComponentExecutionException(
              'Canonical resource.drop $canonicalIndex expected one handle.',
            );
          }
          _componentHost.table.dropNamed(resourceTypeName, args.single as int);
          return null;
        }

        _coreFunctions.add(
          _CoreFunction(
            name: 'canonical[$canonicalIndex].resourceDrop',
            invoke: dropImportedResource,
            invokeSync: dropImportedResource,
          ),
        );
      case WasmComponentCanonicalKind.backpressureInc:
      case WasmComponentCanonicalKind.backpressureDec:
      case WasmComponentCanonicalKind.taskReturn:
      case WasmComponentCanonicalKind.taskCancel:
      case WasmComponentCanonicalKind.contextGet:
      case WasmComponentCanonicalKind.contextSet:
      case WasmComponentCanonicalKind.threadYield:
      case WasmComponentCanonicalKind.subtaskCancel:
      case WasmComponentCanonicalKind.subtaskDrop:
      case WasmComponentCanonicalKind.streamNew:
      case WasmComponentCanonicalKind.streamRead:
      case WasmComponentCanonicalKind.streamWrite:
      case WasmComponentCanonicalKind.streamCancelRead:
      case WasmComponentCanonicalKind.streamCancelWrite:
      case WasmComponentCanonicalKind.streamDropReadable:
      case WasmComponentCanonicalKind.streamDropWritable:
      case WasmComponentCanonicalKind.futureNew:
      case WasmComponentCanonicalKind.futureRead:
      case WasmComponentCanonicalKind.futureWrite:
      case WasmComponentCanonicalKind.futureCancelRead:
      case WasmComponentCanonicalKind.futureCancelWrite:
      case WasmComponentCanonicalKind.futureDropReadable:
      case WasmComponentCanonicalKind.futureDropWritable:
      case WasmComponentCanonicalKind.errorContextNew:
      case WasmComponentCanonicalKind.errorContextDebugMessage:
      case WasmComponentCanonicalKind.errorContextDrop:
      case WasmComponentCanonicalKind.waitableSetNew:
      case WasmComponentCanonicalKind.waitableSetWait:
      case WasmComponentCanonicalKind.waitableSetPoll:
      case WasmComponentCanonicalKind.waitableSetDrop:
      case WasmComponentCanonicalKind.waitableJoin:
      case WasmComponentCanonicalKind.threadIndex:
      case WasmComponentCanonicalKind.threadAvailableParallelism:
        final canonicalMemory = _canonicalMemory(definition);
        final memory = definition.kind == WasmComponentCanonicalKind.taskReturn
            ? _taskReturnUsesResultPointer(definition)
                  ? canonicalMemory
                  : null
            : canonicalMemory;
        final realloc = _canonicalRealloc(definition);
        // Async lifts drive their callback loop through the immediate/event
        // paths. Synchronous callers use the Future-returning paths instead.
        FutureOr<Object?> invoke(List<Object?> args) {
          if (memory == null) {
            return isAsync
                ? _binding.program.invoke(canonicalIndex, args)
                : _binding.program.invokeAsync(canonicalIndex, args);
          }
          return isAsync
              ? _binding.program.invokeWithMemoryEvent(
                  canonicalIndex,
                  memory,
                  args,
                  realloc: realloc,
                )
              : _binding.program.invokeWithMemoryAsync(
                  canonicalIndex,
                  memory,
                  args,
                  realloc: realloc,
                );
        }

        Object? invokeSync(List<Object?> args) {
          if (memory == null) {
            return _binding.program.invoke(canonicalIndex, args);
          }
          return _binding.program.invokeWithMemoryEvent(
            canonicalIndex,
            memory,
            args,
            realloc: realloc,
          );
        }

        _coreFunctions.add(
          _CoreFunction(
            name: 'canonical[$canonicalIndex].${definition.kind.name}',
            invoke: invoke,
            invokeSync: isAsync ? invokeSync : null,
          ),
        );
      case WasmComponentCanonicalKind.threadNewIndirect:
      case WasmComponentCanonicalKind.threadResumeLater:
      case WasmComponentCanonicalKind.threadSuspend:
      case WasmComponentCanonicalKind.threadSuspendThenResume:
      case WasmComponentCanonicalKind.threadYieldThenResume:
      case WasmComponentCanonicalKind.threadSuspendThenPromote:
      case WasmComponentCanonicalKind.threadYieldThenPromote:
      case WasmComponentCanonicalKind.threadSpawnRef:
      case WasmComponentCanonicalKind.threadSpawnIndirect:
        throw WASIPreview2ComponentExecutionException(
          'Canonical $canonicalIndex uses unsupported '
          '${definition.kind.name}.',
        );
    }
  }

  Future<Object?> _invokeAsyncLift(
    int canonicalIndex,
    WasmComponentCanonicalDefinition definition,
    List<Object?> args,
  ) async {
    final callbackIndex = _canonicalOptionIndex(
      definition,
      WasmComponentCanonicalOptionKind.callback,
    );
    if (callbackIndex == null) {
      throw WASIPreview2ComponentExecutionException(
        'Canonical async lift $canonicalIndex requires the Preview3 callback ABI.',
      );
    }
    if (callbackIndex < 0 || callbackIndex >= _coreFunctions.length) {
      throw WASIPreview2ComponentExecutionException(
        'Canonical async lift $canonicalIndex references unknown callback $callbackIndex.',
      );
    }
    final coreFunctionIndex = definition.coreFunctionIndex!;
    final coreFunction = _coreFunctions[coreFunctionIndex];
    final callback = _coreFunctions[callbackIndex];
    final canonicalHost = _componentHost.canonicalHost;
    final task = canonicalHost.taskHost.createTask(
      name: 'canonical[$canonicalIndex].lift',
    );
    final thread = canonicalHost.threadHost.currentThread;

    return canonicalHost.threadHost.runWithThreadAsync(thread, () {
      return canonicalHost.taskHost.runWithTaskAsync(task, () async {
        final entered = await task.enter(canonicalHost.asyncHost.backpressure);
        if (!entered) {
          return null;
        }
        final coreArgs = _adapterProgram.prepareAsyncLiftCoreArgs(
          canonicalIndex,
          args,
          memory: _canonicalMemory(definition),
          realloc: _canonicalRealloc(definition),
        );
        var packed = _asyncCallbackResult(
          await coreFunction.invoke(List<Object?>.unmodifiable(coreArgs)),
          canonicalIndex,
        );
        while ((packed & 0xf) != 0) {
          final code = packed & 0xf;
          WASIComponentWaitableEvent event;
          switch (code) {
            case 1:
              final yieldStatus = await canonicalHost.threadHost.threadYield(
                cancellable: true,
              );
              event = yieldStatus == 0
                  ? WASIComponentWaitableEvent.none
                  : WASIComponentWaitableEvent.taskCancelled;
            case 2:
              event = await canonicalHost.waitableHost.waitableSetWait(
                packed >>> 4,
                cancellable: true,
              );
            default:
              throw WASIPreview2ComponentExecutionException(
                'Canonical async lift $canonicalIndex returned unsupported callback code $code.',
              );
          }
          packed = _asyncCallbackResult(
            await callback.invoke(<Object?>[
              event.code.value,
              event.payload1,
              event.payload2,
            ]),
            canonicalIndex,
          );
        }
        if (!task.state.isResolved) {
          throw WASIPreview2ComponentExecutionException(
            'Canonical async lift $canonicalIndex exited before task.return.',
          );
        }
        if (!task.hasResult) {
          return _adapterProgram.finishAsyncLiftResult(
            canonicalIndex,
            null,
            memory: _canonicalMemory(definition),
          );
        }
        return _adapterProgram.finishAsyncLiftResult(
          canonicalIndex,
          task.result,
          memory: _canonicalMemory(definition),
        );
      });
    });
  }

  int _invokeAsyncLower(
    int canonicalIndex,
    WasmComponentCanonicalDefinition definition,
    List<Object?> coreArgs,
  ) {
    final canonicalHost = _componentHost.canonicalHost;
    final subtask = WASIComponentSubtask(
      name: 'canonical[$canonicalIndex].lower',
    );
    final task = canonicalHost.taskHost.createTask(
      name: 'canonical[$canonicalIndex].lower',
      subtask: subtask,
    );
    Object? synchronousError;
    StackTrace? synchronousStackTrace;
    var waitingForResult = false;
    final execution = canonicalHost.taskHost.runWithTaskAsync(task, () async {
      try {
        task.markStarted();
        final call = _adapterProgram.startAsyncLowerCore(
          canonicalIndex,
          coreArgs,
          memory: _canonicalMemory(definition),
          realloc: _canonicalRealloc(definition),
        );
        final pendingResult = call.result;
        final Object? result;
        if (pendingResult is Future) {
          waitingForResult = true;
          final outcome = await Future.any<({bool cancelled, Object? value})>([
            pendingResult.then((value) => (cancelled: false, value: value)),
            task.whenCancellationRequested.then(
              (_) => (cancelled: true, value: null),
            ),
          ]);
          if (outcome.cancelled) {
            task.deliverCancellation();
            task.cancel();
            return;
          }
          result = outcome.value;
        } else {
          result = pendingResult;
        }
        call.complete(result);
        task.returnResult(result: result, hasResult: definition.result != null);
      } catch (error, stackTrace) {
        if (!waitingForResult) {
          synchronousError = error;
          synchronousStackTrace = stackTrace;
          return;
        }
        if (!subtask.resolved) {
          subtask.markFailed(error, stackTrace);
        }
      }
    });

    final immediateError = synchronousError;
    if (immediateError != null) {
      unawaited(execution);
      Error.throwWithStackTrace(
        immediateError,
        synchronousStackTrace ?? StackTrace.empty,
      );
    }
    if (subtask.resolved) {
      unawaited(execution);
      return subtask.state.code;
    }

    final handle = canonicalHost.subtaskHost.insertSubtask(subtask);
    unawaited(execution);
    return subtask.state.code | (handle << 4);
  }

  int _asyncCallbackResult(Object? value, int canonicalIndex) {
    final scalar = switch (value) {
      int() => value,
      List<Object?>() when value.length == 1 && value.single is int =>
        value.single as int,
      _ => null,
    };
    if (scalar == null) {
      throw WASIPreview2ComponentExecutionException(
        'Canonical async lift $canonicalIndex callback did not return one i32.',
      );
    }
    return scalar.toUnsigned(32);
  }

  native_memory.Memory? _canonicalMemory(
    WasmComponentCanonicalDefinition definition,
  ) {
    final memoryIndex =
        definition.memoryIndex ??
        _canonicalOptionIndex(
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

  bool _taskReturnUsesResultPointer(
    WasmComponentCanonicalDefinition definition,
  ) {
    final resultType = definition.result?.valueType;
    if (resultType == null) {
      return false;
    }
    final layout = componentCanonicalFlatLayout(
      resultType,
      component.componentTypeIndexDefinitions,
      typeScope: component.componentTypeIndexScope,
    );
    if (layout == null) {
      throw WASIPreview2ComponentExecutionException(
        'Canonical task.return result has an unsupported flat layout.',
      );
    }
    return layout.flatLength > 16;
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
      final result = function.invokeSynchronously(<Object?>[
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

  bool _canonicalFunctionIsAsync(WasmComponentCanonicalDefinition definition) =>
      definition.isAsync ||
      definition.options.any(
        (option) => option.kind == WasmComponentCanonicalOptionKind.async,
      );

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
        return _CoreInstance.fromRuntime(
          runtime,
          wrapMemory: _wrapMemory,
          allowSynchronousImports: _preview3Host == null,
        );
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
          final synchronous = function.invokeSync;
          if (function.supportsSyncImport && synchronous != null) {
            functions[key] = synchronous;
          }
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
          types: Map.unmodifiable({
            for (final export in instance.exports)
              if (export.sort.kind == WasmComponentSortKind.componentType)
                _externName(export.name, export.versionSuffix):
                    _visibleTypes[export.sort.index],
          }),
          resourceTypeNames: Map.unmodifiable({
            for (final export in instance.exports)
              if (export.sort.kind == WasmComponentSortKind.componentType &&
                  _visibleResourceTypeNames[export.sort.index] != null)
                _externName(export.name, export.versionSuffix):
                    _visibleResourceTypeNames[export.sort.index]!,
          }),
        );
      case WasmComponentInstanceKind.instantiate:
        final componentIndex = instance.componentIndex;
        if (componentIndex == null ||
            componentIndex < 0 ||
            componentIndex >= _components.length) {
          throw const WASIPreview2ComponentExecutionException(
            'Nested component instance references an unknown component.',
          );
        }
        return _instantiateNestedComponent(
          _components[componentIndex],
          instance.arguments,
        );
    }
  }

  _ComponentInstance _instantiateNestedComponent(
    WasmComponent nested,
    List<WasmComponentInstantiationArgument> arguments,
  ) {
    final suppliedFunctions = <String, _ComponentFunction>{};
    final suppliedInstances = <String, _ComponentInstance>{};
    final suppliedTypes = <String, _NestedComponentType>{};
    for (final argument in arguments) {
      switch (argument.sort.kind) {
        case WasmComponentSortKind.function:
          suppliedFunctions[argument.name] =
              _componentFunctions[argument.sort.index];
        case WasmComponentSortKind.instance:
          suppliedInstances[argument.name] =
              _componentInstances[argument.sort.index];
        case WasmComponentSortKind.componentType:
          suppliedTypes[argument.name] = _NestedComponentType(
            definition: _visibleTypes[argument.sort.index],
            resourceTypeName: _visibleResourceTypeNames[argument.sort.index],
          );
        case WasmComponentSortKind.core:
        case WasmComponentSortKind.value:
        case WasmComponentSortKind.component:
          throw WASIPreview2ComponentExecutionException(
            'Unsupported nested component argument sort '
            '`${argument.sort.kind.name}` for `${argument.name}`.',
          );
      }
    }

    final functions = <_ComponentFunction>[];
    final instances = <_ComponentInstance>[];
    final types = <_NestedComponentType>[];
    final exportedFunctions = <String, _ComponentFunction>{};
    final exportedInstances = <String, _ComponentInstance>{};
    final exportedTypes = <String, WasmComponentTypeDefinition>{};
    final exportedResourceTypeNames = <String, String>{};
    var decodedTypeDefinitionCount = 0;

    for (final event in nested.definitionEvents) {
      switch (event.kind) {
        case WasmComponentDefinitionKind.import:
          final import = nested.imports[event.index];
          final name = _externName(import.name, import.versionSuffix);
          switch (import.descriptor.kind) {
            case WasmComponentExternKind.function:
              final function = suppliedFunctions[name];
              if (function == null) {
                throw WASIPreview2ComponentExecutionException(
                  'Missing nested component function argument `$name`.',
                );
              }
              functions.add(function);
            case WasmComponentExternKind.instance:
              final instance = suppliedInstances[name];
              if (instance == null) {
                throw WASIPreview2ComponentExecutionException(
                  'Missing nested component instance argument `$name`.',
                );
              }
              instances.add(instance);
            case WasmComponentExternKind.componentType:
              final type = suppliedTypes[name];
              if (type == null) {
                throw WASIPreview2ComponentExecutionException(
                  'Missing nested component type argument `$name`.',
                );
              }
              types.add(type);
            case WasmComponentExternKind.coreModule:
            case WasmComponentExternKind.value:
            case WasmComponentExternKind.component:
              throw WASIPreview2ComponentExecutionException(
                'Unsupported nested component import `$name` of kind '
                '`${import.descriptor.kind.name}`.',
              );
          }
        case WasmComponentDefinitionKind.instance:
          final instance = nested.instances[event.index];
          if (instance.kind != WasmComponentInstanceKind.inlineExports) {
            throw const WASIPreview2ComponentExecutionException(
              'Recursive nested component instantiation is not executable yet.',
            );
          }
          instances.add(
            _ComponentInstance(
              functions: Map.unmodifiable({
                for (final export in instance.exports)
                  if (export.sort.kind == WasmComponentSortKind.function)
                    _externName(export.name, export.versionSuffix):
                        functions[export.sort.index],
              }),
              types: const <String, WasmComponentTypeDefinition>{},
              resourceTypeNames: const <String, String>{},
            ),
          );
        case WasmComponentDefinitionKind.alias:
          final alias = nested.aliases[event.index];
          if (alias.target.kind != WasmComponentAliasTargetKind.export ||
              alias.target.instanceIndex == null ||
              alias.target.name == null) {
            throw const WASIPreview2ComponentExecutionException(
              'Unsupported nested component alias.',
            );
          }
          final instance = instances[alias.target.instanceIndex!];
          switch (alias.sort.kind) {
            case WasmComponentSortKind.function:
              final function = instance.functions[alias.target.name!];
              if (function == null) {
                throw WASIPreview2ComponentExecutionException(
                  'Nested component function export '
                  '`${alias.target.name}` not found.',
                );
              }
              functions.add(function);
            case WasmComponentSortKind.componentType:
              final type = instance.types[alias.target.name!];
              if (type == null) {
                throw WASIPreview2ComponentExecutionException(
                  'Nested component type export '
                  '`${alias.target.name}` not found.',
                );
              }
              types.add(
                _NestedComponentType(
                  definition: type,
                  resourceTypeName:
                      instance.resourceTypeNames[alias.target.name!],
                ),
              );
            case WasmComponentSortKind.core:
            case WasmComponentSortKind.value:
            case WasmComponentSortKind.component:
            case WasmComponentSortKind.instance:
              throw const WASIPreview2ComponentExecutionException(
                'Unsupported nested component alias sort.',
              );
          }
        case WasmComponentDefinitionKind.export:
          final export = nested.exports[event.index];
          final name = _externName(export.name, export.versionSuffix);
          switch (export.sort.kind) {
            case WasmComponentSortKind.function:
              exportedFunctions[name] = functions[export.sort.index];
            case WasmComponentSortKind.instance:
              exportedInstances[name] = instances[export.sort.index];
            case WasmComponentSortKind.componentType:
              final type = types[export.sort.index];
              exportedTypes[name] = type.definition;
              final resourceTypeName = type.resourceTypeName;
              if (resourceTypeName != null) {
                exportedResourceTypeNames[name] = resourceTypeName;
              }
              types.add(type);
            case WasmComponentSortKind.core:
            case WasmComponentSortKind.value:
            case WasmComponentSortKind.component:
              break;
          }
        case WasmComponentDefinitionKind.coreType:
        case WasmComponentDefinitionKind.coreModule:
        case WasmComponentDefinitionKind.coreInstance:
        case WasmComponentDefinitionKind.component:
        case WasmComponentDefinitionKind.canonical:
        case WasmComponentDefinitionKind.start:
        case WasmComponentDefinitionKind.value:
          throw WASIPreview2ComponentExecutionException(
            'Unsupported executable definition `${event.kind.name}` in a '
            'nested component.',
          );
        case WasmComponentDefinitionKind.typeCount:
          if (event.index > decodedTypeDefinitionCount) {
            types.addAll(
              nested.typeDefinitions
                  .getRange(decodedTypeDefinitionCount, event.index)
                  .map(
                    (definition) => _NestedComponentType(
                      definition: definition,
                      resourceTypeName: null,
                    ),
                  ),
            );
            decodedTypeDefinitionCount = event.index;
          }
        case WasmComponentDefinitionKind.type:
          break;
      }
    }

    if (exportedInstances.isNotEmpty) {
      throw const WASIPreview2ComponentExecutionException(
        'Nested component instance exports are not executable yet.',
      );
    }
    return _ComponentInstance(
      functions: Map.unmodifiable(exportedFunctions),
      types: Map.unmodifiable(exportedTypes),
      resourceTypeNames: Map.unmodifiable(exportedResourceTypeNames),
    );
  }

  void _addExport(WasmComponentExport export) {
    final name = _externName(export.name, export.versionSuffix);
    switch (export.sort.kind) {
      case WasmComponentSortKind.function:
        final function = _componentFunctions[export.sort.index];
        _exportedFunctions[name] = function;
        _componentFunctions.add(function);
      case WasmComponentSortKind.instance:
        final instance = _componentInstances[export.sort.index];
        _exportedInstances[name] = instance;
        _componentInstances.add(instance);
      case WasmComponentSortKind.componentType:
        _visibleTypes.add(_visibleTypes[export.sort.index]);
        _visibleResourceTypeNames.add(
          _visibleResourceTypeNames[export.sort.index],
        );
      case WasmComponentSortKind.component:
        _components.add(_components[export.sort.index]);
      case WasmComponentSortKind.core:
        _addCoreExportIndex(export.sort);
      case WasmComponentSortKind.value:
        throw WASIPreview2ComponentExecutionException(
          'Component value export `$name` is not executable yet.',
        );
    }
  }

  void _addCoreExportIndex(WasmComponentSortIndex sort) {
    switch (sort.coreKind) {
      case WasmComponentCoreSortKind.function:
        _coreFunctions.add(_coreFunctions[sort.index]);
      case WasmComponentCoreSortKind.table:
        _coreTables.add(_coreTables[sort.index]);
      case WasmComponentCoreSortKind.memory:
        _coreMemories.add(_coreMemories[sort.index]);
      case WasmComponentCoreSortKind.global:
        _coreGlobals.add(_coreGlobals[sort.index]);
      case WasmComponentCoreSortKind.tag:
        _coreTags.add(_coreTags[sort.index]);
      case WasmComponentCoreSortKind.module:
        _coreModules.add(_coreModules[sort.index]);
      case WasmComponentCoreSortKind.instance:
        _coreInstances.add(_coreInstances[sort.index]);
      case WasmComponentCoreSortKind.type:
        throw const WASIPreview2ComponentExecutionException(
          'Core type exports are not executable yet.',
        );
      case null:
        throw const WASIPreview2ComponentExecutionException(
          'Core export is missing its core sort.',
        );
    }
  }

  void _runStart(WasmComponentStart start) {
    if (start.arguments.isNotEmpty || start.resultCount != 0) {
      throw const WASIPreview2ComponentExecutionException(
        'Component starts with values are not executable in the Preview2 runner yet.',
      );
    }
    final function = _componentFunctions[start.functionIndex];
    final result = function.invokeSynchronously(const <Object?>[]);
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

  _ComponentFunction _findPreview3CommandRun() {
    for (final entry in _exportedInstances.entries) {
      if (_isPreview3RunExport(entry.key)) {
        final run = entry.value.functions['run'];
        if (run != null) {
          return run;
        }
      }
    }
    for (final entry in _exportedFunctions.entries) {
      if (_isPreview3RunExport(entry.key)) {
        return entry.value;
      }
    }
    throw const WASIPreview2ComponentExecutionException(
      'Component does not export wasi:cli/run@0.3.0.',
    );
  }

  _ComponentFunction _findProxyHandler() {
    for (final entry in _exportedInstances.entries) {
      if (_isPreview2IncomingHandlerExport(entry.key)) {
        final handle = entry.value.functions['handle'];
        if (handle != null) {
          return handle;
        }
      }
    }
    for (final entry in _exportedFunctions.entries) {
      if (_isPreview2IncomingHandlerExport(entry.key)) {
        return entry.value;
      }
    }
    throw const WASIPreview2ComponentExecutionException(
      'Component does not export wasi:http/incoming-handler@0.2.x.',
    );
  }

  _ComponentFunction _findPreview3HttpHandler() {
    for (final entry in _exportedInstances.entries) {
      if (entry.key == 'wasi:http/handler@0.3.0') {
        final handle = entry.value.functions['handle'];
        if (handle != null) {
          return handle;
        }
      }
    }
    for (final entry in _exportedFunctions.entries) {
      if (entry.key == 'wasi:http/handler@0.3.0') {
        return entry.value;
      }
    }
    throw const WASIPreview2ComponentExecutionException(
      'Component does not export wasi:http/handler@0.3.0.',
    );
  }

  bool _isPreview2RunExport(String name) {
    return RegExp(r'^wasi:cli/run@0\.2\.\d+$').hasMatch(name);
  }

  bool _isPreview3RunExport(String name) => name == 'wasi:cli/run@0.3.0';

  bool _isPreview2IncomingHandlerExport(String name) {
    return RegExp(r'^wasi:http/incoming-handler@0\.2\.\d+$').hasMatch(name);
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
    this.invokeSync,
    this.supportsSyncImport = true,
  });

  final String name;
  final FutureOr<Object?> Function(List<Object?> args) invoke;
  final Object? Function(List<Object?> args)? invokeSync;
  final bool supportsSyncImport;

  Object? invokeSynchronously(List<Object?> args) {
    final synchronous = invokeSync;
    if (synchronous != null) {
      return synchronous(args);
    }
    throw WASIPreview2ComponentExecutionException(
      'Core function `$name` is async-only.',
    );
  }
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
    required bool allowSynchronousImports,
  }) {
    return _CoreInstance(
      exports: Map.unmodifiable({
        for (final name in runtime.exportedFunctions)
          name: _CoreExport.function(
            _CoreFunction(
              name: name,
              invoke: allowSynchronousImports
                  ? (args) => runtime.invokeAsync(name, args)
                  : (args) => runtime.invokeAsyncForced(name, args),
              invokeSync: runtime.exportedFunctionSupportsSync(name)
                  ? (args) => runtime.invoke(name, args)
                  : null,
              supportsSyncImport:
                  allowSynchronousImports &&
                  runtime.exportedFunctionSupportsSync(name),
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
  const _ComponentFunction({
    required this.name,
    required this.invoke,
    this.invokeSync,
  });

  final String name;
  final FutureOr<Object?> Function(List<Object?> args) invoke;
  final Object? Function(List<Object?> args)? invokeSync;

  Object? invokeSynchronously(List<Object?> args) {
    final synchronous = invokeSync;
    if (synchronous != null) {
      return synchronous(args);
    }
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
  const _ComponentInstance({
    required this.functions,
    required this.types,
    required this.resourceTypeNames,
  });

  final Map<String, _ComponentFunction> functions;
  final Map<String, WasmComponentTypeDefinition> types;
  final Map<String, String> resourceTypeNames;
}

final class _NestedComponentType {
  const _NestedComponentType({
    required this.definition,
    required this.resourceTypeName,
  });

  final WasmComponentTypeDefinition definition;
  final String? resourceTypeName;
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

int _componentResourceHandle(Object? value) {
  return switch (value) {
    int() when value >= 0 && value <= 0xffffffff => value,
    BigInt() when value >= BigInt.zero && value <= BigInt.from(0xffffffff) =>
      value.toInt(),
    WasmComponentValueData(kind: WasmComponentValueDataKind.integer) =>
      _componentResourceHandle(value.integer),
    _ => throw WASIPreview2ComponentExecutionException(
      'wasi:http/handler.handle returned an invalid response resource.',
    ),
  };
}

String _preview3HttpErrorCode(Object? value) {
  if (value is WasmComponentValueData &&
      value.kind == WasmComponentValueDataKind.variant) {
    return value.label ?? 'internal-error';
  }
  throw const WASIPreview2ComponentExecutionException(
    'wasi:http/handler.handle returned an invalid error-code.',
  );
}

String _externName(String name, String? versionSuffix) {
  if (versionSuffix == null) {
    return name;
  }
  return '$name@$versionSuffix';
}

String _witCallbackKey(String interfaceName, String functionName) {
  const constructorPrefix = '[constructor]';
  if (functionName.startsWith(constructorPrefix)) {
    final resource = functionName.substring(constructorPrefix.length);
    return '$interfaceName.$resource.constructor';
  }
  final normalized = functionName.replaceFirst(RegExp(r'^\[[^\]]+\]'), '');
  return '$interfaceName.$normalized';
}

String _standardResourceTypeName(String interfaceName, String resourceName) {
  final versionedInterface = interfaceName.replaceFirst(
    RegExp(r'@0\.2\.\d+$'),
    '@0.2.0',
  );
  return '$versionedInterface.$resourceName';
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
