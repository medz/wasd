import '../../instance.dart' as wasm;
import '../../module.dart' as wasm;

class Instance implements wasm.Instance {
  // ignore: avoid_unused_constructor_parameters
  Instance(wasm.Module module, [wasm.Imports imports = const {}]);

  @override
  wasm.Exports get exports =>
      throw UnimplementedError('native wasm backend is not implemented');
}
