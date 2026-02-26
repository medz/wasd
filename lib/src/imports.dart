import 'dart:async';

import 'memory.dart';
import 'module.dart';
import 'table.dart';

typedef WasmHostFunction = Object? Function(List<Object?> args);
typedef WasmAsyncHostFunction = FutureOr<Object?> Function(List<Object?> args);

final class WasmTagImport {
  const WasmTagImport({required this.type, required this.nominalTypeKey});

  final WasmFunctionType type;
  final String nominalTypeKey;
}

final class WasmImports {
  const WasmImports({
    this.functions = const {},
    this.asyncFunctions = const {},
    this.functionTypeDepths = const {},
    this.memories = const {},
    this.tables = const {},
    this.globals = const {},
    this.tags = const {},
  });

  final Map<String, WasmHostFunction> functions;
  final Map<String, WasmAsyncHostFunction> asyncFunctions;
  final Map<String, int> functionTypeDepths;
  final Map<String, WasmMemory> memories;
  final Map<String, WasmTable> tables;
  final Map<String, Object?> globals;
  final Map<String, WasmTagImport> tags;

  static String key(String module, String name) => '$module::$name';
}
