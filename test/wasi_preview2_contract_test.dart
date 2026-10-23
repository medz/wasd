@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/standard_wit.dart';
import 'package:wasd/src/wasi/component/wit_document.dart';

void main() {
  test(
    'complete execution fixtures retain their audited source and binary',
    () {
      final fixtures = _lock()['fixtures'] as Map<String, dynamic>;
      for (final entry in fixtures.entries) {
        final file = File('test/fixtures/wasi_preview2/${entry.key}');
        final bytes = file.readAsBytesSync();
        expect(bytes.length, entry.value['bytes'], reason: entry.key);
        expect(
          sha256.convert(bytes).toString(),
          entry.value['sha256'],
          reason: entry.key,
        );
        final source = File(
          file.path.replaceFirst(RegExp(r'\.wasm$'), '.wat'),
        ).readAsBytesSync();
        expect(
          source.length,
          entry.value['source']['bytes'],
          reason: entry.key,
        );
        expect(
          sha256.convert(source).toString(),
          entry.value['source']['sha256'],
          reason: entry.key,
        );
      }
    },
  );

  test('0.2.12 defaults to the complete stable upstream declarations', () {
    var functionCount = 0;
    for (final name in _packages) {
      final document = _document(name);
      expect(document.package!.text, 'wasi:$name@0.2.12');
      for (final interface in document.interfaces) {
        functionCount += interface.functions.length;
      }
    }
    expect(functionCount, 177);
    expect(
      _document('http').interfaceNamed('types')!.functions.map((f) => f.name),
      isNot(contains('response-outparam.send-informational')),
    );
    expect(_document('clocks').interfaceNamed('timezone'), isNull);
    expect(
      _document(
        'sockets',
      ).interfaceNamed('network')!.functions.map((f) => f.name),
      isNot(contains('network-error-code')),
    );
  });

  test('0.2.12 retains complete expanded HTTP world interface boundaries', () {
    final document = _document('http');
    final world = document.worldNamed('proxy')!;
    expect(
      world.items
          .where((item) => item.direction.name == 'import')
          .map((item) => item.target.text),
      [
        'wasi:io/poll@0.2.12',
        'wasi:clocks/monotonic-clock@0.2.12',
        'wasi:clocks/wall-clock@0.2.12',
        'wasi:random/random@0.2.12',
        'wasi:io/error@0.2.12',
        'wasi:io/streams@0.2.12',
        'wasi:cli/stdout@0.2.12',
        'wasi:cli/stderr@0.2.12',
        'wasi:cli/stdin@0.2.12',
        'types',
        'outgoing-handler',
      ],
    );
    expect(
      world.items
          .where((item) => item.direction.name == 'export')
          .map((item) => item.target.text),
      ['incoming-handler'],
    );
  });

  test('0.2.12 supports a separate informational feature contract', () {
    final optional = _document('http', features: {_informational});
    expect(
      optional.interfaceNamed('types')!.functions.map((f) => f.name),
      contains('response-outparam.send-informational'),
    );
    expect(optional, isNot(same(_document('http'))));
    var total = 0;
    final added = <String>[];
    for (final package in _packages) {
      final stable = _document(package);
      final enabled = _document(package, features: {_informational});
      if (package != 'http') expect(enabled, same(stable));
      for (final interface in enabled.interfaces) {
        final before = {
          for (final function
              in stable.interfaceNamed(interface.name)!.functions)
            function.name: function.signature,
        };
        for (final function in interface.functions) {
          total++;
          if (!before.containsKey(function.name)) {
            added.add('$package/${interface.name}.${function.name}');
          } else {
            expect(function.signature, before[function.name]);
          }
        }
        expect(interface.functions.length, greaterThanOrEqualTo(before.length));
      }
    }
    expect(total, 178);
    expect(added, ['http/types.response-outparam.send-informational']);
    expect(_document('http', features: {_informational}), same(optional));
    expect(_document('http'), isNot(same(optional)));
  });

  test('unknown features are rejected without changing cached contracts', () {
    final stable = _document('http');
    final features = <String>{_informational};
    final optional = _document('http', features: features);
    features.clear();
    expect(_document('http', features: features), same(stable));
    features.add('clocks-timezone');
    expect(() => _document('http', features: features), throwsArgumentError);
    expect(_document('http', features: {_informational}), same(optional));
    expect(_document('http'), same(stable));
  });

  test(
    'earlier 0.2.x compatibility contracts retain their existing behavior',
    () {
      for (final version in ['0.2.0', '0.2.11']) {
        final old = resolveWASIComponentStandardWitTarget(
          'wasi:http/types@$version',
        )!.document;
        expect(old.package!.text, 'wasi:http@$version');
        expect(
          old
              .interfaceNamed('types')!
              .functions
              .map((function) => function.name),
          contains('response-outparam.send-informational'),
        );
        expect(old, isNot(same(_document('http'))));
        expect(
          resolveWASIComponentStandardWitTarget(
            'wasi:http/types@$version',
          )!.document,
          same(old),
        );
      }
      expect(
        resolveWASIComponentStandardWitTarget('wasi:http/types@0.2.13'),
        isNull,
      );
    },
  );

  test(
    'all nine world boundaries match the fixed qualified interface oracle',
    () {
      final expectedWorlds = _lock()['worlds'] as Map<String, dynamic>;
      final actualWorlds = <String, Object>{};
      for (final package in _packages) {
        final document = _document(package);
        for (final world in document.worlds) {
          actualWorlds['wasi:$package/${world.name}@0.2.12'] = {
            for (final direction in ['import', 'export'])
              '${direction}s': [
                for (final item in world.items)
                  if (item.direction.name == direction)
                    item.target.isQualified
                        ? item.target.text
                        : 'wasi:$package/${item.target.text}@0.2.12',
              ],
          };
        }
      }
      expect(actualWorlds, expectedWorlds);
    },
  );

  test(
    'pins all 33 source blob and content digests to the upstream commit',
    () {
      final wasi = _lock()['wasi'] as Map<String, dynamic>;
      expect(wasi['version'], '0.2.12');
      expect(wasi['commit'], '281ba75fafcd50961ef55f9e52747afcc9b71ede');
      expect(wasi['tree'], 'edaab1239de855e4fb3f95bb73e5139f66adfd0f');
      final files = wasi['source_files'] as List<dynamic>;
      expect(files, hasLength(33));
      expect(files.map((dynamic file) => file['path']).toSet(), hasLength(33));
      var bytes = 0;
      for (final file in files) {
        expect(file['path'], matches(r'^proposals/[^/]+/wit/[^/]+\.wit$'));
        expect(file['git_blob'], matches(r'^[0-9a-f]{40}$'));
        expect(file['sha256'], matches(r'^[0-9a-f]{64}$'));
        bytes += file['bytes'] as int;
      }
      expect(bytes, 140580);
      expect(wasi['source_bytes'], bytes);
      expect(_lock()['excluded_features'], [
        'clocks-timezone',
        'network-error-code',
      ]);
    },
  );

  test('embedded packages and the 144-byte feature match normalized hashes', () {
    final lock = _lock();
    final source = File(
      'lib/src/wasi/component/standard_wit_preview2.dart',
    ).readAsStringSync();
    final embedded = {
      for (final match in RegExp(
        r"const String _wasi([A-Za-z]+)0212PinnedSource\s*=\s*r'''([\s\S]*?)''';",
      ).allMatches(source))
        'wasi:${match.group(1)!.toLowerCase()}': match.group(2)!,
    };
    expect(embedded.length, 7);
    final delta = RegExp(
      r"const String _wasiHttp0212InformationalMethod\s*=\s*r'''([\s\S]*?)''';",
    ).firstMatch(source)!.group(1)!;
    final extension = lock['informational_extension'] as Map<String, dynamic>;
    expect(utf8.encode(delta), hasLength(144));
    expect(extension['bytes'], 144);
    expect(sha256.convert(utf8.encode(delta)).toString(), extension['sha256']);
    const marker = '  resource response-outparam {\n';
    expect(extension['insert_after'], marker);
    final profiles = lock['profiles'] as Map<String, dynamic>;
    for (final profile in profiles.entries) {
      final packages = profile.value['packages'] as Map<String, dynamic>;
      expect(packages.keys.toSet(), embedded.keys.toSet());
      for (final package in packages.entries) {
        final stable = embedded[package.key]!;
        final normalized =
            profile.key != 'stable-default' && package.key == 'wasi:http'
            ? stable.replaceFirst(marker, '$marker$delta')
            : stable;
        final bytes = utf8.encode(normalized);
        expect(bytes.length, package.value['bytes'], reason: package.key);
        expect(
          sha256.convert(bytes).toString(),
          package.value['sha256'],
          reason: '${profile.key} ${package.key}',
        );
        expect(normalized, startsWith('package ${package.key}@0.2.12;'));
      }
    }
  });
}

const _packages = [
  'io',
  'clocks',
  'filesystem',
  'sockets',
  'random',
  'cli',
  'http',
];

const _informational = 'informational-outbound-responses';

WASIComponentWitDocument _document(
  String package, {
  Set<String> features = const {},
}) => resolveWASIComponentStandardWitTarget(
  'wasi:$package/imports@0.2.12',
  features: features,
)!.document;

Map<String, dynamic> _lock() =>
    jsonDecode(File('tool/wasi_preview2_contract.lock.json').readAsStringSync())
        as Map<String, dynamic>;
