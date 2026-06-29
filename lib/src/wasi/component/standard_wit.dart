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
