@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/features.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/imports.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/instance.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/memory.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/module.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/runtime_global.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/table.dart';
import 'package:wasd/src/wasm/backend/native/interpreter/value.dart';
import 'package:wasd/wasi.dart';
import 'package:wasd/wasm.dart' show WasmComponent;

final _features = WasmFeatureSet.layeredDefaults(
  profile: WasmFeatureProfile.full,
  additionalEnabled: {'multi-memory', 'multi-table', 'custom-descriptors'},
);

WasmModule _module(String name) => WasmModule.decode(
  File('test/fixtures/import_keys/$name.wasm').readAsBytesSync(),
  features: _features,
);

WasmInstance _instantiate(WasmModule module, WasmImports imports) =>
    WasmInstance.fromModule(module, features: _features, imports: imports);

BigInt _integer(Object? value) =>
    value is BigInt ? value : BigInt.from(value as int);

WasmImports _imports(
  String kind,
  WasmModule module, {
  bool missingSecond = false,
  bool wrongSecond = false,
}) {
  final first = WasmImports.key(
    module.imports[0].module,
    module.imports[0].name,
  );
  final second = WasmImports.key(
    module.imports[1].module,
    module.imports[1].name,
  );
  Map<String, T> pair<T>(T left, T right) => {
    first: left,
    if (!missingSecond) second: right,
  };
  switch (kind) {
    case 'function':
    case 'exact':
      return WasmImports(
        functions: pair((_) => 11, (_) => BigInt.from(22)),
        functionTypes: pair(module.types[0], module.types[wrongSecond ? 0 : 1]),
        functionTypeDepths: pair(17, 29),
      );
    case 'memory':
      return WasmImports(
        memories: pair(
          WasmMemory(minPages: 1, maxPages: 3),
          WasmMemory(minPages: wrongSecond ? 0 : 2, maxPages: 3),
        ),
      );
    case 'table':
      return WasmImports(
        tables: pair(
          WasmTable(refType: WasmRefType.funcref, min: 1, max: 3),
          WasmTable(
            refType: wrongSecond ? WasmRefType.externref : WasmRefType.funcref,
            min: 2,
            max: 3,
          ),
        ),
      );
    case 'global':
      return WasmImports(
        globalBindings: pair(
          RuntimeGlobal(
            valueType: WasmValueType.i32,
            mutable: true,
            value: WasmValue.i32(31),
          ),
          RuntimeGlobal(
            valueType: wrongSecond ? WasmValueType.f64 : WasmValueType.i32,
            mutable: true,
            value: wrongSecond ? WasmValue.f64(32) : WasmValue.i32(32),
          ),
        ),
      );
    case 'tag':
      final provider = _instantiate(
        _module('tag_provider'),
        const WasmImports(),
      );
      return WasmImports(
        tags: pair(
          provider.exportedTagImport('first'),
          provider.exportedTagImport(wrongSecond ? 'bad' : 'second'),
        ),
      );
    default:
      throw ArgumentError(kind);
  }
}

void main() {
  for (final side in ['first', 'second']) {
    test(
      'Component Core $side connections preserve import identities',
      () async {
        final component = WasmComponent.decode(
          File(
            'test/fixtures/import_keys/core_names_$side.component.wasm',
          ).readAsBytesSync(),
        );
        expect(component.validate(), isEmpty);
        final host = WASIPreview2ComponentHost();
        final result = await WASIPreview2CommandRunner(host).run(component);
        expect(result.exitCode, 0);
      },
    );
  }
  for (final kind in [
    'function',
    'exact',
    'memory',
    'table',
    'global',
    'tag',
  ]) {
    for (final names in ['colon', 'empty', 'unicode']) {
      test('$kind $names imports preserve both identities', () {
        final module = _module('${kind}_$names');
        final imports = _imports(kind, module);
        final instance = _instantiate(module, imports);
        switch (kind) {
          case 'function':
          case 'exact':
            expect(instance.invoke('first'), 11);
            expect(_integer(instance.invoke('second')), BigInt.from(22));
            expect(instance.exportedFunctionTypeDepth('first'), 17);
            expect(instance.exportedFunctionTypeDepth('second'), 29);
            expect(
              module.imports.every((i) => i.isExactFunction),
              kind == 'exact',
            );
          case 'tag':
            final keys = module.imports.map((i) => i.key).toList();
            expect(
              instance.exportedTagImport('first'),
              same(imports.tags[keys[0]]),
            );
            expect(
              instance.exportedTagImport('second'),
              same(imports.tags[keys[1]]),
            );
            expect(
              instance.exportedTagImport('first').nominalTypeKey,
              isNot(instance.exportedTagImport('second').nominalTypeKey),
            );
          default:
            final values = kind == 'global' ? [31, 32] : [1, 2];
            expect(instance.invoke('getFirst'), values[0]);
            expect(instance.invoke('getSecond'), values[1]);
            if (kind == 'global') {
              instance
                  .exportedGlobalBinding('first')
                  .setValue(WasmValue.i32(41));
              expect(instance.invoke('getFirst'), 41);
              expect(instance.invoke('getSecond'), 32);
            }
        }
      });

      test('$kind $names missing second cannot reuse first', () {
        final module = _module('${kind}_$names');
        expect(
          () =>
              _instantiate(module, _imports(kind, module, missingSecond: true)),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('Missing'),
            ),
          ),
        );
      });

      test('$kind $names checks the second type independently', () {
        final module = _module('${kind}_$names');
        expect(
          () => _instantiate(module, _imports(kind, module, wrongSecond: true)),
          throwsA(isA<StateError>()),
        );
      });
    }
  }

  for (final kind in ['function', 'exact']) {
    test(
      '$kind asynchronous callbacks and metadata keep their identity',
      () async {
        final module = _module('${kind}_colon');
        final first = module.imports[0].key, second = module.imports[1].key;
        final instance = _instantiate(
          module,
          WasmImports(
            asyncFunctions: {
              first: (_) async => 11,
              second: (_) async => BigInt.from(22),
            },
            functionTypes: {first: module.types[0], second: module.types[1]},
            functionTypeDepths: {first: 17, second: 29},
          ),
        );
        expect(instance.hasAsyncOnlyHostImports, isTrue);
        expect(await instance.invokeAsync('first'), 11);
        expect(_integer(await instance.invokeAsync('second')), BigInt.from(22));
        expect(instance.exportedFunctionTypeDepth('first'), 17);
        expect(instance.exportedFunctionTypeDepth('second'), 29);
      },
    );
  }

  for (final wrongType in [false, true]) {
    test('scalar globals retain their type metadata wrongType=$wrongType', () {
      final module = _module('global_colon');
      final first = module.imports[0].key, second = module.imports[1].key;
      final imports = WasmImports(
        globals: {first: 31, second: 32},
        globalTypes: {
          first: const WasmGlobalType(
            valueType: WasmValueType.i32,
            mutable: true,
          ),
          second: WasmGlobalType(
            valueType: wrongType ? WasmValueType.f64 : WasmValueType.i32,
            mutable: true,
          ),
        },
      );
      if (wrongType) {
        expect(() => _instantiate(module, imports), throwsA(isA<StateError>()));
      } else {
        final instance = _instantiate(module, imports);
        expect(instance.invoke('getFirst'), 31);
        expect(instance.invoke('getSecond'), 32);
      }
    });
  }

  test('global mutability remains checked for the second identity', () {
    final module = _module('global_colon');
    final imports = _imports('global', module);
    imports.globalBindings[module.imports[1].key] = RuntimeGlobal(
      valueType: WasmValueType.i32,
      mutable: false,
      value: WasmValue.i32(32),
    );
    expect(() => _instantiate(module, imports), throwsA(isA<StateError>()));
  });

  test('same global binding can deliberately alias distinct identities', () {
    final module = _module('global_colon');
    final binding = RuntimeGlobal(
      valueType: WasmValueType.i32,
      mutable: true,
      value: WasmValue.i32(31),
    );
    final instance = _instantiate(
      module,
      WasmImports(
        globalBindings: {
          for (final import in module.imports) import.key: binding,
        },
      ),
    );
    binding.setValue(WasmValue.i32(41));
    expect(instance.invoke('getFirst'), 41);
    expect(instance.invoke('getSecond'), 41);
  });

  test('manually concatenated internal keys have no legacy fallback', () {
    final module = _module('global_colon');
    expect(
      () => _instantiate(module, const WasmImports(globals: {'a::b::c': 31})),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Missing'),
        ),
      ),
    );
  });
}
