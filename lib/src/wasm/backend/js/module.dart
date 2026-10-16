@JS()
library;

import 'dart:js_interop';
import 'dart:typed_data';

import '../../errors.dart';
import '../../module.dart' as wasm;
import '../../tag.dart' as wasm;
import '../../value.dart';
import '../native/interpreter/module.dart' as ir;
import 'branch_hint_validator.dart' as branch_hints;
import 'errors.dart' as js_errors;
import 'tag_metadata.dart';

class Module implements wasm.Module {
  Module(ByteBuffer bytes, {Set<wasm.CoreFeature> features = const {}})
    : _tagMetadata = snapshotTagMetadata(bytes),
      host = _compile(bytes, features);

  Module.fromHost(this.host, this._tagMetadata);

  final JSImportModule host;
  Uint8List? _tagMetadata;
  late final _tagTypes = _readTagTypes();

  wasm.TagDescriptor exportedTagType(String name) {
    final type = _tagTypes[name];
    if (type == null) {
      throw UnsupportedError(
        'The exported tag payload signature is unavailable.',
      );
    }
    return wasm.TagDescriptor(
      parameters: List<ValueKind>.generate(type.length, (index) {
        final signature = type[index];
        return switch (signature) {
          '7f' => ValueKind.i32,
          '7e' => ValueKind.i64,
          '7d' => ValueKind.f32,
          '7c' => ValueKind.f64,
          '7b' => ValueKind.v128,
          '70' => ValueKind.funcref,
          '6f' => ValueKind.externref,
          _ => throw UnsupportedError(
            'Unsupported exported tag parameter type: $signature',
          ),
        };
      }),
    );
  }

  Map<String, List<String>> _readTagTypes() {
    final bytes = _tagMetadata;
    if (bytes == null) return const {};
    final result = ir.WasmModule.decodeExportedTagTypes(bytes);
    _tagMetadata = null;
    return result;
  }

  static const supportedFeatures = <wasm.CoreFeature>{};

  static JSImportModule _compile(
    ByteBuffer bytes,
    Set<wasm.CoreFeature> features,
  ) {
    if (features.isNotEmpty) {
      throw CompileError(
        'Explicit Core options are unsupported by the JavaScript '
        'adapter: ${features.map((feature) => feature.name).join(', ')}.',
      );
    }
    try {
      branch_hints.validateBranchHintCustomSections(bytes);
      return JSImportModule(bytes.toJS);
    } catch (e, st) {
      js_errors.translateJsError(e, st);
    }
  }
}

Uint8List? snapshotTagMetadata(ByteBuffer bytes) =>
    (TagMetadataCollector(copy: false)..add(bytes.asUint8List())).finish();

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
