import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:ffi/ffi.dart';

bool cpuClockAvailable(int id) =>
    _readHostCpuClock(id, resolution: true) != null &&
    _readHostCpuClock(id, resolution: false) != null;

int? hostCpuClockResolutionNanos(int id) =>
    _readHostCpuClock(id, resolution: true);

int? _readHostCpuClock(int id, {required bool resolution}) {
  if ((id != 2 && id != 3) ||
      (!Platform.isLinux && !Platform.isMacOS) ||
      ffi.sizeOf<ffi.IntPtr>() != 8) {
    return null;
  }
  try {
    final library = ffi.DynamicLibrary.process();
    final read = library
        .lookupFunction<
          ffi.Int32 Function(ffi.Int32, ffi.Pointer<_Timespec>),
          int Function(int, ffi.Pointer<_Timespec>)
        >(resolution ? 'clock_getres' : 'clock_gettime');
    final value = calloc<_Timespec>();
    try {
      final clockId = Platform.isMacOS ? (id == 2 ? 12 : 16) : id;
      if (read(clockId, value) != 0) return null;
      final seconds = value.ref.seconds;
      final nanos = value.ref.nanoseconds;
      if (seconds < 0 || nanos < 0 || nanos >= 1000000000) return null;
      final result = seconds * 1000000000 + nanos;
      return resolution && result == 0 ? null : result;
    } finally {
      calloc.free(value);
    }
  } catch (_) {
    return null;
  }
}

void pauseForCpuClockTest(Duration duration) => sleep(duration);

void Function() overrideNodeCpuClockApi(
  int id,
  String mode, {
  void Function()? onCall,
}) => throw UnsupportedError('Requires Node.js.');

final class _Timespec extends ffi.Struct {
  @ffi.Int64()
  external int seconds;
  @ffi.Int64()
  external int nanoseconds;
}

void Function() hideNodeRequireForCpuClockTest() =>
    throw UnsupportedError('Requires Node.js.');
