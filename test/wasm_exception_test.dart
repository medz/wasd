import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasm/host_control_flow.dart';
import 'package:wasd/wasm.dart';

import 'support/host_exception_fixtures.dart';
import 'support/host_tag_fixtures.dart';
import 'support/runtime_environment.dart';

const _mixedKinds = <ValueKind>[
  ValueKind.i32,
  ValueKind.i64,
  ValueKind.f32,
  ValueKind.f64,
];

Module _module(String name, {bool exceptionFixture = false}) => Module(
  (exceptionFixture ? hostExceptionFixture(name) : hostTagFixture(name)).buffer,
  features: hasDartIoRuntime ? {CoreFeature.exceptionHandling} : {},
);

Tag _tag(Instance instance, [String name = 'tag']) =>
    (instance.exports[name]! as TagImportExportValue).ref;

WasmFunction _function(Instance instance, String name) =>
    (instance.exports[name]! as FunctionImportExportValue).ref;

WasmFunction _tick(bool asyncHost) =>
    asyncHost ? (List<Object?> _) async => null : (List<Object?> _) => null;

Object? _normalize(Object? value) => switch (value) {
  BigInt() => value.toInt(),
  List() => value.map(_normalize).toList(),
  _ => value,
};

// Preserve explicit encodings for metadata compatibility controls. Current
// backends also accept padded abstract heap types, which pinned wasm-tools
// rejects; those cases do not establish valid frozen Core input coverage.
Uint8List _explicitRefTagBytes(
  int heapType, {
  bool padded = false,
  bool nullable = true,
}) => Uint8List.fromList([
  0x00,
  0x61,
  0x73,
  0x6d,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  padded ? 0x07 : 0x06,
  0x01,
  0x60,
  0x01,
  nullable ? 0x63 : 0x64,
  if (padded) ...[heapType | 0x80, 0x7f] else heapType,
  0x00,
  0x0d,
  0x03,
  0x01,
  0x00,
  0x00,
  0x07,
  0x05,
  0x01,
  0x01,
  0x74,
  0x04,
  0x00,
]);

void _expectExportedPayloadTypes(Instance instance) {
  for (final entry in <String, List<ValueKind>>{
    'empty': [],
    'i32': [ValueKind.i32],
    'i64': [ValueKind.i64],
    'f32': [ValueKind.f32],
    'f64': [ValueKind.f64],
    'mixed': _mixedKinds,
  }.entries) {
    expect(_tag(instance, entry.key).type().parameters, entry.value);
  }
}

Future<Exception> _thrownBy(Object? Function() action) async {
  try {
    await Future<Object?>.sync(action);
  } on Exception catch (error) {
    return error;
  }
  fail('Expected a public WebAssembly Exception.');
}

void main() {
  _referencePayloadTests();

  for (final heapType in [0x6f, 0x70]) {
    final label = heapType == 0x6f ? 'externref' : 'funcref';
    for (final padded in [false, true]) {
      test('explicit nullable $label tag padded=$padded', () {
        final bytes = _explicitRefTagBytes(heapType, padded: padded);
        final module = Module(
          bytes.buffer,
          features: hasDartIoRuntime ? {CoreFeature.exceptionHandling} : {},
        );
        final tag = _tag(Instance(module), 't');
        final parameters = tag.type().parameters;
        expect(parameters, hasLength(1));
        expect(parameters.single.name, label);
        if (heapType == 0x6f || hasDartIoRuntime) {
          for (final payload in [null, if (heapType == 0x6f) 'payload']) {
            final error = Exception(tag, [payload]);
            expect(error.isTag(tag), isTrue);
            expect(error.getArg(tag, 0), payload);
          }
        }
      });
    }

    test('nonnullable $label tag binding fails explicitly', () {
      final bytes = _explicitRefTagBytes(heapType, nullable: false);
      final module = Module(
        bytes.buffer,
        features: hasDartIoRuntime ? {CoreFeature.exceptionHandling} : {},
      );
      if (hasDartIoRuntime) {
        expect(() => Instance(module), throwsA(isA<LinkError>()));
      } else {
        final tag = _tag(Instance(module), 't');
        expect(tag.type, throwsUnsupportedError);
      }
    });
  }

  if (!hasDartIoRuntime) {
    test('JS host funcref tag returns independent parameter snapshots', () {
      final parameters = List<ValueKind>.generate(1, (_) => ValueKind.funcref);
      final tag = Tag(TagDescriptor(parameters: parameters));
      parameters.clear();
      final snapshot = tag.type().parameters;
      expect(snapshot.single.name, 'funcref');
      snapshot.clear();
      expect(tag.type().parameters.single.name, 'funcref');
    });

    test(
      'JS sync module snapshots exported tag metadata before source changes',
      () {
        final bytes = hostTagFixture('exported_payloads');
        final module = Module(bytes.buffer);
        bytes.fillRange(0, bytes.length, 0);
        _expectExportedPayloadTypes(Instance(module));
      },
    );

    test(
      'JS compile snapshots exported tag metadata before awaiting',
      () async {
        final bytes = hostTagFixture('exported_payloads');
        final pending = WebAssembly.compile(bytes.buffer);
        bytes.fillRange(0, bytes.length, 0);
        _expectExportedPayloadTypes(Instance(await pending));
      },
    );

    test(
      'JS instantiate snapshots exported tag metadata before awaiting',
      () async {
        final bytes = hostTagFixture('exported_payloads');
        final pending = WebAssembly.instantiate(bytes.buffer);
        bytes.fillRange(0, bytes.length, 0);
        _expectExportedPayloadTypes((await pending).instance);
      },
    );

    test(
      'JS compileStreaming retains tag metadata across one-byte chunks',
      () async {
        final bytes = hostTagFixture('exported_payloads');
        final module = await WebAssembly.compileStreaming(
          Stream.fromIterable(bytes.map((byte) => [byte])),
        );
        _expectExportedPayloadTypes(Instance(module));
      },
    );

    test(
      'JS instantiateStreaming retains tag metadata across one-byte chunks',
      () async {
        final bytes = hostTagFixture('exported_payloads');
        final result = await WebAssembly.instantiateStreaming(
          Stream.fromIterable(bytes.map((byte) => [byte])),
        );
        _expectExportedPayloadTypes(result.instance);
      },
    );
  }

  test('tag and exception constructors snapshot their input lists', () {
    final parameters = <ValueKind>[..._mixedKinds];
    final tag = Tag(TagDescriptor(parameters: parameters));
    parameters.clear();
    expect(tag.type().parameters, _mixedKinds);
    final returned = tag.type().parameters;
    returned.clear();
    expect(tag.type().parameters, _mixedKinds);
    final payload = <Object?>[7, BigInt.from(8), 1.25, 2.5];
    final error = Exception(
      tag,
      payload,
      const ExceptionOptions(traceStack: true),
    );
    payload.fillRange(0, payload.length, null);
    expect(error.isTag(tag), isTrue);
    expect(
      [for (var i = 0; i < _mixedKinds.length; i++) error.getArg(tag, i)],
      [7, BigInt.from(8), 1.25, 2.5],
    );
  });

  test('empty payload, arity, tag identity, and index checks', () {
    final empty = Tag(const TagDescriptor(parameters: []));
    final error = Exception(empty, []);
    final other = Tag(const TagDescriptor(parameters: []));
    expect(error.isTag(empty), isTrue);
    expect(error.isTag(other), isFalse);
    expect(
      error.isTag(Tag(const TagDescriptor(parameters: [ValueKind.externref]))),
      isFalse,
    );
    expect(() => error.getArg(other, 0), throwsA(anything));
    expect(() => error.getArg(empty, -1), throwsA(anything));
    expect(() => error.getArg(empty, 0), throwsA(anything));
    expect(() => Exception(empty, [1]), throwsArgumentError);
    final tag = Tag(const TagDescriptor(parameters: [ValueKind.i32]));
    expect(() => Exception(tag, []), throwsArgumentError);
    expect(() => Exception(tag, [1, 2]), throwsArgumentError);
    final single = Exception(tag, [1]);
    expect(() => single.getArg(tag, -1), throwsA(anything));
    expect(() => single.getArg(tag, 1), throwsA(anything));
  });

  for (final entry in <ValueKind, List<Object?>>{
    ValueKind.i32: [null, '1', 1.5, BigInt.one],
    ValueKind.i64: [null, '1', 1, 1.5],
    ValueKind.f32: [null, '1', BigInt.one, if (hasDartIoRuntime) 1],
    ValueKind.f64: [null, '1', BigInt.one, if (hasDartIoRuntime) 1],
  }.entries) {
    test('${entry.key.name} rejects wrong public payload types', () {
      final tag = Tag(TagDescriptor(parameters: [entry.key]));
      for (final value in entry.value) {
        expect(() => Exception(tag, [value]), throwsA(isA<TypeError>()));
      }
    });
  }

  test('numeric payloads normalize widths and keep i64 as BigInt', () {
    final tag = Tag(const TagDescriptor(parameters: _mixedKinds));
    final error = Exception(tag, [
      0x100000001,
      (BigInt.one << 64) + BigInt.from(3),
      1.337,
      -0.0,
    ]);
    expect(error.getArg(tag, 0), 1);
    expect(error.getArg(tag, 1), BigInt.from(3));
    expect(error.getArg(tag, 1), isA<BigInt>());
    expect(error.getArg(tag, 2), 1.3370000123977661);
    expect(1 / (error.getArg(tag, 3)! as double), double.negativeInfinity);
    final f32 = Tag(const TagDescriptor(parameters: [ValueKind.f32]));
    final negativeZero = Exception(f32, [-0.0]);
    expect(
      1 / (negativeZero.getArg(f32, 0)! as double),
      double.negativeInfinity,
    );
    final i32 = Tag(const TagDescriptor(parameters: [ValueKind.i32]));
    expect(Exception(i32, [0xffffffff]).getArg(i32, 0), -1);
    final i64 = Tag(const TagDescriptor(parameters: [ValueKind.i64]));
    expect(
      Exception(i64, [(BigInt.one << 64) - BigInt.one]).getArg(i64, 0),
      -BigInt.one,
    );
  });

  for (final asyncHost in [false, true]) {
    for (final entry in <String, List<ValueKind>>{
      'empty': [],
      'mixed': _mixedKinds,
    }.entries) {
      test(
        'host public ${entry.key} exception is caught async=$asyncHost',
        () async {
          final tag = Tag(TagDescriptor(parameters: entry.value));
          final payload = entry.value.isEmpty
              ? <Object?>[]
              : <Object?>[
                  37,
                  BigInt.parse('123456789abcdef', radix: 16),
                  1.25,
                  2.5,
                ];
          final error = Exception(tag, payload);
          final WasmFunction tick = asyncHost
              ? (List<Object?> _) async => throw error
              : (List<Object?> _) => throw error;
          final instance = Instance(_module(entry.key), {
            'host': {
              'tick': ImportExportKind.function(tick),
              'tag': ImportExportKind.tag(tag),
            },
          });
          final result = await Future<Object?>.sync(
            () => _function(instance, 'catch')(payload),
          );
          expect(
            _normalize(result),
            payload.isEmpty ? null : _normalize(payload),
          );
        },
      );
    }

    test(
      'host exception with independent tag escapes typed catch async=$asyncHost',
      () async {
        final expected = Tag(const TagDescriptor(parameters: [ValueKind.i32]));
        final actual = Tag(const TagDescriptor(parameters: [ValueKind.i32]));
        final error = Exception(actual, [23]);
        final WasmFunction tick = asyncHost
            ? (List<Object?> _) async => throw error
            : (List<Object?> _) => throw error;
        final instance = Instance(_module('i32'), {
          'host': {
            'tick': ImportExportKind.function(tick),
            'tag': ImportExportKind.tag(expected),
          },
        });
        final escaped = await _thrownBy(
          () => _function(instance, 'catch')([1]),
        );
        expect(escaped, same(error));
        expect(escaped.isTag(expected), isFalse);
        expect(escaped.isTag(actual), isTrue);
        expect(escaped.getArg(actual, 0), 23);
      },
    );

    test(
      'guest uncaught mixed exception exposes payload and alias async=$asyncHost',
      () async {
        final instance = Instance(
          _module('mixed_throw', exceptionFixture: true),
          {
            'host': {'tick': ImportExportKind.function(_tick(asyncHost))},
          },
        );
        final tag = _tag(instance);
        final alias = _tag(instance, 'alias');
        expect(tag.type().parameters, _mixedKinds);
        final payload = <Object?>[37, BigInt.from(41), 1.25, -0.0];
        final escaped = await _thrownBy(
          () => _function(instance, 'throw')(payload),
        );
        expect(escaped.isTag(tag), isTrue);
        expect(escaped.isTag(alias), isTrue);
        expect(
          escaped.isTag(Tag(const TagDescriptor(parameters: _mixedKinds))),
          isFalse,
        );
        expect([
          for (var i = 0; i < payload.length; i++) escaped.getArg(tag, i),
        ], payload);
        expect(escaped.getArg(tag, 1), isA<BigInt>());
        expect(
          1 / (escaped.getArg(tag, 3)! as double),
          double.negativeInfinity,
        );
      },
    );
  }

  for (final calleeAsync in [false, true]) {
    for (final catcherAsync in [false, true]) {
      test(
        'Dart rethrows guest exception across instances $calleeAsync/$catcherAsync',
        () async {
          final provider = Instance(_module('provider'), {
            'host': {'tick': ImportExportKind.function(_tick(calleeAsync))},
          });
          final tag = _tag(provider);
          final escaped = await _thrownBy(
            () => _function(provider, 'throw')([73]),
          );
          final WasmFunction source = catcherAsync
              ? (List<Object?> _) async => throw escaped
              : (List<Object?> _) => throw escaped;
          final receiver = Instance(_module('consumer'), {
            'host': {
              'tick': ImportExportKind.function(_tick(catcherAsync)),
              'source': ImportExportKind.function(source),
              'tag': ImportExportKind.tag(tag),
            },
          });
          expect(escaped.isTag(_tag(receiver)), isTrue);
          expect(escaped.getArg(_tag(receiver), 0), 73);
          expect(
            await Future<Object?>.sync(() => _function(receiver, 'catch')([0])),
            73,
          );
          final mismatch = Instance(_module('consumer'), {
            'host': {
              'tick': ImportExportKind.function(_tick(catcherAsync)),
              'source': ImportExportKind.function(source),
              'tag': ImportExportKind.tag(
                Tag(const TagDescriptor(parameters: [ValueKind.i32])),
              ),
            },
          });
          final rethrown = await _thrownBy(
            () => _function(mismatch, 'catch')([0]),
          );
          expect(rethrown, same(escaped));
        },
      );

      test(
        'catch_ref carrier retains f32 NaN bits after Dart read/rethrow $calleeAsync/$catcherAsync',
        () async {
          final tag = Tag(const TagDescriptor(parameters: [ValueKind.f32]));
          Instance instance(bool asyncHost, WasmFunction source) =>
              Instance(_module('f32_bits', exceptionFixture: true), {
                'host': {
                  'tick': ImportExportKind.function(_tick(asyncHost)),
                  'source': ImportExportKind.function(source),
                  'tag': ImportExportKind.tag(tag),
                },
              });
          final provider = instance(calleeAsync, (List<Object?> _) => null);
          final escaped = await _thrownBy(
            () => _function(provider, 'throw')([]),
          );
          expect(escaped.getArg(tag, 0), isNaN);
          final WasmFunction source = catcherAsync
              ? (List<Object?> _) async => throw escaped
              : (List<Object?> _) => throw escaped;
          final receiver = instance(catcherAsync, source);
          expect(
            await Future<Object?>.sync(
              () => _function(receiver, 'catch_bits')([]),
            ),
            0x7fc12345,
          );
        },
      );
    }
  }

  test(
    'host start exception retains identity through every entrypoint',
    () async {
      final tag = Tag(const TagDescriptor(parameters: [ValueKind.i32]));
      final error = Exception(tag, [43]);
      final imports = {
        'host': {
          'tick': ImportExportKind.function((List<Object?> _) => throw error),
        },
      };
      final bytes = hostExceptionFixture('host_start');
      final module = Module(bytes.buffer);
      for (final instantiate in <Object? Function()>[
        () => Instance(module, imports),
        () => WebAssembly.instantiateModule(module, imports),
        () => WebAssembly.instantiate(bytes.buffer, imports),
        () => WebAssembly.instantiateStreaming(Stream.value(bytes), imports),
      ]) {
        final escaped = await _thrownBy(instantiate);
        expect(escaped, same(error));
        expect(escaped.isTag(tag), isTrue);
        expect(escaped.getArg(tag, 0), 43);
      }
    },
  );

  if (hasDartIoRuntime) {
    for (final asyncHost in [false, true]) {
      test(
        'exception bridge retains the host stack async=$asyncHost',
        () async {
          final expected = Tag(
            const TagDescriptor(parameters: [ValueKind.i32]),
          );
          final actual = Tag(const TagDescriptor(parameters: [ValueKind.i32]));
          final error = Exception(actual, [23]);
          final stack = StackTrace.fromString('host-exception-stack-marker');
          Never throwWithStack() => Error.throwWithStackTrace(error, stack);
          final WasmFunction tick = asyncHost
              ? (List<Object?> _) async => throwWithStack()
              : (List<Object?> _) => throwWithStack();
          final instance = Instance(_module('i32'), {
            'host': {
              'tick': ImportExportKind.function(tick),
              'tag': ImportExportKind.tag(expected),
            },
          });
          try {
            await Future<Object?>.sync(() => _function(instance, 'catch')([0]));
            fail('Expected an uncaught exception.');
          } on Exception catch (escaped, stackTrace) {
            expect(escaped.isTag(actual), isTrue);
            expect('$stackTrace', contains('host-exception-stack-marker'));
          }
        },
      );
    }
  }

  test(
    'uncaught start exception is public rather than a link failure',
    () async {
      final tag = Tag(const TagDescriptor(parameters: [ValueKind.i32]));
      final imports = {
        'host': {'tag': ImportExportKind.tag(tag)},
      };
      final module = _module('start', exceptionFixture: true);
      final syncError = await _thrownBy(() => Instance(module, imports));
      expect(syncError.isTag(tag), isTrue);
      expect(syncError.getArg(tag, 0), 19);
      final asyncError = await _thrownBy(
        () => WebAssembly.instantiateModule(module, imports),
      );
      expect(asyncError.isTag(tag), isTrue);
      expect(asyncError.getArg(tag, 0), 19);
    },
  );

  for (final asyncHost in [false, true]) {
    test(
      'ordinary host failures stay outside Wasm exception matching async=$asyncHost',
      () async {
        final marker = StateError('ordinary-host-marker');
        final WasmFunction tick = asyncHost
            ? (List<Object?> _) async => throw marker
            : (List<Object?> _) => throw marker;
        final instance = Instance(_module('empty'), {
          'host': {
            'tick': ImportExportKind.function(tick),
            'tag': ImportExportKind.tag(
              Tag(const TagDescriptor(parameters: [])),
            ),
          },
        });
        await expectLater(
          Future<Object?>.sync(() => _function(instance, 'catch')([])),
          throwsA(
            allOf(
              isNot(isA<Exception>()),
              predicate(
                (Object error) => '$error'.contains('ordinary-host-marker'),
              ),
            ),
          ),
        );
      },
    );

    test('host control flow keeps its identity async=$asyncHost', () async {
      final marker = _HostControlFlow();
      final WasmFunction tick = asyncHost
          ? (List<Object?> _) async => throw marker
          : (List<Object?> _) => throw marker;
      final instance = Instance(_module('empty'), {
        'host': {
          'tick': ImportExportKind.function(tick),
          'tag': ImportExportKind.tag(Tag(const TagDescriptor(parameters: []))),
        },
      });
      await expectLater(
        Future<Object?>.sync(() => _function(instance, 'catch')([])),
        throwsA(same(marker)),
      );
    });
  }
}

void _referencePayloadTests() {
  Instance provider(bool asyncHost) =>
      Instance(_module('reference_provider', exceptionFixture: true), {
        'host': {'tick': ImportExportKind.function(_tick(asyncHost))},
      });

  Instance receiver(String fixture, Tag tag, Exception error, bool asyncHost) =>
      Instance(_module(fixture, exceptionFixture: true), {
        'host': {
          'tag': ImportExportKind.tag(tag),
          'source': ImportExportKind.function(
            asyncHost
                ? (List<Object?> _) async => throw error
                : (List<Object?> _) => throw error,
          ),
        },
      });

  test('externref exception preserves nullable primitive payloads', () {
    final tag = Tag(const TagDescriptor(parameters: [ValueKind.externref]));
    final other = Tag(const TagDescriptor(parameters: [ValueKind.externref]));
    for (final payload in <Object?>[
      null,
      'payload',
      17,
      1.25,
      false,
      if (hasDartIoRuntime) BigInt.one << 80,
    ]) {
      final values = [payload];
      final error = Exception(tag, values);
      values.clear();
      expect(error.isTag(tag), isTrue);
      expect(error.isTag(other), isFalse);
      expect(error.getArg(tag, 0), payload);
      expect(() => error.getArg(other, 0), throwsA(anything));
      expect(() => error.getArg(tag, -1), throwsA(anything));
      expect(() => error.getArg(tag, 1), throwsA(anything));
    }
    expect(() => Exception(tag, []), throwsArgumentError);
    expect(() => Exception(tag, [null, null]), throwsArgumentError);
  });

  for (final calleeAsync in [false, true]) {
    for (final catcherAsync in [false, true]) {
      test(
        'externref exception survives guest Dart guest $calleeAsync/$catcherAsync',
        () async {
          final source = provider(calleeAsync);
          final tag = _tag(source, 'extern');
          final alias = _tag(source, 'extern_alias');
          expect(tag.type().parameters, [ValueKind.externref]);
          for (final payload in <Object?>[
            null,
            'roundtrip',
            if (hasDartIoRuntime) BigInt.one << 80,
          ]) {
            final error = await _thrownBy(
              () => _function(source, 'throw_extern')([payload]),
            );
            expect(error.isTag(tag), isTrue);
            expect(error.isTag(alias), isTrue);
            expect(error.getArg(alias, 0), payload);
            final target = receiver(
              'externref_consumer',
              tag,
              error,
              catcherAsync,
            );
            expect(error.isTag(_tag(target)), isTrue);
            expect(
              await Future<Object?>.sync(() => _function(target, 'catch')([])),
              payload,
            );
            final mismatch = receiver(
              'externref_consumer',
              Tag(const TagDescriptor(parameters: [ValueKind.externref])),
              error,
              catcherAsync,
            );
            expect(
              await _thrownBy(() => _function(mismatch, 'catch')([])),
              same(error),
            );
          }
        },
      );
    }
  }

  for (final asyncHost in [false, true]) {
    test(
      'mixed numeric reference exception keeps payload order async=$asyncHost',
      () async {
        final source = provider(asyncHost);
        final tag = _tag(source, 'mixed');
        expect(tag.type().parameters, [
          ValueKind.i32,
          ValueKind.externref,
          ValueKind.f64,
        ]);
        final error = await _thrownBy(
          () => _function(source, 'throw_mixed')([37, 'middle', -0.0]),
        );
        expect(error.getArg(tag, 0), 37);
        expect(error.getArg(tag, 1), 'middle');
        expect(1 / (error.getArg(tag, 2)! as double), double.negativeInfinity);
        final target = receiver(
          'mixed_reference_consumer',
          tag,
          error,
          asyncHost,
        );
        final result =
            await Future<Object?>.sync(() => _function(target, 'catch')([]))
                as List;
        expect(result, [37, 'middle', -0.0]);
        expect(1 / (result[2] as double), double.negativeInfinity);
      },
    );
  }

  if (!hasDartIoRuntime) {
    test('JS externref BigInt readback stays an opaque JS value', () async {
      final value = BigInt.one << 80;
      final hostTag = Tag(
        const TagDescriptor(parameters: [ValueKind.externref]),
      );
      final hostError = Exception(hostTag, [value]);
      final hostReadback = hostError.getArg(hostTag, 0);
      expect(hostReadback, isNot(isA<BigInt>()));
      expect(hostReadback.toString(), value.toString());
      final source = provider(false);
      final tag = _tag(source, 'extern');
      final error = await _thrownBy(
        () => _function(source, 'throw_extern')([value]),
      );
      expect(error.getArg(tag, 0).toString(), value.toString());
      final target = receiver('externref_consumer', tag, error, false);
      expect(
        await Future<Object?>.sync(() => _function(target, 'catch')([])),
        value,
      );
    });
    test('JS funcref exception retains explicit codec limitations', () async {
      final tag = Tag(const TagDescriptor(parameters: [ValueKind.funcref]));
      expect(() => Exception(tag, [null]), throwsUnsupportedError);
      final source = provider(false);
      final error = await _thrownBy(
        () => _function(source, 'throw_null_function')([]),
      );
      expect(error.isTag(_tag(source, 'function')), isTrue);
      expect(
        () => error.getArg(_tag(source, 'function'), 0),
        throwsUnsupportedError,
      );
    });
    test('JS v128 exception retains an explicit encoding limitation', () {
      final tag = Tag(const TagDescriptor(parameters: [ValueKind.v128]));
      expect(() => Exception(tag, [ByteData(16)]), throwsUnsupportedError);
    });
    return;
  }

  for (final asyncHost in [false, true]) {
    test(
      'VM private unsupported reference exception stays opaque async=$asyncHost',
      () async {
        late Exception original;
        final WasmFunction source = asyncHost
            ? (List<Object?> _) async => throw original
            : (List<Object?> _) => throw original;
        Instance instance() =>
            Instance(_module('private_reference', exceptionFixture: true), {
              'host': {
                'tick': ImportExportKind.function(_tick(asyncHost)),
                'source': ImportExportKind.function(source),
              },
            });
        final owner = instance();
        original = await _thrownBy(() => _function(owner, 'throw')([]));
        expect(
          await Future<Object?>.sync(
            () => _function(owner, 'catch_is_null')([]),
          ),
          1,
        );
        expect(
          await _thrownBy(() => _function(owner, 'relay')([])),
          same(original),
        );
        final mismatch = instance();
        expect(
          await _thrownBy(() => _function(mismatch, 'catch_is_null')([])),
          same(original),
        );
      },
    );

    test(
      'VM externref exception retains arbitrary Dart values async=$asyncHost',
      () async {
        final source = provider(asyncHost);
        final tag = _tag(source, 'extern');
        final marker = Object();
        final values = <Object?>[
          marker,
          <Object?>[marker],
          (List<Object?> _) => marker,
          (marker, 'record'),
        ];
        for (final payload in values) {
          final hostError = Exception(tag, [payload]);
          expect(
            hostError.getArg(tag, 0),
            payload is Record ? equals(payload) : same(payload),
          );
          final error = await _thrownBy(
            () => _function(source, 'throw_extern')([payload]),
          );
          final direct = error.getArg(tag, 0);
          expect(direct, payload is Record ? equals(payload) : same(payload));
          final target = receiver('externref_consumer', tag, error, asyncHost);
          final result = await Future<Object?>.sync(
            () => _function(target, 'catch')([]),
          );
          expect(result, payload is Record ? equals(payload) : same(payload));
          if (result is (Object, String)) expect(result.$1, same(marker));
        }
      },
    );

    test(
      'VM funcref exception preserves null and genuine functions async=$asyncHost',
      () async {
        final source = provider(asyncHost);
        final tag = _tag(source, 'function');
        final function = _function(source, 'increment');
        for (final payload in <Object?>[null, function]) {
          final host = Exception(tag, [payload]);
          expect(host.getArg(tag, 0), same(payload));
          final guest = await _thrownBy(
            () => _function(source, 'throw_function')([payload]),
          );
          expect(guest.getArg(tag, 0), same(payload));
          if (payload != null) {
            final target = receiver('funcref_consumer', tag, guest, asyncHost);
            expect(
              await Future<Object?>.sync(
                () => _function(target, 'catch_call')([41]),
              ),
              42,
            );
          }
        }
        for (final invalid in <Object?>[0, Object(), (List<Object?> _) => 1]) {
          expect(() => Exception(tag, [invalid]), throwsArgumentError);
        }
        for (final uncallable in <Object?>[null, _function(source, 'wrong')]) {
          final error = Exception(tag, [uncallable]);
          expect(error.getArg(tag, 0), same(uncallable));
          final target = receiver('funcref_consumer', tag, error, asyncHost);
          await expectLater(
            Future<Object?>.sync(() => _function(target, 'catch_call')([41])),
            throwsA(
              allOf(
                isNot(isA<Exception>()),
                predicate<Object>(
                  (error) => '$error'.contains('call_indirect'),
                ),
              ),
            ),
          );
        }
      },
    );
  }

  test(
    'VM funcref exception owns a guest function after its entrypoint',
    () async {
      Future<(Tag, Exception)> escape() async {
        final source = provider(false);
        return (
          _tag(source, 'function'),
          await _thrownBy(() => _function(source, 'throw_own_function')([])),
        );
      }

      final (tag, error) = await escape();
      final function = error.getArg(tag, 0)! as WasmFunction;
      expect(await Future<Object?>.sync(() => function([41])), 42);
      final target = receiver('funcref_consumer', tag, error, false);
      expect(
        await Future<Object?>.sync(() => _function(target, 'catch_call')([9])),
        10,
      );
    },
  );

  test(
    'VM decoded funcref translates its reference exception payload',
    () async {
      final source = provider(false);
      final functionTag = _tag(source, 'function');
      final carrier = await _thrownBy(
        () => _function(source, 'throw_own_thrower')([]),
      );
      final thrower = carrier.getArg(functionTag, 0)! as WasmFunction;
      final payload = Object();
      final error = await _thrownBy(() => thrower([payload]));
      final tag = _tag(source, 'extern');
      expect(error.getArg(tag, 0), same(payload));
      final target = receiver('externref_consumer', tag, error, false);
      expect(
        await Future<Object?>.sync(() => _function(target, 'catch')([])),
        same(payload),
      );
    },
  );

  test(
    'VM sync host exception awaits foreign async funcref without callback replay',
    () async {
      var callbacks = 0, entered = 0, settled = 0;
      final source = Instance(
        _module('reference_provider', exceptionFixture: true),
        {
          'host': {
            'tick': ImportExportKind.function((List<Object?> _) async {
              entered++;
              await Future<void>.value();
              settled++;
              return null;
            }),
          },
        },
      );
      final tag = Tag(const TagDescriptor(parameters: [ValueKind.funcref]));
      final error = Exception(tag, [_function(source, 'increment')]);
      final target = Instance(
        _module('funcref_consumer', exceptionFixture: true),
        {
          'host': {
            'tag': ImportExportKind.tag(tag),
            'source': ImportExportKind.function((List<Object?> _) {
              callbacks++;
              throw error;
            }),
          },
        },
      );
      expect(
        await Future<Object?>.sync(() => _function(target, 'catch_call')([41])),
        42,
      );
      expect(callbacks, 1);
      expect(entered, 1);
      expect(settled, 1);
    },
  );
}

final class _HostControlFlow implements WasmHostControlFlowException {}
