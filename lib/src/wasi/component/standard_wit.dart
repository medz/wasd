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
  if (parsed.packageName == 'wasi:random' && parsed.version == '0.2.0') {
    return WASIComponentWitResolvedTarget(
      document: _wasiRandom020Document,
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

final WASIComponentWitDocument _wasiRandom020Document =
    WASIComponentWitDocument.parse(
      _wasiRandom020Source,
      sourceName: 'wasi:random@0.2.0',
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

final String _wasiRandom020Source = _wasiRandom030Source.replaceAll(
  '@0.3.0',
  '@0.2.0',
);

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
