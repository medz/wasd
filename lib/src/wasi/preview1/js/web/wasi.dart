import '../../../../wasm/instance.dart' as wasm;
import '../../../../wasm/memory.dart' as wasm;
import '../../../../wasm/module.dart' as wasm;
import '../../../wasi.dart' as wasi;

class WASI implements wasi.WASI {
  // ignore: avoid_unused_constructor_parameters
  WASI({
    List<String> args = const [],
    Map<String, String> env = const {},
    Map<String, String> preopens = const {},
    bool returnOnExit = true,
    int stdin = 0,
    int stdout = 1,
    int stderr = 2,
    wasi.WASIVersion version = wasi.WASIVersion.preview1,
  });

  @override
  wasm.Imports get imports =>
      throw UnimplementedError('browser WASI is not yet implemented');

  @override
  int start(wasm.Instance instance) =>
      throw UnimplementedError('browser WASI is not yet implemented');

  @override
  void initialize(wasm.Instance instance) =>
      throw UnimplementedError('browser WASI is not yet implemented');

  @override
  void finalizeBindings(wasm.Instance instance, {wasm.Memory? memory}) =>
      throw UnimplementedError('browser WASI is not yet implemented');
}
