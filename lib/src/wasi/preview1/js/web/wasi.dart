import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../../../wasm/instance.dart' as wasm;
import '../../../../wasm/memory.dart' as wasm;
import '../../../../wasm/module.dart' as wasm;
import '../../../wasi.dart' as wasi;
import '../../common/constants.dart' as wasi_common;

class WASI implements wasi.WASI {
  // ignore: avoid_unused_constructor_parameters
  WASI({
    List<String> args = const [],
    Map<String, String> env = const {},
    Map<String, String> preopens = const {},
    Map<String, Uint8List> files = const {},
    bool returnOnExit = true,
    int stdin = 0,
    int stdout = 1,
    int stderr = 2,
    wasi.WASIVersion version = wasi.WASIVersion.preview1,
  }) : _returnOnExit = returnOnExit,
       _argsData = [for (final arg in args) _nulTerminated(arg)],
       _envData = [
         for (final entry in env.entries)
           _nulTerminated('${entry.key}=${entry.value}'),
       ],
       _preopensByFd = {
         for (final indexed in preopens.keys.toList().asMap().entries)
           indexed.key + 3: _pathBytes(indexed.value),
       },
       _preopenGuestPathsByFd = {
         for (final indexed in preopens.keys.toList().asMap().entries)
           indexed.key + 3: indexed.value,
       },
       _filesByGuestPath = {
         for (final entry in files.entries)
           _normalizeGuestPath(entry.key): entry.value,
       },
       _stdin = stdin,
       _stdout = stdout,
       _stderr = stderr;

  final bool _returnOnExit;
  final List<Uint8List> _argsData;
  final List<Uint8List> _envData;
  final Map<int, Uint8List> _preopensByFd;
  final Map<int, String> _preopenGuestPathsByFd;
  final Map<String, Uint8List> _filesByGuestPath;
  final int _stdin;
  final int _stdout;
  final int _stderr;
  final math.Random _random = math.Random();
  final Map<int, _VirtualOpenFile> _openFilesByFd = <int, _VirtualOpenFile>{};
  int _nextVirtualFd = 64;
  wasm.Memory? _boundMemory;
  late final wasm.FunctionImportExportValue _nosysImport =
      wasm.ImportExportKind.function((List<Object?> _) => _errnoNosys);

  @override
  wasm.Imports get imports {
    final preview1 = <String, wasm.ImportValue>{
      for (final name in _preview1NosysImports) name: _nosysImport,
      'proc_exit': _procExitImport,
      'args_sizes_get': _argsSizesGetImport,
      'args_get': _argsGetImport,
      'environ_sizes_get': _environSizesGetImport,
      'environ_get': _environGetImport,
      'random_get': _randomGetImport,
      'fd_read': _fdReadImport,
      'fd_write': _fdWriteImport,
      'fd_fdstat_get': _fdFdstatGetImport,
      'fd_filestat_get': _fdFilestatGetImport,
      'fd_close': _fdCloseImport,
      'fd_seek': _fdSeekImport,
      'clock_time_get': _clockTimeGetImport,
      'sched_yield': _schedYieldImport,
      'fd_prestat_get': _fdPrestatGetImport,
      'fd_prestat_dir_name': _fdPrestatDirNameImport,
      'path_open': _pathOpenImport,
      'poll_oneoff': _pollOneoffImport,
    };
    return {'wasi_snapshot_preview1': preview1};
  }

  wasm.FunctionImportExportValue get _procExitImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        throw _WasiExit(args.isEmpty ? 0 : _asInt(args.first));
      });

  wasm.FunctionImportExportValue get _fdWriteImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 4) {
          return _errnoInval;
        }
        final fd = _asInt(args[0]);
        final iovs = _asInt(args[1]);
        final iovsLen = _asInt(args[2]);
        final nwrittenPtr = _asInt(args[3]);

        if (fd != _stdout && fd != _stderr) {
          return _errnoBadf;
        }

        final memory = _boundMemory;
        if (memory == null) {
          return _errnoInval;
        }

        final buffer = memory.buffer;
        if (iovs < 0 || iovsLen < 0 || nwrittenPtr < 0) {
          return _errnoInval;
        }

        final bytes = Uint8List.view(buffer);
        final data = ByteData.view(buffer);
        int totalBytes = 0;
        final output = <int>[];

        for (var index = 0; index < iovsLen; index++) {
          final entry = iovs + index * _iovecEntrySize;
          if (entry + _iovecEntrySize > bytes.length) {
            return _errnoInval;
          }

          final buf = data.getUint32(entry, Endian.little);
          final len = data.getUint32(entry + 4, Endian.little);
          if (len > 0) {
            if (buf + len > bytes.length) {
              return _errnoInval;
            }
            final chunk = bytes.sublist(buf, buf + len);
            output.addAll(chunk);
          }

          totalBytes += len;
        }

        if (output.isNotEmpty) {
          print(_decodeUtf8(output));
        }

        if (nwrittenPtr != 0) {
          if (nwrittenPtr + 4 > bytes.length) {
            return _errnoInval;
          }
          data.setUint32(nwrittenPtr, totalBytes, Endian.little);
        }
        return _errnoSuccess;
      });

  wasm.FunctionImportExportValue get _argsSizesGetImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 2) {
          return _errnoInval;
        }
        final argcPtr = _asInt(args[0]);
        final argvBufSizePtr = _asInt(args[1]);

        final view = _memoryView();
        if (view == null) {
          return _errnoInval;
        }

        final bytes = view.bytes;
        final data = view.data;
        if (!_isU32InBounds(argcPtr, bytes.length) ||
            !_isU32InBounds(argvBufSizePtr, bytes.length)) {
          return _errnoInval;
        }

        data.setUint32(argcPtr, _argsData.length, Endian.little);
        data.setUint32(
          argvBufSizePtr,
          _argsData.fold<int>(0, (sum, arg) => sum + arg.length),
          Endian.little,
        );
        return _errnoSuccess;
      });

  wasm.FunctionImportExportValue get _argsGetImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 2) {
          return _errnoInval;
        }
        final argvPtr = _asInt(args[0]);
        final argvBufPtr = _asInt(args[1]);

        return _writeStringVector(
          strings: _argsData,
          ptrTable: argvPtr,
          ptrBuffer: argvBufPtr,
        );
      });

  wasm.FunctionImportExportValue get _environSizesGetImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 2) {
          return _errnoInval;
        }
        final environCountPtr = _asInt(args[0]);
        final environBufSizePtr = _asInt(args[1]);

        final view = _memoryView();
        if (view == null) {
          return _errnoInval;
        }

        final bytes = view.bytes;
        final data = view.data;
        if (!_isU32InBounds(environCountPtr, bytes.length) ||
            !_isU32InBounds(environBufSizePtr, bytes.length)) {
          return _errnoInval;
        }

        data.setUint32(environCountPtr, _envData.length, Endian.little);
        data.setUint32(
          environBufSizePtr,
          _envData.fold<int>(0, (sum, env) => sum + env.length),
          Endian.little,
        );
        return _errnoSuccess;
      });

  wasm.FunctionImportExportValue get _environGetImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 2) {
          return _errnoInval;
        }
        final environPtr = _asInt(args[0]);
        final environBufPtr = _asInt(args[1]);

        return _writeStringVector(
          strings: _envData,
          ptrTable: environPtr,
          ptrBuffer: environBufPtr,
        );
      });

  wasm.FunctionImportExportValue get _randomGetImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 2) {
          return _errnoInval;
        }
        final bufPtr = _asInt(args[0]);
        final len = _asInt(args[1]);

        final view = _memoryView();
        if (view == null) {
          return _errnoInval;
        }
        if (bufPtr < 0 || len < 0 || bufPtr + len > view.bytes.length) {
          return _errnoInval;
        }

        for (var i = 0; i < len; i++) {
          view.bytes[bufPtr + i] = _random.nextInt(256);
        }
        return _errnoSuccess;
      });

  wasm.FunctionImportExportValue get _fdReadImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 4) {
          return _errnoInval;
        }
        final fd = _asInt(args[0]);
        final iovs = _asInt(args[1]);
        final iovsLen = _asInt(args[2]);
        final nreadPtr = _asInt(args[3]);
        final opened = _openFilesByFd[fd];
        if (fd != _stdin && opened == null) {
          return _errnoBadf;
        }

        final memory = _boundMemory;
        if (memory == null) {
          return _errnoInval;
        }

        final buffer = memory.buffer;
        if (iovs < 0 || iovsLen < 0 || nreadPtr < 0) {
          return _errnoInval;
        }

        final bytes = Uint8List.view(buffer);
        final data = ByteData.view(buffer);
        var totalRead = 0;

        for (var index = 0; index < iovsLen; index++) {
          final entry = iovs + index * _iovecEntrySize;
          if (entry + _iovecEntrySize > bytes.length) {
            return _errnoInval;
          }

          final buf = data.getUint32(entry, Endian.little);
          final len = data.getUint32(entry + 4, Endian.little);
          if (len > 0 && buf + len > bytes.length) {
            return _errnoInval;
          }

          if (opened != null && len > 0) {
            final available = opened.bytes.length - opened.offset;
            if (available <= 0) {
              continue;
            }
            final toRead = math.min(len, available);
            bytes.setRange(buf, buf + toRead, opened.bytes, opened.offset);
            opened.offset += toRead;
            totalRead += toRead;
          }
        }

        if (nreadPtr != 0) {
          if (nreadPtr + 4 > bytes.length) {
            return _errnoInval;
          }
          data.setUint32(
            nreadPtr,
            opened == null ? 0 : totalRead,
            Endian.little,
          );
        }
        return _errnoSuccess;
      });

  wasm.FunctionImportExportValue get _fdFdstatGetImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 2) {
          return _errnoInval;
        }
        final fd = _asInt(args[0]);
        final fdstatPtr = _asInt(args[1]);
        final isStdio = fd == _stdin || fd == _stdout || fd == _stderr;
        final isDir = _preopenGuestPathsByFd.containsKey(fd);
        final isFile = _openFilesByFd.containsKey(fd);
        if (!isStdio && !isDir && !isFile) {
          return _errnoBadf;
        }

        final view = _memoryView();
        if (view == null) {
          return _errnoInval;
        }
        final bytes = view.bytes;
        final data = view.data;
        if (fdstatPtr < 0 || fdstatPtr + _fdstatSize > bytes.length) {
          return _errnoInval;
        }

        bytes.fillRange(fdstatPtr, fdstatPtr + _fdstatSize, 0);
        bytes[fdstatPtr] = isFile
            ? _filetypeRegularFile
            : isDir
            ? _filetypeDirectory
            : _filetypeCharacterDevice;
        data.setUint16(fdstatPtr + 2, 0, Endian.little);
        data.setUint64(fdstatPtr + 8, 0, Endian.little);
        data.setUint64(fdstatPtr + 16, 0, Endian.little);
        return _errnoSuccess;
      });

  wasm.FunctionImportExportValue get _fdFilestatGetImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 2) {
          return _errnoInval;
        }
        final fd = _asInt(args[0]);
        final bufPtr = _asInt(args[1]);

        final view = _memoryView();
        if (view == null) {
          return _errnoInval;
        }
        final bytes = view.bytes;
        final data = view.data;
        if (bufPtr < 0 || bufPtr + _filestatSize > bytes.length) {
          return _errnoInval;
        }

        final opened = _openFilesByFd[fd];
        final isStdio = fd == _stdin || fd == _stdout || fd == _stderr;
        final isDir = _preopenGuestPathsByFd.containsKey(fd);
        if (opened == null && !isStdio && !isDir) {
          return _errnoBadf;
        }

        bytes.fillRange(bufPtr, bufPtr + _filestatSize, 0);
        bytes[bufPtr + 16] = opened != null
            ? _filetypeRegularFile
            : isDir
            ? _filetypeDirectory
            : _filetypeCharacterDevice;
        if (opened != null) {
          data.setUint64(
            bufPtr + 32,
            opened.bytes.length.toUnsigned(64),
            Endian.little,
          );
        }
        return _errnoSuccess;
      });

  wasm.FunctionImportExportValue get _fdCloseImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.isEmpty) {
          return _errnoInval;
        }
        final fd = _asInt(args.first);
        if (fd == _stdin || fd == _stdout || fd == _stderr) {
          return _errnoSuccess;
        }
        if (_openFilesByFd.remove(fd) != null) {
          return _errnoSuccess;
        }
        return _errnoBadf;
      });

  wasm.FunctionImportExportValue get _fdSeekImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 5) {
          return _errnoInval;
        }
        final fd = _asInt(args[0]);
        final offset = _asInt64(args[1]);
        final whence = _asInt(args[2]);
        final newOffsetPtr = _asInt(args[3]);
        final opened = _openFilesByFd[fd];
        if (opened == null) {
          return _errnoBadf;
        }

        final view = _memoryView();
        if (view == null) {
          return _errnoInval;
        }
        final bytes = view.bytes;
        final data = view.data;
        if (newOffsetPtr < 0 || newOffsetPtr + 8 > bytes.length) {
          return _errnoInval;
        }

        final base = switch (whence) {
          0 => 0,
          1 => opened.offset,
          2 => opened.bytes.length,
          _ => -1,
        };
        if (base < 0) {
          return _errnoInval;
        }
        final next = base + offset;
        if (next < 0) {
          return _errnoInval;
        }
        opened.offset = next;
        data.setUint64(newOffsetPtr, next.toUnsigned(64), Endian.little);
        return _errnoSuccess;
      });

  wasm.FunctionImportExportValue get _clockTimeGetImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 3) {
          return _errnoInval;
        }
        final timePtr = _asInt(args[2]);

        final view = _memoryView();
        if (view == null) {
          return _errnoInval;
        }
        if (timePtr < 0 || timePtr + 8 > view.bytes.length) {
          return _errnoInval;
        }

        final nowNanos = DateTime.now().microsecondsSinceEpoch * 1000;
        view.data.setUint64(timePtr, nowNanos, Endian.little);
        return _errnoSuccess;
      });

  wasm.FunctionImportExportValue get _schedYieldImport => _nosysImport;

  wasm.FunctionImportExportValue get _fdPrestatGetImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 2) {
          return _errnoInval;
        }
        final fd = _asInt(args[0]);
        final prestatPtr = _asInt(args[1]);
        final path = _preopensByFd[fd];
        if (path == null) {
          return _errnoBadf;
        }

        final view = _memoryView();
        if (view == null) {
          return _errnoInval;
        }
        final bytes = view.bytes;
        final data = view.data;
        if (prestatPtr < 0 || prestatPtr + _prestatSize > bytes.length) {
          return _errnoInval;
        }

        bytes.fillRange(prestatPtr, prestatPtr + _prestatSize, 0);
        bytes[prestatPtr] = _preopenTypeDir;
        data.setUint32(prestatPtr + 4, path.length, Endian.little);
        return _errnoSuccess;
      });

  wasm.FunctionImportExportValue get _fdPrestatDirNameImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 3) {
          return _errnoInval;
        }
        final fd = _asInt(args[0]);
        final pathPtr = _asInt(args[1]);
        final pathLen = _asInt(args[2]);
        final path = _preopensByFd[fd];
        if (path == null) {
          return _errnoBadf;
        }

        final view = _memoryView();
        if (view == null) {
          return _errnoInval;
        }
        final bytes = view.bytes;
        if (pathPtr < 0 ||
            pathLen < path.length ||
            pathPtr + pathLen > bytes.length) {
          return _errnoInval;
        }

        bytes.setRange(pathPtr, pathPtr + path.length, path);
        return _errnoSuccess;
      });

  wasm.FunctionImportExportValue get _pathOpenImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 9) {
          return _errnoInval;
        }
        final dirFd = _asInt(args[0]);
        final pathPtr = _asInt(args[2]);
        final pathLen = _asInt(args[3]);
        final openedFdPtr = _asInt(args[8]);
        final preopenPath = _preopenGuestPathsByFd[dirFd];
        if (preopenPath == null) {
          return _errnoBadf;
        }

        final view = _memoryView();
        if (view == null) {
          return _errnoInval;
        }
        final bytes = view.bytes;
        final data = view.data;
        if (pathPtr < 0 ||
            pathLen < 0 ||
            pathPtr + pathLen > bytes.length ||
            openedFdPtr < 0 ||
            openedFdPtr + 4 > bytes.length) {
          return _errnoInval;
        }

        final relative = utf8.decode(bytes.sublist(pathPtr, pathPtr + pathLen));
        final guestPath = _joinGuestPath(preopenPath, relative);
        final fileBytes = _filesByGuestPath[guestPath];
        if (fileBytes == null) {
          return _errnoNoent;
        }

        final fd = _nextVirtualFd++;
        _openFilesByFd[fd] = _VirtualOpenFile(fileBytes);
        data.setUint32(openedFdPtr, fd, Endian.little);
        return _errnoSuccess;
      });

  wasm.FunctionImportExportValue get _pollOneoffImport => _nosysImport;

  int _writeStringVector({
    required List<Uint8List> strings,
    required int ptrTable,
    required int ptrBuffer,
  }) {
    final view = _memoryView();
    if (view == null) {
      return _errnoInval;
    }

    final bytes = view.bytes;
    final data = view.data;
    if (ptrTable < 0 || ptrBuffer < 0) {
      return _errnoInval;
    }
    final tableEnd = ptrTable + strings.length * 4;
    if (tableEnd > bytes.length) {
      return _errnoInval;
    }

    var writeOffset = ptrBuffer;
    for (var i = 0; i < strings.length; i++) {
      final entry = strings[i];
      final ptrEntry = ptrTable + i * 4;
      if (!_isU32InBounds(ptrEntry, bytes.length) ||
          writeOffset < 0 ||
          writeOffset + entry.length > bytes.length) {
        return _errnoInval;
      }

      data.setUint32(ptrEntry, writeOffset, Endian.little);
      bytes.setRange(writeOffset, writeOffset + entry.length, entry);
      writeOffset += entry.length;
    }

    return _errnoSuccess;
  }

  _MemoryView? _memoryView() {
    final memory = _boundMemory;
    if (memory == null) {
      return null;
    }
    final buffer = memory.buffer;
    return _MemoryView(Uint8List.view(buffer), ByteData.view(buffer));
  }

  @override
  int start(wasm.Instance instance) {
    finalizeBindings(instance);
    final startExport = instance.exports['_start'];
    if (startExport is! wasm.FunctionImportExportValue) {
      throw StateError('WASI start target _start is missing.');
    }
    try {
      startExport.ref(const []);
      return 0;
    } on _WasiExit catch (error) {
      if (_returnOnExit) {
        return error.exitCode;
      }
      rethrow;
    }
  }

  @override
  void initialize(wasm.Instance instance) {
    finalizeBindings(instance);
    final initializeExport = instance.exports['_initialize'];
    if (initializeExport is! wasm.FunctionImportExportValue) {
      throw StateError('WASI initialize target _initialize is missing.');
    }
    initializeExport.ref(const []);
  }

  @override
  void finalizeBindings(wasm.Instance instance, {wasm.Memory? memory}) {
    if (memory != null) {
      _boundMemory = memory;
      return;
    }

    final exportedMemory = instance.exports['memory'];
    if (exportedMemory is wasm.MemoryImportExportValue) {
      _boundMemory = exportedMemory.ref;
      return;
    }

    if (_boundMemory != null) {
      return;
    }

    throw StateError(
      'WASI finalizeBindings requires a memory export or an explicit memory.',
    );
  }
}

const int _iovecEntrySize = wasi_common.iovecEntrySize;
const int _errnoSuccess = wasi_common.errnoSuccess;
const int _errnoInval = wasi_common.errnoInval;
const int _errnoBadf = wasi_common.errnoBadf;
const int _errnoNoent = wasi_common.errnoNoent;
const int _errnoNosys = wasi_common.errnoNosys;
const int _prestatSize = wasi_common.prestatSize;
const int _preopenTypeDir = wasi_common.preopenTypeDir;
const int _fdstatSize = wasi_common.fdstatSize;
const int _filetypeCharacterDevice = wasi_common.filetypeCharacterDevice;
const int _filetypeDirectory = wasi_common.filetypeDirectory;
const int _filetypeRegularFile = wasi_common.filetypeRegularFile;
const int _filestatSize = 64;
const List<String> _preview1NosysImports = wasi_common.preview1NosysImports;

bool _isU32InBounds(int ptr, int length) => ptr >= 0 && ptr + 4 <= length;

int _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is BigInt) {
    return value.toInt();
  }
  throw ArgumentError.value(
    value,
    'args',
    'WASI args expect i32-like integer values.',
  );
}

int _asInt64(Object? value) {
  if (value is BigInt) {
    return value.toInt();
  }
  return _asInt(value);
}

String _decodeUtf8(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

Uint8List _nulTerminated(String value) =>
    Uint8List.fromList(<int>[...utf8.encode(value), 0]);

Uint8List _pathBytes(String value) => Uint8List.fromList(utf8.encode(value));

String _normalizeGuestPath(String path) {
  if (path.isEmpty) {
    return '/';
  }
  var value = path.startsWith('/') ? path : '/$path';
  while (value.length > 1 && value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

String _joinGuestPath(String preopen, String relative) {
  final base = _normalizeGuestPath(preopen);
  var rel = relative.trim();
  while (rel.startsWith('/')) {
    rel = rel.substring(1);
  }
  while (rel.startsWith('./')) {
    rel = rel.substring(2);
  }
  final joined = rel.isEmpty ? base : '$base/$rel';
  return _normalizeGuestPath(joined);
}

final class _MemoryView {
  _MemoryView(this.bytes, this.data);

  final Uint8List bytes;
  final ByteData data;
}

final class _VirtualOpenFile {
  _VirtualOpenFile(this.bytes);

  final Uint8List bytes;
  int offset = 0;
}

final class _WasiExit extends Error {
  _WasiExit(this.exitCode);

  final int exitCode;
}
