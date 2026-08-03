/// Compile-time sentinel for implementation types that must stay internal.
///
/// Import this library unprefixed beside the package entrypoint. If the package
/// accidentally exports a matching type, references become ambiguous and the
/// public API test stops compiling on every runtime.
final class WASIComponentNativeRuntime {
  const WASIComponentNativeRuntime();
}
