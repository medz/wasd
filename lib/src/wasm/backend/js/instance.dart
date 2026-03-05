@JS()
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../../global.dart' as wasm;
import '../../instance.dart' as wasm;
import '../../memory.dart' as wasm;
import '../../module.dart' as wasm;
import '../../table.dart' as wasm;
import '../../value.dart';
import 'errors.dart' as js_errors;
import 'global.dart' as js_global;
import 'memory.dart' as js_memory;
import 'module.dart' as js_module;
import 'table.dart' as js_table;
import 'tag.dart' as js_tag;

class Instance implements wasm.Instance {
  Instance(wasm.Module module, [wasm.Imports imports = const {}])
    : _module = module,
      host = _instantiate(
        (module as js_module.Module).host,
        createImportObject(imports),
      );

  Instance.fromHost(this._module, this.host);

  final wasm.Module _module;
  final JSImportInstance host;

  @override
  late final wasm.Exports exports = _createExports(_module, host.exports);

  static JSImportInstance _instantiate(
    js_module.JSImportModule jsModule,
    JSObject imports,
  ) {
    try {
      return JSImportInstance(jsModule, imports);
    } catch (e, st) {
      js_errors.translateJsError(e, st);
    }
  }
}

wasm.Exports _createExports(wasm.Module module, JSObject exportObject) {
  final result = <String, wasm.ExportValue>{};
  for (final descriptor in wasm.Module.exports(module)) {
    final name = descriptor.name;
    final raw = exportObject[name];
    if (raw == null) continue;
    result[name] = switch (descriptor.kind) {
      wasm.ImportExportKind.function => wasm.ImportExportKind.function(
        _wrapFunction(raw as JSFunction),
      ),
      wasm.ImportExportKind.global => wasm.ImportExportKind.global(
        _ExportGlobal(raw as js_global.JSGlobal),
      ),
      wasm.ImportExportKind.memory => wasm.ImportExportKind.memory(
        _ExportMemory(raw as js_memory.JSMemory),
      ),
      wasm.ImportExportKind.table => wasm.ImportExportKind.table(
        _ExportTable(raw as js_table.JSTable),
      ),
      wasm.ImportExportKind.tag => wasm.ImportExportKind.tag(
        js_tag.Tag.fromHost(raw as js_tag.JSTag),
      ),
    };
  }
  return result;
}

JSObject createImportObject(wasm.Imports imports) {
  final root = JSObject();
  for (final moduleEntry in imports.entries) {
    final moduleObject = JSObject();
    for (final importEntry in moduleEntry.value.entries) {
      moduleObject[importEntry.key] = _encodeImport(importEntry.value);
    }
    root[moduleEntry.key] = moduleObject;
  }
  return root;
}

JSAny? _encodeImport(wasm.ImportValue value) => switch (value) {
  wasm.IntImportValue(:final ref) => ref.toJS,
  wasm.FunctionImportExportValue(:final ref) => _hostFuncToJS(ref),
  wasm.GlobalImportExportValue(:final ref) => (ref as js_global.Global).host,
  wasm.MemoryImportExportValue(:final ref) => (ref as js_memory.Memory).host,
  wasm.TableImportExportValue(:final ref) => (ref as js_table.Table).host,
  wasm.TagImportExportValue(:final ref) => (ref as js_tag.Tag).host,
};

wasm.WasmFunction _wrapFunction(JSFunction jsFunc) =>
    (List<Object?> args) {
      final jsArgs = <JSAny?>[
        null,
        for (final arg in args) arg.jsify(),
      ];
      return (jsFunc as JSObject)
          .callMethodVarArgs<JSAny?>('call'.toJS, jsArgs)
          ?.dartify();
    };

/// Converts a [wasm.WasmFunction] host function to a [JSFunction] for use as
/// a WebAssembly import.
///
/// WebAssembly calls the import with exactly N positional arguments matching
/// the wasm function type. Our bridge has a fixed 8-param signature; the extra
/// params arrive as JS `undefined` (Dart `null`). Trailing nulls are trimmed
/// to recover the actual argument list.
///
/// Limitation: this heuristic is incorrect for host functions whose final
/// parameter is a nullable reference type (externref / funcref). Numeric types
/// (i32, i64, f32, f64) are always non-null and are unaffected.
JSFunction _hostFuncToJS(wasm.WasmFunction hostFn) {
  JSAny? bridge([
    JSAny? a,
    JSAny? b,
    JSAny? c,
    JSAny? d,
    JSAny? e,
    JSAny? f,
    JSAny? g,
    JSAny? h,
    JSAny? i,
    JSAny? j,
    JSAny? k,
    JSAny? l,
    JSAny? m,
    JSAny? n,
    JSAny? o,
    JSAny? p,
  ]) {
    final all = [a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p];
    final last = all.lastIndexWhere((x) => x != null);
    final args =
        all.sublist(0, last + 1).map((x) => x?.dartify()).toList();
    return hostFn(args)?.jsify();
  }

  return bridge.toJS;
}

class _ExportGlobal implements wasm.Global<ExternRef, Object?> {
  _ExportGlobal(this._host);

  final js_global.JSGlobal _host;

  @override
  Object? get value => _host.value?.dartify();

  @override
  set value(Object? value) {
    _host.value = value.jsify();
  }
}

class _ExportMemory implements wasm.Memory {
  _ExportMemory(this._host);

  final js_memory.JSMemory _host;

  @override
  ByteBuffer get buffer => _host.buffer.toDart;

  @override
  int grow(int delta) => _host.grow(delta);
}

class _ExportTable implements wasm.Table<ExternRef, Object?> {
  _ExportTable(this._host);

  final js_table.JSTable _host;

  @override
  int get length => _host.length;

  @override
  Object? get(int index) => _host.get(index)?.dartify();

  @override
  void set(int index, Object? value) => _host.set(index, value.jsify());

  @override
  int grow(int delta, [Object? value]) {
    if (value == null) return _host.grow(delta);
    return _host.grow(delta, value.jsify());
  }
}

@JS('WebAssembly.Instance')
extension type JSImportInstance._(JSObject _) implements JSObject {
  external factory JSImportInstance(
    js_module.JSImportModule module, [
    JSObject? imports,
  ]);

  external JSObject get exports;
}
