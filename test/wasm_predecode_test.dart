import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/module.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/opcode.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/predecode.dart';

void main() {
  group('WasmPredecoder', () {
    test('reuses pure no-immediate instruction objects', () {
      final decoded = WasmPredecoder.decode(
        WasmCodeBody(
          locals: const <WasmLocalDecl>[],
          instructions: Uint8List.fromList(const <int>[
            Opcodes.i32Add,
            Opcodes.i32Add,
            Opcodes.i32Const,
            1,
            Opcodes.i32Const,
            1,
            Opcodes.end,
          ]),
        ),
        const <WasmFunctionType>[],
      );

      expect(identical(decoded.instructions[0], decoded.instructions[1]), true);
      expect(
        identical(decoded.instructions[2], decoded.instructions[3]),
        false,
      );
      expect(decoded.instructions[2].immediate, 1);
      expect(decoded.instructions[3].immediate, 1);
    });

    test('reuses type-indexed block signature lists', () {
      final functionType = WasmFunctionType(
        params: const <WasmValueType>[WasmValueType.i32],
        results: const <WasmValueType>[WasmValueType.i64],
        paramTypeSignatures: const <String>['7f'],
        resultTypeSignatures: const <String>['7e'],
        kind: WasmCompositeTypeKind.function,
      );

      final decoded = WasmPredecoder.decode(
        WasmCodeBody(
          locals: const <WasmLocalDecl>[],
          instructions: Uint8List.fromList(const <int>[
            Opcodes.block,
            0x00,
            Opcodes.end,
            Opcodes.end,
          ]),
        ),
        <WasmFunctionType>[functionType],
      );

      expect(
        identical(
          decoded.instructions[0].blockParameterTypeSignatures,
          functionType.paramTypeSignatures,
        ),
        true,
      );
      expect(
        identical(
          decoded.instructions[0].blockResultTypeSignatures,
          functionType.resultTypeSignatures,
        ),
        true,
      );
    });
  });
}
