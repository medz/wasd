// ignore_for_file: public_member_api_docs

import 'dart:typed_data';

import 'byte_reader.dart';
import 'features.dart';

final class WasmComponentSection {
  const WasmComponentSection({
    required this.id,
    required this.offset,
    required this.payloadOffset,
    required this.payloadSize,
    this.customName,
  });

  final int id;
  final int offset;
  final int payloadOffset;
  final int payloadSize;
  final String? customName;
}

final class WasmComponent {
  const WasmComponent({required this.sections});

  final List<WasmComponentSection> sections;

  static bool hasComponentPreamble(List<int> bytes) {
    return bytes.length >= 8 &&
        bytes[0] == 0x00 &&
        bytes[1] == 0x61 &&
        bytes[2] == 0x73 &&
        bytes[3] == 0x6d &&
        bytes[4] == 0x0d &&
        bytes[5] == 0x00 &&
        bytes[6] == 0x01 &&
        bytes[7] == 0x00;
  }

  static WasmComponent decode(
    Uint8List bytes, {
    WasmFeatureSet features = const WasmFeatureSet(componentModel: true),
  }) {
    if (!features.componentModel) {
      throw UnsupportedError(
        'Component model decoding requires the component-model feature.',
      );
    }

    final reader = ByteReader(bytes);
    final magic = reader.readBytes(4);
    if (magic[0] != 0x00 ||
        magic[1] != 0x61 ||
        magic[2] != 0x73 ||
        magic[3] != 0x6d) {
      throw const FormatException('Invalid Wasm component magic number.');
    }

    final version = reader.readBytes(2);
    if (version[0] != 0x0d || version[1] != 0x00) {
      throw const FormatException('Unsupported Wasm component version.');
    }

    final layer = reader.readBytes(2);
    if (layer[0] != 0x01 || layer[1] != 0x00) {
      throw const FormatException('Unsupported Wasm component layer.');
    }

    final sections = <WasmComponentSection>[];
    while (!reader.isEOF) {
      final sectionOffset = reader.offset;
      final sectionId = reader.readByte();
      if (sectionId > 12) {
        throw FormatException(
          'Unsupported Wasm component section id: 0x${sectionId.toRadixString(16)}.',
        );
      }

      final payloadSize = reader.readVarUint32();
      final payloadOffset = reader.offset;
      final payload = reader.readBytes(payloadSize);
      sections.add(
        WasmComponentSection(
          id: sectionId,
          offset: sectionOffset,
          payloadOffset: payloadOffset,
          payloadSize: payloadSize,
          customName: sectionId == 0 ? _customSectionName(payload) : null,
        ),
      );
    }

    return WasmComponent(sections: List.unmodifiable(sections));
  }

  static String _customSectionName(Uint8List payload) {
    final reader = ByteReader(payload);
    final name = reader.readName();
    reader.readRemainingBytes();
    return name;
  }
}
