import 'dart:typed_data';

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

    test('lowers and lifts bytes through pointer-length ABI pair', () {
      final memory = WasmMemory(minPages: 1);
      final allocator = WasmCanonicalAbiAllocator(cursor: 64);
      final payload = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);

      final flat = WasmCanonicalAbi.lowerValues(
        types: const [WasmCanonicalAbiType.bytes],
        values: [payload],
        memory: memory,
        allocator: allocator,
      );
      expect(flat, hasLength(2));

      final lifted = WasmCanonicalAbi.liftValues(
        types: const [WasmCanonicalAbiType.bytes],
        flatValues: flat,
        memory: memory,
      );
      expect(lifted.single, isA<Uint8List>());
      expect((lifted.single as Uint8List), orderedEquals(payload));
    });

    test('lowers and lifts canonical list values', () {
      final memory = WasmMemory(minPages: 1);
      final allocator = WasmCanonicalAbiAllocator(cursor: 0);
      final listType = WasmCanonicalAbiType.list(WasmCanonicalAbiType.u32);

      final flat = WasmCanonicalAbi.lowerValues(
        types: [listType],
        values: const [
          [1, 2, 3, 4],
        ],
        memory: memory,
        allocator: allocator,
      );
      final lifted = WasmCanonicalAbi.liftValues(
        types: [listType],
        flatValues: flat,
        memory: memory,
      );

      expect(lifted.single, orderedEquals([1, 2, 3, 4]));
    });

    test('lowers and lifts canonical records', () {
      final memory = WasmMemory(minPages: 1);
      final allocator = WasmCanonicalAbiAllocator(cursor: 32);
      final recordType = WasmCanonicalAbiType.record([
        const WasmCanonicalAbiRecordField(
          name: 'id',
          type: WasmCanonicalAbiType.u32,
        ),
        const WasmCanonicalAbiRecordField(
          name: 'name',
          type: WasmCanonicalAbiType.stringUtf8,
        ),
      ]);

      final flat = WasmCanonicalAbi.lowerValues(
        types: [recordType],
        values: const [
          {'id': 7, 'name': 'wasd'},
        ],
        memory: memory,
        allocator: allocator,
      );
      final lifted = WasmCanonicalAbi.liftValues(
        types: [recordType],
        flatValues: flat,
        memory: memory,
      );

      expect(lifted.single, equals(<String, Object?>{'id': 7, 'name': 'wasd'}));
    });

    test('lowers and lifts canonical variants', () {
      final memory = WasmMemory(minPages: 1);
      final allocator = WasmCanonicalAbiAllocator(cursor: 16);
      final variantType = WasmCanonicalAbiType.variant([
        const WasmCanonicalAbiVariantCase(name: 'none'),
        const WasmCanonicalAbiVariantCase(
          name: 'some',
          payloadType: WasmCanonicalAbiType.s32,
        ),
      ]);

      final flat = WasmCanonicalAbi.lowerValues(
        types: [variantType],
        values: const [
          WasmCanonicalAbiVariantValue(caseName: 'some', payload: -9),
        ],
        memory: memory,
        allocator: allocator,
      );
      final lifted = WasmCanonicalAbi.liftValues(
        types: [variantType],
        flatValues: flat,
        memory: memory,
      );

      expect(
        lifted.single,
        const WasmCanonicalAbiVariantValue(caseName: 'some', payload: -9),
      );
    });

    test('lowers and lifts canonical result values', () {
      final memory = WasmMemory(minPages: 1);
      final allocator = WasmCanonicalAbiAllocator(cursor: 24);
      final resultType = WasmCanonicalAbiType.result(
        ok: WasmCanonicalAbiType.u32,
        error: WasmCanonicalAbiType.stringUtf8,
      );

      final okFlat = WasmCanonicalAbi.lowerValues(
        types: [resultType],
        values: [WasmCanonicalAbiResultValue.ok(11)],
        memory: memory,
        allocator: allocator,
      );
      final okLifted = WasmCanonicalAbi.liftValues(
        types: [resultType],
        flatValues: okFlat,
        memory: memory,
      );
      expect(okLifted.single, WasmCanonicalAbiResultValue.ok(11));

      final errorFlat = WasmCanonicalAbi.lowerValues(
        types: [resultType],
        values: [WasmCanonicalAbiResultValue.error('boom')],
        memory: memory,
        allocator: allocator,
      );
      final errorLifted = WasmCanonicalAbi.liftValues(
        types: [resultType],
        flatValues: errorFlat,
        memory: memory,
      );
      expect(errorLifted.single, WasmCanonicalAbiResultValue.error('boom'));
    });

    test('lowers and lifts resource handles', () {
      final memory = WasmMemory(minPages: 1);
      final allocator = WasmCanonicalAbiAllocator(cursor: 0);
      final resourceType = WasmCanonicalAbiType.resource(name: 'file');

      final flat = WasmCanonicalAbi.lowerValues(
        types: [resourceType],
        values: const [WasmCanonicalAbiResourceHandle(42)],
        memory: memory,
        allocator: allocator,
      );
      expect(flat.single, 42);

      final lifted = WasmCanonicalAbi.liftValues(
        types: [resourceType],
        flatValues: flat,
        memory: memory,
      );
      expect(lifted.single, const WasmCanonicalAbiResourceHandle(42));
    });
  });
}
