import 'dart:typed_data';

import '../wasm/instance.dart';
import '../wasm/memory.dart';
import '../wasm/module.dart';
import 'preview1/socket.dart';
import 'version.dart';
import 'preview1/native/wasi.dart'
    if (dart.library.js_interop) 'preview1/js/wasi.dart'
    as backend;

export 'preview1/socket.dart';
export 'version.dart';

/// Handles a WASI Preview1 `proc_raise` signal.
///
/// When provided to [WASI], the handler is called instead of the default host
/// signal behavior. Returning normally reports success to the guest.
typedef WASIProcRaiseHandler = void Function(WASIProcessSignal signal);

/// WASI Preview1 process signal values.
enum WASIProcessSignal {
  /// Reserved no-signal value.
  none(0),

  /// Hangup signal.
  hup(1),

  /// Interrupt signal.
  interrupt(2),

  /// Terminal quit signal.
  quit(3),

  /// Illegal instruction signal.
  ill(4),

  /// Trace or breakpoint trap signal.
  trap(5),

  /// Process abort signal.
  abrt(6),

  /// Bus error signal.
  bus(7),

  /// Floating point exception signal.
  fpe(8),

  /// Kill signal.
  kill(9),

  /// User-defined signal 1.
  usr1(10),

  /// Invalid memory reference signal.
  segv(11),

  /// User-defined signal 2.
  usr2(12),

  /// Broken pipe signal.
  pipe(13),

  /// Alarm clock signal.
  alrm(14),

  /// Termination signal.
  term(15),

  /// Child process state-change signal.
  chld(16),

  /// Continue signal.
  cont(17),

  /// Stop signal.
  stop(18),

  /// Terminal stop signal.
  tstp(19),

  /// Background read attempted signal.
  ttin(20),

  /// Background write attempted signal.
  ttou(21),

  /// Urgent socket data signal.
  urg(22),

  /// CPU time limit exceeded signal.
  xcpu(23),

  /// File size limit exceeded signal.
  xfsz(24),

  /// Virtual timer expired signal.
  vtalrm(25),

  /// Profiling timer expired signal.
  prof(26),

  /// Window size changed signal.
  winch(27),

  /// Pollable event signal.
  poll(28),

  /// Power failure signal.
  pwr(29),

  /// Bad system call signal.
  sys(30);

  const WASIProcessSignal(this.code);

  /// The WASI Preview1 integer code for this signal.
  final int code;

  /// Returns the signal for a WASI Preview1 integer [code].
  static WASIProcessSignal? fromPreview1Code(int code) {
    if (code < 0 || code >= values.length) {
      return null;
    }
    final signal = values[code];
    return signal.code == code ? signal : null;
  }
}

/// Minimal WASI runtime interface.
abstract interface class WASI {
  /// Creates a WASI runtime with the given options.
  factory WASI({
    List<String> args = const [],
    Map<String, String> env = const {},
    Map<String, String> preopens = const {},
    Map<String, Uint8List> files = const {},
    bool returnOnExit = true,
    int stdin = 0,
    List<int> stdinData = const <int>[],
    int stdout = 1,
    int stderr = 2,
    Map<int, WASIPreview1Socket> sockets = const <int, WASIPreview1Socket>{},
    WASIProcRaiseHandler? procRaiseHandler,
    WASIVersion version = WASIVersion.preview1,
  }) {
    _requireSupportedVersion(version);
    return backend.WASI(
      args: args,
      env: env,
      preopens: preopens,
      files: files,
      returnOnExit: returnOnExit,
      stdin: stdin,
      stdinData: stdinData,
      stdout: stdout,
      stderr: stderr,
      sockets: sockets,
      procRaiseHandler: procRaiseHandler,
      version: version,
    );
  }

  /// The WASI import object to pass when instantiating a module.
  Imports get imports;

  /// Starts a WASI command module by invoking its `_start` export.
  ///
  /// Returns the exit code reported by the module.
  int start(Instance instance);

  /// Initializes a WASI reactor module by invoking its `_initialize` export.
  void initialize(Instance instance);

  /// Binds the WASI runtime to an instance's memory.
  ///
  /// Prefers the explicitly provided [memory]. Falls back to
  /// `instance.exports['memory']`. Throws if neither is available.
  ///
  /// [start] and [initialize] call this automatically when needed.
  void finalizeBindings(Instance instance, {Memory? memory});
}

void _requireSupportedVersion(WASIVersion version) {
  if (version == WASIVersion.preview1) {
    return;
  }
  throw UnsupportedError(
    '${_wasiVersionLabel(version)} requires a component-model WASI host. '
    'This runtime currently supports only WASI Preview1 host instantiation.',
  );
}

String _wasiVersionLabel(WASIVersion version) => switch (version) {
  WASIVersion.preview1 => 'WASI Preview1',
  WASIVersion.preview2 => 'WASI 0.2 / Preview2',
  WASIVersion.preview3 => 'WASI 0.3 / Preview3',
};
