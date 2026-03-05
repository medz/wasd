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

- [x] 实现 `GlobalDescriptor` / `Global`
  - commit: `fe7c3a3`
- [x] 实现 `TableKind` / `TableDescriptor` / `Table`
  - commit: `05cf801`
- [x] 实现 `MemoryDescriptor` / `Memory`（含 `buffer`、`grow`）
  - commit: `7fd9ed6`
- [x] 补齐对应 API 文档
  - commit: `7fd9ed6`

## 里程碑 D：Module Import/Export 模型（Issue #8）

- [x] 完成 `ImportExportKind<T, R>` 泛型工厂
  - commit: `57eeaf6`
- [x] 完成 `ImportExportValue` / `ImportValue` / `ExportValue` 体系
  - commit: `57eeaf6`
- [x] 完成 `Function/Global/Memory/TableImportExportValue`
  - commit: `57eeaf6`
- [x] 完成 typedef：`Exports`、`ModuleImports`、`Imports`
  - commit: `57eeaf6`
- [x] 完成 `ModuleImportDescriptor` / `ModuleExportDescriptor`
  - commit: `57eeaf6`
- [x] 补齐对应 API 文档
  - commit: `57eeaf6`

## 里程碑 E：Module/Instance/WebAssembly（Issue #9）

- [x] 完成 `Module` 最小接口与静态查询方法
  - commit: `57eeaf6`
- [x] 完成 `Instance` 最小接口
  - commit: `6864e26`
- [x] 完成 `WebAssembly` 最小接口
  - commit: `6864e26`
- [x] 支持 `compileStreaming(Stream<List<int>>)`
  - commit: `6864e26`
- [x] `instantiateModule` 返回 `Future<Instance>`
  - commit: `6864e26`

## 里程碑 F：WASM Backend 框架（Issue #10）

- [x] 建立 `src/wasm/backend/js/` 适配边界
  - commit: `07c9000`
- [x] 建立 `src/wasm/backend/native/` 目录与占位结构
  - commit: `07c9000`
- [x] 实现 native backend：`decoder.dart`（二进制解码）+ `runtime.dart`（线性内存 + 栈机执行器）
  - commit: `eacfd91`

## 里程碑 G：WASI 核心 API（Issue #11）

- [x] 实现 `WASIVersion.preview1`
- [x] 实现 `WASI` 构造参数与 `imports`
- [x] 实现 `start(Instance)`（固定 `_start`）
- [x] 实现 `initialize(Instance)`（固定 `_initialize`）
- [x] 实现 `finalizeBindings(Instance, {Memory? memory})`
- [x] 落实默认 memory 解析：文档化语义，Node 后端由 host 自动处理

## 里程碑 H：WASI preview1 后端（Issue #12）

- [x] 建立 `src/wasi/preview1/native/`（UnimplementedError 占位）
- [x] 建立 `src/wasi/preview1/js/web/`（UnimplementedError 占位）
- [x] 建立 `src/wasi/preview1/js/node/`（Node.js `node:wasi` 实现）
- [x] 对齐 Node 行为作为基准语义（returnOnExit: true）

## 里程碑 I：对外导出与测试（Issue #13）

- [x] 新建 `lib/wasm.dart`
  - commit: `07c9000`
- [x] 新建 `lib/wasi.dart`
  - commit: `07c9000`
- [x] 新建 `lib/wasd.dart`（仅 re-export）
  - commit: `07c9000`
- [x] 增加/更新 0.2 定向测试（wasm_test.dart 20 项，wasi_test.dart 5 项）
  - commit: `388396e`
- [x] 执行并通过 `dart analyze`
  - commit: `388396e`
- [x] 执行并通过 `dart test`
  - commit: `388396e`

## 当前执行焦点

- [x] 所有里程碑 A–I 完成。
- [-] 持续优化：WASI JS（Node/Web）语义一致性与回归测试补强（Issue #12, #13）
  - note: in progress
  - verify: `dart analyze` (pass)
  - verify: `dart test` (pass)
  - verify: `dart test --platform node test/wasi_test.dart` (pass)
  - [x] CLI DOOM 基线与 VM/JS runtime 一致性矩阵（Issue #12, #13）
    - commit: `5146817`
  - scope: add preview1 minimal fs io set (`fd_read` / `fd_write` / `fd_close`) on native+web
  - scope: add preview1 process/env/random set (`args_*` / `environ_*` / `random_get`) on native+web
  - scope: add preview1 descriptor/time basics (`fd_fdstat_get` / `clock_time_get`) on native+web
  - scope: add preview1 preopen metadata (`fd_prestat_get` / `fd_prestat_dir_name`) on native+web
  - scope: keep unsupported syscall imports explicit with `ENOSYS` stubs (`sched_yield` / `path_open` / `poll_oneoff`)
  - [x] Node DOOM 首帧监控与图片产出链路（Issue #12, #13）
    - commit: `8b117b1`
  - [x] 提交 0.2 执行期沉淀的 `tool/` 与 CLI 示例资产（Issue #13）
    - commit: `094c48b`
  - [x] 新增 DOOM Flutter 全平台监控示例（Issue #13）
    - commit: `3390fcf`
  - [-] native backend 接入完整解释器执行链（Issue #10, #12, #13）
    - note: in progress (replace minimal opcode runtime with interpreter VM)
  - [-] Flutter 示例切换为纯 `wasd` 直跑 DOOM（Issue #13）
    - note: in progress (remove node runner/webview path)
