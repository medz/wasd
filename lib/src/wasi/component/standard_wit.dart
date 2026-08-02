import 'wit_adapter.dart';
import 'wit_document.dart';

/// Resolves checked-in standard WASI WIT packages supported by this host.
WASIComponentWitResolvedTarget? resolveWASIComponentStandardWitTarget(
  String target,
) {
  final parsed = _parseQualifiedWitTarget(target);
  if (parsed == null) {
    return null;
  }
  if (parsed.packageName == 'wasi:random' &&
      _isPreview2PatchVersion(parsed.version)) {
    return WASIComponentWitResolvedTarget(
      document: _preview2Document(
        _wasiRandom020Source,
        'wasi:random',
        parsed.version!,
      ),
      memberName: parsed.memberName,
    );
  }
  if (parsed.packageName == 'wasi:clocks' &&
      _isPreview2PatchVersion(parsed.version)) {
    return WASIComponentWitResolvedTarget(
      document: _preview2Document(
        _wasiClocks020Source,
        'wasi:clocks',
        parsed.version!,
      ),
      memberName: parsed.memberName,
    );
  }
  if (parsed.packageName == 'wasi:io' &&
      _isPreview2PatchVersion(parsed.version)) {
    return WASIComponentWitResolvedTarget(
      document: _preview2Document(_wasiIo020Source, 'wasi:io', parsed.version!),
      memberName: parsed.memberName,
    );
  }
  if (parsed.packageName == 'wasi:cli' &&
      _isPreview2PatchVersion(parsed.version)) {
    return WASIComponentWitResolvedTarget(
      document: _preview2Document(
        _hasStableCliExitWithCode(parsed.version!)
            ? _wasiCli0212Source
            : _wasiCli020Source,
        'wasi:cli',
        parsed.version!,
      ),
      memberName: parsed.memberName,
    );
  }
  if (parsed.packageName == 'wasi:filesystem' &&
      _isPreview2PatchVersion(parsed.version)) {
    return WASIComponentWitResolvedTarget(
      document: _preview2Document(
        _wasiFilesystem020Source,
        'wasi:filesystem',
        parsed.version!,
      ),
      memberName: parsed.memberName,
    );
  }
  if (parsed.packageName == 'wasi:sockets' &&
      _isPreview2PatchVersion(parsed.version)) {
    return WASIComponentWitResolvedTarget(
      document: _preview2Document(
        _wasiSockets020Source,
        'wasi:sockets',
        parsed.version!,
      ),
      memberName: parsed.memberName,
    );
  }
  if (parsed.packageName == 'wasi:http' &&
      _isPreview2PatchVersion(parsed.version)) {
    return WASIComponentWitResolvedTarget(
      document: _preview2Document(
        _wasiHttp020Source,
        'wasi:http',
        parsed.version!,
      ),
      memberName: parsed.memberName,
    );
  }
  if (parsed.packageName == 'wasi:random' && parsed.version == '0.3.0') {
    return WASIComponentWitResolvedTarget(
      document: _wasiRandom030Document,
      memberName: parsed.memberName,
    );
  }
  if (parsed.packageName == 'wasi:clocks' && parsed.version == '0.3.0') {
    return WASIComponentWitResolvedTarget(
      document: _wasiClocks030Document,
      memberName: parsed.memberName,
    );
  }
  if (parsed.packageName == 'wasi:cli' && parsed.version == '0.3.0') {
    return WASIComponentWitResolvedTarget(
      document: _wasiCli030Document,
      memberName: parsed.memberName,
    );
  }
  if (parsed.packageName == 'wasi:filesystem' && parsed.version == '0.3.0') {
    return WASIComponentWitResolvedTarget(
      document: _wasiFilesystem030Document,
      memberName: parsed.memberName,
    );
  }
  return null;
}

bool _isPreview2PatchVersion(String? version) {
  if (version == null) {
    return false;
  }
  final match = RegExp(r'^0\.2\.(\d+)$').firstMatch(version);
  if (match == null) {
    return false;
  }
  final patch = int.tryParse(match.group(1)!);
  return patch != null && patch >= 0 && patch <= 12;
}

bool _hasStableCliExitWithCode(String version) =>
    int.parse(version.substring('0.2.'.length)) >= 12;

final Map<String, WASIComponentWitDocument> _preview2Documents =
    <String, WASIComponentWitDocument>{};

WASIComponentWitDocument _preview2Document(
  String source,
  String packageName,
  String version,
) {
  final key = '$packageName@$version';
  return _preview2Documents.putIfAbsent(
    key,
    () => WASIComponentWitDocument.parse(
      source.replaceAll('@0.2.0', '@$version'),
      sourceName: key,
    ),
  );
}

({String packageName, String memberName, String? version})?
_parseQualifiedWitTarget(String target) {
  final slash = target.indexOf('/');
  if (slash <= 0 || slash + 1 >= target.length) {
    return null;
  }
  final packageName = target.substring(0, slash);
  final memberAndVersion = target.substring(slash + 1);
  final versionSeparator = memberAndVersion.lastIndexOf('@');
  if (versionSeparator <= 0) {
    return (
      packageName: packageName,
      memberName: memberAndVersion,
      version: null,
    );
  }
  return (
    packageName: packageName,
    memberName: memberAndVersion.substring(0, versionSeparator),
    version: memberAndVersion.substring(versionSeparator + 1),
  );
}

final WASIComponentWitDocument _wasiRandom030Document =
    WASIComponentWitDocument.parse(
      _wasiRandom030Source,
      sourceName: 'wasi:random@0.3.0',
    );

final WASIComponentWitDocument _wasiClocks030Document =
    WASIComponentWitDocument.parse(
      _wasiClocks030Source,
      sourceName: 'wasi:clocks@0.3.0',
    );

final WASIComponentWitDocument _wasiCli030Document =
    WASIComponentWitDocument.parse(
      _wasiCli030Source,
      sourceName: 'wasi:cli@0.3.0',
    );

final WASIComponentWitDocument _wasiFilesystem030Document =
    WASIComponentWitDocument.parse(
      _wasiFilesystem030Source,
      sourceName: 'wasi:filesystem@0.3.0',
    );

const String _wasiRandom030Source = '''
package wasi:random@0.3.0;

interface random {
  get-random-bytes: func(max-len: u64) -> list<u8>;
  get-random-u64: func() -> u64;
}

interface insecure {
  get-insecure-random-bytes: func(max-len: u64) -> list<u8>;
  get-insecure-random-u64: func() -> u64;
}

interface insecure-seed {
  get-insecure-seed: func() -> tuple<u64, u64>;
}

world imports {
  import random;
  import insecure;
  import insecure-seed;
}
''';

const String _wasiRandom020Source = '''
package wasi:random@0.2.0;

interface random {
  get-random-bytes: func(len: u64) -> list<u8>;
  get-random-u64: func() -> u64;
}

interface insecure {
  get-insecure-random-bytes: func(len: u64) -> list<u8>;
  get-insecure-random-u64: func() -> u64;
}

interface insecure-seed {
  insecure-seed: func() -> tuple<u64, u64>;
}

world imports {
  import random;
  import insecure;
  import insecure-seed;
}
''';

const String _wasiClocks020Source = '''
package wasi:clocks@0.2.0;

interface monotonic-clock {
  use wasi:io/poll@0.2.0.{pollable};

  type instant = u64;
  type duration = u64;

  now: func() -> instant;
  resolution: func() -> duration;
  subscribe-instant: func(when: instant) -> pollable;
  subscribe-duration: func(when: duration) -> pollable;
}

interface wall-clock {
  record datetime {
    seconds: u64,
    nanoseconds: u32,
  }

  now: func() -> datetime;
  resolution: func() -> datetime;
}

world imports {
  import monotonic-clock;
  import wall-clock;
}
''';

const String _wasiIo020Source = '''
package wasi:io@0.2.0;

interface error {
  resource error {
    to-debug-string: func() -> string;
  }
}

interface poll {
  resource pollable {
    ready: func() -> bool;
    block: func();
  }

  poll: func(in: list<borrow<pollable>>) -> list<u32>;
}

interface streams {
  use error.{error};
  use poll.{pollable};

  variant stream-error {
    last-operation-failed(error),
    closed,
  }

  resource input-stream {
    read: func(len: u64) -> result<list<u8>, stream-error>;
    blocking-read: func(len: u64) -> result<list<u8>, stream-error>;
    skip: func(len: u64) -> result<u64, stream-error>;
    blocking-skip: func(len: u64) -> result<u64, stream-error>;
    subscribe: func() -> pollable;
  }

  resource output-stream {
    check-write: func() -> result<u64, stream-error>;
    write: func(contents: list<u8>) -> result<_, stream-error>;
    blocking-write-and-flush: func(contents: list<u8>) -> result<_, stream-error>;
    flush: func() -> result<_, stream-error>;
    blocking-flush: func() -> result<_, stream-error>;
    subscribe: func() -> pollable;
    write-zeroes: func(len: u64) -> result<_, stream-error>;
    blocking-write-zeroes-and-flush: func(len: u64) -> result<_, stream-error>;
    splice: func(src: borrow<input-stream>, len: u64) -> result<u64, stream-error>;
    blocking-splice: func(src: borrow<input-stream>, len: u64) -> result<u64, stream-error>;
  }
}

world imports {
  import streams;
  import poll;
}
''';

const String _wasiCli020Source = '''
package wasi:cli@0.2.0;

interface environment {
  get-environment: func() -> list<tuple<string, string>>;
  get-arguments: func() -> list<string>;
  initial-cwd: func() -> option<string>;
}

interface exit {
  exit: func(status: result);
}

interface run {
  run: func() -> result;
}

interface stdin {
  use wasi:io/streams@0.2.0.{input-stream};

  get-stdin: func() -> input-stream;
}

interface stdout {
  use wasi:io/streams@0.2.0.{output-stream};

  get-stdout: func() -> output-stream;
}

interface stderr {
  use wasi:io/streams@0.2.0.{output-stream};

  get-stderr: func() -> output-stream;
}

interface terminal-input {
  resource terminal-input;
}

interface terminal-output {
  resource terminal-output;
}

interface terminal-stdin {
  use terminal-input.{terminal-input};

  get-terminal-stdin: func() -> option<terminal-input>;
}

interface terminal-stdout {
  use terminal-output.{terminal-output};

  get-terminal-stdout: func() -> option<terminal-output>;
}

interface terminal-stderr {
  use terminal-output.{terminal-output};

  get-terminal-stderr: func() -> option<terminal-output>;
}

world imports {
  include wasi:clocks/imports@0.2.0;
  include wasi:filesystem/imports@0.2.0;
  include wasi:sockets/imports@0.2.0;
  include wasi:random/imports@0.2.0;
  include wasi:io/imports@0.2.0;

  import environment;
  import exit;
  import stdin;
  import stdout;
  import stderr;
  import terminal-input;
  import terminal-output;
  import terminal-stdin;
  import terminal-stdout;
  import terminal-stderr;
}

world command {
  include imports;

  export run;
}
''';

const String _wasiCliExitSignature = '  exit: func(status: result);';

final String _wasiCli0212Source = _replaceRequired(
  _wasiCli020Source,
  _wasiCliExitSignature,
  '''$_wasiCliExitSignature
  exit-with-code: func(status-code: u8);''',
);

String _replaceRequired(String source, String pattern, String replacement) {
  if (!source.contains(pattern)) {
    throw StateError('Required standard WIT declaration is missing: $pattern');
  }
  return source.replaceFirst(pattern, replacement);
}

const String _wasiSockets020Source = '''
package wasi:sockets@0.2.0;

interface network {
  resource network;

  enum error-code {
    unknown,
    access-denied,
    not-supported,
    invalid-argument,
    out-of-memory,
    timeout,
    concurrency-conflict,
    not-in-progress,
    would-block,
    invalid-state,
    new-socket-limit,
    address-not-bindable,
    address-in-use,
    remote-unreachable,
    connection-refused,
    connection-reset,
    connection-aborted,
    datagram-too-large,
    name-unresolvable,
    temporary-resolver-failure,
    permanent-resolver-failure,
  }

  enum ip-address-family {
    ipv4,
    ipv6,
  }

  type ipv4-address = tuple<u8, u8, u8, u8>;
  type ipv6-address = tuple<u16, u16, u16, u16, u16, u16, u16, u16>;

  variant ip-address {
    ipv4(ipv4-address),
    ipv6(ipv6-address),
  }

  record ipv4-socket-address {
    port: u16,
    address: ipv4-address,
  }

  record ipv6-socket-address {
    port: u16,
    flow-info: u32,
    address: ipv6-address,
    scope-id: u32,
  }

  variant ip-socket-address {
    ipv4(ipv4-socket-address),
    ipv6(ipv6-socket-address),
  }
}

interface instance-network {
  use network.{network};

  instance-network: func() -> network;
}

interface ip-name-lookup {
  use wasi:io/poll@0.2.0.{pollable};
  use network.{network, error-code, ip-address};

  resolve-addresses: func(network: borrow<network>, name: string) -> result<resolve-address-stream, error-code>;

  resource resolve-address-stream {
    resolve-next-address: func() -> result<option<ip-address>, error-code>;
    subscribe: func() -> pollable;
  }
}

interface tcp {
  use wasi:io/streams@0.2.0.{input-stream, output-stream};
  use wasi:io/poll@0.2.0.{pollable};
  use wasi:clocks/monotonic-clock@0.2.0.{duration};
  use network.{network, error-code, ip-socket-address, ip-address-family};

  enum shutdown-type {
    receive,
    send,
    both,
  }

  resource tcp-socket {
    start-bind: func(network: borrow<network>, local-address: ip-socket-address) -> result<_, error-code>;
    finish-bind: func() -> result<_, error-code>;
    start-connect: func(network: borrow<network>, remote-address: ip-socket-address) -> result<_, error-code>;
    finish-connect: func() -> result<tuple<input-stream, output-stream>, error-code>;
    start-listen: func() -> result<_, error-code>;
    finish-listen: func() -> result<_, error-code>;
    accept: func() -> result<tuple<tcp-socket, input-stream, output-stream>, error-code>;
    local-address: func() -> result<ip-socket-address, error-code>;
    remote-address: func() -> result<ip-socket-address, error-code>;
    is-listening: func() -> bool;
    address-family: func() -> ip-address-family;
    set-listen-backlog-size: func(value: u64) -> result<_, error-code>;
    keep-alive-enabled: func() -> result<bool, error-code>;
    set-keep-alive-enabled: func(value: bool) -> result<_, error-code>;
    keep-alive-idle-time: func() -> result<duration, error-code>;
    set-keep-alive-idle-time: func(value: duration) -> result<_, error-code>;
    keep-alive-interval: func() -> result<duration, error-code>;
    set-keep-alive-interval: func(value: duration) -> result<_, error-code>;
    keep-alive-count: func() -> result<u32, error-code>;
    set-keep-alive-count: func(value: u32) -> result<_, error-code>;
    hop-limit: func() -> result<u8, error-code>;
    set-hop-limit: func(value: u8) -> result<_, error-code>;
    receive-buffer-size: func() -> result<u64, error-code>;
    set-receive-buffer-size: func(value: u64) -> result<_, error-code>;
    send-buffer-size: func() -> result<u64, error-code>;
    set-send-buffer-size: func(value: u64) -> result<_, error-code>;
    subscribe: func() -> pollable;
    shutdown: func(shutdown-type: shutdown-type) -> result<_, error-code>;
  }
}

interface tcp-create-socket {
  use network.{error-code, ip-address-family};
  use tcp.{tcp-socket};

  create-tcp-socket: func(address-family: ip-address-family) -> result<tcp-socket, error-code>;
}

interface udp {
  use wasi:io/poll@0.2.0.{pollable};
  use network.{network, error-code, ip-socket-address, ip-address-family};

  record incoming-datagram {
    data: list<u8>,
    remote-address: ip-socket-address,
  }

  record outgoing-datagram {
    data: list<u8>,
    remote-address: option<ip-socket-address>,
  }

  resource udp-socket {
    start-bind: func(network: borrow<network>, local-address: ip-socket-address) -> result<_, error-code>;
    finish-bind: func() -> result<_, error-code>;
    stream: func(remote-address: option<ip-socket-address>) -> result<tuple<incoming-datagram-stream, outgoing-datagram-stream>, error-code>;
    local-address: func() -> result<ip-socket-address, error-code>;
    remote-address: func() -> result<ip-socket-address, error-code>;
    address-family: func() -> ip-address-family;
    unicast-hop-limit: func() -> result<u8, error-code>;
    set-unicast-hop-limit: func(value: u8) -> result<_, error-code>;
    receive-buffer-size: func() -> result<u64, error-code>;
    set-receive-buffer-size: func(value: u64) -> result<_, error-code>;
    send-buffer-size: func() -> result<u64, error-code>;
    set-send-buffer-size: func(value: u64) -> result<_, error-code>;
    subscribe: func() -> pollable;
  }

  resource incoming-datagram-stream {
    receive: func(max-results: u64) -> result<list<incoming-datagram>, error-code>;
    subscribe: func() -> pollable;
  }

  resource outgoing-datagram-stream {
    check-send: func() -> result<u64, error-code>;
    send: func(datagrams: list<outgoing-datagram>) -> result<u64, error-code>;
    subscribe: func() -> pollable;
  }
}

interface udp-create-socket {
  use network.{error-code, ip-address-family};
  use udp.{udp-socket};

  create-udp-socket: func(address-family: ip-address-family) -> result<udp-socket, error-code>;
}

world imports {
  import instance-network;
  import network;
  import udp;
  import udp-create-socket;
  import tcp;
  import tcp-create-socket;
  import ip-name-lookup;
}
''';

const String _wasiHttp020Source = '''
package wasi:http@0.2.0;

interface types {
  use wasi:clocks/monotonic-clock@0.2.0.{duration};
  use wasi:io/streams@0.2.0.{input-stream, output-stream};
  use wasi:io/error@0.2.0.{error as io-error};
  use wasi:io/poll@0.2.0.{pollable};

  variant method {
    get,
    head,
    post,
    put,
    delete,
    connect,
    options,
    trace,
    patch,
    other(string),
  }

  variant scheme {
    HTTP,
    HTTPS,
    other(string),
  }

  variant error-code {
    DNS-timeout,
    DNS-error(DNS-error-payload),
    destination-not-found,
    destination-unavailable,
    destination-IP-prohibited,
    destination-IP-unroutable,
    connection-refused,
    connection-terminated,
    connection-timeout,
    connection-read-timeout,
    connection-write-timeout,
    connection-limit-reached,
    TLS-protocol-error,
    TLS-certificate-error,
    TLS-alert-received(TLS-alert-received-payload),
    HTTP-request-denied,
    HTTP-request-length-required,
    HTTP-request-body-size(option<u64>),
    HTTP-request-method-invalid,
    HTTP-request-URI-invalid,
    HTTP-request-URI-too-long,
    HTTP-request-header-section-size(option<u32>),
    HTTP-request-header-size(option<field-size-payload>),
    HTTP-request-trailer-section-size(option<u32>),
    HTTP-request-trailer-size(field-size-payload),
    HTTP-response-incomplete,
    HTTP-response-header-section-size(option<u32>),
    HTTP-response-header-size(field-size-payload),
    HTTP-response-body-size(option<u64>),
    HTTP-response-trailer-section-size(option<u32>),
    HTTP-response-trailer-size(field-size-payload),
    HTTP-response-transfer-coding(option<string>),
    HTTP-response-content-coding(option<string>),
    HTTP-response-timeout,
    HTTP-upgrade-failed,
    HTTP-protocol-error,
    loop-detected,
    configuration-error,
    internal-error(option<string>),
  }

  record DNS-error-payload {
    rcode: option<string>,
    info-code: option<u16>,
  }

  record TLS-alert-received-payload {
    alert-id: option<u8>,
    alert-message: option<string>,
  }

  record field-size-payload {
    field-name: option<string>,
    field-size: option<u32>,
  }

  http-error-code: func(err: borrow<io-error>) -> option<error-code>;

  variant header-error {
    invalid-syntax,
    forbidden,
    immutable,
  }

  type field-name = field-key;
  type field-key = string;
  type field-value = list<u8>;

  resource fields {
    constructor();
    from-list: static func(entries: list<tuple<field-name, field-value>>) -> result<fields, header-error>;
    get: func(name: field-name) -> list<field-value>;
    has: func(name: field-name) -> bool;
    set: func(name: field-name, value: list<field-value>) -> result<_, header-error>;
    delete: func(name: field-name) -> result<_, header-error>;
    append: func(name: field-name, value: field-value) -> result<_, header-error>;
    entries: func() -> list<tuple<field-name, field-value>>;
    clone: func() -> fields;
  }

  type headers = fields;
  type trailers = fields;

  resource incoming-request {
    method: func() -> method;
    path-with-query: func() -> option<string>;
    scheme: func() -> option<scheme>;
    authority: func() -> option<string>;
    headers: func() -> headers;
    consume: func() -> result<incoming-body>;
  }

  resource outgoing-request {
    constructor(headers: headers);
    body: func() -> result<outgoing-body>;
    method: func() -> method;
    set-method: func(method: method) -> result;
    path-with-query: func() -> option<string>;
    set-path-with-query: func(path-with-query: option<string>) -> result;
    scheme: func() -> option<scheme>;
    set-scheme: func(scheme: option<scheme>) -> result;
    authority: func() -> option<string>;
    set-authority: func(authority: option<string>) -> result;
    headers: func() -> headers;
  }

  resource request-options {
    constructor();
    connect-timeout: func() -> option<duration>;
    set-connect-timeout: func(duration: option<duration>) -> result;
    first-byte-timeout: func() -> option<duration>;
    set-first-byte-timeout: func(duration: option<duration>) -> result;
    between-bytes-timeout: func() -> option<duration>;
    set-between-bytes-timeout: func(duration: option<duration>) -> result;
  }

  resource response-outparam {
    send-informational: func(status: u16, headers: headers) -> result<_, error-code>;
    set: static func(param: response-outparam, response: result<outgoing-response, error-code>);
  }

  type status-code = u16;

  resource incoming-response {
    status: func() -> status-code;
    headers: func() -> headers;
    consume: func() -> result<incoming-body>;
  }

  resource incoming-body {
    %stream: func() -> result<input-stream>;
    finish: static func(this: incoming-body) -> future-trailers;
  }

  resource future-trailers {
    subscribe: func() -> pollable;
    get: func() -> option<result<result<option<trailers>, error-code>>>;
  }

  resource outgoing-response {
    constructor(headers: headers);
    status-code: func() -> status-code;
    set-status-code: func(status-code: status-code) -> result;
    headers: func() -> headers;
    body: func() -> result<outgoing-body>;
  }

  resource outgoing-body {
    write: func() -> result<output-stream>;
    finish: static func(this: outgoing-body, trailers: option<trailers>) -> result<_, error-code>;
  }

  resource future-incoming-response {
    subscribe: func() -> pollable;
    get: func() -> option<result<result<incoming-response, error-code>>>;
  }
}

interface incoming-handler {
  use types.{incoming-request, response-outparam};

  handle: func(request: incoming-request, response-out: response-outparam);
}

interface outgoing-handler {
  use types.{outgoing-request, request-options, future-incoming-response, error-code};

  handle: func(request: outgoing-request, options: option<request-options>) -> result<future-incoming-response, error-code>;
}

world imports {
  import wasi:clocks/monotonic-clock@0.2.0;
  import wasi:clocks/wall-clock@0.2.0;
  import wasi:random/random@0.2.0;
  import wasi:cli/stdout@0.2.0;
  import wasi:cli/stderr@0.2.0;
  import wasi:cli/stdin@0.2.0;
  import outgoing-handler;
}

world proxy {
  include imports;

  export incoming-handler;
}
''';

const String _wasiFilesystem020Source = '''
package wasi:filesystem@0.2.0;

interface types {
  use wasi:io/streams@0.2.0.{input-stream, output-stream};
  use wasi:io/error@0.2.0.{error};
  use wasi:clocks/wall-clock@0.2.0.{datetime};

  type filesize = u64;
  type link-count = u64;

  enum descriptor-type {
    unknown,
    block-device,
    character-device,
    directory,
    fifo,
    symbolic-link,
    regular-file,
    socket,
  }

  flags descriptor-flags {
    read,
    write,
    file-integrity-sync,
    data-integrity-sync,
    requested-write-sync,
    mutate-directory,
  }

  record descriptor-stat {
    type: descriptor-type,
    link-count: link-count,
    size: filesize,
    data-access-timestamp: option<datetime>,
    data-modification-timestamp: option<datetime>,
    status-change-timestamp: option<datetime>,
  }

  flags path-flags {
    symlink-follow,
  }

  flags open-flags {
    create,
    directory,
    exclusive,
    truncate,
  }

  variant new-timestamp {
    no-change,
    now,
    timestamp(datetime),
  }

  record directory-entry {
    type: descriptor-type,
    name: string,
  }

  enum error-code {
    access,
    would-block,
    already,
    bad-descriptor,
    busy,
    deadlock,
    quota,
    exist,
    file-too-large,
    illegal-byte-sequence,
    in-progress,
    interrupted,
    invalid,
    io,
    is-directory,
    loop,
    too-many-links,
    message-size,
    name-too-long,
    no-device,
    no-entry,
    no-lock,
    insufficient-memory,
    insufficient-space,
    not-directory,
    not-empty,
    not-recoverable,
    unsupported,
    no-tty,
    no-such-device,
    overflow,
    not-permitted,
    pipe,
    read-only,
    invalid-seek,
    text-file-busy,
    cross-device,
  }

  enum advice {
    normal,
    sequential,
    random,
    will-need,
    dont-need,
    no-reuse,
  }

  record metadata-hash-value {
    lower: u64,
    upper: u64,
  }

  resource descriptor {
    read-via-stream: func(offset: filesize) -> result<input-stream, error-code>;
    write-via-stream: func(offset: filesize) -> result<output-stream, error-code>;
    append-via-stream: func() -> result<output-stream, error-code>;
    advise: func(offset: filesize, length: filesize, advice: advice) -> result<_, error-code>;
    sync-data: func() -> result<_, error-code>;
    get-flags: func() -> result<descriptor-flags, error-code>;
    get-type: func() -> result<descriptor-type, error-code>;
    set-size: func(size: filesize) -> result<_, error-code>;
    set-times: func(data-access-timestamp: new-timestamp, data-modification-timestamp: new-timestamp) -> result<_, error-code>;
    read: func(length: filesize, offset: filesize) -> result<tuple<list<u8>, bool>, error-code>;
    write: func(buffer: list<u8>, offset: filesize) -> result<filesize, error-code>;
    read-directory: func() -> result<directory-entry-stream, error-code>;
    sync: func() -> result<_, error-code>;
    create-directory-at: func(path: string) -> result<_, error-code>;
    stat: func() -> result<descriptor-stat, error-code>;
    stat-at: func(path-flags: path-flags, path: string) -> result<descriptor-stat, error-code>;
    set-times-at: func(path-flags: path-flags, path: string, data-access-timestamp: new-timestamp, data-modification-timestamp: new-timestamp) -> result<_, error-code>;
    link-at: func(old-path-flags: path-flags, old-path: string, new-descriptor: borrow<descriptor>, new-path: string) -> result<_, error-code>;
    open-at: func(path-flags: path-flags, path: string, open-flags: open-flags, flags: descriptor-flags) -> result<descriptor, error-code>;
    readlink-at: func(path: string) -> result<string, error-code>;
    remove-directory-at: func(path: string) -> result<_, error-code>;
    rename-at: func(old-path: string, new-descriptor: borrow<descriptor>, new-path: string) -> result<_, error-code>;
    symlink-at: func(old-path: string, new-path: string) -> result<_, error-code>;
    unlink-file-at: func(path: string) -> result<_, error-code>;
    is-same-object: func(other: borrow<descriptor>) -> bool;
    metadata-hash: func() -> result<metadata-hash-value, error-code>;
    metadata-hash-at: func(path-flags: path-flags, path: string) -> result<metadata-hash-value, error-code>;
  }

  resource directory-entry-stream {
    read-directory-entry: func() -> result<option<directory-entry>, error-code>;
  }

  filesystem-error-code: func(err: borrow<error>) -> option<error-code>;
}

interface preopens {
  use types.{descriptor};

  get-directories: func() -> list<tuple<descriptor, string>>;
}

world imports {
  import types;
  import preopens;
}
''';

const String _wasiClocks030Source = '''
package wasi:clocks@0.3.0;

interface types {}

interface monotonic-clock {
  now: func() -> u64;
  get-resolution: func() -> u64;
  wait-until: async func(when: u64);
  wait-for: async func(how-long: u64);
}

interface system-clock {
  record instant {
    seconds: s64,
    nanoseconds: u32,
  }

  now: func() -> instant;
  get-resolution: func() -> u64;
}

interface timezone {
  record instant {
    seconds: s64,
    nanoseconds: u32,
  }

  iana-id: func() -> option<string>;
  utc-offset: func(when: instant) -> option<s64>;
  to-debug-string: func() -> string;
}

world imports {
  import types;
  import monotonic-clock;
  import system-clock;
  import timezone;
}
''';

const String _wasiCli030Source = '''
package wasi:cli@0.3.0;

interface environment {
  get-environment: func() -> list<tuple<string, string>>;
  get-arguments: func() -> list<string>;
  get-initial-cwd: func() -> option<string>;
}

interface exit {
  exit: func(status: result);
  exit-with-code: func(status-code: u8);
}

interface run {
  run: async func() -> result;
}

interface types {
  enum error-code {
    io,
    illegal-byte-sequence,
    pipe,
  }
}

interface stdin {
  enum error-code {
    io,
    illegal-byte-sequence,
    pipe,
  }

  read-via-stream: func() -> tuple<stream<u8>, future<result<_, error-code>>>;
}

interface stdout {
  enum error-code {
    io,
    illegal-byte-sequence,
    pipe,
  }

  write-via-stream: func(data: stream<u8>) -> future<result<_, error-code>>;
}

interface stderr {
  enum error-code {
    io,
    illegal-byte-sequence,
    pipe,
  }

  write-via-stream: func(data: stream<u8>) -> future<result<_, error-code>>;
}

interface terminal-input {
  resource terminal-input;
}

interface terminal-output {
  resource terminal-output;
}

interface terminal-stdin {
  resource terminal-input;

  get-terminal-stdin: func() -> option<terminal-input>;
}

interface terminal-stdout {
  resource terminal-output;

  get-terminal-stdout: func() -> option<terminal-output>;
}

interface terminal-stderr {
  resource terminal-output;

  get-terminal-stderr: func() -> option<terminal-output>;
}

world imports {
  import environment;
  import exit;
  import types;
  import stdin;
  import stdout;
  import stderr;
  import terminal-input;
  import terminal-output;
  import terminal-stdin;
  import terminal-stdout;
  import terminal-stderr;
  import wasi:clocks/types@0.3.0;
  import wasi:clocks/monotonic-clock@0.3.0;
  import wasi:clocks/system-clock@0.3.0;
  import wasi:clocks/timezone@0.3.0;
  import wasi:filesystem/types@0.3.0;
  import wasi:filesystem/preopens@0.3.0;
  import wasi:sockets/types@0.3.0;
  import wasi:sockets/ip-name-lookup@0.3.0;
  import wasi:random/random@0.3.0;
  import wasi:random/insecure@0.3.0;
  import wasi:random/insecure-seed@0.3.0;
}

world command {
  import environment;
  import exit;
  import types;
  import stdin;
  import stdout;
  import stderr;
  import terminal-input;
  import terminal-output;
  import terminal-stdin;
  import terminal-stdout;
  import terminal-stderr;
  import wasi:clocks/types@0.3.0;
  import wasi:clocks/monotonic-clock@0.3.0;
  import wasi:clocks/system-clock@0.3.0;
  import wasi:clocks/timezone@0.3.0;
  import wasi:filesystem/types@0.3.0;
  import wasi:filesystem/preopens@0.3.0;
  import wasi:sockets/types@0.3.0;
  import wasi:sockets/ip-name-lookup@0.3.0;
  import wasi:random/random@0.3.0;
  import wasi:random/insecure@0.3.0;
  import wasi:random/insecure-seed@0.3.0;

  export run;
}
''';

const String _wasiFilesystem030Source = '''
package wasi:filesystem@0.3.0;

interface types {
  record instant {
    seconds: s64,
    nanoseconds: u32,
  }

  variant descriptor-type {
    block-device,
    character-device,
    directory,
    fifo,
    symbolic-link,
    regular-file,
    socket,
    other(option<string>),
  }

  flags descriptor-flags {
    read,
    write,
    file-integrity-sync,
    data-integrity-sync,
    requested-write-sync,
    mutate-directory,
  }

  flags path-flags {
    symlink-follow,
  }

  flags open-flags {
    create,
    directory,
    exclusive,
    truncate,
  }

  record descriptor-stat {
    type: descriptor-type,
    link-count: u64,
    size: u64,
    data-access-timestamp: option<instant>,
    data-modification-timestamp: option<instant>,
    status-change-timestamp: option<instant>,
  }

  variant new-timestamp {
    no-change,
    now,
    timestamp(instant),
  }

  record directory-entry {
    type: descriptor-type,
    name: string,
  }

  variant error-code {
    access,
    already,
    bad-descriptor,
    busy,
    deadlock,
    quota,
    exist,
    file-too-large,
    illegal-byte-sequence,
    in-progress,
    interrupted,
    invalid,
    io,
    is-directory,
    loop,
    too-many-links,
    message-size,
    name-too-long,
    no-device,
    no-entry,
    no-lock,
    insufficient-memory,
    insufficient-space,
    not-directory,
    not-empty,
    not-recoverable,
    unsupported,
    no-tty,
    no-such-device,
    overflow,
    not-permitted,
    pipe,
    read-only,
    invalid-seek,
    text-file-busy,
    cross-device,
    other(option<string>),
  }

  enum advice {
    normal,
    sequential,
    random,
    will-need,
    dont-need,
    no-reuse,
  }

  record metadata-hash-value {
    lower: u64,
    upper: u64,
  }

  resource descriptor;

  descriptor {
    read-via-stream: func(self: borrow<descriptor>, offset: u64) -> tuple<stream<u8>, future<result<_, error-code>>>;
    write-via-stream: func(self: borrow<descriptor>, data: stream<u8>, offset: u64) -> future<result<_, error-code>>;
    append-via-stream: func(self: borrow<descriptor>, data: stream<u8>) -> future<result<_, error-code>>;
    advise: async func(self: borrow<descriptor>, offset: u64, length: u64, advice: advice) -> result<_, error-code>;
    sync-data: async func(self: borrow<descriptor>) -> result<_, error-code>;
    get-flags: async func(self: borrow<descriptor>) -> result<descriptor-flags, error-code>;
    get-type: async func(self: borrow<descriptor>) -> result<descriptor-type, error-code>;
    set-size: async func(self: borrow<descriptor>, size: u64) -> result<_, error-code>;
    set-times: async func(self: borrow<descriptor>, data-access-timestamp: new-timestamp, data-modification-timestamp: new-timestamp) -> result<_, error-code>;
    read-directory: func(self: borrow<descriptor>) -> tuple<stream<directory-entry>, future<result<_, error-code>>>;
    sync: async func(self: borrow<descriptor>) -> result<_, error-code>;
    create-directory-at: async func(self: borrow<descriptor>, path: string) -> result<_, error-code>;
    stat: async func(self: borrow<descriptor>) -> result<descriptor-stat, error-code>;
    stat-at: async func(self: borrow<descriptor>, path-flags: path-flags, path: string) -> result<descriptor-stat, error-code>;
    set-times-at: async func(self: borrow<descriptor>, path-flags: path-flags, path: string, data-access-timestamp: new-timestamp, data-modification-timestamp: new-timestamp) -> result<_, error-code>;
    link-at: async func(self: borrow<descriptor>, old-path-flags: path-flags, old-path: string, new-descriptor: borrow<descriptor>, new-path: string) -> result<_, error-code>;
    open-at: async func(self: borrow<descriptor>, path-flags: path-flags, path: string, open-flags: open-flags, flags: descriptor-flags) -> result<descriptor, error-code>;
    readlink-at: async func(self: borrow<descriptor>, path: string) -> result<string, error-code>;
    remove-directory-at: async func(self: borrow<descriptor>, path: string) -> result<_, error-code>;
    rename-at: async func(self: borrow<descriptor>, old-path: string, new-descriptor: borrow<descriptor>, new-path: string) -> result<_, error-code>;
    symlink-at: async func(self: borrow<descriptor>, old-path: string, new-path: string) -> result<_, error-code>;
    unlink-file-at: async func(self: borrow<descriptor>, path: string) -> result<_, error-code>;
    is-same-object: async func(self: borrow<descriptor>, other: borrow<descriptor>) -> bool;
    metadata-hash: async func(self: borrow<descriptor>) -> result<metadata-hash-value, error-code>;
    metadata-hash-at: async func(self: borrow<descriptor>, path-flags: path-flags, path: string) -> result<metadata-hash-value, error-code>;
  }
}

interface preopens {
  resource descriptor;

  get-directories: func() -> list<tuple<descriptor, string>>;
}

world imports {
  import wasi:clocks/types@0.3.0;
  import wasi:clocks/system-clock@0.3.0;
  import types;
  import preopens;
}
''';
