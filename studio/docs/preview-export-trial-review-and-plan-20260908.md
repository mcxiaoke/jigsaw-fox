# 试导出（Preview Trial Export）自审与定稿方案

> **日期**：2026-09-08
> **性质**：自审 + 定稿，前序方案见 `preview-export-mode-design.md`（v1.0.0，2026-09-06）
> **状态**：方案定稿，未改代码
> **一句话**：预览 = 同一套 `execute()` 代码路径，只做"隔离写"；`src/.studio/` 零写入，元数据快照随图进预览目录。

---

## 1. 术语先行：两级预览，避免撞车

当前已存在 `POST /api/export/preview`（`server.py:_handle_export_preview`），它只返回有序清单 `ordered[]` + 统计，**不产图**。本次要的是"产图可检"的试导出，两者并存：

| 名称 | 接口 | 产物 | 成本 |
|---|---|---|---|
| L1 清单预检（已有） | `POST /api/export/preview` | `ordered[]`、统计、建议起始序号/版本，不写盘 | 毫秒级 |
| L2 试导出（本方案） | `POST /api/export` + `preview:true` | 真实转码图 + 隔离的 `index.json`/`manifest.json` 快照 + 元数据包 | 与正式导出相当 |

前端文案必须区分："预检清单" vs "试导出"，不允许都叫"预览"。

---

## 2. 自审结论：前序两个方案各有什么问题

### 2.1 对 v1.0.0（2026-09-06）的自审

| # | v1.0.0 原决策 | 自审意见 | 定稿 |
|---|---|---|---|
| 1 | 默认 `preview=true`，正式导出需 `preview:false` + `confirmCommit` | **保留，正确**。这是安全默认值，防止一键污染账本 | 保留 |
| 2 | 预览"跳过写 index.json / manifest.json"（§5） | **太粗，需修正**。用户明确要求"元数据同时导出到导出目录人工核对"。跳过=预览目录不是忠实镜像，对不上正式产物 | 改为"隔离写"：`index.json`/`manifest.json` 只写进 `_preview/`，打 `"preview":true` 标记，永不进 `release/` 与正式 `outDir` |
| 3 | 预览查重降级为告警，同批内重复仍硬拦截（§6） | **保留，正确**，与现有 `check_history_duplicate` 的 `error/warn` 分级天然契合 | 保留 |
| 4 | 预览根 `{outDir}/_preview/{module}/` + `rclone --exclude "_preview/**"`（§4/§8） | **保留**，比写 `temp/` 更符合"在真实导出目录内立即可检"的需求 | 保留；多版对照需求用 `_preview_{ts}/` 时间戳变体 |
| 5 | 未提及账本自动迁移写 | **遗漏，见 §3.1**，预览必须只读账本 | 新增 `read_only` 账本 |
| 6 | 未提及与已存在的 `/api/export/preview` 路由重名冲突 | **遗漏**，前端/文档会混淆 | 见 §1 两级命名 |

### 2.2 对上一轮聊天回复方案的自审

| # | 原说法 | 自审意见 |
|---|---|---|
| 1 | 预览用复选框 opt-in（默认正式导出） | **自我推翻**：与 v1.0.0 的"默认预览"安全决策冲突，且保持了"一键即污染"的危险默认。改回默认预览 |
| 2 | 构建目录 `tempfile.mkdtemp` 或 `_preview_时间戳` 二选一，含糊 | 收敛：统一 `_preview[/_{ts}]` 落在用户 `outDir` 下（§4）；`tempfile` 只用于 ZIP 预打包的中间临时文件（现有 daily/pack 逻辑已如此） |
| 3 | `_preview_meta/` 自包含元数据包 | **保留，这是相对 v1.0.0 的真实增量**：`ledger_delta.json`（若正式导出会追加的 records）、`source_map.json`（原图映射+质检快照）、`preview.log` |
| 4 | 未覆盖 `confirmCommit` 二次确认 | 补上：任何 `preview:false` 必须来自显式提交手势（§6） |

---

## 3. 代码级核查：5 处持久化 + 2 个暗坑

以 `main_exporter.py` / `daily_exporter.py` / `pack_exporter_base.py` 实测代码为准：

### 3.1 正式导出的写入清单（试导出必须全部闸住）

1. `src/.studio/release/{module}/`（`images/`、`batches/`、`packs/`、`covers/`、`zips/`、`index.json`）——版本/`batchId`/`maxOrder` 状态源。
2. `src/.studio/ledger/exports.json` 经 `ledger.append_records()` ——`✔已导出`角标、`excludeExported`、`get_max_order()`、查重的唯一依据，**污染重灾区**。
3. `src/.studio/logs/exports.jsonl` 经 `ws.log_export()` ——审计流水。
4. 正式 `outDir/{module}/` + `outDir/manifest.json`（经 `copy_release_to_out()` + `ManifestManager.update_module()`）。
5. `src/.studio/release/manifest.json` 镜像（`update_module(..., ws=ws)` 的附带写入）。

### 3.2 两个暗坑（v1.0.0 未覆盖）

- **暗坑 A：账本读时写**。`ExportsLedger.load()` 在账本缺失且存在 legacy `exported.json` 时会自动迁移并 `_save_unlocked()` 落盘。预览若直接 `ExportsLedger(src)`，一次"只读"初始化就可能凭空变出 `exports.json`。定稿要求：新增 `read_only=True` 参数，预览路径下跳过迁移落盘（内存迁移仅用于本次推演）。
- **暗坑 B：工作区骨架**。`StudioWorkspace(src)` 构造即 `ensure_structure()`（建空目录 + 迁移 `tags.json` 副本）。空目录创建是幂等的，不算元数据污染，允许保留；但 `_migrate_legacy_files` 的拷贝行为应在预览下跳过，原因同上。

### 3.3 允许保留的写（非污染）

- 控制台 + `temp/studio.log` 的服务端日志：服务级日志，非源库元数据，保留。
- 缩略图磁盘缓存（`_preview` 无关，由 `/api/thumb` 触发）： benign，保留。
- `quality_cache`（含 `crop_suggestion`）：导出全程只读。当前 `convert_image()` 只做格式转码、**不应用裁切**，所以用户说的"裁切数据"在预览中体现为 `source_map.json` 内的质检快照字段，而非改图行为；若将来加入应用裁切，该 `cropInfo` 同样只进预览元数据包。

---

## 4. 定稿：试导出执行语义

### 4.1 请求契约

`POST /api/export` 新增两个字段，其余与正式导出完全一致（六件套必须同口径：`selectedPaths`、`manualOrder`、`sortBy`、`excludedPaths`、`tagsRecords`、`format/quality/rename`）：

```json
{
  "type": "main",
  "srcDir": "D:/lib",
  "outDir": "D:/deploy/puzzle",
  "preview": true,
  "confirmCommit": false
}
```

- `preview` 缺失/null **一律按 `true` 处理**；仅显式 `preview:false` + `confirmCommit:true` 才走正式导出。
- `preview:true` 且 `outDir` 指向正式部署目录时，后端**自动下沉**到 `{outDir}/_preview_{ts}/`（日志首行明示实际目录），绝不直接写正式 `outDir`。

### 4.2 服务端闸门（`BaseExporter` 新增）

```python
self.is_preview = bool(data.get("preview", True))  # 缺省预览
def _commit(self) -> bool:
    return not self.is_preview
```

| 阶段 | 正式导出 | 试导出 |
|---|---|---|
| 扫描/选图/剔除/`sort_images`/`validate_image`/同批内 `dup_groups` 硬拦截 | 执行 | **同样执行**（所见即所得，素材硬伤第一时间暴露） |
| `check_history_duplicate` 冲突 | `error` 抛错、`warning` 告警 | **一律 warn 告警**，不阻断（正式会拦的提前可见） |
| 图片转码 / ZIP 预打包 | 执行 | **同样执行**，目标改为 `_preview[/_{ts}]` 镜像结构 |
| `order`/`version`/`batchId`/`revision` | 分配并占用（`batch_003`、`main:201`…） | **只读推演**：`version=现有+1`（假设值）、`batch_id=preview_{ts}`（不占序列）、`revision` 为"将会是"的值 |
| `release/{module}/index.json`、`manifest.json`（含 release 镜像，传 `ws=None` 掐断） | 写 | **只写 `_preview/` 内快照**，顶层加 `"preview": true` |
| `copy_release_to_out` 到正式 `outDir` | 执行 | 跳过 |
| `ledger.append_records` / `ws.log_export` | 执行 | **跳过** |
| `_preview_meta/`（§4.3） | 不生成 | 生成 |

关键约束：**不另写一套预览逻辑**，只在各 `execute()` 尾部的持久化段用 `if self._commit():` 包裹；转码前的全部校验与排序代码零分叉，避免预览与正式漂移。

### 4.3 预览目录结构（自包含，可直接人工核对）

```
{outDir}/_preview_20260908_143000/
├── main/images/0201.webp …          # 与正式一致的镜像结构（daily→zips/，event/collection→packs/+covers/）
├── main/batches/preview_20260908_143000.json
├── main/index.json                  # 快照，"preview": true
├── manifest.json                    # 快照，"preview": true
└── _preview_meta/
    ├── source_map.json              # rel → {sourceHash, sourceSize, targetFile, targetHash,
                                     #          order/logicalId(假设值), tags, quality快照(含crop_suggestion),
                                     #          fmt/quality/rename}
    ├── ledger_delta.json            # 本次"若正式导出"会追加的 records（存档，不入库）
    └── preview.log                  # 本次 logs[] 落盘
```

### 4.4 返回契约

```json
{
  "ok": true,
  "preview": true,
  "previewDir": "D:/deploy/puzzle/_preview_20260908_143000",
  "summary": "[试导出] 未提交 main 批次 preview_20260908_143000（10 关）[正式将分配 main:201~210]",
  "files": ["D:/deploy/puzzle/_preview_20260908_143000/main/images/0201.webp"],
  "wouldCommit": {
    "module": "main", "startOrder": 201, "endOrder": 210,
    "version": 103, "ids": ["main:201", "main:210"]
  }
}
```

### 4.5 前端

- 导出对话框默认态 = 试导出（琥珀色 `[试导出]` 徽标）；切换到正式导出（红色 `[正式导出]`）必须弹二次确认框，逐条列出副作用（占用 ID/版本、写 `index.json`/`manifest.json`、写账本、拷贝部署 `outDir`），勾选"我已核对"后才可提交（`preview:false` + `confirmCommit:true`）。
- 试导出成功横幅："此次为试导出，未写入账本/ID/清单，未部署"，附 `previewDir` 路径；**试导出后跳过 `scanDirectory()` 刷新**（角标不变即无污染的证明，避免用户误以为失败）。
- 预览目录提供"打开目录"与"清空预览"入口；部署命令统一加 `--exclude "_preview*/**"`。

---

## 5. 改动清单与验证

| 文件 | 改动 |
|---|---|
| `studio/exporters/base.py` | `is_preview` / `_commit()` / 预览根解析 |
| `studio/exporters/main_exporter.py`、`daily_exporter.py`、`pack_exporter_base.py` | 构建目标改预览根；持久化段 `if _commit()` 包裹；`_preview_meta/` 生成 |
| `studio/core/exports_ledger.py` | `read_only` 模式（跳过迁移落盘） |
| `studio/core/workspace.py` | 预览下跳过 `_migrate_legacy_files` 拷贝 |
| `studio/server.py` | `_handle_export` 透传 `preview`/`confirmCommit`，无 `confirmCommit` 的 `preview:false` 直接拒绝；返回 `preview`/`previewDir`/`wouldCommit` |
| `studio/static/js/api.js`、`app.js`、`index.html` | 默认试导出、模式徽标、二次确认、试导出横幅、跳过刷新 |

验证（缺一不可）：试导出前后 `src/.studio/ledger`、`src/.studio/release`、`src/.studio/logs` 三处 `hash` 不变；`/api/scan` 的 `exportedCount` 不变；同参正式导出产物（除 `batchId`/时间戳字段）与试导出 `sha256` 一致；`preview:false` 无 `confirmCommit` 时被拒绝。单测至少覆盖"预览前后账本文件 `mtime+hash` 不变"与"无确认的正式导出被拒"。

遗留：多版预览 GC 策略（建议保留最近 N 版 + 一键清空）；`isPatch` 试导出的 `revision` 均为假设值，需在横幅中注明。
