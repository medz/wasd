import 'dart:js_interop';
import 'dart:js_interop_unsafe';

bool get isNodeJsRuntime {
  final process = globalContext.getProperty<JSAny?>('process'.toJS);
  if (process == null) {
    return false;
  }
  final versions = (process as JSObject).getProperty<JSAny?>('versions'.toJS);
  if (versions == null) {
    return false;
  }
  return (versions as JSObject).getProperty<JSAny?>('node'.toJS) != null;
}
