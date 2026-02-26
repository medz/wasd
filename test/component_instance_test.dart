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

List<int> _name(String value) => <int>[
  ..._u32Leb(value.length),
  ...value.codeUnits,
];
