import 'dart:async';

import '../../errors.dart';
import '../../host_control_flow.dart';
import '../../instance.dart' as wasm;
import '../../module.dart' as wasm;
import 'interpreter/imports.dart' as ir_imports;
import 'interpreter/instance.dart' as ir_instance;
import 'interpreter/memory.dart' as ir_memory;
import 'interpreter/runtime_global.dart' as ir_global;
import 'interpreter/table.dart' as ir_table;
import 'interpreter/module.dart' as ir_module;
import 'interpreter/vm.dart' as ir_vm;
import 'exception.dart' as native_exception;
import 'global.dart' as native_global;
import 'memory.dart' as native_memory;
import 'module.dart' as native_module;
import 'tag.dart' as native_tag;
import 'table.dart' as native_table;
import 'reference_values.dart';

String _canonicalSignature(String signature) =>
    ReferenceValues.isExtern(signature)
    ? '6f'
    : ReferenceValues.isFunction(signature)
    ? '70'
    : signature;

final class _UnexpectedAsyncHostResult extends UnsupportedError
    implements WasmHostControlFlowException {
  _UnexpectedAsyncHostResult(String key)
    : super(
        'Host import `$key` returned a Future without declaring a Future '
        'return type. Adapt it with (_) async => await callback(...).',
      );
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
        onImportsValidated: _bindTableImports,
      );
    } on HostCallbackFailure catch (failure) {
      failure.rethrowOriginal();
    } on WasmHostControlFlowException {
      rethrow;
    } on ir_vm.WasmGuestException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        native_exception.Exception.fromRuntime(error, _references),
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
  Map<ir_table.WasmTable, native_table.Table>? _tableBindings;
  Map<native_table.Table, ir_table.WasmTable>? _tableImports;
  final _references = ReferenceValues();
  bool _hasFunctionReferences = false;
  bool _hasFunctionReturningHostImports = false;
  bool _hasBackendFunctionImports = false;

  @override
  wasm.Exports get exports => _exports;

  ir_imports.WasmImports _buildImports(
    wasm.Module module,
    wasm.Imports imports,
  ) {
    final functions = <String, ir_imports.WasmHostFunction>{};
    final asyncFunctions = <String, ir_imports.WasmAsyncHostFunction>{};
    final importedFunctionTypes = <String, ir_module.WasmFunctionType>{};
    final functionReferences = <String, int>{};
    final memories = <String, ir_memory.WasmMemory>{};
    final tables = <String, ir_table.WasmTable>{};
    final globalBindings = <String, ir_global.RuntimeGlobal>{};
    final tags = <String, ir_imports.WasmTagImport>{};
    final decoded = (module as native_module.Module).decoded;
    final functionTypes = <(String, String), ir_module.WasmFunctionType>{};
    for (final import in decoded.imports) {
      if (import.kind != ir_module.WasmImportKind.function &&
          import.kind != ir_module.WasmImportKind.exactFunction) {
        continue;
      }
      final type = decoded.types[import.functionTypeIndex!];
      final key = (import.module, import.name);
      final previous = functionTypes[key];
      if (previous != null &&
          (ReferenceValues.needsConversion(previous) ||
              ReferenceValues.needsConversion(type)) &&
          (previous.paramTypeSignatures.map(_canonicalSignature).join(',') !=
                  type.paramTypeSignatures.map(_canonicalSignature).join(',') ||
              previous.resultTypeSignatures
                      .map(_canonicalSignature)
                      .join(',') !=
                  type.resultTypeSignatures
                      .map(_canonicalSignature)
                      .join(','))) {
        throw UnsupportedError(
          'Reference function imports with the same name require matching signatures.',
        );
      }
      functionTypes[key] = type;
    }
    _hasFunctionReturningHostImports = functionTypes.values.any(
      (type) => type.resultTypeSignatures.any(ReferenceValues.isFunction),
    );
    final referenceValues = WeakReference(_references);
    final globalTypes = [
      for (final import in decoded.imports)
        if (import.kind == ir_module.WasmImportKind.global) import.globalType!,
      for (final global in decoded.globals) global.type,
    ];
    final tableTypes = [
      for (final import in decoded.imports)
        if (import.kind == ir_module.WasmImportKind.table) import.tableType!,
      ...decoded.tables,
    ];
    _hasFunctionReferences =
        globalTypes.any(
          (type) => ReferenceValues.isFunction(type.valueTypeSignature),
        ) ||
        functionTypes.values.any(
          (type) =>
              type.paramTypeSignatures.any(ReferenceValues.isFunction) ||
              type.resultTypeSignatures.any(ReferenceValues.isFunction),
        );
    for (final import in decoded.imports) {
      if (import.kind == ir_module.WasmImportKind.global) {
        ReferenceValues.checkSignature(import.globalType!.valueTypeSignature);
      } else if (import.kind == ir_module.WasmImportKind.table) {
        native_table.checkSupportedType(import.tableType!);
        _hasFunctionReferences |= ReferenceValues.isFunction(
          import.tableType!.refTypeSignature,
        );
      }
    }
    for (final export in decoded.exports) {
      if (export.kind == ir_module.WasmExportKind.global) {
        ReferenceValues.checkSignature(
          globalTypes[export.index].valueTypeSignature,
        );
      } else if (export.kind == ir_module.WasmExportKind.table) {
        native_table.checkSupportedType(tableTypes[export.index]);
        _hasFunctionReferences |= ReferenceValues.isFunction(
          tableTypes[export.index].refTypeSignature,
        );
      }
    }
    final tagTypes = [
      for (final import in decoded.imports)
        if (import.kind == ir_module.WasmImportKind.tag)
          decoded.types[import.tagType!.typeIndex],
      for (final tag in decoded.tags) decoded.types[tag.typeIndex],
    ];
    _hasFunctionReferences |= tagTypes.any(
      (type) => type.paramTypeSignatures.any(
        (signature) => ReferenceValues.isFunction(
          ir_module.WasmModule.canonicalTagSignature(signature),
        ),
      ),
    );
    final declaredTags = <(String, String), List<ir_module.WasmFunctionType>>{};
    for (final import in decoded.imports) {
      if (import.kind == ir_module.WasmImportKind.tag) {
        final type = decoded.types[import.tagType!.typeIndex];
        native_tag.Tag.checkSupportedType(type);
        (declaredTags[(import.module, import.name)] ??= []).add(type);
      }
    }
    if (decoded.exports.any(
      (export) => export.kind == ir_module.WasmExportKind.tag,
    )) {
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
    final declaredTables = {
      for (final import in decoded.imports)
        if (import.kind == ir_module.WasmImportKind.table)
          (import.module, import.name),
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
            final reference = ReferenceValues.functionReference(ref);
            if (reference != null) {
              _references.encode('70', ref);
              importedFunctionTypes[key] = ir_vm.WasmVm.functionReferenceType(
                reference,
              );
              functionReferences[key] = reference;
            }
            final declaredType =
                functionTypes[(moduleEntry.key, importEntry.key)];
            if (reference != null && declaredType != null) {
              _hasBackendFunctionImports = true;
            }
            final type =
                declaredType != null &&
                    ReferenceValues.needsConversion(declaredType)
                ? declaredType
                : null;
            final isAsyncTyped =
                (ref is Future<Object?> Function(List<Object?>) &&
                    ref is! Never Function(List<Object?>)) ||
                (reference != null && ReferenceValues.functionNeedsAsync(ref));
            if (!isAsyncTyped) {
              Object? callback(List<Object?> args) {
                try {
                  final result = ref(
                    type == null
                        ? args
                        : referenceValues.target!.decodeArguments(type, args),
                  );
                  if (result is Future) {
                    result.ignore();
                    throw _UnexpectedAsyncHostResult(key);
                  }
                  return type == null
                      ? result
                      : referenceValues.target!.encodeResults(type, result);
                } on native_exception.Exception catch (error, stackTrace) {
                  error.retainIn(referenceValues.target!);
                  Error.throwWithStackTrace(error.host, stackTrace);
                } catch (error, stack) {
                  if (error is WasmHostControlFlowException) rethrow;
                  throw HostCallbackFailure(error, stack);
                }
              }

              functions[key] = callback;
              if (reference == null) {
                asyncFunctions[key] = (args) async => callback(args);
                continue;
              }
            }
            asyncFunctions[key] = (List<Object?> args) async {
              try {
                final result = await Future<Object?>.sync(
                  () => ref(
                    type == null
                        ? args
                        : referenceValues.target!.decodeArguments(type, args),
                  ),
                );
                return type == null
                    ? result
                    : referenceValues.target!.encodeResults(type, result);
              } on native_exception.Exception catch (error, stackTrace) {
                error.retainIn(referenceValues.target!);
                Error.throwWithStackTrace(error.host, stackTrace);
              } catch (error, stack) {
                if (error is WasmHostControlFlowException) rethrow;
                throw HostCallbackFailure(error, stack);
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
            if (ReferenceValues.isExtern(ref.host.valueTypeSignature) ||
                ReferenceValues.isFunction(ref.host.valueTypeSignature)) {
              _references.connect(ref.references);
            }
          case wasm.TagImportExportValue(:final ref):
            final expected = declaredTags[(moduleEntry.key, importEntry.key)];
            if (expected == null) {
              continue;
            }
            if (ref is! native_tag.Tag) {
              throw LinkError(
                'Tag import `$key` must be created by native backend.',
              );
            }
            final binding = ref.host;
            final actual = binding.type.paramTypeSignatures
                .map(ir_module.WasmModule.canonicalTagSignature)
                .join(',');
            for (final type in expected) {
              if (type.paramTypeSignatures
                      .map(ir_module.WasmModule.canonicalTagSignature)
                      .join(',') !=
                  actual) {
                throw LinkError(
                  'Tag import `$key` has incompatible payload types.',
                );
              }
            }
            tags[key] = binding;
            (_tagBindings ??= {})[binding.nominalTypeKey] = ref;
          case wasm.TableImportExportValue(:final ref):
            if (!declaredTables.contains((moduleEntry.key, importEntry.key))) {
              continue;
            }
            if (ref is! native_table.Table) {
              throw LinkError(
                'Table import `$key` must be created by native backend.',
              );
            }
            final binding = (_tableImports ??= {}).putIfAbsent(
              ref,
              () => ref.prepareBinding(_references),
            );
            tables[key] = binding;
            (_tableBindings ??= {})[binding] = ref;
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
      functionTypes: importedFunctionTypes,
      functionReferences: functionReferences,
      memories: memories,
      tables: tables,
      globalBindings: globalBindings,
      tags: tags,
    );
  }

  void _bindTableImports() {
    final tables = _tableImports;
    if (tables == null) return;
    for (final entry in tables.entries) {
      entry.key.bind(entry.value, _references);
    }
    _tableImports = null;
  }

  List<Object?> _encodePublicArguments(
    int reference,
    ir_module.WasmFunctionType type,
    List<Object?> args,
    List<int>? functionParameters,
  ) {
    ReferenceValues.checkFunctionSignature(type);
    final encoded = _references.encodeArguments(type, args);
    if (functionParameters != null && encoded.length == type.params.length) {
      for (final index in functionParameters) {
        final dependency = encoded[index]! as int;
        if (dependency == -1) continue;
        _hasFunctionReferences = true;
        ir_vm.WasmVm.retainFunctionReferenceDependency(reference, dependency);
      }
    }
    return encoded;
  }

  Future<Object?> _invokeAsync(
    String name,
    List<Object?> encoded,
    ir_module.WasmFunctionType type,
    bool convert,
  ) async {
    try {
      final result =
          _hasFunctionReferences ||
              _hasFunctionReturningHostImports ||
              _hasBackendFunctionImports
          ? await _runtime.invokeAsyncForced(name, encoded)
          : await _runtime.invokeAsync(name, encoded);
      if (!convert) return result;
      return _references.decodeResults(type, result);
    } on HostCallbackFailure catch (failure) {
      failure.rethrowOriginal();
    } on ir_vm.WasmGuestException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        native_exception.Exception.fromRuntime(error, _references),
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
          final reference = _runtime.exportedFunctionReference(name);
          final type = _runtime.exportedFunctionType(name);
          final convert = ReferenceValues.needsConversion(type);
          if (type.resultTypeSignatures.any(ReferenceValues.isFunction)) {
            _hasFunctionReferences = true;
          }
          List<int>? functionParameters;
          if (convert) {
            for (var i = 0; i < type.paramTypeSignatures.length; i++) {
              if (ReferenceValues.isFunction(type.paramTypeSignatures[i])) {
                _hasFunctionReferences = true;
                (functionParameters ??= <int>[]).add(i);
              }
            }
          }
          if (_runtime.hasAsyncOnlyHostImports) {
            result[name] = wasm.ImportExportKind.function(
              _references.registerFunction(
                reference,
                (List<Object?> args) async => _invokeAsync(
                  name,
                  convert
                      ? _encodePublicArguments(
                          reference,
                          type,
                          args,
                          functionParameters,
                        )
                      : args,
                  type,
                  convert,
                ),
              ),
            );
            continue;
          }
          result[name] = wasm.ImportExportKind.function(
            _references.registerFunction(reference, (List<Object?> args) {
              try {
                final encoded = convert
                    ? _encodePublicArguments(
                        reference,
                        type,
                        args,
                        functionParameters,
                      )
                    : args;
                if (_hasFunctionReturningHostImports ||
                    ((_hasFunctionReferences || _hasBackendFunctionImports) &&
                        ir_vm.WasmVm.functionReferenceNeedsAsync(reference))) {
                  return _invokeAsync(name, encoded, type, convert);
                }
                if (!convert) return _runtime.invoke(name, encoded);
                return _references.decodeResults(
                  type,
                  _runtime.invoke(name, encoded),
                );
              } on HostCallbackFailure catch (failure) {
                failure.rethrowOriginal();
              } on ir_vm.WasmGuestException catch (error, stackTrace) {
                Error.throwWithStackTrace(
                  native_exception.Exception.fromRuntime(error, _references),
                  stackTrace,
                );
              }
            }),
          );
        case wasm.ImportExportKind.memory:
          final memory = _runtime.exportedMemory(name);
          result[name] = wasm.ImportExportKind.memory(
            native_memory.Memory.fromRuntime(memory),
          );
        case wasm.ImportExportKind.global:
          final binding = _runtime.exportedGlobalBinding(name);
          result[name] = wasm.ImportExportKind.global(
            native_global.fromRuntime(binding, _references),
          );
        case wasm.ImportExportKind.tag:
          final binding = _runtime.exportedTagImport(name);
          final tag = (_tagBindings ??= {}).putIfAbsent(
            binding.nominalTypeKey,
            () => native_tag.Tag.fromRuntime(binding),
          );
          result[name] = wasm.ImportExportKind.tag(tag);
        case wasm.ImportExportKind.table:
          final binding = _runtime.exportedTable(name);
          final table = (_tableBindings ??= {}).putIfAbsent(
            binding,
            () => native_table.fromRuntime(binding, _references),
          );
          result[name] = wasm.ImportExportKind.table(table);
      }
    }
    return result;
  }
}
