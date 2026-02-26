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

abstract final class TryTableCatchKind {
  static const int catchTag = 0;
  static const int catchRef = 1;
  static const int catchAll = 2;
  static const int catchAllRef = 3;
}

final class TryTableCatchClause {
  const TryTableCatchClause({
    required this.kind,
    required this.labelDepth,
    this.tagIndex,
  });

  final int kind;
  final int labelDepth;
  final int? tagIndex;
}

final class Instruction {
  Instruction({
    required this.opcode,
    this.immediate,
    this.wideImmediate,
    this.secondaryImmediate,
    this.floatImmediate,
    this.floatBytesImmediate,
    this.memArg,
    this.tableDepths,
    this.blockParameterTypes,
    this.blockParameterTypeSignatures,
    this.blockResultTypes,
    this.blockResultTypeSignatures,
    this.gcRefType,
    this.gcBrOnCast,
    this.tryTableCatches,
    this.endIndex,
    this.elseIndex,
  });

  final int opcode;
  int? immediate;
  Object? wideImmediate;
  int? secondaryImmediate;
  double? floatImmediate;
  Uint8List? floatBytesImmediate;
  MemArg? memArg;
  List<int>? tableDepths;
  List<WasmValueType>? blockParameterTypes;
  List<String>? blockParameterTypeSignatures;
  List<WasmValueType>? blockResultTypes;
  List<String>? blockResultTypeSignatures;
  GcRefTypeImmediate? gcRefType;
  GcBrOnCastImmediate? gcBrOnCast;
  List<TryTableCatchClause>? tryTableCatches;
  int? endIndex;
  int? elseIndex;
}

final class GcRefTypeImmediate {
  const GcRefTypeImmediate({
    required this.nullable,
    required this.exact,
    required this.heapType,
  });

  final bool nullable;
  final bool exact;
  final int heapType;
}

final class GcBrOnCastImmediate {
  const GcBrOnCastImmediate({
    required this.flags,
    required this.depth,
    required this.sourceType,
    required this.targetType,
  });

  final int flags;
  final int depth;
  final GcRefTypeImmediate sourceType;
  final GcRefTypeImmediate targetType;
}

final class PredecodedFunction {
  const PredecodedFunction({
    required this.localTypes,
    required this.instructions,
  });

  final List<WasmValueType> localTypes;
  final List<Instruction> instructions;
}

enum _ControlKind { block, loop, if_, tryTable }

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
    List<bool> memory64ByIndex = const <bool>[],
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
        case Opcodes.throwRef:
        case Opcodes.return_:
        case Opcodes.drop:
        case Opcodes.select:
        case Opcodes.refIsNull:
        case Opcodes.refEq:
        case Opcodes.refAsNonNull:
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
          final blockType = _readBlockTypeInfo(reader, moduleTypes);
          instructions.add(
            Instruction(
              opcode: opcode,
              blockParameterTypes: blockType.paramTypes,
              blockParameterTypeSignatures: blockType.paramSignatures,
              blockResultTypes: blockType.resultTypes,
              blockResultTypeSignatures: blockType.resultSignatures,
            ),
          );
          controlStack.add(
            _ControlFrame(
              kind: _ControlKind.block,
              startIndex: instructions.length - 1,
            ),
          );

        case Opcodes.loop:
          final blockType = _readBlockTypeInfo(reader, moduleTypes);
          instructions.add(
            Instruction(
              opcode: opcode,
              blockParameterTypes: blockType.paramTypes,
              blockParameterTypeSignatures: blockType.paramSignatures,
              blockResultTypes: blockType.resultTypes,
              blockResultTypeSignatures: blockType.resultSignatures,
            ),
          );
          controlStack.add(
            _ControlFrame(
              kind: _ControlKind.loop,
              startIndex: instructions.length - 1,
            ),
          );

        case Opcodes.if_:
          final blockType = _readBlockTypeInfo(reader, moduleTypes);
          instructions.add(
            Instruction(
              opcode: opcode,
              blockParameterTypes: blockType.paramTypes,
              blockParameterTypeSignatures: blockType.paramSignatures,
              blockResultTypes: blockType.resultTypes,
              blockResultTypeSignatures: blockType.resultSignatures,
            ),
          );
          controlStack.add(
            _ControlFrame(
              kind: _ControlKind.if_,
              startIndex: instructions.length - 1,
            ),
          );

        case Opcodes.tryTable:
          final blockType = _readBlockTypeInfo(reader, moduleTypes);
          final catchCount = reader.readVarUint32();
          final catches = List<TryTableCatchClause>.generate(
            catchCount,
            (_) => _readTryTableCatchClause(reader),
            growable: false,
          );
          instructions.add(
            Instruction(
              opcode: opcode,
              blockParameterTypes: blockType.paramTypes,
              blockParameterTypeSignatures: blockType.paramSignatures,
              blockResultTypes: blockType.resultTypes,
              blockResultTypeSignatures: blockType.resultSignatures,
              tryTableCatches: catches,
            ),
          );
          controlStack.add(
            _ControlFrame(
              kind: _ControlKind.tryTable,
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
        case Opcodes.brOnNull:
        case Opcodes.brOnNonNull:
        case Opcodes.call:
        case Opcodes.callRef:
        case Opcodes.returnCall:
        case Opcodes.returnCallRef:
        case Opcodes.localGet:
        case Opcodes.localSet:
        case Opcodes.localTee:
        case Opcodes.globalGet:
        case Opcodes.globalSet:
        case Opcodes.tableGet:
        case Opcodes.tableSet:
        case Opcodes.throwTag:
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
            _readSelectValueType(reader, moduleTypes);
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
          final wideImmediate = reader.readVarInt64Value();
          instructions.add(
            Instruction(
              opcode: opcode,
              immediate: wideImmediate is int ? wideImmediate : 0,
              wideImmediate: wideImmediate,
            ),
          );

        case Opcodes.f32Const:
          final floatBytes = reader.readBytes(4);
          instructions.add(
            Instruction(
              opcode: opcode,
              floatImmediate: _decodeF32(floatBytes),
              floatBytesImmediate: floatBytes,
            ),
          );

        case Opcodes.f64Const:
          final floatBytes = reader.readBytes(8);
          instructions.add(
            Instruction(
              opcode: opcode,
              floatImmediate: _decodeF64(floatBytes),
              floatBytesImmediate: floatBytes,
            ),
          );

        case Opcodes.refNull:
          final heapType = _readHeapType(reader);
          instructions.add(
            Instruction(
              opcode: opcode,
              gcRefType: GcRefTypeImmediate(
                nullable: true,
                exact: heapType.$2,
                heapType: heapType.$1,
              ),
            ),
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
            Instruction(
              opcode: opcode,
              memArg: _readMemArg(reader, memory64ByIndex),
            ),
          );

        case 0xfc:
          _decodePrefixedInstruction(reader, instructions);

        case 0xfd:
          if (!features.simd) {
            throw UnsupportedError(
              'SIMD opcode prefix (0xFD) encountered but `simd` feature is disabled.',
            );
          }
          _decodeSimdInstruction(reader, instructions, memory64ByIndex);

        case 0xfe:
          if (!features.threads) {
            throw UnsupportedError(
              'Threads/atomics opcode prefix (0xFE) encountered but `threads` feature is disabled.',
            );
          }
          _decodeThreadInstruction(reader, instructions, memory64ByIndex);

        case 0xfb:
          if (!features.gc) {
            throw UnsupportedError(
              'GC opcode prefix (0xFB) encountered but `gc` feature is disabled.',
            );
          }
          _decodeGcInstruction(reader, instructions);

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

  static void _decodeGcInstruction(
    ByteReader reader,
    List<Instruction> instructions,
  ) {
    final subOpcode = reader.readVarUint32();
    final pseudoOpcode = 0xfb00 | subOpcode;
    switch (pseudoOpcode) {
      case Opcodes.structNew:
      case Opcodes.structNewDefault:
      case Opcodes.structNewDesc:
      case Opcodes.structNewDefaultDesc:
      case Opcodes.arrayNew:
      case Opcodes.arrayNewDefault:
      case Opcodes.arrayGet:
      case Opcodes.arrayGetS:
      case Opcodes.arrayGetU:
      case Opcodes.arraySet:
      case Opcodes.arrayFill:
      case Opcodes.refGetDesc:
        instructions.add(
          Instruction(opcode: pseudoOpcode, immediate: reader.readVarUint32()),
        );
      case Opcodes.structSet:
        instructions.add(
          Instruction(
            opcode: pseudoOpcode,
            immediate: reader.readVarUint32(),
            secondaryImmediate: reader.readVarUint32(),
          ),
        );
      case Opcodes.structGet:
      case Opcodes.structGetU:
      case Opcodes.structGetS:
      case Opcodes.arrayNewData:
      case Opcodes.arrayNewElem:
      case Opcodes.arrayInitElem:
      case Opcodes.arrayInitData:
      case Opcodes.arrayCopy:
        instructions.add(
          Instruction(
            opcode: pseudoOpcode,
            immediate: reader.readVarUint32(),
            secondaryImmediate: reader.readVarUint32(),
          ),
        );
      case Opcodes.arrayNewFixed:
        instructions.add(
          Instruction(
            opcode: pseudoOpcode,
            immediate: reader.readVarUint32(),
            secondaryImmediate: reader.readVarUint32(),
          ),
        );
      case Opcodes.arrayLen:
      case Opcodes.anyConvertExtern:
      case Opcodes.externConvertAny:
      case Opcodes.refI31:
      case Opcodes.i31GetS:
      case Opcodes.i31GetU:
        instructions.add(Instruction(opcode: pseudoOpcode));
      case Opcodes.refTest:
      case Opcodes.refTestNullable:
      case Opcodes.refCast:
      case Opcodes.refCastNullable:
      case Opcodes.refCastDesc:
      case Opcodes.refCastDescEq:
        final baseRefType = _readGcRefType(reader);
        final nullable = switch (pseudoOpcode) {
          Opcodes.refTest => false,
          Opcodes.refTestNullable => true,
          Opcodes.refCast => false,
          Opcodes.refCastNullable => true,
          Opcodes.refCastDesc => false,
          Opcodes.refCastDescEq => true,
          _ => baseRefType.nullable,
        };
        instructions.add(
          Instruction(
            opcode: pseudoOpcode,
            gcRefType: GcRefTypeImmediate(
              nullable: nullable,
              exact: baseRefType.exact,
              heapType: baseRefType.heapType,
            ),
          ),
        );
      case Opcodes.brOnCast:
      case Opcodes.brOnCastFail:
      case Opcodes.brOnCastDescEq:
      case Opcodes.brOnCastDescEqFail:
        final flags = reader.readVarUint32();
        final depth = reader.readVarUint32();
        final sourceBase = _readGcRefType(reader);
        final targetBase = _readGcRefType(reader);
        final sourceType = GcRefTypeImmediate(
          nullable: (flags & 0x01) != 0,
          exact: sourceBase.exact,
          heapType: sourceBase.heapType,
        );
        final targetType = GcRefTypeImmediate(
          nullable: (flags & 0x02) != 0,
          exact: targetBase.exact,
          heapType: targetBase.heapType,
        );
        instructions.add(
          Instruction(
            opcode: pseudoOpcode,
            gcBrOnCast: GcBrOnCastImmediate(
              flags: flags,
              depth: depth,
              sourceType: sourceType,
              targetType: targetType,
            ),
          ),
        );
      default:
        throw UnsupportedError(
          'Unsupported 0xFB sub-opcode: 0x${subOpcode.toRadixString(16)}',
        );
    }
  }

  static void _decodeThreadInstruction(
    ByteReader reader,
    List<Instruction> instructions,
    List<bool> memory64ByIndex,
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
          Instruction(
            opcode: pseudoOpcode,
            memArg: _readMemArg(reader, memory64ByIndex),
          ),
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

  static void _decodeSimdInstruction(
    ByteReader reader,
    List<Instruction> instructions,
    List<bool> memory64ByIndex,
  ) {
    final subOpcode = reader.readVarUint32();
    final pseudoOpcode = subOpcode <= 0xff
        ? (0xfd00 | subOpcode)
        : (0xfd0000 | subOpcode);
    switch (pseudoOpcode) {
      case Opcodes.v128Load:
      case Opcodes.v128Store:
        instructions.add(
          Instruction(
            opcode: pseudoOpcode,
            memArg: _readSimdMemArg(
              reader,
              memory64ByIndex,
              maxAlign: 4,
              opcode: pseudoOpcode,
            ),
          ),
        );
      case Opcodes.v128Load8x8S:
      case Opcodes.v128Load8x8U:
      case Opcodes.v128Load16x4S:
      case Opcodes.v128Load16x4U:
      case Opcodes.v128Load32x2S:
      case Opcodes.v128Load32x2U:
      case Opcodes.v128Load64Splat:
      case Opcodes.v128Load64Zero:
        instructions.add(
          Instruction(
            opcode: pseudoOpcode,
            memArg: _readSimdMemArg(
              reader,
              memory64ByIndex,
              maxAlign: 3,
              opcode: pseudoOpcode,
            ),
          ),
        );
      case Opcodes.v128Load32Splat:
      case Opcodes.v128Load32Zero:
        instructions.add(
          Instruction(
            opcode: pseudoOpcode,
            memArg: _readSimdMemArg(
              reader,
              memory64ByIndex,
              maxAlign: 2,
              opcode: pseudoOpcode,
            ),
          ),
        );
      case Opcodes.v128Load16Splat:
        instructions.add(
          Instruction(
            opcode: pseudoOpcode,
            memArg: _readSimdMemArg(
              reader,
              memory64ByIndex,
              maxAlign: 1,
              opcode: pseudoOpcode,
            ),
          ),
        );
      case Opcodes.v128Load8Splat:
        instructions.add(
          Instruction(
            opcode: pseudoOpcode,
            memArg: _readSimdMemArg(
              reader,
              memory64ByIndex,
              maxAlign: 0,
              opcode: pseudoOpcode,
            ),
          ),
        );
      case Opcodes.f32x4DemoteF64x2Zero:
      case Opcodes.f64x2PromoteLowF32x4:
        instructions.add(Instruction(opcode: pseudoOpcode));
      case Opcodes.v128Const:
        instructions.add(
          Instruction(
            opcode: pseudoOpcode,
            floatBytesImmediate: reader.readBytes(16),
          ),
        );
      case Opcodes.i8x16Shuffle:
        final lanes = reader.readBytes(16);
        for (var lane = 0; lane < lanes.length; lane++) {
          if (lanes[lane] > 31) {
            throw FormatException(
              'Invalid i8x16.shuffle lane index ${lanes[lane]}.',
            );
          }
        }
        instructions.add(
          Instruction(
            opcode: pseudoOpcode,
            floatBytesImmediate: lanes,
          ),
        );
      case Opcodes.i8x16Splat:
      case Opcodes.i16x8Splat:
      case Opcodes.i32x4Splat:
      case Opcodes.i64x2Splat:
      case Opcodes.f32x4Splat:
      case Opcodes.f64x2Splat:
      case Opcodes.i8x16Swizzle:
      case Opcodes.i8x16Abs:
      case Opcodes.i8x16Neg:
      case Opcodes.i8x16Popcnt:
      case Opcodes.i8x16NarrowI16x8S:
      case Opcodes.i8x16NarrowI16x8U:
      case Opcodes.i16x8NarrowI32x4S:
      case Opcodes.i16x8NarrowI32x4U:
      case Opcodes.i16x8Abs:
      case Opcodes.i16x8Neg:
      case Opcodes.i32x4Abs:
      case Opcodes.i32x4Neg:
      case Opcodes.i64x2Abs:
      case Opcodes.i64x2Neg:
      case Opcodes.i8x16Eq:
      case Opcodes.i8x16Ne:
      case Opcodes.i8x16LtS:
      case Opcodes.i8x16LtU:
      case Opcodes.i8x16GtS:
      case Opcodes.i8x16GtU:
      case Opcodes.i8x16LeS:
      case Opcodes.i8x16LeU:
      case Opcodes.i8x16GeS:
      case Opcodes.i8x16GeU:
      case Opcodes.i16x8Eq:
      case Opcodes.i16x8Ne:
      case Opcodes.i16x8LtS:
      case Opcodes.i16x8LtU:
      case Opcodes.i16x8GtS:
      case Opcodes.i16x8GtU:
      case Opcodes.i16x8LeS:
      case Opcodes.i16x8LeU:
      case Opcodes.i16x8GeS:
      case Opcodes.i16x8GeU:
      case Opcodes.i32x4Eq:
      case Opcodes.i32x4Ne:
      case Opcodes.i32x4LtS:
      case Opcodes.i32x4LtU:
      case Opcodes.i32x4GtS:
      case Opcodes.i32x4GtU:
      case Opcodes.i32x4LeS:
      case Opcodes.i32x4LeU:
      case Opcodes.i32x4GeS:
      case Opcodes.i32x4GeU:
      case Opcodes.i64x2Eq:
      case Opcodes.i64x2Ne:
      case Opcodes.i64x2LtS:
      case Opcodes.i64x2GtS:
      case Opcodes.i64x2LeS:
      case Opcodes.i64x2GeS:
      case Opcodes.f32x4Eq:
      case Opcodes.f32x4Ne:
      case Opcodes.f32x4Lt:
      case Opcodes.f32x4Gt:
      case Opcodes.f32x4Le:
      case Opcodes.f32x4Ge:
      case Opcodes.f64x2Eq:
      case Opcodes.f64x2Ne:
      case Opcodes.f64x2Lt:
      case Opcodes.f64x2Gt:
      case Opcodes.f64x2Le:
      case Opcodes.f64x2Ge:
      case Opcodes.v128Not:
      case Opcodes.v128And:
      case Opcodes.v128Andnot:
      case Opcodes.v128Or:
      case Opcodes.v128Xor:
      case Opcodes.v128Bitselect:
      case Opcodes.v128AnyTrue:
      case Opcodes.i8x16AllTrue:
      case Opcodes.i8x16Bitmask:
      case Opcodes.i8x16Shl:
      case Opcodes.i8x16ShrS:
      case Opcodes.i8x16ShrU:
      case Opcodes.i8x16Add:
      case Opcodes.i8x16AddSatS:
      case Opcodes.i8x16AddSatU:
      case Opcodes.i8x16Sub:
      case Opcodes.i8x16SubSatS:
      case Opcodes.i8x16SubSatU:
      case Opcodes.i8x16MinS:
      case Opcodes.i8x16MinU:
      case Opcodes.i8x16MaxS:
      case Opcodes.i8x16MaxU:
      case Opcodes.i8x16AvgrU:
      case Opcodes.i16x8ExtAddPairwiseI8x16S:
      case Opcodes.i16x8ExtAddPairwiseI8x16U:
      case Opcodes.i32x4ExtAddPairwiseI16x8S:
      case Opcodes.i32x4ExtAddPairwiseI16x8U:
      case Opcodes.i16x8AllTrue:
      case Opcodes.i16x8Bitmask:
      case Opcodes.i16x8ExtendHighI8x16S:
      case Opcodes.i16x8ExtendLowI8x16S:
      case Opcodes.i16x8ExtendHighI8x16U:
      case Opcodes.i16x8ExtendLowI8x16U:
      case Opcodes.i16x8Shl:
      case Opcodes.i16x8ShrS:
      case Opcodes.i16x8ShrU:
      case Opcodes.i16x8Add:
      case Opcodes.i16x8AddSatS:
      case Opcodes.i16x8AddSatU:
      case Opcodes.i16x8Sub:
      case Opcodes.i16x8SubSatS:
      case Opcodes.i16x8SubSatU:
      case Opcodes.i16x8Q15MulrSatS:
      case Opcodes.i16x8Mul:
      case Opcodes.i16x8MinS:
      case Opcodes.i16x8MinU:
      case Opcodes.i16x8MaxS:
      case Opcodes.i16x8MaxU:
      case Opcodes.i16x8AvgrU:
      case Opcodes.i16x8ExtmulLowI8x16S:
      case Opcodes.i16x8ExtmulHighI8x16S:
      case Opcodes.i16x8ExtmulLowI8x16U:
      case Opcodes.i16x8ExtmulHighI8x16U:
      case Opcodes.i32x4AllTrue:
      case Opcodes.i32x4Bitmask:
      case Opcodes.i32x4ExtendLowI16x8S:
      case Opcodes.i32x4ExtendHighI16x8S:
      case Opcodes.i32x4ExtendLowI16x8U:
      case Opcodes.i32x4ExtendHighI16x8U:
      case Opcodes.i32x4Shl:
      case Opcodes.i32x4ShrS:
      case Opcodes.i32x4ShrU:
      case Opcodes.i32x4Add:
      case Opcodes.i32x4Sub:
      case Opcodes.i32x4Mul:
      case Opcodes.i32x4MinS:
      case Opcodes.i32x4MinU:
      case Opcodes.i32x4MaxS:
      case Opcodes.i32x4MaxU:
      case Opcodes.i32x4DotI16x8S:
      case Opcodes.i32x4ExtmulLowI16x8S:
      case Opcodes.i32x4ExtmulHighI16x8S:
      case Opcodes.i32x4ExtmulLowI16x8U:
      case Opcodes.i32x4ExtmulHighI16x8U:
      case Opcodes.i64x2AllTrue:
      case Opcodes.i64x2Bitmask:
      case Opcodes.i64x2Shl:
      case Opcodes.i64x2ShrS:
      case Opcodes.i64x2ShrU:
      case Opcodes.i64x2Add:
      case Opcodes.i64x2Sub:
      case Opcodes.i64x2Mul:
      case Opcodes.i64x2ExtmulLowI32x4S:
      case Opcodes.i64x2ExtmulHighI32x4S:
      case Opcodes.i64x2ExtmulLowI32x4U:
      case Opcodes.i64x2ExtmulHighI32x4U:
      case Opcodes.i64x2ExtendLowI32x4S:
      case Opcodes.i64x2ExtendHighI32x4S:
      case Opcodes.i64x2ExtendLowI32x4U:
      case Opcodes.i64x2ExtendHighI32x4U:
      case Opcodes.f32x4Ceil:
      case Opcodes.f32x4Floor:
      case Opcodes.f32x4Trunc:
      case Opcodes.f32x4Nearest:
      case Opcodes.f32x4Abs:
      case Opcodes.f32x4Neg:
      case Opcodes.f32x4Sqrt:
      case Opcodes.f32x4Add:
      case Opcodes.f32x4Sub:
      case Opcodes.f32x4Mul:
      case Opcodes.f32x4Div:
      case Opcodes.f32x4Min:
      case Opcodes.f32x4Max:
      case Opcodes.f32x4Pmin:
      case Opcodes.f32x4Pmax:
      case Opcodes.f64x2Ceil:
      case Opcodes.f64x2Floor:
      case Opcodes.f64x2Trunc:
      case Opcodes.f64x2Nearest:
      case Opcodes.f64x2Abs:
      case Opcodes.f64x2Neg:
      case Opcodes.f64x2Sqrt:
      case Opcodes.f64x2Add:
      case Opcodes.f64x2Sub:
      case Opcodes.f64x2Mul:
      case Opcodes.f64x2Div:
      case Opcodes.f64x2Min:
      case Opcodes.f64x2Max:
      case Opcodes.f64x2Pmin:
      case Opcodes.f64x2Pmax:
      case Opcodes.i32x4TruncSatF32x4S:
      case Opcodes.i32x4TruncSatF32x4U:
      case Opcodes.f32x4ConvertI32x4S:
      case Opcodes.f32x4ConvertI32x4U:
      case Opcodes.i32x4TruncSatF64x2SZero:
      case Opcodes.i32x4TruncSatF64x2UZero:
      case Opcodes.f64x2ConvertLowI32x4S:
      case Opcodes.f64x2ConvertLowI32x4U:
      case Opcodes.i8x16RelaxedSwizzle:
      case Opcodes.i32x4RelaxedTruncF32x4S:
      case Opcodes.i32x4RelaxedTruncF32x4U:
      case Opcodes.i32x4RelaxedTruncF64x2SZero:
      case Opcodes.i32x4RelaxedTruncF64x2UZero:
      case Opcodes.f32x4RelaxedMadd:
      case Opcodes.f32x4RelaxedNmadd:
      case Opcodes.f64x2RelaxedMadd:
      case Opcodes.f64x2RelaxedNmadd:
      case Opcodes.i8x16RelaxedLaneselect:
      case Opcodes.i16x8RelaxedLaneselect:
      case Opcodes.i32x4RelaxedLaneselect:
      case Opcodes.i64x2RelaxedLaneselect:
      case Opcodes.f32x4RelaxedMin:
      case Opcodes.f32x4RelaxedMax:
      case Opcodes.f64x2RelaxedMin:
      case Opcodes.f64x2RelaxedMax:
      case Opcodes.i16x8RelaxedQ15mulrS:
      case Opcodes.i16x8RelaxedDotI8x16I7x16S:
      case Opcodes.i32x4RelaxedDotI8x16I7x16AddS:
        instructions.add(Instruction(opcode: pseudoOpcode));
      case Opcodes.v128Load8Lane:
        instructions.add(
          Instruction(
            opcode: pseudoOpcode,
            memArg: _readSimdMemArg(
              reader,
              memory64ByIndex,
              maxAlign: 0,
              opcode: pseudoOpcode,
            ),
            immediate: _readSimdLaneImmediate(
              reader,
              laneCount: 16,
              opcode: pseudoOpcode,
            ),
          ),
        );
      case Opcodes.v128Load16Lane:
      case Opcodes.v128Store16Lane:
        instructions.add(
          Instruction(
            opcode: pseudoOpcode,
            memArg: _readSimdMemArg(
              reader,
              memory64ByIndex,
              maxAlign: 1,
              opcode: pseudoOpcode,
            ),
            immediate: _readSimdLaneImmediate(
              reader,
              laneCount: 8,
              opcode: pseudoOpcode,
            ),
          ),
        );
      case Opcodes.v128Load32Lane:
      case Opcodes.v128Store32Lane:
        instructions.add(
          Instruction(
            opcode: pseudoOpcode,
            memArg: _readSimdMemArg(
              reader,
              memory64ByIndex,
              maxAlign: 2,
              opcode: pseudoOpcode,
            ),
            immediate: _readSimdLaneImmediate(
              reader,
              laneCount: 4,
              opcode: pseudoOpcode,
            ),
          ),
        );
      case Opcodes.v128Load64Lane:
      case Opcodes.v128Store64Lane:
        instructions.add(
          Instruction(
            opcode: pseudoOpcode,
            memArg: _readSimdMemArg(
              reader,
              memory64ByIndex,
              maxAlign: 3,
              opcode: pseudoOpcode,
            ),
            immediate: _readSimdLaneImmediate(
              reader,
              laneCount: 2,
              opcode: pseudoOpcode,
            ),
          ),
        );
      case Opcodes.v128Store8Lane:
        instructions.add(
          Instruction(
            opcode: pseudoOpcode,
            memArg: _readSimdMemArg(
              reader,
              memory64ByIndex,
              maxAlign: 0,
              opcode: pseudoOpcode,
            ),
            immediate: _readSimdLaneImmediate(
              reader,
              laneCount: 16,
              opcode: pseudoOpcode,
            ),
          ),
        );
      case Opcodes.i8x16ExtractLaneS:
      case Opcodes.i8x16ExtractLaneU:
      case Opcodes.i8x16ReplaceLane:
        instructions.add(
          Instruction(
            opcode: pseudoOpcode,
            immediate: _readSimdLaneImmediate(
              reader,
              laneCount: 16,
              opcode: pseudoOpcode,
            ),
          ),
        );
      case Opcodes.i16x8ExtractLaneS:
      case Opcodes.i16x8ExtractLaneU:
      case Opcodes.i16x8ReplaceLane:
        instructions.add(
          Instruction(
            opcode: pseudoOpcode,
            immediate: _readSimdLaneImmediate(
              reader,
              laneCount: 8,
              opcode: pseudoOpcode,
            ),
          ),
        );
      case Opcodes.i32x4ExtractLane:
      case Opcodes.f32x4ExtractLane:
      case Opcodes.i32x4ReplaceLane:
      case Opcodes.f32x4ReplaceLane:
        instructions.add(
          Instruction(
            opcode: pseudoOpcode,
            immediate: _readSimdLaneImmediate(
              reader,
              laneCount: 4,
              opcode: pseudoOpcode,
            ),
          ),
        );
      case Opcodes.i64x2ExtractLane:
      case Opcodes.f64x2ExtractLane:
      case Opcodes.i64x2ReplaceLane:
      case Opcodes.f64x2ReplaceLane:
        instructions.add(
          Instruction(
            opcode: pseudoOpcode,
            immediate: _readSimdLaneImmediate(
              reader,
              laneCount: 2,
              opcode: pseudoOpcode,
            ),
          ),
        );
      default:
        throw UnsupportedError(
          'Unsupported 0xFD sub-opcode: 0x${subOpcode.toRadixString(16)}',
        );
    }
  }

  static MemArg _readSimdMemArg(
    ByteReader reader,
    List<bool> memory64ByIndex, {
    required int maxAlign,
    required int opcode,
  }) {
    final memArg = _readMemArg(reader, memory64ByIndex);
    if (memArg.align > maxAlign) {
      throw FormatException(
        'Invalid SIMD memarg alignment ${memArg.align} for opcode '
        '0x${opcode.toRadixString(16)}.',
      );
    }
    return memArg;
  }

  static int _readSimdLaneImmediate(
    ByteReader reader, {
    required int laneCount,
    required int opcode,
  }) {
    final lane = reader.readByte();
    if (lane < 0 || lane >= laneCount) {
      throw FormatException(
        'Invalid SIMD lane index $lane for opcode 0x${opcode.toRadixString(16)}.',
      );
    }
    return lane;
  }

  static TryTableCatchClause _readTryTableCatchClause(ByteReader reader) {
    final kind = reader.readByte();
    switch (kind) {
      case TryTableCatchKind.catchTag:
      case TryTableCatchKind.catchRef:
        final tagIndex = reader.readVarUint32();
        final labelDepth = reader.readVarUint32();
        return TryTableCatchClause(
          kind: kind,
          tagIndex: tagIndex,
          labelDepth: labelDepth,
        );
      case TryTableCatchKind.catchAll:
      case TryTableCatchKind.catchAllRef:
        return TryTableCatchClause(
          kind: kind,
          labelDepth: reader.readVarUint32(),
        );
      default:
        throw FormatException(
          'Invalid try_table catch kind: 0x${kind.toRadixString(16)}',
        );
    }
  }

  static GcRefTypeImmediate _readGcRefType(ByteReader reader) {
    final lead = reader.readByte();
    switch (lead) {
      case 0x63:
      case 0x64:
        final nullable = lead == 0x63;
        final heapType = _readHeapType(reader);
        return GcRefTypeImmediate(
          nullable: nullable,
          exact: heapType.$2,
          heapType: heapType.$1,
        );
      case 0x62:
      case 0x61:
        final nested = reader.readByte();
        return GcRefTypeImmediate(
          nullable: false,
          exact: lead == 0x62,
          heapType: _readSignedLeb33WithFirst(reader, nested),
        );
      default:
        final heapType = _readSignedLeb33WithFirst(reader, lead);
        return GcRefTypeImmediate(
          nullable: true,
          exact: false,
          heapType: heapType,
        );
    }
  }

  static (int, bool) _readHeapType(ByteReader reader) {
    final lead = reader.readByte();
    switch (lead) {
      case 0x62:
      case 0x61:
        final nested = reader.readByte();
        return (_readSignedLeb33WithFirst(reader, nested), lead == 0x62);
      default:
        return (_readSignedLeb33WithFirst(reader, lead), false);
    }
  }

  static MemArg _readMemArg(ByteReader reader, List<bool> memory64ByIndex) {
    final encodedAlign = reader.readVarUint32();
    if ((encodedAlign & ~0x7f) != 0) {
      throw const FormatException('Malformed memop flags.');
    }
    // Multi-memory encodes a memory-index-present flag in bit 6.
    final align = encodedAlign & 0x3f;
    final hasMemoryIndex = (encodedAlign & 0x40) != 0;
    final memoryIndex = hasMemoryIndex ? reader.readVarUint32() : 0;
    final isMemory64 =
        memoryIndex >= 0 &&
        memoryIndex < memory64ByIndex.length &&
        memory64ByIndex[memoryIndex];
    return MemArg(
      align: align,
      offset: isMemory64 ? reader.readVarUint64() : reader.readVarUint32(),
      memoryIndex: memoryIndex,
    );
  }

  static ({
    List<WasmValueType> paramTypes,
    List<String> paramSignatures,
    List<WasmValueType> resultTypes,
    List<String> resultSignatures,
  })
  _readBlockTypeInfo(ByteReader reader, List<WasmFunctionType> moduleTypes) {
    final first = reader.readByte();

    if (first == 0x40) {
      return (
        paramTypes: const <WasmValueType>[],
        paramSignatures: const <String>[],
        resultTypes: const <WasmValueType>[],
        resultSignatures: const <String>[],
      );
    }

    if (_isInlineBlockValueType(first)) {
      final inlineType = _readInlineBlockValueTypeWithSignature(reader, first);
      return (
        paramTypes: const <WasmValueType>[],
        paramSignatures: const <String>[],
        resultTypes: <WasmValueType>[inlineType.type],
        resultSignatures: <String>[inlineType.signature],
      );
    }

    final typeIndex = _readSignedLeb33WithFirst(reader, first);
    if (typeIndex < 0 || typeIndex >= moduleTypes.length) {
      throw FormatException('Invalid block type index: $typeIndex');
    }
    if (!moduleTypes[typeIndex].isFunctionType) {
      throw FormatException(
        'Block type index is not a function type: $typeIndex',
      );
    }

    final functionType = moduleTypes[typeIndex];
    final resultSignatures = functionType.resultTypeSignatures.isNotEmpty
        ? List<String>.from(functionType.resultTypeSignatures)
        : functionType.results
              .map(_signatureForValueType)
              .toList(growable: false);
    final paramSignatures = functionType.paramTypeSignatures.isNotEmpty
        ? List<String>.from(functionType.paramTypeSignatures)
        : functionType.params
              .map(_signatureForValueType)
              .toList(growable: false);

    return (
      paramTypes: List<WasmValueType>.from(functionType.params),
      paramSignatures: paramSignatures,
      resultTypes: List<WasmValueType>.from(functionType.results),
      resultSignatures: resultSignatures,
    );
  }

  static void _readSelectValueType(
    ByteReader reader,
    List<WasmFunctionType> moduleTypes,
  ) {
    final typeByte = reader.readByte();
    if (typeByte == 0x63 || typeByte == 0x64) {
      final heapType = _readHeapTypeWithBytes(reader).value;
      if (heapType >= moduleTypes.length) {
        throw FormatException('Invalid select type index: $heapType');
      }
      return;
    }
    if (_isInlineBlockValueType(typeByte)) {
      _readInlineBlockValueTypeWithSignature(reader, typeByte);
      return;
    }
    throw UnsupportedError(
      'Unsupported select type: 0x${typeByte.toRadixString(16)}',
    );
  }

  static bool _isInlineBlockValueType(int value) {
    switch (value) {
      case 0x7f:
      case 0x7e:
      case 0x7d:
      case 0x7c:
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
      case 0x64:
      case 0x63:
      case 0x62:
      case 0x61:
      case 0x60:
        return true;
      default:
        return false;
    }
  }

  static ({WasmValueType type, String signature})
  _readInlineBlockValueTypeWithSignature(ByteReader reader, int first) {
    switch (first) {
      case 0x7f:
        return (type: WasmValueType.i32, signature: '7f');
      case 0x7e:
        return (type: WasmValueType.i64, signature: '7e');
      case 0x7d:
        return (type: WasmValueType.f32, signature: '7d');
      case 0x7c:
        return (type: WasmValueType.f64, signature: '7c');
      case 0x63:
      case 0x64:
        final heap = _readHeapTypeWithBytes(reader);
        return (
          type: WasmValueType.i32,
          signature: _bytesToSignature(<int>[first, ...heap.bytes]),
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
        return (
          type: WasmValueType.i32,
          signature: _bytesToSignature(<int>[first]),
        );
      default:
        throw UnsupportedError(
          'Unsupported inline block type: 0x${first.toRadixString(16)}',
        );
    }
  }

  static ({int value, bool exact, List<int> bytes}) _readHeapTypeWithBytes(
    ByteReader reader,
  ) {
    final lead = reader.readByte();
    if (lead == 0x62 || lead == 0x61) {
      final nested = reader.readByte();
      final decoded = _readSignedLeb33WithFirstAndBytes(reader, nested);
      return (
        value: decoded.value,
        exact: lead == 0x62,
        bytes: <int>[lead, ...decoded.bytes],
      );
    }
    final decoded = _readSignedLeb33WithFirstAndBytes(reader, lead);
    return (value: decoded.value, exact: false, bytes: decoded.bytes);
  }

  static ({int value, List<int> bytes}) _readSignedLeb33WithFirstAndBytes(
    ByteReader reader,
    int firstByte,
  ) {
    final bytes = <int>[firstByte];
    var result = firstByte & 0x7f;
    var shift = 7;
    var byte = firstByte;
    var multiplier = 128;

    while ((byte & 0x80) != 0) {
      byte = reader.readByte();
      bytes.add(byte);
      result += (byte & 0x7f) * multiplier;
      multiplier *= 128;
      shift += 7;
      if (shift > 35) {
        throw const FormatException('Invalid blocktype LEB encoding.');
      }
    }

    if (shift < 33 && (byte & 0x40) != 0) {
      result -= multiplier;
    }
    return (value: _normalizeSignedLeb33(result), bytes: bytes);
  }

  static String _signatureForValueType(WasmValueType type) {
    return switch (type) {
      WasmValueType.i32 => '7f',
      WasmValueType.i64 => '7e',
      WasmValueType.f32 => '7d',
      WasmValueType.f64 => '7c',
    };
  }

  static String _bytesToSignature(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write((byte & 0xff).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
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
        throw const FormatException('Invalid blocktype LEB encoding.');
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
      0x0a || // throw_ref
      0x18 || // delegate
      0x19 || // catch_all
      0x1f => true, // try_table
      _ => false,
    };
  }
}
