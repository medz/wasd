import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'imports.dart';
import 'instance.dart';
import 'hash.dart';
import 'int64.dart';
import 'memory.dart';
import 'wasi_filesystem.dart';
import 'wasi_fs_auto.dart' as auto_fs;
import 'wasi_socket_auto.dart' as auto_socket;
import 'wasi_socket_transport.dart';

typedef WasiReadSource = Uint8List Function(int maxBytes);
typedef WasiWriteSink = void Function(Uint8List bytes);

enum WasiProcRaiseMode { enosys, success, trap }

enum _FdKind { stdin, stdout, stderr, directory, file }

final class _FdEntry {
  _FdEntry.stdin()
    : kind = _FdKind.stdin,
      directoryPath = null,
      file = null,
      rightsBase =
          WasiPreview1._rightFdRead |
          WasiPreview1._rightFdFdstatSetFlags |
          WasiPreview1._rightFdFileStatGet,
      rightsInheriting = 0,
      fdFlags = 0;

  _FdEntry.stdout()
    : kind = _FdKind.stdout,
      directoryPath = null,
      file = null,
      rightsBase =
          WasiPreview1._rightFdWrite |
          WasiPreview1._rightFdFdstatSetFlags |
          WasiPreview1._rightFdFileStatGet,
      rightsInheriting = 0,
      fdFlags = 0;

  _FdEntry.stderr()
    : kind = _FdKind.stderr,
      directoryPath = null,
      file = null,
      rightsBase =
          WasiPreview1._rightFdWrite |
          WasiPreview1._rightFdFdstatSetFlags |
          WasiPreview1._rightFdFileStatGet,
      rightsInheriting = 0,
      fdFlags = 0;

  _FdEntry.directory(this.directoryPath)
    : kind = _FdKind.directory,
      file = null,
      rightsBase =
          WasiPreview1._rightPathOpen |
          WasiPreview1._rightPathCreateDirectory |
          WasiPreview1._rightPathLinkSource |
          WasiPreview1._rightPathLinkTarget |
          WasiPreview1._rightPathRemoveDirectory |
          WasiPreview1._rightPathFileStatGet |
          WasiPreview1._rightPathFileStatSetTimes |
          WasiPreview1._rightPathRenameSource |
          WasiPreview1._rightPathRenameTarget |
          WasiPreview1._rightPathSymlink |
          WasiPreview1._rightPathReadlink |
          WasiPreview1._rightPathUnlinkFile,
      rightsInheriting =
          WasiPreview1._rightFdRead |
          WasiPreview1._rightFdWrite |
          WasiPreview1._rightFdSeek |
          WasiPreview1._rightFdTell |
          WasiPreview1._rightFdFdstatSetFlags |
          WasiPreview1._rightFdFileStatSetTimes |
          WasiPreview1._rightFdFileStatGet,
      fdFlags = 0;

  _FdEntry.file(
    this.file, {
    required this.rightsBase,
    required this.rightsInheriting,
    this.fdFlags = 0,
  }) : kind = _FdKind.file,
       directoryPath = null;

  final _FdKind kind;
  final String? directoryPath;
  final WasiFileDescriptor? file;
  int rightsBase;
  int rightsInheriting;
  int fdFlags;
}

final class _ResolvedPath {
  const _ResolvedPath.path(this.path) : errno = 0;

  const _ResolvedPath.error(this.errno) : path = null;

  final String? path;
  final int errno;
}

final class _PollSubscription {
  const _PollSubscription.clock({
    required this.userdata,
    required this.clockId,
    required this.clockFlags,
    required this.clockPrecisionNs,
    required this.clockDeadlineNs,
  }) : eventType = WasiPreview1._eventTypeClock,
       fd = null;

  const _PollSubscription.fdRead({required this.userdata, required this.fd})
    : eventType = WasiPreview1._eventTypeFdRead,
      clockId = null,
      clockFlags = null,
      clockPrecisionNs = null,
      clockDeadlineNs = null;

  const _PollSubscription.fdWrite({required this.userdata, required this.fd})
    : eventType = WasiPreview1._eventTypeFdWrite,
      clockId = null,
      clockFlags = null,
      clockPrecisionNs = null,
      clockDeadlineNs = null;

  final BigInt userdata;
  final int eventType;
  final int? fd;
  final int? clockId;
  final int? clockFlags;
  final BigInt? clockPrecisionNs;
  final BigInt? clockDeadlineNs;
}

final class _PollReadyEvent {
  const _PollReadyEvent({
    required this.userdata,
    required this.eventType,
    required this.errno,
    this.nbytes = 0,
    this.flags = 0,
  });

  final BigInt userdata;
  final int eventType;
  final int errno;
  final int nbytes;
  final int flags;
}

final class WasiPreview1 {
  WasiPreview1({
    List<String> args = const [],
    Map<String, String> environment = const {},
    List<int> stdin = const [],
    this.stdinSource,
    this.procRaiseMode = WasiProcRaiseMode.enosys,
    this.allowNonStandardWasi = false,
    WasiSocketTransport? socketTransport,
    Map<int, Object> preopenedSockets = const {},
    WasiWriteSink? stdoutSink,
    WasiWriteSink? stderrSink,
    WasiFileSystem? fileSystem,
    bool preferHostIo = true,
    String? ioRootPath,
    Map<int, String> preopenedDirectories = const {3: '/'},
    BigInt Function()? nowRealtimeNs,
    BigInt Function()? nowMonotonicNs,
    void Function(Duration duration)? sleep,
  }) : _args = List.unmodifiable(args),
       _environment = Map.unmodifiable(environment),
       _stdinBuffer = Uint8List.fromList(stdin),
       _stdoutSink = stdoutSink ?? _discardOutput,
       _stderrSink = stderrSink ?? _discardOutput,
       _fileSystem =
           fileSystem ??
           (preferHostIo
               ? auto_fs.createAutoWasiFileSystem(ioRootPath: ioRootPath)
               : WasiInMemoryFileSystem()),
       _socketTransport =
           socketTransport ??
           (preopenedSockets.isNotEmpty
               ? auto_socket.createAutoWasiSocketTransport(
                   preopenedSockets: preopenedSockets,
                 )
               : null),
       _preopenedDirectories = Map.unmodifiable(
         preopenedDirectories.map(
           (fd, path) =>
               MapEntry(fd, WasiInMemoryFileSystem.normalizeAbsolutePath(path)),
         ),
       ) {
    _encodedArgs = _encodeUtf8Values(_args);
    _encodedArgsTotalSize = _cstringVectorTotalSize(_encodedArgs);
    _encodedEnvironmentEntries = _encodeEnvironmentValues(_environment);
    _encodedEnvironmentTotalSize = _cstringVectorTotalSize(
      _encodedEnvironmentEntries,
    );
    _nowRealtimeNs = nowRealtimeNs ?? _defaultNowRealtimeNs;
    _nowMonotonicNs = nowMonotonicNs ?? _defaultNowMonotonicNs;
    _sleep = sleep ?? _defaultSleep;
    if (!allowNonStandardWasi && procRaiseMode != WasiProcRaiseMode.enosys) {
      throw ArgumentError.value(
        procRaiseMode,
        'procRaiseMode',
        'Non-standard proc_raise modes require allowNonStandardWasi: true.',
      );
    }
    _resetFdTable();
  }

  final List<String> _args;
  final Map<String, String> _environment;
  final Uint8List _stdinBuffer;
  final WasiReadSource? stdinSource;
  final WasiProcRaiseMode procRaiseMode;
  final bool allowNonStandardWasi;
  final WasiWriteSink _stdoutSink;
  final WasiWriteSink _stderrSink;
  final WasiFileSystem _fileSystem;
  final WasiSocketTransport? _socketTransport;
  final Map<int, String> _preopenedDirectories;
  late final List<Uint8List> _encodedArgs;
  late final int _encodedArgsTotalSize;
  late final List<Uint8List> _encodedEnvironmentEntries;
  late final int _encodedEnvironmentTotalSize;

  WasmMemory? _memory;
  final Stopwatch _monotonicClock = Stopwatch()..start();
  late final BigInt Function() _nowRealtimeNs;
  late final BigInt Function() _nowMonotonicNs;
  late final void Function(Duration duration) _sleep;
  final Random _random = _createRandom();
  int _stdinOffset = 0;
  final Map<int, _FdEntry> _fdTable = <int, _FdEntry>{};
  late int _nextDynamicFd;

  WasiFileSystem get fileSystem => _fileSystem;
  bool get hostIoSupported => auto_fs.autoHostIoSupported;
  bool get usingHostIo =>
      auto_fs.autoHostIoSupported && _fileSystem is! WasiInMemoryFileSystem;
  bool get hostSocketSupported => auto_socket.autoHostSocketSupported;

  WasmImports get imports => WasmImports(
    functions: {
      WasmImports.key('wasi_snapshot_preview1', 'fd_write'): _fdWrite,
      WasmImports.key('wasi_snapshot_preview1', 'fd_read'): _fdRead,
      WasmImports.key('wasi_snapshot_preview1', 'fd_pread'): _fdPread,
      WasmImports.key('wasi_snapshot_preview1', 'fd_pwrite'): _fdPwrite,
      WasmImports.key('wasi_snapshot_preview1', 'fd_seek'): _fdSeek,
      WasmImports.key('wasi_snapshot_preview1', 'fd_tell'): _fdTell,
      WasmImports.key('wasi_snapshot_preview1', 'fd_advise'): _fdAdvise,
      WasmImports.key('wasi_snapshot_preview1', 'fd_allocate'): _fdAllocate,
      WasmImports.key('wasi_snapshot_preview1', 'fd_datasync'): _fdDatasync,
      WasmImports.key('wasi_snapshot_preview1', 'fd_sync'): _fdSync,
      WasmImports.key('wasi_snapshot_preview1', 'fd_fdstat_get'): _fdFdstatGet,
      WasmImports.key('wasi_snapshot_preview1', 'fd_fdstat_set_flags'):
          _fdFdstatSetFlags,
      WasmImports.key('wasi_snapshot_preview1', 'fd_fdstat_set_rights'):
          _fdFdstatSetRights,
      WasmImports.key('wasi_snapshot_preview1', 'fd_filestat_get'):
          _fdFilestatGet,
      WasmImports.key('wasi_snapshot_preview1', 'fd_filestat_set_size'):
          _fdFilestatSetSize,
      WasmImports.key('wasi_snapshot_preview1', 'fd_filestat_set_times'):
          _fdFilestatSetTimes,
      WasmImports.key('wasi_snapshot_preview1', 'fd_close'): _fdClose,
      WasmImports.key('wasi_snapshot_preview1', 'fd_prestat_get'):
          _fdPrestatGet,
      WasmImports.key('wasi_snapshot_preview1', 'fd_prestat_dir_name'):
          _fdPrestatDirName,
      WasmImports.key('wasi_snapshot_preview1', 'fd_readdir'): _fdReaddir,
      WasmImports.key('wasi_snapshot_preview1', 'fd_renumber'): _fdRenumber,
      WasmImports.key('wasi_snapshot_preview1', 'path_open'): _pathOpen,
      WasmImports.key('wasi_snapshot_preview1', 'path_filestat_get'):
          _pathFilestatGet,
      WasmImports.key('wasi_snapshot_preview1', 'path_filestat_set_times'):
          _pathFilestatSetTimes,
      WasmImports.key('wasi_snapshot_preview1', 'path_link'): _pathLink,
      WasmImports.key('wasi_snapshot_preview1', 'path_symlink'): _pathSymlink,
      WasmImports.key('wasi_snapshot_preview1', 'path_readlink'): _pathReadlink,
      WasmImports.key('wasi_snapshot_preview1', 'path_create_directory'):
          _pathCreateDirectory,
      WasmImports.key('wasi_snapshot_preview1', 'path_remove_directory'):
          _pathRemoveDirectory,
      WasmImports.key('wasi_snapshot_preview1', 'path_unlink_file'):
          _pathUnlinkFile,
      WasmImports.key('wasi_snapshot_preview1', 'path_rename'): _pathRename,
      WasmImports.key('wasi_snapshot_preview1', 'args_sizes_get'):
          _argsSizesGet,
      WasmImports.key('wasi_snapshot_preview1', 'args_get'): _argsGet,
      WasmImports.key('wasi_snapshot_preview1', 'environ_sizes_get'):
          _environSizesGet,
      WasmImports.key('wasi_snapshot_preview1', 'environ_get'): _environGet,
      WasmImports.key('wasi_snapshot_preview1', 'clock_time_get'):
          _clockTimeGet,
      WasmImports.key('wasi_snapshot_preview1', 'clock_res_get'): _clockResGet,
      WasmImports.key('wasi_snapshot_preview1', 'random_get'): _randomGet,
      WasmImports.key('wasi_snapshot_preview1', 'poll_oneoff'): _pollOneoff,
      WasmImports.key('wasi_snapshot_preview1', 'sched_yield'): _schedYield,
      WasmImports.key('wasi_snapshot_preview1', 'proc_raise'): _procRaise,
      WasmImports.key('wasi_snapshot_preview1', 'proc_exit'): _procExit,
      WasmImports.key('wasi_snapshot_preview1', 'sock_accept'): _sockAccept,
      WasmImports.key('wasi_snapshot_preview1', 'sock_recv'): _sockRecv,
      WasmImports.key('wasi_snapshot_preview1', 'sock_send'): _sockSend,
      WasmImports.key('wasi_snapshot_preview1', 'sock_shutdown'): _sockShutdown,
    },
  );

  void bindMemory(WasmMemory memory) {
    _memory = memory;
  }

  void bindInstance(
    WasmInstance instance, {
    String memoryExportName = 'memory',
  }) {
    bindMemory(instance.exportedMemory(memoryExportName));
  }

  Object? _fdWrite(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    final iovs = _asI32(args, 1, 'iovs');
    final iovsLen = _asI32(args, 2, 'iovs_len');
    final nwrittenPtr = _asI32(args, 3, 'nwritten');
    if (iovsLen < 0) {
      return _errnoInval;
    }

    final memory = _requireMemory();
    final output = BytesBuilder(copy: false);
    var total = 0;

    try {
      for (var i = 0; i < iovsLen; i++) {
        final iovBase = iovs + (i * 8);
        final ptr = memory.loadI32(iovBase);
        final len = memory.loadI32(iovBase + 4);
        if (len < 0) {
          return _errnoInval;
        }
        output.add(memory.readBytes(ptr, len));
        total += len;
      }
    } on RangeError {
      return _errnoFault;
    }

    final bytes = Uint8List.fromList(output.takeBytes());
    final target = _fdTable[fd];
    if (target == null) {
      return _errnoBadf;
    }

    try {
      switch (target.kind) {
        case _FdKind.stdout:
          _stdoutSink(bytes);
        case _FdKind.stderr:
          _stderrSink(bytes);
        case _FdKind.file:
          if ((target.rightsBase & _rightFdWrite) == 0) {
            return _errnoNotcapable;
          }
          if ((target.fdFlags & _fdflagAppend) != 0) {
            target.file!.seek(0, _whenceEnd);
          }
          target.file!.write(bytes);
        case _FdKind.stdin:
        case _FdKind.directory:
          return _errnoBadf;
      }
      memory.storeI32(nwrittenPtr, total);
    } on WasiFsException catch (error) {
      return _fsErrno(error.error);
    } on RangeError {
      return _errnoFault;
    }

    return _errnoSuccess;
  }

  Object? _fdRead(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    final iovs = _asI32(args, 1, 'iovs');
    final iovsLen = _asI32(args, 2, 'iovs_len');
    final nreadPtr = _asI32(args, 3, 'nread');
    if (iovsLen < 0) {
      return _errnoInval;
    }

    final target = _fdTable[fd];
    if (target == null) {
      return _errnoBadf;
    }

    final memory = _requireMemory();
    var requestedBytes = 0;
    try {
      for (var i = 0; i < iovsLen; i++) {
        final iovBase = iovs + (i * 8);
        final len = memory.loadI32(iovBase + 4);
        if (len < 0) {
          return _errnoInval;
        }
        requestedBytes += len;
      }
    } on RangeError {
      return _errnoFault;
    }

    Uint8List data;
    try {
      switch (target.kind) {
        case _FdKind.stdin:
          data = _readInput(requestedBytes);
        case _FdKind.file:
          if ((target.rightsBase & _rightFdRead) == 0) {
            return _errnoNotcapable;
          }
          data = target.file!.read(requestedBytes);
        case _FdKind.stdout:
        case _FdKind.stderr:
        case _FdKind.directory:
          return _errnoBadf;
      }
    } on WasiFsException catch (error) {
      return _fsErrno(error.error);
    }

    var copied = 0;
    var cursor = 0;
    try {
      for (var i = 0; i < iovsLen && cursor < data.length; i++) {
        final iovBase = iovs + (i * 8);
        final ptr = memory.loadI32(iovBase);
        final len = memory.loadI32(iovBase + 4);
        final chunkLen = (data.length - cursor) < len
            ? (data.length - cursor)
            : len;
        if (chunkLen <= 0) {
          continue;
        }
        memory.writeBytes(
          ptr,
          Uint8List.sublistView(data, cursor, cursor + chunkLen),
        );
        cursor += chunkLen;
        copied += chunkLen;
      }
      memory.storeI32(nreadPtr, copied);
    } on RangeError {
      return _errnoFault;
    }

    return _errnoSuccess;
  }

  Object? _fdPread(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    final iovs = _asI32(args, 1, 'iovs');
    final iovsLen = _asI32(args, 2, 'iovs_len');
    final offset = _asI64(args, 3, 'offset');
    final nreadPtr = _asI32(args, 4, 'nread');
    if (iovsLen < 0 || offset < 0) {
      return _errnoInval;
    }

    final entry = _fdTable[fd];
    if (entry == null) {
      return _errnoBadf;
    }
    if (entry.kind == _FdKind.stdin ||
        entry.kind == _FdKind.stdout ||
        entry.kind == _FdKind.stderr) {
      return _errnoSpipe;
    }
    if (entry.kind == _FdKind.directory) {
      return _errnoBadf;
    }
    if ((entry.rightsBase & _rightFdRead) == 0) {
      return _errnoNotcapable;
    }

    final memory = _requireMemory();
    var requestedBytes = 0;
    try {
      for (var i = 0; i < iovsLen; i++) {
        final iovBase = iovs + (i * 8);
        final len = memory.loadI32(iovBase + 4);
        if (len < 0) {
          return _errnoInval;
        }
        requestedBytes += len;
      }
    } on RangeError {
      return _errnoFault;
    }

    Uint8List data;
    try {
      final originalOffset = entry.file!.tell();
      entry.file!.seek(offset, _whenceSet);
      data = entry.file!.read(requestedBytes);
      entry.file!.seek(originalOffset, _whenceSet);
    } on WasiFsException catch (error) {
      return _fsErrno(error.error);
    }

    var copied = 0;
    var cursor = 0;
    try {
      for (var i = 0; i < iovsLen && cursor < data.length; i++) {
        final iovBase = iovs + (i * 8);
        final ptr = memory.loadI32(iovBase);
        final len = memory.loadI32(iovBase + 4);
        final chunkLen = (data.length - cursor) < len
            ? (data.length - cursor)
            : len;
        if (chunkLen <= 0) {
          continue;
        }
        memory.writeBytes(
          ptr,
          Uint8List.sublistView(data, cursor, cursor + chunkLen),
        );
        cursor += chunkLen;
        copied += chunkLen;
      }
      memory.storeI32(nreadPtr, copied);
      return _errnoSuccess;
    } on RangeError {
      return _errnoFault;
    }
  }

  Object? _fdPwrite(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    final iovs = _asI32(args, 1, 'iovs');
    final iovsLen = _asI32(args, 2, 'iovs_len');
    final offset = _asI64(args, 3, 'offset');
    final nwrittenPtr = _asI32(args, 4, 'nwritten');
    if (iovsLen < 0 || offset < 0) {
      return _errnoInval;
    }

    final entry = _fdTable[fd];
    if (entry == null) {
      return _errnoBadf;
    }
    if (entry.kind == _FdKind.stdin ||
        entry.kind == _FdKind.stdout ||
        entry.kind == _FdKind.stderr) {
      return _errnoSpipe;
    }
    if (entry.kind == _FdKind.directory) {
      return _errnoBadf;
    }
    if ((entry.rightsBase & _rightFdWrite) == 0) {
      return _errnoNotcapable;
    }

    final memory = _requireMemory();
    final output = BytesBuilder(copy: false);
    var total = 0;
    try {
      for (var i = 0; i < iovsLen; i++) {
        final iovBase = iovs + (i * 8);
        final ptr = memory.loadI32(iovBase);
        final len = memory.loadI32(iovBase + 4);
        if (len < 0) {
          return _errnoInval;
        }
        output.add(memory.readBytes(ptr, len));
        total += len;
      }
    } on RangeError {
      return _errnoFault;
    }
    final bytes = Uint8List.fromList(output.takeBytes());

    try {
      final originalOffset = entry.file!.tell();
      entry.file!.seek(offset, _whenceSet);
      entry.file!.write(bytes);
      entry.file!.seek(originalOffset, _whenceSet);
      memory.storeI32(nwrittenPtr, total);
      return _errnoSuccess;
    } on WasiFsException catch (error) {
      return _fsErrno(error.error);
    } on RangeError {
      return _errnoFault;
    }
  }

  Object? _fdAdvise(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    _asI64(args, 1, 'offset');
    _asI64(args, 2, 'len');
    _asI32(args, 3, 'advice');

    final entry = _fdTable[fd];
    if (entry == null) {
      return _errnoBadf;
    }
    if (entry.kind != _FdKind.file) {
      return _errnoBadf;
    }
    return _errnoSuccess;
  }

  Object? _fdAllocate(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    final offset = _asI64(args, 1, 'offset');
    final len = _asI64(args, 2, 'len');
    if (offset < 0 || len < 0) {
      return _errnoInval;
    }

    final entry = _fdTable[fd];
    if (entry == null) {
      return _errnoBadf;
    }
    if (entry.kind != _FdKind.file) {
      return _errnoBadf;
    }
    if ((entry.rightsBase & _rightFdWrite) == 0) {
      return _errnoNotcapable;
    }

    try {
      final requiredSize = offset + len;
      if (entry.file!.size < requiredSize) {
        entry.file!.truncate(requiredSize);
      }
      return _errnoSuccess;
    } on WasiFsException catch (error) {
      return _fsErrno(error.error);
    }
  }

  Object? _fdClose(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    final entry = _fdTable[fd];
    if (entry == null) {
      final closeSocket = _socketTransport?.close;
      if (closeSocket != null) {
        return closeSocket(fd: fd);
      }
      return _errnoBadf;
    }

    if (fd == 0 || fd == 1 || fd == 2) {
      return _errnoSuccess;
    }

    switch (entry.kind) {
      case _FdKind.file:
        entry.file!.close();
        _fdTable.remove(fd);
      case _FdKind.directory:
        if (_preopenedDirectories.containsKey(fd)) {
          return _errnoSuccess;
        }
        _fdTable.remove(fd);
      case _FdKind.stdin:
      case _FdKind.stdout:
      case _FdKind.stderr:
        return _errnoSuccess;
    }

    return _errnoSuccess;
  }

  Object? _fdDatasync(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    final entry = _fdTable[fd];
    if (entry == null) {
      return _errnoBadf;
    }
    if (entry.kind != _FdKind.file) {
      return _errnoBadf;
    }
    if ((entry.rightsBase & _rightFdWrite) == 0) {
      return _errnoNotcapable;
    }
    try {
      entry.file!.flush();
      return _errnoSuccess;
    } on WasiFsException catch (error) {
      return _fsErrno(error.error);
    }
  }

  Object? _fdSync(List<Object?> args) {
    return _fdDatasync(args);
  }

  Object? _fdSeek(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    final offset = _asI64(args, 1, 'offset');
    final whence = _asI32(args, 2, 'whence');
    final newOffsetPtr = _asI32(args, 3, 'new_offset_ptr');

    final entry = _fdTable[fd];
    if (entry == null) {
      return _errnoBadf;
    }
    if (entry.kind == _FdKind.stdin ||
        entry.kind == _FdKind.stdout ||
        entry.kind == _FdKind.stderr) {
      return _errnoSpipe;
    }
    if (entry.kind == _FdKind.directory) {
      return _errnoInval;
    }
    if ((entry.rightsBase & _rightFdSeek) == 0) {
      return _errnoNotcapable;
    }

    final memory = _requireMemory();
    try {
      final newOffset = entry.file!.seek(offset, whence);
      memory.storeI64(newOffsetPtr, newOffset);
      return _errnoSuccess;
    } on WasiFsException catch (error) {
      return _fsErrno(error.error);
    } on RangeError {
      return _errnoFault;
    }
  }

  Object? _fdTell(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    final offsetPtr = _asI32(args, 1, 'offset_ptr');

    final entry = _fdTable[fd];
    if (entry == null) {
      return _errnoBadf;
    }
    if (entry.kind == _FdKind.stdin ||
        entry.kind == _FdKind.stdout ||
        entry.kind == _FdKind.stderr) {
      return _errnoSpipe;
    }
    if (entry.kind == _FdKind.directory) {
      return _errnoInval;
    }
    if ((entry.rightsBase & _rightFdTell) == 0) {
      return _errnoNotcapable;
    }

    final memory = _requireMemory();
    try {
      final offset = entry.file!.tell();
      memory.storeI64(offsetPtr, offset);
      return _errnoSuccess;
    } on WasiFsException catch (error) {
      return _fsErrno(error.error);
    } on RangeError {
      return _errnoFault;
    }
  }

  Object? _fdFdstatGet(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    final fdstatPtr = _asI32(args, 1, 'fdstat_ptr');

    final entry = _fdTable[fd];
    if (entry == null) {
      return _errnoBadf;
    }

    final memory = _requireMemory();
    try {
      memory.storeI8(fdstatPtr + 0, _fileTypeForFdKind(entry.kind));
      memory.storeI8(fdstatPtr + 1, 0);
      memory.storeI16(fdstatPtr + 2, entry.fdFlags);
      memory.fillBytes(fdstatPtr + 4, 0, 4);
      memory.storeI64(fdstatPtr + 8, entry.rightsBase);
      memory.storeI64(fdstatPtr + 16, entry.rightsInheriting);
      return _errnoSuccess;
    } on RangeError {
      return _errnoFault;
    }
  }

  Object? _fdFdstatSetFlags(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    final fdFlags = _asI32(args, 1, 'fdflags').toUnsigned(16);
    if ((fdFlags & ~_fdflagMask) != 0) {
      return _errnoInval;
    }

    final entry = _fdTable[fd];
    if (entry == null) {
      return _errnoBadf;
    }
    if (entry.kind == _FdKind.directory) {
      return _errnoBadf;
    }
    if ((entry.rightsBase & _rightFdFdstatSetFlags) == 0) {
      return _errnoNotcapable;
    }

    entry.fdFlags = fdFlags;
    return _errnoSuccess;
  }

  Object? _fdFdstatSetRights(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    final rightsBase = WasmI64.unsigned(_asI64(args, 1, 'rights_base')).toInt();
    final rightsInheriting = WasmI64.unsigned(
      _asI64(args, 2, 'rights_inheriting'),
    ).toInt();

    final entry = _fdTable[fd];
    if (entry == null) {
      return _errnoBadf;
    }

    // fd_fdstat_set_rights can only drop capabilities, never add them.
    if ((rightsBase & ~entry.rightsBase) != 0 ||
        (rightsInheriting & ~entry.rightsInheriting) != 0) {
      return _errnoNotcapable;
    }

    entry.rightsBase = rightsBase;
    entry.rightsInheriting = rightsInheriting;
    return _errnoSuccess;
  }

  Object? _fdFilestatGet(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    final statPtr = _asI32(args, 1, 'stat_ptr');

    final entry = _fdTable[fd];
    if (entry == null) {
      return _errnoBadf;
    }
    if ((entry.rightsBase & _rightFdFileStatGet) == 0 &&
        entry.kind == _FdKind.file) {
      return _errnoNotcapable;
    }
    if ((entry.rightsBase & _rightPathFileStatGet) == 0 &&
        entry.kind == _FdKind.directory) {
      return _errnoNotcapable;
    }

    late WasiPathStat stat;
    switch (entry.kind) {
      case _FdKind.stdin:
      case _FdKind.stdout:
      case _FdKind.stderr:
        stat = const WasiPathStat(
          fileType: WasiFileType.characterDevice,
          inode: 0,
          size: 0,
          atimeNs: 0,
          mtimeNs: 0,
          ctimeNs: 0,
        );
      case _FdKind.directory:
        stat = WasiPathStat(
          fileType: WasiFileType.directory,
          inode: _inodeFromPath(entry.directoryPath!),
          size: 0,
          atimeNs: 0,
          mtimeNs: 0,
          ctimeNs: 0,
        );
      case _FdKind.file:
        final file = entry.file!;
        stat = WasiPathStat(
          fileType: WasiFileType.regularFile,
          inode: file.inode,
          size: file.size,
          atimeNs: file.atimeNs,
          mtimeNs: file.mtimeNs,
          ctimeNs: file.ctimeNs,
        );
    }

    final memory = _requireMemory();
    try {
      _storeFilestat(memory, statPtr, stat);
    } on RangeError {
      return _errnoFault;
    }
    return _errnoSuccess;
  }

  Object? _fdFilestatSetSize(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    final size = _asI64(args, 1, 'size');
    if (size < 0) {
      return _errnoInval;
    }

    final entry = _fdTable[fd];
    if (entry == null) {
      return _errnoBadf;
    }
    if (entry.kind != _FdKind.file) {
      return _errnoBadf;
    }
    if ((entry.rightsBase & _rightFdWrite) == 0) {
      return _errnoNotcapable;
    }

    try {
      entry.file!.truncate(size);
      return _errnoSuccess;
    } on WasiFsException catch (error) {
      return _fsErrno(error.error);
    }
  }

  Object? _fdFilestatSetTimes(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    final atim = _asI64(args, 1, 'atim');
    final mtim = _asI64(args, 2, 'mtim');
    final fstFlags = _asI32(args, 3, 'fst_flags').toUnsigned(16);

    final entry = _fdTable[fd];
    if (entry == null) {
      return _errnoBadf;
    }
    if (entry.kind != _FdKind.file) {
      return _errnoBadf;
    }
    if ((entry.rightsBase & _rightFdFileStatSetTimes) == 0) {
      return _errnoNotcapable;
    }

    final resolvedTimes = _resolveSetTimes(
      atim: atim,
      mtim: mtim,
      fstFlags: fstFlags,
    );
    if (resolvedTimes == null) {
      return _errnoInval;
    }

    try {
      entry.file!.setTimes(
        atimeNs: resolvedTimes.$1,
        mtimeNs: resolvedTimes.$2,
      );
      return _errnoSuccess;
    } on WasiFsException catch (error) {
      return _fsErrno(error.error);
    }
  }

  Object? _fdPrestatGet(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    final prestatPtr = _asI32(args, 1, 'prestat_ptr');

    final entry = _fdTable[fd];
    if (entry == null ||
        entry.kind != _FdKind.directory ||
        !_preopenedDirectories.containsKey(fd)) {
      return _errnoBadf;
    }

    final memory = _requireMemory();
    final dirBytes = utf8.encode(entry.directoryPath!);
    try {
      memory.storeI8(prestatPtr + 0, _preopenTypeDir);
      memory.fillBytes(prestatPtr + 1, 0, 3);
      memory.storeI32(prestatPtr + 4, dirBytes.length);
      return _errnoSuccess;
    } on RangeError {
      return _errnoFault;
    }
  }

  Object? _fdPrestatDirName(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    final pathPtr = _asI32(args, 1, 'path_ptr');
    final pathLen = _asI32(args, 2, 'path_len');
    if (pathLen < 0) {
      return _errnoInval;
    }

    final entry = _fdTable[fd];
    if (entry == null ||
        entry.kind != _FdKind.directory ||
        !_preopenedDirectories.containsKey(fd)) {
      return _errnoBadf;
    }

    final dirBytes = Uint8List.fromList(utf8.encode(entry.directoryPath!));
    if (pathLen < dirBytes.length) {
      return _errnoNametoolong;
    }

    final memory = _requireMemory();
    try {
      memory.writeBytes(pathPtr, dirBytes);
      return _errnoSuccess;
    } on RangeError {
      return _errnoFault;
    }
  }

  Object? _fdReaddir(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    final bufPtr = _asI32(args, 1, 'buf');
    final bufLen = _asI32(args, 2, 'buf_len');
    final cookie = _asI64(args, 3, 'cookie');
    final bufUsedPtr = _asI32(args, 4, 'buf_used');
    if (bufLen < 0 || cookie < 0) {
      return _errnoInval;
    }

    final entry = _fdTable[fd];
    if (entry == null || entry.kind != _FdKind.directory) {
      return _errnoBadf;
    }

    final listingFs = _fileSystem;
    if (listingFs is! WasiDirectoryListingFileSystem) {
      return _errnoNosys;
    }

    final entries = (listingFs as WasiDirectoryListingFileSystem).readDirectory(
      entry.directoryPath!,
    );
    final startIndex = cookie.toInt();
    if (startIndex > entries.length) {
      return _errnoInval;
    }

    final payload = BytesBuilder(copy: false);
    for (var i = startIndex; i < entries.length; i++) {
      payload.add(
        _encodeDirent(
          nextCookie: i + 1,
          inode: entries[i].inode,
          name: entries[i].name,
          fileType: _wasiFileTypeCode(entries[i].fileType),
        ),
      );
    }

    final memory = _requireMemory();
    try {
      final bytes = payload.takeBytes();
      final written = bytes.length < bufLen ? bytes.length : bufLen;
      memory.writeBytes(bufPtr, Uint8List.sublistView(bytes, 0, written));
      memory.storeI32(bufUsedPtr, written);
      return _errnoSuccess;
    } on RangeError {
      return _errnoFault;
    }
  }

  Object? _fdRenumber(List<Object?> args) {
    final from = _asI32(args, 0, 'from');
    final to = _asI32(args, 1, 'to');
    if (from < 0 || to < 0) {
      return _errnoBadf;
    }
    if (from == to) {
      return _errnoSuccess;
    }

    final source = _fdTable[from];
    if (source == null) {
      return _errnoBadf;
    }

    if (_preopenedDirectories.containsKey(from) ||
        _preopenedDirectories.containsKey(to)) {
      return _errnoNotsup;
    }

    final target = _fdTable[to];
    if (target != null && target.kind == _FdKind.file) {
      target.file!.close();
    }

    _fdTable[to] = source;
    _fdTable.remove(from);
    if (_nextDynamicFd <= to) {
      _nextDynamicFd = to + 1;
    }
    return _errnoSuccess;
  }

  Object? _pathOpen(List<Object?> args) {
    final dirFd = _asI32(args, 0, 'dirfd');
    final dirFlags = _asI32(args, 1, 'dirflags');
    final pathPtr = _asI32(args, 2, 'path_ptr');
    final pathLen = _asI32(args, 3, 'path_len');
    final oflags = _asI32(args, 4, 'oflags');
    final rightsBase = WasmI64.unsigned(_asI64(args, 5, 'rights_base'));
    final rightsInheriting = WasmI64.unsigned(
      _asI64(args, 6, 'rights_inheriting'),
    );
    final rightsBaseInt = rightsBase.toInt();
    final rightsInheritingInt = rightsInheriting.toInt();
    final fdFlags = _asI32(args, 7, 'fdflags').toUnsigned(16);
    final fdOutPtr = _asI32(args, 8, 'fd_out_ptr');

    if (pathLen < 0) {
      return _errnoInval;
    }
    if ((dirFlags & ~_lookupflagSymlinkFollow) != 0) {
      return _errnoInval;
    }
    if ((fdFlags & ~_fdflagMask) != 0) {
      return _errnoInval;
    }

    final dirEntry = _fdTable[dirFd];
    if (dirEntry == null || dirEntry.kind != _FdKind.directory) {
      return _errnoBadf;
    }
    if ((dirEntry.rightsBase & _rightPathOpen) == 0) {
      return _errnoNotcapable;
    }

    final memory = _requireMemory();
    String rawPath;
    try {
      final pathBytes = memory.readBytes(pathPtr, pathLen);
      rawPath = utf8.decode(pathBytes, allowMalformed: false);
    } on RangeError {
      return _errnoFault;
    } on FormatException {
      return _errnoInval;
    }

    final resolvedPathResult = _resolvePath(
      baseDirectory: dirEntry.directoryPath!,
      rawPath: rawPath,
    );
    if (resolvedPathResult.path == null) {
      return resolvedPathResult.errno;
    }
    final resolvedPath = resolvedPathResult.path!;

    final openDirectory = (oflags & _oflagDirectory) != 0;
    final canRead = (rightsBaseInt & _rightFdRead) != 0;
    final canWrite = (rightsBaseInt & _rightFdWrite) != 0;
    if (!openDirectory && !canRead && !canWrite) {
      return _errnoNotcapable;
    }
    if ((rightsBaseInt & ~dirEntry.rightsInheriting) != 0) {
      return _errnoNotcapable;
    }
    if ((rightsInheritingInt & ~dirEntry.rightsInheriting) != 0) {
      return _errnoNotcapable;
    }

    final create = (oflags & _oflagCreat) != 0;
    final truncate = (oflags & _oflagTrunc) != 0;
    final exclusive = (oflags & _oflagExcl) != 0;

    if (openDirectory) {
      if (create || truncate || exclusive) {
        return _errnoInval;
      }

      final metadataFs = _fileSystem;
      if (metadataFs is! WasiPathMetadataFileSystem) {
        return _errnoNosys;
      }

      WasiPathStat stat;
      try {
        stat = (metadataFs as WasiPathMetadataFileSystem).statPath(
          resolvedPath,
        );
      } on WasiFsException catch (error) {
        return _fsErrno(error.error);
      }
      if (stat.fileType != WasiFileType.directory) {
        return _errnoNotdir;
      }

      final openedFd = _allocateDynamicFd();
      final openedEntry = _FdEntry.directory(resolvedPath)
        ..rightsBase = rightsBaseInt
        ..rightsInheriting = rightsInheritingInt
        ..fdFlags = fdFlags;
      _fdTable[openedFd] = openedEntry;
      try {
        memory.storeI32(fdOutPtr, openedFd);
        return _errnoSuccess;
      } on RangeError {
        _fdTable.remove(openedFd);
        return _errnoFault;
      }
    }

    WasiFileDescriptor descriptor;
    try {
      descriptor = _fileSystem.open(
        path: resolvedPath,
        create: create,
        truncate: truncate,
        read: canRead,
        write: canWrite,
        exclusive: exclusive,
      );
    } on WasiFsException catch (error) {
      return _fsErrno(error.error);
    }

    final openedFd = _allocateDynamicFd();
    _fdTable[openedFd] = _FdEntry.file(
      descriptor,
      rightsBase: rightsBaseInt,
      rightsInheriting: rightsInheritingInt,
      fdFlags: fdFlags,
    );

    try {
      memory.storeI32(fdOutPtr, openedFd);
    } on RangeError {
      _fdTable.remove(openedFd);
      descriptor.close();
      return _errnoFault;
    }

    return _errnoSuccess;
  }

  Object? _pathFilestatGet(List<Object?> args) {
    final dirFd = _asI32(args, 0, 'dirfd');
    final flags = _asI32(args, 1, 'flags');
    final pathPtr = _asI32(args, 2, 'path_ptr');
    final pathLen = _asI32(args, 3, 'path_len');
    final statPtr = _asI32(args, 4, 'stat_ptr');
    if (pathLen < 0) {
      return _errnoInval;
    }
    if ((flags & ~_lookupflagSymlinkFollow) != 0) {
      return _errnoInval;
    }

    final resolvedPathResult = _resolveGuestPath(
      dirFd: dirFd,
      pathPtr: pathPtr,
      pathLen: pathLen,
      requiredRight: _rightPathFileStatGet,
    );
    if (resolvedPathResult.path == null) {
      return resolvedPathResult.errno;
    }
    final resolvedPath = resolvedPathResult.path!;

    final metadataFs = _fileSystem;
    if (metadataFs is! WasiPathMetadataFileSystem) {
      return _errnoNosys;
    }

    WasiPathStat stat;
    try {
      stat = (metadataFs as WasiPathMetadataFileSystem).statPath(resolvedPath);
    } on WasiFsException catch (error) {
      return _fsErrno(error.error);
    }

    final memory = _requireMemory();
    try {
      _storeFilestat(memory, statPtr, stat);
      return _errnoSuccess;
    } on RangeError {
      return _errnoFault;
    }
  }

  Object? _pathFilestatSetTimes(List<Object?> args) {
    final dirFd = _asI32(args, 0, 'dirfd');
    final flags = _asI32(args, 1, 'flags');
    final pathPtr = _asI32(args, 2, 'path_ptr');
    final pathLen = _asI32(args, 3, 'path_len');
    final atim = _asI64(args, 4, 'atim');
    final mtim = _asI64(args, 5, 'mtim');
    final fstFlags = _asI32(args, 6, 'fst_flags').toUnsigned(16);
    if (pathLen < 0) {
      return _errnoInval;
    }
    if ((flags & ~_lookupflagSymlinkFollow) != 0) {
      return _errnoInval;
    }

    final resolvedPathResult = _resolveGuestPath(
      dirFd: dirFd,
      pathPtr: pathPtr,
      pathLen: pathLen,
      requiredRight: _rightPathFileStatSetTimes,
    );
    if (resolvedPathResult.path == null) {
      return resolvedPathResult.errno;
    }
    final resolvedPath = resolvedPathResult.path!;

    final resolvedTimes = _resolveSetTimes(
      atim: atim,
      mtim: mtim,
      fstFlags: fstFlags,
    );
    if (resolvedTimes == null) {
      return _errnoInval;
    }

    final fs = _fileSystem;
    if (fs is! WasiPathTimesFileSystem) {
      return _errnoNosys;
    }

    try {
      (fs as WasiPathTimesFileSystem).setPathTimes(
        path: resolvedPath,
        atimeNs: resolvedTimes.$1,
        mtimeNs: resolvedTimes.$2,
      );
      return _errnoSuccess;
    } on WasiFsException catch (error) {
      return _fsErrno(error.error);
    }
  }

  Object? _pathLink(List<Object?> args) {
    final oldDirFd = _asI32(args, 0, 'old_dirfd');
    final oldFlags = _asI32(args, 1, 'old_flags');
    final oldPathPtr = _asI32(args, 2, 'old_path_ptr');
    final oldPathLen = _asI32(args, 3, 'old_path_len');
    final newDirFd = _asI32(args, 4, 'new_dirfd');
    final newPathPtr = _asI32(args, 5, 'new_path_ptr');
    final newPathLen = _asI32(args, 6, 'new_path_len');
    if (oldPathLen < 0 || newPathLen < 0) {
      return _errnoInval;
    }
    if ((oldFlags & ~_lookupflagSymlinkFollow) != 0) {
      return _errnoInval;
    }

    final sourceResult = _resolveGuestPath(
      dirFd: oldDirFd,
      pathPtr: oldPathPtr,
      pathLen: oldPathLen,
      requiredRight: _rightPathLinkSource,
    );
    if (sourceResult.path == null) {
      return sourceResult.errno;
    }
    final destinationResult = _resolveGuestPath(
      dirFd: newDirFd,
      pathPtr: newPathPtr,
      pathLen: newPathLen,
      requiredRight: _rightPathLinkTarget,
    );
    if (destinationResult.path == null) {
      return destinationResult.errno;
    }
    final source = sourceResult.path!;
    final destination = destinationResult.path!;

    final fs = _fileSystem;
    if (fs is! WasiPathLinkFileSystem) {
      return _errnoNosys;
    }

    try {
      (fs as WasiPathLinkFileSystem).link(
        sourcePath: source,
        destinationPath: destination,
      );
      return _errnoSuccess;
    } on WasiFsException catch (error) {
      return _fsErrno(error.error);
    }
  }

  Object? _pathSymlink(List<Object?> args) {
    final oldPathPtr = _asI32(args, 0, 'old_path_ptr');
    final oldPathLen = _asI32(args, 1, 'old_path_len');
    final fd = _asI32(args, 2, 'fd');
    final newPathPtr = _asI32(args, 3, 'new_path_ptr');
    final newPathLen = _asI32(args, 4, 'new_path_len');
    if (oldPathLen < 0 || newPathLen < 0) {
      return _errnoInval;
    }

    final dirEntry = _fdTable[fd];
    if (dirEntry == null || dirEntry.kind != _FdKind.directory) {
      return _errnoBadf;
    }
    if ((dirEntry.rightsBase & _rightPathSymlink) == 0) {
      return _errnoNotcapable;
    }

    final memory = _requireMemory();
    String targetPath;
    try {
      targetPath = utf8.decode(
        memory.readBytes(oldPathPtr, oldPathLen),
        allowMalformed: false,
      );
    } on RangeError {
      return _errnoFault;
    } on FormatException {
      return _errnoInval;
    }

    final linkPathResult = _resolveGuestPath(
      dirFd: fd,
      pathPtr: newPathPtr,
      pathLen: newPathLen,
      requiredRight: _rightPathSymlink,
    );
    if (linkPathResult.path == null) {
      return linkPathResult.errno;
    }
    final linkPath = linkPathResult.path!;

    final fs = _fileSystem;
    if (fs is! WasiPathLinkFileSystem) {
      return _errnoNosys;
    }

    try {
      (fs as WasiPathLinkFileSystem).symlink(
        targetPath: targetPath,
        linkPath: linkPath,
      );
      return _errnoSuccess;
    } on WasiFsException catch (error) {
      return _fsErrno(error.error);
    }
  }

  Object? _pathReadlink(List<Object?> args) {
    final dirFd = _asI32(args, 0, 'dirfd');
    final pathPtr = _asI32(args, 1, 'path_ptr');
    final pathLen = _asI32(args, 2, 'path_len');
    final bufPtr = _asI32(args, 3, 'buf_ptr');
    final bufLen = _asI32(args, 4, 'buf_len');
    final nreadPtr = _asI32(args, 5, 'nread_ptr');
    if (pathLen < 0 || bufLen < 0) {
      return _errnoInval;
    }

    final resolvedPathResult = _resolveGuestPath(
      dirFd: dirFd,
      pathPtr: pathPtr,
      pathLen: pathLen,
      requiredRight: _rightPathReadlink,
    );
    if (resolvedPathResult.path == null) {
      return resolvedPathResult.errno;
    }
    final resolvedPath = resolvedPathResult.path!;

    final fs = _fileSystem;
    if (fs is! WasiPathLinkFileSystem) {
      return _errnoNosys;
    }

    String target;
    try {
      target = (fs as WasiPathLinkFileSystem).readlink(resolvedPath);
    } on WasiFsException catch (error) {
      return _fsErrno(error.error);
    }

    final bytes = Uint8List.fromList(utf8.encode(target));
    final written = bytes.length < bufLen ? bytes.length : bufLen;
    final memory = _requireMemory();
    try {
      memory.writeBytes(bufPtr, Uint8List.sublistView(bytes, 0, written));
      memory.storeI32(nreadPtr, written);
      return _errnoSuccess;
    } on RangeError {
      return _errnoFault;
    }
  }

  Object? _pathCreateDirectory(List<Object?> args) {
    final dirFd = _asI32(args, 0, 'dirfd');
    final pathPtr = _asI32(args, 1, 'path_ptr');
    final pathLen = _asI32(args, 2, 'path_len');
    if (pathLen < 0) {
      return _errnoInval;
    }

    final resolvedPathResult = _resolveGuestPath(
      dirFd: dirFd,
      pathPtr: pathPtr,
      pathLen: pathLen,
      requiredRight: _rightPathCreateDirectory,
    );
    if (resolvedPathResult.path == null) {
      return resolvedPathResult.errno;
    }
    final resolvedPath = resolvedPathResult.path!;

    final mutableFs = _fileSystem;
    if (mutableFs is! WasiMutablePathFileSystem) {
      return _errnoNosys;
    }

    try {
      (mutableFs as WasiMutablePathFileSystem).createDirectory(resolvedPath);
      return _errnoSuccess;
    } on WasiFsException catch (error) {
      return _fsErrno(error.error);
    }
  }

  Object? _pathRemoveDirectory(List<Object?> args) {
    final dirFd = _asI32(args, 0, 'dirfd');
    final pathPtr = _asI32(args, 1, 'path_ptr');
    final pathLen = _asI32(args, 2, 'path_len');
    if (pathLen < 0) {
      return _errnoInval;
    }

    final resolvedPathResult = _resolveGuestPath(
      dirFd: dirFd,
      pathPtr: pathPtr,
      pathLen: pathLen,
      requiredRight: _rightPathRemoveDirectory,
    );
    if (resolvedPathResult.path == null) {
      return resolvedPathResult.errno;
    }
    final resolvedPath = resolvedPathResult.path!;

    final mutableFs = _fileSystem;
    if (mutableFs is! WasiMutablePathFileSystem) {
      return _errnoNosys;
    }

    try {
      (mutableFs as WasiMutablePathFileSystem).removeDirectory(resolvedPath);
      return _errnoSuccess;
    } on WasiFsException catch (error) {
      return _fsErrno(error.error);
    }
  }

  Object? _pathUnlinkFile(List<Object?> args) {
    final dirFd = _asI32(args, 0, 'dirfd');
    final pathPtr = _asI32(args, 1, 'path_ptr');
    final pathLen = _asI32(args, 2, 'path_len');
    if (pathLen < 0) {
      return _errnoInval;
    }

    final resolvedPathResult = _resolveGuestPath(
      dirFd: dirFd,
      pathPtr: pathPtr,
      pathLen: pathLen,
      requiredRight: _rightPathUnlinkFile,
    );
    if (resolvedPathResult.path == null) {
      return resolvedPathResult.errno;
    }
    final resolvedPath = resolvedPathResult.path!;

    final mutableFs = _fileSystem;
    if (mutableFs is! WasiMutablePathFileSystem) {
      return _errnoNosys;
    }

    try {
      (mutableFs as WasiMutablePathFileSystem).unlinkFile(resolvedPath);
      return _errnoSuccess;
    } on WasiFsException catch (error) {
      return _fsErrno(error.error);
    }
  }

  Object? _pathRename(List<Object?> args) {
    final oldDirFd = _asI32(args, 0, 'old_dirfd');
    final oldPathPtr = _asI32(args, 1, 'old_path_ptr');
    final oldPathLen = _asI32(args, 2, 'old_path_len');
    final newDirFd = _asI32(args, 3, 'new_dirfd');
    final newPathPtr = _asI32(args, 4, 'new_path_ptr');
    final newPathLen = _asI32(args, 5, 'new_path_len');
    if (oldPathLen < 0 || newPathLen < 0) {
      return _errnoInval;
    }

    final oldResolvedPathResult = _resolveGuestPath(
      dirFd: oldDirFd,
      pathPtr: oldPathPtr,
      pathLen: oldPathLen,
      requiredRight: _rightPathRenameSource,
    );
    if (oldResolvedPathResult.path == null) {
      return oldResolvedPathResult.errno;
    }
    final newResolvedPathResult = _resolveGuestPath(
      dirFd: newDirFd,
      pathPtr: newPathPtr,
      pathLen: newPathLen,
      requiredRight: _rightPathRenameTarget,
    );
    if (newResolvedPathResult.path == null) {
      return newResolvedPathResult.errno;
    }
    final oldResolvedPath = oldResolvedPathResult.path!;
    final newResolvedPath = newResolvedPathResult.path!;

    final mutableFs = _fileSystem;
    if (mutableFs is! WasiMutablePathFileSystem) {
      return _errnoNosys;
    }

    try {
      (mutableFs as WasiMutablePathFileSystem).rename(
        sourcePath: oldResolvedPath,
        destinationPath: newResolvedPath,
      );
      return _errnoSuccess;
    } on WasiFsException catch (error) {
      return _fsErrno(error.error);
    }
  }

  Object? _argsSizesGet(List<Object?> args) {
    final argcPtr = _asI32(args, 0, 'argc');
    final argvBufSizePtr = _asI32(args, 1, 'argv_buf_size');
    final memory = _requireMemory();
    try {
      memory.storeI32(argcPtr, _encodedArgs.length);
      memory.storeI32(argvBufSizePtr, _encodedArgsTotalSize);
    } on RangeError {
      return _errnoFault;
    }
    return _errnoSuccess;
  }

  Object? _argsGet(List<Object?> args) {
    final argvPtr = _asI32(args, 0, 'argv');
    final argvBufPtr = _asI32(args, 1, 'argv_buf');
    final memory = _requireMemory();
    try {
      _writeCStringVector(
        memory: memory,
        pointersPtr: argvPtr,
        bufferPtr: argvBufPtr,
        encodedValues: _encodedArgs,
      );
    } on RangeError {
      return _errnoFault;
    }
    return _errnoSuccess;
  }

  Object? _environSizesGet(List<Object?> args) {
    final environCountPtr = _asI32(args, 0, 'environ_count');
    final environBufSizePtr = _asI32(args, 1, 'environ_buf_size');
    final memory = _requireMemory();
    try {
      memory.storeI32(environCountPtr, _encodedEnvironmentEntries.length);
      memory.storeI32(environBufSizePtr, _encodedEnvironmentTotalSize);
      return _errnoSuccess;
    } on RangeError {
      return _errnoFault;
    }
  }

  Object? _environGet(List<Object?> args) {
    final environPtr = _asI32(args, 0, 'environ');
    final environBufPtr = _asI32(args, 1, 'environ_buf');
    final memory = _requireMemory();
    try {
      _writeCStringVector(
        memory: memory,
        pointersPtr: environPtr,
        bufferPtr: environBufPtr,
        encodedValues: _encodedEnvironmentEntries,
      );
      return _errnoSuccess;
    } on RangeError {
      return _errnoFault;
    }
  }

  Object? _clockTimeGet(List<Object?> args) {
    final clockId = _asI32(args, 0, 'clock_id');
    _asI64(args, 1, 'precision');
    final timePtr = _asI32(args, 2, 'time_ptr');

    final nowNs = _clockNowNs(clockId);
    if (nowNs == null) {
      return _errnoInval;
    }

    final memory = _requireMemory();
    try {
      memory.storeI64(timePtr, nowNs);
      return _errnoSuccess;
    } on RangeError {
      return _errnoFault;
    }
  }

  Object? _clockResGet(List<Object?> args) {
    final clockId = _asI32(args, 0, 'clock_id');
    final resolutionPtr = _asI32(args, 1, 'resolution_ptr');
    switch (clockId) {
      case _clockIdRealtime:
      case _clockIdMonotonic:
      case _clockIdProcessCpuTime:
      case _clockIdThreadCpuTime:
        break;
      default:
        return _errnoInval;
    }
    final memory = _requireMemory();
    try {
      memory.storeI64(resolutionPtr, 1);
      return _errnoSuccess;
    } on RangeError {
      return _errnoFault;
    }
  }

  Object? _randomGet(List<Object?> args) {
    final bufPtr = _asI32(args, 0, 'buf');
    final bufLen = _asI32(args, 1, 'buf_len');
    if (bufLen < 0) {
      return _errnoInval;
    }

    final bytes = Uint8List(bufLen);
    for (var i = 0; i < bufLen; i++) {
      bytes[i] = _nextRandomByte();
    }

    final memory = _requireMemory();
    try {
      memory.writeBytes(bufPtr, bytes);
      return _errnoSuccess;
    } on RangeError {
      return _errnoFault;
    }
  }

  Object? _pollOneoff(List<Object?> args) {
    final inPtr = _asI32(args, 0, 'in_ptr');
    final outPtr = _asI32(args, 1, 'out_ptr');
    final nSubscriptions = _asI32(args, 2, 'nsubscriptions');
    final nEventsPtr = _asI32(args, 3, 'nevents_ptr');
    if (nSubscriptions <= 0) {
      return _errnoInval;
    }

    final memory = _requireMemory();
    final subscriptions = <_PollSubscription>[];
    try {
      for (var i = 0; i < nSubscriptions; i++) {
        final subscriptionPtr = inPtr + (i * _subscriptionSize);
        final userdata = memory.loadI64(
          subscriptionPtr + _subscriptionOffsetUserdata,
        );
        final eventType = memory.loadU8(
          subscriptionPtr + _subscriptionOffsetEventType,
        );

        switch (eventType) {
          case _eventTypeClock:
            final clockId = memory.loadI32(
              subscriptionPtr + _subscriptionOffsetClockId,
            );
            final timeout = memory.loadU64(
              subscriptionPtr + _subscriptionOffsetClockTimeout,
            );
            final precision = memory.loadU64(
              subscriptionPtr + _subscriptionOffsetClockPrecision,
            );
            final clockFlags = memory.loadU16(
              subscriptionPtr + _subscriptionOffsetClockFlags,
            );
            if ((clockFlags & ~_subclockFlagAbstime) != 0) {
              return _errnoInval;
            }
            final now = _clockNowNs(clockId);
            final isAbsolute = (clockFlags & _subclockFlagAbstime) != 0;
            final deadline = now == null
                ? null
                : (isAbsolute ? timeout : now + timeout);
            subscriptions.add(
              _PollSubscription.clock(
                userdata: userdata,
                clockId: clockId,
                clockFlags: clockFlags,
                clockPrecisionNs: precision,
                clockDeadlineNs: deadline,
              ),
            );
          case _eventTypeFdRead:
            final fd = memory.loadI32(subscriptionPtr + _subscriptionOffsetFd);
            subscriptions.add(
              _PollSubscription.fdRead(userdata: userdata, fd: fd),
            );
          case _eventTypeFdWrite:
            final fd = memory.loadI32(subscriptionPtr + _subscriptionOffsetFd);
            subscriptions.add(
              _PollSubscription.fdWrite(userdata: userdata, fd: fd),
            );
          default:
            return _errnoInval;
        }
      }
    } on RangeError {
      return _errnoFault;
    }

    while (true) {
      final readyEvents = <_PollReadyEvent>[];
      BigInt? minClockRemainingNs;
      var hasNonClockSubscriptions = false;

      for (final subscription in subscriptions) {
        switch (subscription.eventType) {
          case _eventTypeClock:
            final clockId = subscription.clockId!;
            final now = _clockNowNs(clockId);
            if (now == null) {
              readyEvents.add(
                _PollReadyEvent(
                  userdata: subscription.userdata,
                  eventType: _eventTypeClock,
                  errno: _errnoInval,
                ),
              );
              continue;
            }
            final deadline = subscription.clockDeadlineNs!;
            if (now >= deadline) {
              readyEvents.add(
                _PollReadyEvent(
                  userdata: subscription.userdata,
                  eventType: _eventTypeClock,
                  errno: _errnoSuccess,
                ),
              );
              continue;
            }
            final remaining = deadline - now;
            if (minClockRemainingNs == null ||
                remaining < minClockRemainingNs) {
              minClockRemainingNs = remaining;
            }
          case _eventTypeFdRead:
            hasNonClockSubscriptions = true;
            final fd = subscription.fd!;
            final entry = _fdTable[fd];
            if (entry == null ||
                entry.kind == _FdKind.stdout ||
                entry.kind == _FdKind.stderr ||
                entry.kind == _FdKind.directory) {
              readyEvents.add(
                _PollReadyEvent(
                  userdata: subscription.userdata,
                  eventType: _eventTypeFdRead,
                  errno: _errnoBadf,
                ),
              );
              continue;
            }
            final nbytes = _availableReadBytes(entry: entry);
            final ready = entry.kind == _FdKind.file || nbytes > 0;
            if (ready) {
              readyEvents.add(
                _PollReadyEvent(
                  userdata: subscription.userdata,
                  eventType: _eventTypeFdRead,
                  errno: _errnoSuccess,
                  nbytes: nbytes,
                ),
              );
            }
          case _eventTypeFdWrite:
            hasNonClockSubscriptions = true;
            final fd = subscription.fd!;
            final entry = _fdTable[fd];
            if (entry == null ||
                entry.kind == _FdKind.stdin ||
                entry.kind == _FdKind.directory) {
              readyEvents.add(
                _PollReadyEvent(
                  userdata: subscription.userdata,
                  eventType: _eventTypeFdWrite,
                  errno: _errnoBadf,
                ),
              );
              continue;
            }
            readyEvents.add(
              _PollReadyEvent(
                userdata: subscription.userdata,
                eventType: _eventTypeFdWrite,
                errno: _errnoSuccess,
              ),
            );
          default:
            return _errnoInval;
        }
      }

      if (readyEvents.isNotEmpty) {
        try {
          for (var i = 0; i < readyEvents.length; i++) {
            final event = readyEvents[i];
            _storePollEvent(
              memory: memory,
              eventPtr: outPtr + (i * _eventSize),
              userdata: event.userdata,
              eventType: event.eventType,
              errno: event.errno,
              nbytes: event.nbytes,
              flags: event.flags,
            );
          }
          memory.storeI32(nEventsPtr, readyEvents.length);
          return _errnoSuccess;
        } on RangeError {
          return _errnoFault;
        }
      }

      final sleepDuration = _nextPollSleepDuration(
        minClockRemainingNs: minClockRemainingNs,
        hasNonClockSubscriptions: hasNonClockSubscriptions,
      );
      _sleep(sleepDuration);
    }
  }

  Object? _schedYield(List<Object?> args) {
    if (args.isNotEmpty) {
      // Ignore extra values to stay permissive with host adapters.
    }
    return _errnoSuccess;
  }

  Object? _procRaise(List<Object?> args) {
    final signal = _asI32(args, 0, 'sig');
    switch (procRaiseMode) {
      case WasiProcRaiseMode.enosys:
        return _errnoNosys;
      case WasiProcRaiseMode.success:
        return _errnoSuccess;
      case WasiProcRaiseMode.trap:
        throw WasiProcRaise(signal);
    }
  }

  Object? _procExit(List<Object?> args) {
    final code = _asI32(args, 0, 'code');
    throw WasiProcExit(code);
  }

  Object? _sockAccept(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    final flags = _asI32(args, 1, 'flags');
    final roFdPtr = _asI32(args, 2, 'ro_fd_ptr');
    final handler = _socketTransport?.accept;
    if (handler == null) {
      return _errnoNosys;
    }
    final result = handler(
      fd: fd,
      flags: flags,
      allocateFd: _allocateDynamicFd,
    );
    if (result.errno != _errnoSuccess) {
      return result.errno;
    }
    final acceptedFd = result.acceptedFd;
    if (acceptedFd == null || acceptedFd < 0) {
      throw StateError(
        'WASI sock_accept handler must return a non-negative acceptedFd when errno is success.',
      );
    }
    final memory = _requireMemory();
    try {
      memory.storeI32(roFdPtr, acceptedFd);
      return _errnoSuccess;
    } on RangeError {
      return _errnoFault;
    }
  }

  Object? _sockRecv(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    final riDataPtr = _asI32(args, 1, 'ri_data_ptr');
    final riDataLen = _asI32(args, 2, 'ri_data_len');
    final riFlags = _asI32(args, 3, 'ri_flags');
    final roDatalenPtr = _asI32(args, 4, 'ro_datalen_ptr');
    final roFlagsPtr = _asI32(args, 5, 'ro_flags_ptr');
    if (riDataLen < 0) {
      return _errnoInval;
    }
    final handler = _socketTransport?.recv;
    if (handler == null) {
      return _errnoNosys;
    }

    final memory = _requireMemory();
    var requestedBytes = 0;
    try {
      for (var i = 0; i < riDataLen; i++) {
        final iovBase = riDataPtr + (i * 8);
        final len = memory.loadI32(iovBase + 4);
        if (len < 0) {
          return _errnoInval;
        }
        requestedBytes += len;
      }
    } on RangeError {
      return _errnoFault;
    }

    final result = handler(fd: fd, flags: riFlags, maxBytes: requestedBytes);
    if (result.errno != _errnoSuccess) {
      return result.errno;
    }
    final incoming = result.data ?? Uint8List(0);
    final bytes = incoming.length <= requestedBytes
        ? incoming
        : Uint8List.sublistView(incoming, 0, requestedBytes);

    var copied = 0;
    var cursor = 0;
    try {
      for (var i = 0; i < riDataLen && cursor < bytes.length; i++) {
        final iovBase = riDataPtr + (i * 8);
        final ptr = memory.loadI32(iovBase);
        final len = memory.loadI32(iovBase + 4);
        final chunkLen = (bytes.length - cursor) < len
            ? (bytes.length - cursor)
            : len;
        if (chunkLen <= 0) {
          continue;
        }
        memory.writeBytes(
          ptr,
          Uint8List.sublistView(bytes, cursor, cursor + chunkLen),
        );
        cursor += chunkLen;
        copied += chunkLen;
      }
      memory.storeI32(roDatalenPtr, copied);
      memory.storeI16(roFlagsPtr, result.flags);
      return _errnoSuccess;
    } on RangeError {
      return _errnoFault;
    }
  }

  Object? _sockSend(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    final siDataPtr = _asI32(args, 1, 'si_data_ptr');
    final siDataLen = _asI32(args, 2, 'si_data_len');
    final siFlags = _asI32(args, 3, 'si_flags');
    final soDatalenPtr = _asI32(args, 4, 'so_datalen_ptr');
    if (siDataLen < 0) {
      return _errnoInval;
    }
    final handler = _socketTransport?.send;
    if (handler == null) {
      return _errnoNosys;
    }

    final memory = _requireMemory();
    final output = BytesBuilder(copy: false);
    var totalBytes = 0;
    try {
      for (var i = 0; i < siDataLen; i++) {
        final iovBase = siDataPtr + (i * 8);
        final ptr = memory.loadI32(iovBase);
        final len = memory.loadI32(iovBase + 4);
        if (len < 0) {
          return _errnoInval;
        }
        output.add(memory.readBytes(ptr, len));
        totalBytes += len;
      }
    } on RangeError {
      return _errnoFault;
    }
    final data = Uint8List.fromList(output.takeBytes());

    final result = handler(fd: fd, flags: siFlags, data: data);
    if (result.errno != _errnoSuccess) {
      return result.errno;
    }
    final bytesWritten = result.bytesWritten;
    if (bytesWritten < 0 || bytesWritten > totalBytes) {
      throw StateError(
        'WASI sock_send handler bytesWritten must be between 0 and input length.',
      );
    }
    try {
      memory.storeI32(soDatalenPtr, bytesWritten);
      return _errnoSuccess;
    } on RangeError {
      return _errnoFault;
    }
  }

  Object? _sockShutdown(List<Object?> args) {
    final fd = _asI32(args, 0, 'fd');
    final how = _asI32(args, 1, 'how');
    final handler = _socketTransport?.shutdown;
    if (handler == null) {
      return _errnoNosys;
    }
    return handler(fd: fd, how: how);
  }

  void _resetFdTable() {
    _fdTable
      ..clear()
      ..[0] = _FdEntry.stdin()
      ..[1] = _FdEntry.stdout()
      ..[2] = _FdEntry.stderr();

    var maxFd = 2;
    for (final entry in _preopenedDirectories.entries) {
      if (entry.key < 0) {
        throw ArgumentError.value(entry.key, 'preopenedDirectories key');
      }
      _fdTable[entry.key] = _FdEntry.directory(entry.value);
      if (entry.key > maxFd) {
        maxFd = entry.key;
      }
    }
    _nextDynamicFd = maxFd + 1;
  }

  int _allocateDynamicFd() {
    while (_fdTable.containsKey(_nextDynamicFd) ||
        (_socketTransport?.containsFd?.call(fd: _nextDynamicFd) ?? false)) {
      _nextDynamicFd++;
    }
    return _nextDynamicFd++;
  }

  WasmMemory _requireMemory() {
    final memory = _memory;
    if (memory == null) {
      throw StateError(
        'WASI memory is not bound. Call bindMemory(...) or bindInstance(...) first.',
      );
    }
    return memory;
  }

  Uint8List _readInput(int maxBytes) {
    if (maxBytes <= 0) {
      return Uint8List(0);
    }
    final custom = stdinSource;
    if (custom != null) {
      final chunk = custom(maxBytes);
      if (chunk.length <= maxBytes) {
        return chunk;
      }
      return Uint8List.sublistView(chunk, 0, maxBytes);
    }

    if (_stdinOffset >= _stdinBuffer.length) {
      return Uint8List(0);
    }
    final available = _stdinBuffer.length - _stdinOffset;
    final count = available < maxBytes ? available : maxBytes;
    final chunk = Uint8List.sublistView(
      _stdinBuffer,
      _stdinOffset,
      _stdinOffset + count,
    );
    _stdinOffset += count;
    return Uint8List.fromList(chunk);
  }

  static List<Uint8List> _encodeUtf8Values(Iterable<String> values) {
    return values
        .map(utf8.encode)
        .map(Uint8List.fromList)
        .toList(growable: false);
  }

  static List<Uint8List> _encodeEnvironmentValues(
    Map<String, String> environment,
  ) {
    return _encodeUtf8Values(
      environment.entries.map((entry) => '${entry.key}=${entry.value}'),
    );
  }

  static int _cstringVectorTotalSize(List<Uint8List> encodedValues) {
    return encodedValues.fold<int>(0, (sum, part) => sum + part.length + 1);
  }

  static void _writeCStringVector({
    required WasmMemory memory,
    required int pointersPtr,
    required int bufferPtr,
    required List<Uint8List> encodedValues,
  }) {
    var cursor = bufferPtr;
    for (var i = 0; i < encodedValues.length; i++) {
      final encoded = encodedValues[i];
      memory.storeI32(pointersPtr + (i * 4), cursor);
      memory.writeBytesFromList(cursor, encoded);
      memory.storeI8(cursor + encoded.length, 0);
      cursor += encoded.length + 1;
    }
  }

  int _nextRandomByte() {
    return _random.nextInt(256);
  }

  static Random _createRandom() {
    try {
      return Random.secure();
    } on UnsupportedError {
      return Random();
    }
  }

  BigInt _defaultNowRealtimeNs() {
    return BigInt.from(DateTime.now().microsecondsSinceEpoch) *
        BigInt.from(1000);
  }

  BigInt _defaultNowMonotonicNs() {
    return BigInt.from(_monotonicClock.elapsedMicroseconds) * BigInt.from(1000);
  }

  static void _defaultSleep(Duration duration) {
    if (duration <= Duration.zero) {
      return;
    }
    final targetMicros = duration.inMicroseconds;
    final sw = Stopwatch()..start();
    while (sw.elapsedMicroseconds < targetMicros) {}
  }

  BigInt? _clockNowNs(int clockId) {
    switch (clockId) {
      case _clockIdRealtime:
        return _nowRealtimeNs();
      case _clockIdMonotonic:
      case _clockIdProcessCpuTime:
      case _clockIdThreadCpuTime:
        return _nowMonotonicNs();
      default:
        return null;
    }
  }

  Duration _nextPollSleepDuration({
    required BigInt? minClockRemainingNs,
    required bool hasNonClockSubscriptions,
  }) {
    var sleepDuration = _pollIdleSleep;
    if (minClockRemainingNs != null) {
      if (minClockRemainingNs <= BigInt.zero) {
        return Duration.zero;
      }
      final maxNs =
          BigInt.from(_pollMaxSleep.inMicroseconds) * BigInt.from(1000);
      if (minClockRemainingNs >= maxNs) {
        sleepDuration = _pollMaxSleep;
      } else {
        final micros =
            ((minClockRemainingNs + BigInt.from(999)) ~/ BigInt.from(1000))
                .toInt();
        sleepDuration = Duration(microseconds: micros);
      }
    }
    if (hasNonClockSubscriptions && sleepDuration > _pollIdleSleep) {
      return _pollIdleSleep;
    }
    return sleepDuration;
  }

  int _availableReadBytes({required _FdEntry entry}) {
    return switch (entry.kind) {
      _FdKind.stdin =>
        (_stdinBuffer.length - _stdinOffset) < 0
            ? 0
            : (_stdinBuffer.length - _stdinOffset),
      _FdKind.file => _availableFileBytes(entry.file!),
      _FdKind.stdout || _FdKind.stderr || _FdKind.directory => 0,
    };
  }

  static void _storePollEvent({
    required WasmMemory memory,
    required int eventPtr,
    required BigInt userdata,
    required int eventType,
    required int errno,
    required int nbytes,
    required int flags,
  }) {
    memory.storeI64(eventPtr + _eventOffsetUserdata, userdata);
    memory.storeI16(eventPtr + _eventOffsetErrno, errno);
    memory.storeI8(eventPtr + _eventOffsetEventType, eventType);
    memory.storeI8(eventPtr + (_eventOffsetEventType + 1), 0);
    memory.storeI64(eventPtr + _eventOffsetNbytes, nbytes);
    memory.storeI16(eventPtr + _eventOffsetFlags, flags);
    memory.fillBytes(eventPtr + (_eventOffsetFlags + 2), 0, 6);
  }

  static int _availableFileBytes(WasiFileDescriptor file) {
    try {
      final current = file.tell();
      final remaining = file.size - current;
      return remaining < 0 ? 0 : remaining;
    } on WasiFsException {
      return 0;
    }
  }

  static (int?, int?)? _resolveSetTimes({
    required int atim,
    required int mtim,
    required int fstFlags,
  }) {
    if ((fstFlags & ~_fstFlagMask) != 0) {
      return null;
    }
    final atimSet = (fstFlags & _fstFlagAtim) != 0;
    final atimNow = (fstFlags & _fstFlagAtimNow) != 0;
    final mtimSet = (fstFlags & _fstFlagMtim) != 0;
    final mtimNow = (fstFlags & _fstFlagMtimNow) != 0;
    if (atimSet && atimNow) {
      return null;
    }
    if (mtimSet && mtimNow) {
      return null;
    }

    final now = DateTime.now().microsecondsSinceEpoch * 1000;
    final atimeNs = atimNow
        ? now
        : (atimSet ? WasmI64.signed(atim).toInt() : null);
    final mtimeNs = mtimNow
        ? now
        : (mtimSet ? WasmI64.signed(mtim).toInt() : null);
    return (atimeNs, mtimeNs);
  }

  static void _storeFilestat(
    WasmMemory memory,
    int statPtr,
    WasiPathStat stat,
  ) {
    memory.storeI64(statPtr + 0, 1);
    memory.storeI64(statPtr + 8, stat.inode);
    memory.storeI8(statPtr + 16, _wasiFileTypeCode(stat.fileType));
    memory.fillBytes(statPtr + 17, 0, 7);
    memory.storeI64(statPtr + 24, 1);
    memory.storeI64(statPtr + 32, stat.size);
    memory.storeI64(statPtr + 40, stat.atimeNs);
    memory.storeI64(statPtr + 48, stat.mtimeNs);
    memory.storeI64(statPtr + 56, stat.ctimeNs);
  }

  static Uint8List _encodeDirent({
    required int nextCookie,
    required int inode,
    required String name,
    required int fileType,
  }) {
    final nameBytes = utf8.encode(name);
    final totalLength = 24 + nameBytes.length;
    final bytes = Uint8List(totalLength);
    final view = ByteData.sublistView(bytes);
    view.setUint32(0, WasmI64.lowU32(nextCookie), Endian.little);
    view.setUint32(4, WasmI64.highU32(nextCookie), Endian.little);
    view.setUint32(8, WasmI64.lowU32(inode), Endian.little);
    view.setUint32(12, WasmI64.highU32(inode), Endian.little);
    view.setUint32(16, nameBytes.length, Endian.little);
    view.setUint8(20, fileType);
    bytes.setRange(24, totalLength, nameBytes);
    return bytes;
  }

  _ResolvedPath _resolvePath({
    required String baseDirectory,
    required String rawPath,
  }) {
    if (rawPath.contains('\u0000')) {
      return const _ResolvedPath.error(_errnoInval);
    }

    final combined = rawPath.startsWith('/')
        ? rawPath
        : (baseDirectory == '/' ? '/$rawPath' : '$baseDirectory/$rawPath');
    late final String normalized;
    try {
      normalized = WasiInMemoryFileSystem.normalizeAbsolutePath(combined);
    } on WasiFsException catch (error) {
      return _ResolvedPath.error(_pathResolutionErrno(error.error));
    }

    if (baseDirectory == '/') {
      return _ResolvedPath.path(normalized);
    }
    if (normalized == baseDirectory ||
        normalized.startsWith('$baseDirectory/')) {
      return _ResolvedPath.path(normalized);
    }
    return const _ResolvedPath.error(_errnoNotcapable);
  }

  _ResolvedPath _resolveGuestPath({
    required int dirFd,
    required int pathPtr,
    required int pathLen,
    required int requiredRight,
  }) {
    final dirEntry = _fdTable[dirFd];
    if (dirEntry == null || dirEntry.kind != _FdKind.directory) {
      return const _ResolvedPath.error(_errnoBadf);
    }
    if ((dirEntry.rightsBase & requiredRight) == 0) {
      return const _ResolvedPath.error(_errnoNotcapable);
    }

    final memory = _requireMemory();
    try {
      final pathBytes = memory.readBytes(pathPtr, pathLen);
      final rawPath = utf8.decode(pathBytes, allowMalformed: false);
      return _resolvePath(
        baseDirectory: dirEntry.directoryPath!,
        rawPath: rawPath,
      );
    } on RangeError {
      return const _ResolvedPath.error(_errnoFault);
    } on FormatException {
      return const _ResolvedPath.error(_errnoInval);
    }
  }

  static int _pathResolutionErrno(WasiFsError error) {
    switch (error) {
      case WasiFsError.permissionDenied:
        return _errnoNotcapable;
      case WasiFsError.invalid:
        return _errnoInval;
      default:
        return _fsErrno(error);
    }
  }

  static int _asI32(List<Object?> args, int index, String name) {
    if (index < 0 || index >= args.length) {
      throw StateError('Missing WASI argument: $name');
    }
    final value = args[index];
    if (value is! int) {
      throw StateError('WASI argument `$name` must be i32/int.');
    }
    return value.toSigned(32);
  }

  static int _asI64(List<Object?> args, int index, String name) {
    if (index < 0 || index >= args.length) {
      throw StateError('Missing WASI argument: $name');
    }
    final value = args[index];
    if (value is int) {
      return WasmI64.signed(value).toInt();
    }
    if (value is BigInt) {
      return WasmI64.signed(value).toInt();
    }
    throw StateError('WASI argument `$name` must be i64/int-or-bigint.');
  }

  static int _fsErrno(WasiFsError error) {
    switch (error) {
      case WasiFsError.notFound:
        return _errnoNoent;
      case WasiFsError.exists:
        return _errnoExist;
      case WasiFsError.invalid:
        return _errnoInval;
      case WasiFsError.permissionDenied:
        return _errnoPerm;
      case WasiFsError.notSupported:
        return _errnoNosys;
      case WasiFsError.directoryNotEmpty:
        return _errnoNotempty;
      case WasiFsError.notDirectory:
        return _errnoNotdir;
      case WasiFsError.isDirectory:
        return _errnoIsdir;
    }
  }

  static int _inodeFromPath(String path) {
    return WasmHash.fnv1a64Positive(path);
  }

  static int _fileTypeForFdKind(_FdKind kind) {
    return switch (kind) {
      _FdKind.stdin ||
      _FdKind.stdout ||
      _FdKind.stderr => _filetypeCharacterDevice,
      _FdKind.directory => _filetypeDirectory,
      _FdKind.file => _filetypeRegularFile,
    };
  }

  static int _wasiFileTypeCode(WasiFileType fileType) {
    return switch (fileType) {
      WasiFileType.blockDevice => _filetypeBlockDevice,
      WasiFileType.characterDevice => _filetypeCharacterDevice,
      WasiFileType.directory => _filetypeDirectory,
      WasiFileType.regularFile => _filetypeRegularFile,
      WasiFileType.socketDgram => _filetypeSocketDgram,
      WasiFileType.socketStream => _filetypeSocketStream,
      WasiFileType.symbolicLink => _filetypeSymbolicLink,
      WasiFileType.unknown => _filetypeUnknown,
    };
  }

  static void _discardOutput(Uint8List _) {}

  static const int _lookupflagSymlinkFollow = 0x0001;

  static const int _oflagCreat = 0x0001;
  static const int _oflagDirectory = 0x0002;
  static const int _oflagExcl = 0x0004;
  static const int _oflagTrunc = 0x0008;

  static const int _fdflagAppend = 0x0001;
  static const int _fdflagDsync = 0x0002;
  static const int _fdflagNonblock = 0x0004;
  static const int _fdflagRsync = 0x0008;
  static const int _fdflagSync = 0x0010;
  static const int _fdflagMask =
      _fdflagAppend |
      _fdflagDsync |
      _fdflagNonblock |
      _fdflagRsync |
      _fdflagSync;

  static const int _fstFlagAtim = 0x0001;
  static const int _fstFlagAtimNow = 0x0002;
  static const int _fstFlagMtim = 0x0004;
  static const int _fstFlagMtimNow = 0x0008;
  static const int _fstFlagMask =
      _fstFlagAtim | _fstFlagAtimNow | _fstFlagMtim | _fstFlagMtimNow;

  static const int _rightFdRead = 0x0000000000000002;
  static const int _rightFdSeek = 0x0000000000000004;
  static const int _rightFdFdstatSetFlags = 0x0000000000000008;
  static const int _rightFdTell = 0x0000000000000020;
  static const int _rightFdWrite = 0x0000000000000040;
  static const int _rightFdFileStatSetTimes = 0x0000000000008000;
  static const int _rightPathCreateDirectory = 0x0000000000000200;
  static const int _rightPathLinkSource = 0x0000000000000400;
  static const int _rightPathLinkTarget = 0x0000000000000800;
  static const int _rightPathOpen = 0x0000000000002000;
  static const int _rightPathRenameSource = 0x0000000000010000;
  static const int _rightPathRenameTarget = 0x0000000000020000;
  static const int _rightPathFileStatGet = 0x0000000000040000;
  static const int _rightPathFileStatSetTimes = 0x0000000000080000;
  static const int _rightFdFileStatGet = 0x0000000000200000;
  static const int _rightPathSymlink = 0x0000000001000000;
  static const int _rightPathRemoveDirectory = 0x0000000002000000;
  static const int _rightPathUnlinkFile = 0x0000000004000000;
  static const int _rightPathReadlink = 0x0000000008000000;

  static const int _errnoSuccess = 0;
  static const int _errnoPerm = 63;
  static const int _errnoBadf = 8;
  static const int _errnoExist = 20;
  static const int _errnoFault = 21;
  static const int _errnoInval = 28;
  static const int _errnoNametoolong = 37;
  static const int _errnoNoent = 44;
  static const int _errnoNosys = 52;
  static const int _errnoNotempty = 55;
  static const int _errnoNotdir = 54;
  static const int _errnoNotsup = 58;
  static const int _errnoIsdir = 31;
  static const int _errnoNotcapable = 76;
  static const int _errnoSpipe = 70;

  static const int _whenceSet = 0;
  static const int _whenceEnd = 2;

  static const int _clockIdRealtime = 0;
  static const int _clockIdMonotonic = 1;
  static const int _clockIdProcessCpuTime = 2;
  static const int _clockIdThreadCpuTime = 3;

  static const int _eventTypeClock = 0;
  static const int _eventTypeFdRead = 1;
  static const int _eventTypeFdWrite = 2;
  static const int _subclockFlagAbstime = 0x0001;

  static const int _subscriptionOffsetUserdata = 0;
  static const int _subscriptionOffsetEventType = 8;
  static const int _subscriptionOffsetFd = 16;
  static const int _subscriptionOffsetClockId = 16;
  static const int _subscriptionOffsetClockTimeout = 24;
  static const int _subscriptionOffsetClockPrecision = 32;
  static const int _subscriptionOffsetClockFlags = 40;

  static const int _eventOffsetUserdata = 0;
  static const int _eventOffsetErrno = 8;
  static const int _eventOffsetEventType = 10;
  static const int _eventOffsetNbytes = 16;
  static const int _eventOffsetFlags = 24;

  static const int _subscriptionSize = 48;
  static const int _eventSize = 32;
  static const Duration _pollIdleSleep = Duration(milliseconds: 5);
  static const Duration _pollMaxSleep = Duration(milliseconds: 50);

  static const int _preopenTypeDir = 0;

  static const int _filetypeUnknown = 0;
  static const int _filetypeBlockDevice = 1;
  static const int _filetypeCharacterDevice = 2;
  static const int _filetypeDirectory = 3;
  static const int _filetypeRegularFile = 4;
  static const int _filetypeSocketDgram = 5;
  static const int _filetypeSocketStream = 6;
  static const int _filetypeSymbolicLink = 7;
}

final class WasiProcExit implements Exception {
  const WasiProcExit(this.exitCode);

  final int exitCode;

  @override
  String toString() => 'WasiProcExit($exitCode)';
}

final class WasiProcRaise implements Exception {
  const WasiProcRaise(this.signal);

  final int signal;

  @override
  String toString() => 'WasiProcRaise(signal: $signal)';
}
