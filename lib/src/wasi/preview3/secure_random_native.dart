import 'dart:math' as math;
import 'dart:typed_data';

final math.Random _secureRandom = math.Random.secure();

/// Returns cryptographically secure random bytes on native Dart runtimes.
Uint8List secureRandomBytes(int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = _secureRandom.nextInt(256);
  }
  return bytes;
}
