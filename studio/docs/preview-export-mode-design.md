# Studio 预览导出模式 (Preview / Dry-Run Export) 设计文档

> **文档版本**：v1.0.0（草案）
> **更新日期**：2026-09-06
> **状态**：待评审，仅方案，未改代码
> **适用模块**：Main / Daily / Events / Collections
> **配套架构**：`unified-content-export-and-storage-architecture.md`（v2.3.0）

---

## 1. 背景与问题

当前 `/api/export`（`studio/server.py:_handle_export`）把以下动作**绑定同一次 `execute()`**：

1. 图片真实转码（WebP）
2. 写入 `.studio/release/{module}/`（权威不可变镜像）
3. 计算并 **占用** order / 版本 / 逻辑 ID
4. 更新 `index.json` / `manifest.json`
5. 写入权威账本 `.studio/ledger/exports.json` + 审计流水
6. 原子拷贝至用户指定 `outDir`（→ 可被 `rclone sync ./out` 直接部署）

**痛点**：运营有时只是想**临时核对导出图片**（清晰度、裁剪、命名、顺序），并不想立刻占用 ID、更新账本、推进版本、写 manifest、部署 outDir。现有流程一"点导出"就把一切副作用都落地，核对不满意也无法干净回退（ID 已占用、账本已追加）。

**目标**：提供一条「**只转图、零副作用**」的**预览（dry-run）导出**旁路，让运营先核图，确认无误后再执行同一参数的正式导出，且两者幂等、不冲突、不跳号。

---

## 2. 核心决策

| 决策点 | 结论 |
| :--- | :--- |
| 预览输出位置 | **用户指定的 `outDir` 下的预览隔离子目录 `{outDir}/_preview/{module}/`（目录名显式含 `preview`，与正式 `outDir/{module}/` 物理隔离，用户直观可检；即使 `outDir` 指向真实部署目录也能显著区分，见 §4）** |
| 预览查重策略 | **跨模块/历史占用降级为仅告警**；同批次完全重复图仍硬拦截（那是"同批少天数/重复关"硬伤，与是否提交无关） |
| **默认模式** | **默认就是 `preview=true`** |
| UI 显著提示 | 导出动作必须有**醒目的模式标识**，避免误把预览当正式导出 |
| 影响范围 | 不改原架构文档；代码层面为「旁路 + guard」，正式导出路径逻辑保持不变 |

---

## 3. 请求契约

`/api/export` 的 `data` 增加可选字段（默认 `preview=true`）：

```json
{
  "type": "main",
  "srcDir": "D:/lib",
  "outDir": "D:/deploy/puzzle",
  "httpBase": "",
  "catalog": "lowres/comics",
  "selectedPaths": [...],
  "preview": true,          // 新增：true=预览(dry-run) / false=正式导出
  "confirmCommit": false    // 新增：提交类操作的前端二次确认回传字段（防误触），详见 §6
}
```

- **后端语义**：`preview` 缺失或为 null 时，**一律按 `true` 处理**（默认预览）；只有前端显式传 `"preview": false`（且通常伴随 `confirmCommit` 确认）才执行正式导出。
- [server.py `_handle_export`](studio/server.py) 透传该字段至 exporter，无需改返回结构。`result.files` 在预览模式下返回"将要生成"的预览图片路径 + 将分配的 ID/hash。

---

## 4. 目标目录解析（公共层）

在 [base.py](studio/exporters/base.py) `BaseExporter` 增加：

```python
self.preview = bool(data.get("preview", True))   # 默认预览

# 预览根：直接落在用户指定的 outDir 下的隔离子目录，目录名显式含 preview
# 例：D:/deploy/puzzle/_preview/main/  |  D:/deploy/puzzle/_preview/daily/zips/
# 即使 outDir 指向真实部署目录，_preview 前缀也能显著区分、避免与正式 release 混淆/误部署
self.out_root = (
    self.out_p / "_preview" / self.module
    if self.preview
    else self.out_p / self.module
)
# 可选：按时间戳隔离多版预览 -> self.out_p / f"_preview_{ts}" / self.module
```

各导出器的"写入目标"统一从 `release_dir` / `out_p` 改为 `self.out_root`。正式导出时的 `out_root = out_p/{module}` 与原行为等效，**不改变现有部署路径**；预览时则为 `out_p/_preview/{module}/`，让运营在自己选定的导出目录内立即可见、可检。

> 结构镜像：preview 下仍生成与正式一致的子目录（`main/images|batches`、`daily/zips`、`events|collections/packs|covers`），让运营预览的正是"将要得到"的目录形态，仅外层多一层 `_preview` 隔离；该目录天然不被正式 `rclone sync ./out --exclude _preview/**` 部署（建议部署命令显式排除 `_preview`，见 §8）。

---

## 5. 各导出器旁路改动（零副作用分支）

在 `execute()` 抽一个提交守卫，用 `if 提交:` 包住一切有副作用的写入：

```python
def _commit(self) -> bool:
    """preview 模式下返回 False，跳过所有有副作用写入"""
    return not self.preview
```

| 副作用段落 | Preview 行为 |
| :--- | :--- |
| 图片转码（真实 WebP） | ✅ 永远执行（这是预览的意义） |
| 写 index.json / manifest.json / version | ❌ 跳过 |
| 写 legacy 兼容文件（main.json / {module}.json 等） | ❌ 跳过 |
| 拷贝 outDir | ❌ 跳过 |
| 账本 append + 审计流水 | ❌ 跳过 |
| 占用 order / 版本 / ID | ❌ 只读推演，不写入 |

### 5.1 MainExporter
- 转图写入预览根；**不**写 `index.json`、`manifest.json`、legacy `main.json`、不拷 outDir、不 append 账本/审计；
- order 仍经 `ledger.get_max_order("main")` **只读**推演"将分配的下一个 order"，仅用于命名（`%04d.webp`）与返回预览 ID `main:{order}`，**不占用**；
- 跳过 `record_exports` / `ledger.append_records` / `ws.log_export`。

### 5.2 DailyExporter
- ZIP 写入预览根 `zips/`；跳 index/manifest/账本/审计/legacy；月份不占用。

### 5.3 EventExporter / CollectionExporter（pack_exporter_base）
- zip + cover 写入预览根 `{packs,covers}/`；跳过 index/manifest/账本/legacy/outDir。

---

## 6. 预览查重 = 仅告警

在 main / pack_base / daily 的 `check_history_duplicate` 调用处统一：

```python
conflict, msg, sev = ledger.check_history_duplicate(h, module=...)
if conflict:
    if self.preview:
        self.log(f"[预览] 仅告警：{msg}（正式导出将硬拦截）", "warn")  # 不阻断
    elif sev == "error":
        raise ValueError(f"导出已被拦截: {msg}")
    elif sev == "warning":
        self.log(f"注意: {msg}", "warn")
```

保留的硬拦截：**同批次内部**出现内容完全相同的两张图（`dup_groups`）仍直接报错——这与是否提交无关，属于素材本身的问题，预览也应在第一时间暴露。

---

## 7. 默认预览 + UI 显著提示

### 7.1 默认预览
导出请求后端默认 `preview=true`。前端"导出"按钮的默认动作即**预览**；只有用户明确选择/确认"正式导出"才发出 `preview=false` + `confirmCommit=true`。

### 7.2 UI 显著提示（强要求）
为避免"以为点了正式导出、其实只是预览"或反之，UI 必须对当前模式做**醒目区分**：

- **常显模式下缀**：导出主按钮/托盘上持续显示当前模式，用颜色+文案区分：
  - 预览态：琥珀色 `[预览]`（不落库、不部署）
  - 提交态：红色 `[正式导出]`（占用 ID、写账本、部署 outDir）
- **预览结果横幅**：预览完成后，返回结果区域置顶一条静态横幅，明确写"**此次为预览，未写入账本/ID/清单，未部署**"，并附将分配的 ID 列表。
- **正式导出二次确认**：触发 `preview=false` 时弹出确认框，逐条列出将发生的副作用（占用顺序/ID、写 index.json、写 manifest、更新账本、拷贝并部署 outDir），用户须勾选"我已核对确认"后才可提交。
- **提交回执**：正式导出成功后前端给出绿色确认条 + 本次版本/批次/batchId，与预览输出做对照。

> 强约束：**任何一次副作用（非预览）导出，都必须来自用户一次明确的"提交"手势**，不允许通过改变默认参数而静默发生。

---

## 8. 预览产物管理

- 预览产物**直接写入用户指定的 `outDir/_preview/{module}/`**（如 `D:/deploy/puzzle/_preview/main/images/0201.webp`），与正式 `outDir/{module}/` 同盘可见、即点即检；
- **显著隔离**：外层目录名固定含 `preview`（`_preview`），即使 `outDir` 指向真实 `release` 部署目录也能一眼区分；部署时建议 `rclone sync ./out remote:puzzles-cdn --exclude "_preview/**"` 显式排除预览目录，或在 Studio 正式部署按钮中自动过滤；
- 进入预览前清空 `outDir/_preview/{module}/`（或按时间戳建 `outDir/_preview_{ts}/{module}/` 以便对照多版预览，推荐带时间戳）；
- 预览产物不进入 `.studio/release/`、不写 `ledger/exports.json`，不会被扫描器/权威账本拾起；仅为供人工核对的临时镜像，正式导出前可随时删除。

---

## 9. 返回值约定

```json
{
  "ok": true,
  "summary": "[预览] 未提交 main 批次 batch_002（10 关）[实际将分配 main:201~main:210]",
  "files": ["D:/deploy/puzzle/_preview/main/images/0201.webp", "..."],
  "preview": true,
  "wouldCommit": {
    "module": "main",
    "batchId": "batch_002",
    "startOrder": 201,
    "endOrder": 210,
    "version": 103,
    "ids": ["main:201", "...", "main:210"]
  }
}
```
> 注：`files` 均位于用户指定的 `outDir/_preview/` 下，目录名显式含 `preview`，即使 `outDir` 为真实部署目录也能显著区分，正式 `rclone sync` 时排除 `_preview/**` 即可。

- `preview: true` 一并返回，供前端据此显示"预览"横幅；
- `wouldCommit` 显式列出正式导出将产生的影响，供确认框与回执使用。

---

## 10. 改动清单（仅列代码文件，不改原架构文档）

| 文件 | 改动 |
| :--- | :--- |
| `studio/exporters/base.py` | 新增 `preview` / `out_root` / `_commit()` |
| `studio/exporters/main_exporter.py` | 转图写 `out_root`；order 只读推演；副作用段 `if _commit()` 包裹 |
| `studio/exporters/daily_exporter.py` | 同上（zip 预览） |
| `studio/exporters/pack_exporter_base.py` | 同上（zip+cover 预览） |
| `studio/exporters/collection_exporter.py` / `event_exporter.py` | 继承基类，无需额外改动 |
| `studio/server.py` | 透传 `preview`；返回 `preview`/`wouldCommit` |
| Studio 前端 | 默认预览、模式显著提示、正式导出二次确认、提交回执 |

**不改动**：`unified-content-export-and-storage-architecture.md` 及其它既有设计文档。

---

## 11. 待确认 / 遗留

- [ ] 预览是否需要"批量确认后一次性正式导出"（多选预览→一次提交）？
- [ ] 临时转码的预览 WebP 是否需要与正式导出 `quality`/参数完全一致（建议一致，保证所见即所得）；
- [ ] `outDir/_preview/` 是否需要纳入 GC 清理策略（建议预览目录随正式导出自动清理或提供“一键清空预览”）。

---

*2026-09-06 更新：预览输出由 `.studio/staging/preview/` 调整为用户指定 `outDir/_preview/`（目录名显式含 preview），满足“在真实导出目录内立即可检且显著区分”的需求。*

*本方案仅设计，未改动任何代码或既有文档。*