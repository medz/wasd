import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:wasd/wasd.dart';

@JS('globalThis.wasdSpecReadText')
external JSString _jsSpecReadText(JSString path);

@JS('globalThis.wasdSpecReadBinary')
external JSUint8Array _jsSpecReadBinary(JSString path);

@JS('globalThis.wasdSpecSetResult')
external void _jsSpecSetResult(JSString payloadJson);

@JS('globalThis.wasdSpecSetError')
external void _jsSpecSetError(JSString payloadJson);
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
      floatBits = null,
      expectsRef = false,
      expectsNullRef = false;
  const _ExpectedValue.i64(this.value)
    : type = 'i64',
      isNaN = false,
      floatBits = null,
      expectsRef = false,
      expectsNullRef = false;
  const _ExpectedValue.f32(this.floatBits)
    : type = 'f32',
      isNaN = false,
      value = null,
      expectsRef = false,
      expectsNullRef = false;
  const _ExpectedValue.f64(this.floatBits)
    : type = 'f64',
      isNaN = false,
      value = null,
      expectsRef = false,
      expectsNullRef = false;
  const _ExpectedValue.nan(this.type)
    : isNaN = true,
      value = null,
      floatBits = null,
      expectsRef = false,
      expectsNullRef = false;
  const _ExpectedValue.ref(this.type, {required this.expectsNullRef})
    : isNaN = false,
      value = null,
      floatBits = null,
      expectsRef = true;

  final String type;
  final bool isNaN;
  final int? value;
  final int? floatBits;
  final bool expectsRef;
  final bool expectsNullRef;
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
    'wast2json_stdout': null,
    'wast2json_stderr': null,
  };
}

final class _ScriptExecutionState {
  _ScriptExecutionState({
    required WasmFeatureSet features,
    required Uint8List Function(String filename) moduleLoader,
  }) : _features = features,
       _moduleLoader = moduleLoader;

  final WasmFeatureSet _features;
  final Uint8List Function(String filename) _moduleLoader;

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
    try {
      return _moduleLoader(filename);
    } catch (_) {
      throw _SpecRunnerFailure(
        'module-file-missing',
        'Generated file not found: $filename',
      );
    }
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
    final expectedFunctionImports = <String, WasmImport>{};
    for (final import in targetModule.imports) {
      if (import.kind != WasmImportKind.function &&
          import.kind != WasmImportKind.exactFunction) {
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
      WasmImports.key('spectest', 'global_f32'): 666.0,
      WasmImports.key('spectest', 'global_f64'): 666.0,
    };
    final memories = <String, WasmMemory>{
      WasmImports.key('spectest', 'memory'): _spectestMemory,
      WasmImports.key('spectest', 'shared_memory'): _spectestSharedMemory,
    };
    final tables = <String, WasmTable>{
      WasmImports.key('spectest', 'table'): _spectestTable,
    };

    for (final entry in _registeredModules.entries) {
      final alias = entry.key;
      final instance = entry.value;
      for (final export in instance.exportedFunctions) {
        final key = WasmImports.key(alias, export);
        final expectedImport = expectedFunctionImports[key];
        if (expectedImport == null) {
          continue;
        }
        final expectedType = targetModule.types[expectedImport.functionTypeIndex!];
        final expectedDepth = _functionTypeDepth(
          targetModule,
          expectedImport.functionTypeIndex!,
        );
        final actualType = instance.exportedFunctionType(export);
        final actualDepth = instance.exportedFunctionTypeDepth(export);
        if (!_functionTypeCompatibleForImport(
          expectedType: expectedType,
          expectedDepth: expectedDepth,
          isExactImport: expectedImport.isExactFunction,
          actualType: actualType,
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
      functionTypeDepths: functionTypeDepths,
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
    if (value is! String &&
        type != 'nullref' &&
        type != 'nullfuncref' &&
        type != 'nullstructref' &&
        type != 'nullarrayref') {
      throw _SpecRunnerFailure('invalid-arg-value', '$raw');
    }

    switch (type) {
      case 'i32':
        final valueString = value as String;
        return _signedBits(BigInt.parse(valueString), 32);
      case 'i64':
        final valueString = value as String;
        return _signedBits(BigInt.parse(valueString), 64);
      case 'f32':
        final valueString = value as String;
        return _f32FromBits(_parseFloatBits(valueString, 32));
      case 'f64':
        final valueString = value as String;
        return _f64FromBits(_parseFloatBits(valueString, 64));
      case 'externref':
      case 'funcref':
      case 'structref':
      case 'arrayref':
        final valueString = value as String;
        return _signedBits(BigInt.parse(valueString), 32);
      case 'nullref':
      case 'nullfuncref':
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

  static _ExpectedValue _parseExpectedValue(Map<String, Object?> raw) {
    final type = raw['type'];
    final value = raw['value'];
    if (type is! String) {
      throw _SpecRunnerFailure('invalid-expected-type', '$raw');
    }
    if (value is! String &&
        type != 'funcref' &&
        type != 'externref' &&
        type != 'structref' &&
        type != 'arrayref' &&
        type != 'nullref' &&
        type != 'nullfuncref' &&
        type != 'nullstructref' &&
        type != 'nullarrayref') {
      throw _SpecRunnerFailure('invalid-expected-value', '$raw');
    }

    switch (type) {
      case 'i32':
        final valueString = value as String;
        return _ExpectedValue.i32(_signedBits(BigInt.parse(valueString), 32));
      case 'i64':
        final valueString = value as String;
        return _ExpectedValue.i64(_signedBits(BigInt.parse(valueString), 64));
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
      case 'funcref':
      case 'externref':
      case 'structref':
      case 'arrayref':
        return _ExpectedValue.ref(type, expectsNullRef: false);
      case 'nullref':
      case 'nullfuncref':
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
        if (expected.floatBits == null) {
          return false;
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
        return _f64Bits(actual) == expected.floatBits;
      default:
        return false;
    }
  }

  static int _parseFloatBits(String value, int bits) {
    final integer = _tryParseInteger(value);
    if (integer != null) {
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

  static double _f32FromBits(int bits) {
    final data = ByteData(4)..setUint32(0, bits.toUnsigned(32), Endian.little);
    return data.getFloat32(0, Endian.little);
  }

  static int _f64Bits(double value) {
    final data = ByteData(8)..setFloat64(0, value, Endian.little);
    final low = data.getUint32(0, Endian.little);
    final high = data.getUint32(4, Endian.little);
    return (BigInt.from(high) << 32 | BigInt.from(low)).toInt();
  }

  static double _f64FromBits(int bits) {
    final normalized = BigInt.from(bits) & ((BigInt.one << 64) - BigInt.one);
    final low = (normalized & BigInt.from(0xffffffff)).toInt();
    final high = ((normalized >> 32) & BigInt.from(0xffffffff)).toInt();
    final data = ByteData(8)
      ..setUint32(0, low, Endian.little)
      ..setUint32(4, high, Endian.little);
    return data.getFloat64(0, Endian.little);
  }

  static String _expectedToString(_ExpectedValue expected) {
    if (expected.expectsRef) {
      return expected.expectsNullRef ? '${expected.type}(null)' : expected.type;
    }
    if (expected.isNaN) {
      return '${expected.type}(nan)';
    }
    if (expected.value != null) {
      return '${expected.type}(${expected.value})';
    }
    return '${expected.type}(bits=${expected.floatBits})';
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

  static bool _functionTypeCompatibleForImport({
    required WasmFunctionType expectedType,
    required int expectedDepth,
    required bool isExactImport,
    required WasmFunctionType actualType,
    required int actualDepth,
  }) {
    if (!_functionTypesEqual(expectedType, actualType)) {
      return false;
    }
    if (isExactImport) {
      return actualDepth == expectedDepth;
    }
    return actualDepth >= expectedDepth;
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
      final superDepth = _functionTypeDepthInternal(module, superTypeIndex, seen);
      if (superDepth > maxDepth) {
        maxDepth = superDepth;
      }
    }
    return maxDepth + 1;
  }
}

Future<void> main(List<String> args) async {
  final manifestPath = _argValue(args, '--player-manifest');
  if (manifestPath == null || manifestPath.isEmpty) {
    final message = 'Missing required --player-manifest=<path>.';
    _jsSpecSetError(jsonEncode(<String, Object?>{'error': message}).toJS);
    throw ArgumentError(message);
  }

  try {
    final manifestText = _jsSpecReadText(manifestPath.toJS).toDart;
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

      final scriptJsonText = _jsSpecReadText(scriptJsonPath.toJS).toDart;
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
        features: _featuresForGroup(group),
        moduleLoader: (filename) =>
            _jsSpecReadBinary('$wasmDirPath/$filename'.toJS).toDart,
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
    );

    _jsSpecSetResult(const JsonEncoder.withIndent('  ').convert(payload).toJS);
    final filesFailed =
        (payload['totals'] as Map<String, Object?>)['files_failed'] as int;
    if (filesFailed > 0) {
      throw StateError('spec-testsuite failed: files_failed=$filesFailed');
    }
  } catch (error) {
    _jsSpecSetError(jsonEncode(<String, Object?>{'error': '$error'}).toJS);
    rethrow;
  }
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
}) {
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
    'files': results.map((r) => r.toJson()).toList(growable: false),
  };
}
WasmFeatureSet _featuresForGroup(String group) {
  final base = WasmFeatureSet.layeredDefaults(profile: WasmFeatureProfile.full);
  final additionalEnabled = <String>{...base.additionalEnabled};
  switch (group) {
    case 'custom-page-sizes':
      additionalEnabled.add('multi-memory');
      break;
  }
  return base.copyWith(additionalEnabled: additionalEnabled);
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
