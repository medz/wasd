@JS()
library;

import 'dart:js_interop';
import 'dart:typed_data';

import '../../global.dart' as wasm_global;
import '../../memory.dart' as wasm_memory;
import '../../module.dart' as wasm;
import '../../table.dart' as wasm_table;
import '../../tag.dart' as wasm_tag;

class Module implements wasm.Module {
  Module(ByteBuffer bytes) : host = JSImportModule(Uint8List.view(bytes).toJS);

  final JSImportModule host;
}

List<wasm.ModuleImportDescriptor> imports(wasm.Module module) =>
    JSImportModule.imports(
      (module as Module).host,
    ).toDart.map(parseImportDescriptor).toList(growable: false);

List<wasm.ModuleExportDescriptor> exports(wasm.Module module) =>
    JSImportModule.exports(
      (module as Module).host,
    ).toDart.map(parseExportDescriptor).toList(growable: false);

List<ByteBuffer> customSections(wasm.Module module, String name) =>
    JSImportModule.customSections(
      (module as Module).host,
      name.toJS,
    ).toDart.map((buffer) => buffer.toDart).toList(growable: false);

wasm.ModuleImportDescriptor parseImportDescriptor(
  JSImportDescriptor descriptor,
) => switch (descriptor.kind.toDart) {
  'function' =>
    wasm.ModuleImportDescriptor<Function, wasm.FunctionImportExportValue>(
      kind: wasm.ImportExportKind.function,
      module: descriptor.module.toDart,
      name: descriptor.name.toDart,
    ),
  'global' =>
    wasm.ModuleImportDescriptor<
      wasm_global.Global,
      wasm.GlobalImportExportValue
    >(
      kind: wasm.ImportExportKind.global,
      module: descriptor.module.toDart,
      name: descriptor.name.toDart,
    ),
  'memory' =>
    wasm.ModuleImportDescriptor<
      wasm_memory.Memory,
      wasm.MemoryImportExportValue
    >(
      kind: wasm.ImportExportKind.memory,
      module: descriptor.module.toDart,
      name: descriptor.name.toDart,
    ),
  'table' =>
    wasm.ModuleImportDescriptor<wasm_table.Table, wasm.TableImportExportValue>(
      kind: wasm.ImportExportKind.table,
      module: descriptor.module.toDart,
      name: descriptor.name.toDart,
    ),
  'tag' => wasm.ModuleImportDescriptor<wasm_tag.Tag, wasm.TagImportExportValue>(
    kind: wasm.ImportExportKind.tag,
    module: descriptor.module.toDart,
    name: descriptor.name.toDart,
  ),
  _ => throw UnsupportedError(
    'Unsupported import/export kind: ${descriptor.kind.toDart}',
  ),
};

wasm.ModuleExportDescriptor parseExportDescriptor(
  JSImportExportDescriptor descriptor,
) => switch (descriptor.kind.toDart) {
  'function' =>
    wasm.ModuleExportDescriptor<Function, wasm.FunctionImportExportValue>(
      kind: wasm.ImportExportKind.function,
      name: descriptor.name.toDart,
    ),
  'global' =>
    wasm.ModuleExportDescriptor<
      wasm_global.Global,
      wasm.GlobalImportExportValue
    >(kind: wasm.ImportExportKind.global, name: descriptor.name.toDart),
  'memory' =>
    wasm.ModuleExportDescriptor<
      wasm_memory.Memory,
      wasm.MemoryImportExportValue
    >(kind: wasm.ImportExportKind.memory, name: descriptor.name.toDart),
  'table' =>
    wasm.ModuleExportDescriptor<wasm_table.Table, wasm.TableImportExportValue>(
      kind: wasm.ImportExportKind.table,
      name: descriptor.name.toDart,
    ),
  'tag' => wasm.ModuleExportDescriptor<wasm_tag.Tag, wasm.TagImportExportValue>(
    kind: wasm.ImportExportKind.tag,
    name: descriptor.name.toDart,
  ),
  _ => throw UnsupportedError(
    'Unsupported import/export kind: ${descriptor.kind.toDart}',
  ),
};

extension type JSImportDescriptor._(JSObject _) implements JSObject {
  external JSString get module;
  external JSString get name;
  external JSString get kind;
}

extension type JSImportExportDescriptor._(JSObject _) implements JSObject {
  external JSString get name;
  external JSString get kind;
}

@JS('WebAssembly.Module')
extension type JSImportModule._(JSObject _) implements JSObject {
  external factory JSImportModule(JSAny bytes);

  external static JSArray<JSImportDescriptor> imports(JSImportModule module);

  external static JSArray<JSImportExportDescriptor> exports(
    JSImportModule module,
  );

  external static JSArray<JSArrayBuffer> customSections(
    JSImportModule module,
    JSString name,
  );
}
