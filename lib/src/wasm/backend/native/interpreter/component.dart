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

final class WasmComponentCoreSortIndex {
  const WasmComponentCoreSortIndex({required this.kind, required this.index});

  final WasmComponentCoreSortKind kind;
  final int index;
}

final class WasmComponentExternDescriptor {
  const WasmComponentExternDescriptor({
    required this.kind,
    this.boundKind = WasmComponentExternBoundKind.none,
    this.coreKind,
    this.typeIndex,
    this.valueIndex,
    this.valueType,
    this.valueTypeCode,
  });

  final WasmComponentExternKind kind;
  final WasmComponentExternBoundKind boundKind;
  final WasmComponentCoreSortKind? coreKind;
  final int? typeIndex;
  final int? valueIndex;
  final WasmComponentValueType? valueType;
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

enum WasmComponentCoreInstanceKind { instantiate, inlineExports }

final class WasmComponentCoreInstance {
  const WasmComponentCoreInstance.instantiate({
    required this.moduleIndex,
    required this.arguments,
  }) : kind = WasmComponentCoreInstanceKind.instantiate,
       exports = const <WasmComponentCoreInlineExport>[];

  const WasmComponentCoreInstance.inlineExports({required this.exports})
    : kind = WasmComponentCoreInstanceKind.inlineExports,
      moduleIndex = null,
      arguments = const <WasmComponentCoreInstantiationArgument>[];

  final WasmComponentCoreInstanceKind kind;
  final int? moduleIndex;
  final List<WasmComponentCoreInstantiationArgument> arguments;
  final List<WasmComponentCoreInlineExport> exports;
}

final class WasmComponentCoreInstantiationArgument {
  const WasmComponentCoreInstantiationArgument({
    required this.name,
    required this.instanceIndex,
  });

  final String name;
  final int instanceIndex;
}

final class WasmComponentCoreInlineExport {
  const WasmComponentCoreInlineExport({required this.name, required this.sort});

  final String name;
  final WasmComponentCoreSortIndex sort;
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

final class WasmComponentStart {
  const WasmComponentStart({
    required this.functionIndex,
    required this.arguments,
    required this.resultCount,
  });

  final int functionIndex;
  final List<int> arguments;
  final int resultCount;
}

enum WasmComponentPrimitiveValueType {
  boolean,
  s8,
  u8,
  s16,
  u16,
  s32,
  u32,
  s64,
  u64,
  f32,
  f64,
  char,
  string,
  errorContext,
}

enum WasmComponentValueTypeKind { primitive, typeIndex }

final class WasmComponentValueType {
  const WasmComponentValueType.primitive(this.primitive)
    : kind = WasmComponentValueTypeKind.primitive,
      typeIndex = null;

  const WasmComponentValueType.typeIndex(this.typeIndex)
    : kind = WasmComponentValueTypeKind.typeIndex,
      primitive = null;

  final WasmComponentValueTypeKind kind;
  final WasmComponentPrimitiveValueType? primitive;
  final int? typeIndex;
}

final class WasmComponentCanonicalResult {
  const WasmComponentCanonicalResult.none() : valueType = null;

  const WasmComponentCanonicalResult.value(this.valueType);

  final WasmComponentValueType? valueType;
}

enum WasmComponentCanonicalOptionKind {
  stringEncodingUtf8,
  stringEncodingUtf16,
  stringEncodingLatin1Utf16,
  memory,
  realloc,
  postReturn,
  async,
  callback,
}

final class WasmComponentCanonicalOption {
  const WasmComponentCanonicalOption({required this.kind, this.index});

  final WasmComponentCanonicalOptionKind kind;
  final int? index;
}

enum WasmComponentCanonicalKind {
  lift,
  lower,
  resourceNew,
  resourceDrop,
  resourceRep,
  backpressureSet,
  backpressureInc,
  backpressureDec,
  taskReturn,
  taskCancel,
  contextGet,
  contextSet,
  threadYield,
  subtaskCancel,
  subtaskDrop,
  streamNew,
  streamRead,
  streamWrite,
  streamCancelRead,
  streamCancelWrite,
  streamDropReadable,
  streamDropWritable,
  futureNew,
  futureRead,
  futureWrite,
  futureCancelRead,
  futureCancelWrite,
  futureDropReadable,
  futureDropWritable,
  errorContextNew,
  errorContextDebugMessage,
  errorContextDrop,
  waitableSetNew,
  waitableSetWait,
  waitableSetPoll,
  waitableSetDrop,
  waitableJoin,
  threadIndex,
  threadNewIndirect,
  threadSwitchTo,
  threadSuspend,
  threadResumeLater,
  threadYieldTo,
  threadSpawnRef,
  threadSpawnIndirect,
  threadAvailableParallelism,
}

final class WasmComponentCanonicalDefinition {
  const WasmComponentCanonicalDefinition({
    required this.kind,
    this.coreFunctionIndex,
    this.functionIndex,
    this.typeIndex,
    this.tableIndex,
    this.memoryIndex,
    this.contextIndex,
    this.options = const <WasmComponentCanonicalOption>[],
    this.result,
    this.isAsync = false,
    this.isCancellable = false,
    this.isShared = false,
  });

  final WasmComponentCanonicalKind kind;
  final int? coreFunctionIndex;
  final int? functionIndex;
  final int? typeIndex;
  final int? tableIndex;
  final int? memoryIndex;
  final int? contextIndex;
  final List<WasmComponentCanonicalOption> options;
  final WasmComponentCanonicalResult? result;
  final bool isAsync;
  final bool isCancellable;
  final bool isShared;
}

final class WasmComponent {
  const WasmComponent({
    required this.sections,
    required this.imports,
    required this.exports,
    required this.components,
    required this.coreModules,
    required this.coreInstances,
    required this.instances,
    required this.aliases,
    required this.starts,
    required this.canonicalDefinitions,
  });

  final List<WasmComponentSection> sections;
  final List<WasmComponentImport> imports;
  final List<WasmComponentExport> exports;
  final List<WasmComponent> components;
  final List<WasmModule> coreModules;
  final List<WasmComponentCoreInstance> coreInstances;
  final List<WasmComponentInstance> instances;
  final List<WasmComponentAlias> aliases;
  final List<WasmComponentStart> starts;
  final List<WasmComponentCanonicalDefinition> canonicalDefinitions;

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
    final coreInstances = <WasmComponentCoreInstance>[];
    final instances = <WasmComponentInstance>[];
    final aliases = <WasmComponentAlias>[];
    final starts = <WasmComponentStart>[];
    final canonicalDefinitions = <WasmComponentCanonicalDefinition>[];
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
        case _coreInstanceSectionId:
          coreInstances.addAll(_decodeCoreInstances(payload));
        case _componentSectionId:
          components.add(WasmComponent.decode(payload, features: features));
        case _instanceSectionId:
          instances.addAll(_decodeInstances(payload));
        case _aliasSectionId:
          aliases.addAll(_decodeAliases(payload));
        case _canonicalSectionId:
          canonicalDefinitions.addAll(_decodeCanonicalDefinitions(payload));
        case _startSectionId:
          starts.add(_decodeStart(payload));
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
      coreInstances: List.unmodifiable(coreInstances),
      instances: List.unmodifiable(instances),
      aliases: List.unmodifiable(aliases),
      starts: List.unmodifiable(starts),
      canonicalDefinitions: List.unmodifiable(canonicalDefinitions),
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
const int _coreInstanceSectionId = 2;
const int _instanceSectionId = 5;
const int _aliasSectionId = 6;
const int _canonicalSectionId = 8;
const int _startSectionId = 9;

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

List<WasmComponentCoreInstance> _decodeCoreInstances(Uint8List payload) {
  final reader = ByteReader(payload);
  final count = reader.readVarUint32();
  final instances = <WasmComponentCoreInstance>[];
  for (var i = 0; i < count; i++) {
    instances.add(_readCoreInstance(reader));
  }
  reader.expectEof();
  return instances;
}

WasmComponentCoreInstance _readCoreInstance(ByteReader reader) {
  final kind = reader.readByte();
  switch (kind) {
    case 0x00:
      final moduleIndex = reader.readVarUint32();
      final argumentCount = reader.readVarUint32();
      final arguments = <WasmComponentCoreInstantiationArgument>[];
      for (var i = 0; i < argumentCount; i++) {
        arguments.add(_readCoreInstantiationArgument(reader));
      }
      return WasmComponentCoreInstance.instantiate(
        moduleIndex: moduleIndex,
        arguments: List.unmodifiable(arguments),
      );
    case 0x01:
      final exportCount = reader.readVarUint32();
      final exports = <WasmComponentCoreInlineExport>[];
      for (var i = 0; i < exportCount; i++) {
        exports.add(_readCoreInlineExport(reader));
      }
      return WasmComponentCoreInstance.inlineExports(
        exports: List.unmodifiable(exports),
      );
    default:
      throw FormatException(
        'Unsupported Wasm component core instance expression: 0x${kind.toRadixString(16)}.',
      );
  }
}

WasmComponentCoreInstantiationArgument _readCoreInstantiationArgument(
  ByteReader reader,
) {
  final name = reader.readName();
  final sort = reader.readByte();
  if (sort != 0x12) {
    throw FormatException(
      'Unsupported Wasm component core instantiation argument sort: 0x${sort.toRadixString(16)}.',
    );
  }
  return WasmComponentCoreInstantiationArgument(
    name: name,
    instanceIndex: reader.readVarUint32(),
  );
}

WasmComponentCoreInlineExport _readCoreInlineExport(ByteReader reader) {
  return WasmComponentCoreInlineExport(
    name: reader.readName(),
    sort: _readCoreSortIndex(reader),
  );
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

WasmComponentStart _decodeStart(Uint8List payload) {
  final reader = ByteReader(payload);
  final functionIndex = reader.readVarUint32();
  final argumentCount = reader.readVarUint32();
  final arguments = <int>[];
  for (var i = 0; i < argumentCount; i++) {
    arguments.add(reader.readVarUint32());
  }
  final resultCount = reader.readVarUint32();
  reader.expectEof();
  return WasmComponentStart(
    functionIndex: functionIndex,
    arguments: List.unmodifiable(arguments),
    resultCount: resultCount,
  );
}

List<WasmComponentCanonicalDefinition> _decodeCanonicalDefinitions(
  Uint8List payload,
) {
  final reader = ByteReader(payload);
  final count = reader.readVarUint32();
  final definitions = <WasmComponentCanonicalDefinition>[];
  for (var i = 0; i < count; i++) {
    definitions.add(_readCanonicalDefinition(reader));
  }
  reader.expectEof();
  return definitions;
}

WasmComponentCanonicalDefinition _readCanonicalDefinition(ByteReader reader) {
  final opcode = reader.readByte();
  switch (opcode) {
    case 0x00:
      _expectCanonicalFunctionSort(reader);
      final coreFunctionIndex = reader.readVarUint32();
      final options = _readCanonicalOptions(reader);
      return WasmComponentCanonicalDefinition(
        kind: WasmComponentCanonicalKind.lift,
        coreFunctionIndex: coreFunctionIndex,
        options: options,
        typeIndex: reader.readVarUint32(),
      );
    case 0x01:
      _expectCanonicalFunctionSort(reader);
      return WasmComponentCanonicalDefinition(
        kind: WasmComponentCanonicalKind.lower,
        functionIndex: reader.readVarUint32(),
        options: _readCanonicalOptions(reader),
      );
    case 0x02:
      return _readCanonicalTypeIndex(
        reader,
        WasmComponentCanonicalKind.resourceNew,
      );
    case 0x03:
      return _readCanonicalTypeIndex(
        reader,
        WasmComponentCanonicalKind.resourceDrop,
      );
    case 0x04:
      return _readCanonicalTypeIndex(
        reader,
        WasmComponentCanonicalKind.resourceRep,
      );
    case 0x08:
      return const WasmComponentCanonicalDefinition(
        kind: WasmComponentCanonicalKind.backpressureSet,
      );
    case 0x24:
      return const WasmComponentCanonicalDefinition(
        kind: WasmComponentCanonicalKind.backpressureInc,
      );
    case 0x25:
      return const WasmComponentCanonicalDefinition(
        kind: WasmComponentCanonicalKind.backpressureDec,
      );
    case 0x09:
      return WasmComponentCanonicalDefinition(
        kind: WasmComponentCanonicalKind.taskReturn,
        result: _readCanonicalResult(reader),
        options: _readCanonicalOptions(reader),
      );
    case 0x05:
      return const WasmComponentCanonicalDefinition(
        kind: WasmComponentCanonicalKind.taskCancel,
      );
    case 0x0a:
      return _readContextCanonical(
        reader,
        WasmComponentCanonicalKind.contextGet,
      );
    case 0x0b:
      return _readContextCanonical(
        reader,
        WasmComponentCanonicalKind.contextSet,
      );
    case 0x0c:
      return _readCancellableCanonical(
        reader,
        WasmComponentCanonicalKind.threadYield,
      );
    case 0x06:
      return _readAsyncCanonical(
        reader,
        WasmComponentCanonicalKind.subtaskCancel,
      );
    case 0x0d:
      return const WasmComponentCanonicalDefinition(
        kind: WasmComponentCanonicalKind.subtaskDrop,
      );
    case 0x0e:
      return _readCanonicalTypeIndex(
        reader,
        WasmComponentCanonicalKind.streamNew,
      );
    case 0x0f:
      return _readTypedOptionsCanonical(
        reader,
        WasmComponentCanonicalKind.streamRead,
      );
    case 0x10:
      return _readTypedOptionsCanonical(
        reader,
        WasmComponentCanonicalKind.streamWrite,
      );
    case 0x11:
      return _readTypedAsyncCanonical(
        reader,
        WasmComponentCanonicalKind.streamCancelRead,
      );
    case 0x12:
      return _readTypedAsyncCanonical(
        reader,
        WasmComponentCanonicalKind.streamCancelWrite,
      );
    case 0x13:
      return _readCanonicalTypeIndex(
        reader,
        WasmComponentCanonicalKind.streamDropReadable,
      );
    case 0x14:
      return _readCanonicalTypeIndex(
        reader,
        WasmComponentCanonicalKind.streamDropWritable,
      );
    case 0x15:
      return _readCanonicalTypeIndex(
        reader,
        WasmComponentCanonicalKind.futureNew,
      );
    case 0x16:
      return _readTypedOptionsCanonical(
        reader,
        WasmComponentCanonicalKind.futureRead,
      );
    case 0x17:
      return _readTypedOptionsCanonical(
        reader,
        WasmComponentCanonicalKind.futureWrite,
      );
    case 0x18:
      return _readTypedAsyncCanonical(
        reader,
        WasmComponentCanonicalKind.futureCancelRead,
      );
    case 0x19:
      return _readTypedAsyncCanonical(
        reader,
        WasmComponentCanonicalKind.futureCancelWrite,
      );
    case 0x1a:
      return _readCanonicalTypeIndex(
        reader,
        WasmComponentCanonicalKind.futureDropReadable,
      );
    case 0x1b:
      return _readCanonicalTypeIndex(
        reader,
        WasmComponentCanonicalKind.futureDropWritable,
      );
    case 0x1c:
      return WasmComponentCanonicalDefinition(
        kind: WasmComponentCanonicalKind.errorContextNew,
        options: _readCanonicalOptions(reader),
      );
    case 0x1d:
      return WasmComponentCanonicalDefinition(
        kind: WasmComponentCanonicalKind.errorContextDebugMessage,
        options: _readCanonicalOptions(reader),
      );
    case 0x1e:
      return const WasmComponentCanonicalDefinition(
        kind: WasmComponentCanonicalKind.errorContextDrop,
      );
    case 0x1f:
      return const WasmComponentCanonicalDefinition(
        kind: WasmComponentCanonicalKind.waitableSetNew,
      );
    case 0x20:
      return _readCancellableMemoryCanonical(
        reader,
        WasmComponentCanonicalKind.waitableSetWait,
      );
    case 0x21:
      return _readCancellableMemoryCanonical(
        reader,
        WasmComponentCanonicalKind.waitableSetPoll,
      );
    case 0x22:
      return const WasmComponentCanonicalDefinition(
        kind: WasmComponentCanonicalKind.waitableSetDrop,
      );
    case 0x23:
      return const WasmComponentCanonicalDefinition(
        kind: WasmComponentCanonicalKind.waitableJoin,
      );
    case 0x26:
      return const WasmComponentCanonicalDefinition(
        kind: WasmComponentCanonicalKind.threadIndex,
      );
    case 0x27:
      return WasmComponentCanonicalDefinition(
        kind: WasmComponentCanonicalKind.threadNewIndirect,
        typeIndex: reader.readVarUint32(),
        tableIndex: reader.readVarUint32(),
      );
    case 0x28:
      return _readCancellableCanonical(
        reader,
        WasmComponentCanonicalKind.threadSwitchTo,
      );
    case 0x29:
      return _readCancellableCanonical(
        reader,
        WasmComponentCanonicalKind.threadSuspend,
      );
    case 0x2a:
      return const WasmComponentCanonicalDefinition(
        kind: WasmComponentCanonicalKind.threadResumeLater,
      );
    case 0x2b:
      return _readCancellableCanonical(
        reader,
        WasmComponentCanonicalKind.threadYieldTo,
      );
    case 0x40:
      return WasmComponentCanonicalDefinition(
        kind: WasmComponentCanonicalKind.threadSpawnRef,
        isShared: _readCanonicalFlag(reader, 'shared'),
        typeIndex: reader.readVarUint32(),
      );
    case 0x41:
      return WasmComponentCanonicalDefinition(
        kind: WasmComponentCanonicalKind.threadSpawnIndirect,
        isShared: _readCanonicalFlag(reader, 'shared'),
        typeIndex: reader.readVarUint32(),
        tableIndex: reader.readVarUint32(),
      );
    case 0x42:
      return WasmComponentCanonicalDefinition(
        kind: WasmComponentCanonicalKind.threadAvailableParallelism,
        isShared: _readCanonicalFlag(reader, 'shared'),
      );
    default:
      throw FormatException(
        'Unsupported Wasm component canonical definition: 0x${opcode.toRadixString(16)}.',
      );
  }
}

WasmComponentCanonicalDefinition _readCanonicalTypeIndex(
  ByteReader reader,
  WasmComponentCanonicalKind kind,
) {
  return WasmComponentCanonicalDefinition(
    kind: kind,
    typeIndex: reader.readVarUint32(),
  );
}

WasmComponentCanonicalDefinition _readTypedOptionsCanonical(
  ByteReader reader,
  WasmComponentCanonicalKind kind,
) {
  return WasmComponentCanonicalDefinition(
    kind: kind,
    typeIndex: reader.readVarUint32(),
    options: _readCanonicalOptions(reader),
  );
}

WasmComponentCanonicalDefinition _readTypedAsyncCanonical(
  ByteReader reader,
  WasmComponentCanonicalKind kind,
) {
  return WasmComponentCanonicalDefinition(
    kind: kind,
    typeIndex: reader.readVarUint32(),
    isAsync: _readCanonicalFlag(reader, 'async'),
  );
}

WasmComponentCanonicalDefinition _readContextCanonical(
  ByteReader reader,
  WasmComponentCanonicalKind kind,
) {
  final valueType = reader.readByte();
  if (valueType != 0x7f) {
    throw FormatException(
      'Unsupported Wasm component canonical context value type: 0x${valueType.toRadixString(16)}.',
    );
  }
  return WasmComponentCanonicalDefinition(
    kind: kind,
    contextIndex: reader.readVarUint32(),
  );
}

WasmComponentCanonicalDefinition _readAsyncCanonical(
  ByteReader reader,
  WasmComponentCanonicalKind kind,
) {
  return WasmComponentCanonicalDefinition(
    kind: kind,
    isAsync: _readCanonicalFlag(reader, 'async'),
  );
}

WasmComponentCanonicalDefinition _readCancellableCanonical(
  ByteReader reader,
  WasmComponentCanonicalKind kind,
) {
  return WasmComponentCanonicalDefinition(
    kind: kind,
    isCancellable: _readCanonicalFlag(reader, 'cancel'),
  );
}

WasmComponentCanonicalDefinition _readCancellableMemoryCanonical(
  ByteReader reader,
  WasmComponentCanonicalKind kind,
) {
  return WasmComponentCanonicalDefinition(
    kind: kind,
    isCancellable: _readCanonicalFlag(reader, 'cancel'),
    memoryIndex: reader.readVarUint32(),
  );
}

void _expectCanonicalFunctionSort(ByteReader reader) {
  final sort = reader.readByte();
  if (sort != 0x00) {
    throw FormatException(
      'Unsupported Wasm component canonical function sort: 0x${sort.toRadixString(16)}.',
    );
  }
}

List<WasmComponentCanonicalOption> _readCanonicalOptions(ByteReader reader) {
  final count = reader.readVarUint32();
  final options = <WasmComponentCanonicalOption>[];
  for (var i = 0; i < count; i++) {
    options.add(_readCanonicalOption(reader));
  }
  return List.unmodifiable(options);
}

WasmComponentCanonicalOption _readCanonicalOption(ByteReader reader) {
  final kind = reader.readByte();
  switch (kind) {
    case 0x00:
      return const WasmComponentCanonicalOption(
        kind: WasmComponentCanonicalOptionKind.stringEncodingUtf8,
      );
    case 0x01:
      return const WasmComponentCanonicalOption(
        kind: WasmComponentCanonicalOptionKind.stringEncodingUtf16,
      );
    case 0x02:
      return const WasmComponentCanonicalOption(
        kind: WasmComponentCanonicalOptionKind.stringEncodingLatin1Utf16,
      );
    case 0x03:
      return WasmComponentCanonicalOption(
        kind: WasmComponentCanonicalOptionKind.memory,
        index: reader.readVarUint32(),
      );
    case 0x04:
      return WasmComponentCanonicalOption(
        kind: WasmComponentCanonicalOptionKind.realloc,
        index: reader.readVarUint32(),
      );
    case 0x05:
      return WasmComponentCanonicalOption(
        kind: WasmComponentCanonicalOptionKind.postReturn,
        index: reader.readVarUint32(),
      );
    case 0x06:
      return const WasmComponentCanonicalOption(
        kind: WasmComponentCanonicalOptionKind.async,
      );
    case 0x07:
      return WasmComponentCanonicalOption(
        kind: WasmComponentCanonicalOptionKind.callback,
        index: reader.readVarUint32(),
      );
    default:
      throw FormatException(
        'Unsupported Wasm component canonical option: 0x${kind.toRadixString(16)}.',
      );
  }
}

WasmComponentCanonicalResult _readCanonicalResult(ByteReader reader) {
  final tag = reader.readByte();
  switch (tag) {
    case 0x00:
      return WasmComponentCanonicalResult.value(
        _readComponentValueType(reader),
      );
    case 0x01:
      final empty = reader.readByte();
      if (empty != 0x00) {
        throw FormatException(
          'Unsupported Wasm component empty result list payload: 0x${empty.toRadixString(16)}.',
        );
      }
      return const WasmComponentCanonicalResult.none();
    default:
      throw FormatException(
        'Unsupported Wasm component result list tag: 0x${tag.toRadixString(16)}.',
      );
  }
}

WasmComponentValueType _readComponentValueType(ByteReader reader) {
  final offset = reader.offset;
  final lead = reader.readByte();
  final primitive = _primitiveValueTypeForByte(lead);
  if (primitive != null) {
    return WasmComponentValueType.primitive(primitive);
  }
  reader.offset = offset;
  return WasmComponentValueType.typeIndex(reader.readVarUint32());
}

WasmComponentPrimitiveValueType? _primitiveValueTypeForByte(int byte) {
  return switch (byte) {
    0x7f => WasmComponentPrimitiveValueType.boolean,
    0x7e => WasmComponentPrimitiveValueType.s8,
    0x7d => WasmComponentPrimitiveValueType.u8,
    0x7c => WasmComponentPrimitiveValueType.s16,
    0x7b => WasmComponentPrimitiveValueType.u16,
    0x7a => WasmComponentPrimitiveValueType.s32,
    0x79 => WasmComponentPrimitiveValueType.u32,
    0x78 => WasmComponentPrimitiveValueType.s64,
    0x77 => WasmComponentPrimitiveValueType.u64,
    0x76 => WasmComponentPrimitiveValueType.f32,
    0x75 => WasmComponentPrimitiveValueType.f64,
    0x74 => WasmComponentPrimitiveValueType.char,
    0x73 => WasmComponentPrimitiveValueType.string,
    0x64 => WasmComponentPrimitiveValueType.errorContext,
    _ => null,
  };
}

bool _readCanonicalFlag(ByteReader reader, String context) {
  final flag = reader.readByte();
  switch (flag) {
    case 0x00:
      return false;
    case 0x01:
      return true;
    default:
      throw FormatException(
        'Unsupported Wasm component canonical $context flag: 0x${flag.toRadixString(16)}.',
      );
  }
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

WasmComponentCoreSortIndex _readCoreSortIndex(ByteReader reader) {
  return WasmComponentCoreSortIndex(
    kind: _readCoreSortKind(reader),
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
  final boundOffset = reader.offset;
  final bound = reader.readByte();
  switch (bound) {
    case 0x00:
      return WasmComponentExternDescriptor(
        kind: WasmComponentExternKind.value,
        boundKind: WasmComponentExternBoundKind.equality,
        valueIndex: reader.readVarUint32(),
      );
    case 0x01:
      final valueType = _readComponentValueType(reader);
      return WasmComponentExternDescriptor(
        kind: WasmComponentExternKind.value,
        boundKind: WasmComponentExternBoundKind.valueType,
        valueType: valueType,
        valueTypeCode: _valueTypeCode(valueType),
      );
    default:
      reader.offset = boundOffset;
      final valueType = _readComponentValueType(reader);
      return WasmComponentExternDescriptor(
        kind: WasmComponentExternKind.value,
        boundKind: WasmComponentExternBoundKind.valueType,
        valueType: valueType,
        valueTypeCode: _valueTypeCode(valueType),
      );
  }
}

int? _valueTypeCode(WasmComponentValueType valueType) {
  final primitive = valueType.primitive;
  if (primitive == null) {
    return valueType.typeIndex;
  }
  return switch (primitive) {
    WasmComponentPrimitiveValueType.boolean => 0x7f,
    WasmComponentPrimitiveValueType.s8 => 0x7e,
    WasmComponentPrimitiveValueType.u8 => 0x7d,
    WasmComponentPrimitiveValueType.s16 => 0x7c,
    WasmComponentPrimitiveValueType.u16 => 0x7b,
    WasmComponentPrimitiveValueType.s32 => 0x7a,
    WasmComponentPrimitiveValueType.u32 => 0x79,
    WasmComponentPrimitiveValueType.s64 => 0x78,
    WasmComponentPrimitiveValueType.u64 => 0x77,
    WasmComponentPrimitiveValueType.f32 => 0x76,
    WasmComponentPrimitiveValueType.f64 => 0x75,
    WasmComponentPrimitiveValueType.char => 0x74,
    WasmComponentPrimitiveValueType.string => 0x73,
    WasmComponentPrimitiveValueType.errorContext => 0x64,
  };
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
