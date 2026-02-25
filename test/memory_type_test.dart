import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/wasd.dart';

void main() {
  group('memory type decoding', () {
    test('decodes shared memory limits flags', () {
      final wasm = _moduleWithDefinedMemory(flags: 0x03, min: 1, max: 2);

      final module = WasmModule.decode(wasm);
      final memory = module.memories.single;
      expect(memory.minPages, 1);
      expect(memory.maxPages, 2);
      expect(memory.shared, isTrue);
      expect(memory.isMemory64, isFalse);
      expect(memory.pageSizeLog2, 16);
    });

    test('decodes custom page size limits flags', () {
      final wasm = _moduleWithDefinedMemory(
        flags: 0x08,
        min: 2,
        pageSizeLog2: 0,
      );

      final module = WasmModule.decode(wasm);
      final memory = module.memories.single;
      expect(memory.minPages, 2);
      expect(memory.maxPages, isNull);
      expect(memory.shared, isFalse);
      expect(memory.isMemory64, isFalse);
      expect(memory.pageSizeLog2, 0);
    });
  });

  group('memory type instantiation', () {
    test('rejects custom page sizes at instantiation', () {
      final wasm = _moduleWithDefinedMemory(
        flags: 0x08,
        min: 1,
        pageSizeLog2: 0,
      );

      expect(
        () => WasmInstance.fromBytes(wasm),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => error.message,
            'message',
            contains('custom page size'),
          ),
        ),
      );
    });

    test('rejects shared import with non-shared host memory', () {
      final wasm = _moduleWithImportedMemory(
        flags: 0x03,
        min: 1,
        max: 2,
        exportMemory: true,
      );

      final imports = WasmImports(
        memories: {
          WasmImports.key('env', 'mem'): WasmMemory(
            minPages: 1,
            maxPages: 2,
            shared: false,
          ),
        },
      );

      expect(
        () => WasmInstance.fromBytes(
          wasm,
          imports: imports,
          features: const WasmFeatureSet(threads: true),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('shared flag mismatch'),
          ),
        ),
      );
    });

    test('accepts shared import when host memory is shared', () {
      final wasm = _moduleWithImportedMemory(
        flags: 0x03,
        min: 1,
        max: 2,
        exportMemory: true,
      );

      final imports = WasmImports(
        memories: {
          WasmImports.key('env', 'mem'): WasmMemory(
            minPages: 1,
            maxPages: 2,
            shared: true,
          ),
        },
      );

      final instance = WasmInstance.fromBytes(
        wasm,
        imports: imports,
        features: const WasmFeatureSet(threads: true),
      );
      expect(instance.exportedMemory('mem').shared, isTrue);
    });
  });
}

Uint8List _moduleWithDefinedMemory({
  required int flags,
  required int min,
  int? max,
  int? pageSizeLog2,
}) {
  final limits = _limits(
    flags: flags,
    min: min,
    max: max,
    pageSizeLog2: pageSizeLog2,
  );
  final memorySection = _section(5, <int>[..._u32Leb(1), ...limits]);
  return Uint8List.fromList(<int>[..._wasmHeader, ...memorySection]);
}

Uint8List _moduleWithImportedMemory({
  required int flags,
  required int min,
  int? max,
  int? pageSizeLog2,
  bool exportMemory = false,
}) {
  final importPayload = <int>[
    ..._u32Leb(1),
    ..._name('env'),
    ..._name('mem'),
    WasmImportKind.memory,
    ..._limits(flags: flags, min: min, max: max, pageSizeLog2: pageSizeLog2),
  ];
  final sections = <int>[..._section(2, importPayload)];
  if (exportMemory) {
    sections.addAll(
      _section(7, <int>[
        ..._u32Leb(1),
        ..._name('mem'),
        WasmExportKind.memory,
        0,
      ]),
    );
  }
  return Uint8List.fromList(<int>[..._wasmHeader, ...sections]);
}

const List<int> _wasmHeader = <int>[
  0x00,
  0x61,
  0x73,
  0x6d,
  0x01,
  0x00,
  0x00,
  0x00,
];

List<int> _section(int id, List<int> payload) => <int>[
  id,
  ..._u32Leb(payload.length),
  ...payload,
];

List<int> _name(String value) {
  final bytes = value.codeUnits;
  return <int>[..._u32Leb(bytes.length), ...bytes];
}

List<int> _limits({
  required int flags,
  required int min,
  int? max,
  int? pageSizeLog2,
}) {
  final bytes = <int>[..._u32Leb(flags), ..._u32Leb(min)];
  if ((flags & 0x01) != 0) {
    if (max == null) {
      throw ArgumentError('max is required when flags has max bit.');
    }
    bytes.addAll(_u32Leb(max));
  }
  if ((flags & 0x08) != 0) {
    if (pageSizeLog2 == null) {
      throw ArgumentError(
        'pageSizeLog2 is required when flags has page-size bit.',
      );
    }
    bytes.addAll(_u32Leb(pageSizeLog2));
  }
  return bytes;
}

List<int> _u32Leb(int value) {
  var remaining = value;
  final bytes = <int>[];
  do {
    var byte = remaining & 0x7f;
    remaining >>= 7;
    if (remaining != 0) {
      byte |= 0x80;
    }
    bytes.add(byte);
  } while (remaining != 0);
  return bytes;
}
