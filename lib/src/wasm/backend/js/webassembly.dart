@JS()
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import '../../instance.dart' as wasm_instance;
import '../../module.dart' as wasm_module;
import '../../webassembly.dart' as wasm;
import 'instance.dart' as backend_instance;
import 'module.dart' as backend_module;

class WebAssembly implements wasm.WebAssembly {
  WebAssembly(this.module, this.instance);

  @override
  final wasm_instance.Instance instance;

  @override
  final wasm_module.Module module;
}

Future<wasm_module.Module> compile(ByteBuffer bytes) async =>
    backend_module.Module(bytes);

Future<wasm_module.Module> compileStreaming(Stream<List<int>> source) async =>
    compile(await collectBytes(source));

Future<wasm.WebAssembly> instantiate(
  ByteBuffer bytes, [
  wasm_module.Imports imports = const {},
]) async {
  final module = await compile(bytes);
  final instance = await instantiateModule(module, imports);
  return WebAssembly(module, instance);
}

Future<wasm.WebAssembly> instantiateStreaming(
  Stream<List<int>> source, [
  wasm_module.Imports imports = const {},
]) async => instantiate(await collectBytes(source), imports);

Future<wasm_instance.Instance> instantiateModule(
  wasm_module.Module module, [
  wasm_module.Imports imports = const {},
]) async => backend_instance.Instance(module, imports);

bool validate(ByteBuffer bytes) =>
    jsValidate(Uint8List.view(bytes).toJS).toDart;

Future<ByteBuffer> collectBytes(Stream<List<int>> source) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in source) {
    builder.add(chunk);
  }
  return builder.takeBytes().buffer;
}

@JS('WebAssembly.validate')
external JSBoolean jsValidate(JSAny bytes);
