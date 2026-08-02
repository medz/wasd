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
    final exchange = _NativeHttpExchange();
    return WASIPreview2HttpResult<WASIPreview2HttpFutureIncomingResponse>.ok(
      WASIPreview2HttpFutureIncomingResponse(
        _send(request, uri, options, exchange),
        onDrop: exchange.cancel,
      ),
    );
  }

  Future<WASIPreview2HttpResult<WASIPreview2HttpIncomingResponse>> _send(
    WASIPreview2HttpOutgoingRequest request,
    Uri uri,
    WASIPreview2HttpRequestOptions? options,
    _NativeHttpExchange exchange,
  ) async {
    io.HttpClientRequest? ioRequest;
    try {
      final method = request.method.wireName;
      final pendingOpen = _client.openUrl(method, uri);
      exchange.watchPendingRequest(pendingOpen);
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
        return const WASIPreview2HttpResult<
          WASIPreview2HttpIncomingResponse
        >.error('internal-error');
      }
      ioRequest.followRedirects = false;
      for (final entry in request.headers.entries) {
        ioRequest.headers.add(entry.name, String.fromCharCodes(entry.value));
      }
      final bodyResult = await _writeRequestBody(
        ioRequest,
        request.bodyResource,
      );
      if (!bodyResult.isOk) {
        exchange.abortRequest(
          ioRequest,
          io.HttpException(bodyResult.errorCode!),
        );
        return WASIPreview2HttpResult<WASIPreview2HttpIncomingResponse>.error(
          bodyResult.errorCode!,
        );
      }
      final ioResponse = await ioRequest.close();
      exchange.detachRequest(ioRequest);
      ioRequest = null;
      if (exchange.isCancelled) {
        return const WASIPreview2HttpResult<
          WASIPreview2HttpIncomingResponse
        >.error('internal-error');
      }
      final input = WASIPreview2InputStream();
      exchange.pipeResponseBody(ioResponse, input, options);
      final trailers = _responseTrailers(ioResponse);
      return WASIPreview2HttpResult<WASIPreview2HttpIncomingResponse>.ok(
        WASIPreview2HttpIncomingResponse(
          status: ioResponse.statusCode,
          headers: WASIPreview2HttpFields(
            entries: _responseHeaders(ioResponse.headers),
            mutable: false,
          ),
          body: WASIPreview2HttpIncomingBody(
            input,
            trailers: trailers,
            onDrop: exchange.cancel,
          ),
        ),
      );
    } on TimeoutException catch (error, stackTrace) {
      exchange.abortRequest(ioRequest, error, stackTrace);
      exchange.cancel();
      return const WASIPreview2HttpResult<
        WASIPreview2HttpIncomingResponse
      >.error('connection-timeout');
    } on io.SocketException catch (error, stackTrace) {
      exchange.abortRequest(ioRequest, error, stackTrace);
      exchange.cancel();
      return WASIPreview2HttpResult<WASIPreview2HttpIncomingResponse>.error(
        _socketHttpErrorCode(error),
      );
    } on io.HttpException catch (error, stackTrace) {
      exchange.abortRequest(ioRequest, error, stackTrace);
      exchange.cancel();
      return const WASIPreview2HttpResult<
        WASIPreview2HttpIncomingResponse
      >.error('HTTP-protocol-error');
    } on Object catch (error, stackTrace) {
      exchange.abortRequest(ioRequest, error, stackTrace);
      exchange.cancel();
      return const WASIPreview2HttpResult<
        WASIPreview2HttpIncomingResponse
      >.error('internal-error');
    }
  }
}

final class _NativeHttpExchange {
  io.HttpClientRequest? _request;
  io.HttpClientRequest? _abortedRequest;
  StreamSubscription<List<int>>? _responseSubscription;
  WASIPreview2InputStream? _responseInput;
  Timer? _responseTimeout;
  bool _cancelled = false;
  bool _responseDone = false;

  bool get isCancelled => _cancelled;

  void watchPendingRequest(Future<io.HttpClientRequest> request) {
    unawaited(
      request.then<void>((lateRequest) {
        if (_cancelled) {
          abortRequest(
            lateRequest,
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
    _abortRequest(request, error, stackTrace);
  }

  void pipeResponseBody(
    io.HttpClientResponse response,
    WASIPreview2InputStream input,
    WASIPreview2HttpRequestOptions? options,
  ) {
    final firstByteTimeout = _durationFromNanos(options?.firstByteTimeout);
    final betweenBytesTimeout = _durationFromNanos(
      options?.betweenBytesTimeout,
    );
    _responseInput = input;
    final subscription = response.listen(
      (chunk) {
        if (_cancelled || _responseDone) {
          return;
        }
        _cancelResponseTimeout();
        input.append(chunk);
        if (betweenBytesTimeout != null) {
          _armResponseTimeout(betweenBytesTimeout);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (_cancelled || _responseDone) {
          return;
        }
        _responseDone = true;
        _cancelResponseTimeout();
        _responseInput = null;
        _responseSubscription = null;
        input.fail(_responseBodyError(error));
      },
      onDone: () {
        if (_cancelled || _responseDone) {
          return;
        }
        _responseDone = true;
        _cancelResponseTimeout();
        _responseInput = null;
        _responseSubscription = null;
        input.close();
      },
      cancelOnError: true,
    );
    if (_responseDone) {
      return;
    }
    _responseSubscription = subscription;
    if (_cancelled) {
      _stopResponse('internal-error');
    } else if (firstByteTimeout != null) {
      _armResponseTimeout(firstByteTimeout);
    }
  }

  void cancel() {
    if (_cancelled || _responseDone) {
      return;
    }
    _cancelled = true;
    abortRequest(_request, StateError('WASI HTTP exchange was abandoned.'));
    _stopResponse('internal-error');
  }

  void _armResponseTimeout(Duration duration) {
    _cancelResponseTimeout();
    _responseTimeout = Timer(duration, () {
      if (_cancelled || _responseDone) {
        return;
      }
      _responseDone = true;
      _stopResponse('HTTP-response-timeout');
    });
  }

  void _cancelResponseTimeout() {
    _responseTimeout?.cancel();
    _responseTimeout = null;
  }

  void _stopResponse(String error) {
    _cancelResponseTimeout();
    final input = _responseInput;
    _responseInput = null;
    input?.fail(error);
    final subscription = _responseSubscription;
    _responseSubscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel());
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
