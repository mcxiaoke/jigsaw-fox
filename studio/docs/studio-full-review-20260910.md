# Studio 全面代码审查报告（数据与工作流 / UIUX）

- 审查日期：2026-09-10 08:31 (GMT+8)
- 审查范围：`studio/` 全部生产代码 —— `server.py` (1900) + `core/` (4400) + `exporters/` (2100) + `taxonomy.py` (658) + `static/` (前端 4900)，合计约 14,000 行（不含 6 个测试文件）
- 审查方式：三路并行逐行审查（数据层 / 导出流水线 / 前端 UIUX）+ 主流程 `server.py` 全量精读 + 关键指控源码复核
- **本次为只读审查，未改动任何代码，故不计入 `CHANGES-YYYYMMDD.md`**

---

## 一、结论摘要

**总体判断：工程质量中上，架构决策（内容哈希追踪、权威账本、原子写、软删除回收站、环境 fail-fast）明显优于同类内部工具；但存在 3 类结构性缺口。**

| 类别 | 数量 | 核心判断 |
|---|---|---|
| P0 数据/流程阻断 | **4** | 导出可并发、导出不可取消、回滚非原子、断连后 UI 不可恢复 |
| P1 明显缺陷 | **16** | 集中在"能力没接进工作流""同名覆盖""口径错配""并发无锁" |
| P2 改进项 | **18** | 多为降级路径、清理、性能与视觉一致性 |

**三句话结论：**

1. **最严重的是"并发 + 不可取消"**：导出走同步请求线程且无任何互斥，两个人（或两个标签页）同时点导出会写坏 release 与账本；一旦开始只能等它跑完，Ctrl+C 强杀会留下半截产物。
2. **最讽刺的是"回滚做了但用不了"**：`core/export_rollback.py` 601 行 + 完整测试，但 `server.py` 无一条 `/api/rollback`、`/api/ledger` 路由，运营误导出后**无法自助撤销**，只能手工改 `.studio/ledger/exports.json`。这是工作流上最大的断点。
3. **前端"功能全但边缘态薄"**：XSS 防护到位、按钮禁用到位；但断连、超大数据量、0 选中、无进度条这几处会让人卡死或误判。

---

## 二、影响数据与工作流的严重问题

### P0

**【1】导出无并发互斥 —— 可同时跑多个导出，竞态写坏 release 与账本** ✅ 已修复
- 位置：`server.py:1410 _handle_export`（全程无任何 running 检查）对比 `server.py:1306-1314` 质检有 409 拦截
- 问题：质检做了并发拦截，导出没有。两个导出任务会同时写同一 `release/index.json`、同一 `main/batches/{id}/images/`、同一 `exports.json`。
- 后果：账本记录互相覆盖（last-writer-wins）、`order` 分配撞号、zip 与 manifest 不匹配；且不会报错。
- 建议：导出入口加与质检同款的全局 running 锁（返回 409），锁粒度为「源目录 + 输出目录」。

**【2】导出不可取消，且同步阻塞在请求线程内**
- 位置：`server.py:1410-1533`（无 cancel 检查点）；`_job_cancel` 仅在 `server.py:1339` 被 `/api/quality/cancel` 调用；无 `/api/export/cancel` 路由
- 问题：导出在 HTTP 工作线程里同步跑完，`_job_is_cancelled` 从未在导出路径被调用；无优雅关闭（`server.py:1847-1852` 仅 `serve_forever` + `KeyboardInterrupt`）。
- 后果：误发一个 5000 张的导出无法中止，只能杀进程；强杀时 release 已写了一部分、账本未写 → 半状态产物 + 账本与镜像不一致，且无自愈。
- 建议：导出改后台 worker + 子批间检查取消标记；新增 `/api/export/cancel`；注册 `atexit`/signal 做优雅停止。

**【3】回滚非原子，部分失败仍返回 `ok: True`〔已复核〕**
- 位置：`core/export_rollback.py:369-389`，先 `ledger.rollback_operation()` 落盘，再逐模块 `_cleanup_release_for_module()`；任一模块失败即 `return {"ok": True, ...}`，剩余模块不再处理
- 问题：账本先撤销、镜像后回退，两步非原子；镜像回退失败时既不停也不报错。
- 后果：账本说"已撤销"但 release 里旧条目/文件还在（或只删一半），app 端拿到脏数据，且本次操作无法自愈。
- 建议：改为「快照 → 回退全部镜像 → 成功后才回滚账本」；任一步失败即整体失败并还原快照，禁止半成功。

**【4】导出轮询断连后"重新连接"按钮被日志门控隐藏，早期断网无法恢复** ✅ 已修复
- 位置：`static/index.html:814`（`v-if="exportLogs.length > 0 && ..."` 包裹了 reconnect 按钮）；质检侧的同类按钮 `index.html:312` 无此门控
- 问题：轮询在开始阶段（还没收到第一条 log）就连续失败被判死时，`exportPollLost=true` 但按钮不可见。
- 后果：用户看到按钮永远停在"正在导出 (n/total)"，既不能重连也不能取消，只能关弹窗盲等。
- 建议：reconnect 按钮移出 `exportLogs` 门控，改为 `isExporting && exportPollLost` 时独立显示。

### P1

**【5】回滚/台账能力完全没有 HTTP 接口 —— 601 行代码进不了工作流〔已复核〕**
- 位置：`server.py:468-594` 全部 GET/POST/DELETE 路由中，无任何 `ledger` / `rollback` / `cache` 相关端点；`core/export_rollback.py`（601 行）与 `test_rollback.py`（17KB）零引用入口
- 问题：撤销能力只存在于 Python 模块与测试里，前端无任何入口。
- 后果：正式导出出错后，运营**无法自助恢复**，只能手工编辑 `.studio/ledger/exports.json`（有损坏风险）或找人跑脚本。同时这也是高危能力的失控面：没有界面就没有确认、没有审计。
- 建议：补 `GET /api/ledger`（台账查看/筛选）+ `POST /api/rollback`（二次确认 + 影响条数 + 可逆说明 + 操作留痕）。这是本轮最高性价比的补齐项。

**【6】`record_exports` 静默吞掉权威账本写入失败〔已复核〕** ✅ 已修复（随 exported.json 兼容层一并移除）
- 位置：`core/export_tracker.py:184-188` `try: ... append_records(...) except Exception: pass`，随后 `:194-196` 仍更新 legacy `exported.json`
- 问题：权威账本写异常被吞；legacy 账本照写。二者主次关系见 `export_tracker.py:36-68`（权威优先）。
- 后果：权威账本停在旧状态、legacy 已更新 → 下次 `load_exported_ledger` 走权威（旧），"已导出"判据失效，重复导出拦截形同虚设。
- 建议：不要吞异常；写权威失败即整体失败并回滚 legacy，至少上报告警到 UI 日志。

**【7】实例级锁 + 每请求新建实例 = 跨请求零互斥〔已复核〕**
- 位置：`core/cache_db.py:37` `self._lock = threading.Lock()`；`server.py:635 / 968 / 1013 / 1047 / 1234 / 1476` 全部是 `with CacheDB(root) as db:`（每请求新实例）
- 问题：锁绑在实例上，每个 HTTP 请求一个新实例，锁形同虚设；`ExportsLedger`、`workspace.py:31` 同款。
- 后果：并发打标/导出时账本记录丢失、用户覆盖字段互相覆盖（见【8】）。与【1】叠加放大。
- 建议：改为按 `root` 路径的模块级共享锁（或单例连接 + 同锁）。

**【8】`set_user_override` 读-改-写跨临界区，丢失更新**
- 位置：`core/cache_db.py:543` 读旧值 → 释放锁 → `:570-588` 再加锁写
- 后果：并发下"设裁切框"与"设标签"互相覆盖；用户的手动裁切框静默丢失。
- 建议：读-合并-写整体放进同一 `with self._lock`，或改用 `COALESCE(excluded.x, x)` 式合并写入。

**【9】手动裁切框只存于 `synchronous=NORMAL` 的 SQLite，且不进 tags.json**
- 位置：`core/cache_db.py:50-51`；`tags_manager.py:544-600` 仅持久化 tags/subject/scene
- 后果：异常关机可丢最后一次提交；素材目录被移动/重建后裁切框全丢，且无可恢复副本（评分同理，但评分可重算，裁切框不可）。
- 建议：对该表用 `synchronous=FULL`，或把裁切框一并写入 tags.json。

**【10】任意本地文件可被读取 + CORS 全开〔已复核〕** 🟡 部分修复（路径已限制在 root 内；CORS 收紧未做）
- 位置：`server.py:817-857 _resolve_image_path`（绝对路径只要 `exists()` 就放行，无 root 边界）；`:1395 _handle_file` 直接 `read_bytes` 返回；`:443-446 _cors()` 返回 `Access-Control-Allow-Origin: *` 且 `do_OPTIONS` 放行全部方法
- 后果：任意本地网页可对 `127.0.0.1:5188` 发起跨域请求 → 读取本机任意文件、触发 `/api/delete` 软删素材、触发导出。单机使用场景风险有限，但属真实的信息泄露面。
- 建议：`_resolve_image_path` 强制限制在 `current_root_dir` 内；CORS 改为仅允许 `http://127.0.0.1:5188` / `null`；写操作加简单 token 校验。

**【11】扫描接口全量返回 records，无分页**
- 位置：`server.py:803-815`（`records` 为全量数组）
- 后果：2.5 万张素材时单次响应数十 MB，前端解析 + Vue 响应式代理卡顿；前端虽做了分页（默认 500），但传输与解析成本已经付了。
- 建议：接口支持 `?offset&limit` 或改为只回 hash/path 的瘦列表 + 按需拉详情。

**【12】同名文件在"保持原名"路径下静默覆盖 → 交付丢图〔已复核，触发条件已收窄〕**
- 位置：`core/image_proc.py:379-412 make_rename`（`rule == 'none'` 时输出名 = 原 stem）；调用点 `main_exporter.py:343`、`daily_exporter.py:138-143`、`pack_exporter_base.py:268`
- 触发条件：① 前端把重命名选为"保持原名"（`index.html:541` 可选，默认 `sequence` 安全）；② **daily 导出时文件名匹配 `^\d{8}\.` 会强制保留原名**（`daily_exporter.py:138`）—— 日历类素材普遍是 `20260901.jpg` 命名，此路径默认生效。
- 后果：不同子目录下的同名文件在 zip/输出目录内重名，后者覆盖前者，**交付包永久少一张图**，manifest 仍列两条指向同一文件，按内容哈希去重查不出来。
- 建议：输出前对 `arc_name` 做全局唯一性校验，冲突时追加短 hash 或保留相对路径，冲突即 fail-fast 而非覆盖。

**【13】规格化只缩不放，裁剪后输出长边可能不达标**
- 位置：`core/crop_compute.py:546-559 resize_long`（`if long_side <= long_target: return img`）；调用点 `image_proc.py:339`
- 问题：`assert_min_long` 只校验**源**图长边，主体被裁小后不再放大。
- 后果：产出的图远小于目标长边（如主体仅 800px），客户端拿到低清图，与"长边固定"契约不符。
- 建议：裁剪后长边显著小于目标时至少 warn 并在 UI 明示；或约定"内容过小则整图缩放"。

**【14】LA / 调色板 P 模式的 alpha 在转码时丢失**
- 位置：`core/image_proc.py:219-221`（webp）、`:223/227`（jpeg）、`:343-354`（normalize）
- 问题：`LA`、`P` 模式既非 `RGB` 也非 `RGBA`，直接 `convert("RGB")` 丢弃透明通道。
- 后果：带透明的灰度/索引色图转成不透明，边缘黑块。
- 建议：先统一 `convert("RGBA")`，再按目标格式合成白底（jpeg）或保留 alpha（webp）。

**【15】质检并发拦截误伤导出，且文案与事实不符〔已复核〕** ✅ 已修复（改为按任务类型前缀互斥）
- 位置：`server.py:1306-1314`（遍历 `_JOBS` 中所有 `state == running`，而导出任务也会注册进 `_JOBS`）
- 后果：导出进行中启动质检，被拒且提示"质检任务正在进行中: <导出任务ID>"，用户困惑。
- 建议：拦截时按任务类型区分，文案回传真实类型。

**【16】`DEFAULT_LONG_TARGET` 1920 与契约注释 2160 错配** ✅ 已修复（注释统一为 1920）
- 位置：`core/image_proc.py:54`、`exporters/base.py:38` 注释、`core/crop_compute.py:549` 注释；`base.py:50` 实际取值 1920
- 后果：前端未显式下发 `longTarget` 时门限为 1920，与"≥2160 才放行"的既定需求背离。
- 建议：统一常量与注释，并明确前端是否必须下发。

---

## 三、UI/UX 改进清单（按性价比排序）

| # | 改进项 | 位置 | 收益 | 成本 |
|---|---|---|---|---|
| U1 | 分页去掉/限流"全部"选项（改上限 5000 并提示） | `index.html:357-362`、`app.js:143-153` | 避免 2.5 万卡片 + 2.5 万缩略图请求冻结页面 | 1 行 |
| U2 | 导出 reconnect 移出日志门控 | `index.html:814` | 恢复断连场景可操作性 | 小 |
| U3 | 加导出百分比进度条 + 独立"收尾/部署中"状态 | `app.js:2162-2164`、`index.html:285-287` | 消除"卡在 100%"误判（以 `state` 而非计数判定完成） | 中 |
| U4 | 0 选中时禁用头部"导出资产"+ 第①步即警示 | `index.html:117`、`app.js:1747-1762` | 少走 2 步冤枉路 | 1 行 |
| U5 | 补台账查看面板 + 受控回滚入口（见 P1-【5】） | 全新增 | 闭环宣称工作流，给不可逆操作兜底 | 中 |
| U6 | 批量标签覆盖/重置统一二次确认 + 最近一次可撤销 | `app.js:1321/1370/1397`（当前仅 >20 张才确认） | 降低误操作损失 | 小 |
| U7 | 前端主动拦截重复图导出（不裸依赖后端） | `app.js:294-310` vs `2236` | 后端兜底失效时不静默误导出 | 小 |
| U8 | 预览 payload 仅传选中子集并缓存 | `app.js:391-399`、`460-487` | 大库切步不再全量序列化 2.5 万条 | 中 |
| U9 | 导出顺序网格虚拟滚动 / 分组折叠 | `app.js:1968-1986`、`studio.css:1352` | 上千张拖拽不再卡顿 | 中 |
| U10 | 浅色主题暗块修正 | `studio.css:481`（缩略图 letterbox `#0f172a`）、`:692`（查看器 `#3a3a3a`） | 视觉一致性（查看器深色可保留，网格 letterbox 应改浅灰） | 1 行 |
| U11 | 折叠导出向导为单屏主按钮 + "一键导出（当前筛选+默认配置）" | 导出流程 ①→②→③ | 典型导出从 8-10 步压到 4-5 步 | 中 |
| U12 | 清理死代码（`mainTagsRow1/2`、`restartExport`、`catalogs/specificTags` 等未被模板引用） | `app.js:54-55/1769/2316` | 可维护性 | 小 |
| U13 | 拆分 2580 行 `setup()` 为 composables（扫描/质检/导出/查看器/裁切） | `app.js:29-2567` | 长期可维护性 | 大 |
| U14 | 批量质检中禁用单张质检按钮 | `app.js:910-929` vs `1034`（两套 flag） | 消除状态冲突 | 小 |
| U15 | Daily 超月天数改为明确"将截断、日历缺天" | `app.js:2049-2051`（现仅 toast "多余不分配"） | 避免误以为整月完整 | 1 行 |
| U16 | 错误文案脱敏（不直出 `e.message`/路径） | `app.js:481/2050` | 面向运营的友好度 | 小 |
| U17 | a11y：模态 focus-trap + `aria-*`，补充快捷键说明 | 全局 | 键盘可达性 | 中 |

**核心工作流步数实测：** 填源目录 → 扫描 → 筛选勾选 → 点导出 → ①选类型确认配置 → ②排序 → ③填输出目录+选正式 → 二次确认 → 执行 → 关闭 = **约 8-10 步含 2 次确认**。可合并项：输出目录已 localStorage 记忆可省；①②③ 对多数用户是默认配置，U11 可压缩掉 4 步。

---

## 四、P2 速览（不展开）

- `core/exports_ledger.py:438-441` 事件流与 JSON 落盘非原子，崩溃后事件流成为影子
- `core/exports_ledger.py:306-309` superseded（已修订）记录仍计入"已导出"集合
- `core/export_rollback.py:193/254` `lstrip("/")` 未规范化 `..`，存在越界删除风险
- `core/export_rollback.py:473-492` JSON 保存失败时回滚事件已写入影子流
- `core/scanner.py:144-147` 文件在读-哈希间隙消失 → 静默得空 hash
- `core/tags_manager.py:245` `relative_to` 遇符号链接抛错中断整批；`:281-302` 原地修改入参
- `core/tags_manager.py:544-600` `save_tags_file` 依赖调用方传全量，局部保存会抹掉其他手动标签
- `core/quality_evaluator.py:31` `VENV_PYTHON` 硬编码 `C:\Home\Develop\venv\...`（与 `server.py:1758` 的 fail-fast 设计相矛盾，属残留）
- `core/quality_evaluator.py:335-341` `cv2.kmeans` 用 `KMEANS_RANDOM_CENTERS`，同图多次评估调色板抖动
- `core/image_proc.py:576-601` 无 `MAX_IMAGE_PIXELS` 保护，超大图全量解码
- `core/image_proc.py:101-105` 缓存键含绝对路径，移动素材目录后缓存全失效
- `exporters/daily_exporter.py:296-310`、`pack_exporter_base.py:311-326` 转码失败时临时文件未清理
- `exporters/daily_exporter.py:292-403` release 先落盘、账本后写 → 重试时版本号膨胀 + 孤儿 zip
- `exporters/main_exporter.py:249-264` patch 模式未强制 `startOrder` → 退化为追加而非修订
- `exporters/*` zip 装配单线程且期间无进度上报
- `server.py:84` 日志文件名在 import 时固定，跨天不切换、无大小轮转
- `server.py:415` `current_root_dir` 为类级全局，多标签/多目录场景串扰
- `server.py:1493-1494` 手动裁切框查询失败被静默忽略，导出退回自动裁剪且不提示
- `server.py:1522` 导出异常只回传 traceback 最后一行
- `server.py:1723` 静态/原图整文件读入内存，无 Range 支持
- `studio/studio.db` 0 字节残留文件

---

## 五、决策清单（请按编号拍板）

| 编号 | 事项 | 建议 | 我的判断 | 状态 |
|---|---|---|---|---|
| **1** | 导出加全局互斥锁（409 拒绝并发） | 做 | 必做，成本极低，风险最高 | ✅ 已完成 |
| **2** | 导出改后台 worker + 支持取消 + 优雅停止 | 做 | 必做，但改动面中等，可拆两步 | ⬜ **下一步正式立项** |
| **3** | 补 `/api/ledger` + `/api/rollback` 及前端台账面板 | 做 | 必做，当前能力完全浪费 | ⬜ 待定 |
| **4** | 修 `undo_op` 原子性（先镜像后账本，失败即还原） | 做 | 必做，否则回滚不敢用 | ⬜ 待定 |
| **5** | `record_exports` 不再吞异常 | 做 | 必做，一行改动 | ✅ 已完成（随 6 一并落地） |
| **6** | 整体移除 exported.json 支持 | 做 | 无旧数据源，可放心移除 | ✅ 已完成 |
| **7** | 输出名唯一性校验（修 daily 日期名覆盖） | 做 | 会静默丢图，必须堵 | ⬜ 待定 |
| **8** | 路径解析限制在 root 内 + CORS 收紧 | 做 | 低成本安全加固 | 🟡 已完成一半（root 限制已做，CORS 未动） |
| **9** | resize 不放大 / alpha 丢失 / 1920 vs 2160 | 先确认契约再改 | 需你定门限 | 🟡 注释部分已完成，其余待定 |
| **10** | U1/U2/U4/U10 四个一行级前端修复 | 做 | 性价比最高 | 🟡 U2（reconnect）已完成，其余待定 |
| **11** | U3 导出进度条 + 收尾态 | 做 | 与 2 一起做效果最好 | ⬜ 待定 |
| **12** | U5 台账 UI（同 3） | 同上 | — | ⬜ 待定 |
| **13** | U11 导出向导折叠 + 一键导出 | 待定 | 需你判断是否接受向导简化 | ⬜ 待定 |
| **14** | U13 拆分 2580 行 `setup()` | 暂缓 | 大重构，建议单独立项 | ⬜ 暂缓 |
| **15** | 任务类型前缀 + 同类互斥 | 做 | 低成本，消除误伤 | ✅ 已完成 |
| **16** | 长边门限注释修正为 1920 | 做 | 你已确认真值为 1920 | ✅ 已完成 |
| **17** | 单次导出数量上限（100 张） | 做 | 游戏侧单次更新量硬约束 | ✅ 已完成（见第七节） |

**需要你先回答的一个问题：** 长边门限到底是 1920 还是 2160？（`image_proc.py:54` 是 1920，多处注释与 `base.py:38` 写 2160）—— 这决定第 9 项怎么改。

---

## 六、执行记录（2026-09-10 09:16）

已按用户拍板执行决策清单中的 **1 / 4 / 6 / 10 / 15 / 16** 六项，并回答了上面的问题（长边门限 = 1920，注释过时）。

| 决策号 | 事项 | 状态 | 主要落点 |
|---|---|---|---|
| 1 | 导出并发互斥 | ✅ | `server.py`：`_job_register` 改为原子注册（锁内完成检查+写入）并返回是否被拒；`/api/export` 入口 409；补匿名 taskId 防绕过；`finally` + `_job_ensure_finished` 防锁死；质检 worker 异常收口 |
| 4 | 导出 reconnect 按钮 | ✅ | `static/index.html`：按钮移出 `.export-result` 日志门控容器 |
| 6 | 移除 exported.json | ✅ | `core/export_tracker.py` 重写为纯权威账本视图层；`core/exports_ledger.py` 删 `_try_migrate_legacy`；`server.py` 删 `/api/exported`；README 同步 |
| 10 | 路径限制在 root 内 | ✅ | `server.py:_resolve_image_path` 增加允许根集合，允许根为空时一律拒绝 |
| 15 | 任务类型前缀 | ✅ | 前端 `qc_`/`exp_` → `quality_`/`export_`；后端 `_job_kind_of` + `_job_kind_label`；`/api/job/status` 返回 `kind` |
| 16 | 长边门限注释 | ✅ | 5 处 2160 → 1920 |
| 17 | 单次导出数量上限 100 张 | ✅ | `base.py` 常量 + `assert_max_images`；main/daily/pack 三处校验；`GET /api/export/limits` 下发；前端预览提示 + 按钮禁用；`ValueError` → HTTP 400（详见第七节） |

**回归**：90 项测试全绿；临时脚本 `temp/verify_studio_fixes.py` 17 项全通过（含 20 线程并发注册恰好 1 成功、越界路径 404、允许根内 200、异类任务不互斥）。变更摘要见 `studio/docs/CHANGES-20260910.md`。

**遗留提示**：移除 exported.json 后，若某源目录只有 `exported.json` 而没有 `.studio/ledger/exports.json`，其历史已导出记录将不再被识别。—— ✅ 用户已确认当前全部为测试数据源、无旧数据，风险解除。

---

## 七、单次导出数量上限（100 张）方案

### 约束来源
游戏侧一次内容更新（`main` / `event` / `collection` / `daily`）的绝对量不应过大，因此在 Studio 侧设硬上限，**一次导出最多 100 张**。

### 实现位置（改哪里）

| 层次 | 位置 | 作用 |
|---|---|---|
| **唯一常量源** | `exporters/base.py` → `MAX_EXPORT_IMAGES_PER_JOB = 100` | 全局默认上限 |
| 按类型差异化 | `exporters/base.py` → `EXPORT_IMAGE_LIMITS = {"main":100,"daily":100,"events":100,"collections":100}` | 按导出器 module 名覆盖 |
| 校验函数 | `exporters/base.py` → `assert_max_images(images, log_fn, exp_type)` | 超限时 log + `raise ValueError` |
| 调用点 | `main_exporter.py`（剔除已导出后）、`daily_exporter.py`（排序后）、`pack_exporter_base.py`（剔除已导出后） | 按**最终真实数量**判定 |
| 下发给前端 | `server.py` → `GET /api/export/limits`；`/api/export/preview` 响应的 `stats.maxImagesPerJob` / `stats.overLimit` / `limits` | 前端不硬编码阈值 |
| 前端 | `api.js:fetchExportLimits`；`app.js` 的 `currentExportLimit` / `exportImageCount` / `exportOverLimit`；`index.html` 第③步红条 + 按钮禁用 | 超限即拦截并提示分批 |

### 想改限制，怎么做

| 场景 | 操作 |
|---|---|
| 全局调整为 N 张 | 改 `MAX_EXPORT_IMAGES_PER_JOB = N`（`EXPORT_IMAGE_LIMITS` 里显式列出的类型需同步改，否则以字典为准） |
| 只放宽某一类（如 daily 改为 31） | 改 `EXPORT_IMAGE_LIMITS["daily"] = 31`，其余不动 |
| 取消限制 | 将常量与字典值设为 `0` 表示不限？——**不支持**，当前 `assert_max_images` 用 `n <= limit` 判断，`0` 会拦掉所有导出。要取消请直接注释三处 `assert_max_images` 调用，或改为一个足够大的值（如 `10**6`） |
| 临时放开一次大版本首发 | 改常量 → 重启 `studio/server.py` → 导出 → 改回。**前端无需改动**，下次打开页面自动拉取新值 |

> 注意：上限只在**服务端重启后**对 `/api/export/limits` 生效（常量在模块加载时读取）。若希望热更新，需要把阈值挪到配置文件或数据库——当前未做，因为改动频率预期极低。

### 口径说明（为什么放在剔除已导出之后）
`excludeExported` 默认开启，导出器会在校验前剔除已导出图片。因此数量校验放在**剔除之后、转码之前**，按最终真实数量判定，避免"实际只导出 60 张却被 100 张上限误拦"。前端 `exportOverLimit` 用预览清单条数（`previewStats.total`），与导出器同口径。

### 已实现的行为
- 后端：超限 → 抛出 `ValueError` → `/api/export` 返回 **HTTP 400**（与 500 运行时异常区分），文案含"超过单次导出上限 N 张…请减少选中范围或分批导出"。
- 前端：第③步显示"本次待导出 N 张（单次上限 100 张）"；超限时红条告警 + 导出按钮禁用 + `startExport` 内二次硬拦截。

### 验证
`temp/verify_export_limit.py` 9 项全通过（以**独立 server 子进程**方式跑，避免 Windows 多进程 spawn 重入测试脚本）：limits 端点、100 张成功、101 张 400 + 正确文案、预检 `overLimit` 边界。

