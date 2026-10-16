import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/string_memory.dart';
import 'package:wasd/src/wasi/component/value_memory.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/memory.dart';

import 'support/component_fixtures.dart' as component_fixtures;

void main() {
  group('WASIComponentCanonicalValueMemoryCodec', () {
    test('stores a map after its payload allocation grows memory', () {
      final codec = _primitiveMapCodec(
        WasmComponentPrimitiveValueType.u32,
        WasmComponentPrimitiveValueType.u32,
      );
      final value = _runtimeComposite(WasmComponentValueDataKind.map, [
        _runtimeComposite(WasmComponentValueDataKind.tuple, [7, 42]),
      ]);
      for (final flat in [true, false]) {
        final memory = Memory(const MemoryDescriptor(initial: 1, maximum: 2));
        int realloc(int oldPointer, int oldSize, int alignment, int newSize) {
          expect((oldPointer, oldSize, alignment, newSize), (0, 0, 4, 8));
          expect(memory.grow(1), 1);
          return 65536;
        }

        final WasmComponentValueData loaded;
        if (flat) {
          final stored = codec.storeFlatList(memory, value, realloc: realloc);
          expect(stored, (pointer: 65536, length: 1));
          loaded = codec.loadFlatList(memory, stored.pointer, stored.length);
        } else {
          codec.store(memory, 32, value, realloc: realloc);
          final data = ByteData.view(memory.buffer);
          expect(data.getUint32(32, Endian.little), 65536);
          expect(data.getUint32(36, Endian.little), 1);
          loaded = codec.load(memory, 32) as WasmComponentValueData;
        }
        expect(memory.buffer.lengthInBytes, 131072);
        expect(loaded.items.single.items.map((item) => item.integer), [7, 42]);
      }
    });

    test('keeps later map tuple fields after nested realloc grows memory', () {
      final codec = _primitiveMapCodec(
        WasmComponentPrimitiveValueType.string,
        WasmComponentPrimitiveValueType.u32,
      );
      final memory = Memory(const MemoryDescriptor(initial: 1, maximum: 3));
      var calls = 0;
      final stored = codec.storeFlatList(
        memory,
        _runtimeComposite(WasmComponentValueDataKind.map, [
          for (final number in [42, 43])
            _runtimeComposite(WasmComponentValueDataKind.tuple, [
              'key',
              number,
            ]),
        ]),
        realloc: (_, _, _, _) {
          if (calls++ == 0) return 128;
          return memory.grow(1) * 65536;
        },
      );
      final loaded = codec.loadFlatList(memory, stored.pointer, stored.length);
      expect(memory.buffer.lengthInBytes, 196608);
      expect(loaded.items.map((item) => item.items[0].string), ['key', 'key']);
      expect(loaded.items.map((item) => item.items[1].integer), [42, 43]);
    });

    test(
      'keeps map tuple fields when realloc refreshes memory without growth',
      () {
        final codec = _primitiveMapCodec(
          WasmComponentPrimitiveValueType.string,
          WasmComponentPrimitiveValueType.u32,
        );
        final memory = Memory(const MemoryDescriptor(initial: 1, maximum: 2));
        var calls = 0;
        final stored = codec.storeFlatList(
          memory,
          _runtimeComposite(WasmComponentValueDataKind.map, [
            _runtimeComposite(WasmComponentValueDataKind.tuple, ['key', 42]),
          ]),
          realloc: (_, _, _, _) {
            if (calls++ == 0) return 128;
            expect(memory.grow(0), 1);
            return 256;
          },
        );
        final loaded = codec.loadFlatList(
          memory,
          stored.pointer,
          stored.length,
        );
        expect(loaded.items.single.items[0].string, 'key');
        expect(loaded.items.single.items[1].integer, 42);
        expect(memory.buffer.lengthInBytes, 65536);
      },
    );

    test('keeps map entries and header after nested realloc grows memory', () {
      final codec = _u32StringMapCodec();
      final memory = Memory(const MemoryDescriptor(initial: 1, maximum: 3));
      var calls = 0;
      codec.store(
        memory,
        32,
        _mapValue([(7, 'first'), (9, 'second')]),
        realloc: (_, _, _, _) {
          if (calls++ == 0) return 128;
          return memory.grow(1) * 65536;
        },
      );
      final data = ByteData.view(memory.buffer);
      expect(data.getUint32(32, Endian.little), 128);
      expect(data.getUint32(36, Endian.little), 2);
      expect(_mapEntries(codec.load(memory, 32) as WasmComponentValueData), [
        (7, 'first'),
        (9, 'second'),
      ]);
    });

    test('keeps record fields after nested realloc grows memory', () {
      final codec = WASIComponentCanonicalValueMemoryCodec.fromValueType(
        const WasmComponentValueType.typeIndex(0),
        const [
          WasmComponentTypeDefinition(
            kind: WasmComponentTypeKind.definedValue,
            definedValue: WasmComponentDefinedValueType(
              kind: WasmComponentDefinedValueTypeKind.record,
              fields: [
                WasmComponentLabeledValueType(
                  label: 'text',
                  type: WasmComponentValueType.primitive(
                    WasmComponentPrimitiveValueType.string,
                  ),
                ),
                WasmComponentLabeledValueType(
                  label: 'number',
                  type: WasmComponentValueType.primitive(
                    WasmComponentPrimitiveValueType.u32,
                  ),
                ),
              ],
            ),
          ),
        ],
      )!;
      final memory = Memory(const MemoryDescriptor(initial: 1, maximum: 2));
      codec.store(
        memory,
        32,
        _runtimeComposite(WasmComponentValueDataKind.record, ['grown', 42]),
        realloc: (_, _, _, _) => memory.grow(1) * 65536,
      );
      final loaded = codec.load(memory, 32) as WasmComponentValueData;
      expect(loaded.items[0].string, 'grown');
      expect(loaded.items[1].integer, 42);
    });

    for (final mode in ['list', 'fixed-list', 'batch']) {
      test('keeps $mode values after nested realloc grows memory', () {
        const definitions = [
          WasmComponentTypeDefinition(
            kind: WasmComponentTypeKind.definedValue,
            definedValue: WasmComponentDefinedValueType(
              kind: WasmComponentDefinedValueTypeKind.variant,
              cases: [
                WasmComponentVariantCase(
                  label: 'text',
                  type: WasmComponentValueType.primitive(
                    WasmComponentPrimitiveValueType.string,
                  ),
                ),
                WasmComponentVariantCase(
                  label: 'number',
                  type: WasmComponentValueType.primitive(
                    WasmComponentPrimitiveValueType.u32,
                  ),
                ),
              ],
            ),
          ),
          WasmComponentTypeDefinition(
            kind: WasmComponentTypeKind.definedValue,
            definedValue: WasmComponentDefinedValueType(
              kind: WasmComponentDefinedValueTypeKind.list,
              elementType: WasmComponentValueType.typeIndex(0),
            ),
          ),
          WasmComponentTypeDefinition(
            kind: WasmComponentTypeKind.definedValue,
            definedValue: WasmComponentDefinedValueType(
              kind: WasmComponentDefinedValueTypeKind.fixedList,
              fixedLength: 2,
              elementType: WasmComponentValueType.typeIndex(0),
            ),
          ),
        ];
        final values = [
          WasmComponentValueData(
            kind: WasmComponentValueDataKind.variant,
            rawBytes: Uint8List(0),
            index: 0,
            associatedValue: WasmComponentValueData(
              kind: WasmComponentValueDataKind.string,
              rawBytes: Uint8List(0),
              string: 'grown',
            ),
          ),
          WasmComponentValueData(
            kind: WasmComponentValueDataKind.variant,
            rawBytes: Uint8List(0),
            index: 1,
            associatedValue: WasmComponentValueData(
              kind: WasmComponentValueDataKind.integer,
              rawBytes: Uint8List(0),
              integer: 42,
            ),
          ),
        ];
        final index = mode == 'list'
            ? 1
            : mode == 'fixed-list'
            ? 2
            : 0;
        final codec = WASIComponentCanonicalValueMemoryCodec.fromValueType(
          WasmComponentValueType.typeIndex(index),
          definitions,
        )!;
        final memory = Memory(const MemoryDescriptor(initial: 1, maximum: 2));
        var calls = 0;
        int realloc(int oldPointer, int oldSize, int alignment, int newSize) {
          if (mode == 'list' && calls++ == 0) return 128;
          return memory.grow(1) * 65536;
        }

        final List<WasmComponentValueData> loaded;
        if (mode == 'batch') {
          codec.storeMany(memory, 32, values, realloc: realloc);
          loaded = codec.loadManyAs<WasmComponentValueData>(
            memory,
            32,
            2,
            'values',
          );
        } else if (mode == 'list') {
          final stored = codec.storeFlatList(
            memory,
            WasmComponentValueData(
              kind: WasmComponentValueDataKind.list,
              rawBytes: Uint8List(0),
              items: values,
            ),
            realloc: realloc,
          );
          loaded = codec
              .loadFlatList(memory, stored.pointer, stored.length)
              .items;
        } else {
          codec.store(
            memory,
            32,
            WasmComponentValueData(
              kind: WasmComponentValueDataKind.fixedList,
              rawBytes: Uint8List(0),
              items: values,
            ),
            realloc: realloc,
          );
          loaded = (codec.load(memory, 32) as WasmComponentValueData).items;
        }
        expect(loaded.map((value) => value.index), [0, 1], reason: mode);
        expect(loaded[0].associatedValue!.string, 'grown', reason: mode);
        expect(loaded[1].associatedValue!.integer, 42, reason: mode);
      });
    }

    test('resolves the canonical layout of a decoded map type', () {
      final component = WasmComponent.decode(
        Uint8List.fromList([
          0x00,
          0x61,
          0x73,
          0x6d,
          0x0d,
          0x00,
          0x01,
          0x00,
          0x07,
          0x04,
          0x01,
          0x63,
          0x79,
          0x73,
        ]),
      );
      expect(component.validate(), isEmpty);
      final codec = WASIComponentCanonicalValueMemoryCodec.fromValueType(
        const WasmComponentValueType.typeIndex(0),
        component.componentTypeIndexDefinitions,
      );
      expect(codec, isNotNull);
      expect(codec!.byteLength, 8);
      expect(codec.alignment, 4);
      expect(codec.requiresRealloc, isTrue);
    });

    test('round trips ordered map entries with duplicate keys and strings', () {
      final codec = _u32StringMapCodec();
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      var cursor = 256;
      final allocations = <(int, int)>[];
      int realloc(int oldPointer, int oldSize, int alignment, int newSize) {
        allocations.add((alignment, newSize));
        cursor = (cursor + alignment - 1) & -alignment;
        final pointer = cursor;
        cursor += newSize;
        return pointer;
      }

      final value = _mapValue([(7, 'first'), (7, 'second'), (9, 'hé')]);
      codec.store(memory, 32, value, realloc: realloc);
      final loaded = codec.load(memory, 32) as WasmComponentValueData;
      expect(loaded.kind, WasmComponentValueDataKind.map);
      expect(_mapEntries(loaded), [(7, 'first'), (7, 'second'), (9, 'hé')]);
      expect(allocations.first, (4, 36));
      expect(data.getUint32(256, Endian.little), 7);
      expect(data.getUint32(268, Endian.little), 7);
      expect(data.getUint32(280, Endian.little), 9);

      final flat = codec.storeFlatList(memory, loaded, realloc: realloc);
      expect(flat.length, 3);
      expect(
        _mapEntries(codec.loadFlatList(memory, flat.pointer, flat.length)),
        _mapEntries(value),
      );
      codec.store(memory, 48, _mapValue([]), realloc: realloc);
      expect((codec.load(memory, 48) as WasmComponentValueData).items, isEmpty);
      expect(
        codec.loadFlatList(memory, 0xffffffff, 0).kind,
        WasmComponentValueDataKind.map,
      );
    });

    test('round trips maps nested in records and lists', () {
      final definitions = <WasmComponentTypeDefinition>[
        ..._u32StringMapDefinitions(),
        const WasmComponentTypeDefinition(
          kind: WasmComponentTypeKind.definedValue,
          definedValue: WasmComponentDefinedValueType(
            kind: WasmComponentDefinedValueTypeKind.list,
            elementType: WasmComponentValueType.typeIndex(0),
          ),
        ),
        const WasmComponentTypeDefinition(
          kind: WasmComponentTypeKind.definedValue,
          definedValue: WasmComponentDefinedValueType(
            kind: WasmComponentDefinedValueTypeKind.record,
            fields: [
              WasmComponentLabeledValueType(
                label: 'entries',
                type: WasmComponentValueType.typeIndex(1),
              ),
            ],
          ),
        ),
      ];
      final codec = WASIComponentCanonicalValueMemoryCodec.fromValueType(
        const WasmComponentValueType.typeIndex(2),
        definitions,
      )!;
      final memory = Memory(const MemoryDescriptor(initial: 1));
      var cursor = 256;
      codec.store(
        memory,
        32,
        WasmComponentValueData(
          kind: WasmComponentValueDataKind.record,
          rawBytes: Uint8List(0),
          items: [
            WasmComponentValueData(
              kind: WasmComponentValueDataKind.list,
              rawBytes: Uint8List(0),
              items: [
                _mapValue([(1, 'a')]),
                _mapValue([]),
                _mapValue([(2, 'b')]),
              ],
            ),
          ],
        ),
        realloc: (_, _, alignment, newSize) {
          cursor = (cursor + alignment - 1) & -alignment;
          final pointer = cursor;
          cursor += newSize;
          return pointer;
        },
      );
      expect(codec.requiresRealloc, isTrue);
      final record = codec.load(memory, 32) as WasmComponentValueData;
      expect(record.items.single.items.map(_mapEntries), [
        [(1, 'a')],
        <(int, String)>[],
        [(2, 'b')],
      ]);
      final optionCodec = WASIComponentCanonicalValueMemoryCodec.fromValueType(
        const WasmComponentValueType.typeIndex(3),
        [
          ...definitions,
          const WasmComponentTypeDefinition(
            kind: WasmComponentTypeKind.definedValue,
            definedValue: WasmComponentDefinedValueType(
              kind: WasmComponentDefinedValueTypeKind.option,
              elementType: WasmComponentValueType.typeIndex(0),
            ),
          ),
        ],
      )!;
      expect(optionCodec.requiresRealloc, isTrue);
    });

    test(
      'stores runtime map tuples while preserving duplicate string keys',
      () {
        final codec = WASIComponentCanonicalValueMemoryCodec.fromValueType(
          const WasmComponentValueType.typeIndex(0),
          const [
            WasmComponentTypeDefinition(
              kind: WasmComponentTypeKind.definedValue,
              definedValue: WasmComponentDefinedValueType(
                kind: WasmComponentDefinedValueTypeKind.map,
                keyType: WasmComponentValueType.primitive(
                  WasmComponentPrimitiveValueType.string,
                ),
                valueType: WasmComponentValueType.primitive(
                  WasmComponentPrimitiveValueType.u32,
                ),
              ),
            ),
          ],
        )!;
        final memory = Memory(const MemoryDescriptor(initial: 1));
        var cursor = 128;
        final value = WasmComponentValueData(
          kind: WasmComponentValueDataKind.map,
          rawBytes: Uint8List(0),
          runtimeItems: [
            for (final number in [1, 2])
              WasmComponentValueData(
                kind: WasmComponentValueDataKind.tuple,
                rawBytes: Uint8List(0),
                runtimeItems: ['same', number],
              ),
          ],
        );
        codec.validate('entries', value);
        final flat = codec.storeFlatList(
          memory,
          value,
          realloc: (_, _, alignment, newSize) {
            cursor = (cursor + alignment - 1) & -alignment;
            final pointer = cursor;
            cursor += newSize;
            return pointer;
          },
        );
        final loaded = codec.loadFlatList(memory, flat.pointer, flat.length);
        expect(loaded.items.map((item) => item.items[0].string), [
          'same',
          'same',
        ]);
        expect(loaded.items.map((item) => item.items[1].integer), [1, 2]);
      },
    );

    test('rejects malformed map entries and out of bounds payloads', () {
      final codec = _u32StringMapCodec();
      final memory = Memory(const MemoryDescriptor(initial: 1));
      expect(() => codec.validate('entries', {1: 'x'}), throwsStateError);
      expect(
        () => codec.validate(
          'entries',
          WasmComponentValueData(
            kind: WasmComponentValueDataKind.list,
            rawBytes: Uint8List(0),
            items: _mapValue([(1, 'x')]).items,
          ),
        ),
        throwsStateError,
      );
      expect(
        () => codec.validate('entries', _mapValue([(-1, 'x')])),
        throwsStateError,
      );
      expect(
        () => codec.validate(
          'entries',
          WasmComponentValueData(
            kind: WasmComponentValueDataKind.map,
            rawBytes: Uint8List(0),
            items: [
              _mapValue([(1, 'x')]).items.single.items.first,
            ],
          ),
        ),
        throwsStateError,
      );
      expect(() => codec.loadFlatList(memory, 65532, 1), throwsRangeError);
      expect(() => codec.loadFlatList(memory, 65, 1), throwsStateError);
      expect(
        () => codec.loadFlatList(memory, 64, 0xffffffff),
        throwsRangeError,
      );
    });

    test('does not treat u32 handle memory layouts as legal map keys', () {
      for (final kind in [
        WasmComponentDefinedValueTypeKind.own,
        WasmComponentDefinedValueTypeKind.borrow,
        WasmComponentDefinedValueTypeKind.stream,
        WasmComponentDefinedValueTypeKind.future,
      ]) {
        final definitions = <WasmComponentTypeDefinition>[
          const WasmComponentTypeDefinition(
            kind: WasmComponentTypeKind.resource,
            resource: WasmComponentResourceType.abstract(),
          ),
          WasmComponentTypeDefinition(
            kind: WasmComponentTypeKind.definedValue,
            definedValue: WasmComponentDefinedValueType(
              kind: kind,
              typeIndex: 0,
            ),
          ),
          const WasmComponentTypeDefinition(
            kind: WasmComponentTypeKind.definedValue,
            definedValue: WasmComponentDefinedValueType(
              kind: WasmComponentDefinedValueTypeKind.map,
              keyType: WasmComponentValueType.typeIndex(1),
              valueType: WasmComponentValueType.primitive(
                WasmComponentPrimitiveValueType.u32,
              ),
            ),
          ),
        ];
        expect(
          WASIComponentCanonicalValueMemoryCodec.fromAdapterValueType(
            const WasmComponentValueType.typeIndex(2),
            definitions,
          ),
          isNull,
          reason: '${kind.name} is a handle rather than a primitive map key',
        );
      }
    });

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

    test('rejects non-scalar char stores', () {
      final codec = WASIComponentCanonicalValueMemoryCodec.fromValueType(
        const WasmComponentValueType.primitive(
          WasmComponentPrimitiveValueType.char,
        ),
        const <WasmComponentTypeDefinition>[],
      )!;
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);

      codec.store(memory, 32, 'A');
      expect(data.getUint32(32, Endian.little), 0x41);
      expect(
        () => codec.store(memory, 32, String.fromCharCode(0xd800)),
        throwsStateError,
      );
      expect(data.getUint32(32, Endian.little), 0x41);

      codec.store(memory, 32, String.fromCharCode(0x1f600));
      expect(data.getUint32(32, Endian.little), 0x1f600);
    });

    test('loads and stores error-context handles as canonical u32', () {
      final codec = WASIComponentCanonicalValueMemoryCodec.fromValueType(
        const WasmComponentValueType.primitive(
          WasmComponentPrimitiveValueType.errorContext,
        ),
        const <WasmComponentTypeDefinition>[],
      )!;
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 17, Endian.little);

      expect(codec.byteLength, 4);
      expect(codec.alignment, 4);
      expect(codec.load(memory, 32), 17);

      codec.store(memory, 36, 23);
      expect(data.getUint32(36, Endian.little), 23);
      codec.store(
        memory,
        40,
        WasmComponentValueData(
          kind: WasmComponentValueDataKind.integer,
          rawBytes: Uint8List(0),
          integer: 29,
        ),
      );
      expect(data.getUint32(40, Endian.little), 29);
      expect(() => codec.store(memory, 44, -1), throwsStateError);
      expect(() => codec.store(memory, 44, 0x100000000), throwsStateError);
      expect(
        () => codec.store(
          memory,
          44,
          WasmComponentValueData(
            kind: WasmComponentValueDataKind.integer,
            rawBytes: Uint8List(0),
            integer: -1,
          ),
        ),
        throwsStateError,
      );
      expect(
        () => codec.store(
          memory,
          44,
          WasmComponentValueData(
            kind: WasmComponentValueDataKind.integer,
            rawBytes: Uint8List(0),
            integer: 0x100000000,
          ),
        ),
        throwsStateError,
      );
    });

    test('loads and stores handle-aware adapter records as canonical u32', () {
      expect(
        WASIComponentCanonicalValueMemoryCodec.fromValueType(
          component_fixtures.canonicalResourceRecordValueType,
          component_fixtures.canonicalResourceRecordDefinitions,
        ),
        isNull,
      );
      final codec = WASIComponentCanonicalValueMemoryCodec.fromAdapterValueType(
        component_fixtures.canonicalResourceRecordValueType,
        component_fixtures.canonicalResourceRecordDefinitions,
      )!;
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 101, Endian.little);
      data.setUint32(36, 202, Endian.little);
      data.setUint16(40, 7, Endian.little);

      final loaded = codec.load(memory, 32) as WasmComponentValueData;

      expect(codec.byteLength, 12);
      expect(codec.alignment, 4);
      expect(loaded.kind, WasmComponentValueDataKind.record);
      expect(loaded.items.map((item) => item.integer), [101, 202, 7]);

      codec.store(memory, 64, loaded);
      expect(data.getUint32(64, Endian.little), 101);
      expect(data.getUint32(68, Endian.little), 202);
      expect(data.getUint16(72, Endian.little), 7);

      expect(
        () => codec.store(
          memory,
          80,
          WasmComponentValueData(
            kind: WasmComponentValueDataKind.record,
            rawBytes: Uint8List(0),
            items: [
              WasmComponentValueData(
                kind: WasmComponentValueDataKind.integer,
                rawBytes: Uint8List(0),
                integer: 0x100000000,
              ),
              WasmComponentValueData(
                kind: WasmComponentValueDataKind.integer,
                rawBytes: Uint8List(0),
                integer: 202,
              ),
              WasmComponentValueData(
                kind: WasmComponentValueDataKind.integer,
                rawBytes: Uint8List(0),
                integer: 7,
              ),
            ],
          ),
        ),
        throwsStateError,
      );
    });

    test('loads and stores owned resource async elements as canonical u32', () {
      expect(
        WASIComponentCanonicalValueMemoryCodec.fromValueType(
          const WasmComponentValueType.typeIndex(1),
          component_fixtures.canonicalResourceRecordDefinitions,
        ),
        isNull,
      );
      expect(
        WASIComponentCanonicalValueMemoryCodec.fromAsyncElementType(
          const WasmComponentValueType.typeIndex(2),
          component_fixtures.canonicalResourceRecordDefinitions,
        ),
        isNull,
      );
      final codec = WASIComponentCanonicalValueMemoryCodec.fromAsyncElementType(
        const WasmComponentValueType.typeIndex(1),
        component_fixtures.canonicalResourceRecordDefinitions,
      )!;
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint32(32, 0xffffffff, Endian.little);

      expect(codec.byteLength, 4);
      expect(codec.alignment, 4);
      expect(codec.load(memory, 32), 0xffffffff);

      codec.store(memory, 36, 0x80000000);
      expect(data.getUint32(36, Endian.little), 0x80000000);
      expect(() => codec.store(memory, 40, -1), throwsStateError);
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

    test('rejects duplicate flag labels before writing memory', () {
      final codec = WASIComponentCanonicalValueMemoryCodec.fromValueType(
        const WasmComponentValueType.typeIndex(0),
        [
          const WasmComponentTypeDefinition(
            kind: WasmComponentTypeKind.definedValue,
            definedValue: WasmComponentDefinedValueType(
              kind: WasmComponentDefinedValueTypeKind.flags,
              labels: ['a', 'b', 'c'],
            ),
          ),
        ],
      )!;
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final data = ByteData.view(memory.buffer);
      data.setUint8(32, 0xff);
      final duplicate = WasmComponentValueData(
        kind: WasmComponentValueDataKind.flags,
        rawBytes: Uint8List(0),
        labels: ['a', 'a'],
      );

      expect(() => codec.store(memory, 32, duplicate), throwsStateError);
      expect(data.getUint8(32), 0xff);
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

    test('rejects invalid variant payloads before writing memory', () {
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
                    WasmComponentPrimitiveValueType.u32,
                  ),
                ),
              ],
            ),
          ),
        ],
      )!;
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final bytes = Uint8List.view(memory.buffer);
      bytes.fillRange(32, 40, 0xaa);

      expect(
        () => codec.store(
          memory,
          32,
          WasmComponentValueData(
            kind: WasmComponentValueDataKind.variant,
            rawBytes: Uint8List(0),
            label: 'empty',
            associatedValue: WasmComponentValueData(
              kind: WasmComponentValueDataKind.integer,
              rawBytes: Uint8List(0),
              integer: 7,
            ),
          ),
        ),
        throwsStateError,
      );
      expect(bytes.sublist(32, 40), everyElement(0xaa));

      expect(
        () => codec.store(
          memory,
          32,
          WasmComponentValueData(
            kind: WasmComponentValueDataKind.variant,
            rawBytes: Uint8List(0),
            label: 'number',
          ),
        ),
        throwsStateError,
      );
      expect(bytes.sublist(32, 40), everyElement(0xaa));
    });

    test(
      'rejects conflicting variant case selectors before writing memory',
      () {
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
        data.setUint8(32, 0xff);
        data.setUint64(40, 0xffffffffffffffff, Endian.little);
        final conflicting = WasmComponentValueData(
          kind: WasmComponentValueDataKind.variant,
          rawBytes: Uint8List(0),
          index: 1,
          label: 'empty',
          associatedValue: WasmComponentValueData(
            kind: WasmComponentValueDataKind.integer,
            rawBytes: Uint8List(0),
            integer: 7,
          ),
        );

        expect(() => codec.store(memory, 32, conflicting), throwsStateError);
        expect(data.getUint8(32), 0xff);
        expect(data.getUint64(40, Endian.little), 0xffffffffffffffff);
      },
    );

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

    test('allocates an aligned non-null pointer for an empty list', () {
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
      final empty = WasmComponentValueData(
        kind: WasmComponentValueDataKind.list,
        rawBytes: Uint8List(0),
      );
      var allocations = 0;

      codec.store(
        memory,
        64,
        empty,
        realloc: (oldPointer, oldSize, alignment, newSize) {
          allocations++;
          expect(oldPointer, 0);
          expect(oldSize, 0);
          expect(alignment, 4);
          expect(newSize, 0);
          return 4;
        },
      );

      expect(allocations, 1);
      expect(data.getUint32(64, Endian.little), 4);
      expect(data.getUint32(68, Endian.little), 0);
    });

    test('loads and stores strings through canonical records', () {
      final codec = WASIComponentCanonicalValueMemoryCodec.fromValueType(
        const WasmComponentValueType.primitive(
          WasmComponentPrimitiveValueType.string,
        ),
        const <WasmComponentTypeDefinition>[],
      )!;
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final bytes = Uint8List.view(memory.buffer);
      final data = ByteData.view(memory.buffer);
      data.setUint16(96, 0x68, Endian.little);
      data.setUint16(98, 0xe9, Endian.little);
      data.setUint32(32, 96, Endian.little);
      data.setUint32(36, 2, Endian.little);

      final loaded = codec.load(
        memory,
        32,
        stringEncoding: WASIComponentCanonicalStringEncoding.utf16,
      );

      expect(codec.byteLength, 8);
      expect(codec.alignment, 4);
      expect(codec.requiresRealloc, isTrue);
      expect(loaded, 'hé');

      codec.store(
        memory,
        64,
        loaded,
        realloc: (oldPointer, oldSize, alignment, newSize) {
          expect(oldPointer, 0);
          expect(oldSize, 0);
          expect(alignment, 2);
          expect(newSize, 4);
          return 128;
        },
        stringEncoding: WASIComponentCanonicalStringEncoding.utf16,
      );
      expect(data.getUint32(64, Endian.little), 128);
      expect(data.getUint32(68, Endian.little), 2);
      expect(bytes[128], 0x68);
      expect(bytes[129], 0x00);
      expect(bytes[130], 0xe9);
      expect(bytes[131], 0x00);
    });

    test('loads and stores lists of strings through nested realloc', () {
      final codec = WASIComponentCanonicalValueMemoryCodec.fromValueType(
        const WasmComponentValueType.typeIndex(0),
        [
          const WasmComponentTypeDefinition(
            kind: WasmComponentTypeKind.definedValue,
            definedValue: WasmComponentDefinedValueType(
              kind: WasmComponentDefinedValueTypeKind.list,
              elementType: WasmComponentValueType.primitive(
                WasmComponentPrimitiveValueType.string,
              ),
            ),
          ),
        ],
      )!;
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final bytes = Uint8List.view(memory.buffer);
      final data = ByteData.view(memory.buffer);
      bytes.setAll(160, 'go'.codeUnits);
      bytes.setAll(176, 'hi'.codeUnits);
      data.setUint32(96, 160, Endian.little);
      data.setUint32(100, 2, Endian.little);
      data.setUint32(104, 176, Endian.little);
      data.setUint32(108, 2, Endian.little);
      data.setUint32(32, 96, Endian.little);
      data.setUint32(36, 2, Endian.little);

      final loaded = codec.load(memory, 32) as WasmComponentValueData;

      expect(loaded.kind, WasmComponentValueDataKind.list);
      expect(loaded.items.map((item) => item.string), ['go', 'hi']);
      final allocations = <int>[224, 256, 272];
      codec.store(
        memory,
        64,
        loaded,
        realloc: (oldPointer, oldSize, alignment, newSize) {
          expect(oldPointer, 0);
          expect(oldSize, 0);
          if (allocations.length == 3) {
            expect(alignment, 4);
            expect(newSize, 16);
          } else {
            expect(alignment, 1);
            expect(newSize, 2);
          }
          return allocations.removeAt(0);
        },
      );
      expect(data.getUint32(64, Endian.little), 224);
      expect(data.getUint32(68, Endian.little), 2);
      expect(data.getUint32(224, Endian.little), 256);
      expect(data.getUint32(228, Endian.little), 2);
      expect(data.getUint32(232, Endian.little), 272);
      expect(data.getUint32(236, Endian.little), 2);
      expect(String.fromCharCodes(bytes.sublist(256, 258)), 'go');
      expect(String.fromCharCodes(bytes.sublist(272, 274)), 'hi');
      expect(allocations, isEmpty);
    });
  });
}

List<WasmComponentTypeDefinition> _u32StringMapDefinitions() =>
    WasmComponent.decode(
      Uint8List.fromList([
        0x00,
        0x61,
        0x73,
        0x6d,
        0x0d,
        0x00,
        0x01,
        0x00,
        0x07,
        0x04,
        0x01,
        0x63,
        0x79,
        0x73,
      ]),
    ).componentTypeIndexDefinitions;

WASIComponentCanonicalValueMemoryCodec _u32StringMapCodec() =>
    WASIComponentCanonicalValueMemoryCodec.fromValueType(
      const WasmComponentValueType.typeIndex(0),
      _u32StringMapDefinitions(),
    )!;

WasmComponentValueData _mapValue(List<(int, String)> entries) =>
    WasmComponentValueData(
      kind: WasmComponentValueDataKind.map,
      rawBytes: Uint8List(0),
      items: [
        for (final entry in entries)
          WasmComponentValueData(
            kind: WasmComponentValueDataKind.tuple,
            rawBytes: Uint8List(0),
            items: [
              WasmComponentValueData(
                kind: WasmComponentValueDataKind.integer,
                rawBytes: Uint8List(0),
                integer: entry.$1,
              ),
              WasmComponentValueData(
                kind: WasmComponentValueDataKind.string,
                rawBytes: Uint8List(0),
                string: entry.$2,
              ),
            ],
          ),
      ],
    );

List<(int, String)> _mapEntries(WasmComponentValueData value) => [
  for (final entry in value.items)
    (entry.items[0].integer! as int, entry.items[1].string!),
];

WASIComponentCanonicalValueMemoryCodec _primitiveMapCodec(
  WasmComponentPrimitiveValueType key,
  WasmComponentPrimitiveValueType value,
) => WASIComponentCanonicalValueMemoryCodec.fromValueType(
  const WasmComponentValueType.typeIndex(0),
  [
    WasmComponentTypeDefinition(
      kind: WasmComponentTypeKind.definedValue,
      definedValue: WasmComponentDefinedValueType(
        kind: WasmComponentDefinedValueTypeKind.map,
        keyType: WasmComponentValueType.primitive(key),
        valueType: WasmComponentValueType.primitive(value),
      ),
    ),
  ],
)!;

WasmComponentValueData _runtimeComposite(
  WasmComponentValueDataKind kind,
  List<Object?> values,
) => WasmComponentValueData(
  kind: kind,
  rawBytes: Uint8List(0),
  runtimeItems: values,
);
