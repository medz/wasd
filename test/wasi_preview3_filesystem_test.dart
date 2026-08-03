import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/async_values.dart';
import 'package:wasd/src/wasi/component/resource_table.dart';
import 'package:wasd/src/wasi/preview3/filesystem.dart';
import 'package:wasd/src/wasi/preview3/native/default_hosts_stub.dart'
    as portable;
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';

void main() {
  group('WASIPreview3FilesystemHost', () {
    test('reports portable preopen and mutation requirements', () {
      expect(
        () => portable.createDefaultPreview3FilesystemHost(
          preopens: const <String, String>{},
          canMutate: true,
          table: WASIComponentResourceTable(),
        ),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => error.toString(),
            'message',
            contains('preopens and mutation support require dart:io'),
          ),
        ),
      );
    });

    test('enforces descriptor flags and official symlink resolution', () async {
      final directory = WASIPreview3FilesystemDirectory(
        canMutate: true,
        entries: [
          WASIPreview3FilesystemDirectoryEntry.regularFile(
            'file.txt',
            bytes: const <int>[1, 2, 3],
            canMutate: true,
          ),
          WASIPreview3FilesystemDirectoryEntry.symbolicLink(
            'link.txt',
            target: 'file.txt',
          ),
        ],
      );
      final host = WASIPreview3FilesystemHost(preopens: {'/': directory});
      final root = await _preopen(host);

      final openedWithDefaultRead = await _open(host, root, 'file.txt');
      final file = _okHandle(openedWithDefaultRead);
      final read =
          await _invoke(host, 'descriptor.read-via-stream', [file, BigInt.zero])
              as List<Object?>;
      final readStream = read[0] as WASIComponentStream<int>;
      final readResult = read[1] as WASIComponentFuture<WasmComponentValueData>;
      expect(await readStream.readable.readWhenAvailable(3), [1, 2, 3]);
      expect((await readResult.readable.readWhenReady()).isOk, isTrue);
      expect(readResult.writable.isDropped, isTrue);

      final noFollow =
          await _invoke(host, 'descriptor.stat-at', [
                root,
                _flags(),
                'link.txt',
              ])
              as WasmComponentValueData;
      final follow =
          await _invoke(host, 'descriptor.stat-at', [
                root,
                _flags('symlink-follow'),
                'link.txt',
              ])
              as WasmComponentValueData;
      expect(_statType(noFollow), 'symbolic-link');
      expect(_statType(follow), 'regular-file');

      final invalidTruncate = await _open(
        host,
        root,
        'file.txt',
        openFlags: _flags('truncate'),
      );
      expect(_errorLabel(invalidTruncate), 'invalid');

      final absoluteSymlink =
          await _invoke(host, 'descriptor.symlink-at', [
                root,
                '/outside',
                'absolute-link',
              ])
              as WasmComponentValueData;
      expect(_errorLabel(absoluteSymlink), 'not-permitted');
    });

    test('rename preserves one mutable regular-file backing', () async {
      final source = WASIPreview3FilesystemDirectoryEntry.regularFile(
        'source.txt',
        bytes: const <int>[1, 2, 3],
        canMutate: true,
      );
      final directory = WASIPreview3FilesystemDirectory(
        canMutate: true,
        entries: [source],
      );
      final host = WASIPreview3FilesystemHost(preopens: {'/': directory});
      final root = await _preopen(host);
      final openedBeforeRename = _okHandle(
        await _open(host, root, 'source.txt', flags: _flags('read', 'write')),
      );

      final rename =
          await _invoke(host, 'descriptor.rename-at', [
                root,
                'source.txt',
                root,
                'renamed.txt',
              ])
              as WasmComponentValueData;
      expect(rename.isOk, isTrue);
      final renamed = directory.entries.single;

      await _writeDescriptor(host, openedBeforeRename, const <int>[9], 3);
      expect(renamed.bytes, <int>[1, 2, 3, 9]);

      final openedAfterRename = _okHandle(
        await _open(host, root, 'renamed.txt', flags: _flags('read', 'write')),
      );
      expect(
        (await _invoke(host, 'descriptor.set-size', [
                  openedAfterRename,
                  BigInt.from(2),
                ])
                as WasmComponentValueData)
            .isOk,
        isTrue,
      );
      await _writeDescriptor(host, openedAfterRename, const <int>[8], 1);
      expect(source.bytes, <int>[1, 8]);

      final first = WASIComponentStream<int>('before-rename-append');
      final second = WASIComponentStream<int>('after-rename-append');
      final firstResult =
          await _invoke(host, 'descriptor.append-via-stream', [
                openedBeforeRename,
                first,
              ])
              as WASIComponentFuture<WasmComponentValueData>;
      final secondResult =
          await _invoke(host, 'descriptor.append-via-stream', [
                openedAfterRename,
                second,
              ])
              as WASIComponentFuture<WasmComponentValueData>;
      await Future<void>.delayed(Duration.zero);
      first.writable
        ..write(4)
        ..close();
      second.writable
        ..write(5)
        ..close();
      expect((await firstResult.readable.readWhenReady()).isOk, isTrue);
      expect((await secondResult.readable.readWhenReady()).isOk, isTrue);
      expect(
        renamed.bytes,
        anyOf(equals(<int>[1, 8, 4, 5]), equals(<int>[1, 8, 5, 4])),
      );
    });

    test(
      'bounds file producers and completes after stream consumption',
      () async {
        final bytes = List<int>.generate(100000, (index) => index & 0xff);
        final host = WASIPreview3FilesystemHost(
          preopens: {
            '/': WASIPreview3FilesystemDirectory(
              entries: [
                WASIPreview3FilesystemDirectoryEntry.regularFile(
                  'large.bin',
                  bytes: bytes,
                ),
              ],
            ),
          },
        );
        final root = await _preopen(host);
        final file = _okHandle(
          await _open(host, root, 'large.bin', flags: _flags('read')),
        );
        final read =
            await _invoke(host, 'descriptor.read-via-stream', [
                  file,
                  BigInt.zero,
                ])
                as List<Object?>;
        final stream = read[0] as WASIComponentStream<int>;
        final result = read[1] as WASIComponentFuture<WasmComponentValueData>;

        expect(stream.maxBufferedElements, 65536);
        expect(stream.queuedLength, lessThanOrEqualTo(65536));
        expect(result.readable.isReady, isFalse);

        final received = <int>[];
        while (true) {
          final chunk = await stream.readable.readWhenAvailable(8192);
          if (chunk.isEmpty) {
            break;
          }
          received.addAll(chunk);
        }
        expect(received, bytes);
        expect((await result.readable.readWhenReady()).isOk, isTrue);
      },
    );

    test('reports unsupported durability instead of fake success', () async {
      final data = Uint8List.fromList(<int>[1]);
      final entry = WASIPreview3FilesystemDirectoryEntry.regularFile(
        'dynamic.bin',
        canMutate: true,
        currentSize: () => BigInt.from(data.length),
        readBytes: (offset) => data.sublist(offset.toInt()),
        writeBytes: (offset, bytes) {
          data.setRange(offset.toInt(), offset.toInt() + bytes.length, bytes);
          return const WASIPreview3FilesystemMutationResult.ok();
        },
      );
      final host = WASIPreview3FilesystemHost(
        preopens: {
          '/': WASIPreview3FilesystemDirectory(
            canMutate: true,
            entries: [entry],
          ),
        },
      );
      final root = await _preopen(host);
      final file = _okHandle(
        await _open(host, root, 'dynamic.bin', flags: _flags('read', 'write')),
      );

      final sync = await _invoke(host, 'descriptor.sync', [file]);
      final syncData = await _invoke(host, 'descriptor.sync-data', [file]);
      final advise = await _invoke(host, 'descriptor.advise', [
        file,
        BigInt.zero,
        BigInt.one,
        _enum('normal'),
      ]);

      expect(_errorLabel(sync as WasmComponentValueData), 'unsupported');
      expect(_errorLabel(syncData as WasmComponentValueData), 'unsupported');
      expect(_errorLabel(advise as WasmComponentValueData), 'unsupported');
    });

    test('accepts pre-epoch system-clock instants', () async {
      WASIPreview3FilesystemTimestampUpdate? seen;
      final host = WASIPreview3FilesystemHost(
        preopens: {
          '/': WASIPreview3FilesystemDirectory(
            canMutate: true,
            entries: [
              WASIPreview3FilesystemDirectoryEntry.regularFile(
                'old.txt',
                canMutate: true,
                setTimes: (update) {
                  seen = update;
                  return const WASIPreview3FilesystemMutationResult.ok();
                },
              ),
            ],
          ),
        },
      );
      final root = await _preopen(host);
      final file = _okHandle(
        await _open(host, root, 'old.txt', flags: _flags('write')),
      );
      final result =
          await _invoke(host, 'descriptor.set-times', [
                file,
                _timestamp(-1, 999999999),
                _variant('no-change'),
              ])
              as WasmComponentValueData;

      expect(result.isOk, isTrue);
      expect(seen?.accessTimeNanos, BigInt.from(-1));
    });

    test(
      'owns descriptors and holds async write borrows until completion',
      () async {
        final host = WASIPreview3FilesystemHost(
          preopens: {
            '/': WASIPreview3FilesystemDirectory(
              canMutate: true,
              entries: [
                WASIPreview3FilesystemDirectoryEntry.regularFile(
                  'file.bin',
                  canMutate: true,
                ),
              ],
            ),
          },
        );
        final firstRoot = await _preopen(host);
        final secondRoot = await _preopen(host);
        expect(secondRoot, isNot(firstRoot));
        expect(host.table.activeCount, 2);

        host.table.dropNamed(
          'wasi:filesystem/types@0.3.0.descriptor',
          firstRoot,
        );
        final droppedType =
            await _invoke(host, 'descriptor.get-type', [firstRoot])
                as WasmComponentValueData;
        expect(_errorLabel(droppedType), 'bad-descriptor');

        final file = _okHandle(
          await _open(host, secondRoot, 'file.bin', flags: _flags('write')),
        );
        final source = WASIComponentStream<int>('pending-write');
        final result =
            await _invoke(host, 'descriptor.write-via-stream', [
                  file,
                  source,
                  BigInt.zero,
                ])
                as WASIComponentFuture<WasmComponentValueData>;

        expect(
          () => host.table.dropNamed(
            'wasi:filesystem/types@0.3.0.descriptor',
            file,
          ),
          throwsStateError,
        );
        source.writable.close();
        expect((await result.readable.readWhenReady()).isOk, isTrue);
        host.table.dropNamed('wasi:filesystem/types@0.3.0.descriptor', file);
        expect(host.table.activeCount, 1);
      },
    );

    test('releases descriptor-backed host resources on drop', () async {
      final opened = <Set<String>>[];
      final closed = <Set<String>>[];
      final host = WASIPreview3FilesystemHost(
        preopens: {
          '/': WASIPreview3FilesystemDirectory(
            canMutate: true,
            entries: [
              WASIPreview3FilesystemDirectoryEntry.regularFile(
                'owned.bin',
                canMutate: true,
                openDescriptor: (flags) {
                  opened.add(Set<String>.of(flags));
                  return const WASIPreview3FilesystemMutationResult.ok();
                },
                closeDescriptor: (flags) {
                  closed.add(Set<String>.of(flags));
                },
              ),
            ],
          ),
        },
      );
      final root = await _preopen(host);
      final file = _okHandle(
        await _open(host, root, 'owned.bin', flags: _flags('read', 'write')),
      );

      expect(opened, [
        <String>{'read', 'write'},
      ]);
      expect(closed, isEmpty);
      host.table.dropNamed('wasi:filesystem/types@0.3.0.descriptor', file);
      expect(closed, [
        <String>{'read', 'write'},
      ]);
    });

    test('serializes concurrent append streams at the current end', () async {
      final entry = WASIPreview3FilesystemDirectoryEntry.regularFile(
        'append.bin',
        bytes: const <int>[0],
        canMutate: true,
      );
      final host = WASIPreview3FilesystemHost(
        preopens: {
          '/': WASIPreview3FilesystemDirectory(
            canMutate: true,
            entries: [entry],
          ),
        },
      );
      final root = await _preopen(host);
      final file = _okHandle(
        await _open(host, root, 'append.bin', flags: _flags('write')),
      );
      final first = WASIComponentStream<int>('first-append');
      final second = WASIComponentStream<int>('second-append');
      final firstResult =
          await _invoke(host, 'descriptor.append-via-stream', [file, first])
              as WASIComponentFuture<WasmComponentValueData>;
      final secondResult =
          await _invoke(host, 'descriptor.append-via-stream', [file, second])
              as WASIComponentFuture<WasmComponentValueData>;

      await Future<void>.delayed(Duration.zero);
      first.writable
        ..write(1)
        ..close();
      second.writable
        ..write(2)
        ..close();

      expect((await firstResult.readable.readWhenReady()).isOk, isTrue);
      expect((await secondResult.readable.readWhenReady()).isOk, isTrue);
      expect(
        entry.bytes,
        anyOf(equals(<int>[0, 1, 2]), equals(<int>[0, 2, 1])),
      );
    });

    test('treats a pending write or append writer drop as EOF', () async {
      final entry = WASIPreview3FilesystemDirectoryEntry.regularFile(
        'drop.bin',
        bytes: const <int>[0],
        canMutate: true,
      );
      final host = WASIPreview3FilesystemHost(
        preopens: {
          '/': WASIPreview3FilesystemDirectory(
            canMutate: true,
            entries: [entry],
          ),
        },
      );
      final root = await _preopen(host);
      final file = _okHandle(
        await _open(host, root, 'drop.bin', flags: _flags('write')),
      );

      for (final (function, arguments) in <(String, List<Object?>)>[
        ('descriptor.write-via-stream', <Object?>[file, BigInt.zero]),
        ('descriptor.append-via-stream', <Object?>[file]),
      ]) {
        final source = WASIComponentStream<int>(function);
        final result =
            await _invoke(host, function, <Object?>[
                  arguments.first,
                  source,
                  ...arguments.skip(1),
                ])
                as WASIComponentFuture<WasmComponentValueData>;
        await Future<void>.delayed(Duration.zero);
        expect(result.readable.isReady, isFalse);

        source.writable.drop();

        expect((await result.readable.readWhenReady()).isOk, isTrue);
        expect(entry.bytes, <int>[0]);
      }
    });

    test('bounds directory producers', () async {
      final host = WASIPreview3FilesystemHost(
        preopens: {
          '/': WASIPreview3FilesystemDirectory(
            entries: [
              for (var index = 0; index < 100; index++)
                WASIPreview3FilesystemDirectoryEntry.regularFile('file-$index'),
            ],
          ),
        },
      );
      final root = await _preopen(host);
      final read =
          await _invoke(host, 'descriptor.read-directory', [root])
              as List<Object?>;
      final stream = read[0] as WASIComponentStream<WasmComponentValueData>;
      final result = read[1] as WASIComponentFuture<WasmComponentValueData>;

      expect(stream.maxBufferedElements, 64);
      expect(stream.queuedLength, lessThanOrEqualTo(64));
      expect(result.readable.isReady, isFalse);

      var count = 0;
      while (true) {
        final entries = await stream.readable.readWhenAvailable(16);
        if (entries.isEmpty) {
          break;
        }
        count += entries.length;
      }
      expect(count, 100);
      expect((await result.readable.readWhenReady()).isOk, isTrue);
    });

    test('reports every Preview3 descriptor type shape', () async {
      final host = WASIPreview3FilesystemHost(
        preopens: {
          '/': WASIPreview3FilesystemDirectory(
            entries: [
              WASIPreview3FilesystemDirectoryEntry.special(
                'block',
                kind: WASIPreview3FilesystemDescriptorKind.blockDevice,
              ),
              WASIPreview3FilesystemDirectoryEntry.special(
                'character',
                kind: WASIPreview3FilesystemDescriptorKind.characterDevice,
              ),
              WASIPreview3FilesystemDirectoryEntry.special(
                'fifo',
                kind: WASIPreview3FilesystemDescriptorKind.fifo,
              ),
              WASIPreview3FilesystemDirectoryEntry.special(
                'socket',
                kind: WASIPreview3FilesystemDescriptorKind.socket,
              ),
              WASIPreview3FilesystemDirectoryEntry.special(
                'other',
                kind: WASIPreview3FilesystemDescriptorKind.other,
              ),
            ],
          ),
        },
      );
      final root = await _preopen(host);

      for (final (name, label) in const <(String, String)>[
        ('block', 'block-device'),
        ('character', 'character-device'),
        ('fifo', 'fifo'),
        ('socket', 'socket'),
        ('other', 'other'),
      ]) {
        final result =
            await _invoke(host, 'descriptor.stat-at', [root, _flags(), name])
                as WasmComponentValueData;
        expect(_statType(result), label);
        if (label == 'other') {
          final descriptorType = result.associatedValue!.items.first;
          expect(descriptorType.associatedValue?.label, 'none');
        }
      }
    });
  });
}

Future<Object?> _invoke(
  WASIPreview3FilesystemHost host,
  String function,
  List<Object?> args,
) async {
  return await host.imports['wasi:filesystem/types@0.3.0.$function']!(args);
}

Future<void> _writeDescriptor(
  WASIPreview3FilesystemHost host,
  int descriptor,
  List<int> bytes,
  int offset,
) async {
  final source = WASIComponentStream<int>('filesystem-test-write');
  source.writable
    ..writeAll(bytes)
    ..close();
  final result =
      await _invoke(host, 'descriptor.write-via-stream', [
            descriptor,
            source,
            BigInt.from(offset),
          ])
          as WASIComponentFuture<WasmComponentValueData>;
  expect((await result.readable.readWhenReady()).isOk, isTrue);
}

Future<int> _preopen(WASIPreview3FilesystemHost host) async {
  final value =
      await host.imports['wasi:filesystem/preopens@0.3.0.get-directories']!(
            const <Object?>[],
          )
          as WasmComponentValueData;
  return (value.items.single.items.first.integer as int);
}

Future<WasmComponentValueData> _open(
  WASIPreview3FilesystemHost host,
  int root,
  String path, {
  WasmComponentValueData? openFlags,
  WasmComponentValueData? flags,
}) async {
  return await _invoke(host, 'descriptor.open-at', [
        root,
        _flags(),
        path,
        openFlags ?? _flags(),
        flags ?? _flags(),
      ])
      as WasmComponentValueData;
}

int _okHandle(WasmComponentValueData result) {
  expect(result.isOk, isTrue);
  return (result.associatedValue!.integer as int);
}

String _errorLabel(WasmComponentValueData result) {
  expect(result.isOk, isFalse);
  return result.associatedValue!.label!;
}

String _statType(WasmComponentValueData result) {
  expect(result.isOk, isTrue);
  return result.associatedValue!.items.first.label!;
}

WasmComponentValueData _flags([String? first, String? second]) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.flags,
    rawBytes: Uint8List(0),
    labels: [?first, ?second],
  );
}

WasmComponentValueData _enum(String label) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.enumeration,
    rawBytes: Uint8List(0),
    label: label,
  );
}

WasmComponentValueData _timestamp(int seconds, int nanoseconds) {
  return _variant(
    'timestamp',
    WasmComponentValueData(
      kind: WasmComponentValueDataKind.record,
      rawBytes: Uint8List(0),
      items: [_integer(BigInt.from(seconds)), _integer(nanoseconds)],
    ),
  );
}

WasmComponentValueData _variant(
  String label, [
  WasmComponentValueData? associatedValue,
]) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.variant,
    rawBytes: Uint8List(0),
    label: label,
    associatedValue: associatedValue,
  );
}

WasmComponentValueData _integer(Object value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.integer,
    rawBytes: Uint8List(0),
    integer: value,
  );
}
