import 'dart:typed_data';

import 'byte_reader.dart';
import 'features.dart';

/// Decoded component section payload.
final class WasmComponentSection {
  const WasmComponentSection({required this.id, required this.payload});

  final int id;
  final Uint8List payload;
}

/// Decoded core instance declaration from component section `0x02`.
final class WasmComponentCoreInstance {
  const WasmComponentCoreInstance.instantiate({required this.moduleIndex});

  final int moduleIndex;
}

/// Component-level exported core function alias.
///
/// Current subset decodes this from section `0x03`.
final class WasmComponentCoreExportAlias {
  const WasmComponentCoreExportAlias({
    required this.componentExportName,
    required this.instanceIndex,
    required this.coreExportName,
  });

  final String componentExportName;
  final int instanceIndex;
  final String coreExportName;
}

enum WasmComponentImportKind { function, memory, table, global, tag }

/// Component-level import requirement decoded from section `0x04`.
final class WasmComponentImportRequirement {
  const WasmComponentImportRequirement({
    required this.componentImportName,
    required this.moduleName,
    required this.fieldName,
    required this.kind,
  });

  final String componentImportName;
  final String moduleName;
  final String fieldName;
  final WasmComponentImportKind kind;
}

/// Minimal component binary decoder.
///
/// This currently validates the component header and collects raw sections.
/// Full canonical ABI/lowering/lifting semantics are implemented separately.
final class WasmComponent {
  const WasmComponent._({
    required this.sections,
    required this.coreModules,
    required this.coreInstances,
    required this.coreExportAliases,
    required this.importRequirements,
  });

  static const List<int> _magic = <int>[0x00, 0x61, 0x73, 0x6d];
  static const List<int> _componentVersion = <int>[0x0d, 0x00, 0x01, 0x00];

  final List<WasmComponentSection> sections;
  final List<Uint8List> coreModules;
  final List<WasmComponentCoreInstance> coreInstances;
  final List<WasmComponentCoreExportAlias> coreExportAliases;
  final List<WasmComponentImportRequirement> importRequirements;

  static WasmComponent decode(
    Uint8List componentBytes, {
    WasmFeatureSet features = const WasmFeatureSet(),
  }) {
    if (!features.componentModel) {
      throw UnsupportedError(
        'Component model binary requires `componentModel` feature to be enabled.',
      );
    }

    final reader = ByteReader(componentBytes);
    final magic = reader.readBytes(4);
    if (!_sameBytes(magic, _magic)) {
      throw const FormatException('Invalid Wasm component magic number.');
    }

    final version = reader.readBytes(4);
    if (!_sameBytes(version, _componentVersion)) {
      throw const FormatException('Unsupported Wasm component version.');
    }

    final sections = <WasmComponentSection>[];
    final coreModules = <Uint8List>[];
    final coreInstances = <WasmComponentCoreInstance>[];
    final coreExportAliases = <WasmComponentCoreExportAlias>[];
    final importRequirements = <WasmComponentImportRequirement>[];
    while (!reader.isEOF) {
      final id = reader.readByte();
      final sectionSize = reader.readVarUint32();
      final section = reader.readSubReader(sectionSize);
      final payload = section.readRemainingBytes();
      sections.add(WasmComponentSection(id: id, payload: payload));
      if (id == 0x01 && _isCoreModulePayload(payload)) {
        coreModules.add(Uint8List.fromList(payload));
      } else if (id == 0x02) {
        coreInstances.addAll(_decodeCoreInstanceSectionPayload(payload));
      } else if (id == 0x03) {
        coreExportAliases.addAll(_decodeCoreExportAliasSectionPayload(payload));
      } else if (id == 0x04) {
        importRequirements.addAll(_decodeImportSectionPayload(payload));
      }
    }

    return WasmComponent._(
      sections: List<WasmComponentSection>.unmodifiable(sections),
      coreModules: List<Uint8List>.unmodifiable(coreModules),
      coreInstances: List<WasmComponentCoreInstance>.unmodifiable(
        coreInstances,
      ),
      coreExportAliases: List<WasmComponentCoreExportAlias>.unmodifiable(
        coreExportAliases,
      ),
      importRequirements: List<WasmComponentImportRequirement>.unmodifiable(
        importRequirements,
      ),
    );
  }

  static List<WasmComponentCoreInstance> _decodeCoreInstanceSectionPayload(
    Uint8List payload,
  ) {
    final reader = ByteReader(payload);
    final count = reader.readVarUint32();
    final instances = <WasmComponentCoreInstance>[];
    for (var i = 0; i < count; i++) {
      final kind = reader.readByte();
      switch (kind) {
        case 0x00:
          final moduleIndex = reader.readVarUint32();
          final argCount = reader.readVarUint32();
          if (argCount != 0) {
            throw UnsupportedError(
              'Component core-instance instantiate args are not implemented yet.',
            );
          }
          instances.add(
            WasmComponentCoreInstance.instantiate(moduleIndex: moduleIndex),
          );
        default:
          throw UnsupportedError(
            'Unsupported component core-instance kind: 0x${kind.toRadixString(16)}',
          );
      }
    }
    if (!reader.isEOF) {
      throw const FormatException(
        'Trailing bytes in component core-instance section payload.',
      );
    }
    return instances;
  }

  static List<WasmComponentCoreExportAlias>
  _decodeCoreExportAliasSectionPayload(Uint8List payload) {
    final reader = ByteReader(payload);
    final count = reader.readVarUint32();
    final aliases = <WasmComponentCoreExportAlias>[];
    final names = <String>{};
    for (var i = 0; i < count; i++) {
      final instanceIndex = reader.readVarUint32();
      final coreExportName = _readName(reader);
      final componentExportName = _readName(reader);
      if (!names.add(componentExportName)) {
        throw FormatException(
          'Duplicate component export alias: $componentExportName',
        );
      }
      aliases.add(
        WasmComponentCoreExportAlias(
          componentExportName: componentExportName,
          instanceIndex: instanceIndex,
          coreExportName: coreExportName,
        ),
      );
    }
    if (!reader.isEOF) {
      throw const FormatException(
        'Trailing bytes in component core-export alias section payload.',
      );
    }
    return aliases;
  }

  static List<WasmComponentImportRequirement> _decodeImportSectionPayload(
    Uint8List payload,
  ) {
    final reader = ByteReader(payload);
    final count = reader.readVarUint32();
    final imports = <WasmComponentImportRequirement>[];
    final names = <String>{};
    for (var i = 0; i < count; i++) {
      final componentImportName = _readName(reader);
      final moduleName = _readName(reader);
      final fieldName = _readName(reader);
      final kind = _decodeImportKind(reader.readByte());
      if (!names.add(componentImportName)) {
        throw FormatException(
          'Duplicate component import name: $componentImportName',
        );
      }
      imports.add(
        WasmComponentImportRequirement(
          componentImportName: componentImportName,
          moduleName: moduleName,
          fieldName: fieldName,
          kind: kind,
        ),
      );
    }
    if (!reader.isEOF) {
      throw const FormatException(
        'Trailing bytes in component import section payload.',
      );
    }
    return imports;
  }

  static WasmComponentImportKind _decodeImportKind(int raw) {
    switch (raw) {
      case 0x00:
        return WasmComponentImportKind.function;
      case 0x01:
        return WasmComponentImportKind.memory;
      case 0x02:
        return WasmComponentImportKind.table;
      case 0x03:
        return WasmComponentImportKind.global;
      case 0x04:
        return WasmComponentImportKind.tag;
      default:
        throw UnsupportedError(
          'Unsupported component import kind: 0x${raw.toRadixString(16)}',
        );
    }
  }

  static String _readName(ByteReader reader) {
    final length = reader.readVarUint32();
    return String.fromCharCodes(reader.readBytes(length));
  }

  static bool _isCoreModulePayload(Uint8List payload) {
    if (payload.length < 8) {
      return false;
    }
    return payload[0] == 0x00 &&
        payload[1] == 0x61 &&
        payload[2] == 0x73 &&
        payload[3] == 0x6d &&
        payload[4] == 0x01 &&
        payload[5] == 0x00 &&
        payload[6] == 0x00 &&
        payload[7] == 0x00;
  }

  static bool _sameBytes(Uint8List actual, List<int> expected) {
    if (actual.length != expected.length) {
      return false;
    }
    for (var i = 0; i < actual.length; i++) {
      if (actual[i] != expected[i]) {
        return false;
      }
    }
    return true;
  }
}
