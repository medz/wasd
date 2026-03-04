@JS()
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import '../../instance.dart' as wasm;
import '../../module.dart' as wasm;
import '../../webassembly.dart' as wasm;
import 'instance.dart' as js_instance;
import 'module.dart' as js_module;

class WebAssembly implements wasm.WebAssembly {
  WebAssembly(this.module, this.instance);

  @override
  final wasm.Module module;

  @override
  final wasm.Instance instance;
}

Future<wasm.Module> compile(ByteBuffer bytes) async =>
    js_module.Module.fromHost(await _jsCompile(bytes.toJS).toDart);

Future<wasm.Module> compileStreaming(Stream<List<int>> source) async =>
    compile(await _collectStream(source));

Future<wasm.WebAssembly> instantiate(
  ByteBuffer bytes, [
  wasm.Imports imports = const {},
]) async {
  final result = await _jsInstantiateBytes(
    bytes.toJS,
    js_instance.createImportObject(imports),
  ).toDart;
  final module = js_module.Module.fromHost(result.module);
  return WebAssembly(module, js_instance.Instance.fromHost(module, result.instance));
}

Future<wasm.WebAssembly> instantiateStreaming(
  Stream<List<int>> source, [
  wasm.Imports imports = const {},
]) async => instantiate(await _collectStream(source), imports);

Future<wasm.Instance> instantiateModule(
  wasm.Module module, [
  wasm.Imports imports = const {},
]) async {
  final jsInstance = await _jsInstantiateModule(
    (module as js_module.Module).host,
    js_instance.createImportObject(imports),
  ).toDart;
  return js_instance.Instance.fromHost(module, jsInstance);
}

bool validate(ByteBuffer bytes) => _jsValidate(bytes.toJS);

Future<ByteBuffer> _collectStream(Stream<List<int>> source) async {
  final chunks = <int>[];
  await for (final chunk in source) {
    chunks.addAll(chunk);
  }
  return Uint8List.fromList(chunks).buffer;
}

@JS('WebAssembly.compile')
external JSPromise<js_module.JSImportModule> _jsCompile(JSArrayBuffer bytes);

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

extension type _JSInstantiatedSource._(JSObject _) implements JSObject {
  external js_module.JSImportModule get module;
  external js_instance.JSImportInstance get instance;
}
