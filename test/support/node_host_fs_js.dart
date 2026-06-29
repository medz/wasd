import 'dart:js_interop';
import 'dart:js_interop_unsafe';

final class NodeHostTemp {
  NodeHostTemp._(this.path, this._fs, this._path);

  final String path;
  final JSObject _fs;
  final JSObject _path;

  void writeFile(String relativePath, String content) {
    _fs.callMethodVarArgs<JSAny?>('writeFileSync'.toJS, [
      _join(relativePath).toJS,
      content.toJS,
    ]);
  }

  void createDirectory(String relativePath) {
    final options = JSObject()..['recursive'] = true.toJS;
    _fs.callMethodVarArgs<JSAny?>('mkdirSync'.toJS, [
      _join(relativePath).toJS,
      options,
    ]);
  }

  String readFile(String relativePath) {
    final result = _fs.callMethodVarArgs<JSAny?>('readFileSync'.toJS, [
      _join(relativePath).toJS,
      'utf8'.toJS,
    ]);
    return _jsString(result).toDart;
  }

  bool fileExists(String relativePath) => _entryMatches(relativePath, 'isFile');

  bool directoryExists(String relativePath) =>
      _entryMatches(relativePath, 'isDirectory');

  void delete() {
    final options = JSObject()
      ..['recursive'] = true.toJS
      ..['force'] = true.toJS;
    _fs.callMethodVarArgs<JSAny?>('rmSync'.toJS, [path.toJS, options]);
  }

  bool _entryMatches(String relativePath, String method) {
    try {
      final stat = _fs.callMethodVarArgs<JSAny?>('lstatSync'.toJS, [
        _join(relativePath).toJS,
      ]);
      if (stat case final JSObject object) {
        final result = object.callMethodVarArgs<JSAny?>(method.toJS, const []);
        return _jsString(result).toDart == 'true';
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  String _join(String relativePath) {
    final result = _path.callMethodVarArgs<JSAny?>('join'.toJS, [
      path.toJS,
      relativePath.toJS,
    ]);
    return _jsString(result).toDart;
  }
}

NodeHostTemp? createNodeHostTemp(String prefix) {
  final fs = _requireNodeBuiltin('node:fs');
  final os = _requireNodeBuiltin('node:os');
  final path = _requireNodeBuiltin('node:path');
  if (fs == null || os == null || path == null) {
    return null;
  }
  final tmpdir = _jsString(
    os.callMethodVarArgs<JSAny?>('tmpdir'.toJS, const []),
  ).toDart;
  final tempPrefix = _jsString(
    path.callMethodVarArgs<JSAny?>('join'.toJS, [tmpdir.toJS, prefix.toJS]),
  ).toDart;
  final tempPath = _jsString(
    fs.callMethodVarArgs<JSAny?>('mkdtempSync'.toJS, [tempPrefix.toJS]),
  ).toDart;
  return NodeHostTemp._(tempPath, fs, path);
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
