import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/async_host.dart';
import 'package:wasd/src/wasi/component/canonical_host.dart';
import 'package:wasd/src/wasi/component/host.dart';
import 'package:wasd/src/wasi/component/resource_host.dart';
import 'package:wasd/src/wasi/component/versioned_host.dart';
import 'package:wasd/src/wasi/component/waitable_set.dart';
import 'package:wasd/src/wasi/component/wit_document.dart';
import 'package:wasd/src/wasi/preview2/component_host.dart';
import 'package:wasd/src/wasi/preview3/component_host.dart';
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

    test('keeps Preview3 host capability gaps separate from version gates', () {
      final component = WasmComponent.decode(_canonicalMixedResourceBytes());
      final host = WASIComponentVersionedHost(version: WASIVersion.preview3);

      final plan = host.prepareComponent(component, validate: false);

      expect(plan.canBind, isFalse);
      expect(plan.versionErrors, isEmpty);
      expect(plan.bindingErrors, isEmpty);
      expect(plan.unsupportedDefinitions, hasLength(1));
      expect(
        plan.unsupportedDefinitions.single.kind,
        WasmComponentCanonicalKind.lower,
      );
      expect(
        () => plan.bind(),
        throwsA(isA<WASIComponentCanonicalHostUnsupportedException>()),
      );
      expect(host.componentHost.table.activeCount, 0);
    });
  });

  group('fixed WASI component host versions', () {
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
        expect(preview3Plan.canBindAdapters, isFalse);
        expect(
          preview3Plan.bindingErrors.map(
            (error) => error.function.qualifiedName,
          ),
          containsAll(<String>['run.run', 'stdout.write-via-stream']),
        );
        expect(preview3Plan.world.name, 'command');
        expect(preview3Plan.items.map((item) => item.target.text), [
          'run',
          'wasi:filesystem/imports@0.3.0',
          'stdout',
        ]);
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

    test('Preview3 wrapper reports adapter resource handle uses', () {
      final component = WasmComponent.decode(
        canonicalResourceLiftComponentBytes(),
      );
      final host = WASIPreview3ComponentHost();

      final plan = host.prepareComponent(component);

      expect(component.validate(), isEmpty);
      expect(plan.canBind, isFalse);
      expect(plan.versionErrors, isEmpty);
      expect(plan.unsupportedDefinitions, hasLength(1));
      expect(
        plan.unsupportedDefinitions.single.kind,
        WasmComponentCanonicalKind.lift,
      );
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
      expect(
        () => plan.bind(),
        throwsA(isA<WASIComponentCanonicalHostUnsupportedException>()),
      );
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
