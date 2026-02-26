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
    this.tryTableCatches,
  });

  final _LabelKind kind;
  final int stackHeight;
  final List<WasmValueType> branchTypes;
  final List<WasmValueType> endTypes;
  final int endIndex;
  final int loopStartIndex;
  final List<TryTableCatchClause>? tryTableCatches;
}

enum _GcRefKind { i31, struct, array, extern, anyExtern }

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
       fields = List<WasmValue>.from(fields),
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

  _GcRefObject.anyExtern(this.externValue)
    : kind = _GcRefKind.anyExtern,
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

final class _FunctionRefTarget {
  const _FunctionRefTarget({required this.vm, required this.functionIndex});

  final WasmVm vm;
  final int functionIndex;

  RuntimeFunction get function => vm._functions[functionIndex];
}

final class _ExceptionObject {
  const _ExceptionObject({required this.nominalTypeKey, required this.values});

  final String nominalTypeKey;
  final List<WasmValue> values;
}

final class _WasmThrownException implements Exception {
  const _WasmThrownException(this.exceptionRef);

  final int exceptionRef;
}

final class WasmVm {
  WasmVm({
    required List<RuntimeFunction> functions,
    required List<WasmFunctionType> types,
    required List<WasmFunctionType> tagTypes,
    required List<String> tagNominalTypeKeys,
    required List<WasmTable> tables,
    required List<WasmMemory> memories,
    required List<RuntimeGlobal> globals,
    required int functionRefNamespace,
    required List<bool> memory64ByIndex,
    required List<bool> table64ByIndex,
    required List<Uint8List?> dataSegments,
    required List<List<int?>?> elementSegments,
    required List<int> elementSegmentRefTypeCodes,
    this.maxCallDepth = 1024,
  }) : _functions = functions,
       _types = types,
       _tagTypes = tagTypes,
       _tagNominalTypeKeys = tagNominalTypeKeys,
       _tables = tables,
       _memories = memories,
       _globals = globals,
       _functionRefNamespace = functionRefNamespace,
       _memory64ByIndex = memory64ByIndex,
       _table64ByIndex = table64ByIndex,
       _dataSegments = dataSegments,
       _elementSegments = elementSegments,
       _elementSegmentRefTypeCodes = elementSegmentRefTypeCodes {
    if (_memory64ByIndex.length != _memories.length) {
      throw ArgumentError(
        'memory64ByIndex length ${_memory64ByIndex.length} does not match '
        'memory count ${_memories.length}.',
      );
    }
    if (_table64ByIndex.length != _tables.length) {
      throw ArgumentError(
        'table64ByIndex length ${_table64ByIndex.length} does not match '
        'table count ${_tables.length}.',
      );
    }
    if (_tagTypes.length != _tagNominalTypeKeys.length) {
      throw ArgumentError(
        'tagTypes length ${_tagTypes.length} does not match '
        'tagNominalTypeKeys length ${_tagNominalTypeKeys.length}.',
      );
    }
    if (_elementSegmentRefTypeCodes.length != _elementSegments.length) {
      throw ArgumentError(
        'elementSegmentRefTypeCodes length ${_elementSegmentRefTypeCodes.length} '
        'does not match element segment count ${_elementSegments.length}.',
      );
    }
    for (var i = 0; i < _functions.length; i++) {
      final ref = functionRefIdFor(
        namespace: _functionRefNamespace,
        functionIndex: i,
      );
      _functionRefTargets[ref] = _FunctionRefTarget(vm: this, functionIndex: i);
    }
  }

  final List<RuntimeFunction> _functions;
  final List<WasmFunctionType> _types;
  final List<WasmFunctionType> _tagTypes;
  final List<String> _tagNominalTypeKeys;
  final List<WasmTable> _tables;
  final List<WasmMemory> _memories;
  final List<RuntimeGlobal> _globals;
  final int _functionRefNamespace;
  final List<bool> _memory64ByIndex;
  final List<bool> _table64ByIndex;
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
  static int _nextFunctionRefNamespace = 1;
  static int _nextFunctionRefId = 0x40000000;
  static int _nextV128Value = 0x10000000;
  static final Map<String, int> _v128ValueByBytes = <String, int>{};
  static final Map<int, Uint8List> _v128BytesByValue = <int, Uint8List>{};
  static final Map<int, ({int kind, int typeIndex, int? descriptorRef})>
  _constGcRefs = <int, ({int kind, int typeIndex, int? descriptorRef})>{};
  static final Map<String, int> _functionRefIdsByKey = <String, int>{};
  static final Map<int, _FunctionRefTarget> _functionRefTargets =
      <int, _FunctionRefTarget>{};
  static int _nextExceptionRef = 0x20000000;
  static final Map<int, _ExceptionObject> _exceptionObjects =
      <int, _ExceptionObject>{};
  static int _nextGcObjectId = 0;
  static final Map<int, _GcRefObject> _sharedGcObjects = <int, _GcRefObject>{};
  static final Map<int, int> _sharedI31Refs = <int, int>{};
  static final BigInt _u32MaskBigInt = BigInt.from(0xffffffff);
  static final BigInt _u64MaskBigInt = (BigInt.one << 64) - BigInt.one;

  static int allocateFunctionRefNamespace() => _nextFunctionRefNamespace++;

  static int functionRefIdFor({
    required int namespace,
    required int functionIndex,
  }) {
    if (namespace <= 0) {
      throw RangeError.value(namespace, 'namespace', 'must be > 0');
    }
    if (functionIndex < 0) {
      throw RangeError.value(functionIndex, 'functionIndex', 'must be >= 0');
    }
    final key = '$namespace:$functionIndex';
    final existing = _functionRefIdsByKey[key];
    if (existing != null) {
      return existing;
    }
    if (_nextFunctionRefId > 0x7fffffff) {
      throw StateError('Function reference id space exhausted.');
    }
    final allocated = _nextFunctionRefId++;
    _functionRefIdsByKey[key] = allocated;
    return allocated;
  }

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
    return _canonicalI31Ref(value);
  }

  static int _canonicalI31Ref(int value) {
    final normalized = value & 0x7fffffff;
    return _sharedI31Refs.putIfAbsent(
      normalized,
      () => _allocateSharedGcObject(_GcRefObject.i31(normalized)),
    );
  }

  int _checkTagIndex(int index) => _checkIndex(index, _tagTypes.length, 'tag');

  static int internV128Bytes(Uint8List bytes) {
    if (bytes.lengthInBytes != 16) {
      throw ArgumentError.value(bytes.lengthInBytes, 'bytes.lengthInBytes');
    }
    final key = _v128BytesKey(bytes);
    final existing = _v128ValueByBytes[key];
    if (existing != null) {
      return existing;
    }
    if (_nextV128Value > 0x7fffffff) {
      throw StateError('v128 value id space exhausted.');
    }
    final value = _nextV128Value++;
    _v128ValueByBytes[key] = value;
    _v128BytesByValue[value] = Uint8List.fromList(bytes);
    return value;
  }

  static Uint8List? v128BytesForValue(int value) {
    final bytes = _v128BytesByValue[value];
    if (bytes == null) {
      return null;
    }
    return Uint8List.fromList(bytes);
  }

  static String _v128BytesKey(Uint8List bytes) {
    return bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  int _internV128(Uint8List bytes) {
    return internV128Bytes(bytes);
  }

  int _allocateExceptionRef(_ExceptionObject exception) {
    final ref = _nextExceptionRef++;
    _exceptionObjects[ref] = exception;
    return ref;
  }

  _ExceptionObject _requireExceptionObject(int reference) {
    final exception = _exceptionObjects[reference];
    if (exception == null) {
      throw StateError('throw_ref to non-exception reference.');
    }
    return exception;
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

    var currentFunctionIndex = functionIndex;
    var currentArgs = args;

    executionLoop:
    while (true) {
      _checkFunctionIndex(currentFunctionIndex);
      final function = _functions[currentFunctionIndex];

      if (currentArgs.length != function.type.params.length) {
        throw ArgumentError(
          'Function index $currentFunctionIndex expects '
          '${function.type.params.length} args, got ${currentArgs.length}.',
        );
      }

      final normalizedArgs = _normalizeValues(
        currentArgs,
        function.type.params,
      );

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

        try {
          switch (instruction.opcode) {
            case Opcodes.unreachable:
              throw StateError('unreachable trap');

            case Opcodes.nop:
              pc++;

            case Opcodes.block:
              final paramTypes = instruction.blockParameterTypes ?? const [];
              final entryStackHeight = _consumeBlockParameters(
                stack,
                paramTypes,
                context: 'block',
              );
              labels.add(
                _LabelFrame(
                  kind: _LabelKind.block,
                  stackHeight: entryStackHeight,
                  branchTypes: instruction.blockResultTypes ?? const [],
                  endTypes: instruction.blockResultTypes ?? const [],
                  endIndex: _requireJumpIndex(instruction.endIndex, 'block'),
                  loopStartIndex: -1,
                ),
              );
              pc++;

            case Opcodes.loop:
              final paramTypes = instruction.blockParameterTypes ?? const [];
              final entryStackHeight = _consumeBlockParameters(
                stack,
                paramTypes,
                context: 'loop',
              );
              labels.add(
                _LabelFrame(
                  kind: _LabelKind.loop,
                  stackHeight: entryStackHeight,
                  branchTypes: paramTypes,
                  endTypes: instruction.blockResultTypes ?? const [],
                  endIndex: _requireJumpIndex(instruction.endIndex, 'loop'),
                  loopStartIndex: pc + 1,
                ),
              );
              pc++;

            case Opcodes.if_:
              final condition = _popI32(stack);
              final paramTypes = instruction.blockParameterTypes ?? const [];
              final entryStackHeight = _consumeBlockParameters(
                stack,
                paramTypes,
                context: 'if',
              );
              final label = _LabelFrame(
                kind: _LabelKind.if_,
                stackHeight: entryStackHeight,
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

            case Opcodes.tryTable:
              final paramTypes = instruction.blockParameterTypes ?? const [];
              final entryStackHeight = _consumeBlockParameters(
                stack,
                paramTypes,
                context: 'try_table',
              );
              labels.add(
                _LabelFrame(
                  kind: _LabelKind.block,
                  stackHeight: entryStackHeight,
                  branchTypes: instruction.blockResultTypes ?? const [],
                  endTypes: instruction.blockResultTypes ?? const [],
                  endIndex: _requireJumpIndex(
                    instruction.endIndex,
                    'try_table',
                  ),
                  loopStartIndex: -1,
                  tryTableCatches: instruction.tryTableCatches,
                ),
              );
              pc++;

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

            case Opcodes.throwTag:
              _throwTag(stack, instruction);

            case Opcodes.throwRef:
              _throwRef(stack);

            case Opcodes.call:
              final targetIndex = instruction.immediate!;
              _checkFunctionIndex(targetIndex);
              final target = _functions[targetIndex];
              final callArgs = _popArgs(stack, target.type.params);
              final callResults = _execute(
                targetIndex,
                callArgs,
                depth: depth + 1,
              );
              stack.addAll(callResults);
              pc++;

            case Opcodes.callRef:
              final typeIndex = _checkTypeIndex(instruction.immediate!);
              final expectedType = _types[typeIndex];
              if (!expectedType.isFunctionType) {
                throw StateError(
                  'call_ref expected non-function type $typeIndex.',
                );
              }
              final functionReference = _popRef(stack);
              final target = _requireFunctionTarget(
                functionReference,
                opName: 'call_ref',
              );
              if (!_functionTargetMatchesType(
                target,
                typeIndex,
                exact: false,
              )) {
                throw StateError('call_ref signature mismatch trap');
              }
              final callArgs = _popArgs(stack, expectedType.params);
              final callResults = target.vm._execute(
                target.functionIndex,
                callArgs,
                depth: depth + 1,
              );
              stack.addAll(callResults);
              pc++;

            case Opcodes.returnCall:
              final targetIndex = instruction.immediate!;
              _checkFunctionIndex(targetIndex);
              final target = _functions[targetIndex];
              final callArgs = _popArgs(stack, target.type.params);
              currentFunctionIndex = targetIndex;
              currentArgs = callArgs;
              continue executionLoop;

            case Opcodes.returnCallRef:
              final typeIndex = _checkTypeIndex(instruction.immediate!);
              final expectedType = _types[typeIndex];
              if (!expectedType.isFunctionType) {
                throw StateError(
                  'call_ref expected non-function type $typeIndex.',
                );
              }
              final functionReference = _popRef(stack);
              final target = _requireFunctionTarget(
                functionReference,
                opName: 'call_ref',
              );
              if (!_functionTargetMatchesType(
                target,
                typeIndex,
                exact: false,
              )) {
                throw StateError('call_ref signature mismatch trap');
              }
              final callArgs = _popArgs(stack, expectedType.params);
              if (identical(target.vm, this)) {
                currentFunctionIndex = target.functionIndex;
                currentArgs = callArgs;
                continue executionLoop;
              }
              return target.vm._execute(
                target.functionIndex,
                callArgs,
                depth: depth,
              );

            case Opcodes.callIndirect:
              final typeIndex = _checkTypeIndex(instruction.immediate!);
              final tableIndex = _checkTableIndex(
                instruction.secondaryImmediate!,
              );
              final tableElementIndex = _popTableOperand(
                stack,
                tableIndex: tableIndex,
                label: 'call_indirect table index',
              );
              final targetFunctionRef = _tables[tableIndex][tableElementIndex];
              if (targetFunctionRef == null) {
                throw StateError('call_indirect to null table element.');
              }

              final target = _functionRefTargets[targetFunctionRef];
              if (target == null) {
                throw StateError(
                  'call_indirect to non-function table element.',
                );
              }
              final expectedType = _types[typeIndex];
              if (!expectedType.isFunctionType) {
                throw StateError(
                  'call_indirect expected non-function type $typeIndex.',
                );
              }

              if (!_functionTargetMatchesType(
                target,
                typeIndex,
                exact: false,
              )) {
                throw StateError('call_indirect signature mismatch trap');
              }

              final callArgs = _popArgs(stack, expectedType.params);
              final callResults = target.vm._execute(
                target.functionIndex,
                callArgs,
                depth: depth + 1,
              );
              stack.addAll(callResults);
              pc++;

            case Opcodes.returnCallIndirect:
              final typeIndex = _checkTypeIndex(instruction.immediate!);
              final tableIndex = _checkTableIndex(
                instruction.secondaryImmediate!,
              );
              final tableElementIndex = _popTableOperand(
                stack,
                tableIndex: tableIndex,
                label: 'return_call_indirect table index',
              );
              final targetFunctionRef = _tables[tableIndex][tableElementIndex];
              if (targetFunctionRef == null) {
                throw StateError('call_indirect to null table element.');
              }

              final target = _functionRefTargets[targetFunctionRef];
              if (target == null) {
                throw StateError(
                  'call_indirect to non-function table element.',
                );
              }
              final expectedType = _types[typeIndex];
              if (!expectedType.isFunctionType) {
                throw StateError(
                  'call_indirect expected non-function type $typeIndex.',
                );
              }

              if (!_functionTargetMatchesType(
                target,
                typeIndex,
                exact: false,
              )) {
                throw StateError('call_indirect signature mismatch trap');
              }

              final callArgs = _popArgs(stack, expectedType.params);
              if (identical(target.vm, this)) {
                currentFunctionIndex = target.functionIndex;
                currentArgs = callArgs;
                continue executionLoop;
              }
              return target.vm._execute(
                target.functionIndex,
                callArgs,
                depth: depth,
              );

            case Opcodes.drop:
              _pop(stack);
              pc++;

            case Opcodes.select:
            case Opcodes.selectT:
              final condition = _popI32(stack);
              final falseValue = _pop(stack);
              final trueValue = _pop(stack);
              if (falseValue.type != trueValue.type) {
                throw StateError(
                  'select operands must have the same value type.',
                );
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
                throw StateError(
                  'Cannot mutate immutable global $globalIndex.',
                );
              }
              global.setValue(_pop(stack));
              pc++;

            case Opcodes.tableGet:
              final tableIndex = _checkTableIndex(instruction.immediate!);
              final elementIndex = _popTableOperand(
                stack,
                tableIndex: tableIndex,
                label: 'table.get index',
              );
              _pushRef(stack, _tables[tableIndex][elementIndex]);
              pc++;

            case Opcodes.tableSet:
              final tableIndex = _checkTableIndex(instruction.immediate!);
              final value = _popRef(stack);
              final elementIndex = _popTableOperand(
                stack,
                tableIndex: tableIndex,
                label: 'table.set index',
              );
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
              _storeF32Bits(stack, instruction, _popF32Bits(stack));
              pc++;

            case Opcodes.f64Store:
              _storeF64Bits(stack, instruction, _popF64Bits(stack));
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
              _atomicStoreI8(
                stack,
                instruction,
                WasmI64.lowU32(_popI64(stack)),
              );
              pc++;

            case Opcodes.i64AtomicStore16:
              _atomicStoreI16(
                stack,
                instruction,
                WasmI64.lowU32(_popI64(stack)),
              );
              pc++;

            case Opcodes.i64AtomicStore32:
              _atomicStoreI32(
                stack,
                instruction,
                WasmI64.lowU32(_popI64(stack)),
              );
              pc++;

            case Opcodes.i32AtomicRmwAdd:
              stack.add(
                WasmValue.i32(
                  _atomicRmwI32(stack, instruction, (a, b) => a + b),
                ),
              );
              pc++;

            case Opcodes.i64AtomicRmwAdd:
              stack.add(
                WasmValue.i64(
                  _atomicRmwI64(stack, instruction, (a, b) => a + b),
                ),
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
                WasmValue.i32(
                  _atomicRmwI32(stack, instruction, (a, b) => a - b),
                ),
              );
              pc++;

            case Opcodes.i64AtomicRmwSub:
              stack.add(
                WasmValue.i64(
                  _atomicRmwI64(stack, instruction, (a, b) => a - b),
                ),
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
                WasmValue.i32(
                  _atomicRmwI32(stack, instruction, (a, b) => a & b),
                ),
              );
              pc++;

            case Opcodes.i64AtomicRmwAnd:
              stack.add(
                WasmValue.i64(
                  _atomicRmwI64(stack, instruction, (a, b) => a & b),
                ),
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
                WasmValue.i32(
                  _atomicRmwI32(stack, instruction, (a, b) => a | b),
                ),
              );
              pc++;

            case Opcodes.i64AtomicRmwOr:
              stack.add(
                WasmValue.i64(
                  _atomicRmwI64(stack, instruction, (a, b) => a | b),
                ),
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
                WasmValue.i32(
                  _atomicRmwI32(stack, instruction, (a, b) => a ^ b),
                ),
              );
              pc++;

            case Opcodes.i64AtomicRmwXor:
              stack.add(
                WasmValue.i64(
                  _atomicRmwI64(stack, instruction, (a, b) => a ^ b),
                ),
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
              final wideImmediate = instruction.wideImmediate;
              if (wideImmediate == null) {
                throw StateError('Malformed i64.const immediate.');
              }
              stack.add(WasmValue.i64(wideImmediate));
              pc++;

            case Opcodes.f32Const:
              final floatBytes = instruction.floatBytesImmediate;
              if (floatBytes != null && floatBytes.length == 4) {
                final bits = ByteData.sublistView(
                  floatBytes,
                ).getUint32(0, Endian.little);
                stack.add(WasmValue.f32Bits(bits));
              } else {
                stack.add(WasmValue.f32(instruction.floatImmediate!));
              }
              pc++;

            case Opcodes.f64Const:
              final floatBytes = instruction.floatBytesImmediate;
              if (floatBytes != null && floatBytes.length == 8) {
                final data = ByteData.sublistView(floatBytes);
                final low = data.getUint32(0, Endian.little);
                final high = data.getUint32(4, Endian.little);
                stack.add(
                  WasmValue.f64Bits(
                    WasmI64.fromU32PairUnsigned(low: low, high: high),
                  ),
                );
              } else {
                stack.add(WasmValue.f64(instruction.floatImmediate!));
              }
              pc++;

            case Opcodes.v128Const:
              final laneBytes = instruction.floatBytesImmediate;
              if (laneBytes == null || laneBytes.length != 16) {
                throw StateError('Malformed v128.const immediate.');
              }
              stack.add(WasmValue.i32(_internV128(laneBytes)));
              pc++;

            case Opcodes.v128Load:
              stack.add(WasmValue.i32(_loadV128(stack, instruction)));
              pc++;

            case Opcodes.v128Load8x8S:
              _pushV128Bytes(stack, _simdLoad8x8(stack, instruction, signed: true));
              pc++;

            case Opcodes.v128Load8x8U:
              _pushV128Bytes(stack, _simdLoad8x8(stack, instruction, signed: false));
              pc++;

            case Opcodes.v128Load16x4S:
              _pushV128Bytes(
                stack,
                _simdLoad16x4(stack, instruction, signed: true),
              );
              pc++;

            case Opcodes.v128Load16x4U:
              _pushV128Bytes(
                stack,
                _simdLoad16x4(stack, instruction, signed: false),
              );
              pc++;

            case Opcodes.v128Load32x2S:
              _pushV128Bytes(
                stack,
                _simdLoad32x2(stack, instruction, signed: true),
              );
              pc++;

            case Opcodes.v128Load32x2U:
              _pushV128Bytes(
                stack,
                _simdLoad32x2(stack, instruction, signed: false),
              );
              pc++;

            case Opcodes.v128Load8Splat:
              _pushV128Bytes(stack, _simdLoadSplat(stack, instruction, laneWidth: 1));
              pc++;

            case Opcodes.v128Load16Splat:
              _pushV128Bytes(stack, _simdLoadSplat(stack, instruction, laneWidth: 2));
              pc++;

            case Opcodes.v128Load32Splat:
              _pushV128Bytes(stack, _simdLoadSplat(stack, instruction, laneWidth: 4));
              pc++;

            case Opcodes.v128Load64Splat:
              _pushV128Bytes(stack, _simdLoadSplat(stack, instruction, laneWidth: 8));
              pc++;

            case Opcodes.v128Load32Zero:
              _pushV128Bytes(stack, _simdLoadZeroExtend(stack, instruction, laneWidth: 4));
              pc++;

            case Opcodes.v128Load64Zero:
              _pushV128Bytes(stack, _simdLoadZeroExtend(stack, instruction, laneWidth: 8));
              pc++;

            case Opcodes.v128Store:
              _storeV128(stack, instruction);
              pc++;

            case Opcodes.v128Load8Lane:
              _pushV128Bytes(
                stack,
                _simdLoadLane(stack, instruction, laneWidth: 1, laneCount: 16),
              );
              pc++;

            case Opcodes.v128Load16Lane:
              _pushV128Bytes(
                stack,
                _simdLoadLane(stack, instruction, laneWidth: 2, laneCount: 8),
              );
              pc++;

            case Opcodes.v128Load32Lane:
              _pushV128Bytes(
                stack,
                _simdLoadLane(stack, instruction, laneWidth: 4, laneCount: 4),
              );
              pc++;

            case Opcodes.v128Load64Lane:
              _pushV128Bytes(
                stack,
                _simdLoadLane(stack, instruction, laneWidth: 8, laneCount: 2),
              );
              pc++;

            case Opcodes.v128Store8Lane:
              _simdStoreLane(stack, instruction, laneWidth: 1, laneCount: 16);
              pc++;

            case Opcodes.v128Store16Lane:
              _simdStoreLane(stack, instruction, laneWidth: 2, laneCount: 8);
              pc++;

            case Opcodes.v128Store32Lane:
              _simdStoreLane(stack, instruction, laneWidth: 4, laneCount: 4);
              pc++;

            case Opcodes.v128Store64Lane:
              _simdStoreLane(stack, instruction, laneWidth: 8, laneCount: 2);
              pc++;

            case Opcodes.f32x4DemoteF64x2Zero:
              _simdF32x4DemoteF64x2Zero(stack);
              pc++;

            case Opcodes.f64x2PromoteLowF32x4:
              _simdF64x2PromoteLowF32x4(stack);
              pc++;

            case Opcodes.i8x16Splat:
              _simdSplatI8x16(stack);
              pc++;

            case Opcodes.i16x8Splat:
              _simdSplatI16x8(stack);
              pc++;

            case Opcodes.i32x4Splat:
              _simdSplatI32x4(stack);
              pc++;

            case Opcodes.i64x2Splat:
              _simdSplatI64x2(stack);
              pc++;

            case Opcodes.f32x4Splat:
              _simdSplatF32x4(stack);
              pc++;

            case Opcodes.f64x2Splat:
              _simdSplatF64x2(stack);
              pc++;

            case Opcodes.i8x16Swizzle:
              _simdI8x16Swizzle(stack);
              pc++;

            case Opcodes.i8x16RelaxedSwizzle:
              _simdI8x16Swizzle(stack);
              pc++;

            case Opcodes.i8x16Shuffle:
              _simdI8x16Shuffle(stack, instruction: instruction);
              pc++;

            case Opcodes.i8x16ExtractLaneS:
              _simdExtractLaneI8x16(stack, signed: true, instruction: instruction);
              pc++;

            case Opcodes.i8x16ExtractLaneU:
              _simdExtractLaneI8x16(
                stack,
                signed: false,
                instruction: instruction,
              );
              pc++;

            case Opcodes.i8x16ReplaceLane:
              _simdReplaceLaneI8x16(stack, instruction: instruction);
              pc++;

            case Opcodes.i16x8ExtractLaneS:
              _simdExtractLaneI16x8(
                stack,
                signed: true,
                instruction: instruction,
              );
              pc++;

            case Opcodes.i16x8ExtractLaneU:
              _simdExtractLaneI16x8(
                stack,
                signed: false,
                instruction: instruction,
              );
              pc++;

            case Opcodes.i16x8ReplaceLane:
              _simdReplaceLaneI16x8(stack, instruction: instruction);
              pc++;

            case Opcodes.i32x4ExtractLane:
              _simdExtractLaneI32x4(stack, instruction: instruction);
              pc++;

            case Opcodes.i32x4ReplaceLane:
              _simdReplaceLaneI32x4(stack, instruction: instruction);
              pc++;

            case Opcodes.i64x2ExtractLane:
              _simdExtractLaneI64x2(stack, instruction: instruction);
              pc++;

            case Opcodes.i64x2ReplaceLane:
              _simdReplaceLaneI64x2(stack, instruction: instruction);
              pc++;

            case Opcodes.f32x4ExtractLane:
              _simdExtractLaneF32x4(stack, instruction: instruction);
              pc++;

            case Opcodes.f32x4ReplaceLane:
              _simdReplaceLaneF32x4(stack, instruction: instruction);
              pc++;

            case Opcodes.f64x2ExtractLane:
              _simdExtractLaneF64x2(stack, instruction: instruction);
              pc++;

            case Opcodes.f64x2ReplaceLane:
              _simdReplaceLaneF64x2(stack, instruction: instruction);
              pc++;

            case Opcodes.v128Not:
              _simdV128Not(stack);
              pc++;

            case Opcodes.v128And:
              _simdV128And(stack);
              pc++;

            case Opcodes.v128Andnot:
              _simdV128Andnot(stack);
              pc++;

            case Opcodes.v128Or:
              _simdV128Or(stack);
              pc++;

            case Opcodes.v128Xor:
              _simdV128Xor(stack);
              pc++;

            case Opcodes.v128Bitselect:
              _simdV128Bitselect(stack);
              pc++;

            case Opcodes.i8x16RelaxedLaneselect:
            case Opcodes.i16x8RelaxedLaneselect:
            case Opcodes.i32x4RelaxedLaneselect:
            case Opcodes.i64x2RelaxedLaneselect:
              _simdV128Bitselect(stack);
              pc++;

            case Opcodes.v128AnyTrue:
              _simdV128AnyTrue(stack);
              pc++;

            case Opcodes.i8x16AllTrue:
              _simdI8x16AllTrue(stack);
              pc++;

            case Opcodes.i16x8AllTrue:
              _simdI16x8AllTrue(stack);
              pc++;

            case Opcodes.i32x4AllTrue:
              _simdI32x4AllTrue(stack);
              pc++;

            case Opcodes.i64x2AllTrue:
              _simdI64x2AllTrue(stack);
              pc++;

            case Opcodes.i8x16Bitmask:
              _simdI8x16Bitmask(stack);
              pc++;

            case Opcodes.i16x8Bitmask:
              _simdI16x8Bitmask(stack);
              pc++;

            case Opcodes.i32x4Bitmask:
              _simdI32x4Bitmask(stack);
              pc++;

            case Opcodes.i64x2Bitmask:
              _simdI64x2Bitmask(stack);
              pc++;

            case Opcodes.i8x16Eq:
              _simdI8x16Eq(stack);
              pc++;

            case Opcodes.i8x16Ne:
              _simdI8x16Ne(stack);
              pc++;

            case Opcodes.i8x16LtS:
            case Opcodes.i8x16LtU:
            case Opcodes.i8x16GtS:
            case Opcodes.i8x16GtU:
            case Opcodes.i8x16LeS:
            case Opcodes.i8x16LeU:
            case Opcodes.i8x16GeS:
            case Opcodes.i8x16GeU:
              _simdI8x16Compare(stack, opcode: instruction.opcode);
              pc++;

            case Opcodes.i16x8Eq:
              _simdI16x8Eq(stack);
              pc++;

            case Opcodes.i16x8Ne:
              _simdI16x8Ne(stack);
              pc++;

            case Opcodes.i16x8LtS:
            case Opcodes.i16x8LtU:
            case Opcodes.i16x8GtS:
            case Opcodes.i16x8GtU:
            case Opcodes.i16x8LeS:
            case Opcodes.i16x8LeU:
            case Opcodes.i16x8GeS:
            case Opcodes.i16x8GeU:
              _simdI16x8Compare(stack, opcode: instruction.opcode);
              pc++;

            case Opcodes.i32x4Eq:
              _simdI32x4Eq(stack);
              pc++;

            case Opcodes.i32x4Ne:
              _simdI32x4Ne(stack);
              pc++;

            case Opcodes.i32x4LtS:
            case Opcodes.i32x4LtU:
            case Opcodes.i32x4GtS:
            case Opcodes.i32x4GtU:
            case Opcodes.i32x4LeS:
            case Opcodes.i32x4LeU:
            case Opcodes.i32x4GeS:
            case Opcodes.i32x4GeU:
              _simdI32x4Compare(stack, opcode: instruction.opcode);
              pc++;

            case Opcodes.f32x4Eq:
              _simdF32x4Eq(stack);
              pc++;

            case Opcodes.f32x4Ne:
              _simdF32x4Ne(stack);
              pc++;

            case Opcodes.f32x4Lt:
            case Opcodes.f32x4Gt:
            case Opcodes.f32x4Le:
            case Opcodes.f32x4Ge:
              _simdF32x4Compare(stack, opcode: instruction.opcode);
              pc++;

            case Opcodes.f64x2Eq:
              _simdF64x2Eq(stack);
              pc++;

            case Opcodes.f64x2Ne:
              _simdF64x2Ne(stack);
              pc++;

            case Opcodes.i64x2Eq:
              _simdI64x2Eq(stack);
              pc++;

            case Opcodes.f64x2Lt:
            case Opcodes.f64x2Gt:
            case Opcodes.f64x2Le:
            case Opcodes.f64x2Ge:
              _simdF64x2Compare(stack, opcode: instruction.opcode);
              pc++;

            case Opcodes.i64x2Ne:
            case Opcodes.i64x2LtS:
            case Opcodes.i64x2GtS:
            case Opcodes.i64x2LeS:
            case Opcodes.i64x2GeS:
              _simdI64x2Compare(stack, opcode: instruction.opcode);
              pc++;

            case Opcodes.i8x16ShrS:
              _simdI8x16ShrS(stack);
              pc++;

            case Opcodes.i8x16Shl:
              _simdI8x16Shl(stack);
              pc++;

            case Opcodes.i8x16ShrU:
              _simdI8x16ShrU(stack);
              pc++;

            case Opcodes.i16x8ShrS:
              _simdI16x8ShrS(stack);
              pc++;

            case Opcodes.i16x8Shl:
              _simdI16x8Shl(stack);
              pc++;

            case Opcodes.i16x8ShrU:
              _simdI16x8ShrU(stack);
              pc++;

            case Opcodes.i32x4ShrS:
              _simdI32x4ShrS(stack);
              pc++;

            case Opcodes.i32x4Shl:
              _simdI32x4Shl(stack);
              pc++;

            case Opcodes.i32x4ShrU:
              _simdI32x4ShrU(stack);
              pc++;

            case Opcodes.i64x2Shl:
              _simdI64x2Shl(stack);
              pc++;

            case Opcodes.i64x2ShrS:
              _simdI64x2ShrS(stack);
              pc++;

            case Opcodes.i64x2ShrU:
              _simdI64x2ShrU(stack);
              pc++;

            case Opcodes.i8x16Abs:
              _simdI8x16Abs(stack);
              pc++;

            case Opcodes.i8x16Neg:
              _simdI8x16Neg(stack);
              pc++;

            case Opcodes.i8x16Popcnt:
              _simdI8x16Popcnt(stack);
              pc++;

            case Opcodes.i8x16Add:
              _simdI8x16Add(stack);
              pc++;

            case Opcodes.i8x16NarrowI16x8S:
              _simdI8x16NarrowI16x8S(stack);
              pc++;

            case Opcodes.i8x16NarrowI16x8U:
              _simdI8x16NarrowI16x8U(stack);
              pc++;

            case Opcodes.i16x8NarrowI32x4S:
              _simdI16x8NarrowI32x4S(stack);
              pc++;

            case Opcodes.i16x8NarrowI32x4U:
              _simdI16x8NarrowI32x4U(stack);
              pc++;

            case Opcodes.i8x16AddSatS:
              _simdI8x16AddSatS(stack);
              pc++;

            case Opcodes.i8x16AddSatU:
              _simdI8x16AddSatU(stack);
              pc++;

            case Opcodes.i8x16Sub:
              _simdI8x16Sub(stack);
              pc++;

            case Opcodes.i8x16SubSatS:
              _simdI8x16SubSatS(stack);
              pc++;

            case Opcodes.i8x16SubSatU:
              _simdI8x16SubSatU(stack);
              pc++;

            case Opcodes.i8x16MinS:
              _simdI8x16MinS(stack);
              pc++;

            case Opcodes.i8x16MinU:
              _simdI8x16MinU(stack);
              pc++;

            case Opcodes.i8x16MaxS:
              _simdI8x16MaxS(stack);
              pc++;

            case Opcodes.i8x16MaxU:
              _simdI8x16MaxU(stack);
              pc++;

            case Opcodes.i8x16AvgrU:
              _simdI8x16AvgrU(stack);
              pc++;

            case Opcodes.i16x8Add:
              _simdI16x8Add(stack);
              pc++;

            case Opcodes.i16x8AddSatS:
              _simdI16x8AddSatS(stack);
              pc++;

            case Opcodes.i16x8AddSatU:
              _simdI16x8AddSatU(stack);
              pc++;

            case Opcodes.i16x8Sub:
              _simdI16x8Sub(stack);
              pc++;

            case Opcodes.i16x8SubSatS:
              _simdI16x8SubSatS(stack);
              pc++;

            case Opcodes.i16x8SubSatU:
              _simdI16x8SubSatU(stack);
              pc++;

            case Opcodes.i16x8Abs:
              _simdI16x8Abs(stack);
              pc++;

            case Opcodes.i16x8Neg:
              _simdI16x8Neg(stack);
              pc++;

            case Opcodes.i16x8Mul:
              _simdI16x8Mul(stack);
              pc++;

            case Opcodes.i16x8MinS:
              _simdI16x8MinS(stack);
              pc++;

            case Opcodes.i16x8MinU:
              _simdI16x8MinU(stack);
              pc++;

            case Opcodes.i16x8MaxS:
              _simdI16x8MaxS(stack);
              pc++;

            case Opcodes.i16x8MaxU:
              _simdI16x8MaxU(stack);
              pc++;

            case Opcodes.i16x8AvgrU:
              _simdI16x8AvgrU(stack);
              pc++;

            case Opcodes.i16x8Q15MulrSatS:
              _simdI16x8Q15MulrSatS(stack);
              pc++;

            case Opcodes.i16x8RelaxedQ15mulrS:
              _simdI16x8Q15MulrSatS(stack);
              pc++;

            case Opcodes.i16x8RelaxedDotI8x16I7x16S:
              _simdI16x8RelaxedDotI8x16I7x16S(stack);
              pc++;

            case Opcodes.i16x8ExtAddPairwiseI8x16S:
              _simdI16x8ExtAddPairwiseI8x16S(stack);
              pc++;

            case Opcodes.i16x8ExtAddPairwiseI8x16U:
              _simdI16x8ExtAddPairwiseI8x16U(stack);
              pc++;

            case Opcodes.i16x8ExtendHighI8x16S:
              _simdI16x8ExtendHighI8x16S(stack);
              pc++;

            case Opcodes.i16x8ExtendLowI8x16S:
              _simdI16x8ExtendLowI8x16S(stack);
              pc++;

            case Opcodes.i16x8ExtendHighI8x16U:
              _simdI16x8ExtendHighI8x16U(stack);
              pc++;

            case Opcodes.i16x8ExtendLowI8x16U:
              _simdI16x8ExtendLowI8x16U(stack);
              pc++;

            case Opcodes.i16x8ExtmulLowI8x16S:
              _simdI16x8ExtmulLowI8x16S(stack);
              pc++;

            case Opcodes.i16x8ExtmulHighI8x16S:
              _simdI16x8ExtmulHighI8x16S(stack);
              pc++;

            case Opcodes.i16x8ExtmulLowI8x16U:
              _simdI16x8ExtmulLowI8x16U(stack);
              pc++;

            case Opcodes.i16x8ExtmulHighI8x16U:
              _simdI16x8ExtmulHighI8x16U(stack);
              pc++;

            case Opcodes.i32x4ExtAddPairwiseI16x8S:
              _simdI32x4ExtAddPairwiseI16x8S(stack);
              pc++;

            case Opcodes.i32x4ExtAddPairwiseI16x8U:
              _simdI32x4ExtAddPairwiseI16x8U(stack);
              pc++;

            case Opcodes.i32x4ExtendLowI16x8S:
              _simdI32x4ExtendLowI16x8S(stack);
              pc++;

            case Opcodes.i32x4ExtendHighI16x8S:
              _simdI32x4ExtendHighI16x8S(stack);
              pc++;

            case Opcodes.i32x4ExtendLowI16x8U:
              _simdI32x4ExtendLowI16x8U(stack);
              pc++;

            case Opcodes.i32x4ExtendHighI16x8U:
              _simdI32x4ExtendHighI16x8U(stack);
              pc++;

            case Opcodes.i32x4Abs:
              _simdI32x4Abs(stack);
              pc++;

            case Opcodes.i32x4Neg:
              _simdI32x4Neg(stack);
              pc++;

            case Opcodes.i32x4Add:
              _simdI32x4Add(stack);
              pc++;

            case Opcodes.i32x4Sub:
              _simdI32x4Sub(stack);
              pc++;

            case Opcodes.i32x4Mul:
              _simdI32x4Mul(stack);
              pc++;

            case Opcodes.i32x4MinS:
              _simdI32x4MinS(stack);
              pc++;

            case Opcodes.i32x4MinU:
              _simdI32x4MinU(stack);
              pc++;

            case Opcodes.i32x4MaxS:
              _simdI32x4MaxS(stack);
              pc++;

            case Opcodes.i32x4MaxU:
              _simdI32x4MaxU(stack);
              pc++;

            case Opcodes.i32x4DotI16x8S:
              _simdI32x4DotI16x8S(stack);
              pc++;

            case Opcodes.i32x4RelaxedDotI8x16I7x16AddS:
              _simdI32x4RelaxedDotI8x16I7x16AddS(stack);
              pc++;

            case Opcodes.i32x4ExtmulLowI16x8S:
              _simdI32x4ExtmulLowI16x8S(stack);
              pc++;

            case Opcodes.i32x4ExtmulHighI16x8S:
              _simdI32x4ExtmulHighI16x8S(stack);
              pc++;

            case Opcodes.i32x4ExtmulLowI16x8U:
              _simdI32x4ExtmulLowI16x8U(stack);
              pc++;

            case Opcodes.i32x4ExtmulHighI16x8U:
              _simdI32x4ExtmulHighI16x8U(stack);
              pc++;

            case Opcodes.i64x2Abs:
              _simdI64x2Abs(stack);
              pc++;

            case Opcodes.i64x2Neg:
              _simdI64x2Neg(stack);
              pc++;

            case Opcodes.i64x2ExtendLowI32x4S:
              _simdI64x2ExtendLowI32x4S(stack);
              pc++;

            case Opcodes.i64x2ExtendHighI32x4S:
              _simdI64x2ExtendHighI32x4S(stack);
              pc++;

            case Opcodes.i64x2ExtendLowI32x4U:
              _simdI64x2ExtendLowI32x4U(stack);
              pc++;

            case Opcodes.i64x2ExtendHighI32x4U:
              _simdI64x2ExtendHighI32x4U(stack);
              pc++;

            case Opcodes.i64x2Add:
              _simdI64x2Add(stack);
              pc++;

            case Opcodes.i64x2Sub:
              _simdI64x2Sub(stack);
              pc++;

            case Opcodes.i64x2Mul:
              _simdI64x2Mul(stack);
              pc++;

            case Opcodes.i64x2ExtmulLowI32x4S:
              _simdI64x2ExtmulLowI32x4S(stack);
              pc++;

            case Opcodes.i64x2ExtmulHighI32x4S:
              _simdI64x2ExtmulHighI32x4S(stack);
              pc++;

            case Opcodes.i64x2ExtmulLowI32x4U:
              _simdI64x2ExtmulLowI32x4U(stack);
              pc++;

            case Opcodes.i64x2ExtmulHighI32x4U:
              _simdI64x2ExtmulHighI32x4U(stack);
              pc++;

            case Opcodes.f32x4Ceil:
              _simdF32x4Ceil(stack);
              pc++;

            case Opcodes.f32x4Floor:
              _simdF32x4Floor(stack);
              pc++;

            case Opcodes.f32x4Trunc:
              _simdF32x4Trunc(stack);
              pc++;

            case Opcodes.f32x4Nearest:
              _simdF32x4Nearest(stack);
              pc++;

            case Opcodes.f32x4Abs:
              _simdF32x4Abs(stack);
              pc++;

            case Opcodes.f32x4Neg:
              _simdF32x4Neg(stack);
              pc++;

            case Opcodes.f32x4Sqrt:
              _simdF32x4Sqrt(stack);
              pc++;

            case Opcodes.f32x4Add:
              _simdF32x4Add(stack);
              pc++;

            case Opcodes.f32x4Sub:
              _simdF32x4Sub(stack);
              pc++;

            case Opcodes.f32x4Mul:
              _simdF32x4Mul(stack);
              pc++;

            case Opcodes.f32x4RelaxedMadd:
              _simdF32x4RelaxedMadd(stack);
              pc++;

            case Opcodes.f32x4RelaxedNmadd:
              _simdF32x4RelaxedNmadd(stack);
              pc++;

            case Opcodes.f32x4Div:
              _simdF32x4Div(stack);
              pc++;

            case Opcodes.f32x4Min:
              _simdF32x4Min(stack);
              pc++;

            case Opcodes.f32x4Max:
              _simdF32x4Max(stack);
              pc++;

            case Opcodes.f32x4Pmin:
              _simdF32x4Pmin(stack);
              pc++;

            case Opcodes.f32x4Pmax:
              _simdF32x4Pmax(stack);
              pc++;

            case Opcodes.f32x4RelaxedMin:
              _simdF32x4Min(stack);
              pc++;

            case Opcodes.f32x4RelaxedMax:
              _simdF32x4Max(stack);
              pc++;

            case Opcodes.f64x2Ceil:
              _simdF64x2Ceil(stack);
              pc++;

            case Opcodes.f64x2Floor:
              _simdF64x2Floor(stack);
              pc++;

            case Opcodes.f64x2Trunc:
              _simdF64x2Trunc(stack);
              pc++;

            case Opcodes.f64x2Nearest:
              _simdF64x2Nearest(stack);
              pc++;

            case Opcodes.f64x2Abs:
              _simdF64x2Abs(stack);
              pc++;

            case Opcodes.f64x2Neg:
              _simdF64x2Neg(stack);
              pc++;

            case Opcodes.f64x2Sqrt:
              _simdF64x2Sqrt(stack);
              pc++;

            case Opcodes.f64x2Add:
              _simdF64x2Add(stack);
              pc++;

            case Opcodes.f64x2Sub:
              _simdF64x2Sub(stack);
              pc++;

            case Opcodes.f64x2Mul:
              _simdF64x2Mul(stack);
              pc++;

            case Opcodes.f64x2RelaxedMadd:
              _simdF64x2RelaxedMadd(stack);
              pc++;

            case Opcodes.f64x2RelaxedNmadd:
              _simdF64x2RelaxedNmadd(stack);
              pc++;

            case Opcodes.f64x2Div:
              _simdF64x2Div(stack);
              pc++;

            case Opcodes.f64x2Min:
              _simdF64x2Min(stack);
              pc++;

            case Opcodes.f64x2Max:
              _simdF64x2Max(stack);
              pc++;

            case Opcodes.f64x2Pmin:
              _simdF64x2Pmin(stack);
              pc++;

            case Opcodes.f64x2Pmax:
              _simdF64x2Pmax(stack);
              pc++;

            case Opcodes.f64x2RelaxedMin:
              _simdF64x2Min(stack);
              pc++;

            case Opcodes.f64x2RelaxedMax:
              _simdF64x2Max(stack);
              pc++;

            case Opcodes.f32x4ConvertI32x4S:
              _simdF32x4ConvertI32x4S(stack);
              pc++;

            case Opcodes.f32x4ConvertI32x4U:
              _simdF32x4ConvertI32x4U(stack);
              pc++;

            case Opcodes.i32x4TruncSatF32x4S:
              _simdI32x4TruncSatF32x4S(stack);
              pc++;

            case Opcodes.i32x4RelaxedTruncF32x4S:
              _simdI32x4TruncSatF32x4S(stack);
              pc++;

            case Opcodes.i32x4TruncSatF32x4U:
              _simdI32x4TruncSatF32x4U(stack);
              pc++;

            case Opcodes.i32x4RelaxedTruncF32x4U:
              _simdI32x4TruncSatF32x4U(stack);
              pc++;

            case Opcodes.i32x4TruncSatF64x2SZero:
              _simdI32x4TruncSatF64x2SZero(stack);
              pc++;

            case Opcodes.i32x4RelaxedTruncF64x2SZero:
              _simdI32x4TruncSatF64x2SZero(stack);
              pc++;

            case Opcodes.i32x4TruncSatF64x2UZero:
              _simdI32x4TruncSatF64x2UZero(stack);
              pc++;

            case Opcodes.i32x4RelaxedTruncF64x2UZero:
              _simdI32x4TruncSatF64x2UZero(stack);
              pc++;

            case Opcodes.f64x2ConvertLowI32x4S:
              _simdF64x2ConvertLowI32x4S(stack);
              pc++;

            case Opcodes.f64x2ConvertLowI32x4U:
              _simdF64x2ConvertLowI32x4U(stack);
              pc++;

            case Opcodes.refNull:
              stack.add(WasmValue.i32(_nullRef));
              pc++;

            case Opcodes.refFunc:
              final functionIndex = _checkFunctionIndex(instruction.immediate!);
              final functionRef = functionRefIdFor(
                namespace: _functionRefNamespace,
                functionIndex: functionIndex,
              );
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

            case Opcodes.structGet:
            case Opcodes.structGetS:
            case Opcodes.structGetU:
              _gcStructGet(
                stack,
                instruction,
                signed: instruction.opcode == Opcodes.structGetS,
                allowPacked: instruction.opcode != Opcodes.structGet,
              );
              pc++;

            case Opcodes.structSet:
              _gcStructSet(stack, instruction);
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

            case Opcodes.externConvertAny:
              _gcExternConvertAny(stack);
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
              stack.add(
                WasmValue.i32(_popI32(stack) == _popI32(stack) ? 1 : 0),
              );
              pc++;

            case Opcodes.i32Ne:
              stack.add(
                WasmValue.i32(_popI32(stack) != _popI32(stack) ? 1 : 0),
              );
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
              stack.add(
                WasmValue.i32(_popI64(stack) == _popI64(stack) ? 1 : 0),
              );
              pc++;

            case Opcodes.i64Ne:
              stack.add(
                WasmValue.i32(_popI64(stack) != _popI64(stack) ? 1 : 0),
              );
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
              stack.add(
                WasmValue.i32(_popF32(stack) == _popF32(stack) ? 1 : 0),
              );
              pc++;

            case Opcodes.f32Ne:
              stack.add(
                WasmValue.i32(_popF32(stack) != _popF32(stack) ? 1 : 0),
              );
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
              stack.add(
                WasmValue.i32(_popF64(stack) == _popF64(stack) ? 1 : 0),
              );
              pc++;

            case Opcodes.f64Ne:
              stack.add(
                WasmValue.i32(_popF64(stack) != _popF64(stack) ? 1 : 0),
              );
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
              final rhs = _popI32(stack);
              final lhs = _popI32(stack);
              stack.add(WasmValue.i32(_mulI32(lhs, rhs)));
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
              stack.add(WasmValue.f32Bits(_popF32Bits(stack) & 0x7fffffff));
              pc++;

            case Opcodes.f32Neg:
              stack.add(WasmValue.f32Bits(_popF32Bits(stack) ^ 0x80000000));
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
              final rhsBits = _popF32Bits(stack);
              final lhsBits = _popF32Bits(stack);
              stack.add(
                WasmValue.f32Bits(
                  (lhsBits & 0x7fffffff) | (rhsBits & 0x80000000),
                ),
              );
              pc++;

            case Opcodes.f64Abs:
              stack.add(
                WasmValue.f64Bits(
                  _popF64Bits(stack) &
                      BigInt.parse('7fffffffffffffff', radix: 16),
                ),
              );
              pc++;

            case Opcodes.f64Neg:
              stack.add(
                WasmValue.f64Bits(
                  _popF64Bits(stack) ^
                      BigInt.parse('8000000000000000', radix: 16),
                ),
              );
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
              final signMask = BigInt.parse('8000000000000000', radix: 16);
              final magnitudeMask = BigInt.parse('7fffffffffffffff', radix: 16);
              final rhsBits = _popF64Bits(stack);
              final lhsBits = _popF64Bits(stack);
              stack.add(
                WasmValue.f64Bits(
                  (lhsBits & magnitudeMask) | (rhsBits & signMask),
                ),
              );
              pc++;

            case Opcodes.i32WrapI64:
              stack.add(
                WasmValue.i32(WasmI64.lowU32(_popI64(stack)).toSigned(32)),
              );
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
              stack.add(
                WasmValue.i64(_toSignedI64(_truncToI64U(_popF32(stack)))),
              );
              pc++;

            case Opcodes.i64TruncF64S:
              stack.add(WasmValue.i64(_truncToI64S(_popF64(stack))));
              pc++;

            case Opcodes.i64TruncF64U:
              stack.add(
                WasmValue.i64(_toSignedI64(_truncToI64U(_popF64(stack)))),
              );
              pc++;

            case Opcodes.f32ConvertI32S:
              stack.add(WasmValue.f32(_popI32(stack).toDouble()));
              pc++;

            case Opcodes.f32ConvertI32U:
              stack.add(WasmValue.f32(_toU32(_popI32(stack)).toDouble()));
              pc++;

            case Opcodes.f32ConvertI64S:
              stack.add(WasmValue.f32(_f32FromInteger(_popI64(stack))));
              pc++;

            case Opcodes.f32ConvertI64U:
              stack.add(WasmValue.f32(_f32FromInteger(_toU64(_popI64(stack)))));
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
              stack.add(
                WasmValue.f64(WasmI64.unsignedToDouble(_popI64(stack))),
              );
              pc++;

            case Opcodes.f64PromoteF32:
              stack.add(WasmValue.f64(_popF32(stack)));
              pc++;

            case Opcodes.i32ReinterpretF32:
              stack.add(
                WasmValue.i32(
                  _pop(stack).castTo(WasmValueType.f32).asF32Bits(),
                ),
              );
              pc++;

            case Opcodes.i64ReinterpretF64:
              stack.add(
                WasmValue.i64(
                  _pop(stack).castTo(WasmValueType.f64).asF64Bits(),
                ),
              );
              pc++;

            case Opcodes.f32ReinterpretI32:
              stack.add(WasmValue.f32Bits(_toU32(_popI32(stack))));
              pc++;

            case Opcodes.f64ReinterpretI64:
              stack.add(WasmValue.f64Bits(_toU64(_popI64(stack))));
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
        } on _WasmThrownException catch (thrown) {
          final handledPc = _handleThrownException(
            thrown,
            labels: labels,
            stack: stack,
          );
          if (handledPc == null) {
            rethrow;
          }
          pc = handledPc;
        }
      }

      throw StateError('Function execution ended without `end` instruction.');
    }
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
    _truncateStackToHeight(stack, target.stackHeight, context: 'branch');
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
    _truncateStackToHeight(stack, label.stackHeight, context: 'end');
    stack.addAll(results);
  }

  void _throwTag(List<WasmValue> stack, Instruction instruction) {
    final tagIndex = _checkTagIndex(instruction.immediate!);
    final tagType = _tagTypes[tagIndex];
    final values = _popArgs(stack, tagType.params);
    final exceptionRef = _allocateExceptionRef(
      _ExceptionObject(
        nominalTypeKey: _tagNominalTypeKeys[tagIndex],
        values: values,
      ),
    );
    throw _WasmThrownException(exceptionRef);
  }

  void _throwRef(List<WasmValue> stack) {
    final exceptionRef = _popRef(stack);
    if (exceptionRef == null) {
      throw StateError('null exception reference');
    }
    _requireExceptionObject(exceptionRef);
    throw _WasmThrownException(exceptionRef);
  }

  int? _handleThrownException(
    _WasmThrownException thrown, {
    required List<_LabelFrame> labels,
    required List<WasmValue> stack,
  }) {
    final exception = _requireExceptionObject(thrown.exceptionRef);
    for (var i = labels.length - 1; i >= 0; i--) {
      final frame = labels[i];
      final catches = frame.tryTableCatches;
      if (catches == null || catches.isEmpty) {
        continue;
      }

      TryTableCatchClause? matched;
      for (final clause in catches) {
        switch (clause.kind) {
          case TryTableCatchKind.catchTag:
          case TryTableCatchKind.catchRef:
            final tagIndex = clause.tagIndex;
            if (tagIndex == null) {
              continue;
            }
            final resolvedTagIndex = _checkTagIndex(tagIndex);
            if (_tagNominalTypeKeys[resolvedTagIndex] ==
                exception.nominalTypeKey) {
              matched = clause;
            }
          case TryTableCatchKind.catchAll:
          case TryTableCatchKind.catchAllRef:
            matched = clause;
          default:
            continue;
        }
        if (matched != null) {
          break;
        }
      }

      if (matched == null) {
        continue;
      }

      if (i + 1 < labels.length) {
        labels.removeRange(i + 1, labels.length);
      }
      _truncateStackToHeight(
        stack,
        frame.stackHeight,
        context: 'exception unwind',
      );

      switch (matched.kind) {
        case TryTableCatchKind.catchTag:
          stack.addAll(exception.values);
        case TryTableCatchKind.catchRef:
          stack
            ..addAll(exception.values)
            ..add(WasmValue.i32(thrown.exceptionRef));
        case TryTableCatchKind.catchAll:
          break;
        case TryTableCatchKind.catchAllRef:
          stack.add(WasmValue.i32(thrown.exceptionRef));
        default:
          continue;
      }
      return _branch(matched.labelDepth + 1, labels, stack);
    }

    return null;
  }

  void _truncateStackToHeight(
    List<WasmValue> stack,
    int height, {
    required String context,
  }) {
    if (stack.length < height) {
      throw StateError(
        'Operand stack underflow while restoring $context frame: '
        'stack=${stack.length}, height=$height.',
      );
    }
    stack.length = height;
  }

  int _consumeBlockParameters(
    List<WasmValue> stack,
    List<WasmValueType> paramTypes, {
    required String context,
  }) {
    if (paramTypes.isEmpty) {
      return stack.length;
    }
    final params = _takeTopValues(stack, paramTypes);
    final entryStackHeight = stack.length - paramTypes.length;
    _truncateStackToHeight(
      stack,
      entryStackHeight,
      context: '$context parameters',
    );
    stack.addAll(params);
    return entryStackHeight;
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

  bool _isTable64(int tableIndex) {
    if (tableIndex < 0 || tableIndex >= _table64ByIndex.length) {
      throw RangeError(
        'Invalid table index: $tableIndex (count=${_table64ByIndex.length}).',
      );
    }
    return _table64ByIndex[tableIndex];
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

  int _popUnsignedI32Operand(List<WasmValue> stack, {required String label}) {
    final value = _pop(stack);
    if (value.type != WasmValueType.i32) {
      throw StateError(
        'Type mismatch: expected i32 for $label, got ${value.type}.',
      );
    }
    return _toLinearMemoryValue(
      BigInt.from(_toU32(value.asI32())),
      label: label,
    );
  }

  int _popMemoryOperationLength(
    List<WasmValue> stack, {
    required String label,
  }) {
    final value = _pop(stack);
    final unsigned = switch (value.type) {
      WasmValueType.i32 => BigInt.from(_toU32(value.asI32())),
      WasmValueType.i64 => _toU64(value.asI64()),
      _ => throw StateError(
        'Type mismatch: expected i32/i64 length for $label, got ${value.type}.',
      ),
    };
    return _toLinearMemoryValue(unsigned, label: label);
  }

  BigInt _popUnsignedTableOperand(
    List<WasmValue> stack, {
    required int tableIndex,
  }) {
    if (_isTable64(tableIndex)) {
      return _toU64(_popI64(stack));
    }
    return BigInt.from(_toU32(_popI32(stack)));
  }

  int _popTableOperand(
    List<WasmValue> stack, {
    required int tableIndex,
    required String label,
  }) {
    final operand = _popUnsignedTableOperand(stack, tableIndex: tableIndex);
    return _toLinearMemoryValue(operand, label: label);
  }

  WasmValue _tableIndexValue(int tableIndex, int value) {
    if (_isTable64(tableIndex)) {
      final i64 = value < 0 ? WasmI64.signed(value) : WasmI64.unsigned(value);
      return WasmValue.i64(i64);
    }
    return WasmValue.i32(value);
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
    if (!a.isFunctionType || !b.isFunctionType) {
      return false;
    }
    if (a.declaresSubtype != b.declaresSubtype ||
        a.subtypeFinal != b.subtypeFinal) {
      return false;
    }
    if (a.recGroupSize != b.recGroupSize ||
        a.recGroupPosition != b.recGroupPosition) {
      return false;
    }
    if (a.paramTypeSignatures.length != b.paramTypeSignatures.length ||
        a.resultTypeSignatures.length != b.resultTypeSignatures.length) {
      return false;
    }
    for (var i = 0; i < a.paramTypeSignatures.length; i++) {
      if (a.paramTypeSignatures[i] != b.paramTypeSignatures[i]) {
        return false;
      }
    }
    for (var i = 0; i < a.resultTypeSignatures.length; i++) {
      if (a.resultTypeSignatures[i] != b.resultTypeSignatures[i]) {
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
    final functionTarget = _functionRefTargets[reference];
    if (functionTarget != null) {
      if (targetHeapType < 0) {
        return _functionRefMatchesAbstract(
          targetHeapType,
          exact: refType.exact,
        );
      }
      return _functionTargetMatchesType(
        functionTarget,
        targetHeapType,
        exact: refType.exact,
      );
    }

    if (reference >= 0) {
      return _externRefMatches(targetHeapType, exact: refType.exact);
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
      case _GcRefKind.anyExtern:
        return _anyRefMatches(targetHeapType, exact: refType.exact);
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

  bool _anyRefMatches(int heapType, {required bool exact}) {
    if (heapType >= 0 || exact) {
      return false;
    }
    return heapType == _heapAny;
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
    if (left.recGroupSize != right.recGroupSize ||
        left.recGroupPosition != right.recGroupPosition) {
      return false;
    }
    final leftGroupStart = lhs - left.recGroupPosition;
    final rightGroupStart = rhs - right.recGroupPosition;
    final recGroupSize = left.recGroupSize;
    if (leftGroupStart < 0 ||
        rightGroupStart < 0 ||
        leftGroupStart + recGroupSize > _types.length ||
        rightGroupStart + recGroupSize > _types.length) {
      return false;
    }
    if (left.kind != right.kind ||
        left.isFunctionType != right.isFunctionType) {
      return false;
    }
    if (left.declaresSubtype != right.declaresSubtype ||
        left.subtypeFinal != right.subtypeFinal) {
      return false;
    }
    if (recGroupSize > 1) {
      for (var i = 0; i < recGroupSize; i++) {
        final leftPeer = leftGroupStart + i;
        final rightPeer = rightGroupStart + i;
        if (leftPeer == lhs && rightPeer == rhs) {
          continue;
        }
        if (!_areTypesEquivalent(leftPeer, rightPeer, seenPairs)) {
          return false;
        }
      }
    }
    if (left.superTypeIndices.length != right.superTypeIndices.length) {
      return false;
    }
    for (var i = 0; i < left.superTypeIndices.length; i++) {
      final leftSuper = left.superTypeIndices[i];
      final rightSuper = right.superTypeIndices[i];
      final leftSuperInGroup =
          leftSuper >= leftGroupStart &&
          leftSuper < leftGroupStart + recGroupSize;
      final rightSuperInGroup =
          rightSuper >= rightGroupStart &&
          rightSuper < rightGroupStart + recGroupSize;
      if (leftSuperInGroup || rightSuperInGroup) {
        if (!leftSuperInGroup || !rightSuperInGroup) {
          return false;
        }
        if ((leftSuper - leftGroupStart) != (rightSuper - rightGroupStart)) {
          return false;
        }
        continue;
      }
      if (!_areTypesEquivalent(leftSuper, rightSuper, seenPairs)) {
        return false;
      }
    }
    final leftDescriptor = left.descriptorTypeIndex;
    final rightDescriptor = right.descriptorTypeIndex;
    if ((leftDescriptor == null) != (rightDescriptor == null)) {
      return false;
    }
    if (leftDescriptor != null &&
        !_areTypesEquivalent(leftDescriptor, rightDescriptor!, seenPairs)) {
      return false;
    }
    final leftDescribes = left.describesTypeIndex;
    final rightDescribes = right.describesTypeIndex;
    if ((leftDescribes == null) != (rightDescribes == null)) {
      return false;
    }
    if (leftDescribes != null &&
        !_areTypesEquivalent(leftDescribes, rightDescribes!, seenPairs)) {
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
          leftGroupStart: leftGroupStart,
          rightGroupStart: rightGroupStart,
          recGroupSize: recGroupSize,
        )) {
          return false;
        }
      }
      for (var i = 0; i < left.resultTypeSignatures.length; i++) {
        if (!_areValueTypeSignaturesEquivalent(
          left.resultTypeSignatures[i],
          right.resultTypeSignatures[i],
          seenPairs,
          leftGroupStart: leftGroupStart,
          rightGroupStart: rightGroupStart,
          recGroupSize: recGroupSize,
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
            leftGroupStart: leftGroupStart,
            rightGroupStart: rightGroupStart,
            recGroupSize: recGroupSize,
          )) {
        return false;
      }
    }
    return true;
  }

  bool _areValueTypeSignaturesEquivalent(
    String lhs,
    String rhs,
    Set<String> seenPairs, {
    int? leftGroupStart,
    int? rightGroupStart,
    int? recGroupSize,
  }) {
    final leftRef = _parseRefSignature(lhs);
    final rightRef = _parseRefSignature(rhs);
    if (leftRef == null || rightRef == null) {
      return lhs == rhs;
    }
    if (leftRef.nullable != rightRef.nullable ||
        leftRef.exact != rightRef.exact) {
      return false;
    }
    final leftHeap = leftRef.heapType;
    final rightHeap = rightRef.heapType;
    if (leftHeap < 0 || rightHeap < 0) {
      return leftHeap == rightHeap;
    }
    if (leftGroupStart != null &&
        rightGroupStart != null &&
        recGroupSize != null) {
      final leftInGroup =
          leftHeap >= leftGroupStart &&
          leftHeap < leftGroupStart + recGroupSize;
      final rightInGroup =
          rightHeap >= rightGroupStart &&
          rightHeap < rightGroupStart + recGroupSize;
      if (leftInGroup || rightInGroup) {
        if (!leftInGroup || !rightInGroup) {
          return false;
        }
        if ((leftHeap - leftGroupStart) != (rightHeap - rightGroupStart)) {
          return false;
        }
        return true;
      }
    }
    if (leftHeap == rightHeap) {
      return true;
    }
    return _areTypesEquivalent(leftHeap, rightHeap, seenPairs);
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
      throw StateError(
        'type without descriptor requires non-descriptor allocation',
      );
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
      throw StateError(
        'type without descriptor requires non-descriptor allocation',
      );
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
    required bool allowPacked,
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
    if (!allowPacked && _isPackedStorageSignature(fieldSignature)) {
      throw StateError('struct.get requires unpacked field.');
    }
    final value = fields[fieldIndex];
    stack.add(_coerceLoadedFieldValue(fieldSignature, value, signed: signed));
  }

  void _gcStructSet(List<WasmValue> stack, Instruction instruction) {
    final expectedTypeIndex = _checkTypeIndex(instruction.immediate!);
    final fieldIndex = instruction.secondaryImmediate!;
    final value = _pop(stack);
    final reference = _popRef(stack);
    if (reference == null) {
      throw StateError('null reference');
    }
    final object = _requireGcObject(reference);
    if (object.kind != _GcRefKind.struct ||
        !_isTypeSubtype(object.typeIndex!, expectedTypeIndex)) {
      throw StateError('struct.set on incompatible reference.');
    }
    final fields = object.fields!;
    if (fieldIndex < 0 || fieldIndex >= fields.length) {
      throw StateError('Invalid struct field index: $fieldIndex');
    }
    final fieldSignature =
        _types[object.typeIndex!].fieldSignatures[fieldIndex];
    final parsedField = _parseFieldTypeForEquivalence(fieldSignature);
    if (parsedField == null) {
      throw StateError('Invalid struct field signature: $fieldSignature');
    }
    if (parsedField.mutability == 0) {
      throw StateError('immutable field');
    }
    fields[fieldIndex] = _coerceFieldValue(fieldSignature, value);
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
    final elementIndex = _checkElementSegmentIndex(
      instruction.secondaryImmediate!,
    );
    final type = _types[typeIndex];
    if (type.kind != WasmCompositeTypeKind.array) {
      throw StateError('array.new_elem requires an array type.');
    }
    final fieldSignature = type.fieldSignatures.single;
    final valueSignature = _parseFieldTypeForEquivalence(
      fieldSignature,
    )?.valueSignature;
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
    final parsedField = _parseFieldTypeForEquivalence(
      type.fieldSignatures.single,
    );
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
    final elementIndex = _checkElementSegmentIndex(
      instruction.secondaryImmediate!,
    );
    final type = _types[typeIndex];
    if (type.kind != WasmCompositeTypeKind.array) {
      throw StateError('array.init_elem requires an array type.');
    }
    final parsedField = _parseFieldTypeForEquivalence(
      type.fieldSignatures.single,
    );
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
    final parsedField = _parseFieldTypeForEquivalence(
      type.fieldSignatures.single,
    );
    if (parsedField == null || parsedField.mutability == 0) {
      throw StateError('immutable array');
    }

    final length = _popLength(stack);
    final fillValue = _coerceFieldValue(
      type.fieldSignatures.single,
      _pop(stack),
    );
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
    if (sourceOffset > segment.length ||
        length > segment.length - sourceOffset) {
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
      return WasmValue.i32(_canonicalI31Ref(segmentValue));
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
    final parsedField = _parseFieldTypeForEquivalence(
      type.fieldSignatures.single,
    );
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
    final existing = _sharedGcObjects[externReference];
    if (existing != null) {
      if (existing.kind == _GcRefKind.anyExtern) {
        _pushRef(stack, externReference);
        return;
      }
      if (existing.kind == _GcRefKind.extern) {
        _pushRef(stack, existing.externValue);
        return;
      }
    }
    _pushRef(stack, _allocateGcObject(_GcRefObject.anyExtern(externReference)));
  }

  void _gcExternConvertAny(List<WasmValue> stack) {
    final anyReference = _popRef(stack);
    if (anyReference == null) {
      _pushRef(stack, null);
      return;
    }
    final existing = _sharedGcObjects[anyReference];
    if (existing != null) {
      if (existing.kind == _GcRefKind.anyExtern) {
        _pushRef(stack, existing.externValue);
        return;
      }
      if (existing.kind == _GcRefKind.extern) {
        _pushRef(stack, anyReference);
        return;
      }
    }
    _pushRef(stack, _allocateGcObject(_GcRefObject.extern(anyReference)));
  }

  void _gcRefI31(List<WasmValue> stack) {
    final value = _popI32(stack) & 0x7fffffff;
    _pushRef(stack, _canonicalI31Ref(value));
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

  bool _isPackedStorageSignature(String valueSignature) {
    return valueSignature == '78' || valueSignature == '77';
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

  bool _functionTargetMatchesType(
    _FunctionRefTarget target,
    int targetTypeIndex, {
    required bool exact,
  }) {
    final targetType = _types[_checkTypeIndex(targetTypeIndex)];
    if (!targetType.isFunctionType) {
      return false;
    }

    final function = target.function;
    if (target.vm == this) {
      if (!function.isHost) {
        if (exact) {
          return _areTypesEquivalent(
            function.declaredTypeIndex,
            targetTypeIndex,
            <String>{},
          );
        }
        return _isTypeSubtype(function.declaredTypeIndex, targetTypeIndex);
      }
      return _functionTypeMatchesByDepth(
        actualTypeIndex: function.declaredTypeIndex,
        targetTypeIndex: targetTypeIndex,
        exact: exact,
        actualDepthOverride: function.runtimeTypeDepth,
      );
    }

    return _functionTypeEquals(function.type, targetType);
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

  int _loadV128(List<WasmValue> stack, Instruction instruction) {
    final memArg = instruction.memArg;
    if (memArg == null) {
      throw StateError('Missing memarg for opcode 0x${instruction.opcode}.');
    }
    final memory = _memoryForMemArg(instruction);
    final address = _addressFromStack(stack, instruction);
    return _internV128(memory.readBytes(address, 16));
  }

  void _storeV128(List<WasmValue> stack, Instruction instruction) {
    final bytes = _popV128Bytes(stack, opName: 'v128.store');
    final memArg = instruction.memArg;
    if (memArg == null) {
      throw StateError('Missing memarg for opcode 0x${instruction.opcode}.');
    }
    final memory = _memoryForMemArg(instruction);
    final address = _addressFromStack(stack, instruction);
    memory.writeBytes(address, bytes);
  }

  Uint8List _simdLoad8x8(
    List<WasmValue> stack,
    Instruction instruction, {
    required bool signed,
  }) {
    final memory = _memoryForMemArg(instruction);
    final address = _addressFromStack(stack, instruction);
    final result = Uint8List(16);
    final data = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final value = memory.loadU8(address + lane);
      final widened = signed ? value.toSigned(8) : value;
      data.setUint16(lane * 2, widened & 0xffff, Endian.little);
    }
    return result;
  }

  Uint8List _simdLoad16x4(
    List<WasmValue> stack,
    Instruction instruction, {
    required bool signed,
  }) {
    final memory = _memoryForMemArg(instruction);
    final address = _addressFromStack(stack, instruction);
    final result = Uint8List(16);
    final data = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final value = memory.loadU16(address + (lane * 2));
      final widened = signed ? value.toSigned(16) : value;
      data.setUint32(lane * 4, _toU32(widened), Endian.little);
    }
    return result;
  }

  Uint8List _simdLoad32x2(
    List<WasmValue> stack,
    Instruction instruction, {
    required bool signed,
  }) {
    final memory = _memoryForMemArg(instruction);
    final address = _addressFromStack(stack, instruction);
    final result = Uint8List(16);
    final data = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final laneOffset = address + (lane * 4);
      final value = signed
          ? WasmI64.signed(memory.loadI32(laneOffset))
          : BigInt.from(memory.loadU32(laneOffset));
      _writeLaneU64(data, lane * 8, value);
    }
    return result;
  }

  Uint8List _simdLoadSplat(
    List<WasmValue> stack,
    Instruction instruction, {
    required int laneWidth,
  }) {
    final memory = _memoryForMemArg(instruction);
    final address = _addressFromStack(stack, instruction);
    final laneBytes = memory.readBytes(address, laneWidth);
    final result = Uint8List(16);
    for (var offset = 0; offset < 16; offset += laneWidth) {
      result.setRange(offset, offset + laneWidth, laneBytes);
    }
    return result;
  }

  Uint8List _simdLoadZeroExtend(
    List<WasmValue> stack,
    Instruction instruction, {
    required int laneWidth,
  }) {
    final memory = _memoryForMemArg(instruction);
    final address = _addressFromStack(stack, instruction);
    final result = Uint8List(16);
    result.setRange(0, laneWidth, memory.readBytes(address, laneWidth));
    return result;
  }

  Uint8List _simdLoadLane(
    List<WasmValue> stack,
    Instruction instruction, {
    required int laneWidth,
    required int laneCount,
  }) {
    final lane = _requireSimdLane(
      instruction,
      laneCount: laneCount,
      opName: 'v128.load_lane',
    );
    final vector = _popV128Bytes(stack, opName: 'v128.load_lane');
    final result = Uint8List.fromList(vector);
    final memory = _memoryForMemArg(instruction);
    final address = _addressFromStack(stack, instruction);
    final laneOffset = lane * laneWidth;
    result.setRange(
      laneOffset,
      laneOffset + laneWidth,
      memory.readBytes(address, laneWidth),
    );
    return result;
  }

  void _simdStoreLane(
    List<WasmValue> stack,
    Instruction instruction, {
    required int laneWidth,
    required int laneCount,
  }) {
    final lane = _requireSimdLane(
      instruction,
      laneCount: laneCount,
      opName: 'v128.store_lane',
    );
    final vector = _popV128Bytes(stack, opName: 'v128.store_lane');
    final memory = _memoryForMemArg(instruction);
    final address = _addressFromStack(stack, instruction);
    final laneOffset = lane * laneWidth;
    memory.writeBytes(
      address,
      Uint8List.fromList(vector.sublist(laneOffset, laneOffset + laneWidth)),
    );
  }

  void _simdSplatI8x16(List<WasmValue> stack) {
    final lane = _popI32(stack) & 0xff;
    _pushV128Bytes(
      stack,
      Uint8List(16)..fillRange(0, 16, lane),
    );
  }

  void _simdSplatI16x8(List<WasmValue> stack) {
    final lane = _popI32(stack) & 0xffff;
    final result = Uint8List(16);
    final data = ByteData.sublistView(result);
    for (var i = 0; i < 8; i++) {
      data.setUint16(i * 2, lane, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdSplatI32x4(List<WasmValue> stack) {
    final lane = _toU32(_popI32(stack));
    final result = Uint8List(16);
    final data = ByteData.sublistView(result);
    for (var i = 0; i < 4; i++) {
      data.setUint32(i * 4, lane, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdSplatI64x2(List<WasmValue> stack) {
    final lane = _toU64(_popI64(stack));
    final result = Uint8List(16);
    final data = ByteData.sublistView(result);
    for (var i = 0; i < 2; i++) {
      _writeLaneU64(data, i * 8, lane);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdSplatF32x4(List<WasmValue> stack) {
    final lane = _popF32Bits(stack) & 0xffffffff;
    final result = Uint8List(16);
    final data = ByteData.sublistView(result);
    for (var i = 0; i < 4; i++) {
      data.setUint32(i * 4, lane, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdSplatF64x2(List<WasmValue> stack) {
    final lane = _popF64Bits(stack) & _u64MaskBigInt;
    final result = Uint8List(16);
    final data = ByteData.sublistView(result);
    for (var i = 0; i < 2; i++) {
      _writeLaneU64(data, i * 8, lane);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16Swizzle(List<WasmValue> stack) {
    final indices = _popV128Bytes(stack, opName: 'i8x16.swizzle');
    final source = _popV128Bytes(stack, opName: 'i8x16.swizzle');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      final index = indices[lane];
      result[lane] = index < 16 ? source[index] : 0;
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16Shuffle(
    List<WasmValue> stack, {
    required Instruction instruction,
  }) {
    final lanes = instruction.floatBytesImmediate;
    if (lanes == null || lanes.length != 16) {
      throw StateError('Malformed i8x16.shuffle immediate.');
    }
    final rhs = _popV128Bytes(stack, opName: 'i8x16.shuffle');
    final lhs = _popV128Bytes(stack, opName: 'i8x16.shuffle');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      final index = lanes[lane];
      result[lane] = index < 16 ? lhs[index] : rhs[index - 16];
    }
    _pushV128Bytes(stack, result);
  }

  void _simdExtractLaneI8x16(
    List<WasmValue> stack, {
    required bool signed,
    required Instruction instruction,
  }) {
    final lane = _requireSimdLane(instruction, laneCount: 16, opName: 'i8x16.extract_lane');
    final value = _popV128Bytes(stack, opName: 'i8x16.extract_lane')[lane];
    stack.add(WasmValue.i32(signed ? value.toSigned(8) : value));
  }

  void _simdExtractLaneI16x8(
    List<WasmValue> stack, {
    required bool signed,
    required Instruction instruction,
  }) {
    final lane = _requireSimdLane(
      instruction,
      laneCount: 8,
      opName: 'i16x8.extract_lane',
    );
    final bytes = _popV128Bytes(stack, opName: 'i16x8.extract_lane');
    final value = ByteData.sublistView(bytes).getUint16(lane * 2, Endian.little);
    stack.add(WasmValue.i32(signed ? value.toSigned(16) : value));
  }

  void _simdExtractLaneI32x4(
    List<WasmValue> stack, {
    required Instruction instruction,
  }) {
    final lane = _requireSimdLane(
      instruction,
      laneCount: 4,
      opName: 'i32x4.extract_lane',
    );
    final bytes = _popV128Bytes(stack, opName: 'i32x4.extract_lane');
    final value = ByteData.sublistView(bytes).getInt32(lane * 4, Endian.little);
    stack.add(WasmValue.i32(value));
  }

  void _simdExtractLaneI64x2(
    List<WasmValue> stack, {
    required Instruction instruction,
  }) {
    final lane = _requireSimdLane(
      instruction,
      laneCount: 2,
      opName: 'i64x2.extract_lane',
    );
    final bytes = _popV128Bytes(stack, opName: 'i64x2.extract_lane');
    final data = ByteData.sublistView(bytes);
    final offset = lane * 8;
    final low = data.getUint32(offset, Endian.little);
    final high = data.getUint32(offset + 4, Endian.little);
    stack.add(
      WasmValue.i64(
        WasmI64.fromU32PairSigned(low: low, high: high),
      ),
    );
  }

  void _simdExtractLaneF32x4(
    List<WasmValue> stack, {
    required Instruction instruction,
  }) {
    final lane = _requireSimdLane(
      instruction,
      laneCount: 4,
      opName: 'f32x4.extract_lane',
    );
    final bytes = _popV128Bytes(stack, opName: 'f32x4.extract_lane');
    final bits = ByteData.sublistView(bytes).getUint32(lane * 4, Endian.little);
    stack.add(WasmValue.f32Bits(bits));
  }

  void _simdExtractLaneF64x2(
    List<WasmValue> stack, {
    required Instruction instruction,
  }) {
    final lane = _requireSimdLane(
      instruction,
      laneCount: 2,
      opName: 'f64x2.extract_lane',
    );
    final bytes = _popV128Bytes(stack, opName: 'f64x2.extract_lane');
    final data = ByteData.sublistView(bytes);
    final offset = lane * 8;
    final low = data.getUint32(offset, Endian.little);
    final high = data.getUint32(offset + 4, Endian.little);
    stack.add(
      WasmValue.f64Bits(
        WasmI64.fromU32PairUnsigned(low: low, high: high),
      ),
    );
  }

  void _simdReplaceLaneI8x16(
    List<WasmValue> stack, {
    required Instruction instruction,
  }) {
    final lane = _requireSimdLane(
      instruction,
      laneCount: 16,
      opName: 'i8x16.replace_lane',
    );
    final value = _popI32(stack) & 0xff;
    final bytes = Uint8List.fromList(_popV128Bytes(stack, opName: 'i8x16.replace_lane'));
    bytes[lane] = value;
    _pushV128Bytes(stack, bytes);
  }

  void _simdReplaceLaneI16x8(
    List<WasmValue> stack, {
    required Instruction instruction,
  }) {
    final lane = _requireSimdLane(
      instruction,
      laneCount: 8,
      opName: 'i16x8.replace_lane',
    );
    final value = _popI32(stack) & 0xffff;
    final bytes = Uint8List.fromList(_popV128Bytes(stack, opName: 'i16x8.replace_lane'));
    ByteData.sublistView(bytes).setUint16(lane * 2, value, Endian.little);
    _pushV128Bytes(stack, bytes);
  }

  void _simdReplaceLaneI32x4(
    List<WasmValue> stack, {
    required Instruction instruction,
  }) {
    final lane = _requireSimdLane(
      instruction,
      laneCount: 4,
      opName: 'i32x4.replace_lane',
    );
    final value = _toU32(_popI32(stack));
    final bytes = Uint8List.fromList(_popV128Bytes(stack, opName: 'i32x4.replace_lane'));
    ByteData.sublistView(bytes).setUint32(lane * 4, value, Endian.little);
    _pushV128Bytes(stack, bytes);
  }

  void _simdReplaceLaneI64x2(
    List<WasmValue> stack, {
    required Instruction instruction,
  }) {
    final lane = _requireSimdLane(
      instruction,
      laneCount: 2,
      opName: 'i64x2.replace_lane',
    );
    final value = _toU64(_popI64(stack));
    final bytes = Uint8List.fromList(_popV128Bytes(stack, opName: 'i64x2.replace_lane'));
    final data = ByteData.sublistView(bytes);
    _writeLaneU64(data, lane * 8, value);
    _pushV128Bytes(stack, bytes);
  }

  void _simdReplaceLaneF32x4(
    List<WasmValue> stack, {
    required Instruction instruction,
  }) {
    final lane = _requireSimdLane(
      instruction,
      laneCount: 4,
      opName: 'f32x4.replace_lane',
    );
    final value = _popF32Bits(stack) & 0xffffffff;
    final bytes = Uint8List.fromList(_popV128Bytes(stack, opName: 'f32x4.replace_lane'));
    ByteData.sublistView(bytes).setUint32(lane * 4, value, Endian.little);
    _pushV128Bytes(stack, bytes);
  }

  void _simdReplaceLaneF64x2(
    List<WasmValue> stack, {
    required Instruction instruction,
  }) {
    final lane = _requireSimdLane(
      instruction,
      laneCount: 2,
      opName: 'f64x2.replace_lane',
    );
    final value = _popF64Bits(stack) & _u64MaskBigInt;
    final bytes = Uint8List.fromList(_popV128Bytes(stack, opName: 'f64x2.replace_lane'));
    final data = ByteData.sublistView(bytes);
    _writeLaneU64(data, lane * 8, value);
    _pushV128Bytes(stack, bytes);
  }

  void _simdV128Not(List<WasmValue> stack) {
    final operand = _popV128Bytes(stack, opName: 'v128.not');
    final result = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      result[i] = (~operand[i]) & 0xff;
    }
    _pushV128Bytes(stack, result);
  }

  void _simdV128And(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'v128.and');
    final lhs = _popV128Bytes(stack, opName: 'v128.and');
    final result = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      result[i] = lhs[i] & rhs[i];
    }
    _pushV128Bytes(stack, result);
  }

  void _simdV128Andnot(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'v128.andnot');
    final lhs = _popV128Bytes(stack, opName: 'v128.andnot');
    final result = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      result[i] = lhs[i] & ((~rhs[i]) & 0xff);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdV128Or(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'v128.or');
    final lhs = _popV128Bytes(stack, opName: 'v128.or');
    final result = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      result[i] = lhs[i] | rhs[i];
    }
    _pushV128Bytes(stack, result);
  }

  void _simdV128Xor(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'v128.xor');
    final lhs = _popV128Bytes(stack, opName: 'v128.xor');
    final result = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      result[i] = lhs[i] ^ rhs[i];
    }
    _pushV128Bytes(stack, result);
  }

  void _simdV128Bitselect(List<WasmValue> stack) {
    final mask = _popV128Bytes(stack, opName: 'v128.bitselect');
    final rhs = _popV128Bytes(stack, opName: 'v128.bitselect');
    final lhs = _popV128Bytes(stack, opName: 'v128.bitselect');
    final result = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      result[i] = (lhs[i] & mask[i]) | (rhs[i] & ((~mask[i]) & 0xff));
    }
    _pushV128Bytes(stack, result);
  }

  void _simdV128AnyTrue(List<WasmValue> stack) {
    final value = _popV128Bytes(stack, opName: 'v128.any_true');
    var anyTrue = 0;
    for (final byte in value) {
      if (byte != 0) {
        anyTrue = 1;
        break;
      }
    }
    stack.add(WasmValue.i32(anyTrue));
  }

  void _simdI8x16AllTrue(List<WasmValue> stack) {
    final value = _popV128Bytes(stack, opName: 'i8x16.all_true');
    var allTrue = 1;
    for (final lane in value) {
      if (lane == 0) {
        allTrue = 0;
        break;
      }
    }
    stack.add(WasmValue.i32(allTrue));
  }

  void _simdI16x8AllTrue(List<WasmValue> stack) {
    final value = _popV128Bytes(stack, opName: 'i16x8.all_true');
    final data = ByteData.sublistView(value);
    var allTrue = 1;
    for (var lane = 0; lane < 8; lane++) {
      if (data.getUint16(lane * 2, Endian.little) == 0) {
        allTrue = 0;
        break;
      }
    }
    stack.add(WasmValue.i32(allTrue));
  }

  void _simdI32x4AllTrue(List<WasmValue> stack) {
    final value = _popV128Bytes(stack, opName: 'i32x4.all_true');
    final data = ByteData.sublistView(value);
    var allTrue = 1;
    for (var lane = 0; lane < 4; lane++) {
      if (data.getUint32(lane * 4, Endian.little) == 0) {
        allTrue = 0;
        break;
      }
    }
    stack.add(WasmValue.i32(allTrue));
  }

  void _simdI64x2AllTrue(List<WasmValue> stack) {
    final value = _popV128Bytes(stack, opName: 'i64x2.all_true');
    final data = ByteData.sublistView(value);
    var allTrue = 1;
    for (var lane = 0; lane < 2; lane++) {
      if (_readLaneU64(data, lane * 8) == BigInt.zero) {
        allTrue = 0;
        break;
      }
    }
    stack.add(WasmValue.i32(allTrue));
  }

  void _simdI8x16Bitmask(List<WasmValue> stack) {
    final value = _popV128Bytes(stack, opName: 'i8x16.bitmask');
    var mask = 0;
    for (var lane = 0; lane < 16; lane++) {
      if ((value[lane] & 0x80) != 0) {
        mask |= (1 << lane);
      }
    }
    stack.add(WasmValue.i32(mask));
  }

  void _simdI16x8Bitmask(List<WasmValue> stack) {
    final value = _popV128Bytes(stack, opName: 'i16x8.bitmask');
    final data = ByteData.sublistView(value);
    var mask = 0;
    for (var lane = 0; lane < 8; lane++) {
      if ((data.getUint16(lane * 2, Endian.little) & 0x8000) != 0) {
        mask |= (1 << lane);
      }
    }
    stack.add(WasmValue.i32(mask));
  }

  void _simdI32x4Bitmask(List<WasmValue> stack) {
    final value = _popV128Bytes(stack, opName: 'i32x4.bitmask');
    final data = ByteData.sublistView(value);
    var mask = 0;
    for (var lane = 0; lane < 4; lane++) {
      if ((data.getUint32(lane * 4, Endian.little) & 0x80000000) != 0) {
        mask |= (1 << lane);
      }
    }
    stack.add(WasmValue.i32(mask));
  }

  void _simdI64x2Bitmask(List<WasmValue> stack) {
    final value = _popV128Bytes(stack, opName: 'i64x2.bitmask');
    final data = ByteData.sublistView(value);
    var mask = 0;
    final signBit = BigInt.one << 63;
    for (var lane = 0; lane < 2; lane++) {
      if ((_readLaneU64(data, lane * 8) & signBit) != BigInt.zero) {
        mask |= (1 << lane);
      }
    }
    stack.add(WasmValue.i32(mask));
  }

  void _simdI8x16Eq(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i8x16.eq');
    final lhs = _popV128Bytes(stack, opName: 'i8x16.eq');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      result[lane] = lhs[lane] == rhs[lane] ? 0xff : 0x00;
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16Ne(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i8x16.ne');
    final lhs = _popV128Bytes(stack, opName: 'i8x16.ne');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      result[lane] = lhs[lane] != rhs[lane] ? 0xff : 0x00;
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8Eq(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.eq');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.eq');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final laneEqual =
          lhsData.getUint16(offset, Endian.little) ==
          rhsData.getUint16(offset, Endian.little);
      resultData.setUint16(offset, laneEqual ? 0xffff : 0x0000, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8Ne(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.ne');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.ne');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final laneNe =
          lhsData.getUint16(offset, Endian.little) !=
          rhsData.getUint16(offset, Endian.little);
      resultData.setUint16(offset, laneNe ? 0xffff : 0x0000, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4Eq(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i32x4.eq');
    final lhs = _popV128Bytes(stack, opName: 'i32x4.eq');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final laneEqual =
          lhsData.getUint32(offset, Endian.little) ==
          rhsData.getUint32(offset, Endian.little);
      resultData.setUint32(
        offset,
        laneEqual ? 0xffffffff : 0x00000000,
        Endian.little,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4Ne(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i32x4.ne');
    final lhs = _popV128Bytes(stack, opName: 'i32x4.ne');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final laneNe =
          lhsData.getUint32(offset, Endian.little) !=
          rhsData.getUint32(offset, Endian.little);
      resultData.setUint32(
        offset,
        laneNe ? 0xffffffff : 0x00000000,
        Endian.little,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4Eq(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'f32x4.eq');
    final lhs = _popV128Bytes(stack, opName: 'f32x4.eq');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final lhsLane = lhsData.getFloat32(offset, Endian.little);
      final rhsLane = rhsData.getFloat32(offset, Endian.little);
      final laneEqual = lhsLane == rhsLane;
      resultData.setUint32(
        offset,
        laneEqual ? 0xffffffff : 0x00000000,
        Endian.little,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4Ne(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'f32x4.ne');
    final lhs = _popV128Bytes(stack, opName: 'f32x4.ne');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final lhsLane = lhsData.getFloat32(offset, Endian.little);
      final rhsLane = rhsData.getFloat32(offset, Endian.little);
      final laneNe = lhsLane != rhsLane;
      resultData.setUint32(
        offset,
        laneNe ? 0xffffffff : 0x00000000,
        Endian.little,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2Eq(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'f64x2.eq');
    final lhs = _popV128Bytes(stack, opName: 'f64x2.eq');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final lhsLane = lhsData.getFloat64(offset, Endian.little);
      final rhsLane = rhsData.getFloat64(offset, Endian.little);
      _writeLaneU64(
        resultData,
        offset,
        lhsLane == rhsLane ? _u64MaskBigInt : BigInt.zero,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2Ne(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'f64x2.ne');
    final lhs = _popV128Bytes(stack, opName: 'f64x2.ne');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final lhsLane = lhsData.getFloat64(offset, Endian.little);
      final rhsLane = rhsData.getFloat64(offset, Endian.little);
      _writeLaneU64(
        resultData,
        offset,
        lhsLane != rhsLane ? _u64MaskBigInt : BigInt.zero,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI64x2Eq(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i64x2.eq');
    final lhs = _popV128Bytes(stack, opName: 'i64x2.eq');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _writeLaneU64(
        resultData,
        offset,
        _readLaneU64(lhsData, offset) == _readLaneU64(rhsData, offset)
            ? _u64MaskBigInt
            : BigInt.zero,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16Compare(List<WasmValue> stack, {required int opcode}) {
    final rhs = _popV128Bytes(stack, opName: 'i8x16.compare');
    final lhs = _popV128Bytes(stack, opName: 'i8x16.compare');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      final aS = lhs[lane].toSigned(8);
      final bS = rhs[lane].toSigned(8);
      final aU = lhs[lane];
      final bU = rhs[lane];
      final matches = switch (opcode) {
        Opcodes.i8x16LtS => aS < bS,
        Opcodes.i8x16LtU => aU < bU,
        Opcodes.i8x16GtS => aS > bS,
        Opcodes.i8x16GtU => aU > bU,
        Opcodes.i8x16LeS => aS <= bS,
        Opcodes.i8x16LeU => aU <= bU,
        Opcodes.i8x16GeS => aS >= bS,
        Opcodes.i8x16GeU => aU >= bU,
        _ => throw StateError('Unsupported i8x16 compare opcode: $opcode'),
      };
      result[lane] = matches ? 0xff : 0x00;
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8Compare(List<WasmValue> stack, {required int opcode}) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.compare');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.compare');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final aS = lhsData.getInt16(offset, Endian.little);
      final bS = rhsData.getInt16(offset, Endian.little);
      final aU = lhsData.getUint16(offset, Endian.little);
      final bU = rhsData.getUint16(offset, Endian.little);
      final matches = switch (opcode) {
        Opcodes.i16x8LtS => aS < bS,
        Opcodes.i16x8LtU => aU < bU,
        Opcodes.i16x8GtS => aS > bS,
        Opcodes.i16x8GtU => aU > bU,
        Opcodes.i16x8LeS => aS <= bS,
        Opcodes.i16x8LeU => aU <= bU,
        Opcodes.i16x8GeS => aS >= bS,
        Opcodes.i16x8GeU => aU >= bU,
        _ => throw StateError('Unsupported i16x8 compare opcode: $opcode'),
      };
      resultData.setUint16(offset, matches ? 0xffff : 0x0000, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4Compare(List<WasmValue> stack, {required int opcode}) {
    final rhs = _popV128Bytes(stack, opName: 'i32x4.compare');
    final lhs = _popV128Bytes(stack, opName: 'i32x4.compare');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final aS = lhsData.getInt32(offset, Endian.little);
      final bS = rhsData.getInt32(offset, Endian.little);
      final aU = lhsData.getUint32(offset, Endian.little);
      final bU = rhsData.getUint32(offset, Endian.little);
      final matches = switch (opcode) {
        Opcodes.i32x4LtS => aS < bS,
        Opcodes.i32x4LtU => aU < bU,
        Opcodes.i32x4GtS => aS > bS,
        Opcodes.i32x4GtU => aU > bU,
        Opcodes.i32x4LeS => aS <= bS,
        Opcodes.i32x4LeU => aU <= bU,
        Opcodes.i32x4GeS => aS >= bS,
        Opcodes.i32x4GeU => aU >= bU,
        _ => throw StateError('Unsupported i32x4 compare opcode: $opcode'),
      };
      resultData.setUint32(
        offset,
        matches ? 0xffffffff : 0x00000000,
        Endian.little,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI64x2Compare(List<WasmValue> stack, {required int opcode}) {
    final rhs = _popV128Bytes(stack, opName: 'i64x2.compare');
    final lhs = _popV128Bytes(stack, opName: 'i64x2.compare');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final signBit = BigInt.one << 63;
    final wrap = BigInt.one << 64;
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      var a = _readLaneU64(lhsData, offset);
      var b = _readLaneU64(rhsData, offset);
      if ((a & signBit) != BigInt.zero) {
        a -= wrap;
      }
      if ((b & signBit) != BigInt.zero) {
        b -= wrap;
      }
      final matches = switch (opcode) {
        Opcodes.i64x2Ne => a != b,
        Opcodes.i64x2LtS => a < b,
        Opcodes.i64x2GtS => a > b,
        Opcodes.i64x2LeS => a <= b,
        Opcodes.i64x2GeS => a >= b,
        _ => throw StateError('Unsupported i64x2 compare opcode: $opcode'),
      };
      _writeLaneU64(
        resultData,
        offset,
        matches ? _u64MaskBigInt : BigInt.zero,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4Compare(List<WasmValue> stack, {required int opcode}) {
    final rhs = _popV128Bytes(stack, opName: 'f32x4.compare');
    final lhs = _popV128Bytes(stack, opName: 'f32x4.compare');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final a = lhsData.getFloat32(offset, Endian.little);
      final b = rhsData.getFloat32(offset, Endian.little);
      final matches = switch (opcode) {
        Opcodes.f32x4Lt => a < b,
        Opcodes.f32x4Gt => a > b,
        Opcodes.f32x4Le => a <= b,
        Opcodes.f32x4Ge => a >= b,
        _ => throw StateError('Unsupported f32x4 compare opcode: $opcode'),
      };
      resultData.setUint32(
        offset,
        matches ? 0xffffffff : 0x00000000,
        Endian.little,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2Compare(List<WasmValue> stack, {required int opcode}) {
    final rhs = _popV128Bytes(stack, opName: 'f64x2.compare');
    final lhs = _popV128Bytes(stack, opName: 'f64x2.compare');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final a = lhsData.getFloat64(offset, Endian.little);
      final b = rhsData.getFloat64(offset, Endian.little);
      final matches = switch (opcode) {
        Opcodes.f64x2Lt => a < b,
        Opcodes.f64x2Gt => a > b,
        Opcodes.f64x2Le => a <= b,
        Opcodes.f64x2Ge => a >= b,
        _ => throw StateError('Unsupported f64x2 compare opcode: $opcode'),
      };
      _writeLaneU64(
        resultData,
        offset,
        matches ? _u64MaskBigInt : BigInt.zero,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16ShrS(List<WasmValue> stack) {
    final shift = _popI32(stack) & 7;
    final value = _popV128Bytes(stack, opName: 'i8x16.shr_s');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      result[lane] = (value[lane].toSigned(8) >> shift) & 0xff;
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8ShrS(List<WasmValue> stack) {
    final shift = _popI32(stack) & 15;
    final value = _popV128Bytes(stack, opName: 'i16x8.shr_s');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final laneValue = valueData.getInt16(offset, Endian.little);
      resultData.setUint16(offset, (laneValue >> shift) & 0xffff, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4ShrS(List<WasmValue> stack) {
    final shift = _popI32(stack) & 31;
    final value = _popV128Bytes(stack, opName: 'i32x4.shr_s');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final laneValue = valueData.getInt32(offset, Endian.little);
      resultData.setUint32(offset, (laneValue >> shift) & 0xffffffff, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16Add(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i8x16.add');
    final lhs = _popV128Bytes(stack, opName: 'i8x16.add');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      result[lane] = (lhs[lane] + rhs[lane]) & 0xff;
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16NarrowI16x8S(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i8x16.narrow_i16x8_s');
    final lhs = _popV128Bytes(stack, opName: 'i8x16.narrow_i16x8_s');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    for (var lane = 0; lane < 8; lane++) {
      final left = lhsData.getInt16(lane * 2, Endian.little).clamp(-128, 127);
      final right = rhsData.getInt16(lane * 2, Endian.little).clamp(-128, 127);
      result[lane] = left & 0xff;
      result[lane + 8] = right & 0xff;
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16NarrowI16x8U(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i8x16.narrow_i16x8_u');
    final lhs = _popV128Bytes(stack, opName: 'i8x16.narrow_i16x8_u');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    for (var lane = 0; lane < 8; lane++) {
      final left = lhsData.getInt16(lane * 2, Endian.little).clamp(0, 255);
      final right = rhsData.getInt16(lane * 2, Endian.little).clamp(0, 255);
      result[lane] = left;
      result[lane + 8] = right;
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8NarrowI32x4S(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.narrow_i32x4_s');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.narrow_i32x4_s');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final left = lhsData.getInt32(lane * 4, Endian.little).clamp(-32768, 32767);
      final right = rhsData.getInt32(lane * 4, Endian.little).clamp(-32768, 32767);
      resultData.setUint16(lane * 2, left & 0xffff, Endian.little);
      resultData.setUint16((lane + 4) * 2, right & 0xffff, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8NarrowI32x4U(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.narrow_i32x4_u');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.narrow_i32x4_u');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final left = lhsData.getInt32(lane * 4, Endian.little).clamp(0, 65535);
      final right = rhsData.getInt32(lane * 4, Endian.little).clamp(0, 65535);
      resultData.setUint16(lane * 2, left, Endian.little);
      resultData.setUint16((lane + 4) * 2, right, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16AddSatS(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i8x16.add_sat_s');
    final lhs = _popV128Bytes(stack, opName: 'i8x16.add_sat_s');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      final sum = lhs[lane].toSigned(8) + rhs[lane].toSigned(8);
      final clamped = sum.clamp(-128, 127);
      result[lane] = clamped & 0xff;
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16Sub(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i8x16.sub');
    final lhs = _popV128Bytes(stack, opName: 'i8x16.sub');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      result[lane] = (lhs[lane] - rhs[lane]) & 0xff;
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16SubSatU(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i8x16.sub_sat_u');
    final lhs = _popV128Bytes(stack, opName: 'i8x16.sub_sat_u');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      final value = lhs[lane] - rhs[lane];
      result[lane] = value < 0 ? 0 : value;
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8Add(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.add');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.add');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final laneValue =
          lhsData.getUint16(offset, Endian.little) +
          rhsData.getUint16(offset, Endian.little);
      resultData.setUint16(offset, laneValue & 0xffff, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8AddSatS(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.add_sat_s');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.add_sat_s');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final sum =
          lhsData.getInt16(offset, Endian.little) +
          rhsData.getInt16(offset, Endian.little);
      final clamped = sum.clamp(-32768, 32767);
      resultData.setUint16(offset, clamped & 0xffff, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8Sub(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.sub');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.sub');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final laneValue =
          lhsData.getUint16(offset, Endian.little) -
          rhsData.getUint16(offset, Endian.little);
      resultData.setUint16(offset, laneValue & 0xffff, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8SubSatU(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.sub_sat_u');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.sub_sat_u');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final lhsLane = lhsData.getUint16(offset, Endian.little);
      final rhsLane = rhsData.getUint16(offset, Endian.little);
      final value = lhsLane - rhsLane;
      resultData.setUint16(offset, value < 0 ? 0 : value, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8Mul(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.mul');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.mul');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final laneValue =
          lhsData.getInt16(offset, Endian.little) *
          rhsData.getInt16(offset, Endian.little);
      resultData.setUint16(offset, laneValue & 0xffff, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4Add(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i32x4.add');
    final lhs = _popV128Bytes(stack, opName: 'i32x4.add');
    final lhsData = ByteData.sublistView(lhs);
    final rhsData = ByteData.sublistView(rhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final lhsLane = lhsData.getUint32(offset, Endian.little);
      final rhsLane = rhsData.getUint32(offset, Endian.little);
      resultData.setUint32(
        offset,
        (lhsLane + rhsLane) & 0xffffffff,
        Endian.little,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4Sub(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i32x4.sub');
    final lhs = _popV128Bytes(stack, opName: 'i32x4.sub');
    final lhsData = ByteData.sublistView(lhs);
    final rhsData = ByteData.sublistView(rhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final lhsLane = lhsData.getUint32(offset, Endian.little);
      final rhsLane = rhsData.getUint32(offset, Endian.little);
      resultData.setUint32(
        offset,
        (lhsLane - rhsLane) & 0xffffffff,
        Endian.little,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4Mul(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i32x4.mul');
    final lhs = _popV128Bytes(stack, opName: 'i32x4.mul');
    final lhsData = ByteData.sublistView(lhs);
    final rhsData = ByteData.sublistView(rhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final lhsLane = lhsData.getUint32(offset, Endian.little);
      final rhsLane = rhsData.getUint32(offset, Endian.little);
      resultData.setUint32(offset, _mulU32(lhsLane, rhsLane), Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI64x2Add(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i64x2.add');
    final lhs = _popV128Bytes(stack, opName: 'i64x2.add');
    final lhsData = ByteData.sublistView(lhs);
    final rhsData = ByteData.sublistView(rhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final lhsLane = _readLaneU64(lhsData, offset);
      final rhsLane = _readLaneU64(rhsData, offset);
      _writeLaneU64(resultData, offset, lhsLane + rhsLane);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI64x2Sub(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i64x2.sub');
    final lhs = _popV128Bytes(stack, opName: 'i64x2.sub');
    final lhsData = ByteData.sublistView(lhs);
    final rhsData = ByteData.sublistView(rhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final lhsLane = _readLaneU64(lhsData, offset);
      final rhsLane = _readLaneU64(rhsData, offset);
      _writeLaneU64(resultData, offset, lhsLane - rhsLane);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI64x2Mul(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i64x2.mul');
    final lhs = _popV128Bytes(stack, opName: 'i64x2.mul');
    final lhsData = ByteData.sublistView(lhs);
    final rhsData = ByteData.sublistView(rhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final lhsLane = _readLaneU64(lhsData, offset);
      final rhsLane = _readLaneU64(rhsData, offset);
      _writeLaneU64(resultData, offset, lhsLane * rhsLane);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4Abs(List<WasmValue> stack) {
    final value = _popV128Bytes(stack, opName: 'f32x4.abs');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final bits = valueData.getUint32(offset, Endian.little);
      resultData.setUint32(offset, bits & 0x7fffffff, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4Div(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'f32x4.div');
    final lhs = _popV128Bytes(stack, opName: 'f32x4.div');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final lhsLane = lhsData.getFloat32(offset, Endian.little);
      final rhsLane = rhsData.getFloat32(offset, Endian.little);
      _setF32LaneCanonical(resultData, offset, lhsLane / rhsLane);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4Min(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'f32x4.min');
    final lhs = _popV128Bytes(stack, opName: 'f32x4.min');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final lhsLane = lhsData.getFloat32(offset, Endian.little);
      final rhsLane = rhsData.getFloat32(offset, Endian.little);
      _setF32LaneCanonical(resultData, offset, _fMin(lhsLane, rhsLane));
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2Add(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'f64x2.add');
    final lhs = _popV128Bytes(stack, opName: 'f64x2.add');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _setF64LaneCanonical(
        resultData,
        offset,
        lhsData.getFloat64(offset, Endian.little) +
            rhsData.getFloat64(offset, Endian.little),
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2Sub(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'f64x2.sub');
    final lhs = _popV128Bytes(stack, opName: 'f64x2.sub');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _setF64LaneCanonical(
        resultData,
        offset,
        lhsData.getFloat64(offset, Endian.little) -
            rhsData.getFloat64(offset, Endian.little),
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2Mul(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'f64x2.mul');
    final lhs = _popV128Bytes(stack, opName: 'f64x2.mul');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _setF64LaneCanonical(
        resultData,
        offset,
        lhsData.getFloat64(offset, Endian.little) *
            rhsData.getFloat64(offset, Endian.little),
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4RelaxedMadd(List<WasmValue> stack) {
    final addend = _popV128Bytes(stack, opName: 'f32x4.relaxed_madd');
    final rhs = _popV128Bytes(stack, opName: 'f32x4.relaxed_madd');
    final lhs = _popV128Bytes(stack, opName: 'f32x4.relaxed_madd');
    final addendData = ByteData.sublistView(addend);
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final value =
          (lhsData.getFloat32(offset, Endian.little) *
              rhsData.getFloat32(offset, Endian.little)) +
          addendData.getFloat32(offset, Endian.little);
      _setF32LaneCanonical(resultData, offset, value);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4RelaxedNmadd(List<WasmValue> stack) {
    final addend = _popV128Bytes(stack, opName: 'f32x4.relaxed_nmadd');
    final rhs = _popV128Bytes(stack, opName: 'f32x4.relaxed_nmadd');
    final lhs = _popV128Bytes(stack, opName: 'f32x4.relaxed_nmadd');
    final addendData = ByteData.sublistView(addend);
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final value =
          -(lhsData.getFloat32(offset, Endian.little) *
              rhsData.getFloat32(offset, Endian.little)) +
          addendData.getFloat32(offset, Endian.little);
      _setF32LaneCanonical(resultData, offset, value);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2RelaxedMadd(List<WasmValue> stack) {
    final addend = _popV128Bytes(stack, opName: 'f64x2.relaxed_madd');
    final rhs = _popV128Bytes(stack, opName: 'f64x2.relaxed_madd');
    final lhs = _popV128Bytes(stack, opName: 'f64x2.relaxed_madd');
    final addendData = ByteData.sublistView(addend);
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final value =
          (lhsData.getFloat64(offset, Endian.little) *
              rhsData.getFloat64(offset, Endian.little)) +
          addendData.getFloat64(offset, Endian.little);
      _setF64LaneCanonical(resultData, offset, value);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2RelaxedNmadd(List<WasmValue> stack) {
    final addend = _popV128Bytes(stack, opName: 'f64x2.relaxed_nmadd');
    final rhs = _popV128Bytes(stack, opName: 'f64x2.relaxed_nmadd');
    final lhs = _popV128Bytes(stack, opName: 'f64x2.relaxed_nmadd');
    final addendData = ByteData.sublistView(addend);
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final value =
          -(lhsData.getFloat64(offset, Endian.little) *
              rhsData.getFloat64(offset, Endian.little)) +
          addendData.getFloat64(offset, Endian.little);
      _setF64LaneCanonical(resultData, offset, value);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4ConvertI32x4S(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'f32x4.convert_i32x4_s');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      resultData.setFloat32(
        offset,
        inputData.getInt32(offset, Endian.little).toDouble(),
        Endian.little,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4TruncSatF32x4S(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i32x4.trunc_sat_f32x4_s');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final laneValue = _truncSatToI32S(inputData.getFloat32(offset, Endian.little));
      resultData.setUint32(offset, _toU32(laneValue), Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16Shl(List<WasmValue> stack) {
    final shift = _popI32(stack) & 7;
    final value = _popV128Bytes(stack, opName: 'i8x16.shl');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      result[lane] = (value[lane] << shift) & 0xff;
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16ShrU(List<WasmValue> stack) {
    final shift = _popI32(stack) & 7;
    final value = _popV128Bytes(stack, opName: 'i8x16.shr_u');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      result[lane] = (value[lane] >> shift) & 0xff;
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8Shl(List<WasmValue> stack) {
    final shift = _popI32(stack) & 15;
    final value = _popV128Bytes(stack, opName: 'i16x8.shl');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      resultData.setUint16(
        offset,
        (valueData.getUint16(offset, Endian.little) << shift) & 0xffff,
        Endian.little,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8ShrU(List<WasmValue> stack) {
    final shift = _popI32(stack) & 15;
    final value = _popV128Bytes(stack, opName: 'i16x8.shr_u');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      resultData.setUint16(
        offset,
        valueData.getUint16(offset, Endian.little) >> shift,
        Endian.little,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4Shl(List<WasmValue> stack) {
    final shift = _popI32(stack) & 31;
    final value = _popV128Bytes(stack, opName: 'i32x4.shl');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      resultData.setUint32(
        offset,
        (valueData.getUint32(offset, Endian.little) << shift) & 0xffffffff,
        Endian.little,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4ShrU(List<WasmValue> stack) {
    final shift = _popI32(stack) & 31;
    final value = _popV128Bytes(stack, opName: 'i32x4.shr_u');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      resultData.setUint32(
        offset,
        valueData.getUint32(offset, Endian.little) >> shift,
        Endian.little,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI64x2Shl(List<WasmValue> stack) {
    final shift = _popI32(stack) & 63;
    final value = _popV128Bytes(stack, opName: 'i64x2.shl');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _writeLaneU64(resultData, offset, _readLaneU64(valueData, offset) << shift);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI64x2ShrS(List<WasmValue> stack) {
    final shift = _popI32(stack) & 63;
    final value = _popV128Bytes(stack, opName: 'i64x2.shr_s');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    final signBit = BigInt.one << 63;
    final wrap = BigInt.one << 64;
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      var laneValue = _readLaneU64(valueData, offset);
      if ((laneValue & signBit) != BigInt.zero) {
        laneValue -= wrap;
      }
      _writeLaneU64(resultData, offset, laneValue >> shift);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI64x2ShrU(List<WasmValue> stack) {
    final shift = _popI32(stack) & 63;
    final value = _popV128Bytes(stack, opName: 'i64x2.shr_u');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _writeLaneU64(resultData, offset, _readLaneU64(valueData, offset) >> shift);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16Abs(List<WasmValue> stack) {
    final value = _popV128Bytes(stack, opName: 'i8x16.abs');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      result[lane] = value[lane].toSigned(8).abs() & 0xff;
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16Neg(List<WasmValue> stack) {
    final value = _popV128Bytes(stack, opName: 'i8x16.neg');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      result[lane] = (-value[lane].toSigned(8)) & 0xff;
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16Popcnt(List<WasmValue> stack) {
    final value = _popV128Bytes(stack, opName: 'i8x16.popcnt');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      var v = value[lane];
      var count = 0;
      while (v != 0) {
        count += v & 1;
        v >>= 1;
      }
      result[lane] = count;
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16AddSatU(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i8x16.add_sat_u');
    final lhs = _popV128Bytes(stack, opName: 'i8x16.add_sat_u');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      final sum = lhs[lane] + rhs[lane];
      result[lane] = sum > 255 ? 255 : sum;
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16SubSatS(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i8x16.sub_sat_s');
    final lhs = _popV128Bytes(stack, opName: 'i8x16.sub_sat_s');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      final diff = lhs[lane].toSigned(8) - rhs[lane].toSigned(8);
      result[lane] = diff.clamp(-128, 127) & 0xff;
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16MinS(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i8x16.min_s');
    final lhs = _popV128Bytes(stack, opName: 'i8x16.min_s');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      final a = lhs[lane].toSigned(8);
      final b = rhs[lane].toSigned(8);
      result[lane] = (a < b ? a : b) & 0xff;
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16MinU(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i8x16.min_u');
    final lhs = _popV128Bytes(stack, opName: 'i8x16.min_u');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      result[lane] = lhs[lane] < rhs[lane] ? lhs[lane] : rhs[lane];
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16MaxS(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i8x16.max_s');
    final lhs = _popV128Bytes(stack, opName: 'i8x16.max_s');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      final a = lhs[lane].toSigned(8);
      final b = rhs[lane].toSigned(8);
      result[lane] = (a > b ? a : b) & 0xff;
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16MaxU(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i8x16.max_u');
    final lhs = _popV128Bytes(stack, opName: 'i8x16.max_u');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      result[lane] = lhs[lane] > rhs[lane] ? lhs[lane] : rhs[lane];
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI8x16AvgrU(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i8x16.avgr_u');
    final lhs = _popV128Bytes(stack, opName: 'i8x16.avgr_u');
    final result = Uint8List(16);
    for (var lane = 0; lane < 16; lane++) {
      result[lane] = (lhs[lane] + rhs[lane] + 1) >> 1;
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8Abs(List<WasmValue> stack) {
    final value = _popV128Bytes(stack, opName: 'i16x8.abs');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final laneValue = valueData.getInt16(lane * 2, Endian.little).abs();
      resultData.setUint16(lane * 2, laneValue & 0xffff, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8Neg(List<WasmValue> stack) {
    final value = _popV128Bytes(stack, opName: 'i16x8.neg');
    final valueData = ByteData.sublistView(value);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final laneValue = -valueData.getInt16(lane * 2, Endian.little);
      resultData.setUint16(lane * 2, laneValue & 0xffff, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8AddSatU(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.add_sat_u');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.add_sat_u');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final sum =
          lhsData.getUint16(offset, Endian.little) +
          rhsData.getUint16(offset, Endian.little);
      resultData.setUint16(offset, sum > 0xffff ? 0xffff : sum, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8SubSatS(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.sub_sat_s');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.sub_sat_s');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final diff =
          lhsData.getInt16(offset, Endian.little) -
          rhsData.getInt16(offset, Endian.little);
      resultData.setUint16(
        offset,
        diff.clamp(-32768, 32767) & 0xffff,
        Endian.little,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8MinS(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.min_s');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.min_s');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final a = lhsData.getInt16(offset, Endian.little);
      final b = rhsData.getInt16(offset, Endian.little);
      resultData.setUint16(offset, (a < b ? a : b) & 0xffff, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8MinU(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.min_u');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.min_u');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final a = lhsData.getUint16(offset, Endian.little);
      final b = rhsData.getUint16(offset, Endian.little);
      resultData.setUint16(offset, a < b ? a : b, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8MaxS(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.max_s');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.max_s');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final a = lhsData.getInt16(offset, Endian.little);
      final b = rhsData.getInt16(offset, Endian.little);
      resultData.setUint16(offset, (a > b ? a : b) & 0xffff, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8MaxU(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.max_u');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.max_u');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final a = lhsData.getUint16(offset, Endian.little);
      final b = rhsData.getUint16(offset, Endian.little);
      resultData.setUint16(offset, a > b ? a : b, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8AvgrU(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.avgr_u');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.avgr_u');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final avg =
          lhsData.getUint16(offset, Endian.little) +
          rhsData.getUint16(offset, Endian.little) +
          1;
      resultData.setUint16(offset, avg >> 1, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8Q15MulrSatS(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.q15mulr_sat_s');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.q15mulr_sat_s');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    final min = BigInt.from(-32768);
    final max = BigInt.from(32767);
    final roundingBias = BigInt.from(0x4000);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final product =
          BigInt.from(lhsData.getInt16(offset, Endian.little)) *
          BigInt.from(rhsData.getInt16(offset, Endian.little));
      final rounded = (product + roundingBias) >> 15;
      var clamped = rounded;
      if (clamped < min) {
        clamped = min;
      } else if (clamped > max) {
        clamped = max;
      }
      resultData.setUint16(
        offset,
        clamped.toInt() & 0xffff,
        Endian.little,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8ExtAddPairwiseI8x16S(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i16x8.extadd_pairwise_i8x16_s');
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final a = input[lane * 2].toSigned(8);
      final b = input[(lane * 2) + 1].toSigned(8);
      resultData.setUint16(lane * 2, (a + b) & 0xffff, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8ExtAddPairwiseI8x16U(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i16x8.extadd_pairwise_i8x16_u');
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final a = input[lane * 2];
      final b = input[(lane * 2) + 1];
      resultData.setUint16(lane * 2, (a + b) & 0xffff, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8ExtendHighI8x16S(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i16x8.extend_high_i8x16_s');
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      resultData.setUint16(
        lane * 2,
        input[8 + lane].toSigned(8) & 0xffff,
        Endian.little,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8ExtendLowI8x16S(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i16x8.extend_low_i8x16_s');
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      resultData.setUint16(
        lane * 2,
        input[lane].toSigned(8) & 0xffff,
        Endian.little,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8ExtendHighI8x16U(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i16x8.extend_high_i8x16_u');
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      resultData.setUint16(lane * 2, input[8 + lane], Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8ExtendLowI8x16U(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i16x8.extend_low_i8x16_u');
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      resultData.setUint16(lane * 2, input[lane], Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8ExtmulLowI8x16S(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.extmul_low_i8x16_s');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.extmul_low_i8x16_s');
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final value = lhs[lane].toSigned(8) * rhs[lane].toSigned(8);
      resultData.setUint16(lane * 2, value & 0xffff, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8ExtmulHighI8x16S(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.extmul_high_i8x16_s');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.extmul_high_i8x16_s');
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final value = lhs[8 + lane].toSigned(8) * rhs[8 + lane].toSigned(8);
      resultData.setUint16(lane * 2, value & 0xffff, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8ExtmulLowI8x16U(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.extmul_low_i8x16_u');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.extmul_low_i8x16_u');
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final value = lhs[lane] * rhs[lane];
      resultData.setUint16(lane * 2, value & 0xffff, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8ExtmulHighI8x16U(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.extmul_high_i8x16_u');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.extmul_high_i8x16_u');
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final value = lhs[8 + lane] * rhs[8 + lane];
      resultData.setUint16(lane * 2, value & 0xffff, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4ExtAddPairwiseI16x8S(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i32x4.extadd_pairwise_i16x8_s');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final a = inputData.getInt16(lane * 4, Endian.little);
      final b = inputData.getInt16((lane * 4) + 2, Endian.little);
      resultData.setUint32(lane * 4, _toU32(a + b), Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4ExtAddPairwiseI16x8U(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i32x4.extadd_pairwise_i16x8_u');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final a = inputData.getUint16(lane * 4, Endian.little);
      final b = inputData.getUint16((lane * 4) + 2, Endian.little);
      resultData.setUint32(lane * 4, (a + b) & 0xffffffff, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4ExtendLowI16x8S(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i32x4.extend_low_i16x8_s');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      resultData.setUint32(
        lane * 4,
        _toU32(inputData.getInt16(lane * 2, Endian.little)),
        Endian.little,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4ExtendHighI16x8S(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i32x4.extend_high_i16x8_s');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      resultData.setUint32(
        lane * 4,
        _toU32(inputData.getInt16((lane + 4) * 2, Endian.little)),
        Endian.little,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4ExtendLowI16x8U(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i32x4.extend_low_i16x8_u');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      resultData.setUint32(
        lane * 4,
        inputData.getUint16(lane * 2, Endian.little),
        Endian.little,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4ExtendHighI16x8U(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i32x4.extend_high_i16x8_u');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      resultData.setUint32(
        lane * 4,
        inputData.getUint16((lane + 4) * 2, Endian.little),
        Endian.little,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4Abs(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i32x4.abs');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final value = inputData.getInt32(lane * 4, Endian.little).abs();
      resultData.setUint32(lane * 4, _toU32(value), Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4Neg(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i32x4.neg');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final value = -inputData.getInt32(lane * 4, Endian.little);
      resultData.setUint32(lane * 4, _toU32(value), Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4MinS(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i32x4.min_s');
    final lhs = _popV128Bytes(stack, opName: 'i32x4.min_s');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final a = lhsData.getInt32(lane * 4, Endian.little);
      final b = rhsData.getInt32(lane * 4, Endian.little);
      resultData.setUint32(lane * 4, _toU32(a < b ? a : b), Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4MinU(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i32x4.min_u');
    final lhs = _popV128Bytes(stack, opName: 'i32x4.min_u');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final a = lhsData.getUint32(lane * 4, Endian.little);
      final b = rhsData.getUint32(lane * 4, Endian.little);
      resultData.setUint32(lane * 4, a < b ? a : b, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4MaxS(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i32x4.max_s');
    final lhs = _popV128Bytes(stack, opName: 'i32x4.max_s');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final a = lhsData.getInt32(lane * 4, Endian.little);
      final b = rhsData.getInt32(lane * 4, Endian.little);
      resultData.setUint32(lane * 4, _toU32(a > b ? a : b), Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4MaxU(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i32x4.max_u');
    final lhs = _popV128Bytes(stack, opName: 'i32x4.max_u');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final a = lhsData.getUint32(lane * 4, Endian.little);
      final b = rhsData.getUint32(lane * 4, Endian.little);
      resultData.setUint32(lane * 4, a > b ? a : b, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4DotI16x8S(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i32x4.dot_i16x8_s');
    final lhs = _popV128Bytes(stack, opName: 'i32x4.dot_i16x8_s');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final a0 = lhsData.getInt16(offset, Endian.little);
      final a1 = lhsData.getInt16(offset + 2, Endian.little);
      final b0 = rhsData.getInt16(offset, Endian.little);
      final b1 = rhsData.getInt16(offset + 2, Endian.little);
      final value = (a0 * b0) + (a1 * b1);
      resultData.setUint32(offset, _toU32(value), Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI16x8RelaxedDotI8x16I7x16S(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i16x8.relaxed_dot_i8x16_i7x16_s');
    final lhs = _popV128Bytes(stack, opName: 'i16x8.relaxed_dot_i8x16_i7x16_s');
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 8; lane++) {
      final offset = lane * 2;
      final a0 = lhs[offset].toSigned(8);
      final a1 = lhs[offset + 1].toSigned(8);
      final b0 = rhs[offset].toSigned(8);
      final b1 = rhs[offset + 1].toSigned(8);
      final value = (a0 * b0) + (a1 * b1);
      resultData.setUint16(lane * 2, value & 0xffff, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4RelaxedDotI8x16I7x16AddS(List<WasmValue> stack) {
    final addend = _popV128Bytes(
      stack,
      opName: 'i32x4.relaxed_dot_i8x16_i7x16_add_s',
    );
    final rhs = _popV128Bytes(stack, opName: 'i32x4.relaxed_dot_i8x16_i7x16_add_s');
    final lhs = _popV128Bytes(stack, opName: 'i32x4.relaxed_dot_i8x16_i7x16_add_s');
    final addendData = ByteData.sublistView(addend);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final byteOffset = lane * 4;
      var dot = 0;
      for (var i = 0; i < 4; i++) {
        dot += lhs[byteOffset + i].toSigned(8) * rhs[byteOffset + i].toSigned(8);
      }
      final value = addendData.getInt32(lane * 4, Endian.little) + dot;
      resultData.setUint32(lane * 4, _toU32(value), Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4ExtmulLowI16x8S(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i32x4.extmul_low_i16x8_s');
    final lhs = _popV128Bytes(stack, opName: 'i32x4.extmul_low_i16x8_s');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final a = lhsData.getInt16(lane * 2, Endian.little);
      final b = rhsData.getInt16(lane * 2, Endian.little);
      resultData.setUint32(lane * 4, _toU32(a * b), Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4ExtmulHighI16x8S(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i32x4.extmul_high_i16x8_s');
    final lhs = _popV128Bytes(stack, opName: 'i32x4.extmul_high_i16x8_s');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final a = lhsData.getInt16((lane + 4) * 2, Endian.little);
      final b = rhsData.getInt16((lane + 4) * 2, Endian.little);
      resultData.setUint32(lane * 4, _toU32(a * b), Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4ExtmulLowI16x8U(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i32x4.extmul_low_i16x8_u');
    final lhs = _popV128Bytes(stack, opName: 'i32x4.extmul_low_i16x8_u');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final a = lhsData.getUint16(lane * 2, Endian.little);
      final b = rhsData.getUint16(lane * 2, Endian.little);
      resultData.setUint32(lane * 4, (a * b) & 0xffffffff, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4ExtmulHighI16x8U(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i32x4.extmul_high_i16x8_u');
    final lhs = _popV128Bytes(stack, opName: 'i32x4.extmul_high_i16x8_u');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final a = lhsData.getUint16((lane + 4) * 2, Endian.little);
      final b = rhsData.getUint16((lane + 4) * 2, Endian.little);
      resultData.setUint32(lane * 4, (a * b) & 0xffffffff, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI64x2Abs(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i64x2.abs');
    final inputData = ByteData.sublistView(input);
    final signBit = BigInt.one << 63;
    final wrap = BigInt.one << 64;
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      var value = _readLaneU64(inputData, offset);
      if ((value & signBit) != BigInt.zero) {
        value -= wrap;
      }
      _writeLaneU64(resultData, offset, value.abs());
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI64x2Neg(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i64x2.neg');
    final inputData = ByteData.sublistView(input);
    final signBit = BigInt.one << 63;
    final wrap = BigInt.one << 64;
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      var value = _readLaneU64(inputData, offset);
      if ((value & signBit) != BigInt.zero) {
        value -= wrap;
      }
      _writeLaneU64(resultData, offset, -value);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI64x2ExtendLowI32x4S(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i64x2.extend_low_i32x4_s');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final value = inputData.getInt32(lane * 4, Endian.little);
      _writeLaneU64(resultData, lane * 8, WasmI64.signed(value));
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI64x2ExtendHighI32x4S(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i64x2.extend_high_i32x4_s');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final value = inputData.getInt32((lane + 2) * 4, Endian.little);
      _writeLaneU64(resultData, lane * 8, WasmI64.signed(value));
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI64x2ExtendLowI32x4U(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i64x2.extend_low_i32x4_u');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final value = BigInt.from(inputData.getUint32(lane * 4, Endian.little));
      _writeLaneU64(resultData, lane * 8, value);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI64x2ExtendHighI32x4U(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i64x2.extend_high_i32x4_u');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final value = BigInt.from(inputData.getUint32((lane + 2) * 4, Endian.little));
      _writeLaneU64(resultData, lane * 8, value);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI64x2ExtmulLowI32x4S(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i64x2.extmul_low_i32x4_s');
    final lhs = _popV128Bytes(stack, opName: 'i64x2.extmul_low_i32x4_s');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final a = lhsData.getInt32(lane * 4, Endian.little);
      final b = rhsData.getInt32(lane * 4, Endian.little);
      _writeLaneU64(
        resultData,
        lane * 8,
        WasmI64.signed(BigInt.from(a) * BigInt.from(b)),
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI64x2ExtmulHighI32x4S(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i64x2.extmul_high_i32x4_s');
    final lhs = _popV128Bytes(stack, opName: 'i64x2.extmul_high_i32x4_s');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final a = lhsData.getInt32((lane + 2) * 4, Endian.little);
      final b = rhsData.getInt32((lane + 2) * 4, Endian.little);
      _writeLaneU64(
        resultData,
        lane * 8,
        WasmI64.signed(BigInt.from(a) * BigInt.from(b)),
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI64x2ExtmulLowI32x4U(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i64x2.extmul_low_i32x4_u');
    final lhs = _popV128Bytes(stack, opName: 'i64x2.extmul_low_i32x4_u');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final a = BigInt.from(lhsData.getUint32(lane * 4, Endian.little));
      final b = BigInt.from(rhsData.getUint32(lane * 4, Endian.little));
      _writeLaneU64(resultData, lane * 8, a * b);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI64x2ExtmulHighI32x4U(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'i64x2.extmul_high_i32x4_u');
    final lhs = _popV128Bytes(stack, opName: 'i64x2.extmul_high_i32x4_u');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final a = BigInt.from(lhsData.getUint32((lane + 2) * 4, Endian.little));
      final b = BigInt.from(rhsData.getUint32((lane + 2) * 4, Endian.little));
      _writeLaneU64(resultData, lane * 8, a * b);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4Ceil(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'f32x4.ceil');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final value = inputData.getFloat32(lane * 4, Endian.little);
      _setF32LaneCanonical(resultData, lane * 4, value.ceilToDouble());
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4Floor(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'f32x4.floor');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final value = inputData.getFloat32(lane * 4, Endian.little);
      _setF32LaneCanonical(resultData, lane * 4, value.floorToDouble());
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4Trunc(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'f32x4.trunc');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final value = inputData.getFloat32(lane * 4, Endian.little);
      _setF32LaneCanonical(resultData, lane * 4, value.truncateToDouble());
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4Nearest(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'f32x4.nearest');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final value = inputData.getFloat32(lane * 4, Endian.little);
      _setF32LaneCanonical(resultData, lane * 4, _nearest(value));
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4Neg(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'f32x4.neg');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final bits = inputData.getUint32(lane * 4, Endian.little);
      resultData.setUint32(lane * 4, bits ^ 0x80000000, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4Sqrt(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'f32x4.sqrt');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      _setF32LaneCanonical(
        resultData,
        offset,
        math.sqrt(inputData.getFloat32(offset, Endian.little)),
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4Add(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'f32x4.add');
    final lhs = _popV128Bytes(stack, opName: 'f32x4.add');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      _setF32LaneCanonical(
        resultData,
        offset,
        lhsData.getFloat32(offset, Endian.little) +
            rhsData.getFloat32(offset, Endian.little),
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4Sub(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'f32x4.sub');
    final lhs = _popV128Bytes(stack, opName: 'f32x4.sub');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      _setF32LaneCanonical(
        resultData,
        offset,
        lhsData.getFloat32(offset, Endian.little) -
            rhsData.getFloat32(offset, Endian.little),
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4Mul(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'f32x4.mul');
    final lhs = _popV128Bytes(stack, opName: 'f32x4.mul');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      _setF32LaneCanonical(
        resultData,
        offset,
        lhsData.getFloat32(offset, Endian.little) *
            rhsData.getFloat32(offset, Endian.little),
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4Max(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'f32x4.max');
    final lhs = _popV128Bytes(stack, opName: 'f32x4.max');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final lhsLane = lhsData.getFloat32(offset, Endian.little);
      final rhsLane = rhsData.getFloat32(offset, Endian.little);
      _setF32LaneCanonical(resultData, offset, _fMax(lhsLane, rhsLane));
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4Pmin(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'f32x4.pmin');
    final lhs = _popV128Bytes(stack, opName: 'f32x4.pmin');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final lhsBits = lhsData.getUint32(offset, Endian.little);
      final rhsBits = rhsData.getUint32(offset, Endian.little);
      if (_isF32NaNBits(lhsBits) || _isF32NaNBits(rhsBits)) {
        resultData.setUint32(offset, lhsBits, Endian.little);
        continue;
      }
      final lhsLane = lhsData.getFloat32(offset, Endian.little);
      final rhsLane = rhsData.getFloat32(offset, Endian.little);
      if (lhsLane < rhsLane) {
        resultData.setUint32(offset, lhsBits, Endian.little);
      } else if (lhsLane > rhsLane) {
        resultData.setUint32(offset, rhsBits, Endian.little);
      } else {
        resultData.setUint32(offset, lhsBits, Endian.little);
      }
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4Pmax(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'f32x4.pmax');
    final lhs = _popV128Bytes(stack, opName: 'f32x4.pmax');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final lhsBits = lhsData.getUint32(offset, Endian.little);
      final rhsBits = rhsData.getUint32(offset, Endian.little);
      if (_isF32NaNBits(lhsBits) || _isF32NaNBits(rhsBits)) {
        resultData.setUint32(offset, lhsBits, Endian.little);
        continue;
      }
      final lhsLane = lhsData.getFloat32(offset, Endian.little);
      final rhsLane = rhsData.getFloat32(offset, Endian.little);
      if (lhsLane > rhsLane) {
        resultData.setUint32(offset, lhsBits, Endian.little);
      } else if (lhsLane < rhsLane) {
        resultData.setUint32(offset, rhsBits, Endian.little);
      } else {
        resultData.setUint32(offset, lhsBits, Endian.little);
      }
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2Ceil(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'f64x2.ceil');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _setF64LaneCanonical(
        resultData,
        offset,
        inputData.getFloat64(offset, Endian.little).ceilToDouble(),
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2Floor(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'f64x2.floor');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _setF64LaneCanonical(
        resultData,
        offset,
        inputData.getFloat64(offset, Endian.little).floorToDouble(),
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2Trunc(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'f64x2.trunc');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _setF64LaneCanonical(
        resultData,
        offset,
        inputData.getFloat64(offset, Endian.little).truncateToDouble(),
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2Nearest(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'f64x2.nearest');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _setF64LaneCanonical(
        resultData,
        offset,
        _nearest(inputData.getFloat64(offset, Endian.little)),
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2Abs(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'f64x2.abs');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final bits = _readLaneU64(inputData, offset) & (_u64MaskBigInt >> 1);
      _writeLaneU64(resultData, offset, bits);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2Neg(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'f64x2.neg');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    final signBit = BigInt.one << 63;
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _writeLaneU64(resultData, offset, _readLaneU64(inputData, offset) ^ signBit);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2Sqrt(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'f64x2.sqrt');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _setF64LaneCanonical(
        resultData,
        offset,
        math.sqrt(inputData.getFloat64(offset, Endian.little)),
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2Div(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'f64x2.div');
    final lhs = _popV128Bytes(stack, opName: 'f64x2.div');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _setF64LaneCanonical(
        resultData,
        offset,
        lhsData.getFloat64(offset, Endian.little) /
            rhsData.getFloat64(offset, Endian.little),
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2Min(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'f64x2.min');
    final lhs = _popV128Bytes(stack, opName: 'f64x2.min');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _setF64LaneCanonical(
        resultData,
        offset,
        _fMin(
          lhsData.getFloat64(offset, Endian.little),
          rhsData.getFloat64(offset, Endian.little),
        ),
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2Max(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'f64x2.max');
    final lhs = _popV128Bytes(stack, opName: 'f64x2.max');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      _setF64LaneCanonical(
        resultData,
        offset,
        _fMax(
          lhsData.getFloat64(offset, Endian.little),
          rhsData.getFloat64(offset, Endian.little),
        ),
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2Pmin(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'f64x2.pmin');
    final lhs = _popV128Bytes(stack, opName: 'f64x2.pmin');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final lhsBits = _readLaneU64(lhsData, offset);
      final rhsBits = _readLaneU64(rhsData, offset);
      if (_isF64NaNBits(lhsBits) || _isF64NaNBits(rhsBits)) {
        _writeLaneU64(resultData, offset, lhsBits);
        continue;
      }
      final lhsLane = lhsData.getFloat64(offset, Endian.little);
      final rhsLane = rhsData.getFloat64(offset, Endian.little);
      if (lhsLane < rhsLane) {
        _writeLaneU64(resultData, offset, lhsBits);
      } else if (lhsLane > rhsLane) {
        _writeLaneU64(resultData, offset, rhsBits);
      } else {
        _writeLaneU64(resultData, offset, lhsBits);
      }
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2Pmax(List<WasmValue> stack) {
    final rhs = _popV128Bytes(stack, opName: 'f64x2.pmax');
    final lhs = _popV128Bytes(stack, opName: 'f64x2.pmax');
    final rhsData = ByteData.sublistView(rhs);
    final lhsData = ByteData.sublistView(lhs);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final lhsBits = _readLaneU64(lhsData, offset);
      final rhsBits = _readLaneU64(rhsData, offset);
      if (_isF64NaNBits(lhsBits) || _isF64NaNBits(rhsBits)) {
        _writeLaneU64(resultData, offset, lhsBits);
        continue;
      }
      final lhsLane = lhsData.getFloat64(offset, Endian.little);
      final rhsLane = rhsData.getFloat64(offset, Endian.little);
      if (lhsLane > rhsLane) {
        _writeLaneU64(resultData, offset, lhsBits);
      } else if (lhsLane < rhsLane) {
        _writeLaneU64(resultData, offset, rhsBits);
      } else {
        _writeLaneU64(resultData, offset, lhsBits);
      }
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4ConvertI32x4U(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'f32x4.convert_i32x4_u');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      resultData.setFloat32(
        offset,
        inputData.getUint32(offset, Endian.little).toDouble(),
        Endian.little,
      );
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4TruncSatF32x4U(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i32x4.trunc_sat_f32x4_u');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 4; lane++) {
      final offset = lane * 4;
      final laneValue = _truncSatToI32U(inputData.getFloat32(offset, Endian.little));
      resultData.setUint32(offset, _toU32(laneValue), Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4TruncSatF64x2SZero(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i32x4.trunc_sat_f64x2_s_zero');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final laneValue = _truncSatToI32S(inputData.getFloat64(offset, Endian.little));
      resultData.setUint32(lane * 4, _toU32(laneValue), Endian.little);
    }
    resultData.setUint32(8, 0, Endian.little);
    resultData.setUint32(12, 0, Endian.little);
    _pushV128Bytes(stack, result);
  }

  void _simdI32x4TruncSatF64x2UZero(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'i32x4.trunc_sat_f64x2_u_zero');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final offset = lane * 8;
      final laneValue = _truncSatToI32U(inputData.getFloat64(offset, Endian.little));
      resultData.setUint32(lane * 4, _toU32(laneValue), Endian.little);
    }
    resultData.setUint32(8, 0, Endian.little);
    resultData.setUint32(12, 0, Endian.little);
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2ConvertLowI32x4S(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'f64x2.convert_low_i32x4_s');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final value = inputData.getInt32(lane * 4, Endian.little).toDouble();
      resultData.setFloat64(lane * 8, value, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2ConvertLowI32x4U(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'f64x2.convert_low_i32x4_u');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final value = inputData.getUint32(lane * 4, Endian.little).toDouble();
      resultData.setFloat64(lane * 8, value, Endian.little);
    }
    _pushV128Bytes(stack, result);
  }

  void _simdF32x4DemoteF64x2Zero(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'f32x4.demote_f64x2_zero');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final value = inputData.getFloat64(lane * 8, Endian.little);
      _setF32LaneCanonical(resultData, lane * 4, value);
    }
    resultData.setUint32(8, 0, Endian.little);
    resultData.setUint32(12, 0, Endian.little);
    _pushV128Bytes(stack, result);
  }

  void _simdF64x2PromoteLowF32x4(List<WasmValue> stack) {
    final input = _popV128Bytes(stack, opName: 'f64x2.promote_low_f32x4');
    final inputData = ByteData.sublistView(input);
    final result = Uint8List(16);
    final resultData = ByteData.sublistView(result);
    for (var lane = 0; lane < 2; lane++) {
      final value = inputData.getFloat32(lane * 4, Endian.little);
      _setF64LaneCanonical(resultData, lane * 8, value);
    }
    _pushV128Bytes(stack, result);
  }

  void _pushV128Bytes(List<WasmValue> stack, Uint8List bytes) {
    stack.add(WasmValue.i32(_internV128(bytes)));
  }

  int _requireSimdLane(
    Instruction instruction, {
    required int laneCount,
    required String opName,
  }) {
    final lane = instruction.immediate;
    if (lane == null || lane < 0 || lane >= laneCount) {
      throw StateError('$opName lane index out of range.');
    }
    return lane;
  }

  Uint8List _popV128Bytes(List<WasmValue> stack, {required String opName}) {
    final token = _popI32(stack);
    final bytes = _v128BytesByValue[token];
    if (bytes == null) {
      throw StateError('$opName expects v128 operand.');
    }
    return bytes;
  }

  BigInt _readLaneU64(ByteData data, int offset) {
    final low = BigInt.from(data.getUint32(offset, Endian.little));
    final high = BigInt.from(data.getUint32(offset + 4, Endian.little));
    return low | (high << 32);
  }

  void _writeLaneU64(ByteData data, int offset, BigInt value) {
    final normalized = value & _u64MaskBigInt;
    final low = (normalized & _u32MaskBigInt).toInt();
    final high = ((normalized >> 32) & _u32MaskBigInt).toInt();
    data.setUint32(offset, low, Endian.little);
    data.setUint32(offset + 4, high, Endian.little);
  }

  void _setF32LaneCanonical(ByteData data, int offset, double value) {
    final bits = WasmValue.toF32Bits(value);
    data.setUint32(offset, _canonicalizeF32NaNBits(bits), Endian.little);
  }

  void _setF64LaneCanonical(ByteData data, int offset, double value) {
    final bits = WasmValue.toF64Bits(value);
    _writeLaneU64(data, offset, _canonicalizeF64NaNBits(bits));
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
  int _popF32Bits(List<WasmValue> stack) =>
      _pop(stack).castTo(WasmValueType.f32).asF32Bits();
  BigInt _popF64Bits(List<WasmValue> stack) =>
      _pop(stack).castTo(WasmValueType.f64).asF64Bits();

  int? _popRef(List<WasmValue> stack) {
    final raw = _popI32(stack);
    return raw == _nullRef ? null : raw;
  }

  _FunctionRefTarget _requireFunctionTarget(
    int? reference, {
    required String opName,
  }) {
    if (reference == null) {
      throw StateError('$opName to null function reference.');
    }
    final target = _functionRefTargets[reference];
    if (target == null) {
      throw StateError('$opName to non-function reference.');
    }
    return target;
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

  void _storeI64(List<WasmValue> stack, Instruction instruction, BigInt value) {
    final address = _addressFromStack(stack, instruction);
    _memoryForMemArg(instruction).storeI64(address, value);
  }

  void _storeF32Bits(List<WasmValue> stack, Instruction instruction, int bits) {
    final address = _addressFromStack(stack, instruction);
    _memoryForMemArg(instruction).storeI32(address, bits);
  }

  void _storeF64Bits(
    List<WasmValue> stack,
    Instruction instruction,
    BigInt bits,
  ) {
    final address = _addressFromStack(stack, instruction);
    _memoryForMemArg(instruction).storeI64(address, bits);
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

    final length = _popUnsignedI32Operand(stack, label: 'memory.init length');
    final sourceOffset = _popUnsignedI32Operand(
      stack,
      label: 'memory.init source offset',
    );
    final destinationOffset = _popMemoryOperand(
      stack,
      memoryIndex: memoryIndex,
      label: 'memory.init destination offset',
    );

    final data = _dataSegments[dataIndex];
    if (data == null) {
      if (length == 0) {
        return;
      }
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

    final length = _popMemoryOperationLength(
      stack,
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
    final length = _popMemoryOperationLength(
      stack,
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

    final length = _popUnsignedI32Operand(stack, label: 'table.init length');
    final sourceOffset = _popUnsignedI32Operand(
      stack,
      label: 'table.init source offset',
    );
    final destinationOffset = _popTableOperand(
      stack,
      tableIndex: tableIndex,
      label: 'table.init destination offset',
    );

    final segment = _elementSegments[elementIndex];
    if (segment == null) {
      if (length == 0) {
        return;
      }
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
    final destinationIs64 = _isTable64(destinationTableIndex);
    final sourceIs64 = _isTable64(sourceTableIndex);
    final length = destinationIs64 && sourceIs64
        ? WasmI64.unsigned(_popI64(stack)).toInt()
        : _popI32(stack).toUnsigned(32);
    final sourceOffset = _popTableOperand(
      stack,
      tableIndex: sourceTableIndex,
      label: 'table.copy source offset',
    );
    final destinationOffset = _popTableOperand(
      stack,
      tableIndex: destinationTableIndex,
      label: 'table.copy destination offset',
    );

    final sourceTable = _tables[sourceTableIndex];
    final destinationTable = _tables[destinationTableIndex];
    if (sourceOffset > sourceTable.length ||
        length > sourceTable.length - sourceOffset) {
      throw StateError('table.copy source out of bounds.');
    }
    if (destinationOffset > destinationTable.length ||
        length > destinationTable.length - destinationOffset) {
      throw StateError('table.copy destination out of bounds.');
    }

    final temp = <int?>[];
    for (var i = 0; i < length; i++) {
      temp.add(sourceTable[sourceOffset + i]);
    }

    destinationTable.initialize(destinationOffset, temp);
  }

  void _tableGrow(Instruction instruction, List<WasmValue> stack) {
    final tableIndex = _checkTableIndex(instruction.immediate!);
    final delta = _popTableOperand(
      stack,
      tableIndex: tableIndex,
      label: 'table.grow delta',
    );
    final value = _popRef(stack);

    final previous = _tables[tableIndex].grow(delta, value);
    stack.add(_tableIndexValue(tableIndex, previous));
  }

  void _tableSize(Instruction instruction, List<WasmValue> stack) {
    final tableIndex = _checkTableIndex(instruction.immediate!);
    stack.add(_tableIndexValue(tableIndex, _tables[tableIndex].length));
  }

  void _tableFill(Instruction instruction, List<WasmValue> stack) {
    final tableIndex = _checkTableIndex(instruction.immediate!);
    final length = _popTableOperand(
      stack,
      tableIndex: tableIndex,
      label: 'table.fill length',
    );
    final value = _popRef(stack);
    final destinationOffset = _popTableOperand(
      stack,
      tableIndex: tableIndex,
      label: 'table.fill destination offset',
    );

    final table = _tables[tableIndex];
    if (destinationOffset > table.length ||
        length > table.length - destinationOffset) {
      throw StateError('table.fill destination out of bounds.');
    }
    final fillValues = List<int?>.filled(length, value);
    table.initialize(destinationOffset, fillValues);
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

  int _toLinearMemoryValue(BigInt value, {required String label}) {
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
  static int _mulI32(int lhs, int rhs) {
    final product =
        (BigInt.from(lhs.toSigned(32)) * BigInt.from(rhs.toSigned(32))) &
        _u32MaskBigInt;
    return product.toInt().toSigned(32);
  }

  static int _mulU32(int lhs, int rhs) {
    final product =
        (BigInt.from(lhs.toUnsigned(32)) * BigInt.from(rhs.toUnsigned(32))) &
        _u32MaskBigInt;
    return product.toInt();
  }

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

  static bool _isF32NaNBits(int bits) {
    final normalized = bits.toUnsigned(32);
    return (normalized & 0x7f800000) == 0x7f800000 &&
        (normalized & 0x007fffff) != 0;
  }

  static bool _isF64NaNBits(BigInt bits) {
    final normalized = WasmI64.unsigned(bits);
    return (normalized & _f64ExponentMask) == _f64ExponentMask &&
        (normalized & _f64FractionMask) != BigInt.zero;
  }

  static int _canonicalizeF32NaNBits(int bits) {
    final normalized = bits.toUnsigned(32);
    return _isF32NaNBits(normalized) ? 0x7fc00000 : normalized;
  }

  static BigInt _canonicalizeF64NaNBits(BigInt bits) {
    final normalized = WasmI64.unsigned(bits);
    return _isF64NaNBits(normalized) ? _f64CanonicalNan : normalized;
  }

  static double _nearest(double value) {
    if (value.isNaN || value.isInfinite || value == 0.0) {
      return value;
    }
    final lower = value.floorToDouble();
    final upper = value.ceilToDouble();
    final lowerDistance = (value - lower).abs();
    final upperDistance = (upper - value).abs();

    double result;
    if (lowerDistance < upperDistance) {
      result = lower;
    } else if (upperDistance < lowerDistance) {
      result = upper;
    } else {
      final lowerEven = lower.toInt().isEven;
      result = lowerEven ? lower : upper;
    }

    if (result == 0.0) {
      return value.isNegative ? -0.0 : 0.0;
    }
    return result;
  }

  static int _signExtend(int value, int bits) {
    if (bits <= 0 || bits > 32) {
      throw RangeError.range(bits, 1, 32, 'bits');
    }
    if (bits == 32) {
      return value.toSigned(32);
    }
    final bitMask = (1 << bits) - 1;
    final masked = value & bitMask;
    final signBit = 1 << (bits - 1);
    final extended = (masked & signBit) != 0 ? masked - (1 << bits) : masked;
    return extended.toSigned(32);
  }

  static BigInt _signExtend64(BigInt value, int bits) {
    return WasmI64.signExtend(value, bits);
  }

  static double _f32FromInteger(Object value) {
    return WasmValue.fromF32Bits(_f32BitsFromInteger(value));
  }

  static int _f32BitsFromInteger(Object value) {
    var integer = value is BigInt ? value : BigInt.from(value as int);
    if (integer == BigInt.zero) {
      return 0;
    }

    var signBit = 0;
    if (integer < BigInt.zero) {
      signBit = 1;
      integer = -integer;
    }

    const significandBits = 24; // includes implicit leading bit
    final bitLength = integer.bitLength;
    var exponent = bitLength - 1;
    BigInt significand;

    if (bitLength <= significandBits) {
      significand = integer << (significandBits - bitLength);
    } else {
      final shift = bitLength - significandBits;
      significand = integer >> shift;
      final remainderMask = (BigInt.one << shift) - BigInt.one;
      final remainder = integer & remainderMask;
      final halfway = BigInt.one << (shift - 1);
      final shouldRoundUp =
          remainder > halfway ||
          (remainder == halfway && (significand & BigInt.one) == BigInt.one);
      if (shouldRoundUp) {
        significand += BigInt.one;
        if (significand == (BigInt.one << significandBits)) {
          significand >>= 1;
          exponent++;
        }
      }
    }

    final exponentBits = exponent + 127;
    final fractionBits = (significand & BigInt.from(0x7fffff)).toInt();
    return (signBit << 31) | (exponentBits << 23) | fractionBits;
  }

  static int _truncToI32S(double value) {
    _assertFinite(value);
    final truncated = value.truncate();
    if (truncated < _i32MinValueInt || truncated > _i32MaxValueInt) {
      throw StateError('i32.trunc_*_s overflow trap');
    }
    return truncated.toSigned(32);
  }

  static int _truncToI32U(double value) {
    _assertFinite(value);
    final truncated = value.truncate();
    if (truncated < 0 || truncated > _u32MaxValueInt) {
      throw StateError('i32.trunc_*_u overflow trap');
    }
    return truncated.toUnsigned(32).toSigned(32);
  }

  static BigInt _truncToI64S(double value) {
    _assertFinite(value);
    if (value < _i64Min || value >= _i64MaxPlusOne) {
      throw StateError('i64.trunc_*_s overflow trap');
    }
    final truncated = BigInt.from(value);
    return WasmI64.signed(truncated);
  }

  static BigInt _truncToI64U(double value) {
    _assertFinite(value);
    if (value <= -1.0 || value >= _u64MaxPlusOne) {
      throw StateError('i64.trunc_*_u overflow trap');
    }
    final truncated = BigInt.from(value);
    return WasmI64.unsigned(truncated);
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
    return WasmI64.signed(BigInt.from(value));
  }

  static BigInt _truncSatToI64U(double value) {
    if (value.isNaN || value <= 0) {
      return BigInt.zero;
    }
    if (value >= _u64Max) {
      return _u64Mask;
    }
    return WasmI64.unsigned(BigInt.from(value));
  }

  static void _assertFinite(double value) {
    if (value.isNaN || value.isInfinite) {
      throw StateError('Invalid conversion trap: NaN or infinite value');
    }
  }

  static final BigInt _i64MinValue = WasmI64.minSigned;
  static final BigInt _i64MaxValue = WasmI64.maxSigned;
  static const int _i32MinValueInt = -2147483648;
  static const int _i32MaxValueInt = 2147483647;
  static const int _u32MaxValueInt = 0xffffffff;
  static final BigInt _u64Mask = WasmI64.allOnesMask;
  static final BigInt _u64BigMod = BigInt.one << 64;
  static final BigInt _u64BigMask = _u64BigMod - BigInt.one;
  static final BigInt _u128BigMask = (BigInt.one << 128) - BigInt.one;
  static final BigInt _f64ExponentMask = BigInt.parse(
    '7ff0000000000000',
    radix: 16,
  );
  static final BigInt _f64FractionMask = BigInt.parse(
    '000fffffffffffff',
    radix: 16,
  );
  static final BigInt _f64CanonicalNan = BigInt.parse(
    '7ff8000000000000',
    radix: 16,
  );

  static const double _i32Min = -2147483648.0;
  static const double _i32Max = 2147483647.0;

  static const double _u32Max = 4294967295.0;

  static const double _i64Min = -9223372036854775808.0;
  static const double _i64Max = 9223372036854775807.0;
  static const double _i64MaxPlusOne = 9223372036854775808.0;

  static const double _u64Max = 18446744073709551615.0;
  static const double _u64MaxPlusOne = 18446744073709551616.0;
}
