# Content Studio WebUI — 代码结构、功能与后端 API 对接

> 适用范围：`studio/static/`（`index.html` 1059 行、`js/app.js` 2135 行、`js/api.js` 203 行、`js/logger.js` 271 行、`js/taxonomy.js` 347 行、`css/studio.css` 1399 行）
> 代码基线：2026-09-08。文中所有函数名、字段名、行号均取自当前源码。

---

## 一、技术栈与总体形态

| 项 | 选择 | 原因 |
|---|---|---|
| 框架 | Vue 3 **全局构建版**（`vendor/vue.global.prod.js`）+ 原生 ESM | 无需构建链，改完刷新即生效；`setup()` 组合式写法 |
| 拖拽 | `vendor/Sortable.min.js` | 导出顺序手动排序 |
| 裁切 | Cropper.js v1（**CDN**，`cdnjs`） | 大图查看器内手动画裁切框 |
| 样式 | 单文件 `studio.css`，CSS 变量主题 | 无预处理器 |
| 数据请求 | `fetch` 原生封装在 `api.js` | 无 axios |

**注意**：Vue 与 Sortable 是本地 vendor（离线可用），Cropper.js 走 CDN——离线环境下「画裁切框」按钮会不可用，其余功能不受影响。

---

## 二、文件结构与职责

```
studio/static/
├── index.html                 模板：头部 / 配置栏 / 侧栏 / 工具条 / 卡片网格 /
│                              导出三步工作台 / 正式导出确认 Modal / 大图查看器 / Toast
│                              + 致命白屏守卫内联脚本（renderFatalError）
├── css/studio.css             全部样式（含 .export-view max-width:1920px 大屏适配）
├── js/
│   ├── logger.js              零依赖 IIFE：接管 console + 环形缓冲 + 浮动日志面板（window.StdLog）
│   ├── api.js                 REST 客户端：唯一发请求的地方
│   ├── app.js                 Vue 主应用：全部状态、计算属性、业务方法
│   └── taxonomy.js            由 scripts/build_taxonomy.py 生成的离线分类常量（window.TAXONOMY）
└── vendor/
    ├── vue.global.prod.js
    └── Sortable.min.js
```

**加载顺序**（`index.html`，顺序本身是设计）：

```
内联致命守卫 → logger.js → taxonomy.js（脚本，挂 window.TAXONOMY）
→ vue.global.prod.js → Sortable.min.js → Cropper.js(CDN)
→ <script type="module" src="/static/js/app.js">
```

`logger.js` 必须**尽早**加载才能接管 `console`；`taxonomy.js` 在 `app.js` 之前只是作为降级数据源。

---

## 三、状态模型（app.js `setup()`）

### 3.1 分类元数据（运行时拉取，非硬编码）

`mainTags` / `catalogs` / `specificTags` / `tagZh` / `catalogToTags` / `tagToCatalogs`，在 `onMounted` 里由 `/api/taxonomy` 填充；失败时降级读 `window.TAXONOMY.main_tags`。

派生的展示态：`tagIcon`、`tagDesc`、`mainTagsRow1`（前 7 个）、`mainTagsRow2`（其余）——侧栏双行排布。

### 3.2 「标签不变量」三件套（前端单一事实源）

```js
const OTHERS = "Others";
const normalizeTags = (tags) => { /* 去空去重，小写 others 规范为 "Others"，空则落 [OTHERS] */ };
const isOthers   = (r) => r?.tags?.includes(OTHERS);
const isOthersTag = (t) => String(t||"").trim().toLowerCase() === "others";
const applyTags  = (r, tags, reviewRequired) => { r.tags = normalizeTags(tags); r.catalogs = [...r.tags]; r.review_required = ...; };
```

**这是全前端最重要的一条约定**：素材无标签时 `tags` 恒为 `["Others"]`，绝不出现空数组或小写 `"others"`。于是「是否未分类」在任何位置都等价于 `isOthers(r)`——`tagCounts`、`unreviewedCount`、Others 过滤、「选待复核」全部坍缩成一个判定，不再有分散特判。

所有写入口（`doScan` 加载、批量设/加/删/清标签、查看器点标签）一律走 `applyTags`，保证不变量恒成立。

### 3.3 核心响应式状态

| 分类 | 状态 |
|---|---|
| 配置（localStorage 持久化） | `srcDir` / `outDir` / `httpBase`（键：`studio_srcDir`、`studio_outDir`、`studio_httpBase`） |
| 数据 | `records[]`、`selectedSet: Set<path>`、`qualitySummary` |
| 过滤 | `activeTag`、`onlyUnreviewed`、`hideExported`、`onlyDuplicates`、`searchQuery` |
| 质检过滤 | `filterGrade`（S/A/B/C/F/unscored）、`filterScoreMin`、`filterScoreMax`、`filterUpgradeable` |
| 排序与显示 | `sortBy`（name/quality/mtime/confidence/size/dimension）、`sortOrder`、`cardZoom`（持久化 `studio_cardZoom`） |
| 质检任务 | `qcTaskId`、`qcProgress`、`qcLogs`、`isBatchEvaluating`、`isEvaluatingQuality` |
| 导出会话 | `exportModalOpen`、`exportType`、`exportStep`(1/2/3)、`exportConfig`、`exportExcluded: Set`、`previewState`、`exportLogs`、`exportDone`、`exportError`、`isExporting` |
| 试导出 | `lastExportIsTrial`、`lastTrialDir`、`confirmFormalOpen`、`formalConfirmChecked` |
| 查看器 | `viewerModalOpen`、`viewerIndex`、`currentViewerItem` |
| 裁切 | `cropMode`、`cropAspectRatio`、`isSavingCrop`、`manualCropCache`、`cropPixelW/H` |
| 服务连通 | `serverOnline`、`isCheckingServer`、`thumbEpoch` |

### 3.4 关键计算属性

- `filteredRecords`：过滤主干。顺序为 侧栏分类 → 仅看待复核 → 仅看重复 → 隐藏已导出 → 品质评级 → 分数区间 → 可升级 → 关键字 → 排序。其中 `activeTag` 支持两个**伪分类**：`__exported`（已导出）、`__small_long`（长边 <1920 不合格）。
- `tagCounts` / `unreviewedCount` / `exportedCount` / `unexportedCount` / `duplicateCount` / `smallLongCount`：头部与侧栏计数。
- `isUnselectable(item)`：`too_small_long || exported` → 卡片置灰、checkbox disabled、全选/反选/选待复核/选未导出全部跳过。**从源头阻止不合格图进入导出**。
- `hasDuplicateInExportScope`：勾选范围内的重复素材预警。

---

## 四、功能模块

### 4.1 主工作区（扫描 → 打标 → 质检）

- **扫描**：`doScan()` → `/api/scan` → `normalizeTags` 归一化 → 清空选中 → 装配 `qualitySummary` → 后台 `fetchManualCropsAfterScan()` 拉裁切覆盖（不阻塞 UI）。
- **保存**：`doSave()` → POST `/api/tags`（全量 records）。
- **批量操作**：全选 / 全不选 / 反选 / 选待复核 / 选未导出；批量 设置 / 追加 / 移除 / 清空 标签；一键复核 / 标记待复核。全部只改前端 `records`，**落盘靠 `doSave`**。
- **单张质检**：卡片上小按钮与查看器内「分析」按钮 → `/api/quality`（后者带 `force=1`）。
- **批量质检**：见 4.4。

### 4.2 大图查看器与手动裁切

- `openViewer` / `prevViewer` / `nextViewer` / `closeViewer`；键盘 `← →` 翻页、`Esc` 关闭。
- 底部：当前标签、快速添加标签（按 taxonomy）、「标记已复核 / 已复核」切换。
- **自动裁切框 overlay（红虚线）**：`cropOverlayStyle` 依据 `quality.details.crop_box` 与图片原始 `width/height` 算百分比定位；`score_boosted` 时显示 ⬆。
- **手动裁切框 overlay（蓝框）**：`manualCropOverlayStyle` 依据 `manualCropCache[hash]`。
- **画裁切框**：`enterCropMode()` 初始化 Cropper.js（`initCropper`），工具栏提供 1:1 / 3:4 / 4:3 / 自由 四档比例 + 保存 / 取消 / 删除，并实时显示裁切后像素尺寸 `cropPixelText`（短边 <1200 时标 ⚠）。
- 坐标用 `getData(true)` 取**原图像素坐标**，再除以原图宽高转成 0.0~1.0 百分比后提交。
- `syncViewerImg()`：图片 load / 翻页 / resize 时用 JS 把 wrapper 尺寸同步到 img 实际渲染尺寸——**修 overlay 百分比偏移的根因**（CSS `inline-block` + `max-height:100%` 在 flex 容器里存在循环高度依赖，竖图溢出导致错位）。

### 4.3 导出三步工作台

`exportStep`：① 基础配置 → ② 顺序调整 → ③ 导出前预览（完成态停留在此，不跳第④步）。

**① 基础配置**
- 类型选项卡：Main / Daily / Event / Collection（切换 main 时 `resetStartOrderForType()` 用建议值重置起始序号）。
- 导出范围：**只支持「已勾选」**（"全部"已移除，防止混入未勾选 / 分辨率不足 / 已导出的图）；`openExport` 强制 `exportScope="selected"`。
- 规格化：目标比例多选（自动 = 1:1 + 4:3 族，可手选 1:1 / 4:3 / 2:3，与「自动」互斥）+ 裁切方式（smart / center / none），长边固定 1920。
- 各类型专属字段：main 起始序号 / 版本；daily 月份；event / collection 的 ID + 中英标题 + 描述 + displayOrder + status + outputMode。
- 勾选范围内有重复素材时显示红条预警。

**② 顺序调整**
- `previewOrdered` 网格（`.og-card`，`content-visibility:auto` 缓解大列表渲染）；`sortBy=manual` 时由 SortableJS 启用拖拽。
- 工具：切换到手动排序 / ↕ 整体反转 / **🎲 随机排序 (tag 均分)**。
- 每张卡：`↑` `↓` `✕` 三个兜底按钮（大列表拖拽卡顿时仍可精确调整，`✕` 剔除后即时重算统计）。
- 随机算法 `fairTagShuffle`：按每张图首个真实标签分组（无则归 Others）→ 组内 Fisher-Yates → 组间按 taxonomy 顺序做**欠账优先贪心**（`deficit = (pos+1)/N × count − placed`，欠最多者出列，同分按 taxonomy 顺序破平；若与上一格同 tag 且有别的可选则改取次优），头部强制取 taxonomy 第一个非空组。实测常见分布下同 tag 邻接为 0。
- `rebuildSortable()` 在排序方式 / 步骤 / 列表长度变化时重建拖拽实例。

**③ 导出前预览**
- 试导出 / 正式导出 双按钮（默认**试导出**）；正式导出有红条警告。
- **📦 输出设置**：输出目录（必填）+ HTTP 根地址，填写即记忆 localStorage 并重跑预检（让建议序号/版本基于真实产物目录）。
- 统计卡片：总数、原图体积、预计产物体积、标签分布、目录分布、含已导出张数、起始序号与版本。
- 必填校验失败时顶部**持久红条** `exportError`（源目录 / 输出目录 / event+collection 标题），不再只是一闪而过的 toast。
- 执行中实时滚动日志 + 进度；完成后 `exportDone` 置位、**停留第③步**，底部只留「关闭」。

**正式导出二次确认 Modal**：切到正式导出并点确认时弹出，逐条列出副作用，勾选后才可提交（纯前端防呆）。

### 4.4 批量质检（异步任务 + 轮询）

```
triggerBatchQuality(force)
  → 生成 taskId = "qc_" + …
  → localStorage["activeQualityTask"] = {taskId, dir}     // 刷新可恢复
  → POST /api/quality/batch  → 立即返回 {taskId, total}
  → pollQualityStatus()  700ms setTimeout 递归（不叠加速率）
       ├ done  → finalizeQualityJob(true)
       ├ error → finalizeQualityJob(false)（"cancelled" 显示为「质检已取消」）
       ├ 未 found（服务重启/超时）→ 按成功恢复：从 SQLite 装配已落库结果
       └ running → 更新 qcProgress / qcLogs(最近 20 条) 继续轮询
```

完成后的刷新是**轻量**的：`fetchQualityScores()`（纯 SQL）merge 到已有 `records`，而不是重新 `/api/scan` 全量扫文件系统。

`cancelQuality()` → POST `/api/quality/cancel`（协作式，worker 在子批边界退出）。
`resumeQualityJob()` 在 `onMounted` 末尾调用，实现页面刷新后自动重连未完成的质检任务。

### 4.5 服务端连通性守护

- `checkServerHealth()`：`/api/health` 带 4s `AbortController` 超时；**连续 2 次失败才判定离线**（消除瞬时抖动误报）。
- 每 3s 心跳一次；`handleImageError()` 在缩略图加载失败时防抖 800ms 触发一次检测。
- 离线时顶部红条 + 点击重试；恢复时刷新 `thumbEpoch`（给所有缩略图 URL 加 `_e=` 破缓存，强制重拉）。
- 头部心跳指示器可手动点击检测。

### 4.6 前端日志（logger.js）

- 接管 `console.log/info/warn/error/debug`：原样输出浏览器控制台 + 写入 500 条环形缓冲；
- 捕获 `window.error` 与 `unhandledrejection`；
- 暴露 `window.StdLog`（`error/warn/info/log/debug/show/hide/toggle/copy/clear`）；
- 右下角 📜 浮动按钮展开面板，可一键复制全部（优先 `navigator.clipboard`，非安全上下文回退 `textarea+execCommand`）；样式内联，不依赖 `studio.css`；z-index 低于致命白屏层。
- `app.js` 在 7 处用户可见错误的 `catch` 中插入 `console.error("[上下文]", err)`，自动进面板（正常降级的 `catch (_) {}` 不计入）。

### 4.7 键盘快捷键

`Esc`：关查看器 → 关导出工作台 → 清空选中；查看器内 `←/→` 翻页；`Ctrl+A` 全选当前过滤结果（输入框内不触发）。

---

## 五、API 客户端（api.js）与后端逐一对接

| 前端函数 | 请求 | 后端端点 | 备注 |
|---|---|---|---|
| `checkHealth(4000)` | GET | `/api/health` | `AbortController` 超时；`cache:no-store` + `?t=` 破缓存 |
| `fetchTaxonomy()` | GET | `/api/taxonomy` | 前端分类元数据唯一来源 |
| `scanDirectory(dir)` | GET | `/api/scan?dir=` | 主扫描 |
| `fetchTags(dir)` | GET | `/api/tags?dir=` | 只读 tags.json |
| `saveTags(dir, records)` | POST | `/api/tags` | 全量写回 |
| `executeExport(payload)` | POST | `/api/export` | 失败时把 `data.logs` 挂到 `err.logs` |
| `previewExport(payload)` | POST | `/api/export/preview` | 只读预检 |
| `fetchExportStatus(id)` → `fetchJobStatus(id)` | GET | `/api/job/status?task=` | **不抛错**，未找到返回 `{ok:false,found:false}` |
| `fetchJobStatus(id)` | GET | `/api/job/status?task=` | 导出与质检共用 |
| `fetchQuality(path,hash,dir,force)` | GET | `/api/quality` | — |
| `fetchQualityStats(dir)` | GET | `/api/quality/stats` | — |
| `fetchQualityScores(dir)` | GET | `/api/quality/scores` | 质检完成后的轻量刷新 |
| `batchEvaluateQuality(dir,limit,paths,force,clientTaskId)` | POST | `/api/quality/batch` | 返回 `{ok, taskId, total, started}` |
| `cancelQualityJob(taskId)` | POST | `/api/quality/cancel` | — |
| `fetchManualCrops(dir)` | GET | `/api/crop/manual?dir=` | — |
| `saveManualCrop(hash,box,ratio,dir)` | POST | `/api/crop/manual` | box 为 `{x0,y0,x1,y1}` 百分比 |
| `deleteManualCrop(hash,dir)` | DELETE | `/api/crop/manual?hash=&dir=` | — |
| `getThumbUrl(path,size,baseDir)` | — | `/api/thumb?path=&size=&dir=` | **尺寸分桶** 240/360/480/640/800，提高缓存命中；`dir=` 让后端能解析相对路径 |
| `getFileUrl(path,baseDir)` | — | `/api/file?path=&dir=` | 查看器原图 |

**序列化细节**：`jsonStringifySafe()` 刻意**不加缩进**——导出 payload 可能携带上万条 slim 记录，缩进会让体积近乎翻倍（实测 3000 张 2.1MB → 1.1MB）。配合 `buildSlimRecords()` 只回传 `path/file/hash/tags/exported` 五个字段，预检请求体实测量降 72.6%。

---

## 六、两条关键数据流

### 6.1 导出（双通道竞速 + 幂等收尾）

```
startExport()
  ├ trial=true  → runExport()
  └ trial=false → confirmFormalOpen（勾选后 confirmFormalExport → runExport）

runExport()
  1) 必填校验：srcDir / outDir / selectedSet / (event|collection 标题) → 失败写 exportError 红条并 return
  2) 生成 taskId = "exp_…"，置 isExporting
  3) 启动轮询：setTimeout(pollStatus, 150)，之后每 700ms
  4) 同时 await POST /api/export（同步长连接）
  5) finalize(success, info) 幂等：谁先到终态谁收尾，后到者忽略
       ├ 成功 + 试导出：显示 🧪 + trialDir，skipRescan=true（不重扫，角标不变即零污染证明）
       ├ 成功 + 正式：rescanAfterSuccess() 重新 /api/scan
       └ 失败：展示 st.logs
  6) exportDone = true，停留第③步
```

payload 关键点：`clientTaskId`、`trial`、`selectedPaths`、`manualOrder`（`previewOrdered.map(o => o.rel)`）、`excludedPaths`、`tagsRecords`（slim）、`targetRatios`、`cropMode`、`rename`。

### 6.2 剔除图片的闭环（`excludedPaths` 契约）

第②步点 `✕` → `removeFromPreview(i)` 从 `previewOrdered` 移除并把 `rel` 加入 `exportExcluded` → 预检与导出 payload 都带 `excludedPaths` → 后端 `resolve_excluded()` 按小写 posix 相对路径过滤。

**为什么必须传**：不传的话，被剔除的图片只是从前端清单消失，后端仍按全量扫描导出——它们会拿到兜底 rank 排到清单末尾**照样导出**（曾实测「预览 8 张、实际导出 10 张且序号错位」）。

切换导出范围时 `exportExcluded` 自动作废（`watch`）；每次 `openExport` 也会清空。

---

## 七、性能与规模处理

| 手段 | 位置 | 效果 |
|---|---|---|
| 缩略图尺寸分桶（240/360/480/640/800） | `getThumbUrl` | 提高浏览器与服务端缓存命中 |
| ETag + `max-age=86400, immutable` | 后端 `/api/thumb` | 二次访问 304 |
| `jsonStringifySafe` 不缩进 + `buildSlimRecords` | `api.js` / `app.js` | 预检请求体 -72.6% |
| `.og-card` `content-visibility:auto` + `contain-intrinsic-size` | `studio.css` | 视口外卡片跳过布局绘制 |
| `.export-view` `max-width:1920px`（原 880px） | `studio.css:1217` | 1920 屏实测 1872px、顺序网格 16 列 |
| 质检完成走 `/api/quality/scores` 而非重扫 | `finalizeQualityJob` | 1138 张时省掉 1138 次 `os.stat` |
| 缩略图 `draggable=false` + `pointer-events:none` | `index.html` `.og-thumb` | 避免原生图片拖拽与 SortableJS 抢事件 |

**未解决的规模问题**：顺序列表**没有虚拟滚动**——25k 张仍会生成 2.5 万 DOM 节点，`content-visibility` 只缓解渲染不减少节点。澄清一点：主界面浏览网格（无拖拽）与导出顺序列表（SortableJS 需真实 DOM）是两个问题；`↑/↓` 操作的是数组下标、与 DOM 无关，真正受限的只有「跨屏拖拽」。

---

## 八、已知边界

1. **Cropper.js 走 CDN**：离线环境下「画裁切框」不可用。
2. **正式导出二次确认是纯前端防呆**：直接调 API 无此拦截。
3. **预检结果无缓存**：切换步骤（第②、③步各触发一次）会重复请求，参数未变时也重算。
4. **localStorage 目录记忆**：`srcDir`/`outDir`/`httpBase` 记在浏览器本地，换机器或清缓存后需重填。
5. `.og-card` 尚未渲染 `it.tags` 徽章，也未用 `prevTarget` 做历史批次提示（已列待办）。
