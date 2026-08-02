/// Marks host exceptions that leave WebAssembly execution without trapping.
///
/// Native runtimes preserve these exceptions so the embedding host can handle
/// control flow such as WASI process exit.
abstract interface class WasmHostControlFlowException implements Exception {}
