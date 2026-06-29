import 'dart:math' as math;
import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../component/wit_adapter.dart';
import 'secure_random.dart' as secure_random;

/// WASI 0.3 `wasi:random` host imports.
final class WASIPreview3RandomHost {
  /// Creates a random host import provider.
  WASIPreview3RandomHost({
    math.Random? secureRandom,
    math.Random? insecureRandom,
  }) : _secureRandom = secureRandom,
       _insecureRandom = insecureRandom ?? math.Random();

  static const int _maxBytesPerCall = 64 * 1024;

  final math.Random? _secureRandom;
  final math.Random _insecureRandom;
  (BigInt, BigInt)? _insecureSeed;

  /// Import callbacks keyed by canonical WIT adapter names.
  late final Map<String, WASIComponentWitAdapterCallback> imports =
      Map<String, WASIComponentWitAdapterCallback>.unmodifiable({
        'wasi:random/random@0.3.0.get-random-bytes': (args) =>
            _secureRandomBytes(args.single),
        'wasi:random/random@0.3.0.get-random-u64': (_) => _secureRandomU64(),
        'wasi:random/insecure@0.3.0.get-insecure-random-bytes': (args) =>
            _randomBytes(args.single, _insecureRandom),
        'wasi:random/insecure@0.3.0.get-insecure-random-u64': (_) =>
            _nextU64(_insecureRandom),
        'wasi:random/insecure-seed@0.3.0.get-insecure-seed': (_) =>
            _insecureSeedTuple(),
      });

  WasmComponentValueData _randomBytes(Object? maxLenValue, math.Random random) {
    final length = _boundedLength(maxLenValue);
    return _bytesData(_randomRawBytes(length, random));
  }

  WasmComponentValueData _secureRandomBytes(Object? maxLenValue) {
    final length = _boundedLength(maxLenValue);
    final injected = _secureRandom;
    final bytes = injected == null
        ? secure_random.secureRandomBytes(length)
        : _randomRawBytes(length, injected);
    return _bytesData(bytes);
  }

  BigInt _secureRandomU64() {
    final injected = _secureRandom;
    if (injected != null) {
      return _nextU64(injected);
    }
    return _u64FromBytes(secure_random.secureRandomBytes(8));
  }

  WasmComponentValueData _bytesData(Uint8List bytes) {
    return WasmComponentValueData(
      kind: WasmComponentValueDataKind.list,
      rawBytes: Uint8List.fromList(bytes),
      items: [
        for (final byte in bytes)
          WasmComponentValueData(
            kind: WasmComponentValueDataKind.integer,
            rawBytes: Uint8List(0),
            integer: byte,
          ),
      ],
    );
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

  int _boundedLength(Object? value) {
    final maxLen = switch (value) {
      int() => BigInt.from(value),
      BigInt() => value,
      _ => BigInt.zero,
    };
    if (maxLen <= BigInt.zero) {
      return 0;
    }
    final cap = BigInt.from(_maxBytesPerCall);
    return maxLen > cap ? _maxBytesPerCall : maxLen.toInt();
  }
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

WasmComponentValueData _u64Data(BigInt value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.integer,
    rawBytes: Uint8List(0),
    integer: value,
  );
}
