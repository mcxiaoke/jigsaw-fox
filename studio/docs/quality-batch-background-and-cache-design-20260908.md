# 质检后台任务与缓存持久化设计

> 关联调研：[2026-09-08 质检问题调查] 现状为「单次点击只质检 30 张、无进度、无反馈」。
> 本文给出改造方案，重点解决两件事：
> 1. **前端退出/关闭/导航后，质检任务在「服务端后台」继续完成并落库**（任务与前端会话解耦、可重连观测）。
> 2. **质检结果以文件 sha256 为键持久化缓存**，除非用户「强制重新质检」否则复用。  
> ⚠️ **状态：规划 / 未实施**——文中早期命名（如 `/api/quality/light`）仅为设计稿草稿，最终落地为 `/api/quality/scores`。请以 `studio-server-architecture-and-api-20260908.md` + 当前源码为准。 

---

## 1. 现状与问题根因（简述）

| 现象 | 根因 | 代码位置 |
|---|---|---|
| 只质检 30 张 | 前端 `triggerBatchQuality` 写死 `batchEvaluateQuality(dir, 30)`；server 用该 limit 作 `get_unscored_items(limit)` 的 SQL `LIMIT`，且无自动续跑循环 | `studio/static/js/app.js:644`；`server.py:786`、`cache_db.py:295` |
| 没有进度 | 批量质检是「单次阻塞 HTTP 请求」，server 跑完所有图、攒齐结果后才一次性返回；前端仅有按钮文案 + 首尾 toast，无进度条、无逐张反馈 | `server.py:804` 的 `for` 循环；`index.html:281` |
| 没有反馈（慢） | 按 README `python studio/server.py` 启动时默认 python **无 cv2**，每调用一次 `evaluate_image` 就冷起一个 venv 子进程（timeout=10s）；server 又是「逐张 evaluate_image」而非「`evaluate_images_batch` 整批一次」 | `quality_evaluator.py:499-529`、`:514` |
| 退出即中断观感 | 当前批处理在请求线程内同步执行，前端无独立可重连的任务句柄；关闭页面后无法再看到进度/结果（服务端其实会跑完，但前端无重显机制） | `server.py:777` |

**好消息**：下面三样能力「已经存在」，本方案是「接线 + 补齐后台线程 + 缓存固化」，不是从零造。

- ✅ **job 后台任务框架**：`_job_register` / `_job_progress` / `_job_append_log` / `_job_finish` / `_job_snapshot`（`server.py:160-249`），并有导出轮询接口 `_handle_export_status` → `GET /api/export/status?task=`。
- ✅ **sha256 缓存底座**：`CacheDB.quality_cache` 表以 `hash` 为主键（`cache_db.py:72-88`），`save_qualities_batch` / `get_qualities` / `get_unscored_items` 齐备；扫描时已在 `server.py:527-538` 装配到每条记录。
- ✅ **前端轮询范式**：导出已实现 `taskId` 生成 + `setTimeout` 700ms 轮询 + 幂等 `finalize`（`app.js:1244-1324`），`api.fetchExportStatus` 可用。

---

## 2. 设计目标

1. 质检任务在**服务端后台线程**执行，前端退出/关闭/导航后**继续跑完并落库**。
2. 结果以**文件 sha256 为键**持久化；「强制重新质检」才覆盖，否则复用。
3. 提供**实时进度**（done/total + 日志），前端可重连查看，且断点续算（重扫目录即从库装配已完成部分，剩余继续）。
4. **最小化改动**：复用现有 job 框架与导出轮询范式。

---

## 3. 方案总览（数据流）

```
前端 triggerBatchQuality
   │  POST /api/quality/batch {dir, paths?, force?, clientTaskId}
   ▼
server 立即：_job_register(taskId)  →  返回 {ok, taskId, total}   （不等结果）
   │
   ├─▶ 后台 worker（ThreadPoolExecutor, max_workers=1）：
   │       targets = paths 或 get_unscored_items(limit=500)   // force 时取全部 file_cache（含已评分，需 get_all_items()）
   │       SUB_BATCH = 50  // 子批大小
   │       PARALLEL = max(4, cpu_count - 4)  // 子批内并行度，留 4 核给系统/server
   │       for i in range(0, len(targets), SUB_BATCH):
   │           sub = targets[i : i+SUB_BATCH]
   │           res = evaluate_images_batch(sub, max_workers=PARALLEL)  // 子批内并行（见 §3.1）
   │           db.save_qualities_batch(res)                    // 每子批落库 studio.db（sha256 关联）
   │           _job_progress(taskId, i+len(sub), len(targets))
   │           _job_append_log(taskId, {...})
   │           if _job_is_cancelled(taskId): break            // 取消检查
   │       _job_finish(taskId, summary)
   │
   └─▶ 前端 700ms 轮询 GET /api/job/status?task=
            ├─ running: 更新进度条 + 日志
            ├─ done:    rescan 目录 → 从 studio.db 装配 → 合并到 records
            ├─ cancelled: toast「质检已取消」
            └─ error:   toast

【退出界面后再回来】
   前端 onMounted / 切目录：读 localStorage 的 activeQualityTask
       ├─ job 仍在(≤300s TTL 且进程未重启) → 直接续轮询
       └─ job 丢失(超时/重启)            → rescan 目录，studio.db 已落库部分结果，
                                             未完成的仍 unscored，下次 batch 自动续算
```

---

### 3.1 子批内并行策略（关键性能优化）

`evaluate_images_batch` 当前**完全串行**（`quality_evaluator.py:535-537` 的列表推导或子进程内逐张循环）。改造为子批内并行，是整个方案最大的性能收益点。

**现状分析**：每张 `evaluate_path` 的工作分解——

| 阶段 | 操作 | 占比 | 是否释放 GIL |
|---|---|---|---|
| 文件读取 | `open().read()` | ~10% | ✅ 释放（I/O） |
| PIL 解码 | `Image.open` + `exif_transpose` + `convert` | ~15% | ❌ 持有 |
| numpy 转换 | `np.array(pil_img)` | ~5% | ❌ 持有 |
| OpenCV 运算 | `cvtColor` ×3 + `resize` + `Laplacian` + `Sobel` + `kmeans` | ~40% | ✅ 释放（C 层） |
| 网格分析 | `_analyze_grid` 64 格循环 + `np.var`/`np.mean` | ~15% | ⚠️ 部分 |
| 色彩/调色板 | `np.histogram` + `np.sum` + `cv2.kmeans` | ~10% | ✅ 释放 |
| 裁剪/打分 | `_evaluate_crop` / `_compute_score` | ~5% | ❌ 纯 Python |

约 **50-60% 计算量在 OpenCV/numpy C 层（释放 GIL）**，因此 **ThreadPool 并行有真实加速**。

**方案：`evaluate_images_batch` 按 `HAS_CV2` 分派并行策略**

```python
# quality_evaluator.py 改造

def evaluate_images_batch(paths, eval_max_dim=640, max_workers=None):
    """批量评估，子批内并行"""
    if not paths:
        return []
    
    workers = max_workers or max(4, (os.cpu_count() or 8) - 4)
    
    if HAS_CV2:
        # 进程内有 cv2：ThreadPool 并行（OpenCV C 层释放 GIL，有真实并行收益）
        evaluator = PhysicalEvaluator(eval_max_dim=eval_max_dim)
        with ThreadPoolExecutor(max_workers=workers) as pool:
            return list(pool.map(evaluator.evaluate_path, paths))
    
    # 进程无 cv2 但有 venv：并行多个子进程（subprocess.run 释放 GIL，ThreadPool 可并行等待）
    if VENV_PYTHON.is_file():
        return _evaluate_batch_parallel_subprocess(paths, eval_max_dim, workers)
    
    # 降级 Pillow 串行
    return [_evaluate_with_pillow(p) for p in paths]


def _evaluate_batch_parallel_subprocess(paths, eval_max_dim, workers):
    """并行多个 venv 子进程，每个子进程处理一个 chunk"""
    chunk_size = max(1, len(paths) // workers)
    chunks = [paths[i:i+chunk_size] for i in range(0, len(paths), chunk_size)]
    
    def run_chunk(chunk):
        cmd = [str(VENV_PYTHON), "-m", "studio.core.quality_evaluator", "--batch"]
        input_json = json.dumps([str(Path(p).resolve()) for p in chunk], ensure_ascii=False)
        env = {**os.environ, "PYTHONIOENCODING": "utf-8"}
        timeout = max(60, len(chunk) * 2)
        proc = subprocess.run(cmd, input=input_json, capture_output=True, text=True,
                              encoding="utf-8", errors="replace", env=env, timeout=timeout)
        if proc.returncode == 0 and proc.stdout.strip():
            return json.loads(proc.stdout.strip())
        logger.warning("[quality] 子进程 chunk 失败 (rc=%d): %s", proc.returncode, proc.stderr[:200])
        return []
    
    with ThreadPoolExecutor(max_workers=len(chunks)) as pool:
        chunk_results = list(pool.map(run_chunk, chunks))
    
    # 按 chunk 顺序拼接，保持与输入 paths 的对应关系
    return [item for chunk in chunk_results for item in chunk]
```

**预期加速比**（4 核 CPU）：

| 模式 | 串行（当前） | 并行（改造后） | 加速比 |
|---|---|---|---|
| `HAS_CV2=True`（进程内 cv2） | ~15ms/张 → 50 张 ~0.75s | ThreadPool 4 线程 → 50 张 ~0.25s | **~3×** |
| `HAS_CV2=False`（venv 子进程） | 启动 ~0.5s + 50 张 ~0.75s = ~1.25s | 4 子进程并行 → 启动 ~0.5s + ~0.2s = ~0.7s | **~1.8×** |
| Pillow 降级 | ~30ms/张 → 50 张 ~1.5s | 串行不变 | 1× |

> 注：`HAS_CV2=True` 模式加速比最高，因为省去了子进程启动开销且 OpenCV C 层充分释放 GIL。**推荐 README 启动命令改用已装 cv2 的 python**（当前默认 python 已 `pip install opencv-python`，直接 `python studio/server.py` 即可命中 `HAS_CV2=True` 路径）。

**并行度参数**：
- 默认 `max_workers = max(4, cpu_count - 4)`，留 4 核给系统和 server 本身；8 核 16 线程机器实际用 12 线程。
- 前端可通过 `POST /api/quality/batch` 的 `maxWorkers` 参数覆盖（可选，1-8）。
- worker 外层 `ThreadPoolExecutor(max_workers=1)` 管理整个 job 生命周期；`evaluate_images_batch` 内部再用 `ThreadPoolExecutor(max_workers=N)` 做子批内并行——两层 ThreadPool 不冲突，内层在外层线程内创建和销毁。

---

## 4. 缓存设计（sha256 关联）

### 4.1 主缓存：`studio.db` / `quality_cache`（唯一缓存源）

- **位置**：`<srcDir>/.studio/cache/studio.db`（由 `StudioWorkspace` 管理，`workspace.py:37`）。
- **关联键**：`file_cache.hash`（sha256）↔ `quality_cache.hash`（主键）。
- **现有表结构**（`cache_db.py:72-88`，无需改）：

  | 列 | 含义 |
  |---|---|
  | `hash` | 文件内容 sha256（主键） |
  | `score` / `grade` / `status` | 综合分 / 等级 / 状态 |
  | `dead_zone_ratio` / `core_dead_ratio` / `border_dead_ratio` / `flat_zone_ratio` | 死区/平坦区比例 |
  | `crop_suggestion` / `can_upgrade` / `max_grid` | 裁剪建议 / 可提分 / 推荐切片档 |
  | `details_json` | 完整细节（Laplacian、色彩熵、主色、diagnostics、8×8 网格） |
  | `evaluated_at` | 评估时间 |

- **失效策略**：
  - **内容寻址天然防 stale**：图片改动 → hash 变 → 生成新行；旧行可通过 `prune_missing_files` 思路定期清理（孤立 hash）。
  - **强制重新质检（force）**：batch 接口 `force=true` 时，需取**全部** file_cache 记录（含已评分），而非仅 `get_unscored_items`（后者 SQL 为 `WHERE q.hash IS NULL`）。新增 `get_all_items(limit)` 方法返回 `[(path, hash)]` 全量列表；对目标 hash 直接 `save_qualities_batch`（`ON CONFLICT(hash) DO UPDATE` 覆盖，见 `cache_db.py:277`）。单张质检已支持 `force` 参数（`server.py:752` 命中即返回，force 跳过缓存）。
- **统计**：`get_stats()` 已给出 grade/status 分布（`cache_db.py:315`），前端 `qualitySummary` 直接展示。
- **跨机迁移**：SQLite 文件本身可移植，sha256 跨机一致，直接拷贝 `studio.db` 即可迁移；如需人工检视，用任意 SQLite 客户端打开即可。

---

## 5. 接口设计

### 5.1 `POST /api/quality/batch`（改造）

请求体：
```json
{
  "dir": "/abs/src",
  "paths": ["a.jpg", "b.png"],   // 可选：指定若干图；缺省则取未评分
  "limit": 500,                  // 提高上限（原 20~200 太小）；worker 循环续批直到 unscored=0
  "force": false,                // true=强制重检（覆盖已缓存），取全部 file_cache 记录
  "clientTaskId": "qc_xxx",      // 必填：复用导出范式
  "maxWorkers": 12              // 可选：子批内并行度，默认 max(4, cpu_count-4)，范围 1-24
}
```

行为：
- 立即 `_job_register(taskId)`，**后台 worker**（`ThreadPoolExecutor(max_workers=1)`）执行真实计算（不再阻塞请求）。
- 立即返回：`{ "ok": true, "taskId": "qc_xxx", "total": 1234, "started": true }`。
- `clientTaskId` 为必填项，不再保留旧同步阻塞路径（旧路径的 30 张硬限制和阻塞行为无保留价值）。

### 5.2 `GET /api/job/status?task=xxx`（统一端点，复用 `_job_snapshot`）

返回（与导出状态接口同构，质检与导出共用同一查询端点）：
```json
{ "ok": true, "found": true, "state": "running",
  "done": 120, "total": 1234, "logs": [{"t":"16:01:02","level":"info","msg":"已评估 120/1234"}],
  "summary": null, "error": null }
```
将现有 `_handle_export_status`（`server.py:696`）泛化为 `_handle_job_status`，路由 `GET /api/job/status?task=`；导出与质检前端共用同一轮询函数，减少代码重复。

### 5.3 `POST /api/quality/cancel?task=qc_xxx`（新增）

取消进行中的质检任务。worker 在每个子批完成后检查 cancel 标志，若已取消则提前退出并 `_job_finish(taskId, error="cancelled")`。25k 张图可能跑数十分钟，取消机制不可省略。

### 5.4 已有可复用

- `GET /api/quality/stats`：返回 grade/status 分布，rescan 后前端自动装配。
- `POST /api/quality`（单张）：已支持 `force` 覆盖（`server.py:752`）。

---

## 6. 前端改造（`studio/static/js/app.js`）

将 `triggerBatchQuality`（`app.js:630-667`）从「同步等结果」改为「**启动 + 轮询**」，完全对齐导出范式（`app.js:1244-1324`）：

1. **启动**：生成 `taskId = "qc_" + Date.now().toString(36) + ...`；`POST /api/quality/batch` 带 `clientTaskId` 与 `force`；把 `{taskId, dir, total}` 存内存 **+ localStorage**（跨会话重连）。
2. **轮询**：`pollQualityStatus`（700ms，同 `pollStatus`，统一调用 `GET /api/job/status`）：
   - `running` → 更新进度条 `done/total` + 日志；
   - `done` → 幂等 `finalize`：调用 `scanDirectory` rescan，从 studio.db 装配已有结果，合并到 `records`，进度条走满；
   - `cancelled` → `showToast`「质检已取消」；
   - `error` → `showToast`。
3. **进度条 UI**：新增 `qc-progress`（复用 `index.html:879` 的 `q-progress-bg/q-progress-bar` 样式），按钮文案显示 `质检中 ${done}/${total}`；新增「取消质检」按钮，调用 `POST /api/quality/cancel`。
4. **重连恢复**（`onMounted` / 切目录时）：读 localStorage 的 `activeQualityTask`：
   - job 仍在 → 续轮询；
   - job 丢失（超时 300s 或被重启） → 直接 `rescan`，studio.db 已落库结果自动装配，剩余 `unscoredCount` 驱动「继续质检」提示。
5. `unscoredCount` / `scoredCount` 已由 rescan 的 `stats` 驱动（现有 `app.js:122-123`），无需额外改造。

---

## 7. 缓存落库的字段清单（来自 `quality_evaluator`）

worker 每子批写入 `studio.db`（`details_json` 存放 details 全量）：

- 顶层：`score` / `grade` / `status` / `dead_zone_ratio` / `core_dead_ratio` / `border_dead_ratio` / `flat_zone_ratio` / `crop_suggestion` / `can_upgrade` / `potential_score` / `max_grid`
- `details`：`laplacian_var`（清晰度）、`color_entropy`、`color_spread`、`spatial_balance`、`palette_hex`（Top-5 主色）、`diagnostics`（诊断文本）、`grid_rows`/`grid_cols`、`grid_matrix`（8×8 每格 `var/edge/is_dead/is_flat` 死区地图）

---

## 8. 边界与风险

| 风险 | 处理 |
|---|---|
| 服务器重启 | worker 随进程退出；但 `studio.db` 已分批落库，重连走 rescan 自然**断点续算**（剩余 unscored 下次 batch 继续）。job TTL 300s 内可查，超时惰性清理（`server.py:163`）。 |
| 并发重复点击 | 同目录同时只允许一个质检 job（worker 启动用 `_JOB_LOCK` 或 per-dir 互斥标记）；重复点击返回「已有进行中任务」。 |
| cv2 缺失导致慢 | worker 改用 `evaluate_images_batch`（**每子批一次子进程**）替代逐张 `evaluate_image`；推荐 README 启动命令改用已装 cv2 的 python（当前默认 python 已 `pip install opencv-python` 5.0.0，`python studio/server.py` 直接命中 `HAS_CV2=True` 进程内路径，免子进程冷启动）。 |
| 超大库（25k 张） | `limit` 提到 500/批，worker 循环续批直到 `unscored=0`；每子批 50 张并行评估 + 落库 + 进度回写，天然分片不爆内存。 |
| 串行瓶颈 | `evaluate_images_batch` 当前完全串行（列表推导或子进程内逐张循环）。改造为子批内 `ThreadPool` 并行（见 §3.1），`HAS_CV2=True` 时加速 ~3×，`HAS_CV2=False` 时加速 ~1.8×。 |
| 线程安全 | `CacheDB` 每实例一把 `threading.Lock`（`cache_db.py:36`），**跨实例不互斥**。worker 线程与 HTTP 请求各自创建 `CacheDB` 实例，跨实例并发靠 SQLite **WAL 模式 + `busy_timeout=30s`** 串行化写操作保证安全（`cache_db.py:49`）。非应用层锁保证，是数据库层串行化。若未来写压力增大，可考虑引入全局 CacheDB 单例或全局写锁。 |
| 子进程超时 | `evaluate_images_batch` 子进程 `timeout` 改为按子批大小动态计算：`timeout = max(60, len(sub) * 2)`。超时后降级 Pillow 逐张，需在日志中告警而非静默。并行子进程模式下各 chunk 独立计时，单 chunk 超时不影响其他 chunk。 |
| 取消需求 | 新增 `_job_cancel(task_id)` 设置 cancel 标志，worker 在子批之间检查并提前退出；`POST /api/quality/cancel` 供前端调用。 |

---

## 9. 实施步骤（待拍板后执行）

1. **quality_evaluator**：改造 `evaluate_images_batch` 支持子批内并行（见 §3.1），新增 `max_workers` 参数与 `_evaluate_batch_parallel_subprocess` 辅助函数。
2. **cache_db**：新增 `get_all_items(limit)` 方法，返回全量 `[(path, hash)]`（含已评分），供 force 模式使用。
3. **server**：新增 `_job_cancel(task_id)` 与 `_job_is_cancelled(task_id)`（cancel 标志存储在 `_JOBS[task_id]` 中）。
4. **server**：抽出 `_run_quality_job(dir, targets, force, task_id, max_workers)`，用 `ThreadPoolExecutor(max_workers=1)` 提交；内部按 `SUB_BATCH=50` 分子批循环，每子批调用 `evaluate_images_batch(sub, max_workers=max_workers)` → `save_qualities_batch` → `_job_progress`/`_job_append_log`，子批间检查 cancel 标志。
5. **server**：`POST /api/quality/batch` 改为「注册 job → 提交 Future → 立即返回 taskId」；支持 `force`、`paths`、`maxWorkers`；`clientTaskId` 必填，不保留旧同步路径。
6. **server**：新增 `POST /api/quality/cancel?task=` 路由。
7. **server**：将 `_handle_export_status` 泛化为 `_handle_job_status`，路由改为 `GET /api/job/status?task=`；导出与质检共用。
8. **frontend**：`triggerBatchQuality` 改为「启动 + 700ms 轮询（调 `GET /api/job/status`）+ 幂等 finalize」；新增进度条 + 取消按钮；localStorage 重连恢复。
9. **README**：启动命令说明当前默认 python 已装 cv2，直接 `python studio/server.py` 即可命中进程内路径（`HAS_CV2=True`），获得最佳并行加速。
10. **测试**：后端在 `test_studio.py` 增补「并行 batch + force + 断点续算 + 取消」用例；前端手动验证退出重连。

---

## 10. 小结

- **"退出界面任务继续"** 靠「server 后台 worker（`ThreadPoolExecutor`）+ job 框架 + 前端轮询重连 + 取消机制」实现，复用导出已验证的范式，风险低。
- **"缓存 + 强制重检"** 靠现有 `quality_cache`（sha256 主键）即可满足；`studio.db` 为唯一缓存源，跨机迁移直接拷贝 db 文件，无需 json 镜像。
- 最大性能收益来自两层并行：**外层** worker 按 `SUB_BATCH=50` 分子批串行（控制落库/进度粒度），**内层** `evaluate_images_batch` 子批内 `ThreadPool` 并行（`HAS_CV2=True` 时加速 ~3×，`HAS_CV2=False` 时加速 ~1.8×）。当前默认 python 已装 cv2，`python studio/server.py` 直接命中进程内路径，获得最佳加速。
