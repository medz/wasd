import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'component official runner defaults match pinned wasm-tools features',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'wasd_component_official_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });

      final testsuite = Directory('${temp.path}/component-tests');
      await Directory('${testsuite.path}/values').create(recursive: true);
      await File(
        '${testsuite.path}/values/strings.wast',
      ).writeAsString('(component)');

      final fakeWasmTools = File('${temp.path}/fake_wasm_tools.sh');
      await fakeWasmTools.writeAsString('''
#!/bin/sh
if [ "\$1" = "--version" ]; then
  echo "wasm-tools 1.252.0"
  exit 0
fi

features=""
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = "--features" ]; then
    shift
    features="\$1"
  fi
  shift
done

case "\$features" in
  *cm-async-builtins*)
    echo "old cm-async-builtins feature should not be used" >&2
    exit 2
    ;;
esac
case "\$features" in
  *cm-more-async-builtins*) ;;
  *)
    echo "missing cm-more-async-builtins" >&2
    exit 3
    ;;
esac
case "\$features" in
  *cm-error-context*) ;;
  *)
    echo "missing cm-error-context" >&2
    exit 4
    ;;
esac
exit 0
''');
      await Process.run('chmod', ['+x', fakeWasmTools.path]);

      final jsonPath = '${temp.path}/component.json';
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'tool/component_official_runner.dart',
        '--testsuite-dir=${testsuite.path}',
        '--wasm-tools-bin=${fakeWasmTools.path}',
        '--include-pattern=^values/strings\\.wast\$',
        '--json=$jsonPath',
        '--markdown=${temp.path}/component.md',
      ]);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final payload =
          json.decode(await File(jsonPath).readAsString())
              as Map<String, Object?>;
      expect(payload['status'], 'passed');
      expect(
        payload['features'],
        allOf(
          contains('cm-more-async-builtins'),
          contains('cm-error-context'),
          isNot(contains('cm-async-builtins,')),
        ),
      );
    },
  );

  test(
    'component official runner reports pinned async validator xfails',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'wasd_component_official_xfail_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });

      final testsuite = Directory('${temp.path}/component-tests');
      await Directory('${testsuite.path}/async').create(recursive: true);
      await File(
        '${testsuite.path}/async/cross-abi-calls.wast',
      ).writeAsString('(component)');

      final fakeWasmTools = File('${temp.path}/fake_wasm_tools.sh');
      await fakeWasmTools.writeAsString('''
#!/bin/sh
if [ "\$1" = "--version" ]; then
  echo "wasm-tools 1.252.0"
  exit 0
fi
echo "error: 1 test failures in \$2:" >&2
echo 'the `async` canonical option requires an async function type' >&2
exit 1
''');
      await Process.run('chmod', ['+x', fakeWasmTools.path]);

      final jsonPath = '${temp.path}/component.json';
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'tool/component_official_runner.dart',
        '--testsuite-dir=${testsuite.path}',
        '--wasm-tools-bin=${fakeWasmTools.path}',
        '--include-pattern=^async/cross-abi-calls\\.wast\$',
        '--json=$jsonPath',
        '--markdown=${temp.path}/component.md',
      ]);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final payload =
          json.decode(await File(jsonPath).readAsString())
              as Map<String, Object?>;
      final totals = payload['totals'] as Map<String, Object?>;
      expect(payload['status'], 'passed');
      expect(totals['files_failed'], 0);
      expect(totals['files_xfailed'], 1);
    },
  );

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
