@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/async_values.dart';
import 'package:wasd/src/wasi/preview3/native/filesystem.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';

void main() {
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

  test('rejects trailing-slash symlink traversal beyond the preopen', () async {
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
  });

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

    final openWritable = _okHandle(
      await _open(host, root, 'open.cleanup', flags: _flags(['read', 'write'])),
    );
    final openReadable = _okHandle(
      await _open(host, root, 'open.cleanup', flags: _flags(['read'])),
    );
    expect(
      (await _invoke(host, 'descriptor.unlink-file-at', [root, 'open.cleanup'])
              as WasmComponentValueData)
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
  });
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
