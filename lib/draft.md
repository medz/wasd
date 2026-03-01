# WASD 0.2 重构草案

> 状态：草案（持续补充）
>
> 日期：2026-03-01

## 1. 文档定位

- 本文是 0.2 的设计草案，**草案结论优先**。
- `src/wasm` 当前代码用于迭代验证，允许与草案阶段性不一致。
- 本文仅定义接口与约束，不展开实现细节。

## 2. 0.2 目标

- 0.x 允许重新设计 API 与内部结构。
- `wasm` / `wasi` 按 backend 分层设计。
- Native 平台目标：纯 Dart + `dart:io`。
- JS/Node 平台目标：优先直连原生能力。
- 清理旧版 POC 和过度设计，聚焦可用性与性能。

## 3. 接口草案（已确认）

### 3.1 错误模型

```dart
abstract class WasmError extends Error {
  WasmError(this.message, {this.cause});

  final String message;
  final Object? cause;
}

class CompileError extends WasmError {
  CompileError(super.message, {super.cause});
}

class LinkError extends WasmError {
  LinkError(super.message, {super.cause});
}

class RuntimeError extends WasmError {
  RuntimeError(super.message, {super.cause});
}
```

### 3.2 Value 类型系统

```dart
import 'dart:typed_data';

enum ValueKind<T extends Value<T, V>, V extends Object?> {
  funcref(FuncRef._, {'anyfunc'}),
  externref(ExternRef._),
  f32(Float32._),
  f64(Float64._),
  i32(Int32._),
  i64(Int64._),
  v128(Vector128._);

  const ValueKind(this._factory, [this.aliases = const {}]);

  final T Function(V value) _factory;
  final Set<String> aliases;

  T call(V ref) => _factory(ref);
}

sealed class Value<T extends Value<T, V>, V extends Object?> {
  const Value._(this.ref);

  final V ref;
  ValueKind<T, V> get kind;
}

final class FuncRef extends Value<FuncRef, Function> {
  const FuncRef._(super.ref) : super._();

  @override
  ValueKind<FuncRef, Function> get kind => .funcref;

  T call<T extends Object?>(
    List<Object?>? positionalArguments, [
    Map<Symbol, Object?>? namedArguments,
  ]) => Function.apply(ref, positionalArguments, namedArguments);
}

final class ExternRef extends Value<ExternRef, Object?> {
  const ExternRef._(super.ref) : super._();

  @override
  ValueKind<ExternRef, Object?> get kind => .externref;
}

final class Int32 extends Value<Int32, int> {
  const Int32._(super.ref) : super._();

  @override
  ValueKind<Int32, int> get kind => .i32;
}

final class Int64 extends Value<Int64, int> {
  const Int64._(super.ref) : super._();

  @override
  ValueKind<Int64, int> get kind => .i64;
}

final class Float32 extends Value<Float32, double> {
  const Float32._(super.ref) : super._();

  @override
  ValueKind<Float32, double> get kind => .f32;
}

final class Float64 extends Value<Float64, double> {
  const Float64._(super.ref) : super._();

  @override
  ValueKind<Float64, double> get kind => .f64;
}

final class Vector128 extends Value<Vector128, ByteData> {
  Vector128._(super.ref) : assert(ref.lengthInBytes == 16), super._() {
    if (ref.lengthInBytes != 16) {
      throw ArgumentError.value(
        ref.lengthInBytes,
        'ref.lengthInBytes',
        'must be exactly 16 bytes',
      );
    }
  }

  @override
  ValueKind<Vector128, ByteData> get kind => .v128;
}
```

### 3.3 Global 接口

```dart
class GlobalDescriptor<T extends Value<T, V>, V extends Object?> {
  const GlobalDescriptor({required this.value, this.mutable = false});

  final ValueKind<T, V> value;
  final bool mutable;
}

class Global<T extends Value<T, V>, V extends Object?> {
  Global(this._descriptor, this._value);

  final GlobalDescriptor<T, V> _descriptor;
  V _value;

  V get value => _value;

  set value(V value) {
    if (!_descriptor.mutable) {
      throw StateError('Cannot set value of immutable global');
    }
    _value = value;
  }
}
```

### 3.4 Table 接口

```dart
enum TableKind<T extends Value<T, V>, V extends Object?> {
  funcref(.funcref, {'anyfunc'}),
  externref(.externref);

  const TableKind(this.value, [this.aliases = const {}]);

  final Set<String> aliases;
  final ValueKind<T, V> value;
}

class TableDescriptor<T extends Value<T, V>, V extends Object?> {
  const TableDescriptor(this.element, this.initial, [this.maximum]);

  final TableKind<T, V> element;
  final int initial;
  final int? maximum;
}

abstract class Table<T extends Value<T, V>, V extends Object?>
    with Iterable<V> {
  Table(this.descriptor, this.fill);

  final TableDescriptor<T, V> descriptor;
  final V fill;

  int grow(int delta, [V? value]);
}
```

### 3.5 Memory 最小接口

```dart
import 'dart:typed_data';

class MemoryDescriptor {
  const MemoryDescriptor({required this.initial, this.maximum, this.shared});

  final int initial;
  final int? maximum;
  final bool? shared;
}

abstract class Memory {
  Memory(MemoryDescriptor descriptor);

  ByteBuffer get buffer;
  int grow(int delta);
}
```

### 3.6 Module Import/Export 类型模型

```dart
enum ImportExportKind<T extends Object, R extends ExportValue<T, R>> {
  function(FunctionImportExportValue._),
  global(GlobalImportExportValue._),
  memory(MemoryImportExportValue._),
  table(TableImportExportValue._);

  const ImportExportKind(this._factory);

  final R Function(T ref) _factory;

  R call(T ref) => _factory(ref);
}

sealed class ImportExportValue<T extends Object> {
  const ImportExportValue._(this.ref);

  final T ref;
}

sealed class ImportValue<T extends Object> extends ImportExportValue<T> {
  const ImportValue._(super.ref) : super._();
}

final class IntImportValue extends ImportValue<int> {
  const IntImportValue._(super.ref) : super._();
}

sealed class ExportValue<T extends Object, R extends ExportValue<T, R>>
    extends ImportExportValue<T> {
  const ExportValue._(super.ref) : super._();

  ImportExportKind<T, R> get kind;
}

final class FunctionImportExportValue
    extends ExportValue<Function, FunctionImportExportValue>
    implements ImportValue<Function> {
  const FunctionImportExportValue._(super.ref) : super._();

  @override
  ImportExportKind<Function, FunctionImportExportValue> get kind => .function;
}

final class GlobalImportExportValue
    extends ExportValue<Global, GlobalImportExportValue>
    implements ImportValue<Global> {
  const GlobalImportExportValue._(super.ref) : super._();

  @override
  ImportExportKind<Global, GlobalImportExportValue> get kind => .global;
}

final class MemoryImportExportValue
    extends ExportValue<Memory, MemoryImportExportValue>
    implements ImportValue<Memory> {
  const MemoryImportExportValue._(super.ref) : super._();

  @override
  ImportExportKind<Memory, MemoryImportExportValue> get kind => .memory;
}

final class TableImportExportValue
    extends ExportValue<Table, TableImportExportValue>
    implements ImportValue<Table> {
  const TableImportExportValue._(super.ref) : super._();

  @override
  ImportExportKind<Table, TableImportExportValue> get kind => .table;
}

typedef Exports = Map<String, ExportValue>;
typedef ModuleImports = Map<String, ImportValue>;
typedef Imports = Map<String, ModuleImports>;
```

### 3.7 Module 最小接口

```dart
import 'dart:typed_data';

class ModuleImportDescriptor<T extends Object, R extends ExportValue<T, R>> {
  const ModuleImportDescriptor({
    required this.kind,
    required this.module,
    required this.name,
  });

  final ImportExportKind<T, R> kind;
  final String module;
  final String name;
}

class ModuleExportDescriptor<T extends Object, R extends ExportValue<T, R>> {
  const ModuleExportDescriptor({required this.kind, required this.name});

  final ImportExportKind<T, R> kind;
  final String name;
}

abstract class Module {
  Module(ByteBuffer bytes);

  static List<ModuleImportDescriptor> imports(Module module);
  static List<ModuleExportDescriptor> exports(Module module);
  static List<ByteBuffer> customSections(
    Module module,
    String name,
  );
}
```

### 3.8 Instance 最小接口

```dart
abstract class Instance {
  Instance(Module module, [Imports imports = const {}]);

  Exports get exports;
}
```

### 3.9 WebAssembly 最小接口

```dart
import 'dart:async';
import 'dart:typed_data';

abstract class WebAssembly {
  Instance get instance;
  Module get module;

  static Future<Module> compile(ByteBuffer bytes);
  static Future<Module> compileStreaming(Stream<List<int>> source);

  static Future<WebAssembly> instantiate(
    ByteBuffer bytes, [
    Imports imports = const {},
  ]);
  static Future<WebAssembly> instantiateStreaming(
    Stream<List<int>> source, [
    Imports imports = const {},
  ]);
  static Future<Instance> instantiateModule(
    Module module, [
    Imports imports = const {},
  ]);

  static bool validate(ByteBuffer bytes);
}
```

### 3.10 WASI 最小接口

```dart
enum WASIVersion { preview1 }

class WASI {
  WASI({
    List<String> args = const [],
    Map<String, String> env = const {},
    Map<String, String> preopens = const {},
    bool returnOnExit = true,
    int stdin = 0,
    int stdout = 1,
    int stderr = 2,
    WASIVersion version = .preview1,
  });

  Imports get imports;
  int start(Instance instance);
  void initialize(Instance instance);
  void finalizeBindings(
    Instance instance, {
    Memory? memory,
  });
}
```

- `start` / `initialize` / `finalizeBindings` 约束：
  1. `start` 内部固定调用 `_start` 导出（与 Node 行为一致）。
  2. `initialize` 内部固定调用 `_initialize` 导出（与 Node 行为一致）。
  3. `finalizeBindings` 优先使用显式传入的 `memory`。
  4. 若 `memory == null`，则读取 `instance.exports['memory']`（与 Node 行为一致）。
  5. 两者都不可用时，抛出异常。
  6. `finalizeBindings` 为可选显式调用；`start` / `initialize` 在需要时应自动确保绑定完成。

## 4. 当前 0.2 代码快照（便于跟进）

- `src/wasm/module.dart`
  - 已有 `ImportExportKind`、`ImportExportValue`、`ImportValue`、`ExportValue`、`IntImportValue`、`FunctionImportExportValue`。
  - 其余导出值类型（global/memory/table）与描述符接口仍在补充中。
- `src/wasm/errors.dart`
  - 仍是 `WebAssemblyError/CompileError/LinkError`，尚未同步到本草案的 `WasmError` 体系。
- `src/wasm/webassembly.dart`、`src/wasm/instance.dart`、`src/wasm/backend/js.dart`
  - 目前仍为占位。

## 5. `wasm/` / `wasi/` 组织结构（草案）

仅定义目录层级与职责边界，`backend` 下不定义具体文件。

```text
src/wasm/
  errors.dart
  value.dart
  global.dart
  table.dart
  memory.dart
  module.dart
  instance.dart
  webassembly.dart
  backend/
    js/
    native/
```

目录职责：

- `wasm/*.dart`
  - 放 WebAssembly 表层 API 与主语义模型（当前草案第 3 章定义的接口）。
- `wasm/backend/js/`
  - 放 JS/Node 平台互操作适配（包含类型与数据桥接逻辑）。
- `wasm/backend/native/`
  - 预留给 Dart 侧原生实现路径；当前阶段只定目录，不定文件。

`wasi/` 目录结构：

```text
src/wasi/
  version.dart
  wasi.dart
  preview1/
    native/
    js/
      web/
      node/
```

目录职责：

- `wasi/version.dart`、`wasi/wasi.dart`
  - 放 WASI 版本声明与表层 API。
- `wasi/preview1/native/`
  - 放 preview1 在 Native 平台的实现。
- `wasi/preview1/js/`
  - 放 preview1 在 JS/Node 平台的实现与适配。
- `wasi/preview1/js/web/`、`wasi/preview1/js/node/`
  - 分别放浏览器与 Node.js 场景的 JS backend 实现。

`lib/` 导出结构：

```text
lib/
  wasm.dart
  wasi.dart
  wasd.dart
```

导出职责：

- `lib/wasm.dart`
  - 对外导出 WASM 相关公共 API。
- `lib/wasi.dart`
  - 对外导出 WASI 相关公共 API。
- `lib/wasd.dart`
  - 仅做聚合导出：re-export `wasm.dart` + `wasi.dart`。

## 6. 基本使用方法

### 6.1 WASM 的基本使用方法

```dart
import 'dart:typed_data';

Future<void> runWasm(ByteBuffer bytes) async {
  // 1) 预编译（可选）
  final module = await WebAssembly.compile(bytes);

  // 2) 直接从 module 实例化
  final instance = await WebAssembly.instantiateModule(module);

  // 3) 或者直接从 bytes 实例化
  final wasm = await WebAssembly.instantiate(bytes);

  // 4) 获取导出（通过 instance）
  final exports = instance.exports;
  final exports2 = wasm.instance.exports;

  // 5) 读取模块导入导出元信息
  final imports = Module.imports(module);
  final descriptors = Module.exports(module);
  final customSections = Module.customSections(module, 'name');

  // 防止示例变量未使用
  print([exports, exports2, imports, descriptors, customSections].length);
}
```

### 6.2 WASI 的基本使用方法

```dart
import 'dart:typed_data';

Future<void> runWasi(ByteBuffer bytes) async {
  final wasi = WASI(
    args: const ['app.wasm', '--help'],
    env: const {'FOO': 'bar'},
    preopens: const {'/sandbox': './sandbox'},
    returnOnExit: true,
    stdin: 0,
    stdout: 1,
    stderr: 2,
    version: .preview1,
  );

  // 1) 把 WASI imports 注入实例化
  final wasm = await WebAssembly.instantiate(bytes, wasi.imports);

  // 2) 绑定 memory（可选显式调用；start/initialize 会自动确保绑定）
  // wasi.finalizeBindings(wasm.instance);
  // wasi.finalizeBindings(wasm.instance, memory: someMemory);

  // 3) initialize 为可选调用；内部固定调用 `_initialize`
  // wasi.initialize(wasm.instance);

  // 4) command 模块入口（内部固定调用 `_start`）
  final exitCode = wasi.start(wasm.instance);
  print('exitCode=$exitCode');
}
```
