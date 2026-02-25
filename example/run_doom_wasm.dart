import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wasd/wasd.dart';

const String _defaultWasmPath = 'example/doom/doom.wasm';
const String _defaultIwadPath = 'example/doom/doom1.wad';
const int _defaultMaxFrames = 180;

void main(List<String> args) {
  final wasmPath = args.isNotEmpty ? args[0] : _defaultWasmPath;
  final iwadPath = args.length > 1 ? args[1] : _defaultIwadPath;
  final maxFrames = args.length > 2
      ? (int.tryParse(args[2]) ?? _defaultMaxFrames)
      : _defaultMaxFrames;
  final dumpFramePath = args.length > 3 ? args[3] : null;

  if (maxFrames <= 0) {
    stderr.writeln('maxFrames must be positive.');
    exitCode = 2;
    return;
  }

  final wasmFile = File(wasmPath);
  if (!wasmFile.existsSync()) {
    stderr.writeln('Missing wasm file: $wasmPath');
    stderr.writeln(
      'Run `example/doom/setup_assets.sh` or provide a custom wasm path.',
    );
    exitCode = 1;
    return;
  }

  final iwadFile = File(iwadPath);
  if (!iwadFile.existsSync()) {
    stderr.writeln('Missing IWAD file: $iwadPath');
    stderr.writeln(
      'Run `example/doom/setup_assets.sh` or provide a custom IWAD path.',
    );
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
  final host = _HeadlessDoomHost(
    maxFrames: maxFrames,
    dumpFramePath: dumpFramePath,
  );

  final imports = <String, WasmHostFunction>{
    ...wasi.imports.functions,
    ...host.imports,
  };

  final instance = WasmInstance.fromBytes(
    wasmFile.readAsBytesSync(),
    imports: WasmImports(functions: imports),
  );
  wasi.bindInstance(instance);
  host.bindMemory(instance.exportedMemory('memory'));

  try {
    instance.invoke('_start');
    stdout.writeln('doom _start returned');
  } on _StopDoom catch (e) {
    stdout.writeln('doom started successfully, frames=${e.frames}');
  } on WasiProcExit catch (e) {
    stdout.writeln('doom exited via WASI code=${e.exitCode}');
  }
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
  stdout.writeln('Created IWAD alias: ${alias.path}');
}

String _basename(String path) {
  final parts = path.split(RegExp(r'[\\/]'));
  if (parts.isEmpty) {
    return path;
  }
  return parts.last;
}

final class _HeadlessDoomHost {
  _HeadlessDoomHost({required this.maxFrames, this.dumpFramePath});

  final int maxFrames;
  final String? dumpFramePath;
  final Uint8List _palette = Uint8List(1024);

  WasmMemory? _memory;
  var _frames = 0;
  var _frameDumped = false;

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
    return 0;
  }

  Object? _nextEvent(List<Object?> args) {
    return 0;
  }

  Object? _renderFrame(List<Object?> args) {
    final memory = _requireMemory();
    final framePtr = _asI32(args, 0, 'frame_ptr');
    final frameLen = _asI32(args, 1, 'frame_len');

    _frames++;
    if (_frames % 30 == 0) {
      stdout.writeln('rendered frames: $_frames');
    }

    if (!_frameDumped && dumpFramePath != null && frameLen > 0) {
      _dumpFrame(
        memory: memory,
        framePtr: framePtr,
        frameLen: frameLen,
        outputPath: dumpFramePath!,
      );
      _frameDumped = true;
      stdout.writeln('wrote first frame to: $dumpFramePath');
    }

    if (_frames >= maxFrames) {
      throw _StopDoom(_frames);
    }
    return 0;
  }

  void _dumpFrame({
    required WasmMemory memory,
    required int framePtr,
    required int frameLen,
    required String outputPath,
  }) {
    final indexed = memory.readBytes(framePtr, frameLen);
    var width = 320;
    var height = 200;
    if (frameLen != 320 * 200) {
      width = frameLen;
      height = 1;
    }

    final pixelCount = width * height;
    final rgb = Uint8List(pixelCount * 3);
    for (var i = 0; i < pixelCount; i++) {
      final colorIndex = indexed[i];
      final paletteOffset = colorIndex * 4;
      final outOffset = i * 3;
      if (paletteOffset + 2 < _palette.length) {
        rgb[outOffset + 0] = _palette[paletteOffset + 0];
        rgb[outOffset + 1] = _palette[paletteOffset + 1];
        rgb[outOffset + 2] = _palette[paletteOffset + 2];
      } else {
        rgb[outOffset + 0] = colorIndex;
        rgb[outOffset + 1] = colorIndex;
        rgb[outOffset + 2] = colorIndex;
      }
    }

    final header = ascii.encode('P6\n$width $height\n255\n');
    final out = Uint8List(header.length + rgb.length);
    out.setRange(0, header.length, header);
    out.setRange(header.length, out.length, rgb);

    final outFile = File(outputPath);
    outFile.parent.createSync(recursive: true);
    outFile.writeAsBytesSync(out, flush: true);
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

final class _StopDoom implements Exception {
  const _StopDoom(this.frames);
  final int frames;
}
