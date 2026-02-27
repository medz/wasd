import 'module.dart';
import 'value.dart';

final class RuntimeGlobal {
  RuntimeGlobal({
    required this.valueType,
    required this.mutable,
    this.valueTypeSignature,
    required WasmValue value,
  }) : _value = value.castTo(valueType);

  final WasmValueType valueType;
  final bool mutable;
  final String? valueTypeSignature;
  WasmValue _value;

  WasmValue get value => _value;

  void setValue(WasmValue value) {
    _value = value.castTo(valueType);
  }
}
