import 'dart:io';
import 'dart:typed_data';

import 'package:wasd/wasm.dart';
import 'package:wasd/wasi.dart';

const String _defaultWasmPath = 'test/fixtures/doom/doom.wasm';
const String _defaultIwadPath = 'test/fixtures/doom/doom1.wad';
const String _defaultGuestRoot = '/doom';
const String _defaultMode = 'instantiate';
const String _defaultTimedemo = 'demo1';

Future<int> main(List<String> args) async {
  final options = _parseArgs(args);
  final mode = options['mode'] ?? _defaultMode;
  if (mode != 'instantiate' && mode != 'start') {
    stderr.writeln('Invalid --mode value: $mode');
    stderr.writeln('Allowed values: instantiate, start');
    return 2;
  }

  final wasmPath = options['wasm'] ?? _defaultWasmPath;
  final iwadPath = options['iwad'] ?? _defaultIwadPath;
  final guestRoot = options['guest-root'] ?? _defaultGuestRoot;
  final timedemo = options['timedemo'] ?? _defaultTimedemo;

  final wasmFile = File(wasmPath);
  final iwadFile = File(iwadPath);
  if (!await wasmFile.exists()) {
    stderr.writeln('Missing wasm file: $wasmPath');
    return 2;
  }
  if (!await iwadFile.exists()) {
    stderr.writeln('Missing IWAD file: $iwadPath');
    return 2;
  }

  final iwadName = iwadFile.uri.pathSegments.isEmpty
      ? 'doom1.wad'
      : iwadFile.uri.pathSegments.last;
  final hostPreopenDir = iwadFile.parent.path;
  final guestIwadPath = '$guestRoot/$iwadName';

  final wasmBytes = await wasmFile.readAsBytes();
  final wasiArgs = <String>[
    'doom.wasm',
    '-iwad',
    guestIwadPath,
    '-nosound',
    '-timedemo',
    timedemo,
  ];
  final wasi = WASI(
    args: wasiArgs,
    preopens: <String, String>{guestRoot: hostPreopenDir},
    env: <String, String>{'HOME': guestRoot, 'TERM': 'xterm'},
  );
  final imports = <String, ModuleImports>{
    ...wasi.imports,
    'env': _buildDoomEnvImports(),
  };

  final result = await WebAssembly.instantiate(
    Uint8List.fromList(wasmBytes).buffer,
    imports,
  );

  if (mode == 'instantiate') {
    stdout.writeln('DOOM instantiate succeeded.');
    stdout.writeln('module=$wasmPath iwad=$iwadPath');
    return 0;
  }

  final exitCode = wasi.start(result.instance);
  stdout.writeln('DOOM exited with code $exitCode');
  return exitCode;
}

ModuleImports _buildDoomEnvImports() => <String, ImportValue>{
  'ZwareDoomOpenWindow': ImportExportKind.function((List<Object?> _) => 0),
  'ZwareDoomSetPalette': ImportExportKind.function((List<Object?> _) => 0),
  'ZwareDoomRenderFrame': ImportExportKind.function((List<Object?> _) => 0),
  'ZwareDoomPendingEvent': ImportExportKind.function((List<Object?> _) => 0),
  'ZwareDoomNextEvent': ImportExportKind.function((List<Object?> _) => 0),
};

Map<String, String> _parseArgs(List<String> args) {
  final result = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) continue;
    final eq = arg.indexOf('=');
    if (eq != -1) {
      final key = arg.substring(2, eq);
      final value = arg.substring(eq + 1);
      result[key] = value;
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
