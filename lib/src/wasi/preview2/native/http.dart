import 'dart:async';
import 'dart:io' as io;

import '../http.dart';
import '../io.dart';

/// Preview2 HTTP host backed by `dart:io`.
final class WASIPreview2NativeHttpHost extends WASIPreview2HttpHost {
  /// Creates a native HTTP host.
  WASIPreview2NativeHttpHost({
    super.table,
    super.pollHost,
    super.streamsHost,
    io.HttpClient? client,
  }) : super(
         backend: _NativeHttpBackend(
           _configureHttpClient(client ?? io.HttpClient()),
         ),
         maximumRequestTimeoutNanos:
             BigInt.from(_maxDurationMicroseconds) * BigInt.from(1000),
       );
}

io.HttpClient _configureHttpClient(io.HttpClient client) {
  client.autoUncompress = false;
  client.userAgent = null;
  return client;
}

final class _NativeHttpBackend implements WASIPreview2HttpBackend {
  _NativeHttpBackend(this._client);

  final io.HttpClient _client;

  @override
  WASIPreview2HttpResult<WASIPreview2HttpFutureIncomingResponse> handle(
    WASIPreview2HttpOutgoingRequest request,
    WASIPreview2HttpRequestOptions? options,
  ) {
    if (!_timeoutsSupported(options)) {
      return const WASIPreview2HttpResult<
        WASIPreview2HttpFutureIncomingResponse
      >.error('configuration-error');
    }
    final uri = _uriForRequest(request);
    if (uri == null) {
      return const WASIPreview2HttpResult<
        WASIPreview2HttpFutureIncomingResponse
      >.error('HTTP-request-URI-invalid');
    }
    final body = request.bodyResource;
    body?.rejectTrailersWith(_trailersUnsupportedError);
    if (body != null && body.isFinished && body.trailers != null) {
      return const WASIPreview2HttpResult<
        WASIPreview2HttpFutureIncomingResponse
      >.error(_trailersUnsupportedError);
    }
    return WASIPreview2HttpResult<WASIPreview2HttpFutureIncomingResponse>.ok(
      WASIPreview2HttpFutureIncomingResponse(_send(request, uri, options)),
    );
  }

  Future<WASIPreview2HttpResult<WASIPreview2HttpIncomingResponse>> _send(
    WASIPreview2HttpOutgoingRequest request,
    Uri uri,
    WASIPreview2HttpRequestOptions? options,
  ) async {
    io.HttpClientRequest? ioRequest;
    try {
      final method = request.method.wireName;
      final pendingOpen = _client.openUrl(method, uri);
      var open = pendingOpen;
      final connectTimeout = _durationFromNanos(options?.connectTimeout);
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
              _abortRequest(lateRequest, TimeoutException('connect-timeout'));
            }
          }, onError: (Object _, StackTrace _) {}),
        );
      }
      ioRequest = await open;
      ioRequest.followRedirects = false;
      for (final entry in request.headers.entries) {
        ioRequest.headers.add(entry.name, String.fromCharCodes(entry.value));
      }
      final bodyResult = await _writeRequestBody(
        ioRequest,
        request.bodyResource,
      );
      if (!bodyResult.isOk) {
        _abortRequest(ioRequest, io.HttpException(bodyResult.errorCode!));
        return WASIPreview2HttpResult<WASIPreview2HttpIncomingResponse>.error(
          bodyResult.errorCode!,
        );
      }
      final ioResponse = await ioRequest.close();
      ioRequest = null;
      final input = WASIPreview2InputStream();
      _pipeResponseBody(ioResponse, input, options);
      final trailers = _responseTrailers(ioResponse);
      return WASIPreview2HttpResult<WASIPreview2HttpIncomingResponse>.ok(
        WASIPreview2HttpIncomingResponse(
          status: ioResponse.statusCode,
          headers: WASIPreview2HttpFields(
            entries: _responseHeaders(ioResponse.headers),
            mutable: false,
          ),
          body: WASIPreview2HttpIncomingBody(input, trailers: trailers),
        ),
      );
    } on TimeoutException catch (error, stackTrace) {
      _abortRequest(ioRequest, error, stackTrace);
      return const WASIPreview2HttpResult<
        WASIPreview2HttpIncomingResponse
      >.error('connection-timeout');
    } on io.SocketException catch (error, stackTrace) {
      _abortRequest(ioRequest, error, stackTrace);
      return WASIPreview2HttpResult<WASIPreview2HttpIncomingResponse>.error(
        _socketHttpErrorCode(error),
      );
    } on io.HttpException catch (error, stackTrace) {
      _abortRequest(ioRequest, error, stackTrace);
      return const WASIPreview2HttpResult<
        WASIPreview2HttpIncomingResponse
      >.error('HTTP-protocol-error');
    } on Object catch (error, stackTrace) {
      _abortRequest(ioRequest, error, stackTrace);
      return const WASIPreview2HttpResult<
        WASIPreview2HttpIncomingResponse
      >.error('internal-error');
    }
  }
}

void _abortRequest(
  io.HttpClientRequest? request,
  Object error, [
  StackTrace? stackTrace,
]) {
  if (request == null) {
    return;
  }
  try {
    request.abort(error, stackTrace);
  } on Object {
    // Preserve the original WASI HTTP error when abort itself fails.
  }
}

Future<WASIPreview2HttpResult<void>> _writeRequestBody(
  io.HttpClientRequest request,
  WASIPreview2HttpOutgoingBody? body,
) async {
  if (body == null) {
    return const WASIPreview2HttpResult<void>.ok(null);
  }
  try {
    await for (final chunk in body.chunks) {
      if (chunk.isNotEmpty) {
        request.add(chunk);
      }
    }
    final result = await body.done;
    if (!result.isOk) {
      return result;
    }
    if (body.trailers != null) {
      return const WASIPreview2HttpResult<void>.error(
        _trailersUnsupportedError,
      );
    }
    return result;
  } on Object {
    return const WASIPreview2HttpResult<void>.error('internal-error');
  }
}

void _pipeResponseBody(
  io.HttpClientResponse response,
  WASIPreview2InputStream input,
  WASIPreview2HttpRequestOptions? options,
) {
  final firstByteTimeout = _durationFromNanos(options?.firstByteTimeout);
  final betweenBytesTimeout = _durationFromNanos(options?.betweenBytesTimeout);
  Timer? timeout;
  var failed = false;
  late final StreamSubscription<List<int>> subscription;

  void cancelTimeout() {
    timeout?.cancel();
    timeout = null;
  }

  void failTimeout() {
    failed = true;
    cancelTimeout();
    input.fail('HTTP-response-timeout');
    unawaited(subscription.cancel());
  }

  void armTimeout(Duration duration) {
    cancelTimeout();
    timeout = Timer(duration, failTimeout);
  }

  subscription = response.listen(
    (chunk) {
      if (failed) {
        return;
      }
      cancelTimeout();
      input.append(chunk);
      if (betweenBytesTimeout != null) {
        armTimeout(betweenBytesTimeout);
      }
    },
    onError: (Object error, StackTrace stackTrace) {
      if (failed) {
        return;
      }
      failed = true;
      cancelTimeout();
      input.fail(_responseBodyError(error));
    },
    onDone: () {
      if (failed) {
        return;
      }
      cancelTimeout();
      input.close();
    },
    cancelOnError: true,
  );

  if (firstByteTimeout != null) {
    armTimeout(firstByteTimeout);
  }
}

WASIPreview2HttpFutureTrailers? _responseTrailers(
  io.HttpClientResponse response,
) {
  final declaration = response.headers[io.HttpHeaders.trailerHeader];
  if (declaration == null || declaration.isEmpty) {
    return null;
  }
  return WASIPreview2HttpFutureTrailers.completed(
    const WASIPreview2HttpResult<WASIPreview2HttpFields?>.error(
      _trailersUnsupportedError,
    ),
  );
}

String _responseBodyError(Object error) {
  if (error is io.HttpException) {
    return _httpProtocolError;
  }
  if (error is io.SocketException) {
    return _socketHttpErrorCode(error);
  }
  return 'internal-error';
}

Uri? _uriForRequest(WASIPreview2HttpOutgoingRequest request) {
  final scheme = request.scheme?.wireName ?? 'http';
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

List<WASIPreview2HttpFieldEntry> _responseHeaders(io.HttpHeaders headers) {
  final entries = <WASIPreview2HttpFieldEntry>[];
  headers.forEach((name, values) {
    for (final value in values) {
      entries.add(WASIPreview2HttpFieldEntry(name, value.codeUnits));
    }
  });
  return entries;
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

bool _timeoutsSupported(WASIPreview2HttpRequestOptions? options) {
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
  final message = error.message.toLowerCase();
  if (message.contains('refused')) {
    return 'connection-refused';
  }
  if (message.contains('lookup') ||
      message.contains('nodename') ||
      message.contains('name')) {
    return 'DNS-error';
  }
  if (message.contains('timed out')) {
    return 'connection-timeout';
  }
  return 'destination-unavailable';
}

const int _maxDurationMicroseconds = 86400000000;
const String _httpProtocolError = 'HTTP-protocol-error';
const String _trailersUnsupportedError = _httpProtocolError;
