import 'dart:async';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/context.dart';
import 'package:wasd/src/wasi/component/thread.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';

void main() {
  group('WASIComponentThreadHost', () {
    test('reports implicit thread index and available parallelism', () {
      final host = WASIComponentThreadHost(availableParallelism: 4);
      final index = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.threadIndex,
        ),
      );
      final availableParallelism = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.threadAvailableParallelism,
          isShared: true,
        ),
      );

      expect(index.threadIndex(), 0);
      expect(availableParallelism.shared, isTrue);
      expect(availableParallelism.threadAvailableParallelism(), 4);
      expect(host.threadCount, 1);
    });

    test('runs with registered threads and their contexts', () {
      final contextHost = WASIComponentContextHost();
      final threadHost = WASIComponentThreadHost(contextHost: contextHost);
      final contextSet = contextHost.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.contextSet,
          contextIndex: 0,
        ),
      );
      final contextGet = contextHost.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.contextGet,
          contextIndex: 0,
        ),
      );
      final threadIndex = threadHost.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.threadIndex,
        ),
      );
      final worker = threadHost.createThread(
        name: 'worker',
        context: WASIComponentContext(
          name: 'worker-context',
          initialSlots: [9],
        ),
      );

      contextSet.contextSet(3);

      final workerResult = threadHost.runWithThread(worker, () {
        expect(threadIndex.threadIndex(), worker.index);
        expect(contextGet.contextGet(), 9);
        contextSet.contextSet(12);
        return contextGet.contextGet();
      });

      expect(workerResult, 12);
      expect(worker.context.get(0), 12);
      expect(threadIndex.threadIndex(), 0);
      expect(contextGet.contextGet(), 3);
    });

    test('restores current thread and context after async scopes', () async {
      final contextHost = WASIComponentContextHost();
      final threadHost = WASIComponentThreadHost(contextHost: contextHost);
      final contextGet = contextHost.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.contextGet,
          contextIndex: 0,
        ),
      );
      final threadIndex = threadHost.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.threadIndex,
        ),
      );
      final worker = threadHost.createThread(
        name: 'async-worker',
        context: WASIComponentContext(
          name: 'async-worker-context',
          initialSlots: [44],
        ),
      );

      await expectLater(
        threadHost.runWithThreadAsync(worker, () async {
          await Future<void>.delayed(Duration.zero);
          return <int>[threadIndex.threadIndex(), contextGet.contextGet()];
        }),
        completion(<int>[worker.index, 44]),
      );

      expect(threadIndex.threadIndex(), 0);
      expect(contextGet.contextGet(), 0);
    });

    test('keeps overlapping async threads and contexts isolated', () async {
      final contextHost = WASIComponentContextHost();
      final threadHost = WASIComponentThreadHost(contextHost: contextHost);
      final contextGet = contextHost.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.contextGet,
          contextIndex: 0,
        ),
      );
      final threadIndex = threadHost.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.threadIndex,
        ),
      );
      final left = threadHost.createThread(
        name: 'left-thread',
        context: WASIComponentContext(
          name: 'left-thread-context',
          initialSlots: [100],
        ),
      );
      final right = threadHost.createThread(
        name: 'right-thread',
        context: WASIComponentContext(
          name: 'right-thread-context',
          initialSlots: [200],
        ),
      );
      final leftEntered = Completer<void>();
      final releaseLeft = Completer<void>();
      final rightEntered = Completer<void>();
      final releaseRight = Completer<void>();

      final leftResult = threadHost.runWithThreadAsync(left, () async {
        expect(threadIndex.threadIndex(), left.index);
        expect(contextGet.contextGet(), 100);
        leftEntered.complete();
        await releaseLeft.future;
        return <int>[threadIndex.threadIndex(), contextGet.contextGet()];
      });
      await leftEntered.future;

      final rightResult = threadHost.runWithThreadAsync(right, () async {
        expect(threadIndex.threadIndex(), right.index);
        expect(contextGet.contextGet(), 200);
        rightEntered.complete();
        await releaseRight.future;
        return <int>[threadIndex.threadIndex(), contextGet.contextGet()];
      });
      await rightEntered.future;

      try {
        releaseLeft.complete();
        expect(await leftResult, <int>[left.index, 100]);
      } finally {
        if (!releaseRight.isCompleted) {
          releaseRight.complete();
        }
      }
      expect(await rightResult, <int>[right.index, 200]);
      expect(threadIndex.threadIndex(), 0);
      expect(contextGet.contextGet(), 0);
    });

    test(
      'lets synchronous thread scopes override async current threads',
      () async {
        final contextHost = WASIComponentContextHost();
        final threadHost = WASIComponentThreadHost(contextHost: contextHost);
        final contextGet = contextHost.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.contextGet,
            contextIndex: 0,
          ),
        );
        final threadIndex = threadHost.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.threadIndex,
          ),
        );
        final outer = threadHost.createThread(
          name: 'outer-thread',
          context: WASIComponentContext(
            name: 'outer-thread-context',
            initialSlots: [33],
          ),
        );
        final nested = threadHost.createThread(
          name: 'nested-thread',
          context: WASIComponentContext(
            name: 'nested-thread-context',
            initialSlots: [66],
          ),
        );

        await threadHost.runWithThreadAsync(outer, () async {
          expect(threadIndex.threadIndex(), outer.index);
          expect(contextGet.contextGet(), 33);

          final nestedResult = threadHost.runWithThread(nested, () {
            return <int>[threadIndex.threadIndex(), contextGet.contextGet()];
          });

          expect(nestedResult, <int>[nested.index, 66]);
          expect(threadIndex.threadIndex(), outer.index);
          expect(contextGet.contextGet(), 33);
        });
      },
    );

    test('invokes thread programs by canonical definition order', () {
      final host = WASIComponentThreadHost(availableParallelism: 2);
      final program = WASIComponentCanonicalThreadProgram(
        operations: [
          host.bindCanonicalDefinition(
            const WasmComponentCanonicalDefinition(
              kind: WasmComponentCanonicalKind.threadIndex,
            ),
          ),
          host.bindCanonicalDefinition(
            const WasmComponentCanonicalDefinition(
              kind: WasmComponentCanonicalKind.threadAvailableParallelism,
            ),
          ),
        ],
      );

      expect(program.invoke(0, const <Object?>[]), 0);
      expect(program.invoke(1, const <Object?>[]), 2);
      expect(() => program.invoke(1, <Object?>[1]), throwsStateError);
      expect(() => program.invoke(9, const <Object?>[]), throwsStateError);
    });

    test('executes thread.yield asynchronously', () async {
      final host = WASIComponentThreadHost();
      final yielded = <String>[];
      final yieldOperation = host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.threadYield,
        ),
      );

      final future = yieldOperation.threadYield().then(
        (_) => yielded.add('done'),
      );

      expect(yielded, isEmpty);
      await future;
      expect(yielded, ['done']);

      final program = WASIComponentCanonicalThreadProgram(
        operations: [yieldOperation],
      );
      expect(program.invokeAsync(0, const <Object?>[]), completes);
      expect(
        () => program.invoke(0, const <Object?>[]),
        throwsUnsupportedError,
      );
    });

    test('validates host configuration and unsupported thread definitions', () {
      expect(
        () => WASIComponentThreadHost(availableParallelism: 0),
        throwsRangeError,
      );
      expect(
        () => WASIComponentThreadHost(availableParallelism: 0x100000000),
        throwsRangeError,
      );

      final host = WASIComponentThreadHost();
      expect(
        () => host.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.threadSuspend,
          ),
        ),
        throwsUnsupportedError,
      );
      expect(
        () => host.bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.waitableSetNew,
          ),
        ),
        throwsUnsupportedError,
      );
    });
  });
}
