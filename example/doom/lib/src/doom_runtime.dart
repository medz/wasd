import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:wasd/wasm.dart';
import 'package:wasd/wasi.dart';

const String doomWasmAsset = 'assets/doom/doom.wasm';
const String doomIwadAsset = 'assets/doom/doom1.wad';
const String doomRunnerCommandStart = 'start';
const String doomRunnerMessageFrame = 'frame';
const String doomRunnerMessageExit = 'exit';
const String doomRunnerMessageError = 'error';
const String doomRunnerMessageInputPort = 'input-port';
const String doomFrameFormatBmp = 'bmp';
const String doomFrameFormatRgba = 'rgba';
const String guestRoot = '/doom';
const String guestIwadName = 'doom1.wad';
const int doomDefaultWidth = 320;
const int doomDefaultHeight = 200;
const int doomNativeTargetFrameIntervalUs = 28000;
const int doomEventTypeKeyDown = 0;
const int doomEventTypeKeyUp = 1;
const int doomKeyRight = 0xae;
const int doomKeyLeft = 0xac;
const int doomKeyUp = 0xad;
const int doomKeyDown = 0xaf;
const int doomKeyEscape = 27;
const int doomKeyEnter = 13;
const int doomKeyTab = 9;
const int doomKeyBackspace = 127;
const int doomKeyCtrl = 0x9d;
const int doomKeyAlt = 0xb8;
const int doomKeyShift = 0xb6;
const bool usesJsInterop = bool.fromEnvironment('dart.library.js_interop');

typedef DoomRunnerMessage = Map<String, Object?>;

enum DoomFrameTransport { bmp, rgba }

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

  List<int> toNativeMessage() => <int>[type, code];

  static DoomInputEvent? fromNativeMessage(Object? message) {
    if (message is! List || message.length != 2) {
      return null;
    }
    final type = _asIntOrNull(message[0]);
    final code = _asIntOrNull(message[1]);
    if (type == null || code == null) {
      return null;
    }
    return DoomInputEvent(type: type, code: code);
  }
}

final class DoomRuntime {
  DoomRuntime({
    required void Function(DoomRunnerMessage message) emit,
    required this.frameTransport,
    this.frameIntervalUs = 0,
  }) : _emit = emit,
       _drainInput = null;

  DoomRuntime.withInputDrain({
    required void Function(DoomRunnerMessage message) emit,
    required this.frameTransport,
    this.frameIntervalUs = 0,
    void Function(Queue<DoomInputEvent> queue)? drainInput,
  }) : _emit = emit,
       _drainInput = drainInput;

  final void Function(DoomRunnerMessage message) _emit;
  final void Function(Queue<DoomInputEvent> queue)? _drainInput;
  final DoomFrameTransport frameTransport;
  final int frameIntervalUs;
  final Queue<DoomInputEvent> _queuedEvents = Queue<DoomInputEvent>();
  final Stopwatch _frameClock = Stopwatch()..start();

  Memory? _memory;
  _PaletteData? _palette;
  int _windowWidth = doomDefaultWidth;
  int _windowHeight = doomDefaultHeight;
  int _frameCount = 0;
  int _lastFrameSentUs = 0;
  int _lastEventYieldUs = 0;

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
            usesJsInterop ? _onPendingEvent : _onPendingEventAsync,
          ),
          'ZwareDoomNextEvent': ImportExportKind.function(
            usesJsInterop ? _onNextEvent : _onNextEventAsync,
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
      if (!usesJsInterop) {
        wasi.finalizeBindings(result.instance);
      }
      final exit = usesJsInterop
          ? wasi.start(result.instance)
          : await _startAsync(result.instance);
      _emit(<String, Object?>{'type': doomRunnerMessageExit, 'code': exit});
    } catch (error, stackTrace) {
      _emit(<String, Object?>{
        'type': doomRunnerMessageError,
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
    return 1;
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

    if (frameIntervalUs > 0) {
      final nowUs = _frameClock.elapsedMicroseconds;
      if (nowUs - _lastFrameSentUs < frameIntervalUs) {
        return 0;
      }
      _lastFrameSentUs = nowUs;
    }

    final indexed = Uint8List.fromList(bytes.sublist(ptr, ptr + pixelCount));
    final frameBytes = switch (frameTransport) {
      DoomFrameTransport.bmp => encodeBmp24(
        width: width,
        height: height,
        rgb: _indexedToRgb(indexed, _palette),
      ),
      DoomFrameTransport.rgba => _indexedToRgba(indexed, _palette),
    };
    _frameCount++;
    if (_frameCount == 1) {
      _emit(<String, Object?>{'type': 'log', 'line': 'received first frame'});
    }
    _emit(<String, Object?>{
      'type': doomRunnerMessageFrame,
      'format': frameTransport == DoomFrameTransport.bmp
          ? doomFrameFormatBmp
          : doomFrameFormatRgba,
      'width': width,
      'height': height,
      'bytes': frameBytes,
    });
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
    await _yieldToEventLoopIfNeeded();
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
      await _yieldToEventLoopIfNeeded();
      if (_queuedEvents.isEmpty) {
        return 0;
      }
    }
    return _onNextEvent(args);
  }

  Future<void> _yieldToEventLoopIfNeeded() async {
    final nowUs = _frameClock.elapsedMicroseconds;
    if (nowUs - _lastEventYieldUs < 2000) {
      return;
    }
    _lastEventYieldUs = nowUs;
    await Future<void>.delayed(Duration.zero);
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
  queue.addAll(const <DoomInputEvent>[
    DoomInputEvent(type: doomEventTypeKeyDown, code: doomKeyEnter),
    DoomInputEvent(type: doomEventTypeKeyUp, code: doomKeyEnter),
    DoomInputEvent(type: doomEventTypeKeyDown, code: 32),
    DoomInputEvent(type: doomEventTypeKeyUp, code: 32),
    DoomInputEvent(type: doomEventTypeKeyDown, code: doomKeyEnter),
    DoomInputEvent(type: doomEventTypeKeyUp, code: doomKeyEnter),
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

Uint8List _indexedToRgba(Uint8List indexed, _PaletteData? palette) {
  final rgba = Uint8List(indexed.length * 4);
  if (palette == null || palette.bytes.length < 3) {
    for (var i = 0; i < indexed.length; i++) {
      final value = indexed[i];
      final base = i * 4;
      rgba[base] = value;
      rgba[base + 1] = value;
      rgba[base + 2] = value;
      rgba[base + 3] = 255;
    }
    return rgba;
  }

  final colorCount = palette.bytes.length ~/ palette.stride;
  for (var i = 0; i < indexed.length; i++) {
    final idx = indexed[i] % colorCount;
    final src = idx * palette.stride;
    final dst = i * 4;
    var r = palette.bytes[src];
    var g = palette.bytes[src + 1];
    var b = palette.bytes[src + 2];
    if (palette.isSixBit) {
      r = _paletteExpand6To8(r);
      g = _paletteExpand6To8(g);
      b = _paletteExpand6To8(b);
    }
    rgba[dst] = r;
    rgba[dst + 1] = g;
    rgba[dst + 2] = b;
    rgba[dst + 3] = 255;
  }
  return rgba;
}

_PaletteData? _extractPalette(Uint8List memory, int ptr, int? hint) {
  if (ptr >= memory.length) {
    return null;
  }
  const int paletteEntries = 256;
  final available = memory.length - ptr;

  if (hint != null &&
      hint >= paletteEntries * 4 &&
      ptr + hint <= memory.length) {
    return _PaletteData(
      Uint8List.fromList(memory.sublist(ptr, ptr + paletteEntries * 4)),
      4,
      false,
    );
  }

  if (available >= paletteEntries * 4) {
    final candidate = memory.sublist(ptr, ptr + paletteEntries * 4);
    var looksLikeRgba = true;
    for (var i = 3; i < candidate.length; i += 4) {
      final alpha = candidate[i];
      if (alpha != 0 && alpha != 255) {
        looksLikeRgba = false;
        break;
      }
    }
    if (looksLikeRgba) {
      return _PaletteData(Uint8List.fromList(candidate), 4, false);
    }
  }

  if (hint != null &&
      hint >= paletteEntries * 3 &&
      ptr + hint <= memory.length) {
    final candidate = Uint8List.fromList(
      memory.sublist(ptr, ptr + paletteEntries * 3),
    );
    return _PaletteData(candidate, 3, _paletteLooksSixBit(candidate));
  }

  if (available >= paletteEntries * 3) {
    final candidate = Uint8List.fromList(
      memory.sublist(ptr, ptr + paletteEntries * 3),
    );
    return _PaletteData(candidate, 3, _paletteLooksSixBit(candidate));
  }

  return null;
}

bool _paletteLooksSixBit(Uint8List palette) =>
    palette.isNotEmpty && palette.every((value) => value <= 63);

int _paletteExpand6To8(int value) => ((value * 255) ~/ 63).clamp(0, 255);

Uint8List encodeBmp24({
  required int width,
  required int height,
  required Uint8List rgb,
}) {
  final rowStride = width * 3;
  final rowPad = (4 - rowStride % 4) % 4;
  final pixelBytes = (rowStride + rowPad) * height;
  const headerBytes = 54;
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

final class _PaletteData {
  const _PaletteData(this.bytes, this.stride, this.isSixBit);

  final Uint8List bytes;
  final int stride;
  final bool isSixBit;
}
