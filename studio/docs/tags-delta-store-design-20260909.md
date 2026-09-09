# tags.json 手动增量(Delta)存储 设计文档

> 日期：2026-09-09（GMT+8）
> 状态：**已落地（已完成实现，46 项单测通过）**；本文件从"设计方案"改为"落地记录"，§8/§9/§11 已按实际实现更新。
> 关联文件：`studio/core/tags_manager.py`、`studio/core/scanner.py`、`studio/exporters/main_exporter.py`、`studio/server.py`、`studio/static/js/app.js`、`studio/static/index.html`、`studio/static/css/studio.css`

## 0. 实施状态同步（2026-09-09 定稿 → 已实现）

| 项 | 状态 | 说明 |
|---|---|---|
| delta 落盘 + `type:"manual"` | ✅ 已实现 | `save_tags_file` 只落手动记录，写 `type:"manual"`；空/`["Others"]` 视为显式清空，下游禁止自动覆盖 |
| 身份模型 hash 优先、path 兜底 | ✅ 已实现 | `key = hash or ("path:"+rel)`；「一旦手动永不自动归零」 |
| 手动权威全链路 | ✅ 已实现 | merge §4.5 不覆盖手动成员、donor 手动优先、`is_manual` 传播；exporter 不 re-derive 手动 |
| 自动保存 | ✅ 已实现 | 前端 `applyTags` 置 `is_manual` 并 `scheduleAutoSave()`(600ms 防抖静默落盘)；手动按钮兜底 |
| 缩略图区分自动/手动 | ✅ 已实现 | 手动卡片渲染 `✍️ 手` 徽标 + 左侧橙线 |
| 手动保存按钮 | ✅ 保留 | 「保存 tags.json」作为强制/立即保存兜底 |
| 「一键精简 tags.json」迁移 | ⏸ 延后 | 未正式使用、无现网全量文件，首批保存即产出 delta |
| 「移除手动标记」UI 动作 | ⏸ 可选后续 | 现在通过重打自动标签 + 保存来覆盖 |
| 旧全量格式只读兼容 | ✅ 保留 | `normalize_records` 仍可读旧 `tags` 字段格式 |

> 变更明细见 `studio/docs/CHANGES-20260909.md`。

## 1. 背景与目标

当前 `tags.json` 为**全量**存储：`save_tags_file` 把每条记录（含目录名自动推导的标签、catalogs、confidence、size/mtime/format 等冗余）全部落盘。

由于目录名已能确定性推导标签（`guess_tags_from_path`），且读取端已有「无 tags 就从路径重推」的兜底，自动标签**完全不必持久化**。

**目标**：`tags.json` 改为只保存「用户手动打标 / 人工复核」的**增量(delta)** 记录；目录名自动标签和一切可由扫描重算的元数据一律不落盘。文件显著变小、diff 清晰、一眼可见人工确认项。

**关键决策（用户确认）**：
- delta 粒度：**按条记录整体为准**（不问增删，存最终 manual_tags）。
- 自动记录元数据：**全部砍掉，读取时从扫描重算**。
- 身份模型：**manual tag 与 hash(SHA-256) 关联，path 仅作辅助记录与兜底键**（见 §4）。

---

## 2. 核心概念

### 2.1 双轨标签
- **自动基准 `base(path)`** = `guess_tags_from_path(path, root)`。由目录名确定性推导，永不落盘，读取时实时重算。
- **手动增量 `delta`** = 用户人工改过头的结果，是 `tags.json` 中**唯一**被持久化的内容对象。

### 2.2 全量视图（内存合成）
始终存在、供统计/筛选/导出/质检使用：
```
effective(rec) = delta.manual_tags    若该记录命中 delta
               = base(path)            否则
```

---

## 3. 落盘格式（新 tags.json schema）

```jsonc
{
  "$schema": "jigsaw-tags-delta-v1",
  "key": "hash",                        // 身份策略: hash 优先, path 兜底(见 §4)
  "records": [
    {
      "type": "manual",                // 手动权威: 出现即代表人工指定, 自动推断全局禁用
      "hash": "sha256hex...",          // 身份主键; 空则省略并以 path-keyed 记录进入
      "path": "Animals/cats/001.jpg",  // 辅助记录(用于导出账本/追溯/兜底键)
      "manual_tags": ["Pets", "cute"], // 手动最终标签; 显式清空/未分类统一收口为 ["Others"]
      "subject": "",                   // 仅非空才存
      "scene": "",
      "reason": "",                    // 仅真实人工备注存; 引擎自动生成(智能推断/未打标/继承/对齐)一律过滤
      "confidence": 0.9,               // 仅手动调整过才存
      "updated_at": "2026-09-09T10:00:00" // 便于审计
    }
  ]
}
```

> **type="manual"（2026-09-09 定稿）**：`manual_tags` 无论真实标签还是 `["Others"]`（=显式清空/未分类；空数组与 Others 等价为 app 不变量，故统一收口 `["Others"]`），一旦 `type` 出现即视为人工权威，所有下游（merge 对齐、exporter、统计）一律**禁止**用目录名自动推断覆盖。前端唯一改标签入口 `applyTags` 置 `is_manual=true`，`save_tags_file` 据此 + `differs/has_text` 安全网落盘，并写 `type:"manual"`。

不再落盘的字段：`review_required`（纯派生：未打标 Others / 低置信即"待复核"，由 tags 推导，不持久化）、`catalogs/width/height/format/size/mtime/aspect_ratio/orientation/long_side/too_small_long`——全部来自扫描（`cache_db`/`scan_image_infos`），读取时重算。前端已移除手动「已复核/待复核」开关。

### 3.1 取消手动（可选，见 §7）
用户把某张图恢复为「与目录推导一致」时，提供「移除手动标记」动作，删除对应 delta；该图回到自动推导。

---

## 4. 身份模型：为什么以 hash 为主键

### 4.1 hash 身份（推荐，默认）
- manual tag 绑定**内容**而非位置：文件改名 / 移动 / 跨目录复制，hash 不变 → 人工标签自动跟随。
- 与既有 dedup 语义一致：`merge_scanned_images` §4.5 已强制「同 hash 的所有副本标签一致」，故同 hash 共享一份 manual_tags 不冲突。
- 数据量更小：同一内容多副本只存一份 delta。

### 4.2 兜底与边界
- **hash 为空**（读取失败/0 字节）：退回 `path` 作键。规则：`key = hash or ("path:" + rel)`。
- **同 hash 冲突**（理论上被对齐逻辑禁止，防御处理）：以 `updated_at` 较新者为准，`logger.warning` 告警；若未来需支持同内容不同标注，则论文档 §7 退化为 path-keyed。

### 4.3 修改后失效
文件内容变更 → hash 变化 → 旧 delta 成孤儿（点不到）；新 hash 按「全新记录」重新判定。行为可接受，文档标注即可。

---

## 5. 判定规则（should_persist）

对每条记录（**已实现**，`save_tags_file`）：

```
base = guess_tags_from_path(rel, root)
existing_delta = 按 §4 键查已存在 delta

persist if (
    is_manual                  # 前端显式动作(applyTags 置位) → 无条件落盘(权威)
    or existing_delta is not None   # 一旦手动、永不自动归零 → 更新
    or set(effective_tags) != set(base)   # 标签被改过/增删(非前端生产者安全网)
    or subject or scene        # 有人工备注(安全网; reason 是引擎生成, 不看)
)
```
> 空数组与 `["Others"]` 等价（app 不变量），统一收口 `["Others"]`；一旦落盘即 `type:"manual"`。
> `reason` 不参与判定：merge 会为每条自动记录写 `智能推断/未打标/继承/对齐`，不能作为手动依据，且落盘时这些引擎 reason 一律过滤。

> 注：以 hash 为身份时，一旦成为 delta，即使后来移动到标签更匹配的目录也不会被「自动归零」——因为它是人工选择。这与 path-keyed 相反（path-keyed 会随路径基准漂移）。

---

## 6. 读取 / 合成（改动最小化）

### 6.1 `normalize_records` / 新增 `resolve_effective`
- 先按 §4 把 `records` 建成 `delta_by_key` 索引。
- 每条 path 记录：`effective = next((d.manual_tags for d in delta_lookup(rec)), guess_tags_from_path(path))`。
- `catalogs = get_catalogs_for_tags(effective)`。
- `review_required = d.review_required if delta else (effective == [OTHERS_TAG])`。
- 其余元数据由扫描回填（现状已如此）。

### 6.2 `save_tags_file` 改造（已实现）
- 入参仍是全量 records（前端无感），**在函数内部裁剪**，只写 delta（含 `type:"manual"`）。
- 返回 `(ok, filepath, saved, auto_skipped)`；`server._handle_post_tags` 回给前端 `{saved, autoSkipped}`，toast 显示「手动 N 条（自动识别 X 条未落盘）」。

### 6.3 `model` 字段去向（已实现）
`rule/inherited` 仅存在于内存运行态，不再落盘。落盘以 `type:"manual"` 代表"是否人工"。读取端 `normalize_records` 对 delta 记录置 `is_manual=True`，列表格式也透传 `is_manual`（供 exporter 的 `tagsRecords` 路径不丢标识）。

---

## 7. 兼容性

### 7.1 迁移（本期不做，延后）
项目尚未正式使用、暂无手动 tags，首批保存自然产出近空 delta 文件，无需现网迁移。延后的「一键精简」流程（读现存全量 → 筛 delta → 覆盖写新 schema → 备份 `.studio/backups/tags-*.bak`）待已有全量文件后按需启用。

### 7.2 读取兼容旧全量格式（保留只读）
`normalize_records` 保留对旧全量格式（每条自带 tags）的只读兼容：将其视为「已解析结果」直接产出全量视图。后续每次 save 后自动转为 delta。

### 7.3 中途回退
若 hash-keyed 遇到不可接受场景，保留 `path-keyed` 分支（§4.2），schema 的 `key` 字段记录当前策略，便于迁移。

---

## 8. 实现落点（全部已落地）

| 文件 | 改动 |
|---|---|
| `studio/core/tags_manager.py` | ✅ `save_tags_file` 裁剪为 delta + `type:"manual"` + 返回 `(ok,filepath,saved,auto_skipped)`；`is_manual` 权威判定；`_records_from_delta`/`_is_delta_format`；`normalize_records` 透传 `is_manual`；merge §4.5 手动守卫 + donor 手动优先；`_is_auto_reason` 过滤引擎 reason |
| `studio/exporters/main_exporter.py` | ✅ 兜底改为 `if not tags and not is_manual` 才路径推断（手动空/Others 永不 re-derive） |
| `studio/server.py` | ✅ `_handle_post_tags` 回 `{saved, autoSkipped}` |
| `studio/static/js/app.js` | ✅ `applyTags` 置 `is_manual` + `scheduleAutoSave()`；`buildSlimRecords` 透传 `is_manual`；toast 显示 saved/autoSkipped |
| `studio/static/index.html` | ✅ 卡片渲染手动徽标 |
| `studio/static/css/studio.css` | ✅ `.tag-manual` / `.card-tags.has-manual` 样式 |
| `studio/test_studio.py` | ✅ delta 判定、手动权威、后端 tag 操作(覆盖/追加/移除/重置/多图多次)、type 落盘等单测 |

## 9. 测试用例（已实现，`python -m unittest studio.test_studio` 46 项通过）

1. delta 判定：纯自动裁剪近空、手动(People)落盘（`test_scan_and_tags_manager`）。
2. 读取合成：delta 重读 → 全量视图正确（同上）。
3. hash 身份 / 移动继承：手动 tag 移动目录后保留（`test_auto_reconciliation_on_rename_or_move`）。
4. 一旦手动永不归零：手动改回与目录一致仍保留（`test_manual_tag_never_auto_reset`）。
5. 手动 Others 不被自动覆盖 + `type` 落盘（`test_manual_cleared_to_others_not_overridden`）。
6. no-op 手动清空（is_manual 标记）也落盘（`test_manual_flag_persists_noop_clear`）。
7. 覆盖/追加/移除/重置 + 多图多次操作（`test_backend_manual_tag_operations`）。
8. save 返回 `{saved, autoSkipped}` 数值正确（覆盖于上述各用例）。

---

## 10. 影响与风险

- ✅ 文件体积、diff 清晰度、可读性显著提升。
- ⚠️ **关于「读取时逐条 guess」的真实成本（用户澄清）**：
  - 主链路 `_handle_scan` 本就在 `merge_scanned_images` 对**新图片全量 guess**（已有实现，不是新增），因此该路径**无需额外逐条 guess**。
  - delta 化的实际改变是：自动图不再「猜一次存起来」，而是**每次扫描重新猜**（代价极轻：字符串/正则；附赠目录改名即自动跟随）。
  - 纯读链路（`_handle_get_tags`、exporter 预读）当前能直接拿全量 tags 是因为全量文件每行存了标签；delta 化后若要直接出全量视图需 resolver。**规避：merge 保持唯一 guesser，`normalize_records` 只解析 delta，其它需全量的路由也走 resolver/扫描**，不引入重复 guess。可按 `(hash,path)` 加 LRU 缓存兜底。
- ⚠️ 内容修改后旧 delta 孤儿（§4.3）：接受范围内，文档已标注。
- ⚠️ 同 hash 不同人工意图在当前对齐语义下不受支持（§4.2）；后续如需要，走 path-keyed 分支。
- ⚠️ 改的是持久层核心格式，必须全量跑 `python -m unittest studio.test_studio`，并验证 §9 新用例。

---

## 11. 已决问题（2026-09-09 用户确认）→ 均已落地

1. **「一旦手动、永不自动归零」的 hash 语义 —— 接受。** 不做自动归零；「移除手动标记」仅作为可选的显式清除动作（后续 UI 迭代提供）。
2. **`key` 字段正式暴露 —— 可以。** 写入 schema，标注当前策略（hash 优先 / path 兜底）。
3. **「精简 tags.json」迁移 —— 本期不做，延后。** 保留 `normalize_records` 对旧全量格式只读兼容。
4. **`type` 单词 —— 统一用 `"manual"`。** 出现即人工权威，`manual_tags` 无论真实值还是 `["Others"]` 都禁用自动推断。
5. **空数组 / 清空 —— 统一收口 `["Others"]`。** 空 `[]` ≡ `["Others"]`（app 不变量），人工清空也会持久化为 `type:"manual" + ["Others"]`。
6. **自动保存 —— 采纳。** 用户操作即保存（`applyTags` 触发防抖 `scheduleAutoSave()`），手动按钮兜底，杜绝"忘了点保存"。
7. **缩略图区分自动/手动 —— 采纳。** 卡片 `is_manual` 标注 `✍️ 手` + 左侧橙线。
8. **手动清空为 Others 的图在导出中 —— 按普通 Others 处理**（归类到 Others 桶），仅保证不被 re-derive。