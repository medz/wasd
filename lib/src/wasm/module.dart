import 'dart:typed_data';

import 'global.dart';
import 'memory.dart';
import 'table.dart';

/// Kind marker and typed factory for module import/export values.
enum ImportExportKind<T extends Object, R extends ExportValue<T, R>> {
  /// Function import/export kind.
  function(FunctionImportExportValue._),

  /// Global import/export kind.
  global(GlobalImportExportValue._),

  /// Memory import/export kind.
  memory(MemoryImportExportValue._),

  /// Table import/export kind.
  table(TableImportExportValue._);

  /// Creates a kind from its concrete value factory.
  const ImportExportKind(this._factory);

  final R Function(T ref) _factory;

  /// Creates a concrete import/export value from [ref].
  R call(T ref) => _factory(ref);
}

/// Base wrapper for module import/export references.
sealed class ImportExportValue<T extends Object> {
  /// Creates an import/export wrapper from [ref].
  const ImportExportValue._(this.ref);

  /// Wrapped reference value.
  final T ref;
}

/// Marker type for import values.
sealed class ImportValue<T extends Object> extends ImportExportValue<T> {
  /// Creates an import value wrapper from [ref].
  const ImportValue._(super.ref) : super._();
}

/// Integer import value used by import object augmentation.
final class IntImportValue extends ImportValue<int> {
  /// Creates an integer import value wrapper.
  const IntImportValue._(super.ref) : super._();
}

/// Marker type for export values.
sealed class ExportValue<T extends Object, R extends ExportValue<T, R>>
    extends ImportExportValue<T> {
  /// Creates an export value wrapper from [ref].
  const ExportValue._(super.ref) : super._();

  /// Kind marker of this export value.
  ImportExportKind<T, R> get kind;
}

/// Function import/export value wrapper.
final class FunctionImportExportValue
    extends ExportValue<Function, FunctionImportExportValue>
    implements ImportValue<Function> {
  /// Creates a function import/export value wrapper.
  const FunctionImportExportValue._(super.ref) : super._();

  @override
  ImportExportKind<Function, FunctionImportExportValue> get kind => .function;
}

/// Global import/export value wrapper.
final class GlobalImportExportValue
    extends ExportValue<Global, GlobalImportExportValue>
    implements ImportValue<Global> {
  /// Creates a global import/export value wrapper.
  const GlobalImportExportValue._(super.ref) : super._();

  @override
  ImportExportKind<Global, GlobalImportExportValue> get kind => .global;
}

/// Memory import/export value wrapper.
final class MemoryImportExportValue
    extends ExportValue<Memory, MemoryImportExportValue>
    implements ImportValue<Memory> {
  /// Creates a memory import/export value wrapper.
  const MemoryImportExportValue._(super.ref) : super._();

  @override
  ImportExportKind<Memory, MemoryImportExportValue> get kind => .memory;
}

/// Table import/export value wrapper.
final class TableImportExportValue
    extends ExportValue<Table, TableImportExportValue>
    implements ImportValue<Table> {
  /// Creates a table import/export value wrapper.
  const TableImportExportValue._(super.ref) : super._();

  @override
  ImportExportKind<Table, TableImportExportValue> get kind => .table;
}

/// Export object map for an instantiated module.
typedef Exports = Map<String, ExportValue>;

/// Module-local imports map (import name -> import value).
typedef ModuleImports = Map<String, ImportValue>;

/// Full imports map (module name -> module imports).
typedef Imports = Map<String, ModuleImports>;

/// Module import descriptor metadata.
class ModuleImportDescriptor<T extends Object, R extends ExportValue<T, R>> {
  /// Creates a module import descriptor.
  const ModuleImportDescriptor({
    required this.kind,
    required this.module,
    required this.name,
  });

  /// Kind of the imported value.
  final ImportExportKind<T, R> kind;

  /// Source module name.
  final String module;

  /// Import name in the source module.
  final String name;
}

/// Module export descriptor metadata.
class ModuleExportDescriptor<T extends Object, R extends ExportValue<T, R>> {
  /// Creates a module export descriptor.
  const ModuleExportDescriptor({required this.kind, required this.name});

  /// Kind of the exported value.
  final ImportExportKind<T, R> kind;

  /// Export name.
  final String name;
}

/// Minimal module interface.
abstract class Module {
  /// Creates a module from raw [bytes].
  Module(ByteBuffer bytes);

  /// Returns all import descriptors from [moduleObject].
  static List<ModuleImportDescriptor> imports(Module moduleObject) =>
      throw UnimplementedError();

  /// Returns all export descriptors from [moduleObject].
  static List<ModuleExportDescriptor> exports(Module moduleObject) =>
      throw UnimplementedError();

  /// Returns custom section contents by [sectionName].
  static List<ByteBuffer> customSections(
    Module moduleObject,
    String sectionName,
  ) => throw UnimplementedError();
}
