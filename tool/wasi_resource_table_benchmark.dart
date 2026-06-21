import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wasd/src/wasi/component/async_host.dart';
import 'package:wasd/src/wasi/component/canonical_host.dart';
import 'package:wasd/src/wasi/component/error_context.dart';
import 'package:wasd/src/wasi/component/host.dart';
import 'package:wasd/src/wasi/component/resource_host.dart';
import 'package:wasd/src/wasi/component/resource_table.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/memory.dart';

const int _defaultIterations = 100000;
const int _defaultResources = 1024;
const int _warmupIterations = 1000;

Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  if (options.help) {
    _printUsage();
    return;
  }

  await _runWarmup(options);

  final insertGetDrop = _benchmarkInsertGetDrop(options.iterations);
  final borrow = _benchmarkBorrow(options);
  final borrowAsync = await _benchmarkBorrowAsync(options);
  final dropCallbacks = _benchmarkDropCallbacks(options.iterations);
  final programInvoke = _benchmarkProgramInvoke(options.iterations);
  final componentResourceBindings = _benchmarkComponentResourceBindings(
    options.iterations,
  );
  final componentHostBinding = _benchmarkComponentHostBinding(
    options.iterations,
  );
  final componentHostStreamBinding = _benchmarkComponentHostStreamBinding(
    options.iterations,
  );
  final componentHostStreamMemoryBinding =
      _benchmarkComponentHostStreamMemoryBinding(options.iterations);
  final canonicalHostProgram = _benchmarkCanonicalHostProgram(
    options.iterations,
  );
  final errorContextProgram = _benchmarkErrorContextProgram(options.iterations);
  final errorContextMemory = _benchmarkErrorContextMemory(options.iterations);

  final payload = <String, Object?>{
    'iterations': options.iterations,
    'resources': options.resources,
    'insert_get_drop': insertGetDrop.toJson(),
    'borrow': borrow.toJson(),
    'borrow_async': borrowAsync.toJson(),
    'drop_callbacks': dropCallbacks.toJson(),
    'program_invoke': programInvoke.toJson(),
    'component_resource_bindings': componentResourceBindings.toJson(),
    'component_host_binding': componentHostBinding.toJson(),
    'component_host_stream_binding': componentHostStreamBinding.toJson(),
    'component_host_stream_memory_binding': componentHostStreamMemoryBinding
        .toJson(),
    'canonical_host_program': canonicalHostProgram.toJson(),
    'error_context_program': errorContextProgram.toJson(),
    'error_context_memory': errorContextMemory.toJson(),
  };

  if (options.json) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(payload));
  } else {
    _printText(payload);
  }
}

Future<void> _runWarmup(_Options options) async {
  _benchmarkInsertGetDrop(_warmupIterations);
  _benchmarkBorrow(options.copyWith(iterations: _warmupIterations));
  await _benchmarkBorrowAsync(options.copyWith(iterations: _warmupIterations));
  _benchmarkDropCallbacks(_warmupIterations);
  _benchmarkProgramInvoke(_warmupIterations);
  _benchmarkComponentResourceBindings(_warmupIterations);
  _benchmarkComponentHostBinding(_warmupIterations);
  _benchmarkComponentHostStreamBinding(_warmupIterations);
  _benchmarkComponentHostStreamMemoryBinding(_warmupIterations);
  _benchmarkCanonicalHostProgram(_warmupIterations);
  _benchmarkErrorContextProgram(_warmupIterations);
  _benchmarkErrorContextMemory(_warmupIterations);
}

_Metric _benchmarkInsertGetDrop(int iterations) {
  final table = WASIComponentResourceTable();
  final resourceType = table.defineType<int>('resource');
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final handle = table.resourceNew<int>(resourceType, i);
    checksum += table.resourceRep<int>(resourceType, handle);
    table.resourceDrop<int>(resourceType, handle);
    if (table.contains(handle)) {
      throw StateError('stale handle remained live: $handle');
    }
  }
  watch.stop();

  if (table.activeCount != 0) {
    throw StateError('resource table leaked ${table.activeCount} resources');
  }
  return _Metric(
    operations: iterations * 4,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkBorrow(_Options options) {
  final table = WASIComponentResourceTable();
  final resourceType = table.defineType<int>('resource');
  final handles = <int>[];
  for (var i = 0; i < options.resources; i++) {
    handles.add(table.insert<int>(resourceType, i));
  }

  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final handle = handles[i % handles.length];
    table.borrow<int, void>(resourceType, handle, (resource) {
      checksum += resource;
    });
  }
  watch.stop();

  for (final handle in handles) {
    table.drop<int>(resourceType, handle);
  }
  if (table.activeCount != 0) {
    throw StateError('resource table leaked ${table.activeCount} resources');
  }
  return _Metric(
    operations: options.iterations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

Future<_Metric> _benchmarkBorrowAsync(_Options options) async {
  final table = WASIComponentResourceTable();
  final resourceType = table.defineType<int>('resource');
  final handles = <int>[];
  for (var i = 0; i < options.resources; i++) {
    handles.add(table.insert<int>(resourceType, i));
  }

  var checksum = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < options.iterations; i++) {
    final handle = handles[i % handles.length];
    checksum += await table.borrowAsync<int, int>(
      resourceType,
      handle,
      Future<int>.value,
    );
  }
  watch.stop();

  for (final handle in handles) {
    table.drop<int>(resourceType, handle);
  }
  if (table.activeCount != 0) {
    throw StateError('resource table leaked ${table.activeCount} resources');
  }
  return _Metric(
    operations: options.iterations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkDropCallbacks(int iterations) {
  final table = WASIComponentResourceTable();
  var checksum = 0;
  final resourceType = table.defineType<int>(
    'resource',
    onDrop: (resource) {
      checksum += resource;
    },
  );

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final handle = table.resourceNew<int>(resourceType, i);
    table.resourceDrop<int>(resourceType, handle);
  }
  watch.stop();

  if (table.activeCount != 0) {
    throw StateError('resource table leaked ${table.activeCount} resources');
  }
  return _Metric(
    operations: iterations * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkProgramInvoke(int iterations) {
  final component = WasmComponent.decode(_resourceProgramBytes());
  final host = WASIComponentResourceHost();
  host.defineResourceTypeFromComponent<int>(component, 0, 'resource');
  final program = host.bindCanonicalDefinitions(component);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final handle = program.invoke(0, <Object?>[i]);
    if (handle is! int) {
      throw StateError('resource.new returned non-handle: $handle');
    }
    final representation = program.invoke(1, <Object?>[handle]);
    if (representation is! int) {
      throw StateError('resource.rep returned non-int: $representation');
    }
    checksum += representation;
    program.invoke(2, <Object?>[handle]);
  }
  watch.stop();

  if (host.table.activeCount != 0) {
    throw StateError(
      'resource host table leaked ${host.table.activeCount} resources',
    );
  }
  return _Metric(
    operations: iterations * 3,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentResourceBindings(int iterations) {
  final component = WasmComponent.decode(_resourceProgramBytes());
  final host = WASIComponentResourceHost();
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final bindings = host.componentResourceBindings(component);
    final binding = bindings.single;
    checksum += binding.componentTypeIndex;
    checksum += binding.name.length;
    checksum += binding.representation.index;
    checksum += binding.isAbstract ? 1 : 0;
  }
  watch.stop();

  return _Metric(
    operations: iterations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentHostBinding(int iterations) {
  final component = WasmComponent.decode(_resourceProgramBytes());
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final host = WASIComponentHost();
    final binding = host.bindComponent(component);
    final handle = binding.program.invoke(0, <Object?>[i]);
    if (handle is! int) {
      throw StateError('component host resource.new returned non-handle');
    }
    final representation = binding.program.invoke(1, <Object?>[handle]);
    if (representation is! int) {
      throw StateError('component host resource.rep returned non-int');
    }
    checksum += representation;
    binding.program.invoke(2, <Object?>[handle]);
    if (host.table.activeCount != 0) {
      throw StateError(
        'component host table leaked ${host.table.activeCount} resources',
      );
    }
  }
  watch.stop();

  return _Metric(
    operations: iterations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentHostStreamBinding(int iterations) {
  final component = WasmComponent.decode(_streamProgramBytes());
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final host = WASIComponentHost();
    final binding = host.bindComponent(component);
    final packed = binding.program.invoke(0, const <Object?>[]);
    if (packed is! int) {
      throw StateError('component host stream.new returned non-i64');
    }
    final handles = WASIComponentAsyncEndpointHandles.unpack(packed);
    checksum +=
        binding.program.invoke(2, <Object?>[
              handles.writable,
              <Object?>[null],
            ])
            as int;
    final values =
        binding.program.invoke(1, <Object?>[handles.readable, 1])
            as List<Object?>;
    checksum += values.length;
    binding.program.invoke(5, <Object?>[handles.readable]);
    binding.program.invoke(6, <Object?>[handles.writable]);
    if (host.table.activeCount != 0) {
      throw StateError(
        'component host stream table leaked ${host.table.activeCount} resources',
      );
    }
  }
  watch.stop();

  return _Metric(
    operations: iterations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentHostStreamMemoryBinding(int iterations) {
  final component = WasmComponent.decode(_streamMemoryProgramBytes());
  final memory = Memory(const MemoryDescriptor(initial: 1));
  final data = ByteData.view(memory.buffer);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    data.setUint32(32, i & 0xffffffff, Endian.little);
    data.setUint32(36, (i + 1) & 0xffffffff, Endian.little);
    final host = WASIComponentHost();
    final binding = host.bindComponent(component);
    final packed = binding.program.invoke(0, const <Object?>[]);
    if (packed is! int) {
      throw StateError('component host stream.new returned non-i64');
    }
    final handles = WASIComponentAsyncEndpointHandles.unpack(packed);
    checksum +=
        binding.program.invokeWithMemory(2, memory, <Object?>[
              handles.writable,
              32,
              2,
            ])
            as int;
    checksum +=
        binding.program.invokeWithMemory(1, memory, <Object?>[
              handles.readable,
              96,
              2,
            ])
            as int;
    checksum += data.getUint32(96, Endian.little);
    checksum += data.getUint32(100, Endian.little);
    binding.program.invoke(3, <Object?>[handles.readable]);
    binding.program.invoke(4, <Object?>[handles.writable]);
    if (host.table.activeCount != 0) {
      throw StateError(
        'component host stream memory table leaked ${host.table.activeCount} resources',
      );
    }
  }
  watch.stop();

  return _Metric(
    operations: iterations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkCanonicalHostProgram(int iterations) {
  final host = WASIComponentCanonicalHost(availableParallelism: 4);
  host.resourceHost.defineResourceType<int>(0, 'resource');
  final program = host.bindCanonicalDefinitions(const [
    WasmComponentCanonicalDefinition(
      kind: WasmComponentCanonicalKind.resourceNew,
      typeIndex: 0,
    ),
    WasmComponentCanonicalDefinition(
      kind: WasmComponentCanonicalKind.resourceRep,
      typeIndex: 0,
    ),
    WasmComponentCanonicalDefinition(
      kind: WasmComponentCanonicalKind.contextSet,
      contextIndex: 0,
    ),
    WasmComponentCanonicalDefinition(
      kind: WasmComponentCanonicalKind.contextGet,
      contextIndex: 0,
    ),
    WasmComponentCanonicalDefinition(
      kind: WasmComponentCanonicalKind.threadIndex,
    ),
    WasmComponentCanonicalDefinition(
      kind: WasmComponentCanonicalKind.threadAvailableParallelism,
    ),
    WasmComponentCanonicalDefinition(
      kind: WasmComponentCanonicalKind.errorContextNew,
    ),
    WasmComponentCanonicalDefinition(
      kind: WasmComponentCanonicalKind.errorContextDebugMessage,
    ),
    WasmComponentCanonicalDefinition(
      kind: WasmComponentCanonicalKind.errorContextDrop,
    ),
    WasmComponentCanonicalDefinition(
      kind: WasmComponentCanonicalKind.resourceDrop,
      typeIndex: 0,
    ),
  ]);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final handle = program.invoke(0, <Object?>[i]);
    if (handle is! int) {
      throw StateError('canonical resource.new returned non-handle: $handle');
    }
    final representation = program.invoke(1, <Object?>[handle]);
    if (representation is! int) {
      throw StateError(
        'canonical resource.rep returned non-int: $representation',
      );
    }
    checksum += representation;
    program.invoke(2, <Object?>[i]);
    checksum += program.invoke(3, const <Object?>[]) as int;
    checksum += program.invoke(4, const <Object?>[]) as int;
    checksum += program.invoke(5, const <Object?>[]) as int;
    final errorContext = program.invoke(6, <Object?>['error-$i']);
    if (errorContext is! int) {
      throw StateError(
        'canonical error-context.new returned non-handle: $errorContext',
      );
    }
    final message = program.invoke(7, <Object?>[errorContext]);
    if (message is! String) {
      throw StateError(
        'canonical error-context.debug-message returned non-string: $message',
      );
    }
    checksum += message.length;
    program.invoke(8, <Object?>[errorContext]);
    program.invoke(9, <Object?>[handle]);
  }
  watch.stop();

  if (host.table.activeCount != 0) {
    throw StateError(
      'canonical host table leaked ${host.table.activeCount} resources',
    );
  }
  return _Metric(
    operations: iterations * 10,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkErrorContextProgram(int iterations) {
  final host = WASIComponentErrorContextHost();
  final program = WASIComponentCanonicalErrorContextProgram(
    operations: [
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextNew,
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextDebugMessage,
        ),
      ),
      host.bindCanonicalDefinition(
        const WasmComponentCanonicalDefinition(
          kind: WasmComponentCanonicalKind.errorContextDrop,
        ),
      ),
    ],
  );
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final handle = program.invoke(0, <Object?>['error-$i']);
    if (handle is! int) {
      throw StateError('error-context.new returned non-handle: $handle');
    }
    final message = program.invoke(1, <Object?>[handle]);
    if (message is! String) {
      throw StateError(
        'error-context.debug-message returned non-string: $message',
      );
    }
    checksum += message.length;
    program.invoke(2, <Object?>[handle]);
  }
  watch.stop();

  if (host.table.activeCount != 0) {
    throw StateError(
      'error-context host leaked ${host.table.activeCount} contexts',
    );
  }
  return _Metric(
    operations: iterations * 3,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkErrorContextMemory(int iterations) {
  final memory = Memory(const MemoryDescriptor(initial: 1));
  final bytes = Uint8List.view(memory.buffer);
  final inputPointer = 1024;
  final outputPointer = 4096;
  final resultPointer = 8192;
  final resultView = ByteData.view(memory.buffer);
  final inputBytes = utf8.encode('canonical error-context');
  final host = WASIComponentErrorContextHost();
  final newOperation = host.bindCanonicalDefinition(
    const WasmComponentCanonicalDefinition(
      kind: WasmComponentCanonicalKind.errorContextNew,
      options: [
        WasmComponentCanonicalOption(
          kind: WasmComponentCanonicalOptionKind.stringEncodingUtf8,
        ),
        WasmComponentCanonicalOption(
          kind: WasmComponentCanonicalOptionKind.memory,
          index: 0,
        ),
      ],
    ),
  );
  final debugOperation = host.bindCanonicalDefinition(
    const WasmComponentCanonicalDefinition(
      kind: WasmComponentCanonicalKind.errorContextDebugMessage,
      options: [
        WasmComponentCanonicalOption(
          kind: WasmComponentCanonicalOptionKind.stringEncodingUtf8,
        ),
        WasmComponentCanonicalOption(
          kind: WasmComponentCanonicalOptionKind.memory,
          index: 0,
        ),
        WasmComponentCanonicalOption(
          kind: WasmComponentCanonicalOptionKind.realloc,
          index: 0,
        ),
      ],
    ),
  );
  final dropOperation = host.bindCanonicalDefinition(
    const WasmComponentCanonicalDefinition(
      kind: WasmComponentCanonicalKind.errorContextDrop,
    ),
  );
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    bytes.setRange(inputPointer, inputPointer + inputBytes.length, inputBytes);
    final handle = newOperation.createFromMemory(
      memory,
      inputPointer,
      inputBytes.length,
    );
    final result = debugOperation.debugMessageIntoMemory(
      handle,
      memory,
      resultPointer,
      (oldPointer, oldSize, alignment, newSize) => outputPointer,
    );
    checksum += result.byteLength;
    checksum += resultView.getUint32(resultPointer + 4, Endian.little);
    checksum += bytes[outputPointer];
    dropOperation.drop(handle);
  }
  watch.stop();

  if (host.table.activeCount != 0) {
    throw StateError(
      'error-context memory host leaked ${host.table.activeCount} contexts',
    );
  }
  return _Metric(
    operations: iterations * 7,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

void _printText(Map<String, Object?> payload) {
  stdout
    ..writeln('WASI component resource table benchmark')
    ..writeln('  iterations: ${payload['iterations']}')
    ..writeln('  resources: ${payload['resources']}');
  for (final name in const <String>[
    'insert_get_drop',
    'borrow',
    'borrow_async',
    'drop_callbacks',
    'program_invoke',
    'component_resource_bindings',
    'component_host_binding',
    'component_host_stream_binding',
    'component_host_stream_memory_binding',
    'canonical_host_program',
    'error_context_program',
    'error_context_memory',
  ]) {
    final metric = payload[name]! as Map<String, Object?>;
    stdout
      ..writeln('  $name operations: ${metric['operations']}')
      ..writeln('  $name total us: ${metric['total_us']}')
      ..writeln('  $name per operation us: ${metric['per_operation_us']}');
  }
}

Uint8List _resourceProgramBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x04,
  0x01,
  0x3f,
  0x7f,
  0x00,
  0x08,
  0x07,
  0x03,
  0x02,
  0x00,
  0x04,
  0x00,
  0x03,
  0x00,
]);

Uint8List _streamProgramBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x07,
  0x03,
  0x01,
  0x66,
  0x00,
  0x08,
  0x13,
  0x07,
  0x0e,
  0x00,
  0x0f,
  0x00,
  0x00,
  0x10,
  0x00,
  0x00,
  0x11,
  0x00,
  0x00,
  0x12,
  0x00,
  0x00,
  0x13,
  0x00,
  0x14,
  0x00,
]);

Uint8List _streamMemoryProgramBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x01,
  0x16,
  0x00,
  0x61,
  0x73,
  0x6d,
  0x01,
  0x00,
  0x00,
  0x00,
  0x05,
  0x03,
  0x01,
  0x00,
  0x01,
  0x07,
  0x07,
  0x01,
  0x03,
  0x6d,
  0x65,
  0x6d,
  0x02,
  0x00,
  0x02,
  0x04,
  0x01,
  0x00,
  0x00,
  0x00,
  0x07,
  0x04,
  0x01,
  0x66,
  0x01,
  0x79,
  0x08,
  0x03,
  0x01,
  0x0e,
  0x00,
  0x06,
  0x09,
  0x01,
  0x00,
  0x02,
  0x01,
  0x00,
  0x03,
  0x6d,
  0x65,
  0x6d,
  0x08,
  0x06,
  0x01,
  0x0f,
  0x00,
  0x01,
  0x03,
  0x00,
  0x06,
  0x09,
  0x01,
  0x00,
  0x02,
  0x01,
  0x00,
  0x03,
  0x6d,
  0x65,
  0x6d,
  0x08,
  0x0a,
  0x03,
  0x10,
  0x00,
  0x01,
  0x03,
  0x01,
  0x13,
  0x00,
  0x14,
  0x00,
]);

void _printUsage() {
  stdout.writeln('''
Usage: dart run tool/wasi_resource_table_benchmark.dart [options]

Options:
  --iterations=<n>  Operation repetitions. Default: $_defaultIterations.
  --resources=<n>   Live resources for borrow lookup. Default: $_defaultResources.
  --json            Print machine-readable JSON.
  --help            Show this help.
''');
}

final class _Metric {
  const _Metric({
    required this.operations,
    required this.totalMicros,
    required this.checksum,
  });

  final int operations;
  final int totalMicros;
  final int checksum;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'operations': operations,
      'total_us': totalMicros,
      'per_operation_us': totalMicros / operations,
      'checksum': checksum,
    };
  }
}

final class _Options {
  const _Options({
    required this.iterations,
    required this.resources,
    required this.json,
    required this.help,
  });

  final int iterations;
  final int resources;
  final bool json;
  final bool help;

  _Options copyWith({int? iterations, int? resources}) {
    return _Options(
      iterations: iterations ?? this.iterations,
      resources: resources ?? this.resources,
      json: json,
      help: help,
    );
  }

  factory _Options.parse(List<String> args) {
    var iterations = _defaultIterations;
    var resources = _defaultResources;
    var json = false;
    var help = false;

    for (final arg in args) {
      if (arg == '--json') {
        json = true;
      } else if (arg == '--help' || arg == '-h') {
        help = true;
      } else if (arg.startsWith('--iterations=')) {
        iterations = _positiveInt(arg, '--iterations');
      } else if (arg.startsWith('--resources=')) {
        resources = _positiveInt(arg, '--resources');
      } else {
        throw ArgumentError('Unsupported argument: $arg');
      }
    }

    return _Options(
      iterations: iterations,
      resources: resources,
      json: json,
      help: help,
    );
  }

  static int _positiveInt(String arg, String name) {
    final value = int.tryParse(arg.substring(name.length + 1));
    if (value == null || value <= 0) {
      throw ArgumentError('$name must be a positive integer.');
    }
    return value;
  }
}
