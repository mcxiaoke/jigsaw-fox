# Studio 导出页面（排序 / 预览 / 三步流）问题排查与修复报告

> **文档版本**：v1.1.0
> **创建日期**：2026-09-07
> **排查方式**：源码走读 + Playwright(Edge) 实机驱动 UI + 直连 `/api/export/preview` 契约探针 + 产物落盘核验
> **测试样本**：小样本 40 张（`C:\Home\Temp\studio_dbg_src`）、压力样本 3000 张（`C:\Home\Temp\studio_scale_src`）、真实样本 25,428 张（`C:\Home\Temp\Jigsaw_Organized`）
> **状态**：已定位 → **已修复并回归通过**（见 §4 / §6）

---

## 1. 排查结论总览

导出三步流（基础配置 → 顺序调整 → 导出前预览）**主干链路是通的**：手动拖拽 → 顺序回传后端 → `order` 分配 → 落盘，全链路实测一致（拖 0→5 + 整体反转后，`batch_001.json` 的 101~110 与界面顺序逐项吻合）。

真正的问题集中在四类：
1. **导出收尾态的按钮语义错误**（可重复导出）；
2. **手动排序的成果在产物上不可见**（rename 默认不改名）+ **version 语义错误**；
3. **规模不可用**（预检请求体膨胀 + 全量渲染无虚拟化 + 拖拽大列表卡顿）；
4. **预检/导出的排序口径不一致**（`resolve()` 缺失导致手动排序可能静默失效）。

---

## 2. 问题清单（按严重度）

### A. 功能性 Bug

#### A1【高】导出完成后第④步仍显示「✅ 确认导出」，可重复导出覆盖产物
- **位置**：`studio/static/index.html` 导出导航按钮组（`v-if="exportStep < 2"` / `v-else-if="exportStep === 2"` / `v-else`）。
- **机理**：`runExport()` 成功/失败都会 `exportStep.value = 4`，而 `v-else` 兜底分支对 step 4 同样命中，于是「确认导出」按钮在结果页依旧可点。
- **实测复现**：导出成功后底部按钮 = `['📋 复制日志', '← 上一步', '关闭', '✅ 确认导出']`，此时再点会**再次提交导出任务**。

#### A2【高】Main 首次导出 version 默认 101 而非 1，与 UI 提示直接矛盾
- **位置**：`studio/exporters/main_exporter.py`（`version_input` 为空且无历史版本时 `version = 101`）。
- **实测复现**：UI 占位提示「当前 0，下版本 1」，实际导出后 `main/index.json` 写入 `"version": 101`。
- **连锁**：下一次导出 `existing_version=101 → 102`，版本号从 101 起跳，"留空则自动 +1" 的语义完全失效。

#### A3【高】Main 默认 `rename=none`，手动排序成果在产物文件名上完全不可见
- **位置**：`studio/static/js/app.js` `exportConfig.rename` 默认 `"none"`。
- **实测复现**：拖拽 + 反转后导出 10 张，磁盘产物为 `Abstract_0001_3933857680.webp` 等原名，`order` 只存在于 `main.json` 内部。
- **对照设计文档**：`studio-export-workflow-ui-and-config-design-dsf.md` §4.1 明确要求「main 建议同时将 `rename_rule` 默认改为 `sequence`（`101.webp…`），让"文件名 = order"」。
- **影响**：用户在第二步辛苦拖好的顺序，落到硬盘上**看不出任何顺序**，功能感知断裂。

#### A4【高】预检与导出的排序路径口径不一致 → 手动排序可能**静默失效**
- **位置**：
  - `studio/server.py` `_handle_export_preview`：`root = Path(src)`（**未 resolve**）；
  - `studio/core/scanner.py` `build_manual_order`：`sp = Path(src_p).resolve()`；
  - `studio/core/scanner.py` `sort_images` manual 分支：`rank.get(p.as_posix().lower(), ...)`，其中 `p` 来自**未 resolve 的 root** 拼接。
- **机理**：`manual_order` 的键是 `resolve()` 后的绝对路径，而 `p.as_posix()` 用的是未 resolve 的 root。当 `srcDir` 为相对路径、含 `..`、盘符大小写差异、或经过符号链接/junction 时，键匹配不上 → `rank.get(..., len(paths))` 全部落到同一个兜底值 → **排序退化为扫描字典序，且无任何警告**。
- **对照**：`/api/scan` 用的是 `Path(dir_param).resolve()`，两处口径不一致。

#### A5【中】第二步缺失 ↑ / ↓ / ✕ 按钮，`moveExportItem` / `removeFromPreview` 是死代码
- **位置**：`studio/static/js/app.js` 定义了 `moveExportItem(i, dir)`、`removeFromPreview(i)`，但 `index.html` 第二步的 `.og-card` 内**没有任何调用点**。
- **对照设计文档**：§3.2 要求行单元 = `拖拽柄 + 顺位编号 + 缩略图 + 文件名 + 标签 + ↑ ↓ ✕`。
- **影响**：拖拽成为唯一排序手段（与 B3 叠加后大列表等于不可排序），且 `✕` 剔除单张的能力完全缺失；也无键盘可达性。

#### A6【中】预览体积估算与 quality 完全无关，且第一步残留死控件
- **位置**：
  - `studio/server.py`：`"estWebpBytes": int(source_bytes * 0.2)`，**未使用 `quality`**；
  - `studio/static/index.html` 第一步「WebP 压缩率（预览按此粗估体积）」字段组内**只有一段说明文字，没有任何 input**（真正的滑杆在上一格，标题是「WebP / JPEG 质量」）。
- **影响**：把质量从 70 调到 20，第三步「WebP 预计」纹丝不动；同时页面上出现两个"质量"相关区块，其中一个是空的，误导操作者。
- **对照设计文档**：§7「诚实标注：体积为预计」；§4.3 quality 需透传生效。

#### A7【低】第一步与第二步各有一个排序下拉，行为不一致
- 第一步「导出顺序排序」改动**不触发**重新预检；第二步「顺序来源」`@change="goExportStep(2)"` 会触发。
- 两个下拉的选项集也不一致（第一步缺 `mtime_dsc`、`size_dsc` 顺序与第二步不齐）。

#### A9【高·修复中发现】第二步 ✕ 剔除只改了前端清单，导出仍会把该图片打进去
- **位置**：`moveExportItem` / `removeFromPreview` 原本就是死代码，但更关键的是——即便激活它们，后端 `sort_images` 的 manual 分支对 `manualOrder` 里缺失的项会给兜底 rank（`rank.get(..., len(paths))`），**被剔除的图片会被排到清单末尾照样导出**。
- **影响**：预览显示 8 张、实际导出 10 张，且被"剔除"的图片拿到最大序号，编号还会发生**空洞+错位**。
- **修复**：前后端新增 `excludedPaths` 契约——前端维护 `exportExcluded` 集合并随预检/导出提交；`base.py` 新增 `resolve_excluded()`，三个导出器与 `/api/export/preview` 统一按小写 posix 相对路径真正过滤。切换导出范围时自动作废剔除记录。
- **实测**：✕ 掉 2 张 → 预检 total 10→8、第三步 8、落盘 `101.webp…108.webp` 共 8 张**连续无空洞**，日志出现「已剔除 2 张在第②步手动移除的图片」。

---

### B. 性能 / 规模问题（实测数据）

#### B1【高】预检请求体过大，且每次切步/改排序都全量重发
- **实测**：3000 张时 `POST /api/export/preview` 请求体 = **2,166,289 字节（≈2.1 MB）**；按线性外推，用户真实目录 **25,428 张 ≈ 18 MB/次**。
- **根因**：
  1. payload 里携带全量 `tagsRecords: records.value`（仅为让后端拿到 tags，而后端在 records 为空时本就会自己读 `tags.json`）；
  2. `api.js` 的 `jsonStringifySafe` 使用 `JSON.stringify(obj, null, 2)` **带缩进**序列化，体积白白放大近一倍。

#### B2【高】顺序列表全量渲染，无虚拟化 / 分页
- **实测**：3000 张 → `.order-grid` 内 3000 个 `.og-card` + 3000 个 `<img>`，全页 DOM 节点 **63,268** 个。
- **外推**：25,428 张 → 约 **50 万+ DOM 节点** + 2.5 万个缩略图请求，页面必然长时间冻结甚至崩溃。

#### B3【中】SortableJS 在大列表上拖拽卡顿
- **实测**：3000 项单次拖拽 + 稳定耗时 ≈ **2.9 s**（扣除固定 1.5s 等待后）。Sortable 每次拖动需要在网格里做大量 DOM 插拔。
- **外推**：25k 项基本不可用 → A5 的 ↑/↓ 按钮从"增强"变成"刚需兜底"。

#### B4【中】缩略图 `<img>` 未禁用浏览器原生拖拽
- `.og-thumb` 是普通 `<img>`，Chrome/Edge 中图片自带原生 drag 行为，会与 SortableJS 抢拖拽事件，造成落点漂移或触发系统拖放。需 `draggable="false"`（或 CSS `-webkit-user-drag: none`）。

#### B5【低】标签分布与目录分布共用同一 `distMax` 刻度
- `app.js` 的 `distMax` 把 `stats.tags` 与 `stats.dirs` 的所有值合并取 max。当某个维度最大值远大于另一维度时，另一张图的条形几乎不可见。

---

### C. 与设计文档的偏差

| # | 偏差 | 文档依据 |
| :--- | :--- | :--- |
| C1 | `.export-view { max-width: 880px }`，实际是 880px 弹窗而非全屏视图；第二步缩略图网格在 880px 内仅约 7 列 | §2.3 / §3「全屏 Exporter View」 |
| C2 | `og-card` 未渲染 `it.tags`（后端已返回，文档要求行单元含标签） | §3.2 |
| C3 | `ordered[].prevTarget` 后端已返回，前端完全未使用 | §4.2 |

---

## 3. 验证通过的部分（无需改动）

- Vue 挂载正常，无 fatal error / pageerror（防白屏守卫未触发）。
- 拖拽落位准确：0→5 多步拖拽后原第 0 项精确落到索引 5，**DOM 顺序与 `previewOrdered` 完全一致**（Vue 3 keyed diff 与 Sortable 的 DOM 操作未出现错位）。
- 编号 `og-num` 随拖拽实时重排（101~110）。
- 「整体反转」后 DOM 与数据同步正确。
- 手动顺序经 `manualOrder` 回传后端，`sort_images` manual 分支采纳正确（API 直测：反转清单回传 → 返回顺序一致）。
- 导出落盘 `order` 映射与界面顺序逐项一致。
- 导出视图相关 CSS 类（`export-view-*` / `order-grid` / `og-*` / `kpi*` / `hbar*`）全部存在，无缺失样式。

---

## 4. 修复方案与落地

### 已修复（本轮）

| # | 修复 | 文件 |
| :--- | :--- | :--- |
| F1 | step ≥ 3 隐藏「确认导出」，结果页改为「🔄 再导一次」（重置回第①步）+「关闭」，杜绝重复导出 | `index.html` |
| F2 | Main 默认 `rename: "sequence"`，让文件名 = order；并在 UI 中明确「保持原文件名」选项仍可选 | `app.js` |
| F3 | 首次导出 version 默认 `1`（不再 101），与 UI「下版本 1」提示一致 | `main_exporter.py` |
| F4 | `_handle_export_preview` 改用 `Path(src).resolve()`，与 `/api/scan`、`build_manual_order` 口径统一，消除手动排序静默失效 | `server.py` |
| F5 | 第二步补上 `↑ / ↓ / ✕` 操作按钮，激活既有 `moveExportItem` / `removeFromPreview`；`✕` 后同步刷新统计 | `index.html` / `app.js` |
| F6 | `estWebpBytes` 改为按 `quality` 估算（WebP/JPG 用 quality 折算，PNG/original 标注为原图）；删除第一步死控件，保留单一质量滑杆 | `server.py` / `index.html` |
| F7 | 导出相关请求改为紧凑 JSON（去掉 `null, 2` 缩进），请求体直接减半 | `api.js` |
| F8 | 预检不再回传全量 `tagsRecords`（后端已能从 `tags.json` 兜底读取），请求体从 MB 级降到 KB 级 | `app.js` |
| F9 | `.og-thumb` 加 `draggable="false"` + CSS 禁用原生图片拖拽 | `index.html` / `studio.css` |
| F10 | `.og-card` 加 `content-visibility: auto` + `contain-intrinsic-size`，大列表渲染开销大幅下降 | `studio.css` |
| F11 | 标签分布与目录分布各自独立刻度（`distMaxTags` / `distMaxDirs`） | `app.js` |
| F12 | 第一步排序下拉补齐 `mtime_dsc`，与第二步选项集一致 | `index.html` |
| F13 | 第三步「起始序号」仅在 main 类型显示 | `index.html` |
| F14 | 新增 `excludedPaths` 契约：`base.py` 增加 `resolve_excluded()`，`main/daily/pack` 三个导出器与 `/api/export/preview` 统一过滤；前端维护 `exportExcluded` 集合并随 payload 提交，切换导出范围时作废 | `base.py` / `main_exporter.py` / `daily_exporter.py` / `pack_exporter_base.py` / `server.py` / `app.js` |
| F15 | `.export-view` 上限 880px → **1920px**（C1 落地）；`.export-body` 去掉 `max-height: calc(100vh - 210px)` 改用 `flex:1 + min-height:0` 精确填满，消除底部大片留白 | `studio.css` |

### 建议后续（本轮未动，需单独拍板）

| # | 建议 | 理由 |
| :--- | :--- | :--- |
| R1 | **两处**网格都值得做虚拟滚动，但手段不同（见 §7） | 25k 张下两处都会生成数万 DOM；`content-visibility` 只缓解渲染，不减少节点数 |
| C2 | `og-card` 渲染 `it.tags` 徽章、利用 `prevTarget` 做历史批次提示 | 文档 §3.2 / §4.2 |
| R2 | 预检结果缓存：sortBy / scope / excludeExported 未变时复用，避免切步重复请求 | 进一步降低 B1 |
| R3 | 服务端 `sort_images` manual 分支对 `rank.get(..., len(paths))` 的兜底加日志告警 | 让 A4 这类"静默退化"可见 |

---

## 7. 关于虚拟滚动的适用范围（澄清）

**主界面浏览网格 与 导出顺序列表是两个不同的问题，不能套同一个方案：**

| | 主界面浏览网格 (`.image-grid`) | 导出顺序列表 (`.order-grid`) |
| :--- | :--- | :--- |
| 数据量 | `filteredRecords` 全量渲染，无分页 | `previewOrdered` 全量渲染 |
| 实测（3000 张） | 3000 卡 + 3000 img，51,234 DOM 节点 | 3000 卡 + 9000 按钮，75,267 DOM 节点（含背后的浏览网格） |
| 25,428 张外推 | ~43 万节点 | ~63 万节点 |
| 交互约束 | **无拖拽**，只需点击选中 | **SortableJS 拖拽** |
| 虚拟滚动可行性 | ✅ 直接可行，标准窗口化即可 | ⚠️ 受限：Sortable 需要真实 DOM 才能拖 |

**结论：**
- **主界面网格**：虚拟滚动收益最大、实现最干净（纯窗口化，无第三方库也能手写）。**优先做这里**。
- **导出顺序列表**：虚拟滚动与拖拽天然冲突。可行折中是——窗口化渲染 + 依赖已加的 **↑/↓ 按钮**做跨窗口调整（按钮操作的是数据数组，不依赖 DOM），拖拽仅在当前渲染窗口内有效。若拖拽体验不可牺牲，则维持现状（`content-visibility` 已把绘制开销压下来，节点数仍在但不再卡绘制）。

> 备注：`↑/↓` 按钮操作 `previewOrdered` 数组下标，与 DOM 无关，因此天然兼容任何虚拟化方案；真正受限的只有"跨屏拖拽"这一种交互。

---

## 5. 复现 / 回归脚本

- `temp/studio_debug/probe_preview.py` —— 预检契约探针（name_asc / manual 回传 / 空边界）
- `temp/studio_debug/ui_probe.py` —— UI 主流程探针（挂载→扫描→选择→三步流）
- `temp/studio_debug/drag_probe.py` —— 拖拽落位 + 反转 + step4 按钮语义探针
- `temp/studio_debug/scale_probe.py` —— 3000 张规模压力探针（含请求体实测）
- `temp/studio_debug/scale_drag.py` —— 3000 张规模拖拽落位回归
- `temp/studio_debug/verify_fixes.py` —— 修复项逐条验证（quality 联动 / ↑↓✕ / 请求体）
- `temp/studio_debug/verify_exclude.py` —— ✕ 剔除端到端验证（预检/第三步/落盘三处一致）
- `temp/studio_debug/measure_grids.py` —— 主界面网格与顺序列表 DOM 规模测量
- `temp/studio_debug/shot_width.py` —— 多分辨率（1920/1440/1280）导出视图排版截图
- `temp/studio_debug/gen_images.py` —— 生成规模测试图片

---

## 6. 修复后回归结果（实测）

### 6.1 逐项验证

| # | 修复项 | 验证方式 | 结果 |
| :--- | :--- | :--- | :--- |
| F1 | 重复导出 | 导出成功后读取 `.export-nav` 按钮 | ✅ 按钮变为 `['📋 复制日志','← 上一步','关闭','🔄 再导一次']`，「确认导出」不再出现 |
| F2 | 文件名 = order | 拖 0→5 + 反转后导出 10 张，读取 `main/images/` | ✅ 落盘为 `101.webp … 110.webp`，`batch_001.json` 的 `order→url` 逐项吻合 |
| F3 | version=1 | 读取 `main/index.json` | ✅ `"version": 1`（修复前 101），batch version 同步为 1 |
| F4 | resolve 口径 | `py_compile` + preview 契约探针 | ✅ manual 回传顺序一致（`期望顺序 == 传入的 manualOrder ? True`） |
| F5 | ↑/↓/✕ | 3000 张下点击 `✕` 与 `↑` | ✅ `og-ops` 3000 个 / `og-btn` 9000 个；`✕` 后 `total 3000→2999`、`sourceBytes` 同步；`↑` 第 9 张正确换位 |
| F6 | quality 联动 | quality=20 时读 `previewStats` | ✅ `estRatio=0.04`，`estWebpBytes=25,182`（≈25 KB）；修复前恒为 `sourceBytes*0.2` |
| F7/F8 | 请求体瘦身 | Playwright 拦截 `POST /api/export/preview` | ✅ **2,166,289 B (2.1 MB) → 594,203 B (580 KB)，降低 72.6%** |
| F9 | 原生拖拽 | 3000 张下拖 0→6 | ✅ 精确落在索引 6，DOM == `previewOrdered` |
| F10 | 渲染开销 | 3000 张下拖拽耗时 | ✅ 拖拽+稳定 ≈ 0.5s（有效操作时间），`content-visibility` 未影响 Sortable 测量 |
| F11 | 分布刻度 | 读 `hbarWidth(cnt,'tags'/'dirs')` | ✅ 两图各自归一化 |
| F12 | 第一步下拉 | 选项集比对 | ✅ 补齐 `mtime_dsc`，与第二步一致 |
| F13 | 起始序号 | main 类型判定 | ✅ 仅 main 显示 |

### 6.2 既有测试套件

```
studio.test_frontend  test_js_syntax_integrity ... ok
                      test_page_headless_mount ... ok
studio.test_ledger    4 tests ... ok
studio.test_workspace 5 tests ... ok
studio.test_studio    30 tests ... ok
----------------------------------------------------------------------
Ran 41 tests in 10.3s  —  OK（0 failures, 0 errors）
```

### 6.3 规模指标对比

| 指标 | 修复前 | 修复后 |
| :--- | :--- | :--- |
| 预检请求体（3000 张） | 2,166,289 B (2.1 MB) | **594,203 B (580 KB)** ↓72.6% |
| 单张剔除后统计 | 不同步（无该功能） | ✅ total / sourceBytes / est / tags / dirs 即时重算 |
| 大列表精确调整 | 仅拖拽（3000 项 ≈ 2.9s/次） | ✅ ↑/↓ 单击即时换位，拖拽仍可用 |
| 体积预估 | 恒为原图 20% | ✅ 随 format + quality 变化（q20 → 4%） |
| 导出产物可读性 | 原文件名，顺序不可见 | ✅ `101.webp…110.webp` |
| 首次版本号 | 101（与 UI 提示矛盾） | ✅ 1 |
| ✕ 剔除单张 | 仅前端视觉移除，导出仍包含且序号错位 | ✅ 端到端排除，落盘 8 张连续无空洞 |

---

## 8. 标签规则统一：无标签素材一律落成规范兜底标签 [Others]（2026-09-08 追加）

> 用户要求「把没有 tag 的当作 others tag，统一排序规则」。落地为一条**标签不变量**：
> 素材无标签 / 标签无法归类时，`tags` 一律为 `["Others"]`（taxonomy 规范形式，大写 O），
> 绝不出现空数组或小写 `"others"`。「是否未分类」在任何位置都等价于 `OTHERS_TAG in tags`。

### 8.1 改动

| 文件 | 改动 |
| :--- | :--- |
| `taxonomy.py` | 新增唯一规范常量 `OTHERS_TAG = "Others"`（此前全靠字符串字面量，大小写漂移的根源） |
| `core/tags_manager.py` | **修复潜在 bug**：`("others" in tags)` 对规范形式 `"Others"` 永远为假 → 高 confidence 的未分类素材不会被标记待复核；改为 `OTHERS_TAG in tags` |
| `server.py` | 导出预检兜底 `["others"]` → `[OTHERS_TAG]`；实测 `stats.tags` 键由小写 `others` 统一为 `Others` |
| `exporters/main_exporter.py` | 双写兼容分支（`["Others"]` / `["others"]`）收窄为常量比较 |
| `static/js/app.js` | 前端不变量三件套 `normalizeTags` / `isOthers` / `applyTags`；扫描加载与导出后重拉均归一化；全部批量/查看器打标操作走 `applyTags`；统计 / 待复核 / Others 过滤从「空数组或全 others」多条件特判坍缩为 `includes(OTHERS)` |

### 8.2 顺带消除的前端特判

统一前这些位置各写一份 `!r.tags || r.tags.length === 0 || r.tags.every(t => t.toLowerCase() === 'others')`（共 5+ 处），
统一后全部变成 `isOthers(r)`：
- `tagCounts`（Others 桶计数，现直接平铺累加）
- `unreviewedCount`（待复核总数）
- `filteredRecords` 的 Others 过滤分支与「仅看待复核」分支
- `selectUnreviewedOnly`（选待复核）
- `tagCounts` Others 键恒存在（未打标也会计数，不再依赖单独的 othersCount 累加器）

### 8.3 验证（Playwright 实机，40 张全未打标样本）

```
1) Others(其他) 侧栏计数 = 40 ✅        2) 全部记录 tags === ['Others']，无空数组 ✅
3) 点「其他」过滤 = 40 张 ✅            4) 全选→覆盖 Landscapes → Others=0 / Landscapes=40 ✅
5) Others 过滤 = 0 张 ✅               6) 移除 Landscapes → 退回 Others=40 ✅
导出预检 stats.tags 键 = Others ✅      studio 41 个单测全部通过 ✅
```

### 8.4 回归脚本

`temp/studio_debug/verify_others.py`

---

## 9. 导出工作台收尾：主界面输出字段下沉 + 报错可视化 + 一键随机（tag 均分）

> 用户补充：①主界面不需要 输出目录 / HTTP 根地址，应在导出最后一步填写；②导出前空输出目录当时没有任何提示也没有报错；③手动排序界面加一键随机，相同 tag 尽量不相邻、尽量平均分配、组间按 taxonomy 顺序。

### 9.1 主界面输出字段下沉

| 文件 | 改动 |
| :--- | :--- |
| `static/index.html` `config-bar` | 移除「输出目录」「HTTP 根地址」两个 field-group；源目录保留（属于"扫描前就要确定"） |
| `static/index.html` 第③步 body 顶部 | 新增「📦 输出设置（确认导出前必填）」卡，含两个输入框，`*` 标必填，填写即记忆 `localStorage`，改动触发 `onOutputChange`（持久化 + 清错误 + 在第③步时重跑预检让建议序号/版本基于真实产物目录） |
| `static/js/app.js` | 新增 `onOutputChange` 与 `exportError` 引用，`persistConfig` 此前未暴露在 return 块（main bar `@change` 静默失效），本次顺带修正 |
| `static/css/studio.css` | 新增 `.output-settings` / `.output-settings-title` 样式（indigo 浅底强调"导出前必填"） |

### 9.2 空输出目录点导出有明确报错

`runExport` 入口先 `exportError.value = ""`，再分别校验「源目录 / 输出目录 / 标题（event+collection）」，不通过则把具体原因写到 `exportError` 同时 `showToast`，`exportStep` 保持 3 不误入导出。第③步 body 顶部加 `<div v-if="exportError" class="export-error-banner">` 红条，**持久展示**直到用户在输出设置或第①步修正（`goExportStep` / `openExport` / `onOutputChange` 都会清空）。

文案按"少了什么 → 在哪里补"两句式说清：

```
⛔ 输出目录为空：导出前请先在上方填写 输出目录 (Output Directory)。
⛔ 图片源目录为空：请回到主界面填写源目录后再导出。
⛔ 缺少英文标题：Event / Collection 导出前请填写英文标题 (Title)。
```

### 9.3 一键随机排序（tag 均分）

第②步新增「🎲 随机排序 (tag 均分)」按钮（与「↕ 整体反转」并列），调用 `randomShuffleOrder()`。算法：

1. 从每张图的 tags 取首个真实标签（无则归 OTHERS 桶），组内 Fisher-Yates 洗牌。
2. 组间按 **taxonomy 顺序** 排序（Others=17 在末位，未知名标签排在 Others 之前）。
3. **欠账优先贪心**出列：
   - 每格 `deficit = (pos+1)/N × count − placed`，欠得最多的下一格出列；同分按 taxonomy 顺序破平。
   - 若最优组与上一格相同且还有别的组可选，改取次优组（避免同 tag 紧邻）。
4. 强制头部为 taxonomy 顺序的第一个非空组，保证序列观感从真实分类起。
5. 随机后 `sortBy` 自动切到 `manual`，仍可继续手动拖拽 / ↑↓ 调整。

该算法在常见分布下**理论最优**（邻接 0，除非某组数量大到数学上无解）。

### 9.4 验证（Playwright 实机 40 张）

```
1) 主界面配置栏输入框数 = 1 ✅   （无「输出目录」「HTTP 根地址」字样）
3) 一键随机：顺序变化 ✅   sortBy = manual ✅   相邻同 tag = 0
   头 12: L,O,A,O,L,A,O,L,A,O,L,O   分布: L12 A12 O16
4) 第③步「📦 输出设置」面板出现 ✅
   清空 outDir → 点「确认导出」→ 红条 ⛔ 持久显示 ✅
   exportStep 保持 3（未误入导出）✅
   填写 outDir → 红条消失 ✅   确认导出 → 第④步 11 行日志 ✅
   落盘 40 张 ✅
```

Algorithm 模拟（Node）覆盖四个典型分布：

| 分布 | rr adj | rr+dominant adj | slot adj | **欠账优先 adj** | 头按 taxonomy |
| :--- | :---: | :---: | :---: | :---: | :---: |
| L12 A12 O16（用户真实场景） | 4 | 4 | 3 | **0** | ✓ |
| 4×10 均衡 | 0 | 0 | 0 | **0** | ✓ |
| L30 A5 O5 主导 | 24 | 19 | 24 | **19**（理论最小） | ✓ |
| L20 A20 O40 Other 多 | 0 | 0 | 0 | **0** | ✓ |

### 9.5 回归脚本

- `temp/studio_debug/verify_step3_output_shuffle.py` —— 三项需求合并验证
- `temp/studio_debug/shot_step3_states.py` —— 红条态 / 填写后正常态截图

`studio` 既有 41 个单测全部通过；`drag_probe` 等老探针同步改为通过 `__STUDIO_VM__.outDir = v` 注入（不再写 main bar 的 field）。
