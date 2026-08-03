import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/async_values.dart';
import 'package:wasd/src/wasi/component/versioned_host.dart';
import 'package:wasd/src/wasi/component/wit_document.dart';
import 'package:wasd/src/wasi/preview3/native/sockets.dart';
import 'package:wasd/src/wasi/preview3/sockets.dart';
import 'package:wasd/src/wasi/version.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';

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
      final document = WASIComponentWitDocument.parse('''
package wasd-tests:sockets;

world test {
  include wasi:sockets/imports@0.3.0;
}
''');
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

    test('native socket options remain observable before binding', () {
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

    test(
      'native bind publishes an ephemeral port and rejects unusable addresses',
      () {
        final host = WASIPreview3NativeSocketsHost();
        final imports = host.imports;
        final first = _createSocket(imports, tcp: false);
        final duplicate = _createSocket(imports, tcp: false);
        final nonLocal = _createSocket(imports, tcp: false);

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
        final local =
            _okValue(
                  imports['wasi:sockets/types@0.3.0.udp-socket.get-local-address']!(
                        <Object?>[first],
                      )
                      as WasmComponentValueData,
                )
                as WasmComponentValueData;
        expect(_socketPort(local), greaterThan(0));
        expect(
          _errorLabel(
            imports['wasi:sockets/types@0.3.0.udp-socket.bind']!(<Object?>[
                  duplicate,
                  local,
                ])
                as WasmComponentValueData,
          ),
          'address-in-use',
        );
        expect(
          _errorLabel(
            imports['wasi:sockets/types@0.3.0.udp-socket.bind']!(<Object?>[
                  nonLocal,
                  _ipv4Socket(port: 0, a: 192, b: 0, c: 2, d: 1),
                ])
                as WasmComponentValueData,
          ),
          'address-not-bindable',
        );

        host.table.dropNamed('wasi:sockets/types@0.3.0.udp-socket', first);
        host.table.dropNamed('wasi:sockets/types@0.3.0.udp-socket', duplicate);
        host.table.dropNamed('wasi:sockets/types@0.3.0.udp-socket', nonLocal);
      },
    );

    test('native UDP connect publishes its local endpoint synchronously', () {
      final host = WASIPreview3NativeSocketsHost();
      final imports = host.imports;
      final udp = _createSocket(imports, tcp: false);

      expect(
        _isOk(
          imports['wasi:sockets/types@0.3.0.udp-socket.connect']!(<Object?>[
                udp,
                _ipv4Socket(port: 42, a: 127, b: 0, c: 0, d: 1),
              ])
              as WasmComponentValueData,
        ),
        isTrue,
      );
      final local =
          _okValue(
                imports['wasi:sockets/types@0.3.0.udp-socket.get-local-address']!(
                      <Object?>[udp],
                    )
                    as WasmComponentValueData,
              )
              as WasmComponentValueData;
      expect(local.label, 'ipv4');
      expect(_socketPort(local), greaterThan(0));
      expect(
        local.associatedValue!.items[1].items.map((part) => part.integer),
        <Object?>[127, 0, 0, 1],
      );

      host.table.dropNamed('wasi:sockets/types@0.3.0.udp-socket', udp);
    });

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
        expect(
          _isOk(
            imports['wasi:sockets/types@0.3.0.tcp-socket.bind']!(<Object?>[
                  server,
                  _ipv4Socket(port: 0, a: 127, b: 0, c: 0, d: 1),
                ])
                as WasmComponentValueData,
          ),
          isTrue,
        );
        final listenResult =
            imports['wasi:sockets/types@0.3.0.tcp-socket.listen']!(<Object?>[
                  server,
                ])
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
                  request,
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
                  response,
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
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'native loopback UDP sends and receives one datagram',
      () async {
        final host = WASIPreview3NativeSocketsHost();
        final imports = host.imports;
        final receiver = _createSocket(imports, tcp: false);
        final sender = _createSocket(imports, tcp: false);
        for (final socket in <int>[receiver, sender]) {
          expect(
            _isOk(
              imports['wasi:sockets/types@0.3.0.udp-socket.bind']!(<Object?>[
                    socket,
                    _ipv4Socket(port: 0, a: 127, b: 0, c: 0, d: 1),
                  ])
                  as WasmComponentValueData,
            ),
            isTrue,
          );
        }
        final receiverPort = await _waitForPort(imports, receiver, tcp: false);
        final sent =
            await imports['wasi:sockets/types@0.3.0.udp-socket.send']!(
                  <Object?>[
                    sender,
                    _bytes(<int>[1, 3, 3, 7]),
                    _some(
                      _ipv4Socket(port: receiverPort, a: 127, b: 0, c: 0, d: 1),
                    ),
                  ],
                )
                as WasmComponentValueData;
        expect(_isOk(sent), isTrue);
        final received =
            await imports['wasi:sockets/types@0.3.0.udp-socket.receive']!(
                  <Object?>[receiver],
                )
                as WasmComponentValueData;
        final tuple = _okValue(received) as WasmComponentValueData;
        expect(_byteValues(tuple.items[0]), <int>[1, 3, 3, 7]);

        host.table.dropNamed('wasi:sockets/types@0.3.0.udp-socket', sender);
        host.table.dropNamed('wasi:sockets/types@0.3.0.udp-socket', receiver);
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );
  });
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

  @override
  WASIPreview3SocketOperation<WASIPreview3IpSocketAddress> startTcpBind(
    WASIPreview3IpSocketAddress localAddress,
  ) => WASIPreview3SocketOperation<WASIPreview3IpSocketAddress>.completed(
    WASIPreview3SocketResult<WASIPreview3IpSocketAddress>.ok(
      localAddress.port == 0 ? _address(port: 41000) : localAddress,
    ),
  );

  @override
  WASIPreview3SocketOperation<WASIPreview3TcpConnection> startTcpConnect({
    required WASIPreview3IpSocketAddress remoteAddress,
    WASIPreview3IpSocketAddress? localAddress,
  }) {
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
  }) => WASIPreview3SocketOperation<WASIPreview3TcpListener>.completed(
    WASIPreview3SocketResult<WASIPreview3TcpListener>.ok(listener),
  );

  @override
  WASIPreview3SocketOperation<WASIPreview3UdpBinding> startUdpBind(
    WASIPreview3IpSocketAddress localAddress,
  ) => WASIPreview3SocketOperation<WASIPreview3UdpBinding>.completed(
    WASIPreview3SocketResult<WASIPreview3UdpBinding>.ok(udp),
  );
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

final class _FakeUdpBinding implements WASIPreview3UdpBinding {
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
  bool closed = false;

  @override
  Future<WASIPreview3SocketResult<void>> send(
    Uint8List data,
    WASIPreview3IpSocketAddress remoteAddress,
  ) async {
    sent.add((List<int>.of(data), remoteAddress));
    return const WASIPreview3SocketResult<void>.ok();
  }

  @override
  Future<WASIPreview3SocketResult<WASIPreview3IncomingDatagram>>
  receive() async =>
      WASIPreview3SocketResult<WASIPreview3IncomingDatagram>.ok(_incoming);

  @override
  void close() => closed = true;
}

int _createSocket(
  Map<String, Object? Function(List<Object?>)> imports, {
  required bool tcp,
}) {
  final name = tcp ? 'tcp-socket' : 'udp-socket';
  return _resource(
    imports['wasi:sockets/types@0.3.0.$name.create']!(<Object?>[
          _family('ipv4'),
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
          _integer(0x2001),
          _integer(0x0db8),
          _integer(0),
          _integer(0),
          _integer(0),
          _integer(0),
          _integer(0),
          _integer(1),
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
