import 'dart:js_interop';
import 'dart:js_interop_unsafe';

final class NodeStdioSpy {
  NodeStdioSpy._({
    required JSObject stdout,
    required JSObject stderr,
    required JSAny? originalStdoutWrite,
    required JSAny? originalStderrWrite,
  }) : _stdout = stdout,
       _stderr = stderr,
       _originalStdoutWrite = originalStdoutWrite,
       _originalStderrWrite = originalStderrWrite;

  final JSObject _stdout;
  final JSObject _stderr;
  final JSAny? _originalStdoutWrite;
  final JSAny? _originalStderrWrite;
  final List<String> _stdoutChunks = <String>[];
  final List<String> _stderrChunks = <String>[];

  List<String> get stdout => List<String>.unmodifiable(_stdoutChunks);

  List<String> get stderr => List<String>.unmodifiable(_stderrChunks);

  void restore() {
    _stdout['write'] = _originalStdoutWrite;
    _stderr['write'] = _originalStderrWrite;
  }
}

NodeStdioSpy installNodeStdioSpy() {
  final process = globalContext.getProperty<JSAny?>('process'.toJS);
  if (process == null || !process.isA<JSObject>()) {
    throw StateError('Node process is unavailable.');
  }
  final processObject = process as JSObject;
  final stdout = processObject.getProperty<JSObject?>('stdout'.toJS);
  final stderr = processObject.getProperty<JSObject?>('stderr'.toJS);
  if (stdout == null || stderr == null) {
    throw StateError('Node stdio streams are unavailable.');
  }
  final spy = NodeStdioSpy._(
    stdout: stdout,
    stderr: stderr,
    originalStdoutWrite: stdout.getProperty<JSAny?>('write'.toJS),
    originalStderrWrite: stderr.getProperty<JSAny?>('write'.toJS),
  );

  JSAny stdoutWrite(JSAny? chunk) {
    spy._stdoutChunks.add(_decodeNodeChunk(chunk));
    return true.toJS;
  }

  JSAny stderrWrite(JSAny? chunk) {
    spy._stderrChunks.add(_decodeNodeChunk(chunk));
    return true.toJS;
  }

  stdout['write'] = stdoutWrite.toJS;
  stderr['write'] = stderrWrite.toJS;
  return spy;
}

String _decodeNodeChunk(JSAny? chunk) {
  if (chunk == null) {
    return '';
  }
  if (chunk.isA<JSString>()) {
    return (chunk as JSString).toDart;
  }
  final bufferModule = _requireNodeBuiltin('node:buffer');
  final buffer = bufferModule?.getProperty<JSObject?>('Buffer'.toJS);
  if (buffer == null) {
    return _jsString(chunk).toDart;
  }
  final from = buffer.callMethodVarArgs<JSAny?>('from'.toJS, [chunk]);
  if (from == null || !from.isA<JSObject>()) {
    return _jsString(chunk).toDart;
  }
  final decoded = (from as JSObject).callMethodVarArgs<JSAny?>(
    'toString'.toJS,
    ['utf8'.toJS],
  );
  return _jsString(decoded).toDart;
}

JSObject? _requireNodeBuiltin(String name) {
  final require = globalContext.getProperty<JSAny?>('require'.toJS);
  if (require == null) {
    return null;
  }
  final module = _jsRequire(name.toJS);
  if (module case final JSObject object) {
    return object;
  }
  return null;
}

@JS('require')
external JSAny _jsRequire(JSString module);

@JS('String')
external JSString _jsString(JSAny? value);
