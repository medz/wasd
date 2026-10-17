@JS()
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../../global.dart' as wasm;
import '../../instance.dart' as wasm;
import '../../memory.dart' as wasm;
import '../../module.dart' as wasm;
import '../../table.dart' as wasm;
import '../../value.dart';
import 'errors.dart' as js_errors;
import 'exception.dart' as js_exception;
import 'global.dart' as js_global;
import 'memory.dart' as js_memory;
import 'module.dart' as js_module;
import 'table.dart' as js_table;
import 'tag.dart' as js_tag;
import 'value_codec.dart' as codec;

class Instance implements wasm.Instance {
  factory Instance(wasm.Module module, [wasm.Imports imports = const {}]) {
    final asynchronous = hasAsyncHostImports(module, imports);
    return Instance.fromHost(
      module,
      _instantiate(
        (module as js_module.Module).host,
        createImportObject(imports, asynchronous: asynchronous),
      ),
      asynchronous: asynchronous,
    );
  }

  Instance.fromHost(this._module, this.host, {bool asynchronous = false})
    : _asynchronous = asynchronous;

  final wasm.Module _module;
  final bool _asynchronous;
  final JSImportInstance host;

  @override
  late final wasm.Exports exports = _createExports(
    _module,
    host.exports,
    _asynchronous,
  );

  static JSImportInstance _instantiate(
    js_module.JSImportModule jsModule,
    JSObject imports,
  ) {
    try {
      return JSImportInstance(jsModule, imports);
    } catch (e, st) {
      translateAsyncError(e, st);
    }
  }
}

wasm.Exports _createExports(
  wasm.Module module,
  JSObject exportObject,
  bool asynchronous,
) {
  final result = <String, wasm.ExportValue>{};
  for (final descriptor in wasm.Module.exports(module)) {
    final name = descriptor.name;
    final raw = exportObject[name];
    if (raw == null) continue;
    result[name] = switch (descriptor.kind) {
      wasm.ImportExportKind.function => wasm.ImportExportKind.function(
        asynchronous
            ? _wrapAsyncFunction(raw as JSFunction)
            : _wrapFunction(raw as JSFunction),
      ),
      wasm.ImportExportKind.global => wasm.ImportExportKind.global(
        _ExportGlobal(raw as js_global.JSGlobal),
      ),
      wasm.ImportExportKind.memory => wasm.ImportExportKind.memory(
        _ExportMemory(raw as js_memory.JSMemory),
      ),
      wasm.ImportExportKind.table => wasm.ImportExportKind.table(
        _ExportTable(raw as js_table.JSTable),
      ),
      wasm.ImportExportKind.tag => wasm.ImportExportKind.tag(
        js_tag.Tag.fromHost(
          raw as js_tag.JSTag,
          () => (module as js_module.Module).exportedTagType(name),
        ),
      ),
    };
  }
  return result;
}

bool hasAsyncBindings(wasm.Imports imports) => imports.values.any(
  (bindings) => bindings.values.any(
    (value) => value is wasm.FunctionImportExportValue && _isAsync(value.ref),
  ),
);

bool hasAsyncHostImports(wasm.Module module, wasm.Imports imports) {
  if (!hasAsyncBindings(imports)) return false;
  return wasm.Module.imports(module).any((descriptor) {
    if (descriptor.kind != wasm.ImportExportKind.function) return false;
    final binding = imports[descriptor.module]?[descriptor.name];
    return binding is wasm.FunctionImportExportValue && _isAsync(binding.ref);
  });
}

// A synchronous function inferred as Never is also a subtype of Future<...>.
bool _isAsync(wasm.WasmFunction function) =>
    function is Future<Object?> Function(List<Object?>) &&
    function is! Never Function(List<Object?>);

JSObject createImportObject(wasm.Imports imports, {bool asynchronous = false}) {
  if (asynchronous &&
      (_suspendingConstructor == null ||
          _promisingConstructor == null ||
          !js_exception.supportsHostThrow)) {
    throw UnsupportedError(
      'Asynchronous host imports require WebAssembly.Suspending, '
      'WebAssembly.promising and WebAssembly.JSTag.',
    );
  }
  final root = JSObject();
  for (final moduleEntry in imports.entries) {
    final moduleObject = JSObject();
    for (final importEntry in moduleEntry.value.entries) {
      moduleObject[importEntry.key] = _encodeImport(
        importEntry.value,
        asynchronous,
      );
    }
    root[moduleEntry.key] = moduleObject;
  }
  return root;
}

JSAny? _encodeImport(
  wasm.ImportValue value,
  bool asynchronous,
) => switch (value) {
  wasm.IntImportValue(:final ref) => ref.toJS,
  wasm.FunctionImportExportValue(:final ref) => _hostFuncToJS(
    ref,
    asynchronous,
  ),
  wasm.GlobalImportExportValue(:final ref) => (ref as js_global.Global).host,
  wasm.MemoryImportExportValue(:final ref) => (ref as js_memory.Memory).host,
  wasm.TableImportExportValue(:final ref) => (ref as js_table.Table).host,
  wasm.TagImportExportValue(:final ref) => (ref as js_tag.Tag).host,
};

wasm.WasmFunction _wrapAsyncFunction(JSFunction raw) {
  // promising only accepts a raw Wasm function. Cache one wrapper per export.
  final promising = _jsPromising(raw);
  return (List<Object?> args) async {
    try {
      final jsArgs = <JSAny?>[for (final arg in args) _encodeHostValue(arg)];
      final promise = (promising as JSObject)
          .callMethodVarArgs<JSPromise<JSAny?>>('call'.toJS, [null, ...jsArgs]);
      return _decodeHostArg(await promise.toDart);
    } catch (error, stack) {
      translateAsyncError(error, stack);
    }
  };
}

Never translateAsyncError(Object error, StackTrace stack) {
  // ignore: invalid_runtime_check_with_js_interop_types
  if (error is JSObject) {
    final original = _hostErrors.get(error);
    if (original != null) {
      final (cause, sourceStack) = original.toDart as (Object, StackTrace);
      Error.throwWithStackTrace(cause, sourceStack);
    }
  }
  js_errors.translateJsError(error, stack);
}

wasm.WasmFunction _wrapFunction(JSFunction jsFunc) => (List<Object?> args) {
  try {
    final jsArgs = <JSAny?>[for (final arg in args) _encodeHostValue(arg)];
    return _decodeHostArg(
      (jsFunc as JSObject).callMethodVarArgs<JSAny?>('call'.toJS, [
        null,
        ...jsArgs,
      ]),
    );
  } catch (e, st) {
    js_errors.translateJsError(e, st);
  }
};

/// Converts a [wasm.WasmFunction] host function to a [JSFunction] for use as
/// a WebAssembly import.
///
/// WebAssembly calls the import with exactly N positional arguments matching
/// the wasm function type. Our bridge has a fixed 8-param signature; the extra
/// params arrive as JS `undefined` (Dart `null`). Trailing nulls are trimmed
/// to recover the actual argument list.
///
/// Limitation: this heuristic is incorrect for host functions whose final
/// parameter is a nullable reference type (externref / funcref). Numeric types
/// (i32, i64, f32, f64) are always non-null and are unaffected.
JSAny _hostFuncToJS(wasm.WasmFunction hostFn, bool asynchronous) {
  final suspending = asynchronous && _isAsync(hostFn);
  JSAny? bridge([
    JSAny? a,
    JSAny? b,
    JSAny? c,
    JSAny? d,
    JSAny? e,
    JSAny? f,
    JSAny? g,
    JSAny? h,
    JSAny? i,
    JSAny? j,
    JSAny? k,
    JSAny? l,
    JSAny? m,
    JSAny? n,
    JSAny? o,
    JSAny? p,
  ]) {
    final all = [a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p];
    final last = all.lastIndexWhere((x) => x != null);
    final args = all
        .sublist(0, last + 1)
        .map(_decodeHostArg)
        .toList(growable: false);
    try {
      final result = hostFn(args);
      if (result is Future) {
        if (suspending) return _hostPromise(result);
        result.ignore();
        throw UnsupportedError(
          'A host callback returning a Future must declare a Future return '
          'type. Adapt it with (_) async => await callback(...).',
        );
      }
      return _encodeHostValue(result);
    } on js_exception.Exception catch (error) {
      js_exception.throwToHost(error);
    } catch (error, stack) {
      if (asynchronous) js_exception.throwValueToHost(_hostError(error, stack));
      rethrow;
    }
  }

  return suspending ? _JSSuspending(bridge.toJS) : bridge.toJS;
}

JSPromise<JSAny?> _hostPromise(Future<Object?> future) => JSPromise<JSAny?>(
  (JSFunction resolve, JSFunction reject) {
    future.then<void>(
      (value) {
        try {
          resolve.callAsFunction(null, _encodeHostValue(value));
        } catch (error, stack) {
          reject.callAsFunction(null, _hostError(error, stack));
        }
      },
      onError: (Object error, StackTrace stack) {
        reject.callAsFunction(null, _hostError(error, stack));
      },
    );
  }.toJS,
);

JSObject _hostError(Object error, StackTrace stack) {
  if (error is js_exception.Exception) return error.host;
  final carrier = JSObject();
  _hostErrors.set(carrier, (error, stack).toJSBox);
  return carrier;
}

final _hostErrors = _HostErrors();

@JS('WeakMap')
extension type _HostErrors._(JSObject _) implements JSObject {
  external factory _HostErrors();

  external JSBoxedDartObject? get(JSObject carrier);
  external void set(JSObject carrier, JSBoxedDartObject error);
}

@JS('WebAssembly.Suspending')
external JSFunction? get _suspendingConstructor;

@JS('WebAssembly.promising')
external JSFunction? get _promisingConstructor;

@JS('WebAssembly.promising')
external JSFunction _jsPromising(JSFunction function);

@JS('WebAssembly.Suspending')
extension type _JSSuspending._(JSObject _) implements JSObject {
  external factory _JSSuspending(JSFunction function);
}

JSAny? _encodeHostValue(Object? value) => switch (value) {
  BigInt() => codec.jsBigInt(value.toString().toJS),
  List() => value.map(_encodeHostValue).toList(growable: false).toJS,
  _ => value.jsify(),
};

Object? _decodeHostArg(JSAny? value) {
  if (value == null) {
    return null;
  }
  if (value.typeofEquals('bigint')) {
    return BigInt.parse(_jsString(value).toDart);
  }
  if (value.isA<JSArray<JSAny?>>()) {
    return (value as JSArray<JSAny?>).toDart
        .map(_decodeHostArg)
        .toList(growable: false);
  }
  return value.dartify();
}

@JS('String')
external JSString _jsString(JSAny? value);

class _ExportGlobal implements wasm.Global<ExternRef, Object?> {
  _ExportGlobal(this._host);

  final js_global.JSGlobal _host;

  @override
  Object? get value => _host.value?.dartify();

  @override
  set value(Object? value) {
    _host.value = value.jsify();
  }
}

class _ExportMemory implements wasm.Memory {
  _ExportMemory(this._host);

  final js_memory.JSMemory _host;

  @override
  ByteBuffer get buffer => _host.buffer.toDart;

  @override
  int grow(int delta) => _host.grow(delta);
}

class _ExportTable implements wasm.Table<ExternRef, Object?> {
  _ExportTable(this._host);

  final js_table.JSTable _host;

  @override
  int get length => _host.length;

  @override
  Object? get(int index) => _host.get(index)?.dartify();

  @override
  void set(int index, Object? value) => _host.set(index, value.jsify());

  @override
  int grow(int delta, [Object? value]) {
    if (value == null) return _host.grow(delta);
    return _host.grow(delta, value.jsify());
  }
}

@JS('WebAssembly.Instance')
extension type JSImportInstance._(JSObject _) implements JSObject {
  external factory JSImportInstance(
    js_module.JSImportModule module, [
    JSObject? imports,
  ]);

  external JSObject get exports;
}
