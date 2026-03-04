import '../../errors.dart';
import '../../instance.dart' as wasm;
import '../../module.dart' as wasm;
import 'decoder.dart' as dec;
import 'memory.dart' as native_memory;
import 'module.dart' as native_module;
import 'runtime.dart' as rt;

class Instance implements wasm.Instance {
  Instance(wasm.Module module, [wasm.Imports imports = const {}])
    : _module = module,
      _memories = _buildMemories(module),
      _hostFunctions = _buildHostFunctions(module, imports) {
    _exports = _buildExports();
  }

  final wasm.Module _module;
  final List<rt.LinearMemory> _memories;
  final List<rt.HostFn> _hostFunctions;
  late final wasm.Exports _exports;

  @override
  wasm.Exports get exports => _exports;

  // ── Setup ──────────────────────────────────────────────────────────────────

  static List<rt.LinearMemory> _buildMemories(wasm.Module module) {
    final decoded = (module as native_module.Module).decoded;
    return [
      for (final mem in decoded.memories)
        rt.LinearMemory(minPages: mem.min, maxPages: mem.max),
    ];
  }

  static List<rt.HostFn> _buildHostFunctions(
    wasm.Module module,
    wasm.Imports imports,
  ) {
    final decoded = (module as native_module.Module).decoded;
    final hostFns = <rt.HostFn>[];
    for (final imp in decoded.imports) {
      if (imp.kind != dec.ExternKind.function) continue;
      final modImports = imports[imp.module];
      if (modImports == null) {
        throw LinkError('Missing import module: ${imp.module}');
      }
      final importValue = modImports[imp.name];
      if (importValue is! wasm.FunctionImportExportValue) {
        throw LinkError('Missing function import: ${imp.module}.${imp.name}');
      }
      hostFns.add(importValue.ref);
    }
    return hostFns;
  }

  // ── Exports ────────────────────────────────────────────────────────────────

  wasm.Exports _buildExports() {
    final decoded = (_module as native_module.Module).decoded;
    final result = <String, wasm.ExportValue>{};
    for (final exp in decoded.exports) {
      switch (exp.kind) {
        case dec.ExternKind.function:
          final idx = exp.index;
          result[exp.name] = wasm.ImportExportKind.function(
            (List<Object?> args) =>
                rt.execute(decoded, idx, args, _hostFunctions, _memories),
          );
        case dec.ExternKind.memory:
          result[exp.name] = wasm.ImportExportKind.memory(
            native_memory.Memory.fromRuntime(_memories[exp.index]),
          );
        case dec.ExternKind.global:
        case dec.ExternKind.table:
        case dec.ExternKind.tag:
          break; // not yet supported
      }
    }
    return result;
  }
}
