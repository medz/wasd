# Examples

This directory contains the runnable WASD examples.

## hello.dart

Minimal runtime example that instantiates a tiny module and invokes an exported `hello` function.

```bash
dart run example/hello.dart
```

## sum.dart

Basic function call example for `sum(i32, i32)`.

```bash
dart run example/sum.dart
dart run example/sum.dart 3 9
```

## doom/

Flutter desktop example that runs Doom wasm.

See [doom/README.md](doom/README.md) for setup and run steps.
