import '../../../wasm/instance.dart' as wasm;
import '../../../wasm/memory.dart' as wasm;
import '../../../wasm/module.dart' as wasm;
import '../../wasi.dart' as wasi_iface;

class WASI implements wasi_iface.WASI {
  // ignore: avoid_unused_constructor_parameters
  WASI({
    List<String> args = const [],
    Map<String, String> env = const {},
    Map<String, String> preopens = const {},
    bool returnOnExit = true,
    int stdin = 0,
    int stdout = 1,
    int stderr = 2,
    wasi_iface.WASIVersion version = wasi_iface.WASIVersion.preview1,
  });

  @override
  wasm.Imports get imports =>
      throw UnimplementedError('native WASI backend is not implemented');

  @override
  int start(wasm.Instance instance) =>
      throw UnimplementedError('native WASI backend is not implemented');

  @override
  void initialize(wasm.Instance instance) =>
      throw UnimplementedError('native WASI backend is not implemented');

  @override
  void finalizeBindings(wasm.Instance instance, {wasm.Memory? memory}) =>
      throw UnimplementedError('native WASI backend is not implemented');
}
