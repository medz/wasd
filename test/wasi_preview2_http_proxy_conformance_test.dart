import 'dart:io';

// Fixture provenance is verified by SHA-256 before execution.
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:wasd/wasi.dart';
import 'package:wasd/wasm.dart';

const _fixturePath =
    'test/fixtures/wasi_preview2/'
    'wasi_http_0_2_12_static_response.component.wasm';
const _fixtureSha256 =
    '94bd7c8d6a10cca265f7237868135b37c7e76b9b12967d863fe988ad880f07a8';
const _fullProxyPrefix =
    'test/fixtures/wasi_preview2/wasi_http_0_2_12_full_proxy.component';
const _fullProxyArtifacts = <String, String>{
  '$_fullProxyPrefix.wat':
      'ae390f3449eb7c81b2085df86d80911f5ccfcd8c374abad44eb83d190410450a',
  '$_fullProxyPrefix.wasm':
      '227ab950a4e352907743d387fb7f6f864dc8d32eafa7f5319e6f377c3a879ec0',
};
const _fullProxyImports = <String>[
  'wasi:io/poll@0.2.12',
  'wasi:clocks/monotonic-clock@0.2.12',
  'wasi:clocks/wall-clock@0.2.12',
  'wasi:random/random@0.2.12',
  'wasi:io/error@0.2.12',
  'wasi:io/streams@0.2.12',
  'wasi:cli/stdout@0.2.12',
  'wasi:cli/stderr@0.2.12',
  'wasi:cli/stdin@0.2.12',
  'wasi:http/types@0.2.12',
  'wasi:http/outgoing-handler@0.2.12',
];

void main() {
  group('WASI HTTP incoming request lifecycle', () {
    test('dropping an unconsumed request drops its body', () {
      var bodyDrops = 0;
      final host = WASIPreview2ComponentHost();
      final request = host.httpHost.insertIncomingRequest(
        WASIPreview2HttpIncomingRequest(
          method: const WASIPreview2HttpMethod.standard('post'),
          headers: WASIPreview2HttpFields(),
          body: WASIPreview2HttpIncomingBody(
            WASIPreview2InputStream(),
            onDrop: () => bodyDrops++,
          ),
        ),
      );

      host.componentHost.table.dropNamed(
        'wasi:http/types@0.2.0.incoming-request',
        request,
      );

      expect(bodyDrops, 1);
    });

    test('a consumed body outlives its request', () {
      var bodyDrops = 0;
      final host = WASIPreview2ComponentHost();
      final request = host.httpHost.insertIncomingRequest(
        WASIPreview2HttpIncomingRequest(
          method: const WASIPreview2HttpMethod.standard('post'),
          headers: WASIPreview2HttpFields(),
          body: WASIPreview2HttpIncomingBody(
            WASIPreview2InputStream(),
            onDrop: () => bodyDrops++,
          ),
        ),
      );
      final consume = host
          .httpHost
          .imports['wasi:http/types@0.2.0.incoming-request.consume']!;
      final result = consume([request]) as WasmComponentValueData;
      final body = result.associatedValue!.integer! as int;

      host.componentHost.table.dropNamed(
        'wasi:http/types@0.2.0.incoming-request',
        request,
      );
      expect(bodyDrops, 0);

      host.componentHost.table.dropNamed(
        'wasi:http/types@0.2.0.incoming-body',
        body,
      );
      expect(bodyDrops, 1);
    });
  });

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

  group('WASI HTTP 0.2.12 complete proxy component', () {
    test('fixture retains all imports and handler type exports', () async {
      for (final artifact in _fullProxyArtifacts.entries) {
        final bytes = await File(artifact.key).readAsBytes();
        expect(
          sha256.convert(bytes).toString(),
          artifact.value,
          reason: artifact.key,
        );
      }
      final component = WasmComponent.decode(
        await File('$_fullProxyPrefix.wasm').readAsBytes(),
      );
      expect(component.validate(), isEmpty);
      expect(
        component.imports.map((item) => item.name),
        unorderedEquals(_fullProxyImports),
      );
      expect(
        component.imports.map((item) => item.descriptor.kind),
        everyElement(WasmComponentExternKind.instance),
      );
      expect(component.exports.map((item) => item.name), [
        'wasi:http/incoming-handler@0.2.12',
      ]);

      // Follow the actual exported instance to its type/function shim.
      final handler = component.exports.single;
      expect(handler.sort.kind, WasmComponentSortKind.instance);
      final importedInstances = component.imports
          .where(
            (item) => item.descriptor.kind == WasmComponentExternKind.instance,
          )
          .length;
      final instance =
          component.instances[handler.sort.index - importedInstances];
      expect(instance.kind, WasmComponentInstanceKind.instantiate);
      final shim = component.components[instance.componentIndex!];
      expect(
        shim.exports.map((item) => (item.name, item.sort.kind)),
        unorderedEquals([
          ('incoming-request', WasmComponentSortKind.componentType),
          ('response-outparam', WasmComponentSortKind.componentType),
          ('handle', WasmComponentSortKind.function),
        ]),
      );
    });

    test('sets a response and releases owned request resources', () async {
      final component = WasmComponent.decode(
        await File('$_fullProxyPrefix.wasm').readAsBytes(),
      );
      final host = WASIPreview2ComponentHost();
      final baseline = host.componentHost.table.activeCount;
      var bodyDrops = 0;
      final request = WASIPreview2HttpIncomingRequest(
        method: const WASIPreview2HttpMethod.standard('get'),
        headers: WASIPreview2HttpFields(),
        pathWithQuery: '/',
        scheme: const WASIPreview2HttpScheme.standard('HTTP'),
        authority: 'example.test',
        body: WASIPreview2HttpIncomingBody(
          WASIPreview2InputStream(bytes: const [1, 2, 3], closed: true),
          onDrop: () => bodyDrops++,
        ),
      );

      final outparam = await WASIPreview2ProxyRunner(
        host,
      ).handle(component, request);

      expect(outparam.informationalResponses, isEmpty);
      expect(outparam.response, isNotNull);
      expect(outparam.response!.isOk, isTrue);
      expect(outparam.response!.errorCode, isNull);
      final response = outparam.response!.value!;
      expect(response.statusCode, 200);
      expect(response.headers.entries, isEmpty);
      expect(response.bodyResource, isNull);
      expect(bodyDrops, 1);
      expect(host.componentHost.table.activeCount, baseline);
    });
  });
}
