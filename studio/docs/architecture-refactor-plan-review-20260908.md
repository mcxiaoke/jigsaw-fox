# Content Studio 架构重构规划 · 评审意见

> 被评审文档：`studio/docs/architecture-refactor-plan-20260908.md`
> 评审时间：2026-09-08 22:34 (GMT+8)
> 评审方式：文档全部量化声明逐条对源码/测试实测核对
> 结论：**方向判断正确，可以推进；但存在 1 项阻塞、1 项未拍板的关键决策、多处基线数据偏差。建议按第九节顺序逐项拍板后再动工。**

---

## 零、结论摘要

被评审文档的**核心诊断是站得住的**——"分层不缺，缺的是两个编排壳（后端 `server.py`、前端 `app.js` 的 `setup()`）的收口"，这个判断与源码实况一致，且 `core/` 与 `exporters/` 确实已经分层健康，不动它们是对的。"渐进式、不重写"的总基调也正确。

但作为一份"等待逐项拍板"的方案，它有三个必须先补的洞：

1. **阻塞**：它准备拿来当每步回归闸门的自动化测试，现在本身就是红的（6 项失败，含前端挂载测试）。闸门不修，P2/P3 的"拆一块验一块"是空话。
2. **未拍板**：P1 里"模块级函数 **或** mixin"这个决定工作量差一个量级的选择，被含糊带过。
3. **数据偏差**：基线表多处不准，会连带污染成本估算。

---

## 一、核实基线：文档数据 vs 实测

| 项 | 文档声明 | 实测 | 判定 |
|---|---|---|---|
| `server.py` | 1790 行 | 1790 行 | 准确 |
| `core/`（9 模块） | 3629 行 | **4112 行**（9 个功能模块 4110 + `__init__.py` 2） | 低估 ~480 行 |
| `exporters/` | 1957 行 | 1966 行 | 基本准确 |
| 前端 `app.js` / `index.html` / `studio.css` | 2228 / 1102 / 1420 | 2228 / 1102 / 1420 | 准确 |
| 业务 handler | "30 个" | **19 个** `_handle_*` 方法 | 高估，影响"30 handler 改写"成本估算 |
| API 端点 | "15 API" | **20 个路由分支** | 低估 |
| 测试 | "51 项"（隐含绿） | **42 项，其中 6 项失败** | 数量与状态均不准 |

### API 端点实测明细（20 个路由分支）

- **GET（12）**：`/api/health`、`/api/taxonomy`、`/api/scan`、`/api/tags`、`/api/exported`、`/api/export/status`（与 `/api/job/status` 共用分支）、`/api/thumb`、`/api/file`、`/api/quality`、`/api/quality/stats`、`/api/quality/scores`、`/api/crop/manual`
- **POST（7）**：`/api/tags`、`/api/export`、`/api/export/preview`、`/api/quality/batch`、`/api/quality/cancel`、`/api/crop/manual`、`/api/delete`
- **DELETE（1）**：`/api/crop/manual`

> 注：单图删除走的是 **POST `/api/delete`**，不是 DELETE 方法；DELETE 仅用于删除手动裁切框。

---

## 二、阻塞项：验证基线是红的

被评审文档 P1 的验证手段写的是 `python -m unittest studio.test_studio（51 项）`，P2/P3 写的是"每拆一块跑一次 test_frontend"。实测结果：

```
Ran 42 tests in 14.381s
FAILED (failures=6)
```

6 项失败明细：

| 测试 | 归属 | 性质 |
|---|---|---|
| `test_find_duplicate_groups` | TestDuplicateHandling | 重复图检测，`2 != 3` |
| `test_duplicate_tag_inheritance` | TestDuplicateHandling | 重复图检测 |
| `test_exporter_rejects_duplicate_images` | TestDuplicateHandling | 重复图检测 |
| `test_daily_exporter_rejects_duplicate_images` | TestDuplicateHandling | 重复图检测 |
| `test_server_duplicate_scan_api` | TestDuplicateHandling | 重复图检测，`0 != 1` |
| **`test_page_headless_mount`** | **test_frontend** | **"Vue 应用未成功挂载，页面残留 v-cloak（白屏）"** |

**为什么这是阻塞项**：最后一条正是文档准备用作 P2/P3 每步回归门禁的前端挂载测试。门禁本身是红的，整轮重构就失去唯一的自动化前端校验手段，"拆一块验一块"无法落地。

**建议**：新增 **P0 阶段**——先修红，再谈重构。其中 5 项 `TestDuplicateHandling` 集中在重复图检测，看起来是独立的业务 bug 或过期测试，按原文档 §五"重构与功能变更严格分离"的原则，建议**单独立项排查**，不要混进 P1-P3 顺手改。

---

## 三、P1 风险论证存在自相矛盾

被评审文档给 P1 打"极低风险"，理由原文是：

> 纯搬移；handler 间无共享可变状态，靠 `current_root_dir` 类变量 + 每次开 `CacheDB`

这句话本身是矛盾的——**`current_root_dir` 恰恰就是跨请求共享的可变全局状态**：

- `server.py:367` 定义为类变量 `current_root_dir: Path | None = None`
- 全文件 **12 处以上** 引用（`server.py:582` 处赋值，790/902/945/959/979/1002/1065/1201 等处读取）
- 服务是 `ThreadingHTTPServer`（`server.py:1667`），多线程并发下该变量全局可见

此外还有模块级全局：`_JOBS` 字典 + `_JOB_LOCK`（`server.py:169-171`）。

**结论不变，理由要换**：P1 确实低风险、值得立刻做，但正确的理由是——**这些共享状态已存在且工作正常，纯搬移只要不改变语义就不会引入新增风险**；而不是"没有共享状态"。按原文理由实施，会低估 19 个 handler 对 `self` 的依赖改造量。

---

## 四、P1 未拍板的关键决策：mixin vs 模块级函数

19 个 handler 全部是实例方法，深度依赖 `self`：

- `self._json(...)` / `self._error(...)`（`server.py:400` / `409`）
- `self._resolve_image_path(...)`（`server.py:761`）
- `self.current_root_dir` / `StudioRequestHandler.current_root_dir`
- `self.send_response` / `self.send_error` / `self._serve_static_file`

被评审文档 §3.2 写的是"按域一个文件（**模块级函数或 mixin**）"——这两个选项的工作量差一个量级：

| 方案 | 改造量 | 效果 |
|---|---|---|
| **mixin** | 极小，`self` 全部保留，近乎物理搬运 | 达成降体量目标；但不是"架构纯化" |
| **模块级函数** | 大，所有 `self.*` 调用需重新接线 | 更"纯"，但 P1 阶段收益不成比例 |

**建议选 mixin。** P1 的目标是让 `server.py` 从 1790 行降到 ~500 行、让加 API 只动一处，不是做架构纯化。mixin 用最小代价拿到全部收益。此项必须在动工前拍板。

---

## 五、P2 被低估：不是"原样迁移、行为不变"

被评审文档将 P2 描述为"纯工具链迁移，行为不变，风险低"。实测有两点未纳入：

1. **Vue 获取路径会被迫改变**：`app.js` 是 `type="module"` 的 ESM（`index.html:1100`），但 Vue 走的是全局变量 `window.Vue`（`app.js:27`：`const { createApp, ref, computed, ... } = window.Vue;`）。Vite 化必须改成 `import { createApp } from 'vue'`，这已经不是"行为不变"。
2. **存在 CDN 外部依赖**：`index.html:58` 从 `cdnjs.cloudflare.com` 加载 cropperjs。离线/内网环境会直接挂。被评审文档 §六 风险表完全没有这一条。

**建议**：P2 顺手把 cropperjs 本地化到 `static/vendor/`（该目录已有 `vue.global.prod.js`、`Sortable.min.js` 先例），消除外部依赖。

---

## 六、P3 的核心建议：不要现在预设 5 个 store

这是本次评审**最主要的一条建议**。

被评审文档 §3.1 自上而下预设了 5 个 Pinia store（`useConfig` / `useRecords` / `useQuality` / `useViewer` / `useExport`），并在第七节问"五切分是否认可"。

问题在于：**store 的真实边界是在组件抽取过程中浮现出来的，不是事前设计出来的。** 现在锁死五切分，大概率在拆到一半时发现与实际的共享状态对不上，回头返工——而这块正是 2228 行"经过多轮 bug 淬炼"的逻辑，返工成本最高。

**建议把 P3 劈成两段**：

- **P3a · SFC 组件化**：只搬模板与视图逻辑，**状态语义一律不动**
- **P3b · Pinia store 切分**：等共享状态在组件间自然浮现后，再按需抽取

这样每一步都可独立验证，也避免"先设计边界、后发现错了"的二次返工。

---

## 七、P3a 的组件拆解顺序：按状态耦合度递增

被评审文档把 `ConfirmDialog` 与 `ViewerModal` 并列作为试点，但两者风险差很远——`ViewerModal` 是删除功能所在切片，承载 `viewerIndex` / `cropMode` / 删除动作，是状态最重的一块。

**建议顺序**：

```
ConfirmDialog / ToastMsg   ← 纯展示，无状态语义，风险最低
        ↓
ViewerModal                ← 状态最重（viewerIndex / cropMode / 删除）
        ↓
ExportWorkbench            ← 三步会话状态
        ↓
AppShell                   ← 牵连最广，最后做
```

先用纯展示组件验证 Vite + SFC 工具链跑通（近乎零风险），再逐步啃状态重的部分。拿 `ViewerModal` 开局等于一上来同时处理组件边界和 store 边界，正好踩进 P3b 的坑。

---

## 八、其余建议

1. **P4 建议直接标"不做"，不要"保留观察"**——留观察项等于给方案漂移留口子；真有需求时重新评估即可，成本并不更高。
2. **5 个 `TestDuplicateHandling` 失败单独立项**，不并入 P1-P3（见第二节）。
3. **修订后的阶段表**：

| 阶段 | 内容 | 风险 | 建议 |
|---|---|---|---|
| **P0**（新增） | 修复 6 个红测，重点让 `test_page_headless_mount` 变绿 | 低但**阻塞** | 必须先做 |
| **P1** | 后端 handlers 按域拆到 `handlers/`（**mixin**），JobStore/worker 独立 | 低 | 立刻做 |
| **P2** | 引入 Vite，顺手本地化 cropperjs CDN 依赖 | 中 | 做 |
| **P3a** | SFC 组件化，按第七节顺序，不动状态语义 | 中 | 做 |
| **P3b** | Pinia store 切分，边界浮现后再定，**现在不锁五切分** | 高 | 后置 |
| ~~P4~~ | 剩余大组件化 / 后端换 FastAPI | 高 | **不做** |

---

## 九、待拍板清单

| # | 事项 | 建议 |
|---|---|---|
| 1 | P0 是否先行（修 6 个红测，`test_page_headless_mount` 优先） | **是，阻塞项** |
| 2 | P1 用 mixin 还是模块级函数 | **mixin** |
| 3 | P1 风险理由是否按第三节改写 | **改，原文自相矛盾** |
| 4 | P2 是否顺带把 cropperjs 从 CDN 本地化 | **是** |
| 5 | P3 是否改为 P3a + P3b 两段，且现在不锁五切分 | **是** |
| 6 | P4 明确标"不做"而非"保留观察" | **是** |
| 7 | 5 个重复图检测失败是否单独立项 | **是** |

---

## 十、附录：核实命令

```bash
cd C:/Home/Projects/jigsawpuzzle/studio

# 行数基线
wc -l server.py core/*.py exporters/*.py \
      static/js/*.js static/index.html static/css/*.css

# handler 清单（实测 19 个）
grep -nE "^    def " server.py

# 共享可变状态
grep -nE "current_root_dir|^_JOBS|^_JOB_LOCK|ThreadingHTTPServer" server.py

# 前端装配方式
grep -nE "^import |window\.Vue|createApp" static/js/app.js
grep -nE "script src|v-cloak" static/index.html

# 测试基线（实测 42 项 / 6 失败）
cd C:/Home/Projects/jigsawpuzzle
python -m unittest studio.test_studio -v
```

---

## 十一、参考文档

- `studio/docs/architecture-refactor-plan-20260908.md`（被评审文档）
- `studio/docs/studio-server-architecture-and-api-20260908.md`
- `studio/docs/studio-webui-architecture-and-api-20260908.md`
- `studio/docs/studio-lessons-learned-20260908.md`
