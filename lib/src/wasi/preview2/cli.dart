import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../../wasm/host_control_flow.dart';
import '../component/wit_adapter.dart';
import 'io.dart';

/// Host-owned WASI 0.2 terminal input marker.
final class WASIPreview2TerminalInput {
  /// Creates a terminal input marker.
  const WASIPreview2TerminalInput();
}

/// Host-owned WASI 0.2 terminal output marker.
final class WASIPreview2TerminalOutput {
  /// Creates a terminal output marker.
  const WASIPreview2TerminalOutput();
}

/// Exception used to terminate a WASI 0.2 command instance.
final class WASIPreview2Exit implements WasmHostControlFlowException {
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
    bool terminalStdin = false,
    bool terminalStdout = false,
    bool terminalStderr = false,
  }) : streamsHost = streamsHost ?? WASIPreview2StreamsHost(),
       args = List<String>.unmodifiable(args),
       env = Map<String, String>.unmodifiable(env),
       stdinData = Uint8List.fromList(stdinData),
       _stdin = stdin,
       _stdout = stdout,
       _stderr = stderr,
       _terminalStdin = terminalStdin,
       _terminalStdout = terminalStdout,
       _terminalStderr = terminalStderr;

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
  final bool _terminalStdin;
  final bool _terminalStdout;
  final bool _terminalStderr;
  late final WASIPreview2InputStream _stdinStream =
      _stdin ?? WASIPreview2InputStream(bytes: stdinData, closed: true);
  late final WASIPreview2OutputStream _stdoutStream =
      _stdout ?? WASIPreview2OutputStream();
  late final WASIPreview2OutputStream _stderrStream =
      _stderr ?? WASIPreview2OutputStream();

  late final _terminalInputType = streamsHost.table
      .defineType<WASIPreview2TerminalInput>(
        'wasi:cli/terminal-input@0.2.0.terminal-input',
      );
  late final _terminalOutputType = streamsHost.table
      .defineType<WASIPreview2TerminalOutput>(
        'wasi:cli/terminal-output@0.2.0.terminal-output',
      );

  /// Host-owned `input-stream` anchor used for stdin diagnostics.
  late final int stdinHandle = streamsHost.insertPersistentInputStream(
    _stdinStream,
  );

  /// Host-owned `output-stream` anchor used for stdout diagnostics.
  late final int stdoutHandle = streamsHost.insertPersistentOutputStream(
    _stdoutStream,
  );

  /// Host-owned `output-stream` anchor used for stderr diagnostics.
  late final int stderrHandle = streamsHost.insertPersistentOutputStream(
    _stderrStream,
  );

  /// Owned `terminal-input` handle returned when stdin is a terminal.
  late final int? terminalStdinHandle = _terminalStdin
      ? streamsHost.table.insertPersistent<WASIPreview2TerminalInput>(
          _terminalInputType,
          const WASIPreview2TerminalInput(),
        )
      : null;

  /// Owned `terminal-output` handle returned when stdout is a terminal.
  late final int? terminalStdoutHandle = _terminalStdout
      ? streamsHost.table.insertPersistent<WASIPreview2TerminalOutput>(
          _terminalOutputType,
          const WASIPreview2TerminalOutput(),
        )
      : null;

  /// Owned `terminal-output` handle returned when stderr is a terminal.
  late final int? terminalStderrHandle = _terminalStderr
      ? streamsHost.table.insertPersistent<WASIPreview2TerminalOutput>(
          _terminalOutputType,
          const WASIPreview2TerminalOutput(),
        )
      : null;

  /// Host stdout stream state.
  WASIPreview2OutputStream get stdoutStream => _stdoutStream;

  /// Host stderr stream state.
  WASIPreview2OutputStream get stderrStream => _stderrStream;

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
        'wasi:cli/stdin@0.2.0.get-stdin': (_) =>
            streamsHost.insertInputStream(_stdinStream),
        'wasi:cli/stdout@0.2.0.get-stdout': (_) =>
            streamsHost.insertOutputStream(_stdoutStream),
        'wasi:cli/stderr@0.2.0.get-stderr': (_) =>
            streamsHost.insertOutputStream(_stderrStream),
        'wasi:cli/terminal-stdin@0.2.0.get-terminal-stdin': (_) =>
            _optionalHandle(_newTerminalInputHandle()),
        'wasi:cli/terminal-stdout@0.2.0.get-terminal-stdout': (_) =>
            _optionalHandle(_newTerminalOutputHandle(_terminalStdout)),
        'wasi:cli/terminal-stderr@0.2.0.get-terminal-stderr': (_) =>
            _optionalHandle(_newTerminalOutputHandle(_terminalStderr)),
      });

  int? _newTerminalInputHandle() {
    return !_terminalStdin
        ? null
        : streamsHost.table.insert<WASIPreview2TerminalInput>(
            _terminalInputType,
            const WASIPreview2TerminalInput(),
          );
  }

  int? _newTerminalOutputHandle(bool enabled) {
    return !enabled
        ? null
        : streamsHost.table.insert<WASIPreview2TerminalOutput>(
            _terminalOutputType,
            const WASIPreview2TerminalOutput(),
          );
  }

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

WasmComponentValueData _optionalHandle(int? handle) {
  if (handle == null) {
    return _none();
  }
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'some',
    isSome: true,
    associatedValue: WasmComponentValueData(
      kind: WasmComponentValueDataKind.integer,
      rawBytes: Uint8List(0),
      integer: handle,
    ),
  );
}
