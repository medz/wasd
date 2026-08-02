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
const _exitWithCodeFixturePath =
    'test/fixtures/wasi_preview2/'
    'wasi_cli_0_2_12_exit_with_code.component.wasm';
const _exitWithCodeFixtureSha256 =
    '5728b22e11f5187a874d40a21545120aae1e59430d55ac3f0b8ba69f7a8e0424';
const _exitWithCodeSourcePath =
    'test/fixtures/wasi_preview2/'
    'wasi_cli_0_2_12_exit_with_code.component.wat';
const _exitWithCodeSourceSha256 =
    'e743b5e0f5f88de84b9a4d00684b422f633ec06d97c1eef4fabb00b8b7d9b313';

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

  group('WASI CLI 0.2.12 exit-with-code command component', () {
    test('fixture is fixed and valid', () async {
      final source = await File(_exitWithCodeSourcePath).readAsBytes();
      final bytes = await File(_exitWithCodeFixturePath).readAsBytes();

      expect(source, hasLength(1068));
      expect(sha256.convert(source).toString(), _exitWithCodeSourceSha256);
      expect(bytes, hasLength(488));
      expect(sha256.convert(bytes).toString(), _exitWithCodeFixtureSha256);
      expect(WasmComponent.decode(bytes).validate(), isEmpty);
    });

    test('returns the requested process exit code', () async {
      final bytes = await File(_exitWithCodeFixturePath).readAsBytes();
      final component = WasmComponent.decode(bytes);
      final host = WASIPreview2ComponentHost.native();

      final result = await WASIPreview2CommandRunner(host).run(component);

      expect(result.exitCode, 7);
      expect(host.cliHost.stdoutBytes, isEmpty);
      expect(host.cliHost.stderrBytes, isEmpty);
    });
  });
}
