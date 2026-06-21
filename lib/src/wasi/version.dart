/// WASI specification version.
enum WASIVersion {
  /// WASI preview1 (wasi_snapshot_preview1).
  preview1,

  /// WASI 0.2 / Preview 2 component-model APIs.
  preview2,

  /// WASI 0.3 / Preview 3 component-model async APIs.
  preview3,
}
