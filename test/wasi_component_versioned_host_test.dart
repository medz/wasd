import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/async_host.dart';
import 'package:wasd/src/wasi/component/async_values.dart';
import 'package:wasd/src/wasi/component/canonical_host.dart';
import 'package:wasd/src/wasi/component/host.dart';
import 'package:wasd/src/wasi/component/resource_host.dart';
import 'package:wasd/src/wasi/component/resource_table.dart';
import 'package:wasd/src/wasi/component/versioned_host.dart';
import 'package:wasd/src/wasi/component/waitable_set.dart';
import 'package:wasd/src/wasi/component/wit_adapter.dart';
import 'package:wasd/src/wasi/component/wit_document.dart';
import 'package:wasd/src/wasi/preview2/cli.dart';
import 'package:wasd/src/wasi/preview2/clocks.dart';
import 'package:wasd/src/wasi/preview2/component_host.dart';
import 'package:wasd/src/wasi/preview2/filesystem.dart';
import 'package:wasd/src/wasi/preview2/http.dart';
import 'package:wasd/src/wasi/preview2/io.dart';
import 'package:wasd/src/wasi/preview2/poll.dart';
import 'package:wasd/src/wasi/preview2/sockets.dart';
import 'package:wasd/src/wasi/preview3/cli.dart';
import 'package:wasd/src/wasi/preview3/component_host.dart';
import 'package:wasd/src/wasi/preview3/filesystem.dart';
import 'package:wasd/src/wasi/version.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/memory.dart';

import 'support/component_fixtures.dart';

void main() {
  group('WASIComponentVersionProfile', () {
    test('describes component canonical areas by WASI version', () {
      expect(WASIComponentVersionProfile.preview1.canonicalAreas, isEmpty);
      expect(
        WASIComponentVersionProfile.preview2.canonicalAreas,
        containsAll(<WASIComponentCanonicalCapabilityArea>[
          WASIComponentCanonicalCapabilityArea.adapterGeneration,
          WASIComponentCanonicalCapabilityArea.resource,
        ]),
      );
      expect(
        WASIComponentVersionProfile.preview2.canonicalAreas,
        isNot(contains(WASIComponentCanonicalCapabilityArea.asyncValue)),
      );
      expect(
        WASIComponentVersionProfile.preview3.canonicalAreas,
        containsAll(<WASIComponentCanonicalCapabilityArea>[
          WASIComponentCanonicalCapabilityArea.asyncValue,
          WASIComponentCanonicalCapabilityArea.waitable,
          WASIComponentCanonicalCapabilityArea.threadScheduling,
        ]),
      );
      expect(
        () => WASIComponentVersionProfile.preview3.canonicalAreas.add(
          WASIComponentCanonicalCapabilityArea.resource,
        ),
        throwsUnsupportedError,
      );
      expect(
        WASIComponentVersionProfile.forVersion(WASIVersion.preview3),
        same(WASIComponentVersionProfile.preview3),
      );
    });
  });

  group('WASIComponentVersionedHost', () {
    test('rejects component canonical definitions for Preview1', () {
      final component = WasmComponent.decode(_canonicalResourceProgramBytes());
      final host = WASIComponentVersionedHost(version: WASIVersion.preview1);

      final plan = host.prepareComponent(component);

      expect(plan.canBind, isFalse);
      expect(plan.validationErrors, isEmpty);
      expect(plan.unsupportedDefinitions, isEmpty);
      expect(plan.bindingErrors, isEmpty);
      expect(plan.versionErrors, hasLength(3));
      expect(
        plan.versionErrors.map((error) => error.kind),
        <WasmComponentCanonicalKind>[
          WasmComponentCanonicalKind.resourceNew,
          WasmComponentCanonicalKind.resourceRep,
          WasmComponentCanonicalKind.resourceDrop,
        ],
      );
      expect(
        () => plan.bind(),
        throwsA(
          isA<WASIComponentVersionUnsupportedException>()
              .having((error) => error.errors, 'errors', hasLength(3))
              .having(
                (error) => error.toString(),
                'message',
                contains('WASI Preview1'),
              ),
        ),
      );
      expect(host.componentHost.table.activeCount, 0);
    });

    test('binds Preview2 resource components through the shared host', () {
      final component = WasmComponent.decode(_canonicalResourceProgramBytes());
      final host = WASIComponentVersionedHost(version: WASIVersion.preview2);
      final dropped = <int>[];

      final plan = host.prepareComponent(component);

      expect(plan.canBind, isTrue);
      expect(plan.versionErrors, isEmpty);
      expect(plan.unsupportedDefinitions, isEmpty);
      expect(plan.bindingErrors, isEmpty);

      final binding = plan.bind(
        onResourceDrop: (_, resource) => dropped.add(resource as int),
      );
      final handle = binding.program.invoke(0, <Object?>[123]);

      expect(binding.program.invoke(1, <Object?>[handle]), 123);
      expect(binding.program.invoke(2, <Object?>[handle]), isNull);
      expect(dropped, [123]);
      expect(host.componentHost.table.activeCount, 0);
    });

    test('rejects Preview2 async stream canonical definitions', () {
      final component = WasmComponent.decode(_canonicalStreamProgramBytes());
      final componentHost = WASIComponentHost();
      final host = WASIComponentVersionedHost(
        version: WASIVersion.preview2,
        componentHost: componentHost,
      );

      final plan = host.prepareComponent(component);

      expect(plan.canBind, isFalse);
      expect(plan.validationErrors, isEmpty);
      expect(plan.unsupportedDefinitions, isEmpty);
      expect(plan.bindingErrors, isEmpty);
      expect(plan.versionErrors, hasLength(7));
      expect(plan.versionErrors.map((error) => error.capability.area).toSet(), {
        WASIComponentCanonicalCapabilityArea.asyncValue,
      });
      expect(
        plan.versionErrors.map((error) => error.kind),
        <WasmComponentCanonicalKind>[
          WasmComponentCanonicalKind.streamNew,
          WasmComponentCanonicalKind.streamRead,
          WasmComponentCanonicalKind.streamWrite,
          WasmComponentCanonicalKind.streamCancelRead,
          WasmComponentCanonicalKind.streamCancelWrite,
          WasmComponentCanonicalKind.streamDropReadable,
          WasmComponentCanonicalKind.streamDropWritable,
        ],
      );
      expect(
        () => plan.bind(),
        throwsA(
          isA<WASIComponentVersionUnsupportedException>()
              .having((error) => error.errors, 'errors', hasLength(7))
              .having(
                (error) => error.toString(),
                'message',
                allOf(contains('WASI 0.2 / Preview2'), contains('streamNew')),
              ),
        ),
      );
      expect(componentHost.table.activeCount, 0);
    });

    test('allows Preview3 async stream components through the profile', () {
      final component = WasmComponent.decode(_canonicalStreamProgramBytes());
      final host = WASIComponentVersionedHost(version: WASIVersion.preview3);

      final plan = host.prepareComponent(component);

      expect(plan.canBind, isTrue);
      expect(plan.versionErrors, isEmpty);
      expect(plan.unsupportedDefinitions, isEmpty);

      final binding = plan.bind();
      final handles = WASIComponentAsyncEndpointHandles.unpack(
        binding.program.invoke(0, const <Object?>[])! as int,
      );

      expect(binding.asyncValueBindings, hasLength(1));
      expect(host.componentHost.table.activeCount, 2);
      expect(binding.program.invoke(5, <Object?>[handles.readable]), isNull);
      expect(binding.program.invoke(6, <Object?>[handles.writable]), isNull);
      expect(host.componentHost.table.activeCount, 0);
    });

    test(
      'keeps Preview3 adapter callback requirements separate from gates',
      () {
        final component = WasmComponent.decode(_canonicalMixedResourceBytes());
        final host = WASIComponentVersionedHost(version: WASIVersion.preview3);

        final plan = host.prepareComponent(component, validate: false);

        expect(plan.canBind, isFalse);
        expect(plan.canBindWithAdapters, isFalse);
        expect(plan.versionErrors, isEmpty);
        expect(plan.bindingErrors, hasLength(1));
        expect(plan.unsupportedDefinitions, isEmpty);
        expect(
          () => plan.bind(),
          throwsA(isA<WASIComponentHostBindingException>()),
        );
        expect(host.componentHost.table.activeCount, 0);
      },
    );
  });

  group('fixed WASI component host versions', () {
    test('rejects Preview2 overrides backed by different resource tables', () {
      final firstTable = WASIComponentResourceTable();
      final secondTable = WASIComponentResourceTable();

      expect(
        () => WASIPreview2ComponentHost(
          errorHost: WASIPreview2IoErrorHost(table: firstTable),
          clocksHost: WASIPreview2ClocksHost(
            pollHost: WASIPreview2PollHost(table: secondTable),
          ),
        ),
        throwsArgumentError,
      );
    });

    test('rejects HTTP streams wired to a different poll host', () {
      final table = WASIComponentResourceTable();
      final streams = WASIPreview2StreamsHost(table: table);

      expect(
        () => WASIPreview2HttpHost(
          table: table,
          pollHost: WASIPreview2PollHost(table: table),
          streamsHost: streams,
        ),
        throwsArgumentError,
      );
    });

    test('Preview2 wrapper enforces the Preview2 profile', () {
      final resourceComponent = WasmComponent.decode(
        _canonicalResourceProgramBytes(),
      );
      final streamComponent = WasmComponent.decode(
        _canonicalStreamProgramBytes(),
      );
      final sharedHost = WASIComponentHost();
      final host = WASIPreview2ComponentHost(componentHost: sharedHost);

      expect(host.profile, same(WASIComponentVersionProfile.preview2));
      expect(host.componentHost, same(sharedHost));

      final resourcePlan = host.prepareComponent(resourceComponent);
      final streamPlan = host.prepareComponent(streamComponent);

      expect(resourcePlan.canBind, isTrue);
      expect(streamPlan.canBind, isFalse);
      expect(streamPlan.versionErrors, hasLength(7));
      expect(sharedHost.table.activeCount, 0);
    });

    test(
      'Preview2 and Preview3 wrappers ingest WIT worlds through profiles',
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
        final preview2 = WASIPreview2ComponentHost();
        final preview3 = WASIPreview3ComponentHost();

        final preview2Plan = preview2.prepareWitWorld(
          document,
          worldName: 'command',
        );
        final preview3Plan = preview3.prepareWitWorld(
          document,
          worldName: 'command',
        );

        expect(preview2Plan.canIngest, isFalse);
        expect(preview2Plan.versionErrors, hasLength(3));
        expect(
          preview2Plan.versionErrors.map((error) => error.targetName),
          containsAll(<String>[
            'run.run',
            'stdout.write-via-stream',
            'wasi:filesystem/imports@0.3.0',
          ]),
        );
        expect(preview3Plan.canIngest, isTrue);
        expect(preview3Plan.versionErrors, isEmpty);
        expect(preview3Plan.canBindAdapters, isTrue);
        expect(preview3Plan.bindingErrors, isEmpty);
        expect(preview3Plan.world.name, 'command');
        expect(preview3Plan.items.map((item) => item.target.text), [
          'run',
          'wasi:filesystem/imports@0.3.0',
          'stdout',
        ]);
      },
    );

    test('Preview2 expands and binds standard WASI random imports', () {
      const source = '''
package wasi-testsuite:test;

world random-test {
  include wasi:random/imports@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final preview2 = WASIPreview2ComponentHost();
      final plan = preview2.prepareWitWorld(document, worldName: 'random-test');

      expect(plan.canIngest, isTrue);
      expect(plan.canBindAdapters, isTrue);
      expect(plan.bindingErrors, isEmpty);
      expect(plan.functions.map((function) => function.qualifiedName), [
        'wasi:random/random@0.2.0.get-random-bytes',
        'wasi:random/random@0.2.0.get-random-u64',
        'wasi:random/insecure@0.2.0.get-insecure-random-bytes',
        'wasi:random/insecure@0.2.0.get-insecure-random-u64',
        'wasi:random/insecure-seed@0.2.0.insecure-seed',
      ]);

      final program = preview2.bindWitWorld(document, worldName: 'random-test');
      final bytes =
          program.invokeImport('wasi:random/random@0.2.0.get-random-bytes', [
                BigInt.from(8),
              ])
              as WasmComponentValueData;
      final seedA =
          program.invokeImport(
                'wasi:random/insecure-seed@0.2.0.insecure-seed',
                const [],
              )
              as WasmComponentValueData;
      final seedB =
          program.invokeImport(
                'wasi:random/insecure-seed@0.2.0.insecure-seed',
                const [],
              )
              as WasmComponentValueData;

      expect(_u8List(bytes), hasLength(8));
      expect(
        program.invokeImport(
          'wasi:random/random@0.2.0.get-random-u64',
          const [],
        ),
        isA<BigInt>(),
      );
      expect(
        program.invokeImport(
          'wasi:random/insecure@0.2.0.get-insecure-random-u64',
          const [],
        ),
        isA<BigInt>(),
      );
      expect(_u64Tuple(seedA), _u64Tuple(seedB));
      expect(
        preview2.standardImports,
        contains('wasi:random/random@0.2.0.get-random-bytes'),
      );
    });

    test('Preview2 expands and binds standard WASI clocks imports', () {
      const source = '''
package wasi-testsuite:test;

world clocks-test {
  include wasi:clocks/imports@0.2.0;
  import wasi:io/poll@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final preview2 = WASIPreview2ComponentHost();
      final plan = preview2.prepareWitWorld(document, worldName: 'clocks-test');

      expect(plan.canIngest, isTrue);
      expect(plan.canBindAdapters, isTrue);
      expect(plan.bindingErrors, isEmpty);
      expect(plan.functions.map((function) => function.qualifiedName), [
        'wasi:clocks/monotonic-clock@0.2.0.now',
        'wasi:clocks/monotonic-clock@0.2.0.resolution',
        'wasi:clocks/monotonic-clock@0.2.0.subscribe-instant',
        'wasi:clocks/monotonic-clock@0.2.0.subscribe-duration',
        'wasi:clocks/wall-clock@0.2.0.now',
        'wasi:clocks/wall-clock@0.2.0.resolution',
        'wasi:io/poll@0.2.0.pollable.ready',
        'wasi:io/poll@0.2.0.pollable.block',
        'wasi:io/poll@0.2.0.poll',
      ]);

      final program = preview2.bindWitWorld(document, worldName: 'clocks-test');
      final before =
          program.invokeImport(
                'wasi:clocks/monotonic-clock@0.2.0.now',
                const [],
              )
              as BigInt;
      final resolution =
          program.invokeImport(
                'wasi:clocks/monotonic-clock@0.2.0.resolution',
                const [],
              )
              as BigInt;
      final instantHandle =
          program.invokeImport(
                'wasi:clocks/monotonic-clock@0.2.0.subscribe-instant',
                [before],
              )
              as int;
      final durationHandle =
          program.invokeImport(
                'wasi:clocks/monotonic-clock@0.2.0.subscribe-duration',
                [BigInt.zero],
              )
              as int;
      final wallNow =
          program.invokeImport('wasi:clocks/wall-clock@0.2.0.now', const [])
              as WasmComponentValueData;
      final wallResolution =
          program.invokeImport(
                'wasi:clocks/wall-clock@0.2.0.resolution',
                const [],
              )
              as WasmComponentValueData;

      expect(resolution, greaterThan(BigInt.zero));
      expect(instantHandle, greaterThan(0));
      expect(durationHandle, greaterThan(instantHandle));
      expect(_datetimeNanoseconds(wallNow), lessThan(1000000000));
      expect(_datetimeNanoseconds(wallResolution), lessThan(1000000000));
      expect(
        program.invokeImport('wasi:io/poll@0.2.0.pollable.ready', [
          instantHandle,
        ]),
        isTrue,
      );
      expect(
        program.invokeImport('wasi:io/poll@0.2.0.pollable.block', [
          durationHandle,
        ]),
        isNull,
      );
      expect(
        _u32List(
          program.invokeImport('wasi:io/poll@0.2.0.poll', [
                _resourceHandleList([instantHandle, durationHandle]),
              ])
              as WasmComponentValueData,
        ),
        [0, 1],
      );
      expect(
        preview2.standardImports,
        contains('wasi:clocks/monotonic-clock@0.2.0.subscribe-duration'),
      );
      expect(
        preview2.standardImports,
        contains('wasi:io/poll@0.2.0.pollable.ready'),
      );
    });

    test('Preview2 poll host waits on pending pollables', () async {
      final host = WASIPreview2PollHost();
      final readySignal = Completer<void>();
      var ready = false;
      final handle = host.insert(
        WASIPreview2Pollable(
          isReady: () => ready,
          waitReady: () => readySignal.future,
        ),
      );

      expect(
        host.imports['wasi:io/poll@0.2.0.pollable.ready']!([handle]),
        isFalse,
      );
      final block = host.imports['wasi:io/poll@0.2.0.pollable.block']!([
        handle,
      ]);
      expect(block, isA<Future<void>>());
      var completed = false;
      final wait = (block as Future<void>).then((_) {
        completed = true;
      });

      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);

      ready = true;
      readySignal.complete();
      await wait;

      expect(
        host.imports['wasi:io/poll@0.2.0.pollable.ready']!([handle]),
        isTrue,
      );
      expect(
        _u32List(
          host.imports['wasi:io/poll@0.2.0.poll']!([
                _resourceHandleList([handle]),
              ])
              as WasmComponentValueData,
        ),
        [0],
      );
    });

    test(
      'Preview2 expands and binds standard WASI io streams imports',
      () async {
        const source = '''
package wasi-testsuite:test;

world io-test {
  import wasi:io/error@0.2.0;
  include wasi:io/imports@0.2.0;
}
''';
        final document = WASIComponentWitDocument.parse(source);
        final preview2 = WASIPreview2ComponentHost();
        final input = preview2.streamsHost.insertInputStream(
          WASIPreview2InputStream(bytes: const <int>[1, 2, 3, 4], closed: true),
        );
        final output = preview2.streamsHost.insertOutputStream();
        final plan = preview2.prepareWitWorld(document, worldName: 'io-test');

        expect(plan.canIngest, isTrue);
        expect(plan.canBindAdapters, isTrue);
        expect(plan.bindingErrors, isEmpty);
        expect(plan.functions.map((function) => function.qualifiedName), [
          'wasi:io/error@0.2.0.error.to-debug-string',
          'wasi:io/streams@0.2.0.input-stream.read',
          'wasi:io/streams@0.2.0.input-stream.blocking-read',
          'wasi:io/streams@0.2.0.input-stream.skip',
          'wasi:io/streams@0.2.0.input-stream.blocking-skip',
          'wasi:io/streams@0.2.0.input-stream.subscribe',
          'wasi:io/streams@0.2.0.output-stream.check-write',
          'wasi:io/streams@0.2.0.output-stream.write',
          'wasi:io/streams@0.2.0.output-stream.blocking-write-and-flush',
          'wasi:io/streams@0.2.0.output-stream.flush',
          'wasi:io/streams@0.2.0.output-stream.blocking-flush',
          'wasi:io/streams@0.2.0.output-stream.subscribe',
          'wasi:io/streams@0.2.0.output-stream.write-zeroes',
          'wasi:io/streams@0.2.0.output-stream.blocking-write-zeroes-and-flush',
          'wasi:io/streams@0.2.0.output-stream.splice',
          'wasi:io/streams@0.2.0.output-stream.blocking-splice',
          'wasi:io/poll@0.2.0.pollable.ready',
          'wasi:io/poll@0.2.0.pollable.block',
          'wasi:io/poll@0.2.0.poll',
        ]);

        final program = preview2.bindWitWorld(document, worldName: 'io-test');
        final read =
            program.invokeImport('wasi:io/streams@0.2.0.input-stream.read', [
                  input,
                  BigInt.from(2),
                ])
                as WasmComponentValueData;
        final skipped =
            program.invokeImport('wasi:io/streams@0.2.0.input-stream.skip', [
                  input,
                  BigInt.one,
                ])
                as WasmComponentValueData;
        final pollable =
            program.invokeImport(
                  'wasi:io/streams@0.2.0.input-stream.subscribe',
                  [input],
                )
                as int;
        final permit =
            program.invokeImport(
                  'wasi:io/streams@0.2.0.output-stream.check-write',
                  [output],
                )
                as WasmComponentValueData;
        final write = program.invokeImport(
          'wasi:io/streams@0.2.0.output-stream.write',
          [
            output,
            _u8ListValue([9, 8]),
          ],
        );
        program.invokeImport(
          'wasi:io/streams@0.2.0.output-stream.check-write',
          [output],
        );
        final zeroes = program.invokeImport(
          'wasi:io/streams@0.2.0.output-stream.write-zeroes',
          [output, BigInt.from(2)],
        );
        final splice =
            program.invokeImport('wasi:io/streams@0.2.0.output-stream.splice', [
                  output,
                  input,
                  BigInt.from(8),
                ])
                as WasmComponentValueData;
        final closed =
            program.invokeImport('wasi:io/streams@0.2.0.input-stream.read', [
                  input,
                  BigInt.one,
                ])
                as WasmComponentValueData;

        expect(_u8List(_resultOk(read)), [1, 2]);
        expect(_u64Data(_resultOk(skipped)), BigInt.one);
        expect(
          program.invokeImport('wasi:io/poll@0.2.0.pollable.ready', [pollable]),
          isTrue,
        );
        expect(_u64Data(_resultOk(permit)), greaterThan(BigInt.zero));
        expect((write as WasmComponentValueData).isOk, isTrue);
        expect((zeroes as WasmComponentValueData).isOk, isTrue);
        expect(_u64Data(_resultOk(splice)), BigInt.one);
        expect(preview2.streamsHost.outputStream(output).bytes, [
          9,
          8,
          0,
          0,
          4,
        ]);
        expect(_resultErrorLabel(closed), 'closed');
        expect(
          preview2.standardImports,
          contains('wasi:io/streams@0.2.0.output-stream.splice'),
        );

        final failedInput = preview2.streamsHost.insertInputStream(
          WASIPreview2InputStream()..fail('read failed'),
        );
        final failed =
            program.invokeImport('wasi:io/streams@0.2.0.input-stream.read', [
                  failedInput,
                  BigInt.one,
                ])
                as WasmComponentValueData;
        final errorHandle = _streamErrorHandle(failed);

        expect(
          program.invokeImport('wasi:io/error@0.2.0.error.to-debug-string', [
            errorHandle,
          ]),
          'read failed',
        );

        final pending = WASIPreview2InputStream();
        final pendingHandle = preview2.streamsHost.insertInputStream(pending);
        var completed = false;
        final blockingRead = program
            .invokeImportAsync(
              'wasi:io/streams@0.2.0.input-stream.blocking-read',
              [pendingHandle, BigInt.one],
            )
            .then((value) {
              completed = true;
              return value as WasmComponentValueData;
            });

        await Future<void>.delayed(Duration.zero);
        expect(completed, isFalse);

        pending.append(const <int>[]);
        await Future<void>.delayed(Duration.zero);
        expect(completed, isFalse);

        pending.append(const <int>[42]);
        expect(_u8List(_resultOk(await blockingRead)), [42]);
        expect(completed, isTrue);
      },
    );

    test(
      'Preview2 streams consume write permits and terminal failures once',
      () {
        const source = '''
package wasi-testsuite:test;

world io-test {
  import wasi:io/error@0.2.0;
  include wasi:io/imports@0.2.0;
}
''';
        final preview2 = WASIPreview2ComponentHost();
        final program = preview2.bindWitWorld(
          WASIComponentWitDocument.parse(source),
          worldName: 'io-test',
        );
        final output = preview2.streamsHost.insertOutputStream(
          WASIPreview2OutputStream(maxWriteSize: 2),
        );

        program.invokeImport(
          'wasi:io/streams@0.2.0.output-stream.check-write',
          [output],
        );
        _expectUnitOk(
          program.invokeImport('wasi:io/streams@0.2.0.output-stream.write', [
                output,
                _u8ListValue([1]),
              ])
              as WasmComponentValueData,
        );
        expect(
          () => program.invokeImport(
            'wasi:io/streams@0.2.0.output-stream.write',
            [
              output,
              _u8ListValue([2]),
            ],
          ),
          throwsStateError,
        );
        program.invokeImport(
          'wasi:io/streams@0.2.0.output-stream.check-write',
          [output],
        );
        _expectUnitOk(
          program.invokeImport('wasi:io/streams@0.2.0.output-stream.write', [
                output,
                _u8ListValue([2, 3]),
              ])
              as WasmComponentValueData,
        );
        expect(preview2.streamsHost.outputStream(output).bytes, [1, 2, 3]);

        final failedInput = preview2.streamsHost.insertInputStream(
          WASIPreview2InputStream(bytes: const <int>[8, 9])
            ..fail('input failed'),
        );
        final firstRead =
            program.invokeImport('wasi:io/streams@0.2.0.input-stream.read', [
                  failedInput,
                  BigInt.one,
                ])
                as WasmComponentValueData;
        final secondRead =
            program.invokeImport('wasi:io/streams@0.2.0.input-stream.read', [
                  failedInput,
                  BigInt.one,
                ])
                as WasmComponentValueData;
        final skippedAfterFailure =
            program.invokeImport('wasi:io/streams@0.2.0.input-stream.skip', [
                  failedInput,
                  BigInt.one,
                ])
                as WasmComponentValueData;
        final blockingReadAfterFailure = program.invokeImport(
          'wasi:io/streams@0.2.0.input-stream.blocking-read',
          [failedInput, BigInt.one],
        );

        expect(_resultErrorLabel(firstRead), 'last-operation-failed');
        expect(
          program.invokeImport('wasi:io/error@0.2.0.error.to-debug-string', [
            _streamErrorHandle(firstRead),
          ]),
          'input failed',
        );
        expect(_resultErrorLabel(secondRead), 'closed');
        expect(_resultErrorLabel(skippedAfterFailure), 'closed');
        expect(
          _resultErrorLabel(blockingReadAfterFailure as WasmComponentValueData),
          'closed',
        );

        final failedOutput = preview2.streamsHost.insertOutputStream(
          WASIPreview2OutputStream()..fail('output failed'),
        );
        final firstCheck =
            program.invokeImport(
                  'wasi:io/streams@0.2.0.output-stream.check-write',
                  [failedOutput],
                )
                as WasmComponentValueData;
        final secondCheck =
            program.invokeImport(
                  'wasi:io/streams@0.2.0.output-stream.check-write',
                  [failedOutput],
                )
                as WasmComponentValueData;

        expect(_resultErrorLabel(firstCheck), 'last-operation-failed');
        expect(
          program.invokeImport('wasi:io/error@0.2.0.error.to-debug-string', [
            _streamErrorHandle(firstCheck),
          ]),
          'output failed',
        );
        expect(_resultErrorLabel(secondCheck), 'closed');

        final callbackOutput = preview2.streamsHost.insertOutputStream(
          WASIPreview2OutputStream(onWrite: (_) => 'sink failed'),
        );
        program.invokeImport(
          'wasi:io/streams@0.2.0.output-stream.check-write',
          [callbackOutput],
        );
        final failedWrite =
            program.invokeImport('wasi:io/streams@0.2.0.output-stream.write', [
                  callbackOutput,
                  _u8ListValue([4]),
                ])
                as WasmComponentValueData;
        final checkAfterFailedWrite =
            program.invokeImport(
                  'wasi:io/streams@0.2.0.output-stream.check-write',
                  [callbackOutput],
                )
                as WasmComponentValueData;

        expect(_resultErrorLabel(failedWrite), 'last-operation-failed');
        expect(
          program.invokeImport('wasi:io/error@0.2.0.error.to-debug-string', [
            _streamErrorHandle(failedWrite),
          ]),
          'sink failed',
        );
        expect(_resultErrorLabel(checkAfterFailedWrite), 'closed');
      },
    );

    test('Preview2 expands and binds standard WASI CLI interfaces', () {
      const source = '''
package wasi-testsuite:test;

world cli-test {
  import wasi:cli/environment@0.2.0;
  import wasi:cli/exit@0.2.0;
  import wasi:cli/stdin@0.2.0;
  import wasi:cli/stdout@0.2.0;
  import wasi:cli/stderr@0.2.0;
  import wasi:cli/terminal-stdin@0.2.0;
  import wasi:cli/terminal-stdout@0.2.0;
  import wasi:cli/terminal-stderr@0.2.0;
  import wasi:io/streams@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final cli = WASIPreview2CliHost(
        args: const <String>['cli-env.wasm', 'a', 'b'],
        env: const <String, String>{'foo': 'bar', 'baz': '42'},
        initialCwd: '/workspace',
        stdinData: const <int>[120, 121],
      );
      final preview2 = WASIPreview2ComponentHost(cliHost: cli);
      final plan = preview2.prepareWitWorld(document, worldName: 'cli-test');

      expect(preview2.streamsHost, same(cli.streamsHost));
      expect(plan.canIngest, isTrue);
      expect(plan.canBindAdapters, isTrue);
      expect(plan.bindingErrors, isEmpty);
      expect(
        plan.functions.map((function) => function.qualifiedName),
        containsAll(<String>[
          'wasi:cli/environment@0.2.0.get-environment',
          'wasi:cli/environment@0.2.0.get-arguments',
          'wasi:cli/environment@0.2.0.initial-cwd',
          'wasi:cli/exit@0.2.0.exit',
          'wasi:cli/stdin@0.2.0.get-stdin',
          'wasi:cli/stdout@0.2.0.get-stdout',
          'wasi:cli/stderr@0.2.0.get-stderr',
          'wasi:cli/terminal-stdin@0.2.0.get-terminal-stdin',
          'wasi:cli/terminal-stdout@0.2.0.get-terminal-stdout',
          'wasi:cli/terminal-stderr@0.2.0.get-terminal-stderr',
          'wasi:io/streams@0.2.0.input-stream.read',
          'wasi:io/streams@0.2.0.output-stream.write',
        ]),
      );

      final program = preview2.bindWitWorld(document, worldName: 'cli-test');
      final environment =
          program.invokeImport(
                'wasi:cli/environment@0.2.0.get-environment',
                const [],
              )
              as WasmComponentValueData;
      final arguments =
          program.invokeImport(
                'wasi:cli/environment@0.2.0.get-arguments',
                const [],
              )
              as WasmComponentValueData;
      final cwd =
          program.invokeImport(
                'wasi:cli/environment@0.2.0.initial-cwd',
                const [],
              )
              as WasmComponentValueData;
      final terminal =
          program.invokeImport(
                'wasi:cli/terminal-stdout@0.2.0.get-terminal-stdout',
                const [],
              )
              as WasmComponentValueData;

      expect(_stringPairs(environment), contains(('foo', 'bar')));
      expect(_stringPairs(environment), contains(('baz', '42')));
      expect(_stringList(arguments), ['cli-env.wasm', 'a', 'b']);
      expect(_optionString(cwd), '/workspace');
      expect(terminal.kind, WasmComponentValueDataKind.option);
      expect(terminal.isSome, isFalse);

      final stdin =
          program.invokeImport('wasi:cli/stdin@0.2.0.get-stdin', const [])
              as int;
      final read =
          program.invokeImport('wasi:io/streams@0.2.0.input-stream.read', [
                stdin,
                BigInt.from(8),
              ])
              as WasmComponentValueData;
      expect(_u8List(_resultOk(read)), [120, 121]);

      final stdout =
          program.invokeImport('wasi:cli/stdout@0.2.0.get-stdout', const [])
              as int;
      program.invokeImport('wasi:io/streams@0.2.0.output-stream.check-write', [
        stdout,
      ]);
      final stdoutWrite = program.invokeImport(
        'wasi:io/streams@0.2.0.output-stream.write',
        [
          stdout,
          _u8ListValue([111, 107]),
        ],
      );
      expect((stdoutWrite as WasmComponentValueData).isOk, isTrue);
      expect(cli.stdoutBytes, [111, 107]);

      final stderr =
          program.invokeImport('wasi:cli/stderr@0.2.0.get-stderr', const [])
              as int;
      program.invokeImport('wasi:io/streams@0.2.0.output-stream.check-write', [
        stderr,
      ]);
      final stderrWrite = program.invokeImport(
        'wasi:io/streams@0.2.0.output-stream.write',
        [
          stderr,
          _u8ListValue([33]),
        ],
      );
      expect((stderrWrite as WasmComponentValueData).isOk, isTrue);
      expect(cli.stderrBytes, [33]);

      expect(
        () =>
            program.invokeImport('wasi:cli/exit@0.2.0.exit', [_unitOkValue()]),
        throwsA(
          isA<WASIPreview2Exit>()
              .having((error) => error.statusCode, 'statusCode', 0)
              .having((error) => error.isSuccess, 'isSuccess', isTrue),
        ),
      );
      expect(
        () => program.invokeImport('wasi:cli/exit@0.2.0.exit', [
          _unitErrorValue(),
        ]),
        throwsA(
          isA<WASIPreview2Exit>()
              .having((error) => error.statusCode, 'statusCode', 1)
              .having((error) => error.isSuccess, 'isSuccess', isFalse),
        ),
      );
      expect(
        preview2.standardImports,
        contains('wasi:cli/stdin@0.2.0.get-stdin'),
      );
    });

    test('Preview2 CLI exposes configured terminal resources', () {
      const source = '''
package wasi-testsuite:test;

world cli-test {
  import wasi:cli/terminal-stdin@0.2.0;
  import wasi:cli/terminal-stdout@0.2.0;
  import wasi:cli/terminal-stderr@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final cli = WASIPreview2CliHost(
        terminalStdin: true,
        terminalStdout: true,
        terminalStderr: true,
      );
      final preview2 = WASIPreview2ComponentHost(cliHost: cli);
      final program = preview2.bindWitWorld(document, worldName: 'cli-test');
      final stdin =
          program.invokeImport(
                'wasi:cli/terminal-stdin@0.2.0.get-terminal-stdin',
                const [],
              )
              as WasmComponentValueData;
      final stdout =
          program.invokeImport(
                'wasi:cli/terminal-stdout@0.2.0.get-terminal-stdout',
                const [],
              )
              as WasmComponentValueData;
      final stderr =
          program.invokeImport(
                'wasi:cli/terminal-stderr@0.2.0.get-terminal-stderr',
                const [],
              )
              as WasmComponentValueData;
      final stdinHandle = _optionHandle(stdin);
      final stdoutHandle = _optionHandle(stdout);
      final stderrHandle = _optionHandle(stderr);

      expect(stdinHandle, isNot(cli.terminalStdinHandle));
      expect(stdoutHandle, isNot(cli.terminalStdoutHandle));
      expect(stderrHandle, isNot(cli.terminalStderrHandle));
      expect(preview2.streamsHost.table.contains(stdinHandle!), isTrue);
      expect(preview2.streamsHost.table.contains(stdoutHandle!), isTrue);
      expect(preview2.streamsHost.table.contains(stderrHandle!), isTrue);
    });

    test('Preview2 runtime scopes cannot access CLI anchor handles', () async {
      final cli = WASIPreview2CliHost();
      final preview2 = WASIPreview2ComponentHost(cliHost: cli);
      final table = preview2.componentHost.table;
      final stdoutAnchor = cli.stdoutHandle;

      await table.runScoped<void>(() async {
        final stdout =
            preview2.standardImports['wasi:cli/stdout@0.2.0.get-stdout']!(
                  const <Object?>[],
                )
                as int;

        expect(stdout, isNot(stdoutAnchor));
        expect(
          () => preview2.streamsHost.outputStream(stdoutAnchor),
          throwsStateError,
        );
        expect(
          preview2.streamsHost.outputStream(stdout),
          same(cli.stdoutStream),
        );
      });

      expect(table.contains(stdoutAnchor), isTrue);
      expect(table.activeCount, 1);
    });

    test('Preview2 expands and binds standard WASI sockets imports', () async {
      const source = '''
package wasi-testsuite:test;

world sockets-test {
  include wasi:sockets/imports@0.2.0;
  include wasi:io/imports@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final preview2 = WASIPreview2ComponentHost();
      final plan = preview2.prepareWitWorld(
        document,
        worldName: 'sockets-test',
      );

      expect(plan.canIngest, isTrue);
      expect(plan.canBindAdapters, isTrue);
      expect(plan.bindingErrors, isEmpty);
      expect(
        plan.functions.map((function) => function.qualifiedName),
        containsAll(<String>[
          'wasi:sockets/instance-network@0.2.0.instance-network',
          'wasi:sockets/ip-name-lookup@0.2.0.resolve-addresses',
          'wasi:sockets/ip-name-lookup@0.2.0.resolve-address-stream.resolve-next-address',
          'wasi:sockets/ip-name-lookup@0.2.0.resolve-address-stream.subscribe',
          'wasi:sockets/tcp-create-socket@0.2.0.create-tcp-socket',
          'wasi:sockets/tcp@0.2.0.tcp-socket.local-address',
          'wasi:sockets/tcp@0.2.0.tcp-socket.subscribe',
          'wasi:sockets/tcp@0.2.0.tcp-socket.shutdown',
          'wasi:sockets/udp-create-socket@0.2.0.create-udp-socket',
          'wasi:sockets/udp@0.2.0.udp-socket.stream',
          'wasi:sockets/udp@0.2.0.incoming-datagram-stream.receive',
          'wasi:sockets/udp@0.2.0.outgoing-datagram-stream.send',
          'wasi:io/poll@0.2.0.pollable.ready',
        ]),
      );

      final program = preview2.bindWitWorld(
        document,
        worldName: 'sockets-test',
      );
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
      final udpSocket =
          program.invokeImport(
                'wasi:sockets/udp-create-socket@0.2.0.create-udp-socket',
                [_enumValue('ipv6')],
              )
              as WasmComponentValueData;
      final lookupStream =
          program.invokeImport(
                'wasi:sockets/ip-name-lookup@0.2.0.resolve-addresses',
                [network, '127.0.0.1'],
              )
              as WasmComponentValueData;
      final streamHandle = _resourceHandle(_resultOk(lookupStream));
      final lookupPollable =
          program.invokeImport(
                'wasi:sockets/ip-name-lookup@0.2.0.resolve-address-stream.subscribe',
                [streamHandle],
              )
              as int;
      await program.invokeImportAsync('wasi:io/poll@0.2.0.pollable.block', [
        lookupPollable,
      ]);
      final firstAddress =
          program.invokeImport(
                'wasi:sockets/ip-name-lookup@0.2.0.resolve-address-stream.resolve-next-address',
                [streamHandle],
              )
              as WasmComponentValueData;
      final secondAddress =
          program.invokeImport(
                'wasi:sockets/ip-name-lookup@0.2.0.resolve-address-stream.resolve-next-address',
                [streamHandle],
              )
              as WasmComponentValueData;
      final localAddress =
          program.invokeImport(
                'wasi:sockets/tcp@0.2.0.tcp-socket.local-address',
                [_resourceHandle(_resultOk(tcpSocket))],
              )
              as WasmComponentValueData;
      final shutdown =
          program.invokeImport('wasi:sockets/tcp@0.2.0.tcp-socket.shutdown', [
                _resourceHandle(_resultOk(tcpSocket)),
                _enumValue('both'),
              ])
              as WasmComponentValueData;

      expect(_resourceHandle(_resultOk(tcpSocket)), isNonZero);
      expect(_resourceHandle(_resultOk(udpSocket)), isNonZero);
      expect(_optionIpAddressLabel(_resultOk(firstAddress)), 'ipv4');
      expect(_optionIpAddressLabel(_resultOk(secondAddress)), isNull);
      expect(
        program.invokeImport('wasi:io/poll@0.2.0.pollable.ready', [
          lookupPollable,
        ]),
        isTrue,
      );
      expect(_resultErrorLabel(localAddress), 'invalid-state');
      expect(_resultErrorLabel(shutdown), 'invalid-state');
      expect(
        preview2.standardImports,
        contains('wasi:sockets/tcp-create-socket@0.2.0.create-tcp-socket'),
      );
    });

    test(
      'Preview2 sockets backend completes TCP listen connect and accept',
      () {
        const source = '''
package wasi-testsuite:test;

world sockets-test {
  include wasi:sockets/imports@0.2.0;
  include wasi:io/imports@0.2.0;
}
''';
        final document = WASIComponentWitDocument.parse(source);
        final backend = _LoopbackSocketsBackend();
        final preview2 = WASIPreview2ComponentHost(
          socketsHost: WASIPreview2SocketsHost(backend: backend),
        );
        final program = preview2.bindWitWorld(
          document,
          worldName: 'sockets-test',
        );
        final network =
            program.invokeImport(
                  'wasi:sockets/instance-network@0.2.0.instance-network',
                  const [],
                )
                as int;
        final listener = _resourceHandle(
          _resultOk(
            program.invokeImport(
                  'wasi:sockets/tcp-create-socket@0.2.0.create-tcp-socket',
                  [_enumValue('ipv4')],
                )
                as WasmComponentValueData,
          ),
        );
        final client = _resourceHandle(
          _resultOk(
            program.invokeImport(
                  'wasi:sockets/tcp-create-socket@0.2.0.create-tcp-socket',
                  [_enumValue('ipv4')],
                )
                as WasmComponentValueData,
          ),
        );

        _expectUnitOk(
          program.invokeImport('wasi:sockets/tcp@0.2.0.tcp-socket.start-bind', [
                listener,
                network,
                _ipv4SocketAddressValue(port: 8080),
              ])
              as WasmComponentValueData,
        );
        _expectUnitOk(
          program.invokeImport(
                'wasi:sockets/tcp@0.2.0.tcp-socket.finish-bind',
                [listener],
              )
              as WasmComponentValueData,
        );
        _expectUnitOk(
          program.invokeImport(
                'wasi:sockets/tcp@0.2.0.tcp-socket.start-listen',
                [listener],
              )
              as WasmComponentValueData,
        );
        _expectUnitOk(
          program.invokeImport(
                'wasi:sockets/tcp@0.2.0.tcp-socket.finish-listen',
                [listener],
              )
              as WasmComponentValueData,
        );
        _expectUnitOk(
          program.invokeImport(
                'wasi:sockets/tcp@0.2.0.tcp-socket.start-connect',
                [client, network, _ipv4SocketAddressValue(port: 8080)],
              )
              as WasmComponentValueData,
        );
        final connect =
            program.invokeImport(
                  'wasi:sockets/tcp@0.2.0.tcp-socket.finish-connect',
                  [client],
                )
                as WasmComponentValueData;
        final accept =
            program.invokeImport('wasi:sockets/tcp@0.2.0.tcp-socket.accept', [
                  listener,
                ])
                as WasmComponentValueData;
        final clientStreams = _tcpStreamPair(_resultOk(connect));
        final accepted = _tcpAcceptTuple(_resultOk(accept));

        program.invokeImport(
          'wasi:io/streams@0.2.0.output-stream.check-write',
          [clientStreams.output],
        );
        _expectUnitOk(
          program.invokeImport('wasi:io/streams@0.2.0.output-stream.write', [
                clientStreams.output,
                _u8ListValue([7, 8, 9]),
              ])
              as WasmComponentValueData,
        );
        final received =
            program.invokeImport('wasi:io/streams@0.2.0.input-stream.read', [
                  accepted.input,
                  BigInt.from(8),
                ])
                as WasmComponentValueData;
        final listenerPollable =
            program.invokeImport(
                  'wasi:sockets/tcp@0.2.0.tcp-socket.subscribe',
                  [listener],
                )
                as int;

        expect(_u8List(_resultOk(received)), [7, 8, 9]);
        expect(
          _resultOk(
            program.invokeImport(
                  'wasi:sockets/tcp@0.2.0.tcp-socket.local-address',
                  [client],
                )
                as WasmComponentValueData,
          ),
          isA<WasmComponentValueData>(),
        );
        expect(
          _resultOk(
            program.invokeImport(
                  'wasi:sockets/tcp@0.2.0.tcp-socket.remote-address',
                  [client],
                )
                as WasmComponentValueData,
          ),
          isA<WasmComponentValueData>(),
        );
        expect(
          program.invokeImport(
            'wasi:sockets/tcp@0.2.0.tcp-socket.is-listening',
            [listener],
          ),
          isTrue,
        );
        expect(
          program.invokeImport('wasi:io/poll@0.2.0.pollable.ready', [
            listenerPollable,
          ]),
          isFalse,
        );
        expect(backend.acceptedConnections, 1);
      },
    );

    test('Preview2 sockets exposes TCP and UDP socket options', () {
      const source = '''
package wasi-testsuite:test;

world sockets-test {
  include wasi:sockets/imports@0.2.0;
  include wasi:io/imports@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final preview2 = WASIPreview2ComponentHost(
        socketsHost: WASIPreview2SocketsHost(
          backend: _LoopbackSocketsBackend(),
        ),
      );
      final program = preview2.bindWitWorld(
        document,
        worldName: 'sockets-test',
      );
      final tcp = _resourceHandle(
        _resultOk(
          program.invokeImport(
                'wasi:sockets/tcp-create-socket@0.2.0.create-tcp-socket',
                [_enumValue('ipv4')],
              )
              as WasmComponentValueData,
        ),
      );
      final udp = _resourceHandle(
        _resultOk(
          program.invokeImport(
                'wasi:sockets/udp-create-socket@0.2.0.create-udp-socket',
                [_enumValue('ipv6')],
              )
              as WasmComponentValueData,
        ),
      );

      _expectUnitOk(
        program.invokeImport(
              'wasi:sockets/tcp@0.2.0.tcp-socket.set-keep-alive-enabled',
              [tcp, true],
            )
            as WasmComponentValueData,
      );
      _expectUnitOk(
        program.invokeImport(
              'wasi:sockets/tcp@0.2.0.tcp-socket.set-keep-alive-idle-time',
              [tcp, BigInt.from(11)],
            )
            as WasmComponentValueData,
      );
      _expectUnitOk(
        program.invokeImport(
              'wasi:sockets/tcp@0.2.0.tcp-socket.set-keep-alive-interval',
              [tcp, BigInt.from(12)],
            )
            as WasmComponentValueData,
      );
      _expectUnitOk(
        program.invokeImport(
              'wasi:sockets/tcp@0.2.0.tcp-socket.set-keep-alive-count',
              [tcp, 13],
            )
            as WasmComponentValueData,
      );
      _expectUnitOk(
        program.invokeImport(
              'wasi:sockets/tcp@0.2.0.tcp-socket.set-hop-limit',
              [tcp, 64],
            )
            as WasmComponentValueData,
      );
      _expectUnitOk(
        program.invokeImport(
              'wasi:sockets/tcp@0.2.0.tcp-socket.set-receive-buffer-size',
              [tcp, BigInt.from(4096)],
            )
            as WasmComponentValueData,
      );
      _expectUnitOk(
        program.invokeImport(
              'wasi:sockets/tcp@0.2.0.tcp-socket.set-send-buffer-size',
              [tcp, BigInt.from(8192)],
            )
            as WasmComponentValueData,
      );
      _expectUnitOk(
        program.invokeImport(
              'wasi:sockets/tcp@0.2.0.tcp-socket.set-listen-backlog-size',
              [tcp, BigInt.from(32)],
            )
            as WasmComponentValueData,
      );

      expect(
        _caseLabel(
          program.invokeImport(
                'wasi:sockets/tcp@0.2.0.tcp-socket.address-family',
                [tcp],
              )
              as WasmComponentValueData,
        ),
        'ipv4',
      );
      expect(
        _resultBool(
          program.invokeImport(
                'wasi:sockets/tcp@0.2.0.tcp-socket.keep-alive-enabled',
                [tcp],
              )
              as WasmComponentValueData,
        ),
        isTrue,
      );
      expect(
        _u64Data(
          _resultOk(
            program.invokeImport(
                  'wasi:sockets/tcp@0.2.0.tcp-socket.keep-alive-idle-time',
                  [tcp],
                )
                as WasmComponentValueData,
          ),
        ),
        BigInt.from(11),
      );
      expect(
        _u64Data(
          _resultOk(
            program.invokeImport(
                  'wasi:sockets/tcp@0.2.0.tcp-socket.keep-alive-interval',
                  [tcp],
                )
                as WasmComponentValueData,
          ),
        ),
        BigInt.from(12),
      );
      expect(
        _u64Data(
          _resultOk(
            program.invokeImport(
                  'wasi:sockets/tcp@0.2.0.tcp-socket.keep-alive-count',
                  [tcp],
                )
                as WasmComponentValueData,
          ),
        ),
        BigInt.from(13),
      );
      expect(
        _u64Data(
          _resultOk(
            program.invokeImport(
                  'wasi:sockets/tcp@0.2.0.tcp-socket.hop-limit',
                  [tcp],
                )
                as WasmComponentValueData,
          ),
        ),
        BigInt.from(64),
      );
      expect(
        _u64Data(
          _resultOk(
            program.invokeImport(
                  'wasi:sockets/tcp@0.2.0.tcp-socket.receive-buffer-size',
                  [tcp],
                )
                as WasmComponentValueData,
          ),
        ),
        BigInt.from(4096),
      );
      expect(
        _u64Data(
          _resultOk(
            program.invokeImport(
                  'wasi:sockets/tcp@0.2.0.tcp-socket.send-buffer-size',
                  [tcp],
                )
                as WasmComponentValueData,
          ),
        ),
        BigInt.from(8192),
      );
      expect(
        _resultErrorLabel(
          program.invokeImport(
                'wasi:sockets/tcp@0.2.0.tcp-socket.set-hop-limit',
                [tcp, 0],
              )
              as WasmComponentValueData,
        ),
        'invalid-argument',
      );

      _expectUnitOk(
        program.invokeImport(
              'wasi:sockets/udp@0.2.0.udp-socket.set-unicast-hop-limit',
              [udp, 42],
            )
            as WasmComponentValueData,
      );
      _expectUnitOk(
        program.invokeImport(
              'wasi:sockets/udp@0.2.0.udp-socket.set-receive-buffer-size',
              [udp, BigInt.from(2048)],
            )
            as WasmComponentValueData,
      );
      _expectUnitOk(
        program.invokeImport(
              'wasi:sockets/udp@0.2.0.udp-socket.set-send-buffer-size',
              [udp, BigInt.from(4096)],
            )
            as WasmComponentValueData,
      );

      expect(
        _caseLabel(
          program.invokeImport(
                'wasi:sockets/udp@0.2.0.udp-socket.address-family',
                [udp],
              )
              as WasmComponentValueData,
        ),
        'ipv6',
      );
      expect(
        _u64Data(
          _resultOk(
            program.invokeImport(
                  'wasi:sockets/udp@0.2.0.udp-socket.unicast-hop-limit',
                  [udp],
                )
                as WasmComponentValueData,
          ),
        ),
        BigInt.from(42),
      );
      expect(
        _u64Data(
          _resultOk(
            program.invokeImport(
                  'wasi:sockets/udp@0.2.0.udp-socket.receive-buffer-size',
                  [udp],
                )
                as WasmComponentValueData,
          ),
        ),
        BigInt.from(2048),
      );
      expect(
        _u64Data(
          _resultOk(
            program.invokeImport(
                  'wasi:sockets/udp@0.2.0.udp-socket.send-buffer-size',
                  [udp],
                )
                as WasmComponentValueData,
          ),
        ),
        BigInt.from(4096),
      );
      expect(
        _resultErrorLabel(
          program.invokeImport(
                'wasi:sockets/udp@0.2.0.udp-socket.set-unicast-hop-limit',
                [udp, 0],
              )
              as WasmComponentValueData,
        ),
        'invalid-argument',
      );
    });

    test('Preview2 sockets backend sends and receives UDP datagrams', () {
      const source = '''
package wasi-testsuite:test;

world sockets-test {
  include wasi:sockets/imports@0.2.0;
  include wasi:io/imports@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final backend = _LoopbackSocketsBackend();
      final preview2 = WASIPreview2ComponentHost(
        socketsHost: WASIPreview2SocketsHost(backend: backend),
      );
      final program = preview2.bindWitWorld(
        document,
        worldName: 'sockets-test',
      );
      final network =
          program.invokeImport(
                'wasi:sockets/instance-network@0.2.0.instance-network',
                const [],
              )
              as int;
      final socket = _resourceHandle(
        _resultOk(
          program.invokeImport(
                'wasi:sockets/udp-create-socket@0.2.0.create-udp-socket',
                [_enumValue('ipv4')],
              )
              as WasmComponentValueData,
        ),
      );

      _expectUnitOk(
        program.invokeImport('wasi:sockets/udp@0.2.0.udp-socket.start-bind', [
              socket,
              network,
              _ipv4SocketAddressValue(port: 9090),
            ])
            as WasmComponentValueData,
      );
      _expectUnitOk(
        program.invokeImport('wasi:sockets/udp@0.2.0.udp-socket.finish-bind', [
              socket,
            ])
            as WasmComponentValueData,
      );
      final streams =
          program.invokeImport('wasi:sockets/udp@0.2.0.udp-socket.stream', [
                socket,
                _noneValue(),
              ])
              as WasmComponentValueData;
      final (incoming, outgoing) = _udpStreamPair(_resultOk(streams));
      final socketPollable =
          program.invokeImport('wasi:sockets/udp@0.2.0.udp-socket.subscribe', [
                socket,
              ])
              as int;
      final incomingPollable =
          program.invokeImport(
                'wasi:sockets/udp@0.2.0.incoming-datagram-stream.subscribe',
                [incoming],
              )
              as int;
      final outgoingPollable =
          program.invokeImport(
                'wasi:sockets/udp@0.2.0.outgoing-datagram-stream.subscribe',
                [outgoing],
              )
              as int;
      final permit =
          program.invokeImport(
                'wasi:sockets/udp@0.2.0.outgoing-datagram-stream.check-send',
                [outgoing],
              )
              as WasmComponentValueData;
      final sent =
          program.invokeImport(
                'wasi:sockets/udp@0.2.0.outgoing-datagram-stream.send',
                [
                  outgoing,
                  _outgoingDatagramsValue([
                    ([1, 2, 3], _ipv4SocketAddressValue(port: 9090)),
                  ]),
                ],
              )
              as WasmComponentValueData;
      final received =
          program.invokeImport(
                'wasi:sockets/udp@0.2.0.incoming-datagram-stream.receive',
                [incoming, BigInt.from(4)],
              )
              as WasmComponentValueData;

      expect(
        _resultOk(
          program.invokeImport(
                'wasi:sockets/udp@0.2.0.udp-socket.local-address',
                [socket],
              )
              as WasmComponentValueData,
        ),
        isA<WasmComponentValueData>(),
      );
      expect(
        _resultErrorLabel(
          program.invokeImport(
                'wasi:sockets/udp@0.2.0.udp-socket.remote-address',
                [socket],
              )
              as WasmComponentValueData,
        ),
        'invalid-state',
      );
      expect(
        program.invokeImport('wasi:io/poll@0.2.0.pollable.ready', [
          socketPollable,
        ]),
        isTrue,
      );
      expect(
        program.invokeImport('wasi:io/poll@0.2.0.pollable.ready', [
          incomingPollable,
        ]),
        isFalse,
      );
      expect(
        program.invokeImport('wasi:io/poll@0.2.0.pollable.ready', [
          outgoingPollable,
        ]),
        isTrue,
      );
      expect(_u64Data(_resultOk(permit)), greaterThan(BigInt.zero));
      expect(_u64Data(_resultOk(sent)), BigInt.one);
      expect(_udpDatagramPayloads(_resultOk(received)), [
        [1, 2, 3],
      ]);
      expect(backend.sentDatagrams, 1);
    });

    test('Preview2 CLI imports include official WASI sockets imports', () {
      const source = '''
package wasi-testsuite:test;

world cli-test {
  include wasi:cli/imports@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final preview2 = WASIPreview2ComponentHost();
      final plan = preview2.prepareWitWorld(document, worldName: 'cli-test');

      expect(plan.canIngest, isTrue);
      expect(plan.canBindAdapters, isTrue);
      expect(plan.bindingErrors, isEmpty);
      expect(
        plan.functions.map((function) => function.qualifiedName),
        containsAll(<String>[
          'wasi:cli/environment@0.2.0.get-environment',
          'wasi:filesystem/preopens@0.2.0.get-directories',
          'wasi:sockets/instance-network@0.2.0.instance-network',
          'wasi:sockets/tcp-create-socket@0.2.0.create-tcp-socket',
          'wasi:sockets/udp-create-socket@0.2.0.create-udp-socket',
          'wasi:sockets/ip-name-lookup@0.2.0.resolve-addresses',
          'wasi:random/random@0.2.0.get-random-bytes',
          'wasi:io/streams@0.2.0.input-stream.read',
        ]),
      );
    });

    test('Preview2 binds current 0.2.x standard WIT patch imports', () {
      const source = '''
package wasi-testsuite:test;

world sockets-test {
  include wasi:sockets/imports@0.2.12;
  include wasi:io/imports@0.2.12;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final preview2 = WASIPreview2ComponentHost();
      final plan = preview2.prepareWitWorld(
        document,
        worldName: 'sockets-test',
      );

      expect(plan.canIngest, isTrue);
      expect(plan.canBindAdapters, isTrue);
      expect(
        plan.functions.map((function) => function.qualifiedName),
        containsAll(<String>[
          'wasi:sockets/instance-network@0.2.12.instance-network',
          'wasi:sockets/tcp-create-socket@0.2.12.create-tcp-socket',
          'wasi:io/poll@0.2.12.pollable.ready',
        ]),
      );

      final program = preview2.bindWitWorld(
        document,
        worldName: 'sockets-test',
      );
      final tcpSocket =
          program.invokeImport(
                'wasi:sockets/tcp-create-socket@0.2.12.create-tcp-socket',
                [_enumValue('ipv4')],
              )
              as WasmComponentValueData;

      expect(_resourceHandle(_resultOk(tcpSocket)), isNonZero);
      expect(
        preview2.standardImports,
        contains('wasi:sockets/tcp-create-socket@0.2.12.create-tcp-socket'),
      );
    });

    test('Preview2 covers every standard WASI 0.2.x host import', () {
      for (var patch = 0; patch <= 12; patch++) {
        final version = '0.2.$patch';
        final document = WASIComponentWitDocument.parse('''
package wasi-testsuite:preview2-coverage;

world all-imports {
  include wasi:random/imports@$version;
  include wasi:clocks/imports@$version;
  include wasi:io/imports@$version;
  include wasi:cli/imports@$version;
  include wasi:filesystem/imports@$version;
  include wasi:sockets/imports@$version;
  include wasi:http/imports@$version;
  import wasi:http/types@$version;
}
''');
        final preview2 = WASIPreview2ComponentHost();
        final plan = preview2.prepareWitWorld(
          document,
          worldName: 'all-imports',
        );
        final importedFunctions = plan.functions
            .where(
              (function) =>
                  function.direction ==
                  WASIComponentWitWorldItemDirection.import,
            )
            .map((function) => function.qualifiedName)
            .toSet();
        final missing =
            importedFunctions
                .where((name) => !preview2.standardImports.containsKey(name))
                .toList()
              ..sort();

        expect(plan.canIngest, isTrue, reason: version);
        expect(plan.canBindAdapters, isTrue, reason: version);
        expect(plan.bindingErrors, isEmpty, reason: version);
        expect(importedFunctions.length, greaterThan(120), reason: version);
        expect(missing, isEmpty, reason: version);
        expect(
          importedFunctions.contains('wasi:cli/exit@$version.exit-with-code'),
          patch == 12,
          reason: version,
        );
      }
    });

    test('Preview2 expands and binds standard WASI HTTP imports', () {
      const source = '''
package wasi-testsuite:test;

world http-test {
  include wasi:http/imports@0.2.8;
  import wasi:http/types@0.2.8;
  include wasi:io/imports@0.2.8;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final preview2 = WASIPreview2ComponentHost();
      final plan = preview2.prepareWitWorld(document, worldName: 'http-test');

      expect(plan.canIngest, isTrue);
      expect(plan.canBindAdapters, isTrue);
      expect(plan.bindingErrors, isEmpty);
      expect(
        plan.functions.map((function) => function.qualifiedName),
        containsAll(<String>[
          'wasi:http/outgoing-handler@0.2.8.handle',
          'wasi:http/types@0.2.8.fields.constructor',
          'wasi:http/types@0.2.8.fields.from-list',
          'wasi:http/types@0.2.8.outgoing-request.constructor',
          'wasi:http/types@0.2.8.outgoing-body.write',
          'wasi:http/types@0.2.8.future-incoming-response.get',
          'wasi:http/types@0.2.8.incoming-body.%stream',
          'wasi:cli/stdout@0.2.8.get-stdout',
          'wasi:random/random@0.2.8.get-random-bytes',
        ]),
      );
      expect(
        preview2.standardImports,
        contains('wasi:http/outgoing-handler@0.2.8.handle'),
      );
    });

    test('Preview2 HTTP backend completes outgoing request response flow', () {
      const source = '''
package wasi-testsuite:test;

world http-test {
  import wasi:http/types@0.2.0;
  import wasi:http/outgoing-handler@0.2.0;
  include wasi:io/imports@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final backend = _LoopbackHttpBackend();
      final preview2 = WASIPreview2ComponentHost(
        httpHost: WASIPreview2HttpHost(backend: backend),
      );
      final program = preview2.bindWitWorld(document, worldName: 'http-test');
      final headers = _resourceHandle(
        _resultOk(
          program.invokeImport('wasi:http/types@0.2.0.fields.from-list', [
                _httpFieldListValue([
                  ('x-test', [111, 107]),
                ]),
              ])
              as WasmComponentValueData,
        ),
      );
      final request =
          program.invokeImport(
                'wasi:http/types@0.2.0.outgoing-request.constructor',
                [headers],
              )
              as int;
      expect(preview2.componentHost.table.contains(headers), isFalse);

      _expectUnitOk(
        program.invokeImport(
              'wasi:http/types@0.2.0.outgoing-request.set-method',
              [request, _variantCaseValue('post', 2)],
            )
            as WasmComponentValueData,
      );
      _expectUnitOk(
        program.invokeImport(
              'wasi:http/types@0.2.0.outgoing-request.set-scheme',
              [request, _someValue(_variantValue('HTTP'))],
            )
            as WasmComponentValueData,
      );
      _expectUnitOk(
        program.invokeImport(
              'wasi:http/types@0.2.0.outgoing-request.set-authority',
              [request, _someValue(_stringValue('example.test'))],
            )
            as WasmComponentValueData,
      );
      _expectUnitOk(
        program.invokeImport(
              'wasi:http/types@0.2.0.outgoing-request.set-path-with-query',
              [request, _someValue(_stringValue('/hello?x=1'))],
            )
            as WasmComponentValueData,
      );
      final outgoingBody = _resourceHandle(
        _resultOk(
          program.invokeImport('wasi:http/types@0.2.0.outgoing-request.body', [
                request,
              ])
              as WasmComponentValueData,
        ),
      );
      final output = _resourceHandle(
        _resultOk(
          program.invokeImport('wasi:http/types@0.2.0.outgoing-body.write', [
                outgoingBody,
              ])
              as WasmComponentValueData,
        ),
      );
      program.invokeImport('wasi:io/streams@0.2.0.output-stream.check-write', [
        output,
      ]);
      _expectUnitOk(
        program.invokeImport('wasi:io/streams@0.2.0.output-stream.write', [
              output,
              _u8ListValue([1, 2, 3]),
            ])
            as WasmComponentValueData,
      );
      expect(preview2.componentHost.table.contains(outgoingBody), isTrue);
      expect(preview2.componentHost.table.contains(output), isTrue);
      Object? finishError;
      try {
        program.invokeImport('wasi:http/types@0.2.0.outgoing-body.finish', [
          outgoingBody,
          _noneValue(),
        ]);
      } on StateError catch (error) {
        finishError = error;
      }
      expect(finishError.toString(), contains('child handles'));
      expect(preview2.componentHost.table.contains(outgoingBody), isTrue);
      expect(preview2.componentHost.table.contains(output), isTrue);
      preview2.componentHost.table.dropNamed(
        'wasi:io/streams@0.2.0.output-stream',
        output,
      );
      final trailers =
          program.invokeImport(
                'wasi:http/types@0.2.0.fields.constructor',
                const [],
              )
              as int;
      _expectUnitOk(
        program.invokeImport('wasi:http/types@0.2.0.outgoing-body.finish', [
              outgoingBody,
              _someValue(_integerValue(trailers)),
            ])
            as WasmComponentValueData,
      );
      expect(preview2.componentHost.table.contains(outgoingBody), isFalse);
      expect(preview2.componentHost.table.contains(trailers), isFalse);

      final options =
          program.invokeImport(
                'wasi:http/types@0.2.0.request-options.constructor',
                const [],
              )
              as int;

      final future = _resourceHandle(
        _resultOk(
          program.invokeImport('wasi:http/outgoing-handler@0.2.0.handle', [
                request,
                _someValue(_integerValue(options)),
              ])
              as WasmComponentValueData,
        ),
      );
      expect(preview2.componentHost.table.contains(request), isFalse);
      expect(preview2.componentHost.table.contains(options), isFalse);
      final ready =
          program.invokeImport(
                'wasi:http/types@0.2.0.future-incoming-response.get',
                [future],
              )
              as WasmComponentValueData;
      final response = _resourceHandle(
        _resultOk(_resultOk(_optionPayload(ready))),
      );
      final status =
          program.invokeImport(
                'wasi:http/types@0.2.0.incoming-response.status',
                [response],
              )
              as int;
      final responseHeaders =
          program.invokeImport(
                'wasi:http/types@0.2.0.incoming-response.headers',
                [response],
              )
              as int;
      final incomingBody = _resourceHandle(
        _resultOk(
          program.invokeImport(
                'wasi:http/types@0.2.0.incoming-response.consume',
                [response],
              )
              as WasmComponentValueData,
        ),
      );
      final input = _resourceHandle(
        _resultOk(
          program.invokeImport('wasi:http/types@0.2.0.incoming-body.%stream', [
                incomingBody,
              ])
              as WasmComponentValueData,
        ),
      );
      final bytes =
          program.invokeImport('wasi:io/streams@0.2.0.input-stream.read', [
                input,
                BigInt.from(8),
              ])
              as WasmComponentValueData;

      expect(status, 201);
      expect(
        _httpFieldEntryValues(
          _httpFieldEntries(_fieldsEntries(program, responseHeaders)),
          'x-reply',
        ),
        [
          [111, 107],
        ],
      );
      expect(_u8List(_resultOk(bytes)), [104, 105]);
      expect(backend.requestCount, 1);
      expect(backend.lastMethod, 'POST');
      expect(backend.lastAuthority, 'example.test');
      expect(backend.lastPathWithQuery, '/hello?x=1');
      expect(backend.lastBody, [1, 2, 3]);
      expect(backend.lastHeaderNames, contains('x-test'));
    });

    test(
      'Preview2 outgoing handler rejects invalid requests before backend I/O',
      () {
        const source = '''
package wasi-testsuite:test;

world http-test {
  import wasi:http/types@0.2.0;
  import wasi:http/outgoing-handler@0.2.0;
}
''';
        final invalidRequests = [
          (
            name: 'HTTP without authority',
            headers: <(String, List<int>)>[],
            setScheme: true,
            authority: null,
            errorCode: 'HTTP-request-URI-invalid',
          ),
          (
            name: 'default HTTP without authority',
            headers: <(String, List<int>)>[],
            setScheme: false,
            authority: null,
            errorCode: 'HTTP-request-URI-invalid',
          ),
          (
            name: 'HTTP userinfo authority',
            headers: <(String, List<int>)>[],
            setScheme: true,
            authority: 'user@example.test',
            errorCode: 'HTTP-request-URI-invalid',
          ),
          (
            name: 'HTTP empty userinfo authority',
            headers: <(String, List<int>)>[],
            setScheme: true,
            authority: '@example.test',
            errorCode: 'HTTP-request-URI-invalid',
          ),
          (
            name: 'Host header',
            headers: <(String, List<int>)>[('Host', 'other.example'.codeUnits)],
            setScheme: true,
            authority: 'example.test',
            errorCode: 'HTTP-request-denied',
          ),
          (
            name: 'malformed Content-Length',
            headers: <(String, List<int>)>[('Content-Length', '+5'.codeUnits)],
            setScheme: true,
            authority: 'example.test',
            errorCode: 'HTTP-request-body-size',
          ),
          (
            name: 'conflicting Content-Length',
            headers: <(String, List<int>)>[
              ('Content-Length', '5'.codeUnits),
              ('content-length', '6'.codeUnits),
            ],
            setScheme: true,
            authority: 'example.test',
            errorCode: 'HTTP-request-body-size',
          ),
        ];

        for (final invalidRequest in invalidRequests) {
          final backend = _LoopbackHttpBackend();
          final preview2 = WASIPreview2ComponentHost(
            httpHost: WASIPreview2HttpHost(backend: backend),
          );
          final program = preview2.bindWitWorld(
            WASIComponentWitDocument.parse(source),
            worldName: 'http-test',
          );
          final headers = _resourceHandle(
            _resultOk(
              program.invokeImport('wasi:http/types@0.2.0.fields.from-list', [
                    _httpFieldListValue(invalidRequest.headers),
                  ])
                  as WasmComponentValueData,
            ),
          );
          final request =
              program.invokeImport(
                    'wasi:http/types@0.2.0.outgoing-request.constructor',
                    [headers],
                  )
                  as int;
          if (invalidRequest.setScheme) {
            _expectUnitOk(
              program.invokeImport(
                    'wasi:http/types@0.2.0.outgoing-request.set-scheme',
                    [request, _someValue(_variantValue('HTTP'))],
                  )
                  as WasmComponentValueData,
            );
          }
          if (invalidRequest.authority case final authority?) {
            _expectUnitOk(
              program.invokeImport(
                    'wasi:http/types@0.2.0.outgoing-request.set-authority',
                    [request, _someValue(_stringValue(authority))],
                  )
                  as WasmComponentValueData,
            );
          }
          final options =
              program.invokeImport(
                    'wasi:http/types@0.2.0.request-options.constructor',
                    const [],
                  )
                  as int;

          final handled =
              program.invokeImport('wasi:http/outgoing-handler@0.2.0.handle', [
                    request,
                    _someValue(_integerValue(options)),
                  ])
                  as WasmComponentValueData;

          expect(
            _resultErrorLabel(handled),
            invalidRequest.errorCode,
            reason: invalidRequest.name,
          );
          final error = handled.associatedValue!;
          if (invalidRequest.errorCode == 'HTTP-request-body-size') {
            expect(
              error.associatedValue?.kind,
              WasmComponentValueDataKind.option,
            );
            expect(error.associatedValue?.index, 0);
          } else {
            expect(error.associatedValue, isNull);
          }
          expect(
            preview2.componentHost.table.contains(request),
            isFalse,
            reason: invalidRequest.name,
          );
          expect(
            preview2.componentHost.table.contains(options),
            isFalse,
            reason: invalidRequest.name,
          );
          expect(backend.requestCount, 0, reason: invalidRequest.name);
        }
      },
    );

    test(
      'Preview2 HTTP resources expose fields requests responses and trailers',
      () {
        const source = '''
package wasi-testsuite:test;

world http-test {
  import wasi:http/types@0.2.0;
  include wasi:io/imports@0.2.0;
}
''';
        final document = WASIComponentWitDocument.parse(source);
        final preview2 = WASIPreview2ComponentHost();
        final program = preview2.bindWitWorld(document, worldName: 'http-test');
        final fields = _resourceHandle(
          _resultOk(
            program.invokeImport('wasi:http/types@0.2.0.fields.from-list', [
                  _httpFieldListValue([
                    ('x-test', [49]),
                    ('x-test', [50]),
                  ]),
                ])
                as WasmComponentValueData,
          ),
        );

        expect(
          _httpFieldValues(
            program.invokeImport('wasi:http/types@0.2.0.fields.get', [
                  fields,
                  'X-Test',
                ])
                as WasmComponentValueData,
          ),
          [
            [49],
            [50],
          ],
        );
        expect(
          program.invokeImport('wasi:http/types@0.2.0.fields.has', [
            fields,
            'x-test',
          ]),
          isTrue,
        );
        _expectUnitOk(
          program.invokeImport('wasi:http/types@0.2.0.fields.set', [
                fields,
                'x-set',
                _httpFieldValuesValue([
                  [51],
                  [52],
                ]),
              ])
              as WasmComponentValueData,
        );
        _expectUnitOk(
          program.invokeImport('wasi:http/types@0.2.0.fields.delete', [
                fields,
                'x-test',
              ])
              as WasmComponentValueData,
        );
        final clonedFields =
            program.invokeImport('wasi:http/types@0.2.0.fields.clone', [fields])
                as int;
        _expectUnitOk(
          program.invokeImport('wasi:http/types@0.2.0.fields.append', [
                clonedFields,
                'x-clone',
                _u8ListValue([53]),
              ])
              as WasmComponentValueData,
        );

        final clonedFieldEntries = _httpFieldEntries(
          _fieldsEntries(program, clonedFields),
        );
        expect(_httpFieldEntryValues(clonedFieldEntries, 'x-set'), [
          [51],
          [52],
        ]);
        expect(_httpFieldEntryValues(clonedFieldEntries, 'x-clone'), [
          [53],
        ]);
        expect(
          program.invokeImport('wasi:http/types@0.2.0.fields.has', [
            fields,
            'x-test',
          ]),
          isFalse,
        );

        final request =
            program.invokeImport(
                  'wasi:http/types@0.2.0.outgoing-request.constructor',
                  [clonedFields],
                )
                as int;
        expect(
          _caseLabel(
            program.invokeImport(
                  'wasi:http/types@0.2.0.outgoing-request.method',
                  [request],
                )
                as WasmComponentValueData,
          ),
          'get',
        );
        _expectUnitOk(
          program.invokeImport(
                'wasi:http/types@0.2.0.outgoing-request.set-method',
                [request, _variantCaseValue('patch', 8)],
              )
              as WasmComponentValueData,
        );
        _expectUnitOk(
          program.invokeImport(
                'wasi:http/types@0.2.0.outgoing-request.set-scheme',
                [request, _someValue(_variantCaseValue('HTTPS', 1))],
              )
              as WasmComponentValueData,
        );
        _expectUnitOk(
          program.invokeImport(
                'wasi:http/types@0.2.0.outgoing-request.set-authority',
                [request, _someValue(_stringValue('api.example.test'))],
              )
              as WasmComponentValueData,
        );
        _expectUnitOk(
          program.invokeImport(
                'wasi:http/types@0.2.0.outgoing-request.set-path-with-query',
                [request, _someValue(_stringValue('/v1?q=1'))],
              )
              as WasmComponentValueData,
        );

        expect(
          _caseLabel(
            program.invokeImport(
                  'wasi:http/types@0.2.0.outgoing-request.method',
                  [request],
                )
                as WasmComponentValueData,
          ),
          'patch',
        );
        expect(
          _caseLabel(
            _optionPayload(
              program.invokeImport(
                    'wasi:http/types@0.2.0.outgoing-request.scheme',
                    [request],
                  )
                  as WasmComponentValueData,
            ),
          ),
          'HTTPS',
        );
        expect(
          _optionString(
            program.invokeImport(
                  'wasi:http/types@0.2.0.outgoing-request.authority',
                  [request],
                )
                as WasmComponentValueData,
          ),
          'api.example.test',
        );
        expect(
          _optionString(
            program.invokeImport(
                  'wasi:http/types@0.2.0.outgoing-request.path-with-query',
                  [request],
                )
                as WasmComponentValueData,
          ),
          '/v1?q=1',
        );
        final requestHeaders =
            program.invokeImport(
                  'wasi:http/types@0.2.0.outgoing-request.headers',
                  [request],
                )
                as int;
        expect(
          _httpFieldEntryValues(
            _httpFieldEntries(_fieldsEntries(program, requestHeaders)),
            'x-clone',
          ),
          [
            [53],
          ],
        );

        final options =
            program.invokeImport(
                  'wasi:http/types@0.2.0.request-options.constructor',
                  const [],
                )
                as int;
        _expectUnitOk(
          program.invokeImport(
                'wasi:http/types@0.2.0.request-options.set-connect-timeout',
                [options, _someValue(_integerValue(BigInt.from(1000)))],
              )
              as WasmComponentValueData,
        );
        _expectUnitOk(
          program.invokeImport(
                'wasi:http/types@0.2.0.request-options.set-first-byte-timeout',
                [options, _someValue(_integerValue(BigInt.from(2000)))],
              )
              as WasmComponentValueData,
        );
        _expectUnitOk(
          program.invokeImport(
                'wasi:http/types@0.2.0.request-options.set-between-bytes-timeout',
                [options, _someValue(_integerValue(BigInt.from(3000)))],
              )
              as WasmComponentValueData,
        );
        expect(
          _optionU64(
            program.invokeImport(
                  'wasi:http/types@0.2.0.request-options.connect-timeout',
                  [options],
                )
                as WasmComponentValueData,
          ),
          BigInt.from(1000),
        );
        expect(
          _optionU64(
            program.invokeImport(
                  'wasi:http/types@0.2.0.request-options.first-byte-timeout',
                  [options],
                )
                as WasmComponentValueData,
          ),
          BigInt.from(2000),
        );
        expect(
          _optionU64(
            program.invokeImport(
                  'wasi:http/types@0.2.0.request-options.between-bytes-timeout',
                  [options],
                )
                as WasmComponentValueData,
          ),
          BigInt.from(3000),
        );

        final responseHeaders = _resourceHandle(
          _resultOk(
            program.invokeImport('wasi:http/types@0.2.0.fields.from-list', [
                  _httpFieldListValue([
                    ('x-response', [54]),
                  ]),
                ])
                as WasmComponentValueData,
          ),
        );
        final response =
            program.invokeImport(
                  'wasi:http/types@0.2.0.outgoing-response.constructor',
                  [responseHeaders],
                )
                as int;
        expect(preview2.componentHost.table.contains(responseHeaders), isFalse);
        expect(
          program.invokeImport(
            'wasi:http/types@0.2.0.outgoing-response.status-code',
            [response],
          ),
          200,
        );
        _expectUnitOk(
          program.invokeImport(
                'wasi:http/types@0.2.0.outgoing-response.set-status-code',
                [response, 202],
              )
              as WasmComponentValueData,
        );
        expect(
          program.invokeImport(
            'wasi:http/types@0.2.0.outgoing-response.status-code',
            [response],
          ),
          202,
        );
        final clonedResponseHeaders =
            program.invokeImport(
                  'wasi:http/types@0.2.0.outgoing-response.headers',
                  [response],
                )
                as int;
        expect(
          _httpFieldEntryValues(
            _httpFieldEntries(_fieldsEntries(program, clonedResponseHeaders)),
            'x-response',
          ),
          [
            [54],
          ],
        );
        preview2.componentHost.table.dropNamed(
          'wasi:http/types@0.2.0.fields',
          clonedResponseHeaders,
        );
        expect(
          _resourceHandle(
            _resultOk(
              program.invokeImport(
                    'wasi:http/types@0.2.0.outgoing-response.body',
                    [response],
                  )
                  as WasmComponentValueData,
            ),
          ),
          isNonZero,
        );
        final outparam = WASIPreview2HttpResponseOutparam();
        final outparamHandle = preview2.httpHost.insertResponseOutparam(
          outparam,
        );
        expect(
          program.invokeImport('wasi:http/types@0.2.0.response-outparam.set', [
            outparamHandle,
            _resultOkValue(_integerValue(response)),
          ]),
          isNull,
        );
        expect(outparam.response?.value?.statusCode, 202);
        expect(preview2.componentHost.table.contains(outparamHandle), isFalse);
        expect(preview2.componentHost.table.contains(response), isFalse);

        final incomingRequest = preview2.httpHost.insertIncomingRequest(
          WASIPreview2HttpIncomingRequest(
            method: const WASIPreview2HttpMethod.standard('post'),
            headers: WASIPreview2HttpFields(
              entries: const <WASIPreview2HttpFieldEntry>[
                WASIPreview2HttpFieldEntry('x-incoming', <int>[55]),
              ],
              mutable: false,
            ),
            pathWithQuery: '/incoming?q=1',
            scheme: const WASIPreview2HttpScheme.standard('HTTPS'),
            authority: 'svc.example.test',
            body: WASIPreview2HttpIncomingBody(
              WASIPreview2InputStream(bytes: const <int>[56], closed: true),
              trailers: WASIPreview2HttpFutureTrailers.completed(
                WASIPreview2HttpResult<WASIPreview2HttpFields?>.ok(
                  WASIPreview2HttpFields(
                    entries: const <WASIPreview2HttpFieldEntry>[
                      WASIPreview2HttpFieldEntry('x-trailer', <int>[57]),
                    ],
                    mutable: false,
                  ),
                ),
              ),
            ),
          ),
        );

        expect(
          _caseLabel(
            program.invokeImport(
                  'wasi:http/types@0.2.0.incoming-request.method',
                  [incomingRequest],
                )
                as WasmComponentValueData,
          ),
          'post',
        );
        expect(
          _optionString(
            program.invokeImport(
                  'wasi:http/types@0.2.0.incoming-request.path-with-query',
                  [incomingRequest],
                )
                as WasmComponentValueData,
          ),
          '/incoming?q=1',
        );
        expect(
          _caseLabel(
            _optionPayload(
              program.invokeImport(
                    'wasi:http/types@0.2.0.incoming-request.scheme',
                    [incomingRequest],
                  )
                  as WasmComponentValueData,
            ),
          ),
          'HTTPS',
        );
        expect(
          _optionString(
            program.invokeImport(
                  'wasi:http/types@0.2.0.incoming-request.authority',
                  [incomingRequest],
                )
                as WasmComponentValueData,
          ),
          'svc.example.test',
        );
        final incomingHeaders =
            program.invokeImport(
                  'wasi:http/types@0.2.0.incoming-request.headers',
                  [incomingRequest],
                )
                as int;
        expect(
          _httpFieldEntryValues(
            _httpFieldEntries(_fieldsEntries(program, incomingHeaders)),
            'x-incoming',
          ),
          [
            [55],
          ],
        );
        final incomingBody = _resourceHandle(
          _resultOk(
            program.invokeImport(
                  'wasi:http/types@0.2.0.incoming-request.consume',
                  [incomingRequest],
                )
                as WasmComponentValueData,
          ),
        );
        final futureTrailers =
            program.invokeImport('wasi:http/types@0.2.0.incoming-body.finish', [
                  incomingBody,
                ])
                as int;
        expect(preview2.componentHost.table.contains(incomingBody), isFalse);
        final trailersPollable =
            program.invokeImport(
                  'wasi:http/types@0.2.0.future-trailers.subscribe',
                  [futureTrailers],
                )
                as int;
        expect(
          program.invokeImport('wasi:io/poll@0.2.0.pollable.ready', [
            trailersPollable,
          ]),
          isTrue,
        );
        final trailers =
            program.invokeImport('wasi:http/types@0.2.0.future-trailers.get', [
                  futureTrailers,
                ])
                as WasmComponentValueData;
        final trailerFields = _optionHandle(
          _resultOk(_resultOk(_optionPayload(trailers))),
        );

        expect(trailerFields, isNotNull);
        expect(
          _httpFieldEntryValues(
            _httpFieldEntries(_fieldsEntries(program, trailerFields!)),
            'x-trailer',
          ),
          [
            [57],
          ],
        );
      },
    );

    test('Preview2 HTTP maps errors and informational outparams', () {
      const source = '''
package wasi-testsuite:test;

world http-test {
  import wasi:http/types@0.2.0;
  import wasi:io/error@0.2.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final preview2 = WASIPreview2ComponentHost();
      final program = preview2.bindWitWorld(document, worldName: 'http-test');
      final timeoutError = preview2.errorHost.insert(
        const WASIPreview2IoError('HTTP-response-timeout'),
      );
      final unknownError = preview2.errorHost.insert(
        const WASIPreview2IoError('application error'),
      );
      final timeoutCode =
          program.invokeImport('wasi:http/types@0.2.0.http-error-code', [
                timeoutError,
              ])
              as WasmComponentValueData;
      final unknownCode =
          program.invokeImport('wasi:http/types@0.2.0.http-error-code', [
                unknownError,
              ])
              as WasmComponentValueData;
      const payloadCases = <String>{
        'DNS-error',
        'TLS-alert-received',
        'HTTP-request-body-size',
        'HTTP-request-header-section-size',
        'HTTP-request-header-size',
        'HTTP-request-trailer-section-size',
        'HTTP-request-trailer-size',
        'HTTP-response-header-section-size',
        'HTTP-response-header-size',
        'HTTP-response-body-size',
        'HTTP-response-trailer-section-size',
        'HTTP-response-trailer-size',
        'HTTP-response-transfer-coding',
        'HTTP-response-content-coding',
        'internal-error',
      };
      for (final errorCode in payloadCases) {
        final errorHandle = preview2.errorHost.insert(
          WASIPreview2IoError(errorCode),
        );
        final option =
            program.invokeImport('wasi:http/types@0.2.0.http-error-code', [
                  errorHandle,
                ])
                as WasmComponentValueData;
        final error = _optionPayload(option);
        expect(_caseLabel(error), errorCode);
        expect(error.associatedValue, isNotNull, reason: errorCode);
      }
      final outparam = WASIPreview2HttpResponseOutparam();
      final outparamHandle = preview2.httpHost.insertResponseOutparam(outparam);
      final fields =
          program.invokeImport(
                'wasi:http/types@0.2.0.fields.constructor',
                const [],
              )
              as int;
      _expectUnitOk(
        program.invokeImport('wasi:http/types@0.2.0.fields.append', [
              fields,
              'x-info',
              _u8ListValue([111, 107]),
            ])
            as WasmComponentValueData,
      );
      _expectUnitOk(
        program.invokeImport(
              'wasi:http/types@0.2.0.response-outparam.send-informational',
              [outparamHandle, 103, fields],
            )
            as WasmComponentValueData,
      );
      expect(preview2.componentHost.table.contains(fields), isFalse);
      final invalidFields =
          program.invokeImport(
                'wasi:http/types@0.2.0.fields.constructor',
                const [],
              )
              as int;
      final invalidInformational =
          program.invokeImport(
                'wasi:http/types@0.2.0.response-outparam.send-informational',
                [outparamHandle, 200, invalidFields],
              )
              as WasmComponentValueData;
      expect(preview2.componentHost.table.contains(invalidFields), isFalse);

      expect(_optionCaseLabel(timeoutCode), 'HTTP-response-timeout');
      expect(_optionCaseLabel(unknownCode), isNull);
      expect(outparam.informationalResponses, hasLength(1));
      expect(outparam.informationalResponses.single.status, 103);
      expect(
        outparam.informationalResponses.single.headers.entries.single.name,
        'x-info',
      );
      expect(_resultErrorLabel(invalidInformational), 'HTTP-protocol-error');

      final errorOutparam = WASIPreview2HttpResponseOutparam();
      final errorOutparamHandle = preview2.httpHost.insertResponseOutparam(
        errorOutparam,
      );
      expect(
        program.invokeImport('wasi:http/types@0.2.0.response-outparam.set', [
          errorOutparamHandle,
          _resultErrorValue(_variantCaseValue('HTTP-protocol-error', 35)),
        ]),
        isNull,
      );
      expect(
        preview2.componentHost.table.contains(errorOutparamHandle),
        isFalse,
      );
      expect(errorOutparam.response?.errorCode, 'HTTP-protocol-error');
    });

    test('Preview2 HTTP proxy export sets response outparam', () {
      const source = '''
package wasi-testsuite:test;

world proxy-test {
  include wasi:http/proxy@0.2.8;
  import wasi:http/types@0.2.8;
  include wasi:io/imports@0.2.8;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final preview2 = WASIPreview2ComponentHost();
      final plan = preview2.prepareWitWorld(document, worldName: 'proxy-test');

      expect(plan.canIngest, isTrue);
      expect(plan.canBindAdapters, isTrue);
      expect(plan.bindingErrors, isEmpty);
      expect(
        plan.functions.map((function) => function.qualifiedName),
        containsAll(<String>[
          'wasi:http/outgoing-handler@0.2.8.handle',
          'wasi:http/types@0.2.8.outgoing-response.constructor',
          'wasi:http/types@0.2.8.response-outparam.set',
          'wasi:http/incoming-handler@0.2.8.handle',
        ]),
      );

      late final WASIComponentWitAdapterProgram program;
      program = preview2.bindWitWorld(
        document,
        worldName: 'proxy-test',
        exports: {
          'wasi:http/incoming-handler@0.2.8.handle': (args) {
            final request = args[0] as int;
            final responseOut = args[1] as int;
            final path =
                program.invokeImport(
                      'wasi:http/types@0.2.8.incoming-request.path-with-query',
                      [request],
                    )
                    as WasmComponentValueData;

            expect(_optionString(path), '/proxy');

            final fields =
                program.invokeImport(
                      'wasi:http/types@0.2.8.fields.constructor',
                      const [],
                    )
                    as int;
            _expectUnitOk(
              program.invokeImport('wasi:http/types@0.2.8.fields.append', [
                    fields,
                    'x-proxy',
                    _u8ListValue([111, 107]),
                  ])
                  as WasmComponentValueData,
            );
            final response =
                program.invokeImport(
                      'wasi:http/types@0.2.8.outgoing-response.constructor',
                      [fields],
                    )
                    as int;
            expect(preview2.componentHost.table.contains(fields), isFalse);
            _expectUnitOk(
              program.invokeImport(
                    'wasi:http/types@0.2.8.outgoing-response.set-status-code',
                    [response, 204],
                  )
                  as WasmComponentValueData,
            );
            final outgoingBody = _resourceHandle(
              _resultOk(
                program.invokeImport(
                      'wasi:http/types@0.2.8.outgoing-response.body',
                      [response],
                    )
                    as WasmComponentValueData,
              ),
            );
            final output = _resourceHandle(
              _resultOk(
                program.invokeImport(
                      'wasi:http/types@0.2.8.outgoing-body.write',
                      [outgoingBody],
                    )
                    as WasmComponentValueData,
              ),
            );

            program.invokeImport(
              'wasi:io/streams@0.2.8.output-stream.check-write',
              [output],
            );
            _expectUnitOk(
              program.invokeImport(
                    'wasi:io/streams@0.2.8.output-stream.write',
                    [
                      output,
                      _u8ListValue([111, 107]),
                    ],
                  )
                  as WasmComponentValueData,
            );
            expect(
              () => program.invokeImport(
                'wasi:http/types@0.2.8.outgoing-body.finish',
                [outgoingBody, _noneValue()],
              ),
              throwsStateError,
            );
            preview2.componentHost.table.dropNamed(
              'wasi:io/streams@0.2.0.output-stream',
              output,
            );
            _expectUnitOk(
              program.invokeImport(
                    'wasi:http/types@0.2.8.outgoing-body.finish',
                    [outgoingBody, _noneValue()],
                  )
                  as WasmComponentValueData,
            );
            expect(
              preview2.componentHost.table.contains(outgoingBody),
              isFalse,
            );
            program.invokeImport(
              'wasi:http/types@0.2.8.response-outparam.set',
              [responseOut, _resultOkValue(_integerValue(response))],
            );
            expect(preview2.componentHost.table.contains(responseOut), isFalse);
            expect(preview2.componentHost.table.contains(response), isFalse);
            return null;
          },
        },
      );
      final responseOutparam = WASIPreview2HttpResponseOutparam();
      final incoming = preview2.httpHost.insertIncomingRequest(
        WASIPreview2HttpIncomingRequest(
          method: const WASIPreview2HttpMethod.standard('get'),
          headers: WASIPreview2HttpFields(),
          pathWithQuery: '/proxy',
          scheme: const WASIPreview2HttpScheme.standard('HTTP'),
          authority: 'example.test',
        ),
      );
      final responseOut = preview2.httpHost.insertResponseOutparam(
        responseOutparam,
      );

      expect(
        program.invokeExport('wasi:http/incoming-handler@0.2.8.handle', [
          incoming,
          responseOut,
        ]),
        isNull,
      );

      final responseResult = responseOutparam.response;
      expect(responseResult, isNotNull);
      expect(responseResult!.isOk, isTrue);
      final response = responseResult.value!;
      expect(response.statusCode, 204);
      expect(response.headers.entries.map((entry) => entry.name), ['x-proxy']);
      expect(response.bodyResource?.bytes, [111, 107]);
      expect(response.bodyResource?.isFinished, isTrue);
    });

    test('Preview2 outgoing body finish enforces Content-Length', () {
      const source = '''
package wasi-testsuite:test;

world http-test {
  import wasi:http/types@0.2.0;
  include wasi:io/imports@0.2.0;
}
''';
      final preview2 = WASIPreview2ComponentHost();
      final program = preview2.bindWitWorld(
        WASIComponentWitDocument.parse(source),
        worldName: 'http-test',
      );

      final malformedHeaders = _resourceHandle(
        _resultOk(
          program.invokeImport('wasi:http/types@0.2.0.fields.from-list', [
                _httpFieldListValue([('content-length', '+3'.codeUnits)]),
              ])
              as WasmComponentValueData,
        ),
      );
      final malformedResponse =
          program.invokeImport(
                'wasi:http/types@0.2.0.outgoing-response.constructor',
                [malformedHeaders],
              )
              as int;
      expect(
        (program.invokeImport('wasi:http/types@0.2.0.outgoing-response.body', [
                  malformedResponse,
                ])
                as WasmComponentValueData)
            .isOk,
        isFalse,
      );

      WasmComponentValueData finishBody(List<int> bytes) {
        final headers = _resourceHandle(
          _resultOk(
            program.invokeImport('wasi:http/types@0.2.0.fields.from-list', [
                  _httpFieldListValue([
                    ('content-length', [51]),
                  ]),
                ])
                as WasmComponentValueData,
          ),
        );
        final request =
            program.invokeImport(
                  'wasi:http/types@0.2.0.outgoing-request.constructor',
                  [headers],
                )
                as int;
        final body = _resourceHandle(
          _resultOk(
            program.invokeImport(
                  'wasi:http/types@0.2.0.outgoing-request.body',
                  [request],
                )
                as WasmComponentValueData,
          ),
        );
        final output = _resourceHandle(
          _resultOk(
            program.invokeImport('wasi:http/types@0.2.0.outgoing-body.write', [
                  body,
                ])
                as WasmComponentValueData,
          ),
        );
        program.invokeImport(
          'wasi:io/streams@0.2.0.output-stream.check-write',
          [output],
        );
        _expectUnitOk(
          program.invokeImport('wasi:io/streams@0.2.0.output-stream.write', [
                output,
                _u8ListValue(bytes),
              ])
              as WasmComponentValueData,
        );
        preview2.componentHost.table.dropNamed(
          'wasi:io/streams@0.2.0.output-stream',
          output,
        );
        return program.invokeImport(
              'wasi:http/types@0.2.0.outgoing-body.finish',
              [body, _noneValue()],
            )
            as WasmComponentValueData;
      }

      expect(_resultErrorLabel(finishBody([1, 2])), 'HTTP-protocol-error');
      _expectUnitOk(finishBody([1, 2, 3]));
    });

    test('Preview2 HTTP fields own immutable copies of entry values', () {
      final sourceValue = <int>[49];
      final fields = WASIPreview2HttpFields(
        entries: <WASIPreview2HttpFieldEntry>[
          WASIPreview2HttpFieldEntry('content-length', sourceValue),
        ],
        mutable: false,
      );
      final clone = fields.immutableClone();

      sourceValue[0] = 50;

      expect(fields.entries.single.value, [49]);
      expect(clone.entries.single.value, [49]);
      expect(
        identical(fields.entries.single.value, clone.entries.single.value),
        isFalse,
      );
      expect(() => fields.entries.single.value[0] = 51, throwsUnsupportedError);
      expect(() => clone.entries.single.value.add(52), throwsUnsupportedError);
    });

    test('Preview2 incoming request without a body exposes closed input', () {
      final request = WASIPreview2HttpIncomingRequest(
        method: const WASIPreview2HttpMethod.standard('get'),
        headers: WASIPreview2HttpFields(),
      );

      final body = request.consume()!;
      final stream = body.takeStream()!;

      expect(stream.isReadable, isTrue);
      expect(body.finish().isReady, isTrue);
    });

    test(
      'Preview2 future trailers follow incoming body completion and errors',
      () async {
        const source = '''
package wasi-testsuite:test;

world http-test {
  import wasi:http/types@0.2.0;
  include wasi:io/imports@0.2.0;
}
''';
        final preview2 = WASIPreview2ComponentHost();
        final program = preview2.bindWitWorld(
          WASIComponentWitDocument.parse(source),
          worldName: 'http-test',
        );

        final gatedStream = WASIPreview2InputStream();
        final gatedTrailers = WASIPreview2HttpIncomingBody(
          gatedStream,
          trailers: WASIPreview2HttpFutureTrailers.completed(
            const WASIPreview2HttpResult<WASIPreview2HttpFields?>.ok(null),
          ),
        ).finish();

        expect(gatedTrailers.isReady, isFalse);
        gatedStream.close();
        await gatedTrailers.waitReady();
        expect(gatedTrailers.isReady, isTrue);

        int finishBody(
          WASIPreview2InputStream stream, {
          WASIPreview2HttpFutureTrailers? trailers,
        }) {
          final request = preview2.httpHost.insertIncomingRequest(
            WASIPreview2HttpIncomingRequest(
              method: const WASIPreview2HttpMethod.standard('get'),
              headers: WASIPreview2HttpFields(),
              body: WASIPreview2HttpIncomingBody(stream, trailers: trailers),
            ),
          );
          final body = _resourceHandle(
            _resultOk(
              program.invokeImport(
                    'wasi:http/types@0.2.0.incoming-request.consume',
                    [request],
                  )
                  as WasmComponentValueData,
            ),
          );
          return program.invokeImport(
                'wasi:http/types@0.2.0.incoming-body.finish',
                [body],
              )
              as int;
        }

        final cleanStream = WASIPreview2InputStream();
        final cleanTrailers = finishBody(cleanStream);
        final cleanPollable =
            program.invokeImport(
                  'wasi:http/types@0.2.0.future-trailers.subscribe',
                  [cleanTrailers],
                )
                as int;

        expect(
          program.invokeImport('wasi:io/poll@0.2.0.pollable.ready', [
            cleanPollable,
          ]),
          isFalse,
        );
        cleanStream.close();
        await Future<void>.delayed(Duration.zero);
        expect(
          program.invokeImport('wasi:io/poll@0.2.0.pollable.ready', [
            cleanPollable,
          ]),
          isTrue,
        );
        final cleanResult =
            program.invokeImport('wasi:http/types@0.2.0.future-trailers.get', [
                  cleanTrailers,
                ])
                as WasmComponentValueData;
        expect(
          _optionHandle(_resultOk(_resultOk(_optionPayload(cleanResult)))),
          isNull,
        );

        final failedStream = WASIPreview2InputStream();
        final failedTrailers = finishBody(failedStream);
        final failedPollable =
            program.invokeImport(
                  'wasi:http/types@0.2.0.future-trailers.subscribe',
                  [failedTrailers],
                )
                as int;

        expect(
          program.invokeImport('wasi:io/poll@0.2.0.pollable.ready', [
            failedPollable,
          ]),
          isFalse,
        );
        failedStream.fail('HTTP-response-timeout');
        await Future<void>.delayed(Duration.zero);
        expect(
          program.invokeImport('wasi:io/poll@0.2.0.pollable.ready', [
            failedPollable,
          ]),
          isTrue,
        );
        final failedResult =
            program.invokeImport('wasi:http/types@0.2.0.future-trailers.get', [
                  failedTrailers,
                ])
                as WasmComponentValueData;
        final bodyResult = _resultOk(_optionPayload(failedResult));

        expect(_resultErrorLabel(bodyResult), 'HTTP-response-timeout');

        final suppliedTrailers = WASIPreview2HttpFutureTrailers.completed(
          WASIPreview2HttpResult<WASIPreview2HttpFields?>.ok(
            WASIPreview2HttpFields(
              entries: const <WASIPreview2HttpFieldEntry>[
                WASIPreview2HttpFieldEntry('x-shared', <int>[49]),
              ],
            ),
          ),
        );
        final firstStream = WASIPreview2InputStream();
        final secondStream = WASIPreview2InputStream();
        final sharedHandles = <int>[
          finishBody(firstStream, trailers: suppliedTrailers),
          finishBody(secondStream, trailers: suppliedTrailers),
        ];
        firstStream.close();
        secondStream.close();
        await Future<void>.delayed(Duration.zero);

        for (final handle in sharedHandles) {
          final result =
              program.invokeImport(
                    'wasi:http/types@0.2.0.future-trailers.get',
                    [handle],
                  )
                  as WasmComponentValueData;
          final fields = _optionHandle(
            _resultOk(_resultOk(_optionPayload(result))),
          );
          expect(fields, isNotNull);
          expect(
            _httpFieldEntryValues(
              _httpFieldEntries(_fieldsEntries(program, fields!)),
              'x-shared',
            ),
            [
              [49],
            ],
          );
        }
      },
    );

    test('Preview2 preopens allocate only runtime-scoped handles', () async {
      final table = WASIComponentResourceTable();
      final filesystem = WASIPreview2FilesystemHost(
        table: table,
        preopens: <String, WASIPreview2FilesystemDirectory>{
          '/workspace': WASIPreview2FilesystemDirectory(),
        },
      );

      expect(table.activeCount, 0);
      await table.runScoped<void>(() async {
        final directories =
            filesystem
                    .imports['wasi:filesystem/preopens@0.2.0.get-directories']!(
                  const <Object?>[],
                )
                as WasmComponentValueData;
        final descriptor = _filesystemPreopens(directories).single.$1;

        expect(table.contains(descriptor), isTrue);
        expect(table.activeCount, 1);
      });
      expect(table.activeCount, 0);
    });

    test(
      'Preview2 filesystem preserves descriptor flags and follows symlinks only when requested',
      () {
        const source = '''
package wasi-testsuite:test;

world filesystem-test {
  include wasi:filesystem/imports@0.2.0;
}
''';
        const unicodeLinkTarget = '目标';
        final dynamicallyCreatedEntries =
            <WASIPreview2FilesystemDirectoryEntry>[];
        var dynamicCreateCalls = 0;
        var noteSetTimesCalls = 0;
        final linkedSources = <String>[];
        final dynamicDirectory = WASIPreview2FilesystemDirectory.dynamic(
          canMutate: true,
          entries: () => dynamicallyCreatedEntries,
          resolveEntry: (name) {
            for (final entry in dynamicallyCreatedEntries) {
              if (entry.name == name) {
                return entry;
              }
            }
            return null;
          },
          createFile: (name) {
            dynamicCreateCalls++;
            final entry = WASIPreview2FilesystemDirectoryEntry.regularFile(
              name,
              canMutate: true,
              currentSize: () => BigInt.zero,
              readBytes: (_) => Uint8List(0),
              writeBytes: (_, _) =>
                  const WASIPreview2FilesystemMutationResult.ok(),
            );
            dynamicallyCreatedEntries.add(entry);
            return entry;
          },
        );
        final filesystem = WASIPreview2FilesystemHost(
          preopens: {
            '/': WASIPreview2FilesystemDirectory(
              canMutate: true,
              link: (oldName, _, _) {
                linkedSources.add(oldName);
                return const WASIPreview2FilesystemMutationResult.ok();
              },
              entries: [
                WASIPreview2FilesystemDirectoryEntry.regularFile(
                  'note.txt',
                  bytes: const <int>[104, 101, 108, 108, 111],
                  canMutate: true,
                  setTimes: (_) {
                    noteSetTimesCalls++;
                    return const WASIPreview2FilesystemMutationResult.ok();
                  },
                ),
                WASIPreview2FilesystemDirectoryEntry.symbolicLink(
                  'note-link',
                  target: 'note.txt',
                ),
                WASIPreview2FilesystemDirectoryEntry.symbolicLink(
                  'unicode-link',
                  target: unicodeLinkTarget,
                ),
                WASIPreview2FilesystemDirectoryEntry.regularFile(
                  'external.txt',
                  canMutate: true,
                  readBytes: (_) => Uint8List(0),
                  currentSize: () => BigInt.zero,
                  writeBytes: (_, _) =>
                      const WASIPreview2FilesystemMutationResult.ok(),
                ),
                WASIPreview2FilesystemDirectoryEntry.directory(
                  'dynamic',
                  directory: dynamicDirectory,
                ),
                WASIPreview2FilesystemDirectoryEntry.symbolicLink(
                  'dynamic-link',
                  target: 'dynamic',
                ),
                WASIPreview2FilesystemDirectoryEntry.symbolicLink(
                  'loop-a',
                  target: 'loop-b',
                ),
                WASIPreview2FilesystemDirectoryEntry.symbolicLink(
                  'loop-b',
                  target: 'loop-a',
                ),
              ],
            ),
          },
        );
        final program = WASIPreview2ComponentHost(filesystemHost: filesystem)
            .bindWitWorld(
              WASIComponentWitDocument.parse(source),
              worldName: 'filesystem-test',
            );
        final directories =
            program.invokeImport(
                  'wasi:filesystem/preopens@0.2.0.get-directories',
                  const [],
                )
                as WasmComponentValueData;
        final root = _filesystemPreopens(directories).single.$1;

        int open(String path, List<String> pathFlags, List<String> flags) {
          final result =
              program.invokeImport(
                    'wasi:filesystem/types@0.2.0.descriptor.open-at',
                    [
                      root,
                      _flagsValue(pathFlags),
                      path,
                      _flagsValue(const <String>[]),
                      _flagsValue(flags),
                    ],
                  )
                  as WasmComponentValueData;
          return _resourceHandle(_resultOk(result));
        }

        final readOnly = open('note.txt', const [], const ['read']);
        final readOnlyFlags =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.get-flags',
                  [readOnly],
                )
                as WasmComponentValueData;
        final deniedWrite =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.write',
                  [
                    readOnly,
                    _u8ListValue([33]),
                    BigInt.zero,
                  ],
                )
                as WasmComponentValueData;
        expect(_resultOk(readOnlyFlags).labels, ['read']);
        expect(_resultErrorLabel(deniedWrite), 'read-only');
        _expectUnitOk(
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.sync-data',
                [readOnly],
              )
              as WasmComponentValueData,
        );
        _expectUnitOk(
          program.invokeImport('wasi:filesystem/types@0.2.0.descriptor.sync', [
                readOnly,
              ])
              as WasmComponentValueData,
        );

        final writeOnly = open('note.txt', const [], const ['write']);
        final writeOnlyFlags =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.get-flags',
                  [writeOnly],
                )
                as WasmComponentValueData;
        final deniedRead =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.read',
                  [writeOnly, BigInt.one, BigInt.zero],
                )
                as WasmComponentValueData;
        expect(_resultOk(writeOnlyFlags).labels, ['write']);
        expect(_resultErrorLabel(deniedRead), 'not-permitted');

        final unsupportedSyncOpen =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.open-at',
                  [
                    root,
                    _flagsValue(const <String>[]),
                    'external.txt',
                    _flagsValue(const <String>[]),
                    _flagsValue(const <String>['write', 'file-integrity-sync']),
                  ],
                )
                as WasmComponentValueData;
        expect(_resultErrorLabel(unsupportedSyncOpen), 'unsupported');

        final dynamic = open('dynamic', const [], const [
          'read',
          'mutate-directory',
        ]);
        final rejectedDynamicCreate =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.open-at',
                  [
                    dynamic,
                    _flagsValue(const <String>[]),
                    'must-not-exist.txt',
                    _flagsValue(const <String>['create']),
                    _flagsValue(const <String>['write', 'file-integrity-sync']),
                  ],
                )
                as WasmComponentValueData;
        expect(_resultErrorLabel(rejectedDynamicCreate), 'unsupported');
        expect(dynamicCreateCalls, 0);
        expect(dynamicallyCreatedEntries, isEmpty);

        final rejectedDirectoryFlagCreate =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.open-at',
                  [
                    root,
                    _flagsValue(const <String>[]),
                    'invalid-created-file.txt',
                    _flagsValue(const <String>['create']),
                    _flagsValue(const <String>['write', 'mutate-directory']),
                  ],
                )
                as WasmComponentValueData;
        expect(_resultErrorLabel(rejectedDirectoryFlagCreate), 'invalid');
        final missingAfterRejectedCreate =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.open-at',
                  [
                    root,
                    _flagsValue(const <String>[]),
                    'invalid-created-file.txt',
                    _flagsValue(const <String>[]),
                    _flagsValue(const <String>['read']),
                  ],
                )
                as WasmComponentValueData;
        expect(_resultErrorLabel(missingAfterRejectedCreate), 'no-entry');

        final createdThroughDirectorySymlink =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.open-at',
                  [
                    root,
                    _flagsValue(const <String>[]),
                    'dynamic-link/created.txt',
                    _flagsValue(const <String>['create']),
                    _flagsValue(const <String>['write']),
                  ],
                )
                as WasmComponentValueData;
        expect(createdThroughDirectorySymlink.isOk, isTrue);
        expect(dynamicCreateCalls, 1);
        expect(dynamicallyCreatedEntries.map((entry) => entry.name), [
          'created.txt',
        ]);

        final loopCreate =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.open-at',
                  [
                    root,
                    _flagsValue(const <String>['symlink-follow']),
                    'loop-a',
                    _flagsValue(const <String>['create']),
                    _flagsValue(const <String>['write']),
                  ],
                )
                as WasmComponentValueData;
        expect(_resultErrorLabel(loopCreate), 'loop');

        final nonDirectoryCreate =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.open-at',
                  [
                    root,
                    _flagsValue(const <String>[]),
                    'note.txt/child.txt',
                    _flagsValue(const <String>['create']),
                    _flagsValue(const <String>['write']),
                  ],
                )
                as WasmComponentValueData;
        expect(_resultErrorLabel(nonDirectoryCreate), 'not-directory');

        final link = open('note-link', const [], const ['read']);
        final followed = open(
          'note-link',
          const ['symlink-follow'],
          const ['read'],
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
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.read',
                  [followed, BigInt.from(5), BigInt.zero],
                )
                as WasmComponentValueData;
        expect(_caseLabel(_resultOk(linkType)), 'symbolic-link');
        expect(_caseLabel(_resultOk(followedType)), 'regular-file');
        expect(_readBytes(followedRead), [104, 101, 108, 108, 111]);

        final linkStat =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.stat-at',
                  [root, _flagsValue(const <String>[]), 'note-link'],
                )
                as WasmComponentValueData;
        final followedStat =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.stat-at',
                  [
                    root,
                    _flagsValue(const <String>['symlink-follow']),
                    'note-link',
                  ],
                )
                as WasmComponentValueData;
        final unicodeLinkStat =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.stat-at',
                  [root, _flagsValue(const <String>[]), 'unicode-link'],
                )
                as WasmComponentValueData;
        final unicodeReadlink =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.readlink-at',
                  [root, 'unicode-link'],
                )
                as WasmComponentValueData;
        expect(_descriptorStatType(_resultOk(linkStat)), 'symbolic-link');
        expect(_descriptorStatType(_resultOk(followedStat)), 'regular-file');
        expect(_descriptorStatSize(_resultOk(unicodeLinkStat)), BigInt.from(6));
        expect(_resultOk(unicodeReadlink).string, unicodeLinkTarget);

        final targetHash =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.metadata-hash-at',
                  [root, _flagsValue(const <String>[]), 'note.txt'],
                )
                as WasmComponentValueData;
        final linkHash =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.metadata-hash-at',
                  [root, _flagsValue(const <String>[]), 'note-link'],
                )
                as WasmComponentValueData;
        final followedHash =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.metadata-hash-at',
                  [
                    root,
                    _flagsValue(const <String>['symlink-follow']),
                    'note-link',
                  ],
                )
                as WasmComponentValueData;
        expect(
          _metadataHashLower(_resultOk(linkHash)),
          isNot(_metadataHashLower(_resultOk(targetHash))),
        );
        expect(
          _metadataHashLower(_resultOk(followedHash)),
          _metadataHashLower(_resultOk(targetHash)),
        );

        final noFollowSetTimes =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.set-times-at',
                  [
                    root,
                    _flagsValue(const <String>[]),
                    'note-link',
                    _variantCaseValue('now', 1),
                    _variantCaseValue('no-change', 0),
                  ],
                )
                as WasmComponentValueData;
        expect(_resultErrorLabel(noFollowSetTimes), 'read-only');
        expect(noteSetTimesCalls, 0);
        _expectUnitOk(
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.set-times-at',
                [
                  root,
                  _flagsValue(const <String>['symlink-follow']),
                  'note-link',
                  _variantCaseValue('now', 1),
                  _variantCaseValue('no-change', 0),
                ],
              )
              as WasmComponentValueData,
        );
        expect(noteSetTimesCalls, 1);

        _expectUnitOk(
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.link-at',
                [
                  root,
                  _flagsValue(const <String>[]),
                  'note-link',
                  root,
                  'linked-symlink',
                ],
              )
              as WasmComponentValueData,
        );
        _expectUnitOk(
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.link-at',
                [
                  root,
                  _flagsValue(const <String>['symlink-follow']),
                  'note-link',
                  root,
                  'linked-target',
                ],
              )
              as WasmComponentValueData,
        );
        expect(linkedSources, ['note-link', 'note.txt']);

        final directorySync =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.sync',
                  [root],
                )
                as WasmComponentValueData;
        final directorySyncData =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.sync-data',
                  [root],
                )
                as WasmComponentValueData;
        expect(_resultErrorLabel(directorySync), 'unsupported');
        expect(_resultErrorLabel(directorySyncData), 'unsupported');
      },
    );

    test(
      'Preview2 filesystem keeps create and symlink resolution beneath the preopen',
      () {
        const source = '''
package wasi-testsuite:test;

world filesystem-test {
  include wasi:filesystem/imports@0.2.0;
}
''';
        final nested = WASIPreview2FilesystemDirectory(
          canMutate: true,
          entries: <WASIPreview2FilesystemDirectoryEntry>[
            WASIPreview2FilesystemDirectoryEntry.regularFile(
              'nested.txt',
              bytes: const <int>[2],
            ),
            WASIPreview2FilesystemDirectoryEntry.symbolicLink(
              'self',
              target: '.',
            ),
            WASIPreview2FilesystemDirectoryEntry.symbolicLink(
              'up',
              target: '..',
            ),
          ],
        );
        final filesystem = WASIPreview2FilesystemHost(
          preopens: <String, WASIPreview2FilesystemDirectory>{
            '/': WASIPreview2FilesystemDirectory(
              canMutate: true,
              entries: <WASIPreview2FilesystemDirectoryEntry>[
                WASIPreview2FilesystemDirectoryEntry.regularFile(
                  'root.txt',
                  bytes: const <int>[1],
                ),
                WASIPreview2FilesystemDirectoryEntry.directory(
                  'nested',
                  directory: nested,
                ),
                WASIPreview2FilesystemDirectoryEntry.symbolicLink(
                  'absolute',
                  target: '/outside',
                ),
                WASIPreview2FilesystemDirectoryEntry.symbolicLink(
                  'escape',
                  target: '..',
                ),
              ],
            ),
          },
        );
        final program = WASIPreview2ComponentHost(filesystemHost: filesystem)
            .bindWitWorld(
              WASIComponentWitDocument.parse(source),
              worldName: 'filesystem-test',
            );
        final directories =
            program.invokeImport(
                  'wasi:filesystem/preopens@0.2.0.get-directories',
                  const <Object?>[],
                )
                as WasmComponentValueData;
        final root = _filesystemPreopens(directories).single.$1;

        WasmComponentValueData openAt(
          String path, {
          List<String> pathFlags = const <String>[],
          List<String> openFlags = const <String>[],
          List<String> descriptorFlags = const <String>['read'],
        }) {
          return program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.open-at',
                <Object?>[
                  root,
                  _flagsValue(pathFlags),
                  path,
                  _flagsValue(openFlags),
                  _flagsValue(descriptorFlags),
                ],
              )
              as WasmComponentValueData;
        }

        final createDirectory = openAt(
          'must-remain-missing',
          openFlags: const <String>['create', 'directory'],
          descriptorFlags: const <String>['write'],
        );
        expect(_resultErrorLabel(createDirectory), 'no-entry');
        final rejectedTruncate = openAt(
          'root.txt',
          openFlags: const <String>['truncate'],
        );
        expect(_resultErrorLabel(rejectedTruncate), 'invalid');
        final rootFile = _resourceHandle(_resultOk(openAt('root.txt')));
        final rootFileRead =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.read',
                  <Object?>[rootFile, BigInt.one, BigInt.zero],
                )
                as WasmComponentValueData;
        expect(_readBytes(rootFileRead), const <int>[1]);
        final missingStat =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.stat-at',
                  <Object?>[
                    root,
                    _flagsValue(const <String>[]),
                    'must-remain-missing',
                  ],
                )
                as WasmComponentValueData;
        expect(_resultErrorLabel(missingStat), 'no-entry');

        final absoluteSymlink =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.symlink-at',
                  <Object?>[root, '/outside', 'created-absolute'],
                )
                as WasmComponentValueData;
        expect(_resultErrorLabel(absoluteSymlink), 'not-permitted');
        final nulSymlink =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.symlink-at',
                  <Object?>[root, 'bad\u0000target', 'created-nul'],
                )
                as WasmComponentValueData;
        expect(_resultErrorLabel(nulSymlink), 'not-permitted');
        final absoluteReadlink =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.readlink-at',
                  <Object?>[root, 'absolute'],
                )
                as WasmComponentValueData;
        expect(_resultErrorLabel(absoluteReadlink), 'not-permitted');

        for (final path in <String>[
          'nested/../root.txt',
          'nested/up/root.txt',
        ]) {
          final file = _resourceHandle(_resultOk(openAt(path)));
          final read =
              program.invokeImport(
                    'wasi:filesystem/types@0.2.0.descriptor.read',
                    <Object?>[file, BigInt.one, BigInt.zero],
                  )
                  as WasmComponentValueData;
          expect(_readBytes(read), const <int>[1], reason: path);
        }

        final nestedFile = _resourceHandle(
          _resultOk(openAt('nested/self/nested.txt')),
        );
        final nestedRead =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.read',
                  <Object?>[nestedFile, BigInt.one, BigInt.zero],
                )
                as WasmComponentValueData;
        expect(_readBytes(nestedRead), const <int>[2]);

        expect(
          openAt(
            'nested/../created.txt',
            openFlags: const <String>['create'],
            descriptorFlags: const <String>['write'],
          ).isOk,
          isTrue,
        );
        final createdStat =
            program.invokeImport(
                  'wasi:filesystem/types@0.2.0.descriptor.stat-at',
                  <Object?>[root, _flagsValue(const <String>[]), 'created.txt'],
                )
                as WasmComponentValueData;
        expect(createdStat.isOk, isTrue);

        expect(_resultErrorLabel(openAt('../root.txt')), 'not-permitted');
        expect(_resultErrorLabel(openAt('escape/root.txt')), 'not-permitted');
        expect(
          _resultErrorLabel(
            openAt(
              'nested/../../escaped.txt',
              openFlags: const <String>['create'],
              descriptorFlags: const <String>['write'],
            ),
          ),
          'not-permitted',
        );
      },
    );

    test('Preview2 expands and binds standard WASI filesystem imports', () {
      const source = '''
package wasi-testsuite:test;

world filesystem-test {
  include wasi:filesystem/imports@0.2.0;
  include wasi:io/imports@0.2.0;
}
''';
      final note = WASIPreview2FilesystemDirectoryEntry.regularFile(
        'note.txt',
        bytes: const <int>[104, 101, 108, 108, 111],
        canMutate: true,
      );
      final blocked = WASIPreview2FilesystemDirectoryEntry.regularFile(
        'blocked.txt',
        canMutate: true,
        writeBytes: (_, _) => const WASIPreview2FilesystemMutationResult.error(
          WASIPreview2FilesystemMutationError.readOnly,
        ),
      );
      final filesystem = WASIPreview2FilesystemHost(
        preopens: {
          '/': WASIPreview2FilesystemDirectory(
            canMutate: true,
            entries: [
              note,
              blocked,
              WASIPreview2FilesystemDirectoryEntry.directory('etc'),
            ],
          ),
        },
      );
      final document = WASIComponentWitDocument.parse(source);
      final preview2 = WASIPreview2ComponentHost(filesystemHost: filesystem);
      final plan = preview2.prepareWitWorld(
        document,
        worldName: 'filesystem-test',
      );

      expect(filesystem.streamsHost, same(preview2.streamsHost));
      expect(plan.canIngest, isTrue);
      expect(plan.canBindAdapters, isTrue);
      expect(plan.bindingErrors, isEmpty);
      expect(
        plan.functions.map((function) => function.qualifiedName),
        containsAll(<String>[
          'wasi:filesystem/preopens@0.2.0.get-directories',
          'wasi:filesystem/types@0.2.0.descriptor.get-flags',
          'wasi:filesystem/types@0.2.0.descriptor.get-type',
          'wasi:filesystem/types@0.2.0.descriptor.stat',
          'wasi:filesystem/types@0.2.0.descriptor.open-at',
          'wasi:filesystem/types@0.2.0.descriptor.read-via-stream',
          'wasi:filesystem/types@0.2.0.descriptor.write-via-stream',
          'wasi:filesystem/types@0.2.0.descriptor.read',
          'wasi:filesystem/types@0.2.0.descriptor.write',
          'wasi:filesystem/types@0.2.0.descriptor.read-directory',
          'wasi:filesystem/types@0.2.0.directory-entry-stream.read-directory-entry',
          'wasi:filesystem/types@0.2.0.filesystem-error-code',
          'wasi:io/streams@0.2.0.input-stream.read',
          'wasi:io/streams@0.2.0.output-stream.write',
        ]),
      );

      final program = preview2.bindWitWorld(
        document,
        worldName: 'filesystem-test',
      );
      final directories =
          program.invokeImport(
                'wasi:filesystem/preopens@0.2.0.get-directories',
                const [],
              )
              as WasmComponentValueData;
      final root = _filesystemPreopens(directories).single.$1;
      final nextDirectories =
          program.invokeImport(
                'wasi:filesystem/preopens@0.2.0.get-directories',
                const [],
              )
              as WasmComponentValueData;
      final nextRoot = _filesystemPreopens(nextDirectories).single.$1;
      expect(nextRoot, isNot(root));
      expect(filesystem.table.contains(root), isTrue);
      expect(filesystem.table.contains(nextRoot), isTrue);
      final directoryRead =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.read-directory',
                [root],
              )
              as WasmComponentValueData;
      final directoryStream = _resourceHandle(_resultOk(directoryRead));
      final firstEntry =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.directory-entry-stream.read-directory-entry',
                [directoryStream],
              )
              as WasmComponentValueData;
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
      final file = _resourceHandle(_resultOk(opened));
      _expectUnitOk(
        program.invokeImport('wasi:filesystem/types@0.2.0.descriptor.advise', [
              file,
              BigInt.zero,
              BigInt.from(6),
              _enumValue('sequential'),
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
      final fileType =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.get-type',
                [file],
              )
              as WasmComponentValueData;
      final fileStat =
          program.invokeImport('wasi:filesystem/types@0.2.0.descriptor.stat', [
                file,
              ])
              as WasmComponentValueData;
      final fileHash =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.metadata-hash',
                [file],
              )
              as WasmComponentValueData;
      final noteHashAt =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.metadata-hash-at',
                [root, _flagsValue(const <String>[]), 'note.txt'],
              )
              as WasmComponentValueData;
      final directRead =
          program.invokeImport('wasi:filesystem/types@0.2.0.descriptor.read', [
                file,
                BigInt.from(3),
                BigInt.from(1),
              ])
              as WasmComponentValueData;
      final streamRead =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.read-via-stream',
                [file, BigInt.from(2)],
              )
              as WasmComponentValueData;
      final input = _resourceHandle(_resultOk(streamRead));
      final inputBytes =
          program.invokeImport('wasi:io/streams@0.2.0.input-stream.read', [
                input,
                BigInt.from(8),
              ])
              as WasmComponentValueData;
      final streamWrite =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.write-via-stream',
                [file, BigInt.one],
              )
              as WasmComponentValueData;
      final output = _resourceHandle(_resultOk(streamWrite));

      program.invokeImport('wasi:io/streams@0.2.0.output-stream.check-write', [
        output,
      ]);
      final outputWrite =
          program.invokeImport('wasi:io/streams@0.2.0.output-stream.write', [
                output,
                _u8ListValue([88, 89]),
              ])
              as WasmComponentValueData;
      final directWrite =
          program.invokeImport('wasi:filesystem/types@0.2.0.descriptor.write', [
                file,
                _u8ListValue([33]),
                BigInt.from(5),
              ])
              as WasmComponentValueData;
      final blockedOpened =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.open-at',
                [
                  root,
                  _flagsValue(const <String>[]),
                  'blocked.txt',
                  _flagsValue(const <String>[]),
                  _flagsValue(const <String>['write']),
                ],
              )
              as WasmComponentValueData;
      final blockedFile = _resourceHandle(_resultOk(blockedOpened));
      final blockedWriteStream =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.descriptor.write-via-stream',
                [blockedFile, BigInt.zero],
              )
              as WasmComponentValueData;
      final blockedOutput = _resourceHandle(_resultOk(blockedWriteStream));

      program.invokeImport('wasi:io/streams@0.2.0.output-stream.check-write', [
        blockedOutput,
      ]);
      final blockedWrite =
          program.invokeImport('wasi:io/streams@0.2.0.output-stream.write', [
                blockedOutput,
                _u8ListValue([1]),
              ])
              as WasmComponentValueData;
      final filesystemError =
          program.invokeImport(
                'wasi:filesystem/types@0.2.0.filesystem-error-code',
                [_streamErrorHandle(blockedWrite)],
              )
              as WasmComponentValueData;

      expect(_optionDirectoryEntryName(_resultOk(firstEntry)), 'note.txt');
      expect(_caseLabel(_resultOk(fileType)), 'regular-file');
      expect(_descriptorStatType(_resultOk(fileStat)), 'regular-file');
      expect(_metadataHashLower(_resultOk(fileHash)), isNot(BigInt.zero));
      expect(_metadataHashLower(_resultOk(noteHashAt)), isNot(BigInt.zero));
      expect(_readBytes(directRead), [101, 108, 108]);
      expect(_readReachedEnd(directRead), isFalse);
      expect(_u8List(_resultOk(inputBytes)), [108, 108, 111]);
      expect(outputWrite.isOk, isTrue);
      expect(_u64Data(_resultOk(directWrite)), BigInt.one);
      expect(note.bytes, [104, 88, 89, 108, 111, 33]);
      expect(_optionCaseLabel(filesystemError), 'read-only');
      expect(
        preview2.standardImports,
        contains('wasi:filesystem/types@0.2.0.descriptor.open-at'),
      );
    });

    test('Preview3 expands and binds standard WASI random imports', () {
      const source = '''
package wasi-testsuite:test;

world random-test {
  include wasi:random/imports@0.3.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final preview2Plan = WASIPreview2ComponentHost().prepareWitWorld(
        document,
        worldName: 'random-test',
      );
      final preview3 = WASIPreview3ComponentHost();
      final preview3Plan = preview3.prepareWitWorld(
        document,
        worldName: 'random-test',
      );

      expect(preview2Plan.canIngest, isFalse);
      expect(preview2Plan.versionErrors.map((error) => error.targetName), [
        'wasi:random/imports@0.3.0',
      ]);
      expect(preview3Plan.canIngest, isTrue);
      expect(preview3Plan.canBindAdapters, isTrue);
      expect(preview3Plan.functions.map((function) => function.qualifiedName), [
        'wasi:random/random@0.3.0.get-random-bytes',
        'wasi:random/random@0.3.0.get-random-u64',
        'wasi:random/insecure@0.3.0.get-insecure-random-bytes',
        'wasi:random/insecure@0.3.0.get-insecure-random-u64',
        'wasi:random/insecure-seed@0.3.0.get-insecure-seed',
      ]);

      final program = preview3.bindWitWorld(document, worldName: 'random-test');
      final bytesA =
          program.invokeImport('wasi:random/random@0.3.0.get-random-bytes', [
                BigInt.from(16),
              ])
              as WasmComponentValueData;
      final bytesB =
          program.invokeImport('wasi:random/random@0.3.0.get-random-bytes', [
                BigInt.from(16),
              ])
              as WasmComponentValueData;
      final insecureA =
          program.invokeImport(
                'wasi:random/insecure@0.3.0.get-insecure-random-bytes',
                [BigInt.from(16)],
              )
              as WasmComponentValueData;
      final seedA =
          program.invokeImport(
                'wasi:random/insecure-seed@0.3.0.get-insecure-seed',
                const [],
              )
              as WasmComponentValueData;
      final seedB =
          program.invokeImport(
                'wasi:random/insecure-seed@0.3.0.get-insecure-seed',
                const [],
              )
              as WasmComponentValueData;

      expect(_u8List(bytesA), hasLength(16));
      expect(_u8List(bytesB), hasLength(16));
      expect(_u8List(bytesA), isNot(_u8List(bytesB)));
      expect(_u8List(insecureA), hasLength(16));
      expect(
        program.invokeImport(
          'wasi:random/random@0.3.0.get-random-u64',
          const [],
        ),
        isA<BigInt>(),
      );
      expect(
        program.invokeImport(
          'wasi:random/insecure@0.3.0.get-insecure-random-u64',
          const [],
        ),
        isA<BigInt>(),
      );
      expect(_u64Tuple(seedA), _u64Tuple(seedB));
    });

    test('Preview3 expands and binds standard WASI clocks imports', () async {
      const source = '''
package wasi-testsuite:test;

world clocks-test {
  include wasi:clocks/imports@0.3.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final preview2Plan = WASIPreview2ComponentHost().prepareWitWorld(
        document,
        worldName: 'clocks-test',
      );
      final preview3 = WASIPreview3ComponentHost();
      final preview3Plan = preview3.prepareWitWorld(
        document,
        worldName: 'clocks-test',
      );

      expect(preview2Plan.canIngest, isFalse);
      expect(preview2Plan.versionErrors.map((error) => error.targetName), [
        'wasi:clocks/imports@0.3.0',
      ]);
      expect(preview3Plan.canIngest, isTrue);
      expect(preview3Plan.canBindAdapters, isTrue);
      expect(preview3Plan.functions.map((function) => function.qualifiedName), [
        'wasi:clocks/monotonic-clock@0.3.0.now',
        'wasi:clocks/monotonic-clock@0.3.0.get-resolution',
        'wasi:clocks/monotonic-clock@0.3.0.wait-until',
        'wasi:clocks/monotonic-clock@0.3.0.wait-for',
        'wasi:clocks/system-clock@0.3.0.now',
        'wasi:clocks/system-clock@0.3.0.get-resolution',
      ]);

      final program = preview3.bindWitWorld(document, worldName: 'clocks-test');
      final before =
          program.invokeImport(
                'wasi:clocks/monotonic-clock@0.3.0.now',
                const [],
              )
              as BigInt;
      final resolution =
          program.invokeImport(
                'wasi:clocks/monotonic-clock@0.3.0.get-resolution',
                const [],
              )
              as BigInt;
      await program.invokeImportAsync(
        'wasi:clocks/monotonic-clock@0.3.0.wait-for',
        [BigInt.from(1000)],
      );
      await program.invokeImportAsync(
        'wasi:clocks/monotonic-clock@0.3.0.wait-until',
        [BigInt.zero],
      );
      final after =
          program.invokeImport(
                'wasi:clocks/monotonic-clock@0.3.0.now',
                const [],
              )
              as BigInt;
      final instant =
          program.invokeImport('wasi:clocks/system-clock@0.3.0.now', const [])
              as WasmComponentValueData;
      final systemResolution =
          program.invokeImport(
                'wasi:clocks/system-clock@0.3.0.get-resolution',
                const [],
              )
              as BigInt;

      expect(resolution, greaterThan(BigInt.zero));
      expect(after, greaterThanOrEqualTo(before));
      expect(_instantNanoseconds(instant), lessThan(1000000000));
      expect(systemResolution, greaterThan(BigInt.zero));
    });

    test('Preview3 forwards Preview2 compatibility output immediately', () async {
      final stdout = <int>[];
      final stderr = <int>[];
      final preview3 = WASIPreview3ComponentHost(
        stdout: stdout.addAll,
        stderr: stderr.addAll,
      );
      final compatibility = preview3.preview2CompatibilityHost;

      await compatibility.componentHost.table.runScoped<void>(() async {
        final stdoutHandle =
            compatibility.standardImports['wasi:cli/stdout@0.2.0.get-stdout']!(
                  const <Object?>[],
                )
                as int;
        compatibility
            .standardImports['wasi:io/streams@0.2.0.output-stream.check-write']!(
          <Object?>[stdoutHandle],
        );
        final stdoutWrite =
            compatibility
                    .standardImports['wasi:io/streams@0.2.0.output-stream.write']!(
                  <Object?>[
                    stdoutHandle,
                    _u8ListValue(const <int>[111, 107]),
                  ],
                )
                as WasmComponentValueData;

        final stderrHandle =
            compatibility.standardImports['wasi:cli/stderr@0.2.0.get-stderr']!(
                  const <Object?>[],
                )
                as int;
        compatibility
            .standardImports['wasi:io/streams@0.2.0.output-stream.check-write']!(
          <Object?>[stderrHandle],
        );
        final stderrWrite =
            compatibility
                    .standardImports['wasi:io/streams@0.2.0.output-stream.write']!(
                  <Object?>[
                    stderrHandle,
                    _u8ListValue(const <int>[33]),
                  ],
                )
                as WasmComponentValueData;

        expect(stdoutWrite.isOk, isTrue);
        expect(stderrWrite.isOk, isTrue);
        expect(stdout, const <int>[111, 107]);
        expect(stderr, const <int>[33]);
      });
    });

    test('Preview3 expands and binds standard WASI CLI imports', () async {
      const source = '''
package wasi-testsuite:test;

world cli-test {
  include wasi:cli/imports@0.3.0;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final preview2Plan = WASIPreview2ComponentHost().prepareWitWorld(
        document,
        worldName: 'cli-test',
      );
      final cli = WASIPreview3CliHost(
        args: const <String>['cli-env.wasm', 'a', 'b', '42'],
        env: const <String, String>{'foo': 'bar', 'baz': '42'},
        initialCwd: '/workspace',
        stdinData: const <int>[120, 121],
      );
      final preview3 = WASIPreview3ComponentHost(cliHost: cli);
      final preview3Plan = preview3.prepareWitWorld(
        document,
        worldName: 'cli-test',
      );

      expect(preview2Plan.canIngest, isFalse);
      expect(preview2Plan.versionErrors.map((error) => error.targetName), [
        'wasi:cli/imports@0.3.0',
      ]);
      expect(preview3Plan.canIngest, isTrue);
      expect(preview3Plan.canBindAdapters, isTrue);
      expect(preview3Plan.bindingErrors, isEmpty);
      expect(
        preview3Plan.functions.map((function) => function.qualifiedName),
        containsAll(<String>[
          'wasi:cli/environment@0.3.0.get-environment',
          'wasi:cli/environment@0.3.0.get-arguments',
          'wasi:cli/environment@0.3.0.get-initial-cwd',
          'wasi:cli/exit@0.3.0.exit',
          'wasi:cli/exit@0.3.0.exit-with-code',
          'wasi:cli/stdin@0.3.0.read-via-stream',
          'wasi:cli/stdout@0.3.0.write-via-stream',
          'wasi:cli/stderr@0.3.0.write-via-stream',
          'wasi:cli/terminal-stdin@0.3.0.get-terminal-stdin',
          'wasi:cli/terminal-stdout@0.3.0.get-terminal-stdout',
          'wasi:cli/terminal-stderr@0.3.0.get-terminal-stderr',
        ]),
      );

      final program = preview3.bindWitWorld(document, worldName: 'cli-test');
      final environment =
          program.invokeImport(
                'wasi:cli/environment@0.3.0.get-environment',
                const [],
              )
              as WasmComponentValueData;
      final arguments =
          program.invokeImport(
                'wasi:cli/environment@0.3.0.get-arguments',
                const [],
              )
              as WasmComponentValueData;
      final cwd =
          program.invokeImport(
                'wasi:cli/environment@0.3.0.get-initial-cwd',
                const [],
              )
              as WasmComponentValueData;
      final terminal =
          program.invokeImport(
                'wasi:cli/terminal-stdout@0.3.0.get-terminal-stdout',
                const [],
              )
              as WasmComponentValueData;

      expect(_stringPairs(environment), contains(('foo', 'bar')));
      expect(_stringPairs(environment), contains(('baz', '42')));
      expect(_stringList(arguments), ['cli-env.wasm', 'a', 'b', '42']);
      expect(_optionString(cwd), '/workspace');
      expect(terminal.kind, WasmComponentValueDataKind.option);
      expect(terminal.isSome, isFalse);

      final stdinTuple =
          program.invokeImport('wasi:cli/stdin@0.3.0.read-via-stream', const [])
              as List<Object?>;
      final stdinStream = stdinTuple[0] as WASIComponentReadableStream<int>;
      final stdinResult =
          stdinTuple[1] as WASIComponentFuture<WasmComponentValueData>;
      expect(stdinStream.read(8), [120, 121]);
      expect(stdinResult.readable.read().isOk, isTrue);

      final stdoutStream = WASIComponentStream<int>(
        'stdout-test',
        maxBufferedElements: 0,
      );
      final stdoutResult =
          program.invokeImport('wasi:cli/stdout@0.3.0.write-via-stream', [
                stdoutStream.readable,
              ])
              as WASIComponentFuture<WasmComponentValueData>;
      expect(
        await stdoutStream.writable.writeWhenAvailable(<int>[111, 107]),
        2,
      );
      await Future<void>.delayed(Duration.zero);
      stdoutStream.writable.drop();
      expect((await stdoutResult.readable.readWhenReady()).isOk, isTrue);
      expect(cli.stdoutBytes, [111, 107]);

      final stderrStream = WASIComponentStream<int>('stderr-test');
      stderrStream.writable.write(33);
      stderrStream.writable.close();
      final stderrResult =
          program.invokeImport('wasi:cli/stderr@0.3.0.write-via-stream', [
                stderrStream,
              ])
              as WASIComponentFuture<WasmComponentValueData>;
      expect((await stderrResult.readable.readWhenReady()).isOk, isTrue);
      expect(cli.stderrBytes, [33]);

      expect(
        () =>
            program.invokeImport('wasi:cli/exit@0.3.0.exit', [_unitOkValue()]),
        throwsA(
          isA<WASIPreview3Exit>()
              .having((error) => error.statusCode, 'statusCode', 0)
              .having((error) => error.isSuccess, 'isSuccess', isTrue),
        ),
      );
      expect(
        () => program.invokeImport('wasi:cli/exit@0.3.0.exit', [
          _unitOkCaseValue(),
        ]),
        throwsA(
          isA<WASIPreview3Exit>()
              .having((error) => error.statusCode, 'statusCode', 0)
              .having((error) => error.isSuccess, 'isSuccess', isTrue),
        ),
      );
      expect(
        () => program.invokeImport('wasi:cli/exit@0.3.0.exit-with-code', [7]),
        throwsA(
          isA<WASIPreview3Exit>()
              .having((error) => error.statusCode, 'statusCode', 7)
              .having((error) => error.isSuccess, 'isSuccess', isFalse),
        ),
      );
    });

    test('Preview3 CLI accepts live stdin after command start', () async {
      final input = WASIComponentStream<int>('live-stdin');
      final cli = WASIPreview3CliHost(stdin: input.readable);
      final callback = cli.imports['wasi:cli/stdin@0.3.0.read-via-stream']!;
      final result = callback(const <Object?>[]) as List<Object?>;
      final readable = result[0] as WASIComponentReadableStream<int>;
      final pending = readable.readWhenAvailable(64);

      input.writable.writeAll(const <int>[108, 105, 118, 101]);
      input.writable.close();

      expect(await pending, const <int>[108, 105, 118, 101]);
      expect(await readable.readWhenAvailable(64), isEmpty);
    });

    test(
      'Preview3 expands and binds standard WASI filesystem imports',
      () async {
        const source = '''
package wasi-testsuite:test;

world filesystem-test {
  include wasi:filesystem/imports@0.3.0;
}
''';
        final document = WASIComponentWitDocument.parse(source);
        final filesystem = WASIPreview3FilesystemHost(
          preopens: {
            '/': WASIPreview3FilesystemDirectory(
              entries: [
                WASIPreview3FilesystemDirectoryEntry.directory('etc'),
                WASIPreview3FilesystemDirectoryEntry.regularFile(
                  'hello.txt',
                  bytes: const <int>[104, 101, 108, 108, 111],
                ),
              ],
            ),
            '/cache': WASIPreview3FilesystemDirectory(),
          },
        );
        final preview3 = WASIPreview3ComponentHost(filesystemHost: filesystem);
        final plan = preview3.prepareWitWorld(
          document,
          worldName: 'filesystem-test',
        );

        expect(plan.canIngest, isTrue);
        expect(plan.canBindAdapters, isTrue);
        expect(plan.bindingErrors, isEmpty);
        expect(
          plan.functions.map((function) => function.qualifiedName),
          containsAll(<String>[
            'wasi:filesystem/preopens@0.3.0.get-directories',
            'wasi:filesystem/types@0.3.0.descriptor.get-flags',
            'wasi:filesystem/types@0.3.0.descriptor.get-type',
            'wasi:filesystem/types@0.3.0.descriptor.stat',
            'wasi:filesystem/types@0.3.0.descriptor.read-directory',
            'wasi:filesystem/types@0.3.0.descriptor.metadata-hash',
            'wasi:filesystem/types@0.3.0.descriptor.is-same-object',
          ]),
        );

        final program = preview3.bindWitWorld(
          document,
          worldName: 'filesystem-test',
        );
        final directories =
            program.invokeImport(
                  'wasi:filesystem/preopens@0.3.0.get-directories',
                  const [],
                )
                as WasmComponentValueData;
        final preopens = _filesystemPreopens(directories);

        expect(preopens.map((preopen) => preopen.$2), ['/', '/cache']);
        expect(preopens.map((preopen) => preopen.$1).toSet(), hasLength(2));

        final root = preopens.first.$1;
        final flags =
            await program.invokeImportAsync(
                  'wasi:filesystem/types@0.3.0.descriptor.get-flags',
                  [root],
                )
                as WasmComponentValueData;
        final type =
            await program.invokeImportAsync(
                  'wasi:filesystem/types@0.3.0.descriptor.get-type',
                  [root],
                )
                as WasmComponentValueData;
        final stat =
            await program.invokeImportAsync(
                  'wasi:filesystem/types@0.3.0.descriptor.stat',
                  [root],
                )
                as WasmComponentValueData;
        final sameObject =
            await program.invokeImportAsync(
                  'wasi:filesystem/types@0.3.0.descriptor.is-same-object',
                  [root, root],
                )
                as bool;
        final hash =
            await program.invokeImportAsync(
                  'wasi:filesystem/types@0.3.0.descriptor.metadata-hash',
                  [root],
                )
                as WasmComponentValueData;
        final directoryRead =
            program.invokeImport(
                  'wasi:filesystem/types@0.3.0.descriptor.read-directory',
                  [root],
                )
                as List<Object?>;
        final entries =
            directoryRead[0] as WASIComponentStream<WasmComponentValueData>;
        final readResult =
            directoryRead[1] as WASIComponentFuture<WasmComponentValueData>;

        expect(_resultOk(flags).labels, contains('read'));
        expect(_variantLabel(_resultOk(type)), 'directory');
        expect(_descriptorStatType(_resultOk(stat)), 'directory');
        expect(sameObject, isTrue);
        expect(_metadataHashLower(_resultOk(hash)), isNot(BigInt.zero));
        expect(
          (await entries.readable.readWhenAvailable(
            8,
          )).map(_directoryEntryName).toList(),
          ['etc', 'hello.txt'],
        );
        expect((await readResult.readable.readWhenReady()).isOk, isTrue);

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
        final file = _resourceHandle(_resultOk(opened));
        final fileType =
            await program.invokeImportAsync(
                  'wasi:filesystem/types@0.3.0.descriptor.get-type',
                  [file],
                )
                as WasmComponentValueData;
        final fileStat =
            await program.invokeImportAsync(
                  'wasi:filesystem/types@0.3.0.descriptor.stat-at',
                  [root, _flagsValue(const <String>[]), 'hello.txt'],
                )
                as WasmComponentValueData;
        final fileHash =
            await program.invokeImportAsync(
                  'wasi:filesystem/types@0.3.0.descriptor.metadata-hash-at',
                  [root, _flagsValue(const <String>[]), 'hello.txt'],
                )
                as WasmComponentValueData;
        final denied =
            await program.invokeImportAsync(
                  'wasi:filesystem/types@0.3.0.descriptor.open-at',
                  [
                    root,
                    _flagsValue(const <String>[]),
                    'hello.txt',
                    _flagsValue(const <String>[]),
                    _flagsValue(const <String>['write']),
                  ],
                )
                as WasmComponentValueData;
        final fileRead =
            program.invokeImport(
                  'wasi:filesystem/types@0.3.0.descriptor.read-via-stream',
                  [file, BigInt.from(1)],
                )
                as List<Object?>;
        final fileStream = fileRead[0] as WASIComponentStream<int>;
        final fileReadResult =
            fileRead[1] as WASIComponentFuture<WasmComponentValueData>;

        expect(_variantLabel(_resultOk(fileType)), 'regular-file');
        expect(_descriptorStatType(_resultOk(fileStat)), 'regular-file');
        expect(_metadataHashLower(_resultOk(fileHash)), isNot(BigInt.zero));
        expect(_resultErrorLabel(denied), 'read-only');
        expect(fileStream.readable.read(8), [101, 108, 108, 111]);
        expect((await fileReadResult.readable.readWhenReady()).isOk, isTrue);
      },
    );

    test('Preview2 and Preview3 wrappers execute WIT world adapters', () {
      const source = '''
package acme:math@0.2.0;

interface adder {
  add: func(left: u32, right: u32) -> u32;
}

interface printer {
  print: func(message: string);
}

world command {
  import adder;
  export printer;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final preview2Plan = WASIPreview2ComponentHost().prepareWitWorld(
        document,
        worldName: 'command',
      );
      final preview3Plan = WASIPreview3ComponentHost().prepareWitWorld(
        document,
        worldName: 'command',
      );
      final printed = <String>[];

      expect(preview2Plan.canBindAdapters, isTrue);
      expect(preview3Plan.canBindAdapters, isTrue);
      expect(preview2Plan.functions.map((function) => function.qualifiedName), [
        'adder.add',
        'printer.print',
      ]);
      expect(preview2Plan.functions.map((function) => function.direction), [
        WASIComponentWitWorldItemDirection.import,
        WASIComponentWitWorldItemDirection.export,
      ]);

      final preview2Program = preview2Plan.bindAdapters(
        imports: {'adder.add': (args) => (args[0] as int) + (args[1] as int)},
        exports: {
          'printer.print': (args) {
            printed.add(args.single as String);
            return null;
          },
        },
      );
      final preview3Program = preview3Plan.bindAdapters(
        imports: {'adder.add': (args) => 7},
        exports: {'printer.print': (_) => null},
      );

      expect(preview2Program.invokeImport('adder.add', [20, 22]), 42);
      expect(preview2Program.invokeExport('printer.print', ['ready']), isNull);
      expect(printed, ['ready']);
      expect(preview3Program.invokeImport('adder.add', [3, 4]), 7);
      expect(
        () => preview2Program.invokeImport('adder.add', [0x100000000, 1]),
        throwsStateError,
      );
    });

    test('Preview3 wrappers execute async WIT function adapters', () async {
      const source = '''
package acme:task@0.3.0;

interface runner {
  run: async func(seed: u32) -> u32;
}

world command {
  import runner;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final preview2Plan = WASIPreview2ComponentHost().prepareWitWorld(
        document,
        worldName: 'command',
      );
      final preview3Plan = WASIPreview3ComponentHost().prepareWitWorld(
        document,
        worldName: 'command',
      );
      final seen = <int>[];

      expect(preview2Plan.canIngest, isFalse);
      expect(preview2Plan.canBindAdapters, isFalse);
      expect(preview3Plan.canIngest, isTrue);
      expect(preview3Plan.canBindAdapters, isTrue);
      expect(preview3Plan.bindingErrors, isEmpty);

      final program = preview3Plan.bindAdapters(
        imports: {
          'runner.run': (args) async {
            final seed = args.single as int;
            seen.add(seed);
            return seed + 1;
          },
        },
      );

      expect(() => program.invokeImport('runner.run', [41]), throwsStateError);
      expect(await program.invokeImportAsync('runner.run', [41]), 42);
      expect(seen, [41]);
    });

    test('Preview3 wrappers execute stream and future WIT adapters', () {
      const source = '''
package wasi:cli@0.3.0;

interface stdout {
  write-via-stream: func(data: stream<u8>) -> future<result>;
}

world command {
  export stdout;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final preview2Plan = WASIPreview2ComponentHost().prepareWitWorld(
        document,
        worldName: 'command',
      );
      final preview3Plan = WASIPreview3ComponentHost().prepareWitWorld(
        document,
        worldName: 'command',
      );
      final bytes = <int>[];

      expect(preview2Plan.canIngest, isFalse);
      expect(preview2Plan.canBindAdapters, isFalse);
      expect(preview3Plan.canIngest, isTrue);
      expect(preview3Plan.canBindAdapters, isTrue);
      expect(preview3Plan.bindingErrors, isEmpty);
      expect(
        preview3Plan.functions.single.signature.params.single.type.kind,
        WASIComponentWitAdapterValueKind.stream,
      );
      expect(
        preview3Plan.functions.single.signature.result!.kind,
        WASIComponentWitAdapterValueKind.future,
      );

      final program = preview3Plan.bindAdapters(
        exports: {
          'stdout.write-via-stream': (args) {
            final stream = args.single as WASIComponentStream<int>;
            bytes.addAll(stream.readable.read(4));
            final result = WASIComponentFuture<WasmComponentValueData>(
              'stdout-result',
            );
            result.writable.complete(_unitOkValue());
            return result;
          },
        },
      );
      final stream = WASIComponentStream<int>('stdout-bytes');
      stream.writable.writeAll(<int>[104, 105]);
      stream.writable.close();

      final result =
          program.invokeExport('stdout.write-via-stream', [stream])
              as WASIComponentFuture<WasmComponentValueData>;
      final status = result.readable.read();

      expect(bytes, [104, 105]);
      expect(status.kind, WasmComponentValueDataKind.result);
      expect(status.isOk, isTrue);
      expect(
        () => program.invokeExport('stdout.write-via-stream', [0]),
        throwsStateError,
      );
    });

    test('Preview2 and Preview3 wrappers execute composite WIT values', () {
      const source = '''
package acme:math@0.2.0;

interface lookup {
  get: func(key: option<u32>) -> result<u32, string>;
}

world command {
  import lookup;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final preview2Plan = WASIPreview2ComponentHost().prepareWitWorld(
        document,
        worldName: 'command',
      );
      final preview3Plan = WASIPreview3ComponentHost().prepareWitWorld(
        document,
        worldName: 'command',
      );
      final seenKeys = <int?>[];

      expect(preview2Plan.canBindAdapters, isTrue);
      expect(preview3Plan.canBindAdapters, isTrue);

      final program = preview2Plan.bindAdapters(
        imports: {
          'lookup.get': (args) {
            final key = args.single as WasmComponentValueData;
            expect(key.kind, WasmComponentValueDataKind.option);
            if (key.isSome ?? false) {
              seenKeys.add(key.associatedValue!.integer as int);
              return _u32StringOkValue(42);
            }
            seenKeys.add(null);
            return _u32StringErrorValue('missing');
          },
        },
      );
      final preview3Program = preview3Plan.bindAdapters(
        imports: {'lookup.get': (_) => _u32StringOkValue(7)},
      );

      final ok =
          program.invokeImport('lookup.get', [_u32SomeValue(1)])
              as WasmComponentValueData;
      final error =
          program.invokeImport('lookup.get', [_u32NoneValue()])
              as WasmComponentValueData;
      final preview3Ok =
          preview3Program.invokeImport('lookup.get', [_u32NoneValue()])
              as WasmComponentValueData;

      expect(ok.kind, WasmComponentValueDataKind.result);
      expect(ok.isOk, isTrue);
      expect(ok.associatedValue!.integer, 42);
      expect(error.isOk, isFalse);
      expect(error.associatedValue!.string, 'missing');
      expect(preview3Ok.isOk, isTrue);
      expect(preview3Ok.associatedValue!.integer, 7);
      expect(seenKeys, [1, null]);
      expect(
        () => program.invokeImport('lookup.get', [_conflictingU32SomeValue()]),
        throwsStateError,
      );
      expect(
        () => program.invokeImport('lookup.get', [_wrongKindU32SomeValue()]),
        throwsStateError,
      );
      expect(seenKeys, [1, null]);
    });

    test(
      'Preview2 and Preview3 wrappers execute list and tuple WIT values',
      () {
        const source = '''
package acme:env@0.2.0;

interface environment {
  expand: func(seed: tuple<string, u32>) -> list<tuple<string, string>>;
}

world command {
  import environment;
}
''';
        final document = WASIComponentWitDocument.parse(source);
        final preview2Plan = WASIPreview2ComponentHost().prepareWitWorld(
          document,
          worldName: 'command',
        );
        final preview3Plan = WASIPreview3ComponentHost().prepareWitWorld(
          document,
          worldName: 'command',
        );
        final seenSeeds = <String>[];

        expect(preview2Plan.canBindAdapters, isTrue);
        expect(preview3Plan.canBindAdapters, isTrue);

        final program = preview2Plan.bindAdapters(
          imports: {
            'environment.expand': (args) {
              final seed = args.single as WasmComponentValueData;
              expect(seed.kind, WasmComponentValueDataKind.tuple);
              seenSeeds.add('${seed.items[0].string}:${seed.items[1].integer}');
              return _stringTupleListValue([
                ('PATH', '/bin'),
                ('SEED', seed.items[1].integer.toString()),
              ]);
            },
          },
        );
        final preview3Program = preview3Plan.bindAdapters(
          imports: {
            'environment.expand': (_) =>
                _stringTupleListValue([('SHELL', '/bin/sh')]),
          },
        );

        final rows =
            program.invokeImport('environment.expand', [
                  _seedTupleValue('env', 7),
                ])
                as WasmComponentValueData;
        final preview3Rows =
            preview3Program.invokeImport('environment.expand', [
                  _seedTupleValue('ignored', 0),
                ])
                as WasmComponentValueData;

        expect(rows.kind, WasmComponentValueDataKind.list);
        expect(rows.items, hasLength(2));
        expect(rows.items[0].items.map((item) => item.string), [
          'PATH',
          '/bin',
        ]);
        expect(rows.items[1].items.map((item) => item.string), ['SEED', '7']);
        expect(preview3Rows.items.single.items.map((item) => item.string), [
          'SHELL',
          '/bin/sh',
        ]);
        expect(seenSeeds, ['env:7']);
        expect(
          () => program.invokeImport('environment.expand', [
            _shortSeedTupleValue(),
          ]),
          throwsStateError,
        );
        expect(seenSeeds, ['env:7']);

        final badResultProgram = preview2Plan.bindAdapters(
          imports: {'environment.expand': (_) => _badStringTupleListValue()},
        );
        expect(
          () => badResultProgram.invokeImport('environment.expand', [
            _seedTupleValue('env', 7),
          ]),
          throwsStateError,
        );
      },
    );

    test('Preview2 and Preview3 wrappers execute named WIT record values', () {
      const source = '''
package acme:env@0.2.0;

interface environment {
  record entry {
    name: string,
    value: string,
  }

  get: func(prefix: string) -> list<entry>;
}

world command {
  import environment;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final preview2Plan = WASIPreview2ComponentHost().prepareWitWorld(
        document,
        worldName: 'command',
      );
      final preview3Plan = WASIPreview3ComponentHost().prepareWitWorld(
        document,
        worldName: 'command',
      );
      final prefixes = <String>[];

      expect(preview2Plan.canBindAdapters, isTrue);
      expect(preview3Plan.canBindAdapters, isTrue);

      final program = preview2Plan.bindAdapters(
        imports: {
          'environment.get': (args) {
            prefixes.add(args.single as String);
            return _envEntryListValue([('PATH', '/bin'), ('SHELL', '/bin/sh')]);
          },
        },
      );
      final preview3Program = preview3Plan.bindAdapters(
        imports: {
          'environment.get': (_) => _envEntryListValue([('HOME', '/tmp')]),
        },
      );

      final rows =
          program.invokeImport('environment.get', ['env'])
              as WasmComponentValueData;
      final preview3Rows =
          preview3Program.invokeImport('environment.get', ['ignored'])
              as WasmComponentValueData;

      expect(rows.kind, WasmComponentValueDataKind.list);
      expect(rows.items.map((item) => item.kind), [
        WasmComponentValueDataKind.record,
        WasmComponentValueDataKind.record,
      ]);
      expect(rows.items[0].items.map((item) => item.string), ['PATH', '/bin']);
      expect(rows.items[1].items.map((item) => item.string), [
        'SHELL',
        '/bin/sh',
      ]);
      expect(preview3Rows.items.single.items.map((item) => item.string), [
        'HOME',
        '/tmp',
      ]);
      expect(prefixes, ['env']);

      final badResultProgram = preview2Plan.bindAdapters(
        imports: {'environment.get': (_) => _badEnvEntryListValue()},
      );
      expect(
        () => badResultProgram.invokeImport('environment.get', ['env']),
        throwsStateError,
      );
    });

    test(
      'Preview2 and Preview3 wrappers execute WIT variants enums and flags',
      () {
        const source = '''
package acme:access@0.2.0;

interface access {
  flags permissions {
    read,
    write,
    execute,
  }

  enum decision {
    allow,
    deny,
  }

  variant request {
    anonymous,
    path(string),
    inherit(permissions),
  }

  check: func(request: request, allowed: permissions) -> decision;
}

world command {
  import access;
}
''';
        final document = WASIComponentWitDocument.parse(source);
        final preview2Plan = WASIPreview2ComponentHost().prepareWitWorld(
          document,
          worldName: 'command',
        );
        final preview3Plan = WASIPreview3ComponentHost().prepareWitWorld(
          document,
          worldName: 'command',
        );
        final seen = <String>[];

        expect(preview2Plan.canBindAdapters, isTrue);
        expect(preview3Plan.canBindAdapters, isTrue);

        final program = preview2Plan.bindAdapters(
          imports: {
            'access.check': (args) {
              final request = args[0] as WasmComponentValueData;
              final allowed = args[1] as WasmComponentValueData;
              seen.add('${request.label}:${allowed.labels.join(",")}');
              return _decisionValue('allow');
            },
          },
        );
        final preview3Program = preview3Plan.bindAdapters(
          imports: {'access.check': (_) => _decisionValue('deny')},
        );

        final decision =
            program.invokeImport('access.check', [
                  _requestPathValue('/tmp/config'),
                  _permissionsValue(['read', 'write']),
                ])
                as WasmComponentValueData;
        final inherited =
            program.invokeImport('access.check', [
                  _requestInheritValue(['execute']),
                  _permissionsValue(['execute']),
                ])
                as WasmComponentValueData;
        final preview3Decision =
            preview3Program.invokeImport('access.check', [
                  _requestAnonymousValue(),
                  _permissionsValue(['read']),
                ])
                as WasmComponentValueData;

        expect(decision.kind, WasmComponentValueDataKind.enumeration);
        expect(decision.label, 'allow');
        expect(inherited.label, 'allow');
        expect(preview3Decision.label, 'deny');
        expect(seen, ['path:read,write', 'inherit:execute']);

        expect(
          () => program.invokeImport('access.check', [
            _badRequestPathValue(),
            _permissionsValue(['read']),
          ]),
          throwsStateError,
        );
        expect(
          () => program.invokeImport('access.check', [
            _requestAnonymousValue(),
            _permissionsValue(['delete']),
          ]),
          throwsStateError,
        );
        expect(seen, ['path:read,write', 'inherit:execute']);

        final badResultProgram = preview2Plan.bindAdapters(
          imports: {'access.check': (_) => _decisionValue('maybe')},
        );
        expect(
          () => badResultProgram.invokeImport('access.check', [
            _requestAnonymousValue(),
            _permissionsValue(['read']),
          ]),
          throwsStateError,
        );
      },
    );

    test('Preview2 and Preview3 wrappers execute WIT resource handles', () {
      const source = '''
package acme:files@0.2.0;

interface files {
  resource descriptor {
    read: func() -> u32;
  }

  open: func(path: string) -> descriptor;
  stat: func(handle: borrow<descriptor>) -> u32;
}

world command {
  import files;
}
''';
      final document = WASIComponentWitDocument.parse(source);
      final preview2Plan = WASIPreview2ComponentHost().prepareWitWorld(
        document,
        worldName: 'command',
      );
      final preview3Plan = WASIPreview3ComponentHost().prepareWitWorld(
        document,
        worldName: 'command',
      );
      final seen = <Object?>[];

      expect(preview2Plan.canBindAdapters, isTrue);
      expect(preview3Plan.canBindAdapters, isTrue);
      expect(preview2Plan.functions.map((function) => function.qualifiedName), [
        'files.descriptor.read',
        'files.open',
        'files.stat',
      ]);

      final program = preview2Plan.bindAdapters(
        imports: {
          'files.descriptor.read': (args) {
            seen.add(args.single);
            return (args.single as int) + 7;
          },
          'files.open': (args) {
            seen.add(args.single);
            return 41;
          },
          'files.stat': (args) {
            seen.add(args.single);
            return (args.single as int) + 1;
          },
        },
      );
      final preview3Program = preview3Plan.bindAdapters(
        imports: {
          'files.descriptor.read': (args) => (args.single as int) + 11,
          'files.open': (_) => 51,
          'files.stat': (args) => args.single,
        },
      );

      final handle = program.invokeImport('files.open', ['config']);
      expect(handle, 41);
      expect(program.invokeImport('files.stat', [handle]), 42);
      expect(program.invokeImport('files.descriptor.read', [handle]), 48);
      expect(preview3Program.invokeImport('files.open', ['config']), 51);
      expect(preview3Program.invokeImport('files.stat', [51]), 51);
      expect(preview3Program.invokeImport('files.descriptor.read', [51]), 62);
      expect(seen, ['config', 41, 41]);

      expect(() => program.invokeImport('files.stat', [-1]), throwsStateError);
      expect(seen, ['config', 41, 41]);

      final badResultProgram = preview2Plan.bindAdapters(
        imports: {
          'files.descriptor.read': (_) => 0,
          'files.open': (_) => -1,
          'files.stat': (args) => args.single,
        },
      );
      expect(
        () => badResultProgram.invokeImport('files.open', ['config']),
        throwsStateError,
      );
    });

    test(
      'Preview2 wrapper rejects owned-resource async values at version gate',
      () {
        final streamComponent = WasmComponent.decode(
          ownedResourceStreamNewDropComponentBytes(),
        );
        final futureComponent = WasmComponent.decode(
          ownedResourceFutureNewDropComponentBytes(),
        );
        final host = WASIPreview2ComponentHost();

        final streamPlan = host.prepareComponent(streamComponent);
        final futurePlan = host.prepareComponent(futureComponent);

        expect(streamComponent.validate(), isEmpty);
        expect(futureComponent.validate(), isEmpty);
        expect(streamPlan.canBind, isFalse);
        expect(futurePlan.canBind, isFalse);
        expect(streamPlan.versionErrors, hasLength(3));
        expect(futurePlan.versionErrors, hasLength(3));
        expect(streamPlan.versionErrors.map((error) => error.kind), [
          WasmComponentCanonicalKind.streamNew,
          WasmComponentCanonicalKind.streamDropReadable,
          WasmComponentCanonicalKind.streamDropWritable,
        ]);
        expect(futurePlan.versionErrors.map((error) => error.kind), [
          WasmComponentCanonicalKind.futureNew,
          WasmComponentCanonicalKind.futureDropReadable,
          WasmComponentCanonicalKind.futureDropWritable,
        ]);
        expect(streamPlan.unsupportedDefinitions, isEmpty);
        expect(futurePlan.unsupportedDefinitions, isEmpty);
        expect(streamPlan.bindingErrors, isEmpty);
        expect(futurePlan.bindingErrors, isEmpty);
        expect(streamPlan.componentPlan.resourceBindings, hasLength(1));
        expect(futurePlan.componentPlan.resourceBindings, hasLength(1));
        expect(
          streamPlan.componentPlan.resourceBindings.single.componentTypeIndex,
          0,
        );
        expect(
          futurePlan.componentPlan.resourceBindings.single.componentTypeIndex,
          0,
        );
        expect(streamPlan.componentPlan.asyncValueBindings, hasLength(1));
        expect(futurePlan.componentPlan.asyncValueBindings, hasLength(1));
        expect(
          streamPlan.componentPlan.asyncValueBindings.single.kind,
          WASIComponentAsyncValueBindingKind.stream,
        );
        expect(
          futurePlan.componentPlan.asyncValueBindings.single.kind,
          WASIComponentAsyncValueBindingKind.future,
        );
        expect(
          streamPlan.componentPlan.asyncValueBindings.single.componentTypeIndex,
          2,
        );
        expect(
          futurePlan.componentPlan.asyncValueBindings.single.componentTypeIndex,
          2,
        );
        expect(
          streamPlan
              .componentPlan
              .asyncValueBindings
              .single
              .memoryLayout!
              .byteLength,
          4,
        );
        expect(
          futurePlan
              .componentPlan
              .asyncValueBindings
              .single
              .memoryLayout!
              .byteLength,
          4,
        );
        expect(
          () => streamPlan.bind(),
          throwsA(isA<WASIComponentVersionUnsupportedException>()),
        );
        expect(
          () => futurePlan.bind(),
          throwsA(isA<WASIComponentVersionUnsupportedException>()),
        );
        expect(host.componentHost.table.activeCount, 0);
      },
    );

    test('Preview3 wrapper accepts async stream profile bindings', () {
      final component = WasmComponent.decode(_canonicalStreamProgramBytes());
      final host = WASIPreview3ComponentHost();

      expect(host.profile, same(WASIComponentVersionProfile.preview3));

      final binding = host.bindComponent(component);
      final handles = WASIComponentAsyncEndpointHandles.unpack(
        binding.program.invoke(0, const <Object?>[])! as int,
      );

      expect(binding.asyncValueBindings, hasLength(1));
      expect(host.componentHost.table.activeCount, 2);
      expect(binding.program.invoke(5, <Object?>[handles.readable]), isNull);
      expect(binding.program.invoke(6, <Object?>[handles.writable]), isNull);
      expect(host.componentHost.table.activeCount, 0);
    });

    test('Preview3 wrapper executes owned-resource async lifecycles', () {
      final streamComponent = WasmComponent.decode(
        ownedResourceStreamNewDropComponentBytes(),
      );
      final futureComponent = WasmComponent.decode(
        ownedResourceFutureNewDropComponentBytes(),
      );
      final streamHost = WASIPreview3ComponentHost();
      final futureHost = WASIPreview3ComponentHost();

      final streamPlan = streamHost.prepareComponent(streamComponent);
      final futurePlan = futureHost.prepareComponent(futureComponent);

      expect(streamComponent.validate(), isEmpty);
      expect(futureComponent.validate(), isEmpty);
      expect(streamPlan.canBind, isTrue);
      expect(futurePlan.canBind, isTrue);
      expect(streamPlan.versionErrors, isEmpty);
      expect(futurePlan.versionErrors, isEmpty);
      expect(streamPlan.unsupportedDefinitions, isEmpty);
      expect(futurePlan.unsupportedDefinitions, isEmpty);
      expect(streamPlan.bindingErrors, isEmpty);
      expect(futurePlan.bindingErrors, isEmpty);
      expect(streamPlan.componentPlan.resourceBindings, hasLength(1));
      expect(futurePlan.componentPlan.resourceBindings, hasLength(1));
      expect(
        streamPlan.componentPlan.resourceBindings.single.componentTypeIndex,
        0,
      );
      expect(
        futurePlan.componentPlan.resourceBindings.single.componentTypeIndex,
        0,
      );
      expect(streamPlan.componentPlan.asyncValueBindings, hasLength(1));
      expect(futurePlan.componentPlan.asyncValueBindings, hasLength(1));
      expect(
        streamPlan.componentPlan.asyncValueBindings.single.kind,
        WASIComponentAsyncValueBindingKind.stream,
      );
      expect(
        futurePlan.componentPlan.asyncValueBindings.single.kind,
        WASIComponentAsyncValueBindingKind.future,
      );
      expect(
        streamPlan.componentPlan.asyncValueBindings.single.componentTypeIndex,
        2,
      );
      expect(
        futurePlan.componentPlan.asyncValueBindings.single.componentTypeIndex,
        2,
      );
      expect(
        streamPlan
            .componentPlan
            .asyncValueBindings
            .single
            .memoryLayout!
            .byteLength,
        4,
      );
      expect(
        futurePlan
            .componentPlan
            .asyncValueBindings
            .single
            .memoryLayout!
            .byteLength,
        4,
      );

      final streamBinding = streamPlan.bind();
      final streamHandles = WASIComponentAsyncEndpointHandles.unpack(
        streamBinding.program.invoke(0, const <Object?>[])! as int,
      );
      expect(streamHost.componentHost.table.activeCount, 2);
      expect(
        streamBinding.program.invoke(1, <Object?>[streamHandles.readable]),
        isNull,
      );
      expect(
        streamBinding.program.invoke(2, <Object?>[streamHandles.writable]),
        isNull,
      );
      expect(streamHost.componentHost.table.activeCount, 0);

      final futureBinding = futurePlan.bind();
      final futureHandles = WASIComponentAsyncEndpointHandles.unpack(
        futureBinding.program.invoke(0, const <Object?>[])! as int,
      );
      expect(futureHost.componentHost.table.activeCount, 2);
      expect(
        futureBinding.program.invoke(1, <Object?>[futureHandles.readable]),
        isNull,
      );
      expect(
        futureBinding.program.invoke(2, <Object?>[futureHandles.writable]),
        isNull,
      );
      expect(futureHost.componentHost.table.activeCount, 0);
    });

    test('Preview2 wrapper rejects owned-resource async memory copies', () {
      final streamComponent = WasmComponent.decode(
        ownedResourceAsyncMemoryProgramFromU32(
          canonicalU32StreamMemoryComponentBytes(),
          isStream: true,
        ),
      );
      final futureComponent = WasmComponent.decode(
        ownedResourceAsyncMemoryProgramFromU32(
          canonicalU32FutureMemoryComponentBytes(),
          isStream: false,
        ),
      );
      final host = WASIPreview2ComponentHost();

      final streamPlan = host.prepareComponent(streamComponent);
      final futurePlan = host.prepareComponent(futureComponent);

      expect(streamComponent.validate(), isEmpty);
      expect(futureComponent.validate(), isEmpty);
      expect(streamPlan.canBind, isFalse);
      expect(futurePlan.canBind, isFalse);
      expect(streamPlan.versionErrors, hasLength(5));
      expect(futurePlan.versionErrors, hasLength(5));
      expect(streamPlan.versionErrors.map((error) => error.kind), [
        WasmComponentCanonicalKind.streamNew,
        WasmComponentCanonicalKind.streamRead,
        WasmComponentCanonicalKind.streamWrite,
        WasmComponentCanonicalKind.streamDropReadable,
        WasmComponentCanonicalKind.streamDropWritable,
      ]);
      expect(futurePlan.versionErrors.map((error) => error.kind), [
        WasmComponentCanonicalKind.futureNew,
        WasmComponentCanonicalKind.futureRead,
        WasmComponentCanonicalKind.futureWrite,
        WasmComponentCanonicalKind.futureDropReadable,
        WasmComponentCanonicalKind.futureDropWritable,
      ]);
      expect(streamPlan.unsupportedDefinitions, isEmpty);
      expect(futurePlan.unsupportedDefinitions, isEmpty);
      expect(streamPlan.bindingErrors, isEmpty);
      expect(futurePlan.bindingErrors, isEmpty);
      expect(streamPlan.componentPlan.resourceBindings, hasLength(1));
      expect(futurePlan.componentPlan.resourceBindings, hasLength(1));
      expect(streamPlan.componentPlan.asyncValueBindings, hasLength(1));
      expect(futurePlan.componentPlan.asyncValueBindings, hasLength(1));
      expect(
        streamPlan
            .componentPlan
            .asyncValueBindings
            .single
            .memoryLayout!
            .byteLength,
        4,
      );
      expect(
        futurePlan
            .componentPlan
            .asyncValueBindings
            .single
            .memoryLayout!
            .byteLength,
        4,
      );
      expect(
        () => streamPlan.bind(),
        throwsA(isA<WASIComponentVersionUnsupportedException>()),
      );
      expect(
        () => futurePlan.bind(),
        throwsA(isA<WASIComponentVersionUnsupportedException>()),
      );
      expect(host.componentHost.table.activeCount, 0);
    });

    test('Preview3 wrapper executes owned-resource async memory copies', () {
      final streamComponent = WasmComponent.decode(
        ownedResourceAsyncMemoryProgramFromU32(
          canonicalU32StreamMemoryComponentBytes(),
          isStream: true,
        ),
      );
      final futureComponent = WasmComponent.decode(
        ownedResourceAsyncMemoryProgramFromU32(
          canonicalU32FutureMemoryComponentBytes(),
          isStream: false,
        ),
      );
      final streamHost = WASIPreview3ComponentHost();
      final futureHost = WASIPreview3ComponentHost();
      final streamMemory = Memory(const MemoryDescriptor(initial: 1));
      final futureMemory = Memory(const MemoryDescriptor(initial: 1));
      final streamData = ByteData.view(streamMemory.buffer);
      final futureData = ByteData.view(futureMemory.buffer);
      streamData.setUint32(32, 0x7fffffff, Endian.little);
      streamData.setUint32(36, 0x80000000, Endian.little);
      futureData.setUint32(32, 0xffffffff, Endian.little);

      final streamPlan = streamHost.prepareComponent(streamComponent);
      final futurePlan = futureHost.prepareComponent(futureComponent);

      expect(streamComponent.validate(), isEmpty);
      expect(futureComponent.validate(), isEmpty);
      expect(streamPlan.canBind, isTrue);
      expect(futurePlan.canBind, isTrue);
      expect(streamPlan.versionErrors, isEmpty);
      expect(futurePlan.versionErrors, isEmpty);
      expect(streamPlan.unsupportedDefinitions, isEmpty);
      expect(futurePlan.unsupportedDefinitions, isEmpty);
      expect(streamPlan.componentPlan.resourceBindings, hasLength(1));
      expect(futurePlan.componentPlan.resourceBindings, hasLength(1));
      expect(streamPlan.componentPlan.asyncValueBindings, hasLength(1));
      expect(futurePlan.componentPlan.asyncValueBindings, hasLength(1));

      final streamBinding = streamPlan.bind();
      final streamHandles = WASIComponentAsyncEndpointHandles.unpack(
        streamBinding.program.invoke(0, const <Object?>[])! as int,
      );
      expect(
        streamBinding.program.invokeWithMemory(2, streamMemory, <Object?>[
          streamHandles.writable,
          32,
          2,
        ]),
        2 << 4,
      );
      expect(
        streamBinding.program.invokeWithMemory(1, streamMemory, <Object?>[
          streamHandles.readable,
          96,
          2,
        ]),
        2 << 4,
      );
      expect(streamData.getUint32(96, Endian.little), 0x7fffffff);
      expect(streamData.getUint32(100, Endian.little), 0x80000000);
      expect(
        streamBinding.program.invoke(3, <Object?>[streamHandles.readable]),
        isNull,
      );
      expect(
        streamBinding.program.invoke(4, <Object?>[streamHandles.writable]),
        isNull,
      );
      expect(streamHost.componentHost.table.activeCount, 0);

      final futureBinding = futurePlan.bind();
      final futureHandles = WASIComponentAsyncEndpointHandles.unpack(
        futureBinding.program.invoke(0, const <Object?>[])! as int,
      );
      expect(
        futureBinding.program.invokeWithMemory(2, futureMemory, <Object?>[
          futureHandles.writable,
          32,
        ]),
        0,
      );
      expect(
        futureBinding.program.invokeWithMemory(1, futureMemory, <Object?>[
          futureHandles.readable,
          96,
        ]),
        0,
      );
      expect(futureData.getUint32(96, Endian.little), 0xffffffff);
      expect(
        futureBinding.program.invoke(3, <Object?>[futureHandles.readable]),
        isNull,
      );
      expect(
        futureBinding.program.invoke(4, <Object?>[futureHandles.writable]),
        isNull,
      );
      expect(futureHost.componentHost.table.activeCount, 0);
    });

    test(
      'Preview3 wrapper publishes owned-resource async copy events',
      () async {
        final streamComponent = WasmComponent.decode(
          ownedResourceAsyncMemoryProgramFromU32(
            canonicalU32StreamMemoryComponentBytes(),
            isStream: true,
          ),
        );
        final futureComponent = WasmComponent.decode(
          ownedResourceAsyncMemoryProgramFromU32(
            canonicalU32FutureMemoryComponentBytes(),
            isStream: false,
          ),
        );
        final streamHost = WASIPreview3ComponentHost();
        final futureHost = WASIPreview3ComponentHost();
        final streamMemory = Memory(const MemoryDescriptor(initial: 1));
        final futureMemory = Memory(const MemoryDescriptor(initial: 1));
        final streamData = ByteData.view(streamMemory.buffer);
        final futureData = ByteData.view(futureMemory.buffer);
        streamData.setUint32(32, 0x01020304, Endian.little);
        streamData.setUint32(36, 0x05060708, Endian.little);
        futureData.setUint32(32, 0x0a0b0c0d, Endian.little);

        final streamBinding = streamHost.bindComponent(streamComponent);
        final streamHandles = WASIComponentAsyncEndpointHandles.unpack(
          streamBinding.program.invoke(0, const <Object?>[])! as int,
        );
        final streamWaitableHost =
            streamHost.componentHost.canonicalHost.waitableHost;
        final streamWaitableSet = streamWaitableHost.waitableSetNew();
        streamWaitableHost.waitableJoin(
          streamHandles.readable,
          streamWaitableSet,
        );
        var streamCompleted = false;

        expect(
          streamBinding.program.invokeWithMemoryEvent(
            1,
            streamMemory,
            <Object?>[streamHandles.readable, 96, 2],
          ),
          wasiComponentAsyncBlocked,
        );
        final streamPending =
            streamWaitableHost.waitableSetWaitToMemory(
              streamWaitableSet,
              streamMemory,
              128,
            )..then((_) {
              streamCompleted = true;
            });
        await Future<void>.delayed(Duration.zero);
        expect(streamCompleted, isFalse);
        expect(
          () => streamBinding.program.invoke(3, <Object?>[
            streamHandles.readable,
          ]),
          throwsStateError,
        );
        expect(
          streamBinding.program.invokeWithMemory(2, streamMemory, <Object?>[
            streamHandles.writable,
            32,
            2,
          ]),
          2 << 4,
        );

        await expectLater(
          streamPending,
          completion(WASIComponentWaitableEventCode.streamRead.value),
        );
        expect(streamCompleted, isTrue);
        expect(streamData.getUint32(96, Endian.little), 0x01020304);
        expect(streamData.getUint32(100, Endian.little), 0x05060708);
        expect(
          streamData.getUint32(128, Endian.little),
          streamHandles.readable,
        );
        expect(streamData.getUint32(132, Endian.little), 2 << 4);
        streamWaitableHost.waitableJoin(streamHandles.readable, 0);
        streamWaitableHost.waitableSetDrop(streamWaitableSet);
        expect(
          streamBinding.program.invoke(3, <Object?>[streamHandles.readable]),
          isNull,
        );
        expect(
          streamBinding.program.invoke(4, <Object?>[streamHandles.writable]),
          isNull,
        );
        expect(streamHost.componentHost.table.activeCount, 0);

        final futureBinding = futureHost.bindComponent(futureComponent);
        final futureHandles = WASIComponentAsyncEndpointHandles.unpack(
          futureBinding.program.invoke(0, const <Object?>[])! as int,
        );
        final futureWaitableHost =
            futureHost.componentHost.canonicalHost.waitableHost;
        final futureWaitableSet = futureWaitableHost.waitableSetNew();
        futureWaitableHost.waitableJoin(
          futureHandles.readable,
          futureWaitableSet,
        );

        expect(
          futureBinding.program.invokeWithMemoryEvent(
            1,
            futureMemory,
            <Object?>[futureHandles.readable, 96],
          ),
          wasiComponentAsyncBlocked,
        );
        expect(
          futureBinding.program.invokeWithMemory(2, futureMemory, <Object?>[
            futureHandles.writable,
            32,
          ]),
          0,
        );

        await expectLater(
          futureWaitableHost.waitableSetWaitToMemory(
            futureWaitableSet,
            futureMemory,
            128,
          ),
          completion(WASIComponentWaitableEventCode.futureRead.value),
        );
        expect(futureData.getUint32(96, Endian.little), 0x0a0b0c0d);
        expect(
          futureData.getUint32(128, Endian.little),
          futureHandles.readable,
        );
        expect(futureData.getUint32(132, Endian.little), 0);
        futureWaitableHost.waitableJoin(futureHandles.readable, 0);
        futureWaitableHost.waitableSetDrop(futureWaitableSet);
        expect(
          futureBinding.program.invoke(3, <Object?>[futureHandles.readable]),
          isNull,
        );
        expect(
          futureBinding.program.invoke(4, <Object?>[futureHandles.writable]),
          isNull,
        );
        expect(futureHost.componentHost.table.activeCount, 0);
      },
    );

    test('Preview3 wrapper cancels owned-resource async copy events', () async {
      final streamComponent = WasmComponent.decode(
        asyncMemoryProgramWithCancelDefinitions(
          ownedResourceAsyncMemoryProgramFromU32(
            canonicalU32StreamMemoryComponentBytes(),
            isStream: true,
          ),
          isStream: true,
          componentTypeIndex: 2,
        ),
      );
      final futureComponent = WasmComponent.decode(
        asyncMemoryProgramWithCancelDefinitions(
          ownedResourceAsyncMemoryProgramFromU32(
            canonicalU32FutureMemoryComponentBytes(),
            isStream: false,
          ),
          isStream: false,
          componentTypeIndex: 2,
        ),
      );
      final streamHost = WASIPreview3ComponentHost();
      final futureHost = WASIPreview3ComponentHost();
      final streamMemory = Memory(const MemoryDescriptor(initial: 1));
      final futureMemory = Memory(const MemoryDescriptor(initial: 1));
      final streamData = ByteData.view(streamMemory.buffer);
      final futureData = ByteData.view(futureMemory.buffer);

      final streamBinding = streamHost.bindComponent(streamComponent);
      final streamHandles = WASIComponentAsyncEndpointHandles.unpack(
        streamBinding.program.invoke(0, const <Object?>[])! as int,
      );
      final streamWaitableHost =
          streamHost.componentHost.canonicalHost.waitableHost;
      final streamWaitableSet = streamWaitableHost.waitableSetNew();
      streamWaitableHost.waitableJoin(
        streamHandles.readable,
        streamWaitableSet,
      );

      expect(streamComponent.validate(), isEmpty);
      expect(
        streamBinding.program.invokeWithMemoryEvent(1, streamMemory, <Object?>[
          streamHandles.readable,
          96,
          2,
        ]),
        wasiComponentAsyncBlocked,
      );
      expect(
        streamBinding.program.invoke(3, <Object?>[streamHandles.readable]),
        wasiComponentAsyncBlocked,
      );
      expect(
        () =>
            streamBinding.program.invoke(3, <Object?>[streamHandles.readable]),
        throwsStateError,
      );

      await expectLater(
        streamWaitableHost.waitableSetWaitToMemory(
          streamWaitableSet,
          streamMemory,
          128,
        ),
        completion(WASIComponentWaitableEventCode.streamRead.value),
      );
      expect(streamData.getUint32(128, Endian.little), streamHandles.readable);
      expect(
        streamData.getUint32(132, Endian.little),
        WASIComponentAsyncCopyResult.cancelled().packedResult,
      );
      streamWaitableHost.waitableJoin(streamHandles.readable, 0);
      streamWaitableHost.waitableSetDrop(streamWaitableSet);
      expect(
        streamBinding.program.invoke(5, <Object?>[streamHandles.readable]),
        isNull,
      );
      expect(
        streamBinding.program.invoke(6, <Object?>[streamHandles.writable]),
        isNull,
      );
      expect(streamHost.componentHost.table.activeCount, 0);

      final futureBinding = futureHost.bindComponent(futureComponent);
      final futureHandles = WASIComponentAsyncEndpointHandles.unpack(
        futureBinding.program.invoke(0, const <Object?>[])! as int,
      );
      final futureWaitableHost =
          futureHost.componentHost.canonicalHost.waitableHost;
      final futureWaitableSet = futureWaitableHost.waitableSetNew();
      futureWaitableHost.waitableJoin(
        futureHandles.readable,
        futureWaitableSet,
      );

      expect(futureComponent.validate(), isEmpty);
      expect(
        futureBinding.program.invokeWithMemoryEvent(1, futureMemory, <Object?>[
          futureHandles.readable,
          96,
        ]),
        wasiComponentAsyncBlocked,
      );
      expect(
        futureBinding.program.invoke(3, <Object?>[futureHandles.readable]),
        wasiComponentAsyncBlocked,
      );

      await expectLater(
        futureWaitableHost.waitableSetWaitToMemory(
          futureWaitableSet,
          futureMemory,
          128,
        ),
        completion(WASIComponentWaitableEventCode.futureRead.value),
      );
      expect(futureData.getUint32(128, Endian.little), futureHandles.readable);
      expect(
        futureData.getUint32(132, Endian.little),
        WASIComponentAsyncCopyResult.cancelled().packedResult,
      );
      futureWaitableHost.waitableJoin(futureHandles.readable, 0);
      futureWaitableHost.waitableSetDrop(futureWaitableSet);
      expect(
        futureBinding.program.invoke(5, <Object?>[futureHandles.readable]),
        isNull,
      );
      expect(
        futureBinding.program.invoke(6, <Object?>[futureHandles.writable]),
        isNull,
      );
      expect(futureHost.componentHost.table.activeCount, 0);
    });

    test('Preview2 and Preview3 wrappers execute primitive adapters', () {
      final component = WasmComponent.decode(
        canonicalPrimitiveLiftLowerComponentBytes(),
      );
      final preview2 = WASIPreview2ComponentHost();
      final preview3 = WASIPreview3ComponentHost();
      var preview2CoreCalls = 0;
      var preview2ComponentCalls = 0;
      var preview3CoreCalls = 0;
      var preview3ComponentCalls = 0;

      final preview2Program = preview2.bindAdapters(
        component,
        coreFunctions: {
          0: (args) {
            expect(args, isEmpty);
            preview2CoreCalls++;
            return 21;
          },
        },
        componentFunctions: {
          0: (args) {
            expect(args, isEmpty);
            preview2ComponentCalls++;
            return 22;
          },
        },
      );
      final preview3Program = preview3.bindAdapters(
        component,
        coreFunctions: {
          0: (args) {
            expect(args, isEmpty);
            preview3CoreCalls++;
            return 31;
          },
        },
        componentFunctions: {
          0: (args) {
            expect(args, isEmpty);
            preview3ComponentCalls++;
            return 32;
          },
        },
      );

      expect(component.validate(), isEmpty);
      expect(preview2Program.operations, hasLength(2));
      expect(preview3Program.operations, hasLength(2));
      expect(preview2Program.invokeFlat(0, const <Object?>[]), [21]);
      expect(preview2Program.invokeFlat(1, const <Object?>[]), [22]);
      expect(preview3Program.invokeFlat(0, const <Object?>[]), [31]);
      expect(preview3Program.invokeFlat(1, const <Object?>[]), [32]);
      expect(preview2CoreCalls, 1);
      expect(preview2ComponentCalls, 1);
      expect(preview3CoreCalls, 1);
      expect(preview3ComponentCalls, 1);
      expect(preview2.componentHost.table.activeCount, 0);
      expect(preview3.componentHost.table.activeCount, 0);
    });

    test('Preview3 wrapper executes async primitive adapters', () async {
      final component = WasmComponent.decode(
        canonicalAsyncPrimitiveLiftLowerComponentBytes(),
      );
      final preview2 = WASIPreview2ComponentHost();
      final preview3 = WASIPreview3ComponentHost();
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);

      final preview2Plan = preview2.prepareComponent(component);
      expect(component.validate(), isEmpty);
      expect(preview2Plan.canBindWithAdapters, isFalse);
      expect(preview2Plan.versionErrors, hasLength(2));
      expect(
        preview2Plan.versionErrors.map((error) => error.capability.area),
        everyElement(WASIComponentCanonicalCapabilityArea.asyncValue),
      );

      final binding = preview3.bindComponent(
        component,
        coreFunctions: {
          0: (args) async {
            expect(args, isEmpty);
            return 61;
          },
        },
        componentFunctions: {
          0: (args) async {
            expect(args, isEmpty);
            return 71;
          },
        },
      );

      expect(binding.program.operations, hasLength(2));
      expect(
        () => binding.program.invoke(0, const <Object?>[]),
        throwsUnsupportedError,
      );
      expect(
        () => binding.program.invokeFlat(0, const <Object?>[]),
        throwsUnsupportedError,
      );
      expect(
        () => binding.program.invokeWithMemory(
          0,
          memory,
          const <Object?>[],
          resultPointer: 32,
        ),
        throwsUnsupportedError,
      );
      expect(await binding.program.invokeAsync(0, const <Object?>[]), 61);
      expect(await binding.program.invokeAsync(1, const <Object?>[]), 71);
      expect(await binding.program.invokeFlatAsync(0, const <Object?>[]), [61]);
      expect(await binding.program.invokeFlatAsync(1, const <Object?>[]), [71]);
      expect(
        await binding.program.invokeWithMemoryAsync(
          0,
          memory,
          const <Object?>[],
          resultPointer: 32,
        ),
        61,
      );
      expect(data.getUint32(32, Endian.little), 61);
      expect(
        await binding.program.invokeWithMemoryAsync(
          1,
          memory,
          const <Object?>[],
          resultPointer: 40,
        ),
        71,
      );
      expect(data.getUint32(40, Endian.little), 71);
    });

    test('Preview3 wrapper reports adapter resource handle uses', () {
      final component = WasmComponent.decode(
        canonicalResourceLiftComponentBytes(),
      );
      final host = WASIPreview3ComponentHost();

      final plan = host.prepareComponent(component);

      expect(component.validate(), isEmpty);
      expect(plan.canBind, isFalse);
      expect(plan.canBindWithAdapters, isTrue);
      expect(plan.versionErrors, isEmpty);
      expect(plan.unsupportedDefinitions, isEmpty);
      expect(plan.componentPlan.bindingErrors, isEmpty);
      expect(plan.resourceUses, hasLength(3));
      expect(plan.resourceUses.map((use) => use.path), [
        'canonical[0].param[0].owned',
        'canonical[0].param[1].borrowed',
        'canonical[0].result',
      ]);
      expect(plan.resourceUses.map((use) => use.handleKind), [
        WASIComponentResourceHandleKind.own,
        WASIComponentResourceHandleKind.borrow,
        WASIComponentResourceHandleKind.own,
      ]);
      expect(plan.resourceUses.map((use) => use.binding?.representation), [
        WASIComponentResourceRepresentation.i32,
        WASIComponentResourceRepresentation.i32,
        WASIComponentResourceRepresentation.i32,
      ]);
      expect(() => plan.bind(), throwsStateError);
    });
  });
}

WasmComponentValueData _u32SomeValue(int value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'some',
    isSome: true,
    associatedValue: WasmComponentValueData(
      kind: WasmComponentValueDataKind.integer,
      rawBytes: Uint8List(0),
      integer: value,
    ),
  );
}

WasmComponentValueData _u32NoneValue() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'none',
    isSome: false,
  );
}

WasmComponentValueData _conflictingU32SomeValue() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'some',
    isSome: false,
    associatedValue: WasmComponentValueData(
      kind: WasmComponentValueDataKind.integer,
      rawBytes: Uint8List(0),
      integer: 1,
    ),
  );
}

WasmComponentValueData _wrongKindU32SomeValue() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'some',
    isSome: true,
    associatedValue: WasmComponentValueData(
      kind: WasmComponentValueDataKind.string,
      rawBytes: Uint8List(0),
      integer: 1,
    ),
  );
}

WasmComponentValueData _u32StringOkValue(int value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'ok',
    isOk: true,
    associatedValue: WasmComponentValueData(
      kind: WasmComponentValueDataKind.integer,
      rawBytes: Uint8List(0),
      integer: value,
    ),
  );
}

WasmComponentValueData _unitOkValue() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'ok',
    isOk: true,
  );
}

WasmComponentValueData _resultOkValue(WasmComponentValueData value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'ok',
    isOk: true,
    associatedValue: value,
  );
}

WasmComponentValueData _resultErrorValue(WasmComponentValueData value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'error',
    isOk: false,
    associatedValue: value,
  );
}

WasmComponentValueData _unitOkCaseValue() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'ok',
  );
}

WasmComponentValueData _unitErrorValue() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'error',
    isOk: false,
  );
}

WasmComponentValueData _u32StringErrorValue(String value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'error',
    isOk: false,
    associatedValue: WasmComponentValueData(
      kind: WasmComponentValueDataKind.string,
      rawBytes: Uint8List(0),
      string: value,
    ),
  );
}

WasmComponentValueData _seedTupleValue(String name, int value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.tuple,
    rawBytes: Uint8List(0),
    items: [
      WasmComponentValueData(
        kind: WasmComponentValueDataKind.string,
        rawBytes: Uint8List(0),
        string: name,
      ),
      WasmComponentValueData(
        kind: WasmComponentValueDataKind.integer,
        rawBytes: Uint8List(0),
        integer: value,
      ),
    ],
  );
}

WasmComponentValueData _shortSeedTupleValue() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.tuple,
    rawBytes: Uint8List(0),
    items: [
      WasmComponentValueData(
        kind: WasmComponentValueDataKind.string,
        rawBytes: Uint8List(0),
        string: 'env',
      ),
    ],
  );
}

List<int> _u8List(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.list) {
    throw StateError('expected list<u8>, got ${value.kind.name}');
  }
  return [
    for (final item in value.items)
      if (item.kind == WasmComponentValueDataKind.integer)
        item.integer as int
      else
        throw StateError('expected u8 item, got ${item.kind.name}'),
  ];
}

List<int> _u32List(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.list) {
    throw StateError('expected list<u32>, got ${value.kind.name}');
  }
  return [
    for (final item in value.items)
      if (item.kind == WasmComponentValueDataKind.integer)
        (item.integer as int)
      else
        throw StateError('expected u32 item, got ${item.kind.name}'),
  ];
}

WasmComponentValueData _resourceHandleList(List<int> handles) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    items: [
      for (final handle in handles)
        WasmComponentValueData(
          kind: WasmComponentValueDataKind.integer,
          rawBytes: Uint8List(0),
          integer: handle,
        ),
    ],
  );
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

WasmComponentValueData _stringValue(String value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.string,
    rawBytes: Uint8List(0),
    string: value,
  );
}

WasmComponentValueData _httpFieldListValue(List<(String, List<int>)> entries) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    items: [
      for (final entry in entries)
        _tupleValue([_stringValue(entry.$1), _u8ListValue(entry.$2)]),
    ],
  );
}

WasmComponentValueData _httpFieldValuesValue(List<List<int>> values) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    items: [for (final value in values) _u8ListValue(value)],
  );
}

WasmComponentValueData _fieldsEntries(
  WASIComponentWitAdapterProgram program,
  int fields,
) {
  return program.invokeImport('wasi:http/types@0.2.0.fields.entries', [fields])
      as WasmComponentValueData;
}

List<List<int>> _httpFieldValues(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.list) {
    throw StateError('expected list<field-value>, got ${value.kind.name}');
  }
  return [for (final item in value.items) _u8List(item)];
}

List<(String, List<int>)> _httpFieldEntries(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.list) {
    throw StateError('expected list<field>, got ${value.kind.name}');
  }
  return [
    for (final item in value.items)
      if (item.kind == WasmComponentValueDataKind.tuple &&
          item.items.length == 2 &&
          item.items[0].kind == WasmComponentValueDataKind.string)
        (item.items[0].string!, _u8List(item.items[1]))
      else
        throw StateError('expected HTTP field tuple, got ${item.kind.name}'),
  ];
}

List<List<int>> _httpFieldEntryValues(
  List<(String, List<int>)> entries,
  String name,
) {
  final lower = name.toLowerCase();
  return [
    for (final entry in entries)
      if (entry.$1.toLowerCase() == lower) entry.$2,
  ];
}

int _datetimeNanoseconds(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.record ||
      value.items.length != 2 ||
      value.items[1].kind != WasmComponentValueDataKind.integer) {
    throw StateError('expected datetime, got ${value.kind.name}');
  }
  return value.items[1].integer as int;
}

List<String> _stringList(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.list) {
    throw StateError('expected list<string>, got ${value.kind.name}');
  }
  return [
    for (final item in value.items)
      if (item.kind == WasmComponentValueDataKind.string)
        item.string!
      else
        throw StateError('expected string item, got ${item.kind.name}'),
  ];
}

List<(String, String)> _stringPairs(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.list) {
    throw StateError(
      'expected list<tuple<string, string>>, got ${value.kind.name}',
    );
  }
  return [
    for (final item in value.items)
      if (item.kind == WasmComponentValueDataKind.tuple &&
          item.items.length == 2 &&
          item.items[0].kind == WasmComponentValueDataKind.string &&
          item.items[1].kind == WasmComponentValueDataKind.string)
        (item.items[0].string!, item.items[1].string!)
      else
        throw StateError('expected string tuple item, got ${item.kind.name}'),
  ];
}

List<(int, String)> _filesystemPreopens(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.list) {
    throw StateError(
      'expected list<tuple<descriptor, string>>, got ${value.kind.name}',
    );
  }
  return [
    for (final item in value.items)
      if (item.kind == WasmComponentValueDataKind.tuple &&
          item.items.length == 2 &&
          item.items[0].kind == WasmComponentValueDataKind.integer &&
          item.items[1].kind == WasmComponentValueDataKind.string)
        (_resourceHandle(item.items[0]), item.items[1].string!)
      else
        throw StateError(
          'expected filesystem preopen tuple item, got ${item.kind.name}',
        ),
  ];
}

WasmComponentValueData _resultOk(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.result ||
      !(value.isOk ?? value.label == 'ok' || value.index == 0)) {
    throw StateError('expected ok result, got ${value.kind.name}');
  }
  final associated = value.associatedValue;
  if (associated == null) {
    throw StateError('expected ok result payload');
  }
  return associated;
}

String _variantLabel(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.variant) {
    throw StateError('expected variant, got ${value.kind.name}');
  }
  return value.label ?? 'case-${value.index}';
}

String _caseLabel(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.variant &&
      value.kind != WasmComponentValueDataKind.enumeration) {
    throw StateError('expected case value, got ${value.kind.name}');
  }
  return value.label ?? 'case-${value.index}';
}

String _descriptorStatType(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.record ||
      value.items.length != 6) {
    throw StateError('expected descriptor-stat, got ${value.kind.name}');
  }
  return _caseLabel(value.items[0]);
}

BigInt _descriptorStatSize(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.record ||
      value.items.length != 6) {
    throw StateError('expected descriptor-stat, got ${value.kind.name}');
  }
  return _u64Data(value.items[2]);
}

BigInt _metadataHashLower(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.record ||
      value.items.length != 2) {
    throw StateError('expected metadata-hash-value, got ${value.kind.name}');
  }
  return _u64Data(value.items[0]);
}

int _resourceHandle(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.integer) {
    throw StateError('expected resource handle, got ${value.kind.name}');
  }
  final integer = value.integer;
  if (integer is int) {
    return integer;
  }
  if (integer is BigInt) {
    return integer.toInt();
  }
  throw StateError('expected resource handle payload, got $integer');
}

int? _optionHandle(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.option) {
    throw StateError('expected option<resource>, got ${value.kind.name}');
  }
  if (!(value.isSome ?? value.label == 'some' || value.index == 1)) {
    return null;
  }
  final associated = value.associatedValue;
  if (associated == null) {
    throw StateError('expected option<resource> payload');
  }
  return _resourceHandle(associated);
}

String _resultErrorLabel(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.result ||
      (value.isOk ?? value.label == 'ok' || value.index == 0)) {
    throw StateError('expected error result, got ${value.kind.name}');
  }
  final associated = value.associatedValue;
  if (associated == null) {
    throw StateError('expected error result payload');
  }
  return _caseLabel(associated);
}

int _streamErrorHandle(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.result ||
      (value.isOk ?? value.label == 'ok' || value.index == 0)) {
    throw StateError('expected error result, got ${value.kind.name}');
  }
  final associated = value.associatedValue;
  if (associated == null ||
      associated.kind != WasmComponentValueDataKind.variant ||
      associated.associatedValue == null) {
    throw StateError('expected stream-error payload');
  }
  return _resourceHandle(associated.associatedValue!);
}

String _directoryEntryName(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.record ||
      value.items.length != 2 ||
      value.items[1].kind != WasmComponentValueDataKind.string) {
    throw StateError('expected directory-entry, got ${value.kind.name}');
  }
  return value.items[1].string!;
}

String? _optionDirectoryEntryName(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.option) {
    throw StateError(
      'expected option<directory-entry>, got ${value.kind.name}',
    );
  }
  if (!(value.isSome ?? false)) {
    return null;
  }
  final associated = value.associatedValue;
  if (associated == null) {
    throw StateError('expected directory-entry payload');
  }
  return _directoryEntryName(associated);
}

String? _optionCaseLabel(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.option) {
    throw StateError('expected option case, got ${value.kind.name}');
  }
  if (!(value.isSome ?? value.label == 'some' || value.index == 1)) {
    return null;
  }
  final associated = value.associatedValue;
  if (associated == null) {
    throw StateError('expected option case payload');
  }
  return _caseLabel(associated);
}

String? _optionIpAddressLabel(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.option) {
    throw StateError('expected option<ip-address>, got ${value.kind.name}');
  }
  if (!(value.isSome ?? false)) {
    return null;
  }
  final associated = value.associatedValue;
  if (associated == null) {
    throw StateError('expected ip-address payload');
  }
  return _caseLabel(associated);
}

WasmComponentValueData _enumValue(String label) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.enumeration,
    rawBytes: Uint8List(0),
    label: label,
  );
}

WasmComponentValueData _flagsValue(List<String> labels) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.flags,
    rawBytes: Uint8List(0),
    labels: labels,
  );
}

String? _optionString(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.option) {
    throw StateError('expected option<string>, got ${value.kind.name}');
  }
  if (!(value.isSome ?? value.label == 'some' || value.index == 1)) {
    return null;
  }
  final associated = value.associatedValue;
  if (associated?.kind != WasmComponentValueDataKind.string) {
    throw StateError('expected option<string> payload');
  }
  return associated!.string;
}

WasmComponentValueData _optionPayload(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.option ||
      !(value.isSome ?? value.label == 'some' || value.index == 1) ||
      value.associatedValue == null) {
    throw StateError('expected some option payload');
  }
  return value.associatedValue!;
}

BigInt? _optionU64(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.option) {
    throw StateError('expected option<u64>, got ${value.kind.name}');
  }
  if (!(value.isSome ?? value.label == 'some' || value.index == 1)) {
    return null;
  }
  final associated = value.associatedValue;
  if (associated == null) {
    throw StateError('expected option<u64> payload');
  }
  return _u64Data(associated);
}

(BigInt, BigInt) _u64Tuple(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.tuple ||
      value.items.length != 2) {
    throw StateError('expected tuple<u64, u64>, got ${value.kind.name}');
  }
  return (_u64Data(value.items[0]), _u64Data(value.items[1]));
}

BigInt _u64Data(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.integer) {
    throw StateError('expected u64, got ${value.kind.name}');
  }
  final integer = value.integer;
  if (integer is BigInt) {
    return integer;
  }
  if (integer is int) {
    return BigInt.from(integer);
  }
  throw StateError('expected integer payload, got $integer');
}

bool _resultBool(WasmComponentValueData value) {
  final result = _resultOk(value);
  if (result.kind != WasmComponentValueDataKind.boolean ||
      result.boolean == null) {
    throw StateError('expected bool result, got ${result.kind.name}');
  }
  return result.boolean!;
}

WasmComponentValueData _readTuple(WasmComponentValueData value) {
  return _resultOk(value);
}

List<int> _readBytes(WasmComponentValueData value) {
  final tuple = _readTuple(value);
  if (tuple.kind != WasmComponentValueDataKind.tuple ||
      tuple.items.length != 2) {
    throw StateError('expected read tuple, got ${tuple.kind.name}');
  }
  return _u8List(tuple.items[0]);
}

bool _readReachedEnd(WasmComponentValueData value) {
  final tuple = _readTuple(value);
  if (tuple.kind != WasmComponentValueDataKind.tuple ||
      tuple.items.length != 2 ||
      tuple.items[1].kind != WasmComponentValueDataKind.boolean) {
    throw StateError('expected read tuple eof flag, got ${tuple.kind.name}');
  }
  return tuple.items[1].boolean!;
}

int _instantNanoseconds(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.record ||
      value.items.length != 2) {
    throw StateError('expected clock instant, got ${value.kind.name}');
  }
  final nanos = value.items[1];
  if (nanos.kind != WasmComponentValueDataKind.integer ||
      nanos.integer is! int) {
    throw StateError('expected instant nanoseconds u32');
  }
  return nanos.integer as int;
}

void _expectUnitOk(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.result ||
      !(value.isOk ?? value.label == 'ok' || value.index == 0)) {
    throw StateError('expected unit ok result, got ${value.kind.name}');
  }
}

({int input, int output}) _tcpStreamPair(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.tuple ||
      value.items.length != 2) {
    throw StateError('expected tcp stream pair, got ${value.kind.name}');
  }
  return (
    input: _resourceHandle(value.items[0]),
    output: _resourceHandle(value.items[1]),
  );
}

({int socket, int input, int output}) _tcpAcceptTuple(
  WasmComponentValueData value,
) {
  if (value.kind != WasmComponentValueDataKind.tuple ||
      value.items.length != 3) {
    throw StateError('expected tcp accept tuple, got ${value.kind.name}');
  }
  return (
    socket: _resourceHandle(value.items[0]),
    input: _resourceHandle(value.items[1]),
    output: _resourceHandle(value.items[2]),
  );
}

(int, int) _udpStreamPair(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.tuple ||
      value.items.length != 2) {
    throw StateError('expected udp stream pair, got ${value.kind.name}');
  }
  return (_resourceHandle(value.items[0]), _resourceHandle(value.items[1]));
}

List<List<int>> _udpDatagramPayloads(WasmComponentValueData value) {
  if (value.kind != WasmComponentValueDataKind.list) {
    throw StateError('expected datagram list, got ${value.kind.name}');
  }
  return [
    for (final item in value.items)
      if (item.kind == WasmComponentValueDataKind.record &&
          item.items.length == 2)
        _u8List(item.items[0])
      else
        throw StateError('expected datagram record, got ${item.kind.name}'),
  ];
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

WasmComponentValueData _outgoingDatagramsValue(
  List<(List<int>, WasmComponentValueData)> datagrams,
) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    items: [
      for (final (bytes, remoteAddress) in datagrams)
        _recordValue([_u8ListValue(bytes), _someValue(remoteAddress)]),
    ],
  );
}

WasmComponentValueData _someValue(WasmComponentValueData value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'some',
    isSome: true,
    associatedValue: value,
  );
}

WasmComponentValueData _noneValue() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'none',
    isSome: false,
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

WasmComponentValueData _variantCaseValue(
  String label,
  int index, [
  WasmComponentValueData? associatedValue,
]) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.variant,
    rawBytes: Uint8List(0),
    index: index,
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

final class _LoopbackHttpBackend implements WASIPreview2HttpBackend {
  int requestCount = 0;
  String? lastMethod;
  String? lastAuthority;
  String? lastPathWithQuery;
  List<String> lastHeaderNames = const <String>[];
  List<int> lastBody = const <int>[];

  @override
  WASIPreview2HttpResult<WASIPreview2HttpFutureIncomingResponse> handle(
    WASIPreview2HttpOutgoingRequest request,
    WASIPreview2HttpRequestOptions? options,
  ) {
    requestCount++;
    lastMethod = request.method.wireName;
    lastAuthority = request.authority;
    lastPathWithQuery = request.pathWithQuery;
    lastHeaderNames = [
      for (final entry in request.headers.entries) entry.name.toLowerCase(),
    ];
    lastBody = request.bodyResource?.bytes ?? const <int>[];
    return WASIPreview2HttpResult<WASIPreview2HttpFutureIncomingResponse>.ok(
      WASIPreview2HttpFutureIncomingResponse.completed(
        WASIPreview2HttpResult<WASIPreview2HttpIncomingResponse>.ok(
          WASIPreview2HttpIncomingResponse(
            status: 201,
            headers: WASIPreview2HttpFields(
              entries: const <WASIPreview2HttpFieldEntry>[
                WASIPreview2HttpFieldEntry('x-reply', <int>[111, 107]),
              ],
              mutable: false,
            ),
            body: WASIPreview2HttpIncomingBody(
              WASIPreview2InputStream(
                bytes: const <int>[104, 105],
                closed: true,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _LoopbackSocketsBackend implements WASIPreview2SocketsBackend {
  final Map<String, _LoopbackTcpListener> _tcpListeners = {};
  final Map<String, _LoopbackUdpBinding> _udpBindings = {};
  int _nextPort = 49152;

  int acceptedConnections = 0;
  int sentDatagrams = 0;

  @override
  WASIPreview2SocketOperation<WASIPreview2IpSocketAddress> startTcpBind(
    WASIPreview2IpSocketAddress localAddress,
  ) {
    return WASIPreview2SocketOperation<WASIPreview2IpSocketAddress>.completed(
      WASIPreview2SocketResult<WASIPreview2IpSocketAddress>.ok(
        _materializePort(localAddress),
      ),
    );
  }

  @override
  WASIPreview2SocketOperation<WASIPreview2TcpConnection> startTcpConnect({
    required WASIPreview2IpSocketAddress remoteAddress,
    WASIPreview2IpSocketAddress? localAddress,
  }) {
    final listener = _tcpListeners[_addressKey(remoteAddress)];
    if (listener == null) {
      return WASIPreview2SocketOperation<WASIPreview2TcpConnection>.completed(
        const WASIPreview2SocketResult<WASIPreview2TcpConnection>.error(
          'connection-refused',
        ),
      );
    }
    final clientLocal = _materializePort(
      localAddress ??
          WASIPreview2IpSocketAddress.ipv4(port: 0, a: 127, b: 0, c: 0, d: 1),
    );
    final clientInput = WASIPreview2InputStream();
    final serverInput = WASIPreview2InputStream();
    final clientOutput = WASIPreview2OutputStream(
      onWrite: (bytes) {
        serverInput.append(bytes);
        return null;
      },
    );
    final serverOutput = WASIPreview2OutputStream(
      onWrite: (bytes) {
        clientInput.append(bytes);
        return null;
      },
    );
    final clientConnection = WASIPreview2TcpConnection(
      inputStream: clientInput,
      outputStream: clientOutput,
      localAddress: clientLocal,
      remoteAddress: remoteAddress,
    );
    final serverConnection = WASIPreview2TcpConnection(
      inputStream: serverInput,
      outputStream: serverOutput,
      localAddress: remoteAddress,
      remoteAddress: clientLocal,
    );
    listener.enqueue(serverConnection);
    acceptedConnections++;
    return WASIPreview2SocketOperation<WASIPreview2TcpConnection>.completed(
      WASIPreview2SocketResult<WASIPreview2TcpConnection>.ok(clientConnection),
    );
  }

  @override
  WASIPreview2SocketOperation<WASIPreview2TcpListener> startTcpListen({
    required WASIPreview2IpSocketAddress localAddress,
    required BigInt backlog,
  }) {
    final address = _materializePort(localAddress);
    final listener = _LoopbackTcpListener(address);
    _tcpListeners[_addressKey(address)] = listener;
    return WASIPreview2SocketOperation<WASIPreview2TcpListener>.completed(
      WASIPreview2SocketResult<WASIPreview2TcpListener>.ok(listener),
    );
  }

  @override
  WASIPreview2SocketOperation<WASIPreview2UdpBinding> startUdpBind(
    WASIPreview2IpSocketAddress localAddress,
  ) {
    final address = _materializePort(localAddress);
    final binding = _LoopbackUdpBinding(this, address);
    _udpBindings[_addressKey(address)] = binding;
    return WASIPreview2SocketOperation<WASIPreview2UdpBinding>.completed(
      WASIPreview2SocketResult<WASIPreview2UdpBinding>.ok(binding),
    );
  }

  WASIPreview2IpSocketAddress _materializePort(
    WASIPreview2IpSocketAddress address,
  ) {
    if (address.port != 0) {
      return address;
    }
    return WASIPreview2IpSocketAddress.ipv4(
      port: _nextPort++,
      a: address.address.parts[0],
      b: address.address.parts[1],
      c: address.address.parts[2],
      d: address.address.parts[3],
    );
  }

  String _addressKey(WASIPreview2IpSocketAddress address) =>
      '${address.host}:${address.port}';
}

final class _LoopbackTcpListener implements WASIPreview2TcpListener {
  _LoopbackTcpListener(this.localAddress);

  @override
  final WASIPreview2IpSocketAddress localAddress;

  final List<WASIPreview2TcpConnection> _queue = [];
  final List<Completer<void>> _waiters = [];
  bool _closed = false;

  @override
  bool get canAccept => _queue.isNotEmpty || _closed;

  @override
  Future<void> waitAccept() {
    if (canAccept) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  @override
  WASIPreview2SocketResult<WASIPreview2TcpConnection> accept() {
    if (_queue.isEmpty) {
      return const WASIPreview2SocketResult<WASIPreview2TcpConnection>.error(
        'would-block',
      );
    }
    return WASIPreview2SocketResult<WASIPreview2TcpConnection>.ok(
      _queue.removeAt(0),
    );
  }

  @override
  void close() {
    _closed = true;
    _notify();
  }

  void enqueue(WASIPreview2TcpConnection connection) {
    _queue.add(connection);
    _notify();
  }

  void _notify() {
    final waiters = List<Completer<void>>.of(_waiters);
    _waiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }
}

final class _LoopbackUdpBinding implements WASIPreview2UdpBinding {
  _LoopbackUdpBinding(this.backend, this.localAddress);

  final _LoopbackSocketsBackend backend;

  @override
  final WASIPreview2IpSocketAddress localAddress;

  @override
  WASIPreview2IpSocketAddress? get remoteAddress => null;

  @override
  BigInt get sendCapacity => BigInt.from(64);

  @override
  bool get canReceive => _queue.isNotEmpty;

  @override
  bool get canSend => true;

  final List<WASIPreview2IncomingDatagram> _queue = [];

  @override
  Future<void> waitReceive() => Future<void>.value();

  @override
  Future<void> waitSend() => Future<void>.value();

  @override
  WASIPreview2SocketResult<List<WASIPreview2IncomingDatagram>> receive(
    BigInt maxResults,
  ) {
    final count = maxResults.toInt() < _queue.length
        ? maxResults.toInt()
        : _queue.length;
    final datagrams = _queue.sublist(0, count);
    _queue.removeRange(0, count);
    return WASIPreview2SocketResult<List<WASIPreview2IncomingDatagram>>.ok(
      datagrams,
    );
  }

  @override
  WASIPreview2SocketResult<BigInt> send(
    List<WASIPreview2OutgoingDatagram> datagrams,
  ) {
    var sent = 0;
    for (final datagram in datagrams) {
      final remoteAddress = datagram.remoteAddress;
      if (remoteAddress == null) {
        return const WASIPreview2SocketResult<BigInt>.error(
          'remote-unreachable',
        );
      }
      final target = backend._udpBindings[backend._addressKey(remoteAddress)];
      if (target == null) {
        return const WASIPreview2SocketResult<BigInt>.error(
          'remote-unreachable',
        );
      }
      target._queue.add(
        WASIPreview2IncomingDatagram(
          data: Uint8List.fromList(datagram.data),
          remoteAddress: localAddress,
        ),
      );
      sent++;
      backend.sentDatagrams++;
    }
    return WASIPreview2SocketResult<BigInt>.ok(BigInt.from(sent));
  }

  @override
  void close() {}
}

WasmComponentValueData _stringTupleListValue(List<(String, String)> rows) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    items: [
      for (final row in rows)
        WasmComponentValueData(
          kind: WasmComponentValueDataKind.tuple,
          rawBytes: Uint8List(0),
          items: [
            WasmComponentValueData(
              kind: WasmComponentValueDataKind.string,
              rawBytes: Uint8List(0),
              string: row.$1,
            ),
            WasmComponentValueData(
              kind: WasmComponentValueDataKind.string,
              rawBytes: Uint8List(0),
              string: row.$2,
            ),
          ],
        ),
    ],
  );
}

WasmComponentValueData _badStringTupleListValue() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    items: [
      WasmComponentValueData(
        kind: WasmComponentValueDataKind.tuple,
        rawBytes: Uint8List(0),
        items: [
          WasmComponentValueData(
            kind: WasmComponentValueDataKind.string,
            rawBytes: Uint8List(0),
            string: 'PATH',
          ),
          WasmComponentValueData(
            kind: WasmComponentValueDataKind.integer,
            rawBytes: Uint8List(0),
            integer: 1,
          ),
        ],
      ),
    ],
  );
}

WasmComponentValueData _envEntryListValue(List<(String, String)> rows) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    items: [for (final row in rows) _envEntryValue(row.$1, row.$2)],
  );
}

WasmComponentValueData _envEntryValue(String name, String value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.record,
    rawBytes: Uint8List(0),
    items: [
      WasmComponentValueData(
        kind: WasmComponentValueDataKind.string,
        rawBytes: Uint8List(0),
        string: name,
      ),
      WasmComponentValueData(
        kind: WasmComponentValueDataKind.string,
        rawBytes: Uint8List(0),
        string: value,
      ),
    ],
  );
}

WasmComponentValueData _badEnvEntryListValue() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    items: [
      WasmComponentValueData(
        kind: WasmComponentValueDataKind.record,
        rawBytes: Uint8List(0),
        items: [
          WasmComponentValueData(
            kind: WasmComponentValueDataKind.string,
            rawBytes: Uint8List(0),
            string: 'PATH',
          ),
        ],
      ),
    ],
  );
}

WasmComponentValueData _permissionsValue(List<String> labels) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.flags,
    rawBytes: Uint8List(0),
    labels: labels,
  );
}

WasmComponentValueData _decisionValue(String label) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.enumeration,
    rawBytes: Uint8List(0),
    label: label,
  );
}

WasmComponentValueData _requestAnonymousValue() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.variant,
    rawBytes: Uint8List(0),
    label: 'anonymous',
  );
}

WasmComponentValueData _requestPathValue(String path) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.variant,
    rawBytes: Uint8List(0),
    label: 'path',
    associatedValue: WasmComponentValueData(
      kind: WasmComponentValueDataKind.string,
      rawBytes: Uint8List(0),
      string: path,
    ),
  );
}

WasmComponentValueData _requestInheritValue(List<String> labels) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.variant,
    rawBytes: Uint8List(0),
    label: 'inherit',
    associatedValue: _permissionsValue(labels),
  );
}

WasmComponentValueData _badRequestPathValue() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.variant,
    rawBytes: Uint8List(0),
    label: 'path',
  );
}

Uint8List _canonicalResourceProgramBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x04,
  0x01,
  0x3f,
  0x7f,
  0x00,
  0x08,
  0x07,
  0x03,
  0x02,
  0x00,
  0x04,
  0x00,
  0x03,
  0x00,
]);

Uint8List _canonicalMixedResourceBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x08,
  0x02,
  0x3f,
  0x7f,
  0x00,
  0x40,
  0x00,
  0x01,
  0x00,
  0x08,
  0x07,
  0x02,
  0x02,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
]);

Uint8List _canonicalStreamProgramBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x03,
  0x01,
  0x66,
  0x00,
  0x08,
  0x13,
  0x07,
  0x0e,
  0x00,
  0x0f,
  0x00,
  0x00,
  0x10,
  0x00,
  0x00,
  0x11,
  0x00,
  0x00,
  0x12,
  0x00,
  0x00,
  0x13,
  0x00,
  0x14,
  0x00,
]);
