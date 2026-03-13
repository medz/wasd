import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:wasd/wasm.dart';
import 'package:wasd/wasi.dart';

const String doomWasmAsset = 'assets/doom/doom.wasm';
const String doomIwadAsset = 'assets/doom/doom1.wad';
const String doomRunnerCommandStart = 'start';
const String guestRoot = '/doom';
const String guestIwadName = 'doom1.wad';
const int doomDefaultWidth = 320;
const int doomDefaultHeight = 200;
const bool _usesJsInterop = bool.fromEnvironment('dart.library.js_interop');

typedef DoomRunnerMessage = Map<String, Object?>;

DoomRunnerMessage normalizeDoomRunnerMessage(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  final normalized = <String, Object?>{};
  if (value is Map) {
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is String) {
        normalized[key] = entry.value;
      }
    }
  }
  return normalized;
}

final class DoomInputEvent {
  const DoomInputEvent({required this.type, required this.code});

  final int type;
  final int code;

  DoomRunnerMessage toMessage() => <String, Object?>{
    'type': 'input',
    'eventType': type,
    'code': code,
  };

  static DoomInputEvent? fromMessage(Object? message) {
    if (message is! Map<Object?, Object?>) {
      return null;
    }
    final type = _asIntOrNull(message['eventType']);
    final code = _asIntOrNull(message['code']);
    if (type == null || code == null) {
      return null;
    }
    return DoomInputEvent(type: type, code: code);
  }
}

final class DoomRuntime {
  DoomRuntime({required void Function(DoomRunnerMessage message) emit})
    : this.withInputDrain(emit: emit);

  DoomRuntime.withInputDrain({
    required void Function(DoomRunnerMessage message) emit,
    void Function(Queue<DoomInputEvent> queue)? drainInput,
  }) : _emit = emit,
       _drainInput = drainInput;

  final void Function(DoomRunnerMessage message) _emit;
  final void Function(Queue<DoomInputEvent> queue)? _drainInput;
  final Queue<DoomInputEvent> _queuedEvents = Queue<DoomInputEvent>();

  Memory? _memory;
  _PaletteData? _palette;
  int _windowWidth = doomDefaultWidth;
  int _windowHeight = doomDefaultHeight;
  int _frameCount = 0;

  void enqueueInput(DoomInputEvent event) {
    _queuedEvents.add(event);
  }

  Future<void> run({
    required Uint8List wasmBytes,
    required Uint8List iwadBytes,
  }) async {
    try {
      final wasi = WASI(
        args: const <String>[
          'doom.wasm',
          '-file',
          '$guestRoot/$guestIwadName',
          '-nosound',
        ],
        preopens: const <String, String>{guestRoot: guestRoot},
        files: <String, Uint8List>{'$guestRoot/$guestIwadName': iwadBytes},
        env: const <String, String>{
          'HOME': guestRoot,
          'TERM': 'xterm',
          'DOOMWADDIR': guestRoot,
          'DOOMWADPATH': guestRoot,
        },
      );

      final imports = <String, ModuleImports>{
        ...wasi.imports,
        'env': <String, ImportValue>{
          'ZwareDoomOpenWindow': ImportExportKind.function(_onOpenWindow),
          'ZwareDoomSetPalette': ImportExportKind.function(_onSetPalette),
          'ZwareDoomRenderFrame': ImportExportKind.function(_onRenderFrame),
          'ZwareDoomPendingEvent': ImportExportKind.function(
            _usesJsInterop ? _onPendingEvent : _onPendingEventAsync,
          ),
          'ZwareDoomNextEvent': ImportExportKind.function(
            _usesJsInterop ? _onNextEvent : _onNextEventAsync,
          ),
        },
      };

      _emit(<String, Object?>{
        'type': 'log',
        'line': 'instantiating module...',
      });
      enqueueBootstrapInputQueue(_queuedEvents);
      final result = await WebAssembly.instantiate(wasmBytes.buffer, imports);
      final memoryExport = result.instance.exports['memory'];
      if (memoryExport is MemoryImportExportValue) {
        _memory = memoryExport.ref;
      }

      _emit(<String, Object?>{'type': 'log', 'line': 'running wasi _start...'});
      if (!_usesJsInterop) {
        wasi.finalizeBindings(result.instance);
      }
      final exit = _usesJsInterop
          ? wasi.start(result.instance)
          : await _startAsync(result.instance);
      _emit(<String, Object?>{'type': 'exit', 'code': exit});
    } catch (error, stackTrace) {
      _emit(<String, Object?>{
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
    final bmp = encodeBmp24(width: width, height: height, rgb: rgb);
    _frameCount++;
    if (_frameCount == 1) {
      _emit(<String, Object?>{'type': 'log', 'line': 'received first frame'});
    }
    _emit(<String, Object?>{'type': 'frame', 'frame': _frameCount, 'bmp': bmp});
    return 0;
  }

  Object? _onPendingEvent(List<Object?> args) {
    _drainInput?.call(_queuedEvents);
    return _queuedEvents.isNotEmpty ? 1 : 0;
  }

  Future<Object?> _onPendingEventAsync(List<Object?> args) async {
    if (_onPendingEvent(args) == 1) {
      return 1;
    }
    await Future<void>.delayed(Duration.zero);
    return _onPendingEvent(args);
  }

  Object? _onNextEvent(List<Object?> args) {
    _drainInput?.call(_queuedEvents);
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
      if (!isI32PointerInBounds(typePtr, view) ||
          !isI32PointerInBounds(data1Ptr, view) ||
          !isI32PointerInBounds(data2Ptr, view) ||
          !isI32PointerInBounds(data3Ptr, view)) {
        return 0;
      }
      view.setInt32(typePtr!, event.type, Endian.little);
      view.setInt32(data1Ptr!, event.code, Endian.little);
      view.setInt32(data2Ptr!, 0, Endian.little);
      view.setInt32(data3Ptr!, 0, Endian.little);
      return 1;
    }

    final ptr = _asIntOrNull(args.first);
    if (!isI32PointerInBounds(ptr, view) || ptr! + 16 > view.lengthInBytes) {
      return 0;
    }
    view.setInt32(ptr, event.type, Endian.little);
    view.setInt32(ptr + 4, event.code, Endian.little);
    view.setInt32(ptr + 8, 0, Endian.little);
    view.setInt32(ptr + 12, 0, Endian.little);
    return 1;
  }

  Future<Object?> _onNextEventAsync(List<Object?> args) async {
    if (_queuedEvents.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    return _onNextEvent(args);
  }

  Future<int> _startAsync(Instance instance) async {
    final startExport = instance.exports['_start'];
    if (startExport is! FunctionImportExportValue) {
      throw StateError('WASI start target _start is missing.');
    }
    try {
      await Future<Object?>.sync(() => startExport.ref(const <Object?>[]));
      return 0;
    } catch (error) {
      if (error.runtimeType.toString() == '_WasiExit') {
        final exitCode = (error as dynamic).exitCode;
        if (exitCode is int) {
          return exitCode;
        }
      }
      rethrow;
    }
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
}

void enqueueBootstrapInputQueue(Queue<DoomInputEvent> queue) {
  const int enter = 13;
  const int space = 32;
  queue.addAll(const <DoomInputEvent>[
    DoomInputEvent(type: 0, code: enter),
    DoomInputEvent(type: 1, code: enter),
    DoomInputEvent(type: 0, code: space),
    DoomInputEvent(type: 1, code: space),
    DoomInputEvent(type: 0, code: enter),
    DoomInputEvent(type: 1, code: enter),
  ]);
}

int? asIntOrNull(Object? value) => _asIntOrNull(value);

Uint8List? messageBytesAsUint8List(Object? value) {
  if (value is Uint8List) {
    return value;
  }
  if (value is ByteBuffer) {
    return Uint8List.view(value);
  }
  if (value is List<Object?>) {
    return Uint8List.fromList(
      value
          .whereType<num>()
          .map((item) => item.toInt())
          .toList(growable: false),
    );
  }
  if (value is List<num>) {
    return Uint8List.fromList(
      value.map((item) => item.toInt()).toList(growable: false),
    );
  }
  return null;
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

bool isI32PointerInBounds(int? ptr, ByteData view) =>
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

(int, int)? decodeBmpDimensions(Uint8List? bmp) {
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

Uint8List encodeBmp24({
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
