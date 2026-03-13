import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/doom_frame_bytes.dart';
import 'src/doom_runner_client.dart';
import 'src/doom_runtime.dart';

const bool _doomAutoStartEnabled = bool.fromEnvironment(
  'DOOM_AUTO_START',
  defaultValue: true,
);

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
  final FocusNode _focusNode = FocusNode(debugLabel: 'doom-input-focus');
  final Stopwatch _uiClock = Stopwatch()..start();

  DoomRunnerClient? _runner;
  StreamSubscription<DoomRunnerMessage>? _runnerMessages;
  ui.Image? _frameImage;
  bool _decodingFrame = false;
  int _frames = 0;
  int _framesAtFpsMark = 0;
  int _lastFpsMarkUs = 0;
  double _fps = 0;
  bool _showHelpOverlay = true;
  String _status = 'Booting Doom runtime...';
  _DoomRuntimeState _runtimeState = _DoomRuntimeState.booting;

  bool get _autoStart => _doomAutoStartEnabled && !_isWidgetTestBinding();

  @override
  void initState() {
    super.initState();
    if (_autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_startDoom());
        }
      });
    }
  }

  @override
  void dispose() {
    unawaited(_shutdownRuntime());
    _focusNode.dispose();
    _frameImage?.dispose();
    super.dispose();
  }

  Future<void> _shutdownRuntime() async {
    final subscription = _runnerMessages;
    _runnerMessages = null;
    await subscription?.cancel();

    final runner = _runner;
    _runner = null;
    await runner?.stop();
  }

  Future<void> _startDoom() async {
    await _shutdownRuntime();
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

    final wasmBytes = await _loadAssetBytes(doomWasmAsset);
    final iwadBytes = await _loadAssetBytes(doomIwadAsset);
    if (wasmBytes == null || iwadBytes == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _runtimeState = _DoomRuntimeState.missingAssets;
        _status =
            'Missing bundled assets.\n'
            'Expected assets under: example/doom/assets/doom/';
      });
      return;
    }

    final runner = DoomRunnerClient();
    _runner = runner;
    _runnerMessages = runner.messages.listen(_onRunnerMessage);
    _focusNode.requestFocus();
    await runner.start(wasmBytes: wasmBytes, iwadBytes: iwadBytes);
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

  void _onRunnerMessage(DoomRunnerMessage message) {
    if (!mounted) {
      return;
    }
    final type = message['type'];
    if (type == doomRunnerMessageInputChannel) {
      return;
    }
    if (type == 'log') {
      final line = message['line'] as String?;
      if (line != null && mounted) {
        setState(() {
          _status = line;
          if (_runtimeState == _DoomRuntimeState.booting &&
              line == 'received first frame') {
            _runtimeState = _DoomRuntimeState.running;
          }
        });
      }
      return;
    }
    if (type == doomRunnerMessageFrame) {
      if (_decodingFrame) {
        return;
      }
      final bytes = frameMessageBytesAsUint8List(message['bytes']);
      if (bytes == null) {
        return;
      }
      final width = asIntOrNull(message['width']) ?? doomDefaultWidth;
      final height = asIntOrNull(message['height']) ?? doomDefaultHeight;
      final format = message['format'] as String? ?? doomFrameFormatRgba;
      _decodingFrame = true;
      if (format == doomFrameFormatBmp) {
        unawaited(_decodeCodecFrame(bytes));
      } else {
        ui.decodeImageFromPixels(
          bytes,
          width,
          height,
          ui.PixelFormat.rgba8888,
          _commitFrame,
        );
      }
      return;
    }
    if (type == doomRunnerMessageExit) {
      final code = message['code'];
      setState(() {
        _runtimeState = _DoomRuntimeState.exited;
        _status = 'WASI exit code: $code';
      });
      return;
    }
    if (type == doomRunnerMessageError) {
      final error = message['error'] as String? ?? 'Unknown error';
      setState(() {
        _runtimeState = _DoomRuntimeState.error;
        _status = 'Runtime error: $error';
      });
    }
  }

  Future<void> _decodeCodecFrame(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      _commitFrame(frame.image);
    } catch (_) {
      _decodingFrame = false;
    }
  }

  void _commitFrame(ui.Image image) {
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
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _runner?.sendKey(
        DoomInputEvent(type: doomEventTypeKeyDown, code: doomKey),
      );
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      _runner?.sendKey(DoomInputEvent(type: doomEventTypeKeyUp, code: doomKey));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  int? _mapKey(KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight) {
      return doomKeyRight;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      return doomKeyLeft;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      return doomKeyUp;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      return doomKeyDown;
    }
    if (key == LogicalKeyboardKey.escape) {
      return doomKeyEscape;
    }
    if (key == LogicalKeyboardKey.enter) {
      return doomKeyEnter;
    }
    if (key == LogicalKeyboardKey.space) {
      return 32;
    }
    if (key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight) {
      return doomKeyCtrl;
    }
    if (key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight) {
      return doomKeyAlt;
    }
    if (key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight) {
      return doomKeyShift;
    }
    if (key == LogicalKeyboardKey.tab) {
      return doomKeyTab;
    }
    if (key == LogicalKeyboardKey.backspace) {
      return doomKeyBackspace;
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
    unawaited(_startDoom());
    _focusNode.requestFocus();
  }

  bool _isWidgetTestBinding() {
    final bindingName = WidgetsBinding.instance.runtimeType.toString();
    return bindingName.contains('TestWidgetsFlutterBinding') ||
        bindingName.contains('AutomatedTestWidgetsFlutterBinding') ||
        bindingName.contains('LiveTestWidgetsFlutterBinding');
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
              children: <Widget>[
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
                      aspectRatio: doomDefaultWidth / doomDefaultHeight,
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
                            children: <Widget>[
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
                    children: <Widget>[
                      Expanded(
                        child: _TopStatusBar(fps: _fps, frameCount: _frames),
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
          children: <Widget>[
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
  const _TopStatusBar({required this.fps, required this.frameCount});

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
            children: <Widget>[
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
                children: <Widget>[
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
            children: <Widget>[
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
            children: <Widget>[
              Expanded(
                child: Text(
                  'state=$runtimeLabel  status=$statusText',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (showHint)
                const Text('Arrows move | Ctrl fire | Space use | Esc menu'),
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
              children: <Widget>[
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
                Text('Move: Arrow Keys'),
                Text('Fire: Ctrl'),
                Text('Use/Open: Space'),
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
