import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:isolate_manager/isolate_manager.dart';

import 'doom_shared_input_queue.dart';
import 'doom_runtime.dart';
import 'doom_worker.dart';

final class DoomRunnerClient {
  DoomRunnerClient();

  final StreamController<DoomRunnerMessage> _messagesController =
      StreamController<DoomRunnerMessage>.broadcast();
  late final Stream<DoomRunnerMessage> messages = _messagesController.stream;
  IsolateManager<Object?, Object?>? _manager;
  DoomSharedInputQueue? _inputQueue;
  SendPort? _nativeInputPort;
  bool _stopped = false;

  Future<void> start({
    required Uint8List wasmBytes,
    required Uint8List iwadBytes,
  }) async {
    if (_stopped) {
      return;
    }
    final inputQueue = DoomSharedInputQueue();
    _inputQueue = inputQueue;
    final unsupportedReason = inputQueue.unsupportedReason;
    if (unsupportedReason != null) {
      _emit(<String, Object?>{'type': 'log', 'line': unsupportedReason});
    }
    final manager = IsolateManager<Object?, Object?>.createCustom(
      doomRunnerWorker,
      workerName: 'doomRunnerWorker',
    );
    _manager = manager;
    await manager.start();
    final run = manager.compute(
      <String, Object?>{
        'type': doomRunnerCommandStart,
        'wasmBytes': wasmBytes,
        'iwadBytes': iwadBytes,
        'inputQueue': inputQueue.handle,
        'inputQueueCapacity': inputQueue.capacity,
      },
      callback: _handleWorkerMessage,
      transferables: <Object>[wasmBytes.buffer, iwadBytes.buffer],
    );
    unawaited(_watchRunCompletion(run));
  }

  void sendKey(DoomInputEvent event) {
    final inputQueue = _inputQueue;
    if (inputQueue != null && inputQueue.isSupported) {
      inputQueue.enqueue(event);
      return;
    }
    final nativeInputPort = _nativeInputPort;
    if (nativeInputPort == null || _stopped) {
      return;
    }
    nativeInputPort.send(event.toMessage());
  }

  Future<void> stop() async {
    _stopped = true;
    final manager = _manager;
    _manager = null;
    _inputQueue = null;
    _nativeInputPort = null;
    await manager?.stop();
    await _messagesController.close();
  }

  Future<void> _watchRunCompletion(Future<Object?> run) async {
    try {
      await run;
    } catch (error, stackTrace) {
      if (_stopped) {
        return;
      }
      _emit(<String, Object?>{
        'type': 'error',
        'error': '$error',
        'stack': '$stackTrace',
      });
    }
  }

  bool _handleWorkerMessage(Object? rawMessage) {
    final message = normalizeDoomRunnerMessage(rawMessage);
    if (message['type'] == 'input-port') {
      final port = message['port'];
      if (port is SendPort) {
        _nativeInputPort = port;
      }
      return false;
    }
    _emit(message);
    final type = message['type'];
    return type == 'exit' || type == 'error';
  }

  void _emit(DoomRunnerMessage message) {
    if (!_messagesController.isClosed) {
      _messagesController.add(message);
    }
  }
}
