import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('core suite collection excludes legacy proposal files', () async {
    final temp = await Directory.systemTemp.createTemp('wasd_spec_runner_');
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    await File('${temp.path}/core.wast').writeAsString('(module)');
    await Directory('${temp.path}/legacy').create();
    await File('${temp.path}/legacy/try_catch.wast').writeAsString('(module)');
    await Directory('${temp.path}/proposals/example').create(recursive: true);
    await File(
      '${temp.path}/proposals/example/proposal.wast',
    ).writeAsString('(module)');

    final fakeWast2Json = File('${temp.path}/fake_wast2json.sh');
    await fakeWast2Json.writeAsString('''
#!/bin/sh
input=""
output=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    *.wast) input="\$1" ;;
    -o) shift; output="\$1" ;;
  esac
  shift
done
case "\$input" in
  */legacy/*)
    echo "legacy file should not be part of the default core suite" >&2
    exit 9
    ;;
esac
mkdir -p "\$(dirname "\$output")"
printf '{"commands":[]}' > "\$output"
''');
    await Process.run('chmod', ['+x', fakeWast2Json.path]);

    final jsonPath = '${temp.path}/result.json';
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'tool/spec_testsuite_runner.dart',
      '--suite=core',
      '--testsuite-dir=${temp.path}',
      '--wast2json=${fakeWast2Json.path}',
      '--no-conversion-cache',
      '--output-json=$jsonPath',
      '--output-md=${temp.path}/result.md',
    ]);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final payload =
        json.decode(await File(jsonPath).readAsString())
            as Map<String, Object?>;
    final totals = payload['totals'] as Map<String, Object?>;
    expect(totals['files_total'], 1);
    expect(totals['files_failed'], 0);
    final groups = payload['group_stats'] as Map<String, Object?>;
    expect(groups.keys, ['core']);
  });
}
