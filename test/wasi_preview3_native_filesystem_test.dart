@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/async_values.dart';
import 'package:wasd/src/wasi/component/resource_table.dart';
import 'package:wasd/src/wasi/preview3/native/default_hosts_stub.dart'
    as default_hosts_stub;
import 'package:wasd/src/wasi/preview3/native/filesystem.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';

void main() {
  test('portable default filesystem rejects native-only configuration', () {
    expect(
      () => default_hosts_stub.createDefaultPreview3FilesystemHost(
        preopens: const <String, String>{'/': '/tmp'},
        canMutate: false,
        table: WASIComponentResourceTable(),
      ),
      throwsUnsupportedError,
    );
    expect(
      () => default_hosts_stub.createDefaultPreview3FilesystemHost(
        preopens: const <String, String>{},
        canMutate: true,
        table: WASIComponentResourceTable(),
      ),
      throwsUnsupportedError,
    );
  });

  test(
    'Preview3 native filesystem streams chunks and performs durability',
    () async {
      final directory = Directory.systemTemp.createTempSync('wasd-p3-fs-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final bytes = List<int>.generate(100000, (index) => index & 0xff);
      final file = File('${directory.path}/large.bin')..writeAsBytesSync(bytes);
      final host = WASIPreview3NativeFilesystemHost(
        preopens: {'/': directory.path},
        canMutate: true,
      );
      final root = await _preopen(host);

      final readHandle = _okHandle(
        await _open(host, root, 'large.bin', flags: _flags(['read'])),
      );
      final read =
          await _invoke(host, 'descriptor.read-via-stream', [
                readHandle,
                BigInt.zero,
              ])
              as List<Object?>;
      final stream = read[0] as WASIComponentStream<int>;
      final result = read[1] as WASIComponentFuture<WasmComponentValueData>;
      expect(stream.maxBufferedElements, 65536);
      final received = <int>[];
      while (true) {
        final chunk = await stream.readable.readWhenAvailable(8192);
        if (chunk.isEmpty) break;
        received.addAll(chunk);
      }
      expect(received, bytes);
      expect((await result.readable.readWhenReady()).isOk, isTrue);

      final writeHandle = _okHandle(
        await _open(
          host,
          root,
          'large.bin',
          flags: _flags(['write', 'file-integrity-sync']),
        ),
      );
      final source = WASIComponentStream<int>('native-file-write');
      source.writable
        ..write(0x7f)
        ..close();
      final writeResult =
          await _invoke(host, 'descriptor.write-via-stream', [
                writeHandle,
                source,
                BigInt.zero,
              ])
              as WASIComponentFuture<WasmComponentValueData>;
      expect((await writeResult.readable.readWhenReady()).isOk, isTrue);
      expect(file.readAsBytesSync().first, 0x7f);
      expect(
        (await _invoke(host, 'descriptor.sync', [writeHandle])
                as WasmComponentValueData)
            .isOk,
        isTrue,
      );
      expect(
        (await _invoke(host, 'descriptor.sync-data', [writeHandle])
                as WasmComponentValueData)
            .isOk,
        isTrue,
      );

      if (!Platform.isWindows) {
        final symlink =
            await _invoke(host, 'descriptor.symlink-at', [
                  root,
                  'large.bin',
                  'link.bin',
                ])
                as WasmComponentValueData;
        expect(symlink.isOk, isTrue);
        final noFollow =
            await _invoke(host, 'descriptor.stat-at', [
                  root,
                  _flags([]),
                  'link.bin',
                ])
                as WasmComponentValueData;
        final follow =
            await _invoke(host, 'descriptor.stat-at', [
                  root,
                  _flags(['symlink-follow']),
                  'link.bin',
                ])
                as WasmComponentValueData;
        expect(_stat(noFollow).items.first.label, 'symbolic-link');
        expect(_stat(noFollow).items[2].integer, BigInt.from(9));
        expect(_stat(follow).items.first.label, 'regular-file');
        expect(_stat(follow).items[2].integer, BigInt.from(100000));
      }
    },
  );

  test('matches official empty-path and default descriptor flags', () async {
    final directory = Directory.systemTemp.createTempSync('wasd-p3-paths-');
    addTearDown(() => directory.deleteSync(recursive: true));
    File('${directory.path}/a.txt').writeAsStringSync('a');
    final host = WASIPreview3NativeFilesystemHost(
      preopens: {'/': directory.path},
      canMutate: true,
    );
    final root = await _preopen(host);

    expect(
      _errorLabel(await _open(host, root, '', flags: _flags(['read']))),
      'no-entry',
    );
    for (final function in <String>[
      'descriptor.create-directory-at',
      'descriptor.remove-directory-at',
      'descriptor.unlink-file-at',
    ]) {
      expect(
        _errorLabel(
          await _invoke(host, function, [root, '']) as WasmComponentValueData,
        ),
        'no-entry',
      );
    }
    for (final function in <String>[
      'descriptor.create-directory-at',
      'descriptor.remove-directory-at',
    ]) {
      expect(
        _errorLabel(
          await _invoke(host, function, [root, '..']) as WasmComponentValueData,
        ),
        'not-permitted',
      );
    }
    for (final function in <String>[
      'descriptor.stat-at',
      'descriptor.metadata-hash-at',
    ]) {
      expect(
        _errorLabel(
          await _invoke(host, function, [root, _flags([]), ''])
              as WasmComponentValueData,
        ),
        'no-entry',
      );
    }

    final openedDirectory = _okHandle(
      await _open(host, root, '.', flags: _flags([])),
    );
    expect(await _descriptorFlags(host, openedDirectory), ['read']);

    final created = _okHandle(
      await _open(
        host,
        root,
        'created.cleanup',
        openFlags: _flags(['create', 'exclusive']),
        flags: _flags([]),
      ),
    );
    expect(await _descriptorFlags(host, created), ['read', 'write']);
  });

  test(
    'unlink preserves descriptors without requiring combined file permissions',
    () async {
      if (Platform.isWindows) {
        markTestSkipped('POSIX unlink semantics are not available on Windows.');
        return;
      }
      final directory = Directory.systemTemp.createTempSync(
        'wasd-p3-unlink-permissions-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final readable = File('${directory.path}/readable.cleanup')
        ..writeAsStringSync('readable');
      final writable = File('${directory.path}/writable.cleanup')
        ..writeAsStringSync('write');
      expect(Process.runSync('chmod', ['400', readable.path]).exitCode, 0);
      expect(Process.runSync('chmod', ['200', writable.path]).exitCode, 0);

      final host = WASIPreview3NativeFilesystemHost(
        preopens: {'/': directory.path},
        canMutate: true,
      );
      final root = await _preopen(host);
      final readHandle = _okHandle(
        await _open(host, root, 'readable.cleanup', flags: _flags(['read'])),
      );
      final writeHandle = _okHandle(
        await _open(host, root, 'writable.cleanup', flags: _flags(['write'])),
      );
      expect(
        _errorLabel(
          await _open(host, root, 'readable.cleanup', flags: _flags(['write'])),
        ),
        'access',
      );
      expect(
        _errorLabel(
          await _open(host, root, 'writable.cleanup', flags: _flags(['read'])),
        ),
        'access',
      );

      for (final path in ['readable.cleanup', 'writable.cleanup']) {
        expect(
          (await _invoke(host, 'descriptor.unlink-file-at', [root, path])
                  as WasmComponentValueData)
              .isOk,
          isTrue,
        );
      }
      expect(await _readDescriptor(host, readHandle), 'readable'.codeUnits);

      final replacement = WASIComponentStream<int>('write-only-unlinked');
      replacement.writable
        ..writeAll('XYZ'.codeUnits)
        ..close();
      final writeResult =
          await _invoke(host, 'descriptor.write-via-stream', [
                writeHandle,
                replacement,
                BigInt.one,
              ])
              as WASIComponentFuture<WasmComponentValueData>;
      expect((await writeResult.readable.readWhenReady()).isOk, isTrue);
      expect(
        (await _invoke(host, 'descriptor.set-size', [
                  writeHandle,
                  BigInt.from(4),
                ])
                as WasmComponentValueData)
            .isOk,
        isTrue,
      );
      expect(
        (await _invoke(host, 'descriptor.sync', [writeHandle])
                as WasmComponentValueData)
            .isOk,
        isTrue,
      );
      expect(
        _stat(
          await _invoke(host, 'descriptor.stat', [writeHandle])
              as WasmComponentValueData,
        ).items[2].integer,
        BigInt.from(4),
      );

      host.table.dropNamed(
        'wasi:filesystem/types@0.3.0.descriptor',
        readHandle,
      );
      host.table.dropNamed(
        'wasi:filesystem/types@0.3.0.descriptor',
        writeHandle,
      );
    },
  );

  test('rename preserves overwritten and descendant descriptors', () async {
    final directory = Directory.systemTemp.createTempSync('wasd-p3-rename-');
    addTearDown(() => directory.deleteSync(recursive: true));
    File('${directory.path}/source.txt').writeAsStringSync('new-source');
    File('${directory.path}/target.txt').writeAsStringSync('old');
    Directory('${directory.path}/old/sub').createSync(recursive: true);
    File('${directory.path}/old/sub/file.txt').writeAsStringSync('child');
    final host = WASIPreview3NativeFilesystemHost(
      preopens: {'/': directory.path},
      canMutate: true,
    );
    final root = await _preopen(host);
    int? target;
    if (!Platform.isWindows) {
      target = _okHandle(
        await _open(host, root, 'target.txt', flags: _flags(['read', 'write'])),
      );
    }
    final subdirectory = _okHandle(
      await _open(host, root, 'old/sub', flags: _flags(['read'])),
    );
    final child = _okHandle(
      await _open(
        host,
        root,
        'old/sub/file.txt',
        flags: _flags(['read', 'write']),
      ),
    );

    if (target != null) {
      expect(
        (await _invoke(host, 'descriptor.rename-at', [
                  root,
                  'source.txt',
                  root,
                  'target.txt',
                ])
                as WasmComponentValueData)
            .isOk,
        isTrue,
      );
      expect(
        File('${directory.path}/target.txt').readAsStringSync(),
        'new-source',
      );
      expect(await _readDescriptor(host, target), 'old'.codeUnits);
      expect(
        _stat(
          await _invoke(host, 'descriptor.stat', [target])
              as WasmComponentValueData,
        ).items[2].integer,
        BigInt.from(3),
      );
    }

    expect(
      (await _invoke(host, 'descriptor.rename-at', [root, 'old', root, 'new'])
              as WasmComponentValueData)
          .isOk,
      isTrue,
    );
    final childStat =
        await _invoke(host, 'descriptor.stat-at', [
              subdirectory,
              _flags([]),
              'file.txt',
            ])
            as WasmComponentValueData;
    expect(_stat(childStat).items.first.label, 'regular-file');
    expect(await _readDescriptor(host, child), 'child'.codeUnits);
    final update = WASIComponentStream<int>('renamed-child-write');
    update.writable
      ..writeAll('!'.codeUnits)
      ..close();
    final updateResult =
        await _invoke(host, 'descriptor.write-via-stream', [
              child,
              update,
              BigInt.from(5),
            ])
            as WASIComponentFuture<WasmComponentValueData>;
    expect((await updateResult.readable.readWhenReady()).isOk, isTrue);
    expect(
      File('${directory.path}/new/sub/file.txt').readAsStringSync(),
      'child!',
    );

    for (final handle in [?target, subdirectory, child]) {
      host.table.dropNamed('wasi:filesystem/types@0.3.0.descriptor', handle);
    }
  });

  test('rejects replacing or removing live directory descriptors', () async {
    final directory = Directory.systemTemp.createTempSync('wasd-p3-live-dir-');
    addTearDown(() => directory.deleteSync(recursive: true));
    Directory('${directory.path}/held').createSync();
    Directory('${directory.path}/source').createSync();
    Directory('${directory.path}/target').createSync();
    final host = WASIPreview3NativeFilesystemHost(
      preopens: {'/': directory.path},
      canMutate: true,
    );
    final root = await _preopen(host);

    final held = _okHandle(
      await _open(host, root, 'held', flags: _flags(['read'])),
    );
    expect(
      _errorLabel(
        await _invoke(host, 'descriptor.remove-directory-at', [root, 'held'])
            as WasmComponentValueData,
      ),
      'unsupported',
    );
    expect(Directory('${directory.path}/held').existsSync(), isTrue);
    host.table.dropNamed('wasi:filesystem/types@0.3.0.descriptor', held);
    expect(
      (await _invoke(host, 'descriptor.remove-directory-at', [root, 'held'])
              as WasmComponentValueData)
          .isOk,
      isTrue,
    );
    expect(
      (await _invoke(host, 'descriptor.create-directory-at', [root, 'held'])
              as WasmComponentValueData)
          .isOk,
      isTrue,
    );

    final target = _okHandle(
      await _open(host, root, 'target', flags: _flags(['read'])),
    );
    expect(
      _errorLabel(
        await _invoke(host, 'descriptor.rename-at', [
              root,
              'source',
              root,
              'target',
            ])
            as WasmComponentValueData,
      ),
      'unsupported',
    );
    expect(Directory('${directory.path}/source').existsSync(), isTrue);
    expect(Directory('${directory.path}/target').existsSync(), isTrue);
    host.table.dropNamed('wasi:filesystem/types@0.3.0.descriptor', target);
  });

  test(
    'tracks filesystem case policy without merging distinct files',
    () async {
      final directory = Directory.systemTemp.createTempSync('wasd-p3-case-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final aliased = File('${directory.path}/CaseAlias.cleanup')
        ..writeAsStringSync('alias');
      final aliasPath = '${directory.path}/casealias.cleanup';
      final caseInsensitive = File(aliasPath).existsSync();
      if (!caseInsensitive) File(aliasPath).writeAsStringSync('lower');
      final renamed = File('${directory.path}/RenameCase.cleanup')
        ..writeAsStringSync('rename');
      final host = WASIPreview3NativeFilesystemHost(
        preopens: {'/': directory.path},
        canMutate: true,
      );
      final root = await _preopen(host);

      if (!caseInsensitive) {
        final upperHandle = _okHandle(
          await _open(
            host,
            root,
            aliased.uri.pathSegments.last,
            flags: _flags(['read']),
          ),
        );
        final lowerHandle = _okHandle(
          await _open(host, root, 'casealias.cleanup', flags: _flags(['read'])),
        );
        expect(await _readDescriptor(host, upperHandle), 'alias'.codeUnits);
        expect(await _readDescriptor(host, lowerHandle), 'lower'.codeUnits);
        for (final handle in <int>[upperHandle, lowerHandle]) {
          host.table.dropNamed(
            'wasi:filesystem/types@0.3.0.descriptor',
            handle,
          );
        }
        return;
      }

      final aliasHandle = _okHandle(
        await _open(
          host,
          root,
          aliased.uri.pathSegments.last,
          flags: _flags(['read']),
        ),
      );
      final unlink =
          await _invoke(host, 'descriptor.unlink-file-at', [
                root,
                'casealias.cleanup',
              ])
              as WasmComponentValueData;
      if (Platform.isWindows) {
        expect(_errorLabel(unlink), 'unsupported');
        host.table.dropNamed(
          'wasi:filesystem/types@0.3.0.descriptor',
          aliasHandle,
        );
        expect(
          (await _invoke(host, 'descriptor.unlink-file-at', [
                    root,
                    'casealias.cleanup',
                  ])
                  as WasmComponentValueData)
              .isOk,
          isTrue,
        );
      } else {
        expect(unlink.isOk, isTrue);
        expect(await _readDescriptor(host, aliasHandle), 'alias'.codeUnits);
        host.table.dropNamed(
          'wasi:filesystem/types@0.3.0.descriptor',
          aliasHandle,
        );
      }

      final renameHandle = _okHandle(
        await _open(
          host,
          root,
          renamed.uri.pathSegments.last,
          flags: _flags(['read']),
        ),
      );
      expect(
        (await _invoke(host, 'descriptor.rename-at', [
                  root,
                  'RenameCase.cleanup',
                  root,
                  'renamecase.cleanup',
                ])
                as WasmComponentValueData)
            .isOk,
        isTrue,
      );
      expect(await _readDescriptor(host, renameHandle), 'rename'.codeUnits);
      host.table.dropNamed(
        'wasi:filesystem/types@0.3.0.descriptor',
        renameHandle,
      );
    },
  );

  test('detects case policy for an empty numeric preopen', () async {
    final parent = Directory.systemTemp.createTempSync('wasd-p3-case-root-');
    addTearDown(() => parent.deleteSync(recursive: true));
    final directory = Directory('${parent.path}/123456')..createSync();
    final host = WASIPreview3NativeFilesystemHost(
      preopens: {'/': directory.path},
      canMutate: true,
    );
    final root = await _preopen(host);
    File('${directory.path}/NumericCase.cleanup').writeAsStringSync('upper');
    final lowerPath = '${directory.path}/numericcase.cleanup';

    if (!File(lowerPath).existsSync()) {
      File(lowerPath).writeAsStringSync('lower');
      final upper = _okHandle(
        await _open(host, root, 'NumericCase.cleanup', flags: _flags(['read'])),
      );
      final lower = _okHandle(
        await _open(host, root, 'numericcase.cleanup', flags: _flags(['read'])),
      );
      expect(await _readDescriptor(host, upper), 'upper'.codeUnits);
      expect(await _readDescriptor(host, lower), 'lower'.codeUnits);
      for (final handle in <int>[upper, lower]) {
        host.table.dropNamed('wasi:filesystem/types@0.3.0.descriptor', handle);
      }
      return;
    }

    final handle = _okHandle(
      await _open(host, root, 'NumericCase.cleanup', flags: _flags(['read'])),
    );
    final unlink =
        await _invoke(host, 'descriptor.unlink-file-at', [
              root,
              'numericcase.cleanup',
            ])
            as WasmComponentValueData;
    if (Platform.isWindows) {
      expect(_errorLabel(unlink), 'unsupported');
    } else {
      expect(unlink.isOk, isTrue);
      expect(await _readDescriptor(host, handle), 'upper'.codeUnits);
    }
    host.table.dropNamed('wasi:filesystem/types@0.3.0.descriptor', handle);
  });

  test(
    'hard-link case variants do not imply a case-insensitive root',
    () async {
      if (Platform.isWindows) {
        markTestSkipped('The regression uses the POSIX ln utility.');
        return;
      }
      final directory = Directory.systemTemp.createTempSync(
        'wasd-p3-case-hardlink-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final upperProbe = File('${directory.path}/ProbeCase.cleanup')
        ..writeAsStringSync('probe');
      final lowerProbe = '${directory.path}/probeCase.cleanup';
      if (File(lowerProbe).existsSync()) {
        markTestSkipped('The temporary filesystem is case-insensitive.');
        return;
      }
      try {
        final linked = Process.runSync('ln', <String>[
          upperProbe.path,
          lowerProbe,
        ]);
        if (linked.exitCode != 0) {
          markTestSkipped(
            'The temporary filesystem does not support hard links.',
          );
          return;
        }
      } on ProcessException {
        markTestSkipped('The POSIX ln utility is unavailable.');
        return;
      }
      expect(
        FileSystemEntity.identicalSync(upperProbe.path, lowerProbe),
        isTrue,
      );

      final host = WASIPreview3NativeFilesystemHost(
        preopens: {'/': directory.path},
        canMutate: false,
      );
      final root = await _preopen(host);
      File('${directory.path}/AlphaCase.cleanup').writeAsStringSync('upper');
      File('${directory.path}/alphaCase.cleanup').writeAsStringSync('lower');

      final upper = _okHandle(
        await _open(host, root, 'AlphaCase.cleanup', flags: _flags(['read'])),
      );
      final lower = _okHandle(
        await _open(host, root, 'alphaCase.cleanup', flags: _flags(['read'])),
      );
      expect(await _readDescriptor(host, upper), 'upper'.codeUnits);
      expect(await _readDescriptor(host, lower), 'lower'.codeUnits);
      for (final handle in <int>[upper, lower]) {
        host.table.dropNamed('wasi:filesystem/types@0.3.0.descriptor', handle);
      }
    },
  );

  test('Windows rejects unlink until a live descriptor is dropped', () async {
    if (!Platform.isWindows) {
      markTestSkipped('Windows-specific delete sharing boundary.');
      return;
    }
    final directory = Directory.systemTemp.createTempSync('wasd-p3-win-fs-');
    addTearDown(() => directory.deleteSync(recursive: true));
    File('${directory.path}/open.cleanup').writeAsStringSync('open');
    final host = WASIPreview3NativeFilesystemHost(
      preopens: {'/': directory.path},
      canMutate: true,
    );
    final root = await _preopen(host);
    final handle = _okHandle(
      await _open(host, root, 'open.cleanup', flags: _flags(['read'])),
    );

    expect(
      _errorLabel(
        await _invoke(host, 'descriptor.unlink-file-at', [root, 'open.cleanup'])
            as WasmComponentValueData,
      ),
      'unsupported',
    );
    host.table.dropNamed('wasi:filesystem/types@0.3.0.descriptor', handle);
    expect(
      (await _invoke(host, 'descriptor.unlink-file-at', [root, 'open.cleanup'])
              as WasmComponentValueData)
          .isOk,
      isTrue,
    );
  });

  test(
    'rejects trailing-slash symlink traversal beyond the preopen',
    () async {
      final directory = Directory.systemTemp.createTempSync('wasd-p3-rmdir-');
      addTearDown(() => directory.deleteSync(recursive: true));
      File('${directory.path}/a.txt').writeAsStringSync('a');
      Link('${directory.path}/parent.cleanup').createSync('..');
      Link('${directory.path}/file.cleanup').createSync('a.txt');
      final host = WASIPreview3NativeFilesystemHost(
        preopens: {'/': directory.path},
        canMutate: true,
      );
      final root = await _preopen(host);

      expect(
        _errorLabel(
          await _invoke(host, 'descriptor.remove-directory-at', [
                root,
                'parent.cleanup',
              ])
              as WasmComponentValueData,
        ),
        'not-directory',
      );
      expect(
        _errorLabel(
          await _invoke(host, 'descriptor.remove-directory-at', [
                root,
                'parent.cleanup/',
              ])
              as WasmComponentValueData,
        ),
        'not-permitted',
      );
      expect(
        _errorLabel(
          await _invoke(host, 'descriptor.remove-directory-at', [
                root,
                'file.cleanup/',
              ])
              as WasmComponentValueData,
        ),
        'not-directory',
      );
      expect(
        _errorLabel(
          await _invoke(host, 'descriptor.remove-directory-at', [root, 'a.txt'])
              as WasmComponentValueData,
        ),
        'not-directory',
      );
    },
    skip: Platform.isWindows ? 'POSIX symlink semantics.' : false,
  );

  test('matches official native mutation error semantics', () async {
    final directory = Directory.systemTemp.createTempSync('wasd-p3-errors-');
    addTearDown(() => directory.deleteSync(recursive: true));
    File('${directory.path}/a.txt').writeAsStringSync('a');
    File('${directory.path}/exists.cleanup').writeAsStringSync('exists');
    File('${directory.path}/open.cleanup').writeAsStringSync('open');
    final host = WASIPreview3NativeFilesystemHost(
      preopens: {'/': directory.path},
      canMutate: true,
    );
    final root = await _preopen(host);
    final readOnly = _okHandle(
      await _open(host, root, 'a.txt', flags: _flags(['read'])),
    );

    expect(
      _errorLabel(
        await _invoke(host, 'descriptor.advise', [
              root,
              BigInt.zero,
              BigInt.zero,
              _enum('normal'),
            ])
            as WasmComponentValueData,
      ),
      'bad-descriptor',
    );
    expect(
      (await _invoke(host, 'descriptor.advise', [
                readOnly,
                BigInt.zero,
                BigInt.one,
                _enum('normal'),
              ])
              as WasmComponentValueData)
          .isOk,
      isTrue,
    );
    expect(
      _errorLabel(
        await _invoke(host, 'descriptor.set-size', [readOnly, BigInt.one])
            as WasmComponentValueData,
      ),
      'access',
    );
    expect(
      _errorLabel(
        await _invoke(host, 'descriptor.set-times', [
              readOnly,
              _variant('now'),
              _variant('no-change'),
            ])
            as WasmComponentValueData,
      ),
      'access',
    );
    expect(
      _errorLabel(
        await _invoke(host, 'descriptor.link-at', [
              root,
              _flags([]),
              '.',
              root,
              'link.cleanup',
            ])
            as WasmComponentValueData,
      ),
      'not-permitted',
    );
    expect(
      _errorLabel(
        await _invoke(host, 'descriptor.link-at', [
              root,
              _flags([]),
              'a.txt',
              root,
              'exists.cleanup',
            ])
            as WasmComponentValueData,
      ),
      'exist',
    );
    expect(
      _errorLabel(
        await _invoke(host, 'descriptor.link-at', [
              root,
              _flags([]),
              'a.txt',
              root,
              '..',
            ])
            as WasmComponentValueData,
      ),
      'not-permitted',
    );
    expect(
      (await _invoke(host, 'descriptor.rename-at', [
                root,
                'a.txt',
                root,
                'a.txt',
              ])
              as WasmComponentValueData)
          .isOk,
      isTrue,
    );

    if (!Platform.isWindows) {
      final openWritable = _okHandle(
        await _open(
          host,
          root,
          'open.cleanup',
          flags: _flags(['read', 'write']),
        ),
      );
      final openReadable = _okHandle(
        await _open(host, root, 'open.cleanup', flags: _flags(['read'])),
      );
      expect(
        (await _invoke(host, 'descriptor.unlink-file-at', [
                  root,
                  'open.cleanup',
                ])
                as WasmComponentValueData)
            .isOk,
        isTrue,
      );
      final replacement = WASIComponentStream<int>('unlinked-file-write');
      replacement.writable
        ..writeAll(<int>[9, 8])
        ..close();
      final writeResult =
          await _invoke(host, 'descriptor.write-via-stream', [
                openWritable,
                replacement,
                BigInt.one,
              ])
              as WASIComponentFuture<WasmComponentValueData>;
      expect((await writeResult.readable.readWhenReady()).isOk, isTrue);

      final read =
          await _invoke(host, 'descriptor.read-via-stream', [
                openReadable,
                BigInt.zero,
              ])
              as List<Object?>;
      final contents = <int>[];
      final stream = read[0] as WASIComponentStream<int>;
      while (true) {
        final chunk = await stream.readable.readWhenAvailable(16);
        if (chunk.isEmpty) break;
        contents.addAll(chunk);
      }
      expect(contents, <int>[111, 9, 8, 110]);
      expect(
        (await (read[1] as WASIComponentFuture<WasmComponentValueData>).readable
                .readWhenReady())
            .isOk,
        isTrue,
      );
      expect(
        (await _invoke(host, 'descriptor.set-size', [
                  openWritable,
                  BigInt.from(23),
                ])
                as WasmComponentValueData)
            .isOk,
        isTrue,
      );
      for (final handle in [openWritable, openReadable]) {
        final stat =
            await _invoke(host, 'descriptor.stat', [handle])
                as WasmComponentValueData;
        expect(_stat(stat).items[2].integer, BigInt.from(23));
      }

      expect(
        (await _invoke(host, 'descriptor.symlink-at', [
                  root,
                  'a.txt',
                  'target.cleanup',
                ])
                as WasmComponentValueData)
            .isOk,
        isTrue,
      );
      expect(
        (await _invoke(host, 'descriptor.rename-at', [
                  root,
                  'a.txt',
                  root,
                  'target.cleanup',
                ])
                as WasmComponentValueData)
            .isOk,
        isTrue,
      );
    }
  });
}

Future<List<int>> _readDescriptor(
  WASIPreview3NativeFilesystemHost host,
  int handle,
) async {
  final read =
      await _invoke(host, 'descriptor.read-via-stream', [handle, BigInt.zero])
          as List<Object?>;
  final bytes = <int>[];
  final stream = read[0] as WASIComponentStream<int>;
  while (true) {
    final chunk = await stream.readable.readWhenAvailable(16);
    if (chunk.isEmpty) break;
    bytes.addAll(chunk);
  }
  expect(
    (await (read[1] as WASIComponentFuture<WasmComponentValueData>).readable
            .readWhenReady())
        .isOk,
    isTrue,
  );
  return bytes;
}

Future<Object?> _invoke(
  WASIPreview3NativeFilesystemHost host,
  String function,
  List<Object?> args,
) async => await host.imports['wasi:filesystem/types@0.3.0.$function']!(args);

Future<int> _preopen(WASIPreview3NativeFilesystemHost host) async {
  final directories =
      await host.imports['wasi:filesystem/preopens@0.3.0.get-directories']!(
            const <Object?>[],
          )
          as WasmComponentValueData;
  return directories.items.single.items.first.integer! as int;
}

Future<WasmComponentValueData> _open(
  WASIPreview3NativeFilesystemHost host,
  int root,
  String path, {
  WasmComponentValueData? openFlags,
  required WasmComponentValueData flags,
}) async =>
    await _invoke(host, 'descriptor.open-at', [
          root,
          _flags([]),
          path,
          openFlags ?? _flags([]),
          flags,
        ])
        as WasmComponentValueData;

int _okHandle(WasmComponentValueData result) {
  expect(result.isOk, isTrue);
  return result.associatedValue!.integer! as int;
}

WasmComponentValueData _flags(List<String> labels) => WasmComponentValueData(
  kind: WasmComponentValueDataKind.flags,
  rawBytes: Uint8List(0),
  labels: labels,
);

WasmComponentValueData _stat(WasmComponentValueData result) {
  expect(result.isOk, isTrue);
  return result.associatedValue!;
}

String _errorLabel(WasmComponentValueData result) {
  expect(result.isOk, isFalse);
  return result.associatedValue!.label!;
}

Future<List<String>> _descriptorFlags(
  WASIPreview3NativeFilesystemHost host,
  int handle,
) async {
  final result =
      await _invoke(host, 'descriptor.get-flags', [handle])
          as WasmComponentValueData;
  expect(result.isOk, isTrue);
  return result.associatedValue!.labels;
}

WasmComponentValueData _enum(String label) => WasmComponentValueData(
  kind: WasmComponentValueDataKind.enumeration,
  rawBytes: Uint8List(0),
  label: label,
);

WasmComponentValueData _variant(String label) => WasmComponentValueData(
  kind: WasmComponentValueDataKind.variant,
  rawBytes: Uint8List(0),
  label: label,
);
