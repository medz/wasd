@TestOn('browser || node')
library;

import 'dart:collection';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:test/test.dart';
import 'package:wasd/wasm.dart';

import 'support/wasm_fixtures.dart';

void main() {
  test('a failed async result encoding rejects the export Future', () async {
    final marker = StateError('async result encoding failed');
    final stack = StackTrace.fromString('async-result-encoding-stack');
    var calls = 0;
    final runtime = await WebAssembly.instantiate(
      wasiStartModuleBytes().buffer,
      {
        'wasi_snapshot_preview1': {
          'proc_exit': ImportExportKind.function((_) async {
            calls++;
            return _UnencodableList(marker, stack);
          }),
        },
      },
    );
    final start =
        (runtime.instance.exports['_start']! as FunctionImportExportValue).ref;
    try {
      await (start(const []) as Future<Object?>);
      fail('Expected the original result encoding error.');
    } catch (error, sourceStack) {
      expect(error, same(marker));
      expect('$sourceStack', contains('async-result-encoding-stack'));
    }
    expect(calls, 1);
  });

  // Mutate one capability at a time and restore it before the next test.
  for (final capability in ['Suspending', 'promising', 'JSTag']) {
    test(
      'missing $capability rejects only actual asynchronous imports',
      () async {
        final assembly = globalContext['WebAssembly'] as JSObject;
        final descriptor = _getOwnPropertyDescriptor(assembly, capability.toJS);
        // JSTag is configurable but not writable; assignment would leave it set.
        expect(assembly.delete(capability.toJS).toDart, isTrue);
        expect(assembly[capability], isNull);
        try {
          final unused = {
            'unused': {
              'callback': ImportExportKind.function((_) async => null),
            },
          };
          final sync = (await WebAssembly.instantiate(
            simpleAddModuleBytes().buffer,
            unused,
          )).instance;
          final add = (sync.exports['add']! as FunctionImportExportValue).ref;
          expect(add([20, 22]), 42);

          final bytes = wasiStartModuleBytes();
          final module = Module(bytes.buffer);
          var calls = 0;
          final imports = {
            'wasi_snapshot_preview1': {
              'proc_exit': ImportExportKind.function((_) async {
                calls++;
                return null;
              }),
            },
          };
          for (final create in <Object? Function()>[
            () => Instance(module, imports),
            () => WebAssembly.instantiateModule(module, imports),
            () => WebAssembly.instantiate(bytes.buffer, imports),
            () =>
                WebAssembly.instantiateStreaming(Stream.value(bytes), imports),
          ]) {
            await expectLater(
              Future<Object?>.sync(create),
              throwsA(isA<UnsupportedError>()),
            );
            expect(calls, 0);
          }
        } finally {
          _defineProperty(assembly, capability.toJS, descriptor);
        }
      },
    );
  }
}

final class _UnencodableList extends ListBase<Object?> {
  _UnencodableList(this.error, this.stack);

  final Object error;
  final StackTrace stack;

  @override
  int get length => Error.throwWithStackTrace(error, stack);

  @override
  set length(int value) => throw UnsupportedError('Immutable test result.');

  @override
  Object? operator [](int index) => null;

  @override
  void operator []=(int index, Object? value) =>
      throw UnsupportedError('Immutable test result.');
}

@JS('Object.getOwnPropertyDescriptor')
external JSObject _getOwnPropertyDescriptor(JSObject object, JSString property);

@JS('Object.defineProperty')
external JSObject _defineProperty(
  JSObject object,
  JSString property,
  JSObject descriptor,
);
