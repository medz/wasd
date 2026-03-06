import 'dart:async';
import 'dart:collection';
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ffi/ffi.dart' as pkg_ffi;
import 'package:wasd/wasm.dart';
import 'package:wasd/wasi.dart';

const String _doomWasmAsset = 'assets/doom/doom.wasm';
const String _doomIwadAsset = 'assets/doom/doom1.wad';
const String _guestRoot = '/doom';
const String _guestIwadName = 'doom1.wad';
const int _doomDefaultWidth = 320;
const int _doomDefaultHeight = 200;
const int _runnerStoppedExitCode = -1;
const String _webTargetRemovedMessage =
    'DOOM web target has been removed. Run this example on desktop.';

void main() {
  runApp(const DoomApp());
}

class DoomApp extends StatelessWidget {
  const DoomApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'DOOM Flutter',
      theme: ThemeData.dark(useMaterial3: true),
      home: const _DoomPage(),
    );
  }
}

class _DoomPage extends StatefulWidget {
  const _DoomPage();

  @override
  State<_DoomPage> createState() => _DoomPageState();
}

class _DoomPageState extends State<_DoomPage> {
  static const bool _autoStart =
      bool.fromEnvironment('DOOM_AUTO_START', defaultValue: true) &&
      !bool.fromEnvironment('FLUTTER_TEST');
  final FocusNode _focusNode = FocusNode();
  final List<String> _logs = <String>[];

  Uint8List? _frameBytes;
  String? _error;
  bool _running = false;
  _DoomRunnerClient? _runner;
  StreamSubscription<_DoomRunnerMessage>? _runnerMessages;

  @override
  void initState() {
    super.initState();
    _requestGameFocus();
    if (_autoStart) {
      scheduleMicrotask(_startGame);
    }
  }

  @override
  void dispose() {
    unawaited(_stopRunner());
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _startGame() async {
    if (_running) {
      return;
    }

    if (kIsWeb) {
      setState(() {
        _running = false;
        _error = _webTargetRemovedMessage;
        _logs
          ..clear()
          ..add(_webTargetRemovedMessage);
      });
      return;
    }

    setState(() {
      _running = true;
      _error = null;
      _frameBytes = null;
      _logs
        ..clear()
        ..add('loading DOOM assets...');
    });
    _requestGameFocus();

    try {
      final wasmData = await rootBundle.load(_doomWasmAsset);
      final iwadData = await rootBundle.load(_doomIwadAsset);
      final wasmBytes = Uint8List.fromList(
        wasmData.buffer.asUint8List(
          wasmData.offsetInBytes,
          wasmData.lengthInBytes,
        ),
      );
      final iwadBytes = Uint8List.fromList(
        iwadData.buffer.asUint8List(
          iwadData.offsetInBytes,
          iwadData.lengthInBytes,
        ),
      );
      await _startRunner(wasmBytes, iwadBytes);
    } catch (error, stackTrace) {
      if (!mounted) {
        return;
      }
      setState(() {
        _running = false;
        _error = '$error';
      });
      _appendLog('$error\n$stackTrace');
    }
  }

  Future<void> _startRunner(Uint8List wasmBytes, Uint8List iwadBytes) async {
    await _stopRunner();
    final runner = _DoomRunnerClient(
      wasmBytes: wasmBytes,
      iwadBytes: iwadBytes,
    );
    _runner = runner;
    _runnerMessages = runner.messages.listen(_onRunnerMessage);
    try {
      await runner.start();
    } catch (_) {
      await _stopRunner();
      rethrow;
    }
  }

  void _onRunnerMessage(_DoomRunnerMessage message) {
    if (!mounted) {
      return;
    }
    final type = message['type'];
    if (type == 'log') {
      final line = message['line'];
      if (line is String) {
        _appendLog(line);
      }
      return;
    }
    if (type == 'frame') {
      final bmp = message['bmp'];
      if (bmp is Uint8List) {
        setState(() {
          _frameBytes = bmp;
        });
      }
      return;
    }
    if (type == 'exit') {
      final code = message['code'];
      setState(() {
        _running = false;
      });
      if (code != _runnerStoppedExitCode) {
        _appendLog('doom exited: $code');
      }
      unawaited(_stopRunner());
      return;
    }
    if (type == 'error') {
      final error = message['error'];
      setState(() {
        _running = false;
        _error = '$error';
      });
      final stack = message['stack'];
      _appendLog('$error\n$stack');
      unawaited(_stopRunner());
    }
  }

  Future<void> _stopRunner() async {
    final subscription = _runnerMessages;
    _runnerMessages = null;
    await subscription?.cancel();

    final runner = _runner;
    _runner = null;
    await runner?.stop();
  }

  void _sendKeyEvent(KeyEvent event) {
    if (!_running) {
      return;
    }

    final code = _mapDoomKey(event.logicalKey);
    if (code == null) {
      return;
    }

    final isDown = switch (event) {
      KeyDownEvent() => true,
      KeyRepeatEvent() => true,
      KeyUpEvent() => false,
      _ => false,
    };

    _dispatchInputEvent(_DoomInputEvent(type: isDown ? 0 : 1, code: code));
  }

  void _dispatchInputEvent(_DoomInputEvent event) {
    _runner?.sendKey(event);
  }

  void _requestGameFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  void _onTapGameSurface(TapDownDetails _) {
    _requestGameFocus();
    if (_running) {
      _dispatchInputEvent(const _DoomInputEvent(type: 0, code: 32));
    }
  }

  void _onTapGameSurfaceUp(TapUpDetails _) {
    if (_running) {
      _dispatchInputEvent(const _DoomInputEvent(type: 1, code: 32));
    }
  }

  int? _mapDoomKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowRight) return 0xae;
    if (key == LogicalKeyboardKey.arrowLeft) return 0xac;
    if (key == LogicalKeyboardKey.arrowUp) return 0xad;
    if (key == LogicalKeyboardKey.arrowDown) return 0xaf;
    if (key == LogicalKeyboardKey.escape) return 27;
    if (key == LogicalKeyboardKey.enter) return 13;
    if (key == LogicalKeyboardKey.space) return 32;
    if (key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight) {
      return 0x80 + 0x36;
    }
    if (key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight) {
      return 0x80 + 0x1d;
    }
    if (key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight) {
      return 0x80 + 0x38;
    }

    final label = key.keyLabel;
    if (label.length == 1) {
      return label.toLowerCase().codeUnitAt(0);
    }
    return null;
  }

  void _appendLog(String line) {
    if (!mounted) {
      return;
    }
    setState(() {
      _logs.add(line);
      if (_logs.length > 200) {
        _logs.removeRange(0, _logs.length - 200);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final frame = _frameBytes;
    final frameSize = _decodeBmpDimensions(frame);
    final frameWidth = (frameSize?.$1 ?? _doomDefaultWidth).toDouble();
    final frameHeight = (frameSize?.$2 ?? _doomDefaultHeight).toDouble();
    return Scaffold(
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _onTapGameSurface,
        onTapUp: _onTapGameSurfaceUp,
        child: KeyboardListener(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _sendKeyEvent,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: frame == null
                    ? Text(_running ? 'Booting DOOM...' : 'DOOM is not running')
                    : SizedBox.expand(
                        child: FittedBox(
                          fit: BoxFit.contain,
                          child: SizedBox(
                            width: frameWidth,
                            height: frameHeight,
                            child: Image.memory(
                              frame,
                              gaplessPlayback: true,
                              filterQuality: FilterQuality.none,
                              fit: BoxFit.fill,
                            ),
                          ),
                        ),
                      ),
              ),
              if (_error != null)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    margin: const EdgeInsets.all(12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    color: const Color(0xCC330000),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

typedef _DoomRunnerMessage = Map<String, Object?>;

abstract interface class _DoomRunnerClient {
  factory _DoomRunnerClient({
    required Uint8List wasmBytes,
    required Uint8List iwadBytes,
  }) {
    if (kIsWeb) {
      return _UnsupportedDoomRunnerClient();
    }
    return _IsolateDoomRunnerClient(wasmBytes: wasmBytes, iwadBytes: iwadBytes);
  }

  Stream<_DoomRunnerMessage> get messages;

  Future<void> start();

  void sendKey(_DoomInputEvent event);

  Future<void> stop();
}

final class _UnsupportedDoomRunnerClient implements _DoomRunnerClient {
  final StreamController<_DoomRunnerMessage> _messagesController =
      StreamController<_DoomRunnerMessage>.broadcast(sync: true);
  bool _stopped = false;

  @override
  Stream<_DoomRunnerMessage> get messages => _messagesController.stream;

  @override
  Future<void> start() async {
    throw UnsupportedError(_webTargetRemovedMessage);
  }

  @override
  void sendKey(_DoomInputEvent event) {}

  @override
  Future<void> stop() async {
    if (_stopped) {
      return;
    }
    _stopped = true;
    await _messagesController.close();
  }
}

final class _IsolateDoomRunnerClient implements _DoomRunnerClient {
  _IsolateDoomRunnerClient({
    required Uint8List wasmBytes,
    required Uint8List iwadBytes,
  }) : _wasmBytes = wasmBytes,
       _iwadBytes = iwadBytes;

  final Uint8List _wasmBytes;
  final Uint8List _iwadBytes;
  final StreamController<_DoomRunnerMessage> _messagesController =
      StreamController<_DoomRunnerMessage>.broadcast();
  final _SharedInputBuffer _sharedInputBuffer = _SharedInputBuffer.allocate();

  Isolate? _isolate;
  ReceivePort? _events;
  StreamSubscription<Object?>? _eventSubscription;
  bool _stopped = false;

  @override
  Stream<_DoomRunnerMessage> get messages => _messagesController.stream;

  @override
  Future<void> start() async {
    if (_stopped || _isolate != null) {
      return;
    }
    final events = ReceivePort();
    _events = events;
    _eventSubscription = events.listen(_onNativeMessage);
    _isolate = await Isolate.spawn<_DoomRunnerBootstrap>(
      _doomRunnerEntryPoint,
      _DoomRunnerBootstrap(
        events.sendPort,
        _wasmBytes,
        _iwadBytes,
        _sharedInputBuffer.address,
        _sharedInputBuffer.capacity,
      ),
      errorsAreFatal: false,
    );
  }

  @override
  void sendKey(_DoomInputEvent event) {
    _sharedInputBuffer.enqueue(event);
  }

  @override
  Future<void> stop() async {
    if (_stopped) {
      return;
    }
    _stopped = true;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sharedInputBuffer.dispose();

    final subscription = _eventSubscription;
    _eventSubscription = null;
    await subscription?.cancel();
    _events?.close();
    _events = null;
    await _messagesController.close();
  }

  void _onNativeMessage(Object? message) {
    if (message is! Map<Object?, Object?>) {
      return;
    }
    final type = message['type'];
    if (type == 'frame') {
      final frame = _asIntOrNull(message['frame']);
      final bmp = message['bmp'];
      if (frame is int && bmp is TransferableTypedData) {
        _emit(<String, Object?>{
          'type': 'frame',
          'frame': frame,
          'bmp': bmp.materialize().asUint8List(),
        });
        return;
      }
    }
    _emit(_normalizeMessage(message));
  }

  _DoomRunnerMessage _normalizeMessage(Map<Object?, Object?> message) {
    final normalized = <String, Object?>{};
    for (final entry in message.entries) {
      final key = entry.key;
      if (key is String) {
        normalized[key] = entry.value;
      }
    }
    return normalized;
  }

  void _emit(_DoomRunnerMessage message) {
    if (!_messagesController.isClosed) {
      _messagesController.add(message);
    }
  }
}

final class _DoomRunnerBootstrap {
  const _DoomRunnerBootstrap(
    this.events,
    this.wasmBytes,
    this.iwadBytes,
    this.inputBufferAddress,
    this.inputBufferCapacity,
  );

  final SendPort events;
  final Uint8List wasmBytes;
  final Uint8List iwadBytes;
  final int inputBufferAddress;
  final int inputBufferCapacity;
}

final class _DoomRunnerWorker {
  _DoomRunnerWorker({
    required void Function(_DoomRunnerMessage message) emit,
    required Uint8List wasmBytes,
    required Uint8List iwadBytes,
    _SharedInputBufferReader? sharedInputReader,
  }) : _emit = emit,
       _wasmBytes = wasmBytes,
       _iwadBytes = iwadBytes,
       _sharedInputReader = sharedInputReader;

  final void Function(_DoomRunnerMessage message) _emit;
  final Uint8List _wasmBytes;
  final Uint8List _iwadBytes;
  final _SharedInputBufferReader? _sharedInputReader;
  final Queue<_DoomInputEvent> _queuedEvents = Queue<_DoomInputEvent>();

  Memory? _memory;
  _PaletteData? _palette;
  int _windowWidth = _doomDefaultWidth;
  int _windowHeight = _doomDefaultHeight;
  int _frameCount = 0;
  bool _stopRequested = false;

  void enqueueInput(_DoomInputEvent event) {
    _queuedEvents.add(event);
  }

  void requestStop() {
    _stopRequested = true;
  }

  Future<void> run() async {
    try {
      _ensureRunning();
      _log('instantiating module...');
      _enqueueBootstrapInput();
      final wasi = WASI(
        args: const <String>[
          'doom.wasm',
          '-file',
          '$_guestRoot/$_guestIwadName',
          '-nosound',
        ],
        preopens: const <String, String>{_guestRoot: _guestRoot},
        files: <String, Uint8List>{'$_guestRoot/$_guestIwadName': _iwadBytes},
        env: const <String, String>{
          'HOME': _guestRoot,
          'TERM': 'xterm',
          'DOOMWADDIR': _guestRoot,
          'DOOMWADPATH': _guestRoot,
        },
      );

      final imports = <String, ModuleImports>{
        ...wasi.imports,
        'env': <String, ImportValue>{
          'ZwareDoomOpenWindow': ImportExportKind.function(_onOpenWindow),
          'ZwareDoomSetPalette': ImportExportKind.function(_onSetPalette),
          'ZwareDoomRenderFrame': ImportExportKind.function(_onRenderFrame),
          'ZwareDoomPendingEvent': ImportExportKind.function(_onPendingEvent),
          'ZwareDoomNextEvent': ImportExportKind.function(_onNextEvent),
        },
      };

      final result = await WebAssembly.instantiate(_wasmBytes.buffer, imports);
      _ensureRunning();
      final memoryExport = result.instance.exports['memory'];
      if (memoryExport is MemoryImportExportValue) {
        _memory = memoryExport.ref;
      }

      _log('running wasi _start...');
      final exit = wasi.start(result.instance);
      _emit(<String, Object?>{'type': 'exit', 'code': exit});
    } on _DoomRunnerStopRequested {
      _emit(<String, Object?>{'type': 'exit', 'code': _runnerStoppedExitCode});
    } catch (error, stackTrace) {
      _emit(<String, Object?>{
        'type': 'error',
        'error': '$error',
        'stack': '$stackTrace',
      });
    }
  }

  Object? _onOpenWindow(List<Object?> args) {
    _ensureRunning();
    final values = args
        .map(_asIntOrNull)
        .whereType<int>()
        .toList(growable: false);
    if (values.length >= 2) {
      if (_isLikelyResolution(values[0], values[1])) {
        _windowWidth = values[0];
        _windowHeight = values[1];
      } else if (_isLikelyResolution(values[1], values[0])) {
        _windowWidth = values[1];
        _windowHeight = values[0];
      }
    }
    return 0;
  }

  Object? _onSetPalette(List<Object?> args) {
    _ensureRunning();
    final memory = _memory;
    if (memory == null || args.isEmpty) {
      return 0;
    }
    final ptr = _asIntOrNull(args.first);
    if (ptr == null || ptr < 0) {
      return 0;
    }
    final bytes = Uint8List.view(memory.buffer);
    final hint = args.length > 1 ? _asIntOrNull(args[1]) : null;
    final palette = _extractPalette(bytes, ptr, hint);
    if (palette == null) {
      return 0;
    }
    _palette = palette;
    return 0;
  }

  Object? _onRenderFrame(List<Object?> args) {
    _ensureRunning();
    final memory = _memory;
    if (memory == null) {
      return 0;
    }

    final bytes = Uint8List.view(memory.buffer);
    final resolution = _resolveResolution(args);
    final width = resolution.$1;
    final height = resolution.$2;
    final pixelCount = width * height;
    if (pixelCount <= 0 || pixelCount > bytes.length) {
      return 0;
    }

    final ptr = _resolveFramePointer(args, pixelCount, bytes.length);
    if (ptr == null) {
      return 0;
    }

    final indexed = Uint8List.fromList(bytes.sublist(ptr, ptr + pixelCount));
    final rgb = _indexedToRgb(indexed, _palette);
    final bmp = _encodeBmp24(width: width, height: height, rgb: rgb);
    _frameCount++;
    if (_frameCount == 1) {
      _log('received first frame');
    }
    _emit(<String, Object?>{'type': 'frame', 'frame': _frameCount, 'bmp': bmp});
    return 0;
  }

  Object? _onPendingEvent(List<Object?> args) {
    _ensureRunning();
    _sharedInputReader?.drainInto(_queuedEvents);
    return _queuedEvents.isNotEmpty ? 1 : 0;
  }

  Object? _onNextEvent(List<Object?> args) {
    _ensureRunning();
    _sharedInputReader?.drainInto(_queuedEvents);
    final memory = _memory;
    if (memory == null || args.isEmpty || _queuedEvents.isEmpty) {
      return 0;
    }
    final event = _queuedEvents.removeFirst();
    final view = ByteData.view(memory.buffer);
    if (args.length >= 4) {
      final typePtr = _asIntOrNull(args[0]);
      final data1Ptr = _asIntOrNull(args[1]);
      final data2Ptr = _asIntOrNull(args[2]);
      final data3Ptr = _asIntOrNull(args[3]);
      if (!_isI32PointerInBounds(typePtr, view) ||
          !_isI32PointerInBounds(data1Ptr, view) ||
          !_isI32PointerInBounds(data2Ptr, view) ||
          !_isI32PointerInBounds(data3Ptr, view)) {
        return 0;
      }
      view.setInt32(typePtr!, event.type, Endian.little);
      view.setInt32(data1Ptr!, event.code, Endian.little);
      view.setInt32(data2Ptr!, 0, Endian.little);
      view.setInt32(data3Ptr!, 0, Endian.little);
      return 1;
    }

    final ptr = _asIntOrNull(args.first);
    if (!_isI32PointerInBounds(ptr, view) || ptr! + 16 > view.lengthInBytes) {
      return 0;
    }
    view.setInt32(ptr, event.type, Endian.little);
    view.setInt32(ptr + 4, event.code, Endian.little);
    view.setInt32(ptr + 8, 0, Endian.little);
    view.setInt32(ptr + 12, 0, Endian.little);
    return 1;
  }

  (int, int) _resolveResolution(List<Object?> args) {
    final ints = args
        .map(_asIntOrNull)
        .whereType<int>()
        .toList(growable: false);
    for (var i = 0; i + 1 < ints.length; i++) {
      final a = ints[i];
      final b = ints[i + 1];
      if (_isLikelyResolution(a, b)) {
        _windowWidth = a;
        _windowHeight = b;
      } else if (_isLikelyResolution(b, a)) {
        _windowWidth = b;
        _windowHeight = a;
      }
    }
    return (_windowWidth, _windowHeight);
  }

  int? _resolveFramePointer(
    List<Object?> args,
    int pixelCount,
    int memoryLength,
  ) {
    for (final arg in args) {
      final value = _asIntOrNull(arg);
      if (value != null && value >= 0 && value + pixelCount <= memoryLength) {
        return value;
      }
    }
    if (pixelCount <= memoryLength) {
      return 0;
    }
    return null;
  }

  void _ensureRunning() {
    if (_stopRequested) {
      throw const _DoomRunnerStopRequested();
    }
  }

  void _log(String line) {
    _emit(<String, Object?>{'type': 'log', 'line': line});
  }

  void _enqueueBootstrapInput() {
    _enqueueBootstrapInputQueue(_queuedEvents);
  }
}

final class _DoomRunnerStopRequested {
  const _DoomRunnerStopRequested();
}

@pragma('vm:entry-point')
Future<void> _doomRunnerEntryPoint(_DoomRunnerBootstrap bootstrap) async {
  final runner = _DoomRunnerWorker(
    wasmBytes: bootstrap.wasmBytes,
    iwadBytes: bootstrap.iwadBytes,
    sharedInputReader: _SharedInputBufferReader(
      address: bootstrap.inputBufferAddress,
      capacity: bootstrap.inputBufferCapacity,
    ),
    emit: (_DoomRunnerMessage message) {
      if (message['type'] == 'frame') {
        final bmp = message['bmp'];
        if (bmp is Uint8List) {
          bootstrap.events.send(<String, Object?>{
            ...message,
            'bmp': TransferableTypedData.fromList(<Uint8List>[bmp]),
          });
          return;
        }
      }
      bootstrap.events.send(message);
    },
  );
  await runner.run();
}

final class _DoomInputEvent {
  const _DoomInputEvent({required this.type, required this.code});

  final int type;
  final int code;
}

final class _SharedInputBuffer {
  _SharedInputBuffer._(this._pointer, this.capacity)
    : _view = _pointer.asTypedList(_headerSize + capacity * 2) {
    _view[0] = 0; // write index
    _view[1] = 0; // read index
    _view[2] = capacity;
  }

  static const int _headerSize = 3;
  static const int _defaultCapacity = 256;

  static _SharedInputBuffer allocate({int capacity = _defaultCapacity}) {
    final pointer = pkg_ffi.calloc<ffi.Int32>(_headerSize + capacity * 2);
    return _SharedInputBuffer._(pointer, capacity);
  }

  final ffi.Pointer<ffi.Int32> _pointer;
  final Int32List _view;
  final int capacity;
  bool _disposed = false;

  int get address => _pointer.address;

  void enqueue(_DoomInputEvent event) {
    if (_disposed) {
      return;
    }
    var write = _view[0];
    var read = _view[1];
    final nextWrite = (write + 1) % capacity;
    if (nextWrite == read) {
      read = (read + 1) % capacity;
      _view[1] = read;
    }

    final base = _headerSize + write * 2;
    _view[base] = event.type;
    _view[base + 1] = event.code;
    _view[0] = nextWrite;
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    pkg_ffi.calloc.free(_pointer);
  }
}

final class _SharedInputBufferReader {
  _SharedInputBufferReader({required int address, required this.capacity})
    : _view = ffi.Pointer<ffi.Int32>.fromAddress(
        address,
      ).asTypedList(_SharedInputBuffer._headerSize + capacity * 2);

  final Int32List _view;
  final int capacity;

  void drainInto(Queue<_DoomInputEvent> queue) {
    var read = _view[1];
    final write = _view[0];
    while (read != write) {
      final base = _SharedInputBuffer._headerSize + read * 2;
      queue.add(_DoomInputEvent(type: _view[base], code: _view[base + 1]));
      read = (read + 1) % capacity;
    }
    _view[1] = read;
  }
}

void _enqueueBootstrapInputQueue(Queue<_DoomInputEvent> queue) {
  const int enter = 13;
  const int space = 32;
  queue.addAll(const <_DoomInputEvent>[
    _DoomInputEvent(type: 0, code: enter),
    _DoomInputEvent(type: 1, code: enter),
    _DoomInputEvent(type: 0, code: space),
    _DoomInputEvent(type: 1, code: space),
    _DoomInputEvent(type: 0, code: enter),
    _DoomInputEvent(type: 1, code: enter),
  ]);
}

int? _asIntOrNull(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is BigInt) {
    return value.toInt();
  }
  return null;
}

bool _isI32PointerInBounds(int? ptr, ByteData view) =>
    ptr != null && ptr >= 0 && ptr + 4 <= view.lengthInBytes;

bool _isLikelyResolution(int width, int height) =>
    width >= 64 && height >= 64 && width <= 4096 && height <= 4096;

Uint8List _indexedToRgb(Uint8List indexed, _PaletteData? palette) {
  final rgb = Uint8List(indexed.length * 3);
  if (palette == null || palette.bytes.length < 3) {
    for (var i = 0; i < indexed.length; i++) {
      final value = indexed[i];
      final base = i * 3;
      rgb[base] = value;
      rgb[base + 1] = value;
      rgb[base + 2] = value;
    }
    return rgb;
  }

  final colorCount = palette.bytes.length ~/ palette.stride;
  for (var i = 0; i < indexed.length; i++) {
    final idx = indexed[i] % colorCount;
    final src = idx * palette.stride;
    final dst = i * 3;
    var r = palette.bytes[src];
    var g = palette.bytes[src + 1];
    var b = palette.bytes[src + 2];
    if (palette.isSixBit) {
      r = _paletteExpand6To8(r);
      g = _paletteExpand6To8(g);
      b = _paletteExpand6To8(b);
    }
    rgb[dst] = r;
    rgb[dst + 1] = g;
    rgb[dst + 2] = b;
  }
  return rgb;
}

_PaletteData? _extractPalette(Uint8List memory, int ptr, int? hint) {
  if (ptr < 0 || ptr >= memory.length) {
    return null;
  }
  final available = memory.length - ptr;
  if (available < 3) {
    return null;
  }

  var stride = 3;
  var length = 256 * 3;

  if (hint != null && hint > 0) {
    if (hint <= 256 && hint * 3 <= available) {
      stride = 3;
      length = hint * 3;
    } else if (hint <= available) {
      if (hint == 1024 || (hint % 4 == 0 && hint >= 256 && hint <= 2048)) {
        stride = 4;
        length = hint;
      } else if (hint % 3 == 0) {
        stride = 3;
        length = hint;
      } else if (hint > 1024 && 1024 <= available) {
        stride = 4;
        length = 1024;
      } else if (768 <= available) {
        stride = 3;
        length = 768;
      } else {
        return null;
      }
    }
  } else if (1024 <= available) {
    stride = 4;
    length = 1024;
  } else if (768 <= available) {
    stride = 3;
    length = 768;
  } else {
    length = (available ~/ 3) * 3;
    stride = 3;
  }

  if (ptr + length > memory.length || length < stride * 2) {
    return null;
  }
  final bytes = Uint8List.fromList(memory.sublist(ptr, ptr + length));
  return _PaletteData(
    bytes: bytes,
    stride: stride,
    isSixBit: _isLikelySixBitPalette(bytes, stride),
  );
}

bool _isLikelySixBitPalette(Uint8List bytes, int stride) {
  var max = 0;
  for (var i = 0; i + 2 < bytes.length; i += stride) {
    final r = bytes[i];
    final g = bytes[i + 1];
    final b = bytes[i + 2];
    if (r > max) max = r;
    if (g > max) max = g;
    if (b > max) max = b;
    if (max > 63) {
      return false;
    }
  }
  return true;
}

int _paletteExpand6To8(int value) {
  final clamped = value.clamp(0, 63);
  return (clamped << 2) | (clamped >> 4);
}

(int, int)? _decodeBmpDimensions(Uint8List? bmp) {
  if (bmp == null || bmp.length < 26) {
    return null;
  }
  if (bmp[0] != 0x42 || bmp[1] != 0x4d) {
    return null;
  }
  final view = ByteData.sublistView(bmp);
  final width = view.getInt32(18, Endian.little);
  final height = view.getInt32(22, Endian.little).abs();
  if (width <= 0 || height <= 0) {
    return null;
  }
  return (width, height);
}

final class _PaletteData {
  const _PaletteData({
    required this.bytes,
    required this.stride,
    required this.isSixBit,
  });

  final Uint8List bytes;
  final int stride;
  final bool isSixBit;
}

Uint8List _encodeBmp24({
  required int width,
  required int height,
  required Uint8List rgb,
}) {
  final rowStride = width * 3;
  final rowPad = (4 - (rowStride % 4)) % 4;
  final pixelBytes = (rowStride + rowPad) * height;
  final headerBytes = 54;
  final fileSize = headerBytes + pixelBytes;

  final out = Uint8List(fileSize);
  final data = ByteData.view(out.buffer);

  data.setUint8(0, 0x42);
  data.setUint8(1, 0x4d);
  data.setUint32(2, fileSize, Endian.little);
  data.setUint32(10, headerBytes, Endian.little);
  data.setUint32(14, 40, Endian.little);
  data.setInt32(18, width, Endian.little);
  data.setInt32(22, height, Endian.little);
  data.setUint16(26, 1, Endian.little);
  data.setUint16(28, 24, Endian.little);
  data.setUint32(34, pixelBytes, Endian.little);
  data.setInt32(38, 2835, Endian.little);
  data.setInt32(42, 2835, Endian.little);

  var dst = headerBytes;
  for (var y = height - 1; y >= 0; y--) {
    final srcRow = y * rowStride;
    for (var x = 0; x < width; x++) {
      final src = srcRow + x * 3;
      out[dst++] = rgb[src + 2];
      out[dst++] = rgb[src + 1];
      out[dst++] = rgb[src];
    }
    for (var p = 0; p < rowPad; p++) {
      out[dst++] = 0;
    }
  }
  return out;
}
