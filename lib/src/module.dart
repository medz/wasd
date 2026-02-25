import 'dart:typed_data';

import 'byte_reader.dart';
import 'features.dart';
import 'opcode.dart';

enum WasmValueType { i32, i64, f32, f64 }

enum WasmRefType { funcref, externref }

enum WasmElementMode { active, passive, declarative }

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
  const WasmFunctionType({required this.params, required this.results});

  final List<WasmValueType> params;
  final List<WasmValueType> results;
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
  const WasmTableType({required this.refType, required this.min, this.max});

  final WasmRefType refType;
  final int min;
  final int? max;
}

final class WasmGlobalType {
  const WasmGlobalType({required this.valueType, required this.mutable});

  final WasmValueType valueType;
  final bool mutable;
}

final class WasmImport {
  const WasmImport({
    required this.module,
    required this.name,
    required this.kind,
    this.functionTypeIndex,
    this.tableType,
    this.memoryType,
    this.globalType,
  });

  final String module;
  final String name;
  final int kind;
  final int? functionTypeIndex;
  final WasmTableType? tableType;
  final WasmMemoryType? memoryType;
  final WasmGlobalType? globalType;

  String get key => '$module::$name';
}

final class WasmLocalDecl {
  const WasmLocalDecl({required this.count, required this.type});

  final int count;
  final WasmValueType type;
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
  }) : mode = WasmElementMode.active;

  const WasmElementSegment.passive({required this.functionIndices})
    : mode = WasmElementMode.passive,
      tableIndex = 0,
      offsetExpr = null;

  const WasmElementSegment.declarative({required this.functionIndices})
    : mode = WasmElementMode.declarative,
      tableIndex = 0,
      offsetExpr = null;

  final WasmElementMode mode;
  final int tableIndex;
  final Uint8List? offsetExpr;
  final List<int?> functionIndices;

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
          throw const FormatException(
            'Unexpected content after last section.',
          );
        }
        final sectionOrder = _sectionOrder(sectionId);
        if (sectionOrder < lastSectionOrder) {
          throw const FormatException(
            'Unexpected content after last section.',
          );
        }
        lastSectionOrder = sectionOrder;
      }

      switch (sectionId) {
        case 0:
          // Custom section.
          sectionReader.readRemainingBytes();
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
          _parseElementSection(sectionReader, elements);
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

  static void _parseTypeSection(
    ByteReader reader,
    List<WasmFunctionType> sink,
  ) {
    final count = reader.readVarUint32();
    for (var i = 0; i < count; i++) {
      final form = reader.readByte();
      if (form != 0x60) {
        throw UnsupportedError(
          'Unsupported type form: 0x${form.toRadixString(16)}',
        );
      }

      sink.add(
        WasmFunctionType(
          params: _readValueTypeVector(reader),
          results: _readValueTypeVector(reader),
        ),
      );
    }
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
          importedFunctions++;
          sink.add(
            WasmImport(
              module: moduleName,
              name: fieldName,
              kind: kind,
              functionTypeIndex: reader.readVarUint32(),
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
            ),
          );

        case 1:
          _readElemKind(reader);
          sink.add(
            WasmElementSegment.passive(
              functionIndices: _readFunctionIndexVector(reader),
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
            ),
          );

        case 3:
          _readElemKind(reader);
          sink.add(
            WasmElementSegment.declarative(
              functionIndices: _readFunctionIndexVector(reader),
            ),
          );

        case 4:
          final offsetExpr = _readInitExpression(reader);
          sink.add(
            WasmElementSegment.active(
              tableIndex: 0,
              offsetExpr: offsetExpr,
              functionIndices: _readElementExprFunctionIndices(reader),
            ),
          );

        case 5:
          final refType = WasmRefTypeCodec.fromByte(reader.readByte());
          if (refType != WasmRefType.funcref) {
            throw UnsupportedError(
              'Only funcref element segments are supported.',
            );
          }
          sink.add(
            WasmElementSegment.passive(
              functionIndices: _readElementExprFunctionIndices(reader),
            ),
          );

        case 6:
          final tableIndex = reader.readVarUint32();
          final offsetExpr = _readInitExpression(reader);
          final refType = WasmRefTypeCodec.fromByte(reader.readByte());
          if (refType != WasmRefType.funcref) {
            throw UnsupportedError(
              'Only funcref element segments are supported.',
            );
          }
          sink.add(
            WasmElementSegment.active(
              tableIndex: tableIndex,
              offsetExpr: offsetExpr,
              functionIndices: _readElementExprFunctionIndices(reader),
            ),
          );

        case 7:
          final refType = WasmRefTypeCodec.fromByte(reader.readByte());
          if (refType != WasmRefType.funcref) {
            throw UnsupportedError(
              'Only funcref element segments are supported.',
            );
          }
          sink.add(
            WasmElementSegment.declarative(
              functionIndices: _readElementExprFunctionIndices(reader),
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
        locals.add(
          WasmLocalDecl(
            count: bodyReader.readVarUint32(),
            type: _readValueType(bodyReader),
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
          reader.readByte();
        case Opcodes.refFunc:
          reader.readVarUint32();
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
        default:
          throw UnsupportedError(
            'Unsupported init expression opcode: 0x${opcode.toRadixString(16)}',
          );
      }
    }
  }

  static List<WasmValueType> _readValueTypeVector(ByteReader reader) {
    final count = reader.readVarUint32();
    final result = <WasmValueType>[];
    for (var i = 0; i < count; i++) {
      result.add(_readValueType(reader));
    }
    return result;
  }

  static WasmValueType _readValueType(ByteReader reader) {
    return WasmValueTypeCodec.fromByte(reader.readByte());
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

  static List<int?> _readElementExprFunctionIndices(ByteReader reader) {
    final count = reader.readVarUint32();
    final result = <int?>[];
    for (var i = 0; i < count; i++) {
      result.add(_readElementExprFunctionIndex(reader));
    }
    return result;
  }

  static int? _readElementExprFunctionIndex(ByteReader reader) {
    final opcode = reader.readByte();
    switch (opcode) {
      case Opcodes.refNull:
        WasmRefTypeCodec.fromByte(reader.readByte());
        if (reader.readByte() != Opcodes.end) {
          throw const FormatException(
            'Malformed ref.null init expr in element.',
          );
        }
        return null;

      case Opcodes.refFunc:
        final functionIndex = reader.readVarUint32();
        if (reader.readByte() != Opcodes.end) {
          throw const FormatException(
            'Malformed ref.func init expr in element.',
          );
        }
        return functionIndex;

      default:
        throw UnsupportedError(
          'Unsupported element init expr opcode: 0x${opcode.toRadixString(16)}',
        );
    }
  }

  static WasmTableType _readTableType(ByteReader reader) {
    final refType = WasmRefTypeCodec.fromByte(reader.readByte());
    final limits = _readLimits(reader);
    _validateLimits(limits, context: 'table');
    return WasmTableType(refType: refType, min: limits.min, max: limits.max);
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
    final valueType = _readValueType(reader);
    final mutability = reader.readByte();
    if (mutability != 0 && mutability != 1) {
      throw UnsupportedError('Invalid global mutability: $mutability');
    }

    return WasmGlobalType(valueType: valueType, mutable: mutability == 1);
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
