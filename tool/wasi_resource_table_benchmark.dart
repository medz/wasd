import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wasd/src/wasi/component/adapter_host.dart';
import 'package:wasd/src/wasi/component/adapter_plan.dart';
import 'package:wasd/src/wasi/component/async_host.dart';
import 'package:wasd/src/wasi/component/canonical_host.dart';
import 'package:wasd/src/wasi/component/error_context.dart';
import 'package:wasd/src/wasi/component/host.dart';
import 'package:wasd/src/wasi/component/resource_host.dart';
import 'package:wasd/src/wasi/component/resource_table.dart';
import 'package:wasd/src/wasi/component/string_memory.dart';
import 'package:wasd/src/wasi/component/value_memory.dart';
import 'package:wasd/src/wasi/component/wit_document.dart';
import 'package:wasd/src/wasi/preview2/component_host.dart';
import 'package:wasd/src/wasi/preview3/component_host.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/component.dart';
import 'package:wasd/src/wasm/memory.dart';

import '../test/support/component_fixtures.dart' as component_fixtures;

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
  final componentVersionedPreview2Binding =
      _benchmarkComponentVersionedPreview2Binding(options.iterations);
  final componentHostStreamBinding = _benchmarkComponentHostStreamBinding(
    options.iterations,
  );
  final componentVersionedPreview3StreamBinding =
      _benchmarkComponentVersionedPreview3StreamBinding(options.iterations);
  final componentAdapterDirectInvoke = _benchmarkComponentAdapterDirectInvoke(
    options.iterations,
  );
  final componentAdapterProgramInvoke = _benchmarkComponentAdapterProgramInvoke(
    options.iterations,
  );
  final componentVersionedAdapterProgramInvoke =
      _benchmarkComponentVersionedAdapterProgramInvoke(options.iterations);
  final componentWitAdapterProgramInvoke =
      _benchmarkComponentWitAdapterProgramInvoke(options.iterations);
  final componentWitCompositeAdapterProgramInvoke =
      _benchmarkComponentWitCompositeAdapterProgramInvoke(options.iterations);
  final componentWitListTupleAdapterProgramInvoke =
      _benchmarkComponentWitListTupleAdapterProgramInvoke(options.iterations);
  final componentWitRecordAdapterProgramInvoke =
      _benchmarkComponentWitRecordAdapterProgramInvoke(options.iterations);
  final componentAdapterStringProgramInvoke =
      _benchmarkComponentAdapterStringProgramInvoke(options.iterations);
  final componentAdapterStringFlatInvoke =
      _benchmarkComponentAdapterStringFlatInvoke(options.iterations);
  final componentAdapterRecordFlatInvoke =
      _benchmarkComponentAdapterRecordFlatInvoke(options.iterations);
  final componentAdapterTupleFlatInvoke =
      _benchmarkComponentAdapterTupleFlatInvoke(options.iterations);
  final componentAdapterFixedListFlatInvoke =
      _benchmarkComponentAdapterFixedListFlatInvoke(options.iterations);
  final componentAdapterFlagsEnumFlatInvoke =
      _benchmarkComponentAdapterFlagsEnumFlatInvoke(options.iterations);
  final componentAdapterListFlatInvoke =
      _benchmarkComponentAdapterListFlatInvoke(options.iterations);
  final componentAdapterVariantFlatInvoke =
      _benchmarkComponentAdapterVariantFlatInvoke(options.iterations);
  final componentAdapterOptionFlatInvoke =
      _benchmarkComponentAdapterOptionFlatInvoke(options.iterations);
  final componentAdapterResultFlatInvoke =
      _benchmarkComponentAdapterResultFlatInvoke(options.iterations);
  final componentAdapterResourceDirectInvoke =
      _benchmarkComponentAdapterResourceDirectInvoke(options.iterations);
  final componentAdapterResourceFlatInvoke =
      _benchmarkComponentAdapterResourceFlatInvoke(options.iterations);
  final componentAdapterResourceMemoryInvoke =
      _benchmarkComponentAdapterResourceMemoryInvoke(options.iterations);
  final componentAdapterResourceRecordMemoryInvoke =
      _benchmarkComponentAdapterResourceRecordMemoryInvoke(options.iterations);
  final componentAdapterErrorContextDirectInvoke =
      _benchmarkComponentAdapterErrorContextDirectInvoke(options.iterations);
  final componentAdapterErrorContextFlatInvoke =
      _benchmarkComponentAdapterErrorContextFlatInvoke(options.iterations);
  final componentAdapterErrorContextMemoryInvoke =
      _benchmarkComponentAdapterErrorContextMemoryInvoke(options.iterations);
  final componentAdapterStringMemoryInvoke =
      _benchmarkComponentAdapterStringMemoryInvoke(options.iterations);
  final componentHostStreamMemoryBinding =
      _benchmarkComponentHostStreamMemoryBinding(options.iterations);
  final componentHostOwnedResourceStreamMemoryBinding =
      _benchmarkComponentHostOwnedResourceStreamMemoryBinding(
        options.iterations,
      );
  final componentHostRecordStreamMemoryBinding =
      _benchmarkComponentHostRecordStreamMemoryBinding(options.iterations);
  final componentHostListStreamMemoryBinding =
      _benchmarkComponentHostListStreamMemoryBinding(options.iterations);
  final componentHostStringListStreamMemoryBinding =
      _benchmarkComponentHostStringListStreamMemoryBinding(options.iterations);
  final componentHostListFutureMemoryBinding =
      _benchmarkComponentHostListFutureMemoryBinding(options.iterations);
  final componentHostStringListFutureMemoryBinding =
      _benchmarkComponentHostStringListFutureMemoryBinding(options.iterations);
  final componentHostFutureMemoryBinding =
      _benchmarkComponentHostFutureMemoryBinding(options.iterations);
  final componentHostOwnedResourceFutureMemoryBinding =
      _benchmarkComponentHostOwnedResourceFutureMemoryBinding(
        options.iterations,
      );
  final canonicalHostProgram = _benchmarkCanonicalHostProgram(
    options.iterations,
  );
  final errorContextProgram = _benchmarkErrorContextProgram(options.iterations);
  final errorContextMemory = _benchmarkErrorContextMemory(options.iterations);
  final canonicalVariantStore = _benchmarkCanonicalVariantStore(
    options.iterations,
  );

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
    'component_versioned_preview2_binding': componentVersionedPreview2Binding
        .toJson(),
    'component_host_stream_binding': componentHostStreamBinding.toJson(),
    'component_versioned_preview3_stream_binding':
        componentVersionedPreview3StreamBinding.toJson(),
    'component_adapter_direct_invoke': componentAdapterDirectInvoke.toJson(),
    'component_adapter_program_invoke': componentAdapterProgramInvoke.toJson(),
    'component_versioned_adapter_program_invoke':
        componentVersionedAdapterProgramInvoke.toJson(),
    'component_wit_adapter_program_invoke': componentWitAdapterProgramInvoke
        .toJson(),
    'component_wit_composite_adapter_program_invoke':
        componentWitCompositeAdapterProgramInvoke.toJson(),
    'component_wit_list_tuple_adapter_program_invoke':
        componentWitListTupleAdapterProgramInvoke.toJson(),
    'component_wit_record_adapter_program_invoke':
        componentWitRecordAdapterProgramInvoke.toJson(),
    'component_adapter_string_program_invoke':
        componentAdapterStringProgramInvoke.toJson(),
    'component_adapter_string_flat_invoke': componentAdapterStringFlatInvoke
        .toJson(),
    'component_adapter_record_flat_invoke': componentAdapterRecordFlatInvoke
        .toJson(),
    'component_adapter_tuple_flat_invoke': componentAdapterTupleFlatInvoke
        .toJson(),
    'component_adapter_fixed_list_flat_invoke':
        componentAdapterFixedListFlatInvoke.toJson(),
    'component_adapter_flags_enum_flat_invoke':
        componentAdapterFlagsEnumFlatInvoke.toJson(),
    'component_adapter_list_flat_invoke': componentAdapterListFlatInvoke
        .toJson(),
    'component_adapter_variant_flat_invoke': componentAdapterVariantFlatInvoke
        .toJson(),
    'component_adapter_option_flat_invoke': componentAdapterOptionFlatInvoke
        .toJson(),
    'component_adapter_result_flat_invoke': componentAdapterResultFlatInvoke
        .toJson(),
    'component_adapter_resource_direct_invoke':
        componentAdapterResourceDirectInvoke.toJson(),
    'component_adapter_resource_flat_invoke': componentAdapterResourceFlatInvoke
        .toJson(),
    'component_adapter_resource_memory_invoke':
        componentAdapterResourceMemoryInvoke.toJson(),
    'component_adapter_resource_record_memory_invoke':
        componentAdapterResourceRecordMemoryInvoke.toJson(),
    'component_adapter_error_context_direct_invoke':
        componentAdapterErrorContextDirectInvoke.toJson(),
    'component_adapter_error_context_flat_invoke':
        componentAdapterErrorContextFlatInvoke.toJson(),
    'component_adapter_error_context_memory_invoke':
        componentAdapterErrorContextMemoryInvoke.toJson(),
    'component_adapter_string_memory_invoke': componentAdapterStringMemoryInvoke
        .toJson(),
    'component_host_stream_memory_binding': componentHostStreamMemoryBinding
        .toJson(),
    'component_host_owned_resource_stream_memory_binding':
        componentHostOwnedResourceStreamMemoryBinding.toJson(),
    'component_host_record_stream_memory_binding':
        componentHostRecordStreamMemoryBinding.toJson(),
    'component_host_list_stream_memory_binding':
        componentHostListStreamMemoryBinding.toJson(),
    'component_host_string_list_stream_memory_binding':
        componentHostStringListStreamMemoryBinding.toJson(),
    'component_host_list_future_memory_binding':
        componentHostListFutureMemoryBinding.toJson(),
    'component_host_string_list_future_memory_binding':
        componentHostStringListFutureMemoryBinding.toJson(),
    'component_host_future_memory_binding': componentHostFutureMemoryBinding
        .toJson(),
    'component_host_owned_resource_future_memory_binding':
        componentHostOwnedResourceFutureMemoryBinding.toJson(),
    'canonical_host_program': canonicalHostProgram.toJson(),
    'error_context_program': errorContextProgram.toJson(),
    'error_context_memory': errorContextMemory.toJson(),
    'canonical_variant_store': canonicalVariantStore.toJson(),
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
  _benchmarkComponentVersionedPreview2Binding(_warmupIterations);
  _benchmarkComponentHostStreamBinding(_warmupIterations);
  _benchmarkComponentVersionedPreview3StreamBinding(_warmupIterations);
  _benchmarkComponentAdapterDirectInvoke(_warmupIterations);
  _benchmarkComponentAdapterProgramInvoke(_warmupIterations);
  _benchmarkComponentVersionedAdapterProgramInvoke(_warmupIterations);
  _benchmarkComponentWitAdapterProgramInvoke(_warmupIterations);
  _benchmarkComponentWitCompositeAdapterProgramInvoke(_warmupIterations);
  _benchmarkComponentWitListTupleAdapterProgramInvoke(_warmupIterations);
  _benchmarkComponentWitRecordAdapterProgramInvoke(_warmupIterations);
  _benchmarkComponentAdapterStringProgramInvoke(_warmupIterations);
  _benchmarkComponentAdapterStringFlatInvoke(_warmupIterations);
  _benchmarkComponentAdapterRecordFlatInvoke(_warmupIterations);
  _benchmarkComponentAdapterTupleFlatInvoke(_warmupIterations);
  _benchmarkComponentAdapterFixedListFlatInvoke(_warmupIterations);
  _benchmarkComponentAdapterFlagsEnumFlatInvoke(_warmupIterations);
  _benchmarkComponentAdapterListFlatInvoke(_warmupIterations);
  _benchmarkComponentAdapterVariantFlatInvoke(_warmupIterations);
  _benchmarkComponentAdapterOptionFlatInvoke(_warmupIterations);
  _benchmarkComponentAdapterResultFlatInvoke(_warmupIterations);
  _benchmarkComponentAdapterResourceDirectInvoke(_warmupIterations);
  _benchmarkComponentAdapterResourceFlatInvoke(_warmupIterations);
  _benchmarkComponentAdapterResourceMemoryInvoke(_warmupIterations);
  _benchmarkComponentAdapterResourceRecordMemoryInvoke(_warmupIterations);
  _benchmarkComponentAdapterErrorContextDirectInvoke(_warmupIterations);
  _benchmarkComponentAdapterErrorContextFlatInvoke(_warmupIterations);
  _benchmarkComponentAdapterErrorContextMemoryInvoke(_warmupIterations);
  _benchmarkComponentAdapterStringMemoryInvoke(_warmupIterations);
  _benchmarkComponentHostStreamMemoryBinding(_warmupIterations);
  _benchmarkComponentHostOwnedResourceStreamMemoryBinding(_warmupIterations);
  _benchmarkComponentHostRecordStreamMemoryBinding(_warmupIterations);
  _benchmarkComponentHostListStreamMemoryBinding(_warmupIterations);
  _benchmarkComponentHostStringListStreamMemoryBinding(_warmupIterations);
  _benchmarkComponentHostListFutureMemoryBinding(_warmupIterations);
  _benchmarkComponentHostStringListFutureMemoryBinding(_warmupIterations);
  _benchmarkComponentHostFutureMemoryBinding(_warmupIterations);
  _benchmarkComponentHostOwnedResourceFutureMemoryBinding(_warmupIterations);
  _benchmarkCanonicalHostProgram(_warmupIterations);
  _benchmarkErrorContextProgram(_warmupIterations);
  _benchmarkErrorContextMemory(_warmupIterations);
  _benchmarkCanonicalVariantStore(_warmupIterations);
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

_Metric _benchmarkComponentVersionedPreview2Binding(int iterations) {
  final component = WasmComponent.decode(_resourceProgramBytes());
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final host = WASIPreview2ComponentHost();
    final binding = host.bindComponent(component);
    final handle = binding.program.invoke(0, <Object?>[i]);
    if (handle is! int) {
      throw StateError(
        'component versioned Preview2 resource.new returned non-handle',
      );
    }
    final representation = binding.program.invoke(1, <Object?>[handle]);
    if (representation is! int) {
      throw StateError(
        'component versioned Preview2 resource.rep returned non-int',
      );
    }
    checksum += representation;
    binding.program.invoke(2, <Object?>[handle]);
    if (host.componentHost.table.activeCount != 0) {
      throw StateError(
        'component versioned Preview2 table leaked ${host.componentHost.table.activeCount} resources',
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

_Metric _benchmarkComponentVersionedPreview3StreamBinding(int iterations) {
  final component = WasmComponent.decode(_streamProgramBytes());
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final host = WASIPreview3ComponentHost();
    final binding = host.bindComponent(component);
    final packed = binding.program.invoke(0, const <Object?>[]);
    if (packed is! int) {
      throw StateError(
        'component versioned Preview3 stream.new returned non-i64',
      );
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
    if (host.componentHost.table.activeCount != 0) {
      throw StateError(
        'component versioned Preview3 stream table leaked ${host.componentHost.table.activeCount} resources',
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

_Metric _benchmarkComponentAdapterDirectInvoke(int iterations) {
  final component = WasmComponent.decode(_primitiveAdapterProgramBytes());
  final plans = componentCanonicalAdapterPlans(component);
  final host = const WASIComponentCanonicalAdapterHost();
  final lift = host.bindLiftCoreFunction(plans[0], (_) => 41);
  final lower = host.bindLowerComponentFunction(plans[1], (_) => 42);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    checksum += lift.invoke(const <Object?>[]) as int;
    checksum += lower.invoke(const <Object?>[]) as int;
  }
  watch.stop();

  return _Metric(
    operations: iterations * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentAdapterProgramInvoke(int iterations) {
  final component = WasmComponent.decode(_primitiveAdapterProgramBytes());
  final plans = componentCanonicalAdapterPlans(component);
  final host = const WASIComponentCanonicalAdapterHost();
  final program = host.bindAdapterPlans(
    plans,
    coreFunctions: {0: (_) => 41},
    componentFunctions: {0: (_) => 42},
  );
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    checksum += program.invoke(0, const <Object?>[]) as int;
    checksum += program.invoke(1, const <Object?>[]) as int;
  }
  watch.stop();

  return _Metric(
    operations: iterations * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentVersionedAdapterProgramInvoke(int iterations) {
  final component = WasmComponent.decode(_primitiveAdapterProgramBytes());
  final preview2Program = WASIPreview2ComponentHost().bindAdapters(
    component,
    coreFunctions: {0: (_) => 51},
    componentFunctions: {0: (_) => 52},
  );
  final preview3Program = WASIPreview3ComponentHost().bindAdapters(
    component,
    coreFunctions: {0: (_) => 61},
    componentFunctions: {0: (_) => 62},
  );
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    checksum += preview2Program.invokeFlat(0, const <Object?>[]).single as int;
    checksum += preview2Program.invokeFlat(1, const <Object?>[]).single as int;
    checksum += preview3Program.invokeFlat(0, const <Object?>[]).single as int;
    checksum += preview3Program.invokeFlat(1, const <Object?>[]).single as int;
  }
  watch.stop();

  return _Metric(
    operations: iterations * 4,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentWitAdapterProgramInvoke(int iterations) {
  const source = '''
package acme:bench@0.2.0;

interface adder {
  add: func(left: u32, right: u32) -> u32;
}

interface sink {
  write: func(message: string);
}

world command {
  import adder;
  export sink;
}
''';
  final document = WASIComponentWitDocument.parse(source);
  final program = WASIPreview2ComponentHost()
      .prepareWitWorld(document, worldName: 'command')
      .bindAdapters(
        imports: {'adder.add': (args) => (args[0] as int) + (args[1] as int)},
        exports: {'sink.write': (_) => null},
      );
  var checksum = 0;
  final addArgs = <Object?>[0, 7];

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    addArgs[0] = i & 0xffff;
    checksum += program.invokeImport('adder.add', addArgs) as int;
    program.invokeExport('sink.write', const <Object?>['ok']);
  }
  watch.stop();

  return _Metric(
    operations: iterations * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentWitCompositeAdapterProgramInvoke(int iterations) {
  const source = '''
package acme:bench@0.2.0;

interface lookup {
  get: func(key: option<u32>) -> result<u32, u32>;
}

world command {
  import lookup;
}
''';
  final document = WASIComponentWitDocument.parse(source);
  final program = WASIPreview2ComponentHost()
      .prepareWitWorld(document, worldName: 'command')
      .bindAdapters(
        imports: {
          'lookup.get': (args) {
            final key = args.single as WasmComponentValueData;
            if (key.isSome ?? false) {
              final value = key.associatedValue!.integer as int;
              return _u32OkValue(value + 7);
            }
            return _u32ErrorValue(3);
          },
        },
      );
  var checksum = 0;
  final some = _u32SomeValue(11);
  final none = _u32NoneValue();
  final someArgs = <Object?>[some];
  final noneArgs = <Object?>[none];

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final ok =
        program.invokeImport('lookup.get', someArgs) as WasmComponentValueData;
    checksum += ok.associatedValue!.integer as int;
    final error =
        program.invokeImport('lookup.get', noneArgs) as WasmComponentValueData;
    checksum += error.associatedValue!.integer as int;
  }
  watch.stop();

  return _Metric(
    operations: iterations * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentWitListTupleAdapterProgramInvoke(int iterations) {
  const source = '''
package acme:bench@0.2.0;

interface expand {
  grow: func(seed: tuple<u32, u32>) -> list<tuple<u32, u32>>;
}

world command {
  import expand;
}
''';
  final document = WASIComponentWitDocument.parse(source);
  final program = WASIPreview2ComponentHost()
      .prepareWitWorld(document, worldName: 'command')
      .bindAdapters(
        imports: {
          'expand.grow': (args) {
            final seed = args.single as WasmComponentValueData;
            final left = seed.items[0].integer as int;
            final right = seed.items[1].integer as int;
            return _u32TupleListValue([
              (left + 1, right + 1),
              (left + 2, right + 2),
            ]);
          },
        },
      );
  var checksum = 0;
  final seed = _u32CompositeValue(WasmComponentValueDataKind.tuple, const [
    11,
    13,
  ]);
  final seedArgs = <Object?>[seed];

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final list =
        program.invokeImport('expand.grow', seedArgs) as WasmComponentValueData;
    for (final tuple in list.items) {
      checksum += tuple.items[0].integer as int;
      checksum += tuple.items[1].integer as int;
    }
  }
  watch.stop();

  return _Metric(
    operations: iterations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentWitRecordAdapterProgramInvoke(int iterations) {
  const source = '''
package acme:bench@0.2.0;

interface records {
  record pair {
    left: u32,
    right: u32,
  }

  swap: func(pair: pair) -> pair;
}

world command {
  import records;
}
''';
  final document = WASIComponentWitDocument.parse(source);
  final program = WASIPreview2ComponentHost()
      .prepareWitWorld(document, worldName: 'command')
      .bindAdapters(
        imports: {
          'records.swap': (args) {
            final pair = args.single as WasmComponentValueData;
            final left = pair.items[0].integer as int;
            final right = pair.items[1].integer as int;
            return _recordValue(right, left);
          },
        },
      );
  var checksum = 0;
  final pair = _recordValue(11, 13);
  final pairArgs = <Object?>[pair];

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final swapped =
        program.invokeImport('records.swap', pairArgs)
            as WasmComponentValueData;
    checksum += swapped.items[0].integer as int;
    checksum += swapped.items[1].integer as int;
  }
  watch.stop();

  return _Metric(
    operations: iterations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentAdapterStringProgramInvoke(int iterations) {
  final component = WasmComponent.decode(
    component_fixtures.canonicalStringLiftLowerComponentBytes(),
  );
  final plans = componentCanonicalAdapterPlans(component);
  final host = const WASIComponentCanonicalAdapterHost();
  final program = host.bindAdapterPlans(
    plans,
    coreFunctions: {
      0: (args) {
        if (args.single != 'core') {
          throw StateError('unexpected lift adapter argument: ${args.single}');
        }
        return 'lifted';
      },
    },
    componentFunctions: {
      0: (args) {
        if (args.single != 'component') {
          throw StateError('unexpected lower adapter argument: ${args.single}');
        }
        return 'lowered';
      },
    },
  );
  const coreArgs = <Object?>['core'];
  const componentArgs = <Object?>['component'];
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    checksum += (program.invoke(0, coreArgs) as String).length;
    checksum += (program.invoke(1, componentArgs) as String).length;
  }
  watch.stop();

  return _Metric(
    operations: iterations * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentAdapterStringFlatInvoke(int iterations) {
  final component = WasmComponent.decode(
    component_fixtures.canonicalStringLiftLowerComponentBytes(),
  );
  final plans = componentCanonicalAdapterPlans(component);
  final host = const WASIComponentCanonicalAdapterHost();
  final program = host.bindAdapterPlans(
    plans,
    coreFunctions: {0: (_) => 'lifted'},
    componentFunctions: {0: (_) => 'lowered'},
  );
  final memory = Memory(const MemoryDescriptor(initial: 1));
  final input = writeWASIComponentCanonicalString(
    memory,
    (_, _, _, _) => 256,
    'guest',
    WASIComponentCanonicalStringEncoding.utf8,
  );
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final lifted = program.invokeFlat(
      0,
      <Object?>[input.pointer, input.canonicalLength],
      memory: memory,
      realloc: (_, _, _, _) => 512,
    );
    checksum += readWASIComponentCanonicalString(
      memory,
      lifted[0]! as int,
      lifted[1]! as int,
      WASIComponentCanonicalStringEncoding.utf8,
    ).length;
    final lowered = program.invokeFlat(
      1,
      <Object?>[input.pointer, input.canonicalLength],
      memory: memory,
      realloc: (_, _, _, _) => 512,
    );
    checksum += readWASIComponentCanonicalString(
      memory,
      lowered[0]! as int,
      lowered[1]! as int,
      WASIComponentCanonicalStringEncoding.utf8,
    ).length;
  }
  watch.stop();

  return _Metric(
    operations: iterations * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentAdapterRecordFlatInvoke(int iterations) {
  final component = WasmComponent.decode(
    component_fixtures.canonicalRecordLiftLowerComponentBytes(),
  );
  final plans = componentCanonicalAdapterPlans(component);
  final host = const WASIComponentCanonicalAdapterHost();
  final program = host.bindAdapterPlans(
    plans,
    coreFunctions: {0: (_) => _recordValue(21, 22)},
    componentFunctions: {0: (_) => _recordValue(41, 42)},
  );
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final lifted = program.invokeFlat(0, const <Object?>[11, 12]);
    checksum += lifted[0]! as int;
    checksum += lifted[1]! as int;
    final lowered = program.invokeFlat(1, const <Object?>[31, 32]);
    checksum += lowered[0]! as int;
    checksum += lowered[1]! as int;
  }
  watch.stop();

  return _Metric(
    operations: iterations * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentAdapterTupleFlatInvoke(int iterations) {
  final component = WasmComponent.decode(
    component_fixtures.canonicalTupleLiftLowerComponentBytes(),
  );
  final plans = componentCanonicalAdapterPlans(component);
  final host = const WASIComponentCanonicalAdapterHost();
  final program = host.bindAdapterPlans(
    plans,
    coreFunctions: {
      0: (_) =>
          _u32CompositeValue(WasmComponentValueDataKind.tuple, const [21, 22]),
    },
    componentFunctions: {
      0: (_) =>
          _u32CompositeValue(WasmComponentValueDataKind.tuple, const [41, 42]),
    },
  );
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final lifted = program.invokeFlat(0, const <Object?>[11, 12]);
    checksum += lifted[0]! as int;
    checksum += lifted[1]! as int;
    final lowered = program.invokeFlat(1, const <Object?>[31, 32]);
    checksum += lowered[0]! as int;
    checksum += lowered[1]! as int;
  }
  watch.stop();

  return _Metric(
    operations: iterations * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentAdapterFixedListFlatInvoke(int iterations) {
  final component = WasmComponent.decode(
    component_fixtures.canonicalFixedListLiftLowerComponentBytes(),
  );
  final plans = componentCanonicalAdapterPlans(component);
  final host = const WASIComponentCanonicalAdapterHost();
  final program = host.bindAdapterPlans(
    plans,
    coreFunctions: {
      0: (_) => _u32CompositeValue(WasmComponentValueDataKind.fixedList, const [
        4,
        5,
        6,
      ]),
    },
    componentFunctions: {
      0: (_) => _u32CompositeValue(WasmComponentValueDataKind.fixedList, const [
        10,
        11,
        12,
      ]),
    },
  );
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final lifted = program.invokeFlat(0, const <Object?>[1, 2, 3]);
    checksum += lifted[0]! as int;
    checksum += lifted[1]! as int;
    checksum += lifted[2]! as int;
    final lowered = program.invokeFlat(1, const <Object?>[7, 8, 9]);
    checksum += lowered[0]! as int;
    checksum += lowered[1]! as int;
    checksum += lowered[2]! as int;
  }
  watch.stop();

  return _Metric(
    operations: iterations * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentAdapterFlagsEnumFlatInvoke(int iterations) {
  final component = WasmComponent.decode(
    component_fixtures.canonicalFlagsEnumLiftLowerComponentBytes(),
  );
  final plans = componentCanonicalAdapterPlans(component);
  final host = const WASIComponentCanonicalAdapterHost();
  final program = host.bindAdapterPlans(
    plans,
    coreFunctions: {
      0: (_) => _flagsValue(const ['read', 'write']),
      1: (_) => _enumValue(label: 'blue'),
    },
    componentFunctions: {
      0: (_) => _flagsValue(const ['exec']),
      1: (_) => _enumValue(index: 1),
    },
  );
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    checksum += program.invokeFlat(0, const <Object?>[0x5]).single! as int;
    checksum += program.invokeFlat(1, const <Object?>[0x2]).single! as int;
    checksum += program.invokeFlat(2, const <Object?>[1]).single! as int;
    checksum += program.invokeFlat(3, const <Object?>[0]).single! as int;
  }
  watch.stop();

  return _Metric(
    operations: iterations * 4,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentAdapterListFlatInvoke(int iterations) {
  final component = WasmComponent.decode(
    component_fixtures.canonicalU32ListLiftLowerComponentBytes(),
  );
  final plans = componentCanonicalAdapterPlans(component);
  final host = const WASIComponentCanonicalAdapterHost();
  final memory = Memory(const MemoryDescriptor(initial: 1));
  final realloc = (_, _, _, _) => 512;
  _writeU32List(memory, 64, const [3, 5]);
  _writeU32List(memory, 96, const [11]);
  final program = host.bindAdapterPlans(
    plans,
    coreFunctions: {
      1: (_) => _u32ListValue(const [7, 13, 17]),
    },
    componentFunctions: {
      0: (_) => _u32ListValue(const [19, 23]),
    },
  );
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final lifted = program.invokeFlat(
      0,
      const <Object?>[64, 2],
      memory: memory,
      realloc: realloc,
    );
    checksum += lifted[1]! as int;
    final lowered = program.invokeFlat(
      1,
      const <Object?>[96, 1],
      memory: memory,
      realloc: realloc,
    );
    checksum += lowered[1]! as int;
  }
  watch.stop();

  return _Metric(
    operations: iterations * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentAdapterOptionFlatInvoke(int iterations) {
  final component = WasmComponent.decode(
    component_fixtures.canonicalU32OptionLiftLowerComponentBytes(),
  );
  final plans = componentCanonicalAdapterPlans(component);
  final host = const WASIComponentCanonicalAdapterHost();
  final program = host.bindAdapterPlans(
    plans,
    coreFunctions: {1: (_) => _u32SomeValue(41)},
    componentFunctions: {0: (_) => _u32NoneValue()},
  );
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final lifted = program.invokeFlat(0, const <Object?>[1, 31]);
    checksum += lifted[0]! as int;
    checksum += lifted[1]! as int;
    final lowered = program.invokeFlat(1, const <Object?>[0, 999]);
    checksum += lowered[0]! as int;
    checksum += lowered[1]! as int;
  }
  watch.stop();

  return _Metric(
    operations: iterations * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentAdapterVariantFlatInvoke(int iterations) {
  final component = WasmComponent.decode(
    component_fixtures.canonicalU32VariantLiftLowerComponentBytes(),
  );
  final plans = componentCanonicalAdapterPlans(component);
  final host = const WASIComponentCanonicalAdapterHost();
  final program = host.bindAdapterPlans(
    plans,
    coreFunctions: {1: (_) => _u32VariantValue(label: 'right', value: 41)},
    componentFunctions: {0: (_) => _u32VariantValue(index: 0)},
  );
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final lifted = program.invokeFlat(0, const <Object?>[1, 31]);
    checksum += lifted[0]! as int;
    checksum += lifted[1]! as int;
    final lowered = program.invokeFlat(1, const <Object?>[0, 999]);
    checksum += lowered[0]! as int;
    checksum += lowered[1]! as int;
  }
  watch.stop();

  return _Metric(
    operations: iterations * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentAdapterResultFlatInvoke(int iterations) {
  final component = WasmComponent.decode(
    component_fixtures.canonicalU32ResultLiftLowerComponentBytes(),
  );
  final plans = componentCanonicalAdapterPlans(component);
  final host = const WASIComponentCanonicalAdapterHost();
  final program = host.bindAdapterPlans(
    plans,
    coreFunctions: {1: (_) => _u32OkValue(41)},
    componentFunctions: {0: (_) => _u32ErrorValue(11)},
  );
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final lifted = program.invokeFlat(0, const <Object?>[0, 31]);
    checksum += lifted[0]! as int;
    checksum += lifted[1]! as int;
    final lowered = program.invokeFlat(1, const <Object?>[1, 7]);
    checksum += lowered[0]! as int;
    checksum += lowered[1]! as int;
  }
  watch.stop();

  return _Metric(
    operations: iterations * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentAdapterResourceDirectInvoke(int iterations) {
  final component = WasmComponent.decode(
    component_fixtures.canonicalResourceLiftComponentBytes(),
  );
  final plans = componentCanonicalAdapterPlans(component);
  final plan = plans.single;
  final host = const WASIComponentCanonicalAdapterHost();
  final program = host.bindAdapterPlans(
    plans,
    coreFunctions: {plan.definition.coreFunctionIndex!: (_) => 51},
  );
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    checksum += program.invoke(0, const <Object?>[31, 41])! as int;
  }
  watch.stop();

  return _Metric(
    operations: iterations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentAdapterResourceFlatInvoke(int iterations) {
  final component = WasmComponent.decode(
    component_fixtures.canonicalResourceLiftComponentBytes(),
  );
  final plans = componentCanonicalAdapterPlans(component);
  final plan = plans.single;
  final host = const WASIComponentCanonicalAdapterHost();
  final program = host.bindAdapterPlans(
    plans,
    coreFunctions: {plan.definition.coreFunctionIndex!: (_) => 51},
  );
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final lifted = program.invokeFlat(0, const <Object?>[31, 41]);
    checksum += lifted.single! as int;
  }
  watch.stop();

  return _Metric(
    operations: iterations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentAdapterResourceMemoryInvoke(int iterations) {
  final component = WasmComponent.decode(
    component_fixtures.canonicalResourceLiftComponentBytes(),
  );
  final plans = componentCanonicalAdapterPlans(component);
  final plan = plans.single;
  final host = const WASIComponentCanonicalAdapterHost();
  final program = host.bindAdapterPlans(
    plans,
    coreFunctions: {plan.definition.coreFunctionIndex!: (_) => 51},
  );
  final memory = Memory(const MemoryDescriptor(initial: 1));
  final data = ByteData.view(memory.buffer);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    data.setUint32(32, 31, Endian.little);
    data.setUint32(36, 41, Endian.little);
    checksum +=
        program.invokeWithMemory(0, memory, const <int>[
              32,
              36,
            ], resultPointer: 40)!
            as int;
    checksum += data.getUint32(40, Endian.little);
  }
  watch.stop();

  return _Metric(
    operations: iterations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentAdapterResourceRecordMemoryInvoke(int iterations) {
  final plan = _resourceRecordAdapterPlan();
  final program = const WASIComponentCanonicalAdapterHost().bindAdapterPlans(
    [plan],
    coreFunctions: {
      0: (_) => _u32CompositeValue(WasmComponentValueDataKind.record, const [
        303,
        404,
        9,
      ]),
    },
  );
  final memory = Memory(const MemoryDescriptor(initial: 1));
  final data = ByteData.view(memory.buffer);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    data.setUint32(32, 101, Endian.little);
    data.setUint32(36, 202, Endian.little);
    data.setUint16(40, 7, Endian.little);
    final result =
        program.invokeWithMemory(0, memory, const <int>[32], resultPointer: 64)!
            as WasmComponentValueData;
    checksum += result.items[0].integer! as int;
    checksum += data.getUint32(64, Endian.little);
    checksum += data.getUint32(68, Endian.little);
    checksum += data.getUint16(72, Endian.little);
  }
  watch.stop();

  return _Metric(
    operations: iterations,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

WASIComponentCanonicalAdapterPlan _resourceRecordAdapterPlan() {
  final memoryCodec =
      WASIComponentCanonicalValueMemoryCodec.fromAdapterValueType(
        component_fixtures.canonicalResourceRecordValueType,
        component_fixtures.canonicalResourceRecordDefinitions,
      )!;
  final resourceUses = <WASIComponentResourceUse>[
    const WASIComponentResourceUse(
      canonicalIndex: 0,
      canonicalKind: WasmComponentCanonicalKind.lift,
      path: 'canonical[0].param[0].input.owned',
      handleKind: WASIComponentResourceHandleKind.own,
      resourceTypeIndex: 0,
      binding: null,
    ),
    const WASIComponentResourceUse(
      canonicalIndex: 0,
      canonicalKind: WasmComponentCanonicalKind.lift,
      path: 'canonical[0].param[0].input.borrowed',
      handleKind: WASIComponentResourceHandleKind.borrow,
      resourceTypeIndex: 0,
      binding: null,
    ),
    const WASIComponentResourceUse(
      canonicalIndex: 0,
      canonicalKind: WasmComponentCanonicalKind.lift,
      path: 'canonical[0].result.owned',
      handleKind: WASIComponentResourceHandleKind.own,
      resourceTypeIndex: 0,
      binding: null,
    ),
    const WASIComponentResourceUse(
      canonicalIndex: 0,
      canonicalKind: WasmComponentCanonicalKind.lift,
      path: 'canonical[0].result.borrowed',
      handleKind: WASIComponentResourceHandleKind.borrow,
      resourceTypeIndex: 0,
      binding: null,
    ),
  ];
  return WASIComponentCanonicalAdapterPlan(
    canonicalIndex: 0,
    definition: const WasmComponentCanonicalDefinition(
      kind: WasmComponentCanonicalKind.lift,
      coreFunctionIndex: 0,
    ),
    functionType: const WasmComponentFunctionType(
      params: [
        WasmComponentLabeledValueType(
          label: 'input',
          type: component_fixtures.canonicalResourceRecordValueType,
        ),
      ],
      result: component_fixtures.canonicalResourceRecordValueType,
    ),
    params: [
      WASIComponentCanonicalAdapterValuePlan(
        path: 'canonical[0].param[0].input',
        label: 'input',
        type: component_fixtures.canonicalResourceRecordValueType,
        memoryCodec: memoryCodec,
        flatLayout: null,
        resourceUses: resourceUses
            .where((use) => use.path.startsWith('canonical[0].param[0].input.'))
            .toList(growable: false),
      ),
    ],
    result: WASIComponentCanonicalAdapterValuePlan(
      path: 'canonical[0].result',
      label: null,
      type: component_fixtures.canonicalResourceRecordValueType,
      memoryCodec: memoryCodec,
      flatLayout: null,
      resourceUses: resourceUses
          .where((use) => use.path.startsWith('canonical[0].result.'))
          .toList(growable: false),
    ),
    resourceUses: resourceUses,
    stringEncoding: WASIComponentCanonicalStringEncoding.utf8,
    memoryIndex: 0,
    reallocIndex: null,
    postReturnIndex: null,
    callbackIndex: null,
    isAsync: false,
  );
}

_Metric _benchmarkComponentAdapterErrorContextDirectInvoke(int iterations) {
  final component = WasmComponent.decode(
    component_fixtures.canonicalErrorContextLiftLowerComponentBytes(),
  );
  final plans = componentCanonicalAdapterPlans(component);
  final host = const WASIComponentCanonicalAdapterHost();
  final program = host.bindAdapterPlans(
    plans,
    coreFunctions: {1: (_) => 19},
    componentFunctions: {0: (_) => 29},
  );
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    checksum += program.invoke(0, const <Object?>[17])! as int;
    checksum += program.invoke(1, const <Object?>[23])! as int;
  }
  watch.stop();

  return _Metric(
    operations: iterations * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentAdapterErrorContextFlatInvoke(int iterations) {
  final component = WasmComponent.decode(
    component_fixtures.canonicalErrorContextLiftLowerComponentBytes(),
  );
  final plans = componentCanonicalAdapterPlans(component);
  final host = const WASIComponentCanonicalAdapterHost();
  final program = host.bindAdapterPlans(
    plans,
    coreFunctions: {1: (_) => 19},
    componentFunctions: {0: (_) => 29},
  );
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final lifted = program.invokeFlat(0, const <Object?>[17]);
    checksum += lifted.single! as int;
    final lowered = program.invokeFlat(1, const <Object?>[23]);
    checksum += lowered.single! as int;
  }
  watch.stop();

  return _Metric(
    operations: iterations * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentAdapterErrorContextMemoryInvoke(int iterations) {
  final component = WasmComponent.decode(
    component_fixtures.canonicalErrorContextLiftLowerComponentBytes(),
  );
  final plans = componentCanonicalAdapterPlans(component);
  final host = const WASIComponentCanonicalAdapterHost();
  final program = host.bindAdapterPlans(
    plans,
    coreFunctions: {1: (_) => 19},
    componentFunctions: {0: (_) => 29},
  );
  final memory = Memory(const MemoryDescriptor(initial: 1));
  final data = ByteData.view(memory.buffer);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    data.setUint32(32, 17, Endian.little);
    checksum +=
        program.invokeWithMemory(0, memory, const <int>[32], resultPointer: 36)!
            as int;
    checksum += data.getUint32(36, Endian.little);
    data.setUint32(40, 23, Endian.little);
    checksum +=
        program.invokeWithMemory(1, memory, const <int>[40], resultPointer: 44)!
            as int;
    checksum += data.getUint32(44, Endian.little);
  }
  watch.stop();

  return _Metric(
    operations: iterations * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

WasmComponentValueData _recordValue(int left, int right) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.record,
    rawBytes: Uint8List(0),
    items: [
      WasmComponentValueData(
        kind: WasmComponentValueDataKind.integer,
        rawBytes: Uint8List(0),
        integer: left,
      ),
      WasmComponentValueData(
        kind: WasmComponentValueDataKind.integer,
        rawBytes: Uint8List(0),
        integer: right,
      ),
    ],
  );
}

WasmComponentValueData _u32CompositeValue(
  WasmComponentValueDataKind kind,
  List<int> values,
) {
  return WasmComponentValueData(
    kind: kind,
    rawBytes: Uint8List(0),
    items: [
      for (final value in values)
        WasmComponentValueData(
          kind: WasmComponentValueDataKind.integer,
          rawBytes: Uint8List(0),
          integer: value,
        ),
    ],
  );
}

WasmComponentValueData _u32ListValue(List<int> values) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    items: [
      for (final value in values)
        WasmComponentValueData(
          kind: WasmComponentValueDataKind.integer,
          rawBytes: Uint8List(0),
          integer: value,
        ),
    ],
  );
}

WasmComponentValueData _u32TupleListValue(List<(int, int)> rows) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    items: [
      for (final row in rows)
        _u32CompositeValue(WasmComponentValueDataKind.tuple, [row.$1, row.$2]),
    ],
  );
}

void _writeU32List(Memory memory, int pointer, List<int> values) {
  final data = ByteData.view(memory.buffer);
  for (var i = 0; i < values.length; i++) {
    data.setUint32(pointer + i * 4, values[i], Endian.little);
  }
}

WasmComponentValueData _u32SomeValue(int value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    isSome: true,
    associatedValue: WasmComponentValueData(
      kind: WasmComponentValueDataKind.integer,
      rawBytes: Uint8List(0),
      integer: value,
    ),
  );
}

WasmComponentValueData _u32NoneValue() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    isSome: false,
  );
}

WasmComponentValueData _u32VariantValue({
  int? index,
  String? label,
  int? value,
}) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.variant,
    rawBytes: Uint8List(0),
    index: index,
    label: label,
    associatedValue: value == null
        ? null
        : WasmComponentValueData(
            kind: WasmComponentValueDataKind.integer,
            rawBytes: Uint8List(0),
            integer: value,
          ),
  );
}

WasmComponentValueData _u32OkValue(int value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    isOk: true,
    associatedValue: WasmComponentValueData(
      kind: WasmComponentValueDataKind.integer,
      rawBytes: Uint8List(0),
      integer: value,
    ),
  );
}

WasmComponentValueData _u32ErrorValue(int value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    isOk: false,
    associatedValue: WasmComponentValueData(
      kind: WasmComponentValueDataKind.integer,
      rawBytes: Uint8List(0),
      integer: value,
    ),
  );
}

WasmComponentValueData _flagsValue(List<String> labels) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.flags,
    rawBytes: Uint8List(0),
    labels: List<String>.unmodifiable(labels),
  );
}

WasmComponentValueData _enumValue({int? index, String? label}) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.enumeration,
    rawBytes: Uint8List(0),
    index: index,
    label: label,
  );
}

_Metric _benchmarkComponentAdapterStringMemoryInvoke(int iterations) {
  final component = WasmComponent.decode(
    component_fixtures.canonicalStringLiftLowerComponentBytes(),
  );
  final plans = componentCanonicalAdapterPlans(component);
  final host = const WASIComponentCanonicalAdapterHost();
  final program = host.bindAdapterPlans(
    plans,
    coreFunctions: {0: (_) => 'lifted'},
    componentFunctions: {0: (_) => 'lowered'},
  );
  final memory = Memory(const MemoryDescriptor(initial: 1));
  final input = writeWASIComponentCanonicalString(
    memory,
    (_, _, _, _) => 256,
    'guest',
    WASIComponentCanonicalStringEncoding.utf8,
  );
  writeWASIComponentMemoryStringRecord(memory, 32, input);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    checksum +=
        (program.invokeWithMemory(
                  0,
                  memory,
                  const <int>[32],
                  resultPointer: 64,
                  realloc: (_, _, _, _) => 512,
                )
                as String)
            .length;
    checksum += readWASIComponentCanonicalStringRecord(
      memory,
      64,
      WASIComponentCanonicalStringEncoding.utf8,
    ).length;
    checksum +=
        (program.invokeWithMemory(
                  1,
                  memory,
                  const <int>[32],
                  resultPointer: 96,
                  realloc: (_, _, _, _) => 512,
                )
                as String)
            .length;
    checksum += readWASIComponentCanonicalStringRecord(
      memory,
      96,
      WASIComponentCanonicalStringEncoding.utf8,
    ).length;
  }
  watch.stop();

  return _Metric(
    operations: iterations * 2,
    totalMicros: watch.elapsedMicroseconds,
    checksum: checksum,
  );
}

_Metric _benchmarkComponentHostStreamMemoryBinding(int iterations) {
  final component = WasmComponent.decode(
    component_fixtures.canonicalU32StreamMemoryComponentBytes(),
  );
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

_Metric _benchmarkComponentHostOwnedResourceStreamMemoryBinding(
  int iterations,
) {
  final component = WasmComponent.decode(
    component_fixtures.ownedResourceAsyncMemoryProgramFromU32(
      component_fixtures.canonicalU32StreamMemoryComponentBytes(),
      isStream: true,
    ),
  );
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
      throw StateError(
        'component host owned-resource stream.new returned non-i64',
      );
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
        'component host owned-resource stream memory table leaked ${host.table.activeCount} resources',
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

_Metric _benchmarkComponentHostRecordStreamMemoryBinding(int iterations) {
  final component = WasmComponent.decode(_recordStreamMemoryProgramBytes());
  final memory = Memory(const MemoryDescriptor(initial: 1));
  final data = ByteData.view(memory.buffer);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    data.setUint32(32, i & 0xffffffff, Endian.little);
    data.setUint16(36, (i + 1) & 0xffff, Endian.little);
    data.setUint32(40, (i + 2) & 0xffffffff, Endian.little);
    data.setUint16(44, (i + 3) & 0xffff, Endian.little);
    final host = WASIComponentHost();
    final binding = host.bindComponent(component);
    final packed = binding.program.invoke(0, const <Object?>[]);
    if (packed is! int) {
      throw StateError('component host record stream.new returned non-i64');
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
    checksum += data.getUint16(100, Endian.little);
    checksum += data.getUint32(104, Endian.little);
    checksum += data.getUint16(108, Endian.little);
    binding.program.invoke(3, <Object?>[handles.readable]);
    binding.program.invoke(4, <Object?>[handles.writable]);
    if (host.table.activeCount != 0) {
      throw StateError(
        'component host record stream memory table leaked ${host.table.activeCount} resources',
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

_Metric _benchmarkComponentHostListStreamMemoryBinding(int iterations) {
  final component = WasmComponent.decode(_listStreamMemoryProgramBytes());
  final memory = Memory(const MemoryDescriptor(initial: 1));
  final data = ByteData.view(memory.buffer);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    data.setUint32(32, 256, Endian.little);
    data.setUint32(36, 2, Endian.little);
    data.setUint32(256, i & 0xffffffff, Endian.little);
    data.setUint32(260, (i + 1) & 0xffffffff, Endian.little);
    final host = WASIComponentHost();
    final binding = host.bindComponent(component);
    final handles = host.canonicalHost.asyncHost
        .bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.streamNew,
            typeIndex: 1,
          ),
        )
        .streamNewHandles();
    checksum +=
        binding.program.invokeWithMemory(1, memory, <Object?>[
              handles.writable,
              32,
              1,
            ])
            as int;
    checksum +=
        binding.program.invokeWithMemory(0, memory, <Object?>[
              handles.readable,
              96,
              1,
            ], realloc: (oldPointer, oldSize, alignment, newSize) => 512)
            as int;
    checksum += data.getUint32(96, Endian.little);
    checksum += data.getUint32(100, Endian.little);
    checksum += data.getUint32(512, Endian.little);
    checksum += data.getUint32(516, Endian.little);
    host.canonicalHost.asyncHost
        .bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.streamDropReadable,
            typeIndex: 1,
          ),
        )
        .streamDropReadableHandle(handles.readable);
    host.canonicalHost.asyncHost
        .bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.streamDropWritable,
            typeIndex: 1,
          ),
        )
        .streamDropWritableHandle(handles.writable);
    if (host.table.activeCount != 0) {
      throw StateError(
        'component host list stream memory table leaked ${host.table.activeCount} resources',
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

_Metric _benchmarkComponentHostStringListStreamMemoryBinding(int iterations) {
  final component = WasmComponent.decode(_stringListStreamMemoryProgramBytes());
  final memory = Memory(const MemoryDescriptor(initial: 1));
  final bytes = Uint8List.view(memory.buffer);
  final data = ByteData.view(memory.buffer);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    _writeStringListInput(bytes, data, i);
    final host = WASIComponentHost();
    final binding = host.bindComponent(component);
    final handles = host.canonicalHost.asyncHost
        .bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.streamNew,
            typeIndex: 1,
          ),
        )
        .streamNewHandles();
    checksum +=
        binding.program.invokeWithMemory(1, memory, <Object?>[
              handles.writable,
              32,
              1,
            ])
            as int;
    var allocationIndex = 0;
    checksum +=
        binding.program.invokeWithMemory(
              0,
              memory,
              <Object?>[handles.readable, 96, 1],
              realloc: (oldPointer, oldSize, alignment, newSize) {
                final pointer = switch (allocationIndex++) {
                  0 => 512,
                  1 => 544,
                  2 => 560,
                  _ => throw StateError('unexpected string-list allocation'),
                };
                return pointer;
              },
            )
            as int;
    checksum += _checksumStringListOutput(bytes, data);
    host.canonicalHost.asyncHost
        .bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.streamDropReadable,
            typeIndex: 1,
          ),
        )
        .streamDropReadableHandle(handles.readable);
    host.canonicalHost.asyncHost
        .bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.streamDropWritable,
            typeIndex: 1,
          ),
        )
        .streamDropWritableHandle(handles.writable);
    if (host.table.activeCount != 0) {
      throw StateError(
        'component host string list stream memory table leaked ${host.table.activeCount} resources',
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

_Metric _benchmarkComponentHostListFutureMemoryBinding(int iterations) {
  final component = WasmComponent.decode(_listFutureMemoryProgramBytes());
  final memory = Memory(const MemoryDescriptor(initial: 1));
  final data = ByteData.view(memory.buffer);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    data.setUint32(32, 256, Endian.little);
    data.setUint32(36, 2, Endian.little);
    data.setUint32(256, i & 0xffffffff, Endian.little);
    data.setUint32(260, (i + 1) & 0xffffffff, Endian.little);
    final host = WASIComponentHost();
    final binding = host.bindComponent(component);
    final handles = host.canonicalHost.asyncHost
        .bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.futureNew,
            typeIndex: 1,
          ),
        )
        .futureNewHandles();
    checksum +=
        binding.program.invokeWithMemory(1, memory, <Object?>[
              handles.writable,
              32,
            ])
            as int;
    checksum +=
        binding.program.invokeWithMemory(0, memory, <Object?>[
              handles.readable,
              96,
            ], realloc: (oldPointer, oldSize, alignment, newSize) => 512)
            as int;
    checksum += data.getUint32(96, Endian.little);
    checksum += data.getUint32(100, Endian.little);
    checksum += data.getUint32(512, Endian.little);
    checksum += data.getUint32(516, Endian.little);
    host.canonicalHost.asyncHost
        .bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.futureDropReadable,
            typeIndex: 1,
          ),
        )
        .futureDropReadableHandle(handles.readable);
    host.canonicalHost.asyncHost
        .bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.futureDropWritable,
            typeIndex: 1,
          ),
        )
        .futureDropWritableHandle(handles.writable);
    if (host.table.activeCount != 0) {
      throw StateError(
        'component host list future memory table leaked ${host.table.activeCount} resources',
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

_Metric _benchmarkComponentHostStringListFutureMemoryBinding(int iterations) {
  final component = WasmComponent.decode(_stringListFutureMemoryProgramBytes());
  final memory = Memory(const MemoryDescriptor(initial: 1));
  final bytes = Uint8List.view(memory.buffer);
  final data = ByteData.view(memory.buffer);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    _writeStringListInput(bytes, data, i);
    final host = WASIComponentHost();
    final binding = host.bindComponent(component);
    final handles = host.canonicalHost.asyncHost
        .bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.futureNew,
            typeIndex: 1,
          ),
        )
        .futureNewHandles();
    checksum +=
        binding.program.invokeWithMemory(1, memory, <Object?>[
              handles.writable,
              32,
            ])
            as int;
    var allocationIndex = 0;
    checksum +=
        binding.program.invokeWithMemory(
              0,
              memory,
              <Object?>[handles.readable, 96],
              realloc: (oldPointer, oldSize, alignment, newSize) {
                final pointer = switch (allocationIndex++) {
                  0 => 512,
                  1 => 544,
                  2 => 560,
                  _ => throw StateError('unexpected string-list allocation'),
                };
                return pointer;
              },
            )
            as int;
    checksum += _checksumStringListOutput(bytes, data);
    host.canonicalHost.asyncHost
        .bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.futureDropReadable,
            typeIndex: 1,
          ),
        )
        .futureDropReadableHandle(handles.readable);
    host.canonicalHost.asyncHost
        .bindCanonicalDefinition(
          const WasmComponentCanonicalDefinition(
            kind: WasmComponentCanonicalKind.futureDropWritable,
            typeIndex: 1,
          ),
        )
        .futureDropWritableHandle(handles.writable);
    if (host.table.activeCount != 0) {
      throw StateError(
        'component host string list future memory table leaked ${host.table.activeCount} resources',
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

_Metric _benchmarkComponentHostFutureMemoryBinding(int iterations) {
  final component = WasmComponent.decode(
    component_fixtures.canonicalU32FutureMemoryComponentBytes(),
  );
  final memory = Memory(const MemoryDescriptor(initial: 1));
  final data = ByteData.view(memory.buffer);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    data.setUint32(32, i & 0xffffffff, Endian.little);
    final host = WASIComponentHost();
    final binding = host.bindComponent(component);
    final packed = binding.program.invoke(0, const <Object?>[]);
    if (packed is! int) {
      throw StateError('component host future.new returned non-i64');
    }
    final handles = WASIComponentAsyncEndpointHandles.unpack(packed);
    checksum +=
        binding.program.invokeWithMemory(2, memory, <Object?>[
              handles.writable,
              32,
            ])
            as int;
    checksum +=
        binding.program.invokeWithMemory(1, memory, <Object?>[
              handles.readable,
              96,
            ])
            as int;
    checksum += data.getUint32(96, Endian.little);
    binding.program.invoke(3, <Object?>[handles.readable]);
    binding.program.invoke(4, <Object?>[handles.writable]);
    if (host.table.activeCount != 0) {
      throw StateError(
        'component host future memory table leaked ${host.table.activeCount} resources',
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

_Metric _benchmarkComponentHostOwnedResourceFutureMemoryBinding(
  int iterations,
) {
  final component = WasmComponent.decode(
    component_fixtures.ownedResourceAsyncMemoryProgramFromU32(
      component_fixtures.canonicalU32FutureMemoryComponentBytes(),
      isStream: false,
    ),
  );
  final memory = Memory(const MemoryDescriptor(initial: 1));
  final data = ByteData.view(memory.buffer);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    data.setUint32(32, i & 0xffffffff, Endian.little);
    final host = WASIComponentHost();
    final binding = host.bindComponent(component);
    final packed = binding.program.invoke(0, const <Object?>[]);
    if (packed is! int) {
      throw StateError(
        'component host owned-resource future.new returned non-i64',
      );
    }
    final handles = WASIComponentAsyncEndpointHandles.unpack(packed);
    checksum +=
        binding.program.invokeWithMemory(2, memory, <Object?>[
              handles.writable,
              32,
            ])
            as int;
    checksum +=
        binding.program.invokeWithMemory(1, memory, <Object?>[
              handles.readable,
              96,
            ])
            as int;
    checksum += data.getUint32(96, Endian.little);
    binding.program.invoke(3, <Object?>[handles.readable]);
    binding.program.invoke(4, <Object?>[handles.writable]);
    if (host.table.activeCount != 0) {
      throw StateError(
        'component host owned-resource future memory table leaked ${host.table.activeCount} resources',
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

void _writeStringListInput(Uint8List bytes, ByteData data, int iteration) {
  final first = 0x61 + (iteration % 26);
  final second = 0x41 + (iteration % 26);
  bytes[256] = first;
  bytes[257] = 0x30;
  bytes[272] = second;
  bytes[273] = 0x31;
  data.setUint32(128, 256, Endian.little);
  data.setUint32(132, 2, Endian.little);
  data.setUint32(136, 272, Endian.little);
  data.setUint32(140, 2, Endian.little);
  data.setUint32(32, 128, Endian.little);
  data.setUint32(36, 2, Endian.little);
}

int _checksumStringListOutput(Uint8List bytes, ByteData data) {
  return data.getUint32(96, Endian.little) +
      data.getUint32(100, Endian.little) +
      data.getUint32(512, Endian.little) +
      data.getUint32(516, Endian.little) +
      data.getUint32(520, Endian.little) +
      data.getUint32(524, Endian.little) +
      bytes[544] +
      bytes[545] +
      bytes[560] +
      bytes[561];
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

_Metric _benchmarkCanonicalVariantStore(int iterations) {
  final codec = WASIComponentCanonicalValueMemoryCodec.fromValueType(
    const WasmComponentValueType.typeIndex(0),
    [
      const WasmComponentTypeDefinition(
        kind: WasmComponentTypeKind.definedValue,
        definedValue: WasmComponentDefinedValueType(
          kind: WasmComponentDefinedValueTypeKind.variant,
          cases: [
            WasmComponentVariantCase(label: 'empty'),
            WasmComponentVariantCase(
              label: 'number',
              type: WasmComponentValueType.primitive(
                WasmComponentPrimitiveValueType.u32,
              ),
            ),
          ],
        ),
      ),
    ],
  )!;
  final memory = Memory(const MemoryDescriptor(initial: 1));
  final data = ByteData.view(memory.buffer);
  final empty = _u32VariantValue(index: 0);
  final number = _u32VariantValue(label: 'number', value: 41);
  var checksum = 0;

  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    codec.store(memory, 32, empty);
    codec.store(memory, 40, number);
    checksum += data.getUint8(32);
    checksum += data.getUint8(40);
    checksum += data.getUint32(44, Endian.little);
  }
  watch.stop();

  return _Metric(
    operations: iterations * 2,
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
    'component_versioned_preview2_binding',
    'component_host_stream_binding',
    'component_versioned_preview3_stream_binding',
    'component_versioned_adapter_program_invoke',
    'component_host_stream_memory_binding',
    'component_host_owned_resource_stream_memory_binding',
    'component_host_record_stream_memory_binding',
    'component_host_list_stream_memory_binding',
    'component_host_string_list_stream_memory_binding',
    'component_host_list_future_memory_binding',
    'component_host_string_list_future_memory_binding',
    'component_host_future_memory_binding',
    'component_host_owned_resource_future_memory_binding',
    'canonical_host_program',
    'error_context_program',
    'error_context_memory',
    'canonical_variant_store',
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

Uint8List _recordStreamMemoryProgramBytes() => Uint8List.fromList(const <int>[
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
  0x0c,
  0x02,
  0x72,
  0x02,
  0x01,
  0x61,
  0x79,
  0x01,
  0x62,
  0x7b,
  0x66,
  0x01,
  0x00,
  0x08,
  0x03,
  0x01,
  0x0e,
  0x01,
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
  0x01,
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
  0x01,
  0x01,
  0x03,
  0x01,
  0x13,
  0x01,
  0x14,
  0x01,
]);

Uint8List _listStreamMemoryProgramBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x01,
  0x37,
  0x00,
  0x61,
  0x73,
  0x6d,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x09,
  0x01,
  0x60,
  0x04,
  0x7f,
  0x7f,
  0x7f,
  0x7f,
  0x01,
  0x7f,
  0x03,
  0x02,
  0x01,
  0x00,
  0x05,
  0x03,
  0x01,
  0x00,
  0x01,
  0x07,
  0x11,
  0x02,
  0x03,
  0x6d,
  0x65,
  0x6d,
  0x02,
  0x00,
  0x07,
  0x72,
  0x65,
  0x61,
  0x6c,
  0x6c,
  0x6f,
  0x63,
  0x00,
  0x00,
  0x0a,
  0x06,
  0x01,
  0x04,
  0x00,
  0x41,
  0x00,
  0x0b,
  0x02,
  0x04,
  0x01,
  0x00,
  0x00,
  0x00,
  0x06,
  0x15,
  0x02,
  0x00,
  0x02,
  0x01,
  0x00,
  0x03,
  0x6d,
  0x65,
  0x6d,
  0x00,
  0x00,
  0x01,
  0x00,
  0x07,
  0x72,
  0x65,
  0x61,
  0x6c,
  0x6c,
  0x6f,
  0x63,
  0x07,
  0x06,
  0x02,
  0x70,
  0x79,
  0x66,
  0x01,
  0x00,
  0x08,
  0x0d,
  0x02,
  0x0f,
  0x01,
  0x02,
  0x03,
  0x00,
  0x04,
  0x00,
  0x10,
  0x01,
  0x01,
  0x03,
  0x00,
]);

Uint8List _stringListStreamMemoryProgramBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x01,
      0x37,
      0x00,
      0x61,
      0x73,
      0x6d,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x09,
      0x01,
      0x60,
      0x04,
      0x7f,
      0x7f,
      0x7f,
      0x7f,
      0x01,
      0x7f,
      0x03,
      0x02,
      0x01,
      0x00,
      0x05,
      0x03,
      0x01,
      0x00,
      0x01,
      0x07,
      0x11,
      0x02,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x02,
      0x00,
      0x07,
      0x72,
      0x65,
      0x61,
      0x6c,
      0x6c,
      0x6f,
      0x63,
      0x00,
      0x00,
      0x0a,
      0x06,
      0x01,
      0x04,
      0x00,
      0x41,
      0x00,
      0x0b,
      0x02,
      0x04,
      0x01,
      0x00,
      0x00,
      0x00,
      0x06,
      0x15,
      0x02,
      0x00,
      0x02,
      0x01,
      0x00,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x00,
      0x00,
      0x01,
      0x00,
      0x07,
      0x72,
      0x65,
      0x61,
      0x6c,
      0x6c,
      0x6f,
      0x63,
      0x07,
      0x06,
      0x02,
      0x70,
      0x73,
      0x66,
      0x01,
      0x00,
      0x08,
      0x0d,
      0x02,
      0x0f,
      0x01,
      0x02,
      0x03,
      0x00,
      0x04,
      0x00,
      0x10,
      0x01,
      0x01,
      0x03,
      0x00,
    ]);

Uint8List _listFutureMemoryProgramBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x01,
  0x37,
  0x00,
  0x61,
  0x73,
  0x6d,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x09,
  0x01,
  0x60,
  0x04,
  0x7f,
  0x7f,
  0x7f,
  0x7f,
  0x01,
  0x7f,
  0x03,
  0x02,
  0x01,
  0x00,
  0x05,
  0x03,
  0x01,
  0x00,
  0x01,
  0x07,
  0x11,
  0x02,
  0x03,
  0x6d,
  0x65,
  0x6d,
  0x02,
  0x00,
  0x07,
  0x72,
  0x65,
  0x61,
  0x6c,
  0x6c,
  0x6f,
  0x63,
  0x00,
  0x00,
  0x0a,
  0x06,
  0x01,
  0x04,
  0x00,
  0x41,
  0x00,
  0x0b,
  0x02,
  0x04,
  0x01,
  0x00,
  0x00,
  0x00,
  0x06,
  0x15,
  0x02,
  0x00,
  0x02,
  0x01,
  0x00,
  0x03,
  0x6d,
  0x65,
  0x6d,
  0x00,
  0x00,
  0x01,
  0x00,
  0x07,
  0x72,
  0x65,
  0x61,
  0x6c,
  0x6c,
  0x6f,
  0x63,
  0x07,
  0x06,
  0x02,
  0x70,
  0x79,
  0x65,
  0x01,
  0x00,
  0x08,
  0x0d,
  0x02,
  0x16,
  0x01,
  0x02,
  0x03,
  0x00,
  0x04,
  0x00,
  0x17,
  0x01,
  0x01,
  0x03,
  0x00,
]);

Uint8List _stringListFutureMemoryProgramBytes() =>
    Uint8List.fromList(const <int>[
      0x00,
      0x61,
      0x73,
      0x6d,
      0x0d,
      0x00,
      0x01,
      0x00,
      0x01,
      0x37,
      0x00,
      0x61,
      0x73,
      0x6d,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x09,
      0x01,
      0x60,
      0x04,
      0x7f,
      0x7f,
      0x7f,
      0x7f,
      0x01,
      0x7f,
      0x03,
      0x02,
      0x01,
      0x00,
      0x05,
      0x03,
      0x01,
      0x00,
      0x01,
      0x07,
      0x11,
      0x02,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x02,
      0x00,
      0x07,
      0x72,
      0x65,
      0x61,
      0x6c,
      0x6c,
      0x6f,
      0x63,
      0x00,
      0x00,
      0x0a,
      0x06,
      0x01,
      0x04,
      0x00,
      0x41,
      0x00,
      0x0b,
      0x02,
      0x04,
      0x01,
      0x00,
      0x00,
      0x00,
      0x06,
      0x15,
      0x02,
      0x00,
      0x02,
      0x01,
      0x00,
      0x03,
      0x6d,
      0x65,
      0x6d,
      0x00,
      0x00,
      0x01,
      0x00,
      0x07,
      0x72,
      0x65,
      0x61,
      0x6c,
      0x6c,
      0x6f,
      0x63,
      0x07,
      0x06,
      0x02,
      0x70,
      0x73,
      0x65,
      0x01,
      0x00,
      0x08,
      0x0d,
      0x02,
      0x16,
      0x01,
      0x02,
      0x03,
      0x00,
      0x04,
      0x00,
      0x17,
      0x01,
      0x01,
      0x03,
      0x00,
    ]);

Uint8List _primitiveAdapterProgramBytes() => Uint8List.fromList(const <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x0d,
  0x00,
  0x01,
  0x00,
  0x01,
  0x38,
  0x00,
  0x61,
  0x73,
  0x6d,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x05,
  0x01,
  0x60,
  0x00,
  0x01,
  0x7f,
  0x03,
  0x02,
  0x01,
  0x00,
  0x05,
  0x03,
  0x01,
  0x00,
  0x01,
  0x07,
  0x0b,
  0x02,
  0x01,
  0x66,
  0x00,
  0x00,
  0x03,
  0x6d,
  0x65,
  0x6d,
  0x02,
  0x00,
  0x0a,
  0x06,
  0x01,
  0x04,
  0x00,
  0x41,
  0x01,
  0x0b,
  0x00,
  0x09,
  0x04,
  0x6e,
  0x61,
  0x6d,
  0x65,
  0x00,
  0x02,
  0x01,
  0x6d,
  0x02,
  0x04,
  0x01,
  0x00,
  0x00,
  0x00,
  0x07,
  0x05,
  0x01,
  0x40,
  0x00,
  0x00,
  0x7a,
  0x06,
  0x0f,
  0x02,
  0x00,
  0x00,
  0x01,
  0x00,
  0x01,
  0x66,
  0x00,
  0x02,
  0x01,
  0x00,
  0x03,
  0x6d,
  0x65,
  0x6d,
  0x08,
  0x0c,
  0x02,
  0x00,
  0x00,
  0x00,
  0x01,
  0x03,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x00,
  0x34,
  0x0e,
  0x63,
  0x6f,
  0x6d,
  0x70,
  0x6f,
  0x6e,
  0x65,
  0x6e,
  0x74,
  0x2d,
  0x6e,
  0x61,
  0x6d,
  0x65,
  0x01,
  0x0c,
  0x00,
  0x00,
  0x01,
  0x01,
  0x07,
  0x6c,
  0x6f,
  0x77,
  0x65,
  0x72,
  0x65,
  0x64,
  0x01,
  0x06,
  0x00,
  0x11,
  0x01,
  0x00,
  0x01,
  0x6d,
  0x01,
  0x06,
  0x00,
  0x12,
  0x01,
  0x00,
  0x01,
  0x6d,
  0x01,
  0x05,
  0x01,
  0x01,
  0x00,
  0x01,
  0x66,
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
