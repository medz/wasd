import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/async_values.dart';
import 'package:wasd/src/wasi/component/wit_adapter.dart';
import 'package:wasd/src/wasi/component/wit_document.dart';
import 'package:wasd/src/wasi/preview3/component_host.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';

void main() {
  group('WIT map adapter runtime', () {
    test('preserves ordered duplicate keys through nested record and list', () {
      final map = _runtimeMap(<Object?>[
        _runtimePair('same', _runtimeList(<Object?>[_u32(1)])),
        _runtimePair('same', _runtimeList(<Object?>[_u32(2), _u32(3)])),
      ]);
      final record = _runtimeRecord(<Object?>[
        _runtimeList(<Object?>[map]),
      ]);
      final program = _bindMapWorld((args) => args.single);

      final result = program.invokeImport('tables.update', <Object?>[record]);

      expect(result, same(record));
      expect(map.itemValues, hasLength(2));
      expect(
        map.itemValues.map(
          (item) => (item! as WasmComponentValueData).itemValues.first,
        ),
        <Object?>['same', 'same'],
      );
    });

    test('rejects malformed map entries and validates keys and values', () {
      var calls = 0;
      final program = _bindMapWorld((args) {
        calls++;
        return args.single;
      });
      for (final map in <WasmComponentValueData>[
        _runtimeList(const <Object?>[]),
        _runtimeMap(<Object?>[
          _runtimeList(<Object?>['key', _u32(1)]),
        ]),
        _runtimeMap(<Object?>[_runtimePair(7, _runtimeList(<Object?>[]))]),
        _runtimeMap(<Object?>[
          _runtimePair('key', _runtimeList(<Object?>[_u32(-1)])),
        ]),
        _runtimeMap(<Object?>[
          WasmComponentValueData(
            kind: WasmComponentValueDataKind.tuple,
            rawBytes: Uint8List(0),
            runtimeItems: const <Object?>['key'],
          ),
        ]),
      ]) {
        final value = _runtimeRecord(<Object?>[
          _runtimeList(<Object?>[map]),
        ]);
        expect(
          () => program.invokeImport('tables.update', <Object?>[value]),
          throwsStateError,
        );
      }
      expect(calls, 0);
    });

    test('validates returned map values', () {
      final argument = _runtimeRecord(<Object?>[
        _runtimeList(<Object?>[_runtimeMap(const <Object?>[])]),
      ]);
      final program = _bindMapWorld(
        (_) => _runtimeRecord(<Object?>[
          _runtimeList(<Object?>[
            _runtimeMap(<Object?>[_runtimePair('key', _u32(9))]),
          ]),
        ]),
      );

      expect(
        () => program.invokeImport('tables.update', <Object?>[argument]),
        throwsStateError,
      );
    });

    test('accepts component value tuple entries', () {
      final map = WasmComponentValueData(
        kind: WasmComponentValueDataKind.map,
        rawBytes: Uint8List(0),
        items: <WasmComponentValueData>[
          WasmComponentValueData(
            kind: WasmComponentValueDataKind.tuple,
            rawBytes: Uint8List(0),
            items: <WasmComponentValueData>[
              WasmComponentValueData(
                kind: WasmComponentValueDataKind.string,
                rawBytes: Uint8List(0),
                string: 'key',
              ),
              WasmComponentValueData(
                kind: WasmComponentValueDataKind.list,
                rawBytes: Uint8List(0),
                items: <WasmComponentValueData>[_u32(5)],
              ),
            ],
          ),
        ],
      );
      final argument = _runtimeRecord(<Object?>[
        _runtimeList(<Object?>[map]),
      ]);
      final program = _bindMapWorld((args) => args.single);

      expect(
        program.invokeImport('tables.update', <Object?>[argument]),
        same(argument),
      );
    });
  });

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

WASIComponentWitAdapterProgram _bindMapWorld(
  WASIComponentWitAdapterCallback update,
) {
  final document = WASIComponentWitDocument.parse('''
interface tables {
  type key = string;
  record batch { values: list<map<key, list<u32>>> }
  update: func(value: batch) -> batch;
}
world command { import tables; }
''');
  final functions = wasiComponentWitWorldFunctions(
    document,
    document.worldNamed('command')!,
  );
  expect(wasiComponentWitAdapterBindingErrors(functions), isEmpty);
  return WASIComponentWitAdapterProgram.bind(
    functions,
    imports: <String, WASIComponentWitAdapterCallback>{'tables.update': update},
  );
}

WasmComponentValueData _runtimeMap(List<Object?> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.map,
    rawBytes: Uint8List(0),
    runtimeItems: List<Object?>.unmodifiable(items),
  );
}

WasmComponentValueData _runtimePair(Object? key, Object? value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.tuple,
    rawBytes: Uint8List(0),
    runtimeItems: <Object?>[key, value],
  );
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
