# WASD 0.2 TODO

## 跟踪规则

- 本文件是 0.2 实施的执行清单，所有开发先更新本文件再动代码。
- 每个任务都要绑定 issue（`#5` 或其子 issue）。
- 状态只使用：`[ ]` 未开始、`[-]` 进行中、`[x]` 已完成。
- 完成任务时必须补充对应 commit 哈希。

## 里程碑 A：基础切换（Issue #5）

- [x] 完成 0.2 工作区布局切换（`0.2 -> lib`，旧代码迁移到 `old.*`）
  - commit: `4d71536`
- [x] `tool -> old.tool`
  - commit: `9aebc76`
- [x] 分析器排除 `old.*` 目录
  - commit: `f16cf31`
- [x] 启用 `public_member_api_docs`
  - commit: `e381894`

## 里程碑 B：WASM 错误与值体系（Issue #6）

- [x] `errors.dart` 改为 `WasmError` 抽象基类
  - commit: `cde415b`
- [x] 增加 `RuntimeError`
  - commit: `cde415b`
- [x] 修复 `errors.dart` 的 API 文档告警
  - commit: `4227734`
- [x] 实现 `value.dart`（`ValueKind` + sealed/final 值类型）
  - commit: `df922a3`
- [x] `Vector128` 构造函数内长度校验（16 bytes）
  - commit: `df922a3`
- [x] 为 `value.dart` 补齐 `public_member_api_docs`
  - commit: `df922a3`

## 里程碑 C：Global/Table/Memory（Issue #7）

- [ ] 实现 `GlobalDescriptor` / `Global`
- [ ] 实现 `TableKind` / `TableDescriptor` / `Table`
- [ ] 实现 `MemoryDescriptor` / `Memory`（含 `buffer`、`grow`）
- [ ] 补齐对应 API 文档

## 里程碑 D：Module Import/Export 模型（Issue #8）

- [ ] 完成 `ImportExportKind<T, R>` 泛型工厂
- [ ] 完成 `ImportExportValue` / `ImportValue` / `ExportValue` 体系
- [ ] 完成 `Function/Global/Memory/TableImportExportValue`
- [ ] 完成 typedef：`Exports`、`ModuleImports`、`Imports`
- [ ] 完成 `ModuleImportDescriptor` / `ModuleExportDescriptor`
- [ ] 补齐对应 API 文档

## 里程碑 E：Module/Instance/WebAssembly（Issue #9）

- [ ] 完成 `Module` 最小接口与静态查询方法
- [ ] 完成 `Instance` 最小接口
- [ ] 完成 `WebAssembly` 最小接口
- [ ] 支持 `compileStreaming(Stream<List<int>>)`
- [ ] `instantiateModule` 返回 `Future<Instance>`

## 里程碑 F：WASM Backend 框架（Issue #10）

- [ ] 建立 `src/wasm/backend/js/` 适配边界
- [ ] 建立 `src/wasm/backend/native/` 目录与占位结构
- [ ] 明确 JS 平台类型桥接点（如 `i64 <-> bigint`）

## 里程碑 G：WASI 核心 API（Issue #11）

- [ ] 实现 `WASIVersion.preview1`
- [ ] 实现 `WASI` 构造参数与 `imports`
- [ ] 实现 `start(Instance)`（固定 `_start`）
- [ ] 实现 `initialize(Instance)`（固定 `_initialize`）
- [ ] 实现 `finalizeBindings(Instance, {Memory? memory})`
- [ ] 落实默认 memory 解析：`instance.exports['memory']`

## 里程碑 H：WASI preview1 后端（Issue #12）

- [ ] 建立 `src/wasi/preview1/native/`
- [ ] 建立 `src/wasi/preview1/js/web/`
- [ ] 建立 `src/wasi/preview1/js/node/`
- [ ] 对齐 Node 行为作为基准语义

## 里程碑 I：对外导出与测试（Issue #13）

- [ ] 新建 `lib/wasm.dart`
- [ ] 新建 `lib/wasi.dart`
- [ ] 新建 `lib/wasd.dart`（仅 re-export）
- [ ] 增加/更新 0.2 定向测试
- [ ] 执行并通过 `dart analyze`
- [ ] 执行并通过 `dart test`

## 当前执行焦点

- [-] 进入 Issue #7：`global.dart` / `table.dart` / `memory` 接口收敛。
