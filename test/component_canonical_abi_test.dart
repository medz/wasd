import 'package:test/test.dart';
import 'package:wasd/wasd.dart';

void main() {
  group('WasmCanonicalAbi', () {
    test('lowers and lifts mixed scalar/string values', () {
      final memory = WasmMemory(minPages: 1);
      final allocator = WasmCanonicalAbiAllocator(cursor: 32);
      final types = <WasmCanonicalAbiType>[
        WasmCanonicalAbiType.s32,
        WasmCanonicalAbiType.boolI32,
        WasmCanonicalAbiType.stringUtf8,
        WasmCanonicalAbiType.u64,
        WasmCanonicalAbiType.f64,
      ];
      final values = <Object?>[
        -1,
        true,
        'wasd',
        BigInt.parse('18446744073709551615'),
        3.5,
      ];

      final flat = WasmCanonicalAbi.lowerValues(
        types: types,
        values: values,
        memory: memory,
        allocator: allocator,
      );
      final lifted = WasmCanonicalAbi.liftValues(
        types: types,
        flatValues: flat,
        memory: memory,
      );

      expect(lifted[0], -1);
      expect(lifted[1], isTrue);
      expect(lifted[2], 'wasd');
      expect(lifted[3], BigInt.parse('18446744073709551615'));
      expect(lifted[4], 3.5);
    });

    test('writes UTF-8 strings into linear memory', () {
      final memory = WasmMemory(minPages: 1);
      final allocator = WasmCanonicalAbiAllocator(cursor: 0);
      final flat = WasmCanonicalAbi.lowerValues(
        types: const [WasmCanonicalAbiType.stringUtf8],
        values: const ['hello'],
        memory: memory,
        allocator: allocator,
      );

      final pointer = flat[0] as int;
      final length = flat[1] as int;
      expect(length, 5);
      expect(memory.readBytes(pointer, length), 'hello'.codeUnits);
      expect(allocator.cursor, pointer + length);
    });

    test('rejects flat arity mismatch on lift', () {
      final memory = WasmMemory(minPages: 1);
      expect(
        () => WasmCanonicalAbi.liftValues(
          types: const [WasmCanonicalAbiType.s32, WasmCanonicalAbiType.s32],
          flatValues: const [1],
          memory: memory,
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
