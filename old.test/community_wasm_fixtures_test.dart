import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/wasd.dart';

const String _goFixturePath = 'test/fixtures/community/go_hello_wasip1.wasm';
const String _tinygoFixturePath =
    'test/fixtures/community/tinygo_hello_wasi.wasm';

void main() {
  final goFixture = File(_goFixturePath);
  final tinygoFixture = File(_tinygoFixturePath);

  test(
    'community go fixture runs with wasi preview1',
    () async {
      final result = await _runWasiStartFixture(
        goFixture,
        argv0: 'go_hello_wasip1.wasm',
      );
      expect(result.exitCode, 0);
      expect(result.stdoutText, contains('go-fixture-ok'));
      expect(result.stderrText, isEmpty);
    },
    skip: goFixture.existsSync()
        ? false
        : 'Missing Go fixture. Run: tool/setup_test_fixtures.sh --community-only',
  );

  test(
    'community tinygo fixture runs with wasi preview1',
    () async {
      final result = await _runWasiStartFixture(
        tinygoFixture,
        argv0: 'tinygo_hello_wasi.wasm',
      );
      expect(result.exitCode, 0);
      expect(
        '${result.stdoutText}${result.stderrText}',
        contains('Hello world!'),
      );
    },
    skip: tinygoFixture.existsSync()
        ? false
        : 'Missing TinyGo fixture. Run: tool/setup_test_fixtures.sh --community-only --with-tinygo',
  );
}

Future<_WasiStartResult> _runWasiStartFixture(
  File fixture, {
  required String argv0,
}) async {
  final wasmBytes = await fixture.readAsBytes();
  final stdout = BytesBuilder();
  final stderr = BytesBuilder();
  final wasi = WasiPreview1(
    args: <String>[argv0],
    stdin: Uint8List(0),
    stdoutSink: stdout.add,
    stderrSink: stderr.add,
    fileSystem: WasiInMemoryFileSystem(),
    preferHostIo: false,
  );

  final instance = WasmInstance.fromBytes(wasmBytes, imports: wasi.imports);
  wasi.bindInstance(instance);

  var exitCode = 0;
  try {
    instance.invoke('_start');
  } on WasiProcExit catch (error) {
    exitCode = error.exitCode;
  }

  return _WasiStartResult(
    exitCode: exitCode,
    stdoutText: String.fromCharCodes(stdout.takeBytes()),
    stderrText: String.fromCharCodes(stderr.takeBytes()),
  );
}

final class _WasiStartResult {
  const _WasiStartResult({
    required this.exitCode,
    required this.stdoutText,
    required this.stderrText,
  });

  final int exitCode;
  final String stdoutText;
  final String stderrText;
}
