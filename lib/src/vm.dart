import 'dart:typed_data';
import 'dart:math' as math;

import 'int64.dart';
import 'memory.dart';
import 'module.dart';
import 'opcode.dart';
import 'predecode.dart';
import 'runtime_function.dart';
import 'runtime_global.dart';
import 'table.dart';
import 'value.dart';

enum _LabelKind { block, loop, if_ }

final class _LabelFrame {
  _LabelFrame({
    required this.kind,
    required this.stackHeight,
    required this.branchTypes,
    required this.endTypes,
    required this.endIndex,
    required this.loopStartIndex,
  });

  final _LabelKind kind;
  final int stackHeight;
  final List<WasmValueType> branchTypes;
  final List<WasmValueType> endTypes;
  final int endIndex;
  final int loopStartIndex;
}

enum _GcRefKind { i31, struct, array, extern }

final class _GcRefObject {
  _GcRefObject.i31(this.i31Value)
    : kind = _GcRefKind.i31,
      typeIndex = null,
      descriptorRef = null,
      fields = null,
      elements = null,
      externValue = null;

  _GcRefObject.struct({
    required this.typeIndex,
    this.descriptorRef,
    required List<WasmValue> fields,
  }) : kind = _GcRefKind.struct,
       i31Value = null,
       fields = List<WasmValue>.unmodifiable(fields),
       elements = null,
       externValue = null;

  _GcRefObject.array({
    required this.typeIndex,
    required List<WasmValue> elements,
  }) : kind = _GcRefKind.array,
       i31Value = null,
       descriptorRef = null,
       fields = null,
       elements = List<WasmValue>.from(elements),
       externValue = null;

  _GcRefObject.extern(this.externValue)
    : kind = _GcRefKind.extern,
      i31Value = null,
      typeIndex = null,
      descriptorRef = null,
      fields = null,
      elements = null;

  final _GcRefKind kind;
  final int? i31Value;
  final int? typeIndex;
  final int? descriptorRef;
  final List<WasmValue>? fields;
  final List<WasmValue>? elements;
  final int? externValue;
}

final class WasmVm {
  WasmVm({
    required List<RuntimeFunction> functions,
    required List<WasmFunctionType> types,
    required List<WasmTable> tables,
    required List<WasmMemory> memories,
    required List<RuntimeGlobal> globals,
    required List<bool> memory64ByIndex,
    required List<Uint8List?> dataSegments,
    required List<List<int?>?> elementSegments,
    required List<int> elementSegmentRefTypeCodes,
    this.maxCallDepth = 1024,
  }) : _functions = functions,
       _types = types,
       _tables = tables,
       _memories = memories,
       _globals = globals,
       _memory64ByIndex = memory64ByIndex,
       _dataSegments = dataSegments,
       _elementSegments = elementSegments,
       _elementSegmentRefTypeCodes = elementSegmentRefTypeCodes {
    if (_memory64ByIndex.length != _memories.length) {
      throw ArgumentError(
        'memory64ByIndex length ${_memory64ByIndex.length} does not match '
        'memory count ${_memories.length}.',
      );
    }
    if (_elementSegmentRefTypeCodes.length != _elementSegments.length) {
      throw ArgumentError(
        'elementSegmentRefTypeCodes length ${_elementSegmentRefTypeCodes.length} '
        'does not match element segment count ${_elementSegments.length}.',
      );
    }
  }

  final List<RuntimeFunction> _functions;
  final List<WasmFunctionType> _types;
  final List<WasmTable> _tables;
  final List<WasmMemory> _memories;
  final List<RuntimeGlobal> _globals;
  final List<bool> _memory64ByIndex;
  final List<Uint8List?> _dataSegments;
  final List<List<int?>?> _elementSegments;
  final List<int> _elementSegmentRefTypeCodes;
  final int maxCallDepth;

  static const int _nullRef = -1;
  static const int _heapAny = -18;
  static const int _heapEq = -19;
  static const int _heapI31 = -20;
  static const int _heapStruct = -21;
  static const int _heapArray = -22;
  static const int _heapFunc = -16;
  static const int _heapExtern = -17;
  static const int _heapNone = -15;
  static const int _heapNofunc = -13;
  static const int _heapNoextern = -14;
  static const int constGcRefKindStruct = 1;
  static const int constGcRefKindArray = 2;
  static const int constGcRefKindI31 = 3;
  static const int _constGcRefBase = -0x40000000;
  static int _nextConstGcRefId = 0;
  static final Map<int, ({int kind, int typeIndex, int? descriptorRef})>
  _constGcRefs =
      <int, ({int kind, int typeIndex, int? descriptorRef})>{};
  static int _nextGcObjectId = 0;
  static final Map<int, _GcRefObject> _sharedGcObjects = <int, _GcRefObject>{};

  static int encodeConstGcRef({
    required int kind,
    required int typeIndex,
    int? descriptorRef,
  }) {
    if (kind <= 0 || kind > 0x3ff) {
      throw RangeError.range(kind, 1, 0x3ff, 'kind');
    }
    if (typeIndex < 0) {
      throw RangeError.value(typeIndex, 'typeIndex', 'must be >= 0');
    }
    final id = _nextConstGcRefId++;
    final reference = _constGcRefBase - id;
    _constGcRefs[reference] = (
      kind: kind,
      typeIndex: typeIndex,
      descriptorRef: descriptorRef,
    );
    return reference;
  }

  static ({int kind, int typeIndex, int? descriptorRef})? decodeConstGcRef(
    int reference,
  ) {
    return _constGcRefs[reference];
  }

  static int allocateConstStructRef({
    required int typeIndex,
    int? descriptorRef,
    required List<WasmValue> fields,
  }) {
    return _allocateSharedGcObject(
      _GcRefObject.struct(
        typeIndex: typeIndex,
        descriptorRef: descriptorRef,
        fields: fields,
      ),
    );
  }

  static int allocateConstArrayRef({
    required int typeIndex,
    required List<WasmValue> elements,
  }) {
    return _allocateSharedGcObject(
      _GcRefObject.array(typeIndex: typeIndex, elements: elements),
    );
  }

  static int allocateConstI31Ref(int value) {
    return _allocateSharedGcObject(_GcRefObject.i31(value & 0x7fffffff));
  }

  List<WasmValue> invokeFunction(int functionIndex, List<WasmValue> args) {
    return _execute(functionIndex, args, depth: 0);
  }

  List<WasmValue> _execute(
    int functionIndex,
    List<WasmValue> args, {
    required int depth,
  }) {
    if (depth > maxCallDepth) {
      throw StateError('Call stack overflow (depth > $maxCallDepth).');
    }

    _checkFunctionIndex(functionIndex);
    final function = _functions[functionIndex];

    if (args.length != function.type.params.length) {
      throw ArgumentError(
        'Function index $functionIndex expects ${function.type.params.length} '
        'args, got ${args.length}.',
      );
    }

    final normalizedArgs = _normalizeValues(args, function.type.params);

    if (function is HostRuntimeFunction) {
      final externalArgs = normalizedArgs
          .map((value) => value.toExternal())
          .toList(growable: false);
      final hostResult = function.callback(externalArgs);
      return WasmValue.decodeResults(function.type.results, hostResult);
    }

    final defined = function as DefinedRuntimeFunction;
    final locals = <WasmValue>[];
    locals.addAll(normalizedArgs);
    for (final localType in defined.localTypes) {
      locals.add(WasmValue.zeroForType(localType));
    }

    final stack = <WasmValue>[];
    final labels = <_LabelFrame>[];
    final instructions = defined.instructions;
    if (instructions.isEmpty) {
      throw StateError('Function body has no instructions.');
    }
    labels.add(
      _LabelFrame(
        kind: _LabelKind.block,
        stackHeight: 0,
        branchTypes: function.type.results,
        endTypes: function.type.results,
        endIndex: instructions.length - 1,
        loopStartIndex: -1,
      ),
    );
    var pc = 0;

    while (pc < instructions.length) {
      final instruction = instructions[pc];

      switch (instruction.opcode) {
        case Opcodes.unreachable:
          throw StateError('unreachable trap');

        case Opcodes.nop:
          pc++;

        case Opcodes.block:
          labels.add(
            _LabelFrame(
              kind: _LabelKind.block,
              stackHeight: stack.length,
              branchTypes: instruction.blockResultTypes ?? const [],
              endTypes: instruction.blockResultTypes ?? const [],
              endIndex: _requireJumpIndex(instruction.endIndex, 'block'),
              loopStartIndex: -1,
            ),
          );
          pc++;

        case Opcodes.loop:
          labels.add(
            _LabelFrame(
              kind: _LabelKind.loop,
              stackHeight: stack.length,
              // In core MVP and current decoder support, loops have no
              // parameter types, so `br` to loop carries zero values.
              branchTypes: const [],
              endTypes: instruction.blockResultTypes ?? const [],
              endIndex: _requireJumpIndex(instruction.endIndex, 'loop'),
              loopStartIndex: pc + 1,
            ),
          );
          pc++;

        case Opcodes.if_:
          final condition = _popI32(stack);
          final label = _LabelFrame(
            kind: _LabelKind.if_,
            stackHeight: stack.length,
            branchTypes: instruction.blockResultTypes ?? const [],
            endTypes: instruction.blockResultTypes ?? const [],
            endIndex: _requireJumpIndex(instruction.endIndex, 'if'),
            loopStartIndex: -1,
          );
          labels.add(label);

          if (condition != 0) {
            pc++;
          } else if (instruction.elseIndex != null) {
            pc = instruction.elseIndex! + 1;
          } else {
            labels.removeLast();
            _exitLabel(label, stack);
            pc = label.endIndex + 1;
          }

        case Opcodes.else_:
          if (labels.isEmpty || labels.last.kind != _LabelKind.if_) {
            throw StateError('`else` reached without matching `if`.');
          }
          final label = labels.removeLast();
          _exitLabel(label, stack);
          pc = _requireJumpIndex(instruction.endIndex, 'else') + 1;

        case Opcodes.end:
          if (labels.isNotEmpty && labels.last.endIndex == pc) {
            final label = labels.removeLast();
            _exitLabel(label, stack);
            if (labels.isEmpty) {
              return _collectResults(function.type.results, stack);
            }
            pc++;
            continue;
          }

          return _collectResults(function.type.results, stack);

        case Opcodes.br:
          pc = _branch(instruction.immediate!, labels, stack);

        case Opcodes.brIf:
          final condition = _popI32(stack);
          if (condition != 0) {
            pc = _branch(instruction.immediate!, labels, stack);
          } else {
            pc++;
          }

        case Opcodes.brOnNull:
          final value = _popRef(stack);
          if (value == null) {
            pc = _branch(instruction.immediate!, labels, stack);
          } else {
            _pushRef(stack, value);
            pc++;
          }

        case Opcodes.brOnNonNull:
          final value = _popRef(stack);
          if (value != null) {
            _pushRef(stack, value);
            pc = _branch(instruction.immediate!, labels, stack);
          } else {
            _pushRef(stack, null);
            pc++;
          }

        case Opcodes.brTable:
          final selector = _popI32(stack);
          final targets = instruction.tableDepths;
          if (targets == null || targets.isEmpty) {
            throw StateError('Invalid br_table targets.');
          }

          final defaultDepth = targets.last;
          final branchDepth = selector >= 0 && selector < targets.length - 1
              ? targets[selector]
              : defaultDepth;

          pc = _branch(branchDepth, labels, stack);

        case Opcodes.return_:
          return _collectResults(function.type.results, stack);

        case Opcodes.call:
          final targetIndex = instruction.immediate!;
          _checkFunctionIndex(targetIndex);
          final target = _functions[targetIndex];
          final callArgs = _popArgs(stack, target.type.params);
          final callResults = _execute(targetIndex, callArgs, depth: depth + 1);
          stack.addAll(callResults);
          pc++;

        case Opcodes.returnCall:
          final targetIndex = instruction.immediate!;
          _checkFunctionIndex(targetIndex);
          final target = _functions[targetIndex];
          final callArgs = _popArgs(stack, target.type.params);
          return _execute(targetIndex, callArgs, depth: depth + 1);

        case Opcodes.callIndirect:
          final typeIndex = _checkTypeIndex(instruction.immediate!);
          final tableIndex = _checkTableIndex(instruction.secondaryImmediate!);
          final tableElementIndex = _popI32(stack);
          final targetFunctionIndex = _tables[tableIndex][tableElementIndex];
          if (targetFunctionIndex == null) {
            throw StateError('call_indirect to null table element.');
          }

          _checkFunctionIndex(targetFunctionIndex);
          final target = _functions[targetFunctionIndex];
          final expectedType = _types[typeIndex];
          if (!expectedType.isFunctionType) {
            throw StateError(
              'call_indirect expected non-function type $typeIndex.',
            );
          }

          if (!_functionTypeEquals(target.type, expectedType)) {
            throw StateError('call_indirect signature mismatch trap');
          }

          final callArgs = _popArgs(stack, expectedType.params);
          final callResults = _execute(
            targetFunctionIndex,
            callArgs,
            depth: depth + 1,
          );
          stack.addAll(callResults);
          pc++;

        case Opcodes.returnCallIndirect:
          final typeIndex = _checkTypeIndex(instruction.immediate!);
          final tableIndex = _checkTableIndex(instruction.secondaryImmediate!);
          final tableElementIndex = _popI32(stack);
          final targetFunctionIndex = _tables[tableIndex][tableElementIndex];
          if (targetFunctionIndex == null) {
            throw StateError('call_indirect to null table element.');
          }

          _checkFunctionIndex(targetFunctionIndex);
          final target = _functions[targetFunctionIndex];
          final expectedType = _types[typeIndex];
          if (!expectedType.isFunctionType) {
            throw StateError(
              'call_indirect expected non-function type $typeIndex.',
            );
          }

          if (!_functionTypeEquals(target.type, expectedType)) {
            throw StateError('call_indirect signature mismatch trap');
          }

          final callArgs = _popArgs(stack, expectedType.params);
          return _execute(targetFunctionIndex, callArgs, depth: depth + 1);

        case Opcodes.drop:
          _pop(stack);
          pc++;

        case Opcodes.select:
        case Opcodes.selectT:
          final condition = _popI32(stack);
          final falseValue = _pop(stack);
          final trueValue = _pop(stack);
          if (falseValue.type != trueValue.type) {
            throw StateError('select operands must have the same value type.');
          }
          stack.add(condition != 0 ? trueValue : falseValue);
          pc++;

        case Opcodes.localGet:
          final localIndex = _checkIndex(
            instruction.immediate!,
            locals.length,
            'local',
          );
          stack.add(locals[localIndex]);
          pc++;

        case Opcodes.localSet:
          final localIndex = _checkIndex(
            instruction.immediate!,
            locals.length,
            'local',
          );
          locals[localIndex] = _pop(stack).castTo(locals[localIndex].type);
          pc++;

        case Opcodes.localTee:
          final localIndex = _checkIndex(
            instruction.immediate!,
            locals.length,
            'local',
          );
          final value = _pop(stack).castTo(locals[localIndex].type);
          locals[localIndex] = value;
          stack.add(value);
          pc++;

        case Opcodes.globalGet:
          final globalIndex = _checkIndex(
            instruction.immediate!,
            _globals.length,
            'global',
          );
          stack.add(_globals[globalIndex].value);
          pc++;

        case Opcodes.globalSet:
          final globalIndex = _checkIndex(
            instruction.immediate!,
            _globals.length,
            'global',
          );
          final global = _globals[globalIndex];
          if (!global.mutable) {
            throw StateError('Cannot mutate immutable global $globalIndex.');
          }
          global.setValue(_pop(stack));
          pc++;

        case Opcodes.tableGet:
          final tableIndex = _checkTableIndex(instruction.immediate!);
          final elementIndex = _popI32(stack);
          _pushRef(stack, _tables[tableIndex][elementIndex]);
          pc++;

        case Opcodes.tableSet:
          final tableIndex = _checkTableIndex(instruction.immediate!);
          final value = _popRef(stack);
          final elementIndex = _popI32(stack);
          _tables[tableIndex][elementIndex] = value;
          pc++;

        case Opcodes.i32Load:
          stack.add(WasmValue.i32(_loadI32(stack, instruction)));
          pc++;

        case Opcodes.i64Load:
          stack.add(WasmValue.i64(_loadI64(stack, instruction)));
          pc++;

        case Opcodes.f32Load:
          stack.add(WasmValue.f32(_loadF32(stack, instruction)));
          pc++;

        case Opcodes.f64Load:
          stack.add(WasmValue.f64(_loadF64(stack, instruction)));
          pc++;

        case Opcodes.i32Load8S:
          stack.add(WasmValue.i32(_loadI8(stack, instruction)));
          pc++;

        case Opcodes.i32Load8U:
          stack.add(WasmValue.i32(_loadU8(stack, instruction)));
          pc++;

        case Opcodes.i32Load16S:
          stack.add(WasmValue.i32(_loadI16(stack, instruction)));
          pc++;

        case Opcodes.i32Load16U:
          stack.add(WasmValue.i32(_loadU16(stack, instruction)));
          pc++;

        case Opcodes.i64Load8S:
          stack.add(WasmValue.i64(_loadI8(stack, instruction)));
          pc++;

        case Opcodes.i64Load8U:
          stack.add(WasmValue.i64(_loadU8(stack, instruction)));
          pc++;

        case Opcodes.i64Load16S:
          stack.add(WasmValue.i64(_loadI16(stack, instruction)));
          pc++;

        case Opcodes.i64Load16U:
          stack.add(WasmValue.i64(_loadU16(stack, instruction)));
          pc++;

        case Opcodes.i64Load32S:
          stack.add(WasmValue.i64(_loadI32(stack, instruction)));
          pc++;

        case Opcodes.i64Load32U:
          stack.add(WasmValue.i64(_loadU32(stack, instruction)));
          pc++;

        case Opcodes.i32Store:
          _storeI32(stack, instruction, _popI32(stack));
          pc++;

        case Opcodes.i64Store:
          _storeI64(stack, instruction, _popI64(stack));
          pc++;

        case Opcodes.f32Store:
          _storeF32(stack, instruction, _popF32(stack));
          pc++;

        case Opcodes.f64Store:
          _storeF64(stack, instruction, _popF64(stack));
          pc++;

        case Opcodes.i32Store8:
          _storeI8(stack, instruction, _popI32(stack));
          pc++;

        case Opcodes.i32Store16:
          _storeI16(stack, instruction, _popI32(stack));
          pc++;

        case Opcodes.i64Store8:
          _storeI8(stack, instruction, WasmI64.lowU32(_popI64(stack)));
          pc++;

        case Opcodes.i64Store16:
          _storeI16(stack, instruction, WasmI64.lowU32(_popI64(stack)));
          pc++;

        case Opcodes.i64Store32:
          _storeI32(stack, instruction, WasmI64.lowU32(_popI64(stack)));
          pc++;

        case Opcodes.memoryAtomicNotify:
          _memoryAtomicNotify(stack, instruction);
          pc++;

        case Opcodes.memoryAtomicWait32:
          _memoryAtomicWait32(stack, instruction);
          pc++;

        case Opcodes.memoryAtomicWait64:
          _memoryAtomicWait64(stack, instruction);
          pc++;

        case Opcodes.atomicFence:
          pc++;

        case Opcodes.i32AtomicLoad:
          stack.add(WasmValue.i32(_atomicLoadI32(stack, instruction)));
          pc++;

        case Opcodes.i64AtomicLoad:
          stack.add(WasmValue.i64(_atomicLoadI64(stack, instruction)));
          pc++;

        case Opcodes.i32AtomicLoad8U:
          stack.add(WasmValue.i32(_atomicLoadU8(stack, instruction)));
          pc++;

        case Opcodes.i32AtomicLoad16U:
          stack.add(WasmValue.i32(_atomicLoadU16(stack, instruction)));
          pc++;

        case Opcodes.i64AtomicLoad8U:
          stack.add(WasmValue.i64(_atomicLoadU8(stack, instruction)));
          pc++;

        case Opcodes.i64AtomicLoad16U:
          stack.add(WasmValue.i64(_atomicLoadU16(stack, instruction)));
          pc++;

        case Opcodes.i64AtomicLoad32U:
          stack.add(WasmValue.i64(_atomicLoadU32(stack, instruction)));
          pc++;

        case Opcodes.i32AtomicStore:
          _atomicStoreI32(stack, instruction, _popI32(stack));
          pc++;

        case Opcodes.i64AtomicStore:
          _atomicStoreI64(stack, instruction, _popI64(stack));
          pc++;

        case Opcodes.i32AtomicStore8:
          _atomicStoreI8(stack, instruction, _popI32(stack));
          pc++;

        case Opcodes.i32AtomicStore16:
          _atomicStoreI16(stack, instruction, _popI32(stack));
          pc++;

        case Opcodes.i64AtomicStore8:
          _atomicStoreI8(stack, instruction, WasmI64.lowU32(_popI64(stack)));
          pc++;

        case Opcodes.i64AtomicStore16:
          _atomicStoreI16(stack, instruction, WasmI64.lowU32(_popI64(stack)));
          pc++;

        case Opcodes.i64AtomicStore32:
          _atomicStoreI32(stack, instruction, WasmI64.lowU32(_popI64(stack)));
          pc++;

        case Opcodes.i32AtomicRmwAdd:
          stack.add(
            WasmValue.i32(_atomicRmwI32(stack, instruction, (a, b) => a + b)),
          );
          pc++;

        case Opcodes.i64AtomicRmwAdd:
          stack.add(
            WasmValue.i64(_atomicRmwI64(stack, instruction, (a, b) => a + b)),
          );
          pc++;

        case Opcodes.i32AtomicRmw8AddU:
          stack.add(
            WasmValue.i32(
              _atomicRmwI32Narrow(
                stack,
                instruction,
                widthBytes: 1,
                operation: (a, b) => a + b,
              ),
            ),
          );
          pc++;

        case Opcodes.i32AtomicRmw16AddU:
          stack.add(
            WasmValue.i32(
              _atomicRmwI32Narrow(
                stack,
                instruction,
                widthBytes: 2,
                operation: (a, b) => a + b,
              ),
            ),
          );
          pc++;

        case Opcodes.i64AtomicRmw8AddU:
          stack.add(
            WasmValue.i64(
              _atomicRmwI64Narrow(
                stack,
                instruction,
                widthBytes: 1,
                operation: (a, b) => a + b,
              ),
            ),
          );
          pc++;

        case Opcodes.i64AtomicRmw16AddU:
          stack.add(
            WasmValue.i64(
              _atomicRmwI64Narrow(
                stack,
                instruction,
                widthBytes: 2,
                operation: (a, b) => a + b,
              ),
            ),
          );
          pc++;

        case Opcodes.i64AtomicRmw32AddU:
          stack.add(
            WasmValue.i64(
              _atomicRmwI64Narrow(
                stack,
                instruction,
                widthBytes: 4,
                operation: (a, b) => a + b,
              ),
            ),
          );
          pc++;

        case Opcodes.i32AtomicRmwSub:
          stack.add(
            WasmValue.i32(_atomicRmwI32(stack, instruction, (a, b) => a - b)),
          );
          pc++;

        case Opcodes.i64AtomicRmwSub:
          stack.add(
            WasmValue.i64(_atomicRmwI64(stack, instruction, (a, b) => a - b)),
          );
          pc++;

        case Opcodes.i32AtomicRmw8SubU:
          stack.add(
            WasmValue.i32(
              _atomicRmwI32Narrow(
                stack,
                instruction,
                widthBytes: 1,
                operation: (a, b) => a - b,
              ),
            ),
          );
          pc++;

        case Opcodes.i32AtomicRmw16SubU:
          stack.add(
            WasmValue.i32(
              _atomicRmwI32Narrow(
                stack,
                instruction,
                widthBytes: 2,
                operation: (a, b) => a - b,
              ),
            ),
          );
          pc++;

        case Opcodes.i64AtomicRmw8SubU:
          stack.add(
            WasmValue.i64(
              _atomicRmwI64Narrow(
                stack,
                instruction,
                widthBytes: 1,
                operation: (a, b) => a - b,
              ),
            ),
          );
          pc++;

        case Opcodes.i64AtomicRmw16SubU:
          stack.add(
            WasmValue.i64(
              _atomicRmwI64Narrow(
                stack,
                instruction,
                widthBytes: 2,
                operation: (a, b) => a - b,
              ),
            ),
          );
          pc++;

        case Opcodes.i64AtomicRmw32SubU:
          stack.add(
            WasmValue.i64(
              _atomicRmwI64Narrow(
                stack,
                instruction,
                widthBytes: 4,
                operation: (a, b) => a - b,
              ),
            ),
          );
          pc++;

        case Opcodes.i32AtomicRmwAnd:
          stack.add(
            WasmValue.i32(_atomicRmwI32(stack, instruction, (a, b) => a & b)),
          );
          pc++;

        case Opcodes.i64AtomicRmwAnd:
          stack.add(
            WasmValue.i64(_atomicRmwI64(stack, instruction, (a, b) => a & b)),
          );
          pc++;

        case Opcodes.i32AtomicRmw8AndU:
          stack.add(
            WasmValue.i32(
              _atomicRmwI32Narrow(
                stack,
                instruction,
                widthBytes: 1,
                operation: (a, b) => a & b,
              ),
            ),
          );
          pc++;

        case Opcodes.i32AtomicRmw16AndU:
          stack.add(
            WasmValue.i32(
              _atomicRmwI32Narrow(
                stack,
                instruction,
                widthBytes: 2,
                operation: (a, b) => a & b,
              ),
            ),
          );
          pc++;

        case Opcodes.i64AtomicRmw8AndU:
          stack.add(
            WasmValue.i64(
              _atomicRmwI64Narrow(
                stack,
                instruction,
                widthBytes: 1,
                operation: (a, b) => a & b,
              ),
            ),
          );
          pc++;

        case Opcodes.i64AtomicRmw16AndU:
          stack.add(
            WasmValue.i64(
              _atomicRmwI64Narrow(
                stack,
                instruction,
                widthBytes: 2,
                operation: (a, b) => a & b,
              ),
            ),
          );
          pc++;

        case Opcodes.i64AtomicRmw32AndU:
          stack.add(
            WasmValue.i64(
              _atomicRmwI64Narrow(
                stack,
                instruction,
                widthBytes: 4,
                operation: (a, b) => a & b,
              ),
            ),
          );
          pc++;

        case Opcodes.i32AtomicRmwOr:
          stack.add(
            WasmValue.i32(_atomicRmwI32(stack, instruction, (a, b) => a | b)),
          );
          pc++;

        case Opcodes.i64AtomicRmwOr:
          stack.add(
            WasmValue.i64(_atomicRmwI64(stack, instruction, (a, b) => a | b)),
          );
          pc++;

        case Opcodes.i32AtomicRmw8OrU:
          stack.add(
            WasmValue.i32(
              _atomicRmwI32Narrow(
                stack,
                instruction,
                widthBytes: 1,
                operation: (a, b) => a | b,
              ),
            ),
          );
          pc++;

        case Opcodes.i32AtomicRmw16OrU:
          stack.add(
            WasmValue.i32(
              _atomicRmwI32Narrow(
                stack,
                instruction,
                widthBytes: 2,
                operation: (a, b) => a | b,
              ),
            ),
          );
          pc++;

        case Opcodes.i64AtomicRmw8OrU:
          stack.add(
            WasmValue.i64(
              _atomicRmwI64Narrow(
                stack,
                instruction,
                widthBytes: 1,
                operation: (a, b) => a | b,
              ),
            ),
          );
          pc++;

        case Opcodes.i64AtomicRmw16OrU:
          stack.add(
            WasmValue.i64(
              _atomicRmwI64Narrow(
                stack,
                instruction,
                widthBytes: 2,
                operation: (a, b) => a | b,
              ),
            ),
          );
          pc++;

        case Opcodes.i64AtomicRmw32OrU:
          stack.add(
            WasmValue.i64(
              _atomicRmwI64Narrow(
                stack,
                instruction,
                widthBytes: 4,
                operation: (a, b) => a | b,
              ),
            ),
          );
          pc++;

        case Opcodes.i32AtomicRmwXor:
          stack.add(
            WasmValue.i32(_atomicRmwI32(stack, instruction, (a, b) => a ^ b)),
          );
          pc++;

        case Opcodes.i64AtomicRmwXor:
          stack.add(
            WasmValue.i64(_atomicRmwI64(stack, instruction, (a, b) => a ^ b)),
          );
          pc++;

        case Opcodes.i32AtomicRmw8XorU:
          stack.add(
            WasmValue.i32(
              _atomicRmwI32Narrow(
                stack,
                instruction,
                widthBytes: 1,
                operation: (a, b) => a ^ b,
              ),
            ),
          );
          pc++;

        case Opcodes.i32AtomicRmw16XorU:
          stack.add(
            WasmValue.i32(
              _atomicRmwI32Narrow(
                stack,
                instruction,
                widthBytes: 2,
                operation: (a, b) => a ^ b,
              ),
            ),
          );
          pc++;

        case Opcodes.i64AtomicRmw8XorU:
          stack.add(
            WasmValue.i64(
              _atomicRmwI64Narrow(
                stack,
                instruction,
                widthBytes: 1,
                operation: (a, b) => a ^ b,
              ),
            ),
          );
          pc++;

        case Opcodes.i64AtomicRmw16XorU:
          stack.add(
            WasmValue.i64(
              _atomicRmwI64Narrow(
                stack,
                instruction,
                widthBytes: 2,
                operation: (a, b) => a ^ b,
              ),
            ),
          );
          pc++;

        case Opcodes.i64AtomicRmw32XorU:
          stack.add(
            WasmValue.i64(
              _atomicRmwI64Narrow(
                stack,
                instruction,
                widthBytes: 4,
                operation: (a, b) => a ^ b,
              ),
            ),
          );
          pc++;

        case Opcodes.i32AtomicRmwXchg:
          stack.add(
            WasmValue.i32(_atomicRmwI32(stack, instruction, (_, b) => b)),
          );
          pc++;

        case Opcodes.i64AtomicRmwXchg:
          stack.add(
            WasmValue.i64(_atomicRmwI64(stack, instruction, (_, b) => b)),
          );
          pc++;

        case Opcodes.i32AtomicRmw8XchgU:
          stack.add(
            WasmValue.i32(
              _atomicRmwI32Narrow(
                stack,
                instruction,
                widthBytes: 1,
                operation: (_, b) => b,
              ),
            ),
          );
          pc++;

        case Opcodes.i32AtomicRmw16XchgU:
          stack.add(
            WasmValue.i32(
              _atomicRmwI32Narrow(
                stack,
                instruction,
                widthBytes: 2,
                operation: (_, b) => b,
              ),
            ),
          );
          pc++;

        case Opcodes.i64AtomicRmw8XchgU:
          stack.add(
            WasmValue.i64(
              _atomicRmwI64Narrow(
                stack,
                instruction,
                widthBytes: 1,
                operation: (_, b) => b,
              ),
            ),
          );
          pc++;

        case Opcodes.i64AtomicRmw16XchgU:
          stack.add(
            WasmValue.i64(
              _atomicRmwI64Narrow(
                stack,
                instruction,
                widthBytes: 2,
                operation: (_, b) => b,
              ),
            ),
          );
          pc++;

        case Opcodes.i64AtomicRmw32XchgU:
          stack.add(
            WasmValue.i64(
              _atomicRmwI64Narrow(
                stack,
                instruction,
                widthBytes: 4,
                operation: (_, b) => b,
              ),
            ),
          );
          pc++;

        case Opcodes.i32AtomicRmwCmpxchg:
          stack.add(WasmValue.i32(_atomicCmpxchgI32(stack, instruction)));
          pc++;

        case Opcodes.i64AtomicRmwCmpxchg:
          stack.add(WasmValue.i64(_atomicCmpxchgI64(stack, instruction)));
          pc++;

        case Opcodes.i32AtomicRmw8CmpxchgU:
          stack.add(
            WasmValue.i32(
              _atomicCmpxchgI32Narrow(stack, instruction, widthBytes: 1),
            ),
          );
          pc++;

        case Opcodes.i32AtomicRmw16CmpxchgU:
          stack.add(
            WasmValue.i32(
              _atomicCmpxchgI32Narrow(stack, instruction, widthBytes: 2),
            ),
          );
          pc++;

        case Opcodes.i64AtomicRmw8CmpxchgU:
          stack.add(
            WasmValue.i64(
              _atomicCmpxchgI64Narrow(stack, instruction, widthBytes: 1),
            ),
          );
          pc++;

        case Opcodes.i64AtomicRmw16CmpxchgU:
          stack.add(
            WasmValue.i64(
              _atomicCmpxchgI64Narrow(stack, instruction, widthBytes: 2),
            ),
          );
          pc++;

        case Opcodes.i64AtomicRmw32CmpxchgU:
          stack.add(
            WasmValue.i64(
              _atomicCmpxchgI64Narrow(stack, instruction, widthBytes: 4),
            ),
          );
          pc++;

        case Opcodes.memorySize:
          final memoryIndex = instruction.immediate!;
          final pageCount = _requireMemory(memoryIndex).pageCount;
          if (_isMemory64(memoryIndex)) {
            stack.add(WasmValue.i64(pageCount));
          } else {
            stack.add(WasmValue.i32(pageCount));
          }
          pc++;

        case Opcodes.memoryGrow:
          final memoryIndex = instruction.immediate!;
          final memory = _requireMemory(memoryIndex);
          final deltaPages = _popMemoryOperand(
            stack,
            memoryIndex: memoryIndex,
            label: 'memory.grow delta',
          );
          final previous = memory.grow(deltaPages);
          if (_isMemory64(memoryIndex)) {
            stack.add(WasmValue.i64(previous));
          } else {
            stack.add(WasmValue.i32(previous));
          }
          pc++;

        case Opcodes.i32Const:
          stack.add(WasmValue.i32(instruction.immediate!));
          pc++;

        case Opcodes.i64Const:
          stack.add(WasmValue.i64(instruction.immediate!));
          pc++;

        case Opcodes.f32Const:
          stack.add(WasmValue.f32(instruction.floatImmediate!));
          pc++;

        case Opcodes.f64Const:
          stack.add(WasmValue.f64(instruction.floatImmediate!));
          pc++;

        case Opcodes.refNull:
          stack.add(WasmValue.i32(_nullRef));
          pc++;

        case Opcodes.refFunc:
          final functionRef = _checkFunctionIndex(instruction.immediate!);
          stack.add(WasmValue.i32(functionRef));
          pc++;

        case Opcodes.refIsNull:
          stack.add(WasmValue.i32(_popRef(stack) == null ? 1 : 0));
          pc++;

        case Opcodes.refEq:
          final rhs = _popRef(stack);
          final lhs = _popRef(stack);
          stack.add(WasmValue.i32(lhs == rhs ? 1 : 0));
          pc++;

        case Opcodes.refAsNonNull:
          final value = _popRef(stack);
          if (value == null) {
            throw StateError('null reference');
          }
          _pushRef(stack, value);
          pc++;

        case Opcodes.structNew:
          _gcStructNew(stack, instruction);
          pc++;

        case Opcodes.structNewDefault:
          _gcStructNewDefault(stack, instruction);
          pc++;

        case Opcodes.structNewDesc:
          _gcStructNewDesc(stack, instruction);
          pc++;

        case Opcodes.structNewDefaultDesc:
          _gcStructNewDefaultDesc(stack, instruction);
          pc++;

        case Opcodes.structGetU:
        case Opcodes.structGetS:
          _gcStructGet(
            stack,
            instruction,
            signed: instruction.opcode == Opcodes.structGetS,
          );
          pc++;

        case Opcodes.arrayNew:
          _gcArrayNew(stack, instruction);
          pc++;

        case Opcodes.arrayNewDefault:
          _gcArrayNewDefault(stack, instruction);
          pc++;

        case Opcodes.arrayNewFixed:
          _gcArrayNewFixed(stack, instruction);
          pc++;

        case Opcodes.arrayNewData:
          _gcArrayNewData(stack, instruction);
          pc++;

        case Opcodes.arrayNewElem:
          _gcArrayNewElem(stack, instruction);
          pc++;

        case Opcodes.arrayInitData:
          _gcArrayInitData(stack, instruction);
          pc++;

        case Opcodes.arrayInitElem:
          _gcArrayInitElem(stack, instruction);
          pc++;

        case Opcodes.arrayCopy:
          _gcArrayCopy(stack, instruction);
          pc++;

        case Opcodes.arrayFill:
          _gcArrayFill(stack, instruction);
          pc++;

        case Opcodes.arrayGet:
        case Opcodes.arrayGetS:
        case Opcodes.arrayGetU:
          _gcArrayGet(
            stack,
            instruction,
            signed: instruction.opcode == Opcodes.arrayGetS,
          );
          pc++;

        case Opcodes.arraySet:
          _gcArraySet(stack, instruction);
          pc++;

        case Opcodes.arrayLen:
          _gcArrayLen(stack);
          pc++;

        case Opcodes.anyConvertExtern:
          _gcAnyConvertExtern(stack);
          pc++;

        case Opcodes.refI31:
          _gcRefI31(stack);
          pc++;

        case Opcodes.i31GetS:
        case Opcodes.i31GetU:
          _gcI31Get(stack, signed: instruction.opcode == Opcodes.i31GetS);
          pc++;

        case Opcodes.refTest:
        case Opcodes.refTestNullable:
          stack.add(WasmValue.i32(_gcRefTest(stack, instruction) ? 1 : 0));
          pc++;

        case Opcodes.refCast:
        case Opcodes.refCastNullable:
          _gcRefCast(stack, instruction);
          pc++;

        case Opcodes.refGetDesc:
          _gcRefGetDesc(stack, instruction);
          pc++;

        case Opcodes.refCastDesc:
        case Opcodes.refCastDescEq:
          _gcRefCastDescEq(stack, instruction);
          pc++;

        case Opcodes.brOnCast:
          final brOnCast = instruction.gcBrOnCast;
          if (brOnCast == null) {
            throw StateError('Missing br_on_cast immediate.');
          }
          final value = _popRef(stack);
          if (_gcRefMatches(value, brOnCast.targetType)) {
            _pushRef(stack, value);
            pc = _branch(brOnCast.depth, labels, stack);
          } else {
            _pushRef(stack, value);
            pc++;
          }

        case Opcodes.brOnCastFail:
          final brOnCast = instruction.gcBrOnCast;
          if (brOnCast == null) {
            throw StateError('Missing br_on_cast_fail immediate.');
          }
          final value = _popRef(stack);
          final matches = _gcRefMatches(value, brOnCast.targetType);
          if (!matches) {
            _pushRef(stack, value);
            pc = _branch(brOnCast.depth, labels, stack);
          } else {
            _pushRef(stack, value);
            pc++;
          }

        case Opcodes.brOnCastDescEq:
          final brOnCast = instruction.gcBrOnCast;
          if (brOnCast == null) {
            throw StateError('Missing br_on_cast_desc_eq immediate.');
          }
          final descriptor = _popRef(stack);
          final value = _popRef(stack);
          final matches = _gcRefMatchesWithDescriptor(
            value: value,
            descriptor: descriptor,
            targetType: brOnCast.targetType,
          );
          if (matches) {
            _pushRef(stack, value);
            pc = _branch(brOnCast.depth, labels, stack);
          } else {
            _pushRef(stack, value);
            pc++;
          }

        case Opcodes.brOnCastDescEqFail:
          final brOnCast = instruction.gcBrOnCast;
          if (brOnCast == null) {
            throw StateError('Missing br_on_cast_desc_eq_fail immediate.');
          }
          final descriptor = _popRef(stack);
          final value = _popRef(stack);
          final matches = _gcRefMatchesWithDescriptor(
            value: value,
            descriptor: descriptor,
            targetType: brOnCast.targetType,
          );
          if (!matches) {
            _pushRef(stack, value);
            pc = _branch(brOnCast.depth, labels, stack);
          } else {
            _pushRef(stack, value);
            pc++;
          }

        case Opcodes.i32Eqz:
          stack.add(WasmValue.i32(_popI32(stack) == 0 ? 1 : 0));
          pc++;

        case Opcodes.i32Eq:
          stack.add(WasmValue.i32(_popI32(stack) == _popI32(stack) ? 1 : 0));
          pc++;

        case Opcodes.i32Ne:
          stack.add(WasmValue.i32(_popI32(stack) != _popI32(stack) ? 1 : 0));
          pc++;

        case Opcodes.i32LtS:
          final rhs = _popI32(stack);
          final lhs = _popI32(stack);
          stack.add(WasmValue.i32(lhs < rhs ? 1 : 0));
          pc++;

        case Opcodes.i32LtU:
          final rhs = _toU32(_popI32(stack));
          final lhs = _toU32(_popI32(stack));
          stack.add(WasmValue.i32(lhs < rhs ? 1 : 0));
          pc++;

        case Opcodes.i32GtS:
          final rhs = _popI32(stack);
          final lhs = _popI32(stack);
          stack.add(WasmValue.i32(lhs > rhs ? 1 : 0));
          pc++;

        case Opcodes.i32GtU:
          final rhs = _toU32(_popI32(stack));
          final lhs = _toU32(_popI32(stack));
          stack.add(WasmValue.i32(lhs > rhs ? 1 : 0));
          pc++;

        case Opcodes.i32LeS:
          final rhs = _popI32(stack);
          final lhs = _popI32(stack);
          stack.add(WasmValue.i32(lhs <= rhs ? 1 : 0));
          pc++;

        case Opcodes.i32LeU:
          final rhs = _toU32(_popI32(stack));
          final lhs = _toU32(_popI32(stack));
          stack.add(WasmValue.i32(lhs <= rhs ? 1 : 0));
          pc++;

        case Opcodes.i32GeS:
          final rhs = _popI32(stack);
          final lhs = _popI32(stack);
          stack.add(WasmValue.i32(lhs >= rhs ? 1 : 0));
          pc++;

        case Opcodes.i32GeU:
          final rhs = _toU32(_popI32(stack));
          final lhs = _toU32(_popI32(stack));
          stack.add(WasmValue.i32(lhs >= rhs ? 1 : 0));
          pc++;

        case Opcodes.i64Eqz:
          stack.add(WasmValue.i32(_popI64(stack) == BigInt.zero ? 1 : 0));
          pc++;

        case Opcodes.i64Eq:
          stack.add(WasmValue.i32(_popI64(stack) == _popI64(stack) ? 1 : 0));
          pc++;

        case Opcodes.i64Ne:
          stack.add(WasmValue.i32(_popI64(stack) != _popI64(stack) ? 1 : 0));
          pc++;

        case Opcodes.i64LtS:
          final rhs = _popI64(stack);
          final lhs = _popI64(stack);
          stack.add(WasmValue.i32(lhs.compareTo(rhs) < 0 ? 1 : 0));
          pc++;

        case Opcodes.i64LtU:
          final rhs = _popI64(stack);
          final lhs = _popI64(stack);
          stack.add(
            WasmValue.i32(WasmI64.compareUnsigned(lhs, rhs) < 0 ? 1 : 0),
          );
          pc++;

        case Opcodes.i64GtS:
          final rhs = _popI64(stack);
          final lhs = _popI64(stack);
          stack.add(WasmValue.i32(lhs.compareTo(rhs) > 0 ? 1 : 0));
          pc++;

        case Opcodes.i64GtU:
          final rhs = _popI64(stack);
          final lhs = _popI64(stack);
          stack.add(
            WasmValue.i32(WasmI64.compareUnsigned(lhs, rhs) > 0 ? 1 : 0),
          );
          pc++;

        case Opcodes.i64LeS:
          final rhs = _popI64(stack);
          final lhs = _popI64(stack);
          stack.add(WasmValue.i32(lhs.compareTo(rhs) <= 0 ? 1 : 0));
          pc++;

        case Opcodes.i64LeU:
          final rhs = _popI64(stack);
          final lhs = _popI64(stack);
          stack.add(
            WasmValue.i32(WasmI64.compareUnsigned(lhs, rhs) <= 0 ? 1 : 0),
          );
          pc++;

        case Opcodes.i64GeS:
          final rhs = _popI64(stack);
          final lhs = _popI64(stack);
          stack.add(WasmValue.i32(lhs.compareTo(rhs) >= 0 ? 1 : 0));
          pc++;

        case Opcodes.i64GeU:
          final rhs = _popI64(stack);
          final lhs = _popI64(stack);
          stack.add(
            WasmValue.i32(WasmI64.compareUnsigned(lhs, rhs) >= 0 ? 1 : 0),
          );
          pc++;

        case Opcodes.f32Eq:
          stack.add(WasmValue.i32(_popF32(stack) == _popF32(stack) ? 1 : 0));
          pc++;

        case Opcodes.f32Ne:
          stack.add(WasmValue.i32(_popF32(stack) != _popF32(stack) ? 1 : 0));
          pc++;

        case Opcodes.f32Lt:
          final rhs = _popF32(stack);
          final lhs = _popF32(stack);
          stack.add(WasmValue.i32(lhs < rhs ? 1 : 0));
          pc++;

        case Opcodes.f32Gt:
          final rhs = _popF32(stack);
          final lhs = _popF32(stack);
          stack.add(WasmValue.i32(lhs > rhs ? 1 : 0));
          pc++;

        case Opcodes.f32Le:
          final rhs = _popF32(stack);
          final lhs = _popF32(stack);
          stack.add(WasmValue.i32(lhs <= rhs ? 1 : 0));
          pc++;

        case Opcodes.f32Ge:
          final rhs = _popF32(stack);
          final lhs = _popF32(stack);
          stack.add(WasmValue.i32(lhs >= rhs ? 1 : 0));
          pc++;

        case Opcodes.f64Eq:
          stack.add(WasmValue.i32(_popF64(stack) == _popF64(stack) ? 1 : 0));
          pc++;

        case Opcodes.f64Ne:
          stack.add(WasmValue.i32(_popF64(stack) != _popF64(stack) ? 1 : 0));
          pc++;

        case Opcodes.f64Lt:
          final rhs = _popF64(stack);
          final lhs = _popF64(stack);
          stack.add(WasmValue.i32(lhs < rhs ? 1 : 0));
          pc++;

        case Opcodes.f64Gt:
          final rhs = _popF64(stack);
          final lhs = _popF64(stack);
          stack.add(WasmValue.i32(lhs > rhs ? 1 : 0));
          pc++;

        case Opcodes.f64Le:
          final rhs = _popF64(stack);
          final lhs = _popF64(stack);
          stack.add(WasmValue.i32(lhs <= rhs ? 1 : 0));
          pc++;

        case Opcodes.f64Ge:
          final rhs = _popF64(stack);
          final lhs = _popF64(stack);
          stack.add(WasmValue.i32(lhs >= rhs ? 1 : 0));
          pc++;

        case Opcodes.i32Clz:
          stack.add(WasmValue.i32(_i32Clz(_popI32(stack))));
          pc++;

        case Opcodes.i32Ctz:
          stack.add(WasmValue.i32(_i32Ctz(_popI32(stack))));
          pc++;

        case Opcodes.i32Popcnt:
          stack.add(WasmValue.i32(_i32Popcnt(_popI32(stack))));
          pc++;

        case Opcodes.i32Add:
          stack.add(WasmValue.i32(_popI32(stack) + _popI32(stack)));
          pc++;

        case Opcodes.i32Sub:
          final rhs = _popI32(stack);
          final lhs = _popI32(stack);
          stack.add(WasmValue.i32(lhs - rhs));
          pc++;

        case Opcodes.i32Mul:
          stack.add(WasmValue.i32(_popI32(stack) * _popI32(stack)));
          pc++;

        case Opcodes.i32DivS:
          final rhs = _popI32(stack);
          final lhs = _popI32(stack);
          if (rhs == 0) {
            throw StateError('i32.div_s division by zero trap');
          }
          if (lhs == -2147483648 && rhs == -1) {
            throw StateError('i32.div_s overflow trap');
          }
          stack.add(WasmValue.i32(lhs ~/ rhs));
          pc++;

        case Opcodes.i32DivU:
          final rhs = _toU32(_popI32(stack));
          final lhs = _toU32(_popI32(stack));
          if (rhs == 0) {
            throw StateError('i32.div_u division by zero trap');
          }
          stack.add(WasmValue.i32(lhs ~/ rhs));
          pc++;

        case Opcodes.i32RemS:
          final rhs = _popI32(stack);
          final lhs = _popI32(stack);
          if (rhs == 0) {
            throw StateError('i32.rem_s division by zero trap');
          }
          stack.add(WasmValue.i32(lhs.remainder(rhs)));
          pc++;

        case Opcodes.i32RemU:
          final rhs = _toU32(_popI32(stack));
          final lhs = _toU32(_popI32(stack));
          if (rhs == 0) {
            throw StateError('i32.rem_u division by zero trap');
          }
          stack.add(WasmValue.i32(lhs % rhs));
          pc++;

        case Opcodes.i32And:
          stack.add(WasmValue.i32(_popI32(stack) & _popI32(stack)));
          pc++;

        case Opcodes.i32Or:
          stack.add(WasmValue.i32(_popI32(stack) | _popI32(stack)));
          pc++;

        case Opcodes.i32Xor:
          stack.add(WasmValue.i32(_popI32(stack) ^ _popI32(stack)));
          pc++;

        case Opcodes.i32Shl:
          final rhs = _popI32(stack) & 31;
          stack.add(WasmValue.i32(_popI32(stack) << rhs));
          pc++;

        case Opcodes.i32ShrS:
          final rhs = _popI32(stack) & 31;
          stack.add(WasmValue.i32(_popI32(stack) >> rhs));
          pc++;

        case Opcodes.i32ShrU:
          final rhs = _popI32(stack) & 31;
          stack.add(WasmValue.i32(_toU32(_popI32(stack)) >> rhs));
          pc++;

        case Opcodes.i32Rotl:
          final rhs = _popI32(stack) & 31;
          stack.add(WasmValue.i32(_rotl32(_toU32(_popI32(stack)), rhs)));
          pc++;

        case Opcodes.i32Rotr:
          final rhs = _popI32(stack) & 31;
          stack.add(WasmValue.i32(_rotr32(_toU32(_popI32(stack)), rhs)));
          pc++;

        case Opcodes.i64Clz:
          stack.add(WasmValue.i64(_i64Clz(_popI64(stack))));
          pc++;

        case Opcodes.i64Ctz:
          stack.add(WasmValue.i64(_i64Ctz(_popI64(stack))));
          pc++;

        case Opcodes.i64Popcnt:
          stack.add(WasmValue.i64(_i64Popcnt(_popI64(stack))));
          pc++;

        case Opcodes.i64Add:
          final rhs = _popI64(stack);
          final lhs = _popI64(stack);
          stack.add(WasmValue.i64(WasmI64.add(lhs, rhs)));
          pc++;

        case Opcodes.i64Sub:
          final rhs = _popI64(stack);
          final lhs = _popI64(stack);
          stack.add(WasmValue.i64(WasmI64.sub(lhs, rhs)));
          pc++;

        case Opcodes.i64Mul:
          final rhs = _popI64(stack);
          final lhs = _popI64(stack);
          stack.add(WasmValue.i64(WasmI64.mul(lhs, rhs)));
          pc++;

        case Opcodes.i64DivS:
          final rhs = _popI64(stack);
          final lhs = _popI64(stack);
          if (rhs == BigInt.zero) {
            throw StateError('i64.div_s division by zero trap');
          }
          if (lhs == _i64MinValue && rhs == -BigInt.one) {
            throw StateError('i64.div_s overflow trap');
          }
          stack.add(WasmValue.i64(WasmI64.divS(lhs, rhs)));
          pc++;

        case Opcodes.i64DivU:
          final rhs = _popI64(stack);
          final lhs = _popI64(stack);
          if (rhs == BigInt.zero) {
            throw StateError('i64.div_u division by zero trap');
          }
          stack.add(WasmValue.i64(WasmI64.divU(lhs, rhs)));
          pc++;

        case Opcodes.i64RemS:
          final rhs = _popI64(stack);
          final lhs = _popI64(stack);
          if (rhs == BigInt.zero) {
            throw StateError('i64.rem_s division by zero trap');
          }
          stack.add(WasmValue.i64(WasmI64.remS(lhs, rhs)));
          pc++;

        case Opcodes.i64RemU:
          final rhs = _popI64(stack);
          final lhs = _popI64(stack);
          if (rhs == BigInt.zero) {
            throw StateError('i64.rem_u division by zero trap');
          }
          stack.add(WasmValue.i64(WasmI64.remU(lhs, rhs)));
          pc++;

        case Opcodes.i64And:
          final rhs = _popI64(stack);
          final lhs = _popI64(stack);
          stack.add(WasmValue.i64(WasmI64.and(lhs, rhs)));
          pc++;

        case Opcodes.i64Or:
          final rhs = _popI64(stack);
          final lhs = _popI64(stack);
          stack.add(WasmValue.i64(WasmI64.or(lhs, rhs)));
          pc++;

        case Opcodes.i64Xor:
          final rhs = _popI64(stack);
          final lhs = _popI64(stack);
          stack.add(WasmValue.i64(WasmI64.xor(lhs, rhs)));
          pc++;

        case Opcodes.i64Shl:
          final rhs = (_popI64(stack) & BigInt.from(63)).toInt();
          stack.add(WasmValue.i64(WasmI64.shl(_popI64(stack), rhs)));
          pc++;

        case Opcodes.i64ShrS:
          final rhs = (_popI64(stack) & BigInt.from(63)).toInt();
          stack.add(WasmValue.i64(WasmI64.shrS(_popI64(stack), rhs)));
          pc++;

        case Opcodes.i64ShrU:
          final rhs = (_popI64(stack) & BigInt.from(63)).toInt();
          stack.add(WasmValue.i64(WasmI64.shrU(_popI64(stack), rhs)));
          pc++;

        case Opcodes.i64Rotl:
          final rhs = (_popI64(stack) & BigInt.from(63)).toInt();
          stack.add(WasmValue.i64(_rotl64(_popI64(stack), rhs)));
          pc++;

        case Opcodes.i64Rotr:
          final rhs = (_popI64(stack) & BigInt.from(63)).toInt();
          stack.add(WasmValue.i64(_rotr64(_popI64(stack), rhs)));
          pc++;

        case Opcodes.f32Abs:
          stack.add(WasmValue.f32(_popF32(stack).abs()));
          pc++;

        case Opcodes.f32Neg:
          stack.add(WasmValue.f32(-_popF32(stack)));
          pc++;

        case Opcodes.f32Ceil:
          stack.add(WasmValue.f32(_popF32(stack).ceilToDouble()));
          pc++;

        case Opcodes.f32Floor:
          stack.add(WasmValue.f32(_popF32(stack).floorToDouble()));
          pc++;

        case Opcodes.f32Trunc:
          stack.add(WasmValue.f32(_popF32(stack).truncateToDouble()));
          pc++;

        case Opcodes.f32Nearest:
          stack.add(WasmValue.f32(_nearest(_popF32(stack))));
          pc++;

        case Opcodes.f32Sqrt:
          stack.add(WasmValue.f32(math.sqrt(_popF32(stack))));
          pc++;

        case Opcodes.f32Add:
          stack.add(WasmValue.f32(_popF32(stack) + _popF32(stack)));
          pc++;

        case Opcodes.f32Sub:
          final rhs = _popF32(stack);
          final lhs = _popF32(stack);
          stack.add(WasmValue.f32(lhs - rhs));
          pc++;

        case Opcodes.f32Mul:
          stack.add(WasmValue.f32(_popF32(stack) * _popF32(stack)));
          pc++;

        case Opcodes.f32Div:
          final rhs = _popF32(stack);
          final lhs = _popF32(stack);
          stack.add(WasmValue.f32(lhs / rhs));
          pc++;

        case Opcodes.f32Min:
          final rhs = _popF32(stack);
          final lhs = _popF32(stack);
          stack.add(WasmValue.f32(_fMin(lhs, rhs)));
          pc++;

        case Opcodes.f32Max:
          final rhs = _popF32(stack);
          final lhs = _popF32(stack);
          stack.add(WasmValue.f32(_fMax(lhs, rhs)));
          pc++;

        case Opcodes.f32CopySign:
          final rhs = _popF32(stack);
          final lhs = _popF32(stack);
          stack.add(WasmValue.f32(_copySignF32(lhs, rhs)));
          pc++;

        case Opcodes.f64Abs:
          stack.add(WasmValue.f64(_popF64(stack).abs()));
          pc++;

        case Opcodes.f64Neg:
          stack.add(WasmValue.f64(-_popF64(stack)));
          pc++;

        case Opcodes.f64Ceil:
          stack.add(WasmValue.f64(_popF64(stack).ceilToDouble()));
          pc++;

        case Opcodes.f64Floor:
          stack.add(WasmValue.f64(_popF64(stack).floorToDouble()));
          pc++;

        case Opcodes.f64Trunc:
          stack.add(WasmValue.f64(_popF64(stack).truncateToDouble()));
          pc++;

        case Opcodes.f64Nearest:
          stack.add(WasmValue.f64(_nearest(_popF64(stack))));
          pc++;

        case Opcodes.f64Sqrt:
          stack.add(WasmValue.f64(math.sqrt(_popF64(stack))));
          pc++;

        case Opcodes.f64Add:
          stack.add(WasmValue.f64(_popF64(stack) + _popF64(stack)));
          pc++;

        case Opcodes.f64Sub:
          final rhs = _popF64(stack);
          final lhs = _popF64(stack);
          stack.add(WasmValue.f64(lhs - rhs));
          pc++;

        case Opcodes.f64Mul:
          stack.add(WasmValue.f64(_popF64(stack) * _popF64(stack)));
          pc++;

        case Opcodes.f64Div:
          final rhs = _popF64(stack);
          final lhs = _popF64(stack);
          stack.add(WasmValue.f64(lhs / rhs));
          pc++;

        case Opcodes.f64Min:
          final rhs = _popF64(stack);
          final lhs = _popF64(stack);
          stack.add(WasmValue.f64(_fMin(lhs, rhs)));
          pc++;

        case Opcodes.f64Max:
          final rhs = _popF64(stack);
          final lhs = _popF64(stack);
          stack.add(WasmValue.f64(_fMax(lhs, rhs)));
          pc++;

        case Opcodes.f64CopySign:
          final rhs = _popF64(stack);
          final lhs = _popF64(stack);
          stack.add(WasmValue.f64(_copySignF64(lhs, rhs)));
          pc++;

        case Opcodes.i32WrapI64:
          stack.add(WasmValue.i32(WasmI64.lowU32(_popI64(stack)).toSigned(32)));
          pc++;

        case Opcodes.i32TruncF32S:
          stack.add(WasmValue.i32(_truncToI32S(_popF32(stack))));
          pc++;

        case Opcodes.i32TruncF32U:
          stack.add(WasmValue.i32(_truncToI32U(_popF32(stack))));
          pc++;

        case Opcodes.i32TruncF64S:
          stack.add(WasmValue.i32(_truncToI32S(_popF64(stack))));
          pc++;

        case Opcodes.i32TruncF64U:
          stack.add(WasmValue.i32(_truncToI32U(_popF64(stack))));
          pc++;

        case Opcodes.i64ExtendI32S:
          stack.add(WasmValue.i64(_popI32(stack)));
          pc++;

        case Opcodes.i64ExtendI32U:
          stack.add(WasmValue.i64(_toU32(_popI32(stack))));
          pc++;

        case Opcodes.i64TruncF32S:
          stack.add(WasmValue.i64(_truncToI64S(_popF32(stack))));
          pc++;

        case Opcodes.i64TruncF32U:
          stack.add(WasmValue.i64(_toSignedI64(_truncToI64U(_popF32(stack)))));
          pc++;

        case Opcodes.i64TruncF64S:
          stack.add(WasmValue.i64(_truncToI64S(_popF64(stack))));
          pc++;

        case Opcodes.i64TruncF64U:
          stack.add(WasmValue.i64(_toSignedI64(_truncToI64U(_popF64(stack)))));
          pc++;

        case Opcodes.f32ConvertI32S:
          stack.add(WasmValue.f32(_popI32(stack).toDouble()));
          pc++;

        case Opcodes.f32ConvertI32U:
          stack.add(WasmValue.f32(_toU32(_popI32(stack)).toDouble()));
          pc++;

        case Opcodes.f32ConvertI64S:
          stack.add(WasmValue.f32(_popI64(stack).toDouble()));
          pc++;

        case Opcodes.f32ConvertI64U:
          stack.add(WasmValue.f32(WasmI64.unsignedToDouble(_popI64(stack))));
          pc++;

        case Opcodes.f32DemoteF64:
          stack.add(WasmValue.f32(_popF64(stack)));
          pc++;

        case Opcodes.f64ConvertI32S:
          stack.add(WasmValue.f64(_popI32(stack).toDouble()));
          pc++;

        case Opcodes.f64ConvertI32U:
          stack.add(WasmValue.f64(_toU32(_popI32(stack)).toDouble()));
          pc++;

        case Opcodes.f64ConvertI64S:
          stack.add(WasmValue.f64(_popI64(stack).toDouble()));
          pc++;

        case Opcodes.f64ConvertI64U:
          stack.add(WasmValue.f64(WasmI64.unsignedToDouble(_popI64(stack))));
          pc++;

        case Opcodes.f64PromoteF32:
          stack.add(WasmValue.f64(_popF32(stack)));
          pc++;

        case Opcodes.i32ReinterpretF32:
          stack.add(WasmValue.i32(WasmValue.toF32Bits(_popF32(stack))));
          pc++;

        case Opcodes.i64ReinterpretF64:
          stack.add(WasmValue.i64(WasmValue.toF64Bits(_popF64(stack))));
          pc++;

        case Opcodes.f32ReinterpretI32:
          stack.add(
            WasmValue.f32(WasmValue.fromF32Bits(_toU32(_popI32(stack)))),
          );
          pc++;

        case Opcodes.f64ReinterpretI64:
          stack.add(
            WasmValue.f64(WasmValue.fromF64Bits(_toU64(_popI64(stack)))),
          );
          pc++;

        case Opcodes.i32Extend8S:
          stack.add(WasmValue.i32(_signExtend(_popI32(stack), 8)));
          pc++;

        case Opcodes.i32Extend16S:
          stack.add(WasmValue.i32(_signExtend(_popI32(stack), 16)));
          pc++;

        case Opcodes.i64Extend8S:
          stack.add(WasmValue.i64(_signExtend64(_popI64(stack), 8)));
          pc++;

        case Opcodes.i64Extend16S:
          stack.add(WasmValue.i64(_signExtend64(_popI64(stack), 16)));
          pc++;

        case Opcodes.i64Extend32S:
          stack.add(WasmValue.i64(_signExtend64(_popI64(stack), 32)));
          pc++;

        case Opcodes.i32TruncSatF32S:
          stack.add(WasmValue.i32(_truncSatToI32S(_popF32(stack))));
          pc++;

        case Opcodes.i32TruncSatF32U:
          stack.add(WasmValue.i32(_truncSatToI32U(_popF32(stack))));
          pc++;

        case Opcodes.i32TruncSatF64S:
          stack.add(WasmValue.i32(_truncSatToI32S(_popF64(stack))));
          pc++;

        case Opcodes.i32TruncSatF64U:
          stack.add(WasmValue.i32(_truncSatToI32U(_popF64(stack))));
          pc++;

        case Opcodes.i64TruncSatF32S:
          stack.add(WasmValue.i64(_truncSatToI64S(_popF32(stack))));
          pc++;

        case Opcodes.i64TruncSatF32U:
          stack.add(
            WasmValue.i64(_toSignedI64(_truncSatToI64U(_popF32(stack)))),
          );
          pc++;

        case Opcodes.i64TruncSatF64S:
          stack.add(WasmValue.i64(_truncSatToI64S(_popF64(stack))));
          pc++;

        case Opcodes.i64TruncSatF64U:
          stack.add(
            WasmValue.i64(_toSignedI64(_truncSatToI64U(_popF64(stack)))),
          );
          pc++;

        case Opcodes.i64Add128:
          _i64Add128(stack);
          pc++;

        case Opcodes.i64Sub128:
          _i64Sub128(stack);
          pc++;

        case Opcodes.i64MulWideS:
          _i64MulWideS(stack);
          pc++;

        case Opcodes.i64MulWideU:
          _i64MulWideU(stack);
          pc++;

        case Opcodes.memoryInit:
          _memoryInit(instruction, stack);
          pc++;

        case Opcodes.dataDrop:
          _dataDrop(instruction.immediate!);
          pc++;

        case Opcodes.memoryCopy:
          _memoryCopy(instruction, stack);
          pc++;

        case Opcodes.memoryFill:
          _memoryFill(instruction, stack);
          pc++;

        case Opcodes.tableInit:
          _tableInit(instruction, stack);
          pc++;

        case Opcodes.elemDrop:
          _elemDrop(instruction.immediate!);
          pc++;

        case Opcodes.tableCopy:
          _tableCopy(instruction, stack);
          pc++;

        case Opcodes.tableGrow:
          _tableGrow(instruction, stack);
          pc++;

        case Opcodes.tableSize:
          _tableSize(instruction, stack);
          pc++;

        case Opcodes.tableFill:
          _tableFill(instruction, stack);
          pc++;

        default:
          throw UnsupportedError(
            'Unsupported opcode: 0x${instruction.opcode.toRadixString(16)}',
          );
      }
    }

    throw StateError('Function execution ended without `end` instruction.');
  }

  int _branch(int depth, List<_LabelFrame> labels, List<WasmValue> stack) {
    if (depth < 0 || depth >= labels.length) {
      throw RangeError(
        'Invalid label depth: $depth (labels=${labels.length}).',
      );
    }

    final targetPosition = labels.length - 1 - depth;
    final target = labels[targetPosition];

    final results = _takeTopValues(stack, target.branchTypes);
    stack.length = target.stackHeight;
    stack.addAll(results);

    if (target.kind == _LabelKind.loop) {
      if (targetPosition + 1 < labels.length) {
        labels.removeRange(targetPosition + 1, labels.length);
      }
      return target.loopStartIndex;
    }

    if (targetPosition == 0) {
      if (labels.length > 1) {
        labels.removeRange(1, labels.length);
      }
      return target.endIndex;
    }

    labels.removeRange(targetPosition, labels.length);
    return target.endIndex + 1;
  }

  void _exitLabel(_LabelFrame label, List<WasmValue> stack) {
    final results = _takeTopValues(stack, label.endTypes);
    stack.length = label.stackHeight;
    stack.addAll(results);
  }

  List<WasmValue> _takeTopValues(
    List<WasmValue> stack,
    List<WasmValueType> resultTypes,
  ) {
    if (resultTypes.isEmpty) {
      return const [];
    }

    if (stack.length < resultTypes.length) {
      throw StateError(
        'Operand stack underflow for arity ${resultTypes.length}.',
      );
    }

    final start = stack.length - resultTypes.length;
    final results = <WasmValue>[];
    for (var i = 0; i < resultTypes.length; i++) {
      results.add(stack[start + i].castTo(resultTypes[i]));
    }
    return results;
  }

  List<WasmValue> _popArgs(
    List<WasmValue> stack,
    List<WasmValueType> paramTypes,
  ) {
    if (paramTypes.isEmpty) {
      return const [];
    }

    if (stack.length < paramTypes.length) {
      throw StateError('Operand stack underflow while preparing call args.');
    }

    final args = List<WasmValue>.generate(
      paramTypes.length,
      (index) => WasmValue.zeroForType(paramTypes[index]),
      growable: false,
    );

    for (var i = paramTypes.length - 1; i >= 0; i--) {
      args[i] = _pop(stack).castTo(paramTypes[i]);
    }

    return args;
  }

  List<WasmValue> _collectResults(
    List<WasmValueType> resultTypes,
    List<WasmValue> stack,
  ) {
    if (resultTypes.isEmpty) {
      return const [];
    }

    if (stack.length < resultTypes.length) {
      throw StateError('Not enough values on stack for function result.');
    }

    final start = stack.length - resultTypes.length;
    final results = <WasmValue>[];
    for (var i = 0; i < resultTypes.length; i++) {
      results.add(stack[start + i].castTo(resultTypes[i]));
    }
    return results;
  }

  List<WasmValue> _normalizeValues(
    List<WasmValue> values,
    List<WasmValueType> types,
  ) {
    final normalized = <WasmValue>[];
    for (var i = 0; i < types.length; i++) {
      normalized.add(values[i].castTo(types[i]));
    }
    return normalized;
  }

  int _checkIndex(int index, int count, String label) {
    if (index < 0 || index >= count) {
      throw RangeError('Invalid $label index: $index (count=$count).');
    }
    return index;
  }

  int _checkFunctionIndex(int index) {
    return _checkIndex(index, _functions.length, 'function');
  }

  int _checkTypeIndex(int index) {
    return _checkIndex(index, _types.length, 'type');
  }

  int _checkTableIndex(int index) {
    return _checkIndex(index, _tables.length, 'table');
  }

  int _checkDataSegmentIndex(int index) {
    return _checkIndex(index, _dataSegments.length, 'data segment');
  }

  int _checkElementSegmentIndex(int index) {
    return _checkIndex(index, _elementSegments.length, 'element segment');
  }

  WasmMemory _requireMemory([int memoryIndex = 0]) {
    if (memoryIndex < 0 || memoryIndex >= _memories.length) {
      throw RangeError(
        'Invalid memory index: $memoryIndex (count=${_memories.length}).',
      );
    }
    return _memories[memoryIndex];
  }

  bool _isMemory64(int memoryIndex) {
    if (memoryIndex < 0 || memoryIndex >= _memory64ByIndex.length) {
      throw RangeError(
        'Invalid memory index: $memoryIndex (count=${_memory64ByIndex.length}).',
      );
    }
    return _memory64ByIndex[memoryIndex];
  }

  BigInt _popUnsignedMemoryOperand(
    List<WasmValue> stack, {
    required int memoryIndex,
  }) {
    if (_isMemory64(memoryIndex)) {
      return _toU64(_popI64(stack));
    }
    return BigInt.from(_toU32(_popI32(stack)));
  }

  int _popMemoryOperand(
    List<WasmValue> stack, {
    required int memoryIndex,
    required String label,
  }) {
    final operand = _popUnsignedMemoryOperand(stack, memoryIndex: memoryIndex);
    return _toLinearMemoryValue(operand, label: label);
  }

  int _requireJumpIndex(int? index, String context) {
    if (index == null) {
      throw StateError('Missing jump index for `$context`.');
    }
    return index;
  }

  WasmMemory _memoryForMemArg(Instruction instruction) {
    final memArg = instruction.memArg;
    if (memArg == null) {
      throw StateError('Missing memarg for opcode 0x${instruction.opcode}.');
    }
    return _requireMemory(memArg.memoryIndex);
  }

  bool _functionTypeEquals(WasmFunctionType a, WasmFunctionType b) {
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

  bool _gcRefTest(List<WasmValue> stack, Instruction instruction) {
    final gcRefType = instruction.gcRefType;
    if (gcRefType == null) {
      throw StateError('Missing ref.test immediate.');
    }
    final value = _popRef(stack);
    return _gcRefMatches(value, gcRefType);
  }

  void _gcRefCast(List<WasmValue> stack, Instruction instruction) {
    final gcRefType = instruction.gcRefType;
    if (gcRefType == null) {
      throw StateError('Missing ref.cast immediate.');
    }
    final value = _popRef(stack);
    if (!_gcRefMatches(value, gcRefType)) {
      throw StateError('cast failure');
    }
    _pushRef(stack, value);
  }

  void _gcRefGetDesc(List<WasmValue> stack, Instruction instruction) {
    final typeIndex = instruction.immediate;
    if (typeIndex == null) {
      throw StateError('Missing ref.get_desc immediate.');
    }
    final expectedType = _types[_checkTypeIndex(typeIndex)];
    if (expectedType.descriptorTypeIndex == null) {
      throw StateError('type without descriptor');
    }
    final value = _popRef(stack);
    if (value == null) {
      throw StateError('null reference');
    }
    final descriptor = _gcDescriptorForRef(value);
    if (descriptor == null) {
      throw StateError('descriptor not available');
    }
    _pushRef(stack, descriptor);
  }

  void _gcRefCastDescEq(List<WasmValue> stack, Instruction instruction) {
    final gcRefType = instruction.gcRefType;
    if (gcRefType == null) {
      throw StateError('Missing ref.cast_desc_eq immediate.');
    }
    final descriptor = _popRef(stack);
    final value = _popRef(stack);
    if (!_gcRefMatchesWithDescriptor(
      value: value,
      descriptor: descriptor,
      targetType: gcRefType,
    )) {
      throw StateError('descriptor cast failure');
    }
    _pushRef(stack, value);
  }

  bool _gcRefMatchesWithDescriptor({
    required int? value,
    required int? descriptor,
    required GcRefTypeImmediate targetType,
  }) {
    if (descriptor == null) {
      throw StateError('null descriptor reference');
    }
    if (!_gcRefMatches(value, targetType)) {
      return false;
    }
    if (value == null) {
      return true;
    }
    final valueDescriptor = _gcDescriptorForRef(value);
    return valueDescriptor == descriptor;
  }

  int? _gcDescriptorForRef(int reference) {
    if (reference >= 0) {
      return null;
    }
    final constRef = decodeConstGcRef(reference);
    if (constRef != null) {
      return constRef.descriptorRef;
    }
    final object = _requireGcObject(reference);
    return object.descriptorRef;
  }

  bool _gcRefMatches(int? reference, GcRefTypeImmediate refType) {
    if (reference == null) {
      return refType.nullable;
    }
    final targetHeapType = refType.heapType;
    if (reference >= 0) {
      if (targetHeapType < 0) {
        return _functionRefMatchesAbstract(
          targetHeapType,
          exact: refType.exact,
        );
      }
      final actualTypeIndex =
          _functions[_checkFunctionIndex(reference)].declaredTypeIndex;
      return _functionTypeMatchesByDepth(
        actualTypeIndex: actualTypeIndex,
        targetTypeIndex: targetHeapType,
        exact: refType.exact,
        actualDepthOverride: _functions[reference].runtimeTypeDepth,
      );
    }

    final constRef = decodeConstGcRef(reference);
    if (constRef != null) {
      switch (constRef.kind) {
        case constGcRefKindI31:
          return _i31RefMatches(targetHeapType, exact: refType.exact);
        case constGcRefKindStruct:
        case constGcRefKindArray:
          return _typedGcRefMatches(
            constRef.typeIndex,
            targetHeapType,
            exact: refType.exact,
          );
        default:
          return false;
      }
    }

    final object = _requireGcObject(reference);
    switch (object.kind) {
      case _GcRefKind.i31:
        return _i31RefMatches(targetHeapType, exact: refType.exact);
      case _GcRefKind.struct:
      case _GcRefKind.array:
        return _typedGcRefMatches(
          object.typeIndex!,
          targetHeapType,
          exact: refType.exact,
        );
      case _GcRefKind.extern:
        return _externRefMatches(targetHeapType, exact: refType.exact);
    }
  }

  bool _functionRefMatchesAbstract(int heapType, {required bool exact}) {
    if (exact) {
      return false;
    }
    return heapType == _heapFunc;
  }

  bool _i31RefMatches(int heapType, {required bool exact}) {
    if (heapType >= 0) {
      return false;
    }
    if (exact) {
      return heapType == _heapI31;
    }
    return heapType == _heapI31 || heapType == _heapEq || heapType == _heapAny;
  }

  bool _typedGcRefMatches(
    int actualTypeIndex,
    int targetHeapType, {
    required bool exact,
  }) {
    if (targetHeapType >= 0) {
      if (exact) {
        return actualTypeIndex == targetHeapType;
      }
      return _isTypeSubtype(actualTypeIndex, targetHeapType) ||
          _areTypesEquivalent(actualTypeIndex, targetHeapType, <String>{});
    }
    if (actualTypeIndex < 0 || actualTypeIndex >= _types.length) {
      return false;
    }
    final actualType = _types[actualTypeIndex];
    if (exact) {
      switch (targetHeapType) {
        case _heapStruct:
          return actualType.kind == WasmCompositeTypeKind.struct;
        case _heapArray:
          return actualType.kind == WasmCompositeTypeKind.array;
        default:
          return false;
      }
    }
    switch (targetHeapType) {
      case _heapAny:
        return actualType.kind == WasmCompositeTypeKind.struct ||
            actualType.kind == WasmCompositeTypeKind.array;
      case _heapEq:
        return actualType.kind == WasmCompositeTypeKind.struct ||
            actualType.kind == WasmCompositeTypeKind.array;
      case _heapStruct:
        return actualType.kind == WasmCompositeTypeKind.struct;
      case _heapArray:
        return actualType.kind == WasmCompositeTypeKind.array;
      default:
        return false;
    }
  }

  bool _externRefMatches(int heapType, {required bool exact}) {
    if (heapType >= 0 || exact) {
      return false;
    }
    return heapType == _heapExtern;
  }

  bool _isTypeSubtype(int subTypeIndex, int superTypeIndex) {
    if (subTypeIndex == superTypeIndex) {
      return true;
    }
    if (subTypeIndex < 0 ||
        subTypeIndex >= _types.length ||
        superTypeIndex < 0 ||
        superTypeIndex >= _types.length) {
      return false;
    }
    final visited = <int>{subTypeIndex};
    final pending = <int>[subTypeIndex];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (current == superTypeIndex ||
          _areTypesEquivalent(current, superTypeIndex, <String>{})) {
        return true;
      }
      for (final parent in _types[current].superTypeIndices) {
        if (parent == superTypeIndex ||
            _areTypesEquivalent(parent, superTypeIndex, <String>{})) {
          return true;
        }
        if (parent < 0 || parent >= _types.length) {
          continue;
        }
        if (visited.add(parent)) {
          pending.add(parent);
        }
      }
    }
    return false;
  }

  bool _areTypesEquivalent(int lhs, int rhs, Set<String> seenPairs) {
    if (lhs == rhs) {
      return true;
    }
    if (lhs < 0 || lhs >= _types.length || rhs < 0 || rhs >= _types.length) {
      return false;
    }
    final pairKey = lhs < rhs ? '$lhs:$rhs' : '$rhs:$lhs';
    if (!seenPairs.add(pairKey)) {
      return true;
    }
    final left = _types[lhs];
    final right = _types[rhs];
    if (left.kind != right.kind ||
        left.isFunctionType != right.isFunctionType) {
      return false;
    }
    if (left.superTypeIndices.length != right.superTypeIndices.length) {
      return false;
    }
    for (var i = 0; i < left.superTypeIndices.length; i++) {
      if (!_areTypesEquivalent(
        left.superTypeIndices[i],
        right.superTypeIndices[i],
        seenPairs,
      )) {
        return false;
      }
    }
    final leftDescriptor = left.descriptorTypeIndex;
    final rightDescriptor = right.descriptorTypeIndex;
    if ((leftDescriptor == null) != (rightDescriptor == null)) {
      return false;
    }
    if (leftDescriptor != null &&
        !_areTypesEquivalent(
          leftDescriptor,
          rightDescriptor!,
          seenPairs,
        )) {
      return false;
    }
    final leftDescribes = left.describesTypeIndex;
    final rightDescribes = right.describesTypeIndex;
    if ((leftDescribes == null) != (rightDescribes == null)) {
      return false;
    }
    if (leftDescribes != null &&
        !_areTypesEquivalent(
          leftDescribes,
          rightDescribes!,
          seenPairs,
        )) {
      return false;
    }
    if (left.isFunctionType) {
      if (left.paramTypeSignatures.length != right.paramTypeSignatures.length ||
          left.resultTypeSignatures.length !=
              right.resultTypeSignatures.length) {
        return false;
      }
      for (var i = 0; i < left.paramTypeSignatures.length; i++) {
        if (!_areValueTypeSignaturesEquivalent(
          left.paramTypeSignatures[i],
          right.paramTypeSignatures[i],
          seenPairs,
        )) {
          return false;
        }
      }
      for (var i = 0; i < left.resultTypeSignatures.length; i++) {
        if (!_areValueTypeSignaturesEquivalent(
          left.resultTypeSignatures[i],
          right.resultTypeSignatures[i],
          seenPairs,
        )) {
          return false;
        }
      }
      return true;
    }
    if (left.fieldSignatures.length != right.fieldSignatures.length) {
      return false;
    }
    for (var i = 0; i < left.fieldSignatures.length; i++) {
      final leftField = _parseFieldTypeForEquivalence(left.fieldSignatures[i]);
      final rightField = _parseFieldTypeForEquivalence(
        right.fieldSignatures[i],
      );
      if (leftField == null || rightField == null) {
        return false;
      }
      if (leftField.mutability != rightField.mutability ||
          !_areValueTypeSignaturesEquivalent(
            leftField.valueSignature,
            rightField.valueSignature,
            seenPairs,
          )) {
        return false;
      }
    }
    return true;
  }

  bool _areValueTypeSignaturesEquivalent(
    String lhs,
    String rhs,
    Set<String> seenPairs,
  ) {
    if (lhs == rhs) {
      return true;
    }
    final leftRef = _parseRefSignature(lhs);
    final rightRef = _parseRefSignature(rhs);
    if (leftRef == null || rightRef == null) {
      return false;
    }
    if (leftRef.nullable != rightRef.nullable ||
        leftRef.exact != rightRef.exact) {
      return false;
    }
    if (leftRef.heapType == rightRef.heapType) {
      return true;
    }
    if (leftRef.heapType >= 0 && rightRef.heapType >= 0) {
      return _areTypesEquivalent(
        leftRef.heapType,
        rightRef.heapType,
        seenPairs,
      );
    }
    return false;
  }

  ({String valueSignature, int mutability})? _parseFieldTypeForEquivalence(
    String signature,
  ) {
    final bytes = _signatureToBytes(signature);
    if (bytes.length < 2) {
      return null;
    }
    final mutability = bytes.last;
    if (mutability != 0 && mutability != 1) {
      return null;
    }
    return (
      valueSignature: _bytesToSignature(bytes.sublist(0, bytes.length - 1)),
      mutability: mutability,
    );
  }

  ({bool nullable, bool exact, int heapType})? _parseRefSignature(
    String signature,
  ) {
    final bytes = _signatureToBytes(signature);
    if (bytes.isEmpty) {
      return null;
    }
    if (bytes.length == 1) {
      final legacyHeap = _legacyHeapTypeFromRefTypeCode(bytes.single);
      if (legacyHeap != null) {
        return (nullable: true, exact: false, heapType: legacyHeap);
      }
      final decoded = _readSignedLeb33FromBytes(bytes, 0);
      if (decoded == null || decoded.$2 != bytes.length) {
        return null;
      }
      return (nullable: true, exact: false, heapType: decoded.$1);
    }
    if (bytes.length < 2) {
      return null;
    }
    final prefix = bytes[0];
    if (prefix != 0x63 && prefix != 0x64) {
      final decoded = _readSignedLeb33FromBytes(bytes, 0);
      if (decoded == null || decoded.$2 != bytes.length) {
        return null;
      }
      return (nullable: true, exact: false, heapType: decoded.$1);
    }
    var offset = 1;
    var exact = false;
    if (bytes[offset] == 0x62 || bytes[offset] == 0x61) {
      exact = bytes[offset] == 0x62;
      offset++;
      if (offset >= bytes.length) {
        return null;
      }
    }
    final decoded = _readSignedLeb33FromBytes(bytes, offset);
    if (decoded == null || decoded.$2 != bytes.length) {
      return null;
    }
    return (nullable: prefix == 0x63, exact: exact, heapType: decoded.$1);
  }

  (int, int)? _readSignedLeb33FromBytes(List<int> bytes, int offset) {
    if (offset >= bytes.length) {
      return null;
    }
    final firstByte = bytes[offset];
    var result = firstByte & 0x7f;
    var shift = 7;
    var byte = firstByte;
    var multiplier = 128;
    var index = offset + 1;
    while ((byte & 0x80) != 0) {
      if (index >= bytes.length) {
        return null;
      }
      byte = bytes[index++];
      result += (byte & 0x7f) * multiplier;
      multiplier *= 128;
      shift += 7;
      if (shift > 35) {
        return null;
      }
    }
    if (shift < 33 && (byte & 0x40) != 0) {
      result -= multiplier;
    }
    return (_normalizeSignedLeb33(result), index);
  }

  int _normalizeSignedLeb33(int value) {
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

  int? _legacyHeapTypeFromRefTypeCode(int code) {
    return switch (code & 0xff) {
      0x70 => _heapFunc,
      0x6f => _heapExtern,
      0x6e => _heapAny,
      0x6d => _heapEq,
      0x6b => _heapStruct,
      0x6a => _heapArray,
      0x69 => _heapI31,
      0x71 => _heapNone,
      0x72 => _heapNoextern,
      0x73 => _heapNofunc,
      _ => null,
    };
  }

  List<int> _signatureToBytes(String signature) {
    if (signature.isEmpty || signature.length.isOdd) {
      return const <int>[];
    }
    final bytes = <int>[];
    for (var i = 0; i < signature.length; i += 2) {
      bytes.add(int.parse(signature.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  String _bytesToSignature(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write((byte & 0xff).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static int _allocateSharedGcObject(_GcRefObject object) {
    final reference = -(_nextGcObjectId + 2);
    _nextGcObjectId++;
    _sharedGcObjects[reference] = object;
    return reference;
  }

  int _allocateGcObject(_GcRefObject object) {
    return _allocateSharedGcObject(object);
  }

  _GcRefObject _requireGcObject(int reference) {
    final cached = _sharedGcObjects[reference];
    if (cached != null) {
      return cached;
    }
    final constRef = decodeConstGcRef(reference);
    if (constRef != null && constRef.kind == constGcRefKindI31) {
      final materialized = _GcRefObject.i31(constRef.typeIndex & 0x7fffffff);
      _sharedGcObjects[reference] = materialized;
      return materialized;
    }
    throw StateError('Invalid GC reference: $reference');
  }

  void _gcStructNew(List<WasmValue> stack, Instruction instruction) {
    final typeIndex = _checkTypeIndex(instruction.immediate!);
    final type = _types[typeIndex];
    if (type.kind != WasmCompositeTypeKind.struct) {
      throw StateError('struct.new requires a struct type.');
    }
    if (type.descriptorTypeIndex != null) {
      throw StateError('type with descriptor requires descriptor allocation');
    }
    final fields = List<WasmValue>.filled(
      type.fieldSignatures.length,
      WasmValue.i32(0),
      growable: false,
    );
    for (var i = type.fieldSignatures.length - 1; i >= 0; i--) {
      fields[i] = _coerceFieldValue(type.fieldSignatures[i], _pop(stack));
    }
    _pushRef(
      stack,
      _allocateGcObject(
        _GcRefObject.struct(typeIndex: typeIndex, fields: fields),
      ),
    );
  }

  void _gcStructNewDefault(List<WasmValue> stack, Instruction instruction) {
    final typeIndex = _checkTypeIndex(instruction.immediate!);
    final type = _types[typeIndex];
    if (type.kind != WasmCompositeTypeKind.struct) {
      throw StateError('struct.new_default requires a struct type.');
    }
    if (type.descriptorTypeIndex != null) {
      throw StateError('type with descriptor requires descriptor allocation');
    }
    final fields = type.fieldSignatures
        .map(_defaultValueForFieldSignature)
        .toList(growable: false);
    _pushRef(
      stack,
      _allocateGcObject(
        _GcRefObject.struct(typeIndex: typeIndex, fields: fields),
      ),
    );
  }

  void _gcStructNewDesc(List<WasmValue> stack, Instruction instruction) {
    final typeIndex = _checkTypeIndex(instruction.immediate!);
    final type = _types[typeIndex];
    if (type.kind != WasmCompositeTypeKind.struct) {
      throw StateError('struct.new_desc requires a struct type.');
    }
    if (type.descriptorTypeIndex == null) {
      throw StateError('type without descriptor requires non-descriptor allocation');
    }
    final descriptor = _popRef(stack);
    if (descriptor == null) {
      throw StateError('null descriptor reference');
    }
    final fields = List<WasmValue>.filled(
      type.fieldSignatures.length,
      WasmValue.i32(0),
      growable: false,
    );
    for (var i = type.fieldSignatures.length - 1; i >= 0; i--) {
      fields[i] = _coerceFieldValue(type.fieldSignatures[i], _pop(stack));
    }
    _pushRef(
      stack,
      _allocateGcObject(
        _GcRefObject.struct(
          typeIndex: typeIndex,
          descriptorRef: descriptor,
          fields: fields,
        ),
      ),
    );
  }

  void _gcStructNewDefaultDesc(List<WasmValue> stack, Instruction instruction) {
    final typeIndex = _checkTypeIndex(instruction.immediate!);
    final type = _types[typeIndex];
    if (type.kind != WasmCompositeTypeKind.struct) {
      throw StateError('struct.new_default_desc requires a struct type.');
    }
    if (type.descriptorTypeIndex == null) {
      throw StateError('type without descriptor requires non-descriptor allocation');
    }
    final descriptor = _popRef(stack);
    if (descriptor == null) {
      throw StateError('null descriptor reference');
    }
    final fields = type.fieldSignatures
        .map(_defaultValueForFieldSignature)
        .toList(growable: false);
    _pushRef(
      stack,
      _allocateGcObject(
        _GcRefObject.struct(
          typeIndex: typeIndex,
          descriptorRef: descriptor,
          fields: fields,
        ),
      ),
    );
  }

  void _gcStructGet(
    List<WasmValue> stack,
    Instruction instruction, {
    required bool signed,
  }) {
    final expectedTypeIndex = _checkTypeIndex(instruction.immediate!);
    final fieldIndex = instruction.secondaryImmediate!;
    final reference = _popRef(stack);
    if (reference == null) {
      throw StateError('null reference');
    }
    final object = _requireGcObject(reference);
    if (object.kind != _GcRefKind.struct ||
        !_isTypeSubtype(object.typeIndex!, expectedTypeIndex)) {
      throw StateError('struct.get on incompatible reference.');
    }
    final fields = object.fields!;
    if (fieldIndex < 0 || fieldIndex >= fields.length) {
      throw StateError('Invalid struct field index: $fieldIndex');
    }
    final fieldSignature =
        _types[object.typeIndex!].fieldSignatures[fieldIndex];
    final value = fields[fieldIndex];
    stack.add(_coerceLoadedFieldValue(fieldSignature, value, signed: signed));
  }

  void _gcArrayNew(List<WasmValue> stack, Instruction instruction) {
    final typeIndex = _checkTypeIndex(instruction.immediate!);
    final type = _types[typeIndex];
    if (type.kind != WasmCompositeTypeKind.array) {
      throw StateError('array.new requires an array type.');
    }
    final length = _popLength(stack);
    final seed = _coerceFieldValue(type.fieldSignatures.single, _pop(stack));
    final elements = List<WasmValue>.generate(
      length,
      (_) => seed,
      growable: false,
    );
    _pushRef(
      stack,
      _allocateGcObject(
        _GcRefObject.array(typeIndex: typeIndex, elements: elements),
      ),
    );
  }

  void _gcArrayNewDefault(List<WasmValue> stack, Instruction instruction) {
    final typeIndex = _checkTypeIndex(instruction.immediate!);
    final type = _types[typeIndex];
    if (type.kind != WasmCompositeTypeKind.array) {
      throw StateError('array.new_default requires an array type.');
    }
    final length = _popLength(stack);
    final seed = _defaultValueForFieldSignature(type.fieldSignatures.single);
    final elements = List<WasmValue>.filled(length, seed, growable: false);
    _pushRef(
      stack,
      _allocateGcObject(
        _GcRefObject.array(typeIndex: typeIndex, elements: elements),
      ),
    );
  }

  void _gcArrayNewFixed(List<WasmValue> stack, Instruction instruction) {
    final typeIndex = _checkTypeIndex(instruction.immediate!);
    final type = _types[typeIndex];
    if (type.kind != WasmCompositeTypeKind.array) {
      throw StateError('array.new_fixed requires an array type.');
    }
    final length = instruction.secondaryImmediate!;
    if (length < 0) {
      throw StateError('Invalid array.new_fixed length: $length');
    }
    final elements = List<WasmValue>.filled(
      length,
      WasmValue.i32(0),
      growable: false,
    );
    for (var i = length - 1; i >= 0; i--) {
      elements[i] = _coerceFieldValue(type.fieldSignatures.single, _pop(stack));
    }
    _pushRef(
      stack,
      _allocateGcObject(
        _GcRefObject.array(typeIndex: typeIndex, elements: elements),
      ),
    );
  }

  void _gcArrayNewData(List<WasmValue> stack, Instruction instruction) {
    final typeIndex = _checkTypeIndex(instruction.immediate!);
    final dataIndex = _checkDataSegmentIndex(instruction.secondaryImmediate!);
    final type = _types[typeIndex];
    if (type.kind != WasmCompositeTypeKind.array) {
      throw StateError('array.new_data requires an array type.');
    }
    final fieldSignature = type.fieldSignatures.single;
    final fieldBytes = _fieldSignatureBytes(fieldSignature);
    final valueTypeCode = fieldBytes.first;

    final length = _popLength(stack);
    final sourceOffset = _popLength(stack);
    final data = _dataSegments[dataIndex];
    if (data == null) {
      if (length == 0) {
        _pushRef(
          stack,
          _allocateGcObject(
            _GcRefObject.array(typeIndex: typeIndex, elements: const []),
          ),
        );
        return;
      }
      throw StateError('out of bounds memory access');
    }

    final elements = _readNumericArrayElementsFromData(
      data: data,
      sourceOffset: sourceOffset,
      length: length,
      valueTypeCode: valueTypeCode,
    );
    _pushRef(
      stack,
      _allocateGcObject(
        _GcRefObject.array(typeIndex: typeIndex, elements: elements),
      ),
    );
  }

  void _gcArrayNewElem(List<WasmValue> stack, Instruction instruction) {
    final typeIndex = _checkTypeIndex(instruction.immediate!);
    final elementIndex = _checkElementSegmentIndex(instruction.secondaryImmediate!);
    final type = _types[typeIndex];
    if (type.kind != WasmCompositeTypeKind.array) {
      throw StateError('array.new_elem requires an array type.');
    }
    final fieldSignature = type.fieldSignatures.single;
    final valueSignature =
        _parseFieldTypeForEquivalence(fieldSignature)?.valueSignature;
    if (valueSignature == null || _parseRefSignature(valueSignature) == null) {
      throw StateError('type mismatch');
    }

    final length = _popLength(stack);
    final sourceOffset = _popLength(stack);
    final segmentValues = _sliceElementSegment(
      elementIndex: elementIndex,
      sourceOffset: sourceOffset,
      length: length,
    );
    final segmentRefTypeCode = _elementSegmentRefTypeCodes[elementIndex];
    final elements = List<WasmValue>.generate(
      length,
      (index) => _coerceArrayElementFromSegment(
        segmentRefTypeCode: segmentRefTypeCode,
        segmentValue: segmentValues[index],
      ),
      growable: false,
    );
    _pushRef(
      stack,
      _allocateGcObject(
        _GcRefObject.array(typeIndex: typeIndex, elements: elements),
      ),
    );
  }

  void _gcArrayInitData(List<WasmValue> stack, Instruction instruction) {
    final typeIndex = _checkTypeIndex(instruction.immediate!);
    final dataIndex = _checkDataSegmentIndex(instruction.secondaryImmediate!);
    final type = _types[typeIndex];
    if (type.kind != WasmCompositeTypeKind.array) {
      throw StateError('array.init_data requires an array type.');
    }
    final parsedField = _parseFieldTypeForEquivalence(type.fieldSignatures.single);
    if (parsedField == null || parsedField.mutability == 0) {
      throw StateError('immutable array');
    }
    final valueTypeBytes = _signatureToBytes(parsedField.valueSignature);
    if (valueTypeBytes.isEmpty) {
      throw StateError('type mismatch');
    }

    final length = _popLength(stack);
    final sourceOffset = _popLength(stack);
    final destinationOffset = _popLength(stack);
    final reference = _popRef(stack);
    if (reference == null) {
      throw StateError('null array reference');
    }
    final object = _requireGcObject(reference);
    if (object.kind != _GcRefKind.array ||
        !_isTypeSubtype(object.typeIndex!, typeIndex)) {
      throw StateError('array.init_data on incompatible reference.');
    }

    final elements = object.elements!;
    if (destinationOffset > elements.length ||
        length > elements.length - destinationOffset) {
      throw StateError('out of bounds array access');
    }

    final data = _dataSegments[dataIndex];
    if (data == null) {
      if (length == 0) {
        return;
      }
      throw StateError('out of bounds memory access');
    }
    final loaded = _readNumericArrayElementsFromData(
      data: data,
      sourceOffset: sourceOffset,
      length: length,
      valueTypeCode: valueTypeBytes.first,
    );
    for (var i = 0; i < length; i++) {
      elements[destinationOffset + i] = loaded[i];
    }
  }

  void _gcArrayInitElem(List<WasmValue> stack, Instruction instruction) {
    final typeIndex = _checkTypeIndex(instruction.immediate!);
    final elementIndex = _checkElementSegmentIndex(instruction.secondaryImmediate!);
    final type = _types[typeIndex];
    if (type.kind != WasmCompositeTypeKind.array) {
      throw StateError('array.init_elem requires an array type.');
    }
    final parsedField = _parseFieldTypeForEquivalence(type.fieldSignatures.single);
    if (parsedField == null || parsedField.mutability == 0) {
      throw StateError('immutable array');
    }
    if (_parseRefSignature(parsedField.valueSignature) == null) {
      throw StateError('type mismatch');
    }

    final length = _popLength(stack);
    final sourceOffset = _popLength(stack);
    final destinationOffset = _popLength(stack);
    final reference = _popRef(stack);
    if (reference == null) {
      throw StateError('null array reference');
    }
    final object = _requireGcObject(reference);
    if (object.kind != _GcRefKind.array ||
        !_isTypeSubtype(object.typeIndex!, typeIndex)) {
      throw StateError('array.init_elem on incompatible reference.');
    }
    final elements = object.elements!;
    if (destinationOffset > elements.length ||
        length > elements.length - destinationOffset) {
      throw StateError('out of bounds array access');
    }

    final segmentValues = _sliceElementSegment(
      elementIndex: elementIndex,
      sourceOffset: sourceOffset,
      length: length,
    );
    final segmentRefTypeCode = _elementSegmentRefTypeCodes[elementIndex];
    for (var i = 0; i < length; i++) {
      elements[destinationOffset + i] = _coerceArrayElementFromSegment(
        segmentRefTypeCode: segmentRefTypeCode,
        segmentValue: segmentValues[i],
      );
    }
  }

  void _gcArrayCopy(List<WasmValue> stack, Instruction instruction) {
    final destinationTypeIndex = _checkTypeIndex(instruction.immediate!);
    final sourceTypeIndex = _checkTypeIndex(instruction.secondaryImmediate!);

    final length = _popLength(stack);
    final sourceOffset = _popLength(stack);
    final sourceReference = _popRef(stack);
    final destinationOffset = _popLength(stack);
    final destinationReference = _popRef(stack);

    if (destinationReference == null || sourceReference == null) {
      throw StateError('null array reference');
    }

    final destinationObject = _requireGcObject(destinationReference);
    final sourceObject = _requireGcObject(sourceReference);
    if (destinationObject.kind != _GcRefKind.array ||
        !_isTypeSubtype(destinationObject.typeIndex!, destinationTypeIndex)) {
      throw StateError('array.copy destination type mismatch');
    }
    if (sourceObject.kind != _GcRefKind.array ||
        !_isTypeSubtype(sourceObject.typeIndex!, sourceTypeIndex)) {
      throw StateError('array.copy source type mismatch');
    }

    final destinationType = _types[destinationTypeIndex];
    final destinationField = _parseFieldTypeForEquivalence(
      destinationType.fieldSignatures.single,
    );
    if (destinationField == null || destinationField.mutability == 0) {
      throw StateError('immutable array');
    }

    final destinationElements = destinationObject.elements!;
    final sourceElements = sourceObject.elements!;
    if (destinationOffset > destinationElements.length ||
        length > destinationElements.length - destinationOffset ||
        sourceOffset > sourceElements.length ||
        length > sourceElements.length - sourceOffset) {
      throw StateError('out of bounds array access');
    }

    final copied = List<WasmValue>.from(
      sourceElements.sublist(sourceOffset, sourceOffset + length),
      growable: false,
    );
    for (var i = 0; i < length; i++) {
      destinationElements[destinationOffset + i] = _coerceFieldValue(
        destinationType.fieldSignatures.single,
        copied[i],
      );
    }
  }

  void _gcArrayFill(List<WasmValue> stack, Instruction instruction) {
    final typeIndex = _checkTypeIndex(instruction.immediate!);
    final type = _types[typeIndex];
    if (type.kind != WasmCompositeTypeKind.array) {
      throw StateError('array.fill requires an array type.');
    }
    final parsedField = _parseFieldTypeForEquivalence(type.fieldSignatures.single);
    if (parsedField == null || parsedField.mutability == 0) {
      throw StateError('immutable array');
    }

    final length = _popLength(stack);
    final fillValue = _coerceFieldValue(type.fieldSignatures.single, _pop(stack));
    final destinationOffset = _popLength(stack);
    final reference = _popRef(stack);
    if (reference == null) {
      throw StateError('null array reference');
    }
    final object = _requireGcObject(reference);
    if (object.kind != _GcRefKind.array ||
        !_isTypeSubtype(object.typeIndex!, typeIndex)) {
      throw StateError('array.fill on incompatible reference.');
    }
    final elements = object.elements!;
    if (destinationOffset > elements.length ||
        length > elements.length - destinationOffset) {
      throw StateError('out of bounds array access');
    }
    for (var i = 0; i < length; i++) {
      elements[destinationOffset + i] = fillValue;
    }
  }

  List<int?> _sliceElementSegment({
    required int elementIndex,
    required int sourceOffset,
    required int length,
  }) {
    final segment = _elementSegments[elementIndex];
    if (segment == null) {
      if (length == 0) {
        return const <int?>[];
      }
      throw StateError('out of bounds table access');
    }
    if (sourceOffset > segment.length || length > segment.length - sourceOffset) {
      throw StateError('out of bounds table access');
    }
    return List<int?>.from(
      segment.sublist(sourceOffset, sourceOffset + length),
      growable: false,
    );
  }

  List<WasmValue> _readNumericArrayElementsFromData({
    required Uint8List data,
    required int sourceOffset,
    required int length,
    required int valueTypeCode,
  }) {
    final elementSize = _numericArrayElementSize(valueTypeCode);
    final totalBytes = length * elementSize;
    if (sourceOffset > data.length || totalBytes > data.length - sourceOffset) {
      throw StateError('out of bounds memory access');
    }
    final view = ByteData.sublistView(data);
    return List<WasmValue>.generate(length, (index) {
      final byteOffset = sourceOffset + (index * elementSize);
      return _readNumericArrayElement(
        view: view,
        byteOffset: byteOffset,
        valueTypeCode: valueTypeCode,
      );
    }, growable: false);
  }

  WasmValue _coerceArrayElementFromSegment({
    required int segmentRefTypeCode,
    required int? segmentValue,
  }) {
    if (segmentValue == null) {
      return WasmValue.i32(_nullRef);
    }
    if (segmentRefTypeCode == 0x69 || segmentRefTypeCode == 0x6c) {
      if (segmentValue < 0) {
        return WasmValue.i32(segmentValue);
      }
      return WasmValue.i32(
        _allocateGcObject(_GcRefObject.i31(segmentValue & 0x7fffffff)),
      );
    }
    return WasmValue.i32(segmentValue);
  }

  int _numericArrayElementSize(int valueTypeCode) {
    return switch (valueTypeCode) {
      0x78 => 1, // i8
      0x77 => 2, // i16
      0x7f || 0x7d => 4, // i32/f32
      0x7e || 0x7c => 8, // i64/f64
      0x7b => 16, // v128
      _ => throw StateError('array type is not numeric or vector'),
    };
  }

  WasmValue _readNumericArrayElement({
    required ByteData view,
    required int byteOffset,
    required int valueTypeCode,
  }) {
    return switch (valueTypeCode) {
      0x78 => WasmValue.i32(view.getUint8(byteOffset)),
      0x77 => WasmValue.i32(view.getUint16(byteOffset, Endian.little)),
      0x7f => WasmValue.i32(view.getInt32(byteOffset, Endian.little)),
      0x7d => WasmValue.f32(view.getFloat32(byteOffset, Endian.little)),
      0x7e => WasmValue.i64(
        WasmI64.fromU32PairSigned(
          low: view.getUint32(byteOffset, Endian.little),
          high: view.getUint32(byteOffset + 4, Endian.little),
        ),
      ),
      0x7c => WasmValue.f64(view.getFloat64(byteOffset, Endian.little)),
      0x7b => throw UnsupportedError(
        'array data initialization for v128 is not supported yet.',
      ),
      _ => throw StateError('array type is not numeric or vector'),
    };
  }

  void _gcArrayGet(
    List<WasmValue> stack,
    Instruction instruction, {
    required bool signed,
  }) {
    final expectedTypeIndex = _checkTypeIndex(instruction.immediate!);
    final index = _popLength(stack);
    final reference = _popRef(stack);
    if (reference == null) {
      throw StateError('null reference');
    }
    final object = _requireGcObject(reference);
    if (object.kind != _GcRefKind.array ||
        !_isTypeSubtype(object.typeIndex!, expectedTypeIndex)) {
      throw StateError('array.get on incompatible reference.');
    }
    final elements = object.elements!;
    if (index < 0 || index >= elements.length) {
      throw RangeError('Array index out of bounds: $index');
    }
    final fieldSignature = _types[object.typeIndex!].fieldSignatures.single;
    stack.add(
      _coerceLoadedFieldValue(fieldSignature, elements[index], signed: signed),
    );
  }

  void _gcArraySet(List<WasmValue> stack, Instruction instruction) {
    final expectedTypeIndex = _checkTypeIndex(instruction.immediate!);
    final value = _pop(stack);
    final index = _popLength(stack);
    final reference = _popRef(stack);
    if (reference == null) {
      throw StateError('null array reference');
    }
    final object = _requireGcObject(reference);
    if (object.kind != _GcRefKind.array ||
        !_isTypeSubtype(object.typeIndex!, expectedTypeIndex)) {
      throw StateError('array.set on incompatible reference.');
    }
    final type = _types[object.typeIndex!];
    final parsedField = _parseFieldTypeForEquivalence(type.fieldSignatures.single);
    if (parsedField == null || parsedField.mutability == 0) {
      throw StateError('immutable array');
    }
    final elements = object.elements!;
    if (index < 0 || index >= elements.length) {
      throw StateError('out of bounds array access');
    }
    elements[index] = _coerceFieldValue(type.fieldSignatures.single, value);
  }

  void _gcArrayLen(List<WasmValue> stack) {
    final reference = _popRef(stack);
    if (reference == null) {
      throw StateError('null reference');
    }
    final object = _requireGcObject(reference);
    if (object.kind != _GcRefKind.array) {
      throw StateError('array.len expects an array reference.');
    }
    stack.add(WasmValue.i32(object.elements!.length));
  }

  void _gcAnyConvertExtern(List<WasmValue> stack) {
    final externReference = _popRef(stack);
    if (externReference == null) {
      _pushRef(stack, null);
      return;
    }
    _pushRef(stack, _allocateGcObject(_GcRefObject.extern(externReference)));
  }

  void _gcRefI31(List<WasmValue> stack) {
    final value = _popI32(stack) & 0x7fffffff;
    _pushRef(stack, _allocateGcObject(_GcRefObject.i31(value)));
  }

  void _gcI31Get(List<WasmValue> stack, {required bool signed}) {
    final reference = _popRef(stack);
    if (reference == null) {
      throw StateError('null reference');
    }
    final object = _requireGcObject(reference);
    if (object.kind != _GcRefKind.i31) {
      throw StateError('i31.get expects an i31 reference.');
    }
    final value = object.i31Value!;
    if (signed) {
      final signedValue = (value & 0x40000000) != 0
          ? value | ~0x7fffffff
          : value;
      stack.add(WasmValue.i32(signedValue));
    } else {
      stack.add(WasmValue.i32(value & 0x7fffffff));
    }
  }

  WasmValue _coerceFieldValue(String fieldSignature, WasmValue input) {
    final bytes = _fieldSignatureBytes(fieldSignature);
    final typeCode = bytes[0];
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

  WasmValue _coerceLoadedFieldValue(
    String fieldSignature,
    WasmValue value, {
    required bool signed,
  }) {
    final bytes = _fieldSignatureBytes(fieldSignature);
    final typeCode = bytes[0];
    if (typeCode == 0x78) {
      final raw = value.castTo(WasmValueType.i32).asI32() & 0xff;
      return WasmValue.i32(signed ? raw.toSigned(8) : raw);
    }
    if (typeCode == 0x77) {
      final raw = value.castTo(WasmValueType.i32).asI32() & 0xffff;
      return WasmValue.i32(signed ? raw.toSigned(16) : raw);
    }
    return value;
  }

  WasmValue _defaultValueForFieldSignature(String fieldSignature) {
    final bytes = _fieldSignatureBytes(fieldSignature);
    final typeCode = bytes[0];
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
        return WasmValue.i32(_nullRef);
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

  List<int> _fieldSignatureBytes(String fieldSignature) {
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

  bool _functionTypeMatchesByDepth({
    required int actualTypeIndex,
    required int targetTypeIndex,
    required bool exact,
    int? actualDepthOverride,
  }) {
    final actualType = _types[_checkTypeIndex(actualTypeIndex)];
    final targetType = _types[_checkTypeIndex(targetTypeIndex)];
    if (!actualType.isFunctionType || !targetType.isFunctionType) {
      return false;
    }
    if (!_functionTypeEquals(actualType, targetType)) {
      return false;
    }
    final actualDepth =
        actualDepthOverride ?? _typeDepth(actualTypeIndex, <int>{});
    final targetDepth = _typeDepth(targetTypeIndex, <int>{});
    if (exact) {
      return actualDepth == targetDepth;
    }
    return actualDepth >= targetDepth;
  }

  int _typeDepth(int typeIndex, Set<int> seen) {
    if (!seen.add(typeIndex)) {
      return 0;
    }
    final type = _types[_checkTypeIndex(typeIndex)];
    if (!type.isFunctionType || type.superTypeIndices.isEmpty) {
      return 0;
    }
    var maxDepth = 0;
    for (final superTypeIndex in type.superTypeIndices) {
      final depth = _typeDepth(superTypeIndex, seen);
      if (depth > maxDepth) {
        maxDepth = depth;
      }
    }
    return maxDepth + 1;
  }

  WasmValue _pop(List<WasmValue> stack) {
    if (stack.isEmpty) {
      throw StateError('Operand stack underflow.');
    }
    return stack.removeLast();
  }

  int _popI32(List<WasmValue> stack) =>
      _pop(stack).castTo(WasmValueType.i32).asI32();
  BigInt _popI64(List<WasmValue> stack) =>
      _pop(stack).castTo(WasmValueType.i64).asI64();
  double _popF32(List<WasmValue> stack) =>
      _pop(stack).castTo(WasmValueType.f32).asF32();
  double _popF64(List<WasmValue> stack) =>
      _pop(stack).castTo(WasmValueType.f64).asF64();

  int? _popRef(List<WasmValue> stack) {
    final raw = _popI32(stack);
    return raw == _nullRef ? null : raw;
  }

  void _pushRef(List<WasmValue> stack, int? value) {
    stack.add(WasmValue.i32(value ?? _nullRef));
  }

  int _addressFromStack(List<WasmValue> stack, Instruction instruction) {
    final memArg = instruction.memArg;
    if (memArg == null) {
      throw StateError('Missing memarg for opcode 0x${instruction.opcode}.');
    }
    final base = _popUnsignedMemoryOperand(
      stack,
      memoryIndex: memArg.memoryIndex,
    );
    final address = base + BigInt.from(memArg.offset);
    return _toLinearMemoryValue(address, label: 'memory address');
  }

  int _loadI8(List<WasmValue> stack, Instruction instruction) {
    final address = _addressFromStack(stack, instruction);
    return _memoryForMemArg(instruction).loadI8(address);
  }

  int _loadU8(List<WasmValue> stack, Instruction instruction) {
    final address = _addressFromStack(stack, instruction);
    return _memoryForMemArg(instruction).loadU8(address);
  }

  int _loadI16(List<WasmValue> stack, Instruction instruction) {
    final address = _addressFromStack(stack, instruction);
    return _memoryForMemArg(instruction).loadI16(address);
  }

  int _loadU16(List<WasmValue> stack, Instruction instruction) {
    final address = _addressFromStack(stack, instruction);
    return _memoryForMemArg(instruction).loadU16(address);
  }

  int _loadI32(List<WasmValue> stack, Instruction instruction) {
    final address = _addressFromStack(stack, instruction);
    return _memoryForMemArg(instruction).loadI32(address);
  }

  int _loadU32(List<WasmValue> stack, Instruction instruction) {
    final address = _addressFromStack(stack, instruction);
    return _memoryForMemArg(instruction).loadU32(address);
  }

  BigInt _loadI64(List<WasmValue> stack, Instruction instruction) {
    final address = _addressFromStack(stack, instruction);
    return _memoryForMemArg(instruction).loadI64(address);
  }

  double _loadF32(List<WasmValue> stack, Instruction instruction) {
    final address = _addressFromStack(stack, instruction);
    return _memoryForMemArg(instruction).loadF32(address);
  }

  double _loadF64(List<WasmValue> stack, Instruction instruction) {
    final address = _addressFromStack(stack, instruction);
    return _memoryForMemArg(instruction).loadF64(address);
  }

  void _storeI8(List<WasmValue> stack, Instruction instruction, int value) {
    final address = _addressFromStack(stack, instruction);
    _memoryForMemArg(instruction).storeI8(address, value);
  }

  void _storeI16(List<WasmValue> stack, Instruction instruction, int value) {
    final address = _addressFromStack(stack, instruction);
    _memoryForMemArg(instruction).storeI16(address, value);
  }

  void _storeI32(List<WasmValue> stack, Instruction instruction, int value) {
    final address = _addressFromStack(stack, instruction);
    _memoryForMemArg(instruction).storeI32(address, value);
  }

  void _storeI64(
    List<WasmValue> stack,
    Instruction instruction,
    BigInt value,
  ) {
    final address = _addressFromStack(stack, instruction);
    _memoryForMemArg(instruction).storeI64(address, value);
  }

  void _storeF32(List<WasmValue> stack, Instruction instruction, double value) {
    final address = _addressFromStack(stack, instruction);
    _memoryForMemArg(instruction).storeF32(address, value);
  }

  void _storeF64(List<WasmValue> stack, Instruction instruction, double value) {
    final address = _addressFromStack(stack, instruction);
    _memoryForMemArg(instruction).storeF64(address, value);
  }

  int _atomicAddressFromStack(
    List<WasmValue> stack,
    Instruction instruction, {
    required int widthBytes,
  }) {
    final address = _addressFromStack(stack, instruction);
    if (widthBytes > 1 && address % widthBytes != 0) {
      throw StateError('unaligned atomic');
    }
    return address;
  }

  int _atomicLoadU8(List<WasmValue> stack, Instruction instruction) {
    final address = _atomicAddressFromStack(stack, instruction, widthBytes: 1);
    return _memoryForMemArg(instruction).loadU8(address);
  }

  int _atomicLoadU16(List<WasmValue> stack, Instruction instruction) {
    final address = _atomicAddressFromStack(stack, instruction, widthBytes: 2);
    return _memoryForMemArg(instruction).loadU16(address);
  }

  int _atomicLoadU32(List<WasmValue> stack, Instruction instruction) {
    final address = _atomicAddressFromStack(stack, instruction, widthBytes: 4);
    return _memoryForMemArg(instruction).loadU32(address);
  }

  int _atomicLoadI32(List<WasmValue> stack, Instruction instruction) {
    final address = _atomicAddressFromStack(stack, instruction, widthBytes: 4);
    return _memoryForMemArg(instruction).loadI32(address);
  }

  BigInt _atomicLoadI64(List<WasmValue> stack, Instruction instruction) {
    final address = _atomicAddressFromStack(stack, instruction, widthBytes: 8);
    return _memoryForMemArg(instruction).loadI64(address);
  }

  void _atomicStoreI8(
    List<WasmValue> stack,
    Instruction instruction,
    int value,
  ) {
    final address = _atomicAddressFromStack(stack, instruction, widthBytes: 1);
    _memoryForMemArg(instruction).storeI8(address, value);
  }

  void _atomicStoreI16(
    List<WasmValue> stack,
    Instruction instruction,
    int value,
  ) {
    final address = _atomicAddressFromStack(stack, instruction, widthBytes: 2);
    _memoryForMemArg(instruction).storeI16(address, value);
  }

  void _atomicStoreI32(
    List<WasmValue> stack,
    Instruction instruction,
    int value,
  ) {
    final address = _atomicAddressFromStack(stack, instruction, widthBytes: 4);
    _memoryForMemArg(instruction).storeI32(address, value);
  }

  void _atomicStoreI64(
    List<WasmValue> stack,
    Instruction instruction,
    BigInt value,
  ) {
    final address = _atomicAddressFromStack(stack, instruction, widthBytes: 8);
    _memoryForMemArg(instruction).storeI64(address, value);
  }

  void _memoryAtomicNotify(List<WasmValue> stack, Instruction instruction) {
    _popI32(stack); // count
    final address = _atomicAddressFromStack(stack, instruction, widthBytes: 4);
    _memoryForMemArg(instruction).loadU32(address); // bounds check
    stack.add(WasmValue.i32(0));
  }

  void _memoryAtomicWait32(List<WasmValue> stack, Instruction instruction) {
    _popI64(stack); // timeout
    final expected = _toU32(_popI32(stack));
    final address = _atomicAddressFromStack(stack, instruction, widthBytes: 4);
    final actual = _memoryForMemArg(instruction).loadU32(address);
    stack.add(WasmValue.i32(actual == expected ? 2 : 1));
  }

  void _memoryAtomicWait64(List<WasmValue> stack, Instruction instruction) {
    _popI64(stack); // timeout
    final expected = _toU64(_popI64(stack));
    final address = _atomicAddressFromStack(stack, instruction, widthBytes: 8);
    final actual = _toU64(_memoryForMemArg(instruction).loadI64(address));
    stack.add(WasmValue.i32(actual == expected ? 2 : 1));
  }

  int _atomicRmwI32(
    List<WasmValue> stack,
    Instruction instruction,
    int Function(int current, int operand) operation,
  ) {
    final operand = _toU32(_popI32(stack));
    final address = _atomicAddressFromStack(stack, instruction, widthBytes: 4);
    final memory = _memoryForMemArg(instruction);
    final current = _toU32(memory.loadI32(address));
    final next = _toU32(operation(current, operand));
    memory.storeI32(address, next);
    return current;
  }

  BigInt _atomicRmwI64(
    List<WasmValue> stack,
    Instruction instruction,
    BigInt Function(BigInt current, BigInt operand) operation,
  ) {
    final operand = _toU64(_popI64(stack));
    final address = _atomicAddressFromStack(stack, instruction, widthBytes: 8);
    final memory = _memoryForMemArg(instruction);
    final current = _toU64(memory.loadI64(address));
    final next = _toU64(operation(current, operand));
    memory.storeI64(address, next);
    return current;
  }

  int _atomicRmwI32Narrow(
    List<WasmValue> stack,
    Instruction instruction, {
    required int widthBytes,
    required int Function(int current, int operand) operation,
  }) {
    final bits = widthBytes * 8;
    final operand = _popI32(stack).toUnsigned(bits);
    final address = _atomicAddressFromStack(
      stack,
      instruction,
      widthBytes: widthBytes,
    );
    final memory = _memoryForMemArg(instruction);
    final current = switch (widthBytes) {
      1 => memory.loadU8(address),
      2 => memory.loadU16(address),
      _ => throw StateError('Unsupported i32 atomic narrow width: $widthBytes'),
    };
    final next = operation(current, operand).toUnsigned(bits);
    switch (widthBytes) {
      case 1:
        memory.storeI8(address, next);
      case 2:
        memory.storeI16(address, next);
    }
    return current;
  }

  int _atomicRmwI64Narrow(
    List<WasmValue> stack,
    Instruction instruction, {
    required int widthBytes,
    required int Function(int current, int operand) operation,
  }) {
    final bits = widthBytes * 8;
    final operand =
        (_toU64(_popI64(stack)) & ((BigInt.one << bits) - BigInt.one)).toInt();
    final address = _atomicAddressFromStack(
      stack,
      instruction,
      widthBytes: widthBytes,
    );
    final memory = _memoryForMemArg(instruction);
    final current = switch (widthBytes) {
      1 => memory.loadU8(address),
      2 => memory.loadU16(address),
      4 => memory.loadU32(address),
      _ => throw StateError('Unsupported i64 atomic narrow width: $widthBytes'),
    };
    final next = operation(current, operand).toUnsigned(bits);
    switch (widthBytes) {
      case 1:
        memory.storeI8(address, next);
      case 2:
        memory.storeI16(address, next);
      case 4:
        memory.storeI32(address, next);
    }
    return current;
  }

  int _atomicCmpxchgI32(List<WasmValue> stack, Instruction instruction) {
    final replacement = _toU32(_popI32(stack));
    final expected = _toU32(_popI32(stack));
    final address = _atomicAddressFromStack(stack, instruction, widthBytes: 4);
    final memory = _memoryForMemArg(instruction);
    final current = _toU32(memory.loadI32(address));
    if (current == expected) {
      memory.storeI32(address, replacement);
    }
    return current;
  }

  BigInt _atomicCmpxchgI64(List<WasmValue> stack, Instruction instruction) {
    final replacement = _toU64(_popI64(stack));
    final expected = _toU64(_popI64(stack));
    final address = _atomicAddressFromStack(stack, instruction, widthBytes: 8);
    final memory = _memoryForMemArg(instruction);
    final current = _toU64(memory.loadI64(address));
    if (current == expected) {
      memory.storeI64(address, replacement);
    }
    return current;
  }

  int _atomicCmpxchgI32Narrow(
    List<WasmValue> stack,
    Instruction instruction, {
    required int widthBytes,
  }) {
    final bits = widthBytes * 8;
    final replacement = _popI32(stack).toUnsigned(bits);
    final expected = _popI32(stack).toUnsigned(bits);
    final address = _atomicAddressFromStack(
      stack,
      instruction,
      widthBytes: widthBytes,
    );
    final memory = _memoryForMemArg(instruction);
    final current = switch (widthBytes) {
      1 => memory.loadU8(address),
      2 => memory.loadU16(address),
      _ => throw StateError('Unsupported i32 atomic narrow width: $widthBytes'),
    };
    if (current == expected) {
      switch (widthBytes) {
        case 1:
          memory.storeI8(address, replacement);
        case 2:
          memory.storeI16(address, replacement);
      }
    }
    return current;
  }

  int _atomicCmpxchgI64Narrow(
    List<WasmValue> stack,
    Instruction instruction, {
    required int widthBytes,
  }) {
    final bits = widthBytes * 8;
    final replacement =
        (_toU64(_popI64(stack)) & ((BigInt.one << bits) - BigInt.one)).toInt();
    final expected =
        (_toU64(_popI64(stack)) & ((BigInt.one << bits) - BigInt.one)).toInt();
    final address = _atomicAddressFromStack(
      stack,
      instruction,
      widthBytes: widthBytes,
    );
    final memory = _memoryForMemArg(instruction);
    final current = switch (widthBytes) {
      1 => memory.loadU8(address),
      2 => memory.loadU16(address),
      4 => memory.loadU32(address),
      _ => throw StateError('Unsupported i64 atomic narrow width: $widthBytes'),
    };
    if (current == expected) {
      switch (widthBytes) {
        case 1:
          memory.storeI8(address, replacement);
        case 2:
          memory.storeI16(address, replacement);
        case 4:
          memory.storeI32(address, replacement);
      }
    }
    return current;
  }

  void _memoryInit(Instruction instruction, List<WasmValue> stack) {
    final dataIndex = _checkDataSegmentIndex(instruction.immediate!);
    final memoryIndex = instruction.secondaryImmediate!;
    final memory = _requireMemory(memoryIndex);

    final length = _popMemoryOperand(
      stack,
      memoryIndex: memoryIndex,
      label: 'memory.init length',
    );
    final sourceOffset = _popMemoryOperand(
      stack,
      memoryIndex: memoryIndex,
      label: 'memory.init source offset',
    );
    final destinationOffset = _popMemoryOperand(
      stack,
      memoryIndex: memoryIndex,
      label: 'memory.init destination offset',
    );

    final data = _dataSegments[dataIndex];
    if (data == null) {
      throw StateError('memory.init on dropped data segment $dataIndex.');
    }

    if (sourceOffset + length > data.length) {
      throw StateError('memory.init source out of bounds.');
    }

    final chunk = Uint8List.fromList(
      data.sublist(sourceOffset, sourceOffset + length),
    );
    memory.writeBytes(destinationOffset, chunk);
  }

  void _dataDrop(int dataIndex) {
    _dataSegments[_checkDataSegmentIndex(dataIndex)] = null;
  }

  void _memoryCopy(Instruction instruction, List<WasmValue> stack) {
    final destinationMemoryIndex = instruction.immediate!;
    final sourceMemoryIndex = instruction.secondaryImmediate!;
    final destinationMemory = _requireMemory(destinationMemoryIndex);
    final sourceMemory = _requireMemory(sourceMemoryIndex);
    final destinationMemory64 = _isMemory64(destinationMemoryIndex);
    final sourceMemory64 = _isMemory64(sourceMemoryIndex);
    if (destinationMemory64 != sourceMemory64) {
      throw StateError(
        'memory.copy source and destination memories must have matching '
        'index types.',
      );
    }

    final length = _popMemoryOperand(
      stack,
      memoryIndex: destinationMemoryIndex,
      label: 'memory.copy length',
    );
    final sourceOffset = _popMemoryOperand(
      stack,
      memoryIndex: sourceMemoryIndex,
      label: 'memory.copy source offset',
    );
    final destinationOffset = _popMemoryOperand(
      stack,
      memoryIndex: destinationMemoryIndex,
      label: 'memory.copy destination offset',
    );

    if (identical(destinationMemory, sourceMemory)) {
      destinationMemory.copyBytes(destinationOffset, sourceOffset, length);
      return;
    }

    final bytes = sourceMemory.readBytes(sourceOffset, length);
    destinationMemory.writeBytes(destinationOffset, bytes);
  }

  void _memoryFill(Instruction instruction, List<WasmValue> stack) {
    final memoryIndex = instruction.immediate!;
    final length = _popMemoryOperand(
      stack,
      memoryIndex: memoryIndex,
      label: 'memory.fill length',
    );
    final fillValue = _popI32(stack);
    final destinationOffset = _popMemoryOperand(
      stack,
      memoryIndex: memoryIndex,
      label: 'memory.fill destination offset',
    );

    _requireMemory(memoryIndex).fillBytes(destinationOffset, fillValue, length);
  }

  void _tableInit(Instruction instruction, List<WasmValue> stack) {
    final elementIndex = _checkElementSegmentIndex(instruction.immediate!);
    final tableIndex = _checkTableIndex(instruction.secondaryImmediate!);

    final length = _popLength(stack);
    final sourceOffset = _popLength(stack);
    final destinationOffset = _popLength(stack);

    final segment = _elementSegments[elementIndex];
    if (segment == null) {
      throw StateError('table.init on dropped element segment $elementIndex.');
    }

    if (sourceOffset + length > segment.length) {
      throw StateError('table.init source out of bounds.');
    }

    final table = _tables[tableIndex];
    table.initialize(
      destinationOffset,
      segment.sublist(sourceOffset, sourceOffset + length),
    );
  }

  void _elemDrop(int elementIndex) {
    _elementSegments[_checkElementSegmentIndex(elementIndex)] = null;
  }

  void _tableCopy(Instruction instruction, List<WasmValue> stack) {
    final destinationTableIndex = _checkTableIndex(instruction.immediate!);
    final sourceTableIndex = _checkTableIndex(instruction.secondaryImmediate!);

    final length = _popLength(stack);
    final sourceOffset = _popLength(stack);
    final destinationOffset = _popLength(stack);

    final sourceTable = _tables[sourceTableIndex];
    final destinationTable = _tables[destinationTableIndex];

    final temp = <int?>[];
    for (var i = 0; i < length; i++) {
      temp.add(sourceTable[sourceOffset + i]);
    }

    destinationTable.initialize(destinationOffset, temp);
  }

  void _tableGrow(Instruction instruction, List<WasmValue> stack) {
    final tableIndex = _checkTableIndex(instruction.immediate!);
    final delta = _popI32(stack);
    final value = _popRef(stack);

    if (delta < 0) {
      stack.add(WasmValue.i32(-1));
      return;
    }

    final previous = _tables[tableIndex].grow(delta, value);
    stack.add(WasmValue.i32(previous));
  }

  void _tableSize(Instruction instruction, List<WasmValue> stack) {
    final tableIndex = _checkTableIndex(instruction.immediate!);
    stack.add(WasmValue.i32(_tables[tableIndex].length));
  }

  void _tableFill(Instruction instruction, List<WasmValue> stack) {
    final tableIndex = _checkTableIndex(instruction.immediate!);
    final length = _popLength(stack);
    final value = _popRef(stack);
    final destinationOffset = _popLength(stack);

    final fillValues = List<int?>.filled(length, value);
    _tables[tableIndex].initialize(destinationOffset, fillValues);
  }

  void _i64Add128(List<WasmValue> stack) {
    final rhsHigh = _u64ToBigInt(_popI64(stack));
    final rhsLow = _u64ToBigInt(_popI64(stack));
    final lhsHigh = _u64ToBigInt(_popI64(stack));
    final lhsLow = _u64ToBigInt(_popI64(stack));

    final lhs = (lhsHigh << 64) | lhsLow;
    final rhs = (rhsHigh << 64) | rhsLow;
    _pushI128Result(stack, lhs + rhs);
  }

  void _i64Sub128(List<WasmValue> stack) {
    final rhsHigh = _u64ToBigInt(_popI64(stack));
    final rhsLow = _u64ToBigInt(_popI64(stack));
    final lhsHigh = _u64ToBigInt(_popI64(stack));
    final lhsLow = _u64ToBigInt(_popI64(stack));

    final lhs = (lhsHigh << 64) | lhsLow;
    final rhs = (rhsHigh << 64) | rhsLow;
    _pushI128Result(stack, lhs - rhs);
  }

  void _i64MulWideS(List<WasmValue> stack) {
    final rhs = _popI64(stack);
    final lhs = _popI64(stack);
    _pushI128Result(stack, lhs * rhs);
  }

  void _i64MulWideU(List<WasmValue> stack) {
    final rhs = _u64ToBigInt(_popI64(stack));
    final lhs = _u64ToBigInt(_popI64(stack));
    _pushI128Result(stack, lhs * rhs);
  }

  void _pushI128Result(List<WasmValue> stack, BigInt value) {
    final normalized = value & _u128BigMask;
    final low = _unsignedBigIntToSignedI64(normalized & _u64BigMask);
    final high = _unsignedBigIntToSignedI64((normalized >> 64) & _u64BigMask);
    stack
      ..add(WasmValue.i64(low))
      ..add(WasmValue.i64(high));
  }

  int _popLength(List<WasmValue> stack) {
    final value = _popI32(stack);
    if (value < 0) {
      throw StateError('Negative length in memory/table operation: $value');
    }
    return value;
  }

  int _toLinearMemoryValue(
    BigInt value, {
    required String label,
  }) {
    if (value < BigInt.zero) {
      throw RangeError('Negative $label: $value.');
    }
    final maxSupported = BigInt.from(wasmAddressSpaceBytes);
    if (value > maxSupported) {
      throw RangeError(
        '$label exceeds supported linear-memory range: '
        '$value > $wasmAddressSpaceBytes.',
      );
    }
    return value.toInt();
  }

  static int _toU32(int value) => value.toUnsigned(32);
  static BigInt _toU64(Object value) => WasmI64.unsigned(value);
  static BigInt _toSignedI64(Object value) => WasmI64.signed(value);
  static BigInt _u64ToBigInt(Object value) => WasmI64.unsigned(value);

  static BigInt _unsignedBigIntToSignedI64(BigInt value) =>
      WasmI64.signed(value);

  static int _i32Clz(int value) {
    final v = _toU32(value);
    if (v == 0) {
      return 32;
    }
    return 32 - v.bitLength;
  }

  static int _i32Ctz(int value) {
    var v = _toU32(value);
    if (v == 0) {
      return 32;
    }

    var count = 0;
    while ((v & 1) == 0) {
      count++;
      v >>= 1;
    }
    return count;
  }

  static int _i32Popcnt(int value) {
    var v = _toU32(value);
    var count = 0;
    while (v != 0) {
      v &= v - 1;
      count++;
    }
    return count;
  }

  static BigInt _i64Clz(BigInt value) {
    return WasmI64.clz(value);
  }

  static BigInt _i64Ctz(BigInt value) {
    return WasmI64.ctz(value);
  }

  static BigInt _i64Popcnt(BigInt value) {
    return WasmI64.popcnt(value);
  }

  static int _rotl32(int value, int shift) {
    if (shift == 0) {
      return value.toUnsigned(32);
    }
    return ((value << shift) | (value >> (32 - shift))).toUnsigned(32);
  }

  static int _rotr32(int value, int shift) {
    if (shift == 0) {
      return value.toUnsigned(32);
    }
    return ((value >> shift) | (value << (32 - shift))).toUnsigned(32);
  }

  static BigInt _rotl64(BigInt value, int shift) {
    return WasmI64.rotl(value, shift);
  }

  static BigInt _rotr64(BigInt value, int shift) {
    return WasmI64.rotr(value, shift);
  }

  static double _fMin(double a, double b) {
    if (a.isNaN || b.isNaN) {
      return double.nan;
    }
    if (a == 0.0 && b == 0.0) {
      if (a.isNegative || b.isNegative) {
        return -0.0;
      }
      return 0.0;
    }
    return a < b ? a : b;
  }

  static double _fMax(double a, double b) {
    if (a.isNaN || b.isNaN) {
      return double.nan;
    }
    if (a == 0.0 && b == 0.0) {
      if (!a.isNegative || !b.isNegative) {
        return 0.0;
      }
      return -0.0;
    }
    return a > b ? a : b;
  }

  static double _copySignF32(double magnitude, double sign) {
    final m = WasmValue.toF32Bits(magnitude);
    final s = WasmValue.toF32Bits(sign);
    final bits = (m & 0x7fffffff) | (s & 0x80000000);
    return WasmValue.fromF32Bits(bits);
  }

  static double _copySignF64(double magnitude, double sign) {
    final m = WasmValue.toF64Bits(magnitude);
    final s = WasmValue.toF64Bits(sign);
    final bits = WasmI64.or(
      WasmI64.and(m, _i64MagnitudeMask),
      WasmI64.and(s, _i64SignBitMask),
    );
    return WasmValue.fromF64Bits(bits);
  }

  static double _nearest(double value) {
    if (value.isNaN || value.isInfinite || value == 0.0) {
      return value;
    }

    final floor = value.floorToDouble();
    final delta = value - floor;

    if (delta < 0.5) {
      return floor;
    }
    if (delta > 0.5) {
      return floor + 1.0;
    }

    return floor.toInt().isEven ? floor : floor + 1.0;
  }

  static int _signExtend(int value, int bits) {
    final shift = 32 - bits;
    return (value << shift >> shift).toSigned(32);
  }

  static BigInt _signExtend64(BigInt value, int bits) {
    return WasmI64.signExtend(value, bits);
  }

  static int _truncToI32S(double value) {
    _assertFinite(value);
    if (value < _i32Min || value >= _i32MaxPlusOne) {
      throw StateError('i32.trunc_*_s overflow trap');
    }
    return value.truncate().toSigned(32);
  }

  static int _truncToI32U(double value) {
    _assertFinite(value);
    if (value < 0 || value >= _u32MaxPlusOne) {
      throw StateError('i32.trunc_*_u overflow trap');
    }
    return value.truncate().toUnsigned(32).toSigned(32);
  }

  static BigInt _truncToI64S(double value) {
    _assertFinite(value);
    if (value < _i64Min || value >= _i64MaxPlusOne) {
      throw StateError('i64.trunc_*_s overflow trap');
    }
    return WasmI64.signed(value.truncate());
  }

  static BigInt _truncToI64U(double value) {
    _assertFinite(value);
    if (value < 0 || value >= _u64MaxPlusOne) {
      throw StateError('i64.trunc_*_u overflow trap');
    }
    return WasmI64.unsigned(value.truncate());
  }

  static int _truncSatToI32S(double value) {
    if (value.isNaN) {
      return 0;
    }
    if (value <= _i32Min) {
      return _i32Min.toInt();
    }
    if (value >= _i32Max) {
      return 0x7fffffff;
    }
    return value.truncate().toSigned(32);
  }

  static int _truncSatToI32U(double value) {
    if (value.isNaN || value <= 0) {
      return 0;
    }
    if (value >= _u32Max) {
      return 0xffffffff.toSigned(32);
    }
    return value.truncate().toUnsigned(32).toSigned(32);
  }

  static BigInt _truncSatToI64S(double value) {
    if (value.isNaN) {
      return BigInt.zero;
    }
    if (value <= _i64Min) {
      return _i64MinValue;
    }
    if (value >= _i64Max) {
      return _i64MaxValue;
    }
    return WasmI64.signed(value.truncate());
  }

  static BigInt _truncSatToI64U(double value) {
    if (value.isNaN || value <= 0) {
      return BigInt.zero;
    }
    if (value >= _u64Max) {
      return _u64Mask;
    }
    return WasmI64.unsigned(value.truncate());
  }

  static void _assertFinite(double value) {
    if (value.isNaN || value.isInfinite) {
      throw StateError('Invalid conversion trap: NaN or infinite value');
    }
  }

  static final BigInt _i64MinValue = WasmI64.minSigned;
  static final BigInt _i64MaxValue = WasmI64.maxSigned;
  static final BigInt _i64MagnitudeMask = WasmI64.magnitudeMask;
  static final BigInt _i64SignBitMask = WasmI64.signBitMask;
  static final BigInt _u64Mask = WasmI64.allOnesMask;
  static final BigInt _u64BigMod = BigInt.one << 64;
  static final BigInt _u64BigMask = _u64BigMod - BigInt.one;
  static final BigInt _u128BigMask = (BigInt.one << 128) - BigInt.one;

  static const double _i32Min = -2147483648.0;
  static const double _i32Max = 2147483647.0;
  static const double _i32MaxPlusOne = 2147483648.0;

  static const double _u32Max = 4294967295.0;
  static const double _u32MaxPlusOne = 4294967296.0;

  static const double _i64Min = -9223372036854775808.0;
  static const double _i64Max = 9223372036854775807.0;
  static const double _i64MaxPlusOne = 9223372036854775808.0;

  static const double _u64Max = 18446744073709551615.0;
  static const double _u64MaxPlusOne = 18446744073709551616.0;
}
