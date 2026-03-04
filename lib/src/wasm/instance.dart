import 'backend/native/instance.dart'
    if (dart.library.js_interop) 'backend/js/instance.dart'
    as backend;
import 'module.dart';

/// Minimal WebAssembly instance interface.
abstract interface class Instance {
  /// Creates an instance from [module] and optional [imports].
  factory Instance(Module module, [Imports imports]) = backend.Instance;

  /// Exported values of this instance.
  Exports get exports;
}
