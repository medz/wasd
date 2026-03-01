enum ImportExportKind<T extends Object, R extends ExportValue<T, R>> {
  function(FunctionImportExportValue._),
  global,
  memory,
  table;

  const ImportExportKind(this._factory);

  final R Function(T value) _factory;

  R call(T value) => _factory(value);
}

typedef Exports = Map<String, ExportValue>;
typedef ModuleImports = Map<String, ImportExportValue<dynamic>>;
typedef Imports = Map<String, ModuleImports>;

sealed class ImportExportValue<T extends Object> {
  const ImportExportValue._(this.ref);

  final T ref;
}

sealed class ImportValue<T extends Object> extends ImportExportValue<T> {
  ImportValue._(super.ref) : super._();
}

final class IntImportValue extends ImportValue<int> {
  IntImportValue._(super.ref) : super._();
}

sealed class ExportValue<T extends Object, R extends ExportValue<T, R>>
    extends ImportExportValue<T> {
  ExportValue._(super.ref) : super._();

  ImportExportKind<T, R> get kind;
}

final class FunctionImportExportValue
    extends ExportValue<Function, FunctionImportExportValue>
    implements ImportValue<Function> {
  FunctionImportExportValue._(super.ref) : super._();

  @override
  ImportExportKind<Function, FunctionImportExportValue> get kind => .function;
}
