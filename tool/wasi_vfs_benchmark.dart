import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wasd/src/wasi/preview1/common/constants.dart';
import 'package:wasd/src/wasi/preview1/common/vfs.dart';

const int _defaultDirectories = 64;
const int _defaultFilesPerDirectory = 32;
const int _defaultIterations = 2000;
const int _defaultOpenFds = 512;
const int _defaultMutations = 200;
const int _warmupIterations = 50;

void main(List<String> args) {
  final options = _Options.parse(args);
  if (options.help) {
    _printUsage();
    return;
  }

  final baselineFiles = _buildFiles(
    directories: options.directories,
    filesPerDirectory: options.filesPerDirectory,
  );
  _runWarmup(baselineFiles, options);

  final pathOpen = _benchmarkPathOpenClose(baselineFiles, options);
  final readdir = _benchmarkReaddir(baselineFiles, options);
  final rights = _benchmarkRightsChecks(baselineFiles, options);
  final mutations = _benchmarkMutations(baselineFiles, options);

  final payload = <String, Object?>{
    'directories': options.directories,
    'files_per_directory': options.filesPerDirectory,
    'files': baselineFiles.length,
    'iterations': options.iterations,
    'open_fds': options.openFds,
    'mutations': options.mutations,
    'path_open_close': pathOpen.toJson(),
    'readdir': readdir.toJson(),
    'rights_checks': rights.toJson(),
    'mutations_benchmark': mutations.toJson(),
  };

  if (options.json) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(payload));
  } else {
    _printText(payload);
  }
}

Map<String, Uint8List> _buildFiles({
  required int directories,
  required int filesPerDirectory,
}) {
  final files = <String, Uint8List>{};
  for (var dir = 0; dir < directories; dir++) {
    for (var file = 0; file < filesPerDirectory; file++) {
      files['/sandbox/dir$dir/file$file.bin'] = Uint8List.fromList(<int>[
        dir & 0xff,
        file & 0xff,
        (dir + file) & 0xff,
      ]);
    }
  }
  return files;
}

Preview1VirtualFileSystem _newVfs(Map<String, Uint8List> files) {
  return Preview1VirtualFileSystem(
    preopens: const <String, String>{'/sandbox': '/sandbox'},
    files: files,
  );
}

void _runWarmup(Map<String, Uint8List> files, _Options options) {
  final warmupOptions = options.copyWith(
    iterations: _warmupIterations,
    openFds: 64,
    mutations: 8,
  );
  _benchmarkPathOpenClose(files, warmupOptions);
  _benchmarkReaddir(files, warmupOptions);
  _benchmarkRightsChecks(files, warmupOptions);
  _benchmarkMutations(files, warmupOptions);
}

_Metric _benchmarkPathOpenClose(
  Map<String, Uint8List> files,
  _Options options,
) {
  final vfs = _newVfs(files);
  final paths = files.keys.toList(growable: false);
  var openedCount = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final result = vfs.openPath(
      paths[i % paths.length],
      rightsBase: rightsAll,
      rightsInheriting: 0,
    );
    final fd = result.fd;
    if (fd == null || !vfs.close(fd)) {
      throw StateError('path open/close failed at iteration $i');
    }
    openedCount++;
  }
  watch.stop();
  return _Metric(
    operations: openedCount,
    totalMicros: watch.elapsedMicroseconds,
    checksum: openedCount,
  );
}

_Metric _benchmarkReaddir(Map<String, Uint8List> files, _Options options) {
  final vfs = _newVfs(files);
  final directoryFds = <int>[];
  for (var dir = 0; dir < options.directories; dir++) {
    final result = vfs.openPath(
      '/sandbox/dir$dir',
      rightsBase: rightsAll,
      rightsInheriting: rightsAll,
    );
    final fd = result.fd;
    if (fd == null) {
      throw StateError('directory open failed for dir$dir');
    }
    directoryFds.add(fd);
  }

  var entryCount = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final fd = directoryFds[i % directoryFds.length];
    final entries = vfs.directoryEntriesForFd(fd);
    if (entries == null) {
      throw StateError('directory entries missing for fd $fd');
    }
    entryCount += entries.length;
  }
  watch.stop();
  return _Metric(
    operations: options.iterations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: entryCount,
  );
}

_Metric _benchmarkRightsChecks(Map<String, Uint8List> files, _Options options) {
  final vfs = _newVfs(files);
  final paths = files.keys.toList(growable: false);
  final fds = <int>[];
  for (var i = 0; i < options.openFds; i++) {
    final result = vfs.openPath(
      paths[i % paths.length],
      rightsBase: rightsAll,
      rightsInheriting: 0,
    );
    final fd = result.fd;
    if (fd == null) {
      throw StateError('file open failed for rights benchmark');
    }
    fds.add(fd);
  }

  var allowed = 0;
  final operations = options.iterations * fds.length;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    for (final fd in fds) {
      if (vfs.descriptorHasRight(fd, rightFdRead)) {
        allowed++;
      }
    }
  }
  watch.stop();
  return _Metric(
    operations: operations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: allowed,
  );
}

_Metric _benchmarkMutations(Map<String, Uint8List> files, _Options options) {
  final vfs = _newVfs(files);
  var successfulOperations = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.mutations; i++) {
    final dir = '/sandbox/bench$i';
    final linked = '$dir/linked.bin';
    final renamed = '$dir/renamed.bin';
    final symlink = '$dir/symlink.bin';
    _expectPathMutation(vfs.createDirectory(dir), 'createDirectory');
    successfulOperations++;
    _expectPathMutation(
      vfs.linkPath(oldPath: '/sandbox/dir0/file0.bin', newPath: linked),
      'linkPath',
    );
    successfulOperations++;
    _expectPathMutation(
      vfs.createSymlink(target: '../dir0/file1.bin', linkPath: symlink),
      'createSymlink',
    );
    successfulOperations++;
    _expectPathMutation(
      vfs.renamePath(oldPath: linked, newPath: renamed),
      'renamePath',
    );
    successfulOperations++;
    _expectPathMutation(vfs.unlinkFile(renamed), 'unlinkFile renamed');
    successfulOperations++;
    _expectPathMutation(vfs.unlinkFile(symlink), 'unlinkFile symlink');
    successfulOperations++;
    _expectPathMutation(vfs.removeDirectory(dir), 'removeDirectory');
    successfulOperations++;
  }
  watch.stop();
  return _Metric(
    operations: successfulOperations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: successfulOperations,
  );
}

void _expectPathMutation(Preview1PathMutationResult result, String operation) {
  if (result != Preview1PathMutationResult.success) {
    throw StateError('$operation failed: $result');
  }
}

void _printText(Map<String, Object?> payload) {
  stdout
    ..writeln('wasi vfs benchmark')
    ..writeln('  directories: ${payload['directories']}')
    ..writeln('  files per directory: ${payload['files_per_directory']}')
    ..writeln('  files: ${payload['files']}')
    ..writeln('  iterations: ${payload['iterations']}')
    ..writeln('  open fds: ${payload['open_fds']}')
    ..writeln('  mutations: ${payload['mutations']}');
  _printMetric('path open/close', payload['path_open_close']);
  _printMetric('readdir', payload['readdir']);
  _printMetric('rights checks', payload['rights_checks']);
  _printMetric('mutations', payload['mutations_benchmark']);
}

void _printMetric(String label, Object? raw) {
  final metric = raw! as Map<String, Object?>;
  stdout
    ..writeln('  $label operations: ${metric['operations']}')
    ..writeln('  $label total us: ${metric['total_us']}')
    ..writeln('  $label per operation us: ${metric['per_operation_us']}');
}

void _printUsage() {
  stdout.writeln('''
Usage: dart run tool/wasi_vfs_benchmark.dart [options]

Options:
  --directories=<n>          Number of virtual directories. Default: $_defaultDirectories.
  --files-per-directory=<n>  Number of files under each directory. Default: $_defaultFilesPerDirectory.
  --iterations=<n>           Repetitions for open/readdir/right checks. Default: $_defaultIterations.
  --open-fds=<n>             Descriptors opened for rights checks. Default: $_defaultOpenFds.
  --mutations=<n>            Directory/link/symlink mutation cycles. Default: $_defaultMutations.
  --json                     Print machine-readable JSON.
  --help                     Show this help.
''');
}

final class _Metric {
  const _Metric({
    required this.operations,
    required this.totalMicros,
    required this.checksum,
  });

  final int operations;
  final int totalMicros;
  final int checksum;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'operations': operations,
      'total_us': totalMicros,
      'per_operation_us': totalMicros / operations,
      'checksum': checksum,
    };
  }
}

final class _Options {
  const _Options({
    required this.directories,
    required this.filesPerDirectory,
    required this.iterations,
    required this.openFds,
    required this.mutations,
    required this.json,
    required this.help,
  });

  final int directories;
  final int filesPerDirectory;
  final int iterations;
  final int openFds;
  final int mutations;
  final bool json;
  final bool help;

  _Options copyWith({int? iterations, int? openFds, int? mutations}) {
    return _Options(
      directories: directories,
      filesPerDirectory: filesPerDirectory,
      iterations: iterations ?? this.iterations,
      openFds: openFds ?? this.openFds,
      mutations: mutations ?? this.mutations,
      json: json,
      help: help,
    );
  }

  factory _Options.parse(List<String> args) {
    var directories = _defaultDirectories;
    var filesPerDirectory = _defaultFilesPerDirectory;
    var iterations = _defaultIterations;
    var openFds = _defaultOpenFds;
    var mutations = _defaultMutations;
    var json = false;
    var help = false;

    for (final arg in args) {
      if (arg == '--json') {
        json = true;
      } else if (arg == '--help' || arg == '-h') {
        help = true;
      } else if (arg.startsWith('--directories=')) {
        directories = _positiveInt(arg, '--directories');
      } else if (arg.startsWith('--files-per-directory=')) {
        filesPerDirectory = _positiveInt(arg, '--files-per-directory');
      } else if (arg.startsWith('--iterations=')) {
        iterations = _positiveInt(arg, '--iterations');
      } else if (arg.startsWith('--open-fds=')) {
        openFds = _positiveInt(arg, '--open-fds');
      } else if (arg.startsWith('--mutations=')) {
        mutations = _positiveInt(arg, '--mutations');
      } else {
        throw ArgumentError('Unsupported argument: $arg');
      }
    }

    return _Options(
      directories: directories,
      filesPerDirectory: filesPerDirectory,
      iterations: iterations,
      openFds: openFds,
      mutations: mutations,
      json: json,
      help: help,
    );
  }

  static int _positiveInt(String arg, String name) {
    final value = int.tryParse(arg.substring(name.length + 1));
    if (value == null || value <= 0) {
      throw ArgumentError('$name must be a positive integer.');
    }
    return value;
  }
}
