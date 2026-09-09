# Content Studio 前后端架构重构规划（渐进式，不重写）

> 适用范围：`studio/` 子项目（`server.py` + `static/` 前端）
> 编写时间：2026-09-08 22:26 (GMT+8)
> 触发：单图删除功能（+572 行）代码量审查 → 引发出对整体可维护性的评估
> 状态：**方案讨论稿，尚未实施，等待逐项拍板**  
> ⚠️ 本文为**重构规划**，其中端点改名（如 `/api/quality/batch/cancel`）**尚未实施**；与 `studio-server-architecture-and-api-20260908.md`（现状架构）不一致时，以后者 + 当前源码为准，避免按图索骥。

---

## 一、现状诊断

### 1.1 规模清单（2026-09-08 基线）

| 端 | 文件 | 行数 | 职责数 |
|---|---|---|---|
| 后端 | `server.py` | 1790 | 5+：路由分发 / 30 个业务 handler / JobStore / 质检 worker / 日志初始化 / 静态服务 |
| 后端 | `core/`（9 模块） | 3629 | 领域层：扫描/质检/转码/账本/缓存 — **分层健康** |
| 后端 | `exporters/`（8 模块） | 1957 | 策略模式导出引擎 — **分层健康** |
| 前端 | `js/app.js` | 2228 | 单 `setup()`：48 ref + 40 computed + 85 方法 全在一个函数作用域 |
| 前端 | `index.html` | 1102 | 全部模板（头部/侧栏/网格/导出工作台/查看器/弹窗/Toast） |
| 前端 | `css/studio.css` | 1420 | 全部样式单文件 |
| 前端 | `js/api.js` | 218 | REST 唯一请求层 — **职责单一** |
| 前端 | `js/logger.js` / `taxonomy.js` | 271 / 347 | — 职责单一 |

### 1.2 核心判断

**可维护性问题不在"分层缺失"，而在两个"编排壳"越界膨胀**：

- 后端病灶：`server.py` 把 HTTP 壳 + 路由 + 全部 handler + 任务托管焊在一个类里；但 `core/` 领域层与 `exporters/` 策略层已经抽得干净，**业务逻辑大部分已下沉**，server.py 里的 handler 多是"解析参数 → 调 core → 返回 JSON"的薄壳。
- 前端病灶：`app.js` 单 `setup()` 是真正的"上帝函数"——改一个功能要同时动 index.html + app.js + studio.css（可能还要 api.js），且 `setup()` 的 return 块漏绑定模板时**不报错**（见 lessons-learned §二），状态靠闭包隐式互传。
- 历史反复出现的 bug（口径不一致 / 只改一半）在单文件巨型化下更容易发生。

### 1.3 触发案例（本次删除功能）

单图删除 +572 行（功能代码 380 + 测试 121 + 文档 71）。其中约 85 行孤儿数据清理、39 行体验加固属"顺带正确性"。功能本身规模正常，但**暴露了改一个功能要动 8 个文件、且前端状态无边界**的结构问题。

---

## 二、前提变化：约束解除后的重新评估

### 2.1 原约束（demo 期遗留，现已解除）

- 后端"零第三方 Web 框架"（只用 stdlib http.server）
- 前端"无构建链，改完刷新即生效"（Vue 全局版 + 原生 ESM）

这两条是项目代码量很少时的快速立项约束。**现已明确解除**，可引入框架/构建链。但"改造量不能特别巨大、不能等于完全重写"仍是硬前提。

### 2.2 重新评估结论

| 端 | 结论 | 原因 |
|---|---|---|
| **前端** | **值得升级：Vite + Vue SFC + Pinia** | 三体问题（模板/逻辑/样式分居三文件）只有组件化能根治；与既有"删除二次确认复用"讨论直接衔接 |
| **后端** | **维持 http.server，只做结构拆分**（不换 FastAPI/Flask） | 业务逻辑已在 core/，handler 是薄壳；本地单用户 15 API 无鉴权无中间件，框架价值（校验/文档/DI/高并发）全用不上；换框架成本（30 handler + 51 测试改写）换来的只是"代码位置变了" |

---

## 三、目标架构

### 3.1 前端目标形态（Vite + SFC + Pinia）

```
App.vue（装配层，业务逻辑不落这里）
 ├── AppShell          扫描·侧栏·卡片网格（含批量打标）
 ├── ViewerModal       大图查看器 + 裁切 + 删除（本次新增逻辑归入此）
 ├── ExportWorkbench   三步导出向导 + 正式导出二次确认
 ├── ConfirmDialog     通用二次确认弹窗（删除/正式导出复用，消掉 4 弹窗复制）
 └── ToastMsg          轻提示

Pinia stores（共享状态显式化，按现状状态模型切 5 个）：
 ├── useConfig      srcDir/outDir/httpBase/cardZoom（localStorage 持久化）
 ├── useRecords     records[]/selectedSet + filteredRecords 派生链 + 批量操作
 ├── useQuality     质检任务 state + 轮询/取消/恢复
 ├── useViewer      viewerIndex/currentItem + cropMode + 删除动作
 └── useExport      三步会话 exportStep/config/preview/logs + 试导出/正式导出

组件间不直连，跨组件共享一律走 store。
```

**关键认知**：SFC 化 ≠ 重写逻辑。`filteredRecords` 计算链、`fairTagShuffle`、状态机等经过多轮 bug 淬炼的逻辑**原样搬移**，只改"代码放哪"。

### 3.2 后端目标形态（仍为 stdlib）

```
server.py（~500 行）  只留：StudioServer / 路由表 / do_* 分发 / _json/_error/_resolve_image_path / 日志初始化
studio/handlers/      按域一个文件（模块级函数或 mixin）：
 ├── scan.py           /api/scan + /api/tags 读取
 ├── quality.py        /api/quality* + /api/quality/batch/cancel （规划：现状实际为 /api/quality/cancel）
 ├── export.py         /api/export + /api/export/preview + /api/job/status
 ├── image.py          /api/thumb + /api/file + /api/crop/manual + /api/delete
 └── misc.py           /api/health + /api/taxonomy + /api/exported
studio/jobs.py（或 core/）  JobStore + 质检 worker 独立模块
```

---

## 四、分阶段实施计划（成本低 → 高）

| 阶段 | 内容 | 成本 | 风险 | 验证 | 收益 |
|---|---|---|---|---|---|
| **P1** | 后端 `server.py` 瘦身：路由表化 + handler 按域拆到 `handlers/` + JobStore/worker 独立 | 低 | 极低（纯搬移；handler 间无共享可变状态，靠 `current_root_dir` 类变量 + 每次开 `CacheDB`） | `python -m unittest studio.test_studio`（51 项）+ curl 冒烟 | server.py 1790 → ~500，加 API 只动一处 |
| **P2** | 前端引入 Vite，现有 app.js/index.html/css **原样**跑通（不拆逻辑） | 中低 | 低（纯工具链迁移，行为不变） | test_frontend.py + Playwright/手动冒烟 | 获得 SFC 编译能力 + HMR；后续拆组件的地基 |
| **P3** | 按 §3.1 拆 5 个 Pinia store；先拆边界清晰的组件（ConfirmDialog、ViewerModal——删除功能所在切片做试点） | 中 | 中（跨 store 引用关系要先画清楚；参考架构文档 §3 状态模型） | 每拆一块跑一次 test_frontend + 实机点一遍关键路径 | 前端最大维护性提升；ConfirmDialog 复用根治弹窗复制 |
| **P4**（可选） | AppShell/ExportWorkbench 剩余大组件化；后端若未来确有文档/校验需求再评估 FastAPI | 高 | 高 | — | 收益递减，可永久不做 |

**建议甜点区：P1 + P2 + P3。** P4 留给未来有真实需求时再议。

---

## 五、明确不做的事（防方案漂移）

1. 不重写 `core/` 与 `exporters/` —— 分层已正确，动了才是真重写。
2. 前端暂不引入 TS —— 与 SFC 化正交，可后置为独立决策。
3. 后端不因"能上框架了"而上框架 —— 具体场景不支持（见 §2.2）。
4. 不引入 vue-router —— 单页应用无多路由需求。
5. 不在 P1-P3 期间顺手改业务逻辑 —— 重构与功能变更严格分离。

---

## 六、风险与对策

| 风险 | 对策 |
|---|---|
| 前端状态引用关系复杂，拆 store 漏改导致静默错误 | 先画状态依赖图；按"一个功能一个切片"粒度拆分；每片拆完即跑 test_frontend + 实机验证（对齐 lessons-learned 的 checklist） |
| setup() return 漏绑不报错（历史教训） | P2 引入 SFC 后逐步以模板引用为准，拆一块验一块；保留 test_frontend CDP 挂载诊断 |
| Vite 引入初期构建/依赖问题 | P2 阶段"原样迁移"先行，构建绿了再动结构；构建链问题与逻辑问题隔离排查 |
| 大搬移引入回归 | 纯搬移阶段用 git diff --stat + 行为测试兜底；handler 签名不动，只换文件位置 |

---

## 七、待拍板事项

- [ ] P1（后端拆分）是否开始？先从 scan handler 一个文件做样板
- [ ] P2（Vite 引入）时机：P1 完成后 / 与 P1 并行？
- [ ] P3 的 store 边界按 §3.1 五切分是否认可？ViewerModal 切片是否作为首个试点
- [ ] P4 明确为"不做"还是"保留观察"

---

## 八、参考文档

- `studio/docs/studio-server-architecture-and-api-20260908.md`（现状全览）
- `studio/docs/studio-webui-architecture-and-api-20260908.md`（现状全览）
- `studio/docs/studio-lessons-learned-20260908.md`（历史教训，本规划的 checklist 来源）
