import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'component official runner reports wasm-tools validation-only non-execution coverage',
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
  echo "wasm-tools 1.254.0"
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
      expect(payload['engine'], 'wasm-tools');
      expect(payload['engine_mode'], 'validation-only');
      expect(payload['executes_wasm'], isFalse);
      expect(payload['executes_wasd'], isFalse);
      expect(payload['ignore_error_messages'], isTrue);
      expect(payload['engine_version'], contains('1.254.0'));
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
    'component official runner can use Wasmtime reference execution',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'wasd_component_official_reference_',
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

      final fakeWasmtime = File('${temp.path}/fake_wasmtime.sh');
      await fakeWasmtime.writeAsString('''
#!/bin/sh
if [ "\$1" = "--version" ]; then
  echo "wasmtime 48.0.0 (e8ac8c27f 2026-08-01)"
  exit 0
fi
test "\$1" = "wast" || exit 2
args=" \$* "
case "\$args" in
  *" --ignore-error-messages "*)
    echo "unsupported --ignore-error-messages" >&2
    exit 5
    ;;
esac
case "\$args" in
  *" -Wcomponent-model-async=y "*) ;;
  *) echo "missing component async flag" >&2; exit 3 ;;
esac
case "\$args" in
  *" -Wcomponent-model-threading=y "*) ;;
  *) echo "missing component threading flag" >&2; exit 4 ;;
esac
exit 0
''');
      await Process.run('chmod', ['+x', fakeWasmtime.path]);

      final jsonPath = '${temp.path}/component.json';
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'tool/component_official_runner.dart',
        '--testsuite-dir=${testsuite.path}',
        '--wasmtime-bin=${fakeWasmtime.path}',
        '--features=cm-async,cm-threading,unknown-preview-feature',
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
      expect(payload['engine'], 'wasmtime');
      expect(payload['engine_mode'], 'reference-execution');
      expect(payload['executes_wasm'], isTrue);
      expect(payload['executes_wasd'], isFalse);
      expect(payload['ignore_error_messages'], isFalse);
      expect(payload['engine_version'], contains('e8ac8c27f'));
      expect(
        result.stderr,
        contains(
          'warning: ignoring unknown Wasmtime feature '
          '`unknown-preview-feature`',
        ),
      );
      expect(totals['files_failed'], 0);
      expect(totals['files_passed'], 1);
    },
  );

  test(
    'component official runner bounds each file and writes a report',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'wasd_component_official_timeout_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });

      final testsuite = Directory('${temp.path}/component-tests');
      await Directory('${testsuite.path}/async').create(recursive: true);
      await File(
        '${testsuite.path}/async/a-hang.wast',
      ).writeAsString('(component)');
      await File(
        '${testsuite.path}/async/b-pass.wast',
      ).writeAsString('(component)');
      final fakeWasmTools = File('${temp.path}/fake_wasm_tools.sh');
      await fakeWasmTools.writeAsString('''
#!/bin/sh
if [ "\$1" = "--version" ]; then
  echo "wasm-tools timeout test"
  exit 0
fi
case "\$2" in
  *a-hang.wast) sleep 30 ;;
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
        '--groups=async',
        '--file-timeout-seconds=1',
        '--json=$jsonPath',
        '--markdown=${temp.path}/component.md',
      ]).timeout(const Duration(seconds: 10));

      expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
      final payload =
          json.decode(await File(jsonPath).readAsString())
              as Map<String, Object?>;
      final files = (payload['files'] as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(payload['status'], 'failed');
      expect(payload['file_timeout_seconds'], 1);
      expect(files, hasLength(2));
      expect(files[0]['path'], 'async/a-hang.wast');
      expect(files[0]['timed_out'], isTrue);
      expect(files[0]['exit_code'], 124);
      expect(files[1]['path'], 'async/b-pass.wast');
      expect(files[1]['passed'], isTrue);
    },
  );

  test(
    'component official runner reports argument conflicts as usage',
    () async {
      for (final conflictingArgs in <List<String>>[
        <String>['--all-groups', '--groups=async'],
        <String>[
          '--wasm-tools-bin=/tmp/wasm-tools',
          '--wasmtime-bin=/tmp/wasmtime',
        ],
      ]) {
        final result = await Process.run(Platform.resolvedExecutable, [
          'run',
          'tool/component_official_runner.dart',
          ...conflictingArgs,
        ]);

        expect(result.exitCode, 2);
        expect(result.stderr, contains('Usage:'));
        expect(result.stderr, isNot(contains('Unhandled exception')));
      }
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

  test(
    'core runner validates custom malformed and invalid assertions',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'wasd_spec_custom_assertions_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });

      await File('${temp.path}/custom.wast').writeAsString('(module)');

      final fakeWast2Json = File('${temp.path}/fake_wast2json.sh');
      await fakeWast2Json.writeAsString('''
#!/bin/sh
output=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) shift; output="\$1" ;;
  esac
  shift
done
outdir="\$(dirname "\$output")"
mkdir -p "\$outdir"
printf '(module (@custom))' > "\$outdir/bad-custom.wat"
printf '\\x00asm\\x01\\x00\\x00\\x00\\x01\\x02\\x01\\x00' > "\$outdir/bad-custom.wasm"
cat > "\$output" <<'JSON'
{
  "commands": [
    {
      "type": "assert_malformed_custom",
      "line": 1,
      "filename": "bad-custom.wat",
      "module_type": "text",
      "text": "@custom annotation: missing section name"
    },
    {
      "type": "assert_invalid_custom",
      "line": 2,
      "filename": "bad-custom.wasm",
      "module_type": "binary",
      "text": "@metadata.code.branch_hint annotation: invalid target"
    }
  ]
}
JSON
''');
      await Process.run('chmod', ['+x', fakeWast2Json.path]);

      final fakeWat2Wasm = File('${temp.path}/wat2wasm');
      await fakeWat2Wasm.writeAsString('''
#!/bin/sh
exit 1
''');
      await Process.run('chmod', ['+x', fakeWat2Wasm.path]);

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
      expect(totals['commands_skipped'], 0);
      expect(totals['commands_passed'], 2);
    },
  );

  test(
    'spec runner uses the portable threads check for JS proposals',
    () async {
      final source = await File('tool/spec_runner.dart').readAsString();

      expect(source, contains('js-threads-portable-compile'));
      expect(source, contains('tool/threads_portable_check.dart'));
      expect(source, isNot(contains('test/threads_portable_test.dart')));
    },
  );
}
