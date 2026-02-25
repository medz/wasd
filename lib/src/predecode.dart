import 'dart:typed_data';

import 'byte_reader.dart';
import 'features.dart';
import 'module.dart';
import 'opcode.dart';

final class MemArg {
  const MemArg({
    required this.align,
    required this.offset,
    this.memoryIndex = 0,
  });

  final int align;
  final int offset;
  final int memoryIndex;
}

final class Instruction {
  Instruction({
    required this.opcode,
    this.immediate,
    this.secondaryImmediate,
    this.floatImmediate,
    this.memArg,
    this.tableDepths,
    this.blockResultTypes,
    this.endIndex,
    this.elseIndex,
  });

  final int opcode;
  int? immediate;
  int? secondaryImmediate;
  double? floatImmediate;
  MemArg? memArg;
  List<int>? tableDepths;
  List<WasmValueType>? blockResultTypes;
  int? endIndex;
  int? elseIndex;
}

final class PredecodedFunction {
  const PredecodedFunction({
    required this.localTypes,
    required this.instructions,
  });

  final List<WasmValueType> localTypes;
  final List<Instruction> instructions;
}

enum _ControlKind { block, loop, if_ }

final class _ControlFrame {
  _ControlFrame({required this.kind, required this.startIndex});

  final _ControlKind kind;
  final int startIndex;
  int? elseInstructionIndex;
}

abstract final class WasmPredecoder {
  static PredecodedFunction decode(
    WasmCodeBody body,
    List<WasmFunctionType> moduleTypes, {
    WasmFeatureSet features = const WasmFeatureSet(),
  }) {
    final localTypes = <WasmValueType>[];
    for (final local in body.locals) {
      for (var i = 0; i < local.count; i++) {
        localTypes.add(local.type);
      }
    }

    final reader = ByteReader(body.instructions);
    final instructions = <Instruction>[];
    final controlStack = <_ControlFrame>[];

    while (!reader.isEOF) {
      final opcode = reader.readByte();

      switch (opcode) {
        case Opcodes.unreachable:
        case Opcodes.nop:
        case Opcodes.return_:
        case Opcodes.drop:
        case Opcodes.select:
        case Opcodes.refIsNull:
        case Opcodes.i32Eqz:
        case Opcodes.i32Eq:
        case Opcodes.i32Ne:
        case Opcodes.i32LtS:
        case Opcodes.i32LtU:
        case Opcodes.i32GtS:
        case Opcodes.i32GtU:
        case Opcodes.i32LeS:
        case Opcodes.i32LeU:
        case Opcodes.i32GeS:
        case Opcodes.i32GeU:
        case Opcodes.i64Eqz:
        case Opcodes.i64Eq:
        case Opcodes.i64Ne:
        case Opcodes.i64LtS:
        case Opcodes.i64LtU:
        case Opcodes.i64GtS:
        case Opcodes.i64GtU:
        case Opcodes.i64LeS:
        case Opcodes.i64LeU:
        case Opcodes.i64GeS:
        case Opcodes.i64GeU:
        case Opcodes.f32Eq:
        case Opcodes.f32Ne:
        case Opcodes.f32Lt:
        case Opcodes.f32Gt:
        case Opcodes.f32Le:
        case Opcodes.f32Ge:
        case Opcodes.f64Eq:
        case Opcodes.f64Ne:
        case Opcodes.f64Lt:
        case Opcodes.f64Gt:
        case Opcodes.f64Le:
        case Opcodes.f64Ge:
        case Opcodes.i32Clz:
        case Opcodes.i32Ctz:
        case Opcodes.i32Popcnt:
        case Opcodes.i32Add:
        case Opcodes.i32Sub:
        case Opcodes.i32Mul:
        case Opcodes.i32DivS:
        case Opcodes.i32DivU:
        case Opcodes.i32RemS:
        case Opcodes.i32RemU:
        case Opcodes.i32And:
        case Opcodes.i32Or:
        case Opcodes.i32Xor:
        case Opcodes.i32Shl:
        case Opcodes.i32ShrS:
        case Opcodes.i32ShrU:
        case Opcodes.i32Rotl:
        case Opcodes.i32Rotr:
        case Opcodes.i64Clz:
        case Opcodes.i64Ctz:
        case Opcodes.i64Popcnt:
        case Opcodes.i64Add:
        case Opcodes.i64Sub:
        case Opcodes.i64Mul:
        case Opcodes.i64DivS:
        case Opcodes.i64DivU:
        case Opcodes.i64RemS:
        case Opcodes.i64RemU:
        case Opcodes.i64And:
        case Opcodes.i64Or:
        case Opcodes.i64Xor:
        case Opcodes.i64Shl:
        case Opcodes.i64ShrS:
        case Opcodes.i64ShrU:
        case Opcodes.i64Rotl:
        case Opcodes.i64Rotr:
        case Opcodes.f32Abs:
        case Opcodes.f32Neg:
        case Opcodes.f32Ceil:
        case Opcodes.f32Floor:
        case Opcodes.f32Trunc:
        case Opcodes.f32Nearest:
        case Opcodes.f32Sqrt:
        case Opcodes.f32Add:
        case Opcodes.f32Sub:
        case Opcodes.f32Mul:
        case Opcodes.f32Div:
        case Opcodes.f32Min:
        case Opcodes.f32Max:
        case Opcodes.f32CopySign:
        case Opcodes.f64Abs:
        case Opcodes.f64Neg:
        case Opcodes.f64Ceil:
        case Opcodes.f64Floor:
        case Opcodes.f64Trunc:
        case Opcodes.f64Nearest:
        case Opcodes.f64Sqrt:
        case Opcodes.f64Add:
        case Opcodes.f64Sub:
        case Opcodes.f64Mul:
        case Opcodes.f64Div:
        case Opcodes.f64Min:
        case Opcodes.f64Max:
        case Opcodes.f64CopySign:
        case Opcodes.i32WrapI64:
        case Opcodes.i32TruncF32S:
        case Opcodes.i32TruncF32U:
        case Opcodes.i32TruncF64S:
        case Opcodes.i32TruncF64U:
        case Opcodes.i64ExtendI32S:
        case Opcodes.i64ExtendI32U:
        case Opcodes.i64TruncF32S:
        case Opcodes.i64TruncF32U:
        case Opcodes.i64TruncF64S:
        case Opcodes.i64TruncF64U:
        case Opcodes.f32ConvertI32S:
        case Opcodes.f32ConvertI32U:
        case Opcodes.f32ConvertI64S:
        case Opcodes.f32ConvertI64U:
        case Opcodes.f32DemoteF64:
        case Opcodes.f64ConvertI32S:
        case Opcodes.f64ConvertI32U:
        case Opcodes.f64ConvertI64S:
        case Opcodes.f64ConvertI64U:
        case Opcodes.f64PromoteF32:
        case Opcodes.i32ReinterpretF32:
        case Opcodes.i64ReinterpretF64:
        case Opcodes.f32ReinterpretI32:
        case Opcodes.f64ReinterpretI64:
        case Opcodes.i32Extend8S:
        case Opcodes.i32Extend16S:
        case Opcodes.i64Extend8S:
        case Opcodes.i64Extend16S:
        case Opcodes.i64Extend32S:
          instructions.add(Instruction(opcode: opcode));

        case Opcodes.block:
          instructions.add(
            Instruction(
              opcode: opcode,
              blockResultTypes: _readBlockResultTypes(reader, moduleTypes),
            ),
          );
          controlStack.add(
            _ControlFrame(
              kind: _ControlKind.block,
              startIndex: instructions.length - 1,
            ),
          );

        case Opcodes.loop:
          instructions.add(
            Instruction(
              opcode: opcode,
              blockResultTypes: _readBlockResultTypes(reader, moduleTypes),
            ),
          );
          controlStack.add(
            _ControlFrame(
              kind: _ControlKind.loop,
              startIndex: instructions.length - 1,
            ),
          );

        case Opcodes.if_:
          instructions.add(
            Instruction(
              opcode: opcode,
              blockResultTypes: _readBlockResultTypes(reader, moduleTypes),
            ),
          );
          controlStack.add(
            _ControlFrame(
              kind: _ControlKind.if_,
              startIndex: instructions.length - 1,
            ),
          );

        case Opcodes.else_:
          if (controlStack.isEmpty ||
              controlStack.last.kind != _ControlKind.if_) {
            throw const FormatException('`else` without matching `if`.');
          }
          instructions.add(Instruction(opcode: opcode));
          final frame = controlStack.last;
          frame.elseInstructionIndex = instructions.length - 1;
          instructions[frame.startIndex].elseIndex = frame.elseInstructionIndex;

        case Opcodes.end:
          final endIndex = instructions.length;
          instructions.add(Instruction(opcode: opcode));

          if (controlStack.isNotEmpty) {
            final frame = controlStack.removeLast();
            instructions[frame.startIndex].endIndex = endIndex;
            if (frame.elseInstructionIndex != null) {
              instructions[frame.elseInstructionIndex!].endIndex = endIndex;
            }
            continue;
          }

          if (!reader.isEOF) {
            throw const FormatException(
              'Unexpected trailing instructions after function end.',
            );
          }

          return PredecodedFunction(
            localTypes: List.unmodifiable(localTypes),
            instructions: List.unmodifiable(instructions),
          );

        case Opcodes.br:
        case Opcodes.brIf:
        case Opcodes.call:
        case Opcodes.returnCall:
        case Opcodes.localGet:
        case Opcodes.localSet:
        case Opcodes.localTee:
        case Opcodes.globalGet:
        case Opcodes.globalSet:
        case Opcodes.tableGet:
        case Opcodes.tableSet:
        case Opcodes.memorySize:
        case Opcodes.memoryGrow:
        case Opcodes.refFunc:
          instructions.add(
            Instruction(opcode: opcode, immediate: reader.readVarUint32()),
          );

        case Opcodes.callIndirect:
          instructions.add(
            Instruction(
              opcode: opcode,
              immediate: reader.readVarUint32(),
              secondaryImmediate: reader.readVarUint32(),
            ),
          );

        case Opcodes.returnCallIndirect:
          instructions.add(
            Instruction(
              opcode: opcode,
              immediate: reader.readVarUint32(),
              secondaryImmediate: reader.readVarUint32(),
            ),
          );

        case Opcodes.selectT:
          final arity = reader.readVarUint32();
          for (var i = 0; i < arity; i++) {
            _readSelectValueType(reader);
          }
          instructions.add(Instruction(opcode: opcode, immediate: arity));

        case Opcodes.brTable:
          final targetCount = reader.readVarUint32();
          final depths = <int>[];
          for (var i = 0; i < targetCount + 1; i++) {
            depths.add(reader.readVarUint32());
          }
          instructions.add(
            Instruction(opcode: opcode, tableDepths: List.unmodifiable(depths)),
          );

        case Opcodes.i32Const:
          instructions.add(
            Instruction(opcode: opcode, immediate: reader.readVarInt32()),
          );

        case Opcodes.i64Const:
          instructions.add(
            Instruction(opcode: opcode, immediate: reader.readVarInt64()),
          );

        case Opcodes.f32Const:
          instructions.add(
            Instruction(
              opcode: opcode,
              floatImmediate: _decodeF32(reader.readBytes(4)),
            ),
          );

        case Opcodes.f64Const:
          instructions.add(
            Instruction(
              opcode: opcode,
              floatImmediate: _decodeF64(reader.readBytes(8)),
            ),
          );

        case Opcodes.refNull:
          instructions.add(
            Instruction(opcode: opcode, immediate: reader.readByte()),
          );

        case Opcodes.i32Load:
        case Opcodes.i64Load:
        case Opcodes.f32Load:
        case Opcodes.f64Load:
        case Opcodes.i32Load8S:
        case Opcodes.i32Load8U:
        case Opcodes.i32Load16S:
        case Opcodes.i32Load16U:
        case Opcodes.i64Load8S:
        case Opcodes.i64Load8U:
        case Opcodes.i64Load16S:
        case Opcodes.i64Load16U:
        case Opcodes.i64Load32S:
        case Opcodes.i64Load32U:
        case Opcodes.i32Store:
        case Opcodes.i64Store:
        case Opcodes.f32Store:
        case Opcodes.f64Store:
        case Opcodes.i32Store8:
        case Opcodes.i32Store16:
        case Opcodes.i64Store8:
        case Opcodes.i64Store16:
        case Opcodes.i64Store32:
          instructions.add(
            Instruction(opcode: opcode, memArg: _readMemArg(reader)),
          );

        case 0xfc:
          _decodePrefixedInstruction(reader, instructions);

        case 0xfd:
          if (!features.simd) {
            throw UnsupportedError(
              'SIMD opcode prefix (0xFD) encountered but `simd` feature is disabled.',
            );
          }
          throw UnsupportedError(
            'SIMD feature gate is enabled, but SIMD execution is not implemented yet.',
          );

        case 0xfe:
          if (!features.threads) {
            throw UnsupportedError(
              'Threads/atomics opcode prefix (0xFE) encountered but `threads` feature is disabled.',
            );
          }
          _decodeThreadInstruction(reader, instructions);

        case 0xfb:
          if (!features.gc) {
            throw UnsupportedError(
              'GC opcode prefix (0xFB) encountered but `gc` feature is disabled.',
            );
          }
          throw UnsupportedError(
            'GC feature gate is enabled, but GC execution is not implemented yet.',
          );

        default:
          if (_isExceptionHandlingOpcode(opcode)) {
            if (!features.exceptionHandling) {
              throw UnsupportedError(
                'Exception-handling opcode 0x${opcode.toRadixString(16)} encountered but `exceptionHandling` feature is disabled.',
              );
            }
            throw UnsupportedError(
              'Exception-handling feature gate is enabled, but EH execution is not implemented yet.',
            );
          }
          throw UnsupportedError(
            'Unsupported opcode in runtime: 0x${opcode.toRadixString(16)}',
          );
      }
    }

    throw const FormatException('Function body ended without final `end`.');
  }

  static void _decodePrefixedInstruction(
    ByteReader reader,
    List<Instruction> instructions,
  ) {
    final subOpcode = reader.readVarUint32();
    final pseudoOpcode = 0xfc00 | subOpcode;

    switch (pseudoOpcode) {
      case Opcodes.i32TruncSatF32S:
      case Opcodes.i32TruncSatF32U:
      case Opcodes.i32TruncSatF64S:
      case Opcodes.i32TruncSatF64U:
      case Opcodes.i64TruncSatF32S:
      case Opcodes.i64TruncSatF32U:
      case Opcodes.i64TruncSatF64S:
      case Opcodes.i64TruncSatF64U:
      case Opcodes.i64Add128:
      case Opcodes.i64Sub128:
      case Opcodes.i64MulWideS:
      case Opcodes.i64MulWideU:
        instructions.add(Instruction(opcode: pseudoOpcode));

      case Opcodes.dataDrop:
      case Opcodes.elemDrop:
      case Opcodes.tableGrow:
      case Opcodes.tableSize:
      case Opcodes.tableFill:
        instructions.add(
          Instruction(opcode: pseudoOpcode, immediate: reader.readVarUint32()),
        );

      case Opcodes.memoryInit:
      case Opcodes.memoryCopy:
      case Opcodes.tableInit:
      case Opcodes.tableCopy:
        instructions.add(
          Instruction(
            opcode: pseudoOpcode,
            immediate: reader.readVarUint32(),
            secondaryImmediate: reader.readVarUint32(),
          ),
        );

      case Opcodes.memoryFill:
        instructions.add(
          Instruction(opcode: pseudoOpcode, immediate: reader.readVarUint32()),
        );

      default:
        throw UnsupportedError(
          'Unsupported 0xFC sub-opcode: 0x${subOpcode.toRadixString(16)}',
        );
    }
  }

  static void _decodeThreadInstruction(
    ByteReader reader,
    List<Instruction> instructions,
  ) {
    final subOpcode = reader.readVarUint32();
    final pseudoOpcode = 0xfe00 | subOpcode;

    switch (pseudoOpcode) {
      case Opcodes.memoryAtomicNotify:
      case Opcodes.memoryAtomicWait32:
      case Opcodes.memoryAtomicWait64:
      case Opcodes.i32AtomicLoad:
      case Opcodes.i64AtomicLoad:
      case Opcodes.i32AtomicLoad8U:
      case Opcodes.i32AtomicLoad16U:
      case Opcodes.i64AtomicLoad8U:
      case Opcodes.i64AtomicLoad16U:
      case Opcodes.i64AtomicLoad32U:
      case Opcodes.i32AtomicStore:
      case Opcodes.i64AtomicStore:
      case Opcodes.i32AtomicStore8:
      case Opcodes.i32AtomicStore16:
      case Opcodes.i64AtomicStore8:
      case Opcodes.i64AtomicStore16:
      case Opcodes.i64AtomicStore32:
      case Opcodes.i32AtomicRmwAdd:
      case Opcodes.i64AtomicRmwAdd:
      case Opcodes.i32AtomicRmw8AddU:
      case Opcodes.i32AtomicRmw16AddU:
      case Opcodes.i64AtomicRmw8AddU:
      case Opcodes.i64AtomicRmw16AddU:
      case Opcodes.i64AtomicRmw32AddU:
      case Opcodes.i32AtomicRmwSub:
      case Opcodes.i64AtomicRmwSub:
      case Opcodes.i32AtomicRmw8SubU:
      case Opcodes.i32AtomicRmw16SubU:
      case Opcodes.i64AtomicRmw8SubU:
      case Opcodes.i64AtomicRmw16SubU:
      case Opcodes.i64AtomicRmw32SubU:
      case Opcodes.i32AtomicRmwAnd:
      case Opcodes.i64AtomicRmwAnd:
      case Opcodes.i32AtomicRmw8AndU:
      case Opcodes.i32AtomicRmw16AndU:
      case Opcodes.i64AtomicRmw8AndU:
      case Opcodes.i64AtomicRmw16AndU:
      case Opcodes.i64AtomicRmw32AndU:
      case Opcodes.i32AtomicRmwOr:
      case Opcodes.i64AtomicRmwOr:
      case Opcodes.i32AtomicRmw8OrU:
      case Opcodes.i32AtomicRmw16OrU:
      case Opcodes.i64AtomicRmw8OrU:
      case Opcodes.i64AtomicRmw16OrU:
      case Opcodes.i64AtomicRmw32OrU:
      case Opcodes.i32AtomicRmwXor:
      case Opcodes.i64AtomicRmwXor:
      case Opcodes.i32AtomicRmw8XorU:
      case Opcodes.i32AtomicRmw16XorU:
      case Opcodes.i64AtomicRmw8XorU:
      case Opcodes.i64AtomicRmw16XorU:
      case Opcodes.i64AtomicRmw32XorU:
      case Opcodes.i32AtomicRmwXchg:
      case Opcodes.i64AtomicRmwXchg:
      case Opcodes.i32AtomicRmw8XchgU:
      case Opcodes.i32AtomicRmw16XchgU:
      case Opcodes.i64AtomicRmw8XchgU:
      case Opcodes.i64AtomicRmw16XchgU:
      case Opcodes.i64AtomicRmw32XchgU:
      case Opcodes.i32AtomicRmwCmpxchg:
      case Opcodes.i64AtomicRmwCmpxchg:
      case Opcodes.i32AtomicRmw8CmpxchgU:
      case Opcodes.i32AtomicRmw16CmpxchgU:
      case Opcodes.i64AtomicRmw8CmpxchgU:
      case Opcodes.i64AtomicRmw16CmpxchgU:
      case Opcodes.i64AtomicRmw32CmpxchgU:
        instructions.add(
          Instruction(opcode: pseudoOpcode, memArg: _readMemArg(reader)),
        );

      case Opcodes.atomicFence:
        final reserved = reader.readVarUint32();
        if (reserved != 0) {
          throw const FormatException(
            'Invalid atomic.fence immediate: expected 0.',
          );
        }
        instructions.add(Instruction(opcode: pseudoOpcode));

      default:
        throw UnsupportedError(
          'Unsupported 0xFE sub-opcode: 0x${subOpcode.toRadixString(16)}',
        );
    }
  }

  static MemArg _readMemArg(ByteReader reader) {
    final encodedAlign = reader.readVarUint32();
    // Multi-memory encodes a memory-index-present flag in bit 6.
    final align = encodedAlign & 0x3f;
    final hasMemoryIndex = (encodedAlign & 0x40) != 0;
    final memoryIndex = hasMemoryIndex ? reader.readVarUint32() : 0;
    return MemArg(
      align: align,
      offset: reader.readVarUint32(),
      memoryIndex: memoryIndex,
    );
  }

  static List<WasmValueType> _readBlockResultTypes(
    ByteReader reader,
    List<WasmFunctionType> moduleTypes,
  ) {
    final first = reader.readByte();

    if (first == 0x40) {
      return const [];
    }

    if (first == 0x7f || first == 0x7e || first == 0x7d || first == 0x7c) {
      return [WasmValueTypeCodec.fromByte(first)];
    }

    final typeIndex = _readSignedLeb33WithFirst(reader, first);
    if (typeIndex < 0 || typeIndex >= moduleTypes.length) {
      throw FormatException('Invalid block type index: $typeIndex');
    }

    return List<WasmValueType>.from(moduleTypes[typeIndex].results);
  }

  static void _readSelectValueType(ByteReader reader) {
    final typeByte = reader.readByte();
    switch (typeByte) {
      case 0x7f: // i32
      case 0x7e: // i64
      case 0x7d: // f32
      case 0x7c: // f64
      case 0x70: // funcref
      case 0x6f: // externref
        return;
      default:
        throw UnsupportedError(
          'Unsupported select type: 0x${typeByte.toRadixString(16)}',
        );
    }
  }

  static int _readSignedLeb33WithFirst(ByteReader reader, int firstByte) {
    var result = firstByte & 0x7f;
    var shift = 7;
    var byte = firstByte;

    while ((byte & 0x80) != 0) {
      byte = reader.readByte();
      result |= (byte & 0x7f) << shift;
      shift += 7;
      if (shift > 35) {
        throw const FormatException('Invalid blocktype LEB encoding.');
      }
    }

    if (shift < 33 && (byte & 0x40) != 0) {
      result |= -1 << shift;
    }

    return result;
  }

  static double _decodeF32(Uint8List bytes) {
    return ByteData.sublistView(bytes).getFloat32(0, Endian.little);
  }

  static double _decodeF64(Uint8List bytes) {
    return ByteData.sublistView(bytes).getFloat64(0, Endian.little);
  }

  static bool _isExceptionHandlingOpcode(int opcode) {
    return switch (opcode) {
      0x06 || // try
      0x07 || // catch
      0x08 || // throw
      0x09 || // rethrow
      0x19 || // catch_all
      0x1a => true, // delegate
      _ => false,
    };
  }
}
