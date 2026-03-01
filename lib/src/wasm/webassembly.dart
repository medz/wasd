import 'dart:async';
import 'dart:typed_data';

import 'instance.dart';
import 'module.dart';

/// Minimal WebAssembly facade interface.
abstract interface class WebAssembly {
  /// Instantiated module instance.
  Instance get instance;

  /// Compiled module object used for [instance].
  Module get module;

  /// Compiles raw [bytes] into a [Module].
  static Future<Module> compile(ByteBuffer bytes) => throw UnimplementedError();

  /// Compiles binary stream [source] into a [Module].
  static Future<Module> compileStreaming(Stream<List<int>> source) =>
      throw UnimplementedError();

  /// Instantiates WebAssembly from [bytes] and optional [imports].
  static Future<WebAssembly> instantiate(
    ByteBuffer bytes, [
    Imports imports = const {},
  ]) => throw UnimplementedError();

  /// Instantiates WebAssembly from binary stream [source].
  static Future<WebAssembly> instantiateStreaming(
    Stream<List<int>> source, [
    Imports imports = const {},
  ]) => throw UnimplementedError();

  /// Instantiates a precompiled [module] and returns an [Instance].
  static Future<Instance> instantiateModule(
    Module module, [
    Imports imports = const {},
  ]) => throw UnimplementedError();

  /// Validates whether [bytes] contains a valid WebAssembly module.
  static bool validate(ByteBuffer bytes) => throw UnimplementedError();
}
