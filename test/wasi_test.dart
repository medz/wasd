import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/preview1/common/vfs.dart';
import 'package:wasd/wasm.dart';
import 'package:wasd/wasi.dart';
import 'support/runtime_environment.dart';
import 'support/wasm_fixtures.dart';
import 'support/web_crypto_spy.dart';

final _wasiBytes = wasiStartModuleBytes();

Object? _skipOnNode(String reason) => isNodeJsRuntime ? reason : false;

Object? _skipUnlessBrowser(String reason) =>
    isBrowserJsRuntime ? false : reason;

const int _rightFdRead = 1 << 1;
const int _rightFdSeek = 1 << 2;
const int _rightFdDatasync = 1;
const int _rightFdFdstatSetFlags = 1 << 3;
const int _rightFdSync = 1 << 4;
const int _rightFdWrite = 1 << 6;
const int _rightFdAdvise = 1 << 7;
const int _rightFdFdstatGet = 1 << 21;
const int _rightFdFilestatSetTimes = 1 << 23;
const int _rightPollFdReadwrite = 1 << 27;
const int _rightSockShutdown = 1 << 28;
const int _rightSockAccept = 1 << 29;
const int _rightPathOpen = 1 << 13;
const int _rightsAll = (1 << 30) - 1;
const int _filetypeSocketDgram = 5;
const int _filetypeSocketStream = 6;
const int _errnoAgain = 6;
const int _errnoBadf = 8;
const int _errnoExist = 20;
const int _errnoInval = 28;
const int _errnoNotsock = 57;
const int _errnoNotdir = 54;
const int _errnoNotsup = 58;
const int _errnoNotcapable = 76;
const int _errnoPipe = 64;
const int _oflagCreat = 1;
const int _oflagDirectory = 2;
const int _oflagExcl = 4;
const int _oflagTrunc = 8;
const int _fdflagAppend = 1;
const int _fdflagNonblock = 4;
const int _fdflagUnknown = 1 << 5;
const int _riflagRecvWaitall = 2;
const int _roflagRecvDataTruncated = 1;
const int _subscriptionSize = 48;
const int _subscriptionTagOffset = 8;
const int _subscriptionFdReadwriteFdOffset = 16;
const int _subscriptionClockIdOffset = 16;
const int _subscriptionClockFlagsOffset = 40;
const int _eventSize = 32;
const int _eventErrorOffset = 8;
const int _eventTypeOffset = 10;
const int _eventFdReadwriteNbytesOffset = 16;
const int _eventFdReadwriteFlagsOffset = 24;
const int _eventTypeClock = 0;
const int _eventTypeFdRead = 1;
const int _eventTypeFdWrite = 2;
const int _eventrwflagFdReadwriteHangup = 1;

void _setUint64Le(ByteData data, int offset, int value) {
  final normalized = value.toUnsigned(64);
  data.setUint32(offset, normalized & 0xffffffff, Endian.little);
  data.setUint32(offset + 4, normalized >>> 32, Endian.little);
}

int _getUint64Le(ByteData data, int offset) {
  final low = data.getUint32(offset, Endian.little);
  final high = data.getUint32(offset + 4, Endian.little);
  return low | (high << 32);
}

List<({int inode, String name, int next, int type})> _readDirents(
  Uint8List bytes,
  ByteData data,
  int ptr,
  int length,
) {
  final entries = <({int inode, String name, int next, int type})>[];
  var offset = ptr;
  final end = ptr + length;
  while (offset + 24 <= end) {
    final next = _getUint64Le(data, offset);
    final inode = _getUint64Le(data, offset + 8);
    final nameLen = data.getUint32(offset + 16, Endian.little);
    final type = bytes[offset + 20];
    final namePtr = offset + 24;
    final nameEnd = namePtr + nameLen;
    if (nameEnd > end) {
      break;
    }
    entries.add((
      inode: inode,
      name: utf8.decode(bytes.sublist(namePtr, nameEnd)),
      next: next,
      type: type,
    ));
    offset = nameEnd;
  }
  return entries;
}

Future<Object?> _awaitMaybeFuture(Object? value) async =>
    value is Future ? await value : value;

void _writePollSubscription(
  ByteData data,
  int ptr, {
  required int userdata,
  required int tag,
  int fd = 0,
}) {
  _setUint64Le(data, ptr, userdata);
  data.setUint8(ptr + _subscriptionTagOffset, tag);
  if (tag == _eventTypeFdRead || tag == _eventTypeFdWrite) {
    data.setUint32(ptr + _subscriptionFdReadwriteFdOffset, fd, Endian.little);
  }
}

const _supportedClockIds = <int>[0, 1, 2, 3];

void main() {
  group('WASI', () {
    test('constructor creates instance', () {
      final wasi = WASI();
      expect(wasi, isA<WASI>());
    });

    test('constructor rejects unsupported component WASI versions', () {
      expect(
        () => WASI(version: WASIVersion.preview2),
        throwsA(isA<UnsupportedError>()),
      );
      expect(
        () => WASI(version: WASIVersion.preview3),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('process signal codes follow WASI Preview1 numbering', () {
      expect(WASIProcessSignal.none.code, 0);
      expect(WASIProcessSignal.term.code, 15);
      expect(WASIProcessSignal.sys.code, 30);
      expect(WASIProcessSignal.fromPreview1Code(15), WASIProcessSignal.term);
      expect(WASIProcessSignal.fromPreview1Code(30), WASIProcessSignal.sys);
      expect(WASIProcessSignal.fromPreview1Code(31), isNull);
    });

    test('imports contains wasi_snapshot_preview1', () {
      final wasi = WASI();
      expect(wasi.imports.containsKey('wasi_snapshot_preview1'), isTrue);
    });

    test('imports has proc_exit function', () {
      final wasi = WASI();
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      expect(preview1.containsKey('proc_exit'), isTrue);
      expect(preview1['proc_exit'], isA<FunctionImportExportValue>());
    });

    test('datagram sockets reject accepted queues', () {
      final datagram = WASIPreview1Socket.datagram();
      expect(
        () => datagram.queueAccepted(WASIPreview1Socket()),
        throwsStateError,
      );
    });

    test('accepted socket queues require stream sockets', () {
      final listener = WASIPreview1Socket();
      final datagram = WASIPreview1Socket.datagram();

      expect(() => listener.queueAccepted(datagram), throwsStateError);
      expect(
        () => WASIPreview1Socket(pendingAccepted: [datagram]),
        throwsStateError,
      );
    });

    test('datagram sockets keep defensive and owned write paths separate', () {
      final socket = WASIPreview1Socket.datagram();
      final callerOwned = Uint8List.fromList([1, 2, 3]);

      expect(socket.writeMessage(callerOwned), 3);
      callerOwned[0] = 9;
      expect(socket.sentMessages.single, [1, 2, 3]);

      final vfs = Preview1VirtualFileSystem(sockets: {75: socket});
      final descriptor = vfs.socketForFd(75)!;
      final bytes = Uint8List(32);
      final data = ByteData.view(bytes.buffer);
      const iovPtr = 0;
      const bufferPtr = 16;
      const countPtr = 24;
      bytes.setAll(bufferPtr, [4, 5]);
      data.setUint32(iovPtr, bufferPtr, Endian.little);
      data.setUint32(iovPtr + 4, 2, Endian.little);

      expect(
        writeSocketFromIov(
          socket: descriptor,
          bytes: bytes,
          data: data,
          iovs: iovPtr,
          iovsLen: 1,
          nwrittenPtr: countPtr,
        ),
        0,
      );
      expect(data.getUint32(countPtr, Endian.little), 2);
      expect(socket.sentMessages.map((message) => message.toList()), [
        [1, 2, 3],
        [4, 5],
      ]);
    });

    test('stream sockets record sent bytes as an owned copy', () {
      final socket = WASIPreview1Socket();
      final source = Uint8List.fromList([1, 2, 3, 4]);

      expect(socket.writeFrom(source, 1, 2), 2);
      source[1] = 9;
      expect(socket.sentData, [2, 3]);

      expect(socket.writeFrom(Uint8List.fromList([4]), 0, 1), 1);
      expect(socket.sentData, [2, 3, 4]);
      socket.clearSentData();
      expect(socket.sentData, isEmpty);
    });

    test('virtual socket poll honors host readiness hints', () {
      final socket = WASIPreview1Socket(readReadyBytes: 128, writeReady: false);
      final vfs = Preview1VirtualFileSystem(sockets: {70: socket});

      final readable = vfs.pollFdReadWrite(fd: 70, eventType: _eventTypeFdRead);
      expect(readable.ready, isTrue);
      expect(readable.errno, 0);
      expect(readable.nbytes, 128);
      expect(readable.flags, 0);

      final writeWaiting = vfs.pollFdReadWrite(
        fd: 70,
        eventType: _eventTypeFdWrite,
      );
      expect(writeWaiting.ready, isFalse);
      expect(writeWaiting.errno, 0);

      socket.readReadyBytes = null;
      final readWaiting = vfs.pollFdReadWrite(
        fd: 70,
        eventType: _eventTypeFdRead,
      );
      expect(readWaiting.ready, isFalse);

      socket.readReadyBytes = 0;
      final zeroReadyRead = vfs.pollFdReadWrite(
        fd: 70,
        eventType: _eventTypeFdRead,
      );
      expect(zeroReadyRead.ready, isFalse);

      socket.addReceiveData([1, 2, 3]);
      final bufferedRead = vfs.pollFdReadWrite(
        fd: 70,
        eventType: _eventTypeFdRead,
      );
      expect(bufferedRead.ready, isTrue);
      expect(bufferedRead.nbytes, 3);

      socket.writeReady = true;
      final writable = vfs.pollFdReadWrite(
        fd: 70,
        eventType: _eventTypeFdWrite,
      );
      expect(writable.ready, isTrue);

      expect(() => socket.readReadyBytes = -1, throwsArgumentError);
    });

    test('virtual socket send handlers stop after partial writes', () {
      final acceptedBytes = <int>[];
      final socket = WASIPreview1Socket(
        sendHandler: (source, start, length) {
          acceptedBytes.add(source[start]);
          return 1;
        },
      );
      final vfs = Preview1VirtualFileSystem(sockets: {71: socket});
      final descriptor = vfs.socketForFd(71)!;
      final bytes = Uint8List(64);
      final data = ByteData.view(bytes.buffer);
      const iovPtr = 0;
      const firstBufferPtr = 24;
      const secondBufferPtr = 32;
      const countPtr = 48;

      bytes[firstBufferPtr] = 1;
      bytes[firstBufferPtr + 1] = 2;
      bytes[secondBufferPtr] = 3;
      bytes[secondBufferPtr + 1] = 4;
      data.setUint32(iovPtr, firstBufferPtr, Endian.little);
      data.setUint32(iovPtr + 4, 2, Endian.little);
      data.setUint32(iovPtr + 8, secondBufferPtr, Endian.little);
      data.setUint32(iovPtr + 12, 2, Endian.little);

      expect(
        writeSocketFromIov(
          socket: descriptor,
          bytes: bytes,
          data: data,
          iovs: iovPtr,
          iovsLen: 2,
          nwrittenPtr: countPtr,
        ),
        0,
      );
      expect(data.getUint32(countPtr, Endian.little), 1);
      expect(acceptedBytes, [1]);
    });

    test('virtual socket stream send snapshots overlapping iovs', () {
      const iovPtr = 4800;
      const secondIovPtr = iovPtr + 8;
      const originalPayloadPtr = 0x1341;
      const mutatedPayloadPtr = 0x1350;
      const countPtr = 5008;
      final acceptedBytes = BytesBuilder(copy: true);
      var calls = 0;
      final socket = WASIPreview1Socket(
        sendHandler: (source, start, length) {
          calls++;
          acceptedBytes.add(
            Uint8List.sublistView(source, start, start + length),
          );
          if (calls == 1) {
            expect(start, secondIovPtr);
            expect(length, 1);
            expect(source[start], originalPayloadPtr & 0xff);
            source[start] = mutatedPayloadPtr & 0xff;
          }
          return length;
        },
      );
      final vfs = Preview1VirtualFileSystem(sockets: {71: socket});
      final descriptor = vfs.socketForFd(71)!;
      final bytes = Uint8List(8192);
      final data = ByteData.view(bytes.buffer);

      bytes.setAll(originalPayloadPtr, utf8.encode('ok!'));
      bytes.setAll(mutatedPayloadPtr, utf8.encode('bad'));
      data.setUint32(iovPtr, secondIovPtr, Endian.little);
      data.setUint32(iovPtr + 4, 1, Endian.little);
      data.setUint32(iovPtr + 8, originalPayloadPtr, Endian.little);
      data.setUint32(iovPtr + 12, 3, Endian.little);

      expect(
        writeSocketFromIov(
          socket: descriptor,
          bytes: bytes,
          data: data,
          iovs: iovPtr,
          iovsLen: 2,
          nwrittenPtr: countPtr,
        ),
        0,
      );
      expect(calls, 2);
      expect(data.getUint32(countPtr, Endian.little), 4);
      expect(acceptedBytes.toBytes(), [
        originalPayloadPtr & 0xff,
        ...'ok!'.codeUnits,
      ]);
      expect(data.getUint32(secondIovPtr, Endian.little), mutatedPayloadPtr);
    });

    test('virtual socket receive providers are capped to requested bytes', () {
      var providerCalls = 0;
      final socket = WASIPreview1Socket(
        receiveDataProvider: (maxBytes) {
          providerCalls++;
          expect(maxBytes, 2);
          return providerCalls == 1 ? utf8.encode('hello') : const <int>[];
        },
      );
      final vfs = Preview1VirtualFileSystem(sockets: {72: socket});
      final descriptor = vfs.socketForFd(72)!;
      final bytes = Uint8List(64);
      final data = ByteData.view(bytes.buffer);
      const iovPtr = 0;
      const bufferPtr = 16;
      const countPtr = 32;
      const flagsPtr = 40;

      data.setUint32(iovPtr, bufferPtr, Endian.little);
      data.setUint32(iovPtr + 4, 2, Endian.little);
      expect(
        readSocketIntoIov(
          socket: descriptor,
          bytes: bytes,
          data: data,
          iovs: iovPtr,
          iovsLen: 1,
          flags: 0,
          nreadPtr: countPtr,
          roFlagsPtr: flagsPtr,
        ),
        0,
      );
      expect(data.getUint32(countPtr, Endian.little), 2);
      expect(data.getUint16(flagsPtr, Endian.little), 0);
      expect(utf8.decode(bytes.sublist(bufferPtr, bufferPtr + 2)), 'he');
      expect(socket.remainingReceiveData, isEmpty);

      data.setUint32(countPtr, 0xfeedface, Endian.little);
      data.setUint16(flagsPtr, 0xbeef, Endian.little);
      expect(
        readSocketIntoIov(
          socket: descriptor,
          bytes: bytes,
          data: data,
          iovs: iovPtr,
          iovsLen: 1,
          flags: 0,
          nreadPtr: countPtr,
          roFlagsPtr: flagsPtr,
        ),
        _errnoAgain,
      );
      expect(data.getUint32(countPtr, Endian.little), 0xfeedface);
      expect(data.getUint16(flagsPtr, Endian.little), 0xbeef);
      expect(providerCalls, 2);
    });

    test('virtual datagram providers preserve zero-length messages', () {
      final messages = [<int>[]];
      final socket = WASIPreview1Socket.datagram(
        receiveMessageProvider: () =>
            messages.isEmpty ? null : messages.removeAt(0),
      );
      final vfs = Preview1VirtualFileSystem(sockets: {72: socket});

      final readiness = vfs.pollFdReadWrite(
        fd: 72,
        eventType: _eventTypeFdRead,
      );
      expect(readiness.ready, isTrue);
      expect(readiness.nbytes, 0);
      expect(readiness.flags, 0);

      final descriptor = vfs.socketForFd(72)!;
      final bytes = Uint8List(64);
      final data = ByteData.view(bytes.buffer);
      const iovPtr = 0;
      const bufferPtr = 24;
      const countPtr = 48;
      const flagsPtr = 56;
      data.setUint32(iovPtr, bufferPtr, Endian.little);
      data.setUint32(iovPtr + 4, 4, Endian.little);

      expect(
        readSocketIntoIov(
          socket: descriptor,
          bytes: bytes,
          data: data,
          iovs: iovPtr,
          iovsLen: 1,
          flags: 0,
          nreadPtr: countPtr,
          roFlagsPtr: flagsPtr,
        ),
        0,
      );
      expect(data.getUint32(countPtr, Endian.little), 0);
      expect(data.getUint16(flagsPtr, Endian.little), 0);
      expect(socket.remainingReceiveMessages, isEmpty);
    });

    test('virtual socket host send handlers reject invalid write counts', () {
      final stream = WASIPreview1Socket(
        sendHandler: (source, start, length) => length + 1,
      );
      final datagram = WASIPreview1Socket.datagram(
        sendMessageHandler: (message) => -1,
      );
      final partialDatagram = WASIPreview1Socket.datagram(
        sendMessageHandler: (message) => message.length - 1,
      );
      final overDatagram = WASIPreview1Socket.datagram(
        sendMessageHandler: (message) => message.length + 1,
      );
      final vfs = Preview1VirtualFileSystem(
        sockets: {
          73: stream,
          74: datagram,
          75: partialDatagram,
          76: overDatagram,
        },
      );
      final bytes = Uint8List(64);
      final data = ByteData.view(bytes.buffer);
      const iovPtr = 0;
      const bufferPtr = 24;
      const countPtr = 48;

      bytes.setAll(bufferPtr, [1, 2, 3, 4]);
      data.setUint32(iovPtr, bufferPtr, Endian.little);
      data.setUint32(iovPtr + 4, 4, Endian.little);

      data.setUint32(countPtr, 0xdeadbeef, Endian.little);
      expect(
        writeSocketFromIov(
          socket: vfs.socketForFd(73)!,
          bytes: bytes,
          data: data,
          iovs: iovPtr,
          iovsLen: 1,
          nwrittenPtr: countPtr,
        ),
        _errnoInval,
      );
      expect(data.getUint32(countPtr, Endian.little), 0xdeadbeef);

      data.setUint32(countPtr, 0xfeedface, Endian.little);
      expect(
        writeSocketFromIov(
          socket: vfs.socketForFd(74)!,
          bytes: bytes,
          data: data,
          iovs: iovPtr,
          iovsLen: 1,
          nwrittenPtr: countPtr,
        ),
        _errnoInval,
      );
      expect(data.getUint32(countPtr, Endian.little), 0xfeedface);
      expect(datagram.sentMessages, isEmpty);

      data.setUint32(countPtr, 0xabad1dea, Endian.little);
      expect(
        writeSocketFromIov(
          socket: vfs.socketForFd(75)!,
          bytes: bytes,
          data: data,
          iovs: iovPtr,
          iovsLen: 1,
          nwrittenPtr: countPtr,
        ),
        _errnoInval,
      );
      expect(data.getUint32(countPtr, Endian.little), 0xabad1dea);
      expect(partialDatagram.sentMessages, isEmpty);

      data.setUint32(countPtr, 0x12345678, Endian.little);
      expect(
        writeSocketFromIov(
          socket: vfs.socketForFd(76)!,
          bytes: bytes,
          data: data,
          iovs: iovPtr,
          iovsLen: 1,
          nwrittenPtr: countPtr,
        ),
        _errnoInval,
      );
      expect(data.getUint32(countPtr, Endian.little), 0x12345678);
      expect(overDatagram.sentMessages, isEmpty);
    });

    test('virtual socket send rejects write-side shutdown', () {
      final stream = WASIPreview1Socket();
      final datagram = WASIPreview1Socket.datagram();
      stream.shutdown(receive: false, send: true);
      datagram.shutdown(receive: false, send: true);
      final vfs = Preview1VirtualFileSystem(
        sockets: {75: stream, 76: datagram},
      );
      final bytes = Uint8List(64);
      final data = ByteData.view(bytes.buffer);
      const iovPtr = 0;
      const bufferPtr = 24;
      const countPtr = 48;

      bytes.setAll(bufferPtr, [1, 2, 3, 4]);
      data.setUint32(iovPtr, bufferPtr, Endian.little);
      data.setUint32(iovPtr + 4, 4, Endian.little);

      data.setUint32(countPtr, 0xdeadbeef, Endian.little);
      expect(
        writeSocketFromIov(
          socket: vfs.socketForFd(75)!,
          bytes: bytes,
          data: data,
          iovs: iovPtr,
          iovsLen: 1,
          nwrittenPtr: countPtr,
        ),
        _errnoPipe,
      );
      expect(data.getUint32(countPtr, Endian.little), 0xdeadbeef);
      expect(stream.sentData, isEmpty);

      data.setUint32(countPtr, 0xfeedface, Endian.little);
      expect(
        writeSocketFromIov(
          socket: vfs.socketForFd(76)!,
          bytes: bytes,
          data: data,
          iovs: iovPtr,
          iovsLen: 1,
          nwrittenPtr: countPtr,
        ),
        _errnoPipe,
      );
      expect(data.getUint32(countPtr, Endian.little), 0xfeedface);
      expect(datagram.sentMessages, isEmpty);
    });

    test('virtual socket receive shutdown remains terminal', () {
      final stream = WASIPreview1Socket(receiveData: [1, 2]);
      final datagram = WASIPreview1Socket.datagram(
        receiveMessages: [
          [3, 4],
        ],
      );
      stream.shutdown(receive: true, send: false);
      datagram.shutdown(receive: true, send: false);
      expect(stream.remainingReceiveData, isEmpty);
      expect(datagram.remainingReceiveMessages, isEmpty);

      stream.addReceiveData([5, 6]);
      datagram.addReceiveData([7, 8]);
      expect(stream.remainingReceiveData, isEmpty);
      expect(datagram.remainingReceiveMessages, isEmpty);

      final vfs = Preview1VirtualFileSystem(
        sockets: {77: stream, 78: datagram},
      );
      final bytes = Uint8List(64);
      final data = ByteData.view(bytes.buffer);
      const iovPtr = 0;
      const bufferPtr = 24;
      const countPtr = 48;
      const flagsPtr = 56;
      data.setUint32(iovPtr, bufferPtr, Endian.little);
      data.setUint32(iovPtr + 4, 4, Endian.little);

      for (final fd in [77, 78]) {
        final readiness = vfs.pollFdReadWrite(
          fd: fd,
          eventType: _eventTypeFdRead,
        );
        expect(readiness.ready, isTrue);
        expect(readiness.nbytes, 0);
        expect(readiness.flags, _eventrwflagFdReadwriteHangup);

        data.setUint32(countPtr, 0xdeadbeef, Endian.little);
        data.setUint16(flagsPtr, 0xbeef, Endian.little);
        expect(
          readSocketIntoIov(
            socket: vfs.socketForFd(fd)!,
            bytes: bytes,
            data: data,
            iovs: iovPtr,
            iovsLen: 1,
            flags: 0,
            nreadPtr: countPtr,
            roFlagsPtr: flagsPtr,
          ),
          0,
        );
        expect(data.getUint32(countPtr, Endian.little), 0);
        expect(data.getUint16(flagsPtr, Endian.little), 0);
      }
    });

    test('virtual socket descriptors reject initial fd collisions', () {
      expect(
        () => Preview1VirtualFileSystem(firstVirtualFd: -1),
        throwsArgumentError,
      );
      expect(
        () => Preview1VirtualFileSystem(sockets: {-1: WASIPreview1Socket()}),
        throwsArgumentError,
      );
      expect(
        () => Preview1VirtualFileSystem(sockets: {0: WASIPreview1Socket()}),
        throwsArgumentError,
      );
      expect(
        () => Preview1VirtualFileSystem(
          preopens: {'/sandbox': '/tmp'},
          sockets: {3: WASIPreview1Socket()},
        ),
        throwsArgumentError,
      );
      expect(
        () => Preview1VirtualFileSystem(
          stdinFd: 3,
          preopens: {'/sandbox': '/tmp'},
        ),
        throwsArgumentError,
      );
      expect(
        () => Preview1VirtualFileSystem(stdinFd: 10, stdoutFd: 10),
        throwsArgumentError,
      );
    });

    test('imports has fd_write function', () {
      final wasi = WASI();
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      expect(preview1.containsKey('fd_write'), isTrue);
      expect(preview1['fd_write'], isA<FunctionImportExportValue>());
    });

    test('imports has fd_read function', () {
      final wasi = WASI();
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      expect(preview1.containsKey('fd_read'), isTrue);
      expect(preview1['fd_read'], isA<FunctionImportExportValue>());
    });

    test('imports has fd_close function', () {
      final wasi = WASI();
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      expect(preview1.containsKey('fd_close'), isTrue);
      expect(preview1['fd_close'], isA<FunctionImportExportValue>());
    });

    test('imports has args functions', () {
      final wasi = WASI();
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      expect(preview1.containsKey('args_sizes_get'), isTrue);
      expect(preview1.containsKey('args_get'), isTrue);
      expect(preview1['args_sizes_get'], isA<FunctionImportExportValue>());
      expect(preview1['args_get'], isA<FunctionImportExportValue>());
    });

    test('imports has environ functions', () {
      final wasi = WASI();
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      expect(preview1.containsKey('environ_sizes_get'), isTrue);
      expect(preview1.containsKey('environ_get'), isTrue);
      expect(preview1['environ_sizes_get'], isA<FunctionImportExportValue>());
      expect(preview1['environ_get'], isA<FunctionImportExportValue>());
    });

    test('imports has random_get function', () {
      final wasi = WASI();
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      expect(preview1.containsKey('random_get'), isTrue);
      expect(preview1['random_get'], isA<FunctionImportExportValue>());
    });

    test('imports has fd_fdstat_get function', () {
      final wasi = WASI();
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      expect(preview1.containsKey('fd_fdstat_get'), isTrue);
      expect(preview1['fd_fdstat_get'], isA<FunctionImportExportValue>());
    });

    test('imports has clock_time_get function', () {
      final wasi = WASI();
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      expect(preview1.containsKey('clock_time_get'), isTrue);
      expect(preview1['clock_time_get'], isA<FunctionImportExportValue>());
    });

    test('imports has clock_res_get function', () {
      final wasi = WASI();
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      expect(preview1.containsKey('clock_res_get'), isTrue);
      expect(preview1['clock_res_get'], isA<FunctionImportExportValue>());
    });

    test('imports exposes preview1 compatibility functions', () {
      final wasi = WASI();
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      expect(preview1.containsKey('sched_yield'), isTrue);
      expect(preview1.containsKey('fd_prestat_get'), isTrue);
      expect(preview1.containsKey('fd_prestat_dir_name'), isTrue);
      expect(preview1.containsKey('path_open'), isTrue);
      expect(preview1.containsKey('path_filestat_get'), isTrue);
      expect(preview1.containsKey('poll_oneoff'), isTrue);
      expect(preview1.containsKey('path_readlink'), isTrue);
      expect(preview1.containsKey('path_symlink'), isTrue);
      expect(preview1.containsKey('path_unlink_file'), isTrue);
      expect(preview1.containsKey('fd_seek'), isTrue);
      expect(preview1.containsKey('fd_renumber'), isTrue);
      expect(preview1.containsKey('proc_raise'), isTrue);
      expect(preview1['sched_yield'], isA<FunctionImportExportValue>());
      expect(preview1['path_open'], isA<FunctionImportExportValue>());
      expect(preview1['fd_seek'], isA<FunctionImportExportValue>());
    });

    test('virtual file lookup indexes survive file path mutations', () {
      final vfs = Preview1VirtualFileSystem(
        preopens: const {'/sandbox': '/sandbox'},
        files: {
          '/sandbox/Alpha.TXT': Uint8List.fromList([1]),
          '/sandbox/alpha.txt': Uint8List.fromList([2]),
          '/sandbox/dir/Name.wasm': Uint8List.fromList([3]),
          '/sandbox/other/name.wasm': Uint8List.fromList([4]),
        },
      );

      expect(vfs.lookupFile('/sandbox/ALPHA.TXT')!.bytes.single, 1);
      expect(vfs.lookupFile('/missing/NAME.WASM')!.bytes.single, 3);
      expect(
        vfs.linkPath(
          oldPath: '/sandbox/alpha.txt',
          newPath: '/sandbox/linked.txt',
        ),
        Preview1PathMutationResult.success,
      );
      expect(
        vfs.renamePath(
          oldPath: '/sandbox/linked.txt',
          newPath: '/sandbox/Renamed.TXT',
        ),
        Preview1PathMutationResult.success,
      );
      expect(vfs.lookupFile('/sandbox/renamed.txt')!.bytes.single, 2);
      expect(
        vfs.removeDirectory('/sandbox/dir'),
        Preview1PathMutationResult.notEmpty,
      );

      expect(
        vfs.unlinkFile('/sandbox/Alpha.TXT'),
        Preview1PathMutationResult.success,
      );
      expect(vfs.lookupFile('/sandbox/ALPHA.TXT')!.bytes.single, 2);
      expect(
        vfs.unlinkFile('/sandbox/dir/Name.wasm'),
        Preview1PathMutationResult.success,
      );
      expect(vfs.lookupFile('/missing/NAME.WASM')!.bytes.single, 4);
      expect(
        vfs.removeDirectory('/sandbox/dir'),
        Preview1PathMutationResult.success,
      );
      expect(
        vfs.unlinkFile('/sandbox/Renamed.TXT'),
        Preview1PathMutationResult.success,
      );
      expect(vfs.lookupFile('/sandbox/renamed.txt'), isNull);
    });

    group('with instantiated module', () {
      late WASI wasi;
      late Instance instance;

      setUp(() async {
        wasi = WASI(
          args: ['app.wasm'],
          env: {'FOO': 'bar'},
          preopens: {'/sandbox': '/tmp'},
        );
        final result = await WebAssembly.instantiate(
          _wasiBytes.buffer,
          wasi.imports,
        );
        instance = result.instance;
      });

      test('instance exports _start and memory', () {
        expect(instance.exports.containsKey('_start'), isTrue);
        expect(instance.exports.containsKey('memory'), isTrue);
      });

      test('start returns exit code 42', () {
        final code = wasi.start(instance);
        expect(code, 42);
      });

      test(
        'start rethrows on proc_exit when returnOnExit is false',
        () {
          final nonReturningWasi = WASI(returnOnExit: false);
          expect(() => nonReturningWasi.start(instance), throwsA(isA<Error>()));
        },
        skip: _skipOnNode(
          'Skipping on Node.js; proc_exit may terminate process.',
        ),
      );

      test('fd_write writes bytes to stdout and returns number of bytes', () {
        final preview1 = wasi.imports['wasi_snapshot_preview1']!;
        final fdWrite = preview1['fd_write'];
        expect(fdWrite, isA<FunctionImportExportValue>());

        final memory =
            (instance.exports['memory'] as MemoryImportExportValue).ref;
        wasi.finalizeBindings(instance, memory: memory);

        final bytes = Uint8List.view(memory.buffer);
        final data = ByteData.view(memory.buffer);
        const text = 'hello wasi';
        final textBytes = utf8.encode(text);
        const iovPtr = 128;
        const bufferPtr = 256;
        const writtenPtr = 1024;

        bytes.setAll(bufferPtr, textBytes);
        data.setUint32(iovPtr, bufferPtr, Endian.little);
        data.setUint32(iovPtr + 4, textBytes.length, Endian.little);

        final result = (fdWrite as FunctionImportExportValue).ref([
          1,
          iovPtr,
          1,
          writtenPtr,
        ]);
        expect(result, 0);
        final reported = data.getUint32(writtenPtr, Endian.little);
        expect(reported, textBytes.length);
      });

      test(
        'args_sizes_get and args_get write argv pointers and data',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final argsSizesGet =
              preview1['args_sizes_get'] as FunctionImportExportValue;
          final argsGet = preview1['args_get'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const argcPtr = 1200;
          const argvBufSizePtr = 1204;
          const argvPtr = 1216;
          const argvBufPtr = 1232;

          expect(argsSizesGet.ref([argcPtr, argvBufSizePtr]), 0);
          expect(data.getUint32(argcPtr, Endian.little), 1);
          expect(data.getUint32(argvBufSizePtr, Endian.little), 9);

          expect(argsGet.ref([argvPtr, argvBufPtr]), 0);
          final firstArgPtr = data.getUint32(argvPtr, Endian.little);
          expect(firstArgPtr, argvBufPtr);
          expect(
            utf8.decode(bytes.sublist(firstArgPtr, firstArgPtr + 8)),
            'app.wasm',
          );
          expect(bytes[firstArgPtr + 8], 0);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; args behavior is delegated to node:wasi.',
        ),
      );

      test(
        'args_get returns inval for out-of-bounds argv buffer',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final argsGet = preview1['args_get'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          const argvPtr = 1000;
          final argvBufPtr = bytes.length - 4;

          final result = argsGet.ref([argvPtr, argvBufPtr]);
          expect(result, 28);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; args behavior is delegated to node:wasi.',
        ),
      );

      test(
        'environ_sizes_get and environ_get write environment pointers and data',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final environSizesGet =
              preview1['environ_sizes_get'] as FunctionImportExportValue;
          final environGet =
              preview1['environ_get'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const environCountPtr = 1240;
          const environBufSizePtr = 1244;
          const environPtr = 1260;
          const environBufPtr = 1280;

          expect(environSizesGet.ref([environCountPtr, environBufSizePtr]), 0);
          expect(data.getUint32(environCountPtr, Endian.little), 1);
          expect(data.getUint32(environBufSizePtr, Endian.little), 8);

          expect(environGet.ref([environPtr, environBufPtr]), 0);
          final firstEnvPtr = data.getUint32(environPtr, Endian.little);
          expect(firstEnvPtr, environBufPtr);
          expect(
            utf8.decode(bytes.sublist(firstEnvPtr, firstEnvPtr + 7)),
            'FOO=bar',
          );
          expect(bytes[firstEnvPtr + 7], 0);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; environ behavior is delegated to node:wasi.',
        ),
      );

      test(
        'random_get fills memory region',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final randomGet = preview1['random_get'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          const randomPtr = 1400;
          const randomLen = 32;
          bytes.fillRange(randomPtr, randomPtr + randomLen, 0xaa);

          expect(randomGet.ref([randomPtr, randomLen]), 0);
          final after = bytes.sublist(randomPtr, randomPtr + randomLen);
          expect(after.any((value) => value != 0xaa), isTrue);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; random behavior is delegated to node:wasi.',
        ),
      );

      test(
        'random_get uses Web Crypto on browser runtimes',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final randomGet = preview1['random_get'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final spy = installWebCryptoGetRandomValuesSpy();
          addTearDown(spy.restore);

          final bytes = Uint8List.view(memory.buffer);
          const randomPtr = 1440;
          const randomLen = 32;
          bytes.fillRange(randomPtr, randomPtr + randomLen, 0xaa);

          expect(randomGet.ref([randomPtr, randomLen]), 0);
          expect(spy.callCount, greaterThan(0));

          final after = bytes.sublist(randomPtr, randomPtr + randomLen);
          expect(after.any((value) => value != 0xaa), isTrue);
        },
        skip: canSpyOnWebCrypto
            ? false
            : 'Skipping outside browser JS runtimes.',
      );

      test(
        'random_get returns inval for out-of-bounds buffer',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final randomGet = preview1['random_get'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          expect(randomGet.ref([bytes.length - 8, 16]), 28);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; random behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_write returns badf for unknown descriptors',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final fdWrite = preview1['fd_write'] as FunctionImportExportValue;
          final result = fdWrite.ref([99, 0, 0, 0]);
          expect(result, 8);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; fd_write behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_write returns inval for out-of-bounds iovec',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final fdWrite = preview1['fd_write'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const iovPtr = 128;
          data.setUint32(iovPtr, bytes.length - 2, Endian.little);
          data.setUint32(iovPtr + 4, 8, Endian.little);

          final result = fdWrite.ref([1, iovPtr, 1, 0]);
          expect(result, 28);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; fd_write behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_read reports EOF with zero bytes on stdin',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final fdRead = preview1['fd_read'];
          expect(fdRead, isA<FunctionImportExportValue>());

          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final data = ByteData.view(memory.buffer);
          const iovPtr = 128;
          const bufferPtr = 512;
          const nreadPtr = 1028;

          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 8, Endian.little);
          data.setUint32(nreadPtr, 999, Endian.little);

          final result = (fdRead as FunctionImportExportValue).ref([
            0,
            iovPtr,
            1,
            nreadPtr,
          ]);
          expect(result, 0);
          expect(data.getUint32(nreadPtr, Endian.little), 0);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; fd_read behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_read reads configured stdin bytes and advances offset',
        () async {
          final inputWasi = WASI(stdinData: utf8.encode('hello stdin'));
          final inputResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            inputWasi.imports,
          );
          final inputInstance = inputResult.instance;
          final preview1 = inputWasi.imports['wasi_snapshot_preview1']!;
          final fdRead = preview1['fd_read'] as FunctionImportExportValue;
          final memory =
              (inputInstance.exports['memory'] as MemoryImportExportValue).ref;
          inputWasi.finalizeBindings(inputInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const iovPtr = 1408;
          const firstBufferPtr = 1440;
          const secondBufferPtr = 1450;
          const nreadPtr = 1460;

          data.setUint32(iovPtr, firstBufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 5, Endian.little);
          data.setUint32(iovPtr + 8, secondBufferPtr, Endian.little);
          data.setUint32(iovPtr + 12, 6, Endian.little);

          expect(fdRead.ref([0, iovPtr, 2, nreadPtr]), 0);
          expect(data.getUint32(nreadPtr, Endian.little), 11);
          expect(
            utf8.decode(bytes.sublist(firstBufferPtr, firstBufferPtr + 5)),
            'hello',
          );
          expect(
            utf8.decode(bytes.sublist(secondBufferPtr, secondBufferPtr + 6)),
            ' stdin',
          );

          data.setUint32(nreadPtr, 123, Endian.little);
          expect(fdRead.ref([0, iovPtr, 2, nreadPtr]), 0);
          expect(data.getUint32(nreadPtr, Endian.little), 0);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; fd_read behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_read returns badf for unknown descriptors',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final fdRead = preview1['fd_read'] as FunctionImportExportValue;
          final result = fdRead.ref([99, 0, 0, 0]);
          expect(result, 8);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; fd_read behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_close returns badf for unknown descriptors',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final fdClose = preview1['fd_close'];
          expect(fdClose, isA<FunctionImportExportValue>());

          final result = (fdClose as FunctionImportExportValue).ref([42]);
          expect(result, 8);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; fd_close behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_close closes preopen descriptors without closing opened directories',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/assets/doom1.wad': Uint8List.fromList([7, 8, 9]),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final fdClose = preview1['fd_close'] as FunctionImportExportValue;
          final fdFdstatGet =
              preview1['fd_fdstat_get'] as FunctionImportExportValue;
          final fdPrestatGet =
              preview1['fd_prestat_get'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const pathPtr = 1500;
          const openedFdPtr = 1532;
          const fdstatPtr = 1548;
          final dirPath = utf8.encode('assets');
          bytes.setAll(pathPtr, dirPath);

          expect(
            pathOpen.ref([
              3,
              0,
              pathPtr,
              dirPath.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final openedDirFd = data.getUint32(openedFdPtr, Endian.little);
          expect(openedDirFd, greaterThan(3));

          expect(fdClose.ref([3]), 0);
          expect(fdFdstatGet.ref([3, fdstatPtr]), _errnoBadf);
          expect(fdPrestatGet.ref([3, fdstatPtr]), _errnoBadf);
          expect(fdFdstatGet.ref([openedDirFd, fdstatPtr]), 0);
          expect(bytes[fdstatPtr], 3);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; fd_close behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_fdstat_get writes a character-device descriptor for stdio',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final fdFdstatGet =
              preview1['fd_fdstat_get'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          const fdstatPtr = 1500;
          bytes.fillRange(fdstatPtr, fdstatPtr + 24, 0xff);

          final result = fdFdstatGet.ref([1, fdstatPtr]);
          expect(result, 0);
          expect(bytes[fdstatPtr], 2);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; fd_fdstat_get behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_fdstat_get returns badf for unknown descriptors',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final fdFdstatGet =
              preview1['fd_fdstat_get'] as FunctionImportExportValue;
          final result = fdFdstatGet.ref([42, 0]);
          expect(result, 8);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; fd_fdstat_get behavior is delegated to node:wasi.',
        ),
      );

      test(
        'clock_time_get writes a non-zero timestamp',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final clockTimeGet =
              preview1['clock_time_get'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final data = ByteData.view(memory.buffer);
          const timePtr = 1600;
          _setUint64Le(data, timePtr, 0);

          final result = clockTimeGet.ref([0, 0, timePtr]);
          expect(result, 0);
          expect(_getUint64Le(data, timePtr), greaterThan(0));
        },
        skip: _skipOnNode(
          'Skipping on Node.js; clock_time_get behavior is delegated to node:wasi.',
        ),
      );

      test(
        'clock_time_get returns inval for out-of-bounds pointer',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final clockTimeGet =
              preview1['clock_time_get'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final result = clockTimeGet.ref([0, 0, bytes.length - 4]);
          expect(result, 28);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; clock_time_get behavior is delegated to node:wasi.',
        ),
      );

      test(
        'clock_time_get returns inval for unsupported clock ids',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final clockTimeGet =
              preview1['clock_time_get'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final data = ByteData.view(memory.buffer);
          const timePtr = 1610;
          _setUint64Le(data, timePtr, 123);

          final result = clockTimeGet.ref([99, 0, timePtr]);
          expect(result, 28);
          expect(_getUint64Le(data, timePtr), 123);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; clock_time_get behavior is delegated to node:wasi.',
        ),
      );

      test(
        'clock_res_get writes a non-zero resolution for supported clocks',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final clockResGet =
              preview1['clock_res_get'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final data = ByteData.view(memory.buffer);
          const resolutionPtr = 1700;

          for (final clockId in _supportedClockIds) {
            _setUint64Le(data, resolutionPtr, 0);
            final result = clockResGet.ref([clockId, resolutionPtr]);
            expect(
              result,
              0,
              reason: 'clock_res_get should support clock $clockId',
            );
            expect(
              _getUint64Le(data, resolutionPtr),
              greaterThan(0),
              reason:
                  'clock_res_get should write a non-zero resolution for clock $clockId',
            );
          }
        },
        skip: _skipOnNode(
          'Skipping on Node.js; clock_res_get behavior is delegated to node:wasi.',
        ),
      );

      test(
        'clock_res_get returns inval for unsupported clock ids',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final clockResGet =
              preview1['clock_res_get'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final data = ByteData.view(memory.buffer);
          const resolutionPtr = 1710;
          _setUint64Le(data, resolutionPtr, 123);

          final result = clockResGet.ref([99, resolutionPtr]);
          expect(result, 28);
          expect(_getUint64Le(data, resolutionPtr), 123);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; clock_res_get behavior is delegated to node:wasi.',
        ),
      );

      test(
        'clock_res_get returns inval for out-of-bounds pointer',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final clockResGet =
              preview1['clock_res_get'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final result = clockResGet.ref([0, bytes.length - 4]);
          expect(result, 28);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; clock_res_get behavior is delegated to node:wasi.',
        ),
      );

      test('finalizeBindings accepts explicit memory and reuses it later', () {
        final memoryValue = instance.exports['memory'];
        expect(memoryValue, isA<MemoryImportExportValue>());
        final memory = (memoryValue as MemoryImportExportValue).ref;

        final memoryAwareWasi = WASI();
        memoryAwareWasi.finalizeBindings(instance, memory: memory);
        expect(
          () => memoryAwareWasi.finalizeBindings(instance),
          returnsNormally,
        );
      });

      test(
        'custom stdio descriptors are honored by fd_read/fd_write/fd_close',
        () async {
          final customWasi = WASI(stdin: 10, stdout: 11, stderr: 12);
          final customResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            customWasi.imports,
          );
          final customInstance = customResult.instance;
          final preview1 = customWasi.imports['wasi_snapshot_preview1']!;
          final fdWrite = preview1['fd_write'] as FunctionImportExportValue;
          final fdRead = preview1['fd_read'] as FunctionImportExportValue;
          final fdClose = preview1['fd_close'] as FunctionImportExportValue;
          final memory =
              (customInstance.exports['memory'] as MemoryImportExportValue).ref;
          customWasi.finalizeBindings(customInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const text = 'ok';
          final textBytes = utf8.encode(text);
          const iovPtr = 1900;
          const bufferPtr = 1910;
          const writtenPtr = 1920;
          const nreadPtr = 1930;

          bytes.setAll(bufferPtr, textBytes);
          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, textBytes.length, Endian.little);

          expect(fdWrite.ref([11, iovPtr, 1, writtenPtr]), 0);
          expect(fdRead.ref([10, iovPtr, 1, nreadPtr]), 0);
          expect(fdClose.ref([11]), 0);
          expect(fdClose.ref([12]), 0);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; descriptor behavior is delegated to node:wasi.',
        ),
      );

      test(
        'proc_raise validates preview1 signals while basic scheduling syscalls succeed',
        () async {
          final raisedSignals = <WASIProcessSignal>[];
          final signalWasi = WASI(
            procRaiseHandler: raisedSignals.add,
            args: ['app.wasm'],
            env: {'FOO': 'bar'},
            preopens: {'/sandbox': '/tmp'},
          );
          final signalResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            signalWasi.imports,
          );
          final signalInstance = signalResult.instance;
          final preview1 = signalWasi.imports['wasi_snapshot_preview1']!;
          final schedYield =
              preview1['sched_yield'] as FunctionImportExportValue;
          final pollOneoff =
              preview1['poll_oneoff'] as FunctionImportExportValue;
          final procRaise = preview1['proc_raise'] as FunctionImportExportValue;
          final memory =
              (signalInstance.exports['memory'] as MemoryImportExportValue).ref;
          signalWasi.finalizeBindings(signalInstance, memory: memory);

          final data = ByteData.view(memory.buffer);
          const inPtr = 2200;
          const outPtr = 2300;
          const neventsPtr = 2400;
          data.setUint32(inPtr, 0x11223344, Endian.little);
          data.setUint32(inPtr + 4, 0x55667788, Endian.little);
          data.setUint8(inPtr + 8, 0); // clock event

          expect(await _awaitMaybeFuture(schedYield.ref(const [])), 0);
          expect(
            await _awaitMaybeFuture(
              pollOneoff.ref([inPtr, outPtr, 1, neventsPtr]),
            ),
            0,
          );
          expect(data.getUint32(neventsPtr, Endian.little), 1);
          expect(data.getUint32(outPtr, Endian.little), 0x11223344);
          expect(data.getUint32(outPtr + 4, Endian.little), 0x55667788);
          expect(data.getUint8(outPtr + 10), 0);
          expect(procRaise.ref([15]), 0);
          expect(raisedSignals, [WASIProcessSignal.term]);
          expect(procRaise.ref([0]), _errnoInval);
          expect(procRaise.ref([31]), _errnoInval);
          expect(raisedSignals, [WASIProcessSignal.term]);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; syscall behavior is delegated to node:wasi.',
        ),
      );

      test(
        'poll_oneoff rejects zero subscriptions without memory side effects',
        () async {
          final pollWasi = WASI();
          final pollResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            pollWasi.imports,
          );
          final pollInstance = pollResult.instance;
          final pollOneoff =
              pollWasi.imports['wasi_snapshot_preview1']!['poll_oneoff']
                  as FunctionImportExportValue;
          final memory =
              (pollInstance.exports['memory'] as MemoryImportExportValue).ref;
          pollWasi.finalizeBindings(pollInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const inPtr = 2200;
          const outPtr = 2300;
          const neventsPtr = 2400;
          bytes.fillRange(outPtr, outPtr + _eventSize, 0xaa);
          data.setUint32(neventsPtr, 0xdeadbeef, Endian.little);

          expect(
            await _awaitMaybeFuture(
              pollOneoff.ref([inPtr, outPtr, 0, neventsPtr]),
            ),
            _errnoInval,
          );
          expect(data.getUint32(neventsPtr, Endian.little), 0xdeadbeef);
          expect(
            bytes.sublist(outPtr, outPtr + _eventSize),
            everyElement(0xaa),
          );
        },
        skip: _skipOnNode(
          'Skipping on Node.js; syscall behavior is delegated to node:wasi.',
        ),
      );

      test(
        'poll_oneoff reports invalid clock subscriptions as event errors',
        () async {
          final pollWasi = WASI();
          final pollResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            pollWasi.imports,
          );
          final pollInstance = pollResult.instance;
          final pollOneoff =
              pollWasi.imports['wasi_snapshot_preview1']!['poll_oneoff']
                  as FunctionImportExportValue;
          final memory =
              (pollInstance.exports['memory'] as MemoryImportExportValue).ref;
          pollWasi.finalizeBindings(pollInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const inPtr = 2448;
          const outPtr = 2544;
          const neventsPtr = 2640;

          _writePollSubscription(
            data,
            inPtr,
            userdata: 0x9901,
            tag: _eventTypeClock,
          );
          data.setUint32(inPtr + _subscriptionClockIdOffset, 99, Endian.little);
          expect(
            await _awaitMaybeFuture(
              pollOneoff.ref([inPtr, outPtr, 1, neventsPtr]),
            ),
            0,
          );
          expect(data.getUint32(neventsPtr, Endian.little), 1);
          expect(_getUint64Le(data, outPtr), 0x9901);
          expect(bytes[outPtr + _eventTypeOffset], _eventTypeClock);
          expect(
            data.getUint16(outPtr + _eventErrorOffset, Endian.little),
            _errnoInval,
          );

          bytes.fillRange(outPtr, outPtr + _eventSize, 0xff);
          data.setUint32(neventsPtr, 0xfeedface, Endian.little);
          _writePollSubscription(
            data,
            inPtr,
            userdata: 0x9902,
            tag: _eventTypeClock,
          );
          data.setUint32(inPtr + _subscriptionClockIdOffset, 0, Endian.little);
          data.setUint16(
            inPtr + _subscriptionClockFlagsOffset,
            2,
            Endian.little,
          );
          expect(
            await _awaitMaybeFuture(
              pollOneoff.ref([inPtr, outPtr, 1, neventsPtr]),
            ),
            0,
          );
          expect(data.getUint32(neventsPtr, Endian.little), 1);
          expect(_getUint64Le(data, outPtr), 0x9902);
          expect(bytes[outPtr + _eventTypeOffset], _eventTypeClock);
          expect(
            data.getUint16(outPtr + _eventErrorOffset, Endian.little),
            _errnoInval,
          );
        },
        skip: _skipOnNode(
          'Skipping on Node.js; poll_oneoff behavior is delegated to node:wasi.',
        ),
      );

      test(
        'proc_raise returns nosys in browsers without a handler',
        () async {
          final browserWasi = WASI();
          final browserResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            browserWasi.imports,
          );
          final browserInstance = browserResult.instance;
          final procRaise =
              browserWasi.imports['wasi_snapshot_preview1']!['proc_raise']
                  as FunctionImportExportValue;
          final memory =
              (browserInstance.exports['memory'] as MemoryImportExportValue)
                  .ref;
          browserWasi.finalizeBindings(browserInstance, memory: memory);

          expect(procRaise.ref([15]), 52);
        },
        skip: _skipUnlessBrowser(
          'Skipping outside browser JS runtimes; native proc_raise can signal.',
        ),
      );

      test(
        'poll_oneoff reports preview1 socket read readiness and hangup',
        () async {
          final readable = WASIPreview1Socket(receiveData: utf8.encode('abc'));
          final waiting = WASIPreview1Socket();
          final closed = WASIPreview1Socket();
          closed.shutdown(receive: true, send: false);
          final socketWasi = WASI(
            sockets: {22: readable, 23: waiting, 24: closed},
          );
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final pollOneoff =
              preview1['poll_oneoff'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const inPtr = 2416;
          const outPtr = 2560;
          const neventsPtr = 2688;

          _writePollSubscription(
            data,
            inPtr,
            userdata: 0x1101,
            tag: _eventTypeFdRead,
            fd: 22,
          );
          expect(
            await _awaitMaybeFuture(
              pollOneoff.ref([inPtr, outPtr, 1, neventsPtr]),
            ),
            0,
          );
          expect(data.getUint32(neventsPtr, Endian.little), 1);
          expect(_getUint64Le(data, outPtr), 0x1101);
          expect(data.getUint16(outPtr + _eventErrorOffset, Endian.little), 0);
          expect(bytes[outPtr + _eventTypeOffset], _eventTypeFdRead);
          expect(_getUint64Le(data, outPtr + _eventFdReadwriteNbytesOffset), 3);
          expect(
            data.getUint16(
              outPtr + _eventFdReadwriteFlagsOffset,
              Endian.little,
            ),
            0,
          );

          bytes.fillRange(outPtr, outPtr + _eventSize * 2, 0xff);
          _writePollSubscription(
            data,
            inPtr,
            userdata: 0x2202,
            tag: _eventTypeFdRead,
            fd: 23,
          );
          _writePollSubscription(
            data,
            inPtr + _subscriptionSize,
            userdata: 0x3303,
            tag: _eventTypeClock,
          );
          expect(
            await _awaitMaybeFuture(
              pollOneoff.ref([inPtr, outPtr, 2, neventsPtr]),
            ),
            0,
          );
          expect(data.getUint32(neventsPtr, Endian.little), 1);
          expect(_getUint64Le(data, outPtr), 0x3303);
          expect(bytes[outPtr + _eventTypeOffset], _eventTypeClock);

          _writePollSubscription(
            data,
            inPtr,
            userdata: 0x4404,
            tag: _eventTypeFdRead,
            fd: 24,
          );
          expect(
            await _awaitMaybeFuture(
              pollOneoff.ref([inPtr, outPtr, 1, neventsPtr]),
            ),
            0,
          );
          expect(data.getUint32(neventsPtr, Endian.little), 1);
          expect(_getUint64Le(data, outPtr), 0x4404);
          expect(bytes[outPtr + _eventTypeOffset], _eventTypeFdRead);
          expect(_getUint64Le(data, outPtr + _eventFdReadwriteNbytesOffset), 0);
          expect(
            data.getUint16(
              outPtr + _eventFdReadwriteFlagsOffset,
              Endian.little,
            ),
            _eventrwflagFdReadwriteHangup,
          );
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'poll_oneoff reports socket write readiness and rights errors',
        () async {
          final socket = WASIPreview1Socket();
          final restricted = WASIPreview1Socket();
          final closedWrite = WASIPreview1Socket();
          closedWrite.shutdown(receive: false, send: true);
          final socketWasi = WASI(
            sockets: {25: socket, 26: restricted, 27: closedWrite},
          );
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final pollOneoff =
              preview1['poll_oneoff'] as FunctionImportExportValue;
          final fdFdstatSetRights =
              preview1['fd_fdstat_set_rights'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const inPtr = 2704;
          const outPtr = 2816;
          const neventsPtr = 2928;

          _writePollSubscription(
            data,
            inPtr,
            userdata: 0x5505,
            tag: _eventTypeFdWrite,
            fd: 25,
          );
          expect(
            await _awaitMaybeFuture(
              pollOneoff.ref([inPtr, outPtr, 1, neventsPtr]),
            ),
            0,
          );
          expect(data.getUint32(neventsPtr, Endian.little), 1);
          expect(_getUint64Le(data, outPtr), 0x5505);
          expect(data.getUint16(outPtr + _eventErrorOffset, Endian.little), 0);
          expect(bytes[outPtr + _eventTypeOffset], _eventTypeFdWrite);

          expect(fdFdstatSetRights.ref([26, _rightFdWrite, _rightFdWrite]), 0);
          _writePollSubscription(
            data,
            inPtr,
            userdata: 0x6606,
            tag: _eventTypeFdWrite,
            fd: 26,
          );
          expect(
            await _awaitMaybeFuture(
              pollOneoff.ref([inPtr, outPtr, 1, neventsPtr]),
            ),
            0,
          );
          expect(data.getUint32(neventsPtr, Endian.little), 1);
          expect(_getUint64Le(data, outPtr), 0x6606);
          expect(
            data.getUint16(outPtr + _eventErrorOffset, Endian.little),
            _errnoNotcapable,
          );
          expect(bytes[outPtr + _eventTypeOffset], _eventTypeFdWrite);

          _writePollSubscription(
            data,
            inPtr,
            userdata: 0x7707,
            tag: _eventTypeFdWrite,
            fd: 27,
          );
          data.setUint32(neventsPtr, 0xfeedface, Endian.little);
          bytes.fillRange(outPtr, outPtr + _eventSize, 0xff);
          expect(
            await _awaitMaybeFuture(
              pollOneoff.ref([inPtr, outPtr, 1, neventsPtr]),
            ),
            0,
          );
          expect(data.getUint32(neventsPtr, Endian.little), 1);
          expect(_getUint64Le(data, outPtr), 0x7707);
          expect(data.getUint16(outPtr + _eventErrorOffset, Endian.little), 0);
          expect(bytes[outPtr + _eventTypeOffset], _eventTypeFdWrite);
          expect(_getUint64Le(data, outPtr + _eventFdReadwriteNbytesOffset), 0);
          expect(
            data.getUint16(
              outPtr + _eventFdReadwriteFlagsOffset,
              Endian.little,
            ),
            _eventrwflagFdReadwriteHangup,
          );
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'poll_oneoff reports host socket readiness hints',
        () async {
          final external = WASIPreview1Socket(
            readReadyBytes: 77,
            writeReady: false,
          );
          final datagram = WASIPreview1Socket.datagram(readReadyBytes: 5);
          final socketWasi = WASI(sockets: {29: external, 31: datagram});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final pollOneoff =
              preview1['poll_oneoff'] as FunctionImportExportValue;
          final sockSend = preview1['sock_send'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const inPtr = 3544;
          const outPtr = 3664;
          const neventsPtr = 3792;
          const sendIovPtr = 3808;
          const sendBufferPtr = 3840;
          const sendCountPtr = 3872;

          _writePollSubscription(
            data,
            inPtr,
            userdata: 0x9909,
            tag: _eventTypeFdRead,
            fd: 29,
          );
          expect(
            await _awaitMaybeFuture(
              pollOneoff.ref([inPtr, outPtr, 1, neventsPtr]),
            ),
            0,
          );
          expect(data.getUint32(neventsPtr, Endian.little), 1);
          expect(_getUint64Le(data, outPtr), 0x9909);
          expect(data.getUint16(outPtr + _eventErrorOffset, Endian.little), 0);
          expect(bytes[outPtr + _eventTypeOffset], _eventTypeFdRead);
          expect(
            _getUint64Le(data, outPtr + _eventFdReadwriteNbytesOffset),
            77,
          );
          expect(
            data.getUint16(
              outPtr + _eventFdReadwriteFlagsOffset,
              Endian.little,
            ),
            0,
          );

          bytes.fillRange(outPtr, outPtr + _eventSize, 0xff);
          _writePollSubscription(
            data,
            inPtr,
            userdata: 0x9911,
            tag: _eventTypeFdRead,
            fd: 31,
          );
          expect(
            await _awaitMaybeFuture(
              pollOneoff.ref([inPtr, outPtr, 1, neventsPtr]),
            ),
            0,
          );
          expect(data.getUint32(neventsPtr, Endian.little), 1);
          expect(_getUint64Le(data, outPtr), 0x9911);
          expect(data.getUint16(outPtr + _eventErrorOffset, Endian.little), 0);
          expect(bytes[outPtr + _eventTypeOffset], _eventTypeFdRead);
          expect(_getUint64Le(data, outPtr + _eventFdReadwriteNbytesOffset), 5);
          expect(
            data.getUint16(
              outPtr + _eventFdReadwriteFlagsOffset,
              Endian.little,
            ),
            0,
          );

          bytes.fillRange(outPtr, outPtr + _eventSize * 2, 0xff);
          _writePollSubscription(
            data,
            inPtr,
            userdata: 0xaa0a,
            tag: _eventTypeFdWrite,
            fd: 29,
          );
          _writePollSubscription(
            data,
            inPtr + _subscriptionSize,
            userdata: 0xbb0b,
            tag: _eventTypeClock,
          );
          expect(
            await _awaitMaybeFuture(
              pollOneoff.ref([inPtr, outPtr, 2, neventsPtr]),
            ),
            0,
          );
          expect(data.getUint32(neventsPtr, Endian.little), 1);
          expect(_getUint64Le(data, outPtr), 0xbb0b);
          expect(bytes[outPtr + _eventTypeOffset], _eventTypeClock);

          bytes.setAll(sendBufferPtr, utf8.encode('send'));
          data.setUint32(sendIovPtr, sendBufferPtr, Endian.little);
          data.setUint32(sendIovPtr + 4, 4, Endian.little);
          data.setUint32(sendCountPtr, 0xdeadbeef, Endian.little);
          expect(
            sockSend.ref([29, sendIovPtr, 1, 0, sendCountPtr]),
            _errnoAgain,
          );
          expect(data.getUint32(sendCountPtr, Endian.little), 0xdeadbeef);
          expect(external.sentData, isEmpty);

          external.writeReady = true;
          _writePollSubscription(
            data,
            inPtr,
            userdata: 0xcc0c,
            tag: _eventTypeFdWrite,
            fd: 29,
          );
          expect(
            await _awaitMaybeFuture(
              pollOneoff.ref([inPtr, outPtr, 1, neventsPtr]),
            ),
            0,
          );
          expect(data.getUint32(neventsPtr, Endian.little), 1);
          expect(_getUint64Le(data, outPtr), 0xcc0c);
          expect(bytes[outPtr + _eventTypeOffset], _eventTypeFdWrite);

          expect(sockSend.ref([29, sendIovPtr, 1, 0, sendCountPtr]), 0);
          expect(data.getUint32(sendCountPtr, Endian.little), 4);
          expect(utf8.decode(external.sentData), 'send');
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'poll_oneoff ignores zero-byte stream readiness hints',
        () async {
          final socket = WASIPreview1Socket(readReadyBytes: 0);
          final socketWasi = WASI(sockets: {37: socket});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final pollOneoff =
              preview1['poll_oneoff'] as FunctionImportExportValue;
          final sockRecv = preview1['sock_recv'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const inPtr = 5024;
          const outPtr = 5136;
          const neventsPtr = 5248;
          const iovPtr = 5264;
          const bufferPtr = 5296;
          const countPtr = 5328;
          const flagsPtr = 5344;

          _writePollSubscription(
            data,
            inPtr,
            userdata: 0x1010,
            tag: _eventTypeFdRead,
            fd: 37,
          );
          _writePollSubscription(
            data,
            inPtr + _subscriptionSize,
            userdata: 0x2020,
            tag: _eventTypeClock,
          );
          expect(
            await _awaitMaybeFuture(
              pollOneoff.ref([inPtr, outPtr, 2, neventsPtr]),
            ),
            0,
          );
          expect(data.getUint32(neventsPtr, Endian.little), 1);
          expect(_getUint64Le(data, outPtr), 0x2020);
          expect(bytes[outPtr + _eventTypeOffset], _eventTypeClock);

          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 4, Endian.little);
          data.setUint32(countPtr, 0xfeedface, Endian.little);
          data.setUint16(flagsPtr, 0xbeef, Endian.little);
          expect(
            sockRecv.ref([37, iovPtr, 1, 0, countPtr, flagsPtr]),
            _errnoAgain,
          );
          expect(data.getUint32(countPtr, Endian.little), 0xfeedface);
          expect(data.getUint16(flagsPtr, Endian.little), 0xbeef);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'poll_oneoff pulls host-backed stream provider readiness',
        () async {
          final receiveSource = utf8.encode('io');
          var receiveOffset = 0;
          var providerCalls = 0;
          final socket = WASIPreview1Socket(
            receiveDataProvider: (maxBytes) {
              providerCalls++;
              final remaining = receiveSource.length - receiveOffset;
              if (remaining <= 0 || maxBytes <= 0) {
                return const <int>[];
              }
              final count = maxBytes < remaining ? maxBytes : remaining;
              final chunk = receiveSource.sublist(
                receiveOffset,
                receiveOffset + count,
              );
              receiveOffset += count;
              return chunk;
            },
          );
          var deniedProviderCalls = 0;
          final deniedSocket = WASIPreview1Socket(
            receiveDataProvider: (_) {
              deniedProviderCalls++;
              return const <int>[0xff];
            },
          );
          final socketWasi = WASI(sockets: {35: socket, 36: deniedSocket});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final pollOneoff =
              preview1['poll_oneoff'] as FunctionImportExportValue;
          final sockRecv = preview1['sock_recv'] as FunctionImportExportValue;
          final fdFdstatSetRights =
              preview1['fd_fdstat_set_rights'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const inPtr = 4688;
          const outPtr = 4800;
          const neventsPtr = 4912;
          const iovPtr = 4928;
          const bufferPtr = 4960;
          const countPtr = 4992;
          const flagsPtr = 5008;

          _writePollSubscription(
            data,
            inPtr,
            userdata: 0xdd0d,
            tag: _eventTypeFdRead,
            fd: 35,
          );
          expect(
            await _awaitMaybeFuture(
              pollOneoff.ref([inPtr, outPtr, 1, neventsPtr]),
            ),
            0,
          );
          expect(data.getUint32(neventsPtr, Endian.little), 1);
          expect(_getUint64Le(data, outPtr), 0xdd0d);
          expect(bytes[outPtr + _eventTypeOffset], _eventTypeFdRead);
          expect(_getUint64Le(data, outPtr + _eventFdReadwriteNbytesOffset), 1);
          expect(providerCalls, 1);

          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 2, Endian.little);
          expect(sockRecv.ref([35, iovPtr, 1, 0, countPtr, flagsPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 2);
          expect(data.getUint16(flagsPtr, Endian.little), 0);
          expect(utf8.decode(bytes.sublist(bufferPtr, bufferPtr + 2)), 'io');
          expect(providerCalls, 2);
          expect(socket.remainingReceiveData, isEmpty);

          expect(fdFdstatSetRights.ref([36, 0, 0]), 0);
          _writePollSubscription(
            data,
            inPtr,
            userdata: 0xee0e,
            tag: _eventTypeFdRead,
            fd: 36,
          );
          expect(
            await _awaitMaybeFuture(
              pollOneoff.ref([inPtr, outPtr, 1, neventsPtr]),
            ),
            0,
          );
          expect(data.getUint32(neventsPtr, Endian.little), 1);
          expect(_getUint64Le(data, outPtr), 0xee0e);
          expect(bytes[outPtr + _eventTypeOffset], _eventTypeFdRead);
          expect(
            data.getUint16(outPtr + _eventErrorOffset, Endian.little),
            _errnoNotcapable,
          );
          expect(deniedProviderCalls, 0);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'poll_oneoff treats queued zero-length datagrams as readable',
        () async {
          final datagram = WASIPreview1Socket.datagram(
            receiveMessages: const <List<int>>[<int>[]],
          );
          final socketWasi = WASI(sockets: {27: datagram});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final pollOneoff =
              preview1['poll_oneoff'] as FunctionImportExportValue;
          final sockRecv = preview1['sock_recv'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const inPtr = 2944;
          const outPtr = 3056;
          const neventsPtr = 3168;
          const iovPtr = 3184;
          const bufferPtr = 3216;
          const countPtr = 3248;
          const flagsPtr = 3264;

          _writePollSubscription(
            data,
            inPtr,
            userdata: 0x7707,
            tag: _eventTypeFdRead,
            fd: 27,
          );
          expect(
            await _awaitMaybeFuture(
              pollOneoff.ref([inPtr, outPtr, 1, neventsPtr]),
            ),
            0,
          );
          expect(data.getUint32(neventsPtr, Endian.little), 1);
          expect(_getUint64Le(data, outPtr), 0x7707);
          expect(data.getUint16(outPtr + _eventErrorOffset, Endian.little), 0);
          expect(bytes[outPtr + _eventTypeOffset], _eventTypeFdRead);
          expect(_getUint64Le(data, outPtr + _eventFdReadwriteNbytesOffset), 0);
          expect(
            data.getUint16(
              outPtr + _eventFdReadwriteFlagsOffset,
              Endian.little,
            ),
            0,
          );

          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 4, Endian.little);
          expect(sockRecv.ref([27, iovPtr, 1, 0, countPtr, flagsPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 0);
          expect(data.getUint16(flagsPtr, Endian.little), 0);
          expect(datagram.remainingReceiveMessages, isEmpty);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'poll_oneoff reports queued socket accepts as readable',
        () async {
          final accepted = WASIPreview1Socket(
            receiveData: utf8.encode('client'),
          );
          final listener = WASIPreview1Socket(pendingAccepted: [accepted]);
          final socketWasi = WASI(sockets: {28: listener});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final pollOneoff =
              preview1['poll_oneoff'] as FunctionImportExportValue;
          final sockAccept =
              preview1['sock_accept'] as FunctionImportExportValue;
          final fdFdstatGet =
              preview1['fd_fdstat_get'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const inPtr = 3280;
          const outPtr = 3392;
          const neventsPtr = 3504;
          const acceptedFdPtr = 3520;
          const fdstatPtr = 3536;

          _writePollSubscription(
            data,
            inPtr,
            userdata: 0x8808,
            tag: _eventTypeFdRead,
            fd: 28,
          );
          expect(
            await _awaitMaybeFuture(
              pollOneoff.ref([inPtr, outPtr, 1, neventsPtr]),
            ),
            0,
          );
          expect(data.getUint32(neventsPtr, Endian.little), 1);
          expect(_getUint64Le(data, outPtr), 0x8808);
          expect(data.getUint16(outPtr + _eventErrorOffset, Endian.little), 0);
          expect(bytes[outPtr + _eventTypeOffset], _eventTypeFdRead);
          expect(_getUint64Le(data, outPtr + _eventFdReadwriteNbytesOffset), 0);
          expect(
            data.getUint16(
              outPtr + _eventFdReadwriteFlagsOffset,
              Endian.little,
            ),
            0,
          );

          expect(sockAccept.ref([28, 0, acceptedFdPtr]), 0);
          final acceptedFd = data.getUint32(acceptedFdPtr, Endian.little);
          expect(acceptedFd, greaterThanOrEqualTo(64));
          expect(fdFdstatGet.ref([acceptedFd, fdstatPtr]), 0);
          expect(bytes[fdstatPtr], _filetypeSocketStream);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'sock_accept stops after listener receive shutdown without fd side effects',
        () async {
          final accepted = WASIPreview1Socket(
            receiveData: utf8.encode('client'),
          );
          final listener = WASIPreview1Socket(pendingAccepted: [accepted]);
          final socketWasi = WASI(sockets: {43: listener});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final pollOneoff =
              preview1['poll_oneoff'] as FunctionImportExportValue;
          final sockAccept =
              preview1['sock_accept'] as FunctionImportExportValue;
          final sockShutdown =
              preview1['sock_shutdown'] as FunctionImportExportValue;
          final fdFdstatGet =
              preview1['fd_fdstat_get'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const inPtr = 4864;
          const outPtr = 4928;
          const neventsPtr = 4992;
          const acceptedFdPtr = 5008;
          const fdstatPtr = 5024;

          expect(sockShutdown.ref([43, 1]), 0);
          _writePollSubscription(
            data,
            inPtr,
            userdata: 0x8843,
            tag: _eventTypeFdRead,
            fd: 43,
          );
          expect(
            await _awaitMaybeFuture(
              pollOneoff.ref([inPtr, outPtr, 1, neventsPtr]),
            ),
            0,
          );
          expect(data.getUint32(neventsPtr, Endian.little), 1);
          expect(_getUint64Le(data, outPtr), 0x8843);
          expect(data.getUint16(outPtr + _eventErrorOffset, Endian.little), 0);
          expect(bytes[outPtr + _eventTypeOffset], _eventTypeFdRead);
          expect(_getUint64Le(data, outPtr + _eventFdReadwriteNbytesOffset), 0);
          expect(
            data.getUint16(
              outPtr + _eventFdReadwriteFlagsOffset,
              Endian.little,
            ),
            _eventrwflagFdReadwriteHangup,
          );

          data.setUint32(acceptedFdPtr, 0xdeadbeef, Endian.little);
          expect(sockAccept.ref([43, 0, acceptedFdPtr]), _errnoAgain);
          expect(data.getUint32(acceptedFdPtr, Endian.little), 0xdeadbeef);
          expect(fdFdstatGet.ref([64, fdstatPtr]), _errnoBadf);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'poll_oneoff gates queued socket accepts on sock_accept rights',
        () async {
          final allowedListener = WASIPreview1Socket(
            pendingAccepted: [WASIPreview1Socket()],
          );
          final deniedListener = WASIPreview1Socket(
            pendingAccepted: [WASIPreview1Socket()],
          );
          final socketWasi = WASI(
            sockets: {29: allowedListener, 30: deniedListener},
          );
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final pollOneoff =
              preview1['poll_oneoff'] as FunctionImportExportValue;
          final fdFdstatSetRights =
              preview1['fd_fdstat_set_rights'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const inPtr = 3552;
          const outPtr = 3616;
          const neventsPtr = 3680;

          _writePollSubscription(
            data,
            inPtr,
            userdata: 0x9909,
            tag: _eventTypeFdRead,
            fd: 29,
          );

          expect(
            fdFdstatSetRights.ref([
              29,
              _rightPollFdReadwrite | _rightSockAccept,
              0,
            ]),
            0,
          );
          expect(
            await _awaitMaybeFuture(
              pollOneoff.ref([inPtr, outPtr, 1, neventsPtr]),
            ),
            0,
          );
          expect(data.getUint32(neventsPtr, Endian.little), 1);
          expect(_getUint64Le(data, outPtr), 0x9909);
          expect(data.getUint16(outPtr + _eventErrorOffset, Endian.little), 0);
          expect(bytes[outPtr + _eventTypeOffset], _eventTypeFdRead);

          expect(
            fdFdstatSetRights.ref([
              30,
              _rightPollFdReadwrite | _rightFdRead,
              0,
            ]),
            0,
          );
          _writePollSubscription(
            data,
            inPtr,
            userdata: 0x9910,
            tag: _eventTypeFdRead,
            fd: 30,
          );
          expect(
            await _awaitMaybeFuture(
              pollOneoff.ref([inPtr, outPtr, 1, neventsPtr]),
            ),
            0,
          );
          expect(data.getUint32(neventsPtr, Endian.little), 1);
          expect(_getUint64Le(data, outPtr), 0x9910);
          expect(
            data.getUint16(outPtr + _eventErrorOffset, Endian.little),
            _errnoNotcapable,
          );
          expect(bytes[outPtr + _eventTypeOffset], _eventTypeFdRead);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'sock_recv and sock_send use configured preview1 stream sockets',
        () async {
          final socket = WASIPreview1Socket(receiveData: utf8.encode('hello'));
          final socketWasi = WASI(sockets: {10: socket});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockRecv = preview1['sock_recv'] as FunctionImportExportValue;
          final sockSend = preview1['sock_send'] as FunctionImportExportValue;
          final fdFdstatGet =
              preview1['fd_fdstat_get'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const recvIovPtr = 2944;
          const recvBufferPtr = 2960;
          const recvCountPtr = 2992;
          const recvFlagsPtr = 3008;
          const sendIovPtr = 3024;
          const sendBufferPtr = 3040;
          const sendCountPtr = 3072;
          const fdstatPtr = 3088;

          data.setUint32(recvIovPtr, recvBufferPtr, Endian.little);
          data.setUint32(recvIovPtr + 4, 3, Endian.little);
          expect(
            sockRecv.ref([10, recvIovPtr, 1, 0, recvCountPtr, recvFlagsPtr]),
            0,
          );
          expect(data.getUint32(recvCountPtr, Endian.little), 3);
          expect(data.getUint16(recvFlagsPtr, Endian.little), 0);
          expect(
            utf8.decode(bytes.sublist(recvBufferPtr, recvBufferPtr + 3)),
            'hel',
          );

          data.setUint32(recvIovPtr + 4, 5, Endian.little);
          expect(
            sockRecv.ref([10, recvIovPtr, 1, 1, recvCountPtr, recvFlagsPtr]),
            0,
          );
          expect(data.getUint32(recvCountPtr, Endian.little), 2);
          expect(
            utf8.decode(bytes.sublist(recvBufferPtr, recvBufferPtr + 2)),
            'lo',
          );
          expect(
            sockRecv.ref([10, recvIovPtr, 1, 0, recvCountPtr, recvFlagsPtr]),
            0,
          );
          expect(data.getUint32(recvCountPtr, Endian.little), 2);

          bytes.setAll(sendBufferPtr, utf8.encode('pong'));
          data.setUint32(sendIovPtr, sendBufferPtr, Endian.little);
          data.setUint32(sendIovPtr + 4, 4, Endian.little);
          expect(sockSend.ref([10, sendIovPtr, 1, 0, sendCountPtr]), 0);
          expect(data.getUint32(sendCountPtr, Endian.little), 4);
          expect(utf8.decode(socket.sentData), 'pong');

          expect(fdFdstatGet.ref([10, fdstatPtr]), 0);
          expect(bytes[fdstatPtr], _filetypeSocketStream);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_read and fd_write operate on preview1 socket descriptors',
        () async {
          final stream = WASIPreview1Socket(receiveData: utf8.encode('stream'));
          final emptyStream = WASIPreview1Socket();
          final blockedStream = WASIPreview1Socket(writeReady: false);
          final datagram = WASIPreview1Socket.datagram(
            receiveMessages: [utf8.encode('packet')],
          );
          final socketWasi = WASI(
            sockets: {
              35: stream,
              36: datagram,
              37: emptyStream,
              38: blockedStream,
            },
          );
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final fdRead = preview1['fd_read'] as FunctionImportExportValue;
          final fdWrite = preview1['fd_write'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const streamReadIovPtr = 4240;
          const streamReadBufferPtr = 4272;
          const streamReadCountPtr = 4304;
          const streamWriteIovPtr = 4320;
          const streamWriteBufferPtr = 4352;
          const streamWriteCountPtr = 4384;
          const datagramReadIovPtr = 4400;
          const datagramReadBufferPtr = 4432;
          const datagramReadCountPtr = 4464;
          const datagramWriteIovPtr = 4480;
          const datagramWriteFirstPtr = 4512;
          const datagramWriteSecondPtr = 4528;
          const datagramWriteCountPtr = 4544;
          const emptyReadIovPtr = 4560;
          const emptyReadBufferPtr = 4592;
          const emptyReadCountPtr = 4624;
          const blockedWriteIovPtr = 4640;
          const blockedWriteBufferPtr = 4672;
          const blockedWriteCountPtr = 4704;

          data.setUint32(streamReadIovPtr, streamReadBufferPtr, Endian.little);
          data.setUint32(streamReadIovPtr + 4, 6, Endian.little);
          data.setUint32(streamReadCountPtr, 0xdeadbeef, Endian.little);
          expect(fdRead.ref([35, streamReadIovPtr, 1, streamReadCountPtr]), 0);
          expect(data.getUint32(streamReadCountPtr, Endian.little), 6);
          expect(
            utf8.decode(
              bytes.sublist(streamReadBufferPtr, streamReadBufferPtr + 6),
            ),
            'stream',
          );

          bytes.setAll(streamWriteBufferPtr, utf8.encode('reply'));
          data.setUint32(
            streamWriteIovPtr,
            streamWriteBufferPtr,
            Endian.little,
          );
          data.setUint32(streamWriteIovPtr + 4, 5, Endian.little);
          data.setUint32(streamWriteCountPtr, 0xfeedface, Endian.little);
          expect(
            fdWrite.ref([35, streamWriteIovPtr, 1, streamWriteCountPtr]),
            0,
          );
          expect(data.getUint32(streamWriteCountPtr, Endian.little), 5);
          expect(utf8.decode(stream.sentData), 'reply');

          data.setUint32(
            datagramReadIovPtr,
            datagramReadBufferPtr,
            Endian.little,
          );
          data.setUint32(datagramReadIovPtr + 4, 4, Endian.little);
          data.setUint32(datagramReadCountPtr, 0xdeadbeef, Endian.little);
          expect(
            fdRead.ref([36, datagramReadIovPtr, 1, datagramReadCountPtr]),
            0,
          );
          expect(data.getUint32(datagramReadCountPtr, Endian.little), 4);
          expect(
            utf8.decode(
              bytes.sublist(datagramReadBufferPtr, datagramReadBufferPtr + 4),
            ),
            'pack',
          );
          expect(datagram.remainingReceiveMessages, isEmpty);

          bytes.setAll(datagramWriteFirstPtr, utf8.encode('da'));
          bytes.setAll(datagramWriteSecondPtr, utf8.encode('ta'));
          data.setUint32(
            datagramWriteIovPtr,
            datagramWriteFirstPtr,
            Endian.little,
          );
          data.setUint32(datagramWriteIovPtr + 4, 2, Endian.little);
          data.setUint32(
            datagramWriteIovPtr + 8,
            datagramWriteSecondPtr,
            Endian.little,
          );
          data.setUint32(datagramWriteIovPtr + 12, 2, Endian.little);
          data.setUint32(datagramWriteCountPtr, 0xfeedface, Endian.little);
          expect(
            fdWrite.ref([36, datagramWriteIovPtr, 2, datagramWriteCountPtr]),
            0,
          );
          expect(data.getUint32(datagramWriteCountPtr, Endian.little), 4);
          expect(datagram.sentMessages.map(utf8.decode).toList(), ['data']);

          data.setUint32(emptyReadIovPtr, emptyReadBufferPtr, Endian.little);
          data.setUint32(emptyReadIovPtr + 4, 4, Endian.little);
          data.setUint32(emptyReadCountPtr, 0xdeadbeef, Endian.little);
          expect(
            fdRead.ref([37, emptyReadIovPtr, 1, emptyReadCountPtr]),
            _errnoAgain,
          );
          expect(data.getUint32(emptyReadCountPtr, Endian.little), 0xdeadbeef);

          bytes.setAll(blockedWriteBufferPtr, utf8.encode('stop'));
          data.setUint32(
            blockedWriteIovPtr,
            blockedWriteBufferPtr,
            Endian.little,
          );
          data.setUint32(blockedWriteIovPtr + 4, 4, Endian.little);
          data.setUint32(blockedWriteCountPtr, 0xfeedface, Endian.little);
          expect(
            fdWrite.ref([38, blockedWriteIovPtr, 1, blockedWriteCountPtr]),
            _errnoAgain,
          );
          expect(
            data.getUint32(blockedWriteCountPtr, Endian.little),
            0xfeedface,
          );
          expect(blockedStream.sentData, isEmpty);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'positioned fd descriptor errors do not require bound memory',
        () {
          final socketWasi = WASI(sockets: {39: WASIPreview1Socket()});
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final fdPread = preview1['fd_pread'] as FunctionImportExportValue;
          final fdPwrite = preview1['fd_pwrite'] as FunctionImportExportValue;
          final fdSeek = preview1['fd_seek'] as FunctionImportExportValue;
          final fdTell = preview1['fd_tell'] as FunctionImportExportValue;

          expect(fdPread.ref([99, 0, 0, 0, 0]), _errnoBadf);
          expect(fdPwrite.ref([99, 0, 0, 0, 0]), _errnoBadf);
          expect(fdSeek.ref([99, 0, 0, 0]), _errnoBadf);
          expect(fdTell.ref([99, 0]), _errnoBadf);

          expect(fdPread.ref([39, 0, 0, 0, 0]), _errnoNotcapable);
          expect(fdPwrite.ref([39, 0, 0, 0, 0]), _errnoNotcapable);
          expect(fdSeek.ref([39, 0, 0, 0]), _errnoNotcapable);
          expect(fdTell.ref([39, 0]), _errnoNotcapable);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_filestat_get descriptor errors do not require bound memory',
        () async {
          final unboundWasi = WASI(sockets: {39: WASIPreview1Socket()});
          final unboundPreview1 =
              unboundWasi.imports['wasi_snapshot_preview1']!;
          final unboundFilestatGet =
              unboundPreview1['fd_filestat_get'] as FunctionImportExportValue;
          final unboundSetRights =
              unboundPreview1['fd_fdstat_set_rights']
                  as FunctionImportExportValue;

          expect(unboundFilestatGet.ref([99, 0]), _errnoBadf);
          expect(unboundSetRights.ref([39, 0, 0]), 0);
          expect(unboundFilestatGet.ref([39, 0]), _errnoNotcapable);

          final socketWasi = WASI(sockets: {40: WASIPreview1Socket()});
          final result = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final instance = result.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final fdFilestatGet =
              preview1['fd_filestat_get'] as FunctionImportExportValue;
          final fdFdstatSetRights =
              preview1['fd_fdstat_set_rights'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(instance, memory: memory);

          final data = ByteData.view(memory.buffer);
          final invalidFilestatPtr = memory.buffer.lengthInBytes - 1;
          data.setUint32(invalidFilestatPtr - 3, 0xfeedface, Endian.little);

          expect(fdFilestatGet.ref([99, invalidFilestatPtr]), _errnoBadf);
          expect(fdFdstatSetRights.ref([40, 0, 0]), 0);
          expect(fdFilestatGet.ref([40, invalidFilestatPtr]), _errnoNotcapable);
          expect(
            data.getUint32(invalidFilestatPtr - 3, Endian.little),
            0xfeedface,
          );
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'default socket rights expose socket-specific operations only',
        () async {
          final socket = WASIPreview1Socket();
          final socketWasi = WASI(sockets: {39: socket});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final fdFdstatGet =
              preview1['fd_fdstat_get'] as FunctionImportExportValue;
          final fdAdvise = preview1['fd_advise'] as FunctionImportExportValue;
          final fdDatasync =
              preview1['fd_datasync'] as FunctionImportExportValue;
          final fdSync = preview1['fd_sync'] as FunctionImportExportValue;
          final fdAllocate =
              preview1['fd_allocate'] as FunctionImportExportValue;
          final fdFilestatSetSize =
              preview1['fd_filestat_set_size'] as FunctionImportExportValue;
          final fdFilestatSetTimes =
              preview1['fd_filestat_set_times'] as FunctionImportExportValue;
          final fdPread = preview1['fd_pread'] as FunctionImportExportValue;
          final fdPwrite = preview1['fd_pwrite'] as FunctionImportExportValue;
          final fdSeek = preview1['fd_seek'] as FunctionImportExportValue;
          final fdTell = preview1['fd_tell'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const fdstatPtr = 4720;
          const iovPtr = 4752;
          const bufferPtr = 4776;
          const countPtr = 4800;
          const offsetPtr = 4808;
          const socketRights =
              _rightFdRead |
              _rightFdFdstatSetFlags |
              _rightFdWrite |
              _rightFdFdstatGet |
              _rightPollFdReadwrite |
              _rightSockShutdown |
              _rightSockAccept;
          const socketInheritingRights = socketRights & ~_rightSockAccept;
          const fileOnlyRights =
              _rightFdDatasync |
              _rightFdSync |
              _rightFdAdvise |
              _rightFdFilestatSetTimes;

          expect(fdFdstatGet.ref([39, fdstatPtr]), 0);
          expect(bytes[fdstatPtr], _filetypeSocketStream);
          final rightsBase = _getUint64Le(data, fdstatPtr + 8);
          final rightsInheriting = _getUint64Le(data, fdstatPtr + 16);
          expect(rightsBase, socketRights);
          expect(rightsInheriting, socketInheritingRights);
          expect(rightsBase & fileOnlyRights, 0);
          expect(rightsInheriting & _rightSockAccept, 0);

          expect(fdAdvise.ref([39, 0, 0, 0]), _errnoNotcapable);
          expect(fdDatasync.ref([39]), _errnoNotcapable);
          expect(fdSync.ref([39]), _errnoNotcapable);
          expect(fdAllocate.ref([39, 0, 1]), _errnoNotcapable);
          expect(fdFilestatSetSize.ref([39, 1]), _errnoNotcapable);
          expect(fdFilestatSetTimes.ref([39, 0, 0, 0]), _errnoNotcapable);

          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 4, Endian.little);
          data.setUint32(countPtr, 0xfeedface, Endian.little);
          expect(fdPread.ref([39, iovPtr, 1, 0, countPtr]), _errnoNotcapable);
          expect(data.getUint32(countPtr, Endian.little), 0xfeedface);

          data.setUint32(countPtr, 0xdeadbeef, Endian.little);
          expect(fdPwrite.ref([39, iovPtr, 1, 0, countPtr]), _errnoNotcapable);
          expect(data.getUint32(countPtr, Endian.little), 0xdeadbeef);

          _setUint64Le(data, offsetPtr, 0x11223344);
          expect(fdSeek.ref([39, 0, 0, offsetPtr]), _errnoNotcapable);
          expect(_getUint64Le(data, offsetPtr), 0x11223344);

          _setUint64Le(data, offsetPtr, 0x55667788);
          expect(fdTell.ref([39, offsetPtr]), _errnoNotcapable);
          expect(_getUint64Le(data, offsetPtr), 0x55667788);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'accepted sockets do not inherit listener accept rights by default',
        () async {
          final accepted = WASIPreview1Socket(
            receiveData: utf8.encode('client'),
          );
          final listener = WASIPreview1Socket(pendingAccepted: [accepted]);
          final socketWasi = WASI(sockets: {42: listener});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockAccept =
              preview1['sock_accept'] as FunctionImportExportValue;
          final sockRecv = preview1['sock_recv'] as FunctionImportExportValue;
          final fdFdstatGet =
              preview1['fd_fdstat_get'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const acceptedFdPtr = 4736;
          const fdstatPtr = 4752;
          const iovPtr = 4784;
          const bufferPtr = 4816;
          const countPtr = 4848;
          const flagsPtr = 4864;
          const socketBaseRights =
              _rightFdRead |
              _rightFdFdstatSetFlags |
              _rightFdWrite |
              _rightFdFdstatGet |
              _rightPollFdReadwrite |
              _rightSockShutdown |
              _rightSockAccept;
          const socketInheritingRights = socketBaseRights & ~_rightSockAccept;

          expect(sockAccept.ref([42, 0, acceptedFdPtr]), 0);
          final acceptedFd = data.getUint32(acceptedFdPtr, Endian.little);
          expect(fdFdstatGet.ref([acceptedFd, fdstatPtr]), 0);
          expect(bytes[fdstatPtr], _filetypeSocketStream);
          expect(_getUint64Le(data, fdstatPtr + 8), socketInheritingRights);
          expect(_getUint64Le(data, fdstatPtr + 16), 0);

          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 6, Endian.little);
          expect(
            sockRecv.ref([acceptedFd, iovPtr, 1, 0, countPtr, flagsPtr]),
            0,
          );
          expect(data.getUint32(countPtr, Endian.little), 6);
          expect(
            utf8.decode(bytes.sublist(bufferPtr, bufferPtr + 6)),
            'client',
          );

          data.setUint32(acceptedFdPtr, 0xdeadbeef, Endian.little);
          expect(
            sockAccept.ref([acceptedFd, 0, acceptedFdPtr]),
            _errnoNotcapable,
          );
          expect(data.getUint32(acceptedFdPtr, Endian.little), 0xdeadbeef);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'sock_recv and sock_send use host-backed stream handlers',
        () async {
          final receiveSource = utf8.encode('hello');
          var receiveOffset = 0;
          final sent = BytesBuilder(copy: true);
          final socket = WASIPreview1Socket(
            readReadyBytes: receiveSource.length,
            receiveDataProvider: (maxBytes) {
              final remaining = receiveSource.length - receiveOffset;
              if (remaining <= 0 || maxBytes <= 0) {
                return const <int>[];
              }
              final count = maxBytes < remaining ? maxBytes : remaining;
              final chunk = receiveSource.sublist(
                receiveOffset,
                receiveOffset + count,
              );
              receiveOffset += count;
              return chunk;
            },
            sendHandler: (source, start, length) {
              sent.add(Uint8List.sublistView(source, start, start + length));
              return length;
            },
          );
          final socketWasi = WASI(sockets: {11: socket});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockRecv = preview1['sock_recv'] as FunctionImportExportValue;
          final sockSend = preview1['sock_send'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const recvIovPtr = 3096;
          const recvBufferPtr = 3136;
          const recvCountPtr = 3184;
          const recvFlagsPtr = 3200;
          const sendIovPtr = 3216;
          const sendFirstBufferPtr = 3264;
          const sendSecondBufferPtr = 3296;
          const sendCountPtr = 3344;

          data.setUint32(recvIovPtr, recvBufferPtr, Endian.little);
          data.setUint32(recvIovPtr + 4, 5, Endian.little);
          expect(
            sockRecv.ref([11, recvIovPtr, 1, 2, recvCountPtr, recvFlagsPtr]),
            0,
          );
          expect(data.getUint32(recvCountPtr, Endian.little), 5);
          expect(data.getUint16(recvFlagsPtr, Endian.little), 0);
          expect(
            utf8.decode(bytes.sublist(recvBufferPtr, recvBufferPtr + 5)),
            'hello',
          );
          expect(receiveOffset, receiveSource.length);

          bytes.setAll(sendFirstBufferPtr, utf8.encode('ho'));
          bytes.setAll(sendSecondBufferPtr, utf8.encode('st'));
          data.setUint32(sendIovPtr, sendFirstBufferPtr, Endian.little);
          data.setUint32(sendIovPtr + 4, 2, Endian.little);
          data.setUint32(sendIovPtr + 8, sendSecondBufferPtr, Endian.little);
          data.setUint32(sendIovPtr + 12, 2, Endian.little);
          expect(sockSend.ref([11, sendIovPtr, 2, 0, sendCountPtr]), 0);
          expect(data.getUint32(sendCountPtr, Endian.little), 4);
          expect(utf8.decode(sent.toBytes()), 'host');
          expect(socket.sentData, isEmpty);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'sock_recv waitall drains chunked host stream providers',
        () async {
          final receiveSource = utf8.encode('hello');
          var receiveOffset = 0;
          var providerCalls = 0;
          final socket = WASIPreview1Socket(
            receiveDataProvider: (maxBytes) {
              providerCalls++;
              if (maxBytes <= 0 || receiveOffset >= receiveSource.length) {
                return const <int>[];
              }
              final byte = receiveSource[receiveOffset];
              receiveOffset++;
              return <int>[byte];
            },
          );
          final socketWasi = WASI(sockets: {34: socket});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockRecv = preview1['sock_recv'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const iovPtr = 4560;
          const firstBufferPtr = 4592;
          const secondBufferPtr = 4624;
          const countPtr = 4656;
          const flagsPtr = 4672;

          data.setUint32(iovPtr, firstBufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 2, Endian.little);
          data.setUint32(iovPtr + 8, secondBufferPtr, Endian.little);
          data.setUint32(iovPtr + 12, 3, Endian.little);
          data.setUint32(countPtr, 0xfeedface, Endian.little);
          data.setUint16(flagsPtr, 0xbeef, Endian.little);

          expect(
            sockRecv.ref([
              34,
              iovPtr,
              2,
              _riflagRecvWaitall,
              countPtr,
              flagsPtr,
            ]),
            0,
          );
          expect(data.getUint32(countPtr, Endian.little), 5);
          expect(data.getUint16(flagsPtr, Endian.little), 0);
          expect(
            utf8.decode(bytes.sublist(firstBufferPtr, firstBufferPtr + 2)),
            'he',
          );
          expect(
            utf8.decode(bytes.sublist(secondBufferPtr, secondBufferPtr + 3)),
            'llo',
          );
          expect(providerCalls, 5);
          expect(socket.remainingReceiveData, isEmpty);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'connected stream sockets can opt out of accept capability',
        () async {
          final socket = WASIPreview1Socket(canAccept: false);
          final socketWasi = WASI(sockets: {43: socket});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockAccept =
              preview1['sock_accept'] as FunctionImportExportValue;
          final fdFdstatGet =
              preview1['fd_fdstat_get'] as FunctionImportExportValue;
          final fdFdstatSetRights =
              preview1['fd_fdstat_set_rights'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const fdstatPtr = 4880;
          const acceptedFdPtr = 4912;

          expect(fdFdstatGet.ref([43, fdstatPtr]), 0);
          expect(bytes[fdstatPtr], _filetypeSocketStream);
          final rightsBase = _getUint64Le(data, fdstatPtr + 8);
          final rightsInheriting = _getUint64Le(data, fdstatPtr + 16);
          expect(rightsBase & _rightSockAccept, 0);
          expect(rightsInheriting & _rightSockAccept, 0);

          expect(
            fdFdstatSetRights.ref([43, _rightSockAccept, 0]),
            _errnoNotcapable,
          );
          data.setUint32(acceptedFdPtr, 0xdeadbeef, Endian.little);
          expect(sockAccept.ref([43, 0, acceptedFdPtr]), _errnoNotcapable);
          expect(data.getUint32(acceptedFdPtr, Endian.little), 0xdeadbeef);
          expect(
            () => socket.queueAccepted(WASIPreview1Socket()),
            throwsStateError,
          );
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'sock_accept returns queued preview1 stream sockets with inherited rights',
        () async {
          final accepted = WASIPreview1Socket(
            receiveData: utf8.encode('client'),
          );
          final listener = WASIPreview1Socket(pendingAccepted: [accepted]);
          final socketWasi = WASI(sockets: {20: listener});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockAccept =
              preview1['sock_accept'] as FunctionImportExportValue;
          final sockRecv = preview1['sock_recv'] as FunctionImportExportValue;
          final fdFdstatGet =
              preview1['fd_fdstat_get'] as FunctionImportExportValue;
          final fdFdstatSetRights =
              preview1['fd_fdstat_set_rights'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const acceptedFdPtr = 3120;
          const fdstatPtr = 3136;
          const iovPtr = 3168;
          const bufferPtr = 3200;
          const countPtr = 3232;
          const flagsPtr = 3248;

          expect(
            fdFdstatSetRights.ref([
              20,
              _rightSockAccept,
              _rightFdRead | _rightFdFdstatGet | _rightSockShutdown,
            ]),
            0,
          );
          expect(sockAccept.ref([20, 4, acceptedFdPtr]), 0);
          final acceptedFd = data.getUint32(acceptedFdPtr, Endian.little);
          expect(acceptedFd, greaterThanOrEqualTo(64));

          expect(fdFdstatGet.ref([acceptedFd, fdstatPtr]), 0);
          expect(bytes[fdstatPtr], _filetypeSocketStream);
          expect(data.getUint16(fdstatPtr + 2, Endian.little), 4);
          expect(
            _getUint64Le(data, fdstatPtr + 8),
            _rightFdRead | _rightFdFdstatGet | _rightSockShutdown,
          );
          expect(_getUint64Le(data, fdstatPtr + 16), 0);

          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 6, Endian.little);
          expect(
            sockRecv.ref([acceptedFd, iovPtr, 1, 0, countPtr, flagsPtr]),
            0,
          );
          expect(data.getUint32(countPtr, Endian.little), 6);
          expect(
            utf8.decode(bytes.sublist(bufferPtr, bufferPtr + 6)),
            'client',
          );
          expect(sockAccept.ref([20, 0, acceptedFdPtr]), 6);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'socket descriptor flags reject file-only flags',
        () async {
          final accepted = WASIPreview1Socket(
            receiveData: utf8.encode('client'),
          );
          final listener = WASIPreview1Socket(pendingAccepted: [accepted]);
          final blockedAccepted = WASIPreview1Socket(
            receiveData: utf8.encode('blocked'),
          );
          final blockedListener = WASIPreview1Socket(
            pendingAccepted: [blockedAccepted],
          );
          final socket = WASIPreview1Socket();
          final socketWasi = WASI(
            sockets: {20: listener, 21: socket, 22: blockedListener},
          );
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockAccept =
              preview1['sock_accept'] as FunctionImportExportValue;
          final fdFdstatGet =
              preview1['fd_fdstat_get'] as FunctionImportExportValue;
          final fdFdstatSetFlags =
              preview1['fd_fdstat_set_flags'] as FunctionImportExportValue;
          final fdFdstatSetRights =
              preview1['fd_fdstat_set_rights'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final data = ByteData.view(memory.buffer);
          const acceptedFdPtr = 3312;
          const fdstatPtr = 3328;

          expect(
            fdFdstatSetRights.ref([
              20,
              _rightSockAccept,
              _rightFdRead | _rightFdFdstatGet,
            ]),
            0,
          );
          expect(
            fdFdstatSetRights.ref([
              21,
              _rightFdFdstatGet | _rightFdFdstatSetFlags,
              0,
            ]),
            0,
          );
          expect(fdFdstatSetRights.ref([22, 0, 0]), 0);

          data.setUint32(acceptedFdPtr, 0xdeadbeef, Endian.little);
          expect(
            sockAccept.ref([1, _fdflagAppend, acceptedFdPtr]),
            _errnoNotsock,
          );
          expect(data.getUint32(acceptedFdPtr, Endian.little), 0xdeadbeef);
          expect(
            sockAccept.ref([99, _fdflagAppend, acceptedFdPtr]),
            _errnoBadf,
          );
          expect(data.getUint32(acceptedFdPtr, Endian.little), 0xdeadbeef);

          expect(
            sockAccept.ref([20, _fdflagUnknown, acceptedFdPtr]),
            _errnoInval,
          );
          expect(data.getUint32(acceptedFdPtr, Endian.little), 0xdeadbeef);

          expect(
            sockAccept.ref([20, _fdflagAppend, acceptedFdPtr]),
            _errnoNotsup,
          );
          expect(data.getUint32(acceptedFdPtr, Endian.little), 0xdeadbeef);
          expect(
            sockAccept.ref([22, _fdflagAppend, acceptedFdPtr]),
            _errnoNotsup,
          );
          expect(data.getUint32(acceptedFdPtr, Endian.little), 0xdeadbeef);
          expect(blockedListener.hasPendingAccept, isTrue);

          expect(fdFdstatSetFlags.ref([21, _fdflagUnknown]), _errnoInval);
          expect(fdFdstatSetFlags.ref([21, _fdflagAppend]), _errnoNotsup);
          expect(fdFdstatGet.ref([21, fdstatPtr]), 0);
          expect(data.getUint16(fdstatPtr + 2, Endian.little), 0);
          expect(fdFdstatSetFlags.ref([22, _fdflagAppend]), _errnoNotsup);
          expect(fdFdstatGet.ref([22, fdstatPtr]), 0);
          expect(data.getUint16(fdstatPtr + 2, Endian.little), 0);

          expect(sockAccept.ref([20, _fdflagNonblock, acceptedFdPtr]), 0);
          final acceptedFd = data.getUint32(acceptedFdPtr, Endian.little);
          expect(fdFdstatGet.ref([acceptedFd, fdstatPtr]), 0);
          expect(data.getUint16(fdstatPtr + 2, Endian.little), _fdflagNonblock);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'socket syscalls return notsock for non-socket descriptors',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final sockAccept =
              preview1['sock_accept'] as FunctionImportExportValue;
          final sockRecv = preview1['sock_recv'] as FunctionImportExportValue;
          final sockSend = preview1['sock_send'] as FunctionImportExportValue;
          final sockShutdown =
              preview1['sock_shutdown'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final data = ByteData.view(memory.buffer);
          const iovPtr = 3264;
          const bufferPtr = 3296;
          const countPtr = 3328;
          const flagsPtr = 3344;
          const acceptedFdPtr = 3360;

          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 0, Endian.little);
          data.setUint32(countPtr, 0xfeedface, Endian.little);
          data.setUint16(flagsPtr, 0xbeef, Endian.little);
          data.setUint32(acceptedFdPtr, 0xdeadbeef, Endian.little);

          expect(sockAccept.ref([3, 0, acceptedFdPtr]), _errnoNotsock);
          expect(data.getUint32(acceptedFdPtr, Endian.little), 0xdeadbeef);
          expect(
            sockRecv.ref([3, iovPtr, 1, 0, countPtr, flagsPtr]),
            _errnoNotsock,
          );
          expect(data.getUint32(countPtr, Endian.little), 0xfeedface);
          expect(data.getUint16(flagsPtr, Endian.little), 0xbeef);
          expect(sockSend.ref([3, iovPtr, 1, 0, countPtr]), _errnoNotsock);
          expect(data.getUint32(countPtr, Endian.little), 0xfeedface);
          expect(sockShutdown.ref([3, 3]), _errnoNotsock);

          expect(sockAccept.ref([99, 0, acceptedFdPtr]), _errnoBadf);
          expect(
            sockRecv.ref([99, iovPtr, 1, 0, countPtr, flagsPtr]),
            _errnoBadf,
          );
          expect(sockSend.ref([99, iovPtr, 1, 0, countPtr]), _errnoBadf);
          expect(sockShutdown.ref([99, 3]), _errnoBadf);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'datagram sockets do not expose accept rights',
        () async {
          final datagram = WASIPreview1Socket.datagram();
          final socketWasi = WASI(sockets: {21: datagram});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockAccept =
              preview1['sock_accept'] as FunctionImportExportValue;
          final fdFdstatGet =
              preview1['fd_fdstat_get'] as FunctionImportExportValue;
          final fdFdstatSetRights =
              preview1['fd_fdstat_set_rights'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final data = ByteData.view(memory.buffer);
          const acceptedFdPtr = 3264;
          const fdstatPtr = 3280;

          expect(fdFdstatGet.ref([21, fdstatPtr]), 0);
          expect(data.getUint8(fdstatPtr), _filetypeSocketDgram);
          expect(_getUint64Le(data, fdstatPtr + 8) & _rightSockAccept, 0);
          expect(_getUint64Le(data, fdstatPtr + 16), 0);

          expect(
            fdFdstatSetRights.ref([21, _rightSockAccept, _rightFdRead]),
            _errnoNotcapable,
          );
          data.setUint32(acceptedFdPtr, 0xdeadbeef, Endian.little);
          expect(sockAccept.ref([21, 0, acceptedFdPtr]), _errnoNotcapable);
          expect(data.getUint32(acceptedFdPtr, Endian.little), 0xdeadbeef);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'sock_recv returns again for sockets with no queued receive data',
        () async {
          final stream = WASIPreview1Socket();
          final datagram = WASIPreview1Socket.datagram();
          final socketWasi = WASI(sockets: {18: stream, 19: datagram});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockRecv = preview1['sock_recv'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final data = ByteData.view(memory.buffer);
          const iovPtr = 4320;
          const bufferPtr = 4352;
          const countPtr = 4384;
          const flagsPtr = 4400;

          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 4, Endian.little);
          data.setUint32(countPtr, 0xfeedface, Endian.little);
          data.setUint16(flagsPtr, 0xbeef, Endian.little);
          expect(
            sockRecv.ref([18, iovPtr, 1, 0, countPtr, flagsPtr]),
            _errnoAgain,
          );
          expect(data.getUint32(countPtr, Endian.little), 0xfeedface);
          expect(data.getUint16(flagsPtr, Endian.little), 0xbeef);

          expect(
            sockRecv.ref([19, iovPtr, 1, 0, countPtr, flagsPtr]),
            _errnoAgain,
          );
          expect(data.getUint32(countPtr, Endian.little), 0xfeedface);
          expect(data.getUint16(flagsPtr, Endian.little), 0xbeef);

          stream.shutdown(receive: true, send: false);
          datagram.shutdown(receive: true, send: false);
          expect(sockRecv.ref([18, iovPtr, 1, 0, countPtr, flagsPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 0);
          expect(data.getUint16(flagsPtr, Endian.little), 0);
          data.setUint32(countPtr, 0xfeedface, Endian.little);
          data.setUint16(flagsPtr, 0xbeef, Endian.little);
          expect(sockRecv.ref([19, iovPtr, 1, 0, countPtr, flagsPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 0);
          expect(data.getUint16(flagsPtr, Endian.little), 0);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'sock_recv and sock_send validate stream iovs before side effects',
        () async {
          final receiveSocket = WASIPreview1Socket(
            receiveData: utf8.encode('abcdef'),
          );
          final sendSocket = WASIPreview1Socket();
          final socketWasi = WASI(sockets: {32: receiveSocket, 33: sendSocket});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockRecv = preview1['sock_recv'] as FunctionImportExportValue;
          final sockSend = preview1['sock_send'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const iovPtr = 4416;
          const bufferPtr = 4464;
          const countPtr = 4528;
          const flagsPtr = 4544;
          final invalidBufferPtr = bytes.length - 2;

          bytes.fillRange(bufferPtr, bufferPtr + 6, 0xaa);
          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 3, Endian.little);
          data.setUint32(iovPtr + 8, invalidBufferPtr, Endian.little);
          data.setUint32(iovPtr + 12, 4, Endian.little);
          data.setUint32(countPtr, 0xfeedface, Endian.little);
          data.setUint16(flagsPtr, 0xbeef, Endian.little);

          expect(
            sockRecv.ref([32, iovPtr, 2, 0, countPtr, flagsPtr]),
            _errnoInval,
          );
          expect(data.getUint32(countPtr, Endian.little), 0xfeedface);
          expect(data.getUint16(flagsPtr, Endian.little), 0xbeef);
          expect(bytes.sublist(bufferPtr, bufferPtr + 3), [0xaa, 0xaa, 0xaa]);
          expect(utf8.decode(receiveSocket.remainingReceiveData), 'abcdef');

          bytes.setAll(bufferPtr, utf8.encode('out'));
          data.setUint32(countPtr, 0xfeedface, Endian.little);
          expect(sockSend.ref([33, iovPtr, 2, 0, countPtr]), _errnoInval);
          expect(data.getUint32(countPtr, Endian.little), 0xfeedface);
          expect(sendSocket.sentData, isEmpty);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'sock_recv and sock_send validate flags before descriptor rights',
        () async {
          final receiveSocket = WASIPreview1Socket(
            receiveData: utf8.encode('input'),
          );
          final sendSocket = WASIPreview1Socket();
          final socketWasi = WASI(sockets: {46: receiveSocket, 47: sendSocket});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockRecv = preview1['sock_recv'] as FunctionImportExportValue;
          final sockSend = preview1['sock_send'] as FunctionImportExportValue;
          final fdFdstatSetRights =
              preview1['fd_fdstat_set_rights'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const recvIovPtr = 4816;
          const recvBufferPtr = 4848;
          const recvCountPtr = 4880;
          const recvFlagsPtr = 4896;
          const sendIovPtr = 4912;
          const sendBufferPtr = 4944;
          const sendCountPtr = 4976;
          const recvUnknownFlag = 1 << 2;
          const sendUnknownFlag = 1;

          data.setUint32(recvIovPtr, recvBufferPtr, Endian.little);
          data.setUint32(recvIovPtr + 4, 3, Endian.little);
          bytes.setAll(sendBufferPtr, utf8.encode('out'));
          data.setUint32(sendIovPtr, sendBufferPtr, Endian.little);
          data.setUint32(sendIovPtr + 4, 3, Endian.little);
          expect(fdFdstatSetRights.ref([46, 0, 0]), 0);
          expect(fdFdstatSetRights.ref([47, 0, 0]), 0);

          data.setUint32(recvCountPtr, 0xfeedface, Endian.little);
          data.setUint16(recvFlagsPtr, 0xbeef, Endian.little);
          expect(
            sockRecv.ref([
              46,
              recvIovPtr,
              1,
              recvUnknownFlag,
              recvCountPtr,
              recvFlagsPtr,
            ]),
            _errnoInval,
          );
          expect(data.getUint32(recvCountPtr, Endian.little), 0xfeedface);
          expect(data.getUint16(recvFlagsPtr, Endian.little), 0xbeef);
          expect(utf8.decode(receiveSocket.remainingReceiveData), 'input');

          data.setUint32(sendCountPtr, 0xdeadbeef, Endian.little);
          expect(
            sockSend.ref([47, sendIovPtr, 1, sendUnknownFlag, sendCountPtr]),
            _errnoInval,
          );
          expect(data.getUint32(sendCountPtr, Endian.little), 0xdeadbeef);
          expect(sendSocket.sentData, isEmpty);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'sock_recv snapshots iovs before writing receive buffers',
        () async {
          final stream = WASIPreview1Socket(
            receiveData: utf8.encode('abcdefghij'),
          );
          final datagram = WASIPreview1Socket.datagram(
            receiveMessages: [utf8.encode('klmnopqrst')],
          );
          final socketWasi = WASI(sockets: {44: stream, 45: datagram});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockRecv = preview1['sock_recv'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const streamIovPtr = 4560;
          const streamFirstBufferPtr = streamIovPtr + 8;
          const streamSecondBufferPtr = 4624;
          const streamCountPtr = 4656;
          const streamFlagsPtr = 4672;
          const datagramIovPtr = 4688;
          const datagramFirstBufferPtr = datagramIovPtr + 8;
          const datagramSecondBufferPtr = 4752;
          const datagramCountPtr = 4784;
          const datagramFlagsPtr = 4800;

          data.setUint32(streamIovPtr, streamFirstBufferPtr, Endian.little);
          data.setUint32(streamIovPtr + 4, 8, Endian.little);
          data.setUint32(
            streamIovPtr + 8,
            streamSecondBufferPtr,
            Endian.little,
          );
          data.setUint32(streamIovPtr + 12, 2, Endian.little);
          expect(
            sockRecv.ref([
              44,
              streamIovPtr,
              2,
              0,
              streamCountPtr,
              streamFlagsPtr,
            ]),
            0,
          );
          expect(data.getUint32(streamCountPtr, Endian.little), 10);
          expect(data.getUint16(streamFlagsPtr, Endian.little), 0);
          expect(
            utf8.decode(
              bytes.sublist(streamFirstBufferPtr, streamFirstBufferPtr + 8),
            ),
            'abcdefgh',
          );
          expect(
            utf8.decode(
              bytes.sublist(streamSecondBufferPtr, streamSecondBufferPtr + 2),
            ),
            'ij',
          );
          expect(stream.remainingReceiveData, isEmpty);

          data.setUint32(datagramIovPtr, datagramFirstBufferPtr, Endian.little);
          data.setUint32(datagramIovPtr + 4, 8, Endian.little);
          data.setUint32(
            datagramIovPtr + 8,
            datagramSecondBufferPtr,
            Endian.little,
          );
          data.setUint32(datagramIovPtr + 12, 2, Endian.little);
          expect(
            sockRecv.ref([
              45,
              datagramIovPtr,
              2,
              0,
              datagramCountPtr,
              datagramFlagsPtr,
            ]),
            0,
          );
          expect(data.getUint32(datagramCountPtr, Endian.little), 10);
          expect(data.getUint16(datagramFlagsPtr, Endian.little), 0);
          expect(
            utf8.decode(
              bytes.sublist(datagramFirstBufferPtr, datagramFirstBufferPtr + 8),
            ),
            'klmnopqr',
          );
          expect(
            utf8.decode(
              bytes.sublist(
                datagramSecondBufferPtr,
                datagramSecondBufferPtr + 2,
              ),
            ),
            'st',
          );
          expect(datagram.remainingReceiveMessages, isEmpty);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'sock_recv handles multi-iov peek without consuming socket data',
        () async {
          final socket = WASIPreview1Socket(receiveData: utf8.encode('abcdef'));
          final socketWasi = WASI(sockets: {12: socket});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockRecv = preview1['sock_recv'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const iovPtr = 3360;
          const firstBufferPtr = 3392;
          const secondBufferPtr = 3424;
          const countPtr = 3456;
          const flagsPtr = 3472;

          data.setUint32(iovPtr, firstBufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 2, Endian.little);
          data.setUint32(iovPtr + 8, secondBufferPtr, Endian.little);
          data.setUint32(iovPtr + 12, 3, Endian.little);
          expect(sockRecv.ref([12, iovPtr, 2, 1, countPtr, flagsPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 5);
          expect(
            utf8.decode(bytes.sublist(firstBufferPtr, firstBufferPtr + 2)),
            'ab',
          );
          expect(
            utf8.decode(bytes.sublist(secondBufferPtr, secondBufferPtr + 3)),
            'cde',
          );
          expect(utf8.decode(socket.remainingReceiveData), 'abcdef');

          data.setUint32(iovPtr, firstBufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 6, Endian.little);
          expect(sockRecv.ref([12, iovPtr, 1, 0, countPtr, flagsPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 6);
          expect(
            utf8.decode(bytes.sublist(firstBufferPtr, firstBufferPtr + 6)),
            'abcdef',
          );
          expect(socket.remainingReceiveData, isEmpty);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'sock_recv waitall returns again without consuming partial stream data',
        () async {
          final socket = WASIPreview1Socket(receiveData: utf8.encode('abc'));
          final socketWasi = WASI(sockets: {13: socket});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockRecv = preview1['sock_recv'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const iovPtr = 3696;
          const bufferPtr = 3728;
          const countPtr = 3760;
          const flagsPtr = 3776;

          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 4, Endian.little);
          expect(
            sockRecv.ref([13, iovPtr, 1, 2, countPtr, flagsPtr]),
            _errnoAgain,
          );
          expect(utf8.decode(socket.remainingReceiveData), 'abc');

          socket.addReceiveData(utf8.encode('d'));
          expect(sockRecv.ref([13, iovPtr, 1, 2, countPtr, flagsPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 4);
          expect(data.getUint16(flagsPtr, Endian.little), 0);
          expect(utf8.decode(bytes.sublist(bufferPtr, bufferPtr + 4)), 'abcd');
          expect(socket.remainingReceiveData, isEmpty);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'sock_recv keeps truncation flag clear for byte-stream partial reads',
        () async {
          final socket = WASIPreview1Socket(receiveData: utf8.encode('abcdef'));
          final socketWasi = WASI(sockets: {14: socket});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockRecv = preview1['sock_recv'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const iovPtr = 3792;
          const bufferPtr = 3824;
          const countPtr = 3856;
          const flagsPtr = 3872;

          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 3, Endian.little);
          expect(sockRecv.ref([14, iovPtr, 1, 0, countPtr, flagsPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 3);
          expect(data.getUint16(flagsPtr, Endian.little), 0);
          expect(utf8.decode(bytes.sublist(bufferPtr, bufferPtr + 3)), 'abc');
          expect(utf8.decode(socket.remainingReceiveData), 'def');
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'sock_recv reports truncation for datagram sockets',
        () async {
          final socket = WASIPreview1Socket.datagram(
            receiveMessages: [utf8.encode('abcdef'), utf8.encode('xy')],
          );
          final socketWasi = WASI(sockets: {15: socket});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockRecv = preview1['sock_recv'] as FunctionImportExportValue;
          final fdFdstatGet =
              preview1['fd_fdstat_get'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const fdstatPtr = 3888;
          const iovPtr = 3920;
          const bufferPtr = 3952;
          const countPtr = 3984;
          const flagsPtr = 4000;

          expect(fdFdstatGet.ref([15, fdstatPtr]), 0);
          expect(bytes[fdstatPtr], _filetypeSocketDgram);
          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 3, Endian.little);
          expect(sockRecv.ref([15, iovPtr, 1, 0, countPtr, flagsPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 3);
          expect(
            data.getUint16(flagsPtr, Endian.little),
            _roflagRecvDataTruncated,
          );
          expect(utf8.decode(bytes.sublist(bufferPtr, bufferPtr + 3)), 'abc');

          data.setUint32(iovPtr + 4, 4, Endian.little);
          expect(sockRecv.ref([15, iovPtr, 1, 0, countPtr, flagsPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 2);
          expect(data.getUint16(flagsPtr, Endian.little), 0);
          expect(utf8.decode(bytes.sublist(bufferPtr, bufferPtr + 2)), 'xy');
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'sock_recv peek preserves datagram messages and sock_send records datagrams',
        () async {
          final socket = WASIPreview1Socket.datagram(
            receiveMessages: [utf8.encode('packet')],
          );
          final socketWasi = WASI(sockets: {16: socket});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockRecv = preview1['sock_recv'] as FunctionImportExportValue;
          final sockSend = preview1['sock_send'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const iovPtr = 4016;
          const firstBufferPtr = 4048;
          const secondBufferPtr = 4080;
          const countPtr = 4112;
          const flagsPtr = 4128;

          data.setUint32(iovPtr, firstBufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 4, Endian.little);
          expect(sockRecv.ref([16, iovPtr, 1, 1, countPtr, flagsPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 4);
          expect(
            data.getUint16(flagsPtr, Endian.little),
            _roflagRecvDataTruncated,
          );
          expect(utf8.decode(socket.remainingReceiveMessages.single), 'packet');

          data.setUint32(iovPtr + 4, 6, Endian.little);
          expect(sockRecv.ref([16, iovPtr, 1, 0, countPtr, flagsPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 6);
          expect(data.getUint16(flagsPtr, Endian.little), 0);
          expect(
            utf8.decode(bytes.sublist(firstBufferPtr, firstBufferPtr + 6)),
            'packet',
          );
          expect(socket.remainingReceiveMessages, isEmpty);

          bytes.setAll(firstBufferPtr, utf8.encode('da'));
          bytes.setAll(secondBufferPtr, utf8.encode('ta'));
          data.setUint32(iovPtr, firstBufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 2, Endian.little);
          data.setUint32(iovPtr + 8, secondBufferPtr, Endian.little);
          data.setUint32(iovPtr + 12, 2, Endian.little);
          expect(sockSend.ref([16, iovPtr, 2, 0, countPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 4);
          expect(socket.sentMessages, hasLength(1));
          expect(utf8.decode(socket.sentMessages.single), 'data');
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'sock_recv and sock_send use host-backed datagram handlers',
        () async {
          final receiveMessages = [utf8.encode('packet')];
          final sentMessages = <Uint8List>[];
          final socket = WASIPreview1Socket.datagram(
            receiveMessageProvider: () =>
                receiveMessages.isEmpty ? null : receiveMessages.removeAt(0),
            sendMessageHandler: (message) {
              sentMessages.add(Uint8List.fromList(message));
              return message.length;
            },
          );
          final socketWasi = WASI(sockets: {17: socket});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockRecv = preview1['sock_recv'] as FunctionImportExportValue;
          final sockSend = preview1['sock_send'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const iovPtr = 4176;
          const firstBufferPtr = 4208;
          const secondBufferPtr = 4240;
          const countPtr = 4288;
          const flagsPtr = 4304;

          data.setUint32(iovPtr, firstBufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 4, Endian.little);
          expect(sockRecv.ref([17, iovPtr, 1, 1, countPtr, flagsPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 4);
          expect(
            data.getUint16(flagsPtr, Endian.little),
            _roflagRecvDataTruncated,
          );
          expect(utf8.decode(socket.remainingReceiveMessages.single), 'packet');

          data.setUint32(iovPtr + 4, 6, Endian.little);
          expect(sockRecv.ref([17, iovPtr, 1, 0, countPtr, flagsPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 6);
          expect(data.getUint16(flagsPtr, Endian.little), 0);
          expect(
            utf8.decode(bytes.sublist(firstBufferPtr, firstBufferPtr + 6)),
            'packet',
          );
          expect(socket.remainingReceiveMessages, isEmpty);

          bytes.setAll(firstBufferPtr, utf8.encode('da'));
          bytes.setAll(secondBufferPtr, utf8.encode('ta'));
          data.setUint32(iovPtr, firstBufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 2, Endian.little);
          data.setUint32(iovPtr + 8, secondBufferPtr, Endian.little);
          data.setUint32(iovPtr + 12, 2, Endian.little);
          expect(sockSend.ref([17, iovPtr, 2, 0, countPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 4);
          expect(sentMessages, hasLength(1));
          expect(utf8.decode(sentMessages.single), 'data');
          expect(socket.sentMessages, isEmpty);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'sock_send rejects partial host-backed datagram writes',
        () async {
          final socket = WASIPreview1Socket.datagram(
            sendMessageHandler: (message) => message.length - 1,
          );
          final socketWasi = WASI(sockets: {17: socket});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockSend = preview1['sock_send'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const iovPtr = 4312;
          const bufferPtr = 4344;
          const countPtr = 4376;

          bytes.setAll(bufferPtr, utf8.encode('data'));
          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 4, Endian.little);
          data.setUint32(countPtr, 0xfeedface, Endian.little);

          expect(sockSend.ref([17, iovPtr, 1, 0, countPtr]), _errnoInval);
          expect(data.getUint32(countPtr, Endian.little), 0xfeedface);
          expect(socket.sentMessages, isEmpty);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_renumber and fd_close preserve preview1 socket descriptor state',
        () async {
          final source = WASIPreview1Socket(receiveData: utf8.encode('data'));
          final target = WASIPreview1Socket(receiveData: utf8.encode('old'));
          final socketWasi = WASI(sockets: {40: source, 41: target});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final fdRenumber =
              preview1['fd_renumber'] as FunctionImportExportValue;
          final fdClose = preview1['fd_close'] as FunctionImportExportValue;
          final fdFdstatGet =
              preview1['fd_fdstat_get'] as FunctionImportExportValue;
          final sockRecv = preview1['sock_recv'] as FunctionImportExportValue;
          final sockSend = preview1['sock_send'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const fdstatPtr = 3488;
          const iovPtr = 3520;
          const bufferPtr = 3552;
          const countPtr = 3584;
          const flagsPtr = 3600;

          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 4, Endian.little);
          expect(fdRenumber.ref([40, 41]), 0);
          expect(fdFdstatGet.ref([40, fdstatPtr]), 8);
          expect(fdFdstatGet.ref([41, fdstatPtr]), 0);
          expect(bytes[fdstatPtr], _filetypeSocketStream);
          expect(sockRecv.ref([41, iovPtr, 1, 0, countPtr, flagsPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 4);
          expect(utf8.decode(bytes.sublist(bufferPtr, bufferPtr + 4)), 'data');

          bytes.setAll(bufferPtr, utf8.encode('pong'));
          expect(sockSend.ref([41, iovPtr, 1, 0, countPtr]), 0);
          expect(utf8.decode(source.sentData), 'pong');
          expect(utf8.decode(target.remainingReceiveData), 'old');

          expect(fdClose.ref([41]), 0);
          expect(sockRecv.ref([41, iovPtr, 1, 0, countPtr, flagsPtr]), 8);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'sock_shutdown and descriptor rights are enforced for preview1 sockets',
        () async {
          final socket = WASIPreview1Socket(receiveData: utf8.encode('in'));
          final socketWasi = WASI(sockets: {30: socket});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockRecv = preview1['sock_recv'] as FunctionImportExportValue;
          final sockSend = preview1['sock_send'] as FunctionImportExportValue;
          final sockShutdown =
              preview1['sock_shutdown'] as FunctionImportExportValue;
          final fdFdstatSetRights =
              preview1['fd_fdstat_set_rights'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const iovPtr = 3264;
          const bufferPtr = 3296;
          const countPtr = 3328;
          const flagsPtr = 3344;

          bytes.setAll(bufferPtr, utf8.encode('out'));
          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 3, Endian.little);

          expect(
            fdFdstatSetRights.ref([30, _rightFdRead | _rightSockShutdown, 0]),
            0,
          );
          expect(sockSend.ref([30, iovPtr, 1, 0, countPtr]), 76);
          expect(sockRecv.ref([30, iovPtr, 1, 0, countPtr, flagsPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 2);
          expect(sockShutdown.ref([30, 3]), 0);
          expect(sockRecv.ref([30, iovPtr, 1, 0, countPtr, flagsPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 0);
          expect(sockShutdown.ref([30, 8]), 28);
          expect(sockShutdown.ref([1, 1]), _errnoNotsock);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'sock_shutdown validates how before descriptor state',
        () async {
          final socket = WASIPreview1Socket(receiveData: utf8.encode('in'));
          final socketWasi = WASI(sockets: {48: socket});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockRecv = preview1['sock_recv'] as FunctionImportExportValue;
          final sockSend = preview1['sock_send'] as FunctionImportExportValue;
          final sockShutdown =
              preview1['sock_shutdown'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const iovPtr = 3344;
          const recvBufferPtr = 3376;
          const sendBufferPtr = 3408;
          const countPtr = 3440;
          const flagsPtr = 3456;

          bytes.setAll(sendBufferPtr, utf8.encode('out'));
          data.setUint32(iovPtr, sendBufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 3, Endian.little);

          expect(sockShutdown.ref([999, 8]), _errnoInval);
          expect(sockShutdown.ref([1, 8]), _errnoInval);
          expect(sockShutdown.ref([48, 0]), _errnoInval);
          expect(sockShutdown.ref([48, 8]), _errnoInval);

          expect(sockSend.ref([48, iovPtr, 1, 0, countPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 3);
          expect(utf8.decode(socket.sentData), 'out');

          data.setUint32(iovPtr, recvBufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 2, Endian.little);
          expect(sockRecv.ref([48, iovPtr, 1, 0, countPtr, flagsPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 2);
          expect(
            utf8.decode(bytes.sublist(recvBufferPtr, recvBufferPtr + 2)),
            'in',
          );
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'sock_send validates iovs before socket send error states',
        () async {
          final stream = WASIPreview1Socket();
          final datagram = WASIPreview1Socket.datagram();
          final blocked = WASIPreview1Socket(writeReady: false);
          stream.shutdown(receive: false, send: true);
          datagram.shutdown(receive: false, send: true);
          final socketWasi = WASI(
            sockets: {31: stream, 32: datagram, 33: blocked},
          );
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockSend = preview1['sock_send'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const iovPtr = 3696;
          const bufferPtr = 3728;
          const countPtr = 3760;
          final invalidBufferPtr = bytes.length - 2;

          data.setUint32(iovPtr, invalidBufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 4, Endian.little);
          data.setUint32(countPtr, 0xfeedface, Endian.little);
          expect(sockSend.ref([31, iovPtr, 1, 0, countPtr]), _errnoInval);
          expect(data.getUint32(countPtr, Endian.little), 0xfeedface);
          expect(stream.sentData, isEmpty);

          data.setUint32(countPtr, 0xfeedface, Endian.little);
          expect(sockSend.ref([32, iovPtr, 1, 0, countPtr]), _errnoInval);
          expect(data.getUint32(countPtr, Endian.little), 0xfeedface);
          expect(datagram.sentMessages, isEmpty);

          data.setUint32(countPtr, 0xfeedface, Endian.little);
          expect(sockSend.ref([33, iovPtr, 1, 0, countPtr]), _errnoInval);
          expect(data.getUint32(countPtr, Endian.little), 0xfeedface);
          expect(blocked.sentData, isEmpty);

          bytes.setAll(bufferPtr, utf8.encode('out'));
          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 3, Endian.little);
          expect(sockSend.ref([31, iovPtr, 1, 0, countPtr]), _errnoPipe);
          expect(sockSend.ref([32, iovPtr, 1, 0, countPtr]), _errnoPipe);
          expect(sockSend.ref([33, iovPtr, 1, 0, countPtr]), _errnoAgain);
          expect(stream.sentData, isEmpty);
          expect(datagram.sentMessages, isEmpty);
          expect(blocked.sentData, isEmpty);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'sock_send and fd_write treat zero-byte stream writes as no-ops',
        () async {
          final sockSendSocket = WASIPreview1Socket(writeReady: false);
          final fdWriteSocket = WASIPreview1Socket(writeReady: false);
          final shutdownSocket = WASIPreview1Socket();
          shutdownSocket.shutdown(receive: false, send: true);
          final socketWasi = WASI(
            sockets: {
              34: sockSendSocket,
              39: fdWriteSocket,
              40: shutdownSocket,
            },
          );
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockSend = preview1['sock_send'] as FunctionImportExportValue;
          final fdWrite = preview1['fd_write'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final data = ByteData.view(memory.buffer);
          const iovPtr = 3712;
          const bufferPtr = 3744;
          const sockSendCountPtr = 3776;
          const fdWriteCountPtr = 3792;

          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 0, Endian.little);
          data.setUint32(sockSendCountPtr, 0xfeedface, Endian.little);
          expect(sockSend.ref([34, iovPtr, 1, 0, sockSendCountPtr]), 0);
          expect(data.getUint32(sockSendCountPtr, Endian.little), 0);
          expect(sockSendSocket.sentData, isEmpty);

          data.setUint32(fdWriteCountPtr, 0xdeadbeef, Endian.little);
          expect(fdWrite.ref([39, iovPtr, 1, fdWriteCountPtr]), 0);
          expect(data.getUint32(fdWriteCountPtr, Endian.little), 0);
          expect(fdWriteSocket.sentData, isEmpty);

          data.setUint32(sockSendCountPtr, 0xfeedface, Endian.little);
          expect(
            sockSend.ref([40, iovPtr, 1, 0, sockSendCountPtr]),
            _errnoPipe,
          );
          expect(data.getUint32(sockSendCountPtr, Endian.little), 0xfeedface);
          expect(shutdownSocket.sentData, isEmpty);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'sock_send reports pipe after write-side shutdown',
        () async {
          final socket = WASIPreview1Socket();
          final socketWasi = WASI(sockets: {31: socket});
          final socketResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            socketWasi.imports,
          );
          final socketInstance = socketResult.instance;
          final preview1 = socketWasi.imports['wasi_snapshot_preview1']!;
          final sockSend = preview1['sock_send'] as FunctionImportExportValue;
          final sockShutdown =
              preview1['sock_shutdown'] as FunctionImportExportValue;
          final memory =
              (socketInstance.exports['memory'] as MemoryImportExportValue).ref;
          socketWasi.finalizeBindings(socketInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const iovPtr = 3616;
          const bufferPtr = 3648;
          const countPtr = 3680;

          bytes.setAll(bufferPtr, utf8.encode('out'));
          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 3, Endian.little);
          expect(sockSend.ref([31, iovPtr, 1, 1, countPtr]), 28);
          expect(sockShutdown.ref([31, 2]), 0);
          expect(sockSend.ref([31, iovPtr, 1, 0, countPtr]), _errnoPipe);
          expect(socket.sentData, isEmpty);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; socket behavior is delegated to node:wasi.',
        ),
      );

      test(
        'path_open opens virtual file and fd_seek updates file offset',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/doom1.wad': Uint8List.fromList([1, 2, 3, 4]),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final fdSeek = preview1['fd_seek'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          final relativePath = utf8.encode('doom1.wad');
          const pathPtr = 2000;
          const openedFdPtr = 2020;
          const newOffsetPtr = 2032;

          bytes.setAll(pathPtr, relativePath);
          expect(
            pathOpen.ref([
              3,
              0,
              pathPtr,
              relativePath.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final openedFd = data.getUint32(openedFdPtr, Endian.little);
          expect(openedFd, greaterThanOrEqualTo(64));

          expect(fdSeek.ref([openedFd, 2, 0, newOffsetPtr]), 0);
          expect(data.getUint32(newOffsetPtr, Endian.little), 2);
          expect(data.getUint32(newOffsetPtr + 4, Endian.little), 0);
          expect(fdSeek.ref([1, 0, 0, newOffsetPtr]), 8);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; path_open/fd_seek behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_pread, fd_pwrite, and fd_write update virtual files',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/data.txt': Uint8List.fromList(utf8.encode('abcdef')),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final fdPread = preview1['fd_pread'] as FunctionImportExportValue;
          final fdPwrite = preview1['fd_pwrite'] as FunctionImportExportValue;
          final fdWrite = preview1['fd_write'] as FunctionImportExportValue;
          final fdSeek = preview1['fd_seek'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          final relativePath = utf8.encode('data.txt');
          const pathPtr = 2240;
          const openedFdPtr = 2260;
          const writeIovPtr = 2272;
          const writeBufferPtr = 2304;
          const writeCountPtr = 2336;
          const readIovPtr = 2352;
          const readBufferPtr = 2384;
          const readCountPtr = 2416;
          const offsetPtr = 2432;

          bytes.setAll(pathPtr, relativePath);
          expect(
            pathOpen.ref([
              3,
              0,
              pathPtr,
              relativePath.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final fd = data.getUint32(openedFdPtr, Endian.little);

          bytes.setAll(writeBufferPtr, utf8.encode('XY'));
          data.setUint32(writeIovPtr, writeBufferPtr, Endian.little);
          data.setUint32(writeIovPtr + 4, 2, Endian.little);
          expect(fdPwrite.ref([fd, writeIovPtr, 1, 2, writeCountPtr]), 0);
          expect(data.getUint32(writeCountPtr, Endian.little), 2);

          data.setUint32(readIovPtr, readBufferPtr, Endian.little);
          data.setUint32(readIovPtr + 4, 6, Endian.little);
          expect(fdPread.ref([fd, readIovPtr, 1, 0, readCountPtr]), 0);
          expect(data.getUint32(readCountPtr, Endian.little), 6);
          expect(
            utf8.decode(bytes.sublist(readBufferPtr, readBufferPtr + 6)),
            'abXYef',
          );

          expect(fdSeek.ref([fd, 0, 1, offsetPtr]), 0);
          expect(_getUint64Le(data, offsetPtr), 0);

          bytes.setAll(writeBufferPtr, utf8.encode('zz'));
          expect(fdWrite.ref([fd, writeIovPtr, 1, writeCountPtr]), 0);
          expect(data.getUint32(writeCountPtr, Endian.little), 2);
          expect(fdSeek.ref([fd, 0, 1, offsetPtr]), 0);
          expect(_getUint64Le(data, offsetPtr), 2);

          expect(fdPread.ref([fd, readIovPtr, 1, 0, readCountPtr]), 0);
          expect(
            utf8.decode(bytes.sublist(readBufferPtr, readBufferPtr + 6)),
            'zzXYef',
          );
        },
        skip: _skipOnNode(
          'Skipping on Node.js; file IO behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_pread snapshots overlapping iovs before writing file bytes',
        () async {
          const iovPtr = 5248;
          const secondIovPtr = iovPtr + 8;
          const originalTargetPtr = 0x1641;
          const mutatedTargetPtr = 0x1650;
          const countPtr = 5824;
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/alias.txt': Uint8List.fromList([
                mutatedTargetPtr & 0xff,
                ...'ok!'.codeUnits,
              ]),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final fdPread = preview1['fd_pread'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          final relativePath = utf8.encode('alias.txt');
          const pathPtr = 5200;
          const openedFdPtr = 5232;

          bytes.setAll(pathPtr, relativePath);
          expect(
            pathOpen.ref([
              3,
              0,
              pathPtr,
              relativePath.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final fd = data.getUint32(openedFdPtr, Endian.little);

          bytes.setAll(originalTargetPtr, '___'.codeUnits);
          bytes.setAll(mutatedTargetPtr, 'bad'.codeUnits);
          data.setUint32(iovPtr, secondIovPtr, Endian.little);
          data.setUint32(iovPtr + 4, 1, Endian.little);
          data.setUint32(iovPtr + 8, originalTargetPtr, Endian.little);
          data.setUint32(iovPtr + 12, 3, Endian.little);

          expect(fdPread.ref([fd, iovPtr, 2, 0, countPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 4);
          expect(
            utf8.decode(
              bytes.sublist(originalTargetPtr, originalTargetPtr + 3),
            ),
            'ok!',
          );
          expect(
            utf8.decode(bytes.sublist(mutatedTargetPtr, mutatedTargetPtr + 3)),
            'bad',
          );
        },
        skip: _skipOnNode(
          'Skipping on Node.js; file IO behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_pwrite validates all iovs before mutating virtual files',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/preflight.txt': Uint8List.fromList(
                utf8.encode('abcdef'),
              ),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final fdPread = preview1['fd_pread'] as FunctionImportExportValue;
          final fdPwrite = preview1['fd_pwrite'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          final relativePath = utf8.encode('preflight.txt');
          const pathPtr = 5840;
          const openedFdPtr = 5872;
          const writeIovPtr = 5888;
          const writeBufferPtr = 5920;
          const writeCountPtr = 5952;
          const readIovPtr = 5968;
          const readBufferPtr = 6000;
          const readCountPtr = 6032;

          bytes.setAll(pathPtr, relativePath);
          expect(
            pathOpen.ref([
              3,
              0,
              pathPtr,
              relativePath.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final fd = data.getUint32(openedFdPtr, Endian.little);

          bytes.setAll(writeBufferPtr, utf8.encode('XY'));
          data.setUint32(writeIovPtr, writeBufferPtr, Endian.little);
          data.setUint32(writeIovPtr + 4, 2, Endian.little);
          data.setUint32(writeIovPtr + 8, bytes.length - 2, Endian.little);
          data.setUint32(writeIovPtr + 12, 8, Endian.little);
          data.setUint32(writeCountPtr, 0xfeedface, Endian.little);
          expect(
            fdPwrite.ref([fd, writeIovPtr, 2, 0, writeCountPtr]),
            _errnoInval,
          );
          expect(data.getUint32(writeCountPtr, Endian.little), 0xfeedface);

          data.setUint32(readIovPtr, readBufferPtr, Endian.little);
          data.setUint32(readIovPtr + 4, 6, Endian.little);
          expect(fdPread.ref([fd, readIovPtr, 1, 0, readCountPtr]), 0);
          expect(data.getUint32(readCountPtr, Endian.little), 6);
          expect(
            utf8.decode(bytes.sublist(readBufferPtr, readBufferPtr + 6)),
            'abcdef',
          );
        },
        skip: _skipOnNode(
          'Skipping on Node.js; file IO behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd read and write counts can target memory zero',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/data.txt': Uint8List.fromList(utf8.encode('abcdef')),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final fdRead = preview1['fd_read'] as FunctionImportExportValue;
          final fdPread = preview1['fd_pread'] as FunctionImportExportValue;
          final fdPwrite = preview1['fd_pwrite'] as FunctionImportExportValue;
          final fdWrite = preview1['fd_write'] as FunctionImportExportValue;
          final fdSeek = preview1['fd_seek'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          final relativePath = utf8.encode('data.txt');
          const countPtr = 0;
          const countSentinel = 0xdeadbeef;
          const pathPtr = 2240;
          const openedFdPtr = 2260;
          const writeIovPtr = 2272;
          const writeBufferPtr = 2304;
          const readIovPtr = 2352;
          const readBufferPtr = 2384;
          const offsetPtr = 2432;

          data.setUint32(writeIovPtr, writeBufferPtr, Endian.little);
          data.setUint32(writeIovPtr + 4, 0, Endian.little);
          data.setUint32(countPtr, countSentinel, Endian.little);
          expect(fdWrite.ref([1, writeIovPtr, 1, countPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 0);

          bytes.setAll(pathPtr, relativePath);
          expect(
            pathOpen.ref([
              3,
              0,
              pathPtr,
              relativePath.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final fd = data.getUint32(openedFdPtr, Endian.little);

          bytes.setAll(writeBufferPtr, utf8.encode('XY'));
          data.setUint32(writeIovPtr, writeBufferPtr, Endian.little);
          data.setUint32(writeIovPtr + 4, 2, Endian.little);
          data.setUint32(countPtr, countSentinel, Endian.little);
          expect(fdPwrite.ref([fd, writeIovPtr, 1, 2, countPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 2);

          data.setUint32(readIovPtr, readBufferPtr, Endian.little);
          data.setUint32(readIovPtr + 4, 6, Endian.little);
          data.setUint32(countPtr, countSentinel, Endian.little);
          expect(fdPread.ref([fd, readIovPtr, 1, 0, countPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 6);

          expect(fdSeek.ref([fd, 0, 0, offsetPtr]), 0);
          data.setUint32(readIovPtr + 4, 3, Endian.little);
          data.setUint32(countPtr, countSentinel, Endian.little);
          expect(fdRead.ref([fd, readIovPtr, 1, countPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 3);

          bytes.setAll(writeBufferPtr, utf8.encode('zz'));
          data.setUint32(countPtr, countSentinel, Endian.little);
          expect(fdWrite.ref([fd, writeIovPtr, 1, countPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 2);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; file IO behavior is delegated to node:wasi.',
        ),
      );

      test(
        'path_open creates, exclusively opens, and truncates virtual files',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/existing.txt': Uint8List.fromList(
                utf8.encode('abcdef'),
              ),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final fdPread = preview1['fd_pread'] as FunctionImportExportValue;
          final fdPwrite = preview1['fd_pwrite'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          final createdPath = utf8.encode('created.txt');
          final existingPath = utf8.encode('existing.txt');
          const pathPtr = 4512;
          const existingPathPtr = 4544;
          const openedFdPtr = 4576;
          const iovPtr = 4592;
          const bufferPtr = 4624;
          const countPtr = 4656;
          const readBufferPtr = 4672;
          const exclusiveFdSentinel = 0xdecafbad;

          bytes.setAll(pathPtr, createdPath);
          expect(
            pathOpen.ref([
              3,
              0,
              pathPtr,
              createdPath.length,
              _oflagCreat,
              _rightFdRead | _rightFdWrite | _rightFdSeek,
              0,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final createdFd = data.getUint32(openedFdPtr, Endian.little);

          bytes.setAll(bufferPtr, utf8.encode('new'));
          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 3, Endian.little);
          expect(fdPwrite.ref([createdFd, iovPtr, 1, 0, countPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 3);

          data.setUint32(iovPtr, readBufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 3, Endian.little);
          expect(fdPread.ref([createdFd, iovPtr, 1, 0, countPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 3);
          expect(
            utf8.decode(bytes.sublist(readBufferPtr, readBufferPtr + 3)),
            'new',
          );

          data.setUint32(openedFdPtr, exclusiveFdSentinel, Endian.little);
          expect(
            pathOpen.ref([
              3,
              0,
              pathPtr,
              createdPath.length,
              _oflagCreat | _oflagExcl,
              _rightFdRead,
              0,
              0,
              openedFdPtr,
            ]),
            _errnoExist,
          );
          expect(
            data.getUint32(openedFdPtr, Endian.little),
            exclusiveFdSentinel,
          );

          bytes.setAll(existingPathPtr, existingPath);
          expect(
            pathOpen.ref([
              3,
              0,
              existingPathPtr,
              existingPath.length,
              _oflagTrunc,
              _rightFdRead | _rightFdWrite | _rightFdSeek,
              0,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final truncatedFd = data.getUint32(openedFdPtr, Endian.little);
          data.setUint32(iovPtr, readBufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 6, Endian.little);
          expect(fdPread.ref([truncatedFd, iovPtr, 1, 0, countPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 0);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; file IO behavior is delegated to node:wasi.',
        ),
      );

      test(
        'path_open create and truncate require directory rights',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/existing.txt': Uint8List.fromList(
                utf8.encode('abcdef'),
              ),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final fdFdstatSetRights =
              preview1['fd_fdstat_set_rights'] as FunctionImportExportValue;
          final fdPread = preview1['fd_pread'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          final missingPath = utf8.encode('created.txt');
          final existingPath = utf8.encode('existing.txt');
          const missingPathPtr = 4720;
          const existingPathPtr = 4752;
          const openedFdPtr = 4784;
          const iovPtr = 4800;
          const readBufferPtr = 4832;
          const countPtr = 4864;
          const failedFdSentinel = 0xfeedface;

          expect(fdFdstatSetRights.ref([3, _rightPathOpen, _rightsAll]), 0);

          bytes.setAll(missingPathPtr, missingPath);
          data.setUint32(openedFdPtr, failedFdSentinel, Endian.little);
          expect(
            pathOpen.ref([
              3,
              0,
              missingPathPtr,
              missingPath.length,
              _oflagCreat,
              _rightFdRead | _rightFdWrite,
              0,
              0,
              openedFdPtr,
            ]),
            _errnoNotcapable,
          );
          expect(data.getUint32(openedFdPtr, Endian.little), failedFdSentinel);

          bytes.setAll(existingPathPtr, existingPath);
          expect(
            pathOpen.ref([
              3,
              0,
              existingPathPtr,
              existingPath.length,
              _oflagTrunc,
              _rightFdRead | _rightFdWrite,
              0,
              0,
              openedFdPtr,
            ]),
            _errnoNotcapable,
          );

          expect(
            pathOpen.ref([
              3,
              0,
              existingPathPtr,
              existingPath.length,
              0,
              _rightFdRead | _rightFdSeek,
              0,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final fd = data.getUint32(openedFdPtr, Endian.little);
          data.setUint32(iovPtr, readBufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 6, Endian.little);
          expect(fdPread.ref([fd, iovPtr, 1, 0, countPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 6);
          expect(
            utf8.decode(bytes.sublist(readBufferPtr, readBufferPtr + 6)),
            'abcdef',
          );
        },
        skip: _skipOnNode(
          'Skipping on Node.js; path_open behavior is delegated to node:wasi.',
        ),
      );

      test(
        'path_open rejects file descriptors as directory bases',
        () async {
          final fileWasi = WASI(preopens: {'/sandbox': '/tmp'});
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          final baseFilePath = utf8.encode('base_file.txt');
          final childPath = utf8.encode('child.txt');
          const pathPtr = 4864;
          const childPathPtr = 4896;
          const openedFdPtr = 4928;
          const failedFdSentinel = 0xdecafbad;

          bytes.setAll(pathPtr, baseFilePath);
          expect(
            pathOpen.ref([
              3,
              0,
              pathPtr,
              baseFilePath.length,
              _oflagCreat,
              0,
              0,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final fileFd = data.getUint32(openedFdPtr, Endian.little);

          bytes.setAll(childPathPtr, childPath);
          data.setUint32(openedFdPtr, failedFdSentinel, Endian.little);
          expect(
            pathOpen.ref([
              fileFd,
              0,
              childPathPtr,
              childPath.length,
              _oflagCreat,
              0,
              0,
              0,
              openedFdPtr,
            ]),
            _errnoNotdir,
          );
          expect(data.getUint32(openedFdPtr, Endian.little), failedFdSentinel);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; path_open behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_renumber moves virtual descriptors and requires an open target',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/source.txt': Uint8List.fromList(utf8.encode('abcd')),
              '/sandbox/target.txt': Uint8List.fromList(utf8.encode('WXYZ')),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final fdRenumber =
              preview1['fd_renumber'] as FunctionImportExportValue;
          final fdPread = preview1['fd_pread'] as FunctionImportExportValue;
          final fdSeek = preview1['fd_seek'] as FunctionImportExportValue;
          final fdTell = preview1['fd_tell'] as FunctionImportExportValue;
          final fdClose = preview1['fd_close'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          final sourcePath = utf8.encode('source.txt');
          final targetPath = utf8.encode('target.txt');
          const sourcePathPtr = 2448;
          const targetPathPtr = 2480;
          const sourceFdPtr = 2512;
          const targetFdPtr = 2528;
          const offsetPtr = 2544;
          const iovPtr = 2576;
          const readBufferPtr = 2608;
          const readCountPtr = 2640;

          bytes.setAll(sourcePathPtr, sourcePath);
          bytes.setAll(targetPathPtr, targetPath);
          expect(
            pathOpen.ref([
              3,
              0,
              sourcePathPtr,
              sourcePath.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              sourceFdPtr,
            ]),
            0,
          );
          expect(
            pathOpen.ref([
              3,
              0,
              targetPathPtr,
              targetPath.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              targetFdPtr,
            ]),
            0,
          );
          final sourceFd = data.getUint32(sourceFdPtr, Endian.little);
          final targetFd = data.getUint32(targetFdPtr, Endian.little);
          expect(sourceFd, isNot(targetFd));

          expect(fdSeek.ref([sourceFd, 2, 0, offsetPtr]), 0);
          expect(fdRenumber.ref([sourceFd, targetFd]), 0);
          expect(fdTell.ref([sourceFd, offsetPtr]), 8);
          expect(fdTell.ref([targetFd, offsetPtr]), 0);
          expect(_getUint64Le(data, offsetPtr), 2);

          data.setUint32(iovPtr, readBufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 4, Endian.little);
          expect(fdPread.ref([targetFd, iovPtr, 1, 0, readCountPtr]), 0);
          expect(data.getUint32(readCountPtr, Endian.little), 4);
          expect(
            utf8.decode(bytes.sublist(readBufferPtr, readBufferPtr + 4)),
            'abcd',
          );
          expect(fdRenumber.ref([targetFd, targetFd]), 0);
          expect(fdTell.ref([targetFd, offsetPtr]), 0);
          expect(_getUint64Le(data, offsetPtr), 2);

          expect(
            pathOpen.ref([
              3,
              0,
              targetPathPtr,
              targetPath.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              sourceFdPtr,
            ]),
            0,
          );
          final reopenedFd = data.getUint32(sourceFdPtr, Endian.little);
          expect(fdClose.ref([targetFd]), 0);
          expect(fdRenumber.ref([reopenedFd, targetFd]), _errnoBadf);
          expect(fdTell.ref([targetFd, offsetPtr]), _errnoBadf);
          expect(fdTell.ref([reopenedFd, offsetPtr]), 0);
          expect(_getUint64Le(data, offsetPtr), 0);
          bytes.fillRange(readBufferPtr, readBufferPtr + 4, 0);
          expect(fdPread.ref([reopenedFd, iovPtr, 1, 0, readCountPtr]), 0);
          expect(data.getUint32(readCountPtr, Endian.little), 4);
          expect(
            utf8.decode(bytes.sublist(readBufferPtr, readBufferPtr + 4)),
            'WXYZ',
          );
        },
        skip: _skipOnNode(
          'Skipping on Node.js; fd_renumber behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_fdstat_set_rights persists and enforces descriptor rights',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/data.txt': Uint8List.fromList(utf8.encode('abcdef')),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final fdFdstatGet =
              preview1['fd_fdstat_get'] as FunctionImportExportValue;
          final fdFdstatSetRights =
              preview1['fd_fdstat_set_rights'] as FunctionImportExportValue;
          final fdPread = preview1['fd_pread'] as FunctionImportExportValue;
          final fdPwrite = preview1['fd_pwrite'] as FunctionImportExportValue;
          final fdWrite = preview1['fd_write'] as FunctionImportExportValue;
          final pathFilestatGet =
              preview1['path_filestat_get'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          final path = utf8.encode('data.txt');
          const pathPtr = 2672;
          const fdPtr = 2704;
          const fdstatPtr = 2720;
          const iovPtr = 2752;
          const bufferPtr = 2784;
          const countPtr = 2816;
          const filestatPtr = 2832;
          const zeroFdPtr = 2912;

          bytes.setAll(pathPtr, path);
          expect(
            pathOpen.ref([
              3,
              0,
              pathPtr,
              path.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              fdPtr,
            ]),
            0,
          );
          final fd = data.getUint32(fdPtr, Endian.little);

          expect(
            pathOpen.ref([3, 0, pathPtr, path.length, 0, 0, 0, 0, zeroFdPtr]),
            0,
          );
          final zeroFd = data.getUint32(zeroFdPtr, Endian.little);
          expect(fdFdstatGet.ref([zeroFd, fdstatPtr]), 0);
          expect(_getUint64Le(data, fdstatPtr + 8), 0);
          expect(_getUint64Le(data, fdstatPtr + 16), 0);
          expect(fdPread.ref([zeroFd, iovPtr, 1, 0, countPtr]), 76);

          expect(fdFdstatGet.ref([fd, fdstatPtr]), 0);
          expect(
            fdFdstatSetRights.ref([
              fd,
              _rightFdRead | _rightFdSeek | _rightFdFdstatGet,
              0,
            ]),
            0,
          );
          expect(fdFdstatGet.ref([fd, fdstatPtr]), 0);
          expect(
            _getUint64Le(data, fdstatPtr + 8),
            _rightFdRead | _rightFdSeek | _rightFdFdstatGet,
          );
          expect(_getUint64Le(data, fdstatPtr + 16), 0);

          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 3, Endian.little);
          expect(fdPread.ref([fd, iovPtr, 1, 0, countPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 3);
          expect(fdPwrite.ref([fd, iovPtr, 1, 0, countPtr]), 76);
          expect(fdFdstatSetRights.ref([fd, _rightFdWrite, 0]), 76);

          expect(fdFdstatSetRights.ref([1, 0, 0]), 0);
          expect(fdWrite.ref([1, iovPtr, 1, countPtr]), 76);

          expect(
            fdFdstatSetRights.ref([3, _rightFdFdstatGet, _rightFdRead]),
            0,
          );
          expect(
            pathFilestatGet.ref([3, 0, pathPtr, path.length, filestatPtr]),
            76,
          );
        },
        skip: _skipOnNode(
          'Skipping on Node.js; descriptor rights behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_tell, fd_filestat_set_size, and fd_allocate update file size',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/data.bin': Uint8List.fromList(utf8.encode('abcdef')),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final fdSeek = preview1['fd_seek'] as FunctionImportExportValue;
          final fdTell = preview1['fd_tell'] as FunctionImportExportValue;
          final fdFilestatGet =
              preview1['fd_filestat_get'] as FunctionImportExportValue;
          final fdFilestatSetSize =
              preview1['fd_filestat_set_size'] as FunctionImportExportValue;
          final fdAllocate =
              preview1['fd_allocate'] as FunctionImportExportValue;
          final fdPread = preview1['fd_pread'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          final relativePath = utf8.encode('data.bin');
          const pathPtr = 2448;
          const openedFdPtr = 2480;
          const offsetPtr = 2496;
          const filestatPtr = 2528;
          const iovPtr = 2600;
          const readBufferPtr = 2624;
          const readCountPtr = 2656;

          bytes.setAll(pathPtr, relativePath);
          expect(
            pathOpen.ref([
              3,
              0,
              pathPtr,
              relativePath.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final fd = data.getUint32(openedFdPtr, Endian.little);

          expect(fdSeek.ref([fd, 4, 0, offsetPtr]), 0);
          expect(fdTell.ref([fd, offsetPtr]), 0);
          expect(_getUint64Le(data, offsetPtr), 4);

          expect(fdFilestatGet.ref([fd, filestatPtr]), 0);
          expect(_getUint64Le(data, filestatPtr + 32), 6);

          expect(fdFilestatSetSize.ref([fd, 3]), 0);
          expect(fdFilestatGet.ref([fd, filestatPtr]), 0);
          expect(_getUint64Le(data, filestatPtr + 32), 3);

          data.setUint32(iovPtr, readBufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 6, Endian.little);
          expect(fdPread.ref([fd, iovPtr, 1, 0, readCountPtr]), 0);
          expect(data.getUint32(readCountPtr, Endian.little), 3);
          expect(
            utf8.decode(bytes.sublist(readBufferPtr, readBufferPtr + 3)),
            'abc',
          );

          bytes.fillRange(readBufferPtr, readBufferPtr + 12, 0xff);
          expect(fdAllocate.ref([fd, 8, 4]), 0);
          expect(fdFilestatGet.ref([fd, filestatPtr]), 0);
          expect(_getUint64Le(data, filestatPtr + 32), 12);
          expect(fdTell.ref([fd, offsetPtr]), 0);
          expect(_getUint64Le(data, offsetPtr), 4);

          data.setUint32(iovPtr, readBufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 12, Endian.little);
          expect(fdPread.ref([fd, iovPtr, 1, 0, readCountPtr]), 0);
          expect(data.getUint32(readCountPtr, Endian.little), 12);
          expect(bytes.sublist(readBufferPtr, readBufferPtr + 3), [97, 98, 99]);
          expect(
            bytes.sublist(readBufferPtr + 3, readBufferPtr + 12),
            List<int>.filled(9, 0),
          );
        },
        skip: _skipOnNode(
          'Skipping on Node.js; file size behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_advise, fd_datasync, and fd_sync validate virtual descriptors',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/data.bin': Uint8List.fromList(utf8.encode('abcdef')),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final fdAdvise = preview1['fd_advise'] as FunctionImportExportValue;
          final fdDatasync =
              preview1['fd_datasync'] as FunctionImportExportValue;
          final fdSync = preview1['fd_sync'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          final relativePath = utf8.encode('data.bin');
          const pathPtr = 2816;
          const openedFdPtr = 2848;

          bytes.setAll(pathPtr, relativePath);
          expect(
            pathOpen.ref([
              3,
              0,
              pathPtr,
              relativePath.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final fd = data.getUint32(openedFdPtr, Endian.little);

          expect(fdAdvise.ref([fd, 0, 6, 0]), 0);
          expect(fdDatasync.ref([fd]), 0);
          expect(fdSync.ref([fd]), 0);
          expect(fdAdvise.ref([fd, 0, 6, 99]), 28);
          expect(fdAdvise.ref([999, 0, 6, 0]), 8);
          expect(fdDatasync.ref([999]), 8);
          expect(fdSync.ref([999]), 8);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; descriptor sync behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_fdstat_set_flags persists descriptor flags and append mode',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/data.txt': Uint8List.fromList(utf8.encode('abcdef')),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final fdFdstatGet =
              preview1['fd_fdstat_get'] as FunctionImportExportValue;
          final fdFdstatSetFlags =
              preview1['fd_fdstat_set_flags'] as FunctionImportExportValue;
          final fdSeek = preview1['fd_seek'] as FunctionImportExportValue;
          final fdWrite = preview1['fd_write'] as FunctionImportExportValue;
          final fdPread = preview1['fd_pread'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          final relativePath = utf8.encode('data.txt');
          const pathPtr = 3072;
          const openedFdPtr = 3104;
          const fdstatPtr = 3120;
          const offsetPtr = 3160;
          const iovPtr = 3184;
          const bufferPtr = 3216;
          const countPtr = 3248;
          const readBufferPtr = 3264;

          bytes.setAll(pathPtr, relativePath);
          expect(
            pathOpen.ref([
              3,
              0,
              pathPtr,
              relativePath.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final fd = data.getUint32(openedFdPtr, Endian.little);

          expect(fdFdstatSetFlags.ref([fd, 1]), 0);
          expect(fdFdstatGet.ref([fd, fdstatPtr]), 0);
          expect(data.getUint16(fdstatPtr + 2, Endian.little), 1);

          expect(fdSeek.ref([fd, 0, 0, offsetPtr]), 0);
          bytes.setAll(bufferPtr, utf8.encode('XY'));
          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 2, Endian.little);
          expect(fdWrite.ref([fd, iovPtr, 1, countPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 2);

          data.setUint32(iovPtr, readBufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 8, Endian.little);
          expect(fdPread.ref([fd, iovPtr, 1, 0, countPtr]), 0);
          expect(data.getUint32(countPtr, Endian.little), 8);
          expect(
            utf8.decode(bytes.sublist(readBufferPtr, readBufferPtr + 8)),
            'abcdefXY',
          );

          expect(fdFdstatSetFlags.ref([fd, 0x20]), 28);
          expect(fdFdstatSetFlags.ref([999, 1]), 8);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; descriptor flag behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_filestat_set_times and path_filestat_set_times persist virtual timestamps',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/data.bin': Uint8List.fromList(utf8.encode('abcdef')),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final fdFilestatGet =
              preview1['fd_filestat_get'] as FunctionImportExportValue;
          final fdFilestatSetTimes =
              preview1['fd_filestat_set_times'] as FunctionImportExportValue;
          final pathFilestatGet =
              preview1['path_filestat_get'] as FunctionImportExportValue;
          final pathFilestatSetTimes =
              preview1['path_filestat_set_times'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          final filePath = utf8.encode('data.bin');
          final dirPath = utf8.encode('.');
          const pathPtr = 2864;
          const dirPathPtr = 2880;
          const openedFdPtr = 2896;
          const filestatPtr = 2928;
          const atime = 123456789;
          const mtime = 987654321;
          const updatedAtime = 222222222;
          const updatedMtime = 333333333;

          bytes.setAll(pathPtr, filePath);
          bytes.setAll(dirPathPtr, dirPath);
          expect(
            pathOpen.ref([
              3,
              0,
              pathPtr,
              filePath.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final fd = data.getUint32(openedFdPtr, Endian.little);

          expect(fdFilestatSetTimes.ref([fd, atime, mtime, 1 | 4]), 0);
          expect(fdFilestatGet.ref([fd, filestatPtr]), 0);
          expect(_getUint64Le(data, filestatPtr + 40), atime);
          expect(_getUint64Le(data, filestatPtr + 48), mtime);

          expect(
            pathFilestatSetTimes.ref([
              3,
              0,
              dirPathPtr,
              dirPath.length,
              updatedAtime,
              updatedMtime,
              1 | 4,
            ]),
            0,
          );
          expect(
            pathFilestatGet.ref([
              3,
              0,
              dirPathPtr,
              dirPath.length,
              filestatPtr,
            ]),
            0,
          );
          expect(_getUint64Le(data, filestatPtr + 40), updatedAtime);
          expect(_getUint64Le(data, filestatPtr + 48), updatedMtime);

          expect(fdFilestatSetTimes.ref([fd, 1, 2, 1 | 2]), 28);
          expect(fdFilestatSetTimes.ref([999, 1, 2, 1 | 4]), 8);
          final missingPath = utf8.encode('missing.bin');
          bytes.setAll(pathPtr, missingPath);
          expect(
            pathFilestatSetTimes.ref([
              3,
              0,
              pathPtr,
              missingPath.length,
              1,
              2,
              1 | 4,
            ]),
            44,
          );
        },
        skip: _skipOnNode(
          'Skipping on Node.js; filestat time behavior is delegated to node:wasi.',
        ),
      );

      test(
        'new virtual nodes start with non-zero filestat timestamps',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/existing.txt': Uint8List.fromList([1]),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathCreateDirectory =
              preview1['path_create_directory'] as FunctionImportExportValue;
          final pathSymlink =
              preview1['path_symlink'] as FunctionImportExportValue;
          final pathFilestatGet =
              preview1['path_filestat_get'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const pathPtr = 2700;
          const targetPtr = 2760;
          const filestatPtr = 2820;

          void expectNonZeroTimes(String path) {
            final pathBytes = utf8.encode(path);
            bytes.setAll(pathPtr, pathBytes);
            expect(
              pathFilestatGet.ref([
                3,
                0,
                pathPtr,
                pathBytes.length,
                filestatPtr,
              ]),
              0,
            );
            expect(_getUint64Le(data, filestatPtr + 40), isNonZero);
            expect(_getUint64Le(data, filestatPtr + 48), isNonZero);
          }

          expectNonZeroTimes('existing.txt');

          final dirPath = utf8.encode('created-dir');
          bytes.setAll(pathPtr, dirPath);
          expect(pathCreateDirectory.ref([3, pathPtr, dirPath.length]), 0);
          expectNonZeroTimes('created-dir');

          final target = utf8.encode('existing.txt');
          final link = utf8.encode('created-link');
          bytes.setAll(targetPtr, target);
          bytes.setAll(pathPtr, link);
          expect(
            pathSymlink.ref([
              targetPtr,
              target.length,
              3,
              pathPtr,
              link.length,
            ]),
            0,
          );
          expectNonZeroTimes('created-link');
        },
        skip: _skipOnNode(
          'Skipping on Node.js; virtual filestat behavior is delegated to node:wasi.',
        ),
      );

      test(
        'path_open opens virtual directories and resolves nested files',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/assets/doom1.wad': Uint8List.fromList([7, 8, 9]),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final fdFdstatGet =
              preview1['fd_fdstat_get'] as FunctionImportExportValue;
          final fdRead = preview1['fd_read'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const pathPtr = 2048;
          const openedFdPtr = 2080;
          const fdstatPtr = 2096;
          const iovPtr = 2160;
          const bufferPtr = 2176;
          const nreadPtr = 2192;

          final dirPath = utf8.encode('assets');
          bytes.setAll(pathPtr, dirPath);
          expect(
            pathOpen.ref([
              3,
              0,
              pathPtr,
              dirPath.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final dirFd = data.getUint32(openedFdPtr, Endian.little);
          expect(fdFdstatGet.ref([dirFd, fdstatPtr]), 0);
          expect(bytes[fdstatPtr], 3);

          final nestedPath = utf8.encode('./doom1.wad');
          bytes.setAll(pathPtr, nestedPath);
          expect(
            pathOpen.ref([
              dirFd,
              0,
              pathPtr,
              nestedPath.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final fileFd = data.getUint32(openedFdPtr, Endian.little);
          data.setUint32(iovPtr, bufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 3, Endian.little);

          expect(fdRead.ref([fileFd, iovPtr, 1, nreadPtr]), 0);
          expect(data.getUint32(nreadPtr, Endian.little), 3);
          expect(bytes.sublist(bufferPtr, bufferPtr + 3), [7, 8, 9]);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; path_open/fd_read behavior is delegated to node:wasi.',
        ),
      );

      test(
        'path_open does not grant fd_seek rights to directories',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/assets/doom1.wad': Uint8List.fromList([7, 8, 9]),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final fdFdstatGet =
              preview1['fd_fdstat_get'] as FunctionImportExportValue;
          final fdSeek = preview1['fd_seek'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const pathPtr = 2192;
          const openedFdPtr = 2224;
          const fdstatPtr = 2240;
          const offsetPtr = 2272;

          final dirPath = utf8.encode('assets');
          bytes.setAll(pathPtr, dirPath);
          expect(
            pathOpen.ref([
              3,
              0,
              pathPtr,
              dirPath.length,
              _oflagDirectory,
              _rightFdSeek,
              0,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final dirFd = data.getUint32(openedFdPtr, Endian.little);

          expect(fdFdstatGet.ref([dirFd, fdstatPtr]), 0);
          expect(bytes[fdstatPtr], 3);
          expect(_getUint64Le(data, fdstatPtr + 8) & _rightFdSeek, 0);

          _setUint64Le(data, offsetPtr, 0xdecafbad);
          expect(fdSeek.ref([dirFd, 0, 1, offsetPtr]), _errnoNotcapable);
          expect(_getUint64Le(data, offsetPtr), 0xdecafbad);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; path_open/fd_seek behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_readdir reads virtual directory entries and respects cookies',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/assets/doom1.wad': Uint8List.fromList([7, 8, 9]),
              '/sandbox/assets/nested/map.wad': Uint8List.fromList([1]),
              '/sandbox/assets/readme.txt': Uint8List.fromList([2]),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final pathCreateDirectory =
              preview1['path_create_directory'] as FunctionImportExportValue;
          final fdReaddir = preview1['fd_readdir'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const pathPtr = 2800;
          const openedFdPtr = 2832;
          const direntsPtr = 2864;
          const bufusedPtr = 3040;

          final dirPath = utf8.encode('assets');
          bytes.setAll(pathPtr, dirPath);
          expect(
            pathOpen.ref([
              3,
              0,
              pathPtr,
              dirPath.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final dirFd = data.getUint32(openedFdPtr, Endian.little);

          expect(fdReaddir.ref([dirFd, direntsPtr, 160, 0, bufusedPtr]), 0);
          final bufused = data.getUint32(bufusedPtr, Endian.little);
          final entries = _readDirents(bytes, data, direntsPtr, bufused);
          expect(entries.map((entry) => entry.name), [
            '.',
            '..',
            'doom1.wad',
            'nested',
            'readme.txt',
          ]);
          expect(entries.map((entry) => entry.type), [3, 3, 4, 3, 4]);

          bytes.fillRange(direntsPtr, direntsPtr + 160, 0);
          expect(
            fdReaddir.ref([
              dirFd,
              direntsPtr,
              160,
              entries[2].next,
              bufusedPtr,
            ]),
            0,
          );
          final nextBufused = data.getUint32(bufusedPtr, Endian.little);
          final nextEntries = _readDirents(
            bytes,
            data,
            direntsPtr,
            nextBufused,
          );
          expect(nextEntries.map((entry) => entry.name), [
            'nested',
            'readme.txt',
          ]);

          final newDirPath = utf8.encode('newdir');
          bytes.setAll(pathPtr, newDirPath);
          expect(
            pathCreateDirectory.ref([dirFd, pathPtr, newDirPath.length]),
            0,
          );
          bytes.fillRange(direntsPtr, direntsPtr + 160, 0);
          expect(fdReaddir.ref([dirFd, direntsPtr, 160, 0, bufusedPtr]), 0);
          final updatedBufused = data.getUint32(bufusedPtr, Endian.little);
          final updatedEntries = _readDirents(
            bytes,
            data,
            direntsPtr,
            updatedBufused,
          );
          expect(updatedEntries.map((entry) => entry.name), contains('newdir'));
        },
        skip: _skipOnNode(
          'Skipping on Node.js; fd_readdir behavior is delegated to node:wasi.',
        ),
      );

      test(
        'filestat and readdir report stable virtual node identities',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/assets/a.txt': Uint8List.fromList([1]),
              '/sandbox/assets/b.txt': Uint8List.fromList([2]),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final pathLink = preview1['path_link'] as FunctionImportExportValue;
          final fdFilestatGet =
              preview1['fd_filestat_get'] as FunctionImportExportValue;
          final pathFilestatGet =
              preview1['path_filestat_get'] as FunctionImportExportValue;
          final fdReaddir = preview1['fd_readdir'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const pathPtr = 2700;
          const secondPathPtr = 2736;
          const openedFdPtr = 2772;
          const filestatPtr = 2808;
          const otherFilestatPtr = 2872;
          const direntsPtr = 2944;
          const bufusedPtr = 3200;

          final dirPath = utf8.encode('assets');
          bytes.setAll(pathPtr, dirPath);
          expect(
            pathOpen.ref([
              3,
              0,
              pathPtr,
              dirPath.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final dirFd = data.getUint32(openedFdPtr, Endian.little);
          expect(fdFilestatGet.ref([dirFd, filestatPtr]), 0);
          final dirDevice = _getUint64Le(data, filestatPtr);
          final dirInode = _getUint64Le(data, filestatPtr + 8);
          expect(dirDevice, isNonZero);
          expect(dirInode, isNonZero);

          final fileA = utf8.encode('assets/a.txt');
          bytes.setAll(pathPtr, fileA);
          expect(
            pathFilestatGet.ref([3, 0, pathPtr, fileA.length, filestatPtr]),
            0,
          );
          final fileADevice = _getUint64Le(data, filestatPtr);
          final fileAInode = _getUint64Le(data, filestatPtr + 8);
          expect(fileADevice, dirDevice);
          expect(fileAInode, isNonZero);

          final fileB = utf8.encode('assets/b.txt');
          bytes.setAll(pathPtr, fileB);
          expect(
            pathFilestatGet.ref([
              3,
              0,
              pathPtr,
              fileB.length,
              otherFilestatPtr,
            ]),
            0,
          );
          expect(_getUint64Le(data, otherFilestatPtr), dirDevice);
          final fileBInode = _getUint64Le(data, otherFilestatPtr + 8);
          expect(fileBInode, isNot(fileAInode));

          final hardLink = utf8.encode('assets/a-hard.txt');
          bytes.setAll(pathPtr, fileA);
          bytes.setAll(secondPathPtr, hardLink);
          expect(
            pathLink.ref([
              3,
              0,
              pathPtr,
              fileA.length,
              3,
              secondPathPtr,
              hardLink.length,
            ]),
            0,
          );
          bytes.setAll(pathPtr, hardLink);
          expect(
            pathFilestatGet.ref([
              3,
              0,
              pathPtr,
              hardLink.length,
              otherFilestatPtr,
            ]),
            0,
          );
          expect(_getUint64Le(data, otherFilestatPtr), dirDevice);
          expect(_getUint64Le(data, otherFilestatPtr + 8), fileAInode);

          expect(fdReaddir.ref([dirFd, direntsPtr, 220, 0, bufusedPtr]), 0);
          final bufused = data.getUint32(bufusedPtr, Endian.little);
          final entries = _readDirents(bytes, data, direntsPtr, bufused);
          expect(
            entries.singleWhere((entry) => entry.name == '.').inode,
            dirInode,
          );
          expect(
            entries.singleWhere((entry) => entry.name == 'a.txt').inode,
            fileAInode,
          );
          expect(
            entries.singleWhere((entry) => entry.name == 'a-hard.txt').inode,
            fileAInode,
          );
          expect(
            entries.singleWhere((entry) => entry.name == 'b.txt').inode,
            fileBInode,
          );
        },
        skip: _skipOnNode(
          'Skipping on Node.js; virtual identity behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_readdir keeps buffer full while directory entries remain',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              for (var index = 0; index < 100; index++)
                '/sandbox/many/file.$index': Uint8List(0),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final fdReaddir = preview1['fd_readdir'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const pathPtr = 2700;
          const openedFdPtr = 2736;
          const direntsPtr = 2800;
          const bufferLength = 256;
          const bufusedPtr = 3100;

          final dirPath = utf8.encode('many');
          bytes.setAll(pathPtr, dirPath);
          expect(
            pathOpen.ref([
              3,
              0,
              pathPtr,
              dirPath.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final dirFd = data.getUint32(openedFdPtr, Endian.little);

          var total = 0;
          var cookie = 0;
          for (var page = 0; page < 32; page++) {
            bytes.fillRange(direntsPtr, direntsPtr + bufferLength, 0);
            expect(
              fdReaddir.ref([
                dirFd,
                direntsPtr,
                bufferLength,
                cookie,
                bufusedPtr,
              ]),
              0,
            );
            final bufused = data.getUint32(bufusedPtr, Endian.little);
            final entries = _readDirents(bytes, data, direntsPtr, bufused);
            total += entries.length;
            if (bufused < bufferLength) {
              break;
            }
            expect(entries, isNotEmpty);
            cookie = entries.last.next;
          }

          expect(total, 102);
        },
        skip: _skipOnNode(
          'Skipping on Node.js; fd_readdir behavior is delegated to node:wasi.',
        ),
      );

      test(
        'path_create_directory, path_rename, path_unlink_file, and path_remove_directory update virtual paths',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/source.txt': Uint8List.fromList(utf8.encode('hello')),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathCreateDirectory =
              preview1['path_create_directory'] as FunctionImportExportValue;
          final pathRename =
              preview1['path_rename'] as FunctionImportExportValue;
          final pathUnlinkFile =
              preview1['path_unlink_file'] as FunctionImportExportValue;
          final pathRemoveDirectory =
              preview1['path_remove_directory'] as FunctionImportExportValue;
          final pathFilestatGet =
              preview1['path_filestat_get'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          const pathPtr = 2688;
          const newPathPtr = 2720;
          const filestatPtr = 2760;

          final dirPath = utf8.encode('work');
          bytes.setAll(pathPtr, dirPath);
          expect(pathCreateDirectory.ref([3, pathPtr, dirPath.length]), 0);
          expect(
            pathFilestatGet.ref([3, 0, pathPtr, dirPath.length, filestatPtr]),
            0,
          );
          expect(bytes[filestatPtr + 16], 3);

          final oldPath = utf8.encode('source.txt');
          final renamedPath = utf8.encode('work/renamed.txt');
          bytes.setAll(pathPtr, oldPath);
          bytes.setAll(newPathPtr, renamedPath);
          expect(
            pathRename.ref([
              3,
              pathPtr,
              oldPath.length,
              3,
              newPathPtr,
              renamedPath.length,
            ]),
            0,
          );
          expect(
            pathFilestatGet.ref([3, 0, pathPtr, oldPath.length, filestatPtr]),
            44,
          );
          expect(
            pathFilestatGet.ref([
              3,
              0,
              newPathPtr,
              renamedPath.length,
              filestatPtr,
            ]),
            0,
          );
          expect(bytes[filestatPtr + 16], 4);

          expect(pathUnlinkFile.ref([3, newPathPtr, renamedPath.length]), 0);
          expect(
            pathFilestatGet.ref([
              3,
              0,
              newPathPtr,
              renamedPath.length,
              filestatPtr,
            ]),
            44,
          );

          bytes.setAll(pathPtr, dirPath);
          expect(pathRemoveDirectory.ref([3, pathPtr, dirPath.length]), 0);
          expect(
            pathFilestatGet.ref([3, 0, pathPtr, dirPath.length, filestatPtr]),
            44,
          );
        },
        skip: _skipOnNode(
          'Skipping on Node.js; path mutation behavior is delegated to node:wasi.',
        ),
      );

      test(
        'path_link creates hard links to virtual files',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/source.txt': Uint8List.fromList(utf8.encode('hello')),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathLink = preview1['path_link'] as FunctionImportExportValue;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final pathUnlinkFile =
              preview1['path_unlink_file'] as FunctionImportExportValue;
          final pathFilestatGet =
              preview1['path_filestat_get'] as FunctionImportExportValue;
          final fdPread = preview1['fd_pread'] as FunctionImportExportValue;
          final fdPwrite = preview1['fd_pwrite'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const oldPathPtr = 2848;
          const newPathPtr = 2880;
          const openedFdPtr = 2912;
          const filestatPtr = 2928;
          const iovPtr = 3000;
          const readBufferPtr = 3024;
          const readCountPtr = 3056;
          const writeBufferPtr = 3072;

          final oldPath = utf8.encode('source.txt');
          final newPath = utf8.encode('linked.txt');
          bytes.setAll(oldPathPtr, oldPath);
          bytes.setAll(newPathPtr, newPath);
          expect(
            pathLink.ref([
              3,
              0,
              oldPathPtr,
              oldPath.length,
              3,
              newPathPtr,
              newPath.length,
            ]),
            0,
          );
          expect(
            pathFilestatGet.ref([
              3,
              0,
              newPathPtr,
              newPath.length,
              filestatPtr,
            ]),
            0,
          );
          expect(bytes[filestatPtr + 16], 4);

          expect(
            pathOpen.ref([
              3,
              0,
              oldPathPtr,
              oldPath.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final oldFd = data.getUint32(openedFdPtr, Endian.little);
          bytes[writeBufferPtr] = 'J'.codeUnitAt(0);
          data.setUint32(iovPtr, writeBufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 1, Endian.little);
          expect(fdPwrite.ref([oldFd, iovPtr, 1, 0, readCountPtr]), 0);
          expect(data.getUint32(readCountPtr, Endian.little), 1);

          expect(pathUnlinkFile.ref([3, oldPathPtr, oldPath.length]), 0);
          expect(
            pathFilestatGet.ref([
              3,
              0,
              oldPathPtr,
              oldPath.length,
              filestatPtr,
            ]),
            44,
          );
          expect(
            pathOpen.ref([
              3,
              0,
              newPathPtr,
              newPath.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final fd = data.getUint32(openedFdPtr, Endian.little);
          data.setUint32(iovPtr, readBufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 5, Endian.little);
          expect(fdPread.ref([fd, iovPtr, 1, 0, readCountPtr]), 0);
          expect(data.getUint32(readCountPtr, Endian.little), 5);
          expect(
            utf8.decode(bytes.sublist(readBufferPtr, readBufferPtr + 5)),
            'Jello',
          );
        },
        skip: _skipOnNode(
          'Skipping on Node.js; path_link behavior is delegated to node:wasi.',
        ),
      );

      test(
        'path_symlink and path_readlink preserve virtual symlink targets',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/target.txt': Uint8List.fromList(utf8.encode('target')),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathSymlink =
              preview1['path_symlink'] as FunctionImportExportValue;
          final pathReadlink =
              preview1['path_readlink'] as FunctionImportExportValue;
          final pathFilestatGet =
              preview1['path_filestat_get'] as FunctionImportExportValue;
          final pathFilestatSetTimes =
              preview1['path_filestat_set_times'] as FunctionImportExportValue;
          final pathLink = preview1['path_link'] as FunctionImportExportValue;
          final pathOpen = preview1['path_open'] as FunctionImportExportValue;
          final fdPread = preview1['fd_pread'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          final targetPath = utf8.encode('target.txt');
          final linkPath = utf8.encode('link.txt');
          final hardLinkPath = utf8.encode('hard.txt');
          const targetPathPtr = 3312;
          const linkPathPtr = 3344;
          const readlinkBufferPtr = 3376;
          const readlinkUsedPtr = 3408;
          const filestatPtr = 3424;
          const openedFdPtr = 3496;
          const iovPtr = 3520;
          const readBufferPtr = 3552;
          const readCountPtr = 3584;
          const hardLinkPathPtr = 3616;

          bytes.setAll(targetPathPtr, targetPath);
          bytes.setAll(linkPathPtr, linkPath);
          bytes.setAll(hardLinkPathPtr, hardLinkPath);
          expect(
            pathSymlink.ref([
              targetPathPtr,
              targetPath.length,
              3,
              linkPathPtr,
              linkPath.length,
            ]),
            0,
          );

          expect(
            pathReadlink.ref([
              3,
              linkPathPtr,
              linkPath.length,
              readlinkBufferPtr,
              32,
              readlinkUsedPtr,
            ]),
            0,
          );
          final readlinkUsed = data.getUint32(readlinkUsedPtr, Endian.little);
          expect(
            utf8.decode(
              bytes.sublist(
                readlinkBufferPtr,
                readlinkBufferPtr + readlinkUsed,
              ),
            ),
            'target.txt',
          );

          expect(
            pathFilestatGet.ref([
              3,
              0,
              linkPathPtr,
              linkPath.length,
              filestatPtr,
            ]),
            0,
          );
          expect(bytes[filestatPtr + 16], 7);
          expect(
            pathFilestatSetTimes.ref([
              3,
              0,
              linkPathPtr,
              linkPath.length,
              111,
              222,
              5,
            ]),
            0,
          );
          expect(
            pathFilestatGet.ref([
              3,
              0,
              linkPathPtr,
              linkPath.length,
              filestatPtr,
            ]),
            0,
          );
          expect(bytes[filestatPtr + 16], 7);
          expect(_getUint64Le(data, filestatPtr + 40), 111);
          expect(_getUint64Le(data, filestatPtr + 48), 222);
          expect(
            pathFilestatSetTimes.ref([
              3,
              1,
              linkPathPtr,
              linkPath.length,
              333,
              444,
              5,
            ]),
            0,
          );
          expect(
            pathFilestatGet.ref([
              3,
              1,
              linkPathPtr,
              linkPath.length,
              filestatPtr,
            ]),
            0,
          );
          expect(bytes[filestatPtr + 16], 4);
          expect(_getUint64Le(data, filestatPtr + 32), 6);
          expect(_getUint64Le(data, filestatPtr + 40), 333);
          expect(_getUint64Le(data, filestatPtr + 48), 444);
          expect(
            pathFilestatGet.ref([
              3,
              0,
              linkPathPtr,
              linkPath.length,
              filestatPtr,
            ]),
            0,
          );
          expect(bytes[filestatPtr + 16], 7);
          expect(_getUint64Le(data, filestatPtr + 40), 111);
          expect(_getUint64Le(data, filestatPtr + 48), 222);

          expect(
            pathLink.ref([
              3,
              1,
              linkPathPtr,
              linkPath.length,
              3,
              hardLinkPathPtr,
              hardLinkPath.length,
            ]),
            0,
          );

          expect(
            pathOpen.ref([
              3,
              1,
              linkPathPtr,
              linkPath.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final fd = data.getUint32(openedFdPtr, Endian.little);
          data.setUint32(iovPtr, readBufferPtr, Endian.little);
          data.setUint32(iovPtr + 4, 6, Endian.little);
          expect(fdPread.ref([fd, iovPtr, 1, 0, readCountPtr]), 0);
          expect(data.getUint32(readCountPtr, Endian.little), 6);
          expect(
            utf8.decode(bytes.sublist(readBufferPtr, readBufferPtr + 6)),
            'target',
          );
          bytes.fillRange(readBufferPtr, readBufferPtr + 6, 0);
          expect(
            pathOpen.ref([
              3,
              0,
              hardLinkPathPtr,
              hardLinkPath.length,
              0,
              _rightsAll,
              _rightsAll,
              0,
              openedFdPtr,
            ]),
            0,
          );
          final hardFd = data.getUint32(openedFdPtr, Endian.little);
          expect(fdPread.ref([hardFd, iovPtr, 1, 0, readCountPtr]), 0);
          expect(data.getUint32(readCountPtr, Endian.little), 6);
          expect(
            utf8.decode(bytes.sublist(readBufferPtr, readBufferPtr + 6)),
            'target',
          );
        },
        skip: _skipOnNode(
          'Skipping on Node.js; symlink behavior is delegated to node:wasi.',
        ),
      );

      test(
        'path_filestat_get reports file, directory, and missing paths',
        () async {
          final fileWasi = WASI(
            preopens: {'/sandbox': '/tmp'},
            files: {
              '/sandbox/doom1.wad': Uint8List.fromList([1, 2, 3, 4]),
            },
          );
          final fileResult = await WebAssembly.instantiate(
            _wasiBytes.buffer,
            fileWasi.imports,
          );
          final fileInstance = fileResult.instance;
          final preview1 = fileWasi.imports['wasi_snapshot_preview1']!;
          final pathFilestatGet =
              preview1['path_filestat_get'] as FunctionImportExportValue;
          final memory =
              (fileInstance.exports['memory'] as MemoryImportExportValue).ref;
          fileWasi.finalizeBindings(fileInstance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const pathPtr = 2064;
          const filestatPtr = 2100;

          final filePath = utf8.encode('doom1.wad');
          bytes.setAll(pathPtr, filePath);
          expect(
            pathFilestatGet.ref([3, 0, pathPtr, filePath.length, filestatPtr]),
            0,
          );
          expect(bytes[filestatPtr + 16], 4);
          expect(data.getUint32(filestatPtr + 32, Endian.little), 4);
          expect(data.getUint32(filestatPtr + 36, Endian.little), 0);

          final dirPath = utf8.encode('.');
          bytes.setAll(pathPtr, dirPath);
          expect(
            pathFilestatGet.ref([3, 0, pathPtr, dirPath.length, filestatPtr]),
            0,
          );
          expect(bytes[filestatPtr + 16], 3);

          final missingPath = utf8.encode('missing.wad');
          bytes.setAll(pathPtr, missingPath);
          expect(
            pathFilestatGet.ref([
              3,
              0,
              pathPtr,
              missingPath.length,
              filestatPtr,
            ]),
            44,
          );
        },
        skip: _skipOnNode(
          'Skipping on Node.js; path_filestat_get behavior is delegated to node:wasi.',
        ),
      );

      test(
        'fd_prestat_get and fd_prestat_dir_name expose configured preopen',
        () {
          final preview1 = wasi.imports['wasi_snapshot_preview1']!;
          final fdPrestatGet =
              preview1['fd_prestat_get'] as FunctionImportExportValue;
          final fdPrestatDirName =
              preview1['fd_prestat_dir_name'] as FunctionImportExportValue;
          final memory =
              (instance.exports['memory'] as MemoryImportExportValue).ref;
          wasi.finalizeBindings(instance, memory: memory);

          final bytes = Uint8List.view(memory.buffer);
          final data = ByteData.view(memory.buffer);
          const prestatPtr = 1800;
          const pathPtr = 1816;

          expect(fdPrestatGet.ref([3, prestatPtr]), 0);
          expect(bytes[prestatPtr], 0);
          final pathLen = data.getUint32(prestatPtr + 4, Endian.little);
          expect(pathLen, 8);

          expect(fdPrestatDirName.ref([3, pathPtr, pathLen]), 0);
          expect(
            utf8.decode(bytes.sublist(pathPtr, pathPtr + pathLen)),
            '/sandbox',
          );
        },
        skip: _skipOnNode(
          'Skipping on Node.js; prestat behavior is delegated to node:wasi.',
        ),
      );
    });
  });
}
