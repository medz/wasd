// ignore_for_file: public_member_api_docs

import 'dart:typed_data';

import 'int64.dart';
import 'memory.dart';
import 'opcode.dart';
import 'table.dart';
import 'value.dart';

final class RuntimeMemoryOps {
  static WasmValue loadByOpcode({
    required WasmMemory memory,
    required int address,
    required int opcode,
    required String context,
  }) {
    switch (opcode) {
      case Opcodes.i32Load:
        return WasmValue.i32(memory.loadI32(address));
      case Opcodes.i64Load:
        return WasmValue.i64(memory.loadI64(address));
      case Opcodes.f32Load:
        return WasmValue.f32(memory.loadF32(address));
      case Opcodes.f64Load:
        return WasmValue.f64(memory.loadF64(address));
      case Opcodes.i32Load8S:
        return WasmValue.i32(memory.loadI8(address));
      case Opcodes.i32Load8U:
        return WasmValue.i32(memory.loadU8(address));
      case Opcodes.i32Load16S:
        return WasmValue.i32(memory.loadI16(address));
      case Opcodes.i32Load16U:
        return WasmValue.i32(memory.loadU16(address));
      case Opcodes.i64Load8S:
        return WasmValue.i64(memory.loadI8(address));
      case Opcodes.i64Load8U:
        return WasmValue.i64(memory.loadU8(address));
      case Opcodes.i64Load16S:
        return WasmValue.i64(memory.loadI16(address));
      case Opcodes.i64Load16U:
        return WasmValue.i64(memory.loadU16(address));
      case Opcodes.i64Load32S:
        return WasmValue.i64(memory.loadI32(address));
      case Opcodes.i64Load32U:
        return WasmValue.i64(memory.loadU32(address));
      default:
        throw StateError(
          'Unexpected memory load opcode in $context: '
          '0x${opcode.toRadixString(16)}',
        );
    }
  }

  static void storeByOpcode({
    required WasmMemory memory,
    required int address,
    required int opcode,
    required WasmValue value,
    required String context,
  }) {
    switch (opcode) {
      case Opcodes.i32Store:
        memory.storeI32(address, value.asI32());
        return;
      case Opcodes.i64Store:
        memory.storeI64(address, value.asI64());
        return;
      case Opcodes.f32Store:
        memory.storeI32(address, value.asF32Bits());
        return;
      case Opcodes.f64Store:
        memory.storeI64(address, value.asF64Bits());
        return;
      case Opcodes.i32Store8:
        memory.storeI8(address, value.asI32());
        return;
      case Opcodes.i32Store16:
        memory.storeI16(address, value.asI32());
        return;
      case Opcodes.i64Store8:
        memory.storeI8(address, WasmI64.lowU32(value.asI64()));
        return;
      case Opcodes.i64Store16:
        memory.storeI16(address, WasmI64.lowU32(value.asI64()));
        return;
      case Opcodes.i64Store32:
        memory.storeI32(address, WasmI64.lowU32(value.asI64()));
        return;
      default:
        throw StateError(
          'Unexpected memory store opcode in $context: '
          '0x${opcode.toRadixString(16)}',
        );
    }
  }

  static int atomicLoadWidthByOpcode(int opcode, {required String context}) {
    switch (opcode) {
      case Opcodes.i32AtomicLoad:
        return 4;
      case Opcodes.i64AtomicLoad:
        return 8;
      case Opcodes.i32AtomicLoad8U:
      case Opcodes.i64AtomicLoad8U:
        return 1;
      case Opcodes.i32AtomicLoad16U:
      case Opcodes.i64AtomicLoad16U:
        return 2;
      case Opcodes.i64AtomicLoad32U:
        return 4;
      default:
        throw StateError(
          'Unexpected atomic load opcode in $context: '
          '0x${opcode.toRadixString(16)}',
        );
    }
  }

  static int atomicStoreWidthByOpcode(int opcode, {required String context}) {
    switch (opcode) {
      case Opcodes.i32AtomicStore:
        return 4;
      case Opcodes.i64AtomicStore:
        return 8;
      case Opcodes.i32AtomicStore8:
      case Opcodes.i64AtomicStore8:
        return 1;
      case Opcodes.i32AtomicStore16:
      case Opcodes.i64AtomicStore16:
        return 2;
      case Opcodes.i64AtomicStore32:
        return 4;
      default:
        throw StateError(
          'Unexpected atomic store opcode in $context: '
          '0x${opcode.toRadixString(16)}',
        );
    }
  }

  static void requireAtomicAlignment(
    int address, {
    required int widthBytes,
    required String context,
  }) {
    if (widthBytes > 1 && address % widthBytes != 0) {
      throw StateError('unaligned atomic');
    }
  }

  static WasmValue atomicLoadByOpcode({
    required WasmMemory memory,
    required int address,
    required int opcode,
    required String context,
  }) {
    switch (opcode) {
      case Opcodes.i32AtomicLoad:
        return WasmValue.i32(memory.loadI32(address));
      case Opcodes.i64AtomicLoad:
        return WasmValue.i64(memory.loadI64(address));
      case Opcodes.i32AtomicLoad8U:
        return WasmValue.i32(memory.loadU8(address));
      case Opcodes.i32AtomicLoad16U:
        return WasmValue.i32(memory.loadU16(address));
      case Opcodes.i64AtomicLoad8U:
        return WasmValue.i64(memory.loadU8(address));
      case Opcodes.i64AtomicLoad16U:
        return WasmValue.i64(memory.loadU16(address));
      case Opcodes.i64AtomicLoad32U:
        return WasmValue.i64(memory.loadU32(address));
      default:
        throw StateError(
          'Unexpected atomic load opcode in $context: '
          '0x${opcode.toRadixString(16)}',
        );
    }
  }

  static void atomicStoreByOpcode({
    required WasmMemory memory,
    required int address,
    required int opcode,
    required WasmValue value,
    required String context,
  }) {
    switch (opcode) {
      case Opcodes.i32AtomicStore:
        memory.storeI32(address, value.asI32());
        return;
      case Opcodes.i64AtomicStore:
        memory.storeI64(address, value.asI64());
        return;
      case Opcodes.i32AtomicStore8:
        memory.storeI8(address, value.asI32());
        return;
      case Opcodes.i32AtomicStore16:
        memory.storeI16(address, value.asI32());
        return;
      case Opcodes.i64AtomicStore8:
        memory.storeI8(address, WasmI64.lowU32(value.asI64()));
        return;
      case Opcodes.i64AtomicStore16:
        memory.storeI16(address, WasmI64.lowU32(value.asI64()));
        return;
      case Opcodes.i64AtomicStore32:
        memory.storeI32(address, WasmI64.lowU32(value.asI64()));
        return;
      default:
        throw StateError(
          'Unexpected atomic store opcode in $context: '
          '0x${opcode.toRadixString(16)}',
        );
    }
  }

  static int atomicNotify({required WasmMemory memory, required int address}) {
    memory.loadU32(address);
    return 0;
  }

  static int atomicWait32({
    required WasmMemory memory,
    required int address,
    required int expected,
  }) {
    final actual = memory.loadU32(address);
    return actual == expected ? 2 : 1;
  }

  static int atomicWait64({
    required WasmMemory memory,
    required int address,
    required BigInt expected,
  }) {
    final actual = WasmI64.unsigned(memory.loadI64(address));
    return actual == expected ? 2 : 1;
  }

  static int atomicRmwI32({
    required WasmMemory memory,
    required int address,
    required int operand,
    required int Function(int current, int operand) operation,
  }) {
    final current = memory.loadI32(address).toUnsigned(32);
    final next = operation(current, operand).toUnsigned(32);
    memory.storeI32(address, next);
    return current;
  }

  static BigInt atomicRmwI64({
    required WasmMemory memory,
    required int address,
    required BigInt operand,
    required BigInt Function(BigInt current, BigInt operand) operation,
  }) {
    final current = WasmI64.unsigned(memory.loadI64(address));
    final next = WasmI64.unsigned(operation(current, operand));
    memory.storeI64(address, next);
    return current;
  }

  static int atomicRmwNarrowUnsigned({
    required WasmMemory memory,
    required int address,
    required int widthBytes,
    required int operand,
    required int Function(int current, int operand) operation,
    required String context,
  }) {
    final bits = widthBytes * 8;
    final current = _loadAtomicNarrowUnsigned(
      memory,
      address,
      widthBytes: widthBytes,
      context: context,
    );
    final next = operation(current, operand).toUnsigned(bits);
    _storeAtomicNarrowUnsigned(
      memory,
      address,
      widthBytes: widthBytes,
      value: next,
      context: context,
    );
    return current;
  }

  static int atomicCmpxchgI32({
    required WasmMemory memory,
    required int address,
    required int expected,
    required int replacement,
  }) {
    final current = memory.loadI32(address).toUnsigned(32);
    if (current == expected) {
      memory.storeI32(address, replacement);
    }
    return current;
  }

  static BigInt atomicCmpxchgI64({
    required WasmMemory memory,
    required int address,
    required BigInt expected,
    required BigInt replacement,
  }) {
    final current = WasmI64.unsigned(memory.loadI64(address));
    if (current == expected) {
      memory.storeI64(address, replacement);
    }
    return current;
  }

  static int atomicCmpxchgNarrowUnsigned({
    required WasmMemory memory,
    required int address,
    required int widthBytes,
    required int expected,
    required int replacement,
    required String context,
  }) {
    final current = _loadAtomicNarrowUnsigned(
      memory,
      address,
      widthBytes: widthBytes,
      context: context,
    );
    if (current == expected) {
      _storeAtomicNarrowUnsigned(
        memory,
        address,
        widthBytes: widthBytes,
        value: replacement,
        context: context,
      );
    }
    return current;
  }

  static int _loadAtomicNarrowUnsigned(
    WasmMemory memory,
    int address, {
    required int widthBytes,
    required String context,
  }) {
    switch (widthBytes) {
      case 1:
        return memory.loadU8(address);
      case 2:
        return memory.loadU16(address);
      case 4:
        return memory.loadU32(address);
      default:
        throw StateError('Unsupported $context width: $widthBytes');
    }
  }

  static void _storeAtomicNarrowUnsigned(
    WasmMemory memory,
    int address, {
    required int widthBytes,
    required int value,
    required String context,
  }) {
    switch (widthBytes) {
      case 1:
        memory.storeI8(address, value);
        return;
      case 2:
        memory.storeI16(address, value);
        return;
      case 4:
        memory.storeI32(address, value);
        return;
      default:
        throw StateError('Unsupported $context width: $widthBytes');
    }
  }

  static void initFromDataSegment({
    required Uint8List? segment,
    required int segmentIndex,
    required WasmMemory memory,
    required int sourceOffset,
    required int destinationOffset,
    required int length,
  }) {
    if (segment == null) {
      if (length == 0) {
        return;
      }
      throw StateError('memory.init on dropped data segment $segmentIndex.');
    }
    if (sourceOffset > segment.length ||
        length > segment.length - sourceOffset) {
      throw StateError('memory.init source out of bounds.');
    }
    if (destinationOffset > memory.lengthInBytes ||
        length > memory.lengthInBytes - destinationOffset) {
      throw StateError('memory.init destination out of bounds.');
    }
    if (length == 0) {
      return;
    }
    memory.writeBytesFromList(
      destinationOffset,
      segment,
      sourceOffset: sourceOffset,
      length: length,
    );
  }

  static void copy({
    required WasmMemory sourceMemory,
    required WasmMemory destinationMemory,
    required int sourceOffset,
    required int destinationOffset,
    required int length,
  }) {
    if (sourceOffset > sourceMemory.lengthInBytes ||
        length > sourceMemory.lengthInBytes - sourceOffset) {
      throw StateError('memory.copy source out of bounds.');
    }
    if (destinationOffset > destinationMemory.lengthInBytes ||
        length > destinationMemory.lengthInBytes - destinationOffset) {
      throw StateError('memory.copy destination out of bounds.');
    }
    if (length == 0) {
      return;
    }
    destinationMemory.copyFromMemory(
      source: sourceMemory,
      destinationOffset: destinationOffset,
      sourceOffset: sourceOffset,
      length: length,
    );
  }

  static void fill({
    required WasmMemory memory,
    required int destinationOffset,
    required int value,
    required int length,
  }) {
    if (destinationOffset > memory.lengthInBytes ||
        length > memory.lengthInBytes - destinationOffset) {
      throw StateError('memory.fill out of bounds.');
    }
    if (length == 0) {
      return;
    }
    memory.fillBytes(destinationOffset, value, length);
  }
}

final class RuntimeTableOps {
  static void initFromElementSegment({
    required List<int?>? segment,
    required int segmentIndex,
    required WasmTable table,
    required int sourceOffset,
    required int destinationOffset,
    required int length,
  }) {
    if (segment == null) {
      if (length == 0) {
        return;
      }
      throw StateError('table.init on dropped element segment $segmentIndex.');
    }
    if (sourceOffset > segment.length ||
        length > segment.length - sourceOffset) {
      throw StateError('table.init source out of bounds.');
    }
    if (destinationOffset > table.length ||
        length > table.length - destinationOffset) {
      throw StateError('table.init destination out of bounds.');
    }
    if (length == 0) {
      return;
    }
    table.initializeRange(
      destinationOffset,
      segment,
      sourceOffset: sourceOffset,
      length: length,
    );
  }

  static void copy({
    required WasmTable sourceTable,
    required WasmTable destinationTable,
    required int sourceOffset,
    required int destinationOffset,
    required int length,
  }) {
    if (sourceOffset > sourceTable.length ||
        length > sourceTable.length - sourceOffset) {
      throw StateError('table.copy source out of bounds.');
    }
    if (destinationOffset > destinationTable.length ||
        length > destinationTable.length - destinationOffset) {
      throw StateError('table.copy destination out of bounds.');
    }
    if (length == 0) {
      return;
    }
    destinationTable.copyEntries(
      source: sourceTable,
      destinationOffset: destinationOffset,
      sourceOffset: sourceOffset,
      length: length,
    );
  }

  static void fill({
    required WasmTable table,
    required int destinationOffset,
    required int? value,
    required int length,
  }) {
    if (destinationOffset > table.length ||
        length > table.length - destinationOffset) {
      throw StateError('table.fill destination out of bounds.');
    }
    if (length == 0) {
      return;
    }
    table.fillRange(destinationOffset, length, value);
  }
}
