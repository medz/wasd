import 'dart:collection';

import 'doom_runtime.dart';

final class DoomNativeInputClient {
  DoomNativeInputClient._();

  static Future<DoomNativeInputClient?> connect(Object? handle) async => null;

  void send(DoomInputEvent event) {}

  Future<void> close() async {}
}

final class DoomNativeInputServer {
  DoomNativeInputServer._();

  static Future<DoomNativeInputServer?> bind() async => null;

  Object? get handle => null;

  void drainInto(Queue<DoomInputEvent> queue) {}

  Future<void> close() async {}
}
