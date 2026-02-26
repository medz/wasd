import 'dart:typed_data';

import 'byte_reader.dart';
import 'features.dart';

/// Decoded component section payload.
final class WasmComponentSection {
  const WasmComponentSection({required this.id, required this.payload});

  final int id;
  final Uint8List payload;
}

/// Minimal component binary decoder.
///
/// This currently validates the component header and collects raw sections.
/// Full canonical ABI/lowering/lifting semantics are implemented separately.
final class WasmComponent {
  const WasmComponent._({required this.sections});

  static const List<int> _magic = <int>[0x00, 0x61, 0x73, 0x6d];
  static const List<int> _componentVersion = <int>[0x0d, 0x00, 0x01, 0x00];

  final List<WasmComponentSection> sections;

  static WasmComponent decode(
    Uint8List componentBytes, {
    WasmFeatureSet features = const WasmFeatureSet(),
  }) {
    if (!features.componentModel) {
      throw UnsupportedError(
        'Component model binary requires `componentModel` feature to be enabled.',
      );
    }

    final reader = ByteReader(componentBytes);
    final magic = reader.readBytes(4);
    if (!_sameBytes(magic, _magic)) {
      throw const FormatException('Invalid Wasm component magic number.');
    }

    final version = reader.readBytes(4);
    if (!_sameBytes(version, _componentVersion)) {
      throw const FormatException('Unsupported Wasm component version.');
    }

    final sections = <WasmComponentSection>[];
    while (!reader.isEOF) {
      final id = reader.readByte();
      final sectionSize = reader.readVarUint32();
      final section = reader.readSubReader(sectionSize);
      sections.add(
        WasmComponentSection(id: id, payload: section.readRemainingBytes()),
      );
    }

    return WasmComponent._(
      sections: List<WasmComponentSection>.unmodifiable(sections),
    );
  }

  static bool _sameBytes(Uint8List actual, List<int> expected) {
    if (actual.length != expected.length) {
      return false;
    }
    for (var i = 0; i < actual.length; i++) {
      if (actual[i] != expected[i]) {
        return false;
      }
    }
    return true;
  }
}
