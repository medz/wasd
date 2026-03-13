import 'dart:collection';

import 'doom_runtime.dart';

final class DoomSharedInputQueue {
  DoomSharedInputQueue({this.capacity = 256});

  final int capacity;

  Object? get handle => null;

  bool get isSupported => false;

  String? get unsupportedReason => null;

  void enqueue(DoomInputEvent event) {}

  void drainInto(Queue<DoomInputEvent> queue) {}

  static DoomSharedInputQueue? fromHandle(
    Object? handle, {
    required int capacity,
  }) {
    if (handle == null) {
      return null;
    }
    return DoomSharedInputQueue(capacity: capacity);
  }
}
