import 'dart:async';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/resource_table.dart';

void main() {
  group('WASIComponentResourceTable', () {
    test('allocates typed resources and rejects wrong resource types', () {
      final table = WASIComponentResourceTable();
      final cliType = table.defineType<String>('cli');

      final handle = table.insert<String>(cliType, 'cli');

      expect(table.activeCount, 1);
      expect(table.contains(handle), isTrue);
      expect(table.containsType(cliType, handle), isTrue);
      expect(table.get<String>(cliType, handle), 'cli');
      expect(table.contains(42), isFalse);
      expect(() => table.drop<String>(cliType, 42), throwsStateError);
    });

    test('keeps nominal resource types separate from Dart value types', () {
      final table = WASIComponentResourceTable();
      final inputStreamType = table.defineType<int>('input-stream');
      final outputStreamType = table.defineType<int>('output-stream');

      final handle = table.insert<int>(inputStreamType, 7);

      expect(table.get<int>(inputStreamType, handle), 7);
      expect(table.containsType(inputStreamType, handle), isTrue);
      expect(table.containsType(outputStreamType, handle), isFalse);
      expect(() => table.get<int>(outputStreamType, handle), throwsStateError);
      expect(() => table.drop<int>(outputStreamType, handle), throwsStateError);

      table.drop<int>(inputStreamType, handle);
      expect(table.activeCount, 0);
    });

    test('rejects resource types from other tables', () {
      final first = WASIComponentResourceTable();
      final second = WASIComponentResourceTable();
      final firstType = first.defineType<int>('first');
      final secondType = second.defineType<int>('second');

      final handle = first.insert<int>(firstType, 1);

      expect(() => first.insert<int>(secondType, 2), throwsStateError);
      expect(() => first.get<int>(secondType, handle), throwsStateError);
      expect(() => first.drop<int>(secondType, handle), throwsStateError);

      first.drop<int>(firstType, handle);
      expect(first.activeCount, 0);
    });

    test('drops resources once and invalidates stale handles', () {
      final table = WASIComponentResourceTable();
      final dropped = <String>[];
      final streamType = table.defineType<String>(
        'stream',
        onDrop: dropped.add,
      );

      final handle = table.insert<String>(streamType, 'stream');

      table.drop<String>(streamType, handle);

      expect(table.activeCount, 0);
      expect(table.contains(handle), isFalse);
      expect(dropped, ['stream']);
      expect(() => table.get<String>(streamType, handle), throwsStateError);
      expect(() => table.drop<String>(streamType, handle), throwsStateError);

      final reused = table.insert<String>(streamType, 'future');

      expect(reused, isNot(handle));
      expect(table.get<String>(streamType, reused), 'future');
      expect(() => table.get<String>(streamType, handle), throwsStateError);
    });

    test('keeps hot reused handles in the canonical u32 range', () {
      final table = WASIComponentResourceTable();
      final streamType = table.defineType<int>('stream');
      final staleHandles = <int>[];

      for (var i = 0; i < 128; i++) {
        final handle = table.insert<int>(streamType, i);

        expect(handle, inInclusiveRange(1, 0xffffffff));
        expect(table.get<int>(streamType, handle), i);

        table.drop<int>(streamType, handle);
        staleHandles.add(handle);
      }

      for (final handle in staleHandles) {
        expect(table.contains(handle), isFalse);
        expect(() => table.get<int>(streamType, handle), throwsStateError);
      }
      expect(table.activeCount, 0);
    });

    test('supports canonical resource new, rep, and drop operations', () {
      final table = WASIComponentResourceTable();
      final dropped = <int>[];
      final descriptorType = table.defineType<int>(
        'descriptor',
        onDrop: dropped.add,
      );

      final handle = table.resourceNew<int>(descriptorType, 33);

      expect(table.resourceRep<int>(descriptorType, handle), 33);
      table.resourceDrop<int>(descriptorType, handle);
      expect(dropped, [33]);
      expect(
        () => table.resourceRep<int>(descriptorType, handle),
        throwsStateError,
      );
      expect(
        () => table.resourceDrop<int>(descriptorType, handle),
        throwsStateError,
      );
    });

    test('prevents dropping borrowed resources', () {
      final table = WASIComponentResourceTable();
      final socketType = table.defineType<String>('socket');
      final handle = table.insert<String>(socketType, 'socket');

      table.borrow<String, void>(socketType, handle, (resource) {
        expect(resource, 'socket');
        expect(() => table.drop<String>(socketType, handle), throwsStateError);
      });

      table.drop<String>(socketType, handle);
      expect(table.activeCount, 0);
    });

    test('releases borrows when callbacks throw', () {
      final table = WASIComponentResourceTable();
      final fileType = table.defineType<String>('file');
      final handle = table.insert<String>(fileType, 'file');

      expect(
        () => table.borrow<String, void>(fileType, handle, (_) {
          throw StateError('failed');
        }),
        throwsStateError,
      );

      table.drop<String>(fileType, handle);
      expect(table.activeCount, 0);
    });

    test('prevents dropping asynchronously borrowed resources', () async {
      final table = WASIComponentResourceTable();
      final fileType = table.defineType<String>('file');
      final handle = table.insert<String>(fileType, 'file');
      final completer = Completer<String>();

      final borrowed = table.borrowAsync<String, String>(fileType, handle, (
        resource,
      ) {
        expect(resource, 'file');
        return completer.future;
      });
      await Future<void>.delayed(Duration.zero);

      expect(() => table.drop<String>(fileType, handle), throwsStateError);

      completer.complete('done');

      await expectLater(borrowed, completion('done'));
      table.drop<String>(fileType, handle);
      expect(table.activeCount, 0);
    });
  });
}
