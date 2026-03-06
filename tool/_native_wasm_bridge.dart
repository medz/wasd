import 'package:wasd/src/wasm/backend/native/interpreter/features.dart'
    as _native_features;
import 'package:wasd/src/wasm/backend/native/interpreter/imports.dart'
    as _native_imports;
import 'package:wasd/src/wasm/backend/native/interpreter/instance.dart'
    as _native_instance;
import 'package:wasd/src/wasm/backend/native/interpreter/memory.dart'
    as _native_memory;
import 'package:wasd/src/wasm/backend/native/interpreter/module.dart'
    as _native_module;
import 'package:wasd/src/wasm/backend/native/interpreter/opcode.dart'
    as _native_opcode;
import 'package:wasd/src/wasm/backend/native/interpreter/runtime_global.dart'
    as _native_runtime_global;
import 'package:wasd/src/wasm/backend/native/interpreter/table.dart'
    as _native_table;
import 'package:wasd/src/wasm/backend/native/interpreter/value.dart'
    as _native_value;
import 'package:wasd/src/wasm/backend/native/interpreter/vm.dart' as _native_vm;

typedef WasmFeatureSet = _native_features.WasmFeatureSet;
typedef WasmFeatureProfile = _native_features.WasmFeatureProfile;
typedef WasmInstance = _native_instance.WasmInstance;
typedef WasmImports = _native_imports.WasmImports;
typedef WasmHostFunction = _native_imports.WasmHostFunction;
typedef WasmModule = _native_module.WasmModule;
typedef WasmMemory = _native_memory.WasmMemory;
typedef WasmTable = _native_table.WasmTable;
typedef WasmImport = _native_module.WasmImport;
typedef WasmTagImport = _native_imports.WasmTagImport;
typedef WasmImportKind = _native_module.WasmImportKind;
typedef WasmGlobalType = _native_module.WasmGlobalType;
typedef WasmRefType = _native_module.WasmRefType;
typedef WasmValueType = _native_module.WasmValueType;
typedef WasmF32Bits = _native_value.WasmF32Bits;
typedef WasmF64Bits = _native_value.WasmF64Bits;
typedef WasmVm = _native_vm.WasmVm;
typedef RuntimeGlobal = _native_runtime_global.RuntimeGlobal;
typedef Opcodes = _native_opcode.Opcodes;
