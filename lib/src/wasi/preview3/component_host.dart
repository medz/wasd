import '../component/async_host.dart';
import '../component/host.dart';
import '../component/resource_host.dart';
import '../component/versioned_host.dart';
import '../version.dart';
import '../../wasm/backend/native/interpreter/component.dart';

/// Internal WASI 0.3 / Preview3 component host boundary.
///
/// This fixed-version wrapper keeps Preview3 adapter code on the async-aware
/// component profile while host capability gaps remain explicitly reported.
/// It is not exported as public runtime support.
final class WASIPreview3ComponentHost {
  /// Creates a Preview3 component host over [componentHost] or a new host.
  WASIPreview3ComponentHost({WASIComponentHost? componentHost})
    : versionedHost = WASIComponentVersionedHost(
        version: WASIVersion.preview3,
        componentHost: componentHost,
      );

  /// Underlying versioned component-host facade.
  final WASIComponentVersionedHost versionedHost;

  /// Preview3 version profile.
  WASIComponentVersionProfile get profile => versionedHost.profile;

  /// Shared component host.
  WASIComponentHost get componentHost => versionedHost.componentHost;

  /// Prepares [component] for Preview3 component-host binding.
  WASIComponentVersionedBindingPlan prepareComponent(
    WasmComponent component, {
    bool validate = true,
  }) {
    return versionedHost.prepareComponent(component, validate: validate);
  }

  /// Prepares and binds [component] through the Preview3 profile.
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
    return versionedHost.bindComponent(
      component,
      validate: validate,
      resourceName: resourceName,
      onResourceDrop: onResourceDrop,
      asyncValueName: asyncValueName,
      maxBufferedElementsForStream: maxBufferedElementsForStream,
      onAsyncValueDrop: onAsyncValueDrop,
    );
  }
}
