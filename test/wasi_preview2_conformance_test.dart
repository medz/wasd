import 'dart:convert';
import 'dart:io';

// SHA-256 stays test-only; package:test already locks crypto.
// ignore: depend_on_referenced_packages
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:wasd/wasi.dart';
import 'package:wasd/wasm.dart';

const _fixturePath =
    'test/fixtures/wasi_preview2/wasmtime_v47_0_3_hello.component.wasm';
const _fixtureSha256 =
    '9bc764eae49b55c963bbce08b5d9caebe176d7e32fdee097a85930495396a329';

void main() {
  group('Wasmtime v47.0.3 WASI 0.2 command component', () {
    test('fixture is fixed and non-empty', () async {
      final bytes = await File(_fixturePath).readAsBytes();

      expect(bytes, isNotEmpty);
      expect(sha256.convert(bytes).toString(), _fixtureSha256);
    });

    test('executes with wasd', () async {
      final bytes = await File(_fixturePath).readAsBytes();
      final component = WasmComponent.decode(bytes);
      final host = WASIPreview2ComponentHost.native(args: [_fixturePath]);

      final result = await WASIPreview2CommandRunner(host).run(component);

      expect(result.exitCode, 0);
      expect(utf8.decode(host.cliHost.stdoutBytes), 'Hello, world!\n');
      expect(host.cliHost.stderrBytes, isEmpty);
    });
  });
}
