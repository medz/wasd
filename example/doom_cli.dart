import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wasd/wasm.dart';
import 'package:wasd/wasi.dart';

const String _defaultWasmPath = 'test/fixtures/doom/doom.wasm';
const String _defaultIwadPath = 'test/fixtures/doom/doom1.wad';
const String _defaultGuestRoot = '/doom';
const String _defaultMode = 'instantiate';
const String _defaultTimedemo = 'demo1';
const String _defaultFrameDir = '.dart_tool/doom_frames';
const int _defaultWriteFrames = 1;
const int _doomDefaultWidth = 320;
const int _doomDefaultHeight = 200;

Future<void> main(List<String> args) async {
  final code = await _run(args);
  if (code != 0) {
    exitCode = code;
  }
}

Future<int> _run(List<String> args) async {
  final options = _parseArgs(args);
  final mode = options['mode'] ?? _defaultMode;
  if (mode != 'instantiate' && mode != 'start') {
    stderr.writeln('Invalid --mode value: $mode');
    stderr.writeln('Allowed values: instantiate, start');
    return 2;
  }

  final wasmPath = options['wasm'] ?? _defaultWasmPath;
  final iwadPath = options['iwad'] ?? _defaultIwadPath;
  final guestRoot = options['guest-root'] ?? _defaultGuestRoot;
  final timedemo = options['timedemo'] ?? _defaultTimedemo;
  final frameDirPath = options['frame-dir'] ?? _defaultFrameDir;
  final writeFrames = _parsePositiveInt(
    options['write-frames'],
    _defaultWriteFrames,
  );

  final wasmFile = File(wasmPath);
  final iwadFile = File(iwadPath);
  if (!await wasmFile.exists()) {
    stderr.writeln('Missing wasm file: $wasmPath');
    return 2;
  }
  if (!await iwadFile.exists()) {
    stderr.writeln('Missing IWAD file: $iwadPath');
    return 2;
  }

  final iwadName = iwadFile.uri.pathSegments.isEmpty
      ? 'doom1.wad'
      : iwadFile.uri.pathSegments.last;
  final hostPreopenDir = iwadFile.parent.path;
  final guestIwadPath = '$guestRoot/$iwadName';

  final monitor = _DoomFrameMonitor(
    frameDirPath: frameDirPath,
    maxFramesToWrite: writeFrames,
  );
  final wasmBytes = await wasmFile.readAsBytes();
  final wasiArgs = <String>[
    'doom.wasm',
    '-iwad',
    guestIwadPath,
    '-nosound',
    '-timedemo',
    timedemo,
  ];
  final wasi = WASI(
    args: wasiArgs,
    preopens: <String, String>{guestRoot: hostPreopenDir},
    env: <String, String>{'HOME': guestRoot, 'TERM': 'xterm'},
  );
  final imports = <String, ModuleImports>{
    ...wasi.imports,
    'env': monitor.imports,
  };

  final result = await WebAssembly.instantiate(
    Uint8List.fromList(wasmBytes).buffer,
    imports,
  );
  final memoryValue = result.instance.exports['memory'];
  if (memoryValue is MemoryImportExportValue) {
    monitor.bindMemory(memoryValue.ref);
  }

  if (mode == 'instantiate') {
    final reportPath = await monitor.writeReport(
      mode: mode,
      wasmPath: wasmPath,
      iwadPath: iwadPath,
      exitCode: 0,
      health: 'instantiated',
    );
    stdout.writeln('DOOM instantiate succeeded.');
    stdout.writeln('module=$wasmPath iwad=$iwadPath');
    stdout.writeln('report=$reportPath');
    return 0;
  }

  final exitCode = wasi.start(result.instance);
  final reportPath = await monitor.writeReport(
    mode: mode,
    wasmPath: wasmPath,
    iwadPath: iwadPath,
    exitCode: exitCode,
    health: monitor.health,
  );

  if (!monitor.isHealthy) {
    stderr.writeln('DOOM monitor failed: ${monitor.health}');
    stderr.writeln('report=$reportPath');
    return exitCode == 0 ? 1 : exitCode;
  }

  stdout.writeln('DOOM exited with code $exitCode');
  stdout.writeln('frames=${monitor.frameCount}');
  if (monitor.writtenFrames.isNotEmpty) {
    stdout.writeln('first_frame=${monitor.writtenFrames.first}');
  }
  stdout.writeln('report=$reportPath');
  return exitCode;
}

Map<String, String> _parseArgs(List<String> args) {
  final result = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) {
      continue;
    }
    final eq = arg.indexOf('=');
    if (eq != -1) {
      final key = arg.substring(2, eq);
      final value = arg.substring(eq + 1);
      result[key] = value;
      continue;
    }
    final key = arg.substring(2);
    if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
      result[key] = args[i + 1];
      i++;
      continue;
    }
    result[key] = 'true';
  }
  return result;
}

ModuleImports _buildDoomEnvImports(
  _DoomFrameMonitor monitor,
) => <String, ImportValue>{
  'ZwareDoomOpenWindow': ImportExportKind.function(monitor.onOpenWindow),
  'ZwareDoomSetPalette': ImportExportKind.function(monitor.onSetPalette),
  'ZwareDoomRenderFrame': ImportExportKind.function(monitor.onRenderFrame),
  'ZwareDoomPendingEvent': ImportExportKind.function(monitor.onPendingEvent),
  'ZwareDoomNextEvent': ImportExportKind.function(monitor.onNextEvent),
};

int _parsePositiveInt(String? raw, int fallback) {
  final parsed = raw == null ? fallback : int.tryParse(raw) ?? fallback;
  return parsed <= 0 ? fallback : parsed;
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

final class _DoomFrameMonitor {
  _DoomFrameMonitor({
    required this.frameDirPath,
    required this.maxFramesToWrite,
  });

  final String frameDirPath;
  final int maxFramesToWrite;
  final List<String> callbackTrace = <String>[];
  final Set<int> uniqueFrameHashes = <int>{};
  final List<String> writtenFrames = <String>[];

  Memory? _memory;
  Uint8List? _palette;
  int _windowWidth = _doomDefaultWidth;
  int _windowHeight = _doomDefaultHeight;
  int frameCount = 0;
  int paletteUpdates = 0;

  ModuleImports get imports => _buildDoomEnvImports(this);

  bool get isHealthy => frameCount > 0 && writtenFrames.isNotEmpty;

  String get health {
    if (frameCount == 0) {
      return 'no_render_frame';
    }
    if (writtenFrames.isEmpty) {
      return 'no_frame_file';
    }
    if (uniqueFrameHashes.isEmpty) {
      return 'no_frame_hash';
    }
    return 'ok';
  }

  void bindMemory(Memory memory) {
    _memory = memory;
    Directory(frameDirPath).createSync(recursive: true);
  }

  Object? onOpenWindow(List<Object?> args) {
    _recordCallback('open_window', args);
    final values = args.map(_asIntOrNull).whereType<int>().toList();
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

  Object? onSetPalette(List<Object?> args) {
    _recordCallback('set_palette', args);
    final memory = _memory;
    if (memory == null || args.isEmpty) {
      return 0;
    }

    final ptr = _asIntOrNull(args.first);
    if (ptr == null || ptr < 0) {
      return 0;
    }

    final bytes = Uint8List.view(memory.buffer);
    final colors = args.length > 1
        ? _parsePositiveInt('${_asIntOrNull(args[1]) ?? 256}', 256)
        : 256;
    final paletteLength = colors * 3;
    if (ptr + paletteLength > bytes.length) {
      return 0;
    }

    _palette = Uint8List.fromList(bytes.sublist(ptr, ptr + paletteLength));
    paletteUpdates++;
    return 0;
  }

  Object? onRenderFrame(List<Object?> args) {
    _recordCallback('render_frame', args);
    frameCount++;

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
    final hash = _fnv1a32(indexed);
    uniqueFrameHashes.add(hash);

    if (writtenFrames.length >= maxFramesToWrite) {
      return 0;
    }

    final rgb = _indexedToRgb(indexed);
    final frameName = 'frame_${frameCount.toString().padLeft(6, '0')}.bmp';
    final framePath = '$frameDirPath/$frameName';
    _writeBmp24(path: framePath, width: width, height: height, rgb: rgb);
    writtenFrames.add(framePath);
    return 0;
  }

  Object? onPendingEvent(List<Object?> args) {
    _recordCallback('pending_event', args);
    return 0;
  }

  Object? onNextEvent(List<Object?> args) {
    _recordCallback('next_event', args);
    return 0;
  }

  Future<String> writeReport({
    required String mode,
    required String wasmPath,
    required String iwadPath,
    required int exitCode,
    required String health,
  }) async {
    final file = File('$frameDirPath/report.json');
    await file.parent.create(recursive: true);
    final map = <String, Object?>{
      'mode': mode,
      'wasm': wasmPath,
      'iwad': iwadPath,
      'exitCode': exitCode,
      'health': health,
      'frameCount': frameCount,
      'paletteUpdates': paletteUpdates,
      'windowSize': <String, int>{
        'width': _windowWidth,
        'height': _windowHeight,
      },
      'writtenFrames': writtenFrames,
      'uniqueFrameHashes': uniqueFrameHashes.length,
      'callbackTrace': callbackTrace,
    };
    await file.writeAsString(jsonEncode(map));
    return file.path;
  }

  (int, int) _resolveResolution(List<Object?> args) {
    final values = args.map(_asIntOrNull).whereType<int>().toList();
    for (var i = 0; i + 1 < values.length; i++) {
      final a = values[i];
      final b = values[i + 1];
      if (_isLikelyResolution(a, b)) {
        _windowWidth = a;
        _windowHeight = b;
        return (a, b);
      }
    }
    return (_windowWidth, _windowHeight);
  }

  int? _resolveFramePointer(
    List<Object?> args,
    int pixelCount,
    int memoryLength,
  ) {
    final values = args.map(_asIntOrNull).whereType<int>().toList();
    for (final value in values) {
      if (value < 0) {
        continue;
      }
      if (value + pixelCount <= memoryLength) {
        return value;
      }
    }
    if (pixelCount <= memoryLength) {
      return 0;
    }
    return null;
  }

  Uint8List _indexedToRgb(Uint8List indexed) {
    final rgb = Uint8List(indexed.length * 3);
    final palette = _palette;
    if (palette == null || palette.length < 3) {
      for (var i = 0; i < indexed.length; i++) {
        final value = indexed[i];
        final base = i * 3;
        rgb[base] = value;
        rgb[base + 1] = value;
        rgb[base + 2] = value;
      }
      return rgb;
    }

    final colorCount = palette.length ~/ 3;
    for (var i = 0; i < indexed.length; i++) {
      final colorIndex = indexed[i] % colorCount;
      final paletteBase = colorIndex * 3;
      final rgbBase = i * 3;
      rgb[rgbBase] = palette[paletteBase];
      rgb[rgbBase + 1] = palette[paletteBase + 1];
      rgb[rgbBase + 2] = palette[paletteBase + 2];
    }
    return rgb;
  }

  void _recordCallback(String name, List<Object?> args) {
    if (callbackTrace.length >= 24) {
      return;
    }
    callbackTrace.add('$name(${args.map(_describeArg).join(', ')})');
  }

  String _describeArg(Object? value) {
    if (value is int) {
      return value.toString();
    }
    if (value is num) {
      return value.toInt().toString();
    }
    if (value == null) {
      return 'null';
    }
    return value.runtimeType.toString();
  }
}

void _writeBmp24({
  required String path,
  required int width,
  required int height,
  required Uint8List rgb,
}) {
  final rowStride = width * 3;
  final paddedRowStride = (rowStride + 3) & ~3;
  final pixelDataSize = paddedRowStride * height;
  final fileSize = 14 + 40 + pixelDataSize;
  final out = Uint8List(fileSize);
  final data = ByteData.view(out.buffer);

  out[0] = 0x42; // B
  out[1] = 0x4d; // M
  data.setUint32(2, fileSize, Endian.little);
  data.setUint32(10, 54, Endian.little); // pixel array offset

  data.setUint32(14, 40, Endian.little); // DIB header size
  data.setInt32(18, width, Endian.little);
  data.setInt32(22, height, Endian.little);
  data.setUint16(26, 1, Endian.little); // planes
  data.setUint16(28, 24, Endian.little); // bpp
  data.setUint32(34, pixelDataSize, Endian.little);

  var dst = 54;
  for (var y = 0; y < height; y++) {
    final srcRow = (height - 1 - y) * rowStride;
    for (var x = 0; x < width; x++) {
      final src = srcRow + x * 3;
      out[dst++] = rgb[src + 2]; // B
      out[dst++] = rgb[src + 1]; // G
      out[dst++] = rgb[src]; // R
    }
    while ((dst - 54) % paddedRowStride != 0) {
      out[dst++] = 0;
    }
  }

  File(path).writeAsBytesSync(out, flush: true);
}

int _fnv1a32(Uint8List bytes) {
  var hash = 0x811c9dc5;
  for (final byte in bytes) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}
