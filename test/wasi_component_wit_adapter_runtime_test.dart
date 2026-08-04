import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/async_values.dart';
import 'package:wasd/src/wasi/component/wit_adapter.dart';
import 'package:wasd/src/wasi/component/wit_document.dart';
import 'package:wasd/src/wasi/preview3/component_host.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';

void main() {
  group('Preview3 WIT adapter runtime composites', () {
    test('validates stream endpoints inside records', () {
      final program = _bindRuntimeCompositeWorld(
        accept: (args) => args.single,
        collect: (_) => _runtimeList(const <Object?>[]),
      );
      final stream = WASIComponentStream<int>('record-stream');
      final record = _runtimeRecord(<Object?>[stream.readable, _u32(7)]);

      final result =
          program.invokeImport('runtime.accept', <Object?>[record])
              as WasmComponentValueData;

      expect(result, same(record));
      expect(result.items, isEmpty);
      expect(result.itemValues, hasLength(2));
      expect(result.itemValues.first, same(stream.readable));
      expect((result.itemValues.last as WasmComponentValueData).integer, 7);
    });

    test('validates future endpoints inside lists', () {
      final first = WASIComponentFuture<int>('first-future');
      final second = WASIComponentFuture<int>('second-future');
      final futures = _runtimeList(<Object?>[first.readable, second.readable]);
      final program = _bindRuntimeCompositeWorld(
        accept: (args) => args.single,
        collect: (_) => futures,
      );

      final result =
          program.invokeImport('runtime.collect', const <Object?>[])
              as WasmComponentValueData;

      expect(result, same(futures));
      expect(result.items, isEmpty);
      expect(result.itemValues, <Object?>[
        same(first.readable),
        same(second.readable),
      ]);
    });
  });
}

WASIComponentWitAdapterProgram _bindRuntimeCompositeWorld({
  required WASIComponentWitAdapterCallback accept,
  required WASIComponentWitAdapterCallback collect,
}) {
  const source = '''
package acme:runtime@0.3.0;

interface runtime {
  record transfer {
    source: stream<u8>,
    sequence: u32,
  }

  accept: func(value: transfer) -> transfer;
  collect: func() -> list<future<u32>>;
}

world command {
  import runtime;
}
''';
  final plan = WASIPreview3ComponentHost().prepareWitWorld(
    WASIComponentWitDocument.parse(source),
    worldName: 'command',
  );
  expect(plan.canBindAdapters, isTrue, reason: plan.bindingErrors.toString());
  return plan.bindAdapters(
    imports: <String, WASIComponentWitAdapterCallback>{
      'runtime.accept': accept,
      'runtime.collect': collect,
    },
  );
}

WasmComponentValueData _runtimeRecord(List<Object?> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.record,
    rawBytes: Uint8List(0),
    runtimeItems: List<Object?>.unmodifiable(items),
  );
}

WasmComponentValueData _runtimeList(List<Object?> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    runtimeItems: List<Object?>.unmodifiable(items),
  );
}

WasmComponentValueData _u32(int value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.integer,
    rawBytes: Uint8List(0),
    integer: value,
  );
}
