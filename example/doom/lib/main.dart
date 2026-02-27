import 'dart:collection';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wasd/wasd.dart';

const String _doomWasmAssetPath = 'assets/doom/doom.wasm';
const String _doomIwadAssetPath = 'assets/doom/doom1.wad';

const int _doomWidth = 320;
const int _doomHeight = 200;
const int _doomTargetFrameIntervalUs = 28000;

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

enum _DoomRuntimeState { booting, running, exited, error, missingAssets }

void main() {
  runApp(const DoomWindowApp());
}

final class DoomWindowApp extends StatelessWidget {
  const DoomWindowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DOOM // WASD',
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
  SendPort? _eventSendPort;
  final FocusNode _focusNode = FocusNode(debugLabel: 'doom-input-focus');
  final Stopwatch _uiClock = Stopwatch()..start();

  ui.Image? _frameImage;
  bool _decodingFrame = false;
  int _frames = 0;
  int _framesAtFpsMark = 0;
  int _lastFpsMarkUs = 0;
  double _fps = 0;
  bool _showHelpOverlay = true;
  String _status = 'Booting Doom runtime...';
  _DoomRuntimeState _runtimeState = _DoomRuntimeState.booting;

  @override
  void initState() {
    super.initState();
    _startDoom();
  }

  @override
  void dispose() {
    _shutdownRuntime();
    _focusNode.dispose();
    _frameImage?.dispose();
    _frameImage = null;
    super.dispose();
  }

  void _shutdownRuntime() {
    _doomIsolate?.kill(priority: Isolate.immediate);
    _doomIsolate = null;
    _receivePort?.close();
    _receivePort = null;
    _eventSendPort = null;
  }

  Future<void> _startDoom() async {
    _shutdownRuntime();
    _frameImage?.dispose();
    _frameImage = null;
    _frames = 0;
    _framesAtFpsMark = 0;
    _lastFpsMarkUs = 0;
    _fps = 0;
    _decodingFrame = false;
    if (mounted) {
      setState(() {
        _runtimeState = _DoomRuntimeState.booting;
        _status = 'Booting Doom runtime...';
      });
    }

    final wasmBytes = await _loadAssetBytes(_doomWasmAssetPath);
    final iwadBytes = await _loadAssetBytes(_doomIwadAssetPath);
    if (wasmBytes == null || iwadBytes == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _runtimeState = _DoomRuntimeState.missingAssets;
        _status =
            'Missing bundled assets.\n'
            'Run: tool/setup_assets.sh\n'
            'Expected assets under: example/doom/assets/doom/';
      });
      return;
    }

    final receivePort = ReceivePort();
    receivePort.listen(_onIsolateMessage);
    _receivePort = receivePort;

    _doomIsolate = await Isolate.spawn<Map<String, Object?>>(_doomIsolateMain, {
      'uiPort': receivePort.sendPort,
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
    if (type == 'event_port') {
      final port = message['port'];
      if (port is SendPort) {
        _eventSendPort = port;
      }
      return;
    }
    if (type == 'status') {
      final text = message['text'] as String? ?? '';
      setState(() {
        _status = text;
        if (_runtimeState == _DoomRuntimeState.error ||
            _runtimeState == _DoomRuntimeState.exited) {
          return;
        }
        _runtimeState = text == 'Running'
            ? _DoomRuntimeState.running
            : _DoomRuntimeState.booting;
      });
      return;
    }
    if (type == 'error') {
      final text = message['text'] as String? ?? 'Unknown error';
      setState(() {
        _runtimeState = _DoomRuntimeState.error;
        _status = 'Runtime error: $text';
      });
      return;
    }
    if (type == 'exit') {
      final text = message['text'] as String? ?? 'Runtime stopped';
      setState(() {
        _runtimeState = _DoomRuntimeState.exited;
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
          final nowUs = _uiClock.elapsedMicroseconds;
          if (_lastFpsMarkUs == 0) {
            _lastFpsMarkUs = nowUs;
          }
          setState(() {
            _frameImage?.dispose();
            _frameImage = image;
            _frames++;
            _runtimeState = _DoomRuntimeState.running;
            _status = 'In game';
            final elapsedUs = nowUs - _lastFpsMarkUs;
            if (elapsedUs >= 1000000) {
              final newFrames = _frames - _framesAtFpsMark;
              _fps = newFrames * 1000000 / elapsedUs;
              _framesAtFpsMark = _frames;
              _lastFpsMarkUs = nowUs;
            }
          });
        },
      );
    }
  }

  KeyEventResult _onKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.f1) {
      _toggleHelpOverlay();
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.f5) {
      _restartDoom();
      return KeyEventResult.handled;
    }

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
    final port = _eventSendPort;
    if (port == null) {
      return;
    }
    port.send(<int>[eventType, keyCode]);
  }

  void _toggleHelpOverlay() {
    setState(() {
      _showHelpOverlay = !_showHelpOverlay;
    });
    _focusNode.requestFocus();
  }

  void _dismissHelpOverlay() {
    if (!_showHelpOverlay) {
      return;
    }
    setState(() {
      _showHelpOverlay = false;
    });
    _focusNode.requestFocus();
  }

  void _restartDoom() {
    _startDoom();
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xff040404),
      body: Listener(
        onPointerDown: (_) => _focusNode.requestFocus(),
        behavior: HitTestBehavior.translucent,
        child: GestureDetector(
          onTap: _focusNode.requestFocus,
          child: Focus(
            focusNode: _focusNode,
            autofocus: true,
            onKeyEvent: (_, event) => _onKeyEvent(event),
            child: Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment(0, -0.15),
                        radius: 1.2,
                        colors: <Color>[
                          Color(0xff22160f),
                          Color(0xff130a06),
                          Color(0xff050303),
                        ],
                      ),
                    ),
                  ),
                ),
                Center(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 72, 18, 120),
                    child: AspectRatio(
                      aspectRatio: _doomWidth / _doomHeight,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black,
                          border: Border.all(
                            color: const Color(0xff9d5530),
                            width: 2,
                          ),
                          boxShadow: const <BoxShadow>[
                            BoxShadow(
                              color: Colors.black87,
                              blurRadius: 24,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: ClipRect(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              _frameImage == null
                                  ? const _BootBackdrop()
                                  : RawImage(
                                      image: _frameImage,
                                      fit: BoxFit.fill,
                                      filterQuality: FilterQuality.none,
                                    ),
                              IgnorePointer(
                                child: CustomPaint(
                                  painter: _ScanlineOverlayPainter(
                                    opacity: _frameImage == null ? 0 : 0.12,
                                  ),
                                ),
                              ),
                              if (_frameImage != null)
                                const IgnorePointer(
                                  child: Center(
                                    child: Text(
                                      '+',
                                      style: TextStyle(
                                        color: Color(0x88f4b36a),
                                        fontSize: 22,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 20,
                  left: 20,
                  right: 20,
                  child: Row(
                    children: [
                      Expanded(
                        child: _TopStatusBar(
                          runtimeLabel: _runtimeLabel,
                          fps: _fps,
                          frameCount: _frames,
                        ),
                      ),
                      const SizedBox(width: 12),
                      _SmallKeycap(
                        keyName: 'F1',
                        description: _showHelpOverlay ? 'Hide Help' : 'Help',
                        onTap: _toggleHelpOverlay,
                      ),
                      const SizedBox(width: 8),
                      _SmallKeycap(
                        keyName: 'F5',
                        description: 'Restart',
                        onTap: _restartDoom,
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 18,
                  child: _HudPanel(
                    runtimeLabel: _runtimeLabel,
                    statusText: _status,
                    showHint: _frameImage != null,
                  ),
                ),
                if (_showHelpOverlay)
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: _dismissHelpOverlay,
                      behavior: HitTestBehavior.opaque,
                      child: const DecoratedBox(
                        decoration: BoxDecoration(color: Color(0xaa000000)),
                        child: Center(child: _HelpCard()),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String get _runtimeLabel => switch (_runtimeState) {
    _DoomRuntimeState.booting => 'BOOTING',
    _DoomRuntimeState.running => 'LIVE',
    _DoomRuntimeState.exited => 'EXITED',
    _DoomRuntimeState.error => 'ERROR',
    _DoomRuntimeState.missingAssets => 'MISSING ASSETS',
  };
}

final class _BootBackdrop extends StatelessWidget {
  const _BootBackdrop();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xff070707),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'DOOM // WASD',
              style: TextStyle(
                color: Color(0xfff39b57),
                fontSize: 26,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
                fontFamily: 'monospace',
              ),
            ),
            SizedBox(height: 14),
            CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xffe07a3d)),
            ),
          ],
        ),
      ),
    );
  }
}

final class _ScanlineOverlayPainter extends CustomPainter {
  const _ScanlineOverlayPainter({required this.opacity});

  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) {
      return;
    }
    final linePaint = Paint()
      ..color = Color.fromRGBO(0, 0, 0, opacity)
      ..strokeWidth = 1;
    for (double y = 0; y < size.height; y += 3) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }
    final vignette = Paint()
      ..shader = const RadialGradient(
        center: Alignment.center,
        radius: 0.95,
        colors: <Color>[
          Color(0x00000000),
          Color(0x33000000),
          Color(0x88000000),
        ],
        stops: <double>[0.45, 0.78, 1],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, vignette);
  }

  @override
  bool shouldRepaint(covariant _ScanlineOverlayPainter oldDelegate) {
    return oldDelegate.opacity != opacity;
  }
}

final class _TopStatusBar extends StatelessWidget {
  const _TopStatusBar({
    required this.runtimeLabel,
    required this.fps,
    required this.frameCount,
  });

  final String runtimeLabel;
  final double fps;
  final int frameCount;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xbb080808),
        border: Border.all(color: const Color(0xff8f4b28), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: DefaultTextStyle(
          style: const TextStyle(
            fontFamily: 'monospace',
            color: Color(0xfff4e2cf),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'DOOM // WASD',
                style: TextStyle(
                  color: Color(0xffef9d5b),
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 14,
                runSpacing: 4,
                children: [
                  Text('state: $runtimeLabel'),
                  Text('fps: ${fps.toStringAsFixed(1)}'),
                  Text('frames: $frameCount'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _SmallKeycap extends StatelessWidget {
  const _SmallKeycap({
    required this.keyName,
    required this.description,
    this.onTap,
  });

  final String keyName;
  final String description;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xcc121212),
        border: Border.all(color: const Color(0xff6f3a1f), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: DefaultTextStyle(
          style: const TextStyle(
            fontFamily: 'monospace',
            color: Color(0xfff0d7bf),
            fontSize: 11,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                keyName,
                style: const TextStyle(
                  color: Color(0xfff39b57),
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(description),
            ],
          ),
        ),
      ),
    );
    final callback = onTap;
    if (callback == null) {
      return content;
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: callback,
        child: content,
      ),
    );
  }
}

final class _HudPanel extends StatelessWidget {
  const _HudPanel({
    required this.runtimeLabel,
    required this.statusText,
    required this.showHint,
  });

  final String runtimeLabel;
  final String statusText;
  final bool showHint;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xcc090909),
        border: Border.all(color: const Color(0xff8d4e2b), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: DefaultTextStyle(
          style: const TextStyle(
            fontFamily: 'monospace',
            color: Color(0xffe5d7c8),
            fontSize: 11,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'state=$runtimeLabel  status=$statusText',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (showHint)
                const Text(
                  'WASD move | Ctrl/Space fire | Enter use | Esc menu',
                ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _HelpCard extends StatelessWidget {
  const _HelpCard();

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xee0a0a0a),
          border: Border.all(color: const Color(0xff9b5931), width: 1.5),
          boxShadow: const <BoxShadow>[
            BoxShadow(color: Colors.black87, blurRadius: 18, spreadRadius: 2),
          ],
        ),
        child: const Padding(
          padding: EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: DefaultTextStyle(
            style: TextStyle(
              fontFamily: 'monospace',
              color: Color(0xfff0dcc7),
              fontSize: 13,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Mission Briefing',
                  style: TextStyle(
                    color: Color(0xfff39b57),
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 10),
                Text('Click viewport to focus input.'),
                Text('Move: WASD or Arrow Keys'),
                Text('Fire: Ctrl or Space'),
                Text('Use/Open: Enter'),
                Text('Menu: Esc'),
                SizedBox(height: 10),
                Text('F1: Toggle this overlay'),
                Text('F5: Restart runtime'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _doomIsolateMain(Map<String, Object?> args) async {
  final uiPort = args['uiPort'] as SendPort;
  final wasmBytes = (args['wasmBytes'] as TransferableTypedData)
      .materialize()
      .asUint8List();
  final iwadBytes = (args['iwadBytes'] as TransferableTypedData)
      .materialize()
      .asUint8List();

  _WindowDoomHost? frontend;

  try {
    frontend = _WindowDoomHost(uiPort: uiPort);
    uiPort.send(<String, Object?>{
      'type': 'event_port',
      'port': frontend.eventSendPort,
    });
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
    final imports = WasmImports(
      functions: <String, WasmHostFunction>{
        ...wasi.imports.functions,
        ...frontend.syncImports,
      },
      asyncFunctions: frontend.asyncImports,
    );
    final instance = WasmInstance.fromBytes(wasmBytes, imports: imports);
    wasi.bindInstance(instance);
    frontend.bindMemory(instance.exportedMemory('memory'));

    uiPort.send(<String, Object?>{'type': 'status', 'text': 'Running'});
    await instance.invokeAsync('_start');
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
  } finally {
    frontend?.close();
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
    followSymlinks: true,
  );
  fd.write(bytes);
  fd.close();
}

final class _WindowDoomHost {
  _WindowDoomHost({required this.uiPort}) {
    _eventPort.handler = _onEventMessage;
  }

  final SendPort uiPort;
  final RawReceivePort _eventPort = RawReceivePort();
  final Queue<_DoomEvent> _events = Queue<_DoomEvent>();
  final Uint8List _palette = Uint8List(1024);
  final Stopwatch _frameClock = Stopwatch()..start();

  WasmMemory? _memory;
  int _lastEventYieldUs = 0;
  int _lastFrameSentUs = 0;

  SendPort get eventSendPort => _eventPort.sendPort;

  Map<String, WasmHostFunction> get syncImports => <String, WasmHostFunction>{
    WasmImports.key('env', 'ZwareDoomOpenWindow'): _openWindow,
    WasmImports.key('env', 'ZwareDoomSetPalette'): _setPalette,
    WasmImports.key('env', 'ZwareDoomRenderFrame'): _renderFrame,
  };

  Map<String, WasmAsyncHostFunction> get asyncImports =>
      <String, WasmAsyncHostFunction>{
        WasmImports.key('env', 'ZwareDoomPendingEvent'): _pendingEventAsync,
        WasmImports.key('env', 'ZwareDoomNextEvent'): _nextEventAsync,
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

  void _onEventMessage(Object? message) {
    if (message is! List || message.length != 2) {
      return;
    }
    final eventType = message[0];
    final keyCode = message[1];
    if (eventType is! int || keyCode is! int) {
      return;
    }
    _events.add(_DoomEvent(type: eventType.toSigned(32), data1: keyCode));
  }

  Future<Object?> _pendingEventAsync(List<Object?> args) async {
    if (_events.isEmpty) {
      await _yieldToEventLoopIfNeeded();
    }
    return _events.isNotEmpty ? 1 : 0;
  }

  Future<Object?> _nextEventAsync(List<Object?> args) async {
    if (_events.isEmpty) {
      await _yieldToEventLoopIfNeeded();
      if (_events.isEmpty) {
        return 0;
      }
    }
    _writeNextEventToGuest(args);
    return 1;
  }

  void _writeNextEventToGuest(List<Object?> args) {
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
  }

  Object? _renderFrame(List<Object?> args) {
    final memory = _requireMemory();
    final framePtr = _asI32(args, 0, 'frame_ptr');
    final frameLen = _asI32(args, 1, 'frame_len');
    if (frameLen <= 0) {
      return 0;
    }

    final nowUs = _frameClock.elapsedMicroseconds;
    if (nowUs - _lastFrameSentUs < _doomTargetFrameIntervalUs) {
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

  void close() {
    _eventPort.close();
  }

  Future<void> _yieldToEventLoopIfNeeded() async {
    final nowUs = _frameClock.elapsedMicroseconds;
    if (nowUs - _lastEventYieldUs < 2000) {
      return;
    }
    _lastEventYieldUs = nowUs;
    await Future<void>.delayed(Duration.zero);
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
