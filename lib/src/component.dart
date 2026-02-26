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
  WasmComponentCoreInstance.instantiate({
    required this.moduleIndex,
    List<int> argumentInstanceIndices = const <int>[],
  }) : argumentInstanceIndices = List<int>.unmodifiable(
         argumentInstanceIndices,
       );

  final int moduleIndex;
  final List<int> argumentInstanceIndices;
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

/// Alias binding for a core instance index, decoded from section `0x05`.
final class WasmComponentCoreInstanceAlias {
  const WasmComponentCoreInstanceAlias({
    required this.aliasName,
    required this.instanceIndex,
  });

  final String aliasName;
  final int instanceIndex;
}

enum WasmComponentTypeKind { value, function, alias }

/// Component type declaration decoded from section `0x06`.
final class WasmComponentTypeDeclaration {
  const WasmComponentTypeDeclaration.value({
    required this.name,
    required this.valueTypeCode,
  }) : kind = WasmComponentTypeKind.value,
       parameterTypeCodes = null,
       resultTypeCodes = null,
       aliasTargetIndex = null;

  const WasmComponentTypeDeclaration.function({
    required this.name,
    required this.parameterTypeCodes,
    required this.resultTypeCodes,
  }) : kind = WasmComponentTypeKind.function,
       valueTypeCode = null,
       aliasTargetIndex = null;

  const WasmComponentTypeDeclaration.alias({
    required this.name,
    required this.aliasTargetIndex,
  }) : kind = WasmComponentTypeKind.alias,
       valueTypeCode = null,
       parameterTypeCodes = null,
       resultTypeCodes = null;

  final String name;
  final WasmComponentTypeKind kind;
  final int? valueTypeCode;
  final List<int>? parameterTypeCodes;
  final List<int>? resultTypeCodes;
  final int? aliasTargetIndex;
}

enum WasmComponentTypeBindingTargetKind { importRequirement, coreExportAlias }

/// Type binding edge decoded from section `0x07`.
final class WasmComponentTypeBinding {
  const WasmComponentTypeBinding({
    required this.targetKind,
    required this.targetIndex,
    required this.typeDeclarationIndex,
  });

  final WasmComponentTypeBindingTargetKind targetKind;
  final int targetIndex;
  final int typeDeclarationIndex;
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
    required this.coreInstanceAliases,
    required this.typeDeclarations,
    required this.typeBindings,
  });

  static const List<int> _magic = <int>[0x00, 0x61, 0x73, 0x6d];
  static const List<int> _componentVersion = <int>[0x0d, 0x00, 0x01, 0x00];

  final List<WasmComponentSection> sections;
  final List<Uint8List> coreModules;
  final List<WasmComponentCoreInstance> coreInstances;
  final List<WasmComponentCoreExportAlias> coreExportAliases;
  final List<WasmComponentImportRequirement> importRequirements;
  final List<WasmComponentCoreInstanceAlias> coreInstanceAliases;
  final List<WasmComponentTypeDeclaration> typeDeclarations;
  final List<WasmComponentTypeBinding> typeBindings;

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
    final coreInstanceAliases = <WasmComponentCoreInstanceAlias>[];
    final typeDeclarations = <WasmComponentTypeDeclaration>[];
    final typeBindings = <WasmComponentTypeBinding>[];
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
      } else if (id == 0x05) {
        coreInstanceAliases.addAll(
          _decodeCoreInstanceAliasSectionPayload(payload),
        );
      } else if (id == 0x06) {
        typeDeclarations.addAll(_decodeTypeSectionPayload(payload));
      } else if (id == 0x07) {
        typeBindings.addAll(_decodeTypeBindingSectionPayload(payload));
      }
    }
    _validateTypeBindings(
      typeBindings: typeBindings,
      typeDeclarations: typeDeclarations,
      importRequirements: importRequirements,
      coreExportAliases: coreExportAliases,
    );

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
      coreInstanceAliases: List<WasmComponentCoreInstanceAlias>.unmodifiable(
        coreInstanceAliases,
      ),
      typeDeclarations: List<WasmComponentTypeDeclaration>.unmodifiable(
        typeDeclarations,
      ),
      typeBindings: List<WasmComponentTypeBinding>.unmodifiable(typeBindings),
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
          final argumentInstanceIndices = List<int>.generate(
            argCount,
            (_) => reader.readVarUint32(),
            growable: false,
          );
          instances.add(
            WasmComponentCoreInstance.instantiate(
              moduleIndex: moduleIndex,
              argumentInstanceIndices: argumentInstanceIndices,
            ),
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

  static List<WasmComponentCoreInstanceAlias>
  _decodeCoreInstanceAliasSectionPayload(Uint8List payload) {
    final reader = ByteReader(payload);
    final count = reader.readVarUint32();
    final aliases = <WasmComponentCoreInstanceAlias>[];
    final names = <String>{};
    for (var i = 0; i < count; i++) {
      final aliasName = _readName(reader);
      final instanceIndex = reader.readVarUint32();
      if (!names.add(aliasName)) {
        throw FormatException('Duplicate core instance alias: $aliasName');
      }
      aliases.add(
        WasmComponentCoreInstanceAlias(
          aliasName: aliasName,
          instanceIndex: instanceIndex,
        ),
      );
    }
    if (!reader.isEOF) {
      throw const FormatException(
        'Trailing bytes in component core-instance alias section payload.',
      );
    }
    return aliases;
  }

  static List<WasmComponentTypeDeclaration> _decodeTypeSectionPayload(
    Uint8List payload,
  ) {
    final reader = ByteReader(payload);
    final count = reader.readVarUint32();
    final declarations = <WasmComponentTypeDeclaration>[];
    final names = <String>{};
    for (var i = 0; i < count; i++) {
      final name = _readName(reader);
      if (!names.add(name)) {
        throw FormatException(
          'Duplicate component type declaration name: $name',
        );
      }
      final kind = reader.readByte();
      switch (kind) {
        case 0x00:
          declarations.add(
            WasmComponentTypeDeclaration.value(
              name: name,
              valueTypeCode: reader.readByte(),
            ),
          );
        case 0x01:
          final paramCount = reader.readVarUint32();
          final params = List<int>.generate(
            paramCount,
            (_) => reader.readByte(),
            growable: false,
          );
          final resultCount = reader.readVarUint32();
          final results = List<int>.generate(
            resultCount,
            (_) => reader.readByte(),
            growable: false,
          );
          declarations.add(
            WasmComponentTypeDeclaration.function(
              name: name,
              parameterTypeCodes: params,
              resultTypeCodes: results,
            ),
          );
        case 0x02:
          declarations.add(
            WasmComponentTypeDeclaration.alias(
              name: name,
              aliasTargetIndex: reader.readVarUint32(),
            ),
          );
        default:
          throw UnsupportedError(
            'Unsupported component type declaration kind: '
            '0x${kind.toRadixString(16)}',
          );
      }
    }
    if (!reader.isEOF) {
      throw const FormatException(
        'Trailing bytes in component type section payload.',
      );
    }
    _validateTypeDeclarationGraph(declarations);
    return declarations;
  }

  static void _validateTypeDeclarationGraph(
    List<WasmComponentTypeDeclaration> declarations,
  ) {
    for (var i = 0; i < declarations.length; i++) {
      final declaration = declarations[i];
      final aliasTargetIndex = declaration.aliasTargetIndex;
      if (declaration.kind == WasmComponentTypeKind.alias &&
          (aliasTargetIndex == null ||
              aliasTargetIndex < 0 ||
              aliasTargetIndex >= declarations.length)) {
        throw FormatException(
          'Component type alias `${declaration.name}` target out of range: '
          '$aliasTargetIndex (count=${declarations.length}).',
        );
      }
    }

    final visitState = List<int>.filled(declarations.length, 0);
    bool visit(int index) {
      final state = visitState[index];
      if (state == 1) {
        return false;
      }
      if (state == 2) {
        return true;
      }
      visitState[index] = 1;
      final declaration = declarations[index];
      if (declaration.kind == WasmComponentTypeKind.alias) {
        final target = declaration.aliasTargetIndex!;
        if (!visit(target)) {
          return false;
        }
      }
      visitState[index] = 2;
      return true;
    }

    for (var i = 0; i < declarations.length; i++) {
      if (!visit(i)) {
        throw const FormatException('Component type alias cycle detected.');
      }
    }
  }

  static List<WasmComponentTypeBinding> _decodeTypeBindingSectionPayload(
    Uint8List payload,
  ) {
    final reader = ByteReader(payload);
    final count = reader.readVarUint32();
    final bindings = <WasmComponentTypeBinding>[];
    for (var i = 0; i < count; i++) {
      final targetKind = _decodeTypeBindingTargetKind(reader.readByte());
      final targetIndex = reader.readVarUint32();
      final typeDeclarationIndex = reader.readVarUint32();
      bindings.add(
        WasmComponentTypeBinding(
          targetKind: targetKind,
          targetIndex: targetIndex,
          typeDeclarationIndex: typeDeclarationIndex,
        ),
      );
    }
    if (!reader.isEOF) {
      throw const FormatException(
        'Trailing bytes in component type-binding section payload.',
      );
    }
    return bindings;
  }

  static WasmComponentTypeBindingTargetKind _decodeTypeBindingTargetKind(
    int raw,
  ) {
    switch (raw) {
      case 0x00:
        return WasmComponentTypeBindingTargetKind.importRequirement;
      case 0x01:
        return WasmComponentTypeBindingTargetKind.coreExportAlias;
      default:
        throw UnsupportedError(
          'Unsupported component type-binding target kind: '
          '0x${raw.toRadixString(16)}',
        );
    }
  }

  static void _validateTypeBindings({
    required List<WasmComponentTypeBinding> typeBindings,
    required List<WasmComponentTypeDeclaration> typeDeclarations,
    required List<WasmComponentImportRequirement> importRequirements,
    required List<WasmComponentCoreExportAlias> coreExportAliases,
  }) {
    for (final binding in typeBindings) {
      if (binding.typeDeclarationIndex < 0 ||
          binding.typeDeclarationIndex >= typeDeclarations.length) {
        throw FormatException(
          'Component type binding references invalid type index '
          '${binding.typeDeclarationIndex} (count=${typeDeclarations.length}).',
        );
      }
      switch (binding.targetKind) {
        case WasmComponentTypeBindingTargetKind.importRequirement:
          if (binding.targetIndex < 0 ||
              binding.targetIndex >= importRequirements.length) {
            throw FormatException(
              'Component type binding references invalid import index '
              '${binding.targetIndex} (count=${importRequirements.length}).',
            );
          }
        case WasmComponentTypeBindingTargetKind.coreExportAlias:
          if (binding.targetIndex < 0 ||
              binding.targetIndex >= coreExportAliases.length) {
            throw FormatException(
              'Component type binding references invalid export-alias index '
              '${binding.targetIndex} (count=${coreExportAliases.length}).',
            );
          }
      }

      final resolvedDeclaration = _resolveTypeDeclaration(
        typeDeclarations,
        binding.typeDeclarationIndex,
      );
      if (binding.targetKind ==
          WasmComponentTypeBindingTargetKind.importRequirement) {
        final importRequirement = importRequirements[binding.targetIndex];
        switch (importRequirement.kind) {
          case WasmComponentImportKind.function:
            if (resolvedDeclaration.kind != WasmComponentTypeKind.function) {
              throw FormatException(
                'Component type binding for function import '
                '`${importRequirement.componentImportName}` must reference '
                'a function type declaration.',
              );
            }
            break;
          case WasmComponentImportKind.global:
            if (resolvedDeclaration.kind != WasmComponentTypeKind.value) {
              throw FormatException(
                'Component type binding for global import '
                '`${importRequirement.componentImportName}` must reference '
                'a value type declaration.',
              );
            }
            break;
          case WasmComponentImportKind.memory:
          case WasmComponentImportKind.table:
          case WasmComponentImportKind.tag:
            throw UnsupportedError(
              'Component type binding for `${importRequirement.kind.name}` '
              'imports is not implemented yet.',
            );
        }
      } else if (binding.targetKind ==
          WasmComponentTypeBindingTargetKind.coreExportAlias) {
        if (resolvedDeclaration.kind != WasmComponentTypeKind.function) {
          final alias = coreExportAliases[binding.targetIndex];
          throw FormatException(
            'Component type binding for core export alias '
            '`${alias.componentExportName}` must reference '
            'a function type declaration.',
          );
        }
      }
    }
  }

  static WasmComponentTypeDeclaration _resolveTypeDeclaration(
    List<WasmComponentTypeDeclaration> declarations,
    int index,
  ) {
    var current = index;
    final visited = <int>{};
    while (true) {
      if (!visited.add(current)) {
        throw const FormatException('Component type alias cycle detected.');
      }
      final declaration = declarations[current];
      if (declaration.kind != WasmComponentTypeKind.alias) {
        return declaration;
      }
      current = declaration.aliasTargetIndex!;
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
