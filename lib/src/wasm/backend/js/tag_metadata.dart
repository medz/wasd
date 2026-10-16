import 'dart:typed_data';

import '../native/interpreter/byte_reader.dart';

/// Keeps only the binary sections needed to recover exported tag signatures.
final class TagMetadataCollector {
  TagMetadataCollector({bool copy = true}) : _copy = copy;

  final bool _copy;
  final _sections = <int, BytesBuilder>{};
  final _headers = <int, List<int>>{};
  var _headerRemaining = 8;
  int? _sectionId;
  var _sectionHeader = <int>[];
  var _length = 0;
  var _multiplier = 1;
  var _remaining = 0;
  var _invalid = false;

  void add(List<int> chunk) {
    if (_invalid) return;
    final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    var offset = 0;
    while (offset < bytes.length) {
      if (_headerRemaining > 0) {
        final count = _headerRemaining < bytes.length - offset
            ? _headerRemaining
            : bytes.length - offset;
        _headerRemaining -= count;
        offset += count;
      } else if (_remaining > 0) {
        final count = _remaining < bytes.length - offset
            ? _remaining
            : bytes.length - offset;
        _sections[_sectionId]?.add(
          Uint8List.sublistView(bytes, offset, offset + count),
        );
        _remaining -= count;
        offset += count;
        if (_remaining == 0) _sectionId = null;
      } else if (_sectionId == null) {
        _sectionId = bytes[offset++];
        _sectionHeader = [_sectionId!];
        _length = 0;
        _multiplier = 1;
      } else {
        final byte = bytes[offset++];
        _sectionHeader.add(byte);
        _length += (byte & 0x7f) * _multiplier;
        if (_sectionHeader.length > 6 ||
            (_sectionHeader.length == 6 && byte > 0x0f)) {
          _invalid = true;
          return;
        }
        if ((byte & 0x80) != 0) {
          _multiplier *= 128;
          continue;
        }
        final sectionId = _sectionId!;
        if (sectionId == 1 ||
            sectionId == 2 ||
            sectionId == 7 ||
            sectionId == 13) {
          _sections[sectionId] = BytesBuilder(copy: _copy);
          _headers[sectionId] = _sectionHeader;
        }
        _remaining = _length;
        if (_remaining == 0) _sectionId = null;
      }
    }
  }

  Uint8List? finish() {
    if (_invalid || _headerRemaining != 0 || _sectionId != null) return null;
    final exports = _sections[7]?.takeBytes();
    if (exports == null || !_hasTagExport(exports)) return null;
    final result = BytesBuilder(copy: false)
      ..add(const [0, 97, 115, 109, 1, 0, 0, 0]);
    for (final entry in _sections.entries) {
      result
        ..add(_headers[entry.key]!)
        ..add(entry.key == 7 ? exports : entry.value.takeBytes());
    }
    return result.takeBytes();
  }

  static bool _hasTagExport(Uint8List bytes) {
    try {
      final reader = ByteReader(bytes);
      final count = reader.readVarUint32();
      for (var i = 0; i < count; i++) {
        reader.readBytesView(reader.readVarUint32());
        final kind = reader.readByte();
        reader.readVarUint32();
        if (kind == 4) return true;
      }
    } on FormatException catch (_) {
      // Compilation reports malformed binaries through the platform compiler.
    }
    return false;
  }
}
