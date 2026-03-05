import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wasd/wasm.dart';
import 'package:wasd/wasi.dart';

const String _doomWasmAsset = 'assets/doom/doom.wasm';
const String _doomIwadAsset = 'assets/doom/doom1.wad';
const String _guestRoot = '/doom';
const String _guestIwadName = 'doom1.wad';
const int _doomDefaultWidth = 320;
const int _doomDefaultHeight = 200;

void main() {
  runApp(const _DoomApp());
}

class _DoomApp extends StatelessWidget {
  const _DoomApp();

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
  static const bool _autoStart = bool.fromEnvironment('DOOM_AUTO_START');
  final FocusNode _focusNode = FocusNode();
  final List<String> _logs = <String>[];
  final Queue<_DoomInputEvent> _queuedEvents = Queue<_DoomInputEvent>();

  Uint8List? _frameBytes;
  String? _error;
  bool _running = false;
  int _frameCount = 0;
  Isolate? _nativeRunnerIsolate;
  ReceivePort? _nativeRunnerEvents;
  SendPort? _nativeRunnerControl;
  Memory? _memory;
  _PaletteData? _palette;
  int _windowWidth = _doomDefaultWidth;
  int _windowHeight = _doomDefaultHeight;

  @override
  void initState() {
    super.initState();
    if (_autoStart) {
      scheduleMicrotask(_startGame);
    }
  }

  @override
  void dispose() {
    _stopNativeRunner();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _startGame() async {
    if (_running) {
      return;
    }

    setState(() {
      _running = true;
      _error = null;
      _frameBytes = null;
      _frameCount = 0;
      _memory = null;
      _palette = null;
      _windowWidth = _doomDefaultWidth;
      _windowHeight = _doomDefaultHeight;
      _logs
        ..clear()
        ..add('loading DOOM assets...');
    });

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

      if (!kIsWeb) {
        await _startNativeRunner(wasmBytes, iwadBytes);
        return;
      }

      final preopens = <String, String>{_guestRoot: _guestRoot};
      final files = <String, Uint8List>{
        '$_guestRoot/$_guestIwadName': iwadBytes,
      };

      _appendLog('instantiating module...');
      final wasi = WASI(
        args: <String>[
          'doom.wasm',
          '-file',
          '$_guestRoot/$_guestIwadName',
          '-nosound',
        ],
        preopens: preopens,
        files: files,
        env: <String, String>{
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

      final result = await WebAssembly.instantiate(wasmBytes.buffer, imports);
      final memoryExport = result.instance.exports['memory'];
      if (memoryExport is MemoryImportExportValue) {
        _memory = memoryExport.ref;
      }

      _appendLog('running wasi _start...');
      final exit = wasi.start(result.instance);
      if (!mounted) {
        return;
      }
      setState(() {
        _running = false;
        _logs.add('doom exited: $exit');
      });
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

  Future<void> _startNativeRunner(
    Uint8List wasmBytes,
    Uint8List iwadBytes,
  ) async {
    _stopNativeRunner();
    final events = ReceivePort();
    _nativeRunnerEvents = events;
    _nativeRunnerControl = null;
    events.listen(_onNativeRunnerMessage);
    _appendLog('starting native runner isolate...');
    _nativeRunnerIsolate = await Isolate.spawn<_DoomRunnerBootstrap>(
      _doomRunnerEntryPoint,
      _DoomRunnerBootstrap(events.sendPort, wasmBytes, iwadBytes),
      errorsAreFatal: false,
    );
  }

  void _onNativeRunnerMessage(Object? message) {
    if (!mounted || message is! Map<Object?, Object?>) {
      return;
    }
    final type = message['type'];
    if (type == 'control_port') {
      final port = message['port'];
      if (port is SendPort) {
        _nativeRunnerControl = port;
      }
      return;
    }
    if (type == 'log') {
      final line = message['line'];
      if (line is String) {
        _appendLog(line);
      }
      return;
    }
    if (type == 'frame') {
      final frame = message['frame'];
      final bmp = message['bmp'];
      if (frame is int && bmp is TransferableTypedData) {
        final bytes = bmp.materialize().asUint8List();
        setState(() {
          _frameCount = frame;
          _frameBytes = bytes;
        });
      }
      return;
    }
    if (type == 'exit') {
      final code = message['code'];
      setState(() {
        _running = false;
      });
      _appendLog('doom exited: $code');
      _stopNativeRunner();
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
      _stopNativeRunner();
    }
  }

  void _stopNativeRunner() {
    _nativeRunnerIsolate?.kill(priority: Isolate.immediate);
    _nativeRunnerIsolate = null;
    _nativeRunnerControl = null;
    _nativeRunnerEvents?.close();
    _nativeRunnerEvents = null;
  }

  Future<void> _stopGame() async {
    if (!kIsWeb) {
      _stopNativeRunner();
      setState(() {
        _running = false;
        _logs.add('native runner stopped.');
      });
      return;
    }

    setState(() {
      _running = false;
      _logs.add('stop requested (wasi command modules cannot be interrupted).');
    });
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

    if (!kIsWeb) {
      _nativeRunnerControl?.send(<String, Object?>{
        'type': 'key',
        'keyType': isDown ? 0 : 1,
        'code': code,
      });
      return;
    }

    _queuedEvents.add(_DoomInputEvent(type: isDown ? 0 : 1, code: code));
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

  Object? _onOpenWindow(List<Object?> args) {
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
    if (!mounted || !_running) {
      return 0;
    }
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

    setState(() {
      _frameBytes = bmp;
      _frameCount++;
    });
    return 0;
  }

  Object? _onPendingEvent(List<Object?> args) {
    return _queuedEvents.isNotEmpty ? 1 : 0;
  }

  Object? _onNextEvent(List<Object?> args) {
    final memory = _memory;
    if (memory == null || args.isEmpty || _queuedEvents.isEmpty) {
      return 0;
    }
    final ptr = _asIntOrNull(args.first);
    if (ptr == null || ptr < 0) {
      return 0;
    }

    final event = _queuedEvents.removeFirst();
    final view = ByteData.view(memory.buffer);
    view.setInt32(ptr, event.type, Endian.little);
    view.setInt32(ptr + 4, event.code, Endian.little);
    view.setInt32(ptr + 8, 0, Endian.little);
    view.setInt32(ptr + 12, 0, Endian.little);
    return 0;
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
    return Scaffold(
      appBar: AppBar(
        title: Text('DOOM ($_frameCount)'),
        actions: <Widget>[
          IconButton(
            onPressed: _running ? null : _startGame,
            icon: const Icon(Icons.play_arrow),
          ),
          IconButton(
            onPressed: _running ? _stopGame : null,
            icon: const Icon(Icons.stop),
          ),
        ],
      ),
      body: KeyboardListener(
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
                  ? const Text('Press Play to start DOOM')
                  : Image.memory(
                      frame,
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.none,
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
    );
  }
}

final class _DoomRunnerBootstrap {
  const _DoomRunnerBootstrap(this.events, this.wasmBytes, this.iwadBytes);

  final SendPort events;
  final Uint8List wasmBytes;
  final Uint8List iwadBytes;
}

final class _DoomRunnerWorker {
  _DoomRunnerWorker({
    required SendPort events,
    required Uint8List wasmBytes,
    required Uint8List iwadBytes,
  }) : _events = events,
       _wasmBytes = wasmBytes,
       _iwadBytes = iwadBytes;

  final SendPort _events;
  final Uint8List _wasmBytes;
  final Uint8List _iwadBytes;
  final Queue<_DoomInputEvent> _queuedEvents = Queue<_DoomInputEvent>();

  Memory? _memory;
  _PaletteData? _palette;
  int _windowWidth = _doomDefaultWidth;
  int _windowHeight = _doomDefaultHeight;
  int _frameCount = 0;

  Future<void> run() async {
    try {
      final controlPort = ReceivePort();
      controlPort.listen(_onControlMessage);
      _events.send(<String, Object?>{
        'type': 'control_port',
        'port': controlPort.sendPort,
      });
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
      final memoryExport = result.instance.exports['memory'];
      if (memoryExport is MemoryImportExportValue) {
        _memory = memoryExport.ref;
      }

      _log('running wasi _start...');
      final exit = wasi.start(result.instance);
      _events.send(<String, Object?>{'type': 'exit', 'code': exit});
    } catch (error, stackTrace) {
      _events.send(<String, Object?>{
        'type': 'error',
        'error': '$error',
        'stack': '$stackTrace',
      });
    }
  }

  Object? _onOpenWindow(List<Object?> args) {
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
    _events.send(<String, Object?>{
      'type': 'frame',
      'frame': _frameCount,
      'bmp': TransferableTypedData.fromList(<Uint8List>[bmp]),
    });
    return 0;
  }

  Object? _onPendingEvent(List<Object?> args) =>
      _queuedEvents.isNotEmpty ? 1 : 0;

  Object? _onNextEvent(List<Object?> args) {
    final memory = _memory;
    if (memory == null || args.isEmpty || _queuedEvents.isEmpty) {
      return 0;
    }
    final ptr = _asIntOrNull(args.first);
    if (ptr == null || ptr < 0) {
      return 0;
    }
    final event = _queuedEvents.removeFirst();
    final view = ByteData.view(memory.buffer);
    view.setInt32(ptr, event.type, Endian.little);
    view.setInt32(ptr + 4, event.code, Endian.little);
    view.setInt32(ptr + 8, 0, Endian.little);
    view.setInt32(ptr + 12, 0, Endian.little);
    return 0;
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

  void _log(String line) {
    _events.send(<String, Object?>{'type': 'log', 'line': line});
  }

  void _onControlMessage(Object? message) {
    if (message is! Map<Object?, Object?>) {
      return;
    }
    if (message['type'] != 'key') {
      return;
    }
    final keyType = _asIntOrNull(message['keyType']);
    final code = _asIntOrNull(message['code']);
    if (keyType == null || code == null) {
      return;
    }
    _queuedEvents.add(_DoomInputEvent(type: keyType, code: code));
  }

  void _enqueueBootstrapInput() {
    const int enter = 13;
    const int space = 32;
    _queuedEvents.addAll(const <_DoomInputEvent>[
      _DoomInputEvent(type: 0, code: enter),
      _DoomInputEvent(type: 1, code: enter),
      _DoomInputEvent(type: 0, code: space),
      _DoomInputEvent(type: 1, code: space),
      _DoomInputEvent(type: 0, code: enter),
      _DoomInputEvent(type: 1, code: enter),
    ]);
  }
}

@pragma('vm:entry-point')
Future<void> _doomRunnerEntryPoint(_DoomRunnerBootstrap bootstrap) async {
  final runner = _DoomRunnerWorker(
    events: bootstrap.events,
    wasmBytes: bootstrap.wasmBytes,
    iwadBytes: bootstrap.iwadBytes,
  );
  await runner.run();
}

final class _DoomInputEvent {
  const _DoomInputEvent({required this.type, required this.code});

  final int type;
  final int code;
}

int? _asIntOrNull(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return null;
}

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
  final clamped = value.clamp(0, 63) as int;
  return (clamped << 2) | (clamped >> 4);
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
