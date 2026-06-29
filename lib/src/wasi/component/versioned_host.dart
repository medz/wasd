import '../../wasm/backend/native/interpreter/component.dart';
import '../version.dart';
import 'adapter_host.dart';
import 'adapter_plan.dart';
import 'async_host.dart';
import 'canonical_host.dart';
import 'host.dart';
import 'resource_host.dart';
import 'wit_adapter.dart';
import 'wit_document.dart';

/// Versioned component-host facade for WASI Preview2/Preview3 adapters.
///
/// It separates version profile checks from host capability checks so P2/P3
/// adapters can report whether a canonical definition is outside the selected
/// WASI version surface or inside the version surface but not implemented by
/// the current host yet.
final class WASIComponentVersionedHost {
  /// Creates a versioned host facade for [version].
  WASIComponentVersionedHost({
    required WASIVersion version,
    WASIComponentHost? componentHost,
  }) : profile = WASIComponentVersionProfile.forVersion(version),
       componentHost = componentHost ?? WASIComponentHost();

  /// Version profile enforced by this facade.
  final WASIComponentVersionProfile profile;

  /// Shared component host.
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

  /// Prepares and binds canonical `lift`/`lower` adapter operations.
  WASIComponentCanonicalAdapterProgram bindAdapters(
    WasmComponent component, {
    bool validate = true,
    Map<int, WASIComponentCanonicalAdapterCallback> coreFunctions =
        const <int, WASIComponentCanonicalAdapterCallback>{},
    Map<int, WASIComponentCanonicalAdapterCallback> componentFunctions =
        const <int, WASIComponentCanonicalAdapterCallback>{},
  }) {
    return prepareComponent(component, validate: validate).bindAdapters(
      coreFunctions: coreFunctions,
      componentFunctions: componentFunctions,
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

  /// Prepares a WIT world against this WASI version profile.
  WASIComponentVersionedWitWorldPlan prepareWitWorld(
    WASIComponentWitDocument document, {
    String? worldName,
  }) {
    final world = _selectWitWorld(document, worldName);
    final errors = _witWorldVersionErrors(profile, document, world);
    final functions = wasiComponentWitWorldFunctions(document, world);
    return WASIComponentVersionedWitWorldPlan._(
      profile: profile,
      document: document,
      world: world,
      versionErrors: errors,
      functions: functions,
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

  /// Canonical `lift`/`lower` adapter plans captured before host binding.
  List<WASIComponentCanonicalAdapterPlan> get adapterPlans =>
      componentPlan.adapterPlans;

  /// Whether [bind] can build a component host binding without throwing.
  bool get canBind => versionErrors.isEmpty && componentPlan.canBind;

  /// Binds direct primitive canonical `lift`/`lower` adapter operations.
  WASIComponentCanonicalAdapterProgram bindAdapters({
    Map<int, WASIComponentCanonicalAdapterCallback> coreFunctions =
        const <int, WASIComponentCanonicalAdapterCallback>{},
    Map<int, WASIComponentCanonicalAdapterCallback> componentFunctions =
        const <int, WASIComponentCanonicalAdapterCallback>{},
  }) {
    if (versionErrors.isNotEmpty) {
      throw WASIComponentVersionUnsupportedException(versionErrors);
    }
    return componentPlan.bindAdapters(
      coreFunctions: coreFunctions,
      componentFunctions: componentFunctions,
    );
  }

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

/// Prepared WIT world ingestion report for one WASI version profile.
final class WASIComponentVersionedWitWorldPlan {
  WASIComponentVersionedWitWorldPlan._({
    required this.profile,
    required this.document,
    required this.world,
    required List<WASIComponentVersionedWitWorldError> versionErrors,
    required List<WASIComponentWitFunctionBinding> functions,
  }) : versionErrors = List<WASIComponentVersionedWitWorldError>.unmodifiable(
         versionErrors,
       ),
       functions = List<WASIComponentWitFunctionBinding>.unmodifiable(
         functions,
       ),
       bindingErrors = wasiComponentWitAdapterBindingErrors(functions);

  /// Version profile used for WIT world ingestion.
  final WASIComponentVersionProfile profile;

  /// Parsed WIT document.
  final WASIComponentWitDocument document;

  /// Selected world boundary.
  final WASIComponentWitWorld world;

  /// Version-specific WIT ingestion errors.
  final List<WASIComponentVersionedWitWorldError> versionErrors;

  /// Direct world items preserved in declaration order.
  List<WASIComponentWitWorldItem> get items => world.items;

  /// Whether this WIT world can enter adapter binding for [profile].
  bool get canIngest => versionErrors.isEmpty;

  /// Local WIT functions expanded from imports, exports, and local includes.
  final List<WASIComponentWitFunctionBinding> functions;

  /// Binding errors for WIT functions inside this version profile.
  final List<WASIComponentWitAdapterBindingError> bindingErrors;

  /// Whether this WIT world can bind executable synchronous adapters.
  bool get canBindAdapters => canIngest && bindingErrors.isEmpty;

  /// Binds local WIT interface functions to executable adapter callbacks.
  WASIComponentWitAdapterProgram bindAdapters({
    Map<String, WASIComponentWitAdapterCallback> imports =
        const <String, WASIComponentWitAdapterCallback>{},
    Map<String, WASIComponentWitAdapterCallback> exports =
        const <String, WASIComponentWitAdapterCallback>{},
  }) {
    if (versionErrors.isNotEmpty) {
      throw WASIComponentVersionedWitWorldUnsupportedException(versionErrors);
    }
    final errors = bindingErrors;
    if (errors.isNotEmpty) {
      throw WASIComponentWitAdapterBindingException(errors);
    }
    return WASIComponentWitAdapterProgram.bind(
      functions,
      imports: imports,
      exports: exports,
    );
  }
}

/// WIT world item or function rejected by a WASI version profile.
final class WASIComponentVersionedWitWorldError {
  /// Creates a WIT world version-profile error.
  const WASIComponentVersionedWitWorldError({
    required this.profile,
    required this.item,
    required this.targetName,
    required this.reason,
    this.function,
  });

  /// Version profile that rejected the WIT boundary.
  final WASIComponentVersionProfile profile;

  /// World item that introduced the rejected boundary.
  final WASIComponentWitWorldItem item;

  /// Human-readable target path, such as `run.run`.
  final String targetName;

  /// Optional function boundary when a local interface function was rejected.
  final WASIComponentWitFunction? function;

  /// Human-readable rejection reason.
  final String reason;

  @override
  String toString() => '$targetName: $reason';
}

/// Thrown when WIT world ingestion fails the selected WASI version profile.
final class WASIComponentVersionedWitWorldUnsupportedException
    implements Exception {
  /// Creates an exception from WIT version [errors].
  WASIComponentVersionedWitWorldUnsupportedException(
    Iterable<WASIComponentVersionedWitWorldError> errors,
  ) : errors = List<WASIComponentVersionedWitWorldError>.unmodifiable(errors);

  /// WIT version errors that blocked adapter binding.
  final List<WASIComponentVersionedWitWorldError> errors;

  @override
  String toString() {
    final buffer = StringBuffer(
      'WASI component version profile cannot bind WIT world',
    );
    for (final error in errors) {
      buffer
        ..write('\n')
        ..write(error);
    }
    return buffer.toString();
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

WASIComponentWitWorld _selectWitWorld(
  WASIComponentWitDocument document,
  String? worldName,
) {
  if (worldName != null) {
    final world = document.worldNamed(worldName);
    if (world == null) {
      throw StateError("WIT document does not declare world '$worldName'.");
    }
    return world;
  }
  if (document.worlds.length != 1) {
    throw StateError(
      'WIT document must declare exactly one world or pass worldName; found '
      '${document.worlds.length}.',
    );
  }
  return document.worlds.single;
}

List<WASIComponentVersionedWitWorldError> _witWorldVersionErrors(
  WASIComponentVersionProfile profile,
  WASIComponentWitDocument document,
  WASIComponentWitWorld world,
) {
  final errors = <WASIComponentVersionedWitWorldError>[];
  for (final item in world.items) {
    final target = item.target;
    if (target.isQualified) {
      if (_requiresPreview3WitTarget(target.text) &&
          !_profileSupportsPreview3Async(profile)) {
        errors.add(
          WASIComponentVersionedWitWorldError(
            profile: profile,
            item: item,
            targetName: target.text,
            reason: '${profile.label} cannot ingest WASI 0.3 WIT target.',
          ),
        );
      }
      continue;
    }
    if (item.direction == WASIComponentWitWorldItemDirection.include) {
      final included = document.worldNamed(target.text);
      if (included != null) {
        errors.addAll(_witWorldVersionErrors(profile, document, included));
      }
      continue;
    }
    final interface = document.interfaceNamed(target.text);
    if (interface == null) {
      continue;
    }
    for (final function in interface.functions) {
      if (!function.usesPreview3AsyncFeatures) {
        continue;
      }
      if (_profileSupportsPreview3Async(profile)) {
        continue;
      }
      errors.add(
        WASIComponentVersionedWitWorldError(
          profile: profile,
          item: item,
          function: function,
          targetName: '${interface.name}.${function.name}',
          reason:
              '${profile.label} does not include Preview3 async WIT '
              'functions, streams, or futures.',
        ),
      );
    }
  }
  return List<WASIComponentVersionedWitWorldError>.unmodifiable(errors);
}

bool _profileSupportsPreview3Async(WASIComponentVersionProfile profile) {
  return profile.canonicalAreas.contains(
    WASIComponentCanonicalCapabilityArea.asyncValue,
  );
}

bool _requiresPreview3WitTarget(String target) {
  return target.contains('@0.3') || target.contains('@0.3.0');
}
