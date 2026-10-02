import 'dart:typed_data';

import 'backend/native/module.dart'
    if (dart.library.js_interop) 'backend/js/module.dart'
    as backend;
import 'global.dart';
import 'memory.dart';
import 'table.dart';
import 'tag.dart';

/// Kind marker and typed factory for module import/export values.
enum ImportExportKind<T extends Object, R extends ExportValue<T, R>> {
  /// Function import/export kind.
  function(FunctionImportExportValue._),

  /// Global import/export kind.
  global(GlobalImportExportValue._),

  /// Memory import/export kind.
  memory(MemoryImportExportValue._),

  /// Table import/export kind.
  table(TableImportExportValue._),

  /// Tag import/export kind.
  tag(TagImportExportValue._);

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

/// The Dart calling convention for host functions passed to or received from
/// WebAssembly: arguments are delivered as a [List] and the return value is
/// nullable.
typedef WasmFunction = Object? Function(List<Object?>);

/// Function import/export value wrapper.
final class FunctionImportExportValue
    extends ExportValue<WasmFunction, FunctionImportExportValue>
    implements ImportValue<WasmFunction> {
  /// Creates a function import/export value wrapper.
  const FunctionImportExportValue._(super.ref) : super._();

  @override
  ImportExportKind<WasmFunction, FunctionImportExportValue> get kind =>
      .function;
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

/// Tag import/export value wrapper.
final class TagImportExportValue extends ExportValue<Tag, TagImportExportValue>
    implements ImportValue<Tag> {
  /// Creates a tag import/export value wrapper.
  const TagImportExportValue._(super.ref) : super._();

  @override
  ImportExportKind<Tag, TagImportExportValue> get kind => .tag;
}

/// Export object map for an instantiated module.
typedef Exports = Map<String, ExportValue>;

/// Module-local imports map (import name -> import value).
typedef ModuleImports = Map<String, ImportValue>;

/// Full imports map (module name -> module imports).
typedef Imports = Map<String, ModuleImports>;

/// Module import descriptor metadata.
class ModuleImportDescriptor {
  /// Creates a module import descriptor.
  const ModuleImportDescriptor({
    required this.kind,
    required this.module,
    required this.name,
  });

  /// Kind of the imported value.
  final ImportExportKind kind;

  /// Source module name.
  final String module;

  /// Import name in the source module.
  final String name;
}

/// Module export descriptor metadata.
class ModuleExportDescriptor {
  /// Creates a module export descriptor.
  const ModuleExportDescriptor({required this.kind, required this.name});

  /// Kind of the exported value.
  final ImportExportKind kind;

  /// Export name.
  final String name;
}

/// Optional Core extensions selectable through [Module].
///
/// This list is not a complete inventory of default instructions or a claim of
/// conformance to a whole Core specification release.
enum CoreFeature {
  /// Multiple linear memories, including indexed memory instructions and data.
  multiMemory,
}

/// Minimal module interface.
abstract interface class Module {
  /// Creates a module from raw [bytes].
  ///
  /// [features] adds explicitly supported extensions to the existing backend
  /// defaults. An empty set preserves default compilation behavior. Unsupported
  /// options and invalid modules throw `CompileError`; options are never ignored.
  factory Module(ByteBuffer bytes, {Set<CoreFeature> features}) =
      backend.Module;

  /// Immutable set of explicit options supported by the selected backend.
  ///
  /// The Dart VM supports [CoreFeature.multiMemory]. The JavaScript adapter
  /// currently supports no explicit options; its default compilation still
  /// follows the platform WebAssembly engine. This query does not enumerate
  /// features that a backend may accept by default.
  static Set<CoreFeature> get supportedFeatures =>
      backend.Module.supportedFeatures;

  /// Returns all import descriptors from [module].
  static List<ModuleImportDescriptor> imports(Module module) =>
      backend.imports(module);

  /// Returns all export descriptors from [module].
  static List<ModuleExportDescriptor> exports(Module module) =>
      backend.exports(module);

  /// Returns custom section contents by [name].
  static List<ByteBuffer> customSections(Module module, String name) =>
      backend.customSections(module, name);
}
