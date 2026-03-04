import '../../../wasm/instance.dart' as wasm;
import '../../../wasm/memory.dart' as wasm;
import '../../../wasm/module.dart' as wasm;
import '../../wasi.dart' as wasi_iface;

class WASI implements wasi_iface.WASI {
  // ignore: avoid_unused_constructor_parameters
  WASI({
    List<String> args = const [],
    Map<String, String> env = const {},
    Map<String, String> preopens = const {},
    bool returnOnExit = true,
    int stdin = 0,
    int stdout = 1,
    int stderr = 2,
    wasi_iface.WASIVersion version = wasi_iface.WASIVersion.preview1,
  }) : _returnOnExit = returnOnExit;

  final bool _returnOnExit;
  wasm.Memory? _boundMemory;

  @override
  wasm.Imports get imports => <String, wasm.ModuleImports>{
    'wasi_snapshot_preview1': <String, wasm.ImportValue>{
      'proc_exit': _procExitImport,
    },
  };

  wasm.FunctionImportExportValue get _procExitImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        throw _WasiExit(args.isEmpty ? 0 : _asInt(args.first));
      });

  static int _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    throw ArgumentError.value(
      value,
      'args',
      'proc_exit expects an i32 exit code.',
    );
  }

  @override
  int start(wasm.Instance instance) {
    finalizeBindings(instance);
    final startExport = instance.exports['_start'];
    if (startExport is! wasm.FunctionImportExportValue) {
      throw StateError('WASI start target _start is missing.');
    }
    try {
      startExport.ref(const []);
      return 0;
    } on _WasiExit catch (error) {
      if (_returnOnExit) {
        return error.exitCode;
      }
      rethrow;
    }
  }

  @override
  void initialize(wasm.Instance instance) {
    finalizeBindings(instance);
    final initializeExport = instance.exports['_initialize'];
    if (initializeExport is! wasm.FunctionImportExportValue) {
      throw StateError('WASI initialize target _initialize is missing.');
    }
    initializeExport.ref(const []);
  }

  @override
  void finalizeBindings(wasm.Instance instance, {wasm.Memory? memory}) {
    if (memory != null) {
      _boundMemory = memory;
      return;
    }

    final exportedMemory = instance.exports['memory'];
    if (exportedMemory is wasm.MemoryImportExportValue) {
      _boundMemory = exportedMemory.ref;
      return;
    }

    if (_boundMemory != null) {
      return;
    }

    throw StateError(
      'WASI finalizeBindings requires a memory export or an explicit memory.',
    );
  }
}

final class _WasiExit extends Error {
  _WasiExit(this.exitCode);

  final int exitCode;
}
