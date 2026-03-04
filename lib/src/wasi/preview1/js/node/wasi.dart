@JS()
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../../../../wasm/instance.dart' as wasm;
import '../../../../wasm/memory.dart' as wasm;
import '../../../../wasm/module.dart' as wasm;
import '../../../wasi.dart' as wasi_iface;
import '../../../../wasm/backend/js/instance.dart' as js_instance;
import '../../../../wasm/backend/js/memory.dart' as js_memory;

class WASI implements wasi_iface.WASI {
  WASI({
    List<String> args = const [],
    Map<String, String> env = const {},
    Map<String, String> preopens = const {},
    bool returnOnExit = true,
    int stdin = 0,
    int stdout = 1,
    int stderr = 2,
    wasi_iface.WASIVersion version = wasi_iface.WASIVersion.preview1,
  }) : _host = _createNodeWasi(
         args: args,
         env: env,
         preopens: preopens,
         stdin: stdin,
         stdout: stdout,
         stderr: stderr,
       );

  final _JSNodeWasi _host;

  @override
  wasm.Imports get imports {
    final wasiImport = _host.wasiImport;
    final functions = <String, wasm.ImportValue>{};
    for (final jsKey in _jsObjectKeys(wasiImport).toDart) {
      final key = jsKey.toDart;
      final fn = wasiImport[key] as JSFunction;
      functions[key] = wasm.ImportExportKind.function(_wrapNodeFunc(fn));
    }
    return {'wasi_snapshot_preview1': functions};
  }

  @override
  int start(wasm.Instance instance) {
    final jsInstance = (instance as js_instance.Instance).host;
    // Node.js wasi.start() handles memory binding internally.
    // With returnOnExit: true, proc_exit is captured and the exit code is
    // returned rather than calling process.exit() directly.
    final result = _host.start(jsInstance);
    return result.toDartDouble.toInt();
  }

  @override
  void initialize(wasm.Instance instance) {
    final jsInstance = (instance as js_instance.Instance).host;
    // Node.js wasi.initialize() handles memory binding internally.
    _host.initialize(jsInstance);
  }

  @override
  void finalizeBindings(wasm.Instance instance, {wasm.Memory? memory}) {
    final jsInstance = (instance as js_instance.Instance).host;
    if (memory != null) {
      _host.finalizeBindings(jsInstance, (memory as js_memory.Memory).host);
    } else {
      _host.finalizeBindings(jsInstance);
    }
  }
}

// ── helpers ───────────────────────────────────────────────────────────────────

/// Wraps a Node.js WASI syscall [JSFunction] as a [wasm.WasmFunction].
wasm.WasmFunction _wrapNodeFunc(JSFunction fn) =>
    (List<Object?> args) {
      final jsArgs = <JSAny?>[
        null,
        for (final arg in args) arg.jsify(),
      ];
      return (fn as JSObject)
          .callMethodVarArgs<JSAny?>('call'.toJS, jsArgs)
          ?.dartify();
    };

// ── Node.js environment detection ─────────────────────────────────────────────

/// Returns `true` when running inside Node.js.
///
/// Checks for `process.versions.node` following the standard Node.js idiom.
bool _isNodeJs() {
  final process = globalContext.getProperty<JSAny?>('process'.toJS);
  if (process == null) return false;
  final versions =
      (process as JSObject).getProperty<JSAny?>('versions'.toJS);
  if (versions == null) return false;
  return (versions as JSObject).getProperty<JSAny?>('node'.toJS) != null;
}

// ── Node.js WASI construction ─────────────────────────────────────────────────

_JSNodeWasi _createNodeWasi({
  required List<String> args,
  required Map<String, String> env,
  required Map<String, String> preopens,
  required int stdin,
  required int stdout,
  required int stderr,
}) {
  if (!_isNodeJs()) {
    throw UnsupportedError(
      'WASI is only supported in Node.js environments. '
      'Browser WASI is not yet implemented.',
    );
  }
  final opts = JSObject();
  opts['version'] = 'preview1'.toJS;
  // returnOnExit: true (Node.js default) causes proc_exit to be captured so
  // that wasi.start() returns the exit code rather than calling process.exit().
  opts['returnOnExit'] = true.toJS;
  opts['stdin'] = stdin.toJS;
  opts['stdout'] = stdout.toJS;
  opts['stderr'] = stderr.toJS;
  opts['args'] = [for (final a in args) a.toJS].toJS;

  final jsEnv = JSObject();
  for (final e in env.entries) {
    jsEnv[e.key] = e.value.toJS;
  }
  opts['env'] = jsEnv;

  final jsPreopens = JSObject();
  for (final e in preopens.entries) {
    jsPreopens[e.key] = e.value.toJS;
  }
  opts['preopens'] = jsPreopens;

  return _jsReflectConstruct(_jsRequireWasi(), <JSAny?>[opts].toJS)
      as _JSNodeWasi;
}

/// Returns the `WASI` constructor from `node:wasi`.
///
/// node_preamble sets `self.require = require`, making `@JS('require')` work
/// in dart2js compiled output running under `dart test --platform node`.
JSFunction _jsRequireWasi() {
  final mod = _jsRequire('node:wasi'.toJS) as JSObject;
  return mod['WASI'] as JSFunction;
}

// ── JS interop declarations ───────────────────────────────────────────────────

@JS('require')
external JSAny _jsRequire(JSString module);

@JS('Reflect.construct')
external JSObject _jsReflectConstruct(JSFunction target, JSArray<JSAny?> args);

@JS('Object.keys')
external JSArray<JSString> _jsObjectKeys(JSObject obj);

extension type _JSNodeWasi._(JSObject _) implements JSObject {
  /// The WASI syscall implementations keyed by function name.
  external JSObject get wasiImport;

  /// Invokes `_start` export; returns the exit code (returnOnExit: true).
  external JSNumber start(js_instance.JSImportInstance instance);

  /// Invokes `_initialize` export of a WASI reactor module.
  external void initialize(js_instance.JSImportInstance instance);

  /// Binds the WASI runtime to an instance's memory.
  external void finalizeBindings(
    js_instance.JSImportInstance instance, [
    js_memory.JSMemory? memory,
  ]);
}
