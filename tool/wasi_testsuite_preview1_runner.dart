import 'dart:io' as io;
import 'dart:typed_data';

import 'package:wasd/wasd.dart';
import 'package:wasd/wasi.dart';

Future<void> main(List<String> args) async {
  late final _RunnerOptions options;
  try {
    options = _RunnerOptions.parse(args);
  } on Object catch (error) {
    io.stderr
      ..writeln('wasd-preview1-runner: $error')
      ..writeln(_usage);
    io.exitCode = 2;
    return;
  }

  if (options.showHelp) {
    io.stdout.writeln(_usage);
    return;
  }
  if (options.showVersion) {
    io.stdout.writeln('wasd-preview1-runner local');
    return;
  }

  final wasmPath = options.wasmPath;
  if (wasmPath == null) {
    io.stderr.writeln(_usage);
    io.exitCode = 2;
    return;
  }

  final preopens = <String, String>{};
  final files = <String, Uint8List>{};
  for (final dir in options.dirs) {
    preopens[dir.guestPath] = dir.guestPath;
    files.addAll(await _readDirectoryFiles(dir));
  }

  try {
    final wasmBytes = await io.File(wasmPath).readAsBytes();
    final wasi = WASI(
      args: <String>[wasmPath, ...options.programArgs],
      env: options.env,
      preopens: preopens,
      files: files,
    );
    final result = await WebAssembly.instantiate(
      wasmBytes.buffer,
      wasi.imports,
    );
    io.exitCode = wasi.start(result.instance);
  } on Object catch (error, stackTrace) {
    io.stderr
      ..writeln('wasd-preview1-runner failed: $error')
      ..writeln(stackTrace);
    io.exitCode = 1;
  }
}

Future<Map<String, Uint8List>> _readDirectoryFiles(_PreopenDir dir) async {
  final root = io.Directory(dir.hostPath);
  if (!await root.exists()) {
    throw ArgumentError.value(dir.hostPath, 'dir', 'does not exist');
  }

  final files = <String, Uint8List>{};
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! io.File) {
      continue;
    }
    final relative = _relativePath(root.path, entity.path);
    final guestPath = _joinGuestPath(dir.guestPath, relative);
    files[guestPath] = await entity.readAsBytes();
  }
  return files;
}

String _relativePath(String root, String path) {
  final normalizedRoot = _normalizeHostPath(root);
  final normalizedPath = _normalizeHostPath(path);
  if (normalizedPath == normalizedRoot) {
    return '';
  }
  final prefix = normalizedRoot.endsWith('/')
      ? normalizedRoot
      : '$normalizedRoot/';
  if (!normalizedPath.startsWith(prefix)) {
    throw ArgumentError.value(path, 'path', 'is not under $root');
  }
  return normalizedPath.substring(prefix.length);
}

String _normalizeHostPath(String path) =>
    io.File(path).absolute.path.replaceAll(r'\', '/');

String _joinGuestPath(String guestRoot, String relative) {
  final normalizedRoot = guestRoot.startsWith('/') ? guestRoot : '/$guestRoot';
  final root = normalizedRoot == '/' ? '' : normalizedRoot;
  final cleanedRelative = relative
      .replaceAll(r'\', '/')
      .split('/')
      .where((part) => part.isNotEmpty)
      .join('/');
  if (cleanedRelative.isEmpty) {
    return normalizedRoot;
  }
  return '$root/$cleanedRelative';
}

final class _PreopenDir {
  const _PreopenDir({required this.hostPath, required this.guestPath});

  final String hostPath;
  final String guestPath;

  static _PreopenDir parse(String value) {
    final separator = value.indexOf('::');
    if (separator <= 0 || separator + 2 >= value.length) {
      throw ArgumentError.value(value, 'dir', 'expected HOST::GUEST');
    }
    return _PreopenDir(
      hostPath: value.substring(0, separator),
      guestPath: value.substring(separator + 2),
    );
  }
}

final class _RunnerOptions {
  const _RunnerOptions({
    required this.showHelp,
    required this.showVersion,
    required this.env,
    required this.dirs,
    required this.wasmPath,
    required this.programArgs,
  });

  final bool showHelp;
  final bool showVersion;
  final Map<String, String> env;
  final List<_PreopenDir> dirs;
  final String? wasmPath;
  final List<String> programArgs;

  static _RunnerOptions parse(List<String> args) {
    var showHelp = false;
    var showVersion = false;
    final env = <String, String>{};
    final dirs = <_PreopenDir>[];
    String? wasmPath;
    final programArgs = <String>[];

    for (var index = 0; index < args.length; index++) {
      final arg = args[index];
      if (wasmPath != null) {
        programArgs.add(arg);
        continue;
      }

      switch (arg) {
        case '--help':
        case '-h':
          showHelp = true;
        case '--version':
          showVersion = true;
        case '--env':
          final value = _readOptionValue(args, ++index, '--env');
          final separator = value.indexOf('=');
          if (separator <= 0) {
            throw ArgumentError.value(value, '--env', 'expected KEY=VALUE');
          }
          env[value.substring(0, separator)] = value.substring(separator + 1);
        case '--dir':
          dirs.add(_PreopenDir.parse(_readOptionValue(args, ++index, '--dir')));
        case '--':
          if (index + 1 >= args.length) {
            throw ArgumentError('-- requires a wasm path');
          }
          wasmPath = args[++index];
        default:
          if (arg.startsWith('--env=')) {
            final value = arg.substring('--env='.length);
            final separator = value.indexOf('=');
            if (separator <= 0) {
              throw ArgumentError.value(value, '--env', 'expected KEY=VALUE');
            }
            env[value.substring(0, separator)] = value.substring(separator + 1);
          } else if (arg.startsWith('--dir=')) {
            dirs.add(_PreopenDir.parse(arg.substring('--dir='.length)));
          } else if (arg.startsWith('-')) {
            throw ArgumentError('unknown option: $arg');
          } else {
            wasmPath = arg;
          }
      }
    }

    return _RunnerOptions(
      showHelp: showHelp,
      showVersion: showVersion,
      env: Map.unmodifiable(env),
      dirs: List.unmodifiable(dirs),
      wasmPath: wasmPath,
      programArgs: List.unmodifiable(programArgs),
    );
  }

  static String _readOptionValue(List<String> args, int index, String option) {
    if (index >= args.length) {
      throw ArgumentError('$option requires a value');
    }
    return args[index];
  }
}

const String _usage = '''
Usage: dart run tool/wasi_testsuite_preview1_runner.dart [options] <module.wasm> [args...]

Options:
  --env KEY=VALUE       Add a WASI environment variable.
  --dir HOST::GUEST     Snapshot HOST files into the virtual GUEST preopen.
  --version             Print runner version.
  -h, --help            Show this help.
''';
