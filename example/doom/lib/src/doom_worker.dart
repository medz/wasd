import 'dart:async';
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
        _sendMessage(controller, request['uiPort'], <String, Object?>{
          'type': doomRunnerMessageError,
          'error': 'Unsupported worker command: $command',
        });
        return const <String, Object?>{'type': 'ignored'};
      }

      ReceivePort? nativeInputPort;
      StreamSubscription<Object?>? nativeInputSubscription;

      try {
        final wasmBytes = _requireBytes(request['wasmBytes'], 'wasmBytes');
        final iwadBytes = _requireBytes(request['iwadBytes'], 'iwadBytes');
        final nativeUiPort = request['uiPort'];
        final frameTransport = request['frameTransport'] == doomFrameFormatBmp
            ? DoomFrameTransport.bmp
            : DoomFrameTransport.rgba;
        final inputQueue = DoomSharedInputQueue.fromHandle(
          request['inputQueue'],
          capacity: asIntOrNull(request['inputQueueCapacity']) ?? 256,
        );
        final pendingNativeEvents = Queue<DoomInputEvent>();
        if (inputQueue == null) {
          nativeInputPort = ReceivePort();
          nativeInputSubscription = nativeInputPort.listen((message) {
            final event = DoomInputEvent.fromNativeMessage(message);
            if (event != null) {
              pendingNativeEvents.add(event);
            }
          });
          _sendMessage(controller, nativeUiPort, <String, Object?>{
            'type': doomRunnerMessageInputPort,
            'port': nativeInputPort.sendPort,
          });
        }

        final runtime = DoomRuntime.withInputDrain(
          emit: (runnerMessage) =>
              _sendMessage(controller, nativeUiPort, runnerMessage),
          frameTransport: frameTransport,
          frameIntervalUs: frameTransport == DoomFrameTransport.rgba
              ? doomNativeTargetFrameIntervalUs
              : 0,
          drainInput: (queue) {
            inputQueue?.drainInto(queue);
            if (pendingNativeEvents.isEmpty) {
              return;
            }
            queue.addAll(pendingNativeEvents);
            pendingNativeEvents.clear();
          },
        );
        await runtime.run(wasmBytes: wasmBytes, iwadBytes: iwadBytes);
      } catch (error, stackTrace) {
        _sendMessage(controller, request['uiPort'], <String, Object?>{
          'type': doomRunnerMessageError,
          'error': '$error',
          'stack': '$stackTrace',
        });
      } finally {
        await nativeInputSubscription?.cancel();
        nativeInputPort?.close();
      }

      return const <String, Object?>{'type': 'ignored'};
    },
  );
}

void _sendMessage(
  IsolateManagerController<Object?, Object?> controller,
  Object? nativeUiPort,
  DoomRunnerMessage message,
) {
  if (nativeUiPort is SendPort) {
    nativeUiPort.send(_nativeTransferMessage(message));
    return;
  }
  final bytes = message['bytes'];
  if (bytes is Uint8List || bytes is ByteBuffer) {
    controller.sendResultWithAutoTransfer(message);
    return;
  }
  controller.sendResult(message);
}

DoomRunnerMessage _nativeTransferMessage(DoomRunnerMessage message) {
  final bytes = message['bytes'];
  if (bytes is Uint8List) {
    return <String, Object?>{
      ...message,
      'bytes': TransferableTypedData.fromList(<Uint8List>[bytes]),
    };
  }
  return message;
}

Uint8List _requireBytes(Object? value, String fieldName) {
  final bytes = messageBytesAsUint8List(value);
  if (bytes == null) {
    throw ArgumentError.value(value, fieldName, 'Expected binary payload.');
  }
  return bytes;
}
