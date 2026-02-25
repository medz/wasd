import 'dart:typed_data';

import 'byte_reader.dart';
import 'features.dart';
import 'module.dart';
import 'opcode.dart';
import 'predecode.dart';

abstract final class WasmValidator {
  static void validateModule(
    WasmModule module, {
    WasmFeatureSet features = const WasmFeatureSet(),
  }) {
    _validateTableArity(module, features: features);
    _validateImportTypes(module);
    _validateExportBindings(module);
    _validateStartFunction(module);
    _validateGlobals(module);
    _validateElements(module);
    _validateDataSegments(module);
    _validateFunctions(module, features: features);
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

  static void _validateImportTypes(WasmModule module) {
    for (final import in module.imports) {
      switch (import.kind) {
        case WasmImportKind.function:
          final typeIndex = import.functionTypeIndex;
          if (typeIndex == null ||
              typeIndex < 0 ||
              typeIndex >= module.types.length) {
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
          // Const expressions can reference imported immutable globals.
          return index < importedGlobals.length && !available[index].mutable;
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
        if (exprType != WasmValueType.i32) {
          throw FormatException(
            'Validation failed: element offset expr must produce i32, got $exprType.',
          );
        }
      }
      for (final functionIndex in element.functionIndices) {
        if (functionIndex == null) {
          continue;
        }
        _checkIndex(functionIndex, functionCount, 'element function');
      }
    }
  }

  static void _validateDataSegments(WasmModule module) {
    final memoryCount = module.importedMemoryCount + module.memories.length;
    final importedGlobals = module.imports
        .where((i) => i.kind == WasmImportKind.global)
        .map((i) => i.globalType!)
        .toList(growable: false);

    for (final data in module.dataSegments) {
      if (data.isPassive) {
        continue;
      }
      _checkIndex(data.memoryIndex, memoryCount, 'data memory');
      final exprType = _validateConstExpr(
        module: module,
        expr: data.offsetExpr!,
        availableGlobals: importedGlobals,
        allowGlobalGet: (index, available) {
          if (index < 0 || index >= available.length) {
            return false;
          }
          return !available[index].mutable;
        },
      );
      if (exprType != WasmValueType.i32) {
        throw FormatException(
          'Validation failed: data offset expr must produce i32, got $exprType.',
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
    var requiresDataCount = false;

    for (var i = 0; i < module.functionTypeIndices.length; i++) {
      final typeIndex = module.functionTypeIndices[i];
      _checkIndex(typeIndex, module.types.length, 'function type');
      final functionType = module.types[typeIndex];
      final body = module.codes[i];
      final localsCount = _validatedLocalsCount(functionType, body);
      final predecoded = WasmPredecoder.decode(
        body,
        module.types,
        features: features,
      );

      final controlStack = <int>[];
      for (var pc = 0; pc < predecoded.instructions.length; pc++) {
        final instruction = predecoded.instructions[pc];
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
            final depth = instruction.immediate!;
            if (depth < 0 || depth >= controlStack.length) {
              throw FormatException(
                'Validation failed: branch depth out of range: $depth.',
              );
            }
          case Opcodes.brTable:
            final targets = instruction.tableDepths ?? const <int>[];
            for (final depth in targets) {
              if (depth < 0 || depth >= controlStack.length) {
                throw FormatException(
                  'Validation failed: br_table depth out of range: $depth.',
                );
              }
            }
          case Opcodes.call:
          case Opcodes.returnCall:
          case Opcodes.refFunc:
            _checkIndex(instruction.immediate!, functionCount, 'function ref');
          case Opcodes.callIndirect:
          case Opcodes.returnCallIndirect:
            _checkIndex(
              instruction.immediate!,
              module.types.length,
              'type ref',
            );
            _checkIndex(
              instruction.secondaryImmediate!,
              tableCount,
              'table ref',
            );
          case Opcodes.localGet:
          case Opcodes.localSet:
          case Opcodes.localTee:
            _checkIndex(instruction.immediate!, localsCount, 'local');
          case Opcodes.globalGet:
          case Opcodes.globalSet:
            _checkIndex(instruction.immediate!, globalCount, 'global');
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
          case Opcodes.memorySize:
          case Opcodes.memoryGrow:
            if (memoryCount == 0) {
              throw const FormatException(
                'Validation failed: memory instruction used without memory.',
              );
            }
            if (instruction.immediate != 0) {
              throw const FormatException(
                'Validation failed: only memory index 0 is supported.',
              );
            }
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
            if (instruction.secondaryImmediate != 0) {
              throw const FormatException(
                'Validation failed: only memory index 0 is supported.',
              );
            }
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
            if (instruction.immediate != 0 ||
                instruction.secondaryImmediate != 0) {
              throw const FormatException(
                'Validation failed: only memory index 0 is supported.',
              );
            }
          case Opcodes.memoryFill:
            if (memoryCount == 0) {
              throw const FormatException(
                'Validation failed: memory.fill used without memory.',
              );
            }
            if (instruction.immediate != 0) {
              throw const FormatException(
                'Validation failed: only memory index 0 is supported.',
              );
            }
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
      if (import.kind != WasmImportKind.function) {
        continue;
      }
      if (importFuncOrdinal == index) {
        return module.types[import.functionTypeIndex!];
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
    return module.types[typeIndex];
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
          reader.readByte();
          stack.add(WasmValueType.i32);
        case Opcodes.refFunc:
          final functionIndex = reader.readVarUint32();
          final functionCount =
              module.importedFunctionCount + module.functionTypeIndices.length;
          _checkIndex(functionIndex, functionCount, 'const expr ref.func');
          stack.add(WasmValueType.i32);
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

  static void _checkIndex(int index, int count, String what) {
    if (index < 0 || index >= count) {
      throw FormatException(
        'Validation failed: invalid $what index $index (count=$count).',
      );
    }
  }
}
