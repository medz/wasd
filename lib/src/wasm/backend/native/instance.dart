import 'dart:async';

import '../../errors.dart';
import '../../instance.dart' as wasm;
import '../../module.dart' as wasm;
import 'interpreter/imports.dart' as ir_imports;
import 'interpreter/instance.dart' as ir_instance;
import 'interpreter/memory.dart' as ir_memory;
import 'memory.dart' as native_memory;
import 'module.dart' as native_module;

class Instance implements wasm.Instance {
  Instance(wasm.Module module, [wasm.Imports imports = const {}])
    : _module = module {
    try {
      _runtime = ir_instance.WasmInstance.fromModule(
        (module as native_module.Module).decoded,
        imports: _buildImports(imports),
      );
    } on WasmError {
      rethrow;
    } catch (e) {
      throw LinkError(e.toString(), cause: e);
    }
    _exports = _buildExports();
  }

  final wasm.Module _module;
  late final ir_instance.WasmInstance _runtime;
  late final wasm.Exports _exports;

  @override
  wasm.Exports get exports => _exports;

  static ir_imports.WasmImports _buildImports(wasm.Imports imports) {
    final functions = <String, ir_imports.WasmHostFunction>{};
    final asyncFunctions = <String, ir_imports.WasmAsyncHostFunction>{};
    final memories = <String, ir_memory.WasmMemory>{};

    for (final moduleEntry in imports.entries) {
      for (final importEntry in moduleEntry.value.entries) {
        final key = ir_imports.WasmImports.key(
          moduleEntry.key,
          importEntry.key,
        );
        final importValue = importEntry.value;
        switch (importValue) {
          case wasm.FunctionImportExportValue(:final ref):
            final isAsyncTyped = ref.runtimeType.toString().contains('Future');
            if (!isAsyncTyped) {
              functions[key] = (List<Object?> args) {
                final result = ref(args);
                if (result is Future) {
                  throw UnsupportedError(
                    'Async-only host import `$key` is not available in '
                    'the synchronous VM pipeline. Use invokeAsync on direct '
                    'exported host functions.',
                  );
                }
                return result;
              };
            }
            asyncFunctions[key] = (List<Object?> args) =>
                Future<Object?>.sync(() => ref(args));
          case wasm.MemoryImportExportValue(:final ref):
            if (ref is! native_memory.Memory) {
              throw LinkError(
                'Memory import `$key` must be created by native backend.',
              );
            }
            memories[key] = ref.host;
          default:
            throw LinkError(
              'Unsupported native import value `${importValue.runtimeType}` for `$key`.',
            );
        }
      }
    }

    return ir_imports.WasmImports(
      functions: functions,
      asyncFunctions: asyncFunctions,
      memories: memories,
    );
  }

  wasm.Exports _buildExports() {
    final result = <String, wasm.ExportValue>{};
    for (final descriptor in wasm.Module.exports(_module)) {
      final name = descriptor.name;
      switch (descriptor.kind) {
        case wasm.ImportExportKind.function:
          result[name] = wasm.ImportExportKind.function((List<Object?> args) {
            if (_runtime.hasAsyncOnlyHostImports) {
              return _runtime.invokeAsync(name, args);
            }
            try {
              return _runtime.invoke(name, args);
            } catch (error) {
              final message = '$error';
              if (message.contains('Async-only host import')) {
                return _runtime.invokeAsync(name, args);
              }
              rethrow;
            }
          });
        case wasm.ImportExportKind.memory:
          final memory = _runtime.exportedMemory(name);
          result[name] = wasm.ImportExportKind.memory(
            native_memory.Memory.fromRuntime(memory),
          );
        case wasm.ImportExportKind.global:
        case wasm.ImportExportKind.table:
        case wasm.ImportExportKind.tag:
          break;
      }
    }
    return result;
  }
}
