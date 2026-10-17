import 'dart:async';

import '../../errors.dart';
import '../../host_control_flow.dart';
import '../../instance.dart' as wasm;
import '../../module.dart' as wasm;
import 'interpreter/imports.dart' as ir_imports;
import 'interpreter/instance.dart' as ir_instance;
import 'interpreter/memory.dart' as ir_memory;
import 'interpreter/runtime_global.dart' as ir_global;
import 'interpreter/module.dart' as ir_module;
import 'interpreter/vm.dart' as ir_vm;
import 'exception.dart' as native_exception;
import 'global.dart' as native_global;
import 'memory.dart' as native_memory;
import 'module.dart' as native_module;
import 'tag.dart' as native_tag;

final class _UnexpectedAsyncHostResult extends UnsupportedError
    implements WasmHostControlFlowException {
  _UnexpectedAsyncHostResult(String key)
    : super(
        'Host import `$key` returned a Future without declaring a Future '
        'return type. Adapt it with (_) async => await callback(...).',
      );
}

final class _HostCallbackFailure implements WasmHostControlFlowException {
  _HostCallbackFailure(this.error, this.stack);

  final Object error;
  final StackTrace stack;

  Never rethrowOriginal() => Error.throwWithStackTrace(error, stack);
}

class Instance implements wasm.Instance {
  Instance(
    wasm.Module module, [
    wasm.Imports imports = const {},
    ir_instance.WasmInstantiationPhaseMeasure? profile,
  ]) : _module = module {
    try {
      final nativeModule = module as native_module.Module;
      _runtime = ir_instance.WasmInstance.fromModule(
        nativeModule.decoded,
        features: nativeModule.features,
        imports: _buildImports(module, imports),
        validate: false,
        profile: profile,
        predecodedFunctions: nativeModule.predecodedFunctions,
      );
    } on _HostCallbackFailure catch (failure) {
      failure.rethrowOriginal();
    } on WasmHostControlFlowException {
      rethrow;
    } on ir_vm.WasmGuestException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        native_exception.Exception.fromRuntime(error),
        stackTrace,
      );
    } on WasmError {
      rethrow;
    } catch (e) {
      throw LinkError(e.toString(), cause: e);
    }
    try {
      _exports = _buildExports();
    } on WasmError {
      rethrow;
    } catch (e) {
      throw LinkError(e.toString(), cause: e);
    }
  }

  final wasm.Module _module;
  late final ir_instance.WasmInstance _runtime;
  late final wasm.Exports _exports;
  Map<String, native_tag.Tag>? _tagBindings;

  @override
  wasm.Exports get exports => _exports;

  ir_imports.WasmImports _buildImports(
    wasm.Module module,
    wasm.Imports imports,
  ) {
    final functions = <String, ir_imports.WasmHostFunction>{};
    final asyncFunctions = <String, ir_imports.WasmAsyncHostFunction>{};
    final memories = <String, ir_memory.WasmMemory>{};
    final globalBindings = <String, ir_global.RuntimeGlobal>{};
    final tags = <String, ir_imports.WasmTagImport>{};
    final decoded = (module as native_module.Module).decoded;
    final declaredTags = <(String, String)>{};
    for (final import in decoded.imports) {
      if (import.kind == ir_module.WasmImportKind.tag) {
        native_tag.Tag.checkSupportedType(
          decoded.types[import.tagType!.typeIndex],
        );
        declaredTags.add((import.module, import.name));
      }
    }
    if (decoded.exports.any(
      (export) => export.kind == ir_module.WasmExportKind.tag,
    )) {
      final tagTypes = [
        for (final import in decoded.imports)
          if (import.kind == ir_module.WasmImportKind.tag)
            decoded.types[import.tagType!.typeIndex],
        for (final tag in decoded.tags) decoded.types[tag.typeIndex],
      ];
      for (final export in decoded.exports) {
        if (export.kind == ir_module.WasmExportKind.tag) {
          native_tag.Tag.checkSupportedType(tagTypes[export.index]);
        }
      }
    }
    final declaredGlobals = {
      for (final descriptor in wasm.Module.imports(module))
        if (descriptor.kind == wasm.ImportExportKind.global)
          (descriptor.module, descriptor.name),
    };

    for (final moduleEntry in imports.entries) {
      for (final importEntry in moduleEntry.value.entries) {
        final key = ir_imports.WasmImports.key(
          moduleEntry.key,
          importEntry.key,
        );
        final importValue = importEntry.value;
        switch (importValue) {
          case wasm.FunctionImportExportValue(:final ref):
            final isAsyncTyped =
                ref is Future<Object?> Function(List<Object?>) &&
                ref is! Never Function(List<Object?>);
            if (!isAsyncTyped) {
              Object? callback(List<Object?> args) {
                try {
                  final result = ref(args);
                  if (result is Future) {
                    result.ignore();
                    throw _UnexpectedAsyncHostResult(key);
                  }
                  return result;
                } on native_exception.Exception catch (error, stackTrace) {
                  Error.throwWithStackTrace(error.host, stackTrace);
                } catch (error, stack) {
                  if (error is WasmHostControlFlowException) rethrow;
                  throw _HostCallbackFailure(error, stack);
                }
              }

              functions[key] = callback;
              asyncFunctions[key] = (args) async => callback(args);
              continue;
            }
            asyncFunctions[key] = (List<Object?> args) async {
              try {
                return await Future<Object?>.sync(() => ref(args));
              } on native_exception.Exception catch (error, stackTrace) {
                Error.throwWithStackTrace(error.host, stackTrace);
              } catch (error, stack) {
                if (error is WasmHostControlFlowException) rethrow;
                throw _HostCallbackFailure(error, stack);
              }
            };
          case wasm.MemoryImportExportValue(:final ref):
            if (ref is! native_memory.Memory) {
              throw LinkError(
                'Memory import `$key` must be created by native backend.',
              );
            }
            memories[key] = ref.host;
          case wasm.GlobalImportExportValue(:final ref):
            if (!declaredGlobals.contains((moduleEntry.key, importEntry.key))) {
              continue;
            }
            if (ref is! native_global.Global) {
              throw LinkError(
                'Global import `$key` must be created by native backend.',
              );
            }
            globalBindings[key] = ref.host;
          case wasm.TagImportExportValue(:final ref):
            if (!declaredTags.contains((moduleEntry.key, importEntry.key))) {
              continue;
            }
            if (ref is! native_tag.Tag) {
              throw LinkError(
                'Tag import `$key` must be created by native backend.',
              );
            }
            final binding = ref.host;
            tags[key] = binding;
            (_tagBindings ??= {})[binding.nominalTypeKey] = ref;
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
      globalBindings: globalBindings,
      tags: tags,
    );
  }

  Future<Object?> _invokeAsync(String name, List<Object?> args) async {
    try {
      return await _runtime.invokeAsync(name, args);
    } on _HostCallbackFailure catch (failure) {
      failure.rethrowOriginal();
    } on ir_vm.WasmGuestException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        native_exception.Exception.fromRuntime(error),
        stackTrace,
      );
    }
  }

  wasm.Exports _buildExports() {
    final result = <String, wasm.ExportValue>{};
    for (final descriptor in wasm.Module.exports(_module)) {
      final name = descriptor.name;
      switch (descriptor.kind) {
        case wasm.ImportExportKind.function:
          if (_runtime.hasAsyncOnlyHostImports) {
            result[name] = wasm.ImportExportKind.function(
              (List<Object?> args) => _invokeAsync(name, args),
            );
            continue;
          }
          result[name] = wasm.ImportExportKind.function((List<Object?> args) {
            try {
              return _runtime.invoke(name, args);
            } on _HostCallbackFailure catch (failure) {
              failure.rethrowOriginal();
            } on ir_vm.WasmGuestException catch (error, stackTrace) {
              Error.throwWithStackTrace(
                native_exception.Exception.fromRuntime(error),
                stackTrace,
              );
            }
          });
        case wasm.ImportExportKind.memory:
          final memory = _runtime.exportedMemory(name);
          result[name] = wasm.ImportExportKind.memory(
            native_memory.Memory.fromRuntime(memory),
          );
        case wasm.ImportExportKind.global:
          final binding = _runtime.exportedGlobalBinding(name);
          if (native_global.isNumericBinding(binding)) {
            result[name] = wasm.ImportExportKind.global(
              native_global.fromRuntime(binding),
            );
          }
        case wasm.ImportExportKind.tag:
          final binding = _runtime.exportedTagImport(name);
          final tag = (_tagBindings ??= {}).putIfAbsent(
            binding.nominalTypeKey,
            () => native_tag.Tag.fromRuntime(binding),
          );
          result[name] = wasm.ImportExportKind.tag(tag);
        case wasm.ImportExportKind.table:
          break;
      }
    }
    return result;
  }
}
