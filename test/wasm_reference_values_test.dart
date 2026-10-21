@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:wasd/src/wasm/backend/native/global.dart' as native;
import 'package:wasd/src/wasm/backend/native/reference_values.dart';
import 'package:wasd/wasm.dart';

import 'support/host_global_fixtures.dart';

void main() {
  test('record callback roundtrip preserves the original guest reference', () {
    final record = (value: Object());
    final source = Instance(
      Module(hostGlobalFixture('externref_owned').buffer),
    );
    final exported = source.exports['value']! as GlobalImportExportValue;
    exported.ref.value = record;
    final consumer = Instance(
      Module(hostGlobalFixture('reference_record_callback').buffer),
      {
        'host': {
          'value': exported,
          'echo': ImportExportKind.function((args) => args.single),
        },
      },
    );
    (consumer.exports['run']! as FunctionImportExportValue).ref([]);
    final copied = consumer.exports['copy']! as GlobalImportExportValue;
    expect(
      (copied.ref as native.Global).host.value.asI32(),
      (exported.ref as native.Global).host.value.asI32(),
    );
    expect((copied.ref.value as ({Object value})).value, same(record.value));
  });

  test(
    'record references remain identical across connected and cyclic stores',
    () {
      final first = ReferenceValues();
      final second = ReferenceValues()..connect(first);
      final third = ReferenceValues()..connect(second);
      final record = (value: Object());
      final id = first.encode('6f', record);
      expect(second.encode('6f', record), id);
      expect(third.encode('6f', record), id);
      first.connect(third);
      final another = (value: Object());
      final anotherId = first.encode('6f', another);
      expect(third.encode('6f', another), anotherId);
      expect(anotherId, isNot(id));
    },
  );

  test('decoded record references retain their original encoding', () {
    final first = ReferenceValues();
    final other = ReferenceValues();
    final record = (value: Object());
    final id = first.encode('6f', record);
    final decoded = other.decode('6f', id);
    expect(other.encode('6f', decoded), id);
    expect((decoded as ({Object value})).value, same(record.value));
    expect(other.encode('6f', null), -1);
    expect(other.decode('6f', -1), isNull);
  });
  test(
    'imported guest functions connect source and importing reference stores',
    () {
      final source = Instance(
        Module(hostGlobalFixture('funcref_owned').buffer),
      );
      final function =
          (source.exports['increment']! as FunctionImportExportValue).ref;
      final importer = Instance(
        Module(hostGlobalFixture('reference_import_call').buffer),
        {
          'host': {'relay': ImportExportKind.function(function)},
        },
      );
      final global =
          (importer.exports['value']! as GlobalImportExportValue).ref
              as native.Global;
      final record = (value: Object());
      global.value = record;
      final sourceStore =
          ((source.exports['value']! as GlobalImportExportValue).ref
                  as native.Global)
              .references;
      expect(sourceStore.encode('6f', record), global.host.value.asI32());
    },
  );
}
