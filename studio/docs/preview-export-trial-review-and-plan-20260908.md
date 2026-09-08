# 试导出（Trial Export）自审与定稿方案

> **日期**：2026-09-08
> **性质**：自审 + 定稿，前序方案见 `preview-export-mode-design.md`（v1.0.0，2026-09-06）
> **状态**：方案定稿，未改代码
> **一句话**：试导出 = 同一套 `execute()` 代码路径，只做"隔离写"；`src/.studio/` 零写入，元数据快照随图进试导出目录。

---

## 1. 术语先行：两级产出，避免撞车

当前已存在 `POST /api/export/preview`（`server.py:_handle_export_preview`），它只返回有序清单 `ordered[]` + 统计，**不产图**。本次要的是"产图可检"的试导出，两者并存。**命名上彻底错开：`preview` 专指"清单预检"，`trial` 专指"试导出（产图）"**，禁止混用：

| 名称 | 接口/字段 | 产物 | 成本 |
|---|---|---|---|
| L1 清单预检（已有） | `POST /api/export/preview` | `ordered[]`、统计、建议起始序号/版本，不写盘 | 毫秒级 |
| L2 试导出（本方案） | `POST /api/export` + `trial:true` | 真实转码图 + 隔离的 `index.json`/`manifest.json` 快照 + 元数据包 | 与正式导出相当 |

前端文案必须区分："预检清单" vs "试导出"，不允许都叫"预览"。

---

## 2. 自审结论：前序方案各有什么问题

### 2.1 对 v1.0.0（2026-09-06）的自审

| # | v1.0.0 原决策 | 自审意见 | 定稿 |
|---|---|---|---|
| 1 | 默认 `preview=true`，正式导出需 `preview:false` + `confirmCommit` | 语义对，但实现细节需调整 | 语义保留（安全默认试导出），但**实现改为纯前端防呆**（见 2.2#1），后端不翻转默认 |
| 2 | 预览"跳过写 index.json / manifest.json"（§5） | **太粗，需修正**。用户明确要求"元数据同时导出到导出目录人工核对"。跳过=试导出目录不是忠实镜像，对不上正式产物 | 改为"隔离写"：`index.json`/`manifest.json` 只写进 `_trial/`，打 `"trial":true` 标记，永不进 `release/` 与正式 `outDir` |
| 3 | 预览查重降级为告警，同批内重复仍硬拦截（§6） | **保留，正确**，与现有 `check_history_duplicate` 的 `error/warn` 分级天然契合 | 保留 |
| 4 | 预览根 `{outDir}/_preview/{module}/` + `rclone --exclude "_preview/**"`（§4/§8） | **保留**，比写 `temp/` 更符合"在真实导出目录内立即可检"的需求 | 保留；多版对照需求用 `_trial_{ts}/` 时间戳变体；排除规则统一 `--exclude "_trial*/**"` |
| 5 | 未提及账本自动迁移写 | **遗漏，见 §3.1**，试导出必须只读账本 | 新增 `read_only` 账本 |
| 6 | 未提及与已存在的 `/api/export/preview` 路由重名冲突 | **遗漏**，前端/文档会混淆 | 见 §1 两级命名，试导出改用 `trial` |

### 2.2 对上一轮聊天回复方案的自审

| # | 原说法 | 自审意见 |
|---|---|---|
| 1 | 预览用复选框 opt-in（默认正式导出） | **自我推翻**：与 v1.0.0 的"默认试导出"安全决策冲突，且保持了"一键即污染"的危险默认。改回默认试导出，**并通过纯前端防呆实现**（§2.3） |
| 2 | 构建目录 `tempfile.mkdtemp` 或 `_preview_时间戳` 二选一，含糊 | 收敛：统一 `_trial[/_{ts}]` 落在用户 `outDir` 下（§4）；`tempfile` 只用于 ZIP 预打包的中间临时文件（现有 daily/pack 逻辑已如此） |
| 3 | `_trial_meta/` 自包含元数据包 | **保留，这是相对 v1.0.0 的真实增量**：`ledger_delta.json`（若正式导出会追加的 records）、`source_map.json`（原图映射+质检快照）、`trial.log` |
| 4 | 后端无 `confirmCommit` 硬闸 | 已按"纯前端防呆"收敛：不做后端翻转默认/硬闸，避免破坏现网旧调用（§2.3） |

### 2.3 定稿：纯前端防呆，后端零破坏

**后端不翻转默认、不做 `confirmCommit` 硬闸。** `trial` 缺失/null 一律视为 `False`（即正式导出），与现网旧调用完全兼容：

```python
self.is_trial = bool(data.get("trial", False))   # 缺省=False=正式导出, 向后兼容
def _commit(self) -> bool:
    return not self.is_trial
```

这样：
- **旧脚本/旧前端**（不带 `trial`）继续走正式导出，零破坏；
- **前端**提供安全默认：导出对话框默认态 = 试导出，自动带 `trial:true`；用户切正式导出（`trial:false`）时才弹二次确认框逐条列副作用并勾选。二次确认是**纯前端守卫**，后端不感知 `confirmCommit`。
- 代价：绕过前端直接调 API 的用户拿不到二次确认，属于可接受的前端防呆边界（§6 记录为待评估项）。

---

## 3. 代码级核查：5 处持久化 + 2 个暗坑

以 `main_exporter.py` / `daily_exporter.py` / `pack_exporter_base.py` 实测代码为准：

### 3.1 正式导出的写入清单（试导出必须全部隔离）

1. `src/.studio/release/{module}/`（`images/`、`batches/`、`packs/`、`covers/`、`zips/`、`index.json`）——版本/`batchId`/`maxOrder` 状态源。
2. `src/.studio/ledger/exports.json` 经 `ledger.append_records()` ——`✔已导出`角标、`excludeExported`、`get_max_order()`、查重的唯一依据，**污染重灾区**。
3. `src/.studio/logs/exports.jsonl` 经 `ws.log_export()` ——审计流水。
4. 正式 `outDir/{module}/` + `outDir/manifest.json`（经 `copy_release_to_out()` + `ManifestManager.update_module()`）。
5. `src/.studio/release/manifest.json` 镜像（`update_module(..., ws=ws)` 的附带写入）。

### 3.2 两个暗坑

- **暗坑 A：账本读时写**。`ExportsLedger.load()` 在账本缺失且存在 legacy `exported.json` 时会自动迁移并 `_save_unlocked()` 落盘。试导出若直接 `ExportsLedger(src)`，一次"只读"初始化就可能凭空变出 `exports.json`。定稿要求：新增 `read_only=True` 参数，试导出路径下跳过迁移落盘（内存迁移仅用于本次推演）。**双保险**：`read_only` 下 `append_records()`/`save()` 直接返回，杜绝任何写路径。
- **暗坑 B：工作区骨架 + 迁移含 move**。`StudioWorkspace(src)` 构造即 `ensure_structure()`（建空目录 + `_migrate_legacy_files()`）。其中**不只是拷贝 `tags.json`**，还会对 `.studio.db` 执行 **`shutil.move`（真实移动文件 + WAL/SHM）**，属于重写迁移。空目录创建是幂等的，不算元数据污染，允许保留；但 `_migrate_legacy_files`（含 move）应在试导出下整体跳过。**双保险**：`read_only` 下 `_migrate_legacy_files()` 不执行。

### 3.3 允许保留的写（非污染）

- 控制台 + `temp/studio.log` 的服务端日志：服务级日志，非源库元数据，保留。
- 缩略图磁盘缓存（与 `trial` 无关，由 `/api/thumb` 触发）： benign，保留。
- `quality_cache`（含 `crop_suggestion`）：导出全程只读。当前 `convert_image()` 只做格式转码、**不应用裁切**，所以用户说的"裁切数据"在试导出中体现为 `source_map.json` 内的质检快照字段，而非改图行为；若将来加入应用裁切，该 `cropInfo` 同样只进试导出元数据包。

---

## 4. 定稿：试导出执行语义

### 4.1 请求契约

`POST /api/export` 新增 `trial` 字段，其余与正式导出完全一致（六件套必须同口径：`selectedPaths`、`manualOrder`、`sortBy`、`excludedPaths`、`tagsRecords`、`format/quality/rename`）：

```json
{
  "type": "main",
  "srcDir": "D:/lib",
  "outDir": "D:/deploy/puzzle",
  "trial": true
}
```

- `trial` 缺失/null **一律按 `false` 处理**（正式导出，向后兼容）。
- `trial:true` 且 `outDir` 指向正式部署目录时，后端**自动下沉**到 `{outDir}/_trial_{ts}/`（日志首行明示实际目录），绝不直接写正式 `outDir`。
- 无 `confirmCommit` 概念：二次确认由纯前端承担（§2.3）。

### 4.2 服务端闸门与构建根注入（`BaseExporter` 新增）

```python
self.is_trial = bool(data.get("trial", False))          # 缺省=正式导出
self._trial_ts = None
def _commit(self) -> bool:
    return not self.is_trial
def _resolve_build_root(self) -> Path:
    # 关键：写目标在 execute 顶部一次性重定向，中段零逻辑分叉
    if not self.is_trial:
        self._build_root = self.out_p
        return self.out_p
    self._trial_ts = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    self._build_root = self.out_p / f"_trial_{self._trial_ts}"
    return self._build_root
```

**实测核实到的中段写目录（非尾部）**，必须靠构建根注入而非 `_commit()` 包裹：
- [main_exporter.py](file:///c:/Home/Projects/jigsawpuzzle/studio/exporters/main_exporter.py#L142-L153)：`release_main_dir = ws.release_dir / "main"`、`images_dir`/`batches_dir`；
- [main_exporter.py](file:///c:/Home/Projects/jigsawpuzzle/studio/exporters/main_exporter.py#L249)：plans 的 `dst`；
- [pack_exporter_base.py](file:///c:/Home/Projects/jigsawpuzzle/studio/exporters/pack_exporter_base.py#L160-L164)：`packs_dir`/`covers_dir`；
- [daily_exporter.py](file:///c:/Home/Projects/jigsawpuzzle/studio/exporters/daily_exporter.py#L129-L131)：`zips_dir`。

**定稿做法：在 execute 顶部统一替换"构建根"**，把上述所有中段写目录从 `ws.release_dir/{module}` 改为 `self._build_root/{module}`（正式=outDir，试导出=_trial_{ts}），同时让 `self.out_p` 指向 `_build_root`，使 `copy_release_to_out` → outDir 与 `ManifestManager.update_module(out_p=...)` 天然落入试导出目录。真正用 `if self._commit():` 守卫的只有：账本 `append_records`、`ws.log_export`、release 镜像同步（`update_module(..., ws=None)`）。如此转码/排序/查重/门户代码**逐行不动**，预览与正式无漂移。

| 阶段 | 正式导出 | 试导出 |
|---|---|---|
| 扫描/选图/剔除/`sort_images`/`validate_image`/同批内 `dup_groups` 硬拦截 | 执行 | **同样执行**（所见即所得，素材硬伤第一时间暴露） |
| `check_history_duplicate` 冲突 | `error` 抛错、`warning` 告警 | **一律 warn 告警**，不阻断（正式会拦的提前可见） |
| 图片转码 / ZIP 预打包 | 执行（写 outDir） | **同样执行**，写 `_trial[/_{ts}]` 镜像结构 |
| `order`/`version`/`batchId`/`revision` | 分配并占用（`batch_003`、`main:201`…） | **只读推演**：`version=现有+1`（假设值）、`batch_id=trial_{ts}`（不占序列）、`revision` 为"将会是"的值 |
| `release/{module}/index.json`、`manifest.json`（含 release 镜像，传 `ws=None` 掐断） | 写 | **只写 `_trial/` 内快照**，顶层加 `"trial": true` |
| `copy_release_to_out` 到正式 `outDir` | 执行 | 执行，但 `out_p` 已被重定向到 `_build_root` |
| `ledger.append_records` / `ws.log_export` | 执行 | **`if _commit()` 跳过**（read_only 下 append 本身也拒绝） |
| `_trial_meta/`（§4.3） | 不生成 | 生成 |

### 4.3 试导出目录结构（自包含，可直接人工核对）

```
{outDir}/_trial_20260908_143000/
├── main/images/0201.webp …          # 与正式一致的镜像结构（daily→zips/，event/collection→packs/+covers/）
├── main/batches/trial_20260908_143000.json
├── main/index.json                  # 快照，"trial": true
├── manifest.json                    # 快照，"trial": true
└── _trial_meta/
    ├── source_map.json              # rel → {sourceHash, sourceSize, targetFile, targetHash,
                                     #          order/logicalId(假设值), tags, quality快照(含crop_suggestion),
                                     #          fmt/quality/rename}
    ├── ledger_delta.json            # 本次"若正式导出"会追加的 records（存档，不入库）
    └── trial.log                    # 本次 logs[] 落盘
```

### 4.4 返回契约

```json
{
  "ok": true,
  "trial": true,
  "trialDir": "D:/deploy/puzzle/_trial_20260908_143000",
  "summary": "[试导出] 未提交 main 批次 trial_20260908_143000（10 关）[正式将分配 main:201~210]",
  "files": ["D:/deploy/puzzle/_trial_20260908_143000/main/images/0201.webp"],
  "wouldCommit": {
    "module": "main", "startOrder": 201, "endOrder": 210,
    "version": 103, "ids": ["main:201", "main:210"]
  }
}
```

### 4.5 前端（纯前端防呆）

- 导出对话框默认态 = 试导出（琥珀色 `[试导出]` 徽标，自动带 `trial:true`）；切换到正式导出（红色 `[正式导出]`，`trial:false`）必须弹二次确认框，逐条列出副作用（占用 ID/版本、写 `index.json`/`manifest.json`、写账本、拷贝部署 `outDir`），勾选"我已核对"后才可提交。后端不感知 `confirmCommit`（§2.3）。
- 试导出成功横幅："此次为试导出，未写入账本/ID/清单，未部署"，附 `trialDir` 路径；**试导出后跳过 `scanDirectory()` 刷新**（角标不变即无污染的证明，避免用户误以为失败）。
- 试导出目录提供"打开目录"与"清空试导出"入口；部署命令统一加 `--exclude "_trial*/**"`。

---

## 5. 改动清单与验证

| 文件 | 改动 |
|---|---|
| `studio/exporters/base.py` | `is_trial` / `_commit()` / `_resolve_build_root()`（构建根注入） |
| `studio/exporters/main_exporter.py`、`daily_exporter.py`、`pack_exporter_base.py` | execute 顶部构建根改 `_build_root`；尾部持久化段 `if _commit()` 包裹；`_trial_meta/` 生成 |
| `studio/core/exports_ledger.py` | `read_only` 模式（跳过迁移落盘；`append_records`/`save` 双保险拒绝） |
| `studio/core/workspace.py` | `read_only` 下跳过 `_migrate_legacy_files`（含 `.studio.db` 的 move） |
| `studio/server.py` | `_handle_export` 透传 `trial`；返回 `trial`/`trialDir`/`wouldCommit` |
| `studio/static/js/api.js`、`app.js`、`index.html` | 默认试导出、模式徽标、二次确认、试导出横幅、跳过刷新 |

验证（缺一不可）：试导出前后 `src/.studio/ledger`、`src/.studio/release`、`src/.studio/logs` 三处 `hash` 不变；`/api/scan` 的 `exportedCount` 不变；同参正式导出图片字节（除时间戳/batchId）与试导出 `sha256` 一致，元数据 JSON 结构一致；试导出目录 `_trial_{ts}` 自包含且可达。单测至少覆盖"试导出前后账本文件 `mtime+hash` 不变"。

---

## 6. 实测确认（不污染 `.studio/` 的验收与边界）

本节的目的是**用实测背书"不污染 `.studio/`"**，而不是仅靠代码审查。实现"试导出（trial）"后，按以下清单实测：

1. **污染基线**：试导出前对 `src/.studio/` 整体做 `sha256` 快照（目录树 + 文件内容 + `mtime`）。
2. **触发幂写写路径**：构造三种试导出（main / daily / pack或collection），其中至少一次在**账本缺失且存在 legacy `exported.json`**、**根目录存在旧 `tags.json`/`.studio.db`** 的源库上跑，专门触发暗坑 A/B。
3. **断言**：试导出后 `src/.studio/` 快照与基线一致（允许 `ledger`/`logs`/`release`/`cache` 目录因 `mkdir(parents=True)` 多出的**空目录**，但不得有任何文件新建/改动/删除，`.studio.db` 不得被 move）。
4. **反向断言**：同参正式导出在相同源库上跑一次，确认产物与试导出差异**仅在** batchId、发布时间戳、`trial` 标记上，图片字节一致。
5. **遗留/待评估**：绕过前端直接调 API 无二次确认的边界（纯前端防呆的固有缺口）；多版试导出 GC 策略（建议保留最近 N=3 版 + 一键清空）；`isPatch` 试导出的 `revision` 均为假设值，需在横幅中注明。

**当前状态**：方案已定稿、未改代码，本节实测清单待实现后执行成为通过依据。