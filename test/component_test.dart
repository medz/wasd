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

    test('reports duplicate component import names', () {
      final errors = WasmComponent.decode(
        _duplicateImportNamesComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(
        errors.single.message,
        contains('import name a conflicts with previous import name a'),
      );

      final folded = WasmComponent.decode(
        _caseFoldedDuplicateImportNamesComponentBytes(),
      ).validate();
      expect(folded, hasLength(1));
      expect(
        folded.single.message,
        contains(
          'import name foo-BAR conflicts with previous import name foo-bar',
        ),
      );

      final versionedDuplicate = WasmComponent.decode(
        _versionedDuplicateImportNamesComponentBytes(),
      ).validate();
      expect(versionedDuplicate, hasLength(1));
      expect(
        versionedDuplicate.single.message,
        contains(
          'import name foo@2.0.0 conflicts with previous import name foo@1.0.0',
        ),
      );

      final structuredDuplicate = WasmComponent.decode(
        _structuredDuplicateImportNamesComponentBytes(),
      ).validate();
      expect(structuredDuplicate, hasLength(1));
      expect(
        structuredDuplicate.single.message,
        contains(
          'import name [method]foo.foo conflicts with previous import name foo',
        ),
      );
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

    test('reports invalid core module type declaration indexes', () {
      final errors = WasmComponent.decode(
        _coreModuleTypeExportBeforeTypeComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(
        errors.single.message,
        contains('Unknown Wasm component core function type index'),
      );
    });

    test('reports duplicate core module type import and export names', () {
      final duplicateImport = WasmComponent.decode(
        _coreModuleTypeDuplicateImportComponentBytes(),
      ).validate();
      expect(duplicateImport, hasLength(1));
      expect(
        duplicateImport.single.message,
        contains('duplicate core module import name :a'),
      );

      final duplicateExport = WasmComponent.decode(
        _coreModuleTypeDuplicateExportComponentBytes(),
      ).validate();
      expect(duplicateExport, hasLength(1));
      expect(
        duplicateExport.single.message,
        contains('core module export name a already defined'),
      );
    });

    test('validates core module type declaration aliases', () {
      expect(
        WasmComponent.decode(_coreModuleTypeAliasComponentBytes()).validate(),
        isEmpty,
      );

      final errors = WasmComponent.decode(
        _coreModuleTypeAliasBeforeTypeComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(
        errors.single.message,
        contains('Unknown Wasm component core type index'),
      );
    });

    test('rejects core module type declarations defining module types', () {
      final errors = WasmComponent.decode(
        _coreModuleTypeNestedModuleTypeComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(
        errors.single.message,
        contains('cannot define core module types'),
      );
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
      expect(component.validate(), isEmpty);
      final child = component.components.last;
      expect(child.aliases, hasLength(1));
      final alias = child.aliases.single;
      expect(alias.sort.kind, WasmComponentSortKind.component);
      expect(alias.target.kind, WasmComponentAliasTargetKind.outer);
      expect(alias.target.componentDepth, 1);
      expect(alias.target.index, 0);
    });

    test('reports invalid outer alias component indexes', () {
      final errors = WasmComponent.decode(
        _outerAliasComponentIndexOutOfRangeComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(errors.single.path, 'component[1].alias[0].target');
      expect(
        errors.single.message,
        contains('Unknown Wasm component outer alias component index'),
      );
    });

    test('validates outer type aliases before nested component imports', () {
      expect(
        WasmComponent.decode(_outerTypeAliasImportComponentBytes()).validate(),
        isEmpty,
      );
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

    test('reports duplicate component type import names', () {
      final errors = WasmComponent.decode(
        _duplicateTypeDeclarationImportNamesComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(
        errors.single.message,
        contains('import name a conflicts with previous import name a'),
      );

      final folded = WasmComponent.decode(
        _caseFoldedDuplicateTypeDeclarationImportNamesComponentBytes(),
      ).validate();
      expect(folded, hasLength(1));
      expect(
        folded.single.message,
        contains(
          'import name foo-BAR conflicts with previous import name foo-bar',
        ),
      );

      final versionedDuplicate = WasmComponent.decode(
        _versionedDuplicateTypeDeclarationImportNamesComponentBytes(),
      ).validate();
      expect(versionedDuplicate, hasLength(1));
      expect(
        versionedDuplicate.single.message,
        contains(
          'import name foo@2.0.0 conflicts with previous import name foo@1.0.0',
        ),
      );

      final structuredDuplicate = WasmComponent.decode(
        _structuredDuplicateTypeDeclarationImportNamesComponentBytes(),
      ).validate();
      expect(structuredDuplicate, hasLength(1));
      expect(
        structuredDuplicate.single.message,
        contains(
          'import name [method]foo.foo conflicts with previous import name foo',
        ),
      );
    });

    test('reports invalid component type declaration indexes', () {
      final errors = WasmComponent.decode(
        _typeDeclarationExportBeforeTypeComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(
        errors.single.message,
        contains('Unknown Wasm component function type index'),
      );
    });

    test('validates local component type declaration value indexes', () {
      expect(
        WasmComponent.decode(
          _typeDeclarationLocalValueTypeComponentBytes(),
        ).validate(),
        isEmpty,
      );
    });

    test('validates resource imports introduced by type declarations', () {
      expect(
        WasmComponent.decode(
          _typeDeclarationResourceImportComponentBytes(),
        ).validate(),
        isEmpty,
      );
    });

    test('validates local core module type declaration indexes', () {
      expect(
        WasmComponent.decode(
          _typeDeclarationLocalCoreModuleImportComponentBytes(),
        ).validate(),
        isEmpty,
      );

      final errors = WasmComponent.decode(
        _typeDeclarationCoreModuleImportBeforeCoreTypeComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(
        errors.single.message,
        contains('Unknown Wasm component core module type index'),
      );
    });

    test('validates local type declaration aliases', () {
      expect(
        WasmComponent.decode(
          _typeDeclarationLocalTypeAliasComponentBytes(),
        ).validate(),
        isEmpty,
      );

      final errors = WasmComponent.decode(
        _typeDeclarationAliasBeforeTypeComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(
        errors.single.message,
        contains('Unknown Wasm component type index'),
      );
    });

    test('validates nested type declaration outer aliases', () {
      expect(
        WasmComponent.decode(
          _typeDeclarationNestedOuterAliasComponentBytes(),
        ).validate(),
        isEmpty,
      );

      final errors = WasmComponent.decode(
        _typeDeclarationOuterAliasDepthOutOfRangeComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(
        errors.single.message,
        contains('Unknown Wasm component type scope'),
      );
    });

    test(
      'validates type declaration aliases to containing component types',
      () {
        expect(
          WasmComponent.decode(
            _typeDeclarationContainingComponentOuterAliasComponentBytes(),
          ).validate(),
          isEmpty,
        );
      },
    );

    test(
      'rejects type declaration resource aliases across component boundaries',
      () {
        final errors = WasmComponent.decode(
          _typeDeclarationOuterResourceAliasComponentBytes(),
        ).validate();

        expect(errors, hasLength(1));
        expect(
          errors.single.message,
          contains('cannot alias resource-containing types'),
        );
      },
    );

    test('rejects unsupported type declaration alias sorts', () {
      final errors = WasmComponent.decode(
        _typeDeclarationFunctionAliasComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(
        errors.single.message,
        contains('Unsupported Wasm component type declaration alias sort'),
      );
    });

    test('validates function type indexes introduced by exports', () {
      expect(
        WasmComponent.decode(
          _typeDeclarationExportIntroducesFunctionTypeComponentBytes(),
        ).validate(),
        isEmpty,
      );

      final foldedDuplicate = WasmComponent.decode(
        _caseFoldedDuplicateTypeDeclarationExportNamesComponentBytes(),
      ).validate();
      expect(foldedDuplicate, hasLength(1));
      expect(
        foldedDuplicate.single.message,
        contains(
          'export name foo-BAR conflicts with previous export name foo-bar',
        ),
      );

      final versionedDuplicate = WasmComponent.decode(
        _versionedDuplicateTypeDeclarationExportNamesComponentBytes(),
      ).validate();
      expect(versionedDuplicate, hasLength(1));
      expect(
        versionedDuplicate.single.message,
        contains(
          'export name foo@2.0.0 conflicts with previous export name foo@1.0.0',
        ),
      );

      final structuredDuplicate = WasmComponent.decode(
        _structuredDuplicateTypeDeclarationExportNamesComponentBytes(),
      ).validate();
      expect(structuredDuplicate, hasLength(1));
      expect(
        structuredDuplicate.single.message,
        contains(
          'export name [method]foo.foo conflicts with previous export name foo',
        ),
      );
    });

    test(
      'validates component and instance type indexes introduced by exports',
      () {
        expect(
          WasmComponent.decode(
            _typeDeclarationExportIntroducesComponentTypeComponentBytes(),
          ).validate(),
          isEmpty,
        );
        expect(
          WasmComponent.decode(
            _typeDeclarationExportIntroducesInstanceTypeComponentBytes(),
          ).validate(),
          isEmpty,
        );
      },
    );

    test('validates equality type indexes introduced by exports', () {
      expect(
        WasmComponent.decode(
          _typeDeclarationExportIntroducesEqualityTypeComponentBytes(),
        ).validate(),
        isEmpty,
      );

      final errors = WasmComponent.decode(
        _typeDeclarationEqualityTypeExportBeforeTypeComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(
        errors.single.message,
        contains('Unknown Wasm component type index'),
      );
    });

    test('validates fresh resource types introduced by exports', () {
      expect(
        WasmComponent.decode(
          _typeDeclarationExportIntroducesResourceTypeComponentBytes(),
        ).validate(),
        isEmpty,
      );
    });

    test('rejects direct resource type declarations in component types', () {
      final errors = WasmComponent.decode(
        _typeDeclarationDirectResourceTypeComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(errors.single.message, contains('cannot define resource types'));
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

    test('reports empty component defined value type bodies', () {
      final invalidTypes = <(Uint8List, String)>[
        (
          _emptyRecordTypeComponentBytes(),
          'record type must have at least one field',
        ),
        (
          _emptyVariantTypeComponentBytes(),
          'variant type must have at least one case',
        ),
        (
          _emptyFlagsTypeComponentBytes(),
          'flags type must have at least one entry',
        ),
        (
          _emptyEnumTypeComponentBytes(),
          'enum type must have at least one variant',
        ),
        (
          _emptyTupleTypeComponentBytes(),
          'tuple type must have at least one type',
        ),
      ];

      for (final (bytes, message) in invalidTypes) {
        final errors = WasmComponent.decode(bytes).validate();
        expect(errors, hasLength(1));
        expect(errors.single.message, contains(message));
      }
    });

    test('reports too many component flags entries', () {
      final errors = WasmComponent.decode(
        _tooManyFlagsTypeComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(errors.single.message, contains('cannot have more than 32 flags'));
    });

    test('reports empty component function parameter names', () {
      final errors = WasmComponent.decode(
        _emptyFunctionParameterNameTypeComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(
        errors.single.message,
        contains('function parameter name cannot be empty'),
      );
    });

    test('reports conflicting component function parameter names', () {
      final errors = WasmComponent.decode(
        _conflictingFunctionParameterNamesTypeComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(
        errors.single.message,
        contains(
          'function parameter name FOO conflicts with previous parameter name foo',
        ),
      );
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

    test('reports invalid component value definition type indexes', () {
      final wrongSort = WasmComponent.decode(
        _valueDefinitionWrongSortTypeIndexComponentBytes(),
      ).validate();
      expect(wrongSort, hasLength(1));
      expect(
        wrongSort.single.message,
        contains('does not refer to a value type'),
      );

      final outOfRange = WasmComponent.decode(
        _valueDefinitionOutOfRangeTypeIndexComponentBytes(),
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
      expect(
        WasmComponent.decode(
          _resourceDestructorFunctionComponentBytes(),
        ).validate(),
        isEmpty,
      );
      final externrefRepresentation = WasmComponent.decode(
        _resourceExternrefRepresentationTypeComponentBytes(),
      ).validate();
      expect(externrefRepresentation, hasLength(1));
      expect(
        externrefRepresentation.single.message,
        contains('resource representation type'),
      );

      final refEqRepresentation = WasmComponent.decode(
        _resourceRefEqRepresentationTypeComponentBytes(),
      );
      final refEqErrors = refEqRepresentation.validate();
      expect(refEqErrors, hasLength(1));
      expect(
        refEqErrors.single.message,
        contains('resource representation type'),
      );
      expect(
        refEqRepresentation
            .typeDefinitions
            .single
            .resource!
            .representationTypeCode,
        0x64,
      );

      final invalidRepresentation = WasmComponent.decode(
        _resourceInvalidRepresentationTypeComponentBytes(),
      ).validate();
      expect(invalidRepresentation, hasLength(1));
      expect(
        invalidRepresentation.single.message,
        contains('resource representation type'),
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

      final invalidDestructor = WasmComponent.decode(
        _resourceDestructorOutOfRangeFunctionComponentBytes(),
      ).validate();
      expect(invalidDestructor, hasLength(1));
      expect(
        invalidDestructor.single.message,
        contains('Unknown Wasm component function index'),
      );

      final invalidCallback = WasmComponent.decode(
        _asyncResourceCallbackOutOfRangeFunctionComponentBytes(),
      ).validate();
      expect(invalidCallback, hasLength(1));
      expect(
        invalidCallback.single.message,
        contains('Unknown Wasm component function index'),
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

    test('validates component export sort indexes in definition order', () {
      expect(WasmComponent.decode(_exportComponentBytes()).validate(), isEmpty);
      expect(
        WasmComponent.decode(_exportFunctionAliasComponentBytes()).validate(),
        isEmpty,
      );
      expect(
        WasmComponent.decode(_exportTypeAliasImportComponentBytes()).validate(),
        isEmpty,
      );

      final beforeDefinition = WasmComponent.decode(
        _exportFunctionBeforeDefinitionComponentBytes(),
      ).validate();
      expect(beforeDefinition, hasLength(1));
      expect(
        beforeDefinition.single.message,
        contains('Unknown Wasm component function index'),
      );

      final valueBeforeDefinition = WasmComponent.decode(
        _exportValueBeforeDefinitionComponentBytes(),
      ).validate();
      expect(valueBeforeDefinition, hasLength(1));
      expect(
        valueBeforeDefinition.single.message,
        contains('Unknown Wasm component value index'),
      );

      final duplicateName = WasmComponent.decode(
        _duplicateExportNamesComponentBytes(),
      ).validate();
      expect(duplicateName, hasLength(1));
      expect(
        duplicateName.single.message,
        contains('export name host-func conflicts with previous export name'),
      );

      final foldedDuplicateName = WasmComponent.decode(
        _caseFoldedDuplicateExportNamesComponentBytes(),
      ).validate();
      expect(foldedDuplicateName, hasLength(1));
      expect(
        foldedDuplicateName.single.message,
        contains(
          'export name foo-BAR conflicts with previous export name foo-bar',
        ),
      );

      final versionedDuplicateName = WasmComponent.decode(
        _versionedDuplicateExportNamesComponentBytes(),
      ).validate();
      expect(versionedDuplicateName, hasLength(1));
      expect(
        versionedDuplicateName.single.message,
        contains(
          'export name foo@2.0.0 conflicts with previous export name foo@1.0.0',
        ),
      );

      final structuredDuplicateName = WasmComponent.decode(
        _structuredDuplicateExportNamesComponentBytes(),
      ).validate();
      expect(structuredDuplicateName, hasLength(1));
      expect(
        structuredDuplicateName.single.message,
        contains(
          'export name [method]foo.foo conflicts with previous export name foo',
        ),
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

    test('reports component value consumption errors', () {
      expect(
        WasmComponent.decode(_valueImportExportComponentBytes()).validate(),
        isEmpty,
      );

      final unconsumed = WasmComponent.decode(
        _valueImportComponentBytes(),
      ).validate();
      expect(unconsumed, hasLength(1));
      expect(unconsumed.single.message, contains('was not consumed'));

      final duplicate = WasmComponent.decode(
        _valueImportDuplicateExportComponentBytes(),
      ).validate();
      expect(duplicate, hasLength(1));
      expect(duplicate.single.message, contains('already consumed'));
    });

    test('validates component instantiation indexes and value arguments', () {
      expect(
        WasmComponent.decode(
          _instantiateValueArgumentComponentBytes(),
        ).validate(),
        isEmpty,
      );

      final beforeDefinition = WasmComponent.decode(
        _instantiateComponentBeforeDefinitionComponentBytes(),
      ).validate();
      expect(beforeDefinition, hasLength(1));
      expect(
        beforeDefinition.single.message,
        contains('Unknown Wasm component component index'),
      );

      final missingCoreArgument = WasmComponent.decode(
        _instantiateMissingCoreArgumentComponentBytes(),
      ).validate();
      expect(missingCoreArgument, hasLength(1));
      expect(
        missingCoreArgument.single.message,
        contains('Unknown Wasm component core memory index'),
      );

      final duplicate = WasmComponent.decode(
        _instantiateDuplicateValueArgumentComponentBytes(),
      ).validate();
      expect(duplicate, hasLength(1));
      expect(duplicate.single.message, contains('already consumed'));

      final duplicateName = WasmComponent.decode(
        _instantiateDuplicateArgumentNameComponentBytes(),
      ).validate();
      expect(duplicateName, hasLength(1));
      expect(
        duplicateName.single.message,
        contains('Duplicate Wasm component instantiation argument name'),
      );

      final duplicateInlineExportName = WasmComponent.decode(
        _inlineInstanceDuplicateExportNameComponentBytes(),
      ).validate();
      expect(duplicateInlineExportName, hasLength(1));
      expect(
        duplicateInlineExportName.single.message,
        contains('Duplicate Wasm component inline export name'),
      );

      final versionedDuplicateInlineExportName = WasmComponent.decode(
        _inlineInstanceVersionedDuplicateExportNameComponentBytes(),
      ).validate();
      expect(versionedDuplicateInlineExportName, hasLength(1));
      expect(
        versionedDuplicateInlineExportName.single.message,
        contains('inline export name "foo@2.0.0" conflicts with "foo@1.0.0"'),
      );

      final structuredDuplicateInlineExportName = WasmComponent.decode(
        _inlineInstanceStructuredDuplicateExportNameComponentBytes(),
      ).validate();
      expect(structuredDuplicateInlineExportName, hasLength(1));
      expect(
        structuredDuplicateInlineExportName.single.message,
        contains('inline export name "[method]foo.foo" conflicts with "foo"'),
      );
    });

    test('validates core instance indexes in definition order', () {
      expect(
        WasmComponent.decode(
          _coreInstanceInstantiateComponentBytes(),
        ).validate(),
        isEmpty,
      );
      expect(
        WasmComponent.decode(_coreInstanceInlineComponentBytes()).validate(),
        isEmpty,
      );
      expect(
        WasmComponent.decode(
          _coreModuleExportAliasInstantiateComponentBytes(),
        ).validate(),
        isEmpty,
      );

      final beforeModule = WasmComponent.decode(
        _coreInstanceBeforeModuleComponentBytes(),
      ).validate();
      expect(beforeModule, hasLength(1));
      expect(
        beforeModule.single.message,
        contains('Unknown Wasm component core module index'),
      );

      final undefinedArgument = WasmComponent.decode(
        _coreInstanceUndefinedArgumentComponentBytes(),
      ).validate();
      expect(undefinedArgument, hasLength(1));
      expect(
        undefinedArgument.single.message,
        contains('Unknown Wasm component core instance index'),
      );

      final undefinedInlineExport = WasmComponent.decode(
        _coreInlineInstanceUndefinedMemoryComponentBytes(),
      ).validate();
      expect(undefinedInlineExport, hasLength(1));
      expect(
        undefinedInlineExport.single.message,
        contains('Unknown Wasm component core memory index'),
      );

      final duplicateArgumentName = WasmComponent.decode(
        _coreInstanceDuplicateArgumentNameComponentBytes(),
      ).validate();
      expect(duplicateArgumentName, hasLength(1));
      expect(
        duplicateArgumentName.single.message,
        contains('Duplicate Wasm component core instantiation argument name'),
      );

      final duplicateInlineExportName = WasmComponent.decode(
        _coreInstanceDuplicateInlineExportNameComponentBytes(),
      ).validate();
      expect(duplicateInlineExportName, hasLength(1));
      expect(
        duplicateInlineExportName.single.message,
        contains('Duplicate Wasm component core inline export name'),
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
      expect(
        WasmComponent.decode(
          _importedResourceCanonicalProgramComponentBytes(),
        ).validate(),
        isEmpty,
      );
      expect(
        WasmComponent.decode(
          _aliasedInstanceResourceCanonicalProgramComponentBytes(),
        ).validate(),
        isEmpty,
      );
      expect(
        WasmComponent.decode(
          _instantiatedComponentResourceAliasCanonicalProgramComponentBytes(),
        ).validate(),
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
      expect(
        wrongSort.any(
          (error) =>
              error.message.contains('does not refer to a function type'),
        ),
        isTrue,
      );

      final outOfRange = WasmComponent.decode(
        _canonicalLiftOutOfRangeTypeIndexComponentBytes(),
      ).validate();
      expect(
        outOfRange.any(
          (error) => error.message.contains(
            'Unknown Wasm component function type index',
          ),
        ),
        isTrue,
      );
    });

    test('reports duplicate and conflicting canonical options', () {
      final conflictingStringEncoding = WasmComponent.decode(
        _canonicalConflictingStringEncodingComponentBytes(),
      ).validate();
      expect(
        conflictingStringEncoding.any(
          (error) => error.message.contains(
            'Conflicting Wasm component canonical string encoding option',
          ),
        ),
        isTrue,
      );

      final duplicateMemory = WasmComponent.decode(
        _canonicalDuplicateMemoryOptionComponentBytes(),
      ).validate();
      expect(
        duplicateMemory.any(
          (error) => error.message.contains(
            'Duplicate Wasm component canonical option',
          ),
        ),
        isTrue,
      );
    });

    test('reports invalid canonical option placements', () {
      final lower = WasmComponent.decode(
        _canonicalLowerWithPostReturnComponentBytes(),
      ).validate();

      expect(
        lower.any(
          (error) => error.message.contains(
            'canon lower cannot use postReturn option',
          ),
        ),
        isTrue,
      );

      final streamRead = WasmComponent.decode(
        _canonicalStreamReadWithAsyncComponentBytes(),
      ).validate();

      expect(
        streamRead.any(
          (error) => error.message.contains(
            'stream or future copy cannot use async option',
          ),
        ),
        isTrue,
      );
    });

    test('validates stream and future dynamic copy options by direction', () {
      final streamReadWithRealloc = WasmComponent.decode(
        _canonicalStreamReadWithReallocComponentBytes(),
      ).validate();
      expect(streamReadWithRealloc, isEmpty);

      final streamReadReallocWithoutMemory = WasmComponent.decode(
        _canonicalStreamReadWithReallocWithoutMemoryComponentBytes(),
      ).validate();
      expect(
        streamReadReallocWithoutMemory.any(
          (error) =>
              error.message.contains('realloc option requires a memory option'),
        ),
        isTrue,
      );

      final streamWriteWithoutRealloc = WasmComponent.decode(
        _canonicalStringStreamWriteWithoutReallocComponentBytes(),
      ).validate();
      expect(streamWriteWithoutRealloc, isEmpty);

      final futureWriteWithoutRealloc = WasmComponent.decode(
        _canonicalStringFutureWriteWithoutReallocComponentBytes(),
      ).validate();
      expect(futureWriteWithoutRealloc, isEmpty);

      final streamReadWithoutRealloc = WasmComponent.decode(
        _canonicalStringStreamReadWithoutReallocComponentBytes(),
      ).validate();
      expect(streamReadWithoutRealloc, hasLength(1));
      expect(
        streamReadWithoutRealloc.single.message,
        contains('requires a realloc option'),
      );

      final futureReadWithoutRealloc = WasmComponent.decode(
        _canonicalStringFutureReadWithoutReallocComponentBytes(),
      ).validate();
      expect(futureReadWithoutRealloc, hasLength(1));
      expect(
        futureReadWithoutRealloc.single.message,
        contains('requires a realloc option'),
      );
    });

    test('reports invalid canonical context indexes', () {
      final errors = WasmComponent.decode(
        _canonicalContextGetOutOfRangeComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(errors.single.message, contains('context index'));
      expect(errors.single.message, contains('less than 2'));
    });

    test('reports missing canonical option requirements', () {
      final errors = WasmComponent.decode(
        _canonicalLowerAsyncWithoutMemoryComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(errors.single.message, contains('requires a memory option'));

      final stream = WasmComponent.decode(
        _canonicalStreamReadWithoutMemoryComponentBytes(),
      ).validate();

      expect(
        stream.any(
          (error) => error.message.contains('requires a memory option'),
        ),
        isTrue,
      );

      final errorContext = WasmComponent.decode(
        _canonicalErrorContextNewWithoutMemoryComponentBytes(),
      ).validate();

      expect(errorContext, hasLength(1));
      expect(errorContext.single.message, contains('requires a memory option'));

      final debugMessage = WasmComponent.decode(
        _canonicalErrorContextDebugMessageWithoutReallocComponentBytes(),
      ).validate();

      expect(debugMessage, hasLength(1));
      expect(
        debugMessage.single.message,
        contains('requires a realloc option'),
      );

      final asyncErrorContext = WasmComponent.decode(
        _canonicalErrorContextNewWithAsyncComponentBytes(),
      ).validate();

      expect(asyncErrorContext, hasLength(1));
      expect(asyncErrorContext.single.message, contains('cannot use async'));

      final taskReturn = WasmComponent.decode(
        _canonicalTaskReturnWithAsyncComponentBytes(),
      ).validate();

      expect(taskReturn, hasLength(1));
      expect(taskReturn.single.message, contains('cannot use async option'));

      final stringTaskReturn = WasmComponent.decode(
        _canonicalTaskReturnStringWithoutMemoryComponentBytes(),
      ).validate();

      expect(stringTaskReturn, hasLength(1));
      expect(
        stringTaskReturn.single.message,
        contains('requires a memory option'),
      );

      final lowerParam = WasmComponent.decode(
        _canonicalLowerStringParamWithoutMemoryComponentBytes(),
      ).validate();

      expect(lowerParam, hasLength(1));
      expect(lowerParam.single.message, contains('requires a memory option'));

      final lowerResult = WasmComponent.decode(
        _canonicalLowerStringResultWithoutReallocComponentBytes(),
      ).validate();

      expect(
        lowerResult.any(
          (error) => error.message.contains('requires a realloc option'),
        ),
        isTrue,
      );

      final liftParam = WasmComponent.decode(
        _canonicalLiftStringParamWithoutReallocComponentBytes(),
      ).validate();

      expect(
        liftParam.any(
          (error) => error.message.contains('requires a realloc option'),
        ),
        isTrue,
      );

      final liftResult = WasmComponent.decode(
        _canonicalLiftStringResultWithoutMemoryComponentBytes(),
      ).validate();

      expect(
        liftResult.any(
          (error) => error.message.contains('requires a memory option'),
        ),
        isTrue,
      );
    });

    test('reports task.return result types containing borrow', () {
      final errors = WasmComponent.decode(
        _canonicalTaskReturnBorrowResultComponentBytes(),
      ).validate();

      expect(errors, hasLength(1));
      expect(errors.single.message, contains('task.return result type'));
      expect(errors.single.message, contains('borrow'));
    });

    test('reports invalid canonical option core indexes', () {
      final errors = WasmComponent.decode(
        _canonicalMemoryOptionOutOfRangeComponentBytes(),
      ).validate();

      expect(
        errors.any(
          (error) => error.message.contains(
            'Unknown Wasm component core memory index',
          ),
        ),
        isTrue,
      );
    });

    test('reports invalid canonical direct core indexes', () {
      final memory = WasmComponent.decode(
        _canonicalWaitableSetWaitMemoryOutOfRangeComponentBytes(),
      ).validate();
      expect(memory, hasLength(1));
      expect(
        memory.single.message,
        contains('Unknown Wasm component core memory index'),
      );

      final table = WasmComponent.decode(
        _canonicalThreadNewIndirectTableOutOfRangeComponentBytes(),
      ).validate();
      expect(
        table.any(
          (error) =>
              error.message.contains('Unknown Wasm component core table index'),
        ),
        isTrue,
      );
    });

    test('reports invalid canonical direct type indexes', () {
      expect(
        WasmComponent.decode(_canonicalStreamNewComponentBytes()).validate(),
        isEmpty,
      );

      final stream = WasmComponent.decode(
        _canonicalStreamNewTypeOutOfRangeComponentBytes(),
      ).validate();
      expect(stream, hasLength(1));
      expect(
        stream.single.message,
        contains('Unknown Wasm component stream type index'),
      );

      final future = WasmComponent.decode(
        _canonicalFutureNewWrongSortTypeComponentBytes(),
      ).validate();
      expect(future, hasLength(1));
      expect(
        future.single.message,
        contains('does not refer to a future type'),
      );
    });

    test('reports invalid component start indexes', () {
      expect(
        WasmComponent.decode(_startNoResultComponentBytes()).validate(),
        isEmpty,
      );

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

      final aliasBeforeInstance = WasmComponent.decode(
        _aliasTargetInstanceDefinedAfterComponentBytes(),
      ).validate();
      expect(aliasBeforeInstance, hasLength(1));
      expect(
        aliasBeforeInstance.single.message,
        contains('Unknown Wasm component instance index'),
      );
    });

    test('validates inline instance export aliases', () {
      final missingName = WasmComponent.decode(
        _exportAliasMissingNameComponentBytes(),
      ).validate();
      expect(missingName, hasLength(1));
      expect(
        missingName.single.message,
        contains('Unknown Wasm component instance export'),
      );

      final wrongSort = WasmComponent.decode(
        _exportAliasWrongSortComponentBytes(),
      ).validate();
      expect(wrongSort, hasLength(1));
      expect(
        wrongSort.single.message,
        contains('does not refer to a value export'),
      );
    });

    test('reports component start signature mismatches', () {
      final argumentCount = WasmComponent.decode(
        _startArgumentCountMismatchComponentBytes(),
      ).validate();
      expect(argumentCount, hasLength(1));
      expect(argumentCount.single.message, contains('start argument count'));

      final argumentType = WasmComponent.decode(
        _startArgumentTypeMismatchComponentBytes(),
      ).validate();
      expect(argumentType, hasLength(1));
      expect(argumentType.single.message, contains('start argument type'));

      final resultCount = WasmComponent.decode(
        _startResultCountMismatchComponentBytes(),
      ).validate();
      expect(resultCount, hasLength(1));
      expect(resultCount.single.message, contains('start result count'));

      final aliasedFunctionArgumentCount = WasmComponent.decode(
        _startAliasedFunctionArgumentCountMismatchComponentBytes(),
      ).validate();
      expect(aliasedFunctionArgumentCount, hasLength(1));
      expect(
        aliasedFunctionArgumentCount.single.message,
        contains('start argument count'),
      );

      final instantiatedFunctionArgumentCount = WasmComponent.decode(
        _startInstantiatedFunctionArgumentCountMismatchComponentBytes(),
      ).validate();
      expect(instantiatedFunctionArgumentCount, hasLength(1));
      expect(
        instantiatedFunctionArgumentCount.single.message,
        contains('start argument count'),
      );

      final aliasedValueArgumentType = WasmComponent.decode(
        _startAliasedValueArgumentTypeMismatchComponentBytes(),
      ).validate();
      expect(aliasedValueArgumentType, hasLength(1));
      expect(
        aliasedValueArgumentType.single.message,
        contains('start argument type'),
      );

      final instantiatedValueArgumentType = WasmComponent.decode(
        _startInstantiatedValueArgumentTypeMismatchComponentBytes(),
      ).validate();
      expect(instantiatedValueArgumentType, hasLength(1));
      expect(
        instantiatedValueArgumentType.single.message,
        contains('start argument type'),
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

    test('reports nested stream and future element types', () {
      final stream = WasmComponent.decode(
        _nestedStreamTypeComponentBytes(),
      ).validate();
      expect(stream, hasLength(1));
      expect(stream.single.message, contains('nested async'));
      expect(stream.single.message, contains('stream element type'));

      final future = WasmComponent.decode(
        _futureStreamTypeComponentBytes(),
      ).validate();
      expect(future, hasLength(1));
      expect(future.single.message, contains('nested async'));
      expect(future.single.message, contains('future element type'));
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

Uint8List _minimalFunctionComponentWithImports(List<List<int>> imports) {
  return _componentBytes([
    _componentFunctionTypeSection(),
    _componentSection(0x0a, [
      ..._varUint32(imports.length),
      for (final import in imports) ...import,
    ]),
  ]);
}

Uint8List _minimalFunctionComponentWithExports(List<List<int>> exports) {
  return _componentBytes([
    _componentFunctionTypeSection(),
    _componentSingleFunctionImportSection('host-func'),
    _componentSection(0x0b, [
      ..._varUint32(exports.length),
      for (final export in exports) ...export,
    ]),
  ]);
}

Uint8List _minimalFunctionComponentWithInlineExports(List<List<int>> exports) {
  return _componentBytes([
    _componentFunctionTypeSection(),
    _componentSingleFunctionImportSection('f'),
    _componentSection(0x05, [
      0x01,
      0x01,
      ..._varUint32(exports.length),
      for (final export in exports) ...export,
    ]),
  ]);
}

Uint8List _componentTypeWithDeclarations(List<List<int>> declarations) {
  return _componentBytes([
    _componentSection(0x07, [
      0x01,
      0x41,
      ..._varUint32(declarations.length),
      for (final declaration in declarations) ...declaration,
    ]),
  ]);
}

Uint8List _componentInstanceTypeWithFunctionExportDeclarations(
  List<List<int>> exports,
) {
  return _componentBytes([
    _componentSection(0x07, [
      0x01,
      0x42,
      ..._varUint32(exports.length + 1),
      0x01,
      0x40,
      0x00,
      0x01,
      0x00,
      for (final export in exports) ...export,
    ]),
  ]);
}

Uint8List _componentBytes(List<List<int>> sections) {
  return Uint8List.fromList([
    0x00,
    0x61,
    0x73,
    0x6d,
    0x0d,
    0x00,
    0x01,
    0x00,
    for (final section in sections) ...section,
  ]);
}

List<int> _componentFunctionTypeSection() {
  return _componentSection(0x07, [0x01, 0x40, 0x00, 0x01, 0x00]);
}

List<int> _componentSingleFunctionImportSection(String name) {
  return _componentSection(0x0a, [0x01, ..._componentFunctionImport(name)]);
}

List<int> _componentFunctionImport(String name, {String? versionSuffix}) {
  return [..._componentExternNameBytes(name, versionSuffix), 0x01, 0x00];
}

List<int> _componentFunctionExport(String name, {String? versionSuffix}) {
  return [..._componentExternNameBytes(name, versionSuffix), 0x01, 0x00, 0x00];
}

List<int> _componentInlineFunctionExport(String name, {String? versionSuffix}) {
  return [..._componentExternNameBytes(name, versionSuffix), 0x01, 0x00];
}

List<int> _componentTypeValueImportDeclaration(
  String name, {
  String? versionSuffix,
}) {
  return [0x03, ..._componentExternNameBytes(name, versionSuffix), 0x02, 0x73];
}

List<int> _componentTypeFunctionExportDeclaration(
  String name,
  int functionTypeIndex, {
  String? versionSuffix,
}) {
  return [
    0x04,
    ..._componentExternNameBytes(name, versionSuffix),
    0x01,
    ..._varUint32(functionTypeIndex),
  ];
}

List<int> _componentSection(int id, List<int> payload) {
  return [id, ..._varUint32(payload.length), ...payload];
}

List<int> _componentExternNameBytes(String name, String? versionSuffix) {
  if (versionSuffix == null) {
    return [0x00, ..._componentNameBytes(name)];
  }
  return [
    0x01,
    ..._componentNameBytes(name),
    ..._componentNameBytes(versionSuffix),
  ];
}

List<int> _componentNameBytes(String name) {
  return [..._varUint32(name.length), ...name.codeUnits];
}

List<int> _varUint32(int value) {
  final bytes = <int>[];
  var remaining = value;
  do {
    var byte = remaining & 0x7f;
    remaining >>= 7;
    if (remaining != 0) {
      byte |= 0x80;
    }
    bytes.add(byte);
  } while (remaining != 0);
  return bytes;
}

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

Uint8List _duplicateImportNamesComponentBytes() =>
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
      0x0b,
      0x02,
      0x00,
      0x01,
      0x61,
      0x01,
      0x00,
      0x00,
      0x01,
      0x61,
      0x01,
      0x00,
    ]);

Uint8List _caseFoldedDuplicateImportNamesComponentBytes() =>
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
      0x17,
      0x02,
      0x00,
      0x07,
      0x66,
      0x6f,
      0x6f,
      0x2d,
      0x62,
      0x61,
      0x72,
      0x01,
      0x00,
      0x00,
      0x07,
      0x66,
      0x6f,
      0x6f,
      0x2d,
      0x42,
      0x41,
      0x52,
      0x01,
      0x00,
    ]);

Uint8List _versionedDuplicateImportNamesComponentBytes() =>
    _minimalFunctionComponentWithImports([
      _componentFunctionImport('foo', versionSuffix: '1.0.0'),
      _componentFunctionImport('foo', versionSuffix: '2.0.0'),
    ]);

Uint8List _structuredDuplicateImportNamesComponentBytes() =>
    _minimalFunctionComponentWithImports([
      _componentFunctionImport('foo'),
      _componentFunctionImport('[method]foo.foo'),
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

Uint8List _valueImportExportComponentBytes() => Uint8List.fromList(const <int>[
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
  0x0b,
  0x07,
  0x01,
  0x00,
  0x01,
  0x76,
  0x02,
  0x00,
  0x00,
]);

Uint8List _instantiateComponentBeforeDefinitionComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x05,
      0x04,
      0x01,
      0x00,
      0x00,
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
    ]);

Uint8List _instantiateValueArgumentComponentBytes() =>
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
      0x05,
      0x0a,
      0x01,
      0x00,
      0x00,
      0x01,
      0x03,
      0x64,
      0x65,
      0x70,
      0x02,
      0x00,
    ]);

Uint8List _instantiateDuplicateValueArgumentComponentBytes() =>
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
      0x05,
      0x10,
      0x01,
      0x00,
      0x00,
      0x02,
      0x03,
      0x64,
      0x65,
      0x70,
      0x02,
      0x00,
      0x03,
      0x64,
      0x75,
      0x70,
      0x02,
      0x00,
    ]);

Uint8List _instantiateDuplicateArgumentNameComponentBytes() =>
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
      0x08,
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x05,
      0x12,
      0x02,
      0x01,
      0x00,
      0x00,
      0x00,
      0x02,
      0x03,
      0x64,
      0x65,
      0x70,
      0x05,
      0x00,
      0x03,
      0x64,
      0x65,
      0x70,
      0x05,
      0x00,
    ]);

Uint8List _valueImportDuplicateExportComponentBytes() =>
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
      0x0b,
      0x0d,
      0x02,
      0x00,
      0x01,
      0x76,
      0x02,
      0x00,
      0x00,
      0x00,
      0x01,
      0x77,
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

Uint8List _duplicateExportNamesComponentBytes() =>
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
      0x1d,
      0x02,
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

Uint8List _caseFoldedDuplicateExportNamesComponentBytes() =>
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
      0x19,
      0x02,
      0x00,
      0x07,
      0x66,
      0x6f,
      0x6f,
      0x2d,
      0x62,
      0x61,
      0x72,
      0x01,
      0x00,
      0x00,
      0x00,
      0x07,
      0x66,
      0x6f,
      0x6f,
      0x2d,
      0x42,
      0x41,
      0x52,
      0x01,
      0x00,
      0x00,
    ]);

Uint8List _versionedDuplicateExportNamesComponentBytes() =>
    _minimalFunctionComponentWithExports([
      _componentFunctionExport('foo', versionSuffix: '1.0.0'),
      _componentFunctionExport('foo', versionSuffix: '2.0.0'),
    ]);

Uint8List _structuredDuplicateExportNamesComponentBytes() =>
    _minimalFunctionComponentWithExports([
      _componentFunctionExport('foo'),
      _componentFunctionExport('[method]foo.foo'),
    ]);

Uint8List _exportFunctionAliasComponentBytes() =>
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
      0x0d,
      0x02,
      0x00,
      0x01,
      0x61,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x62,
      0x01,
      0x01,
      0x00,
    ]);

Uint8List _exportTypeAliasImportComponentBytes() =>
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
      0x0b,
      0x07,
      0x01,
      0x00,
      0x01,
      0x74,
      0x03,
      0x00,
      0x00,
      0x0a,
      0x06,
      0x01,
      0x00,
      0x01,
      0x66,
      0x01,
      0x01,
    ]);

Uint8List _exportFunctionBeforeDefinitionComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
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
    ]);

Uint8List _exportValueBeforeDefinitionComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x0b,
      0x07,
      0x01,
      0x00,
      0x01,
      0x76,
      0x02,
      0x00,
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

Uint8List _coreModuleTypeExportBeforeTypeComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x03,
      0x0e,
      0x01,
      0x50,
      0x02,
      0x03,
      0x03,
      0x72,
      0x75,
      0x6e,
      0x00,
      0x00,
      0x01,
      0x60,
      0x00,
      0x00,
    ]);

Uint8List _coreModuleTypeDuplicateImportComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x03,
      0x13,
      0x01,
      0x50,
      0x03,
      0x01,
      0x60,
      0x00,
      0x00,
      0x00,
      0x00,
      0x01,
      0x61,
      0x00,
      0x00,
      0x00,
      0x00,
      0x01,
      0x61,
      0x00,
      0x00,
    ]);

Uint8List _coreModuleTypeDuplicateExportComponentBytes() =>
    Uint8List.fromList(const <int>[
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
      0x01,
      0x50,
      0x03,
      0x01,
      0x60,
      0x00,
      0x00,
      0x03,
      0x01,
      0x61,
      0x00,
      0x00,
      0x03,
      0x01,
      0x61,
      0x00,
      0x00,
    ]);

Uint8List _coreModuleTypeAliasComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x03,
      0x13,
      0x01,
      0x50,
      0x03,
      0x01,
      0x60,
      0x00,
      0x00,
      0x02,
      0x10,
      0x01,
      0x00,
      0x00,
      0x03,
      0x03,
      0x72,
      0x75,
      0x6e,
      0x00,
      0x01,
    ]);

Uint8List _coreModuleTypeAliasBeforeTypeComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x03,
      0x08,
      0x01,
      0x50,
      0x01,
      0x02,
      0x10,
      0x01,
      0x00,
      0x00,
    ]);

Uint8List _coreModuleTypeNestedModuleTypeComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x03,
      0x06,
      0x01,
      0x50,
      0x01,
      0x01,
      0x50,
      0x00,
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

Uint8List _coreInstanceDuplicateArgumentNameComponentBytes() =>
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
      0x08,
      0x00,
      0x61,
      0x73,
      0x6d,
      0x01,
      0x00,
      0x00,
      0x00,
      0x02,
      0x12,
      0x02,
      0x01,
      0x00,
      0x00,
      0x00,
      0x02,
      0x03,
      0x64,
      0x65,
      0x70,
      0x12,
      0x00,
      0x03,
      0x64,
      0x65,
      0x70,
      0x12,
      0x00,
    ]);

Uint8List _coreInstanceDuplicateInlineExportNameComponentBytes() =>
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
      0x08,
      0x00,
      0x61,
      0x73,
      0x6d,
      0x01,
      0x00,
      0x00,
      0x00,
      0x02,
      0x0b,
      0x01,
      0x01,
      0x02,
      0x01,
      0x6d,
      0x11,
      0x00,
      0x01,
      0x6d,
      0x11,
      0x00,
    ]);

Uint8List _coreModuleExportAliasInstantiateComponentBytes() =>
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
      0x0b,
      0x08,
      0x01,
      0x00,
      0x01,
      0x6d,
      0x00,
      0x11,
      0x00,
      0x00,
      0x02,
      0x04,
      0x01,
      0x00,
      0x01,
      0x00,
    ]);

Uint8List _coreInstanceBeforeModuleComponentBytes() =>
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
      0x04,
      0x01,
      0x00,
      0x00,
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
    ]);

Uint8List _coreInstanceUndefinedArgumentComponentBytes() =>
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

Uint8List _coreInlineInstanceUndefinedMemoryComponentBytes() =>
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

Uint8List _instantiateMissingCoreArgumentComponentBytes() =>
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
      0x08,
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x05,
      0x0b,
      0x01,
      0x00,
      0x00,
      0x01,
      0x03,
      0x64,
      0x65,
      0x70,
      0x00,
      0x02,
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

Uint8List _inlineInstanceDuplicateExportNameComponentBytes() =>
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
      0x00,
      0x01,
      0x66,
      0x01,
      0x00,
      0x05,
      0x0d,
      0x01,
      0x01,
      0x02,
      0x00,
      0x01,
      0x66,
      0x01,
      0x00,
      0x00,
      0x01,
      0x66,
      0x01,
      0x00,
    ]);

Uint8List _inlineInstanceVersionedDuplicateExportNameComponentBytes() =>
    _minimalFunctionComponentWithInlineExports([
      _componentInlineFunctionExport('foo', versionSuffix: '1.0.0'),
      _componentInlineFunctionExport('foo', versionSuffix: '2.0.0'),
    ]);

Uint8List _inlineInstanceStructuredDuplicateExportNameComponentBytes() =>
    _minimalFunctionComponentWithInlineExports([
      _componentInlineFunctionExport('foo'),
      _componentInlineFunctionExport('[method]foo.foo'),
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

Uint8List _exportAliasMissingNameComponentBytes() =>
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
      0x67,
    ]);

Uint8List _exportAliasWrongSortComponentBytes() =>
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
      0x02,
      0x00,
      0x00,
      0x01,
      0x66,
    ]);

Uint8List _aliasTargetInstanceDefinedAfterComponentBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
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

Uint8List _outerAliasComponentIndexOutOfRangeComponentBytes() =>
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
      0x01,
    ]);

Uint8List _outerTypeAliasImportComponentBytes() =>
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
      0x04,
      0x17,
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
      0x03,
      0x02,
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

Uint8List _importedResourceCanonicalProgramComponentBytes() =>
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
      0x06,
      0x01,
      0x00,
      0x01,
      0x72,
      0x03,
      0x01,
      0x08,
      0x07,
      0x03,
      0x02,
      0x00,
      0x04,
      0x00,
      0x03,
      0x00,
    ]);

Uint8List _aliasedInstanceResourceCanonicalProgramComponentBytes() =>
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
      0x05,
      0x08,
      0x01,
      0x01,
      0x01,
      0x00,
      0x01,
      0x72,
      0x03,
      0x00,
      0x06,
      0x06,
      0x01,
      0x03,
      0x00,
      0x00,
      0x01,
      0x72,
      0x08,
      0x07,
      0x03,
      0x02,
      0x01,
      0x04,
      0x01,
      0x03,
      0x01,
    ]);

Uint8List _instantiatedComponentResourceAliasCanonicalProgramComponentBytes() =>
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
      0x17,
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
      0x0b,
      0x07,
      0x01,
      0x00,
      0x01,
      0x72,
      0x03,
      0x00,
      0x00,
      0x05,
      0x04,
      0x01,
      0x00,
      0x00,
      0x00,
      0x06,
      0x06,
      0x01,
      0x03,
      0x00,
      0x00,
      0x01,
      0x72,
      0x08,
      0x07,
      0x03,
      0x02,
      0x00,
      0x04,
      0x00,
      0x03,
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

Uint8List _canonicalLowerWithPostReturnComponentBytes() =>
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
      0x01,
      0x05,
      0x00,
    ]);

Uint8List _canonicalStreamReadWithAsyncComponentBytes() =>
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
      0x03,
      0x01,
      0x66,
      0x00,
      0x08,
      0x05,
      0x01,
      0x0f,
      0x00,
      0x01,
      0x06,
    ]);

Uint8List _canonicalMemoryOptionOutOfRangeComponentBytes() =>
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
      0x01,
      0x03,
      0x00,
    ]);

Uint8List _canonicalLowerAsyncWithoutMemoryComponentBytes() =>
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
      0x00,
      0x01,
      0x66,
      0x01,
      0x00,
      0x08,
      0x06,
      0x01,
      0x01,
      0x00,
      0x00,
      0x01,
      0x06,
    ]);

Uint8List _canonicalErrorContextNewWithoutMemoryComponentBytes() =>
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
      0x1c,
      0x00,
    ]);

Uint8List _canonicalErrorContextDebugMessageWithoutReallocComponentBytes() =>
    Uint8List.fromList(<int>[
      ..._coreExportAliasComponentBytes(),
      0x08,
      0x05,
      0x01,
      0x1d,
      0x01,
      0x03,
      0x00,
    ]);

Uint8List _canonicalErrorContextNewWithAsyncComponentBytes() =>
    Uint8List.fromList(<int>[
      ..._coreExportAliasComponentBytes(),
      0x08,
      0x06,
      0x01,
      0x1c,
      0x02,
      0x03,
      0x00,
      0x06,
    ]);

Uint8List _canonicalTaskReturnWithAsyncComponentBytes() =>
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
      0x09,
      0x01,
      0x00,
      0x01,
      0x06,
    ]);

Uint8List _canonicalContextGetOutOfRangeComponentBytes() =>
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
      0x04,
      0x01,
      0x0a,
      0x7f,
      0x02,
    ]);

Uint8List _canonicalTaskReturnStringWithoutMemoryComponentBytes() =>
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
      0x73,
      0x00,
    ]);

Uint8List _canonicalTaskReturnBorrowResultComponentBytes() =>
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
      0x06,
      0x02,
      0x3f,
      0x7f,
      0x00,
      0x68,
      0x00,
      0x08,
      0x06,
      0x01,
      0x09,
      0x00,
      0x01,
      0x01,
      0x00,
    ]);

Uint8List _canonicalLowerStringParamWithoutMemoryComponentBytes() =>
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
      0x01,
      0x40,
      0x01,
      0x01,
      0x78,
      0x73,
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
      0x08,
      0x05,
      0x01,
      0x01,
      0x00,
      0x00,
      0x00,
    ]);

Uint8List _canonicalLowerStringResultWithoutReallocComponentBytes() =>
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
      0x05,
      0x01,
      0x01,
      0x00,
      0x00,
      0x00,
    ]);

Uint8List _canonicalLiftStringParamWithoutReallocComponentBytes() =>
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
      0x01,
      0x40,
      0x01,
      0x01,
      0x78,
      0x73,
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

Uint8List _canonicalLiftStringResultWithoutMemoryComponentBytes() =>
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
      0x08,
      0x06,
      0x01,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
    ]);

Uint8List _canonicalWaitableSetWaitMemoryOutOfRangeComponentBytes() =>
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
      0x04,
      0x01,
      0x20,
      0x00,
      0x00,
    ]);

Uint8List _canonicalThreadNewIndirectTableOutOfRangeComponentBytes() =>
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
      0x04,
      0x01,
      0x27,
      0x00,
      0x00,
    ]);

Uint8List _canonicalStreamNewComponentBytes() => Uint8List.fromList(const <int>[
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
  0x66,
  0x01,
  0x73,
  0x08,
  0x03,
  0x01,
  0x0e,
  0x00,
]);

Uint8List _canonicalStreamReadWithoutMemoryComponentBytes() =>
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
      0x66,
      0x01,
      0x73,
      0x08,
      0x04,
      0x01,
      0x0f,
      0x00,
      0x00,
    ]);

Uint8List _canonicalStreamReadWithReallocComponentBytes() =>
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
      0x37,
      0x00,
      0x61,
      0x73,
      0x6d,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x09,
      0x01,
      0x60,
      0x04,
      0x7f,
      0x7f,
      0x7f,
      0x7f,
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
      0x11,
      0x02,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x02,
      0x00,
      0x07,
      0x72,
      0x65,
      0x61,
      0x6c,
      0x6c,
      0x6f,
      0x63,
      0x00,
      0x00,
      0x0a,
      0x06,
      0x01,
      0x04,
      0x00,
      0x41,
      0x00,
      0x0b,
      0x02,
      0x04,
      0x01,
      0x00,
      0x00,
      0x00,
      0x06,
      0x15,
      0x02,
      0x00,
      0x02,
      0x01,
      0x00,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x00,
      0x00,
      0x01,
      0x00,
      0x07,
      0x72,
      0x65,
      0x61,
      0x6c,
      0x6c,
      0x6f,
      0x63,
      0x07,
      0x04,
      0x01,
      0x66,
      0x01,
      0x73,
      0x08,
      0x08,
      0x01,
      0x0f,
      0x00,
      0x02,
      0x03,
      0x00,
      0x04,
      0x00,
    ]);

Uint8List _canonicalStreamReadWithReallocWithoutMemoryComponentBytes() =>
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
      0x66,
      0x01,
      0x73,
      0x08,
      0x06,
      0x01,
      0x0f,
      0x00,
      0x01,
      0x04,
      0x00,
    ]);

Uint8List _canonicalStringStreamReadWithoutReallocComponentBytes() =>
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
      0x07,
      0x04,
      0x01,
      0x66,
      0x01,
      0x73,
      0x08,
      0x06,
      0x01,
      0x0f,
      0x00,
      0x01,
      0x03,
      0x00,
    ]);

Uint8List _canonicalStringStreamWriteWithoutReallocComponentBytes() =>
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
      0x07,
      0x04,
      0x01,
      0x66,
      0x01,
      0x73,
      0x08,
      0x06,
      0x01,
      0x10,
      0x00,
      0x01,
      0x03,
      0x00,
    ]);

Uint8List _canonicalStringFutureReadWithoutReallocComponentBytes() =>
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
      0x07,
      0x04,
      0x01,
      0x65,
      0x01,
      0x73,
      0x08,
      0x06,
      0x01,
      0x16,
      0x00,
      0x01,
      0x03,
      0x00,
    ]);

Uint8List _canonicalStringFutureWriteWithoutReallocComponentBytes() =>
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
      0x07,
      0x04,
      0x01,
      0x65,
      0x01,
      0x73,
      0x08,
      0x06,
      0x01,
      0x17,
      0x00,
      0x01,
      0x03,
      0x00,
    ]);

Uint8List _canonicalStreamNewTypeOutOfRangeComponentBytes() =>
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
      0x0e,
      0x00,
    ]);

Uint8List _canonicalFutureNewWrongSortTypeComponentBytes() =>
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
      0x08,
      0x03,
      0x01,
      0x15,
      0x00,
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

Uint8List _duplicateTypeDeclarationImportNamesComponentBytes() =>
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
      0x0f,
      0x01,
      0x41,
      0x02,
      0x03,
      0x00,
      0x01,
      0x61,
      0x02,
      0x73,
      0x03,
      0x00,
      0x01,
      0x61,
      0x02,
      0x73,
    ]);

Uint8List _caseFoldedDuplicateTypeDeclarationImportNamesComponentBytes() =>
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
      0x1b,
      0x01,
      0x41,
      0x02,
      0x03,
      0x00,
      0x07,
      0x66,
      0x6f,
      0x6f,
      0x2d,
      0x62,
      0x61,
      0x72,
      0x02,
      0x73,
      0x03,
      0x00,
      0x07,
      0x66,
      0x6f,
      0x6f,
      0x2d,
      0x42,
      0x41,
      0x52,
      0x02,
      0x73,
    ]);

Uint8List _versionedDuplicateTypeDeclarationImportNamesComponentBytes() =>
    _componentTypeWithDeclarations([
      _componentTypeValueImportDeclaration('foo', versionSuffix: '1.0.0'),
      _componentTypeValueImportDeclaration('foo', versionSuffix: '2.0.0'),
    ]);

Uint8List _structuredDuplicateTypeDeclarationImportNamesComponentBytes() =>
    _componentTypeWithDeclarations([
      _componentTypeValueImportDeclaration('foo'),
      _componentTypeValueImportDeclaration('[method]foo.foo'),
    ]);

Uint8List _typeDeclarationExportBeforeTypeComponentBytes() =>
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
      0x0e,
      0x01,
      0x42,
      0x02,
      0x04,
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
    ]);

Uint8List _typeDeclarationLocalValueTypeComponentBytes() =>
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
      0x0a,
      0x01,
      0x42,
      0x02,
      0x01,
      0x73,
      0x01,
      0x40,
      0x00,
      0x00,
      0x00,
    ]);

Uint8List _typeDeclarationResourceImportComponentBytes() =>
    _componentWithTypeDefinitionsBytes(const <int>[
      0x41,
      0x02,
      0x03,
      0x00,
      0x01,
      0x72,
      0x03,
      0x01,
      0x01,
      0x68,
      0x00,
    ], count: 1);

Uint8List _typeDeclarationLocalCoreModuleImportComponentBytes() =>
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
      0x0d,
      0x01,
      0x41,
      0x02,
      0x00,
      0x50,
      0x00,
      0x03,
      0x00,
      0x01,
      0x6d,
      0x00,
      0x11,
      0x00,
    ]);

Uint8List _typeDeclarationCoreModuleImportBeforeCoreTypeComponentBytes() =>
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
      0x0a,
      0x01,
      0x41,
      0x01,
      0x03,
      0x00,
      0x01,
      0x6d,
      0x00,
      0x11,
      0x00,
    ]);

Uint8List _typeDeclarationLocalTypeAliasComponentBytes() =>
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
      0x13,
      0x01,
      0x42,
      0x03,
      0x01,
      0x40,
      0x00,
      0x01,
      0x00,
      0x02,
      0x03,
      0x02,
      0x00,
      0x00,
      0x04,
      0x00,
      0x01,
      0x61,
      0x01,
      0x01,
    ]);

Uint8List _typeDeclarationAliasBeforeTypeComponentBytes() =>
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
      0x01,
      0x42,
      0x01,
      0x02,
      0x03,
      0x02,
      0x00,
      0x00,
    ]);

Uint8List _typeDeclarationNestedOuterAliasComponentBytes() =>
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
      0x16,
      0x01,
      0x42,
      0x02,
      0x01,
      0x40,
      0x00,
      0x01,
      0x00,
      0x01,
      0x42,
      0x02,
      0x02,
      0x03,
      0x02,
      0x01,
      0x00,
      0x04,
      0x00,
      0x01,
      0x61,
      0x01,
      0x00,
    ]);

Uint8List _typeDeclarationOuterAliasDepthOutOfRangeComponentBytes() =>
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
      0x0b,
      0x01,
      0x42,
      0x01,
      0x01,
      0x42,
      0x01,
      0x02,
      0x03,
      0x02,
      0x03,
      0x00,
    ]);

Uint8List _typeDeclarationContainingComponentOuterAliasComponentBytes() =>
    _componentWithTypeDefinitionsBytes(const <int>[
      0x73,
      0x42,
      0x01,
      0x02,
      0x03,
      0x02,
      0x01,
      0x00,
    ], count: 2);

Uint8List _typeDeclarationOuterResourceAliasComponentBytes() =>
    _componentWithTypeDefinitionsBytes(const <int>[
      0x3f,
      0x7f,
      0x00,
      0x42,
      0x01,
      0x02,
      0x03,
      0x02,
      0x01,
      0x00,
    ], count: 2);

Uint8List _typeDeclarationFunctionAliasComponentBytes() =>
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
      0x01,
      0x42,
      0x01,
      0x02,
      0x01,
      0x02,
      0x00,
      0x00,
    ]);

Uint8List _typeDeclarationExportIntroducesFunctionTypeComponentBytes() =>
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
      0x14,
      0x01,
      0x42,
      0x03,
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
      0x04,
      0x00,
      0x01,
      0x62,
      0x01,
      0x01,
    ]);

Uint8List _caseFoldedDuplicateTypeDeclarationExportNamesComponentBytes() =>
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
      0x20,
      0x01,
      0x42,
      0x03,
      0x01,
      0x40,
      0x00,
      0x01,
      0x00,
      0x04,
      0x00,
      0x07,
      0x66,
      0x6f,
      0x6f,
      0x2d,
      0x62,
      0x61,
      0x72,
      0x01,
      0x00,
      0x04,
      0x00,
      0x07,
      0x66,
      0x6f,
      0x6f,
      0x2d,
      0x42,
      0x41,
      0x52,
      0x01,
      0x01,
    ]);

Uint8List _versionedDuplicateTypeDeclarationExportNamesComponentBytes() =>
    _componentInstanceTypeWithFunctionExportDeclarations([
      _componentTypeFunctionExportDeclaration('foo', 0, versionSuffix: '1.0.0'),
      _componentTypeFunctionExportDeclaration('foo', 1, versionSuffix: '2.0.0'),
    ]);

Uint8List _structuredDuplicateTypeDeclarationExportNamesComponentBytes() =>
    _componentInstanceTypeWithFunctionExportDeclarations([
      _componentTypeFunctionExportDeclaration('foo', 0),
      _componentTypeFunctionExportDeclaration('[method]foo.foo', 1),
    ]);

Uint8List _typeDeclarationExportIntroducesComponentTypeComponentBytes() =>
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
      0x12,
      0x01,
      0x42,
      0x03,
      0x01,
      0x41,
      0x00,
      0x04,
      0x00,
      0x01,
      0x61,
      0x04,
      0x00,
      0x04,
      0x00,
      0x01,
      0x62,
      0x04,
      0x01,
    ]);

Uint8List _typeDeclarationExportIntroducesInstanceTypeComponentBytes() =>
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
      0x12,
      0x01,
      0x42,
      0x03,
      0x01,
      0x42,
      0x00,
      0x04,
      0x00,
      0x01,
      0x61,
      0x05,
      0x00,
      0x04,
      0x00,
      0x01,
      0x62,
      0x05,
      0x01,
    ]);

Uint8List _typeDeclarationExportIntroducesEqualityTypeComponentBytes() =>
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
      0x15,
      0x01,
      0x42,
      0x03,
      0x01,
      0x40,
      0x00,
      0x01,
      0x00,
      0x04,
      0x00,
      0x01,
      0x74,
      0x03,
      0x00,
      0x00,
      0x04,
      0x00,
      0x01,
      0x66,
      0x01,
      0x01,
    ]);

Uint8List _typeDeclarationEqualityTypeExportBeforeTypeComponentBytes() =>
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
      0x0a,
      0x01,
      0x42,
      0x01,
      0x04,
      0x00,
      0x01,
      0x74,
      0x03,
      0x00,
      0x00,
    ]);

Uint8List _typeDeclarationExportIntroducesResourceTypeComponentBytes() =>
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
      0x0c,
      0x01,
      0x42,
      0x02,
      0x04,
      0x00,
      0x01,
      0x72,
      0x03,
      0x01,
      0x01,
      0x69,
      0x00,
    ]);

Uint8List _typeDeclarationDirectResourceTypeComponentBytes() =>
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
      0x07,
      0x01,
      0x42,
      0x01,
      0x01,
      0x3f,
      0x7f,
      0x00,
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

Uint8List _startNoResultComponentBytes() => Uint8List.fromList(const <int>[
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
  0x09,
  0x03,
  0x00,
  0x00,
  0x00,
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

Uint8List _startAliasedFunctionArgumentCountMismatchComponentBytes() =>
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
      0x01,
      0x40,
      0x01,
      0x01,
      0x78,
      0x7f,
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
      0x09,
      0x03,
      0x01,
      0x00,
      0x00,
    ]);

Uint8List _startInstantiatedFunctionArgumentCountMismatchComponentBytes() =>
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
      0x23,
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
      0x01,
      0x40,
      0x01,
      0x01,
      0x78,
      0x7f,
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
      0x0b,
      0x07,
      0x01,
      0x00,
      0x01,
      0x66,
      0x01,
      0x00,
      0x00,
      0x05,
      0x04,
      0x01,
      0x00,
      0x00,
      0x00,
      0x06,
      0x06,
      0x01,
      0x01,
      0x00,
      0x00,
      0x01,
      0x66,
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
      0x08,
      0x01,
      0x40,
      0x01,
      0x01,
      0x78,
      0x7f,
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
      0x08,
      0x01,
      0x40,
      0x01,
      0x01,
      0x78,
      0x7f,
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

Uint8List _startArgumentCountMismatchComponentBytes() =>
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
      0x01,
      0x40,
      0x01,
      0x01,
      0x78,
      0x79,
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
      0x09,
      0x03,
      0x00,
      0x00,
      0x00,
    ]);

Uint8List _startArgumentTypeMismatchComponentBytes() =>
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
      0x01,
      0x40,
      0x01,
      0x01,
      0x78,
      0x79,
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
      0x0a,
      0x06,
      0x01,
      0x00,
      0x01,
      0x76,
      0x02,
      0x73,
      0x09,
      0x04,
      0x00,
      0x01,
      0x00,
      0x00,
    ]);

Uint8List _startAliasedValueArgumentTypeMismatchComponentBytes() =>
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
      0x01,
      0x40,
      0x01,
      0x01,
      0x78,
      0x79,
      0x01,
      0x00,
      0x0a,
      0x0b,
      0x02,
      0x00,
      0x01,
      0x66,
      0x01,
      0x00,
      0x00,
      0x01,
      0x76,
      0x02,
      0x73,
      0x05,
      0x08,
      0x01,
      0x01,
      0x01,
      0x00,
      0x01,
      0x76,
      0x02,
      0x00,
      0x06,
      0x06,
      0x01,
      0x02,
      0x00,
      0x00,
      0x01,
      0x76,
      0x09,
      0x04,
      0x00,
      0x01,
      0x01,
      0x00,
    ]);

Uint8List _startInstantiatedValueArgumentTypeMismatchComponentBytes() =>
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
      0x01,
      0x40,
      0x01,
      0x01,
      0x78,
      0x79,
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
      0x04,
      0x19,
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x0a,
      0x06,
      0x01,
      0x00,
      0x01,
      0x76,
      0x02,
      0x73,
      0x0b,
      0x07,
      0x01,
      0x00,
      0x01,
      0x76,
      0x02,
      0x00,
      0x00,
      0x05,
      0x04,
      0x01,
      0x00,
      0x00,
      0x00,
      0x06,
      0x06,
      0x01,
      0x02,
      0x00,
      0x00,
      0x01,
      0x76,
      0x09,
      0x04,
      0x00,
      0x01,
      0x00,
      0x00,
    ]);

Uint8List _startResultCountMismatchComponentBytes() =>
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

Uint8List _valueDefinitionWrongSortTypeIndexComponentBytes() =>
    _componentBytes([
      _componentFunctionTypeSection(),
      _componentSection(0x0c, const <int>[0x01, 0x00, 0x00]),
    ]);

Uint8List _valueDefinitionOutOfRangeTypeIndexComponentBytes() =>
    _componentBytes([
      _componentSection(0x0c, const <int>[0x01, 0x00, 0x00]),
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

Uint8List _emptyRecordTypeComponentBytes() =>
    _componentWithSingleTypeDefinitionBytes(const <int>[0x72, 0x00]);

Uint8List _emptyVariantTypeComponentBytes() =>
    _componentWithSingleTypeDefinitionBytes(const <int>[0x71, 0x00]);

Uint8List _emptyFlagsTypeComponentBytes() =>
    _componentWithSingleTypeDefinitionBytes(const <int>[0x6e, 0x00]);

Uint8List _emptyEnumTypeComponentBytes() =>
    _componentWithSingleTypeDefinitionBytes(const <int>[0x6d, 0x00]);

Uint8List _emptyTupleTypeComponentBytes() =>
    _componentWithSingleTypeDefinitionBytes(const <int>[0x6f, 0x00]);

Uint8List _tooManyFlagsTypeComponentBytes() {
  final typeBytes = <int>[0x6e, 0x21];
  for (var i = 1; i <= 33; i++) {
    final label = 'f$i'.codeUnits;
    typeBytes
      ..add(label.length)
      ..addAll(label);
  }
  return _componentWithSingleTypeDefinitionBytes(typeBytes);
}

Uint8List _emptyFunctionParameterNameTypeComponentBytes() =>
    _componentWithSingleTypeDefinitionBytes(const <int>[
      0x40,
      0x01,
      0x00,
      0x73,
      0x01,
      0x00,
    ]);

Uint8List _conflictingFunctionParameterNamesTypeComponentBytes() =>
    _componentWithSingleTypeDefinitionBytes(const <int>[
      0x40,
      0x02,
      0x03,
      0x66,
      0x6f,
      0x6f,
      0x73,
      0x03,
      0x46,
      0x4f,
      0x4f,
      0x79,
      0x01,
      0x00,
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

Uint8List _resourceDestructorFunctionComponentBytes() =>
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
      0x00,
      0x01,
      0x66,
      0x01,
      0x00,
      0x07,
      0x05,
      0x01,
      0x3f,
      0x7f,
      0x01,
      0x00,
    ]);

Uint8List _resourceExternrefRepresentationTypeComponentBytes() =>
    _componentWithSingleTypeDefinitionBytes(const <int>[0x3f, 0x6f, 0x00]);

Uint8List _resourceRefEqRepresentationTypeComponentBytes() =>
    _componentWithSingleTypeDefinitionBytes(const <int>[
      0x3f,
      0x64,
      0x6d,
      0x00,
    ]);

Uint8List _resourceInvalidRepresentationTypeComponentBytes() =>
    _componentWithSingleTypeDefinitionBytes(const <int>[0x3f, 0x00, 0x00]);

Uint8List _resourceDestructorOutOfRangeFunctionComponentBytes() =>
    _componentWithSingleTypeDefinitionBytes(const <int>[
      0x3f,
      0x7f,
      0x01,
      0x00,
    ]);

Uint8List _asyncResourceCallbackOutOfRangeFunctionComponentBytes() =>
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
      0x00,
      0x01,
      0x66,
      0x01,
      0x00,
      0x07,
      0x06,
      0x01,
      0x3e,
      0x7f,
      0x00,
      0x01,
      0x01,
    ]);

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

Uint8List _nestedStreamTypeComponentBytes() =>
    _componentWithTypeDefinitionsBytes(const <int>[
      0x66,
      0x01,
      0x73,
      0x66,
      0x01,
      0x00,
    ], count: 2);

Uint8List _futureStreamTypeComponentBytes() =>
    _componentWithTypeDefinitionsBytes(const <int>[
      0x66,
      0x01,
      0x73,
      0x65,
      0x01,
      0x00,
    ], count: 2);

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
