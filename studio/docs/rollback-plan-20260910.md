# 回滚/台账功能实施方案（对应审查报告 P1-【5】 / 决策清单 3、4、12）

- 编写日期：2026-09-10
- 依据：`docs/studio-full-review-20260910.md` P1-【5】（回滚/台账无 HTTP 接口，601 行代码进不了工作流）、P0-【3】（回滚非原子）
- 交付形态：**独立前端页面 `rollback.html`，不与 `index.html` 混合**

---

## 一、功能清单（基于现有能力梳理）

回滚引擎 `core/export_rollback.py` 与账本 `core/exports_ledger.py` 已具备：

| 能力 | 现状 |
|---|---|
| 列出可撤销操作 | `list_ops()` → 按 opId 聚合：记录数、模块、batchIds、order 区间、导出时间；无 opId 的 legacy 记录单独成组（不可撤） |
| 查看单次导出文件明细 | 账本 `records` 按 opId 过滤；字段含 sourcePath / targetFile / logicalId / order / module / revision / supersedes / exportedAt / sourceHash |
| 回滚预览 | `undo_op(dry_run=True)` 返回影响面文案 |
| 执行回滚 | 账本剔除 + 追加自包含 rollback 事件（损坏重建不复活）+ 被 supersedes 的旧记录自动复活 |
| release 镜像回退 | main（删批次目录 + index 回退）、daily（删 zip + index）、events/collections（删 packs/covers + index）均已实现 |
| 自动快照 | 撤销前备份账本与各模块 index.json 到 `.studio/ledger/backups/`（保留 30 份） |
| 审计留痕 | 撤销后写 `rollback_export` 事件到 exports.jsonl；事件流本身可作审计源 |
| 撤销原因 | `reason` 参数已支持，写入审计 |

页面功能定为 6 块：

1. **操作列表**（主表格）：时间倒序展示——opId、时间、模块徽章、记录数、order 区间、批次；模块/关键字筛选；legacy 组单独提示"不支持按操作撤销"
2. **操作详情**：点开任一操作 → 文件级记录表（源路径、目标文件、logicalId、order、版本、是否已被修订替代）
3. **回滚预览**：调 dry-run，展示"将剔除 N 条记录、涉及模块、镜像会删什么"
4. **执行回滚**：二次确认弹窗（预览内容 + 警示"将删除 release 中对应文件" + 填写原因）
5. **回滚结果**：成功摘要（剔除条数、快照文件名）/ warn 黄条（镜像不完整需人工核查）/ 失败
6. **回滚审计**（Tab2）：最近的 rollback_export 审计事件 + 快照备份列表

## 二、前置修复（不修则界面不敢用）

### 2.1 P0-3 回滚原子性（决策清单第 4 项）

现状：`undo_op`（export_rollback.py:369-389）先 `ledger.rollback_operation()` 落盘，再逐模块 `_cleanup_release_for_module()`；任一模块失败仍返回 `ok: True`，剩余模块不再处理。

改为「**快照 → 回退全部镜像 → 成功后才回滚账本**」：

1. 撤销前自动快照账本 + 涉及模块的 release index.json（现有逻辑保留，前移）；
2. 先执行各模块镜像回退（index 回退 + 文件删除），收集每个模块的结果；
3. 任一模块回退失败 → **整体失败**：从快照还原已回退模块的 index.json（无法还原的文件删除操作在结果中明确列出），不回滚账本，返回 `ok: False` + 失败模块明细；
4. 全部镜像回退成功 → 才执行 `ledger.rollback_operation(op_id, reason)`；账本回滚失败同样返回 `ok: False`；
5. 成功后追加 `rollback_export` 审计（现有逻辑保留）。

注意点：
- 文件删除（批次目录 / zip / packs / covers）不可逆，但它们只在对应 index entry 移除之后才会删除，且 index 回退失败时会中止，删除操作本身失败只影响"孤儿文件"而不破坏数据一致性——在结果 `warn` 中列出即可；
- index.json 还原使用快照副本 `shutil.copy2` 覆盖（原子写：先写 tmp 再 replace）；
- `undo_last` 复用 `undo_op`，无需单独改。

### 2.2 路径规范化防越界（P2 项）

`export_rollback.py` 两处 `str(rel).lstrip("/")`（daily zip :193、packs/covers :254）未防 `..`。暴露成 HTTP 接口前补规范化：

```python
def _safe_release_rel(ws, module: str, rel: str) -> Path | None:
    base = (ws.release_dir / module).resolve()
    p = (base / str(rel).lstrip("/\\")).resolve()
    if not str(p).startswith(str(base) + os.sep):
        return None  # 越界路径拒绝
    return p
```

同时给 `main` 的 batchId 加字符白名单（`[A-Za-z0-9_\-]`），防止拼接出越界目录。

## 三、HTTP 接口设计（server.py，贴合现有路由风格）

```
GET  /api/ledger/ops?dir=...                 → {ok, ops:[...], legacyCount}
GET  /api/ledger/records?dir=...&op=op_xxx   → {ok, opId, records:[...]}
GET  /api/ledger/audit?dir=...&limit=50      → {ok, events:[...], backups:[...]}
POST /api/rollback                           → {dir, opId, dryRun, confirm, reason}
```

实现要点：

- dir 参数沿用现有 `_resolve_dir` 语义（限制在允许根内，无允许根一律拒绝）；
- `GET /api/ledger/ops` 直接透传 `list_ops()`（只读 `ExportsLedger(read_only=True)`）；
- `GET /api/ledger/records` 读 `ExportsLedger.records` 按 opId 过滤（只读）；
- `GET /api/ledger/audit` 读 `exports_events.jsonl` 尾部 N 行（action=rollback 优先展示）+ `backups/` 目录列表；
- `POST /api/rollback`：
  - body 缺 `confirm: true` → 400（前端 dry-run 传 `dryRun: true`，执行传 `confirm: true`）；
  - **与导出/质检共用 `_JOBS` 互斥**：回滚同时改账本和 release，必须与进行中的导出/质检互斥（409 拒绝，文案"导出/质检任务进行中，请稍后再回滚"）；回滚执行期间也注册占位任务，防止并发第二个回滚或新导出；
  - 同步执行（回滚是快操作，不做后台 worker / 轮询），返回透传 `undo_op` 结果 dict（ok/msg/warn/detail/removedRecords/modules/snapshotLedger/snapshotIndex）；
  - reason 写入审计；opId 非空校验。

## 四、前端实现（独立页面，零侵入 index.html）

### 4.1 文件结构

```
static/rollback.html          页面骨架（引用 vendor/vue.global.prod.js，与主页面同款）
static/js/rollback-app.js     独立 Vue 3 应用（不引入 2500 行的 app.js）
static/css/rollback.css       轻量独立样式（沿用 studio.css 的 CSS 变量与视觉语言）
```

`server.py` 静态兜底路由（`STATIC_DIR / path`）已可直接放行 `/rollback.html`，后端无需改静态路由。主页面是否加入口链接由用户另行决定，本次不改 index.html。

### 4.2 页面结构

```
┌ 顶栏：目录输入(?dir= 参数 + localStorage 记忆) + 加载 + 汇总(N 次导出 / M 条记录) ┐
│ Tab1 操作列表                          │ Tab2 回滚审计                        │
│ 时间倒序表格：时间│opId│模块徽章│记录数│order区间│[详情][回滚]                    │
│ legacy 提示条：N 组旧记录无 opId，仅展示不可撤销                                │
└──────────────────────────────────────────────────────────────────────────┘
详情 → 右侧抽屉：文件级明细表（可搜索过滤）
回滚 → 三步弹窗：① dry-run 预览 ② 勾选"知晓将删除 release 文件" + 填原因 ③ 执行
结果 → 面板：成功摘要 / 黄条 warn / 失败；成功后自动刷新列表
```

### 4.3 实现细节与坑

- `list_ops` 返回**升序**，前端展示需 reverse；
- 所有记录字段一律文本插值，禁止 `v-html`（保持现有 XSS 防护水位）；
- 时间戳为 UTC ISO 串，前端转本地时间显示；
- 执行回滚为同步请求：按钮 loading + 禁用 + fetch 异常兜底提示；
- `?dir=` 优先于 localStorage，手动改目录后写回 localStorage；
- 快照文件名在结果面板中展示，方便出问题时人工找回。

## 五、实施顺序与验证

| 步骤 | 内容 | 验证 |
|---|---|---|
| 1 | 方案文档（本文档） | — |
| 2 | 修 P0-3 原子性 + 路径规范化 | 现有 test_rollback.py 回归 + 新增失败注入用例 |
| 3 | server.py 加 4 个 API（含互斥） | 临时脚本：ops/records/audit 拉取、dry-run、带 confirm 执行、无 confirm 400、与导出互斥 409 |
| 4 | 前端独立页面 | 手工冒烟：列表/详情/预览/确认/结果/审计 |
| 5 | 全量测试回归 + CHANGES 记录 | pytest 全绿 |
