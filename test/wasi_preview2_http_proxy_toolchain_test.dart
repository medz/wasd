import 'dart:io';

// Fixture provenance is verified by SHA-256 before execution.
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:wasd/wasi.dart';
import 'package:wasd/wasm.dart';

const _fixtureDirectory = 'test/fixtures/wasi_preview2';
const _successFixture =
    '$_fixtureDirectory/'
    'wasi_http_0_2_12_proxy_static_response.component.wasm';
const _postReturnTrapFixture =
    '$_fixtureDirectory/'
    'wasi_http_0_2_12_proxy_post_return_trap.component.wasm';
const _unsetResponseFixture =
    '$_fixtureDirectory/'
    'wasi_http_0_2_12_proxy_unset_response.component.wasm';

const _artifacts = <({String path, int size, String sha256})>[
  (
    path:
        '$_fixtureDirectory/'
        'wasi_http_0_2_12_proxy_static_response.guest.wat',
    size: 790,
    sha256: 'ee8950c386c0ab5ee123490182711a7a30bcb1ec0082576622ac13ac77b2df56',
  ),
  (
    path: _successFixture,
    size: 4173,
    sha256: 'a6bdc7afb0f1b7ae16f27e1a1da3502f44cd9d12f7c01bbb3778008a646bc138',
  ),
  (
    path:
        '$_fixtureDirectory/'
        'wasi_http_0_2_12_proxy_post_return_trap.guest.wat',
    size: 806,
    sha256: '10d6894c9c30cdc48317b66d4be02b600bf2521a1aace3f9dfc844a90eb07448',
  ),
  (
    path: _postReturnTrapFixture,
    size: 4174,
    sha256: '4e5e9d40699d4142ec2fd426686af4312f5e3cd0f02fffc8958daf00393d7d42',
  ),
  (
    path:
        '$_fixtureDirectory/'
        'wasi_http_0_2_12_proxy_unset_response.guest.wat',
    size: 193,
    sha256: '95e2e839bcfaf44ec4355a844a14b9cf08af31909bb9368bfda74b03e2615db1',
  ),
  (
    path: _unsetResponseFixture,
    size: 1553,
    sha256: 'f0f6579792df2ebc8a8e361fa4a5125a8e100248635069c781aa1d9863e39e99',
  ),
];

void main() {
  group('WASI HTTP 0.2.12 toolchain proxy components', () {
    test('fixture artifacts are fixed and components are valid', () async {
      for (final artifact in _artifacts) {
        final bytes = await File(artifact.path).readAsBytes();

        expect(bytes, hasLength(artifact.size), reason: artifact.path);
        expect(
          sha256.convert(bytes).toString(),
          artifact.sha256,
          reason: artifact.path,
        );
        if (artifact.path.endsWith('.component.wasm')) {
          expect(
            WasmComponent.decode(bytes).validate(),
            isEmpty,
            reason: artifact.path,
          );
        }
      }
    });

    test('returns a successful static response', () async {
      final host = WASIPreview2ComponentHost();
      final baseline = host.componentHost.table.activeCount;
      final responseOutparam = await _handle(_successFixture, host: host);

      expect(responseOutparam.informationalResponses, isEmpty);
      final result = responseOutparam.response;
      expect(result, isNotNull);
      expect(result!.isOk, isTrue);
      expect(result.errorCode, isNull);

      final response = result.value;
      expect(response, isNotNull);
      expect(response!.statusCode, 200);
      expect(response.headers.entries, isEmpty);
      expect(response.bodyResource, isNull);
      expect(host.componentHost.table.activeCount, baseline);
    });

    test('executes the canonical post-return function', () async {
      final host = WASIPreview2ComponentHost();
      final baseline = host.componentHost.table.activeCount;
      await expectLater(
        _handle(_postReturnTrapFixture, host: host),
        throwsA(
          predicate<Object>(
            (error) => error.toString().contains('unreachable trap'),
            'a WebAssembly unreachable trap from post-return',
          ),
        ),
      );
      expect(host.componentHost.table.activeCount, baseline);
    });

    test('rejects a handler that leaves the response unset', () async {
      final host = WASIPreview2ComponentHost();
      final baseline = host.componentHost.table.activeCount;
      await expectLater(
        _handle(_unsetResponseFixture, host: host),
        throwsA(isA<WASIPreview2ComponentExecutionException>()),
      );
      expect(host.componentHost.table.activeCount, baseline);
    });
  });
}

Future<WASIPreview2HttpResponseOutparam> _handle(
  String fixturePath, {
  WASIPreview2ComponentHost? host,
}) async {
  final component = WasmComponent.decode(await File(fixturePath).readAsBytes());
  return WASIPreview2ProxyRunner(host ?? WASIPreview2ComponentHost()).handle(
    component,
    WASIPreview2HttpIncomingRequest(
      method: const WASIPreview2HttpMethod.standard('get'),
      headers: WASIPreview2HttpFields(),
      pathWithQuery: '/',
      scheme: const WASIPreview2HttpScheme.standard('HTTP'),
      authority: 'example.test',
    ),
  );
}
