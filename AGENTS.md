# WASD 0.2 Agent Guide

## 目的

- 本文件定义 0.2 重构阶段的执行规范。
- 目标是确保实现过程可追踪、可审计、可复现，避免偏离已确认设计。

## 0.2 跟踪机制

- 任务源头：GitHub 父 issue `#5` 与其 sub-issues `#6` - `#13`。
- 执行清单：仓库根目录 `TODO.md`。
- 开发流程：
  1. 开始任务前，在 `TODO.md` 把目标项标为 `[-]`。
  2. 完成任务后，标记为 `[x]` 并写入 commit 哈希。
  3. 若受阻，保留 `[-]` 并补充阻塞原因。

## 0.2 实施标准

- 以 `#5` 的 API 设计为准，不引入未确认接口。
- 允许破坏性变更（0.x 阶段），但必须在 commit 中明确表达。
- `old.*` 目录（`old.lib`、`old.example`、`old.test`、`old.tool`）视为归档代码：
  - 不新增功能
  - 不作为新实现依赖
  - 不从新 `lib/` 代码中导入
- 所有公共 API 必须满足 `public_member_api_docs`。
- 代码风格使用 `dart format` 与现有 lint 规则。

## 提交与 PR 标准

- 使用 Conventional Commits。
- 破坏性变更使用 `!` 或 `BREAKING CHANGE` 脚注。
- 每个 commit 应可映射到 `TODO.md` 中至少一个条目。
- PR 描述必须关联 0.2 issue（使用 `Resolves #...`）。

## 完成定义（Definition of Done）

- 对应 `TODO.md` 条目已勾选并记录 commit。
- 涉及的 issue 状态与实现进度一致。
- `dart analyze` 无新增问题。
- 相关测试已新增/更新并通过。

## 对外信息约束

- 不在 GitHub issue / PR 中引用本地草案路径。
- 设计与约束应直接写入 issue/PR 正文，保证远程可读。

## 多 Agents 协作机制（0.2 持续优化）

- 目标：以角色分工降低实现偏移，同时持续优化用户 API 易用性、性能与可维护性。
- 角色：
  - 产品代理（Product）：面向 `lib/wasm.dart`、`lib/wasi.dart`、`lib/wasd.dart`、`README.md`、`example/`，定义 API 体验问题、验收标准与 issue 映射。
  - 开发代理（Engineering）：面向 `lib/src/` 与 `tool/`，负责设计取舍、实现与性能影响评估，避免引入未确认 API。
  - 测试代理（QA）：面向 `test/` 与运行矩阵，补齐回归用例、跨 runtime 行为一致性校验与失败复现路径。

### 任务流（每个迭代项都执行）

1. 产品代理先产出“问题定义 + 验收标准 + issue 归属（#5/#6-#13）”。
2. 开发代理按验收标准实现，附带最小可复现示例与必要性能对比。
3. 测试代理补齐/更新测试，执行 `dart analyze`、`dart test`，必要时执行 Node/Flutter 目标验证。
4. 合并前回填 `TODO.md`：进行中保留 `[-]`，完成后改为 `[x]` 并记录 commit。

### 统一门禁

- API 易用性：公共 API 文档齐全，README 与 example 中至少一条路径可直接运行验证。
- 性能：涉及运行时关键路径（解释器、内存、WASI I/O）的改动需说明基线与变化方向。
- 可维护性：不跨层直接依赖 backend 私有实现；保持错误类型、导出面与命名一致性。
