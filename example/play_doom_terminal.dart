import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:wasd/wasd.dart';

const String _defaultWasmPath = 'example/doom/doom.wasm';
const String _defaultIwadPath = 'example/doom/doom1.wad';

enum _RenderMode { color, mono }

final class _CliConfig {
  const _CliConfig({
    required this.wasmPath,
    required this.iwadPath,
    required this.renderMode,
  });

  final String wasmPath;
  final String iwadPath;
  final _RenderMode renderMode;
}

void main(List<String> args) {
  final config = _parseArgs(args);
  final wasmPath = config.wasmPath;
  final iwadPath = config.iwadPath;

  final wasmFile = File(wasmPath);
  if (!wasmFile.existsSync()) {
    stderr.writeln('Missing wasm file: $wasmPath');
    stderr.writeln('Run `example/doom/setup_assets.sh` first.');
    exitCode = 1;
    return;
  }

  final iwadFile = File(iwadPath);
  if (!iwadFile.existsSync()) {
    stderr.writeln('Missing IWAD file: $iwadPath');
    stderr.writeln('Run `example/doom/setup_assets.sh` first.');
    exitCode = 1;
    return;
  }
  _ensureDoom1Alias(iwadFile);

  final wasi = WasiPreview1(
    args: const ['doom.wasm'],
    stdin: Uint8List(0),
    stdoutSink: (bytes) => stdout.add(bytes),
    stderrSink: (bytes) => stderr.add(bytes),
    preferHostIo: true,
    ioRootPath: iwadFile.parent.absolute.path,
  );
  final frontend = _TerminalDoomFrontend(renderMode: config.renderMode);

  final imports = <String, WasmHostFunction>{
    ...wasi.imports.functions,
    ...frontend.imports,
  };

  final instance = WasmInstance.fromBytes(
    wasmFile.readAsBytesSync(),
    imports: WasmImports(functions: imports),
  );
  wasi.bindInstance(instance);
  frontend.bindMemory(instance.exportedMemory('memory'));

  try {
    instance.invoke('_start');
    stdout.writeln('\ndoom _start returned');
  } on _StopPlay {
    stdout.writeln('\nStopped.');
  } on WasiProcExit catch (e) {
    stdout.writeln('\ndoom exited via WASI code=${e.exitCode}');
  } finally {
    frontend.dispose();
  }
}

_CliConfig _parseArgs(List<String> args) {
  final positionals = <String>[];
  var mode = _RenderMode.color;

  for (final arg in args) {
    switch (arg) {
      case '--mono':
        mode = _RenderMode.mono;
      case '--color':
        mode = _RenderMode.color;
      case '-h':
      case '--help':
        stdout.writeln(
          'Usage: dart run example/play_doom_terminal.dart '
          '[doom.wasm] [doom1.wad] [--mono|--color]',
        );
        exit(0);
      default:
        positionals.add(arg);
    }
  }

  final wasmPath = positionals.isNotEmpty ? positionals[0] : _defaultWasmPath;
  final iwadPath = positionals.length > 1 ? positionals[1] : _defaultIwadPath;
  return _CliConfig(wasmPath: wasmPath, iwadPath: iwadPath, renderMode: mode);
}

void _ensureDoom1Alias(File iwadFile) {
  final name = _basename(iwadFile.path).toLowerCase();
  if (name == 'doom1.wad') {
    return;
  }
  final alias = File(
    '${iwadFile.parent.absolute.path}${Platform.pathSeparator}doom1.wad',
  );
  if (alias.existsSync()) {
    return;
  }
  alias.writeAsBytesSync(iwadFile.readAsBytesSync(), flush: true);
}

String _basename(String path) {
  final parts = path.split(RegExp(r'[\\/]'));
  if (parts.isEmpty) {
    return path;
  }
  return parts.last;
}

final class _TerminalDoomFrontend {
  _TerminalDoomFrontend({required _RenderMode renderMode})
    : _renderer = _AnsiRenderer(renderMode: renderMode);

  final Queue<_DoomEvent> _events = Queue<_DoomEvent>();
  final Uint8List _palette = Uint8List(1024);
  final _AnsiRenderer _renderer;
  final _TerminalInput _input = _TerminalInput();

  WasmMemory? _memory;
  var _frameCount = 0;

  void bindMemory(WasmMemory memory) {
    _memory = memory;
  }

  Map<String, WasmHostFunction> get imports => <String, WasmHostFunction>{
    WasmImports.key('env', 'ZwareDoomOpenWindow'): _openWindow,
    WasmImports.key('env', 'ZwareDoomSetPalette'): _setPalette,
    WasmImports.key('env', 'ZwareDoomPendingEvent'): _pendingEvent,
    WasmImports.key('env', 'ZwareDoomNextEvent'): _nextEvent,
    WasmImports.key('env', 'ZwareDoomRenderFrame'): _renderFrame,
  };

  Object? _openWindow(List<Object?> args) {
    _input.enable();
    _renderer.begin();
    return 1;
  }

  Object? _setPalette(List<Object?> args) {
    final memory = _requireMemory();
    final ptr = _asI32(args, 0, 'ptr');
    final len = _asI32(args, 1, 'len');
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
    _pumpInput();
    return _events.isNotEmpty ? 1 : 0;
  }

  Object? _nextEvent(List<Object?> args) {
    _pumpInput();
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
    if (frameLen > 0) {
      final frame = memory.readBytes(framePtr, frameLen);
      _frameCount++;
      _renderer.render(
        indexedFrame: frame,
        palette: _palette,
        frameCount: _frameCount,
      );
    }
    return 0;
  }

  void _pumpInput() {
    final keys = _input.pollKeys();
    for (final key in keys) {
      if (key == _DoomKeys.quit) {
        throw const _StopPlay();
      }
      _events.add(_DoomEvent(_DoomEventType.keyDown, key));
      _events.add(_DoomEvent(_DoomEventType.keyUp, key));
    }
  }

  void dispose() {
    _renderer.end();
    _input.disable();
  }

  WasmMemory _requireMemory() {
    final memory = _memory;
    if (memory == null) {
      throw StateError('Host memory is not bound.');
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

final class _AnsiRenderer {
  _AnsiRenderer({required this.renderMode});

  final _RenderMode renderMode;

  final Stopwatch _fpsGate = Stopwatch()..start();
  int _lastRenderUs = 0;
  bool _started = false;

  // 320x200 -> 80x25 (using upper-half block char with two sampled rows).
  static const int _outWidth = 80;
  static const int _outHeight = 25;
  static const int _sourceWidth = 320;
  static const int _sourceHeight = 200;
  static const String _monoRamp = ' .,:;irsXA253hMHGS#9B&@';

  void begin() {
    if (_started) {
      return;
    }
    _started = true;
    stdout.write('\x1b[2J\x1b[H\x1b[?25l');
  }

  void end() {
    if (!_started) {
      return;
    }
    _started = false;
    stdout.write('\x1b[0m\x1b[?25h\n');
  }

  void render({
    required Uint8List indexedFrame,
    required Uint8List palette,
    required int frameCount,
  }) {
    final nowUs = _fpsGate.elapsedMicroseconds;
    // Limit terminal redraw to ~15 fps to keep it usable.
    if (nowUs - _lastRenderUs < 66 * 1000) {
      return;
    }
    _lastRenderUs = nowUs;

    if (indexedFrame.length < _sourceWidth * _sourceHeight) {
      return;
    }

    final sb = StringBuffer('\x1b[H');
    for (var y = 0; y < _outHeight; y++) {
      final topY = y * 8;
      final bottomY = topY + 4;
      for (var x = 0; x < _outWidth; x++) {
        final srcX = x * 4;
        final topIndex = indexedFrame[(topY * _sourceWidth) + srcX];
        final bottomIndex = indexedFrame[(bottomY * _sourceWidth) + srcX];

        final topOffset = topIndex * 4;
        final bottomOffset = bottomIndex * 4;

        final tr = palette[topOffset + 0];
        final tg = palette[topOffset + 1];
        final tb = palette[topOffset + 2];

        final br = palette[bottomOffset + 0];
        final bg = palette[bottomOffset + 1];
        final bb = palette[bottomOffset + 2];

        if (renderMode == _RenderMode.color) {
          sb.write('\x1b[38;2;$tr;$tg;${tb}m');
          sb.write('\x1b[48;2;$br;$bg;${bb}m');
          sb.write('▀');
        } else {
          final lumTop = ((tr * 299) + (tg * 587) + (tb * 114)) ~/ 1000;
          final lumBottom = ((br * 299) + (bg * 587) + (bb * 114)) ~/ 1000;
          final lum = (lumTop + lumBottom) ~/ 2;
          final idx = (lum * (_monoRamp.length - 1)) ~/ 255;
          sb.write(_monoRamp[idx]);
        }
      }
      sb.write('\x1b[0m\n');
    }
    sb.write(
      'frames: $frameCount | controls: arrows/WASD move, space fire, enter use, esc menu, q quit',
    );
    stdout.write(sb.toString());
  }
}

final class _TerminalInput {
  _TerminalInput();

  bool _enabled = false;
  String? _sttyState;

  void enable() {
    if (_enabled) {
      return;
    }
    if (!stdin.hasTerminal) {
      return;
    }
    if (!(Platform.isMacOS || Platform.isLinux)) {
      return;
    }
    try {
      final save = Process.runSync('stty', ['-g']);
      if (save.exitCode == 0) {
        _sttyState = (save.stdout as String).trim();
      }
      Process.runSync('stty', ['-icanon', 'min', '0', 'time', '0', '-echo']);
      _enabled = true;
    } catch (_) {
      _enabled = false;
    }
  }

  void disable() {
    if (!_enabled) {
      return;
    }
    try {
      final state = _sttyState;
      if (state != null && state.isNotEmpty) {
        Process.runSync('stty', [state]);
      } else {
        Process.runSync('stty', ['sane']);
      }
    } catch (_) {
      // Ignore restore errors.
    } finally {
      _enabled = false;
    }
  }

  List<int> pollKeys() {
    if (!_enabled) {
      return const <int>[];
    }
    final keys = <int>[];
    while (true) {
      int byte;
      try {
        byte = stdin.readByteSync();
      } catch (_) {
        break;
      }
      if (byte < 0) {
        break;
      }
      final mapped = _mapByteToDoomKey(byte);
      if (mapped != null) {
        keys.add(mapped);
      }
    }
    return keys;
  }

  int? _mapByteToDoomKey(int byte) {
    if (byte == 3 || byte == 113 || byte == 81) {
      return _DoomKeys.quit;
    }
    if (byte == 0x1b) {
      // Escape or arrow sequence.
      int next;
      try {
        next = stdin.readByteSync();
      } catch (_) {
        return _DoomKeys.escape;
      }
      if (next < 0) {
        return _DoomKeys.escape;
      }
      if (next != 0x5b) {
        return _DoomKeys.escape;
      }
      int arrow;
      try {
        arrow = stdin.readByteSync();
      } catch (_) {
        return _DoomKeys.escape;
      }
      return switch (arrow) {
        0x41 => _DoomKeys.up,
        0x42 => _DoomKeys.down,
        0x43 => _DoomKeys.right,
        0x44 => _DoomKeys.left,
        _ => _DoomKeys.escape,
      };
    }

    final lower = (byte >= 65 && byte <= 90) ? (byte + 32) : byte;
    if (lower >= 32 && lower <= 126) {
      return lower;
    }
    return switch (byte) {
      9 => _DoomKeys.tab,
      10 || 13 => _DoomKeys.enter,
      127 => _DoomKeys.backspace,
      _ => null,
    };
  }
}

final class _DoomEventType {
  static const int keyDown = 0;
  static const int keyUp = 1;
}

final class _DoomKeys {
  static const int right = 0xae;
  static const int left = 0xac;
  static const int up = 0xad;
  static const int down = 0xaf;
  static const int escape = 27;
  static const int enter = 13;
  static const int tab = 9;
  static const int backspace = 127;
  static const int quit = -1;
}

final class _DoomEvent {
  const _DoomEvent(this.type, this.data1);

  final int type;
  final int data1;
}

final class _StopPlay implements Exception {
  const _StopPlay();
}
