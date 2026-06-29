import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/wasm.dart';
import 'package:wasd/wasi.dart';

import 'support/host_fs.dart';
import 'support/runtime_environment.dart';

void main() {
  group('public WASI component API', () {
    test('decodes components and prepares fixed Preview2/Preview3 hosts', () {
      final component = WasmComponent.decode(_emptyComponentBytes());
      final preview2 = WASIPreview2ComponentHost();
      final preview3 = WASIPreview3ComponentHost();

      expect(component.validate(), isEmpty);
      expect(preview2.profile, same(WASIComponentVersionProfile.preview2));
      expect(preview3.profile, same(WASIComponentVersionProfile.preview3));
      expect(preview2.prepareComponent(component).canBind, isTrue);
      expect(preview3.prepareComponent(component).canBind, isTrue);
    });

    test(
      'exposes WIT world ingestion through versioned Preview2/3 profiles',
      () {
        const source = '''
package wasi:cli@0.3.0;

interface run {
  run: async func() -> result;
}

interface stdout {
  write-via-stream: func(data: stream<u8>) -> future<result>;
}

world command {
  import run;
  include wasi:filesystem/imports@0.3.0;
  export stdout;
}
''';
        final document = WASIComponentWitDocument.parse(source);

        final preview2 = WASIPreview2ComponentHost().prepareWitWorld(
          document,
          worldName: 'command',
        );
        final preview3 = WASIPreview3ComponentHost().prepareWitWorld(
          document,
          worldName: 'command',
        );

        expect(preview2.canIngest, isFalse);
        expect(
          preview2.versionErrors.map((error) => error.targetName),
          containsAll(<String>[
            'run.run',
            'stdout.write-via-stream',
            'wasi:filesystem/imports@0.3.0',
          ]),
        );
        expect(preview3.canIngest, isTrue);
        expect(preview3.versionErrors, isEmpty);
        expect(preview3.canBindAdapters, isTrue);
        expect(preview3.bindingErrors, isEmpty);
        expect(preview3.world.name, 'command');
      },
    );

    test('binds standard Preview3 random imports from public API', () {
      const source = '''
package wasi-testsuite:test;

world random-test {
  include wasi:random/imports@0.3.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final host = WASIPreview3ComponentHost();
      final program = host.bindWitWorld(document, worldName: 'random-test');
      final bytes =
          program.invokeImport('wasi:random/random@0.3.0.get-random-bytes', [
                BigInt.from(4),
              ])
              as WasmComponentValueData;

      expect(bytes.kind, WasmComponentValueDataKind.list);
      expect(bytes.items, hasLength(4));
      expect(
        host.standardImports,
        contains('wasi:random/insecure-seed@0.3.0.get-insecure-seed'),
      );
    });

    test('binds standard Preview3 clocks imports from public API', () {
      const source = '''
package wasi-testsuite:test;

world clocks-test {
  include wasi:clocks/imports@0.3.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final host = WASIPreview3ComponentHost();
      final program = host.bindWitWorld(document, worldName: 'clocks-test');
      final now = program.invokeImport(
        'wasi:clocks/monotonic-clock@0.3.0.now',
        const [],
      );

      expect(now, isA<BigInt>());
      expect(
        host.standardImports,
        contains('wasi:clocks/system-clock@0.3.0.now'),
      );
    });

    test('binds standard Preview3 CLI imports from public API', () {
      const source = '''
package wasi-testsuite:test;

world cli-test {
  include wasi:cli/imports@0.3.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final host = WASIPreview3ComponentHost(
        args: const <String>['cli-env.wasm', 'a'],
        env: const <String, String>{'foo': 'bar'},
        stdinData: const <int>[65],
      );
      final program = host.bindWitWorld(document, worldName: 'cli-test');
      final args =
          program.invokeImport(
                'wasi:cli/environment@0.3.0.get-arguments',
                const [],
              )
              as WasmComponentValueData;

      expect(args.kind, WasmComponentValueDataKind.list);
      expect(args.items.map((item) => item.string), ['cli-env.wasm', 'a']);
      expect(
        host.standardImports,
        contains('wasi:cli/stdin@0.3.0.read-via-stream'),
      );
      expect(host.cliHost.stdinData, [65]);
    });

    test('binds standard Preview3 filesystem imports from public API', () {
      const source = '''
package wasi-testsuite:test;

world filesystem-test {
  import wasi:filesystem/preopens@0.3.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final filesystem = WASIPreview3FilesystemHost(
        preopens: {
          '/': WASIPreview3FilesystemDirectory(
            entries: [
              WASIPreview3FilesystemDirectoryEntry.regularFile(
                'config.json',
                size: BigInt.from(2),
              ),
            ],
          ),
        },
      );
      final host = WASIPreview3ComponentHost(filesystemHost: filesystem);
      final program = host.bindWitWorld(document, worldName: 'filesystem-test');
      final directories =
          program.invokeImport(
                'wasi:filesystem/preopens@0.3.0.get-directories',
                const [],
              )
              as WasmComponentValueData;

      expect(directories.kind, WasmComponentValueDataKind.list);
      expect(directories.items, hasLength(1));
      expect(directories.items.single.items[1].string, '/');
      expect(
        host.standardImports,
        contains('wasi:filesystem/types@0.3.0.descriptor.stat'),
      );
      expect(host.filesystemHost, same(filesystem));
    });

    test(
      'binds Preview3 filesystem imports to real host files on Dart VM',
      () async {
        if (!hasDartIoRuntime) {
          markTestSkipped('requires dart:io host filesystem access');
          return;
        }
        final temp = createHostTemp('wasd_p3_host_fs_');
        if (temp == null) {
          markTestSkipped('requires dart:io host filesystem access');
          return;
        }
        addTearDown(temp.delete);
        temp.writeFile('hello.txt', 'hello');
        temp.createDirectory('etc');
        temp.writeFile('etc/config.txt', 'cfg');

        const source = '''
package wasi-testsuite:test;

world filesystem-test {
  include wasi:filesystem/imports@0.3.0;
}
''';
        final document = WASIComponentWitDocument.parse(source);
        final host = WASIPreview3ComponentHost(
          filesystemHost: WASIPreview3NativeFilesystemHost(
            preopens: {'/': temp.path},
          ),
        );
        final program = host.bindWitWorld(
          document,
          worldName: 'filesystem-test',
        );
        final directories =
            program.invokeImport(
                  'wasi:filesystem/preopens@0.3.0.get-directories',
                  const [],
                )
                as WasmComponentValueData;
        final root = _preopenHandle(directories, '/');
        final directoryRead =
            program.invokeImport(
                  'wasi:filesystem/types@0.3.0.descriptor.read-directory',
                  [root],
                )
                as List<Object?>;
        final entries =
            directoryRead[0] as WASIComponentStream<WasmComponentValueData>;
        final opened =
            await program.invokeImportAsync(
                  'wasi:filesystem/types@0.3.0.descriptor.open-at',
                  [
                    root,
                    _flagsValue(const <String>[]),
                    'hello.txt',
                    _flagsValue(const <String>[]),
                    _flagsValue(const <String>['read']),
                  ],
                )
                as WasmComponentValueData;

        expect(
          entries.readable.read(8).map(_directoryEntryName),
          containsAll(<String>['hello.txt', 'etc']),
        );

        final file = _resultHandle(_resultOk(opened));
        final fileRead =
            program.invokeImport(
                  'wasi:filesystem/types@0.3.0.descriptor.read-via-stream',
                  [file, BigInt.from(1)],
                )
                as List<Object?>;
        final fileStream = fileRead[0] as WASIComponentStream<int>;

        expect(fileStream.readable.read(8), [101, 108, 108, 111]);
      },
    );

    test('mutates Preview3 filesystem real host files on Dart VM', () async {
      if (!hasDartIoRuntime) {
        markTestSkipped('requires dart:io host filesystem access');
        return;
      }
      final temp = createHostTemp('wasd_p3_host_mutate_');
      if (temp == null) {
        markTestSkipped('requires dart:io host filesystem access');
        return;
      }
      addTearDown(temp.delete);
      temp.writeFile('note.txt', 'hello');

      const source = '''
package wasi-testsuite:test;

world filesystem-test {
  include wasi:filesystem/imports@0.3.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final host = WASIPreview3ComponentHost(
        filesystemHost: WASIPreview3NativeFilesystemHost(
          preopens: {'/': temp.path},
          canMutate: true,
        ),
      );
      final program = host.bindWitWorld(document, worldName: 'filesystem-test');
      final directories =
          program.invokeImport(
                'wasi:filesystem/preopens@0.3.0.get-directories',
                const [],
              )
              as WasmComponentValueData;
      final root = _preopenHandle(directories, '/');
      final opened =
          await program.invokeImportAsync(
                'wasi:filesystem/types@0.3.0.descriptor.open-at',
                [
                  root,
                  _flagsValue(const <String>[]),
                  'note.txt',
                  _flagsValue(const <String>[]),
                  _flagsValue(const <String>['read', 'write']),
                ],
              )
              as WasmComponentValueData;
      final file = _resultHandle(_resultOk(opened));

      final patch = WASIComponentStream<int>('p3-file-write');
      patch.writable.writeAll(<int>[88, 89]);
      patch.writable.close();
      final writeResult =
          program.invokeImport(
                'wasi:filesystem/types@0.3.0.descriptor.write-via-stream',
                [file, patch, BigInt.from(1)],
              )
              as WASIComponentFuture<WasmComponentValueData>;
      _expectUnitOk(await writeResult.readable.readWhenReady());
      expect(temp.readFile('note.txt'), 'hXYlo');

      final append = WASIComponentStream<int>('p3-file-append');
      append.writable.write(33);
      append.writable.close();
      final appendResult =
          program.invokeImport(
                'wasi:filesystem/types@0.3.0.descriptor.append-via-stream',
                [file, append],
              )
              as WASIComponentFuture<WasmComponentValueData>;
      _expectUnitOk(await appendResult.readable.readWhenReady());
      expect(temp.readFile('note.txt'), 'hXYlo!');

      final resize =
          await program.invokeImportAsync(
                'wasi:filesystem/types@0.3.0.descriptor.set-size',
                [file, BigInt.from(3)],
              )
              as WasmComponentValueData;
      _expectUnitOk(resize);
      expect(temp.readFile('note.txt'), 'hXY');

      final mkdir =
          await program.invokeImportAsync(
                'wasi:filesystem/types@0.3.0.descriptor.create-directory-at',
                [root, 'created'],
              )
              as WasmComponentValueData;
      _expectUnitOk(mkdir);
      expect(temp.directoryExists('created'), isTrue);

      final created =
          await program.invokeImportAsync(
                'wasi:filesystem/types@0.3.0.descriptor.open-at',
                [
                  root,
                  _flagsValue(const <String>[]),
                  'created.txt',
                  _flagsValue(const <String>['create']),
                  _flagsValue(const <String>['read', 'write']),
                ],
              )
              as WasmComponentValueData;
      final createdFile = _resultHandle(_resultOk(created));
      final createdBytes = WASIComponentStream<int>('p3-created-file-write');
      createdBytes.writable.writeAll(<int>[110, 101, 119]);
      createdBytes.writable.close();
      final createWriteResult =
          program.invokeImport(
                'wasi:filesystem/types@0.3.0.descriptor.write-via-stream',
                [createdFile, createdBytes, BigInt.zero],
              )
              as WASIComponentFuture<WasmComponentValueData>;
      _expectUnitOk(await createWriteResult.readable.readWhenReady());
      expect(temp.readFile('created.txt'), 'new');

      final unlink =
          await program.invokeImportAsync(
                'wasi:filesystem/types@0.3.0.descriptor.unlink-file-at',
                [root, 'note.txt'],
              )
              as WasmComponentValueData;
      _expectUnitOk(unlink);
      expect(temp.fileExists('note.txt'), isFalse);

      final unlinkCreated =
          await program.invokeImportAsync(
                'wasi:filesystem/types@0.3.0.descriptor.unlink-file-at',
                [root, 'created.txt'],
              )
              as WasmComponentValueData;
      _expectUnitOk(unlinkCreated);
      expect(temp.fileExists('created.txt'), isFalse);

      final rmdir =
          await program.invokeImportAsync(
                'wasi:filesystem/types@0.3.0.descriptor.remove-directory-at',
                [root, 'created'],
              )
              as WasmComponentValueData;
      _expectUnitOk(rmdir);
      expect(temp.directoryExists('created'), isFalse);
    });
  });
}

int _preopenHandle(WasmComponentValueData value, String path) {
  for (final item in value.items) {
    if (item.items.length == 2 && item.items[1].string == path) {
      return _resultHandle(item.items[0]);
    }
  }
  throw StateError('missing preopen $path');
}

WasmComponentValueData _resultOk(WasmComponentValueData value) {
  final associated = value.associatedValue;
  if (value.kind != WasmComponentValueDataKind.result ||
      !(value.isOk ?? value.index == 0 || value.label == 'ok') ||
      associated == null) {
    throw StateError('expected ok result');
  }
  return associated;
}

int _resultHandle(WasmComponentValueData value) {
  final integer = value.integer;
  if (integer is int) {
    return integer;
  }
  if (integer is BigInt) {
    return integer.toInt();
  }
  throw StateError('expected resource handle');
}

void _expectUnitOk(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.result ||
      !(value.isOk ?? value.index == 0 || value.label == 'ok')) {
    throw StateError('expected ok result');
  }
}

String _directoryEntryName(WasmComponentValueData value) {
  if (value.items.length != 2 ||
      value.items[1].kind != WasmComponentValueDataKind.string) {
    throw StateError('expected directory entry');
  }
  return value.items[1].string!;
}

WasmComponentValueData _flagsValue(List<String> labels) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.flags,
    rawBytes: Uint8List(0),
    labels: labels,
  );
}

Uint8List _emptyComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
]);
