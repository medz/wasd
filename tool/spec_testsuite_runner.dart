import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wasd/wasd.dart';

enum _SpecSuite { core, proposal, all }

final class _SpecRunnerFailure implements Exception {
  _SpecRunnerFailure(this.reason, this.details);

  final String reason;
  final String details;

  @override
  String toString() => '$reason: $details';
}

final class _CommandResult {
  const _CommandResult._({
    required this.passed,
    required this.skipped,
    this.reason,
    this.details,
  });

  final bool passed;
  final bool skipped;
  final String? reason;
  final String? details;

  factory _CommandResult.pass() =>
      const _CommandResult._(passed: true, skipped: false);

  factory _CommandResult.skip(String reason, String details) =>
      _CommandResult._(
        passed: false,
        skipped: true,
        reason: reason,
        details: details,
      );

  factory _CommandResult.fail(String reason, String details) =>
      _CommandResult._(
        passed: false,
        skipped: false,
        reason: reason,
        details: details,
      );
}

final class _ExpectedValue {
  const _ExpectedValue.i32(this.value)
    : type = 'i32',
      isNaN = false,
      floatValue = null;
  const _ExpectedValue.i64(this.value)
    : type = 'i64',
      isNaN = false,
      floatValue = null;
  const _ExpectedValue.f32(this.floatValue)
    : type = 'f32',
      isNaN = false,
      value = null;
  const _ExpectedValue.f64(this.floatValue)
    : type = 'f64',
      isNaN = false,
      value = null;
  const _ExpectedValue.nan(this.type)
    : isNaN = true,
      value = null,
      floatValue = null;

  final String type;
  final bool isNaN;
  final int? value;
  final double? floatValue;
}

final class _FileResult {
  _FileResult({
    required this.path,
    required this.group,
    required this.commandsSeen,
    required this.commandsPassed,
    required this.commandsFailed,
    required this.commandsSkipped,
    required this.passed,
    this.firstFailureLine,
    this.firstFailureReason,
    this.firstFailureDetails,
    this.wast2jsonStdout,
    this.wast2jsonStderr,
  });

  final String path;
  final String group;
  final int commandsSeen;
  final int commandsPassed;
  final int commandsFailed;
  final int commandsSkipped;
  final bool passed;
  final int? firstFailureLine;
  final String? firstFailureReason;
  final String? firstFailureDetails;
  final String? wast2jsonStdout;
  final String? wast2jsonStderr;

  Map<String, Object?> toJson() => {
    'path': path,
    'group': group,
    'passed': passed,
    'commands_seen': commandsSeen,
    'commands_passed': commandsPassed,
    'commands_failed': commandsFailed,
    'commands_skipped': commandsSkipped,
    'first_failure_line': firstFailureLine,
    'first_failure_reason': firstFailureReason,
    'first_failure_details': firstFailureDetails,
    'wast2json_stdout': wast2jsonStdout,
    'wast2json_stderr': wast2jsonStderr,
  };
}

final class _ScriptExecutionState {
  _ScriptExecutionState(this.workDir);

  final Directory workDir;

  final Map<String, WasmInstance> _namedModules = <String, WasmInstance>{};
  final Map<String, WasmInstance> _registeredModules = <String, WasmInstance>{};
  final WasmMemory _spectestMemory = WasmMemory(minPages: 1, maxPages: 2);
  final WasmTable _spectestTable = WasmTable(
    refType: WasmRefType.funcref,
    min: 10,
    max: 20,
  );

  WasmInstance? _currentInstance;

  WasmFeatureSet get _features =>
      WasmFeatureSet.layeredDefaults(profile: WasmFeatureProfile.full);

  _CommandResult executeCommand(Map<String, Object?> command) {
    final type = command['type'];
    if (type is! String) {
      return _CommandResult.fail(
        'invalid-command',
        'Missing string command type.',
      );
    }

    try {
      switch (type) {
        case 'module':
          return _handleModule(command);
        case 'register':
          return _handleRegister(command);
        case 'action':
          _runAction(_readAction(command));
          return _CommandResult.pass();
        case 'assert_return':
          return _handleAssertReturn(command);
        case 'assert_trap':
          return _handleAssertTrap(command);
        case 'assert_invalid':
        case 'assert_unlinkable':
        case 'assert_uninstantiable':
          return _handleAssertModuleFails(command);
        case 'assert_malformed':
          return _handleAssertMalformed(command);
        default:
          return _CommandResult.skip(
            'unsupported-command',
            'Command type `$type` is not supported yet.',
          );
      }
    } on _SpecRunnerFailure catch (error) {
      return _CommandResult.fail(error.reason, error.details);
    } catch (error) {
      return _CommandResult.fail('unhandled-exception', '$error');
    }
  }

  _CommandResult _handleModule(Map<String, Object?> command) {
    final filename = command['filename'];
    if (filename is! String || filename.isEmpty) {
      return _CommandResult.fail('module-missing-filename', '$command');
    }

    final moduleBytes = _readBinaryModule(filename);
    final module = WasmModule.decode(moduleBytes, features: _features);
    final instance = WasmInstance.fromModule(
      module,
      imports: _buildImports(module),
      features: _features,
    );
    _currentInstance = instance;
    final name = command['name'];
    if (name is String && name.isNotEmpty) {
      _namedModules[name] = instance;
    }
    return _CommandResult.pass();
  }

  _CommandResult _handleRegister(Map<String, Object?> command) {
    final alias = command['as'];
    if (alias is! String || alias.isEmpty) {
      return _CommandResult.fail('register-missing-alias', '$command');
    }

    final name = command['name'];
    final instance = switch (name) {
      String() when name.isNotEmpty => _namedModules[name],
      _ => _currentInstance,
    };
    if (instance == null) {
      return _CommandResult.fail(
        'register-module-not-found',
        'No module available for alias `$alias`.',
      );
    }
    _registeredModules[alias] = instance;
    return _CommandResult.pass();
  }

  _CommandResult _handleAssertReturn(Map<String, Object?> command) {
    final action = _readAction(command);
    final expectedRaw = command['expected'];
    if (expectedRaw is! List) {
      return _CommandResult.fail(
        'assert-return-invalid-expected',
        'Expected value list is missing.',
      );
    }

    final expectedValues = <_ExpectedValue>[];
    for (final raw in expectedRaw) {
      if (raw is! Map) {
        return _CommandResult.fail(
          'assert-return-invalid-expected-entry',
          '$raw',
        );
      }
      expectedValues.add(_parseExpectedValue(raw.cast<String, Object?>()));
    }

    final actualValues = _runAction(action);
    if (actualValues.length != expectedValues.length) {
      return _CommandResult.fail(
        'assert-return-arity-mismatch',
        'expected=${expectedValues.length} actual=${actualValues.length}',
      );
    }

    for (var i = 0; i < expectedValues.length; i++) {
      final expected = expectedValues[i];
      final actual = actualValues[i];
      if (!_matchExpected(actual, expected)) {
        return _CommandResult.fail(
          'assert-return-mismatch',
          'index=$i expected=${_expectedToString(expected)} actual=$actual',
        );
      }
    }

    return _CommandResult.pass();
  }

  _CommandResult _handleAssertTrap(Map<String, Object?> command) {
    final action = _readAction(command);
    try {
      _runAction(action);
      return _CommandResult.fail('assert-trap-not-trapped', '$command');
    } on _SpecRunnerFailure catch (error) {
      return _CommandResult.fail(error.reason, error.details);
    } catch (_) {
      return _CommandResult.pass();
    }
  }

  _CommandResult _handleAssertModuleFails(Map<String, Object?> command) {
    final moduleType = command['module_type'];
    if (moduleType is String && moduleType != 'binary') {
      return _CommandResult.skip(
        'unsupported-module-type',
        'module_type `$moduleType` is not binary.',
      );
    }

    final filename = command['filename'];
    if (filename is! String || filename.isEmpty) {
      return _CommandResult.fail('assert-module-missing-filename', '$command');
    }

    try {
      final moduleBytes = _readBinaryModule(filename);
      final module = WasmModule.decode(moduleBytes, features: _features);
      WasmInstance.fromModule(
        module,
        imports: _buildImports(module),
        features: _features,
      );
      return _CommandResult.fail(
        'assert-module-unexpected-success',
        '$command',
      );
    } on _SpecRunnerFailure catch (error) {
      return _CommandResult.fail(error.reason, error.details);
    } catch (_) {
      return _CommandResult.pass();
    }
  }

  _CommandResult _handleAssertMalformed(Map<String, Object?> command) {
    final moduleType = command['module_type'];
    if (moduleType is String && moduleType == 'text') {
      return _CommandResult.skip(
        'unsupported-text-malformed',
        'Text malformed assertions are delegated to wabt.',
      );
    }
    return _handleAssertModuleFails(command);
  }

  Map<String, Object?> _readAction(Map<String, Object?> command) {
    final action = command['action'];
    if (action is! Map) {
      throw _SpecRunnerFailure('command-missing-action', '$command');
    }
    return action.cast<String, Object?>();
  }

  Uint8List _readBinaryModule(String filename) {
    final file = File('${workDir.path}/$filename');
    if (!file.existsSync()) {
      throw _SpecRunnerFailure(
        'module-file-missing',
        'Generated file not found: ${file.path}',
      );
    }
    return file.readAsBytesSync();
  }

  List<Object?> _runAction(Map<String, Object?> action) {
    final type = action['type'];
    if (type is! String) {
      throw _SpecRunnerFailure('invalid-action', '$action');
    }

    final instance = _resolveActionInstance(action);
    switch (type) {
      case 'invoke':
        final field = action['field'];
        if (field is! String || field.isEmpty) {
          throw _SpecRunnerFailure('invoke-missing-field', '$action');
        }
        final rawArgs = action['args'];
        final args = <Object?>[];
        if (rawArgs is List) {
          for (final raw in rawArgs) {
            if (raw is! Map) {
              throw _SpecRunnerFailure('invoke-invalid-arg', '$raw');
            }
            args.add(_parseActionArg(raw.cast<String, Object?>()));
          }
        }
        return instance.invokeMulti(field, args);
      case 'get':
        final field = action['field'];
        if (field is! String || field.isEmpty) {
          throw _SpecRunnerFailure('get-missing-field', '$action');
        }
        return [instance.readGlobal(field)];
      default:
        throw _SpecRunnerFailure(
          'unsupported-action',
          'Action type `$type` is not supported.',
        );
    }
  }

  WasmInstance _resolveActionInstance(Map<String, Object?> action) {
    final moduleName = action['module'];
    if (moduleName is String && moduleName.isNotEmpty) {
      final named = _namedModules[moduleName] ?? _registeredModules[moduleName];
      if (named != null) {
        return named;
      }
      throw _SpecRunnerFailure(
        'action-module-not-found',
        'Unknown module reference `$moduleName`.',
      );
    }

    final current = _currentInstance;
    if (current == null) {
      throw _SpecRunnerFailure(
        'action-no-current-module',
        'Action requires a current module but none is active.',
      );
    }
    return current;
  }

  WasmImports _buildImports(WasmModule targetModule) {
    final expectedFunctionImports = <String, WasmFunctionType>{};
    for (final import in targetModule.imports) {
      if (import.kind != WasmImportKind.function) {
        continue;
      }
      final typeIndex = import.functionTypeIndex;
      if (typeIndex == null ||
          typeIndex < 0 ||
          typeIndex >= targetModule.types.length) {
        continue;
      }
      expectedFunctionImports[import.key] = targetModule.types[typeIndex];
    }

    final functions = <String, WasmHostFunction>{
      WasmImports.key('spectest', 'print'): (_) => null,
      WasmImports.key('spectest', 'print_i32'): (_) => null,
      WasmImports.key('spectest', 'print_i64'): (_) => null,
      WasmImports.key('spectest', 'print_f32'): (_) => null,
      WasmImports.key('spectest', 'print_f64'): (_) => null,
      WasmImports.key('spectest', 'print_i32_f32'): (_) => null,
      WasmImports.key('spectest', 'print_f64_f64'): (_) => null,
      WasmImports.key('spectest', 'print_f32_f32'): (_) => null,
      WasmImports.key('spectest', 'print_i32_i32'): (_) => null,
    };
    final globals = <String, Object?>{
      WasmImports.key('spectest', 'global_i32'): 666,
      WasmImports.key('spectest', 'global_i64'): 666,
      WasmImports.key('spectest', 'global_f32'): 666.0,
      WasmImports.key('spectest', 'global_f64'): 666.0,
    };
    final memories = <String, WasmMemory>{
      WasmImports.key('spectest', 'memory'): _spectestMemory,
    };
    final tables = <String, WasmTable>{
      WasmImports.key('spectest', 'table'): _spectestTable,
    };

    for (final entry in _registeredModules.entries) {
      final alias = entry.key;
      final instance = entry.value;
      for (final export in instance.exportedFunctions) {
        final key = WasmImports.key(alias, export);
        final expectedType = expectedFunctionImports[key];
        if (expectedType == null) {
          continue;
        }
        final actualType = instance.exportedFunctionType(export);
        if (!_functionTypesEqual(expectedType, actualType)) {
          continue;
        }
        functions[key] = (args) => instance.invoke(export, args);
      }
      for (final export in instance.exportedGlobals) {
        final key = WasmImports.key(alias, export);
        globals[key] = instance.readGlobal(export);
      }
      for (final export in instance.exportedMemories) {
        final key = WasmImports.key(alias, export);
        memories[key] = instance.exportedMemory(export);
      }
      for (final export in instance.exportedTables) {
        final key = WasmImports.key(alias, export);
        tables[key] = instance.exportedTable(export);
      }
    }

    return WasmImports(
      functions: functions,
      globals: globals,
      memories: memories,
      tables: tables,
    );
  }

  static Object? _parseActionArg(Map<String, Object?> raw) {
    final type = raw['type'];
    final value = raw['value'];
    if (type is! String) {
      throw _SpecRunnerFailure('invalid-arg-type', '$raw');
    }
    if (value is! String) {
      throw _SpecRunnerFailure('invalid-arg-value', '$raw');
    }

    switch (type) {
      case 'i32':
        return _signedBits(BigInt.parse(value), 32);
      case 'i64':
        return _signedBits(BigInt.parse(value), 64);
      case 'f32':
        return _parseFloating(value);
      case 'f64':
        return _parseFloating(value);
      default:
        throw _SpecRunnerFailure(
          'unsupported-arg-type',
          'Argument type `$type` is not supported yet.',
        );
    }
  }

  static _ExpectedValue _parseExpectedValue(Map<String, Object?> raw) {
    final type = raw['type'];
    final value = raw['value'];
    if (type is! String) {
      throw _SpecRunnerFailure('invalid-expected-type', '$raw');
    }
    if (value is! String) {
      throw _SpecRunnerFailure('invalid-expected-value', '$raw');
    }

    switch (type) {
      case 'i32':
        return _ExpectedValue.i32(_signedBits(BigInt.parse(value), 32));
      case 'i64':
        return _ExpectedValue.i64(_signedBits(BigInt.parse(value), 64));
      case 'f32':
        if (value.startsWith('nan:')) {
          return const _ExpectedValue.nan('f32');
        }
        return _ExpectedValue.f32(_parseFloating(value));
      case 'f64':
        if (value.startsWith('nan:')) {
          return const _ExpectedValue.nan('f64');
        }
        return _ExpectedValue.f64(_parseFloating(value));
      default:
        throw _SpecRunnerFailure(
          'unsupported-expected-type',
          'Expected type `$type` is not supported yet.',
        );
    }
  }

  static bool _matchExpected(Object? actual, _ExpectedValue expected) {
    switch (expected.type) {
      case 'i32':
        return actual is int && actual.toSigned(32) == expected.value;
      case 'i64':
        return actual is int &&
            _signedBits(BigInt.from(actual), 64) == expected.value;
      case 'f32':
        if (actual is! double) {
          return false;
        }
        if (expected.isNaN) {
          return actual.isNaN;
        }
        if (expected.floatValue == null) {
          return false;
        }
        return _f32Bits(actual) == _f32Bits(expected.floatValue!);
      case 'f64':
        if (actual is! double) {
          return false;
        }
        if (expected.isNaN) {
          return actual.isNaN;
        }
        if (expected.floatValue == null) {
          return false;
        }
        return _f64Bits(actual) == _f64Bits(expected.floatValue!);
      default:
        return false;
    }
  }

  static int _signedBits(BigInt value, int bits) {
    final width = BigInt.one << bits;
    final mask = width - BigInt.one;
    var normalized = value & mask;
    final signBit = BigInt.one << (bits - 1);
    if ((normalized & signBit) != BigInt.zero) {
      normalized -= width;
    }
    return normalized.toInt();
  }

  static double _parseFloating(String value) {
    switch (value) {
      case 'inf':
      case '+inf':
      case 'infinity':
      case '+infinity':
        return double.infinity;
      case '-inf':
      case '-infinity':
        return double.negativeInfinity;
      case 'nan':
      case '+nan':
      case '-nan':
        return double.nan;
      default:
        return double.parse(value);
    }
  }

  static int _f32Bits(double value) {
    final data = ByteData(4)..setFloat32(0, value, Endian.little);
    return data.getUint32(0, Endian.little);
  }

  static int _f64Bits(double value) {
    final data = ByteData(8)..setFloat64(0, value, Endian.little);
    final low = data.getUint32(0, Endian.little);
    final high = data.getUint32(4, Endian.little);
    return (BigInt.from(high) << 32 | BigInt.from(low)).toInt();
  }

  static String _expectedToString(_ExpectedValue expected) {
    if (expected.isNaN) {
      return '${expected.type}(nan)';
    }
    if (expected.value != null) {
      return '${expected.type}(${expected.value})';
    }
    return '${expected.type}(${expected.floatValue})';
  }

  static bool _functionTypesEqual(WasmFunctionType lhs, WasmFunctionType rhs) {
    if (lhs.params.length != rhs.params.length ||
        lhs.results.length != rhs.results.length) {
      return false;
    }
    for (var i = 0; i < lhs.params.length; i++) {
      if (lhs.params[i] != rhs.params[i]) {
        return false;
      }
    }
    for (var i = 0; i < lhs.results.length; i++) {
      if (lhs.results[i] != rhs.results[i]) {
        return false;
      }
    }
    return true;
  }
}

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    _printUsage();
    return;
  }

  final suite = _parseSuite(_argValue(args, '--suite') ?? 'proposal');
  final testsuiteDir =
      _argValue(args, '--testsuite-dir') ??
      '${Directory.current.path}/third_party/wasm-spec-tests';
  final outputJson =
      _argValue(args, '--output-json') ??
      '.dart_tool/spec_runner/proposal_latest.json';
  final outputMarkdown =
      _argValue(args, '--output-md') ?? 'doc/wasm_proposal_failures.md';
  final maxFilesRaw = _argValue(args, '--max-files');
  final maxFiles = maxFilesRaw == null ? null : int.tryParse(maxFilesRaw);

  final wast2jsonBinary = await _resolveWast2Json(
    _argValue(args, '--wast2json'),
  );
  final testsuite = Directory(testsuiteDir);
  if (!testsuite.existsSync()) {
    stderr.writeln('testsuite directory does not exist: ${testsuite.path}');
    exitCode = 2;
    return;
  }

  final startedAt = DateTime.now().toUtc();
  final files = _collectSuiteFiles(testsuite.path, suite);
  final selectedFiles = maxFiles == null
      ? files
      : files.take(maxFiles).toList();

  final results = <_FileResult>[];
  final reasonCounts = <String, int>{};
  final groupStats = <String, Map<String, int>>{};

  for (final file in selectedFiles) {
    final group = _groupForFile(file, testsuite.path);
    final result = await _runWastFile(
      file: file,
      group: group,
      wast2jsonBinary: wast2jsonBinary,
    );
    results.add(result);

    final groupCounter = groupStats.putIfAbsent(
      group,
      () => <String, int>{'total': 0, 'passed': 0, 'failed': 0},
    );
    groupCounter['total'] = (groupCounter['total'] ?? 0) + 1;
    if (result.passed) {
      groupCounter['passed'] = (groupCounter['passed'] ?? 0) + 1;
    } else {
      groupCounter['failed'] = (groupCounter['failed'] ?? 0) + 1;
      final reason = result.firstFailureReason ?? 'unknown-failure';
      reasonCounts[reason] = (reasonCounts[reason] ?? 0) + 1;
    }
  }

  final endedAt = DateTime.now().toUtc();
  final revision = await _git([
    '-C',
    testsuite.path,
    'rev-parse',
    '--short',
    'HEAD',
  ]);

  final filesPassed = results.where((r) => r.passed).length;
  final filesFailed = results.length - filesPassed;
  final commandsSeen = results.fold<int>(0, (acc, r) => acc + r.commandsSeen);
  final commandsPassed = results.fold<int>(
    0,
    (acc, r) => acc + r.commandsPassed,
  );
  final commandsFailed = results.fold<int>(
    0,
    (acc, r) => acc + r.commandsFailed,
  );
  final commandsSkipped = results.fold<int>(
    0,
    (acc, r) => acc + r.commandsSkipped,
  );

  final payload = <String, Object?>{
    'started_at_utc': startedAt.toIso8601String(),
    'ended_at_utc': endedAt.toIso8601String(),
    'suite': suite.name,
    'testsuite_dir': testsuite.path,
    'testsuite_revision': revision,
    'wast2json': wast2jsonBinary,
    'totals': <String, Object?>{
      'files_total': results.length,
      'files_passed': filesPassed,
      'files_failed': filesFailed,
      'commands_seen': commandsSeen,
      'commands_passed': commandsPassed,
      'commands_failed': commandsFailed,
      'commands_skipped': commandsSkipped,
    },
    'group_stats': groupStats,
    'reason_counts': reasonCounts,
    'files': results.map((r) => r.toJson()).toList(growable: false),
  };

  final jsonFile = File(outputJson);
  await jsonFile.parent.create(recursive: true);
  await jsonFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(payload),
  );

  final markdownFile = File(outputMarkdown);
  await markdownFile.parent.create(recursive: true);
  await markdownFile.writeAsString(
    _renderMarkdown(payload: payload, results: results, groupStats: groupStats),
  );

  stdout.writeln(
    'spec-testsuite status: ${filesFailed == 0 ? 'passed' : 'failed'}',
  );
  stdout.writeln('json report: ${jsonFile.path}');
  stdout.writeln('markdown report: ${markdownFile.path}');

  if (filesFailed > 0) {
    exitCode = 1;
  }
}

Future<_FileResult> _runWastFile({
  required String file,
  required String group,
  required String wast2jsonBinary,
}) async {
  final tempDir = await Directory.systemTemp.createTemp('wasd-spec-');
  try {
    final jsonPath = '${tempDir.path}/script.json';
    final conversion = await Process.run(wast2jsonBinary, [
      '--enable-all',
      file,
      '-o',
      jsonPath,
    ]);
    if (conversion.exitCode != 0) {
      return _FileResult(
        path: file,
        group: group,
        commandsSeen: 0,
        commandsPassed: 0,
        commandsFailed: 1,
        commandsSkipped: 0,
        passed: false,
        firstFailureReason: 'wast2json-failed',
        firstFailureDetails:
            ((conversion.stderr as String?) ?? '').trim().isEmpty
            ? ((conversion.stdout as String?) ?? '').trim()
            : ((conversion.stderr as String?) ?? '').trim(),
        wast2jsonStdout: (conversion.stdout as String?) ?? '',
        wast2jsonStderr: (conversion.stderr as String?) ?? '',
      );
    }

    final scriptJson = File(jsonPath);
    final decoded = json.decode(await scriptJson.readAsString());
    if (decoded is! Map) {
      return _FileResult(
        path: file,
        group: group,
        commandsSeen: 0,
        commandsPassed: 0,
        commandsFailed: 1,
        commandsSkipped: 0,
        passed: false,
        firstFailureReason: 'invalid-json-root',
        firstFailureDetails: 'wast2json output root is not an object',
      );
    }
    final commandsRaw = decoded['commands'];
    if (commandsRaw is! List) {
      return _FileResult(
        path: file,
        group: group,
        commandsSeen: 0,
        commandsPassed: 0,
        commandsFailed: 1,
        commandsSkipped: 0,
        passed: false,
        firstFailureReason: 'invalid-commands',
        firstFailureDetails: 'wast2json output does not contain command list',
      );
    }

    var commandsSeen = 0;
    var commandsPassed = 0;
    var commandsFailed = 0;
    var commandsSkipped = 0;
    int? firstFailureLine;
    String? firstFailureReason;
    String? firstFailureDetails;

    final state = _ScriptExecutionState(tempDir);
    for (final raw in commandsRaw) {
      if (raw is! Map) {
        commandsSeen++;
        commandsFailed++;
        firstFailureReason ??= 'invalid-command-entry';
        firstFailureDetails ??= 'Non-object command entry: $raw';
        break;
      }

      commandsSeen++;
      final command = raw.cast<String, Object?>();
      final outcome = state.executeCommand(command);
      if (outcome.skipped) {
        commandsSkipped++;
        continue;
      }
      if (outcome.passed) {
        commandsPassed++;
        continue;
      }

      commandsFailed++;
      firstFailureLine ??= command['line'] is int
          ? command['line'] as int
          : null;
      firstFailureReason ??= outcome.reason;
      firstFailureDetails ??= outcome.details;
      break;
    }

    final passed = commandsFailed == 0;
    return _FileResult(
      path: file,
      group: group,
      commandsSeen: commandsSeen,
      commandsPassed: commandsPassed,
      commandsFailed: commandsFailed,
      commandsSkipped: commandsSkipped,
      passed: passed,
      firstFailureLine: firstFailureLine,
      firstFailureReason: firstFailureReason,
      firstFailureDetails: firstFailureDetails,
    );
  } finally {
    await tempDir.delete(recursive: true);
  }
}

_SpecSuite _parseSuite(String raw) {
  final normalized = raw.trim().toLowerCase();
  switch (normalized) {
    case 'core':
      return _SpecSuite.core;
    case 'proposal':
      return _SpecSuite.proposal;
    case 'all':
      return _SpecSuite.all;
    default:
      throw ArgumentError('Unsupported --suite value: $raw');
  }
}

List<String> _collectSuiteFiles(String testsuiteDir, _SpecSuite suite) {
  final files = <String>[];
  for (final entity in Directory(testsuiteDir).listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.wast')) {
      continue;
    }
    final normalized = entity.path.replaceAll('\\', '/');
    final inProposal = normalized.contains('/proposals/');
    final inLegacy = normalized.contains('/legacy/');
    if (inLegacy) {
      continue;
    }
    switch (suite) {
      case _SpecSuite.core:
        if (!inProposal) {
          files.add(entity.path);
        }
      case _SpecSuite.proposal:
        if (inProposal) {
          files.add(entity.path);
        }
      case _SpecSuite.all:
        files.add(entity.path);
    }
  }
  files.sort();
  return files;
}

String _groupForFile(String file, String testsuiteDir) {
  final normalizedFile = file.replaceAll('\\', '/');
  final normalizedRoot = testsuiteDir.replaceAll('\\', '/');
  final relative = normalizedFile.startsWith('$normalizedRoot/')
      ? normalizedFile.substring(normalizedRoot.length + 1)
      : normalizedFile;
  final parts = relative.split('/');
  if (parts.length >= 3 && parts[0] == 'proposals') {
    return parts[1];
  }
  return 'core';
}

String _renderMarkdown({
  required Map<String, Object?> payload,
  required List<_FileResult> results,
  required Map<String, Map<String, int>> groupStats,
}) {
  final totals = payload['totals'] as Map<String, Object?>;
  final reasonCounts = (payload['reason_counts'] as Map)
      .cast<String, Object?>();

  final b = StringBuffer()
    ..writeln('# WASM Proposal Failure Board')
    ..writeln()
    ..writeln('- Started at (UTC): `${payload['started_at_utc']}`')
    ..writeln('- Ended at (UTC): `${payload['ended_at_utc']}`')
    ..writeln('- Suite: `${payload['suite']}`')
    ..writeln('- Testsuite dir: `${payload['testsuite_dir']}`')
    ..writeln(
      '- Testsuite revision: `${payload['testsuite_revision'] ?? 'unknown'}`',
    )
    ..writeln('- wast2json: `${payload['wast2json']}`')
    ..writeln()
    ..writeln('## Totals')
    ..writeln()
    ..writeln('- Files: ${totals['files_total']}')
    ..writeln('- Passed files: ${totals['files_passed']}')
    ..writeln('- Failed files: ${totals['files_failed']}')
    ..writeln('- Commands seen: ${totals['commands_seen']}')
    ..writeln('- Commands passed: ${totals['commands_passed']}')
    ..writeln('- Commands failed: ${totals['commands_failed']}')
    ..writeln('- Commands skipped: ${totals['commands_skipped']}')
    ..writeln()
    ..writeln('## Groups')
    ..writeln()
    ..writeln('| Group | Files | Passed | Failed |')
    ..writeln('| --- | ---: | ---: | ---: |');

  final sortedGroups = groupStats.keys.toList()..sort();
  for (final group in sortedGroups) {
    final stats = groupStats[group]!;
    b.writeln(
      '| $group | ${stats['total'] ?? 0} | ${stats['passed'] ?? 0} | ${stats['failed'] ?? 0} |',
    );
  }

  if (reasonCounts.isNotEmpty) {
    b.writeln();
    b.writeln('## Top Failure Reasons');
    b.writeln();
    b.writeln('| Reason | Count |');
    b.writeln('| --- | ---: |');
    final sorted = reasonCounts.entries.toList()
      ..sort((a, b) => (b.value as int).compareTo(a.value as int));
    for (final entry in sorted) {
      b.writeln('| ${entry.key} | ${entry.value} |');
    }
  }

  final failed = results.where((r) => !r.passed).toList(growable: false);
  if (failed.isNotEmpty) {
    b.writeln();
    b.writeln('## Failed Files');
    b.writeln();
    b.writeln('| Group | File | Line | Reason | Details |');
    b.writeln('| --- | --- | ---: | --- | --- |');
    for (final file in failed) {
      final details = _markdownEscape(_shorten(file.firstFailureDetails ?? ''));
      b.writeln(
        '| ${file.group} | `${_markdownEscape(file.path)}` | ${file.firstFailureLine ?? 0} | ${file.firstFailureReason ?? 'unknown'} | $details |',
      );
    }
  }

  return b.toString();
}

String _markdownEscape(String input) {
  return input.replaceAll('|', '\\|').replaceAll('\n', '<br>');
}

String _shorten(String input, {int max = 240}) {
  if (input.length <= max) {
    return input;
  }
  return '${input.substring(0, max - 3)}...';
}

String? _argValue(List<String> args, String key) {
  for (var i = 0; i < args.length; i++) {
    final current = args[i];
    if (current == key && i + 1 < args.length) {
      return args[i + 1];
    }
    if (current.startsWith('$key=')) {
      return current.substring(key.length + 1);
    }
  }
  return null;
}

Future<String> _resolveWast2Json(String? explicit) async {
  final candidates = <String>[
    if (explicit != null && explicit.isNotEmpty) explicit,
    '${Directory.current.path}/.toolchains/bin/wast2json',
    '${Directory.current.path}/.toolchains/wabt-1.0.37/bin/wast2json',
    'wast2json',
  ];

  for (final candidate in candidates) {
    if (candidate.contains('/')) {
      final file = File(candidate);
      if (file.existsSync()) {
        return candidate;
      }
      continue;
    }

    final result = await Process.run('which', [candidate]);
    if (result.exitCode == 0) {
      final resolved = ((result.stdout as String?) ?? '').trim();
      if (resolved.isNotEmpty) {
        return resolved;
      }
    }
  }

  throw StateError(
    'Unable to locate `wast2json`. Run `bash tool/ensure_toolchains.sh` first.',
  );
}

Future<String?> _git(List<String> args) async {
  final result = await Process.run('git', args);
  if (result.exitCode != 0) {
    return null;
  }
  final output = ((result.stdout as String?) ?? '').trim();
  return output.isEmpty ? null : output;
}

void _printUsage() {
  stdout.writeln(
    'Usage: dart run tool/spec_testsuite_runner.dart '
    '--suite=<core|proposal|all> '
    '[--testsuite-dir=<path>] '
    '[--output-json=<path>] '
    '[--output-md=<path>] '
    '[--max-files=<n>] '
    '[--wast2json=<path>]',
  );
}
