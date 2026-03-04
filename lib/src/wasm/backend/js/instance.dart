@JS()
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../../global.dart' as wasm_global;
import '../../instance.dart' as wasm_instance;
import '../../memory.dart' as wasm_memory;
import '../../module.dart' as wasm_module;
import '../../table.dart' as wasm_table;
import '../../value.dart';
import 'global.dart' as js_global;
import 'memory.dart' as js_memory;
import 'module.dart' as js_module;
import 'table.dart' as js_table;
import 'tag.dart' as js_tag;

class Instance implements wasm_instance.Instance {
  Instance(this.module, [wasm_module.Imports imports = const {}])
    : host = JSImportInstance(
        (module as js_module.Module).host,
        createImportObject(imports),
      );

  final wasm_module.Module module;
  final JSImportInstance host;

  @override
  late final wasm_module.Exports exports = createExports(module, host.exports);
}

wasm_module.Exports createExports(
  wasm_module.Module module,
  JSObject exportObject,
) {
  final descriptors = wasm_module.Module.exports(module);
  final values = <String, wasm_module.ExportValue>{};
  for (final descriptor in descriptors) {
    final name = descriptor.name;
    final raw = exportObject[name];
    if (raw == null) {
      continue;
    }
    values[name] = switch (descriptor.kind.name) {
      'function' => wasm_module.ImportExportKind.function(
        wrapJsFunction(raw as JSFunction),
      ),
      'global' => wasm_module.ImportExportKind.global(
        ExportGlobal(raw as js_global.JSGlobal),
      ),
      'memory' => wasm_module.ImportExportKind.memory(
        ExportMemory(raw as js_memory.JSMemory),
      ),
      'table' => wasm_module.ImportExportKind.table(
        ExportTable(raw as js_table.JSTable),
      ),
      'tag' => wasm_module.ImportExportKind.tag(
        js_tag.Tag.fromHost(raw as js_tag.JSTag),
      ),
      _ => throw UnsupportedError(
        'Unsupported export kind: ${descriptor.kind.name}',
      ),
    };
  }
  return values;
}

JSObject createImportObject(wasm_module.Imports imports) {
  final root = JSObject();
  for (final moduleEntry in imports.entries) {
    final moduleObject = JSObject();
    for (final importEntry in moduleEntry.value.entries) {
      moduleObject[importEntry.key] = encodeImportValue(importEntry.value);
    }
    root[moduleEntry.key] = moduleObject;
  }
  return root;
}

JSAny? encodeImportValue(wasm_module.ImportValue value) => switch (value) {
  wasm_module.IntImportValue(:final ref) => ref.toJS,
  wasm_module.FunctionImportExportValue(:final ref) => ref.toJS,
  wasm_module.GlobalImportExportValue(:final ref) =>
    (ref as js_global.Global).host,
  wasm_module.MemoryImportExportValue(:final ref) =>
    (ref as js_memory.Memory).host,
  wasm_module.TableImportExportValue(:final ref) =>
    (ref as js_table.Table).host,
  wasm_module.TagImportExportValue(:final ref) => (ref as js_tag.Tag).host,
};

Function wrapJsFunction(JSFunction function) =>
    ([List<Object?> arguments = const []]) {
      final jsArguments = <JSAny?>[
        null,
        ...arguments.map((value) => value.jsify()),
      ];
      final result = (function as JSObject).callMethodVarArgs<JSAny?>(
        'call'.toJS,
        jsArguments,
      );
      return result?.dartify();
    };

class ExportGlobal implements wasm_global.Global<ExternRef, Object?> {
  ExportGlobal(this.host);

  final js_global.JSGlobal host;

  @override
  Object? get value => host.value?.dartify();

  @override
  set value(Object? value) {
    host.value = value.jsify();
  }
}

class ExportMemory implements wasm_memory.Memory {
  ExportMemory(this.host);

  final js_memory.JSMemory host;

  @override
  ByteBuffer get buffer => host.buffer.toDart;

  @override
  int grow(int delta) => host.grow(delta);
}

class ExportTable implements wasm_table.Table<ExternRef, Object?> {
  ExportTable(this.host);

  final js_table.JSTable host;

  @override
  int get length => host.length;

  @override
  Object? get(int index) => host.get(index)?.dartify();

  @override
  void set(int index, Object? value) {
    host.set(index, value.jsify());
  }

  @override
  int grow(int delta, [Object? value]) {
    if (value == null) {
      return host.grow(delta);
    }
    return host.grow(delta, value.jsify());
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
