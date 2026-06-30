import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../component/wit_adapter.dart';
import 'io.dart';

/// Exception used to terminate a WASI 0.2 command instance.
final class WASIPreview2Exit implements Exception {
  /// Creates a Preview2 command exit marker.
  const WASIPreview2Exit(this.statusCode);

  /// Host status code requested by the command.
  final int statusCode;

  /// Whether [statusCode] conventionally represents success.
  bool get isSuccess => statusCode == 0;

  @override
  String toString() => 'WASIPreview2Exit($statusCode)';
}

/// WASI 0.2 `wasi:cli` host imports.
final class WASIPreview2CliHost {
  /// Creates a CLI host import provider.
  WASIPreview2CliHost({
    WASIPreview2StreamsHost? streamsHost,
    List<String> args = const <String>[],
    Map<String, String> env = const <String, String>{},
    this.initialCwd,
    List<int> stdinData = const <int>[],
    WASIPreview2InputStream? stdin,
    WASIPreview2OutputStream? stdout,
    WASIPreview2OutputStream? stderr,
  }) : streamsHost = streamsHost ?? WASIPreview2StreamsHost(),
       args = List<String>.unmodifiable(args),
       env = Map<String, String>.unmodifiable(env),
       stdinData = Uint8List.fromList(stdinData),
       _stdin = stdin,
       _stdout = stdout,
       _stderr = stderr;

  /// Shared Preview2 streams host backing stdin, stdout, and stderr handles.
  final WASIPreview2StreamsHost streamsHost;

  /// Program arguments returned by `get-arguments`.
  final List<String> args;

  /// Environment pairs returned by `get-environment`.
  final Map<String, String> env;

  /// Initial current working directory returned by `initial-cwd`.
  final String? initialCwd;

  /// Bytes served by `stdin.get-stdin` when no custom stdin stream is passed.
  final Uint8List stdinData;

  final WASIPreview2InputStream? _stdin;
  final WASIPreview2OutputStream? _stdout;
  final WASIPreview2OutputStream? _stderr;

  /// Owned `input-stream` handle returned by `stdin.get-stdin`.
  late final int stdinHandle = streamsHost.insertInputStream(
    _stdin ?? WASIPreview2InputStream(bytes: stdinData, closed: true),
  );

  /// Owned `output-stream` handle returned by `stdout.get-stdout`.
  late final int stdoutHandle = streamsHost.insertOutputStream(_stdout);

  /// Owned `output-stream` handle returned by `stderr.get-stderr`.
  late final int stderrHandle = streamsHost.insertOutputStream(_stderr);

  /// Host stdout stream state.
  WASIPreview2OutputStream get stdoutStream =>
      streamsHost.outputStream(stdoutHandle);

  /// Host stderr stream state.
  WASIPreview2OutputStream get stderrStream =>
      streamsHost.outputStream(stderrHandle);

  /// Bytes written to stdout through the returned output-stream.
  Uint8List get stdoutBytes => Uint8List.fromList(stdoutStream.bytes);

  /// Bytes written to stderr through the returned output-stream.
  Uint8List get stderrBytes => Uint8List.fromList(stderrStream.bytes);

  /// Import callbacks keyed by canonical WIT adapter names.
  late final Map<String, WASIComponentWitAdapterCallback> imports =
      Map<String, WASIComponentWitAdapterCallback>.unmodifiable({
        'wasi:cli/environment@0.2.0.get-environment': (_) => _environmentData(),
        'wasi:cli/environment@0.2.0.get-arguments': (_) => _argumentsData(),
        'wasi:cli/environment@0.2.0.initial-cwd': (_) => _initialCwdData(),
        'wasi:cli/exit@0.2.0.exit': (args) => _exit(args.single),
        'wasi:cli/stdin@0.2.0.get-stdin': (_) => stdinHandle,
        'wasi:cli/stdout@0.2.0.get-stdout': (_) => stdoutHandle,
        'wasi:cli/stderr@0.2.0.get-stderr': (_) => stderrHandle,
        'wasi:cli/terminal-stdin@0.2.0.get-terminal-stdin': (_) => _none(),
        'wasi:cli/terminal-stdout@0.2.0.get-terminal-stdout': (_) => _none(),
        'wasi:cli/terminal-stderr@0.2.0.get-terminal-stderr': (_) => _none(),
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
    throw WASIPreview2Exit(_isResultOk(status) ? 0 : 1);
  }
}

bool _isResultOk(Object? value) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.result) {
    return false;
  }
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
