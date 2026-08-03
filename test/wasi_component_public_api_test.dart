import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/wasm.dart';
import 'package:wasd/wasi.dart';

import 'support/host_fs.dart';
import 'support/public_api_sentinels.dart';
import 'support/runtime_environment.dart';

void main() {
  group('public WASI component API', () {
    test('keeps the shared native executor internal', () {
      expect(const WASIComponentNativeRuntime(), isNotNull);
    });

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

    test('creates Preview2 component hosts through the WASI facade', () {
      final host = WASI.preview2(
        args: const <String>['command.wasm', 'arg'],
        env: const <String, String>{'mode': 'test'},
        terminalStdout: true,
      );

      expect(host.profile, same(WASIComponentVersionProfile.preview2));
      expect(host.cliHost.args, ['command.wasm', 'arg']);
      expect(host.cliHost.env, {'mode': 'test'});
      expect(host.cliHost.terminalStdoutHandle, isNotNull);
      expect(
        host.standardImports,
        contains('wasi:cli/stdout@0.2.0.get-stdout'),
      );
    });

    test('creates a complete Preview3 host through the WASI facade', () {
      final host = WASI.preview3(
        args: const <String>['command.wasm', 'arg'],
        env: const <String, String>{'mode': 'test'},
      );

      expect(host.profile, same(WASIComponentVersionProfile.preview3));
      expect(host.cliHost.args, ['command.wasm', 'arg']);
      expect(host.cliHost.env, {'mode': 'test'});
      expect(host.filesystemHost.table, same(host.componentHost.table));
      expect(host.socketsHost.table, same(host.componentHost.table));
      expect(host.httpHost.table, same(host.componentHost.table));
      expect(
        host.preview2CompatibilityHost.componentHost,
        same(host.componentHost),
      );
      expect(
        host.standardImports,
        contains('wasi:filesystem/preopens@0.3.0.get-directories'),
      );
      expect(
        host.standardImports,
        contains('wasi:sockets/types@0.3.0.tcp-socket.create'),
      );
      expect(host.standardImports, contains('wasi:http/client@0.3.0.send'));
      expect(
        host.standardImports,
        contains('wasi:io/streams@0.2.0.input-stream.read'),
      );
    });

    test('exports every stable Preview3 package host', () {
      expect(WASIPreview3RandomHost(), isA<WASIPreview3RandomHost>());
      expect(WASIPreview3ClocksHost(), isA<WASIPreview3ClocksHost>());
      expect(WASIPreview3FilesystemHost(), isA<WASIPreview3FilesystemHost>());
      expect(WASIPreview3SocketsHost(), isA<WASIPreview3SocketsHost>());
      expect(WASIPreview3CliHost(), isA<WASIPreview3CliHost>());
      expect(WASIPreview3HttpHost(), isA<WASIPreview3HttpHost>());
    });

    test('keeps the native Preview3 filesystem constructor portable', () {
      final table = WASIComponentResourceTable();
      if (hasDartIoRuntime) {
        final host = WASIPreview3NativeFilesystemHost(
          preopens: const <String, String>{},
          table: table,
        );

        expect(host.table, same(table));
        return;
      }

      expect(
        () => WASIPreview3NativeFilesystemHost(
          preopens: const <String, String>{},
          table: table,
        ),
        throwsUnsupportedError,
      );
    });

    test('rejects Preview3 hosts backed by different resource tables', () {
      final componentHost = WASIComponentHost();

      expect(
        () => WASIPreview3ComponentHost(
          componentHost: componentHost,
          filesystemHost: WASIPreview3FilesystemHost(),
        ),
        throwsArgumentError,
      );
      expect(
        () => WASIPreview3ComponentHost(
          componentHost: componentHost,
          socketsHost: WASIPreview3SocketsHost(),
        ),
        throwsArgumentError,
      );
      expect(
        () => WASIPreview3ComponentHost(
          componentHost: componentHost,
          httpHost: WASIPreview3HttpHost(),
        ),
        throwsArgumentError,
      );
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

    test('binds standard Preview2 random imports from public API', () {
      const source = '''
package wasi-testsuite:test;

world random-test {
  include wasi:random/imports@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final host = WASIPreview2ComponentHost();
      final program = host.bindWitWorld(document, worldName: 'random-test');
      final bytes =
          program.invokeImport('wasi:random/random@0.2.0.get-random-bytes', [
                BigInt.from(4),
              ])
              as WasmComponentValueData;

      expect(bytes.kind, WasmComponentValueDataKind.list);
      expect(bytes.items, hasLength(4));
      expect(
        host.standardImports,
        contains('wasi:random/insecure-seed@0.2.0.insecure-seed'),
      );
    });

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

    test('binds standard Preview2 clocks imports from public API', () {
      const source = '''
package wasi-testsuite:test;

world clocks-test {
  include wasi:clocks/imports@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final host = WASIPreview2ComponentHost();
      final program = host.bindWitWorld(document, worldName: 'clocks-test');
      final now = program.invokeImport(
        'wasi:clocks/monotonic-clock@0.2.0.now',
        const [],
      );
      final wallNow =
          program.invokeImport('wasi:clocks/wall-clock@0.2.0.now', const [])
              as WasmComponentValueData;
      final handle =
          program.invokeImport(
                'wasi:clocks/monotonic-clock@0.2.0.subscribe-duration',
                [BigInt.zero],
              )
              as int;

      expect(now, isA<BigInt>());
      expect(wallNow.kind, WasmComponentValueDataKind.record);
      expect(wallNow.items, hasLength(2));
      expect(host.pollHost.table.contains(handle), isTrue);
      expect(host.clocksHost.pollHost, same(host.pollHost));
      expect(
        host.standardImports,
        contains('wasi:io/poll@0.2.0.pollable.ready'),
      );
    });

    test('binds standard Preview2 io streams imports from public API', () {
      const source = '''
package wasi-testsuite:test;

world io-test {
  include wasi:io/imports@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final host = WASIPreview2ComponentHost();
      final input = host.streamsHost.insertInputStream(
        WASIPreview2InputStream(bytes: const <int>[5, 6], closed: true),
      );
      final output = host.streamsHost.insertOutputStream();
      final program = host.bindWitWorld(document, worldName: 'io-test');
      final read =
          program.invokeImport('wasi:io/streams@0.2.0.input-stream.read', [
                input,
                BigInt.from(2),
              ])
              as WasmComponentValueData;

      program.invokeImport('wasi:io/streams@0.2.0.output-stream.check-write', [
        output,
      ]);
      final write = program.invokeImport(
        'wasi:io/streams@0.2.0.output-stream.write',
        [
          output,
          _u8ListValue([7, 8]),
        ],
      );

      expect(_u8List(_resultOk(read)), [5, 6]);
      _expectUnitOk(write as WasmComponentValueData);
      expect(host.streamsHost.outputStream(output).bytes, [7, 8]);
      expect(host.streamsHost.pollHost, same(host.pollHost));
      expect(host.streamsHost.errorHost, same(host.errorHost));
      expect(
        host.standardImports,
        contains('wasi:io/streams@0.2.0.input-stream.read'),
      );
    });

    test('binds standard Preview2 CLI imports from public API', () {
      const source = '''
package wasi-testsuite:test;

world cli-test {
  import wasi:cli/environment@0.2.0;
  import wasi:cli/stdin@0.2.0;
  import wasi:cli/stdout@0.2.0;
  import wasi:io/streams@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final host = WASIPreview2ComponentHost(
        args: const <String>['cli-env.wasm', 'a'],
        env: const <String, String>{'foo': 'bar'},
        stdinData: const <int>[65],
      );
      final program = host.bindWitWorld(document, worldName: 'cli-test');
      final args =
          program.invokeImport(
                'wasi:cli/environment@0.2.0.get-arguments',
                const [],
              )
              as WasmComponentValueData;
      final stdin =
          program.invokeImport('wasi:cli/stdin@0.2.0.get-stdin', const [])
              as int;
      final read =
          program.invokeImport('wasi:io/streams@0.2.0.input-stream.read', [
                stdin,
                BigInt.one,
              ])
              as WasmComponentValueData;
      final stdout =
          program.invokeImport('wasi:cli/stdout@0.2.0.get-stdout', const [])
              as int;

      program.invokeImport('wasi:io/streams@0.2.0.output-stream.check-write', [
        stdout,
      ]);
      final write = program.invokeImport(
        'wasi:io/streams@0.2.0.output-stream.write',
        [
          stdout,
          _u8ListValue([66]),
        ],
      );

      expect(args.kind, WasmComponentValueDataKind.list);
      expect(args.items.map((item) => item.string), ['cli-env.wasm', 'a']);
      expect(_u8List(_resultOk(read)), [65]);
      _expectUnitOk(write as WasmComponentValueData);
      expect(host.cliHost.stdoutBytes, [66]);
      expect(host.cliHost.streamsHost, same(host.streamsHost));
      expect(host.standardImports, contains('wasi:cli/stdin@0.2.0.get-stdin'));
    });

    test('binds stable WASI 0.2.12 exit-with-code from public API', () {
      const source = '''
package wasi-testsuite:test;

world cli-test {
  import wasi:cli/exit@0.2.12;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final host = WASIPreview2ComponentHost();
      final program = host.bindWitWorld(document, worldName: 'cli-test');

      expect(
        host.standardImports,
        contains('wasi:cli/exit@0.2.12.exit-with-code'),
      );
      expect(
        () => program.invokeImport(
          'wasi:cli/exit@0.2.12.exit-with-code',
          const [7],
        ),
        throwsA(
          isA<WASIPreview2Exit>()
              .having((error) => error.statusCode, 'statusCode', 7)
              .having((error) => error.isSuccess, 'isSuccess', isFalse),
        ),
      );
    });

    test('binds standard Preview2 sockets imports from public API', () async {
      const source = '''
package wasi-testsuite:test;

world sockets-test {
  include wasi:sockets/imports@0.2.0;
  include wasi:io/imports@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final host = WASIPreview2ComponentHost();
      final program = host.bindWitWorld(document, worldName: 'sockets-test');
      final network =
          program.invokeImport(
                'wasi:sockets/instance-network@0.2.0.instance-network',
                const [],
              )
              as int;
      final tcpSocket =
          program.invokeImport(
                'wasi:sockets/tcp-create-socket@0.2.0.create-tcp-socket',
                [_enumValue('ipv4')],
              )
              as WasmComponentValueData;
      final lookupStream =
          program.invokeImport(
                'wasi:sockets/ip-name-lookup@0.2.0.resolve-addresses',
                [network, '127.0.0.1'],
              )
              as WasmComponentValueData;
      final stream = _resultHandle(_resultOk(lookupStream));
      final pollable =
          program.invokeImport(
                'wasi:sockets/ip-name-lookup@0.2.0.resolve-address-stream.subscribe',
                [stream],
              )
              as int;
      await program.invokeImportAsync('wasi:io/poll@0.2.0.pollable.block', [
        pollable,
      ]);
      final firstAddress =
          program.invokeImport(
                'wasi:sockets/ip-name-lookup@0.2.0.resolve-address-stream.resolve-next-address',
                [stream],
              )
              as WasmComponentValueData;
      final localAddress =
          program.invokeImport(
                'wasi:sockets/tcp@0.2.0.tcp-socket.local-address',
                [_resultHandle(_resultOk(tcpSocket))],
              )
              as WasmComponentValueData;

      expect(_resultHandle(_resultOk(tcpSocket)), isNonZero);
      expect(_optionIpAddressLabel(_resultOk(firstAddress)), 'ipv4');
      expect(_resultErrorLabel(localAddress), 'invalid-state');
      expect(
        program.invokeImport('wasi:io/poll@0.2.0.pollable.ready', [pollable]),
        isTrue,
      );
      expect(host.socketsHost.pollHost, same(host.pollHost));
      expect(
        host.standardImports,
        contains('wasi:sockets/ip-name-lookup@0.2.0.resolve-addresses'),
      );
    });

    test('binds standard Preview2 HTTP imports from public API', () {
      const source = '''
package wasi-testsuite:test;

world http-test {
  import wasi:http/types@0.2.0;
  import wasi:http/outgoing-handler@0.2.0;
  include wasi:io/imports@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final host = WASIPreview2ComponentHost();
      final program = host.bindWitWorld(document, worldName: 'http-test');
      final fields =
          program.invokeImport(
                'wasi:http/types@0.2.0.fields.constructor',
                const [],
              )
              as int;
      final request =
          program.invokeImport(
                'wasi:http/types@0.2.0.outgoing-request.constructor',
                [fields],
              )
              as int;
      final handled =
          program.invokeImport('wasi:http/outgoing-handler@0.2.0.handle', [
                request,
                _noneValue(),
              ])
              as WasmComponentValueData;

      expect(_resultErrorLabel(handled), 'HTTP-request-URI-invalid');
      expect(host.httpHost.streamsHost, same(host.streamsHost));
      expect(
        host.standardImports,
        contains('wasi:http/outgoing-handler@0.2.0.handle'),
      );
    });

    test('creates default Preview2 native backends on Dart VM', () {
      final host = WASIPreview2ComponentHost();
      if (!hasDartIoRuntime) {
        expect(host.filesystemHost, isA<WASIPreview2FilesystemHost>());
        expect(host.socketsHost, isA<WASIPreview2SocketsHost>());
        expect(host.httpHost, isA<WASIPreview2HttpHost>());
        return;
      }

      expect(host.filesystemHost, isA<WASIPreview2NativeFilesystemHost>());
      expect(host.socketsHost, isA<WASIPreview2NativeSocketsHost>());
      expect(host.httpHost, isA<WASIPreview2NativeHttpHost>());
      expect(host.filesystemHost.streamsHost, same(host.streamsHost));
      expect(host.socketsHost.streamsHost, same(host.streamsHost));
      expect(host.httpHost.streamsHost, same(host.streamsHost));
    });

    test('creates a native Preview2 host with real Dart VM backends', () {
      if (!hasDartIoRuntime) {
        markTestSkipped('requires dart:io native backends');
        return;
      }
      final temp = createHostTemp('wasd_p2_native_host_');
      if (temp == null) {
        markTestSkipped('requires dart:io host filesystem access');
        return;
      }
      addTearDown(temp.delete);
      temp.writeFile('native.txt', 'ok');

      const source = '''
package wasi-testsuite:test;

world native-host-test {
  import wasi:cli/environment@0.2.0;
  import wasi:cli/terminal-stdin@0.2.0;
  import wasi:cli/terminal-stdout@0.2.0;
  import wasi:cli/terminal-stderr@0.2.0;
  import wasi:filesystem/preopens@0.2.0;
  import wasi:http/outgoing-handler@0.2.0;
  import wasi:io/streams@0.2.0;
  import wasi:sockets/instance-network@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final host = WASIPreview2ComponentHost.native(
        args: const <String>['component.wasm'],
        env: const <String, String>{'mode': 'native'},
        preopens: {'/': temp.path},
        canMutatePreopens: true,
        terminalStdin: true,
        terminalStdout: true,
        terminalStderr: true,
      );
      final program = host.bindWitWorld(
        document,
        worldName: 'native-host-test',
      );
      final directories =
          program.invokeImport(
                'wasi:filesystem/preopens@0.2.0.get-directories',
                const [],
              )
              as WasmComponentValueData;
      final args =
          program.invokeImport(
                'wasi:cli/environment@0.2.0.get-arguments',
                const [],
              )
              as WasmComponentValueData;
      final terminalStdin =
          program.invokeImport(
                'wasi:cli/terminal-stdin@0.2.0.get-terminal-stdin',
                const [],
              )
              as WasmComponentValueData;
      final terminalStdout =
          program.invokeImport(
                'wasi:cli/terminal-stdout@0.2.0.get-terminal-stdout',
                const [],
              )
              as WasmComponentValueData;
      final terminalStderr =
          program.invokeImport(
                'wasi:cli/terminal-stderr@0.2.0.get-terminal-stderr',
                const [],
              )
              as WasmComponentValueData;

      expect(host.filesystemHost, isA<WASIPreview2NativeFilesystemHost>());
      expect(host.socketsHost, isA<WASIPreview2NativeSocketsHost>());
      expect(host.httpHost, isA<WASIPreview2NativeHttpHost>());
      expect(host.filesystemHost.streamsHost, same(host.streamsHost));
      expect(host.socketsHost.streamsHost, same(host.streamsHost));
      expect(host.httpHost.streamsHost, same(host.streamsHost));
      expect(host.cliHost.streamsHost, same(host.streamsHost));
      expect(host.streamsHost.pollHost, same(host.pollHost));
      expect(host.streamsHost.errorHost, same(host.errorHost));
      expect(_preopenHandle(directories, '/'), isNonNegative);
      expect(args.items.map((item) => item.string), ['component.wasm']);
      expect(
        _optionHandle(terminalStdin),
        isNot(host.cliHost.terminalStdinHandle),
      );
      expect(
        _optionHandle(terminalStdout),
        isNot(host.cliHost.terminalStdoutHandle),
      );
      expect(
        _optionHandle(terminalStderr),
        isNot(host.cliHost.terminalStderrHandle),
      );
      expect(
        host.streamsHost.table.contains(_optionHandle(terminalStdin)!),
        isTrue,
      );
      expect(
        host.streamsHost.table.contains(_optionHandle(terminalStdout)!),
        isTrue,
      );
      expect(
        host.streamsHost.table.contains(_optionHandle(terminalStderr)!),
        isTrue,
      );
      expect(
        host.standardImports,
        contains('wasi:http/outgoing-handler@0.2.0.handle'),
      );
    });

    test('reports unsupported Dart VM TCP bind without fake state', () {
      if (!hasDartIoRuntime) {
        markTestSkipped('requires dart:io sockets');
        return;
      }
      const source = '''
package wasi-testsuite:test;

world sockets-test {
  include wasi:sockets/imports@0.2.0;
  include wasi:io/imports@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final sockets = WASIPreview2NativeSocketsHost();
      final host = WASIPreview2ComponentHost(socketsHost: sockets);
      final program = host.bindWitWorld(document, worldName: 'sockets-test');
      final network =
          program.invokeImport(
                'wasi:sockets/instance-network@0.2.0.instance-network',
                const [],
              )
              as int;
      final socket = _resultHandle(
        _resultOk(
          program.invokeImport(
                'wasi:sockets/tcp-create-socket@0.2.0.create-tcp-socket',
                [_enumValue('ipv4')],
              )
              as WasmComponentValueData,
        ),
      );

      final bind =
          program.invokeImport('wasi:sockets/tcp@0.2.0.tcp-socket.start-bind', [
                socket,
                network,
                _ipv4SocketAddressValue(port: 0),
              ])
              as WasmComponentValueData;

      expect(_resultErrorLabel(bind), 'not-supported');
      expect(sockets.streamsHost, same(host.streamsHost));
    });

    test('binds Preview2 filesystem imports to real host files on Dart VM', () {
      if (!hasDartIoRuntime) {
        markTestSkipped('requires dart:io host filesystem access');
        return;
      }
      final temp = createHostTemp('wasd_p2_host_fs_');
      if (temp == null) {
        markTestSkipped('requires dart:io host filesystem access');
        return;
      }
      addTearDown(temp.delete);
      temp.writeFile('note.txt', 'hello');

      const source = '''
package wasi-testsuite:test;

world filesystem-test {
  include wasi:filesystem/imports@0.2.0;
  include wasi:io/imports@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final filesystem = WASIPreview2NativeFilesystemHost(
        preopens: {'/': temp.path},
        canMutate: true,
      );
      final host = WASIPreview2ComponentHost(filesystemHost: filesystem);
      final program = host.bindWitWorld(document, worldName: 'filesystem-test');
      final directories =
          program.invokeImport(
                'wasi:filesystem/preopens@0.2.0.get-directories',
                const [],
              )
              as WasmComponentValueData;
      final root = _preopenHandle(directories, '/');
      final opened =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.open-at',
                [
                  root,
                  _flagsValue(const <String>[]),
                  'note.txt',
                  _flagsValue(const <String>[]),
                  _flagsValue(const <String>[
                    'read',
                    'write',
                    'file-integrity-sync',
                  ]),
                ],
              )
              as WasmComponentValueData;
      final file = _resultHandle(_resultOk(opened));
      final descriptorFlags =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.get-flags',
                [file],
              )
              as WasmComponentValueData;
      final read =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.read-via-stream',
                [file, BigInt.one],
              )
              as WasmComponentValueData;
      final input = _resultHandle(_resultOk(read));
      final inputBytes =
          program.invokeImport('wasi:io/streams@0.2.0.input-stream.read', [
                input,
                BigInt.from(8),
              ])
              as WasmComponentValueData;
      final write =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.write-via-stream',
                [file, BigInt.from(1)],
              )
              as WasmComponentValueData;
      final output = _resultHandle(_resultOk(write));

      program.invokeImport('wasi:io/streams@0.2.0.output-stream.check-write', [
        output,
      ]);
      _expectUnitOk(
        program.invokeImport('wasi:io/streams@0.2.0.output-stream.write', [
              output,
              _u8ListValue([88, 89]),
            ])
            as WasmComponentValueData,
      );
      _expectUnitOk(
        program.invokeImport(
              'wasi:filesystem/types@0.2.0.descriptor.sync-data',
              [file],
            )
            as WasmComponentValueData,
      );
      _expectUnitOk(
        program.invokeImport('wasi:filesystem/types@0.2.0.descriptor.sync', [
              file,
            ])
            as WasmComponentValueData,
      );

      expect(_u8List(_resultOk(inputBytes)), [101, 108, 108, 111]);
      expect(_resultOk(descriptorFlags).labels, [
        'read',
        'write',
        'file-integrity-sync',
      ]);
      expect(temp.readFile('note.txt'), 'hXYlo');
      expect(host.filesystemHost, same(filesystem));
      expect(
        host.standardImports,
        contains('wasi:filesystem/types@0.2.0.descriptor.open-at'),
      );
    });

    test('mutates Preview2 filesystem real host files on Dart VM', () {
      if (!hasDartIoRuntime) {
        markTestSkipped('requires dart:io host filesystem access');
        return;
      }
      final temp = createHostTemp('wasd_p2_host_mutate_');
      if (temp == null) {
        markTestSkipped('requires dart:io host filesystem access');
        return;
      }
      addTearDown(temp.delete);
      temp.writeFile('note.txt', 'hello');

      const source = '''
package wasi-testsuite:test;

world filesystem-test {
  include wasi:filesystem/imports@0.2.0;
  include wasi:io/imports@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final host = WASIPreview2ComponentHost(
        filesystemHost: WASIPreview2NativeFilesystemHost(
          preopens: {'/': temp.path},
          canMutate: true,
        ),
      );
      final program = host.bindWitWorld(document, worldName: 'filesystem-test');
      final directories =
          program.invokeImport(
                'wasi:filesystem/preopens@0.2.0.get-directories',
                const [],
              )
              as WasmComponentValueData;
      final root = _preopenHandle(directories, '/');
      final opened =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.open-at',
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

      final write =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.write-via-stream',
                [file, BigInt.from(1)],
              )
              as WasmComponentValueData;
      final output = _resultHandle(_resultOk(write));
      program.invokeImport('wasi:io/streams@0.2.0.output-stream.check-write', [
        output,
      ]);
      _expectUnitOk(
        program.invokeImport('wasi:io/streams@0.2.0.output-stream.write', [
              output,
              _u8ListValue([88, 89]),
            ])
            as WasmComponentValueData,
      );
      expect(temp.readFile('note.txt'), 'hXYlo');

      final append =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.append-via-stream',
                [file],
              )
              as WasmComponentValueData;
      final appendOutput = _resultHandle(_resultOk(append));
      program.invokeImport('wasi:io/streams@0.2.0.output-stream.check-write', [
        appendOutput,
      ]);
      _expectUnitOk(
        program.invokeImport('wasi:io/streams@0.2.0.output-stream.write', [
              appendOutput,
              _u8ListValue([33]),
            ])
            as WasmComponentValueData,
      );
      expect(temp.readFile('note.txt'), 'hXYlo!');

      _expectUnitOk(
        program.invokeImport(
              'wasi:filesystem/types@0.2.0.descriptor.set-size',
              [file, BigInt.from(3)],
            )
            as WasmComponentValueData,
      );
      expect(temp.readFile('note.txt'), 'hXY');

      _expectUnitOk(
        program.invokeImport(
              'wasi:filesystem/types@0.2.0.descriptor.create-directory-at',
              [root, 'created'],
            )
            as WasmComponentValueData,
      );
      expect(temp.directoryExists('created'), isTrue);

      final created =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.open-at',
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
      final createdWrite =
          program.invokeImport('wasi:filesystem/types@0.2.0.descriptor.write', [
                createdFile,
                _u8ListValue([110, 101, 119]),
                BigInt.zero,
              ])
              as WasmComponentValueData;
      expect(_integerBigInt(_resultOk(createdWrite).integer), BigInt.from(3));
      expect(temp.readFile('created.txt'), 'new');

      _expectUnitOk(
        program.invokeImport(
              'wasi:filesystem/types@0.2.0.descriptor.unlink-file-at',
              [root, 'note.txt'],
            )
            as WasmComponentValueData,
      );
      expect(temp.fileExists('note.txt'), isFalse);

      _expectUnitOk(
        program.invokeImport(
              'wasi:filesystem/types@0.2.0.descriptor.unlink-file-at',
              [root, 'created.txt'],
            )
            as WasmComponentValueData,
      );
      expect(temp.fileExists('created.txt'), isFalse);

      _expectUnitOk(
        program.invokeImport(
              'wasi:filesystem/types@0.2.0.descriptor.remove-directory-at',
              [root, 'created'],
            )
            as WasmComponentValueData,
      );
      expect(temp.directoryExists('created'), isFalse);
    });

    test('sets Preview2 filesystem real host timestamps on Dart VM', () {
      if (!hasDartIoRuntime) {
        markTestSkipped('requires dart:io host filesystem access');
        return;
      }
      final temp = createHostTemp('wasd_p2_host_times_');
      if (temp == null) {
        markTestSkipped('requires dart:io host filesystem access');
        return;
      }
      addTearDown(temp.delete);
      temp.writeFile('timed.txt', 'time');
      temp.createDirectory('timed-dir');

      const source = '''
package wasi-testsuite:test;

world filesystem-test {
  include wasi:filesystem/imports@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final host = WASIPreview2ComponentHost(
        filesystemHost: WASIPreview2NativeFilesystemHost(
          preopens: {'/': temp.path},
          canMutate: true,
        ),
      );
      final program = host.bindWitWorld(document, worldName: 'filesystem-test');
      final directories =
          program.invokeImport(
                'wasi:filesystem/preopens@0.2.0.get-directories',
                const [],
              )
              as WasmComponentValueData;
      final root = _preopenHandle(directories, '/');
      final opened =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.open-at',
                [
                  root,
                  _flagsValue(const <String>[]),
                  'timed.txt',
                  _flagsValue(const <String>[]),
                  _flagsValue(const <String>['read', 'write']),
                ],
              )
              as WasmComponentValueData;
      final file = _resultHandle(_resultOk(opened));

      final fileAccess = _timestampNanos(1700000000, 123000000);
      final fileModification = _timestampNanos(1700000001, 456000000);
      _expectUnitOk(
        program.invokeImport(
              'wasi:filesystem/types@0.2.0.descriptor.set-times',
              [
                file,
                _timestampValue(1700000000, 123000000),
                _timestampValue(1700000001, 456000000),
              ],
            )
            as WasmComponentValueData,
      );
      expect(temp.fileTimes('timed.txt'), (
        accessTimeNanos: fileAccess,
        modificationTimeNanos: fileModification,
      ));
      final fileStat =
          program.invokeImport('wasi:filesystem/types@0.2.0.descriptor.stat', [
                file,
              ])
              as WasmComponentValueData;
      expect(_descriptorAccessTimeNanos(_resultOk(fileStat)), fileAccess);
      expect(
        _descriptorModificationTimeNanos(_resultOk(fileStat)),
        fileModification,
      );

      final directoryAccess = _timestampNanos(1700000002, 111000000);
      final directoryModification = _timestampNanos(1700000003, 333000000);
      _expectUnitOk(
        program.invokeImport(
              'wasi:filesystem/types@0.2.0.descriptor.set-times-at',
              [
                root,
                _flagsValue(const <String>[]),
                'timed-dir',
                _timestampValue(1700000002, 111000000),
                _timestampValue(1700000003, 333000000),
              ],
            )
            as WasmComponentValueData,
      );
      expect(temp.directoryTimes('timed-dir'), (
        accessTimeNanos: directoryAccess,
        modificationTimeNanos: directoryModification,
      ));
      final directoryStat =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.stat-at',
                [root, _flagsValue(const <String>[]), 'timed-dir'],
              )
              as WasmComponentValueData;
      expect(
        _descriptorAccessTimeNanos(_resultOk(directoryStat)),
        directoryAccess,
      );
      expect(
        _descriptorModificationTimeNanos(_resultOk(directoryStat)),
        directoryModification,
      );
    });

    test('links and renames Preview2 filesystem real host paths', () {
      if (!hasDartIoRuntime) {
        markTestSkipped('requires dart:io host filesystem access');
        return;
      }
      final temp = createHostTemp('wasd_p2_host_links_');
      if (temp == null) {
        markTestSkipped('requires dart:io host filesystem access');
        return;
      }
      addTearDown(temp.delete);
      temp.writeFile('source.txt', 'source');

      const source = '''
package wasi-testsuite:test;

world filesystem-test {
  include wasi:filesystem/imports@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final host = WASIPreview2ComponentHost(
        filesystemHost: WASIPreview2NativeFilesystemHost(
          preopens: {'/': temp.path},
          canMutate: true,
        ),
      );
      final program = host.bindWitWorld(document, worldName: 'filesystem-test');
      final directories =
          program.invokeImport(
                'wasi:filesystem/preopens@0.2.0.get-directories',
                const [],
              )
              as WasmComponentValueData;
      final root = _preopenHandle(directories, '/');

      _expectUnitOk(
        program.invokeImport('wasi:filesystem/types@0.2.0.descriptor.link-at', [
              root,
              _flagsValue(const <String>[]),
              'source.txt',
              root,
              'hard.txt',
            ])
            as WasmComponentValueData,
      );
      expect(temp.readFile('hard.txt'), 'source');

      final sourceFile =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.open-at',
                [
                  root,
                  _flagsValue(const <String>[]),
                  'source.txt',
                  _flagsValue(const <String>[]),
                  _flagsValue(const <String>['read']),
                ],
              )
              as WasmComponentValueData;
      final hardFile =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.open-at',
                [
                  root,
                  _flagsValue(const <String>[]),
                  'hard.txt',
                  _flagsValue(const <String>[]),
                  _flagsValue(const <String>['read']),
                ],
              )
              as WasmComponentValueData;
      expect(
        program.invokeImport(
          'wasi:filesystem/types@0.2.0.descriptor.is-same-object',
          [
            _resultHandle(_resultOk(sourceFile)),
            _resultHandle(_resultOk(hardFile)),
          ],
        ),
        isTrue,
      );

      temp.writeFile('source.txt', 'changed');
      expect(temp.readFile('hard.txt'), 'changed');

      _expectUnitOk(
        program.invokeImport(
              'wasi:filesystem/types@0.2.0.descriptor.rename-at',
              [root, 'hard.txt', root, 'renamed.txt'],
            )
            as WasmComponentValueData,
      );
      expect(temp.fileExists('hard.txt'), isFalse);
      expect(temp.readFile('renamed.txt'), 'changed');

      // Windows symlink creation may require elevated privileges, and link
      // sizes do not have the POSIX byte-length contract checked below.
      if (!temp.path.startsWith('/')) {
        return;
      }

      _expectUnitOk(
        program.invokeImport(
              'wasi:filesystem/types@0.2.0.descriptor.symlink-at',
              [root, 'source.txt', 'link.txt'],
            )
            as WasmComponentValueData,
      );
      expect(temp.symlinkExists('link.txt'), isTrue);
      expect(temp.readLink('link.txt'), 'source.txt');
      temp.createSymlink('目标', 'dangling.txt');

      final readlink =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.readlink-at',
                [root, 'link.txt'],
              )
              as WasmComponentValueData;
      expect(_resultOk(readlink).string, 'source.txt');
      final danglingReadlink =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.readlink-at',
                [root, 'dangling.txt'],
              )
              as WasmComponentValueData;
      expect(_resultOk(danglingReadlink).string, '目标');

      final linkStat =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.stat-at',
                [root, _flagsValue(const <String>[]), 'link.txt'],
              )
              as WasmComponentValueData;
      final danglingStat =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.stat-at',
                [root, _flagsValue(const <String>[]), 'dangling.txt'],
              )
              as WasmComponentValueData;
      expect(_descriptorSize(_resultOk(linkStat)), BigInt.from(10));
      expect(_descriptorSize(_resultOk(danglingStat)), BigInt.from(6));

      final link = _resultHandle(
        _resultOk(
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.open-at',
                [
                  root,
                  _flagsValue(const <String>[]),
                  'link.txt',
                  _flagsValue(const <String>[]),
                  _flagsValue(const <String>['read']),
                ],
              )
              as WasmComponentValueData,
        ),
      );
      final followed = _resultHandle(
        _resultOk(
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.open-at',
                [
                  root,
                  _flagsValue(const <String>['symlink-follow']),
                  'link.txt',
                  _flagsValue(const <String>[]),
                  _flagsValue(const <String>['read']),
                ],
              )
              as WasmComponentValueData,
        ),
      );
      final linkType =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.get-type',
                [link],
              )
              as WasmComponentValueData;
      final followedType =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.get-type',
                [followed],
              )
              as WasmComponentValueData;
      final followedRead =
          program.invokeImport('wasi:filesystem/types@0.2.0.descriptor.read', [
                followed,
                BigInt.from(16),
                BigInt.zero,
              ])
              as WasmComponentValueData;

      expect(_caseLabel(_resultOk(linkType)), 'symbolic-link');
      expect(_caseLabel(_resultOk(followedType)), 'regular-file');
      expect(_u8List(_resultOk(followedRead).items[0]), 'changed'.codeUnits);
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

    test('sets Preview3 filesystem real host timestamps on Dart VM', () async {
      if (!hasDartIoRuntime) {
        markTestSkipped('requires dart:io host filesystem access');
        return;
      }
      final temp = createHostTemp('wasd_p3_host_times_');
      if (temp == null) {
        markTestSkipped('requires dart:io host filesystem access');
        return;
      }
      addTearDown(temp.delete);
      temp.writeFile('timed.txt', 'time');
      temp.createDirectory('timed-dir');

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
                  'timed.txt',
                  _flagsValue(const <String>[]),
                  _flagsValue(const <String>['read', 'write']),
                ],
              )
              as WasmComponentValueData;
      final file = _resultHandle(_resultOk(opened));

      final fileAccess = _timestampNanos(1700000000, 123000000);
      final fileModification = _timestampNanos(1700000001, 456000000);
      final fileTimes =
          await program.invokeImportAsync(
                'wasi:filesystem/types@0.3.0.descriptor.set-times',
                [
                  file,
                  _timestampValue(1700000000, 123000000),
                  _timestampValue(1700000001, 456000000),
                ],
              )
              as WasmComponentValueData;
      _expectUnitOk(fileTimes);
      expect(temp.fileTimes('timed.txt'), (
        accessTimeNanos: fileAccess,
        modificationTimeNanos: fileModification,
      ));
      final fileStat =
          await program.invokeImportAsync(
                'wasi:filesystem/types@0.3.0.descriptor.stat',
                [file],
              )
              as WasmComponentValueData;
      expect(_descriptorAccessTimeNanos(_resultOk(fileStat)), fileAccess);
      expect(
        _descriptorModificationTimeNanos(_resultOk(fileStat)),
        fileModification,
      );

      final directoryAccess = _timestampNanos(1700000002, 111000000);
      final directoryModification = _timestampNanos(1700000003, 333000000);
      final directoryTimes =
          await program.invokeImportAsync(
                'wasi:filesystem/types@0.3.0.descriptor.set-times-at',
                [
                  root,
                  _flagsValue(const <String>[]),
                  'timed-dir',
                  _timestampValue(1700000002, 111000000),
                  _timestampValue(1700000003, 333000000),
                ],
              )
              as WasmComponentValueData;
      _expectUnitOk(directoryTimes);
      expect(temp.directoryTimes('timed-dir'), (
        accessTimeNanos: directoryAccess,
        modificationTimeNanos: directoryModification,
      ));
      final directoryStat =
          await program.invokeImportAsync(
                'wasi:filesystem/types@0.3.0.descriptor.stat-at',
                [root, _flagsValue(const <String>[]), 'timed-dir'],
              )
              as WasmComponentValueData;
      expect(
        _descriptorAccessTimeNanos(_resultOk(directoryStat)),
        directoryAccess,
      );
      expect(
        _descriptorModificationTimeNanos(_resultOk(directoryStat)),
        directoryModification,
      );
    });

    test('links and renames Preview3 filesystem real host paths', () async {
      if (!hasDartIoRuntime) {
        markTestSkipped('requires dart:io host filesystem access');
        return;
      }
      final temp = createHostTemp('wasd_p3_host_links_');
      if (temp == null) {
        markTestSkipped('requires dart:io host filesystem access');
        return;
      }
      addTearDown(temp.delete);
      temp.writeFile('source.txt', 'source');

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

      final link =
          await program.invokeImportAsync(
                'wasi:filesystem/types@0.3.0.descriptor.link-at',
                [
                  root,
                  _flagsValue(const <String>[]),
                  'source.txt',
                  root,
                  'hard.txt',
                ],
              )
              as WasmComponentValueData;
      _expectUnitOk(link);
      expect(temp.readFile('hard.txt'), 'source');

      final sourceFile =
          await program.invokeImportAsync(
                'wasi:filesystem/types@0.3.0.descriptor.open-at',
                [
                  root,
                  _flagsValue(const <String>[]),
                  'source.txt',
                  _flagsValue(const <String>[]),
                  _flagsValue(const <String>['read']),
                ],
              )
              as WasmComponentValueData;
      final hardFile =
          await program.invokeImportAsync(
                'wasi:filesystem/types@0.3.0.descriptor.open-at',
                [
                  root,
                  _flagsValue(const <String>[]),
                  'hard.txt',
                  _flagsValue(const <String>[]),
                  _flagsValue(const <String>['read']),
                ],
              )
              as WasmComponentValueData;
      expect(
        await program.invokeImportAsync(
          'wasi:filesystem/types@0.3.0.descriptor.is-same-object',
          [
            _resultHandle(_resultOk(sourceFile)),
            _resultHandle(_resultOk(hardFile)),
          ],
        ),
        isTrue,
      );

      temp.writeFile('source.txt', 'changed');
      expect(temp.readFile('hard.txt'), 'changed');

      final rename =
          await program.invokeImportAsync(
                'wasi:filesystem/types@0.3.0.descriptor.rename-at',
                [root, 'hard.txt', root, 'renamed.txt'],
              )
              as WasmComponentValueData;
      _expectUnitOk(rename);
      expect(temp.fileExists('hard.txt'), isFalse);
      expect(temp.readFile('renamed.txt'), 'changed');

      final symlink =
          await program.invokeImportAsync(
                'wasi:filesystem/types@0.3.0.descriptor.symlink-at',
                [root, 'source.txt', 'link.txt'],
              )
              as WasmComponentValueData;
      _expectUnitOk(symlink);
      expect(temp.symlinkExists('link.txt'), isTrue);
      expect(temp.readLink('link.txt'), 'source.txt');

      final readlink =
          await program.invokeImportAsync(
                'wasi:filesystem/types@0.3.0.descriptor.readlink-at',
                [root, 'link.txt'],
              )
              as WasmComponentValueData;
      expect(_resultOk(readlink).string, 'source.txt');

      final directoryRead =
          program.invokeImport(
                'wasi:filesystem/types@0.3.0.descriptor.read-directory',
                [root],
              )
              as List<Object?>;
      final entries =
          directoryRead[0] as WASIComponentStream<WasmComponentValueData>;
      expect(
        entries.readable.read(8).map(_directoryEntryName),
        containsAll(<String>['source.txt', 'renamed.txt', 'link.txt']),
      );
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

int? _optionHandle(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.option) {
    throw StateError('expected option<resource>');
  }
  final isSome = value.isSome ?? value.index == 1 || value.label == 'some';
  if (!isSome) {
    return null;
  }
  final associated = value.associatedValue;
  if (associated == null) {
    throw StateError('expected option resource payload');
  }
  return _resultHandle(associated);
}

String _resultErrorLabel(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.result ||
      (value.isOk ?? value.index == 0 || value.label == 'ok') ||
      value.associatedValue == null) {
    throw StateError('expected error result');
  }
  return _caseLabel(value.associatedValue!);
}

String _caseLabel(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.variant &&
      value.kind != WasmComponentValueDataKind.enumeration) {
    throw StateError('expected case value');
  }
  return value.label ?? 'case-${value.index}';
}

String? _optionIpAddressLabel(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.option) {
    throw StateError('expected option<ip-address>');
  }
  if (!(value.isSome ?? value.index == 1 || value.label == 'some')) {
    return null;
  }
  final associated = value.associatedValue;
  if (associated == null) {
    throw StateError('expected ip-address payload');
  }
  return _caseLabel(associated);
}

List<int> _u8List(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.list) {
    throw StateError('expected list<u8>');
  }
  return [
    for (final item in value.items)
      if (item.kind == WasmComponentValueDataKind.integer)
        item.integer as int
      else
        throw StateError('expected u8 item'),
  ];
}

WasmComponentValueData _u8ListValue(List<int> bytes) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    items: [
      for (final byte in bytes)
        WasmComponentValueData(
          kind: WasmComponentValueDataKind.integer,
          rawBytes: Uint8List(0),
          integer: byte,
        ),
    ],
  );
}

WasmComponentValueData _enumValue(String label) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.enumeration,
    rawBytes: Uint8List(0),
    label: label,
  );
}

WasmComponentValueData _noneValue() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'none',
  );
}

void _expectUnitOk(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.result ||
      !(value.isOk ?? value.index == 0 || value.label == 'ok')) {
    throw StateError('expected ok result');
  }
}

WasmComponentValueData _ipv4SocketAddressValue({
  required int port,
  int a = 127,
  int b = 0,
  int c = 0,
  int d = 1,
}) {
  return _variantValue(
    'ipv4',
    _recordValue([
      _integerValue(port),
      _tupleValue([
        _integerValue(a),
        _integerValue(b),
        _integerValue(c),
        _integerValue(d),
      ]),
    ]),
  );
}

WasmComponentValueData _variantValue(
  String label, [
  WasmComponentValueData? associatedValue,
]) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.variant,
    rawBytes: Uint8List(0),
    index: label == 'ipv6' ? 1 : 0,
    label: label,
    associatedValue: associatedValue,
  );
}

WasmComponentValueData _recordValue(List<WasmComponentValueData> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.record,
    rawBytes: Uint8List(0),
    items: items,
  );
}

WasmComponentValueData _tupleValue(List<WasmComponentValueData> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.tuple,
    rawBytes: Uint8List(0),
    items: items,
  );
}

WasmComponentValueData _integerValue(Object value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.integer,
    rawBytes: Uint8List(0),
    integer: value,
  );
}

int _descriptorAccessTimeNanos(WasmComponentValueData value) {
  return _descriptorTimestampNanos(value, 3);
}

BigInt _descriptorSize(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.record ||
      value.items.length != 6) {
    throw StateError('expected descriptor-stat');
  }
  final size = _integerBigInt(value.items[2].integer);
  if (size == null) {
    throw StateError('expected descriptor size');
  }
  return size;
}

int _descriptorModificationTimeNanos(WasmComponentValueData value) {
  return _descriptorTimestampNanos(value, 4);
}

int _descriptorTimestampNanos(WasmComponentValueData value, int index) {
  if (value.kind != WasmComponentValueDataKind.record ||
      value.items.length != 6) {
    throw StateError('expected descriptor-stat');
  }
  final option = value.items[index];
  if (option.kind != WasmComponentValueDataKind.option ||
      !(option.isSome ?? option.index == 1 || option.label == 'some') ||
      option.associatedValue == null) {
    throw StateError('expected descriptor timestamp');
  }
  final instant = option.associatedValue!;
  if (instant.kind != WasmComponentValueDataKind.record ||
      instant.items.length != 2) {
    throw StateError('expected instant');
  }
  final seconds = _integerBigInt(instant.items[0].integer);
  final nanoseconds = _integerBigInt(instant.items[1].integer);
  if (seconds == null || nanoseconds == null) {
    throw StateError('expected instant integers');
  }
  return (seconds * BigInt.from(1000000000) + nanoseconds).toInt();
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

WasmComponentValueData _timestampValue(int seconds, int nanoseconds) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.variant,
    rawBytes: Uint8List(0),
    index: 2,
    label: 'timestamp',
    associatedValue: WasmComponentValueData(
      kind: WasmComponentValueDataKind.record,
      rawBytes: Uint8List(0),
      items: [
        WasmComponentValueData(
          kind: WasmComponentValueDataKind.integer,
          rawBytes: Uint8List(0),
          integer: BigInt.from(seconds),
        ),
        WasmComponentValueData(
          kind: WasmComponentValueDataKind.integer,
          rawBytes: Uint8List(0),
          integer: nanoseconds,
        ),
      ],
    ),
  );
}

int _timestampNanos(int seconds, int nanoseconds) =>
    seconds * 1000000000 + nanoseconds;

BigInt? _integerBigInt(Object? integer) {
  return switch (integer) {
    BigInt() => integer,
    int() => BigInt.from(integer),
    _ => null,
  };
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
