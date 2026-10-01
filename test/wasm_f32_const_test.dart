@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/features.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/instance.dart';

void main() {
  const patterns = [
    0x7f800001, // Positive signaling NaN.
    0xff812345, // Negative signaling NaN with payload.
    0x7fc12345, // Positive quiet NaN with payload.
    0xffc54321, // Negative quiet NaN with payload.
    0x80000000, // Negative zero.
    0x00000001, // Smallest positive subnormal.
    0x3f800001, // Finite value above one.
    0x7f800000, // Positive infinity.
    0xff800000, // Negative infinity.
  ];

  for (final forceAsync in [false, true]) {
    Future<Object?> invoke(
      WasmInstance instance,
      String name, [
      List<Object?> args = const [],
    ]) async => forceAsync
        ? instance.invokeAsyncForced(name, args)
        : instance.invoke(name, args);

    group(forceAsync ? 'forced async f32 constants' : 'f32 constants', () {
      late WasmInstance instance;
      setUp(() {
        instance = WasmInstance.fromBytes(
          File('test/fixtures/f32_const_bits.wasm').readAsBytesSync(),
        );
      });

      for (final path in ['global', 'direct']) {
        test('$path preserves raw f32 bits without GC', () async {
          for (var i = 0; i < patterns.length; i++) {
            final value = await invoke(instance, '$path-$i') as int;
            expect(value.toUnsigned(32), patterns[i], reason: 'pattern $i');
          }
        });
      }

      test(
        'global and direct f64 signaling NaN controls preserve bits',
        () async {
          for (final path in ['global', 'direct']) {
            final value = await invoke(instance, '$path-f64');
            final bits = value is BigInt ? value : BigInt.from(value as int);
            expect(
              bits.toUnsigned(64),
              BigInt.parse('7ff0000000000001', radix: 16),
            );
          }
        },
      );
    });

    group(
      forceAsync ? 'forced async GC f32 constants' : 'GC f32 constants',
      () {
        for (final path in [
          'global-struct',
          'global-array',
          'global-fixed',
          'active-array',
          'passive-array',
        ]) {
          test('$path preserves raw f32 field bits', () async {
            final isElement = path == 'active-array' || path == 'passive-array';
            final fixture = isElement
                ? 'gc_f32_element_bits'
                : 'gc_f32_const_bits';
            final instance = WasmInstance.fromBytes(
              File('test/fixtures/$fixture.wasm').readAsBytesSync(),
              features: const WasmFeatureSet(gc: true),
            );
            for (var i = 0; i < patterns.length; i++) {
              final value =
                  await invoke(
                        instance,
                        isElement ? path : '$path-$i',
                        isElement ? [i] : [],
                      )
                      as int;
              expect(value.toUnsigned(32), patterns[i], reason: 'pattern $i');
            }
          });
        }
      },
    );
  }
}
