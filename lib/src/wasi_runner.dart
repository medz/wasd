import 'dart:typed_data';

import 'imports.dart';
import 'instance.dart';
import 'memory.dart';
import 'table.dart';
import 'wasi_preview1.dart';

final class WasiRunner {
  WasiRunner({
    WasiPreview1? wasi,
    this.startExport = '_start',
    this.memoryExportName = 'memory',
    WasmImports extraImports = const WasmImports(),
  }) : wasi = wasi ?? WasiPreview1(),
       _extraImports = extraImports;

  final WasiPreview1 wasi;
  final String startExport;
  final String memoryExportName;
  final WasmImports _extraImports;

  WasmInstance instantiate(Uint8List wasmBytes) {
    final instance = WasmInstance.fromBytes(
      wasmBytes,
      imports: _mergedImports(wasi.imports, _extraImports),
    );
    _tryBindMemory(instance);
    return instance;
  }

  int runStartFromBytes(Uint8List wasmBytes, [List<Object?> args = const []]) {
    final instance = instantiate(wasmBytes);
    return runStart(instance, args);
  }

  int runStart(WasmInstance instance, [List<Object?> args = const []]) {
    _tryBindMemory(instance);
    try {
      instance.invoke(startExport, args);
      return 0;
    } on WasiProcExit catch (exit) {
      return exit.exitCode;
    }
  }

  void _tryBindMemory(WasmInstance instance) {
    if (instance.exportedMemories.contains(memoryExportName)) {
      wasi.bindMemory(instance.exportedMemory(memoryExportName));
    }
  }

  static WasmImports _mergedImports(WasmImports wasi, WasmImports extra) {
    return WasmImports(
      functions: _mergeMap<String, WasmHostFunction>(
        wasi.functions,
        extra.functions,
        label: 'function import',
      ),
      memories: _mergeMap<String, WasmMemory>(
        wasi.memories,
        extra.memories,
        label: 'memory import',
      ),
      tables: _mergeMap<String, WasmTable>(
        wasi.tables,
        extra.tables,
        label: 'table import',
      ),
      globals: _mergeMap<String, Object?>(
        wasi.globals,
        extra.globals,
        label: 'global import',
      ),
    );
  }

  static Map<K, V> _mergeMap<K, V>(
    Map<K, V> primary,
    Map<K, V> secondary, {
    required String label,
  }) {
    final merged = <K, V>{}..addAll(primary);
    for (final entry in secondary.entries) {
      if (merged.containsKey(entry.key)) {
        throw ArgumentError('Duplicate $label key: ${entry.key}');
      }
      merged[entry.key] = entry.value;
    }
    return Map.unmodifiable(merged);
  }
}
