# Studio 待修复 Issue 清单（Review 2026-09-09）

> 来源：2026-09-09 前后端代码 review（后端核心 / 导出引擎 / 前端三路并行审查，关键结论已抽查源码确认）。
> 本清单记录**尚未修复**的 issue。已完成项见 [CHANGES-20260909.md](CHANGES-20260909.md)（导出 fail-fast、账本写入失败中止、index/manifest 解析失败保护、前端脏保护、分页 + 搜索防抖、tagCounts 正交化）。
> **2026-09-09 更新**：高优先级 4 项（#1/#2/#3/#4）已全部完成，详见 [CHANGES-20260909.md](CHANGES-20260909.md)。#4 最终方案调整为**禁止降级**：启动时强校验 opencv+numpy+Pillow，缺失直接退出；`evaluate_image`/`evaluate_images_batch` 删除 Pillow 降级路径。

---

## ~~🔴 高优先级~~（已全部完成 2026-09-09）

### ~~1. 质检批次静默失败仍计入进度~~ ✅ 已完成
- **实现**：`server.py` `_run_quality_job` 增加 `failed` 计数与连续整批失败中止（≥2 批全失败置 error）；job 快照带 `failed` 字段；前端进度条旁显示"失败 N"。

### ~~2. 轮询失败后轮询链静默断裂~~ ✅ 已完成
- **实现**：质检/导出两侧轮询连续失败 10 次（3s 间隔）才判死，期间 toast 显示重试进度；判死后 UI 提供"🔄 重新连接"按钮，按 clientTaskId 重新挂载轮询。

### ~~3. tags.json 损坏时静默丢弃~~ ✅ 已完成
- **实现**：`tags_manager.py` 损坏文件重命名为 `tags.json.corrupt-<ts>` 保留现场；`/api/tags` 响应带 `warning`；前端 ⚠ toast 展示。

### ~~4. 质检降级链无评估器来源标注~~ ✅ 已完成（方案升级为禁止降级）
- **实现**：`server.py` `_require_export_environment()` 启动强校验 opencv+numpy+Pillow，缺失直接退出；`quality_evaluator.py` 删除 Pillow 降级路径，环境不可用时抛 RuntimeError。

---

## 🟡 中优先级

### ~~5. 批量打标无撤销快照~~ ✅ 部分完成 2026-09-09（二次确认防呆）
- **实现**：批量 Set / Remove / Clear 超过 20 张时弹二次确认（明示张数与动作语义）；Add 仅追加不加确认。完整撤销快照方案仍保留为后续可选项。

### ~~8. 用户主动取消的质检任务显示为 error~~ ✅ 已完成 2026-09-09
- **实现**：`_job_finish` 新增 cancelled 参数，取消走 `state="cancelled"`；前端识别并显示"质检已取消"。端到端验证通过。

### 6. `/api/scan` 同步执行且一次性返回全量数据
- **位置**：`studio/server.py:567-767`（`_handle_scan`）
- **现状**：扫描在请求线程内同步完成，万级文件首扫 HTTP 挂起数分钟；响应含全部记录 + images + qualities 的单个 JSON（几十 MB）。
- **修法**：复用质检的 JobStore 异步模式（POST 返回 task_id，轮询 `/api/job/<id>` 增量进度）；响应改增量 diff（扫描本身已有增量语义）。
- **验收**：万级目录首扫期间 UI 有进度且页面可交互。

### 7. 质检任务并发检查 TOCTOU + clientTaskId 覆盖运行中任务
- **位置**：`studio/server.py:1252-1261`（`_handle_post_quality_batch`）
- **现状**：并发检查与注册分两次加锁，两个并发请求都能通过检查并注册双任务；重复 `clientTaskId` 提交会覆盖运行中任务。
- **修法**：检查 + 注册放进同一次 `_JOB_LOCK` 持有期；`clientTaskId` 已存在且未终态时幂等返回现任务 task_id。
- **验收**：并发双击批量质检只产生一个任务。

### ~~8. 用户主动取消的质检任务显示为 error~~ ✅ 已完成 2026-09-09
- **实现**：`_job_finish` 新增 cancelled 参数，取消走 `state="cancelled"`；前端识别并显示"质检已取消"。端到端验证通过。

### 9. 扫描 prune 以单次可见性删除缓存，外部移动即丢哈希
- **位置**：`studio/server.py:649`（`_handle_scan` → `db.prune_missing_files`）
- **现状**：本次扫描未见的文件记录全部删除。文件被暂时移走（网络盘抖动/OneDrive 占位/子目录操作）即丢 SHA-256 缓存——大文件哈希正是扫描最慢环节；若扫描中途取消/异常则误伤更大。
- **修法**：宽限期策略——未命中行标记 `last_seen_scan_id`，连续 2 次扫描未见才物理删除；prune 前记录删除行数写日志/响应。
- **验收**：移走一个文件再扫描一次，扫描两次后缓存才被清理。

### 10. `set_user_override` 读-改-写竞态
- **位置**：`studio/core/tags_manager.py`（`set_user_override`）
- **现状**：读→改→整体写回无互斥，快速并发请求可互相覆盖丢用户输入（写入本身已是原子替换，只缺锁）。
- **修法**：模块级 `threading.Lock` 包住 read-modify-write 全程。
- **验收**：并发压测两请求设置不同 override，两者均生效。

### 11. 固定临时 ZIP 文件名，并发导出互相踩踏
- **位置**：`studio/exporters/pack_exporter_base.py:243`（`_{module}_{pack_id}_tmp.zip`）、`studio/exporters/daily_exporter.py:206`（`_daily_{month}_tmp.zip`）；同文件内临时转码图命名同患。
- **现状**：两个进程同时导出同一 pack/同月 daily 会写同一个 tmp zip，产出混合内容 ZIP 且哈希错误。
- **修法**：`tempfile.mkstemp()` 或名称加 `os.getpid()` + 随机串；结束清理。（成本极低，两个文件各改一行）
- **验收**：双进程并发导出同月 daily，产物各自完整。

### ~~12. 游离 Promise 拒绝触发全屏 fatal + api.js 无 JSON 兜底~~ ✅ 已完成 2026-09-09
- **实现**：fatal 全屏收窄到挂载完成前（`__STUDIO_APP_MOUNTED__` 标记）；mount 后的 error/rejection 降级为 StdLog 记录。`api.js` 新增 `parseJson` 统一兜底，全部 `res.json()` 调用点改造，`fetchJobStatus` 非 JSON 静默降级由轮询重试兜底。

### 13. tags 保存为全量 POST
- **位置**：`studio/static/js/app.js` `buildSaveRecords()`；后端 `/api/tags` 保存接口
- **现状**：每次保存整包 POST 上万条记录，大库保存慢、失败影响面大（自动重试已加，治标不治本）。
- **修法**：保存接口改增量（只 POST 变更 path+tags 的 delta）；可参考 tags delta 存储设计的既有方向。
- **验收**：大库单张打标保存耗时与库大小无关。

### 14. 导出 copy/压缩阶段无进度反馈
- **位置**：exporters 全流程（`report_progress` 只覆盖逐张转码）
- **现状**：`tmp_zip.replace`、`copy_release_to_out`（可能几百 MB）期间无任何进度，UI 像卡死。
- **修法**：copy 阶段分块拷贝按字节上报；至少在长操作前发"正在拷贝 X MB…"确定性提示。
- **验收**：大包导出全程进度条持续移动。

### 15. 大图查看器无缩放手势 + 筛选变化索引错位
- **位置**：`studio/static/index.html` viewer 主体（约 L888-928）、`studio/static/js/app.js:627`（`currentViewerItem` 基于 `filteredRecords` 索引）
- **现状**：viewer 无滚轮缩放/拖拽平移（质检死区细节查看刚需）；切换筛选/搜索时列表重排，viewer 若开着会指向另一张图。
- **修法**：加滚轮缩放 + 按住拖动平移（约 40 行原生实现）；viewer 打开期间按 `path` 锁定当前项对象引用而非索引，找不到再关闭。
- **验收**：质检中筛选变化，viewer 当前图不跳变。

### 16. 导出中途失败留下半成品，无清理与续跑
- **位置**：exporters 全流程（写入顺序 zip→cover→index→账本→copy→manifest）
- **现状**：任一步失败后 release 镜像留半成品 zip/cover/tmp，无回滚、无启动清理、无幂等续跑标记；重试时 revision 可能从 1 重来但残留旧 `-rN` 文件。
- **修法**：(a) zip/cover 写 `_staging/` 全部成功后再原子替换；(b) 导出开始清理遗留 `.tmp` 与 staging；(c) 以 `(pack_id, zipSha256)` 为幂等键，重试时"文件已存在且哈希一致"直接续跑后续步骤。
- **验收**：导出中途 kill 进程后重试，能续跑且无残留脏文件。

### 17. 扫描跳过的文件无用户可见提示
- **位置**：`studio/core/scanner.py`（增量扫描路径）
- **现状**：SHA-256 计算失败/为空的文件被静默排除不入记录，扫描响应仍"成功 + N 条"，文件在前端"消失"用户可能误以为已删除。
- **修法**：扫描结果附 `skipped` 数组（路径 + 原因），前端展示"本次扫描跳过 N 个无法读取的文件"。
- **验收**：放一个被锁定的文件后扫描，UI 显示跳过提示。

### 18. 导出预览请求竞态
- **位置**：`studio/static/js/app.js` `loadExportPreview`（约 L412-439）
- **现状**：无 AbortController/请求序号，快速切步骤时慢的旧响应后到覆盖新的排序结果，正式导出用错序数据。
- **修法**：模块级 `previewSeq` 序号守卫，响应处理前 `if (seq !== previewSeq) return;`（三行改动）。
- **验收**：快速切换 sortBy 后预览列表与最终选择一致。

---

## 🟢 低优先级

### ~~19. 错误 toast 2.5s 太短且单例互相覆盖~~ ✅ 已完成 2026-09-09
- **实现**：showToast 支持级别——error 红 8s / warn 橙 5s（可手动关闭）/ info 2.5s；error/warn 同步写入 StdLog 面板；13 处失败提示调用升级为对应级别。堆叠 toast 仍为可选项。

### 20. 审计流水写入失败静默 + JSONL 无轮转
- **位置**：`studio/core/workspace.py`（audit 写入路径）
- **修法**：写入失败至少 `_logger.warning` 带路径；JSONL 按天或按 10MB 滚动，旧文件保留 N 份。

### 21. `/static/` 服务缺路径包含性校验
- **位置**：`studio/server.py:437-443, 494-499`
- **现状**：未见 `resolve()` 后仍在静态根内的检查（删除图片处理器已有正确写法可复用）。本地 loopback 风险低，非 loopback 监听即目录穿越。
- **修法**：封装 `safe_join(root, rel)`，`Path.resolve()` 后校验 `root_resolved in p.parents`。

### 22. `current_root_dir` 类级全局可变状态
- **位置**：`studio/server.py`（`StudioRequestHandler.current_root_dir`，扫描时写类属性）
- **修法**：root 信息随请求上下文传递，不用类级全局；避免并发扫描两目录互相覆盖。

### 23. 日志无清理，DEBUG 全量落盘
- **位置**：`studio/server.py:78-84, 111-155`
- **修法**：启动时清理 N 天前日志；文件级别降为 INFO，DEBUG 留控制台。

### 24. 卡片网格无键盘可达性
- **位置**：`studio/static/index.html:329`（卡片 div @click）、`studio/static/js/app.js` 全局键盘监听
- **修法**：卡片 `tabindex="0"` + `@keydown.enter/space` 选择；容器方向键移动焦点 + Space 勾选；`role="listbox"` / `aria-selected`。

### 25. `toggleSelect` 每次点击 O(n) 复制 Set
- **位置**：`studio/static/js/app.js:1003`
- **修法**：`shallowRef` + 直接改 Set 后 `triggerRef`，或 `selectedVersion` 计数器通知更新，点击恢复 O(1)（与 #24 大列表叠加时收益明显）。

### 26. `cardZoom` 拖动导致全网格缩略图换 URL 重拉
- **位置**：`studio/static/index.html:394`（`getThumbUrl(item.path, cardZoom * 2)`）
- **修法**：zoom 用 `change` 事件而非 `input`；或对分桶做吸附函数减少中间态请求。

### 27. `copyExportLogs` 先 toast 后异步写，失败无感知
- **位置**：`studio/static/js/app.js`（约 L1969）
- **修法**：await 成功后再 toast；失败 fallback `execCommand('copy')`，仍失败提示手动复制。

### 28. export_tracker 兼容层吞掉账本异常
- **位置**：`studio/core/export_tracker.py:82-83, 184-188`
- **现状**：读旧 exported.json 失败返回空账本、`append_records` 异常 `pass`——防重静默失效且无人知晓。
- **修法**：至少打日志；读取失败不返回"空账本"这种看似合法的结果。

---

## 建议的下一批

~~**#1 + #2 + #5 + #11**~~ —— 高优先级 4 项与 #5(防呆)/#8/#12/#19 已完成（2026-09-09）。**当前建议下一批：#11（临时文件唯一后缀，两行改动）+ #3 剩余部分（tags.json 损坏）已完 → 顺延为 #7（JobStore 并发 TOCTOU）+ #18（预览竞态）**。

## 已知良好设计（勿误改）

- 缩略图缓存键含 `mtime_ns+size`、`.tmp+replace` 原子写（`image_proc.py:96-185`）✅
- 导出 finalize 双通道幂等 + `finalized` 防双收尾（app.js）✅
- 正式导出二次确认 Modal（副作用清单 + 勾选）✅
- `deleteImage` 的 `res.json().catch()` 兜底（api.js）——是 #12 的改造模板 ✅
- logger.js 环形缓冲 500 条，与 fatal 守卫解耦 ✅
- 账本 `append_records` 幂等去重（module/logicalId/revision）✅
