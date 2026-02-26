import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'src/spec_player_bridge_io.dart'
    if (dart.library.js_interop) 'src/spec_player_bridge_web.dart'
    as player_bridge;
import 'src/spec_v128_codec.dart' as spec_v128;
import 'package:wasd/wasd.dart';

enum _SpecSuite { core, proposal, all }

enum _WastConverterKind { wasmToolsJsonFromWast, wabtWast2json }

final class _WastConverter {
  const _WastConverter({required this.kind, required this.binary});

  final _WastConverterKind kind;
  final String binary;

  String get label => switch (kind) {
    _WastConverterKind.wasmToolsJsonFromWast => 'wasm-tools json-from-wast',
    _WastConverterKind.wabtWast2json => 'wabt wast2json',
  };

  List<String> command({
    required String wastFile,
    required String outputJsonPath,
    required String wasmDir,
  }) => switch (kind) {
    _WastConverterKind.wasmToolsJsonFromWast => <String>[
      'json-from-wast',
      wastFile,
      '-o',
      outputJsonPath,
      '--wasm-dir',
      wasmDir,
    ],
    _WastConverterKind.wabtWast2json => <String>[
      '--enable-all',
      wastFile,
      '-o',
      outputJsonPath,
    ],
  };
}

enum _TextModuleParserKind { wasmToolsParse, wabtWat2Wasm }

final class _TextModuleParser {
  const _TextModuleParser({required this.kind, required this.binary});

  final _TextModuleParserKind kind;
  final String binary;

  List<String> command({
    required String watFile,
    required String outputWasmPath,
  }) => switch (kind) {
    _TextModuleParserKind.wasmToolsParse => <String>[
      'parse',
      watFile,
      '-o',
      outputWasmPath,
    ],
    _TextModuleParserKind.wabtWat2Wasm => <String>[
      '--enable-all',
      watFile,
      '-o',
      outputWasmPath,
    ],
  };
}

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
  const _ExpectedValue.i32(int this.value)
    : type = 'i32',
      isNaN = false,
      floatBits = null,
      expectsRef = false,
      expectsNullRef = false,
      v128Raw = null,
      alternatives = null;
  const _ExpectedValue.i64(BigInt this.value)
    : type = 'i64',
      isNaN = false,
      floatBits = null,
      expectsRef = false,
      expectsNullRef = false,
      v128Raw = null,
      alternatives = null;
  const _ExpectedValue.f32(this.floatBits)
    : type = 'f32',
      isNaN = false,
      value = null,
      expectsRef = false,
      expectsNullRef = false,
      v128Raw = null,
      alternatives = null;
  const _ExpectedValue.f64(this.floatBits)
    : type = 'f64',
      isNaN = false,
      value = null,
      expectsRef = false,
      expectsNullRef = false,
      v128Raw = null,
      alternatives = null;
  const _ExpectedValue.nan(this.type)
    : isNaN = true,
      value = null,
      floatBits = null,
      expectsRef = false,
      expectsNullRef = false,
      v128Raw = null,
      alternatives = null;
  _ExpectedValue.v128(int this.value, {this.v128Raw})
    : type = 'v128',
      isNaN = false,
      floatBits = null,
      expectsRef = false,
      expectsNullRef = false,
      alternatives = null;
  _ExpectedValue.either(this.alternatives)
    : type = 'either',
      isNaN = false,
      value = null,
      floatBits = null,
      expectsRef = false,
      expectsNullRef = false,
      v128Raw = null;
  const _ExpectedValue.ref(this.type, {required this.expectsNullRef})
    : isNaN = false,
      value = null,
      floatBits = null,
      expectsRef = true,
      v128Raw = null,
      alternatives = null;

  final String type;
  final bool isNaN;
  final Object? value;
  final int? floatBits;
  final bool expectsRef;
  final bool expectsNullRef;
  final Map<String, Object?>? v128Raw;
  final List<_ExpectedValue>? alternatives;
}

final class _FileResult {
  _FileResult({
    required this.path,
    required this.group,
    required this.commandsSeen,
    required this.commandsPassed,
    required this.commandsFailed,
    required this.commandsSkipped,
    required this.skipReasonCounts,
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
  final Map<String, int> skipReasonCounts;
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
    'skip_reason_counts': skipReasonCounts,
    'first_failure_line': firstFailureLine,
    'first_failure_reason': firstFailureReason,
    'first_failure_details': firstFailureDetails,
    'wast2json_stdout': wast2jsonStdout,
    'wast2json_stderr': wast2jsonStderr,
  };
}

final class _PreparedManifestEntry {
  const _PreparedManifestEntry({
    required this.path,
    required this.group,
    required this.workDirPath,
    required this.scriptJsonPath,
    required this.wasmDirPath,
  });

  final String path;
  final String group;
  final String workDirPath;
  final String scriptJsonPath;
  final String wasmDirPath;

  Map<String, Object?> toJson() => {
    'path': path,
    'group': group,
    'work_dir': workDirPath,
    'script_json_path': scriptJsonPath,
    'wasm_dir': wasmDirPath,
  };
}

final class _ScriptExecutionState {
  _ScriptExecutionState({
    required this.workDirPath,
    required WasmFeatureSet features,
    Uint8List Function(String filename)? moduleLoader,
  }) : _features = features,
       _moduleLoader = moduleLoader;

  final String workDirPath;
  final WasmFeatureSet _features;
  final Uint8List Function(String filename)? _moduleLoader;

  final Map<String, WasmModule> _moduleDefinitions = <String, WasmModule>{};
  WasmModule? _anonymousModuleDefinition;
  final Map<String, WasmInstance> _namedModules = <String, WasmInstance>{};
  final Map<String, WasmInstance> _registeredModules = <String, WasmInstance>{};
  final WasmMemory _spectestMemory = WasmMemory(minPages: 1, maxPages: 2);
  final WasmMemory _spectestSharedMemory = WasmMemory(
    minPages: 1,
    maxPages: 2,
    shared: true,
  );
  final WasmTable _spectestTable = WasmTable(
    refType: WasmRefType.funcref,
    min: 10,
    max: 20,
    refTypeSignature: '70',
  );
  final WasmTable _spectestTable64 = WasmTable(
    refType: WasmRefType.funcref,
    min: 10,
    max: 20,
    isTable64: true,
    refTypeSignature: '70',
  );

  WasmInstance? _currentInstance;

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
        case 'module_definition':
          return _handleModuleDefinition(command);
        case 'module_instance':
          return _handleModuleInstance(command);
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
        case 'assert_exhaustion':
          return _handleAssertExhaustion(command);
        case 'assert_exception':
          return _handleAssertException(command);
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
    } catch (error, stackTrace) {
      return _CommandResult.fail('unhandled-exception', '$error\n$stackTrace');
    }
  }

  _CommandResult _handleModule(Map<String, Object?> command) {
    final resolvedFilename = _resolveModuleFilename(command);
    if (resolvedFilename == null) {
      return _CommandResult.fail('module-missing-filename', '$command');
    }

    final moduleBytes = _readBinaryModule(resolvedFilename);
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

  _CommandResult _handleModuleDefinition(Map<String, Object?> command) {
    final resolvedFilename = _resolveModuleFilename(command);
    if (resolvedFilename == null) {
      return _CommandResult.fail('module-missing-filename', '$command');
    }
    final moduleBytes = _readBinaryModule(resolvedFilename);
    final module = WasmModule.decode(moduleBytes, features: _features);
    final name = command['name'];
    if (name is String && name.isNotEmpty) {
      _moduleDefinitions[name] = module;
    } else {
      _anonymousModuleDefinition = module;
    }
    return _CommandResult.pass();
  }

  _CommandResult _handleModuleInstance(Map<String, Object?> command) {
    final moduleName = command['module'];
    final module = switch (moduleName) {
      String() when moduleName.isNotEmpty => _moduleDefinitions[moduleName],
      _ => _anonymousModuleDefinition,
    };
    if (module == null) {
      if (moduleName is String && moduleName.isNotEmpty) {
        return _CommandResult.fail(
          'module-instance-definition-not-found',
          'Module definition `$moduleName` not found.',
        );
      }
      return _CommandResult.fail('module-instance-missing-module', '$command');
    }
    final instance = WasmInstance.fromModule(
      module,
      imports: _buildImports(module),
      features: _features,
    );
    _currentInstance = instance;
    final instanceName = command['instance'];
    if (instanceName is String && instanceName.isNotEmpty) {
      _namedModules[instanceName] = instance;
    }
    return _CommandResult.pass();
  }

  String? _resolveModuleFilename(Map<String, Object?> command) {
    final filename = command['filename'];
    if (filename is! String || filename.isEmpty) {
      return null;
    }
    final moduleType = command['module_type'];
    var resolvedFilename = filename;
    if (moduleType is String && moduleType != 'binary') {
      if (moduleType == 'text') {
        final binaryFilename = command['binary_filename'];
        if (binaryFilename is String && binaryFilename.isNotEmpty) {
          resolvedFilename = binaryFilename;
        } else {
          return null;
        }
      } else {
        return null;
      }
    }
    return resolvedFilename;
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

  _CommandResult _handleAssertExhaustion(Map<String, Object?> command) {
    final action = _readAction(command);
    try {
      _runAction(action);
      return _CommandResult.fail('assert-exhaustion-not-trapped', '$command');
    } on _SpecRunnerFailure catch (error) {
      return _CommandResult.fail(error.reason, error.details);
    } catch (_) {
      return _CommandResult.pass();
    }
  }

  _CommandResult _handleAssertException(Map<String, Object?> command) {
    final action = _readAction(command);
    try {
      _runAction(action);
      return _CommandResult.fail('assert-exception-not-thrown', '$command');
    } on _SpecRunnerFailure catch (error) {
      return _CommandResult.fail(error.reason, error.details);
    } catch (_) {
      return _CommandResult.pass();
    }
  }

  _CommandResult _handleAssertModuleFails(Map<String, Object?> command) {
    final filename = _resolveModuleFilename(command);
    if (filename == null) {
      final moduleType = command['module_type'];
      if (moduleType is String && moduleType != 'binary') {
        return _CommandResult.skip(
          'unsupported-module-type',
          'module_type `$moduleType` is not binary.',
        );
      }
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
      final validated = command['wasd_text_malformed_validated'];
      if (validated is bool) {
        if (validated) {
          return _CommandResult.pass();
        }
        return _CommandResult.skip(
          'text-malformed-parser-divergence',
          'Text parser accepted malformed assertion: $command',
        );
      }
      return _CommandResult.skip(
        'unsupported-text-malformed',
        'Text malformed assertion was not prevalidated.',
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
    final loader = _moduleLoader;
    if (loader != null) {
      return loader(filename);
    }

    final file = File('$workDirPath/$filename');
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
        if (field is! String) {
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
        if (field is! String) {
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
    final expectedFunctionImports = <String, WasmImport>{};
    final expectedGlobalImports = <String, WasmImport>{};
    for (final import in targetModule.imports) {
      if (import.kind != WasmImportKind.function &&
          import.kind != WasmImportKind.exactFunction) {
        if (import.kind != WasmImportKind.global || import.globalType == null) {
          continue;
        }
        expectedGlobalImports[import.key] = import;
        continue;
      }
      final typeIndex = import.functionTypeIndex;
      if (typeIndex == null ||
          typeIndex < 0 ||
          typeIndex >= targetModule.types.length ||
          !targetModule.types[typeIndex].isFunctionType) {
        continue;
      }
      expectedFunctionImports[import.key] = import;
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
    final functionTypeDepths = <String, int>{};
    final globals = <String, Object?>{
      WasmImports.key('spectest', 'global_i32'): 666,
      WasmImports.key('spectest', 'global_i64'): 666,
      WasmImports.key('spectest', 'global_f32'): 666.6,
      WasmImports.key('spectest', 'global_f64'): 666.6,
    };
    final globalTypes = <String, WasmGlobalType>{
      WasmImports.key('spectest', 'global_i32'): const WasmGlobalType(
        valueType: WasmValueType.i32,
        mutable: false,
        valueTypeSignature: '7f',
      ),
      WasmImports.key('spectest', 'global_i64'): const WasmGlobalType(
        valueType: WasmValueType.i64,
        mutable: false,
        valueTypeSignature: '7e',
      ),
      WasmImports.key('spectest', 'global_f32'): const WasmGlobalType(
        valueType: WasmValueType.f32,
        mutable: false,
        valueTypeSignature: '7d',
      ),
      WasmImports.key('spectest', 'global_f64'): const WasmGlobalType(
        valueType: WasmValueType.f64,
        mutable: false,
        valueTypeSignature: '7c',
      ),
    };
    final globalBindings = <String, RuntimeGlobal>{};
    final memories = <String, WasmMemory>{
      WasmImports.key('spectest', 'memory'): _spectestMemory,
      WasmImports.key('spectest', 'shared_memory'): _spectestSharedMemory,
    };
    final tables = <String, WasmTable>{
      WasmImports.key('spectest', 'table'): _spectestTable,
      WasmImports.key('spectest', 'table64'): _spectestTable64,
    };
    final tags = <String, WasmTagImport>{};

    for (final entry in _registeredModules.entries) {
      final alias = entry.key;
      final instance = entry.value;
      for (final export in instance.exportedFunctions) {
        final key = WasmImports.key(alias, export);
        final expectedImport = expectedFunctionImports[key];
        if (expectedImport == null) {
          continue;
        }
        final expectedTypeIndex = expectedImport.functionTypeIndex!;
        final expectedDepth = _functionTypeDepth(
          targetModule,
          expectedTypeIndex,
        );
        final actualTypeIndex = instance.exportedFunctionTypeIndex(export);
        final actualDepth = instance.exportedFunctionTypeDepth(export);
        if (!_functionTypeCompatibleForImport(
          expectedModule: targetModule,
          expectedTypeIndex: expectedTypeIndex,
          expectedDepth: expectedDepth,
          isExactImport: expectedImport.isExactFunction,
          actualModule: instance.module,
          actualTypeIndex: actualTypeIndex,
          actualDepth: actualDepth,
        )) {
          continue;
        }
        functions[key] = (args) => instance.invoke(export, args);
        functionTypeDepths[key] = actualDepth;
      }
      for (final export in instance.exportedGlobals) {
        final key = WasmImports.key(alias, export);
        globals[key] = instance.readGlobal(export);
        final actualType = instance.exportedGlobalType(export);
        final expectedImport = expectedGlobalImports[key];
        if (expectedImport != null &&
            _globalTypeCompatibleForImport(
              expectedModule: targetModule,
              expectedType: expectedImport.globalType!,
              actualModule: instance.module,
              actualType: actualType,
            )) {
          // Canonicalize imported global signatures to the target module when
          // cross-module equivalent types use different local type indices.
          globalTypes[key] = expectedImport.globalType!;
        } else {
          globalTypes[key] = actualType;
        }
        globalBindings[key] = instance.exportedGlobalBinding(export);
      }
      for (final export in instance.exportedMemories) {
        final key = WasmImports.key(alias, export);
        memories[key] = instance.exportedMemory(export);
      }
      for (final export in instance.exportedTables) {
        final key = WasmImports.key(alias, export);
        tables[key] = instance.exportedTable(export);
      }
      for (final export in instance.exportedTags) {
        final key = WasmImports.key(alias, export);
        tags[key] = instance.exportedTagImport(export);
      }
    }

    return WasmImports(
      functions: functions,
      functionTypeDepths: functionTypeDepths,
      globals: globals,
      globalTypes: globalTypes,
      globalBindings: globalBindings,
      memories: memories,
      tables: tables,
      tags: tags,
    );
  }

  Object? _parseActionArg(Map<String, Object?> raw) {
    final type = raw['type'];
    final value = raw['value'];
    if (type is! String) {
      throw _SpecRunnerFailure('invalid-arg-type', '$raw');
    }
    final isReferenceArg =
        type == 'externref' ||
        type == 'funcref' ||
        type == 'structref' ||
        type == 'arrayref' ||
        type == 'eqref' ||
        type == 'i31ref' ||
        type == 'exnref' ||
        type == 'anyref' ||
        type == 'refnull' ||
        type == 'nullref' ||
        type == 'nullfuncref' ||
        type == 'nullexternref' ||
        type == 'nullexnref' ||
        type == 'nullstructref' ||
        type == 'nullarrayref';
    if (value is! String && !isReferenceArg && type != 'v128') {
      throw _SpecRunnerFailure('invalid-arg-value', '$raw');
    }

    switch (type) {
      case 'i32':
        final valueString = value as String;
        return _signedBits(BigInt.parse(valueString), 32);
      case 'i64':
        final valueString = value as String;
        return _signedBitsBigInt(BigInt.parse(valueString), 64);
      case 'f32':
        final valueString = value as String;
        return WasmF32Bits(_parseFloatBits(valueString, 32));
      case 'f64':
        final valueString = value as String;
        return WasmF64Bits(_parseFloatBits(valueString, 64));
      case 'v128':
        return _parseV128Token(raw);
      case 'externref':
      case 'funcref':
      case 'structref':
      case 'arrayref':
      case 'eqref':
      case 'i31ref':
      case 'exnref':
      case 'anyref':
        if (value == null || value == 'null') {
          return -1;
        }
        final valueString = value as String;
        return _signedBits(BigInt.parse(valueString), 32);
      case 'nullref':
      case 'refnull':
      case 'nullfuncref':
      case 'nullexternref':
      case 'nullexnref':
      case 'nullstructref':
      case 'nullarrayref':
        return -1;
      default:
        throw _SpecRunnerFailure(
          'unsupported-arg-type',
          'Argument type `$type` is not supported yet.',
        );
    }
  }

  _ExpectedValue _parseExpectedValue(Map<String, Object?> raw) {
    final type = raw['type'];
    final value = raw['value'];
    if (type is! String) {
      throw _SpecRunnerFailure('invalid-expected-type', '$raw');
    }
    if (value is! String &&
        type != 'either' &&
        type != 'v128' &&
        type != 'funcref' &&
        type != 'externref' &&
        type != 'structref' &&
        type != 'arrayref' &&
        type != 'eqref' &&
        type != 'i31ref' &&
        type != 'exnref' &&
        type != 'anyref' &&
        type != 'nullref' &&
        type != 'refnull' &&
        type != 'nullfuncref' &&
        type != 'nullexternref' &&
        type != 'nullexnref' &&
        type != 'nullstructref' &&
        type != 'nullarrayref') {
      throw _SpecRunnerFailure('invalid-expected-value', '$raw');
    }

    switch (type) {
      case 'either':
        final valuesRaw = raw['values'];
        if (valuesRaw is! List || valuesRaw.isEmpty) {
          throw _SpecRunnerFailure('invalid-expected-value', '$raw');
        }
        final alternatives = <_ExpectedValue>[];
        for (final candidate in valuesRaw) {
          if (candidate is! Map) {
            throw _SpecRunnerFailure('invalid-expected-value', '$raw');
          }
          alternatives.add(
            _parseExpectedValue(candidate.cast<String, Object?>()),
          );
        }
        return _ExpectedValue.either(alternatives);
      case 'i32':
        final valueString = value as String;
        return _ExpectedValue.i32(_signedBits(BigInt.parse(valueString), 32));
      case 'i64':
        final valueString = value as String;
        return _ExpectedValue.i64(
          _signedBitsBigInt(BigInt.parse(valueString), 64),
        );
      case 'f32':
        final valueString = value as String;
        if (valueString.startsWith('nan:')) {
          return const _ExpectedValue.nan('f32');
        }
        return _ExpectedValue.f32(_parseFloatBits(valueString, 32));
      case 'f64':
        final valueString = value as String;
        if (valueString.startsWith('nan:')) {
          return const _ExpectedValue.nan('f64');
        }
        return _ExpectedValue.f64(_parseFloatBits(valueString, 64));
      case 'v128':
        return _ExpectedValue.v128(_parseV128Token(raw), v128Raw: raw);
      case 'funcref':
      case 'externref':
      case 'structref':
      case 'arrayref':
      case 'eqref':
      case 'i31ref':
      case 'exnref':
      case 'anyref':
        return _ExpectedValue.ref(type, expectsNullRef: value == 'null');
      case 'nullref':
      case 'refnull':
      case 'nullfuncref':
      case 'nullexternref':
      case 'nullexnref':
      case 'nullstructref':
      case 'nullarrayref':
        return _ExpectedValue.ref(type, expectsNullRef: true);
      default:
        throw _SpecRunnerFailure(
          'unsupported-expected-type',
          'Expected type `$type` is not supported yet.',
        );
    }
  }

  static bool _matchExpected(Object? actual, _ExpectedValue expected) {
    if (expected.expectsRef) {
      if (expected.expectsNullRef) {
        return actual == null || (actual is int && actual == -1);
      }
      return actual is int && actual != -1;
    }
    switch (expected.type) {
      case 'either':
        final alternatives = expected.alternatives;
        if (alternatives == null || alternatives.isEmpty) {
          return false;
        }
        for (final candidate in alternatives) {
          if (_matchExpected(actual, candidate)) {
            return true;
          }
        }
        return false;
      case 'i32':
        final expectedValue = expected.value;
        return actual is int &&
            expectedValue is int &&
            actual.toSigned(32) == expectedValue;
      case 'i64':
        final expectedValue = expected.value;
        if (expectedValue is! BigInt) {
          return false;
        }
        if (actual is BigInt) {
          return _signedBitsBigInt(actual, 64) == expectedValue;
        }
        if (actual is int) {
          return _signedBitsBigInt(BigInt.from(actual), 64) == expectedValue;
        }
        return false;
      case 'f32':
        if (actual is! double) {
          return false;
        }
        if (expected.isNaN) {
          return actual.isNaN;
        }
        if (expected.floatBits == null) {
          return false;
        }
        if (_isF32NaNBits(expected.floatBits!)) {
          return actual.isNaN;
        }
        return _f32Bits(actual) == expected.floatBits;
      case 'f64':
        if (actual is! double) {
          return false;
        }
        if (expected.isNaN) {
          return actual.isNaN;
        }
        if (expected.floatBits == null) {
          return false;
        }
        if (_isF64NaNBits(expected.floatBits!)) {
          return actual.isNaN;
        }
        return _f64Bits(actual) == expected.floatBits;
      case 'v128':
        final expectedValue = expected.value;
        if (actual is! int || expectedValue is! int) {
          return false;
        }
        if (actual.toSigned(32) == expectedValue.toSigned(32)) {
          return true;
        }
        final raw = expected.v128Raw;
        if (raw == null) {
          return false;
        }
        return _matchV128NaNPattern(actual, expectedValue, raw);
      default:
        return false;
    }
  }

  static bool _matchV128NaNPattern(
    int actualToken,
    int expectedToken,
    Map<String, Object?> raw,
  ) {
    final laneType = raw['lane_type'];
    final lanesRaw = raw['value'];
    if (laneType is! String || lanesRaw is! List) {
      return false;
    }
    final bytes = WasmVm.v128BytesForValue(actualToken);
    final expectedBytes = WasmVm.v128BytesForValue(expectedToken);
    if (bytes == null || expectedBytes == null) {
      return false;
    }
    final data = ByteData.sublistView(bytes);
    final expectedData = ByteData.sublistView(expectedBytes);
    switch (laneType) {
      case 'f32':
        if (lanesRaw.length != 4) {
          return false;
        }
        for (var lane = 0; lane < 4; lane++) {
          final expectedLane = lanesRaw[lane];
          final actualLaneBits = data.getUint32(lane * 4, Endian.little);
          final expectedLaneBits = expectedData.getUint32(
            lane * 4,
            Endian.little,
          );
          if (_isV128NaNPatternToken(expectedLane)) {
            if (!_matchF32NaNPattern(actualLaneBits, expectedLane)) {
              return false;
            }
            continue;
          }
          if (actualLaneBits != expectedLaneBits) {
            return false;
          }
        }
        return true;
      case 'f64':
        if (lanesRaw.length != 2) {
          return false;
        }
        for (var lane = 0; lane < 2; lane++) {
          final expectedLane = lanesRaw[lane];
          final actualLaneBits = _u64FromLane(data, lane * 8);
          final expectedLaneBits = _u64FromLane(expectedData, lane * 8);
          if (_isV128NaNPatternToken(expectedLane)) {
            if (!_matchF64NaNPattern(actualLaneBits, expectedLane)) {
              return false;
            }
            continue;
          }
          if (actualLaneBits != expectedLaneBits) {
            return false;
          }
        }
        return true;
      default:
        return false;
    }
  }

  static bool _isV128NaNPatternToken(Object? token) {
    if (token is! String) {
      return false;
    }
    final normalized = token.trim().toLowerCase();
    final unsignedText = _stripLeadingSign(normalized);
    return unsignedText == 'nan:canonical' || unsignedText == 'nan:arithmetic';
  }

  static bool _matchF32NaNPattern(int actualBits, Object? expectedLane) {
    if (expectedLane is! String) {
      return false;
    }
    final normalized = expectedLane.trim().toLowerCase();
    final signRequirement = _nanSignRequirement(normalized);
    final unsignedText = _stripLeadingSign(normalized);
    if (unsignedText != 'nan:canonical' && unsignedText != 'nan:arithmetic') {
      return false;
    }
    if (!_isF32NaNBits(actualBits)) {
      return false;
    }
    final signBitSet = (actualBits & 0x80000000) != 0;
    if (signRequirement == -1 && !signBitSet) {
      return false;
    }
    if (signRequirement == 1 && signBitSet) {
      return false;
    }
    if (unsignedText == 'nan:canonical') {
      return (actualBits & 0x7fffffff) == 0x7fc00000;
    }
    final fraction = actualBits & 0x007fffff;
    return (fraction & 0x00400000) != 0;
  }

  static bool _matchF64NaNPattern(BigInt actualBits, Object? expectedLane) {
    if (expectedLane is! String) {
      return false;
    }
    final normalized = expectedLane.trim().toLowerCase();
    final signRequirement = _nanSignRequirement(normalized);
    final unsignedText = _stripLeadingSign(normalized);
    if (unsignedText != 'nan:canonical' && unsignedText != 'nan:arithmetic') {
      return false;
    }
    if (!_isF64NaNBits(_signedBits(actualBits, 64))) {
      return false;
    }
    final normalizedBits = actualBits & _u64Mask;
    final signBitSet = (normalizedBits & _u64SignBit) != BigInt.zero;
    if (signRequirement == -1 && !signBitSet) {
      return false;
    }
    if (signRequirement == 1 && signBitSet) {
      return false;
    }
    if (unsignedText == 'nan:canonical') {
      return (normalizedBits & _u64AbsMask) == _f64CanonicalAbsBits;
    }
    final fraction = normalizedBits & _f64FractionMask;
    return (fraction & _f64QuietBit) != BigInt.zero;
  }

  static int _nanSignRequirement(String text) {
    if (text.startsWith('-')) {
      return -1;
    }
    if (text.startsWith('+')) {
      return 1;
    }
    return 0;
  }

  static String _stripLeadingSign(String text) {
    if (text.startsWith('+') || text.startsWith('-')) {
      return text.substring(1);
    }
    return text;
  }

  static BigInt _u64FromLane(ByteData data, int offset) {
    final low = BigInt.from(data.getUint32(offset, Endian.little));
    final high = BigInt.from(data.getUint32(offset + 4, Endian.little));
    return (low | (high << 32)) & _u64Mask;
  }

  int _parseV128Token(Map<String, Object?> raw) {
    try {
      final bytes = spec_v128.parseV128LiteralBytes(raw);
      return WasmVm.internV128Bytes(bytes);
    } on FormatException {
      throw _SpecRunnerFailure('invalid-v128-value', '$raw');
    }
  }

  static int _parseFloatBits(String value, int bits) {
    final integer = _tryParseInteger(value);
    if (integer != null) {
      if (bits == 64) {
        return _signedBits(integer, 64);
      }
      return _unsignedBits(integer, bits);
    }

    final parsed = _parseFloating(value);
    return bits == 32 ? _f32Bits(parsed) : _f64Bits(parsed);
  }

  static BigInt? _tryParseInteger(String value) {
    try {
      return BigInt.parse(value);
    } catch (_) {
      return null;
    }
  }

  static int _unsignedBits(BigInt value, int bits) {
    final width = BigInt.one << bits;
    final mask = width - BigInt.one;
    return (value & mask).toInt();
  }

  static BigInt _signedBitsBigInt(BigInt value, int bits) {
    final width = BigInt.one << bits;
    final mask = width - BigInt.one;
    var normalized = value & mask;
    final signBit = BigInt.one << (bits - 1);
    if ((normalized & signBit) != BigInt.zero) {
      normalized -= width;
    }
    return normalized;
  }

  static int _signedBits(BigInt value, int bits) {
    return _signedBitsBigInt(value, bits).toInt();
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
    return _signedBits((BigInt.from(high) << 32) | BigInt.from(low), 64);
  }

  static final BigInt _u64Mask = (BigInt.one << 64) - BigInt.one;
  static final BigInt _u64SignBit = BigInt.one << 63;
  static final BigInt _u64AbsMask = _u64SignBit - BigInt.one;
  static final BigInt _f64CanonicalAbsBits = BigInt.parse(
    '7ff8000000000000',
    radix: 16,
  );
  static final BigInt _f64FractionMask = BigInt.parse(
    '000fffffffffffff',
    radix: 16,
  );
  static final BigInt _f64QuietBit = BigInt.parse(
    '0008000000000000',
    radix: 16,
  );

  static bool _isF32NaNBits(int bits) {
    final normalized = bits.toUnsigned(32);
    return (normalized & 0x7f800000) == 0x7f800000 &&
        (normalized & 0x007fffff) != 0;
  }

  static bool _isF64NaNBits(int bits) {
    final normalized = BigInt.from(bits) & ((BigInt.one << 64) - BigInt.one);
    final exponent = (normalized >> 52) & BigInt.from(0x7ff);
    final fraction = normalized & BigInt.parse('fffffffffffff', radix: 16);
    return exponent == BigInt.from(0x7ff) && fraction != BigInt.zero;
  }

  static String _expectedToString(_ExpectedValue expected) {
    if (expected.expectsRef) {
      return expected.expectsNullRef ? '${expected.type}(null)' : expected.type;
    }
    if (expected.type == 'either') {
      final alternatives = expected.alternatives;
      if (alternatives == null || alternatives.isEmpty) {
        return 'either()';
      }
      return 'either(${alternatives.map(_expectedToString).join('|')})';
    }
    if (expected.isNaN) {
      return '${expected.type}(nan)';
    }
    if (expected.value != null) {
      return '${expected.type}(${expected.value})';
    }
    return '${expected.type}(bits=${expected.floatBits})';
  }

  static bool _functionTypeCompatibleForImport({
    required WasmModule expectedModule,
    required int expectedTypeIndex,
    required int expectedDepth,
    required bool isExactImport,
    required WasmModule actualModule,
    required int actualTypeIndex,
    required int actualDepth,
  }) {
    final equivalent = _areTypesEquivalentAcrossModules(
      leftModule: actualModule,
      leftTypeIndex: actualTypeIndex,
      rightModule: expectedModule,
      rightTypeIndex: expectedTypeIndex,
      seenPairs: <String>{},
    );
    final actualIsSubtype = _hasEquivalentSupertypeAcrossModules(
      actualModule: actualModule,
      actualTypeIndex: actualTypeIndex,
      expectedModule: expectedModule,
      expectedTypeIndex: expectedTypeIndex,
    );
    final expectedIsSubtype = _hasEquivalentSupertypeAcrossModules(
      actualModule: expectedModule,
      actualTypeIndex: expectedTypeIndex,
      expectedModule: actualModule,
      expectedTypeIndex: actualTypeIndex,
    );
    if (!(equivalent || actualIsSubtype || expectedIsSubtype)) {
      return false;
    }
    if (isExactImport) {
      return actualDepth == expectedDepth;
    }
    return actualDepth >= expectedDepth && (equivalent || actualIsSubtype);
  }

  static bool _globalTypeCompatibleForImport({
    required WasmModule expectedModule,
    required WasmGlobalType expectedType,
    required WasmModule actualModule,
    required WasmGlobalType actualType,
  }) {
    if (expectedType.mutable != actualType.mutable) {
      return false;
    }

    final expectedSignature = expectedType.valueTypeSignature;
    final actualSignature = actualType.valueTypeSignature;
    if (expectedSignature == null ||
        expectedSignature.isEmpty ||
        actualSignature == null ||
        actualSignature.isEmpty) {
      return expectedType.valueType == actualType.valueType;
    }

    final expectedRef = _parseRefSignature(expectedSignature);
    final actualRef = _parseRefSignature(actualSignature);
    if (expectedRef == null || actualRef == null) {
      return expectedSignature == actualSignature;
    }
    if (expectedRef.nullable != actualRef.nullable ||
        expectedRef.exact != actualRef.exact) {
      return false;
    }
    final expectedHeap = expectedRef.heapType;
    final actualHeap = actualRef.heapType;
    if (expectedHeap < 0 || actualHeap < 0) {
      return expectedHeap == actualHeap;
    }
    return _areTypesEquivalentAcrossModules(
      leftModule: actualModule,
      leftTypeIndex: actualHeap,
      rightModule: expectedModule,
      rightTypeIndex: expectedHeap,
      seenPairs: <String>{},
    );
  }

  static bool _hasEquivalentSupertypeAcrossModules({
    required WasmModule actualModule,
    required int actualTypeIndex,
    required WasmModule expectedModule,
    required int expectedTypeIndex,
  }) {
    if (actualTypeIndex < 0 || actualTypeIndex >= actualModule.types.length) {
      return false;
    }
    final visited = <int>{actualTypeIndex};
    final pending = <int>[actualTypeIndex];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (_areTypesEquivalentAcrossModules(
        leftModule: actualModule,
        leftTypeIndex: current,
        rightModule: expectedModule,
        rightTypeIndex: expectedTypeIndex,
        seenPairs: <String>{},
      )) {
        return true;
      }
      for (final parent in actualModule.types[current].superTypeIndices) {
        if (parent < 0 || parent >= actualModule.types.length) {
          continue;
        }
        if (visited.add(parent)) {
          pending.add(parent);
        }
      }
    }
    return false;
  }

  static bool _areTypesEquivalentAcrossModules({
    required WasmModule leftModule,
    required int leftTypeIndex,
    required WasmModule rightModule,
    required int rightTypeIndex,
    required Set<String> seenPairs,
  }) {
    if (leftTypeIndex < 0 ||
        leftTypeIndex >= leftModule.types.length ||
        rightTypeIndex < 0 ||
        rightTypeIndex >= rightModule.types.length) {
      return false;
    }
    final pairKey =
        '${identityHashCode(leftModule)}:$leftTypeIndex|'
        '${identityHashCode(rightModule)}:$rightTypeIndex';
    if (!seenPairs.add(pairKey)) {
      return true;
    }

    final left = leftModule.types[leftTypeIndex];
    final right = rightModule.types[rightTypeIndex];
    if (left.kind != right.kind ||
        left.isFunctionType != right.isFunctionType ||
        left.declaresSubtype != right.declaresSubtype ||
        left.subtypeFinal != right.subtypeFinal ||
        left.recGroupSize != right.recGroupSize ||
        left.recGroupPosition != right.recGroupPosition) {
      return false;
    }

    final recGroupSize = left.recGroupSize;
    final leftGroupStart = leftTypeIndex - left.recGroupPosition;
    final rightGroupStart = rightTypeIndex - right.recGroupPosition;
    if (leftGroupStart < 0 ||
        rightGroupStart < 0 ||
        leftGroupStart + recGroupSize > leftModule.types.length ||
        rightGroupStart + recGroupSize > rightModule.types.length) {
      return false;
    }

    if (recGroupSize > 1) {
      for (var i = 0; i < recGroupSize; i++) {
        final leftPeer = leftGroupStart + i;
        final rightPeer = rightGroupStart + i;
        if (leftPeer == leftTypeIndex && rightPeer == rightTypeIndex) {
          continue;
        }
        if (!_areTypesEquivalentAcrossModules(
          leftModule: leftModule,
          leftTypeIndex: leftPeer,
          rightModule: rightModule,
          rightTypeIndex: rightPeer,
          seenPairs: seenPairs,
        )) {
          return false;
        }
      }
    }

    if (left.superTypeIndices.length != right.superTypeIndices.length) {
      return false;
    }
    for (var i = 0; i < left.superTypeIndices.length; i++) {
      final leftSuper = left.superTypeIndices[i];
      final rightSuper = right.superTypeIndices[i];
      final leftSuperInGroup =
          leftSuper >= leftGroupStart &&
          leftSuper < leftGroupStart + recGroupSize;
      final rightSuperInGroup =
          rightSuper >= rightGroupStart &&
          rightSuper < rightGroupStart + recGroupSize;
      if (leftSuperInGroup || rightSuperInGroup) {
        if (!leftSuperInGroup || !rightSuperInGroup) {
          return false;
        }
        if ((leftSuper - leftGroupStart) != (rightSuper - rightGroupStart)) {
          return false;
        }
        continue;
      }
      if (!_areTypesEquivalentAcrossModules(
        leftModule: leftModule,
        leftTypeIndex: leftSuper,
        rightModule: rightModule,
        rightTypeIndex: rightSuper,
        seenPairs: seenPairs,
      )) {
        return false;
      }
    }

    final leftDescriptor = left.descriptorTypeIndex;
    final rightDescriptor = right.descriptorTypeIndex;
    if ((leftDescriptor == null) != (rightDescriptor == null)) {
      return false;
    }
    if (leftDescriptor != null &&
        !_areTypesEquivalentAcrossModules(
          leftModule: leftModule,
          leftTypeIndex: leftDescriptor,
          rightModule: rightModule,
          rightTypeIndex: rightDescriptor!,
          seenPairs: seenPairs,
        )) {
      return false;
    }

    final leftDescribes = left.describesTypeIndex;
    final rightDescribes = right.describesTypeIndex;
    if ((leftDescribes == null) != (rightDescribes == null)) {
      return false;
    }
    if (leftDescribes != null &&
        !_areTypesEquivalentAcrossModules(
          leftModule: leftModule,
          leftTypeIndex: leftDescribes,
          rightModule: rightModule,
          rightTypeIndex: rightDescribes!,
          seenPairs: seenPairs,
        )) {
      return false;
    }

    if (left.isFunctionType) {
      if (left.paramTypeSignatures.length != right.paramTypeSignatures.length ||
          left.resultTypeSignatures.length !=
              right.resultTypeSignatures.length) {
        return false;
      }
      for (var i = 0; i < left.paramTypeSignatures.length; i++) {
        if (!_areValueSignaturesEquivalentAcrossModules(
          leftModule: leftModule,
          rightModule: rightModule,
          leftSignature: left.paramTypeSignatures[i],
          rightSignature: right.paramTypeSignatures[i],
          seenPairs: seenPairs,
          leftGroupStart: leftGroupStart,
          rightGroupStart: rightGroupStart,
          recGroupSize: recGroupSize,
        )) {
          return false;
        }
      }
      for (var i = 0; i < left.resultTypeSignatures.length; i++) {
        if (!_areValueSignaturesEquivalentAcrossModules(
          leftModule: leftModule,
          rightModule: rightModule,
          leftSignature: left.resultTypeSignatures[i],
          rightSignature: right.resultTypeSignatures[i],
          seenPairs: seenPairs,
          leftGroupStart: leftGroupStart,
          rightGroupStart: rightGroupStart,
          recGroupSize: recGroupSize,
        )) {
          return false;
        }
      }
      return true;
    }

    if (left.fieldSignatures.length != right.fieldSignatures.length) {
      return false;
    }
    for (var i = 0; i < left.fieldSignatures.length; i++) {
      final leftField = _parseFieldSignature(left.fieldSignatures[i]);
      final rightField = _parseFieldSignature(right.fieldSignatures[i]);
      if (leftField == null || rightField == null) {
        return false;
      }
      if (leftField.mutability != rightField.mutability) {
        return false;
      }
      if (!_areValueSignaturesEquivalentAcrossModules(
        leftModule: leftModule,
        rightModule: rightModule,
        leftSignature: leftField.valueSignature,
        rightSignature: rightField.valueSignature,
        seenPairs: seenPairs,
        leftGroupStart: leftGroupStart,
        rightGroupStart: rightGroupStart,
        recGroupSize: recGroupSize,
      )) {
        return false;
      }
    }
    return true;
  }

  static bool _areValueSignaturesEquivalentAcrossModules({
    required WasmModule leftModule,
    required WasmModule rightModule,
    required String leftSignature,
    required String rightSignature,
    required Set<String> seenPairs,
    required int leftGroupStart,
    required int rightGroupStart,
    required int recGroupSize,
  }) {
    final leftRef = _parseRefSignature(leftSignature);
    final rightRef = _parseRefSignature(rightSignature);
    if (leftRef == null || rightRef == null) {
      return leftSignature == rightSignature;
    }
    if (leftRef.nullable != rightRef.nullable ||
        leftRef.exact != rightRef.exact) {
      return false;
    }
    final leftHeap = leftRef.heapType;
    final rightHeap = rightRef.heapType;
    if (leftHeap < 0 || rightHeap < 0) {
      return leftHeap == rightHeap;
    }

    final leftInGroup =
        leftHeap >= leftGroupStart && leftHeap < leftGroupStart + recGroupSize;
    final rightInGroup =
        rightHeap >= rightGroupStart &&
        rightHeap < rightGroupStart + recGroupSize;
    if (leftInGroup || rightInGroup) {
      if (!leftInGroup || !rightInGroup) {
        return false;
      }
      return (leftHeap - leftGroupStart) == (rightHeap - rightGroupStart);
    }
    if (leftHeap == rightHeap && identical(leftModule, rightModule)) {
      return true;
    }
    return _areTypesEquivalentAcrossModules(
      leftModule: leftModule,
      leftTypeIndex: leftHeap,
      rightModule: rightModule,
      rightTypeIndex: rightHeap,
      seenPairs: seenPairs,
    );
  }

  static ({String valueSignature, int mutability})? _parseFieldSignature(
    String signature,
  ) {
    final bytes = _signatureToBytes(signature);
    if (bytes.length < 2) {
      return null;
    }
    final mutability = bytes.last;
    if (mutability != 0 && mutability != 1) {
      return null;
    }
    return (
      valueSignature: _bytesToSignature(bytes.sublist(0, bytes.length - 1)),
      mutability: mutability,
    );
  }

  static ({bool nullable, bool exact, int heapType})? _parseRefSignature(
    String signature,
  ) {
    final bytes = _signatureToBytes(signature);
    if (bytes.isEmpty) {
      return null;
    }
    if (bytes.length == 1) {
      final heapType = _legacyHeapTypeFromRefTypeCode(bytes.single);
      if (heapType == null) {
        final decoded = _readSignedLeb33FromBytes(bytes, 0);
        if (decoded == null || decoded.$2 != bytes.length) {
          return null;
        }
        return (nullable: true, exact: false, heapType: decoded.$1);
      }
      return (nullable: true, exact: false, heapType: heapType);
    }
    if (bytes.length < 2) {
      return null;
    }
    final refPrefix = bytes[0];
    if (refPrefix != 0x63 && refPrefix != 0x64) {
      final decoded = _readSignedLeb33FromBytes(bytes, 0);
      if (decoded == null || decoded.$2 != bytes.length) {
        return null;
      }
      return (nullable: true, exact: false, heapType: decoded.$1);
    }
    var offset = 1;
    var exact = false;
    if (bytes[offset] == 0x62 || bytes[offset] == 0x61) {
      exact = bytes[offset] == 0x62;
      offset++;
      if (offset >= bytes.length) {
        return null;
      }
    }
    final decodedHeap = _readSignedLeb33FromBytes(bytes, offset);
    if (decodedHeap == null || decodedHeap.$2 != bytes.length) {
      return null;
    }
    return (
      nullable: refPrefix == 0x63,
      exact: exact,
      heapType: decodedHeap.$1,
    );
  }

  static (int, int)? _readSignedLeb33FromBytes(List<int> bytes, int offset) {
    if (offset >= bytes.length) {
      return null;
    }
    final firstByte = bytes[offset];
    var result = firstByte & 0x7f;
    var shift = 7;
    var byte = firstByte;
    var multiplier = 128;
    var index = offset + 1;
    while ((byte & 0x80) != 0) {
      if (index >= bytes.length) {
        return null;
      }
      byte = bytes[index++];
      result += (byte & 0x7f) * multiplier;
      multiplier *= 128;
      shift += 7;
      if (shift > 35) {
        return null;
      }
    }
    if (shift < 33 && (byte & 0x40) != 0) {
      result -= multiplier;
    }
    return (_normalizeSignedLeb33(result), index);
  }

  static int _normalizeSignedLeb33(int value) {
    const signBit33 = 0x100000000;
    const width33 = 0x200000000;
    var normalized = value % width33;
    if (normalized < 0) {
      normalized += width33;
    }
    if (normalized >= signBit33) {
      normalized -= width33;
    }
    return normalized;
  }

  static int? _legacyHeapTypeFromRefTypeCode(int code) {
    return switch (code & 0xff) {
      0x70 => -16, // funcref
      0x6f => -17, // externref
      0x6e => -18, // anyref
      0x6d => -19, // eqref
      0x6c => -21, // i31ref
      0x6b => -20, // structref
      0x6a => -14, // arrayref
      0x69 => -22, // exnref legacy alias
      0x68 => -24, // noexn legacy alias
      0x74 => -22, // exnref
      0x75 => -24, // noexn
      0x71 => -23, // nullref
      0x72 => -15, // nullexternref
      0x73 => -13, // nullfuncref
      _ => null,
    };
  }

  static List<int> _signatureToBytes(String signature) {
    if (signature.isEmpty || signature.length.isOdd) {
      return const <int>[];
    }
    final bytes = <int>[];
    for (var i = 0; i < signature.length; i += 2) {
      bytes.add(int.parse(signature.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  static String _bytesToSignature(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static int _functionTypeDepth(WasmModule module, int typeIndex) {
    return _functionTypeDepthInternal(module, typeIndex, <int>{});
  }

  static int _functionTypeDepthInternal(
    WasmModule module,
    int typeIndex,
    Set<int> seen,
  ) {
    if (!seen.add(typeIndex)) {
      return 0;
    }
    if (typeIndex < 0 || typeIndex >= module.types.length) {
      return 0;
    }
    final type = module.types[typeIndex];
    if (!type.isFunctionType || type.superTypeIndices.isEmpty) {
      return 0;
    }
    var maxDepth = 0;
    for (final superTypeIndex in type.superTypeIndices) {
      final superDepth = _functionTypeDepthInternal(
        module,
        superTypeIndex,
        seen,
      );
      if (superDepth > maxDepth) {
        maxDepth = superDepth;
      }
    }
    return maxDepth + 1;
  }
}

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    _printUsage();
    return;
  }

  final prepareManifest = _argValue(args, '--prepare-manifest');
  final playerManifest = _argValue(args, '--player-manifest');
  if (prepareManifest != null && playerManifest != null) {
    stderr.writeln(
      'Use only one mode: --prepare-manifest or --player-manifest.',
    );
    exitCode = 2;
    return;
  }

  if (prepareManifest != null) {
    await _runPrepareManifestMode(args, prepareManifest);
    return;
  }
  if (playerManifest != null) {
    await _runPlayerMode(playerManifest);
    return;
  }

  await _runVmMode(args);
}

Future<void> _runVmMode(List<String> args) async {
  final suite = _parseSuite(_argValue(args, '--suite') ?? 'proposal');
  final defaultOutputJson = _defaultOutputJsonForSuite(suite);
  final defaultOutputMarkdown = _defaultOutputMarkdownForSuite(suite);
  final testsuiteDir =
      _argValue(args, '--testsuite-dir') ??
      '${Directory.current.path}/third_party/wasm-spec-tests';
  final outputJson = _argValue(args, '--output-json') ?? defaultOutputJson;
  final outputMarkdown =
      _argValue(args, '--output-md') ?? defaultOutputMarkdown;
  final maxFilesRaw = _argValue(args, '--max-files');
  final maxFiles = maxFilesRaw == null ? null : int.tryParse(maxFilesRaw);

  final converter = await _resolveWastConverter(
    jsonFromWast: _argValue(args, '--json-from-wast'),
    wast2json: _argValue(args, '--wast2json'),
  );
  final textModuleParsers = await _resolveTextModuleParsers(converter);
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
  final skipReasonCounts = <String, int>{};
  final groupStats = <String, Map<String, int>>{};

  for (final file in selectedFiles) {
    final group = _groupForFile(file, testsuite.path);
    final result = await _runWastFile(
      file: file,
      group: group,
      converter: converter,
      textModuleParsers: textModuleParsers,
    );
    results.add(result);
    _accumulateStats(
      result,
      groupStats: groupStats,
      reasonCounts: reasonCounts,
      skipReasonCounts: skipReasonCounts,
    );
  }

  final endedAt = DateTime.now().toUtc();
  final revision = await _git([
    '-C',
    testsuite.path,
    'rev-parse',
    '--short',
    'HEAD',
  ]);

  final payload = _buildPayload(
    startedAt: startedAt,
    endedAt: endedAt,
    suiteName: suite.name,
    testsuiteDir: testsuite.path,
    testsuiteRevision: revision,
    converterLabel: converter.label,
    converterBinary: converter.binary,
    results: results,
    groupStats: groupStats,
    reasonCounts: reasonCounts,
    skipReasonCounts: skipReasonCounts,
  );

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

  final filesFailed =
      (payload['totals'] as Map<String, Object?>)['files_failed'] as int;
  stdout.writeln(
    'spec-testsuite status: ${filesFailed == 0 ? 'passed' : 'failed'}',
  );
  stdout.writeln('json report: ${jsonFile.path}');
  stdout.writeln('markdown report: ${markdownFile.path}');

  if (filesFailed > 0) {
    exitCode = 1;
  }
}

Future<void> _runPrepareManifestMode(
  List<String> args,
  String manifestPath,
) async {
  final suite = _parseSuite(_argValue(args, '--suite') ?? 'proposal');
  final defaultPrepareRoot = _defaultPrepareRootForSuite(suite);
  final testsuiteDir =
      _argValue(args, '--testsuite-dir') ??
      '${Directory.current.path}/third_party/wasm-spec-tests';
  final maxFilesRaw = _argValue(args, '--max-files');
  final maxFiles = maxFilesRaw == null ? null : int.tryParse(maxFilesRaw);
  final prepareRoot = _argValue(args, '--prepare-root') ?? defaultPrepareRoot;

  final converter = await _resolveWastConverter(
    jsonFromWast: _argValue(args, '--json-from-wast'),
    wast2json: _argValue(args, '--wast2json'),
  );
  final textModuleParsers = await _resolveTextModuleParsers(converter);
  final testsuite = Directory(testsuiteDir);
  if (!testsuite.existsSync()) {
    stderr.writeln('testsuite directory does not exist: ${testsuite.path}');
    exitCode = 2;
    return;
  }

  final files = _collectSuiteFiles(testsuite.path, suite);
  final selectedFiles = maxFiles == null
      ? files
      : files.take(maxFiles).toList();

  final rootDir = Directory(prepareRoot);
  if (rootDir.existsSync()) {
    await rootDir.delete(recursive: true);
  }
  await rootDir.create(recursive: true);

  final startedAt = DateTime.now().toUtc();
  final entries = <_PreparedManifestEntry>[];
  for (var i = 0; i < selectedFiles.length; i++) {
    final file = selectedFiles[i];
    final group = _groupForFile(file, testsuite.path);
    final slot = Directory('${rootDir.path}/f${i.toString().padLeft(4, '0')}');
    await slot.create(recursive: true);
    final jsonPath = '${slot.path}/script.json';
    final conversion = await Process.run(
      converter.binary,
      converter.command(
        wastFile: file,
        outputJsonPath: jsonPath,
        wasmDir: slot.path,
      ),
    );
    if (conversion.exitCode != 0) {
      stderr.writeln('failed to convert: $file');
      stderr.writeln(((conversion.stderr as String?) ?? '').trim());
      exitCode = 1;
      return;
    }
    if (textModuleParsers.isNotEmpty) {
      await _annotatePreparedScriptTextMalformedAssertions(
        scriptJsonPath: jsonPath,
        workDirPath: slot.path,
        parsers: textModuleParsers,
      );
    }
    entries.add(
      _PreparedManifestEntry(
        path: file,
        group: group,
        workDirPath: slot.path,
        scriptJsonPath: jsonPath,
        wasmDirPath: slot.path,
      ),
    );
  }

  final endedAt = DateTime.now().toUtc();
  final revision = await _git([
    '-C',
    testsuite.path,
    'rev-parse',
    '--short',
    'HEAD',
  ]);
  final payload = <String, Object?>{
    'started_at_utc': startedAt.toIso8601String(),
    'ended_at_utc': endedAt.toIso8601String(),
    'suite': suite.name,
    'testsuite_dir': testsuite.path,
    'testsuite_revision': revision,
    'wast_converter': converter.label,
    'wast_converter_binary': converter.binary,
    'entries': entries.map((e) => e.toJson()).toList(growable: false),
  };

  final manifestFile = File(manifestPath);
  await manifestFile.parent.create(recursive: true);
  await manifestFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(payload),
  );
  stdout.writeln('prepared manifest: ${manifestFile.path}');
  stdout.writeln('prepared entries: ${entries.length}');
}

Future<void> _runPlayerMode(String manifestPath) async {
  try {
    final manifestText = player_bridge.specReadText(manifestPath);
    final manifestDecoded = json.decode(manifestText);
    if (manifestDecoded is! Map) {
      throw StateError('player manifest root is not an object');
    }
    final manifest = manifestDecoded.cast<String, Object?>();
    final entriesRaw = manifest['entries'];
    if (entriesRaw is! List) {
      throw StateError('player manifest missing entries list');
    }

    final startedAt = DateTime.now().toUtc();
    final results = <_FileResult>[];
    final reasonCounts = <String, int>{};
    final skipReasonCounts = <String, int>{};
    final groupStats = <String, Map<String, int>>{};

    for (final rawEntry in entriesRaw) {
      if (rawEntry is! Map) {
        throw StateError('invalid player entry: $rawEntry');
      }
      final entry = rawEntry.cast<String, Object?>();
      final file = entry['path'] as String?;
      final group = entry['group'] as String?;
      final scriptJsonPath = entry['script_json_path'] as String?;
      final wasmDirPath = entry['wasm_dir'] as String?;
      if (file == null ||
          group == null ||
          scriptJsonPath == null ||
          wasmDirPath == null) {
        throw StateError('player entry missing required fields: $entry');
      }

      final scriptJsonText = player_bridge.specReadText(scriptJsonPath);
      final scriptDecoded = json.decode(scriptJsonText);
      if (scriptDecoded is! Map) {
        throw StateError('script root is not object: $scriptJsonPath');
      }
      final script = scriptDecoded.cast<String, Object?>();
      final commandsRaw = script['commands'];
      if (commandsRaw is! List) {
        throw StateError('script missing commands: $scriptJsonPath');
      }

      final state = _ScriptExecutionState(
        workDirPath: wasmDirPath,
        features: _featuresForGroup(group),
        moduleLoader: (filename) =>
            player_bridge.specReadBinary('$wasmDirPath/$filename'),
      );
      final result = _executeCommands(
        path: file,
        group: group,
        commandsRaw: commandsRaw,
        state: state,
      );
      results.add(result);
      _accumulateStats(
        result,
        groupStats: groupStats,
        reasonCounts: reasonCounts,
        skipReasonCounts: skipReasonCounts,
      );
    }

    final endedAt = DateTime.now().toUtc();
    final payload = _buildPayload(
      startedAt: startedAt,
      endedAt: endedAt,
      suiteName: (manifest['suite'] as String?) ?? 'proposal',
      testsuiteDir: (manifest['testsuite_dir'] as String?) ?? '',
      testsuiteRevision: manifest['testsuite_revision'] as String?,
      converterLabel:
          (manifest['wast_converter'] as String?) ?? 'prepared-manifest',
      converterBinary:
          (manifest['wast_converter_binary'] as String?) ?? 'prepared-manifest',
      results: results,
      groupStats: groupStats,
      reasonCounts: reasonCounts,
      skipReasonCounts: skipReasonCounts,
    );

    player_bridge.specSetResult(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    final filesFailed =
        (payload['totals'] as Map<String, Object?>)['files_failed'] as int;
    if (filesFailed > 0) {
      throw StateError('spec-testsuite failed: files_failed=$filesFailed');
    }
  } catch (error) {
    player_bridge.specSetError(
      jsonEncode(<String, Object?>{'error': '$error'}),
    );
    rethrow;
  }
}

Future<_FileResult> _runWastFile({
  required String file,
  required String group,
  required _WastConverter converter,
  required List<_TextModuleParser> textModuleParsers,
}) async {
  final tempDir = await Directory.systemTemp.createTemp('wasd-spec-');
  try {
    final jsonPath = '${tempDir.path}/script.json';
    final conversion = await Process.run(
      converter.binary,
      converter.command(
        wastFile: file,
        outputJsonPath: jsonPath,
        wasmDir: tempDir.path,
      ),
    );
    if (conversion.exitCode != 0) {
      return _FileResult(
        path: file,
        group: group,
        commandsSeen: 0,
        commandsPassed: 0,
        commandsFailed: 1,
        commandsSkipped: 0,
        skipReasonCounts: const <String, int>{},
        passed: false,
        firstFailureReason: 'wast-convert-failed',
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
        skipReasonCounts: const <String, int>{},
        passed: false,
        firstFailureReason: 'invalid-json-root',
        firstFailureDetails: 'converter output root is not an object',
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
        skipReasonCounts: const <String, int>{},
        passed: false,
        firstFailureReason: 'invalid-commands',
        firstFailureDetails: 'converter output does not contain command list',
      );
    }

    final state = _ScriptExecutionState(
      workDirPath: tempDir.path,
      features: _featuresForGroup(group),
    );
    if (textModuleParsers.isNotEmpty) {
      await _annotateCommandsTextMalformedAssertions(
        commandsRaw: commandsRaw,
        workDirPath: tempDir.path,
        parsers: textModuleParsers,
      );
    }
    return _executeCommands(
      path: file,
      group: group,
      commandsRaw: commandsRaw,
      state: state,
    );
  } finally {
    await tempDir.delete(recursive: true);
  }
}

Future<void> _annotatePreparedScriptTextMalformedAssertions({
  required String scriptJsonPath,
  required String workDirPath,
  required List<_TextModuleParser> parsers,
}) async {
  final file = File(scriptJsonPath);
  final decoded = json.decode(await file.readAsString());
  if (decoded is! Map) {
    return;
  }
  final root = decoded.cast<String, Object?>();
  final commandsRaw = root['commands'];
  if (commandsRaw is! List) {
    return;
  }
  await _annotateCommandsTextMalformedAssertions(
    commandsRaw: commandsRaw,
    workDirPath: workDirPath,
    parsers: parsers,
  );
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(root));
}

Future<void> _annotateCommandsTextMalformedAssertions({
  required List commandsRaw,
  required String workDirPath,
  required List<_TextModuleParser> parsers,
}) async {
  final cache = <String, bool>{};
  for (final raw in commandsRaw) {
    if (raw is! Map) {
      continue;
    }
    final command = raw.cast<String, Object?>();
    if (command['type'] != 'assert_malformed' ||
        command['module_type'] != 'text') {
      continue;
    }
    final filename = command['filename'];
    if (filename is! String || filename.isEmpty) {
      continue;
    }
    final key = '$workDirPath::$filename';
    final malformed = cache.putIfAbsent(
      key,
      () => _isTextModuleMalformed(
        filename: filename,
        workDirPath: workDirPath,
        parsers: parsers,
      ),
    );
    command['wasd_text_malformed_validated'] = malformed;
  }
}

bool _isTextModuleMalformed({
  required String filename,
  required String workDirPath,
  required List<_TextModuleParser> parsers,
}) {
  final watPath = '$workDirPath/$filename';
  if (!File(watPath).existsSync()) {
    return false;
  }
  for (final parser in parsers) {
    final probeOutput =
        '$workDirPath/.wasd_text_probe_${parser.kind.name}.wasm';
    final result = Process.runSync(
      parser.binary,
      parser.command(watFile: watPath, outputWasmPath: probeOutput),
      stdoutEncoding: latin1,
      stderrEncoding: latin1,
    );
    final outputFile = File(probeOutput);
    if (outputFile.existsSync()) {
      outputFile.deleteSync();
    }
    if (result.exitCode != 0) {
      // assert_malformed(text) succeeds when at least one compliant text parser
      // rejects the quoted module.
      return true;
    }
  }
  return false;
}

_FileResult _executeCommands({
  required String path,
  required String group,
  required List commandsRaw,
  required _ScriptExecutionState state,
}) {
  var commandsSeen = 0;
  var commandsPassed = 0;
  var commandsFailed = 0;
  var commandsSkipped = 0;
  final skipReasonCounts = <String, int>{};
  int? firstFailureLine;
  String? firstFailureReason;
  String? firstFailureDetails;

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
      final reason = outcome.reason ?? 'unknown-skip';
      skipReasonCounts[reason] = (skipReasonCounts[reason] ?? 0) + 1;
      continue;
    }
    if (outcome.passed) {
      commandsPassed++;
      continue;
    }

    commandsFailed++;
    firstFailureLine ??= command['line'] is int ? command['line'] as int : null;
    firstFailureReason ??= outcome.reason;
    firstFailureDetails ??= outcome.details;
    break;
  }

  return _FileResult(
    path: path,
    group: group,
    commandsSeen: commandsSeen,
    commandsPassed: commandsPassed,
    commandsFailed: commandsFailed,
    commandsSkipped: commandsSkipped,
    skipReasonCounts: skipReasonCounts,
    passed: commandsFailed == 0,
    firstFailureLine: firstFailureLine,
    firstFailureReason: firstFailureReason,
    firstFailureDetails: firstFailureDetails,
  );
}

void _accumulateStats(
  _FileResult result, {
  required Map<String, Map<String, int>> groupStats,
  required Map<String, int> reasonCounts,
  required Map<String, int> skipReasonCounts,
}) {
  for (final entry in result.skipReasonCounts.entries) {
    skipReasonCounts[entry.key] =
        (skipReasonCounts[entry.key] ?? 0) + entry.value;
  }
  final groupCounter = groupStats.putIfAbsent(
    result.group,
    () => <String, int>{'total': 0, 'passed': 0, 'failed': 0},
  );
  groupCounter['total'] = (groupCounter['total'] ?? 0) + 1;
  if (result.passed) {
    groupCounter['passed'] = (groupCounter['passed'] ?? 0) + 1;
    return;
  }
  groupCounter['failed'] = (groupCounter['failed'] ?? 0) + 1;
  final reason = result.firstFailureReason ?? 'unknown-failure';
  reasonCounts[reason] = (reasonCounts[reason] ?? 0) + 1;
}

Map<String, Object?> _buildPayload({
  required DateTime startedAt,
  required DateTime endedAt,
  required String suiteName,
  required String testsuiteDir,
  required String? testsuiteRevision,
  required String converterLabel,
  required String converterBinary,
  required List<_FileResult> results,
  required Map<String, Map<String, int>> groupStats,
  required Map<String, int> reasonCounts,
  required Map<String, int> skipReasonCounts,
}) {
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

  return <String, Object?>{
    'started_at_utc': startedAt.toIso8601String(),
    'ended_at_utc': endedAt.toIso8601String(),
    'suite': suiteName,
    'testsuite_dir': testsuiteDir,
    'testsuite_revision': testsuiteRevision,
    'wast_converter': converterLabel,
    'wast_converter_binary': converterBinary,
    'wast2json': converterBinary,
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
    'skip_reason_counts': skipReasonCounts,
    'files': results.map((r) => r.toJson()).toList(growable: false),
  };
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

String _defaultOutputJsonForSuite(_SpecSuite suite) {
  switch (suite) {
    case _SpecSuite.core:
      return '.dart_tool/spec_runner/core_latest.json';
    case _SpecSuite.proposal:
      return '.dart_tool/spec_runner/proposal_latest.json';
    case _SpecSuite.all:
      return '.dart_tool/spec_runner/all_latest.json';
  }
}

String _defaultOutputMarkdownForSuite(_SpecSuite suite) {
  switch (suite) {
    case _SpecSuite.core:
      return '.dart_tool/spec_runner/wasm_core_failures.md';
    case _SpecSuite.proposal:
      return '.dart_tool/spec_runner/wasm_proposal_failures.md';
    case _SpecSuite.all:
      return '.dart_tool/spec_runner/wasm_all_failures.md';
  }
}

String _defaultPrepareRootForSuite(_SpecSuite suite) {
  switch (suite) {
    case _SpecSuite.core:
      return '.dart_tool/spec_runner/core_bundle';
    case _SpecSuite.proposal:
      return '.dart_tool/spec_runner/proposal_bundle';
    case _SpecSuite.all:
      return '.dart_tool/spec_runner/all_bundle';
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

WasmFeatureSet _featuresForGroup(String group) {
  final base = WasmFeatureSet.layeredDefaults(profile: WasmFeatureProfile.full);
  final additionalEnabled = <String>{...base.additionalEnabled};
  switch (group) {
    case 'core':
    case 'custom-page-sizes':
      additionalEnabled.add('multi-memory');
      additionalEnabled.add('multi-table');
      break;
    case 'custom-descriptors':
      additionalEnabled.add('custom-descriptors');
      break;
  }
  return base.copyWith(additionalEnabled: additionalEnabled);
}

String _renderMarkdown({
  required Map<String, Object?> payload,
  required List<_FileResult> results,
  required Map<String, Map<String, int>> groupStats,
}) {
  final totals = payload['totals'] as Map<String, Object?>;
  final reasonCounts = (payload['reason_counts'] as Map)
      .cast<String, Object?>();
  final skipReasonCounts = (payload['skip_reason_counts'] as Map)
      .cast<String, Object?>();
  final suiteLabel = _suiteLabel(payload['suite'] as String?);

  final b = StringBuffer()
    ..writeln('# WASM $suiteLabel Failure Board')
    ..writeln()
    ..writeln('- Started at (UTC): `${payload['started_at_utc']}`')
    ..writeln('- Ended at (UTC): `${payload['ended_at_utc']}`')
    ..writeln('- Suite: `${payload['suite']}`')
    ..writeln('- Testsuite dir: `${payload['testsuite_dir']}`')
    ..writeln(
      '- Testsuite revision: `${payload['testsuite_revision'] ?? 'unknown'}`',
    )
    ..writeln(
      '- Wast converter: `${payload['wast_converter']}` (`${payload['wast_converter_binary']}`)',
    )
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

  if (skipReasonCounts.isNotEmpty) {
    b.writeln();
    b.writeln('## Top Skip Reasons');
    b.writeln();
    b.writeln('| Reason | Count |');
    b.writeln('| --- | ---: |');
    final sorted = skipReasonCounts.entries.toList()
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

String _suiteLabel(String? suite) {
  switch ((suite ?? '').trim().toLowerCase()) {
    case 'core':
      return 'Core';
    case 'proposal':
      return 'Proposal';
    case 'all':
      return 'All';
    default:
      return 'Testsuite';
  }
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

Future<_WastConverter> _resolveWastConverter({
  required String? jsonFromWast,
  required String? wast2json,
}) async {
  if ((jsonFromWast?.isNotEmpty ?? false) && (wast2json?.isNotEmpty ?? false)) {
    throw ArgumentError('Use only one of `--json-from-wast` or `--wast2json`.');
  }

  if (jsonFromWast != null && jsonFromWast.isNotEmpty) {
    final binary = await _resolveBinaryCandidates(
      <String>[jsonFromWast],
      missingMessage:
          'Unable to locate `--json-from-wast` binary: $jsonFromWast',
    );
    return _WastConverter(
      kind: _WastConverterKind.wasmToolsJsonFromWast,
      binary: binary,
    );
  }

  if (wast2json != null && wast2json.isNotEmpty) {
    final binary = await _resolveBinaryCandidates(<String>[
      wast2json,
    ], missingMessage: 'Unable to locate `--wast2json` binary: $wast2json');
    return _WastConverter(
      kind: _WastConverterKind.wabtWast2json,
      binary: binary,
    );
  }

  final wasmTools = await _tryResolveBinaryCandidates(<String>[
    '${Directory.current.path}/.toolchains/bin/wasm-tools',
    '${Directory.current.path}/.toolchains/wasm-tools-1.245.1/wasm-tools-1.245.1-aarch64-macos/wasm-tools',
    '${Directory.current.path}/.toolchains/wasm-tools-1.226.0/wasm-tools-1.226.0-aarch64-macos/wasm-tools',
    'wasm-tools',
  ]);
  if (wasmTools != null) {
    return _WastConverter(
      kind: _WastConverterKind.wasmToolsJsonFromWast,
      binary: wasmTools,
    );
  }

  final wast2jsonBinary = await _tryResolveBinaryCandidates(<String>[
    '${Directory.current.path}/.toolchains/bin/wast2json',
    '${Directory.current.path}/.toolchains/wabt-1.0.39/bin/wast2json',
    '${Directory.current.path}/.toolchains/wabt-1.0.37/bin/wast2json',
    'wast2json',
  ]);
  if (wast2jsonBinary != null) {
    return _WastConverter(
      kind: _WastConverterKind.wabtWast2json,
      binary: wast2jsonBinary,
    );
  }

  throw StateError(
    'Unable to locate wast converter (`wasm-tools` or `wast2json`). '
    'Run `bash tool/ensure_toolchains.sh` first.',
  );
}

Future<List<_TextModuleParser>> _resolveTextModuleParsers(
  _WastConverter converter,
) async {
  final parsers = <_TextModuleParser>[];
  void addParser(_TextModuleParser parser) {
    final duplicate = parsers.any(
      (candidate) =>
          candidate.kind == parser.kind && candidate.binary == parser.binary,
    );
    if (!duplicate) {
      parsers.add(parser);
    }
  }

  if (converter.kind == _WastConverterKind.wasmToolsJsonFromWast) {
    addParser(
      _TextModuleParser(
        kind: _TextModuleParserKind.wasmToolsParse,
        binary: converter.binary,
      ),
    );
  }

  final directWat2Wasm = _siblingBinary(converter.binary, 'wat2wasm');
  if (directWat2Wasm != null && File(directWat2Wasm).existsSync()) {
    addParser(
      _TextModuleParser(
        kind: _TextModuleParserKind.wabtWat2Wasm,
        binary: directWat2Wasm,
      ),
    );
  }

  final wat2wasm = await _tryResolveBinaryCandidates(<String>[
    '${Directory.current.path}/.toolchains/bin/wat2wasm',
    '${Directory.current.path}/.toolchains/wabt-1.0.39/bin/wat2wasm',
    '${Directory.current.path}/.toolchains/wabt-1.0.37/bin/wat2wasm',
    'wat2wasm',
  ]);
  if (wat2wasm != null) {
    addParser(
      _TextModuleParser(
        kind: _TextModuleParserKind.wabtWat2Wasm,
        binary: wat2wasm,
      ),
    );
  }

  final wasmTools = await _tryResolveBinaryCandidates(<String>[
    '${Directory.current.path}/.toolchains/bin/wasm-tools',
    'wasm-tools',
  ]);
  if (wasmTools != null) {
    addParser(
      _TextModuleParser(
        kind: _TextModuleParserKind.wasmToolsParse,
        binary: wasmTools,
      ),
    );
  }

  if (converter.kind == _WastConverterKind.wabtWast2json) {
    // If `wast2json` drove conversion, keep parser ordering stable by preferring
    // wabt first and wasm-tools as fallback.
    parsers.sort((left, right) {
      final leftScore = left.kind == _TextModuleParserKind.wabtWat2Wasm ? 0 : 1;
      final rightScore = right.kind == _TextModuleParserKind.wabtWat2Wasm
          ? 0
          : 1;
      return leftScore.compareTo(rightScore);
    });
  } else {
    // When wasm-tools drives conversion, prioritize wasm-tools parse first.
    parsers.sort((left, right) {
      final leftScore = left.kind == _TextModuleParserKind.wasmToolsParse
          ? 0
          : 1;
      final rightScore = right.kind == _TextModuleParserKind.wasmToolsParse
          ? 0
          : 1;
      return leftScore.compareTo(rightScore);
    });
  }

  return parsers;
}

String? _siblingBinary(String binary, String siblingName) {
  if (!binary.contains('/')) {
    return null;
  }
  final parent = File(binary).parent.path;
  return '$parent/$siblingName';
}

Future<String> _resolveBinaryCandidates(
  List<String> candidates, {
  required String missingMessage,
}) async {
  final resolved = await _tryResolveBinaryCandidates(candidates);
  if (resolved != null) {
    return resolved;
  }
  throw StateError(missingMessage);
}

Future<String?> _tryResolveBinaryCandidates(List<String> candidates) async {
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
  return null;
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
    '[--json-from-wast=<path>] '
    '[--wast2json=<path>] '
    '[--prepare-manifest=<path>] '
    '[--prepare-root=<path>] '
    '[--player-manifest=<path>]',
  );
}
