// Vendored from WebAssembly/WASI v0.3.0.
// Upstream commit: 3ee2a590c766594ae44a54730fc74fc27da5c609
// https://github.com/WebAssembly/WASI/tree/3ee2a590c766594ae44a54730fc74fc27da5c609
// Source root: proposals/{random,clocks,filesystem,sockets,cli,http}/wit
// Normalization: each package is concatenated into one parseable WIT
// document with one package declaration and comments omitted. The unstable
// clocks/timezone.wit interface and clocks-timezone world import are omitted.
// Normalized UTF-8 SHA-256 digests:
//   wasi:random: b09b09818eec54f15dff7c1954ae99ee775fa60e14dfd50df33482de773379a0
//   wasi:clocks: 6f439837cf69feb5013e958e662e37dbf5a25ed59af7f0496292d19dae808ab5
//   wasi:filesystem: a0b860ab1712cb0efbe85349447437d0f17db9095c99d62bf10bd3238c2b4421
//   wasi:sockets: 0b27141f74480629f8506fa89c75e3cda2b429c72add5e86d2a4fd1fdb5ace54
//   wasi:cli: 4c88aa3c1abb19864150a35c0d0d4742fc281099eaf3bf46cc939927dc2dc74d
//   wasi:http: 245048008576712e5af4d7b09d91e16c4f7cf6736e2458c4f9f9b4598f3c4400

part of 'standard_wit.dart';

const String _wasiRandom030Source = r'''package wasi:random@0.3.0;

@since(version = 0.3.0)
interface random {
    @since(version = 0.3.0)
    get-random-bytes: func(max-len: u64) -> list<u8>;

    @since(version = 0.3.0)
    get-random-u64: func() -> u64;
}

@since(version = 0.3.0)
interface insecure {
    @since(version = 0.3.0)
    get-insecure-random-bytes: func(max-len: u64) -> list<u8>;

    @since(version = 0.3.0)
    get-insecure-random-u64: func() -> u64;
}

@since(version = 0.3.0)
interface insecure-seed {
    @since(version = 0.3.0)
    get-insecure-seed: func() -> tuple<u64, u64>;
}

@since(version = 0.3.0)
world imports {
    @since(version = 0.3.0)
    import random;

    @since(version = 0.3.0)
    import insecure;

    @since(version = 0.3.0)
    import insecure-seed;
}
''';

const String _wasiClocks030Source = r'''package wasi:clocks@0.3.0;

@since(version = 0.3.0)
interface types {
    @since(version = 0.3.0)
    type duration = u64;
}

@since(version = 0.3.0)
interface monotonic-clock {
    use types.{duration};

    @since(version = 0.3.0)
    type mark = u64;

    @since(version = 0.3.0)
    now: func() -> mark;

    @since(version = 0.3.0)
    get-resolution: func() -> duration;

    @since(version = 0.3.0)
    wait-until: async func(
        when: mark,
    );

    @since(version = 0.3.0)
    wait-for: async func(
        how-long: duration,
    );
}

@since(version = 0.3.0)
interface system-clock {
    use types.{duration};

    @since(version = 0.3.0)
    record instant {
        seconds: s64,
        nanoseconds: u32,
    }

    @since(version = 0.3.0)
    now: func() -> instant;

    @since(version = 0.3.0)
    get-resolution: func() -> duration;
}

@since(version = 0.3.0)
world imports {
    @since(version = 0.3.0)
    import monotonic-clock;
    @since(version = 0.3.0)
    import system-clock;
}
''';

const String _wasiFilesystem030Source = r'''package wasi:filesystem@0.3.0;

@since(version = 0.3.0)
interface types {
    @since(version = 0.3.0)
    use wasi:clocks/system-clock@0.3.0.{instant};

    @since(version = 0.3.0)
    type filesize = u64;

    @since(version = 0.3.0)
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

    @since(version = 0.3.0)
    flags descriptor-flags {
        read,
        write,
        file-integrity-sync,
        data-integrity-sync,
        requested-write-sync,
        mutate-directory,
    }

    @since(version = 0.3.0)
    record descriptor-stat {
        %type: descriptor-type,
        link-count: link-count,
        size: filesize,
        data-access-timestamp: option<instant>,
        data-modification-timestamp: option<instant>,
        status-change-timestamp: option<instant>,
    }

    @since(version = 0.3.0)
    flags path-flags {
        symlink-follow,
    }

    @since(version = 0.3.0)
    flags open-flags {
        create,
        directory,
        exclusive,
        truncate,
    }

    @since(version = 0.3.0)
    type link-count = u64;

    @since(version = 0.3.0)
    variant new-timestamp {
        no-change,
        now,
        timestamp(instant),
    }

    @since(version = 0.3.0)
    record directory-entry {
        %type: descriptor-type,

        name: string,
    }

    @since(version = 0.3.0)
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

    @since(version = 0.3.0)
    enum advice {
        normal,
        sequential,
        random,
        will-need,
        dont-need,
        no-reuse,
    }

    @since(version = 0.3.0)
    record metadata-hash-value {
       lower: u64,
       upper: u64,
    }

    @since(version = 0.3.0)
    resource descriptor {
        @since(version = 0.3.0)
        read-via-stream: func(
            offset: filesize,
        ) -> tuple<stream<u8>, future<result<_, error-code>>>;

        @since(version = 0.3.0)
        write-via-stream: func(
            data: stream<u8>,
            offset: filesize,
        ) -> future<result<_, error-code>>;

        @since(version = 0.3.0)
        append-via-stream: func(data: stream<u8>) -> future<result<_, error-code>>;

        @since(version = 0.3.0)
        advise: async func(
            offset: filesize,
            length: filesize,
            advice: advice
        ) -> result<_, error-code>;

        @since(version = 0.3.0)
        sync-data: async func() -> result<_, error-code>;

        @since(version = 0.3.0)
        get-flags: async func() -> result<descriptor-flags, error-code>;

        @since(version = 0.3.0)
        get-type: async func() -> result<descriptor-type, error-code>;

        @since(version = 0.3.0)
        set-size: async func(size: filesize) -> result<_, error-code>;

        @since(version = 0.3.0)
        set-times: async func(
            data-access-timestamp: new-timestamp,
            data-modification-timestamp: new-timestamp,
        ) -> result<_, error-code>;

        @since(version = 0.3.0)
        read-directory: func() -> tuple<stream<directory-entry>, future<result<_, error-code>>>;

        @since(version = 0.3.0)
        sync: async func() -> result<_, error-code>;

        @since(version = 0.3.0)
        create-directory-at: async func(
            path: string,
        ) -> result<_, error-code>;

        @since(version = 0.3.0)
        stat: async func() -> result<descriptor-stat, error-code>;

        @since(version = 0.3.0)
        stat-at: async func(
            path-flags: path-flags,
            path: string,
        ) -> result<descriptor-stat, error-code>;

        @since(version = 0.3.0)
        set-times-at: async func(
            path-flags: path-flags,
            path: string,
            data-access-timestamp: new-timestamp,
            data-modification-timestamp: new-timestamp,
        ) -> result<_, error-code>;

        @since(version = 0.3.0)
        link-at: async func(
            old-path-flags: path-flags,
            old-path: string,
            new-descriptor: borrow<descriptor>,
            new-path: string,
        ) -> result<_, error-code>;

        @since(version = 0.3.0)
        open-at: async func(
            path-flags: path-flags,
            path: string,
            open-flags: open-flags,
            %flags: descriptor-flags,
        ) -> result<descriptor, error-code>;

        @since(version = 0.3.0)
        readlink-at: async func(
            path: string,
        ) -> result<string, error-code>;

        @since(version = 0.3.0)
        remove-directory-at: async func(
            path: string,
        ) -> result<_, error-code>;

        @since(version = 0.3.0)
        rename-at: async func(
            old-path: string,
            new-descriptor: borrow<descriptor>,
            new-path: string,
        ) -> result<_, error-code>;

        @since(version = 0.3.0)
        symlink-at: async func(
            old-path: string,
            new-path: string,
        ) -> result<_, error-code>;

        @since(version = 0.3.0)
        unlink-file-at: async func(
            path: string,
        ) -> result<_, error-code>;

        @since(version = 0.3.0)
        is-same-object: async func(other: borrow<descriptor>) -> bool;

        @since(version = 0.3.0)
        metadata-hash: async func() -> result<metadata-hash-value, error-code>;

        @since(version = 0.3.0)
        metadata-hash-at: async func(
            path-flags: path-flags,
            path: string,
        ) -> result<metadata-hash-value, error-code>;
    }
}

@since(version = 0.3.0)
interface preopens {
    @since(version = 0.3.0)
    use types.{descriptor};

    @since(version = 0.3.0)
    get-directories: func() -> list<tuple<descriptor, string>>;
}

@since(version = 0.3.0)
world imports {
    @since(version = 0.3.0)
    import types;
    @since(version = 0.3.0)
    import preopens;
}
''';

const String _wasiSockets030Source = r'''package wasi:sockets@0.3.0;

@since(version = 0.3.0)
interface types {
    @since(version = 0.3.0)
    use wasi:clocks/types@0.3.0.{duration};

    @since(version = 0.3.0)
    variant error-code {
        access-denied,

        not-supported,

        invalid-argument,

        out-of-memory,

        timeout,

        invalid-state,

        address-not-bindable,

        address-in-use,

        remote-unreachable,

        connection-refused,

        connection-broken,

        connection-reset,

        connection-aborted,

        datagram-too-large,

        other(option<string>),
    }

    @since(version = 0.3.0)
    enum ip-address-family {
        ipv4,

        ipv6,
    }

    @since(version = 0.3.0)
    type ipv4-address = tuple<u8, u8, u8, u8>;
    @since(version = 0.3.0)
    type ipv6-address = tuple<u16, u16, u16, u16, u16, u16, u16, u16>;

    @since(version = 0.3.0)
    variant ip-address {
        ipv4(ipv4-address),
        ipv6(ipv6-address),
    }

    @since(version = 0.3.0)
    record ipv4-socket-address {
        port: u16,
        address: ipv4-address,
    }

    @since(version = 0.3.0)
    record ipv6-socket-address {
        port: u16,
        flow-info: u32,
        address: ipv6-address,
        scope-id: u32,
    }

    @since(version = 0.3.0)
    variant ip-socket-address {
        ipv4(ipv4-socket-address),
        ipv6(ipv6-socket-address),
    }

    @since(version = 0.3.0)
    resource tcp-socket {

        @since(version = 0.3.0)
        create: static func(address-family: ip-address-family) -> result<tcp-socket, error-code>;

        @since(version = 0.3.0)
        bind: func(local-address: ip-socket-address) -> result<_, error-code>;

        @since(version = 0.3.0)
        connect: async func(remote-address: ip-socket-address) -> result<_, error-code>;

        @since(version = 0.3.0)
        listen: func() -> result<stream<tcp-socket>, error-code>;

        @since(version = 0.3.0)
        send: func(data: stream<u8>) -> future<result<_, error-code>>;

        @since(version = 0.3.0)
        receive: func() -> tuple<stream<u8>, future<result<_, error-code>>>;

        @since(version = 0.3.0)
        get-local-address: func() -> result<ip-socket-address, error-code>;

        @since(version = 0.3.0)
        get-remote-address: func() -> result<ip-socket-address, error-code>;

        @since(version = 0.3.0)
        get-is-listening: func() -> bool;

        @since(version = 0.3.0)
        get-address-family: func() -> ip-address-family;

        @since(version = 0.3.0)
        set-listen-backlog-size: func(value: u64) -> result<_, error-code>;

        @since(version = 0.3.0)
        get-keep-alive-enabled: func() -> result<bool, error-code>;
        @since(version = 0.3.0)
        set-keep-alive-enabled: func(value: bool) -> result<_, error-code>;

        @since(version = 0.3.0)
        get-keep-alive-idle-time: func() -> result<duration, error-code>;
        @since(version = 0.3.0)
        set-keep-alive-idle-time: func(value: duration) -> result<_, error-code>;

        @since(version = 0.3.0)
        get-keep-alive-interval: func() -> result<duration, error-code>;
        @since(version = 0.3.0)
        set-keep-alive-interval: func(value: duration) -> result<_, error-code>;

        @since(version = 0.3.0)
        get-keep-alive-count: func() -> result<u32, error-code>;
        @since(version = 0.3.0)
        set-keep-alive-count: func(value: u32) -> result<_, error-code>;

        @since(version = 0.3.0)
        get-hop-limit: func() -> result<u8, error-code>;
        @since(version = 0.3.0)
        set-hop-limit: func(value: u8) -> result<_, error-code>;

        @since(version = 0.3.0)
        get-receive-buffer-size: func() -> result<u64, error-code>;
        @since(version = 0.3.0)
        set-receive-buffer-size: func(value: u64) -> result<_, error-code>;
        @since(version = 0.3.0)
        get-send-buffer-size: func() -> result<u64, error-code>;
        @since(version = 0.3.0)
        set-send-buffer-size: func(value: u64) -> result<_, error-code>;
    }

    @since(version = 0.3.0)
    resource udp-socket {

        @since(version = 0.3.0)
        create: static func(address-family: ip-address-family) -> result<udp-socket, error-code>;

        @since(version = 0.3.0)
        bind: func(local-address: ip-socket-address) -> result<_, error-code>;

        @since(version = 0.3.0)
        connect: func(remote-address: ip-socket-address) -> result<_, error-code>;

        @since(version = 0.3.0)
        disconnect: func() -> result<_, error-code>;

        @since(version = 0.3.0)
        send: async func(data: list<u8>, remote-address: option<ip-socket-address>) -> result<_, error-code>;

        @since(version = 0.3.0)
        receive: async func() -> result<tuple<list<u8>, ip-socket-address>, error-code>;

        @since(version = 0.3.0)
        get-local-address: func() -> result<ip-socket-address, error-code>;

        @since(version = 0.3.0)
        get-remote-address: func() -> result<ip-socket-address, error-code>;

        @since(version = 0.3.0)
        get-address-family: func() -> ip-address-family;

        @since(version = 0.3.0)
        get-unicast-hop-limit: func() -> result<u8, error-code>;
        @since(version = 0.3.0)
        set-unicast-hop-limit: func(value: u8) -> result<_, error-code>;

        @since(version = 0.3.0)
        get-receive-buffer-size: func() -> result<u64, error-code>;
        @since(version = 0.3.0)
        set-receive-buffer-size: func(value: u64) -> result<_, error-code>;
        @since(version = 0.3.0)
        get-send-buffer-size: func() -> result<u64, error-code>;
        @since(version = 0.3.0)
        set-send-buffer-size: func(value: u64) -> result<_, error-code>;
    }
}

@since(version = 0.3.0)
interface ip-name-lookup {
    @since(version = 0.3.0)
    use types.{ip-address};

    @since(version = 0.3.0)
    variant error-code {
        access-denied,

        invalid-argument,

        name-unresolvable,

        temporary-resolver-failure,

        permanent-resolver-failure,

        other(option<string>),
    }

    @since(version = 0.3.0)
    resolve-addresses: async func(name: string) -> result<list<ip-address>, error-code>;
}

@since(version = 0.3.0)
world imports {
    @since(version = 0.3.0)
    import types;
    @since(version = 0.3.0)
    import ip-name-lookup;
}
''';

const String _wasiCli030Source = r'''package wasi:cli@0.3.0;

@since(version = 0.3.0)
interface environment {
  @since(version = 0.3.0)
  get-environment: func() -> list<tuple<string, string>>;

  @since(version = 0.3.0)
  get-arguments: func() -> list<string>;

  @since(version = 0.3.0)
  get-initial-cwd: func() -> option<string>;
}

@since(version = 0.3.0)
interface exit {
  @since(version = 0.3.0)
  exit: func(status: result);

  @since(version = 0.3.0)
  exit-with-code: func(status-code: u8);
}

@since(version = 0.3.0)
interface types {
  @since(version = 0.3.0)
  enum error-code {
    io,
    illegal-byte-sequence,
    pipe,
  }
}

@since(version = 0.3.0)
interface stdin {
  use types.{error-code};

  @since(version = 0.3.0)
  read-via-stream: func() -> tuple<stream<u8>, future<result<_, error-code>>>;
}

@since(version = 0.3.0)
interface stdout {
  use types.{error-code};

  @since(version = 0.3.0)
  write-via-stream: func(data: stream<u8>) -> future<result<_, error-code>>;
}

@since(version = 0.3.0)
interface stderr {
  use types.{error-code};

  @since(version = 0.3.0)
  write-via-stream: func(data: stream<u8>) -> future<result<_, error-code>>;
}

@since(version = 0.3.0)
interface terminal-input {
    @since(version = 0.3.0)
    resource terminal-input;
}

@since(version = 0.3.0)
interface terminal-output {
    @since(version = 0.3.0)
    resource terminal-output;
}

@since(version = 0.3.0)
interface terminal-stdin {
    @since(version = 0.3.0)
    use terminal-input.{terminal-input};

    @since(version = 0.3.0)
    get-terminal-stdin: func() -> option<terminal-input>;
}

@since(version = 0.3.0)
interface terminal-stdout {
    @since(version = 0.3.0)
    use terminal-output.{terminal-output};

    @since(version = 0.3.0)
    get-terminal-stdout: func() -> option<terminal-output>;
}

@since(version = 0.3.0)
interface terminal-stderr {
    @since(version = 0.3.0)
    use terminal-output.{terminal-output};

    @since(version = 0.3.0)
    get-terminal-stderr: func() -> option<terminal-output>;
}

@since(version = 0.3.0)
interface run {
  @since(version = 0.3.0)
  run: async func() -> result;
}

@since(version = 0.3.0)
world imports {
  @since(version = 0.3.0)
  include wasi:clocks/imports@0.3.0;
  @since(version = 0.3.0)
  include wasi:filesystem/imports@0.3.0;
  @since(version = 0.3.0)
  include wasi:sockets/imports@0.3.0;
  @since(version = 0.3.0)
  include wasi:random/imports@0.3.0;

  @since(version = 0.3.0)
  import environment;
  @since(version = 0.3.0)
  import exit;
  @since(version = 0.3.0)
  import stdin;
  @since(version = 0.3.0)
  import stdout;
  @since(version = 0.3.0)
  import stderr;
  @since(version = 0.3.0)
  import terminal-input;
  @since(version = 0.3.0)
  import terminal-output;
  @since(version = 0.3.0)
  import terminal-stdin;
  @since(version = 0.3.0)
  import terminal-stdout;
  @since(version = 0.3.0)
  import terminal-stderr;
}

@since(version = 0.3.0)
world command {
  @since(version = 0.3.0)
  include imports;

  @since(version = 0.3.0)
  export run;
}
''';

const String _wasiHttp030Source = r'''package wasi:http@0.3.0;

@since(version = 0.3.0)
interface types {
  use wasi:clocks/types@0.3.0.{duration};

  @since(version = 0.3.0)
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
    other(string)
  }

  @since(version = 0.3.0)
  variant scheme {
    HTTP,
    HTTPS,
    other(string)
  }

  @since(version = 0.3.0)
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
    internal-error(option<string>)
  }

  @since(version = 0.3.0)
  record DNS-error-payload {
    rcode: option<string>,
    info-code: option<u16>
  }

  @since(version = 0.3.0)
  record TLS-alert-received-payload {
    alert-id: option<u8>,
    alert-message: option<string>
  }

  @since(version = 0.3.0)
  record field-size-payload {
    field-name: option<string>,
    field-size: option<u32>
  }

  @since(version = 0.3.0)
  variant header-error {
    invalid-syntax,

    forbidden,

    immutable,

    size-exceeded,

    other(option<string>),
  }

  @since(version = 0.3.0)
  variant request-options-error {
    not-supported,

    immutable,

    other(option<string>),
  }

  @since(version = 0.3.0)
  type field-name = string;

  @since(version = 0.3.0)
  type field-value = list<u8>;

  @since(version = 0.3.0)
  resource fields {

    constructor();

    from-list: static func(
      entries: list<tuple<field-name,field-value>>
    ) -> result<fields, header-error>;

    get: func(name: field-name) -> list<field-value>;

    has: func(name: field-name) -> bool;

    set: func(name: field-name, value: list<field-value>) -> result<_, header-error>;

    delete: func(name: field-name) -> result<_, header-error>;

    get-and-delete: func(name: field-name) -> result<list<field-value>, header-error>;

    append: func(name: field-name, value: field-value) -> result<_, header-error>;

    copy-all: func() -> list<tuple<field-name,field-value>>;

    clone: func() -> fields;
  }

  @since(version = 0.3.0)
  type headers = fields;

  @since(version = 0.3.0)
  type trailers = fields;

  @since(version = 0.3.0)
  resource request {

    new: static func(
      headers: headers,
      contents: option<stream<u8>>,
      trailers: future<result<option<trailers>, error-code>>,
      options: option<request-options>
    ) -> tuple<request, future<result<_, error-code>>>;

    get-method: func() -> method;
    set-method: func(method: method) -> result;

    get-path-with-query: func() -> option<string>;
    set-path-with-query: func(path-with-query: option<string>) -> result;

    get-scheme: func() -> option<scheme>;
    set-scheme: func(scheme: option<scheme>) -> result;

    get-authority: func() -> option<string>;
    set-authority: func(authority: option<string>) -> result;

    get-options: func() -> option<request-options>;

    get-headers: func() -> headers;

    consume-body: static func(this: request, res: future<result<_, error-code>>) -> tuple<stream<u8>, future<result<option<trailers>, error-code>>>;
  }

  @since(version = 0.3.0)
  resource request-options {
    constructor();

    get-connect-timeout: func() -> option<duration>;

    set-connect-timeout: func(duration: option<duration>) -> result<_, request-options-error>;

    get-first-byte-timeout: func() -> option<duration>;

    set-first-byte-timeout: func(duration: option<duration>) -> result<_, request-options-error>;

    get-between-bytes-timeout: func() -> option<duration>;

    set-between-bytes-timeout: func(duration: option<duration>) -> result<_, request-options-error>;

    clone: func() -> request-options;
  }

  @since(version = 0.3.0)
  type status-code = u16;

  @since(version = 0.3.0)
  resource response {

    new: static func(
      headers: headers,
      contents: option<stream<u8>>,
      trailers: future<result<option<trailers>, error-code>>,
    ) -> tuple<response, future<result<_, error-code>>>;

    get-status-code: func() -> status-code;

    set-status-code: func(status-code: status-code) -> result;

    get-headers: func() -> headers;

    consume-body: static func(this: response, res: future<result<_, error-code>>) -> tuple<stream<u8>, future<result<option<trailers>, error-code>>>;
  }
}

@since(version = 0.3.0)
world service {
  include wasi:clocks/imports@0.3.0;
  include wasi:random/imports@0.3.0;

  import wasi:cli/stdout@0.3.0;
  import wasi:cli/stderr@0.3.0;

  import wasi:cli/stdin@0.3.0;

  import client;

  export handler;
}

@since(version = 0.3.0)
world middleware {
  include service;
  import handler;
}

@since(version = 0.3.0)
interface handler {
  use types.{request, response, error-code};

  handle: async func(
    request: request,
  ) -> result<response, error-code>;
}

@since(version = 0.3.0)
interface client {
  use types.{request, response, error-code};

  send: async func(
    request: request,
  ) -> result<response, error-code>;
}
''';

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

final WASIComponentWitDocument _wasiFilesystem030Document =
    WASIComponentWitDocument.parse(
      _wasiFilesystem030Source,
      sourceName: 'wasi:filesystem@0.3.0',
    );

final WASIComponentWitDocument _wasiSockets030Document =
    WASIComponentWitDocument.parse(
      _wasiSockets030Source,
      sourceName: 'wasi:sockets@0.3.0',
    );

final WASIComponentWitDocument _wasiCli030Document =
    WASIComponentWitDocument.parse(
      _wasiCli030Source,
      sourceName: 'wasi:cli@0.3.0',
    );

final WASIComponentWitDocument _wasiHttp030Document =
    WASIComponentWitDocument.parse(
      _wasiHttp030Source,
      sourceName: 'wasi:http@0.3.0',
    );
