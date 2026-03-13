import 'dart:io';
import 'dart:typed_data';

import 'package:wasd/src/wasm/backend/native/interpreter/features.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/module.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/predecode.dart';

const String _defaultWasmPath = 'assets/doom/doom.wasm';

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  final wasmPath = options['wasm'] ?? _defaultWasmPath;
  final functions = _parseFunctions(options['functions']);
  if (functions.isEmpty) {
    stderr.writeln('Pass --functions=133,98,...');
    exitCode = 2;
    return;
  }

  final wasmBytes = await File(wasmPath).readAsBytes();
  final module = WasmModule.decode(
    Uint8List.fromList(wasmBytes),
    features: const WasmFeatureSet(),
  );
  final importedFunctionCount = module.imports
      .where(
        (import) =>
            import.kind == WasmImportKind.function ||
            import.kind == WasmImportKind.exactFunction,
      )
      .length;
  final memory64ByIndex = List<bool>.generate(
    module.memories.length,
    (index) => module.memories[index].isMemory64,
    growable: false,
  );

  for (final functionIndex in functions) {
    stdout.writeln('== function $functionIndex ==');
    if (functionIndex < importedFunctionCount) {
      final imported = module.imports
          .where(
            (import) =>
                import.kind == WasmImportKind.function ||
                import.kind == WasmImportKind.exactFunction,
          )
          .toList(growable: false)[functionIndex];
      stdout.writeln(
        'import ${imported.module}.${imported.name} type=${imported.functionTypeIndex}',
      );
      continue;
    }

    final codeIndex = functionIndex - importedFunctionCount;
    if (codeIndex < 0 || codeIndex >= module.codes.length) {
      stdout.writeln('out-of-range');
      continue;
    }

    final typeIndex = module.functionTypeIndices[codeIndex];
    final predecoded = WasmPredecoder.decode(
      module.codes[codeIndex],
      module.types,
      features: const WasmFeatureSet(),
      memory64ByIndex: memory64ByIndex,
    );
    final histogram = <int, int>{};
    for (final instruction in predecoded.instructions) {
      histogram.update(
        instruction.opcode,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final topOpcodes = histogram.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    stdout.writeln('codeIndex=$codeIndex typeIndex=$typeIndex');
    stdout.writeln(
      'params=${module.types[typeIndex].params.length} '
      'results=${module.types[typeIndex].results.length} '
      'locals=${predecoded.localTypes.length} '
      'instructions=${predecoded.instructions.length}',
    );
    for (final entry in topOpcodes.take(12)) {
      stdout.writeln(
        'opcode=0x${entry.key.toRadixString(16)} count=${entry.value}',
      );
    }
  }
}

Map<String, String> _parseArgs(List<String> args) {
  final result = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) {
      continue;
    }
    final eq = arg.indexOf('=');
    if (eq != -1) {
      result[arg.substring(2, eq)] = arg.substring(eq + 1);
      continue;
    }
    final key = arg.substring(2);
    if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
      result[key] = args[i + 1];
      i++;
      continue;
    }
    result[key] = 'true';
  }
  return result;
}

List<int> _parseFunctions(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return const <int>[];
  }
  return raw
      .split(',')
      .map((item) => int.tryParse(item.trim()))
      .whereType<int>()
      .toList(growable: false);
}
