import 'dart:async';
import 'dart:typed_data';

import '../../instance.dart' as wasm;
import '../../module.dart' as wasm;
import '../../webassembly.dart' as wasm;

class WebAssembly implements wasm.WebAssembly {
  WebAssembly(this.module, this.instance);

  @override
  final wasm.Module module;

  @override
  final wasm.Instance instance;
}

Future<wasm.Module> compile(ByteBuffer bytes) =>
    Future.error(UnimplementedError('native wasm backend is not implemented'));

Future<wasm.Module> compileStreaming(Stream<List<int>> source) =>
    Future.error(UnimplementedError('native wasm backend is not implemented'));

Future<wasm.WebAssembly> instantiate(
  ByteBuffer bytes, [
  wasm.Imports imports = const {},
]) => Future.error(UnimplementedError('native wasm backend is not implemented'));

Future<wasm.WebAssembly> instantiateStreaming(
  Stream<List<int>> source, [
  wasm.Imports imports = const {},
]) => Future.error(UnimplementedError('native wasm backend is not implemented'));

Future<wasm.Instance> instantiateModule(
  wasm.Module module, [
  wasm.Imports imports = const {},
]) => Future.error(UnimplementedError('native wasm backend is not implemented'));

bool validate(ByteBuffer bytes) =>
    throw UnimplementedError('native wasm backend is not implemented');
