import 'dart:typed_data';

import '_native_wasm_bridge.dart' as _native;

typedef WasmFeatureSet = _native.WasmFeatureSet;
typedef WasmModule = _native.WasmModule;
typedef WasmInstance = _native.WasmInstance;

void main() {
  runThreadsPortableChecks();
}

void runThreadsPortableChecks() {
  final module = WasmModule.decode(
    _threadsPortableCheckModule,
    features: const WasmFeatureSet(threads: true),
  );
  WasmInstance.fromModule(
    module,
    features: const WasmFeatureSet(threads: true),
  );
}

final Uint8List _threadsPortableCheckModule = Uint8List.fromList(<int>[
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
  0x07,
  0x09,
  0x01,
  0x05,
  0x73,
  0x75,
  0x6d,
  0x3a,
  0x31,
  0x00,
  0x00,
  0x0a,
  0x06,
  0x01,
  0x04,
  0x00,
  0x41,
  0x2a,
  0x0b,
]);
