import '../../errors.dart';
import '../../global.dart' as wasm;
import '../../instance.dart' as wasm;
import '../../module.dart' as wasm;
import '../../value.dart';
import 'global.dart' as native_global;
import 'memory.dart' as native_memory;
import 'module.dart' as native_module;
import 'interpreter/imports.dart' as old_imports;
import 'interpreter/instance.dart' as old;
import 'interpreter/memory.dart' as old_memory;
import 'interpreter/module.dart' as old_module;
import 'interpreter/runtime_global.dart' as old_global;
import 'interpreter/value.dart' as old_value;

class Instance implements wasm.Instance {
  Instance(wasm.Module module, [wasm.Imports imports = const {}])
    : _module = module,
      _host = _instantiate(module, imports);

  Instance.fromHost(this._module, this._host);

  final wasm.Module _module;
  final old.WasmInstance _host;

  @override
  late final wasm.Exports exports = _buildExports(_module, _host);

  static old.WasmInstance _instantiate(
    wasm.Module module,
    wasm.Imports imports,
  ) {
    try {
      return old.WasmInstance.fromModule(
        (module as native_module.Module).host,
        imports: _buildWasmImports(imports),
      );
    } on StateError catch (e) {
      throw LinkError(e.message, cause: e);
    } on FormatException catch (e) {
      throw LinkError(e.message, cause: e);
    }
  }
}

// ── Import conversion ─────────────────────────────────────────────────────────

old_imports.WasmImports _buildWasmImports(wasm.Imports imports) {
  final functions = <String, old_imports.WasmHostFunction>{};
  final memories = <String, old_memory.WasmMemory>{};
  final globalBindings = <String, old_global.RuntimeGlobal>{};

  for (final moduleEntry in imports.entries) {
    for (final importEntry in moduleEntry.value.entries) {
      final key = old_imports.WasmImports.key(moduleEntry.key, importEntry.key);
      switch (importEntry.value) {
        case wasm.FunctionImportExportValue(:final ref):
          functions[key] = ref;
        case wasm.MemoryImportExportValue(:final ref):
          memories[key] = (ref as native_memory.Memory).host;
        case wasm.GlobalImportExportValue(:final ref):
          globalBindings[key] = (ref as native_global.Global).host;
        case wasm.TableImportExportValue():
          throw UnsupportedError(
            'Table imports are not yet supported by the native backend.',
          );
        case wasm.TagImportExportValue():
          throw UnsupportedError(
            'Tag imports are not yet supported by the native backend.',
          );
        case wasm.IntImportValue():
          break; // not a standard wasm import
      }
    }
  }

  return old_imports.WasmImports(
    functions: functions,
    memories: memories,
    globalBindings: globalBindings,
  );
}

// ── Export construction ───────────────────────────────────────────────────────

wasm.Exports _buildExports(wasm.Module module, old.WasmInstance host) {
  final result = <String, wasm.ExportValue>{};
  for (final desc in wasm.Module.exports(module)) {
    final name = desc.name;
    switch (desc.kind) {
      case wasm.ImportExportKind.function:
        result[name] = wasm.ImportExportKind.function(
          (List<Object?> args) => host.invoke(name, args),
        );
      case wasm.ImportExportKind.memory:
        result[name] = wasm.ImportExportKind.memory(
          native_memory.Memory.fromHost(host.exportedMemory(name)),
        );
      case wasm.ImportExportKind.global:
        result[name] = wasm.ImportExportKind.global(
          _ExportGlobal(host.exportedGlobalBinding(name)),
        );
      case wasm.ImportExportKind.table:
        // Table exports require internal index resolution; not yet supported.
        break;
      case wasm.ImportExportKind.tag:
        break;
    }
  }
  return result;
}

// ── Exported-global wrapper ───────────────────────────────────────────────────

/// Wraps a [RuntimeGlobal] from a wasm export as an untyped
/// [Global<ExternRef, Object?>], mirroring the JS backend's approach.
class _ExportGlobal implements wasm.Global<ExternRef, Object?> {
  _ExportGlobal(this._host);

  final old_global.RuntimeGlobal _host;

  @override
  Object? get value {
    final raw = _host.value.toExternal();
    // i64 may be returned as int for small values; normalise to BigInt.
    if (_host.valueType == old_module.WasmValueType.i64 && raw is int) {
      return BigInt.from(raw);
    }
    return raw;
  }

  @override
  set value(Object? v) {
    if (!_host.mutable) {
      throw StateError('Cannot set value of immutable global');
    }
    _host.setValue(old_value.WasmValue.fromExternal(_host.valueType, v));
  }
}
