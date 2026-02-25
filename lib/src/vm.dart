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

final class WasmVm {
  WasmVm({
    required List<RuntimeFunction> functions,
    required List<WasmFunctionType> types,
    required List<WasmTable> tables,
    required WasmMemory? memory,
    required List<RuntimeGlobal> globals,
    required List<Uint8List?> dataSegments,
    required List<List<int?>?> elementSegments,
    this.maxCallDepth = 1024,
  }) : _functions = functions,
       _types = types,
       _tables = tables,
       _memory = memory,
       _globals = globals,
       _dataSegments = dataSegments,
       _elementSegments = elementSegments;

  final List<RuntimeFunction> _functions;
  final List<WasmFunctionType> _types;
  final List<WasmTable> _tables;
  final WasmMemory? _memory;
  final List<RuntimeGlobal> _globals;
  final List<Uint8List?> _dataSegments;
  final List<List<int?>?> _elementSegments;
  final int maxCallDepth;

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
          _pushFuncRef(stack, _tables[tableIndex][elementIndex]);
          pc++;

        case Opcodes.tableSet:
          final tableIndex = _checkTableIndex(instruction.immediate!);
          final value = _popFuncRef(stack);
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
          _storeI8(stack, instruction, _popI64(stack));
          pc++;

        case Opcodes.i64Store16:
          _storeI16(stack, instruction, _popI64(stack));
          pc++;

        case Opcodes.i64Store32:
          _storeI32(stack, instruction, _popI64(stack));
          pc++;

        case Opcodes.memorySize:
          _requireMemoryIndexZero(instruction.immediate!);
          stack.add(WasmValue.i32(_requireMemory().pageCount));
          pc++;

        case Opcodes.memoryGrow:
          _requireMemoryIndexZero(instruction.immediate!);
          final deltaPages = _popI32(stack);
          if (deltaPages < 0) {
            stack.add(WasmValue.i32(-1));
          } else {
            stack.add(WasmValue.i32(_requireMemory().grow(deltaPages)));
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
          stack.add(WasmValue.i32(-1));
          pc++;

        case Opcodes.refFunc:
          final functionRef = _checkFunctionIndex(instruction.immediate!);
          stack.add(WasmValue.i32(functionRef));
          pc++;

        case Opcodes.refIsNull:
          stack.add(WasmValue.i32(_popFuncRef(stack) == null ? 1 : 0));
          pc++;

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
          stack.add(WasmValue.i32(_popI64(stack) == 0 ? 1 : 0));
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
          stack.add(WasmValue.i32(lhs < rhs ? 1 : 0));
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
          stack.add(WasmValue.i32(lhs > rhs ? 1 : 0));
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
          stack.add(WasmValue.i32(lhs <= rhs ? 1 : 0));
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
          stack.add(WasmValue.i32(lhs >= rhs ? 1 : 0));
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
          if (rhs == 0) {
            throw StateError('i64.div_s division by zero trap');
          }
          if (lhs == _i64MinValue && rhs == -1) {
            throw StateError('i64.div_s overflow trap');
          }
          stack.add(WasmValue.i64(WasmI64.divS(lhs, rhs)));
          pc++;

        case Opcodes.i64DivU:
          final rhs = _popI64(stack);
          final lhs = _popI64(stack);
          if (rhs == 0) {
            throw StateError('i64.div_u division by zero trap');
          }
          stack.add(WasmValue.i64(WasmI64.divU(lhs, rhs)));
          pc++;

        case Opcodes.i64RemS:
          final rhs = _popI64(stack);
          final lhs = _popI64(stack);
          if (rhs == 0) {
            throw StateError('i64.rem_s division by zero trap');
          }
          stack.add(WasmValue.i64(WasmI64.remS(lhs, rhs)));
          pc++;

        case Opcodes.i64RemU:
          final rhs = _popI64(stack);
          final lhs = _popI64(stack);
          if (rhs == 0) {
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
          final rhs = _popI64(stack) & 63;
          stack.add(WasmValue.i64(WasmI64.shl(_popI64(stack), rhs)));
          pc++;

        case Opcodes.i64ShrS:
          final rhs = _popI64(stack) & 63;
          stack.add(WasmValue.i64(WasmI64.shrS(_popI64(stack), rhs)));
          pc++;

        case Opcodes.i64ShrU:
          final rhs = _popI64(stack) & 63;
          stack.add(WasmValue.i64(WasmI64.shrU(_popI64(stack), rhs)));
          pc++;

        case Opcodes.i64Rotl:
          final rhs = _popI64(stack) & 63;
          stack.add(WasmValue.i64(_rotl64(_popI64(stack), rhs)));
          pc++;

        case Opcodes.i64Rotr:
          final rhs = _popI64(stack) & 63;
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
          stack.add(WasmValue.i32(_popI64(stack)));
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

  WasmMemory _requireMemory() {
    if (_memory == null) {
      throw StateError('Module has no memory.');
    }
    return _memory;
  }

  int _requireJumpIndex(int? index, String context) {
    if (index == null) {
      throw StateError('Missing jump index for `$context`.');
    }
    return index;
  }

  void _requireMemoryIndexZero(int memoryIndex) {
    if (memoryIndex != 0) {
      throw UnsupportedError('Only memory index 0 is supported.');
    }
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

  WasmValue _pop(List<WasmValue> stack) {
    if (stack.isEmpty) {
      throw StateError('Operand stack underflow.');
    }
    return stack.removeLast();
  }

  int _popI32(List<WasmValue> stack) =>
      _pop(stack).castTo(WasmValueType.i32).asI32();
  int _popI64(List<WasmValue> stack) =>
      _pop(stack).castTo(WasmValueType.i64).asI64();
  double _popF32(List<WasmValue> stack) =>
      _pop(stack).castTo(WasmValueType.f32).asF32();
  double _popF64(List<WasmValue> stack) =>
      _pop(stack).castTo(WasmValueType.f64).asF64();

  int? _popFuncRef(List<WasmValue> stack) {
    final raw = _popI32(stack);
    return raw == -1 ? null : _checkFunctionIndex(raw);
  }

  void _pushFuncRef(List<WasmValue> stack, int? functionIndex) {
    stack.add(WasmValue.i32(functionIndex ?? -1));
  }

  int _addressFromStack(List<WasmValue> stack, int offset) {
    return _toAddress(_popI32(stack) + offset);
  }

  int _loadI8(List<WasmValue> stack, Instruction instruction) {
    final address = _addressFromStack(stack, instruction.memArg!.offset);
    return _requireMemory().loadI8(address);
  }

  int _loadU8(List<WasmValue> stack, Instruction instruction) {
    final address = _addressFromStack(stack, instruction.memArg!.offset);
    return _requireMemory().loadU8(address);
  }

  int _loadI16(List<WasmValue> stack, Instruction instruction) {
    final address = _addressFromStack(stack, instruction.memArg!.offset);
    return _requireMemory().loadI16(address);
  }

  int _loadU16(List<WasmValue> stack, Instruction instruction) {
    final address = _addressFromStack(stack, instruction.memArg!.offset);
    return _requireMemory().loadU16(address);
  }

  int _loadI32(List<WasmValue> stack, Instruction instruction) {
    final address = _addressFromStack(stack, instruction.memArg!.offset);
    return _requireMemory().loadI32(address);
  }

  int _loadU32(List<WasmValue> stack, Instruction instruction) {
    final address = _addressFromStack(stack, instruction.memArg!.offset);
    return _requireMemory().loadU32(address);
  }

  int _loadI64(List<WasmValue> stack, Instruction instruction) {
    final address = _addressFromStack(stack, instruction.memArg!.offset);
    return _requireMemory().loadI64(address);
  }

  double _loadF32(List<WasmValue> stack, Instruction instruction) {
    final address = _addressFromStack(stack, instruction.memArg!.offset);
    return _requireMemory().loadF32(address);
  }

  double _loadF64(List<WasmValue> stack, Instruction instruction) {
    final address = _addressFromStack(stack, instruction.memArg!.offset);
    return _requireMemory().loadF64(address);
  }

  void _storeI8(List<WasmValue> stack, Instruction instruction, int value) {
    final address = _addressFromStack(stack, instruction.memArg!.offset);
    _requireMemory().storeI8(address, value);
  }

  void _storeI16(List<WasmValue> stack, Instruction instruction, int value) {
    final address = _addressFromStack(stack, instruction.memArg!.offset);
    _requireMemory().storeI16(address, value);
  }

  void _storeI32(List<WasmValue> stack, Instruction instruction, int value) {
    final address = _addressFromStack(stack, instruction.memArg!.offset);
    _requireMemory().storeI32(address, value);
  }

  void _storeI64(List<WasmValue> stack, Instruction instruction, int value) {
    final address = _addressFromStack(stack, instruction.memArg!.offset);
    _requireMemory().storeI64(address, value);
  }

  void _storeF32(List<WasmValue> stack, Instruction instruction, double value) {
    final address = _addressFromStack(stack, instruction.memArg!.offset);
    _requireMemory().storeF32(address, value);
  }

  void _storeF64(List<WasmValue> stack, Instruction instruction, double value) {
    final address = _addressFromStack(stack, instruction.memArg!.offset);
    _requireMemory().storeF64(address, value);
  }

  void _memoryInit(Instruction instruction, List<WasmValue> stack) {
    final dataIndex = _checkDataSegmentIndex(instruction.immediate!);
    _requireMemoryIndexZero(instruction.secondaryImmediate!);

    final length = _popLength(stack);
    final sourceOffset = _popLength(stack);
    final destinationOffset = _popLength(stack);

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
    _requireMemory().writeBytes(destinationOffset, chunk);
  }

  void _dataDrop(int dataIndex) {
    _dataSegments[_checkDataSegmentIndex(dataIndex)] = null;
  }

  void _memoryCopy(Instruction instruction, List<WasmValue> stack) {
    _requireMemoryIndexZero(instruction.immediate!);
    _requireMemoryIndexZero(instruction.secondaryImmediate!);

    final length = _popLength(stack);
    final sourceOffset = _popLength(stack);
    final destinationOffset = _popLength(stack);

    _requireMemory().copyBytes(destinationOffset, sourceOffset, length);
  }

  void _memoryFill(Instruction instruction, List<WasmValue> stack) {
    _requireMemoryIndexZero(instruction.immediate!);

    final length = _popLength(stack);
    final fillValue = _popI32(stack);
    final destinationOffset = _popLength(stack);

    _requireMemory().fillBytes(destinationOffset, fillValue, length);
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
    final value = _popFuncRef(stack);

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
    final value = _popFuncRef(stack);
    final destinationOffset = _popLength(stack);

    final fillValues = List<int?>.filled(length, value);
    _tables[tableIndex].initialize(destinationOffset, fillValues);
  }

  int _popLength(List<WasmValue> stack) {
    final value = _popI32(stack);
    if (value < 0) {
      throw StateError('Negative length in memory/table operation: $value');
    }
    return value;
  }

  int _toAddress(int value) {
    if (value < 0) {
      throw RangeError('Negative memory address: $value.');
    }
    return value;
  }

  static int _toU32(int value) => value.toUnsigned(32);
  static int _toU64(int value) => WasmI64.unsigned(value);
  static int _toSignedI64(int value) => WasmI64.signed(value);

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

  static int _i64Clz(int value) {
    return WasmI64.clz(value);
  }

  static int _i64Ctz(int value) {
    return WasmI64.ctz(value);
  }

  static int _i64Popcnt(int value) {
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

  static int _rotl64(int value, int shift) {
    return WasmI64.rotl(value, shift);
  }

  static int _rotr64(int value, int shift) {
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

  static int _signExtend64(int value, int bits) {
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

  static int _truncToI64S(double value) {
    _assertFinite(value);
    if (value < _i64Min || value >= _i64MaxPlusOne) {
      throw StateError('i64.trunc_*_s overflow trap');
    }
    return WasmI64.signed(value.truncate());
  }

  static int _truncToI64U(double value) {
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

  static int _truncSatToI64S(double value) {
    if (value.isNaN) {
      return 0;
    }
    if (value <= _i64Min) {
      return _i64MinValue;
    }
    if (value >= _i64Max) {
      return _i64MaxValue;
    }
    return WasmI64.signed(value.truncate());
  }

  static int _truncSatToI64U(double value) {
    if (value.isNaN || value <= 0) {
      return 0;
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

  static final int _i64MinValue = WasmI64.minSigned;
  static final int _i64MaxValue = WasmI64.maxSigned;
  static final int _i64MagnitudeMask = WasmI64.magnitudeMask;
  static final int _i64SignBitMask = WasmI64.signBitMask;
  static final int _u64Mask = WasmI64.allOnesMask;

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
