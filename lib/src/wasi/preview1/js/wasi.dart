import 'dart:typed_data';

import '../../../wasm/instance.dart' as wasm_instance;
import '../../../wasm/memory.dart' as wasm_memory;
import '../../../wasm/module.dart' as wasm_module;
import '../../wasi.dart' as wasi_iface;
import '../socket.dart';
import 'web/wasi.dart' as web;

class WASI implements wasi_iface.WASI {
  WASI({
    List<String> args = const [],
    Map<String, String> env = const {},
    Map<String, String> preopens = const {},
    Map<String, Uint8List> files = const {},
    bool returnOnExit = true,
    int stdin = 0,
    List<int> stdinData = const <int>[],
    int stdout = 1,
    int stderr = 2,
    Map<int, WASIPreview1Socket> sockets = const <int, WASIPreview1Socket>{},
    wasi_iface.WASIOutputSink? stdoutSink,
    wasi_iface.WASIOutputSink? stderrSink,
    wasi_iface.WASIProcRaiseHandler? procRaiseHandler,
    wasi_iface.WASIVersion version = wasi_iface.WASIVersion.preview1,
  }) : _delegate = _createDelegate(
         args: args,
         env: env,
         preopens: preopens,
         files: files,
         returnOnExit: returnOnExit,
         stdin: stdin,
         stdinData: stdinData,
         stdout: stdout,
         stderr: stderr,
         sockets: sockets,
         stdoutSink: stdoutSink,
         stderrSink: stderrSink,
         procRaiseHandler: procRaiseHandler,
         version: version,
       );

  final wasi_iface.WASI _delegate;

  @override
  wasm_module.Imports get imports => _delegate.imports;

  @override
  int start(wasm_instance.Instance instance) => _delegate.start(instance);

  @override
  void initialize(wasm_instance.Instance instance) =>
      _delegate.initialize(instance);

  @override
  void finalizeBindings(
    wasm_instance.Instance instance, {
    wasm_memory.Memory? memory,
  }) => _delegate.finalizeBindings(instance, memory: memory);
}

wasi_iface.WASI _createDelegate({
  required List<String> args,
  required Map<String, String> env,
  required Map<String, String> preopens,
  required Map<String, Uint8List> files,
  required bool returnOnExit,
  required int stdin,
  required List<int> stdinData,
  required int stdout,
  required int stderr,
  required Map<int, WASIPreview1Socket> sockets,
  required wasi_iface.WASIOutputSink? stdoutSink,
  required wasi_iface.WASIOutputSink? stderrSink,
  required wasi_iface.WASIProcRaiseHandler? procRaiseHandler,
  required wasi_iface.WASIVersion version,
}) {
  if (const bool.fromEnvironment('WASI_TRACE')) {
    print('WASI JS backend: wasd');
  }
  return web.WASI(
    args: args,
    env: env,
    preopens: preopens,
    files: files,
    returnOnExit: returnOnExit,
    stdin: stdin,
    stdinData: stdinData,
    stdout: stdout,
    stderr: stderr,
    sockets: sockets,
    stdoutSink: stdoutSink,
    stderrSink: stderrSink,
    procRaiseHandler: procRaiseHandler,
    version: version,
  );
}
