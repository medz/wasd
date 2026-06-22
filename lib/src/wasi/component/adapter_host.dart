import '../../wasm/backend/native/interpreter/component.dart';
import 'adapter_plan.dart';

/// Function callback used by direct canonical adapter operations.
typedef WASIComponentCanonicalAdapterCallback =
    Object? Function(List<Object?> args);

/// Host for executable canonical `lift`/`lower` adapter operations.
///
/// This is the first executable adapter boundary. It intentionally supports
/// only direct synchronous primitive signatures: resource handles, dynamic
/// memory payloads, nested component values, and async adapters are rejected
/// instead of being approximated.
final class WASIComponentCanonicalAdapterHost {
  /// Creates a canonical adapter host.
  const WASIComponentCanonicalAdapterHost();

  /// Binds a canonical `lift` plan to the core function it wraps.
  WASIComponentCanonicalAdapterOperation bindLiftCoreFunction(
    WASIComponentCanonicalAdapterPlan plan,
    WASIComponentCanonicalAdapterCallback coreFunction,
  ) {
    _requireAdapterKind(plan, WasmComponentCanonicalKind.lift);
    _checkDirectPrimitivePlan(plan);
    return WASIComponentCanonicalAdapterOperation._(
      plan: plan,
      callback: coreFunction,
    );
  }

  /// Binds a canonical `lower` plan to the component function it wraps.
  WASIComponentCanonicalAdapterOperation bindLowerComponentFunction(
    WASIComponentCanonicalAdapterPlan plan,
    WASIComponentCanonicalAdapterCallback componentFunction,
  ) {
    _requireAdapterKind(plan, WasmComponentCanonicalKind.lower);
    _checkDirectPrimitivePlan(plan);
    return WASIComponentCanonicalAdapterOperation._(
      plan: plan,
      callback: componentFunction,
    );
  }
}

/// Executable direct primitive canonical adapter operation.
final class WASIComponentCanonicalAdapterOperation {
  const WASIComponentCanonicalAdapterOperation._({
    required this.plan,
    required WASIComponentCanonicalAdapterCallback callback,
  }) : _callback = callback;

  /// Adapter generation plan this operation executes.
  final WASIComponentCanonicalAdapterPlan plan;

  final WASIComponentCanonicalAdapterCallback _callback;

  /// Canonical adapter kind.
  WasmComponentCanonicalKind get kind => plan.kind;

  /// Canonical definition index.
  int get canonicalIndex => plan.canonicalIndex;

  /// Invokes the adapter with direct primitive values.
  Object? invoke(List<Object?> args) {
    if (args.length != plan.params.length) {
      throw StateError(
        'WASI component canonical adapter index $canonicalIndex expected '
        '${plan.params.length} arguments, got ${args.length}.',
      );
    }
    for (var i = 0; i < plan.params.length; i++) {
      plan.params[i].memoryCodec!.validate(plan.params[i].path, args[i]);
    }

    final result = _callback(List<Object?>.unmodifiable(args));
    final resultPlan = plan.result;
    if (resultPlan == null) {
      if (result != null) {
        throw StateError(
          'WASI component canonical adapter index $canonicalIndex expected no result.',
        );
      }
      return null;
    }
    resultPlan.memoryCodec!.validate(resultPlan.path, result);
    return result;
  }
}

void _requireAdapterKind(
  WASIComponentCanonicalAdapterPlan plan,
  WasmComponentCanonicalKind expected,
) {
  if (plan.kind != expected) {
    throw StateError(
      'WASI component canonical adapter index ${plan.canonicalIndex} expected '
      '${expected.name}, got ${plan.kind.name}.',
    );
  }
}

void _checkDirectPrimitivePlan(WASIComponentCanonicalAdapterPlan plan) {
  if (plan.isAsync) {
    throw UnsupportedError(
      'WASI component canonical adapter index ${plan.canonicalIndex} uses async.',
    );
  }
  if (plan.hasResourceHandles) {
    throw UnsupportedError(
      'WASI component canonical adapter index ${plan.canonicalIndex} uses resource handles.',
    );
  }
  if (plan.hasDynamicPayload) {
    throw UnsupportedError(
      'WASI component canonical adapter index ${plan.canonicalIndex} uses dynamic memory payloads.',
    );
  }
  for (final param in plan.params) {
    _checkDirectPrimitiveValue(plan, param);
  }
  final result = plan.result;
  if (result != null) {
    _checkDirectPrimitiveValue(plan, result);
  }
}

void _checkDirectPrimitiveValue(
  WASIComponentCanonicalAdapterPlan plan,
  WASIComponentCanonicalAdapterValuePlan value,
) {
  if (value.memoryCodec?.primitive == null) {
    throw UnsupportedError(
      'WASI component canonical adapter index ${plan.canonicalIndex} '
      'value ${value.path} is not a direct primitive value.',
    );
  }
  if (value.resourceUses.isNotEmpty) {
    throw UnsupportedError(
      'WASI component canonical adapter index ${plan.canonicalIndex} '
      'value ${value.path} uses resource handles.',
    );
  }
}
