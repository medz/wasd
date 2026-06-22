import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wasd/src/wasi/preview1/common/constants.dart';
import 'package:wasd/src/wasi/preview1/common/fd_syscalls.dart';
import 'package:wasd/src/wasi/preview1/common/socket_syscalls.dart';
import 'package:wasd/src/wasi/preview1/common/vfs.dart';
import 'package:wasd/src/wasi/preview1/socket.dart';

const int _defaultDirectories = 64;
const int _defaultFilesPerDirectory = 32;
const int _defaultIterations = 2000;
const int _defaultOpenFds = 512;
const int _defaultMutations = 200;
const int _warmupIterations = 50;
const int _socketChunkSize = 64;
const int _socketIovSize = 32;
const String _allDistributions = 'all';
const String _baselineDistribution = 'baseline';
const List<String> _benchmarkDistributions = <String>[
  _baselineDistribution,
  'directory-heavy',
  'descriptor-heavy',
  'socket-heavy',
];

const Map<String, _DistributionDefaults> _distributionDefaults =
    <String, _DistributionDefaults>{
      _baselineDistribution: _DistributionDefaults(
        directories: _defaultDirectories,
        filesPerDirectory: _defaultFilesPerDirectory,
        iterations: _defaultIterations,
        openFds: _defaultOpenFds,
        mutations: _defaultMutations,
      ),
      'directory-heavy': _DistributionDefaults(
        directories: 128,
        filesPerDirectory: 64,
        iterations: _defaultIterations,
        openFds: _defaultOpenFds,
        mutations: _defaultMutations,
      ),
      'descriptor-heavy': _DistributionDefaults(
        directories: _defaultDirectories,
        filesPerDirectory: _defaultFilesPerDirectory,
        iterations: 1000,
        openFds: 2048,
        mutations: _defaultMutations,
      ),
      'socket-heavy': _DistributionDefaults(
        directories: _defaultDirectories,
        filesPerDirectory: _defaultFilesPerDirectory,
        iterations: 8000,
        openFds: _defaultOpenFds,
        mutations: _defaultMutations,
      ),
    };

void main(List<String> args) {
  final options = _Options.parse(args);
  if (options.help) {
    _printUsage();
    return;
  }

  final payload = options.distribution == _allDistributions
      ? <String, Object?>{
          'distribution': _allDistributions,
          'runs': {
            for (final distribution in _benchmarkDistributions)
              distribution: _runBenchmark(
                options.withDistribution(distribution),
              ),
          },
        }
      : _runBenchmark(options);

  if (options.json) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(payload));
  } else {
    _printText(payload);
  }
}

Map<String, Object?> _runBenchmark(_Options options) {
  final baselineFiles = _buildFiles(
    directories: options.directories,
    filesPerDirectory: options.filesPerDirectory,
  );
  _runWarmup(baselineFiles, options);

  final pathOpen = _benchmarkPathOpenClose(baselineFiles, options);
  final readdir = _benchmarkReaddir(baselineFiles, options);
  final rights = _benchmarkRightsChecks(baselineFiles, options);
  final mutations = _benchmarkMutations(baselineFiles, options);
  final fileRenumberClose = _benchmarkFileRenumberClose(baselineFiles, options);
  final fileFdReadWrite = _benchmarkFileFdReadWrite(options);
  final directoryRenumberClose = _benchmarkDirectoryRenumberClose(options);
  final socketRecvPeek = _benchmarkSocketRecvPeek(options);
  final socketRecvWaitall = _benchmarkSocketRecvWaitall(options);
  final socketSendRecv = _benchmarkSocketSendRecv(options);
  final socketSendErrorPreflight = _benchmarkSocketSendErrorPreflight(options);
  final socketStreamZeroSend = _benchmarkSocketStreamZeroSend(options);
  final socketShutdownPreflight = _benchmarkSocketShutdownPreflight(options);
  final socketFdReadWrite = _benchmarkSocketFdReadWrite(options);
  final socketDgramTruncation = _benchmarkSocketDatagramTruncation(options);
  final socketDatagramRights = _benchmarkSocketDatagramRights(options);
  final socketConnectedRights = _benchmarkSocketConnectedRights(options);
  final socketFdflagPreflight = _benchmarkSocketFdflagPreflight(options);
  final socketFileRightsPreflight = _benchmarkSocketFileRightsPreflight(
    options,
  );
  final socketPositionedRightsPreflight =
      _benchmarkSocketPositionedRightsPreflight(options);
  final socketPollReadiness = _benchmarkSocketPollReadiness(options);
  final socketRenumberClose = _benchmarkSocketRenumberClose(options);
  final socketAcceptInheritance = _benchmarkSocketAcceptInheritance(options);
  final socketAcceptReceiveShutdown = _benchmarkSocketAcceptReceiveShutdown(
    options,
  );

  final payload = <String, Object?>{
    'distribution': options.distribution,
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
    'file_renumber_close': fileRenumberClose.toJson(),
    'file_fd_read_write': fileFdReadWrite.toJson(),
    'directory_renumber_close': directoryRenumberClose.toJson(),
    'socket_recv_peek': socketRecvPeek.toJson(),
    'socket_recv_waitall': socketRecvWaitall.toJson(),
    'socket_send_recv': socketSendRecv.toJson(),
    'socket_send_error_preflight': socketSendErrorPreflight.toJson(),
    'socket_stream_zero_send': socketStreamZeroSend.toJson(),
    'socket_shutdown_preflight': socketShutdownPreflight.toJson(),
    'socket_fd_read_write': socketFdReadWrite.toJson(),
    'socket_dgram_truncation': socketDgramTruncation.toJson(),
    'socket_datagram_rights': socketDatagramRights.toJson(),
    'socket_connected_rights': socketConnectedRights.toJson(),
    'socket_fdflag_preflight': socketFdflagPreflight.toJson(),
    'socket_file_rights_preflight': socketFileRightsPreflight.toJson(),
    'socket_positioned_rights_preflight': socketPositionedRightsPreflight
        .toJson(),
    'socket_poll_readiness': socketPollReadiness.toJson(),
    'socket_renumber_close': socketRenumberClose.toJson(),
    'socket_accept_inheritance': socketAcceptInheritance.toJson(),
    'socket_accept_receive_shutdown': socketAcceptReceiveShutdown.toJson(),
  };
  return payload;
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
  _benchmarkFileRenumberClose(files, warmupOptions);
  _benchmarkFileFdReadWrite(warmupOptions);
  _benchmarkDirectoryRenumberClose(warmupOptions);
  _benchmarkSocketRecvPeek(warmupOptions);
  _benchmarkSocketRecvWaitall(warmupOptions);
  _benchmarkSocketSendRecv(warmupOptions);
  _benchmarkSocketStreamZeroSend(warmupOptions);
  _benchmarkSocketShutdownPreflight(warmupOptions);
  _benchmarkSocketDatagramTruncation(warmupOptions);
  _benchmarkSocketConnectedRights(warmupOptions);
  _benchmarkSocketFdflagPreflight(warmupOptions);
  _benchmarkSocketFileRightsPreflight(warmupOptions);
  _benchmarkSocketPositionedRightsPreflight(warmupOptions);
  _benchmarkSocketPollReadiness(warmupOptions);
  _benchmarkSocketRenumberClose(warmupOptions);
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

_Metric _benchmarkFileRenumberClose(
  Map<String, Uint8List> files,
  _Options options,
) {
  final vfs = _newVfs(files);
  final paths = files.keys.toList(growable: false);
  final sourceFds = <int>[];
  final targetFds = <int>[];
  for (var i = 0; i < options.iterations; i++) {
    sourceFds.add(
      _openBenchmarkPath(
        vfs,
        paths[i % paths.length],
        label: 'file renumber source',
      ),
    );
    targetFds.add(
      _openBenchmarkPath(
        vfs,
        paths[(i + options.iterations) % paths.length],
        label: 'file renumber target',
      ),
    );
  }

  var successfulOperations = 0;
  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final toFd = targetFds[i];
    final result = vfs.renumberDescriptor(fromFd: sourceFds[i], toFd: toFd);
    if (result != Preview1FdRenumberResult.success) {
      throw StateError('file renumber failed at iteration $i: $result');
    }
    successfulOperations++;
    if (!vfs.close(toFd)) {
      throw StateError('file close failed at iteration $i');
    }
    successfulOperations++;
    checksum += toFd;
  }
  watch.stop();
  return _Metric(
    operations: successfulOperations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkFileFdReadWrite(_Options options) {
  final vfs = _newVfs({
    '/sandbox/data.bin': Uint8List.fromList(
      List<int>.generate(_socketChunkSize, (index) => index & 0xff),
    ),
  });
  final fd = _openBenchmarkPath(
    vfs,
    '/sandbox/data.bin',
    label: 'file fd read/write',
  );
  final opened = vfs.openFileForFd(fd);
  if (opened == null) {
    throw StateError('file descriptor missing for fd read/write benchmark');
  }

  final bytes = Uint8List(384);
  final data = ByteData.view(bytes.buffer);
  const readIovPtr = 0;
  const readFirstBufferPtr = 32;
  const readSecondBufferPtr = 96;
  const writeIovPtr = 160;
  const writeFirstBufferPtr = 192;
  const writeSecondBufferPtr = 256;
  const countPtr = 320;
  _writeTwoIovs(
    data: data,
    iovPtr: readIovPtr,
    firstBufferPtr: readFirstBufferPtr,
    firstLength: _socketIovSize,
    secondBufferPtr: readSecondBufferPtr,
    secondLength: _socketIovSize,
  );
  _writeTwoIovs(
    data: data,
    iovPtr: writeIovPtr,
    firstBufferPtr: writeFirstBufferPtr,
    firstLength: _socketIovSize,
    secondBufferPtr: writeSecondBufferPtr,
    secondLength: _socketIovSize,
  );
  for (var i = 0; i < _socketIovSize; i++) {
    bytes[writeFirstBufferPtr + i] = (i + 1) & 0xff;
    bytes[writeSecondBufferPtr + i] = (i + 1 + _socketIovSize) & 0xff;
  }

  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final readErrno = readOpenFileIntoIov(
      opened: opened,
      bytes: bytes,
      data: data,
      iovs: readIovPtr,
      iovsLen: 2,
      nreadPtr: countPtr,
      fileOffset: 0,
    );
    if (readErrno != errnoSuccess) {
      throw StateError('file fd_read failed at iteration $i: $readErrno');
    }
    checksum += data.getUint32(countPtr, Endian.little);

    final writeErrno = writeOpenFileFromIov(
      opened: opened,
      bytes: bytes,
      data: data,
      iovs: writeIovPtr,
      iovsLen: 2,
      nwrittenPtr: countPtr,
      fileOffset: 0,
    );
    if (writeErrno != errnoSuccess) {
      throw StateError('file fd_write failed at iteration $i: $writeErrno');
    }
    checksum += data.getUint32(countPtr, Endian.little);
  }
  watch.stop();
  return _Metric(
    operations: options.iterations * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkDirectoryRenumberClose(_Options options) {
  final vfs = _newVfs(
    _buildFiles(
      directories: options.directories,
      filesPerDirectory: options.filesPerDirectory,
    ),
  );
  final sourceFds = <int>[];
  final targetFds = <int>[];
  for (var i = 0; i < options.iterations; i++) {
    sourceFds.add(
      _openBenchmarkPath(
        vfs,
        '/sandbox/dir${i % options.directories}',
        label: 'directory renumber source',
      ),
    );
    targetFds.add(
      _openBenchmarkPath(
        vfs,
        '/sandbox/dir${(i + 1) % options.directories}',
        label: 'directory renumber target',
      ),
    );
  }

  var successfulOperations = 0;
  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final toFd = targetFds[i];
    final result = vfs.renumberDescriptor(fromFd: sourceFds[i], toFd: toFd);
    if (result != Preview1FdRenumberResult.success) {
      throw StateError('directory renumber failed at iteration $i: $result');
    }
    successfulOperations++;
    if (!vfs.close(toFd)) {
      throw StateError('directory close failed at iteration $i');
    }
    successfulOperations++;
    checksum += toFd;
  }
  watch.stop();
  return _Metric(
    operations: successfulOperations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkSocketRecvPeek(_Options options) {
  final socket = WASIPreview1Socket(
    receiveData: List<int>.generate(_socketChunkSize, (index) => index & 0xff),
  );
  final vfs = Preview1VirtualFileSystem(sockets: {64: socket});
  final descriptor = vfs.socketForFd(64);
  if (descriptor == null) {
    throw StateError('socket descriptor missing for peek benchmark');
  }
  final bytes = Uint8List(256);
  final data = ByteData.view(bytes.buffer);
  const iovPtr = 0;
  const firstBufferPtr = 32;
  const secondBufferPtr = 96;
  const countPtr = 160;
  const flagsPtr = 168;
  _writeTwoIovs(
    data: data,
    iovPtr: iovPtr,
    firstBufferPtr: firstBufferPtr,
    firstLength: _socketIovSize,
    secondBufferPtr: secondBufferPtr,
    secondLength: _socketIovSize,
  );

  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final errno = readSocketIntoIov(
      socket: descriptor,
      bytes: bytes,
      data: data,
      iovs: iovPtr,
      iovsLen: 2,
      flags: riflagRecvPeek,
      nreadPtr: countPtr,
      roFlagsPtr: flagsPtr,
    );
    if (errno != errnoSuccess) {
      throw StateError('socket recv peek failed at iteration $i: $errno');
    }
    checksum += data.getUint32(countPtr, Endian.little);
  }
  watch.stop();
  return _Metric(
    operations: options.iterations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkSocketRecvWaitall(_Options options) {
  final satisfiedSocket = WASIPreview1Socket(
    receiveData: List<int>.generate(
      options.iterations * _socketChunkSize,
      (index) => index & 0xff,
    ),
  );
  final againSocket = WASIPreview1Socket(
    receiveData: List<int>.generate(_socketChunkSize - 1, (index) => index),
  );
  var hostReceiveByte = 0;
  final hostChunkedSocket = WASIPreview1Socket(
    receiveDataProvider: (maxBytes) {
      if (maxBytes <= 0) {
        return const <int>[];
      }
      final chunkLength = maxBytes < 8 ? maxBytes : 8;
      final start = hostReceiveByte;
      hostReceiveByte += chunkLength;
      return List<int>.generate(chunkLength, (index) => (start + index) & 0xff);
    },
  );
  final vfs = Preview1VirtualFileSystem(
    sockets: {64: satisfiedSocket, 65: againSocket, 66: hostChunkedSocket},
  );
  final satisfiedDescriptor = vfs.socketForFd(64);
  final againDescriptor = vfs.socketForFd(65);
  final hostChunkedDescriptor = vfs.socketForFd(66);
  if (satisfiedDescriptor == null ||
      againDescriptor == null ||
      hostChunkedDescriptor == null) {
    throw StateError('socket descriptor missing for waitall benchmark');
  }
  final bytes = Uint8List(256);
  final data = ByteData.view(bytes.buffer);
  const iovPtr = 0;
  const firstBufferPtr = 32;
  const secondBufferPtr = 96;
  const countPtr = 160;
  const flagsPtr = 168;
  _writeTwoIovs(
    data: data,
    iovPtr: iovPtr,
    firstBufferPtr: firstBufferPtr,
    firstLength: _socketIovSize,
    secondBufferPtr: secondBufferPtr,
    secondLength: _socketIovSize,
  );

  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final satisfiedErrno = readSocketIntoIov(
      socket: satisfiedDescriptor,
      bytes: bytes,
      data: data,
      iovs: iovPtr,
      iovsLen: 2,
      flags: riflagRecvWaitall,
      nreadPtr: countPtr,
      roFlagsPtr: flagsPtr,
    );
    if (satisfiedErrno != errnoSuccess) {
      throw StateError(
        'socket waitall satisfied recv failed at iteration $i: '
        '$satisfiedErrno',
      );
    }
    checksum += data.getUint32(countPtr, Endian.little);
    final againErrno = readSocketIntoIov(
      socket: againDescriptor,
      bytes: bytes,
      data: data,
      iovs: iovPtr,
      iovsLen: 2,
      flags: riflagRecvWaitall,
      nreadPtr: countPtr,
      roFlagsPtr: flagsPtr,
    );
    if (againErrno != errnoAgain) {
      throw StateError(
        'socket waitall again recv failed at iteration $i: $againErrno',
      );
    }
    checksum += againErrno;
    final hostChunkedErrno = readSocketIntoIov(
      socket: hostChunkedDescriptor,
      bytes: bytes,
      data: data,
      iovs: iovPtr,
      iovsLen: 2,
      flags: riflagRecvWaitall,
      nreadPtr: countPtr,
      roFlagsPtr: flagsPtr,
    );
    if (hostChunkedErrno != errnoSuccess) {
      throw StateError(
        'socket waitall host chunked recv failed at iteration $i: '
        '$hostChunkedErrno',
      );
    }
    checksum += data.getUint32(countPtr, Endian.little);
  }
  watch.stop();
  return _Metric(
    operations: options.iterations * 3,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkSocketSendRecv(_Options options) {
  final socket = WASIPreview1Socket(
    receiveData: List<int>.generate(
      options.iterations * _socketChunkSize,
      (index) => index & 0xff,
    ),
  );
  final blockedSocket = WASIPreview1Socket(writeReady: false);
  final emptyStreamSocket = WASIPreview1Socket();
  final emptyDatagramSocket = WASIPreview1Socket.datagram();
  var hostReceiveByte = 0;
  var hostSentBytes = 0;
  final hostSocket = WASIPreview1Socket(
    receiveDataProvider: (maxBytes) {
      final chunk = Uint8List(maxBytes);
      for (var i = 0; i < maxBytes; i++) {
        chunk[i] = (hostReceiveByte + i) & 0xff;
      }
      hostReceiveByte += maxBytes;
      return chunk;
    },
    sendHandler: (source, start, length) {
      hostSentBytes += length;
      return length;
    },
  );
  final vfs = Preview1VirtualFileSystem(
    sockets: {
      64: socket,
      65: blockedSocket,
      66: hostSocket,
      67: emptyStreamSocket,
      68: emptyDatagramSocket,
    },
  );
  final descriptor = vfs.socketForFd(64);
  final blockedDescriptor = vfs.socketForFd(65);
  final hostDescriptor = vfs.socketForFd(66);
  final emptyStreamDescriptor = vfs.socketForFd(67);
  final emptyDatagramDescriptor = vfs.socketForFd(68);
  if (descriptor == null ||
      blockedDescriptor == null ||
      hostDescriptor == null ||
      emptyStreamDescriptor == null ||
      emptyDatagramDescriptor == null) {
    throw StateError('socket descriptor missing for send/recv benchmark');
  }
  final bytes = Uint8List(384);
  final data = ByteData.view(bytes.buffer);
  const recvIovPtr = 0;
  const recvFirstBufferPtr = 32;
  const recvSecondBufferPtr = 96;
  const sendIovPtr = 160;
  const sendFirstBufferPtr = 192;
  const sendSecondBufferPtr = 256;
  const countPtr = 320;
  const flagsPtr = 328;
  _writeTwoIovs(
    data: data,
    iovPtr: recvIovPtr,
    firstBufferPtr: recvFirstBufferPtr,
    firstLength: _socketIovSize,
    secondBufferPtr: recvSecondBufferPtr,
    secondLength: _socketIovSize,
  );
  _writeTwoIovs(
    data: data,
    iovPtr: sendIovPtr,
    firstBufferPtr: sendFirstBufferPtr,
    firstLength: _socketIovSize,
    secondBufferPtr: sendSecondBufferPtr,
    secondLength: _socketIovSize,
  );
  for (var i = 0; i < _socketIovSize; i++) {
    bytes[sendFirstBufferPtr + i] = i & 0xff;
    bytes[sendSecondBufferPtr + i] = (i + _socketIovSize) & 0xff;
  }

  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final recvErrno = readSocketIntoIov(
      socket: descriptor,
      bytes: bytes,
      data: data,
      iovs: recvIovPtr,
      iovsLen: 2,
      flags: 0,
      nreadPtr: countPtr,
      roFlagsPtr: flagsPtr,
    );
    if (recvErrno != errnoSuccess) {
      throw StateError('socket recv failed at iteration $i: $recvErrno');
    }
    checksum += data.getUint32(countPtr, Endian.little);
    final sendErrno = writeSocketFromIov(
      socket: descriptor,
      bytes: bytes,
      data: data,
      iovs: sendIovPtr,
      iovsLen: 2,
      nwrittenPtr: countPtr,
    );
    if (sendErrno != errnoSuccess) {
      throw StateError('socket send failed at iteration $i: $sendErrno');
    }
    checksum += data.getUint32(countPtr, Endian.little);

    data.setUint32(countPtr, 0x7fffffff, Endian.little);
    final blockedErrno = writeSocketFromIov(
      socket: blockedDescriptor,
      bytes: bytes,
      data: data,
      iovs: sendIovPtr,
      iovsLen: 2,
      nwrittenPtr: countPtr,
    );
    if (blockedErrno != errnoAgain) {
      throw StateError(
        'socket blocked send failed at iteration $i: $blockedErrno',
      );
    }
    if (data.getUint32(countPtr, Endian.little) != 0x7fffffff ||
        blockedSocket.sentData.isNotEmpty) {
      throw StateError('socket blocked send wrote data at iteration $i');
    }
    checksum += blockedErrno;

    data.setUint32(countPtr, 0x7fffffff, Endian.little);
    data.setUint16(flagsPtr, 0x7fff, Endian.little);
    final emptyStreamErrno = readSocketIntoIov(
      socket: emptyStreamDescriptor,
      bytes: bytes,
      data: data,
      iovs: recvIovPtr,
      iovsLen: 2,
      flags: 0,
      nreadPtr: countPtr,
      roFlagsPtr: flagsPtr,
    );
    if (emptyStreamErrno != errnoAgain ||
        data.getUint32(countPtr, Endian.little) != 0x7fffffff ||
        data.getUint16(flagsPtr, Endian.little) != 0x7fff) {
      throw StateError(
        'empty stream recv did not block at iteration $i: '
        '$emptyStreamErrno',
      );
    }
    checksum += emptyStreamErrno;

    final emptyDatagramErrno = readSocketIntoIov(
      socket: emptyDatagramDescriptor,
      bytes: bytes,
      data: data,
      iovs: recvIovPtr,
      iovsLen: 2,
      flags: 0,
      nreadPtr: countPtr,
      roFlagsPtr: flagsPtr,
    );
    if (emptyDatagramErrno != errnoAgain ||
        data.getUint32(countPtr, Endian.little) != 0x7fffffff ||
        data.getUint16(flagsPtr, Endian.little) != 0x7fff) {
      throw StateError(
        'empty datagram recv did not block at iteration $i: '
        '$emptyDatagramErrno',
      );
    }
    checksum += emptyDatagramErrno;

    final hostRecvErrno = readSocketIntoIov(
      socket: hostDescriptor,
      bytes: bytes,
      data: data,
      iovs: recvIovPtr,
      iovsLen: 2,
      flags: riflagRecvWaitall,
      nreadPtr: countPtr,
      roFlagsPtr: flagsPtr,
    );
    if (hostRecvErrno != errnoSuccess) {
      throw StateError(
        'host socket recv failed at iteration $i: $hostRecvErrno',
      );
    }
    checksum += data.getUint32(countPtr, Endian.little);

    final hostSendErrno = writeSocketFromIov(
      socket: hostDescriptor,
      bytes: bytes,
      data: data,
      iovs: sendIovPtr,
      iovsLen: 2,
      nwrittenPtr: countPtr,
    );
    if (hostSendErrno != errnoSuccess) {
      throw StateError(
        'host socket send failed at iteration $i: $hostSendErrno',
      );
    }
    checksum += data.getUint32(countPtr, Endian.little);
  }
  watch.stop();
  return _Metric(
    operations: options.iterations * 7,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum + hostReceiveByte + hostSentBytes,
  );
}

_Metric _benchmarkSocketFdReadWrite(_Options options) {
  final socket = WASIPreview1Socket(
    receiveData: List<int>.generate(
      options.iterations * _socketChunkSize,
      (index) => index & 0xff,
    ),
  );
  final emptySocket = WASIPreview1Socket();
  final blockedSocket = WASIPreview1Socket(writeReady: false);
  final vfs = Preview1VirtualFileSystem(
    sockets: {64: socket, 65: emptySocket, 66: blockedSocket},
  );
  final descriptor = vfs.socketForFd(64);
  final emptyDescriptor = vfs.socketForFd(65);
  final blockedDescriptor = vfs.socketForFd(66);
  if (descriptor == null ||
      emptyDescriptor == null ||
      blockedDescriptor == null) {
    throw StateError('socket descriptor missing for fd read/write benchmark');
  }

  final bytes = Uint8List(384);
  final data = ByteData.view(bytes.buffer);
  const readIovPtr = 0;
  const readFirstBufferPtr = 32;
  const readSecondBufferPtr = 96;
  const writeIovPtr = 160;
  const writeFirstBufferPtr = 192;
  const writeSecondBufferPtr = 256;
  const countPtr = 320;
  _writeTwoIovs(
    data: data,
    iovPtr: readIovPtr,
    firstBufferPtr: readFirstBufferPtr,
    firstLength: _socketIovSize,
    secondBufferPtr: readSecondBufferPtr,
    secondLength: _socketIovSize,
  );
  _writeTwoIovs(
    data: data,
    iovPtr: writeIovPtr,
    firstBufferPtr: writeFirstBufferPtr,
    firstLength: _socketIovSize,
    secondBufferPtr: writeSecondBufferPtr,
    secondLength: _socketIovSize,
  );
  for (var i = 0; i < _socketIovSize; i++) {
    bytes[writeFirstBufferPtr + i] = i & 0xff;
    bytes[writeSecondBufferPtr + i] = (i + _socketIovSize) & 0xff;
  }

  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final readErrno = readSocketIntoIov(
      socket: descriptor,
      bytes: bytes,
      data: data,
      iovs: readIovPtr,
      iovsLen: 2,
      flags: 0,
      nreadPtr: countPtr,
      roFlagsPtr: null,
    );
    if (readErrno != errnoSuccess) {
      throw StateError('socket fd_read failed at iteration $i: $readErrno');
    }
    checksum += data.getUint32(countPtr, Endian.little);

    final writeErrno = writeSocketFromIov(
      socket: descriptor,
      bytes: bytes,
      data: data,
      iovs: writeIovPtr,
      iovsLen: 2,
      nwrittenPtr: countPtr,
    );
    if (writeErrno != errnoSuccess) {
      throw StateError('socket fd_write failed at iteration $i: $writeErrno');
    }
    checksum += data.getUint32(countPtr, Endian.little);

    data.setUint32(countPtr, 0x7fffffff, Endian.little);
    final emptyReadErrno = readSocketIntoIov(
      socket: emptyDescriptor,
      bytes: bytes,
      data: data,
      iovs: readIovPtr,
      iovsLen: 2,
      flags: 0,
      nreadPtr: countPtr,
      roFlagsPtr: null,
    );
    if (emptyReadErrno != errnoAgain ||
        data.getUint32(countPtr, Endian.little) != 0x7fffffff) {
      throw StateError(
        'socket fd_read empty stream wrote output at iteration $i: '
        '$emptyReadErrno',
      );
    }
    checksum += emptyReadErrno;

    data.setUint32(countPtr, 0x7fffffff, Endian.little);
    final blockedWriteErrno = writeSocketFromIov(
      socket: blockedDescriptor,
      bytes: bytes,
      data: data,
      iovs: writeIovPtr,
      iovsLen: 2,
      nwrittenPtr: countPtr,
    );
    if (blockedWriteErrno != errnoAgain ||
        data.getUint32(countPtr, Endian.little) != 0x7fffffff ||
        blockedSocket.sentData.isNotEmpty) {
      throw StateError(
        'socket fd_write blocked stream wrote output at iteration $i: '
        '$blockedWriteErrno',
      );
    }
    checksum += blockedWriteErrno;
  }
  watch.stop();
  return _Metric(
    operations: options.iterations * 4,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkSocketSendErrorPreflight(_Options options) {
  final shutdownStream = WASIPreview1Socket();
  final shutdownDatagram = WASIPreview1Socket.datagram();
  final blockedStream = WASIPreview1Socket(writeReady: false);
  shutdownStream.shutdown(receive: false, send: true);
  shutdownDatagram.shutdown(receive: false, send: true);
  final vfs = Preview1VirtualFileSystem(
    sockets: {64: shutdownStream, 65: shutdownDatagram, 66: blockedStream},
  );
  final shutdownStreamDescriptor = vfs.socketForFd(64);
  final shutdownDatagramDescriptor = vfs.socketForFd(65);
  final blockedStreamDescriptor = vfs.socketForFd(66);
  if (shutdownStreamDescriptor == null ||
      shutdownDatagramDescriptor == null ||
      blockedStreamDescriptor == null) {
    throw StateError('socket descriptor missing for send preflight benchmark');
  }

  final bytes = Uint8List(128);
  final data = ByteData.view(bytes.buffer);
  const iovPtr = 0;
  const bufferPtr = 32;
  const countPtr = 96;
  final invalidBufferPtr = bytes.length - 2;
  bytes.setAll(bufferPtr, [1, 2, 3, 4]);

  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    data.setUint32(iovPtr, invalidBufferPtr, Endian.little);
    data.setUint32(iovPtr + 4, 4, Endian.little);

    data.setUint32(countPtr, 0x7fffffff, Endian.little);
    final invalidShutdownStreamErrno = writeSocketFromIov(
      socket: shutdownStreamDescriptor,
      bytes: bytes,
      data: data,
      iovs: iovPtr,
      iovsLen: 1,
      nwrittenPtr: countPtr,
    );
    if (invalidShutdownStreamErrno != errnoInval ||
        data.getUint32(countPtr, Endian.little) != 0x7fffffff) {
      throw StateError(
        'shutdown stream send preflight failed at iteration $i: '
        '$invalidShutdownStreamErrno',
      );
    }
    checksum += invalidShutdownStreamErrno;

    data.setUint32(countPtr, 0x7fffffff, Endian.little);
    final invalidShutdownDatagramErrno = writeSocketFromIov(
      socket: shutdownDatagramDescriptor,
      bytes: bytes,
      data: data,
      iovs: iovPtr,
      iovsLen: 1,
      nwrittenPtr: countPtr,
    );
    if (invalidShutdownDatagramErrno != errnoInval ||
        data.getUint32(countPtr, Endian.little) != 0x7fffffff) {
      throw StateError(
        'shutdown datagram send preflight failed at iteration $i: '
        '$invalidShutdownDatagramErrno',
      );
    }
    checksum += invalidShutdownDatagramErrno;

    data.setUint32(countPtr, 0x7fffffff, Endian.little);
    final invalidBlockedStreamErrno = writeSocketFromIov(
      socket: blockedStreamDescriptor,
      bytes: bytes,
      data: data,
      iovs: iovPtr,
      iovsLen: 1,
      nwrittenPtr: countPtr,
    );
    if (invalidBlockedStreamErrno != errnoInval ||
        data.getUint32(countPtr, Endian.little) != 0x7fffffff) {
      throw StateError(
        'blocked stream send preflight failed at iteration $i: '
        '$invalidBlockedStreamErrno',
      );
    }
    checksum += invalidBlockedStreamErrno;

    data.setUint32(iovPtr, bufferPtr, Endian.little);
    data.setUint32(iovPtr + 4, 4, Endian.little);

    data.setUint32(countPtr, 0x7fffffff, Endian.little);
    final shutdownStreamErrno = writeSocketFromIov(
      socket: shutdownStreamDescriptor,
      bytes: bytes,
      data: data,
      iovs: iovPtr,
      iovsLen: 1,
      nwrittenPtr: countPtr,
    );
    if (shutdownStreamErrno != errnoPipe ||
        data.getUint32(countPtr, Endian.little) != 0x7fffffff) {
      throw StateError(
        'shutdown stream send errno failed at iteration $i: '
        '$shutdownStreamErrno',
      );
    }
    checksum += shutdownStreamErrno;

    data.setUint32(countPtr, 0x7fffffff, Endian.little);
    final shutdownDatagramErrno = writeSocketFromIov(
      socket: shutdownDatagramDescriptor,
      bytes: bytes,
      data: data,
      iovs: iovPtr,
      iovsLen: 1,
      nwrittenPtr: countPtr,
    );
    if (shutdownDatagramErrno != errnoPipe ||
        data.getUint32(countPtr, Endian.little) != 0x7fffffff) {
      throw StateError(
        'shutdown datagram send errno failed at iteration $i: '
        '$shutdownDatagramErrno',
      );
    }
    checksum += shutdownDatagramErrno;

    data.setUint32(countPtr, 0x7fffffff, Endian.little);
    final blockedStreamErrno = writeSocketFromIov(
      socket: blockedStreamDescriptor,
      bytes: bytes,
      data: data,
      iovs: iovPtr,
      iovsLen: 1,
      nwrittenPtr: countPtr,
    );
    if (blockedStreamErrno != errnoAgain ||
        data.getUint32(countPtr, Endian.little) != 0x7fffffff) {
      throw StateError(
        'blocked stream send errno failed at iteration $i: '
        '$blockedStreamErrno',
      );
    }
    checksum += blockedStreamErrno;
  }
  watch.stop();
  if (shutdownStream.sentData.isNotEmpty ||
      shutdownDatagram.sentMessages.isNotEmpty ||
      blockedStream.sentData.isNotEmpty) {
    throw StateError('socket send preflight wrote data');
  }
  return _Metric(
    operations: options.iterations * 6,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkSocketStreamZeroSend(_Options options) {
  final blockedStream = WASIPreview1Socket(writeReady: false);
  final vfs = Preview1VirtualFileSystem(sockets: {64: blockedStream});
  final descriptor = vfs.socketForFd(64);
  if (descriptor == null) {
    throw StateError('socket descriptor missing for zero-send benchmark');
  }

  final bytes = Uint8List(64);
  final data = ByteData.view(bytes.buffer);
  const iovPtr = 0;
  const bufferPtr = 32;
  const countPtr = 48;
  data.setUint32(iovPtr, bufferPtr, Endian.little);
  data.setUint32(iovPtr + 4, 0, Endian.little);

  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    data.setUint32(countPtr, 0x7fffffff, Endian.little);
    final errno = writeSocketFromIov(
      socket: descriptor,
      bytes: bytes,
      data: data,
      iovs: iovPtr,
      iovsLen: 1,
      nwrittenPtr: countPtr,
    );
    if (errno != errnoSuccess ||
        data.getUint32(countPtr, Endian.little) != 0 ||
        blockedStream.sentData.isNotEmpty) {
      throw StateError('stream zero-send failed at iteration $i: errno=$errno');
    }
    checksum++;
  }
  watch.stop();
  return _Metric(
    operations: options.iterations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkSocketShutdownPreflight(_Options options) {
  final shutdownSocket = WASIPreview1Socket();
  final rightlessSocket = WASIPreview1Socket();
  final vfs = Preview1VirtualFileSystem(
    sockets: {64: shutdownSocket, 65: rightlessSocket},
  );
  final rightsResult = vfs.setDescriptorRights(
    fd: 65,
    rightsBase: 0,
    rightsInheriting: 0,
  );
  if (rightsResult != Preview1FdRightsResult.success) {
    throw StateError('socket shutdown benchmark rights setup failed');
  }

  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final invalidMissingErrno = preview1SockShutdown(vfs: vfs, fd: 999, how: 8);
    if (invalidMissingErrno != errnoInval) {
      throw StateError(
        'shutdown invalid missing-fd preflight failed at iteration $i: '
        '$invalidMissingErrno',
      );
    }
    checksum += invalidMissingErrno;

    final invalidNonSocketErrno = preview1SockShutdown(vfs: vfs, fd: 1, how: 8);
    if (invalidNonSocketErrno != errnoInval) {
      throw StateError(
        'shutdown invalid non-socket preflight failed at iteration $i: '
        '$invalidNonSocketErrno',
      );
    }
    checksum += invalidNonSocketErrno;

    final invalidRightlessErrno = preview1SockShutdown(
      vfs: vfs,
      fd: 65,
      how: 8,
    );
    if (invalidRightlessErrno != errnoInval) {
      throw StateError(
        'shutdown invalid rightless preflight failed at iteration $i: '
        '$invalidRightlessErrno',
      );
    }
    checksum += invalidRightlessErrno;

    final rightlessErrno = preview1SockShutdown(vfs: vfs, fd: 65, how: 1);
    if (rightlessErrno != errnoNotcapable) {
      throw StateError(
        'shutdown rightless errno failed at iteration $i: $rightlessErrno',
      );
    }
    checksum += rightlessErrno;

    final successErrno = preview1SockShutdown(vfs: vfs, fd: 64, how: 1);
    if (successErrno != errnoSuccess) {
      throw StateError(
        'shutdown success failed at iteration $i: $successErrno',
      );
    }
    checksum += successErrno;
  }
  watch.stop();
  if (!shutdownSocket.receiveShutdown || shutdownSocket.sendShutdown) {
    throw StateError('socket shutdown benchmark mutated wrong shutdown state');
  }
  if (rightlessSocket.receiveShutdown || rightlessSocket.sendShutdown) {
    throw StateError('socket shutdown rightless path mutated socket state');
  }
  return _Metric(
    operations: options.iterations * 5,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkSocketDatagramTruncation(_Options options) {
  final socket = WASIPreview1Socket.datagram(
    receiveMessages: List<List<int>>.generate(
      options.iterations,
      (index) => List<int>.generate(
        _socketChunkSize,
        (byteIndex) => (index + byteIndex) & 0xff,
      ),
    ),
  );
  var hostReceiveByte = 0;
  var hostSentBytes = 0;
  final hostSocket = WASIPreview1Socket.datagram(
    receiveMessageProvider: () {
      final message = Uint8List(_socketIovSize);
      for (var i = 0; i < message.length; i++) {
        message[i] = (hostReceiveByte + i) & 0xff;
      }
      hostReceiveByte += message.length;
      return message;
    },
    sendMessageHandler: (message) {
      hostSentBytes += message.length;
      return message.length;
    },
  );
  final vfs = Preview1VirtualFileSystem(sockets: {64: socket, 65: hostSocket});
  final descriptor = vfs.socketForFd(64);
  final hostDescriptor = vfs.socketForFd(65);
  if (descriptor == null || hostDescriptor == null) {
    throw StateError('socket descriptor missing for datagram benchmark');
  }
  final bytes = Uint8List(128);
  final data = ByteData.view(bytes.buffer);
  const iovPtr = 0;
  const bufferPtr = 32;
  const countPtr = 96;
  const flagsPtr = 104;
  data.setUint32(iovPtr, bufferPtr, Endian.little);
  data.setUint32(iovPtr + 4, _socketIovSize, Endian.little);

  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final errno = readSocketIntoIov(
      socket: descriptor,
      bytes: bytes,
      data: data,
      iovs: iovPtr,
      iovsLen: 1,
      flags: 0,
      nreadPtr: countPtr,
      roFlagsPtr: flagsPtr,
    );
    if (errno != errnoSuccess) {
      throw StateError('socket datagram recv failed at iteration $i: $errno');
    }
    final roflags = data.getUint16(flagsPtr, Endian.little);
    if (roflags != roflagRecvDataTruncated) {
      throw StateError('socket datagram truncation missing at iteration $i');
    }
    checksum += data.getUint32(countPtr, Endian.little) + roflags;

    final defaultSendErrno = writeSocketFromIov(
      socket: descriptor,
      bytes: bytes,
      data: data,
      iovs: iovPtr,
      iovsLen: 1,
      nwrittenPtr: countPtr,
    );
    if (defaultSendErrno != errnoSuccess) {
      throw StateError(
        'default datagram send failed at iteration $i: $defaultSendErrno',
      );
    }
    if (data.getUint32(countPtr, Endian.little) != _socketIovSize) {
      throw StateError('default datagram send mismatch at iteration $i');
    }
    checksum += data.getUint32(countPtr, Endian.little);

    final hostRecvErrno = readSocketIntoIov(
      socket: hostDescriptor,
      bytes: bytes,
      data: data,
      iovs: iovPtr,
      iovsLen: 1,
      flags: 0,
      nreadPtr: countPtr,
      roFlagsPtr: flagsPtr,
    );
    if (hostRecvErrno != errnoSuccess) {
      throw StateError(
        'host datagram recv failed at iteration $i: $hostRecvErrno',
      );
    }
    if (data.getUint32(countPtr, Endian.little) != _socketIovSize ||
        data.getUint16(flagsPtr, Endian.little) != 0) {
      throw StateError('host datagram recv mismatch at iteration $i');
    }
    checksum += data.getUint32(countPtr, Endian.little);

    final hostSendErrno = writeSocketFromIov(
      socket: hostDescriptor,
      bytes: bytes,
      data: data,
      iovs: iovPtr,
      iovsLen: 1,
      nwrittenPtr: countPtr,
    );
    if (hostSendErrno != errnoSuccess) {
      throw StateError(
        'host datagram send failed at iteration $i: $hostSendErrno',
      );
    }
    if (data.getUint32(countPtr, Endian.little) != _socketIovSize) {
      throw StateError('host datagram send mismatch at iteration $i');
    }
    checksum += data.getUint32(countPtr, Endian.little);
  }
  watch.stop();
  if (socket.sentMessages.length != options.iterations) {
    throw StateError('default datagram send record count mismatch');
  }
  return _Metric(
    operations: options.iterations * 4,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum + hostReceiveByte + hostSentBytes,
  );
}

_Metric _benchmarkSocketPollReadiness(_Options options) {
  final readable = WASIPreview1Socket(
    receiveData: List<int>.generate(_socketChunkSize, (index) => index & 0xff),
  );
  final waiting = WASIPreview1Socket();
  final closed = WASIPreview1Socket();
  closed.shutdown(receive: true, send: false);
  final writeClosed = WASIPreview1Socket();
  writeClosed.shutdown(receive: false, send: true);
  final listener = WASIPreview1Socket(pendingAccepted: [WASIPreview1Socket()]);
  final external = WASIPreview1Socket(
    readReadyBytes: _socketChunkSize ~/ 2,
    writeReady: false,
  );
  final externalDatagram = WASIPreview1Socket.datagram(
    readReadyBytes: _socketChunkSize ~/ 4,
  );
  final zeroHint = WASIPreview1Socket(readReadyBytes: 0);
  var providerCalls = 0;
  final providerBacked = WASIPreview1Socket(
    receiveDataProvider: (maxBytes) {
      if (maxBytes <= 0) {
        return const <int>[];
      }
      providerCalls++;
      return <int>[providerCalls & 0xff];
    },
  );
  final vfs = Preview1VirtualFileSystem(
    sockets: {
      64: readable,
      65: waiting,
      66: closed,
      67: listener,
      68: external,
      69: providerBacked,
      70: zeroHint,
      71: writeClosed,
      72: externalDatagram,
    },
  );
  final providerDrainBuffer = Uint8List(1);

  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final readableEvent = vfs.pollFdReadWrite(
      fd: 64,
      eventType: eventTypeFdRead,
    );
    if (!readableEvent.ready || readableEvent.nbytes != _socketChunkSize) {
      throw StateError('readable socket poll failed at iteration $i');
    }
    checksum += readableEvent.nbytes;

    final waitingEvent = vfs.pollFdReadWrite(
      fd: 65,
      eventType: eventTypeFdRead,
    );
    if (waitingEvent.ready) {
      throw StateError('waiting socket reported ready at iteration $i');
    }
    checksum += waitingEvent.errno;

    final writableEvent = vfs.pollFdReadWrite(
      fd: 65,
      eventType: eventTypeFdWrite,
    );
    if (!writableEvent.ready || writableEvent.errno != errnoSuccess) {
      throw StateError('writable socket poll failed at iteration $i');
    }
    checksum += writableEvent.errno;

    final closedEvent = vfs.pollFdReadWrite(fd: 66, eventType: eventTypeFdRead);
    if (!closedEvent.ready ||
        closedEvent.flags != eventrwflagFdReadwriteHangup) {
      throw StateError('closed socket hangup poll failed at iteration $i');
    }
    checksum += closedEvent.flags;

    final writeClosedEvent = vfs.pollFdReadWrite(
      fd: 71,
      eventType: eventTypeFdWrite,
    );
    if (!writeClosedEvent.ready ||
        writeClosedEvent.nbytes != 0 ||
        writeClosedEvent.flags != eventrwflagFdReadwriteHangup ||
        writeClosedEvent.errno != errnoSuccess) {
      throw StateError(
        'write-closed socket hangup poll failed at iteration $i',
      );
    }
    checksum += writeClosedEvent.flags;

    final acceptEvent = vfs.pollFdReadWrite(fd: 67, eventType: eventTypeFdRead);
    if (!acceptEvent.ready ||
        acceptEvent.nbytes != 0 ||
        acceptEvent.flags != 0 ||
        acceptEvent.errno != errnoSuccess) {
      throw StateError('queued accept socket poll failed at iteration $i');
    }
    checksum++;

    final externalReadEvent = vfs.pollFdReadWrite(
      fd: 68,
      eventType: eventTypeFdRead,
    );
    if (!externalReadEvent.ready ||
        externalReadEvent.nbytes != _socketChunkSize ~/ 2 ||
        externalReadEvent.flags != 0 ||
        externalReadEvent.errno != errnoSuccess) {
      throw StateError('external readable socket poll failed at iteration $i');
    }
    checksum += externalReadEvent.nbytes;

    final externalDatagramEvent = vfs.pollFdReadWrite(
      fd: 72,
      eventType: eventTypeFdRead,
    );
    if (!externalDatagramEvent.ready ||
        externalDatagramEvent.nbytes != _socketChunkSize ~/ 4 ||
        externalDatagramEvent.flags != 0 ||
        externalDatagramEvent.errno != errnoSuccess) {
      throw StateError(
        'external datagram readable socket poll failed at iteration $i',
      );
    }
    checksum += externalDatagramEvent.nbytes;

    final externalWriteEvent = vfs.pollFdReadWrite(
      fd: 68,
      eventType: eventTypeFdWrite,
    );
    if (externalWriteEvent.ready || externalWriteEvent.errno != errnoSuccess) {
      throw StateError(
        'external write-wait socket poll failed at iteration $i',
      );
    }
    checksum += externalWriteEvent.errno;

    final zeroHintReadEvent = vfs.pollFdReadWrite(
      fd: 70,
      eventType: eventTypeFdRead,
    );
    if (zeroHintReadEvent.ready || zeroHintReadEvent.errno != errnoSuccess) {
      throw StateError('zero-hint stream socket poll failed at iteration $i');
    }
    checksum += zeroHintReadEvent.errno;

    final providerReadEvent = vfs.pollFdReadWrite(
      fd: 69,
      eventType: eventTypeFdRead,
    );
    if (!providerReadEvent.ready ||
        providerReadEvent.nbytes != 1 ||
        providerReadEvent.flags != 0 ||
        providerReadEvent.errno != errnoSuccess) {
      throw StateError(
        'provider-backed stream socket poll failed at iteration $i',
      );
    }
    final drained = providerBacked.readInto(providerDrainBuffer, 0, 1);
    if (drained != 1) {
      throw StateError(
        'provider-backed stream socket drain failed at iteration $i',
      );
    }
    checksum += providerReadEvent.nbytes + providerDrainBuffer.single;
  }
  watch.stop();
  if (providerCalls != options.iterations) {
    throw StateError('provider-backed stream socket poll count mismatch');
  }
  return _Metric(
    operations: options.iterations * 11,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkSocketRenumberClose(_Options options) {
  const fromBase = 1000;
  const toBase = 100000;
  final sockets = <int, WASIPreview1Socket>{};
  for (var i = 0; i < options.iterations; i++) {
    sockets[fromBase + i] = WASIPreview1Socket(receiveData: [i & 0xff]);
    sockets[toBase + i] = WASIPreview1Socket();
  }
  final vfs = Preview1VirtualFileSystem(sockets: sockets);

  var successfulOperations = 0;
  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final toFd = toBase + i;
    final result = vfs.renumberDescriptor(fromFd: fromBase + i, toFd: toFd);
    if (result != Preview1FdRenumberResult.success) {
      throw StateError('socket renumber failed at iteration $i: $result');
    }
    successfulOperations++;
    if (!vfs.close(toFd)) {
      throw StateError('socket close failed at iteration $i');
    }
    successfulOperations++;
    checksum += toFd;
  }
  watch.stop();
  return _Metric(
    operations: successfulOperations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkSocketAcceptInheritance(_Options options) {
  final listener = WASIPreview1Socket(
    pendingAccepted: List<WASIPreview1Socket>.generate(
      options.iterations,
      (_) => WASIPreview1Socket(),
    ),
  );
  final vfs = Preview1VirtualFileSystem(sockets: {64: listener});

  var successfulOperations = 0;
  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final acceptedFd = vfs.acceptSocket(
      fd: 64,
      descriptorFlags: fdflagNonblock,
    );
    if (acceptedFd < 0) {
      throw StateError('socket accept failed at iteration $i');
    }
    successfulOperations++;
    final rights = vfs.descriptorRightsForFd(acceptedFd);
    final flags = vfs.descriptorFlagsForFd(acceptedFd);
    if (rights == null ||
        rights.base != rightsSocketInheriting ||
        rights.inheriting != 0 ||
        flags != fdflagNonblock) {
      throw StateError('accepted socket rights mismatch at iteration $i');
    }
    checksum += acceptedFd + rights.base + flags!;
    if (!vfs.close(acceptedFd)) {
      throw StateError('accepted socket close failed at iteration $i');
    }
    successfulOperations++;
  }
  watch.stop();
  return _Metric(
    operations: successfulOperations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkSocketAcceptReceiveShutdown(_Options options) {
  const fdBase = 8192;
  final sockets = <int, WASIPreview1Socket>{
    for (var i = 0; i < options.iterations; i++)
      fdBase + i: WASIPreview1Socket(pendingAccepted: [WASIPreview1Socket()]),
  };
  final vfs = Preview1VirtualFileSystem(
    firstVirtualFd: fdBase + options.iterations,
    sockets: sockets,
  );

  var successfulOperations = 0;
  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final fd = fdBase + i;
    final listener = vfs.socketForFd(fd)!.socket;
    listener.shutdown(receive: true, send: false);
    successfulOperations++;
    if (vfs.acceptSocket(fd: fd, descriptorFlags: 0) >= 0) {
      throw StateError('receive-shutdown listener accepted at iteration $i');
    }
    if (listener.hasPendingAccept) {
      throw StateError('receive-shutdown listener kept accept queue at $i');
    }
    checksum += fd;
    successfulOperations++;
  }
  watch.stop();
  return _Metric(
    operations: successfulOperations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkSocketDatagramRights(_Options options) {
  const fdBase = 24576;
  final sockets = <int, WASIPreview1Socket>{
    for (var i = 0; i < options.iterations; i++)
      fdBase + i: WASIPreview1Socket.datagram(),
  };
  final vfs = Preview1VirtualFileSystem(
    firstVirtualFd: fdBase + options.iterations,
    sockets: sockets,
  );

  var successfulOperations = 0;
  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final fd = fdBase + i;
    final rights = vfs.descriptorRightsForFd(fd);
    if (rights == null ||
        rights.base != rightsSocketInheriting ||
        rights.inheriting != 0) {
      throw StateError('datagram socket rights mismatch at iteration $i');
    }
    checksum += fd + rights.base + rights.inheriting;
    successfulOperations++;

    final result = vfs.setDescriptorRights(
      fd: fd,
      rightsBase: rightSockAccept,
      rightsInheriting: 0,
    );
    if (result != Preview1FdRightsResult.notCapable) {
      throw StateError('datagram accepted sock_accept rights at iteration $i');
    }
    successfulOperations++;
  }
  watch.stop();
  return _Metric(
    operations: successfulOperations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkSocketConnectedRights(_Options options) {
  const fdBase = 32768;
  final sockets = <int, WASIPreview1Socket>{
    for (var i = 0; i < options.iterations; i++)
      fdBase + i: WASIPreview1Socket(canAccept: false),
  };
  final vfs = Preview1VirtualFileSystem(
    firstVirtualFd: fdBase + options.iterations,
    sockets: sockets,
  );

  var successfulOperations = 0;
  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final fd = fdBase + i;
    final rights = vfs.descriptorRightsForFd(fd);
    if (rights == null ||
        rights.base != rightsSocketInheriting ||
        rights.inheriting != 0) {
      throw StateError('connected socket rights mismatch at iteration $i');
    }
    checksum += fd + rights.base + rights.inheriting;
    successfulOperations++;

    final result = vfs.setDescriptorRights(
      fd: fd,
      rightsBase: rightSockAccept,
      rightsInheriting: 0,
    );
    if (result != Preview1FdRightsResult.notCapable) {
      throw StateError('connected socket accepted sock_accept rights at $i');
    }
    successfulOperations++;

    if (vfs.acceptSocket(fd: fd, descriptorFlags: 0) >= 0) {
      throw StateError('connected socket accepted a queued stream at $i');
    }
    successfulOperations++;
  }
  watch.stop();
  return _Metric(
    operations: successfulOperations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkSocketFdflagPreflight(_Options options) {
  const fdBase = 40960;
  final sockets = <int, WASIPreview1Socket>{
    for (var i = 0; i < options.iterations; i++) ...{
      fdBase + i * 2: WASIPreview1Socket(),
      fdBase + i * 2 + 1: WASIPreview1Socket(),
    },
  };
  final vfs = Preview1VirtualFileSystem(
    firstVirtualFd: fdBase + options.iterations * 2,
    sockets: sockets,
  );
  for (var i = 0; i < options.iterations; i++) {
    final rightlessFd = fdBase + i * 2 + 1;
    final result = vfs.setDescriptorRights(
      fd: rightlessFd,
      rightsBase: 0,
      rightsInheriting: 0,
    );
    if (result != Preview1FdRightsResult.success) {
      throw StateError('socket fdflag setup failed at iteration $i: $result');
    }
  }

  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final writableFd = fdBase + i * 2;
    final rightlessFd = writableFd + 1;

    final unsupportedErrno = preview1FdFdstatSetFlags(
      vfs: vfs,
      fd: rightlessFd,
      flags: fdflagAppend,
    );
    if (unsupportedErrno != errnoNotsup) {
      throw StateError(
        'socket fdflag unsupported errno failed at iteration $i: '
        '$unsupportedErrno',
      );
    }
    checksum += unsupportedErrno;

    final rightlessErrno = preview1FdFdstatSetFlags(
      vfs: vfs,
      fd: rightlessFd,
      flags: fdflagNonblock,
    );
    if (rightlessErrno != errnoNotcapable) {
      throw StateError(
        'socket fdflag rightless errno failed at iteration $i: '
        '$rightlessErrno',
      );
    }
    checksum += rightlessErrno;

    final successErrno = preview1FdFdstatSetFlags(
      vfs: vfs,
      fd: writableFd,
      flags: fdflagNonblock,
    );
    if (successErrno != errnoSuccess ||
        vfs.descriptorFlagsForFd(writableFd) != fdflagNonblock) {
      throw StateError('socket fdflag success failed at iteration $i');
    }
    checksum += successErrno + vfs.descriptorFlagsForFd(writableFd)!;

    final invalidErrno = preview1FdFdstatSetFlags(
      vfs: vfs,
      fd: writableFd,
      flags: fdflagKnownMask << 1,
    );
    if (invalidErrno != errnoInval) {
      throw StateError(
        'socket fdflag invalid errno failed at iteration $i: $invalidErrno',
      );
    }
    checksum += invalidErrno;
  }
  watch.stop();
  return _Metric(
    operations: options.iterations * 4,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkSocketFileRightsPreflight(_Options options) {
  const fdBase = 49152;
  final sockets = <int, WASIPreview1Socket>{
    for (var i = 0; i < options.iterations; i++)
      fdBase + i: WASIPreview1Socket(),
  };
  final vfs = Preview1VirtualFileSystem(
    firstVirtualFd: fdBase + options.iterations,
    sockets: sockets,
  );

  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final fd = fdBase + i;
    final allocateErrno = preview1FdAllocate(
      vfs: vfs,
      fd: fd,
      offset: 0,
      length: 1,
    );
    if (allocateErrno != errnoNotcapable) {
      throw StateError(
        'socket fd_allocate errno failed at iteration $i: $allocateErrno',
      );
    }
    checksum += allocateErrno;

    final setSizeErrno = preview1FdFilestatSetSize(vfs: vfs, fd: fd, size: 1);
    if (setSizeErrno != errnoNotcapable) {
      throw StateError(
        'socket fd_filestat_set_size errno failed at iteration $i: '
        '$setSizeErrno',
      );
    }
    checksum += setSizeErrno;
  }
  watch.stop();
  return _Metric(
    operations: options.iterations * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkSocketPositionedRightsPreflight(_Options options) {
  const fdBase = 53248;
  final sockets = <int, WASIPreview1Socket>{
    for (var i = 0; i < options.iterations; i++)
      fdBase + i: WASIPreview1Socket(),
  };
  final vfs = Preview1VirtualFileSystem(
    firstVirtualFd: fdBase + options.iterations,
    sockets: sockets,
  );
  final bytes = Uint8List(128);
  final data = ByteData.view(bytes.buffer);
  const iovPtr = 0;
  const bufferPtr = 32;
  const countPtr = 64;
  const offsetPtr = 72;
  const countSentinel = 0x7fffffff;
  const offsetLowSentinel = 0x11223344;
  const offsetHighSentinel = 0x55667788;
  data.setUint32(iovPtr, bufferPtr, Endian.little);
  data.setUint32(iovPtr + 4, 4, Endian.little);

  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final fd = fdBase + i;
    data.setUint32(countPtr, countSentinel, Endian.little);
    final preadErrno = preview1FdPread(
      vfs: vfs,
      fd: fd,
      bytes: bytes,
      data: data,
      iovs: iovPtr,
      iovsLen: 1,
      offset: 0,
      nreadPtr: countPtr,
    );
    if (preadErrno != errnoNotcapable ||
        data.getUint32(countPtr, Endian.little) != countSentinel) {
      throw StateError(
        'socket fd_pread errno failed at iteration $i: $preadErrno',
      );
    }
    checksum += preadErrno;

    data.setUint32(countPtr, countSentinel, Endian.little);
    final pwriteErrno = preview1FdPwrite(
      vfs: vfs,
      fd: fd,
      bytes: bytes,
      data: data,
      iovs: iovPtr,
      iovsLen: 1,
      offset: 0,
      nwrittenPtr: countPtr,
    );
    if (pwriteErrno != errnoNotcapable ||
        data.getUint32(countPtr, Endian.little) != countSentinel) {
      throw StateError(
        'socket fd_pwrite errno failed at iteration $i: $pwriteErrno',
      );
    }
    checksum += pwriteErrno;

    data.setUint32(offsetPtr, offsetLowSentinel, Endian.little);
    data.setUint32(offsetPtr + 4, offsetHighSentinel, Endian.little);
    final seekErrno = preview1FdSeek(
      vfs: vfs,
      fd: fd,
      offset: 0,
      whence: 0,
      bytes: bytes,
      data: data,
      newOffsetPtr: offsetPtr,
    );
    if (seekErrno != errnoNotcapable ||
        data.getUint32(offsetPtr, Endian.little) != offsetLowSentinel ||
        data.getUint32(offsetPtr + 4, Endian.little) != offsetHighSentinel) {
      throw StateError(
        'socket fd_seek errno failed at iteration $i: $seekErrno',
      );
    }
    checksum += seekErrno;

    data.setUint32(offsetPtr, offsetLowSentinel, Endian.little);
    data.setUint32(offsetPtr + 4, offsetHighSentinel, Endian.little);
    final tellErrno = preview1FdTell(
      vfs: vfs,
      fd: fd,
      bytes: bytes,
      data: data,
      offsetPtr: offsetPtr,
    );
    if (tellErrno != errnoNotcapable ||
        data.getUint32(offsetPtr, Endian.little) != offsetLowSentinel ||
        data.getUint32(offsetPtr + 4, Endian.little) != offsetHighSentinel) {
      throw StateError(
        'socket fd_tell errno failed at iteration $i: $tellErrno',
      );
    }
    checksum += tellErrno;
  }
  watch.stop();
  return _Metric(
    operations: options.iterations * 4,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

void _writeTwoIovs({
  required ByteData data,
  required int iovPtr,
  required int firstBufferPtr,
  required int firstLength,
  required int secondBufferPtr,
  required int secondLength,
}) {
  data.setUint32(iovPtr, firstBufferPtr, Endian.little);
  data.setUint32(iovPtr + 4, firstLength, Endian.little);
  data.setUint32(iovPtr + 8, secondBufferPtr, Endian.little);
  data.setUint32(iovPtr + 12, secondLength, Endian.little);
}

void _expectPathMutation(Preview1PathMutationResult result, String operation) {
  if (result != Preview1PathMutationResult.success) {
    throw StateError('$operation failed: $result');
  }
}

int _openBenchmarkPath(
  Preview1VirtualFileSystem vfs,
  String path, {
  required String label,
}) {
  final result = vfs.openPath(
    path,
    rightsBase: rightsAll,
    rightsInheriting: rightsAll,
  );
  final fd = result.fd;
  if (fd == null) {
    throw StateError('$label open failed for `$path`');
  }
  return fd;
}

void _printText(Map<String, Object?> payload) {
  final runs = payload['runs'];
  if (runs is Map<String, Object?>) {
    stdout
      ..writeln('wasi vfs benchmark')
      ..writeln('  distribution: ${payload['distribution']}');
    for (final entry in runs.entries) {
      stdout.writeln('');
      stdout.writeln('distribution: ${entry.key}');
      _printSingleText(
        entry.value! as Map<String, Object?>,
        includeTitle: false,
        includeDistribution: false,
      );
    }
    return;
  }
  _printSingleText(payload);
}

void _printSingleText(
  Map<String, Object?> payload, {
  bool includeTitle = true,
  bool includeDistribution = true,
}) {
  if (includeTitle) {
    stdout.writeln('wasi vfs benchmark');
  }
  if (includeDistribution) {
    stdout.writeln('  distribution: ${payload['distribution']}');
  }
  stdout
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
  _printMetric('file renumber/close', payload['file_renumber_close']);
  _printMetric('file fd read/write', payload['file_fd_read_write']);
  _printMetric('directory renumber/close', payload['directory_renumber_close']);
  _printMetric('socket recv peek', payload['socket_recv_peek']);
  _printMetric('socket recv waitall', payload['socket_recv_waitall']);
  _printMetric('socket send/recv', payload['socket_send_recv']);
  _printMetric(
    'socket send error preflight',
    payload['socket_send_error_preflight'],
  );
  _printMetric('socket stream zero send', payload['socket_stream_zero_send']);
  _printMetric(
    'socket shutdown preflight',
    payload['socket_shutdown_preflight'],
  );
  _printMetric('socket fd read/write', payload['socket_fd_read_write']);
  _printMetric(
    'socket datagram truncation',
    payload['socket_dgram_truncation'],
  );
  _printMetric('socket datagram rights', payload['socket_datagram_rights']);
  _printMetric('socket connected rights', payload['socket_connected_rights']);
  _printMetric('socket fdflag preflight', payload['socket_fdflag_preflight']);
  _printMetric(
    'socket file rights preflight',
    payload['socket_file_rights_preflight'],
  );
  _printMetric(
    'socket positioned rights preflight',
    payload['socket_positioned_rights_preflight'],
  );
  _printMetric('socket poll readiness', payload['socket_poll_readiness']);
  _printMetric('socket renumber/close', payload['socket_renumber_close']);
  _printMetric(
    'socket accept inheritance',
    payload['socket_accept_inheritance'],
  );
  _printMetric(
    'socket accept receive shutdown',
    payload['socket_accept_receive_shutdown'],
  );
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
  --distribution=<name>      Benchmark distribution: baseline, directory-heavy,
                             descriptor-heavy, socket-heavy, or all. Default:
                             $_baselineDistribution.
  --directories=<n>          Number of virtual directories. Default: $_defaultDirectories.
  --files-per-directory=<n>  Number of files under each directory. Default: $_defaultFilesPerDirectory.
  --iterations=<n>           Repetitions for open/readdir/right checks. Default: $_defaultIterations.
  --open-fds=<n>             Descriptors opened for rights checks. Default: $_defaultOpenFds.
  --mutations=<n>            Directory/link/symlink mutation cycles. Default: $_defaultMutations.
  --json                     Print machine-readable JSON.
  --help                     Show this help.
''');
}

final class _DistributionDefaults {
  const _DistributionDefaults({
    required this.directories,
    required this.filesPerDirectory,
    required this.iterations,
    required this.openFds,
    required this.mutations,
  });

  final int directories;
  final int filesPerDirectory;
  final int iterations;
  final int openFds;
  final int mutations;
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
    required this.distribution,
    required this.directoriesOverride,
    required this.filesPerDirectoryOverride,
    required this.iterationsOverride,
    required this.openFdsOverride,
    required this.mutationsOverride,
    required this.json,
    required this.help,
  });

  final String distribution;
  final int? directoriesOverride;
  final int? filesPerDirectoryOverride;
  final int? iterationsOverride;
  final int? openFdsOverride;
  final int? mutationsOverride;
  final bool json;
  final bool help;

  _DistributionDefaults get _defaults {
    return _distributionDefaults[distribution] ??
        _distributionDefaults[_baselineDistribution]!;
  }

  int get directories => directoriesOverride ?? _defaults.directories;

  int get filesPerDirectory {
    return filesPerDirectoryOverride ?? _defaults.filesPerDirectory;
  }

  int get iterations => iterationsOverride ?? _defaults.iterations;

  int get openFds => openFdsOverride ?? _defaults.openFds;

  int get mutations => mutationsOverride ?? _defaults.mutations;

  _Options withDistribution(String distribution) {
    return _Options(
      distribution: distribution,
      directoriesOverride: directoriesOverride,
      filesPerDirectoryOverride: filesPerDirectoryOverride,
      iterationsOverride: iterationsOverride,
      openFdsOverride: openFdsOverride,
      mutationsOverride: mutationsOverride,
      json: json,
      help: help,
    );
  }

  _Options copyWith({int? iterations, int? openFds, int? mutations}) {
    return _Options(
      distribution: distribution,
      directoriesOverride: directories,
      filesPerDirectoryOverride: filesPerDirectory,
      iterationsOverride: iterations ?? this.iterations,
      openFdsOverride: openFds ?? this.openFds,
      mutationsOverride: mutations ?? this.mutations,
      json: json,
      help: help,
    );
  }

  factory _Options.parse(List<String> args) {
    var distribution = _baselineDistribution;
    int? directories;
    int? filesPerDirectory;
    int? iterations;
    int? openFds;
    int? mutations;
    var json = false;
    var help = false;

    for (final arg in args) {
      if (arg == '--json') {
        json = true;
      } else if (arg == '--help' || arg == '-h') {
        help = true;
      } else if (arg.startsWith('--distribution=')) {
        distribution = arg.substring('--distribution='.length);
        if (distribution != _allDistributions &&
            !_distributionDefaults.containsKey(distribution)) {
          throw ArgumentError('Unsupported distribution: $distribution');
        }
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
      distribution: distribution,
      directoriesOverride: directories,
      filesPerDirectoryOverride: filesPerDirectory,
      iterationsOverride: iterations,
      openFdsOverride: openFds,
      mutationsOverride: mutations,
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
