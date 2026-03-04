import 'module.dart';
import 'runtime_stack_ops.dart';
import 'value.dart';

final class RuntimeControlOps {
  static int targetIndexForDepth(
    int depth,
    int frameCount, {
    required String context,
    String labelName = 'labels',
  }) {
    if (depth < 0 || depth >= frameCount) {
      throw RangeError(
        '$context depth out of range: $depth ($labelName=$frameCount)',
      );
    }
    return frameCount - 1 - depth;
  }

  static void rebaseStackForBranch({
    required List<WasmValue> stack,
    required List<WasmValueType> branchTypes,
    required int stackBaseHeight,
    required String context,
  }) {
    final branchValues = RuntimeStackOps.takeTopTyped(
      stack,
      branchTypes,
      context: '$context branch values',
    );
    RuntimeStackOps.truncateToHeight(
      stack,
      stackBaseHeight,
      context: '$context branch target',
    );
    stack.addAll(branchValues);
  }

  static void leaveFrameDropExtra({
    required List<WasmValue> stack,
    required int stackBaseHeight,
    required List<WasmValueType> resultTypes,
    required String context,
  }) {
    final results = RuntimeStackOps.takeTopTyped(
      stack,
      resultTypes,
      context: '$context frame results',
    );
    RuntimeStackOps.truncateToHeight(
      stack,
      stackBaseHeight,
      context: '$context frame restore',
    );
    stack.addAll(results);
  }

  static void leaveFrameExact({
    required List<WasmValue> stack,
    required int stackBaseHeight,
    required List<WasmValueType> resultTypes,
    required String context,
  }) {
    final results = RuntimeStackOps.popTyped(
      stack,
      resultTypes,
      context: '$context control-result',
    );
    if (stack.length != stackBaseHeight) {
      throw StateError(
        '$context stack height mismatch: expected $stackBaseHeight, '
        'has ${stack.length}.',
      );
    }
    stack.addAll(results);
  }
}
