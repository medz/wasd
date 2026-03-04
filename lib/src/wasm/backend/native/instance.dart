import '../../instance.dart' as wasm;
import '../../module.dart';

class Instance implements wasm.Instance {
  Instance(this.module, [this.imports = const {}]);

  final Module module;
  final Imports imports;

  @override
  Exports get exports =>
      throw UnimplementedError('Native backend instance exports');
}
