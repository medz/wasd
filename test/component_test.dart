import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/features.dart';

void main() {
  group('WasmComponent.decode', () {
    test('decodes an empty component', () {
      final component = WasmComponent.decode(_emptyComponentBytes());

      expect(component.sections, isEmpty);
    });

    test('decodes component section framing and custom section names', () {
      final component = WasmComponent.decode(_customSectionComponentBytes());

      expect(component.sections, hasLength(1));
      expect(component.imports, isEmpty);
      expect(component.exports, isEmpty);
      final section = component.sections.single;
      expect(section.id, 0);
      expect(section.offset, 8);
      expect(section.payloadOffset, 10);
      expect(section.payloadSize, 5);
      expect(section.customName, 'name');
    });

    test('decodes component imports', () {
      final component = WasmComponent.decode(_importComponentBytes());

      expect(component.imports, hasLength(1));
      expect(component.exports, isEmpty);
      final import = component.imports.single;
      expect(import.name, 'wasi:cli/run@0.3.0');
      expect(import.versionSuffix, isNull);
      expect(import.descriptor.kind, WasmComponentExternKind.function);
      expect(import.descriptor.typeIndex, 0);
    });

    test('decodes component names with version suffixes', () {
      final component = WasmComponent.decode(_versionedImportComponentBytes());

      final import = component.imports.single;
      expect(import.name, 'wasi');
      expect(import.versionSuffix, '0.3.0');
      expect(import.descriptor.kind, WasmComponentExternKind.function);
      expect(import.descriptor.typeIndex, 0);
    });

    test('decodes value imports with direct value types', () {
      final component = WasmComponent.decode(_valueImportComponentBytes());

      final import = component.imports.single;
      expect(import.name, 'name');
      expect(import.descriptor.kind, WasmComponentExternKind.value);
      expect(
        import.descriptor.boundKind,
        WasmComponentExternBoundKind.valueType,
      );
      expect(
        import.descriptor.valueType!.primitive,
        WasmComponentPrimitiveValueType.string,
      );
    });

    test('decodes legacy component import name prefixes', () {
      final component = WasmComponent.decode(
        _legacyPrefixedImportComponentBytes(),
      );

      final import = component.imports.single;
      expect(import.name, 'a');
      expect(import.versionSuffix, isNull);
      expect(import.descriptor.kind, WasmComponentExternKind.function);
      expect(import.descriptor.typeIndex, 0);
    });

    test('decodes component exports without explicit descriptors', () {
      final component = WasmComponent.decode(_exportComponentBytes());

      expect(component.imports, hasLength(1));
      expect(component.exports, hasLength(1));
      final export = component.exports.single;
      expect(export.name, 'host-func');
      expect(export.versionSuffix, isNull);
      expect(export.sort.kind, WasmComponentSortKind.function);
      expect(export.sort.index, 0);
      expect(export.descriptor, isNull);
    });

    test('decodes component exports with explicit descriptors', () {
      final component = WasmComponent.decode(
        _exportWithDescriptorComponentBytes(),
      );

      final export = component.exports.single;
      expect(export.name, 'host-func');
      expect(export.sort.kind, WasmComponentSortKind.function);
      expect(export.sort.index, 0);
      expect(export.descriptor, isNotNull);
      expect(export.descriptor!.kind, WasmComponentExternKind.function);
      expect(export.descriptor!.typeIndex, 0);
    });

    test('decodes nested components', () {
      final component = WasmComponent.decode(_nestedComponentBytes());

      expect(component.imports, isEmpty);
      expect(component.exports, isEmpty);
      expect(component.components, hasLength(1));
      final child = component.components.single;
      expect(child.sections.map((section) => section.id), [7, 10]);
      expect(child.imports.single.name, 'child-func');
      expect(
        child.imports.single.descriptor.kind,
        WasmComponentExternKind.function,
      );
      expect(child.imports.single.descriptor.typeIndex, 0);
    });

    test('decodes embedded core modules', () {
      final component = WasmComponent.decode(_coreModuleComponentBytes());

      expect(component.coreModules, hasLength(1));
      final module = component.coreModules.single;
      expect(module.types, hasLength(1));
      expect(module.exports.single.name, 'run');
      expect(module.functionTypeIndices, [0]);
      expect(module.codes, hasLength(1));
    });

    test('decodes component core type sections', () {
      final component = WasmComponent.decode(_coreTypeComponentBytes());

      expect(component.coreTypes, hasLength(2));
      expect(
        component.coreTypes.first.kind,
        WasmComponentCoreTypeKind.function,
      );

      final moduleType = component.coreTypes.last;
      expect(moduleType.kind, WasmComponentCoreTypeKind.module);
      expect(moduleType.declarations, hasLength(2));
      expect(
        moduleType.declarations.first.kind,
        WasmComponentCoreTypeDeclarationKind.type,
      );
      final export = moduleType.declarations.last;
      expect(export.kind, WasmComponentCoreTypeDeclarationKind.export);
      expect(export.name, 'run');
      expect(export.descriptor!.kind, WasmComponentCoreSortKind.function);
      expect(export.descriptor!.typeIndex, 0);
    });

    test('decodes instantiated core instances', () {
      final component = WasmComponent.decode(
        _coreInstanceInstantiateComponentBytes(),
      );

      expect(component.coreInstances, hasLength(1));
      final instance = component.coreInstances.single;
      expect(instance.kind, WasmComponentCoreInstanceKind.instantiate);
      expect(instance.moduleIndex, 0);
      expect(instance.arguments, isEmpty);
    });

    test('decodes core instances with inline exports', () {
      final component = WasmComponent.decode(
        _coreInstanceInlineComponentBytes(),
      );

      expect(component.coreInstances, hasLength(2));
      final instance = component.coreInstances.last;
      expect(instance.kind, WasmComponentCoreInstanceKind.inlineExports);
      expect(instance.exports, hasLength(1));
      expect(instance.exports.single.name, 'mem');
      expect(
        instance.exports.single.sort.kind,
        WasmComponentCoreSortKind.memory,
      );
      expect(instance.exports.single.sort.index, 0);
    });

    test('decodes core instantiation arguments', () {
      final component = WasmComponent.decode(
        _coreInstanceArgumentComponentBytes(),
      );

      final instance = component.coreInstances.single;
      expect(instance.kind, WasmComponentCoreInstanceKind.instantiate);
      expect(instance.moduleIndex, 0);
      expect(instance.arguments, hasLength(1));
      expect(instance.arguments.single.name, 'dep');
      expect(instance.arguments.single.instanceIndex, 0);
    });

    test('decodes inline component instances', () {
      final component = WasmComponent.decode(_inlineInstanceComponentBytes());

      expect(component.instances, hasLength(1));
      final instance = component.instances.single;
      expect(instance.kind, WasmComponentInstanceKind.inlineExports);
      expect(instance.exports, hasLength(1));
      expect(instance.exports.single.name, 'f');
      expect(instance.exports.single.sort.kind, WasmComponentSortKind.function);
      expect(instance.exports.single.sort.index, 0);
    });

    test('decodes component instantiation arguments', () {
      final component = WasmComponent.decode(
        _instantiateInstanceComponentBytes(),
      );

      expect(component.components, hasLength(1));
      expect(component.instances, hasLength(2));
      final instance = component.instances.last;
      expect(instance.kind, WasmComponentInstanceKind.instantiate);
      expect(instance.componentIndex, 0);
      expect(instance.arguments, hasLength(1));
      expect(instance.arguments.single.name, 'dep');
      expect(
        instance.arguments.single.sort.kind,
        WasmComponentSortKind.instance,
      );
      expect(instance.arguments.single.sort.index, 0);
    });

    test('decodes component export aliases', () {
      final component = WasmComponent.decode(_exportAliasComponentBytes());

      expect(component.aliases, hasLength(1));
      final alias = component.aliases.single;
      expect(alias.sort.kind, WasmComponentSortKind.function);
      expect(alias.target.kind, WasmComponentAliasTargetKind.export);
      expect(alias.target.instanceIndex, 0);
      expect(alias.target.name, 'f');
    });

    test('decodes core export aliases', () {
      final component = WasmComponent.decode(_coreExportAliasComponentBytes());

      expect(component.aliases, hasLength(1));
      final alias = component.aliases.single;
      expect(alias.sort.kind, WasmComponentSortKind.core);
      expect(alias.sort.coreKind, WasmComponentCoreSortKind.memory);
      expect(alias.target.kind, WasmComponentAliasTargetKind.coreExport);
      expect(alias.target.coreInstanceIndex, 0);
      expect(alias.target.name, 'mem');
    });

    test('decodes core tag export aliases', () {
      final component = WasmComponent.decode(
        _coreTagExportAliasComponentBytes(),
      );

      final alias = component.aliases.single;
      expect(alias.sort.kind, WasmComponentSortKind.core);
      expect(alias.sort.coreKind, WasmComponentCoreSortKind.tag);
      expect(alias.target.kind, WasmComponentAliasTargetKind.coreExport);
      expect(alias.target.coreInstanceIndex, 0);
      expect(alias.target.name, 'e');
    });

    test('decodes outer aliases in nested components', () {
      final component = WasmComponent.decode(_outerAliasComponentBytes());

      expect(component.components, hasLength(2));
      final child = component.components.last;
      expect(child.aliases, hasLength(1));
      final alias = child.aliases.single;
      expect(alias.sort.kind, WasmComponentSortKind.component);
      expect(alias.target.kind, WasmComponentAliasTargetKind.outer);
      expect(alias.target.componentDepth, 1);
      expect(alias.target.index, 0);
    });

    test('decodes canonical lift and lower definitions', () {
      final component = WasmComponent.decode(
        _canonicalLiftLowerComponentBytes(),
      );

      expect(component.canonicalDefinitions, hasLength(2));
      final lift = component.canonicalDefinitions.first;
      expect(lift.kind, WasmComponentCanonicalKind.lift);
      expect(lift.coreFunctionIndex, 0);
      expect(lift.typeIndex, 0);
      expect(lift.options, hasLength(1));
      expect(lift.options.single.kind, WasmComponentCanonicalOptionKind.memory);
      expect(lift.options.single.index, 0);

      final lower = component.canonicalDefinitions.last;
      expect(lower.kind, WasmComponentCanonicalKind.lower);
      expect(lower.functionIndex, 0);
      expect(lower.options, isEmpty);
    });

    test('decodes component type definitions', () {
      final component = WasmComponent.decode(_typeDefinitionsComponentBytes());

      expect(component.typeDefinitions, hasLength(5));
      final tuple = component.typeDefinitions[0].definedValue!;
      expect(tuple.kind, WasmComponentDefinedValueTypeKind.tuple);
      expect(tuple.types.map((type) => type.primitive), [
        WasmComponentPrimitiveValueType.u8,
        WasmComponentPrimitiveValueType.u32,
      ]);

      final function = component.typeDefinitions[1].function!;
      expect(function.params.single.label, 'x');
      expect(
        function.params.single.type.primitive,
        WasmComponentPrimitiveValueType.string,
      );
      expect(function.result!.typeIndex, 0);

      final record = component.typeDefinitions[2].definedValue!;
      expect(record.kind, WasmComponentDefinedValueTypeKind.record);
      expect(record.fields.map((field) => field.label), ['a', 'b']);

      final variant = component.typeDefinitions[3].definedValue!;
      expect(variant.kind, WasmComponentDefinedValueTypeKind.variant);
      expect(variant.cases.map((case_) => case_.label), ['a', 'b']);

      final resource = component.typeDefinitions[4].resource!;
      expect(resource.representationTypeCode, 0x7f);
      expect(resource.destructorFunctionIndex, isNull);
    });

    test('decodes component and instance type declarations', () {
      final component = WasmComponent.decode(
        _componentInstanceTypesComponentBytes(),
      );

      expect(component.typeDefinitions, hasLength(2));
      final instance = component.typeDefinitions.first.instance!;
      expect(instance.declarations, hasLength(2));
      expect(
        instance.declarations.first.kind,
        WasmComponentTypeDeclarationKind.type,
      );
      final instanceExport = instance.declarations.last.export!;
      expect(instanceExport.name, 'a');
      expect(instanceExport.descriptor.kind, WasmComponentExternKind.function);

      final componentType = component.typeDefinitions.last.component!;
      expect(componentType.declarations, hasLength(4));
      expect(
        componentType.declarations.first.kind,
        WasmComponentTypeDeclarationKind.type,
      );
      final componentImport = componentType.declarations[1].import!;
      expect(componentImport.name, 'a');
      expect(componentImport.descriptor.kind, WasmComponentExternKind.function);
      final componentExport = componentType.declarations.last.export!;
      expect(componentExport.name, 'b');
      expect(componentExport.descriptor.kind, WasmComponentExternKind.function);
    });

    test('decodes component starts', () {
      final component = WasmComponent.decode(_startComponentBytes());

      expect(component.starts, hasLength(1));
      final start = component.starts.single;
      expect(start.functionIndex, 0);
      expect(start.arguments, isEmpty);
      expect(start.resultCount, 1);
    });

    test('decodes component start value arguments', () {
      final component = WasmComponent.decode(_startArgumentsComponentBytes());

      final start = component.starts.single;
      expect(start.functionIndex, 3);
      expect(start.arguments, [1, 2]);
      expect(start.resultCount, 4);
    });

    test('decodes component value definitions', () {
      final component = WasmComponent.decode(_valueDefinitionsComponentBytes());

      expect(component.valueDefinitions, hasLength(3));
      final boolean = component.valueDefinitions[0];
      expect(boolean.type.primitive, WasmComponentPrimitiveValueType.boolean);
      expect(boolean.value.kind, WasmComponentValueDataKind.boolean);
      expect(boolean.value.boolean, isTrue);

      final integer = component.valueDefinitions[1];
      expect(integer.type.primitive, WasmComponentPrimitiveValueType.u32);
      expect(integer.value.kind, WasmComponentValueDataKind.integer);
      expect(integer.value.integer, 3);

      final string = component.valueDefinitions[2];
      expect(string.type.primitive, WasmComponentPrimitiveValueType.string);
      expect(string.value.kind, WasmComponentValueDataKind.string);
      expect(string.value.string, 'hi');
    });

    test('resolves type-indexed component value definitions', () {
      final component = WasmComponent.decode(
        _typedValueDefinitionsComponentBytes(),
      );

      final value = component.valueDefinitions.single;
      expect(value.type.typeIndex, 0);
      expect(value.value.kind, WasmComponentValueDataKind.tuple);
      expect(value.value.items.map((item) => item.integer), [5, 0x1234]);
    });

    test('decodes variable-size typed component values', () {
      final component = WasmComponent.decode(
        _variableSizeValueDefinitionsComponentBytes(),
      );

      final value = component.valueDefinitions.single;
      expect(value.value.kind, WasmComponentValueDataKind.tuple);
      expect(value.value.items[0].integer, 5);
      expect(value.value.items[1].string, 'hi');
    });

    test('decodes fixed-list component value definitions', () {
      final component = WasmComponent.decode(
        _fixedListValueDefinitionsComponentBytes(),
      );

      final value = component.valueDefinitions.single;
      expect(value.value.kind, WasmComponentValueDataKind.fixedList);
      expect(value.value.items.map((item) => item.integer), [1, 2, 3]);
    });

    test('decodes enum and flags component value definitions', () {
      final component = WasmComponent.decode(
        _enumFlagsValueDefinitionsComponentBytes(),
      );

      final enumValue = component.valueDefinitions[0].value;
      expect(enumValue.kind, WasmComponentValueDataKind.enumeration);
      expect(enumValue.index, 2);
      expect(enumValue.label, 'c');

      final flagsValue = component.valueDefinitions[1].value;
      expect(flagsValue.kind, WasmComponentValueDataKind.flags);
      expect(flagsValue.labels, ['a', 'c']);
    });

    test('decodes option and result component value definitions', () {
      final component = WasmComponent.decode(
        _optionResultValueDefinitionsComponentBytes(),
      );

      final optionValue = component.valueDefinitions[0].value;
      expect(optionValue.kind, WasmComponentValueDataKind.option);
      expect(optionValue.isSome, isTrue);
      expect(optionValue.associatedValue!.string, 'hi');

      final okValue = component.valueDefinitions[1].value;
      expect(okValue.kind, WasmComponentValueDataKind.result);
      expect(okValue.isOk, isTrue);
      expect(okValue.associatedValue!.integer, 7);

      final errorValue = component.valueDefinitions[2].value;
      expect(errorValue.kind, WasmComponentValueDataKind.result);
      expect(errorValue.isOk, isFalse);
      expect(errorValue.associatedValue!.string, 'no');
    });

    test('decodes variant component value definitions', () {
      final component = WasmComponent.decode(
        _variantValueDefinitionsComponentBytes(),
      );

      final value = component.valueDefinitions.single.value;
      expect(value.kind, WasmComponentValueDataKind.variant);
      expect(value.index, 1);
      expect(value.label, 'num');
      expect(value.associatedValue!.integer, 9);
    });

    test('reports duplicate component defined value type labels', () {
      final invalidTypes = <Uint8List>[
        _duplicateRecordLabelsTypeComponentBytes(),
        _duplicateVariantLabelsTypeComponentBytes(),
        _duplicateFlagsLabelsTypeComponentBytes(),
        _duplicateEnumLabelsTypeComponentBytes(),
      ];

      for (final bytes in invalidTypes) {
        final errors = WasmComponent.decode(bytes).validate();
        expect(errors, hasLength(1));
        expect(errors.single.message, contains('Duplicate Wasm component'));
      }
    });

    test('reports invalid component value type indexes', () {
      final wrongSort = WasmComponent.decode(
        _functionResultWrongSortTypeIndexComponentBytes(),
      ).validate();
      expect(wrongSort, hasLength(1));
      expect(
        wrongSort.single.message,
        contains('does not refer to a value type'),
      );

      final outOfRange = WasmComponent.decode(
        _listElementOutOfRangeTypeIndexComponentBytes(),
      ).validate();
      expect(outOfRange, hasLength(1));
      expect(
        outOfRange.single.message,
        contains('Unknown Wasm component value type index'),
      );
    });

    test('reports invalid component resource type indexes', () {
      expect(
        WasmComponent.decode(_ownedResourceTypeComponentBytes()).validate(),
        isEmpty,
      );

      final wrongSort = WasmComponent.decode(
        _ownedWrongSortTypeIndexComponentBytes(),
      ).validate();
      expect(wrongSort, hasLength(1));
      expect(
        wrongSort.single.message,
        contains('does not refer to a resource type'),
      );

      final outOfRange = WasmComponent.decode(
        _borrowedOutOfRangeTypeIndexComponentBytes(),
      ).validate();
      expect(outOfRange, hasLength(1));
      expect(
        outOfRange.single.message,
        contains('Unknown Wasm component resource type index'),
      );
    });

    test('reports invalid component import descriptor type indexes', () {
      expect(WasmComponent.decode(_importComponentBytes()).validate(), isEmpty);

      final wrongSort = WasmComponent.decode(
        _functionImportWrongSortTypeIndexComponentBytes(),
      ).validate();
      expect(wrongSort, hasLength(1));
      expect(
        wrongSort.single.message,
        contains('does not refer to a function type'),
      );

      final invalidValueType = WasmComponent.decode(
        _valueImportOutOfRangeTypeIndexComponentBytes(),
      ).validate();
      expect(invalidValueType, hasLength(1));
      expect(
        invalidValueType.single.message,
        contains('Unknown Wasm component value type index'),
      );
    });

    test('reports value import equality indexes before definition', () {
      final errors = WasmComponent.decode(
        _valueImportEqualityBeforeDefinitionComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(
        errors.single.message,
        contains('Unknown Wasm component value index'),
      );
    });

    test('reports invalid canonical result value type indexes', () {
      final errors = WasmComponent.decode(
        _canonicalResultOutOfRangeTypeIndexComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(
        errors.single.message,
        contains('Unknown Wasm component value type index'),
      );
    });

    test('reports invalid canonical resource type indexes', () {
      expect(
        WasmComponent.decode(_canonicalResourceTypeComponentBytes()).validate(),
        isEmpty,
      );

      final wrongSort = WasmComponent.decode(
        _canonicalResourceWrongSortTypeIndexComponentBytes(),
      ).validate();
      expect(wrongSort, hasLength(1));
      expect(
        wrongSort.single.message,
        contains('does not refer to a resource type'),
      );

      final outOfRange = WasmComponent.decode(
        _canonicalResourceOutOfRangeTypeIndexComponentBytes(),
      ).validate();
      expect(outOfRange, hasLength(1));
      expect(
        outOfRange.single.message,
        contains('Unknown Wasm component resource type index'),
      );
    });

    test('reports invalid canonical lift function type indexes', () {
      final wrongSort = WasmComponent.decode(
        _canonicalLiftWrongSortTypeIndexComponentBytes(),
      ).validate();
      expect(wrongSort, hasLength(1));
      expect(
        wrongSort.single.message,
        contains('does not refer to a function type'),
      );

      final outOfRange = WasmComponent.decode(
        _canonicalLiftOutOfRangeTypeIndexComponentBytes(),
      ).validate();
      expect(outOfRange, hasLength(1));
      expect(
        outOfRange.single.message,
        contains('Unknown Wasm component function type index'),
      );
    });

    test('reports duplicate and conflicting canonical options', () {
      final conflictingStringEncoding = WasmComponent.decode(
        _canonicalConflictingStringEncodingComponentBytes(),
      ).validate();
      expect(conflictingStringEncoding, hasLength(1));
      expect(
        conflictingStringEncoding.single.message,
        contains('Conflicting Wasm component canonical string encoding option'),
      );

      final duplicateMemory = WasmComponent.decode(
        _canonicalDuplicateMemoryOptionComponentBytes(),
      ).validate();
      expect(duplicateMemory, hasLength(1));
      expect(
        duplicateMemory.single.message,
        contains('Duplicate Wasm component canonical option'),
      );
    });

    test('reports invalid component start indexes', () {
      expect(WasmComponent.decode(_startComponentBytes()).validate(), isEmpty);

      final invalidFunction = WasmComponent.decode(
        _startOutOfRangeFunctionIndexComponentBytes(),
      ).validate();
      expect(invalidFunction, hasLength(1));
      expect(
        invalidFunction.single.message,
        contains('Unknown Wasm component function index'),
      );

      final invalidArgument = WasmComponent.decode(
        _startOutOfRangeValueArgumentComponentBytes(),
      ).validate();
      expect(invalidArgument, hasLength(1));
      expect(
        invalidArgument.single.message,
        contains('Unknown Wasm component value index'),
      );
    });

    test('reports component index references before definition', () {
      final startBeforeValue = WasmComponent.decode(
        _startArgumentDefinedAfterStartComponentBytes(),
      ).validate();
      expect(startBeforeValue, hasLength(1));
      expect(
        startBeforeValue.single.message,
        contains('Unknown Wasm component value index'),
      );

      final lowerBeforeFunction = WasmComponent.decode(
        _canonicalLowerFunctionDefinedAfterComponentBytes(),
      ).validate();
      expect(lowerBeforeFunction, hasLength(1));
      expect(
        lowerBeforeFunction.single.message,
        contains('Unknown Wasm component function index'),
      );
    });

    test('reports invalid component stream char element types', () {
      expect(
        WasmComponent.decode(_streamStringTypeComponentBytes()).validate(),
        isEmpty,
      );

      final errors = WasmComponent.decode(
        _streamCharTypeComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(errors.single.message, contains('stream element type'));
      expect(errors.single.message, contains('char'));
    });

    test('reports stream and future element types containing borrow', () {
      expect(
        WasmComponent.decode(_streamOwnTypeComponentBytes()).validate(),
        isEmpty,
      );

      final stream = WasmComponent.decode(
        _streamBorrowTypeComponentBytes(),
      ).validate();
      expect(stream, hasLength(1));
      expect(stream.single.message, contains('stream element type'));
      expect(stream.single.message, contains('borrow'));

      final future = WasmComponent.decode(
        _futureBorrowTypeComponentBytes(),
      ).validate();
      expect(future, hasLength(1));
      expect(future.single.message, contains('future element type'));
      expect(future.single.message, contains('borrow'));
    });

    test('reports function result types containing borrow', () {
      expect(
        WasmComponent.decode(_functionOwnResultTypeComponentBytes()).validate(),
        isEmpty,
      );

      final errors = WasmComponent.decode(
        _functionBorrowResultTypeComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(errors.single.message, contains('function result type'));
      expect(errors.single.message, contains('borrow'));
    });

    test('rejects component decoding when the feature is disabled', () {
      expect(
        () => WasmComponent.decode(
          _emptyComponentBytes(),
          features: const WasmFeatureSet(),
        ),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('rejects core module binaries as components', () {
      expect(
        () => WasmComponent.decode(_emptyCoreModuleBytes()),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects truncated component sections', () {
      expect(
        () => WasmComponent.decode(_truncatedSectionComponentBytes()),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

Uint8List _emptyComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
]);

Uint8List _customSectionComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x04,
  0x6e,
  0x61,
  0x6d,
  0x65,
]);

Uint8List _importComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x05,
  0x01,
  0x40,
  0x00,
  0x01,
  0x00,
  0x0a,
  0x17,
  0x01,
  0x00,
  0x12,
  0x77,
  0x61,
  0x73,
  0x69,
  0x3a,
  0x63,
  0x6c,
  0x69,
  0x2f,
  0x72,
  0x75,
  0x6e,
  0x40,
  0x30,
  0x2e,
  0x33,
  0x2e,
  0x30,
  0x01,
  0x00,
]);

Uint8List _versionedImportComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x0a,
  0x0f,
  0x01,
  0x01,
  0x04,
  0x77,
  0x61,
  0x73,
  0x69,
  0x05,
  0x30,
  0x2e,
  0x33,
  0x2e,
  0x30,
  0x01,
  0x00,
]);

Uint8List _valueImportComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x0a,
  0x09,
  0x01,
  0x00,
  0x04,
  0x6e,
  0x61,
  0x6d,
  0x65,
  0x02,
  0x73,
  0x00,
  0x19,
  0x0e,
  0x63,
  0x6f,
  0x6d,
  0x70,
  0x6f,
  0x6e,
  0x65,
  0x6e,
  0x74,
  0x2d,
  0x6e,
  0x61,
  0x6d,
  0x65,
  0x01,
  0x08,
  0x02,
  0x01,
  0x00,
  0x04,
  0x6e,
  0x61,
  0x6d,
  0x65,
]);

Uint8List _legacyPrefixedImportComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x07,
      0x05,
      0x01,
      0x40,
      0x00,
      0x01,
      0x00,
      0x0a,
      0x06,
      0x01,
      0x01,
      0x01,
      0x61,
      0x01,
      0x00,
    ]);

Uint8List _functionImportWrongSortTypeIndexComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x07,
      0x02,
      0x01,
      0x7f,
      0x0a,
      0x06,
      0x01,
      0x00,
      0x01,
      0x66,
      0x01,
      0x00,
    ]);

Uint8List _valueImportOutOfRangeTypeIndexComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x0a,
      0x07,
      0x01,
      0x00,
      0x01,
      0x76,
      0x02,
      0x01,
      0x00,
    ]);

Uint8List _valueImportEqualityBeforeDefinitionComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x0a,
      0x07,
      0x01,
      0x00,
      0x01,
      0x76,
      0x02,
      0x00,
      0x00,
    ]);

Uint8List _exportComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x05,
  0x01,
  0x40,
  0x00,
  0x01,
  0x00,
  0x0a,
  0x0e,
  0x01,
  0x00,
  0x09,
  0x68,
  0x6f,
  0x73,
  0x74,
  0x2d,
  0x66,
  0x75,
  0x6e,
  0x63,
  0x01,
  0x00,
  0x0b,
  0x0f,
  0x01,
  0x00,
  0x09,
  0x68,
  0x6f,
  0x73,
  0x74,
  0x2d,
  0x66,
  0x75,
  0x6e,
  0x63,
  0x01,
  0x00,
  0x00,
]);

Uint8List _exportWithDescriptorComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x07,
      0x05,
      0x01,
      0x40,
      0x00,
      0x01,
      0x00,
      0x0a,
      0x0e,
      0x01,
      0x00,
      0x09,
      0x68,
      0x6f,
      0x73,
      0x74,
      0x2d,
      0x66,
      0x75,
      0x6e,
      0x63,
      0x01,
      0x00,
      0x0b,
      0x11,
      0x01,
      0x00,
      0x09,
      0x68,
      0x6f,
      0x73,
      0x74,
      0x2d,
      0x66,
      0x75,
      0x6e,
      0x63,
      0x01,
      0x00,
      0x01,
      0x01,
      0x00,
    ]);

Uint8List _nestedComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x04,
  0x20,
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x05,
  0x01,
  0x40,
  0x00,
  0x01,
  0x00,
  0x0a,
  0x0f,
  0x01,
  0x00,
  0x0a,
  0x63,
  0x68,
  0x69,
  0x6c,
  0x64,
  0x2d,
  0x66,
  0x75,
  0x6e,
  0x63,
  0x01,
  0x00,
]);

Uint8List _coreModuleComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x01,
  0x21,
  0x00,
  0x61,
  0x73,
  0x6d,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x04,
  0x01,
  0x60,
  0x00,
  0x00,
  0x03,
  0x02,
  0x01,
  0x00,
  0x07,
  0x07,
  0x01,
  0x03,
  0x72,
  0x75,
  0x6e,
  0x00,
  0x00,
  0x0a,
  0x04,
  0x01,
  0x02,
  0x00,
  0x0b,
]);

Uint8List _coreTypeComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x03,
  0x11,
  0x02,
  0x60,
  0x00,
  0x00,
  0x50,
  0x02,
  0x01,
  0x60,
  0x00,
  0x00,
  0x03,
  0x03,
  0x72,
  0x75,
  0x6e,
  0x00,
  0x00,
  0x00,
  0x1a,
  0x0e,
  0x63,
  0x6f,
  0x6d,
  0x70,
  0x6f,
  0x6e,
  0x65,
  0x6e,
  0x74,
  0x2d,
  0x6e,
  0x61,
  0x6d,
  0x65,
  0x01,
  0x09,
  0x00,
  0x10,
  0x02,
  0x00,
  0x01,
  0x66,
  0x01,
  0x01,
  0x6d,
]);

Uint8List _coreInstanceInstantiateComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x01,
      0x16,
      0x00,
      0x61,
      0x73,
      0x6d,
      0x01,
      0x00,
      0x00,
      0x00,
      0x05,
      0x03,
      0x01,
      0x00,
      0x01,
      0x07,
      0x07,
      0x01,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x02,
      0x00,
      0x02,
      0x04,
      0x01,
      0x00,
      0x00,
      0x00,
    ]);

Uint8List _coreInstanceInlineComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x01,
  0x16,
  0x00,
  0x61,
  0x73,
  0x6d,
  0x01,
  0x00,
  0x00,
  0x00,
  0x05,
  0x03,
  0x01,
  0x00,
  0x01,
  0x07,
  0x07,
  0x01,
  0x03,
  0x6d,
  0x65,
  0x6d,
  0x02,
  0x00,
  0x02,
  0x04,
  0x01,
  0x00,
  0x00,
  0x00,
  0x06,
  0x09,
  0x01,
  0x00,
  0x02,
  0x01,
  0x00,
  0x03,
  0x6d,
  0x65,
  0x6d,
  0x02,
  0x09,
  0x01,
  0x01,
  0x01,
  0x03,
  0x6d,
  0x65,
  0x6d,
  0x02,
  0x00,
]);

Uint8List _coreInstanceArgumentComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x02,
      0x0a,
      0x01,
      0x00,
      0x00,
      0x01,
      0x03,
      0x64,
      0x65,
      0x70,
      0x12,
      0x00,
    ]);

Uint8List _inlineInstanceComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x05,
  0x01,
  0x40,
  0x00,
  0x01,
  0x00,
  0x0a,
  0x06,
  0x01,
  0x00,
  0x01,
  0x66,
  0x01,
  0x00,
  0x05,
  0x08,
  0x01,
  0x01,
  0x01,
  0x00,
  0x01,
  0x66,
  0x01,
  0x00,
]);

Uint8List _instantiateInstanceComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x04,
      0x2c,
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x07,
      0x03,
      0x01,
      0x42,
      0x00,
      0x0a,
      0x08,
      0x01,
      0x00,
      0x03,
      0x64,
      0x65,
      0x70,
      0x05,
      0x00,
      0x00,
      0x13,
      0x0e,
      0x63,
      0x6f,
      0x6d,
      0x70,
      0x6f,
      0x6e,
      0x65,
      0x6e,
      0x74,
      0x2d,
      0x6e,
      0x61,
      0x6d,
      0x65,
      0x00,
      0x02,
      0x01,
      0x63,
      0x05,
      0x0c,
      0x02,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x03,
      0x64,
      0x65,
      0x70,
      0x05,
      0x00,
      0x00,
      0x1f,
      0x0e,
      0x63,
      0x6f,
      0x6d,
      0x70,
      0x6f,
      0x6e,
      0x65,
      0x6e,
      0x74,
      0x2d,
      0x6e,
      0x61,
      0x6d,
      0x65,
      0x01,
      0x05,
      0x04,
      0x01,
      0x00,
      0x01,
      0x63,
      0x01,
      0x07,
      0x05,
      0x01,
      0x00,
      0x03,
      0x64,
      0x65,
      0x70,
    ]);

Uint8List _exportAliasComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x05,
  0x01,
  0x40,
  0x00,
  0x01,
  0x00,
  0x0a,
  0x06,
  0x01,
  0x00,
  0x01,
  0x66,
  0x01,
  0x00,
  0x05,
  0x08,
  0x01,
  0x01,
  0x01,
  0x00,
  0x01,
  0x66,
  0x01,
  0x00,
  0x06,
  0x06,
  0x01,
  0x01,
  0x00,
  0x00,
  0x01,
  0x66,
]);

Uint8List _coreExportAliasComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x01,
  0x16,
  0x00,
  0x61,
  0x73,
  0x6d,
  0x01,
  0x00,
  0x00,
  0x00,
  0x05,
  0x03,
  0x01,
  0x00,
  0x01,
  0x07,
  0x07,
  0x01,
  0x03,
  0x6d,
  0x65,
  0x6d,
  0x02,
  0x00,
  0x02,
  0x04,
  0x01,
  0x00,
  0x00,
  0x00,
  0x06,
  0x09,
  0x01,
  0x00,
  0x02,
  0x01,
  0x00,
  0x03,
  0x6d,
  0x65,
  0x6d,
]);

Uint8List _coreTagExportAliasComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x01,
  0x1a,
  0x00,
  0x61,
  0x73,
  0x6d,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x04,
  0x01,
  0x60,
  0x00,
  0x00,
  0x0d,
  0x03,
  0x01,
  0x00,
  0x00,
  0x07,
  0x05,
  0x01,
  0x01,
  0x65,
  0x04,
  0x00,
  0x02,
  0x04,
  0x01,
  0x00,
  0x00,
  0x00,
  0x06,
  0x07,
  0x01,
  0x00,
  0x04,
  0x01,
  0x00,
  0x01,
  0x65,
]);

Uint8List _outerAliasComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x04,
  0x08,
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x04,
  0x0f,
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x06,
  0x05,
  0x01,
  0x04,
  0x02,
  0x01,
  0x00,
]);

Uint8List _canonicalLiftLowerComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x01,
  0x38,
  0x00,
  0x61,
  0x73,
  0x6d,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x05,
  0x01,
  0x60,
  0x00,
  0x01,
  0x7f,
  0x03,
  0x02,
  0x01,
  0x00,
  0x05,
  0x03,
  0x01,
  0x00,
  0x01,
  0x07,
  0x0b,
  0x02,
  0x01,
  0x66,
  0x00,
  0x00,
  0x03,
  0x6d,
  0x65,
  0x6d,
  0x02,
  0x00,
  0x0a,
  0x06,
  0x01,
  0x04,
  0x00,
  0x41,
  0x01,
  0x0b,
  0x00,
  0x09,
  0x04,
  0x6e,
  0x61,
  0x6d,
  0x65,
  0x00,
  0x02,
  0x01,
  0x6d,
  0x02,
  0x04,
  0x01,
  0x00,
  0x00,
  0x00,
  0x07,
  0x05,
  0x01,
  0x40,
  0x00,
  0x00,
  0x7a,
  0x06,
  0x0f,
  0x02,
  0x00,
  0x00,
  0x01,
  0x00,
  0x01,
  0x66,
  0x00,
  0x02,
  0x01,
  0x00,
  0x03,
  0x6d,
  0x65,
  0x6d,
  0x08,
  0x0c,
  0x02,
  0x00,
  0x00,
  0x00,
  0x01,
  0x03,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x00,
  0x34,
  0x0e,
  0x63,
  0x6f,
  0x6d,
  0x70,
  0x6f,
  0x6e,
  0x65,
  0x6e,
  0x74,
  0x2d,
  0x6e,
  0x61,
  0x6d,
  0x65,
  0x01,
  0x0c,
  0x00,
  0x00,
  0x01,
  0x01,
  0x07,
  0x6c,
  0x6f,
  0x77,
  0x65,
  0x72,
  0x65,
  0x64,
  0x01,
  0x06,
  0x00,
  0x11,
  0x01,
  0x00,
  0x01,
  0x6d,
  0x01,
  0x06,
  0x00,
  0x12,
  0x01,
  0x00,
  0x01,
  0x6d,
  0x01,
  0x05,
  0x01,
  0x01,
  0x00,
  0x01,
  0x66,
]);

Uint8List _canonicalResultOutOfRangeTypeIndexComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x08,
      0x05,
      0x01,
      0x09,
      0x00,
      0x00,
      0x00,
    ]);

Uint8List _canonicalResourceTypeComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x07,
      0x04,
      0x01,
      0x3f,
      0x7f,
      0x00,
      0x08,
      0x03,
      0x01,
      0x02,
      0x00,
    ]);

Uint8List _canonicalResourceWrongSortTypeIndexComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x07,
      0x02,
      0x01,
      0x7f,
      0x08,
      0x03,
      0x01,
      0x02,
      0x00,
    ]);

Uint8List _canonicalResourceOutOfRangeTypeIndexComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x08,
      0x03,
      0x01,
      0x02,
      0x00,
    ]);

Uint8List _canonicalLiftWrongSortTypeIndexComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x07,
      0x02,
      0x01,
      0x7f,
      0x08,
      0x06,
      0x01,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
    ]);

Uint8List _canonicalLiftOutOfRangeTypeIndexComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x08,
      0x06,
      0x01,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
    ]);

Uint8List _canonicalConflictingStringEncodingComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x07,
      0x05,
      0x01,
      0x40,
      0x00,
      0x00,
      0x73,
      0x0a,
      0x06,
      0x01,
      0x00,
      0x01,
      0x66,
      0x01,
      0x00,
      0x08,
      0x07,
      0x01,
      0x01,
      0x00,
      0x00,
      0x02,
      0x00,
      0x01,
    ]);

Uint8List _canonicalDuplicateMemoryOptionComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x07,
      0x05,
      0x01,
      0x40,
      0x00,
      0x00,
      0x73,
      0x0a,
      0x06,
      0x01,
      0x00,
      0x01,
      0x66,
      0x01,
      0x00,
      0x08,
      0x09,
      0x01,
      0x01,
      0x00,
      0x00,
      0x02,
      0x03,
      0x00,
      0x03,
      0x01,
    ]);

Uint8List _typeDefinitionsComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x22,
  0x05,
  0x6f,
  0x02,
  0x7d,
  0x79,
  0x40,
  0x01,
  0x01,
  0x78,
  0x73,
  0x00,
  0x00,
  0x72,
  0x02,
  0x01,
  0x61,
  0x73,
  0x01,
  0x62,
  0x79,
  0x71,
  0x02,
  0x01,
  0x61,
  0x01,
  0x73,
  0x00,
  0x01,
  0x62,
  0x00,
  0x00,
  0x3f,
  0x7f,
  0x00,
]);

Uint8List _componentInstanceTypesComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x07,
      0x26,
      0x02,
      0x42,
      0x02,
      0x01,
      0x40,
      0x00,
      0x01,
      0x00,
      0x04,
      0x00,
      0x01,
      0x61,
      0x01,
      0x00,
      0x41,
      0x04,
      0x01,
      0x40,
      0x00,
      0x01,
      0x00,
      0x03,
      0x00,
      0x01,
      0x61,
      0x01,
      0x00,
      0x01,
      0x40,
      0x00,
      0x01,
      0x00,
      0x04,
      0x00,
      0x01,
      0x62,
      0x01,
      0x01,
    ]);

Uint8List _startComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x05,
  0x01,
  0x40,
  0x00,
  0x00,
  0x73,
  0x0a,
  0x06,
  0x01,
  0x00,
  0x01,
  0x66,
  0x01,
  0x00,
  0x09,
  0x03,
  0x00,
  0x00,
  0x01,
  0x00,
  0x16,
  0x0e,
  0x63,
  0x6f,
  0x6d,
  0x70,
  0x6f,
  0x6e,
  0x65,
  0x6e,
  0x74,
  0x2d,
  0x6e,
  0x61,
  0x6d,
  0x65,
  0x01,
  0x05,
  0x01,
  0x01,
  0x00,
  0x01,
  0x66,
]);

Uint8List _startArgumentsComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x09,
  0x05,
  0x03,
  0x02,
  0x01,
  0x02,
  0x04,
]);

Uint8List _startOutOfRangeFunctionIndexComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x09,
      0x03,
      0x00,
      0x00,
      0x00,
    ]);

Uint8List _startOutOfRangeValueArgumentComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x07,
      0x05,
      0x01,
      0x40,
      0x00,
      0x00,
      0x73,
      0x0a,
      0x06,
      0x01,
      0x00,
      0x01,
      0x66,
      0x01,
      0x00,
      0x09,
      0x04,
      0x00,
      0x01,
      0x00,
      0x00,
    ]);

Uint8List _startArgumentDefinedAfterStartComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x07,
      0x05,
      0x01,
      0x40,
      0x00,
      0x00,
      0x73,
      0x0a,
      0x06,
      0x01,
      0x00,
      0x01,
      0x66,
      0x01,
      0x00,
      0x09,
      0x04,
      0x00,
      0x01,
      0x00,
      0x00,
      0x0c,
      0x04,
      0x01,
      0x7f,
      0x01,
      0x01,
    ]);

Uint8List _canonicalLowerFunctionDefinedAfterComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x08,
      0x05,
      0x01,
      0x01,
      0x00,
      0x00,
      0x00,
      0x07,
      0x05,
      0x01,
      0x40,
      0x00,
      0x00,
      0x73,
      0x0a,
      0x06,
      0x01,
      0x00,
      0x01,
      0x66,
      0x01,
      0x00,
    ]);

Uint8List _valueDefinitionsComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x0c,
  0x0f,
  0x03,
  0x7f,
  0x01,
  0x01,
  0x79,
  0x04,
  0x03,
  0x00,
  0x00,
  0x00,
  0x73,
  0x03,
  0x02,
  0x68,
  0x69,
]);

Uint8List _typedValueDefinitionsComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x07,
      0x05,
      0x01,
      0x6f,
      0x02,
      0x7d,
      0x7b,
      0x0c,
      0x06,
      0x01,
      0x00,
      0x03,
      0x05,
      0x34,
      0x12,
    ]);

Uint8List _variableSizeValueDefinitionsComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x07,
      0x05,
      0x01,
      0x6f,
      0x02,
      0x7d,
      0x73,
      0x0c,
      0x07,
      0x01,
      0x00,
      0x04,
      0x05,
      0x02,
      0x68,
      0x69,
    ]);

Uint8List _fixedListValueDefinitionsComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x07,
      0x04,
      0x01,
      0x67,
      0x7d,
      0x03,
      0x0c,
      0x06,
      0x01,
      0x00,
      0x03,
      0x01,
      0x02,
      0x03,
    ]);

Uint8List _enumFlagsValueDefinitionsComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x07,
      0x11,
      0x02,
      0x6d,
      0x03,
      0x01,
      0x61,
      0x01,
      0x62,
      0x01,
      0x63,
      0x6e,
      0x03,
      0x01,
      0x61,
      0x01,
      0x62,
      0x01,
      0x63,
      0x0c,
      0x0a,
      0x02,
      0x00,
      0x04,
      0x02,
      0x00,
      0x00,
      0x00,
      0x01,
      0x01,
      0x05,
    ]);

Uint8List _optionResultValueDefinitionsComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x07,
      0x08,
      0x02,
      0x6b,
      0x73,
      0x6a,
      0x01,
      0x7d,
      0x01,
      0x73,
      0x0c,
      0x11,
      0x03,
      0x00,
      0x04,
      0x01,
      0x02,
      0x68,
      0x69,
      0x01,
      0x02,
      0x00,
      0x07,
      0x01,
      0x04,
      0x01,
      0x02,
      0x6e,
      0x6f,
    ]);

Uint8List _variantValueDefinitionsComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x07,
      0x11,
      0x01,
      0x71,
      0x02,
      0x04,
      0x6e,
      0x6f,
      0x6e,
      0x65,
      0x00,
      0x00,
      0x03,
      0x6e,
      0x75,
      0x6d,
      0x01,
      0x7d,
      0x00,
      0x0c,
      0x08,
      0x01,
      0x00,
      0x05,
      0x01,
      0x00,
      0x00,
      0x00,
      0x09,
    ]);

Uint8List _duplicateRecordLabelsTypeComponentBytes() =>
    _componentWithSingleTypeDefinitionBytes(const <int>[
      0x72,
      0x02,
      0x01,
      0x61,
      0x7d,
      0x01,
      0x61,
      0x7b,
    ]);

Uint8List _duplicateVariantLabelsTypeComponentBytes() =>
    _componentWithSingleTypeDefinitionBytes(const <int>[
      0x71,
      0x02,
      0x01,
      0x61,
      0x00,
      0x00,
      0x01,
      0x61,
      0x00,
      0x00,
    ]);

Uint8List _duplicateFlagsLabelsTypeComponentBytes() =>
    _componentWithSingleTypeDefinitionBytes(const <int>[
      0x6e,
      0x02,
      0x01,
      0x61,
      0x01,
      0x61,
    ]);

Uint8List _duplicateEnumLabelsTypeComponentBytes() =>
    _componentWithSingleTypeDefinitionBytes(const <int>[
      0x6d,
      0x02,
      0x01,
      0x61,
      0x01,
      0x61,
    ]);

Uint8List _functionResultWrongSortTypeIndexComponentBytes() =>
    _componentWithSingleTypeDefinitionBytes(const <int>[
      0x40,
      0x00,
      0x00,
      0x00,
    ]);

Uint8List _listElementOutOfRangeTypeIndexComponentBytes() =>
    _componentWithSingleTypeDefinitionBytes(const <int>[0x70, 0x01]);

Uint8List _ownedResourceTypeComponentBytes() =>
    _componentWithTypeDefinitionsBytes(const <int>[
      0x3f,
      0x7f,
      0x00,
      0x69,
      0x00,
    ], count: 2);

Uint8List _ownedWrongSortTypeIndexComponentBytes() =>
    _componentWithSingleTypeDefinitionBytes(const <int>[0x69, 0x00]);

Uint8List _borrowedOutOfRangeTypeIndexComponentBytes() =>
    _componentWithSingleTypeDefinitionBytes(const <int>[0x68, 0x01]);

Uint8List _streamStringTypeComponentBytes() =>
    _componentWithSingleTypeDefinitionBytes(const <int>[0x66, 0x01, 0x73]);

Uint8List _streamCharTypeComponentBytes() =>
    _componentWithSingleTypeDefinitionBytes(const <int>[0x66, 0x01, 0x74]);

Uint8List _streamOwnTypeComponentBytes() => _componentWithTypeDefinitionsBytes(
  const <int>[0x3f, 0x7f, 0x00, 0x69, 0x00, 0x66, 0x01, 0x01],
  count: 3,
);

Uint8List _streamBorrowTypeComponentBytes() =>
    _componentWithTypeDefinitionsBytes(const <int>[
      0x3f,
      0x7f,
      0x00,
      0x68,
      0x00,
      0x66,
      0x01,
      0x01,
    ], count: 3);

Uint8List _futureBorrowTypeComponentBytes() =>
    _componentWithTypeDefinitionsBytes(const <int>[
      0x3f,
      0x7f,
      0x00,
      0x68,
      0x00,
      0x65,
      0x01,
      0x01,
    ], count: 3);

Uint8List _functionOwnResultTypeComponentBytes() =>
    _componentWithTypeDefinitionsBytes(const <int>[
      0x3f,
      0x7f,
      0x00,
      0x69,
      0x00,
      0x40,
      0x00,
      0x00,
      0x01,
    ], count: 3);

Uint8List _functionBorrowResultTypeComponentBytes() =>
    _componentWithTypeDefinitionsBytes(const <int>[
      0x3f,
      0x7f,
      0x00,
      0x68,
      0x00,
      0x40,
      0x00,
      0x00,
      0x01,
    ], count: 3);

Uint8List _componentWithSingleTypeDefinitionBytes(List<int> typeBytes) =>
    _componentWithTypeDefinitionsBytes(typeBytes, count: 1);

Uint8List _componentWithTypeDefinitionsBytes(
  List<int> typeBytes, {
  required int count,
}) => Uint8List.fromList(<int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  typeBytes.length + 1,
  count,
  ...typeBytes,
]);

Uint8List _truncatedSectionComponentBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x04,
  0x6e,
]);

Uint8List _emptyCoreModuleBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x01,
  0x00,
  0x00,
  0x00,
]);
