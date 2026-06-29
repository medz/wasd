import 'dart:math' as math;

import '../component/wit_adapter.dart';
import '../preview3/random.dart';

/// WASI 0.2 `wasi:random` host imports.
final class WASIPreview2RandomHost {
  /// Creates a random host import provider.
  WASIPreview2RandomHost({
    math.Random? secureRandom,
    math.Random? insecureRandom,
  }) : _delegate = WASIPreview3RandomHost(
         secureRandom: secureRandom,
         insecureRandom: insecureRandom,
       );

  final WASIPreview3RandomHost _delegate;

  /// Import callbacks keyed by canonical WIT adapter names.
  late final Map<String, WASIComponentWitAdapterCallback> imports =
      Map<String, WASIComponentWitAdapterCallback>.unmodifiable({
        for (final entry in _delegate.imports.entries)
          entry.key.replaceFirst('@0.3.0', '@0.2.0'): entry.value,
      });
}
