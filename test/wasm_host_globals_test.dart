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

  test('VM rejects an unsupported reference host kind explicitly', () {
    final module = Module(hostGlobalFixture('ref_import').buffer);
    final value = Global<ExternRef, Object?>(
      const GlobalDescriptor<ExternRef, Object?>(value: ValueKind.externref),
      null,
    );
    expect(
      () => Instance(module, {
        'host': {'value': ImportExportKind.global(value)},
      }),
      throwsA(
        isA<LinkError>().having(
          (e) => e.message,
          'message',
          contains('numeric kinds only'),
        ),
      ),
    );
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

class _ForeignGlobal implements Global<Int32, int> {
  @override
  int value = 0;
}
