@TestOn('vm')
library;

import 'dart:async';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:mirrors' as mirrors;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/wasi.dart';
import 'package:wasd/wasm.dart';

void main() {
  group('WASI 0.2.12 host semantics', () {
    test('binds the Preview2 insecure-seed function name', () {
      const source = '''
package wasi-test:host;

world test {
  import wasi:random/insecure-seed@0.2.12;
}
''';
      final host = WASIPreview2ComponentHost();
      final program = host.bindWitWorld(
        WASIComponentWitDocument.parse(source),
        worldName: 'test',
      );

      final seed = program.invokeImport(
        'wasi:random/insecure-seed@0.2.12.insecure-seed',
        const <Object?>[],
      );

      expect(seed, isA<WasmComponentValueData>());
      expect((seed! as WasmComponentValueData).items, hasLength(2));
    });

    test('returns exactly the requested Preview2 random byte length', () {
      final imports = WASIPreview2ComponentHost().standardImports;
      final length = BigInt.from(65536);

      for (final name in <String>[
        'wasi:random/random@0.2.12.get-random-bytes',
        'wasi:random/insecure@0.2.12.get-insecure-random-bytes',
      ]) {
        final bytes = imports[name]!(<Object?>[length]);
        expect(bytes, isA<WasmComponentValueData>(), reason: name);
        expect(
          (bytes! as WasmComponentValueData).items,
          hasLength(length.toInt()),
          reason: name,
        );
      }
    });

    test('traps oversized Preview2 random requests before generation', () {
      final random = _CountingRandom();
      final imports = WASIPreview2ComponentHost(
        randomHost: WASIPreview2RandomHost(
          secureRandom: random,
          insecureRandom: random,
        ),
      ).standardImports;

      for (final name in <String>[
        'wasi:random/random@0.2.12.get-random-bytes',
        'wasi:random/insecure@0.2.12.get-insecure-random-bytes',
      ]) {
        expect(
          () => imports[name]!(<Object?>[BigInt.from(65537)]),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('65536'),
            ),
          ),
          reason: name,
        );
      }
      expect(random.nextIntCalls, 0);
    });

    test('poll traps for an empty pollable list', () {
      final poll = WASIPreview2ComponentHost()
          .standardImports['wasi:io/poll@0.2.12.poll']!;

      expect(
        () => poll(<Object?>[_list(const <WasmComponentValueData>[])]),
        throwsStateError,
      );
    });

    test('DNS lookup remains non-blocking while an async resolver runs', () async {
      final resolved = Completer<Iterable<WASIPreview2IpAddress>>();
      final sockets = WASIPreview2SocketsHost(
        resolveAddresses: (_) => resolved.future,
      );
      final imports = sockets.imports;
      final network =
          imports['wasi:sockets/instance-network@0.2.0.instance-network']!(
                const <Object?>[],
              )!
              as int;
      final stream = _resultHandle(
        imports['wasi:sockets/ip-name-lookup@0.2.0.resolve-addresses']!(
              <Object?>[network, 'example.test'],
            )!
            as WasmComponentValueData,
      );
      final pollable =
          imports['wasi:sockets/ip-name-lookup@0.2.0.resolve-address-stream.subscribe']!(
                <Object?>[stream],
              )!
              as int;

      expect(
        _resultError(
          imports['wasi:sockets/ip-name-lookup@0.2.0.resolve-address-stream.resolve-next-address']!(
                <Object?>[stream],
              )!
              as WasmComponentValueData,
        ),
        'would-block',
      );
      expect(
        sockets.pollHost.imports['wasi:io/poll@0.2.0.pollable.ready']!(
          <Object?>[pollable],
        ),
        isFalse,
      );

      resolved.complete(<WASIPreview2IpAddress>[
        WASIPreview2IpAddress.ipv4(192, 0, 2, 1),
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(
        sockets.pollHost.imports['wasi:io/poll@0.2.0.pollable.ready']!(
          <Object?>[pollable],
        ),
        isTrue,
      );
      expect(
        _resultError(
          imports['wasi:sockets/ip-name-lookup@0.2.0.resolve-address-stream.resolve-next-address']!(
                <Object?>[stream],
              )!
              as WasmComponentValueData,
        ),
        isNull,
      );
    });

    test('DNS parses IP literals without calling the configured resolver', () {
      var resolverCalls = 0;
      final sockets = WASIPreview2SocketsHost(
        resolveAddresses: (_) {
          resolverCalls++;
          throw StateError('IP literals must not reach the resolver');
        },
      );
      final imports = sockets.imports;
      final network =
          imports['wasi:sockets/instance-network@0.2.0.instance-network']!(
                const <Object?>[],
              )!
              as int;

      for (final (name, family) in <(String, String)>[
        ('192.0.2.1', 'ipv4'),
        ('2001:db8::1', 'ipv6'),
        ('::192.0.2.1', 'ipv6'),
      ]) {
        final resolved =
            imports['wasi:sockets/ip-name-lookup@0.2.0.resolve-addresses']!(
                  <Object?>[network, name],
                )!
                as WasmComponentValueData;
        expect(_resultError(resolved), isNull, reason: name);
        final next =
            imports['wasi:sockets/ip-name-lookup@0.2.0.resolve-address-stream.resolve-next-address']!(
                  <Object?>[_resultHandle(resolved)],
                )!
                as WasmComponentValueData;
        expect(_resultError(next), isNull, reason: name);
        expect(next.associatedValue!.isSome, isTrue, reason: name);
        expect(next.associatedValue!.associatedValue!.label, family);
      }

      final mapped =
          imports['wasi:sockets/ip-name-lookup@0.2.0.resolve-addresses']!(
                <Object?>[network, '::ffff:192.0.2.1'],
              )!
              as WasmComponentValueData;
      expect(_resultError(mapped), isNull);
      expect(
        _resultError(
          imports['wasi:sockets/ip-name-lookup@0.2.0.resolve-address-stream.resolve-next-address']!(
                <Object?>[_resultHandle(mapped)],
              )!
              as WasmComponentValueData,
        ),
        'name-unresolvable',
      );

      expect(resolverCalls, 0);
    });

    test('DNS rejects malformed names before calling the resolver', () {
      var resolverCalls = 0;
      final sockets = WASIPreview2SocketsHost(
        resolveAddresses: (_) {
          resolverCalls++;
          return const <WASIPreview2IpAddress>[];
        },
      );
      final imports = sockets.imports;
      final network =
          imports['wasi:sockets/instance-network@0.2.0.instance-network']!(
                const <Object?>[],
              )!
              as int;

      for (final name in <String>[
        '',
        'bad\u0000name',
        'bad name',
        'bad..name',
        '-bad.example',
        'bad-.example',
        '2001:::1',
        '192.0.2.1::',
        '999.0.0.1',
        '😀.example',
        '€.example',
        'bad\u200d.example',
        'e\u0301.example',
        'مثالa.example',
        'xn--.example',
        'xn--a.example',
        '${List<String>.filled(64, 'a').join()}.example',
      ]) {
        final result =
            imports['wasi:sockets/ip-name-lookup@0.2.0.resolve-addresses']!(
                  <Object?>[network, name],
                )!
                as WasmComponentValueData;
        expect(_resultError(result), 'invalid-argument', reason: name);
      }

      expect(resolverCalls, 0);
    });

    test('DNS passes normalized IDNA ASCII names to the resolver', () {
      final resolvedNames = <String>[];
      final sockets = WASIPreview2SocketsHost(
        resolveAddresses: (name) {
          resolvedNames.add(name);
          return <WASIPreview2IpAddress>[
            WASIPreview2IpAddress.ipv4(192, 0, 2, 1),
          ];
        },
      );
      final imports = sockets.imports;
      final network =
          imports['wasi:sockets/instance-network@0.2.0.instance-network']!(
                const <Object?>[],
              )!
              as int;

      for (final name in <String>[
        '例子.测试',
        '例子。测试',
        '例子．测试',
        '例子｡测试',
        'BÜCHER.Example',
        'mañana.com',
        'مثال.إختبار',
        'مِثال.إختبار',
        'דוגמה.ישראל',
        'παράδειγμα.δοκιμή',
        'xn--bcher-kva.example',
        'ExAmPle.COM.',
        '123',
      ]) {
        final result =
            imports['wasi:sockets/ip-name-lookup@0.2.0.resolve-addresses']!(
                  <Object?>[network, name],
                )!
                as WasmComponentValueData;
        expect(_resultError(result), isNull, reason: name);
      }

      expect(resolvedNames, <String>[
        'xn--fsqu00a.xn--0zwm56d',
        'xn--fsqu00a.xn--0zwm56d',
        'xn--fsqu00a.xn--0zwm56d',
        'xn--fsqu00a.xn--0zwm56d',
        'xn--bcher-kva.example',
        'xn--maana-pta.com',
        'xn--mgbh0fb.xn--kgbechtv',
        'xn--mgbh0fb9c.xn--kgbechtv',
        'xn--6dbbec0c.xn--4dbrk0ce',
        'xn--hxajbheg2az3al.xn--jxalpdlp',
        'xn--bcher-kva.example',
        'example.com.',
        '123',
      ]);
    });

    test('DNS filters IPv4-mapped IPv6 resolver results', () {
      final sockets = WASIPreview2SocketsHost(
        resolveAddresses: (_) => <WASIPreview2IpAddress>[
          WASIPreview2IpAddress.ipv6(0, 0, 0, 0, 0, 0xffff, 0xc000, 0x0201),
          WASIPreview2IpAddress.ipv4(192, 0, 2, 2),
        ],
      );
      final imports = sockets.imports;
      final network =
          imports['wasi:sockets/instance-network@0.2.0.instance-network']!(
                const <Object?>[],
              )!
              as int;
      final resolved =
          imports['wasi:sockets/ip-name-lookup@0.2.0.resolve-addresses']!(
                <Object?>[network, 'example.test'],
              )!
              as WasmComponentValueData;
      final stream = _resultHandle(resolved);

      final first =
          imports['wasi:sockets/ip-name-lookup@0.2.0.resolve-address-stream.resolve-next-address']!(
                <Object?>[stream],
              )!
              as WasmComponentValueData;
      expect(_resultError(first), isNull);
      expect(first.associatedValue!.associatedValue!.label, 'ipv4');
      final exhausted =
          imports['wasi:sockets/ip-name-lookup@0.2.0.resolve-address-stream.resolve-next-address']!(
                <Object?>[stream],
              )!
              as WasmComponentValueData;
      expect(_resultError(exhausted), isNull);
      expect(exhausted.associatedValue!.isSome, isFalse);
    });

    test('DNS resolver failures preserve standardized error categories', () async {
      for (final errorCode in <String>[
        'name-unresolvable',
        'temporary-resolver-failure',
        'permanent-resolver-failure',
      ]) {
        final sockets = WASIPreview2SocketsHost(
          resolveAddresses: (_) =>
              Future<Iterable<WASIPreview2IpAddress>>.error(
                WASIPreview2AddressResolverError(errorCode),
              ),
        );
        final imports = sockets.imports;
        final network =
            imports['wasi:sockets/instance-network@0.2.0.instance-network']!(
                  const <Object?>[],
                )!
                as int;
        final resolved =
            imports['wasi:sockets/ip-name-lookup@0.2.0.resolve-addresses']!(
                  <Object?>[network, 'example.test'],
                )!
                as WasmComponentValueData;
        final stream = _resultHandle(resolved);

        expect(
          _resultError(
            imports['wasi:sockets/ip-name-lookup@0.2.0.resolve-address-stream.resolve-next-address']!(
                  <Object?>[stream],
                )!
                as WasmComponentValueData,
          ),
          'would-block',
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          _resultError(
            imports['wasi:sockets/ip-name-lookup@0.2.0.resolve-address-stream.resolve-next-address']!(
                  <Object?>[stream],
                )!
                as WasmComponentValueData,
          ),
          errorCode,
        );
      }
    });

    test('native DNS classifies Dart resolver failures', () {
      expect(
        _nativeResolverErrorCode(
          const io.SocketException(
            'Temporary failure in name resolution',
            osError: io.OSError('EAI_AGAIN', -3),
          ),
        ),
        'temporary-resolver-failure',
      );
      expect(
        _nativeResolverErrorCode(
          const io.SocketException(
            'Non-recoverable resolver failure',
            osError: io.OSError('EAI_FAIL', -4),
          ),
        ),
        'permanent-resolver-failure',
      );
      expect(
        _nativeResolverErrorCode(
          const io.SocketException('No address associated with hostname'),
        ),
        'name-unresolvable',
      );
      expect(
        _nativeResolverErrorCode(StateError('unclassified resolver failure')),
        'name-unresolvable',
      );
    });

    test('failed TCP connect leaves the socket terminally closed', () {
      final sockets = WASIPreview2SocketsHost(
        backend: const _FailingSocketsBackend(),
      );
      final imports = sockets.imports;
      final network =
          imports['wasi:sockets/instance-network@0.2.0.instance-network']!(
                const <Object?>[],
              )!
              as int;
      final socket = _resultHandle(
        imports['wasi:sockets/tcp-create-socket@0.2.0.create-tcp-socket']!(
              <Object?>[_enum('ipv4', 0)],
            )!
            as WasmComponentValueData,
      );

      expect(
        _resultError(
          imports['wasi:sockets/tcp@0.2.0.tcp-socket.start-connect']!(<Object?>[
                socket,
                network,
                _ipv4SocketAddress(port: 9),
              ])!
              as WasmComponentValueData,
        ),
        isNull,
      );
      expect(
        _resultError(
          imports['wasi:sockets/tcp@0.2.0.tcp-socket.finish-connect']!(
                <Object?>[socket],
              )!
              as WasmComponentValueData,
        ),
        'connection-refused',
      );
      expect(
        _resultError(
          imports['wasi:sockets/tcp@0.2.0.tcp-socket.start-connect']!(<Object?>[
                socket,
                network,
                _ipv4SocketAddress(port: 9),
              ])!
              as WasmComponentValueData,
        ),
        'invalid-state',
      );
    });

    test('TCP sockets share repeated instance-network handles', () {
      final sockets = WASIPreview2SocketsHost(
        backend: _ClosableSocketsBackend(),
      );
      final imports = sockets.imports;
      final firstNetwork =
          imports['wasi:sockets/instance-network@0.2.0.instance-network']!(
                const <Object?>[],
              )!
              as int;
      final secondNetwork =
          imports['wasi:sockets/instance-network@0.2.0.instance-network']!(
                const <Object?>[],
              )!
              as int;
      final socket = _resultHandle(
        imports['wasi:sockets/tcp-create-socket@0.2.0.create-tcp-socket']!(
              <Object?>[_enum('ipv4', 0)],
            )!
            as WasmComponentValueData,
      );

      expect(
        _resultError(
          imports['wasi:sockets/tcp@0.2.0.tcp-socket.start-bind']!(<Object?>[
                socket,
                0,
                _ipv4SocketAddress(port: 3000),
              ])!
              as WasmComponentValueData,
        ),
        'invalid-argument',
      );
      expect(
        _resultError(
          imports['wasi:sockets/tcp@0.2.0.tcp-socket.start-bind']!(<Object?>[
                socket,
                firstNetwork,
                _ipv4SocketAddress(port: 3000),
              ])!
              as WasmComponentValueData,
        ),
        isNull,
      );
      expect(
        _resultError(
          imports['wasi:sockets/tcp@0.2.0.tcp-socket.finish-bind']!(<Object?>[
                socket,
              ])!
              as WasmComponentValueData,
        ),
        isNull,
      );
      expect(
        _resultError(
          imports['wasi:sockets/tcp@0.2.0.tcp-socket.start-connect']!(<Object?>[
                socket,
                secondNetwork,
                _ipv4SocketAddress(port: 3001),
              ])!
              as WasmComponentValueData,
        ),
        isNull,
      );
    });

    test('half shutdown reports not-supported instead of closing both', () {
      final backend = _ClosableSocketsBackend();
      final sockets = WASIPreview2SocketsHost(backend: backend);
      final imports = sockets.imports;
      final network =
          imports['wasi:sockets/instance-network@0.2.0.instance-network']!(
                const <Object?>[],
              )!
              as int;
      final socket = _resultHandle(
        imports['wasi:sockets/tcp-create-socket@0.2.0.create-tcp-socket']!(
              <Object?>[_enum('ipv4', 0)],
            )!
            as WasmComponentValueData,
      );
      imports['wasi:sockets/tcp@0.2.0.tcp-socket.start-connect']!(<Object?>[
        socket,
        network,
        _ipv4SocketAddress(port: 8080),
      ]);
      imports['wasi:sockets/tcp@0.2.0.tcp-socket.finish-connect']!(<Object?>[
        socket,
      ]);

      for (final (label, index) in <(String, int)>[
        ('receive', 0),
        ('send', 1),
      ]) {
        expect(
          _resultError(
            imports['wasi:sockets/tcp@0.2.0.tcp-socket.shutdown']!(<Object?>[
                  socket,
                  _enum(label, index),
                ])!
                as WasmComponentValueData,
          ),
          'not-supported',
        );
      }
      expect(backend.tcpShutdowns, isEmpty);
      expect(
        _resultError(
          imports['wasi:sockets/tcp@0.2.0.tcp-socket.shutdown']!(<Object?>[
                socket,
                _enum('both', 2),
              ])!
              as WasmComponentValueData,
        ),
        isNull,
      );
      expect(backend.tcpShutdowns, ['both']);
    });

    test('a second UDP stream invalidates the previous stream pair', () {
      final sockets = WASIPreview2SocketsHost(
        backend: _ClosableSocketsBackend(),
      );
      final imports = sockets.imports;
      final network =
          imports['wasi:sockets/instance-network@0.2.0.instance-network']!(
                const <Object?>[],
              )!
              as int;
      final socket = _resultHandle(
        imports['wasi:sockets/udp-create-socket@0.2.0.create-udp-socket']!(
              <Object?>[_enum('ipv4', 0)],
            )!
            as WasmComponentValueData,
      );
      imports['wasi:sockets/udp@0.2.0.udp-socket.start-bind']!(<Object?>[
        socket,
        network,
        _ipv4SocketAddress(port: 8081),
      ]);
      imports['wasi:sockets/udp@0.2.0.udp-socket.finish-bind']!(<Object?>[
        socket,
      ]);
      final first = _resultPair(
        imports['wasi:sockets/udp@0.2.0.udp-socket.stream']!(<Object?>[
              socket,
              _some(_ipv4SocketAddress(port: 9000)),
            ])!
            as WasmComponentValueData,
      );
      final second = _resultPair(
        imports['wasi:sockets/udp@0.2.0.udp-socket.stream']!(<Object?>[
              socket,
              _none(),
            ])!
            as WasmComponentValueData,
      );

      expect(
        _resultError(
          imports['wasi:sockets/udp@0.2.0.incoming-datagram-stream.receive']!(
                <Object?>[first.$1, BigInt.one],
              )!
              as WasmComponentValueData,
        ),
        'invalid-state',
      );
      expect(
        _resultError(
          imports['wasi:sockets/udp@0.2.0.outgoing-datagram-stream.check-send']!(
                <Object?>[first.$2],
              )!
              as WasmComponentValueData,
        ),
        'invalid-state',
      );
      expect(
        _resultError(
          imports['wasi:sockets/udp@0.2.0.outgoing-datagram-stream.check-send']!(
                <Object?>[second.$2],
              )!
              as WasmComponentValueData,
        ),
        isNull,
      );
      expect(
        _resultError(
          imports['wasi:sockets/udp@0.2.0.udp-socket.remote-address']!(
                <Object?>[socket],
              )!
              as WasmComponentValueData,
        ),
        'invalid-state',
      );
    });

    test('UDP send requires and consumes a check-send permit', () {
      final binding = _SemanticsUdpBinding(sendCapacity: BigInt.one);
      final sockets = WASIPreview2SocketsHost(
        backend: _ClosableSocketsBackend(udpBindingFactory: (_) => binding),
      );
      final imports = sockets.imports;
      final streams = _boundUdpStreams(
        sockets,
        _some(_ipv4SocketAddress(port: 9000)),
      );
      final send =
          imports['wasi:sockets/udp@0.2.0.outgoing-datagram-stream.send']!;
      final checkSend =
          imports['wasi:sockets/udp@0.2.0.outgoing-datagram-stream.check-send']!;
      final datagram = _outgoingDatagram(_none());

      expect(
        () => send(<Object?>[
          streams.$3,
          _list(<WasmComponentValueData>[datagram]),
        ]),
        throwsStateError,
      );

      checkSend(<Object?>[streams.$3]);
      expect(
        () => send(<Object?>[
          streams.$3,
          _list(<WasmComponentValueData>[datagram, datagram]),
        ]),
        throwsStateError,
      );

      checkSend(<Object?>[streams.$3]);
      expect(
        _resultError(
          send(<Object?>[
                streams.$3,
                _list(<WasmComponentValueData>[datagram]),
              ])!
              as WasmComponentValueData,
        ),
        isNull,
      );
      expect(
        () => send(<Object?>[
          streams.$3,
          _list(<WasmComponentValueData>[datagram]),
        ]),
        throwsStateError,
      );
    });

    test('UDP send validates connected and unconnected destinations', () {
      final binding = _SemanticsUdpBinding(sendCapacity: BigInt.one);
      final sockets = WASIPreview2SocketsHost(
        backend: _ClosableSocketsBackend(udpBindingFactory: (_) => binding),
      );
      final imports = sockets.imports;
      final connectedAddress = _ipv4SocketAddress(port: 9000);
      final connected = _boundUdpStreams(sockets, _some(connectedAddress));
      final send =
          imports['wasi:sockets/udp@0.2.0.outgoing-datagram-stream.send']!;
      final checkSend =
          imports['wasi:sockets/udp@0.2.0.outgoing-datagram-stream.check-send']!;

      checkSend(<Object?>[connected.$3]);
      expect(
        _resultError(
          send(<Object?>[
                connected.$3,
                _list(<WasmComponentValueData>[
                  _outgoingDatagram(_some(_ipv4SocketAddress(port: 9001))),
                ]),
              ])!
              as WasmComponentValueData,
        ),
        'invalid-argument',
      );

      checkSend(<Object?>[connected.$3]);
      expect(
        _resultError(
          send(<Object?>[
                connected.$3,
                _list(<WasmComponentValueData>[_outgoingDatagram(_none())]),
              ])!
              as WasmComponentValueData,
        ),
        isNull,
      );
      expect(binding.sent.single.remoteAddress?.port, 9000);

      final unconnected = _boundUdpStreams(sockets, _none());
      checkSend(<Object?>[unconnected.$3]);
      expect(
        _resultError(
          send(<Object?>[
                unconnected.$3,
                _list(<WasmComponentValueData>[_outgoingDatagram(_none())]),
              ])!
              as WasmComponentValueData,
        ),
        'invalid-argument',
      );

      for (final invalidAddress in <WasmComponentValueData>[
        _ipv4SocketAddress(port: 0),
        _ipv4SocketAddress(port: 9002, a: 0, b: 0, c: 0, d: 0),
      ]) {
        checkSend(<Object?>[unconnected.$3]);
        expect(
          _resultError(
            send(<Object?>[
                  unconnected.$3,
                  _list(<WasmComponentValueData>[
                    _outgoingDatagram(_some(invalidAddress)),
                  ]),
                ])!
                as WasmComponentValueData,
          ),
          'invalid-argument',
        );
      }
    });

    test('UDP stream rejects an unusable remote address', () {
      final sockets = WASIPreview2SocketsHost(
        backend: _ClosableSocketsBackend(),
      );
      final imports = sockets.imports;
      final bound = _boundUdpStreams(sockets, _none());

      for (final invalidAddress in <WasmComponentValueData>[
        _ipv4SocketAddress(port: 0),
        _ipv4SocketAddress(port: 9000, a: 0, b: 0, c: 0, d: 0),
      ]) {
        expect(
          _resultError(
            imports['wasi:sockets/udp@0.2.0.udp-socket.stream']!(<Object?>[
                  bound.$1,
                  _some(invalidAddress),
                ])!
                as WasmComponentValueData,
          ),
          'invalid-argument',
        );
      }
    });

    test('UDP send reports progress before a later backend error', () {
      final binding = _SemanticsUdpBinding(
        sendCapacity: BigInt.from(2),
        failSendCall: 2,
      );
      final sockets = WASIPreview2SocketsHost(
        backend: _ClosableSocketsBackend(udpBindingFactory: (_) => binding),
      );
      final imports = sockets.imports;
      final streams = _boundUdpStreams(
        sockets,
        _some(_ipv4SocketAddress(port: 9000)),
      );
      imports['wasi:sockets/udp@0.2.0.outgoing-datagram-stream.check-send']!(
        <Object?>[streams.$3],
      );

      final result =
          imports['wasi:sockets/udp@0.2.0.outgoing-datagram-stream.send']!(
                <Object?>[
                  streams.$3,
                  _list(<WasmComponentValueData>[
                    _outgoingDatagram(_none(), data: const [1]),
                    _outgoingDatagram(_none(), data: const [2]),
                  ]),
                ],
              )!
              as WasmComponentValueData;

      expect(_resultError(result), isNull);
      expect(result.associatedValue!.integer, BigInt.one);
      expect(binding.sendCalls, 2);
    });

    test(
      'TCP connect rejects unusable remotes without starting backend I/O',
      () {
        final backend = _ClosableSocketsBackend();
        final sockets = WASIPreview2SocketsHost(backend: backend);
        final imports = sockets.imports;
        final network =
            imports['wasi:sockets/instance-network@0.2.0.instance-network']!(
                  const <Object?>[],
                )!
                as int;
        final socket = _resultHandle(
          imports['wasi:sockets/tcp-create-socket@0.2.0.create-tcp-socket']!(
                <Object?>[_enum('ipv4', 0)],
              )!
              as WasmComponentValueData,
        );

        for (final invalidAddress in <WasmComponentValueData>[
          _ipv4SocketAddress(port: 0),
          _ipv4SocketAddress(port: 9000, a: 0, b: 0, c: 0, d: 0),
          _ipv4SocketAddress(port: 9000, a: 224, b: 0, c: 0, d: 1),
          _ipv4SocketAddress(port: 9000, a: 255, b: 255, c: 255, d: 255),
        ]) {
          expect(
            _resultError(
              imports['wasi:sockets/tcp@0.2.0.tcp-socket.start-connect']!(
                    <Object?>[socket, network, invalidAddress],
                  )!
                  as WasmComponentValueData,
            ),
            'invalid-argument',
          );
        }
        expect(backend.tcpConnectCount, 0);

        final ipv6Socket = _resultHandle(
          imports['wasi:sockets/tcp-create-socket@0.2.0.create-tcp-socket']!(
                <Object?>[_enum('ipv6', 1)],
              )!
              as WasmComponentValueData,
        );
        expect(
          _resultError(
            imports['wasi:sockets/tcp@0.2.0.tcp-socket.start-connect']!(
                  <Object?>[
                    ipv6Socket,
                    network,
                    _ipv6SocketAddress(
                      port: 9000,
                      f: 0xffff,
                      g: 0xc000,
                      h: 0x0201,
                    ),
                  ],
                )!
                as WasmComponentValueData,
          ),
          'invalid-argument',
        );
        expect(backend.tcpConnectCount, 0);
        expect(
          _resultError(
            imports['wasi:sockets/tcp@0.2.0.tcp-socket.start-connect']!(
                  <Object?>[socket, network, _ipv4SocketAddress(port: 9000)],
                )!
                as WasmComponentValueData,
          ),
          isNull,
        );
        expect(backend.tcpConnectCount, 1);
      },
    );

    test(
      'TCP subscribe stays live across bind and listen state changes',
      () async {
        final bind =
            Completer<WASIPreview2SocketResult<WASIPreview2IpSocketAddress>>();
        final listen =
            Completer<WASIPreview2SocketResult<WASIPreview2TcpListener>>();
        final listener = _SemanticsTcpListener();
        final backend = _ClosableSocketsBackend(
          tcpBindFuture: bind.future,
          tcpListenFuture: listen.future,
        );
        final sockets = WASIPreview2SocketsHost(backend: backend);
        final imports = sockets.imports;
        final network =
            imports['wasi:sockets/instance-network@0.2.0.instance-network']!(
                  const <Object?>[],
                )!
                as int;
        final socket = _resultHandle(
          imports['wasi:sockets/tcp-create-socket@0.2.0.create-tcp-socket']!(
                <Object?>[_enum('ipv4', 0)],
              )!
              as WasmComponentValueData,
        );
        final pollable =
            imports['wasi:sockets/tcp@0.2.0.tcp-socket.subscribe']!(<Object?>[
                  socket,
                ])!
                as int;
        bool ready() =>
            sockets.pollHost.imports['wasi:io/poll@0.2.0.pollable.ready']!(
                  <Object?>[pollable],
                )!
                as bool;

        expect(ready(), isTrue);
        imports['wasi:sockets/tcp@0.2.0.tcp-socket.start-bind']!(<Object?>[
          socket,
          network,
          _ipv4SocketAddress(port: 8080),
        ]);
        expect(ready(), isFalse);
        bind.complete(
          WASIPreview2SocketResult<WASIPreview2IpSocketAddress>.ok(
            WASIPreview2IpSocketAddress.ipv4(
              port: 8080,
              a: 127,
              b: 0,
              c: 0,
              d: 1,
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(ready(), isTrue);
        expect(
          _resultError(
            imports['wasi:sockets/tcp@0.2.0.tcp-socket.finish-bind']!(<Object?>[
                  socket,
                ])!
                as WasmComponentValueData,
          ),
          isNull,
        );

        imports['wasi:sockets/tcp@0.2.0.tcp-socket.start-listen']!(<Object?>[
          socket,
        ]);
        expect(ready(), isFalse);
        listen.complete(
          WASIPreview2SocketResult<WASIPreview2TcpListener>.ok(listener),
        );
        await Future<void>.delayed(Duration.zero);
        expect(ready(), isTrue);
        expect(
          _resultError(
            imports['wasi:sockets/tcp@0.2.0.tcp-socket.finish-listen']!(
                  <Object?>[socket],
                )!
                as WasmComponentValueData,
          ),
          isNull,
        );
        expect(ready(), isFalse);
        listener.ready = true;
        expect(ready(), isTrue);
      },
    );

    test(
      'UDP subscribe stays live across bind and I/O state changes',
      () async {
        final bind =
            Completer<WASIPreview2SocketResult<WASIPreview2UdpBinding>>();
        final binding = _SemanticsUdpBinding(
          sendCapacity: BigInt.one,
          sendReady: false,
        );
        final backend = _ClosableSocketsBackend(udpBindFuture: bind.future);
        final sockets = WASIPreview2SocketsHost(backend: backend);
        final imports = sockets.imports;
        final network =
            imports['wasi:sockets/instance-network@0.2.0.instance-network']!(
                  const <Object?>[],
                )!
                as int;
        final socket = _resultHandle(
          imports['wasi:sockets/udp-create-socket@0.2.0.create-udp-socket']!(
                <Object?>[_enum('ipv4', 0)],
              )!
              as WasmComponentValueData,
        );
        final pollable =
            imports['wasi:sockets/udp@0.2.0.udp-socket.subscribe']!(<Object?>[
                  socket,
                ])!
                as int;
        bool ready() =>
            sockets.pollHost.imports['wasi:io/poll@0.2.0.pollable.ready']!(
                  <Object?>[pollable],
                )!
                as bool;

        expect(ready(), isTrue);
        imports['wasi:sockets/udp@0.2.0.udp-socket.start-bind']!(<Object?>[
          socket,
          network,
          _ipv4SocketAddress(port: 8081),
        ]);
        expect(ready(), isFalse);
        bind.complete(
          WASIPreview2SocketResult<WASIPreview2UdpBinding>.ok(binding),
        );
        await Future<void>.delayed(Duration.zero);
        expect(ready(), isTrue);
        expect(
          _resultError(
            imports['wasi:sockets/udp@0.2.0.udp-socket.finish-bind']!(<Object?>[
                  socket,
                ])!
                as WasmComponentValueData,
          ),
          isNull,
        );
        expect(ready(), isFalse);
        binding.sendReady = true;
        expect(ready(), isTrue);
      },
    );

    test('socket subscriptions keep their parent sockets live', () {
      final sockets = WASIPreview2SocketsHost();
      final imports = sockets.imports;
      final tcp = _resultHandle(
        imports['wasi:sockets/tcp-create-socket@0.2.0.create-tcp-socket']!(
              <Object?>[_enum('ipv4', 0)],
            )!
            as WasmComponentValueData,
      );
      final udp = _resultHandle(
        imports['wasi:sockets/udp-create-socket@0.2.0.create-udp-socket']!(
              <Object?>[_enum('ipv4', 0)],
            )!
            as WasmComponentValueData,
      );
      final tcpPollable =
          imports['wasi:sockets/tcp@0.2.0.tcp-socket.subscribe']!(<Object?>[
                tcp,
              ])!
              as int;
      final udpPollable =
          imports['wasi:sockets/udp@0.2.0.udp-socket.subscribe']!(<Object?>[
                udp,
              ])!
              as int;

      expect(
        () => sockets.table.dropNamed('wasi:sockets/tcp@0.2.0.tcp-socket', tcp),
        throwsStateError,
      );
      expect(
        () => sockets.table.dropNamed('wasi:sockets/udp@0.2.0.udp-socket', udp),
        throwsStateError,
      );

      sockets.table.dropNamed('wasi:io/poll@0.2.0.pollable', tcpPollable);
      sockets.table.dropNamed('wasi:io/poll@0.2.0.pollable', udpPollable);
      sockets.table.dropNamed('wasi:sockets/tcp@0.2.0.tcp-socket', tcp);
      sockets.table.dropNamed('wasi:sockets/udp@0.2.0.udp-socket', udp);
    });

    test('connected TCP streams keep their socket live', () {
      final backend = _ClosableSocketsBackend();
      final sockets = WASIPreview2SocketsHost(backend: backend);
      final imports = sockets.imports;
      final network =
          imports['wasi:sockets/instance-network@0.2.0.instance-network']!(
                const <Object?>[],
              )!
              as int;
      final socket = _resultHandle(
        imports['wasi:sockets/tcp-create-socket@0.2.0.create-tcp-socket']!(
              <Object?>[_enum('ipv4', 0)],
            )!
            as WasmComponentValueData,
      );
      imports['wasi:sockets/tcp@0.2.0.tcp-socket.start-connect']!(<Object?>[
        socket,
        network,
        _ipv4SocketAddress(port: 8080),
      ]);
      final streams = _resultPair(
        imports['wasi:sockets/tcp@0.2.0.tcp-socket.finish-connect']!(<Object?>[
              socket,
            ])!
            as WasmComponentValueData,
      );
      final inputPollable =
          sockets
                  .streamsHost
                  .imports['wasi:io/streams@0.2.0.input-stream.subscribe']!(
                <Object?>[streams.$1],
              )!
              as int;
      final outputPollable =
          sockets
                  .streamsHost
                  .imports['wasi:io/streams@0.2.0.output-stream.subscribe']!(
                <Object?>[streams.$2],
              )!
              as int;

      expect(
        () => sockets.table.dropNamed(
          'wasi:sockets/tcp@0.2.0.tcp-socket',
          socket,
        ),
        throwsStateError,
      );
      expect(
        () => sockets.table.dropNamed(
          'wasi:io/streams@0.2.0.input-stream',
          streams.$1,
        ),
        throwsStateError,
      );
      expect(
        () => sockets.table.dropNamed(
          'wasi:io/streams@0.2.0.output-stream',
          streams.$2,
        ),
        throwsStateError,
      );

      sockets.table.dropNamed('wasi:io/poll@0.2.0.pollable', inputPollable);
      sockets.table.dropNamed('wasi:io/poll@0.2.0.pollable', outputPollable);
      sockets.table.dropNamed('wasi:io/streams@0.2.0.input-stream', streams.$1);
      sockets.table.dropNamed(
        'wasi:io/streams@0.2.0.output-stream',
        streams.$2,
      );
      sockets.table.dropNamed('wasi:sockets/tcp@0.2.0.tcp-socket', socket);
      expect(backend.tcpShutdowns, ['both']);
    });

    test('accepted TCP streams keep their connected socket live', () async {
      final listener = _SemanticsTcpListener(_testTcpConnection());
      final backend = _ClosableSocketsBackend(
        tcpListenFuture: Future.value(
          WASIPreview2SocketResult<WASIPreview2TcpListener>.ok(listener),
        ),
      );
      final sockets = WASIPreview2SocketsHost(backend: backend);
      final imports = sockets.imports;
      final network =
          imports['wasi:sockets/instance-network@0.2.0.instance-network']!(
                const <Object?>[],
              )!
              as int;
      final listeningSocket = _resultHandle(
        imports['wasi:sockets/tcp-create-socket@0.2.0.create-tcp-socket']!(
              <Object?>[_enum('ipv4', 0)],
            )!
            as WasmComponentValueData,
      );
      imports['wasi:sockets/tcp@0.2.0.tcp-socket.start-bind']!(<Object?>[
        listeningSocket,
        network,
        _ipv4SocketAddress(port: 8080),
      ]);
      imports['wasi:sockets/tcp@0.2.0.tcp-socket.finish-bind']!(<Object?>[
        listeningSocket,
      ]);
      imports['wasi:sockets/tcp@0.2.0.tcp-socket.start-listen']!(<Object?>[
        listeningSocket,
      ]);
      await Future<void>.delayed(Duration.zero);
      final finishListen =
          imports['wasi:sockets/tcp@0.2.0.tcp-socket.finish-listen']!(<Object?>[
                listeningSocket,
              ])!
              as WasmComponentValueData;
      expect(_resultError(finishListen), isNull);
      final accepted = _resultTriple(
        imports['wasi:sockets/tcp@0.2.0.tcp-socket.accept']!(<Object?>[
              listeningSocket,
            ])!
            as WasmComponentValueData,
      );

      expect(
        () => sockets.table.dropNamed(
          'wasi:sockets/tcp@0.2.0.tcp-socket',
          accepted.$1,
        ),
        throwsStateError,
      );
      sockets.table.dropNamed(
        'wasi:io/streams@0.2.0.input-stream',
        accepted.$2,
      );
      sockets.table.dropNamed(
        'wasi:io/streams@0.2.0.output-stream',
        accepted.$3,
      );
      sockets.table.dropNamed('wasi:sockets/tcp@0.2.0.tcp-socket', accepted.$1);
      sockets.table.dropNamed(
        'wasi:sockets/tcp@0.2.0.tcp-socket',
        listeningSocket,
      );
    });

    test('UDP stream pollables keep streams and their socket live', () {
      final sockets = WASIPreview2SocketsHost(
        backend: _ClosableSocketsBackend(),
      );
      final imports = sockets.imports;
      final streams = _boundUdpStreams(sockets, _none());
      final socketPollable =
          imports['wasi:sockets/udp@0.2.0.udp-socket.subscribe']!(<Object?>[
                streams.$1,
              ])!
              as int;
      final incomingPollable =
          imports['wasi:sockets/udp@0.2.0.incoming-datagram-stream.subscribe']!(
                <Object?>[streams.$2],
              )!
              as int;
      final outgoingPollable =
          imports['wasi:sockets/udp@0.2.0.outgoing-datagram-stream.subscribe']!(
                <Object?>[streams.$3],
              )!
              as int;

      expect(
        () => sockets.table.dropNamed(
          'wasi:sockets/udp@0.2.0.udp-socket',
          streams.$1,
        ),
        throwsStateError,
      );
      expect(
        () => sockets.table.dropNamed(
          'wasi:sockets/udp@0.2.0.incoming-datagram-stream',
          streams.$2,
        ),
        throwsStateError,
      );
      expect(
        () => sockets.table.dropNamed(
          'wasi:sockets/udp@0.2.0.outgoing-datagram-stream',
          streams.$3,
        ),
        throwsStateError,
      );

      sockets.table.dropNamed('wasi:io/poll@0.2.0.pollable', socketPollable);
      sockets.table.dropNamed('wasi:io/poll@0.2.0.pollable', incomingPollable);
      sockets.table.dropNamed('wasi:io/poll@0.2.0.pollable', outgoingPollable);
      sockets.table.dropNamed(
        'wasi:sockets/udp@0.2.0.incoming-datagram-stream',
        streams.$2,
      );
      sockets.table.dropNamed(
        'wasi:sockets/udp@0.2.0.outgoing-datagram-stream',
        streams.$3,
      );
      sockets.table.dropNamed('wasi:sockets/udp@0.2.0.udp-socket', streams.$1);
    });

    test('socket child resources clean up in dependency order', () async {
      final table = WASIComponentResourceTable();
      final backend = _ClosableSocketsBackend();
      final sockets = WASIPreview2SocketsHost(table: table, backend: backend);
      await table.runScoped(() {
        final imports = sockets.imports;
        final network =
            imports['wasi:sockets/instance-network@0.2.0.instance-network']!(
                  const <Object?>[],
                )!
                as int;
        final tcp = _resultHandle(
          imports['wasi:sockets/tcp-create-socket@0.2.0.create-tcp-socket']!(
                <Object?>[_enum('ipv4', 0)],
              )!
              as WasmComponentValueData,
        );
        imports['wasi:sockets/tcp@0.2.0.tcp-socket.start-connect']!(<Object?>[
          tcp,
          network,
          _ipv4SocketAddress(port: 8080),
        ]);
        final tcpStreams = _resultPair(
          imports['wasi:sockets/tcp@0.2.0.tcp-socket.finish-connect']!(
                <Object?>[tcp],
              )!
              as WasmComponentValueData,
        );
        sockets
            .streamsHost
            .imports['wasi:io/streams@0.2.0.input-stream.subscribe']!(<Object?>[
          tcpStreams.$1,
        ]);
        sockets
            .streamsHost
            .imports['wasi:io/streams@0.2.0.output-stream.subscribe']!(
          <Object?>[tcpStreams.$2],
        );

        final udp = _resultHandle(
          imports['wasi:sockets/udp-create-socket@0.2.0.create-udp-socket']!(
                <Object?>[_enum('ipv4', 0)],
              )!
              as WasmComponentValueData,
        );
        imports['wasi:sockets/udp@0.2.0.udp-socket.start-bind']!(<Object?>[
          udp,
          network,
          _ipv4SocketAddress(port: 8081),
        ]);
        imports['wasi:sockets/udp@0.2.0.udp-socket.finish-bind']!(<Object?>[
          udp,
        ]);
        final udpStreams = _resultPair(
          imports['wasi:sockets/udp@0.2.0.udp-socket.stream']!(<Object?>[
                udp,
                _none(),
              ])!
              as WasmComponentValueData,
        );
        imports['wasi:sockets/udp@0.2.0.incoming-datagram-stream.subscribe']!(
          <Object?>[udpStreams.$1],
        );
        imports['wasi:sockets/udp@0.2.0.outgoing-datagram-stream.subscribe']!(
          <Object?>[udpStreams.$2],
        );
      });

      expect(table.activeCount, 0);
      expect(backend.tcpShutdowns, ['both']);
      expect(backend.udpCloseCount, 1);
    });

    test('native UDP receive accepts the maximum u64 result count', () async {
      final sockets = WASIPreview2NativeSocketsHost();
      final imports = sockets.imports;
      final network =
          imports['wasi:sockets/instance-network@0.2.0.instance-network']!(
                const <Object?>[],
              )!
              as int;
      final socket = _resultHandle(
        imports['wasi:sockets/udp-create-socket@0.2.0.create-udp-socket']!(
              <Object?>[_enum('ipv4', 0)],
            )!
            as WasmComponentValueData,
      );
      expect(
        _resultError(
          imports['wasi:sockets/udp@0.2.0.udp-socket.start-bind']!(<Object?>[
                socket,
                network,
                _ipv4SocketAddress(port: 0),
              ])!
              as WasmComponentValueData,
        ),
        isNull,
      );
      expect(_resultError(await _finishUdpBind(sockets, socket)), isNull);
      final streams = _resultPair(
        imports['wasi:sockets/udp@0.2.0.udp-socket.stream']!(<Object?>[
              socket,
              _none(),
            ])!
            as WasmComponentValueData,
      );

      final result =
          imports['wasi:sockets/udp@0.2.0.incoming-datagram-stream.receive']!(
                <Object?>[streams.$1, (BigInt.one << 64) - BigInt.one],
              )!
              as WasmComponentValueData;

      expect(_resultError(result), isNull);
      expect(result.associatedValue!.items, isEmpty);
      sockets.table.dropNamed(
        'wasi:sockets/udp@0.2.0.incoming-datagram-stream',
        streams.$1,
      );
      sockets.table.dropNamed(
        'wasi:sockets/udp@0.2.0.outgoing-datagram-stream',
        streams.$2,
      );
      sockets.table.dropNamed('wasi:sockets/udp@0.2.0.udp-socket', socket);
    });

    test('native listener termination preserves queued connections', () async {
      final backend = _nativeSocketsBackend();
      final operation = backend.startTcpListen(
        localAddress: WASIPreview2IpSocketAddress.ipv4(
          port: 0,
          a: 127,
          b: 0,
          c: 0,
          d: 1,
        ),
        backlog: BigInt.one,
      );
      await operation.waitReady();
      final result = operation.resultOrNull!;
      expect(result.isOk, isTrue, reason: result.errorCode);
      final listener = result.value!;
      final client = await io.Socket.connect(
        io.InternetAddress.loopbackIPv4,
        listener.localAddress.port,
      );
      final clientClosed = Completer<void>();
      client.listen(
        (_) {},
        onDone: clientClosed.complete,
        onError: (Object _) {
          if (!clientClosed.isCompleted) {
            clientClosed.complete();
          }
        },
      );
      addTearDown(client.destroy);
      await listener.waitAccept();
      expect(listener.canAccept, isTrue);

      await _nativeListenerServer(listener).close();
      await _waitUntil(() => _nativeListenerClosed(listener));

      final accept = listener.accept();
      expect(accept.isOk, isTrue, reason: accept.errorCode);
      accept.value!.dispose!();
      await clientClosed.future.timeout(const Duration(seconds: 5));
      final exhausted = listener.accept();
      expect(exhausted.isOk, isFalse);
      expect(exhausted.errorCode, 'connection-aborted');
    });

    test('dropping TCP and UDP socket resources closes their backends', () {
      final backend = _ClosableSocketsBackend();
      final sockets = WASIPreview2SocketsHost(backend: backend);
      final imports = sockets.imports;
      final network =
          imports['wasi:sockets/instance-network@0.2.0.instance-network']!(
                const <Object?>[],
              )!
              as int;
      final tcp = _resultHandle(
        imports['wasi:sockets/tcp-create-socket@0.2.0.create-tcp-socket']!(
              <Object?>[_enum('ipv4', 0)],
            )!
            as WasmComponentValueData,
      );
      final udp = _resultHandle(
        imports['wasi:sockets/udp-create-socket@0.2.0.create-udp-socket']!(
              <Object?>[_enum('ipv4', 0)],
            )!
            as WasmComponentValueData,
      );

      imports['wasi:sockets/tcp@0.2.0.tcp-socket.start-connect']!(<Object?>[
        tcp,
        network,
        _ipv4SocketAddress(port: 8080),
      ]);
      final tcpStreams = _resultPair(
        imports['wasi:sockets/tcp@0.2.0.tcp-socket.finish-connect']!(<Object?>[
              tcp,
            ])!
            as WasmComponentValueData,
      );
      imports['wasi:sockets/udp@0.2.0.udp-socket.start-bind']!(<Object?>[
        udp,
        network,
        _ipv4SocketAddress(port: 8081),
      ]);
      imports['wasi:sockets/udp@0.2.0.udp-socket.finish-bind']!(<Object?>[udp]);

      sockets.table.dropNamed(
        'wasi:io/streams@0.2.0.input-stream',
        tcpStreams.$1,
      );
      sockets.table.dropNamed(
        'wasi:io/streams@0.2.0.output-stream',
        tcpStreams.$2,
      );
      sockets.table.dropNamed('wasi:sockets/tcp@0.2.0.tcp-socket', tcp);
      sockets.table.dropNamed('wasi:sockets/udp@0.2.0.udp-socket', udp);

      expect(backend.tcpShutdowns, ['both']);
      expect(backend.udpCloseCount, 1);
    });

    test('native TCP bind and socket options do not report fake success', () {
      final sockets = WASIPreview2NativeSocketsHost();
      final imports = sockets.imports;
      final network =
          imports['wasi:sockets/instance-network@0.2.0.instance-network']!(
                const <Object?>[],
              )!
              as int;
      final tcp = _resultHandle(
        imports['wasi:sockets/tcp-create-socket@0.2.0.create-tcp-socket']!(
              <Object?>[_enum('ipv4', 0)],
            )!
            as WasmComponentValueData,
      );
      final udp = _resultHandle(
        imports['wasi:sockets/udp-create-socket@0.2.0.create-udp-socket']!(
              <Object?>[_enum('ipv4', 0)],
            )!
            as WasmComponentValueData,
      );

      expect(
        _resultError(
          imports['wasi:sockets/tcp@0.2.0.tcp-socket.start-bind']!(<Object?>[
                tcp,
                network,
                _ipv4SocketAddress(port: 0),
              ])!
              as WasmComponentValueData,
        ),
        'not-supported',
      );
      expect(
        _resultError(
          imports['wasi:sockets/tcp@0.2.0.tcp-socket.set-hop-limit']!(<Object?>[
                tcp,
                64,
              ])!
              as WasmComponentValueData,
        ),
        'not-supported',
      );
      expect(
        _resultError(
          imports['wasi:sockets/udp@0.2.0.udp-socket.set-unicast-hop-limit']!(
                <Object?>[udp, 64],
              )!
              as WasmComponentValueData,
        ),
        'not-supported',
      );
    });

    test(
      'native TCP send shutdown flushes and socket drops close OS resources',
      () async {
        final server = await io.ServerSocket.bind(
          io.InternetAddress.loopbackIPv4,
          0,
        );
        final accepted = Completer<io.Socket>();
        final serverSubscription = server.listen(accepted.complete);
        addTearDown(() async {
          await serverSubscription.cancel();
          await server.close();
        });

        final sockets = WASIPreview2NativeSocketsHost();
        final imports = sockets.imports;
        final network =
            imports['wasi:sockets/instance-network@0.2.0.instance-network']!(
                  const <Object?>[],
                )!
                as int;
        final tcp = _resultHandle(
          imports['wasi:sockets/tcp-create-socket@0.2.0.create-tcp-socket']!(
                <Object?>[_enum('ipv4', 0)],
              )!
              as WasmComponentValueData,
        );
        expect(
          _resultError(
            imports['wasi:sockets/tcp@0.2.0.tcp-socket.start-connect']!(
                  <Object?>[
                    tcp,
                    network,
                    _ipv4SocketAddress(port: server.port),
                  ],
                )!
                as WasmComponentValueData,
          ),
          isNull,
        );
        final tcpFinish = await _finishTcpConnect(sockets, tcp);
        expect(_resultError(tcpFinish), isNull);
        final tcpStreams = _resultPair(tcpFinish);
        final peer = await accepted.future.timeout(const Duration(seconds: 5));
        final peerReceived = Completer<List<int>>();
        final received = <int>[];
        peer.listen(
          received.addAll,
          onDone: () => peerReceived.complete(List<int>.of(received)),
          onError: (Object error, StackTrace stackTrace) {
            if (!peerReceived.isCompleted) {
              peerReceived.completeError(error, stackTrace);
            }
          },
        );
        addTearDown(peer.destroy);

        const sentBeforeShutdown = <int>[1, 2, 3, 4];
        final write =
            sockets
                    .streamsHost
                    .imports['wasi:io/streams@0.2.0.output-stream.blocking-write-and-flush']!(
                  <Object?>[
                    tcpStreams.$2,
                    _list(<WasmComponentValueData>[
                      for (final byte in sentBeforeShutdown) _integer(byte),
                    ]),
                  ],
                )!
                as WasmComponentValueData;
        expect(_resultError(write), isNull);

        expect(
          _resultError(
            imports['wasi:sockets/tcp@0.2.0.tcp-socket.shutdown']!(<Object?>[
                  tcp,
                  _enum('send', 1),
                ])!
                as WasmComponentValueData,
          ),
          isNull,
        );
        expect(
          await peerReceived.future.timeout(const Duration(seconds: 5)),
          sentBeforeShutdown,
        );

        const receivedAfterShutdown = <int>[9, 8, 7];
        peer.add(receivedAfterShutdown);
        await peer.flush();
        await _waitUntil(
          () => sockets.streamsHost.inputStream(tcpStreams.$1).isReadable,
        );
        final read =
            sockets
                    .streamsHost
                    .imports['wasi:io/streams@0.2.0.input-stream.read']!(
                  <Object?>[
                    tcpStreams.$1,
                    BigInt.from(receivedAfterShutdown.length),
                  ],
                )!
                as WasmComponentValueData;
        expect(_resultError(read), isNull);
        expect(
          read.associatedValue!.items
              .map((byte) => (byte.integer! as num).toInt())
              .toList(growable: false),
          receivedAfterShutdown,
        );
        sockets.table.dropNamed(
          'wasi:io/streams@0.2.0.input-stream',
          tcpStreams.$1,
        );
        sockets.table.dropNamed(
          'wasi:io/streams@0.2.0.output-stream',
          tcpStreams.$2,
        );
        sockets.table.dropNamed('wasi:sockets/tcp@0.2.0.tcp-socket', tcp);

        final reservation = await io.RawDatagramSocket.bind(
          io.InternetAddress.loopbackIPv4,
          0,
        );
        final port = reservation.port;
        reservation.close();
        await Future<void>.delayed(Duration.zero);
        final udp = _resultHandle(
          imports['wasi:sockets/udp-create-socket@0.2.0.create-udp-socket']!(
                <Object?>[_enum('ipv4', 0)],
              )!
              as WasmComponentValueData,
        );
        expect(
          _resultError(
            imports['wasi:sockets/udp@0.2.0.udp-socket.start-bind']!(<Object?>[
                  udp,
                  network,
                  _ipv4SocketAddress(port: port),
                ])!
                as WasmComponentValueData,
          ),
          isNull,
        );
        expect(_resultError(await _finishUdpBind(sockets, udp)), isNull);
        sockets.table.dropNamed('wasi:sockets/udp@0.2.0.udp-socket', udp);
        await Future<void>.delayed(Duration.zero);

        final rebound = await _bindUdpEventually(port);
        rebound.close();
      },
    );
  });
}

final class _CountingRandom implements math.Random {
  int nextIntCalls = 0;

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;

  @override
  int nextInt(int max) {
    nextIntCalls++;
    return 0;
  }
}

Future<io.RawDatagramSocket> _bindUdpEventually(int port) async {
  for (var attempt = 0; ; attempt++) {
    try {
      return await io.RawDatagramSocket.bind(
        io.InternetAddress.loopbackIPv4,
        port,
      );
    } on io.SocketException {
      if (attempt == 19) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}

final class _FailingSocketsBackend implements WASIPreview2SocketsBackend {
  const _FailingSocketsBackend();

  @override
  WASIPreview2SocketOperation<WASIPreview2IpSocketAddress> startTcpBind(
    WASIPreview2IpSocketAddress localAddress,
  ) => WASIPreview2SocketOperation<WASIPreview2IpSocketAddress>.completed(
    WASIPreview2SocketResult<WASIPreview2IpSocketAddress>.ok(localAddress),
  );

  @override
  WASIPreview2SocketOperation<WASIPreview2TcpConnection> startTcpConnect({
    required WASIPreview2IpSocketAddress remoteAddress,
    WASIPreview2IpSocketAddress? localAddress,
  }) => WASIPreview2SocketOperation<WASIPreview2TcpConnection>.completed(
    const WASIPreview2SocketResult<WASIPreview2TcpConnection>.error(
      'connection-refused',
    ),
  );

  @override
  WASIPreview2SocketOperation<WASIPreview2TcpListener> startTcpListen({
    required WASIPreview2IpSocketAddress localAddress,
    required BigInt backlog,
  }) => WASIPreview2SocketOperation<WASIPreview2TcpListener>.completed(
    const WASIPreview2SocketResult<WASIPreview2TcpListener>.error(
      'not-supported',
    ),
  );

  @override
  WASIPreview2SocketOperation<WASIPreview2UdpBinding> startUdpBind(
    WASIPreview2IpSocketAddress localAddress,
  ) => WASIPreview2SocketOperation<WASIPreview2UdpBinding>.completed(
    const WASIPreview2SocketResult<WASIPreview2UdpBinding>.error(
      'not-supported',
    ),
  );
}

final class _ClosableSocketsBackend implements WASIPreview2SocketsBackend {
  _ClosableSocketsBackend({
    this.udpBindingFactory,
    this.tcpBindFuture,
    this.tcpListenFuture,
    this.udpBindFuture,
  });

  final WASIPreview2UdpBinding Function(WASIPreview2IpSocketAddress address)?
  udpBindingFactory;
  final Future<WASIPreview2SocketResult<WASIPreview2IpSocketAddress>>?
  tcpBindFuture;
  final Future<WASIPreview2SocketResult<WASIPreview2TcpListener>>?
  tcpListenFuture;
  final Future<WASIPreview2SocketResult<WASIPreview2UdpBinding>>? udpBindFuture;
  final List<String> tcpShutdowns = <String>[];
  int tcpConnectCount = 0;
  int udpCloseCount = 0;

  @override
  WASIPreview2SocketOperation<WASIPreview2IpSocketAddress> startTcpBind(
    WASIPreview2IpSocketAddress localAddress,
  ) {
    final future = tcpBindFuture;
    return future == null
        ? WASIPreview2SocketOperation<WASIPreview2IpSocketAddress>.completed(
            WASIPreview2SocketResult<WASIPreview2IpSocketAddress>.ok(
              localAddress,
            ),
          )
        : WASIPreview2SocketOperation<WASIPreview2IpSocketAddress>.pending(
            future,
          );
  }

  @override
  WASIPreview2SocketOperation<WASIPreview2TcpConnection> startTcpConnect({
    required WASIPreview2IpSocketAddress remoteAddress,
    WASIPreview2IpSocketAddress? localAddress,
  }) {
    tcpConnectCount++;
    return WASIPreview2SocketOperation<WASIPreview2TcpConnection>.completed(
      WASIPreview2SocketResult<WASIPreview2TcpConnection>.ok(
        WASIPreview2TcpConnection(
          inputStream: WASIPreview2InputStream(closed: true),
          outputStream: WASIPreview2OutputStream(),
          localAddress: WASIPreview2IpSocketAddress.ipv4(
            port: 3000,
            a: 127,
            b: 0,
            c: 0,
            d: 1,
          ),
          remoteAddress: remoteAddress,
          close: tcpShutdowns.add,
        ),
      ),
    );
  }

  @override
  WASIPreview2SocketOperation<WASIPreview2TcpListener> startTcpListen({
    required WASIPreview2IpSocketAddress localAddress,
    required BigInt backlog,
  }) {
    final future = tcpListenFuture;
    return future == null
        ? WASIPreview2SocketOperation<WASIPreview2TcpListener>.completed(
            const WASIPreview2SocketResult<WASIPreview2TcpListener>.error(
              'not-supported',
            ),
          )
        : WASIPreview2SocketOperation<WASIPreview2TcpListener>.pending(future);
  }

  @override
  WASIPreview2SocketOperation<WASIPreview2UdpBinding> startUdpBind(
    WASIPreview2IpSocketAddress localAddress,
  ) {
    final future = udpBindFuture;
    return future == null
        ? WASIPreview2SocketOperation<WASIPreview2UdpBinding>.completed(
            WASIPreview2SocketResult<WASIPreview2UdpBinding>.ok(
              udpBindingFactory?.call(localAddress) ??
                  _ClosableUdpBinding(localAddress, () => udpCloseCount++),
            ),
          )
        : WASIPreview2SocketOperation<WASIPreview2UdpBinding>.pending(future);
  }
}

final class _SemanticsTcpListener implements WASIPreview2TcpListener {
  _SemanticsTcpListener([WASIPreview2TcpConnection? connection])
    : _connection = connection,
      ready = connection != null;

  WASIPreview2TcpConnection? _connection;
  bool ready;

  @override
  WASIPreview2IpSocketAddress get localAddress =>
      WASIPreview2IpSocketAddress.ipv4(port: 8080, a: 127, b: 0, c: 0, d: 1);

  @override
  bool get canAccept => ready;

  @override
  Future<void> waitAccept() => Future<void>.value();

  @override
  WASIPreview2SocketResult<WASIPreview2TcpConnection> accept() {
    final connection = _connection;
    if (connection == null) {
      return const WASIPreview2SocketResult<WASIPreview2TcpConnection>.error(
        'would-block',
      );
    }
    _connection = null;
    ready = false;
    return WASIPreview2SocketResult<WASIPreview2TcpConnection>.ok(connection);
  }

  @override
  void close() {}
}

final class _SemanticsUdpBinding implements WASIPreview2UdpBinding {
  _SemanticsUdpBinding({
    required this.sendCapacity,
    this.failSendCall,
    this.sendReady = true,
  }) : localAddress = WASIPreview2IpSocketAddress.ipv4(
         port: 8081,
         a: 127,
         b: 0,
         c: 0,
         d: 1,
       );

  @override
  final WASIPreview2IpSocketAddress localAddress;

  @override
  WASIPreview2IpSocketAddress? get remoteAddress => null;

  @override
  final BigInt sendCapacity;

  final int? failSendCall;
  final List<WASIPreview2OutgoingDatagram> sent = [];
  int sendCalls = 0;
  bool sendReady;

  @override
  bool get canReceive => false;

  @override
  bool get canSend => sendReady;

  @override
  Future<void> waitReceive() => Future<void>.value();

  @override
  Future<void> waitSend() => Future<void>.value();

  @override
  WASIPreview2SocketResult<List<WASIPreview2IncomingDatagram>> receive(
    BigInt maxResults,
  ) => const WASIPreview2SocketResult<List<WASIPreview2IncomingDatagram>>.ok(
    <WASIPreview2IncomingDatagram>[],
  );

  @override
  WASIPreview2SocketResult<BigInt> send(
    List<WASIPreview2OutgoingDatagram> datagrams,
  ) {
    sendCalls++;
    if (sendCalls == failSendCall) {
      return const WASIPreview2SocketResult<BigInt>.error('remote-unreachable');
    }
    sent.addAll(datagrams);
    return WASIPreview2SocketResult<BigInt>.ok(BigInt.from(datagrams.length));
  }

  @override
  void close() {}
}

final class _ClosableUdpBinding implements WASIPreview2UdpBinding {
  const _ClosableUdpBinding(this.localAddress, this._onClose);

  final void Function() _onClose;

  @override
  final WASIPreview2IpSocketAddress localAddress;

  @override
  WASIPreview2IpSocketAddress? get remoteAddress => null;

  @override
  BigInt get sendCapacity => BigInt.one;

  @override
  bool get canReceive => false;

  @override
  bool get canSend => true;

  @override
  Future<void> waitReceive() => Future<void>.value();

  @override
  Future<void> waitSend() => Future<void>.value();

  @override
  WASIPreview2SocketResult<List<WASIPreview2IncomingDatagram>> receive(
    BigInt maxResults,
  ) => const WASIPreview2SocketResult<List<WASIPreview2IncomingDatagram>>.ok(
    <WASIPreview2IncomingDatagram>[],
  );

  @override
  WASIPreview2SocketResult<BigInt> send(
    List<WASIPreview2OutgoingDatagram> datagrams,
  ) => WASIPreview2SocketResult<BigInt>.ok(BigInt.from(datagrams.length));

  @override
  void close() => _onClose();
}

WasmComponentValueData _enum(String label, int index) => WasmComponentValueData(
  kind: WasmComponentValueDataKind.enumeration,
  rawBytes: Uint8List(0),
  label: label,
  index: index,
);

WasmComponentValueData _integer(Object value) => WasmComponentValueData(
  kind: WasmComponentValueDataKind.integer,
  rawBytes: Uint8List(0),
  integer: value,
);

WasmComponentValueData _tuple(List<WasmComponentValueData> items) =>
    WasmComponentValueData(
      kind: WasmComponentValueDataKind.tuple,
      rawBytes: Uint8List(0),
      items: items,
    );

WasmComponentValueData _record(List<WasmComponentValueData> items) =>
    WasmComponentValueData(
      kind: WasmComponentValueDataKind.record,
      rawBytes: Uint8List(0),
      items: items,
    );

WasmComponentValueData _variant(
  String label,
  int index,
  WasmComponentValueData value,
) => WasmComponentValueData(
  kind: WasmComponentValueDataKind.variant,
  rawBytes: Uint8List(0),
  label: label,
  index: index,
  associatedValue: value,
);

WasmComponentValueData _list(List<WasmComponentValueData> items) =>
    WasmComponentValueData(
      kind: WasmComponentValueDataKind.list,
      rawBytes: Uint8List(0),
      items: items,
    );

WasmComponentValueData _none() => WasmComponentValueData(
  kind: WasmComponentValueDataKind.option,
  rawBytes: Uint8List(0),
  index: 0,
  label: 'none',
  isSome: false,
);

WasmComponentValueData _some(WasmComponentValueData value) =>
    WasmComponentValueData(
      kind: WasmComponentValueDataKind.option,
      rawBytes: Uint8List(0),
      index: 1,
      label: 'some',
      isSome: true,
      associatedValue: value,
    );

WasmComponentValueData _ipv4SocketAddress({
  required int port,
  int a = 127,
  int b = 0,
  int c = 0,
  int d = 1,
}) => _variant(
  'ipv4',
  0,
  _record(<WasmComponentValueData>[
    _integer(port),
    _tuple(<WasmComponentValueData>[
      _integer(a),
      _integer(b),
      _integer(c),
      _integer(d),
    ]),
  ]),
);

WasmComponentValueData _ipv6SocketAddress({
  required int port,
  int a = 0,
  int b = 0,
  int c = 0,
  int d = 0,
  int e = 0,
  int f = 0,
  int g = 0,
  int h = 1,
  int flowInfo = 0,
  int scopeId = 0,
}) => _variant(
  'ipv6',
  1,
  _record(<WasmComponentValueData>[
    _integer(port),
    _integer(flowInfo),
    _tuple(<WasmComponentValueData>[
      _integer(a),
      _integer(b),
      _integer(c),
      _integer(d),
      _integer(e),
      _integer(f),
      _integer(g),
      _integer(h),
    ]),
    _integer(scopeId),
  ]),
);

WasmComponentValueData _outgoingDatagram(
  WasmComponentValueData remoteAddress, {
  List<int> data = const <int>[],
}) => _record(<WasmComponentValueData>[
  _list(<WasmComponentValueData>[for (final byte in data) _integer(byte)]),
  remoteAddress,
]);

(int, int, int) _boundUdpStreams(
  WASIPreview2SocketsHost sockets,
  WasmComponentValueData remoteAddress,
) {
  final imports = sockets.imports;
  final network =
      imports['wasi:sockets/instance-network@0.2.0.instance-network']!(
            const <Object?>[],
          )!
          as int;
  final socket = _resultHandle(
    imports['wasi:sockets/udp-create-socket@0.2.0.create-udp-socket']!(
          <Object?>[_enum('ipv4', 0)],
        )!
        as WasmComponentValueData,
  );
  imports['wasi:sockets/udp@0.2.0.udp-socket.start-bind']!(<Object?>[
    socket,
    network,
    _ipv4SocketAddress(port: 8081),
  ]);
  final finish =
      imports['wasi:sockets/udp@0.2.0.udp-socket.finish-bind']!(<Object?>[
            socket,
          ])!
          as WasmComponentValueData;
  expect(_resultError(finish), isNull);
  final streams = _resultPair(
    imports['wasi:sockets/udp@0.2.0.udp-socket.stream']!(<Object?>[
          socket,
          remoteAddress,
        ])!
        as WasmComponentValueData,
  );
  return (socket, streams.$1, streams.$2);
}

int _resultHandle(WasmComponentValueData result) =>
    (result.associatedValue!.integer! as num).toInt();

(int, int) _resultPair(WasmComponentValueData result) {
  final tuple = result.associatedValue!;
  return (
    (tuple.items[0].integer! as num).toInt(),
    (tuple.items[1].integer! as num).toInt(),
  );
}

(int, int, int) _resultTriple(WasmComponentValueData result) {
  final tuple = result.associatedValue!;
  return (
    (tuple.items[0].integer! as num).toInt(),
    (tuple.items[1].integer! as num).toInt(),
    (tuple.items[2].integer! as num).toInt(),
  );
}

WASIPreview2TcpConnection _testTcpConnection() {
  return WASIPreview2TcpConnection(
    inputStream: WASIPreview2InputStream(closed: true),
    outputStream: WASIPreview2OutputStream(),
    localAddress: WASIPreview2IpSocketAddress.ipv4(
      port: 8080,
      a: 127,
      b: 0,
      c: 0,
      d: 1,
    ),
    remoteAddress: WASIPreview2IpSocketAddress.ipv4(
      port: 9000,
      a: 127,
      b: 0,
      c: 0,
      d: 1,
    ),
  );
}

String? _resultError(WasmComponentValueData result) {
  if (result.isOk ?? result.index == 0) {
    return null;
  }
  return result.associatedValue?.label;
}

Future<WasmComponentValueData> _finishTcpConnect(
  WASIPreview2SocketsHost sockets,
  int socket,
) async {
  final pollable =
      sockets.imports['wasi:sockets/tcp@0.2.0.tcp-socket.subscribe']!(<Object?>[
            socket,
          ])!
          as int;
  final waiting = sockets
      .pollHost
      .imports['wasi:io/poll@0.2.0.pollable.block']!(<Object?>[pollable]);
  if (waiting is Future<void>) {
    await waiting;
  }
  sockets.table.dropNamed('wasi:io/poll@0.2.0.pollable', pollable);
  return sockets.imports['wasi:sockets/tcp@0.2.0.tcp-socket.finish-connect']!(
        <Object?>[socket],
      )!
      as WasmComponentValueData;
}

Future<WasmComponentValueData> _finishUdpBind(
  WASIPreview2SocketsHost sockets,
  int socket,
) async {
  final pollable =
      sockets.imports['wasi:sockets/udp@0.2.0.udp-socket.subscribe']!(<Object?>[
            socket,
          ])!
          as int;
  final waiting = sockets
      .pollHost
      .imports['wasi:io/poll@0.2.0.pollable.block']!(<Object?>[pollable]);
  if (waiting is Future<void>) {
    await waiting;
  }
  sockets.table.dropNamed('wasi:io/poll@0.2.0.pollable', pollable);
  return sockets.imports['wasi:sockets/udp@0.2.0.udp-socket.finish-bind']!(
        <Object?>[socket],
      )!
      as WasmComponentValueData;
}

WASIPreview2SocketsBackend _nativeSocketsBackend() {
  final library = _nativeSocketsLibrary();
  final type =
      library.declarations[mirrors.MirrorSystem.getSymbol(
            '_NativeSocketsBackend',
            library,
          )]!
          as mirrors.ClassMirror;
  return type.newInstance(const Symbol(''), const <Object>[]).reflectee
      as WASIPreview2SocketsBackend;
}

io.ServerSocket _nativeListenerServer(WASIPreview2TcpListener listener) {
  final library = _nativeSocketsLibrary();
  return mirrors
          .reflect(listener)
          .getField(mirrors.MirrorSystem.getSymbol('_server', library))
          .reflectee
      as io.ServerSocket;
}

bool _nativeListenerClosed(WASIPreview2TcpListener listener) {
  final library = _nativeSocketsLibrary();
  return mirrors
          .reflect(listener)
          .getField(mirrors.MirrorSystem.getSymbol('_closed', library))
          .reflectee
      as bool;
}

String _nativeResolverErrorCode(Object error) {
  final library = _nativeSocketsLibrary();
  return library.invoke(
        mirrors.MirrorSystem.getSymbol('_resolverErrorCode', library),
        <Object>[error],
      ).reflectee
      as String;
}

mirrors.LibraryMirror _nativeSocketsLibrary() {
  return mirrors.currentMirrorSystem().libraries.values.singleWhere(
    (library) => library.uri.toString().endsWith(
      '/src/wasi/preview2/native/sockets.dart',
    ),
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition did not become true');
    }
    await Future<void>.delayed(Duration.zero);
  }
}
