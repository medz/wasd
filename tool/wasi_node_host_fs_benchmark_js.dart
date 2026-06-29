@JS()
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:wasd/src/wasi/preview1/common/constants.dart' as wasi;
import 'package:wasd/wasm.dart';
import 'package:wasd/wasi.dart';

import '../test/support/wasm_fixtures.dart';

const int _defaultIterations = 1000;
const int _defaultWarmupIterations = 50;
const int _defaultPayloadBytes = 1024;
const int _createPathBuckets = 64;
const int _pathPtr = 2048;
const int _openedFdPtr = 2304;
const int _iovPtr = 2320;
const int _bufferPtr = 2368;
const int _countPtr = 2496;
const int _filestatPtr = 2528;
const int _readChunkBytes = 32;
const int _direntBufferBytes = 16384;

final Uint8List _writeChunk = Uint8List.fromList(
  utf8.encode('wasd-node-host-fs-benchmark-io'),
);

Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  if (options.help) {
    _printUsage();
    return;
  }

  final payload = await _runBenchmark(options);
  if (options.json) {
    print(const JsonEncoder.withIndent('  ').convert(payload));
  } else {
    _printText(payload);
  }
}

Future<Map<String, Object?>> _runBenchmark(_Options options) async {
  final temp = _NodeHostTemp.create();
  try {
    final payloadText = _asciiPayload(options.payloadBytes);
    temp
      ..writeFile('data.bin', payloadText)
      ..writeFile('mutable.bin', payloadText)
      ..createDirectory('assets')
      ..writeFile('assets/a.txt', 'a')
      ..writeFile('assets/b.txt', 'b')
      ..createDirectory('assets/sub');

    final host = await _BenchmarkContext.create(
      preopens: <String, String>{'/host': temp.path},
    );
    temp.writeFile('late-root.txt', 'created after WASI construction');
    final virtual = await _BenchmarkContext.create(
      preopens: const <String, String>{'/virtual': '/virtual'},
      files: <String, Uint8List>{
        '/virtual/data.bin': Uint8List.fromList(utf8.encode(payloadText)),
        '/virtual/mutable.bin': Uint8List.fromList(utf8.encode(payloadText)),
        '/virtual/assets/a.txt': Uint8List.fromList(utf8.encode('a')),
        '/virtual/assets/b.txt': Uint8List.fromList(utf8.encode('b')),
        '/virtual/assets/sub/child.txt': Uint8List.fromList(utf8.encode('s')),
      },
    );

    _warmUp(host, virtual, options);

    final metrics = <String, Object?>{
      'host_open_close': _benchmarkOpenClose(
        host,
        'data.bin',
        options.iterations,
      ).toJson(),
      'virtual_open_close': _benchmarkOpenClose(
        virtual,
        'data.bin',
        options.iterations,
      ).toJson(),
      'host_positioned_read': _benchmarkPositionedRead(
        host,
        'data.bin',
        options,
      ).toJson(),
      'virtual_positioned_read': _benchmarkPositionedRead(
        virtual,
        'data.bin',
        options,
      ).toJson(),
      'host_positioned_write': _benchmarkPositionedWrite(
        host,
        'mutable.bin',
        options,
      ).toJson(),
      'virtual_positioned_write': _benchmarkPositionedWrite(
        virtual,
        'mutable.bin',
        options,
      ).toJson(),
      'host_create_truncate_resize_close': _benchmarkCreateTruncateResize(
        host,
        'host-created',
        options,
      ).toJson(),
      'virtual_create_truncate_resize_close': _benchmarkCreateTruncateResize(
        virtual,
        'virtual-created',
        options,
      ).toJson(),
      'host_preopen_readdir': _benchmarkPreopenReaddir(host, options).toJson(),
      'virtual_preopen_readdir': _benchmarkPreopenReaddir(
        virtual,
        options,
      ).toJson(),
      'host_directory_open_readdir_close': _benchmarkDirectoryOpenReaddirClose(
        host,
        'assets',
        options,
      ).toJson(),
      'virtual_directory_open_readdir_close':
          _benchmarkDirectoryOpenReaddirClose(
            virtual,
            'assets',
            options,
          ).toJson(),
    };

    final hostMutable = temp.readFile('mutable.bin');
    if (!hostMutable.contains('wasd-node-host-fs-benchmark-io')) {
      throw StateError('host positioned write did not persist to mutable.bin');
    }
    final expectedCreatedSize = options.payloadBytes * 2;
    final createdSize = temp.fileSize('host-created-0.bin');
    if (createdSize != expectedCreatedSize) {
      throw StateError(
        'host resize readback expected $expectedCreatedSize bytes, got '
        '$createdSize',
      );
    }
    final hostPreopenEntries = host.readDirectoryNames(3);
    if (!hostPreopenEntries.contains('late-root.txt') ||
        !hostPreopenEntries.contains('assets')) {
      throw StateError(
        'host preopen readdir did not report live root entries: '
        '$hostPreopenEntries',
      );
    }
    final hostAssetsFd = host.openDirectory('assets');
    final hostAssetEntries = host.readDirectoryNames(hostAssetsFd);
    host.close(hostAssetsFd);
    if (!hostAssetEntries.contains('a.txt') ||
        !hostAssetEntries.contains('b.txt') ||
        !hostAssetEntries.contains('sub')) {
      throw StateError(
        'host directory readdir did not report live asset entries: '
        '$hostAssetEntries',
      );
    }

    return <String, Object?>{
      'runtime': 'node-js',
      'benchmark': 'wasi-node-host-fs',
      'iterations': options.iterations,
      'warmup_iterations': options.warmupIterations,
      'payload_bytes': options.payloadBytes,
      'create_path_buckets': _createPathBuckets,
      'metrics': metrics,
      'assertions': <String, Object?>{
        'host_positioned_write_readback': true,
        'host_resize_size_bytes': createdSize,
        'host_preopen_readdir_readback': true,
        'host_directory_readdir_readback': true,
      },
    };
  } finally {
    temp.delete();
  }
}

void _warmUp(
  _BenchmarkContext host,
  _BenchmarkContext virtual,
  _Options options,
) {
  final warmup = options.copyWith(iterations: options.warmupIterations);
  _benchmarkOpenClose(host, 'data.bin', warmup.iterations);
  _benchmarkOpenClose(virtual, 'data.bin', warmup.iterations);
  _benchmarkPositionedRead(host, 'data.bin', warmup);
  _benchmarkPositionedRead(virtual, 'data.bin', warmup);
  _benchmarkPositionedWrite(host, 'mutable.bin', warmup);
  _benchmarkPositionedWrite(virtual, 'mutable.bin', warmup);
  _benchmarkCreateTruncateResize(host, 'host-warmup', warmup);
  _benchmarkCreateTruncateResize(virtual, 'virtual-warmup', warmup);
  _benchmarkPreopenReaddir(host, warmup);
  _benchmarkPreopenReaddir(virtual, warmup);
  _benchmarkDirectoryOpenReaddirClose(host, 'assets', warmup);
  _benchmarkDirectoryOpenReaddirClose(virtual, 'assets', warmup);
}

_Metric _benchmarkOpenClose(
  _BenchmarkContext context,
  String path,
  int iterations,
) {
  var checksum = 0;
  final startMicros = _nowMicros();
  for (var i = 0; i < iterations; i++) {
    final fd = context.openFile(path, _readRights);
    checksum += fd;
    context.close(fd);
  }
  return _Metric(
    operations: iterations,
    totalMicros: _nowMicros() - startMicros,
    checksum: checksum,
  );
}

_Metric _benchmarkPositionedRead(
  _BenchmarkContext context,
  String path,
  _Options options,
) {
  final fd = context.openFile(path, _readRights);
  final maxOffset = options.payloadBytes - _readChunkBytes;
  var checksum = 0;
  final startMicros = _nowMicros();
  for (var i = 0; i < options.iterations; i++) {
    checksum += context.pread(
      fd,
      length: _readChunkBytes,
      offset: maxOffset <= 0 ? 0 : (i * 17) % maxOffset,
    );
  }
  final totalMicros = _nowMicros() - startMicros;
  context.close(fd);
  return _Metric(
    operations: options.iterations,
    totalMicros: totalMicros,
    checksum: checksum,
  );
}

_Metric _benchmarkPositionedWrite(
  _BenchmarkContext context,
  String path,
  _Options options,
) {
  final fd = context.openFile(path, _writeRights);
  final maxOffset = options.payloadBytes - _writeChunk.length;
  var checksum = 0;
  final startMicros = _nowMicros();
  for (var i = 0; i < options.iterations; i++) {
    checksum += context.pwrite(
      fd,
      _writeChunk,
      offset: maxOffset <= 0 ? 0 : (i * 23) % maxOffset,
    );
  }
  final totalMicros = _nowMicros() - startMicros;
  context.close(fd);
  return _Metric(
    operations: options.iterations,
    totalMicros: totalMicros,
    checksum: checksum,
  );
}

_Metric _benchmarkCreateTruncateResize(
  _BenchmarkContext context,
  String prefix,
  _Options options,
) {
  final targetSize = options.payloadBytes * 2;
  var checksum = 0;
  final startMicros = _nowMicros();
  for (var i = 0; i < options.iterations; i++) {
    final path = '$prefix-${i % _createPathBuckets}.bin';
    final fd = context.openFile(
      path,
      _resizeRights,
      oflags: wasi.oflagCreat | wasi.oflagTrunc,
    );
    checksum += context.pwrite(fd, _writeChunk, offset: 0);
    context.setSize(fd, options.payloadBytes ~/ 2);
    context.allocate(fd, options.payloadBytes, options.payloadBytes);
    final size = context.fileSize(fd);
    if (size != targetSize) {
      throw StateError(
        'resize failed for $path: expected $targetSize, got $size',
      );
    }
    checksum += size;
    context.close(fd);
  }
  return _Metric(
    operations: options.iterations,
    totalMicros: _nowMicros() - startMicros,
    checksum: checksum,
  );
}

_Metric _benchmarkPreopenReaddir(_BenchmarkContext context, _Options options) {
  var checksum = 0;
  final startMicros = _nowMicros();
  for (var i = 0; i < options.iterations; i++) {
    checksum += context.readdir(3);
  }
  return _Metric(
    operations: options.iterations,
    totalMicros: _nowMicros() - startMicros,
    checksum: checksum,
  );
}

_Metric _benchmarkDirectoryOpenReaddirClose(
  _BenchmarkContext context,
  String path,
  _Options options,
) {
  var checksum = 0;
  final startMicros = _nowMicros();
  for (var i = 0; i < options.iterations; i++) {
    final fd = context.openDirectory(path);
    checksum += fd;
    checksum += context.readdir(fd);
    context.close(fd);
  }
  return _Metric(
    operations: options.iterations,
    totalMicros: _nowMicros() - startMicros,
    checksum: checksum,
  );
}

const int _readRights =
    wasi.rightFdRead |
    wasi.rightFdSeek |
    wasi.rightFdTell |
    wasi.rightFdFilestatGet;
const int _directoryRights = wasi.rightFdReaddir | wasi.rightFdFilestatGet;
const int _writeRights =
    wasi.rightFdWrite |
    wasi.rightFdSeek |
    wasi.rightFdTell |
    wasi.rightFdFilestatGet;
const int _resizeRights =
    _writeRights | wasi.rightFdFilestatSetSize | wasi.rightFdAllocate;

final class _BenchmarkContext {
  _BenchmarkContext._({
    required this.pathOpen,
    required this.fdClose,
    required this.fdPread,
    required this.fdPwrite,
    required this.fdReaddir,
    required this.fdFilestatGet,
    required this.fdFilestatSetSize,
    required this.fdAllocate,
    required this.bytes,
    required this.data,
  });

  final FunctionImportExportValue pathOpen;
  final FunctionImportExportValue fdClose;
  final FunctionImportExportValue fdPread;
  final FunctionImportExportValue fdPwrite;
  final FunctionImportExportValue fdReaddir;
  final FunctionImportExportValue fdFilestatGet;
  final FunctionImportExportValue fdFilestatSetSize;
  final FunctionImportExportValue fdAllocate;
  final Uint8List bytes;
  final ByteData data;

  static Future<_BenchmarkContext> create({
    required Map<String, String> preopens,
    Map<String, Uint8List> files = const <String, Uint8List>{},
  }) async {
    final wasiHost = WASI(preopens: preopens, files: files);
    final result = await WebAssembly.instantiate(
      wasiStartModuleBytes().buffer,
      wasiHost.imports,
    );
    final instance = result.instance;
    final memory = (instance.exports['memory'] as MemoryImportExportValue).ref;
    wasiHost.finalizeBindings(instance, memory: memory);
    final imports = wasiHost.imports['wasi_snapshot_preview1']!;
    return _BenchmarkContext._(
      pathOpen: imports['path_open'] as FunctionImportExportValue,
      fdClose: imports['fd_close'] as FunctionImportExportValue,
      fdPread: imports['fd_pread'] as FunctionImportExportValue,
      fdPwrite: imports['fd_pwrite'] as FunctionImportExportValue,
      fdReaddir: imports['fd_readdir'] as FunctionImportExportValue,
      fdFilestatGet: imports['fd_filestat_get'] as FunctionImportExportValue,
      fdFilestatSetSize:
          imports['fd_filestat_set_size'] as FunctionImportExportValue,
      fdAllocate: imports['fd_allocate'] as FunctionImportExportValue,
      bytes: Uint8List.view(memory.buffer),
      data: ByteData.view(memory.buffer),
    );
  }

  int openFile(String path, int rights, {int oflags = 0}) {
    final pathBytes = utf8.encode(path);
    bytes.setAll(_pathPtr, pathBytes);
    final errno = pathOpen.ref([
      3,
      0,
      _pathPtr,
      pathBytes.length,
      oflags,
      rights,
      0,
      0,
      _openedFdPtr,
    ]);
    if (errno != 0) {
      throw StateError('path_open($path) failed with errno $errno');
    }
    return data.getUint32(_openedFdPtr, Endian.little);
  }

  int openDirectory(String path) =>
      openFile(path, _directoryRights, oflags: wasi.oflagDirectory);

  int readdir(int fd) {
    final errno = fdReaddir.ref([
      fd,
      _bufferPtr,
      _direntBufferBytes,
      0,
      _countPtr,
    ]);
    if (errno != 0) {
      throw StateError('fd_readdir($fd) failed with errno $errno');
    }
    return data.getUint32(_countPtr, Endian.little);
  }

  List<String> readDirectoryNames(int fd) {
    final used = readdir(fd);
    final names = <String>[];
    var offset = _bufferPtr;
    final end = _bufferPtr + used;
    while (offset + wasi.direntSize <= end) {
      final nameLength = data.getUint32(
        offset + wasi.direntNameLengthOffset,
        Endian.little,
      );
      final namePtr = offset + wasi.direntSize;
      final nameEnd = namePtr + nameLength;
      if (nameEnd > end) {
        break;
      }
      names.add(utf8.decode(bytes.sublist(namePtr, nameEnd)));
      offset = nameEnd;
    }
    return names;
  }

  int pread(int fd, {required int length, required int offset}) {
    data.setUint32(_iovPtr, _bufferPtr, Endian.little);
    data.setUint32(_iovPtr + 4, length, Endian.little);
    final errno = fdPread.ref([fd, _iovPtr, 1, offset, _countPtr]);
    if (errno != 0) {
      throw StateError('fd_pread($fd) failed with errno $errno');
    }
    return data.getUint32(_countPtr, Endian.little);
  }

  int pwrite(int fd, Uint8List source, {required int offset}) {
    bytes.setAll(_bufferPtr, source);
    data.setUint32(_iovPtr, _bufferPtr, Endian.little);
    data.setUint32(_iovPtr + 4, source.length, Endian.little);
    final errno = fdPwrite.ref([fd, _iovPtr, 1, offset, _countPtr]);
    if (errno != 0) {
      throw StateError('fd_pwrite($fd) failed with errno $errno');
    }
    return data.getUint32(_countPtr, Endian.little);
  }

  int fileSize(int fd) {
    final errno = fdFilestatGet.ref([fd, _filestatPtr]);
    if (errno != 0) {
      throw StateError('fd_filestat_get($fd) failed with errno $errno');
    }
    return _getUint64Le(data, _filestatPtr + 32);
  }

  void setSize(int fd, int size) {
    final errno = fdFilestatSetSize.ref([fd, size]);
    if (errno != 0) {
      throw StateError('fd_filestat_set_size($fd) failed with errno $errno');
    }
  }

  void allocate(int fd, int offset, int length) {
    final errno = fdAllocate.ref([fd, offset, length]);
    if (errno != 0) {
      throw StateError('fd_allocate($fd) failed with errno $errno');
    }
  }

  void close(int fd) {
    final errno = fdClose.ref([fd]);
    if (errno != 0) {
      throw StateError('fd_close($fd) failed with errno $errno');
    }
  }
}

final class _NodeHostTemp {
  _NodeHostTemp._(this.path, this._fs, this._path);

  final String path;
  final JSObject _fs;
  final JSObject _path;

  static _NodeHostTemp create() {
    final fs = _requireNodeBuiltin('node:fs');
    final os = _requireNodeBuiltin('node:os');
    final path = _requireNodeBuiltin('node:path');
    if (fs == null || os == null || path == null) {
      throw StateError('Node.js fs/os/path builtins are required.');
    }
    final tmpdir = _jsString(
      os.callMethodVarArgs<JSAny?>('tmpdir'.toJS, const []),
    ).toDart;
    final prefix = _jsString(
      path.callMethodVarArgs<JSAny?>('join'.toJS, [
        tmpdir.toJS,
        'wasd_node_host_fs_benchmark_'.toJS,
      ]),
    ).toDart;
    final tempPath = _jsString(
      fs.callMethodVarArgs<JSAny?>('mkdtempSync'.toJS, [prefix.toJS]),
    ).toDart;
    return _NodeHostTemp._(tempPath, fs, path);
  }

  void writeFile(String relativePath, String content) {
    _fs.callMethodVarArgs<JSAny?>('writeFileSync'.toJS, [
      _join(relativePath).toJS,
      content.toJS,
    ]);
  }

  void createDirectory(String relativePath) {
    final options = JSObject()..['recursive'] = true.toJS;
    _fs.callMethodVarArgs<JSAny?>('mkdirSync'.toJS, [
      _join(relativePath).toJS,
      options,
    ]);
  }

  String readFile(String relativePath) {
    final result = _fs.callMethodVarArgs<JSAny?>('readFileSync'.toJS, [
      _join(relativePath).toJS,
      'utf8'.toJS,
    ]);
    return _jsString(result).toDart;
  }

  int fileSize(String relativePath) {
    final stat = _fs.callMethodVarArgs<JSAny?>('statSync'.toJS, [
      _join(relativePath).toJS,
    ]);
    return (stat as JSObject)
        .getProperty<JSNumber>('size'.toJS)
        .toDartDouble
        .toInt();
  }

  void delete() {
    final options = JSObject()
      ..['recursive'] = true.toJS
      ..['force'] = true.toJS;
    _fs.callMethodVarArgs<JSAny?>('rmSync'.toJS, [path.toJS, options]);
  }

  String _join(String relativePath) {
    final result = _path.callMethodVarArgs<JSAny?>('join'.toJS, [
      path.toJS,
      relativePath.toJS,
    ]);
    return _jsString(result).toDart;
  }
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

  Map<String, Object?> toJson() => <String, Object?>{
    'operations': operations,
    'total_us': totalMicros,
    'per_operation_us': operations == 0 ? 0 : totalMicros / operations,
    'checksum': checksum,
  };
}

final class _Options {
  const _Options({
    required this.iterations,
    required this.warmupIterations,
    required this.payloadBytes,
    required this.json,
    required this.help,
  });

  final int iterations;
  final int warmupIterations;
  final int payloadBytes;
  final bool json;
  final bool help;

  _Options copyWith({int? iterations}) => _Options(
    iterations: iterations ?? this.iterations,
    warmupIterations: warmupIterations,
    payloadBytes: payloadBytes,
    json: json,
    help: help,
  );

  static _Options parse(List<String> args) {
    var iterations = _defaultIterations;
    var warmup = _defaultWarmupIterations;
    var payloadBytes = _defaultPayloadBytes;
    var json = false;
    var help = false;

    for (final arg in args) {
      if (arg == '--json') {
        json = true;
      } else if (arg == '--help') {
        help = true;
      } else if (arg.startsWith('--iterations=')) {
        iterations = _positiveInt(arg, '--iterations=');
      } else if (arg.startsWith('--warmup=')) {
        warmup = _positiveInt(arg, '--warmup=');
      } else if (arg.startsWith('--payload-bytes=')) {
        payloadBytes = _positiveInt(arg, '--payload-bytes=');
      } else {
        throw FormatException('Unknown option: $arg');
      }
    }
    if (payloadBytes < _writeChunk.length + _readChunkBytes) {
      throw FormatException(
        '--payload-bytes must be at least '
        '${_writeChunk.length + _readChunkBytes}.',
      );
    }
    return _Options(
      iterations: iterations,
      warmupIterations: warmup,
      payloadBytes: payloadBytes,
      json: json,
      help: help,
    );
  }

  static int _positiveInt(String arg, String prefix) {
    final value = int.tryParse(arg.substring(prefix.length));
    if (value == null || value <= 0) {
      throw FormatException('$prefix expects a positive integer.');
    }
    return value;
  }
}

String _asciiPayload(int length) {
  final units = List<int>.generate(length, (index) => 0x61 + (index % 26));
  return String.fromCharCodes(units);
}

int _getUint64Le(ByteData data, int offset) {
  final low = data.getUint32(offset, Endian.little);
  final high = data.getUint32(offset + 4, Endian.little);
  return (high << 32) | low;
}

int _nowMicros() {
  final performance = globalContext.getProperty<JSObject?>('performance'.toJS);
  final now = performance?.callMethodVarArgs<JSNumber?>('now'.toJS, const []);
  if (now != null) {
    return (now.toDartDouble * 1000).round();
  }
  return DateTime.now().microsecondsSinceEpoch;
}

JSObject? _requireNodeBuiltin(String name) {
  final require = globalContext.getProperty<JSAny?>('require'.toJS);
  if (require == null) {
    return null;
  }
  final module = _jsRequire(name.toJS);
  if (module case final JSObject object) {
    return object;
  }
  return null;
}

void _printText(Map<String, Object?> payload) {
  final metrics = payload['metrics']! as Map<String, Object?>;
  print('WASI Node host FS benchmark');
  print('iterations: ${payload['iterations']}');
  print('payload bytes: ${payload['payload_bytes']}');
  for (final entry in metrics.entries) {
    final metric = entry.value! as Map<String, Object?>;
    print('${entry.key}: ${metric['per_operation_us']} us/op');
  }
}

void _printUsage() {
  print('''
Usage: node .dart_tool/wasi_node_host_fs_benchmark/benchmark.js [options]

Options:
  --iterations=<n>       Repetitions for each measured operation. Default: $_defaultIterations.
  --warmup=<n>           Warmup repetitions before measurement. Default: $_defaultWarmupIterations.
  --payload-bytes=<n>    Host/virtual file payload size. Default: $_defaultPayloadBytes.
  --json                 Print machine-readable JSON.
  --help                 Show this help.
''');
}

@JS('require')
external JSAny _jsRequire(JSString module);

@JS('String')
external JSString _jsString(JSAny? value);
