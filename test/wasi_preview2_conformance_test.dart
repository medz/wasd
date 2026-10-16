import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

// Fixture provenance is verified by SHA-256 before execution.
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
  test('executes attributed interface imports by their externnames', () async {
    final component = WasmComponent.decode(
      base64Decode(_nameAttributesCommandBase64),
    );
    expect(component.validate(), isEmpty);
    final random = _CountingRandom();
    final host = WASIPreview2ComponentHost(
      randomHost: WASIPreview2RandomHost(secureRandom: random),
    );

    final result = await WASIPreview2CommandRunner(host).run(component);

    expect(result.exitCode, 0);
    // The guest invokes both the plain-named and version-attributed imports.
    expect(random.wordCalls, 4);
  });

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

    test(
      'executes across hosts sharing one component resource table',
      () async {
        final bytes = await File(_fixturePath).readAsBytes();
        final component = WasmComponent.decode(bytes);
        final componentHost = WASIComponentHost();
        final first = WASIPreview2ComponentHost(componentHost: componentHost);
        final second = WASIPreview2ComponentHost(componentHost: componentHost);

        final firstResult = await WASIPreview2CommandRunner(
          first,
        ).run(component);
        final secondResult = await WASIPreview2CommandRunner(
          second,
        ).run(component);

        expect(firstResult.exitCode, 0);
        expect(secondResult.exitCode, 0);
        expect(utf8.decode(first.cliHost.stdoutBytes), 'Hello, world!\n');
        expect(utf8.decode(second.cliHost.stdoutBytes), 'Hello, world!\n');
      },
    );

    test('executes concurrently across one shared component host', () async {
      final bytes = await File(_fixturePath).readAsBytes();
      final component = WasmComponent.decode(bytes);
      final componentHost = WASIComponentHost();
      final first = WASIPreview2ComponentHost(componentHost: componentHost);
      final second = WASIPreview2ComponentHost(componentHost: componentHost);

      final results = await Future.wait([
        WASIPreview2CommandRunner(first).run(component),
        WASIPreview2CommandRunner(second).run(component),
      ]);

      expect(results.map((result) => result.exitCode), [0, 0]);
      expect(utf8.decode(first.cliHost.stdoutBytes), 'Hello, world!\n');
      expect(utf8.decode(second.cliHost.stdoutBytes), 'Hello, world!\n');
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

final class _CountingRandom implements math.Random {
  var wordCalls = 0;

  @override
  int nextInt(int max) {
    expect(max, 0x100000000);
    wordCalls++;
    return 7;
  }

  @override
  bool nextBool() => throw StateError('Unexpected random bool request.');

  @override
  double nextDouble() => throw StateError('Unexpected random double request.');
}

// Component Model 0220da8 nameattributes encoding. A nested component imports
// `primary` (implements + external-id) and `wasi:random/random@0.2`
// (versionsuffix ".12" + external-id). Both are supplied by their externnames
// from the same standard host interface and invoke get-random-u64. Function,
// nested inline-export, and command export IDs are also metadata only.
// The Core module calls each lowered function, drops both results, and returns
// the successful CLI result. No external compiler is needed to run this input.
const _nameAttributesCommandBase64 =
    'AGFzbQ0AAQAHMQFCAgFAAAB3BAIOZ2V0LXJhbmRvbS11NjQBAhNpZ25vcmVkLWZ1bmN0aW9uLWlkAQAKMAECGXdhc2k6cmFuZG9t'
    'L3JhbmRvbUAwLjIuMTIBAg9pZ25vcmVkLXJvb3QtaWQFAATSAgBhc20NAAEABzgBQgIBQAAAdwQCDmdldC1yYW5kb20tdTY0AQIa'
    'aWdub3JlZC1uZXN0ZWQtZnVuY3Rpb24taWQBAAp7AgIHcHJpbWFyeQIAGXdhc2k6cmFuZG9tL3JhbmRvbUAwLjIuMTICG2h0dHBz'
    'Oi8vZXhhbXBsZS50ZXN0L3JhbmRvbQUAAhZ3YXNpOnJhbmRvbS9yYW5kb21AMC4yAgEDLjEyAhRpZ25vcmVkLXZlcnNpb25lZC1p'
    'ZAUABiUCAQAADmdldC1yYW5kb20tdTY0AQABDmdldC1yYW5kb20tdTY0BR4BAQECBnNlY29uZAECDmlnbm9yZWQtYmFnLWlkAQEG'
    'CwEBAAIGc2Vjb25kCz0CAgVmaXJzdAECEGlnbm9yZWQtZmlyc3QtaWQBAAACBnNlY29uZAECEWlnbm9yZWQtc2Vjb25kLWlkAQIA'
    'BScBAAACB3ByaW1hcnkFABZ3YXNpOnJhbmRvbS9yYW5kb21AMC4yBQAGFAIBAAEFZmlyc3QBAAEGc2Vjb25kCAkCAQAAAAEAAQAC'
    'FAEBAgVmaXJzdAAABnNlY29uZAABAXAAYXNtAQAAAAEJAmAAAX5gAAF/AiACBnJhbmRvbQVmaXJzdAAABnJhbmRvbQZzZWNvbmQA'
    'AAMCAQEHBwEDcnVuAAIKDAEKABAAGhABGkEACwAeBG5hbWUABQRtYWluARACAAVmaXJzdAEGc2Vjb25kAg0BAAABBnJhbmRvbRIA'
    'BgkBAAABAQNydW4HCAJqAABAAAABCAYBAAACAAIFGwEBAQIDcnVuAQIOaWdub3JlZC1ydW4taWQBAgsuAQITd2FzaTpjbGkvcnVu'
    'QDAuMi4xMgECEmlnbm9yZWQtY29tbWFuZC1pZAUCAA==';
