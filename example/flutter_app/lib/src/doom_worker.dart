import 'dart:collection';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:isolate_manager/isolate_manager.dart';

import 'doom_shared_input_queue.dart';
import 'doom_runtime.dart';

@pragma('vm:entry-point')
@isolateManagerCustomWorker
void doomRunnerWorker(dynamic params) {
  IsolateManagerFunction.customFunction<Object?, Object?>(
    params,
    autoHandleException: false,
    autoHandleResult: false,
    onEvent: (controller, message) async {
      final request = normalizeDoomRunnerMessage(message);
      final command = request['type'];
      if (command != doomRunnerCommandStart) {
        _sendMessage(controller, <String, Object?>{
          'type': 'error',
          'error': 'Unsupported worker command: $command',
        });
        return const <String, Object?>{'type': 'ignored'};
      }

      try {
        final wasmBytes = _requireBytes(request['wasmBytes'], 'wasmBytes');
        final iwadBytes = _requireBytes(request['iwadBytes'], 'iwadBytes');
        final inputQueue = DoomSharedInputQueue.fromHandle(
          request['inputQueue'],
          capacity: asIntOrNull(request['inputQueueCapacity']) ?? 256,
        );
        final nativeInputPort = ReceivePort();
        final pendingNativeEvents = Queue<DoomInputEvent>();
        final nativeInputSubscription = nativeInputPort.listen((message) {
          final event = DoomInputEvent.fromMessage(message);
          if (event != null) {
            pendingNativeEvents.add(event);
          }
        });
        _sendMessage(controller, <String, Object?>{
          'type': 'input-port',
          'port': nativeInputPort.sendPort,
        });
        final runtime = DoomRuntime.withInputDrain(
          emit: (runnerMessage) => _sendMessage(controller, runnerMessage),
          drainInput: (queue) {
            inputQueue?.drainInto(queue);
            if (pendingNativeEvents.isEmpty) {
              return;
            }
            queue.addAll(pendingNativeEvents);
            pendingNativeEvents.clear();
          },
        );
        try {
          await runtime.run(wasmBytes: wasmBytes, iwadBytes: iwadBytes);
        } finally {
          await nativeInputSubscription.cancel();
          nativeInputPort.close();
        }
      } catch (error, stackTrace) {
        _sendMessage(controller, <String, Object?>{
          'type': 'error',
          'error': '$error',
          'stack': '$stackTrace',
        });
      }

      return const <String, Object?>{'type': 'ignored'};
    },
  );
}

void _sendMessage(
  IsolateManagerController<Object?, Object?> controller,
  DoomRunnerMessage message,
) {
  final bmp = message['bmp'];
  if (bmp is Uint8List || bmp is ByteBuffer) {
    controller.sendResultWithAutoTransfer(message);
    return;
  }
  controller.sendResult(message);
}

Uint8List _requireBytes(Object? value, String fieldName) {
  final bytes = messageBytesAsUint8List(value);
  if (bytes == null) {
    throw ArgumentError.value(value, fieldName, 'Expected binary payload.');
  }
  return bytes;
}
