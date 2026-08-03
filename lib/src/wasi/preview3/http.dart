import 'dart:async';
import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../component/async_values.dart';
import '../component/resource_table.dart';
import '../component/wit_adapter.dart';
import '../preview2/http.dart'
    show
        WASIPreview2HttpFieldEntry,
        WASIPreview2HttpFields,
        WASIPreview2HttpMethod,
        WASIPreview2HttpScheme;

/// Preview3 name for the shared HTTP fields representation.
typedef WASIPreview3HttpFields = WASIPreview2HttpFields;

/// Preview3 name for one HTTP field entry.
typedef WASIPreview3HttpFieldEntry = WASIPreview2HttpFieldEntry;

/// Preview3 name for the HTTP method representation.
typedef WASIPreview3HttpMethod = WASIPreview2HttpMethod;

/// Preview3 name for the HTTP URI scheme representation.
typedef WASIPreview3HttpScheme = WASIPreview2HttpScheme;

/// Result returned by Preview3 HTTP handlers and transports.
final class WASIPreview3HttpResult<T> {
  const WASIPreview3HttpResult._(this.value, this.errorCode);

  /// Creates a successful result.
  const WASIPreview3HttpResult.ok(T value) : this._(value, null);

  /// Creates an HTTP `error-code` result.
  const WASIPreview3HttpResult.error(String errorCode)
    : this._(null, errorCode);

  /// Successful value.
  final T? value;

  /// Stable `wasi:http/types.error-code` case label.
  final String? errorCode;

  /// Whether this result is successful.
  bool get isOk => errorCode == null;
}

/// Preview3 HTTP request transport options.
final class WASIPreview3HttpRequestOptions {
  /// Creates mutable request options.
  WASIPreview3HttpRequestOptions({
    this.connectTimeout,
    this.firstByteTimeout,
    this.betweenBytesTimeout,
    this.mutable = true,
  });

  /// Connect timeout in nanoseconds.
  BigInt? connectTimeout;

  /// Timeout to the first response byte in nanoseconds.
  BigInt? firstByteTimeout;

  /// Timeout between response chunks in nanoseconds.
  BigInt? betweenBytesTimeout;

  /// Whether setters may mutate this resource.
  final bool mutable;

  /// Returns an immutable copy for attachment to a request.
  WASIPreview3HttpRequestOptions immutableClone() {
    return WASIPreview3HttpRequestOptions(
      connectTimeout: connectTimeout,
      firstByteTimeout: firstByteTimeout,
      betweenBytesTimeout: betweenBytesTimeout,
      mutable: false,
    );
  }

  /// Returns a mutable deep copy.
  WASIPreview3HttpRequestOptions mutableClone() {
    return WASIPreview3HttpRequestOptions(
      connectTimeout: connectTimeout,
      firstByteTimeout: firstByteTimeout,
      betweenBytesTimeout: betweenBytesTimeout,
    );
  }
}

/// Unified Preview3 HTTP request resource.
final class WASIPreview3HttpRequest {
  /// Creates a request owned by a host or transport.
  WASIPreview3HttpRequest({
    required WASIPreview3HttpFields headers,
    this.contents,
    required this.trailers,
    WASIPreview3HttpRequestOptions? options,
    WASIComponentFuture<WasmComponentValueData>? transmissionResult,
    void Function()? onDrop,
    WASIPreview3HttpFields Function(int handle)? takeTrailers,
  }) : headers = headers.immutableClone(),
       options = options?.immutableClone(),
       _transmissionResult = transmissionResult,
       _onDrop = onDrop,
       _takeTrailers = takeTrailers;

  /// Creates a request whose body has no trailers.
  factory WASIPreview3HttpRequest.noTrailers({
    required WASIPreview3HttpFields headers,
    WASIComponentStream<int>? contents,
    WASIPreview3HttpRequestOptions? options,
    void Function()? onDrop,
  }) {
    return WASIPreview3HttpRequest(
      headers: headers,
      contents: contents,
      trailers: _completedTrailersFuture(null),
      options: options,
      onDrop: onDrop,
    );
  }

  /// Request method, initially `GET`.
  WASIPreview3HttpMethod method = const WASIPreview3HttpMethod.standard('get');

  /// Request path and query, or null for an empty target.
  String? pathWithQuery;

  /// Request URI scheme.
  WASIPreview3HttpScheme? scheme;

  /// Request authority.
  String? authority;

  /// Immutable request headers.
  final WASIPreview3HttpFields headers;

  /// Optional request body stream.
  final WASIComponentStream<int>? contents;

  /// Body trailers completion supplied with this request.
  final WASIComponentFuture<WasmComponentValueData> trailers;

  /// Immutable transport options.
  final WASIPreview3HttpRequestOptions? options;

  final WASIComponentFuture<WasmComponentValueData>? _transmissionResult;
  final WASIPreview3HttpFields Function(int handle)? _takeTrailers;
  void Function()? _onDrop;
  bool _bodyConsumed = false;
  bool _trailersRead = false;

  /// Completes the future returned by `request.new`.
  void completeTransmission(WASIPreview3HttpResult<void> result) {
    final future = _transmissionResult;
    if (future == null || !future.writable.canComplete) {
      return;
    }
    future.writable.complete(
      result.isOk ? _unitOk() : _errorCodeResult(result.errorCode!),
    );
  }

  /// Cancels transport work and releases unconsumed async endpoints.
  void cancel() => _drop();

  /// Resolves and takes the trailers supplied with this request.
  Future<WASIPreview3HttpResult<WASIPreview3HttpFields?>> readTrailers() async {
    if (_trailersRead) {
      throw StateError('WASI HTTP request trailers were already read.');
    }
    _trailersRead = true;
    final result = _resultData(await trailers.readable.readWhenReady());
    if (!_resultIsOk(result)) {
      return WASIPreview3HttpResult<WASIPreview3HttpFields?>.error(
        _errorCodeFromData(result.payload),
      );
    }
    final option = _optionData(result.payload);
    if (!_optionIsSome(option)) {
      return const WASIPreview3HttpResult<WASIPreview3HttpFields?>.ok(null);
    }
    final take = _takeTrailers;
    if (take == null) {
      return const WASIPreview3HttpResult<WASIPreview3HttpFields?>.error(
        'internal-error',
      );
    }
    return WASIPreview3HttpResult<WASIPreview3HttpFields?>.ok(
      take(_handle(option.payload)),
    );
  }

  List<Object?> _consumeBody(
    WASIComponentReadableFuture<Object?> handlingResult,
  ) {
    if (_bodyConsumed) {
      throw StateError('WASI HTTP request body was already consumed.');
    }
    _bodyConsumed = true;
    final contents = this.contents ?? _closedByteStream('http-request-body');
    _watchHandlingResult(handlingResult);
    return <Object?>[contents, trailers];
  }

  void _watchHandlingResult(
    WASIComponentReadableFuture<Object?> handlingResult,
  ) {
    unawaited(() async {
      try {
        final result = await handlingResult.readWhenReady();
        if (!_resultIsOk(_resultData(result))) {
          _drop();
        }
      } on Object {
        _drop();
      }
    }());
  }

  void _drop() {
    final onDrop = _onDrop;
    _onDrop = null;
    onDrop?.call();
    if (!_bodyConsumed) {
      final body = contents;
      if (body != null &&
          !body.writable.isClosed &&
          !body.readable.isCancelled &&
          !body.readable.isDropped) {
        body.readable.cancel();
      }
      if (!trailers.readable.isReady &&
          !trailers.readable.isCancelled &&
          !trailers.readable.isDropped) {
        trailers.readable.cancel();
      }
    }
    completeTransmission(
      const WASIPreview3HttpResult<void>.error('internal-error'),
    );
  }
}

/// Unified Preview3 HTTP response resource.
final class WASIPreview3HttpResponse {
  /// Creates a response owned by a host or transport.
  WASIPreview3HttpResponse({
    required WASIPreview3HttpFields headers,
    this.contents,
    required this.trailers,
    WASIComponentFuture<WasmComponentValueData>? transmissionResult,
    void Function()? onDrop,
  }) : headers = headers.immutableClone(),
       _transmissionResult = transmissionResult,
       _onDrop = onDrop;

  /// Creates a response whose body has no trailers.
  factory WASIPreview3HttpResponse.noTrailers({
    required WASIPreview3HttpFields headers,
    WASIComponentStream<int>? contents,
    void Function()? onDrop,
  }) {
    return WASIPreview3HttpResponse(
      headers: headers,
      contents: contents,
      trailers: _completedTrailersFuture(null),
      onDrop: onDrop,
    );
  }

  /// HTTP status code, initially 200.
  int statusCode = 200;

  /// Immutable response headers.
  final WASIPreview3HttpFields headers;

  /// Optional response body stream.
  final WASIComponentStream<int>? contents;

  /// Body trailers completion supplied with this response.
  final WASIComponentFuture<WasmComponentValueData> trailers;

  final WASIComponentFuture<WasmComponentValueData>? _transmissionResult;
  void Function()? _onDrop;
  bool _bodyConsumed = false;

  /// Completes the future returned by `response.new`.
  void completeTransmission(WASIPreview3HttpResult<void> result) {
    final future = _transmissionResult;
    if (future == null || !future.writable.canComplete) {
      return;
    }
    future.writable.complete(
      result.isOk ? _unitOk() : _errorCodeResult(result.errorCode!),
    );
  }

  /// Cancels transport work and releases unconsumed async endpoints.
  void cancel() => _drop();

  List<Object?> _consumeBody(
    WASIComponentReadableFuture<Object?> handlingResult,
  ) {
    if (_bodyConsumed) {
      throw StateError('WASI HTTP response body was already consumed.');
    }
    _bodyConsumed = true;
    final contents = this.contents ?? _closedByteStream('http-response-body');
    _watchHandlingResult(handlingResult);
    return <Object?>[contents, trailers];
  }

  void _watchHandlingResult(
    WASIComponentReadableFuture<Object?> handlingResult,
  ) {
    final onDrop = _onDrop;
    if (onDrop == null) {
      return;
    }
    unawaited(() async {
      try {
        final result = await handlingResult.readWhenReady();
        if (!_resultIsOk(_resultData(result))) {
          _drop();
        }
      } on Object {
        _drop();
      }
    }());
  }

  void _drop() {
    final onDrop = _onDrop;
    _onDrop = null;
    onDrop?.call();
    if (!_bodyConsumed) {
      final body = contents;
      if (body != null &&
          !body.writable.isClosed &&
          !body.readable.isCancelled &&
          !body.readable.isDropped) {
        body.readable.cancel();
      }
      if (!trailers.readable.isReady &&
          !trailers.readable.isCancelled &&
          !trailers.readable.isDropped) {
        trailers.readable.cancel();
      }
    }
    completeTransmission(
      const WASIPreview3HttpResult<void>.error('internal-error'),
    );
  }
}

/// Backend used by Preview3 `client.send` and imported `handler.handle`.
abstract interface class WASIPreview3HttpBackend {
  /// Handles an owned request and returns an owned response.
  FutureOr<WASIPreview3HttpResult<WASIPreview3HttpResponse>> handle(
    WASIPreview3HttpRequest request,
  );
}

/// Backend that rejects every request.
final class WASIPreview3UnsupportedHttpBackend
    implements WASIPreview3HttpBackend {
  /// Creates an unsupported backend.
  const WASIPreview3UnsupportedHttpBackend();

  @override
  WASIPreview3HttpResult<WASIPreview3HttpResponse> handle(
    WASIPreview3HttpRequest request,
  ) {
    request.completeTransmission(
      const WASIPreview3HttpResult<void>.error('configuration-error'),
    );
    request.cancel();
    return const WASIPreview3HttpResult<WASIPreview3HttpResponse>.error(
      'configuration-error',
    );
  }
}

/// WASI 0.3 `wasi:http` host imports.
base class WASIPreview3HttpHost {
  /// Creates a Preview3 HTTP host.
  WASIPreview3HttpHost({
    WASIComponentResourceTable? table,
    WASIPreview3HttpBackend? clientBackend,
    WASIPreview3HttpBackend? handlerBackend,
    this.maximumRequestTimeoutNanos,
  }) : table = table ?? WASIComponentResourceTable(),
       clientBackend =
           clientBackend ?? const WASIPreview3UnsupportedHttpBackend(),
       handlerBackend =
           handlerBackend ?? const WASIPreview3UnsupportedHttpBackend();

  /// Shared component resource table.
  final WASIComponentResourceTable table;

  /// Backend for `wasi:http/client.send`.
  final WASIPreview3HttpBackend clientBackend;

  /// Backend for the handler imported by the middleware world.
  final WASIPreview3HttpBackend handlerBackend;

  /// Largest supported request timeout in nanoseconds.
  final BigInt? maximumRequestTimeoutNanos;

  late final WASIComponentResourceType<WASIPreview3HttpFields> _fieldsType =
      table.defineType<WASIPreview3HttpFields>('wasi:http/types@0.3.0.fields');
  late final WASIComponentResourceType<WASIPreview3HttpRequest> _requestType =
      table.defineType<WASIPreview3HttpRequest>(
        'wasi:http/types@0.3.0.request',
        onDrop: (request) => request._drop(),
      );
  late final WASIComponentResourceType<WASIPreview3HttpRequestOptions>
  _requestOptionsType = table.defineType<WASIPreview3HttpRequestOptions>(
    'wasi:http/types@0.3.0.request-options',
  );
  late final WASIComponentResourceType<WASIPreview3HttpResponse> _responseType =
      table.defineType<WASIPreview3HttpResponse>(
        'wasi:http/types@0.3.0.response',
        onDrop: (response) => response._drop(),
      );

  /// Stable Preview3 HTTP import callbacks.
  late final Map<String, WASIComponentWitAdapterCallback>
  imports = Map<String, WASIComponentWitAdapterCallback>.unmodifiable({
    'wasi:http/types@0.3.0.fields.constructor': (_) =>
        insertFields(WASIPreview3HttpFields()),
    'wasi:http/types@0.3.0.fields.from-list': (args) =>
        _fieldsFromList(args.single),
    'wasi:http/types@0.3.0.fields.get': (args) =>
        _fieldsGet(_handle(args[0]), args[1] as String),
    'wasi:http/types@0.3.0.fields.has': (args) =>
        _fields(_handle(args[0])).has(args[1] as String),
    'wasi:http/types@0.3.0.fields.set': (args) => _headerMutationResult(
      _fields(
        _handle(args[0]),
      ).set(args[1] as String, _fieldValuesFromData(args[2])),
    ),
    'wasi:http/types@0.3.0.fields.delete': (args) => _headerMutationResult(
      _fields(_handle(args[0])).delete(args[1] as String),
    ),
    'wasi:http/types@0.3.0.fields.get-and-delete': (args) =>
        _fieldsGetAndDelete(_handle(args[0]), args[1] as String),
    'wasi:http/types@0.3.0.fields.append': (args) => _headerMutationResult(
      _appendField(
        _handle(args[0]),
        args[1] as String,
        _u8ListFromData(args[2]),
      ),
    ),
    'wasi:http/types@0.3.0.fields.copy-all': (args) =>
        _fieldsEntriesData(_fields(_handle(args.single)).entries),
    'wasi:http/types@0.3.0.fields.clone': (args) =>
        insertFields(_fields(_handle(args.single)).mutableClone()),
    'wasi:http/types@0.3.0.request.new': (args) => _newRequest(args),
    'wasi:http/types@0.3.0.request.get-method': (args) =>
        _methodData(_request(_handle(args.single)).method),
    'wasi:http/types@0.3.0.request.set-method': (args) =>
        _setRequestMethod(_handle(args[0]), args[1]),
    'wasi:http/types@0.3.0.request.get-path-with-query': (args) =>
        _optionalString(_request(_handle(args.single)).pathWithQuery),
    'wasi:http/types@0.3.0.request.set-path-with-query': (args) =>
        _setRequestPath(_handle(args[0]), args[1]),
    'wasi:http/types@0.3.0.request.get-scheme': (args) =>
        _optionalScheme(_request(_handle(args.single)).scheme),
    'wasi:http/types@0.3.0.request.set-scheme': (args) =>
        _setRequestScheme(_handle(args[0]), args[1]),
    'wasi:http/types@0.3.0.request.get-authority': (args) =>
        _optionalString(_request(_handle(args.single)).authority),
    'wasi:http/types@0.3.0.request.set-authority': (args) =>
        _setRequestAuthority(_handle(args[0]), args[1]),
    'wasi:http/types@0.3.0.request.get-options': (args) =>
        _getRequestOptions(_handle(args.single)),
    'wasi:http/types@0.3.0.request.get-headers': (args) => _insertChildFields(
      _handle(args.single),
      _request(_handle(args.single)).headers,
    ),
    'wasi:http/types@0.3.0.request.consume-body': (args) =>
        _consumeRequestBody(_handle(args[0]), args[1]),
    'wasi:http/types@0.3.0.request-options.constructor': (_) =>
        _insertRequestOptions(WASIPreview3HttpRequestOptions()),
    'wasi:http/types@0.3.0.request-options.get-connect-timeout': (args) =>
        _optionalDuration(_requestOptions(_handle(args.single)).connectTimeout),
    'wasi:http/types@0.3.0.request-options.set-connect-timeout': (args) =>
        _setRequestTimeout(
          _handle(args[0]),
          args[1],
          (options, duration) => options.connectTimeout = duration,
        ),
    'wasi:http/types@0.3.0.request-options.get-first-byte-timeout': (args) =>
        _optionalDuration(
          _requestOptions(_handle(args.single)).firstByteTimeout,
        ),
    'wasi:http/types@0.3.0.request-options.set-first-byte-timeout': (args) =>
        _setRequestTimeout(
          _handle(args[0]),
          args[1],
          (options, duration) => options.firstByteTimeout = duration,
        ),
    'wasi:http/types@0.3.0.request-options.get-between-bytes-timeout': (args) =>
        _optionalDuration(
          _requestOptions(_handle(args.single)).betweenBytesTimeout,
        ),
    'wasi:http/types@0.3.0.request-options.set-between-bytes-timeout': (args) =>
        _setRequestTimeout(
          _handle(args[0]),
          args[1],
          (options, duration) => options.betweenBytesTimeout = duration,
        ),
    'wasi:http/types@0.3.0.request-options.clone': (args) =>
        _insertRequestOptions(
          _requestOptions(_handle(args.single)).mutableClone(),
        ),
    'wasi:http/types@0.3.0.response.new': (args) => _newResponse(args),
    'wasi:http/types@0.3.0.response.get-status-code': (args) =>
        _response(_handle(args.single)).statusCode,
    'wasi:http/types@0.3.0.response.set-status-code': (args) =>
        _setResponseStatus(_handle(args[0]), _u16(args[1])),
    'wasi:http/types@0.3.0.response.get-headers': (args) => _insertChildFields(
      _handle(args.single),
      _response(_handle(args.single)).headers,
    ),
    'wasi:http/types@0.3.0.response.consume-body': (args) =>
        _consumeResponseBody(_handle(args[0]), args[1]),
    'wasi:http/client@0.3.0.send': (args) =>
        _dispatch(_handle(args.single), clientBackend),
    'wasi:http/handler@0.3.0.handle': (args) =>
        _dispatch(_handle(args.single), handlerBackend),
    'client.send': (args) => _dispatch(_handle(args.single), clientBackend),
    'handler.handle': (args) => _dispatch(_handle(args.single), handlerBackend),
  });

  /// Inserts an owned fields resource.
  int insertFields(WASIPreview3HttpFields fields) {
    return table.insert<WASIPreview3HttpFields>(_fieldsType, fields);
  }

  /// Inserts an owned request for delivery to a component handler.
  int insertRequest(WASIPreview3HttpRequest request) {
    return table.insert<WASIPreview3HttpRequest>(_requestType, request);
  }

  /// Inserts an owned response.
  int insertResponse(WASIPreview3HttpResponse response) {
    return table.insert<WASIPreview3HttpResponse>(_responseType, response);
  }

  /// Takes an owned response returned by a component handler.
  WASIPreview3HttpResponse takeResponse(int handle) {
    return table.takeDetachingChildren<WASIPreview3HttpResponse>(
      _responseType,
      handle,
    );
  }

  int _insertChildFields(int parentHandle, WASIPreview3HttpFields fields) {
    final handle = insertFields(fields.immutableClone());
    table.attachChild(parentHandle, handle);
    return handle;
  }

  int _insertRequestOptions(WASIPreview3HttpRequestOptions options) {
    return table.insert<WASIPreview3HttpRequestOptions>(
      _requestOptionsType,
      options,
    );
  }

  WASIPreview3HttpFields _fields(int handle) {
    return table.get<WASIPreview3HttpFields>(_fieldsType, handle);
  }

  WASIPreview3HttpRequest _request(int handle) {
    return table.get<WASIPreview3HttpRequest>(_requestType, handle);
  }

  WASIPreview3HttpRequestOptions _requestOptions(int handle) {
    return table.get<WASIPreview3HttpRequestOptions>(
      _requestOptionsType,
      handle,
    );
  }

  WASIPreview3HttpResponse _response(int handle) {
    return table.get<WASIPreview3HttpResponse>(_responseType, handle);
  }

  WasmComponentValueData _fieldsFromList(Object? value) {
    final entries = _fieldEntriesFromData(value);
    if (entries.any(
      (entry) => !_validFieldName(entry.name) || !_validFieldValue(entry.value),
    )) {
      return _result(false, _headerErrorData('invalid-syntax'));
    }
    return _ok(
      _integerData(insertFields(WASIPreview3HttpFields(entries: entries))),
    );
  }

  WasmComponentValueData _fieldsGet(int handle, String name) {
    return _list([
      for (final value in _fields(handle).values(name)) _u8ListData(value),
    ]);
  }

  WasmComponentValueData _fieldsGetAndDelete(int handle, String name) {
    final fields = _fields(handle);
    final values = fields.values(name);
    final error = fields.delete(name);
    if (error != null) {
      return _result(false, _headerErrorData(error));
    }
    return _ok(_list([for (final value in values) _u8ListData(value)]));
  }

  String? _appendField(int handle, String name, List<int> value) {
    final fields = _fields(handle);
    final key = name.toLowerCase();
    final originalName = fields.entries
        .where((entry) => entry.name.toLowerCase() == key)
        .firstOrNull
        ?.name;
    return fields.append(originalName ?? name, value);
  }

  List<Object?> _newRequest(List<Object?> args) {
    final headersHandle = _handle(args[0]);
    final contents = _optionalStreamFromData(args[1], 'http-request-body');
    final trailers = _futureFromData(args[2], 'http-request-trailers');
    final optionsHandle = _optionalHandleFromData(args[3]);
    final headers = _fields(headersHandle);
    final options = optionsHandle == null
        ? null
        : _requestOptions(optionsHandle);
    table.take<WASIPreview3HttpFields>(_fieldsType, headersHandle);
    if (optionsHandle != null) {
      table.take<WASIPreview3HttpRequestOptions>(
        _requestOptionsType,
        optionsHandle,
      );
    }
    final transmission = WASIComponentFuture<WasmComponentValueData>(
      'http-request-transmission',
    );
    final request = WASIPreview3HttpRequest(
      headers: headers,
      contents: contents,
      trailers: trailers,
      options: options,
      transmissionResult: transmission,
      takeTrailers: (handle) =>
          table.take<WASIPreview3HttpFields>(_fieldsType, handle),
    );
    return <Object?>[insertRequest(request), transmission];
  }

  List<Object?> _newResponse(List<Object?> args) {
    final headersHandle = _handle(args[0]);
    final contents = _optionalStreamFromData(args[1], 'http-response-body');
    final trailers = _futureFromData(args[2], 'http-response-trailers');
    final headers = table.take<WASIPreview3HttpFields>(
      _fieldsType,
      headersHandle,
    );
    final transmission = WASIComponentFuture<WasmComponentValueData>(
      'http-response-transmission',
    );
    final response = WASIPreview3HttpResponse(
      headers: headers,
      contents: contents,
      trailers: trailers,
      transmissionResult: transmission,
    );
    return <Object?>[insertResponse(response), transmission];
  }

  WasmComponentValueData _setRequestMethod(int handle, Object? value) {
    var method = _methodFromData(value);
    if (method == null || !_validMethod(method.wireName)) {
      return _unitError();
    }
    method = switch (method.wireName) {
      'GET' => const WASIPreview3HttpMethod.standard('get'),
      'HEAD' => const WASIPreview3HttpMethod.standard('head'),
      'POST' => const WASIPreview3HttpMethod.standard('post'),
      'PUT' => const WASIPreview3HttpMethod.standard('put'),
      'DELETE' => const WASIPreview3HttpMethod.standard('delete'),
      'CONNECT' => const WASIPreview3HttpMethod.standard('connect'),
      'OPTIONS' => const WASIPreview3HttpMethod.standard('options'),
      'TRACE' => const WASIPreview3HttpMethod.standard('trace'),
      'PATCH' => const WASIPreview3HttpMethod.standard('patch'),
      _ => method,
    };
    _request(handle).method = method;
    return _unitOk();
  }

  WasmComponentValueData _setRequestPath(int handle, Object? value) {
    final path = _optionalStringFromData(value);
    if (path != null && !_validPathWithQuery(path)) {
      return _unitError();
    }
    _request(handle).pathWithQuery = path == '' ? '/' : path;
    return _unitOk();
  }

  WasmComponentValueData _setRequestScheme(int handle, Object? value) {
    var scheme = _optionalSchemeFromData(value);
    if (scheme != null && !_validScheme(scheme.wireName)) {
      return _unitError();
    }
    scheme = switch (scheme?.wireName.toLowerCase()) {
      'http' => const WASIPreview3HttpScheme.standard('HTTP'),
      'https' => const WASIPreview3HttpScheme.standard('HTTPS'),
      _ => scheme,
    };
    _request(handle).scheme = scheme;
    return _unitOk();
  }

  WasmComponentValueData _setRequestAuthority(int handle, Object? value) {
    final authority = _optionalStringFromData(value);
    if (authority != null && !_validAuthority(authority)) {
      return _unitError();
    }
    _request(handle).authority = authority;
    return _unitOk();
  }

  WasmComponentValueData _getRequestOptions(int requestHandle) {
    final options = _request(requestHandle).options;
    if (options == null) {
      return _none();
    }
    final handle = _insertRequestOptions(options.immutableClone());
    table.attachChild(requestHandle, handle);
    return _some(_integerData(handle));
  }

  WasmComponentValueData _setRequestTimeout(
    int handle,
    Object? value,
    void Function(WASIPreview3HttpRequestOptions, BigInt?) setTimeout,
  ) {
    final options = _requestOptions(handle);
    if (!options.mutable) {
      return _result(false, _requestOptionsErrorData('immutable'));
    }
    final duration = _optionalDurationFromData(value);
    final maximum = maximumRequestTimeoutNanos;
    if (duration != null && maximum != null && duration > maximum) {
      return _result(false, _requestOptionsErrorData('not-supported'));
    }
    setTimeout(options, duration);
    return _unitOk();
  }

  WasmComponentValueData _setResponseStatus(int handle, int status) {
    if (status < 100 || status > 599) {
      return _unitError();
    }
    _response(handle).statusCode = status;
    return _unitOk();
  }

  List<Object?> _consumeRequestBody(int handle, Object? resultValue) {
    final result = _readableFuture(resultValue, 'request handling result');
    final request = table.takeDetachingChildren<WASIPreview3HttpRequest>(
      _requestType,
      handle,
    );
    return request._consumeBody(result);
  }

  List<Object?> _consumeResponseBody(int handle, Object? resultValue) {
    final result = _readableFuture(resultValue, 'response handling result');
    final response = table.takeDetachingChildren<WASIPreview3HttpResponse>(
      _responseType,
      handle,
    );
    return response._consumeBody(result);
  }

  Future<WasmComponentValueData> _dispatch(
    int handle,
    WASIPreview3HttpBackend backend,
  ) async {
    final request = _request(handle);
    final validationError = _requestValidationError(request);
    final owned = table.takeDetachingChildren<WASIPreview3HttpRequest>(
      _requestType,
      handle,
    );
    if (validationError != null) {
      owned.completeTransmission(
        WASIPreview3HttpResult<void>.error(validationError),
      );
      owned.cancel();
      return _errorCodeResult(validationError);
    }
    try {
      final result = await backend.handle(owned);
      if (!result.isOk) {
        owned.completeTransmission(
          WASIPreview3HttpResult<void>.error(result.errorCode!),
        );
        owned.cancel();
        return _errorCodeResult(result.errorCode!);
      }
      return _ok(_integerData(insertResponse(result.value!)));
    } on Object {
      owned.completeTransmission(
        const WASIPreview3HttpResult<void>.error('internal-error'),
      );
      owned.cancel();
      return _errorCodeResult('internal-error');
    }
  }

  WasmComponentValueData _headerMutationResult(String? error) {
    return error == null ? _unitOk() : _result(false, _headerErrorData(error));
  }
}

WASIComponentReadableFuture<Object?> _readableFuture(
  Object? value,
  String name,
) {
  return switch (value) {
    WASIComponentReadableFuture<Object?>() => value,
    WASIComponentFuture<Object?>() => value.readable,
    _ => throw StateError('Expected $name future readable endpoint.'),
  };
}

WASIComponentStream<int>? _optionalStreamFromData(Object? value, String name) {
  final data = _optionData(value);
  if (!_optionIsSome(data)) {
    return null;
  }
  final associated = data.payload;
  if (associated is WASIComponentStream<int>) {
    return associated.maxBufferedElements == 0
        ? _bufferReadableStream(associated.readable, name)
        : associated;
  }
  if (associated is WASIComponentReadableStream<Object?>) {
    return _bufferReadableStream(associated, name);
  }
  throw StateError('Expected option<stream<u8>> payload.');
}

WASIComponentStream<int> _bufferReadableStream(
  WASIComponentReadableStream<Object?> source,
  String name,
) {
  final buffered = WASIComponentStream<int>(
    name,
    maxBufferedElements: 64 * 1024,
  );
  unawaited(() async {
    try {
      while (true) {
        final values = await source.readWhenAvailable(64 * 1024);
        if (values.isEmpty) {
          buffered.writable.close();
          return;
        }
        final bytes = <int>[];
        for (final value in values) {
          if (value is! int || value < 0 || value > 0xff) {
            throw StateError('Expected stream<u8> element.');
          }
          bytes.add(value);
        }
        var offset = 0;
        while (offset < bytes.length) {
          offset += await buffered.writable.writeWhenAvailable(
            bytes.getRange(offset, bytes.length),
          );
        }
      }
    } on WASIComponentAsyncEndpointStateError catch (error) {
      if (error.failure == WASIComponentAsyncEndpointFailure.dropped) {
        if (!buffered.writable.isClosed) {
          buffered.writable.close();
        }
      } else if (!buffered.readable.isDropped &&
          !buffered.readable.isCancelled) {
        buffered.readable.cancel();
      }
    } on Object {
      if (!buffered.readable.isDropped && !buffered.readable.isCancelled) {
        buffered.readable.cancel();
      }
    }
  }());
  return buffered;
}

WASIComponentFuture<WasmComponentValueData> _futureFromData(
  Object? value,
  String name,
) {
  final source = switch (value) {
    WASIComponentReadableFuture<Object?>() => value,
    WASIComponentFuture<Object?>() => value.readable,
    _ => throw StateError('Expected $name future readable endpoint.'),
  };
  final buffered = WASIComponentFuture<WasmComponentValueData>(name);
  unawaited(() async {
    try {
      final result = await source.readWhenReady();
      if (result is! WasmComponentValueData) {
        throw StateError('Expected $name component value.');
      }
      if (buffered.writable.canComplete) {
        buffered.writable.complete(result);
      }
    } on Object {
      if (buffered.writable.canComplete) {
        buffered.writable.cancel();
      }
    }
  }());
  return buffered;
}

int? _optionalHandleFromData(Object? value) {
  final data = _optionData(value);
  return _optionIsSome(data) ? _handle(data.associatedValue) : null;
}

WASIComponentFuture<WasmComponentValueData> _completedTrailersFuture(
  WASIPreview3HttpFields? fields,
) {
  if (fields != null) {
    throw UnsupportedError(
      'Owned fields trailers require a WASIPreview3HttpHost resource table.',
    );
  }
  final future = WASIComponentFuture<WasmComponentValueData>('http-trailers');
  future.writable.complete(_ok(_none()));
  return future;
}

WASIComponentStream<int> _closedByteStream(String name) {
  final stream = WASIComponentStream<int>(name);
  stream.writable.close();
  return stream;
}

WASIPreview3HttpMethod? _methodFromData(Object? value) {
  final data = _variantData(value);
  final label = data.label ?? _caseLabel(_httpMethodCases, data.index);
  if (label == 'other') {
    final token = _stringFromData(data.associatedValue);
    return token == null ? null : WASIPreview3HttpMethod.other(token);
  }
  return _httpMethodCases.contains(label)
      ? WASIPreview3HttpMethod.standard(label)
      : null;
}

WasmComponentValueData _methodData(WASIPreview3HttpMethod method) {
  return _variant(
    method.label,
    _httpMethodCases.indexOf(method.label),
    method.other == null ? null : _stringData(method.other!),
  );
}

WASIPreview3HttpScheme? _schemeFromData(Object? value) {
  final data = _variantData(value);
  final label = data.label ?? _caseLabel(_httpSchemeCases, data.index);
  if (label == 'other') {
    final scheme = _stringFromData(data.associatedValue);
    return scheme == null ? null : WASIPreview3HttpScheme.other(scheme);
  }
  return label == 'HTTP' || label == 'HTTPS'
      ? WASIPreview3HttpScheme.standard(label)
      : null;
}

WasmComponentValueData _schemeData(WASIPreview3HttpScheme scheme) {
  return _variant(
    scheme.label,
    _httpSchemeCases.indexOf(scheme.label),
    scheme.other == null ? null : _stringData(scheme.other!),
  );
}

WASIPreview3HttpScheme? _optionalSchemeFromData(Object? value) {
  final data = _optionData(value);
  return _optionIsSome(data) ? _schemeFromData(data.associatedValue) : null;
}

WasmComponentValueData _optionalScheme(WASIPreview3HttpScheme? scheme) {
  return scheme == null ? _none() : _some(_schemeData(scheme));
}

String? _optionalStringFromData(Object? value) {
  final data = _optionData(value);
  return _optionIsSome(data) ? _stringFromData(data.associatedValue) : null;
}

WasmComponentValueData _optionalString(String? value) {
  return value == null ? _none() : _some(_stringData(value));
}

BigInt? _optionalDurationFromData(Object? value) {
  final data = _optionData(value);
  return _optionIsSome(data) ? _u64(data.associatedValue) : null;
}

WasmComponentValueData _optionalDuration(BigInt? value) {
  return value == null ? _none() : _some(_integerData(value));
}

List<WASIPreview3HttpFieldEntry> _fieldEntriesFromData(Object? value) {
  final list = _listData(value);
  return <WASIPreview3HttpFieldEntry>[
    for (final item in list.items)
      WASIPreview3HttpFieldEntry(
        _stringFromData(_tupleData(item).items[0])!,
        _u8ListFromData(_tupleData(item).items[1]),
      ),
  ];
}

List<List<int>> _fieldValuesFromData(Object? value) {
  final list = _listData(value);
  return <List<int>>[for (final item in list.items) _u8ListFromData(item)];
}

WasmComponentValueData _fieldsEntriesData(
  List<WASIPreview3HttpFieldEntry> entries,
) {
  return _list(<WasmComponentValueData>[
    for (final entry in entries)
      _tuple(<WasmComponentValueData>[
        _stringData(entry.name),
        _u8ListData(entry.value),
      ]),
  ]);
}

String? _requestValidationError(WASIPreview3HttpRequest request) {
  final scheme = request.scheme?.wireName.toLowerCase() ?? 'http';
  final authority = request.authority;
  final isHttp = scheme == 'http' || scheme == 'https';
  if (isHttp && authority == null) {
    return 'HTTP-request-URI-invalid';
  }
  if (authority != null &&
      (!_validAuthority(authority) ||
          (isHttp && _authorityHasUserInfo(authority)))) {
    return 'HTTP-request-URI-invalid';
  }
  if (request.headers.has('host')) {
    return 'HTTP-request-denied';
  }
  if (_contentLength(request.headers).invalid) {
    return 'HTTP-request-body-size';
  }
  return null;
}

({BigInt? value, bool invalid}) _contentLength(WASIPreview3HttpFields fields) {
  final values = <BigInt>[];
  for (final rawValue in fields.values('content-length')) {
    for (final part in String.fromCharCodes(rawValue).split(',')) {
      final text = part.trim();
      if (text.isEmpty || text.codeUnits.any((code) => !_isDigit(code))) {
        return (value: null, invalid: true);
      }
      values.add(BigInt.parse(text));
    }
  }
  if (values.isEmpty) {
    return (value: null, invalid: false);
  }
  final expected = values.first;
  return values.every((value) => value == expected)
      ? (value: expected, invalid: false)
      : (value: null, invalid: true);
}

WasmComponentValueData _errorCodeResult(String code) {
  return _result(false, _errorCodeData(code));
}

String _errorCodeFromData(Object? value) {
  final data = _variantData(value);
  return data.label ?? _caseLabel(_httpErrorCodeCases, data.index);
}

WasmComponentValueData _errorCodeData(String code) {
  var index = _httpErrorCodeCases.indexOf(code);
  if (index < 0) {
    index = _httpErrorCodeCases.indexOf('internal-error');
  }
  final label = _httpErrorCodeCases[index];
  return _variant(label, index, _httpErrorCodePayload(label));
}

WasmComponentValueData? _httpErrorCodePayload(String code) {
  return switch (code) {
    'DNS-error' ||
    'TLS-alert-received' => _record(<WasmComponentValueData>[_none(), _none()]),
    'HTTP-request-trailer-size' ||
    'HTTP-response-header-size' ||
    'HTTP-response-trailer-size' => _record(<WasmComponentValueData>[
      _none(),
      _none(),
    ]),
    'HTTP-request-body-size' ||
    'HTTP-request-header-section-size' ||
    'HTTP-request-header-size' ||
    'HTTP-request-trailer-section-size' ||
    'HTTP-response-header-section-size' ||
    'HTTP-response-body-size' ||
    'HTTP-response-trailer-section-size' ||
    'HTTP-response-transfer-coding' ||
    'HTTP-response-content-coding' ||
    'internal-error' => _none(),
    _ => null,
  };
}

WasmComponentValueData _headerErrorData(String code) {
  var index = _headerErrorCases.indexOf(code);
  if (index < 0) {
    index = _headerErrorCases.indexOf('other');
    return _variant('other', index, _none());
  }
  return _variant(code, index, code == 'other' ? _none() : null);
}

WasmComponentValueData _requestOptionsErrorData(String code) {
  var index = _requestOptionsErrorCases.indexOf(code);
  if (index < 0) {
    index = _requestOptionsErrorCases.indexOf('other');
    return _variant('other', index, _none());
  }
  return _variant(code, index, code == 'other' ? _none() : null);
}

WasmComponentValueData _ok([WasmComponentValueData? value]) {
  return _result(true, value);
}

WasmComponentValueData _unitOk() => _ok();

WasmComponentValueData _unitError() => _result(false, null);

WasmComponentValueData _result(bool isOk, WasmComponentValueData? value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.result,
    rawBytes: Uint8List(0),
    index: isOk ? 0 : 1,
    label: isOk ? 'ok' : 'error',
    isOk: isOk,
    associatedValue: value,
  );
}

WasmComponentValueData _some(WasmComponentValueData value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 1,
    label: 'some',
    isSome: true,
    associatedValue: value,
  );
}

WasmComponentValueData _none() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'none',
    isSome: false,
  );
}

WasmComponentValueData _variant(
  String label,
  int index, [
  WasmComponentValueData? associatedValue,
]) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.variant,
    rawBytes: Uint8List(0),
    index: index,
    label: label,
    associatedValue: associatedValue,
  );
}

WasmComponentValueData _list(List<WasmComponentValueData> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.list,
    rawBytes: Uint8List(0),
    items: List<WasmComponentValueData>.unmodifiable(items),
  );
}

WasmComponentValueData _tuple(List<WasmComponentValueData> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.tuple,
    rawBytes: Uint8List(0),
    items: List<WasmComponentValueData>.unmodifiable(items),
  );
}

WasmComponentValueData _record(List<WasmComponentValueData> items) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.record,
    rawBytes: Uint8List(0),
    items: List<WasmComponentValueData>.unmodifiable(items),
  );
}

WasmComponentValueData _stringData(String value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.string,
    rawBytes: Uint8List(0),
    string: value,
  );
}

WasmComponentValueData _integerData(Object value) {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.integer,
    rawBytes: Uint8List(0),
    integer: value,
  );
}

WasmComponentValueData _u8ListData(List<int> bytes) {
  return _list(<WasmComponentValueData>[
    for (final byte in bytes) _integerData(byte),
  ]);
}

WasmComponentValueData _listData(Object? value) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.list) {
    throw StateError('Expected list value.');
  }
  return value;
}

WasmComponentValueData _tupleData(Object? value) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.tuple) {
    throw StateError('Expected tuple value.');
  }
  return value;
}

WasmComponentValueData _variantData(Object? value) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.variant) {
    throw StateError('Expected variant value.');
  }
  return value;
}

WasmComponentValueData _optionData(Object? value) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.option) {
    throw StateError('Expected option value.');
  }
  return value;
}

WasmComponentValueData _resultData(Object? value) {
  if (value is! WasmComponentValueData ||
      value.kind != WasmComponentValueDataKind.result) {
    throw StateError('Expected result value.');
  }
  return value;
}

bool _optionIsSome(WasmComponentValueData value) {
  return value.isSome ?? value.label == 'some' || value.index == 1;
}

bool _resultIsOk(WasmComponentValueData value) {
  return value.isOk ?? value.label == 'ok' || value.index == 0;
}

String _caseLabel(List<String> cases, int? index) {
  if (index == null || index < 0 || index >= cases.length) {
    throw StateError('Unknown WIT variant case index: $index.');
  }
  return cases[index];
}

String? _stringFromData(Object? value) {
  return switch (value) {
    String() => value,
    WasmComponentValueData(kind: WasmComponentValueDataKind.string) =>
      value.string,
    _ => null,
  };
}

List<int> _u8ListFromData(Object? value) {
  final list = _listData(value);
  return <int>[
    for (final item in list.items)
      if (item.kind == WasmComponentValueDataKind.integer)
        _u8(item.integer)
      else
        throw StateError('Expected u8 field value item.'),
  ];
}

int _u8(Object? value) {
  return switch (value) {
    int() when value >= 0 && value <= 0xff => value,
    BigInt() when value >= BigInt.zero && value <= BigInt.from(0xff) =>
      value.toInt(),
    WasmComponentValueData(kind: WasmComponentValueDataKind.integer) => _u8(
      value.integer,
    ),
    _ => throw StateError('Expected u8 value, got $value.'),
  };
}

int _u16(Object? value) {
  return switch (value) {
    int() when value >= 0 && value <= 0xffff => value,
    BigInt() when value >= BigInt.zero && value <= BigInt.from(0xffff) =>
      value.toInt(),
    WasmComponentValueData(kind: WasmComponentValueDataKind.integer) => _u16(
      value.integer,
    ),
    _ => throw StateError('Expected u16 value, got $value.'),
  };
}

BigInt _u64(Object? value) {
  return switch (value) {
    int() when value >= 0 => BigInt.from(value),
    BigInt() when value >= BigInt.zero => value,
    WasmComponentValueData(kind: WasmComponentValueDataKind.integer) => _u64(
      value.integer,
    ),
    _ => throw StateError('Expected u64 value, got $value.'),
  };
}

int _handle(Object? value) {
  return switch (value) {
    int() when value >= 0 && value <= _maxU32 => value,
    BigInt() when value >= BigInt.zero && value <= BigInt.from(_maxU32) =>
      value.toInt(),
    WasmComponentValueData(kind: WasmComponentValueDataKind.integer) => _handle(
      value.integer,
    ),
    _ => throw StateError('Expected WASI resource handle, got $value.'),
  };
}

bool _validMethod(String method) => _validFieldName(method);

bool _validPathWithQuery(String value) {
  for (var index = 0; index < value.length; index++) {
    final code = value.codeUnitAt(index);
    if (code < 0x80 &&
        !_isUriPchar(code) &&
        code != 37 &&
        code != 47 &&
        code != 63) {
      return false;
    }
  }
  return true;
}

bool _validAuthority(String value) {
  if (value.isEmpty) {
    return false;
  }
  for (var index = 0; index < value.length; index++) {
    final code = value.codeUnitAt(index);
    if (code == 37) {
      if (index + 2 >= value.length ||
          !_isHexDigit(value.codeUnitAt(index + 1)) ||
          !_isHexDigit(value.codeUnitAt(index + 2))) {
        return false;
      }
      index += 2;
      continue;
    }
    if (!_isUriPchar(code) && code != 91 && code != 93) {
      return false;
    }
  }
  final uri = Uri.tryParse('http://$value/');
  return uri != null &&
      uri.hasAuthority &&
      uri.host.isNotEmpty &&
      uri.path == '/' &&
      !uri.hasQuery &&
      !uri.hasFragment;
}

bool _authorityHasUserInfo(String value) => value.contains('@');

bool _validScheme(String scheme) {
  if (scheme.isEmpty || !_isAlpha(scheme.codeUnitAt(0))) {
    return false;
  }
  for (var index = 1; index < scheme.length; index++) {
    final code = scheme.codeUnitAt(index);
    if (!_isAlpha(code) &&
        !_isDigit(code) &&
        code != 43 &&
        code != 45 &&
        code != 46) {
      return false;
    }
  }
  return true;
}

bool _validFieldName(String name) {
  return name.isNotEmpty && name.codeUnits.every(_isTokenChar);
}

bool _validFieldValue(List<int> value) {
  return value.every(
    (byte) =>
        byte == 9 ||
        (byte >= 32 && byte <= 126) ||
        (byte >= 128 && byte <= 255),
  );
}

bool _isTokenChar(int code) {
  return _isAlpha(code) ||
      _isDigit(code) ||
      const <int>{
        33,
        35,
        36,
        37,
        38,
        39,
        42,
        43,
        45,
        46,
        94,
        95,
        96,
        124,
        126,
      }.contains(code);
}

bool _isUriPchar(int code) {
  return _isAlpha(code) ||
      _isDigit(code) ||
      const <int>{
        33,
        36,
        38,
        39,
        40,
        41,
        42,
        43,
        44,
        45,
        46,
        58,
        59,
        61,
        64,
        95,
        126,
      }.contains(code);
}

bool _isHexDigit(int code) {
  return _isDigit(code) ||
      (code >= 65 && code <= 70) ||
      (code >= 97 && code <= 102);
}

bool _isAlpha(int code) {
  return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
}

bool _isDigit(int code) => code >= 48 && code <= 57;

const List<String> _httpMethodCases = <String>[
  'get',
  'head',
  'post',
  'put',
  'delete',
  'connect',
  'options',
  'trace',
  'patch',
  'other',
];

const List<String> _httpSchemeCases = <String>['HTTP', 'HTTPS', 'other'];

const List<String> _headerErrorCases = <String>[
  'invalid-syntax',
  'forbidden',
  'immutable',
  'size-exceeded',
  'other',
];

const List<String> _requestOptionsErrorCases = <String>[
  'not-supported',
  'immutable',
  'other',
];

const List<String> _httpErrorCodeCases = <String>[
  'DNS-timeout',
  'DNS-error',
  'destination-not-found',
  'destination-unavailable',
  'destination-IP-prohibited',
  'destination-IP-unroutable',
  'connection-refused',
  'connection-terminated',
  'connection-timeout',
  'connection-read-timeout',
  'connection-write-timeout',
  'connection-limit-reached',
  'TLS-protocol-error',
  'TLS-certificate-error',
  'TLS-alert-received',
  'HTTP-request-denied',
  'HTTP-request-length-required',
  'HTTP-request-body-size',
  'HTTP-request-method-invalid',
  'HTTP-request-URI-invalid',
  'HTTP-request-URI-too-long',
  'HTTP-request-header-section-size',
  'HTTP-request-header-size',
  'HTTP-request-trailer-section-size',
  'HTTP-request-trailer-size',
  'HTTP-response-incomplete',
  'HTTP-response-header-section-size',
  'HTTP-response-header-size',
  'HTTP-response-body-size',
  'HTTP-response-trailer-section-size',
  'HTTP-response-trailer-size',
  'HTTP-response-transfer-coding',
  'HTTP-response-content-coding',
  'HTTP-response-timeout',
  'HTTP-upgrade-failed',
  'HTTP-protocol-error',
  'loop-detected',
  'configuration-error',
  'internal-error',
];

const int _maxU32 = 0xffffffff;
