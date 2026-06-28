@JS()
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../../../wasm/instance.dart' as wasm;
import '../../../../wasm/memory.dart' as wasm;
import '../../../../wasm/module.dart' as wasm;
import '../../../wasi.dart' as wasi;
import '../../common/constants.dart' as wasi_common;
import '../../common/fd_syscalls.dart' as wasi_fd;
import '../../common/socket_syscalls.dart' as wasi_socket;
import '../../common/vfs.dart' as wasi_vfs;
import '../../socket.dart';

class WASI implements wasi.WASI {
  // ignore: avoid_unused_constructor_parameters
  WASI({
    List<String> args = const [],
    Map<String, String> env = const {},
    Map<String, String> preopens = const {},
    Map<String, Uint8List> files = const {},
    bool returnOnExit = true,
    int stdin = 0,
    List<int> stdinData = const <int>[],
    int stdout = 1,
    int stderr = 2,
    Map<int, WASIPreview1Socket> sockets = const <int, WASIPreview1Socket>{},
    wasi.WASIProcRaiseHandler? procRaiseHandler,
    wasi.WASIVersion version = wasi.WASIVersion.preview1,
  }) : _returnOnExit = returnOnExit,
       _procRaiseHandler = procRaiseHandler,
       _argsData = [for (final arg in args) wasi_vfs.nulTerminated(arg)],
       _envData = [
         for (final entry in env.entries)
           wasi_vfs.nulTerminated('${entry.key}=${entry.value}'),
       ],
       _vfs = wasi_vfs.Preview1VirtualFileSystem(
         preopens: preopens,
         files: files,
         stdinFd: stdin,
         stdoutFd: stdout,
         stderrFd: stderr,
         sockets: sockets,
       ),
       _stdinInput = wasi_vfs.Preview1VirtualOpenFile.fromBytes(
         Uint8List.fromList(stdinData),
       );

  final bool _returnOnExit;
  final wasi.WASIProcRaiseHandler? _procRaiseHandler;
  final List<Uint8List> _argsData;
  final List<Uint8List> _envData;
  final wasi_vfs.Preview1VirtualFileSystem _vfs;
  final wasi_vfs.Preview1OpenFile _stdinInput;
  static const int _maxWebCryptoGetRandomValuesLength = 65536;

  final Stopwatch _monotonicClock = Stopwatch()..start();
  ByteBuffer? _cachedMemoryBuffer;
  _MemoryView? _cachedMemoryView;
  final bool _traceSyscalls = const bool.fromEnvironment('WASI_TRACE');
  wasm.Memory? _boundMemory;
  final JSObject _crypto = _requireWebCrypto();
  late final wasm.FunctionImportExportValue _nosysImport =
      wasm.ImportExportKind.function((List<Object?> _) => _errnoNosys);

  @override
  wasm.Imports get imports {
    final preview1 = <String, wasm.ImportValue>{
      for (final name in _preview1NosysImports) name: _nosysImport,
      'proc_exit': _procExitImport,
      'proc_raise': _procRaiseImport,
      'args_sizes_get': _argsSizesGetImport,
      'args_get': _argsGetImport,
      'environ_sizes_get': _environSizesGetImport,
      'environ_get': _environGetImport,
      'random_get': _randomGetImport,
      'sock_accept': _sockAcceptImport,
      'sock_recv': _sockRecvImport,
      'sock_send': _sockSendImport,
      'sock_shutdown': _sockShutdownImport,
      'clock_res_get': _clockResGetImport,
      'fd_read': _fdReadImport,
      'fd_write': _fdWriteImport,
      'fd_advise': _fdAdviseImport,
      'fd_datasync': _fdDatasyncImport,
      'fd_pread': _fdPreadImport,
      'fd_pwrite': _fdPwriteImport,
      'fd_readdir': _fdReaddirImport,
      'fd_renumber': _fdRenumberImport,
      'fd_sync': _fdSyncImport,
      'fd_allocate': _fdAllocateImport,
      'fd_fdstat_get': _fdFdstatGetImport,
      'fd_fdstat_set_flags': _fdFdstatSetFlagsImport,
      'fd_fdstat_set_rights': _fdFdstatSetRightsImport,
      'fd_filestat_get': _fdFilestatGetImport,
      'fd_filestat_set_size': _fdFilestatSetSizeImport,
      'fd_filestat_set_times': _fdFilestatSetTimesImport,
      'fd_close': _fdCloseImport,
      'fd_seek': _fdSeekImport,
      'fd_tell': _fdTellImport,
      'clock_time_get': _clockTimeGetImport,
      'sched_yield': _schedYieldImport,
      'fd_prestat_get': _fdPrestatGetImport,
      'fd_prestat_dir_name': _fdPrestatDirNameImport,
      'path_create_directory': _pathCreateDirectoryImport,
      'path_filestat_get': _pathFilestatGetImport,
      'path_filestat_set_times': _pathFilestatSetTimesImport,
      'path_link': _pathLinkImport,
      'path_open': _pathOpenImport,
      'path_readlink': _pathReadlinkImport,
      'path_remove_directory': _pathRemoveDirectoryImport,
      'path_rename': _pathRenameImport,
      'path_symlink': _pathSymlinkImport,
      'path_unlink_file': _pathUnlinkFileImport,
      'poll_oneoff': _pollOneoffImport,
    };
    return {'wasi_snapshot_preview1': preview1};
  }

  wasm.FunctionImportExportValue get _procExitImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        throw _WasiExit(args.isEmpty ? 0 : _asInt(args.first));
      });

  wasm.FunctionImportExportValue get _procRaiseImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.isEmpty) {
          return _errnoInval;
        }
        final signal = wasi.WASIProcessSignal.fromPreview1Code(
          _asInt(args.first),
        );
        if (signal == null || signal == wasi.WASIProcessSignal.none) {
          return _errnoInval;
        }

        final handler = _procRaiseHandler;
        if (handler == null) {
          return _errnoNosys;
        }
        handler(signal);
        return _errnoSuccess;
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

        final opened = _vfs.openFileForFd(fd);
        final socket = _vfs.socketForFd(fd);
        final stdioKind = _vfs.stdioKindForFd(fd);
        final isOutput =
            stdioKind == wasi_vfs.Preview1StdioDescriptorKind.stdout ||
            stdioKind == wasi_vfs.Preview1StdioDescriptorKind.stderr;
        if (!isOutput) {
          if (opened == null && socket == null) {
            return _errnoBadf;
          }
          final right = _checkDescriptorRight(fd, _rightFdWrite);
          if (right != _errnoSuccess) {
            return right;
          }
          if (socket != null) {
            final view = _memoryView();
            if (view == null) {
              return _errnoInval;
            }
            return wasi_vfs.writeSocketFromIov(
              socket: socket,
              bytes: view.bytes,
              data: view.data,
              iovs: iovs,
              iovsLen: iovsLen,
              nwrittenPtr: nwrittenPtr,
            );
          }
          return _writeOpenFileFromIov(
            opened: opened!,
            iovs: iovs,
            iovsLen: iovsLen,
            nwrittenPtr: nwrittenPtr,
          );
        }
        final right = _checkDescriptorRight(fd, _rightFdWrite);
        if (right != _errnoSuccess) {
          return right;
        }

        final view = _memoryView();
        if (view == null) {
          return _errnoInval;
        }
        final bytes = view.bytes;
        final data = view.data;
        if (iovs < 0 ||
            iovsLen < 0 ||
            !_isU32InBounds(nwrittenPtr, bytes.length)) {
          return _errnoInval;
        }
        int totalBytes = 0;
        final output = _traceSyscalls ? <int>[] : null;

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
            output?.addAll(bytes.sublist(buf, buf + len));
          }

          totalBytes += len;
        }

        if (_traceSyscalls && output != null && output.isNotEmpty) {
          print(_decodeUtf8(output));
        }

        data.setUint32(nwrittenPtr, totalBytes, Endian.little);
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
      print(
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
            print('[wasi:args_get:guest] args=${guestArgs.join(' | ')}');
          }
        }
        return result;
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

        _fillSecureRandom(view.bytes, start: bufPtr, length: len);
        return _errnoSuccess;
      });

  void _fillSecureRandom(
    Uint8List bytes, {
    required int start,
    required int length,
  }) {
    var offset = 0;
    while (offset < length) {
      final chunkLength = math.min(
        length - offset,
        _maxWebCryptoGetRandomValuesLength,
      );
      final chunk = Uint8List.sublistView(
        bytes,
        start + offset,
        start + offset + chunkLength,
      );
      _crypto.callMethodVarArgs<JSAny?>('getRandomValues'.toJS, [chunk.toJS]);
      offset += chunkLength;
    }
  }

  wasm.FunctionImportExportValue get _sockAcceptImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 3) {
          return _errnoInval;
        }
        final view = _memoryView();
        return wasi_socket.preview1SockAccept(
          vfs: _vfs,
          fd: _asInt(args[0]),
          flags: _asInt(args[1]),
          acceptedFdPtr: _asInt(args[2]),
          bytes: view?.bytes,
          data: view?.data,
        );
      });

  wasm.FunctionImportExportValue get _sockRecvImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 6) {
          return _errnoInval;
        }
        final view = _memoryView();
        return wasi_socket.preview1SockRecv(
          vfs: _vfs,
          fd: _asInt(args[0]),
          iovs: _asInt(args[1]),
          iovsLen: _asInt(args[2]),
          flags: _asInt(args[3]),
          nreadPtr: _asInt(args[4]),
          roFlagsPtr: _asInt(args[5]),
          bytes: view?.bytes,
          data: view?.data,
        );
      });

  wasm.FunctionImportExportValue get _sockSendImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 5) {
          return _errnoInval;
        }
        final view = _memoryView();
        return wasi_socket.preview1SockSend(
          vfs: _vfs,
          fd: _asInt(args[0]),
          iovs: _asInt(args[1]),
          iovsLen: _asInt(args[2]),
          flags: _asInt(args[3]),
          nwrittenPtr: _asInt(args[4]),
          bytes: view?.bytes,
          data: view?.data,
        );
      });

  wasm.FunctionImportExportValue get _sockShutdownImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 2) {
          return _errnoInval;
        }
        return wasi_socket.preview1SockShutdown(
          vfs: _vfs,
          fd: _asInt(args[0]),
          how: _asInt(args[1]),
        );
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
        final opened = _vfs.openFileForFd(fd);
        final socket = _vfs.socketForFd(fd);
        final input =
            _vfs.stdioKindForFd(fd) ==
                wasi_vfs.Preview1StdioDescriptorKind.stdin
            ? _stdinInput
            : opened;
        final isDirectory = _vfs.isOpenDirectoryFd(fd);
        if (input == null && socket == null) {
          return _errnoBadf;
        }
        if (isDirectory) {
          return _errnoBadf;
        }
        final right = _checkDescriptorRight(fd, _rightFdRead);
        if (right != _errnoSuccess) {
          return right;
        }
        if (socket != null) {
          final view = _memoryView();
          if (view == null) {
            return _errnoInval;
          }
          return wasi_vfs.readSocketIntoIov(
            socket: socket,
            bytes: view.bytes,
            data: view.data,
            iovs: iovs,
            iovsLen: iovsLen,
            flags: 0,
            nreadPtr: nreadPtr,
            roFlagsPtr: null,
          );
        }

        return _readOpenFileIntoIov(
          opened: input!,
          iovs: iovs,
          iovsLen: iovsLen,
          nreadPtr: nreadPtr,
        );
      });

  wasm.FunctionImportExportValue get _fdAdviseImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 4) {
          return _errnoInval;
        }
        final fd = _asInt(args[0]);
        final offset = _asInt64(args[1]);
        final len = _asInt64(args[2]);
        final advice = _asInt(args[3]);
        final right = _checkDescriptorRight(fd, _rightFdAdvise);
        if (right != _errnoSuccess) {
          return right;
        }
        if (offset < 0 || len < 0 || advice < 0 || advice > 5) {
          return _errnoInval;
        }
        return _errnoSuccess;
      });

  wasm.FunctionImportExportValue get _fdDatasyncImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.isEmpty) {
          return _errnoInval;
        }
        return _checkDescriptorRight(_asInt(args[0]), _rightFdDatasync);
      });

  wasm.FunctionImportExportValue get _fdPreadImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 5) {
          return _errnoInval;
        }
        final fd = _asInt(args[0]);
        final iovs = _asInt(args[1]);
        final iovsLen = _asInt(args[2]);
        final offset = _asInt64(args[3]);
        final nreadPtr = _asInt(args[4]);
        final view = _memoryView();

        return wasi_fd.preview1FdPread(
          vfs: _vfs,
          fd: fd,
          bytes: view?.bytes,
          data: view?.data,
          iovs: iovs,
          iovsLen: iovsLen,
          offset: offset,
          nreadPtr: nreadPtr,
        );
      });

  wasm.FunctionImportExportValue get _fdPwriteImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 5) {
          return _errnoInval;
        }
        final fd = _asInt(args[0]);
        final iovs = _asInt(args[1]);
        final iovsLen = _asInt(args[2]);
        final offset = _asInt64(args[3]);
        final nwrittenPtr = _asInt(args[4]);
        final view = _memoryView();

        return wasi_fd.preview1FdPwrite(
          vfs: _vfs,
          fd: fd,
          bytes: view?.bytes,
          data: view?.data,
          iovs: iovs,
          iovsLen: iovsLen,
          offset: offset,
          nwrittenPtr: nwrittenPtr,
        );
      });

  wasm.FunctionImportExportValue get _fdReaddirImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 5) {
          return _errnoInval;
        }
        final fd = _asInt(args[0]);
        final bufferPtr = _asInt(args[1]);
        final bufferLength = _asInt(args[2]);
        final cookie = _asInt64(args[3]);
        final bufferUsedPtr = _asInt(args[4]);
        final entries = _vfs.directoryEntriesForFd(fd);
        if (entries == null) {
          return _errnoBadf;
        }
        final right = _checkDescriptorRight(fd, _rightFdReaddir);
        if (right != _errnoSuccess) {
          return right;
        }
        if (cookie < 0) {
          return _errnoInval;
        }

        final view = _memoryView();
        if (view == null) {
          return _errnoInval;
        }
        final bytes = view.bytes;
        final data = view.data;
        if (bufferPtr < 0 ||
            bufferLength < 0 ||
            bufferPtr + bufferLength > bytes.length ||
            bufferUsedPtr < 0 ||
            bufferUsedPtr + 4 > bytes.length) {
          return _errnoInval;
        }

        final written = wasi_vfs.writeDirectoryEntries(
          entries: entries,
          bytes: bytes,
          data: data,
          bufferPtr: bufferPtr,
          bufferLength: bufferLength,
          cookie: cookie,
        );
        data.setUint32(bufferUsedPtr, written, Endian.little);
        return _errnoSuccess;
      });

  wasm.FunctionImportExportValue get _fdSyncImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.isEmpty) {
          return _errnoInval;
        }
        return _checkDescriptorRight(_asInt(args[0]), _rightFdSync);
      });

  wasm.FunctionImportExportValue get _fdAllocateImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 3) {
          return _errnoInval;
        }
        final fd = _asInt(args[0]);
        final offset = _asInt64(args[1]);
        final len = _asInt64(args[2]);
        return wasi_fd.preview1FdAllocate(
          vfs: _vfs,
          fd: fd,
          offset: offset,
          length: len,
        );
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
    final descriptorKind = _vfs.descriptorKindForFd(fd);
    final isStdio =
        descriptorKind == wasi_vfs.Preview1DescriptorKind.stdin ||
        descriptorKind == wasi_vfs.Preview1DescriptorKind.stdout ||
        descriptorKind == wasi_vfs.Preview1DescriptorKind.stderr;
    final isDir = _vfs.isDirectoryFd(fd);
    final isFile = _vfs.openFileForFd(fd) != null;
    final socket = _vfs.socketForFd(fd);
    final isSocket = socket != null;
    if (_traceSyscalls) {
      print(
        '[wasi:fd_fdstat_get] fd=$fd isStdio=$isStdio isDir=$isDir isFile=$isFile isSocket=$isSocket',
      );
    }
    if (!isStdio && !isDir && !isFile && !isSocket) {
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
        : isSocket
        ? socket.fileType
        : isDir
        ? _filetypeDirectory
        : _filetypeCharacterDevice;
    data.setUint16(
      fdstatPtr + 2,
      _vfs.descriptorFlagsForFd(fd) ?? 0,
      Endian.little,
    );
    final rights = _vfs.descriptorRightsForFd(fd);
    if (rights == null) {
      return _errnoBadf;
    }
    final rightsBase = rights.base;
    final rightsInheriting = rights.inheriting;
    _setUint64(data, fdstatPtr + 8, rightsBase);
    _setUint64(data, fdstatPtr + 16, rightsInheriting);
    return _errnoSuccess;
  });

  wasm.FunctionImportExportValue get _fdFdstatSetFlagsImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 2) {
          return _errnoInval;
        }
        return wasi_fd.preview1FdFdstatSetFlags(
          vfs: _vfs,
          fd: _asInt(args[0]),
          flags: _asInt(args[1]),
        );
      });

  wasm.FunctionImportExportValue get _fdFdstatSetRightsImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 3) {
          return _errnoInval;
        }
        return _errnoFromFdRightsResult(
          _vfs.setDescriptorRights(
            fd: _asInt(args[0]),
            rightsBase: _asInt64(args[1]),
            rightsInheriting: _asInt64(args[2]),
          ),
        );
      });

  wasm.FunctionImportExportValue get _fdFilestatGetImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 2) {
          return _errnoInval;
        }
        final fd = _asInt(args[0]);
        final bufPtr = _asInt(args[1]);

        final view = _memoryView();
        return wasi_fd.preview1FdFilestatGet(
          vfs: _vfs,
          fd: fd,
          bytes: view?.bytes,
          data: view?.data,
          filestatPtr: bufPtr,
        );
      });

  wasm.FunctionImportExportValue get _fdFilestatSetSizeImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 2) {
          return _errnoInval;
        }
        final fd = _asInt(args[0]);
        final size = _asInt64(args[1]);
        return wasi_fd.preview1FdFilestatSetSize(vfs: _vfs, fd: fd, size: size);
      });

  wasm.FunctionImportExportValue get _fdFilestatSetTimesImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 4) {
          return _errnoInval;
        }
        final metadata = _vfs.metadataForFd(_asInt(args[0]));
        if (metadata == null) {
          return _errnoBadf;
        }
        final right = _checkDescriptorRight(
          _asInt(args[0]),
          _rightFdFilestatSetTimes,
        );
        if (right != _errnoSuccess) {
          return right;
        }
        return _applyFilestatTimes(
          metadata: metadata,
          accessTimeNanos: _asInt64(args[1]),
          modificationTimeNanos: _asInt64(args[2]),
          flags: _asInt(args[3]),
        );
      });

  wasm.FunctionImportExportValue get _fdCloseImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.isEmpty) {
          return _errnoInval;
        }
        final fd = _asInt(args.first);
        if (_vfs.close(fd)) {
          return _errnoSuccess;
        }
        return _errnoBadf;
      });

  wasm.FunctionImportExportValue get _fdRenumberImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 2) {
          return _errnoInval;
        }
        return switch (_vfs.renumberDescriptor(
          fromFd: _asInt(args[0]),
          toFd: _asInt(args[1]),
        )) {
          wasi_vfs.Preview1FdRenumberResult.success => _errnoSuccess,
          wasi_vfs.Preview1FdRenumberResult.invalid => _errnoInval,
          wasi_vfs.Preview1FdRenumberResult.badf => _errnoBadf,
        };
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

        final view = _memoryView();
        return wasi_fd.preview1FdSeek(
          vfs: _vfs,
          fd: fd,
          offset: offset,
          whence: whence,
          bytes: view?.bytes,
          data: view?.data,
          newOffsetPtr: newOffsetPtr,
        );
      });

  wasm.FunctionImportExportValue get _fdTellImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 2) {
          return _errnoInval;
        }
        final fd = _asInt(args[0]);
        final offsetPtr = _asInt(args[1]);

        final view = _memoryView();
        return wasi_fd.preview1FdTell(
          vfs: _vfs,
          fd: fd,
          bytes: view?.bytes,
          data: view?.data,
          offsetPtr: offsetPtr,
        );
      });

  wasm.FunctionImportExportValue get _clockTimeGetImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 3) {
          return _errnoInval;
        }
        final clockId = _asInt(args[0]);
        final timePtr = _asInt(args[2]);
        if (_clockResolutionNanos(clockId) == null) {
          return _errnoInval;
        }

        final view = _memoryView();
        if (view == null) {
          return _errnoInval;
        }
        if (timePtr < 0 || timePtr + 8 > view.bytes.length) {
          return _errnoInval;
        }

        final nowNanos = _clockNowNanos(clockId);
        _setUint64(view.data, timePtr, nowNanos);
        return _errnoSuccess;
      });

  wasm.FunctionImportExportValue get _clockResGetImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 2) {
          return _errnoInval;
        }
        final clockId = _asInt(args[0]);
        final resolutionPtr = _asInt(args[1]);
        final resolutionNanos = _clockResolutionNanos(clockId);
        if (resolutionNanos == null) {
          return _errnoInval;
        }

        final view = _memoryView();
        if (view == null) {
          return _errnoInval;
        }
        if (resolutionPtr < 0 || resolutionPtr + 8 > view.bytes.length) {
          return _errnoInval;
        }

        _setUint64(view.data, resolutionPtr, resolutionNanos);
        return _errnoSuccess;
      });

  wasm.FunctionImportExportValue get _schedYieldImport =>
      wasm.ImportExportKind.function((List<Object?> _) => _errnoSuccess);

  wasm.FunctionImportExportValue get _fdPrestatGetImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 2) {
          return _errnoInval;
        }
        final fd = _asInt(args[0]);
        final prestatPtr = _asInt(args[1]);
        if (_traceSyscalls) {
          print('[wasi:fd_prestat_get] fd=$fd');
        }
        final path = _vfs.preopenPathBytesForFd(fd);
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
          print('[wasi:fd_prestat_dir_name] fd=$fd pathLen=$pathLen');
        }
        final path = _vfs.preopenPathBytesForFd(fd);
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

  wasm.FunctionImportExportValue get _pathCreateDirectoryImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 3) {
          return _errnoInval;
        }
        final resolved = _resolvePath(
          dirFd: _asInt(args[0]),
          pathPtr: _asInt(args[1]),
          pathLen: _asInt(args[2]),
        );
        if (resolved.errno != _errnoSuccess) {
          return resolved.errno;
        }
        final right = _checkDescriptorRight(
          _asInt(args[0]),
          _rightPathCreateDirectory,
        );
        if (right != _errnoSuccess) {
          return right;
        }
        return _errnoFromPathMutationResult(
          _vfs.createDirectory(resolved.path!),
        );
      });

  wasm.FunctionImportExportValue
  get _pathOpenImport => wasm.ImportExportKind.function((List<Object?> args) {
    if (args.length < 9) {
      return _errnoInval;
    }
    final dirFd = _asInt(args[0]);
    final lookupFlags = _asInt(args[1]);
    final pathPtr = _asInt(args[2]);
    final pathLen = _asInt(args[3]);
    final oflags = _asInt(args[4]);
    final openedFdPtr = _asInt(args[8]);
    if ((lookupFlags & ~_lookupflagKnownMask) != 0 ||
        (oflags & ~_oflagKnownMask) != 0) {
      return _errnoInval;
    }
    final directoryFd = _checkDirectoryFd(dirFd);
    if (directoryFd != _errnoSuccess) {
      return directoryFd;
    }
    final baseDirectory = _vfs.directoryPathForFd(dirFd)!;
    final right = _checkDescriptorRight(dirFd, _rightPathOpen);
    if (right != _errnoSuccess) {
      return right;
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

    final guestPath = wasi_vfs.resolveGuestPathInfo(
      bytes: bytes,
      preopenPath: baseDirectory,
      pathPtr: pathPtr,
      pathLen: pathLen,
    );
    if (_traceSyscalls) {
      print(
        '[wasi:path_open] dirFd=$dirFd base=$baseDirectory path=$guestPath len=$pathLen',
      );
    }
    if (guestPath == null) {
      return _errnoInval;
    }
    final pathErrno = wasi_vfs.errnoForResolvedGuestPathInfo(guestPath);
    if (pathErrno != null) {
      return pathErrno;
    }
    final normalizedPath = wasi_vfs.normalizeGuestPath(guestPath.path);
    final openPath = (lookupFlags & _lookupflagSymlinkFollow) == 0
        ? normalizedPath
        : _vfs.resolveSymlinkPath(normalizedPath);
    if (openPath == null) {
      return _errnoNoent;
    }
    final fileBytes = _vfs.lookupFile(openPath);
    if (_traceSyscalls) {
      print(
        '[wasi:path_open] normalized=$normalizedPath open=$openPath found=${fileBytes != null}',
      );
    }
    final requestedRightsBase = _asInt64(args[5]);
    final requestedRightsInheriting = _asInt64(args[6]);
    final descriptorFlags = _asInt(args[7]);
    if ((descriptorFlags & ~_fdflagKnownMask) != 0 ||
        requestedRightsBase < 0 ||
        requestedRightsInheriting < 0 ||
        (requestedRightsBase & ~_rightsKnownMask) != 0 ||
        (requestedRightsInheriting & ~_rightsKnownMask) != 0) {
      return _errnoInval;
    }
    final parentRights = _vfs.descriptorRightsForFd(dirFd);
    if (parentRights == null) {
      return _errnoBadf;
    }
    if ((oflags & _oflagCreat) != 0) {
      final createRight = _checkDescriptorRight(dirFd, _rightPathCreateFile);
      if (createRight != _errnoSuccess) {
        return createRight;
      }
    }
    if ((oflags & _oflagTrunc) != 0) {
      final truncateRight = _checkDescriptorRight(
        dirFd,
        _rightPathFilestatSetSize,
      );
      if (truncateRight != _errnoSuccess) {
        return truncateRight;
      }
    }
    if (requestedRightsBase != 0 &&
            (requestedRightsBase | parentRights.inheriting) !=
                parentRights.inheriting ||
        requestedRightsInheriting != 0 &&
            (requestedRightsInheriting | parentRights.inheriting) !=
                parentRights.inheriting) {
      return _errnoNotcapable;
    }
    final opened = _vfs.openPath(
      openPath,
      rightsBase: requestedRightsBase,
      rightsInheriting: requestedRightsInheriting,
      descriptorFlags: descriptorFlags,
      oflags: oflags,
      hasTrailingSeparator: guestPath.hasTrailingSeparator,
    );
    switch (opened.kind) {
      case wasi_vfs.Preview1VirtualOpenKind.file:
      case wasi_vfs.Preview1VirtualOpenKind.directory:
        data.setUint32(openedFdPtr, opened.fd!, Endian.little);
        return _errnoSuccess;
      case wasi_vfs.Preview1VirtualOpenKind.missing:
        return _errnoNoent;
      case wasi_vfs.Preview1VirtualOpenKind.exists:
        return _errnoExist;
      case wasi_vfs.Preview1VirtualOpenKind.isDirectory:
        return _errnoIsdir;
      case wasi_vfs.Preview1VirtualOpenKind.notDirectory:
        return _errnoNotdir;
      case wasi_vfs.Preview1VirtualOpenKind.symlinkLoop:
        return _errnoLoop;
      case wasi_vfs.Preview1VirtualOpenKind.notCapable:
        return _errnoNotcapable;
      case wasi_vfs.Preview1VirtualOpenKind.notSupported:
        return _errnoNotsup;
    }
  });

  wasm.FunctionImportExportValue get _pathRemoveDirectoryImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 3) {
          return _errnoInval;
        }
        final resolved = _resolvePath(
          dirFd: _asInt(args[0]),
          pathPtr: _asInt(args[1]),
          pathLen: _asInt(args[2]),
        );
        if (resolved.errno != _errnoSuccess) {
          return resolved.errno;
        }
        final right = _checkDescriptorRight(
          _asInt(args[0]),
          _rightPathRemoveDirectory,
        );
        if (right != _errnoSuccess) {
          return right;
        }
        return _errnoFromPathMutationResult(
          _vfs.removeDirectory(resolved.path!),
        );
      });

  wasm.FunctionImportExportValue get _pathRenameImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 6) {
          return _errnoInval;
        }
        final oldPath = _resolvePath(
          dirFd: _asInt(args[0]),
          pathPtr: _asInt(args[1]),
          pathLen: _asInt(args[2]),
        );
        if (oldPath.errno != _errnoSuccess) {
          return oldPath.errno;
        }
        final newPath = _resolvePath(
          dirFd: _asInt(args[3]),
          pathPtr: _asInt(args[4]),
          pathLen: _asInt(args[5]),
        );
        if (newPath.errno != _errnoSuccess) {
          return newPath.errno;
        }
        final oldRight = _checkDescriptorRight(
          _asInt(args[0]),
          _rightPathRenameSource,
        );
        if (oldRight != _errnoSuccess) {
          return oldRight;
        }
        final newRight = _checkDescriptorRight(
          _asInt(args[3]),
          _rightPathRenameTarget,
        );
        if (newRight != _errnoSuccess) {
          return newRight;
        }

        return _errnoFromPathMutationResult(
          _vfs.renamePath(oldPath: oldPath.path!, newPath: newPath.path!),
        );
      });

  wasm.FunctionImportExportValue get _pathLinkImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 7) {
          return _errnoInval;
        }
        final lookupFlags = _asInt(args[1]);
        if ((lookupFlags & ~_lookupflagKnownMask) != 0) {
          return _errnoInval;
        }
        if ((lookupFlags & _lookupflagSymlinkFollow) != 0) {
          return _errnoInval;
        }
        final oldPath = _resolvePath(
          dirFd: _asInt(args[0]),
          pathPtr: _asInt(args[2]),
          pathLen: _asInt(args[3]),
        );
        if (oldPath.errno != _errnoSuccess) {
          return oldPath.errno;
        }
        final oldRight = _checkDescriptorRight(
          _asInt(args[0]),
          _rightPathLinkSource,
        );
        if (oldRight != _errnoSuccess) {
          return oldRight;
        }
        final newPath = _resolvePath(
          dirFd: _asInt(args[4]),
          pathPtr: _asInt(args[5]),
          pathLen: _asInt(args[6]),
        );
        if (newPath.errno != _errnoSuccess) {
          return newPath.errno;
        }
        final newRight = _checkDescriptorRight(
          _asInt(args[4]),
          _rightPathLinkTarget,
        );
        if (newRight != _errnoSuccess) {
          return newRight;
        }

        return _errnoFromPathMutationResult(
          _vfs.linkPath(
            oldPath: oldPath.path!,
            newPath: newPath.path!,
            newPathHasTrailingSeparator: newPath.hasTrailingSeparator,
          ),
        );
      });

  wasm.FunctionImportExportValue get _pathReadlinkImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 6) {
          return _errnoInval;
        }
        final resolved = _resolvePath(
          dirFd: _asInt(args[0]),
          pathPtr: _asInt(args[1]),
          pathLen: _asInt(args[2]),
        );
        if (resolved.errno != _errnoSuccess) {
          return resolved.errno;
        }
        final right = _checkDescriptorRight(
          _asInt(args[0]),
          _rightPathReadlink,
        );
        if (right != _errnoSuccess) {
          return right;
        }

        final bufferPtr = _asInt(args[3]);
        final bufferLength = _asInt(args[4]);
        final bufferUsedPtr = _asInt(args[5]);
        final view = _memoryView();
        if (view == null) {
          return _errnoInval;
        }
        final bytes = view.bytes;
        final data = view.data;
        if (bufferPtr < 0 ||
            bufferLength < 0 ||
            bufferPtr + bufferLength > bytes.length ||
            bufferUsedPtr < 0 ||
            bufferUsedPtr + 4 > bytes.length) {
          return _errnoInval;
        }

        final symlink = _vfs.symlinkForPath(resolved.path!);
        if (symlink == null) {
          return _vfs.pathEntry(resolved.path!) == null
              ? _errnoNoent
              : _errnoInval;
        }

        final bytesToWrite = math.min(bufferLength, symlink.targetBytes.length);
        if (bytesToWrite > 0) {
          bytes.setRange(
            bufferPtr,
            bufferPtr + bytesToWrite,
            symlink.targetBytes,
          );
        }
        data.setUint32(bufferUsedPtr, bytesToWrite, Endian.little);
        return _errnoSuccess;
      });

  wasm.FunctionImportExportValue get _pathSymlinkImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 5) {
          return _errnoInval;
        }
        final targetPtr = _asInt(args[0]);
        final targetLength = _asInt(args[1]);
        final view = _memoryView();
        if (view == null) {
          return _errnoInval;
        }
        final bytes = view.bytes;
        if (targetPtr < 0 ||
            targetLength < 0 ||
            targetPtr + targetLength > bytes.length) {
          return _errnoInval;
        }
        final decodedTarget = utf8.decode(
          bytes.sublist(targetPtr, targetPtr + targetLength),
          allowMalformed: true,
        );
        final nul = decodedTarget.indexOf('\u0000');
        final target = nul == -1
            ? decodedTarget
            : decodedTarget.substring(0, nul);

        final linkPath = _resolvePath(
          dirFd: _asInt(args[2]),
          pathPtr: _asInt(args[3]),
          pathLen: _asInt(args[4]),
        );
        if (linkPath.errno != _errnoSuccess) {
          return linkPath.errno;
        }
        final right = _checkDescriptorRight(_asInt(args[2]), _rightPathSymlink);
        if (right != _errnoSuccess) {
          return right;
        }
        return _errnoFromPathMutationResult(
          _vfs.createSymlink(
            target: target,
            linkPath: linkPath.path!,
            hasTrailingSeparator: linkPath.hasTrailingSeparator,
          ),
        );
      });

  wasm.FunctionImportExportValue get _pathUnlinkFileImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 3) {
          return _errnoInval;
        }
        final resolved = _resolvePath(
          dirFd: _asInt(args[0]),
          pathPtr: _asInt(args[1]),
          pathLen: _asInt(args[2]),
        );
        if (resolved.errno != _errnoSuccess) {
          return resolved.errno;
        }
        final right = _checkDescriptorRight(
          _asInt(args[0]),
          _rightPathUnlinkFile,
        );
        if (right != _errnoSuccess) {
          return right;
        }
        return _errnoFromPathMutationResult(
          _vfs.unlinkFile(
            resolved.path!,
            hasTrailingSeparator: resolved.hasTrailingSeparator,
          ),
        );
      });

  wasm.FunctionImportExportValue
  get _pathFilestatGetImport => wasm.ImportExportKind.function((
    List<Object?> args,
  ) {
    if (args.length < 5) {
      return _errnoInval;
    }
    final dirFd = _asInt(args[0]);
    final lookupFlags = _asInt(args[1]);
    final pathPtr = _asInt(args[2]);
    final pathLen = _asInt(args[3]);
    final filestatPtr = _asInt(args[4]);
    if ((lookupFlags & ~_lookupflagKnownMask) != 0) {
      return _errnoInval;
    }
    final directoryFd = _checkDirectoryFd(dirFd);
    if (directoryFd != _errnoSuccess) {
      return directoryFd;
    }
    final baseDirectory = _vfs.directoryPathForFd(dirFd)!;
    final right = _checkDescriptorRight(dirFd, _rightPathFilestatGet);
    if (right != _errnoSuccess) {
      return right;
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
    final guestPath = wasi_vfs.resolveGuestPathInfo(
      bytes: bytes,
      preopenPath: baseDirectory,
      pathPtr: pathPtr,
      pathLen: pathLen,
    );
    if (_traceSyscalls) {
      print(
        '[wasi:path_filestat_get] dirFd=$dirFd base=$baseDirectory path=$guestPath len=$pathLen',
      );
    }
    if (guestPath == null) {
      return _errnoInval;
    }
    final pathErrno = wasi_vfs.errnoForResolvedGuestPathInfo(guestPath);
    if (pathErrno != null) {
      return pathErrno;
    }

    final normalizedPath = wasi_vfs.normalizeGuestPath(guestPath.path);
    final entry = _vfs.pathEntry(
      normalizedPath,
      followSymlinks: (lookupFlags & _lookupflagSymlinkFollow) != 0,
    );
    if (entry == null) {
      return _errnoNoent;
    }

    bytes.fillRange(filestatPtr, filestatPtr + _filestatSize, 0);
    bytes[filestatPtr + 16] = entry.fileType;
    _setUint64(data, filestatPtr + 32, entry.size);
    wasi_vfs.writeFilestatMetadata(
      data: data,
      filestatPtr: filestatPtr,
      metadata: entry.metadata,
    );
    return _errnoSuccess;
  });

  wasm.FunctionImportExportValue get _pathFilestatSetTimesImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 7) {
          return _errnoInval;
        }
        final lookupFlags = _asInt(args[1]);
        if ((lookupFlags & ~_lookupflagKnownMask) != 0) {
          return _errnoInval;
        }
        final resolved = _resolvePath(
          dirFd: _asInt(args[0]),
          pathPtr: _asInt(args[2]),
          pathLen: _asInt(args[3]),
        );
        if (resolved.errno != _errnoSuccess) {
          return resolved.errno;
        }
        final right = _checkDescriptorRight(
          _asInt(args[0]),
          _rightPathFilestatSetTimes,
        );
        if (right != _errnoSuccess) {
          return right;
        }
        final entry = _vfs.pathEntry(
          resolved.path!,
          followSymlinks: (lookupFlags & _lookupflagSymlinkFollow) != 0,
        );
        if (entry == null) {
          return _errnoNoent;
        }
        return _applyFilestatTimes(
          metadata: entry.metadata,
          accessTimeNanos: _asInt64(args[4]),
          modificationTimeNanos: _asInt64(args[5]),
          flags: _asInt(args[6]),
        );
      });

  wasm.FunctionImportExportValue get _pollOneoffImport =>
      wasm.ImportExportKind.function((List<Object?> args) {
        if (args.length < 4) {
          return _errnoInval;
        }
        final inPtr = _asInt(args[0]);
        final outPtr = _asInt(args[1]);
        final nsubscriptions = _asInt(args[2]);
        final neventsPtr = _asInt(args[3]);

        final view = _memoryView();
        if (view == null) {
          return _errnoInval;
        }
        final bytes = view.bytes;
        final data = view.data;
        if (nsubscriptions < 0 ||
            neventsPtr < 0 ||
            neventsPtr + 4 > bytes.length) {
          return _errnoInval;
        }
        if (nsubscriptions == 0) {
          return _errnoInval;
        }
        if (inPtr < 0 ||
            outPtr < 0 ||
            inPtr + nsubscriptions * _subscriptionSize > bytes.length ||
            outPtr + nsubscriptions * _eventSize > bytes.length) {
          return _errnoInval;
        }

        _writePollEvents(
          bytes: bytes,
          data: data,
          inPtr: inPtr,
          outPtr: outPtr,
          nsubscriptions: nsubscriptions,
          neventsPtr: neventsPtr,
        );
        return _errnoSuccess;
      });

  bool _isOpenDescriptor(int fd) => _vfs.descriptorKindForFd(fd) != null;

  int _checkDescriptorRight(int fd, int right) {
    if (!_isOpenDescriptor(fd)) {
      return _errnoBadf;
    }
    return _vfs.descriptorHasRight(fd, right)
        ? _errnoSuccess
        : _errnoNotcapable;
  }

  int _checkDirectoryFd(int fd) {
    return switch (_vfs.descriptorKindForFd(fd)) {
      null => _errnoBadf,
      wasi_vfs.Preview1DescriptorKind.openDirectory ||
      wasi_vfs.Preview1DescriptorKind.preopenDirectory => _errnoSuccess,
      _ => _errnoNotdir,
    };
  }

  int _applyFilestatTimes({
    required wasi_vfs.Preview1VirtualNodeMetadata metadata,
    required int accessTimeNanos,
    required int modificationTimeNanos,
    required int flags,
  }) {
    if ((flags & ~_filestatTimeKnownFlags) != 0 ||
        (flags & _filestatSetAccessTime) != 0 &&
            (flags & _filestatSetAccessTimeNow) != 0 ||
        (flags & _filestatSetModificationTime) != 0 &&
            (flags & _filestatSetModificationTimeNow) != 0) {
      return _errnoInval;
    }
    if ((flags & _filestatSetAccessTime) != 0 && accessTimeNanos < 0 ||
        (flags & _filestatSetModificationTime) != 0 &&
            modificationTimeNanos < 0) {
      return _errnoInval;
    }

    final now =
        ((flags & _filestatSetAccessTimeNow) != 0 ||
            (flags & _filestatSetModificationTimeNow) != 0)
        ? _clockNowNanos(_clockRealtime)
        : 0;
    if ((flags & _filestatSetAccessTime) != 0) {
      metadata.accessTimeNanos = accessTimeNanos;
    } else if ((flags & _filestatSetAccessTimeNow) != 0) {
      metadata.accessTimeNanos = now;
    }
    if ((flags & _filestatSetModificationTime) != 0) {
      metadata.modificationTimeNanos = modificationTimeNanos;
    } else if ((flags & _filestatSetModificationTimeNow) != 0) {
      metadata.modificationTimeNanos = now;
    }
    return _errnoSuccess;
  }

  int _writePollEvents({
    required Uint8List bytes,
    required ByteData data,
    required int inPtr,
    required int outPtr,
    required int nsubscriptions,
    required int neventsPtr,
  }) {
    var eventCount = 0;
    var earliestWaitNanos = 0;
    final nowMonotonic = _clockNowNanos(_clockMonotonic);
    for (var index = 0; index < nsubscriptions; index++) {
      final subscriptionPtr = inPtr + index * _subscriptionSize;

      final tag = bytes[subscriptionPtr + _subscriptionTagOffset];
      var errno = _errnoSuccess;
      var nbytes = 0;
      var flags = 0;
      var isReady = true;
      var remainingNanos = 0;
      if (tag == _eventTypeClock) {
        final clockWaitNanos = _clockSubscriptionWaitNanos(
          data: data,
          subscriptionPtr: subscriptionPtr,
          nowMonotonic: nowMonotonic,
        );
        if (clockWaitNanos == _clockSubscriptionInvalid) {
          errno = _errnoInval;
        } else {
          remainingNanos = clockWaitNanos;
        }
      } else if (tag != _eventTypeFdRead && tag != _eventTypeFdWrite) {
        errno = _errnoInval;
      }
      if (remainingNanos > 0) {
        if (earliestWaitNanos == 0 || remainingNanos < earliestWaitNanos) {
          earliestWaitNanos = remainingNanos;
        }
        continue;
      }
      if (tag == _eventTypeFdRead || tag == _eventTypeFdWrite) {
        final readiness = _vfs.pollFdReadWrite(
          fd: data.getUint32(
            subscriptionPtr + _subscriptionFdReadwriteFdOffset,
            Endian.little,
          ),
          eventType: tag,
          stdinInput: _stdinInput,
        );
        isReady = readiness.ready;
        errno = readiness.errno;
        nbytes = readiness.nbytes;
        flags = readiness.flags;
      }
      if (!isReady) {
        continue;
      }

      final eventPtr = outPtr + eventCount * _eventSize;
      bytes.fillRange(eventPtr, eventPtr + _eventSize, 0);
      eventCount++;
      data.setUint32(
        eventPtr,
        data.getUint32(subscriptionPtr, Endian.little),
        Endian.little,
      );
      data.setUint32(
        eventPtr + 4,
        data.getUint32(subscriptionPtr + 4, Endian.little),
        Endian.little,
      );
      bytes[eventPtr + _eventTypeOffset] = tag;
      data.setUint16(eventPtr + _eventErrorOffset, errno, Endian.little);
      if (tag == _eventTypeFdRead || tag == _eventTypeFdWrite) {
        _setUint64(data, eventPtr + _eventFdReadwriteNbytesOffset, nbytes);
        data.setUint16(
          eventPtr + _eventFdReadwriteFlagsOffset,
          flags,
          Endian.little,
        );
      }
    }

    data.setUint32(neventsPtr, eventCount, Endian.little);
    return eventCount == 0 ? earliestWaitNanos : 0;
  }

  int _clockSubscriptionWaitNanos({
    required ByteData data,
    required int subscriptionPtr,
    required int nowMonotonic,
  }) {
    final clockId = data.getUint32(
      subscriptionPtr + _subscriptionClockIdOffset,
      Endian.little,
    );
    final timeout = _getUint64(
      data,
      subscriptionPtr + _subscriptionClockTimeoutOffset,
    );
    final flags = data.getUint16(
      subscriptionPtr + _subscriptionClockFlagsOffset,
      Endian.little,
    );
    if (_clockResolutionNanos(clockId) == null ||
        (flags & ~_subscriptionClockAbstime) != 0) {
      return _clockSubscriptionInvalid;
    }
    final now = _clockNowNanos(clockId);
    final deadline = (flags & _subscriptionClockAbstime) != 0
        ? timeout
        : now + timeout;
    final remaining = deadline - now;
    if (clockId == _clockMonotonic) {
      return remaining > 0 ? remaining : 0;
    }
    final adjustedDeadline = nowMonotonic + remaining;
    return adjustedDeadline > nowMonotonic
        ? adjustedDeadline - nowMonotonic
        : 0;
  }

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

  int _readOpenFileIntoIov({
    required wasi_vfs.Preview1OpenFile opened,
    required int iovs,
    required int iovsLen,
    required int nreadPtr,
    int? fileOffset,
  }) {
    final view = _memoryView();
    if (view == null) {
      return _errnoInval;
    }
    final bytes = view.bytes;
    final data = view.data;
    return wasi_vfs.readOpenFileIntoIov(
      opened: opened,
      bytes: bytes,
      data: data,
      iovs: iovs,
      iovsLen: iovsLen,
      nreadPtr: nreadPtr,
      fileOffset: fileOffset,
    );
  }

  int _writeOpenFileFromIov({
    required wasi_vfs.Preview1OpenFile opened,
    required int iovs,
    required int iovsLen,
    required int nwrittenPtr,
    int? fileOffset,
  }) {
    final view = _memoryView();
    if (view == null) {
      return _errnoInval;
    }
    final bytes = view.bytes;
    final data = view.data;
    return wasi_vfs.writeOpenFileFromIov(
      opened: opened,
      bytes: bytes,
      data: data,
      iovs: iovs,
      iovsLen: iovsLen,
      nwrittenPtr: nwrittenPtr,
      fileOffset: fileOffset,
    );
  }

  _ResolvedPath _resolvePath({
    required int dirFd,
    required int pathPtr,
    required int pathLen,
  }) {
    final directoryFd = _checkDirectoryFd(dirFd);
    if (directoryFd != _errnoSuccess) {
      return _ResolvedPath.error(directoryFd);
    }
    final baseDirectory = _vfs.directoryPathForFd(dirFd)!;

    final view = _memoryView();
    if (view == null) {
      return const _ResolvedPath.error(_errnoInval);
    }
    final bytes = view.bytes;
    if (pathPtr < 0 || pathLen < 0 || pathPtr + pathLen > bytes.length) {
      return const _ResolvedPath.error(_errnoInval);
    }

    final guestPath = wasi_vfs.resolveGuestPathInfo(
      bytes: bytes,
      preopenPath: baseDirectory,
      pathPtr: pathPtr,
      pathLen: pathLen,
    );
    if (guestPath == null) {
      return const _ResolvedPath.error(_errnoInval);
    }
    final pathErrno = wasi_vfs.errnoForResolvedGuestPathInfo(guestPath);
    if (pathErrno != null) {
      return _ResolvedPath.error(pathErrno);
    }
    return _ResolvedPath.path(
      wasi_vfs.normalizeGuestPath(guestPath.path),
      hasTrailingSeparator: guestPath.hasTrailingSeparator,
    );
  }

  _MemoryView? _memoryView() {
    final memory = _boundMemory;
    if (memory == null) {
      return null;
    }
    final buffer = memory.buffer;
    final cachedBuffer = _cachedMemoryBuffer;
    var cachedView = _cachedMemoryView;
    if (!identical(cachedBuffer, buffer) || cachedView == null) {
      cachedView = _MemoryView(Uint8List.view(buffer), ByteData.view(buffer));
      _cachedMemoryBuffer = buffer;
      _cachedMemoryView = cachedView;
    }
    return cachedView;
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
      _cachedMemoryBuffer = null;
      _cachedMemoryView = null;
      return;
    }

    final exportedMemory = instance.exports['memory'];
    if (exportedMemory is wasm.MemoryImportExportValue) {
      _boundMemory = exportedMemory.ref;
      _cachedMemoryBuffer = null;
      _cachedMemoryView = null;
      return;
    }

    if (_boundMemory != null) {
      return;
    }

    throw StateError(
      'WASI finalizeBindings requires a memory export or an explicit memory.',
    );
  }

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

  int _clockNowNanos(int clockId) {
    if (clockId == _clockMonotonic ||
        clockId == _clockProcessCpuTimeId ||
        clockId == _clockThreadCpuTimeId) {
      return _monotonicClock.elapsedMicroseconds * 1000;
    }
    return DateTime.now().microsecondsSinceEpoch * 1000;
  }

  int? _clockResolutionNanos(int clockId) {
    if (clockId == _clockRealtime ||
        clockId == _clockMonotonic ||
        clockId == _clockProcessCpuTimeId ||
        clockId == _clockThreadCpuTimeId) {
      return 1000;
    }
    return null;
  }
}

const int _iovecEntrySize = wasi_common.iovecEntrySize;
const int _subscriptionSize = wasi_common.subscriptionSize;
const int _subscriptionTagOffset = wasi_common.subscriptionTagOffset;
const int _subscriptionFdReadwriteFdOffset =
    wasi_common.subscriptionFdReadwriteFdOffset;
const int _eventSize = wasi_common.eventSize;
const int _eventErrorOffset = wasi_common.eventErrorOffset;
const int _eventTypeOffset = wasi_common.eventTypeOffset;
const int _eventFdReadwriteNbytesOffset =
    wasi_common.eventFdReadwriteNbytesOffset;
const int _eventFdReadwriteFlagsOffset =
    wasi_common.eventFdReadwriteFlagsOffset;
const int _eventTypeClock = wasi_common.eventTypeClock;
const int _eventTypeFdRead = wasi_common.eventTypeFdRead;
const int _eventTypeFdWrite = wasi_common.eventTypeFdWrite;
const int _clockRealtime = 0;
const int _clockMonotonic = 1;
const int _clockProcessCpuTimeId = 2;
const int _clockThreadCpuTimeId = 3;
const int _subscriptionClockIdOffset = 16;
const int _subscriptionClockTimeoutOffset = 24;
const int _subscriptionClockFlagsOffset = 40;
const int _subscriptionClockAbstime = 1;
const int _clockSubscriptionInvalid = -1;
const int _errnoSuccess = wasi_common.errnoSuccess;
const int _errnoInval = wasi_common.errnoInval;
const int _errnoBadf = wasi_common.errnoBadf;
const int _errnoExist = wasi_common.errnoExist;
const int _errnoIsdir = wasi_common.errnoIsdir;
const int _errnoNoent = wasi_common.errnoNoent;
const int _errnoNosys = wasi_common.errnoNosys;
const int _errnoNotdir = wasi_common.errnoNotdir;
const int _errnoNotempty = wasi_common.errnoNotempty;
const int _errnoNotcapable = wasi_common.errnoNotcapable;
const int _errnoNotsup = wasi_common.errnoNotsup;
const int _errnoLoop = wasi_common.errnoLoop;
const int _errnoPerm = wasi_common.errnoPerm;
const int _prestatSize = wasi_common.prestatSize;
const int _preopenTypeDir = wasi_common.preopenTypeDir;
const int _fdstatSize = wasi_common.fdstatSize;
const int _filetypeCharacterDevice = wasi_common.filetypeCharacterDevice;
const int _filetypeDirectory = wasi_common.filetypeDirectory;
const int _filetypeRegularFile = wasi_common.filetypeRegularFile;
const int _oflagCreat = wasi_common.oflagCreat;
const int _oflagTrunc = wasi_common.oflagTrunc;
const int _oflagKnownMask = wasi_common.oflagKnownMask;
const int _fdflagKnownMask = wasi_common.fdflagKnownMask;
const int _lookupflagSymlinkFollow = wasi_common.lookupflagSymlinkFollow;
const int _lookupflagKnownMask = _lookupflagSymlinkFollow;
const int _filestatSize = 64;
const int _filestatSetAccessTime = 1;
const int _filestatSetAccessTimeNow = 2;
const int _filestatSetModificationTime = 4;
const int _filestatSetModificationTimeNow = 8;
const int _filestatTimeKnownFlags =
    _filestatSetAccessTime |
    _filestatSetAccessTimeNow |
    _filestatSetModificationTime |
    _filestatSetModificationTimeNow;
const int _rightFdDatasync = wasi_common.rightFdDatasync;
const int _rightFdRead = wasi_common.rightFdRead;
const int _rightFdSync = wasi_common.rightFdSync;
const int _rightFdWrite = wasi_common.rightFdWrite;
const int _rightFdAdvise = wasi_common.rightFdAdvise;
const int _rightPathCreateDirectory = wasi_common.rightPathCreateDirectory;
const int _rightPathCreateFile = wasi_common.rightPathCreateFile;
const int _rightPathLinkSource = wasi_common.rightPathLinkSource;
const int _rightPathLinkTarget = wasi_common.rightPathLinkTarget;
const int _rightPathOpen = wasi_common.rightPathOpen;
const int _rightFdReaddir = wasi_common.rightFdReaddir;
const int _rightPathReadlink = wasi_common.rightPathReadlink;
const int _rightPathRenameSource = wasi_common.rightPathRenameSource;
const int _rightPathRenameTarget = wasi_common.rightPathRenameTarget;
const int _rightPathFilestatGet = wasi_common.rightPathFilestatGet;
const int _rightPathFilestatSetSize = wasi_common.rightPathFilestatSetSize;
const int _rightPathFilestatSetTimes = wasi_common.rightPathFilestatSetTimes;
const int _rightFdFilestatSetTimes = wasi_common.rightFdFilestatSetTimes;
const int _rightPathSymlink = wasi_common.rightPathSymlink;
const int _rightPathRemoveDirectory = wasi_common.rightPathRemoveDirectory;
const int _rightPathUnlinkFile = wasi_common.rightPathUnlinkFile;
const int _rightsKnownMask = wasi_common.rightsKnownMask;
const List<String> _preview1NosysImports = wasi_common.preview1NosysImports;

bool _isU32InBounds(int ptr, int length) => ptr >= 0 && ptr + 4 <= length;

int _errnoFromPathMutationResult(wasi_vfs.Preview1PathMutationResult result) =>
    switch (result) {
      wasi_vfs.Preview1PathMutationResult.success => _errnoSuccess,
      wasi_vfs.Preview1PathMutationResult.invalid => _errnoInval,
      wasi_vfs.Preview1PathMutationResult.noEntry => _errnoNoent,
      wasi_vfs.Preview1PathMutationResult.exists => _errnoExist,
      wasi_vfs.Preview1PathMutationResult.isDirectory => _errnoIsdir,
      wasi_vfs.Preview1PathMutationResult.notDirectory => _errnoNotdir,
      wasi_vfs.Preview1PathMutationResult.notEmpty => _errnoNotempty,
      wasi_vfs.Preview1PathMutationResult.notCapable => _errnoNotcapable,
      wasi_vfs.Preview1PathMutationResult.permissionDenied => _errnoPerm,
    };

int _errnoFromFdRightsResult(wasi_vfs.Preview1FdRightsResult result) =>
    switch (result) {
      wasi_vfs.Preview1FdRightsResult.success => _errnoSuccess,
      wasi_vfs.Preview1FdRightsResult.invalid => _errnoInval,
      wasi_vfs.Preview1FdRightsResult.badf => _errnoBadf,
      wasi_vfs.Preview1FdRightsResult.notCapable => _errnoNotcapable,
    };

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
  final jsNumeric = _decodeJsNumeric(value);
  if (jsNumeric != null) {
    return jsNumeric;
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
  final jsNumeric = _decodeJsNumeric(value);
  if (jsNumeric != null) {
    return jsNumeric;
  }
  return _asInt(value);
}

int? _decodeJsNumeric(Object? value) {
  // ignore: invalid_runtime_check_with_js_interop_types
  if (value is JSAny) {
    if (value.typeofEquals('bigint') ||
        value.typeofEquals('number') ||
        value.typeofEquals('string')) {
      final parsed = _tryParseJsInt(_jsString(value).toDart);
      if (parsed != null) {
        return parsed;
      }
    }
  }
  return _tryParseJsInt(value?.toString());
}

int? _tryParseJsInt(String? raw) {
  if (raw == null) {
    return null;
  }
  final normalized = raw.trim();
  if (normalized.isEmpty) {
    return null;
  }
  final candidate = normalized.endsWith('n')
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
  return int.tryParse(candidate);
}

@JS('String')
external JSString _jsString(JSAny? value);

JSObject _requireWebCrypto() {
  if (_isNodeJs()) {
    final crypto = _requireNodeWebCrypto();
    if (crypto != null) {
      return crypto;
    }
  }

  final crypto = globalContext.getProperty<JSObject?>('crypto'.toJS);
  if (crypto != null) {
    return crypto;
  }

  final nodeCrypto = _requireNodeWebCrypto();
  if (nodeCrypto != null) {
    return nodeCrypto;
  }

  throw UnsupportedError('Web Crypto is unavailable in this runtime.');
}

bool _isNodeJs() {
  final process = globalContext.getProperty<JSAny?>('process'.toJS);
  if (process == null) {
    return false;
  }
  final versions = (process as JSObject).getProperty<JSAny?>('versions'.toJS);
  if (versions == null) {
    return false;
  }
  return (versions as JSObject).getProperty<JSAny?>('node'.toJS) != null;
}

JSObject? _requireNodeWebCrypto() {
  final require = globalContext.getProperty<JSAny?>('require'.toJS);
  if (require == null) {
    return null;
  }
  final cryptoModule = _jsRequire('node:crypto'.toJS);
  if (cryptoModule case final JSObject module) {
    final webcrypto = module.getProperty<JSObject?>('webcrypto'.toJS);
    if (webcrypto != null) {
      return webcrypto;
    }
  }
  return null;
}

@JS('require')
external JSAny _jsRequire(JSString module);

void _setUint64(ByteData data, int offset, int value) {
  final normalized = value.toUnsigned(64);
  final low = normalized & 0xffffffff;
  final high = (normalized >> 32) & 0xffffffff;
  data.setUint32(offset, low, Endian.little);
  data.setUint32(offset + 4, high, Endian.little);
}

int _getUint64(ByteData data, int offset) {
  final low = data.getUint32(offset, Endian.little);
  final high = data.getUint32(offset + 4, Endian.little);
  return (high << 32) | low;
}

String _decodeUtf8(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

final class _MemoryView {
  _MemoryView(this.bytes, this.data);

  final Uint8List bytes;
  final ByteData data;
}

final class _ResolvedPath {
  const _ResolvedPath.path(this.path, {this.hasTrailingSeparator = false})
    : errno = _errnoSuccess;

  const _ResolvedPath.error(this.errno)
    : path = null,
      hasTrailingSeparator = false;

  final String? path;
  final int errno;
  final bool hasTrailingSeparator;
}

final class _WasiExit extends Error {
  _WasiExit(this.exitCode);

  final int exitCode;
}
