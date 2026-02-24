import 'dart:io';
import 'dart:typed_data';

import 'package:pure_wasm_runtime/pure_wasm_runtime.dart';

void main(List<String> args) {
  final rootPath = args.isEmpty ? 'example/wasm' : args.first;
  final root = Directory(rootPath);
  if (!root.existsSync()) {
    stderr.writeln('Directory not found: $rootPath');
    exit(66);
  }

  final wasmFiles = root
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((file) => file.path.endsWith('.wasm'))
      .toList(growable: false);

  if (wasmFiles.isEmpty) {
    stdout.writeln('No .wasm files found under: $rootPath');
    return;
  }

  for (final file in wasmFiles) {
    stdout.writeln('== ${file.path} ==');
    try {
      final bytes = Uint8List.fromList(file.readAsBytesSync());
      final instance = WasmInstance.fromBytes(bytes);
      stdout.writeln('  functions: ${instance.exportedFunctions}');
      stdout.writeln('  globals:   ${instance.exportedGlobals}');
      stdout.writeln('  memories:  ${instance.exportedMemories}');
      stdout.writeln('  tables:    ${instance.exportedTables}');
    } catch (error) {
      stdout.writeln('  failed to load: $error');
    }
  }
}
