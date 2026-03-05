// ignore_for_file: public_member_api_docs

import 'module.dart';
import 'value.dart';

final class RuntimeStackOps {
  static void truncateToHeight(
    List<WasmValue> stack,
    int height, {
    required String context,
  }) {
    if (stack.length < height) {
      throw StateError(
        '$context stack underflow: stack=${stack.length}, height=$height.',
      );
    }
    stack.length = height;
  }

  static List<WasmValue> takeTopTyped(
    List<WasmValue> stack,
    List<WasmValueType> types, {
    required String context,
  }) {
    if (types.isEmpty) {
      return const [];
    }
    if (stack.length < types.length) {
      throw StateError(
        '$context stack underflow: needs ${types.length}, has ${stack.length}.',
      );
    }
    final start = stack.length - types.length;
    final values = <WasmValue>[];
    for (var i = 0; i < types.length; i++) {
      values.add(stack[start + i].castTo(types[i]));
    }
    return values;
  }

  static List<WasmValue> popTyped(
    List<WasmValue> stack,
    List<WasmValueType> types, {
    required String context,
  }) {
    if (types.isEmpty) {
      return const [];
    }
    if (stack.length < types.length) {
      throw StateError(
        '$context stack underflow: needs ${types.length}, has ${stack.length}.',
      );
    }
    final values = List<WasmValue>.filled(
      types.length,
      WasmValue.i32(0),
      growable: false,
    );
    for (var i = types.length - 1; i >= 0; i--) {
      values[i] = stack.removeLast().castTo(types[i]);
    }
    return values;
  }

  static List<WasmValue> collectResultsFromTop(
    List<WasmValue> stack,
    List<WasmValueType> resultTypes, {
    required String context,
  }) {
    return takeTopTyped(stack, resultTypes, context: context);
  }

  static List<WasmValue> collectResultsAtExactHeight(
    List<WasmValue> stack,
    List<WasmValueType> resultTypes, {
    required String context,
  }) {
    if (stack.length < resultTypes.length) {
      throw StateError(
        '$context result underflow: needs ${resultTypes.length}, '
        'has ${stack.length}.',
      );
    }
    if (stack.length != resultTypes.length) {
      throw StateError(
        '$context stack height mismatch: expected ${resultTypes.length}, '
        'has ${stack.length}.',
      );
    }
    return takeTopTyped(stack, resultTypes, context: context);
  }
}
