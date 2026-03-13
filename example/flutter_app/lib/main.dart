import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/doom_runner_client.dart';
import 'src/doom_runtime.dart';

const bool _doomAutoStartEnabled = bool.fromEnvironment(
  'DOOM_AUTO_START',
  defaultValue: true,
);

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
  final FocusNode _focusNode = FocusNode();
  final List<String> _logs = <String>[];

  Uint8List? _frameBytes;
  String? _error;
  bool _running = false;
  DoomRunnerClient? _runner;
  StreamSubscription<DoomRunnerMessage>? _runnerMessages;

  bool get _autoStart => _doomAutoStartEnabled && !_isWidgetTestBinding();

  @override
  void initState() {
    super.initState();
    _requestGameFocus();
    if (_autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_startGame());
        }
      });
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
      final wasmData = await rootBundle.load(doomWasmAsset);
      final iwadData = await rootBundle.load(doomIwadAsset);
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
    final runner = DoomRunnerClient();
    _runner = runner;
    _runnerMessages = runner.messages.listen(_onRunnerMessage);
    try {
      await runner.start(wasmBytes: wasmBytes, iwadBytes: iwadBytes);
    } catch (_) {
      await _stopRunner();
      rethrow;
    }
  }

  void _onRunnerMessage(DoomRunnerMessage message) {
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
      final bmp = messageBytesAsUint8List(message['bmp']);
      if (bmp != null) {
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
      _appendLog('doom exited: $code');
      unawaited(_stopRunner());
      return;
    }
    if (type == 'error') {
      final error = message['error'];
      final stack = message['stack'];
      setState(() {
        _running = false;
        _error = '$error';
      });
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

  Future<void> _stopGame() async {
    setState(() {
      _running = false;
      _logs.add('stop requested (current runtime is not interruptible).');
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
    _runner?.sendKey(DoomInputEvent(type: isDown ? 0 : 1, code: code));
  }

  void _requestGameFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  bool _isWidgetTestBinding() {
    final bindingName = WidgetsBinding.instance.runtimeType.toString();
    return bindingName.contains('TestWidgetsFlutterBinding') ||
        bindingName.contains('AutomatedTestWidgetsFlutterBinding') ||
        bindingName.contains('LiveTestWidgetsFlutterBinding');
  }

  void _onTapGameSurface(TapDownDetails _) {
    _requestGameFocus();
    if (_running) {
      _runner?.sendKey(const DoomInputEvent(type: 0, code: 32));
    }
  }

  void _onTapGameSurfaceUp(TapUpDetails _) {
    if (_running) {
      _runner?.sendKey(const DoomInputEvent(type: 1, code: 32));
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
    final frameSize = decodeBmpDimensions(frame);
    final frameWidth = (frameSize?.$1 ?? doomDefaultWidth).toDouble();
    final frameHeight = (frameSize?.$2 ?? doomDefaultHeight).toDouble();
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
              Align(
                alignment: Alignment.topLeft,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        FilledButton(
                          onPressed: _running ? null : _startGame,
                          child: const Text('Start'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonal(
                          onPressed: _running ? _stopGame : null,
                          child: const Text('Stop'),
                        ),
                      ],
                    ),
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
