import '../component/adapter_host.dart';
import '../component/async_host.dart';
import '../component/host.dart';
import '../component/resource_host.dart';
import '../component/versioned_host.dart';
import '../component/wit_adapter.dart';
import '../component/wit_document.dart';
import '../version.dart';
import '../../wasm/backend/native/interpreter/component.dart';
import 'random.dart';

/// WASI 0.2 / Preview2 component host boundary.
///
/// This fixed-version wrapper keeps Preview2 adapter code from constructing a
/// mixed-version component host by hand.
final class WASIPreview2ComponentHost {
  /// Creates a Preview2 component host over [componentHost] or a new host.
  WASIPreview2ComponentHost({
    WASIComponentHost? componentHost,
    WASIPreview2RandomHost? randomHost,
  }) : versionedHost = WASIComponentVersionedHost(
         version: WASIVersion.preview2,
         componentHost: componentHost,
       ),
       _randomHost = randomHost ?? WASIPreview2RandomHost();

  /// Underlying versioned component-host facade.
  final WASIComponentVersionedHost versionedHost;

  final WASIPreview2RandomHost _randomHost;

  /// Preview2 version profile.
  WASIComponentVersionProfile get profile => versionedHost.profile;

  /// Shared component host.
  WASIComponentHost get componentHost => versionedHost.componentHost;

  /// Random host state for standard `wasi:random` imports.
  WASIPreview2RandomHost get randomHost => _randomHost;

  /// Standard Preview2 WIT import callbacks implemented by this host.
  late final Map<String, WASIComponentWitAdapterCallback> standardImports =
      Map<String, WASIComponentWitAdapterCallback>.unmodifiable({
        ..._randomHost.imports,
      });

  /// Prepares [component] for Preview2 component-host binding.
  WASIComponentVersionedBindingPlan prepareComponent(
    WasmComponent component, {
    bool validate = true,
  }) {
    return versionedHost.prepareComponent(component, validate: validate);
  }

  /// Prepares a WIT world for Preview2 adapter binding.
  WASIComponentVersionedWitWorldPlan prepareWitWorld(
    WASIComponentWitDocument document, {
    String? worldName,
  }) {
    return versionedHost.prepareWitWorld(document, worldName: worldName);
  }

  /// Prepares and binds a Preview2 WIT world.
  ///
  /// Built-in standard WASI imports are supplied by default and can be
  /// overridden by passing the same key in [imports].
  WASIComponentWitAdapterProgram bindWitWorld(
    WASIComponentWitDocument document, {
    String? worldName,
    Map<String, WASIComponentWitAdapterCallback> imports =
        const <String, WASIComponentWitAdapterCallback>{},
    Map<String, WASIComponentWitAdapterCallback> exports =
        const <String, WASIComponentWitAdapterCallback>{},
  }) {
    return versionedHost.bindWitWorld(
      document,
      worldName: worldName,
      imports: <String, WASIComponentWitAdapterCallback>{
        ...standardImports,
        ...imports,
      },
      exports: exports,
    );
  }

  /// Prepares and binds Preview2 canonical `lift`/`lower` adapter operations.
  WASIComponentCanonicalAdapterProgram bindAdapters(
    WasmComponent component, {
    bool validate = true,
    Map<int, WASIComponentCanonicalAdapterCallback> coreFunctions =
        const <int, WASIComponentCanonicalAdapterCallback>{},
    Map<int, WASIComponentCanonicalAdapterCallback> componentFunctions =
        const <int, WASIComponentCanonicalAdapterCallback>{},
  }) {
    return versionedHost.bindAdapters(
      component,
      validate: validate,
      coreFunctions: coreFunctions,
      componentFunctions: componentFunctions,
    );
  }

  /// Prepares and binds [component] through the Preview2 profile.
  WASIComponentHostBinding bindComponent(
    WasmComponent component, {
    bool validate = true,
    Map<int, WASIComponentCanonicalAdapterCallback> coreFunctions =
        const <int, WASIComponentCanonicalAdapterCallback>{},
    Map<int, WASIComponentCanonicalAdapterCallback> componentFunctions =
        const <int, WASIComponentCanonicalAdapterCallback>{},
    String Function(WASIComponentResourceBinding binding)? resourceName,
    void Function(WASIComponentResourceBinding binding, Object resource)?
    onResourceDrop,
    String Function(WASIComponentAsyncValueBinding binding)? asyncValueName,
    int? Function(WASIComponentAsyncValueBinding binding)?
    maxBufferedElementsForStream,
    void Function(WASIComponentAsyncValueBinding binding)? onAsyncValueDrop,
  }) {
    return versionedHost.bindComponent(
      component,
      validate: validate,
      coreFunctions: coreFunctions,
      componentFunctions: componentFunctions,
      resourceName: resourceName,
      onResourceDrop: onResourceDrop,
      asyncValueName: asyncValueName,
      maxBufferedElementsForStream: maxBufferedElementsForStream,
      onAsyncValueDrop: onAsyncValueDrop,
    );
  }
}
