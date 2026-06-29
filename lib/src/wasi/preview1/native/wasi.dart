import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../../wasm/instance.dart' as wasm;
import '../../../wasm/memory.dart' as wasm;
import '../../../wasm/module.dart' as wasm;
import '../../wasi.dart' as wasi_iface;
import '../common/constants.dart' as wasi_common;
import '../common/fd_syscalls.dart' as wasi_fd;
import '../common/socket_syscalls.dart' as wasi_socket;
import '../common/vfs.dart' as wasi_vfs;
import '../socket.dart';

class WASI implements wasi_iface.WASI {
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
    wasi_iface.WASIProcRaiseHandler? procRaiseHandler,
    wasi_iface.WASIVersion version = wasi_iface.WASIVersion.preview1,
  }) : _returnOnExit = returnOnExit,
       _procRaiseHandler = procRaiseHandler,
       _argsData = [for (final arg in args) wasi_vfs.nulTerminated(arg)],
       _envData = [
         for (final entry in env.entries)
           wasi_vfs.nulTerminated('${entry.key}=${entry.value}'),
       ],
       _hostPreopensByGuestPath = _buildHostPreopens(preopens),
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
  final wasi_iface.WASIProcRaiseHandler? _procRaiseHandler;
  final List<Uint8List> _argsData;
  final List<Uint8List> _envData;
  final Map<String, String> _hostPreopensByGuestPath;
  final wasi_vfs.Preview1VirtualFileSystem _vfs;
  final wasi_vfs.Preview1OpenFile _stdinInput;
  final math.Random _secureRandom = math.Random.secure();
  final Stopwatch _monotonicClock = Stopwatch()..start();
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
        final signal = wasi_iface.WASIProcessSignal.fromPreview1Code(
          _asInt(args.first),
        );
        if (signal == null || signal == wasi_iface.WASIProcessSignal.none) {
          return _errnoInval;
        }

        final handler = _procRaiseHandler;
        if (handler != null) {
          handler(signal);
          return _errnoSuccess;
        }
        return _raiseNativeProcessSignal(signal);
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
          if (_vfs.descriptorKindForFd(fd) == null) {
            return _errnoBadf;
          }
          final right = _checkDescriptorRight(fd, _rightFdWrite);
          if (right != _errnoSuccess) {
            return right;
          }
          if (opened == null && socket == null) {
            return _errnoBadf;
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

        final memory = _boundMemory;
        if (memory == null) {
          return _errnoInval;
        }

        final buffer = memory.buffer;
        final bytes = Uint8List.view(buffer);
        final data = ByteData.view(buffer);
        if (iovs < 0 ||
            iovsLen < 0 ||
            !_isU32InBounds(nwrittenPtr, bytes.length)) {
          return _errnoInval;
        }
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
          if (stdioKind == wasi_vfs.Preview1StdioDescriptorKind.stdout) {
            io.stdout.add(output);
          } else {
            io.stderr.add(output);
          }
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
          view.bytes[bufPtr + i] = _secureRandom.nextInt(256);
        }
        return _errnoSuccess;
      });

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
        if (_vfs.descriptorKindForFd(fd) == null) {
          return _errnoBadf;
        }
        if (isDirectory) {
          return _errnoBadf;
        }
        final right = _checkDescriptorRight(fd, _rightFdRead);
        if (right != _errnoSuccess) {
          return right;
        }
        if (input == null && socket == null) {
          return _errnoBadf;
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
        return wasi_fd.preview1FdDatasync(vfs: _vfs, fd: _asInt(args[0]));
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
        final directoryPath = _vfs.directoryPathForFd(fd);
        if (directoryPath == null) {
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

        final openedHostPath = _vfs.openDirectoryHostPathForFd(fd);
        final hostPreopenPath = openedHostPath == null
            ? _hostPreopenPathForGuestPath(directoryPath)
            : null;
        final entriesResult = openedHostPath != null
            ? _readHostDirectoryEntries(openedHostPath, followSymlinks: false)
            : hostPreopenPath == null
            ? (errno: _errnoSuccess, entries: _vfs.directoryEntriesForFd(fd))
            : _readHostDirectoryEntries(
                hostPreopenPath.hostPath,
                followSymlinks: true,
              );
        List<wasi_vfs.Preview1DirectoryEntry>? entries;
        if (entriesResult.errno == _errnoSuccess) {
          entries = entriesResult.entries;
          if (openedHostPath != null && entries != null) {
            _vfs.refreshOpenDirectoryEntriesForFd(fd, entries);
          }
        } else if (openedHostPath != null &&
            entriesResult.errno == _errnoNoent) {
          _vfs.detachOpenDirectoryFd(fd);
          entries = _vfs.directoryEntriesForFd(fd);
        } else {
          return entriesResult.errno;
        }
        if (entries == null) {
          return _errnoBadf;
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
        return wasi_fd.preview1FdSync(vfs: _vfs, fd: _asInt(args[0]));
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
      io.stderr.writeln(
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

        final opened = _vfs.openFileForFd(fd);
        if (opened is _Preview1NativeHostOpenFile) {
          opened.refreshMetadata();
        }
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
        final fd = _asInt(args[0]);
        final metadata = _vfs.metadataForFd(fd);
        if (metadata == null) {
          return _errnoBadf;
        }
        final right = _checkDescriptorRight(fd, _rightFdFilestatSetTimes);
        if (right != _errnoSuccess) {
          return right;
        }
        final opened = _vfs.openFileForFd(fd);
        if (opened is _Preview1NativeHostOpenFile) {
          return _applyHostFileFilestatTimes(
            opened,
            accessTimeNanos: _asInt64(args[1]),
            modificationTimeNanos: _asInt64(args[2]),
            flags: _asInt(args[3]),
          );
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
          io.stderr.writeln('[wasi:fd_prestat_get] fd=$fd');
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
          io.stderr.writeln(
            '[wasi:fd_prestat_dir_name] fd=$fd pathLen=$pathLen',
          );
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
        final hostPath = _hostPathForGuestPath(resolved.path!);
        if (hostPath != null) {
          return _errnoFromPathMutationResult(_createHostDirectory(hostPath));
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
    final right = _checkDescriptorRight(dirFd, _rightPathOpen);
    if (right != _errnoSuccess) {
      return right;
    }
    if (_vfs.isDetachedOpenDirectoryFd(dirFd)) {
      return _errnoNoent;
    }
    final baseDirectory = _vfs.directoryPathForFd(dirFd)!;

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
      io.stderr.writeln(
        '[wasi:path_open] dirFd=$dirFd preopen=$baseDirectory path=$guestPath len=$pathLen',
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
        ? _vfs.resolveParentSymlinkPath(normalizedPath)
        : _vfs.resolveSymlinkPath(normalizedPath);
    if (openPath == null) {
      return _errnoNoent;
    }
    final fileBytes = _vfs.lookupFile(openPath);
    if (_traceSyscalls) {
      io.stderr.writeln(
        '[wasi:path_open] guest=$normalizedPath open=$openPath found=${fileBytes != null}',
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
    final hasVirtualPathEntry =
        _vfs.pathEntry(openPath, followSymlinks: false) != null;
    var opened =
        !hasVirtualPathEntry &&
            (oflags & _oflagCreat) != 0 &&
            _hostPathForGuestPath(openPath) != null
        ? _openHostPreopenPath(
            openPath,
            rightsBase: requestedRightsBase,
            rightsInheriting: requestedRightsInheriting,
            descriptorFlags: descriptorFlags,
            oflags: oflags,
            hasTrailingSeparator: guestPath.hasTrailingSeparator,
            followSymlinks: (lookupFlags & _lookupflagSymlinkFollow) != 0,
          )
        : _vfs.openPath(
            openPath,
            rightsBase: requestedRightsBase,
            rightsInheriting: requestedRightsInheriting,
            descriptorFlags: descriptorFlags,
            oflags: oflags,
            hasTrailingSeparator: guestPath.hasTrailingSeparator,
          );
    if (opened.kind == wasi_vfs.Preview1VirtualOpenKind.missing &&
        (oflags & _oflagCreat) == 0) {
      opened = _openHostPreopenPath(
        openPath,
        rightsBase: requestedRightsBase,
        rightsInheriting: requestedRightsInheriting,
        descriptorFlags: descriptorFlags,
        oflags: oflags,
        hasTrailingSeparator: guestPath.hasTrailingSeparator,
        followSymlinks: (lookupFlags & _lookupflagSymlinkFollow) != 0,
      );
    }
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
        final hostPath = _hostPathForGuestPath(resolved.path!);
        if (hostPath != null) {
          final hostResult =
              _hostPreopensByGuestPath.containsKey(resolved.path!)
              ? wasi_vfs.Preview1PathMutationResult.notEmpty
              : _removeHostDirectory(hostPath);
          if (hostResult == wasi_vfs.Preview1PathMutationResult.success) {
            _vfs.detachOpenDirectoryFdsForPath(resolved.path!);
          }
          if (hostResult != wasi_vfs.Preview1PathMutationResult.noEntry ||
              _vfs.pathEntry(resolved.path!, followSymlinks: false) == null) {
            return _errnoFromPathMutationResult(hostResult);
          }
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

        final oldHostPath = _hostPathForGuestPath(oldPath.path!);
        final newHostPath = _hostPathForGuestPath(newPath.path!);
        if (oldHostPath != null && newHostPath != null) {
          final hostResult = _renameHostPath(
            oldGuestPath: oldPath.path!,
            newGuestPath: newPath.path!,
            oldHostPath: oldHostPath,
            newHostPath: newHostPath,
          );
          if (hostResult == wasi_vfs.Preview1PathMutationResult.success) {
            _vfs.renameOpenDirectoryFdsForHostRename(
              oldGuestPath: oldPath.path!,
              newGuestPath: newPath.path!,
              oldHostPath: oldHostPath,
              newHostPath: newHostPath,
            );
          }
          if (hostResult != wasi_vfs.Preview1PathMutationResult.noEntry ||
              _vfs.pathEntry(oldPath.path!, followSymlinks: false) == null) {
            return _errnoFromPathMutationResult(hostResult);
          }
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
        final oldPathFollowSymlinks =
            (lookupFlags & _lookupflagSymlinkFollow) != 0;
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

        final oldHostPreopen = _hostPreopenPathForGuestPath(oldPath.path!);
        final newHostPath = _hostPathForGuestPath(newPath.path!);
        if (oldHostPreopen != null && newHostPath != null) {
          final hostResult = _linkHostPath(
            oldHostPath: oldHostPreopen.hostPath,
            oldHostRoot: oldHostPreopen.hostRoot,
            oldPathFollowSymlinks: oldPathFollowSymlinks,
            newHostPath: newHostPath,
            newPathHasTrailingSeparator: newPath.hasTrailingSeparator,
          );
          if (hostResult != wasi_vfs.Preview1PathMutationResult.noEntry ||
              _vfs.pathEntry(
                    oldPath.path!,
                    followSymlinks: oldPathFollowSymlinks,
                  ) ==
                  null) {
            return _errnoFromPathMutationResult(hostResult);
          }
        }

        return _errnoFromPathMutationResult(
          _vfs.linkPath(
            oldPath: oldPath.path!,
            newPath: newPath.path!,
            oldPathFollowSymlinks: oldPathFollowSymlinks,
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
        final hostPath = _hostPathForGuestPath(resolved.path!);
        if (hostPath != null) {
          final hostSymlink = _readHostSymlink(hostPath);
          if (hostSymlink.errno == _errnoSuccess) {
            final targetBytes = hostSymlink.targetBytes!;
            final bytesToWrite = math.min(bufferLength, targetBytes.length);
            if (bytesToWrite > 0) {
              bytes.setRange(bufferPtr, bufferPtr + bytesToWrite, targetBytes);
            }
            data.setUint32(bufferUsedPtr, bytesToWrite, Endian.little);
            return _errnoSuccess;
          }
          if (hostSymlink.errno != _errnoNoent || symlink == null) {
            return hostSymlink.errno;
          }
        }
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
        final targetInfo = wasi_vfs.resolveSymlinkTargetInfo(
          bytes: bytes,
          targetPtr: targetPtr,
          targetLen: targetLength,
        );
        if (targetInfo == null) {
          return _errnoInval;
        }
        final targetErrno = wasi_vfs.errnoForSymlinkTargetInfo(targetInfo);
        if (targetErrno != null) {
          return targetErrno;
        }
        final target = targetInfo.target;

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
        final hostPath = _hostPathForGuestPath(linkPath.path!);
        if (hostPath != null) {
          return _errnoFromPathMutationResult(
            _createHostSymlink(
              target: target,
              linkHostPath: hostPath,
              hasTrailingSeparator: linkPath.hasTrailingSeparator,
            ),
          );
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
        final hostPath = _hostPathForGuestPath(resolved.path!);
        if (hostPath != null) {
          final hostResult = _unlinkHostFile(
            hostPath,
            hasTrailingSeparator: resolved.hasTrailingSeparator,
          );
          if (hostResult != wasi_vfs.Preview1PathMutationResult.noEntry ||
              _vfs.pathEntry(resolved.path!, followSymlinks: false) == null) {
            return _errnoFromPathMutationResult(hostResult);
          }
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
      io.stderr.writeln(
        '[wasi:path_filestat_get] dirFd=$dirFd preopen=$baseDirectory path=$guestPath len=$pathLen',
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
    final statPath = (lookupFlags & _lookupflagSymlinkFollow) == 0
        ? _vfs.resolveParentSymlinkPath(normalizedPath)
        : _vfs.resolveSymlinkPath(normalizedPath);
    if (statPath == null) {
      return _errnoNoent;
    }
    final entry = _vfs.pathEntry(statPath, followSymlinks: false);
    if (entry == null) {
      final hostEntry = _hostPathEntry(
        statPath,
        followSymlinks: (lookupFlags & _lookupflagSymlinkFollow) != 0,
      );
      if (hostEntry.errno != _errnoSuccess) {
        return hostEntry.errno;
      }
      return _writeFilestatEntry(
        bytes: bytes,
        data: data,
        filestatPtr: filestatPtr,
        entry: hostEntry.entry!,
      );
    }

    return _writeFilestatEntry(
      bytes: bytes,
      data: data,
      filestatPtr: filestatPtr,
      entry: entry,
    );
  });

  int _writeFilestatEntry({
    required Uint8List bytes,
    required ByteData data,
    required int filestatPtr,
    required wasi_vfs.Preview1VirtualPathEntry entry,
  }) {
    bytes.fillRange(filestatPtr, filestatPtr + _filestatSize, 0);
    bytes[filestatPtr + 16] = entry.fileType;
    _setUint64(data, filestatPtr + 32, entry.size);
    wasi_vfs.writeFilestatMetadata(
      data: data,
      filestatPtr: filestatPtr,
      metadata: entry.metadata,
    );
    return _errnoSuccess;
  }

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
        final followSymlinks = (lookupFlags & _lookupflagSymlinkFollow) != 0;
        final entry = _vfs.pathEntry(
          resolved.path!,
          followSymlinks: followSymlinks,
        );
        if (entry != null) {
          return _applyFilestatTimes(
            metadata: entry.metadata,
            accessTimeNanos: _asInt64(args[4]),
            modificationTimeNanos: _asInt64(args[5]),
            flags: _asInt(args[6]),
          );
        }
        final hostPreopen = _hostPreopenPathForGuestPath(resolved.path!);
        if (hostPreopen == null) {
          return _errnoNoent;
        }
        return _applyHostPathFilestatTimes(
          hostPath: hostPreopen.hostPath,
          hostRoot: hostPreopen.hostRoot,
          followSymlinks: followSymlinks,
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

        final pollStartMonotonic = _clockNowNanos(_clockMonotonic);
        var waitNanos = _writePollEvents(
          bytes: bytes,
          data: data,
          inPtr: inPtr,
          outPtr: outPtr,
          nsubscriptions: nsubscriptions,
          neventsPtr: neventsPtr,
          pollStartMonotonic: pollStartMonotonic,
        );
        if (waitNanos > 0) {
          io.sleep(_durationFromNanos(waitNanos));
          waitNanos = _writePollEvents(
            bytes: bytes,
            data: data,
            inPtr: inPtr,
            outPtr: outPtr,
            nsubscriptions: nsubscriptions,
            neventsPtr: neventsPtr,
            pollStartMonotonic: pollStartMonotonic,
          );
        }
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

  wasi_vfs.Preview1VirtualOpenResult _openHostPreopenPath(
    String guestPath, {
    required int rightsBase,
    required int rightsInheriting,
    required int descriptorFlags,
    required int oflags,
    required bool hasTrailingSeparator,
    required bool followSymlinks,
  }) {
    final hostPreopenPath = _hostPreopenPathForGuestPath(guestPath);
    if (hostPreopenPath == null) {
      return const wasi_vfs.Preview1VirtualOpenResult.missing();
    }
    var hostPath = hostPreopenPath.hostPath;
    final create = (oflags & _oflagCreat) != 0;
    final exclusive = (oflags & _oflagExcl) != 0;
    final truncate = (oflags & _oflagTrunc) != 0;

    var type = io.FileSystemEntity.typeSync(hostPath, followLinks: false);
    if (type == io.FileSystemEntityType.notFound) {
      if (create) {
        if (hasTrailingSeparator || (oflags & _oflagDirectory) != 0) {
          return const wasi_vfs.Preview1VirtualOpenResult.missing();
        }
        final parentType = io.FileSystemEntity.typeSync(
          io.File(hostPath).parent.path,
          followLinks: false,
        );
        if (parentType == io.FileSystemEntityType.notFound) {
          return const wasi_vfs.Preview1VirtualOpenResult.missing();
        }
        if (parentType != io.FileSystemEntityType.directory) {
          return const wasi_vfs.Preview1VirtualOpenResult.notDirectory();
        }
        return _openHostFile(
          hostPath: hostPath,
          rightsBase: rightsBase,
          rightsInheriting: rightsInheriting,
          descriptorFlags: descriptorFlags,
          create: true,
          truncate: truncate,
        );
      }
      return const wasi_vfs.Preview1VirtualOpenResult.missing();
    }
    if (type == io.FileSystemEntityType.link) {
      if (!followSymlinks) {
        return const wasi_vfs.Preview1VirtualOpenResult.symlinkLoop();
      }
      if (create && exclusive) {
        return const wasi_vfs.Preview1VirtualOpenResult.exists();
      }
      final resolved = _resolveHostSymlinkTarget(
        linkHostPath: hostPath,
        hostRoot: hostPreopenPath.hostRoot,
      );
      if (resolved.errno == _errnoNotcapable) {
        return const wasi_vfs.Preview1VirtualOpenResult.notCapable();
      }
      if (resolved.errno == _errnoLoop) {
        return const wasi_vfs.Preview1VirtualOpenResult.symlinkLoop();
      }
      if (resolved.errno == _errnoNoent) {
        return const wasi_vfs.Preview1VirtualOpenResult.missing();
      }
      if (resolved.errno != _errnoSuccess) {
        return const wasi_vfs.Preview1VirtualOpenResult.notSupported();
      }
      hostPath = resolved.hostPath!;
      type = io.FileSystemEntity.typeSync(hostPath, followLinks: false);
    }
    if (type == io.FileSystemEntityType.directory) {
      if (create && exclusive) {
        return const wasi_vfs.Preview1VirtualOpenResult.exists();
      }
      if (truncate) {
        return const wasi_vfs.Preview1VirtualOpenResult.isDirectory();
      }
      return _openHostDirectory(
        guestPath: guestPath,
        hostPath: hostPath,
        rightsBase: rightsBase,
        rightsInheriting: rightsInheriting,
        descriptorFlags: descriptorFlags,
      );
    }
    if (type != io.FileSystemEntityType.file) {
      return const wasi_vfs.Preview1VirtualOpenResult.missing();
    }
    if (hasTrailingSeparator || (oflags & _oflagDirectory) != 0) {
      return const wasi_vfs.Preview1VirtualOpenResult.notDirectory();
    }
    if (create && exclusive) {
      return const wasi_vfs.Preview1VirtualOpenResult.exists();
    }

    return _openHostFile(
      hostPath: hostPath,
      rightsBase: rightsBase,
      rightsInheriting: rightsInheriting,
      descriptorFlags: descriptorFlags,
      create: false,
      truncate: truncate,
    );
  }

  String? _hostPathForGuestPath(String guestPath) =>
      _hostPreopenPathForGuestPath(guestPath)?.hostPath;

  ({String guestRoot, String hostRoot, String hostPath})?
  _hostPreopenPathForGuestPath(String guestPath) {
    final normalized = wasi_vfs.normalizeGuestPath(guestPath);
    String? matchedGuestRoot;
    for (final guestRoot in _hostPreopensByGuestPath.keys) {
      final matches = guestRoot == '/'
          ? normalized.startsWith('/')
          : normalized == guestRoot || normalized.startsWith('$guestRoot/');
      if (matches) {
        if (matchedGuestRoot == null ||
            guestRoot.length > matchedGuestRoot.length) {
          matchedGuestRoot = guestRoot;
        }
      }
    }
    if (matchedGuestRoot == null) {
      return null;
    }

    final hostRoot = _hostPreopensByGuestPath[matchedGuestRoot]!;
    final relative = matchedGuestRoot == '/'
        ? normalized.substring(1)
        : normalized == matchedGuestRoot
        ? ''
        : normalized.substring(matchedGuestRoot.length + 1);
    return (
      guestRoot: matchedGuestRoot,
      hostRoot: hostRoot,
      hostPath: _joinHostPath(hostRoot, relative),
    );
  }

  wasi_vfs.Preview1VirtualOpenResult _openHostDirectory({
    required String guestPath,
    required String hostPath,
    required int rightsBase,
    required int rightsInheriting,
    required int descriptorFlags,
  }) {
    try {
      final entries = _hostDirectoryEntries(hostPath);
      return _vfs.openDirectoryHandle(
        guestPath,
        entries: entries,
        metadata: _metadataFromHostPath(hostPath),
        hostPath: hostPath,
        rightsBase: rightsBase,
        rightsInheriting: rightsInheriting,
        descriptorFlags: descriptorFlags,
      );
    } on io.FileSystemException {
      return const wasi_vfs.Preview1VirtualOpenResult.missing();
    }
  }

  wasi_vfs.Preview1VirtualOpenResult _openHostFile({
    required String hostPath,
    required int rightsBase,
    required int rightsInheriting,
    required int descriptorFlags,
    required bool create,
    required bool truncate,
  }) {
    final file = io.File(hostPath);
    io.RandomAccessFile? opened;
    try {
      final requiresWriteHandle =
          create ||
          truncate ||
          (rightsBase &
                  (_rightFdWrite |
                      _rightFdAllocate |
                      _rightFdFilestatSetSize)) !=
              0;
      opened = file.openSync(
        mode: requiresWriteHandle ? io.FileMode.append : io.FileMode.read,
      );
      if (truncate) {
        opened.truncateSync(0);
      }
      return _vfs.openFileHandle(
        _Preview1NativeHostOpenFile(
          opened,
          hostPath: hostPath,
          metadata: _metadataFromHostPath(hostPath),
          rights: wasi_vfs.Preview1DescriptorRights.file(
            base: rightsBase,
            inheriting: rightsInheriting,
          ),
          descriptorFlags: descriptorFlags,
        ),
      );
    } on io.FileSystemException {
      try {
        opened?.closeSync();
      } on io.FileSystemException {
        // Preserve the open failure as the syscall result.
      }
      return const wasi_vfs.Preview1VirtualOpenResult.missing();
    }
  }

  wasi_vfs.Preview1PathMutationResult _createHostDirectory(String hostPath) {
    final type = io.FileSystemEntity.typeSync(hostPath, followLinks: false);
    if (type != io.FileSystemEntityType.notFound) {
      return wasi_vfs.Preview1PathMutationResult.exists;
    }
    final parentType = io.FileSystemEntity.typeSync(
      io.Directory(hostPath).parent.path,
      followLinks: false,
    );
    if (parentType == io.FileSystemEntityType.notFound) {
      return wasi_vfs.Preview1PathMutationResult.noEntry;
    }
    if (parentType != io.FileSystemEntityType.directory) {
      return wasi_vfs.Preview1PathMutationResult.notDirectory;
    }

    try {
      io.Directory(hostPath).createSync();
      return wasi_vfs.Preview1PathMutationResult.success;
    } on io.FileSystemException {
      return _hostPathMutationError(hostPath);
    }
  }

  wasi_vfs.Preview1PathMutationResult _removeHostDirectory(String hostPath) {
    final type = io.FileSystemEntity.typeSync(hostPath, followLinks: false);
    if (type == io.FileSystemEntityType.notFound) {
      return wasi_vfs.Preview1PathMutationResult.noEntry;
    }
    if (type != io.FileSystemEntityType.directory) {
      return wasi_vfs.Preview1PathMutationResult.notDirectory;
    }

    final directory = io.Directory(hostPath);
    try {
      if (directory.listSync(followLinks: false).isNotEmpty) {
        return wasi_vfs.Preview1PathMutationResult.notEmpty;
      }
      directory.deleteSync();
      return wasi_vfs.Preview1PathMutationResult.success;
    } on io.FileSystemException {
      return _hostPathMutationError(hostPath);
    }
  }

  wasi_vfs.Preview1PathMutationResult _unlinkHostFile(
    String hostPath, {
    required bool hasTrailingSeparator,
  }) {
    final type = io.FileSystemEntity.typeSync(hostPath, followLinks: false);
    if (hasTrailingSeparator) {
      if (type == io.FileSystemEntityType.directory) {
        return wasi_vfs.Preview1PathMutationResult.isDirectory;
      }
      if (type == io.FileSystemEntityType.file ||
          type == io.FileSystemEntityType.link) {
        return wasi_vfs.Preview1PathMutationResult.notDirectory;
      }
      return wasi_vfs.Preview1PathMutationResult.noEntry;
    }
    if (type == io.FileSystemEntityType.notFound) {
      return wasi_vfs.Preview1PathMutationResult.noEntry;
    }
    if (type == io.FileSystemEntityType.directory) {
      return wasi_vfs.Preview1PathMutationResult.isDirectory;
    }
    if (type != io.FileSystemEntityType.file &&
        type != io.FileSystemEntityType.link) {
      return wasi_vfs.Preview1PathMutationResult.noEntry;
    }

    try {
      if (type == io.FileSystemEntityType.link) {
        io.Link(hostPath).deleteSync();
      } else {
        io.File(hostPath).deleteSync();
      }
      return wasi_vfs.Preview1PathMutationResult.success;
    } on io.FileSystemException {
      return _hostPathMutationError(hostPath);
    }
  }

  wasi_vfs.Preview1PathMutationResult _renameHostPath({
    required String oldGuestPath,
    required String newGuestPath,
    required String oldHostPath,
    required String newHostPath,
  }) {
    if (_hostPreopensByGuestPath.containsKey(oldGuestPath)) {
      return wasi_vfs.Preview1PathMutationResult.invalid;
    }

    final oldType = io.FileSystemEntity.typeSync(
      oldHostPath,
      followLinks: false,
    );
    if (oldType == io.FileSystemEntityType.notFound) {
      return wasi_vfs.Preview1PathMutationResult.noEntry;
    }
    if (_sameHostPath(oldHostPath, newHostPath)) {
      return wasi_vfs.Preview1PathMutationResult.success;
    }

    final newParentType = io.FileSystemEntity.typeSync(
      io.File(newHostPath).parent.path,
      followLinks: false,
    );
    if (newParentType == io.FileSystemEntityType.notFound) {
      return wasi_vfs.Preview1PathMutationResult.noEntry;
    }
    if (newParentType != io.FileSystemEntityType.directory) {
      return wasi_vfs.Preview1PathMutationResult.notDirectory;
    }

    final newType = io.FileSystemEntity.typeSync(
      newHostPath,
      followLinks: false,
    );
    if (oldType == io.FileSystemEntityType.directory) {
      if (_isChildGuestPath(newGuestPath, oldGuestPath)) {
        return wasi_vfs.Preview1PathMutationResult.invalid;
      }
      if (newType == io.FileSystemEntityType.file ||
          newType == io.FileSystemEntityType.link) {
        return wasi_vfs.Preview1PathMutationResult.notDirectory;
      }
      if (newType == io.FileSystemEntityType.directory &&
          !_sameHostPath(oldHostPath, newHostPath)) {
        final target = io.Directory(newHostPath);
        try {
          if (target.listSync(followLinks: false).isNotEmpty) {
            return wasi_vfs.Preview1PathMutationResult.notEmpty;
          }
          _vfs.detachOpenDirectoryFdsForPath(newGuestPath);
          target.deleteSync();
        } on io.FileSystemException {
          return _hostPathMutationError(newHostPath);
        }
      }
      return _renameHostEntity(
        type: oldType,
        oldHostPath: oldHostPath,
        newHostPath: newHostPath,
      );
    }

    if (newType == io.FileSystemEntityType.directory) {
      return wasi_vfs.Preview1PathMutationResult.isDirectory;
    }
    return _renameHostEntity(
      type: oldType,
      oldHostPath: oldHostPath,
      newHostPath: newHostPath,
    );
  }

  wasi_vfs.Preview1PathMutationResult _renameHostEntity({
    required io.FileSystemEntityType type,
    required String oldHostPath,
    required String newHostPath,
  }) {
    try {
      if (type == io.FileSystemEntityType.directory) {
        io.Directory(oldHostPath).renameSync(newHostPath);
      } else if (type == io.FileSystemEntityType.link) {
        io.Link(oldHostPath).renameSync(newHostPath);
      } else {
        io.File(oldHostPath).renameSync(newHostPath);
      }
      return wasi_vfs.Preview1PathMutationResult.success;
    } on io.FileSystemException {
      return _hostPathMutationError(oldHostPath);
    }
  }

  wasi_vfs.Preview1PathMutationResult _linkHostPath({
    required String oldHostPath,
    required String oldHostRoot,
    required bool oldPathFollowSymlinks,
    required String newHostPath,
    required bool newPathHasTrailingSeparator,
  }) {
    final newType = io.FileSystemEntity.typeSync(
      newHostPath,
      followLinks: false,
    );
    if (newPathHasTrailingSeparator) {
      if (newType == io.FileSystemEntityType.directory) {
        return wasi_vfs.Preview1PathMutationResult.exists;
      }
      if (newType == io.FileSystemEntityType.file ||
          newType == io.FileSystemEntityType.link) {
        return wasi_vfs.Preview1PathMutationResult.notDirectory;
      }
      return wasi_vfs.Preview1PathMutationResult.noEntry;
    }

    final newParentType = io.FileSystemEntity.typeSync(
      io.File(newHostPath).parent.path,
      followLinks: false,
    );
    if (newParentType == io.FileSystemEntityType.notFound) {
      return wasi_vfs.Preview1PathMutationResult.noEntry;
    }
    if (newParentType != io.FileSystemEntityType.directory) {
      return wasi_vfs.Preview1PathMutationResult.notDirectory;
    }
    if (newType != io.FileSystemEntityType.notFound) {
      return wasi_vfs.Preview1PathMutationResult.exists;
    }

    var sourceHostPath = oldHostPath;
    var oldType = io.FileSystemEntity.typeSync(
      sourceHostPath,
      followLinks: false,
    );
    if (oldType == io.FileSystemEntityType.link && oldPathFollowSymlinks) {
      final resolved = _resolveHostSymlinkTarget(
        linkHostPath: sourceHostPath,
        hostRoot: oldHostRoot,
      );
      if (resolved.errno != _errnoSuccess) {
        return _pathMutationResultFromErrno(resolved.errno);
      }
      sourceHostPath = resolved.hostPath!;
      oldType = io.FileSystemEntity.typeSync(
        sourceHostPath,
        followLinks: false,
      );
    }
    if (oldType == io.FileSystemEntityType.directory) {
      return wasi_vfs.Preview1PathMutationResult.permissionDenied;
    }
    if (oldType != io.FileSystemEntityType.file &&
        oldType != io.FileSystemEntityType.link) {
      return oldType == io.FileSystemEntityType.notFound
          ? wasi_vfs.Preview1PathMutationResult.noEntry
          : wasi_vfs.Preview1PathMutationResult.permissionDenied;
    }

    return _createHostHardLink(
      oldHostPath: sourceHostPath,
      newHostPath: newHostPath,
    );
  }

  wasi_vfs.Preview1PathMutationResult _createHostHardLink({
    required String oldHostPath,
    required String newHostPath,
  }) {
    try {
      if (_hostHardLink(oldHostPath, newHostPath)) {
        return wasi_vfs.Preview1PathMutationResult.success;
      }
    } on ArgumentError {
      return wasi_vfs.Preview1PathMutationResult.permissionDenied;
    } on UnsupportedError {
      return wasi_vfs.Preview1PathMutationResult.permissionDenied;
    }
    return _hostLinkFailure(oldHostPath: oldHostPath, newHostPath: newHostPath);
  }

  wasi_vfs.Preview1PathMutationResult _createHostSymlink({
    required String target,
    required String linkHostPath,
    required bool hasTrailingSeparator,
  }) {
    if (wasi_vfs.isAbsoluteGuestPath(target)) {
      return wasi_vfs.Preview1PathMutationResult.notCapable;
    }

    final linkType = io.FileSystemEntity.typeSync(
      linkHostPath,
      followLinks: false,
    );
    if (hasTrailingSeparator) {
      if (linkType == io.FileSystemEntityType.directory) {
        return wasi_vfs.Preview1PathMutationResult.exists;
      }
      if (linkType == io.FileSystemEntityType.file ||
          linkType == io.FileSystemEntityType.link) {
        return wasi_vfs.Preview1PathMutationResult.notDirectory;
      }
      return wasi_vfs.Preview1PathMutationResult.noEntry;
    }
    if (linkType != io.FileSystemEntityType.notFound) {
      return wasi_vfs.Preview1PathMutationResult.exists;
    }

    final parentType = io.FileSystemEntity.typeSync(
      io.Link(linkHostPath).parent.path,
      followLinks: false,
    );
    if (parentType == io.FileSystemEntityType.notFound) {
      return wasi_vfs.Preview1PathMutationResult.noEntry;
    }
    if (parentType != io.FileSystemEntityType.directory) {
      return wasi_vfs.Preview1PathMutationResult.notDirectory;
    }

    try {
      io.Link(linkHostPath).createSync(target);
      return wasi_vfs.Preview1PathMutationResult.success;
    } on io.FileSystemException {
      return _hostCreatePathFailure(linkHostPath);
    }
  }

  ({int errno, Uint8List? targetBytes}) _readHostSymlink(String hostPath) {
    final type = io.FileSystemEntity.typeSync(hostPath, followLinks: false);
    if (type == io.FileSystemEntityType.notFound) {
      return (errno: _errnoNoent, targetBytes: null);
    }
    if (type != io.FileSystemEntityType.link) {
      return (errno: _errnoInval, targetBytes: null);
    }

    try {
      return (
        errno: _errnoSuccess,
        targetBytes: Uint8List.fromList(
          utf8.encode(io.Link(hostPath).targetSync()),
        ),
      );
    } on io.FileSystemException {
      final currentType = io.FileSystemEntity.typeSync(
        hostPath,
        followLinks: false,
      );
      return (
        errno: currentType == io.FileSystemEntityType.notFound
            ? _errnoNoent
            : _errnoPerm,
        targetBytes: null,
      );
    }
  }

  ({int errno, String? hostPath}) _resolveHostSymlinkTarget({
    required String linkHostPath,
    required String hostRoot,
  }) {
    late final String target;
    try {
      target = io.Link(linkHostPath).targetSync();
    } on io.FileSystemException {
      final type = io.FileSystemEntity.typeSync(
        linkHostPath,
        followLinks: false,
      );
      return (
        errno: type == io.FileSystemEntityType.notFound
            ? _errnoNoent
            : _errnoPerm,
        hostPath: null,
      );
    }

    final targetHostPath = io.File(target).isAbsolute
        ? target
        : _joinNativeHostPath(io.Link(linkHostPath).parent.path, target);
    final targetType = io.FileSystemEntity.typeSync(
      targetHostPath,
      followLinks: false,
    );
    if (targetType == io.FileSystemEntityType.notFound) {
      return (errno: _errnoNoent, hostPath: null);
    }

    try {
      final resolvedTarget = io.File(targetHostPath).resolveSymbolicLinksSync();
      final resolvedRoot = io.Directory(hostRoot).resolveSymbolicLinksSync();
      if (!_isHostPathWithinRoot(resolvedTarget, resolvedRoot)) {
        return (errno: _errnoNotcapable, hostPath: null);
      }
      return (errno: _errnoSuccess, hostPath: resolvedTarget);
    } on io.FileSystemException catch (error) {
      final errno = _errnoFromHostResolveError(error);
      if (errno != null) {
        return (errno: errno, hostPath: null);
      }
      final currentType = io.FileSystemEntity.typeSync(
        targetHostPath,
        followLinks: false,
      );
      if (currentType == io.FileSystemEntityType.notFound) {
        return (errno: _errnoNoent, hostPath: null);
      }
      if (currentType == io.FileSystemEntityType.link) {
        return (errno: _errnoLoop, hostPath: null);
      }
      return (errno: _errnoPerm, hostPath: null);
    }
  }

  int? _errnoFromHostResolveError(io.FileSystemException error) {
    return switch (error.osError?.errorCode) {
      2 => _errnoNoent,
      40 || 62 => _errnoLoop,
      _ => null,
    };
  }

  wasi_vfs.Preview1PathMutationResult _hostLinkFailure({
    required String oldHostPath,
    required String newHostPath,
  }) {
    final newType = io.FileSystemEntity.typeSync(
      newHostPath,
      followLinks: false,
    );
    if (newType != io.FileSystemEntityType.notFound) {
      return wasi_vfs.Preview1PathMutationResult.exists;
    }
    final newParentType = io.FileSystemEntity.typeSync(
      io.File(newHostPath).parent.path,
      followLinks: false,
    );
    if (newParentType == io.FileSystemEntityType.notFound) {
      return wasi_vfs.Preview1PathMutationResult.noEntry;
    }
    if (newParentType != io.FileSystemEntityType.directory) {
      return wasi_vfs.Preview1PathMutationResult.notDirectory;
    }
    final oldType = io.FileSystemEntity.typeSync(
      oldHostPath,
      followLinks: false,
    );
    if (oldType == io.FileSystemEntityType.notFound) {
      return wasi_vfs.Preview1PathMutationResult.noEntry;
    }
    if (oldType == io.FileSystemEntityType.directory) {
      return wasi_vfs.Preview1PathMutationResult.permissionDenied;
    }
    return wasi_vfs.Preview1PathMutationResult.permissionDenied;
  }

  wasi_vfs.Preview1PathMutationResult _pathMutationResultFromErrno(int errno) =>
      switch (errno) {
        _errnoSuccess => wasi_vfs.Preview1PathMutationResult.success,
        _errnoNoent => wasi_vfs.Preview1PathMutationResult.noEntry,
        _errnoNotcapable => wasi_vfs.Preview1PathMutationResult.notCapable,
        _errnoLoop => wasi_vfs.Preview1PathMutationResult.symlinkLoop,
        _errnoNotdir => wasi_vfs.Preview1PathMutationResult.notDirectory,
        _errnoIsdir => wasi_vfs.Preview1PathMutationResult.isDirectory,
        _ => wasi_vfs.Preview1PathMutationResult.permissionDenied,
      };

  wasi_vfs.Preview1PathMutationResult _hostCreatePathFailure(String hostPath) {
    final type = io.FileSystemEntity.typeSync(hostPath, followLinks: false);
    if (type != io.FileSystemEntityType.notFound) {
      return wasi_vfs.Preview1PathMutationResult.exists;
    }
    final parentType = io.FileSystemEntity.typeSync(
      io.File(hostPath).parent.path,
      followLinks: false,
    );
    if (parentType == io.FileSystemEntityType.notFound) {
      return wasi_vfs.Preview1PathMutationResult.noEntry;
    }
    if (parentType != io.FileSystemEntityType.directory) {
      return wasi_vfs.Preview1PathMutationResult.notDirectory;
    }
    return wasi_vfs.Preview1PathMutationResult.permissionDenied;
  }

  wasi_vfs.Preview1PathMutationResult _hostPathMutationError(String hostPath) {
    if (io.FileSystemEntity.typeSync(hostPath, followLinks: false) ==
        io.FileSystemEntityType.notFound) {
      return wasi_vfs.Preview1PathMutationResult.noEntry;
    }
    return wasi_vfs.Preview1PathMutationResult.permissionDenied;
  }

  ({int errno, List<wasi_vfs.Preview1DirectoryEntry>? entries})
  _readHostDirectoryEntries(String hostPath, {required bool followSymlinks}) {
    try {
      final type = io.FileSystemEntity.typeSync(
        hostPath,
        followLinks: followSymlinks,
      );
      if (type == io.FileSystemEntityType.notFound) {
        return (errno: _errnoNoent, entries: null);
      }
      if (type != io.FileSystemEntityType.directory) {
        return (errno: _errnoNotdir, entries: null);
      }
      return (errno: _errnoSuccess, entries: _hostDirectoryEntries(hostPath));
    } on io.FileSystemException {
      final type = io.FileSystemEntity.typeSync(
        hostPath,
        followLinks: followSymlinks,
      );
      if (type == io.FileSystemEntityType.notFound) {
        return (errno: _errnoNoent, entries: null);
      }
      if (type != io.FileSystemEntityType.directory) {
        return (errno: _errnoNotdir, entries: null);
      }
      return (errno: _errnoPerm, entries: null);
    }
  }

  List<wasi_vfs.Preview1DirectoryEntry> _hostDirectoryEntries(String hostPath) {
    final entities = io.Directory(
      hostPath,
    ).listSync(recursive: false, followLinks: false);
    final entries = <wasi_vfs.Preview1DirectoryEntry>[
      wasi_vfs.Preview1DirectoryEntry(
        name: '.',
        fileType: _filetypeDirectory,
        inode: _hostPathInode(hostPath),
      ),
      wasi_vfs.Preview1DirectoryEntry(
        name: '..',
        fileType: _filetypeDirectory,
        inode: _hostPathInode(io.Directory(hostPath).parent.path),
      ),
    ];
    for (final entity in entities) {
      final name = _hostEntityName(entity.path);
      if (name.isEmpty) {
        continue;
      }
      final type = io.FileSystemEntity.typeSync(
        entity.path,
        followLinks: false,
      );
      final fileType = _hostDirectoryEntryFileType(type);
      if (fileType == null) {
        continue;
      }
      entries.add(
        wasi_vfs.Preview1DirectoryEntry(
          name: name,
          fileType: fileType,
          inode: _hostEntityInode(entity),
        ),
      );
    }
    entries.sort((a, b) => a.name.compareTo(b.name));
    return entries;
  }

  int? _hostDirectoryEntryFileType(io.FileSystemEntityType type) {
    if (type == io.FileSystemEntityType.file) {
      return _filetypeRegularFile;
    }
    if (type == io.FileSystemEntityType.directory) {
      return _filetypeDirectory;
    }
    if (type == io.FileSystemEntityType.link) {
      return _filetypeSymbolicLink;
    }
    return null;
  }

  int _hostEntityInode(io.FileSystemEntity entity) =>
      _hostPathInode(entity.path);

  String _hostEntityName(String path) {
    final sanitized = path.replaceAll('\\', '/');
    final slash = sanitized.lastIndexOf('/');
    return slash == -1 ? sanitized : sanitized.substring(slash + 1);
  }

  ({int errno, wasi_vfs.Preview1VirtualPathEntry? entry}) _hostPathEntry(
    String guestPath, {
    required bool followSymlinks,
  }) {
    final hostPreopenPath = _hostPreopenPathForGuestPath(guestPath);
    if (hostPreopenPath == null) {
      return (errno: _errnoNoent, entry: null);
    }
    return _hostPathEntryForHostPath(
      hostPath: hostPreopenPath.hostPath,
      hostRoot: hostPreopenPath.hostRoot,
      followSymlinks: followSymlinks,
    );
  }

  ({int errno, wasi_vfs.Preview1VirtualPathEntry? entry})
  _hostPathEntryForHostPath({
    required String hostPath,
    required String hostRoot,
    required bool followSymlinks,
  }) {
    final type = io.FileSystemEntity.typeSync(hostPath, followLinks: false);
    if (type == io.FileSystemEntityType.notFound) {
      return (errno: _errnoNoent, entry: null);
    }
    if (type == io.FileSystemEntityType.link) {
      if (!followSymlinks) {
        return _hostSymlinkPathEntry(hostPath);
      }
      final resolved = _resolveHostSymlinkTarget(
        linkHostPath: hostPath,
        hostRoot: hostRoot,
      );
      if (resolved.errno != _errnoSuccess) {
        return (errno: resolved.errno, entry: null);
      }
      return _hostPathEntryForHostPath(
        hostPath: resolved.hostPath!,
        hostRoot: hostRoot,
        followSymlinks: false,
      );
    }

    try {
      switch (type) {
        case io.FileSystemEntityType.file:
          final stat = io.File(hostPath).statSync();
          return (
            errno: _errnoSuccess,
            entry: wasi_vfs.Preview1VirtualPathEntry(
              kind: wasi_vfs.Preview1VirtualPathEntryKind.file,
              metadata: _metadataFromHostPath(hostPath),
              size: stat.size,
            ),
          );
        case io.FileSystemEntityType.directory:
          return (
            errno: _errnoSuccess,
            entry: wasi_vfs.Preview1VirtualPathEntry(
              kind: wasi_vfs.Preview1VirtualPathEntryKind.directory,
              metadata: _metadataFromHostPath(hostPath),
            ),
          );
        case io.FileSystemEntityType.link:
        case io.FileSystemEntityType.notFound:
          return (errno: _errnoNoent, entry: null);
        case io.FileSystemEntityType.pipe:
        case io.FileSystemEntityType.unixDomainSock:
          return (errno: _errnoNotsup, entry: null);
      }
      return (errno: _errnoNotsup, entry: null);
    } on io.FileSystemException {
      return (errno: _errnoNoent, entry: null);
    }
  }

  ({int errno, wasi_vfs.Preview1VirtualPathEntry? entry}) _hostSymlinkPathEntry(
    String hostPath,
  ) {
    final target = _readHostSymlink(hostPath);
    if (target.errno != _errnoSuccess) {
      return (errno: target.errno, entry: null);
    }
    return (
      errno: _errnoSuccess,
      entry: wasi_vfs.Preview1VirtualPathEntry(
        kind: wasi_vfs.Preview1VirtualPathEntryKind.symlink,
        metadata: _metadataFromHostLstat(hostPath),
        size: target.targetBytes!.length,
      ),
    );
  }

  int _applyFilestatTimes({
    required wasi_vfs.Preview1VirtualNodeMetadata metadata,
    required int accessTimeNanos,
    required int modificationTimeNanos,
    required int flags,
  }) {
    final update = _resolveFilestatTimeUpdate(
      accessTimeNanos: accessTimeNanos,
      modificationTimeNanos: modificationTimeNanos,
      flags: flags,
    );
    if (update.errno != _errnoSuccess) {
      return update.errno;
    }
    _applyResolvedFilestatTimes(metadata: metadata, update: update);
    return _errnoSuccess;
  }

  int _applyHostFileFilestatTimes(
    _Preview1NativeHostOpenFile opened, {
    required int accessTimeNanos,
    required int modificationTimeNanos,
    required int flags,
  }) {
    final update = _resolveFilestatTimeUpdate(
      accessTimeNanos: accessTimeNanos,
      modificationTimeNanos: modificationTimeNanos,
      flags: flags,
    );
    if (update.errno != _errnoSuccess) {
      return update.errno;
    }
    return _applyHostFileResolvedFilestatTimes(
      hostPath: opened.hostPath,
      metadata: opened.metadata,
      update: update,
    );
  }

  int _applyHostPathFilestatTimes({
    required String hostPath,
    required String hostRoot,
    required bool followSymlinks,
    required int accessTimeNanos,
    required int modificationTimeNanos,
    required int flags,
  }) {
    final update = _resolveFilestatTimeUpdate(
      accessTimeNanos: accessTimeNanos,
      modificationTimeNanos: modificationTimeNanos,
      flags: flags,
    );
    if (update.errno != _errnoSuccess) {
      return update.errno;
    }
    var targetHostPath = hostPath;
    var type = io.FileSystemEntity.typeSync(targetHostPath, followLinks: false);
    if (type == io.FileSystemEntityType.link) {
      if (!followSymlinks) {
        return _applyHostPathResolvedFilestatTimes(
          hostPath: targetHostPath,
          type: type,
          noFollowSymlink: true,
          update: update,
        );
      }
      final resolved = _resolveHostSymlinkTarget(
        linkHostPath: targetHostPath,
        hostRoot: hostRoot,
      );
      if (resolved.errno != _errnoSuccess) {
        return resolved.errno;
      }
      targetHostPath = resolved.hostPath!;
      type = io.FileSystemEntity.typeSync(targetHostPath, followLinks: false);
    }
    if (type == io.FileSystemEntityType.notFound) {
      return _errnoNoent;
    }
    return _applyHostPathResolvedFilestatTimes(
      hostPath: targetHostPath,
      type: type,
      noFollowSymlink: false,
      update: update,
    );
  }

  ({int errno, int? accessTimeNanos, int? modificationTimeNanos})
  _resolveFilestatTimeUpdate({
    required int accessTimeNanos,
    required int modificationTimeNanos,
    required int flags,
  }) {
    if ((flags & ~_filestatTimeKnownFlags) != 0 ||
        (flags & _filestatSetAccessTime) != 0 &&
            (flags & _filestatSetAccessTimeNow) != 0 ||
        (flags & _filestatSetModificationTime) != 0 &&
            (flags & _filestatSetModificationTimeNow) != 0) {
      return (
        errno: _errnoInval,
        accessTimeNanos: null,
        modificationTimeNanos: null,
      );
    }
    if ((flags & _filestatSetAccessTime) != 0 && accessTimeNanos < 0 ||
        (flags & _filestatSetModificationTime) != 0 &&
            modificationTimeNanos < 0) {
      return (
        errno: _errnoInval,
        accessTimeNanos: null,
        modificationTimeNanos: null,
      );
    }

    final now =
        ((flags & _filestatSetAccessTimeNow) != 0 ||
            (flags & _filestatSetModificationTimeNow) != 0)
        ? _clockNowNanos(_clockRealtime)
        : 0;
    return (
      errno: _errnoSuccess,
      accessTimeNanos: (flags & _filestatSetAccessTime) != 0
          ? accessTimeNanos
          : (flags & _filestatSetAccessTimeNow) != 0
          ? now
          : null,
      modificationTimeNanos: (flags & _filestatSetModificationTime) != 0
          ? modificationTimeNanos
          : (flags & _filestatSetModificationTimeNow) != 0
          ? now
          : null,
    );
  }

  void _applyResolvedFilestatTimes({
    required wasi_vfs.Preview1VirtualNodeMetadata metadata,
    required ({int errno, int? accessTimeNanos, int? modificationTimeNanos})
    update,
  }) {
    final accessTimeNanos = update.accessTimeNanos;
    final modificationTimeNanos = update.modificationTimeNanos;
    if (accessTimeNanos != null) {
      metadata.accessTimeNanos = accessTimeNanos;
    }
    if (modificationTimeNanos != null) {
      metadata.modificationTimeNanos = modificationTimeNanos;
    }
  }

  int _applyHostFileResolvedFilestatTimes({
    required String hostPath,
    wasi_vfs.Preview1VirtualNodeMetadata? metadata,
    required ({int errno, int? accessTimeNanos, int? modificationTimeNanos})
    update,
  }) {
    final hostResult = _hostSetPathTimes(
      hostPath: hostPath,
      update: update,
      noFollowSymlink: false,
    );
    switch (hostResult) {
      case _HostSetPathTimesResult.success:
        if (metadata != null) {
          _copyHostPathStatToMetadata(metadata, hostPath);
        }
        return _errnoSuccess;
      case _HostSetPathTimesResult.noEntry:
        return _errnoNoent;
      case _HostSetPathTimesResult.invalid:
        return _errnoInval;
      case _HostSetPathTimesResult.permissionDenied:
        return _errnoPerm;
      case _HostSetPathTimesResult.unsupported:
        break;
    }

    DateTime dateTimeFromNanos(int nanos) {
      return DateTime.fromMicrosecondsSinceEpoch(nanos ~/ 1000, isUtc: true);
    }

    try {
      final file = io.File(hostPath);
      final accessTimeNanos = update.accessTimeNanos;
      final modificationTimeNanos = update.modificationTimeNanos;
      if (accessTimeNanos != null) {
        file.setLastAccessedSync(dateTimeFromNanos(accessTimeNanos));
      }
      if (modificationTimeNanos != null) {
        file.setLastModifiedSync(dateTimeFromNanos(modificationTimeNanos));
      }
      if (metadata != null) {
        _copyHostPathStatToMetadata(metadata, hostPath);
      }
      return _errnoSuccess;
    } on ArgumentError {
      return _errnoInval;
    } on io.FileSystemException {
      if (io.FileSystemEntity.typeSync(hostPath, followLinks: false) ==
          io.FileSystemEntityType.notFound) {
        return _errnoNoent;
      }
      return _errnoPerm;
    }
  }

  int _applyHostPathResolvedFilestatTimes({
    required String hostPath,
    required io.FileSystemEntityType type,
    required bool noFollowSymlink,
    required ({int errno, int? accessTimeNanos, int? modificationTimeNanos})
    update,
  }) {
    if (type == io.FileSystemEntityType.file && !noFollowSymlink) {
      return _applyHostFileResolvedFilestatTimes(
        hostPath: hostPath,
        update: update,
      );
    }
    if (type != io.FileSystemEntityType.directory &&
        type != io.FileSystemEntityType.link) {
      return _errnoNotsup;
    }

    return switch (_hostSetPathTimes(
      hostPath: hostPath,
      update: update,
      noFollowSymlink: noFollowSymlink,
    )) {
      _HostSetPathTimesResult.success => _errnoSuccess,
      _HostSetPathTimesResult.noEntry => _errnoNoent,
      _HostSetPathTimesResult.invalid => _errnoInval,
      _HostSetPathTimesResult.permissionDenied => _errnoPerm,
      _HostSetPathTimesResult.unsupported => _errnoNotsup,
    };
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
    if (_vfs.isDetachedOpenDirectoryFd(dirFd)) {
      return const _ResolvedPath.error(_errnoNoent);
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
    final resolvedPath = _vfs.resolveParentSymlinkPath(guestPath.path);
    if (resolvedPath == null) {
      return const _ResolvedPath.error(_errnoNoent);
    }
    return _ResolvedPath.path(
      resolvedPath,
      hasTrailingSeparator: guestPath.hasTrailingSeparator,
    );
  }

  int _writePollEvents({
    required Uint8List bytes,
    required ByteData data,
    required int inPtr,
    required int outPtr,
    required int nsubscriptions,
    required int neventsPtr,
    required int pollStartMonotonic,
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
          pollStartMonotonic: pollStartMonotonic,
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
    required int pollStartMonotonic,
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
    if ((flags & _subscriptionClockAbstime) == 0) {
      final deadline = pollStartMonotonic + timeout;
      final remaining = deadline - nowMonotonic;
      return remaining > 0 ? remaining : 0;
    }

    final now = _clockNowNanos(clockId);
    final deadline = timeout;
    final remaining = deadline - now;
    if (clockId == _clockMonotonic) {
      return remaining > 0 ? remaining : 0;
    }
    final adjustedDeadline = nowMonotonic + remaining;
    return adjustedDeadline > nowMonotonic
        ? adjustedDeadline - nowMonotonic
        : 0;
  }

  Duration _durationFromNanos(int nanos) {
    if (nanos <= 0) {
      return Duration.zero;
    }
    return Duration(microseconds: (nanos / 1000).ceil());
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

  _MemoryView? _memoryView() {
    final memory = _boundMemory;
    if (memory == null) {
      return null;
    }
    final buffer = memory.buffer;
    return _MemoryView(Uint8List.view(buffer), ByteData.view(buffer));
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
const int _errnoIo = wasi_common.errnoIo;
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
const int _filetypeSymbolicLink = wasi_common.filetypeSymbolicLink;
const int _oflagCreat = wasi_common.oflagCreat;
const int _oflagDirectory = wasi_common.oflagDirectory;
const int _oflagExcl = wasi_common.oflagExcl;
const int _oflagTrunc = wasi_common.oflagTrunc;
const int _oflagKnownMask = wasi_common.oflagKnownMask;
const int _fdflagAppend = wasi_common.fdflagAppend;
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
const int _rightFdRead = wasi_common.rightFdRead;
const int _rightFdWrite = wasi_common.rightFdWrite;
const int _rightFdAdvise = wasi_common.rightFdAdvise;
const int _rightFdAllocate = wasi_common.rightFdAllocate;
const int _rightFdFilestatSetSize = wasi_common.rightFdFilestatSetSize;
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
      wasi_vfs.Preview1PathMutationResult.symlinkLoop => _errnoLoop,
      wasi_vfs.Preview1PathMutationResult.permissionDenied => _errnoPerm,
    };

int _errnoFromFdRightsResult(wasi_vfs.Preview1FdRightsResult result) =>
    switch (result) {
      wasi_vfs.Preview1FdRightsResult.success => _errnoSuccess,
      wasi_vfs.Preview1FdRightsResult.invalid => _errnoInval,
      wasi_vfs.Preview1FdRightsResult.badf => _errnoBadf,
      wasi_vfs.Preview1FdRightsResult.notCapable => _errnoNotcapable,
    };

int _raiseNativeProcessSignal(wasi_iface.WASIProcessSignal signal) {
  final hostSignal = _hostProcessSignalFor(signal);
  if (hostSignal == null) {
    return _errnoNosys;
  }
  try {
    return io.Process.killPid(io.pid, hostSignal) ? _errnoSuccess : _errnoInval;
  } on UnsupportedError {
    return _errnoNosys;
  } on ArgumentError {
    return _errnoInval;
  }
}

io.ProcessSignal? _hostProcessSignalFor(wasi_iface.WASIProcessSignal signal) =>
    switch (signal) {
      wasi_iface.WASIProcessSignal.none => null,
      wasi_iface.WASIProcessSignal.hup => io.ProcessSignal.sighup,
      wasi_iface.WASIProcessSignal.interrupt => io.ProcessSignal.sigint,
      wasi_iface.WASIProcessSignal.quit => io.ProcessSignal.sigquit,
      wasi_iface.WASIProcessSignal.ill => io.ProcessSignal.sigill,
      wasi_iface.WASIProcessSignal.trap => io.ProcessSignal.sigtrap,
      wasi_iface.WASIProcessSignal.abrt => io.ProcessSignal.sigabrt,
      wasi_iface.WASIProcessSignal.bus => io.ProcessSignal.sigbus,
      wasi_iface.WASIProcessSignal.fpe => io.ProcessSignal.sigfpe,
      wasi_iface.WASIProcessSignal.kill => io.ProcessSignal.sigkill,
      wasi_iface.WASIProcessSignal.usr1 => io.ProcessSignal.sigusr1,
      wasi_iface.WASIProcessSignal.segv => io.ProcessSignal.sigsegv,
      wasi_iface.WASIProcessSignal.usr2 => io.ProcessSignal.sigusr2,
      wasi_iface.WASIProcessSignal.pipe => io.ProcessSignal.sigpipe,
      wasi_iface.WASIProcessSignal.alrm => io.ProcessSignal.sigalrm,
      wasi_iface.WASIProcessSignal.term => io.ProcessSignal.sigterm,
      wasi_iface.WASIProcessSignal.chld => io.ProcessSignal.sigchld,
      wasi_iface.WASIProcessSignal.cont => io.ProcessSignal.sigcont,
      wasi_iface.WASIProcessSignal.stop => io.ProcessSignal.sigstop,
      wasi_iface.WASIProcessSignal.tstp => io.ProcessSignal.sigtstp,
      wasi_iface.WASIProcessSignal.ttin => io.ProcessSignal.sigttin,
      wasi_iface.WASIProcessSignal.ttou => io.ProcessSignal.sigttou,
      wasi_iface.WASIProcessSignal.urg => io.ProcessSignal.sigurg,
      wasi_iface.WASIProcessSignal.xcpu => io.ProcessSignal.sigxcpu,
      wasi_iface.WASIProcessSignal.xfsz => io.ProcessSignal.sigxfsz,
      wasi_iface.WASIProcessSignal.vtalrm => io.ProcessSignal.sigvtalrm,
      wasi_iface.WASIProcessSignal.prof => io.ProcessSignal.sigprof,
      wasi_iface.WASIProcessSignal.winch => io.ProcessSignal.sigwinch,
      wasi_iface.WASIProcessSignal.poll => io.ProcessSignal.sigpoll,
      wasi_iface.WASIProcessSignal.pwr => null,
      wasi_iface.WASIProcessSignal.sys => io.ProcessSignal.sigsys,
    };

Map<String, String> _buildHostPreopens(Map<String, String> preopens) {
  final hostPreopens = <String, String>{};
  for (final entry in preopens.entries) {
    final directory = io.Directory(entry.value).absolute;
    if (directory.existsSync()) {
      hostPreopens[wasi_vfs.normalizeGuestPath(entry.key)] = directory.path;
    }
  }
  return hostPreopens;
}

String _joinHostPath(String root, String relative) {
  if (relative.isEmpty) {
    return root;
  }
  var path = root;
  final separator = io.Platform.pathSeparator;
  for (final segment in relative.split('/')) {
    if (segment.isEmpty || segment == '.') {
      continue;
    }
    path = path.endsWith(separator)
        ? '$path$segment'
        : '$path$separator$segment';
  }
  return path;
}

String _joinNativeHostPath(String root, String relative) {
  if (relative.isEmpty) {
    return root;
  }
  final separator = io.Platform.pathSeparator;
  return root.endsWith(separator)
      ? '$root$relative'
      : '$root$separator$relative';
}

bool _isHostPathWithinRoot(String path, String root) {
  final normalizedPath = io.File(path).absolute.path;
  final normalizedRoot = io.Directory(root).absolute.path;
  final separator = io.Platform.pathSeparator;
  if (normalizedRoot.endsWith(separator)) {
    return normalizedPath == normalizedRoot ||
        normalizedPath.startsWith(normalizedRoot);
  }
  return normalizedPath == normalizedRoot ||
      normalizedPath.startsWith('$normalizedRoot$separator');
}

bool _isChildGuestPath(String path, String parent) {
  final normalizedPath = wasi_vfs.normalizeGuestPath(path);
  final normalizedParent = wasi_vfs.normalizeGuestPath(parent);
  if (normalizedParent == '/') {
    return normalizedPath != '/';
  }
  return normalizedPath.startsWith('$normalizedParent/');
}

bool _sameHostPath(String left, String right) =>
    io.File(left).absolute.path == io.File(right).absolute.path;

bool _hostHardLink(String existingPath, String newPath) {
  if (io.Platform.isWindows) {
    return _windowsCreateHardLink(existingPath, newPath);
  }
  return _posixCreateHardLink(existingPath, newPath);
}

_HostSetPathTimesResult _hostSetPathTimes({
  required String hostPath,
  required ({int errno, int? accessTimeNanos, int? modificationTimeNanos})
  update,
  required bool noFollowSymlink,
}) {
  if (io.Platform.isWindows) {
    return _HostSetPathTimesResult.unsupported;
  }
  return _posixSetPathTimes(
    hostPath: hostPath,
    update: update,
    noFollowSymlink: noFollowSymlink,
  );
}

_HostSetPathTimesResult _posixSetPathTimes({
  required String hostPath,
  required ({int errno, int? accessTimeNanos, int? modificationTimeNanos})
  update,
  required bool noFollowSymlink,
}) {
  final pathPointer = hostPath.toNativeUtf8();
  final times = malloc<_NativeTimespec>(2);
  try {
    _writeNativeTimespec(times, update.accessTimeNanos);
    _writeNativeTimespec(times + 1, update.modificationTimeNanos);
    final result = _posixUtimensatFunction()(
      _posixAtFdcwd,
      pathPointer,
      times,
      noFollowSymlink ? _posixAtSymlinkNoFollow : 0,
    );
    if (result == 0) {
      return _HostSetPathTimesResult.success;
    }
    if (io.FileSystemEntity.typeSync(hostPath, followLinks: false) ==
        io.FileSystemEntityType.notFound) {
      return _HostSetPathTimesResult.noEntry;
    }
    return _HostSetPathTimesResult.permissionDenied;
  } on ArgumentError {
    return _HostSetPathTimesResult.invalid;
  } on io.FileSystemException {
    return _HostSetPathTimesResult.permissionDenied;
  } catch (_) {
    return _HostSetPathTimesResult.unsupported;
  } finally {
    malloc.free(pathPointer);
    malloc.free(times);
  }
}

void _writeNativeTimespec(ffi.Pointer<_NativeTimespec> target, int? timeNanos) {
  final ref = target.ref;
  if (timeNanos == null) {
    ref.tvSec = 0;
    ref.tvNsec = _posixUtimeOmit;
    return;
  }
  ref.tvSec = timeNanos ~/ _nanosPerSecond;
  ref.tvNsec = timeNanos.remainder(_nanosPerSecond);
}

bool _posixCreateHardLink(String existingPath, String newPath) {
  final existingPathPointer = existingPath.toNativeUtf8();
  final newPathPointer = newPath.toNativeUtf8();
  try {
    try {
      return _posixLinkatFunction()(
            _posixAtFdcwd,
            existingPathPointer,
            _posixAtFdcwd,
            newPathPointer,
            0,
          ) ==
          0;
    } catch (_) {
      return _posixLinkFunction()(existingPathPointer, newPathPointer) == 0;
    }
  } finally {
    malloc.free(existingPathPointer);
    malloc.free(newPathPointer);
  }
}

bool _windowsCreateHardLink(String existingPath, String newPath) {
  final createHardLink = _windowsCreateHardLinkFunction();
  final newPathPointer = newPath.toNativeUtf16();
  final existingPathPointer = existingPath.toNativeUtf16();
  try {
    return createHardLink(newPathPointer, existingPathPointer, ffi.nullptr) !=
        0;
  } finally {
    malloc.free(newPathPointer);
    malloc.free(existingPathPointer);
  }
}

_PosixLinkDart? _cachedPosixLink;
_PosixLinkatDart? _cachedPosixLinkat;
_PosixUtimensatDart? _cachedPosixUtimensat;
_PosixLstatDart? _cachedPosixLstat;
_WindowsCreateHardLinkDart? _cachedWindowsCreateHardLink;

_PosixLinkDart _posixLinkFunction() => _cachedPosixLink ??= _openPosixCLibrary()
    .lookupFunction<_PosixLinkNative, _PosixLinkDart>('link');

_PosixLinkatDart _posixLinkatFunction() =>
    _cachedPosixLinkat ??= _openPosixCLibrary()
        .lookupFunction<_PosixLinkatNative, _PosixLinkatDart>('linkat');

_PosixUtimensatDart _posixUtimensatFunction() =>
    _cachedPosixUtimensat ??= _openPosixCLibrary()
        .lookupFunction<_PosixUtimensatNative, _PosixUtimensatDart>(
          'utimensat',
        );

_PosixLstatDart _posixLstatFunction() =>
    _cachedPosixLstat ??= _openPosixCLibrary()
        .lookupFunction<_PosixLstatNative, _PosixLstatDart>('lstat');

_WindowsCreateHardLinkDart _windowsCreateHardLinkFunction() =>
    _cachedWindowsCreateHardLink ??= ffi.DynamicLibrary.open('kernel32.dll')
        .lookupFunction<
          _WindowsCreateHardLinkNative,
          _WindowsCreateHardLinkDart
        >('CreateHardLinkW');

ffi.DynamicLibrary _openPosixCLibrary() {
  if (io.Platform.isLinux) {
    return ffi.DynamicLibrary.open('libc.so.6');
  }
  if (io.Platform.isAndroid) {
    return ffi.DynamicLibrary.open('libc.so');
  }
  return ffi.DynamicLibrary.process();
}

typedef _PosixLinkNative =
    ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);
typedef _PosixLinkDart = int Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);

typedef _PosixLinkatNative =
    ffi.Int32 Function(
      ffi.Int32,
      ffi.Pointer<Utf8>,
      ffi.Int32,
      ffi.Pointer<Utf8>,
      ffi.Int32,
    );
typedef _PosixLinkatDart =
    int Function(int, ffi.Pointer<Utf8>, int, ffi.Pointer<Utf8>, int);

typedef _PosixUtimensatNative =
    ffi.Int32 Function(
      ffi.Int32,
      ffi.Pointer<Utf8>,
      ffi.Pointer<_NativeTimespec>,
      ffi.Int32,
    );
typedef _PosixUtimensatDart =
    int Function(int, ffi.Pointer<Utf8>, ffi.Pointer<_NativeTimespec>, int);

typedef _PosixLstatNative =
    ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<ffi.Void>);
typedef _PosixLstatDart =
    int Function(ffi.Pointer<Utf8>, ffi.Pointer<ffi.Void>);

typedef _WindowsCreateHardLinkNative =
    ffi.Int32 Function(
      ffi.Pointer<Utf16>,
      ffi.Pointer<Utf16>,
      ffi.Pointer<ffi.Void>,
    );
typedef _WindowsCreateHardLinkDart =
    int Function(ffi.Pointer<Utf16>, ffi.Pointer<Utf16>, ffi.Pointer<ffi.Void>);

final class _NativeTimespec extends ffi.Struct {
  @ffi.Int64()
  external int tvSec;

  @ffi.Int64()
  external int tvNsec;
}

enum _HostSetPathTimesResult {
  success,
  noEntry,
  invalid,
  permissionDenied,
  unsupported,
}

wasi_vfs.Preview1VirtualNodeMetadata _metadataFromHostStat(io.FileStat stat) {
  final metadata = wasi_vfs.Preview1VirtualNodeMetadata();
  final accessed = stat.accessed.microsecondsSinceEpoch * 1000;
  final modified = stat.modified.microsecondsSinceEpoch * 1000;
  if (accessed > 0) {
    metadata.accessTimeNanos = accessed;
  }
  if (modified > 0) {
    metadata.modificationTimeNanos = modified;
  }
  return metadata;
}

wasi_vfs.Preview1VirtualNodeMetadata _metadataFromHostPath(String hostPath) {
  final info = _hostLstatInfo(hostPath);
  if (info == null) {
    return _metadataFromHostStat(io.File(hostPath).statSync());
  }
  return _metadataFromHostStatInfo(info);
}

wasi_vfs.Preview1VirtualNodeMetadata _metadataFromHostLstat(String hostPath) {
  final info = _hostLstatInfo(hostPath);
  return info == null
      ? wasi_vfs.Preview1VirtualNodeMetadata()
      : _metadataFromHostStatInfo(info);
}

wasi_vfs.Preview1VirtualNodeMetadata _metadataFromHostStatInfo(
  _HostLstatInfo info,
) {
  final metadata = wasi_vfs.Preview1VirtualNodeMetadata(inode: info.inode);
  _copyHostStatInfoToMetadata(metadata, info);
  return metadata;
}

void _copyHostPathStatToMetadata(
  wasi_vfs.Preview1VirtualNodeMetadata metadata,
  String hostPath, {
  bool requireSameInode = false,
}) {
  final info = _hostLstatInfo(hostPath);
  if (info == null) {
    return;
  }
  if (requireSameInode && info.inode != metadata.inode) {
    return;
  }
  _copyHostStatInfoToMetadata(metadata, info);
}

void _copyHostStatInfoToMetadata(
  wasi_vfs.Preview1VirtualNodeMetadata metadata,
  _HostLstatInfo info,
) {
  if (info.linkCount > 0) {
    metadata.linkCount = info.linkCount;
  }
  if (info.accessTimeNanos > 0) {
    metadata.accessTimeNanos = info.accessTimeNanos;
  }
  if (info.modificationTimeNanos > 0) {
    metadata.modificationTimeNanos = info.modificationTimeNanos;
  }
}

int _hostPathInode(String hostPath) =>
    _hostLstatInfo(hostPath)?.inode ??
    wasi_vfs.Preview1VirtualNodeMetadata().inode;

_HostLstatInfo? _hostLstatInfo(String hostPath) {
  if (io.Platform.isWindows) {
    return null;
  }
  final pathPointer = hostPath.toNativeUtf8();
  final statBuffer = malloc<ffi.Uint8>(_hostStatBufferSize);
  try {
    if (_posixLstatFunction()(pathPointer, statBuffer.cast<ffi.Void>()) != 0) {
      return null;
    }
    return (
      inode: _readHostStatInode(statBuffer),
      linkCount: _readHostStatLinkCount(statBuffer),
      accessTimeNanos: _readHostStatTimespecNanos(
        statBuffer,
        _hostStatAccessTimeOffset,
      ),
      modificationTimeNanos: _readHostStatTimespecNanos(
        statBuffer,
        _hostStatModificationTimeOffset,
      ),
    );
  } catch (_) {
    return null;
  } finally {
    malloc.free(pathPointer);
    malloc.free(statBuffer);
  }
}

int _readHostStatInode(ffi.Pointer<ffi.Uint8> statBuffer) {
  return (statBuffer + _hostStatInodeOffset).cast<ffi.Uint64>().value;
}

int _readHostStatLinkCount(ffi.Pointer<ffi.Uint8> statBuffer) {
  if (io.Platform.isMacOS || io.Platform.isIOS) {
    return (statBuffer + _hostStatLinkCountOffset).cast<ffi.Uint16>().value;
  }
  return (statBuffer + _hostStatLinkCountOffset).cast<ffi.Uint64>().value;
}

int _readHostStatTimespecNanos(ffi.Pointer<ffi.Uint8> statBuffer, int offset) {
  final seconds = (statBuffer + offset).cast<ffi.Int64>().value;
  final nanos = (statBuffer + offset + 8).cast<ffi.Int64>().value;
  return seconds * _nanosPerSecond + nanos;
}

int get _posixAtFdcwd => io.Platform.isMacOS || io.Platform.isIOS ? -2 : -100;

int get _posixAtSymlinkNoFollow =>
    io.Platform.isMacOS || io.Platform.isIOS ? 0x20 : 0x100;

int get _posixUtimeOmit =>
    io.Platform.isMacOS || io.Platform.isIOS ? -2 : 1073741822;

int get _hostStatAccessTimeOffset =>
    io.Platform.isMacOS || io.Platform.isIOS ? 32 : 72;

int get _hostStatModificationTimeOffset =>
    io.Platform.isMacOS || io.Platform.isIOS ? 48 : 88;

const int _hostStatInodeOffset = 8;
int get _hostStatLinkCountOffset =>
    io.Platform.isMacOS || io.Platform.isIOS ? 6 : 16;
const int _nanosPerSecond = 1000000000;
const int _hostStatBufferSize = 256;

typedef _HostLstatInfo = ({
  int inode,
  int linkCount,
  int accessTimeNanos,
  int modificationTimeNanos,
});

final class _Preview1NativeHostOpenFile implements wasi_vfs.Preview1OpenFile {
  _Preview1NativeHostOpenFile(
    this._file, {
    required this.hostPath,
    required this.metadata,
    required this.rights,
    required this.descriptorFlags,
  });

  final io.RandomAccessFile _file;
  final String hostPath;

  @override
  final wasi_vfs.Preview1VirtualNodeMetadata metadata;

  void refreshMetadata() {
    _copyHostPathStatToMetadata(metadata, hostPath, requireSameInode: true);
  }

  @override
  final wasi_vfs.Preview1DescriptorRights rights;

  @override
  int descriptorFlags;

  @override
  int offset = 0;

  @override
  int get length => _file.lengthSync();

  @override
  wasi_vfs.Preview1OpenFileIoResult readInto(
    Uint8List target,
    int start,
    int length,
  ) {
    final count = readAtInto(target, start, length, offset);
    offset += count.count;
    return count;
  }

  @override
  wasi_vfs.Preview1OpenFileIoResult readAtInto(
    Uint8List target,
    int start,
    int length,
    int fileOffset,
  ) {
    if (length <= 0 || fileOffset < 0 || start < 0 || start >= target.length) {
      return (errno: _errnoSuccess, count: 0);
    }
    final end = math.min(target.length, start + length);
    int? originalPosition;
    try {
      originalPosition = _file.positionSync();
      _file.setPositionSync(fileOffset);
      return (
        errno: _errnoSuccess,
        count: _file.readIntoSync(target, start, end),
      );
    } on io.FileSystemException {
      return (errno: _errnoIo, count: 0);
    } finally {
      if (originalPosition != null) {
        try {
          _file.setPositionSync(originalPosition);
        } on io.FileSystemException {
          // Preserve the WASI syscall result from the actual read path.
        }
      }
    }
  }

  @override
  wasi_vfs.Preview1OpenFileIoResult writeFrom(
    Uint8List source,
    int start,
    int length,
  ) {
    final fileOffset = (descriptorFlags & _fdflagAppend) == 0
        ? offset
        : this.length;
    final written = writeAtFrom(source, start, length, fileOffset);
    offset = fileOffset + written.count;
    return written;
  }

  @override
  wasi_vfs.Preview1OpenFileIoResult writeAtFrom(
    Uint8List source,
    int start,
    int length,
    int fileOffset,
  ) {
    if (length <= 0 || fileOffset < 0 || start < 0 || start >= source.length) {
      return (errno: _errnoSuccess, count: 0);
    }
    final end = math.min(source.length, start + length);
    if (end <= start) {
      return (errno: _errnoSuccess, count: 0);
    }
    int? originalPosition;
    try {
      originalPosition = _file.positionSync();
      _file.setPositionSync(fileOffset);
      _file.writeFromSync(source, start, end);
      return (errno: _errnoSuccess, count: end - start);
    } on io.FileSystemException {
      return (errno: _errnoIo, count: 0);
    } finally {
      if (originalPosition != null) {
        try {
          _file.setPositionSync(originalPosition);
        } on io.FileSystemException {
          // Preserve the WASI syscall result from the actual write path.
        }
      }
    }
  }

  @override
  int setLength(int length) {
    if (length < 0) {
      return _errnoInval;
    }
    try {
      _file.truncateSync(length);
      return _errnoSuccess;
    } on io.FileSystemException {
      return _errnoIo;
    }
  }

  @override
  int allocate(int offset, int length) {
    if (offset < 0 || length < 0 || offset + length < offset) {
      return _errnoInval;
    }
    final requiredLength = offset + length;
    final currentLength = this.length;
    if (requiredLength > currentLength) {
      return setLength(requiredLength);
    }
    return _errnoSuccess;
  }

  @override
  int dataSync() => _flush();

  @override
  int sync() => _flush();

  int _flush() {
    try {
      _file.flushSync();
      return _errnoSuccess;
    } on io.FileSystemException {
      return _errnoIo;
    }
  }

  @override
  void close() {
    try {
      _file.closeSync();
    } on io.FileSystemException {
      // WASI close is idempotent at this boundary.
    }
  }
}

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

int _getUint64(ByteData data, int offset) {
  final low = data.getUint32(offset, Endian.little);
  final high = data.getUint32(offset + 4, Endian.little);
  return (high << 32) | low;
}

bool _isTruthyEnv(String? value) {
  if (value == null) {
    return false;
  }
  final normalized = value.trim().toLowerCase();
  return normalized == '1' || normalized == 'true' || normalized == 'yes';
}

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
