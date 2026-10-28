// Internal canonical ABI faults; deliberately absent from package entrypoints.
// ignore_for_file: public_member_api_docs

enum WASIComponentResourceTrapKind { unknownHandle, wrongType, borrowed }

final class WASIComponentResourceTrap extends StateError {
  WASIComponentResourceTrap.unknownHandle(this.handle)
    : kind = WASIComponentResourceTrapKind.unknownHandle,
      super('Unknown component handle index: $handle.');

  WASIComponentResourceTrap.wrongType(this.handle)
    : kind = WASIComponentResourceTrapKind.wrongType,
      super('Component resource handle $handle has a different resource type.');

  WASIComponentResourceTrap.borrowed(this.handle)
    : kind = WASIComponentResourceTrapKind.borrowed,
      super('Cannot release lent WASI component resource: $handle.');

  final WASIComponentResourceTrapKind kind;
  final int handle;
}
