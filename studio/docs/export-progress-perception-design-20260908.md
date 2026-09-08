# Studio 导出「进度感知」设计方案（同步执行 + 状态轮询）

> 日期：2026-09-08 ｜ 状态：**已按本文实施**（验证全绿，见 `docs/CHANGES-20260908.md`） ｜ 关联：导出提速已上线（见 `docs/CHANGES-20260908.md`）
> 需求来源：导出 16 张约 1 分钟且全程无进度提示（按钮仅显示「⏳ 正在导出...」，日志要等结束才一次性出现）。
> 硬约束：**不引入 Bug** —— 执行模型不改、向后兼容、进度通道绝不影响主流程。

---

## 1. 目标

1. 导出执行中前端能实时看到：当前阶段（校验/查重/转码/收尾）、转码图片计数 `n/total`、日志逐条滚动。
2. 任何情况下结果展示能力不比现状差（最坏 = 回到"等 POST 返回后显示"，不会更糟）。
3. 不改变导出器执行语义、不新增后台线程、不引入任务取消/重启等生命周期复杂度。

## 2. 方案取舍

| 方案 | 优点 | Bug 风险 | 结论 |
|---|---|---|---|
| 后台线程 + POST 立即返回 task_id | 交互最顺 | 需管理任务生命周期/取消/恢复；execute 挪线程后栈/异常/单测全变；并发重入要防 | 放弃 |
| SSE / WebSocket | 实时推送 | EventSource 断线重连 + 与 POST 组合的状态机复杂度 | 放弃 |
| **同步执行 + 轮询读状态** | execute 仍在原 POST 线程同步跑；ThreadingHTTPServer 天然多线程，POST 执行中其它线程可同时服务状态查询 | 无新并发模型 | **采用** |

关键事实支撑：`ThreadingHTTPServer` 每个请求独立线程，因此 POST `/api/export` 在导出期间占用一个 handler 线程时，浏览器发起的 `GET /api/export/status` 会被**另一个线程**即时处理——这是本方案可行性的基础，不需要任何后台任务设施。

## 3. 接口契约

### 3.1 POST /api/export（不变 + 可选字段）

- body 新增**可选**字段 `clientTaskId`（前端生成的 uuid/随机串）。
- 带 `clientTaskId`：server 注册任务并实时记录进度；响应结构**不变**（`{ok, summary, files, logs, error}`）。
- 不带 `clientTaskId`（旧前端/curl/单测直调）：**整条路径与现在逐字节相同**。

### 3.2 GET /api/export/status?task={clientTaskId}

返回快照（副本，非引用）：

```json
{
  "ok": true,
  "found": true,
  "state": "running" | "done" | "error",
  "logs": [{"t": "HH:MM:SS", "level": "info", "msg": "..."}],
  "done": 5, "total": 16,
  "summary": "...",   // state=done 时
  "error": "..."      // state=error 时
}
```

- 未知 task → `{"ok": false, "found": false}`，前端据此**静默停止轮询**并依赖 POST 结果，不弹错误。

### 3.3 JobStore 生命周期与清理

- 注册：POST 收到 `clientTaskId` 即 `register()`（state=running）。
- 更新：`log_fn` → `append_log`；转码进度 → `update_progress(done,total)`；`execute()` 正常返回/抛异常 → `finish(summary|error)`。
- 清理（防内存增长）：`register/get` 时惰性剔除「终态且创建超过 5 分钟」的记录，最多保留最近 50 条。无定时器、无额外线程。

## 4. 改动点清单（按文件）

| 文件 | 改动 |
|---|---|
| `studio/server.py` | ① 模块级 `ExportJobStore`（`dict + threading.Lock`；所有读写持锁，快照返回深拷贝 logs）；② `_handle_export` 增加 clientTaskId 注册 + log_fn 双写 JobStore + `finish()`；③ 新增 `GET /api/export/status` handler；④ 惰性清理 |
| `studio/core/image_proc.py` | `convert_images_parallel(tasks, workers=None, on_progress=None)`：`as_completed` 每完成一张回调 `(done,total)`；**默认 None 行为不变**；回调 try/except，抛错只记日志 |
| `studio/exporters/base.py` | `BaseExporter.__init__` 增加可选 `progress_fn=None`（不传则老调用不变） |
| `studio/exporters/main_exporter.py` | 转码循环的 `convert_images_parallel(tasks)` → 有 progress_fn 时传 `on_progress`（1~2 行） |
| `studio/exporters/pack_exporter_base.py` | 同上（ZIP 转码处） |
| `studio/exporters/daily_exporter.py` | 同上（ZIP 转码处） |
| `studio/static/js/api.js` | `executeExport` 不变；新增 `fetchExportStatus(taskId)` |
| `studio/static/js/app.js` | `runExport`：生成 clientTaskId 塞 payload → 发 POST（不阻塞 UI）→ `setTimeout` 递归轮询 ~0.7s → 全量替换 exportLogs + 更新进度计数 → 双通道经**单一幂等 `finishExport()`** 收尾（先到者执行，后到者忽略） |
| `studio/static/index.html` | 按钮文案加进度（`⏳ 转码 5/16`）；执行中（isExporting）即显示日志面板（原「仅 step4 显示」放宽到「step3 执行中」） |

## 5. 防线清单（控制 Bug 的机制）

1. **向后兼容硬约束**：无 `clientTaskId` 的请求（含现有 41 单测直调）走原路径，行为零变化。
2. **进度通道不影响主流程**：所有 JobStore 写回调（log_fn/on_progress）内部 try/except，坏了也不打断导出。
3. **无共享可变迭代**：快照返回拷贝；JobStore 读写持同一把锁。
4. **双通道收尾幂等**：POST 结果与轮询终态谁先到只执行一次收尾，另一路忽略（flag 保护）。
5. **status 404 / 网络错误 = 静默降级**：停止轮询、继续等 POST，结果展示能力与今天一致。
6. 进度粒度只到**图片级**（并行池 as_completed），不做"子任务内百分比"，避免易错粒度；其余阶段由既有 log 文案覆盖。

## 6. 测试计划

1. 新增单测：
   - JobStore：register / append_log / update_progress / finish / 过期清理 / 并发写读冒烟。
   - status 端点：真实起服（沿用 `test_studio.py` server 测试模式），并发线程模拟导出写 store，断言轮询能读到 running→done、logs 递增、done/total 变化。
2. 既有 41 单测全绿（无 taskId 路径逐字节不变）。
3. `studio/test_frontend.py`（JS 语法 + headless mount smoke）。
4. 手动端到端两遍：
   - 成功路径：真实 16 张大图导出，观察按钮进度数字递增、日志逐条滚动、结束后 summary 正确。
   - 失败路径：故意损坏 1 张源图触发安全中止，观察 error 展示与轮询停止、按钮恢复。

## 7. 明确不做（本期范围外）

- 取消/中止导出、任务持久化与重启恢复、多标签页共享进度、SSE/WebSocket。
- 「详细 txt 日志落盘到素材库 `.studio/logs`」另立任务（与 jsonl 审计并列），不在本方案内实现。
