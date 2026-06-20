// ignore_for_file: public_member_api_docs

import 'dart:convert';
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

enum WasmComponentTypeKind {
  definedValue,
  function,
  component,
  instance,
  resource,
}

final class WasmComponentTypeDefinition {
  const WasmComponentTypeDefinition({
    required this.kind,
    this.definedValue,
    this.function,
    this.component,
    this.instance,
    this.resource,
  });

  final WasmComponentTypeKind kind;
  final WasmComponentDefinedValueType? definedValue;
  final WasmComponentFunctionType? function;
  final WasmComponentComponentType? component;
  final WasmComponentInstanceType? instance;
  final WasmComponentResourceType? resource;
}

enum WasmComponentDefinedValueTypeKind {
  primitive,
  record,
  variant,
  list,
  fixedList,
  tuple,
  flags,
  enumeration,
  option,
  result,
  own,
  borrow,
  stream,
  future,
}

final class WasmComponentDefinedValueType {
  const WasmComponentDefinedValueType({
    required this.kind,
    this.primitive,
    this.fields = const <WasmComponentLabeledValueType>[],
    this.cases = const <WasmComponentVariantCase>[],
    this.elementType,
    this.fixedLength,
    this.types = const <WasmComponentValueType>[],
    this.labels = const <String>[],
    this.okType,
    this.errorType,
    this.typeIndex,
  });

  final WasmComponentDefinedValueTypeKind kind;
  final WasmComponentPrimitiveValueType? primitive;
  final List<WasmComponentLabeledValueType> fields;
  final List<WasmComponentVariantCase> cases;
  final WasmComponentValueType? elementType;
  final int? fixedLength;
  final List<WasmComponentValueType> types;
  final List<String> labels;
  final WasmComponentValueType? okType;
  final WasmComponentValueType? errorType;
  final int? typeIndex;
}

final class WasmComponentLabeledValueType {
  const WasmComponentLabeledValueType({
    required this.label,
    required this.type,
  });

  final String label;
  final WasmComponentValueType type;
}

final class WasmComponentVariantCase {
  const WasmComponentVariantCase({required this.label, this.type});

  final String label;
  final WasmComponentValueType? type;
}

final class WasmComponentFunctionType {
  const WasmComponentFunctionType({
    required this.params,
    this.result,
    this.isAsync = false,
  });

  final List<WasmComponentLabeledValueType> params;
  final WasmComponentValueType? result;
  final bool isAsync;
}

final class WasmComponentComponentType {
  const WasmComponentComponentType({required this.declarations});

  final List<WasmComponentTypeDeclaration> declarations;
}

final class WasmComponentInstanceType {
  const WasmComponentInstanceType({required this.declarations});

  final List<WasmComponentTypeDeclaration> declarations;
}

final class WasmComponentResourceType {
  const WasmComponentResourceType({
    required this.representationTypeCode,
    this.destructorFunctionIndex,
    this.callbackFunctionIndex,
    this.isAsync = false,
    this.isAbstract = false,
  });

  const WasmComponentResourceType.abstract()
    : representationTypeCode = null,
      destructorFunctionIndex = null,
      callbackFunctionIndex = null,
      isAsync = false,
      isAbstract = true;

  final int? representationTypeCode;
  final int? destructorFunctionIndex;
  final int? callbackFunctionIndex;
  final bool isAsync;
  final bool isAbstract;
}

enum WasmComponentTypeDeclarationKind { coreType, type, alias, import, export }

final class WasmComponentTypeDeclaration {
  const WasmComponentTypeDeclaration({
    required this.kind,
    this.coreType,
    this.type,
    this.alias,
    this.import,
    this.export,
  });

  final WasmComponentTypeDeclarationKind kind;
  final WasmComponentCoreType? coreType;
  final WasmComponentTypeDefinition? type;
  final WasmComponentAlias? alias;
  final WasmComponentImport? import;
  final WasmComponentTypeExport? export;
}

final class WasmComponentTypeExport {
  const WasmComponentTypeExport({
    required this.name,
    required this.descriptor,
    this.versionSuffix,
  });

  final String name;
  final String? versionSuffix;
  final WasmComponentExternDescriptor descriptor;
}

enum WasmComponentCoreTypeKind {
  function,
  struct,
  array,
  recursive,
  subtype,
  module,
}

final class WasmComponentCoreType {
  const WasmComponentCoreType({
    required this.kind,
    this.types = const <WasmComponentCoreType>[],
    this.declarations = const <WasmComponentCoreTypeDeclaration>[],
    this.superTypeIndices = const <int>[],
  });

  final WasmComponentCoreTypeKind kind;
  final List<WasmComponentCoreType> types;
  final List<WasmComponentCoreTypeDeclaration> declarations;
  final List<int> superTypeIndices;
}

enum WasmComponentCoreTypeDeclarationKind { import, type, alias, export }

final class WasmComponentCoreTypeDeclaration {
  const WasmComponentCoreTypeDeclaration({
    required this.kind,
    this.module,
    this.name,
    this.coreType,
    this.descriptor,
    this.alias,
  });

  final WasmComponentCoreTypeDeclarationKind kind;
  final String? module;
  final String? name;
  final WasmComponentCoreType? coreType;
  final WasmComponentCoreExternDescriptor? descriptor;
  final WasmComponentAlias? alias;
}

final class WasmComponentCoreExternDescriptor {
  const WasmComponentCoreExternDescriptor({
    required this.kind,
    this.typeIndex,
    this.limits,
    this.mutable,
  });

  final WasmComponentCoreSortKind kind;
  final int? typeIndex;
  final WasmLimits? limits;
  final bool? mutable;
}

enum WasmComponentValueDataKind {
  boolean,
  integer,
  floatingPoint,
  string,
  tuple,
  record,
  list,
  fixedList,
  variant,
  flags,
  enumeration,
  option,
  result,
  raw,
}

final class WasmComponentValueData {
  WasmComponentValueData({
    required this.kind,
    required this.rawBytes,
    this.boolean,
    this.integer,
    this.floatingPoint,
    this.string,
    this.items = const <WasmComponentValueData>[],
    this.index,
    this.label,
    this.labels = const <String>[],
    this.associatedValue,
    this.isSome,
    this.isOk,
  });

  final WasmComponentValueDataKind kind;
  final Uint8List rawBytes;
  final bool? boolean;
  final Object? integer;
  final double? floatingPoint;
  final String? string;
  final List<WasmComponentValueData> items;
  final int? index;
  final String? label;
  final List<String> labels;
  final WasmComponentValueData? associatedValue;
  final bool? isSome;
  final bool? isOk;
}

final class WasmComponentValueDefinition {
  const WasmComponentValueDefinition({
    required this.type,
    required this.payloadSize,
    required this.rawBytes,
    required this.value,
  });

  final WasmComponentValueType type;
  final int payloadSize;
  final Uint8List rawBytes;
  final WasmComponentValueData value;
}

final class WasmComponentValidationError {
  const WasmComponentValidationError({
    required this.path,
    required this.message,
  });

  final String path;
  final String message;
}

enum _WasmComponentDefinitionEventKind {
  import,
  export,
  coreType,
  coreModule,
  coreInstance,
  component,
  instance,
  typeCount,
  type,
  alias,
  canonical,
  start,
  value,
}

final class _WasmComponentDefinitionEvent {
  const _WasmComponentDefinitionEvent.import(this.index)
    : kind = _WasmComponentDefinitionEventKind.import;

  const _WasmComponentDefinitionEvent.export(this.index)
    : kind = _WasmComponentDefinitionEventKind.export;

  const _WasmComponentDefinitionEvent.coreType(this.index)
    : kind = _WasmComponentDefinitionEventKind.coreType;

  const _WasmComponentDefinitionEvent.coreModule(this.index)
    : kind = _WasmComponentDefinitionEventKind.coreModule;

  const _WasmComponentDefinitionEvent.coreInstance(this.index)
    : kind = _WasmComponentDefinitionEventKind.coreInstance;

  const _WasmComponentDefinitionEvent.component(this.index)
    : kind = _WasmComponentDefinitionEventKind.component;

  const _WasmComponentDefinitionEvent.instance(this.index)
    : kind = _WasmComponentDefinitionEventKind.instance;

  const _WasmComponentDefinitionEvent.typeCount(this.index)
    : kind = _WasmComponentDefinitionEventKind.typeCount;

  const _WasmComponentDefinitionEvent.type(this.index)
    : kind = _WasmComponentDefinitionEventKind.type;

  const _WasmComponentDefinitionEvent.alias(this.index)
    : kind = _WasmComponentDefinitionEventKind.alias;

  const _WasmComponentDefinitionEvent.canonical(this.index)
    : kind = _WasmComponentDefinitionEventKind.canonical;

  const _WasmComponentDefinitionEvent.start(this.index)
    : kind = _WasmComponentDefinitionEventKind.start;

  const _WasmComponentDefinitionEvent.value(this.index)
    : kind = _WasmComponentDefinitionEventKind.value;

  final _WasmComponentDefinitionEventKind kind;
  final int index;
}

final class _WasmComponentValueIndexEntry {
  _WasmComponentValueIndexEntry({
    required this.originPath,
    this.type,
    this.requiresConsumption = true,
  });

  final String originPath;
  final WasmComponentValueType? type;
  bool consumed = false;
  final bool requiresConsumption;
}

final class _WasmComponentCoreIndexCounts {
  var functions = 0;
  var tables = 0;
  var memories = 0;
  var globals = 0;
  var tags = 0;
  var types = 0;
  var modules = 0;
  var instances = 0;

  int count(WasmComponentCoreSortKind kind) {
    return switch (kind) {
      WasmComponentCoreSortKind.function => functions,
      WasmComponentCoreSortKind.table => tables,
      WasmComponentCoreSortKind.memory => memories,
      WasmComponentCoreSortKind.global => globals,
      WasmComponentCoreSortKind.tag => tags,
      WasmComponentCoreSortKind.type => types,
      WasmComponentCoreSortKind.module => modules,
      WasmComponentCoreSortKind.instance => instances,
    };
  }

  void add(WasmComponentCoreSortKind kind) {
    switch (kind) {
      case WasmComponentCoreSortKind.function:
        functions++;
      case WasmComponentCoreSortKind.table:
        tables++;
      case WasmComponentCoreSortKind.memory:
        memories++;
      case WasmComponentCoreSortKind.global:
        globals++;
      case WasmComponentCoreSortKind.tag:
        tags++;
      case WasmComponentCoreSortKind.type:
        types++;
      case WasmComponentCoreSortKind.module:
        modules++;
      case WasmComponentCoreSortKind.instance:
        instances++;
    }
  }
}

final class _WasmComponentOuterAliasScope {
  const _WasmComponentOuterAliasScope({
    required this.typeDefinitions,
    required this.coreModuleCount,
    required this.componentCount,
  });

  final List<WasmComponentTypeDefinition> typeDefinitions;
  final int coreModuleCount;
  final int componentCount;

  int? count(WasmComponentSort sort) {
    if (sort.kind == WasmComponentSortKind.componentType) {
      return typeDefinitions.length;
    }
    if (sort.kind == WasmComponentSortKind.component) {
      return componentCount;
    }
    if (sort.kind == WasmComponentSortKind.core &&
        sort.coreKind == WasmComponentCoreSortKind.module) {
      return coreModuleCount;
    }
    return null;
  }

  WasmComponentTypeDefinition? typeDefinitionAt(int? index) {
    if (index == null || index < 0 || index >= typeDefinitions.length) {
      return null;
    }
    return typeDefinitions[index];
  }
}

final class _WasmComponentTypeAliasScope {
  const _WasmComponentTypeAliasScope({
    required this.definitions,
    required this.crossesComponentBoundary,
    this.visibleCount,
  });

  final List<WasmComponentTypeDefinition> definitions;
  final bool crossesComponentBoundary;
  final int? visibleCount;

  int get length => visibleCount ?? definitions.length;

  WasmComponentTypeDefinition operator [](int index) => definitions[index];
}

bool _componentTypeDefinitionNeedsFunctionIndexValidation(
  WasmComponentTypeDefinition type,
) {
  final resource = type.resource;
  return type.kind == WasmComponentTypeKind.resource &&
      resource != null &&
      (resource.destructorFunctionIndex != null ||
          resource.callbackFunctionIndex != null);
}

final class WasmComponent {
  const WasmComponent._({
    required this.sections,
    required this.imports,
    required this.exports,
    required this.components,
    required this.coreModules,
    required this.coreTypes,
    required this.coreInstances,
    required this.instances,
    required this.aliases,
    required this.starts,
    required this.canonicalDefinitions,
    required this.typeDefinitions,
    required this.valueDefinitions,
    required List<_WasmComponentDefinitionEvent> definitionEvents,
  }) : _definitionEvents = definitionEvents;

  final List<WasmComponentSection> sections;
  final List<WasmComponentImport> imports;
  final List<WasmComponentExport> exports;
  final List<WasmComponent> components;
  final List<WasmModule> coreModules;
  final List<WasmComponentCoreType> coreTypes;
  final List<WasmComponentCoreInstance> coreInstances;
  final List<WasmComponentInstance> instances;
  final List<WasmComponentAlias> aliases;
  final List<WasmComponentStart> starts;
  final List<WasmComponentCanonicalDefinition> canonicalDefinitions;
  final List<WasmComponentTypeDefinition> typeDefinitions;
  final List<WasmComponentValueDefinition> valueDefinitions;
  final List<_WasmComponentDefinitionEvent> _definitionEvents;

  List<WasmComponentValidationError> validate() => _validate();

  List<WasmComponentValidationError> _validate({
    List<_WasmComponentOuterAliasScope> outerAliasScopes =
        const <_WasmComponentOuterAliasScope>[],
  }) {
    final errors = <WasmComponentValidationError>[];
    final context = _WasmComponentValidationContext(
      typeDefinitions: typeDefinitions,
      coreTypes: coreTypes,
      outerAliasScopes: outerAliasScopes,
      errors: errors,
    );
    for (var i = 0; i < coreTypes.length; i++) {
      context.validateCoreTypeDefinition(coreTypes[i], 'coreType[$i]');
    }
    for (var i = 0; i < typeDefinitions.length; i++) {
      context.validateComponentTypeDefinition(
        typeDefinitions[i],
        'type[$i]',
        outerTypeScopes: <_WasmComponentTypeAliasScope>[
          _WasmComponentTypeAliasScope(
            definitions: typeDefinitions,
            visibleCount: i,
            crossesComponentBoundary: true,
          ),
        ],
      );
    }
    context.validateDefinitionEvents(
      _definitionEvents,
      imports: imports,
      exports: exports,
      coreInstances: coreInstances,
      instances: instances,
      aliases: aliases,
      canonicalDefinitions: canonicalDefinitions,
      components: components,
      starts: starts,
      valueDefinitions: valueDefinitions,
    );
    return List.unmodifiable(errors);
  }

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
    final coreTypes = <WasmComponentCoreType>[];
    final coreInstances = <WasmComponentCoreInstance>[];
    final instances = <WasmComponentInstance>[];
    final aliases = <WasmComponentAlias>[];
    final starts = <WasmComponentStart>[];
    final canonicalDefinitions = <WasmComponentCanonicalDefinition>[];
    final typeDefinitions = <WasmComponentTypeDefinition>[];
    final valueDefinitions = <WasmComponentValueDefinition>[];
    final definitionEvents = <_WasmComponentDefinitionEvent>[];
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
          definitionEvents.add(
            _WasmComponentDefinitionEvent.coreModule(coreModules.length - 1),
          );
        case _coreInstanceSectionId:
          final decodedCoreInstances = _decodeCoreInstances(payload);
          for (final coreInstance in decodedCoreInstances) {
            coreInstances.add(coreInstance);
            definitionEvents.add(
              _WasmComponentDefinitionEvent.coreInstance(
                coreInstances.length - 1,
              ),
            );
          }
        case _coreTypeSectionId:
          final decodedCoreTypes = _decodeCoreTypes(payload);
          for (final coreType in decodedCoreTypes) {
            coreTypes.add(coreType);
            definitionEvents.add(
              _WasmComponentDefinitionEvent.coreType(coreTypes.length - 1),
            );
          }
        case _componentSectionId:
          components.add(WasmComponent.decode(payload, features: features));
          definitionEvents.add(
            _WasmComponentDefinitionEvent.component(components.length - 1),
          );
        case _instanceSectionId:
          final decodedInstances = _decodeInstances(payload);
          for (final instance in decodedInstances) {
            instances.add(instance);
            definitionEvents.add(
              _WasmComponentDefinitionEvent.instance(instances.length - 1),
            );
          }
        case _aliasSectionId:
          final decodedAliases = _decodeAliases(payload);
          for (final alias in decodedAliases) {
            aliases.add(alias);
            definitionEvents.add(
              _WasmComponentDefinitionEvent.alias(aliases.length - 1),
            );
          }
        case _typeSectionId:
          final decodedTypeDefinitions = _decodeTypeDefinitions(payload);
          for (final typeDefinition in decodedTypeDefinitions) {
            typeDefinitions.add(typeDefinition);
            if (_componentTypeDefinitionNeedsFunctionIndexValidation(
              typeDefinition,
            )) {
              definitionEvents.add(
                _WasmComponentDefinitionEvent.type(typeDefinitions.length - 1),
              );
            }
          }
          if (decodedTypeDefinitions.isNotEmpty) {
            definitionEvents.add(
              _WasmComponentDefinitionEvent.typeCount(typeDefinitions.length),
            );
          }
        case _canonicalSectionId:
          final decodedCanonicalDefinitions = _decodeCanonicalDefinitions(
            payload,
          );
          for (final canonicalDefinition in decodedCanonicalDefinitions) {
            canonicalDefinitions.add(canonicalDefinition);
            definitionEvents.add(
              _WasmComponentDefinitionEvent.canonical(
                canonicalDefinitions.length - 1,
              ),
            );
          }
        case _startSectionId:
          starts.add(_decodeStart(payload));
          definitionEvents.add(
            _WasmComponentDefinitionEvent.start(starts.length - 1),
          );
        case _importSectionId:
          final decodedImports = _decodeImports(payload);
          for (final import in decodedImports) {
            imports.add(import);
            definitionEvents.add(
              _WasmComponentDefinitionEvent.import(imports.length - 1),
            );
          }
        case _exportSectionId:
          final decodedExports = _decodeExports(payload);
          for (final export in decodedExports) {
            exports.add(export);
            definitionEvents.add(
              _WasmComponentDefinitionEvent.export(exports.length - 1),
            );
          }
        case _valueSectionId:
          final decodedValueDefinitions = _decodeValueDefinitions(
            payload,
            typeDefinitions,
          );
          for (final valueDefinition in decodedValueDefinitions) {
            valueDefinitions.add(valueDefinition);
            definitionEvents.add(
              _WasmComponentDefinitionEvent.value(valueDefinitions.length - 1),
            );
          }
      }
    }

    return WasmComponent._(
      sections: List.unmodifiable(sections),
      imports: List.unmodifiable(imports),
      exports: List.unmodifiable(exports),
      components: List.unmodifiable(components),
      coreModules: List.unmodifiable(coreModules),
      coreTypes: List.unmodifiable(coreTypes),
      coreInstances: List.unmodifiable(coreInstances),
      instances: List.unmodifiable(instances),
      aliases: List.unmodifiable(aliases),
      starts: List.unmodifiable(starts),
      canonicalDefinitions: List.unmodifiable(canonicalDefinitions),
      typeDefinitions: List.unmodifiable(typeDefinitions),
      valueDefinitions: List.unmodifiable(valueDefinitions),
      definitionEvents: List.unmodifiable(definitionEvents),
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
const int _coreTypeSectionId = 3;
const int _instanceSectionId = 5;
const int _aliasSectionId = 6;
const int _typeSectionId = 7;
const int _canonicalSectionId = 8;
const int _startSectionId = 9;
const int _valueSectionId = 12;

final class _WasmComponentValidationContext {
  _WasmComponentValidationContext({
    required this.typeDefinitions,
    required this.coreTypes,
    required this.outerAliasScopes,
    required this.errors,
  });

  final List<WasmComponentTypeDefinition> typeDefinitions;
  final List<WasmComponentCoreType> coreTypes;
  final List<_WasmComponentOuterAliasScope> outerAliasScopes;
  final List<WasmComponentValidationError> errors;
  final Map<int, bool> _valueTypeContainsBorrowMemo = <int, bool>{};
  final Set<int> _valueTypeContainsBorrowVisiting = <int>{};

  void validateComponentTypeDefinition(
    WasmComponentTypeDefinition type,
    String path, {
    List<WasmComponentTypeDefinition>? scopedTypeDefinitions,
    List<_WasmComponentTypeAliasScope> outerTypeScopes =
        const <_WasmComponentTypeAliasScope>[],
  }) {
    final definedValue = type.definedValue;
    if (type.kind == WasmComponentTypeKind.definedValue &&
        definedValue != null) {
      validateDefinedValueType(
        definedValue,
        path,
        scopedTypeDefinitions: scopedTypeDefinitions,
      );
      return;
    }

    final function = type.function;
    if (type.kind == WasmComponentTypeKind.function && function != null) {
      for (var i = 0; i < function.params.length; i++) {
        validateComponentValueType(
          function.params[i].type,
          '$path.params[$i]',
          scopedTypeDefinitions: scopedTypeDefinitions,
        );
      }
      validateComponentValueType(
        function.result,
        '$path.result',
        scopedTypeDefinitions: scopedTypeDefinitions,
      );
      validateValueTypeDoesNotContainBorrow(
        function.result,
        '$path.result',
        'function result type',
        scopedTypeDefinitions: scopedTypeDefinitions,
      );
    }

    final component = type.component;
    if (type.kind == WasmComponentTypeKind.component && component != null) {
      validateComponentTypeDeclarations(
        component.declarations,
        path,
        outerTypeScopes: outerTypeScopes,
      );
    }

    final instance = type.instance;
    if (type.kind == WasmComponentTypeKind.instance && instance != null) {
      validateComponentTypeDeclarations(
        instance.declarations,
        path,
        outerTypeScopes: outerTypeScopes,
      );
    }
  }

  void validateCoreTypeDefinition(WasmComponentCoreType type, String path) {
    if (type.kind == WasmComponentCoreTypeKind.module) {
      validateCoreModuleTypeDeclarations(type.declarations, path);
      return;
    }

    for (var i = 0; i < type.types.length; i++) {
      validateCoreTypeDefinition(type.types[i], '$path.types[$i]');
    }
  }

  void validateCoreModuleTypeDeclarations(
    List<WasmComponentCoreTypeDeclaration> declarations,
    String path,
  ) {
    final localCoreTypeKinds = <WasmComponentCoreTypeKind>[];
    for (var i = 0; i < declarations.length; i++) {
      final declaration = declarations[i];
      switch (declaration.kind) {
        case WasmComponentCoreTypeDeclarationKind.type:
          final coreType = declaration.coreType;
          if (coreType == null) {
            break;
          }
          if (coreType.kind == WasmComponentCoreTypeKind.module) {
            errors.add(
              WasmComponentValidationError(
                path: '$path.declarations[$i]',
                message:
                    'Wasm component core module type declarations cannot define core module types.',
              ),
            );
            break;
          }
          validateCoreTypeDefinition(coreType, '$path.declarations[$i]');
          localCoreTypeKinds.add(coreType.kind);
        case WasmComponentCoreTypeDeclarationKind.import:
        case WasmComponentCoreTypeDeclarationKind.export:
          validateCoreTypeDeclarationExternDescriptor(
            declaration.descriptor,
            '$path.declarations[$i].descriptor',
            localCoreTypeKinds,
          );
        case WasmComponentCoreTypeDeclarationKind.alias:
          validateCoreModuleTypeDeclarationAlias(
            declaration.alias,
            '$path.declarations[$i]',
            localCoreTypeKinds,
          );
          break;
      }
    }
  }

  void validateCoreModuleTypeDeclarationAlias(
    WasmComponentAlias? alias,
    String path,
    List<WasmComponentCoreTypeKind> localCoreTypeKinds,
  ) {
    if (alias == null) {
      return;
    }

    if (alias.sort.kind != WasmComponentSortKind.core ||
        alias.sort.coreKind != WasmComponentCoreSortKind.type ||
        alias.target.kind != WasmComponentAliasTargetKind.outer ||
        alias.target.componentDepth != 0) {
      return;
    }

    final typeIndex = alias.target.index;
    if (typeIndex == null ||
        typeIndex < 0 ||
        typeIndex >= localCoreTypeKinds.length) {
      errors.add(
        WasmComponentValidationError(
          path: '$path.target',
          message: 'Unknown Wasm component core type index: $typeIndex.',
        ),
      );
      return;
    }

    localCoreTypeKinds.add(localCoreTypeKinds[typeIndex]);
  }

  void validateCoreTypeDeclarationExternDescriptor(
    WasmComponentCoreExternDescriptor? descriptor,
    String path,
    List<WasmComponentCoreTypeKind> localCoreTypeKinds,
  ) {
    if (descriptor?.kind != WasmComponentCoreSortKind.function) {
      return;
    }

    validateLocalCoreTypeIndex(
      descriptor!.typeIndex,
      path,
      localCoreTypeKinds,
      WasmComponentCoreTypeKind.function,
      indexDescription: 'core function type',
      targetDescription: 'a core function type',
    );
  }

  void validateLocalCoreTypeIndex(
    int? typeIndex,
    String path,
    List<WasmComponentCoreTypeKind> localCoreTypeKinds,
    WasmComponentCoreTypeKind expectedKind, {
    required String indexDescription,
    required String targetDescription,
  }) {
    if (typeIndex == null ||
        typeIndex < 0 ||
        typeIndex >= localCoreTypeKinds.length) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message:
              'Unknown Wasm component $indexDescription index: $typeIndex.',
        ),
      );
      return;
    }

    if (localCoreTypeKinds[typeIndex] != expectedKind) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message:
              'Wasm component $indexDescription index $typeIndex does not refer to $targetDescription.',
        ),
      );
    }
  }

  void validateDefinedValueType(
    WasmComponentDefinedValueType type,
    String path, {
    List<WasmComponentTypeDefinition>? scopedTypeDefinitions,
  }) {
    switch (type.kind) {
      case WasmComponentDefinedValueTypeKind.record:
        _validateUniqueLabels(
          type.fields.map((field) => field.label),
          '$path.fields',
          'record field',
          errors,
        );
        for (var i = 0; i < type.fields.length; i++) {
          validateComponentValueType(
            type.fields[i].type,
            '$path.fields[$i]',
            scopedTypeDefinitions: scopedTypeDefinitions,
          );
        }
      case WasmComponentDefinedValueTypeKind.variant:
        _validateUniqueLabels(
          type.cases.map((case_) => case_.label),
          '$path.cases',
          'variant case',
          errors,
        );
        for (var i = 0; i < type.cases.length; i++) {
          validateComponentValueType(
            type.cases[i].type,
            '$path.cases[$i]',
            scopedTypeDefinitions: scopedTypeDefinitions,
          );
        }
      case WasmComponentDefinedValueTypeKind.list:
        validateComponentValueType(
          type.elementType,
          '$path.element',
          scopedTypeDefinitions: scopedTypeDefinitions,
        );
      case WasmComponentDefinedValueTypeKind.fixedList:
        validateComponentValueType(
          type.elementType,
          '$path.element',
          scopedTypeDefinitions: scopedTypeDefinitions,
        );
      case WasmComponentDefinedValueTypeKind.tuple:
        for (var i = 0; i < type.types.length; i++) {
          validateComponentValueType(
            type.types[i],
            '$path.items[$i]',
            scopedTypeDefinitions: scopedTypeDefinitions,
          );
        }
      case WasmComponentDefinedValueTypeKind.flags:
        _validateUniqueLabels(type.labels, '$path.flags', 'flags', errors);
      case WasmComponentDefinedValueTypeKind.enumeration:
        _validateUniqueLabels(type.labels, '$path.enum', 'enum', errors);
      case WasmComponentDefinedValueTypeKind.option:
        validateComponentValueType(
          type.elementType,
          '$path.some',
          scopedTypeDefinitions: scopedTypeDefinitions,
        );
      case WasmComponentDefinedValueTypeKind.result:
        validateComponentValueType(
          type.okType,
          '$path.ok',
          scopedTypeDefinitions: scopedTypeDefinitions,
        );
        validateComponentValueType(
          type.errorType,
          '$path.error',
          scopedTypeDefinitions: scopedTypeDefinitions,
        );
      case WasmComponentDefinedValueTypeKind.stream:
        validateComponentValueType(
          type.elementType,
          '$path.stream',
          scopedTypeDefinitions: scopedTypeDefinitions,
        );
        validateStreamElementType(type.elementType, '$path.stream');
        validateValueTypeDoesNotContainBorrow(
          type.elementType,
          '$path.stream',
          'stream element type',
          scopedTypeDefinitions: scopedTypeDefinitions,
        );
      case WasmComponentDefinedValueTypeKind.future:
        validateComponentValueType(
          type.elementType,
          '$path.future',
          scopedTypeDefinitions: scopedTypeDefinitions,
        );
        validateValueTypeDoesNotContainBorrow(
          type.elementType,
          '$path.future',
          'future element type',
          scopedTypeDefinitions: scopedTypeDefinitions,
        );
      case WasmComponentDefinedValueTypeKind.primitive:
        break;
      case WasmComponentDefinedValueTypeKind.own:
      case WasmComponentDefinedValueTypeKind.borrow:
        validateComponentResourceTypeIndex(
          type.typeIndex,
          '$path.resource',
          scopedTypeDefinitions: scopedTypeDefinitions,
        );
    }
  }

  void validateComponentTypeDeclarations(
    List<WasmComponentTypeDeclaration> declarations,
    String path, {
    List<_WasmComponentTypeAliasScope> outerTypeScopes =
        const <_WasmComponentTypeAliasScope>[],
  }) {
    final localTypeDefinitions = <WasmComponentTypeDefinition>[];
    final localCoreTypeKinds = <WasmComponentCoreTypeKind>[];
    final typeScopes = <_WasmComponentTypeAliasScope>[
      _WasmComponentTypeAliasScope(
        definitions: localTypeDefinitions,
        crossesComponentBoundary: false,
      ),
      ...outerTypeScopes,
    ];
    for (var i = 0; i < declarations.length; i++) {
      final declaration = declarations[i];
      switch (declaration.kind) {
        case WasmComponentTypeDeclarationKind.type:
          final nestedType = declaration.type;
          if (nestedType == null) {
            break;
          }
          if (nestedType.kind == WasmComponentTypeKind.resource) {
            errors.add(
              WasmComponentValidationError(
                path: '$path.declarations[$i]',
                message:
                    'Wasm component component and instance types cannot define resource types.',
              ),
            );
            break;
          }
          validateComponentTypeDefinition(
            nestedType,
            '$path.declarations[$i]',
            scopedTypeDefinitions: localTypeDefinitions,
            outerTypeScopes: typeScopes,
          );
          localTypeDefinitions.add(nestedType);
        case WasmComponentTypeDeclarationKind.import:
          validateTypeDeclarationExternDescriptor(
            declaration.import?.descriptor,
            '$path.declarations[$i].import.descriptor',
            localTypeDefinitions,
            localCoreTypeKinds,
          );
        case WasmComponentTypeDeclarationKind.export:
          final descriptor = declaration.export?.descriptor;
          validateTypeDeclarationExternDescriptor(
            descriptor,
            '$path.declarations[$i].export.descriptor',
            localTypeDefinitions,
            localCoreTypeKinds,
          );
          introduceTypeDeclarationExport(descriptor, localTypeDefinitions);
        case WasmComponentTypeDeclarationKind.coreType:
          final coreType = declaration.coreType;
          if (coreType == null) {
            break;
          }
          validateCoreTypeDefinition(coreType, '$path.declarations[$i]');
          localCoreTypeKinds.add(coreType.kind);
        case WasmComponentTypeDeclarationKind.alias:
          final alias = declaration.alias;
          if (alias == null) {
            break;
          }
          validateTypeDeclarationAlias(
            alias,
            '$path.declarations[$i]',
            localTypeDefinitions,
            typeScopes,
          );
          break;
      }
    }
  }

  void validateTypeDeclarationAlias(
    WasmComponentAlias alias,
    String path,
    List<WasmComponentTypeDefinition> localTypeDefinitions,
    List<_WasmComponentTypeAliasScope> typeScopes,
  ) {
    if (alias.sort.kind != WasmComponentSortKind.componentType &&
        alias.sort.kind != WasmComponentSortKind.instance) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message:
              'Unsupported Wasm component type declaration alias sort: ${alias.sort.kind.name}.',
        ),
      );
      return;
    }

    if (alias.sort.kind != WasmComponentSortKind.componentType ||
        alias.target.kind != WasmComponentAliasTargetKind.outer) {
      return;
    }

    final componentDepth = alias.target.componentDepth;
    if (componentDepth == null ||
        componentDepth < 0 ||
        componentDepth >= typeScopes.length) {
      errors.add(
        WasmComponentValidationError(
          path: '$path.target',
          message: 'Unknown Wasm component type scope: $componentDepth.',
        ),
      );
      return;
    }

    final targetTypeScope = typeScopes[componentDepth];
    final typeIndex = alias.target.index;
    if (typeIndex == null ||
        typeIndex < 0 ||
        typeIndex >= targetTypeScope.length) {
      errors.add(
        WasmComponentValidationError(
          path: '$path.target',
          message: 'Unknown Wasm component type index: $typeIndex.',
        ),
      );
      return;
    }

    if (targetTypeScope.crossesComponentBoundary &&
        componentTypeAliasScopeDefinitionContainsResource(
          targetTypeScope,
          typeIndex,
        )) {
      errors.add(
        WasmComponentValidationError(
          path: '$path.target',
          message:
              'Wasm component type declaration aliases cannot alias '
              'resource-containing types across component boundaries.',
        ),
      );
      return;
    }

    localTypeDefinitions.add(targetTypeScope[typeIndex]);
  }

  bool componentTypeAliasScopeDefinitionContainsResource(
    _WasmComponentTypeAliasScope scope,
    int typeIndex, {
    Map<int, bool>? memo,
    Set<int>? visiting,
  }) {
    if (typeIndex < 0 || typeIndex >= scope.length) {
      return false;
    }

    final resolvedMemo = memo ?? <int, bool>{};
    final cached = resolvedMemo[typeIndex];
    if (cached != null) {
      return cached;
    }

    final resolvedVisiting = visiting ?? <int>{};
    if (!resolvedVisiting.add(typeIndex)) {
      return false;
    }

    final contains = componentTypeDefinitionContainsResource(
      scope[typeIndex],
      scope,
      resolvedMemo,
      resolvedVisiting,
    );
    resolvedVisiting.remove(typeIndex);
    resolvedMemo[typeIndex] = contains;
    return contains;
  }

  bool componentTypeDefinitionContainsResource(
    WasmComponentTypeDefinition definition,
    _WasmComponentTypeAliasScope scope,
    Map<int, bool> memo,
    Set<int> visiting,
  ) {
    switch (definition.kind) {
      case WasmComponentTypeKind.resource:
        return definition.resource != null;
      case WasmComponentTypeKind.definedValue:
        final definedValue = definition.definedValue;
        return definedValue != null &&
            componentDefinedValueTypeContainsResource(
              definedValue,
              scope,
              memo,
              visiting,
            );
      case WasmComponentTypeKind.function:
        final function = definition.function;
        return function != null &&
            (function.params.any(
                  (param) => componentValueTypeContainsResource(
                    param.type,
                    scope,
                    memo,
                    visiting,
                  ),
                ) ||
                componentValueTypeContainsResource(
                  function.result,
                  scope,
                  memo,
                  visiting,
                ));
      case WasmComponentTypeKind.component:
        final component = definition.component;
        return component != null &&
            componentTypeDeclarationsContainResource(
              component.declarations,
              <_WasmComponentTypeAliasScope>[scope],
            );
      case WasmComponentTypeKind.instance:
        final instance = definition.instance;
        return instance != null &&
            componentTypeDeclarationsContainResource(
              instance.declarations,
              <_WasmComponentTypeAliasScope>[scope],
            );
    }
  }

  bool componentDefinedValueTypeContainsResource(
    WasmComponentDefinedValueType definedValue,
    _WasmComponentTypeAliasScope scope,
    Map<int, bool> memo,
    Set<int> visiting,
  ) {
    switch (definedValue.kind) {
      case WasmComponentDefinedValueTypeKind.own:
      case WasmComponentDefinedValueTypeKind.borrow:
        return true;
      case WasmComponentDefinedValueTypeKind.record:
        return definedValue.fields.any(
          (field) => componentValueTypeContainsResource(
            field.type,
            scope,
            memo,
            visiting,
          ),
        );
      case WasmComponentDefinedValueTypeKind.variant:
        return definedValue.cases.any(
          (case_) => componentValueTypeContainsResource(
            case_.type,
            scope,
            memo,
            visiting,
          ),
        );
      case WasmComponentDefinedValueTypeKind.list:
      case WasmComponentDefinedValueTypeKind.fixedList:
      case WasmComponentDefinedValueTypeKind.option:
      case WasmComponentDefinedValueTypeKind.stream:
      case WasmComponentDefinedValueTypeKind.future:
        return componentValueTypeContainsResource(
          definedValue.elementType,
          scope,
          memo,
          visiting,
        );
      case WasmComponentDefinedValueTypeKind.tuple:
        return definedValue.types.any(
          (type) =>
              componentValueTypeContainsResource(type, scope, memo, visiting),
        );
      case WasmComponentDefinedValueTypeKind.result:
        return componentValueTypeContainsResource(
              definedValue.okType,
              scope,
              memo,
              visiting,
            ) ||
            componentValueTypeContainsResource(
              definedValue.errorType,
              scope,
              memo,
              visiting,
            );
      case WasmComponentDefinedValueTypeKind.primitive:
      case WasmComponentDefinedValueTypeKind.flags:
      case WasmComponentDefinedValueTypeKind.enumeration:
        return false;
    }
  }

  bool componentValueTypeContainsResource(
    WasmComponentValueType? valueType,
    _WasmComponentTypeAliasScope scope,
    Map<int, bool> memo,
    Set<int> visiting,
  ) {
    if (valueType == null ||
        valueType.kind == WasmComponentValueTypeKind.primitive) {
      return false;
    }

    final typeIndex = valueType.typeIndex;
    return typeIndex != null &&
        componentTypeAliasScopeDefinitionContainsResource(
          scope,
          typeIndex,
          memo: memo,
          visiting: visiting,
        );
  }

  bool componentTypeDeclarationsContainResource(
    List<WasmComponentTypeDeclaration> declarations,
    List<_WasmComponentTypeAliasScope> outerScopes,
  ) {
    final localTypeDefinitions = <WasmComponentTypeDefinition>[];
    final localScope = _WasmComponentTypeAliasScope(
      definitions: localTypeDefinitions,
      crossesComponentBoundary: false,
    );
    final scopes = <_WasmComponentTypeAliasScope>[localScope, ...outerScopes];

    for (final declaration in declarations) {
      final nestedType = declaration.type;
      if (declaration.kind == WasmComponentTypeDeclarationKind.type &&
          nestedType != null) {
        if (componentTypeDefinitionContainsResource(
          nestedType,
          localScope,
          <int, bool>{},
          <int>{},
        )) {
          return true;
        }
        localTypeDefinitions.add(nestedType);
        continue;
      }

      final alias = declaration.alias;
      if (declaration.kind == WasmComponentTypeDeclarationKind.alias &&
          alias != null &&
          alias.sort.kind == WasmComponentSortKind.componentType &&
          alias.target.kind == WasmComponentAliasTargetKind.outer) {
        final componentDepth = alias.target.componentDepth;
        final typeIndex = alias.target.index;
        if (componentDepth == null || typeIndex == null) {
          continue;
        }
        final targetScope = typeAliasScopeAt(scopes, componentDepth);
        if (targetScope == null || typeIndex >= targetScope.length) {
          continue;
        }
        if (componentTypeAliasScopeDefinitionContainsResource(
          targetScope,
          typeIndex,
        )) {
          return true;
        }
        localTypeDefinitions.add(targetScope[typeIndex]);
        continue;
      }

      final descriptor = switch (declaration.kind) {
        WasmComponentTypeDeclarationKind.import =>
          declaration.import?.descriptor,
        WasmComponentTypeDeclarationKind.export =>
          declaration.export?.descriptor,
        _ => null,
      };
      if (componentExternDescriptorContainsResource(descriptor, localScope)) {
        return true;
      }
      introduceTypeDeclarationExport(descriptor, localTypeDefinitions);
    }

    return false;
  }

  _WasmComponentTypeAliasScope? typeAliasScopeAt(
    List<_WasmComponentTypeAliasScope> scopes,
    int componentDepth,
  ) {
    if (componentDepth < 0 || componentDepth >= scopes.length) {
      return null;
    }
    return scopes[componentDepth];
  }

  bool componentExternDescriptorContainsResource(
    WasmComponentExternDescriptor? descriptor,
    _WasmComponentTypeAliasScope localScope,
  ) {
    if (descriptor == null) {
      return false;
    }
    if (descriptor.kind == WasmComponentExternKind.componentType &&
        descriptor.boundKind == WasmComponentExternBoundKind.subtypeResource) {
      return true;
    }

    if (descriptor.kind == WasmComponentExternKind.value) {
      return componentValueTypeContainsResource(
        descriptor.valueType,
        localScope,
        <int, bool>{},
        <int>{},
      );
    }

    final referencesComponentType =
        descriptor.kind == WasmComponentExternKind.function ||
        descriptor.kind == WasmComponentExternKind.component ||
        descriptor.kind == WasmComponentExternKind.instance ||
        (descriptor.kind == WasmComponentExternKind.componentType &&
            descriptor.boundKind == WasmComponentExternBoundKind.equality);
    if (!referencesComponentType) {
      return false;
    }
    final typeIndex = descriptor.typeIndex;
    if (typeIndex == null) {
      return false;
    }
    return componentTypeAliasScopeDefinitionContainsResource(
      localScope,
      typeIndex,
    );
  }

  void introduceTypeDeclarationExport(
    WasmComponentExternDescriptor? descriptor,
    List<WasmComponentTypeDefinition> localTypeDefinitions,
  ) {
    final expectedKind = switch (descriptor?.kind) {
      WasmComponentExternKind.function => WasmComponentTypeKind.function,
      WasmComponentExternKind.component => WasmComponentTypeKind.component,
      WasmComponentExternKind.instance => WasmComponentTypeKind.instance,
      _ => null,
    };
    if (expectedKind != null) {
      final typeIndex = descriptor!.typeIndex;
      if (typeIndex == null ||
          typeIndex < 0 ||
          typeIndex >= localTypeDefinitions.length) {
        return;
      }

      final typeDefinition = localTypeDefinitions[typeIndex];
      if (!componentTypeDefinitionMatches(typeDefinition, expectedKind)) {
        return;
      }

      localTypeDefinitions.add(typeDefinition);
      return;
    }

    if (descriptor?.kind != WasmComponentExternKind.componentType ||
        (descriptor?.boundKind != WasmComponentExternBoundKind.equality &&
            descriptor?.boundKind !=
                WasmComponentExternBoundKind.subtypeResource)) {
      return;
    }

    if (descriptor?.boundKind == WasmComponentExternBoundKind.subtypeResource) {
      localTypeDefinitions.add(
        const WasmComponentTypeDefinition(
          kind: WasmComponentTypeKind.resource,
          resource: WasmComponentResourceType.abstract(),
        ),
      );
      return;
    }

    final typeIndex = descriptor!.typeIndex;
    if (typeIndex == null ||
        typeIndex < 0 ||
        typeIndex >= localTypeDefinitions.length) {
      return;
    }

    final typeDefinition = localTypeDefinitions[typeIndex];
    localTypeDefinitions.add(typeDefinition);
  }

  void validateTypeDeclarationExternDescriptor(
    WasmComponentExternDescriptor? descriptor,
    String path,
    List<WasmComponentTypeDefinition> localTypeDefinitions,
    List<WasmComponentCoreTypeKind> localCoreTypeKinds,
  ) {
    if (descriptor == null) {
      return;
    }

    switch (descriptor.kind) {
      case WasmComponentExternKind.function:
        validateLocalComponentTypeIndex(
          descriptor.typeIndex,
          path,
          localTypeDefinitions,
          WasmComponentTypeKind.function,
          indexDescription: 'function type',
          targetDescription: 'a function type',
        );
      case WasmComponentExternKind.component:
        validateLocalComponentTypeIndex(
          descriptor.typeIndex,
          path,
          localTypeDefinitions,
          WasmComponentTypeKind.component,
          indexDescription: 'component type',
          targetDescription: 'a component type',
        );
      case WasmComponentExternKind.instance:
        validateLocalComponentTypeIndex(
          descriptor.typeIndex,
          path,
          localTypeDefinitions,
          WasmComponentTypeKind.instance,
          indexDescription: 'instance type',
          targetDescription: 'an instance type',
        );
      case WasmComponentExternKind.coreModule:
        validateLocalCoreTypeIndex(
          descriptor.typeIndex,
          path,
          localCoreTypeKinds,
          WasmComponentCoreTypeKind.module,
          indexDescription: 'core module type',
          targetDescription: 'a core module type',
        );
      case WasmComponentExternKind.value:
      case WasmComponentExternKind.componentType:
        if (descriptor.boundKind == WasmComponentExternBoundKind.equality) {
          validateAnyLocalComponentTypeIndex(
            descriptor.typeIndex,
            path,
            localTypeDefinitions,
          );
        }
        break;
    }
  }

  void validateAnyLocalComponentTypeIndex(
    int? typeIndex,
    String path,
    List<WasmComponentTypeDefinition> localTypeDefinitions,
  ) {
    if (typeIndex == null ||
        typeIndex < 0 ||
        typeIndex >= localTypeDefinitions.length) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message: 'Unknown Wasm component type index: $typeIndex.',
        ),
      );
    }
  }

  void validateLocalComponentTypeIndex(
    int? typeIndex,
    String path,
    List<WasmComponentTypeDefinition> localTypeDefinitions,
    WasmComponentTypeKind expectedKind, {
    required String indexDescription,
    required String targetDescription,
  }) {
    if (typeIndex == null ||
        typeIndex < 0 ||
        typeIndex >= localTypeDefinitions.length) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message:
              'Unknown Wasm component $indexDescription index: $typeIndex.',
        ),
      );
      return;
    }

    if (!componentTypeDefinitionMatches(
      localTypeDefinitions[typeIndex],
      expectedKind,
    )) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message:
              'Wasm component $indexDescription index $typeIndex does not refer to $targetDescription.',
        ),
      );
    }
  }

  void validateValueTypeDoesNotContainBorrow(
    WasmComponentValueType? valueType,
    String path,
    String description, {
    List<WasmComponentTypeDefinition>? scopedTypeDefinitions,
  }) {
    if (valueTypeContainsBorrow(
      valueType,
      scopedTypeDefinitions: scopedTypeDefinitions,
    )) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message: 'Wasm component $description cannot contain borrow.',
        ),
      );
    }
  }

  bool valueTypeContainsBorrow(
    WasmComponentValueType? valueType, {
    List<WasmComponentTypeDefinition>? scopedTypeDefinitions,
  }) {
    if (scopedTypeDefinitions != null) {
      return valueTypeContainsBorrowInDefinitions(
        valueType,
        scopedTypeDefinitions,
        <int, bool>{},
        <int>{},
      );
    }

    return valueTypeContainsBorrowInDefinitions(
      valueType,
      typeDefinitions,
      _valueTypeContainsBorrowMemo,
      _valueTypeContainsBorrowVisiting,
    );
  }

  bool valueTypeContainsBorrowInDefinitions(
    WasmComponentValueType? valueType,
    List<WasmComponentTypeDefinition> definitions,
    Map<int, bool> memo,
    Set<int> visiting,
  ) {
    if (valueType == null ||
        valueType.kind == WasmComponentValueTypeKind.primitive) {
      return false;
    }

    final typeIndex = valueType.typeIndex;
    if (typeIndex == null || typeIndex < 0 || typeIndex >= definitions.length) {
      return false;
    }

    final cached = memo[typeIndex];
    if (cached != null) {
      return cached;
    }
    if (!visiting.add(typeIndex)) {
      return false;
    }

    final definition = definitions[typeIndex];
    final definedValue = definition.definedValue;
    if (definition.kind != WasmComponentTypeKind.definedValue ||
        definedValue == null) {
      visiting.remove(typeIndex);
      memo[typeIndex] = false;
      return false;
    }

    final contains = switch (definedValue.kind) {
      WasmComponentDefinedValueTypeKind.borrow => true,
      WasmComponentDefinedValueTypeKind.record => definedValue.fields.any(
        (field) => valueTypeContainsBorrowInDefinitions(
          field.type,
          definitions,
          memo,
          visiting,
        ),
      ),
      WasmComponentDefinedValueTypeKind.variant => definedValue.cases.any(
        (case_) => valueTypeContainsBorrowInDefinitions(
          case_.type,
          definitions,
          memo,
          visiting,
        ),
      ),
      WasmComponentDefinedValueTypeKind.list ||
      WasmComponentDefinedValueTypeKind.fixedList ||
      WasmComponentDefinedValueTypeKind.option ||
      WasmComponentDefinedValueTypeKind.stream ||
      WasmComponentDefinedValueTypeKind.future =>
        valueTypeContainsBorrowInDefinitions(
          definedValue.elementType,
          definitions,
          memo,
          visiting,
        ),
      WasmComponentDefinedValueTypeKind.tuple => definedValue.types.any(
        (type) => valueTypeContainsBorrowInDefinitions(
          type,
          definitions,
          memo,
          visiting,
        ),
      ),
      WasmComponentDefinedValueTypeKind.result =>
        valueTypeContainsBorrowInDefinitions(
              definedValue.okType,
              definitions,
              memo,
              visiting,
            ) ||
            valueTypeContainsBorrowInDefinitions(
              definedValue.errorType,
              definitions,
              memo,
              visiting,
            ),
      WasmComponentDefinedValueTypeKind.primitive ||
      WasmComponentDefinedValueTypeKind.flags ||
      WasmComponentDefinedValueTypeKind.enumeration ||
      WasmComponentDefinedValueTypeKind.own => false,
    };

    visiting.remove(typeIndex);
    memo[typeIndex] = contains;
    return contains;
  }

  void validateComponentValueType(
    WasmComponentValueType? valueType,
    String path, {
    List<WasmComponentTypeDefinition>? scopedTypeDefinitions,
  }) {
    if (valueType == null ||
        valueType.kind == WasmComponentValueTypeKind.primitive) {
      return;
    }

    if (scopedTypeDefinitions == null) {
      validateComponentTypeIndex(
        valueType.typeIndex,
        path,
        WasmComponentTypeKind.definedValue,
        indexDescription: 'value type',
        targetDescription: 'a value type',
      );
      return;
    }

    validateComponentTypeIndexInDefinitions(
      valueType.typeIndex,
      path,
      scopedTypeDefinitions,
      WasmComponentTypeKind.definedValue,
      indexDescription: 'value type',
      targetDescription: 'a value type',
    );
  }

  void validateComponentResourceTypeIndex(
    int? typeIndex,
    String path, {
    List<WasmComponentTypeDefinition>? scopedTypeDefinitions,
  }) {
    if (scopedTypeDefinitions == null) {
      validateComponentTypeIndex(
        typeIndex,
        path,
        WasmComponentTypeKind.resource,
        indexDescription: 'resource type',
        targetDescription: 'a resource type',
      );
      return;
    }

    validateComponentTypeIndexInDefinitions(
      typeIndex,
      path,
      scopedTypeDefinitions,
      WasmComponentTypeKind.resource,
      indexDescription: 'resource type',
      targetDescription: 'a resource type',
    );
  }

  void validateStreamElementType(
    WasmComponentValueType? valueType,
    String path,
  ) {
    if (valueType?.primitive == WasmComponentPrimitiveValueType.char) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message: 'Wasm component stream element type cannot be char.',
        ),
      );
    }
  }

  void validateExternDescriptor(
    WasmComponentExternDescriptor? descriptor,
    String path, {
    List<WasmComponentTypeDefinition>? visibleTypeDefinitions,
  }) {
    if (descriptor == null) {
      return;
    }

    switch (descriptor.kind) {
      case WasmComponentExternKind.coreModule:
        validateCoreModuleTypeIndex(descriptor.typeIndex, '$path.type');
      case WasmComponentExternKind.function:
        validateComponentTypeIndexInMaybeDefinitions(
          descriptor.typeIndex,
          '$path.type',
          WasmComponentTypeKind.function,
          visibleTypeDefinitions,
          indexDescription: 'function type',
          targetDescription: 'a function type',
        );
      case WasmComponentExternKind.value:
        if (descriptor.boundKind == WasmComponentExternBoundKind.valueType) {
          validateComponentValueType(
            descriptor.valueType,
            '$path.valueType',
            scopedTypeDefinitions: visibleTypeDefinitions,
          );
        }
      case WasmComponentExternKind.componentType:
        if (descriptor.boundKind == WasmComponentExternBoundKind.equality) {
          validateAnyComponentTypeIndexInMaybeDefinitions(
            descriptor.typeIndex,
            '$path.type',
            visibleTypeDefinitions,
          );
        }
      case WasmComponentExternKind.component:
        validateComponentTypeIndexInMaybeDefinitions(
          descriptor.typeIndex,
          '$path.type',
          WasmComponentTypeKind.component,
          visibleTypeDefinitions,
          indexDescription: 'component type',
          targetDescription: 'a component type',
        );
      case WasmComponentExternKind.instance:
        validateComponentTypeIndexInMaybeDefinitions(
          descriptor.typeIndex,
          '$path.type',
          WasmComponentTypeKind.instance,
          visibleTypeDefinitions,
          indexDescription: 'instance type',
          targetDescription: 'an instance type',
        );
    }
  }

  void validateAnyComponentTypeIndexInMaybeDefinitions(
    int? typeIndex,
    String path,
    List<WasmComponentTypeDefinition>? definitions,
  ) {
    if (definitions == null) {
      validateAnyComponentTypeIndex(typeIndex, path);
      return;
    }

    if (typeIndex == null || typeIndex < 0 || typeIndex >= definitions.length) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message: 'Unknown Wasm component type index: $typeIndex.',
        ),
      );
    }
  }

  void validateComponentTypeIndexInMaybeDefinitions(
    int? typeIndex,
    String path,
    WasmComponentTypeKind expectedKind,
    List<WasmComponentTypeDefinition>? definitions, {
    required String indexDescription,
    required String targetDescription,
  }) {
    if (definitions == null) {
      validateComponentTypeIndex(
        typeIndex,
        path,
        expectedKind,
        indexDescription: indexDescription,
        targetDescription: targetDescription,
      );
      return;
    }

    validateComponentTypeIndexInDefinitions(
      typeIndex,
      path,
      definitions,
      expectedKind,
      indexDescription: indexDescription,
      targetDescription: targetDescription,
    );
  }

  void validateAnyComponentTypeIndex(int? typeIndex, String path) {
    if (typeIndex == null ||
        typeIndex < 0 ||
        typeIndex >= typeDefinitions.length) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message: 'Unknown Wasm component type index: $typeIndex.',
        ),
      );
    }
  }

  void validateComponentTypeIndex(
    int? typeIndex,
    String path,
    WasmComponentTypeKind expectedKind, {
    required String indexDescription,
    required String targetDescription,
  }) {
    if (typeIndex == null ||
        typeIndex < 0 ||
        typeIndex >= typeDefinitions.length) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message:
              'Unknown Wasm component $indexDescription index: $typeIndex.',
        ),
      );
      return;
    }

    if (!componentTypeDefinitionMatches(
      typeDefinitions[typeIndex],
      expectedKind,
    )) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message:
              'Wasm component $indexDescription index $typeIndex does not refer to $targetDescription.',
        ),
      );
    }
  }

  void validateComponentTypeIndexInDefinitions(
    int? typeIndex,
    String path,
    List<WasmComponentTypeDefinition> definitions,
    WasmComponentTypeKind expectedKind, {
    required String indexDescription,
    required String targetDescription,
  }) {
    if (typeIndex == null || typeIndex < 0 || typeIndex >= definitions.length) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message:
              'Unknown Wasm component $indexDescription index: $typeIndex.',
        ),
      );
      return;
    }

    if (!componentTypeDefinitionMatches(definitions[typeIndex], expectedKind)) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message:
              'Wasm component $indexDescription index $typeIndex does not refer to $targetDescription.',
        ),
      );
    }
  }

  void validateComponentTypeIndexInCount(
    int? typeIndex,
    String path,
    WasmComponentTypeKind expectedKind,
    int typeCount, {
    required String indexDescription,
    required String targetDescription,
  }) {
    if (typeIndex == null || typeIndex < 0 || typeIndex >= typeCount) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message:
              'Unknown Wasm component $indexDescription index: $typeIndex.',
        ),
      );
      return;
    }

    if (!componentTypeDefinitionMatches(
      typeDefinitions[typeIndex],
      expectedKind,
    )) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message:
              'Wasm component $indexDescription index $typeIndex does not refer to $targetDescription.',
        ),
      );
    }
  }

  void validateDefinedValueKindIndex(
    int? typeIndex,
    String path,
    WasmComponentDefinedValueTypeKind expectedKind,
    int typeCount, {
    required String indexDescription,
    required String targetDescription,
  }) {
    if (typeIndex == null || typeIndex < 0 || typeIndex >= typeCount) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message:
              'Unknown Wasm component $indexDescription index: $typeIndex.',
        ),
      );
      return;
    }

    final definition = typeDefinitions[typeIndex];
    if (definition.kind != WasmComponentTypeKind.definedValue ||
        definition.definedValue?.kind != expectedKind) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message:
              'Wasm component $indexDescription index $typeIndex does not refer to $targetDescription.',
        ),
      );
    }
  }

  void validateDefinedValueKindIndexInDefinitions(
    int? typeIndex,
    String path,
    WasmComponentDefinedValueTypeKind expectedKind,
    List<WasmComponentTypeDefinition> definitions, {
    required String indexDescription,
    required String targetDescription,
  }) {
    if (typeIndex == null || typeIndex < 0 || typeIndex >= definitions.length) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message:
              'Unknown Wasm component $indexDescription index: $typeIndex.',
        ),
      );
      return;
    }

    final definition = definitions[typeIndex];
    if (definition.kind != WasmComponentTypeKind.definedValue ||
        definition.definedValue?.kind != expectedKind) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message:
              'Wasm component $indexDescription index $typeIndex does not refer to $targetDescription.',
        ),
      );
    }
  }

  bool componentTypeDefinitionMatches(
    WasmComponentTypeDefinition definition,
    WasmComponentTypeKind expectedKind,
  ) {
    return switch (expectedKind) {
      WasmComponentTypeKind.definedValue =>
        definition.kind == WasmComponentTypeKind.definedValue &&
            definition.definedValue != null,
      WasmComponentTypeKind.function =>
        definition.kind == WasmComponentTypeKind.function &&
            definition.function != null,
      WasmComponentTypeKind.component =>
        definition.kind == WasmComponentTypeKind.component &&
            definition.component != null,
      WasmComponentTypeKind.instance =>
        definition.kind == WasmComponentTypeKind.instance &&
            definition.instance != null,
      WasmComponentTypeKind.resource =>
        definition.kind == WasmComponentTypeKind.resource &&
            definition.resource != null,
    };
  }

  void validateCoreModuleTypeIndex(int? typeIndex, String path) {
    if (typeIndex == null || typeIndex < 0 || typeIndex >= coreTypes.length) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message: 'Unknown Wasm component core module type index: $typeIndex.',
        ),
      );
      return;
    }

    if (coreTypes[typeIndex].kind != WasmComponentCoreTypeKind.module) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message:
              'Wasm component core module type index $typeIndex does not refer to a core module type.',
        ),
      );
    }
  }

  void validateCanonicalDefinition(
    WasmComponentCanonicalDefinition definition,
    String path, {
    List<WasmComponentTypeDefinition>? visibleTypeDefinitions,
  }) {
    if (definition.kind == WasmComponentCanonicalKind.lift) {
      validateComponentTypeIndexInMaybeDefinitions(
        definition.typeIndex,
        '$path.type',
        WasmComponentTypeKind.function,
        visibleTypeDefinitions,
        indexDescription: 'function type',
        targetDescription: 'a function type',
      );
    }

    if (canonicalDefinitionUsesResourceType(definition.kind)) {
      validateComponentResourceTypeIndex(
        definition.typeIndex,
        '$path.type',
        scopedTypeDefinitions: visibleTypeDefinitions,
      );
    }

    validateCanonicalOptions(definition.options, '$path.options');
    validateComponentValueType(
      definition.result?.valueType,
      '$path.result',
      scopedTypeDefinitions: visibleTypeDefinitions,
    );
  }

  void validateCanonicalOptions(
    List<WasmComponentCanonicalOption> options,
    String path,
  ) {
    final seenKinds = <WasmComponentCanonicalOptionKind>{};
    WasmComponentCanonicalOptionKind? stringEncoding;

    for (var i = 0; i < options.length; i++) {
      final optionKind = options[i].kind;
      if (canonicalOptionIsStringEncoding(optionKind)) {
        if (stringEncoding == null) {
          stringEncoding = optionKind;
          continue;
        }

        errors.add(
          WasmComponentValidationError(
            path: '$path[$i]',
            message: stringEncoding == optionKind
                ? 'Duplicate Wasm component canonical string encoding option: ${optionKind.name}.'
                : 'Conflicting Wasm component canonical string encoding option: ${stringEncoding.name} and ${optionKind.name}.',
          ),
        );
        continue;
      }

      if (!seenKinds.add(optionKind)) {
        errors.add(
          WasmComponentValidationError(
            path: '$path[$i]',
            message:
                'Duplicate Wasm component canonical option: ${optionKind.name}.',
          ),
        );
      }
    }
  }

  bool canonicalOptionIsStringEncoding(
    WasmComponentCanonicalOptionKind optionKind,
  ) {
    return optionKind == WasmComponentCanonicalOptionKind.stringEncodingUtf8 ||
        optionKind == WasmComponentCanonicalOptionKind.stringEncodingUtf16 ||
        optionKind ==
            WasmComponentCanonicalOptionKind.stringEncodingLatin1Utf16;
  }

  void validateDefinitionEvents(
    List<_WasmComponentDefinitionEvent> events, {
    required List<WasmComponentImport> imports,
    required List<WasmComponentExport> exports,
    required List<WasmComponentCoreInstance> coreInstances,
    required List<WasmComponentInstance> instances,
    required List<WasmComponentAlias> aliases,
    required List<WasmComponentCanonicalDefinition> canonicalDefinitions,
    required List<WasmComponent> components,
    required List<WasmComponentStart> starts,
    required List<WasmComponentValueDefinition> valueDefinitions,
  }) {
    final functionTypes = <WasmComponentFunctionType?>[];
    final valueEntries = <_WasmComponentValueIndexEntry>[];
    List<WasmComponentTypeDefinition>? materializedTypeDefinitions;
    var decodedTypeDefinitionCount = 0;
    List<WasmComponentTypeDefinition> visibleTypeDefinitionsForRead() {
      final materialized = materializedTypeDefinitions;
      if (materialized != null) {
        return materialized;
      }
      if (decodedTypeDefinitionCount == typeDefinitions.length) {
        return typeDefinitions;
      }
      return typeDefinitions.sublist(0, decodedTypeDefinitionCount);
    }

    List<WasmComponentTypeDefinition> materializeVisibleTypeDefinitions() {
      return materializedTypeDefinitions ??= typeDefinitions.sublist(
        0,
        decodedTypeDefinitionCount,
      );
    }

    final coreCounts = _WasmComponentCoreIndexCounts();
    var componentCount = 0;
    var instanceCount = 0;
    for (final event in events) {
      switch (event.kind) {
        case _WasmComponentDefinitionEventKind.import:
          final descriptor = imports[event.index].descriptor;
          final visibleTypeDefinitions = visibleTypeDefinitionsForRead();
          validateExternDescriptor(
            descriptor,
            'import[${event.index}].descriptor',
            visibleTypeDefinitions: visibleTypeDefinitions,
          );
          WasmComponentValueType? equalityValueType;
          if (descriptor.kind == WasmComponentExternKind.value &&
              descriptor.boundKind == WasmComponentExternBoundKind.equality) {
            validateComponentValueIndex(
              descriptor.valueIndex,
              'import[${event.index}].descriptor.value',
              valueEntries.length,
            );
            equalityValueType = componentValueTypeAt(
              valueEntries,
              descriptor.valueIndex,
            );
          }
          if (descriptor.kind == WasmComponentExternKind.function) {
            functionTypes.add(
              componentFunctionType(
                descriptor.typeIndex,
                definitions: visibleTypeDefinitions,
              ),
            );
          } else if (descriptor.kind == WasmComponentExternKind.value) {
            valueEntries.add(
              _WasmComponentValueIndexEntry(
                originPath: 'import[${event.index}]',
                type:
                    descriptor.boundKind ==
                        WasmComponentExternBoundKind.equality
                    ? equalityValueType
                    : descriptor.valueType,
              ),
            );
          } else if (descriptor.kind == WasmComponentExternKind.coreModule) {
            coreCounts.add(WasmComponentCoreSortKind.module);
          } else if (descriptor.kind == WasmComponentExternKind.component) {
            componentCount++;
          } else if (descriptor.kind == WasmComponentExternKind.instance) {
            instanceCount++;
          }
        case _WasmComponentDefinitionEventKind.export:
          final export = exports[event.index];
          final visibleTypeDefinitions = visibleTypeDefinitionsForRead();
          validateExternDescriptor(
            export.descriptor,
            'export[${event.index}].descriptor',
            visibleTypeDefinitions: visibleTypeDefinitions,
          );
          validateExportDefinition(
            export,
            'export[${event.index}]',
            functionTypes: functionTypes,
            valueEntries: valueEntries,
            coreCounts: coreCounts,
            visibleTypeDefinitions: visibleTypeDefinitions,
            componentCount: componentCount,
            instanceCount: instanceCount,
          );
          if (export.sort.kind == WasmComponentSortKind.component) {
            componentCount++;
          } else if (export.sort.kind == WasmComponentSortKind.instance) {
            instanceCount++;
          } else if (export.sort.kind == WasmComponentSortKind.core &&
              export.sort.coreKind != null) {
            coreCounts.add(export.sort.coreKind!);
          } else if (export.sort.kind == WasmComponentSortKind.componentType) {
            final exportedTypeDefinition = componentTypeDefinitionAt(
              visibleTypeDefinitions,
              export.sort.index,
            );
            if (exportedTypeDefinition != null) {
              materializeVisibleTypeDefinitions().add(exportedTypeDefinition);
            }
          }
        case _WasmComponentDefinitionEventKind.coreType:
          coreCounts.add(WasmComponentCoreSortKind.type);
        case _WasmComponentDefinitionEventKind.coreModule:
          coreCounts.add(WasmComponentCoreSortKind.module);
        case _WasmComponentDefinitionEventKind.coreInstance:
          validateCoreInstanceDefinition(
            coreInstances[event.index],
            'coreInstance[${event.index}]',
            coreCounts: coreCounts,
          );
          coreCounts.add(WasmComponentCoreSortKind.instance);
        case _WasmComponentDefinitionEventKind.component:
          final visibleTypeDefinitions = visibleTypeDefinitionsForRead();
          final childOuterAliasScopes = <_WasmComponentOuterAliasScope>[
            _WasmComponentOuterAliasScope(
              typeDefinitions: List<WasmComponentTypeDefinition>.unmodifiable(
                visibleTypeDefinitions,
              ),
              coreModuleCount: coreCounts.count(
                WasmComponentCoreSortKind.module,
              ),
              componentCount: componentCount,
            ),
            ...outerAliasScopes,
          ];
          for (final error in components[event.index]._validate(
            outerAliasScopes: childOuterAliasScopes,
          )) {
            errors.add(
              WasmComponentValidationError(
                path: 'component[${event.index}].${error.path}',
                message: error.message,
              ),
            );
          }
          componentCount++;
        case _WasmComponentDefinitionEventKind.instance:
          validateInstanceDefinition(
            instances[event.index],
            'instance[${event.index}]',
            functionTypes: functionTypes,
            valueEntries: valueEntries,
            componentCount: componentCount,
            instanceCount: instanceCount,
          );
          instanceCount++;
        case _WasmComponentDefinitionEventKind.typeCount:
          if (event.index > decodedTypeDefinitionCount) {
            materializedTypeDefinitions?.addAll(
              typeDefinitions.getRange(decodedTypeDefinitionCount, event.index),
            );
            decodedTypeDefinitionCount = event.index;
          }
        case _WasmComponentDefinitionEventKind.type:
          validateTypeDefinitionFunctionIndexes(
            typeDefinitions[event.index],
            'type[${event.index}]',
            functionTypes: functionTypes,
          );
        case _WasmComponentDefinitionEventKind.alias:
          final alias = aliases[event.index];
          final visibleTypeDefinitions = visibleTypeDefinitionsForRead();
          final currentOuterAliasScope = _WasmComponentOuterAliasScope(
            typeDefinitions: visibleTypeDefinitions,
            coreModuleCount: coreCounts.count(WasmComponentCoreSortKind.module),
            componentCount: componentCount,
          );
          final aliasIsValid = validateAliasDefinition(
            alias,
            'alias[${event.index}]',
            coreCounts: coreCounts,
            instanceCount: instanceCount,
            currentOuterAliasScope: currentOuterAliasScope,
          );
          if (!aliasIsValid) {
            break;
          }
          final sort = alias.sort;
          if (sort.kind == WasmComponentSortKind.core &&
              sort.coreKind != null) {
            coreCounts.add(sort.coreKind!);
          }
          if (sort.kind == WasmComponentSortKind.function) {
            functionTypes.add(null);
          } else if (sort.kind == WasmComponentSortKind.value) {
            valueEntries.add(
              _WasmComponentValueIndexEntry(
                originPath: 'alias[${event.index}]',
              ),
            );
          } else if (sort.kind == WasmComponentSortKind.component) {
            componentCount++;
          } else if (sort.kind == WasmComponentSortKind.instance) {
            instanceCount++;
          }
          final aliasedTypeDefinition = outerAliasTypeDefinition(
            alias,
            currentOuterAliasScope,
          );
          if (aliasedTypeDefinition != null) {
            materializeVisibleTypeDefinitions().add(aliasedTypeDefinition);
          }
        case _WasmComponentDefinitionEventKind.canonical:
          final definition = canonicalDefinitions[event.index];
          final visibleTypeDefinitions = visibleTypeDefinitionsForRead();
          validateCanonicalDefinition(
            definition,
            'canonical[${event.index}]',
            visibleTypeDefinitions: visibleTypeDefinitions,
          );
          if (definition.kind == WasmComponentCanonicalKind.lift) {
            validateCoreSortIndex(
              definition.coreFunctionIndex,
              'canonical[${event.index}].coreFunction',
              WasmComponentCoreSortKind.function,
              coreCounts,
            );
          }
          if (definition.kind == WasmComponentCanonicalKind.lower) {
            validateComponentFunctionIndex(
              definition.functionIndex,
              'canonical[${event.index}].function',
              functionTypes.length,
            );
          }
          validateCanonicalOptionIndexSpaces(
            definition.options,
            'canonical[${event.index}].options',
            coreCounts,
          );
          validateCanonicalDirectCoreIndexSpaces(
            definition,
            'canonical[${event.index}]',
            coreCounts,
          );
          validateCanonicalDirectTypeIndexSpaces(
            definition,
            'canonical[${event.index}]',
            visibleTypeDefinitions,
          );
          if (definition.kind == WasmComponentCanonicalKind.lower) {
            coreCounts.add(WasmComponentCoreSortKind.function);
          }
          if (definition.kind == WasmComponentCanonicalKind.lift) {
            functionTypes.add(
              componentFunctionType(
                definition.typeIndex,
                definitions: visibleTypeDefinitions,
              ),
            );
          }
        case _WasmComponentDefinitionEventKind.start:
          final start = starts[event.index];
          valueEntries.addAll(
            validateStartDefinition(
              start,
              'start[${event.index}]',
              functionTypes: functionTypes,
              valueEntries: valueEntries,
            ).map(
              (type) => _WasmComponentValueIndexEntry(
                originPath: 'start[${event.index}].result',
                type: type,
              ),
            ),
          );
        case _WasmComponentDefinitionEventKind.value:
          valueEntries.add(
            _WasmComponentValueIndexEntry(
              originPath: 'value[${event.index}]',
              type: valueDefinitions[event.index].type,
            ),
          );
      }
    }

    if (errors.isEmpty) {
      validateConsumedValues(valueEntries);
    }
  }

  void validateExportDefinition(
    WasmComponentExport export,
    String path, {
    required List<WasmComponentFunctionType?> functionTypes,
    required List<_WasmComponentValueIndexEntry> valueEntries,
    required _WasmComponentCoreIndexCounts coreCounts,
    required List<WasmComponentTypeDefinition> visibleTypeDefinitions,
    required int componentCount,
    required int instanceCount,
  }) {
    switch (export.sort.kind) {
      case WasmComponentSortKind.function:
        validateComponentFunctionIndex(
          export.sort.index,
          '$path.sort',
          functionTypes.length,
        );
        functionTypes.add(
          componentFunctionTypeAt(functionTypes, export.sort.index),
        );
      case WasmComponentSortKind.value:
        final valueType = consumeComponentValueIndex(
          export.sort.index,
          '$path.sort',
          valueEntries,
        );
        valueEntries.add(
          _WasmComponentValueIndexEntry(
            originPath: path,
            type: valueType,
            requiresConsumption: false,
          ),
        );
      case WasmComponentSortKind.core:
        final coreKind = export.sort.coreKind;
        if (coreKind != null) {
          validateCoreSortIndex(
            export.sort.index,
            '$path.sort',
            coreKind,
            coreCounts,
          );
        }
        break;
      case WasmComponentSortKind.componentType:
        validateAnyComponentTypeIndexInMaybeDefinitions(
          export.sort.index,
          '$path.sort',
          visibleTypeDefinitions,
        );
        break;
      case WasmComponentSortKind.component:
        validateComponentIndex(export.sort.index, '$path.sort', componentCount);
      case WasmComponentSortKind.instance:
        validateComponentInstanceIndex(
          export.sort.index,
          '$path.sort',
          instanceCount,
        );
    }
  }

  WasmComponentTypeDefinition? componentTypeDefinitionAt(
    List<WasmComponentTypeDefinition> definitions,
    int? typeIndex,
  ) {
    if (typeIndex == null || typeIndex < 0 || typeIndex >= definitions.length) {
      return null;
    }
    return definitions[typeIndex];
  }

  void validateInstanceDefinition(
    WasmComponentInstance instance,
    String path, {
    required List<WasmComponentFunctionType?> functionTypes,
    required List<_WasmComponentValueIndexEntry> valueEntries,
    required int componentCount,
    required int instanceCount,
  }) {
    switch (instance.kind) {
      case WasmComponentInstanceKind.instantiate:
        validateComponentIndex(
          instance.componentIndex,
          '$path.component',
          componentCount,
        );
        for (var i = 0; i < instance.arguments.length; i++) {
          validateComponentSortIndex(
            instance.arguments[i].sort,
            '$path.arguments[$i].sort',
            functionTypes: functionTypes,
            valueEntries: valueEntries,
            componentCount: componentCount,
            instanceCount: instanceCount,
          );
        }
      case WasmComponentInstanceKind.inlineExports:
        for (var i = 0; i < instance.exports.length; i++) {
          validateComponentSortIndex(
            instance.exports[i].sort,
            '$path.exports[$i].sort',
            functionTypes: functionTypes,
            valueEntries: valueEntries,
            componentCount: componentCount,
            instanceCount: instanceCount,
          );
        }
    }
  }

  void validateComponentSortIndex(
    WasmComponentSortIndex sort,
    String path, {
    required List<WasmComponentFunctionType?> functionTypes,
    required List<_WasmComponentValueIndexEntry> valueEntries,
    required int componentCount,
    required int instanceCount,
  }) {
    switch (sort.kind) {
      case WasmComponentSortKind.function:
        validateComponentFunctionIndex(sort.index, path, functionTypes.length);
      case WasmComponentSortKind.value:
        consumeComponentValueIndex(sort.index, path, valueEntries);
      case WasmComponentSortKind.component:
        validateComponentIndex(sort.index, path, componentCount);
      case WasmComponentSortKind.instance:
        validateComponentInstanceIndex(sort.index, path, instanceCount);
      case WasmComponentSortKind.core:
      case WasmComponentSortKind.componentType:
        break;
    }
  }

  void validateCoreInstanceDefinition(
    WasmComponentCoreInstance instance,
    String path, {
    required _WasmComponentCoreIndexCounts coreCounts,
  }) {
    switch (instance.kind) {
      case WasmComponentCoreInstanceKind.instantiate:
        validateCoreSortIndex(
          instance.moduleIndex,
          '$path.module',
          WasmComponentCoreSortKind.module,
          coreCounts,
        );
        for (var i = 0; i < instance.arguments.length; i++) {
          validateCoreSortIndex(
            instance.arguments[i].instanceIndex,
            '$path.arguments[$i].instance',
            WasmComponentCoreSortKind.instance,
            coreCounts,
          );
        }
      case WasmComponentCoreInstanceKind.inlineExports:
        for (var i = 0; i < instance.exports.length; i++) {
          final sort = instance.exports[i].sort;
          validateCoreSortIndex(
            sort.index,
            '$path.exports[$i].sort',
            sort.kind,
            coreCounts,
          );
        }
    }
  }

  bool validateAliasDefinition(
    WasmComponentAlias alias,
    String path, {
    required _WasmComponentCoreIndexCounts coreCounts,
    required int instanceCount,
    required _WasmComponentOuterAliasScope currentOuterAliasScope,
  }) {
    if (alias.target.kind == WasmComponentAliasTargetKind.export) {
      validateComponentInstanceIndex(
        alias.target.instanceIndex,
        '$path.target.instance',
        instanceCount,
      );
    }

    if (alias.sort.kind == WasmComponentSortKind.core &&
        alias.target.kind == WasmComponentAliasTargetKind.coreExport) {
      validateCoreSortIndex(
        alias.target.coreInstanceIndex,
        '$path.target.coreInstance',
        WasmComponentCoreSortKind.instance,
        coreCounts,
      );
    }

    if (alias.target.kind == WasmComponentAliasTargetKind.outer) {
      return validateOuterAliasDefinition(alias, path, currentOuterAliasScope);
    }

    return true;
  }

  bool validateOuterAliasDefinition(
    WasmComponentAlias alias,
    String path,
    _WasmComponentOuterAliasScope currentOuterAliasScope,
  ) {
    final currentSortCount = currentOuterAliasScope.count(alias.sort);
    if (currentSortCount == null) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message:
              'Unsupported Wasm component outer alias sort: '
              '${outerAliasSortDescription(alias.sort)}.',
        ),
      );
      return false;
    }

    final componentDepth = alias.target.componentDepth;
    if (componentDepth == null || componentDepth < 0) {
      errors.add(
        WasmComponentValidationError(
          path: '$path.target',
          message: 'Unknown Wasm component outer alias scope: $componentDepth.',
        ),
      );
      return false;
    }

    final targetScope = outerAliasScopeAt(
      componentDepth,
      currentOuterAliasScope,
    );
    if (targetScope == null) {
      errors.add(
        WasmComponentValidationError(
          path: '$path.target',
          message: 'Unknown Wasm component outer alias scope: $componentDepth.',
        ),
      );
      return false;
    }

    final targetSortCount = targetScope.count(alias.sort);
    final index = alias.target.index;
    if (targetSortCount == null ||
        index == null ||
        index < 0 ||
        index >= targetSortCount) {
      errors.add(
        WasmComponentValidationError(
          path: '$path.target',
          message:
              'Unknown Wasm component outer alias '
              '${outerAliasSortDescription(alias.sort)} index: $index.',
        ),
      );
      return false;
    }

    return true;
  }

  WasmComponentTypeDefinition? outerAliasTypeDefinition(
    WasmComponentAlias alias,
    _WasmComponentOuterAliasScope currentOuterAliasScope,
  ) {
    if (alias.sort.kind != WasmComponentSortKind.componentType ||
        alias.target.kind != WasmComponentAliasTargetKind.outer) {
      return null;
    }

    final componentDepth = alias.target.componentDepth;
    if (componentDepth == null) {
      return null;
    }

    final targetScope = outerAliasScopeAt(
      componentDepth,
      currentOuterAliasScope,
    );
    return targetScope?.typeDefinitionAt(alias.target.index);
  }

  _WasmComponentOuterAliasScope? outerAliasScopeAt(
    int componentDepth,
    _WasmComponentOuterAliasScope currentOuterAliasScope,
  ) {
    if (componentDepth == 0) {
      return currentOuterAliasScope;
    }

    final outerIndex = componentDepth - 1;
    if (outerIndex < 0 || outerIndex >= outerAliasScopes.length) {
      return null;
    }
    return outerAliasScopes[outerIndex];
  }

  String outerAliasSortDescription(WasmComponentSort sort) {
    if (sort.kind == WasmComponentSortKind.core) {
      final coreKind = sort.coreKind;
      return coreKind == null ? 'core' : 'core ${coreKind.name}';
    }
    if (sort.kind == WasmComponentSortKind.componentType) {
      return 'type';
    }
    return sort.kind.name;
  }

  void validateCoreSortIndex(
    int? index,
    String path,
    WasmComponentCoreSortKind kind,
    _WasmComponentCoreIndexCounts coreCounts,
  ) {
    if (index == null || index < 0 || index >= coreCounts.count(kind)) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message: 'Unknown Wasm component core ${kind.name} index: $index.',
        ),
      );
    }
  }

  void validateTypeDefinitionFunctionIndexes(
    WasmComponentTypeDefinition type,
    String path, {
    required List<WasmComponentFunctionType?> functionTypes,
  }) {
    final resource = type.resource;
    if (type.kind != WasmComponentTypeKind.resource || resource == null) {
      return;
    }

    final destructorFunctionIndex = resource.destructorFunctionIndex;
    if (destructorFunctionIndex != null) {
      validateComponentFunctionIndex(
        destructorFunctionIndex,
        '$path.resource.destructor',
        functionTypes.length,
      );
    }

    final callbackFunctionIndex = resource.callbackFunctionIndex;
    if (callbackFunctionIndex != null) {
      validateComponentFunctionIndex(
        callbackFunctionIndex,
        '$path.resource.callback',
        functionTypes.length,
      );
    }
  }

  void validateCanonicalOptionIndexSpaces(
    List<WasmComponentCanonicalOption> options,
    String path,
    _WasmComponentCoreIndexCounts coreCounts,
  ) {
    for (var i = 0; i < options.length; i++) {
      final option = options[i];
      switch (option.kind) {
        case WasmComponentCanonicalOptionKind.memory:
          validateCoreSortIndex(
            option.index,
            '$path[$i]',
            WasmComponentCoreSortKind.memory,
            coreCounts,
          );
        case WasmComponentCanonicalOptionKind.realloc:
        case WasmComponentCanonicalOptionKind.postReturn:
        case WasmComponentCanonicalOptionKind.callback:
          validateCoreSortIndex(
            option.index,
            '$path[$i]',
            WasmComponentCoreSortKind.function,
            coreCounts,
          );
        case WasmComponentCanonicalOptionKind.stringEncodingUtf8:
        case WasmComponentCanonicalOptionKind.stringEncodingUtf16:
        case WasmComponentCanonicalOptionKind.stringEncodingLatin1Utf16:
        case WasmComponentCanonicalOptionKind.async:
          break;
      }
    }
  }

  void validateCanonicalDirectCoreIndexSpaces(
    WasmComponentCanonicalDefinition definition,
    String path,
    _WasmComponentCoreIndexCounts coreCounts,
  ) {
    if (definition.memoryIndex != null) {
      validateCoreSortIndex(
        definition.memoryIndex,
        '$path.memory',
        WasmComponentCoreSortKind.memory,
        coreCounts,
      );
    }

    if (definition.tableIndex != null) {
      validateCoreSortIndex(
        definition.tableIndex,
        '$path.table',
        WasmComponentCoreSortKind.table,
        coreCounts,
      );
    }
  }

  void validateCanonicalDirectTypeIndexSpaces(
    WasmComponentCanonicalDefinition definition,
    String path,
    List<WasmComponentTypeDefinition> visibleTypeDefinitions,
  ) {
    if (canonicalDefinitionUsesStreamType(definition.kind)) {
      validateDefinedValueKindIndexInDefinitions(
        definition.typeIndex,
        '$path.type',
        WasmComponentDefinedValueTypeKind.stream,
        visibleTypeDefinitions,
        indexDescription: 'stream type',
        targetDescription: 'a stream type',
      );
      return;
    }

    if (canonicalDefinitionUsesFutureType(definition.kind)) {
      validateDefinedValueKindIndexInDefinitions(
        definition.typeIndex,
        '$path.type',
        WasmComponentDefinedValueTypeKind.future,
        visibleTypeDefinitions,
        indexDescription: 'future type',
        targetDescription: 'a future type',
      );
      return;
    }

    if (canonicalDefinitionUsesFunctionType(definition.kind)) {
      validateComponentTypeIndexInDefinitions(
        definition.typeIndex,
        '$path.type',
        visibleTypeDefinitions,
        WasmComponentTypeKind.function,
        indexDescription: 'function type',
        targetDescription: 'a function type',
      );
    }
  }

  Iterable<WasmComponentValueType?> validateStartDefinition(
    WasmComponentStart start,
    String path, {
    required List<WasmComponentFunctionType?> functionTypes,
    required List<_WasmComponentValueIndexEntry> valueEntries,
  }) {
    validateComponentFunctionIndex(
      start.functionIndex,
      '$path.function',
      functionTypes.length,
    );

    for (var i = 0; i < start.arguments.length; i++) {
      consumeComponentValueIndex(
        start.arguments[i],
        '$path.arguments[$i]',
        valueEntries,
      );
    }

    final functionType = componentFunctionTypeAt(
      functionTypes,
      start.functionIndex,
    );
    if (functionType == null) {
      return List<WasmComponentValueType?>.filled(start.resultCount, null);
    }

    if (start.arguments.length != functionType.params.length) {
      errors.add(
        WasmComponentValidationError(
          path: '$path.arguments',
          message:
              'Wasm component start argument count does not match function parameter count: expected ${functionType.params.length}, got ${start.arguments.length}.',
        ),
      );
    }

    final comparableArgumentCount =
        start.arguments.length < functionType.params.length
        ? start.arguments.length
        : functionType.params.length;
    for (var i = 0; i < comparableArgumentCount; i++) {
      final valueType = componentValueTypeAt(valueEntries, start.arguments[i]);
      final parameterType = functionType.params[i].type;
      if (valueType != null &&
          !componentValueTypesMatch(parameterType, valueType)) {
        errors.add(
          WasmComponentValidationError(
            path: '$path.arguments[$i]',
            message:
                'Wasm component start argument type does not match function parameter type.',
          ),
        );
      }
    }

    final expectedResultCount = functionType.result == null ? 0 : 1;
    if (start.resultCount != expectedResultCount) {
      errors.add(
        WasmComponentValidationError(
          path: '$path.result',
          message:
              'Wasm component start result count does not match function result count: expected $expectedResultCount, got ${start.resultCount}.',
        ),
      );
      return List<WasmComponentValueType?>.filled(start.resultCount, null);
    }

    final resultType = functionType.result;
    return resultType == null
        ? const <WasmComponentValueType?>[]
        : <WasmComponentValueType?>[resultType];
  }

  WasmComponentFunctionType? componentFunctionType(
    int? typeIndex, {
    List<WasmComponentTypeDefinition>? definitions,
  }) {
    final resolvedDefinitions = definitions ?? typeDefinitions;
    if (typeIndex == null ||
        typeIndex < 0 ||
        typeIndex >= resolvedDefinitions.length) {
      return null;
    }
    final definition = resolvedDefinitions[typeIndex];
    if (definition.kind != WasmComponentTypeKind.function) {
      return null;
    }
    return definition.function;
  }

  WasmComponentFunctionType? componentFunctionTypeAt(
    List<WasmComponentFunctionType?> functionTypes,
    int? functionIndex,
  ) {
    if (functionIndex == null ||
        functionIndex < 0 ||
        functionIndex >= functionTypes.length) {
      return null;
    }
    return functionTypes[functionIndex];
  }

  WasmComponentValueType? componentValueTypeAt(
    List<_WasmComponentValueIndexEntry> valueEntries,
    int? valueIndex,
  ) {
    if (valueIndex == null ||
        valueIndex < 0 ||
        valueIndex >= valueEntries.length) {
      return null;
    }
    return valueEntries[valueIndex].type;
  }

  WasmComponentValueType? consumeComponentValueIndex(
    int? valueIndex,
    String path,
    List<_WasmComponentValueIndexEntry> valueEntries,
  ) {
    validateComponentValueIndex(valueIndex, path, valueEntries.length);
    if (valueIndex == null ||
        valueIndex < 0 ||
        valueIndex >= valueEntries.length) {
      return null;
    }

    final entry = valueEntries[valueIndex];
    if (entry.consumed) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message:
              'Wasm component value index $valueIndex was already consumed.',
        ),
      );
    } else {
      entry.consumed = true;
    }
    return entry.type;
  }

  void validateConsumedValues(
    List<_WasmComponentValueIndexEntry> valueEntries,
  ) {
    for (var i = 0; i < valueEntries.length; i++) {
      final entry = valueEntries[i];
      if (entry.requiresConsumption && !entry.consumed) {
        errors.add(
          WasmComponentValidationError(
            path: entry.originPath,
            message: 'Wasm component value index $i was not consumed.',
          ),
        );
      }
    }
  }

  bool componentValueTypesMatch(
    WasmComponentValueType expected,
    WasmComponentValueType actual,
  ) {
    return expected.kind == actual.kind &&
        expected.primitive == actual.primitive &&
        expected.typeIndex == actual.typeIndex;
  }

  void validateComponentFunctionIndex(
    int? functionIndex,
    String path,
    int functionCount,
  ) {
    if (functionIndex == null ||
        functionIndex < 0 ||
        functionIndex >= functionCount) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message: 'Unknown Wasm component function index: $functionIndex.',
        ),
      );
    }
  }

  void validateComponentValueIndex(
    int? valueIndex,
    String path,
    int valueCount,
  ) {
    if (valueIndex == null || valueIndex < 0 || valueIndex >= valueCount) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message: 'Unknown Wasm component value index: $valueIndex.',
        ),
      );
    }
  }

  void validateComponentIndex(
    int? componentIndex,
    String path,
    int componentCount,
  ) {
    if (componentIndex == null ||
        componentIndex < 0 ||
        componentIndex >= componentCount) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message: 'Unknown Wasm component component index: $componentIndex.',
        ),
      );
    }
  }

  void validateComponentInstanceIndex(
    int? instanceIndex,
    String path,
    int instanceCount,
  ) {
    if (instanceIndex == null ||
        instanceIndex < 0 ||
        instanceIndex >= instanceCount) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message: 'Unknown Wasm component instance index: $instanceIndex.',
        ),
      );
    }
  }

  bool canonicalDefinitionUsesResourceType(WasmComponentCanonicalKind kind) {
    return kind == WasmComponentCanonicalKind.resourceNew ||
        kind == WasmComponentCanonicalKind.resourceDrop ||
        kind == WasmComponentCanonicalKind.resourceRep;
  }

  bool canonicalDefinitionUsesStreamType(WasmComponentCanonicalKind kind) {
    return kind == WasmComponentCanonicalKind.streamNew ||
        kind == WasmComponentCanonicalKind.streamRead ||
        kind == WasmComponentCanonicalKind.streamWrite ||
        kind == WasmComponentCanonicalKind.streamCancelRead ||
        kind == WasmComponentCanonicalKind.streamCancelWrite ||
        kind == WasmComponentCanonicalKind.streamDropReadable ||
        kind == WasmComponentCanonicalKind.streamDropWritable;
  }

  bool canonicalDefinitionUsesFutureType(WasmComponentCanonicalKind kind) {
    return kind == WasmComponentCanonicalKind.futureNew ||
        kind == WasmComponentCanonicalKind.futureRead ||
        kind == WasmComponentCanonicalKind.futureWrite ||
        kind == WasmComponentCanonicalKind.futureCancelRead ||
        kind == WasmComponentCanonicalKind.futureCancelWrite ||
        kind == WasmComponentCanonicalKind.futureDropReadable ||
        kind == WasmComponentCanonicalKind.futureDropWritable;
  }

  bool canonicalDefinitionUsesFunctionType(WasmComponentCanonicalKind kind) {
    return kind == WasmComponentCanonicalKind.threadNewIndirect ||
        kind == WasmComponentCanonicalKind.threadSpawnRef ||
        kind == WasmComponentCanonicalKind.threadSpawnIndirect;
  }
}

void _validateUniqueLabels(
  Iterable<String> labels,
  String path,
  String kind,
  List<WasmComponentValidationError> errors,
) {
  final seen = <String>{};
  for (final label in labels) {
    if (!seen.add(label)) {
      errors.add(
        WasmComponentValidationError(
          path: path,
          message: 'Duplicate Wasm component $kind label: "$label".',
        ),
      );
    }
  }
}

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

List<WasmComponentCoreType> _decodeCoreTypes(Uint8List payload) {
  final reader = ByteReader(payload);
  final count = reader.readVarUint32();
  final types = <WasmComponentCoreType>[];
  for (var i = 0; i < count; i++) {
    types.add(_readComponentCoreType(reader));
  }
  reader.expectEof();
  return types;
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

List<WasmComponentValueDefinition> _decodeValueDefinitions(
  Uint8List payload,
  List<WasmComponentTypeDefinition> typeDefinitions,
) {
  final reader = ByteReader(payload);
  final count = reader.readVarUint32();
  final values = <WasmComponentValueDefinition>[];
  for (var i = 0; i < count; i++) {
    values.add(_readValueDefinition(reader, typeDefinitions));
  }
  reader.expectEof();
  return values;
}

WasmComponentValueDefinition _readValueDefinition(
  ByteReader reader,
  List<WasmComponentTypeDefinition> typeDefinitions,
) {
  final type = _readComponentValueType(reader);
  final payloadSize = reader.readVarUint32();
  final rawBytes = reader.readBytes(payloadSize);
  return WasmComponentValueDefinition(
    type: type,
    payloadSize: payloadSize,
    rawBytes: rawBytes,
    value: _decodeComponentValueData(type, rawBytes, typeDefinitions),
  );
}

WasmComponentValueData _decodeComponentValueData(
  WasmComponentValueType type,
  Uint8List rawBytes,
  List<WasmComponentTypeDefinition> typeDefinitions,
) {
  final reader = ByteReader(rawBytes);
  final value = _readComponentValueData(
    reader,
    type,
    typeDefinitions,
    allowRemainderRaw: true,
  );
  reader.expectEof();
  return value;
}

WasmComponentValueData _readComponentValueData(
  ByteReader reader,
  WasmComponentValueType type,
  List<WasmComponentTypeDefinition> typeDefinitions, {
  required bool allowRemainderRaw,
}) {
  final primitive = type.primitive;
  if (primitive == null) {
    return _readDefinedComponentValueData(
      reader,
      _resolveDefinedComponentValueType(type, typeDefinitions),
      typeDefinitions,
      allowRemainderRaw: allowRemainderRaw,
    );
  }

  return _readPrimitiveComponentValueData(
    reader,
    primitive,
    allowRemainderRaw: allowRemainderRaw,
  );
}

WasmComponentDefinedValueType _resolveDefinedComponentValueType(
  WasmComponentValueType type,
  List<WasmComponentTypeDefinition> typeDefinitions,
) {
  final typeIndex = type.typeIndex;
  if (typeIndex == null ||
      typeIndex < 0 ||
      typeIndex >= typeDefinitions.length) {
    throw FormatException(
      'Unknown Wasm component value type index: $typeIndex.',
    );
  }
  final definition = typeDefinitions[typeIndex];
  final definedValue = definition.definedValue;
  if (definition.kind != WasmComponentTypeKind.definedValue ||
      definedValue == null) {
    throw FormatException(
      'Wasm component value type index $typeIndex does not refer to a value type.',
    );
  }
  return definedValue;
}

WasmComponentValueData _readPrimitiveComponentValueData(
  ByteReader reader,
  WasmComponentPrimitiveValueType primitive, {
  required bool allowRemainderRaw,
}) {
  final start = reader.offset;

  switch (primitive) {
    case WasmComponentPrimitiveValueType.boolean:
      final byte = reader.readByte();
      if (byte != 0x00 && byte != 0x01) {
        throw FormatException(
          'Invalid Wasm component bool value: 0x${byte.toRadixString(16)}.',
        );
      }
      return WasmComponentValueData(
        kind: WasmComponentValueDataKind.boolean,
        rawBytes: _componentValueRawBytes(reader, start),
        boolean: byte == 0x01,
      );
    case WasmComponentPrimitiveValueType.s8:
      final value = reader.readByte().toSigned(8);
      return _componentIntegerValue(
        _componentValueRawBytes(reader, start),
        value,
      );
    case WasmComponentPrimitiveValueType.u8:
      final value = reader.readByte();
      return _componentIntegerValue(
        _componentValueRawBytes(reader, start),
        value,
      );
    case WasmComponentPrimitiveValueType.s16:
      final rawBytes = reader.readBytes(2);
      return _componentIntegerValue(
        _componentValueRawBytes(reader, start),
        ByteData.sublistView(rawBytes).getInt16(0, Endian.little),
      );
    case WasmComponentPrimitiveValueType.u16:
      final rawBytes = reader.readBytes(2);
      return _componentIntegerValue(
        _componentValueRawBytes(reader, start),
        ByteData.sublistView(rawBytes).getUint16(0, Endian.little),
      );
    case WasmComponentPrimitiveValueType.s32:
      final rawBytes = reader.readBytes(4);
      return _componentIntegerValue(
        _componentValueRawBytes(reader, start),
        ByteData.sublistView(rawBytes).getInt32(0, Endian.little),
      );
    case WasmComponentPrimitiveValueType.u32:
      final rawBytes = reader.readBytes(4);
      return _componentIntegerValue(
        _componentValueRawBytes(reader, start),
        ByteData.sublistView(rawBytes).getUint32(0, Endian.little),
      );
    case WasmComponentPrimitiveValueType.s64:
      final rawBytes = reader.readBytes(8);
      return _componentIntegerValue(
        _componentValueRawBytes(reader, start),
        ByteData.sublistView(rawBytes).getInt64(0, Endian.little),
      );
    case WasmComponentPrimitiveValueType.u64:
      final rawBytes = reader.readBytes(8);
      return _componentIntegerValue(
        _componentValueRawBytes(reader, start),
        ByteData.sublistView(rawBytes).getUint64(0, Endian.little),
      );
    case WasmComponentPrimitiveValueType.f32:
      final rawBytes = reader.readBytes(4);
      return WasmComponentValueData(
        kind: WasmComponentValueDataKind.floatingPoint,
        rawBytes: _componentValueRawBytes(reader, start),
        floatingPoint: ByteData.sublistView(
          rawBytes,
        ).getFloat32(0, Endian.little),
      );
    case WasmComponentPrimitiveValueType.f64:
      final rawBytes = reader.readBytes(8);
      return WasmComponentValueData(
        kind: WasmComponentValueDataKind.floatingPoint,
        rawBytes: _componentValueRawBytes(reader, start),
        floatingPoint: ByteData.sublistView(
          rawBytes,
        ).getFloat64(0, Endian.little),
      );
    case WasmComponentPrimitiveValueType.char:
      final rawBytes = _readUtf8CodePointBytes(reader);
      final value = utf8.decode(rawBytes);
      if (value.runes.length != 1) {
        throw const FormatException(
          'Invalid Wasm component char value payload.',
        );
      }
      return WasmComponentValueData(
        kind: WasmComponentValueDataKind.string,
        rawBytes: _componentValueRawBytes(reader, start),
        string: value,
      );
    case WasmComponentPrimitiveValueType.string:
      final value = reader.readName();
      return WasmComponentValueData(
        kind: WasmComponentValueDataKind.string,
        rawBytes: _componentValueRawBytes(reader, start),
        string: value,
      );
    case WasmComponentPrimitiveValueType.errorContext:
      if (!allowRemainderRaw) {
        throw const FormatException(
          'Cannot decode nested Wasm component error-context value without an enclosing length.',
        );
      }
      reader.readRemainingBytes();
      return WasmComponentValueData(
        kind: WasmComponentValueDataKind.raw,
        rawBytes: _componentValueRawBytes(reader, start),
      );
  }
}

WasmComponentValueData _readDefinedComponentValueData(
  ByteReader reader,
  WasmComponentDefinedValueType type,
  List<WasmComponentTypeDefinition> typeDefinitions, {
  required bool allowRemainderRaw,
}) {
  final start = reader.offset;

  switch (type.kind) {
    case WasmComponentDefinedValueTypeKind.primitive:
      final primitive = type.primitive;
      if (primitive == null) {
        throw const FormatException(
          'Wasm component primitive value type is missing its primitive kind.',
        );
      }
      return _readPrimitiveComponentValueData(
        reader,
        primitive,
        allowRemainderRaw: allowRemainderRaw,
      );
    case WasmComponentDefinedValueTypeKind.tuple:
      return _readSequentialComponentValues(
        reader,
        start,
        type.types,
        typeDefinitions,
        WasmComponentValueDataKind.tuple,
      );
    case WasmComponentDefinedValueTypeKind.record:
      return _readSequentialComponentValues(
        reader,
        start,
        type.fields.map((field) => field.type).toList(growable: false),
        typeDefinitions,
        WasmComponentValueDataKind.record,
      );
    case WasmComponentDefinedValueTypeKind.list:
      final elementType = type.elementType;
      if (elementType == null) {
        throw const FormatException(
          'Wasm component list value type is missing its element type.',
        );
      }
      return _readListComponentValue(
        reader,
        start,
        elementType,
        typeDefinitions,
        WasmComponentValueDataKind.list,
      );
    case WasmComponentDefinedValueTypeKind.fixedList:
      final elementType = type.elementType;
      final fixedLength = type.fixedLength;
      if (elementType == null || fixedLength == null) {
        throw const FormatException(
          'Wasm component fixed-list value type is missing its shape.',
        );
      }
      final items = <WasmComponentValueData>[];
      for (var i = 0; i < fixedLength; i++) {
        items.add(
          _readComponentValueData(
            reader,
            elementType,
            typeDefinitions,
            allowRemainderRaw: false,
          ),
        );
      }
      return WasmComponentValueData(
        kind: WasmComponentValueDataKind.fixedList,
        rawBytes: _componentValueRawBytes(reader, start),
        items: List.unmodifiable(items),
      );
    case WasmComponentDefinedValueTypeKind.variant:
      final index = _readComponentCoreU32Value(reader);
      if (index >= type.cases.length) {
        throw FormatException(
          'Invalid Wasm component variant case index: $index.',
        );
      }
      final case_ = type.cases[index];
      final caseType = case_.type;
      final value = caseType == null
          ? null
          : _readComponentValueData(
              reader,
              caseType,
              typeDefinitions,
              allowRemainderRaw: false,
            );
      return WasmComponentValueData(
        kind: WasmComponentValueDataKind.variant,
        rawBytes: _componentValueRawBytes(reader, start),
        index: index,
        label: case_.label,
        associatedValue: value,
      );
    case WasmComponentDefinedValueTypeKind.flags:
      final bytes = reader.readBytes((type.labels.length + 7) ~/ 8);
      if (bytes.isNotEmpty) {
        final unusedBits = bytes.length * 8 - type.labels.length;
        if (unusedBits > 0) {
          final unusedMask = (0xff << (8 - unusedBits)) & 0xff;
          if ((bytes.last & unusedMask) != 0) {
            throw const FormatException(
              'Invalid Wasm component flags value: unused bits are set.',
            );
          }
        }
      }
      final labels = <String>[];
      for (var i = 0; i < type.labels.length; i++) {
        if ((bytes[i ~/ 8] & (1 << (i % 8))) != 0) {
          labels.add(type.labels[i]);
        }
      }
      return WasmComponentValueData(
        kind: WasmComponentValueDataKind.flags,
        rawBytes: _componentValueRawBytes(reader, start),
        labels: List.unmodifiable(labels),
      );
    case WasmComponentDefinedValueTypeKind.enumeration:
      final index = _readComponentCoreU32Value(reader);
      if (index >= type.labels.length) {
        throw FormatException(
          'Invalid Wasm component enum case index: $index.',
        );
      }
      return WasmComponentValueData(
        kind: WasmComponentValueDataKind.enumeration,
        rawBytes: _componentValueRawBytes(reader, start),
        index: index,
        label: type.labels[index],
      );
    case WasmComponentDefinedValueTypeKind.option:
      final tag = reader.readByte();
      switch (tag) {
        case 0x00:
          return WasmComponentValueData(
            kind: WasmComponentValueDataKind.option,
            rawBytes: _componentValueRawBytes(reader, start),
            isSome: false,
          );
        case 0x01:
          final elementType = type.elementType;
          if (elementType == null) {
            throw const FormatException(
              'Wasm component option value type is missing its element type.',
            );
          }
          final value = _readComponentValueData(
            reader,
            elementType,
            typeDefinitions,
            allowRemainderRaw: false,
          );
          return WasmComponentValueData(
            kind: WasmComponentValueDataKind.option,
            rawBytes: _componentValueRawBytes(reader, start),
            associatedValue: value,
            isSome: true,
          );
        default:
          throw FormatException(
            'Invalid Wasm component option value tag: 0x${tag.toRadixString(16)}.',
          );
      }
    case WasmComponentDefinedValueTypeKind.result:
      final tag = reader.readByte();
      switch (tag) {
        case 0x00:
        case 0x01:
          final isOk = tag == 0x00;
          final valueType = isOk ? type.okType : type.errorType;
          final value = valueType == null
              ? null
              : _readComponentValueData(
                  reader,
                  valueType,
                  typeDefinitions,
                  allowRemainderRaw: false,
                );
          return WasmComponentValueData(
            kind: WasmComponentValueDataKind.result,
            rawBytes: _componentValueRawBytes(reader, start),
            associatedValue: value,
            isOk: isOk,
          );
        default:
          throw FormatException(
            'Invalid Wasm component result value tag: 0x${tag.toRadixString(16)}.',
          );
      }
    case WasmComponentDefinedValueTypeKind.own:
    case WasmComponentDefinedValueTypeKind.borrow:
    case WasmComponentDefinedValueTypeKind.stream:
    case WasmComponentDefinedValueTypeKind.future:
      if (!allowRemainderRaw) {
        throw FormatException(
          'Cannot decode nested Wasm component ${type.kind.name} value without a supported payload shape.',
        );
      }
      reader.readRemainingBytes();
      return WasmComponentValueData(
        kind: WasmComponentValueDataKind.raw,
        rawBytes: _componentValueRawBytes(reader, start),
      );
  }
}

WasmComponentValueData _readSequentialComponentValues(
  ByteReader reader,
  int start,
  List<WasmComponentValueType> types,
  List<WasmComponentTypeDefinition> typeDefinitions,
  WasmComponentValueDataKind kind,
) {
  final items = <WasmComponentValueData>[];
  for (final type in types) {
    items.add(
      _readComponentValueData(
        reader,
        type,
        typeDefinitions,
        allowRemainderRaw: false,
      ),
    );
  }
  return WasmComponentValueData(
    kind: kind,
    rawBytes: _componentValueRawBytes(reader, start),
    items: List.unmodifiable(items),
  );
}

WasmComponentValueData _readListComponentValue(
  ByteReader reader,
  int start,
  WasmComponentValueType elementType,
  List<WasmComponentTypeDefinition> typeDefinitions,
  WasmComponentValueDataKind kind,
) {
  final count = reader.readVarUint32();
  final items = <WasmComponentValueData>[];
  for (var i = 0; i < count; i++) {
    items.add(
      _readComponentValueData(
        reader,
        elementType,
        typeDefinitions,
        allowRemainderRaw: false,
      ),
    );
  }
  return WasmComponentValueData(
    kind: kind,
    rawBytes: _componentValueRawBytes(reader, start),
    items: List.unmodifiable(items),
  );
}

Uint8List _componentValueRawBytes(ByteReader reader, int start) {
  return Uint8List.fromList(reader.bytes.sublist(start, reader.offset));
}

int _readComponentCoreU32Value(ByteReader reader) {
  final rawBytes = reader.readBytes(4);
  return ByteData.sublistView(rawBytes).getUint32(0, Endian.little);
}

Uint8List _readUtf8CodePointBytes(ByteReader reader) {
  final lead = reader.readByte();
  final length = switch (lead) {
    <= 0x7f => 1,
    >= 0xc2 && <= 0xdf => 2,
    >= 0xe0 && <= 0xef => 3,
    >= 0xf0 && <= 0xf4 => 4,
    _ => throw FormatException(
      'Invalid Wasm component char UTF-8 leading byte: 0x${lead.toRadixString(16)}.',
    ),
  };
  if (length == 1) {
    return Uint8List.fromList(<int>[lead]);
  }
  return Uint8List.fromList(<int>[lead, ...reader.readBytes(length - 1)]);
}

WasmComponentValueData _componentIntegerValue(
  Uint8List rawBytes,
  Object value,
) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.integer,
    rawBytes: rawBytes,
    integer: value,
  );
}

List<WasmComponentTypeDefinition> _decodeTypeDefinitions(Uint8List payload) {
  final reader = ByteReader(payload);
  final count = reader.readVarUint32();
  final types = <WasmComponentTypeDefinition>[];
  for (var i = 0; i < count; i++) {
    types.add(_readComponentTypeDefinition(reader));
  }
  reader.expectEof();
  return types;
}

WasmComponentTypeDefinition _readComponentTypeDefinition(ByteReader reader) {
  final lead = reader.readByte();
  switch (lead) {
    case 0x40:
      return WasmComponentTypeDefinition(
        kind: WasmComponentTypeKind.function,
        function: _readComponentFunctionType(reader),
      );
    case 0x43:
      return WasmComponentTypeDefinition(
        kind: WasmComponentTypeKind.function,
        function: _readComponentFunctionType(reader, isAsync: true),
      );
    case 0x41:
      return WasmComponentTypeDefinition(
        kind: WasmComponentTypeKind.component,
        component: _readComponentType(reader),
      );
    case 0x42:
      return WasmComponentTypeDefinition(
        kind: WasmComponentTypeKind.instance,
        instance: _readInstanceType(reader),
      );
    case 0x3f:
    case 0x3e:
      return WasmComponentTypeDefinition(
        kind: WasmComponentTypeKind.resource,
        resource: _readResourceType(reader, lead),
      );
    default:
      return WasmComponentTypeDefinition(
        kind: WasmComponentTypeKind.definedValue,
        definedValue: _readDefinedValueTypeWithLead(reader, lead),
      );
  }
}

WasmComponentDefinedValueType _readDefinedValueTypeWithLead(
  ByteReader reader,
  int lead,
) {
  final primitive = _primitiveValueTypeForByte(lead);
  if (primitive != null) {
    return WasmComponentDefinedValueType(
      kind: WasmComponentDefinedValueTypeKind.primitive,
      primitive: primitive,
    );
  }

  switch (lead) {
    case 0x72:
      final fieldCount = reader.readVarUint32();
      final fields = <WasmComponentLabeledValueType>[];
      for (var i = 0; i < fieldCount; i++) {
        fields.add(_readLabelValueType(reader));
      }
      return WasmComponentDefinedValueType(
        kind: WasmComponentDefinedValueTypeKind.record,
        fields: List.unmodifiable(fields),
      );
    case 0x71:
      final caseCount = reader.readVarUint32();
      final cases = <WasmComponentVariantCase>[];
      for (var i = 0; i < caseCount; i++) {
        cases.add(_readVariantCase(reader));
      }
      return WasmComponentDefinedValueType(
        kind: WasmComponentDefinedValueTypeKind.variant,
        cases: List.unmodifiable(cases),
      );
    case 0x70:
      return WasmComponentDefinedValueType(
        kind: WasmComponentDefinedValueTypeKind.list,
        elementType: _readComponentValueType(reader),
      );
    case 0x67:
      return WasmComponentDefinedValueType(
        kind: WasmComponentDefinedValueTypeKind.fixedList,
        elementType: _readComponentValueType(reader),
        fixedLength: reader.readVarUint32(),
      );
    case 0x6f:
      return WasmComponentDefinedValueType(
        kind: WasmComponentDefinedValueTypeKind.tuple,
        types: _readComponentValueTypeVector(reader),
      );
    case 0x6e:
      return WasmComponentDefinedValueType(
        kind: WasmComponentDefinedValueTypeKind.flags,
        labels: _readComponentLabels(reader),
      );
    case 0x6d:
      return WasmComponentDefinedValueType(
        kind: WasmComponentDefinedValueTypeKind.enumeration,
        labels: _readComponentLabels(reader),
      );
    case 0x6b:
      return WasmComponentDefinedValueType(
        kind: WasmComponentDefinedValueTypeKind.option,
        elementType: _readComponentValueType(reader),
      );
    case 0x6a:
      return WasmComponentDefinedValueType(
        kind: WasmComponentDefinedValueTypeKind.result,
        okType: _readOptionalComponentValueType(reader),
        errorType: _readOptionalComponentValueType(reader),
      );
    case 0x69:
      return WasmComponentDefinedValueType(
        kind: WasmComponentDefinedValueTypeKind.own,
        typeIndex: reader.readVarUint32(),
      );
    case 0x68:
      return WasmComponentDefinedValueType(
        kind: WasmComponentDefinedValueTypeKind.borrow,
        typeIndex: reader.readVarUint32(),
      );
    case 0x66:
      return WasmComponentDefinedValueType(
        kind: WasmComponentDefinedValueTypeKind.stream,
        elementType: _readOptionalComponentValueType(reader),
      );
    case 0x65:
      return WasmComponentDefinedValueType(
        kind: WasmComponentDefinedValueTypeKind.future,
        elementType: _readOptionalComponentValueType(reader),
      );
    default:
      throw FormatException(
        'Unsupported Wasm component defined value type: 0x${lead.toRadixString(16)}.',
      );
  }
}

WasmComponentLabeledValueType _readLabelValueType(ByteReader reader) {
  return WasmComponentLabeledValueType(
    label: reader.readName(),
    type: _readComponentValueType(reader),
  );
}

WasmComponentVariantCase _readVariantCase(ByteReader reader) {
  final label = reader.readName();
  final type = _readOptionalComponentValueType(reader);
  final reserved = reader.readByte();
  if (reserved != 0x00) {
    throw FormatException(
      'Unsupported Wasm component variant case reserved byte: 0x${reserved.toRadixString(16)}.',
    );
  }
  return WasmComponentVariantCase(label: label, type: type);
}

List<WasmComponentValueType> _readComponentValueTypeVector(ByteReader reader) {
  final count = reader.readVarUint32();
  final types = <WasmComponentValueType>[];
  for (var i = 0; i < count; i++) {
    types.add(_readComponentValueType(reader));
  }
  return List.unmodifiable(types);
}

List<String> _readComponentLabels(ByteReader reader) {
  final count = reader.readVarUint32();
  final labels = <String>[];
  for (var i = 0; i < count; i++) {
    labels.add(reader.readName());
  }
  return List.unmodifiable(labels);
}

WasmComponentValueType? _readOptionalComponentValueType(ByteReader reader) {
  final tag = reader.readByte();
  switch (tag) {
    case 0x00:
      return null;
    case 0x01:
      return _readComponentValueType(reader);
    default:
      throw FormatException(
        'Unsupported Wasm component optional value type tag: 0x${tag.toRadixString(16)}.',
      );
  }
}

WasmComponentResourceType _readResourceType(ByteReader reader, int lead) {
  final rep = reader.readByte();
  if (lead == 0x3f) {
    return WasmComponentResourceType(
      representationTypeCode: rep,
      destructorFunctionIndex: _readOptionalComponentIndex(reader),
    );
  }
  return WasmComponentResourceType(
    representationTypeCode: rep,
    isAsync: true,
    destructorFunctionIndex: reader.readVarUint32(),
    callbackFunctionIndex: _readOptionalComponentIndex(reader),
  );
}

int? _readOptionalComponentIndex(ByteReader reader) {
  final tag = reader.readByte();
  switch (tag) {
    case 0x00:
      return null;
    case 0x01:
      return reader.readVarUint32();
    default:
      throw FormatException(
        'Unsupported Wasm component optional index tag: 0x${tag.toRadixString(16)}.',
      );
  }
}

WasmComponentFunctionType _readComponentFunctionType(
  ByteReader reader, {
  bool isAsync = false,
}) {
  final paramCount = reader.readVarUint32();
  final params = <WasmComponentLabeledValueType>[];
  for (var i = 0; i < paramCount; i++) {
    params.add(_readLabelValueType(reader));
  }
  return WasmComponentFunctionType(
    params: List.unmodifiable(params),
    result: _readComponentFunctionResult(reader),
    isAsync: isAsync,
  );
}

WasmComponentValueType? _readComponentFunctionResult(ByteReader reader) {
  final tag = reader.readByte();
  switch (tag) {
    case 0x00:
      return _readComponentValueType(reader);
    case 0x01:
      final empty = reader.readByte();
      if (empty != 0x00) {
        throw FormatException(
          'Unsupported Wasm component function result payload: 0x${empty.toRadixString(16)}.',
        );
      }
      return null;
    default:
      throw FormatException(
        'Unsupported Wasm component function result tag: 0x${tag.toRadixString(16)}.',
      );
  }
}

WasmComponentComponentType _readComponentType(ByteReader reader) {
  final declarationCount = reader.readVarUint32();
  final declarations = <WasmComponentTypeDeclaration>[];
  for (var i = 0; i < declarationCount; i++) {
    declarations.add(_readComponentTypeDeclaration(reader));
  }
  return WasmComponentComponentType(
    declarations: List.unmodifiable(declarations),
  );
}

WasmComponentInstanceType _readInstanceType(ByteReader reader) {
  final declarationCount = reader.readVarUint32();
  final declarations = <WasmComponentTypeDeclaration>[];
  for (var i = 0; i < declarationCount; i++) {
    declarations.add(_readInstanceTypeDeclaration(reader));
  }
  return WasmComponentInstanceType(
    declarations: List.unmodifiable(declarations),
  );
}

WasmComponentTypeDeclaration _readComponentTypeDeclaration(ByteReader reader) {
  final kind = reader.readByte();
  if (kind == 0x03) {
    return WasmComponentTypeDeclaration(
      kind: WasmComponentTypeDeclarationKind.import,
      import: _readExternWithName(
        reader,
        'type import',
        (name, versionSuffix) => WasmComponentImport(
          name: name,
          versionSuffix: versionSuffix,
          descriptor: _readExternDescriptor(reader),
        ),
      ),
    );
  }
  return _readInstanceTypeDeclarationWithLead(reader, kind);
}

WasmComponentTypeDeclaration _readInstanceTypeDeclaration(ByteReader reader) {
  return _readInstanceTypeDeclarationWithLead(reader, reader.readByte());
}

WasmComponentTypeDeclaration _readInstanceTypeDeclarationWithLead(
  ByteReader reader,
  int kind,
) {
  switch (kind) {
    case 0x00:
      return WasmComponentTypeDeclaration(
        kind: WasmComponentTypeDeclarationKind.coreType,
        coreType: _readComponentCoreType(reader),
      );
    case 0x01:
      return WasmComponentTypeDeclaration(
        kind: WasmComponentTypeDeclarationKind.type,
        type: _readComponentTypeDefinition(reader),
      );
    case 0x02:
      return WasmComponentTypeDeclaration(
        kind: WasmComponentTypeDeclarationKind.alias,
        alias: _readAlias(reader),
      );
    case 0x04:
      return WasmComponentTypeDeclaration(
        kind: WasmComponentTypeDeclarationKind.export,
        export: _readComponentTypeExport(reader),
      );
    default:
      throw FormatException(
        'Unsupported Wasm component type declaration: 0x${kind.toRadixString(16)}.',
      );
  }
}

WasmComponentTypeExport _readComponentTypeExport(ByteReader reader) {
  return _readExternWithName(
    reader,
    'type export',
    (name, versionSuffix) => WasmComponentTypeExport(
      name: name,
      versionSuffix: versionSuffix,
      descriptor: _readExternDescriptor(reader),
    ),
  );
}

WasmComponentCoreType _readComponentCoreType(ByteReader reader) {
  final lead = reader.readByte();
  if (lead == 0x50) {
    return _readCoreModuleType(reader);
  }
  if (lead == 0x00) {
    final subtype = reader.readByte();
    if (subtype != 0x50) {
      throw FormatException(
        'Unsupported Wasm component prefixed core type: 0x${subtype.toRadixString(16)}.',
      );
    }
    return _readCoreSubtype(reader, subtype);
  }
  return _readCoreRecursiveType(reader, lead);
}

WasmComponentCoreType _readCoreModuleType(ByteReader reader) {
  final declarationCount = reader.readVarUint32();
  final declarations = <WasmComponentCoreTypeDeclaration>[];
  for (var i = 0; i < declarationCount; i++) {
    declarations.add(_readCoreModuleTypeDeclaration(reader));
  }
  return WasmComponentCoreType(
    kind: WasmComponentCoreTypeKind.module,
    declarations: List.unmodifiable(declarations),
  );
}

WasmComponentCoreTypeDeclaration _readCoreModuleTypeDeclaration(
  ByteReader reader,
) {
  final kind = reader.readByte();
  switch (kind) {
    case 0x00:
      final module = reader.readName();
      final name = reader.readName();
      return WasmComponentCoreTypeDeclaration(
        kind: WasmComponentCoreTypeDeclarationKind.import,
        module: module,
        name: name,
        descriptor: _readCoreExternDescriptor(reader),
      );
    case 0x01:
      return WasmComponentCoreTypeDeclaration(
        kind: WasmComponentCoreTypeDeclarationKind.type,
        coreType: _readComponentCoreType(reader),
      );
    case 0x02:
      return WasmComponentCoreTypeDeclaration(
        kind: WasmComponentCoreTypeDeclarationKind.alias,
        alias: _readCoreTypeAlias(reader),
      );
    case 0x03:
      final name = reader.readName();
      return WasmComponentCoreTypeDeclaration(
        kind: WasmComponentCoreTypeDeclarationKind.export,
        name: name,
        descriptor: _readCoreExternDescriptor(reader),
      );
    default:
      throw FormatException(
        'Unsupported Wasm component core module type declaration: 0x${kind.toRadixString(16)}.',
      );
  }
}

WasmComponentAlias _readCoreTypeAlias(ByteReader reader) {
  return WasmComponentAlias(
    sort: WasmComponentSort(
      kind: WasmComponentSortKind.core,
      coreKind: _readCoreSortKind(reader),
    ),
    target: _readCoreOuterAliasTarget(reader),
  );
}

WasmComponentAliasTarget _readCoreOuterAliasTarget(ByteReader reader) {
  final kind = reader.readByte();
  if (kind != 0x01) {
    throw FormatException(
      'Unsupported Wasm component core alias target: 0x${kind.toRadixString(16)}.',
    );
  }
  return WasmComponentAliasTarget.outer(
    componentDepth: reader.readVarUint32(),
    index: reader.readVarUint32(),
  );
}

WasmComponentCoreType _readCoreRecursiveType(ByteReader reader, int lead) {
  if (lead == 0x4e) {
    final count = reader.readVarUint32();
    final types = <WasmComponentCoreType>[];
    for (var i = 0; i < count; i++) {
      types.add(_readCoreSubtype(reader, reader.readByte()));
    }
    return WasmComponentCoreType(
      kind: WasmComponentCoreTypeKind.recursive,
      types: List.unmodifiable(types),
    );
  }
  return _readCoreSubtype(reader, lead);
}

WasmComponentCoreType _readCoreSubtype(ByteReader reader, int lead) {
  var form = lead;
  final superTypeIndices = <int>[];
  while (true) {
    switch (form) {
      case 0x50:
      case 0x4f:
        final superCount = reader.readVarUint32();
        for (var i = 0; i < superCount; i++) {
          superTypeIndices.add(reader.readVarUint32());
        }
        form = reader.readByte();
        continue;
      case 0x4c:
      case 0x4d:
        reader.readVarUint32();
        form = reader.readByte();
        continue;
      default:
        final composite = _readCoreCompositeType(reader, form);
        if (superTypeIndices.isEmpty) {
          return composite;
        }
        return WasmComponentCoreType(
          kind: WasmComponentCoreTypeKind.subtype,
          types: <WasmComponentCoreType>[composite],
          superTypeIndices: List.unmodifiable(superTypeIndices),
        );
    }
  }
}

WasmComponentCoreType _readCoreCompositeType(ByteReader reader, int form) {
  switch (form) {
    case 0x60:
      _readCoreValueTypeVector(reader);
      _readCoreValueTypeVector(reader);
      return const WasmComponentCoreType(
        kind: WasmComponentCoreTypeKind.function,
      );
    case 0x5f:
      final fieldCount = reader.readVarUint32();
      for (var i = 0; i < fieldCount; i++) {
        _readCoreFieldType(reader);
      }
      return const WasmComponentCoreType(
        kind: WasmComponentCoreTypeKind.struct,
      );
    case 0x5e:
      _readCoreFieldType(reader);
      return const WasmComponentCoreType(kind: WasmComponentCoreTypeKind.array);
    default:
      throw FormatException(
        'Unsupported Wasm component core composite type: 0x${form.toRadixString(16)}.',
      );
  }
}

void _readCoreValueTypeVector(ByteReader reader) {
  final count = reader.readVarUint32();
  for (var i = 0; i < count; i++) {
    _readCoreValueType(reader);
  }
}

void _readCoreFieldType(ByteReader reader) {
  final lead = reader.readByte();
  if (lead != 0x78 && lead != 0x77) {
    _readCoreValueTypeWithLead(reader, lead);
  }
  final mutability = reader.readByte();
  if (mutability != 0x00 && mutability != 0x01) {
    throw FormatException(
      'Unsupported Wasm component core field mutability: 0x${mutability.toRadixString(16)}.',
    );
  }
}

WasmComponentCoreExternDescriptor _readCoreExternDescriptor(ByteReader reader) {
  final kind = reader.readByte();
  switch (kind) {
    case 0x00:
    case 0x20:
      return WasmComponentCoreExternDescriptor(
        kind: WasmComponentCoreSortKind.function,
        typeIndex: reader.readVarUint32(),
      );
    case 0x01:
      _readCoreTableType(reader);
      return const WasmComponentCoreExternDescriptor(
        kind: WasmComponentCoreSortKind.table,
      );
    case 0x02:
      final limits = _readCoreMemoryType(reader);
      return WasmComponentCoreExternDescriptor(
        kind: WasmComponentCoreSortKind.memory,
        limits: limits,
      );
    case 0x03:
      _readCoreGlobalType(reader);
      return const WasmComponentCoreExternDescriptor(
        kind: WasmComponentCoreSortKind.global,
      );
    case 0x04:
      _readCoreTagType(reader);
      return const WasmComponentCoreExternDescriptor(
        kind: WasmComponentCoreSortKind.tag,
      );
    default:
      throw FormatException(
        'Unsupported Wasm component core extern descriptor: 0x${kind.toRadixString(16)}.',
      );
  }
}

void _readCoreTableType(ByteReader reader) {
  _readCoreReferenceType(reader);
  _readCoreLimits(reader);
}

WasmLimits _readCoreMemoryType(ByteReader reader) => _readCoreLimits(reader);

void _readCoreGlobalType(ByteReader reader) {
  _readCoreValueType(reader);
  final mutability = reader.readByte();
  if (mutability != 0x00 && mutability != 0x01) {
    throw FormatException(
      'Unsupported Wasm component core global mutability: 0x${mutability.toRadixString(16)}.',
    );
  }
}

void _readCoreTagType(ByteReader reader) {
  final attribute = reader.readByte();
  if (attribute != 0x00) {
    throw FormatException(
      'Unsupported Wasm component core tag attribute: 0x${attribute.toRadixString(16)}.',
    );
  }
  reader.readVarUint32();
}

WasmLimits _readCoreLimits(ByteReader reader) {
  final flags = reader.readByte();
  if ((flags & ~0x0f) != 0) {
    throw FormatException(
      'Unsupported Wasm component core limits flags: 0x${flags.toRadixString(16)}.',
    );
  }
  final hasMax = (flags & 0x01) != 0;
  final shared = (flags & 0x02) != 0;
  final memory64 = (flags & 0x04) != 0;
  final hasPageSize = (flags & 0x08) != 0;
  final min = memory64 ? reader.readVarUint64() : reader.readVarUint32();
  final max = hasMax
      ? (memory64 ? reader.readVarUint64() : reader.readVarUint32())
      : null;
  return WasmLimits(
    min: min,
    max: max,
    shared: shared,
    memory64: memory64,
    pageSizeLog2: hasPageSize ? reader.readVarUint32() : 16,
  );
}

void _readCoreValueType(ByteReader reader) {
  _readCoreValueTypeWithLead(reader, reader.readByte());
}

void _readCoreValueTypeWithLead(ByteReader reader, int lead) {
  switch (lead) {
    case 0x7f:
    case 0x7e:
    case 0x7d:
    case 0x7c:
    case 0x7b:
      return;
    case 0x63:
    case 0x64:
    case 0x62:
    case 0x61:
      _readCoreHeapType(reader);
      return;
    default:
      if (_isCoreLegacyHeapType(lead)) {
        return;
      }
      if (lead <= 0x60 || lead >= 0x80) {
        _readSignedLebContinuation(reader, lead);
        return;
      }
      throw FormatException(
        'Unsupported Wasm component core value type: 0x${lead.toRadixString(16)}.',
      );
  }
}

void _readCoreReferenceType(ByteReader reader) {
  final lead = reader.readByte();
  if (_isCoreLegacyHeapType(lead)) {
    return;
  }
  if (lead == 0x63 || lead == 0x64 || lead == 0x62 || lead == 0x61) {
    _readCoreHeapType(reader);
    return;
  }
  if (lead <= 0x60 || lead >= 0x80) {
    _readSignedLebContinuation(reader, lead);
    return;
  }
  throw FormatException(
    'Unsupported Wasm component core reference type: 0x${lead.toRadixString(16)}.',
  );
}

void _readCoreHeapType(ByteReader reader) {
  var lead = reader.readByte();
  if (lead == 0x62 || lead == 0x61) {
    lead = reader.readByte();
  }
  if (_isCoreLegacyHeapType(lead)) {
    return;
  }
  _readSignedLebContinuation(reader, lead);
}

bool _isCoreLegacyHeapType(int code) {
  return switch (code & 0xff) {
    0x65 ||
    0x66 ||
    0x67 ||
    0x68 ||
    0x69 ||
    0x6a ||
    0x6b ||
    0x6c ||
    0x6d ||
    0x6e ||
    0x6f ||
    0x70 ||
    0x71 ||
    0x72 ||
    0x73 ||
    0x74 ||
    0x75 => true,
    _ => false,
  };
}

void _readSignedLebContinuation(ByteReader reader, int firstByte) {
  var byte = firstByte;
  var count = 1;
  while ((byte & 0x80) != 0) {
    if (count >= 5) {
      throw const FormatException('Invalid signed LEB encoding.');
    }
    byte = reader.readByte();
    count++;
  }
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
