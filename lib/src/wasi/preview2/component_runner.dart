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
import '../component/adapter_plan.dart';
import '../component/host.dart';
import '../component/resource_host.dart';
import '../component/async_host.dart';
import '../component/canonical_handles.dart';
import '../component/string_memory.dart';
import '../component/subtask.dart';
import '../component/task.dart';
import '../component/execution.dart';
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

  /// Instantiates [component] and invokes its synchronous incoming handler.
  Future<WASIPreview2HttpResponseOutparam> handle(
    WasmComponent component,
    WASIPreview2HttpIncomingRequest request,
  ) async {
    final runtime = WASIComponentNativeRuntime.preview2(
      component: component,
      host: host,
    );
    try {
      return await runtime.handleProxy(request);
    } finally {
      await runtime.dispose();
    }
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

/// Native Component Model executor shared by component and WASI runners.
final class WASIComponentNativeRuntime {
  /// Creates a component executor without a fixed WASI version profile.
  ///
  /// The caller owns the allocation scope for this instance and its calls.
  /// Export calls and top-level Component starts await [imports]. A core module
  /// start cannot invoke generic imports. Nested Component starts remain
  /// unsupported; both are rejected before launching callbacks.
  WASIComponentNativeRuntime.component({
    required this.component,
    required WASIComponentHost host,
    Map<String, WASIComponentWitAdapterCallback> imports = const {},
  }) : _genericHost = host,
       _genericImports = Map.unmodifiable(imports),
       _nestedArguments = null,
       _parentStore = null,
       _preview2Host = null,
       _preview3Host = null;

  /// Creates a native executor for a Preview2 [host].
  WASIComponentNativeRuntime.preview2({
    required this.component,
    required WASIPreview2ComponentHost host,
  }) : _genericHost = null,
       _genericImports = const {},
       _nestedArguments = null,
       _parentStore = null,
       _preview2Host = host,
       _preview3Host = null;

  /// Creates a native executor for a Preview3 [host].
  WASIComponentNativeRuntime.preview3({
    required this.component,
    required WASIPreview3ComponentHost host,
  }) : _genericHost = null,
       _genericImports = const {},
       _nestedArguments = null,
       _parentStore = null,
       _preview2Host = null,
       _preview3Host = host;

  WASIComponentNativeRuntime._nested({
    required this.component,
    required WASIComponentNativeRuntime parent,
    required _NestedComponentArguments arguments,
  }) : _genericHost = parent._genericHost,
       _genericImports = parent._genericImports,
       _preview2Host = parent._preview2Host,
       _preview3Host = parent._preview3Host,
       _nestedArguments = arguments,
       _parentStore = parent._store;

  /// Component decoded for this execution.
  final WasmComponent component;
  final WASIComponentGuestStore? _parentStore;
  late final WASIComponentGuestStore _store =
      _parentStore ?? WASIComponentGuestStore();
  final WASIComponentHost? _genericHost;
  final Map<String, WASIComponentWitAdapterCallback> _genericImports;
  final _NestedComponentArguments? _nestedArguments;
  final WASIPreview2ComponentHost? _preview2Host;
  final WASIPreview3ComponentHost? _preview3Host;

  WASIComponentHost get _componentHost =>
      _genericHost ??
      _preview2Host?.componentHost ??
      _preview3Host!.componentHost;

  Map<String, WASIComponentWitAdapterCallback> get _standardImports =>
      _preview2Host?.standardImports ??
      _preview3Host?.standardImports ??
      _genericImports;

  final _liftDefinitionKey = Object();

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
  final List<WASIComponentCanonicalResourceIdentity?> _visibleResources = [];
  final Map<
    WasmComponentTypeDefinitionContext,
    WASIComponentCanonicalResourceIdentity
  >
  _resourceIdentities = {};
  final Map<WASIComponentCanonicalResourceIdentity, String> _resourceTypeNames =
      {};
  final Map<String, WASIComponentCanonicalResourceIdentity> _exportedResources =
      {};
  final Map<int, WASIComponentCanonicalAdapterPlan> _runtimeAdapterPlans = {};
  final List<WASIComponentCanonicalResourceIdentity> _hostResourceIdentities =
      [];
  late final WASIComponentCanonicalHandles _handles =
      WASIComponentCanonicalHandles(
        table: _componentHost.table,
        errorContexts: _componentHost.canonicalHost.errorContextHost,
        contextHost: _componentHost.canonicalHost.contextHost,
        resourceIdentity: _runtimeResourceIdentity,
        adapterResourceIdentity: _adapterResourceIdentity,
        collectErrorCarriers: _collectAdapterErrorCarriers,
      );
  final Map<String, _ComponentFunction> _exportedFunctions =
      <String, _ComponentFunction>{};
  final Map<String, _ComponentInstance> _exportedInstances =
      <String, _ComponentInstance>{};
  final Map<String, WasmComponentTypeDefinition> _exportedTypes = {};
  final Map<String, String> _exportedResourceTypeNames = {};
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
  Future<void>? _genericInitialization;

  /// Instantiates this component once, retaining its state for later calls.
  Future<void> initialize() {
    if (_genericHost == null) return Future<void>.sync(_initialize);
    if (_initialized) return _genericInitialization ??= Future<void>.value();
    if (Zone.current[this] == true) {
      return Future<void>.error(
        const WASIPreview2ComponentExecutionException(
          'Reentrant Component initialization is not supported.',
        ),
      );
    }
    final pending = _genericInitialization;
    if (pending != null) return pending;
    final initialization = Completer<void>();
    // Publish the pending result before a start can invoke a host callback.
    _genericInitialization = initialization.future;
    unawaited(
      runZoned(() async {
        try {
          await _initializeGeneric();
          initialization.complete();
        } catch (error, stack) {
          initialization.completeError(error, stack);
        }
      }, zoneValues: {this: true}),
    );
    return initialization.future;
  }

  /// Invokes a named component function export and awaits host callbacks.
  ///
  /// Initializes the instance on its first call. Resource lifetime belongs to
  /// the caller's allocation scope, which may span several invocations.
  Future<Object?> invokeExport(String name, List<Object?> args) async {
    await initialize();
    final function = _exportedFunctions[name];
    if (function == null) {
      throw WASIPreview2ComponentExecutionException(
        'Component function export `$name` not found.',
      );
    }
    _store.check();
    function.validateArgs?.call(args);
    final result = await function.invoke(args);
    _store.check();
    return result;
  }

  /// Waits for live guest bodies, including work after task.return.
  ///
  /// Calls may depend on a later invocation; call this at a session boundary.
  Future<void> settle() => _store.settle();

  /// Internal command token associated with the originating store failure.
  Object? get failureOwner => _store.failureOwner;

  /// Aborts pending guest waits and releases retained execution scopes.
  ///
  /// A previously trapped store rethrows its first failure after cleanup.
  Future<void> dispose() => _store.dispose();

  /// Executes the Preview2 command export.
  Future<int> runCommand() async {
    try {
      return await _componentHost.table.runScoped(() async {
        try {
          _initialize();
          final run = _findCommandRun();
          final result = await run.invoke(const <Object?>[]);
          await settle();
          return _runResultExitCode(result);
        } on WASIPreview2Exit catch (exit) {
          return exit.statusCode;
        }
      });
    } finally {
      await dispose();
    }
  }

  /// Executes the Preview3 async command export.
  Future<int> runPreview3Command() async {
    try {
      return await _componentHost.table.runScoped(() async {
        try {
          _initialize();
          final run = _findPreview3CommandRun();
          final result = await run.invoke(const <Object?>[]);
          await settle();
          return _runResultExitCode(result);
        } on WASIPreview3Exit catch (exit) {
          return exit.statusCode;
        } on WASIPreview2Exit catch (exit) {
          return exit.statusCode;
        }
      });
    } finally {
      await dispose();
    }
  }

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
    _prepareExecution();
    _processDefinitions();
    _checkHostResourceIdentities();
    _initialized = true;
  }

  Future<void> _initializeGeneric() async {
    _prepareExecution();
    for (final event in component.definitionEvents) {
      if (event.kind == WasmComponentDefinitionKind.start) {
        await _startFunction(component.starts[event.index]).invoke(const []);
      } else {
        _processDefinition(event);
      }
    }
    _checkHostResourceIdentities();
    _initialized = true;
  }

  void _checkHostResourceIdentities() {
    if (_hostResourceIdentities.any((identity) => identity.type == null)) {
      throw const WASIPreview2ComponentExecutionException(
        'Unregistered abstract host resource: alias its provider type and bind that component type index with resourceHost.defineResourceType before execution.',
      );
    }
  }

  void _bindRegisteredHostResource(
    WASIComponentCanonicalResourceIdentity? identity,
    int index,
  ) {
    if (identity == null || identity.type != null) return;
    final registered = _componentHost.canonicalHost.resourceHost
        .canonicalRegisteredTypeAt(index);
    if (registered != null) identity.type = registered;
  }

  void _addVisibleResourceIdentity(
    WASIComponentCanonicalResourceIdentity? identity,
  ) {
    final index = _visibleResources.length;
    _visibleResources.add(identity);
    if (identity == null) return;
    final context = component.componentTypeIndexScope.definitionContextAt(
      index,
    );
    if (context != null) _resourceIdentities[context] = identity;
    final name = _visibleResourceTypeNames[index];
    if (name != null) _resourceTypeNames[identity] = name;
  }

  void _prepareExecution() {
    final plan = _checkComponent();
    final types = component.componentTypeIndexDefinitions;
    final localResourceDefinitions = {
      for (final definition in component.typeDefinitions)
        if (definition.resource != null && !definition.resource!.isAbstract)
          definition,
    };
    _runtimeAdapterPlans.addEntries(
      plan.adapterPlans.map((plan) => MapEntry(plan.canonicalIndex, plan)),
    );
    _initializeAdapterCallbacks(plan.adapterPlans);
    plan.bindCanonicalHandles((bindings) {
      _handles.asyncBindings = bindings;
      if (bindings is WASIComponentAsyncValueBindingSet) {
        _handles.bindAsyncValues(
          bindings,
          plan.asyncValueBindings,
          _asyncResourceIdentity,
        );
      }
      for (final binding in plan.asyncValueBindings) {
        _handles.endpointKinds[binding.componentTypeIndex] =
            binding.kind == WASIComponentAsyncValueBindingKind.stream
            ? WASIComponentCanonicalHandleKind.streamReadable
            : WASIComponentCanonicalHandleKind.futureReadable;
      }
      return _handles;
    });
    _binding = plan.bind(
      coreFunctions: _adapterCoreCallbacks,
      componentFunctions: _adapterComponentCallbacks,
      maxBufferedElementsForStream: (_) => 0,
      instanceLocalAsyncValues: true,

      onResourceDrop: (binding, representation) {
        if (!_store.canRunDestructors) return;
        final definition = types[binding.componentTypeIndex];
        // A foreign alias's destructor index belongs to its defining runtime.
        // This membership check establishes static index provenance only.
        if (!localResourceDefinitions.contains(definition)) return;
        final resource = definition.resource;
        final destructor = resource?.destructorFunctionIndex;
        if (destructor != null) {
          _store.runDestructor(
            () => _coreFunctions[destructor].invokeSynchronously([
              representation,
            ]),
          );
        }
      },
    );
    _adapterProgram = plan.bindAdapters(
      coreFunctions: _adapterCoreCallbacks,
      componentFunctions: _adapterComponentCallbacks,
    );
    _synchronousAdapterProgram = plan.bindAdapters(
      coreFunctions: _synchronousAdapterCoreCallbacks,
      componentFunctions: _synchronousAdapterComponentCallbacks,
    );
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
    for (final type in component.componentTypeIndexDefinitions) {
      if (type.resource?.isAsync == true) {
        throw const WASIPreview2ComponentExecutionException(
          'Asynchronous resource destructors are not executable yet.',
        );
      }
    }
    final genericHost = _genericHost;
    if (genericHost != null) {
      final plan = genericHost.prepareComponent(component, validate: false);
      if (plan.canBindWithAdapters) {
        return plan;
      }
      throw WASIPreview2ComponentExecutionException(
        _formatErrors('wasd-component-runtime bind preflight failed', [
          ...plan.unsupportedDefinitions,
          ...plan.bindingErrors,
        ]),
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
      _processDefinition(event);
    }
  }

  void _processDefinition(WasmComponentDefinitionEvent event) {
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
        _addCanonical(event.index, component.canonicalDefinitions[event.index]);
      case WasmComponentDefinitionKind.instance:
        _componentInstances.add(
          _instantiateComponentInstance(component.instances[event.index]),
        );
      case WasmComponentDefinitionKind.export:
        _addExport(component.exports[event.index]);
      case WasmComponentDefinitionKind.start:
        _runStart(component.starts[event.index]);
      case WasmComponentDefinitionKind.component:
        _components.add(component.nestedComponentInContext(event.index));
      case WasmComponentDefinitionKind.coreType:
      case WasmComponentDefinitionKind.type:
      case WasmComponentDefinitionKind.value:
        break;
    }
  }

  void _includeTypeDefinitionsTo(int count) {
    if (count <= _decodedTypeDefinitionCount) {
      return;
    }
    for (final type in component.typeDefinitions.getRange(
      _decodedTypeDefinitionCount,
      count,
    )) {
      final index = _visibleTypes.length;
      _visibleTypes.add(type);
      _visibleResourceTypeNames.add(null);
      _addVisibleResourceIdentity(
        type.kind == WasmComponentTypeKind.resource
            ? WASIComponentCanonicalResourceIdentity(
                _binding.canonicalResourceTypeAt(index),
                _handles,
              )
            : null,
      );
    }
    _decodedTypeDefinitionCount = count;
  }

  void _addComponentImport(WasmComponentImport import) {
    final name = import.name;
    final supplied = _nestedArguments;
    if (supplied != null) {
      switch (import.descriptor.kind) {
        case WasmComponentExternKind.function:
          _componentFunctions.add(
            supplied.functions[name] ??
                (throw WASIPreview2ComponentExecutionException(
                  'Missing nested component function argument `$name`.',
                )),
          );
        case WasmComponentExternKind.instance:
          _componentInstances.add(
            supplied.instances[name] ??
                (throw WASIPreview2ComponentExecutionException(
                  'Missing nested component instance argument `$name`.',
                )),
          );
        case WasmComponentExternKind.componentType:
          final type = supplied.types[name];
          if (type == null) {
            throw WASIPreview2ComponentExecutionException(
              'Missing nested component type argument `$name`.',
            );
          }
          _visibleTypes.add(type.definition);
          _visibleResourceTypeNames.add(type.resourceTypeName);
          _addVisibleResourceIdentity(type.resourceIdentity);
        case WasmComponentExternKind.coreModule:
        case WasmComponentExternKind.value:
        case WasmComponentExternKind.component:
          throw WASIPreview2ComponentExecutionException(
            'Unsupported nested component import `$name` of kind '
            '`${import.descriptor.kind.name}`.',
          );
      }
      return;
    }
    switch (import.descriptor.kind) {
      case WasmComponentExternKind.function:
        final context = component.componentTypeIndexScope.definitionContextAt(
          import.descriptor.typeIndex,
        );
        final functionType = context?.definition.function;
        _componentFunctions.add(
          _hostComponentFunction(
            name,
            resources: functionType == null
                ? null
                : () => _functionResourceIdentities(
                    functionType,
                    context!.typeScope,
                  ),
          ),
        );
      case WasmComponentExternKind.instance:
        _componentInstances.add(
          _hostComponentInstance(name, import.descriptor),
        );
      case WasmComponentExternKind.coreModule:
        throw WASIPreview2ComponentExecutionException(
          'Imported core modules are not supported yet: $name.',
        );
      case WasmComponentExternKind.componentType:
        final type = _typeExportDefinition(import.descriptor, _visibleTypes);
        final registered = _componentHost.canonicalHost.resourceHost
            .canonicalRegisteredTypeAt(_visibleTypes.length);
        if (type?.resource == null || registered == null) {
          throw WASIPreview2ComponentExecutionException(
            'Unregistered abstract host resource `$name`; bind its component type index with resourceHost.defineResourceType.',
          );
        }
        _visibleTypes.add(type!);
        _visibleResourceTypeNames.add(null);
        _addVisibleResourceIdentity(
          WASIComponentCanonicalResourceIdentity(registered, null),
        );
      case WasmComponentExternKind.component:
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
    final context = component.componentTypeIndexScope.definitionContextAt(
      descriptor.typeIndex,
    );
    final type = context?.definition;
    final instanceType = type?.instance;
    final typeScope = context?.instanceTypeScope;
    if (type == null ||
        type.kind != WasmComponentTypeKind.instance ||
        instanceType == null ||
        typeScope == null) {
      throw WASIPreview2ComponentExecutionException(
        'Component import `$interfaceName` does not reference an instance type.',
      );
    }
    final functions = <String, _ComponentFunction>{};
    final types = <String, WasmComponentTypeDefinition>{};
    final resourceTypeNames = <String, String>{};
    final resources = <String, WASIComponentCanonicalResourceIdentity>{};
    final localResources = <WASIComponentCanonicalResourceIdentity?>[];
    final localResourceTypeNames = <String?>[];
    for (final declaration in instanceType.declarations) {
      final export = declaration.export;
      switch (declaration.kind) {
        case WasmComponentTypeDeclarationKind.type:
          final type = declaration.type;
          if (type != null) {
            localResourceTypeNames.add(null);
            localResources.add(null);
          }
        case WasmComponentTypeDeclarationKind.export:
          if (export == null) {
            continue;
          }
          final name = export.name;
          if (export.descriptor.kind == WasmComponentExternKind.function) {
            final functionContext = typeScope.definitionContextAt(
              export.descriptor.typeIndex,
            )!;
            functions[name] = _hostComponentFunction(
              _witCallbackKey(interfaceName, name),
              resources: () => _functionResourceIdentities(
                functionContext.definition.function!,
                functionContext.typeScope,
              ),
            );
            continue;
          }
          if (export.descriptor.kind != WasmComponentExternKind.componentType) {
            continue;
          }
          final type = typeScope.definitionAt(localResources.length);
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
            final identity = type.resource == null
                ? null
                : export.descriptor.boundKind ==
                      WasmComponentExternBoundKind.equality
                ? localResources[export.descriptor.typeIndex!]
                : WASIComponentCanonicalResourceIdentity(
                    _preview2Host?.canonicalResourceType(interfaceName, name) ??
                        _preview3Host?.canonicalResourceType(
                          interfaceName,
                          name,
                        ),
                    null,
                  );
            if (identity != null) _hostResourceIdentities.add(identity);
            if (identity != null) resources[name] = identity;
            if (identity != null) {
              _resourceIdentities[typeScope.definitionContextAt(
                    localResources.length,
                  )!] =
                  identity;
              if (resourceTypeName != null) {
                _resourceTypeNames[identity] = resourceTypeName;
              }
            }
            localResources.add(identity);
            localResourceTypeNames.add(resourceTypeName);
          }
        case WasmComponentTypeDeclarationKind.import:
        case WasmComponentTypeDeclarationKind.coreType:
          break;
        case WasmComponentTypeDeclarationKind.alias:
          final alias = declaration.alias;
          final aliasContext = typeScope.definitionContextAt(
            localResources.length,
          );
          if (alias?.sort.kind != WasmComponentSortKind.componentType ||
              alias?.target.kind != WasmComponentAliasTargetKind.outer ||
              aliasContext == null) {
            throw WASIPreview2ComponentExecutionException(
              'Unsupported type alias in component import `$interfaceName`.',
            );
          }
          final identity = _resourceIdentities[aliasContext];
          localResourceTypeNames.add(_resourceTypeNames[identity]);
          localResources.add(identity);
      }
    }
    return _ComponentInstance(
      functions: Map.unmodifiable(functions),
      types: Map.unmodifiable(types),
      resourceTypeNames: Map.unmodifiable(resourceTypeNames),
      resources: Map.unmodifiable(resources),
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

  _ComponentFunction _hostComponentFunction(
    String key, {
    List<WASIComponentCanonicalResourceIdentity> Function()? resources,
  }) {
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
    return _ComponentFunction(
      resources: resources,
      isHost: true,
      name: resolvedKey,
      invoke: callback,
      start: (loadArgs, subtask, onResolve, lowering) => _startHostCall(
        resolvedKey,
        callback!,
        loadArgs,
        subtask,
        onResolve,
        lowering,
      ),
      // Generic imports accept FutureOr. Synchronous initialization (notably a
      // core start) must reject them before the callback can launch a Future.
      invokeSync: _genericHost == null
          ? null
          : (_) => throw WASIPreview2ComponentExecutionException(
              'Generic import callback `$resolvedKey` cannot be invoked synchronously.',
            ),
    );
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
        if (alias.sort.kind == WasmComponentSortKind.componentType) {
          final type = component.componentTypeIndexScope.definitionAt(
            _visibleTypes.length,
          );
          if (type != null) {
            _visibleTypes.add(type);
            _visibleResourceTypeNames.add(
              alias.target.componentDepth == 0
                  ? _visibleResourceTypeNames[alias.target.index!]
                  : null,
            );
            _addVisibleResourceIdentity(
              alias.target.componentDepth == 0
                  ? _visibleResources[alias.target.index!]
                  : null,
            );
            return;
          }
        }
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
        final identity = instance.resources[name];
        _bindRegisteredHostResource(identity, _visibleTypes.length);
        _visibleTypes.add(type);
        _visibleResourceTypeNames.add(instance.resourceTypeNames[name]);
        _addVisibleResourceIdentity(identity);
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
            invoke: (args) => _invokeLower(canonicalIndex, definition, args),
            invokeSync: isAsync
                ? (_) => throw const WASIPreview2ComponentExecutionException(
                    'Canonical async lower cannot execute during synchronous initialization.',
                  )
                : (args) {
                    _store.check();
                    _requireMayLeave(canonicalIndex);
                    return _coreHostResult(
                      _synchronousAdapterProgram.invokeLoweredCore(
                        canonicalIndex,
                        args,
                        memory: _canonicalMemory(definition),
                        realloc: _canonicalRealloc(definition),
                      ),
                    );
                  },
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
            resources: () => [
              for (final use
                  in _runtimeAdapterPlans[canonicalIndex]!.resourceUses)
                _runtimeResourceIdentity(use.resourceTypeIndex),
            ],
            validateArgs: (args) {
              _adapterProgram.validateCanonicalArguments(canonicalIndex, args);
              _handles.validateHostArguments(
                canonicalIndex,
                _runtimeAdapterPlans[canonicalIndex]!,
                args,
              );
            },
            start: (loadArgs, subtask, onResolve, _) => _startLift(
              canonicalIndex,
              definition,
              loadArgs,
              subtask,
              onResolve,
            ),
            invoke: (args) => _startLift(
              canonicalIndex,
              definition,
              () => args,
              null,
              null,
            ).result(),
            invokeSync: isAsync
                ? (_) => throw WASIPreview2ComponentExecutionException(
                    'Canonical async lift $canonicalIndex cannot be invoked synchronously.',
                  )
                : (args) => _handles.withThread(
                    () => _handles.withHandleCall(
                      () => _synchronousAdapterProgram.invokeLiftedCore(
                        canonicalIndex,
                        args,
                        memory: _canonicalMemory(definition),
                        realloc: _canonicalRealloc(definition),
                      ),
                    ),
                  ),
          ),
        );
      case WasmComponentCanonicalKind.resourceNew:
      case WasmComponentCanonicalKind.resourceRep:
        _coreFunctions.add(
          _CoreFunction(
            name: 'canonical[$canonicalIndex].${definition.kind.name}',
            invoke: (args) => _invokeResourceBuiltin(canonicalIndex, args),
            invokeSync: (args) => _invokeResourceBuiltin(canonicalIndex, args),
          ),
        );
      case WasmComponentCanonicalKind.resourceDrop:
        _coreFunctions.add(
          _CoreFunction(
            name: 'canonical[$canonicalIndex].resourceDrop',
            invoke: (args) => _invokeResourceBuiltin(canonicalIndex, args),
            invokeSync: (args) => _invokeResourceBuiltin(canonicalIndex, args),
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
          _store.check();
          if (definition.kind == WasmComponentCanonicalKind.threadIndex) {
            return _handles.currentThread;
          }
          if (definition.kind == WasmComponentCanonicalKind.taskReturn) {
            _requireTaskReturn(canonicalIndex, definition);
          }
          if (definition.kind == WasmComponentCanonicalKind.taskCancel) {
            _handles.requireNoCallBorrows();
          }
          final hostArgs = _canonicalHostArgs(definition, args);
          final resultPointer =
              definition.kind ==
                  WasmComponentCanonicalKind.errorContextDebugMessage
              ? (hostArgs.removeLast() as int).toUnsigned(32)
              : null;
          final FutureOr<Object?> result;
          if (memory == null) {
            result = isAsync
                ? _binding.program.invoke(canonicalIndex, hostArgs)
                : _binding.program.invokeAsync(canonicalIndex, hostArgs);
          } else {
            result = isAsync
                ? _binding.program.invokeWithMemoryEvent(
                    canonicalIndex,
                    memory,
                    hostArgs,
                    realloc: realloc,
                    resultPointer: resultPointer,
                  )
                : _binding.program.invokeWithMemoryAsync(
                    canonicalIndex,
                    memory,
                    hostArgs,
                    realloc: realloc,
                    resultPointer: resultPointer,
                  );
          }
          if (result is Future) {
            return result.then(
              (value) => _canonicalGuestResult(definition, args, value, memory),
            );
          }
          return _canonicalGuestResult(definition, args, result, memory);
        }

        Object? invokeSync(List<Object?> args) {
          _store.check();
          if (definition.kind == WasmComponentCanonicalKind.taskReturn) {
            _requireTaskReturn(canonicalIndex, definition);
          }
          if (definition.kind == WasmComponentCanonicalKind.taskCancel) {
            _handles.requireNoCallBorrows();
          }
          if (definition.kind == WasmComponentCanonicalKind.threadIndex) {
            return _handles.currentThread;
          }
          final hostArgs = _canonicalHostArgs(definition, args);
          final resultPointer =
              definition.kind ==
                  WasmComponentCanonicalKind.errorContextDebugMessage
              ? (hostArgs.removeLast() as int).toUnsigned(32)
              : null;
          final result = memory == null
              ? _binding.program.invoke(canonicalIndex, hostArgs)
              : _binding.program.invokeWithMemoryEvent(
                  canonicalIndex,
                  memory,
                  hostArgs,
                  realloc: realloc,
                  resultPointer: resultPointer,
                );
          return _canonicalGuestResult(definition, args, result, memory);
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

  List<Object?> _canonicalHostArgs(
    WasmComponentCanonicalDefinition definition,
    List<Object?> args,
  ) {
    switch (definition.kind) {
      case WasmComponentCanonicalKind.streamNew ||
          WasmComponentCanonicalKind.futureNew:
        _handles.requireCapacity(2);
      case WasmComponentCanonicalKind.waitableSetNew ||
          WasmComponentCanonicalKind.errorContextNew:
        _handles.requireCapacity(1);
      default:
        break;
    }
    final result = List<Object?>.of(args);
    if (definition.kind == WasmComponentCanonicalKind.waitableJoin) {
      result[0] = _handles.host(result[0] as int);
      if (result[1] != 0) {
        result[1] = _handles.host(
          result[1] as int,
          kind: WASIComponentCanonicalHandleKind.waitableSet,
        );
      }
      return result;
    }
    final kind = switch (definition.kind) {
      WasmComponentCanonicalKind.streamRead ||
      WasmComponentCanonicalKind.streamCancelRead ||
      WasmComponentCanonicalKind.streamDropReadable =>
        WASIComponentCanonicalHandleKind.streamReadable,
      WasmComponentCanonicalKind.streamWrite ||
      WasmComponentCanonicalKind.streamCancelWrite ||
      WasmComponentCanonicalKind.streamDropWritable =>
        WASIComponentCanonicalHandleKind.streamWritable,
      WasmComponentCanonicalKind.futureRead ||
      WasmComponentCanonicalKind.futureCancelRead ||
      WasmComponentCanonicalKind.futureDropReadable =>
        WASIComponentCanonicalHandleKind.futureReadable,
      WasmComponentCanonicalKind.futureWrite ||
      WasmComponentCanonicalKind.futureCancelWrite ||
      WasmComponentCanonicalKind.futureDropWritable =>
        WASIComponentCanonicalHandleKind.futureWritable,
      WasmComponentCanonicalKind.waitableSetDrop ||
      WasmComponentCanonicalKind.waitableSetWait ||
      WasmComponentCanonicalKind.waitableSetPoll =>
        WASIComponentCanonicalHandleKind.waitableSet,
      WasmComponentCanonicalKind.subtaskDrop ||
      WasmComponentCanonicalKind.subtaskCancel =>
        WASIComponentCanonicalHandleKind.subtask,
      WasmComponentCanonicalKind.errorContextDrop ||
      WasmComponentCanonicalKind.errorContextDebugMessage =>
        WASIComponentCanonicalHandleKind.errorContext,
      _ => null,
    };
    if (kind != null) {
      result[0] = _handles.host((result[0] as int).toUnsigned(32), kind: kind);
    }
    return result;
  }

  Object? _canonicalGuestResult(
    WasmComponentCanonicalDefinition definition,
    List<Object?> args,
    Object? result,
    native_memory.Memory? memory,
  ) {
    final kind = definition.kind;
    switch (kind) {
      case WasmComponentCanonicalKind.streamNew:
      case WasmComponentCanonicalKind.futureNew:
        final pair = WASIComponentAsyncEndpointHandles.unpack(result as int);
        final stream = kind == WasmComponentCanonicalKind.streamNew;
        final read = _handles.add(
          pair.readable,
          stream
              ? WASIComponentCanonicalHandleKind.streamReadable
              : WASIComponentCanonicalHandleKind.futureReadable,
        );
        final write = _handles.add(
          pair.writable,
          stream
              ? WASIComponentCanonicalHandleKind.streamWritable
              : WASIComponentCanonicalHandleKind.futureWritable,
        );
        return WASIComponentAsyncEndpointHandles(
          readable: read,
          writable: write,
        ).packed;
      case WasmComponentCanonicalKind.waitableSetNew:
        return _handles.add(
          result as int,
          WASIComponentCanonicalHandleKind.waitableSet,
        );
      case WasmComponentCanonicalKind.errorContextNew:
        return _handles.add(
          result as int,
          WASIComponentCanonicalHandleKind.errorContext,
        );
      case WasmComponentCanonicalKind.waitableSetWait:
      case WasmComponentCanonicalKind.waitableSetPoll:
        if (memory != null &&
            result != 0 &&
            result != WASIComponentWaitableEventCode.taskCancelled.value) {
          final data = ByteData.view(memory.buffer);
          final pointer = args[1] as int;
          data.setUint32(
            pointer,
            _handles.guest(data.getUint32(pointer, Endian.little)),
            Endian.little,
          );
        }
        return result;
      case WasmComponentCanonicalKind.streamDropReadable:
      case WasmComponentCanonicalKind.streamDropWritable:
      case WasmComponentCanonicalKind.futureDropReadable:
      case WasmComponentCanonicalKind.futureDropWritable:
      case WasmComponentCanonicalKind.subtaskDrop:
      case WasmComponentCanonicalKind.waitableSetDrop:
      case WasmComponentCanonicalKind.errorContextDrop:
        return result;
      default:
        return result;
    }
  }

  List<WASIComponentCanonicalResourceIdentity> _functionResourceIdentities(
    WasmComponentFunctionType function,
    WasmComponentTypeScope typeScope,
  ) {
    final result = <WASIComponentCanonicalResourceIdentity>[];
    final active = <WasmComponentTypeDefinitionContext>{};
    void visit(WasmComponentValueType? value, WasmComponentTypeScope scope) {
      final index = value?.typeIndex;
      if (index == null) return;
      final context = scope.definitionContextAt(index);
      if (context == null) throw StateError('Unknown runtime host value type.');
      final type = context.definition.definedValue;
      if (type == null) return;
      if (!active.add(context)) {
        throw StateError('Cyclic runtime host value type.');
      }
      void child(WasmComponentValueType? value) =>
          visit(value, context.typeScope);
      try {
        switch (type.kind) {
          case WasmComponentDefinedValueTypeKind.own:
          case WasmComponentDefinedValueTypeKind.borrow:
            final resource = context.typeScope.definitionContextAt(
              type.typeIndex,
            );
            final identity = _resourceIdentities[resource];
            if (identity == null) {
              throw StateError('Missing runtime host resource type.');
            }
            result.add(identity);
          case WasmComponentDefinedValueTypeKind.record:
            for (final field in type.fields) {
              child(field.type);
            }
          case WasmComponentDefinedValueTypeKind.variant:
            for (final item in type.cases) {
              child(item.type);
            }
          case WasmComponentDefinedValueTypeKind.tuple:
            for (final item in type.types) {
              child(item);
            }
          case WasmComponentDefinedValueTypeKind.result:
            child(type.okType);
            child(type.errorType);
          case WasmComponentDefinedValueTypeKind.list:
          case WasmComponentDefinedValueTypeKind.fixedList:
          case WasmComponentDefinedValueTypeKind.option:
          case WasmComponentDefinedValueTypeKind.stream:
          case WasmComponentDefinedValueTypeKind.future:
            child(type.elementType);
          case WasmComponentDefinedValueTypeKind.map:
            child(type.keyType);
            child(type.valueType);
          case WasmComponentDefinedValueTypeKind.primitive:
          case WasmComponentDefinedValueTypeKind.flags:
          case WasmComponentDefinedValueTypeKind.enumeration:
            break;
        }
      } finally {
        active.remove(context);
      }
    }

    for (final parameter in function.params) {
      visit(parameter.type, typeScope);
    }
    visit(function.result, typeScope);
    return result;
  }

  WASIComponentCanonicalResourceIdentity _runtimeResourceIdentity(int index) =>
      _visibleResources[index] ??
      (throw StateError('Unknown runtime resource type: $index.'));

  WASIComponentCanonicalResourceIdentity _adapterResourceIdentity(
    int canonicalIndex,
    int index,
  ) {
    final plan = _runtimeAdapterPlans[canonicalIndex]!;
    if (plan.kind == WasmComponentCanonicalKind.lift) {
      return _runtimeResourceIdentity(index);
    }
    final function = _componentFunctions[plan.definition.functionIndex!];
    final resources = function.resources?.call();
    if (resources != null) {
      if (resources.length != plan.resourceUses.length) {
        throw StateError('Runtime function resource signature mismatch.');
      }
      WASIComponentCanonicalResourceIdentity? result;
      for (var i = 0; i < plan.resourceUses.length; i++) {
        if (plan.resourceUses[i].resourceTypeIndex != index) continue;
        if (result != null && !identical(result, resources[i])) {
          throw StateError('Conflicting nominal resource signature.');
        }
        result = resources[i];
      }
      if (result != null) return result;
    }
    throw StateError(
      'Missing concrete runtime resource provenance for canonical adapter $canonicalIndex type $index.',
    );
  }

  bool _collectAdapterErrorCarriers(int canonicalIndex) {
    final plan = _runtimeAdapterPlans[canonicalIndex]!;
    if (plan.kind != WasmComponentCanonicalKind.lower ||
        _componentFunctions[plan.definition.functionIndex!].isHost) {
      return false;
    }
    bool contains(WASIComponentCanonicalAdapterFlatValuePlan? layout) =>
        layout != null &&
        (layout.kind ==
                WASIComponentCanonicalAdapterFlatValueKind.errorContext ||
            layout.fields.any((field) => contains(field.value)) ||
            layout.cases.any((item) => contains(item.value)) ||
            contains(layout.element) ||
            contains(layout.ok) ||
            contains(layout.error));
    return plan.params.any((param) => contains(param.flatLayout)) ||
        contains(plan.result?.flatLayout);
  }

  WASIComponentCanonicalResourceIdentity _asyncResourceIdentity(
    WASIComponentAsyncValueBinding binding,
    int index,
  ) {
    if (binding.componentTypeIndex <
            component.componentTypeIndexDefinitions.length &&
        index < _visibleResources.length &&
        _visibleResources[index] != null) {
      return _runtimeResourceIdentity(index);
    }
    bool contains(WASIComponentCanonicalAdapterFlatValuePlan? layout) {
      if (layout == null) return false;
      if (layout.asyncTypeIndex == binding.componentTypeIndex) return true;
      return layout.fields.any((field) => contains(field.value)) ||
          layout.cases.any((item) => contains(item.value)) ||
          contains(layout.element) ||
          contains(layout.ok) ||
          contains(layout.error);
    }

    WASIComponentCanonicalResourceIdentity? result;
    for (final plan in _runtimeAdapterPlans.values) {
      if (!plan.params.any((value) => contains(value.flatLayout)) &&
          !contains(plan.result?.flatLayout)) {
        continue;
      }
      final candidate = _adapterResourceIdentity(plan.canonicalIndex, index);
      if (result != null && !identical(result.type, candidate.type)) {
        throw StateError('Conflicting runtime async resource signature.');
      }
      result = candidate;
    }
    return result ?? _runtimeResourceIdentity(index);
  }

  void _requireMayLeave(int canonicalIndex) {
    _adapterProgram.requireMayLeave(canonicalIndex);
    _synchronousAdapterProgram.requireMayLeave(canonicalIndex);
  }

  Object? _invokeResourceBuiltin(int canonicalIndex, List<Object?> args) {
    _requireMayLeave(canonicalIndex);
    final definition = component.canonicalDefinitions[canonicalIndex];
    if (args.length != 1 || args.single is! int) {
      throw StateError('Resource operation expects one i32.');
    }
    final value = args.single as int;
    final index = definition.typeIndex!;
    switch (definition.kind) {
      case WasmComponentCanonicalKind.resourceNew:
        return _handles.newResource(index, value);
      case WasmComponentCanonicalKind.resourceRep:
        return _handles.resourceRep(index, value.toUnsigned(32));
      case WasmComponentCanonicalKind.resourceDrop:
        _handles.resourceDrop(index, value.toUnsigned(32));
        return null;
      default:
        throw StateError('Not a resource operation.');
    }
  }

  void _requireTaskReturn(
    int canonicalIndex,
    WasmComponentCanonicalDefinition definition,
  ) {
    _requireMayLeave(canonicalIndex);
    final active =
        Zone.current[_liftDefinitionKey]
            as ({
              int canonicalIndex,
              WasmComponentCanonicalDefinition definition,
              WASIComponentTask? task,
            })?;
    if (active == null ||
        !_canonicalFunctionIsAsync(active.definition) ||
        active.task == null ||
        !identical(
          active.task,
          _componentHost.canonicalHost.taskHost.currentTask,
        )) {
      throw StateError(
        'task.return requires the current asynchronous lifted task.',
      );
    }
    final expected =
        _runtimeAdapterPlans[active.canonicalIndex]!.functionType.result;
    final actual = definition.result?.valueType;
    final expectedScope =
        component.componentTypeIndexScope
            .definitionContextAt(active.definition.typeIndex)
            ?.typeScope ??
        component.componentTypeIndexScope;
    if (expected == null || actual == null
        ? expected != actual
        : !componentCanonicalValueTypesMatch(
            expected,
            actual,
            expectedScope,
            component.componentTypeIndexScope,
          )) {
      throw StateError(
        'task.return result type does not match the current task.',
      );
    }
    if (!identical(
          _canonicalMemory(definition),
          _canonicalMemory(active.definition),
        ) ||
        WASIComponentCanonicalStringEncoding.fromCanonicalOptions(
              definition.options,
            ) !=
            _runtimeAdapterPlans[active.canonicalIndex]!.stringEncoding) {
      throw StateError(
        'task.return lift options do not match the current task.',
      );
    }
  }

  WASIComponentGuestCall _startLift(
    int canonicalIndex,
    WasmComponentCanonicalDefinition definition,
    List<Object?> Function() loadArgs,
    WASIComponentSubtask? subtask,
    void Function(Object? value)? onResolve,
  ) {
    final isAsync = _canonicalFunctionIsAsync(definition);
    final isAsyncTask =
        isAsync || _runtimeAdapterPlans[canonicalIndex]!.functionType.isAsync;
    final callbackIndex = _canonicalOptionIndex(
      definition,
      WasmComponentCanonicalOptionKind.callback,
    );
    if (isAsync &&
        (callbackIndex == null || callbackIndex >= _coreFunctions.length)) {
      throw WASIPreview2ComponentExecutionException(
        'Canonical async lift $canonicalIndex requires a valid callback.',
      );
    }
    final host = _componentHost.canonicalHost;
    final task = isAsyncTask
        ? host.taskHost.createTask(
            name: 'canonical[$canonicalIndex].lift',
            subtask: subtask,
          )
        : null;
    final lease = _componentHost.table.retainCanonicalScope();
    late WASIComponentGuestCall call;
    call = _store.start(
      instance: this,
      exclusive: isAsyncTask,
      backpressure: isAsyncTask ? host.asyncHost.backpressure : null,
      cancelBeforeStart: () {
        task!.deliverCancellation();
        task.cancel();
      },
      onExit: () {
        if (task != null) host.waitableHost.releaseTask(task);
        lease?.release();
      },
      body: (execution) {
        task?.bindCanonicalExecution(
          liftResult: (raw) {
            _requireMayLeave(canonicalIndex);
            if (isAsync) _handles.requireNoCallBorrows();
            final snapshot = !isAsync
                ? raw
                : _adapterProgram.finishAsyncLiftResult(
                    canonicalIndex,
                    raw,
                    memory: _canonicalMemory(definition),
                  );
            onResolve?.call(snapshot);
            return snapshot;
          },
          onResolved: (value) => execution.resolve(value),
        );
        return runZoned(
          () => _handles.withThread(
            () => _handles.withHandleCall(() async {
              if (!isAsync) {
                Future<void> invoke() async {
                  task?.markStarted();
                  final value = await _adapterProgram.invokeLiftedCoreAsync(
                    canonicalIndex,
                    loadArgs(),
                    memory: _canonicalMemory(definition),
                    realloc: _canonicalRealloc(definition),
                  );
                  if (task != null) {
                    task.returnResult(
                      result: value,
                      hasResult:
                          _runtimeAdapterPlans[canonicalIndex]!.result != null,
                    );
                  } else {
                    onResolve?.call(value);
                    execution.resolve(value);
                  }
                }

                if (task == null) {
                  await invoke();
                } else {
                  await host.taskHost.runWithTaskAsync(task, invoke);
                }
                return;
              }
              await host.taskHost.runWithTaskAsync(task!, () async {
                task.markStarted();
                final coreArgs = _adapterProgram.prepareAsyncLiftCoreArgs(
                  canonicalIndex,
                  loadArgs(),
                  memory: _canonicalMemory(definition),
                  realloc: _canonicalRealloc(definition),
                );
                var packed = _asyncCallbackResult(
                  await _coreFunctions[definition.coreFunctionIndex!].invoke(
                    coreArgs,
                  ),
                  canonicalIndex,
                );
                while ((packed & 0xf) != 0) {
                  final code = packed & 0xf;
                  execution.releaseExclusive();
                  final Future<WASIComponentWaitableEvent> pending;
                  switch (code) {
                    case 1:
                      pending = host.threadHost
                          .threadYield(cancellable: true)
                          .then(
                            (status) => status == 0
                                ? WASIComponentWaitableEvent.none
                                : WASIComponentWaitableEvent.taskCancelled,
                          );
                    case 2:
                      pending = host.waitableHost.waitableSetWait(
                        _handles.host(
                          packed >>> 4,
                          kind: WASIComponentCanonicalHandleKind.waitableSet,
                        ),
                        cancellable: true,
                      );
                    default:
                      throw WASIPreview2ComponentExecutionException(
                        'Canonical async lift $canonicalIndex returned unsupported callback code $code.',
                      );
                  }
                  final event = _handles.event(await execution.wait(pending));
                  packed = _asyncCallbackResult(
                    await _coreFunctions[callbackIndex!].invoke([
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
              });
            }, internalCall: onResolve != null ? true : null),
          ),
          zoneValues: {
            _liftDefinitionKey: (
              canonicalIndex: canonicalIndex,
              definition: definition,
              task: task,
            ),
          },
        );
      },
    );
    subtask?.addCancellationListener((_) => call.cancelBeforeStart());
    return call;
  }

  Future<Object?> _invokeLower(
    int canonicalIndex,
    WasmComponentCanonicalDefinition definition,
    List<Object?> coreArgs,
  ) async {
    _store.check();
    _requireMayLeave(canonicalIndex);
    final function = _componentFunctions[definition.functionIndex!];
    final start = function.start;
    final isAsync = _canonicalFunctionIsAsync(definition);
    if (start == null) {
      throw StateError('Component function has no canonical execution entry.');
    }
    final callerZone = Zone.current;
    final subtask = isAsync
        ? WASIComponentSubtask(name: 'canonical[$canonicalIndex].lower')
        : null;
    WASIComponentCanonicalAsyncLowerCall? lowering;
    List<Object?>? flatResult;
    final execution = start(
      () => callerZone.run(() {
        final prepared = _adapterProgram.prepareCanonicalLowerCore(
          canonicalIndex,
          coreArgs,
          memory: _canonicalMemory(definition),
          realloc: _canonicalRealloc(definition),
        );
        lowering = prepared;
        if (subtask != null) {
          subtask.retainCanonicalBorrows(
            _store.retainDelivery(prepared.releaseCanonicalBorrows),
          );
        }
        return prepared.result as List<Object?>;
      }),
      subtask,
      (value) => callerZone.run(() {
        flatResult = lowering!.completeCanonicalCore(value);
      }),
      () => lowering,
    );
    try {
      await execution.initialHandoff;
      _store.check();
      if (!isAsync) {
        await execution.result();
        return _coreHostResult(flatResult!);
      }
      if (subtask!.resolved) return subtask.deliverCanonicalResolve();
      final handle = _handles.add(
        _componentHost.canonicalHost.subtaskHost.insertSubtask(subtask),
        WASIComponentCanonicalHandleKind.subtask,
      );
      return subtask.state.code | (handle << 4);
    } finally {
      if (_store.stopped) {
        // The caller may observe abort before an opaque callback has stopped
        // using its arguments. Its stack and borrower scope must outlive it.
        await execution.bodyDone;
        lowering?.releaseCanonicalBorrows();
      } else if (!isAsync) {
        lowering?.releaseCanonicalBorrows();
      }
    }
  }

  WASIComponentGuestCall _startHostCall(
    String name,
    WASIComponentWitAdapterCallback callback,
    List<Object?> Function() loadArgs,
    WASIComponentSubtask? subtask,
    void Function(Object? value)? onResolve,
    WASIComponentCanonicalAsyncLowerCall? Function() lowering,
  ) {
    final host = _componentHost.canonicalHost;
    final task = host.taskHost.createTask(name: name, subtask: subtask);
    final lease = _componentHost.table.retainCanonicalScope();
    late WASIComponentGuestCall call;
    call = _store.start(
      instance: callback,
      // Synchronous host failures first acquire their Core execution context.
      lockOnFailure: subtask != null,
      cancelBeforeStart: () {
        task.deliverCancellation();
        task.cancel();
      },
      onExit: () {
        if (_store.stopped) lowering()?.releaseCanonicalBorrows();
        lease?.release();
      },
      body: (execution) => host.taskHost.runWithTaskAsync(task, () async {
        task.bindCanonicalExecution(
          liftResult: (value) {
            onResolve?.call(value);
            return value;
          },
          onResolved: execution.resolve,
        );
        task.markStarted();
        final pending = callback(loadArgs());
        final Object? value;
        if (pending is Future) {
          final boundary = lowering();
          final mustSettle =
              boundary?.requiresCanonicalCallbackSettlement ?? false;
          final ({bool cancelled, Object? value}) outcome;
          try {
            outcome = await execution.wait(
              Future.any<({bool cancelled, Object? value})>([
                pending.then((value) => (cancelled: false, value: value)),
                task.whenCancellationRequested.then(
                  (_) => (cancelled: true, value: null),
                ),
              ]),
              abortable: !mustSettle,
            );
          } catch (error, stack) {
            if (mustSettle) {
              try {
                boundary?.discardCanonicalResult(await pending);
              } catch (_) {}
            }
            Error.throwWithStackTrace(error, stack);
          }
          if (outcome.cancelled) {
            if (mustSettle) {
              try {
                boundary?.discardCanonicalResult(
                  await execution.wait(pending, abortable: false),
                );
              } catch (_) {}
            }
            task.deliverCancellation();
            task.cancel();
            return;
          }
          value = outcome.value;
        } else {
          value = pending;
        }
        task.returnResult(result: value, hasResult: value != null);
      }),
    );
    subtask?.addCancellationListener((_) => call.cancelBeforeStart());
    return call;
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
          // Generic imports are FutureOr and must stay on the async pipeline
          // even when the Core module's static call analysis permits sync.
          allowSynchronousImports:
              _genericHost == null && _preview3Host == null,
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
                export.name: _componentFunctions[export.sort.index],
          }),
          types: Map.unmodifiable({
            for (final export in instance.exports)
              if (export.sort.kind == WasmComponentSortKind.componentType)
                export.name: _visibleTypes[export.sort.index],
          }),
          resources: Map.unmodifiable({
            for (final export in instance.exports)
              if (export.sort.kind == WasmComponentSortKind.componentType &&
                  _visibleResources[export.sort.index] != null)
                export.name: _visibleResources[export.sort.index]!,
          }),
          resourceTypeNames: Map.unmodifiable({
            for (final export in instance.exports)
              if (export.sort.kind == WasmComponentSortKind.componentType &&
                  _visibleResourceTypeNames[export.sort.index] != null)
                export.name: _visibleResourceTypeNames[export.sort.index]!,
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
    if (nested.starts.isNotEmpty) {
      throw const WASIPreview2ComponentExecutionException(
        'Nested Component starts are not executable yet.',
      );
    }
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
            resourceIdentity: _visibleResources[argument.sort.index],
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

    final child = WASIComponentNativeRuntime._nested(
      component: nested,
      parent: this,
      arguments: _NestedComponentArguments(
        functions: suppliedFunctions,
        instances: suppliedInstances,
        types: suppliedTypes,
      ),
    );
    child._initialize();
    if (child._exportedInstances.isNotEmpty) {
      throw const WASIPreview2ComponentExecutionException(
        'Nested component instance exports are not executable yet.',
      );
    }
    return _ComponentInstance(
      functions: Map.unmodifiable(child._exportedFunctions),
      types: Map.unmodifiable(child._exportedTypes),
      resourceTypeNames: Map.unmodifiable(child._exportedResourceTypeNames),
      resources: Map.unmodifiable(child._exportedResources),
    );
  }

  void _addExport(WasmComponentExport export) {
    final name = export.name;
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
        _exportedTypes[name] = _visibleTypes[export.sort.index];
        final resourceTypeName = _visibleResourceTypeNames[export.sort.index];
        if (resourceTypeName != null) {
          _exportedResourceTypeNames[name] = resourceTypeName;
        }
        final runtimeResource = _visibleResources[export.sort.index];
        if (runtimeResource != null) _exportedResources[name] = runtimeResource;
        _visibleTypes.add(_visibleTypes[export.sort.index]);
        _visibleResourceTypeNames.add(
          _visibleResourceTypeNames[export.sort.index],
        );
        _addVisibleResourceIdentity(runtimeResource);
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

  _ComponentFunction _startFunction(WasmComponentStart start) {
    if (start.arguments.isNotEmpty || start.resultCount != 0) {
      throw const WASIPreview2ComponentExecutionException(
        'Component starts with values are not executable in the Preview2 runner yet.',
      );
    }
    return _componentFunctions[start.functionIndex];
  }

  void _runStart(WasmComponentStart start) {
    final result = _startFunction(start).invokeSynchronously(const <Object?>[]);
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
    for (final name in const ['wasi:cli/run@0.3.1', 'wasi:cli/run@0.3.0']) {
      final run =
          _exportedInstances[name]?.functions['run'] ??
          _exportedFunctions[name];
      if (run != null) {
        return run;
      }
    }
    throw const WASIPreview2ComponentExecutionException(
      'Component does not export wasi:cli/run@0.3.0 or @0.3.1.',
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
    for (final name in const [
      'wasi:http/handler@0.3.1',
      'wasi:http/handler@0.3.0',
    ]) {
      final handle =
          _exportedInstances[name]?.functions['handle'] ??
          _exportedFunctions[name];
      if (handle != null) {
        return handle;
      }
    }
    throw const WASIPreview2ComponentExecutionException(
      'Component does not export wasi:http/handler@0.3.0 or @0.3.1.',
    );
  }

  bool _isPreview2RunExport(String name) {
    return RegExp(r'^wasi:cli/run@0\.2\.\d+$').hasMatch(name);
  }

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
              supportsSyncImport: runtime.exportedFunctionSupportsSync(name),
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
    this.resources,
    this.isHost = false,
    this.start,
    this.validateArgs,
  });

  final WASIComponentGuestCall Function(
    List<Object?> Function() loadArgs,
    WASIComponentSubtask? subtask,
    void Function(Object? value)? onResolve,
    WASIComponentCanonicalAsyncLowerCall? Function() lowering,
  )?
  start;
  final void Function(List<Object?> args)? validateArgs;
  final bool isHost;
  final List<WASIComponentCanonicalResourceIdentity> Function()? resources;
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
    this.resources = const {},
  });

  final Map<String, _ComponentFunction> functions;
  final Map<String, WasmComponentTypeDefinition> types;
  final Map<String, String> resourceTypeNames;
  final Map<String, WASIComponentCanonicalResourceIdentity> resources;
}

final class _NestedComponentArguments {
  const _NestedComponentArguments({
    required this.functions,
    required this.instances,
    required this.types,
  });

  final Map<String, _ComponentFunction> functions;
  final Map<String, _ComponentInstance> instances;
  final Map<String, _NestedComponentType> types;
}

final class _NestedComponentType {
  const _NestedComponentType({
    required this.definition,
    required this.resourceTypeName,
    this.resourceIdentity,
  });

  final WasmComponentTypeDefinition definition;
  final String? resourceTypeName;
  final WASIComponentCanonicalResourceIdentity? resourceIdentity;
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
  if (interfaceName.endsWith('@0.3.1')) {
    final alias = _preview3ResourceTypeAliases['$interfaceName.$resourceName'];
    if (alias != null) {
      return alias;
    }
  }
  final versionedInterface = interfaceName.replaceFirst(
    RegExp(r'@0\.2\.\d+$'),
    '@0.2.0',
  );
  return '$versionedInterface.$resourceName';
}

const _preview3ResourceTypeAliases = <String, String>{
  'wasi:cli/terminal-input@0.3.1.terminal-input':
      'wasi:cli/terminal-input@0.3.0.terminal-input',
  'wasi:cli/terminal-output@0.3.1.terminal-output':
      'wasi:cli/terminal-output@0.3.0.terminal-output',
  'wasi:filesystem/types@0.3.1.descriptor':
      'wasi:filesystem/types@0.3.0.descriptor',
  'wasi:sockets/types@0.3.1.tcp-socket': 'wasi:sockets/types@0.3.0.tcp-socket',
  'wasi:sockets/types@0.3.1.udp-socket': 'wasi:sockets/types@0.3.0.udp-socket',
  'wasi:http/types@0.3.1.fields': 'wasi:http/types@0.3.0.fields',
  'wasi:http/types@0.3.1.request': 'wasi:http/types@0.3.0.request',
  'wasi:http/types@0.3.1.request-options':
      'wasi:http/types@0.3.0.request-options',
  'wasi:http/types@0.3.1.response': 'wasi:http/types@0.3.0.response',
};

String _formatErrors(String header, Iterable<Object> errors) {
  final buffer = StringBuffer(header);
  for (final error in errors) {
    buffer
      ..write('\n- ')
      ..write(error);
  }
  return buffer.toString();
}
