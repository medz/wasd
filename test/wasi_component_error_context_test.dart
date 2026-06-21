import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/error_context.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/memory.dart';

void main() {
  group('WASIComponentErrorContextHost', () {
    test('creates, reads, and drops debug messages', () {
      final host = WASIComponentErrorContextHost();

      final handle = host.create('network unreachable');

      expect(handle, isA<int>());
      expect(host.debugMessage(handle), 'network unreachable');
      expect(host.table.activeCount, 1);

      host.drop(handle);

      expect(host.table.activeCount, 0);
      expect(() => host.debugMessage(handle), throwsStateError);
    });

    test('binds decoded canonical new and drop definitions as a program', () {
      final component = WasmComponent.decode(
        _canonicalErrorContextNewDropProgramBytes(),
      );
      expect(component.validate(), isEmpty);
      final host = WASIComponentErrorContextHost();
      final program = host.bindCanonicalDefinitions(component);

      expect(program.operations.map((operation) => operation.kind), [
        WasmComponentCanonicalKind.errorContextNew,
        WasmComponentCanonicalKind.errorContextDrop,
      ]);

      final handle = program.invoke(0, <Object?>['bad descriptor']);

      expect(handle, isA<int>());
      expect(host.debugMessage(handle as int), 'bad descriptor');
      expect(program.invoke(1, <Object?>[handle]), isNull);
      expect(host.table.activeCount, 0);
    });

    test('binds debug-message canonical definitions', () {
      final host = WASIComponentErrorContextHost();
      final newOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextNew,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      );
      final debugOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextDebugMessage,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.realloc,
              index: 0,
            ),
          ],
        ),
      );
      final dropOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextDrop,
        ),
      );

      final handle = newOperation.create('component failed');

      expect(debugOperation.debugMessage(handle), 'component failed');
      dropOperation.drop(handle);
      expect(() => debugOperation.debugMessage(handle), throwsStateError);
    });

    test('reads error-context.new messages from canonical UTF-8 memory', () {
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final bytes = Uint8List.view(memory.buffer);
      final messageBytes = utf8.encode('héllo component');
      bytes.setRange(32, 32 + messageBytes.length, messageBytes);
      final host = WASIComponentErrorContextHost();
      final operation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextNew,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.stringEncodingUtf8,
            ),
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      );

      final handle = operation.createFromMemory(
        memory,
        32,
        messageBytes.length,
      );

      expect(host.debugMessage(handle), 'héllo component');
    });

    test('writes debug-message results to canonical UTF-8 memory', () {
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final host = WASIComponentErrorContextHost();
      final newOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextNew,
        ),
      );
      final debugOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextDebugMessage,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.stringEncodingUtf8,
            ),
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.realloc,
              index: 0,
            ),
          ],
        ),
      );
      final handle = newOperation.create('component failed');
      var nextPointer = 128;

      final result = debugOperation.debugMessageToMemory(handle, memory, (
        oldPointer,
        oldSize,
        alignment,
        newSize,
      ) {
        expect(oldPointer, 0);
        expect(oldSize, 0);
        expect(alignment, 1);
        final pointer = nextPointer;
        nextPointer += newSize;
        return pointer;
      });

      expect(result.pointer, 128);
      expect(result.canonicalLength, utf8.encode('component failed').length);
      expect(result.byteLength, utf8.encode('component failed').length);
      final bytes = Uint8List.view(memory.buffer);
      expect(
        utf8.decode(
          bytes.sublist(result.pointer, result.pointer + result.byteLength),
        ),
        'component failed',
      );
    });

    test('reads error-context.new messages from canonical UTF-16 memory', () {
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final bytes = Uint8List.view(memory.buffer);
      final message = 'component \u2603 failed';
      final messageBytes = _utf16Le(message);
      bytes.setRange(32, 32 + messageBytes.length, messageBytes);
      final host = WASIComponentErrorContextHost();
      final operation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextNew,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.stringEncodingUtf16,
            ),
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      );

      final handle = operation.createFromMemory(
        memory,
        32,
        message.codeUnits.length,
      );

      expect(host.debugMessage(handle), message);
    });

    test(
      'reads error-context.new messages from latin1+utf16 canonical memory',
      () {
        final memory = Memory(const MemoryDescriptor(initial: 1));
        final bytes = Uint8List.view(memory.buffer);
        final latin1Message = 'caf\u00e9';
        final latin1Bytes = Uint8List.fromList(latin1.encode(latin1Message));
        bytes.setRange(32, 32 + latin1Bytes.length, latin1Bytes);
        final utf16Message = 'component \u2603 failed';
        final utf16Bytes = _utf16Le(utf16Message);
        bytes.setRange(96, 96 + utf16Bytes.length, utf16Bytes);
        final host = WASIComponentErrorContextHost();
        final operation = host.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.errorContextNew,
            options: [
              WasmComponentCanonicalOption(
                kind:
                    WasmComponentCanonicalOptionKind.stringEncodingLatin1Utf16,
              ),
              WasmComponentCanonicalOption(
                kind: WasmComponentCanonicalOptionKind.memory,
                index: 0,
              ),
            ],
          ),
        );

        final latin1Handle = operation.createFromMemory(
          memory,
          32,
          latin1Bytes.length,
        );
        final utf16Handle = operation.createFromMemory(
          memory,
          96,
          _latin1Utf16Tag | utf16Message.codeUnits.length,
        );

        expect(host.debugMessage(latin1Handle), latin1Message);
        expect(host.debugMessage(utf16Handle), utf16Message);
      },
    );

    test('writes debug-message results to canonical UTF-16 memory', () {
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final host = WASIComponentErrorContextHost();
      final newOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextNew,
        ),
      );
      final debugOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextDebugMessage,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.stringEncodingUtf16,
            ),
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.realloc,
              index: 0,
            ),
          ],
        ),
      );
      const message = 'component \u2603 failed';
      final handle = newOperation.create(message);

      final result = debugOperation.debugMessageToMemory(handle, memory, (
        oldPointer,
        oldSize,
        alignment,
        newSize,
      ) {
        expect(oldPointer, 0);
        expect(oldSize, 0);
        expect(alignment, 2);
        expect(newSize, message.codeUnits.length * 2);
        return 128;
      });

      expect(result.pointer, 128);
      expect(result.canonicalLength, message.codeUnits.length);
      expect(result.byteLength, message.codeUnits.length * 2);
      final bytes = Uint8List.view(memory.buffer);
      expect(
        _decodeUtf16Le(
          Uint8List.sublistView(
            bytes,
            result.pointer,
            result.pointer + result.byteLength,
          ),
        ),
        message,
      );
    });

    test('writes latin1+utf16 debug-message results in compact form', () {
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final host = WASIComponentErrorContextHost();
      final newOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextNew,
        ),
      );
      final debugOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextDebugMessage,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.stringEncodingLatin1Utf16,
            ),
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.realloc,
              index: 0,
            ),
          ],
        ),
      );
      final latin1Handle = newOperation.create('caf\u00e9');
      final utf16Handle = newOperation.create('component \u2603 failed');

      final latin1Result = debugOperation.debugMessageToMemory(
        latin1Handle,
        memory,
        (oldPointer, oldSize, alignment, newSize) {
          expect(alignment, 2);
          expect(newSize, 4);
          return 128;
        },
      );
      final utf16Result = debugOperation.debugMessageToMemory(
        utf16Handle,
        memory,
        (oldPointer, oldSize, alignment, newSize) {
          expect(alignment, 2);
          return 256;
        },
      );

      final bytes = Uint8List.view(memory.buffer);
      expect(latin1Result.canonicalLength, 4);
      expect(latin1Result.byteLength, 4);
      expect(
        latin1.decode(
          bytes.sublist(
            latin1Result.pointer,
            latin1Result.pointer + latin1Result.byteLength,
          ),
        ),
        'caf\u00e9',
      );
      expect(utf16Result.canonicalLength & _latin1Utf16Tag, _latin1Utf16Tag);
      expect(utf16Result.canonicalLength & _latin1Utf16LengthMask, 18);
      expect(utf16Result.byteLength, 36);
      expect(
        _decodeUtf16Le(
          Uint8List.sublistView(
            bytes,
            utf16Result.pointer,
            utf16Result.pointer + utf16Result.byteLength,
          ),
        ),
        'component \u2603 failed',
      );
    });

    test('writes debug-message result records to canonical memory', () {
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final host = WASIComponentErrorContextHost();
      final newOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextNew,
        ),
      );
      final debugOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextDebugMessage,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.stringEncodingUtf8,
            ),
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.realloc,
              index: 0,
            ),
          ],
        ),
      );
      final handle = newOperation.create('component failed');

      final result = debugOperation.debugMessageIntoMemory(
        handle,
        memory,
        32,
        (oldPointer, oldSize, alignment, newSize) => 128,
      );

      expect(_readU32(memory, 32), result.pointer);
      expect(_readU32(memory, 36), result.canonicalLength);
    });

    test('rejects out-of-bounds canonical string memory ranges', () {
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final host = WASIComponentErrorContextHost();
      final newOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextNew,
        ),
      );
      final debugOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextDebugMessage,
        ),
      );
      final handle = newOperation.create('too large');

      expect(
        () => newOperation.createFromMemory(
          memory,
          memory.buffer.lengthInBytes - 2,
          4,
        ),
        throwsRangeError,
      );
      expect(
        () => debugOperation.debugMessageToMemory(
          handle,
          memory,
          (oldPointer, oldSize, alignment, newSize) =>
              memory.buffer.lengthInBytes - 1,
        ),
        throwsRangeError,
      );
    });

    test('rejects unaligned UTF-16 canonical string pointers', () {
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final host = WASIComponentErrorContextHost();
      final operation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextNew,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.stringEncodingUtf16,
            ),
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      );

      expect(() => operation.createFromMemory(memory, 33, 4), throwsStateError);
    });

    test('rejects malformed UTF-16 canonical string memory', () {
      final memory = Memory(const MemoryDescriptor(initial: 1));
      final bytes = Uint8List.view(memory.buffer);
      bytes[32] = 0x00;
      bytes[33] = 0xd8;
      final host = WASIComponentErrorContextHost();
      final operation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextNew,
          options: [
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.stringEncodingUtf16,
            ),
            WasmComponentCanonicalOption(
              kind: WasmComponentCanonicalOptionKind.memory,
              index: 0,
            ),
          ],
        ),
      );

      expect(
        () => operation.createFromMemory(memory, 32, 1),
        throwsFormatException,
      );
    });

    test('invokes manual canonical debug-message programs', () {
      final host = WASIComponentErrorContextHost();
      final program = WASIComponentCanonicalErrorContextProgram(
        operations: [
          host.bindCanonicalDefinition(
            const WasmComponentCanonicalDefinition(
              kind: WasmComponentCanonicalKind.errorContextNew,
            ),
          ),
          host.bindCanonicalDefinition(
            const WasmComponentCanonicalDefinition(
              kind: WasmComponentCanonicalKind.errorContextDebugMessage,
            ),
          ),
          host.bindCanonicalDefinition(
            const WasmComponentCanonicalDefinition(
              kind: WasmComponentCanonicalKind.errorContextDrop,
            ),
          ),
        ],
      );

      final handle = program.invoke(0, <Object?>['timeout']);

      expect(program.invoke(1, <Object?>[handle]), 'timeout');
      expect(program.invoke(2, <Object?>[handle]), isNull);
      expect(() => program.invoke(1, <Object?>[handle]), throwsStateError);
    });

    test('rejects invalid messages, handles, and canonical kinds', () {
      final host = WASIComponentErrorContextHost();
      final program = WASIComponentCanonicalErrorContextProgram(
        operations: [
          host.bindCanonicalDefinition(
            const WasmComponentCanonicalDefinition(
              kind: WasmComponentCanonicalKind.errorContextNew,
            ),
          ),
          host.bindCanonicalDefinition(
            const WasmComponentCanonicalDefinition(
              kind: WasmComponentCanonicalKind.errorContextDrop,
            ),
          ),
        ],
      );

      expect(() => program.invoke(0, const <Object?>[7]), throwsStateError);
      expect(() => program.invoke(1, const <Object?>['bad']), throwsStateError);
      expect(() => program.invoke(3, const <Object?>[]), throwsStateError);
      expect(
        () => host.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.resourceNew,
            typeIndex: 0,
          ),
        ),
        throwsUnsupportedError,
      );
    });
  });
}

Uint8List _canonicalErrorContextNewDropProgramBytes() =>
    Uint8List.fromList(<int>[
      ..._coreMemoryExportComponentBytes(),
      0x08,
      0x06,
      0x02,
      0x1c,
      0x01,
      0x03,
      0x00,
      0x1e,
    ]);

Uint8List _coreMemoryExportComponentBytes() => Uint8List.fromList(const <int>[
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

const int _latin1Utf16Tag = 0x80000000;
const int _latin1Utf16LengthMask = 0x7fffffff;

Uint8List _utf16Le(String value) {
  final bytes = Uint8List(value.codeUnits.length * 2);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < value.codeUnits.length; i++) {
    data.setUint16(i * 2, value.codeUnits[i], Endian.little);
  }
  return bytes;
}

String _decodeUtf16Le(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return String.fromCharCodes([
    for (var i = 0; i < bytes.length; i += 2) data.getUint16(i, Endian.little),
  ]);
}

int _readU32(Memory memory, int pointer) {
  return ByteData.view(memory.buffer).getUint32(pointer, Endian.little);
}
