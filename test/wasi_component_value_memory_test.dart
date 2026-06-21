import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/value_memory.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/memory.dart';

void main() {
  group('WASIComponentCanonicalValueMemoryCodec', () {
    test('loads and stores record fields with canonical padding', () {
      final codec = WASIComponentCanonicalValueMemoryCodec.fromValueType(
        const WasmComponentValueType.typeIndex(0),
        [
          const WasmComponentTypeDefinition(
            kind: WasmComponentTypeKind.definedValue,
            definedValue: WasmComponentDefinedValueType(
              kind: WasmComponentDefinedValueTypeKind.record,
              fields: [
                WasmComponentLabeledValueType(
                  label: 'a',
                  type: WasmComponentValueType.primitive(
                    WasmComponentPrimitiveValueType.u32,
                  ),
                ),
                WasmComponentLabeledValueType(
                  label: 'b',
                  type: WasmComponentValueType.primitive(
                    WasmComponentPrimitiveValueType.u16,
                  ),
                ),
              ],
            ),
          ),
        ],
      )!;
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 55, Endian.little);
      data.setUint16(36, 13, Endian.little);

      final value = codec.load(memory, 32);

      expect(codec.byteLength, 8);
      expect(codec.alignment, 4);
      expect(value, isA<WasmComponentValueData>());
      final record = value! as WasmComponentValueData;
      expect(record.kind, WasmComponentValueDataKind.record);
      expect(record.items.map((item) => item.integer), [55, 13]);

      codec.store(memory, 96, record);
      expect(data.getUint32(96, Endian.little), 55);
      expect(data.getUint16(100, Endian.little), 13);
    });

    test('loads typed primitive batches', () {
      final codec = WASIComponentCanonicalValueMemoryCodec.fromValueType(
        const WasmComponentValueType.primitive(
          WasmComponentPrimitiveValueType.u32,
        ),
        const <WasmComponentTypeDefinition>[],
      )!;
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 7, Endian.little);
      data.setUint32(36, 8, Endian.little);
      data.setUint32(40, 9, Endian.little);

      expect(codec.loadManyAs<int>(memory, 32, 3, 'items'), [7, 8, 9]);
      expect(
        () => codec.loadManyAs<String>(memory, 32, 1, 'items'),
        throwsStateError,
      );
    });

    test('packs flags through the smallest canonical integer width', () {
      final codec = WASIComponentCanonicalValueMemoryCodec.fromValueType(
        const WasmComponentValueType.typeIndex(0),
        [
          const WasmComponentTypeDefinition(
            kind: WasmComponentTypeKind.definedValue,
            definedValue: WasmComponentDefinedValueType(
              kind: WasmComponentDefinedValueTypeKind.flags,
              labels: ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i'],
            ),
          ),
        ],
      )!;
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      final value = WasmComponentValueData(
        kind: WasmComponentValueDataKind.flags,
        rawBytes: Uint8List(0),
        labels: ['a', 'i'],
      );

      codec.store(memory, 32, value);
      final loaded = codec.load(memory, 32) as WasmComponentValueData;

      expect(codec.byteLength, 2);
      expect(codec.alignment, 2);
      expect(data.getUint16(32, Endian.little), 0x101);
      expect(loaded.labels, ['a', 'i']);
    });

    test('loads and stores variants with aligned payloads', () {
      final codec = WASIComponentCanonicalValueMemoryCodec.fromValueType(
        const WasmComponentValueType.typeIndex(0),
        [
          const WasmComponentTypeDefinition(
            kind: WasmComponentTypeKind.definedValue,
            definedValue: WasmComponentDefinedValueType(
              kind: WasmComponentDefinedValueTypeKind.variant,
              cases: [
                WasmComponentVariantCase(label: 'empty'),
                WasmComponentVariantCase(
                  label: 'number',
                  type: WasmComponentValueType.primitive(
                    WasmComponentPrimitiveValueType.u64,
                  ),
                ),
              ],
            ),
          ),
        ],
      )!;
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      final value = WasmComponentValueData(
        kind: WasmComponentValueDataKind.variant,
        rawBytes: Uint8List(0),
        index: 1,
        label: 'number',
        associatedValue: WasmComponentValueData(
          kind: WasmComponentValueDataKind.integer,
          rawBytes: Uint8List(0),
          integer: 0x0102030405060708,
        ),
      );

      codec.store(memory, 32, value);
      final loaded = codec.load(memory, 32) as WasmComponentValueData;

      expect(codec.byteLength, 16);
      expect(codec.alignment, 8);
      expect(data.getUint8(32), 1);
      expect(data.getUint64(40, Endian.little), 0x0102030405060708);
      expect(loaded.index, 1);
      expect(loaded.label, 'number');
      expect(loaded.associatedValue!.integer, 0x0102030405060708);
    });

    test('loads and stores lists of fixed-size elements through realloc', () {
      final codec = WASIComponentCanonicalValueMemoryCodec.fromValueType(
        const WasmComponentValueType.typeIndex(0),
        [
          const WasmComponentTypeDefinition(
            kind: WasmComponentTypeKind.definedValue,
            definedValue: WasmComponentDefinedValueType(
              kind: WasmComponentDefinedValueTypeKind.list,
              elementType: WasmComponentValueType.primitive(
                WasmComponentPrimitiveValueType.u32,
              ),
            ),
          ),
        ],
      )!;
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(96, 7, Endian.little);
      data.setUint32(100, 8, Endian.little);
      data.setUint32(32, 96, Endian.little);
      data.setUint32(36, 2, Endian.little);

      final loaded = codec.load(memory, 32) as WasmComponentValueData;

      expect(codec.byteLength, 8);
      expect(codec.alignment, 4);
      expect(codec.requiresRealloc, isTrue);
      expect(loaded.kind, WasmComponentValueDataKind.list);
      expect(loaded.items.map((item) => item.integer), [7, 8]);

      codec.store(
        memory,
        64,
        loaded,
        realloc: (oldPointer, oldSize, alignment, newSize) {
          expect(oldPointer, 0);
          expect(oldSize, 0);
          expect(alignment, 4);
          expect(newSize, 8);
          return 128;
        },
      );
      expect(data.getUint32(64, Endian.little), 128);
      expect(data.getUint32(68, Endian.little), 2);
      expect(data.getUint32(128, Endian.little), 7);
      expect(data.getUint32(132, Endian.little), 8);
    });

    test('does not claim dynamic string memory layout support', () {
      final codec = WASIComponentCanonicalValueMemoryCodec.fromValueType(
        const WasmComponentValueType.primitive(
          WasmComponentPrimitiveValueType.string,
        ),
        const <WasmComponentTypeDefinition>[],
      );

      expect(codec, isNull);
    });
  });
}
