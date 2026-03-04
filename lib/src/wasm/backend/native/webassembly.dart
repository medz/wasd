import 'dart:async';
import 'dart:typed_data';

import '../../errors.dart';
import '../../instance.dart' as wasm;
import '../../module.dart' as wasm;
import '../../webassembly.dart' as wasm;
import 'instance.dart' as native_instance;
import 'module.dart' as native_module;
import 'interpreter/module.dart' as old;

class WebAssembly implements wasm.WebAssembly {
  WebAssembly(this.module, this.instance);

  @override
  final wasm.Module module;

  @override
  final wasm.Instance instance;
}

Future<wasm.Module> compile(ByteBuffer bytes) async {
  try {
    return native_module.Module(bytes);
  } on CompileError {
    rethrow;
  } catch (e) {
    throw CompileError(e.toString(), cause: e);
  }
}

Future<wasm.Module> compileStreaming(Stream<List<int>> source) async {
  final bytes = await _collectBytes(source);
  return compile(bytes.buffer);
}

Future<wasm.WebAssembly> instantiate(
  ByteBuffer bytes, [
  wasm.Imports imports = const {},
]) async {
  final module = await compile(bytes);
  final instance = await instantiateModule(module, imports);
  return WebAssembly(module, instance);
}

Future<wasm.WebAssembly> instantiateStreaming(
  Stream<List<int>> source, [
  wasm.Imports imports = const {},
]) async {
  final bytes = await _collectBytes(source);
  return instantiate(bytes.buffer, imports);
}

Future<wasm.Instance> instantiateModule(
  wasm.Module module, [
  wasm.Imports imports = const {},
]) async {
  try {
    return native_instance.Instance(module, imports);
  } on WasmError {
    rethrow;
  } catch (e) {
    throw LinkError(e.toString(), cause: e);
  }
}

bool validate(ByteBuffer bytes) {
  try {
    old.WasmModule.decode(bytes.asUint8List());
    return true;
  } catch (_) {
    return false;
  }
}

Future<Uint8List> _collectBytes(Stream<List<int>> source) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in source) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}
