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
  }) : super(backend: _NativeHttpBackend(client ?? io.HttpClient()));
}

final class _NativeHttpBackend implements WASIPreview2HttpBackend {
  _NativeHttpBackend(this._client);

  final io.HttpClient _client;

  @override
  WASIPreview2HttpResult<WASIPreview2HttpFutureIncomingResponse> handle(
    WASIPreview2HttpOutgoingRequest request,
    WASIPreview2HttpRequestOptions? options,
  ) {
    final uri = _uriForRequest(request);
    if (uri == null) {
      return const WASIPreview2HttpResult<
        WASIPreview2HttpFutureIncomingResponse
      >.error('HTTP-request-URI-invalid');
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
    try {
      final method = request.method.wireName;
      var open = _client.openUrl(method, uri);
      final connectTimeout = _durationFromNanos(options?.connectTimeout);
      if (connectTimeout != null) {
        open = open.timeout(connectTimeout);
      }
      final ioRequest = await open;
      for (final entry in request.headers.entries) {
        ioRequest.headers.add(entry.name, String.fromCharCodes(entry.value));
      }
      final bodyResult = await _writeRequestBody(
        ioRequest,
        request.bodyResource,
      );
      if (!bodyResult.isOk) {
        return WASIPreview2HttpResult<WASIPreview2HttpIncomingResponse>.error(
          bodyResult.errorCode!,
        );
      }
      final ioResponse = await ioRequest.close();
      final input = WASIPreview2InputStream();
      _pipeResponseBody(ioResponse, input, options);
      return WASIPreview2HttpResult<WASIPreview2HttpIncomingResponse>.ok(
        WASIPreview2HttpIncomingResponse(
          status: ioResponse.statusCode,
          headers: WASIPreview2HttpFields(
            entries: _responseHeaders(ioResponse.headers),
            mutable: false,
          ),
          body: WASIPreview2HttpIncomingBody(input),
        ),
      );
    } on TimeoutException {
      return const WASIPreview2HttpResult<
        WASIPreview2HttpIncomingResponse
      >.error('connection-timeout');
    } on io.SocketException catch (error) {
      return WASIPreview2HttpResult<WASIPreview2HttpIncomingResponse>.error(
        _socketHttpErrorCode(error),
      );
    } on io.HttpException {
      return const WASIPreview2HttpResult<
        WASIPreview2HttpIncomingResponse
      >.error('HTTP-protocol-error');
    } on Object {
      return const WASIPreview2HttpResult<
        WASIPreview2HttpIncomingResponse
      >.error('internal-error');
    }
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
    return await body.done;
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
      input.fail(error.toString());
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
  if (micros > BigInt.from(_maxDurationMicroseconds)) {
    return const Duration(days: 1);
  }
  return Duration(microseconds: micros.toInt());
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
