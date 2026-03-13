@JS()
library;

import 'dart:js_interop';
import 'dart:typed_data';

import '../../module.dart' as wasm;
import 'errors.dart' as js_errors;

class Module implements wasm.Module {
  Module(ByteBuffer bytes) : host = _compile(bytes);

  Module.fromHost(this.host);

  final JSImportModule host;

  static JSImportModule _compile(ByteBuffer bytes) {
    try {
      return JSImportModule(bytes.toJS);
    } catch (e, st) {
      js_errors.translateJsError(e, st);
    }
  }
}

List<wasm.ModuleImportDescriptor> imports(wasm.Module module) =>
    JSImportModule.imports((module as Module).host).toDart
        .map(
          (d) => wasm.ModuleImportDescriptor(
            kind: _parseKind(d.kind),
            module: d.module,
            name: d.name,
          ),
        )
        .toList(growable: false);

List<wasm.ModuleExportDescriptor> exports(wasm.Module module) =>
    JSImportModule.exports((module as Module).host).toDart
        .map(
          (d) => wasm.ModuleExportDescriptor(
            kind: _parseKind(d.kind),
            name: d.name,
          ),
        )
        .toList(growable: false);

List<ByteBuffer> customSections(wasm.Module module, String name) =>
    JSImportModule.customSections(
      (module as Module).host,
      name,
    ).toDart.map((b) => b.toDart).toList(growable: false);

wasm.ImportExportKind _parseKind(String kind) => switch (kind) {
  'function' => wasm.ImportExportKind.function,
  'global' => wasm.ImportExportKind.global,
  'memory' => wasm.ImportExportKind.memory,
  'table' => wasm.ImportExportKind.table,
  'tag' => wasm.ImportExportKind.tag,
  _ => throw UnsupportedError('Unsupported import/export kind: $kind'),
};

extension type JSImportDescriptor._(JSObject _) implements JSObject {
  external String get module;
  external String get name;
  external String get kind;
}

extension type JSExportDescriptor._(JSObject _) implements JSObject {
  external String get kind;
  external String get name;
}

@JS('WebAssembly.Module')
extension type JSImportModule._(JSObject _) implements JSObject {
  external factory JSImportModule(JSArrayBuffer bytes);

  external static JSArray<JSImportDescriptor> imports(JSImportModule module);

  external static JSArray<JSExportDescriptor> exports(JSImportModule module);

  external static JSArray<JSArrayBuffer> customSections(
    JSImportModule module,
    String sectionName,
  );
}
