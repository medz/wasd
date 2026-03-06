// ignore_for_file: public_member_api_docs

import 'imports.dart';
import 'module.dart';
import 'predecode.dart';

sealed class RuntimeFunction {
  const RuntimeFunction({
    required this.type,
    required this.declaredTypeIndex,
    required this.runtimeTypeDepth,
  });

  final WasmFunctionType type;
  final int declaredTypeIndex;
  final int runtimeTypeDepth;
  bool get isHost;
}

final class DefinedRuntimeFunction extends RuntimeFunction {
  const DefinedRuntimeFunction({
    required super.type,
    required super.declaredTypeIndex,
    required super.runtimeTypeDepth,
    required this.localTypes,
    required this.instructions,
  });

  final List<WasmValueType> localTypes;
  final List<Instruction> instructions;

  @override
  bool get isHost => false;
}

final class HostRuntimeFunction extends RuntimeFunction {
  const HostRuntimeFunction({
    required super.type,
    required super.declaredTypeIndex,
    required super.runtimeTypeDepth,
    required this.callback,
    this.asyncCallback,
  });

  final WasmHostFunction callback;
  final WasmAsyncHostFunction? asyncCallback;

  @override
  bool get isHost => true;
}
