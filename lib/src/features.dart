enum WasmFeatureProfile {
  /// Core wasm only; all proposal gates disabled.
  core,

  /// Core + lower-risk proposal defaults.
  stable,

  /// Core + stable + high-risk proposal defaults.
  full,
}

final class WasmFeatureSet {
  const WasmFeatureSet({
    this.simd = false,
    this.threads = false,
    this.exceptionHandling = false,
    this.gc = false,
    this.componentModel = false,
    this.additionalEnabled = const <String>{},
    this.additionalDisabled = const <String>{},
  });

  factory WasmFeatureSet.layeredDefaults({
    WasmFeatureProfile profile = WasmFeatureProfile.stable,
    Set<String> additionalEnabled = const <String>{},
    Set<String> additionalDisabled = const <String>{},
  }) {
    final defaults = switch (profile) {
      WasmFeatureProfile.core => const <String>{},
      WasmFeatureProfile.stable => _stableDefaultFeatures,
      WasmFeatureProfile.full => _stableDefaultFeatures.union(
        _highRiskDefaultFeatures,
      ),
    };
    final normalizedEnabled = additionalEnabled
        .map(_normalizeFeatureName)
        .toSet();
    final normalizedDisabled = additionalDisabled
        .map(_normalizeFeatureName)
        .toSet();
    final effective = <String>{...defaults, ...normalizedEnabled}
      ..removeAll(normalizedDisabled);
    return WasmFeatureSet(
      simd: effective.contains(_simdFeatureName),
      threads: effective.contains(_threadsFeatureName),
      exceptionHandling: effective.contains(_exceptionHandlingFeatureName),
      gc: effective.contains(_gcFeatureName),
      componentModel: effective.contains(_componentModelFeatureName),
      additionalEnabled: normalizedEnabled,
      additionalDisabled: normalizedDisabled,
    );
  }

  static const String _simdFeatureName = 'simd';
  static const String _threadsFeatureName = 'threads';
  static const String _exceptionHandlingFeatureName = 'exception-handling';
  static const String _gcFeatureName = 'gc';
  static const String _componentModelFeatureName = 'component-model';

  static const Set<String> _stableDefaultFeatures = <String>{
    _simdFeatureName,
    _exceptionHandlingFeatureName,
  };
  static const Set<String> _highRiskDefaultFeatures = <String>{
    _threadsFeatureName,
    _gcFeatureName,
    _componentModelFeatureName,
  };

  final bool simd;
  final bool threads;
  final bool exceptionHandling;
  final bool gc;
  final bool componentModel;

  /// Forward-compatible extension point for proposals not yet modeled as fields.
  final Set<String> additionalEnabled;

  /// Feature names forcibly disabled after defaults + additions are applied.
  final Set<String> additionalDisabled;

  Set<String> get enabledFeatures {
    final enabled = <String>{};
    if (simd) {
      enabled.add(_simdFeatureName);
    }
    if (threads) {
      enabled.add(_threadsFeatureName);
    }
    if (exceptionHandling) {
      enabled.add(_exceptionHandlingFeatureName);
    }
    if (gc) {
      enabled.add(_gcFeatureName);
    }
    if (componentModel) {
      enabled.add(_componentModelFeatureName);
    }
    enabled.addAll(additionalEnabled.map(_normalizeFeatureName));
    enabled.removeAll(additionalDisabled.map(_normalizeFeatureName));
    return enabled;
  }

  bool isEnabled(String featureName) {
    final normalized = _normalizeFeatureName(featureName);
    return enabledFeatures.contains(normalized);
  }

  WasmFeatureSet copyWith({
    bool? simd,
    bool? threads,
    bool? exceptionHandling,
    bool? gc,
    bool? componentModel,
    Set<String>? additionalEnabled,
    Set<String>? additionalDisabled,
  }) {
    return WasmFeatureSet(
      simd: simd ?? this.simd,
      threads: threads ?? this.threads,
      exceptionHandling: exceptionHandling ?? this.exceptionHandling,
      gc: gc ?? this.gc,
      componentModel: componentModel ?? this.componentModel,
      additionalEnabled: additionalEnabled ?? this.additionalEnabled,
      additionalDisabled: additionalDisabled ?? this.additionalDisabled,
    );
  }

  static String _normalizeFeatureName(String value) {
    final trimmed = value.trim().toLowerCase();
    switch (trimmed) {
      case 'exceptionhandling':
      case 'exception_handling':
        return _exceptionHandlingFeatureName;
      case 'componentmodel':
      case 'component_model':
        return _componentModelFeatureName;
      default:
        return trimmed.replaceAll('_', '-');
    }
  }
}
