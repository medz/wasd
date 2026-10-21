import 'package:test/test.dart';
import 'package:wasd/wasm.dart';

import 'support/host_global_fixtures.dart';
import 'support/runtime_environment.dart';

const List<ValueKind> _kinds = [
  ValueKind.i32,
  ValueKind.i64,
  ValueKind.f32,
  ValueKind.f64,
];

Object _sample(ValueKind kind, int value) => switch (kind) {
  ValueKind.i64 => BigInt.from(value),
  ValueKind.f32 || ValueKind.f64 => value.toDouble(),
  _ => value,
};

Global _global(ValueKind kind, bool mutable, int value) => switch (kind) {
  ValueKind.i32 => Global<Int32, int>(
    GlobalDescriptor<Int32, int>(value: ValueKind.i32, mutable: mutable),
    value,
  ),
  ValueKind.i64 => Global<Int64, BigInt>(
    GlobalDescriptor<Int64, BigInt>(value: ValueKind.i64, mutable: mutable),
    BigInt.from(value),
  ),
  ValueKind.f32 => Global<Float32, double>(
    GlobalDescriptor<Float32, double>(value: ValueKind.f32, mutable: mutable),
    value.toDouble(),
  ),
  ValueKind.f64 => Global<Float64, double>(
    GlobalDescriptor<Float64, double>(value: ValueKind.f64, mutable: mutable),
    value.toDouble(),
  ),
  _ => throw UnsupportedError('Unsupported test kind $kind'),
};

void _expectValue(Object? actual, Object expected) {
  expect(
    expected is BigInt && actual is int ? BigInt.from(actual) : actual,
    expected,
  );
}

void main() {
  for (final kind in _kinds) {
    for (final mutable in [false, true]) {
      for (final asyncHost in [false, true]) {
        if (asyncHost && !hasDartIoRuntime) continue;
        test(
          '${kind.name} mutable=$mutable asyncHost=$asyncHost stays bound',
          () async {
            final global = _global(kind, mutable, 21);
            final module = Module(
              hostGlobalFixture(
                '${kind.name}_${mutable ? 'mutable' : 'immutable'}',
              ).buffer,
            );
            final tick = asyncHost
                ? (List<Object?> _) async => null
                : (List<Object?> _) => null;
            final imports = <String, ModuleImports>{
              'host': {
                'tick': ImportExportKind.function(tick),
                'value': ImportExportKind.global(global),
              },
            };
            final first = Instance(module, imports);
            final second = Instance(module, imports);
            Future<Object?> call(
              Instance instance,
              String name,
              List<Object?> args,
            ) async =>
                (instance.exports[kind == ValueKind.i64 && !hasDartIoRuntime
                            ? (name == 'get' ? 'getLo' : 'setFromI32')
                            : name]!
                        as FunctionImportExportValue)
                    .ref(
                      kind == ValueKind.i64 &&
                              !hasDartIoRuntime &&
                              args.isNotEmpty
                          ? [(args.single as BigInt).toInt()]
                          : args,
                    );
            _expectValue(await call(first, 'get', []), _sample(kind, 21));
            if (mutable) {
              global.value = _sample(kind, 42);
              _expectValue(await call(first, 'get', []), _sample(kind, 42));
              _expectValue(await call(second, 'get', []), _sample(kind, 42));
              await call(first, 'set', [_sample(kind, 63)]);
              _expectValue(global.value, _sample(kind, 63));
              _expectValue(await call(second, 'get', []), _sample(kind, 63));
            } else {
              expect(() => global.value = _sample(kind, 42), throwsA(anything));
              _expectValue(await call(second, 'get', []), _sample(kind, 21));
            }
          },
        );
      }
    }
    for (final mutable in [false, true]) {
      for (final actualKind in _kinds.where((other) => other != kind)) {
        test(
          '${kind.name} rejects ${actualKind.name} import mutable=$mutable',
          () {
            final module = Module(
              hostGlobalFixture(
                '${kind.name}_${mutable ? 'mutable' : 'immutable'}',
              ).buffer,
            );
            final global = _global(actualKind, mutable, 21);
            expect(
              () => Instance(module, {
                'host': {
                  'tick': ImportExportKind.function((_) => null),
                  'value': ImportExportKind.global(global),
                },
              }),
              throwsA(
                isA<LinkError>().having(
                  (e) => e.message,
                  'message',
                  hasDartIoRuntime
                      ? contains('incompatible import type')
                      : contains('imported global does not match'),
                ),
              ),
            );
          },
        );
      }
      test('${kind.name} rejects opposite mutability expected=$mutable', () {
        final module = Module(
          hostGlobalFixture(
            '${kind.name}_${mutable ? 'mutable' : 'immutable'}',
          ).buffer,
        );
        final global = _global(kind, !mutable, 21);
        expect(
          () => Instance(module, {
            'host': {
              'tick': ImportExportKind.function((_) => null),
              'value': ImportExportKind.global(global),
            },
          }),
          throwsA(
            isA<LinkError>().having(
              (e) => e.message,
              'message',
              hasDartIoRuntime
                  ? contains('incompatible import type')
                  : contains('imported global does not match'),
            ),
          ),
        );
      });
    }
  }

  test('i64 host binding preserves all 64 bits through scalar exports', () {
    final original = BigInt.parse('fedcba9876543210', radix: 16).toSigned(64);
    final value = Global<Int64, BigInt>(
      const GlobalDescriptor<Int64, BigInt>(
        value: ValueKind.i64,
        mutable: true,
      ),
      original,
    );
    final instance = Instance(Module(hostGlobalFixture('i64_mutable').buffer), {
      'host': {
        'tick': ImportExportKind.function((_) => null),
        'value': ImportExportKind.global(value),
      },
    });
    expect(value.value, original);
    expect(
      (instance.exports['getLo']! as FunctionImportExportValue).ref([]),
      0x76543210,
    );
    expect(
      (instance.exports['getHi']! as FunctionImportExportValue).ref([]),
      -19088744,
    );
    value.value = BigInt.parse('1234567887654321', radix: 16);
    expect(
      (instance.exports['getLo']! as FunctionImportExportValue).ref([]),
      -2023406815,
    );
    expect(
      (instance.exports['getHi']! as FunctionImportExportValue).ref([]),
      0x12345678,
    );
  });

  _referenceGlobalTests();

  if (!hasDartIoRuntime) return;

  test('VM binds distinct globals whose old runtime keys collided', () {
    final raw = Global<Int32, int>(
      const GlobalDescriptor<Int32, int>(value: ValueKind.i32),
      0x100000001,
    );
    final instance = Instance(
      Module(hostGlobalFixture('name_collision').buffer),
      {
        'a': {'b::c': ImportExportKind.global(raw)},
        'a::b': {
          'c': ImportExportKind.global(_global(ValueKind.i32, false, 21)),
        },
      },
    );
    expect(
      (instance.exports['first']! as FunctionImportExportValue).ref([]),
      1,
    );
    expect(
      (instance.exports['second']! as FunctionImportExportValue).ref([]),
      21,
    );
    expect(raw.value, 1);
  });

  test('VM global selection preserves module and field name boundaries', () {
    final raw = Global<Int32, int>(
      const GlobalDescriptor<Int32, int>(value: ValueKind.i32),
      0x100000001,
    );
    final module = Module(hostGlobalFixture('name_boundary').buffer);
    expect(
      () => Instance(module, {
        'a::b': {'c': ImportExportKind.global(raw)},
      }),
      throwsA(isA<LinkError>()),
    );
    expect(raw.value, 0x100000001);
    final declared = _global(ValueKind.i32, false, 21);
    final instance = Instance(module, {
      'a': {'b::c': ImportExportKind.global(declared)},
      'a::b': {'c': ImportExportKind.global(raw)},
    });
    expect((instance.exports['get']! as FunctionImportExportValue).ref([]), 21);
    expect(raw.value, 0x100000001);
  });

  test('VM unused numeric globals stay standalone in superset imports', () {
    final wide = (BigInt.one << 65) + BigInt.one;
    final fraction = 1.0 + 1.0 / 16777216;
    final values = <String, Global>{
      'i32': Global<Int32, int>(
        const GlobalDescriptor<Int32, int>(value: ValueKind.i32),
        0x100000001,
      ),
      'i64': Global<Int64, BigInt>(
        const GlobalDescriptor<Int64, BigInt>(value: ValueKind.i64),
        wide,
      ),
      'f32': Global<Float32, double>(
        const GlobalDescriptor<Float32, double>(value: ValueKind.f32),
        fraction,
      ),
    };
    Instance(Module(hostGlobalFixture('f32_export_bits').buffer), {
      'unused': {
        for (final entry in values.entries)
          entry.key: ImportExportKind.global(entry.value),
      },
    });
    expect(values['i32']!.value, 0x100000001);
    expect(values['i64']!.value, wide);
    expect(values['f32']!.value, fraction);
  });

  test('VM unused reference and foreign globals do not prevent linking', () {
    final value = _global(ValueKind.i32, true, 21);
    final instance = Instance(Module(hostGlobalFixture('i32_mutable').buffer), {
      'host': {
        'tick': ImportExportKind.function((_) => null),
        'value': ImportExportKind.global(value),
        'extra': ImportExportKind.global(
          Global<ExternRef, Object?>(
            const GlobalDescriptor<ExternRef, Object?>(
              value: ValueKind.externref,
            ),
            null,
          ),
        ),
      },
      'unused': {'value': ImportExportKind.global(_ForeignGlobal())},
    });
    expect((instance.exports['get']! as FunctionImportExportValue).ref([]), 21);
  });

  test('VM a global supplied for a function import remains standalone', () {
    final value = Global<Int32, int>(
      const GlobalDescriptor<Int32, int>(value: ValueKind.i32),
      0x100000001,
    );
    expect(
      () => Instance(Module(hostGlobalFixture('i32_mutable').buffer), {
        'host': {
          'tick': ImportExportKind.global(value),
          'value': ImportExportKind.global(_global(ValueKind.i32, true, 21)),
        },
      }),
      throwsA(isA<LinkError>()),
    );
    expect(value.value, 0x100000001);
  });

  for (final kind in ['f32', 'f64']) {
    for (final asyncHost in [false, true]) {
      test(
        'VM $kind export getter/re-import preserves signaling NaN bits async=$asyncHost',
        () async {
          final first = Instance(
            Module(hostGlobalFixture('${kind}_export_bits').buffer),
          );
          final exported = first.exports['value']! as GlobalImportExportValue;
          expect((exported.ref.value as double).isNaN, isTrue);
          final tick = asyncHost
              ? (List<Object?> _) async => null
              : (List<Object?> _) => null;
          final second = Instance(
            Module(hostGlobalFixture('${kind}_mutable').buffer),
            {
              'host': {
                'tick': ImportExportKind.function(tick),
                'value': exported,
              },
            },
          );
          final bits = await Future<Object?>.sync(
            () =>
                (second.exports['bits']! as FunctionImportExportValue).ref([]),
          );
          _expectValue(
            bits,
            kind == 'f32'
                ? 0x7fa12345
                : BigInt.parse('7ff0123456789abc', radix: 16),
          );
          _expectValue(
            (first.exports['bits']! as FunctionImportExportValue).ref([]),
            kind == 'f32'
                ? 0x7fa12345
                : BigInt.parse('7ff0123456789abc', radix: 16),
          );
        },
      );
    }
  }

  test(
    'VM preserves standalone boxes and converts numeric values when bound',
    () {
      final raw = 0x100000001;
      final value = Global<Int32, int>(
        const GlobalDescriptor<Int32, int>(value: ValueKind.i32, mutable: true),
        raw,
      );
      expect(value.value, raw);
      final module = Module(hostGlobalFixture('i32_mutable').buffer);
      final instance = Instance(module, {
        'host': {
          'tick': ImportExportKind.function((_) => null),
          'value': ImportExportKind.global(value),
        },
      });
      expect(value.value, 1);
      value.value = 0x1ffffffff;
      expect(value.value, -1);
      expect(
        (instance.exports['get']! as FunctionImportExportValue).ref([]),
        -1,
      );
    },
  );

  test('VM bound i64 wraps and f32 rounds without changing unbound boxes', () {
    final wide = (BigInt.one << 65) + BigInt.one;
    final integer = Global<Int64, BigInt>(
      const GlobalDescriptor<Int64, BigInt>(value: ValueKind.i64),
      wide,
    );
    final fraction = 1.0 + 1.0 / 16777216;
    final float = Global<Float32, double>(
      const GlobalDescriptor<Float32, double>(value: ValueKind.f32),
      fraction,
    );
    expect(integer.value, wide);
    expect(float.value, fraction);
    for (final entry in <String, Global>{
      'i64': integer,
      'f32': float,
    }.entries) {
      Instance(Module(hostGlobalFixture('${entry.key}_immutable').buffer), {
        'host': {
          'tick': ImportExportKind.function((_) => null),
          'value': ImportExportKind.global(entry.value),
        },
      });
    }
    expect(integer.value, BigInt.one);
    expect(float.value, 1.0);
  });

  test('VM rejects globals whose descriptor cannot be checked', () {
    final module = Module(hostGlobalFixture('i32_mutable').buffer);
    expect(
      () => Instance(module, {
        'host': {
          'tick': ImportExportKind.function((_) => null),
          'value': ImportExportKind.global(_ForeignGlobal()),
        },
      }),
      throwsA(
        isA<LinkError>().having(
          (e) => e.message,
          'message',
          contains('native backend'),
        ),
      ),
    );
  });

  for (final asyncHost in [false, true]) {
    test(
      'VM preserves host aliases, exported bindings and owned isolation async=$asyncHost',
      () async {
        final module = Module(hostGlobalFixture('alias').buffer);
        final shared = Global<Int32, int>(
          GlobalDescriptor<Int32, int>(value: ValueKind.i32, mutable: true),
          21,
        );
        final isolated = Global<Int32, int>(
          GlobalDescriptor<Int32, int>(value: ValueKind.i32, mutable: true),
          100,
        );
        final tick = asyncHost
            ? (List<Object?> _) async => null
            : (List<Object?> _) => null;
        Instance instance(Global global) => Instance(module, {
          'host': {
            'tick': ImportExportKind.function(tick),
            'first': ImportExportKind.global(global),
            'second': ImportExportKind.global(global),
          },
        });
        final first = instance(shared),
            second = instance(shared),
            third = instance(isolated);
        Future<Object?> call(
          Instance from,
          String name,
          List<Object?> args,
        ) async => (from.exports[name]! as FunctionImportExportValue).ref(args);
        await call(first, 'set', [42]);
        expect(shared.value, 42);
        expect(await call(second, 'get', []), 42);
        expect(await call(third, 'get', []), 100);
        final reexport = first.exports['second']! as GlobalImportExportValue;
        reexport.ref.value = 63;
        expect(shared.value, 63);
        expect(await call(second, 'get', []), 63);
        final fourth = Instance(module, {
          'host': {
            'tick': ImportExportKind.function(tick),
            'first': reexport,
            'second': reexport,
          },
        });
        await call(fourth, 'set', [84]);
        expect(shared.value, 84);
        await call(first, 'setOwned', [123]);
        expect(
          (first.exports['owned']! as GlobalImportExportValue).ref.value,
          123,
        );
        expect(
          (second.exports['owned']! as GlobalImportExportValue).ref.value,
          9,
        );
      },
    );
  }

  test('VM numeric import cannot satisfy an externref declaration', () {
    final module = Module(hostGlobalFixture('ref_import').buffer);
    final value = Global<Int32, int>(
      GlobalDescriptor<Int32, int>(value: ValueKind.i32),
      0,
    );
    expect(
      () => Instance(module, {
        'host': {'value': ImportExportKind.global(value)},
      }),
      throwsA(
        isA<LinkError>().having(
          (e) => e.message,
          'message',
          hasDartIoRuntime
              ? contains('incompatible import type')
              : contains('imported global does not match'),
        ),
      ),
    );
  });

  test('VM rejects mismatched global before data or start effects', () {
    final module = Module(hostGlobalFixture('start_effect').buffer);
    final memory = Memory(const MemoryDescriptor(initial: 1));
    var starts = 0;
    final wrong = Global<Float32, double>(
      GlobalDescriptor<Float32, double>(value: ValueKind.f32, mutable: true),
      0.0,
    );
    expect(
      () => Instance(module, {
        'host': {
          'value': ImportExportKind.global(wrong),
          'memory': ImportExportKind.memory(memory),
          'started': ImportExportKind.function((_) {
            starts++;
            return null;
          }),
        },
      }),
      throwsA(
        isA<LinkError>().having(
          (e) => e.message,
          'message',
          hasDartIoRuntime
              ? contains('incompatible import type')
              : contains('imported global does not match'),
        ),
      ),
    );
    expect(starts, 0);
    expect(memory.buffer.asUint8List()[0], 0);
  });
}

Object? _call(
  Instance instance,
  String name, [
  List<Object?> args = const [],
]) => (instance.exports[name]! as FunctionImportExportValue).ref(args);

Future<Object?> _callAsync(
  Instance instance,
  String name, [
  List<Object?> args = const [],
]) => Future<Object?>.sync(() => _call(instance, name, args));

Global _exportGlobal(Instance instance, [String name = 'value']) =>
    (instance.exports[name]! as GlobalImportExportValue).ref;

Global<ExternRef, Object?> _externGlobal(
  Object? value, {
  bool mutable = true,
}) => Global<ExternRef, Object?>(
  GlobalDescriptor<ExternRef, Object?>(
    value: ValueKind.externref,
    mutable: mutable,
  ),
  value,
);

Instance _referenceInstance(
  String fixture,
  Global global, {
  bool asyncHost = false,
}) => Instance(Module(hostGlobalFixture(fixture).buffer), {
  'host': {
    'tick': ImportExportKind.function(
      asyncHost ? (List<Object?> _) async => null : (List<Object?> _) => null,
    ),
    'value': ImportExportKind.global(global),
  },
});

void _referenceGlobalTests() {
  group('reference globals', () {
    test(
      'externref nullable host and guest mutations share exported storage',
      () {
        final value = _externGlobal(null);
        final first = _referenceInstance('externref_mutable', value);
        final second = _referenceInstance('externref_mutable', value);
        final exported = _exportGlobal(first);
        expect(value.value, isNull);
        expect(exported.value, isNull);
        expect(_call(first, 'get'), isNull);
        value.value = 'host';
        expect(_call(first, 'get'), 'host');
        expect(_call(second, 'get'), 'host');
        _call(first, 'set', [42]);
        expect(value.value, 42);
        expect(exported.value, 42);
        expect(_call(second, 'get'), 42);
        exported.value = false;
        expect(value.value, false);
        expect(_call(second, 'get'), false);
        _call(second, 'clear');
        expect(value.value, isNull);
        expect(exported.value, isNull);
      },
    );

    test('externref immutable imports and exports reject host mutation', () {
      final value = _externGlobal('constant', mutable: false);
      final instance = _referenceInstance('externref_immutable', value);
      final exported = _exportGlobal(instance);
      expect(_call(instance, 'get'), 'constant');
      expect(exported.value, 'constant');
      expect(() => value.value = null, throwsA(anything));
      expect(() => exported.value = null, throwsA(anything));
      expect(_call(instance, 'get'), 'constant');
      expect(exported.value, 'constant');
    });

    test(
      'externref incompatible imports fail before data and start effects',
      () {
        for (final wrong in <Global>[
          _externGlobal(null, mutable: false),
          _global(ValueKind.i32, true, 21),
        ]) {
          final memory = Memory(const MemoryDescriptor(initial: 1));
          var starts = 0;
          expect(
            () => Instance(
              Module(hostGlobalFixture('externref_start_effect').buffer),
              {
                'host': {
                  'value': ImportExportKind.global(wrong),
                  'memory': ImportExportKind.memory(memory),
                  'started': ImportExportKind.function((_) {
                    starts++;
                    return null;
                  }),
                },
              },
            ),
            throwsA(isA<LinkError>()),
          );
          expect(starts, 0);
          expect(memory.buffer.asUint8List()[0], 0);
        }
      },
    );

    test('externref reexported globals keep their shared backing', () {
      final value = _externGlobal('source');
      final first = _referenceInstance('externref_mutable', value);
      final exported = _exportGlobal(first);
      final second = _referenceInstance('externref_mutable', exported);
      _call(second, 'set', ['consumer']);
      expect(value.value, 'consumer');
      expect(exported.value, 'consumer');
      expect(_call(first, 'get'), 'consumer');
      exported.value = null;
      expect(_call(second, 'get'), isNull);
    });

    if (!hasDartIoRuntime) {
      test('JS funcref globals retain an explicit encoding limitation', () {
        expect(
          () => Global<FuncRef, Function?>(
            const GlobalDescriptor<FuncRef, Function?>(
              value: ValueKind.funcref,
              mutable: true,
            ),
            null,
          ),
          throwsA(
            isA<UnsupportedError>().having(
              (error) => error.message,
              'message',
              contains('funcref'),
            ),
          ),
        );
      });
      return;
    }

    for (final asyncHost in [false, true]) {
      test(
        'VM externref preserves arbitrary object identity async=$asyncHost',
        () async {
          final original = Object(), replacement = Object();
          final value = _externGlobal(original);
          final instance = _referenceInstance(
            'externref_mutable',
            value,
            asyncHost: asyncHost,
          );
          final exported = _exportGlobal(instance);
          expect(await _callAsync(instance, 'get'), same(original));
          expect(exported.value, same(original));
          await _callAsync(instance, 'set', [replacement]);
          expect(value.value, same(replacement));
          expect(exported.value, same(replacement));
          value.value = original;
          expect(await _callAsync(instance, 'get'), same(original));
          final values = <Object>[
            <Object>[],
            <String, Object>{},
            (List<Object?> _) => null,
            BigInt.parse('123456789012345678901234567890'),
            (value: Object()),
            _EqualExternal(),
            _EqualExternal(),
            -1,
            0,
            0x10000000,
            0x20000000,
            0x30000000,
            0x40000000,
          ];
          for (final payload in values) {
            await _callAsync(instance, 'set', [payload]);
            expect(value.value, same(payload));
            expect(await _callAsync(instance, 'get'), same(payload));
          }
          await _callAsync(instance, 'clear');
          expect(value.value, isNull);
          expect(exported.value, isNull);
        },
      );

      test(
        'VM externref aliases and reexports share storage without owned leakage async=$asyncHost',
        () async {
          final original = Object(), replacement = Object(), owned = Object();
          final shared = _externGlobal(original),
              isolated = _externGlobal(Object());
          final module = Module(hostGlobalFixture('externref_alias').buffer);
          final tick = asyncHost
              ? (List<Object?> _) async => null
              : (List<Object?> _) => null;
          Instance instance(Global global) => Instance(module, {
            'host': {
              'tick': ImportExportKind.function(tick),
              'first': ImportExportKind.global(global),
              'second': ImportExportKind.global(global),
            },
          });
          final first = instance(shared),
              second = instance(shared),
              third = instance(isolated);
          await _callAsync(first, 'set', [replacement]);
          expect(shared.value, same(replacement));
          expect(await _callAsync(second, 'get'), same(replacement));
          expect(await _callAsync(third, 'get'), same(isolated.value));
          final reexport = first.exports['second']! as GlobalImportExportValue;
          final fourth = Instance(module, {
            'host': {
              'tick': ImportExportKind.function(tick),
              'first': reexport,
              'second': reexport,
            },
          });
          reexport.ref.value = original;
          expect(await _callAsync(fourth, 'get'), same(original));
          await _callAsync(fourth, 'set', [replacement]);
          expect(shared.value, same(replacement));
          expect(_exportGlobal(first, 'first').value, same(replacement));
          await _callAsync(first, 'setOwned', [owned]);
          expect(_exportGlobal(first, 'owned').value, same(owned));
          expect(_exportGlobal(second, 'owned').value, isNull);
          expect(_exportGlobal(third, 'owned').value, isNull);
          expect(_exportGlobal(fourth, 'owned').value, isNull);
        },
      );
    }

    test('VM guest-owned externref exports can be mutated and reimported', () {
      final first = Instance(
        Module(hostGlobalFixture('externref_owned').buffer),
      );
      final second = Instance(
        Module(hostGlobalFixture('externref_owned').buffer),
      );
      final exported = _exportGlobal(first),
          original = Object(),
          replacement = Object();
      expect(exported.value, isNull);
      exported.value = original;
      expect(_call(first, 'get'), same(original));
      final consumer = _referenceInstance('externref_mutable', exported);
      _call(consumer, 'set', [replacement]);
      expect(exported.value, same(replacement));
      expect(_call(first, 'get'), same(replacement));
      expect(_exportGlobal(second).value, isNull);
    });

    for (final asyncHost in [false, true]) {
      test(
        'VM nullable funcref uses genuine cross-instance guest functions async=$asyncHost',
        () async {
          final source = Instance(
            Module(hostGlobalFixture('funcref_owned').buffer),
          );
          final increment =
              (source.exports['increment']! as FunctionImportExportValue).ref;
          final value = Global<FuncRef, Function?>(
            const GlobalDescriptor<FuncRef, Function?>(
              value: ValueKind.funcref,
              mutable: true,
            ),
            null,
          );
          final first = _referenceInstance(
            'funcref_mutable',
            value,
            asyncHost: asyncHost,
          );
          final second = _referenceInstance(
            'funcref_mutable',
            value,
            asyncHost: asyncHost,
          );
          final exported = _exportGlobal(first);
          expect(value.value, isNull);
          expect(await _callAsync(first, 'get'), isNull);
          value.value = increment;
          expect(await _callAsync(first, 'get'), same(increment));
          expect(exported.value, same(increment));
          expect(await _callAsync(first, 'call', [41]), 42);
          expect(await _callAsync(second, 'call', [9]), 10);
          expect(_call(source, 'calls'), 2);
          await _callAsync(first, 'clear');
          expect(value.value, isNull);
          expect(exported.value, isNull);
          await _callAsync(second, 'set', [increment]);
          expect(value.value, same(increment));
          expect(await _callAsync(first, 'call', [1]), 2);
          value.value = null;
          expect(await _callAsync(second, 'get'), isNull);
          expect(exported.value, isNull);
        },
      );
    }

    test(
      'VM mutable funcref globals await foreign async guest functions',
      () async {
        final synchronous = Instance(
          Module(hostGlobalFixture('funcref_owned').buffer),
        );
        final syncIncrement =
            (synchronous.exports['increment']! as FunctionImportExportValue)
                .ref;
        final events = <String>[];
        final asynchronous = Instance(
          Module(hostGlobalFixture('reference_host_callbacks').buffer),
          {
            'host': {
              'tick': ImportExportKind.function((List<Object?> _) async {
                events.add('entered');
                await Future<void>.value();
                events.add('settled');
                return null;
              }),
              'echo': ImportExportKind.function((args) => args.single),
              'fail': ImportExportKind.function((_) => null),
            },
          },
        );
        final asyncIncrement =
            (asynchronous.exports['increment']! as FunctionImportExportValue)
                .ref;
        final value = Global<FuncRef, Function?>(
          const GlobalDescriptor<FuncRef, Function?>(
            value: ValueKind.funcref,
            mutable: true,
          ),
          syncIncrement,
        );
        final consumer = _referenceInstance('funcref_mutable', value);
        expect(await _callAsync(consumer, 'get'), same(syncIncrement));
        expect(await _callAsync(consumer, 'call', [9]), 10);
        expect(_call(synchronous, 'calls'), 1);
        expect(await _callAsync(asynchronous, 'calls'), 0);
        value.value = asyncIncrement;
        expect(value.value, same(asyncIncrement));
        expect(await _callAsync(consumer, 'get'), same(asyncIncrement));
        expect(await _callAsync(consumer, 'call', [20]), 21);
        expect(events, ['entered', 'settled']);
        expect(await _callAsync(asynchronous, 'calls'), 1);
        value.value = syncIncrement;
        expect(await _callAsync(consumer, 'get'), same(syncIncrement));
        expect(await _callAsync(consumer, 'call', [30]), 31);
        expect(_call(synchronous, 'calls'), 2);
        expect(await _callAsync(asynchronous, 'calls'), 1);
        expect(events, ['entered', 'settled']);
      },
    );

    for (final route in ['global', 'import']) {
      test(
        'VM awaits a funcref replaced by a synchronous host callback during a call route=$route',
        () async {
          var settled = 0;
          final synchronous = Instance(
            Module(hostGlobalFixture('funcref_owned').buffer),
          );
          final asynchronous = Instance(
            Module(hostGlobalFixture('reference_host_callbacks').buffer),
            {
              'host': {
                'tick': ImportExportKind.function((List<Object?> _) async {
                  await Future<void>.delayed(Duration.zero);
                  settled++;
                  return null;
                }),
                'echo': ImportExportKind.function((args) => args.single),
                'fail': ImportExportKind.function((_) => null),
              },
            },
          );
          final function =
              (asynchronous.exports['increment']! as FunctionImportExportValue)
                  .ref;
          final value = Global<FuncRef, Function?>(
            const GlobalDescriptor<FuncRef, Function?>(
              value: ValueKind.funcref,
              mutable: true,
            ),
            (synchronous.exports['increment']! as FunctionImportExportValue)
                .ref,
          );
          Object? tick(List<Object?> _) {
            value.value = function;
            return null;
          }

          final relay = Instance(
            Module(hostGlobalFixture('reference_relay').buffer),
            {
              'host': {'value': ImportExportKind.global(value)},
            },
          );
          final consumer = route == 'global'
              ? Instance(Module(hostGlobalFixture('funcref_mutable').buffer), {
                  'host': {
                    'value': ImportExportKind.global(value),
                    'tick': ImportExportKind.function(tick),
                  },
                })
              : Instance(
                  Module(hostGlobalFixture('reference_import_mutation').buffer),
                  {
                    'host': {
                      'relay':
                          relay.exports['call']! as FunctionImportExportValue,
                      'tick': ImportExportKind.function(tick),
                    },
                  },
                );
          expect(await _callAsync(consumer, 'call', [41]), 42);
          expect(settled, 1);
          expect(value.value, same(function));
          expect(_call(synchronous, 'calls'), 0);
        },
      );
    }

    for (final duringStart in [false, true]) {
      test(
        'VM async funcref remains callable after table copy and global clear start=$duringStart',
        () async {
          var ticks = 0;
          final source = Instance(
            Module(hostGlobalFixture('reference_host_callbacks').buffer),
            {
              'host': {
                'tick': ImportExportKind.function((List<Object?> _) async {
                  await Future<void>.delayed(Duration.zero);
                  ticks++;
                  return null;
                }),
                'echo': ImportExportKind.function((args) => args.single),
                'fail': ImportExportKind.function((_) => null),
              },
            },
          );
          final value = Global<FuncRef, Function?>(
            const GlobalDescriptor<FuncRef, Function?>(
              value: ValueKind.funcref,
              mutable: true,
            ),
            (source.exports['increment']! as FunctionImportExportValue).ref,
          );
          final consumer = Instance(
            Module(
              hostGlobalFixture(
                duringStart
                    ? 'reference_table_async_start'
                    : 'reference_table_async',
              ).buffer,
            ),
            {
              'host': {'value': ImportExportKind.global(value)},
            },
          );
          if (!duringStart) await _callAsync(consumer, 'stash');
          expect(value.value, isNull);
          expect(ticks, 0);
          expect(await _callAsync(consumer, 'call', [41]), 42);
          expect(ticks, 1);
          expect(value.value, isNull);
          expect(await _callAsync(source, 'calls'), 1);
        },
      );
    }

    for (final privateStash in [false, true]) {
      for (final ownAsync in [false, true]) {
        test(
          'VM funcref parameters survive table storage private=$privateStash ownAsync=$ownAsync',
          () async {
            var ticks = 0;
            final source = Instance(
              Module(hostGlobalFixture('reference_host_callbacks').buffer),
              {
                'host': {
                  'tick': ImportExportKind.function((List<Object?> _) async {
                    await Future<void>.delayed(Duration.zero);
                    ticks++;
                    return null;
                  }),
                  'echo': ImportExportKind.function((args) => args.single),
                  'fail': ImportExportKind.function((_) => null),
                },
              },
            );
            final function =
                (source.exports['increment']! as FunctionImportExportValue).ref;
            final consumer = Instance(
              Module(
                hostGlobalFixture(
                  ownAsync
                      ? 'reference_parameter_own_async'
                      : 'reference_parameter_async',
                ).buffer,
              ),
              {
                if (ownAsync)
                  'host': {
                    'tick': ImportExportKind.function(
                      (List<Object?> _) async => null,
                    ),
                  },
              },
            );
            if (privateStash) {
              final stash =
                  (consumer.exports['reference']! as GlobalImportExportValue)
                          .ref
                          .value
                      as WasmFunction;
              await Future<Object?>.sync(() => stash([function]));
            } else {
              await _callAsync(consumer, 'stash', [function]);
            }
            expect(ticks, 0);
            expect(await _callAsync(consumer, 'call', [41]), 42);
            expect(ticks, 1);
          },
        );
      }
    }

    for (final route in ['getter', 'host result']) {
      test(
        'VM async function ingress remains awaitable through $route',
        () async {
          var ticks = 0;
          final source = Instance(
            Module(hostGlobalFixture('reference_host_callbacks').buffer),
            {
              'host': {
                'tick': ImportExportKind.function((List<Object?> _) async {
                  await Future<void>.delayed(Duration.zero);
                  ticks++;
                  return null;
                }),
                'echo': ImportExportKind.function((args) => args.single),
                'fail': ImportExportKind.function((_) => null),
              },
            },
          );
          final function =
              (source.exports['increment']! as FunctionImportExportValue).ref;
          final consumer = Instance(
            Module(
              hostGlobalFixture(
                route == 'getter'
                    ? 'reference_parameter_getter'
                    : 'reference_host_function_result',
              ).buffer,
            ),
            {
              if (route == 'host result')
                'host': {'provide': ImportExportKind.function((_) => function)},
            },
          );
          if (route == 'getter') {
            final stash = _call(consumer, 'reference') as WasmFunction;
            await Future<Object?>.sync(() => stash([function]));
          } else {
            await _callAsync(consumer, 'stash');
          }
          expect(ticks, 0);
          expect(await _callAsync(consumer, 'call', [41]), 42);
          expect(ticks, 1);
          if (route == 'host result') {
            expect(await _callAsync(consumer, 'direct', [41]), 42);
            expect(ticks, 2);
            final hidden =
                (consumer.exports['reference']! as GlobalImportExportValue)
                        .ref
                        .value
                    as WasmFunction;
            expect(await Future<Object?>.sync(() => hidden([41])), 42);
            expect(ticks, 3);
          }
        },
      );
    }

    for (final route in ['parameter', 'start', 'function import']) {
      test(
        'VM stored functions observe a source becoming asynchronous route=$route',
        () async {
          var ticks = 0;
          final synchronous = Instance(
            Module(hostGlobalFixture('funcref_owned').buffer),
          );
          final asynchronous = Instance(
            Module(hostGlobalFixture('reference_host_callbacks').buffer),
            {
              'host': {
                'tick': ImportExportKind.function((List<Object?> _) async {
                  await Future<void>.delayed(Duration.zero);
                  ticks++;
                  return null;
                }),
                'echo': ImportExportKind.function((args) => args.single),
                'fail': ImportExportKind.function((_) => null),
              },
            },
          );
          final value = Global<FuncRef, Function?>(
            const GlobalDescriptor<FuncRef, Function?>(
              value: ValueKind.funcref,
              mutable: true,
            ),
            (synchronous.exports['increment']! as FunctionImportExportValue)
                .ref,
          );
          final relay = Instance(
            Module(hostGlobalFixture('reference_relay').buffer),
            {
              'host': {'value': ImportExportKind.global(value)},
            },
          );
          final relayFunction =
              (relay.exports['call']! as FunctionImportExportValue).ref;
          final copied = Global<FuncRef, Function?>(
            const GlobalDescriptor<FuncRef, Function?>(
              value: ValueKind.funcref,
              mutable: true,
            ),
            relayFunction,
          );
          final consumer = route == 'start'
              ? Instance(
                  Module(
                    hostGlobalFixture('reference_table_async_start').buffer,
                  ),
                  {
                    'host': {'value': ImportExportKind.global(copied)},
                  },
                )
              : route == 'function import'
              ? Instance(
                  Module(hostGlobalFixture('reference_import_call').buffer),
                  {
                    'host': {'relay': ImportExportKind.function(relayFunction)},
                  },
                )
              : Instance(
                  Module(hostGlobalFixture('reference_parameter_async').buffer),
                );
          if (route == 'start') {
            expect(copied.value, isNull);
          } else if (route == 'parameter') {
            expect(
              _call(consumer, 'stash', [relayFunction]),
              isNot(isA<Future>()),
            );
          }
          expect(_call(consumer, 'call', [41]), 42);
          value.value =
              (asynchronous.exports['increment']! as FunctionImportExportValue)
                  .ref;
          expect(await _callAsync(consumer, 'call', [41]), 42);
          expect(ticks, 1);
        },
      );
    }

    test(
      'VM imported guest ref.func globals preserve the originating function',
      () async {
        final source = Instance(
          Module(hostGlobalFixture('funcref_owned').buffer),
        );
        final function =
            (source.exports['increment']! as FunctionImportExportValue).ref;
        final module = Module(
          hostGlobalFixture('reference_import_alias').buffer,
        );
        final alias = Instance(module, {
          'host': {'f': ImportExportKind.function(function)},
        });
        final global =
            (alias.exports['reference']! as GlobalImportExportValue).ref;
        expect(global.value, same(function));
        expect(
          (alias.exports['direct']! as FunctionImportExportValue).ref,
          same(function),
        );
        expect(await _callAsync(alias, 'get'), same(function));
        final rebound = Instance(module, {
          'host': {
            'f': ImportExportKind.function(global.value as WasmFunction),
          },
        });
        expect(
          (rebound.exports['reference']! as GlobalImportExportValue).ref.value,
          same(function),
        );
        expect(await _callAsync(rebound, 'call', [41]), 42);
      },
    );

    test('VM imported guest function types reject before start', () {
      final source = Instance(
        Module(hostGlobalFixture('funcref_owned').buffer),
      );
      final function =
          (source.exports['increment']! as FunctionImportExportValue).ref;
      var starts = 0;
      expect(
        () => Instance(
          Module(hostGlobalFixture('reference_import_signature').buffer),
          {
            'host': {
              'f': ImportExportKind.function(function),
              'started': ImportExportKind.function((_) {
                starts++;
                return null;
              }),
            },
          },
        ),
        throwsA(isA<LinkError>()),
      );
      expect(starts, 0);
    });

    test(
      'VM synchronous guest function imports remain callable from start',
      () {
        final source = Instance(
          Module(hostGlobalFixture('funcref_owned').buffer),
        );
        final function =
            (source.exports['increment']! as FunctionImportExportValue).ref;
        final instance = Instance(
          Module(hostGlobalFixture('reference_import_start').buffer),
          {
            'host': {'relay': ImportExportKind.function(function)},
          },
        );
        expect(_call(source, 'calls'), 1);
        expect(_call(instance, 'call', [41]), 42);
        expect(_call(source, 'calls'), 2);
      },
    );

    test(
      'VM unsupported private function rejects before guest side effects',
      () {
        final instance = Instance(
          Module(hostGlobalFixture('reference_hidden_signature').buffer),
        );
        final hidden =
            (instance.exports['reference']! as GlobalImportExportValue)
                    .ref
                    .value
                as WasmFunction;
        expect(() => hidden([]), throwsUnsupportedError);
        expect(
          (instance.exports['calls']! as GlobalImportExportValue).ref.value,
          0,
        );
      },
    );

    test(
      'VM reference host callbacks preserve externref argument and result identity',
      () {
        final input = Object(), replacement = Object();
        Object? seen, result = replacement;
        final instance = Instance(
          Module(hostGlobalFixture('reference_host_callbacks').buffer),
          {
            'host': {
              'tick': ImportExportKind.function((_) => null),
              'echo': ImportExportKind.function((args) {
                expect(args, hasLength(1));
                seen = args.single;
                return result;
              }),
              'fail': ImportExportKind.function((_) => null),
            },
          },
        );
        expect(_call(instance, 'roundtrip', [input]), same(replacement));
        expect(seen, same(input));
        result = null;
        expect(_call(instance, 'roundtrip', [null]), isNull);
        expect(seen, isNull);
      },
    );

    test('VM reference host callbacks preserve the original host error', () {
      final failure = StateError('host callback sentinel');
      Object? fail(List<Object?> _) => throw failure;
      final instance = Instance(
        Module(hostGlobalFixture('reference_host_callbacks').buffer),
        {
          'host': {
            'tick': ImportExportKind.function((_) => null),
            'echo': ImportExportKind.function((args) => args.single),
            'fail': ImportExportKind.function(fail),
          },
        },
      );
      expect(() => _call(instance, 'fail'), throwsA(same(failure)));
    });
    test(
      'VM guest funcref globals reexport identity and enforce indirect signatures',
      () {
        final source = Instance(
          Module(hostGlobalFixture('funcref_owned').buffer),
        );
        final increment =
            (source.exports['increment']! as FunctionImportExportValue).ref;
        final wrong =
            (source.exports['wrong']! as FunctionImportExportValue).ref;
        final exported = _exportGlobal(source);
        expect(exported.value, same(increment));
        expect(_call(source, 'get'), same(increment));
        expect((exported.value as WasmFunction)([9]), 10);
        final first = _referenceInstance('reference_relay', exported);
        final second = _referenceInstance(
          'reference_relay',
          _exportGlobal(first),
        );
        expect(_call(first, 'call', [21]), 22);
        expect(_call(second, 'call', [31]), 32);
        _call(source, 'setWrong');
        expect(exported.value, same(wrong));
        final calls = _call(source, 'calls');
        expect(
          () => _call(first, 'call', [1]),
          throwsA(
            isA<Object>().having(
              (error) => error.toString(),
              'trap',
              contains('call_indirect signature mismatch trap'),
            ),
          ),
        );
        expect(_call(source, 'calls'), calls);
        exported.value = increment;
        expect(_call(second, 'call', [41]), 42);
        _call(first, 'clear');
        expect(exported.value, isNull);
        expect(_call(source, 'get'), isNull);
        expect(
          () => _call(second, 'call', [1]),
          throwsA(
            isA<Object>().having(
              (error) => error.toString(),
              'trap',
              contains('call_indirect to null table element'),
            ),
          ),
        );
      },
    );

    test('VM immutable funcref imports and exports reject mutation', () {
      final source = Instance(
        Module(hostGlobalFixture('funcref_owned').buffer),
      );
      final increment =
          (source.exports['increment']! as FunctionImportExportValue).ref;
      final value = Global<FuncRef, Function?>(
        const GlobalDescriptor<FuncRef, Function?>(value: ValueKind.funcref),
        increment,
      );
      final instance = _referenceInstance('funcref_immutable', value);
      expect(_call(instance, 'get'), same(increment));
      expect(_call(instance, 'call', [5]), 6);
      expect(() => value.value = null, throwsStateError);
      expect(() => _exportGlobal(instance).value = null, throwsStateError);
      final immutable = _exportGlobal(source, 'immutable');
      expect(() => immutable.value = null, throwsStateError);
      final reimport = _referenceInstance('funcref_immutable', immutable);
      expect(_call(reimport, 'call', [8]), 9);
      expect(immutable.value, same(increment));
    });

    test('VM ordinary Dart closures cannot forge guest funcref provenance', () {
      final source = Instance(
        Module(hostGlobalFixture('funcref_owned').buffer),
      );
      final increment =
          (source.exports['increment']! as FunctionImportExportValue).ref;
      Object? fake(List<Object?> args) => args.length;
      final standalone = Global<FuncRef, Function?>(
        const GlobalDescriptor<FuncRef, Function?>(
          value: ValueKind.funcref,
          mutable: true,
        ),
        fake,
      );
      expect(
        () => _referenceInstance('reference_relay', standalone),
        throwsA(isA<LinkError>()),
      );
      expect(standalone.value, same(fake));
      final value = Global<FuncRef, Function?>(
        const GlobalDescriptor<FuncRef, Function?>(
          value: ValueKind.funcref,
          mutable: true,
        ),
        increment,
      );
      final instance = _referenceInstance('reference_relay', value);
      expect(
        () => value.value = fake,
        throwsA(
          anyOf(
            isA<ArgumentError>(),
            isA<UnsupportedError>(),
            isA<StateError>(),
          ),
        ),
      );
      expect(value.value, same(increment));
      expect(_call(instance, 'call', [10]), 11);
      final exported = _exportGlobal(source);
      expect(
        () => exported.value = fake,
        throwsA(
          anyOf(
            isA<ArgumentError>(),
            isA<UnsupportedError>(),
            isA<StateError>(),
          ),
        ),
      );
      expect(exported.value, same(increment));
    });

    test(
      'VM funcref mismatches and untrusted closures fail before instantiation effects',
      () {
        final source = Instance(
          Module(hostGlobalFixture('funcref_owned').buffer),
        );
        final increment =
            (source.exports['increment']! as FunctionImportExportValue).ref;
        for (final wrong in <Global>[
          _externGlobal(null),
          _global(ValueKind.i32, true, 0),
          Global<FuncRef, Function?>(
            const GlobalDescriptor<FuncRef, Function?>(
              value: ValueKind.funcref,
            ),
            increment,
          ),
          Global<FuncRef, Function?>(
            const GlobalDescriptor<FuncRef, Function?>(
              value: ValueKind.funcref,
              mutable: true,
            ),
            (List<Object?> args) => args.length,
          ),
        ]) {
          final memory = Memory(const MemoryDescriptor(initial: 1));
          var starts = 0;
          expect(
            () => Instance(
              Module(hostGlobalFixture('funcref_start_effect').buffer),
              {
                'host': {
                  'value': ImportExportKind.global(wrong),
                  'memory': ImportExportKind.memory(memory),
                  'started': ImportExportKind.function((_) {
                    starts++;
                    return null;
                  }),
                },
              },
            ),
            throwsA(isA<LinkError>()),
          );
          expect(starts, 0);
          expect(memory.buffer.asUint8List()[0], 0);
        }
      },
    );

    for (final kind in ['externref', 'funcref']) {
      for (final guestImport in [false, true]) {
        test(
          'VM duplicate $kind imports accept equivalent nullable encodings guest=$guestImport',
          () async {
            final instance = Instance(
              Module(hostGlobalFixture('reference_equivalent_$kind').buffer),
              {
                'host': {
                  'echo': ImportExportKind.function((args) => args.single),
                },
              },
            );
            final consumer = guestImport
                ? Instance(
                    Module(
                      hostGlobalFixture('reference_equivalent_$kind').buffer,
                    ),
                    {
                      'host': {
                        'echo':
                            instance.exports['run']!
                                as FunctionImportExportValue,
                      },
                    },
                  )
                : instance;
            final source = Instance(
              Module(hostGlobalFixture('funcref_owned').buffer),
            );
            final Object value = kind == 'externref'
                ? Object()
                : (source.exports['increment']! as FunctionImportExportValue)
                      .ref;
            expect(await _callAsync(consumer, 'run', [value]), same(value));
            expect(await _callAsync(consumer, 'run', [null]), isNull);
          },
        );
      }
    }

    test(
      'VM conflicting reference function imports fail before data or start effects',
      () {
        final memory = Memory(const MemoryDescriptor(initial: 1));
        var starts = 0;
        expect(
          () => Instance(
            Module(hostGlobalFixture('reference_duplicate_imports').buffer),
            {
              'host': {
                'f': ImportExportKind.function((args) => args.single),
                'memory': ImportExportKind.memory(memory),
                'started': ImportExportKind.function((_) {
                  starts++;
                  return null;
                }),
              },
            },
          ),
          throwsA(
            isA<LinkError>().having(
              (error) => error.toString(),
              'reason',
              contains('matching signatures'),
            ),
          ),
        );
        expect(starts, 0);
        expect(memory.buffer.asUint8List()[0], 0);
      },
    );

    test(
      'VM unused unsupported function signatures do not block numeric exports',
      () {
        final instance = Instance(
          Module(hostGlobalFixture('reference_unsupported_function').buffer),
        );
        expect(_call(instance, 'answer'), 42);
        expect(
          () => _call(instance, 'unused', [Object()]),
          throwsUnsupportedError,
        );
      },
    );

    test(
      'VM unsupported nonnullable typed exports fail before data or start effects',
      () {
        final memory = Memory(const MemoryDescriptor(initial: 1));
        var starts = 0;
        expect(
          () => Instance(
            Module(hostGlobalFixture('funcref_nonnullable_effect').buffer),
            {
              'host': {
                'memory': ImportExportKind.memory(memory),
                'started': ImportExportKind.function((_) {
                  starts++;
                  return null;
                }),
              },
            },
          ),
          throwsA(isA<LinkError>()),
        );
        expect(starts, 0);
        expect(memory.buffer.asUint8List()[0], 0);
      },
    );
  });
}

class _ForeignGlobal implements Global<Int32, int> {
  @override
  int value = 0;
}

class _EqualExternal {
  @override
  bool operator ==(Object other) => other is _EqualExternal;

  @override
  int get hashCode => 0;
}
