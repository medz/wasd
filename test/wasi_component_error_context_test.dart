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
      expect(result.length, utf8.encode('component failed').length);
      final bytes = Uint8List.view(memory.buffer);
      expect(
        utf8.decode(
          bytes.sublist(result.pointer, result.pointer + result.length),
        ),
        'component failed',
      );
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

    test('rejects non-UTF-8 canonical string encodings', () {
      final host = WASIComponentErrorContextHost();

      expect(
        () => host.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.errorContextNew,
            options: [
              WasmComponentCanonicalOption(
                kind: WasmComponentCanonicalOptionKind.stringEncodingUtf16,
              ),
            ],
          ),
        ),
        throwsUnsupportedError,
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
