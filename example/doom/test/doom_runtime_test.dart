import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wasd/wasd.dart';

const String _doomWasmPath = 'assets/doom/doom.wasm';
const String _doomIwadPath = 'assets/doom/doom1.wad';

void main() {
  test('doom wasm + wad boots and renders first frame', () async {
    final wasmFile = File(_doomWasmPath);
    final iwadFile = File(_doomIwadPath);
    if (!wasmFile.existsSync() || !iwadFile.existsSync()) {
      fail(
        'Missing Doom assets.\n'
        'Run: tool/setup_assets.sh\n'
        'Expected files: $_doomWasmPath and $_doomIwadPath',
      );
    }

    final wasmBytes = await wasmFile.readAsBytes();
    final iwadBytes = await iwadFile.readAsBytes();

    final port = ReceivePort();
    final isolate = await Isolate.spawn<Map<String, Object?>>(_runDoomSmoke, {
      'port': port.sendPort,
      'wasm': TransferableTypedData.fromList(<Uint8List>[wasmBytes]),
      'iwad': TransferableTypedData.fromList(<Uint8List>[iwadBytes]),
    });

    addTearDown(() {
      isolate.kill(priority: Isolate.immediate);
      port.close();
    });

    final raw = await port.first.timeout(
      const Duration(seconds: 60),
      onTimeout: () => <String, Object?>{
        'ok': false,
        'error': 'Timed out waiting for Doom first frame.',
      },
    );

    if (raw is! Map) {
      fail('Unexpected isolate result type: ${raw.runtimeType}');
    }
    final result = raw.cast<String, Object?>();
    if (result['ok'] != true) {
      fail('Doom smoke test failed: ${result['error']}');
    }

    final frames = result['frames'];
    expect(frames, isA<int>());
    expect(frames! as int, greaterThanOrEqualTo(1));
    expect(result['paletteSet'], isTrue);
  });
}

void _runDoomSmoke(Map<String, Object?> args) {
  final port = args['port'] as SendPort;
  final wasmBytes = (args['wasm'] as TransferableTypedData)
      .materialize()
      .asUint8List();
  final iwadBytes = (args['iwad'] as TransferableTypedData)
      .materialize()
      .asUint8List();

  try {
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
    final host = _DoomSmokeHost();
    final imports = <String, WasmHostFunction>{
      ...wasi.imports.functions,
      ...host.imports,
    };
    final instance = WasmInstance.fromBytes(
      wasmBytes,
      imports: WasmImports(functions: imports),
    );
    wasi.bindInstance(instance);
    host.bindMemory(instance.exportedMemory('memory'));
    instance.invoke('_start');

    port.send(<String, Object?>{
      'ok': false,
      'error': 'doom _start returned before rendering a frame',
    });
  } on _DoomFirstFrame catch (event) {
    port.send(<String, Object?>{
      'ok': true,
      'frames': event.frames,
      'paletteSet': event.paletteSet,
    });
  } catch (error, stackTrace) {
    port.send(<String, Object?>{'ok': false, 'error': '$error\n$stackTrace'});
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

final class _DoomSmokeHost {
  final Uint8List _palette = Uint8List(1024);
  WasmMemory? _memory;
  bool _paletteSet = false;
  int _frames = 0;

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
    _paletteSet = true;
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
    final ptr = _asI32(args, 0, 'frame_ptr');
    final len = _asI32(args, 1, 'frame_len');
    if (len <= 0) {
      return 0;
    }
    memory.readBytes(ptr, len);
    _frames++;
    throw _DoomFirstFrame(frames: _frames, paletteSet: _paletteSet);
  }

  WasmMemory _requireMemory() {
    final memory = _memory;
    if (memory == null) {
      throw StateError('Doom smoke host memory is not bound.');
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

final class _DoomFirstFrame implements Exception {
  const _DoomFirstFrame({required this.frames, required this.paletteSet});

  final int frames;
  final bool paletteSet;
}
