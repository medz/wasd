import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';

import '../../../wasm/instance.dart' as wasm;
import '../../../wasm/memory.dart' as wasm;
import '../../../wasm/module.dart' as wasm;
import '../../wasi.dart' as wasi_iface;
import '../common/constants.dart' as wasi_common;

class WASI implements wasi_iface.WASI {
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
    wasi_iface.WASIVersion version = wasi_iface.WASIVersion.preview1,
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
       _stdinFd = stdin,
       _stdoutFd = stdout,
       _stderrFd = stderr;

  final bool _returnOnExit;
  final List<Uint8List> _argsData;
  final List<Uint8List> _envData;
  final Map<int, Uint8List> _preopensByFd;
  final Map<int, String> _preopenGuestPathsByFd;
  final Map<String, Uint8List> _filesByGuestPath;
  final int _stdinFd;
  final int _stdoutFd;
  final int _stderrFd;
  final math.Random _random = math.Random();
  final Map<int, _VirtualOpenFile> _openFilesByFd = <int, _VirtualOpenFile>{};
  final Map<int, String> _openDirectoriesByFd = <int, String>{};
  int _nextVirtualFd = 64;
  final bool _traceSyscalls =
      const bool.fromEnvironment('WASI_TRACE') ||
      _isTruthyEnv(io.Platform.environment['WASI_TRACE']);
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
      'path_filestat_get': _pathFilestatGetImport,
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

        if (fd != _stdoutFd && fd != _stderrFd) {
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
          if (fd == _stdoutFd) {
            io.stdout.add(output);
          } else {
            io.stderr.add(output);
          }
        }

        if (nwrittenPtr != 0) {
          if (nwrittenPtr + 4 > bytes.length) {
            return _errnoInval;
          }
          data.setUint32(nwrittenPtr, totalBytes, Endian.little);
        }
        return _errnoSuccess;
      });

  wasm.FunctionImportExportValue
  get _argsSizesGetImport => wasm.ImportExportKind.function((
    List<Object?> args,
  ) {
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
    if (_traceSyscalls) {
      io.stderr.writeln(
        '[wasi:args_sizes_get] argc=${_argsData.length} argvBufSize=${_argsData.fold<int>(0, (sum, arg) => sum + arg.length)}',
      );
    }
    return _errnoSuccess;
  });

  wasm.FunctionImportExportValue get _argsGetImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 2) {
          return _errnoInval;
        }
        final argvPtr = _asInt(args[0]);
        final argvBufPtr = _asInt(args[1]);
        if (_traceSyscalls) {
          io.stderr.writeln('[wasi:args_get] args=${_debugArgs(_argsData)}');
        }

        final result = _writeStringVector(
          strings: _argsData,
          ptrTable: argvPtr,
          ptrBuffer: argvBufPtr,
        );
        if (_traceSyscalls && result == _errnoSuccess) {
          final view = _memoryView();
          if (view != null) {
            final guestArgs = <String>[];
            for (var i = 0; i < _argsData.length; i++) {
              final ptrEntry = argvPtr + i * 4;
              if (!_isU32InBounds(ptrEntry, view.bytes.length)) {
                continue;
              }
              final ptr = view.data.getUint32(ptrEntry, Endian.little);
              guestArgs.add(_readCString(view.bytes, ptr));
            }
            io.stderr.writeln(
              '[wasi:args_get:guest] args=${guestArgs.join(' | ')}',
            );
          }
        }
        return result;
      });

  wasm.FunctionImportExportValue
  get _environSizesGetImport => wasm.ImportExportKind.function((
    List<Object?> args,
  ) {
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
    if (_traceSyscalls) {
      io.stderr.writeln(
        '[wasi:environ_sizes_get] count=${_envData.length} environBufSize=${_envData.fold<int>(0, (sum, env) => sum + env.length)}',
      );
    }
    return _errnoSuccess;
  });

  wasm.FunctionImportExportValue get _environGetImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 2) {
          return _errnoInval;
        }
        final environPtr = _asInt(args[0]);
        final environBufPtr = _asInt(args[1]);
        if (_traceSyscalls) {
          io.stderr.writeln('[wasi:environ_get] env=${_debugArgs(_envData)}');
        }

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
        final isDirectory = _openDirectoriesByFd.containsKey(fd);
        if (fd != _stdinFd && opened == null) {
          return _errnoBadf;
        }
        if (isDirectory) {
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

  wasm.FunctionImportExportValue
  get _fdFdstatGetImport => wasm.ImportExportKind.function((
    List<Object?> args,
  ) {
    if (args.length < 2) {
      return _errnoInval;
    }
    final fd = _asInt(args[0]);
    final fdstatPtr = _asInt(args[1]);
    final isStdio = fd == _stdinFd || fd == _stdoutFd || fd == _stderrFd;
    final isDir =
        _preopenGuestPathsByFd.containsKey(fd) ||
        _openDirectoriesByFd.containsKey(fd);
    final isFile = _openFilesByFd.containsKey(fd);
    if (_traceSyscalls) {
      io.stderr.writeln(
        '[wasi:fd_fdstat_get] fd=$fd isStdio=$isStdio isDir=$isDir isFile=$isFile',
      );
    }
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
    final rightsBase = _allRightsMask;
    final rightsInheriting = isDir ? _allRightsMask : 0;
    _setUint64(data, fdstatPtr + 8, rightsBase);
    _setUint64(data, fdstatPtr + 16, rightsInheriting);
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
        final openedDirectory = _openDirectoriesByFd[fd];
        final isStdio = fd == _stdinFd || fd == _stdoutFd || fd == _stderrFd;
        final isDir = _preopenGuestPathsByFd.containsKey(fd);
        if (opened == null && openedDirectory == null && !isStdio && !isDir) {
          return _errnoBadf;
        }

        bytes.fillRange(bufPtr, bufPtr + _filestatSize, 0);
        bytes[bufPtr + 16] = opened != null
            ? _filetypeRegularFile
            : (isDir || openedDirectory != null)
            ? _filetypeDirectory
            : _filetypeCharacterDevice;
        if (opened != null) {
          _setUint64(data, bufPtr + 32, opened.bytes.length);
        }
        return _errnoSuccess;
      });

  wasm.FunctionImportExportValue get _fdCloseImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.isEmpty) {
          return _errnoInval;
        }
        final fd = _asInt(args.first);
        if (fd == _stdinFd || fd == _stdoutFd || fd == _stderrFd) {
          return _errnoSuccess;
        }
        if (_openFilesByFd.remove(fd) != null) {
          return _errnoSuccess;
        }
        if (_openDirectoriesByFd.remove(fd) != null) {
          return _errnoSuccess;
        }
        return _errnoBadf;
      });

  wasm.FunctionImportExportValue get _fdSeekImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 4) {
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
        _setUint64(data, newOffsetPtr, next);
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
        _setUint64(view.data, timePtr, nowNanos);
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
        if (_traceSyscalls) {
          io.stderr.writeln('[wasi:fd_prestat_get] fd=$fd');
        }
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
        if (_traceSyscalls) {
          io.stderr.writeln(
            '[wasi:fd_prestat_dir_name] fd=$fd pathLen=$pathLen',
          );
        }
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

  wasm.FunctionImportExportValue
  get _pathOpenImport => wasm.ImportExportKind.function((List<Object?> args) {
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

    final guestPath = _resolveGuestPath(
      bytes: bytes,
      preopenPath: preopenPath,
      pathPtr: pathPtr,
      pathLen: pathLen,
    );
    if (_traceSyscalls) {
      io.stderr.writeln(
        '[wasi:path_open] dirFd=$dirFd preopen=$preopenPath path=$guestPath len=$pathLen',
      );
    }
    if (guestPath == null) {
      return _errnoInval;
    }
    final normalizedPath = _normalizeGuestPath(guestPath);
    final fileBytes = _lookupVirtualFile(normalizedPath);
    if (_traceSyscalls) {
      io.stderr.writeln(
        '[wasi:path_open] guest=$normalizedPath found=${fileBytes != null}',
      );
    }
    if (fileBytes != null) {
      final fd = _nextVirtualFd++;
      _openFilesByFd[fd] = _VirtualOpenFile(fileBytes);
      data.setUint32(openedFdPtr, fd, Endian.little);
      return _errnoSuccess;
    }

    if (_isVirtualDirectory(normalizedPath)) {
      final fd = _nextVirtualFd++;
      _openDirectoriesByFd[fd] = normalizedPath;
      data.setUint32(openedFdPtr, fd, Endian.little);
      return _errnoSuccess;
    }

    return _errnoNoent;
  });

  wasm.FunctionImportExportValue
  get _pathFilestatGetImport => wasm.ImportExportKind.function((
    List<Object?> args,
  ) {
    if (args.length < 5) {
      return _errnoInval;
    }
    final dirFd = _asInt(args[0]);
    final pathPtr = _asInt(args[2]);
    final pathLen = _asInt(args[3]);
    final filestatPtr = _asInt(args[4]);
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
    if (filestatPtr < 0 || filestatPtr + _filestatSize > bytes.length) {
      return _errnoInval;
    }
    final guestPath = _resolveGuestPath(
      bytes: bytes,
      preopenPath: preopenPath,
      pathPtr: pathPtr,
      pathLen: pathLen,
    );
    if (_traceSyscalls) {
      io.stderr.writeln(
        '[wasi:path_filestat_get] dirFd=$dirFd preopen=$preopenPath path=$guestPath len=$pathLen',
      );
    }
    if (guestPath == null) {
      return _errnoInval;
    }

    final normalizedPath = _normalizeGuestPath(guestPath);
    final fileBytes = _lookupVirtualFile(normalizedPath);
    final isDirectory = _isVirtualDirectory(normalizedPath);
    if (fileBytes == null && !isDirectory) {
      return _errnoNoent;
    }

    bytes.fillRange(filestatPtr, filestatPtr + _filestatSize, 0);
    bytes[filestatPtr + 16] = isDirectory
        ? _filetypeDirectory
        : _filetypeRegularFile;
    if (fileBytes != null) {
      _setUint64(data, filestatPtr + 32, fileBytes.length);
    }
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

  String? _resolveGuestPath({
    required Uint8List bytes,
    required String preopenPath,
    required int pathPtr,
    required int pathLen,
  }) {
    if (pathPtr < 0 || pathLen < 0 || pathPtr + pathLen > bytes.length) {
      return null;
    }
    final decoded = utf8.decode(
      bytes.sublist(pathPtr, pathPtr + pathLen),
      allowMalformed: true,
    );
    final nul = decoded.indexOf('\u0000');
    final normalizedPath = nul == -1 ? decoded : decoded.substring(0, nul);
    return _joinGuestPath(preopenPath, normalizedPath);
  }

  bool _isVirtualDirectory(String guestPath) {
    final normalized = _normalizeGuestPath(guestPath);
    if (normalized == '/') {
      return true;
    }
    for (final preopen in _preopenGuestPathsByFd.values) {
      if (_normalizeGuestPath(preopen) == normalized) {
        return true;
      }
    }
    final prefix = '$normalized/';
    for (final filePath in _filesByGuestPath.keys) {
      if (filePath.startsWith(prefix)) {
        return true;
      }
    }
    return false;
  }

  Uint8List? _lookupVirtualFile(String guestPath) {
    final normalized = _normalizeGuestPath(guestPath);
    final direct = _filesByGuestPath[normalized];
    if (direct != null) {
      return direct;
    }
    final lower = normalized.toLowerCase();
    for (final entry in _filesByGuestPath.entries) {
      if (entry.key.toLowerCase() == lower) {
        return entry.value;
      }
    }
    final basename = _basename(normalized);
    if (basename.isEmpty) {
      return null;
    }
    final basenameLower = basename.toLowerCase();
    final basenameCompact = _compactPathToken(basenameLower);
    for (final entry in _filesByGuestPath.entries) {
      final candidateBase = _basename(entry.key);
      if (candidateBase == basename ||
          candidateBase.toLowerCase() == basenameLower ||
          _compactPathToken(candidateBase.toLowerCase()) == basenameCompact) {
        return entry.value;
      }
    }
    return null;
  }

  String _debugArgs(List<Uint8List> args) => args
      .map((entry) {
        final zero = entry.indexOf(0);
        final bytes = zero == -1 ? entry : entry.sublist(0, zero);
        return utf8.decode(bytes, allowMalformed: true);
      })
      .join(' | ');

  String _readCString(Uint8List bytes, int ptr) {
    if (ptr < 0 || ptr >= bytes.length) {
      return '';
    }
    final collected = <int>[];
    for (var index = ptr; index < bytes.length; index++) {
      final value = bytes[index];
      if (value == 0) {
        break;
      }
      collected.add(value);
    }
    return utf8.decode(collected, allowMalformed: true);
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
const int _allRightsMask = 0x1fffffff;
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

void _setUint64(ByteData data, int offset, int value) {
  final normalized = value.toUnsigned(64);
  final low = normalized & 0xffffffff;
  final high = (normalized >> 32) & 0xffffffff;
  data.setUint32(offset, low, Endian.little);
  data.setUint32(offset + 4, high, Endian.little);
}

bool _isTruthyEnv(String? value) {
  if (value == null) {
    return false;
  }
  final normalized = value.trim().toLowerCase();
  return normalized == '1' || normalized == 'true' || normalized == 'yes';
}

String _normalizeGuestPath(String path) {
  if (path.isEmpty) {
    return '/';
  }
  final sanitized = path.replaceAll('\\', '/');
  final segments = <String>[];
  for (final segment in sanitized.split('/')) {
    if (segment.isEmpty || segment == '.') {
      continue;
    }
    if (segment == '..') {
      if (segments.isNotEmpty) {
        segments.removeLast();
      }
      continue;
    }
    segments.add(segment);
  }
  if (segments.isEmpty) {
    return '/';
  }
  return '/${segments.join('/')}';
}

String _joinGuestPath(String preopen, String relative) {
  if (relative.startsWith('/')) {
    return _normalizeGuestPath(relative);
  }
  final base = _normalizeGuestPath(preopen);
  final rel = relative.trim();
  if (rel.isEmpty || rel == '.') {
    return base;
  }
  if (base == '/') {
    return _normalizeGuestPath('/$rel');
  }
  return _normalizeGuestPath('$base/$rel');
}

String _basename(String path) {
  final normalized = _normalizeGuestPath(path);
  final slash = normalized.lastIndexOf('/');
  return slash == -1 ? normalized : normalized.substring(slash + 1);
}

String _compactPathToken(String value) =>
    value.replaceAll(RegExp(r'[^a-z0-9]'), '');

Uint8List _nulTerminated(String value) =>
    Uint8List.fromList(<int>[...utf8.encode(value), 0]);

Uint8List _pathBytes(String value) => Uint8List.fromList(utf8.encode(value));

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
