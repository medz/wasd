import 'dart:async';
import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../component/resource_table.dart';
import '../component/wit_adapter.dart';
import 'io.dart';
import 'poll.dart';

/// Result returned by Preview2 HTTP backends.
final class WASIPreview2HttpResult<T> {
  const WASIPreview2HttpResult._(this.value, this.errorCode);

  /// Creates a successful HTTP backend result.
  const WASIPreview2HttpResult.ok(T value) : this._(value, null);

  /// Creates an HTTP backend error result.
  const WASIPreview2HttpResult.error(String errorCode)
    : this._(null, errorCode);

  /// Successful value, when [isOk] is true.
  final T? value;

  /// `wasi:http/types.error-code` label, when [isOk] is false.
  final String? errorCode;

  /// Whether this result is successful.
  bool get isOk => errorCode == null;
}

/// Preview2 HTTP fields resource.
final class WASIPreview2HttpFields {
  /// Creates HTTP fields from [entries].
  WASIPreview2HttpFields({
    List<WASIPreview2HttpFieldEntry> entries =
        const <WASIPreview2HttpFieldEntry>[],
    this.mutable = true,
  }) : _entries = List<WASIPreview2HttpFieldEntry>.of(entries);

  final List<WASIPreview2HttpFieldEntry> _entries;

  /// Whether mutation APIs are allowed.
  final bool mutable;

  /// Returns all entries in serialization order.
  List<WASIPreview2HttpFieldEntry> get entries =>
      List<WASIPreview2HttpFieldEntry>.unmodifiable(_entries);

  /// Returns an immutable clone.
  WASIPreview2HttpFields immutableClone() =>
      WASIPreview2HttpFields(entries: _entries, mutable: false);

  /// Returns a mutable clone.
  WASIPreview2HttpFields mutableClone() =>
      WASIPreview2HttpFields(entries: _entries);

  /// Returns all values for [name], matching names case-insensitively.
  List<List<int>> values(String name) {
    if (!_validFieldName(name)) {
      return const <List<int>>[];
    }
    final key = name.toLowerCase();
    return [
      for (final entry in _entries)
        if (entry.name.toLowerCase() == key)
          List<int>.unmodifiable(entry.value),
    ];
  }

  /// Returns whether [name] has at least one value.
  bool has(String name) => values(name).isNotEmpty;

  /// Replaces all values for [name].
  String? set(String name, List<List<int>> values) {
    final validation = _validateMutation(name, values);
    if (validation != null) {
      return validation;
    }
    final key = name.toLowerCase();
    _entries.removeWhere((entry) => entry.name.toLowerCase() == key);
    _entries.addAll([
      for (final value in values)
        WASIPreview2HttpFieldEntry(name, List<int>.unmodifiable(value)),
    ]);
    return null;
  }

  /// Deletes all values for [name].
  String? delete(String name) {
    final validation = _validateMutation(name, const <List<int>>[]);
    if (validation != null) {
      return validation;
    }
    final key = name.toLowerCase();
    _entries.removeWhere((entry) => entry.name.toLowerCase() == key);
    return null;
  }

  /// Appends one value for [name].
  String? append(String name, List<int> value) {
    final validation = _validateMutation(name, <List<int>>[value]);
    if (validation != null) {
      return validation;
    }
    _entries.add(
      WASIPreview2HttpFieldEntry(name, List<int>.unmodifiable(value)),
    );
    return null;
  }

  String? _validateMutation(String name, List<List<int>> values) {
    if (!mutable) {
      return 'immutable';
    }
    if (!_validFieldName(name) ||
        values.any((value) => !_validFieldValue(value))) {
      return 'invalid-syntax';
    }
    return null;
  }
}

/// One HTTP field name/value pair.
final class WASIPreview2HttpFieldEntry {
  /// Creates a field entry.
  const WASIPreview2HttpFieldEntry(this.name, this.value);

  /// Field name.
  final String name;

  /// Raw field value bytes.
  final List<int> value;
}

/// Preview2 HTTP request method.
final class WASIPreview2HttpMethod {
  const WASIPreview2HttpMethod._(this.label, this.other);

  /// Creates a standard method.
  const WASIPreview2HttpMethod.standard(String label) : this._(label, null);

  /// Creates a custom method token.
  const WASIPreview2HttpMethod.other(String value) : this._('other', value);

  /// WIT variant label.
  final String label;

  /// Custom token for `other`.
  final String? other;

  /// HTTP wire method.
  String get wireName => other ?? label.toUpperCase();
}

/// Preview2 HTTP URI scheme.
final class WASIPreview2HttpScheme {
  const WASIPreview2HttpScheme._(this.label, this.other);

  /// Creates a standard scheme.
  const WASIPreview2HttpScheme.standard(String label) : this._(label, null);

  /// Creates a custom scheme.
  const WASIPreview2HttpScheme.other(String value) : this._('other', value);

  /// WIT variant label.
  final String label;

  /// Custom scheme for `other`.
  final String? other;

  /// URI scheme text.
  String get wireName => other ?? label.toLowerCase();
}

/// Preview2 outgoing HTTP request.
final class WASIPreview2HttpOutgoingRequest {
  /// Creates an outgoing request.
  WASIPreview2HttpOutgoingRequest(WASIPreview2HttpFields headers)
    : headers = headers.immutableClone();

  /// Request method.
  WASIPreview2HttpMethod method = const WASIPreview2HttpMethod.standard('get');

  /// Request path and query.
  String? pathWithQuery;

  /// Request scheme.
  WASIPreview2HttpScheme? scheme;

  /// Request authority.
  String? authority;

  /// Request headers.
  final WASIPreview2HttpFields headers;

  WASIPreview2HttpOutgoingBody? _body;

  /// Outgoing request body, when created.
  WASIPreview2HttpOutgoingBody? get bodyResource => _body;

  /// Returns the outgoing body on the first call, or null afterwards.
  WASIPreview2HttpOutgoingBody? takeBody() {
    if (_body != null) {
      return null;
    }
    return _body = WASIPreview2HttpOutgoingBody();
  }
}

/// Preview2 incoming HTTP request.
final class WASIPreview2HttpIncomingRequest {
  /// Creates an incoming request.
  WASIPreview2HttpIncomingRequest({
    required this.method,
    required WASIPreview2HttpFields headers,
    this.pathWithQuery,
    this.scheme,
    this.authority,
    WASIPreview2HttpIncomingBody? body,
  }) : headers = headers.immutableClone(),
       _body = body ?? WASIPreview2HttpIncomingBody(WASIPreview2InputStream());

  /// Request method.
  final WASIPreview2HttpMethod method;

  /// Request path and query.
  final String? pathWithQuery;

  /// Request scheme.
  final WASIPreview2HttpScheme? scheme;

  /// Request authority.
  final String? authority;

  /// Request headers.
  final WASIPreview2HttpFields headers;

  WASIPreview2HttpIncomingBody? _body;

  /// Consumes the request body on the first call, or null afterwards.
  WASIPreview2HttpIncomingBody? consume() {
    final body = _body;
    _body = null;
    return body;
  }
}

/// Preview2 HTTP request options.
final class WASIPreview2HttpRequestOptions {
  /// Connect timeout in nanoseconds.
  BigInt? connectTimeout;

  /// First byte timeout in nanoseconds.
  BigInt? firstByteTimeout;

  /// Between bytes timeout in nanoseconds.
  BigInt? betweenBytesTimeout;
}

/// Preview2 response outparam resource.
final class WASIPreview2HttpResponseOutparam {
  WASIPreview2HttpResult<WASIPreview2HttpOutgoingResponse>? _response;
  final List<WASIPreview2HttpInformationalResponse> _informationalResponses =
      <WASIPreview2HttpInformationalResponse>[];

  /// Stored response, when set.
  WASIPreview2HttpResult<WASIPreview2HttpOutgoingResponse>? get response =>
      _response;

  /// Informational responses sent before the final response.
  List<WASIPreview2HttpInformationalResponse> get informationalResponses =>
      List<WASIPreview2HttpInformationalResponse>.unmodifiable(
        _informationalResponses,
      );

  /// Sends an informational response before the final response.
  WASIPreview2HttpResult<void> sendInformational(
    int status,
    WASIPreview2HttpFields headers,
  ) {
    if (_response != null || status < 100 || status > 199) {
      return const WASIPreview2HttpResult<void>.error('HTTP-protocol-error');
    }
    _informationalResponses.add(
      WASIPreview2HttpInformationalResponse(
        status: status,
        headers: headers.immutableClone(),
      ),
    );
    return const WASIPreview2HttpResult<void>.ok(null);
  }

  /// Sets the response once.
  bool set(WASIPreview2HttpResult<WASIPreview2HttpOutgoingResponse> response) {
    if (_response != null) {
      return false;
    }
    _response = response;
    return true;
  }
}

/// Preview2 informational response sent through a response outparam.
final class WASIPreview2HttpInformationalResponse {
  /// Creates an informational response.
  const WASIPreview2HttpInformationalResponse({
    required this.status,
    required this.headers,
  });

  /// Informational status code.
  final int status;

  /// Informational headers.
  final WASIPreview2HttpFields headers;
}

/// Preview2 incoming HTTP response.
final class WASIPreview2HttpIncomingResponse {
  /// Creates an incoming response.
  WASIPreview2HttpIncomingResponse({
    required this.status,
    required WASIPreview2HttpFields headers,
    required WASIPreview2HttpIncomingBody body,
  }) : headers = headers.immutableClone(),
       _body = body;

  /// Response status code.
  final int status;

  /// Response headers.
  final WASIPreview2HttpFields headers;

  WASIPreview2HttpIncomingBody? _body;

  /// Consumes the response body on the first call, or null afterwards.
  WASIPreview2HttpIncomingBody? consume() {
    final body = _body;
    _body = null;
    return body;
  }
}

/// Preview2 incoming body resource.
final class WASIPreview2HttpIncomingBody {
  /// Creates an incoming body backed by [stream].
  WASIPreview2HttpIncomingBody(
    WASIPreview2InputStream stream, {
    WASIPreview2HttpFutureTrailers? trailers,
  }) : _stream = stream,
       _trailers =
           trailers ??
           WASIPreview2HttpFutureTrailers.completed(
             const WASIPreview2HttpResult<WASIPreview2HttpFields?>.ok(null),
           );

  WASIPreview2InputStream? _stream;
  final WASIPreview2HttpFutureTrailers _trailers;

  /// Returns the stream on the first call, or null afterwards.
  WASIPreview2InputStream? takeStream() {
    final stream = _stream;
    _stream = null;
    return stream;
  }

  /// Future trailers associated with this body.
  WASIPreview2HttpFutureTrailers finish() => _trailers;
}

/// Preview2 outgoing response resource.
final class WASIPreview2HttpOutgoingResponse {
  /// Creates an outgoing response.
  WASIPreview2HttpOutgoingResponse(WASIPreview2HttpFields headers)
    : headers = headers.immutableClone();

  /// Response status code.
  int statusCode = 200;

  /// Response headers.
  final WASIPreview2HttpFields headers;

  WASIPreview2HttpOutgoingBody? _body;

  /// Outgoing response body, when created.
  WASIPreview2HttpOutgoingBody? get bodyResource => _body;

  /// Returns the outgoing body on the first call, or null afterwards.
  WASIPreview2HttpOutgoingBody? takeBody() {
    if (_body != null) {
      return null;
    }
    return _body = WASIPreview2HttpOutgoingBody();
  }
}

/// Preview2 outgoing body resource.
final class WASIPreview2HttpOutgoingBody {
  final StreamController<List<int>> _chunks = StreamController<List<int>>();
  final Completer<WASIPreview2HttpResult<void>> _done =
      Completer<WASIPreview2HttpResult<void>>();
  WASIPreview2OutputStream? _stream;
  WASIPreview2HttpFields? _trailers;
  bool _finished = false;

  /// Bytes written to the body stream so far.
  List<int> get bytes =>
      List<int>.unmodifiable(_stream?.bytes ?? const <int>[]);

  /// Body chunks written after the output stream is taken.
  Stream<List<int>> get chunks => _chunks.stream;

  /// Completes when the body is finished.
  Future<WASIPreview2HttpResult<void>> get done => _done.future;

  /// Whether [finish] has been called.
  bool get isFinished => _finished;

  /// Returns the output stream on the first call, or null afterwards.
  WASIPreview2OutputStream? takeStream() {
    if (_stream != null || _finished) {
      return null;
    }
    return _stream = WASIPreview2OutputStream(
      onWrite: (chunk) {
        if (_finished || _chunks.isClosed) {
          return 'stream-closed';
        }
        _chunks.add(chunk);
        return null;
      },
    );
  }

  /// Finishes the body with optional trailers.
  WASIPreview2HttpResult<void> finish(WASIPreview2HttpFields? trailers) {
    if (_finished) {
      return const WASIPreview2HttpResult<void>.error('HTTP-protocol-error');
    }
    _finished = true;
    _trailers = trailers?.immutableClone();
    _stream?.close();
    unawaited(_chunks.close());
    if (!_done.isCompleted) {
      _done.complete(const WASIPreview2HttpResult<void>.ok(null));
    }
    return const WASIPreview2HttpResult<void>.ok(null);
  }

  /// Optional trailers supplied at finish time.
  WASIPreview2HttpFields? get trailers => _trailers;
}

/// Future incoming-response resource.
final class WASIPreview2HttpFutureIncomingResponse {
  /// Creates a pending future response.
  WASIPreview2HttpFutureIncomingResponse(
    Future<WASIPreview2HttpResult<WASIPreview2HttpIncomingResponse>> future,
  ) {
    future.then(
      _complete,
      onError: (Object error, StackTrace stackTrace) {
        _complete(
          WASIPreview2HttpResult<WASIPreview2HttpIncomingResponse>.error(
            'internal-error',
          ),
        );
      },
    );
  }

  /// Creates an already-completed future response.
  WASIPreview2HttpFutureIncomingResponse.completed(
    WASIPreview2HttpResult<WASIPreview2HttpIncomingResponse> result,
  ) : _result = result;

  WASIPreview2HttpResult<WASIPreview2HttpIncomingResponse>? _result;
  final List<Completer<void>> _waiters = <Completer<void>>[];
  bool _taken = false;

  /// Whether the response is ready.
  bool get isReady => _result != null;

  /// Waits for readiness.
  Future<void> waitReady() {
    if (isReady) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  _WASIPreview2HttpFutureRead<WASIPreview2HttpIncomingResponse>? _take() {
    final result = _result;
    if (result == null) {
      return null;
    }
    if (_taken) {
      return const _WASIPreview2HttpFutureRead<
        WASIPreview2HttpIncomingResponse
      >.taken();
    }
    _taken = true;
    return _WASIPreview2HttpFutureRead<WASIPreview2HttpIncomingResponse>.value(
      result,
    );
  }

  void _complete(
    WASIPreview2HttpResult<WASIPreview2HttpIncomingResponse> result,
  ) {
    if (_result != null) {
      return;
    }
    _result = result;
    final waiters = List<Completer<void>>.of(_waiters);
    _waiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }
}

/// Future trailers resource.
final class WASIPreview2HttpFutureTrailers {
  /// Creates pending future trailers.
  WASIPreview2HttpFutureTrailers(
    Future<WASIPreview2HttpResult<WASIPreview2HttpFields?>> future,
  ) {
    future.then(
      _complete,
      onError: (Object error, StackTrace stackTrace) {
        _complete(
          const WASIPreview2HttpResult<WASIPreview2HttpFields?>.error(
            'internal-error',
          ),
        );
      },
    );
  }

  /// Creates completed future trailers.
  WASIPreview2HttpFutureTrailers.completed(
    WASIPreview2HttpResult<WASIPreview2HttpFields?> result,
  ) : _result = result;

  WASIPreview2HttpResult<WASIPreview2HttpFields?>? _result;
  final List<Completer<void>> _waiters = <Completer<void>>[];
  bool _taken = false;

  /// Whether the trailers are ready.
  bool get isReady => _result != null;

  /// Waits for readiness.
  Future<void> waitReady() {
    if (isReady) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  _WASIPreview2HttpFutureRead<WASIPreview2HttpFields?>? _take() {
    final result = _result;
    if (result == null) {
      return null;
    }
    if (_taken) {
      return const _WASIPreview2HttpFutureRead<WASIPreview2HttpFields?>.taken();
    }
    _taken = true;
    return _WASIPreview2HttpFutureRead<WASIPreview2HttpFields?>.value(result);
  }

  void _complete(WASIPreview2HttpResult<WASIPreview2HttpFields?> result) {
    if (_result != null) {
      return;
    }
    _result = result;
    final waiters = List<Completer<void>>.of(_waiters);
    _waiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }
}

/// Backend used by `wasi:http/outgoing-handler`.
abstract interface class WASIPreview2HttpBackend {
  /// Starts an outgoing HTTP request.
  WASIPreview2HttpResult<WASIPreview2HttpFutureIncomingResponse> handle(
    WASIPreview2HttpOutgoingRequest request,
    WASIPreview2HttpRequestOptions? options,
  );
}

/// Backend that rejects all outgoing requests.
final class WASIPreview2UnsupportedHttpBackend
    implements WASIPreview2HttpBackend {
  /// Creates an unsupported HTTP backend.
  const WASIPreview2UnsupportedHttpBackend();

  @override
  WASIPreview2HttpResult<WASIPreview2HttpFutureIncomingResponse> handle(
    WASIPreview2HttpOutgoingRequest request,
    WASIPreview2HttpRequestOptions? options,
  ) {
    return const WASIPreview2HttpResult<
      WASIPreview2HttpFutureIncomingResponse
    >.error('configuration-error');
  }
}

/// WASI 0.2 `wasi:http` host imports.
base class WASIPreview2HttpHost {
  /// Creates an HTTP host backed by [backend].
  WASIPreview2HttpHost({
    WASIComponentResourceTable? table,
    WASIPreview2PollHost? pollHost,
    WASIPreview2StreamsHost? streamsHost,
    WASIPreview2HttpBackend? backend,
  }) : this._fromParts(
         _resolveHttpHostParts(
           table: table,
           pollHost: pollHost,
           streamsHost: streamsHost,
         ),
         backend ?? const WASIPreview2UnsupportedHttpBackend(),
       );

  WASIPreview2HttpHost._fromParts(
    ({
      WASIComponentResourceTable table,
      WASIPreview2PollHost pollHost,
      WASIPreview2StreamsHost streamsHost,
    })
    parts,
    this.backend,
  ) : table = parts.table,
      pollHost = parts.pollHost,
      streamsHost = parts.streamsHost;

  /// Shared resource table.
  final WASIComponentResourceTable table;

  /// Poll host used by HTTP futures.
  final WASIPreview2PollHost pollHost;

  /// Streams host used by HTTP body resources.
  final WASIPreview2StreamsHost streamsHost;

  /// Outgoing HTTP backend.
  final WASIPreview2HttpBackend backend;

  late final WASIComponentResourceType<WASIPreview2HttpFields> _fieldsType =
      table.defineType<WASIPreview2HttpFields>('wasi:http/types@0.2.0.fields');
  late final WASIComponentResourceType<WASIPreview2HttpIncomingRequest>
  _incomingRequestType = table.defineType<WASIPreview2HttpIncomingRequest>(
    'wasi:http/types@0.2.0.incoming-request',
  );
  late final WASIComponentResourceType<WASIPreview2HttpOutgoingRequest>
  _outgoingRequestType = table.defineType<WASIPreview2HttpOutgoingRequest>(
    'wasi:http/types@0.2.0.outgoing-request',
  );
  late final WASIComponentResourceType<WASIPreview2HttpRequestOptions>
  _requestOptionsType = table.defineType<WASIPreview2HttpRequestOptions>(
    'wasi:http/types@0.2.0.request-options',
  );
  late final WASIComponentResourceType<WASIPreview2HttpResponseOutparam>
  _responseOutparamType = table.defineType<WASIPreview2HttpResponseOutparam>(
    'wasi:http/types@0.2.0.response-outparam',
  );
  late final WASIComponentResourceType<WASIPreview2HttpIncomingResponse>
  _incomingResponseType = table.defineType<WASIPreview2HttpIncomingResponse>(
    'wasi:http/types@0.2.0.incoming-response',
  );
  late final WASIComponentResourceType<WASIPreview2HttpIncomingBody>
  _incomingBodyType = table.defineType<WASIPreview2HttpIncomingBody>(
    'wasi:http/types@0.2.0.incoming-body',
  );
  late final WASIComponentResourceType<WASIPreview2HttpFutureTrailers>
  _futureTrailersType = table.defineType<WASIPreview2HttpFutureTrailers>(
    'wasi:http/types@0.2.0.future-trailers',
  );
  late final WASIComponentResourceType<WASIPreview2HttpOutgoingResponse>
  _outgoingResponseType = table.defineType<WASIPreview2HttpOutgoingResponse>(
    'wasi:http/types@0.2.0.outgoing-response',
  );
  late final WASIComponentResourceType<WASIPreview2HttpOutgoingBody>
  _outgoingBodyType = table.defineType<WASIPreview2HttpOutgoingBody>(
    'wasi:http/types@0.2.0.outgoing-body',
  );
  late final WASIComponentResourceType<WASIPreview2HttpFutureIncomingResponse>
  _futureIncomingResponseType = table
      .defineType<WASIPreview2HttpFutureIncomingResponse>(
        'wasi:http/types@0.2.0.future-incoming-response',
      );

  /// Standard `wasi:http@0.2.0` import callbacks.
  late final Map<String, WASIComponentWitAdapterCallback>
  imports = Map<String, WASIComponentWitAdapterCallback>.unmodifiable({
    'wasi:http/types@0.2.0.http-error-code': (args) =>
        _httpErrorCode(_handle(args.single)),
    'wasi:http/types@0.2.0.fields.constructor': (_) =>
        _insertFields(WASIPreview2HttpFields()),
    'wasi:http/types@0.2.0.fields.from-list': (args) =>
        _fieldsFromList(args.single),
    'wasi:http/types@0.2.0.fields.get': (args) =>
        _fieldsGet(_handle(args[0]), args[1] as String),
    'wasi:http/types@0.2.0.fields.has': (args) =>
        _fields(_handle(args[0])).has(args[1] as String),
    'wasi:http/types@0.2.0.fields.set': (args) => _headerMutationResult(
      _fields(
        _handle(args[0]),
      ).set(args[1] as String, _fieldValuesFromData(args[2])),
    ),
    'wasi:http/types@0.2.0.fields.delete': (args) => _headerMutationResult(
      _fields(_handle(args[0])).delete(args[1] as String),
    ),
    'wasi:http/types@0.2.0.fields.append': (args) => _headerMutationResult(
      _fields(
        _handle(args[0]),
      ).append(args[1] as String, _u8ListFromData(args[2])),
    ),
    'wasi:http/types@0.2.0.fields.entries': (args) =>
        _fieldsEntriesData(_fields(_handle(args.single)).entries),
    'wasi:http/types@0.2.0.fields.clone': (args) =>
        _insertFields(_fields(_handle(args.single)).mutableClone()),
    'wasi:http/types@0.2.0.incoming-request.method': (args) =>
        _methodData(_incomingRequest(_handle(args.single)).method),
    'wasi:http/types@0.2.0.incoming-request.path-with-query': (args) =>
        _optionalString(_incomingRequest(_handle(args.single)).pathWithQuery),
    'wasi:http/types@0.2.0.incoming-request.scheme': (args) =>
        _optionalScheme(_incomingRequest(_handle(args.single)).scheme),
    'wasi:http/types@0.2.0.incoming-request.authority': (args) =>
        _optionalString(_incomingRequest(_handle(args.single)).authority),
    'wasi:http/types@0.2.0.incoming-request.headers': (args) =>
        _insertFields(_incomingRequest(_handle(args.single)).headers),
    'wasi:http/types@0.2.0.incoming-request.consume': (args) =>
        _incomingBodyResult(_incomingRequest(_handle(args.single)).consume()),
    'wasi:http/types@0.2.0.outgoing-request.constructor': (args) =>
        _insertOutgoingRequest(
          WASIPreview2HttpOutgoingRequest(_fields(_handle(args.single))),
        ),
    'wasi:http/types@0.2.0.outgoing-request.body': (args) =>
        _outgoingBodyResult(_outgoingRequest(_handle(args.single)).takeBody()),
    'wasi:http/types@0.2.0.outgoing-request.method': (args) =>
        _methodData(_outgoingRequest(_handle(args.single)).method),
    'wasi:http/types@0.2.0.outgoing-request.set-method': (args) =>
        _setRequestMethod(_handle(args[0]), args[1]),
    'wasi:http/types@0.2.0.outgoing-request.path-with-query': (args) =>
        _optionalString(_outgoingRequest(_handle(args.single)).pathWithQuery),
    'wasi:http/types@0.2.0.outgoing-request.set-path-with-query': (args) =>
        _setRequestPath(_handle(args[0]), args[1]),
    'wasi:http/types@0.2.0.outgoing-request.scheme': (args) =>
        _optionalScheme(_outgoingRequest(_handle(args.single)).scheme),
    'wasi:http/types@0.2.0.outgoing-request.set-scheme': (args) =>
        _setRequestScheme(_handle(args[0]), args[1]),
    'wasi:http/types@0.2.0.outgoing-request.authority': (args) =>
        _optionalString(_outgoingRequest(_handle(args.single)).authority),
    'wasi:http/types@0.2.0.outgoing-request.set-authority': (args) =>
        _setRequestAuthority(_handle(args[0]), args[1]),
    'wasi:http/types@0.2.0.outgoing-request.headers': (args) =>
        _insertFields(_outgoingRequest(_handle(args.single)).headers),
    'wasi:http/types@0.2.0.request-options.constructor': (_) =>
        _insertRequestOptions(WASIPreview2HttpRequestOptions()),
    'wasi:http/types@0.2.0.request-options.connect-timeout': (args) =>
        _optionalDuration(_requestOptions(_handle(args.single)).connectTimeout),
    'wasi:http/types@0.2.0.request-options.set-connect-timeout': (args) {
      _requestOptions(_handle(args[0])).connectTimeout =
          _optionalDurationFromData(args[1]);
      return _unitOk();
    },
    'wasi:http/types@0.2.0.request-options.first-byte-timeout': (args) =>
        _optionalDuration(
          _requestOptions(_handle(args.single)).firstByteTimeout,
        ),
    'wasi:http/types@0.2.0.request-options.set-first-byte-timeout': (args) {
      _requestOptions(_handle(args[0])).firstByteTimeout =
          _optionalDurationFromData(args[1]);
      return _unitOk();
    },
    'wasi:http/types@0.2.0.request-options.between-bytes-timeout': (args) =>
        _optionalDuration(
          _requestOptions(_handle(args.single)).betweenBytesTimeout,
        ),
    'wasi:http/types@0.2.0.request-options.set-between-bytes-timeout': (args) {
      _requestOptions(_handle(args[0])).betweenBytesTimeout =
          _optionalDurationFromData(args[1]);
      return _unitOk();
    },
    'wasi:http/types@0.2.0.response-outparam.send-informational': (args) =>
        _sendInformational(_handle(args[0]), _u16(args[1]), _handle(args[2])),
    'wasi:http/types@0.2.0.response-outparam.set': (args) {
      _setResponseOutparam(_handle(args[0]), args[1]);
      return null;
    },
    'wasi:http/types@0.2.0.incoming-response.status': (args) =>
        _incomingResponse(_handle(args.single)).status,
    'wasi:http/types@0.2.0.incoming-response.headers': (args) =>
        _insertFields(_incomingResponse(_handle(args.single)).headers),
    'wasi:http/types@0.2.0.incoming-response.consume': (args) =>
        _incomingBodyResult(_incomingResponse(_handle(args.single)).consume()),
    'wasi:http/types@0.2.0.incoming-body.%stream': (args) =>
        _inputStreamResult(_incomingBody(_handle(args.single)).takeStream()),
    'wasi:http/types@0.2.0.incoming-body.finish': (args) =>
        _insertFutureTrailers(_incomingBody(_handle(args.single)).finish()),
    'wasi:http/types@0.2.0.future-trailers.subscribe': (args) =>
        _subscribeTrailers(_handle(args.single)),
    'wasi:http/types@0.2.0.future-trailers.get': (args) =>
        _futureTrailersGet(_handle(args.single)),
    'wasi:http/types@0.2.0.outgoing-response.constructor': (args) =>
        _insertOutgoingResponse(
          WASIPreview2HttpOutgoingResponse(_fields(_handle(args.single))),
        ),
    'wasi:http/types@0.2.0.outgoing-response.status-code': (args) =>
        _outgoingResponse(_handle(args.single)).statusCode,
    'wasi:http/types@0.2.0.outgoing-response.set-status-code': (args) =>
        _setResponseStatus(_handle(args[0]), _u16(args[1])),
    'wasi:http/types@0.2.0.outgoing-response.headers': (args) =>
        _insertFields(_outgoingResponse(_handle(args.single)).headers),
    'wasi:http/types@0.2.0.outgoing-response.body': (args) =>
        _outgoingBodyResult(_outgoingResponse(_handle(args.single)).takeBody()),
    'wasi:http/types@0.2.0.outgoing-body.write': (args) =>
        _outputStreamResult(_outgoingBody(_handle(args.single)).takeStream()),
    'wasi:http/types@0.2.0.outgoing-body.finish': (args) =>
        _outgoingBodyFinish(_handle(args[0]), args[1]),
    'wasi:http/types@0.2.0.future-incoming-response.subscribe': (args) =>
        _subscribeIncomingResponse(_handle(args.single)),
    'wasi:http/types@0.2.0.future-incoming-response.get': (args) =>
        _futureIncomingResponseGet(_handle(args.single)),
    'wasi:http/outgoing-handler@0.2.0.handle': (args) =>
        _handleOutgoing(_handle(args[0]), _optionalRequestOptions(args[1])),
  });

  /// Inserts [fields] and returns a resource handle.
  int insertFields(WASIPreview2HttpFields fields) => _insertFields(fields);

  /// Inserts [request] and returns a resource handle.
  int insertIncomingRequest(WASIPreview2HttpIncomingRequest request) => table
      .insert<WASIPreview2HttpIncomingRequest>(_incomingRequestType, request);

  /// Inserts [outparam] and returns a resource handle.
  int insertResponseOutparam(WASIPreview2HttpResponseOutparam outparam) =>
      table.insert<WASIPreview2HttpResponseOutparam>(
        _responseOutparamType,
        outparam,
      );

  int _insertFields(WASIPreview2HttpFields fields) =>
      table.insert<WASIPreview2HttpFields>(_fieldsType, fields);

  int _insertOutgoingRequest(WASIPreview2HttpOutgoingRequest request) => table
      .insert<WASIPreview2HttpOutgoingRequest>(_outgoingRequestType, request);

  int _insertRequestOptions(WASIPreview2HttpRequestOptions options) => table
      .insert<WASIPreview2HttpRequestOptions>(_requestOptionsType, options);

  int _insertIncomingResponse(WASIPreview2HttpIncomingResponse response) =>
      table.insert<WASIPreview2HttpIncomingResponse>(
        _incomingResponseType,
        response,
      );

  int _insertIncomingBody(WASIPreview2HttpIncomingBody body) =>
      table.insert<WASIPreview2HttpIncomingBody>(_incomingBodyType, body);

  int _insertFutureTrailers(WASIPreview2HttpFutureTrailers trailers) => table
      .insert<WASIPreview2HttpFutureTrailers>(_futureTrailersType, trailers);

  int _insertOutgoingResponse(WASIPreview2HttpOutgoingResponse response) =>
      table.insert<WASIPreview2HttpOutgoingResponse>(
        _outgoingResponseType,
        response,
      );

  int _insertOutgoingBody(WASIPreview2HttpOutgoingBody body) =>
      table.insert<WASIPreview2HttpOutgoingBody>(_outgoingBodyType, body);

  int _insertFutureIncomingResponse(
    WASIPreview2HttpFutureIncomingResponse response,
  ) => table.insert<WASIPreview2HttpFutureIncomingResponse>(
    _futureIncomingResponseType,
    response,
  );

  WASIPreview2HttpFields _fields(int handle) =>
      table.get<WASIPreview2HttpFields>(_fieldsType, handle);

  WASIPreview2HttpIncomingRequest _incomingRequest(int handle) =>
      table.get<WASIPreview2HttpIncomingRequest>(_incomingRequestType, handle);

  WASIPreview2HttpOutgoingRequest _outgoingRequest(int handle) =>
      table.get<WASIPreview2HttpOutgoingRequest>(_outgoingRequestType, handle);

  WASIPreview2HttpRequestOptions _requestOptions(int handle) =>
      table.get<WASIPreview2HttpRequestOptions>(_requestOptionsType, handle);

  WASIPreview2HttpResponseOutparam _responseOutparam(int handle) => table
      .get<WASIPreview2HttpResponseOutparam>(_responseOutparamType, handle);

  WASIPreview2HttpIncomingResponse _incomingResponse(int handle) => table
      .get<WASIPreview2HttpIncomingResponse>(_incomingResponseType, handle);

  WASIPreview2HttpIncomingBody _incomingBody(int handle) =>
      table.get<WASIPreview2HttpIncomingBody>(_incomingBodyType, handle);

  WASIPreview2HttpFutureTrailers _futureTrailers(int handle) =>
      table.get<WASIPreview2HttpFutureTrailers>(_futureTrailersType, handle);

  WASIPreview2HttpOutgoingResponse _outgoingResponse(int handle) => table
      .get<WASIPreview2HttpOutgoingResponse>(_outgoingResponseType, handle);

  WASIPreview2HttpOutgoingBody _outgoingBody(int handle) =>
      table.get<WASIPreview2HttpOutgoingBody>(_outgoingBodyType, handle);

  WASIPreview2HttpFutureIncomingResponse _futureIncomingResponse(int handle) =>
      table.get<WASIPreview2HttpFutureIncomingResponse>(
        _futureIncomingResponseType,
        handle,
      );

  WasmComponentValueData _httpErrorCode(int handle) {
    final debugString = streamsHost.errorHost.debugString(handle);
    final code = _httpErrorCodeFromDebugString(debugString);
    return code == null ? _none() : _some(_errorCodeData(code));
  }

  WasmComponentValueData _fieldsFromList(Object? value) {
    final entries = _fieldEntriesFromData(value);
    final invalid = entries.any(
      (entry) => !_validFieldName(entry.name) || !_validFieldValue(entry.value),
    );
    if (invalid) {
      return _result(false, _headerErrorData('invalid-syntax'));
    }
    return _ok(
      _integerData(_insertFields(WASIPreview2HttpFields(entries: entries))),
    );
  }

  WasmComponentValueData _fieldsGet(int handle, String name) {
    return _list([
      for (final value in _fields(handle).values(name)) _u8ListData(value),
    ]);
  }

  WasmComponentValueData _setRequestMethod(int handle, Object? value) {
    final method = _methodFromData(value);
    if (method == null || !_validMethod(method.wireName)) {
      return _unitError();
    }
    _outgoingRequest(handle).method = method;
    return _unitOk();
  }

  WasmComponentValueData _setRequestPath(int handle, Object? value) {
    final path = _optionalStringFromData(value);
    if (path != null && (path.contains('\r') || path.contains('\n'))) {
      return _unitError();
    }
    _outgoingRequest(handle).pathWithQuery = path;
    return _unitOk();
  }

  WasmComponentValueData _setRequestScheme(int handle, Object? value) {
    final scheme = _optionalSchemeFromData(value);
    if (scheme != null && !_validScheme(scheme.wireName)) {
      return _unitError();
    }
    _outgoingRequest(handle).scheme = scheme;
    return _unitOk();
  }

  WasmComponentValueData _setRequestAuthority(int handle, Object? value) {
    final authority = _optionalStringFromData(value);
    if (authority != null &&
        (authority.isEmpty ||
            authority.contains('/') ||
            authority.contains('\r') ||
            authority.contains('\n'))) {
      return _unitError();
    }
    _outgoingRequest(handle).authority = authority;
    return _unitOk();
  }

  WasmComponentValueData _setResponseStatus(int handle, int status) {
    if (status < 100 || status > 999) {
      return _unitError();
    }
    _outgoingResponse(handle).statusCode = status;
    return _unitOk();
  }

  WasmComponentValueData _incomingBodyResult(
    WASIPreview2HttpIncomingBody? body,
  ) {
    if (body == null) {
      return _unitError();
    }
    return _ok(_integerData(_insertIncomingBody(body)));
  }

  WasmComponentValueData _outgoingBodyResult(
    WASIPreview2HttpOutgoingBody? body,
  ) {
    if (body == null) {
      return _unitError();
    }
    return _ok(_integerData(_insertOutgoingBody(body)));
  }

  WasmComponentValueData _inputStreamResult(WASIPreview2InputStream? stream) {
    if (stream == null) {
      return _unitError();
    }
    return _ok(_integerData(streamsHost.insertInputStream(stream)));
  }

  WasmComponentValueData _outputStreamResult(WASIPreview2OutputStream? stream) {
    if (stream == null) {
      return _unitError();
    }
    return _ok(_integerData(streamsHost.insertOutputStream(stream)));
  }

  WasmComponentValueData _outgoingBodyFinish(
    int handle,
    Object? trailersValue,
  ) {
    final trailers = _optionalFields(trailersValue);
    final result = _outgoingBody(handle).finish(trailers);
    return result.isOk ? _unitOk() : _errorCodeResult(result.errorCode!);
  }

  WasmComponentValueData _sendInformational(
    int outparamHandle,
    int status,
    int headersHandle,
  ) {
    final result = _responseOutparam(
      outparamHandle,
    ).sendInformational(status, _fields(headersHandle));
    return result.isOk ? _unitOk() : _errorCodeResult(result.errorCode!);
  }

  int _subscribeTrailers(int handle) {
    final trailers = _futureTrailers(handle);
    return pollHost.insert(
      WASIPreview2Pollable(
        isReady: () => trailers.isReady,
        waitReady: trailers.waitReady,
      ),
    );
  }

  WasmComponentValueData _futureTrailersGet(int handle) {
    final read = _futureTrailers(handle)._take();
    if (read == null) {
      return _none();
    }
    if (read.alreadyTaken) {
      return _some(_unitError());
    }
    final result = read.value!;
    final inner = result.isOk
        ? _ok(_optionalFieldsResourceData(result.value))
        : _errorCodeResult(result.errorCode!);
    return _some(_ok(inner));
  }

  int _subscribeIncomingResponse(int handle) {
    final response = _futureIncomingResponse(handle);
    return pollHost.insert(
      WASIPreview2Pollable(
        isReady: () => response.isReady,
        waitReady: response.waitReady,
      ),
    );
  }

  WasmComponentValueData _futureIncomingResponseGet(int handle) {
    final read = _futureIncomingResponse(handle)._take();
    if (read == null) {
      return _none();
    }
    if (read.alreadyTaken) {
      return _some(_unitError());
    }
    final result = read.value!;
    final inner = result.isOk
        ? _ok(_integerData(_insertIncomingResponse(result.value!)))
        : _errorCodeResult(result.errorCode!);
    return _some(_ok(inner));
  }

  WasmComponentValueData _handleOutgoing(
    int requestHandle,
    WASIPreview2HttpRequestOptions? options,
  ) {
    final result = backend.handle(_outgoingRequest(requestHandle), options);
    if (!result.isOk) {
      return _errorCodeResult(result.errorCode!);
    }
    return _ok(_integerData(_insertFutureIncomingResponse(result.value!)));
  }

  void _setResponseOutparam(int handle, Object? value) {
    final outparam = _responseOutparam(handle);
    final result = _outgoingResponseResultFromData(value);
    outparam.set(result);
  }

  WasmComponentValueData _optionalFieldsResourceData(
    WASIPreview2HttpFields? fields,
  ) {
    if (fields == null) {
      return _none();
    }
    return _some(_integerData(_insertFields(fields.immutableClone())));
  }

  WASIPreview2HttpResult<WASIPreview2HttpOutgoingResponse>
  _outgoingResponseResultFromData(Object? value) {
    final data = _resultData(value);
    if (!_resultIsOk(data)) {
      return WASIPreview2HttpResult<WASIPreview2HttpOutgoingResponse>.error(
        _errorCodeFromData(data.associatedValue),
      );
    }
    return WASIPreview2HttpResult<WASIPreview2HttpOutgoingResponse>.ok(
      _outgoingResponse(_handle(data.associatedValue)),
    );
  }

  WASIPreview2HttpRequestOptions? _optionalRequestOptions(Object? value) {
    final data = _optionData(value);
    if (!_optionIsSome(data)) {
      return null;
    }
    return _requestOptions(_handle(data.associatedValue));
  }

  WASIPreview2HttpFields? _optionalFields(Object? value) {
    final data = _optionData(value);
    if (!_optionIsSome(data)) {
      return null;
    }
    return _fields(_handle(data.associatedValue));
  }

  WasmComponentValueData _headerMutationResult(String? error) =>
      error == null ? _unitOk() : _result(false, _headerErrorData(error));
}

final class _WASIPreview2HttpFutureRead<T> {
  const _WASIPreview2HttpFutureRead.value(this.value) : alreadyTaken = false;

  const _WASIPreview2HttpFutureRead.taken() : value = null, alreadyTaken = true;

  final WASIPreview2HttpResult<T>? value;
  final bool alreadyTaken;
}

({
  WASIComponentResourceTable table,
  WASIPreview2PollHost pollHost,
  WASIPreview2StreamsHost streamsHost,
})
_resolveHttpHostParts({
  WASIComponentResourceTable? table,
  WASIPreview2PollHost? pollHost,
  WASIPreview2StreamsHost? streamsHost,
}) {
  final resolvedTable =
      table ??
      streamsHost?.table ??
      pollHost?.table ??
      WASIComponentResourceTable();
  if (pollHost != null && !identical(resolvedTable, pollHost.table)) {
    throw ArgumentError.value(
      pollHost,
      'pollHost',
      'must use the same component resource table as HTTP',
    );
  }
  if (streamsHost != null && !identical(resolvedTable, streamsHost.table)) {
    throw ArgumentError.value(
      streamsHost,
      'streamsHost',
      'must use the same component resource table as HTTP',
    );
  }
  final resolvedPollHost =
      pollHost ??
      streamsHost?.pollHost ??
      WASIPreview2PollHost(table: resolvedTable);
  final resolvedStreamsHost =
      streamsHost ??
      WASIPreview2StreamsHost(table: resolvedTable, pollHost: resolvedPollHost);
  return (
    table: resolvedTable,
    pollHost: resolvedPollHost,
    streamsHost: resolvedStreamsHost,
  );
}

WASIPreview2HttpMethod? _methodFromData(Object? value) {
  final data = _variantData(value);
  final label = data.label ?? _caseLabel(_httpMethodCases, data.index);
  if (label == 'other') {
    final token = _stringFromData(data.associatedValue);
    return token == null ? null : WASIPreview2HttpMethod.other(token);
  }
  if (_httpMethodCases.contains(label)) {
    return WASIPreview2HttpMethod.standard(label);
  }
  return null;
}

WasmComponentValueData _methodData(WASIPreview2HttpMethod method) {
  final index = _httpMethodCases.indexOf(method.label);
  return _variant(
    method.label,
    index,
    method.other == null ? null : _stringData(method.other!),
  );
}

WASIPreview2HttpScheme? _schemeFromData(Object? value) {
  final data = _variantData(value);
  final label = data.label ?? _caseLabel(_httpSchemeCases, data.index);
  if (label == 'other') {
    final scheme = _stringFromData(data.associatedValue);
    return scheme == null ? null : WASIPreview2HttpScheme.other(scheme);
  }
  if (label == 'HTTP' || label == 'HTTPS') {
    return WASIPreview2HttpScheme.standard(label);
  }
  return null;
}

WasmComponentValueData _schemeData(WASIPreview2HttpScheme scheme) {
  final index = _httpSchemeCases.indexOf(scheme.label);
  return _variant(
    scheme.label,
    index,
    scheme.other == null ? null : _stringData(scheme.other!),
  );
}

WASIPreview2HttpScheme? _optionalSchemeFromData(Object? value) {
  final data = _optionData(value);
  return _optionIsSome(data) ? _schemeFromData(data.associatedValue) : null;
}

WasmComponentValueData _optionalScheme(WASIPreview2HttpScheme? scheme) =>
    scheme == null ? _none() : _some(_schemeData(scheme));

String? _optionalStringFromData(Object? value) {
  final data = _optionData(value);
  return _optionIsSome(data) ? _stringFromData(data.associatedValue) : null;
}

WasmComponentValueData _optionalString(String? value) =>
    value == null ? _none() : _some(_stringData(value));

BigInt? _optionalDurationFromData(Object? value) {
  final data = _optionData(value);
  return _optionIsSome(data) ? _u64(data.associatedValue) : null;
}

WasmComponentValueData _optionalDuration(BigInt? value) =>
    value == null ? _none() : _some(_integerData(value));

List<WASIPreview2HttpFieldEntry> _fieldEntriesFromData(Object? value) {
  final list = _listData(value);
  return [
    for (final item in list.items)
      WASIPreview2HttpFieldEntry(
        _stringFromData(_tupleData(item).items[0])!,
        _u8ListFromData(_tupleData(item).items[1]),
      ),
  ];
}

List<List<int>> _fieldValuesFromData(Object? value) {
  final list = _listData(value);
  return [for (final item in list.items) _u8ListFromData(item)];
}

WasmComponentValueData _fieldsEntriesData(
  List<WASIPreview2HttpFieldEntry> entries,
) {
  return _list([
    for (final entry in entries)
      _tuple(<WasmComponentValueData>[
        _stringData(entry.name),
        _u8ListData(entry.value),
      ]),
  ]);
}

String _errorCodeFromData(Object? value) {
  final data = _variantData(value);
  return data.label ?? _caseLabel(_httpErrorCodeCases, data.index);
}

String? _httpErrorCodeFromDebugString(String debugString) {
  if (_httpErrorCodeCases.contains(debugString)) {
    return debugString;
  }
  final normalized = debugString.toLowerCase();
  if (normalized.contains('response') && normalized.contains('timeout')) {
    return 'HTTP-response-timeout';
  }
  if (normalized.contains('connection') && normalized.contains('timeout')) {
    return 'connection-timeout';
  }
  if (normalized.contains('connection') && normalized.contains('refused')) {
    return 'connection-refused';
  }
  if (normalized.contains('dns')) {
    return 'DNS-error';
  }
  return null;
}

WasmComponentValueData _errorCodeResult(String code) =>
    _result(false, _errorCodeData(code));

WasmComponentValueData _errorCodeData(String code) {
  final index = _httpErrorCodeCases.indexOf(code);
  return _variant(code, index < 0 ? _httpErrorCodeCases.length - 1 : index);
}

WasmComponentValueData _headerErrorData(String code) {
  final index = _headerErrorCases.indexOf(code);
  return _variant(code, index < 0 ? 0 : index);
}

WasmComponentValueData _ok([WasmComponentValueData? value]) =>
    _result(true, value);

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
    associatedValue: value,
  );
}

WasmComponentValueData _none() {
  return WasmComponentValueData(
    kind: WasmComponentValueDataKind.option,
    rawBytes: Uint8List(0),
    index: 0,
    label: 'none',
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
  return _list([for (final byte in bytes) _integerData(byte)]);
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
  if (value.label != null) {
    return value.label == 'some';
  }
  return value.index == 1;
}

bool _resultIsOk(WasmComponentValueData value) {
  if (value.label != null) {
    return value.label == 'ok';
  }
  return value.index == 0 || value.isOk == true;
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
  return [
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

bool _validScheme(String scheme) {
  if (scheme.isEmpty) {
    return false;
  }
  final first = scheme.codeUnitAt(0);
  if (!_isAlpha(first)) {
    return false;
  }
  for (var i = 1; i < scheme.length; i++) {
    final code = scheme.codeUnitAt(i);
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
  if (name.isEmpty) {
    return false;
  }
  for (var i = 0; i < name.length; i++) {
    final code = name.codeUnitAt(i);
    if (!_isTokenChar(code)) {
      return false;
    }
  }
  return true;
}

bool _validFieldValue(List<int> value) {
  for (final byte in value) {
    if (byte == 9 ||
        (byte >= 32 && byte <= 126) ||
        byte >= 128 && byte <= 255) {
      continue;
    }
    return false;
  }
  return true;
}

bool _isTokenChar(int code) =>
    _isAlpha(code) ||
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

bool _isAlpha(int code) =>
    (code >= 65 && code <= 90) || (code >= 97 && code <= 122);

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
