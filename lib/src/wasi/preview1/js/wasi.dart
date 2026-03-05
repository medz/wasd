import 'dart:typed_data';

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../../../wasm/instance.dart' as wasm_instance;
import '../../../wasm/memory.dart' as wasm_memory;
import '../../../wasm/module.dart' as wasm_module;
import '../../wasi.dart' as wasi_iface;
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
    int stdout = 1,
    int stderr = 2,
    wasi_iface.WASIVersion version = wasi_iface.WASIVersion.preview1,
  }) : _delegate = _createDelegate(
         args: args,
         env: env,
         preopens: preopens,
         files: files,
         returnOnExit: returnOnExit,
         stdin: stdin,
         stdout: stdout,
         stderr: stderr,
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
  final hasWindow = globalContext.getProperty<JSAny?>('window'.toJS) != null;
  if (hasWindow) {
    return false;
  }
  final hasDocument =
      globalContext.getProperty<JSAny?>('document'.toJS) != null;
  if (hasDocument) {
    return false;
  }
  final process = globalContext.getProperty<JSAny?>('process'.toJS);
  if (process == null) return false;
  final versions = (process as JSObject).getProperty<JSAny?>('versions'.toJS);
  if (versions == null) return false;
  return (versions as JSObject).getProperty<JSAny?>('node'.toJS) != null;
}

wasi_iface.WASI _createDelegate({
  required List<String> args,
  required Map<String, String> env,
  required Map<String, String> preopens,
  required Map<String, Uint8List> files,
  required bool returnOnExit,
  required int stdin,
  required int stdout,
  required int stderr,
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
      stdout: stdout,
      stderr: stderr,
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
    stdout: stdout,
    stderr: stderr,
    version: version,
  );
}
