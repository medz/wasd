import 'dart:io';
import 'dart:typed_data';

import 'package:wasd/wasd.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln(
      'Usage: dart run example/load_from_file.dart <path.wasm> <export> [args...]',
    );
    exit(64);
  }

  final wasmPath = args[0];
  final exportName = args[1];
  final callArgs = args.skip(2).map(_parseArg).toList(growable: false);

  final wasmBytes = File(wasmPath).readAsBytesSync();
  final instance = WasmInstance.fromBytes(Uint8List.fromList(wasmBytes));

  final result = instance.invoke(exportName, callArgs);
  stdout.writeln('result: $result');
}

Object _parseArg(String raw) {
  final intValue = int.tryParse(raw);
  if (intValue != null) {
    return intValue;
  }

  final doubleValue = double.tryParse(raw);
  if (doubleValue != null) {
    return doubleValue;
  }

  throw ArgumentError('Unable to parse arg `$raw` as int/double.');
}
