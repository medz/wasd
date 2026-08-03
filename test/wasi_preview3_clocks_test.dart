import 'dart:async';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/preview3/clocks.dart';

void main() {
  test('wait-until is synchronously ready for a past mark', () {
    final host = WASIPreview3ClocksHost();
    final waitUntil =
        host.imports['wasi:clocks/monotonic-clock@0.3.0.wait-until']!;

    expect(waitUntil(<Object?>[BigInt.zero]), isNot(isA<Future<void>>()));
  });
}
