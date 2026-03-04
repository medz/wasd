@JS()
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import '../../instance.dart' as wasm;
import '../../module.dart' as wasm;
import '../../webassembly.dart' as wasm;
import 'errors.dart' as js_errors;
import 'instance.dart' as js_instance;
import 'module.dart' as js_module;

class WebAssembly implements wasm.WebAssembly {
  WebAssembly(this.module, this.instance);

  @override
  final wasm.Module module;

  @override
  final wasm.Instance instance;
}

Future<wasm.Module> compile(ByteBuffer bytes) async {
  try {
    return js_module.Module.fromHost(await _jsCompile(bytes.toJS).toDart);
  } catch (e, st) {
    js_errors.translateJsError(e, st);
  }
}

Future<wasm.Module> compileStreaming(Stream<List<int>> source) async {
  try {
    return js_module.Module.fromHost(
      await _jsCompileStreaming(_streamToResponse(source)).toDart,
    );
  } catch (e, st) {
    js_errors.translateJsError(e, st);
  }
}

Future<wasm.WebAssembly> instantiate(
  ByteBuffer bytes, [
  wasm.Imports imports = const {},
]) async {
  try {
    final result = await _jsInstantiateBytes(
      bytes.toJS,
      js_instance.createImportObject(imports),
    ).toDart;
    final module = js_module.Module.fromHost(result.module);
    return WebAssembly(
      module,
      js_instance.Instance.fromHost(module, result.instance),
    );
  } catch (e, st) {
    js_errors.translateJsError(e, st);
  }
}

Future<wasm.WebAssembly> instantiateStreaming(
  Stream<List<int>> source, [
  wasm.Imports imports = const {},
]) async {
  try {
    final result = await _jsInstantiateStreaming(
      _streamToResponse(source),
      js_instance.createImportObject(imports),
    ).toDart;
    final module = js_module.Module.fromHost(result.module);
    return WebAssembly(
      module,
      js_instance.Instance.fromHost(module, result.instance),
    );
  } catch (e, st) {
    js_errors.translateJsError(e, st);
  }
}

Future<wasm.Instance> instantiateModule(
  wasm.Module module, [
  wasm.Imports imports = const {},
]) async {
  try {
    final jsInstance = await _jsInstantiateModule(
      (module as js_module.Module).host,
      js_instance.createImportObject(imports),
    ).toDart;
    return js_instance.Instance.fromHost(module, jsInstance);
  } catch (e, st) {
    js_errors.translateJsError(e, st);
  }
}

bool validate(ByteBuffer bytes) => _jsValidate(bytes.toJS);

/// Creates a JS [Response] backed by a [ReadableStream] fed from [source].
///
/// This allows [WebAssembly.compileStreaming] / [instantiateStreaming] to
/// start processing bytes as they arrive rather than waiting for the full
/// payload.
JSResponse _streamToResponse(Stream<List<int>> source) {
  StreamSubscription<List<int>>? subscription;
  _JSReadableStreamController? controller;

  void start(JSAny? ctrl) {
    controller = ctrl as _JSReadableStreamController;
    subscription = source.listen(
      (chunk) {
        final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        controller!.enqueue(bytes.toJS);
      },
      onError: (e) => controller?.error(e.toString().toJS),
      onDone: () => controller?.close(),
    );
  }

  void cancel(JSAny? _) => subscription?.cancel();

  final stream = JSReadableStream(
    {'start': start.toJS, 'cancel': cancel.toJS}.jsify() as JSObject,
  );
  return JSResponse(
    stream,
    {'headers': {'Content-Type': 'application/wasm'}.jsify()}.jsify()
        as JSObject,
  );
}

// ── JS interop declarations ───────────────────────────────────────────────────

@JS('WebAssembly.compile')
external JSPromise<js_module.JSImportModule> _jsCompile(JSArrayBuffer bytes);

@JS('WebAssembly.compileStreaming')
external JSPromise<js_module.JSImportModule> _jsCompileStreaming(
  JSObject response,
);

@JS('WebAssembly.validate')
external bool _jsValidate(JSArrayBuffer bytes);

@JS('WebAssembly.instantiate')
external JSPromise<_JSInstantiatedSource> _jsInstantiateBytes(
  JSArrayBuffer bytes, [
  JSObject? importObject,
]);

@JS('WebAssembly.instantiate')
external JSPromise<js_instance.JSImportInstance> _jsInstantiateModule(
  js_module.JSImportModule module, [
  JSObject? importObject,
]);

@JS('WebAssembly.instantiateStreaming')
external JSPromise<_JSInstantiatedSource> _jsInstantiateStreaming(
  JSObject response, [
  JSObject? importObject,
]);

extension type _JSInstantiatedSource._(JSObject _) implements JSObject {
  external js_module.JSImportModule get module;
  external js_instance.JSImportInstance get instance;
}

@JS('ReadableStream')
extension type JSReadableStream._(JSObject _) implements JSObject {
  external factory JSReadableStream([JSObject? underlyingSource]);
}

@JS('Response')
extension type JSResponse._(JSObject _) implements JSObject {
  external factory JSResponse(JSAny? body, [JSObject? init]);
}

extension type _JSReadableStreamController._(JSObject _) implements JSObject {
  external void enqueue(JSAny? chunk);
  external void close();
  external void error([JSAny? reason]);
}
