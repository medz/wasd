import 'memory.dart';
import 'table.dart';

typedef WasmHostFunction = Object? Function(List<Object?> args);

final class WasmImports {
  const WasmImports({
    this.functions = const {},
    this.memories = const {},
    this.tables = const {},
    this.globals = const {},
  });

  final Map<String, WasmHostFunction> functions;
  final Map<String, WasmMemory> memories;
  final Map<String, WasmTable> tables;
  final Map<String, Object?> globals;

  static String key(String module, String name) => '$module::$name';
}
