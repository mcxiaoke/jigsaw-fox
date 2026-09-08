# 质检后台任务与缓存持久化设计

> 关联调研：[2026-09-08 质检问题调查] 现状为「单次点击只质检 30 张、无进度、无反馈」。
> 本文给出改造方案，重点解决两件事：
> 1. **前端退出/关闭/导航后，质检任务在「服务端后台」继续完成并落库**（任务与前端会话解耦、可重连观测）。
> 2. **质检结果以文件 sha256 为键持久化缓存**，除非用户「强制重新质检」否则复用。

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
   ├─▶ 后台 worker 线程(threading.Thread, daemon)：
   │       targets = paths 或 get_unscored_items(limit=500)   // force 时取全部 file_cache 不限 cache
   │       res = evaluate_images_batch(targets)               // 整批一次子进程，避免逐张冷启动
   │       for 每批:
   │           db.save_qualities_batch(hash→quality)          // 落 studio.db（sha256 关联）
   │           _job_progress(taskId, done, total)
   │           _job_append_log(taskId, {...})
   │       _job_finish(taskId, summary)
   │
   └─▶ 前端 700ms 轮询 GET /api/quality/job?task=
            ├─ running: 更新进度条 + 日志
            ├─ done:    rescan 目录 → 从 studio.db 装配 → 合并到 records
            └─ error:   toast

【退出界面后再回来】
   前端 onMounted / 切目录：读 localStorage 的 activeQualityTask
       ├─ job 仍在(≤300s TTL 且进程未重启) → 直接续轮询
       └─ job 丢失(超时/重启)            → rescan 目录，studio.db 已落库部分结果，
                                             未完成的仍 unscored，下次 batch 自动续算
```

---

## 4. 缓存设计（sha256 关联）

### 4.1 主缓存：`studio.db` / `quality_cache`（推荐，已成事实标准）

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
  - **强制重新质检（force）**：batch 接口 `force=true` 时，对目标 hash 直接 `save_qualities_batch`（`ON CONFLICT(hash) DO UPDATE` 覆盖，见 `cache_db.py:277`）；单张质检已支持 `force` 参数（`server.py:752` 命中即返回，force 跳过缓存）。
- **统计**：`get_stats()` 已给出 grade/status 分布（`cache_db.py:315`），前端 `qualitySummary` 直接展示。

### 4.2 可选镜像：`<srcDir>/.studio/quality.json`（tags.json 风格）

> 用于人工检视 / 跨机迁移 / 调试，与 `tags.json` 同目录（`workspace.py:38`）。

- **结构**（键为 sha256）：
  ```json
  {
    "version": 1,
    "updated_at": "2026-09-08T16:00:00",
    "items": {
      "<sha256>": {
        "score": 82, "grade": "A", "status": "PASS",
        "dead_zone_ratio": 0.03, "core_dead_ratio": 0.01,
        "border_dead_ratio": 0.08, "flat_zone_ratio": 0.05,
        "crop_suggestion": "原图构图饱满，无需裁切",
        "can_upgrade": false, "max_grid": "100 块 (10x10) 大师级",
        "evaluated_at": "2026-09-08T16:00:00",
        "details": { "laplacian_var": 320.0, "color_entropy": 3.1, "palette_hex": ["#..."], "diagnostics": [] }
      }
    }
  }
  ```
- **写入**：worker 每批 `save_qualities_batch` 后，增量合并写入并**原子 rename**（同 tags.json 的写入方式）。
- **读取**：扫描时若 `studio.db` 缺失/损坏，作为 fallback 装配。
- **取舍（重要）**：双写有不一致风险。**建议 `studio.db` 为唯一写入源（canonical），`quality.json` 由 studio.db 派生**（如 rescan 后导出/定时同步），不要把它当写入源，避免双源冲突。若评估下来维护成本 > 收益，可只做 `studio.db`（已满足全部需求）。

---

## 5. 接口设计

### 5.1 `POST /api/quality/batch`（改造）

请求体：
```json
{
  "dir": "/abs/src",
  "paths": ["a.jpg", "b.png"],   // 可选：指定若干图；缺省则取未评分
  "limit": 500,                  // 提高上限（原 20~200 太小）；worker 循环续批直到 unscored=0
  "force": false,                // true=强制重检（覆盖已缓存）
  "clientTaskId": "qc_xxx"       // 复用导出范式；无则退化为旧同步返回
}
```

行为：
- 立即 `_job_register(taskId)`，**后台 worker 线程**执行真实计算（不再阻塞请求）。
- 立即返回：`{ "ok": true, "taskId": "qc_xxx", "total": 1234, "started": true }`。
- 无 `clientTaskId`：保留旧同步行为兜底（仍跑完返回 items），但不注册 job。

### 5.2 `GET /api/quality/job?task=qc_xxx`（新增，复用 `_job_snapshot`）

返回（与导出状态接口同构）：
```json
{ "ok": true, "found": true, "state": "running",
  "done": 120, "total": 1234, "logs": [{"t":"16:01:02","level":"info","msg":"已评估 120/1234"}],
  "summary": null, "error": null }
```
可复用 `_handle_export_status` 的写法（`server.py:696`），新增路由 `if path == "/api/quality/job"`。

### 5.3 已有可复用

- `GET /api/quality/stats`：返回 grade/status 分布，rescan 后前端自动装配。
- `POST /api/quality`（单张）：已支持 `force` 覆盖（`server.py:752`）。

---

## 6. 前端改造（`studio/static/js/app.js`）

将 `triggerBatchQuality`（`app.js:630-667`）从「同步等结果」改为「**启动 + 轮询**」，完全对齐导出范式（`app.js:1244-1324`）：

1. **启动**：生成 `taskId = "qc_" + Date.now().toString(36) + ...`；`POST /api/quality/batch` 带 `clientTaskId` 与 `force`；把 `{taskId, dir, total}` 存内存 **+ localStorage**（跨会话重连）。
2. **轮询**：`pollQualityStatus`（700ms，同 `pollStatus`）：
   - `running` → 更新进度条 `done/total` + 日志；
   - `done` → 幂等 `finalize`：调用 `scanDirectory` rescan，从 studio.db 装配已有结果，合并到 `records`，进度条走满；
   - `error` → `showToast`。
3. **进度条 UI**：新增 `qc-progress`（复用 `index.html:879` 的 `q-progress-bg/q-progress-bar` 样式），按钮文案显示 `质检中 ${done}/${total}`。
4. **重连恢复**（`onMounted` / 切目录时）：读 localStorage 的 `activeQualityTask`：
   - job 仍在 → 续轮询；
   - job 丢失（超时 300s 或被重启） → 直接 `rescan`，studio.db 已落库结果自动装配，剩余 `unscoredCount` 驱动「继续质检」提示。
5. `unscoredCount` / `scoredCount` 已由 rescan 的 `stats` 驱动（现有 `app.js:122-123`），无需额外改造。

---

## 7. 缓存落库的字段清单（来自 `quality_evaluator`）

worker 每批写入 `studio.db`（`details_json` 存放 details 全量），镜像 json 同字段：

- 顶层：`score` / `grade` / `status` / `dead_zone_ratio` / `core_dead_ratio` / `border_dead_ratio` / `flat_zone_ratio` / `crop_suggestion` / `can_upgrade` / `potential_score` / `max_grid`
- `details`：`laplacian_var`（清晰度）、`color_entropy`、`color_spread`、`spatial_balance`、`palette_hex`（Top-5 主色）、`diagnostics`（诊断文本）、`grid_rows`/`grid_cols`、`grid_matrix`（8×8 每格 `var/edge/is_dead/is_flat` 死区地图）

---

## 8. 边界与风险

| 风险 | 处理 |
|---|---|
| 服务器重启 | worker 线程随进程退出；但 `studio.db` 已分批落库，重连走 rescan 自然**断点续算**（剩余 unscored 下次 batch 继续）。job TTL 300s 内可查，超时惰性清理（`server.py:163`）。 |
| 并发重复点击 | 同目录同时只允许一个质检 job（worker 启动用 `_JOB_LOCK` 或 per-dir 互斥标记）；重复点击返回「已有进行中任务」。 |
| cv2 缺失导致慢 | worker 改用 `evaluate_images_batch`（**一次子进程跑整批**）替代逐张 `evaluate_image`；理想是把 README 启动命令改为 venv python（`C:\Home\Develop\venv\Scripts\python.exe` 已装 cv2 5.0，进程内更快）。 |
| 超大库（25k 张） | `limit` 提到 500/批，worker 循环续批直到 `unscored=0`；每批落库 + 进度回写，天然分片不爆内存。 |
| 线程安全 | `CacheDB` 已用 `threading.Lock` + WAL（`cache_db.py:36,49`），worker 与扫描/读取并发安全。 |

---

## 9. 实施步骤（待拍板后执行）

1. **server**：抽出 `_run_quality_job(dir, targets, force, task_id)`，在 `threading.Thread(daemon=True)` 中执行；循环续批 + `_job_progress`/`_job_append_log`/`_job_finish`。
2. **server**：`POST /api/quality/batch` 改为「注册 job → 起线程 → 立即返回 taskId」；支持 `force` 与 `paths` 续批；无 `clientTaskId` 时保留旧同步兜底。
3. **server**：新增 `GET /api/quality/job`（`_job_snapshot` 透传）。
4. **cache_db（可选）**：`add_quality_json_mirror()` / `load_quality_json()`，实现 4.2 的 json 镜像（建议 studio.db 为源，json 派生）。
5. **frontend**：`triggerBatchQuality` 改为「启动 + 700ms 轮询 + 幂等 finalize」；新增进度条；localStorage 重连恢复。
6. **README**：启动命令建议改用 venv python（进程内 cv2，免子进程冷启动）。
7. **测试**：后端在 `test_studio.py` 增补「后台 job + force + 断点续算」用例；前端手动验证退出重连。

---

## 10. 小结

- **"退出界面任务继续"** 靠「server 后台 worker 线程 + job 框架 + 前端轮询重连」实现，复用导出已验证的范式，风险低。
- **"缓存 + 强制重检"** 靠现有 `quality_cache`（sha256 主键）即可满足；`quality.json` 仅作为可选派生镜像，便于检视/迁移。
- 最大性能收益来自把「逐张 `evaluate_image`（每次冷起子进程）」换成「`evaluate_images_batch`（整批一次子进程）」，并顺手解除写死的 `30` 限制与单请求阻塞。
