import '../component/adapter_host.dart';
import '../component/async_host.dart';
import '../component/async_values.dart';
import '../component/canonical_host.dart';
import '../component/host.dart';
import '../component/resource_host.dart';
import '../component/resource_table.dart';
import '../component/versioned_host.dart';
import '../component/wit_adapter.dart';
import '../component/wit_document.dart';
import '../preview2/component_host.dart';
import '../preview2/io.dart';
import '../version.dart';
import '../../wasm/backend/native/interpreter/component.dart';
import 'cli.dart';
import 'clocks.dart';
import 'filesystem.dart';
import 'http.dart';
import 'random.dart';
import 'sockets.dart';
import 'native/default_hosts_stub.dart'
    if (dart.library.io) 'native/default_hosts.dart'
    as native_defaults;

/// WASI 0.3 / Preview3 component host boundary.
///
/// This fixed-version wrapper keeps Preview3 adapter code on the async-aware
/// component profile while host capability gaps remain explicitly reported.
final class WASIPreview3ComponentHost {
  /// Creates a Preview3 component host over [componentHost] or a new host.
  ///
  /// On the Dart VM, default filesystem, sockets, and HTTP clients use
  /// `dart:io`. Other runtimes receive portable hosts that report unsupported
  /// operations explicitly. Preview2 compatibility imports are included for
  /// the adapters embedded in official Preview3 components.
  factory WASIPreview3ComponentHost({
    WASIComponentHost? componentHost,
    WASIPreview2ComponentHost? preview2CompatibilityHost,
    WASIPreview3CliHost? cliHost,
    WASIPreview3ClocksHost? clocksHost,
    WASIPreview3FilesystemHost? filesystemHost,
    WASIPreview3HttpHost? httpHost,
    WASIPreview3RandomHost? randomHost,
    WASIPreview3SocketsHost? socketsHost,
    List<String> args = const <String>[],
    Map<String, String> env = const <String, String>{},
    String? initialCwd,
    List<int> stdinData = const <int>[],
    WASIComponentReadableStream<int>? stdin,
    WASIPreview3CliOutputHandler? stdout,
    WASIPreview3CliOutputHandler? stderr,
    Map<String, String> preopens = const <String, String>{},
    bool canMutatePreopens = false,
    bool? terminalStdin,
    bool? terminalStdout,
    bool? terminalStderr,
    WASIPreview3AddressResolver? resolveAddresses,
    WASIPreview3HttpBackend? handlerBackend,
  }) => _createPreview3ComponentHost(
    native: false,
    componentHost: componentHost,
    preview2CompatibilityHost: preview2CompatibilityHost,
    cliHost: cliHost,
    clocksHost: clocksHost,
    filesystemHost: filesystemHost,
    httpHost: httpHost,
    randomHost: randomHost,
    socketsHost: socketsHost,
    args: args,
    env: env,
    initialCwd: initialCwd,
    stdinData: stdinData,
    stdin: stdin,
    stdout: stdout,
    stderr: stderr,
    preopens: preopens,
    canMutatePreopens: canMutatePreopens,
    terminalStdin: terminalStdin,
    terminalStdout: terminalStdout,
    terminalStderr: terminalStderr,
    resolveAddresses: resolveAddresses,
    handlerBackend: handlerBackend,
  );

  /// Creates a Dart VM-native Preview3 component host.
  ///
  /// This factory requires `dart:io` and wires all standard Preview3 hosts and
  /// the Preview2 compatibility adapters through one component resource table.
  factory WASIPreview3ComponentHost.native({
    WASIComponentHost? componentHost,
    WASIPreview2ComponentHost? preview2CompatibilityHost,
    WASIPreview3CliHost? cliHost,
    WASIPreview3ClocksHost? clocksHost,
    WASIPreview3FilesystemHost? filesystemHost,
    WASIPreview3HttpHost? httpHost,
    WASIPreview3RandomHost? randomHost,
    WASIPreview3SocketsHost? socketsHost,
    List<String> args = const <String>[],
    Map<String, String> env = const <String, String>{},
    String? initialCwd,
    List<int> stdinData = const <int>[],
    WASIComponentReadableStream<int>? stdin,
    WASIPreview3CliOutputHandler? stdout,
    WASIPreview3CliOutputHandler? stderr,
    Map<String, String> preopens = const <String, String>{},
    bool canMutatePreopens = false,
    bool? terminalStdin,
    bool? terminalStdout,
    bool? terminalStderr,
    WASIPreview3AddressResolver? resolveAddresses,
    WASIPreview3HttpBackend? handlerBackend,
  }) => _createPreview3ComponentHost(
    native: true,
    componentHost: componentHost,
    preview2CompatibilityHost: preview2CompatibilityHost,
    cliHost: cliHost,
    clocksHost: clocksHost,
    filesystemHost: filesystemHost,
    httpHost: httpHost,
    randomHost: randomHost,
    socketsHost: socketsHost,
    args: args,
    env: env,
    initialCwd: initialCwd,
    stdinData: stdinData,
    stdin: stdin,
    stdout: stdout,
    stderr: stderr,
    preopens: preopens,
    canMutatePreopens: canMutatePreopens,
    terminalStdin: terminalStdin,
    terminalStdout: terminalStdout,
    terminalStderr: terminalStderr,
    resolveAddresses: resolveAddresses,
    handlerBackend: handlerBackend,
  );

  WASIPreview3ComponentHost._({
    required this.versionedHost,
    required WASIPreview2ComponentHost preview2CompatibilityHost,
    required WASIPreview3RandomHost randomHost,
    required WASIPreview3ClocksHost clocksHost,
    required WASIPreview3CliHost cliHost,
    required WASIPreview3FilesystemHost filesystemHost,
    required WASIPreview3SocketsHost socketsHost,
    required WASIPreview3HttpHost httpHost,
  }) : _preview2CompatibilityHost = preview2CompatibilityHost,
       _randomHost = randomHost,
       _clocksHost = clocksHost,
       _cliHost = cliHost,
       _filesystemHost = filesystemHost,
       _socketsHost = socketsHost,
       _httpHost = httpHost;

  /// Underlying versioned component-host facade.
  final WASIComponentVersionedHost versionedHost;

  final WASIPreview2ComponentHost _preview2CompatibilityHost;
  final WASIPreview3RandomHost _randomHost;
  final WASIPreview3ClocksHost _clocksHost;
  final WASIPreview3CliHost _cliHost;
  final WASIPreview3FilesystemHost _filesystemHost;
  final WASIPreview3SocketsHost _socketsHost;
  final WASIPreview3HttpHost _httpHost;

  /// Preview3 version profile.
  WASIComponentVersionProfile get profile => versionedHost.profile;

  /// Shared component host.
  WASIComponentHost get componentHost => versionedHost.componentHost;

  /// Preview2 imports used by adapters embedded in Preview3 components.
  WASIPreview2ComponentHost get preview2CompatibilityHost =>
      _preview2CompatibilityHost;

  /// Random host state for standard `wasi:random` imports.
  WASIPreview3RandomHost get randomHost => _randomHost;

  /// Clocks host state for standard `wasi:clocks` imports.
  WASIPreview3ClocksHost get clocksHost => _clocksHost;

  /// CLI host state and captured stdio for standard `wasi:cli` imports.
  WASIPreview3CliHost get cliHost => _cliHost;

  /// Filesystem host state for standard `wasi:filesystem` imports.
  WASIPreview3FilesystemHost get filesystemHost => _filesystemHost;

  /// Sockets host state for standard `wasi:sockets` imports.
  WASIPreview3SocketsHost get socketsHost => _socketsHost;

  /// HTTP host state for standard `wasi:http` imports.
  WASIPreview3HttpHost get httpHost => _httpHost;

  /// Standard Preview3 WIT import callbacks implemented by this host.
  late final Map<String, WASIComponentWitAdapterCallback> standardImports =
      Map<String, WASIComponentWitAdapterCallback>.unmodifiable({
        ..._preview2CompatibilityHost.standardImports,
        ..._randomHost.imports,
        ..._clocksHost.imports,
        ..._cliHost.imports,
        ..._filesystemHost.imports,
        ..._socketsHost.imports,
        ..._httpHost.imports,
      });

  /// Prepares [component] for Preview3 component-host binding.
  WASIComponentVersionedBindingPlan prepareComponent(
    WasmComponent component, {
    bool validate = true,
  }) {
    return versionedHost.prepareComponent(component, validate: validate);
  }

  /// Prepares a WIT world for Preview3 adapter binding.
  WASIComponentVersionedWitWorldPlan prepareWitWorld(
    WASIComponentWitDocument document, {
    String? worldName,
  }) {
    return versionedHost.prepareWitWorld(document, worldName: worldName);
  }

  /// Prepares and binds a Preview3 WIT world.
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

  /// Prepares and binds Preview3 canonical `lift`/`lower` adapter operations.
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

  /// Prepares and binds [component] through the Preview3 profile.
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

WASIPreview3ComponentHost _createPreview3ComponentHost({
  required bool native,
  required WASIComponentHost? componentHost,
  required WASIPreview2ComponentHost? preview2CompatibilityHost,
  required WASIPreview3CliHost? cliHost,
  required WASIPreview3ClocksHost? clocksHost,
  required WASIPreview3FilesystemHost? filesystemHost,
  required WASIPreview3HttpHost? httpHost,
  required WASIPreview3RandomHost? randomHost,
  required WASIPreview3SocketsHost? socketsHost,
  required List<String> args,
  required Map<String, String> env,
  required String? initialCwd,
  required List<int> stdinData,
  required WASIComponentReadableStream<int>? stdin,
  required WASIPreview3CliOutputHandler? stdout,
  required WASIPreview3CliOutputHandler? stderr,
  required Map<String, String> preopens,
  required bool canMutatePreopens,
  required bool? terminalStdin,
  required bool? terminalStdout,
  required bool? terminalStderr,
  required WASIPreview3AddressResolver? resolveAddresses,
  required WASIPreview3HttpBackend? handlerBackend,
}) {
  final host = _resolvePreview3ComponentHost(
    componentHost: componentHost,
    preview2CompatibilityHost: preview2CompatibilityHost,
    filesystemHost: filesystemHost,
    httpHost: httpHost,
    socketsHost: socketsHost,
  );
  final compatibilityStdout = _preview2OutputStream(stdout);
  final compatibilityStderr = _preview2OutputStream(stderr);
  final compatibilityHost =
      preview2CompatibilityHost ??
      (native
          ? WASIPreview2ComponentHost.native(
              componentHost: host,
              args: args,
              env: env,
              initialCwd: initialCwd,
              stdinData: stdinData,
              stdout: compatibilityStdout,
              stderr: compatibilityStderr,
              preopens: preopens,
              canMutatePreopens: canMutatePreopens,
              terminalStdin: terminalStdin,
              terminalStdout: terminalStdout,
              terminalStderr: terminalStderr,
            )
          : WASIPreview2ComponentHost(
              componentHost: host,
              args: args,
              env: env,
              initialCwd: initialCwd,
              stdinData: stdinData,
              stdout: compatibilityStdout,
              stderr: compatibilityStderr,
              preopens: preopens,
              canMutatePreopens: canMutatePreopens,
              terminalStdin: terminalStdin,
              terminalStdout: terminalStdout,
              terminalStderr: terminalStderr,
            ));
  final resolvedFilesystemHost =
      filesystemHost ??
      (native
          ? native_defaults.createNativePreview3FilesystemHost(
              preopens: preopens,
              canMutate: canMutatePreopens,
              table: host.table,
            )
          : native_defaults.createDefaultPreview3FilesystemHost(
              preopens: preopens,
              canMutate: canMutatePreopens,
              table: host.table,
            ));
  final resolvedSocketsHost =
      socketsHost ??
      (native
          ? native_defaults.createNativePreview3SocketsHost(
              table: host.table,
              resolveAddresses: resolveAddresses,
            )
          : native_defaults.createDefaultPreview3SocketsHost(
              table: host.table,
              resolveAddresses: resolveAddresses,
            ));
  final resolvedHttpHost =
      httpHost ??
      (native
          ? native_defaults.createNativePreview3HttpHost(
              table: host.table,
              handlerBackend: handlerBackend,
            )
          : native_defaults.createDefaultPreview3HttpHost(
              table: host.table,
              handlerBackend: handlerBackend,
            ));

  return WASIPreview3ComponentHost._(
    versionedHost: WASIComponentVersionedHost(
      version: WASIVersion.preview3,
      componentHost: host,
    ),
    preview2CompatibilityHost: compatibilityHost,
    randomHost: randomHost ?? WASIPreview3RandomHost(),
    clocksHost: clocksHost ?? WASIPreview3ClocksHost(),
    cliHost:
        cliHost ??
        WASIPreview3CliHost(
          args: args,
          env: env,
          initialCwd: initialCwd,
          stdinData: stdinData,
          stdin: stdin,
          stdout: stdout,
          stderr: stderr,
        ),
    filesystemHost: resolvedFilesystemHost,
    socketsHost: resolvedSocketsHost,
    httpHost: resolvedHttpHost,
  );
}

WASIPreview2OutputStream? _preview2OutputStream(
  WASIPreview3CliOutputHandler? handler,
) {
  if (handler == null) {
    return null;
  }
  return WASIPreview2OutputStream(
    onWrite: (bytes) {
      handler(bytes);
      return null;
    },
  );
}

WASIComponentHost _resolvePreview3ComponentHost({
  required WASIComponentHost? componentHost,
  required WASIPreview2ComponentHost? preview2CompatibilityHost,
  required WASIPreview3FilesystemHost? filesystemHost,
  required WASIPreview3HttpHost? httpHost,
  required WASIPreview3SocketsHost? socketsHost,
}) {
  if (componentHost != null &&
      preview2CompatibilityHost != null &&
      !identical(componentHost, preview2CompatibilityHost.componentHost)) {
    throw ArgumentError.value(
      preview2CompatibilityHost,
      'preview2CompatibilityHost',
      'must use the same component host as componentHost',
    );
  }
  final resolvedComponentHost =
      componentHost ?? preview2CompatibilityHost?.componentHost;
  final tables = <({String name, WASIComponentResourceTable table})>[
    if (resolvedComponentHost != null)
      (name: 'componentHost', table: resolvedComponentHost.table),
    if (filesystemHost != null)
      (name: 'filesystemHost', table: filesystemHost.table),
    if (socketsHost != null) (name: 'socketsHost', table: socketsHost.table),
    if (httpHost != null) (name: 'httpHost', table: httpHost.table),
  ];
  if (tables.isNotEmpty) {
    final expected = tables.first;
    for (final entry in tables.skip(1)) {
      if (!identical(entry.table, expected.table)) {
        throw ArgumentError.value(
          entry.table,
          entry.name,
          'must share the same component resource table as ${expected.name}',
        );
      }
    }
  }
  if (resolvedComponentHost != null) {
    return resolvedComponentHost;
  }
  if (tables.isEmpty) {
    return WASIComponentHost();
  }
  return WASIComponentHost(
    canonicalHost: WASIComponentCanonicalHost(table: tables.first.table),
  );
}
