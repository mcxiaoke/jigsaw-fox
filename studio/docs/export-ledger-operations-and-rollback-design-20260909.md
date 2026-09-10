# 导出记账体系升级方案：Operation 事实源 + 投影模型（L1/L2/L3）

> 日期：2026-09-09
> 状态：已拍板，L1 本轮实施；L2/L3 待命
> 关联：回滚某次导出需求（本日会话）、`studio/docs/unified-content-export-and-storage-architecture.md`、`studio/docs/studio-server-architecture-and-api-20260908.md`

---

## 1. 背景与动机

现状导出台账（`.studio/ledger/exports.json` + `exports_events.jsonl`）在**防重、防覆盖、损坏重建**上行为正确（幂等键、tmp+replace 原子写、损坏自动事件重建、legacy 迁移、快照保留 30 份、先记账后交付）。但它**不是为"可回滚、可追溯修改史"设计的**，具体三个根因：

- **R1 · 事件流只记"结果"，不记"动作史"**：`exports_events.jsonl` 仅有 `action=append`（record 全量镜像），重建分支 `_try_rebuild_from_events()` 只认 append；`supersedes`/`revision` 只是单链"被谁替换"，无法表达/回放"整批撤销、补丁换图"这类动作。
- **R2 · 没有"一次导出"操作实体**：一次导出把状态写进 6 处互不关联文件（账本 records / 事件镜像 / 审计流水 / release index / batch json / 镜像图片 + legacy exported.json 视图），**无共享 opId**；审计 `log_export` 只记摘要，不含 items/recordId/文件清单 → 撤销只能按模块/时间反推。
- **R3 · 同一事实多副本、双写无校验**：records 同时物化在 `exports.json` 与 `exports_events.jsonl`，`append_events()` 失败仅告警；`load_exported_ledger()` 又现场派生 legacy 视图 → 权威源不唯一，状态漂移风险存在。

## 2. 目标模型

**核心思想：把"一次导出"从"散落多处的隐式副作用集合"提升为一等实体（Operation）；事件日志（append-only、动作齐全）作为唯一事实源；`exports.json` / `release/index.json` 降级为"可随时重放重建的投影"。**

- 撤销 = **追加 rollback 事件 + 更新投影**，不是物理"抹除记录"；历史永存、可审计、可反悔、可重建。
- 读侧（起始序号、已导出排除、防重、补丁 revision）只消费 records 投影，**正常导出工作流零影响**（见 §6）。

## 3. 分级落地

### L1 · 最小升级（本轮实施）

纯增量、读侧零侵入，全部改动集中在写路径/撤销路径：

1. **记录增加 `opId`（可选字段）**：`append_records()` 对本批新增记录统一回填批次级 opId（调用方零改动；幂等续跑时重复记录被跳过、不产生新 opId）。格式 `op_YYYYMMDD_HHMMSSmmm`（UTC）。
2. **事件流补动作类型**：新增 `rollback` 事件，自包含 `{opId, recordIds}`（撤销补偿信息内嵌，保证"增量撤销"与"全量重建"消费同一数据、结果必然一致）。
3. **重建逻辑升级**：`_try_rebuild_from_events()` 按序重放 append（按 recordId 去重）/ rollback（按 recordIds 删除），撤销记录不会在重建时复活。
4. **撤销 API**：`ExportsLedger.rollback_operation(op_id)` —— 剔除该 op 全部 records、重建索引、追加 rollback 事件、原子保存。被 supersedes 的旧记录因 `_superseded_ids` 为派生索引而**自动复活**，无悬空 active。
5. **回滚工具**：`studio/core/export_rollback.py`（`list_ops` / `undo_op` / `undo_last` + CLI `--dry-run` / `--yes`）：
   - 通用（全模块）：按 opId 撤销 ledger 记录 → 已导出集合收缩 → 防重放行、可重导（序号复用见 §6）；
   - **镜像投影自动回退（L1.1 起全模块覆盖）**：
     - main：release `index.json` 按 batchId 移除 entry、重算 `maxOrder`/`totalCount`（version 不回退）、删除 `batches/{batchId}.json`；
     - daily：release `daily/index.json` 按 month 移除 entry、`currentMonth` 重算、删除被移除 entry 指向的 `zips/{zip}`；
     - events / collections：release `{module}/index.json` 按 id(packId) 移除 entry、删除 entry 指向的 `packs/{zip}` 与 `covers/{cover}`；
   - 撤销执行后经 `workspace.log_export("rollback_export", entity=op_id, ...)` 追加一条撤销审计到 `logs/exports.jsonl`，与既有导出审计并列可查；
   - 撤销前自动快照 ledger（沿用 `backup_ledger_snapshot`）+ 涉及模块的 release index.json 副本到 `ledger/backups/`，支持手工恢复。

**Schema 决策**：`opId` 为可选扩展字段、`rollback` 由 action 字段区分 → **schemaVersion 保持 2 不升版**（无消费方分支，读取天然兼容）；旧记录无 opId 不自动回填（避免伪造整库操作），在 `list_ops` 中归入 legacy 组展示。

### L2 · 投影化（可选强化，L1 稳定后再评）

- `exports.json` 与 `release/index.json` 正式降级为"每次提交/回滚后刷新的物化投影"，事件流为唯一权威；
- 增加启动自检：重放事件数 vs records 数一致性校验，不一致告警；
- 消灭 R3 双写分叉。

### L3 · 版本化镜像（进 backlog，待"线上图回退"需求出现）

- release `images/{order}-r{rev}.webp` 或 index 保留每关版本指针；patch 不再覆盖旧文件；
- 使"某关历史上换过哪几张图、何时换的、一键指回旧版"有完整答案；代价为镜像体积增长 + 导出器命名/索引改动。

## 4. L1 数据格式约定

```text
ledger record（exports.json records[] 内，新增可选键）:
  "opId": "op_20260909_143000123"     # 该记录所属的导出操作；旧记录无此键
  # L1.1 模块标识透传（定位 release 镜像投影用；由 exporter 记账项携带）:
  "month": "202609"                   # daily 模块
  "packId": "ev_demo_001"             # events/collections 模块

exports_events.jsonl（每行一条，新增动作类型）:
  {"v":2,"ts":"...Z","action":"rollback","opId":"op_...","recordIds":["rec_0001",...]}
```

不变量：

- 一次正式导出 = 一次 `append_records()` 调用 = 一个 opId（当前各 exporter 均单次调用；若未来分批需按批拆 op 并显式传 `op_id`）；
- 幂等续跑（中断重试）：重复记录被跳过，不产生第二个 opId；补记的新记录并入新 opId（边界场景，当前 exporter 全量重试下不会出现）；
- `_superseded_ids` 为派生集合 → 撤销 patch 记录即自动复活其 supersedes 的旧记录，无需补偿逻辑。

## 5. L1/L1.1 变更位置清单

| 文件 | 改动 |
|---|---|
| `studio/core/exports_ledger.py` | `new_op_id()`；`append_records` 回填 opId + 透传 month/packId；`rollback_operation()`；rollback 事件落盘；`_try_rebuild_from_events()` 升级（append 去重 + rollback 删除）；`get_ops_summary()` |
| `studio/core/export_rollback.py` | 新增：`list_ops` / `undo_op` / `undo_last` / CLI；main/daily/events/collections 镜像投影回退（index/批次/zip/cover）与撤销前快照 |
| `studio/exporters/pack_exporter_base.py` | 记账 entry 增加 `packId` 字段（一行；daily 已有 month） |
| `studio/test_rollback.py` | 新增：见 §7 |
| `studio/docs/CHANGES-20260909.md` | 顶部追加变更摘要 |

不改：`exporters/*` 选图/转码/两阶段发布路径、扫描/查重/试导出路径、legacy 迁移、schemaVersion（opId 与模块标识均由账本层兼容透传）。

## 6. 对现有导出工作流的影响（逐项核对）

| 现有功能 | 正常导出 | 撤销之后（预期行为） |
|---|---|---|
| 起始序号推算 `get_max_order()` / main 取 max(ledger, index) | 零影响 | main：index entry 移除、maxOrder 重算 → 序号回落复用、无空洞 |
| 已导出排除（UI 扫描标记 / excludeExported / "均已在历史批次中导出"拦截） | 零影响 | 该批 hash 释放 → 重新标记可导出、可重导 |
| 同素材防重 / 跨模块预警 `check_history_duplicate()` | 零影响 | 撤销 hash 重新可用；patch 撤销后旧记录复活，无 active 悬空 |
| 补丁 revision `get_next_revision()` | 零影响 | 撤销 patch 后再 patch，rev 从原链继续（行为与 patch 前一致） |
| 批次幂等重试 `append_records()` 幂等键 | 零影响 | 撤销后重导同 (module, logicalId, revision) 无冲突（记录已删） |
| 事件流损坏重建 | ⚠️ 唯一必改点 | 已升级：rollback 后重建不会复活被撤记录 |
| legacy exported.json 派生视图 | 自动跟随 | 自动收缩 |
| daily/events/collections 导出与撤销（L1.1） | 零影响 | index entry 按 month/packId 移除、zip/cover 产物删除；撤销后重导同月/同包重新入账（zip 命名按 hash 变化走修订，逻辑不变） |

崩溃安全：撤销非原子（records 投影 + index 回退），中断时下次导出取 `max(ledger, index)` 天然偏向保守，配合撤销前快照，不会出现 order 覆盖。

## 7. 测试计划（`studio/test_rollback.py`，unittest）

1. append 自动回填 opId：同批共享、幂等续跑不新增 opId；
2. `rollback_operation`：记录剔除、hash 释放、防重恢复放行；
3. patch 撤销复活：rev2 supersedes rev1 → rollback rev2 的 op → `get_active_record` 回 rev1；
4. 事件重建含 rollback：两 op append → rollback op1 → 删除 `exports.json` → 重建后仅剩 op2；
5. undo_op main 镜像：构造 release index/batch 文件 → 撤销后 entry 移除、maxOrder 重算、批次文件删除；
6. read_only 拒绝 rollback；未知 opId 返回失败；
7. L1.1：daily 撤销（month entry + zip 移除、currentMonth 重算）；events 撤销（packId entry + zip/cover 移除）；month/packId 字段持久化。

运行：`python -m unittest studio/test_ledger.py studio/test_rollback.py`（从仓库根；当前 23 项全绿）。

真实素材集成验证：`temp/rollback_e2e/run_e2e.py`（幂等可重跑）——以 C:/Home/Temp/Nature 真实图片构建 4 个素材库，真实导出器执行 main×2、event、collection、daily 各一次导出，随后用 CLI 与函数逐次回滚，覆盖：CLI undo-last、order 复用重导、patch rev2→撤销→rev1 复活、删 exports.json 后事件流重建一致、四模块镜像（index/batches/zip/cover）回退、撤销后同批可完整重导（防重释放闭环）。

## 8. 边界与暂不做（诚实清单）

- **L1.1 已完成**：main/daily/events/collections 四模块镜像投影均随撤销自动回退（ledger 透传 batchId/month/packId 定位）。残余边界：旧记录（L1.1 之前入库、无 month/packId）撤销时镜像回退尽力而为（找不到定位字段则只撤 ledger 并提示）；
- L2 投影化、L3 版本化镜像不纳入本轮；
- 旧记录（无 opId）不支持按 op 撤销，`list_ops` 归 legacy 展示；
- 试导出（trial）路径不写账本/事件，天然不受影响；
- 撤销不清理 outDir 交付文件（按需求边界，用户侧另行发布处理）。
