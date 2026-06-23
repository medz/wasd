import 'dart:io';

import 'package:test/test.dart';

import 'support/wasm_fixtures.dart';

void main() {
  test('Preview1 testsuite runner executes WASI command modules', () async {
    final temp = await Directory.systemTemp.createTemp('wasd_wasi_runner_');
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final module = File('${temp.path}/read_preopen.wasm');
    await module.writeAsBytes(wasiReadPreopenFileModuleBytes());
    await File('${temp.path}/input.txt').writeAsString('wasd');

    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'tool/wasi_testsuite_preview1_runner.dart',
      '--dir',
      '${temp.path}::/',
      module.path,
      'guest-arg',
    ]);

    expect(result.exitCode, 0);
    expect(result.stderr, isEmpty);
  });
}
