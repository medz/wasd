import 'dart:async';
import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../component/async_values.dart';
import '../component/wit_adapter.dart';

/// Receives bytes written by WASI 0.3 CLI stdout or stderr streams.
typedef WASIPreview3CliOutputHandler = void Function(Uint8List bytes);

/// Exception used to terminate a WASI 0.3 command instance.
final class WASIPreview3Exit implements Exception {
  /// Creates a Preview3 command exit marker.
  const WASIPreview3Exit(this.statusCode);

  /// Host status code requested by the command.
  final int statusCode;

  /// Whether [statusCode] conventionally represents success.
  bool get isSuccess => statusCode == 0;

  @override
  String toString() => 'WASIPreview3Exit($statusCode)';
}

/// WASI 0.3 `wasi:cli` host imports.
final class WASIPreview3CliHost {
  /// Creates a CLI host import provider.
  WASIPreview3CliHost({
    List<String> args = const <String>[],
    Map<String, String> env = const <String, String>{},
    this.initialCwd,
    List<int> stdinData = const <int>[],
    WASIComponentReadableStream<int>? stdin,
    WASIPreview3CliOutputHandler? stdout,
    WASIPreview3CliOutputHandler? stderr,
  }) : args = List<String>.unmodifiable(args),
       env = Map<String, String>.unmodifiable(env),
       stdinData = Uint8List.fromList(stdinData),
       _stdin = stdin,
       _stdoutHandler = stdout,
       _stderrHandler = stderr;

  /// Program arguments returned by `get-arguments`.
  final List<String> args;

  /// Environment pairs returned by `get-environment`.
  final Map<String, String> env;

  /// Initial current working directory returned by `get-initial-cwd`.
  final String? initialCwd;

  /// Bytes served by `stdin.read-via-stream`.
  final Uint8List stdinData;

  final WASIComponentReadableStream<int>? _stdin;
  final WASIPreview3CliOutputHandler? _stdoutHandler;
  final WASIPreview3CliOutputHandler? _stderrHandler;
  final BytesBuilder _stdoutBytes = BytesBuilder(copy: false);
  final BytesBuilder _stderrBytes = BytesBuilder(copy: false);

  /// Bytes written to stdout when no custom sink consumes them first.
  Uint8List get stdoutBytes => _stdoutBytes.toBytes();

  /// Bytes written to stderr when no custom sink consumes them first.
  Uint8List get stderrBytes => _stderrBytes.toBytes();

  /// Import callbacks keyed by canonical WIT adapter names.
  late final Map<String, WASIComponentWitAdapterCallback> imports =
      Map<String, WASIComponentWitAdapterCallback>.unmodifiable({
        'wasi:cli/environment@0.3.0.get-environment': (_) => _environmentData(),
        'wasi:cli/environment@0.3.0.get-arguments': (_) => _argumentsData(),
        'wasi:cli/environment@0.3.0.get-initial-cwd': (_) => _initialCwdData(),
        'wasi:cli/exit@0.3.0.exit': (args) => _exit(args.single),
        'wasi:cli/exit@0.3.0.exit-with-code': (args) =>
            _exitWithCode(args.single),
        'wasi:cli/stdin@0.3.0.read-via-stream': (_) => _readStdinViaStream(),
        'wasi:cli/stdout@0.3.0.write-via-stream': (args) => _writeViaStream(
          args.single,
          name: 'stdout',
          output: _stdoutBytes,
          handler: _stdoutHandler,
        ),
        'wasi:cli/stderr@0.3.0.write-via-stream': (args) => _writeViaStream(
          args.single,
          name: 'stderr',
          output: _stderrBytes,
          handler: _stderrHandler,
        ),
        'wasi:cli/terminal-stdin@0.3.0.get-terminal-stdin': (_) => _none(),
        'wasi:cli/terminal-stdout@0.3.0.get-terminal-stdout': (_) => _none(),
        'wasi:cli/terminal-stderr@0.3.0.get-terminal-stderr': (_) => _none(),
      });

  WasmComponentValueData _environmentData() {
    return WasmComponentValueData(
      kind: WasmComponentValueDataKind.list,
      rawBytes: Uint8List(0),
      items: [
        for (final entry in env.entries)
          WasmComponentValueData(
            kind: WasmComponentValueDataKind.tuple,
            rawBytes: Uint8List(0),
            items: [_stringData(entry.key), _stringData(entry.value)],
          ),
      ],
    );
  }

  WasmComponentValueData _argumentsData() {
    return WasmComponentValueData(
      kind: WasmComponentValueDataKind.list,
      rawBytes: Uint8List(0),
      items: [for (final arg in args) _stringData(arg)],
    );
  }

  WasmComponentValueData _initialCwdData() {
    final cwd = initialCwd;
    if (cwd == null) {
      return _none();
    }
    return WasmComponentValueData(
      kind: WasmComponentValueDataKind.option,
      rawBytes: Uint8List(0),
      index: 1,
      label: 'some',
      isSome: true,
      associatedValue: _stringData(cwd),
    );
  }

  Never _exit(Object? status) {
    if (status is WasmComponentValueData &&
        status.kind == WasmComponentValueDataKind.result &&
        _isResultOk(status)) {
      throw const WASIPreview3Exit(0);
    }
    throw const WASIPreview3Exit(1);
  }

  Never _exitWithCode(Object? statusCode) {
    final code = switch (statusCode) {
      int() => statusCode,
      BigInt() => statusCode.toInt(),
      _ => 1,
    };
    throw WASIPreview3Exit(code & 0xff);
  }

  List<Object?> _readStdinViaStream() {
    final provided = _stdin;
    late final WASIComponentReadableStream<int> readable;
    if (provided != null) {
      readable = provided;
    } else {
      final stream = WASIComponentStream<int>('stdin');
      if (stdinData.isNotEmpty) {
        stream.writable.writeAll(stdinData);
      }
      stream.writable.close();
      readable = stream.readable;
    }
    final result = WASIComponentFuture<WasmComponentValueData>('stdin-result');
    result.writable.complete(_unitOk());
    return <Object?>[readable, result];
  }

  WASIComponentFuture<WasmComponentValueData> _writeViaStream(
    Object? streamValue, {
    required String name,
    required BytesBuilder output,
    required WASIPreview3CliOutputHandler? handler,
  }) {
    final stream = switch (streamValue) {
      WASIComponentReadableStream<Object?>() => streamValue,
      WASIComponentStream<Object?>() => streamValue.readable,
      _ => throw StateError(
        'Expected a readable WASI component byte stream, got $streamValue.',
      ),
    };
    final result = WASIComponentFuture<WasmComponentValueData>('$name-result');
    unawaited(_drainOutput(stream, output, handler, result));
    return result;
  }

  Future<void> _drainOutput(
    WASIComponentReadableStream<Object?> stream,
    BytesBuilder output,
    WASIPreview3CliOutputHandler? handler,
    WASIComponentFuture<WasmComponentValueData> result,
  ) async {
    try {
      try {
        while (true) {
          final chunk = await stream.readWhenAvailable(8192);
          if (chunk.isEmpty) {
            break;
          }
          final bytes = Uint8List.fromList(chunk.cast<int>());
          output.add(bytes);
          handler?.call(Uint8List.fromList(bytes));
        }
      } on WASIComponentAsyncEndpointStateError catch (error) {
        if (error.failure != WASIComponentAsyncEndpointFailure.dropped) {
          rethrow;
        }
      }
      if (result.writable.canComplete) {
        result.writable.complete(_unitOk());
      }
    } catch (_) {
      if (result.writable.canComplete) {
        result.writable.complete(_errorCode('io'));
      }
    }
  }
}

bool _isResultOk(WasmComponentValueData value) {
  bool? selected;
  void select(bool next, String source) {
    if (selected != null && selected != next) {
      throw StateError('Conflicting WASI CLI exit result $source.');
    }
    selected = next;
  }

  final isOk = value.isOk;
  if (isOk != null) {
    select(isOk, 'isOk');
  }
  final index = value.index;
  if (index != null) {
    if (index == 0) {
      select(true, 'index');
    } else if (index == 1) {
      select(false, 'index');
    } else {
      throw StateError('Invalid WASI CLI exit result index $index.');
    }
  }
  final label = value.label;
  if (label != null) {
    if (label == 'ok') {
      select(true, 'label');
    } else if (label == 'error') {
      select(false, 'label');
    } else {
      throw StateError('Invalid WASI CLI exit result label $label.');
    }
  }
  return selected ?? false;
}

WasmComponentValueData _stringData(String value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.string,
    rawBytes: Uint8List(0),
    string: value,
  );
}

WasmComponentValueData _none() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'none',
    isSome: false,
  );
}

WasmComponentValueData _unitOk() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'ok',
    isOk: true,
  );
}

WasmComponentValueData _errorCode(String label) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'error',
    isOk: false,
    associatedValue: WasmComponentValueData(
      kind: WasmComponentValueDataKind.enumeration,
      rawBytes: Uint8List(0),
      index: switch (label) {
        'illegal-byte-sequence' => 1,
        'pipe' => 2,
        _ => 0,
      },
      label: label,
    ),
  );
}
