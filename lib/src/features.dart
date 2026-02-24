final class WasmFeatureSet {
  const WasmFeatureSet({
    this.simd = false,
    this.threads = false,
    this.exceptionHandling = false,
    this.gc = false,
    this.componentModel = false,
  });

  final bool simd;
  final bool threads;
  final bool exceptionHandling;
  final bool gc;
  final bool componentModel;
}
