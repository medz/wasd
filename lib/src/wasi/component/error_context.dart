import 'dart:convert';
import 'dart:typed_data';

import '../../wasm/backend/native/interpreter/component.dart';
import '../../wasm/memory.dart' as wasm;
import 'resource_table.dart';

/// Canonical string encoding supported by component error-context adapters.
enum WASIComponentCanonicalStringEncoding {
  /// UTF-8 canonical string encoding.
  utf8;

  /// Resolves the string encoding selected by decoded canonical options.
  static WASIComponentCanonicalStringEncoding fromCanonicalOptions(
    List<WasmComponentCanonicalOption> options,
  ) {
    for (final option in options) {
      switch (option.kind) {
        case WasmComponentCanonicalOptionKind.stringEncodingUtf8:
          return WASIComponentCanonicalStringEncoding.utf8;
        case WasmComponentCanonicalOptionKind.stringEncodingUtf16:
        case WasmComponentCanonicalOptionKind.stringEncodingLatin1Utf16:
          throw UnsupportedError(
            'WASI component error-context currently supports only UTF-8 strings.',
          );
        case WasmComponentCanonicalOptionKind.memory:
        case WasmComponentCanonicalOptionKind.realloc:
        case WasmComponentCanonicalOptionKind.postReturn:
        case WasmComponentCanonicalOptionKind.async:
        case WasmComponentCanonicalOptionKind.callback:
          break;
      }
    }
    return WASIComponentCanonicalStringEncoding.utf8;
  }
}

/// Result of writing a canonical string to component memory.
final class WASIComponentMemoryString {
  /// Creates a memory string range.
  const WASIComponentMemoryString({
    required this.pointer,
    required this.length,
  });

  /// Pointer to the first byte in guest memory.
  final int pointer;

  /// Byte length of the string payload.
  final int length;
}

/// Canonical-style realloc callback used when lifting strings into memory.
typedef WASIComponentCanonicalRealloc =
    int Function(int oldPointer, int oldSize, int alignment, int newSize);

/// Host-side representation of a Component Model `error-context`.
final class WASIComponentErrorContext {
  /// Creates an error context with a debug [message].
  const WASIComponentErrorContext(this.message);

  /// Debug message associated with the context.
  final String message;
}

/// Binds canonical `error-context.*` definitions to a resource table.
///
/// This is an internal execution layer for Component Model canonical builtins.
/// It includes UTF-8 string memory helpers for canonical `ptr/len` adapters,
/// while broader string encoding coverage and direct core `realloc` integration
/// remain future adapter work.
final class WASIComponentErrorContextHost {
  /// Creates an error-context host backed by [table] or a new resource table.
  WASIComponentErrorContextHost({WASIComponentResourceTable? table})
    : table = table ?? WASIComponentResourceTable() {
    _type = this.table.defineType<WASIComponentErrorContext>('error-context');
  }

  /// Resource table used by this host.
  final WASIComponentResourceTable table;

  late final WASIComponentResourceType<WASIComponentErrorContext> _type;

  /// Creates an error-context handle from [message].
  int create(String message) {
    return table.insert<WASIComponentErrorContext>(
      _type,
      WASIComponentErrorContext(message),
    );
  }

  /// Returns the debug message for [handle].
  String debugMessage(int handle) {
    return table.get<WASIComponentErrorContext>(_type, handle).message;
  }

  /// Drops [handle].
  void drop(int handle) {
    table.drop<WASIComponentErrorContext>(_type, handle);
  }

  /// Binds a decoded canonical error-context definition.
  WASIComponentCanonicalErrorContextOperation bindCanonicalDefinition(
    WasmComponentCanonicalDefinition definition,
  ) {
    if (!_isErrorContextCanonicalKind(definition.kind)) {
      throw UnsupportedError(
        'Wasm component canonical ${definition.kind.name} is not an error-context operation.',
      );
    }
    return WASIComponentCanonicalErrorContextOperation._(
      host: this,
      kind: definition.kind,
      stringEncoding: WASIComponentCanonicalStringEncoding.fromCanonicalOptions(
        definition.options,
      ),
    );
  }

  /// Binds all decoded canonical error-context definitions in [component].
  WASIComponentCanonicalErrorContextProgram bindCanonicalDefinitions(
    WasmComponent component,
  ) {
    return WASIComponentCanonicalErrorContextProgram(
      operations:
          List<WASIComponentCanonicalErrorContextOperation>.unmodifiable([
            for (final definition in component.canonicalDefinitions)
              bindCanonicalDefinition(definition),
          ]),
    );
  }
}

/// Executable error-context-only canonical program for a decoded component.
final class WASIComponentCanonicalErrorContextProgram {
  /// Creates a canonical error-context program from ordered [operations].
  const WASIComponentCanonicalErrorContextProgram({required this.operations});

  /// Error-context operations in component canonical definition order.
  final List<WASIComponentCanonicalErrorContextOperation> operations;

  /// Invokes the canonical error-context operation at [canonicalIndex].
  Object? invoke(int canonicalIndex, List<Object?> args) {
    if (canonicalIndex < 0 || canonicalIndex >= operations.length) {
      throw StateError(
        'Unknown WASI component canonical error-context index: $canonicalIndex.',
      );
    }

    final operation = operations[canonicalIndex];
    switch (operation.kind) {
      case WasmComponentCanonicalKind.errorContextNew:
        _expectArity(canonicalIndex, args, 1);
        return operation.create(_expectString(canonicalIndex, args.single));
      case WasmComponentCanonicalKind.errorContextDebugMessage:
        _expectArity(canonicalIndex, args, 1);
        return operation.debugMessage(
          _expectHandle(canonicalIndex, args.single),
        );
      case WasmComponentCanonicalKind.errorContextDrop:
        _expectArity(canonicalIndex, args, 1);
        operation.drop(_expectHandle(canonicalIndex, args.single));
        return null;
      default:
        throw UnsupportedError(
          'Wasm component canonical ${operation.kind.name} is not executable by the error-context program.',
        );
    }
  }
}

/// Executable form of a canonical error-context operation.
final class WASIComponentCanonicalErrorContextOperation {
  const WASIComponentCanonicalErrorContextOperation._({
    required this.host,
    required this.kind,
    required this.stringEncoding,
  });

  /// Host used by this operation.
  final WASIComponentErrorContextHost host;

  /// Canonical error-context operation kind.
  final WasmComponentCanonicalKind kind;

  /// Canonical string encoding configured by the decoded operation options.
  final WASIComponentCanonicalStringEncoding stringEncoding;

  /// Executes `error-context.new`.
  int create(String message) {
    _requireKind(WasmComponentCanonicalKind.errorContextNew);
    return host.create(message);
  }

  /// Executes `error-context.new` by reading a canonical string from [memory].
  int createFromMemory(wasm.Memory memory, int pointer, int length) {
    _requireKind(WasmComponentCanonicalKind.errorContextNew);
    return host.create(
      _readCanonicalString(memory, pointer, length, stringEncoding),
    );
  }

  /// Executes `error-context.debug-message`.
  String debugMessage(int handle) {
    _requireKind(WasmComponentCanonicalKind.errorContextDebugMessage);
    return host.debugMessage(handle);
  }

  /// Executes `error-context.debug-message` and writes the result to [memory].
  WASIComponentMemoryString debugMessageToMemory(
    int handle,
    wasm.Memory memory,
    WASIComponentCanonicalRealloc realloc,
  ) {
    _requireKind(WasmComponentCanonicalKind.errorContextDebugMessage);
    return _writeCanonicalString(
      memory,
      realloc,
      host.debugMessage(handle),
      stringEncoding,
    );
  }

  /// Executes `error-context.drop`.
  void drop(int handle) {
    _requireKind(WasmComponentCanonicalKind.errorContextDrop);
    host.drop(handle);
  }

  void _requireKind(WasmComponentCanonicalKind expected) {
    if (kind != expected) {
      throw StateError(
        'WASI component canonical ${kind.name} cannot execute ${expected.name}.',
      );
    }
  }
}

bool _isErrorContextCanonicalKind(WasmComponentCanonicalKind kind) {
  return kind == WasmComponentCanonicalKind.errorContextNew ||
      kind == WasmComponentCanonicalKind.errorContextDebugMessage ||
      kind == WasmComponentCanonicalKind.errorContextDrop;
}

void _expectArity(int canonicalIndex, List<Object?> args, int expected) {
  if (args.length != expected) {
    throw StateError(
      'WASI component canonical error-context index $canonicalIndex expected '
      '$expected arguments, got ${args.length}.',
    );
  }
}

String _expectString(int canonicalIndex, Object? value) {
  if (value is String) {
    return value;
  }
  throw StateError(
    'WASI component canonical error-context index $canonicalIndex expected a string message.',
  );
}

int _expectHandle(int canonicalIndex, Object? value) {
  if (value is int) {
    return value;
  }
  throw StateError(
    'WASI component canonical error-context index $canonicalIndex expected an i32 handle.',
  );
}

String _readCanonicalString(
  wasm.Memory memory,
  int pointer,
  int length,
  WASIComponentCanonicalStringEncoding encoding,
) {
  RangeError.checkNotNegative(pointer, 'pointer');
  RangeError.checkNotNegative(length, 'length');
  final bytes = Uint8List.view(memory.buffer);
  if (pointer > bytes.length || length > bytes.length - pointer) {
    throw RangeError.range(
      pointer + length,
      0,
      bytes.length,
      'pointer + length',
    );
  }
  final slice = Uint8List.sublistView(bytes, pointer, pointer + length);
  return switch (encoding) {
    WASIComponentCanonicalStringEncoding.utf8 => utf8.decode(slice),
  };
}

WASIComponentMemoryString _writeCanonicalString(
  wasm.Memory memory,
  WASIComponentCanonicalRealloc realloc,
  String value,
  WASIComponentCanonicalStringEncoding encoding,
) {
  final encoded = switch (encoding) {
    WASIComponentCanonicalStringEncoding.utf8 => Uint8List.fromList(
      utf8.encode(value),
    ),
  };
  final pointer = realloc(0, 0, 1, encoded.length);
  RangeError.checkNotNegative(pointer, 'pointer');

  final bytes = Uint8List.view(memory.buffer);
  if (pointer > bytes.length || encoded.length > bytes.length - pointer) {
    throw RangeError.range(
      pointer + encoded.length,
      0,
      bytes.length,
      'pointer + length',
    );
  }
  bytes.setRange(pointer, pointer + encoded.length, encoded);
  return WASIComponentMemoryString(pointer: pointer, length: encoded.length);
}
