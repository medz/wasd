import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import '../../../wasm/backend/native/interpreter/component.dart';
import '../../component/async_values.dart';
import '../../component/resource_table.dart';
import '../http.dart';
import '../http_error_codes.dart';

/// Dart VM-backed WASI 0.3 HTTP host.
final class WASIPreview3NativeHttpHost extends WASIPreview3HttpHost {
  /// Creates a native HTTP client host.
  factory WASIPreview3NativeHttpHost({
    WASIComponentResourceTable? table,
    WASIPreview3HttpBackend? handlerBackend,
    io.HttpClient? client,
  }) {
    final resolvedClient = client ?? io.HttpClient();
    return WASIPreview3NativeHttpHost._(
      table: table,
      handlerBackend: handlerBackend,
      client: resolvedClient,
      ownedClient: client == null ? resolvedClient : null,
    );
  }

  WASIPreview3NativeHttpHost._({
    super.table,
    super.handlerBackend,
    required io.HttpClient client,
    required io.HttpClient? ownedClient,
  }) : _ownedClient = ownedClient,
       super(
         clientBackend: WASIPreview3NativeHttpBackend(client),
         maximumRequestTimeoutNanos:
             BigInt.from(_maxDurationMicroseconds) * BigInt.from(1000),
       );

  io.HttpClient? _ownedClient;

  /// Closes the HTTP client created by this host, if any.
  @override
  void close({bool force = false}) {
    final client = _ownedClient;
    _ownedClient = null;
    client?.close(force: force);
  }
}

/// Preview3 HTTP client backend implemented with `dart:io`.
final class WASIPreview3NativeHttpBackend implements WASIPreview3HttpBackend {
  /// Creates a backend over a configured [client].
  WASIPreview3NativeHttpBackend(io.HttpClient client)
    : _client = _configureHttpClient(client);

  final io.HttpClient _client;

  @override
  Future<WASIPreview3HttpResult<WASIPreview3HttpResponse>> handle(
    WASIPreview3HttpRequest request,
  ) async {
    if (!_timeoutsSupported(request.options)) {
      return _fail(request, 'configuration-error');
    }
    final uri = _uriForRequest(request);
    if (uri == null) {
      return _fail(request, 'HTTP-request-URI-invalid');
    }
    return _send(request, uri);
  }

  Future<WASIPreview3HttpResult<WASIPreview3HttpResponse>> _send(
    WASIPreview3HttpRequest request,
    Uri uri,
  ) async {
    final exchange = _NativeHttpExchange();
    io.HttpClientRequest? ioRequest;
    try {
      final pendingOpen = _client.openUrl(request.method.wireName, uri);
      exchange.watchPendingRequest(pendingOpen);
      var open = pendingOpen;
      final connectTimeout = _durationFromNanos(
        request.options?.connectTimeout,
      );
      if (connectTimeout != null) {
        var timedOut = false;
        open = pendingOpen.timeout(
          connectTimeout,
          onTimeout: () {
            timedOut = true;
            throw TimeoutException('connect-timeout');
          },
        );
        unawaited(
          pendingOpen.then<void>((lateRequest) {
            if (timedOut) {
              exchange.abortRequest(
                lateRequest,
                TimeoutException('connect-timeout'),
              );
            }
          }, onError: (Object _, StackTrace _) {}),
        );
      }
      ioRequest = await open;
      if (!exchange.attachRequest(ioRequest)) {
        return _fail(request, 'internal-error');
      }
      ioRequest.followRedirects = false;
      for (final entry in request.headers.entries) {
        ioRequest.headers.add(entry.name, String.fromCharCodes(entry.value));
      }
      final bodyResult = await _writeRequestBody(ioRequest, request);
      if (!bodyResult.isOk) {
        exchange.abortRequest(
          ioRequest,
          io.HttpException(bodyResult.errorCode!),
        );
        exchange.cancel();
        return _fail(request, bodyResult.errorCode!);
      }
      final firstByteTimeout = _durationFromNanos(
        request.options?.firstByteTimeout,
      );
      final firstByteStopwatch = firstByteTimeout == null
          ? null
          : (Stopwatch()..start());
      var pendingResponse = ioRequest.close();
      if (firstByteTimeout != null) {
        pendingResponse = pendingResponse.timeout(
          firstByteTimeout,
          onTimeout: () => throw const _FirstByteTimeout(),
        );
      }
      final ioResponse = await pendingResponse;
      exchange.detachRequest(ioRequest);
      ioRequest = null;
      if (exchange.isCancelled) {
        return _fail(request, 'internal-error');
      }
      request.completeTransmission(const WASIPreview3HttpResult<void>.ok(null));

      final body = WASIComponentStream<int>(
        'http-response-body',
        maxBufferedElements: _responseBodyBufferSize,
        onDrop: exchange.cancel,
        onReadableDrop: exchange.cancel,
      );
      final trailers = WASIComponentFuture<WasmComponentValueData>(
        'http-response-trailers',
        onDrop: exchange.cancel,
      );
      final remainingFirstByteTimeout = firstByteTimeout == null
          ? null
          : _remaining(firstByteTimeout, firstByteStopwatch!.elapsed);
      unawaited(
        _pipeResponseBody(
          ioResponse,
          body,
          trailers,
          exchange,
          firstByteTimeout: remainingFirstByteTimeout,
          betweenBytesTimeout: _durationFromNanos(
            request.options?.betweenBytesTimeout,
          ),
        ),
      );
      final response = WASIPreview3HttpResponse(
        headers: WASIPreview3HttpFields(
          entries: _responseHeaders(ioResponse.headers),
          mutable: false,
        ),
        contents: body,
        trailers: trailers,
        onDrop: exchange.cancel,
      )..statusCode = ioResponse.statusCode;
      return WASIPreview3HttpResult<WASIPreview3HttpResponse>.ok(response);
    } on _FirstByteTimeout catch (error, stackTrace) {
      exchange.abortRequest(ioRequest, error, stackTrace);
      exchange.cancel();
      return _fail(request, 'HTTP-response-timeout');
    } on TimeoutException catch (error, stackTrace) {
      exchange.abortRequest(ioRequest, error, stackTrace);
      exchange.cancel();
      return _fail(request, 'connection-timeout');
    } on io.HandshakeException catch (error, stackTrace) {
      exchange.abortRequest(ioRequest, error, stackTrace);
      exchange.cancel();
      return _fail(request, 'TLS-protocol-error');
    } on io.SocketException catch (error, stackTrace) {
      exchange.abortRequest(ioRequest, error, stackTrace);
      exchange.cancel();
      return _fail(request, _socketHttpErrorCode(error));
    } on io.HttpException catch (error, stackTrace) {
      exchange.abortRequest(ioRequest, error, stackTrace);
      exchange.cancel();
      return _fail(request, 'HTTP-protocol-error');
    } on Object catch (error, stackTrace) {
      exchange.abortRequest(ioRequest, error, stackTrace);
      exchange.cancel();
      return _fail(request, 'internal-error');
    }
  }
}

io.HttpClient _configureHttpClient(io.HttpClient client) {
  client.autoUncompress = false;
  client.userAgent = null;
  return client;
}

WASIPreview3HttpResult<WASIPreview3HttpResponse> _fail(
  WASIPreview3HttpRequest request,
  String error,
) {
  request.completeTransmission(WASIPreview3HttpResult<void>.error(error));
  request.cancel();
  return WASIPreview3HttpResult<WASIPreview3HttpResponse>.error(error);
}

Future<WASIPreview3HttpResult<void>> _writeRequestBody(
  io.HttpClientRequest request,
  WASIPreview3HttpRequest wasiRequest,
) async {
  try {
    final body = wasiRequest.contents;
    if (body != null) {
      while (true) {
        final chunk = await body.readable.readWhenAvailable(8192);
        if (chunk.isEmpty) {
          break;
        }
        request.add(chunk);
      }
    }
    final trailers = await wasiRequest.readTrailers();
    if (!trailers.isOk) {
      return WASIPreview3HttpResult<void>.error(trailers.errorCode!);
    }
    if (trailers.value != null) {
      return const WASIPreview3HttpResult<void>.error('HTTP-protocol-error');
    }
    return const WASIPreview3HttpResult<void>.ok(null);
  } on Object {
    return const WASIPreview3HttpResult<void>.error('internal-error');
  }
}

Future<void> _pipeResponseBody(
  io.HttpClientResponse response,
  WASIComponentStream<int> body,
  WASIComponentFuture<WasmComponentValueData> trailers,
  _NativeHttpExchange exchange, {
  required Duration? firstByteTimeout,
  required Duration? betweenBytesTimeout,
}) async {
  final iterator = StreamIterator<List<int>>(response);
  if (!exchange.attachResponse(iterator)) {
    body.writable.close();
    _completeTrailers(trailers, 'internal-error');
    return;
  }
  var first = true;
  try {
    while (true) {
      final timeout = first ? firstByteTimeout : betweenBytesTimeout;
      final hasNext = timeout == null
          ? await iterator.moveNext()
          : await iterator.moveNext().timeout(
              timeout,
              onTimeout: () => throw const _ResponseBodyTimeout(),
            );
      if (!hasNext) {
        break;
      }
      first = false;
      await _writeWithBackpressure(body, iterator.current);
    }
    exchange.detachResponse(iterator);
    body.writable.close();
    _completeTrailers(
      trailers,
      _responseDeclaresTrailers(response) ? 'HTTP-protocol-error' : null,
    );
  } on _ResponseBodyTimeout {
    exchange.detachResponse(iterator);
    await iterator.cancel();
    body.writable.close();
    _completeTrailers(trailers, 'HTTP-response-timeout');
  } on io.SocketException catch (error) {
    exchange.detachResponse(iterator);
    await iterator.cancel();
    body.writable.close();
    _completeTrailers(trailers, _socketHttpErrorCode(error));
  } on io.HttpException {
    exchange.detachResponse(iterator);
    await iterator.cancel();
    body.writable.close();
    _completeTrailers(trailers, 'HTTP-protocol-error');
  } on Object {
    exchange.detachResponse(iterator);
    await iterator.cancel();
    body.writable.close();
    _completeTrailers(trailers, 'internal-error');
  }
}

Future<void> _writeWithBackpressure(
  WASIComponentStream<int> stream,
  List<int> bytes,
) async {
  var offset = 0;
  while (offset < bytes.length) {
    final written = await stream.writable.writeWhenAvailable(
      bytes.getRange(offset, bytes.length),
    );
    if (written <= 0) {
      throw StateError('WASI HTTP response body made no write progress.');
    }
    offset += written;
  }
}

void _completeTrailers(
  WASIComponentFuture<WasmComponentValueData> trailers,
  String? error,
) {
  if (!trailers.writable.canComplete) {
    return;
  }
  trailers.writable.complete(
    error == null ? _noTrailersResult() : _httpErrorResult(error),
  );
}

WasmComponentValueData _noTrailersResult() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'ok',
    isOk: true,
    associatedValue: WasmComponentValueData(
      kind: WasmComponentValueDataKind.option,
      rawBytes: Uint8List(0),
      index: 0,
      label: 'none',
      isSome: false,
    ),
  );
}

WasmComponentValueData _httpErrorResult(String code) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'error',
    isOk: false,
    associatedValue: _httpErrorCode(code),
  );
}

WasmComponentValueData _httpErrorCode(String code) {
  var index = wasiPreview3HttpErrorCodeCases.indexOf(code);
  if (index < 0) {
    index = wasiPreview3HttpErrorCodeCases.indexOf('internal-error');
  }
  final label = wasiPreview3HttpErrorCodeCases[index];
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.variant,
    rawBytes: Uint8List(0),
    index: index,
    label: label,
    associatedValue: label == 'internal-error'
        ? WasmComponentValueData(
            kind: WasmComponentValueDataKind.option,
            rawBytes: Uint8List(0),
            index: 0,
            label: 'none',
            isSome: false,
          )
        : null,
  );
}

final class _NativeHttpExchange {
  io.HttpClientRequest? _request;
  io.HttpClientRequest? _abortedRequest;
  StreamIterator<List<int>>? _response;
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void watchPendingRequest(Future<io.HttpClientRequest> pending) {
    unawaited(
      pending.then<void>((request) {
        if (_cancelled) {
          abortRequest(
            request,
            StateError('WASI HTTP exchange was abandoned.'),
          );
        }
      }, onError: (Object _, StackTrace _) {}),
    );
  }

  bool attachRequest(io.HttpClientRequest request) {
    if (_cancelled) {
      abortRequest(request, StateError('WASI HTTP exchange was abandoned.'));
      return false;
    }
    _request = request;
    return true;
  }

  void detachRequest(io.HttpClientRequest request) {
    if (identical(_request, request)) {
      _request = null;
    }
  }

  bool attachResponse(StreamIterator<List<int>> response) {
    if (_cancelled) {
      unawaited(response.cancel());
      return false;
    }
    _response = response;
    return true;
  }

  void detachResponse(StreamIterator<List<int>> response) {
    if (identical(_response, response)) {
      _response = null;
    }
  }

  void abortRequest(
    io.HttpClientRequest? request,
    Object error, [
    StackTrace? stackTrace,
  ]) {
    if (request == null || identical(_abortedRequest, request)) {
      return;
    }
    if (identical(_request, request)) {
      _request = null;
    }
    _abortedRequest = request;
    try {
      request.abort(error, stackTrace);
    } on Object {
      // Preserve the original transport failure.
    }
  }

  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    abortRequest(_request, StateError('WASI HTTP exchange was abandoned.'));
    final response = _response;
    _response = null;
    if (response != null) {
      unawaited(response.cancel());
    }
  }
}

final class _FirstByteTimeout implements Exception {
  const _FirstByteTimeout();
}

final class _ResponseBodyTimeout implements Exception {
  const _ResponseBodyTimeout();
}

Uri? _uriForRequest(WASIPreview3HttpRequest request) {
  final scheme = request.scheme?.wireName.toLowerCase() ?? 'http';
  if (scheme != 'http' && scheme != 'https') {
    return null;
  }
  final authority = request.authority;
  if (authority == null || authority.isEmpty) {
    return null;
  }
  final path = request.pathWithQuery;
  final normalizedPath = path == null || path.isEmpty
      ? '/'
      : path.startsWith('/')
      ? path
      : '/$path';
  return Uri.tryParse('$scheme://$authority$normalizedPath');
}

List<WASIPreview3HttpFieldEntry> _responseHeaders(io.HttpHeaders headers) {
  final entries = <WASIPreview3HttpFieldEntry>[];
  headers.forEach((name, values) {
    for (final value in values) {
      entries.add(WASIPreview3HttpFieldEntry(name, value.codeUnits));
    }
  });
  return entries;
}

bool _responseDeclaresTrailers(io.HttpClientResponse response) {
  final declaration = response.headers[io.HttpHeaders.trailerHeader];
  return declaration != null && declaration.isNotEmpty;
}

Duration _remaining(Duration timeout, Duration elapsed) {
  final remaining = timeout - elapsed;
  return remaining.isNegative ? Duration.zero : remaining;
}

Duration? _durationFromNanos(BigInt? nanos) {
  if (nanos == null) {
    return null;
  }
  if (nanos <= BigInt.zero) {
    return Duration.zero;
  }
  final micros = (nanos + BigInt.from(999)) ~/ BigInt.from(1000);
  return Duration(microseconds: micros.toInt());
}

bool _timeoutsSupported(WASIPreview3HttpRequestOptions? options) {
  if (options == null) {
    return true;
  }
  final maximum = BigInt.from(_maxDurationMicroseconds) * BigInt.from(1000);
  return <BigInt?>[
    options.connectTimeout,
    options.firstByteTimeout,
    options.betweenBytesTimeout,
  ].every((timeout) => timeout == null || timeout <= maximum);
}

String _socketHttpErrorCode(io.SocketException error) {
  final errorCode = error.osError?.errorCode;
  if (errorCode != null) {
    if (errorCode == _platformConnectionRefusedErrorCode) {
      return 'connection-refused';
    }
    if (errorCode == _platformConnectionTimeoutErrorCode) {
      return 'connection-timeout';
    }
    if (error.address == null && _isDnsErrorCode(errorCode)) {
      return 'DNS-error';
    }
  }

  final message = error.message.toLowerCase();
  if (message.contains('refused')) {
    return 'connection-refused';
  }
  if (message.contains('lookup') ||
      message.contains('nodename') ||
      message.contains('name resolution') ||
      message.contains('host not found') ||
      message.contains('no address associated')) {
    return 'DNS-error';
  }
  if (message.contains('timed out')) {
    return 'connection-timeout';
  }
  return 'destination-unavailable';
}

const int _maxDurationMicroseconds = 86400000000;
const int _responseBodyBufferSize = 64 * 1024;
const Set<int> _linuxDnsErrorCodes = <int>{
  -11,
  -10,
  -8,
  -7,
  -6,
  -5,
  -4,
  -3,
  -2,
};
const Set<int> _darwinDnsErrorCodes = <int>{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11};
const Set<int> _windowsDnsErrorCodes = <int>{11001, 11002, 11003, 11004};

int get _platformConnectionRefusedErrorCode => io.Platform.isWindows
    ? 10061
    : io.Platform.isMacOS || io.Platform.isIOS
    ? 61
    : 111;

int get _platformConnectionTimeoutErrorCode => io.Platform.isWindows
    ? 10060
    : io.Platform.isMacOS || io.Platform.isIOS
    ? 60
    : 110;

bool _isDnsErrorCode(int errorCode) {
  if (io.Platform.isWindows) {
    return _windowsDnsErrorCodes.contains(errorCode);
  }
  if (io.Platform.isMacOS || io.Platform.isIOS) {
    return _darwinDnsErrorCodes.contains(errorCode);
  }
  return _linuxDnsErrorCodes.contains(errorCode);
}
