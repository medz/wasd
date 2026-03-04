import '../wasm/instance.dart';
import '../wasm/memory.dart';
import '../wasm/module.dart';
import 'version.dart';
import 'preview1/native/wasi.dart'
    if (dart.library.js_interop) 'preview1/js/wasi.dart'
    as backend;

export 'version.dart';

/// Minimal WASI runtime interface.
abstract interface class WASI {
  /// Creates a WASI runtime with the given options.
  factory WASI({
    List<String> args,
    Map<String, String> env,
    Map<String, String> preopens,
    bool returnOnExit,
    int stdin,
    int stdout,
    int stderr,
    WASIVersion version,
  }) = backend.WASI;

  /// The WASI import object to pass when instantiating a module.
  Imports get imports;

  /// Starts a WASI command module by invoking its `_start` export.
  ///
  /// Returns the exit code reported by the module.
  int start(Instance instance);

  /// Initializes a WASI reactor module by invoking its `_initialize` export.
  void initialize(Instance instance);

  /// Binds the WASI runtime to an instance's memory.
  ///
  /// Prefers the explicitly provided [memory]. Falls back to
  /// `instance.exports['memory']`. Throws if neither is available.
  ///
  /// [start] and [initialize] call this automatically when needed.
  void finalizeBindings(Instance instance, {Memory? memory});
}
