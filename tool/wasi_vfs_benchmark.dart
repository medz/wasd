import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wasd/src/wasi/preview1/common/constants.dart';
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
  final directoryRenumberClose = _benchmarkDirectoryRenumberClose(options);
  final socketRecvPeek = _benchmarkSocketRecvPeek(options);
  final socketRecvWaitall = _benchmarkSocketRecvWaitall(options);
  final socketSendRecv = _benchmarkSocketSendRecv(options);
  final socketDgramTruncation = _benchmarkSocketDatagramTruncation(options);
  final socketPollReadiness = _benchmarkSocketPollReadiness(options);
  final socketRenumberClose = _benchmarkSocketRenumberClose(options);

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
    'directory_renumber_close': directoryRenumberClose.toJson(),
    'socket_recv_peek': socketRecvPeek.toJson(),
    'socket_recv_waitall': socketRecvWaitall.toJson(),
    'socket_send_recv': socketSendRecv.toJson(),
    'socket_dgram_truncation': socketDgramTruncation.toJson(),
    'socket_poll_readiness': socketPollReadiness.toJson(),
    'socket_renumber_close': socketRenumberClose.toJson(),
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
  _benchmarkDirectoryRenumberClose(warmupOptions);
  _benchmarkSocketRecvPeek(warmupOptions);
  _benchmarkSocketRecvWaitall(warmupOptions);
  _benchmarkSocketSendRecv(warmupOptions);
  _benchmarkSocketDatagramTruncation(warmupOptions);
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
  final vfs = Preview1VirtualFileSystem(
    sockets: {64: satisfiedSocket, 65: againSocket},
  );
  final satisfiedDescriptor = vfs.socketForFd(64);
  final againDescriptor = vfs.socketForFd(65);
  if (satisfiedDescriptor == null || againDescriptor == null) {
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
  }
  watch.stop();
  return _Metric(
    operations: options.iterations * 2,
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
  final vfs = Preview1VirtualFileSystem(
    sockets: {64: socket, 65: blockedSocket},
  );
  final descriptor = vfs.socketForFd(64);
  final blockedDescriptor = vfs.socketForFd(65);
  if (descriptor == null || blockedDescriptor == null) {
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
  }
  watch.stop();
  return _Metric(
    operations: options.iterations * 3,
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
  final vfs = Preview1VirtualFileSystem(sockets: {64: socket});
  final descriptor = vfs.socketForFd(64);
  if (descriptor == null) {
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
  }
  watch.stop();
  return _Metric(
    operations: options.iterations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkSocketPollReadiness(_Options options) {
  final readable = WASIPreview1Socket(
    receiveData: List<int>.generate(_socketChunkSize, (index) => index & 0xff),
  );
  final waiting = WASIPreview1Socket();
  final closed = WASIPreview1Socket();
  closed.shutdown(receive: true, send: false);
  final listener = WASIPreview1Socket(pendingAccepted: [WASIPreview1Socket()]);
  final external = WASIPreview1Socket(
    readReadyBytes: _socketChunkSize ~/ 2,
    writeReady: false,
  );
  final vfs = Preview1VirtualFileSystem(
    sockets: {
      64: readable,
      65: waiting,
      66: closed,
      67: listener,
      68: external,
    },
  );

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
  }
  watch.stop();
  return _Metric(
    operations: options.iterations * 7,
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
  _printMetric('directory renumber/close', payload['directory_renumber_close']);
  _printMetric('socket recv peek', payload['socket_recv_peek']);
  _printMetric('socket recv waitall', payload['socket_recv_waitall']);
  _printMetric('socket send/recv', payload['socket_send_recv']);
  _printMetric(
    'socket datagram truncation',
    payload['socket_dgram_truncation'],
  );
  _printMetric('socket poll readiness', payload['socket_poll_readiness']);
  _printMetric('socket renumber/close', payload['socket_renumber_close']);
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
