import 'dart:convert';
import 'dart:typed_data';

import '../../errors.dart';

const String _branchHintSectionName = 'metadata.code.branch_hint';

void validateBranchHintCustomSections(ByteBuffer bytes) {
  try {
    _BranchHintValidator(bytes.asUint8List()).validate();
  } on FormatException catch (error) {
    throw CompileError(error.message, cause: error);
  } on RangeError catch (error) {
    throw CompileError(error.message, cause: error);
  }
}

bool hasValidBranchHintCustomSections(ByteBuffer bytes) {
  try {
    _BranchHintValidator(bytes.asUint8List()).validate();
    return true;
  } on FormatException catch (_) {
    return false;
  } on RangeError catch (_) {
    return false;
  }
}

final class _BranchHintValidator {
  _BranchHintValidator(this._bytes);

  final Uint8List _bytes;
  final List<Uint8List> _branchHintPayloads = <Uint8List>[];
  final List<_CodeBody> _codeBodies = <_CodeBody>[];
  int _importedFunctionCount = 0;
  bool _hasBranchHints = false;

  void validate() {
    if (!_hasValidHeader()) {
      return;
    }
    _scanSections();
    if (!_hasBranchHints) {
      return;
    }
    _validatePayloads();
  }

  bool _hasValidHeader() {
    return _bytes.length >= 8 &&
        _bytes[0] == 0x00 &&
        _bytes[1] == 0x61 &&
        _bytes[2] == 0x73 &&
        _bytes[3] == 0x6d &&
        _bytes[4] == 0x01 &&
        _bytes[5] == 0x00 &&
        _bytes[6] == 0x00 &&
        _bytes[7] == 0x00;
  }

  void _scanSections() {
    final reader = _ByteReader(_bytes)..offset = 8;
    while (!reader.isEOF) {
      final sectionId = reader.readByte();
      final sectionSize = reader.readVarUint32();
      final section = reader.readSubReader(sectionSize);
      switch (sectionId) {
        case 0:
          final name = section.readName();
          final payload = section.readRemainingBytes();
          if (name == _branchHintSectionName) {
            _hasBranchHints = true;
            _branchHintPayloads.add(payload);
          }
        case 2:
          _scanImportSection(section);
        case 10:
          _scanCodeSection(section);
      }
    }
  }

  void _scanImportSection(_ByteReader reader) {
    final count = reader.readVarUint32();
    for (var i = 0; i < count; i++) {
      reader.readName();
      reader.readName();
      final kind = reader.readByte();
      switch (kind) {
        case 0:
          reader.readVarUint32();
          _importedFunctionCount++;
        case 1:
          _skipRefType(reader);
          _skipLimits(reader);
        case 2:
          _skipLimits(reader);
        case 3:
          _skipValueType(reader);
          reader.readByte();
        case 4:
          reader.readByte();
          reader.readVarUint32();
        default:
          throw FormatException('Unsupported import kind: $kind.');
      }
    }
  }

  void _scanCodeSection(_ByteReader reader) {
    final count = reader.readVarUint32();
    for (var i = 0; i < count; i++) {
      final bodySize = reader.readVarUint32();
      final body = reader.readSubReader(bodySize);
      final localDeclCount = body.readVarUint32();
      for (var j = 0; j < localDeclCount; j++) {
        body.readVarUint32();
        _skipValueType(body);
      }
      final instructionStart = body.offset;
      final instructions = body.readRemainingBytes();
      _codeBodies.add(
        _CodeBody(
          instructionStart: instructionStart,
          instructions: instructions,
        ),
      );
    }
  }

  void _validatePayloads() {
    final hintedOffsetsByFunction = <int, Set<int>>{};
    for (final payload in _branchHintPayloads) {
      final reader = _ByteReader(payload);
      final functionCount = reader.readVarUint32();
      for (var i = 0; i < functionCount; i++) {
        final functionIndex = reader.readVarUint32();
        final codeIndex = functionIndex - _importedFunctionCount;
        if (codeIndex < 0 || codeIndex >= _codeBodies.length) {
          throw FormatException(
            'Invalid branch hint function index: $functionIndex.',
          );
        }

        final hintedOffsets = hintedOffsetsByFunction.putIfAbsent(
          functionIndex,
          () => <int>{},
        );
        final hintCount = reader.readVarUint32();
        for (var j = 0; j < hintCount; j++) {
          final bodyOffset = reader.readVarUint32();
          final hintLength = reader.readVarUint32();
          if (hintLength != 1) {
            throw FormatException(
              'Invalid branch hint payload length: $hintLength.',
            );
          }
          final hint = reader.readByte();
          if (hint != 0 && hint != 1) {
            throw FormatException('Invalid branch hint value: $hint.');
          }
          if (!hintedOffsets.add(bodyOffset)) {
            throw FormatException(
              'Duplicate branch hint for function $functionIndex at body '
              'offset $bodyOffset.',
            );
          }
          if (!_isBranchHintTarget(_codeBodies[codeIndex], bodyOffset)) {
            throw FormatException(
              'Invalid branch hint target for function $functionIndex at '
              'body offset $bodyOffset.',
            );
          }
        }
      }
      reader.expectEof();
    }
  }

  bool _isBranchHintTarget(_CodeBody body, int bodyOffset) {
    if (bodyOffset < body.instructionStart) {
      return false;
    }
    final instructionOffset = bodyOffset - body.instructionStart;
    final reader = _ByteReader(body.instructions);
    var foundStart = false;
    var controlDepth = 0;
    while (!reader.isEOF) {
      final offset = reader.offset;
      final opcode = reader.readByte();
      if (!foundStart) {
        if (offset == instructionOffset) {
          foundStart = true;
        } else {
          _skipInstructionImmediate(reader, opcode);
          continue;
        }
      }

      if (controlDepth == 0 && opcode == 0x04) {
        return true;
      }

      switch (opcode) {
        case 0x02:
        case 0x03:
        case 0x04:
        case 0x06:
        case 0x1f:
          controlDepth++;
        case 0x0b:
        case 0x18:
          if (controlDepth == 0) {
            return false;
          }
          controlDepth--;
        case 0x05:
        case 0x07:
        case 0x19:
          if (controlDepth == 0) {
            return false;
          }
      }

      if (controlDepth == 0 && _terminatesBranchHintScan(opcode)) {
        return false;
      }
      _skipInstructionImmediate(reader, opcode);
    }
    return false;
  }
}

bool _terminatesBranchHintScan(int opcode) {
  return opcode == 0x08 ||
      opcode == 0x09 ||
      opcode == 0x0a ||
      opcode == 0x0c ||
      opcode == 0x0e ||
      opcode == 0x0f ||
      opcode == 0x12 ||
      opcode == 0x13 ||
      opcode == 0x15;
}

void _skipInstructionImmediate(_ByteReader reader, int opcode) {
  switch (opcode) {
    case 0x02:
    case 0x03:
    case 0x04:
    case 0x06:
      _skipBlockType(reader);
    case 0x07:
    case 0x08:
    case 0x09:
    case 0x0c:
    case 0x0d:
    case 0x10:
    case 0x12:
    case 0x14:
    case 0x15:
    case 0x18:
    case 0x20:
    case 0x21:
    case 0x22:
    case 0x23:
    case 0x24:
    case 0x25:
    case 0x26:
    case 0xd2:
    case 0xd5:
    case 0xd6:
      reader.readVarUint32();
    case 0x0e:
      final labelCount = reader.readVarUint32();
      for (var i = 0; i < labelCount; i++) {
        reader.readVarUint32();
      }
      reader.readVarUint32();
    case 0x11:
    case 0x13:
      reader.readVarUint32();
      reader.readVarUint32();
    case 0x1c:
      final typeCount = reader.readVarUint32();
      for (var i = 0; i < typeCount; i++) {
        _skipValueType(reader);
      }
    case >= 0x28 && <= 0x3e:
      reader.readVarUint32();
      reader.readVarUint32();
    case 0x3f:
    case 0x40:
      reader.readVarUint32();
    case 0x41:
      reader.readVarInt32();
    case 0x42:
      reader.readVarInt64();
    case 0x43:
      reader.readBytes(4);
    case 0x44:
      reader.readBytes(8);
    case 0xd0:
      _skipHeapType(reader);
    case 0xfb:
      _skipGcImmediate(reader);
    case 0xfc:
      _skipBulkOrNumericImmediate(reader);
    case 0xfd:
      _skipSimdImmediate(reader);
    case 0xfe:
      _skipAtomicImmediate(reader);
    default:
      break;
  }
}

void _skipGcImmediate(_ByteReader reader) {
  final subOpcode = reader.readVarUint32();
  switch (subOpcode) {
    case 0:
    case 1:
    case 2:
    case 3:
    case 4:
    case 5:
    case 6:
    case 7:
    case 8:
    case 10:
    case 11:
    case 14:
    case 15:
    case 16:
    case 17:
    case 18:
    case 19:
    case 20:
    case 21:
    case 22:
    case 23:
    case 24:
    case 25:
    case 26:
    case 27:
    case 28:
    case 29:
    case 30:
    case 31:
    case 32:
    case 33:
    case 34:
    case 35:
    case 36:
    case 37:
    case 38:
    case 39:
    case 40:
    case 41:
      reader.readVarUint32();
    case 12:
    case 13:
      reader.readVarUint32();
      reader.readVarUint32();
    case 9:
      final count = reader.readVarUint32();
      for (var i = 0; i < count; i++) {
        reader.readVarUint32();
      }
    default:
      break;
  }
}

void _skipBulkOrNumericImmediate(_ByteReader reader) {
  final subOpcode = reader.readVarUint32();
  switch (subOpcode) {
    case 9:
    case 11:
    case 13:
    case 15:
    case 16:
    case 17:
      reader.readVarUint32();
    case 8:
    case 10:
    case 12:
    case 14:
      reader.readVarUint32();
      reader.readVarUint32();
    default:
      break;
  }
}

void _skipSimdImmediate(_ByteReader reader) {
  final subOpcode = reader.readVarUint32();
  switch (subOpcode) {
    case >= 0 && <= 11:
    case 92:
    case 93:
      reader.readVarUint32();
      reader.readVarUint32();
    case 12:
    case 13:
      reader.readBytes(16);
    case >= 21 && <= 34:
      reader.readByte();
    case >= 84 && <= 91:
      reader.readVarUint32();
      reader.readVarUint32();
      reader.readByte();
    default:
      break;
  }
}

void _skipAtomicImmediate(_ByteReader reader) {
  final subOpcode = reader.readVarUint32();
  switch (subOpcode) {
    case 3:
      reader.readVarUint32();
    default:
      reader.readVarUint32();
      reader.readVarUint32();
  }
}

void _skipLimits(_ByteReader reader) {
  final flags = reader.readByte();
  reader.readVarUint32();
  if ((flags & 0x01) != 0) {
    reader.readVarUint32();
  }
  if ((flags & 0x08) != 0) {
    reader.readVarUint32();
  }
}

void _skipBlockType(_ByteReader reader) {
  reader.readVarInt64();
}

void _skipValueType(_ByteReader reader) {
  final value = reader.readByte();
  if (value == 0x64 || value == 0x63) {
    _skipHeapType(reader);
  }
}

void _skipRefType(_ByteReader reader) {
  _skipValueType(reader);
}

void _skipHeapType(_ByteReader reader) {
  reader.readVarInt64();
}

final class _CodeBody {
  const _CodeBody({required this.instructionStart, required this.instructions});

  final int instructionStart;
  final Uint8List instructions;
}

final class _ByteReader {
  _ByteReader(this.bytes);

  final Uint8List bytes;
  int offset = 0;

  bool get isEOF => offset == bytes.length;

  int readByte() {
    if (offset >= bytes.length) {
      throw const FormatException('Unexpected EOF while reading byte.');
    }
    return bytes[offset++];
  }

  Uint8List readBytes(int length) {
    if (length < 0 || offset + length > bytes.length) {
      throw FormatException('Unexpected EOF while reading $length bytes.');
    }
    final start = offset;
    offset += length;
    return Uint8List.sublistView(bytes, start, offset);
  }

  _ByteReader readSubReader(int length) => _ByteReader(readBytes(length));

  Uint8List readRemainingBytes() => readBytes(bytes.length - offset);

  String readName() => utf8.decode(readBytes(readVarUint32()));

  int readVarUint32() {
    var result = 0;
    var shift = 0;
    for (var i = 0; i < 5; i++) {
      final byte = readByte();
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) {
        if (i == 4 && (byte & 0xf0) != 0) {
          throw const FormatException('Invalid varuint32 encoding.');
        }
        return result;
      }
      shift += 7;
    }
    throw const FormatException('Invalid varuint32 encoding.');
  }

  int readVarInt32() {
    final value = readVarInt64();
    if (value < -0x80000000 || value > 0x7fffffff) {
      throw const FormatException('Invalid varint32 encoding.');
    }
    return value;
  }

  int readVarInt64() {
    var result = BigInt.zero;
    var shift = 0;
    var byteCount = 0;
    var terminalByte = 0;
    while (true) {
      final byte = readByte();
      terminalByte = byte;
      byteCount++;
      result |= BigInt.from(byte & 0x7f) << shift;
      shift += 7;
      if ((byte & 0x80) == 0) {
        break;
      }
      if (byteCount >= 10) {
        throw const FormatException('Invalid varint64 encoding.');
      }
    }
    if (byteCount == 10 && (terminalByte & 0x7e) != 0) {
      throw const FormatException('Invalid varint64 encoding.');
    }
    if ((terminalByte & 0x40) != 0 && shift < 64) {
      result -= BigInt.one << shift;
    }
    return result.toInt();
  }

  void expectEof() {
    if (!isEOF) {
      throw FormatException(
        'Expected EOF, remaining: ${bytes.length - offset}.',
      );
    }
  }
}
