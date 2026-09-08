# Content Studio Server — 代码结构、功能与 API 全览

> 适用范围：`studio/` 子项目后端（`server.py` + `core/` + `exporters/` + `taxonomy.py`）
> 代码基线：2026-09-08（`server.py` 1662 行，`core/` 9 模块 3629 行，`exporters/` 8 模块 1957 行）
> 说明：本文所有接口、字段、常量均以当前源码为准；如与旧设计文档冲突，以本文（源码）为准。

---

## 一、定位与技术选型

Content Studio Server 是拼图内容打包工作台的**本地后端**，为 Web 工作台提供「扫描 → 打标 → 质检 → 裁切 → 导出」全链路能力。

三条硬性设计约束贯穿全部代码：

1. **零第三方 Web 框架**：只用 Python 标准库 `http.server` / `sqlite3` / `logging`，`pip install` 不是启动前置条件，`python studio/server.py` 秒开。
2. **永不因可选依赖缺失而崩溃**：OpenCV / NumPy / Pillow 任一缺失都有降级路径（`HAS_PIL`、`HAS_CV2` 开关）。
3. **纯本地单机**：监听 `127.0.0.1`，不做鉴权；靠 Windows 端口独占（`SO_EXCLUSIVEADDRUSE`）防多实例踩踏。

---

## 二、目录结构与模块职责

```
studio/
├── server.py               HTTP 服务：路由分发、业务编排、JobStore、质检 worker、日志初始化
├── taxonomy.py             分类法单一事实源（14 主 Tag + 中文名 + 路径推断规则）
├── __main__.py             支持 `python -m studio` 启动
├── core/                   领域核心层（不依赖 HTTP）
│   ├── cache_db.py         SQLite 算力缓存（文件元数据 / 质检分 / 用户裁切覆盖）
│   ├── scanner.py          目录扫描、哈希、图片元信息、排序、重复检测
│   ├── tags_manager.py     tags.json 读写、记录归一化、扫描结果与既有标签合并
│   ├── quality_evaluator.py 物理适玩度质检（8×8 死区分析 + smart crop 提分）
│   ├── crop_compute.py     纯几何/能量裁剪算法（与 scripts/imgcrop.py 共用）
│   ├── image_proc.py       缩略图、转码、规格化、并行进程池
│   ├── exports_ledger.py   导出账本（.studio/ledger，含 read_only 试导出模式）
│   ├── export_tracker.py   旧版 exported.json 账本读取（兼容层）
│   └── workspace.py        源目录 .studio 工作区（目录结构、审计流水、发布镜像）
├── exporters/              策略模式导出引擎
│   ├── base.py             BaseExporter 抽象基类 + 试导出隔离 + 进度上报
│   ├── registry.py         类型 → 导出器 工厂（main/daily/event/collection）
│   ├── main_exporter.py    主线关卡（序号 + 版本 + 分批次）
│   ├── daily_exporter.py   月度日历（ZIP）
│   ├── pack_exporter_base.py  Event/Collection 公共基类（ZIP 打包）
│   ├── event_exporter.py / collection_exporter.py  仅覆写 item 元数据
│   └── manifest_manager.py 客户端 manifest.json 路由清单维护
├── static/                 前端工作台（见 WebUI 文档）
└── test_*.py               单元/契约测试（test_studio / test_ledger / test_workspace /
                            test_image_proc / test_frontend）
```

**分层依赖方向**（严格单向，无回环）：

```
server.py（HTTP + 编排）
      ↓
exporters/（业务策略）
      ↓
core/（领域能力：扫描 / 质检 / 转码 / 账本 / 缓存）
      ↓
taxonomy.py（常量与推断规则）
```

---

## 三、HTTP 服务层

### 3.1 服务器：`StudioServer`（server.py:1539）

继承 `ThreadingHTTPServer`（每请求一线程，保证缩略图并发请求不被长任务阻塞），并针对 Windows 做了一处关键加固：

```python
def __init__(self, server_address, RequestHandlerClass):
    if sys.platform == "win32":
        self.allow_reuse_address = False      # 关闭标准库默认开启的 SO_REUSEADDR
    super().__init__(server_address, RequestHandlerClass)

def server_bind(self):
    if sys.platform == "win32" and hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
    super().server_bind()
```

**为什么必要**：Python 标准库 `TCPServer` 在 Windows 下默认置 `SO_REUSEADDR`，语义与 Unix 不同——它**允许两个进程同时绑定同一端口**并静默抢连接，表现为「起了两个实例，请求随机落到一个，界面状态诡异」。强制 `SO_EXCLUSIVEADDRUSE` 后第二个实例直接报错退出。

端口被占用时 `run_server`（server.py:1565）捕获 `winerror==10048` 并打印带处置建议的错误块后 `sys.exit(1)`。

### 3.2 请求处理：`StudioRequestHandler`（server.py:359）

统一能力：

| 能力 | 实现 |
|---|---|
| CORS | `_cors()`：`Access-Control-Allow-Origin: *`，方法 `GET,POST,OPTIONS`；`do_OPTIONS` 返回 204 |
| JSON 响应 | `_json(data, status)`，`ensure_ascii=False` + `indent=2` |
| 统一错误 | `_error(message, status)` → `{"ok": false, "error": ...}` |
| 路径解析 | `_resolve_image_path()`（见 3.3） |
| 分级日志 | `log_message()` 覆写：≥500 记 ERROR、≥400 记 WARNING；`/api/thumb`、`/static/`、`/favicon.ico`、`/api/health` 降为 DEBUG（避免刷屏），其余 INFO |

静态资源：`/` 与 `/index.html` 返回 `static/index.html`；`/static/**` 按 MIME 直出；`/favicon.ico` 返回 204；未命中的路径最后还会回退查一次 `STATIC_DIR` 再 404。

### 3.3 多策略图片路径解析 `_resolve_image_path`（server.py:752）

`/api/thumb`、`/api/file`、`/api/quality` 共用。三级回退：

1. 把 `path` 当绝对路径（含 URL decode 与原始串两个候选）；
2. 拼 query 里的 `?dir=`；
3. 拼**上次成功扫描的根目录** `StudioRequestHandler.current_root_dir`（`/api/scan` 时写入的类变量）。

这让前端传相对路径也能命中，是「扫描过一次之后到处都能用相对路径」的基础。

---

## 四、并发与任务模型

三种并发各自解决不同问题，互不干扰：

| 场景 | 机制 | 位置 |
|---|---|---|
| HTTP 请求并发 | `ThreadingHTTPServer` 每请求一线程 | `StudioServer` |
| 质检批量计算 | `ThreadPoolExecutor`（cv2 路径释放 GIL）或并行子进程（Pillow 降级），默认 `max(4, cpu_count-4)` 线程 | `quality_evaluator.evaluate_images_batch`；子批 50 由 `_run_quality_job` 驱动 |
| 图片转码 | 进程池 `convert_images_parallel`，`STUDIO_EXPORT_WORKERS` 或 `min(8, CPU)`；不可用时自动回退串行 | `core/image_proc.py` |
| 后台任务托管 | 质检走 `_Pool(max_workers=1).submit(...)`，POST 立即返回 taskId | `server.py:1126` |

**导出的执行模型刻意保持同步**：导出仍在原 POST 请求线程内同步跑完，前端靠并发轮询只读状态接口拿进度。取舍是「执行模型零改动 + 无 clientTaskId 时行为完全不变」。

### 4.1 JobStore（server.py:164-279）

导出与质检共用的**只读观测通道**，不是任务调度器：

- 全局 `_JOBS: dict[str, dict]` + 单把 `_JOB_LOCK`，所有读写持同一锁；
- `_job_snapshot()` **返回拷贝**（`list(logs)`），绝不外泄可变引用；
- 惰性清理：终态（done/error）超 300s 剔除，最多保留 50 条，**无定时器**；
- 无 `clientTaskId` 的请求不注册，整条路径与旧版完全一致（向后兼容底线）；
- 取消为协作式：只置 `cancel=True`，worker 在子批边界检查（`_QUALITY_SUB_BATCH = 50`）。

任务状态机：`running → done | error`（取消记为 `error="cancelled"`）。

### 4.2 质检后台 worker `_run_quality_job`（server.py:289）

```
子批循环（每批 50）
  → 检查取消 → evaluate_images_batch(并行)
  → rows: [(hash, result)] → db.save_qualities_batch(rows)   # 断点续算天然成立
  → _job_progress + _job_append_log
```

「子批落库」是关键：中途取消/崩溃，已算完的子批仍在 SQLite 里，下次只算未评分的（`get_unscored_items`）。

---

## 五、日志体系

- **双 Handler**：控制台按 `--loglevel`（默认 INFO）；文件恒为 DEBUG，落在 `temp/studio-YYYYMMDD.log`（`_default_log_file()`，**按日期命名，不做大小轮转**）。
- 格式：控制台 `[时间] [级别] 消息`；文件追加 `(文件名:行号)`，便于定位。
- **导出链路双写**：`_handle_export` 的 `log_fn` 同时写 JobStore（供前端轮询）和 Python logger（落盘），因此任务结束后仍可回溯逐张转码、index 写入、账本更新。
- 各 `core/` 模块用 `logging.getLogger(__name__)` 正常 propagate 到 `studio` logger；历史静默 `except: pass` 已改为 `logger.warning/error`。
- 已知坑：`core/image_proc.py` 的 logger 变量名是 `_logger`（不是 `logger`），改动时不要用错。

启动参数：`--host`（默认 127.0.0.1）、`--port`（5188）、`--open`、`--loglevel`、`--debug`、`--logfile`。

---

## 六、API 全量清单

所有 API 前缀 `/api`，响应均为 JSON（`/api/thumb`、`/api/file` 除外，直出二进制）。

### 6.1 GET

| 路径 | 参数 | 说明 | 响应要点 |
|---|---|---|---|
| `/api/health` | — | 探活 | `{ok, has_pil}`，前端 3s 心跳用它 |
| `/api/taxonomy` | — | 分类法元数据 | `{ok, tags, main_tags, catalogs, specific_tags, tag_zh, catalog_to_tags, tag_to_catalogs, all_canonical_tags}`。注：`tags`/`main_tags`/`catalogs`/`specific_tags` 当前**同为 `MAIN_TAGS`**（一份数据多个键，兼容前端历史字段名） |
| `/api/scan` | `dir`（必填） | 主扫描入口 | 见 6.2 |
| `/api/tags` | `dir`（必填） | 只读 tags.json + 关联导出/重复态 | `{ok, file, records}` |
| `/api/exported` | `dir`（必填） | 旧版 exported.json 账本 | `{ok, ledger}` |
| `/api/export/status`、`/api/job/status` | `task` | 任务快照（两路径同处理，向后兼容） | `{ok, found, state, logs, done, total, summary, error}`；未知任务 `{"ok":false,"found":false}` 且 **HTTP 200** |
| `/api/thumb` | `path`、`size`(默认360)、`dir` | 缩略图 | `Cache-Control: public, max-age=86400, immutable` + `ETag`（md5 of 路径+mtime_ns+size+size param）；命中 `If-None-Match` 返回 304 |
| `/api/file` | `path`、`dir` | 原图直出 | — |
| `/api/quality` | `path`、`hash`、`dir`、`force=1` | 单张质检（命中缓存直返） | `{ok, hash, quality, cached}` |
| `/api/quality/stats` | `dir` | 质检统计总览 | `{ok, stats}` |
| `/api/quality/scores` | `dir` | 轻量全量分数（**纯 SQL，不碰文件系统**） | `{ok, scores: {path: quality}, stats}` |
| `/api/crop/manual` | `dir` | 所有用户手动裁切框 | `{ok, overrides}`（仅含 `has_crop` 的条目） |

### 6.2 `/api/scan` 详细（server.py:558）

一次请求内完成的编排链：

```
find_tags_file → 读 tags.json（若有）
  → CacheDB.load_file_cache()                 # SQLite 元数据缓存，未点保存也能秒级恢复
  → scan_images() 全量文件发现
  → scan_image_infos(hash_cache, progress_cb) # 带缓存命中的元数据扫描
  → db.upsert_files() + db.prune_missing_files()
  → merge_scanned_images()                    # 与既有 tags 记录合并
  → load_exported_ledger() + get_exported_map() → 打 exported 标记
  → db.get_qualities(hashes) → 打 quality 标记
  → db.get_stats() → qualitySummary
  → find_duplicate_groups() → 打 is_duplicate / duplicate_with
```

响应：

```jsonc
{
  "ok": true,
  "dir": "...", "tagFile": "...", "tagFormat": "...",
  "records": [ /* 每条含 path/file/hash/width/height/format/size/long_side/
                   too_small_long/tags/catalogs/review_required/
                   exported/quality/is_duplicate/duplicate_with */ ],
  "stats": {
    "exportedCount": 0, "unexportedCount": 0,
    "scoredCount": 0, "unscoredCount": 0, "qualitySummary": {},
    "duplicateGroups": 0, "duplicateCount": 0, "duplicateHashes": []
  },
  "images": [ /* 图片元信息 */ ], "total": 0, "totalExported": 0
}
```

扫描进度通过 `progress_callback` 打点（首张、末张、每 500 张、或距上次 ≥1s），日志形如 `[SCAN] 进度: 1200/3000 (40.0%) | 缓存命中: 1180 | 新计Hash: 20`；重复素材以 `[DUP]` 前缀 WARNING 逐组打印（含各自标签），便于运营直接换图。

### 6.3 POST

| 路径 | 关键入参 | 说明 |
|---|---|---|
| `/api/tags` | `{dir, records}` | 原子写回 tags.json（`save_tags_file`）→ `{ok, file, count}` |
| `/api/export` | 见 6.4 | 统一导出入口（同步执行，可带 `clientTaskId`） |
| `/api/export/preview` | 见 6.5 | 只读预检，**不写任何盘** |
| `/api/quality/batch` | `{dir, clientTaskId, paths?, limit?, force?, maxWorkers?}` | 注册任务后**立即返回** `{ok, taskId, total, started}` |
| `/api/quality/cancel` | `{task}` | 协作式取消，仅 running 可取消 |
| `/api/crop/manual` | `{hash, dir, x0,y0,x1,y1, ratio}` | 保存手动裁切框（百分比坐标，校验 `0.0~1.0` 且 `x1>x0 / y1>y0`） |

`/api/quality/batch` 的目标集选择：`paths` 优先；否则 `force=true` 用 `db.get_all_items()`（重算全部），否则用 `db.get_unscored_items()`（只补未评分）。`limit` 钳制在 `[1, 2000]`，`maxWorkers` 仅在 `[1,24]` 内生效。**并发拦截**：已有 running 任务时新请求返回 **409**。

### 6.4 `/api/export`（server.py:1217）

入参（前端 payload）：`type`、`srcDir`、`outDir`、`httpBase`、`clientTaskId`、`format`、`rename`、`quality`、`targetRatios`、`cropMode`、`sortBy`、`startOrder`、`version`、`month`、`eventId`、`collectionId`、`title`、`titleZh`、`description`、`descZh`、`displayOrder`、`status`、`outputMode`、`excludeExported`、`selectedPaths`、`manualOrder`、`excludedPaths`、`trial`、`tagsRecords`。

执行链：

1. 注册任务（无 `clientTaskId` 则跳过）；
2. 构造 `log_fn`（双写 JobStore + logger）与 `progress_fn`；
3. **注入手动裁切框**：查 `CacheDB.get_all_user_overrides()`，把有 `has_crop` 的转成 `{hash: (x0,y0,x1,y1)}` 写入 `data["manual_boxes"]`，导出器按 hash 查找并对该文件跳过自动 smart crop；
4. `get_exporter(type)` → `validate()` → `execute()`；
5. 成功：试导出回 `trial/trialDir/wouldCommit`，正式导出回 `totalExported`；失败回 `{"ok":false,"error","logs"}` + HTTP 500。

响应结构（`ExportResult.to_dict()`）：`{ok, summary, files, logs, error}`，成功时另加 `totalExported` 或 trial 三件套。

### 6.5 `/api/export/preview`（server.py:1342）

只读预检，与真实导出**共用同一套排序与过滤口径**（这是它被反复修的重点）：

```
scan_images → 按 selectedPaths 过滤 → 剔除 excludedPaths
  → build_manual_order + sort_images（同口径）
  → 标签来源：入参 tagsRecords 优先，否则读源目录 tags 文件；无标签一律落 [Others]
  → ExportsLedger：已导出状态 + main 的 maxOrder
  → 统计：total / sourceBytes / estWebpBytes / estRatio / tags / dirs / alreadyExported
  → 建议：maxOrder / suggestedStartOrder / suggestedVersion
```

两处细节值得记住：

- `root = Path(src).resolve()`：必须与 `/api/scan`、`build_manual_order` 同为 resolved 口径，否则 manual 排序的键匹配不上会**静默退化**成扫描字典序。
- `_estimate_ratio(fmt, quality)`：webp 基准 `0.20@q70`、jpg `0.35`、png/original `1.0`，随 quality 按 `(q/70)^1.35` 缩放。用于「诚实标注」体积预估，不追求精确。

### 6.6 DELETE

| 路径 | 参数 | 说明 |
|---|---|---|
| `/api/crop/manual` | `hash`、`dir` | 删除该图的手动裁切覆盖 |

---

## 七、核心层要点

### 7.1 `core/cache_db.py` — SQLite 算力缓存

库文件：源目录下 `.studio.db`（`CACHE_DB_NAME`），上下文管理器用法 `with CacheDB(root) as db`。

| 表 | 用途 | 主要方法 |
|---|---|---|
| `file_cache` | path / mtime / size / sha256 / width / height / format | `load_file_cache` `upsert_files` `prune_missing_files` `get_all_items` `get_unscored_items` |
| `quality_cache` | hash → 质检结果（`details_json`） | `get_quality` `get_qualities` `save_quality` `save_qualities_batch` `get_all_quality_scores` |
| `user_overrides` | hash → 用户手动裁切框 | `get_user_override` `get_all_user_overrides` `set_user_override` `delete_user_override` |

设计要点：

- **身份凭证是内容 SHA-256，不是路径**——图片改名/移动后标签、复核态、质检分 100% 继承；
- 新字段（如质检的 `crop_box`/`score_boosted`）一律塞 `details_json`，**不改表结构**，旧缓存读到缺字段时前端不渲染即可；
- `get_all_quality_scores()` 一条 `file_cache LEFT JOIN quality_cache` 出结果，是「质检完成后轻量刷新」专用路径（替代全量重扫）。

### 7.2 `core/scanner.py` — 扫描与排序

- 扩展名白名单 `.jpg/.jpeg/.png/.webp/.bmp/.gif/.tif/.tiff`；忽略 `.git`、`.vscode`、`__pycache__` 等；
- `scan_image_infos` 并发取元信息，带 `hash_cache`、`progress_callback`、`stats_out`（cache_hits / new_hashes / errors）；
- 新增 `long_side` 与 `too_small_long`：`long_side < DEFAULT_LONG_TARGET` 时置位，供前端置灰不可选；
- `find_duplicate_groups` 按 hash 分组找内容重复；
- `sort_images` 支持 name / mtime / size / dimension 等，manual 模式接受 `manual_order` 列表。

### 7.3 `core/quality_evaluator.py` — 物理适玩度

- 8×8 网格死区分析：**内部核心死区权重 1.6×，四周边框死区 0.4×**（拼图语义：边框死区可裁掉，内部死区无可救药）；
- 输出 S/A/B/C/F 评级、`max_grid` 推荐难度、调色板、`crop_suggestion` 文案；
- **smart crop 提分**：在 BGR 转换前跑一遍 `_compute_smart_crop(pil_img)`（`compute_content_box → select_aspect → smart_aspect_crop_box`，ratio 池直接引用 `crop_compute.AUTO_FAMILIES`，与导出侧完全一致）；当 `border_dead_ratio ≥ 0.15 且 core_dead_ratio < 0.08 且 subject_short_side ≥ 1200` 时，按 `min(penalties*0.6, 20)` 回补分数并置 `score_boosted=True`；
- 默认检测器为 **USM**（5 档 × 71 张对比实测优于 std），导出侧 `trim_background` 同步改为 `detector="usm"`，保证质检与导出口径一致；
- 批量：`evaluate_images_batch(paths, eval_max_dim=640, max_workers=None)`，有 cv2 走线程池，无 cv2 走并行子进程；`VENV_PYTHON = C:\Home\Develop\venv\Scripts\python.exe` 是本机降级解释器。

### 7.4 `core/image_proc.py` — 转码与规格化

- `generate_thumbnail_bytes(path, size)`：有 Pillow 走缓存目录缩略图，无 Pillow 直出原图；
- `normalize_export_image(...)`：打开 → EXIF 纠正 → **长边 < 1920 阻断** → 去背景（USM）→ 比例裁切 → 长边缩放 → 转码；新增 `manual_box_pct` 参数，有值时**跳过自动 smart crop**，直接百分比→像素转换 + 边界安全裁剪；
- `DEFAULT_LONG_TARGET = 1920`（**上限，只缩小**；裁切后产物长边可能 <1920，短边落在 1280–1920）；
- `convert_images_parallel(tasks)`：进程池并行，worker `_convert_one_parallel` 为模块级函数（Windows spawn 可 pickle）；`on_progress(done, total, current, ok, result)` 可选回调；池不可用时自动回退串行，**绝不中断导出**。

### 7.5 `core/exports_ledger.py` / `workspace.py` — 账本与只读模式

`ExportsLedger(src_dir, read_only=False)` 与 `StudioWorkspace(src_dir, read_only=False)` 的 `read_only` 是**试导出零污染**的实现基石：

- `read_only=True` 时 `_try_migrate_legacy()` 只做内存迁移、跳过 `_save_unlocked()`；`append_records()` / `save()` 双保险拒绝写；`workspace.ensure_structure()` 只 `mkdir`，跳过含 `.studio.db` move 的 `_migrate_legacy_files`。
- 能力：`get_exported_hashes`、`get_exported_map`、`check_history_duplicate`（含严重度分级，允许补丁修订同一 logicalId，严禁主线互斥重复）、`append_records`、`get_max_order`、`get_active_record`、`get_next_revision`。

---

## 八、导出引擎（exporters）

### 8.1 四种模式

| type | 导出器 | 产物形态 |
|---|---|---|
| `main` | `MainExporter` | 主线关卡：序号 + 版本 + 批次，写 `main/index.json` |
| `daily` | `DailyExporter` | 月度日历 ZIP |
| `event` | `EventExporter(PackExporterBase)` | 限时活动 ZIP，需 `eventId` + `title` |
| `collection` | `CollectionExporter(PackExporterBase)` | 精选合集 ZIP，需 `collectionId` + `title` |

`event` / `collection` 共用 `PackExporterBase`，只覆写 `build_item_extra()`。

### 8.2 `BaseExporter` 三件事

1. **试导出隔离**（`is_trial`）：`_commit()` 返回 `not is_trial`；`_write_root()` 把构建根从 `ws.release_dir` 重定向到 `outDir/_trial_{ts}` 并把 `self.out_p` 一并改掉，使后续 copy / manifest / 文件清单天然落进试导出目录；`_write_trial_meta()` 输出 `_trial_meta/{source_map.json, ledger_delta.json, trial.log}`。读已有状态仍从 release 读，**version / startOrder 与正式将分配的一致**。
2. **进度上报**：`report_progress(done, total, current, ok, result)` 逐张输出日志（失败 warn），无订阅者时仍输出，内部异常一律吞掉。
3. **公共参数解析**：`resolve_quality` / `resolve_normalize` / `assert_min_long` / `resolve_excluded`（剔除集按**小写 posix 相对路径**比对）。

### 8.3 主线序号与版本（`MainExporter`）

- 显式传 `startOrder` 时校验：非补丁模式下必须 `> existing_max_order`，否则抛「请从 N+1 开始，避免覆盖已导出的关卡」；
- 未传时：`(existing_max_order + 1) if existing_max_order > 0 else 1`；
- 版本：显式传则用；否则有历史 `existing_version + 1`；首次为 **1**（不再用 101 偏移，1~100 段已随停用 demo 空出）。

### 8.4 图片规格化

三处导出器统一 `resolve_normalize`：`targetRatios`（`auto` = 1:1 + 4:3 族，也可手选 1:1 / 4:3 / 2:3）、`cropMode`（smart / center / none）、`trimBackground`。激活时 `assert_min_long` 阻断长边 < 1920 的图；导出记录与试导出 source_map 补记 `normalize`（ratio / WxH / content box / crop box）。

算法抽在 `core/crop_compute.py`，`scripts/imgcrop.py` 通过 `from studio.core.crop_compute import ...` 复用同一份实现，消除双份维护。

---

## 九、落盘产物一览

| 产物 | 位置 | 说明 |
|---|---|---|
| SQLite 算力缓存 | `<src>/.studio.db` | 文件元数据 / 质检分 / 用户裁切覆盖 |
| 导出账本 | `<src>/.studio/`（ledger、logs、release） | `ExportsLedger` + `StudioWorkspace` |
| 旧版账本 | `<src>/exported.json` | `export_tracker.py` 兼容读取 |
| tags | `<src>/tags.json` | 路径由 `find_tags_file` 发现 |
| 试导出目录 | `<out>/_trial_{YYYYMMDD_HHMMSS}/` | 含 `_trial_meta/` 三件套 |
| 缩略图缓存 | `studio` 缓存目录（`get_thumb_cache_path`） | 命中则跳过解码 |
| 运行日志 | `<root>/temp/studio-YYYYMMDD.log` | 按日期命名，无大小轮转 |

---

## 十、启动方式

```powershell
python studio/server.py --open          # 127.0.0.1:5188 并自动开浏览器
python studio/server.py --port 5189     # 端口占用时换端口
python studio/server.py --debug         # 控制台 DEBUG
python -m studio --open                 # 模块方式（__main__.py）
```

健康检查：`curl http://127.0.0.1:5188/api/health` → `{"ok": true, "has_pil": true}`。

---

## 十一、已知边界与注意点

1. **无鉴权**：任何能访问本机 5188 端口的人都可读写源目录；仅适用于本机可信环境。
2. **试导出的二次确认是纯前端防呆**：绕过前端直接 POST `/api/export` 仍可正式导出。
3. **试导出目录无 GC**：多次试导出会堆积 `_trial_*`，建议保留最近 N 版（未实现）。
4. **Windows 端口独占仅覆盖 win32**：其他平台仍用标准库默认行为。
5. **日志无轮转**：`temp/studio-YYYYMMDD.log` 按天切分，单日大批量导出可能产生大文件。
