import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasd/wasm.dart';
import 'package:wasd/wasi.dart';

// Inline fixture: WASI command module
//   imports: wasi_snapshot_preview1.proc_exit (i32) -> ()
//   exports: _start () -> (), memory
//   _start body: i32.const 42 / call proc_exit / end
final _wasiBytes = Uint8List.fromList([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
  0x01, 0x08, 0x02, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x00, // type section
  0x02, 0x24, 0x01, 0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, // import section
  0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f, 0x70, 0x72,
  0x65, 0x76, 0x69, 0x65, 0x77, 0x31, 0x09, 0x70, 0x72, 0x6f,
  0x63, 0x5f, 0x65, 0x78, 0x69, 0x74, 0x00, 0x00,
  0x03, 0x02, 0x01, 0x01, // function section
  0x05, 0x03, 0x01, 0x00, 0x01, // memory section
  0x07, 0x13, 0x02, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, // export section
  0x00, 0x01, 0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00,
  0x0a, 0x08, 0x01, 0x06, 0x00, 0x41, 0x2a, 0x10, 0x00, 0x0b, // code section
]);

void main() {
  group('WASI', () {
    test('constructor creates instance', () {
      final wasi = WASI();
      expect(wasi, isA<WASI>());
    });

    test('imports contains wasi_snapshot_preview1', () {
      final wasi = WASI();
      expect(wasi.imports.containsKey('wasi_snapshot_preview1'), isTrue);
    });

    test('imports has proc_exit function', () {
      final wasi = WASI();
      final preview1 = wasi.imports['wasi_snapshot_preview1']!;
      expect(preview1.containsKey('proc_exit'), isTrue);
      expect(preview1['proc_exit'], isA<FunctionImportExportValue>());
    });

    group('with instantiated module', () {
      late WASI wasi;
      late Instance instance;

      setUp(() async {
        wasi = WASI(args: ['app.wasm']);
        final result = await WebAssembly.instantiate(
          _wasiBytes.buffer,
          wasi.imports,
        );
        instance = result.instance;
      });

      test('instance exports _start and memory', () {
        expect(instance.exports.containsKey('_start'), isTrue);
        expect(instance.exports.containsKey('memory'), isTrue);
      });

      test('start returns exit code 42', () {
        final code = wasi.start(instance);
        expect(code, 42);
      });
    });
  });
}
