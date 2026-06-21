import 'dart:typed_data';

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../../../wasm/instance.dart' as wasm_instance;
import '../../../wasm/memory.dart' as wasm_memory;
import '../../../wasm/module.dart' as wasm_module;
import '../../wasi.dart' as wasi_iface;
import '../socket.dart';
import 'node/wasi.dart' as node;
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

bool _isNodeJs() {
  final process = globalContext.getProperty<JSAny?>('process'.toJS);
  if (process == null) return false;
  final versions = (process as JSObject).getProperty<JSAny?>('versions'.toJS);
  if (versions == null) return false;
  final nodeVersion = (versions as JSObject).getProperty<JSAny?>('node'.toJS);
  if (nodeVersion == null) return false;
  return globalContext.getProperty<JSAny?>('require'.toJS) != null;
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
  required wasi_iface.WASIVersion version,
}) {
  final useNode = _isNodeJs();
  if (const bool.fromEnvironment('WASI_TRACE')) {
    print('WASI JS backend: ${useNode ? 'node' : 'web'}');
  }
  if (useNode) {
    return node.WASI(
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
      version: version,
    );
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
    version: version,
  );
}
