@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/features.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/instance.dart';

void main() {
  const patterns = [
    '7ff0000000000001', // Positive signaling NaN.
    'fff0123456789abc', // Negative signaling NaN with payload.
    '7ff8123456789abc', // Positive quiet NaN with payload.
    'fff8fedcba987654', // Negative quiet NaN with payload.
    '8000000000000000', // Negative zero.
    '0000000000000001', // Smallest positive subnormal.
    '3ff0000000000001', // Finite value above one.
    '7ff0000000000000', // Positive infinity.
    'fff0000000000000', // Negative infinity.
  ];
  final expected = patterns
      .map((bits) => BigInt.parse(bits, radix: 16))
      .toList();
  BigInt unsignedBits(Object? value) =>
      (value is BigInt ? value : BigInt.from(value as int)).toUnsigned(64);

  for (final forceAsync in [false, true]) {
    Future<Object?> invoke(
      WasmInstance instance,
      String name, [
      List<Object?> args = const [],
    ]) async => forceAsync
        ? instance.invokeAsyncForced(name, args)
        : instance.invoke(name, args);

    group(forceAsync ? 'forced async f64 constants' : 'f64 constants', () {
      for (final path in [
        'global',
        'direct',
        'global-struct',
        'global-array',
        'global-fixed',
        'active-array',
        'passive-array',
        'copy-array',
        'set-array',
      ]) {
        test('$path preserves raw f64 bits', () async {
          final isCore = path == 'global' || path == 'direct';
          final isElement = [
            'active-array',
            'passive-array',
            'copy-array',
            'set-array',
          ].contains(path);
          final fixture = isCore
              ? 'f64_const_bits'
              : isElement
              ? 'gc_f64_element_bits'
              : 'gc_f64_const_bits';
          final instance = WasmInstance.fromBytes(
            File('test/fixtures/$fixture.wasm').readAsBytesSync(),
            features: WasmFeatureSet(gc: !isCore),
          );
          for (var i = 0; i < expected.length; i++) {
            final value = await invoke(
              instance,
              isElement ? path : '$path-$i',
              isElement ? [i] : [],
            );
            expect(unsignedBits(value), expected[i], reason: 'pattern $i');
          }
        });
      }
    });

    group(
      forceAsync ? 'forced async f64 data controls' : 'f64 data controls',
      () {
        for (final operation in ['new', 'init', 'copy', 'set']) {
          test('$operation preserves raw f64 data and field bits', () async {
            final instance = WasmInstance.fromBytes(
              File('test/fixtures/gc_array_f64.wasm').readAsBytesSync(),
              features: const WasmFeatureSet(gc: true),
            );
            for (var i = 0; i < expected.length; i++) {
              final value = await invoke(instance, '$operation-f64', [
                1 + i * 8,
              ]);
              expect(unsignedBits(value), expected[i], reason: 'pattern $i');
              if (operation != 'new') {
                expect(
                  unsignedBits(await invoke(instance, 'get-f64', [0])),
                  BigInt.parse('3ff0000000000000', radix: 16),
                );
                expect(
                  unsignedBits(await invoke(instance, 'get-f64', [2])),
                  BigInt.parse('3ff0000000000000', radix: 16),
                );
              }
            }
          });
        }
      },
    );
  }
}
