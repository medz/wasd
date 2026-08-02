import 'dart:math' as math;
import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../component/wit_adapter.dart';
import '../preview3/secure_random.dart' as secure_random;

const int _maxRandomBytesPerCall = 64 * 1024;

/// WASI 0.2 `wasi:random` host imports.
final class WASIPreview2RandomHost {
  /// Creates a random host import provider.
  WASIPreview2RandomHost({
    math.Random? secureRandom,
    math.Random? insecureRandom,
  }) : _secureRandom = secureRandom,
       _insecureRandom = insecureRandom ?? math.Random();

  final math.Random? _secureRandom;
  final math.Random _insecureRandom;
  (BigInt, BigInt)? _insecureSeed;

  /// Import callbacks keyed by canonical WIT adapter names.
  late final Map<String, WASIComponentWitAdapterCallback> imports =
      Map<String, WASIComponentWitAdapterCallback>.unmodifiable({
        'wasi:random/random@0.2.0.get-random-bytes': (args) =>
            _secureRandomBytes(args.single),
        'wasi:random/random@0.2.0.get-random-u64': (_) => _secureRandomU64(),
        'wasi:random/insecure@0.2.0.get-insecure-random-bytes': (args) =>
            _randomBytes(args.single, _insecureRandom),
        'wasi:random/insecure@0.2.0.get-insecure-random-u64': (_) =>
            _nextU64(_insecureRandom),
        'wasi:random/insecure-seed@0.2.0.insecure-seed': (_) =>
            _insecureSeedTuple(),
      });

  WasmComponentValueData _randomBytes(Object? lengthValue, math.Random random) {
    final length = _length(lengthValue);
    return _bytesData(_randomRawBytes(length, random));
  }

  WasmComponentValueData _secureRandomBytes(Object? lengthValue) {
    final length = _length(lengthValue);
    final injected = _secureRandom;
    final bytes = injected == null
        ? secure_random.secureRandomBytes(length)
        : _randomRawBytes(length, injected);
    return _bytesData(bytes);
  }

  BigInt _secureRandomU64() {
    final injected = _secureRandom;
    return injected == null
        ? _u64FromBytes(secure_random.secureRandomBytes(8))
        : _nextU64(injected);
  }

  WasmComponentValueData _insecureSeedTuple() {
    final seed = _insecureSeed ??= (
      _nextU64(_insecureRandom),
      _nextU64(_insecureRandom),
    );
    return WasmComponentValueData(
      kind: WasmComponentValueDataKind.tuple,
      rawBytes: Uint8List(0),
      items: [_u64Data(seed.$1), _u64Data(seed.$2)],
    );
  }
}

int _length(Object? value) {
  final length = switch (value) {
    int() => BigInt.from(value),
    BigInt() => value,
    WasmComponentValueData(kind: WasmComponentValueDataKind.integer) =>
      switch (value.integer) {
        final int integer => BigInt.from(integer),
        final BigInt integer => integer,
        _ => BigInt.from(-1),
      },
    _ => BigInt.from(-1),
  };
  if (length < BigInt.zero || length > BigInt.from(_maxRandomBytesPerCall)) {
    throw StateError(
      'WASI random byte length must be between 0 and '
      '$_maxRandomBytesPerCall bytes: $value.',
    );
  }
  return length.toInt();
}

Uint8List _randomRawBytes(int length, math.Random random) {
  final bytes = Uint8List(length);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

BigInt _nextU64(math.Random random) {
  final high = random.nextInt(0x100000000);
  final low = random.nextInt(0x100000000);
  return (BigInt.from(high) << 32) | BigInt.from(low);
}

BigInt _u64FromBytes(Uint8List bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}

WasmComponentValueData _bytesData(Uint8List bytes) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List.fromList(bytes),
    items: [for (final byte in bytes) _u64Data(byte)],
  );
}

WasmComponentValueData _u64Data(Object value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.integer,
    rawBytes: Uint8List(0),
    integer: value,
  );
}
