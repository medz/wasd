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
