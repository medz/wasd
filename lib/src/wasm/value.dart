import 'dart:typed_data';

/// Factory-backed kind marker for [Value] types.
enum ValueKind<T extends Value<T, V>, V extends Object?> {
  /// Function reference type.
  funcref(FuncRef._, {'anyfunc'}),

  /// External reference type.
  externref(ExternRef._),

  /// 32-bit floating-point number type.
  f32(Float32._),

  /// 64-bit floating-point number type.
  f64(Float64._),

  /// 32-bit integer type.
  i32(Int32._),

  /// 64-bit integer type.
  i64(Int64._),

  /// 128-bit vector type.
  v128(Vector128._);

  /// Creates a [ValueKind] from a concrete value factory and optional aliases.
  const ValueKind(this._factory, [this.aliases = const {}]);

  final T Function(V value) _factory;

  /// Alternative textual names accepted for this kind.
  final Set<String> aliases;

  /// Creates a typed [Value] wrapper from raw [ref].
  T call(V ref) => _factory(ref);
}

/// Base wrapper for typed WebAssembly runtime values.
sealed class Value<T extends Value<T, V>, V extends Object?> {
  /// Creates a typed value wrapper from [ref].
  const Value._(this.ref);

  /// Wrapped raw runtime reference/value.
  final V ref;

  /// Kind marker of this concrete value.
  ValueKind<T, V> get kind;
}

/// Function reference value.
final class FuncRef extends Value<FuncRef, Function> {
  const FuncRef._(super.ref) : super._();

  @override
  ValueKind<FuncRef, Function> get kind => .funcref;

  /// Invokes the wrapped function reference.
  T call<T extends Object?>(
    List<Object?>? positionalArguments, [
    Map<Symbol, Object?>? namedArguments,
  ]) => Function.apply(ref, positionalArguments, namedArguments);
}

/// External reference value.
final class ExternRef extends Value<ExternRef, Object?> {
  const ExternRef._(super.ref) : super._();

  @override
  ValueKind<ExternRef, Object?> get kind => .externref;
}

/// 32-bit integer value.
final class Int32 extends Value<Int32, int> {
  const Int32._(super.ref) : super._();

  @override
  ValueKind<Int32, int> get kind => .i32;
}

/// 64-bit integer value.
final class Int64 extends Value<Int64, int> {
  const Int64._(super.ref) : super._();

  @override
  ValueKind<Int64, int> get kind => .i64;
}

/// 32-bit floating-point value.
final class Float32 extends Value<Float32, double> {
  const Float32._(super.ref) : super._();

  @override
  ValueKind<Float32, double> get kind => .f32;
}

/// 64-bit floating-point value.
final class Float64 extends Value<Float64, double> {
  const Float64._(super.ref) : super._();

  @override
  ValueKind<Float64, double> get kind => .f64;
}

/// 128-bit vector value.
final class Vector128 extends Value<Vector128, ByteData> {
  /// Creates a [Vector128] from a 16-byte [ByteData] reference.
  Vector128._(super.ref) : assert(ref.lengthInBytes == 16), super._() {
    if (ref.lengthInBytes != 16) {
      throw ArgumentError.value(
        ref.lengthInBytes,
        'ref.lengthInBytes',
        'must be exactly 16 bytes',
      );
    }
  }

  @override
  ValueKind<Vector128, ByteData> get kind => .v128;
}
