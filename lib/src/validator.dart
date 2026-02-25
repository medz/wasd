import 'dart:typed_data';

import 'byte_reader.dart';
import 'features.dart';
import 'module.dart';
import 'opcode.dart';
import 'predecode.dart';

final class _ReferenceControlFrame {
  _ReferenceControlFrame({
    required this.stackHeight,
    required this.resultSignatures,
    this.polymorphic = false,
  });

  final int stackHeight;
  final List<String> resultSignatures;
  bool polymorphic;
}

final class _SimpleControlFrame {
  _SimpleControlFrame({
    required this.stackHeight,
    required this.parameterSignatures,
    required this.labelSignatures,
    required this.resultSignatures,
    this.isLoop = false,
    this.isIf = false,
  });

  final int stackHeight;
  final List<String> parameterSignatures;
  final List<String> labelSignatures;
  final List<String> resultSignatures;
  bool polymorphic = false;
  final bool isLoop;
  final bool isIf;
  bool seenElse = false;
  bool hasEndReachability = false;
}

abstract final class WasmValidator {
  static void validateModule(
    WasmModule module, {
    WasmFeatureSet features = const WasmFeatureSet(),
  }) {
    _validateTypeReferences(module);
    _validateTableArity(module, features: features);
    _validateMemoryArity(module, features: features);
    _validateImportTypes(module);
    _validateExportBindings(module);
    _validateStartFunction(module);
    _validateGlobals(module);
    _validateElements(module);
    _validateDataSegments(module);
    _validateFunctions(module, features: features);
  }

  static void _validateTypeReferences(WasmModule module) {
    for (var typeIndex = 0; typeIndex < module.types.length; typeIndex++) {
      final type = module.types[typeIndex];
      for (final superTypeIndex in type.superTypeIndices) {
        _checkIndex(superTypeIndex, module.types.length, 'type');
      }
      final descriptorType = type.descriptorTypeIndex;
      if (descriptorType != null) {
        _checkIndex(descriptorType, module.types.length, 'type');
      }
      final describesType = type.describesTypeIndex;
      if (describesType != null) {
        _checkIndex(describesType, module.types.length, 'type');
      }

      if (type.isFunctionType) {
        for (final signature in type.paramTypeSignatures) {
          _validateValueSignatureTypeReference(module, signature);
        }
        for (final signature in type.resultTypeSignatures) {
          _validateValueSignatureTypeReference(module, signature);
        }
        continue;
      }

      for (final fieldSignature in type.fieldSignatures) {
        final parsedField = _parseFieldSignature(fieldSignature);
        if (parsedField == null) {
          throw const FormatException('Validation failed: type mismatch.');
        }
        _validateValueSignatureTypeReference(module, parsedField.valueSignature);
      }
    }
  }

  static void _validateValueSignatureTypeReference(
    WasmModule module,
    String signature,
  ) {
    final bytes = _signatureToBytes(signature);
    if (bytes.isEmpty) {
      return;
    }
    final lead = bytes.first;
    if (lead == 0x7f || // i32
        lead == 0x7e || // i64
        lead == 0x7d || // f32
        lead == 0x7c || // f64
        lead == 0x7b || // v128
        lead == 0x78 || // i8
        lead == 0x77) {
      // i16
      return;
    }
    final parsedRef = _parseRefSignature(signature);
    if (parsedRef == null) {
      return;
    }
    final heapType = parsedRef.heapType;
    if (heapType >= 0) {
      _checkIndex(heapType, module.types.length, 'type');
      return;
    }
    if (!_isKnownAbstractHeapType(heapType)) {
      throw const FormatException('Validation failed: type mismatch.');
    }
  }

  static void _validateTableArity(
    WasmModule module, {
    required WasmFeatureSet features,
  }) {
    final tableCount = module.importedTableCount + module.tables.length;
    if (tableCount > 1 && !features.isEnabled('multi-table')) {
      throw const FormatException(
        'Validation failed: multiple tables are not enabled.',
      );
    }
  }

  static void _validateMemoryArity(
    WasmModule module, {
    required WasmFeatureSet features,
  }) {
    final memoryCount = module.importedMemoryCount + module.memories.length;
    if (memoryCount > 1 && !features.isEnabled('multi-memory')) {
      throw const FormatException(
        'Validation failed: multiple memories are not enabled.',
      );
    }
  }

  static void _validateImportTypes(WasmModule module) {
    for (final import in module.imports) {
      switch (import.kind) {
        case WasmImportKind.function:
        case WasmImportKind.exactFunction:
          final typeIndex = import.functionTypeIndex;
          if (typeIndex == null ||
              typeIndex < 0 ||
              typeIndex >= module.types.length ||
              !module.types[typeIndex].isFunctionType) {
            throw FormatException(
              'Validation failed: invalid function import type index: $typeIndex',
            );
          }
        case WasmImportKind.table:
          if (import.tableType == null) {
            throw FormatException(
              'Validation failed: malformed table import `${import.key}`.',
            );
          }
        case WasmImportKind.memory:
          if (import.memoryType == null) {
            throw FormatException(
              'Validation failed: malformed memory import `${import.key}`.',
            );
          }
        case WasmImportKind.global:
          if (import.globalType == null) {
            throw FormatException(
              'Validation failed: malformed global import `${import.key}`.',
            );
          }
      }
    }
  }

  static void _validateExportBindings(WasmModule module) {
    final functionCount =
        module.importedFunctionCount + module.functionTypeIndices.length;
    final tableCount = module.importedTableCount + module.tables.length;
    final memoryCount = module.importedMemoryCount + module.memories.length;
    final globalCount = module.importedGlobalCount + module.globals.length;

    final seenNames = <String>{};
    for (final export in module.exports) {
      if (!seenNames.add(export.name)) {
        throw FormatException(
          'Validation failed: duplicate export name `${export.name}`.',
        );
      }
      switch (export.kind) {
        case WasmExportKind.function:
          _checkIndex(export.index, functionCount, 'export function');
        case WasmExportKind.table:
          _checkIndex(export.index, tableCount, 'export table');
        case WasmExportKind.memory:
          _checkIndex(export.index, memoryCount, 'export memory');
        case WasmExportKind.global:
          _checkIndex(export.index, globalCount, 'export global');
        default:
          throw FormatException(
            'Validation failed: invalid export kind ${export.kind}.',
          );
      }
    }
  }

  static void _validateStartFunction(WasmModule module) {
    final start = module.startFunctionIndex;
    if (start == null) {
      return;
    }
    final functionType = _functionTypeForIndex(module, start);
    if (functionType.params.isNotEmpty || functionType.results.isNotEmpty) {
      throw const FormatException(
        'Validation failed: start function must have signature [] -> [].',
      );
    }
  }

  static void _validateGlobals(WasmModule module) {
    final importedGlobals = module.imports
        .where((i) => i.kind == WasmImportKind.global)
        .map((i) => i.globalType!)
        .toList(growable: false);

    final availableGlobals = <WasmGlobalType>[...importedGlobals];
    for (final global in module.globals) {
      final exprType = _validateConstExpr(
        module: module,
        expr: global.initExpr,
        availableGlobals: availableGlobals,
        allowGlobalGet: (index, available) {
          if (index < 0 || index >= available.length) {
            return false;
          }
          return !available[index].mutable;
        },
      );
      if (exprType != global.type.valueType) {
        throw FormatException(
          'Validation failed: global init type mismatch. expected=${global.type.valueType} actual=$exprType',
        );
      }
      availableGlobals.add(global.type);
    }
  }

  static void _validateElements(WasmModule module) {
    final functionCount =
        module.importedFunctionCount + module.functionTypeIndices.length;
    final tableCount = module.importedTableCount + module.tables.length;
    final table64ByIndex = _table64ByIndex(module);
    final importedGlobals = module.imports
        .where((i) => i.kind == WasmImportKind.global)
        .map((i) => i.globalType!)
        .toList(growable: false);

    for (final element in module.elements) {
      if (element.isActive) {
        _checkIndex(element.tableIndex, tableCount, 'element table');
        final exprType = _validateConstExpr(
          module: module,
          expr: element.offsetExpr!,
          availableGlobals: importedGlobals,
          allowGlobalGet: (index, available) {
            if (index < 0 || index >= available.length) {
              return false;
            }
            return !available[index].mutable;
          },
        );
        final isTable64 =
            element.tableIndex >= 0 &&
            element.tableIndex < table64ByIndex.length &&
            table64ByIndex[element.tableIndex];
        final expectedType = isTable64 ? WasmValueType.i64 : WasmValueType.i32;
        if (exprType != expectedType) {
          throw FormatException(
            'Validation failed: element offset expr must produce '
            '$expectedType, got $exprType.',
          );
        }
      }
      final carriesFunctionRefs = element.refTypeCode == 0x70;
      if (carriesFunctionRefs) {
        for (final functionIndex in element.functionIndices) {
          if (functionIndex == null) {
            continue;
          }
          _checkIndex(functionIndex, functionCount, 'element function');
        }
      }
    }
  }

  static void _validateDataSegments(WasmModule module) {
    final memoryCount = module.importedMemoryCount + module.memories.length;
    final memory64ByIndex = _memory64ByIndex(module);
    final availableGlobals = <WasmGlobalType>[
      ...module.imports
        .where((i) => i.kind == WasmImportKind.global)
        .map((i) => i.globalType!),
      ...module.globals.map((global) => global.type),
    ];

    for (final data in module.dataSegments) {
      if (data.isPassive) {
        continue;
      }
      _checkIndex(data.memoryIndex, memoryCount, 'data memory');
      final isMemory64 =
          data.memoryIndex >= 0 &&
          data.memoryIndex < memory64ByIndex.length &&
          memory64ByIndex[data.memoryIndex];
      final expectedType = isMemory64 ? WasmValueType.i64 : WasmValueType.i32;
      final exprType = _validateConstExpr(
        module: module,
        expr: data.offsetExpr!,
        availableGlobals: availableGlobals,
        allowGlobalGet: (index, available) {
          if (index < 0 || index >= available.length) {
            return false;
          }
          return !available[index].mutable;
        },
      );
      if (exprType != expectedType) {
        throw FormatException(
          'Validation failed: data offset expr must produce $expectedType, got $exprType.',
        );
      }
    }
  }

  static void _validateFunctions(
    WasmModule module, {
    required WasmFeatureSet features,
  }) {
    final functionCount =
        module.importedFunctionCount + module.functionTypeIndices.length;
    final tableCount = module.importedTableCount + module.tables.length;
    final memoryCount = module.importedMemoryCount + module.memories.length;
    final globalCount = module.importedGlobalCount + module.globals.length;
    final memory64ByIndex = _memory64ByIndex(module);
    final table64ByIndex = _table64ByIndex(module);
    final tableTypes = <WasmTableType>[
      ...module.imports
          .where((i) => i.kind == WasmImportKind.table)
          .map((i) => i.tableType!),
      ...module.tables,
    ];
    var requiresDataCount = false;

    for (var i = 0; i < module.functionTypeIndices.length; i++) {
      final typeIndex = module.functionTypeIndices[i];
      _checkIndex(typeIndex, module.types.length, 'function type');
      if (!module.types[typeIndex].isFunctionType) {
        throw FormatException(
          'Validation failed: type index $typeIndex is not a function type.',
        );
      }
      final functionType = module.types[typeIndex];
      final body = module.codes[i];
      final localsCount = _validatedLocalsCount(functionType, body);
      final predecoded = WasmPredecoder.decode(
        body,
        module.types,
        features: features,
        memory64ByIndex: memory64ByIndex,
      );
      _validateBrOnCastTyping(
        module: module,
        functionType: functionType,
        body: body,
        instructions: predecoded.instructions,
      );
      _validateSimpleReferenceReturnCompatibility(
        module: module,
        functionType: functionType,
        instructions: predecoded.instructions,
      );
      _validateSimpleStackDiscipline(
        module: module,
        functionType: functionType,
        body: body,
        instructions: predecoded.instructions,
        memory64ByIndex: memory64ByIndex,
        table64ByIndex: table64ByIndex,
      );
      _validateArrayInstructionTyping(
        module: module,
        functionType: functionType,
        body: body,
        instructions: predecoded.instructions,
      );
      if (_containsWideArithmetic(predecoded.instructions)) {
        _validateWideArithmeticStack(
          functionType: functionType,
          body: body,
          instructions: predecoded.instructions,
        );
      }

      final controlStack = <int>[];
      for (var pc = 0; pc < predecoded.instructions.length; pc++) {
        final instruction = predecoded.instructions[pc];
        if (_isAtomicMemoryOpcode(instruction.opcode) && memoryCount == 0) {
          throw const FormatException(
            'Validation failed: memory instruction used without memory.',
          );
        }
        if (_isAtomicMemoryOpcode(instruction.opcode)) {
          final memoryIndex = instruction.memArg?.memoryIndex;
          if (memoryIndex == null) {
            throw const FormatException(
              'Validation failed: atomic memory instruction missing memarg.',
            );
          }
          _checkIndex(memoryIndex, memoryCount, 'memory');
          _validateMemArgAlignment(instruction);
        }
        switch (instruction.opcode) {
          case Opcodes.block:
          case Opcodes.loop:
          case Opcodes.if_:
            controlStack.add(instruction.opcode);
          case Opcodes.else_:
            if (controlStack.isEmpty || controlStack.last != Opcodes.if_) {
              throw const FormatException(
                'Validation failed: `else` without matching `if`.',
              );
            }
          case Opcodes.end:
            if (controlStack.isNotEmpty) {
              controlStack.removeLast();
            }
          case Opcodes.br:
          case Opcodes.brIf:
          case Opcodes.brOnNull:
          case Opcodes.brOnNonNull:
            final depth = instruction.immediate!;
            if (depth < 0 || depth > controlStack.length) {
              throw FormatException(
                'Validation failed: branch depth out of range: $depth.',
              );
            }
          case Opcodes.brTable:
            final targets = instruction.tableDepths ?? const <int>[];
            for (final depth in targets) {
              if (depth < 0 || depth > controlStack.length) {
                throw FormatException(
                  'Validation failed: br_table depth out of range: $depth.',
                );
              }
            }
          case Opcodes.call:
          case Opcodes.returnCall:
          case Opcodes.refFunc:
            _checkIndex(instruction.immediate!, functionCount, 'function ref');
          case Opcodes.callRef:
          case Opcodes.returnCallRef:
            final typeRef = instruction.immediate!;
            _checkIndex(typeRef, module.types.length, 'type ref');
            if (!module.types[typeRef].isFunctionType) {
              throw FormatException(
                'Validation failed: call_ref type $typeRef is not a function type.',
              );
            }
          case Opcodes.callIndirect:
          case Opcodes.returnCallIndirect:
            final typeRef = instruction.immediate!;
            _checkIndex(typeRef, module.types.length, 'type ref');
            if (!module.types[typeRef].isFunctionType) {
              throw FormatException(
                'Validation failed: call_indirect type $typeRef is not a function type.',
              );
            }
            _checkIndex(
              instruction.secondaryImmediate!,
              tableCount,
              'table ref',
            );
            final tableIndex = instruction.secondaryImmediate!;
            final tableType = tableTypes[tableIndex];
            if (tableType.refType != WasmRefType.funcref) {
              throw const FormatException(
                'Validation failed: type mismatch.',
              );
            }
          case Opcodes.localGet:
          case Opcodes.localSet:
          case Opcodes.localTee:
            _checkIndex(instruction.immediate!, localsCount, 'local');
          case Opcodes.globalGet:
          case Opcodes.globalSet:
            _checkIndex(instruction.immediate!, globalCount, 'global');
          case Opcodes.structNew:
          case Opcodes.structNewDefault:
          case Opcodes.structNewDesc:
          case Opcodes.structNewDefaultDesc:
          case Opcodes.refGetDesc:
            final typeIndex = instruction.immediate!;
            _checkIndex(typeIndex, module.types.length, 'type');
            final type = module.types[typeIndex];
            if (instruction.opcode == Opcodes.refGetDesc) {
              if (type.descriptorTypeIndex == null) {
                throw const FormatException(
                  'Validation failed: type mismatch.',
                );
              }
              break;
            }
            if (type.kind != WasmCompositeTypeKind.struct) {
              throw const FormatException('Validation failed: type mismatch.');
            }
            final hasDescriptor = type.descriptorTypeIndex != null;
            if ((instruction.opcode == Opcodes.structNew ||
                    instruction.opcode == Opcodes.structNewDefault) &&
                hasDescriptor) {
              throw const FormatException('Validation failed: type mismatch.');
            }
            if ((instruction.opcode == Opcodes.structNewDesc ||
                    instruction.opcode == Opcodes.structNewDefaultDesc) &&
                !hasDescriptor) {
              throw const FormatException('Validation failed: type mismatch.');
            }
          case Opcodes.arrayNew:
          case Opcodes.arrayNewDefault:
          case Opcodes.arrayNewFixed:
          case Opcodes.arrayNewData:
          case Opcodes.arrayNewElem:
          case Opcodes.arrayGet:
          case Opcodes.arrayGetS:
          case Opcodes.arrayGetU:
          case Opcodes.arraySet:
          case Opcodes.arrayInitData:
          case Opcodes.arrayInitElem:
          case Opcodes.arrayFill:
            final typeIndex = instruction.immediate!;
            _checkIndex(typeIndex, module.types.length, 'type');
            final type = module.types[typeIndex];
            if (type.kind != WasmCompositeTypeKind.array) {
              throw const FormatException('Validation failed: type mismatch.');
            }
            final arrayField = _arrayFieldInfo(type);
            if (arrayField == null) {
              throw const FormatException('Validation failed: type mismatch.');
            }
            if ((instruction.opcode == Opcodes.arraySet ||
                    instruction.opcode == Opcodes.arrayFill ||
                    instruction.opcode == Opcodes.arrayInitData ||
                    instruction.opcode == Opcodes.arrayInitElem) &&
                arrayField.mutability == 0) {
              throw const FormatException('Validation failed: immutable array.');
            }
            if (instruction.opcode == Opcodes.arrayGet &&
                _isPackedStorageSignature(arrayField.valueSignature)) {
              throw const FormatException('Validation failed: type mismatch.');
            }
            if ((instruction.opcode == Opcodes.arrayGetS ||
                    instruction.opcode == Opcodes.arrayGetU) &&
                !_isPackedStorageSignature(arrayField.valueSignature)) {
              throw const FormatException('Validation failed: type mismatch.');
            }
            if (instruction.opcode == Opcodes.arrayNewData ||
                instruction.opcode == Opcodes.arrayInitData) {
              requiresDataCount = true;
              final dataIndex = instruction.secondaryImmediate!;
              _checkIndex(dataIndex, module.dataSegments.length, 'data segment');
              if (!_isNumericOrVectorValueSignature(arrayField.valueSignature)) {
                throw const FormatException(
                  'Validation failed: type mismatch.',
                );
              }
            }
            if (instruction.opcode == Opcodes.arrayNewElem ||
                instruction.opcode == Opcodes.arrayInitElem) {
              final elementIndex = instruction.secondaryImmediate!;
              _checkIndex(elementIndex, module.elements.length, 'element segment');
              if (!_isReferenceValueSignature(arrayField.valueSignature)) {
                throw const FormatException(
                  'Validation failed: type mismatch.',
                );
              }
              final segment = module.elements[elementIndex];
              if (!_isElementSegmentRefCompatible(
                module: module,
                segmentRefTypeCode: segment.refTypeCode,
                targetValueSignature: arrayField.valueSignature,
              )) {
                throw const FormatException(
                  'Validation failed: type mismatch.',
                );
              }
            }
          case Opcodes.arrayCopy:
            final destinationTypeIndex = instruction.immediate!;
            final sourceTypeIndex = instruction.secondaryImmediate!;
            _checkIndex(destinationTypeIndex, module.types.length, 'type');
            _checkIndex(sourceTypeIndex, module.types.length, 'type');
            final destinationType = module.types[destinationTypeIndex];
            final sourceType = module.types[sourceTypeIndex];
            if (destinationType.kind != WasmCompositeTypeKind.array ||
                sourceType.kind != WasmCompositeTypeKind.array) {
              throw const FormatException('Validation failed: type mismatch.');
            }
            final destinationField = _arrayFieldInfo(destinationType);
            final sourceField = _arrayFieldInfo(sourceType);
            if (destinationField == null || sourceField == null) {
              throw const FormatException('Validation failed: type mismatch.');
            }
            if (destinationField.mutability == 0) {
              throw const FormatException('Validation failed: immutable array.');
            }
            if (!_areValueTypeSignaturesEquivalent(
              module,
              sourceField.valueSignature,
              destinationField.valueSignature,
              <String>{},
            )) {
              throw const FormatException('Validation failed: type mismatch.');
            }
          case Opcodes.refCastDesc:
          case Opcodes.refCastDescEq:
            final target = instruction.gcRefType;
            if (target == null ||
                target.heapType < 0 ||
                target.heapType >= module.types.length ||
                module.types[target.heapType].descriptorTypeIndex == null) {
              throw const FormatException('Validation failed: type mismatch.');
            }
          case Opcodes.tableGet:
          case Opcodes.tableSet:
            _checkIndex(instruction.immediate!, tableCount, 'table');
          case Opcodes.i32Load:
          case Opcodes.i64Load:
          case Opcodes.f32Load:
          case Opcodes.f64Load:
          case Opcodes.i32Load8S:
          case Opcodes.i32Load8U:
          case Opcodes.i32Load16S:
          case Opcodes.i32Load16U:
          case Opcodes.i64Load8S:
          case Opcodes.i64Load8U:
          case Opcodes.i64Load16S:
          case Opcodes.i64Load16U:
          case Opcodes.i64Load32S:
          case Opcodes.i64Load32U:
          case Opcodes.i32Store:
          case Opcodes.i64Store:
          case Opcodes.f32Store:
          case Opcodes.f64Store:
          case Opcodes.i32Store8:
          case Opcodes.i32Store16:
          case Opcodes.i64Store8:
          case Opcodes.i64Store16:
          case Opcodes.i64Store32:
            if (memoryCount == 0) {
              throw const FormatException(
                'Validation failed: memory instruction used without memory.',
              );
            }
            final memoryIndex = instruction.memArg?.memoryIndex;
            if (memoryIndex == null) {
              throw const FormatException(
                'Validation failed: memory instruction missing memarg.',
              );
            }
            _checkIndex(memoryIndex, memoryCount, 'memory');
            _validateMemArgAlignment(instruction);
          case Opcodes.memorySize:
          case Opcodes.memoryGrow:
            if (memoryCount == 0) {
              throw const FormatException(
                'Validation failed: memory instruction used without memory.',
              );
            }
            _checkIndex(instruction.immediate!, memoryCount, 'memory');
          case Opcodes.memoryInit:
            requiresDataCount = true;
            if (memoryCount == 0) {
              throw const FormatException(
                'Validation failed: memory.init used without memory.',
              );
            }
            _checkIndex(
              instruction.immediate!,
              module.dataSegments.length,
              'data segment',
            );
            _checkIndex(instruction.secondaryImmediate!, memoryCount, 'memory');
          case Opcodes.dataDrop:
            requiresDataCount = true;
            _checkIndex(
              instruction.immediate!,
              module.dataSegments.length,
              'data segment',
            );
          case Opcodes.memoryCopy:
            if (memoryCount == 0) {
              throw const FormatException(
                'Validation failed: memory.copy used without memory.',
              );
            }
            _checkIndex(instruction.immediate!, memoryCount, 'memory');
            _checkIndex(instruction.secondaryImmediate!, memoryCount, 'memory');
          case Opcodes.memoryFill:
            if (memoryCount == 0) {
              throw const FormatException(
                'Validation failed: memory.fill used without memory.',
              );
            }
            _checkIndex(instruction.immediate!, memoryCount, 'memory');
          case Opcodes.tableInit:
            _checkIndex(
              instruction.immediate!,
              module.elements.length,
              'element segment',
            );
            _checkIndex(instruction.secondaryImmediate!, tableCount, 'table');
          case Opcodes.elemDrop:
            _checkIndex(
              instruction.immediate!,
              module.elements.length,
              'element segment',
            );
          case Opcodes.tableCopy:
            _checkIndex(instruction.immediate!, tableCount, 'table');
            _checkIndex(instruction.secondaryImmediate!, tableCount, 'table');
          case Opcodes.tableGrow:
          case Opcodes.tableSize:
          case Opcodes.tableFill:
            _checkIndex(instruction.immediate!, tableCount, 'table');
          default:
            // Other opcodes are validated by predecode/runtime type coercion.
            break;
        }
      }
    }

    if (requiresDataCount && module.dataCount == null) {
      throw const FormatException(
        'Validation failed: data_count section required when using memory.init/data.drop.',
      );
    }
  }

  static WasmFunctionType _functionTypeForIndex(WasmModule module, int index) {
    if (index < 0) {
      throw FormatException(
        'Validation failed: invalid function index $index.',
      );
    }

    var importFuncOrdinal = 0;
    for (final import in module.imports) {
      if (import.kind != WasmImportKind.function &&
          import.kind != WasmImportKind.exactFunction) {
        continue;
      }
      if (importFuncOrdinal == index) {
        final type = module.types[import.functionTypeIndex!];
        if (!type.isFunctionType) {
          throw FormatException(
            'Validation failed: type ${import.functionTypeIndex} is not a function type.',
          );
        }
        return type;
      }
      importFuncOrdinal++;
    }

    final definedIndex = index - module.importedFunctionCount;
    if (definedIndex < 0 || definedIndex >= module.functionTypeIndices.length) {
      throw FormatException(
        'Validation failed: invalid function index $index.',
      );
    }
    final typeIndex = module.functionTypeIndices[definedIndex];
    _checkIndex(typeIndex, module.types.length, 'function type');
    final type = module.types[typeIndex];
    if (!type.isFunctionType) {
      throw FormatException(
        'Validation failed: type index $typeIndex is not a function type.',
      );
    }
    return type;
  }

  static int _functionTypeIndexForFunction(WasmModule module, int index) {
    if (index < 0) {
      throw FormatException(
        'Validation failed: invalid function index $index.',
      );
    }

    var importFuncOrdinal = 0;
    for (final import in module.imports) {
      if (import.kind != WasmImportKind.function &&
          import.kind != WasmImportKind.exactFunction) {
        continue;
      }
      if (importFuncOrdinal == index) {
        final typeIndex = import.functionTypeIndex;
        if (typeIndex == null) {
          throw const FormatException(
            'Validation failed: function import missing type index.',
          );
        }
        _checkIndex(typeIndex, module.types.length, 'function type');
        if (!module.types[typeIndex].isFunctionType) {
          throw FormatException(
            'Validation failed: type index $typeIndex is not a function type.',
          );
        }
        return typeIndex;
      }
      importFuncOrdinal++;
    }

    final definedIndex = index - module.importedFunctionCount;
    if (definedIndex < 0 || definedIndex >= module.functionTypeIndices.length) {
      throw FormatException(
        'Validation failed: invalid function index $index.',
      );
    }
    final typeIndex = module.functionTypeIndices[definedIndex];
    _checkIndex(typeIndex, module.types.length, 'function type');
    if (!module.types[typeIndex].isFunctionType) {
      throw FormatException(
        'Validation failed: type index $typeIndex is not a function type.',
      );
    }
    return typeIndex;
  }

  static int _validatedLocalsCount(
    WasmFunctionType functionType,
    WasmCodeBody body,
  ) {
    final maxLocals = BigInt.from(0xffffffff);
    var total = BigInt.from(functionType.params.length);
    for (final local in body.locals) {
      total += BigInt.from(local.count);
      if (total > maxLocals) {
        throw const FormatException('Validation failed: too many locals.');
      }
    }
    return total.toInt();
  }

  static WasmValueType _validateConstExpr({
    required WasmModule module,
    required List<WasmGlobalType> availableGlobals,
    required Uint8List expr,
    required bool Function(int index, List<WasmGlobalType> globals)
    allowGlobalGet,
  }) {
    final reader = ByteReader(expr);
    final stack = <WasmValueType>[];

    void requireTopTwo(WasmValueType type, int opcode) {
      if (stack.length < 2) {
        throw FormatException(
          'Validation failed: const expr stack underflow at 0x${opcode.toRadixString(16)}.',
        );
      }
      final rhs = stack.removeLast();
      final lhs = stack.removeLast();
      if (lhs != type || rhs != type) {
        throw FormatException(
          'Validation failed: const expr type mismatch at 0x${opcode.toRadixString(16)}.',
        );
      }
      stack.add(type);
    }

    void popAny(int count, int opcode) {
      if (stack.length < count) {
        throw FormatException(
          'Validation failed: const expr stack underflow at 0x${opcode.toRadixString(16)}.',
        );
      }
      stack.removeRange(stack.length - count, stack.length);
    }

    while (!reader.isEOF) {
      final opcode = reader.readByte();
      switch (opcode) {
        case Opcodes.i32Const:
          reader.readVarInt32();
          stack.add(WasmValueType.i32);
        case Opcodes.i64Const:
          reader.readVarInt64();
          stack.add(WasmValueType.i64);
        case Opcodes.f32Const:
          reader.readBytes(4);
          stack.add(WasmValueType.f32);
        case Opcodes.f64Const:
          reader.readBytes(8);
          stack.add(WasmValueType.f64);
        case Opcodes.globalGet:
          final index = reader.readVarUint32();
          if (!allowGlobalGet(index, availableGlobals)) {
            throw FormatException(
              'Validation failed: illegal const expr global.get $index.',
            );
          }
          stack.add(availableGlobals[index].valueType);
        case Opcodes.refNull:
          _consumeHeapType(reader);
          stack.add(WasmValueType.i32);
        case Opcodes.refFunc:
          final functionIndex = reader.readVarUint32();
          final functionCount =
              module.importedFunctionCount + module.functionTypeIndices.length;
          _checkIndex(functionIndex, functionCount, 'const expr ref.func');
          stack.add(WasmValueType.i32);
        case 0xfb:
          final subOpcode = reader.readVarUint32();
          final pseudoOpcode = 0xfb00 | subOpcode;
          switch (pseudoOpcode) {
            case Opcodes.structNew:
            case Opcodes.structNewDefault:
            case Opcodes.structNewDesc:
            case Opcodes.structNewDefaultDesc:
            case Opcodes.arrayNew:
            case Opcodes.arrayNewDefault:
            case Opcodes.arrayNewFixed:
              final typeIndex = reader.readVarUint32();
              _checkIndex(typeIndex, module.types.length, 'const expr type');
              final type = module.types[typeIndex];
              switch (pseudoOpcode) {
                case Opcodes.structNew:
                  if (type.kind != WasmCompositeTypeKind.struct) {
                    throw const FormatException(
                      'Validation failed: type mismatch.',
                    );
                  }
                  if (type.descriptorTypeIndex != null) {
                    throw const FormatException(
                      'Validation failed: type mismatch.',
                    );
                  }
                  popAny(type.fieldSignatures.length, pseudoOpcode);
                case Opcodes.structNewDefault:
                  if (type.kind != WasmCompositeTypeKind.struct) {
                    throw const FormatException(
                      'Validation failed: type mismatch.',
                    );
                  }
                  if (type.descriptorTypeIndex != null) {
                    throw const FormatException(
                      'Validation failed: type mismatch.',
                    );
                  }
                case Opcodes.structNewDesc:
                  if (type.kind != WasmCompositeTypeKind.struct ||
                      type.descriptorTypeIndex == null) {
                    throw const FormatException(
                      'Validation failed: type mismatch.',
                    );
                  }
                  popAny(1, pseudoOpcode);
                  popAny(type.fieldSignatures.length, pseudoOpcode);
                case Opcodes.structNewDefaultDesc:
                  if (type.kind != WasmCompositeTypeKind.struct ||
                      type.descriptorTypeIndex == null) {
                    throw const FormatException(
                      'Validation failed: type mismatch.',
                    );
                  }
                  popAny(1, pseudoOpcode);
                case Opcodes.arrayNew:
                  if (type.kind != WasmCompositeTypeKind.array) {
                    throw const FormatException(
                      'Validation failed: type mismatch.',
                    );
                  }
                  popAny(2, pseudoOpcode);
                case Opcodes.arrayNewDefault:
                  if (type.kind != WasmCompositeTypeKind.array) {
                    throw const FormatException(
                      'Validation failed: type mismatch.',
                    );
                  }
                  popAny(1, pseudoOpcode);
                case Opcodes.arrayNewFixed:
                  if (type.kind != WasmCompositeTypeKind.array) {
                    throw const FormatException(
                      'Validation failed: type mismatch.',
                    );
                  }
                  final count = reader.readVarUint32();
                  popAny(count, pseudoOpcode);
                default:
                  throw UnsupportedError(
                    'Validation failed: unsupported const expr opcode 0x${pseudoOpcode.toRadixString(16)}',
                  );
              }
              stack.add(WasmValueType.i32);
            case Opcodes.refI31:
              if (stack.isEmpty || stack.last != WasmValueType.i32) {
                throw FormatException(
                  'Validation failed: const expr type mismatch at 0x${pseudoOpcode.toRadixString(16)}.',
                );
              }
              stack
                ..removeLast()
                ..add(WasmValueType.i32);
            default:
              throw UnsupportedError(
                'Validation failed: unsupported const expr opcode 0x${pseudoOpcode.toRadixString(16)}',
              );
          }
        case Opcodes.i32Add:
        case Opcodes.i32Sub:
        case Opcodes.i32Mul:
          requireTopTwo(WasmValueType.i32, opcode);
        case Opcodes.i64Add:
        case Opcodes.i64Sub:
        case Opcodes.i64Mul:
          requireTopTwo(WasmValueType.i64, opcode);
        case Opcodes.f32Add:
        case Opcodes.f32Sub:
        case Opcodes.f32Mul:
        case Opcodes.f32Div:
          requireTopTwo(WasmValueType.f32, opcode);
        case Opcodes.f64Add:
        case Opcodes.f64Sub:
        case Opcodes.f64Mul:
        case Opcodes.f64Div:
          requireTopTwo(WasmValueType.f64, opcode);
        case Opcodes.end:
          if (!reader.isEOF) {
            throw const FormatException(
              'Validation failed: const expr has trailing bytes.',
            );
          }
          if (stack.length != 1) {
            throw FormatException(
              'Validation failed: const expr must leave one value, got ${stack.length}.',
            );
          }
          return stack.single;
        default:
          throw UnsupportedError(
            'Validation failed: unsupported const expr opcode 0x${opcode.toRadixString(16)}',
          );
      }
    }

    throw const FormatException('Validation failed: const expr missing end.');
  }

  static bool _containsWideArithmetic(List<Instruction> instructions) {
    for (final instruction in instructions) {
      switch (instruction.opcode) {
        case Opcodes.i64Add128:
        case Opcodes.i64Sub128:
        case Opcodes.i64MulWideS:
        case Opcodes.i64MulWideU:
          return true;
      }
    }
    return false;
  }

  static void _validateSimpleStackDiscipline({
    required WasmModule module,
    required WasmFunctionType functionType,
    required WasmCodeBody body,
    required List<Instruction> instructions,
    required List<bool> memory64ByIndex,
    required List<bool> table64ByIndex,
  }) {
    Never mismatch([String? reason]) {
      assert(reason == null || reason.isNotEmpty);
      if (reason == null || reason.isEmpty) {
        throw const FormatException('Validation failed: type mismatch.');
      }
      throw FormatException('Validation failed: type mismatch ($reason).');
    }

    String addressSignatureForMemArg(MemArg? memArg) {
      final memoryIndex = memArg?.memoryIndex ?? 0;
      final isMemory64 =
          memoryIndex >= 0 &&
          memoryIndex < memory64ByIndex.length &&
          memory64ByIndex[memoryIndex];
      return isMemory64 ? '7e' : '7f';
    }

    String addressSignatureForMemoryIndex(int memoryIndex) {
      final isMemory64 =
          memoryIndex >= 0 &&
          memoryIndex < memory64ByIndex.length &&
          memory64ByIndex[memoryIndex];
      return isMemory64 ? '7e' : '7f';
    }

    String tableIndexSignature(int tableIndex) {
      final isTable64 =
          tableIndex >= 0 &&
          tableIndex < table64ByIndex.length &&
          table64ByIndex[tableIndex];
      return isTable64 ? '7e' : '7f';
    }

    List<String> blockParamSignatures(Instruction instruction) {
      final signatures = instruction.blockParameterTypeSignatures;
      if (signatures != null) {
        return List<String>.from(signatures);
      }
      final types = instruction.blockParameterTypes;
      if (types == null) {
        return const <String>[];
      }
      return types.map(_signatureForValueType).toList(growable: false);
    }

    List<String> blockResultSignatures(Instruction instruction) {
      final signatures = instruction.blockResultTypeSignatures;
      if (signatures != null) {
        return List<String>.from(signatures);
      }
      final types = instruction.blockResultTypes;
      if (types == null) {
        return const <String>[];
      }
      return types.map(_signatureForValueType).toList(growable: false);
    }

    final locals = <String>[
      ..._functionParamSignatures(functionType),
      ..._localSignatures(body),
    ];
    final functionResultSignatures = _functionResultSignatures(functionType);
    final stack = <String>[];
    final controlStack = <_SimpleControlFrame>[
      _SimpleControlFrame(
        stackHeight: 0,
        parameterSignatures: const <String>[],
        labelSignatures: List<String>.from(functionResultSignatures),
        resultSignatures: List<String>.from(functionResultSignatures),
      ),
    ];

    bool isReferenceLikeSignature(String signature) {
      final bytes = _signatureToBytes(signature);
      if (bytes.isEmpty) {
        return false;
      }
      final lead = bytes.first;
      if (lead == 0x63 || lead == 0x64) {
        return true;
      }
      return switch (lead) {
        0x70 || // funcref
        0x6f || // externref
        0x71 || // nullref
        0x72 || // nullexternref
        0x73 || // nullfuncref
        0x6e || // anyref
        0x6d || // eqref
        0x6c || // i31ref
        0x6b || // structref
        0x6a || // arrayref
        0x69 || // i31ref (legacy)
        0x68 || // exnref
        0x67 ||
        0x66 ||
        0x65 ||
        0x62 ||
        0x61 ||
        0x60 => true,
        _ => false,
      };
    }

    bool isSubtypeForLightweightPass(String actual, String expected) {
      if (expected == '7f' && isReferenceLikeSignature(actual)) {
        // Local declarations collapse reference locals to i32 in the compact
        // model used by this pass.
        return true;
      }
      if (_isValueSignatureSubtype(module, actual, expected)) {
        return true;
      }
      if (!isReferenceLikeSignature(actual) ||
          !isReferenceLikeSignature(expected)) {
        return false;
      }
      final actualRef = _parseRefSignature(actual);
      final expectedRef = _parseRefSignature(expected);
      if (actualRef == null || expectedRef == null) {
        return false;
      }
      final actualUnknownHeap =
          actualRef.heapType < 0 && !_isKnownAbstractHeapType(actualRef.heapType);
      final expectedUnknownHeap =
          expectedRef.heapType < 0 &&
          !_isKnownAbstractHeapType(expectedRef.heapType);
      if (actualUnknownHeap || expectedUnknownHeap) {
        return true;
      }
      return false;
    }

    String popExpected(String expected, String label) {
      final frame = controlStack.last;
      if (stack.length > frame.stackHeight) {
        final actual = stack.removeLast();
        if (!isSubtypeForLightweightPass(actual, expected)) {
          mismatch('$label expected=$expected actual=$actual');
        }
        return actual;
      }
      if (frame.polymorphic) {
        return expected;
      }
      mismatch('$label stack underflow');
    }

    String popAny(String label) {
      final frame = controlStack.last;
      if (stack.length > frame.stackHeight) {
        return stack.removeLast();
      }
      if (frame.polymorphic) {
        return '7f';
      }
      mismatch('$label stack underflow');
    }

    String popReference(String label) {
      final frame = controlStack.last;
      if (stack.length <= frame.stackHeight && frame.polymorphic) {
        return _encodeRefSignature(
          nullable: true,
          exact: false,
          heapType: _heapAny,
        );
      }
      final value = popAny(label);
      if (!isReferenceLikeSignature(value)) {
        mismatch('$label requires reference operand');
      }
      final parsed = _parseRefSignature(value);
      if (parsed == null) {
        mismatch('$label requires reference operand');
      }
      return value;
    }

    String makeNonNullableReference(String value, String label) {
      final parsed = _parseRefSignature(value);
      if (parsed == null) {
        mismatch('$label requires reference operand');
      }
      if (!parsed.nullable) {
        return value;
      }
      return _encodeRefSignature(
        nullable: false,
        exact: parsed.exact,
        heapType: parsed.heapType,
      );
    }

    void markPolymorphic() {
      final frame = controlStack.last;
      stack.length = frame.stackHeight;
      frame.polymorphic = true;
    }

    _SimpleControlFrame frameForDepth(int depth, String label) {
      if (depth < 0 || depth >= controlStack.length) {
        mismatch('$label depth out of range: $depth');
      }
      return controlStack[controlStack.length - 1 - depth];
    }

    List<String> popLabelValues(List<String> signatures, String label) {
      final popped = <String>[];
      for (var i = signatures.length - 1; i >= 0; i--) {
        popped.add(popExpected(signatures[i], '$label[$i]'));
      }
      return popped;
    }

    bool validateFrameEnd(_SimpleControlFrame frame, String label) {
      final resultLength = frame.resultSignatures.length;
      final hasConcreteStack = stack.length > frame.stackHeight;
      final enforce = !frame.polymorphic || hasConcreteStack;
      if (!enforce) {
        return false;
      }
      if (stack.length != frame.stackHeight + resultLength) {
        mismatch(
          '$label stack height mismatch: stack=${stack.length} '
          'frameBase=${frame.stackHeight} resultLen=$resultLength',
        );
      }
      for (var i = 0; i < resultLength; i++) {
        final actual = stack[stack.length - resultLength + i];
        final expected = frame.resultSignatures[i];
        if (!_isValueSignatureSubtype(module, actual, expected)) {
          mismatch('$label result[$i] expected=$expected actual=$actual');
        }
      }
      return true;
    }

    void popCallArgs(WasmFunctionType targetType, String label) {
      final params = _functionParamSignatures(targetType);
      for (var i = params.length - 1; i >= 0; i--) {
        popExpected(params[i], '$label arg[$i]');
      }
    }

    void pushCallResults(WasmFunctionType targetType) {
      stack.addAll(_functionResultSignatures(targetType));
    }

    void requireReturnCompatibility(
      WasmFunctionType targetType,
      String label,
    ) {
      final targetResults = _functionResultSignatures(targetType);
      if (targetResults.length != functionResultSignatures.length) {
        mismatch(
          '$label result arity mismatch: '
          'expected=${functionResultSignatures.length} actual=${targetResults.length}',
        );
      }
      for (var i = 0; i < targetResults.length; i++) {
        if (!_isValueSignatureSubtype(
          module,
          targetResults[i],
          functionResultSignatures[i],
        )) {
          mismatch(
            '$label result[$i] expected=${functionResultSignatures[i]} '
            'actual=${targetResults[i]}',
          );
        }
      }
    }

    void popCallRefCallee(int expectedTypeIndex, String label) {
      final frame = controlStack.last;
      final fromPolymorphicBottom =
          stack.length <= frame.stackHeight && frame.polymorphic;
      final calleeSignature = popReference(label);
      if (fromPolymorphicBottom) {
        return;
      }
      final parsed = _parseRefSignature(calleeSignature);
      if (parsed == null) {
        mismatch('$label requires reference operand');
      }
      final heapType = parsed.heapType;
      if (_isKnownAbstractHeapType(heapType)) {
        if (heapType == _heapFunc || heapType == _heapNofunc) {
          mismatch('$label requires typed function reference');
        }
        mismatch('$label requires function reference');
      }
      if (heapType >= 0) {
        if (heapType >= module.types.length ||
            !module.types[heapType].isFunctionType) {
          mismatch('$label requires function reference');
        }
        if (!_isHeapSubtype(module, heapType, expectedTypeIndex)) {
          mismatch(
            '$label type mismatch: expected=$expectedTypeIndex actual=$heapType',
          );
        }
      }
      // Negative non-abstract heap types can encode recursive relative type
      // references. Keep this pass permissive and defer canonical checks.
    }

    void unary(String input, String output, String label) {
      popExpected(input, label);
      stack.add(output);
    }

    void binary(String input, String output, String label) {
      popExpected(input, '$label rhs');
      popExpected(input, '$label lhs');
      stack.add(output);
    }

    for (final instruction in instructions) {
      switch (instruction.opcode) {
        case Opcodes.block:
        case Opcodes.loop:
        case Opcodes.if_:
          final parameterSignatures = blockParamSignatures(instruction);
          final resultSignatures = blockResultSignatures(instruction);
          if (instruction.opcode == Opcodes.if_) {
            popExpected('7f', 'if condition');
          }
          for (var i = parameterSignatures.length - 1; i >= 0; i--) {
            popExpected(parameterSignatures[i], 'block param[$i]');
          }
          final stackHeight = stack.length;
          stack.addAll(parameterSignatures);
          controlStack.add(
            _SimpleControlFrame(
              stackHeight: stackHeight,
              parameterSignatures: parameterSignatures,
              labelSignatures: instruction.opcode == Opcodes.loop
                  ? parameterSignatures
                  : resultSignatures,
              resultSignatures: resultSignatures,
              isLoop: instruction.opcode == Opcodes.loop,
              isIf: instruction.opcode == Opcodes.if_,
            ),
          );

        case Opcodes.else_:
          if (controlStack.length <= 1) {
            mismatch('else without matching if');
          }
          final frame = controlStack.last;
          if (!frame.isIf || frame.seenElse) {
            mismatch('else without matching if');
          }
          validateFrameEnd(frame, 'if-then');
          stack.length = frame.stackHeight;
          stack.addAll(frame.parameterSignatures);
          frame.polymorphic = false;
          frame.seenElse = true;

        case Opcodes.end:
          if (controlStack.isEmpty) {
            mismatch('end without control frame');
          }
          final frame = controlStack.removeLast();
          final hasConcreteResult = validateFrameEnd(frame, 'end');
          stack.length = frame.stackHeight;
          if (hasConcreteResult || frame.hasEndReachability) {
            stack.addAll(frame.resultSignatures);
          }
          if (!hasConcreteResult &&
              !frame.hasEndReachability &&
              controlStack.isNotEmpty) {
            controlStack.last.polymorphic = true;
          }
          if (controlStack.isEmpty) {
            return;
          }

        case Opcodes.unreachable:
          markPolymorphic();

        case Opcodes.br:
          final depth = instruction.immediate!;
          final labelFrame = frameForDepth(depth, 'br');
          if (!labelFrame.isLoop) {
            labelFrame.hasEndReachability = true;
          }
          popLabelValues(labelFrame.labelSignatures, 'br operand');
          markPolymorphic();

        case Opcodes.brIf:
          final depth = instruction.immediate!;
          final labelFrame = frameForDepth(depth, 'br_if');
          if (!labelFrame.isLoop) {
            labelFrame.hasEndReachability = true;
          }
          popExpected('7f', 'br_if condition');
          popLabelValues(
            labelFrame.labelSignatures,
            'br_if operand',
          );
          stack.addAll(labelFrame.labelSignatures);

        case Opcodes.brTable:
          popExpected('7f', 'br_table index');
          final depths = instruction.tableDepths ?? const <int>[];
          if (depths.isEmpty) {
            mismatch('br_table requires at least default depth');
          }
          List<String>? commonSignatures;
          for (final depth in depths) {
            final labelFrame = frameForDepth(depth, 'br_table');
            if (!labelFrame.isLoop) {
              labelFrame.hasEndReachability = true;
            }
            final labelSignatures = labelFrame.labelSignatures;
            if (commonSignatures == null) {
              commonSignatures = List<String>.from(labelSignatures);
              continue;
            }
            if (labelSignatures.length != commonSignatures.length) {
              mismatch('br_table target arity mismatch');
            }
          }
          popLabelValues(commonSignatures!, 'br_table operand');
          markPolymorphic();

        case Opcodes.brOnNull:
          final depth = instruction.immediate!;
          final labelFrame = frameForDepth(depth, 'br_on_null');
          if (!labelFrame.isLoop) {
            labelFrame.hasEndReachability = true;
          }
          final frame = controlStack.last;
          final operandFromPolymorphicBottom =
              stack.length <= frame.stackHeight && frame.polymorphic;
          final operand = popReference('br_on_null operand');
          popLabelValues(
            labelFrame.labelSignatures,
            'br_on_null operand',
          );
          stack.addAll(labelFrame.labelSignatures);
          if (!operandFromPolymorphicBottom) {
            stack.add(makeNonNullableReference(operand, 'br_on_null operand'));
          }

        case Opcodes.brOnNonNull:
          final depth = instruction.immediate!;
          final labelFrame = frameForDepth(depth, 'br_on_non_null');
          if (!labelFrame.isLoop) {
            labelFrame.hasEndReachability = true;
          }
          final frame = controlStack.last;
          final operandFromPolymorphicBottom =
              stack.length <= frame.stackHeight && frame.polymorphic;
          final labelSignatures = labelFrame.labelSignatures;
          if (labelSignatures.isEmpty) {
            mismatch('br_on_non_null label arity mismatch');
          }
          final operand = popReference('br_on_non_null operand');
          final nonNullOperand = makeNonNullableReference(
            operand,
            'br_on_non_null operand',
          );
          if (!operandFromPolymorphicBottom &&
              !isSubtypeForLightweightPass(
                nonNullOperand,
                labelSignatures.last,
              )) {
            mismatch(
              'br_on_non_null branch value mismatch: '
              'operand=$nonNullOperand label=${labelSignatures.last}',
            );
          }
          final prefix = labelSignatures.sublist(0, labelSignatures.length - 1);
          popLabelValues(prefix, 'br_on_non_null operand');
          stack.addAll(prefix);

        case Opcodes.return_:
          for (var i = functionResultSignatures.length - 1; i >= 0; i--) {
            popExpected(functionResultSignatures[i], 'return result[$i]');
          }
          markPolymorphic();

        case Opcodes.call:
          final functionIndex = instruction.immediate!;
          final targetType = _functionTypeForIndex(module, functionIndex);
          popCallArgs(targetType, 'call');
          pushCallResults(targetType);

        case Opcodes.returnCall:
          final functionIndex = instruction.immediate!;
          final targetType = _functionTypeForIndex(module, functionIndex);
          popCallArgs(targetType, 'return_call');
          requireReturnCompatibility(targetType, 'return_call');
          markPolymorphic();

        case Opcodes.callIndirect:
          final typeIndex = instruction.immediate!;
          final tableIndex = instruction.secondaryImmediate!;
          final targetType = module.types[typeIndex];
          popExpected(tableIndexSignature(tableIndex), 'call_indirect table');
          popCallArgs(targetType, 'call_indirect');
          pushCallResults(targetType);

        case Opcodes.returnCallIndirect:
          final typeIndex = instruction.immediate!;
          final tableIndex = instruction.secondaryImmediate!;
          final targetType = module.types[typeIndex];
          popExpected(
            tableIndexSignature(tableIndex),
            'return_call_indirect table',
          );
          popCallArgs(targetType, 'return_call_indirect');
          requireReturnCompatibility(targetType, 'return_call_indirect');
          markPolymorphic();

        case Opcodes.callRef:
          final typeIndex = instruction.immediate!;
          final targetType = module.types[typeIndex];
          popCallRefCallee(typeIndex, 'call_ref callee');
          popCallArgs(targetType, 'call_ref');
          pushCallResults(targetType);

        case Opcodes.returnCallRef:
          final typeIndex = instruction.immediate!;
          final targetType = module.types[typeIndex];
          popCallRefCallee(typeIndex, 'return_call_ref callee');
          popCallArgs(targetType, 'return_call_ref');
          requireReturnCompatibility(targetType, 'return_call_ref');
          markPolymorphic();

        case Opcodes.localGet:
          final localIndex = instruction.immediate!;
          if (localIndex < 0 || localIndex >= locals.length) {
            mismatch('local.get index out of range: $localIndex');
          }
          stack.add(locals[localIndex]);

        case Opcodes.localSet:
          final localIndex = instruction.immediate!;
          if (localIndex < 0 || localIndex >= locals.length) {
            mismatch('local.set index out of range: $localIndex');
          }
          popExpected(locals[localIndex], 'local.set value');

        case Opcodes.localTee:
          final localIndex = instruction.immediate!;
          if (localIndex < 0 || localIndex >= locals.length) {
            mismatch('local.tee index out of range: $localIndex');
          }
          final actual = popExpected(locals[localIndex], 'local.tee value');
          stack.add(actual);

        case Opcodes.globalGet:
          final globalIndex = instruction.immediate!;
          final importedGlobals = module.imports
              .where((i) => i.kind == WasmImportKind.global)
              .toList(growable: false);
          final totalGlobals = importedGlobals.length + module.globals.length;
          if (globalIndex < 0 || globalIndex >= totalGlobals) {
            mismatch('global.get index out of range: $globalIndex');
          }
          if (globalIndex < importedGlobals.length) {
            final type = importedGlobals[globalIndex].globalType;
            if (type == null) {
              mismatch('global.get malformed import');
            }
            stack.add(
              type.valueTypeSignature != null &&
                      type.valueTypeSignature!.isNotEmpty
                  ? type.valueTypeSignature!
                  : _signatureForValueType(type.valueType),
            );
          } else {
            final localGlobal = module.globals[globalIndex - importedGlobals.length];
            final type = localGlobal.type;
            stack.add(
              type.valueTypeSignature != null &&
                      type.valueTypeSignature!.isNotEmpty
                  ? type.valueTypeSignature!
                  : _signatureForValueType(type.valueType),
            );
          }

        case Opcodes.globalSet:
          final globalIndex = instruction.immediate!;
          final importedGlobals = module.imports
              .where((i) => i.kind == WasmImportKind.global)
              .toList(growable: false);
          final totalGlobals = importedGlobals.length + module.globals.length;
          if (globalIndex < 0 || globalIndex >= totalGlobals) {
            mismatch('global.set index out of range: $globalIndex');
          }
          if (globalIndex < importedGlobals.length) {
            final type = importedGlobals[globalIndex].globalType;
            if (type == null) {
              mismatch('global.set malformed import');
            }
            popExpected(
              type.valueTypeSignature != null &&
                      type.valueTypeSignature!.isNotEmpty
                  ? type.valueTypeSignature!
                  : _signatureForValueType(type.valueType),
              'global.set value',
            );
          } else {
            final localGlobal = module.globals[globalIndex - importedGlobals.length];
            final type = localGlobal.type;
            popExpected(
              type.valueTypeSignature != null && type.valueTypeSignature!.isNotEmpty
                  ? type.valueTypeSignature!
                  : _signatureForValueType(type.valueType),
              'global.set value',
            );
          }

        case Opcodes.refNull:
          final gcRefType = instruction.gcRefType;
          if (gcRefType != null) {
            stack.add(_gcRefTypeToSignature(gcRefType));
          } else {
            stack.add(_refNullSignature(instruction.immediate!));
          }

        case Opcodes.refFunc:
          final functionIndex = instruction.immediate!;
          final typeIndex = _functionTypeIndexForFunction(module, functionIndex);
          stack.add(
            _encodeRefSignature(
              nullable: false,
              exact: false,
              heapType: typeIndex,
            ),
          );

        case Opcodes.refAsNonNull:
          stack.add(
            makeNonNullableReference(popReference('ref.as_non_null input'), 'ref.as_non_null input'),
          );

        case Opcodes.drop:
          popAny('drop');

        case Opcodes.select:
        case Opcodes.selectT:
          popExpected('7f', 'select condition');
          final rhs = popAny('select rhs');
          final lhs = popAny('select lhs');
          if (!_isValueSignatureSubtype(module, lhs, rhs) &&
              !_isValueSignatureSubtype(module, rhs, lhs)) {
            mismatch('select operand type mismatch: lhs=$lhs rhs=$rhs');
          }
          stack.add(
            _isValueSignatureSubtype(module, lhs, rhs) ? rhs : lhs,
          );

        case Opcodes.i32Const:
          stack.add('7f');
        case Opcodes.i64Const:
          stack.add('7e');
        case Opcodes.f32Const:
          stack.add('7d');
        case Opcodes.f64Const:
          stack.add('7c');

        case Opcodes.i32Load:
        case Opcodes.i32Load8S:
        case Opcodes.i32Load8U:
        case Opcodes.i32Load16S:
        case Opcodes.i32Load16U:
          popExpected(addressSignatureForMemArg(instruction.memArg), 'i32.load');
          stack.add('7f');
        case Opcodes.i64Load:
        case Opcodes.i64Load8S:
        case Opcodes.i64Load8U:
        case Opcodes.i64Load16S:
        case Opcodes.i64Load16U:
        case Opcodes.i64Load32S:
        case Opcodes.i64Load32U:
          popExpected(addressSignatureForMemArg(instruction.memArg), 'i64.load');
          stack.add('7e');
        case Opcodes.f32Load:
          popExpected(addressSignatureForMemArg(instruction.memArg), 'f32.load');
          stack.add('7d');
        case Opcodes.f64Load:
          popExpected(addressSignatureForMemArg(instruction.memArg), 'f64.load');
          stack.add('7c');

        case Opcodes.i32Store:
        case Opcodes.i32Store8:
        case Opcodes.i32Store16:
          popExpected('7f', 'i32.store value');
          popExpected(addressSignatureForMemArg(instruction.memArg), 'i32.store address');
        case Opcodes.i64Store:
        case Opcodes.i64Store8:
        case Opcodes.i64Store16:
        case Opcodes.i64Store32:
          popExpected('7e', 'i64.store value');
          popExpected(addressSignatureForMemArg(instruction.memArg), 'i64.store address');
        case Opcodes.f32Store:
          popExpected('7d', 'f32.store value');
          popExpected(addressSignatureForMemArg(instruction.memArg), 'f32.store address');
        case Opcodes.f64Store:
          popExpected('7c', 'f64.store value');
          popExpected(addressSignatureForMemArg(instruction.memArg), 'f64.store address');

        case Opcodes.memorySize:
          stack.add(addressSignatureForMemoryIndex(instruction.immediate ?? 0));
        case Opcodes.memoryGrow:
          final address = addressSignatureForMemoryIndex(instruction.immediate ?? 0);
          popExpected(address, 'memory.grow delta');
          stack.add(address);

        case Opcodes.i32Eqz:
          unary('7f', '7f', 'i32.eqz');
        case Opcodes.i64Eqz:
          unary('7e', '7f', 'i64.eqz');

        case Opcodes.i32Eq:
        case Opcodes.i32Ne:
        case Opcodes.i32LtS:
        case Opcodes.i32LtU:
        case Opcodes.i32GtS:
        case Opcodes.i32GtU:
        case Opcodes.i32LeS:
        case Opcodes.i32LeU:
        case Opcodes.i32GeS:
        case Opcodes.i32GeU:
          binary('7f', '7f', 'i32.compare');

        case Opcodes.i64Eq:
        case Opcodes.i64Ne:
        case Opcodes.i64LtS:
        case Opcodes.i64LtU:
        case Opcodes.i64GtS:
        case Opcodes.i64GtU:
        case Opcodes.i64LeS:
        case Opcodes.i64LeU:
        case Opcodes.i64GeS:
        case Opcodes.i64GeU:
          binary('7e', '7f', 'i64.compare');

        case Opcodes.f32Eq:
        case Opcodes.f32Ne:
        case Opcodes.f32Lt:
        case Opcodes.f32Gt:
        case Opcodes.f32Le:
        case Opcodes.f32Ge:
          binary('7d', '7f', 'f32.compare');

        case Opcodes.f64Eq:
        case Opcodes.f64Ne:
        case Opcodes.f64Lt:
        case Opcodes.f64Gt:
        case Opcodes.f64Le:
        case Opcodes.f64Ge:
          binary('7c', '7f', 'f64.compare');

        case Opcodes.i32Clz:
        case Opcodes.i32Ctz:
        case Opcodes.i32Popcnt:
        case Opcodes.i32Extend8S:
        case Opcodes.i32Extend16S:
          unary('7f', '7f', 'i32.unary');

        case Opcodes.i64Clz:
        case Opcodes.i64Ctz:
        case Opcodes.i64Popcnt:
        case Opcodes.i64Extend8S:
        case Opcodes.i64Extend16S:
        case Opcodes.i64Extend32S:
          unary('7e', '7e', 'i64.unary');

        case Opcodes.f32Abs:
        case Opcodes.f32Neg:
        case Opcodes.f32Ceil:
        case Opcodes.f32Floor:
        case Opcodes.f32Trunc:
        case Opcodes.f32Nearest:
        case Opcodes.f32Sqrt:
          unary('7d', '7d', 'f32.unary');

        case Opcodes.f64Abs:
        case Opcodes.f64Neg:
        case Opcodes.f64Ceil:
        case Opcodes.f64Floor:
        case Opcodes.f64Trunc:
        case Opcodes.f64Nearest:
        case Opcodes.f64Sqrt:
          unary('7c', '7c', 'f64.unary');

        case Opcodes.i32Add:
        case Opcodes.i32Sub:
        case Opcodes.i32Mul:
        case Opcodes.i32DivS:
        case Opcodes.i32DivU:
        case Opcodes.i32RemS:
        case Opcodes.i32RemU:
        case Opcodes.i32And:
        case Opcodes.i32Or:
        case Opcodes.i32Xor:
        case Opcodes.i32Shl:
        case Opcodes.i32ShrS:
        case Opcodes.i32ShrU:
        case Opcodes.i32Rotl:
        case Opcodes.i32Rotr:
          binary('7f', '7f', 'i32.binary');

        case Opcodes.i64Add:
        case Opcodes.i64Sub:
        case Opcodes.i64Mul:
        case Opcodes.i64DivS:
        case Opcodes.i64DivU:
        case Opcodes.i64RemS:
        case Opcodes.i64RemU:
        case Opcodes.i64And:
        case Opcodes.i64Or:
        case Opcodes.i64Xor:
        case Opcodes.i64Shl:
        case Opcodes.i64ShrS:
        case Opcodes.i64ShrU:
        case Opcodes.i64Rotl:
        case Opcodes.i64Rotr:
          binary('7e', '7e', 'i64.binary');

        case Opcodes.f32Add:
        case Opcodes.f32Sub:
        case Opcodes.f32Mul:
        case Opcodes.f32Div:
        case Opcodes.f32Min:
        case Opcodes.f32Max:
        case Opcodes.f32CopySign:
          binary('7d', '7d', 'f32.binary');

        case Opcodes.f64Add:
        case Opcodes.f64Sub:
        case Opcodes.f64Mul:
        case Opcodes.f64Div:
        case Opcodes.f64Min:
        case Opcodes.f64Max:
        case Opcodes.f64CopySign:
          binary('7c', '7c', 'f64.binary');

        case Opcodes.i32WrapI64:
          unary('7e', '7f', 'i32.wrap_i64');
        case Opcodes.i32TruncF32S:
        case Opcodes.i32TruncF32U:
        case Opcodes.i32TruncSatF32S:
        case Opcodes.i32TruncSatF32U:
          unary('7d', '7f', 'i32.trunc_f32');
        case Opcodes.i32TruncF64S:
        case Opcodes.i32TruncF64U:
        case Opcodes.i32TruncSatF64S:
        case Opcodes.i32TruncSatF64U:
          unary('7c', '7f', 'i32.trunc_f64');
        case Opcodes.i64ExtendI32S:
        case Opcodes.i64ExtendI32U:
          unary('7f', '7e', 'i64.extend_i32');
        case Opcodes.i64TruncF32S:
        case Opcodes.i64TruncF32U:
        case Opcodes.i64TruncSatF32S:
        case Opcodes.i64TruncSatF32U:
          unary('7d', '7e', 'i64.trunc_f32');
        case Opcodes.i64TruncF64S:
        case Opcodes.i64TruncF64U:
        case Opcodes.i64TruncSatF64S:
        case Opcodes.i64TruncSatF64U:
          unary('7c', '7e', 'i64.trunc_f64');
        case Opcodes.f32ConvertI32S:
        case Opcodes.f32ConvertI32U:
          unary('7f', '7d', 'f32.convert_i32');
        case Opcodes.f32ConvertI64S:
        case Opcodes.f32ConvertI64U:
          unary('7e', '7d', 'f32.convert_i64');
        case Opcodes.f32DemoteF64:
          unary('7c', '7d', 'f32.demote_f64');
        case Opcodes.f64ConvertI32S:
        case Opcodes.f64ConvertI32U:
          unary('7f', '7c', 'f64.convert_i32');
        case Opcodes.f64ConvertI64S:
        case Opcodes.f64ConvertI64U:
          unary('7e', '7c', 'f64.convert_i64');
        case Opcodes.f64PromoteF32:
          unary('7d', '7c', 'f64.promote_f32');
        case Opcodes.i32ReinterpretF32:
          unary('7d', '7f', 'i32.reinterpret_f32');
        case Opcodes.i64ReinterpretF64:
          unary('7c', '7e', 'i64.reinterpret_f64');
        case Opcodes.f32ReinterpretI32:
          unary('7f', '7d', 'f32.reinterpret_i32');
        case Opcodes.f64ReinterpretI64:
          unary('7e', '7c', 'f64.reinterpret_i64');

        case Opcodes.nop:
          break;

        default:
          // Keep this pass lightweight. If unsupported forms are present,
          // rely on dedicated validators and runtime checks.
          return;
      }
    }

    mismatch('function ended without final end');
  }

  static void _validateArrayInstructionTyping({
    required WasmModule module,
    required WasmFunctionType functionType,
    required WasmCodeBody body,
    required List<Instruction> instructions,
  }) {
    var hasArrayOps = false;
    for (final instruction in instructions) {
      switch (instruction.opcode) {
        case Opcodes.arrayNew:
        case Opcodes.arrayNewDefault:
        case Opcodes.arrayNewFixed:
        case Opcodes.arrayNewData:
        case Opcodes.arrayNewElem:
        case Opcodes.arrayGet:
        case Opcodes.arrayGetS:
        case Opcodes.arrayGetU:
        case Opcodes.arraySet:
        case Opcodes.arrayInitData:
        case Opcodes.arrayInitElem:
        case Opcodes.arrayCopy:
        case Opcodes.arrayFill:
          hasArrayOps = true;
          break;
      }
      if (hasArrayOps) {
        break;
      }
    }
    if (!hasArrayOps) {
      return;
    }

    Never mismatch([String? reason]) {
      assert(reason == null || reason.isNotEmpty);
      if (reason == null || reason.isEmpty) {
        throw const FormatException('Validation failed: type mismatch.');
      }
      throw FormatException('Validation failed: type mismatch ($reason).');
    }

    String arrayRefResult(int typeIndex) {
      return _encodeRefSignature(
        nullable: false,
        exact: false,
        heapType: typeIndex,
      );
    }

    String arrayRefOperand(int typeIndex) {
      return _encodeRefSignature(
        nullable: true,
        exact: false,
        heapType: typeIndex,
      );
    }

    String fieldValueStackSignature(String fieldSignature) {
      final parsed = _parseFieldSignature(fieldSignature);
      if (parsed == null) {
        mismatch('invalid field signature: $fieldSignature');
      }
      final value = parsed.valueSignature;
      if (value == '78' || value == '77') {
        return '7f';
      }
      return value;
    }

    void requirePopSubtype(List<String> stack, String expected, String label) {
      if (stack.isEmpty) {
        mismatch('$label stack underflow');
      }
      final actual = stack.removeLast();
      if (_parseRefSignature(expected) != null &&
          actual == '7f' &&
          label.endsWith(' array')) {
        // Local signatures in this lightweight pass are i32-only and can lose
        // precise ref-nullability/type-index information.
        return;
      }
      if (!_isValueSignatureSubtype(module, actual, expected)) {
        mismatch('$label expected=$expected actual=$actual');
      }
    }

    final locals = <String>[
      ..._functionParamSignatures(functionType),
      ..._localSignatures(body),
    ];
    final stack = <String>[];

    for (final instruction in instructions) {
      switch (instruction.opcode) {
        case Opcodes.localGet:
          final localIndex = instruction.immediate!;
          if (localIndex < 0 || localIndex >= locals.length) {
            mismatch('local.get index out of range: $localIndex');
          }
          stack.add(locals[localIndex]);

        case Opcodes.i32Const:
          stack.add('7f');

        case Opcodes.i64Const:
          stack.add('7e');

        case Opcodes.f32Const:
          stack.add('7d');

        case Opcodes.f64Const:
          stack.add('7c');

        case Opcodes.refNull:
          final gcRefType = instruction.gcRefType;
          if (gcRefType != null) {
            stack.add(_gcRefTypeToSignature(gcRefType));
          } else {
            stack.add(_refNullSignature(instruction.immediate!));
          }

        case Opcodes.drop:
          if (stack.isEmpty) {
            mismatch('drop stack underflow');
          }
          stack.removeLast();

        case Opcodes.arrayNew:
          final typeIndex = instruction.immediate!;
          final type = module.types[typeIndex];
          requirePopSubtype(
            stack,
            fieldValueStackSignature(type.fieldSignatures.single),
            'array.new value',
          );
          requirePopSubtype(stack, '7f', 'array.new length');
          stack.add(arrayRefResult(typeIndex));

        case Opcodes.arrayNewDefault:
          final typeIndex = instruction.immediate!;
          requirePopSubtype(stack, '7f', 'array.new_default length');
          stack.add(arrayRefResult(typeIndex));

        case Opcodes.arrayNewFixed:
          final typeIndex = instruction.immediate!;
          final type = module.types[typeIndex];
          final fieldSig = fieldValueStackSignature(type.fieldSignatures.single);
          final count = instruction.secondaryImmediate!;
          for (var i = 0; i < count; i++) {
            requirePopSubtype(
              stack,
              fieldSig,
              'array.new_fixed value[$i]',
            );
          }
          stack.add(arrayRefResult(typeIndex));

        case Opcodes.arrayNewData:
          final typeIndex = instruction.immediate!;
          requirePopSubtype(stack, '7f', 'array.new_data length');
          requirePopSubtype(stack, '7f', 'array.new_data source offset');
          stack.add(arrayRefResult(typeIndex));

        case Opcodes.arrayNewElem:
          final typeIndex = instruction.immediate!;
          requirePopSubtype(stack, '7f', 'array.new_elem length');
          requirePopSubtype(stack, '7f', 'array.new_elem source offset');
          stack.add(arrayRefResult(typeIndex));

        case Opcodes.arrayGet:
          final typeIndex = instruction.immediate!;
          final type = module.types[typeIndex];
          final parsed = _parseFieldSignature(type.fieldSignatures.single);
          if (parsed == null) {
            mismatch('array.get invalid field signature');
          }
          requirePopSubtype(stack, '7f', 'array.get index');
          requirePopSubtype(stack, arrayRefOperand(typeIndex), 'array.get array');
          stack.add(parsed.valueSignature);

        case Opcodes.arrayGetS:
        case Opcodes.arrayGetU:
          final typeIndex = instruction.immediate!;
          requirePopSubtype(stack, '7f', 'array.get_* index');
          requirePopSubtype(
            stack,
            arrayRefOperand(typeIndex),
            'array.get_* array',
          );
          stack.add('7f');

        case Opcodes.arraySet:
          final typeIndex = instruction.immediate!;
          final type = module.types[typeIndex];
          requirePopSubtype(
            stack,
            fieldValueStackSignature(type.fieldSignatures.single),
            'array.set value',
          );
          requirePopSubtype(stack, '7f', 'array.set index');
          requirePopSubtype(stack, arrayRefOperand(typeIndex), 'array.set array');

        case Opcodes.arrayInitData:
          final typeIndex = instruction.immediate!;
          requirePopSubtype(stack, '7f', 'array.init_data length');
          requirePopSubtype(stack, '7f', 'array.init_data source offset');
          requirePopSubtype(stack, '7f', 'array.init_data destination offset');
          requirePopSubtype(
            stack,
            arrayRefOperand(typeIndex),
            'array.init_data array',
          );

        case Opcodes.arrayInitElem:
          final typeIndex = instruction.immediate!;
          requirePopSubtype(stack, '7f', 'array.init_elem length');
          requirePopSubtype(stack, '7f', 'array.init_elem source offset');
          requirePopSubtype(stack, '7f', 'array.init_elem destination offset');
          requirePopSubtype(
            stack,
            arrayRefOperand(typeIndex),
            'array.init_elem array',
          );

        case Opcodes.arrayCopy:
          final destinationTypeIndex = instruction.immediate!;
          final sourceTypeIndex = instruction.secondaryImmediate!;
          requirePopSubtype(stack, '7f', 'array.copy length');
          requirePopSubtype(stack, '7f', 'array.copy source offset');
          requirePopSubtype(
            stack,
            arrayRefOperand(sourceTypeIndex),
            'array.copy source array',
          );
          requirePopSubtype(stack, '7f', 'array.copy destination offset');
          requirePopSubtype(
            stack,
            arrayRefOperand(destinationTypeIndex),
            'array.copy destination array',
          );

        case Opcodes.arrayFill:
          final typeIndex = instruction.immediate!;
          final type = module.types[typeIndex];
          requirePopSubtype(stack, '7f', 'array.fill length');
          requirePopSubtype(
            stack,
            fieldValueStackSignature(type.fieldSignatures.single),
            'array.fill value',
          );
          requirePopSubtype(stack, '7f', 'array.fill destination offset');
          requirePopSubtype(
            stack,
            arrayRefOperand(typeIndex),
            'array.fill array',
          );

        case Opcodes.end:
          break;

        default:
          return;
      }
    }

    final expectedResults = _functionResultSignatures(functionType);
    if (expectedResults.any((signature) => _parseRefSignature(signature) != null)) {
      return;
    }
    if (stack.length != functionType.results.length) {
      throw const FormatException('Validation failed: type mismatch.');
    }
    for (var i = 0; i < expectedResults.length; i++) {
      if (!_isValueSignatureSubtype(module, stack[i], expectedResults[i])) {
        throw const FormatException('Validation failed: type mismatch.');
      }
    }
  }

  static void _validateWideArithmeticStack({
    required WasmFunctionType functionType,
    required WasmCodeBody body,
    required List<Instruction> instructions,
  }) {
    final locals = <WasmValueType>[...functionType.params];
    for (final local in body.locals) {
      final localType = local.type;
      for (var i = 0; i < local.count; i++) {
        locals.add(localType);
      }
    }

    final stack = <WasmValueType>[];

    void popI64(String context, int count) {
      for (var i = 0; i < count; i++) {
        if (stack.isEmpty) {
          throw FormatException('Validation failed: type mismatch ($context).');
        }
        final type = stack.removeLast();
        if (type != WasmValueType.i64) {
          throw FormatException('Validation failed: type mismatch ($context).');
        }
      }
    }

    for (final instruction in instructions) {
      switch (instruction.opcode) {
        case Opcodes.localGet:
          final index = instruction.immediate!;
          _checkIndex(index, locals.length, 'local');
          stack.add(locals[index]);

        case Opcodes.i64Const:
          stack.add(WasmValueType.i64);

        case Opcodes.drop:
          if (stack.isEmpty) {
            throw const FormatException('Validation failed: drop underflow.');
          }
          stack.removeLast();

        case Opcodes.i64Add128:
        case Opcodes.i64Sub128:
          popI64('i64.add128/i64.sub128', 4);
          stack
            ..add(WasmValueType.i64)
            ..add(WasmValueType.i64);

        case Opcodes.i64MulWideS:
        case Opcodes.i64MulWideU:
          popI64('i64.mul_wide_*', 2);
          stack
            ..add(WasmValueType.i64)
            ..add(WasmValueType.i64);

        case Opcodes.end:
          // End has no stack effect for this lightweight pass.
          break;

        default:
          // Skip full type-checking when this function uses unsupported forms.
          return;
      }
    }

    if (stack.length != functionType.results.length) {
      throw const FormatException('Validation failed: type mismatch.');
    }
    for (var i = 0; i < functionType.results.length; i++) {
      if (stack[i] != functionType.results[i]) {
        throw const FormatException('Validation failed: type mismatch.');
      }
    }
  }

  static void _validateBrOnCastTyping({
    required WasmModule module,
    required WasmFunctionType functionType,
    required WasmCodeBody body,
    required List<Instruction> instructions,
  }) {
    var hasReferenceTypingOps = false;
    for (final instruction in instructions) {
      switch (instruction.opcode) {
        case Opcodes.brOnCast:
        case Opcodes.brOnCastFail:
        case Opcodes.brOnCastDescEq:
        case Opcodes.brOnCastDescEqFail:
        case Opcodes.refAsNonNull:
        case Opcodes.refGetDesc:
        case Opcodes.refCastDesc:
        case Opcodes.refCastDescEq:
        case Opcodes.structNew:
        case Opcodes.structNewDefault:
        case Opcodes.structNewDesc:
        case Opcodes.structNewDefaultDesc:
          hasReferenceTypingOps = true;
          break;
      }
      if (hasReferenceTypingOps) {
        break;
      }
    }
    if (!hasReferenceTypingOps) {
      return;
    }

    Never mismatch([String? reason]) {
      assert(reason == null || reason.isNotEmpty);
      if (reason == null || reason.isEmpty) {
        throw const FormatException('Validation failed: type mismatch.');
      }
      throw FormatException('Validation failed: type mismatch ($reason).');
    }

    String fieldValueStackSignature(String fieldSignature) {
      final parsed = _parseFieldSignature(fieldSignature);
      if (parsed == null) {
        mismatch('invalid field signature: $fieldSignature');
      }
      final value = parsed.valueSignature;
      if (value == '78' || value == '77') {
        return '7f';
      }
      return value;
    }

    ({int typeIndex, int descriptorTypeIndex}) requireDescriptorTargetHeap(
      int heapType,
    ) {
      if (heapType < 0 || heapType >= module.types.length) {
        mismatch('descriptor target heap must be concrete type: $heapType');
      }
      final targetType = module.types[heapType];
      final descriptorTypeIndex = targetType.descriptorTypeIndex;
      if (descriptorTypeIndex == null) {
        mismatch('target type without descriptor: $heapType');
      }
      return (typeIndex: heapType, descriptorTypeIndex: descriptorTypeIndex);
    }

    String brOnCastFailureSignature(
      String sourceSignature,
      GcRefTypeImmediate targetType,
    ) {
      final sourceRef = _parseRefSignature(sourceSignature);
      if (sourceRef == null) {
        return sourceSignature;
      }
      if (sourceRef.nullable && targetType.nullable) {
        return _encodeRefSignature(
          nullable: false,
          exact: sourceRef.exact,
          heapType: sourceRef.heapType,
        );
      }
      return sourceSignature;
    }

    final locals = <String>[
      ..._functionParamSignatures(functionType),
      ..._localSignatures(body),
    ];
    final stack = <String>[];
    final controlStack = <_ReferenceControlFrame>[
      _ReferenceControlFrame(
        stackHeight: 0,
        resultSignatures: _functionResultSignatures(functionType),
      ),
    ];

    for (final instruction in instructions) {
      final currentFrame = controlStack.last;
      final inPolymorphicContext = currentFrame.polymorphic;
      switch (instruction.opcode) {
        case Opcodes.localGet:
          if (inPolymorphicContext) {
            break;
          }
          final localIndex = instruction.immediate!;
          if (localIndex < 0 || localIndex >= locals.length) {
            mismatch('local.get index out of range: $localIndex');
          }
          stack.add(locals[localIndex]);

        case Opcodes.refNull:
          if (inPolymorphicContext) {
            break;
          }
          final gcRefType = instruction.gcRefType;
          if (gcRefType != null) {
            stack.add(_gcRefTypeToSignature(gcRefType));
          } else {
            stack.add(_refNullSignature(instruction.immediate!));
          }

        case Opcodes.i32Const:
          if (inPolymorphicContext) {
            break;
          }
          stack.add('7f');

        case Opcodes.i64Const:
          if (inPolymorphicContext) {
            break;
          }
          stack.add('7e');

        case Opcodes.f32Const:
          if (inPolymorphicContext) {
            break;
          }
          stack.add('7d');

        case Opcodes.f64Const:
          if (inPolymorphicContext) {
            break;
          }
          stack.add('7c');

        case Opcodes.block:
        case Opcodes.loop:
        case Opcodes.if_:
          final signatures = instruction.blockResultTypeSignatures;
          if (signatures == null) {
            return;
          }
          controlStack.add(
            _ReferenceControlFrame(
              stackHeight: stack.length,
              resultSignatures: List<String>.from(signatures),
              polymorphic: inPolymorphicContext,
            ),
          );

        case Opcodes.brOnCast:
        case Opcodes.brOnCastFail:
          final brOnCast = instruction.gcBrOnCast;
          if (brOnCast == null) {
            mismatch('missing br_on_cast immediate');
          }
          final sourceSignature = _gcRefTypeToSignature(brOnCast.sourceType);
          late final String operandSignature;
          if (inPolymorphicContext) {
            operandSignature = sourceSignature;
          } else {
            if (stack.isEmpty) {
              mismatch('br_on_cast stack underflow');
            }
            operandSignature = stack.removeLast();
          }
          final targetSignature = _gcRefTypeToSignature(brOnCast.targetType);
          final failureSignature = brOnCastFailureSignature(
            sourceSignature,
            brOnCast.targetType,
          );
          if (!brOnCast.sourceType.nullable && brOnCast.targetType.nullable) {
            mismatch('invalid nullability: non-null source to nullable target');
          }
          if (!_isValueSignatureSubtype(
            module,
            targetSignature,
            sourceSignature,
          )) {
            mismatch(
              'target/source mismatch: target=$targetSignature source=$sourceSignature',
            );
          }

          if (!inPolymorphicContext &&
              !_isValueSignatureSubtype(
                module,
                operandSignature,
                sourceSignature,
              )) {
            mismatch(
              'operand/source mismatch: operand=$operandSignature source=$sourceSignature',
            );
          }

          if (!_isHeapCastCompatible(
            module,
            brOnCast.sourceType.heapType,
            brOnCast.targetType.heapType,
          )) {
            mismatch(
              'heap mismatch: target=${brOnCast.targetType.heapType} source=${brOnCast.sourceType.heapType}',
            );
          }

          final depth = brOnCast.depth;
          if (depth < 0 || depth >= controlStack.length) {
            mismatch('branch depth out of range: $depth');
          }
          final labelFrame = controlStack[controlStack.length - 1 - depth];
          final branchSignature = instruction.opcode == Opcodes.brOnCast
              ? targetSignature
              : failureSignature;
          if (!_matchesLabelResultWithBranchValue(
            module: module,
            stack: stack,
            labelResultSignatures: labelFrame.resultSignatures,
            branchSignature: branchSignature,
            allowUnknownPrefix: inPolymorphicContext,
          )) {
            mismatch(
              'label result mismatch: label=${labelFrame.resultSignatures} branch=$branchSignature',
            );
          }

          final fallthroughSignature = instruction.opcode == Opcodes.brOnCast
              ? failureSignature
              : targetSignature;
          if (!inPolymorphicContext) {
            final labelPrefixLength = labelFrame.resultSignatures.length - 1;
            if (labelPrefixLength < 0 || stack.length < labelPrefixLength) {
              mismatch('label prefix underflow for br_on_cast');
            }
            if (labelPrefixLength > 0) {
              stack.length -= labelPrefixLength;
              stack.addAll(
                labelFrame.resultSignatures.sublist(0, labelPrefixLength),
              );
            }
            stack.add(fallthroughSignature);
          }

        case Opcodes.brOnCastDescEq:
        case Opcodes.brOnCastDescEqFail:
          final brOnCast = instruction.gcBrOnCast;
          if (brOnCast == null) {
            mismatch('missing br_on_cast_desc_eq immediate');
          }
          final descriptorTarget = requireDescriptorTargetHeap(
            brOnCast.targetType.heapType,
          );
          final expectedDescriptorSignature = _encodeRefSignature(
            nullable: true,
            exact: brOnCast.targetType.exact,
            heapType: descriptorTarget.descriptorTypeIndex,
          );
          final sourceSignature = _gcRefTypeToSignature(brOnCast.sourceType);
          final targetSignature = _gcRefTypeToSignature(brOnCast.targetType);
          final failureSignature = brOnCastFailureSignature(
            sourceSignature,
            brOnCast.targetType,
          );
          late final String descriptorSignature;
          late final String operandSignature;
          if (inPolymorphicContext) {
            descriptorSignature = expectedDescriptorSignature;
            operandSignature = sourceSignature;
          } else {
            if (stack.length < 2) {
              mismatch('br_on_cast_desc_eq stack underflow');
            }
            descriptorSignature = stack.removeLast();
            operandSignature = stack.removeLast();
          }

          if (!inPolymorphicContext &&
              !_isValueSignatureSubtype(
                module,
                descriptorSignature,
                expectedDescriptorSignature,
              )) {
            mismatch(
              'descriptor mismatch: descriptor=$descriptorSignature expected=$expectedDescriptorSignature',
            );
          }
          if (!inPolymorphicContext &&
              !_isValueSignatureSubtype(
                module,
                operandSignature,
                sourceSignature,
              )) {
            mismatch(
              'operand/source mismatch: operand=$operandSignature source=$sourceSignature',
            );
          }
          if (!_isHeapCastCompatible(
            module,
            brOnCast.sourceType.heapType,
            brOnCast.targetType.heapType,
          )) {
            mismatch(
              'heap mismatch: target=${brOnCast.targetType.heapType} source=${brOnCast.sourceType.heapType}',
            );
          }

          final depth = brOnCast.depth;
          if (depth < 0 || depth >= controlStack.length) {
            mismatch('branch depth out of range: $depth');
          }
          final labelFrame = controlStack[controlStack.length - 1 - depth];
          final branchSignature =
              instruction.opcode == Opcodes.brOnCastDescEq
              ? targetSignature
              : failureSignature;
          if (!_matchesLabelResultWithBranchValue(
            module: module,
            stack: stack,
            labelResultSignatures: labelFrame.resultSignatures,
            branchSignature: branchSignature,
            allowUnknownPrefix: inPolymorphicContext,
          )) {
            mismatch(
              'label result mismatch: label=${labelFrame.resultSignatures} branch=$branchSignature',
            );
          }

          final fallthroughSignature =
              instruction.opcode == Opcodes.brOnCastDescEq
              ? failureSignature
              : targetSignature;
          if (!inPolymorphicContext) {
            final labelPrefixLength = labelFrame.resultSignatures.length - 1;
            if (labelPrefixLength < 0 || stack.length < labelPrefixLength) {
              mismatch('label prefix underflow for br_on_cast_desc_eq');
            }
            if (labelPrefixLength > 0) {
              stack.length -= labelPrefixLength;
              stack.addAll(
                labelFrame.resultSignatures.sublist(0, labelPrefixLength),
              );
            }
          }
          stack.add(fallthroughSignature);

        case Opcodes.refEq:
          if (stack.length >= 2) {
            final rhs = stack.removeLast();
            final lhs = stack.removeLast();
            if (_parseRefSignature(lhs) == null || _parseRefSignature(rhs) == null) {
              mismatch('ref.eq requires reference operands');
            }
          } else if (!inPolymorphicContext) {
            mismatch('ref.eq stack underflow');
          }
          stack.add('7f');

        case Opcodes.structNew:
        case Opcodes.structNewDefault:
        case Opcodes.structNewDesc:
        case Opcodes.structNewDefaultDesc:
          final typeIndex = instruction.immediate;
          if (typeIndex == null ||
              typeIndex < 0 ||
              typeIndex >= module.types.length) {
            mismatch('invalid struct type index for allocation: $typeIndex');
          }
          final type = module.types[typeIndex];
          if (type.kind != WasmCompositeTypeKind.struct) {
            mismatch('allocation target must be struct type: $typeIndex');
          }
          final hasDescriptor = type.descriptorTypeIndex != null;
          final usesDescriptorAllocation =
              instruction.opcode == Opcodes.structNewDesc ||
              instruction.opcode == Opcodes.structNewDefaultDesc;
          if (hasDescriptor != usesDescriptorAllocation) {
            mismatch('descriptor allocation form mismatch');
          }
          if (inPolymorphicContext) {
            break;
          }
          if (usesDescriptorAllocation) {
            final expectedDescriptorSignature = _encodeRefSignature(
              nullable: true,
              exact: true,
              heapType: type.descriptorTypeIndex!,
            );
            if (stack.isEmpty) {
              mismatch('struct.new_desc descriptor underflow');
            }
            final descriptorSignature = stack.removeLast();
            if (!_isValueSignatureSubtype(
              module,
              descriptorSignature,
              expectedDescriptorSignature,
            )) {
              mismatch(
                'struct descriptor mismatch: descriptor=$descriptorSignature expected=$expectedDescriptorSignature',
              );
            }
          }
          if (instruction.opcode == Opcodes.structNew ||
              instruction.opcode == Opcodes.structNewDesc) {
            for (var fieldIndex = type.fieldSignatures.length - 1;
                fieldIndex >= 0;
                fieldIndex--) {
              if (stack.isEmpty) {
                mismatch('struct.new field underflow');
              }
              final expectedField = fieldValueStackSignature(
                type.fieldSignatures[fieldIndex],
              );
              final actualField = stack.removeLast();
              if (!_isValueSignatureSubtype(
                module,
                actualField,
                expectedField,
              )) {
                mismatch(
                  'struct.new field mismatch: actual=$actualField expected=$expectedField',
                );
              }
            }
          }
          stack.add(
            _encodeRefSignature(
              nullable: false,
              exact: true,
              heapType: typeIndex,
            ),
          );

        case Opcodes.refGetDesc:
          final typeIndex = instruction.immediate;
          if (typeIndex == null ||
              typeIndex < 0 ||
              typeIndex >= module.types.length) {
            mismatch('invalid ref.get_desc type index: $typeIndex');
          }
          final targetType = module.types[typeIndex];
          final descriptorTypeIndex = targetType.descriptorTypeIndex;
          if (descriptorTypeIndex == null) {
            mismatch('ref.get_desc target type has no descriptor');
          }
          if (inPolymorphicContext) {
            break;
          }
          if (stack.isEmpty) {
            mismatch('ref.get_desc stack underflow');
          }
          final inputSignature = stack.removeLast();
          final expectedInput = _encodeRefSignature(
            nullable: true,
            exact: false,
            heapType: typeIndex,
          );
          if (!_isValueSignatureSubtype(module, inputSignature, expectedInput)) {
            mismatch(
              'ref.get_desc input mismatch: input=$inputSignature expected=$expectedInput',
            );
          }
          final inputRef = _parseRefSignature(inputSignature);
          if (inputRef == null) {
            mismatch('ref.get_desc input must be ref: $inputSignature');
          }
          final exactOutput =
              inputRef.heapType == _heapNone ||
              (inputRef.exact && inputRef.heapType == typeIndex);
          stack.add(
            _encodeRefSignature(
              nullable: false,
              exact: exactOutput,
              heapType: descriptorTypeIndex,
            ),
          );

        case Opcodes.refCastDesc:
        case Opcodes.refCastDescEq:
          final targetType = instruction.gcRefType;
          if (targetType == null) {
            mismatch('missing ref.cast_desc_eq immediate');
          }
          final descriptorTarget = requireDescriptorTargetHeap(
            targetType.heapType,
          );
          final targetSignature = _gcRefTypeToSignature(targetType);
          final expectedDescriptorSignature = _encodeRefSignature(
            nullable: true,
            exact: targetType.exact,
            heapType: descriptorTarget.descriptorTypeIndex,
          );
          String descriptorSignature;
          String inputSignature;
          if (stack.length >= 2) {
            descriptorSignature = stack.removeLast();
            inputSignature = stack.removeLast();
          } else if (inPolymorphicContext) {
            descriptorSignature = expectedDescriptorSignature;
            inputSignature = targetSignature;
          } else {
            mismatch('ref.cast_desc_eq stack underflow');
          }
          if (!_isValueSignatureSubtype(
            module,
            descriptorSignature,
            expectedDescriptorSignature,
          )) {
            mismatch(
              'ref.cast_desc_eq descriptor mismatch: descriptor=$descriptorSignature expected=$expectedDescriptorSignature',
            );
          }
          final inputRef = _parseRefSignature(inputSignature);
          if (inputRef == null) {
            mismatch('ref.cast_desc_eq input must be reference');
          }
          if (!_isHeapCastCompatible(
            module,
            inputRef.heapType,
            targetType.heapType,
          )) {
            mismatch(
              'ref.cast_desc_eq source/target mismatch: source=$inputSignature target=$targetSignature',
            );
          }
          stack.add(targetSignature);

        case Opcodes.refAsNonNull:
          if (inPolymorphicContext) {
            break;
          }
          if (stack.isEmpty) {
            mismatch('ref.as_non_null stack underflow');
          }
          final signature = stack.removeLast();
          final ref = _parseRefSignature(signature);
          if (ref == null || !ref.nullable) {
            mismatch('ref.as_non_null requires nullable ref, got $signature');
          }
          stack.add(
            _encodeRefSignature(
              nullable: false,
              exact: ref.exact,
              heapType: ref.heapType,
            ),
          );

        case Opcodes.drop:
          if (inPolymorphicContext) {
            break;
          }
          if (stack.isEmpty) {
            mismatch('drop stack underflow');
          }
          stack.removeLast();

        case Opcodes.call:
          final functionIndex = instruction.immediate;
          if (functionIndex == null) {
            mismatch('missing call immediate');
          }
          final targetType = _functionTypeForIndex(module, functionIndex);
          final params = _functionParamSignatures(targetType);
          for (var i = params.length - 1; i >= 0; i--) {
            if (stack.isEmpty) {
              if (!inPolymorphicContext) {
                mismatch('call arg underflow[$i]');
              }
              continue;
            }
            final actual = stack.removeLast();
            final expected = params[i];
            if (!_isValueSignatureSubtype(module, actual, expected)) {
              mismatch('call arg mismatch[$i]: actual=$actual expected=$expected');
            }
          }
          stack.addAll(_functionResultSignatures(targetType));

        case Opcodes.end:
          if (controlStack.isEmpty) {
            return;
          }
          final frame = controlStack.removeLast();
          final resultLength = frame.resultSignatures.length;
          final hasConcreteStack = stack.length > frame.stackHeight;
          final enforceStackCheck = !frame.polymorphic || hasConcreteStack;
          if (enforceStackCheck &&
              stack.length != frame.stackHeight + resultLength) {
            mismatch(
              'end stack height mismatch: stack=${stack.length} frameBase=${frame.stackHeight} resultLen=$resultLength',
            );
          }
          if (enforceStackCheck) {
            for (var i = 0; i < resultLength; i++) {
              final actual = stack[stack.length - resultLength + i];
              final expected = frame.resultSignatures[i];
              if (!_isValueSignatureSubtype(module, actual, expected)) {
                mismatch(
                  'end result mismatch: actual=$actual expected=$expected index=$i',
                );
              }
            }
          }
          stack.length = frame.stackHeight;
          stack.addAll(frame.resultSignatures);
          if (controlStack.isEmpty) {
            return;
          }

        case Opcodes.unreachable:
          stack.length = currentFrame.stackHeight;
          currentFrame.polymorphic = true;

        case Opcodes.nop:
          break;

        default:
          // Keep this pass narrow. Fall back to the main validator for
          // functions using instructions not modeled here.
          return;
      }
    }
  }

  static bool _matchesLabelResultWithBranchValue({
    required WasmModule module,
    required List<String> stack,
    required List<String> labelResultSignatures,
    required String branchSignature,
    required bool allowUnknownPrefix,
  }) {
    if (labelResultSignatures.isEmpty) {
      return false;
    }
    final lastExpected = labelResultSignatures.last;
    if (!_isValueSignatureSubtype(module, branchSignature, lastExpected)) {
      return false;
    }

    final requiredPrefix = labelResultSignatures.length - 1;
    final availablePrefix = stack.length;
    if (!allowUnknownPrefix && availablePrefix < requiredPrefix) {
      return false;
    }

    final compareCount = availablePrefix < requiredPrefix
        ? availablePrefix
        : requiredPrefix;
    final stackStart = availablePrefix - compareCount;
    final labelStart = requiredPrefix - compareCount;
    for (var i = 0; i < compareCount; i++) {
      final actual = stack[stackStart + i];
      final expected = labelResultSignatures[labelStart + i];
      if (!_isValueSignatureSubtype(module, actual, expected)) {
        return false;
      }
    }
    return true;
  }

  static List<String> _functionParamSignatures(WasmFunctionType functionType) {
    if (functionType.paramTypeSignatures.length == functionType.params.length) {
      return List<String>.from(functionType.paramTypeSignatures);
    }
    return functionType.params
        .map(_signatureForValueType)
        .toList(growable: false);
  }

  static List<String> _functionResultSignatures(WasmFunctionType functionType) {
    if (functionType.resultTypeSignatures.length ==
        functionType.results.length) {
      return List<String>.from(functionType.resultTypeSignatures);
    }
    return functionType.results
        .map(_signatureForValueType)
        .toList(growable: false);
  }

  static List<String> _localSignatures(WasmCodeBody body) {
    final signatures = <String>[];
    for (final local in body.locals) {
      final signature =
          local.typeSignature != null && local.typeSignature!.isNotEmpty
          ? local.typeSignature!
          : _signatureForValueType(local.type);
      for (var i = 0; i < local.count; i++) {
        signatures.add(signature);
      }
    }
    return signatures;
  }

  static String _signatureForValueType(WasmValueType type) {
    return switch (type) {
      WasmValueType.i32 => '7f',
      WasmValueType.i64 => '7e',
      WasmValueType.f32 => '7d',
      WasmValueType.f64 => '7c',
    };
  }

  static String _refNullSignature(int encodedHeapTypeLead) {
    final heapType = _legacyHeapTypeFromRefTypeCode(encodedHeapTypeLead);
    if (heapType != null) {
      return _encodeRefSignature(
        nullable: true,
        exact: false,
        heapType: heapType,
      );
    }
    return _bytesToSignature(<int>[encodedHeapTypeLead & 0xff]);
  }

  static String _gcRefTypeToSignature(GcRefTypeImmediate refType) {
    return _encodeRefSignature(
      nullable: refType.nullable,
      exact: refType.exact,
      heapType: refType.heapType,
    );
  }

  static String _encodeRefSignature({
    required bool nullable,
    required bool exact,
    required int heapType,
  }) {
    final bytes = <int>[nullable ? 0x63 : 0x64];
    if (exact) {
      bytes.add(0x62);
    }
    bytes.addAll(_encodeSignedLeb33(heapType));
    return _bytesToSignature(bytes);
  }

  static List<int> _encodeSignedLeb33(int value) {
    final bytes = <int>[];
    var remaining = BigInt.from(value);
    while (true) {
      var byte = (remaining & BigInt.from(0x7f)).toInt();
      remaining >>= 7;
      final signBitSet = (byte & 0x40) != 0;
      final done =
          (remaining == BigInt.zero && !signBitSet) ||
          (remaining == -BigInt.one && signBitSet);
      if (!done) {
        byte += 0x80;
      }
      bytes.add(byte);
      if (done) {
        break;
      }
    }
    return bytes;
  }

  static int? _legacyHeapTypeFromRefTypeCode(int code) {
    return switch (code & 0xff) {
      0x70 => _heapFunc, // funcref
      0x6f => _heapExtern, // externref
      0x6e => _heapAny, // anyref
      0x6d => _heapEq, // eqref
      0x6b => _heapStruct, // structref
      0x6a => _heapArray, // arrayref
      0x69 => _heapI31, // i31ref
      0x71 => _heapNone, // nullref
      0x72 => _heapNoextern, // nullexternref
      0x73 => _heapNofunc, // nullfuncref
      _ => null,
    };
  }

  static bool _isKnownAbstractHeapType(int heapType) {
    return heapType == _heapAny ||
        heapType == _heapEq ||
        heapType == _heapI31 ||
        heapType == _heapStruct ||
        heapType == _heapArray ||
        heapType == _heapFunc ||
        heapType == _heapExtern ||
        heapType == _heapNone ||
        heapType == _heapNofunc ||
        heapType == _heapNoextern;
  }

  static const int _heapAny = -18;
  static const int _heapEq = -19;
  static const int _heapI31 = -20;
  static const int _heapStruct = -21;
  static const int _heapArray = -22;
  static const int _heapFunc = -16;
  static const int _heapExtern = -17;
  static const int _heapNone = -15;
  static const int _heapNofunc = -13;
  static const int _heapNoextern = -14;

  static void _validateSimpleReferenceReturnCompatibility({
    required WasmModule module,
    required WasmFunctionType functionType,
    required List<Instruction> instructions,
  }) {
    if (functionType.resultTypeSignatures.length != 1 ||
        instructions.length != 2 ||
        instructions[0].opcode != Opcodes.localGet ||
        instructions[1].opcode != Opcodes.end) {
      return;
    }
    final localIndex = instructions[0].immediate!;
    if (localIndex < 0 ||
        localIndex >= functionType.params.length ||
        localIndex >= functionType.paramTypeSignatures.length) {
      return;
    }
    final sourceSignature = functionType.paramTypeSignatures[localIndex];
    final targetSignature = functionType.resultTypeSignatures.single;
    if (!_isValueSignatureSubtype(module, sourceSignature, targetSignature)) {
      throw const FormatException('Validation failed: type mismatch.');
    }
  }

  static bool _isValueSignatureSubtype(
    WasmModule module,
    String sourceSignature,
    String targetSignature,
  ) {
    if (sourceSignature == targetSignature) {
      return true;
    }
    final sourceRef = _parseRefSignature(sourceSignature);
    final targetRef = _parseRefSignature(targetSignature);
    if (sourceRef == null || targetRef == null) {
      return false;
    }
    if (sourceRef.nullable && !targetRef.nullable) {
      return false;
    }
    if (targetRef.exact) {
      if (!sourceRef.exact) {
        return _isBottomHeapForExactTarget(
          module,
          sourceRef.heapType,
          targetRef.heapType,
        );
      }
      return _isExactHeapCompatible(
        module,
        sourceRef.heapType,
        targetRef.heapType,
        <String>{},
      );
    }
    return _isHeapSubtype(module, sourceRef.heapType, targetRef.heapType);
  }

  static bool _isBottomHeapForExactTarget(
    WasmModule module,
    int sourceHeapType,
    int targetHeapType,
  ) {
    if (sourceHeapType == _heapNofunc) {
      return _isFuncLikeHeap(module, targetHeapType);
    }
    if (sourceHeapType == _heapNone) {
      return _isEqLikeHeap(module, targetHeapType);
    }
    if (sourceHeapType == _heapNoextern) {
      return targetHeapType == _heapExtern;
    }
    return false;
  }

  static bool _isExactHeapCompatible(
    WasmModule module,
    int sourceHeapType,
    int targetHeapType,
    Set<String> seenPairs,
  ) {
    if (sourceHeapType == targetHeapType) {
      return true;
    }
    if (sourceHeapType < 0 || targetHeapType < 0) {
      return false;
    }
    if (_isConcreteSubType(module, sourceHeapType, targetHeapType) ||
        _isConcreteSubType(module, targetHeapType, sourceHeapType)) {
      return false;
    }
    return _areConcreteTypesEquivalent(
      module,
      sourceHeapType,
      targetHeapType,
      seenPairs,
    );
  }

  static bool _isHeapSubtype(WasmModule module, int subHeap, int superHeap) {
    if (subHeap == superHeap) {
      return true;
    }
    if (superHeap >= 0) {
      if (subHeap >= 0) {
        return _isConcreteSubType(module, subHeap, superHeap);
      }
      return _isAbstractToConcreteSubtype(module, subHeap, superHeap);
    }
    if (subHeap >= 0) {
      return _isConcreteToAbstractSubtype(module, subHeap, superHeap);
    }
    return _isAbstractSubtype(subHeap, superHeap);
  }

  static bool _isHeapCastCompatible(
    WasmModule module,
    int sourceHeap,
    int targetHeap,
  ) {
    if (_isHeapSubtype(module, targetHeap, sourceHeap) ||
        _isHeapSubtype(module, sourceHeap, targetHeap)) {
      return true;
    }
    if (_isEqLikeHeap(module, sourceHeap) && _isEqLikeHeap(module, targetHeap)) {
      return true;
    }
    if (_isFuncLikeHeap(module, sourceHeap) &&
        _isFuncLikeHeap(module, targetHeap)) {
      return true;
    }
    if (_isExternLikeHeap(sourceHeap) && _isExternLikeHeap(targetHeap)) {
      return true;
    }
    return false;
  }

  static bool _isExternLikeHeap(int heapType) {
    return heapType == _heapExtern || heapType == _heapNoextern;
  }

  static bool _isConcreteSubType(
    WasmModule module,
    int subType,
    int superType,
  ) {
    if (subType == superType) {
      return true;
    }
    if (subType < 0 ||
        subType >= module.types.length ||
        superType < 0 ||
        superType >= module.types.length) {
      return false;
    }
    final visiting = <int>{subType};
    final pending = <int>[subType];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      for (final parent in module.types[current].superTypeIndices) {
        if (parent == superType) {
          return true;
        }
        if (parent < 0 || parent >= module.types.length) {
          continue;
        }
        if (visiting.add(parent)) {
          pending.add(parent);
        }
      }
    }
    return false;
  }

  static bool _isConcreteToAbstractSubtype(
    WasmModule module,
    int concreteHeap,
    int abstractHeap,
  ) {
    if (concreteHeap < 0 || concreteHeap >= module.types.length) {
      return false;
    }
    final kind = module.types[concreteHeap].kind;
    switch (abstractHeap) {
      case _heapStruct:
        return kind == WasmCompositeTypeKind.struct;
      case _heapArray:
        return kind == WasmCompositeTypeKind.array;
      case _heapFunc:
        return kind == WasmCompositeTypeKind.function;
      case _heapEq:
        return kind == WasmCompositeTypeKind.struct ||
            kind == WasmCompositeTypeKind.array;
      case _heapAny:
        return kind == WasmCompositeTypeKind.struct ||
            kind == WasmCompositeTypeKind.array;
      default:
        return false;
    }
  }

  static bool _isAbstractToConcreteSubtype(
    WasmModule module,
    int abstractHeap,
    int concreteHeap,
  ) {
    if (concreteHeap < 0 || concreteHeap >= module.types.length) {
      return false;
    }
    final kind = module.types[concreteHeap].kind;
    switch (abstractHeap) {
      case _heapNone:
        return kind == WasmCompositeTypeKind.struct ||
            kind == WasmCompositeTypeKind.array;
      case _heapNofunc:
        return kind == WasmCompositeTypeKind.function;
      default:
        return false;
    }
  }

  static bool _isAbstractSubtype(int subHeap, int superHeap) {
    if (subHeap == superHeap) {
      return true;
    }
    switch (subHeap) {
      case _heapNone:
        return superHeap == _heapStruct ||
            superHeap == _heapArray ||
            superHeap == _heapEq ||
            superHeap == _heapAny;
      case _heapStruct:
      case _heapArray:
      case _heapI31:
      case _heapEq:
        return superHeap == _heapEq || superHeap == _heapAny;
      case _heapNofunc:
        return superHeap == _heapFunc;
      case _heapNoextern:
        return superHeap == _heapExtern;
      default:
        return false;
    }
  }

  static bool _isFuncLikeHeap(WasmModule module, int heapType) {
    if (heapType == _heapFunc || heapType == _heapNofunc) {
      return true;
    }
    if (heapType < 0 || heapType >= module.types.length) {
      return false;
    }
    return module.types[heapType].kind == WasmCompositeTypeKind.function;
  }

  static bool _isEqLikeHeap(WasmModule module, int heapType) {
    if (heapType == _heapEq ||
        heapType == _heapStruct ||
        heapType == _heapArray ||
        heapType == _heapI31 ||
        heapType == _heapNone ||
        heapType == _heapAny) {
      return true;
    }
    if (heapType < 0 || heapType >= module.types.length) {
      return false;
    }
    final kind = module.types[heapType].kind;
    return kind == WasmCompositeTypeKind.struct ||
        kind == WasmCompositeTypeKind.array;
  }

  static bool _areConcreteTypesEquivalent(
    WasmModule module,
    int lhs,
    int rhs,
    Set<String> seenPairs,
  ) {
    if (lhs == rhs) {
      return true;
    }
    if (lhs < 0 ||
        lhs >= module.types.length ||
        rhs < 0 ||
        rhs >= module.types.length) {
      return false;
    }
    final pairKey = lhs < rhs ? '$lhs:$rhs' : '$rhs:$lhs';
    if (!seenPairs.add(pairKey)) {
      return true;
    }
    final left = module.types[lhs];
    final right = module.types[rhs];
    if (left.kind != right.kind) {
      return false;
    }
    if (left.isFunctionType != right.isFunctionType) {
      return false;
    }
    if (left.superTypeIndices.length != right.superTypeIndices.length) {
      return false;
    }
    for (var i = 0; i < left.superTypeIndices.length; i++) {
      if (!_areConcreteTypesEquivalent(
        module,
        left.superTypeIndices[i],
        right.superTypeIndices[i],
        seenPairs,
      )) {
        return false;
      }
    }
    final leftDescriptor = left.descriptorTypeIndex;
    final rightDescriptor = right.descriptorTypeIndex;
    if ((leftDescriptor == null) != (rightDescriptor == null)) {
      return false;
    }
    if (leftDescriptor != null &&
        !_areConcreteTypesEquivalent(
          module,
          leftDescriptor,
          rightDescriptor!,
          seenPairs,
        )) {
      return false;
    }
    final leftDescribes = left.describesTypeIndex;
    final rightDescribes = right.describesTypeIndex;
    if ((leftDescribes == null) != (rightDescribes == null)) {
      return false;
    }
    if (leftDescribes != null &&
        !_areConcreteTypesEquivalent(
          module,
          leftDescribes,
          rightDescribes!,
          seenPairs,
        )) {
      return false;
    }
    if (left.isFunctionType) {
      if (left.paramTypeSignatures.length != right.paramTypeSignatures.length ||
          left.resultTypeSignatures.length !=
              right.resultTypeSignatures.length) {
        return false;
      }
      for (var i = 0; i < left.paramTypeSignatures.length; i++) {
        if (!_areValueTypeSignaturesEquivalent(
          module,
          left.paramTypeSignatures[i],
          right.paramTypeSignatures[i],
          seenPairs,
        )) {
          return false;
        }
      }
      for (var i = 0; i < left.resultTypeSignatures.length; i++) {
        if (!_areValueTypeSignaturesEquivalent(
          module,
          left.resultTypeSignatures[i],
          right.resultTypeSignatures[i],
          seenPairs,
        )) {
          return false;
        }
      }
      return true;
    }

    if (left.fieldSignatures.length != right.fieldSignatures.length) {
      return false;
    }
    for (var i = 0; i < left.fieldSignatures.length; i++) {
      final leftField = _parseFieldSignature(left.fieldSignatures[i]);
      final rightField = _parseFieldSignature(right.fieldSignatures[i]);
      if (leftField == null || rightField == null) {
        return false;
      }
      if (leftField.mutability != rightField.mutability) {
        return false;
      }
      if (!_areValueTypeSignaturesEquivalent(
        module,
        leftField.valueSignature,
        rightField.valueSignature,
        seenPairs,
      )) {
        return false;
      }
    }
    return true;
  }

  static bool _areValueTypeSignaturesEquivalent(
    WasmModule module,
    String lhs,
    String rhs,
    Set<String> seenPairs,
  ) {
    if (lhs == rhs) {
      return true;
    }
    final leftRef = _parseRefSignature(lhs);
    final rightRef = _parseRefSignature(rhs);
    if (leftRef == null || rightRef == null) {
      return false;
    }
    if (leftRef.nullable != rightRef.nullable ||
        leftRef.exact != rightRef.exact) {
      return false;
    }
    if (leftRef.heapType == rightRef.heapType) {
      return true;
    }
    if (leftRef.heapType >= 0 && rightRef.heapType >= 0) {
      return _areConcreteTypesEquivalent(
        module,
        leftRef.heapType,
        rightRef.heapType,
        seenPairs,
      );
    }
    return false;
  }

  static ({bool nullable, bool exact, int heapType})? _parseRefSignature(
    String signature,
  ) {
    final bytes = _signatureToBytes(signature);
    if (bytes.isEmpty) {
      return null;
    }
    if (bytes.length == 1) {
      final heapType = _legacyHeapTypeFromRefTypeCode(bytes.single);
      if (heapType == null) {
        final decoded = _readSignedLeb33FromBytes(bytes, 0);
        if (decoded == null || decoded.$2 != bytes.length) {
          return null;
        }
        return (nullable: true, exact: false, heapType: decoded.$1);
      }
      return (nullable: true, exact: false, heapType: heapType);
    }
    if (bytes.length < 2) {
      return null;
    }
    final refPrefix = bytes[0];
    if (refPrefix != 0x63 && refPrefix != 0x64) {
      final decoded = _readSignedLeb33FromBytes(bytes, 0);
      if (decoded == null || decoded.$2 != bytes.length) {
        return null;
      }
      return (nullable: true, exact: false, heapType: decoded.$1);
    }
    var offset = 1;
    var exact = false;
    if (bytes[offset] == 0x62 || bytes[offset] == 0x61) {
      exact = bytes[offset] == 0x62;
      offset++;
      if (offset >= bytes.length) {
        return null;
      }
    }
    final decodedHeap = _readSignedLeb33FromBytes(bytes, offset);
    if (decodedHeap == null || decodedHeap.$2 != bytes.length) {
      return null;
    }
    return (
      nullable: refPrefix == 0x63,
      exact: exact,
      heapType: decodedHeap.$1,
    );
  }

  static (int, int)? _readSignedLeb33FromBytes(List<int> bytes, int offset) {
    if (offset >= bytes.length) {
      return null;
    }
    final firstByte = bytes[offset];
    var result = firstByte & 0x7f;
    var shift = 7;
    var byte = firstByte;
    var multiplier = 128;
    var index = offset + 1;
    while ((byte & 0x80) != 0) {
      if (index >= bytes.length) {
        return null;
      }
      byte = bytes[index++];
      result += (byte & 0x7f) * multiplier;
      multiplier *= 128;
      shift += 7;
      if (shift > 35) {
        return null;
      }
    }
    if (shift < 33 && (byte & 0x40) != 0) {
      result -= multiplier;
    }
    return (_normalizeSignedLeb33(result), index);
  }

  static ({String valueSignature, int mutability})? _arrayFieldInfo(
    WasmFunctionType type,
  ) {
    if (type.kind != WasmCompositeTypeKind.array ||
        type.fieldSignatures.length != 1) {
      return null;
    }
    return _parseFieldSignature(type.fieldSignatures.single);
  }

  static bool _isPackedStorageSignature(String signature) {
    final bytes = _signatureToBytes(signature);
    if (bytes.isEmpty) {
      return false;
    }
    return bytes.first == 0x78 || bytes.first == 0x77;
  }

  static bool _isNumericOrVectorValueSignature(String signature) {
    final bytes = _signatureToBytes(signature);
    if (bytes.isEmpty) {
      return false;
    }
    return switch (bytes.first) {
      0x78 || // i8
      0x77 || // i16
      0x7f || // i32
      0x7e || // i64
      0x7d || // f32
      0x7c || // f64
      0x7b => true, // v128
      _ => false,
    };
  }

  static bool _isReferenceValueSignature(String signature) {
    return _parseRefSignature(signature) != null;
  }

  static bool _isElementSegmentRefCompatible({
    required WasmModule module,
    required int segmentRefTypeCode,
    required String targetValueSignature,
  }) {
    final target = _parseRefSignature(targetValueSignature);
    if (target == null) {
      return false;
    }
    final heapType = target.heapType;

    switch (segmentRefTypeCode) {
      case 0x70: // funcref
        if (heapType >= 0) {
          return heapType < module.types.length &&
              module.types[heapType].isFunctionType;
        }
        return heapType == _heapFunc;
      case 0x6f: // externref
        return heapType == _heapExtern;
      case 0x69: // i31ref (legacy codepoint)
      case 0x6c: // i31ref (current codepoint)
        return heapType == _heapI31 ||
            heapType == _heapEq ||
            heapType == _heapAny;
      case 0x63: // (ref null ht)
      case 0x64: // (ref ht)
      case 0x61: // exact heap type prefix
      case 0x62:
        // Segment heap detail is not retained in the compact element model yet.
        return true;
      default:
        final targetBytes = _signatureToBytes(targetValueSignature);
        return targetBytes.isNotEmpty && targetBytes.first == segmentRefTypeCode;
    }
  }

  static ({String valueSignature, int mutability})? _parseFieldSignature(
    String signature,
  ) {
    final bytes = _signatureToBytes(signature);
    if (bytes.length < 2) {
      return null;
    }
    final mutability = bytes.last;
    if (mutability != 0 && mutability != 1) {
      return null;
    }
    return (
      valueSignature: _bytesToSignature(bytes.sublist(0, bytes.length - 1)),
      mutability: mutability,
    );
  }

  static List<int> _signatureToBytes(String signature) {
    if (signature.isEmpty || signature.length.isOdd) {
      return const <int>[];
    }
    final bytes = <int>[];
    for (var i = 0; i < signature.length; i += 2) {
      bytes.add(int.parse(signature.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  static String _bytesToSignature(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write((byte & 0xff).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static void _checkIndex(int index, int count, String what) {
    if (index < 0 || index >= count) {
      throw FormatException(
        'Validation failed: invalid $what index $index (count=$count).',
      );
    }
  }

  static List<bool> _memory64ByIndex(WasmModule module) {
    final list = <bool>[];
    for (final import in module.imports) {
      if (import.kind == WasmImportKind.memory) {
        list.add(import.memoryType?.isMemory64 ?? false);
      }
    }
    for (final memory in module.memories) {
      list.add(memory.isMemory64);
    }
    return List<bool>.unmodifiable(list);
  }

  static List<bool> _table64ByIndex(WasmModule module) {
    final list = <bool>[];
    for (final import in module.imports) {
      if (import.kind == WasmImportKind.table) {
        list.add(import.tableType?.isTable64 ?? false);
      }
    }
    for (final table in module.tables) {
      list.add(table.isTable64);
    }
    return List<bool>.unmodifiable(list);
  }

  static bool _isAtomicMemoryOpcode(int opcode) {
    switch (opcode) {
      case Opcodes.memoryAtomicNotify:
      case Opcodes.memoryAtomicWait32:
      case Opcodes.memoryAtomicWait64:
      case Opcodes.i32AtomicLoad:
      case Opcodes.i64AtomicLoad:
      case Opcodes.i32AtomicLoad8U:
      case Opcodes.i32AtomicLoad16U:
      case Opcodes.i64AtomicLoad8U:
      case Opcodes.i64AtomicLoad16U:
      case Opcodes.i64AtomicLoad32U:
      case Opcodes.i32AtomicStore:
      case Opcodes.i64AtomicStore:
      case Opcodes.i32AtomicStore8:
      case Opcodes.i32AtomicStore16:
      case Opcodes.i64AtomicStore8:
      case Opcodes.i64AtomicStore16:
      case Opcodes.i64AtomicStore32:
      case Opcodes.i32AtomicRmwAdd:
      case Opcodes.i64AtomicRmwAdd:
      case Opcodes.i32AtomicRmw8AddU:
      case Opcodes.i32AtomicRmw16AddU:
      case Opcodes.i64AtomicRmw8AddU:
      case Opcodes.i64AtomicRmw16AddU:
      case Opcodes.i64AtomicRmw32AddU:
      case Opcodes.i32AtomicRmwSub:
      case Opcodes.i64AtomicRmwSub:
      case Opcodes.i32AtomicRmw8SubU:
      case Opcodes.i32AtomicRmw16SubU:
      case Opcodes.i64AtomicRmw8SubU:
      case Opcodes.i64AtomicRmw16SubU:
      case Opcodes.i64AtomicRmw32SubU:
      case Opcodes.i32AtomicRmwAnd:
      case Opcodes.i64AtomicRmwAnd:
      case Opcodes.i32AtomicRmw8AndU:
      case Opcodes.i32AtomicRmw16AndU:
      case Opcodes.i64AtomicRmw8AndU:
      case Opcodes.i64AtomicRmw16AndU:
      case Opcodes.i64AtomicRmw32AndU:
      case Opcodes.i32AtomicRmwOr:
      case Opcodes.i64AtomicRmwOr:
      case Opcodes.i32AtomicRmw8OrU:
      case Opcodes.i32AtomicRmw16OrU:
      case Opcodes.i64AtomicRmw8OrU:
      case Opcodes.i64AtomicRmw16OrU:
      case Opcodes.i64AtomicRmw32OrU:
      case Opcodes.i32AtomicRmwXor:
      case Opcodes.i64AtomicRmwXor:
      case Opcodes.i32AtomicRmw8XorU:
      case Opcodes.i32AtomicRmw16XorU:
      case Opcodes.i64AtomicRmw8XorU:
      case Opcodes.i64AtomicRmw16XorU:
      case Opcodes.i64AtomicRmw32XorU:
      case Opcodes.i32AtomicRmwXchg:
      case Opcodes.i64AtomicRmwXchg:
      case Opcodes.i32AtomicRmw8XchgU:
      case Opcodes.i32AtomicRmw16XchgU:
      case Opcodes.i64AtomicRmw8XchgU:
      case Opcodes.i64AtomicRmw16XchgU:
      case Opcodes.i64AtomicRmw32XchgU:
      case Opcodes.i32AtomicRmwCmpxchg:
      case Opcodes.i64AtomicRmwCmpxchg:
      case Opcodes.i32AtomicRmw8CmpxchgU:
      case Opcodes.i32AtomicRmw16CmpxchgU:
      case Opcodes.i64AtomicRmw8CmpxchgU:
      case Opcodes.i64AtomicRmw16CmpxchgU:
      case Opcodes.i64AtomicRmw32CmpxchgU:
        return true;
      default:
        return false;
    }
  }

  static void _validateMemArgAlignment(Instruction instruction) {
    final memArg = instruction.memArg;
    if (memArg == null) {
      return;
    }
    final naturalAlign = _naturalMemArgAlignment(instruction.opcode);
    if (naturalAlign == null) {
      return;
    }

    if (_isAtomicMemoryOpcode(instruction.opcode)) {
      if (memArg.align != naturalAlign) {
        throw const FormatException(
          'Validation failed: atomic memory alignment must be natural.',
        );
      }
      return;
    }

    if (memArg.align > naturalAlign) {
      throw const FormatException(
        'Validation failed: alignment must not be larger than natural.',
      );
    }
  }

  static int? _naturalMemArgAlignment(int opcode) {
    switch (opcode) {
      case Opcodes.i32Load:
      case Opcodes.f32Load:
      case Opcodes.i32Store:
      case Opcodes.f32Store:
        return 2;
      case Opcodes.i64Load:
      case Opcodes.f64Load:
      case Opcodes.i64Store:
      case Opcodes.f64Store:
        return 3;
      case Opcodes.i32Load8S:
      case Opcodes.i32Load8U:
      case Opcodes.i64Load8S:
      case Opcodes.i64Load8U:
      case Opcodes.i32Store8:
      case Opcodes.i64Store8:
      case Opcodes.i32AtomicLoad8U:
      case Opcodes.i64AtomicLoad8U:
      case Opcodes.i32AtomicStore8:
      case Opcodes.i64AtomicStore8:
      case Opcodes.i32AtomicRmw8AddU:
      case Opcodes.i64AtomicRmw8AddU:
      case Opcodes.i32AtomicRmw8SubU:
      case Opcodes.i64AtomicRmw8SubU:
      case Opcodes.i32AtomicRmw8AndU:
      case Opcodes.i64AtomicRmw8AndU:
      case Opcodes.i32AtomicRmw8OrU:
      case Opcodes.i64AtomicRmw8OrU:
      case Opcodes.i32AtomicRmw8XorU:
      case Opcodes.i64AtomicRmw8XorU:
      case Opcodes.i32AtomicRmw8XchgU:
      case Opcodes.i64AtomicRmw8XchgU:
      case Opcodes.i32AtomicRmw8CmpxchgU:
      case Opcodes.i64AtomicRmw8CmpxchgU:
        return 0;
      case Opcodes.i32Load16S:
      case Opcodes.i32Load16U:
      case Opcodes.i64Load16S:
      case Opcodes.i64Load16U:
      case Opcodes.i32Store16:
      case Opcodes.i64Store16:
      case Opcodes.i32AtomicLoad16U:
      case Opcodes.i64AtomicLoad16U:
      case Opcodes.i32AtomicStore16:
      case Opcodes.i64AtomicStore16:
      case Opcodes.i32AtomicRmw16AddU:
      case Opcodes.i64AtomicRmw16AddU:
      case Opcodes.i32AtomicRmw16SubU:
      case Opcodes.i64AtomicRmw16SubU:
      case Opcodes.i32AtomicRmw16AndU:
      case Opcodes.i64AtomicRmw16AndU:
      case Opcodes.i32AtomicRmw16OrU:
      case Opcodes.i64AtomicRmw16OrU:
      case Opcodes.i32AtomicRmw16XorU:
      case Opcodes.i64AtomicRmw16XorU:
      case Opcodes.i32AtomicRmw16XchgU:
      case Opcodes.i64AtomicRmw16XchgU:
      case Opcodes.i32AtomicRmw16CmpxchgU:
      case Opcodes.i64AtomicRmw16CmpxchgU:
        return 1;
      case Opcodes.i64Load32S:
      case Opcodes.i64Load32U:
      case Opcodes.i64Store32:
      case Opcodes.memoryAtomicNotify:
      case Opcodes.memoryAtomicWait32:
      case Opcodes.i32AtomicLoad:
      case Opcodes.i32AtomicStore:
      case Opcodes.i64AtomicLoad32U:
      case Opcodes.i64AtomicStore32:
      case Opcodes.i32AtomicRmwAdd:
      case Opcodes.i32AtomicRmwSub:
      case Opcodes.i32AtomicRmwAnd:
      case Opcodes.i32AtomicRmwOr:
      case Opcodes.i32AtomicRmwXor:
      case Opcodes.i32AtomicRmwXchg:
      case Opcodes.i32AtomicRmwCmpxchg:
      case Opcodes.i64AtomicRmw32AddU:
      case Opcodes.i64AtomicRmw32SubU:
      case Opcodes.i64AtomicRmw32AndU:
      case Opcodes.i64AtomicRmw32OrU:
      case Opcodes.i64AtomicRmw32XorU:
      case Opcodes.i64AtomicRmw32XchgU:
      case Opcodes.i64AtomicRmw32CmpxchgU:
        return 2;
      case Opcodes.memoryAtomicWait64:
      case Opcodes.i64AtomicLoad:
      case Opcodes.i64AtomicStore:
      case Opcodes.i64AtomicRmwAdd:
      case Opcodes.i64AtomicRmwSub:
      case Opcodes.i64AtomicRmwAnd:
      case Opcodes.i64AtomicRmwOr:
      case Opcodes.i64AtomicRmwXor:
      case Opcodes.i64AtomicRmwXchg:
      case Opcodes.i64AtomicRmwCmpxchg:
        return 3;
      default:
        return null;
    }
  }

  static void _consumeHeapType(ByteReader reader) {
    _consumeHeapTypeWithLeadingByte(reader, reader.readByte());
  }

  static void _consumeHeapTypeWithLeadingByte(ByteReader reader, int lead) {
    if (lead == 0x62 || lead == 0x61) {
      _consumeHeapType(reader);
      return;
    }
    if (lead >= 0x65 && lead <= 0x71) {
      return;
    }
    _readSignedLeb33WithFirst(reader, lead);
  }

  static int _readSignedLeb33WithFirst(ByteReader reader, int firstByte) {
    var result = firstByte & 0x7f;
    var shift = 7;
    var byte = firstByte;
    var multiplier = 128;
    while ((byte & 0x80) != 0) {
      byte = reader.readByte();
      result += (byte & 0x7f) * multiplier;
      multiplier *= 128;
      shift += 7;
      if (shift > 35) {
        throw const FormatException('Invalid signed LEB33 encoding.');
      }
    }
    if (shift < 33 && (byte & 0x40) != 0) {
      result -= multiplier;
    }
    return _normalizeSignedLeb33(result);
  }

  static int _normalizeSignedLeb33(int value) {
    const signBit33 = 0x100000000;
    const width33 = 0x200000000;
    var normalized = value % width33;
    if (normalized < 0) {
      normalized += width33;
    }
    if (normalized >= signBit33) {
      normalized -= width33;
    }
    return normalized;
  }
}
