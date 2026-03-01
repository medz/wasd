import 'dart:typed_data';

enum ValueKind<T extends Value<T, V>, V extends Object?> {
  funcref(FuncRef._, {'anyfunc'}),
  externref(ExternRef._),
  f32(Float32._),
  f64(Float64._),
  i32(Int32._),
  i64(Int64._),
  v128(Vector128._);

  const ValueKind(this._factory, [this.aliases = const {}]);

  final T Function(V value) _factory;
  final Set<String> aliases;

  T call(V ref) => _factory(ref);
}

sealed class Value<T extends Value<T, V>, V extends Object?> {
  const Value._(this.ref);

  final V ref;

  ValueKind<T, V> get kind;
}

final class FuncRef extends Value<FuncRef, Function> {
  const FuncRef._(super.ref) : super._();

  @override
  ValueKind<FuncRef, Function> get kind => .funcref;

  T call<T extends Object?>(
    List<Object?>? positionalArguments, [
    Map<Symbol, Object?>? namedArguments,
  ]) => Function.apply(ref, positionalArguments, namedArguments);
}

final class ExternRef extends Value<ExternRef, Object?> {
  const ExternRef._(super.ref) : super._();

  @override
  ValueKind<ExternRef, Object?> get kind => .externref;
}

final class Int32 extends Value<Int32, int> {
  const Int32._(super.ref) : super._();

  @override
  ValueKind<Int32, int> get kind => .i32;
}

final class Int64 extends Value<Int64, int> {
  const Int64._(super.ref) : super._();

  @override
  ValueKind<Int64, int> get kind => .i64;
}

final class Float32 extends Value<Float32, double> {
  const Float32._(super.ref) : super._();

  @override
  ValueKind<Float32, double> get kind => .f32;
}

final class Float64 extends Value<Float64, double> {
  const Float64._(super.ref) : super._();

  @override
  ValueKind<Float64, double> get kind => .f64;
}

final class Vector128 extends Value<Vector128, ByteData> {
  Vector128._(super.ref) : assert(ref.lengthInBytes == 16), super._();

  @override
  ValueKind<Vector128, ByteData> get kind => .v128;
}
