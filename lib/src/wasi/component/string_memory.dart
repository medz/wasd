import 'dart:convert';
import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../../wasm/memory.dart' as wasm;

/// Canonical string encoding used by Component Model memory adapters.
enum WASIComponentCanonicalStringEncoding {
  /// UTF-8 canonical string encoding.
  utf8,

  /// UTF-16LE canonical string encoding.
  utf16,

  /// Latin1+UTF-16 canonical string encoding.
  latin1Utf16;

  /// Resolves the string encoding selected by decoded canonical options.
  static WASIComponentCanonicalStringEncoding fromCanonicalOptions(
    List<WasmComponentCanonicalOption> options,
  ) {
    for (final option in options) {
      switch (option.kind) {
        case WasmComponentCanonicalOptionKind.stringEncodingUtf8:
          return WASIComponentCanonicalStringEncoding.utf8;
        case WasmComponentCanonicalOptionKind.stringEncodingUtf16:
          return WASIComponentCanonicalStringEncoding.utf16;
        case WasmComponentCanonicalOptionKind.stringEncodingLatin1Utf16:
          return WASIComponentCanonicalStringEncoding.latin1Utf16;
        case WasmComponentCanonicalOptionKind.memory:
        case WasmComponentCanonicalOptionKind.realloc:
        case WasmComponentCanonicalOptionKind.postReturn:
        case WasmComponentCanonicalOptionKind.async:
        case WasmComponentCanonicalOptionKind.callback:
          break;
      }
    }
    return WASIComponentCanonicalStringEncoding.utf8;
  }
}

/// Result of writing a canonical string to component memory.
final class WASIComponentMemoryString {
  /// Creates a memory string range.
  const WASIComponentMemoryString({
    required this.pointer,
    required this.canonicalLength,
    required this.byteLength,
  });

  /// Pointer to the first byte in guest memory.
  final int pointer;

  /// Canonical ABI string length value paired with [pointer].
  ///
  /// UTF-8 uses byte length, UTF-16 uses code-unit length, and
  /// Latin1+UTF-16 uses a tagged code-unit length for UTF-16 payloads.
  final int canonicalLength;

  /// Byte length of the string payload in guest memory.
  final int byteLength;
}

/// Canonical-style realloc callback used when lifting strings into memory.
typedef WASIComponentCanonicalRealloc =
    int Function(int oldPointer, int oldSize, int alignment, int newSize);

const int _u32Max = 0xffffffff;
const int _latin1Utf16Tag = 0x80000000;
const int _latin1Utf16LengthMask = 0x7fffffff;
const int _memoryStringRecordByteLength = 8;
const int _memoryStringRecordAlignment = 4;

/// Reads a canonical string payload from [memory].
String readWASIComponentCanonicalString(
  wasm.Memory memory,
  int pointer,
  int canonicalLength,
  WASIComponentCanonicalStringEncoding encoding,
) {
  RangeError.checkNotNegative(pointer, 'pointer');
  _checkU32(canonicalLength, 'length');
  _checkAligned(pointer, _canonicalStringAlignment(encoding), 'pointer');
  final byteLength = _canonicalStringByteLength(canonicalLength, encoding);
  final bytes = Uint8List.view(memory.buffer);
  _checkMemoryRange(bytes, pointer, byteLength, 'pointer + length');
  final slice = Uint8List.sublistView(bytes, pointer, pointer + byteLength);
  return switch (encoding) {
    WASIComponentCanonicalStringEncoding.utf8 => utf8.decode(slice),
    WASIComponentCanonicalStringEncoding.utf16 => _decodeUtf16Le(slice),
    WASIComponentCanonicalStringEncoding.latin1Utf16 =>
      _isLatin1Utf16Tagged(canonicalLength)
          ? _decodeUtf16Le(slice)
          : String.fromCharCodes(slice),
  };
}

/// Reads a canonical `(ptr, len)` string record from [memory].
String readWASIComponentCanonicalStringRecord(
  wasm.Memory memory,
  int pointer,
  WASIComponentCanonicalStringEncoding encoding,
) {
  checkWASIComponentCanonicalStringRecordRange(memory, pointer, 1);
  final data = ByteData.view(memory.buffer);
  final stringPointer = data.getUint32(pointer, Endian.little);
  final canonicalLength = data.getUint32(pointer + 4, Endian.little);
  return readWASIComponentCanonicalString(
    memory,
    stringPointer,
    canonicalLength,
    encoding,
  );
}

/// Validates that [elementCount] contiguous `(ptr, len)` records fit in memory.
void checkWASIComponentCanonicalStringRecordRange(
  wasm.Memory memory,
  int pointer,
  int elementCount,
) {
  RangeError.checkNotNegative(pointer, 'pointer');
  RangeError.checkNotNegative(elementCount, 'elementCount');
  _checkAligned(pointer, _memoryStringRecordAlignment, 'pointer');
  final bytes = Uint8List.view(memory.buffer);
  _checkMemoryRange(
    bytes,
    pointer,
    elementCount * _memoryStringRecordByteLength,
    'pointer + byteLength',
  );
}

/// Writes a canonical string payload into [memory] through [realloc].
WASIComponentMemoryString writeWASIComponentCanonicalString(
  wasm.Memory memory,
  WASIComponentCanonicalRealloc realloc,
  String value,
  WASIComponentCanonicalStringEncoding encoding,
) {
  final encoded = _encodeCanonicalString(value, encoding);
  final pointer = realloc(0, 0, encoded.alignment, encoded.bytes.length);
  RangeError.checkNotNegative(pointer, 'pointer');
  _checkAligned(pointer, encoded.alignment, 'pointer');

  final bytes = Uint8List.view(memory.buffer);
  _checkMemoryRange(bytes, pointer, encoded.bytes.length, 'pointer + length');
  bytes.setRange(pointer, pointer + encoded.bytes.length, encoded.bytes);
  return WASIComponentMemoryString(
    pointer: pointer,
    canonicalLength: encoded.canonicalLength,
    byteLength: encoded.bytes.length,
  );
}

/// Writes a canonical `(ptr, len)` string record into [memory].
void writeWASIComponentMemoryStringRecord(
  wasm.Memory memory,
  int pointer,
  WASIComponentMemoryString result,
) {
  RangeError.checkNotNegative(pointer, 'pointer');
  _checkAligned(pointer, _memoryStringRecordAlignment, 'pointer');
  _checkU32(result.pointer, 'pointer value');
  _checkU32(result.canonicalLength, 'length value');
  final bytes = Uint8List.view(memory.buffer);
  _checkMemoryRange(
    bytes,
    pointer,
    _memoryStringRecordByteLength,
    'pointer + 8',
  );
  final data = ByteData.view(memory.buffer);
  data.setUint32(pointer, result.pointer, Endian.little);
  data.setUint32(pointer + 4, result.canonicalLength, Endian.little);
}

int _canonicalStringAlignment(WASIComponentCanonicalStringEncoding encoding) {
  return switch (encoding) {
    WASIComponentCanonicalStringEncoding.utf8 => 1,
    WASIComponentCanonicalStringEncoding.utf16 => 2,
    WASIComponentCanonicalStringEncoding.latin1Utf16 => 2,
  };
}

int _canonicalStringByteLength(
  int canonicalLength,
  WASIComponentCanonicalStringEncoding encoding,
) {
  return switch (encoding) {
    WASIComponentCanonicalStringEncoding.utf8 => canonicalLength,
    WASIComponentCanonicalStringEncoding.utf16 => canonicalLength * 2,
    WASIComponentCanonicalStringEncoding.latin1Utf16 =>
      _isLatin1Utf16Tagged(canonicalLength)
          ? (canonicalLength & _latin1Utf16LengthMask) * 2
          : canonicalLength,
  };
}

_EncodedCanonicalString _encodeCanonicalString(
  String value,
  WASIComponentCanonicalStringEncoding encoding,
) {
  return switch (encoding) {
    WASIComponentCanonicalStringEncoding.utf8 => _encodeUtf8String(value),
    WASIComponentCanonicalStringEncoding.utf16 => _encodeUtf16String(value),
    WASIComponentCanonicalStringEncoding.latin1Utf16 =>
      _encodeLatin1Utf16String(value),
  };
}

_EncodedCanonicalString _encodeUtf8String(String value) {
  final codeUnits = value.codeUnits;
  _validateUtf16CodeUnits(codeUnits);
  final bytes = Uint8List.fromList(utf8.encode(value));
  return _EncodedCanonicalString(
    bytes: bytes,
    canonicalLength: bytes.length,
    alignment: 1,
  );
}

_EncodedCanonicalString _encodeUtf16String(String value) {
  final codeUnits = value.codeUnits;
  _validateUtf16CodeUnits(codeUnits);
  final bytes = _encodeUtf16CodeUnits(codeUnits);
  return _EncodedCanonicalString(
    bytes: bytes,
    canonicalLength: codeUnits.length,
    alignment: 2,
  );
}

_EncodedCanonicalString _encodeLatin1Utf16String(String value) {
  final codeUnits = value.codeUnits;
  _validateUtf16CodeUnits(codeUnits);
  final latin1Bytes = _tryEncodeLatin1(codeUnits);
  if (latin1Bytes != null) {
    return _EncodedCanonicalString(
      bytes: latin1Bytes,
      canonicalLength: latin1Bytes.length,
      alignment: 2,
    );
  }

  final codeUnitLength = codeUnits.length;
  if (codeUnitLength > _latin1Utf16LengthMask) {
    throw RangeError.range(
      codeUnitLength,
      0,
      _latin1Utf16LengthMask,
      'codeUnitLength',
    );
  }
  return _EncodedCanonicalString(
    bytes: _encodeUtf16CodeUnits(codeUnits),
    canonicalLength: _latin1Utf16Tag | codeUnitLength,
    alignment: 2,
  );
}

Uint8List? _tryEncodeLatin1(List<int> codeUnits) {
  final bytes = Uint8List(codeUnits.length);
  for (var i = 0; i < codeUnits.length; i++) {
    final codeUnit = codeUnits[i];
    if (codeUnit > 0xff) {
      return null;
    }
    bytes[i] = codeUnit;
  }
  return bytes;
}

Uint8List _encodeUtf16CodeUnits(List<int> codeUnits) {
  final bytes = Uint8List(codeUnits.length * 2);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < codeUnits.length; i++) {
    data.setUint16(i * 2, codeUnits[i], Endian.little);
  }
  return bytes;
}

String _decodeUtf16Le(Uint8List bytes) {
  if (bytes.length.isOdd) {
    throw const FormatException('UTF-16 string byte length must be even.');
  }
  final data = ByteData.sublistView(bytes);
  final codeUnits = List<int>.filled(bytes.length ~/ 2, 0);
  for (var i = 0; i < codeUnits.length; i++) {
    codeUnits[i] = data.getUint16(i * 2, Endian.little);
  }
  _validateUtf16CodeUnits(codeUnits);
  return String.fromCharCodes(codeUnits);
}

void _validateUtf16CodeUnits(List<int> codeUnits) {
  for (var i = 0; i < codeUnits.length; i++) {
    final codeUnit = codeUnits[i];
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
      if (i + 1 >= codeUnits.length ||
          codeUnits[i + 1] < 0xdc00 ||
          codeUnits[i + 1] > 0xdfff) {
        throw const FormatException('Malformed UTF-16 string.');
      }
      i++;
    } else if (codeUnit >= 0xdc00 && codeUnit <= 0xdfff) {
      throw const FormatException('Malformed UTF-16 string.');
    }
  }
}

bool _isLatin1Utf16Tagged(int canonicalLength) {
  return canonicalLength & _latin1Utf16Tag != 0;
}

void _checkU32(int value, String name) {
  RangeError.checkNotNegative(value, name);
  if (value > _u32Max) {
    throw RangeError.range(value, 0, _u32Max, name);
  }
}

void _checkAligned(int pointer, int alignment, String name) {
  if (alignment > 1 && pointer % alignment != 0) {
    throw StateError('$name must be $alignment-byte aligned.');
  }
}

void _checkMemoryRange(
  Uint8List bytes,
  int pointer,
  int byteLength,
  String name,
) {
  RangeError.checkNotNegative(pointer, 'pointer');
  RangeError.checkNotNegative(byteLength, 'byteLength');
  if (pointer > bytes.length || byteLength > bytes.length - pointer) {
    throw RangeError.range(pointer + byteLength, 0, bytes.length, name);
  }
}

final class _EncodedCanonicalString {
  const _EncodedCanonicalString({
    required this.bytes,
    required this.canonicalLength,
    required this.alignment,
  });

  final Uint8List bytes;
  final int canonicalLength;
  final int alignment;
}
