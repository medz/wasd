import '../component/adapter_host.dart';
import '../component/async_host.dart';
import '../component/host.dart';
import '../component/resource_host.dart';
import '../component/versioned_host.dart';
import '../component/wit_adapter.dart';
import '../component/wit_document.dart';
import '../version.dart';
import '../../wasm/backend/native/interpreter/component.dart';
import 'cli.dart';
import 'clocks.dart';
import 'filesystem.dart';
import 'http.dart';
import 'io.dart';
import 'poll.dart';
import 'random.dart';
import 'sockets.dart';
import 'native/default_hosts_stub.dart'
    if (dart.library.io) 'native/default_hosts.dart'
    as native_defaults;

/// WASI 0.2 / Preview2 component host boundary.
///
/// This fixed-version wrapper keeps Preview2 adapter code from constructing a
/// mixed-version component host by hand.
final class WASIPreview2ComponentHost {
  /// Creates a Dart VM-native Preview2 component host.
  ///
  /// The default constructor keeps a portable in-memory host for JS/browser
  /// runtimes. This factory wires filesystem, sockets, HTTP, CLI, streams,
  /// pollables, and errors through one shared component resource table on
  /// `dart:io` runtimes.
  factory WASIPreview2ComponentHost.native({
    WASIComponentHost? componentHost,
    List<String> args = const <String>[],
    Map<String, String> env = const <String, String>{},
    String? initialCwd,
    List<int> stdinData = const <int>[],
    Map<String, String> preopens = const <String, String>{},
    bool canMutatePreopens = false,
    bool? terminalStdin,
    bool? terminalStdout,
    bool? terminalStderr,
    WASIPreview2AddressResolver? resolveAddresses,
  }) {
    final host = componentHost ?? WASIComponentHost();
    final pollHost = WASIPreview2PollHost(table: host.table);
    final errorHost = WASIPreview2IoErrorHost(table: host.table);
    final streamsHost = WASIPreview2StreamsHost(
      table: host.table,
      pollHost: pollHost,
      errorHost: errorHost,
    );
    final cliHost = WASIPreview2CliHost(
      streamsHost: streamsHost,
      args: args,
      env: env,
      initialCwd: initialCwd,
      stdinData: stdinData,
      terminalStdin: terminalStdin ?? native_defaults.isNativeStdinTerminal(),
      terminalStdout:
          terminalStdout ?? native_defaults.isNativeStdoutTerminal(),
      terminalStderr:
          terminalStderr ?? native_defaults.isNativeStderrTerminal(),
    );

    return WASIPreview2ComponentHost(
      componentHost: host,
      pollHost: pollHost,
      errorHost: errorHost,
      streamsHost: streamsHost,
      clocksHost: WASIPreview2ClocksHost(pollHost: pollHost),
      cliHost: cliHost,
      filesystemHost: native_defaults.createNativePreview2FilesystemHost(
        preopens: preopens,
        canMutate: canMutatePreopens,
        streamsHost: streamsHost,
      ),
      socketsHost: native_defaults.createNativePreview2SocketsHost(
        pollHost: pollHost,
        streamsHost: streamsHost,
        resolveAddresses: resolveAddresses,
      ),
      httpHost: native_defaults.createNativePreview2HttpHost(
        pollHost: pollHost,
        streamsHost: streamsHost,
      ),
      randomHost: WASIPreview2RandomHost(),
    );
  }

  /// Creates a Preview2 component host over [componentHost] or a new host.
  WASIPreview2ComponentHost({
    WASIComponentHost? componentHost,
    WASIPreview2CliHost? cliHost,
    WASIPreview2ClocksHost? clocksHost,
    WASIPreview2IoErrorHost? errorHost,
    WASIPreview2FilesystemHost? filesystemHost,
    WASIPreview2HttpHost? httpHost,
    WASIPreview2PollHost? pollHost,
    WASIPreview2RandomHost? randomHost,
    WASIPreview2SocketsHost? socketsHost,
    WASIPreview2StreamsHost? streamsHost,
    List<String> args = const <String>[],
    Map<String, String> env = const <String, String>{},
    String? initialCwd,
    List<int> stdinData = const <int>[],
    Map<String, String> preopens = const <String, String>{},
    bool canMutatePreopens = false,
    bool? terminalStdin,
    bool? terminalStdout,
    bool? terminalStderr,
    WASIPreview2AddressResolver? resolveAddresses,
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
         clocksHost == null ||
             streamsHost == null ||
             identical(clocksHost.pollHost, streamsHost.pollHost),
         'clocksHost and streamsHost must share the same Preview2 poll host.',
       ),
       assert(
         errorHost == null ||
             streamsHost == null ||
             identical(errorHost, streamsHost.errorHost),
         'streamsHost and errorHost must share the same Preview2 error host.',
       ),
       assert(
         pollHost == null ||
             socketsHost == null ||
             identical(pollHost, socketsHost.pollHost),
         'socketsHost and pollHost must share the same Preview2 poll host.',
       ),
       assert(
         clocksHost == null ||
             socketsHost == null ||
             identical(clocksHost.pollHost, socketsHost.pollHost),
         'socketsHost and clocksHost must share the same Preview2 poll host.',
       ),
       assert(
         streamsHost == null ||
             socketsHost == null ||
             identical(streamsHost, socketsHost.streamsHost),
         'socketsHost and streamsHost must share the same Preview2 streams host.',
       ),
       assert(
         errorHost == null ||
             socketsHost == null ||
             identical(errorHost, socketsHost.streamsHost.errorHost),
         'socketsHost and errorHost must share the same Preview2 error host.',
       ),
       assert(
         streamsHost == null ||
             cliHost == null ||
             identical(streamsHost, cliHost.streamsHost),
         'cliHost and streamsHost must share the same Preview2 streams host.',
       ),
       assert(
         pollHost == null ||
             cliHost == null ||
             identical(pollHost, cliHost.streamsHost.pollHost),
         'cliHost and pollHost must share the same Preview2 poll host.',
       ),
       assert(
         errorHost == null ||
             cliHost == null ||
             identical(errorHost, cliHost.streamsHost.errorHost),
         'cliHost and errorHost must share the same Preview2 error host.',
       ),
       assert(
         clocksHost == null ||
             cliHost == null ||
             identical(clocksHost.pollHost, cliHost.streamsHost.pollHost),
         'cliHost and clocksHost must share the same Preview2 poll host.',
       ),
       assert(
         socketsHost == null ||
             cliHost == null ||
             identical(socketsHost.pollHost, cliHost.streamsHost.pollHost),
         'cliHost and socketsHost must share the same Preview2 poll host.',
       ),
       assert(
         streamsHost == null ||
             filesystemHost == null ||
             identical(streamsHost, filesystemHost.streamsHost),
         'filesystemHost and streamsHost must share the same Preview2 streams host.',
       ),
       assert(
         pollHost == null ||
             filesystemHost == null ||
             identical(pollHost, filesystemHost.streamsHost.pollHost),
         'filesystemHost and pollHost must share the same Preview2 poll host.',
       ),
       assert(
         errorHost == null ||
             filesystemHost == null ||
             identical(errorHost, filesystemHost.streamsHost.errorHost),
         'filesystemHost and errorHost must share the same Preview2 error host.',
       ),
       assert(
         clocksHost == null ||
             filesystemHost == null ||
             identical(
               clocksHost.pollHost,
               filesystemHost.streamsHost.pollHost,
             ),
         'filesystemHost and clocksHost must share the same Preview2 poll host.',
       ),
       assert(
         cliHost == null ||
             filesystemHost == null ||
             identical(cliHost.streamsHost, filesystemHost.streamsHost),
         'filesystemHost and cliHost must share the same Preview2 streams host.',
       ),
       assert(
         socketsHost == null ||
             filesystemHost == null ||
             identical(
               socketsHost.pollHost,
               filesystemHost.streamsHost.pollHost,
             ),
         'filesystemHost and socketsHost must share the same Preview2 poll host.',
       ),
       assert(
         pollHost == null ||
             httpHost == null ||
             identical(pollHost, httpHost.pollHost),
         'httpHost and pollHost must share the same Preview2 poll host.',
       ),
       assert(
         streamsHost == null ||
             httpHost == null ||
             identical(streamsHost, httpHost.streamsHost),
         'httpHost and streamsHost must share the same Preview2 streams host.',
       ),
       assert(
         errorHost == null ||
             httpHost == null ||
             identical(errorHost, httpHost.streamsHost.errorHost),
         'httpHost and errorHost must share the same Preview2 error host.',
       ),
       assert(
         clocksHost == null ||
             httpHost == null ||
             identical(clocksHost.pollHost, httpHost.pollHost),
         'httpHost and clocksHost must share the same Preview2 poll host.',
       ),
       assert(
         cliHost == null ||
             httpHost == null ||
             identical(cliHost.streamsHost, httpHost.streamsHost),
         'httpHost and cliHost must share the same Preview2 streams host.',
       ),
       assert(
         filesystemHost == null ||
             httpHost == null ||
             identical(filesystemHost.streamsHost, httpHost.streamsHost),
         'httpHost and filesystemHost must share the same Preview2 streams host.',
       ),
       assert(
         socketsHost == null ||
             httpHost == null ||
             identical(socketsHost.streamsHost, httpHost.streamsHost),
         'httpHost and socketsHost must share the same Preview2 streams host.',
       ),
       versionedHost = WASIComponentVersionedHost(
         version: WASIVersion.preview2,
         componentHost: componentHost,
       ),
       _cliHostOverride = cliHost,
       _cliArgs = List<String>.unmodifiable(args),
       _cliEnv = Map<String, String>.unmodifiable(env),
       _cliInitialCwd = initialCwd,
       _cliStdinData = List<int>.unmodifiable(stdinData),
       _cliTerminalStdin = terminalStdin,
       _cliTerminalStdout = terminalStdout,
       _cliTerminalStderr = terminalStderr,
       _filesystemPreopens = Map<String, String>.unmodifiable(preopens),
       _filesystemCanMutatePreopens = canMutatePreopens,
       _resolveAddresses = resolveAddresses,
       _clocksHostOverride = clocksHost,
       _errorHostOverride = errorHost,
       _filesystemHostOverride = filesystemHost,
       _httpHostOverride = httpHost,
       _pollHostOverride = pollHost,
       _randomHost = randomHost ?? WASIPreview2RandomHost(),
       _socketsHostOverride = socketsHost,
       _streamsHostOverride =
           streamsHost ??
           cliHost?.streamsHost ??
           filesystemHost?.streamsHost ??
           socketsHost?.streamsHost ??
           httpHost?.streamsHost;

  /// Underlying versioned component-host facade.
  final WASIComponentVersionedHost versionedHost;

  final WASIPreview2CliHost? _cliHostOverride;
  final List<String> _cliArgs;
  final Map<String, String> _cliEnv;
  final String? _cliInitialCwd;
  final List<int> _cliStdinData;
  final bool? _cliTerminalStdin;
  final bool? _cliTerminalStdout;
  final bool? _cliTerminalStderr;
  final Map<String, String> _filesystemPreopens;
  final bool _filesystemCanMutatePreopens;
  final WASIPreview2AddressResolver? _resolveAddresses;
  final WASIPreview2ClocksHost? _clocksHostOverride;
  final WASIPreview2IoErrorHost? _errorHostOverride;
  final WASIPreview2FilesystemHost? _filesystemHostOverride;
  final WASIPreview2HttpHost? _httpHostOverride;
  final WASIPreview2PollHost? _pollHostOverride;
  final WASIPreview2RandomHost _randomHost;
  final WASIPreview2SocketsHost? _socketsHostOverride;
  final WASIPreview2StreamsHost? _streamsHostOverride;
  late final WASIPreview2PollHost _pollHost =
      _clocksHostOverride?.pollHost ??
      _streamsHostOverride?.pollHost ??
      _socketsHostOverride?.pollHost ??
      _httpHostOverride?.pollHost ??
      _pollHostOverride ??
      WASIPreview2PollHost(table: componentHost.table);
  late final WASIPreview2IoErrorHost _errorHost =
      _streamsHostOverride?.errorHost ??
      _socketsHostOverride?.streamsHost.errorHost ??
      _httpHostOverride?.streamsHost.errorHost ??
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
  late final WASIPreview2CliHost _cliHost =
      _cliHostOverride ??
      WASIPreview2CliHost(
        streamsHost: _streamsHost,
        args: _cliArgs,
        env: _cliEnv,
        initialCwd: _cliInitialCwd,
        stdinData: _cliStdinData,
        terminalStdin:
            _cliTerminalStdin ?? native_defaults.isNativeStdinTerminal(),
        terminalStdout:
            _cliTerminalStdout ?? native_defaults.isNativeStdoutTerminal(),
        terminalStderr:
            _cliTerminalStderr ?? native_defaults.isNativeStderrTerminal(),
      );
  late final WASIPreview2FilesystemHost _filesystemHost =
      _filesystemHostOverride ??
      native_defaults.createDefaultPreview2FilesystemHost(
        preopens: _filesystemPreopens,
        canMutate: _filesystemCanMutatePreopens,
        streamsHost: _streamsHost,
      );
  late final WASIPreview2SocketsHost _socketsHost =
      _socketsHostOverride ??
      native_defaults.createDefaultPreview2SocketsHost(
        pollHost: _pollHost,
        streamsHost: _streamsHost,
        resolveAddresses: _resolveAddresses,
      );
  late final WASIPreview2HttpHost _httpHost =
      _httpHostOverride ??
      native_defaults.createDefaultPreview2HttpHost(
        pollHost: _pollHost,
        streamsHost: _streamsHost,
      );

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

  /// CLI host state and stdio resources for standard `wasi:cli` imports.
  WASIPreview2CliHost get cliHost => _cliHost;

  /// Filesystem host state for standard `wasi:filesystem` imports.
  WASIPreview2FilesystemHost get filesystemHost => _filesystemHost;

  /// Sockets host state for standard `wasi:sockets` imports.
  WASIPreview2SocketsHost get socketsHost => _socketsHost;

  /// HTTP host state for standard `wasi:http` imports.
  WASIPreview2HttpHost get httpHost => _httpHost;

  /// Standard Preview2 WIT import callbacks implemented by this host.
  late final Map<String, WASIComponentWitAdapterCallback> standardImports =
      Map<String, WASIComponentWitAdapterCallback>.unmodifiable(
        _withPreview2PatchAliases({
          ..._randomHost.imports,
          ..._errorHost.imports,
          ..._clocksHost.imports,
          ..._pollHost.imports,
          ..._streamsHost.imports,
          ..._cliHost.imports,
          ..._filesystemHost.imports,
          ..._socketsHost.imports,
          ..._httpHost.imports,
        }),
      );

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

Map<String, WASIComponentWitAdapterCallback> _withPreview2PatchAliases(
  Map<String, WASIComponentWitAdapterCallback> imports,
) {
  final result = <String, WASIComponentWitAdapterCallback>{...imports};
  for (final entry in imports.entries) {
    if (!entry.key.contains('@0.2.0')) {
      continue;
    }
    for (var patch = 1; patch <= 8; patch++) {
      result[entry.key.replaceAll('@0.2.0', '@0.2.$patch')] = entry.value;
    }
  }
  return result;
}
