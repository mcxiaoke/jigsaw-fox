# Studio 导出工作流升级方案：排序 / 导出前预览 / WebP 质量 / 自动起始序号 (Design: dsf)

> **文档版本**：v1.0.0
> **创建日期**：2026-09-07
> **适用模块**：Studio 前端 (`studio/static`)、后端 (`studio/server.py`、`studio/exporters/*`、`studio/core/*`)
> **状态**：方案 / 待评审
> **背景**：在既有 `main-incremental-export-and-mapping-design-review` 与 `unified-content-export-and-storage-architecture-review` 两个架构评审之上，落地的第一批发包能力增强。

---

## 1. 需求清单

| # | 需求 | 核心痛点 |
| :--- | :--- | :--- |
| 1 | 导出排序（可手动） | 顺序来自扫描字典序/无偏好，Main 的编号与内容无关 |
| 2 | 导出前数据预览 | 导出前"一抹黑"，不知道总张数 / tag / 目录 / 防重情况 |
| 3 | 可配置 WebP 压缩率（默认 70%） | `convert_image` 的 `quality=85` 是硬编码，不可调 |
| 4 | 自动填写起始序号（记忆上次 maxId） | `startOrder` 靠人工填，忘改会覆盖旧图 |

---

## 2. 现状分析（含前端结构评估）

### 2.1 前端整体是单实例 Vue SPA
`studio/static/index.html + js/app.js` 是一个 `#app` 单页工作台：
- **主工作台（浏览区）**：`header`（统计徽章 / 保存 / 导出入口）→ `config-bar`（源目录等）→ 左侧 `tag-sidebar` → 中间**图片卡片网格** → `viewerModal` 高清查看器。
- **导出**：`exportModalOpen` 一个**统一小 Modal**（[index.html L408-L569](file:///c:/Home/Projects/jigsawpuzzle/studio/static/index.html#L408-L569)），内部用 `tab-group` 折叠了 main / daily / event / collection 四类导出配置（scope 范围、format、rename、startOrder、version、month、eventId/collectionId、outputMode、title/desc、excludeExported、重复告警、日志、footer）。

### 2.2 关于"SPA 单页是否是好设计" —— 结论：是，无需推翻
这是**内部单用户、离线优先、弱交互的对象打包工具**（Content Studio），不是对外多路由产品：
- 主工作台本质是**一个持续状态页面**：`srcDir` 扫描 → 标签筛选 → 打标 → 质检 → 导出。`tag-sidebar` 的筛选、卡片网格、头部徽章都依赖**同一个 Vue 根的实时响应式状态**（`records` / `exportedCount` / `isSelected`）。拆成多路由页面反而要跨页搬运「当前源目录 / 已选图片 / 已加载记录 / 标签态」，得不偿失。
- 无 SEO / 深链 / 多端诉求，也不存在代码分包以提速的必要，SPA 的"单页响应式 + 无路由"在这里是**优点**。
- **真正的问题不是 SPA，而是"导出流程复杂度 × Modal 小容器"不匹配**：所有配置 + 防重 + 日志硬塞进一个小弹窗，新增排序 / 预览 / 质量 / 自动 id 后必然溢出。

### 2.3 结论：保留 SPA 浏览页，把"导出流程"从 Modal 提升为全屏视图
维护上，若持续在一个 `app.js`(33KB) 里堆配置，会脆。但**不必引入路由或多页面**，只做两层改造：
1. 主浏览工作台保持单页，字段/逻辑不拆；
2. 导出流程独立成**全屏 Exporter View**（同一 Vue 根上用一个 `v-show` 覆盖层切换，仍单实例，但视觉与容量都是"完整页面"），内部走确定的三步流程。

---

## 3. 目标界面结构：全屏 Exporter View + 三步流程

```
流程总览:
  选择素材(浏览页选中) → 全屏导出视图
      ├─ [第一步] 基础配置   ── 类型/范围/格式/WebP质量/排序方式/起始序号/版本
      ├─ [第二步] 顺序调整   ── 手动拖拽排序列表（= order 分配顺序）
      └─ [第三步] 导出前预览 ── 统计卡片 + tag/目录分布 + 目标参数 + 防重预警
                                └─ 确认导出 → 日志区
```

> 通过把导出升级为全屏视图，**所有新控件都有独立空间**，不再挤压浏览区，也不受原 Modal 尺寸限制。

### 3.1 第一步 · 基础配置（新版导出表单字段）

| 字段 | 类型 | 说明 / 默认 |
| :--- | :--- | :--- |
| 导出类型 | 单选 | main / daily / event / collection |
| 导出范围 | 单选 | 全部 / 仅选中 |
| 格式 format | 下拉 | original / webp / jpg / png |
| **WebP 质量 quality** | **滑杆 1~100** | **默认 70**；仅 format∈{webp,jpg} 生效 |
| **排序 sortBy** | **下拉 + 自动按钮** | name_asc *默认* / name_dsc / path / mtime / size / **manual(手动)** |
| **起始序号 startOrder** | number | **自动填充 `maxOrder+1`**，可手动改；服务端强校验 > maxOrder |
| 版本 version | text | 留空=自增 |
| outputMode / 标题类（event/collection） | 按需 | 与现状一致 |
| 其他 | — | excludeExported、按月 etc. |

### 3.2 第二步 · 顺序调整列表
- 行单元 = `拖拽柄 + 顺位编号 + 缩略图 + 文件名 + 标签` + `↑ ↓ ✕`。
- 排序方式切换：手动拖拽（默认）⇄ 一键「按名称 / 按目录 / 按大小」。
- **列表固有顺序 = 导出 order 分配顺序**，每移动一次即影响 `main/201.webp…` 编号。
- 数据来源于**同一份预检结果 `ordered` 数组**，本地排序/拖拽/删除只改数组、不回源请求。

### 3.3 第三步 · 导出前预览（解决需求 2）
- KPI 卡：素材张数 / 原图合计 / 预计 WebP 体积 / 未导出数。
- 分布条：标签分布（归一化后 Top-N + others）、目录分布（相对一级父目录）。
- 参数摘要：起始序号 / 版本 / 质量 / 输出目录。
- 防重预警：预检已在历史批次导出的图片以「黄/橙胶囊」标出（第一步列表同步红标，便于提前发现）。
- 底部：`← 返回排序`  / `确认导出`（→ 日志区展示执行过程与统计）。

---

## 4. 后端契约与实现要点（四个需求逐一落实）

### 4.1 排序（需求 1）
- 给导出器增加 `sortBy` 入参；在**选定图片后、分配序号前**统一排序：
  | 值 | 排序键（稳定的 tie-breaker 一律用相对路径升序） |
  | :--- | :--- |
  | `name_asc`/`name_dsc` | 文件名 |
  | `path_asc`/`path_dsc` | 相对路径 |
  | `mtime_asc`/`mtime_dsc` | 文件修改时间 |
  | `size_asc`/`size_dsc` | 文件大小 |
  | `manual` | 保持前端 `selectedPaths` 传入顺序 |
- 落点：`scanner` 或 `BaseExporter` 提供一个 `sort_images(paths, sortBy)`，供所有 exporter 复用。
- main 建议同时将 `rename_rule` 默认改为 `sequence`（`101.webp…`），让"文件名 = order"，与自动起始序号自然衔接。
- 可靠点：先排序 → 再编号 → 再转码，清单与产物一一对应；key 相同的用相对路径兜底，保证同批两次导出顺序一致（幂等）。

### 4.2 导出前数据统计（需求 2 —— 新增 `/api/export/preview`）
- 新增只读预检接口：入参 `srcDir / sortBy / selectedPaths`，返回：
  ```
  {
    ordered: [ { rel, thumb, tags[], dir, size, isExported, prevTarget } ],  // 排序后的图片项
    stats: { total, sourceBytes, estWebpBytes, tags: {k:v}, dirs: {k:v},
             unexported, alreadyExported },
    suggestedStartOrder, suggestedVersion, maxOrder
  }
  ```
- `ordered` 在第一步渲染列表、第二步展示统计；前端不重复计算。
- 统计口径与导出一致：tag 用归一化后标签（无则 `others`），目录取相对一级父目录，体积预估标注"预计"（用像素数→WebP 估算，不追求精确）。
- 导出成功后，把本次 `stats` 透传给前端日志（扩展 `ExportResult`，可选字段，向后兼容）。

### 4.3 WebP 压缩率可配（需求 3）
- 入参 `quality`（或 `webpQuality`），默认 **70**；前端滑杆 1~100。
- 在各 exporter 调用 `convert_image(src, dst, fmt, quality)` 时透传（当前是硬编码 85 未透传——见 `main_exporter.py` L150）。
- `server` 层夹取合法范围（1~100），非法回退默认 70。

### 4.4 自动起始序号 + 防覆盖（需求 4）
- **maxOrder 事实源**：`out/<module>.json` 中 `levels[].order` 的最大值（`main.map.json` 二次核对；容忍空洞取 max 而非 count）。
- `suggestedStartOrder = maxOrder + 1`，文件不存在 → 默认 101。
- 前端弹窗打开自动填充，可改。
- **服务端强制**：导出器在拿到 `startOrder` 后重新读取当前 `maxOrder`，若 `startOrder <= maxOrder` → 报错中止（`startOrder 必须 == maxOrder + 1`）。
- 说明：可在既有 `/api/export` 与新增 `/api/export/preview` **共用**该 maxOrder 推导逻辑。

---

## 5. 前端落地要点

1. `index.html`：把现有 `exportModalOpen` 提升为 `exportViewOpen` 全屏覆盖容器；新增三步视图骨架（配置 / 排序 / 预览），沿用当前 modal 的字段结构以减少复制。
2. `app.js`：`openExport()` 改为打开全屏视图；接入 `/api/export/preview` 预检，填充 `suggestedStartOrder、suggestedVersion、stats、ordered`；三步间用同一份 `ordered` 传递；新增质量滑杆、排序切换（含手动拖拽或 ↑↓）与统计渲染。
3. 若单个 `app.js` 进一步膨胀（>40KB），再把 Exporter View 拆成独立 `export_view.js`（不引路由，仅脚本拆分），主浏览 SPA 不动。

---

## 6. 落地顺序（建议分 2 期）

### 一期（后端，先稳）
1. `sort_images()` 排序工具 + 各 exporter 接入 `sortBy`（需求1）。
2. `convert_image` 透传 `quality` + 默认 70（需求3）。
3. 抽 `resolve_module_maxorder(out, module)` + 导出器 `startOrder > maxOrder` 防护（需求4）。
4. 新增 `/api/export/preview` 返回 `ordered + stats + suggested`（需求2 前半）。
5. 单测：排序确定性 / 质量夹取 / maxOrder 推导与覆盖拦截 / preview 统计口径。

### 二期（前端）
6. 全屏 Exporter View 三步流程 + 排序列表 + 预览面板 + 质量滑杆 + 自动序号填充。
7. `flutter analyze / flutter test`、`flutter build windows --debug` 回归（确保服务端改动不影响客户端契约 `main.json`）。

---

## 7. 可靠性 / 易用性要点

- **排序=order 唯一依据**：最终提交清单数组下标即 order，服务端以 `suggestedStartOrder` 为基编号，前后端不脱节。
- **防覆盖不靠人记**：序号可改但服务端强制 `> maxOrder`，杜绝"忘改→盖旧图"。
- **预览无副作用**：`/api/export/preview` 只读，不写盘不转码（或仅极端块级校验），运营看到统计后才确认。
- **诚实标注**：体积为"预计"；统计口径与写盘完全同源，避免预览与结果不一致。
- **SPA 保留**：不把浏览工作台拆成多页面，仅在单 Vue 根内用全屏覆盖层承载导出流程；当 app.js 过大时仅做脚本拆分，不做路由重构。