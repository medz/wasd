import 'dart:isolate';
import 'dart:typed_data';

import 'package:isolate_manager/isolate_manager.dart';

import 'doom_native_input_channel.dart';
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

      DoomNativeInputServer? nativeInputChannel;

      try {
        final wasmBytes = _requireBytes(request['wasmBytes'], 'wasmBytes');
        final iwadBytes = _requireBytes(request['iwadBytes'], 'iwadBytes');
        final nativeUiPort = request['uiPort'];
        final frameTransport = switch (request['frameTransport']) {
          doomFrameFormatNone => DoomFrameTransport.none,
          doomFrameFormatBmp => DoomFrameTransport.bmp,
          _ => DoomFrameTransport.rgba,
        };
        final maxFrames = asIntOrNull(request['maxFrames']) ?? 0;
        final frameIntervalUs =
            asIntOrNull(request['frameIntervalUs']) ??
            (frameTransport == DoomFrameTransport.rgba
                ? doomNativeTargetFrameIntervalUs
                : 0);
        final inputQueue = DoomSharedInputQueue.fromHandle(
          request['inputQueue'],
          capacity: asIntOrNull(request['inputQueueCapacity']) ?? 256,
        );
        if (inputQueue == null) {
          nativeInputChannel = await DoomNativeInputServer.bind();
          _sendMessage(controller, nativeUiPort, <String, Object?>{
            'type': doomRunnerMessageInputChannel,
            'channel': nativeInputChannel?.handle,
          });
        }

        final runtime = DoomRuntime.withInputDrain(
          emit: (runnerMessage) =>
              _sendMessage(controller, nativeUiPort, runnerMessage),
          frameTransport: frameTransport,
          frameIntervalUs: frameIntervalUs,
          maxFrames: maxFrames,
          drainInput: (queue) {
            inputQueue?.drainInto(queue);
            nativeInputChannel?.drainInto(queue);
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
        await nativeInputChannel?.close();
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
