import 'module.dart';

/// Minimal WebAssembly instance interface.
abstract class Instance {
  /// Creates an instance from [module] and optional [imports].
  Instance(Module module, [Imports imports = const {}]);

  /// Exported values of this instance.
  Exports get exports;
}
