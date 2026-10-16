import 'package:test/test.dart';
import 'package:wasd/wasm.dart';

import 'support/host_tag_fixtures.dart';
import 'support/runtime_environment.dart';

const _payloads = <String, List<ValueKind>>{
  'empty': [],
  'i32': [ValueKind.i32],
  'i64': [ValueKind.i64],
  'f32': [ValueKind.f32],
  'f64': [ValueKind.f64],
  'mixed': [ValueKind.i32, ValueKind.i64, ValueKind.f32, ValueKind.f64],
};

Object _sample(ValueKind kind) => switch (kind) {
  ValueKind.i32 => 37,
  ValueKind.i64 => BigInt.parse('123456789abcdef', radix: 16),
  ValueKind.f32 => 1.25,
  ValueKind.f64 => 2.5,
  _ => throw StateError('Unsupported test kind $kind'),
};

Object? _normalize(Object? value) => switch (value) {
  BigInt() => value.toInt(),
  List() => value.map(_normalize).toList(),
  _ => value,
};

Module _module(String fixture) => Module(
  hostTagFixture(fixture).buffer,
  features: {CoreFeature.exceptionHandling},
);

WasmFunction _tick(bool asyncHost) =>
    asyncHost ? (List<Object?> _) async => null : (List<Object?> _) => null;

Tag _tag(Instance instance, String name) =>
    (instance.exports[name]! as TagImportExportValue).ref;

WasmFunction _function(Instance instance, String name) =>
    (instance.exports[name]! as FunctionImportExportValue).ref;

void main() {
  if (!hasDartIoRuntime) return;

  test('native tag snapshots constructor parameters', () {
    final parameters = <ValueKind>[ValueKind.i32];
    final tag = Tag(TagDescriptor(parameters: parameters));
    parameters[0] = ValueKind.i64;
    expect(tag.type().parameters, [ValueKind.i32]);
  });

  test('native tag type returns a fresh parameter snapshot', () {
    final tag = Tag(const TagDescriptor(parameters: [ValueKind.i32]));
    final parameters = tag.type().parameters;
    parameters[0] = ValueKind.i64;
    expect(tag.type().parameters, [ValueKind.i32]);
  });

  for (final payload in _payloads.entries) {
    for (final asyncHost in [false, true]) {
      test('${payload.key} throw/catch and exports async=$asyncHost', () async {
        final tag = Tag(TagDescriptor(parameters: payload.value));
        final instance = Instance(_module(payload.key), {
          'host': {
            'tick': ImportExportKind.function(_tick(asyncHost)),
            'tag': ImportExportKind.tag(tag),
          },
        });
        expect(_tag(instance, 'tag'), same(tag));
        expect(_tag(instance, 'alias'), same(tag));
        expect(_tag(instance, 'tag').type().parameters, payload.value);
        final args = payload.value.map(_sample).toList();
        final result = _function(instance, 'catch')(args);
        expect(result is Future, asyncHost);
        final expected = args.isEmpty
            ? null
            : args.length == 1
            ? args.single
            : args;
        expect(
          _normalize(await Future<Object?>.value(result)),
          _normalize(expected),
        );
      });
    }
  }

  test(
    'guest numeric tag exports preserve payload signatures on re-import',
    () {
      final provider = Instance(_module('exported_payloads'));
      for (final payload in _payloads.entries) {
        final tag = _tag(provider, payload.key);
        expect(tag.type().parameters, payload.value);
        final returned = tag.type().parameters;
        returned.clear();
        expect(tag.type().parameters, payload.value);
        final consumer = Instance(_module(payload.key), {
          'host': {
            'tick': ImportExportKind.function(_tick(false)),
            'tag': ImportExportKind.tag(tag),
          },
        });
        expect(_tag(consumer, 'tag'), same(tag));
        final args = payload.value.map(_sample).toList();
        final expected = args.isEmpty
            ? null
            : args.length == 1
            ? args.single
            : args;
        expect(
          _normalize(_function(consumer, 'catch')(args)),
          _normalize(expected),
        );
      }
    },
  );

  for (final asyncHost in [false, true]) {
    test('aliases catch the same tag identity async=$asyncHost', () async {
      final tag = Tag(const TagDescriptor(parameters: [ValueKind.i32]));
      final instance = Instance(_module('identity'), {
        'host': {
          'tick': ImportExportKind.function(_tick(asyncHost)),
          'first': ImportExportKind.tag(tag),
          'second': ImportExportKind.tag(tag),
        },
      });
      expect(_tag(instance, 'first'), same(_tag(instance, 'second')));
      expect(
        await Future<Object?>.value(_function(instance, 'catch')([42])),
        42,
      );
    });

    test(
      'same-signature independent tags do not catch async=$asyncHost',
      () async {
        final first = Tag(const TagDescriptor(parameters: [ValueKind.i32]));
        final second = Tag(const TagDescriptor(parameters: [ValueKind.i32]));
        final instance = Instance(_module('identity'), {
          'host': {
            'tick': ImportExportKind.function(_tick(asyncHost)),
            'first': ImportExportKind.tag(first),
            'second': ImportExportKind.tag(second),
          },
        });
        expect(_tag(instance, 'first'), isNot(same(_tag(instance, 'second'))));
        await expectLater(
          Future<Object?>.sync(() => _function(instance, 'catch')([42])),
          throwsA(anything),
        );
      },
    );
  }

  for (final mode in [
    (callee: false, catcher: false),
    (callee: false, catcher: true),
    (callee: true, catcher: true),
    (callee: true, catcher: false),
  ]) {
    test('guest tag re-import catches cross-instance throw $mode', () async {
      var calls = 0;
      final tick = mode.callee
          ? (List<Object?> _) async {
              calls++;
              return null;
            }
          : (List<Object?> _) {
              calls++;
              return null;
            };
      final provider = Instance(_module('provider'), {
        'host': {'tick': ImportExportKind.function(tick)},
      });
      final otherProvider = Instance(_module('provider'), {
        'host': {'tick': ImportExportKind.function(_tick(mode.callee))},
      });
      final tag = _tag(provider, 'tag');
      expect(tag, same(_tag(provider, 'alias')));
      expect(tag.type().parameters, [ValueKind.i32]);
      final throwFunction = _function(provider, 'throw');
      Instance consumer(Tag tag) => Instance(_module('consumer'), {
        'host': {
          'tick': ImportExportKind.function(_tick(mode.catcher)),
          'source': ImportExportKind.function(throwFunction),
          'tag': ImportExportKind.tag(tag),
        },
      });
      final consumerInstance = consumer(tag);
      expect(_tag(consumerInstance, 'tag'), same(tag));
      expect(
        await Future<Object?>.value(_function(consumerInstance, 'catch')([42])),
        42,
      );
      expect(calls, 1);
      await expectLater(
        Future<Object?>.sync(
          () => _function(consumer(_tag(otherProvider, 'tag')), 'catch')([42]),
        ),
        throwsA(anything),
      );
      expect(calls, 2);
    });
  }

  test('duplicate import names check every tag declaration', () {
    final module = _module('duplicate_import');
    expect(
      () => Instance(module, {
        'host': {
          'tag': ImportExportKind.tag(
            Tag(const TagDescriptor(parameters: [ValueKind.i32])),
          ),
        },
      }),
      throwsA(isA<LinkError>()),
    );
  });

  test('unsupported exported tags fail before guest start effects', () {
    var calls = 0;
    expect(
      () => Instance(_module('unsupported_export_start'), {
        'host': {
          'tick': ImportExportKind.function((_) {
            calls++;
            return null;
          }),
        },
      }),
      throwsA(isA<LinkError>()),
    );
    expect(calls, 0);
  });

  test('plain host tags cannot satisfy non-final defined types', () {
    final imports = {
      'host': {
        'tag': ImportExportKind.tag(
          Tag(const TagDescriptor(parameters: [ValueKind.i32])),
        ),
      },
    };
    expect(
      () => Instance(_module('nonfinal_import'), imports),
      throwsA(isA<LinkError>()),
    );
    expect(() => Instance(_module('final_import'), imports), returnsNormally);
  });

  test('tag imports reject wrong kind, missing, and foreign tags', () {
    final module = _module('i32');
    for (final value in <ImportValue?>[
      null,
      ImportExportKind.function((_) => null),
      ImportExportKind.tag(_ForeignTag()),
    ]) {
      expect(
        () => Instance(module, {
          'host': {
            'tick': ImportExportKind.function(_tick(false)),
            'tag': ?value,
          },
        }),
        throwsA(isA<LinkError>()),
      );
    }
  });

  test(
    'tag payload signatures reject wrong order, length, and numeric kinds',
    () {
      final module = _module('mixed');
      for (final parameters in <List<ValueKind>>[
        [],
        [ValueKind.i32, ValueKind.i64, ValueKind.f32],
        [ValueKind.i64, ValueKind.i32, ValueKind.f32, ValueKind.f64],
        [ValueKind.i32, ValueKind.i64, ValueKind.f64, ValueKind.f64],
        [..._payloads['mixed']!, ValueKind.i32],
      ]) {
        expect(
          () => Instance(module, {
            'host': {
              'tick': ImportExportKind.function(_tick(false)),
              'tag': ImportExportKind.tag(
                Tag(TagDescriptor(parameters: parameters)),
              ),
            },
          }),
          throwsA(isA<LinkError>()),
        );
      }
    },
  );

  for (final kind in <ValueKind>[
    ValueKind.externref,
    ValueKind.funcref,
    ValueKind.v128,
  ]) {
    test(
      'unsupported ${kind.name} host payload rejects a declared binding',
      () {
        expect(
          () => Instance(_module('i32'), {
            'host': {
              'tick': ImportExportKind.function(_tick(false)),
              'tag': ImportExportKind.tag(
                Tag(TagDescriptor(parameters: [kind])),
              ),
            },
          }),
          throwsA(isA<LinkError>()),
        );
      },
    );

    test('i32 carrier cannot satisfy a ${kind.name} tag signature', () {
      expect(
        () => Instance(_module('${kind.name}_import'), {
          'host': {
            'tag': ImportExportKind.tag(
              Tag(const TagDescriptor(parameters: [ValueKind.i32])),
            ),
          },
        }),
        throwsA(isA<LinkError>()),
      );
    });

    test('unsupported ${kind.name} tag exports fail explicitly', () {
      expect(
        () => Instance(_module('${kind.name}_export')),
        throwsA(isA<LinkError>()),
      );
    });
  }

  test('unused superset tags do not bind or block instantiation', () {
    final tag = Tag(const TagDescriptor(parameters: []));
    final instance = Instance(_module('empty'), {
      'host': {
        'tick': ImportExportKind.function(_tick(false)),
        'tag': ImportExportKind.tag(tag),
        'extra': ImportExportKind.tag(_ForeignTag()),
      },
      'unused': {
        for (final kind in <ValueKind>[
          ValueKind.externref,
          ValueKind.funcref,
          ValueKind.v128,
        ])
          kind.name: ImportExportKind.tag(
            Tag(TagDescriptor(parameters: [kind])),
          ),
      },
    });
    expect(_function(instance, 'catch')([]), isNull);
  });
}

class _ForeignTag implements Tag {
  @override
  TagDescriptor type() => const TagDescriptor(parameters: [ValueKind.i32]);
}
