import 'dart:io';

// SHA-256 stays test-only; package:test already locks crypto.
// ignore: depend_on_referenced_packages
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:wasd/wasi.dart';
import 'package:wasd/wasm.dart';

const _fixturePath =
    'test/fixtures/wasi_preview2/'
    'wasi_http_0_2_12_static_response.component.wasm';
const _fixtureSha256 =
    '94bd7c8d6a10cca265f7237868135b37c7e76b9b12967d863fe988ad880f07a8';

void main() {
  group('WASI HTTP 0.2.12 proxy component', () {
    test('fixture is fixed and valid', () async {
      final bytes = await File(_fixturePath).readAsBytes();

      expect(bytes, isNotEmpty);
      expect(sha256.convert(bytes).toString(), _fixtureSha256);

      final component = WasmComponent.decode(bytes);
      expect(component.validate(), isEmpty);
    });

    test('returns a successful static response', () async {
      final bytes = await File(_fixturePath).readAsBytes();
      final component = WasmComponent.decode(bytes);
      final host = WASIPreview2ComponentHost();
      final incomingRequest = WASIPreview2HttpIncomingRequest(
        method: const WASIPreview2HttpMethod.standard('get'),
        headers: WASIPreview2HttpFields(),
        pathWithQuery: '/',
        scheme: const WASIPreview2HttpScheme.standard('HTTP'),
        authority: 'example.test',
      );

      final responseOutparam = await WASIPreview2ProxyRunner(
        host,
      ).handle(component, incomingRequest);

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
    });
  });
}
