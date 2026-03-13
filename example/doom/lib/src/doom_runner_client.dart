import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:isolate_manager/isolate_manager.dart';

import 'doom_native_input_channel.dart';
import 'doom_shared_input_queue.dart';
import 'doom_runtime.dart';
import 'doom_worker.dart';

final class DoomRunnerClient {
  DoomRunnerClient();

  final StreamController<DoomRunnerMessage> _messagesController =
      StreamController<DoomRunnerMessage>.broadcast();
  late final Stream<DoomRunnerMessage> messages = _messagesController.stream;
  IsolateManager<Object?, Object?>? _manager;
  DoomSharedInputQueue? _webInputQueue;
  ReceivePort? _nativeMessagePort;
  StreamSubscription<Object?>? _nativeMessageSubscription;
  DoomNativeInputClient? _nativeInputClient;
  bool _stopped = false;

  Future<void> start({
    required Uint8List wasmBytes,
    required Uint8List iwadBytes,
  }) async {
    if (_stopped) {
      return;
    }
    final inputQueue = usesJsInterop ? DoomSharedInputQueue() : null;
    _webInputQueue = inputQueue;
    final unsupportedReason = inputQueue?.unsupportedReason;
    if (unsupportedReason != null) {
      _emit(<String, Object?>{'type': 'log', 'line': unsupportedReason});
    }
    final manager = IsolateManager<Object?, Object?>.createCustom(
      doomRunnerWorker,
      workerName: 'doomRunnerWorker',
    );
    _manager = manager;
    await manager.start();
    if (!usesJsInterop) {
      final nativeMessagePort = ReceivePort();
      _nativeMessagePort = nativeMessagePort;
      _nativeMessageSubscription = nativeMessagePort.listen(
        _handleNativeMessage,
      );
    }
    final run = manager.compute(
      <String, Object?>{
        'type': doomRunnerCommandStart,
        'wasmBytes': wasmBytes,
        'iwadBytes': iwadBytes,
        'frameTransport': usesJsInterop
            ? doomFrameFormatBmp
            : doomFrameFormatRgba,
        'inputQueue': inputQueue?.handle,
        'inputQueueCapacity': inputQueue?.capacity ?? 256,
        if (!usesJsInterop) 'uiPort': _nativeMessagePort!.sendPort,
      },
      callback: usesJsInterop ? _handleWorkerMessage : null,
      transferables: <Object>[wasmBytes.buffer, iwadBytes.buffer],
    );
    unawaited(_watchRunCompletion(run));
  }

  void sendKey(DoomInputEvent event) {
    final inputQueue = _webInputQueue;
    if (inputQueue != null && inputQueue.isSupported) {
      inputQueue.enqueue(event);
      return;
    }
    final nativeInputClient = _nativeInputClient;
    if (nativeInputClient == null || _stopped) {
      return;
    }
    nativeInputClient.send(event);
  }

  Future<void> stop() async {
    _stopped = true;
    final manager = _manager;
    _manager = null;
    _webInputQueue = null;
    final nativeSubscription = _nativeMessageSubscription;
    _nativeMessageSubscription = null;
    await nativeSubscription?.cancel();
    _nativeMessagePort?.close();
    _nativeMessagePort = null;
    final nativeInputClient = _nativeInputClient;
    _nativeInputClient = null;
    await nativeInputClient?.close();
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
        'type': doomRunnerMessageError,
        'error': '$error',
        'stack': '$stackTrace',
      });
    }
  }

  void _handleNativeMessage(Object? rawMessage) {
    final message = normalizeDoomRunnerMessage(rawMessage);
    if (message['type'] == doomRunnerMessageInputChannel) {
      unawaited(_connectNativeInputChannel(message['channel']));
      return;
    }
    _emit(message);
  }

  bool _handleWorkerMessage(Object? rawMessage) {
    final message = normalizeDoomRunnerMessage(rawMessage);
    if (message['type'] == doomRunnerMessageInputChannel) {
      unawaited(_connectNativeInputChannel(message['channel']));
      return false;
    }
    _emit(message);
    final type = message['type'];
    return type == doomRunnerMessageExit || type == doomRunnerMessageError;
  }

  Future<void> _connectNativeInputChannel(Object? handle) async {
    if (_stopped) {
      return;
    }
    final existing = _nativeInputClient;
    _nativeInputClient = null;
    await existing?.close();
    _nativeInputClient = await DoomNativeInputClient.connect(handle);
  }

  void _emit(DoomRunnerMessage message) {
    if (!_messagesController.isClosed) {
      _messagesController.add(message);
    }
  }
}
