import '../../wasm/backend/native/interpreter/component.dart';
import '../version.dart';
import 'async_host.dart';
import 'canonical_host.dart';
import 'host.dart';
import 'resource_host.dart';

/// Versioned component-host facade for future WASI Preview2/Preview3 adapters.
///
/// This is intentionally internal. It separates version profile checks from
/// host capability checks so P2/P3 adapters can report whether a canonical
/// definition is outside the selected WASI version surface or inside the
/// version surface but not implemented by the current host yet. It is not a
/// public runtime support claim.
final class WASIComponentVersionedHost {
  /// Creates a versioned host facade for [version].
  WASIComponentVersionedHost({
    required WASIVersion version,
    WASIComponentHost? componentHost,
  }) : profile = WASIComponentVersionProfile.forVersion(version),
       componentHost = componentHost ?? WASIComponentHost();

  /// Version profile enforced by this facade.
  final WASIComponentVersionProfile profile;

  /// Shared internal component host.
  final WASIComponentHost componentHost;

  /// Prepares [component] against the selected WASI version and host support.
  WASIComponentVersionedBindingPlan prepareComponent(
    WasmComponent component, {
    bool validate = true,
  }) {
    final componentPlan = componentHost.prepareComponent(
      component,
      validate: validate,
    );
    final versionErrors = componentPlan.validationErrors.isEmpty
        ? _versionSupportErrors(
            profile,
            componentPlan,
            componentHost.canonicalHost,
          )
        : const <WASIComponentVersionSupportError>[];
    return WASIComponentVersionedBindingPlan._(
      host: this,
      componentPlan: componentPlan,
      versionErrors: versionErrors,
    );
  }

  /// Prepares and binds [component].
  WASIComponentHostBinding bindComponent(
    WasmComponent component, {
    bool validate = true,
    String Function(WASIComponentResourceBinding binding)? resourceName,
    void Function(WASIComponentResourceBinding binding, Object resource)?
    onResourceDrop,
    String Function(WASIComponentAsyncValueBinding binding)? asyncValueName,
    int? Function(WASIComponentAsyncValueBinding binding)?
    maxBufferedElementsForStream,
    void Function(WASIComponentAsyncValueBinding binding)? onAsyncValueDrop,
  }) {
    return prepareComponent(component, validate: validate).bind(
      resourceName: resourceName,
      onResourceDrop: onResourceDrop,
      asyncValueName: asyncValueName,
      maxBufferedElementsForStream: maxBufferedElementsForStream,
      onAsyncValueDrop: onAsyncValueDrop,
    );
  }
}

/// Component canonical operation profile for one WASI version.
final class WASIComponentVersionProfile {
  const WASIComponentVersionProfile._({
    required this.version,
    required this.label,
    required this.canonicalAreas,
  });

  /// Returns the component-host profile for [version].
  factory WASIComponentVersionProfile.forVersion(WASIVersion version) {
    return switch (version) {
      WASIVersion.preview1 => preview1,
      WASIVersion.preview2 => preview2,
      WASIVersion.preview3 => preview3,
    };
  }

  /// Preview1 is a core-module import-object host, not a component host.
  static const preview1 = WASIComponentVersionProfile._(
    version: WASIVersion.preview1,
    label: 'WASI Preview1',
    canonicalAreas: <WASIComponentCanonicalCapabilityArea>{},
  );

  /// Preview2 profile for synchronous component-model host work.
  static const preview2 = WASIComponentVersionProfile._(
    version: WASIVersion.preview2,
    label: 'WASI 0.2 / Preview2',
    canonicalAreas: <WASIComponentCanonicalCapabilityArea>{
      WASIComponentCanonicalCapabilityArea.adapterGeneration,
      WASIComponentCanonicalCapabilityArea.resource,
      WASIComponentCanonicalCapabilityArea.errorContext,
    },
  );

  /// Preview3 profile including Component Model async canonical areas.
  static const preview3 = WASIComponentVersionProfile._(
    version: WASIVersion.preview3,
    label: 'WASI 0.3 / Preview3',
    canonicalAreas: <WASIComponentCanonicalCapabilityArea>{
      WASIComponentCanonicalCapabilityArea.adapterGeneration,
      WASIComponentCanonicalCapabilityArea.resource,
      WASIComponentCanonicalCapabilityArea.asyncValue,
      WASIComponentCanonicalCapabilityArea.waitable,
      WASIComponentCanonicalCapabilityArea.subtask,
      WASIComponentCanonicalCapabilityArea.task,
      WASIComponentCanonicalCapabilityArea.context,
      WASIComponentCanonicalCapabilityArea.threadIdentity,
      WASIComponentCanonicalCapabilityArea.threadScheduling,
      WASIComponentCanonicalCapabilityArea.errorContext,
    },
  );

  /// WASI version represented by this profile.
  final WASIVersion version;

  /// Human-readable version label.
  final String label;

  /// Canonical operation areas that belong to this version profile.
  final Set<WASIComponentCanonicalCapabilityArea> canonicalAreas;

  /// Whether [capability] is part of this version profile.
  bool includesCapability(WASIComponentCanonicalKindCapability capability) {
    return canonicalAreas.contains(capability.area);
  }
}

/// Prepared versioned component binding report.
final class WASIComponentVersionedBindingPlan {
  const WASIComponentVersionedBindingPlan._({
    required WASIComponentVersionedHost host,
    required this.componentPlan,
    required this.versionErrors,
  }) : _host = host;

  final WASIComponentVersionedHost _host;

  /// Underlying component-host binding plan.
  final WASIComponentHostBindingPlan componentPlan;

  /// Canonical definitions outside this host's WASI version profile.
  final List<WASIComponentVersionSupportError> versionErrors;

  /// Component validation errors that must be fixed before binding.
  List<WasmComponentValidationError> get validationErrors =>
      componentPlan.validationErrors;

  /// Unsupported canonical definitions that are inside the version profile but
  /// not implemented by this host yet.
  List<WASIComponentCanonicalHostUnsupportedDefinition>
  get unsupportedDefinitions => componentPlan.unsupportedDefinitions;

  /// Host-specific binding gaps that must be wired before binding.
  List<WASIComponentHostBindingError> get bindingErrors =>
      componentPlan.bindingErrors;

  /// Canonical adapter resource-handle uses captured before host binding.
  List<WASIComponentResourceUse> get resourceUses => componentPlan.resourceUses;

  /// Whether [bind] can build a component host binding without throwing.
  bool get canBind => versionErrors.isEmpty && componentPlan.canBind;

  /// Defines component resources/async values and binds the canonical program.
  WASIComponentHostBinding bind({
    String Function(WASIComponentResourceBinding binding)? resourceName,
    void Function(WASIComponentResourceBinding binding, Object resource)?
    onResourceDrop,
    String Function(WASIComponentAsyncValueBinding binding)? asyncValueName,
    int? Function(WASIComponentAsyncValueBinding binding)?
    maxBufferedElementsForStream,
    void Function(WASIComponentAsyncValueBinding binding)? onAsyncValueDrop,
  }) {
    if (versionErrors.isNotEmpty) {
      throw WASIComponentVersionUnsupportedException(versionErrors);
    }
    return componentPlan.bind(
      resourceName: resourceName,
      onResourceDrop: onResourceDrop,
      asyncValueName: asyncValueName,
      maxBufferedElementsForStream: maxBufferedElementsForStream,
      onAsyncValueDrop: onAsyncValueDrop,
    );
  }

  /// Versioned host that owns this binding plan.
  WASIComponentVersionedHost get host => _host;
}

/// A canonical definition that is outside a WASI version profile.
final class WASIComponentVersionSupportError {
  /// Creates a version support error.
  const WASIComponentVersionSupportError({
    required this.canonicalIndex,
    required this.definition,
    required this.profile,
    required this.capability,
  });

  /// Canonical definition index in the decoded component.
  final int canonicalIndex;

  /// Canonical definition outside [profile].
  final WasmComponentCanonicalDefinition definition;

  /// Version profile that rejected [definition].
  final WASIComponentVersionProfile profile;

  /// Canonical capability required by [definition].
  final WASIComponentCanonicalKindCapability capability;

  /// Canonical kind that cannot be used with [profile].
  WasmComponentCanonicalKind get kind => definition.kind;

  /// Human-readable rejection reason.
  String get reason =>
      '${profile.label} does not include ${capability.area.name} canonical operations.';

  @override
  String toString() {
    return 'canonical[$canonicalIndex].${definition.kind.name}: $reason';
  }
}

/// Thrown when a component uses canonical operations outside a WASI profile.
final class WASIComponentVersionUnsupportedException implements Exception {
  /// Creates an exception from version support [errors].
  WASIComponentVersionUnsupportedException(
    Iterable<WASIComponentVersionSupportError> errors,
  ) : errors = List<WASIComponentVersionSupportError>.unmodifiable(errors);

  /// Version support errors that blocked binding.
  final List<WASIComponentVersionSupportError> errors;

  @override
  String toString() {
    final buffer = StringBuffer(
      'WASI component version profile cannot bind component',
    );
    for (final error in errors) {
      buffer
        ..write('\n')
        ..write(error);
    }
    return buffer.toString();
  }
}

List<WASIComponentVersionSupportError> _versionSupportErrors(
  WASIComponentVersionProfile profile,
  WASIComponentHostBindingPlan componentPlan,
  WASIComponentCanonicalHost canonicalHost,
) {
  final errors = <WASIComponentVersionSupportError>[];
  final definitions = componentPlan.canonicalPlan.canonicalDefinitions;
  for (var index = 0; index < definitions.length; index++) {
    final definition = definitions[index];
    final capability = canonicalHost.canonicalKindCapability(definition.kind);
    if (!profile.includesCapability(capability)) {
      errors.add(
        WASIComponentVersionSupportError(
          canonicalIndex: index,
          definition: definition,
          profile: profile,
          capability: capability,
        ),
      );
    }
  }
  return List<WASIComponentVersionSupportError>.unmodifiable(errors);
}
