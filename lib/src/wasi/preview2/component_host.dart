import '../component/adapter_host.dart';
import '../component/async_host.dart';
import '../component/host.dart';
import '../component/resource_host.dart';
import '../component/versioned_host.dart';
import '../component/wit_adapter.dart';
import '../component/wit_document.dart';
import '../version.dart';
import '../../wasm/backend/native/interpreter/component.dart';
import 'clocks.dart';
import 'io.dart';
import 'poll.dart';
import 'random.dart';

/// WASI 0.2 / Preview2 component host boundary.
///
/// This fixed-version wrapper keeps Preview2 adapter code from constructing a
/// mixed-version component host by hand.
final class WASIPreview2ComponentHost {
  /// Creates a Preview2 component host over [componentHost] or a new host.
  WASIPreview2ComponentHost({
    WASIComponentHost? componentHost,
    WASIPreview2ClocksHost? clocksHost,
    WASIPreview2IoErrorHost? errorHost,
    WASIPreview2PollHost? pollHost,
    WASIPreview2RandomHost? randomHost,
    WASIPreview2StreamsHost? streamsHost,
  }) : assert(
         pollHost == null ||
             clocksHost == null ||
             identical(pollHost, clocksHost.pollHost),
         'clocksHost and pollHost must share the same Preview2 poll host.',
       ),
       assert(
         pollHost == null ||
             streamsHost == null ||
             identical(pollHost, streamsHost.pollHost),
         'streamsHost and pollHost must share the same Preview2 poll host.',
       ),
       assert(
         errorHost == null ||
             streamsHost == null ||
             identical(errorHost, streamsHost.errorHost),
         'streamsHost and errorHost must share the same Preview2 error host.',
       ),
       versionedHost = WASIComponentVersionedHost(
         version: WASIVersion.preview2,
         componentHost: componentHost,
       ),
       _clocksHostOverride = clocksHost,
       _errorHostOverride = errorHost,
       _pollHostOverride = pollHost,
       _randomHost = randomHost ?? WASIPreview2RandomHost(),
       _streamsHostOverride = streamsHost;

  /// Underlying versioned component-host facade.
  final WASIComponentVersionedHost versionedHost;

  final WASIPreview2ClocksHost? _clocksHostOverride;
  final WASIPreview2IoErrorHost? _errorHostOverride;
  final WASIPreview2PollHost? _pollHostOverride;
  final WASIPreview2RandomHost _randomHost;
  final WASIPreview2StreamsHost? _streamsHostOverride;
  late final WASIPreview2PollHost _pollHost =
      _clocksHostOverride?.pollHost ??
      _streamsHostOverride?.pollHost ??
      _pollHostOverride ??
      WASIPreview2PollHost(table: componentHost.table);
  late final WASIPreview2IoErrorHost _errorHost =
      _streamsHostOverride?.errorHost ??
      _errorHostOverride ??
      WASIPreview2IoErrorHost(table: componentHost.table);
  late final WASIPreview2StreamsHost _streamsHost =
      _streamsHostOverride ??
      WASIPreview2StreamsHost(
        table: componentHost.table,
        pollHost: _pollHost,
        errorHost: _errorHost,
      );
  late final WASIPreview2ClocksHost _clocksHost =
      _clocksHostOverride ?? WASIPreview2ClocksHost(pollHost: _pollHost);

  /// Preview2 version profile.
  WASIComponentVersionProfile get profile => versionedHost.profile;

  /// Shared component host.
  WASIComponentHost get componentHost => versionedHost.componentHost;

  /// Random host state for standard `wasi:random` imports.
  WASIPreview2RandomHost get randomHost => _randomHost;

  /// Clocks host state for standard `wasi:clocks` imports.
  WASIPreview2ClocksHost get clocksHost => _clocksHost;

  /// Error host state for standard `wasi:io/error` imports.
  WASIPreview2IoErrorHost get errorHost => _errorHost;

  /// Poll host state for standard `wasi:io/poll` imports.
  WASIPreview2PollHost get pollHost => _pollHost;

  /// Streams host state for standard `wasi:io/streams` imports.
  WASIPreview2StreamsHost get streamsHost => _streamsHost;

  /// Standard Preview2 WIT import callbacks implemented by this host.
  late final Map<String, WASIComponentWitAdapterCallback> standardImports =
      Map<String, WASIComponentWitAdapterCallback>.unmodifiable({
        ..._randomHost.imports,
        ..._errorHost.imports,
        ..._clocksHost.imports,
        ..._pollHost.imports,
        ..._streamsHost.imports,
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
