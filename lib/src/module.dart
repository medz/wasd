import 'dart:typed_data';

import 'byte_reader.dart';
import 'features.dart';
import 'opcode.dart';
import 'value.dart';
import 'vm.dart';

enum WasmValueType { i32, i64, f32, f64 }

enum WasmRefType { funcref, externref }

enum WasmElementMode { active, passive, declarative }

enum WasmCompositeTypeKind { function, struct, array }

final class _DecodedValueType {
  const _DecodedValueType({
    required this.valueType,
    required this.runtimeSupported,
  });

  final WasmValueType valueType;
  final bool runtimeSupported;
}

extension WasmValueTypeCodec on WasmValueType {
  static WasmValueType fromByte(int value) {
    switch (value) {
      case 0x7f:
        return WasmValueType.i32;
      case 0x7e:
        return WasmValueType.i64;
      case 0x7d:
        return WasmValueType.f32;
      case 0x7c:
        return WasmValueType.f64;
      default:
        throw UnsupportedError(
          'Unsupported value type: 0x${value.toRadixString(16)}',
        );
    }
  }
}

extension WasmRefTypeCodec on WasmRefType {
  static WasmRefType fromByte(int value) {
    switch (value) {
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
      case 0x64:
      case 0x63:
      case 0x62:
      case 0x61:
      case 0x60:
        return WasmRefType.externref;
      default:
        throw UnsupportedError(
          'Unsupported ref type: 0x${value.toRadixString(16)}',
        );
    }
  }
}

abstract final class WasmImportKind {
  static const int function = 0x00;
  static const int table = 0x01;
  static const int memory = 0x02;
  static const int global = 0x03;
  static const int exactFunction = 0x20;
}

abstract final class WasmExportKind {
  static const int function = 0x00;
  static const int table = 0x01;
  static const int memory = 0x02;
  static const int global = 0x03;
}

final class WasmLimits {
  const WasmLimits({
    required this.min,
    this.max,
    this.shared = false,
    this.memory64 = false,
    this.pageSizeLog2 = 16,
  });

  final int min;
  final int? max;
  final bool shared;
  final bool memory64;
  final int pageSizeLog2;
}

final class WasmFunctionType {
  const WasmFunctionType({
    required this.params,
    required this.results,
    required this.kind,
    this.paramTypeSignatures = const <String>[],
    this.resultTypeSignatures = const <String>[],
    this.fieldSignatures = const <String>[],
    this.superTypeIndices = const <int>[],
    this.descriptorTypeIndex,
    this.describesTypeIndex,
    this.isFunctionType = true,
    this.runtimeSupported = true,
  });

  const WasmFunctionType.nonFunction({
    required this.kind,
    required this.fieldSignatures,
    this.superTypeIndices = const <int>[],
    this.descriptorTypeIndex,
    this.describesTypeIndex,
    this.runtimeSupported = false,
  }) : params = const <WasmValueType>[],
       results = const <WasmValueType>[],
       paramTypeSignatures = const <String>[],
       resultTypeSignatures = const <String>[],
       isFunctionType = false;

  final List<WasmValueType> params;
  final List<WasmValueType> results;
  final WasmCompositeTypeKind kind;
  final List<String> paramTypeSignatures;
  final List<String> resultTypeSignatures;
  final List<String> fieldSignatures;
  final List<int> superTypeIndices;
  final int? descriptorTypeIndex;
  final int? describesTypeIndex;
  final bool isFunctionType;
  final bool runtimeSupported;
}

final class WasmMemoryType {
  const WasmMemoryType({
    required this.minPages,
    this.maxPages,
    this.shared = false,
    this.isMemory64 = false,
    this.pageSizeLog2 = 16,
  });

  final int minPages;
  final int? maxPages;
  final bool shared;
  final bool isMemory64;
  final int pageSizeLog2;
}

final class WasmTableType {
  const WasmTableType({
    required this.refType,
    required this.min,
    this.max,
    this.isTable64 = false,
  });

  final WasmRefType refType;
  final int min;
  final int? max;
  final bool isTable64;
}

final class WasmGlobalType {
  const WasmGlobalType({
    required this.valueType,
    required this.mutable,
    this.valueTypeSignature,
  });

  final WasmValueType valueType;
  final bool mutable;
  final String? valueTypeSignature;
}

final class WasmImport {
  const WasmImport({
    required this.module,
    required this.name,
    required this.kind,
    this.functionTypeIndex,
    this.isExactFunction = false,
    this.tableType,
    this.memoryType,
    this.globalType,
  });

  final String module;
  final String name;
  final int kind;
  final int? functionTypeIndex;
  final bool isExactFunction;
  final WasmTableType? tableType;
  final WasmMemoryType? memoryType;
  final WasmGlobalType? globalType;

  String get key => '$module::$name';
}

final class WasmLocalDecl {
  const WasmLocalDecl({
    required this.count,
    required this.type,
    this.typeSignature,
  });

  final int count;
  final WasmValueType type;
  final String? typeSignature;
}

final class WasmCodeBody {
  const WasmCodeBody({required this.locals, required this.instructions});

  final List<WasmLocalDecl> locals;
  final Uint8List instructions;
}

final class WasmGlobalDef {
  const WasmGlobalDef({required this.type, required this.initExpr});

  final WasmGlobalType type;
  final Uint8List initExpr;
}

final class WasmExport {
  const WasmExport({
    required this.name,
    required this.kind,
    required this.index,
  });

  final String name;
  final int kind;
  final int index;
}

final class WasmDataSegment {
  const WasmDataSegment.active({
    required this.memoryIndex,
    required this.offsetExpr,
    required this.bytes,
  }) : isPassive = false;

  const WasmDataSegment.passive({required this.bytes})
    : isPassive = true,
      memoryIndex = 0,
      offsetExpr = null;

  final bool isPassive;
  final int memoryIndex;
  final Uint8List? offsetExpr;
  final Uint8List bytes;
}

final class WasmElementSegment {
  const WasmElementSegment.active({
    required this.tableIndex,
    required this.offsetExpr,
    required this.functionIndices,
    this.refTypeCode = 0x70,
  }) : mode = WasmElementMode.active;

  const WasmElementSegment.passive({
    required this.functionIndices,
    this.refTypeCode = 0x70,
  })
    : mode = WasmElementMode.passive,
      tableIndex = 0,
      offsetExpr = null;

  const WasmElementSegment.declarative({
    required this.functionIndices,
    this.refTypeCode = 0x70,
  })
    : mode = WasmElementMode.declarative,
      tableIndex = 0,
      offsetExpr = null;

  final WasmElementMode mode;
  final int tableIndex;
  final Uint8List? offsetExpr;
  final List<int?> functionIndices;
  final int refTypeCode;

  bool get isActive => mode == WasmElementMode.active;
  bool get isPassive => mode == WasmElementMode.passive;
  bool get isDeclarative => mode == WasmElementMode.declarative;
}

final class WasmModule {
  const WasmModule({
    required this.types,
    required this.imports,
    required this.functionTypeIndices,
    required this.codes,
    required this.tables,
    required this.globals,
    required this.exports,
    required this.memories,
    required this.elements,
    required this.dataSegments,
    required this.dataCount,
    required this.startFunctionIndex,
    required this.importedFunctionCount,
    required this.importedTableCount,
    required this.importedMemoryCount,
    required this.importedGlobalCount,
  });

  final List<WasmFunctionType> types;
  final List<WasmImport> imports;
  final List<int> functionTypeIndices;
  final List<WasmCodeBody> codes;
  final List<WasmTableType> tables;
  final List<WasmGlobalDef> globals;
  final List<WasmExport> exports;
  final List<WasmMemoryType> memories;
  final List<WasmElementSegment> elements;
  final List<WasmDataSegment> dataSegments;
  final int? dataCount;
  final int? startFunctionIndex;
  final int importedFunctionCount;
  final int importedTableCount;
  final int importedMemoryCount;
  final int importedGlobalCount;

  static WasmModule decode(
    Uint8List wasmBytes, {
    WasmFeatureSet features = const WasmFeatureSet(),
  }) {
    final reader = ByteReader(wasmBytes);

    final magic = reader.readBytes(4);
    if (features.componentModel) {
      // Component model binary format support is not implemented yet.
    }
    if (magic.length != 4 ||
        magic[0] != 0x00 ||
        magic[1] != 0x61 ||
        magic[2] != 0x73 ||
        magic[3] != 0x6d) {
      throw const FormatException('Invalid Wasm magic number.');
    }

    final version = reader.readBytes(4);
    if (version.length != 4 ||
        version[0] != 0x01 ||
        version[1] != 0x00 ||
        version[2] != 0x00 ||
        version[3] != 0x00) {
      throw const FormatException('Unsupported Wasm version.');
    }

    final types = <WasmFunctionType>[];
    final imports = <WasmImport>[];
    final functionTypeIndices = <int>[];
    final codes = <WasmCodeBody>[];
    final tables = <WasmTableType>[];
    final globals = <WasmGlobalDef>[];
    final exports = <WasmExport>[];
    final memories = <WasmMemoryType>[];
    final elements = <WasmElementSegment>[];
    final dataSegments = <WasmDataSegment>[];

    var importedFunctionCount = 0;
    var importedTableCount = 0;
    var importedMemoryCount = 0;
    var importedGlobalCount = 0;
    int? startFunctionIndex;
    int? dataCount;
    final seenStandardSections = <int>{};
    var lastSectionOrder = 0;

    while (!reader.isEOF) {
      final sectionId = reader.readByte();
      final sectionSize = reader.readVarUint32();
      final sectionReader = reader.readSubReader(sectionSize);

      if (sectionId != 0) {
        if (!seenStandardSections.add(sectionId)) {
          throw const FormatException('Unexpected content after last section.');
        }
        final sectionOrder = _sectionOrder(sectionId);
        if (sectionOrder < lastSectionOrder) {
          throw const FormatException('Unexpected content after last section.');
        }
        lastSectionOrder = sectionOrder;
      }

      switch (sectionId) {
        case 0:
          _parseCustomSection(sectionReader);
        case 1:
          _parseTypeSection(sectionReader, types);
        case 2:
          final counts = _parseImportSection(sectionReader, imports);
          importedFunctionCount += counts.$1;
          importedTableCount += counts.$2;
          importedMemoryCount += counts.$3;
          importedGlobalCount += counts.$4;
        case 3:
          _parseFunctionSection(sectionReader, functionTypeIndices);
        case 4:
          _parseTableSection(sectionReader, tables);
        case 5:
          _parseMemorySection(sectionReader, memories);
        case 6:
          _parseGlobalSection(sectionReader, globals);
        case 7:
          _parseExportSection(sectionReader, exports);
        case 8:
          if (startFunctionIndex != null) {
            throw const FormatException('Duplicate start section.');
          }
          startFunctionIndex = sectionReader.readVarUint32();
        case 9:
          _parseElementSection(sectionReader, elements, types);
        case 10:
          _parseCodeSection(sectionReader, codes);
        case 11:
          _parseDataSection(sectionReader, dataSegments);
        case 12:
          if (dataCount != null) {
            throw const FormatException('Duplicate data_count section.');
          }
          dataCount = sectionReader.readVarUint32();
        default:
          throw UnsupportedError(
            'Unsupported section id: 0x${sectionId.toRadixString(16)}',
          );
      }

      sectionReader.expectEof();
    }

    if (functionTypeIndices.length != codes.length) {
      throw FormatException(
        'Function/code count mismatch. functions=${functionTypeIndices.length}, '
        'codes=${codes.length}.',
      );
    }

    if (dataCount != null && dataCount != dataSegments.length) {
      throw FormatException(
        'data_count section mismatch. data_count=$dataCount '
        'data_segments=${dataSegments.length}.',
      );
    }
    _validateSuperTypeCompatibility(types);

    return WasmModule(
      types: List.unmodifiable(types),
      imports: List.unmodifiable(imports),
      functionTypeIndices: List.unmodifiable(functionTypeIndices),
      codes: List.unmodifiable(codes),
      tables: List.unmodifiable(tables),
      globals: List.unmodifiable(globals),
      exports: List.unmodifiable(exports),
      memories: List.unmodifiable(memories),
      elements: List.unmodifiable(elements),
      dataSegments: List.unmodifiable(dataSegments),
      dataCount: dataCount,
      startFunctionIndex: startFunctionIndex,
      importedFunctionCount: importedFunctionCount,
      importedTableCount: importedTableCount,
      importedMemoryCount: importedMemoryCount,
      importedGlobalCount: importedGlobalCount,
    );
  }

  static void _parseCustomSection(ByteReader reader) {
    // Custom section payload begins with a name string. Decoding the name
    // ensures malformed LEB lengths are rejected instead of silently ignored.
    reader.readName();
    reader.readRemainingBytes();
  }

  static void _parseTypeSection(
    ByteReader reader,
    List<WasmFunctionType> sink,
  ) {
    final count = reader.readVarUint32();
    for (var i = 0; i < count; i++) {
      _parseRecursiveTypeEntry(reader, sink);
    }
  }

  static void _parseRecursiveTypeEntry(
    ByteReader reader,
    List<WasmFunctionType> sink,
  ) {
    final form = reader.readByte();
    if (form == 0x4e) {
      final groupStart = sink.length;
      final subgroupCount = reader.readVarUint32();
      for (var i = 0; i < subgroupCount; i++) {
        _parseSubTypeWithLeadingForm(
          reader.readByte(),
          reader,
          sink,
          currentTypeIndex: sink.length,
          insideRecGroup: true,
        );
      }
      _validateRecGroupDescriptorLinks(
        sink,
        groupStart: groupStart,
        groupLength: subgroupCount,
      );
      return;
    }
    _parseSubTypeWithLeadingForm(
      form,
      reader,
      sink,
      currentTypeIndex: sink.length,
      insideRecGroup: false,
    );
  }

  static void _parseSubTypeWithLeadingForm(
    int leadingForm,
    ByteReader reader,
    List<WasmFunctionType> sink, {
    required int currentTypeIndex,
    required bool insideRecGroup,
  }) {
    final superTypeIndices = <int>[];
    var form = leadingForm;
    var hasDescribes = false;
    var hasDescriptor = false;
    int? descriptorTypeIndex;
    int? describesTypeIndex;

    while (true) {
      switch (form) {
        case 0x50:
        case 0x4f:
          final superCount = reader.readVarUint32();
          for (var i = 0; i < superCount; i++) {
            superTypeIndices.add(reader.readVarUint32());
          }
          form = reader.readByte();
          continue;
        case 0x4c:
          if (!insideRecGroup || hasDescribes || hasDescriptor) {
            throw const FormatException('Malformed type descriptor wrapper.');
          }
          hasDescribes = true;
          describesTypeIndex = reader.readVarUint32();
          if (describesTypeIndex >= currentTypeIndex) {
            throw const FormatException('Forward use of described type.');
          }
          form = reader.readByte();
          continue;
        case 0x4d:
          if (!insideRecGroup || hasDescriptor) {
            throw const FormatException('Malformed type descriptor wrapper.');
          }
          hasDescriptor = true;
          descriptorTypeIndex = reader.readVarUint32();
          form = reader.readByte();
          continue;
        default:
          _parseCompositeType(
            form: form,
            reader: reader,
            sink: sink,
            superTypeIndices: superTypeIndices,
            descriptorTypeIndex: descriptorTypeIndex,
            describesTypeIndex: describesTypeIndex,
          );
          return;
      }
    }
  }

  static void _parseCompositeType({
    required int form,
    required ByteReader reader,
    required List<WasmFunctionType> sink,
    required List<int> superTypeIndices,
    required int? descriptorTypeIndex,
    required int? describesTypeIndex,
  }) {
    if ((descriptorTypeIndex != null || describesTypeIndex != null) &&
        form != 0x5f) {
      throw const FormatException('Descriptor type must be a struct.');
    }
    switch (form) {
      case 0x60:
        final functionType = _readFunctionType(reader);
        sink.add(
          WasmFunctionType(
            params: functionType.$1,
            paramTypeSignatures: functionType.$2,
            results: functionType.$3,
            resultTypeSignatures: functionType.$4,
            kind: WasmCompositeTypeKind.function,
            superTypeIndices: List.unmodifiable(superTypeIndices),
            descriptorTypeIndex: descriptorTypeIndex,
            describesTypeIndex: describesTypeIndex,
            runtimeSupported: functionType.$5,
          ),
        );
      case 0x5e:
        final fieldSignature = _readFieldType(reader);
        sink.add(
          WasmFunctionType.nonFunction(
            kind: WasmCompositeTypeKind.array,
            fieldSignatures: List.unmodifiable(<String>[fieldSignature]),
            superTypeIndices: List.unmodifiable(superTypeIndices),
            descriptorTypeIndex: descriptorTypeIndex,
            describesTypeIndex: describesTypeIndex,
          ),
        );
      case 0x5f:
        final fieldCount = reader.readVarUint32();
        final fieldSignatures = <String>[];
        for (var i = 0; i < fieldCount; i++) {
          fieldSignatures.add(_readFieldType(reader));
        }
        sink.add(
          WasmFunctionType.nonFunction(
            kind: WasmCompositeTypeKind.struct,
            fieldSignatures: List.unmodifiable(fieldSignatures),
            superTypeIndices: List.unmodifiable(superTypeIndices),
            descriptorTypeIndex: descriptorTypeIndex,
            describesTypeIndex: describesTypeIndex,
          ),
        );
      default:
        throw UnsupportedError(
          'Unsupported type form: 0x${form.toRadixString(16)}',
        );
    }
  }

  static void _validateRecGroupDescriptorLinks(
    List<WasmFunctionType> types, {
    required int groupStart,
    required int groupLength,
  }) {
    final groupEnd = groupStart + groupLength;
    bool inGroup(int index) => index >= groupStart && index < groupEnd;

    for (var i = groupStart; i < groupEnd; i++) {
      final type = types[i];
      final descriptor = type.descriptorTypeIndex;
      final describes = type.describesTypeIndex;

      if (descriptor != null && !inGroup(descriptor)) {
        throw const FormatException('Descriptor type is outside rec group.');
      }
      if (describes != null && !inGroup(describes)) {
        throw const FormatException('Described type is outside rec group.');
      }
    }

    for (var i = groupStart; i < groupEnd; i++) {
      final type = types[i];
      final descriptor = type.descriptorTypeIndex;
      final describes = type.describesTypeIndex;

      if (descriptor != null && types[descriptor].describesTypeIndex != i) {
        throw const FormatException('Type is not described by its descriptor.');
      }
      if (describes != null && types[describes].descriptorTypeIndex != i) {
        throw const FormatException(
          'Described type is not described by descriptor.',
        );
      }
    }
  }

  static void _validateSuperTypeCompatibility(List<WasmFunctionType> types) {
    for (var i = 0; i < types.length; i++) {
      final subType = types[i];
      for (final superTypeIndex in subType.superTypeIndices) {
        if (superTypeIndex < 0 || superTypeIndex >= types.length) {
          throw FormatException('Invalid super type index: $superTypeIndex');
        }
        final superType = types[superTypeIndex];
        if (subType.kind != superType.kind) {
          throw FormatException(
            'Sub type $i does not match super type $superTypeIndex',
          );
        }
        if (subType.isFunctionType &&
            !_functionSignaturesEqual(subType, superType)) {
          throw FormatException(
            'Sub type $i does not match super type $superTypeIndex',
          );
        }
        if (!subType.isFunctionType) {
          switch (subType.kind) {
            case WasmCompositeTypeKind.array:
              if (subType.fieldSignatures.length !=
                  superType.fieldSignatures.length) {
                throw FormatException(
                  'Sub type $i does not match super type $superTypeIndex',
                );
              }
              for (
                var fieldIndex = 0;
                fieldIndex < subType.fieldSignatures.length;
                fieldIndex++
              ) {
                if (subType.fieldSignatures[fieldIndex] !=
                    superType.fieldSignatures[fieldIndex]) {
                  throw FormatException(
                    'Sub type $i does not match super type $superTypeIndex',
                  );
                }
              }
            case WasmCompositeTypeKind.struct:
              if (subType.fieldSignatures.length <
                  superType.fieldSignatures.length) {
                throw FormatException(
                  'Sub type $i does not match super type $superTypeIndex',
                );
              }
              for (
                var fieldIndex = 0;
                fieldIndex < superType.fieldSignatures.length;
                fieldIndex++
              ) {
                if (subType.fieldSignatures[fieldIndex] !=
                    superType.fieldSignatures[fieldIndex]) {
                  throw FormatException(
                    'Sub type $i does not match super type $superTypeIndex',
                  );
                }
              }
            case WasmCompositeTypeKind.function:
              break;
          }
        }
        final superHasDescriptor = superType.descriptorTypeIndex != null;
        final subHasDescriptor = subType.descriptorTypeIndex != null;
        if (superHasDescriptor && !subHasDescriptor) {
          throw FormatException(
            'Sub type $i does not match super type $superTypeIndex',
          );
        }
        final superHasDescribes = superType.describesTypeIndex != null;
        final subHasDescribes = subType.describesTypeIndex != null;
        if (superHasDescribes != subHasDescribes) {
          throw FormatException(
            'Sub type $i does not match super type $superTypeIndex',
          );
        }
        if (superHasDescriptor &&
            !_isSubType(
              types,
              subType.descriptorTypeIndex!,
              superType.descriptorTypeIndex!,
            )) {
          throw FormatException(
            'Descriptor type ${subType.descriptorTypeIndex} does not match',
          );
        }
        if (superHasDescribes &&
            !_isSubType(
              types,
              subType.describesTypeIndex!,
              superType.describesTypeIndex!,
            )) {
          throw FormatException(
            'Described type ${subType.describesTypeIndex} does not match',
          );
        }
      }
    }
  }

  static bool _isSubType(
    List<WasmFunctionType> types,
    int subTypeIndex,
    int superTypeIndex,
  ) {
    if (subTypeIndex == superTypeIndex) {
      return true;
    }
    return _isSubTypeRecursive(types, subTypeIndex, superTypeIndex, <int>{});
  }

  static bool _isSubTypeRecursive(
    List<WasmFunctionType> types,
    int subTypeIndex,
    int superTypeIndex,
    Set<int> visiting,
  ) {
    if (!visiting.add(subTypeIndex)) {
      return false;
    }
    if (subTypeIndex < 0 || subTypeIndex >= types.length) {
      return false;
    }
    final subType = types[subTypeIndex];
    for (final parent in subType.superTypeIndices) {
      if (parent == superTypeIndex) {
        return true;
      }
      if (_isSubTypeRecursive(types, parent, superTypeIndex, visiting)) {
        return true;
      }
    }
    return false;
  }

  static bool _functionSignaturesEqual(WasmFunctionType a, WasmFunctionType b) {
    if (a.params.length != b.params.length ||
        a.results.length != b.results.length) {
      return false;
    }
    for (var i = 0; i < a.params.length; i++) {
      if (a.params[i] != b.params[i]) {
        return false;
      }
    }
    for (var i = 0; i < a.results.length; i++) {
      if (a.results[i] != b.results[i]) {
        return false;
      }
    }
    return true;
  }

  static String _readFieldType(ByteReader reader) {
    final startOffset = reader.offset;
    final typeByte = reader.readByte();
    if (typeByte == 0x78 || typeByte == 0x77) {
      // Packed i8/i16 storage types.
    } else {
      _readValueTypeWithLeadingByte(reader, typeByte);
    }
    final mutability = reader.readByte();
    if (mutability != 0 && mutability != 1) {
      throw FormatException('Invalid field mutability: $mutability');
    }
    final encoded = reader.bytes.sublist(startOffset, reader.offset);
    return _typeEncodingSignature(encoded);
  }

  static String _typeEncodingSignature(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write((byte & 0xff).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static (int, int, int, int) _parseImportSection(
    ByteReader reader,
    List<WasmImport> sink,
  ) {
    var importedFunctions = 0;
    var importedTables = 0;
    var importedMemories = 0;
    var importedGlobals = 0;

    final count = reader.readVarUint32();
    for (var i = 0; i < count; i++) {
      final moduleName = reader.readName();
      final fieldName = reader.readName();
      final kind = reader.readByte();

      switch (kind) {
        case WasmImportKind.function:
        case WasmImportKind.exactFunction:
          importedFunctions++;
          sink.add(
            WasmImport(
              module: moduleName,
              name: fieldName,
              kind: kind,
              functionTypeIndex: reader.readVarUint32(),
              isExactFunction: kind == WasmImportKind.exactFunction,
            ),
          );

        case WasmImportKind.table:
          importedTables++;
          sink.add(
            WasmImport(
              module: moduleName,
              name: fieldName,
              kind: kind,
              tableType: _readTableType(reader),
            ),
          );

        case WasmImportKind.memory:
          importedMemories++;
          sink.add(
            WasmImport(
              module: moduleName,
              name: fieldName,
              kind: kind,
              memoryType: _readMemoryType(reader),
            ),
          );

        case WasmImportKind.global:
          importedGlobals++;
          sink.add(
            WasmImport(
              module: moduleName,
              name: fieldName,
              kind: kind,
              globalType: _readGlobalType(reader),
            ),
          );

        default:
          throw UnsupportedError(
            'Unsupported import kind: 0x${kind.toRadixString(16)}',
          );
      }
    }

    return (
      importedFunctions,
      importedTables,
      importedMemories,
      importedGlobals,
    );
  }

  static void _parseFunctionSection(ByteReader reader, List<int> sink) {
    final count = reader.readVarUint32();
    for (var i = 0; i < count; i++) {
      sink.add(reader.readVarUint32());
    }
  }

  static void _parseTableSection(ByteReader reader, List<WasmTableType> sink) {
    final count = reader.readVarUint32();
    for (var i = 0; i < count; i++) {
      sink.add(_readTableType(reader));
    }
  }

  static void _parseMemorySection(
    ByteReader reader,
    List<WasmMemoryType> sink,
  ) {
    final count = reader.readVarUint32();
    for (var i = 0; i < count; i++) {
      sink.add(_readMemoryType(reader));
    }
  }

  static void _parseGlobalSection(ByteReader reader, List<WasmGlobalDef> sink) {
    final count = reader.readVarUint32();
    for (var i = 0; i < count; i++) {
      sink.add(
        WasmGlobalDef(
          type: _readGlobalType(reader),
          initExpr: _readInitExpression(reader),
        ),
      );
    }
  }

  static void _parseExportSection(ByteReader reader, List<WasmExport> sink) {
    final count = reader.readVarUint32();
    for (var i = 0; i < count; i++) {
      sink.add(
        WasmExport(
          name: reader.readName(),
          kind: reader.readByte(),
          index: reader.readVarUint32(),
        ),
      );
    }
  }

  static void _parseElementSection(
    ByteReader reader,
    List<WasmElementSegment> sink,
    List<WasmFunctionType> types,
  ) {
    final count = reader.readVarUint32();
    for (var i = 0; i < count; i++) {
      final flags = reader.readVarUint32();

      switch (flags) {
        case 0:
          final offsetExpr = _readInitExpression(reader);
          final functionIndices = _readFunctionIndexVector(reader);
          sink.add(
            WasmElementSegment.active(
              tableIndex: 0,
              offsetExpr: offsetExpr,
              functionIndices: functionIndices,
              refTypeCode: 0x70,
            ),
          );

        case 1:
          _readElemKind(reader);
          sink.add(
            WasmElementSegment.passive(
              functionIndices: _readFunctionIndexVector(reader),
              refTypeCode: 0x70,
            ),
          );

        case 2:
          final tableIndex = reader.readVarUint32();
          final offsetExpr = _readInitExpression(reader);
          _readElemKind(reader);
          sink.add(
            WasmElementSegment.active(
              tableIndex: tableIndex,
              offsetExpr: offsetExpr,
              functionIndices: _readFunctionIndexVector(reader),
              refTypeCode: 0x70,
            ),
          );

        case 3:
          _readElemKind(reader);
          sink.add(
            WasmElementSegment.declarative(
              functionIndices: _readFunctionIndexVector(reader),
              refTypeCode: 0x70,
            ),
          );

        case 4:
          final offsetExpr = _readInitExpression(reader);
          sink.add(
            WasmElementSegment.active(
              tableIndex: 0,
              offsetExpr: offsetExpr,
              functionIndices: _readElementExprFunctionIndices(reader, types),
              refTypeCode: 0x70,
            ),
          );

        case 5:
          final refTypeCode = _readReferenceTypeCode(reader);
          sink.add(
            WasmElementSegment.passive(
              functionIndices: _readElementExprFunctionIndices(reader, types),
              refTypeCode: refTypeCode,
            ),
          );

        case 6:
          final tableIndex = reader.readVarUint32();
          final offsetExpr = _readInitExpression(reader);
          final refTypeCode = _readReferenceTypeCode(reader);
          sink.add(
            WasmElementSegment.active(
              tableIndex: tableIndex,
              offsetExpr: offsetExpr,
              functionIndices: _readElementExprFunctionIndices(reader, types),
              refTypeCode: refTypeCode,
            ),
          );

        case 7:
          final refTypeCode = _readReferenceTypeCode(reader);
          sink.add(
            WasmElementSegment.declarative(
              functionIndices: _readElementExprFunctionIndices(reader, types),
              refTypeCode: refTypeCode,
            ),
          );

        default:
          throw UnsupportedError('Unsupported element segment flag: $flags');
      }
    }
  }

  static void _parseCodeSection(ByteReader reader, List<WasmCodeBody> sink) {
    final count = reader.readVarUint32();
    for (var i = 0; i < count; i++) {
      final bodySize = reader.readVarUint32();
      final bodyReader = reader.readSubReader(bodySize);

      final localDeclCount = bodyReader.readVarUint32();
      final locals = <WasmLocalDecl>[];
      for (var j = 0; j < localDeclCount; j++) {
        final localCount = bodyReader.readVarUint32();
        final typeStart = bodyReader.offset;
        final decodedType = _readValueType(bodyReader);
        locals.add(
          WasmLocalDecl(
            count: localCount,
            type: decodedType.valueType,
            typeSignature: _typeEncodingSignature(
              bodyReader.bytes.sublist(typeStart, bodyReader.offset),
            ),
          ),
        );
      }

      final instructions = bodyReader.readRemainingBytes();
      if (instructions.isEmpty || instructions.last != Opcodes.end) {
        throw const FormatException(
          'Function body must end with `end` opcode.',
        );
      }

      sink.add(WasmCodeBody(locals: locals, instructions: instructions));
    }
  }

  static void _parseDataSection(ByteReader reader, List<WasmDataSegment> sink) {
    final count = reader.readVarUint32();
    for (var i = 0; i < count; i++) {
      final flag = reader.readVarUint32();
      switch (flag) {
        case 0:
          sink.add(
            WasmDataSegment.active(
              memoryIndex: 0,
              offsetExpr: _readInitExpression(reader),
              bytes: reader.readBytes(reader.readVarUint32()),
            ),
          );

        case 1:
          sink.add(
            WasmDataSegment.passive(
              bytes: reader.readBytes(reader.readVarUint32()),
            ),
          );

        case 2:
          sink.add(
            WasmDataSegment.active(
              memoryIndex: reader.readVarUint32(),
              offsetExpr: _readInitExpression(reader),
              bytes: reader.readBytes(reader.readVarUint32()),
            ),
          );

        default:
          throw UnsupportedError('Unsupported data segment flag: $flag');
      }
    }
  }

  static Uint8List _readInitExpression(ByteReader reader) {
    final start = reader.offset;

    while (true) {
      final opcode = reader.readByte();
      switch (opcode) {
        case Opcodes.end:
          return Uint8List.fromList(reader.bytes.sublist(start, reader.offset));
        case Opcodes.i32Const:
          reader.readVarInt32();
        case Opcodes.i64Const:
          reader.readVarInt64();
        case Opcodes.f32Const:
          reader.readBytes(4);
        case Opcodes.f64Const:
          reader.readBytes(8);
        case Opcodes.globalGet:
          reader.readVarUint32();
        case Opcodes.refNull:
          _consumeHeapType(reader);
        case Opcodes.refFunc:
          reader.readVarUint32();
        case 0xfb:
          final subOpcode = reader.readVarUint32();
          final pseudoOpcode = 0xfb00 | subOpcode;
          switch (pseudoOpcode) {
            case Opcodes.structNew:
            case Opcodes.structNewDefault:
            case Opcodes.structNewDesc:
            case Opcodes.structNewDefaultDesc:
            case Opcodes.arrayNew:
            case Opcodes.arrayNewDefault:
              reader.readVarUint32();
            case Opcodes.arrayNewFixed:
              reader.readVarUint32();
              reader.readVarUint32();
            case Opcodes.refI31:
              break;
            default:
              throw UnsupportedError(
                'Unsupported init expression opcode: 0xFB${subOpcode.toRadixString(16).padLeft(2, '0')}',
              );
          }
        case Opcodes.i32Add:
        case Opcodes.i32Sub:
        case Opcodes.i32Mul:
        case Opcodes.i64Add:
        case Opcodes.i64Sub:
        case Opcodes.i64Mul:
        case Opcodes.f32Add:
        case Opcodes.f32Sub:
        case Opcodes.f32Mul:
        case Opcodes.f32Div:
        case Opcodes.f64Add:
        case Opcodes.f64Sub:
        case Opcodes.f64Mul:
        case Opcodes.f64Div:
          continue;
        default:
          throw UnsupportedError(
            'Unsupported init expression opcode: 0x${opcode.toRadixString(16)}',
          );
      }
    }
  }

  static (
    List<WasmValueType>,
    List<String>,
    List<WasmValueType>,
    List<String>,
    bool,
  )
  _readFunctionType(ByteReader reader) {
    final params = _readValueTypeVector(reader);
    final results = _readValueTypeVector(reader);
    return (
      params.$1,
      params.$2,
      results.$1,
      results.$2,
      params.$3 && results.$3,
    );
  }

  static (List<WasmValueType>, List<String>, bool) _readValueTypeVector(
    ByteReader reader,
  ) {
    final count = reader.readVarUint32();
    final valueTypes = <WasmValueType>[];
    final signatures = <String>[];
    var allSupported = true;
    for (var i = 0; i < count; i++) {
      final startOffset = reader.offset;
      final decoded = _readValueType(reader);
      valueTypes.add(decoded.valueType);
      signatures.add(
        _typeEncodingSignature(
          reader.bytes.sublist(startOffset, reader.offset),
        ),
      );
      allSupported = allSupported && decoded.runtimeSupported;
    }
    return (
      List.unmodifiable(valueTypes),
      List.unmodifiable(signatures),
      allSupported,
    );
  }

  static _DecodedValueType _readValueType(ByteReader reader) {
    return _readValueTypeWithLeadingByte(reader, reader.readByte());
  }

  static _DecodedValueType _readValueTypeWithLeadingByte(
    ByteReader reader,
    int leadingByte,
  ) {
    switch (leadingByte) {
      case 0x7f:
        return _DecodedValueType(
          valueType: WasmValueType.i32,
          runtimeSupported: true,
        );
      case 0x7e:
        return _DecodedValueType(
          valueType: WasmValueType.i64,
          runtimeSupported: true,
        );
      case 0x7d:
        return _DecodedValueType(
          valueType: WasmValueType.f32,
          runtimeSupported: true,
        );
      case 0x7c:
        return _DecodedValueType(
          valueType: WasmValueType.f64,
          runtimeSupported: true,
        );
      case 0x63:
      case 0x64:
        _consumeHeapType(reader);
        return _DecodedValueType(
          valueType: WasmValueType.i32,
          runtimeSupported: false,
        );
      case 0x7b:
      case 0x70:
      case 0x71:
      case 0x6f:
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
        return _DecodedValueType(
          valueType: WasmValueType.i32,
          runtimeSupported: false,
        );
      default:
        throw UnsupportedError(
          'Unsupported value type: 0x${leadingByte.toRadixString(16)}',
        );
    }
  }

  static void _readElemKind(ByteReader reader) {
    final kind = reader.readByte();
    if (kind != 0x00) {
      throw UnsupportedError('Only elemkind 0x00 (funcref) is supported.');
    }
  }

  static List<int?> _readFunctionIndexVector(ByteReader reader) {
    final count = reader.readVarUint32();
    final result = <int?>[];
    for (var i = 0; i < count; i++) {
      result.add(reader.readVarUint32());
    }
    return result;
  }

  static List<int?> _readElementExprFunctionIndices(
    ByteReader reader,
    List<WasmFunctionType> types,
  ) {
    final count = reader.readVarUint32();
    final result = <int?>[];
    for (var i = 0; i < count; i++) {
      result.add(_readElementExprFunctionIndex(reader, types));
    }
    return result;
  }

  static int? _readElementExprFunctionIndex(
    ByteReader reader,
    List<WasmFunctionType> types,
  ) {
    final stack = <WasmValue>[];
    while (true) {
      final opcode = reader.readByte();
      switch (opcode) {
        case Opcodes.i32Const:
          stack.add(WasmValue.i32(reader.readVarInt32()));

        case Opcodes.refNull:
          _consumeHeapType(reader);
          stack.add(WasmValue.i32(-1));

        case Opcodes.refFunc:
          stack.add(WasmValue.i32(reader.readVarUint32()));

        case 0xfb:
          final subOpcode = reader.readVarUint32();
          final pseudoOpcode = 0xfb00 | subOpcode;
          switch (pseudoOpcode) {
            case Opcodes.refI31:
              if (stack.isEmpty) {
                throw const FormatException(
                  'Malformed ref.i31 init expr in element.',
                );
              }
              final payload =
                  stack.removeLast().castTo(WasmValueType.i32).asI32() &
                  0x7fffffff;
              stack.add(WasmValue.i32(WasmVm.allocateConstI31Ref(payload)));

            case Opcodes.arrayNew:
              final typeIndex = reader.readVarUint32();
              if (typeIndex < 0 || typeIndex >= types.length) {
                throw FormatException(
                  'Invalid type index in element init expr: $typeIndex',
                );
              }
              final type = types[typeIndex];
              if (type.kind != WasmCompositeTypeKind.array) {
                throw const FormatException(
                  'Element init expr type mismatch.',
                );
              }
              if (stack.length < 2) {
                throw const FormatException(
                  'Malformed array.new init expr in element.',
                );
              }
              final length =
                  stack.removeLast().castTo(WasmValueType.i32).asI32();
              final seed = _coerceConstFieldValue(
                type.fieldSignatures.single,
                stack.removeLast(),
              );
              if (length < 0) {
                throw RangeError('Array length out of bounds: $length');
              }
              final elements = List<WasmValue>.filled(
                length,
                seed,
                growable: false,
              );
              stack.add(
                WasmValue.i32(
                  WasmVm.allocateConstArrayRef(
                    typeIndex: typeIndex,
                    elements: elements,
                  ),
                ),
              );

            case Opcodes.arrayNewDefault:
              final typeIndex = reader.readVarUint32();
              if (typeIndex < 0 || typeIndex >= types.length) {
                throw FormatException(
                  'Invalid type index in element init expr: $typeIndex',
                );
              }
              final type = types[typeIndex];
              if (type.kind != WasmCompositeTypeKind.array || stack.isEmpty) {
                throw const FormatException(
                  'Element init expr type mismatch.',
                );
              }
              final length =
                  stack.removeLast().castTo(WasmValueType.i32).asI32();
              if (length < 0) {
                throw RangeError('Array length out of bounds: $length');
              }
              final defaultValue = _defaultConstFieldValue(
                type.fieldSignatures.single,
              );
              final elements = List<WasmValue>.filled(
                length,
                defaultValue,
                growable: false,
              );
              stack.add(
                WasmValue.i32(
                  WasmVm.allocateConstArrayRef(
                    typeIndex: typeIndex,
                    elements: elements,
                  ),
                ),
              );

            case Opcodes.arrayNewFixed:
              final typeIndex = reader.readVarUint32();
              final elementCount = reader.readVarUint32();
              if (typeIndex < 0 || typeIndex >= types.length) {
                throw FormatException(
                  'Invalid type index in element init expr: $typeIndex',
                );
              }
              final type = types[typeIndex];
              if (type.kind != WasmCompositeTypeKind.array ||
                  stack.length < elementCount) {
                throw const FormatException(
                  'Element init expr type mismatch.',
                );
              }
              final elements = List<WasmValue>.filled(
                elementCount,
                WasmValue.i32(0),
                growable: false,
              );
              for (var i = elementCount - 1; i >= 0; i--) {
                elements[i] = _coerceConstFieldValue(
                  type.fieldSignatures.single,
                  stack.removeLast(),
                );
              }
              stack.add(
                WasmValue.i32(
                  WasmVm.allocateConstArrayRef(
                    typeIndex: typeIndex,
                    elements: elements,
                  ),
                ),
              );

            default:
              throw UnsupportedError(
                'Unsupported 0xFB sub-opcode in element init expr: '
                '0x${subOpcode.toRadixString(16)}',
              );
          }

        case Opcodes.end:
          if (stack.length != 1) {
            throw const FormatException('Malformed element init expr.');
          }
          final reference = stack.single.castTo(WasmValueType.i32).asI32();
          return reference == -1 ? null : reference;

        default:
          throw UnsupportedError(
            'Unsupported element init expr opcode: 0x${opcode.toRadixString(16)}',
          );
      }
    }
  }

  static WasmValue _coerceConstFieldValue(String fieldSignature, WasmValue input) {
    final bytes = _fieldSignatureBytes(fieldSignature);
    final typeCode = bytes.first;
    switch (typeCode) {
      case 0x78:
        return WasmValue.i32(input.castTo(WasmValueType.i32).asI32() & 0xff);
      case 0x77:
        return WasmValue.i32(input.castTo(WasmValueType.i32).asI32() & 0xffff);
      case 0x7f:
      case 0x63:
      case 0x64:
        return WasmValue.i32(input.castTo(WasmValueType.i32).asI32());
      case 0x7e:
        return WasmValue.i64(input.castTo(WasmValueType.i64).asI64());
      case 0x7d:
        return WasmValue.f32(input.castTo(WasmValueType.f32).asF32());
      case 0x7c:
        return WasmValue.f64(input.castTo(WasmValueType.f64).asF64());
      default:
        return input;
    }
  }

  static WasmValue _defaultConstFieldValue(String fieldSignature) {
    final bytes = _fieldSignatureBytes(fieldSignature);
    final typeCode = bytes.first;
    switch (typeCode) {
      case 0x7f:
      case 0x78:
      case 0x77:
        return WasmValue.i32(0);
      case 0x63:
      case 0x64:
      case 0x70:
      case 0x6f:
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
      case 0x71:
      case 0x72:
      case 0x73:
        return WasmValue.i32(-1);
      case 0x7e:
        return WasmValue.i64(0);
      case 0x7d:
        return WasmValue.f32(0);
      case 0x7c:
        return WasmValue.f64(0);
      default:
        return WasmValue.i32(0);
    }
  }

  static List<int> _fieldSignatureBytes(String fieldSignature) {
    if (fieldSignature.length < 4 || fieldSignature.length.isOdd) {
      throw StateError('Invalid field signature: $fieldSignature');
    }
    final bytes = <int>[];
    for (var i = 0; i < fieldSignature.length; i += 2) {
      bytes.add(int.parse(fieldSignature.substring(i, i + 2), radix: 16));
    }
    if (bytes.length < 2) {
      throw StateError('Invalid field signature: $fieldSignature');
    }
    bytes.removeLast(); // mutability
    return bytes;
  }

  static void _consumeHeapType(ByteReader reader) {
    _consumeHeapTypeWithLeadingByte(reader, reader.readByte());
  }

  static void _consumeHeapTypeWithLeadingByte(ByteReader reader, int lead) {
    if (lead == 0x62 || lead == 0x61) {
      final nested = reader.readByte();
      if (nested == 0x62 || nested == 0x61) {
        throw const FormatException('Malformed storage type.');
      }
      if (nested >= 0x65 && nested <= 0x71) {
        throw const FormatException('Malformed storage type.');
      }
      _readSignedLeb33WithFirst(reader, nested);
      return;
    }
    if (lead >= 0x65 && lead <= 0x71) {
      return;
    }
    _readSignedLeb33WithFirst(reader, lead);
  }

  static int _readSignedLeb33WithFirst(ByteReader reader, int firstByte) {
    var result = firstByte & 0x7f;
    var shift = 7;
    var byte = firstByte;
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

  static WasmTableType _readTableType(ByteReader reader) {
    final refType = _readReferenceType(reader);
    final limits = _readLimits(reader, allowExtendedMemoryFlags: true);
    _validateLimits(limits, context: 'table');
    if (limits.shared || limits.pageSizeLog2 != 16) {
      throw const FormatException(
        'Invalid table limits: unsupported flag combination.',
      );
    }
    return WasmTableType(
      refType: refType,
      min: limits.min,
      max: limits.max,
      isTable64: limits.memory64,
    );
  }

  static WasmRefType _readReferenceType(ByteReader reader) {
    final lead = _readReferenceTypeCode(reader);
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
          'Unsupported ref type: 0x${lead.toRadixString(16)}',
        );
    }
  }

  static int _readReferenceTypeCode(ByteReader reader) {
    final lead = reader.readByte();
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
      _readSignedLeb33WithFirst(reader, heapLead);
      return lead;
    }
    if (lead <= 0x60 || lead >= 0x80) {
      _readSignedLeb33WithFirst(reader, lead);
      return lead;
    }
    throw UnsupportedError('Unsupported ref type: 0x${lead.toRadixString(16)}');
  }

  static bool _isLegacyHeapTypeCode(int code) {
    switch (code & 0xff) {
      case 0x65:
      case 0x66:
      case 0x67:
      case 0x68:
      case 0x6c:
      case 0x70: // funcref
      case 0x6f: // externref
      case 0x6e: // anyref
      case 0x6d: // eqref
      case 0x6b: // structref
      case 0x6a: // arrayref
      case 0x69: // i31ref
      case 0x71: // nullref
      case 0x72: // nullexternref
      case 0x73: // nullfuncref
        return true;
      default:
        return false;
    }
  }

  static WasmMemoryType _readMemoryType(ByteReader reader) {
    final limits = _readLimits(reader, allowExtendedMemoryFlags: true);
    _validateLimits(limits, context: 'memory');

    if (!limits.memory64) {
      final pagesBitWidth = 32 - limits.pageSizeLog2;
      if (pagesBitWidth < 0) {
        throw FormatException(
          'Invalid memory page size log2 ${limits.pageSizeLog2}: exceeds i32 memory address space.',
        );
      }
      final maxAllowedPages = BigInt.one << pagesBitWidth;
      final minPages = BigInt.from(limits.min);
      if (minPages > maxAllowedPages) {
        throw FormatException(
          'Invalid memory min limit: ${limits.min} > $maxAllowedPages for page size log2 ${limits.pageSizeLog2}.',
        );
      }
      final max = limits.max;
      if (max != null && BigInt.from(max) > maxAllowedPages) {
        throw FormatException(
          'Invalid memory max limit: $max > $maxAllowedPages for page size log2 ${limits.pageSizeLog2}.',
        );
      }
    }

    return WasmMemoryType(
      minPages: limits.min,
      maxPages: limits.max,
      shared: limits.shared,
      isMemory64: limits.memory64,
      pageSizeLog2: limits.pageSizeLog2,
    );
  }

  static WasmGlobalType _readGlobalType(ByteReader reader) {
    final typeStart = reader.offset;
    final decodedValueType = _readValueType(reader);
    final valueTypeSignature = _typeEncodingSignature(
      reader.bytes.sublist(typeStart, reader.offset),
    );
    final valueType = decodedValueType.valueType;
    final mutability = reader.readByte();
    if (mutability != 0 && mutability != 1) {
      throw UnsupportedError('Invalid global mutability: $mutability');
    }

    return WasmGlobalType(
      valueType: valueType,
      mutable: mutability == 1,
      valueTypeSignature: valueTypeSignature,
    );
  }

  static WasmLimits _readLimits(
    ByteReader reader, {
    bool allowExtendedMemoryFlags = false,
  }) {
    final flags = reader.readByte();
    if (!allowExtendedMemoryFlags) {
      switch (flags) {
        case 0x00:
          return WasmLimits(min: reader.readVarUint32());
        case 0x01:
          return WasmLimits(
            min: reader.readVarUint32(),
            max: reader.readVarUint32(),
          );
        default:
          throw UnsupportedError(
            'Unsupported limits flags: 0x${flags.toRadixString(16)}',
          );
      }
    }

    if ((flags & ~0x0f) != 0) {
      throw UnsupportedError(
        'Unsupported memory limits flags: 0x${flags.toRadixString(16)}',
      );
    }

    final hasMax = (flags & 0x01) != 0;
    final shared = (flags & 0x02) != 0;
    final memory64 = (flags & 0x04) != 0;
    final hasPageSize = (flags & 0x08) != 0;

    final min = memory64 ? reader.readVarUint64() : reader.readVarUint32();
    final max = hasMax
        ? (memory64 ? reader.readVarUint64() : reader.readVarUint32())
        : null;
    final pageSizeLog2 = hasPageSize ? reader.readVarUint32() : 16;

    return WasmLimits(
      min: min,
      max: max,
      shared: shared,
      memory64: memory64,
      pageSizeLog2: pageSizeLog2,
    );
  }

  static void _validateLimits(
    WasmLimits limits, {
    required String context,
    int? maxAllowed,
  }) {
    final max = limits.max;
    if (max != null && max < limits.min) {
      throw FormatException(
        'Invalid $context limits: max($max) < min(${limits.min}).',
      );
    }
    if (context == 'memory') {
      if (limits.shared && max == null) {
        throw const FormatException(
          'Invalid memory limits: shared memory requires a maximum.',
        );
      }
      if (limits.pageSizeLog2 < 0 || limits.pageSizeLog2 > 16) {
        throw FormatException(
          'Invalid memory page size log2: ${limits.pageSizeLog2}.',
        );
      }
    }
    if (maxAllowed != null) {
      if (limits.min > maxAllowed) {
        throw FormatException(
          'Invalid $context min limit: ${limits.min} > $maxAllowed.',
        );
      }
      if (max != null && max > maxAllowed) {
        throw FormatException(
          'Invalid $context max limit: $max > $maxAllowed.',
        );
      }
    }
  }

  static int _sectionOrder(int sectionId) {
    // Data count section (id=12) is validated before code (id=10) and data (id=11).
    return switch (sectionId) {
      1 => 1,
      2 => 2,
      3 => 3,
      4 => 4,
      5 => 5,
      6 => 6,
      7 => 7,
      8 => 8,
      9 => 9,
      12 => 10,
      10 => 11,
      11 => 12,
      _ => sectionId + 100,
    };
  }
}
