import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/async_values.dart';
import 'package:wasd/src/wasi/component/versioned_host.dart';
import 'package:wasd/src/wasi/component/wit_document.dart';
import 'package:wasd/src/wasi/preview3/native/sockets.dart';
import 'package:wasd/src/wasi/preview3/native/socket_options.dart';
import 'package:wasd/src/wasi/preview3/sockets.dart';
import 'package:wasd/src/wasi/version.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/imports.dart'
    as native_imports;
import 'package:wasd/src/wasm/backend/native/interpreter/instance.dart'
    as native_instance;

const List<int> _syncImportModuleBytes = <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x05,
  0x01,
  0x60,
  0x00,
  0x01,
  0x7f,
  0x02,
  0x07,
  0x01,
  0x01,
  0x6d,
  0x01,
  0x66,
  0x00,
  0x00,
  0x03,
  0x02,
  0x01,
  0x00,
  0x07,
  0x07,
  0x01,
  0x03,
  0x72,
  0x75,
  0x6e,
  0x00,
  0x01,
  0x0a,
  0x06,
  0x01,
  0x04,
  0x00,
  0x10,
  0x00,
  0x0b,
];

const String _socketsWorld = '''
package wasd-tests:sockets;

world test {
  include wasi:sockets/imports@0.3.0;
}
''';

void main() {
  group('WASI Preview3 sockets host', () {
    test('covers every stable types and ip-name-lookup function', () {
      final host = WASIPreview3SocketsHost();

      expect(host.imports, hasLength(41));
      expect(
        host.imports.keys,
        containsAll(<String>[
          'wasi:sockets/types@0.3.0.tcp-socket.create',
          'wasi:sockets/types@0.3.0.tcp-socket.bind',
          'wasi:sockets/types@0.3.0.tcp-socket.connect',
          'wasi:sockets/types@0.3.0.tcp-socket.listen',
          'wasi:sockets/types@0.3.0.tcp-socket.send',
          'wasi:sockets/types@0.3.0.tcp-socket.receive',
          'wasi:sockets/types@0.3.0.tcp-socket.get-local-address',
          'wasi:sockets/types@0.3.0.tcp-socket.get-remote-address',
          'wasi:sockets/types@0.3.0.tcp-socket.get-is-listening',
          'wasi:sockets/types@0.3.0.tcp-socket.get-address-family',
          'wasi:sockets/types@0.3.0.tcp-socket.set-listen-backlog-size',
          'wasi:sockets/types@0.3.0.tcp-socket.get-keep-alive-enabled',
          'wasi:sockets/types@0.3.0.tcp-socket.set-keep-alive-enabled',
          'wasi:sockets/types@0.3.0.tcp-socket.get-keep-alive-idle-time',
          'wasi:sockets/types@0.3.0.tcp-socket.set-keep-alive-idle-time',
          'wasi:sockets/types@0.3.0.tcp-socket.get-keep-alive-interval',
          'wasi:sockets/types@0.3.0.tcp-socket.set-keep-alive-interval',
          'wasi:sockets/types@0.3.0.tcp-socket.get-keep-alive-count',
          'wasi:sockets/types@0.3.0.tcp-socket.set-keep-alive-count',
          'wasi:sockets/types@0.3.0.tcp-socket.get-hop-limit',
          'wasi:sockets/types@0.3.0.tcp-socket.set-hop-limit',
          'wasi:sockets/types@0.3.0.tcp-socket.get-receive-buffer-size',
          'wasi:sockets/types@0.3.0.tcp-socket.set-receive-buffer-size',
          'wasi:sockets/types@0.3.0.tcp-socket.get-send-buffer-size',
          'wasi:sockets/types@0.3.0.tcp-socket.set-send-buffer-size',
          'wasi:sockets/types@0.3.0.udp-socket.create',
          'wasi:sockets/types@0.3.0.udp-socket.bind',
          'wasi:sockets/types@0.3.0.udp-socket.connect',
          'wasi:sockets/types@0.3.0.udp-socket.disconnect',
          'wasi:sockets/types@0.3.0.udp-socket.send',
          'wasi:sockets/types@0.3.0.udp-socket.receive',
          'wasi:sockets/types@0.3.0.udp-socket.get-local-address',
          'wasi:sockets/types@0.3.0.udp-socket.get-remote-address',
          'wasi:sockets/types@0.3.0.udp-socket.get-address-family',
          'wasi:sockets/types@0.3.0.udp-socket.get-unicast-hop-limit',
          'wasi:sockets/types@0.3.0.udp-socket.set-unicast-hop-limit',
          'wasi:sockets/types@0.3.0.udp-socket.get-receive-buffer-size',
          'wasi:sockets/types@0.3.0.udp-socket.set-receive-buffer-size',
          'wasi:sockets/types@0.3.0.udp-socket.get-send-buffer-size',
          'wasi:sockets/types@0.3.0.udp-socket.set-send-buffer-size',
          'wasi:sockets/ip-name-lookup@0.3.0.resolve-addresses',
        ]),
      );
    });

    test('binds the complete stable sockets WIT world', () {
      final host = WASIPreview3SocketsHost(backend: _FakeSocketsBackend());
      final document = WASIComponentWitDocument.parse(_socketsWorld);
      final versioned = WASIComponentVersionedHost(
        version: WASIVersion.preview3,
      );
      final plan = versioned.prepareWitWorld(document, worldName: 'test');

      expect(plan.canIngest, isTrue);
      expect(plan.canBindAdapters, isTrue);
      expect(plan.bindingErrors, isEmpty);
      expect(plan.functions, hasLength(41));
      final program = versioned.bindWitWorld(
        document,
        worldName: 'test',
        imports: host.imports,
      );
      final socket = _resource(
        program.invokeImport(
              'wasi:sockets/types@0.3.0.tcp-socket.create',
              <Object?>[_family('ipv4')],
            )
            as WasmComponentValueData,
      );
      final listened =
          program.invokeImport(
                'wasi:sockets/types@0.3.0.tcp-socket.listen',
                <Object?>[socket],
              )
              as WasmComponentValueData;
      final stream = _okValue(listened) as WASIComponentStream<int>;

      host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', socket);
      stream.readable.drop();
      stream.writable.drop();
    });

    test('creates, binds, and reports TCP addresses and options', () {
      final backend = _FakeSocketsBackend();
      final host = WASIPreview3SocketsHost(backend: backend);
      final imports = host.imports;
      final tcp = _resource(
        imports['wasi:sockets/types@0.3.0.tcp-socket.create']!(<Object?>[
              _family('ipv4'),
            ])
            as WasmComponentValueData,
      );

      expect(
        _errorLabel(
          imports['wasi:sockets/types@0.3.0.tcp-socket.get-local-address']!(
                <Object?>[tcp],
              )
              as WasmComponentValueData,
        ),
        'invalid-state',
      );
      expect(
        _isOk(
          imports['wasi:sockets/types@0.3.0.tcp-socket.bind']!(<Object?>[
                tcp,
                _ipv4Socket(port: 0, a: 127, b: 0, c: 0, d: 1),
              ])
              as WasmComponentValueData,
        ),
        isTrue,
      );
      expect(
        _socketPort(
          _okValue(
                imports['wasi:sockets/types@0.3.0.tcp-socket.get-local-address']!(
                      <Object?>[tcp],
                    )
                    as WasmComponentValueData,
              )
              as WasmComponentValueData,
        ),
        41000,
      );
      expect(
        _errorLabel(
          imports['wasi:sockets/types@0.3.0.tcp-socket.bind']!(<Object?>[
                tcp,
                _ipv4Socket(port: 9999, a: 127, b: 0, c: 0, d: 1),
              ])
              as WasmComponentValueData,
        ),
        'invalid-state',
      );

      expect(
        _isOk(
          imports['wasi:sockets/types@0.3.0.tcp-socket.set-hop-limit']!(
                <Object?>[tcp, 32],
              )
              as WasmComponentValueData,
        ),
        isTrue,
      );
      expect(
        _integerResult(
          imports['wasi:sockets/types@0.3.0.tcp-socket.get-hop-limit']!(
                <Object?>[tcp],
              )
              as WasmComponentValueData,
        ),
        32,
      );
      expect(
        _errorLabel(
          imports['wasi:sockets/types@0.3.0.tcp-socket.set-hop-limit']!(
                <Object?>[tcp, 0],
              )
              as WasmComponentValueData,
        ),
        'invalid-argument',
      );
      expect(
        (imports['wasi:sockets/types@0.3.0.tcp-socket.get-address-family']!(
                  <Object?>[tcp],
                )
                as WasmComponentValueData)
            .label,
        'ipv4',
      );
      host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', tcp);
    });

    test('preserves IPv6 flow info and scope id in address properties', () {
      final host = WASIPreview3SocketsHost(backend: _FakeSocketsBackend());
      final imports = host.imports;
      final tcp = _resource(
        imports['wasi:sockets/types@0.3.0.tcp-socket.create']!(<Object?>[
              _family('ipv6'),
            ])
            as WasmComponentValueData,
      );

      expect(
        _isOk(
          imports['wasi:sockets/types@0.3.0.tcp-socket.bind']!(<Object?>[
                tcp,
                _ipv6Socket(port: 8080, flowInfo: 7, scopeId: 9),
              ])
              as WasmComponentValueData,
        ),
        isTrue,
      );
      final address =
          _okValue(
                imports['wasi:sockets/types@0.3.0.tcp-socket.get-local-address']!(
                      <Object?>[tcp],
                    )
                    as WasmComponentValueData,
              )
              as WasmComponentValueData;
      final record = address.associatedValue!;
      expect(address.label, 'ipv6');
      expect(record.items[1].integer, 7);
      expect(record.items[3].integer, 9);
      host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', tcp);
    });

    test('bound TCP listen consumes its binding with the latest backlog', () {
      final backend = _FakeSocketsBackend();
      final host = WASIPreview3SocketsHost(backend: backend);
      final imports = host.imports;
      final tcp = _createSocket(imports, tcp: true);

      expect(
        _isOk(
          imports['wasi:sockets/types@0.3.0.tcp-socket.bind']!(<Object?>[
                tcp,
                _ipv4Socket(port: 0, a: 127, b: 0, c: 0, d: 1),
              ])
              as WasmComponentValueData,
        ),
        isTrue,
      );
      final binding = backend.lastBinding!;
      expect(
        _isOk(
          imports['wasi:sockets/types@0.3.0.tcp-socket.set-listen-backlog-size']!(
                <Object?>[tcp, BigInt.from(7)],
              )
              as WasmComponentValueData,
        ),
        isTrue,
      );

      final listened =
          imports['wasi:sockets/types@0.3.0.tcp-socket.listen']!(<Object?>[tcp])
              as WasmComponentValueData;
      final stream = _okValue(listened) as WASIComponentStream<int>;

      expect(backend.listenBinding, same(binding));
      expect(backend.listenBacklog, BigInt.from(7));
      expect(binding.closed, isTrue);
      expect(binding.closeCallCount, 1);
      expect(
        imports['wasi:sockets/types@0.3.0.tcp-socket.get-is-listening']!(
          <Object?>[tcp],
        ),
        isTrue,
      );

      host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', tcp);
      stream.readable.drop();
      stream.writable.drop();
    });

    test('bound TCP connect consumes its binding exactly once', () async {
      final backend = _FakeSocketsBackend();
      final host = WASIPreview3SocketsHost(backend: backend);
      final imports = host.imports;
      final tcp = _createSocket(imports, tcp: true);

      expect(
        _isOk(
          imports['wasi:sockets/types@0.3.0.tcp-socket.bind']!(<Object?>[
                tcp,
                _ipv4Socket(port: 0, a: 127, b: 0, c: 0, d: 1),
              ])
              as WasmComponentValueData,
        ),
        isTrue,
      );
      final binding = backend.lastBinding!;

      expect(
        _isOk(
          await imports['wasi:sockets/types@0.3.0.tcp-socket.connect']!(
                <Object?>[
                  tcp,
                  _ipv4Socket(port: 8080, a: 127, b: 0, c: 0, d: 1),
                ],
              )
              as WasmComponentValueData,
        ),
        isTrue,
      );
      expect(backend.connectBinding, same(binding));
      expect(binding.closed, isTrue);
      expect(binding.closeCallCount, 1);

      host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', tcp);
      expect(binding.closeCallCount, 1);
    });

    test(
      'propagates backend errors and closes failed TCP connect state',
      () async {
        final host = WASIPreview3SocketsHost();
        final imports = host.imports;
        final tcp = _createSocket(imports, tcp: true);
        final udp = _createSocket(imports, tcp: false);

        expect(
          _errorLabel(
            await imports['wasi:sockets/types@0.3.0.tcp-socket.connect']!(
                  <Object?>[
                    tcp,
                    _ipv4Socket(port: 80, a: 192, b: 0, c: 2, d: 1),
                  ],
                )
                as WasmComponentValueData,
          ),
          'not-supported',
        );
        expect(
          _errorLabel(
            await imports['wasi:sockets/types@0.3.0.tcp-socket.connect']!(
                  <Object?>[
                    tcp,
                    _ipv4Socket(port: 80, a: 192, b: 0, c: 2, d: 1),
                  ],
                )
                as WasmComponentValueData,
          ),
          'invalid-state',
        );
        expect(
          _errorLabel(
            imports['wasi:sockets/types@0.3.0.udp-socket.bind']!(<Object?>[
                  udp,
                  _ipv4Socket(port: 0, a: 127, b: 0, c: 0, d: 1),
                ])
                as WasmComponentValueData,
          ),
          'not-supported',
        );
        host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', tcp);
        host.table.dropNamed('wasi:sockets/types@0.3.0.udp-socket', udp);
      },
    );

    test(
      'connects TCP and preserves send/receive half streams until done',
      () async {
        final backend = _FakeSocketsBackend();
        final host = WASIPreview3SocketsHost(backend: backend);
        final imports = host.imports;
        final tcp = _createSocket(imports, tcp: true);
        final remote = _ipv4Socket(port: 8080, a: 127, b: 0, c: 0, d: 1);

        final connected =
            await imports['wasi:sockets/types@0.3.0.tcp-socket.connect']!(
                  <Object?>[tcp, remote],
                )
                as WasmComponentValueData;
        expect(_isOk(connected), isTrue);
        expect(
          _socketPort(
            _okValue(
                  imports['wasi:sockets/types@0.3.0.tcp-socket.get-remote-address']!(
                        <Object?>[tcp],
                      )
                      as WasmComponentValueData,
                )
                as WasmComponentValueData,
          ),
          8080,
        );

        final outgoing = WASIComponentStream<int>(
          'tcp-test-send',
          maxBufferedElements: 0,
        );
        final sendResult =
            imports['wasi:sockets/types@0.3.0.tcp-socket.send']!(<Object?>[
                  tcp,
                  outgoing.readable,
                ])
                as WASIComponentFuture<WasmComponentValueData>;
        expect(
          await outgoing.writable.writeWhenAvailable(<int>[1, 2, 3, 4]),
          4,
        );
        await Future<void>.delayed(Duration.zero);
        outgoing.writable.drop();
        expect(_isOk(await sendResult.readable.readWhenReady()), isTrue);
        expect(sendResult.writable.isDropped, isTrue);
        expect(backend.connected.writes, <int>[1, 2, 3, 4]);
        expect(backend.connected.finishSendCount, 1);

        final rejected = WASIComponentStream<int>(
          'tcp-test-rejected-send',
          maxBufferedElements: 0,
        );
        final rejectedResult =
            imports['wasi:sockets/types@0.3.0.tcp-socket.send']!(<Object?>[
                  tcp,
                  rejected.readable,
                ])
                as WASIComponentFuture<WasmComponentValueData>;
        expect(
          _errorLabel(await rejectedResult.readable.readWhenReady()),
          'invalid-state',
        );
        expect(rejected.readable.isDropped, isTrue);

        final receive =
            imports['wasi:sockets/types@0.3.0.tcp-socket.receive']!(<Object?>[
                  tcp,
                ])
                as List<Object?>;
        final incoming = receive[0] as WASIComponentStream<int>;
        final receiveResult =
            receive[1] as WASIComponentFuture<WasmComponentValueData>;
        expect(await incoming.readable.readWhenAvailable(16), <int>[9, 8, 7]);
        expect(_isOk(await receiveResult.readable.readWhenReady()), isTrue);

        final secondReceive =
            imports['wasi:sockets/types@0.3.0.tcp-socket.receive']!(<Object?>[
                  tcp,
                ])
                as List<Object?>;
        expect(
          _errorLabel(
            await (secondReceive[1]
                    as WASIComponentFuture<WasmComponentValueData>)
                .readable
                .readWhenReady(),
          ),
          'invalid-state',
        );

        host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', tcp);
        expect(backend.connected.closed, isTrue);
      },
    );

    test('forwards TCP receive data larger than stream capacity', () async {
      final bytes = List<int>.generate(100000, (index) => index & 0xff);
      final backend = _FakeSocketsBackend(tcpIncoming: bytes);
      final host = WASIPreview3SocketsHost(backend: backend);
      final imports = host.imports;
      final tcp = _createSocket(imports, tcp: true);

      expect(
        _isOk(
          await imports['wasi:sockets/types@0.3.0.tcp-socket.connect']!(
                <Object?>[
                  tcp,
                  _ipv4Socket(port: 8080, a: 127, b: 0, c: 0, d: 1),
                ],
              )
              as WasmComponentValueData,
        ),
        isTrue,
      );
      final receive =
          imports['wasi:sockets/types@0.3.0.tcp-socket.receive']!(<Object?>[
                tcp,
              ])
              as List<Object?>;

      expect(
        await _readExactly(
          receive[0] as WASIComponentStream<int>,
          bytes.length,
        ),
        bytes,
      );
      expect(
        _isOk(
          await (receive[1] as WASIComponentFuture<WasmComponentValueData>)
              .readable
              .readWhenReady(),
        ),
        isTrue,
      );
      host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', tcp);
    });

    test('dropping the receive stream keeps the send half usable', () async {
      final backend = _FakeSocketsBackend(tcpIncomingClosed: false);
      final host = WASIPreview3SocketsHost(backend: backend);
      final imports = host.imports;
      final tcp = _createSocket(imports, tcp: true);

      expect(
        _isOk(
          await imports['wasi:sockets/types@0.3.0.tcp-socket.connect']!(
                <Object?>[
                  tcp,
                  _ipv4Socket(port: 8080, a: 127, b: 0, c: 0, d: 1),
                ],
              )
              as WasmComponentValueData,
        ),
        isTrue,
      );
      final receive =
          imports['wasi:sockets/types@0.3.0.tcp-socket.receive']!(<Object?>[
                tcp,
              ])
              as List<Object?>;
      final incoming = receive[0] as WASIComponentStream<int>;
      final receiveResult =
          receive[1] as WASIComponentFuture<WasmComponentValueData>;

      await Future<void>.delayed(Duration.zero);
      incoming.readable.drop();
      await Future<void>.delayed(Duration.zero);

      expect(backend.connected.closed, isFalse);
      expect(backend.connected.receiveClosed, isTrue);
      expect(_isOk(await receiveResult.readable.readWhenReady()), isTrue);

      final outgoing = WASIComponentStream<int>('tcp-send-after-receive-drop');
      outgoing.writable.writeAll(const <int>[4, 5, 6]);
      outgoing.writable.drop();
      final sendResult =
          imports['wasi:sockets/types@0.3.0.tcp-socket.send']!(<Object?>[
                tcp,
                outgoing.readable,
              ])
              as WASIComponentFuture<WasmComponentValueData>;
      expect(_isOk(await sendResult.readable.readWhenReady()), isTrue);
      expect(backend.connected.writes, const <int>[4, 5, 6]);

      incoming.writable.drop();
      host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', tcp);
      expect(backend.connected.closed, isTrue);
    });

    test(
      'listening stream owns listener and yields independent sockets',
      () async {
        final backend = _FakeSocketsBackend();
        final acceptedConnection = _FakeTcpConnection(
          local: _address(port: 5000),
          remote: _address(port: 5001),
        );
        backend.listener.add(acceptedConnection.value);
        final host = WASIPreview3SocketsHost(backend: backend);
        final imports = host.imports;
        final tcp = _createSocket(imports, tcp: true);

        final listened =
            imports['wasi:sockets/types@0.3.0.tcp-socket.listen']!(<Object?>[
                  tcp,
                ])
                as WasmComponentValueData;
        final stream = _okValue(listened) as WASIComponentStream<int>;
        host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', tcp);
        expect(backend.listener.closed, isFalse);

        final accepted = (await stream.readable.readWhenAvailable(1)).single;
        expect(
          _socketPort(
            _okValue(
                  imports['wasi:sockets/types@0.3.0.tcp-socket.get-local-address']!(
                        <Object?>[accepted],
                      )
                      as WasmComponentValueData,
                )
                as WasmComponentValueData,
          ),
          5000,
        );
        host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', accepted);
        expect(acceptedConnection.closed, isTrue);

        stream.readable.drop();
        await Future<void>.delayed(Duration.zero);
        expect(backend.listener.closed, isTrue);
        stream.writable.drop();
      },
    );

    test('dropping an accepted stream disposes queued socket handles', () async {
      final backend = _FakeSocketsBackend();
      final host = WASIPreview3SocketsHost(backend: backend);
      final imports = host.imports;
      final server = _createSocket(imports, tcp: true);
      expect(
        _isOk(
          imports['wasi:sockets/types@0.3.0.tcp-socket.set-listen-backlog-size']!(
                <Object?>[server, BigInt.one],
              )
              as WasmComponentValueData,
        ),
        isTrue,
      );
      final stream =
          _okValue(
                imports['wasi:sockets/types@0.3.0.tcp-socket.listen']!(
                      <Object?>[server],
                    )
                    as WasmComponentValueData,
              )
              as WASIComponentStream<int>;
      final connections = <_FakeTcpConnection>[
        for (final port in <int>[41001, 41002])
          _FakeTcpConnection(
            local: _address(port: 41000),
            remote: _address(port: port),
          ),
      ];
      for (final connection in connections) {
        backend.listener.add(connection.value);
      }
      for (
        var attempt = 0;
        attempt < 100 && host.table.activeCount < 3;
        attempt++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(host.table.activeCount, 3);

      stream.readable.drop();
      for (
        var attempt = 0;
        attempt < 100 && host.table.activeCount > 1;
        attempt++
      ) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(host.table.activeCount, 1);
      expect(connections.every((connection) => connection.closed), isTrue);
      expect(
        connections.every((connection) => connection.closeCallCount == 1),
        isTrue,
      );
      host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', server);
      stream.writable.drop();
      expect(host.table.activeCount, 0);
    });

    test(
      'binds UDP, connects, sends, receives, and drops the binding',
      () async {
        final backend = _FakeSocketsBackend();
        final host = WASIPreview3SocketsHost(backend: backend);
        final imports = host.imports;
        final udp = _createSocket(imports, tcp: false);
        final local = _ipv4Socket(port: 0, a: 127, b: 0, c: 0, d: 1);
        final remote = _ipv4Socket(port: 9000, a: 127, b: 0, c: 0, d: 1);

        expect(
          _isOk(
            imports['wasi:sockets/types@0.3.0.udp-socket.bind']!(<Object?>[
                  udp,
                  local,
                ])
                as WasmComponentValueData,
          ),
          isTrue,
        );
        expect(
          _isOk(
            imports['wasi:sockets/types@0.3.0.udp-socket.connect']!(<Object?>[
                  udp,
                  remote,
                ])
                as WasmComponentValueData,
          ),
          isTrue,
        );
        expect(
          _isOk(
            await imports['wasi:sockets/types@0.3.0.udp-socket.send']!(
                  <Object?>[
                    udp,
                    _bytes(<int>[4, 5, 6]),
                    _none(),
                  ],
                )
                as WasmComponentValueData,
          ),
          isTrue,
        );
        expect(backend.udp.sent.single.$1, <int>[4, 5, 6]);
        expect(backend.udp.sent.single.$2.port, 9000);

        final received =
            await imports['wasi:sockets/types@0.3.0.udp-socket.receive']!(
                  <Object?>[udp],
                )
                as WasmComponentValueData;
        final tuple = _okValue(received) as WasmComponentValueData;
        expect(_byteValues(tuple.items[0]), <int>[7, 8]);
        expect(_socketPort(tuple.items[1]), 9000);

        expect(
          _isOk(
            imports['wasi:sockets/types@0.3.0.udp-socket.disconnect']!(
                  <Object?>[udp],
                )
                as WasmComponentValueData,
          ),
          isTrue,
        );
        expect(
          _errorLabel(
            await imports['wasi:sockets/types@0.3.0.udp-socket.send']!(
                  <Object?>[
                    udp,
                    _bytes(<int>[1]),
                    _none(),
                  ],
                )
                as WasmComponentValueData,
          ),
          'invalid-argument',
        );

        host.table.dropNamed('wasi:sockets/types@0.3.0.udp-socket', udp);
        expect(backend.udp.closed, isTrue);
      },
    );

    test('resolves literals and filters IPv4-mapped IPv6 results', () async {
      final queries = <String>[];
      final host = WASIPreview3SocketsHost(
        resolveAddresses: (name) {
          queries.add(name);
          if (name == 'bad.example') {
            throw const WASIPreview3AddressResolverError(
              'temporary-resolver-failure',
            );
          }
          return <WASIPreview3IpAddress>[
            WASIPreview3IpAddress.ipv6(0, 0, 0, 0, 0, 0xffff, 0x7f00, 1),
            WASIPreview3IpAddress.ipv4(192, 0, 2, 1),
          ];
        },
      );
      final resolve =
          host.imports['wasi:sockets/ip-name-lookup@0.3.0.resolve-addresses']!;

      final literal =
          await resolve(<Object?>['127.0.0.1']) as WasmComponentValueData;
      expect((_okValue(literal) as WasmComponentValueData).items, hasLength(1));

      final named =
          await resolve(<Object?>['example.com']) as WasmComponentValueData;
      final addresses = _okValue(named) as WasmComponentValueData;
      expect(addresses.items, hasLength(1));
      expect(addresses.items.single.label, 'ipv4');

      final unicode =
          await resolve(<Object?>['bücher.example']) as WasmComponentValueData;
      expect(_isOk(unicode), isTrue);
      expect(queries, contains('xn--bcher-kva.example'));

      expect(
        _errorLabel(
          await resolve(<Object?>['bad.example']) as WasmComponentValueData,
        ),
        'temporary-resolver-failure',
      );
      expect(
        _errorLabel(
          await resolve(<Object?>['bad::name']) as WasmComponentValueData,
        ),
        'invalid-argument',
      );
    });

    test('backend rejections become terminal host errors', () async {
      final uncaught = <Object>[];
      await runZonedGuarded<Future<void>>(() async {
        final host = WASIPreview3SocketsHost(
          backend: _RejectingSocketsBackend(),
        );
        final imports = host.imports;

        final binding = _createSocket(imports, tcp: true);
        expect(
          _errorLabel(
            await imports['wasi:sockets/types@0.3.0.tcp-socket.bind']!(
                  <Object?>[
                    binding,
                    _ipv4Socket(port: 0, a: 127, b: 0, c: 0, d: 1),
                  ],
                )
                as WasmComponentValueData,
          ),
          'other',
        );

        final listening = _createSocket(imports, tcp: true);
        final listenResult =
            await imports['wasi:sockets/types@0.3.0.tcp-socket.listen']!(
                  <Object?>[listening],
                )
                as WasmComponentValueData;
        expect(_errorLabel(listenResult), 'other');

        final udp = _createSocket(imports, tcp: false);
        expect(
          _errorLabel(
            await imports['wasi:sockets/types@0.3.0.udp-socket.bind']!(
                  <Object?>[
                    udp,
                    _ipv4Socket(port: 0, a: 127, b: 0, c: 0, d: 1),
                  ],
                )
                as WasmComponentValueData,
          ),
          'other',
        );
        expect(
          _errorLabel(
            await imports['wasi:sockets/types@0.3.0.udp-socket.connect']!(
                  <Object?>[
                    udp,
                    _ipv4Socket(port: 9, a: 127, b: 0, c: 0, d: 1),
                  ],
                )
                as WasmComponentValueData,
          ),
          'other',
        );

        await Future<void>.delayed(Duration.zero);
        expect(
          _errorLabel(
            imports['wasi:sockets/types@0.3.0.tcp-socket.get-local-address']!(
                  <Object?>[binding],
                )
                as WasmComponentValueData,
          ),
          'invalid-state',
        );
        expect(
          imports['wasi:sockets/types@0.3.0.tcp-socket.get-is-listening']!(
            <Object?>[listening],
          ),
          isFalse,
        );
        expect(
          _errorLabel(
            await imports['wasi:sockets/types@0.3.0.udp-socket.send']!(
                  <Object?>[
                    udp,
                    _bytes(<int>[1]),
                    _some(_ipv4Socket(port: 9, a: 127, b: 0, c: 0, d: 1)),
                  ],
                )
                as WasmComponentValueData,
          ),
          'other',
        );

        for (final socket in [binding, listening]) {
          host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', socket);
        }
        host.table.dropNamed('wasi:sockets/types@0.3.0.udp-socket', udp);
      }, (error, _) => uncaught.add(error));
      expect(uncaught, isEmpty);
    });

    test('closes immediate backend values that the host cannot own', () async {
      final backend = _TrackingImmediateSocketsBackend();
      final host = WASIPreview3SocketsHost(backend: backend);
      final imports = host.imports;

      final client = _createSocket(imports, tcp: true);
      final connect =
          imports['wasi:sockets/types@0.3.0.tcp-socket.connect']!(<Object?>[
                client,
                _ipv4Socket(port: 80, a: 127, b: 0, c: 0, d: 1),
              ])
              as Future<WasmComponentValueData>;
      host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', client);
      expect(_errorLabel(await connect), 'invalid-state');
      expect(backend.connections.single.closed, isTrue);
      expect(backend.connections.single.closeCallCount, 1);

      final firstTcp = _createSocket(imports, tcp: true);
      final firstAccepted =
          _okValue(
                imports['wasi:sockets/types@0.3.0.tcp-socket.listen']!(
                      <Object?>[firstTcp],
                    )
                    as WasmComponentValueData,
              )
              as WASIComponentStream<int>;
      final secondTcp = _createSocket(imports, tcp: true);
      expect(
        _errorLabel(
          imports['wasi:sockets/types@0.3.0.tcp-socket.listen']!(<Object?>[
                secondTcp,
              ])
              as WasmComponentValueData,
        ),
        'address-in-use',
      );
      expect(backend.listeners[0].closed, isFalse);
      expect(backend.listeners[1].closed, isTrue);
      expect(backend.listeners[1].closeCallCount, 1);

      final firstUdp = _createSocket(imports, tcp: false);
      expect(
        _isOk(
          imports['wasi:sockets/types@0.3.0.udp-socket.bind']!(<Object?>[
                firstUdp,
                _ipv4Socket(port: 0, a: 127, b: 0, c: 0, d: 1),
              ])
              as WasmComponentValueData,
        ),
        isTrue,
      );
      final secondUdp = _createSocket(imports, tcp: false);
      expect(
        _errorLabel(
          imports['wasi:sockets/types@0.3.0.udp-socket.bind']!(<Object?>[
                secondUdp,
                _ipv4Socket(port: 0, a: 127, b: 0, c: 0, d: 1),
              ])
              as WasmComponentValueData,
        ),
        'address-in-use',
      );
      expect(backend.bindings[0].closed, isFalse);
      expect(backend.bindings[1].closed, isTrue);
      expect(backend.bindings[1].closeCallCount, 1);

      for (final socket in <int>[firstTcp, secondTcp]) {
        host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', socket);
      }
      for (final socket in <int>[firstUdp, secondUdp]) {
        host.table.dropNamed('wasi:sockets/types@0.3.0.udp-socket', socket);
      }
      firstAccepted.readable.drop();
      firstAccepted.writable.drop();
      expect(
        backend.listeners.every((listener) => listener.closeCallCount == 1),
        isTrue,
      );
      expect(
        backend.bindings.every((binding) => binding.closeCallCount == 1),
        isTrue,
      );
    });

    test('cancels a pending TCP connect when its socket is dropped', () async {
      final backend = _PendingConnectSocketsBackend();
      final host = WASIPreview3SocketsHost(backend: backend);
      final imports = host.imports;
      final tcp = _createSocket(imports, tcp: true);
      final connect =
          imports['wasi:sockets/types@0.3.0.tcp-socket.connect']!(<Object?>[
                tcp,
                _ipv4Socket(port: 80, a: 127, b: 0, c: 0, d: 1),
              ])
              as Future<WasmComponentValueData>;

      host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', tcp);

      expect(backend.cancelled, isTrue);
      expect(_errorLabel(await connect), 'invalid-state');
    });

    test('native TCP connect drop cancels its ConnectionTask', () async {
      final overrides = _TrackingSocketStartConnectOverrides();
      await io.IOOverrides.runWithIOOverrides(() async {
        final host = WASIPreview3NativeSocketsHost();
        final imports = host.imports;
        final tcp = _createSocket(imports, tcp: true);
        final connect =
            imports['wasi:sockets/types@0.3.0.tcp-socket.connect']!(<Object?>[
                  tcp,
                  _ipv4Socket(port: 80, a: 127, b: 0, c: 0, d: 1),
                ])
                as Future<WasmComponentValueData>;

        host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', tcp);

        expect(_errorLabel(await connect), 'invalid-state');
        expect(overrides.cancelled, isTrue);
      }, overrides);
    });

    test('native POSIX EPERM maps to access-denied', () async {
      if (io.Platform.isWindows) {
        markTestSkipped('POSIX EPERM mapping does not apply on Windows');
        return;
      }
      await io.IOOverrides.runWithIOOverrides(() async {
        final host = WASIPreview3NativeSocketsHost();
        final imports = host.imports;
        final tcp = _createSocket(imports, tcp: true);
        expect(
          _errorLabel(
            await imports['wasi:sockets/types@0.3.0.tcp-socket.connect']!(
                  <Object?>[
                    tcp,
                    _ipv4Socket(port: 80, a: 127, b: 0, c: 0, d: 1),
                  ],
                )
                as WasmComponentValueData,
          ),
          'access-denied',
        );
        host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', tcp);
      }, _FailingSocketStartConnectOverrides(1));
    });

    test('terminal listener failure releases state and reservation', () async {
      final backend = _FakeSocketsBackend();
      final host = WASIPreview3SocketsHost(backend: backend);
      final imports = host.imports;
      final server = _createSocket(imports, tcp: true);
      final accepted =
          _okValue(
                imports['wasi:sockets/types@0.3.0.tcp-socket.listen']!(
                      <Object?>[server],
                    )
                    as WasmComponentValueData,
              )
              as WASIComponentStream<int>;

      backend.listener.close();
      expect(await accepted.readable.readWhenAvailable(1), isEmpty);
      expect(
        imports['wasi:sockets/types@0.3.0.tcp-socket.get-is-listening']!(
          <Object?>[server],
        ),
        isFalse,
      );
      expect(
        _errorLabel(
          imports['wasi:sockets/types@0.3.0.tcp-socket.get-local-address']!(
                <Object?>[server],
              )
              as WasmComponentValueData,
        ),
        'invalid-state',
      );

      final replacement = _createSocket(imports, tcp: true);
      expect(
        _isOk(
          imports['wasi:sockets/types@0.3.0.tcp-socket.bind']!(<Object?>[
                replacement,
                _ipv4Socket(port: 41000, a: 127, b: 0, c: 0, d: 1),
              ])
              as WasmComponentValueData,
        ),
        isTrue,
      );

      for (final socket in <int>[server, replacement]) {
        host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', socket);
      }
      accepted.readable.drop();
      accepted.writable.drop();
    });

    test(
      'terminal UDP failure releases binding state and reservation',
      () async {
        final backend = _TrackingImmediateSocketsBackend();
        final host = WASIPreview3SocketsHost(backend: backend);
        final imports = host.imports;
        final first = _createSocket(imports, tcp: false);
        expect(
          _isOk(
            imports['wasi:sockets/types@0.3.0.udp-socket.bind']!(<Object?>[
                  first,
                  _ipv4Socket(port: 0, a: 127, b: 0, c: 0, d: 1),
                ])
                as WasmComponentValueData,
          ),
          isTrue,
        );

        backend.bindings.single.sendError = 'remote-unreachable';
        expect(
          _errorLabel(
            await imports['wasi:sockets/types@0.3.0.udp-socket.send']!(
                  <Object?>[
                    first,
                    _bytes(<int>[1]),
                    _some(_ipv4Socket(port: 9, a: 127, b: 0, c: 0, d: 1)),
                  ],
                )
                as WasmComponentValueData,
          ),
          'remote-unreachable',
        );
        expect(
          _isOk(
            imports['wasi:sockets/types@0.3.0.udp-socket.get-local-address']!(
                  <Object?>[first],
                )
                as WasmComponentValueData,
          ),
          isTrue,
        );

        backend.bindings.single.close();
        expect(
          _errorLabel(
            imports['wasi:sockets/types@0.3.0.udp-socket.get-local-address']!(
                  <Object?>[first],
                )
                as WasmComponentValueData,
          ),
          'invalid-state',
        );
        expect(
          _errorLabel(
            await imports['wasi:sockets/types@0.3.0.udp-socket.send']!(
                  <Object?>[
                    first,
                    _bytes(<int>[1]),
                    _some(_ipv4Socket(port: 9, a: 127, b: 0, c: 0, d: 1)),
                  ],
                )
                as WasmComponentValueData,
          ),
          'invalid-state',
        );

        final replacement = _createSocket(imports, tcp: false);
        expect(
          _isOk(
            imports['wasi:sockets/types@0.3.0.udp-socket.bind']!(<Object?>[
                  replacement,
                  _ipv4Socket(port: 0, a: 127, b: 0, c: 0, d: 1),
                ])
                as WasmComponentValueData,
          ),
          isTrue,
        );

        for (final socket in <int>[first, replacement]) {
          host.table.dropNamed('wasi:sockets/types@0.3.0.udp-socket', socket);
        }
      },
    );

    test('pending UDP connect waits for one real implicit bind', () async {
      final backend = _PendingUdpSocketsBackend();
      final host = WASIPreview3SocketsHost(backend: backend);
      final imports = host.imports;
      final udp = _createSocket(imports, tcp: false);
      final connect =
          imports['wasi:sockets/types@0.3.0.udp-socket.connect']!(<Object?>[
                udp,
                _ipv4Socket(port: 9, a: 127, b: 0, c: 0, d: 1),
              ])
              as Future<WasmComponentValueData>;
      expect(backend.bindCount, 1);
      backend.completeBind();
      expect(_isOk(await connect), isTrue);
      expect(
        _socketPort(
          _okValue(
                imports['wasi:sockets/types@0.3.0.udp-socket.get-local-address']!(
                      <Object?>[udp],
                    )
                    as WasmComponentValueData,
              )
              as WasmComponentValueData,
        ),
        43000,
      );

      final sends = <Future<WasmComponentValueData>>[
        for (final byte in <int>[1, 2])
          imports['wasi:sockets/types@0.3.0.udp-socket.send']!(<Object?>[
                udp,
                _bytes(<int>[byte]),
                _none(),
              ])
              as Future<WasmComponentValueData>,
      ];
      expect(backend.bindCount, 1);
      final results = await Future.wait(sends);

      expect(results.every(_isOk), isTrue);
      expect(backend.binding.sent, hasLength(2));
      expect(backend.binding.closed, isFalse);
      host.table.dropNamed('wasi:sockets/types@0.3.0.udp-socket', udp);
      expect(backend.binding.closed, isTrue);
    });

    test('WIT invokeAsync waits for a pending sync socket import', () async {
      final backend = _PendingUdpSocketsBackend();
      final host = WASIPreview3SocketsHost(backend: backend);
      final versioned = WASIComponentVersionedHost(
        version: WASIVersion.preview3,
      );
      final program = versioned.bindWitWorld(
        WASIComponentWitDocument.parse(_socketsWorld),
        worldName: 'test',
        imports: host.imports,
      );
      final udp = _resource(
        program.invokeImport(
              'wasi:sockets/types@0.3.0.udp-socket.create',
              <Object?>[_family('ipv4')],
            )
            as WasmComponentValueData,
      );

      final connect = program.invokeImportAsync(
        'wasi:sockets/types@0.3.0.udp-socket.connect',
        <Object?>[udp, _ipv4Socket(port: 9, a: 127, b: 0, c: 0, d: 1)],
      );
      expect(backend.bindCount, 1);
      backend.completeBind();
      expect(_isOk(await connect as WasmComponentValueData), isTrue);
      expect(
        _socketPort(
          _okValue(
                program.invokeImport(
                      'wasi:sockets/types@0.3.0.udp-socket.get-local-address',
                      <Object?>[udp],
                    )
                    as WasmComponentValueData,
              )
              as WasmComponentValueData,
        ),
        43000,
      );

      host.table.dropNamed('wasi:sockets/types@0.3.0.udp-socket', udp);
    });

    test(
      'forced runtime awaits an async callback for a sync core import',
      () async {
        final callback = Completer<int>();
        final runtime = native_instance.WasmInstance.fromBytes(
          Uint8List.fromList(_syncImportModuleBytes),
          imports: native_imports.WasmImports(
            asyncFunctions: <String, native_imports.WasmAsyncHostFunction>{
              native_imports.WasmImports.key('m', 'f'): (_) => callback.future,
            },
          ),
        );

        var completed = false;
        final result = runtime.invokeAsyncForced('run')
          ..then((_) => completed = true);
        await Future<void>.delayed(Duration.zero);
        expect(completed, isFalse);

        callback.complete(37);
        expect(await result, 37);
        expect(completed, isTrue);
      },
    );

    test('native socket options preserve supported values before bind', () {
      final host = WASIPreview3NativeSocketsHost();
      final imports = host.imports;
      final tcp = _createSocket(imports, tcp: true);
      final udp = _createSocket(imports, tcp: false);

      expect(
        _isOk(
          imports['wasi:sockets/types@0.3.0.tcp-socket.set-hop-limit']!(
                <Object?>[tcp, 42],
              )
              as WasmComponentValueData,
        ),
        isTrue,
      );
      expect(
        _integerResult(
          imports['wasi:sockets/types@0.3.0.tcp-socket.get-hop-limit']!(
                <Object?>[tcp],
              )
              as WasmComponentValueData,
        ),
        42,
      );
      expect(
        _isOk(
          imports['wasi:sockets/types@0.3.0.udp-socket.set-unicast-hop-limit']!(
                <Object?>[udp, 42],
              )
              as WasmComponentValueData,
        ),
        isTrue,
      );
      expect(
        _integerResult(
          imports['wasi:sockets/types@0.3.0.udp-socket.get-unicast-hop-limit']!(
                <Object?>[udp],
              )
              as WasmComponentValueData,
        ),
        42,
      );

      host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', tcp);
      host.table.dropNamed('wasi:sockets/types@0.3.0.udp-socket', udp);
    });

    test('selects platform raw socket constants', () {
      for (final operatingSystem in <String>['linux', 'android']) {
        final abi = NativeSocketOptionAbi.forOperatingSystem(operatingSystem)!;
        expect(abi.socketKeepAlive, 9, reason: operatingSystem);
        expect(abi.socketReceiveBuffer, 8, reason: operatingSystem);
        expect(abi.socketSendBuffer, 7, reason: operatingSystem);
        expect(abi.ipv4Ttl, 2, reason: operatingSystem);
        expect(abi.ipv6UnicastHops, 16, reason: operatingSystem);
        expect(abi.tcpKeepIdle, 4, reason: operatingSystem);
        expect(abi.tcpKeepInterval, 5, reason: operatingSystem);
        expect(abi.tcpKeepCount, 6, reason: operatingSystem);
      }
      final windows = NativeSocketOptionAbi.forOperatingSystem('windows')!;
      expect(windows.socketKeepAlive, 0x0008);
      expect(windows.socketReceiveBuffer, 0x1002);
      expect(windows.socketSendBuffer, 0x1001);
      expect(windows.ipv4Ttl, 4);
      expect(windows.ipv6UnicastHops, 4);
      expect(windows.tcpKeepIdle, 3);
      expect(windows.tcpKeepInterval, 17);
      expect(windows.tcpKeepCount, 16);
      expect(NativeSocketOptionAbi.forOperatingSystem('fuchsia'), isNull);
    });

    test('native rejects IPv6 metadata that dart:io cannot preserve', () {
      final host = WASIPreview3NativeSocketsHost();
      final imports = host.imports;
      for (final (flowInfo, scopeId) in <(int, int)>[(1, 0), (0, 1)]) {
        final tcp = _createSocket(imports, tcp: true, family: 'ipv6');
        final result =
            imports['wasi:sockets/types@0.3.0.tcp-socket.bind']!(<Object?>[
                  tcp,
                  _ipv6Socket(port: 0, flowInfo: flowInfo, scopeId: scopeId),
                ])
                as WasmComponentValueData;
        expect(_errorLabel(result), 'not-supported');
        host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', tcp);
      }
    });

    test('native socket option setters apply to active OS endpoints', () async {
      final server = await io.ServerSocket.bind(
        io.InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(server.close);
      final accepted = server.first;

      final host = WASIPreview3NativeSocketsHost();
      final imports = host.imports;
      final tcp = _createSocket(imports, tcp: true);
      final udp = _createSocket(imports, tcp: false);
      addTearDown(() {
        host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', tcp);
        host.table.dropNamed('wasi:sockets/types@0.3.0.udp-socket', udp);
      });

      expect(
        _isOk(
          await imports['wasi:sockets/types@0.3.0.tcp-socket.connect']!(
                <Object?>[
                  tcp,
                  _ipv4Socket(port: server.port, a: 127, b: 0, c: 0, d: 1),
                ],
              )
              as WasmComponentValueData,
        ),
        isTrue,
      );
      final peer = await accepted;
      addTearDown(peer.destroy);

      final tcpOptions = <(String, Object)>[
        ('set-keep-alive-enabled', true),
        ('set-keep-alive-idle-time', BigInt.from(5000000000)),
        ('set-keep-alive-interval', BigInt.from(2000000000)),
        ('set-keep-alive-count', 4),
        ('set-hop-limit', 41),
        ('set-receive-buffer-size', BigInt.from(131072)),
        ('set-send-buffer-size', BigInt.from(131072)),
      ];
      for (final (name, value) in tcpOptions) {
        expect(
          _isOk(
            await imports['wasi:sockets/types@0.3.0.tcp-socket.$name']!(
                  <Object?>[tcp, value],
                )
                as WasmComponentValueData,
          ),
          isTrue,
          reason: name,
        );
      }

      expect(
        _isOk(
          await imports['wasi:sockets/types@0.3.0.udp-socket.bind']!(<Object?>[
                udp,
                _ipv4Socket(port: 0, a: 127, b: 0, c: 0, d: 1),
              ])
              as WasmComponentValueData,
        ),
        isTrue,
      );
      final udpOptions = <(String, Object)>[
        ('set-unicast-hop-limit', 39),
        ('set-receive-buffer-size', BigInt.from(131072)),
        ('set-send-buffer-size', BigInt.from(131072)),
      ];
      for (final (name, value) in udpOptions) {
        expect(
          _isOk(
            await imports['wasi:sockets/types@0.3.0.udp-socket.$name']!(
                  <Object?>[udp, value],
                )
                as WasmComponentValueData,
          ),
          isTrue,
          reason: name,
        );
      }
    }, tags: 'network');

    test(
      'native UDP bind awaits an OS reservation before connect returns',
      () async {
        final host = WASIPreview3NativeSocketsHost();
        final imports = host.imports;
        final udp = _createSocket(imports, tcp: false);
        addTearDown(
          () =>
              host.table.dropNamed('wasi:sockets/types@0.3.0.udp-socket', udp),
        );

        expect(
          _isOk(
            await imports['wasi:sockets/types@0.3.0.udp-socket.bind']!(
                  <Object?>[
                    udp,
                    _ipv4Socket(port: 0, a: 127, b: 0, c: 0, d: 1),
                  ],
                )
                as WasmComponentValueData,
          ),
          isTrue,
        );
        final port = _socketPort(
          _okValue(
                imports['wasi:sockets/types@0.3.0.udp-socket.get-local-address']!(
                      <Object?>[udp],
                    )
                    as WasmComponentValueData,
              )
              as WasmComponentValueData,
        );
        expect(port, greaterThan(0));
        expect(
          _isOk(
            await imports['wasi:sockets/types@0.3.0.udp-socket.connect']!(
                  <Object?>[
                    udp,
                    _ipv4Socket(port: 9, a: 127, b: 0, c: 0, d: 1),
                  ],
                )
                as WasmComponentValueData,
          ),
          isTrue,
        );
        expect(
          _socketPort(
            _okValue(
                  imports['wasi:sockets/types@0.3.0.udp-socket.get-local-address']!(
                        <Object?>[udp],
                      )
                      as WasmComponentValueData,
                )
                as WasmComponentValueData,
          ),
          port,
        );
        final sendResult =
            await imports['wasi:sockets/types@0.3.0.udp-socket.send']!(
                  <Object?>[
                    udp,
                    _bytes(<int>[1]),
                    _none(),
                  ],
                )
                as WasmComponentValueData;
        expect(
          _errorLabel(sendResult),
          isNull,
          reason: 'the connected native UDP binding must send successfully',
        );
        await expectLater(
          io.RawDatagramSocket.bind(io.InternetAddress.loopbackIPv4, port),
          throwsA(isA<io.SocketException>()),
        );
      },
      tags: 'network',
    );

    test('native TCP bind reports unsupported without fake state', () async {
      final host = WASIPreview3NativeSocketsHost();
      final imports = host.imports;
      final tcp = _createSocket(imports, tcp: true);
      addTearDown(
        () => host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', tcp),
      );

      final bound =
          await imports['wasi:sockets/types@0.3.0.tcp-socket.bind']!(<Object?>[
                tcp,
                _ipv4Socket(port: 0, a: 127, b: 0, c: 0, d: 1),
              ])
              as WasmComponentValueData;

      expect(_errorLabel(bound), 'not-supported');
      expect(
        _errorLabel(
          imports['wasi:sockets/types@0.3.0.tcp-socket.get-local-address']!(
                <Object?>[tcp],
              )
              as WasmComponentValueData,
        ),
        'invalid-state',
      );
      expect(
        imports['wasi:sockets/types@0.3.0.tcp-socket.get-is-listening']!(
          <Object?>[tcp],
        ),
        isFalse,
      );
      expect(
        _errorLabel(
          await imports['wasi:sockets/types@0.3.0.tcp-socket.bind']!(<Object?>[
                tcp,
                _ipv4Socket(port: 0, a: 127, b: 0, c: 0, d: 1),
              ])
              as WasmComponentValueData,
        ),
        'not-supported',
      );
      expect(
        _isOk(
          imports['wasi:sockets/types@0.3.0.tcp-socket.set-listen-backlog-size']!(
                <Object?>[tcp, BigInt.one],
              )
              as WasmComponentValueData,
        ),
        isTrue,
      );
    });

    test('native IPv6 TCP listener does not reserve the IPv4 port', () async {
      final host = WASIPreview3NativeSocketsHost();
      final imports = host.imports;
      final server = _createSocket(imports, tcp: true, family: 'ipv6');
      WASIComponentStream<int>? accepted;
      io.ServerSocket? ipv4;
      try {
        final listened =
            await imports['wasi:sockets/types@0.3.0.tcp-socket.listen']!(
                  <Object?>[server],
                )
                as WasmComponentValueData;
        if (!_isOk(listened)) {
          markTestSkipped('host does not provide IPv6 loopback sockets');
          return;
        }
        accepted = _okValue(listened) as WASIComponentStream<int>;
        final port = await _waitForPort(imports, server, tcp: true);

        ipv4 = await io.ServerSocket.bind(io.InternetAddress.anyIPv4, port);
        expect(ipv4.port, port);
      } finally {
        await ipv4?.close();
        host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', server);
        accepted?.readable.drop();
        accepted?.writable.drop();
      }
    }, tags: 'network');

    test('rejects a 65536-byte UDP datagram before binding', () async {
      final host = WASIPreview3SocketsHost(backend: _FakeSocketsBackend());
      final imports = host.imports;
      final udp = _createSocket(imports, tcp: false);

      expect(
        _errorLabel(
          await imports['wasi:sockets/types@0.3.0.udp-socket.send']!(<Object?>[
                udp,
                _bytes(List<int>.filled(65536, 0)),
                _some(_ipv4Socket(port: 42, a: 127, b: 0, c: 0, d: 1)),
              ])
              as WasmComponentValueData,
        ),
        'datagram-too-large',
      );

      host.table.dropNamed('wasi:sockets/types@0.3.0.udp-socket', udp);
    });

    test(
      'native loopback TCP listens, connects, and half-closes',
      () async {
        final host = WASIPreview3NativeSocketsHost();
        final imports = host.imports;
        final server = _createSocket(imports, tcp: true);
        final client = _createSocket(imports, tcp: true);
        final listenResult =
            await imports['wasi:sockets/types@0.3.0.tcp-socket.listen']!(
                  <Object?>[server],
                )
                as WasmComponentValueData;
        final acceptedStream =
            _okValue(listenResult) as WASIComponentStream<int>;
        final port = await _waitForPort(imports, server, tcp: true);

        expect(
          _isOk(
            await imports['wasi:sockets/types@0.3.0.tcp-socket.connect']!(
                  <Object?>[
                    client,
                    _ipv4Socket(port: port, a: 127, b: 0, c: 0, d: 1),
                  ],
                )
                as WasmComponentValueData,
          ),
          isTrue,
        );
        final accepted = (await acceptedStream.readable.readWhenAvailable(
          1,
        )).single;

        final serverReceive =
            imports['wasi:sockets/types@0.3.0.tcp-socket.receive']!(<Object?>[
                  accepted,
                ])
                as List<Object?>;
        final clientReceive =
            imports['wasi:sockets/types@0.3.0.tcp-socket.receive']!(<Object?>[
                  client,
                ])
                as List<Object?>;
        final requestBytes = List<int>.generate(
          100000,
          (index) => index & 0xff,
        );
        final request = WASIComponentStream<int>('native-tcp-request');
        request.writable.writeAll(requestBytes);
        request.writable.close();
        final requestResult =
            imports['wasi:sockets/types@0.3.0.tcp-socket.send']!(<Object?>[
                  client,
                  request.readable,
                ])
                as WASIComponentFuture<WasmComponentValueData>;

        expect(
          await _readExactly(
            serverReceive[0] as WASIComponentStream<int>,
            requestBytes.length,
          ),
          requestBytes,
        );
        expect(_isOk(await requestResult.readable.readWhenReady()), isTrue);
        expect(
          _isOk(
            await (serverReceive[1]
                    as WASIComponentFuture<WasmComponentValueData>)
                .readable
                .readWhenReady(),
          ),
          isTrue,
        );

        final response = WASIComponentStream<int>('native-tcp-response');
        response.writable.writeAll(<int>[112, 111, 110, 103]);
        response.writable.close();
        final responseResult =
            imports['wasi:sockets/types@0.3.0.tcp-socket.send']!(<Object?>[
                  accepted,
                  response.readable,
                ])
                as WASIComponentFuture<WasmComponentValueData>;
        expect(
          await (clientReceive[0] as WASIComponentStream<int>).readable
              .readWhenAvailable(4),
          <int>[112, 111, 110, 103],
        );
        expect(_isOk(await responseResult.readable.readWhenReady()), isTrue);

        host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', client);
        host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', accepted);
        host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', server);
        acceptedStream.readable.drop();
        acceptedStream.writable.drop();
      },
      tags: 'network',
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'native TCP listener resumes after its backlog queue drains',
      () async {
        final host = WASIPreview3NativeSocketsHost();
        final imports = host.imports;
        final server = _createSocket(imports, tcp: true);
        expect(
          _isOk(
            imports['wasi:sockets/types@0.3.0.tcp-socket.set-listen-backlog-size']!(
                  <Object?>[server, BigInt.one],
                )
                as WasmComponentValueData,
          ),
          isTrue,
        );
        final acceptedStream =
            _okValue(
                  await imports['wasi:sockets/types@0.3.0.tcp-socket.listen']!(
                        <Object?>[server],
                      )
                      as WasmComponentValueData,
                )
                as WASIComponentStream<int>;
        final port = await _waitForPort(imports, server, tcp: true);
        final clientFutures = <Future<io.Socket>>[
          for (var index = 0; index < 3; index++)
            io.Socket.connect(io.InternetAddress.loopbackIPv4, port),
        ];
        final accepted = <int>[];
        for (var index = 0; index < clientFutures.length; index++) {
          accepted.add(
            (await acceptedStream.readable.readWhenAvailable(1)).single,
          );
        }
        final clients = await Future.wait(clientFutures);

        for (final client in clients) {
          client.destroy();
        }
        for (final socket in accepted) {
          host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', socket);
        }
        host.table.dropNamed('wasi:sockets/types@0.3.0.tcp-socket', server);
        acceptedStream.readable.drop();
        acceptedStream.writable.drop();
      },
      tags: 'network',
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'native loopback UDP sends and receives one datagram',
      () async {
        final peer = await io.RawDatagramSocket.bind(
          io.InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(peer.close);
        final peerReceived = Completer<io.Datagram>();
        final peerSubscription = peer.listen((event) {
          if (event != io.RawSocketEvent.read) return;
          final datagram = peer.receive();
          if (datagram != null && !peerReceived.isCompleted) {
            peerReceived.complete(datagram);
          }
        });
        addTearDown(() => peerSubscription.cancel());

        final host = WASIPreview3NativeSocketsHost();
        final imports = host.imports;
        final udp = _createSocket(imports, tcp: false);
        addTearDown(
          () =>
              host.table.dropNamed('wasi:sockets/types@0.3.0.udp-socket', udp),
        );
        expect(
          _isOk(
            await imports['wasi:sockets/types@0.3.0.udp-socket.connect']!(
                  <Object?>[
                    udp,
                    _ipv4Socket(port: peer.port, a: 127, b: 0, c: 0, d: 1),
                  ],
                )
                as WasmComponentValueData,
          ),
          isTrue,
        );

        final receivedFuture =
            imports['wasi:sockets/types@0.3.0.udp-socket.receive']!(<Object?>[
                  udp,
                ])
                as Future<WasmComponentValueData>;
        final localPort = await _waitForPort(imports, udp, tcp: false);
        expect(
          peer.send(
            <int>[1, 3, 3, 7],
            io.InternetAddress.loopbackIPv4,
            localPort,
          ),
          4,
        );
        final received = await receivedFuture;
        final tuple = _okValue(received) as WasmComponentValueData;
        expect(_byteValues(tuple.items[0]), <int>[1, 3, 3, 7]);

        final sent =
            await imports['wasi:sockets/types@0.3.0.udp-socket.send']!(
                  <Object?>[
                    udp,
                    _bytes(<int>[7, 3, 3, 1]),
                    _none(),
                  ],
                )
                as WasmComponentValueData;
        expect(_isOk(sent), isTrue);
        expect((await peerReceived.future).data, <int>[7, 3, 3, 1]);
      },
      tags: 'network',
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test('native IPv6 UDP ignores IPv4-mapped datagrams', () async {
      final host = WASIPreview3NativeSocketsHost();
      final imports = host.imports;
      final udp = _createSocket(imports, tcp: false, family: 'ipv6');
      io.RawDatagramSocket? ipv4;
      io.RawDatagramSocket? ipv6;
      try {
        final bound =
            await imports['wasi:sockets/types@0.3.0.udp-socket.bind']!(
                  <Object?>[
                    udp,
                    _ipv6Socket(
                      port: 0,
                      address: const <int>[0, 0, 0, 0, 0, 0, 0, 0],
                    ),
                  ],
                )
                as WasmComponentValueData;
        if (!_isOk(bound)) {
          markTestSkipped('host does not provide IPv6 UDP sockets');
          return;
        }
        try {
          ipv4 = await io.RawDatagramSocket.bind(
            io.InternetAddress.loopbackIPv4,
            0,
          );
          ipv6 = await io.RawDatagramSocket.bind(
            io.InternetAddress.loopbackIPv6,
            0,
          );
        } on io.SocketException {
          markTestSkipped('host does not provide IPv4 and IPv6 UDP peers');
          return;
        }
        final port = await _waitForPort(imports, udp, tcp: false);
        var completed = false;
        final received =
            (imports['wasi:sockets/types@0.3.0.udp-socket.receive']!(<Object?>[
                      udp,
                    ])
                    as Future<WasmComponentValueData>)
                .whenComplete(() => completed = true);

        expect(ipv4.send(<int>[4], io.InternetAddress.loopbackIPv4, port), 1);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(completed, isFalse);

        expect(ipv6.send(<int>[6], io.InternetAddress.loopbackIPv6, port), 1);
        final tuple = _okValue(await received) as WasmComponentValueData;
        expect(_byteValues(tuple.items[0]), <int>[6]);
      } finally {
        ipv4?.close();
        ipv6?.close();
        host.table.dropNamed('wasi:sockets/types@0.3.0.udp-socket', udp);
      }
    }, tags: 'network');
  });
}

final class _RejectingSocketsBackend implements WASIPreview3SocketsBackend {
  Future<WASIPreview3SocketResult<T>> _reject<T>() =>
      Future<WASIPreview3SocketResult<T>>.error(
        StateError('rejected backend operation'),
      );

  @override
  WASIPreview3SocketOperation<WASIPreview3TcpBinding> startTcpBind(
    WASIPreview3IpSocketAddress localAddress, {
    required BigInt backlog,
  }) => WASIPreview3SocketOperation<WASIPreview3TcpBinding>.pending(
    _reject<WASIPreview3TcpBinding>(),
  );

  @override
  WASIPreview3SocketOperation<WASIPreview3TcpConnection> startTcpConnect({
    required WASIPreview3IpSocketAddress remoteAddress,
    WASIPreview3IpSocketAddress? localAddress,
    WASIPreview3TcpBinding? binding,
  }) => WASIPreview3SocketOperation<WASIPreview3TcpConnection>.pending(
    _reject<WASIPreview3TcpConnection>(),
  );

  @override
  WASIPreview3SocketOperation<WASIPreview3TcpListener> startTcpListen({
    required WASIPreview3IpSocketAddress localAddress,
    required BigInt backlog,
    WASIPreview3TcpBinding? binding,
  }) => WASIPreview3SocketOperation<WASIPreview3TcpListener>.pending(
    _reject<WASIPreview3TcpListener>(),
  );

  @override
  WASIPreview3SocketOperation<WASIPreview3UdpBinding> startUdpBind(
    WASIPreview3IpSocketAddress localAddress,
  ) => WASIPreview3SocketOperation<WASIPreview3UdpBinding>.pending(
    _reject<WASIPreview3UdpBinding>(),
  );
}

final class _TrackingImmediateSocketsBackend
    implements WASIPreview3SocketsBackend {
  final List<_FakeTcpConnection> connections = <_FakeTcpConnection>[];
  final List<_FakeTcpListener> listeners = <_FakeTcpListener>[];
  final List<_FakeUdpBinding> bindings = <_FakeUdpBinding>[];

  @override
  WASIPreview3SocketOperation<WASIPreview3TcpBinding> startTcpBind(
    WASIPreview3IpSocketAddress localAddress, {
    required BigInt backlog,
  }) => WASIPreview3SocketOperation<WASIPreview3TcpBinding>.completed(
    WASIPreview3SocketResult<WASIPreview3TcpBinding>.ok(
      _FakeTcpBinding(localAddress),
    ),
  );

  @override
  WASIPreview3SocketOperation<WASIPreview3TcpConnection> startTcpConnect({
    required WASIPreview3IpSocketAddress remoteAddress,
    WASIPreview3IpSocketAddress? localAddress,
    WASIPreview3TcpBinding? binding,
  }) {
    binding?.close();
    final connection = _FakeTcpConnection(
      local: localAddress ?? _address(port: 42001),
      remote: remoteAddress,
    );
    connections.add(connection);
    return WASIPreview3SocketOperation<WASIPreview3TcpConnection>.completed(
      WASIPreview3SocketResult<WASIPreview3TcpConnection>.ok(connection.value),
    );
  }

  @override
  WASIPreview3SocketOperation<WASIPreview3TcpListener> startTcpListen({
    required WASIPreview3IpSocketAddress localAddress,
    required BigInt backlog,
    WASIPreview3TcpBinding? binding,
  }) {
    binding?.close();
    final listener = _FakeTcpListener(_address(port: 42000));
    listeners.add(listener);
    return WASIPreview3SocketOperation<WASIPreview3TcpListener>.completed(
      WASIPreview3SocketResult<WASIPreview3TcpListener>.ok(listener),
    );
  }

  @override
  WASIPreview3SocketOperation<WASIPreview3UdpBinding> startUdpBind(
    WASIPreview3IpSocketAddress localAddress,
  ) {
    final binding = _FakeUdpBinding(_address(port: 43000));
    bindings.add(binding);
    return WASIPreview3SocketOperation<WASIPreview3UdpBinding>.completed(
      WASIPreview3SocketResult<WASIPreview3UdpBinding>.ok(binding),
    );
  }
}

final class _PendingConnectSocketsBackend
    implements WASIPreview3SocketsBackend {
  final Completer<WASIPreview3SocketResult<WASIPreview3TcpConnection>>
  _connection =
      Completer<WASIPreview3SocketResult<WASIPreview3TcpConnection>>();
  bool cancelled = false;

  @override
  WASIPreview3SocketOperation<WASIPreview3TcpBinding> startTcpBind(
    WASIPreview3IpSocketAddress localAddress, {
    required BigInt backlog,
  }) => WASIPreview3SocketOperation<WASIPreview3TcpBinding>.completed(
    const WASIPreview3SocketResult<WASIPreview3TcpBinding>.error(
      'not-supported',
    ),
  );

  @override
  WASIPreview3SocketOperation<WASIPreview3TcpConnection> startTcpConnect({
    required WASIPreview3IpSocketAddress remoteAddress,
    WASIPreview3IpSocketAddress? localAddress,
    WASIPreview3TcpBinding? binding,
  }) => WASIPreview3SocketOperation<WASIPreview3TcpConnection>.pending(
    _connection.future,
    cancel: () {
      cancelled = true;
      if (!_connection.isCompleted) {
        _connection.complete(
          const WASIPreview3SocketResult<WASIPreview3TcpConnection>.error(
            'connection-aborted',
          ),
        );
      }
    },
  );

  @override
  WASIPreview3SocketOperation<WASIPreview3TcpListener> startTcpListen({
    required WASIPreview3IpSocketAddress localAddress,
    required BigInt backlog,
    WASIPreview3TcpBinding? binding,
  }) => WASIPreview3SocketOperation<WASIPreview3TcpListener>.completed(
    const WASIPreview3SocketResult<WASIPreview3TcpListener>.error(
      'not-supported',
    ),
  );

  @override
  WASIPreview3SocketOperation<WASIPreview3UdpBinding> startUdpBind(
    WASIPreview3IpSocketAddress localAddress,
  ) => WASIPreview3SocketOperation<WASIPreview3UdpBinding>.completed(
    const WASIPreview3SocketResult<WASIPreview3UdpBinding>.error(
      'not-supported',
    ),
  );
}

final class _TrackingSocketStartConnectOverrides extends io.IOOverrides {
  final Completer<io.Socket> _socket = Completer<io.Socket>();
  bool cancelled = false;

  @override
  Future<io.ConnectionTask<io.Socket>> socketStartConnect(
    host,
    int port, {
    sourceAddress,
    int sourcePort = 0,
  }) async => io.ConnectionTask.fromSocket<io.Socket>(_socket.future, () {
    cancelled = true;
    if (!_socket.isCompleted) {
      _socket.completeError(const io.SocketException('cancelled'));
    }
  });
}

final class _FailingSocketStartConnectOverrides extends io.IOOverrides {
  _FailingSocketStartConnectOverrides(this.errorCode);

  final int errorCode;

  @override
  Future<io.ConnectionTask<io.Socket>> socketStartConnect(
    host,
    int port, {
    sourceAddress,
    int sourcePort = 0,
  }) => Future<io.ConnectionTask<io.Socket>>.error(
    io.SocketException('blocked', osError: io.OSError('blocked', errorCode)),
  );
}

final class _PendingUdpSocketsBackend implements WASIPreview3SocketsBackend {
  final Completer<WASIPreview3SocketResult<WASIPreview3UdpBinding>> _bind =
      Completer<WASIPreview3SocketResult<WASIPreview3UdpBinding>>();
  final _FakeUdpBinding binding = _FakeUdpBinding(_address(port: 43000));
  int bindCount = 0;

  void completeBind() {
    _bind.complete(
      WASIPreview3SocketResult<WASIPreview3UdpBinding>.ok(binding),
    );
  }

  @override
  WASIPreview3SocketOperation<WASIPreview3TcpBinding> startTcpBind(
    WASIPreview3IpSocketAddress localAddress, {
    required BigInt backlog,
  }) => WASIPreview3SocketOperation<WASIPreview3TcpBinding>.completed(
    const WASIPreview3SocketResult<WASIPreview3TcpBinding>.error(
      'not-supported',
    ),
  );

  @override
  WASIPreview3SocketOperation<WASIPreview3TcpConnection> startTcpConnect({
    required WASIPreview3IpSocketAddress remoteAddress,
    WASIPreview3IpSocketAddress? localAddress,
    WASIPreview3TcpBinding? binding,
  }) => WASIPreview3SocketOperation<WASIPreview3TcpConnection>.completed(
    const WASIPreview3SocketResult<WASIPreview3TcpConnection>.error(
      'not-supported',
    ),
  );

  @override
  WASIPreview3SocketOperation<WASIPreview3TcpListener> startTcpListen({
    required WASIPreview3IpSocketAddress localAddress,
    required BigInt backlog,
    WASIPreview3TcpBinding? binding,
  }) => WASIPreview3SocketOperation<WASIPreview3TcpListener>.completed(
    const WASIPreview3SocketResult<WASIPreview3TcpListener>.error(
      'not-supported',
    ),
  );

  @override
  WASIPreview3SocketOperation<WASIPreview3UdpBinding> startUdpBind(
    WASIPreview3IpSocketAddress localAddress,
  ) {
    bindCount++;
    return WASIPreview3SocketOperation<WASIPreview3UdpBinding>.pending(
      _bind.future,
      disposeValue: (value) => value.close(),
    );
  }
}

final class _FakeSocketsBackend implements WASIPreview3SocketsBackend {
  _FakeSocketsBackend({
    List<int> tcpIncoming = const <int>[9, 8, 7],
    bool tcpIncomingClosed = true,
  }) : _tcpIncomingClosed = tcpIncomingClosed,
       _tcpIncoming = tcpIncoming,
       listener = _FakeTcpListener(_address(port: 41000)),
       udp = _FakeUdpBinding(_address(port: 41000));

  final List<int> _tcpIncoming;
  final bool _tcpIncomingClosed;
  final _FakeTcpListener listener;
  final _FakeUdpBinding udp;
  late _FakeTcpConnection connected;
  _FakeTcpBinding? lastBinding;
  WASIPreview3TcpBinding? connectBinding;
  WASIPreview3TcpBinding? listenBinding;
  BigInt? listenBacklog;

  @override
  WASIPreview3SocketOperation<WASIPreview3TcpBinding> startTcpBind(
    WASIPreview3IpSocketAddress localAddress, {
    required BigInt backlog,
  }) {
    final binding = _FakeTcpBinding(
      localAddress.port == 0 ? _address(port: 41000) : localAddress,
    );
    lastBinding = binding;
    return WASIPreview3SocketOperation<WASIPreview3TcpBinding>.completed(
      WASIPreview3SocketResult<WASIPreview3TcpBinding>.ok(binding),
    );
  }

  @override
  WASIPreview3SocketOperation<WASIPreview3TcpConnection> startTcpConnect({
    required WASIPreview3IpSocketAddress remoteAddress,
    WASIPreview3IpSocketAddress? localAddress,
    WASIPreview3TcpBinding? binding,
  }) {
    connectBinding = binding;
    binding?.close();
    connected = _FakeTcpConnection(
      local: localAddress ?? _address(port: 41001),
      remote: remoteAddress,
      incomingBytes: _tcpIncoming,
      incomingClosed: _tcpIncomingClosed,
    );
    return WASIPreview3SocketOperation<WASIPreview3TcpConnection>.completed(
      WASIPreview3SocketResult<WASIPreview3TcpConnection>.ok(connected.value),
    );
  }

  @override
  WASIPreview3SocketOperation<WASIPreview3TcpListener> startTcpListen({
    required WASIPreview3IpSocketAddress localAddress,
    required BigInt backlog,
    WASIPreview3TcpBinding? binding,
  }) {
    listenBinding = binding;
    listenBacklog = backlog;
    binding?.close();
    return WASIPreview3SocketOperation<WASIPreview3TcpListener>.completed(
      WASIPreview3SocketResult<WASIPreview3TcpListener>.ok(listener),
    );
  }

  @override
  WASIPreview3SocketOperation<WASIPreview3UdpBinding> startUdpBind(
    WASIPreview3IpSocketAddress localAddress,
  ) => WASIPreview3SocketOperation<WASIPreview3UdpBinding>.completed(
    WASIPreview3SocketResult<WASIPreview3UdpBinding>.ok(udp),
  );
}

final class _FakeTcpBinding implements WASIPreview3TcpBinding {
  _FakeTcpBinding(this.localAddress);

  @override
  final WASIPreview3IpSocketAddress localAddress;

  bool closed = false;
  int closeCallCount = 0;

  @override
  void close() {
    closeCallCount++;
    closed = true;
  }
}

final class _FakeTcpConnection {
  _FakeTcpConnection({
    required WASIPreview3IpSocketAddress local,
    required WASIPreview3IpSocketAddress remote,
    List<int> incomingBytes = const <int>[9, 8, 7],
    bool incomingClosed = true,
  }) {
    final incoming = WASIComponentStream<int>('fake-tcp-incoming');
    incoming.writable.writeAll(incomingBytes);
    final incomingDone = Completer<WASIPreview3SocketResult<void>>();
    if (incomingClosed) {
      incoming.writable.close();
      incomingDone.complete(const WASIPreview3SocketResult<void>.ok());
    }
    value = WASIPreview3TcpConnection(
      incoming: incoming,
      incomingDone: incomingDone.future,
      write: (bytes) {
        writes.addAll(bytes);
        return const WASIPreview3SocketResult<void>.ok();
      },
      finishSend: () {
        if (closed) {
          return const WASIPreview3SocketResult<void>.error(
            'connection-broken',
          );
        }
        finishSendCount++;
        return const WASIPreview3SocketResult<void>.ok();
      },
      closeReceive: () {
        if (closed || receiveClosed) return;
        receiveClosed = true;
        if (!incoming.writable.isClosed) incoming.writable.close();
        if (!incomingDone.isCompleted) {
          incomingDone.complete(const WASIPreview3SocketResult<void>.ok());
        }
      },
      localAddress: local,
      remoteAddress: remote,
      close: () {
        closeCallCount++;
        if (closed) return;
        closed = true;
        if (!incoming.writable.isClosed) incoming.writable.close();
        if (!incomingDone.isCompleted) {
          incomingDone.complete(
            const WASIPreview3SocketResult<void>.error('connection-aborted'),
          );
        }
      },
    );
  }

  late final WASIPreview3TcpConnection value;
  final List<int> writes = <int>[];
  int finishSendCount = 0;
  int closeCallCount = 0;
  bool receiveClosed = false;
  bool closed = false;
}

final class _FakeTcpListener implements WASIPreview3TcpListener {
  _FakeTcpListener(this.localAddress);

  @override
  final WASIPreview3IpSocketAddress localAddress;
  final List<WASIPreview3TcpConnection> _queue = <WASIPreview3TcpConnection>[];
  final List<Completer<void>> _waiters = <Completer<void>>[];
  bool closed = false;
  int closeCallCount = 0;

  void add(WASIPreview3TcpConnection connection) {
    _queue.add(connection);
    _notify();
  }

  @override
  bool get canAccept => _queue.isNotEmpty || closed;

  @override
  Future<void> waitAccept() {
    if (canAccept) return Future<void>.value();
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  @override
  WASIPreview3SocketResult<WASIPreview3TcpConnection> accept() {
    if (_queue.isNotEmpty) {
      return WASIPreview3SocketResult<WASIPreview3TcpConnection>.ok(
        _queue.removeAt(0),
      );
    }
    return WASIPreview3SocketResult<WASIPreview3TcpConnection>.error(
      closed ? 'connection-aborted' : 'would-block',
    );
  }

  @override
  void close() {
    closeCallCount++;
    if (closed) return;
    closed = true;
    _notify();
  }

  void _notify() {
    final waiters = List<Completer<void>>.of(_waiters);
    _waiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }
}

final class _FakeUdpBinding
    implements WASIPreview3UdpBinding, WASIPreview3UdpBindingLifecycle {
  _FakeUdpBinding(this.localAddress)
    : _incoming = WASIPreview3IncomingDatagram(
        data: Uint8List.fromList(<int>[7, 8]),
        remoteAddress: _address(port: 9000),
      );

  @override
  final WASIPreview3IpSocketAddress localAddress;
  final WASIPreview3IncomingDatagram _incoming;
  final List<(List<int>, WASIPreview3IpSocketAddress)> sent =
      <(List<int>, WASIPreview3IpSocketAddress)>[];
  String? sendError;
  String? receiveError;
  @override
  bool get isClosed => closed;
  bool closed = false;
  int closeCallCount = 0;

  @override
  Future<WASIPreview3SocketResult<void>> send(
    Uint8List data,
    WASIPreview3IpSocketAddress remoteAddress,
  ) async {
    if (closed) {
      return const WASIPreview3SocketResult<void>.error('invalid-state');
    }
    final error = sendError;
    if (error != null) return WASIPreview3SocketResult<void>.error(error);
    sent.add((List<int>.of(data), remoteAddress));
    return const WASIPreview3SocketResult<void>.ok();
  }

  @override
  Future<WASIPreview3SocketResult<WASIPreview3IncomingDatagram>>
  receive() async {
    if (closed) {
      return const WASIPreview3SocketResult<WASIPreview3IncomingDatagram>.error(
        'invalid-state',
      );
    }
    final error = receiveError;
    if (error != null) {
      return WASIPreview3SocketResult<WASIPreview3IncomingDatagram>.error(
        error,
      );
    }
    return WASIPreview3SocketResult<WASIPreview3IncomingDatagram>.ok(_incoming);
  }

  @override
  void close() {
    closeCallCount++;
    closed = true;
  }
}

int _createSocket(
  Map<String, Object? Function(List<Object?>)> imports, {
  required bool tcp,
  String family = 'ipv4',
}) {
  final name = tcp ? 'tcp-socket' : 'udp-socket';
  return _resource(
    imports['wasi:sockets/types@0.3.0.$name.create']!(<Object?>[
          _family(family),
        ])
        as WasmComponentValueData,
  );
}

WASIPreview3IpSocketAddress _address({required int port}) =>
    WASIPreview3IpSocketAddress.ipv4(port: port, a: 127, b: 0, c: 0, d: 1);

WasmComponentValueData _family(String label) => WasmComponentValueData(
  kind: WasmComponentValueDataKind.enumeration,
  rawBytes: Uint8List(0),
  label: label,
);

WasmComponentValueData _ipv4Socket({
  required int port,
  required int a,
  required int b,
  required int c,
  required int d,
}) => WasmComponentValueData(
  kind: WasmComponentValueDataKind.variant,
  rawBytes: Uint8List(0),
  label: 'ipv4',
  associatedValue: WasmComponentValueData(
    kind: WasmComponentValueDataKind.record,
    rawBytes: Uint8List(0),
    items: <WasmComponentValueData>[
      _integer(port),
      WasmComponentValueData(
        kind: WasmComponentValueDataKind.tuple,
        rawBytes: Uint8List(0),
        items: <WasmComponentValueData>[
          _integer(a),
          _integer(b),
          _integer(c),
          _integer(d),
        ],
      ),
    ],
  ),
);

WasmComponentValueData _ipv6Socket({
  required int port,
  int flowInfo = 0,
  int scopeId = 0,
  List<int> address = const <int>[0x2001, 0x0db8, 0, 0, 0, 0, 0, 1],
}) => WasmComponentValueData(
  kind: WasmComponentValueDataKind.variant,
  rawBytes: Uint8List(0),
  label: 'ipv6',
  associatedValue: WasmComponentValueData(
    kind: WasmComponentValueDataKind.record,
    rawBytes: Uint8List(0),
    items: <WasmComponentValueData>[
      _integer(port),
      _integer(flowInfo),
      WasmComponentValueData(
        kind: WasmComponentValueDataKind.tuple,
        rawBytes: Uint8List(0),
        items: <WasmComponentValueData>[
          for (final part in address) _integer(part),
        ],
      ),
      _integer(scopeId),
    ],
  ),
);

WasmComponentValueData _none() => WasmComponentValueData(
  kind: WasmComponentValueDataKind.option,
  rawBytes: Uint8List(0),
  label: 'none',
  isSome: false,
);

WasmComponentValueData _some(WasmComponentValueData value) =>
    WasmComponentValueData(
      kind: WasmComponentValueDataKind.option,
      rawBytes: Uint8List(0),
      label: 'some',
      isSome: true,
      associatedValue: value,
    );

WasmComponentValueData _bytes(List<int> bytes) => WasmComponentValueData(
  kind: WasmComponentValueDataKind.list,
  rawBytes: Uint8List(0),
  items: <WasmComponentValueData>[for (final byte in bytes) _integer(byte)],
);

WasmComponentValueData _integer(Object value) => WasmComponentValueData(
  kind: WasmComponentValueDataKind.integer,
  rawBytes: Uint8List(0),
  integer: value,
);

Object? _okValue(WasmComponentValueData result) {
  expect(_isOk(result), isTrue);
  return result.payload;
}

bool _isOk(WasmComponentValueData result) =>
    result.isOk ?? result.label == 'ok' || result.index == 0;

int _resource(WasmComponentValueData result) =>
    (_okValue(result) as WasmComponentValueData).integer! as int;

String? _errorLabel(WasmComponentValueData result) {
  if (_isOk(result)) return null;
  return (result.associatedValue!).label;
}

int _integerResult(WasmComponentValueData result) =>
    (_okValue(result) as WasmComponentValueData).integer! as int;

int _socketPort(WasmComponentValueData address) =>
    address.associatedValue!.items.first.integer! as int;

List<int> _byteValues(WasmComponentValueData list) => <int>[
  for (final item in list.items) item.integer! as int,
];

Future<int> _waitForPort(
  Map<String, Object? Function(List<Object?>)> imports,
  int socket, {
  required bool tcp,
}) async {
  final name = tcp ? 'tcp-socket' : 'udp-socket';
  for (var attempt = 0; attempt < 100; attempt++) {
    final result =
        imports['wasi:sockets/types@0.3.0.$name.get-local-address']!(<Object?>[
              socket,
            ])
            as WasmComponentValueData;
    if (_isOk(result)) {
      final address = _okValue(result) as WasmComponentValueData;
      final port = _socketPort(address);
      if (port != 0) return port;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('native socket did not bind within one second');
}

Future<List<int>> _readExactly(
  WASIComponentStream<int> stream,
  int length,
) async {
  final values = <int>[];
  while (values.length < length) {
    final remaining = length - values.length;
    final chunk = await stream.readable.readWhenAvailable(
      remaining < 4096 ? remaining : 4096,
    );
    if (chunk.isEmpty) break;
    values.addAll(chunk);
  }
  return values;
}
