import 'package:test/test.dart';
import 'package:wasd/wasm.dart';
import 'package:wasd/src/wasm/backend/native/table.dart' as native_table;
import 'package:wasd/src/wasm/backend/native/interpreter/imports.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/instance.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/module.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/runtime_ops.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/table.dart';

import 'support/host_global_fixtures.dart';
import 'support/host_table_fixtures.dart';
import 'support/runtime_environment.dart';

void main() {
  group('WasmTable.copyEntries', () {
    test('copies overlapping ranges as if through a temporary snapshot', () {
      final table = WasmTable(refType: WasmRefType.funcref, min: 6)
        ..initialize(0, <int?>[0, 1, 2, 3, 4, 5]);

      table.copyEntries(
        source: table,
        destinationOffset: 2,
        sourceOffset: 0,
        length: 4,
      );

      expect(table.snapshot(), <int?>[0, 1, 0, 1, 2, 3]);

      table.copyEntries(
        source: table,
        destinationOffset: 0,
        sourceOffset: 2,
        length: 4,
      );

      expect(table.snapshot(), <int?>[0, 1, 2, 3, 2, 3]);
    });

    test('copies entries between tables', () {
      final source = WasmTable(refType: WasmRefType.funcref, min: 4)
        ..initialize(0, <int?>[7, null, 9, 10]);
      final target = WasmTable(refType: WasmRefType.funcref, min: 4);

      target.copyEntries(
        source: source,
        destinationOffset: 1,
        sourceOffset: 0,
        length: 3,
      );

      expect(target.snapshot(), <int?>[null, 7, null, 9]);
    });
  });

  group('RuntimeTableOps.initFromElementSegment', () {
    test('validates zero-length source bounds after elem.drop', () {
      final table = WasmTable(refType: WasmRefType.funcref, min: 4);

      expect(
        () => RuntimeTableOps.initFromElementSegment(
          segment: null,
          segmentIndex: 0,
          table: table,
          sourceOffset: 0,
          destinationOffset: table.length,
          length: 0,
        ),
        returnsNormally,
      );

      expect(
        () => RuntimeTableOps.initFromElementSegment(
          segment: null,
          segmentIndex: 0,
          table: table,
          sourceOffset: 1,
          destinationOffset: 0,
          length: 0,
        ),
        throwsStateError,
      );

      expect(
        () => RuntimeTableOps.initFromElementSegment(
          segment: null,
          segmentIndex: 0,
          table: table,
          sourceOffset: 0,
          destinationOffset: table.length + 1,
          length: 0,
        ),
        throwsStateError,
      );
    });
  });
  _publicTableTests();
}

Table<ExternRef, Object?> _externTable({
  int initial = 2,
  int? maximum = 4,
  Object? value,
}) => Table<ExternRef, Object?>(
  TableDescriptor(TableKind.externref, initial, maximum),
  value,
);

Table<FuncRef, Function?> _functionTable({
  int initial = 1,
  int? maximum = 4,
  Function? value,
}) => Table<FuncRef, Function?>(
  TableDescriptor(TableKind.funcref, initial, maximum),
  value,
);

Instance _tableInstance(String fixture, [Table? table]) => Instance(
  Module(hostTableFixture(fixture).buffer),
  table == null
      ? const {}
      : {
          'host': {'table': ImportExportKind.table(table)},
        },
);

Table _exportTable(Instance instance, [String name = 'values']) =>
    (instance.exports[name]! as TableImportExportValue).ref;

Object? _tableCall(
  Instance instance,
  String name, [
  List<Object?> args = const [],
]) => (instance.exports[name]! as FunctionImportExportValue).ref(args);

Future<Object?> _tableInvoke(
  Instance instance,
  String name, [
  List<Object?> args = const [],
]) => Future<Object?>.sync(() => _tableCall(instance, name, args));

void _publicTableTests() {
  group('public Table bindings', () {
    test('externref imports share host guest set grow and export aliases', () {
      final table = _externTable();
      expect(table.get(0), isNull);
      final instance = _tableInstance('externref_import', table);
      final exported = _exportTable(instance);
      final alias = _exportTable(instance, 'alias');
      table.set(0, 'host');
      expect(_tableCall(instance, 'get', [0]), 'host');
      _tableCall(instance, 'set', [1, 42]);
      expect(table.get(1), 42);
      expect(exported.get(1), 42);
      alias.set(0, null);
      expect(table.get(0), isNull);
      expect(table.grow(1, 'host fill'), 2);
      expect(_tableCall(instance, 'size'), 3);
      expect(_tableCall(instance, 'get', [2]), 'host fill');
      expect(_tableCall(instance, 'grow', [1, 17]), 3);
      expect(table.length, 4);
      expect(alias.length, 4);
      expect(exported.get(3), 17);
      expect(_tableCall(instance, 'grow', [1, null]), -1);
      expect(table.length, 4);
    });

    test(
      'externref owned exports reimport across instances and stay isolated',
      () {
        final first = _tableInstance('externref_owned');
        final other = _tableInstance('externref_owned');
        final exported = _exportTable(first);
        final second = _tableInstance('externref_import', exported);
        _tableCall(second, 'set', [0, 'consumer']);
        expect(_tableCall(first, 'get', [0]), 'consumer');
        expect(_exportTable(first, 'alias').get(0), 'consumer');
        expect(_exportTable(other).get(0), isNull);
        exported.set(1, 99);
        expect(_tableCall(second, 'get', [1]), 99);
        expect(exported.grow(1), 2);
        expect(_exportTable(second).length, 3);
        expect(_tableCall(second, 'get', [2]), isNull);
      },
    );

    test(
      'kind and limits mismatch reject before active data elements and start',
      () {
        final module = Module(hostTableFixture('limits_effect').buffer);
        final incompatible = <Table>[
          _externTable(),
          _functionTable(initial: 1),
          _functionTable(initial: 2, maximum: 5),
          _functionTable(initial: 2, maximum: null),
        ];
        for (final table in incompatible) {
          var starts = 0;
          final memory = Memory(const MemoryDescriptor(initial: 1));
          expect(
            () => Instance(module, {
              'host': {
                'table': ImportExportKind.table(table),
                'memory': ImportExportKind.memory(memory),
                'started': ImportExportKind.function((_) {
                  starts++;
                  return null;
                }),
              },
            }),
            throwsA(isA<LinkError>()),
          );
          expect(starts, 0);
          expect(memory.buffer.asUint8List()[0], 0);
          expect(table.get(0), isNull);
        }
      },
    );

    test(
      'externref BigInt and null survive host guest and exported table reads',
      () {
        final value = BigInt.parse('18446744073709551617');
        final table = _externTable();
        final instance = _tableInstance('externref_import', table);
        final exported = _exportTable(instance);
        table.set(0, value);
        expect(exported.get(0), value);
        expect(_tableCall(instance, 'get', [0]), value);
        _tableCall(instance, 'set', [1, value]);
        expect(table.get(1), value);
        expect(exported.get(1), value);
        exported.set(0, null);
        expect(table.get(0), isNull);
        expect(_tableCall(instance, 'get', [0]), isNull);
      },
    );

    if (!hasDartIoRuntime) {
      test('JS guest object table writes reject unsupported public reads', () {
        final table = _externTable();
        final instance = _tableInstance('externref_import', table);
        _tableCall(instance, 'set', [
          0,
          <String, Object?>{'x': 1},
        ]);
        expect(() => table.get(0), throwsA(isA<UnsupportedError>()));
        expect(
          () => _exportTable(instance).get(0),
          throwsA(isA<UnsupportedError>()),
        );
        final source = _tableInstance('funcref_owned');
        expect(
          () => _exportTable(source).get(0),
          throwsA(isA<UnsupportedError>()),
        );
      });

      test(
        'JS funcref retains its explicit Dart function encoding limitation',
        () {
          final table = _functionTable();
          expect(table.get(0), isNull);
          expect(
            () => table.set(0, (List<Object?> args) => args.single),
            throwsA(isA<UnsupportedError>()),
          );
          expect(table.get(0), isNull);
        },
      );
      return;
    }

    test('VM private funcref table with sync host tick stays synchronous', () {
      var ticks = 0;
      final instance = Instance(
        Module(hostTableFixture('private_funcref').buffer),
        {
          'host': {
            'tick': ImportExportKind.function((_) {
              ticks++;
              return null;
            }),
          },
        },
      );
      expect(_tableCall(instance, 'run', [41]), 42);
      expect(ticks, 1);
      final relay = Instance(
        Module(hostGlobalFixture('reference_import_call').buffer),
        {
          'host': {
            'relay': instance.exports['run']! as FunctionImportExportValue,
          },
        },
      );
      expect(_tableCall(relay, 'call', [41]), 42);
      expect(ticks, 2);
    });

    test(
      'VM externref null object and record identities survive shared backing',
      () {
        final original = Object(), replacement = Object();
        final record = (name: 'table record', marker: original);
        final table = _externTable(value: original);
        final first = _tableInstance('externref_import', table);
        final second = _tableInstance('externref_import', _exportTable(first));
        expect(_tableCall(second, 'get', [0]), same(original));
        _tableCall(second, 'set', [0, replacement]);
        expect(table.get(0), same(replacement));
        expect(_exportTable(first, 'alias').get(0), same(replacement));
        table.set(1, record);
        final returnedRecord = _tableCall(first, 'get', [1]);
        expect(returnedRecord, record);
        expect(
          (returnedRecord as ({String name, Object marker})).marker,
          same(original),
        );
        expect(_tableCall(second, 'grow', [1, original]), 2);
        expect(table.get(2), same(original));
        expect(table.grow(1, replacement), 3);
        expect(_tableCall(first, 'get', [3]), same(replacement));
        _tableCall(first, 'set', [0, null]);
        expect(table.get(0), isNull);
        expect(_tableCall(second, 'get', [0]), isNull);
      },
    );

    test(
      'VM genuine funcref exports preserve identity and indirect signatures',
      () async {
        final source = _tableInstance('funcref_owned');
        final independent = _tableInstance('funcref_owned');
        final increment =
            (source.exports['increment']! as FunctionImportExportValue).ref;
        final wrong =
            (source.exports['wrong']! as FunctionImportExportValue).ref;
        final exported = _exportTable(source);
        expect(exported.get(0), same(increment));
        expect(_tableCall(source, 'get', [0]), same(increment));
        final first = _tableInstance('funcref_import', exported);
        final second = _tableInstance(
          'funcref_import',
          _exportTable(first, 'alias'),
        );
        expect(await _tableInvoke(second, 'call', [0, 41]), 42);
        expect(_tableCall(source, 'calls'), 1);
        expect(_tableCall(independent, 'calls'), 0);
        expect(_tableCall(first, 'get', [0]), same(increment));
        expect(exported.grow(1, increment), 1);
        expect(_exportTable(second).get(1), same(increment));
        expect(await _tableInvoke(second, 'grow', [1, increment]), 2);
        expect(exported.get(2), same(increment));
        await _tableInvoke(second, 'set', [0, wrong]);
        expect(exported.get(0), same(wrong));
        await expectLater(
          _tableInvoke(first, 'call', [0, 41]),
          throwsA(
            predicate<Object>(
              (error) =>
                  error.toString().contains('call_indirect signature mismatch'),
            ),
          ),
        );
        exported.set(0, null);
        await expectLater(
          _tableInvoke(second, 'call', [0, 41]),
          throwsA(
            predicate<Object>(
              (error) => error.toString().contains(
                'call_indirect to null table element',
              ),
            ),
          ),
        );
        _exportTable(first, 'alias').set(0, increment);
        expect(await _tableInvoke(second, 'call', [0, 9]), 10);
        expect(exported.get(0), same(increment));
      },
    );

    test(
      'VM imported funcref table awaits actual foreign async guest calls',
      () async {
        var entered = 0, settled = 0;
        final source = Instance(
          Module(hostGlobalFixture('reference_host_callbacks').buffer),
          {
            'host': {
              'tick': ImportExportKind.function((List<Object?> _) async {
                entered++;
                await Future<void>.value();
                settled++;
                return null;
              }),
              'echo': ImportExportKind.function((args) => args.single),
              'fail': ImportExportKind.function((_) => null),
            },
          },
        );
        final increment =
            (source.exports['increment']! as FunctionImportExportValue).ref;
        final table = _functionTable(value: increment);
        final instance = _tableInstance('funcref_import', table);
        expect(table.get(0), same(increment));
        expect(await _tableInvoke(instance, 'call', [0, 41]), 42);
        expect(entered, 1);
        expect(settled, 1);
        expect(await _tableInvoke(source, 'calls'), 1);
        final pure = _tableInstance('funcref_owned');
        final pureIncrement =
            (pure.exports['increment']! as FunctionImportExportValue).ref;
        table.set(0, pureIncrement);
        expect(await _tableInvoke(instance, 'call', [0, 9]), 10);
        table.set(0, increment);
        expect(await _tableInvoke(instance, 'call', [0, 19]), 20);
        expect(entered, 2);
        expect(settled, 2);
        expect(table.get(0), same(increment));
      },
    );

    for (final mutation in ['set', 'grow']) {
      test('VM mid-call table $mutation awaits foreign async guest', () async {
        var settled = 0, callbacks = 0;
        final source = _asyncTableSource(() async {
          await Future<void>.value();
          settled++;
        });
        final asyncIncrement =
            (source.exports['increment']! as FunctionImportExportValue).ref;
        final pure = _tableInstance('funcref_owned');
        final pureIncrement =
            (pure.exports['increment']! as FunctionImportExportValue).ref;
        final table = _functionTable(value: pureIncrement);
        final index = mutation == 'set' ? 0 : 1;
        final instance = Instance(
          Module(hostTableFixture('funcref_midcall').buffer),
          {
            'host': {
              'table': ImportExportKind.table(table),
              'tick': ImportExportKind.function((_) {
                callbacks++;
                if (mutation == 'set') {
                  table.set(0, asyncIncrement);
                } else {
                  expect(table.grow(1, asyncIncrement), 1);
                }
                return null;
              }),
            },
          },
        );
        expect(await _tableInvoke(instance, 'call', [index, 41]), 42);
        expect(callbacks, 1);
        expect(settled, 1);
        expect(await _tableInvoke(source, 'calls'), 1);
        expect(table.get(index), same(asyncIncrement));
      });
    }

    test(
      'VM internal multi-table copy retains async source after original slot clear',
      () async {
        var settled = 0;
        final source = _asyncTableSource(() async {
          await Future<void>.value();
          settled++;
        });
        final increment =
            (source.exports['increment']! as FunctionImportExportValue).ref;
        final sourceTable = _functionTable(value: increment);
        final target = _tableInstance('funcref_owned');
        final targetTable = _exportTable(target);
        // Public Module does not expose the multi-table feature. Only this
        // copying bridge uses IR; the source, target and final call stay public.
        final copier = WasmInstance.fromBytes(
          hostTableFixture('funcref_copy'),
          features: const WasmFeatureSet(additionalEnabled: {'multi-table'}),
          imports: WasmImports(
            tables: {
              WasmImports.key('host', 'source'):
                  (sourceTable as native_table.Table).host,
              WasmImports.key('host', 'target'):
                  (targetTable as native_table.Table).host,
            },
          ),
        );
        copier.invoke('copy');
        sourceTable.set(0, null);
        expect(await _tableInvoke(target, 'call', [0, 41]), 42);
        expect(settled, 1);
        expect(await _tableInvoke(source, 'calls'), 1);
        expect(sourceTable.get(0), isNull);
        expect(targetTable.get(0), same(increment));
      },
    );

    test('VM unsupported public table types reject before data and start', () {
      for (final fixture in [
        'typed_export',
        'nonnullable_export',
        'gc_export',
        'table64_export',
      ]) {
        final module = Module(hostTableFixture(fixture).buffer);
        final memory = Memory(const MemoryDescriptor(initial: 1));
        var starts = 0;
        expect(
          () => Instance(module, {
            'host': {
              'memory': ImportExportKind.memory(memory),
              'started': ImportExportKind.function((_) {
                starts++;
                return null;
              }),
            },
          }),
          throwsA(isA<LinkError>()),
          reason: fixture,
        );
        expect(starts, 0, reason: fixture);
        expect(memory.buffer.asUint8List()[0], 0, reason: fixture);
      }
    });

    test('VM unused extra invalid table remains unbound', () {
      Object? ordinary(List<Object?> args) => args.single;
      final table = _functionTable(value: ordinary);
      var ticks = 0;
      final instance = Instance(
        Module(hostTableFixture('private_funcref').buffer),
        {
          'host': {
            'table': ImportExportKind.table(table),
            'tick': ImportExportKind.function((_) {
              ticks++;
              return null;
            }),
          },
        },
      );
      expect(_tableCall(instance, 'run', [41]), 42);
      expect(ticks, 1);
      expect(table.get(0), same(ordinary));
      expect(table.grow(1, ordinary), 1);
      expect(table.get(1), same(ordinary));
    });

    for (final failedImport in ['limits', 'missing started']) {
      test(
        'VM failed table link preserves standalone closures: $failedImport',
        () {
          final initial = failedImport == 'limits' ? 1 : 2;
          final table = _functionTable(initial: initial);
          final memory = Memory(const MemoryDescriptor(initial: 1));
          var starts = 0;
          expect(
            () => Instance(Module(hostTableFixture('limits_effect').buffer), {
              'host': {
                'table': ImportExportKind.table(table),
                'memory': ImportExportKind.memory(memory),
                if (failedImport == 'limits')
                  'started': ImportExportKind.function((_) {
                    starts++;
                    return null;
                  }),
              },
            }),
            throwsA(isA<LinkError>()),
          );
          expect(starts, 0);
          expect(memory.buffer.asUint8List()[0], 0);
          expect(table.length, initial);
          Object? ordinary(List<Object?> args) => args.single;
          table.set(0, ordinary);
          expect(table.get(0), same(ordinary));
          expect(table.grow(1, ordinary), initial);
          expect(table.get(initial), same(ordinary));
        },
      );
    }

    test(
      'VM full bound funcref grow validates fill without changing state',
      () {
        final source = _tableInstance('funcref_owned');
        final increment =
            (source.exports['increment']! as FunctionImportExportValue).ref;
        final table = _functionTable(initial: 4, value: increment);
        _tableInstance('funcref_import', table);
        Object? ordinary(List<Object?> args) => args.single;
        expect(() => table.grow(1, ordinary), throwsArgumentError);
        expect(() => table.grow(1, increment), throwsRangeError);
        expect(table.length, 4);
        for (var index = 0; index < table.length; index++) {
          expect(table.get(index), same(increment));
        }
      },
    );

    test('VM standalone Dart functions remain valid until table binding', () {
      Object? ordinary(List<Object?> args) => args.single;
      final table = _functionTable(value: ordinary);
      expect(table.get(0), same(ordinary));
      table.set(0, ordinary);
      expect(table.grow(1, ordinary), 1);
      expect(table.get(1), same(ordinary));
      expect(
        () => _tableInstance('funcref_import', table),
        throwsA(isA<LinkError>()),
      );
      expect(table.length, 2);
      expect(table.get(0), same(ordinary));
    });

    test(
      'VM bound funcref rejects ordinary closures without changing slots or size',
      () {
        final source = _tableInstance('funcref_owned');
        final increment =
            (source.exports['increment']! as FunctionImportExportValue).ref;
        final table = _functionTable(value: increment);
        _tableInstance('funcref_import', table);
        Object? ordinary(List<Object?> args) => args.single;
        expect(() => table.set(0, ordinary), throwsArgumentError);
        expect(table.get(0), same(increment));
        expect(() => table.grow(1, ordinary), throwsArgumentError);
        expect(table.length, 1);
        expect(table.get(0), same(increment));
      },
    );

    test(
      'VM valid grown import uses current length and performs effects once',
      () {
        final table = _functionTable(initial: 1);
        expect(table.grow(1), 1);
        var starts = 0;
        final memory = Memory(const MemoryDescriptor(initial: 1));
        Instance(Module(hostTableFixture('limits_effect').buffer), {
          'host': {
            'table': ImportExportKind.table(table),
            'memory': ImportExportKind.memory(memory),
            'started': ImportExportKind.function((_) {
              starts++;
              return null;
            }),
          },
        });
        expect(starts, 1);
        expect(memory.buffer.asUint8List()[0], 116);
        expect(table.get(0), isA<Function>());
        expect(table.length, 2);
      },
    );

    test('VM table limits and bounds fail without partial growth', () {
      expect(() => _externTable(initial: -1), throwsArgumentError);
      expect(() => _externTable(initial: 2, maximum: 1), throwsArgumentError);
      final table = _externTable();
      _tableInstance('externref_import', table);
      expect(() => table.get(-1), throwsRangeError);
      expect(() => table.set(2, 'outside'), throwsRangeError);
      expect(() => table.grow(-1), throwsArgumentError);
      expect(() => table.grow(3, 'too large'), throwsRangeError);
      expect(table.length, 2);
      expect(table.get(1), isNull);
    });
  });
}

Instance _asyncTableSource(Future<void> Function() tick) =>
    Instance(Module(hostGlobalFixture('reference_host_callbacks').buffer), {
      'host': {
        'tick': ImportExportKind.function((List<Object?> _) async {
          await tick();
          return null;
        }),
        'echo': ImportExportKind.function((args) => args.single),
        'fail': ImportExportKind.function((_) => null),
      },
    });
