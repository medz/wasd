import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pure_wasm_runtime/pure_wasm_runtime.dart';

const String _doomWasmAssetPath = 'assets/doom/doom.wasm';
const String _doomIwadAssetPath = 'assets/doom/doom1.wad';

const int _doomWidth = 320;
const int _doomHeight = 200;

const int _eventTypeKeyDown = 0;
const int _eventTypeKeyUp = 1;

const int _doomKeyRight = 0xae;
const int _doomKeyLeft = 0xac;
const int _doomKeyUp = 0xad;
const int _doomKeyDown = 0xaf;
const int _doomKeyEscape = 27;
const int _doomKeyEnter = 13;
const int _doomKeyTab = 9;
const int _doomKeyBackspace = 127;
const int _doomKeyCtrl = 0x9d;
const int _doomKeyAlt = 0xb8;
const int _doomKeyShift = 0xb6;

void main() {
  runApp(const DoomWindowApp());
}

final class DoomWindowApp extends StatelessWidget {
  const DoomWindowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Doom Wasm Window',
      theme: ThemeData.dark(useMaterial3: true),
      home: const DoomWindowPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

final class DoomWindowPage extends StatefulWidget {
  const DoomWindowPage({super.key});

  @override
  State<DoomWindowPage> createState() => _DoomWindowPageState();
}

final class _DoomWindowPageState extends State<DoomWindowPage> {
  ReceivePort? _receivePort;
  Isolate? _doomIsolate;
  RandomAccessFile? _eventWriter;
  File? _eventFile;

  ui.Image? _frameImage;
  bool _decodingFrame = false;
  int _frames = 0;
  String _status = 'Starting Doom runtime...';

  @override
  void initState() {
    super.initState();
    _startDoom();
  }

  @override
  void dispose() {
    _frameImage?.dispose();
    _frameImage = null;
    _doomIsolate?.kill(priority: Isolate.immediate);
    _receivePort?.close();
    _eventWriter?.closeSync();
    final eventFile = _eventFile;
    if (eventFile != null && eventFile.existsSync()) {
      eventFile.deleteSync();
    }
    super.dispose();
  }

  Future<void> _startDoom() async {
    final wasmBytes = await _loadAssetBytes(_doomWasmAssetPath);
    final iwadBytes = await _loadAssetBytes(_doomIwadAssetPath);
    if (wasmBytes == null || iwadBytes == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status =
            'Missing bundled assets.\n'
            'Put doom.wasm + doom1.wad under doom_window/assets/doom/\n'
            'and run: tool/sync_assets.sh && flutter pub get';
      });
      return;
    }

    final eventFile = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'doom_window_events_${DateTime.now().microsecondsSinceEpoch}.bin',
    );
    eventFile.createSync(recursive: true);
    final eventWriter = eventFile.openSync(mode: FileMode.writeOnlyAppend);

    final receivePort = ReceivePort();
    receivePort.listen(_onIsolateMessage);

    _eventFile = eventFile;
    _eventWriter = eventWriter;
    _receivePort = receivePort;

    _doomIsolate = await Isolate.spawn<Map<String, Object?>>(_doomIsolateMain, {
      'uiPort': receivePort.sendPort,
      'eventFilePath': eventFile.path,
      'wasmBytes': TransferableTypedData.fromList(<Uint8List>[wasmBytes]),
      'iwadBytes': TransferableTypedData.fromList(<Uint8List>[iwadBytes]),
    });
  }

  Future<Uint8List?> _loadAssetBytes(String key) async {
    try {
      final data = await rootBundle.load(key);
      return Uint8List.fromList(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } on FlutterError {
      return null;
    }
  }

  void _onIsolateMessage(Object? message) {
    if (!mounted || message is! Map<Object?, Object?>) {
      return;
    }
    final type = message['type'];
    if (type == 'status') {
      final text = message['text'] as String? ?? '';
      setState(() {
        _status = text;
      });
      return;
    }
    if (type == 'error') {
      final text = message['text'] as String? ?? 'Unknown error';
      setState(() {
        _status = 'Runtime error: $text';
      });
      return;
    }
    if (type == 'exit') {
      final text = message['text'] as String? ?? 'Runtime stopped';
      setState(() {
        _status = text;
      });
      return;
    }
    if (type == 'frame') {
      if (_decodingFrame) {
        return;
      }
      final data = message['rgba'];
      if (data is! TransferableTypedData) {
        return;
      }
      final bytes = data.materialize().asUint8List();
      _decodingFrame = true;
      ui.decodeImageFromPixels(
        bytes,
        _doomWidth,
        _doomHeight,
        ui.PixelFormat.rgba8888,
        (image) {
          _decodingFrame = false;
          if (!mounted) {
            image.dispose();
            return;
          }
          setState(() {
            _frameImage?.dispose();
            _frameImage = image;
            _frames++;
            _status = 'Running';
          });
        },
      );
    }
  }

  KeyEventResult _onKeyEvent(KeyEvent event) {
    final doomKey = _mapKey(event);
    if (doomKey == null) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      _writeEvent(_eventTypeKeyDown, doomKey);
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      _writeEvent(_eventTypeKeyUp, doomKey);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  int? _mapKey(KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight) {
      return _doomKeyRight;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      return _doomKeyLeft;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      return _doomKeyUp;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      return _doomKeyDown;
    }
    if (key == LogicalKeyboardKey.escape) {
      return _doomKeyEscape;
    }
    if (key == LogicalKeyboardKey.enter) {
      return _doomKeyEnter;
    }
    if (key == LogicalKeyboardKey.space) {
      return 32;
    }
    if (key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight) {
      return _doomKeyCtrl;
    }
    if (key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight) {
      return _doomKeyAlt;
    }
    if (key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight) {
      return _doomKeyShift;
    }
    if (key == LogicalKeyboardKey.tab) {
      return _doomKeyTab;
    }
    if (key == LogicalKeyboardKey.backspace) {
      return _doomKeyBackspace;
    }

    final label = key.keyLabel;
    if (label.isNotEmpty) {
      final codeUnit = label.codeUnitAt(0);
      if (codeUnit >= 65 && codeUnit <= 90) {
        return codeUnit + 32;
      }
      if (codeUnit >= 32 && codeUnit <= 126) {
        return codeUnit;
      }
    }
    return null;
  }

  void _writeEvent(int eventType, int keyCode) {
    final writer = _eventWriter;
    if (writer == null) {
      return;
    }
    final bytes = ByteData(8)
      ..setInt32(0, eventType, Endian.little)
      ..setInt32(4, keyCode, Endian.little);
    writer.writeFromSync(bytes.buffer.asUint8List());
    writer.flushSync();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Doom Wasm Window'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            child: Text('frames: $_frames'),
          ),
        ],
      ),
      body: Focus(
        autofocus: true,
        onKeyEvent: (_, event) => _onKeyEvent(event),
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: _doomWidth / _doomHeight,
                  child: ColoredBox(
                    color: Colors.black,
                    child: _frameImage == null
                        ? const Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : RawImage(
                            image: _frameImage,
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.none,
                          ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Text(
                'status: $_status\n'
                'controls: arrows/WASD move, Ctrl/Space fire, Alt strafe, Shift run, Enter use, Esc menu',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _doomIsolateMain(Map<String, Object?> args) {
  final uiPort = args['uiPort'] as SendPort;
  final eventFilePath = args['eventFilePath'] as String;
  final wasmBytes = (args['wasmBytes'] as TransferableTypedData)
      .materialize()
      .asUint8List();
  final iwadBytes = (args['iwadBytes'] as TransferableTypedData)
      .materialize()
      .asUint8List();

  try {
    uiPort.send(<String, Object?>{
      'type': 'status',
      'text': 'Loading Doom wasm...',
    });

    final fs = WasiInMemoryFileSystem();
    _writeInMemoryFile(fs, '/doom1.wad', iwadBytes);

    final wasi = WasiPreview1(
      args: const ['doom.wasm'],
      stdin: Uint8List(0),
      stdoutSink: (_) {},
      stderrSink: (_) {},
      fileSystem: fs,
      preferHostIo: false,
    );
    final frontend = _WindowDoomHost(
      uiPort: uiPort,
      eventFilePath: eventFilePath,
    );
    final imports = <String, WasmHostFunction>{
      ...wasi.imports.functions,
      ...frontend.imports,
    };
    final instance = WasmInstance.fromBytes(
      wasmBytes,
      imports: WasmImports(functions: imports),
    );
    wasi.bindInstance(instance);
    frontend.bindMemory(instance.exportedMemory('memory'));

    uiPort.send(<String, Object?>{'type': 'status', 'text': 'Running'});
    instance.invoke('_start');
    uiPort.send(<String, Object?>{
      'type': 'exit',
      'text': 'doom _start returned',
    });
  } on WasiProcExit catch (error) {
    uiPort.send(<String, Object?>{
      'type': 'exit',
      'text': 'WASI exit code: ${error.exitCode}',
    });
  } catch (error) {
    uiPort.send(<String, Object?>{'type': 'error', 'text': error.toString()});
  }
}

void _writeInMemoryFile(
  WasiInMemoryFileSystem fs,
  String path,
  Uint8List bytes,
) {
  final fd = fs.open(
    path: path,
    create: true,
    truncate: true,
    read: true,
    write: true,
    exclusive: false,
  );
  fd.write(bytes);
  fd.close();
}

final class _WindowDoomHost {
  _WindowDoomHost({required this.uiPort, required String eventFilePath})
    : _eventReader = File(eventFilePath).openSync(mode: FileMode.read);

  final SendPort uiPort;
  final RandomAccessFile _eventReader;
  final Queue<_DoomEvent> _events = Queue<_DoomEvent>();
  final Uint8List _palette = Uint8List(1024);
  final Stopwatch _frameClock = Stopwatch()..start();

  WasmMemory? _memory;
  int _eventReadOffset = 0;
  int _lastFrameSentUs = 0;

  Map<String, WasmHostFunction> get imports => <String, WasmHostFunction>{
    WasmImports.key('env', 'ZwareDoomOpenWindow'): _openWindow,
    WasmImports.key('env', 'ZwareDoomSetPalette'): _setPalette,
    WasmImports.key('env', 'ZwareDoomPendingEvent'): _pendingEvent,
    WasmImports.key('env', 'ZwareDoomNextEvent'): _nextEvent,
    WasmImports.key('env', 'ZwareDoomRenderFrame'): _renderFrame,
  };

  void bindMemory(WasmMemory memory) {
    _memory = memory;
  }

  Object? _openWindow(List<Object?> args) {
    return 1;
  }

  Object? _setPalette(List<Object?> args) {
    final memory = _requireMemory();
    final ptr = _asI32(args, 0, 'palette_ptr');
    final len = _asI32(args, 1, 'palette_len');
    if (len <= 0) {
      return null;
    }

    final bytes = memory.readBytes(ptr, len);
    final copyLen = bytes.length < _palette.length
        ? bytes.length
        : _palette.length;
    _palette.setRange(0, copyLen, bytes);
    if (copyLen < _palette.length) {
      _palette.fillRange(copyLen, _palette.length, 0);
    }
    return null;
  }

  Object? _pendingEvent(List<Object?> args) {
    _pumpEventFile();
    return _events.isNotEmpty ? 1 : 0;
  }

  Object? _nextEvent(List<Object?> args) {
    _pumpEventFile();
    if (_events.isEmpty) {
      return 0;
    }

    final memory = _requireMemory();
    final typePtr = _asI32(args, 0, 'type_ptr');
    final data1Ptr = _asI32(args, 1, 'data1_ptr');
    final data2Ptr = _asI32(args, 2, 'data2_ptr');
    final data3Ptr = _asI32(args, 3, 'data3_ptr');

    final event = _events.removeFirst();
    memory.storeI32(typePtr, event.type);
    memory.storeI32(data1Ptr, event.data1);
    memory.storeI32(data2Ptr, 0);
    memory.storeI32(data3Ptr, 0);
    return 1;
  }

  Object? _renderFrame(List<Object?> args) {
    final memory = _requireMemory();
    final framePtr = _asI32(args, 0, 'frame_ptr');
    final frameLen = _asI32(args, 1, 'frame_len');
    if (frameLen <= 0) {
      return 0;
    }

    final nowUs = _frameClock.elapsedMicroseconds;
    if (nowUs - _lastFrameSentUs < 33 * 1000) {
      return 0;
    }
    _lastFrameSentUs = nowUs;

    final indexed = memory.readBytes(framePtr, frameLen);
    final rgba = _indexedToRgba(indexed);
    uiPort.send(<String, Object?>{
      'type': 'frame',
      'rgba': TransferableTypedData.fromList(<Uint8List>[rgba]),
    });
    return 0;
  }

  Uint8List _indexedToRgba(Uint8List indexed) {
    final pixelCount = _doomWidth * _doomHeight;
    final rgba = Uint8List(pixelCount * 4);
    final usable = indexed.length < pixelCount ? indexed.length : pixelCount;

    for (var i = 0; i < usable; i++) {
      final paletteOffset = indexed[i] * 4;
      final out = i * 4;
      rgba[out + 0] = _palette[paletteOffset + 0];
      rgba[out + 1] = _palette[paletteOffset + 1];
      rgba[out + 2] = _palette[paletteOffset + 2];
      rgba[out + 3] = 255;
    }
    return rgba;
  }

  void _pumpEventFile() {
    final length = _eventReader.lengthSync();
    while (_eventReadOffset + 8 <= length) {
      _eventReader.setPositionSync(_eventReadOffset);
      final bytes = _eventReader.readSync(8);
      if (bytes.length != 8) {
        break;
      }
      _eventReadOffset += 8;
      final view = ByteData.sublistView(Uint8List.fromList(bytes));
      final type = view.getInt32(0, Endian.little);
      final key = view.getInt32(4, Endian.little);
      _events.add(_DoomEvent(type: type, data1: key));
    }
  }

  WasmMemory _requireMemory() {
    final memory = _memory;
    if (memory == null) {
      throw StateError('Doom host memory is not bound.');
    }
    return memory;
  }

  static int _asI32(List<Object?> args, int index, String name) {
    if (index < 0 || index >= args.length) {
      throw StateError('Missing host argument: $name');
    }
    final value = args[index];
    if (value is! int) {
      throw StateError('Host argument `$name` must be i32/int.');
    }
    return value.toSigned(32);
  }
}

final class _DoomEvent {
  const _DoomEvent({required this.type, required this.data1});

  final int type;
  final int data1;
}
