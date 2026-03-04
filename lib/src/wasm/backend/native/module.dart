import 'dart:typed_data';

import '../../module.dart' as wasm;

class Module implements wasm.Module {
  Module(this.bytes);

  final ByteBuffer bytes;
}

List<wasm.ModuleImportDescriptor> imports(wasm.Module module) =>
    throw UnimplementedError('Native backend module import introspection');

List<wasm.ModuleExportDescriptor> exports(wasm.Module module) =>
    throw UnimplementedError('Native backend module export introspection');

List<ByteBuffer> customSections(wasm.Module module, String name) =>
    throw UnimplementedError('Native backend module custom section query');
