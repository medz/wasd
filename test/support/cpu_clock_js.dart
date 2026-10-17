import 'dart:js_interop';
import 'dart:js_interop_unsafe';

JSObject? get _process => globalContext.getProperty<JSObject?>('process'.toJS);
String _method(int id) => id == 2 ? 'cpuUsage' : 'threadCpuUsage';

bool cpuClockAvailable(int id) {
  if (id != 2 && id != 3) return false;
  try {
    final process = _process;
    final method = _method(id).toJS;
    final callback = process?.getProperty<JSAny?>(method);
    if (callback == null || !callback.typeofEquals('function')) return false;
    process!.callMethodVarArgs<JSAny?>(method, const []);
    return true;
  } catch (_) {
    return false;
  }
}

int? hostCpuClockResolutionNanos(int id) => cpuClockAvailable(id) ? 1000 : null;

void pauseForCpuClockTest(Duration duration) {
  final shared = globalContext.getProperty<JSFunction>(
    'SharedArrayBuffer'.toJS,
  );
  final integers = globalContext.getProperty<JSFunction>('Int32Array'.toJS);
  final array = integers.callAsConstructor<JSObject>(
    shared.callAsConstructor<JSObject>(4.toJS),
  );
  globalContext.getProperty<JSObject>('Atomics'.toJS).callMethodVarArgs<JSAny?>(
    'wait'.toJS,
    [array, 0.toJS, 0.toJS, duration.inMilliseconds.toJS],
  );
}

void Function() overrideNodeCpuClockApi(
  int id,
  String mode, {
  void Function()? onCall,
}) {
  final process = _process!;
  final method = _method(id);
  final original = process.getProperty<JSAny?>(method.toJS);
  JSAny? callback() {
    onCall?.call();
    if (mode == 'throws') throw StateError('CPU API failed');
    if (mode == 'primitive') return 5.toJS;
    final result = JSObject();
    result['user'] = switch (mode) {
      'negative' => (-1).toJS,
      'fractional' => 0.5.toJS,
      'nan' => double.nan.toJS,
      'string' => '7'.toJS,
      'large' => 9007199254740991.toJS,
      'zero' => 0.toJS,
      _ => 7.toJS,
    };
    result['system'] = (mode == 'large' || mode == 'zero' ? 0 : 11).toJS;
    return result;
  }

  process[method] = switch (mode) {
    'missing' => null,
    'not-function' => 5.toJS,
    _ => callback.toJS,
  };
  return () {
    process[method] = original;
  };
}

void Function() hideNodeRequireForCpuClockTest() {
  final key = 'require'.toJS;
  final existed = globalContext.hasProperty(key).toDart;
  final original = globalContext.getProperty<JSAny?>(key);
  if (!globalContext.delete(key).toDart ||
      globalContext.getProperty<JSAny?>(key) != null) {
    throw StateError('Cannot hide global require.');
  }
  return () {
    if (existed) {
      globalContext['require'] = original;
    } else {
      globalContext.delete(key);
    }
  };
}
