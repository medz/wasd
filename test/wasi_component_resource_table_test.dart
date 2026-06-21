import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/resource_table.dart';

void main() {
  group('WASIComponentResourceTable', () {
    test('allocates typed resources and rejects wrong resource types', () {
      final table = WASIComponentResourceTable();

      final handle = table.insert<String>('cli');

      expect(table.activeCount, 1);
      expect(table.contains(handle), isTrue);
      expect(table.get<String>(handle), 'cli');
      expect(() => table.get<int>(handle), throwsStateError);
      expect(table.contains(42), isFalse);
      expect(() => table.drop<Object>(42), throwsStateError);
    });

    test('drops resources once and invalidates stale handles', () {
      final table = WASIComponentResourceTable();
      final dropped = <String>[];

      final handle = table.insert<String>('stream', onDrop: dropped.add);

      table.drop<String>(handle);

      expect(table.activeCount, 0);
      expect(table.contains(handle), isFalse);
      expect(dropped, ['stream']);
      expect(() => table.get<String>(handle), throwsStateError);
      expect(() => table.drop<String>(handle), throwsStateError);

      final reused = table.insert<String>('future');

      expect(reused, isNot(handle));
      expect(table.get<String>(reused), 'future');
      expect(() => table.get<String>(handle), throwsStateError);
    });

    test('prevents dropping borrowed resources', () {
      final table = WASIComponentResourceTable();
      final handle = table.insert<String>('socket');

      table.borrow<String, void>(handle, (resource) {
        expect(resource, 'socket');
        expect(() => table.drop<String>(handle), throwsStateError);
      });

      table.drop<String>(handle);
      expect(table.activeCount, 0);
    });

    test('releases borrows when callbacks throw', () {
      final table = WASIComponentResourceTable();
      final handle = table.insert<String>('file');

      expect(
        () => table.borrow<String, void>(handle, (_) {
          throw StateError('failed');
        }),
        throwsStateError,
      );

      table.drop<String>(handle);
      expect(table.activeCount, 0);
    });
  });
}
