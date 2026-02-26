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
  const WasmComponent._({required this.sections, required this.coreModules});

  static const List<int> _magic = <int>[0x00, 0x61, 0x73, 0x6d];
  static const List<int> _componentVersion = <int>[0x0d, 0x00, 0x01, 0x00];

  final List<WasmComponentSection> sections;
  final List<Uint8List> coreModules;

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
    final coreModules = <Uint8List>[];
    while (!reader.isEOF) {
      final id = reader.readByte();
      final sectionSize = reader.readVarUint32();
      final section = reader.readSubReader(sectionSize);
      final payload = section.readRemainingBytes();
      sections.add(WasmComponentSection(id: id, payload: payload));
      if (id == 0x01 && _isCoreModulePayload(payload)) {
        coreModules.add(Uint8List.fromList(payload));
      }
    }

    return WasmComponent._(
      sections: List<WasmComponentSection>.unmodifiable(sections),
      coreModules: List<Uint8List>.unmodifiable(coreModules),
    );
  }

  static bool _isCoreModulePayload(Uint8List payload) {
    if (payload.length < 8) {
      return false;
    }
    return payload[0] == 0x00 &&
        payload[1] == 0x61 &&
        payload[2] == 0x73 &&
        payload[3] == 0x6d &&
        payload[4] == 0x01 &&
        payload[5] == 0x00 &&
        payload[6] == 0x00 &&
        payload[7] == 0x00;
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
