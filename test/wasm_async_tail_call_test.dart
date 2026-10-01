@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/features.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/instance.dart';

void main() {
  test('async tail calls discard the caller exception handlers', () async {
    final instance = WasmInstance.fromBytes(
      File('test/fixtures/async_tail_call.wasm').readAsBytesSync(),
      features: const WasmFeatureSet(exceptionHandling: true, gc: true),
    );
    expect(await instance.invokeAsyncForced('call'), 99);
    for (final name in ['tail', 'tail-ref', 'tail-indirect']) {
      await expectLater(
        instance.invokeAsyncForced(name),
        throwsA(
          predicate<Object>(
            (error) =>
                error.runtimeType.toString() == '_AsyncSubsetThrownException',
          ),
        ),
        reason: '$name must not return the caller catch result',
      );
    }
  });
}
