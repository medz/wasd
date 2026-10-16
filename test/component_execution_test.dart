@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/preview2/component_runner.dart';
import 'package:wasd/wasi.dart';
import 'package:wasd/wasm.dart';

void main() {
  test('initialization is idempotent and preserves guest state', () {
    final component = _counterComponent();
    expect(component.validate(), isEmpty);
    final runtime = WASIComponentNativeRuntime.component(
      component: component,
      host: WASIComponentHost(),
    );

    runtime.initialize();
    expect(runtime.invokeExportSynchronously('next', []), 1);
    runtime.initialize();
    expect(runtime.invokeExportSynchronously('next', []), 2);

    final other = WASIComponentNativeRuntime.component(
      component: component,
      host: WASIComponentHost(),
    );
    expect(other.invokeExportSynchronously('next', []), 1);
    expect(runtime.invokeExportSynchronously('next', []), 3);
  });

  test('missing exports report a lookup failure before invocation', () {
    final runtime = WASIComponentNativeRuntime.component(
      component: _counterComponent(),
      host: WASIComponentHost(),
    );

    expect(
      () => runtime.invokeExportSynchronously('missing', []),
      throwsA(
        isA<WASIPreview2ComponentExecutionException>().having(
          (error) => error.message,
          'message',
          contains('export `missing` not found'),
        ),
      ),
    );
    expect(runtime.invokeExportSynchronously('next', []), 1);
  });

  test('generic execution uses explicitly supplied import callbacks', () {
    final runtime = WASIComponentNativeRuntime.component(
      component: _callbackComponent(),
      host: WASIComponentHost(),
      imports: {'source': (_) => 42},
    );

    expect(runtime.invokeExportSynchronously('call', []), 42);
  });

  test('generic execution does not supply implicit WASI imports', () {
    final runtime = WASIComponentNativeRuntime.component(
      component: _callbackComponent(),
      host: WASIComponentHost(),
    );

    expect(
      runtime.initialize,
      throwsA(
        isA<WASIPreview2ComponentExecutionException>().having(
          (error) => error.message,
          'message',
          contains('import callback `source`'),
        ),
      ),
    );
  });

  test('synchronous invocation rejects an asynchronous callback', () {
    final runtime = WASIComponentNativeRuntime.component(
      component: _callbackComponent(),
      host: WASIComponentHost(),
      imports: {'source': (_) => Future<int>.value(42)},
    );

    expect(
      () => runtime.invokeExportSynchronously('call', []),
      throwsA(
        isA<WASIPreview2ComponentExecutionException>().having(
          (error) => error.message,
          'message',
          contains('async-only'),
        ),
      ),
    );
  });

  test('the caller owns the resource scope across invocations', () async {
    final host = WASIComponentHost();
    final type = host.table.defineType<String>('test');
    final runtime = WASIComponentNativeRuntime.component(
      component: _callbackComponent(),
      host: host,
      imports: {'source': (_) => host.table.insert(type, 'alive')},
    );

    await host.table.runScoped(() {
      final first = runtime.invokeExportSynchronously('call', []) as int;
      final second = runtime.invokeExportSynchronously('call', []) as int;
      expect(host.table.get(type, first), 'alive');
      expect(host.table.get(type, second), 'alive');
      expect(host.table.activeCount, 2);
    });
    expect(host.table.activeCount, 0);
  });

  test('generic construction keeps the existing WASI profiles separate', () {
    final component = _component([
      // canon context.get i32 0 is legal outside the Preview2 profile.
      _section(8, [1, 0x0a, 0x7f, 0]),
    ]);
    expect(component.validate(), isEmpty);

    WASIComponentNativeRuntime.component(
      component: component,
      host: WASIComponentHost(),
    ).initialize();
    WASIComponentNativeRuntime.preview3(
      component: component,
      host: WASIPreview3ComponentHost(),
    ).initialize();
    expect(
      WASIComponentNativeRuntime.preview2(
        component: component,
        host: WASIPreview2ComponentHost(),
      ).initialize,
      throwsA(
        isA<WASIPreview2ComponentExecutionException>().having(
          (error) => error.message,
          'message',
          contains('Preview2 does not include context'),
        ),
      ),
    );
  });
}

WasmComponent _callbackComponent() => _component([
  _section(7, [1, 0x40, 0, 0, 0x79]),
  _section(10, [1, 0, ..._name('source'), 1, 0]),
  _section(11, [1, 0, ..._name('call'), 1, 0, 0]),
]);

WasmComponent _counterComponent() {
  // One guest i32 global; next increments it and returns the new value.
  final core = [
    0,
    97,
    115,
    109,
    1,
    0,
    0,
    0,
    ..._section(1, [1, 0x60, 0, 1, 0x7f]),
    ..._section(3, [1, 0]),
    ..._section(6, [1, 0x7f, 1, 0x41, 0, 0x0b]),
    ..._section(7, [1, ..._name('next'), 0, 0]),
    ..._section(10, [1, 11, 0, 0x23, 0, 0x41, 1, 0x6a, 0x24, 0, 0x23, 0, 0x0b]),
  ];
  return _component([
    _section(1, core),
    _section(2, [1, 0, 0, 0]),
    _section(6, [1, 0, 0, 1, 0, ..._name('next')]),
    _section(7, [1, 0x40, 0, 0, 0x79]),
    _section(8, [1, 0, 0, 0, 0, 0]),
    _section(11, [1, 0, ..._name('next'), 1, 0, 0]),
  ]);
}

WasmComponent _component(List<List<int>> sections) => WasmComponent.decode(
  Uint8List.fromList([
    0,
    97,
    115,
    109,
    13,
    0,
    1,
    0,
    for (final section in sections) ...section,
  ]),
);

// These small test sections and ASCII names fit in one unsigned LEB byte.
List<int> _section(int id, List<int> payload) => [
  id,
  payload.length,
  ...payload,
];
List<int> _name(String name) => [name.length, ...name.codeUnits];
