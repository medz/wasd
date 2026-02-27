import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/wasd.dart';

void main() {
  group('WasmComponentInstance', () {
    test('requires componentModel feature gate', () {
      final componentBytes = _componentWithCoreModules(<Uint8List>[
        _coreModuleConstI32(name: 'one', value: 1),
      ]);

      expect(
        () => WasmComponentInstance.fromBytes(
          componentBytes,
          features: const WasmFeatureSet(componentModel: false),
        ),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('instantiates embedded core modules and invokes exports', () {
      final componentBytes = _componentWithCoreModules(<Uint8List>[
        _coreModuleConstI32(name: 'one', value: 7),
      ]);

      final instance = WasmComponentInstance.fromBytes(
        componentBytes,
        features: const WasmFeatureSet(componentModel: true),
      );

      expect(instance.coreInstances, hasLength(1));
      expect(instance.invokeCore('one'), 7);
    });

    test(
      'can instantiate from bytes with bestEffortDecode for unsupported structured sections',
      () {
        final baseComponent = _componentWithCoreModules(<Uint8List>[
          _coreModuleConstI32(name: 'one', value: 9),
        ]);
        final unsupportedTypeBindingSection = <int>[
          ..._u32Leb(1),
          0x40, // unsupported in strict decode mode
          ..._u32Leb(0),
          ..._u32Leb(0),
        ];
        final componentBytes = Uint8List.fromList(<int>[
          ...baseComponent,
          ..._section(0x07, unsupportedTypeBindingSection),
        ]);

        final strictInstance = WasmComponentInstance.fromBytes(
          componentBytes,
          features: const WasmFeatureSet(componentModel: true),
        );
        expect(strictInstance.invokeCore('one'), 9);

        final instance = WasmComponentInstance.fromBytes(
          componentBytes,
          features: const WasmFeatureSet(componentModel: true),
          bestEffortDecode: true,
        );
        expect(instance.invokeCore('one'), 9);
      },
    );

    test('uses core-instance declarations when section 0x02 is present', () {
      final componentBytes = _componentWithCoreModules(
        <Uint8List>[
          _coreModuleConstI32(name: 'one', value: 1),
          _coreModuleConstI32(name: 'two', value: 2),
        ],
        instantiateModuleIndices: const [1],
      );

      final instance = WasmComponentInstance.fromBytes(
        componentBytes,
        features: const WasmFeatureSet(componentModel: true),
      );

      expect(instance.coreInstances, hasLength(1));
      expect(instance.invokeCore('two'), 2);
      expect(() => instance.invokeCore('one'), throwsA(isA<ArgumentError>()));
    });

    test(
      'falls back to module-order instantiation when core-instance declarations include opaque entries',
      () {
        final baseComponent = _componentWithCoreModules(<Uint8List>[
          _coreModuleConstI32(name: 'one', value: 1),
          _coreModuleConstI32(name: 'two', value: 2),
        ]);
        final opaqueCoreInstanceSectionPayload = <int>[
          ..._u32Leb(2),
          0x01,
          ..._u32Leb(0),
          0x00,
          ..._u32Leb(1),
          ..._u32Leb(0),
        ];
        final componentBytes = Uint8List.fromList(<int>[
          ...baseComponent,
          ..._section(0x02, opaqueCoreInstanceSectionPayload),
        ]);

        final instance = WasmComponentInstance.fromBytes(
          componentBytes,
          features: const WasmFeatureSet(componentModel: true),
        );

        expect(instance.component.hasOpaqueCoreInstances, isTrue);
        expect(instance.coreInstances, hasLength(2));
        expect(instance.invokeCore('one', moduleIndex: 0), 1);
        expect(instance.invokeCore('two', moduleIndex: 1), 2);
      },
    );

    test('accepts declared core-instance argument dependency indexes', () {
      final componentBytes = _componentWithCoreModules(
        <Uint8List>[
          _coreModuleConstI32(name: 'one', value: 1),
          _coreModuleConstI32(name: 'two', value: 2),
        ],
        instantiateModuleIndices: const [0, 1],
        instantiateArgumentInstanceIndices: const [
          <int>[],
          <int>[0],
        ],
      );

      final instance = WasmComponentInstance.fromBytes(
        componentBytes,
        features: const WasmFeatureSet(componentModel: true),
      );

      expect(instance.coreInstances, hasLength(2));
      expect(instance.invokeCore('one', moduleIndex: 0), 1);
      expect(instance.invokeCore('two', moduleIndex: 1), 2);
    });

    test('rejects out-of-range core-instance argument dependency indexes', () {
      final componentBytes = _componentWithCoreModules(
        <Uint8List>[_coreModuleConstI32(name: 'one', value: 1)],
        instantiateModuleIndices: const [0],
        instantiateArgumentInstanceIndices: const [
          <int>[1],
        ],
      );

      expect(
        () => WasmComponentInstance.fromBytes(
          componentBytes,
          features: const WasmFeatureSet(componentModel: true),
        ),
        throwsFormatException,
      );
    });

    test('wires function imports from core-instance argument exports', () {
      final componentBytes = _componentWithCoreModules(
        <Uint8List>[
          _coreModuleConstI32(name: 'inc', value: 42),
          _coreModuleCallImportedNullary(
            importModule: 'host',
            importName: 'inc',
            exportName: 'run',
          ),
        ],
        instantiateModuleIndices: const [0, 1],
        instantiateArgumentInstanceIndices: const [
          <int>[],
          <int>[0],
        ],
      );

      final instance = WasmComponentInstance.fromBytes(
        componentBytes,
        features: const WasmFeatureSet(componentModel: true),
      );

      expect(instance.invokeCore('run', moduleIndex: 1), 42);
    });

    test(
      'rejects function imports wired from core-instance args with mismatched signatures',
      () {
        final componentBytes = _componentWithCoreModules(
          <Uint8List>[
            _coreModuleConstI64(name: 'inc', value: 42),
            _coreModuleCallImportedNullary(
              importModule: 'host',
              importName: 'inc',
              exportName: 'run',
            ),
          ],
          instantiateModuleIndices: const [0, 1],
          instantiateArgumentInstanceIndices: const [
            <int>[],
            <int>[0],
          ],
        );

        expect(
          () => WasmComponentInstance.fromBytes(
            componentBytes,
            features: const WasmFeatureSet(componentModel: true),
          ),
          throwsFormatException,
        );
      },
    );

    test('wires non-function imports from core-instance argument exports', () {
      final componentBytes = _componentWithCoreModules(
        <Uint8List>[
          _coreModuleExportMemory(name: 'mem', minPages: 2, maxPages: 2),
          _coreModuleImportMemoryAndConst(
            importModule: 'env',
            importName: 'mem',
            minPages: 1,
            maxPages: 3,
            exportName: 'runMem',
            value: 11,
          ),
          _coreModuleExportTable(name: 'tab', min: 3, max: 3),
          _coreModuleImportTableAndConst(
            importModule: 'env',
            importName: 'tab',
            min: 2,
            max: 4,
            exportName: 'runTab',
            value: 12,
          ),
          _coreModuleExportGlobalI32(name: 'g', value: 7),
          _coreModuleImportGlobalAndConst(
            importModule: 'env',
            importName: 'g',
            valueType: 0x7f,
            mutable: false,
            exportName: 'runGlobal',
            value: 13,
          ),
          _coreModuleExportTag(name: 't', paramType: 0x7f),
          _coreModuleImportTagAndConst(
            importModule: 'env',
            importName: 't',
            expectedParamType: 0x7f,
            exportName: 'runTag',
            value: 14,
          ),
        ],
        instantiateModuleIndices: const [0, 1, 2, 3, 4, 5, 6, 7],
        instantiateArgumentInstanceIndices: const [
          <int>[],
          <int>[0],
          <int>[],
          <int>[2],
          <int>[],
          <int>[4],
          <int>[],
          <int>[6],
        ],
      );

      final instance = WasmComponentInstance.fromBytes(
        componentBytes,
        features: const WasmFeatureSet(componentModel: true),
      );

      expect(instance.invokeCore('runMem', moduleIndex: 1), 11);
      expect(instance.invokeCore('runTab', moduleIndex: 3), 12);
      expect(instance.invokeCore('runGlobal', moduleIndex: 5), 13);
      expect(instance.invokeCore('runTag', moduleIndex: 7), 14);
    });

    test(
      'rejects memory imports wired from core-instance args with mismatched types',
      () {
        final componentBytes = _componentWithCoreModules(
          <Uint8List>[
            _coreModuleExportMemory(name: 'mem', minPages: 1, maxPages: 1),
            _coreModuleImportMemoryAndConst(
              importModule: 'env',
              importName: 'mem',
              minPages: 2,
              maxPages: 2,
              exportName: 'run',
              value: 1,
            ),
          ],
          instantiateModuleIndices: const [0, 1],
          instantiateArgumentInstanceIndices: const [
            <int>[],
            <int>[0],
          ],
        );

        expect(
          () => WasmComponentInstance.fromBytes(
            componentBytes,
            features: const WasmFeatureSet(componentModel: true),
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'prefers later compatible memory export when an earlier dependency is incompatible',
      () {
        final componentBytes = _componentWithCoreModules(
          <Uint8List>[
            _coreModuleExportMemory(name: 'mem', minPages: 1, maxPages: 1),
            _coreModuleExportMemory(name: 'mem', minPages: 3, maxPages: 3),
            _coreModuleImportMemoryAndConst(
              importModule: 'env',
              importName: 'mem',
              minPages: 2,
              maxPages: 3,
              exportName: 'run',
              value: 21,
            ),
          ],
          instantiateModuleIndices: const [0, 1, 2],
          instantiateArgumentInstanceIndices: const [
            <int>[],
            <int>[],
            <int>[0, 1],
          ],
        );

        final instance = WasmComponentInstance.fromBytes(
          componentBytes,
          features: const WasmFeatureSet(componentModel: true),
        );
        expect(instance.invokeCore('run', moduleIndex: 2), 21);
      },
    );

    test(
      'prefers later compatible table export when an earlier dependency is incompatible',
      () {
        final componentBytes = _componentWithCoreModules(
          <Uint8List>[
            _coreModuleExportTable(name: 'tab', min: 1, max: 1),
            _coreModuleExportTable(name: 'tab', min: 3, max: 3),
            _coreModuleImportTableAndConst(
              importModule: 'env',
              importName: 'tab',
              min: 2,
              max: 3,
              exportName: 'run',
              value: 22,
            ),
          ],
          instantiateModuleIndices: const [0, 1, 2],
          instantiateArgumentInstanceIndices: const [
            <int>[],
            <int>[],
            <int>[0, 1],
          ],
        );

        final instance = WasmComponentInstance.fromBytes(
          componentBytes,
          features: const WasmFeatureSet(componentModel: true),
        );
        expect(instance.invokeCore('run', moduleIndex: 2), 22);
      },
    );

    test(
      'prefers later compatible global export when an earlier dependency is incompatible',
      () {
        final componentBytes = _componentWithCoreModules(
          <Uint8List>[
            _coreModuleExportGlobalI64(name: 'g', value: 0),
            _coreModuleExportGlobalI32(name: 'g', value: 0),
            _coreModuleImportGlobalAndConst(
              importModule: 'env',
              importName: 'g',
              valueType: 0x7f,
              mutable: false,
              exportName: 'run',
              value: 23,
            ),
          ],
          instantiateModuleIndices: const [0, 1, 2],
          instantiateArgumentInstanceIndices: const [
            <int>[],
            <int>[],
            <int>[0, 1],
          ],
        );

        final instance = WasmComponentInstance.fromBytes(
          componentBytes,
          features: const WasmFeatureSet(componentModel: true),
        );
        expect(instance.invokeCore('run', moduleIndex: 2), 23);
      },
    );

    test(
      'prefers later compatible tag export when an earlier dependency is incompatible',
      () {
        final componentBytes = _componentWithCoreModules(
          <Uint8List>[
            _coreModuleExportTag(name: 't', paramType: 0x7e),
            _coreModuleExportTag(name: 't', paramType: 0x7f),
            _coreModuleImportTagAndConst(
              importModule: 'env',
              importName: 't',
              expectedParamType: 0x7f,
              exportName: 'run',
              value: 24,
            ),
          ],
          instantiateModuleIndices: const [0, 1, 2],
          instantiateArgumentInstanceIndices: const [
            <int>[],
            <int>[],
            <int>[0, 1],
          ],
        );

        final instance = WasmComponentInstance.fromBytes(
          componentBytes,
          features: const WasmFeatureSet(componentModel: true),
        );
        expect(instance.invokeCore('run', moduleIndex: 2), 24);
      },
    );

    test(
      'rejects table imports wired from core-instance args with mismatched types',
      () {
        final componentBytes = _componentWithCoreModules(
          <Uint8List>[
            _coreModuleExportTable(name: 'tab', min: 1, max: 1),
            _coreModuleImportTableAndConst(
              importModule: 'env',
              importName: 'tab',
              min: 2,
              max: 2,
              exportName: 'run',
              value: 1,
            ),
          ],
          instantiateModuleIndices: const [0, 1],
          instantiateArgumentInstanceIndices: const [
            <int>[],
            <int>[0],
          ],
        );

        expect(
          () => WasmComponentInstance.fromBytes(
            componentBytes,
            features: const WasmFeatureSet(componentModel: true),
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'rejects global imports wired from core-instance args with mismatched types',
      () {
        final componentBytes = _componentWithCoreModules(
          <Uint8List>[
            _coreModuleExportGlobalI64(name: 'g', value: 0),
            _coreModuleImportGlobalAndConst(
              importModule: 'env',
              importName: 'g',
              valueType: 0x7f,
              mutable: false,
              exportName: 'run',
              value: 1,
            ),
          ],
          instantiateModuleIndices: const [0, 1],
          instantiateArgumentInstanceIndices: const [
            <int>[],
            <int>[0],
          ],
        );

        expect(
          () => WasmComponentInstance.fromBytes(
            componentBytes,
            features: const WasmFeatureSet(componentModel: true),
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'rejects tag imports wired from core-instance args with mismatched types',
      () {
        final componentBytes = _componentWithCoreModules(
          <Uint8List>[
            _coreModuleExportTag(name: 't', paramType: 0x7e),
            _coreModuleImportTagAndConst(
              importModule: 'env',
              importName: 't',
              expectedParamType: 0x7f,
              exportName: 'run',
              value: 1,
            ),
          ],
          instantiateModuleIndices: const [0, 1],
          instantiateArgumentInstanceIndices: const [
            <int>[],
            <int>[0],
          ],
        );

        expect(
          () => WasmComponentInstance.fromBytes(
            componentBytes,
            features: const WasmFeatureSet(componentModel: true),
          ),
          throwsFormatException,
        );
      },
    );

    test('invokes component export aliases from section 0x03', () async {
      final componentBytes = _componentWithCoreModules(
        <Uint8List>[_coreModuleConstI32(name: 'one', value: 9)],
        instantiateModuleIndices: const [0],
        exportAliases: const [
          _ComponentAliasSpec(
            instanceIndex: 0,
            coreExportName: 'one',
            componentExportName: 'apiOne',
          ),
        ],
      );

      final instance = WasmComponentInstance.fromBytes(
        componentBytes,
        features: const WasmFeatureSet(componentModel: true),
      );

      expect(instance.invokeComponentExport('apiOne'), 9);
      expect(await instance.invokeComponentExportAsync('apiOne'), 9);
    });

    test('rejects component export alias pointing to missing core export', () {
      final componentBytes = _componentWithCoreModules(
        <Uint8List>[_coreModuleConstI32(name: 'one', value: 9)],
        instantiateModuleIndices: const [0],
        exportAliases: const [
          _ComponentAliasSpec(
            instanceIndex: 0,
            coreExportName: 'missing',
            componentExportName: 'apiMissing',
          ),
        ],
      );

      expect(
        () => WasmComponentInstance.fromBytes(
          componentBytes,
          features: const WasmFeatureSet(componentModel: true),
        ),
        throwsFormatException,
      );
    });

    test('exposes non-function component export aliases from section 0x03', () {
      final componentBytes = _componentWithCoreModules(
        <Uint8List>[
          _coreModuleExportMemory(name: 'mem', minPages: 1, maxPages: 2),
          _coreModuleExportTable(name: 'tab', min: 1, max: 3),
          _coreModuleExportGlobalI32(name: 'g', value: 7),
          _coreModuleExportTag(name: 'err', paramType: 0x7f),
        ],
        instantiateModuleIndices: const [0, 1, 2, 3],
        exportAliases: const [
          _ComponentAliasSpec(
            instanceIndex: 0,
            coreExportName: 'mem',
            componentExportName: 'apiMem',
          ),
          _ComponentAliasSpec(
            instanceIndex: 1,
            coreExportName: 'tab',
            componentExportName: 'apiTab',
          ),
          _ComponentAliasSpec(
            instanceIndex: 2,
            coreExportName: 'g',
            componentExportName: 'apiGlobal',
          ),
          _ComponentAliasSpec(
            instanceIndex: 3,
            coreExportName: 'err',
            componentExportName: 'apiTag',
          ),
        ],
      );

      final instance = WasmComponentInstance.fromBytes(
        componentBytes,
        features: const WasmFeatureSet(componentModel: true),
      );

      expect(
        instance.componentExportKind('apiMem'),
        WasmComponentImportKind.memory,
      );
      expect(
        instance.componentExportKind('apiTab'),
        WasmComponentImportKind.table,
      );
      expect(
        instance.componentExportKind('apiGlobal'),
        WasmComponentImportKind.global,
      );
      expect(
        instance.componentExportKind('apiTag'),
        WasmComponentImportKind.tag,
      );

      final memory = instance.componentExportMemory('apiMem');
      expect(memory.pageCount, 1);
      expect(memory.maxPages, 2);

      final table = instance.componentExportTable('apiTab');
      expect(table.length, 1);
      expect(table.max, 3);

      expect(instance.readComponentExportGlobal('apiGlobal'), 7);
      expect(
        instance.componentExportGlobalBinding('apiGlobal').valueType,
        WasmValueType.i32,
      );

      final tag = instance.componentExportTag('apiTag');
      expect(
        tag.type.params,
        orderedEquals(const <WasmValueType>[WasmValueType.i32]),
      );
      expect(tag.type.results, isEmpty);

      expect(() => instance.invokeComponentExport('apiMem'), throwsStateError);
    });

    test('validates typed core export alias signatures', () {
      final baseComponent = _componentWithCoreModules(
        <Uint8List>[_coreModuleConstI32(name: 'one', value: 9)],
        instantiateModuleIndices: const [0],
        exportAliases: const [
          _ComponentAliasSpec(
            instanceIndex: 0,
            coreExportName: 'one',
            componentExportName: 'apiOne',
          ),
        ],
      );
      final typeSection = <int>[
        ..._u32Leb(1),
        ..._name('fn_i32'),
        0x01,
        ..._u32Leb(0),
        ..._u32Leb(1),
        0x7f,
      ];
      final typeBindingSection = <int>[
        ..._u32Leb(1),
        0x01,
        ..._u32Leb(0),
        ..._u32Leb(0),
      ];
      final componentBytes = Uint8List.fromList(<int>[
        ...baseComponent,
        ..._section(0x06, typeSection),
        ..._section(0x07, typeBindingSection),
      ]);

      final instance = WasmComponentInstance.fromBytes(
        componentBytes,
        features: const WasmFeatureSet(componentModel: true),
      );
      expect(instance.invokeComponentExport('apiOne'), 9);
    });

    test('rejects mismatched typed core export alias signatures', () {
      final baseComponent = _componentWithCoreModules(
        <Uint8List>[_coreModuleConstI32(name: 'one', value: 9)],
        instantiateModuleIndices: const [0],
        exportAliases: const [
          _ComponentAliasSpec(
            instanceIndex: 0,
            coreExportName: 'one',
            componentExportName: 'apiOne',
          ),
        ],
      );
      final typeSection = <int>[
        ..._u32Leb(1),
        ..._name('fn_i64'),
        0x01,
        ..._u32Leb(0),
        ..._u32Leb(1),
        0x7e,
      ];
      final typeBindingSection = <int>[
        ..._u32Leb(1),
        0x01,
        ..._u32Leb(0),
        ..._u32Leb(0),
      ];
      final componentBytes = Uint8List.fromList(<int>[
        ...baseComponent,
        ..._section(0x06, typeSection),
        ..._section(0x07, typeBindingSection),
      ]);

      expect(
        () => WasmComponentInstance.fromBytes(
          componentBytes,
          features: const WasmFeatureSet(componentModel: true),
        ),
        throwsFormatException,
      );
    });

    test(
      'validates typed core export alias bindings for non-function exports',
      () {
        final baseComponent = _componentWithCoreModules(
          <Uint8List>[
            _coreModuleExportMemory(name: 'mem', minPages: 1, maxPages: 2),
            _coreModuleExportTable(name: 'tab', min: 1, max: 3),
            _coreModuleExportGlobalI32(name: 'g', value: 11),
            _coreModuleExportTag(name: 'err', paramType: 0x7f),
          ],
          instantiateModuleIndices: const [0, 1, 2, 3],
          exportAliases: const [
            _ComponentAliasSpec(
              instanceIndex: 0,
              coreExportName: 'mem',
              componentExportName: 'apiMem',
            ),
            _ComponentAliasSpec(
              instanceIndex: 1,
              coreExportName: 'tab',
              componentExportName: 'apiTab',
            ),
            _ComponentAliasSpec(
              instanceIndex: 2,
              coreExportName: 'g',
              componentExportName: 'apiGlobal',
            ),
            _ComponentAliasSpec(
              instanceIndex: 3,
              coreExportName: 'err',
              componentExportName: 'apiTag',
            ),
          ],
        );
        final typeSection = <int>[
          ..._u32Leb(4),
          ..._name('mem_t'),
          0x03, // memory
          0x01, // has max
          ..._u32Leb(1),
          ..._u32Leb(2),
          ..._name('tab_t'),
          0x04, // table
          0x70, // funcref
          0x01, // has max
          ..._u32Leb(1),
          ..._u32Leb(3),
          ..._name('g_t'),
          0x00, // value
          0x7f, // i32
          ..._name('tag_t'),
          0x05, // tag
          ..._u32Leb(1),
          0x7f, // i32
        ];
        final typeBindingSection = <int>[
          ..._u32Leb(4),
          0x01,
          ..._u32Leb(0),
          ..._u32Leb(0),
          0x01,
          ..._u32Leb(1),
          ..._u32Leb(1),
          0x01,
          ..._u32Leb(2),
          ..._u32Leb(2),
          0x01,
          ..._u32Leb(3),
          ..._u32Leb(3),
        ];
        final componentBytes = Uint8List.fromList(<int>[
          ...baseComponent,
          ..._section(0x06, typeSection),
          ..._section(0x07, typeBindingSection),
        ]);

        final instance = WasmComponentInstance.fromBytes(
          componentBytes,
          features: const WasmFeatureSet(componentModel: true),
        );
        expect(instance.componentExportMemory('apiMem').maxPages, 2);
        expect(instance.componentExportTable('apiTab').max, 3);
        expect(instance.readComponentExportGlobal('apiGlobal'), 11);
        expect(
          instance.componentExportTag('apiTag').type.params,
          orderedEquals(const <WasmValueType>[WasmValueType.i32]),
        );
      },
    );

    test(
      'rejects mismatched typed core export alias bindings for non-function exports',
      () {
        final baseComponent = _componentWithCoreModules(
          <Uint8List>[
            _coreModuleExportMemory(name: 'mem', minPages: 1, maxPages: 2),
          ],
          instantiateModuleIndices: const [0],
          exportAliases: const [
            _ComponentAliasSpec(
              instanceIndex: 0,
              coreExportName: 'mem',
              componentExportName: 'apiMem',
            ),
          ],
        );
        final typeSection = <int>[
          ..._u32Leb(1),
          ..._name('mem_t'),
          0x03, // memory
          0x01, // has max
          ..._u32Leb(1),
          ..._u32Leb(1), // tighter max than actual max=2
        ];
        final typeBindingSection = <int>[
          ..._u32Leb(1),
          0x01,
          ..._u32Leb(0),
          ..._u32Leb(0),
        ];
        final componentBytes = Uint8List.fromList(<int>[
          ...baseComponent,
          ..._section(0x06, typeSection),
          ..._section(0x07, typeBindingSection),
        ]);

        expect(
          () => WasmComponentInstance.fromBytes(
            componentBytes,
            features: const WasmFeatureSet(componentModel: true),
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'validates typed core export alias bindings for reference global exports',
      () {
        final baseComponent = _componentWithCoreModules(
          <Uint8List>[
            _coreModuleExportGlobal(
              name: 'gref',
              valueType: 0x70,
              mutable: false,
              initOpcode: 0xd0,
              value: 0x70,
            ),
          ],
          instantiateModuleIndices: const [0],
          exportAliases: const [
            _ComponentAliasSpec(
              instanceIndex: 0,
              coreExportName: 'gref',
              componentExportName: 'apiGref',
            ),
          ],
        );
        final typeSection = <int>[
          ..._u32Leb(1),
          ..._name('funcref_t'),
          0x00, // value
          0x70, // funcref
        ];
        final typeBindingSection = <int>[
          ..._u32Leb(1),
          0x01, // coreExportAlias
          ..._u32Leb(0),
          ..._u32Leb(0),
        ];
        final componentBytes = Uint8List.fromList(<int>[
          ...baseComponent,
          ..._section(0x06, typeSection),
          ..._section(0x07, typeBindingSection),
        ]);

        final instance = WasmComponentInstance.fromBytes(
          componentBytes,
          features: const WasmFeatureSet(componentModel: true),
        );
        expect(
          instance.componentExportKind('apiGref'),
          WasmComponentImportKind.global,
        );
        expect(instance.readComponentExportGlobal('apiGref'), -1);
      },
    );

    test(
      'rejects mismatched typed core export alias bindings for reference global exports',
      () {
        final baseComponent = _componentWithCoreModules(
          <Uint8List>[
            _coreModuleExportGlobal(
              name: 'gref',
              valueType: 0x70,
              mutable: false,
              initOpcode: 0xd0,
              value: 0x70,
            ),
          ],
          instantiateModuleIndices: const [0],
          exportAliases: const [
            _ComponentAliasSpec(
              instanceIndex: 0,
              coreExportName: 'gref',
              componentExportName: 'apiGref',
            ),
          ],
        );
        final typeSection = <int>[
          ..._u32Leb(1),
          ..._name('externref_t'),
          0x00, // value
          0x6f, // externref
        ];
        final typeBindingSection = <int>[
          ..._u32Leb(1),
          0x01, // coreExportAlias
          ..._u32Leb(0),
          ..._u32Leb(0),
        ];
        final componentBytes = Uint8List.fromList(<int>[
          ...baseComponent,
          ..._section(0x06, typeSection),
          ..._section(0x07, typeBindingSection),
        ]);

        expect(
          () => WasmComponentInstance.fromBytes(
            componentBytes,
            features: const WasmFeatureSet(componentModel: true),
          ),
          throwsFormatException,
        );
      },
    );

    test('validates component import requirements before instantiation', () {
      final componentBytes = _componentWithCoreModules(
        <Uint8List>[_coreModuleConstI32(name: 'one', value: 1)],
        importRequirements: const [
          _ComponentImportRequirementSpec(
            componentImportName: 'incFn',
            moduleName: 'host',
            fieldName: 'inc',
            kind: 0x00,
          ),
        ],
      );

      expect(
        () => WasmComponentInstance.fromBytes(
          componentBytes,
          features: const WasmFeatureSet(componentModel: true),
        ),
        throwsFormatException,
      );

      final satisfied = WasmComponentInstance.fromBytes(
        componentBytes,
        imports: WasmImports(
          functions: {
            WasmImports.key('host', 'inc'): (args) => (args.single as int) + 1,
          },
        ),
        features: const WasmFeatureSet(componentModel: true),
      );
      expect(satisfied.invokeCore('one'), 1);
    });

    test(
      'validates typed global import requirements against provided values',
      () {
        final baseComponent = _componentWithCoreModules(
          <Uint8List>[_coreModuleConstI32(name: 'one', value: 1)],
          importRequirements: const [
            _ComponentImportRequirementSpec(
              componentImportName: 'globalI32',
              moduleName: 'env',
              fieldName: 'g',
              kind: 0x03,
            ),
          ],
        );
        final typeSection = <int>[..._u32Leb(1), ..._name('i32_t'), 0x00, 0x7f];
        final typeBindingSection = <int>[
          ..._u32Leb(1),
          0x00,
          ..._u32Leb(0),
          ..._u32Leb(0),
        ];
        final componentBytes = Uint8List.fromList(<int>[
          ...baseComponent,
          ..._section(0x06, typeSection),
          ..._section(0x07, typeBindingSection),
        ]);

        expect(
          () => WasmComponentInstance.fromBytes(
            componentBytes,
            imports: const WasmImports(globals: {'env::g': 'not-an-i32'}),
            features: const WasmFeatureSet(componentModel: true),
          ),
          throwsFormatException,
        );

        final instance = WasmComponentInstance.fromBytes(
          componentBytes,
          imports: const WasmImports(globals: {'env::g': 7}),
          features: const WasmFeatureSet(componentModel: true),
        );
        expect(instance.invokeCore('one'), 1);
      },
    );

    test(
      'validates typed global reference import requirements via globalTypes signatures',
      () {
        final baseComponent = _componentWithCoreModules(
          <Uint8List>[_coreModuleConstI32(name: 'one', value: 1)],
          importRequirements: const [
            _ComponentImportRequirementSpec(
              componentImportName: 'globalFuncref',
              moduleName: 'env',
              fieldName: 'gref',
              kind: 0x03,
            ),
          ],
        );
        final typeSection = <int>[
          ..._u32Leb(1),
          ..._name('funcref_t'),
          0x00,
          0x70,
        ];
        final typeBindingSection = <int>[
          ..._u32Leb(1),
          0x00,
          ..._u32Leb(0),
          ..._u32Leb(0),
        ];
        final componentBytes = Uint8List.fromList(<int>[
          ...baseComponent,
          ..._section(0x06, typeSection),
          ..._section(0x07, typeBindingSection),
        ]);

        expect(
          () => WasmComponentInstance.fromBytes(
            componentBytes,
            imports: const WasmImports(globals: {'env::gref': -1}),
            features: const WasmFeatureSet(componentModel: true),
          ),
          throwsA(isA<UnsupportedError>()),
        );

        expect(
          () => WasmComponentInstance.fromBytes(
            componentBytes,
            imports: const WasmImports(
              globals: {'env::gref': -1},
              globalTypes: {
                'env::gref': WasmGlobalType(
                  valueType: WasmValueType.i32,
                  mutable: false,
                  valueTypeSignature: '6f',
                ),
              },
            ),
            features: const WasmFeatureSet(componentModel: true),
          ),
          throwsFormatException,
        );

        final instance = WasmComponentInstance.fromBytes(
          componentBytes,
          imports: const WasmImports(
            globals: {'env::gref': -1},
            globalTypes: {
              'env::gref': WasmGlobalType(
                valueType: WasmValueType.i32,
                mutable: false,
                valueTypeSignature: '70',
              ),
            },
          ),
          features: const WasmFeatureSet(componentModel: true),
        );
        expect(instance.invokeCore('one'), 1);
      },
    );

    test(
      'rejects typed global reference imports when globalTypes carrier is non-i32',
      () {
        final baseComponent = _componentWithCoreModules(
          <Uint8List>[_coreModuleConstI32(name: 'one', value: 1)],
          importRequirements: const [
            _ComponentImportRequirementSpec(
              componentImportName: 'globalFuncref',
              moduleName: 'env',
              fieldName: 'gref',
              kind: 0x03,
            ),
          ],
        );
        final typeSection = <int>[
          ..._u32Leb(1),
          ..._name('funcref_t'),
          0x00,
          0x70,
        ];
        final typeBindingSection = <int>[
          ..._u32Leb(1),
          0x00,
          ..._u32Leb(0),
          ..._u32Leb(0),
        ];
        final componentBytes = Uint8List.fromList(<int>[
          ...baseComponent,
          ..._section(0x06, typeSection),
          ..._section(0x07, typeBindingSection),
        ]);

        expect(
          () => WasmComponentInstance.fromBytes(
            componentBytes,
            imports: const WasmImports(
              globals: {'env::gref': -1},
              globalTypes: {
                'env::gref': WasmGlobalType(
                  valueType: WasmValueType.i64,
                  mutable: false,
                  valueTypeSignature: '70',
                ),
              },
            ),
            features: const WasmFeatureSet(componentModel: true),
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'rejects typed global reference imports when globalBindings/globalTypes carriers differ',
      () {
        final baseComponent = _componentWithCoreModules(
          <Uint8List>[_coreModuleConstI32(name: 'one', value: 1)],
          importRequirements: const [
            _ComponentImportRequirementSpec(
              componentImportName: 'globalFuncref',
              moduleName: 'env',
              fieldName: 'gref',
              kind: 0x03,
            ),
          ],
        );
        final typeSection = <int>[
          ..._u32Leb(1),
          ..._name('funcref_t'),
          0x00,
          0x70,
        ];
        final typeBindingSection = <int>[
          ..._u32Leb(1),
          0x00,
          ..._u32Leb(0),
          ..._u32Leb(0),
        ];
        final componentBytes = Uint8List.fromList(<int>[
          ...baseComponent,
          ..._section(0x06, typeSection),
          ..._section(0x07, typeBindingSection),
        ]);

        expect(
          () => WasmComponentInstance.fromBytes(
            componentBytes,
            imports: WasmImports(
              globalBindings: {
                'env::gref': RuntimeGlobal(
                  valueType: WasmValueType.i64,
                  mutable: false,
                  value: WasmValue.i64(0),
                ),
              },
              globalTypes: const {
                'env::gref': WasmGlobalType(
                  valueType: WasmValueType.i32,
                  mutable: false,
                  valueTypeSignature: '70',
                ),
              },
            ),
            features: const WasmFeatureSet(componentModel: true),
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'validates typed global imports with multi-byte reference signatures',
      () {
        final baseComponent = _componentWithCoreModules(
          <Uint8List>[_coreModuleConstI32(name: 'one', value: 1)],
          importRequirements: const [
            _ComponentImportRequirementSpec(
              componentImportName: 'globalTypedRef',
              moduleName: 'env',
              fieldName: 'gtyped',
              kind: 0x03,
            ),
          ],
        );
        final typeSection = <int>[
          ..._u32Leb(1),
          ..._name('typed_ref_t'),
          0x00, // value
          0x63, // ref null
          0x00, // heaptype = type index 0
        ];
        final typeBindingSection = <int>[
          ..._u32Leb(1),
          0x00, // importRequirement
          ..._u32Leb(0),
          ..._u32Leb(0),
        ];
        final componentBytes = Uint8List.fromList(<int>[
          ...baseComponent,
          ..._section(0x06, typeSection),
          ..._section(0x07, typeBindingSection),
        ]);

        expect(
          () => WasmComponentInstance.fromBytes(
            componentBytes,
            imports: const WasmImports(
              globals: {'env::gtyped': -1},
              globalTypes: {
                'env::gtyped': WasmGlobalType(
                  valueType: WasmValueType.i32,
                  mutable: false,
                  valueTypeSignature: '6301',
                ),
              },
            ),
            features: const WasmFeatureSet(componentModel: true),
          ),
          throwsFormatException,
        );

        final instance = WasmComponentInstance.fromBytes(
          componentBytes,
          imports: const WasmImports(
            globals: {'env::gtyped': -1},
            globalTypes: {
              'env::gtyped': WasmGlobalType(
                valueType: WasmValueType.i32,
                mutable: false,
                valueTypeSignature: '6300',
              ),
            },
          ),
          features: const WasmFeatureSet(componentModel: true),
        );
        expect(instance.invokeCore('one'), 1);
      },
    );

    test(
      'validates typed function import requirements against core module signatures',
      () {
        final baseComponent = _componentWithCoreModules(
          <Uint8List>[
            _coreModuleCallImportedNullary(
              importModule: 'host',
              importName: 'inc',
              exportName: 'run',
            ),
          ],
          importRequirements: const [
            _ComponentImportRequirementSpec(
              componentImportName: 'incFn',
              moduleName: 'host',
              fieldName: 'inc',
              kind: 0x00,
            ),
          ],
        );
        final typeSection = <int>[
          ..._u32Leb(1),
          ..._name('fn_i32'),
          0x01,
          ..._u32Leb(0),
          ..._u32Leb(1),
          0x7f,
        ];
        final typeBindingSection = <int>[
          ..._u32Leb(1),
          0x00,
          ..._u32Leb(0),
          ..._u32Leb(0),
        ];
        final componentBytes = Uint8List.fromList(<int>[
          ...baseComponent,
          ..._section(0x06, typeSection),
          ..._section(0x07, typeBindingSection),
        ]);

        final instance = WasmComponentInstance.fromBytes(
          componentBytes,
          imports: WasmImports(
            functions: {WasmImports.key('host', 'inc'): (_) => 11},
          ),
          features: const WasmFeatureSet(componentModel: true),
        );
        expect(instance.invokeCore('run'), 11);
      },
    );

    test(
      'rejects mismatched typed function import requirements against core module signatures',
      () {
        final baseComponent = _componentWithCoreModules(
          <Uint8List>[
            _coreModuleCallImportedNullary(
              importModule: 'host',
              importName: 'inc',
              exportName: 'run',
            ),
          ],
          importRequirements: const [
            _ComponentImportRequirementSpec(
              componentImportName: 'incFn',
              moduleName: 'host',
              fieldName: 'inc',
              kind: 0x00,
            ),
          ],
        );
        final typeSection = <int>[
          ..._u32Leb(1),
          ..._name('fn_i64'),
          0x01,
          ..._u32Leb(0),
          ..._u32Leb(1),
          0x7e,
        ];
        final typeBindingSection = <int>[
          ..._u32Leb(1),
          0x00,
          ..._u32Leb(0),
          ..._u32Leb(0),
        ];
        final componentBytes = Uint8List.fromList(<int>[
          ...baseComponent,
          ..._section(0x06, typeSection),
          ..._section(0x07, typeBindingSection),
        ]);

        expect(
          () => WasmComponentInstance.fromBytes(
            componentBytes,
            imports: WasmImports(
              functions: {WasmImports.key('host', 'inc'): (_) => 11},
            ),
            features: const WasmFeatureSet(componentModel: true),
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'rejects mismatched typed memory import requirements against core module signatures',
      () {
        final baseComponent = _componentWithCoreModules(
          <Uint8List>[
            _coreModuleImportMemoryAndConst(
              importModule: 'env',
              importName: 'mem',
              minPages: 2,
              maxPages: 2,
              exportName: 'run',
              value: 1,
            ),
          ],
          importRequirements: const [
            _ComponentImportRequirementSpec(
              componentImportName: 'memory',
              moduleName: 'env',
              fieldName: 'mem',
              kind: 0x01,
            ),
          ],
        );
        final typeSection = <int>[
          ..._u32Leb(1),
          ..._name('mem_t'),
          0x03,
          0x01,
          ..._u32Leb(1),
          ..._u32Leb(1),
        ];
        final typeBindingSection = <int>[
          ..._u32Leb(1),
          0x00,
          ..._u32Leb(0),
          ..._u32Leb(0),
        ];
        final componentBytes = Uint8List.fromList(<int>[
          ...baseComponent,
          ..._section(0x06, typeSection),
          ..._section(0x07, typeBindingSection),
        ]);

        expect(
          () => WasmComponentInstance.fromBytes(
            componentBytes,
            imports: WasmImports(
              memories: {
                WasmImports.key('env', 'mem'): WasmMemory(
                  minPages: 1,
                  maxPages: 1,
                ),
              },
            ),
            features: const WasmFeatureSet(componentModel: true),
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'rejects mismatched typed table import requirements against core module signatures',
      () {
        final baseComponent = _componentWithCoreModules(
          <Uint8List>[
            _coreModuleImportTableAndConst(
              importModule: 'env',
              importName: 'tab',
              min: 2,
              max: 2,
              exportName: 'run',
              value: 1,
            ),
          ],
          importRequirements: const [
            _ComponentImportRequirementSpec(
              componentImportName: 'table',
              moduleName: 'env',
              fieldName: 'tab',
              kind: 0x02,
            ),
          ],
        );
        final typeSection = <int>[
          ..._u32Leb(1),
          ..._name('tab_t'),
          0x04,
          0x70,
          0x01,
          ..._u32Leb(1),
          ..._u32Leb(1),
        ];
        final typeBindingSection = <int>[
          ..._u32Leb(1),
          0x00,
          ..._u32Leb(0),
          ..._u32Leb(0),
        ];
        final componentBytes = Uint8List.fromList(<int>[
          ...baseComponent,
          ..._section(0x06, typeSection),
          ..._section(0x07, typeBindingSection),
        ]);

        expect(
          () => WasmComponentInstance.fromBytes(
            componentBytes,
            imports: WasmImports(
              tables: {
                WasmImports.key('env', 'tab'): WasmTable(
                  refType: WasmRefType.funcref,
                  min: 1,
                  max: 1,
                ),
              },
            ),
            features: const WasmFeatureSet(componentModel: true),
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'rejects mismatched typed global import requirements against core module signatures',
      () {
        final baseComponent = _componentWithCoreModules(
          <Uint8List>[
            _coreModuleImportGlobalAndConst(
              importModule: 'env',
              importName: 'g',
              valueType: 0x7e,
              mutable: false,
              exportName: 'run',
              value: 1,
            ),
          ],
          importRequirements: const [
            _ComponentImportRequirementSpec(
              componentImportName: 'globalI32',
              moduleName: 'env',
              fieldName: 'g',
              kind: 0x03,
            ),
          ],
        );
        final typeSection = <int>[..._u32Leb(1), ..._name('i32_t'), 0x00, 0x7f];
        final typeBindingSection = <int>[
          ..._u32Leb(1),
          0x00,
          ..._u32Leb(0),
          ..._u32Leb(0),
        ];
        final componentBytes = Uint8List.fromList(<int>[
          ...baseComponent,
          ..._section(0x06, typeSection),
          ..._section(0x07, typeBindingSection),
        ]);

        expect(
          () => WasmComponentInstance.fromBytes(
            componentBytes,
            imports: const WasmImports(globals: {'env::g': 7}),
            features: const WasmFeatureSet(componentModel: true),
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'rejects mismatched typed tag import requirements against core module signatures',
      () {
        final baseComponent = _componentWithCoreModules(
          <Uint8List>[
            _coreModuleImportTagAndConst(
              importModule: 'env',
              importName: 'err',
              expectedParamType: 0x7e,
              exportName: 'run',
              value: 1,
            ),
          ],
          importRequirements: const [
            _ComponentImportRequirementSpec(
              componentImportName: 'tag',
              moduleName: 'env',
              fieldName: 'err',
              kind: 0x04,
            ),
          ],
        );
        final typeSection = <int>[
          ..._u32Leb(1),
          ..._name('tag_t'),
          0x05,
          ..._u32Leb(1),
          0x7f,
        ];
        final typeBindingSection = <int>[
          ..._u32Leb(1),
          0x00,
          ..._u32Leb(0),
          ..._u32Leb(0),
        ];
        final componentBytes = Uint8List.fromList(<int>[
          ...baseComponent,
          ..._section(0x06, typeSection),
          ..._section(0x07, typeBindingSection),
        ]);

        expect(
          () => WasmComponentInstance.fromBytes(
            componentBytes,
            imports: WasmImports(
              tags: {
                WasmImports.key('env', 'err'): WasmTagImport(
                  type: const WasmFunctionType(
                    params: [WasmValueType.i32],
                    results: [],
                    kind: WasmCompositeTypeKind.function,
                  ),
                  nominalTypeKey: 'tag:i32',
                  typeKey: 'tag:i32',
                ),
              },
            ),
            features: const WasmFeatureSet(componentModel: true),
          ),
          throwsFormatException,
        );
      },
    );

    test('rejects conflicting typed global import bindings', () {
      final baseComponent = _componentWithCoreModules(
        <Uint8List>[_coreModuleConstI32(name: 'one', value: 1)],
        importRequirements: const [
          _ComponentImportRequirementSpec(
            componentImportName: 'globalI32',
            moduleName: 'env',
            fieldName: 'g',
            kind: 0x03,
          ),
          _ComponentImportRequirementSpec(
            componentImportName: 'globalI64',
            moduleName: 'env',
            fieldName: 'g',
            kind: 0x03,
          ),
        ],
      );
      final typeSection = <int>[
        ..._u32Leb(2),
        ..._name('i32_t'),
        0x00,
        0x7f,
        ..._name('i64_t'),
        0x00,
        0x7e,
      ];
      final typeBindingSection = <int>[
        ..._u32Leb(2),
        0x00,
        ..._u32Leb(0),
        ..._u32Leb(0),
        0x00,
        ..._u32Leb(1),
        ..._u32Leb(1),
      ];
      final componentBytes = Uint8List.fromList(<int>[
        ...baseComponent,
        ..._section(0x06, typeSection),
        ..._section(0x07, typeBindingSection),
      ]);

      expect(
        () => WasmComponentInstance.fromBytes(
          componentBytes,
          imports: const WasmImports(globals: {'env::g': 7}),
          features: const WasmFeatureSet(componentModel: true),
        ),
        throwsFormatException,
      );
    });

    test('rejects conflicting typed memory import bindings', () {
      final baseComponent = _componentWithCoreModules(
        <Uint8List>[_coreModuleConstI32(name: 'one', value: 1)],
        importRequirements: const [
          _ComponentImportRequirementSpec(
            componentImportName: 'memoryA',
            moduleName: 'env',
            fieldName: 'mem',
            kind: 0x01,
          ),
          _ComponentImportRequirementSpec(
            componentImportName: 'memoryB',
            moduleName: 'env',
            fieldName: 'mem',
            kind: 0x01,
          ),
        ],
      );
      final typeSection = <int>[
        ..._u32Leb(2),
        ..._name('memA'),
        0x03,
        0x01,
        ..._u32Leb(1),
        ..._u32Leb(2),
        ..._name('memB'),
        0x03,
        0x01,
        ..._u32Leb(1),
        ..._u32Leb(3),
      ];
      final typeBindingSection = <int>[
        ..._u32Leb(2),
        0x00,
        ..._u32Leb(0),
        ..._u32Leb(0),
        0x00,
        ..._u32Leb(1),
        ..._u32Leb(1),
      ];
      final componentBytes = Uint8List.fromList(<int>[
        ...baseComponent,
        ..._section(0x06, typeSection),
        ..._section(0x07, typeBindingSection),
      ]);

      expect(
        () => WasmComponentInstance.fromBytes(
          componentBytes,
          imports: WasmImports(
            memories: {
              WasmImports.key('env', 'mem'): WasmMemory(
                minPages: 1,
                maxPages: 2,
              ),
            },
          ),
          features: const WasmFeatureSet(componentModel: true),
        ),
        throwsFormatException,
      );
    });

    test('rejects conflicting typed table import bindings', () {
      final baseComponent = _componentWithCoreModules(
        <Uint8List>[_coreModuleConstI32(name: 'one', value: 1)],
        importRequirements: const [
          _ComponentImportRequirementSpec(
            componentImportName: 'tableA',
            moduleName: 'env',
            fieldName: 'tab',
            kind: 0x02,
          ),
          _ComponentImportRequirementSpec(
            componentImportName: 'tableB',
            moduleName: 'env',
            fieldName: 'tab',
            kind: 0x02,
          ),
        ],
      );
      final typeSection = <int>[
        ..._u32Leb(2),
        ..._name('tabA'),
        0x04,
        0x70,
        0x01,
        ..._u32Leb(1),
        ..._u32Leb(2),
        ..._name('tabB'),
        0x04,
        0x70,
        0x01,
        ..._u32Leb(1),
        ..._u32Leb(3),
      ];
      final typeBindingSection = <int>[
        ..._u32Leb(2),
        0x00,
        ..._u32Leb(0),
        ..._u32Leb(0),
        0x00,
        ..._u32Leb(1),
        ..._u32Leb(1),
      ];
      final componentBytes = Uint8List.fromList(<int>[
        ...baseComponent,
        ..._section(0x06, typeSection),
        ..._section(0x07, typeBindingSection),
      ]);

      expect(
        () => WasmComponentInstance.fromBytes(
          componentBytes,
          imports: WasmImports(
            tables: {
              WasmImports.key('env', 'tab'): WasmTable(
                refType: WasmRefType.funcref,
                min: 1,
                max: 2,
              ),
            },
          ),
          features: const WasmFeatureSet(componentModel: true),
        ),
        throwsFormatException,
      );
    });

    test(
      'rejects conflicting typed tag import bindings before import resolution',
      () {
        final baseComponent = _componentWithCoreModules(
          <Uint8List>[_coreModuleConstI32(name: 'one', value: 1)],
          importRequirements: const [
            _ComponentImportRequirementSpec(
              componentImportName: 'tagA',
              moduleName: 'env',
              fieldName: 'err',
              kind: 0x04,
            ),
            _ComponentImportRequirementSpec(
              componentImportName: 'tagB',
              moduleName: 'env',
              fieldName: 'err',
              kind: 0x04,
            ),
          ],
        );
        final typeSection = <int>[
          ..._u32Leb(2),
          ..._name('tag_i32'),
          0x05,
          ..._u32Leb(1),
          0x7f,
          ..._name('tag_i64'),
          0x05,
          ..._u32Leb(1),
          0x7e,
        ];
        final typeBindingSection = <int>[
          ..._u32Leb(2),
          0x00,
          ..._u32Leb(0),
          ..._u32Leb(0),
          0x00,
          ..._u32Leb(1),
          ..._u32Leb(1),
        ];
        final componentBytes = Uint8List.fromList(<int>[
          ...baseComponent,
          ..._section(0x06, typeSection),
          ..._section(0x07, typeBindingSection),
        ]);

        expect(
          () => WasmComponentInstance.fromBytes(
            componentBytes,
            features: const WasmFeatureSet(componentModel: true),
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('Conflicting typed tag bindings'),
            ),
          ),
        );
      },
    );

    test('resolves typed tag import bindings through type aliases', () {
      final baseComponent = _componentWithCoreModules(
        <Uint8List>[_coreModuleConstI32(name: 'one', value: 1)],
        importRequirements: const [
          _ComponentImportRequirementSpec(
            componentImportName: 'tag',
            moduleName: 'env',
            fieldName: 'err',
            kind: 0x04,
          ),
        ],
      );
      final typeSection = <int>[
        ..._u32Leb(2),
        ..._name('tag_base'),
        0x05,
        ..._u32Leb(1),
        0x7f,
        ..._name('tag_alias'),
        0x02,
        ..._u32Leb(0),
      ];
      final typeBindingSection = <int>[
        ..._u32Leb(1),
        0x00,
        ..._u32Leb(0),
        ..._u32Leb(1),
      ];
      final componentBytes = Uint8List.fromList(<int>[
        ...baseComponent,
        ..._section(0x06, typeSection),
        ..._section(0x07, typeBindingSection),
      ]);

      final instance = WasmComponentInstance.fromBytes(
        componentBytes,
        imports: WasmImports(
          tags: {
            WasmImports.key('env', 'err'): WasmTagImport(
              type: const WasmFunctionType(
                params: [WasmValueType.i32],
                results: [],
                kind: WasmCompositeTypeKind.function,
              ),
              nominalTypeKey: 'tag:i32',
              typeKey: 'tag:i32',
            ),
          },
        ),
        features: const WasmFeatureSet(componentModel: true),
      );
      expect(instance.invokeCore('one'), 1);
    });

    test(
      'validates typed memory import requirements against provided memories',
      () {
        final baseComponent = _componentWithCoreModules(
          <Uint8List>[_coreModuleConstI32(name: 'one', value: 1)],
          importRequirements: const [
            _ComponentImportRequirementSpec(
              componentImportName: 'memory',
              moduleName: 'env',
              fieldName: 'mem',
              kind: 0x01,
            ),
          ],
        );
        final typeSection = <int>[
          ..._u32Leb(1),
          ..._name('mem_t'),
          0x03, // memory
          0x01, // has max
          ..._u32Leb(1),
          ..._u32Leb(2),
        ];
        final typeBindingSection = <int>[
          ..._u32Leb(1),
          0x00,
          ..._u32Leb(0),
          ..._u32Leb(0),
        ];
        final componentBytes = Uint8List.fromList(<int>[
          ...baseComponent,
          ..._section(0x06, typeSection),
          ..._section(0x07, typeBindingSection),
        ]);

        expect(
          () => WasmComponentInstance.fromBytes(
            componentBytes,
            imports: WasmImports(
              memories: {
                WasmImports.key('env', 'mem'): WasmMemory(
                  minPages: 1,
                  maxPages: 3,
                ),
              },
            ),
            features: const WasmFeatureSet(componentModel: true),
          ),
          throwsFormatException,
        );

        final instance = WasmComponentInstance.fromBytes(
          componentBytes,
          imports: WasmImports(
            memories: {
              WasmImports.key('env', 'mem'): WasmMemory(
                minPages: 1,
                maxPages: 2,
              ),
            },
          ),
          features: const WasmFeatureSet(componentModel: true),
        );
        expect(instance.invokeCore('one'), 1);
      },
    );

    test(
      'validates typed table import requirements against provided tables',
      () {
        final baseComponent = _componentWithCoreModules(
          <Uint8List>[_coreModuleConstI32(name: 'one', value: 1)],
          importRequirements: const [
            _ComponentImportRequirementSpec(
              componentImportName: 'table',
              moduleName: 'env',
              fieldName: 'tab',
              kind: 0x02,
            ),
          ],
        );
        final typeSection = <int>[
          ..._u32Leb(1),
          ..._name('tab_t'),
          0x04, // table
          0x70, // funcref
          0x01, // has max
          ..._u32Leb(1),
          ..._u32Leb(2),
        ];
        final typeBindingSection = <int>[
          ..._u32Leb(1),
          0x00,
          ..._u32Leb(0),
          ..._u32Leb(0),
        ];
        final componentBytes = Uint8List.fromList(<int>[
          ...baseComponent,
          ..._section(0x06, typeSection),
          ..._section(0x07, typeBindingSection),
        ]);

        expect(
          () => WasmComponentInstance.fromBytes(
            componentBytes,
            imports: WasmImports(
              tables: {
                WasmImports.key('env', 'tab'): WasmTable(
                  refType: WasmRefType.funcref,
                  min: 0,
                  max: 2,
                ),
              },
            ),
            features: const WasmFeatureSet(componentModel: true),
          ),
          throwsFormatException,
        );

        final instance = WasmComponentInstance.fromBytes(
          componentBytes,
          imports: WasmImports(
            tables: {
              WasmImports.key('env', 'tab'): WasmTable(
                refType: WasmRefType.funcref,
                min: 1,
                max: 2,
              ),
            },
          ),
          features: const WasmFeatureSet(componentModel: true),
        );
        expect(instance.invokeCore('one'), 1);
      },
    );

    test('validates typed tag import requirements against provided tags', () {
      final baseComponent = _componentWithCoreModules(
        <Uint8List>[_coreModuleConstI32(name: 'one', value: 1)],
        importRequirements: const [
          _ComponentImportRequirementSpec(
            componentImportName: 'tag',
            moduleName: 'env',
            fieldName: 'err',
            kind: 0x04,
          ),
        ],
      );
      final typeSection = <int>[
        ..._u32Leb(1),
        ..._name('tag_t'),
        0x05, // tag
        ..._u32Leb(1), // params
        0x7f, // i32
      ];
      final typeBindingSection = <int>[
        ..._u32Leb(1),
        0x00,
        ..._u32Leb(0),
        ..._u32Leb(0),
      ];
      final componentBytes = Uint8List.fromList(<int>[
        ...baseComponent,
        ..._section(0x06, typeSection),
        ..._section(0x07, typeBindingSection),
      ]);

      expect(
        () => WasmComponentInstance.fromBytes(
          componentBytes,
          imports: WasmImports(
            tags: {
              WasmImports.key('env', 'err'): WasmTagImport(
                type: const WasmFunctionType(
                  params: [WasmValueType.i64],
                  results: [],
                  kind: WasmCompositeTypeKind.function,
                ),
                nominalTypeKey: 'tag:i64',
                typeKey: 'tag:i64',
              ),
            },
          ),
          features: const WasmFeatureSet(componentModel: true),
        ),
        throwsFormatException,
      );

      final instance = WasmComponentInstance.fromBytes(
        componentBytes,
        imports: WasmImports(
          tags: {
            WasmImports.key('env', 'err'): WasmTagImport(
              type: const WasmFunctionType(
                params: [WasmValueType.i32],
                results: [],
                kind: WasmCompositeTypeKind.function,
              ),
              nominalTypeKey: 'tag:i32',
              typeKey: 'tag:i32',
            ),
          },
        ),
        features: const WasmFeatureSet(componentModel: true),
      );
      expect(instance.invokeCore('one'), 1);
    });

    test('resolves core instances by alias from section 0x05', () {
      final componentBytes = _componentWithCoreModules(
        <Uint8List>[_coreModuleConstI32(name: 'one', value: 1)],
        coreInstanceAliases: const [
          _ComponentInstanceAliasSpec(aliasName: 'main', instanceIndex: 0),
        ],
      );

      final instance = WasmComponentInstance.fromBytes(
        componentBytes,
        features: const WasmFeatureSet(componentModel: true),
      );
      expect(instance.coreInstanceByAlias('main').invoke('one'), 1);
    });

    test('rejects out-of-range core instance alias bindings', () {
      final componentBytes = _componentWithCoreModules(
        <Uint8List>[_coreModuleConstI32(name: 'one', value: 1)],
        coreInstanceAliases: const [
          _ComponentInstanceAliasSpec(aliasName: 'bad', instanceIndex: 1),
        ],
      );

      expect(
        () => WasmComponentInstance.fromBytes(
          componentBytes,
          features: const WasmFeatureSet(componentModel: true),
        ),
        throwsFormatException,
      );
    });

    test('bridges canonical ABI through core export calls', () {
      final componentBytes = _componentWithCoreModules(<Uint8List>[
        _coreModuleEchoUtf8PointerLength(name: 'echo'),
      ]);

      final instance = WasmComponentInstance.fromBytes(
        componentBytes,
        features: const WasmFeatureSet(componentModel: true),
      );

      final lifted = instance.invokeCanonical(
        exportName: 'echo',
        parameterTypes: const [WasmCanonicalAbiType.stringUtf8],
        parameters: const ['hello wasm'],
        resultTypes: const [WasmCanonicalAbiType.stringUtf8],
      );
      expect(lifted, orderedEquals(const <Object?>['hello wasm']));
    });

    test('fails when component has no embedded core module', () {
      final bytes = Uint8List.fromList(<int>[
        0x00,
        0x61,
        0x73,
        0x6d,
        0x0d,
        0x00,
        0x01,
        0x00,
        0x02,
        0x04,
        0x01,
        0x00,
        0x00,
        0x00,
      ]);

      expect(
        () => WasmComponentInstance.fromBytes(
          bytes,
          features: const WasmFeatureSet(componentModel: true),
        ),
        throwsFormatException,
      );
    });
  });
}

Uint8List _componentWithCoreModules(
  List<Uint8List> modules, {
  List<int>? instantiateModuleIndices,
  List<List<int>>? instantiateArgumentInstanceIndices,
  List<_ComponentAliasSpec>? exportAliases,
  List<_ComponentImportRequirementSpec>? importRequirements,
  List<_ComponentInstanceAliasSpec>? coreInstanceAliases,
}) {
  final bytes = <int>[0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00];
  for (final module in modules) {
    bytes.add(0x01);
    bytes.addAll(_u32Leb(module.length));
    bytes.addAll(module);
  }
  final declarations = instantiateModuleIndices;
  if (declarations != null) {
    final payload = <int>[..._u32Leb(declarations.length)];
    for (
      var declarationIndex = 0;
      declarationIndex < declarations.length;
      declarationIndex++
    ) {
      final moduleIndex = declarations[declarationIndex];
      final argumentIndexes =
          instantiateArgumentInstanceIndices != null &&
              declarationIndex < instantiateArgumentInstanceIndices.length
          ? instantiateArgumentInstanceIndices[declarationIndex]
          : const <int>[];
      payload
        ..add(0x00)
        ..addAll(_u32Leb(moduleIndex))
        ..addAll(_u32Leb(argumentIndexes.length));
      for (final argumentIndex in argumentIndexes) {
        payload.addAll(_u32Leb(argumentIndex));
      }
    }
    bytes
      ..add(0x02)
      ..addAll(_u32Leb(payload.length))
      ..addAll(payload);
  }
  final aliases = exportAliases;
  if (aliases != null && aliases.isNotEmpty) {
    final payload = <int>[..._u32Leb(aliases.length)];
    for (final alias in aliases) {
      payload
        ..addAll(_u32Leb(alias.instanceIndex))
        ..addAll(_name(alias.coreExportName))
        ..addAll(_name(alias.componentExportName));
    }
    bytes
      ..add(0x03)
      ..addAll(_u32Leb(payload.length))
      ..addAll(payload);
  }
  final requirements = importRequirements;
  if (requirements != null && requirements.isNotEmpty) {
    final payload = <int>[..._u32Leb(requirements.length)];
    for (final requirement in requirements) {
      payload
        ..addAll(_name(requirement.componentImportName))
        ..addAll(_name(requirement.moduleName))
        ..addAll(_name(requirement.fieldName))
        ..add(requirement.kind);
    }
    bytes
      ..add(0x04)
      ..addAll(_u32Leb(payload.length))
      ..addAll(payload);
  }
  final instanceAliases = coreInstanceAliases;
  if (instanceAliases != null && instanceAliases.isNotEmpty) {
    final payload = <int>[..._u32Leb(instanceAliases.length)];
    for (final alias in instanceAliases) {
      payload
        ..addAll(_name(alias.aliasName))
        ..addAll(_u32Leb(alias.instanceIndex));
    }
    bytes
      ..add(0x05)
      ..addAll(_u32Leb(payload.length))
      ..addAll(payload);
  }
  return Uint8List.fromList(bytes);
}

final class _ComponentAliasSpec {
  const _ComponentAliasSpec({
    required this.instanceIndex,
    required this.coreExportName,
    required this.componentExportName,
  });

  final int instanceIndex;
  final String coreExportName;
  final String componentExportName;
}

final class _ComponentImportRequirementSpec {
  const _ComponentImportRequirementSpec({
    required this.componentImportName,
    required this.moduleName,
    required this.fieldName,
    required this.kind,
  });

  final String componentImportName;
  final String moduleName;
  final String fieldName;
  final int kind;
}

final class _ComponentInstanceAliasSpec {
  const _ComponentInstanceAliasSpec({
    required this.aliasName,
    required this.instanceIndex,
  });

  final String aliasName;
  final int instanceIndex;
}

Uint8List _coreModuleConstI32({required String name, required int value}) {
  final nameBytes = name.codeUnits;
  return Uint8List.fromList(<int>[
    0x00,
    0x61,
    0x73,
    0x6d,
    0x01,
    0x00,
    0x00,
    0x00,
    // type section
    0x01,
    0x05,
    0x01,
    0x60,
    0x00,
    0x01,
    0x7f,
    // function section
    0x03,
    0x02,
    0x01,
    0x00,
    // export section
    0x07,
    0x04 + nameBytes.length,
    0x01,
    nameBytes.length,
    ...nameBytes,
    0x00,
    0x00,
    // code section
    0x0a,
    0x06,
    0x01,
    0x04,
    0x00,
    0x41,
    ..._u32Leb(value),
    0x0b,
  ]);
}

Uint8List _coreModuleConstI64({required String name, required int value}) {
  final nameBytes = name.codeUnits;
  return Uint8List.fromList(<int>[
    0x00,
    0x61,
    0x73,
    0x6d,
    0x01,
    0x00,
    0x00,
    0x00,
    // type section
    0x01,
    0x05,
    0x01,
    0x60,
    0x00,
    0x01,
    0x7e,
    // function section
    0x03,
    0x02,
    0x01,
    0x00,
    // export section
    0x07,
    0x04 + nameBytes.length,
    0x01,
    nameBytes.length,
    ...nameBytes,
    0x00,
    0x00,
    // code section
    0x0a,
    0x06,
    0x01,
    0x04,
    0x00,
    0x42,
    ..._u32Leb(value),
    0x0b,
  ]);
}

Uint8List _coreModuleCallImportedNullary({
  required String importModule,
  required String importName,
  required String exportName,
}) {
  final importSection = <int>[
    ..._u32Leb(1),
    ..._name(importModule),
    ..._name(importName),
    0x00, // function import
    ..._u32Leb(0), // type index
  ];
  final exportSection = <int>[
    ..._u32Leb(1),
    ..._name(exportName),
    0x00, // function export
    ..._u32Leb(1), // function index (after one imported function)
  ];
  final codeBody = <int>[
    0x00, // local decl count
    0x10, // call
    ..._u32Leb(0), // imported function index
    0x0b, // end
  ];
  final codeSection = <int>[
    ..._u32Leb(1),
    ..._u32Leb(codeBody.length),
    ...codeBody,
  ];

  return Uint8List.fromList(<int>[
    0x00,
    0x61,
    0x73,
    0x6d,
    0x01,
    0x00,
    0x00,
    0x00,
    // type section: (func (result i32))
    ..._section(0x01, <int>[0x01, 0x60, 0x00, 0x01, 0x7f]),
    // import section
    ..._section(0x02, importSection),
    // function section: one defined func of type index 0
    ..._section(0x03, <int>[..._u32Leb(1), ..._u32Leb(0)]),
    // export section
    ..._section(0x07, exportSection),
    // code section
    ..._section(0x0a, codeSection),
  ]);
}

Uint8List _coreModuleExportMemory({
  required String name,
  required int minPages,
  int? maxPages,
}) {
  final memoryPayload = <int>[
    ..._u32Leb(1),
    ..._limits(
      flags: maxPages == null ? 0x00 : 0x01,
      min: minPages,
      max: maxPages,
    ),
  ];
  final exportPayload = <int>[
    ..._u32Leb(1),
    ..._name(name),
    WasmExportKind.memory,
    ..._u32Leb(0),
  ];
  return _coreModuleWithSections(<List<int>>[
    _section(0x05, memoryPayload),
    _section(0x07, exportPayload),
  ]);
}

Uint8List _coreModuleImportMemoryAndConst({
  required String importModule,
  required String importName,
  required int minPages,
  int? maxPages,
  required String exportName,
  required int value,
}) {
  final importPayload = <int>[
    ..._u32Leb(1),
    ..._name(importModule),
    ..._name(importName),
    WasmImportKind.memory,
    ..._limits(
      flags: maxPages == null ? 0x00 : 0x01,
      min: minPages,
      max: maxPages,
    ),
  ];
  return _coreModuleConstRunWithImports(
    typeSectionPayload: const <int>[0x01, 0x60, 0x00, 0x01, 0x7f],
    importSectionPayload: importPayload,
    runTypeIndex: 0,
    exportName: exportName,
    value: value,
  );
}

Uint8List _coreModuleExportTable({
  required String name,
  required int min,
  int? max,
  int refType = 0x70,
}) {
  final tablePayload = <int>[
    ..._u32Leb(1),
    refType,
    ..._limits(flags: max == null ? 0x00 : 0x01, min: min, max: max),
  ];
  final exportPayload = <int>[
    ..._u32Leb(1),
    ..._name(name),
    WasmExportKind.table,
    ..._u32Leb(0),
  ];
  return _coreModuleWithSections(<List<int>>[
    _section(0x04, tablePayload),
    _section(0x07, exportPayload),
  ]);
}

Uint8List _coreModuleImportTableAndConst({
  required String importModule,
  required String importName,
  required int min,
  int? max,
  int refType = 0x70,
  required String exportName,
  required int value,
}) {
  final importPayload = <int>[
    ..._u32Leb(1),
    ..._name(importModule),
    ..._name(importName),
    WasmImportKind.table,
    refType,
    ..._limits(flags: max == null ? 0x00 : 0x01, min: min, max: max),
  ];
  return _coreModuleConstRunWithImports(
    typeSectionPayload: const <int>[0x01, 0x60, 0x00, 0x01, 0x7f],
    importSectionPayload: importPayload,
    runTypeIndex: 0,
    exportName: exportName,
    value: value,
  );
}

Uint8List _coreModuleExportGlobalI32({
  required String name,
  int value = 0,
  bool mutable = false,
}) {
  return _coreModuleExportGlobal(
    name: name,
    valueType: 0x7f,
    mutable: mutable,
    initOpcode: 0x41,
    value: value,
  );
}

Uint8List _coreModuleExportGlobalI64({
  required String name,
  int value = 0,
  bool mutable = false,
}) {
  return _coreModuleExportGlobal(
    name: name,
    valueType: 0x7e,
    mutable: mutable,
    initOpcode: 0x42,
    value: value,
  );
}

Uint8List _coreModuleExportGlobal({
  required String name,
  required int valueType,
  required bool mutable,
  required int initOpcode,
  required int value,
}) {
  final globalPayload = <int>[
    ..._u32Leb(1),
    valueType,
    mutable ? 1 : 0,
    initOpcode,
    ..._u32Leb(value),
    0x0b,
  ];
  final exportPayload = <int>[
    ..._u32Leb(1),
    ..._name(name),
    WasmExportKind.global,
    ..._u32Leb(0),
  ];
  return _coreModuleWithSections(<List<int>>[
    _section(0x06, globalPayload),
    _section(0x07, exportPayload),
  ]);
}

Uint8List _coreModuleImportGlobalAndConst({
  required String importModule,
  required String importName,
  required int valueType,
  required bool mutable,
  required String exportName,
  required int value,
}) {
  final importPayload = <int>[
    ..._u32Leb(1),
    ..._name(importModule),
    ..._name(importName),
    WasmImportKind.global,
    valueType,
    mutable ? 1 : 0,
  ];
  return _coreModuleConstRunWithImports(
    typeSectionPayload: const <int>[0x01, 0x60, 0x00, 0x01, 0x7f],
    importSectionPayload: importPayload,
    runTypeIndex: 0,
    exportName: exportName,
    value: value,
  );
}

Uint8List _coreModuleExportTag({required String name, required int paramType}) {
  final typePayload = <int>[
    ..._u32Leb(1),
    0x60,
    ..._u32Leb(1),
    paramType,
    ..._u32Leb(0),
  ];
  final tagPayload = <int>[..._u32Leb(1), 0x00, ..._u32Leb(0)];
  final exportPayload = <int>[
    ..._u32Leb(1),
    ..._name(name),
    WasmExportKind.tag,
    ..._u32Leb(0),
  ];
  return _coreModuleWithSections(<List<int>>[
    _section(0x01, typePayload),
    _section(0x0d, tagPayload),
    _section(0x07, exportPayload),
  ]);
}

Uint8List _coreModuleImportTagAndConst({
  required String importModule,
  required String importName,
  required int expectedParamType,
  required String exportName,
  required int value,
}) {
  final typePayload = <int>[
    ..._u32Leb(2),
    0x60,
    0x00,
    0x01,
    0x7f,
    0x60,
    ..._u32Leb(1),
    expectedParamType,
    ..._u32Leb(0),
  ];
  final importPayload = <int>[
    ..._u32Leb(1),
    ..._name(importModule),
    ..._name(importName),
    WasmImportKind.tag,
    0x00,
    ..._u32Leb(1),
  ];
  return _coreModuleConstRunWithImports(
    typeSectionPayload: typePayload,
    importSectionPayload: importPayload,
    runTypeIndex: 0,
    exportName: exportName,
    value: value,
  );
}

Uint8List _coreModuleConstRunWithImports({
  required List<int> typeSectionPayload,
  required List<int> importSectionPayload,
  required int runTypeIndex,
  required String exportName,
  required int value,
}) {
  final exportPayload = <int>[
    ..._u32Leb(1),
    ..._name(exportName),
    WasmExportKind.function,
    ..._u32Leb(0),
  ];
  final codeBody = <int>[0x00, 0x41, ..._u32Leb(value), 0x0b];
  final codePayload = <int>[
    ..._u32Leb(1),
    ..._u32Leb(codeBody.length),
    ...codeBody,
  ];
  return _coreModuleWithSections(<List<int>>[
    _section(0x01, typeSectionPayload),
    _section(0x02, importSectionPayload),
    _section(0x03, <int>[..._u32Leb(1), ..._u32Leb(runTypeIndex)]),
    _section(0x07, exportPayload),
    _section(0x0a, codePayload),
  ]);
}

Uint8List _coreModuleWithSections(List<List<int>> sections) {
  final bytes = <int>[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
  for (final section in sections) {
    bytes.addAll(section);
  }
  return Uint8List.fromList(bytes);
}

List<int> _limits({required int flags, required int min, int? max}) {
  final out = <int>[..._u32Leb(flags), ..._u32Leb(min)];
  if ((flags & 0x01) != 0) {
    if (max == null) {
      throw ArgumentError('max is required when limits include max flag.');
    }
    out.addAll(_u32Leb(max));
  }
  return out;
}

Uint8List _coreModuleEchoUtf8PointerLength({required String name}) {
  final nameBytes = name.codeUnits;
  return Uint8List.fromList(<int>[
    0x00,
    0x61,
    0x73,
    0x6d,
    0x01,
    0x00,
    0x00,
    0x00,
    // type section: (func (param i32 i32) (result i32 i32))
    0x01,
    0x08,
    0x01,
    0x60,
    0x02,
    0x7f,
    0x7f,
    0x02,
    0x7f,
    0x7f,
    // function section
    0x03,
    0x02,
    0x01,
    0x00,
    // memory section: (memory 1)
    0x05,
    0x03,
    0x01,
    0x00,
    0x01,
    // export section
    0x07,
    0x04 + nameBytes.length,
    0x01,
    nameBytes.length,
    ...nameBytes,
    0x00,
    0x00,
    // code section: local.get 0; local.get 1; end
    0x0a,
    0x08,
    0x01,
    0x06,
    0x00,
    0x20,
    0x00,
    0x20,
    0x01,
    0x0b,
  ]);
}

List<int> _u32Leb(int value) {
  if (value < 0) {
    throw ArgumentError.value(value, 'value', 'must be >= 0');
  }
  final out = <int>[];
  var remaining = value;
  do {
    var byte = remaining & 0x7f;
    remaining >>= 7;
    if (remaining != 0) {
      byte |= 0x80;
    }
    out.add(byte);
  } while (remaining != 0);
  return out;
}

List<int> _section(int id, List<int> payload) => <int>[
  id,
  ..._u32Leb(payload.length),
  ...payload,
];

List<int> _name(String value) => <int>[
  ..._u32Leb(value.length),
  ...value.codeUnits,
];
