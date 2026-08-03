import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wasd/src/wasi/component/standard_wit.dart';
import 'package:wasd/src/wasi/component/wit_adapter.dart';
import 'package:wasd/src/wasi/component/wit_document.dart';

void main() {
  group('official WASI Preview3 WIT', () {
    test('pins the frozen Preview3 contract inputs', () {
      final manifest =
          jsonDecode(
                File(
                  'tool/wasi_preview3_contract.lock.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      final wasi = manifest['wasi']! as Map<String, Object?>;
      final componentModel =
          manifest['component_model']! as Map<String, Object?>;
      final testsuite = manifest['wasi_testsuite']! as Map<String, Object?>;

      expect(wasi['version'], '0.3.0');
      expect(wasi['commit'], '3ee2a590c766594ae44a54730fc74fc27da5c609');
      expect((wasi['packages']! as List<Object?>).length, 6);
      expect((wasi['worlds']! as List<Object?>).length, 8);
      expect(wasi['excluded'], ['wasi:clocks/timezone@0.3.0']);
      expect(
        componentModel['commit'],
        '73b7ad51d3b5d6f1ef53c923d8c585e28b242bcc',
      );
      expect(componentModel['gate'], 'async');
      expect(
        testsuite['source_commit'],
        '6600796756adce3632409d7e207a9834c9d99ff8',
      );
      expect(
        testsuite['fixture_commit'],
        'c63d52e69316d1aa2c9e7db6251892775204e7e0',
      );
      expect(testsuite['target'], 'wasm32-wasip3');
      expect(testsuite['fixture_count'], 45);
    });

    test('resolves all six packages and eight stable worlds', () {
      const expectedPackages =
          <String, ({List<String> interfaces, List<String> worlds})>{
            'wasi:random': (
              interfaces: ['insecure', 'insecure-seed', 'random'],
              worlds: ['imports'],
            ),
            'wasi:clocks': (
              interfaces: ['monotonic-clock', 'system-clock', 'types'],
              worlds: ['imports'],
            ),
            'wasi:filesystem': (
              interfaces: ['preopens', 'types'],
              worlds: ['imports'],
            ),
            'wasi:sockets': (
              interfaces: ['ip-name-lookup', 'types'],
              worlds: ['imports'],
            ),
            'wasi:cli': (
              interfaces: [
                'environment',
                'exit',
                'run',
                'stderr',
                'stdin',
                'stdout',
                'terminal-input',
                'terminal-output',
                'terminal-stderr',
                'terminal-stdin',
                'terminal-stdout',
                'types',
              ],
              worlds: ['command', 'imports'],
            ),
            'wasi:http': (
              interfaces: ['client', 'handler', 'types'],
              worlds: ['middleware', 'service'],
            ),
          };

      var worldCount = 0;
      for (final MapEntry(key: package, value: expected)
          in expectedPackages.entries) {
        final member = expected.interfaces.first;
        final resolved = resolveWASIComponentStandardWitTarget(
          '$package/$member@0.3.0',
        );

        expect(resolved, isNotNull, reason: package);
        final document = resolved!.document;
        expect(document.package?.text, '$package@0.3.0');
        expect(
          document.interfaces.map((interface) => interface.name).toList()
            ..sort(),
          expected.interfaces,
          reason: package,
        );
        expect(
          document.worlds.map((world) => world.name).toList()..sort(),
          expected.worlds,
          reason: package,
        );
        for (final world in expected.worlds) {
          expect(
            resolveWASIComponentStandardWitTarget(
              '$package/$world@0.3.0',
            )?.document.worldNamed(world),
            isNotNull,
            reason: '$package/$world',
          );
        }
        worldCount += document.worlds.length;
      }

      expect(worldCount, 8);
      final clocks = _document('wasi:clocks/types@0.3.0');
      expect(clocks.interfaceNamed('timezone'), isNull);
    });

    test(
      'preserves the official CLI include graph and resolves every target',
      () {
        final cli = _document('wasi:cli/command@0.3.0');
        final imports = cli.worldNamed('imports')!;
        final command = cli.worldNamed('command')!;

        expect(imports.includes.map((item) => item.target.text), [
          'wasi:clocks/imports@0.3.0',
          'wasi:filesystem/imports@0.3.0',
          'wasi:sockets/imports@0.3.0',
          'wasi:random/imports@0.3.0',
        ]);
        expect(imports.imports.map((item) => item.target.text), [
          'environment',
          'exit',
          'stdin',
          'stdout',
          'stderr',
          'terminal-input',
          'terminal-output',
          'terminal-stdin',
          'terminal-stdout',
          'terminal-stderr',
        ]);
        expect(command.includes.single.target.text, 'imports');
        expect(command.exports.single.target.text, 'run');

        for (final target in imports.includes.map((item) => item.target.text)) {
          final resolved = resolveWASIComponentStandardWitTarget(target);
          expect(resolved, isNotNull, reason: target);
          expect(
            resolved!.document.worldNamed(resolved.memberName),
            isNotNull,
            reason: target,
          );
        }

        expect(
          () => wasiComponentWitWorldFunctions(
            cli,
            command,
            resolveTarget: resolveWASIComponentStandardWitTarget,
          ),
          returnsNormally,
        );
      },
    );

    test('matches stable world shapes and Preview3 async signatures', () {
      final random = _document('wasi:random/imports@0.3.0');
      expect(
        random.worldNamed('imports')!.imports.map((item) => item.target.text),
        ['random', 'insecure', 'insecure-seed'],
      );

      final clocks = _document('wasi:clocks/imports@0.3.0');
      expect(
        clocks.worldNamed('imports')!.imports.map((item) => item.target.text),
        ['monotonic-clock', 'system-clock'],
      );
      expect(
        _function(clocks, 'monotonic-clock', 'wait-until').signature,
        'asyncfunc(when:mark,)',
      );

      final filesystem = _document('wasi:filesystem/types@0.3.0');
      expect(
        filesystem
            .worldNamed('imports')!
            .imports
            .map((item) => item.target.text),
        ['types', 'preopens'],
      );
      expect(
        _function(filesystem, 'types', 'descriptor.read-via-stream').signature,
        'func(self:borrow<descriptor>,offset:filesize,)->tuple<stream<u8>,future<result<_,error-code>>>',
      );

      final sockets = _document('wasi:sockets/types@0.3.0');
      expect(
        sockets.worldNamed('imports')!.imports.map((item) => item.target.text),
        ['types', 'ip-name-lookup'],
      );
      expect(
        _function(sockets, 'types', 'tcp-socket.connect').signature,
        'asyncfunc(self:borrow<tcp-socket>,remote-address:ip-socket-address)->result<_,error-code>',
      );
      expect(
        _function(sockets, 'types', 'tcp-socket.receive').signature,
        'func(self:borrow<tcp-socket>)->tuple<stream<u8>,future<result<_,error-code>>>',
      );

      final cli = _document('wasi:cli/stdin@0.3.0');
      expect(
        _function(cli, 'stdin', 'read-via-stream').signature,
        'func()->tuple<stream<u8>,future<result<_,error-code>>>',
      );
      expect(_function(cli, 'run', 'run').signature, 'asyncfunc()->result');

      final http = _document('wasi:http/types@0.3.0');
      expect(
        http.worldNamed('service')!.includes.map((item) => item.target.text),
        ['wasi:clocks/imports@0.3.0', 'wasi:random/imports@0.3.0'],
      );
      expect(
        http.worldNamed('service')!.imports.map((item) => item.target.text),
        [
          'wasi:cli/stdout@0.3.0',
          'wasi:cli/stderr@0.3.0',
          'wasi:cli/stdin@0.3.0',
          'client',
        ],
      );
      expect(http.worldNamed('service')!.exports.single.target.text, 'handler');
      expect(
        http.worldNamed('middleware')!.includes.single.target.text,
        'service',
      );
      expect(
        http.worldNamed('middleware')!.imports.single.target.text,
        'handler',
      );
      expect(
        _function(http, 'handler', 'handle').signature,
        'asyncfunc(request:request,)->result<response,error-code>',
      );
      expect(
        _function(http, 'client', 'send').signature,
        'asyncfunc(request:request,)->result<response,error-code>',
      );
      expect(
        _function(http, 'types', 'request.new').signature,
        'func(headers:headers,contents:option<stream<u8>>,trailers:future<result<option<trailers>,error-code>>,options:option<request-options>)->tuple<request,future<result<_,error-code>>>',
      );
      expect(
        () => wasiComponentWitWorldFunctions(
          http,
          http.worldNamed('middleware')!,
          resolveTarget: resolveWASIComponentStandardWitTarget,
        ),
        returnsNormally,
      );
    });
  });
}

WASIComponentWitDocument _document(String target) {
  final resolved = resolveWASIComponentStandardWitTarget(target);
  expect(resolved, isNotNull, reason: target);
  return resolved!.document;
}

WASIComponentWitFunction _function(
  WASIComponentWitDocument document,
  String interfaceName,
  String functionName,
) {
  return document
      .interfaceNamed(interfaceName)!
      .functions
      .singleWhere((function) => function.name == functionName);
}
