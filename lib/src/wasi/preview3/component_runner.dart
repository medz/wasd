import '../../wasm/backend/native/interpreter/component.dart';
import '../preview2/component_runner.dart';
import 'component_host.dart';
import 'http.dart';

/// Result returned after executing a WASI Preview3 command component.
final class WASIPreview3CommandResult {
  /// Creates a command execution result.
  const WASIPreview3CommandResult({required this.exitCode});

  /// Process-style exit code. `0` means success.
  final int exitCode;
}

/// Executes WASI Preview3 `wasi:cli/command` components on the native backend.
final class WASIPreview3CommandRunner {
  /// Creates a command runner over [host].
  const WASIPreview3CommandRunner(this.host);

  /// Preview3 host used for standard WASI imports and canonical state.
  final WASIPreview3ComponentHost host;

  /// Instantiates [component] and invokes its exported async `wasi:cli/run`.
  Future<WASIPreview3CommandResult> run(WasmComponent component) async {
    try {
      final exitCode = await WASIComponentNativeRuntime.preview3(
        component: component,
        host: host,
      ).runPreview3Command();
      return WASIPreview3CommandResult(exitCode: exitCode);
    } on WASIPreview2ComponentExecutionException catch (error) {
      throw WASIPreview3ComponentExecutionException(error.message);
    }
  }
}

/// Executes WASI Preview3 `wasi:http/service` components on the native backend.
final class WASIPreview3ServiceRunner {
  /// Creates an HTTP service runner over [host].
  WASIPreview3ServiceRunner(this.host);

  /// Preview3 host used for standard WASI imports and canonical state.
  final WASIPreview3ComponentHost host;

  WasmComponent? _component;
  WASIComponentNativeRuntime? _runtime;

  /// Instantiates [component] and invokes its exported async HTTP handler for
  /// [request].
  Future<WASIPreview3HttpResult<WASIPreview3HttpResponse>> handle(
    WasmComponent component,
    WASIPreview3HttpRequest request,
  ) async {
    try {
      if (!identical(_component, component)) {
        _component = component;
        _runtime = WASIComponentNativeRuntime.preview3(
          component: component,
          host: host,
        );
      }
      return await _runtime!.handlePreview3Service(request);
    } on WASIPreview2ComponentExecutionException catch (error) {
      throw WASIPreview3ComponentExecutionException(error.message);
    }
  }
}

/// Thrown when a Preview3 component cannot be linked or executed.
final class WASIPreview3ComponentExecutionException implements Exception {
  /// Creates an execution exception with [message].
  const WASIPreview3ComponentExecutionException(this.message);

  /// Human-readable failure message.
  final String message;

  @override
  String toString() => message;
}
