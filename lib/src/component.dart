import 'dart:typed_data';

import 'byte_reader.dart';
import 'features.dart';
import 'module.dart';

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

/// Component-level exported core alias.
///
/// Alias kind is resolved from the referenced core instance export at
/// instantiation time.
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

enum WasmComponentTypeKind { value, function, alias, memory, table, tag }

/// Component type declaration decoded from section `0x06`.
final class WasmComponentTypeDeclaration {
  const WasmComponentTypeDeclaration.value({
    required this.name,
    required this.valueTypeCode,
    required this.valueTypeSignature,
  }) : kind = WasmComponentTypeKind.value,
       parameterTypeCodes = null,
       parameterTypeSignatures = null,
       resultTypeCodes = null,
       resultTypeSignatures = null,
       aliasTargetIndex = null,
       memoryType = null,
       tableType = null,
       tagParameterTypeCodes = null,
       tagParameterTypeSignatures = null;

  const WasmComponentTypeDeclaration.function({
    required this.name,
    required this.parameterTypeCodes,
    required this.parameterTypeSignatures,
    required this.resultTypeCodes,
    required this.resultTypeSignatures,
  }) : kind = WasmComponentTypeKind.function,
       valueTypeCode = null,
       valueTypeSignature = null,
       aliasTargetIndex = null,
       memoryType = null,
       tableType = null,
       tagParameterTypeCodes = null,
       tagParameterTypeSignatures = null;

  const WasmComponentTypeDeclaration.alias({
    required this.name,
    required this.aliasTargetIndex,
  }) : kind = WasmComponentTypeKind.alias,
       valueTypeCode = null,
       valueTypeSignature = null,
       parameterTypeCodes = null,
       parameterTypeSignatures = null,
       resultTypeCodes = null,
       resultTypeSignatures = null,
       memoryType = null,
       tableType = null,
       tagParameterTypeCodes = null,
       tagParameterTypeSignatures = null;

  const WasmComponentTypeDeclaration.memory({
    required this.name,
    required this.memoryType,
  }) : kind = WasmComponentTypeKind.memory,
       valueTypeCode = null,
       valueTypeSignature = null,
       parameterTypeCodes = null,
       parameterTypeSignatures = null,
       resultTypeCodes = null,
       resultTypeSignatures = null,
       aliasTargetIndex = null,
       tableType = null,
       tagParameterTypeCodes = null,
       tagParameterTypeSignatures = null;

  const WasmComponentTypeDeclaration.table({
    required this.name,
    required this.tableType,
  }) : kind = WasmComponentTypeKind.table,
       valueTypeCode = null,
       valueTypeSignature = null,
       parameterTypeCodes = null,
       parameterTypeSignatures = null,
       resultTypeCodes = null,
       resultTypeSignatures = null,
       aliasTargetIndex = null,
       memoryType = null,
       tagParameterTypeCodes = null,
       tagParameterTypeSignatures = null;

  const WasmComponentTypeDeclaration.tag({
    required this.name,
    required this.tagParameterTypeCodes,
    required this.tagParameterTypeSignatures,
  }) : kind = WasmComponentTypeKind.tag,
       valueTypeCode = null,
       valueTypeSignature = null,
       parameterTypeCodes = null,
       parameterTypeSignatures = null,
       resultTypeCodes = null,
       resultTypeSignatures = null,
       aliasTargetIndex = null,
       memoryType = null,
       tableType = null;

  final String name;
  final WasmComponentTypeKind kind;
  final int? valueTypeCode;
  final String? valueTypeSignature;
  final List<int>? parameterTypeCodes;
  final List<String>? parameterTypeSignatures;
  final List<int>? resultTypeCodes;
  final List<String>? resultTypeSignatures;
  final int? aliasTargetIndex;
  final WasmMemoryType? memoryType;
  final WasmTableType? tableType;
  final List<int>? tagParameterTypeCodes;
  final List<String>? tagParameterTypeSignatures;
}

enum WasmComponentTypeBindingTargetKind {
  importRequirement,
  coreExportAlias,
  opaque,
}

/// Type binding edge decoded from section `0x07`.
final class WasmComponentTypeBinding {
  const WasmComponentTypeBinding({
    required this.targetKind,
    required this.rawTargetKind,
    required this.targetIndex,
    required this.typeDeclarationIndex,
  });

  final WasmComponentTypeBindingTargetKind targetKind;
  final int rawTargetKind;
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
    required this.hasOpaqueCoreInstances,
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
  final bool hasOpaqueCoreInstances;
  final List<WasmComponentCoreExportAlias> coreExportAliases;
  final List<WasmComponentImportRequirement> importRequirements;
  final List<WasmComponentCoreInstanceAlias> coreInstanceAliases;
  final List<WasmComponentTypeDeclaration> typeDeclarations;
  final List<WasmComponentTypeBinding> typeBindings;

  static WasmComponent decode(
    Uint8List componentBytes, {
    WasmFeatureSet features = const WasmFeatureSet(),
  }) {
    return _decodeInternal(
      componentBytes,
      features: features,
      bestEffort: false,
    );
  }

  /// Best-effort decoder for component binaries produced by fast-moving
  /// upstream tooling/testsuites.
  ///
  /// Unlike [decode], this mode swallows unsupported/malformed structured
  /// section decodes and preserves only sections that were successfully parsed.
  /// Raw section bytes are still retained in [sections].
  static WasmComponent decodeBestEffort(
    Uint8List componentBytes, {
    WasmFeatureSet features = const WasmFeatureSet(),
  }) {
    return _decodeInternal(
      componentBytes,
      features: features,
      bestEffort: true,
    );
  }

  static WasmComponent _decodeInternal(
    Uint8List componentBytes, {
    required WasmFeatureSet features,
    required bool bestEffort,
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
    var hasOpaqueCoreInstances = false;

    while (!reader.isEOF) {
      final id = reader.readByte();
      final sectionSize = reader.readVarUint32();
      final section = reader.readSubReader(sectionSize);
      final payload = section.readRemainingBytes();
      sections.add(WasmComponentSection(id: id, payload: payload));
    }

    for (final section in sections) {
      if (section.id == 0x01 && _isCoreModulePayload(section.payload)) {
        coreModules.add(Uint8List.fromList(section.payload));
      }
    }

    final decodeLegacyStructuredSections =
        _shouldDecodeLegacyStructuredSections(sections);
    if (decodeLegacyStructuredSections) {
      for (final section in sections) {
        final payload = section.payload;
        if (section.id == 0x02) {
          _tryDecodeComponentSection(
            bestEffort: bestEffort,
            decode: () {
              final decodeResult = _decodeCoreInstanceSectionPayload(payload);
              coreInstances.addAll(decodeResult.instances);
              if (decodeResult.hasOpaqueKinds) {
                hasOpaqueCoreInstances = true;
              }
            },
          );
        } else if (section.id == 0x03) {
          _tryDecodeComponentSection(
            bestEffort: bestEffort,
            decode: () => coreExportAliases.addAll(
              _decodeCoreExportAliasSectionPayload(payload),
            ),
          );
        } else if (section.id == 0x04) {
          _tryDecodeComponentSection(
            bestEffort: bestEffort,
            decode: () =>
                importRequirements.addAll(_decodeImportSectionPayload(payload)),
          );
        } else if (section.id == 0x05) {
          _tryDecodeComponentSection(
            bestEffort: bestEffort,
            decode: () => coreInstanceAliases.addAll(
              _decodeCoreInstanceAliasSectionPayload(payload),
            ),
          );
        } else if (section.id == 0x06) {
          _tryDecodeComponentSection(
            bestEffort: bestEffort,
            decode: () =>
                typeDeclarations.addAll(_decodeTypeSectionPayload(payload)),
          );
        } else if (section.id == 0x07) {
          _tryDecodeComponentSection(
            bestEffort: bestEffort,
            decode: () =>
                typeBindings.addAll(_decodeTypeBindingSectionPayload(payload)),
          );
        }
      }

      _tryDecodeComponentSection(
        bestEffort: bestEffort,
        decode: () => _validateTypeBindings(
          typeBindings: typeBindings,
          typeDeclarations: typeDeclarations,
          importRequirements: importRequirements,
          coreExportAliases: coreExportAliases,
        ),
      );
    }
    if (!decodeLegacyStructuredSections) {
      for (final section in sections) {
        if (section.id != 0x02) {
          continue;
        }
        try {
          final decodeResult = _decodeCoreInstanceSectionPayload(
            section.payload,
          );
          coreInstances.addAll(decodeResult.instances);
          if (decodeResult.hasOpaqueKinds) {
            hasOpaqueCoreInstances = true;
          }
        } on UnsupportedError {
          hasOpaqueCoreInstances = true;
          coreInstances.clear();
        } on FormatException {
          // Official-layout core-instance forms may diverge; preserve passthrough.
        }
      }
    }

    return WasmComponent._(
      sections: List<WasmComponentSection>.unmodifiable(sections),
      coreModules: List<Uint8List>.unmodifiable(coreModules),
      coreInstances: List<WasmComponentCoreInstance>.unmodifiable(
        coreInstances,
      ),
      hasOpaqueCoreInstances: hasOpaqueCoreInstances,
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

  static void _tryDecodeComponentSection({
    required bool bestEffort,
    required void Function() decode,
  }) {
    if (!bestEffort) {
      decode();
      return;
    }
    try {
      decode();
    } on UnsupportedError {
      // Best-effort mode keeps raw section bytes and skips this structured view.
    } on FormatException {
      // Best-effort mode keeps raw section bytes and skips this structured view.
    }
  }

  static ({List<WasmComponentCoreInstance> instances, bool hasOpaqueKinds})
  _decodeCoreInstanceSectionPayload(Uint8List payload) {
    final reader = ByteReader(payload);
    final count = reader.readVarUint32();
    final instances = <WasmComponentCoreInstance>[];
    var hasOpaqueKinds = false;
    for (var i = 0; i < count; i++) {
      final kind = reader.readByte();
      switch (kind) {
        case 0x00:
          final moduleIndex = reader.readVarUint32();
          final argCount = reader.readVarUint32();
          final argumentInstanceIndices = _readCoreInstanceArgumentIndices(
            reader,
            argCount,
          );
          instances.add(
            WasmComponentCoreInstance.instantiate(
              moduleIndex: moduleIndex,
              argumentInstanceIndices: argumentInstanceIndices,
            ),
          );
        case 0x01:
          hasOpaqueKinds = true;
          final exportCount = reader.readVarUint32();
          for (var j = 0; j < exportCount; j++) {
            _readName(reader);
            reader.readByte();
            reader.readVarUint32();
          }
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
    return (instances: instances, hasOpaqueKinds: hasOpaqueKinds);
  }

  static List<int> _readCoreInstanceArgumentIndices(
    ByteReader reader,
    int argCount,
  ) {
    if (argCount == 0) {
      return const <int>[];
    }

    final start = reader.offset;
    final officialIndices = <int>[];
    var officialOk = true;
    try {
      for (var i = 0; i < argCount; i++) {
        final nameLength = reader.readVarUint32();
        reader.readBytes(nameLength);
        final kind = reader.readByte();
        if (kind != 0x11 && kind != 0x12 && kind != 0x13) {
          throw FormatException(
            'Unsupported core-instance arg kind: 0x${kind.toRadixString(16)}',
          );
        }
        final index = reader.readVarUint32();
        if (kind == 0x12) {
          officialIndices.add(index);
        }
      }
    } on FormatException {
      officialOk = false;
    }

    if (officialOk) {
      return List<int>.unmodifiable(officialIndices);
    }

    reader.offset = start;
    return List<int>.generate(
      argCount,
      (_) => reader.readVarUint32(),
      growable: false,
    );
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
          final typeStart = reader.offset;
          final valueTypeCode = _readComponentValueTypeCode(reader);
          declarations.add(
            WasmComponentTypeDeclaration.value(
              name: name,
              valueTypeCode: valueTypeCode,
              valueTypeSignature: _bytesToSignature(
                reader.bytes.sublist(typeStart, reader.offset),
              ),
            ),
          );
        case 0x01:
          final paramCount = reader.readVarUint32();
          final params = _readComponentTypeVector(reader, paramCount);
          final resultCount = reader.readVarUint32();
          final results = _readComponentTypeVector(reader, resultCount);
          declarations.add(
            WasmComponentTypeDeclaration.function(
              name: name,
              parameterTypeCodes: params.codes,
              parameterTypeSignatures: params.signatures,
              resultTypeCodes: results.codes,
              resultTypeSignatures: results.signatures,
            ),
          );
        case 0x02:
          declarations.add(
            WasmComponentTypeDeclaration.alias(
              name: name,
              aliasTargetIndex: reader.readVarUint32(),
            ),
          );
        case 0x03:
          declarations.add(
            WasmComponentTypeDeclaration.memory(
              name: name,
              memoryType: _readComponentMemoryType(reader),
            ),
          );
        case 0x04:
          declarations.add(
            WasmComponentTypeDeclaration.table(
              name: name,
              tableType: _readComponentTableType(reader),
            ),
          );
        case 0x05:
          final paramCount = reader.readVarUint32();
          final params = _readComponentTypeVector(reader, paramCount);
          declarations.add(
            WasmComponentTypeDeclaration.tag(
              name: name,
              tagParameterTypeCodes: params.codes,
              tagParameterTypeSignatures: params.signatures,
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

  static ({List<int> codes, List<String> signatures}) _readComponentTypeVector(
    ByteReader reader,
    int count,
  ) {
    final codes = <int>[];
    final signatures = <String>[];
    for (var i = 0; i < count; i++) {
      final typeStart = reader.offset;
      final code = _readComponentValueTypeCode(reader);
      codes.add(code);
      signatures.add(
        _bytesToSignature(reader.bytes.sublist(typeStart, reader.offset)),
      );
    }
    return (
      codes: List<int>.unmodifiable(codes),
      signatures: List<String>.unmodifiable(signatures),
    );
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

  static WasmMemoryType _readComponentMemoryType(ByteReader reader) {
    final flags = reader.readByte();
    if ((flags & ~0x0f) != 0) {
      throw UnsupportedError(
        'Unsupported component memory type flags: '
        '0x${flags.toRadixString(16)}',
      );
    }
    final hasMax = (flags & 0x01) != 0;
    final shared = (flags & 0x02) != 0;
    final memory64 = (flags & 0x04) != 0;
    final hasPageSize = (flags & 0x08) != 0;

    final minPages = memory64 ? reader.readVarUint64() : reader.readVarUint32();
    final maxPages = hasMax
        ? (memory64 ? reader.readVarUint64() : reader.readVarUint32())
        : null;
    final pageSizeLog2 = hasPageSize ? reader.readVarUint32() : 16;
    if (maxPages != null && maxPages < minPages) {
      throw FormatException(
        'Invalid component memory type limits: max($maxPages) < min($minPages).',
      );
    }
    if (shared && maxPages == null) {
      throw const FormatException(
        'Invalid component memory type: shared memory requires max pages.',
      );
    }
    if (pageSizeLog2 < 0 || pageSizeLog2 > 16) {
      throw FormatException(
        'Invalid component memory type page size log2: $pageSizeLog2.',
      );
    }
    return WasmMemoryType(
      minPages: minPages,
      maxPages: maxPages,
      shared: shared,
      isMemory64: memory64,
      pageSizeLog2: pageSizeLog2,
    );
  }

  static WasmTableType _readComponentTableType(ByteReader reader) {
    final refTypeStart = reader.offset;
    final refType = _readComponentReferenceType(reader);
    final refTypeSignature = _bytesToSignature(
      reader.bytes.sublist(refTypeStart, reader.offset),
    );
    final flags = reader.readByte();
    if ((flags & ~0x03) != 0) {
      throw UnsupportedError(
        'Unsupported component table type flags: '
        '0x${flags.toRadixString(16)}',
      );
    }
    final hasMax = (flags & 0x01) != 0;
    final table64 = (flags & 0x02) != 0;

    final min = table64 ? reader.readVarUint64() : reader.readVarUint32();
    final max = hasMax
        ? (table64 ? reader.readVarUint64() : reader.readVarUint32())
        : null;
    if (max != null && max < min) {
      throw FormatException(
        'Invalid component table type limits: max($max) < min($min).',
      );
    }
    return WasmTableType(
      refType: refType,
      min: min,
      max: max,
      isTable64: table64,
      refTypeSignature: refTypeSignature,
    );
  }

  static int _readComponentValueTypeCode(ByteReader reader) {
    final lead = reader.readByte();
    switch (lead) {
      case 0x7f:
      case 0x7e:
      case 0x7d:
      case 0x7c:
      case 0x7b:
      case 0x70:
      case 0x6f:
      case 0x71:
      case 0x72:
      case 0x73:
      case 0x74:
      case 0x75:
      case 0x6e:
      case 0x6d:
      case 0x6c:
      case 0x6b:
      case 0x6a:
      case 0x69:
      case 0x68:
      case 0x67:
      case 0x66:
      case 0x65:
      case 0x62:
      case 0x61:
      case 0x60:
      case 0x63:
      case 0x64:
        if (lead == 0x63 || lead == 0x64 || lead == 0x62 || lead == 0x61) {
          _readComponentReferenceTypeCodeWithLead(reader, lead);
        }
        return lead;
      default:
        throw UnsupportedError(
          'Unsupported component value type: 0x${lead.toRadixString(16)}',
        );
    }
  }

  static WasmRefType _readComponentReferenceType(ByteReader reader) {
    final lead = _readComponentReferenceTypeCode(reader);
    switch (lead) {
      case 0x70:
        return WasmRefType.funcref;
      case 0x6f:
      case 0x71:
      case 0x72:
      case 0x73:
      case 0x6e:
      case 0x6d:
      case 0x6c:
      case 0x6b:
      case 0x6a:
      case 0x69:
      case 0x68:
      case 0x67:
      case 0x66:
      case 0x65:
        return WasmRefType.externref;
      case 0x63:
      case 0x64:
      case 0x62:
      case 0x61:
        return WasmRefType.externref;
      default:
        throw UnsupportedError(
          'Unsupported component ref type: 0x${lead.toRadixString(16)}',
        );
    }
  }

  static int _readComponentReferenceTypeCode(ByteReader reader) {
    final lead = reader.readByte();
    return _readComponentReferenceTypeCodeWithLead(reader, lead);
  }

  static int _readComponentReferenceTypeCodeWithLead(
    ByteReader reader,
    int lead,
  ) {
    if (_isLegacyHeapTypeCode(lead)) {
      return lead;
    }
    if (lead == 0x63 || lead == 0x64 || lead == 0x62 || lead == 0x61) {
      var heapLead = reader.readByte();
      if (heapLead == 0x62 || heapLead == 0x61) {
        heapLead = reader.readByte();
      }
      if (_isLegacyHeapTypeCode(heapLead)) {
        return heapLead;
      }
      _readComponentSignedLeb33WithFirst(reader, heapLead);
      return lead;
    }
    if (lead <= 0x60 || lead >= 0x80) {
      _readComponentSignedLeb33WithFirst(reader, lead);
      return lead;
    }
    throw UnsupportedError(
      'Unsupported component ref type: 0x${lead.toRadixString(16)}',
    );
  }

  static bool _isLegacyHeapTypeCode(int code) {
    switch (code & 0xff) {
      case 0x65:
      case 0x66:
      case 0x67:
      case 0x68:
      case 0x6c:
      case 0x70:
      case 0x6f:
      case 0x6e:
      case 0x6d:
      case 0x6b:
      case 0x6a:
      case 0x69:
      case 0x71:
      case 0x72:
      case 0x73:
        return true;
      default:
        return false;
    }
  }

  static int _readComponentSignedLeb33WithFirst(ByteReader reader, int first) {
    var result = first & 0x7f;
    var shift = 7;
    var byte = first;
    var multiplier = 128;
    while ((byte & 0x80) != 0) {
      byte = reader.readByte();
      result += (byte & 0x7f) * multiplier;
      multiplier *= 128;
      shift += 7;
      if (shift > 35) {
        throw const FormatException('Invalid signed LEB33 encoding.');
      }
    }
    if (shift < 33 && (byte & 0x40) != 0) {
      result -= multiplier;
    }
    return _normalizeSignedLeb33(result);
  }

  static int _normalizeSignedLeb33(int value) {
    const signBit33 = 0x100000000;
    const width33 = 0x200000000;
    var normalized = value % width33;
    if (normalized < 0) {
      normalized += width33;
    }
    if (normalized >= signBit33) {
      normalized -= width33;
    }
    return normalized;
  }

  static String _bytesToSignature(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write((byte & 0xff).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static List<WasmComponentTypeBinding> _decodeTypeBindingSectionPayload(
    Uint8List payload,
  ) {
    final reader = ByteReader(payload);
    final count = reader.readVarUint32();
    final bindings = <WasmComponentTypeBinding>[];
    for (var i = 0; i < count; i++) {
      final rawTargetKind = reader.readByte();
      final targetKind = _decodeTypeBindingTargetKind(rawTargetKind);
      final targetIndex = reader.readVarUint32();
      final typeDeclarationIndex = reader.readVarUint32();
      bindings.add(
        WasmComponentTypeBinding(
          targetKind: targetKind,
          rawTargetKind: rawTargetKind,
          targetIndex: targetIndex,
          typeDeclarationIndex: typeDeclarationIndex,
        ),
      );
    }
    if (!reader.isEOF) {
      final allOpaque =
          bindings.isNotEmpty &&
          bindings.every(
            (binding) =>
                binding.targetKind == WasmComponentTypeBindingTargetKind.opaque,
          );
      if (allOpaque) {
        return bindings;
      }
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
        return WasmComponentTypeBindingTargetKind.opaque;
    }
  }

  static void _validateTypeBindings({
    required List<WasmComponentTypeBinding> typeBindings,
    required List<WasmComponentTypeDeclaration> typeDeclarations,
    required List<WasmComponentImportRequirement> importRequirements,
    required List<WasmComponentCoreExportAlias> coreExportAliases,
  }) {
    for (final binding in typeBindings) {
      if (binding.targetKind == WasmComponentTypeBindingTargetKind.opaque) {
        // Unknown target kinds are preserved for forward-compatibility.
        continue;
      }
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
        case WasmComponentTypeBindingTargetKind.opaque:
          continue;
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
            if (resolvedDeclaration.kind != WasmComponentTypeKind.memory) {
              throw FormatException(
                'Component type binding for memory import '
                '`${importRequirement.componentImportName}` must reference '
                'a memory type declaration.',
              );
            }
            break;
          case WasmComponentImportKind.table:
            if (resolvedDeclaration.kind != WasmComponentTypeKind.table) {
              throw FormatException(
                'Component type binding for table import '
                '`${importRequirement.componentImportName}` must reference '
                'a table type declaration.',
              );
            }
            break;
          case WasmComponentImportKind.tag:
            if (resolvedDeclaration.kind != WasmComponentTypeKind.tag) {
              throw FormatException(
                'Component type binding for tag import '
                '`${importRequirement.componentImportName}` must reference '
                'a tag type declaration.',
              );
            }
            break;
        }
      } else if (binding.targetKind ==
          WasmComponentTypeBindingTargetKind.coreExportAlias) {
        switch (resolvedDeclaration.kind) {
          case WasmComponentTypeKind.value:
          case WasmComponentTypeKind.function:
          case WasmComponentTypeKind.memory:
          case WasmComponentTypeKind.table:
          case WasmComponentTypeKind.tag:
            break;
          case WasmComponentTypeKind.alias:
            final alias = coreExportAliases[binding.targetIndex];
            throw FormatException(
              'Component type binding for core export alias '
              '`${alias.componentExportName}` resolved to an alias declaration.',
            );
        }
      } else {
        // Opaque target kinds intentionally skip strict declaration compatibility
        // checks until semantics are implemented.
        continue;
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

  static bool _shouldDecodeLegacyStructuredSections(
    List<WasmComponentSection> sections,
  ) {
    var hasLegacyCoreModule = false;
    var hasLegacyStructuredSection = false;
    for (final section in sections) {
      if (section.id == 0x01 && _isCoreModulePayload(section.payload)) {
        hasLegacyCoreModule = true;
      }
      if (section.id >= 0x08) {
        return false;
      }
      if (section.id == 0x04 && _isComponentPayload(section.payload)) {
        return false;
      }
      if (section.id == 0x06 &&
          !_looksLegacyTypeSectionPayload(section.payload)) {
        return false;
      }
      if (section.id >= 0x02 && section.id <= 0x07) {
        hasLegacyStructuredSection = true;
      }
    }
    if (!hasLegacyCoreModule && hasLegacyStructuredSection) {
      return false;
    }
    return true;
  }

  static bool _looksLegacyTypeSectionPayload(Uint8List payload) {
    final reader = ByteReader(payload);
    try {
      final count = reader.readVarUint32();
      if (count == 0) {
        return true;
      }
      final firstNameLength = reader.readVarUint32();
      if (firstNameLength == 0 || reader.remaining < firstNameLength + 1) {
        return false;
      }
      reader.readBytes(firstNameLength);
      final firstKind = reader.readByte();
      if (firstKind < 0x00 || firstKind > 0x05) {
        return false;
      }
      return true;
    } on FormatException {
      return false;
    }
  }

  static bool _isComponentPayload(Uint8List payload) {
    if (payload.length < 8) {
      return false;
    }
    return payload[0] == 0x00 &&
        payload[1] == 0x61 &&
        payload[2] == 0x73 &&
        payload[3] == 0x6d &&
        payload[4] == 0x0d &&
        payload[5] == 0x00 &&
        payload[6] == 0x01 &&
        payload[7] == 0x00;
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
