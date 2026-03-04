import 'dart:typed_data';

import '../../module.dart' as wasm;

class Module implements wasm.Module {
  Module(ByteBuffer bytes) : _bytes = bytes;

  Module.fromHost(this._bytes);

  // ignore: unused_field
  final ByteBuffer _bytes;
}

List<wasm.ModuleImportDescriptor> imports(wasm.Module module) =>
    throw UnimplementedError('native wasm backend is not implemented');

List<wasm.ModuleExportDescriptor> exports(wasm.Module module) =>
    throw UnimplementedError('native wasm backend is not implemented');

List<ByteBuffer> customSections(wasm.Module module, String name) =>
    throw UnimplementedError('native wasm backend is not implemented');
