import 'imports.dart';
import 'module.dart';
import 'predecode.dart';

sealed class RuntimeFunction {
  const RuntimeFunction({required this.type});

  final WasmFunctionType type;
  bool get isHost;
}

final class DefinedRuntimeFunction extends RuntimeFunction {
  const DefinedRuntimeFunction({
    required super.type,
    required this.localTypes,
    required this.instructions,
  });

  final List<WasmValueType> localTypes;
  final List<Instruction> instructions;

  @override
  bool get isHost => false;
}

final class HostRuntimeFunction extends RuntimeFunction {
  const HostRuntimeFunction({required super.type, required this.callback});

  final WasmHostFunction callback;

  @override
  bool get isHost => true;
}
