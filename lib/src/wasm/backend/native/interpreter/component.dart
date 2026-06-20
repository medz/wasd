// ignore_for_file: public_member_api_docs

import 'dart:typed_data';

import 'byte_reader.dart';
import 'features.dart';
import 'module.dart';

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

enum WasmComponentCoreSortKind {
  function,
  table,
  memory,
  global,
  tag,
  type,
  module,
  instance,
}

enum WasmComponentSortKind {
  core,
  function,
  value,
  componentType,
  component,
  instance,
}

enum WasmComponentExternKind {
  coreModule,
  function,
  value,
  componentType,
  component,
  instance,
}

enum WasmComponentExternBoundKind { none, equality, subtypeResource, valueType }

final class WasmComponentSortIndex {
  const WasmComponentSortIndex({
    required this.kind,
    required this.index,
    this.coreKind,
  });

  final WasmComponentSortKind kind;
  final int index;
  final WasmComponentCoreSortKind? coreKind;
}

final class WasmComponentSort {
  const WasmComponentSort({required this.kind, this.coreKind});

  final WasmComponentSortKind kind;
  final WasmComponentCoreSortKind? coreKind;
}

final class WasmComponentExternDescriptor {
  const WasmComponentExternDescriptor({
    required this.kind,
    this.boundKind = WasmComponentExternBoundKind.none,
    this.coreKind,
    this.typeIndex,
    this.valueIndex,
    this.valueTypeCode,
  });

  final WasmComponentExternKind kind;
  final WasmComponentExternBoundKind boundKind;
  final WasmComponentCoreSortKind? coreKind;
  final int? typeIndex;
  final int? valueIndex;
  final int? valueTypeCode;
}

final class WasmComponentImport {
  const WasmComponentImport({
    required this.name,
    required this.descriptor,
    this.versionSuffix,
  });

  final String name;
  final String? versionSuffix;
  final WasmComponentExternDescriptor descriptor;
}

final class WasmComponentExport {
  const WasmComponentExport({
    required this.name,
    required this.sort,
    this.versionSuffix,
    this.descriptor,
  });

  final String name;
  final String? versionSuffix;
  final WasmComponentSortIndex sort;
  final WasmComponentExternDescriptor? descriptor;
}

enum WasmComponentInstanceKind { instantiate, inlineExports }

final class WasmComponentInstance {
  const WasmComponentInstance.instantiate({
    required this.componentIndex,
    required this.arguments,
  }) : kind = WasmComponentInstanceKind.instantiate,
       exports = const <WasmComponentInlineExport>[];

  const WasmComponentInstance.inlineExports({required this.exports})
    : kind = WasmComponentInstanceKind.inlineExports,
      componentIndex = null,
      arguments = const <WasmComponentInstantiationArgument>[];

  final WasmComponentInstanceKind kind;
  final int? componentIndex;
  final List<WasmComponentInstantiationArgument> arguments;
  final List<WasmComponentInlineExport> exports;
}

final class WasmComponentInstantiationArgument {
  const WasmComponentInstantiationArgument({
    required this.name,
    required this.sort,
  });

  final String name;
  final WasmComponentSortIndex sort;
}

final class WasmComponentInlineExport {
  const WasmComponentInlineExport({
    required this.name,
    required this.sort,
    this.versionSuffix,
  });

  final String name;
  final String? versionSuffix;
  final WasmComponentSortIndex sort;
}

enum WasmComponentAliasTargetKind { export, coreExport, outer }

final class WasmComponentAlias {
  const WasmComponentAlias({required this.sort, required this.target});

  final WasmComponentSort sort;
  final WasmComponentAliasTarget target;
}

final class WasmComponentAliasTarget {
  const WasmComponentAliasTarget.export({
    required this.instanceIndex,
    required this.name,
  }) : kind = WasmComponentAliasTargetKind.export,
       coreInstanceIndex = null,
       componentDepth = null,
       index = null;

  const WasmComponentAliasTarget.coreExport({
    required this.coreInstanceIndex,
    required this.name,
  }) : kind = WasmComponentAliasTargetKind.coreExport,
       instanceIndex = null,
       componentDepth = null,
       index = null;

  const WasmComponentAliasTarget.outer({
    required this.componentDepth,
    required this.index,
  }) : kind = WasmComponentAliasTargetKind.outer,
       instanceIndex = null,
       coreInstanceIndex = null,
       name = null;

  final WasmComponentAliasTargetKind kind;
  final int? instanceIndex;
  final int? coreInstanceIndex;
  final String? name;
  final int? componentDepth;
  final int? index;
}

final class WasmComponent {
  const WasmComponent({
    required this.sections,
    required this.imports,
    required this.exports,
    required this.components,
    required this.coreModules,
    required this.instances,
    required this.aliases,
  });

  final List<WasmComponentSection> sections;
  final List<WasmComponentImport> imports;
  final List<WasmComponentExport> exports;
  final List<WasmComponent> components;
  final List<WasmModule> coreModules;
  final List<WasmComponentInstance> instances;
  final List<WasmComponentAlias> aliases;

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
    final imports = <WasmComponentImport>[];
    final exports = <WasmComponentExport>[];
    final components = <WasmComponent>[];
    final coreModules = <WasmModule>[];
    final instances = <WasmComponentInstance>[];
    final aliases = <WasmComponentAlias>[];
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
      switch (sectionId) {
        case _coreModuleSectionId:
          coreModules.add(WasmModule.decode(payload, features: features));
        case _componentSectionId:
          components.add(WasmComponent.decode(payload, features: features));
        case _instanceSectionId:
          instances.addAll(_decodeInstances(payload));
        case _aliasSectionId:
          aliases.addAll(_decodeAliases(payload));
        case _importSectionId:
          imports.addAll(_decodeImports(payload));
        case _exportSectionId:
          exports.addAll(_decodeExports(payload));
      }
    }

    return WasmComponent(
      sections: List.unmodifiable(sections),
      imports: List.unmodifiable(imports),
      exports: List.unmodifiable(exports),
      components: List.unmodifiable(components),
      coreModules: List.unmodifiable(coreModules),
      instances: List.unmodifiable(instances),
      aliases: List.unmodifiable(aliases),
    );
  }

  static String _customSectionName(Uint8List payload) {
    final reader = ByteReader(payload);
    final name = reader.readName();
    reader.readRemainingBytes();
    return name;
  }
}

const int _importSectionId = 10;
const int _exportSectionId = 11;
const int _componentSectionId = 4;
const int _coreModuleSectionId = 1;
const int _instanceSectionId = 5;
const int _aliasSectionId = 6;

List<WasmComponentImport> _decodeImports(Uint8List payload) {
  final reader = ByteReader(payload);
  final count = reader.readVarUint32();
  final imports = <WasmComponentImport>[];
  for (var i = 0; i < count; i++) {
    imports.add(
      _readExternWithName(
        reader,
        'import',
        (name, versionSuffix) => WasmComponentImport(
          name: name,
          versionSuffix: versionSuffix,
          descriptor: _readExternDescriptor(reader),
        ),
      ),
    );
  }
  reader.expectEof();
  return imports;
}

List<WasmComponentExport> _decodeExports(Uint8List payload) {
  final reader = ByteReader(payload);
  final count = reader.readVarUint32();
  final exports = <WasmComponentExport>[];
  for (var i = 0; i < count; i++) {
    exports.add(
      _readExternWithName(
        reader,
        'export',
        (name, versionSuffix) => WasmComponentExport(
          name: name,
          versionSuffix: versionSuffix,
          sort: _readSortIndex(reader),
          descriptor: _readOptionalExternDescriptor(reader),
        ),
      ),
    );
  }
  reader.expectEof();
  return exports;
}

List<WasmComponentInstance> _decodeInstances(Uint8List payload) {
  final reader = ByteReader(payload);
  final count = reader.readVarUint32();
  final instances = <WasmComponentInstance>[];
  for (var i = 0; i < count; i++) {
    instances.add(_readInstance(reader));
  }
  reader.expectEof();
  return instances;
}

List<WasmComponentAlias> _decodeAliases(Uint8List payload) {
  final reader = ByteReader(payload);
  final count = reader.readVarUint32();
  final aliases = <WasmComponentAlias>[];
  for (var i = 0; i < count; i++) {
    aliases.add(_readAlias(reader));
  }
  reader.expectEof();
  return aliases;
}

WasmComponentAlias _readAlias(ByteReader reader) {
  return WasmComponentAlias(
    sort: _readSort(reader),
    target: _readAliasTarget(reader),
  );
}

WasmComponentAliasTarget _readAliasTarget(ByteReader reader) {
  final kind = reader.readByte();
  switch (kind) {
    case 0x00:
      return WasmComponentAliasTarget.export(
        instanceIndex: reader.readVarUint32(),
        name: reader.readName(),
      );
    case 0x01:
      return WasmComponentAliasTarget.coreExport(
        coreInstanceIndex: reader.readVarUint32(),
        name: reader.readName(),
      );
    case 0x02:
      return WasmComponentAliasTarget.outer(
        componentDepth: reader.readVarUint32(),
        index: reader.readVarUint32(),
      );
    default:
      throw FormatException(
        'Unsupported Wasm component alias target: 0x${kind.toRadixString(16)}.',
      );
  }
}

WasmComponentInstance _readInstance(ByteReader reader) {
  final kind = reader.readByte();
  switch (kind) {
    case 0x00:
      final componentIndex = reader.readVarUint32();
      final argumentCount = reader.readVarUint32();
      final arguments = <WasmComponentInstantiationArgument>[];
      for (var i = 0; i < argumentCount; i++) {
        arguments.add(_readInstantiationArgument(reader));
      }
      return WasmComponentInstance.instantiate(
        componentIndex: componentIndex,
        arguments: List.unmodifiable(arguments),
      );
    case 0x01:
      final exportCount = reader.readVarUint32();
      final exports = <WasmComponentInlineExport>[];
      for (var i = 0; i < exportCount; i++) {
        exports.add(_readInlineExport(reader));
      }
      return WasmComponentInstance.inlineExports(
        exports: List.unmodifiable(exports),
      );
    default:
      throw FormatException(
        'Unsupported Wasm component instance expression: 0x${kind.toRadixString(16)}.',
      );
  }
}

WasmComponentInstantiationArgument _readInstantiationArgument(
  ByteReader reader,
) {
  return WasmComponentInstantiationArgument(
    name: reader.readName(),
    sort: _readSortIndex(reader),
  );
}

WasmComponentInlineExport _readInlineExport(ByteReader reader) {
  return _readExternWithName(
    reader,
    'inline export',
    (name, versionSuffix) => WasmComponentInlineExport(
      name: name,
      versionSuffix: versionSuffix,
      sort: _readSortIndex(reader),
    ),
  );
}

T _readExternWithName<T>(
  ByteReader reader,
  String context,
  T Function(String name, String? versionSuffix) readRemainder,
) {
  final tag = reader.readByte();
  switch (tag) {
    case 0x00:
      return readRemainder(reader.readName(), null);
    case 0x01:
      final name = reader.readName();
      final afterNameOffset = reader.offset;
      try {
        return readRemainder(name, reader.readName());
      } on FormatException catch (error) {
        if (!_isUnexpectedEof(error)) {
          rethrow;
        }
        // Older component binaries used this prefix without a version suffix.
        reader.offset = afterNameOffset;
        return readRemainder(name, null);
      }
    default:
      throw FormatException(
        'Unsupported Wasm component $context name tag: 0x${tag.toRadixString(16)}.',
      );
  }
}

bool _isUnexpectedEof(FormatException error) {
  return error.message.startsWith('Unexpected EOF');
}

WasmComponentSortIndex _readSortIndex(ByteReader reader) {
  final sort = _readSort(reader);
  return WasmComponentSortIndex(
    kind: sort.kind,
    coreKind: sort.coreKind,
    index: reader.readVarUint32(),
  );
}

WasmComponentSort _readSort(ByteReader reader) {
  final sort = reader.readByte();
  switch (sort) {
    case 0x00:
      return WasmComponentSort(
        kind: WasmComponentSortKind.core,
        coreKind: _readCoreSortKind(reader),
      );
    case 0x01:
      return const WasmComponentSort(kind: WasmComponentSortKind.function);
    case 0x02:
      return const WasmComponentSort(kind: WasmComponentSortKind.value);
    case 0x03:
      return const WasmComponentSort(kind: WasmComponentSortKind.componentType);
    case 0x04:
      return const WasmComponentSort(kind: WasmComponentSortKind.component);
    case 0x05:
      return const WasmComponentSort(kind: WasmComponentSortKind.instance);
    default:
      throw FormatException(
        'Unsupported Wasm component sort: 0x${sort.toRadixString(16)}.',
      );
  }
}

WasmComponentCoreSortKind _readCoreSortKind(ByteReader reader) {
  final sort = reader.readByte();
  switch (sort) {
    case 0x00:
      return WasmComponentCoreSortKind.function;
    case 0x01:
      return WasmComponentCoreSortKind.table;
    case 0x02:
      return WasmComponentCoreSortKind.memory;
    case 0x03:
      return WasmComponentCoreSortKind.global;
    case 0x04:
      return WasmComponentCoreSortKind.tag;
    case 0x10:
      return WasmComponentCoreSortKind.type;
    case 0x11:
      return WasmComponentCoreSortKind.module;
    case 0x12:
      return WasmComponentCoreSortKind.instance;
    default:
      throw FormatException(
        'Unsupported Wasm component core sort: 0x${sort.toRadixString(16)}.',
      );
  }
}

WasmComponentExternDescriptor? _readOptionalExternDescriptor(
  ByteReader reader,
) {
  final present = reader.readByte();
  switch (present) {
    case 0x00:
      return null;
    case 0x01:
      return _readExternDescriptor(reader);
    default:
      throw FormatException(
        'Unsupported Wasm component optional extern descriptor tag: 0x${present.toRadixString(16)}.',
      );
  }
}

WasmComponentExternDescriptor _readExternDescriptor(ByteReader reader) {
  final kind = reader.readByte();
  switch (kind) {
    case 0x00:
      final coreKind = _readCoreSortKind(reader);
      if (coreKind != WasmComponentCoreSortKind.module) {
        throw FormatException(
          'Unsupported Wasm component core extern descriptor kind: $coreKind.',
        );
      }
      return WasmComponentExternDescriptor(
        kind: WasmComponentExternKind.coreModule,
        coreKind: coreKind,
        typeIndex: reader.readVarUint32(),
      );
    case 0x01:
      return WasmComponentExternDescriptor(
        kind: WasmComponentExternKind.function,
        typeIndex: reader.readVarUint32(),
      );
    case 0x02:
      return _readValueExternDescriptor(reader);
    case 0x03:
      return _readTypeExternDescriptor(reader);
    case 0x04:
      return WasmComponentExternDescriptor(
        kind: WasmComponentExternKind.component,
        typeIndex: reader.readVarUint32(),
      );
    case 0x05:
      return WasmComponentExternDescriptor(
        kind: WasmComponentExternKind.instance,
        typeIndex: reader.readVarUint32(),
      );
    default:
      throw FormatException(
        'Unsupported Wasm component extern descriptor: 0x${kind.toRadixString(16)}.',
      );
  }
}

WasmComponentExternDescriptor _readValueExternDescriptor(ByteReader reader) {
  final bound = reader.readByte();
  switch (bound) {
    case 0x00:
      return WasmComponentExternDescriptor(
        kind: WasmComponentExternKind.value,
        boundKind: WasmComponentExternBoundKind.equality,
        valueIndex: reader.readVarUint32(),
      );
    case 0x01:
      return WasmComponentExternDescriptor(
        kind: WasmComponentExternKind.value,
        boundKind: WasmComponentExternBoundKind.valueType,
        valueTypeCode: reader.readVarInt32(),
      );
    default:
      throw FormatException(
        'Unsupported Wasm component value bound: 0x${bound.toRadixString(16)}.',
      );
  }
}

WasmComponentExternDescriptor _readTypeExternDescriptor(ByteReader reader) {
  final bound = reader.readByte();
  switch (bound) {
    case 0x00:
      return WasmComponentExternDescriptor(
        kind: WasmComponentExternKind.componentType,
        boundKind: WasmComponentExternBoundKind.equality,
        typeIndex: reader.readVarUint32(),
      );
    case 0x01:
      return const WasmComponentExternDescriptor(
        kind: WasmComponentExternKind.componentType,
        boundKind: WasmComponentExternBoundKind.subtypeResource,
      );
    default:
      throw FormatException(
        'Unsupported Wasm component type bound: 0x${bound.toRadixString(16)}.',
      );
  }
}
