# 独立 Temp 暂存区与极简启动清理架构设计 (2026-09-12)

## 1. 背景与核心目标

在之前的实现中，各管线（图集 Collections、活动 Events、每日挑战 Daily、扩展包 Packs）直接将下载中的 `.part`、临时 `.zip` 文件以及解压临时目录（`temp_extract_*`）存放在正式的关卡数据目录（如 `levels/collections/`）中。
当下载中途遇到强杀进程、关机、网络断连超时时，底层的临时文件（如 `temp_collection-xxx.zip.part`）会永久滞留在正式业务目录中，造成业务目录污染。

**核心目标**：
1. **物理隔离**：建立专用的 `appSupportDir/temp/` 暂存区，任何下载流（`.part`）、未就绪的临时 `.zip` 和解压临时目录全部限制在 `temp/` 内；
2. **正式目录洁净室**：`levels/` 正式业务目录保持“只读准入”，只接收已解压并校验通过的完整资源；
3. **极简清理策略**：**彻底摒弃复杂的运行中清理（场景 B）**。运行中任何中途失败或遗留的临时文件完全留待下一次启动清扫；
4. **零误删可能**：由于运行中不做任何扫描清理，绝无可能在下载过程中误删正在写入的 `.part` 文件；
5. **历史残留自愈**：启动时自动扫描并清理历史遗留在 `levels/` 各子目录中的 `*.part` 与 `temp_*` 文件。

---

## 2. 目录架构与职责划分

```
C:\Users\<user>\AppData\Roaming\com.mcxiaoke\JigsawFox\
├── levels\                          # [正式只读准入目录] 纯净无污染，只存已校验通过的完整资源
│   ├── collections\<collectionId>\  # 解压完成的图集关卡资源
│   ├── events\<eventId>\            # 解压完成的活动关卡资源
│   ├── daily\<yyyyMm>\              # 解压完成的月度挑战关卡资源
│   ├── packs\<packId>\              # 导入完成的扩展包
│   └── network\                     # 独立网络原图缓存
│
└── temp\                            # [专用临时暂存区] 允许随时无负担清扫
    ├── downloads\                   # 存放所有在途下载文件 (*.zip.part) 与下载就绪的临时 *.zip
    └── extract\                     # 存放正在后台解压中的临时目录 (extract_<id>_<timestamp>)
```

### 同驱动器原子性能保证（Same-Volume Atomic Move）
* `appSupportDir/temp/` 与 `appSupportDir/levels/` 均位于同一存储根路径下（同物理磁盘与卷）。
* 在解压完成且通过业务校验后，从 `temp/extract/extract_<id>_<ts>` 移动到 `levels/.../<id>` 采用操作系统底层的 `Directory.rename` 原生系统调用（Windows `MoveFileExW` / POSIX `rename`）。
* 此过程仅修改文件系统元数据指针，耗时 < 1ms，**无二次磁盘读写与数据拷贝开销**。

---

## 3. 极简清理工作流（Workflow）

### 3.1 正常下载与解压流程（即时收敛）
1. **下载阶段**：
   * 目标路径分配：`temp/downloads/<pipeline>_<id>_<ts>.zip`；
   * 流式下载产生：`temp/downloads/<pipeline>_<id>_<ts>.zip.part`；
   * 下载成功：原子重命名为 `temp/downloads/<pipeline>_<id>_<ts>.zip`。
2. **解压阶段**：
   * 临时目录分配：`temp/extract/extract_<pipeline>_<id>_<ts>`；
   * Isolate 解压到该临时目录；
   * 业务校验：图片文件格式白名单匹配，有效解压图片数量 > 0。
3. **原子提升与回滚保障（Atomic Promotion & Rollback）**：
   * 遵循红线 R1：若正式目录 `levels/.../<id>` 已存在旧内容，先将其改名为同级 `.bak_<ts>` 备份目录；
   * 优先执行同卷原子重命名 `await tempExtractDir.rename(targetDir.path)` 一键移入正式目录；
   * 若跨卷重命名失败，触发分阶段拷贝回退：先拷贝至同级 `.staging_<ts>` 目录，完成后原子 rename 替换；
   * 成功落位后安全清理旧备份；若任何步骤异常失败，自动将 `.bak_<ts>` 恢复还原，杜绝数据损坏或丢失；
   * 触发通知器，更新业务就绪状态。
4. **即时清理**：
   * 在 `finally` 块中立即删除 `temp/downloads/` 中的临时 `.zip`。

### 3.2 异常中断与强杀处理（启动零竞争清理）
* **运行中策略**：若用户在下载或解压过程中强杀进程、断电或网络超时抛错，当前进程不启动任何全局文件扫描与清理，残留的临时文件静置于 `temp/` 中；
* **冷启动初始化（Startup GC）**：
  * 时机：`ContentManager.initialize()` 执行的最早期；
  * 状态：此时前后台**尚未发起任何网络请求，在途活跃下载数为 0**；
  * 动作（清空暂存区）：直接清空 `appSupportDir/temp/` 目录；
  * 效果：以绝对的单线程、零并发竞态完成清扫，暂存区恢复 100% 洁净，且完全无需对正式业务目录进行多余遍历。

---

## 4. 深度自我审查（Self-Review Checklist）

我们对本方案进行了全面的潜在风险与功能破坏审查：

### 审查项 1：是否会破坏正在下载的 `.part` 文件？
* **结论**：**绝无可能（0 风险）**。
* **原因**：运行期间完全不执行后台 GC，所有的下载与解压任务独享其在 `temp/` 中分配的带时间戳唯一路径；清理动作仅在冷启动、所有下载尚未发生前执行。

### 审查项 2：是否会违反“红线 R1”（禁止删除已下载正式数据）？
* **结论**：**绝对严格遵守**。
* **原因**：
  1. 冷启动清扫仅作用于专用暂存区 `appSupportDir/temp/`，正式业务目录绝不触碰；
  2. 目录提升（`promoteExtractDir`）遵循严谨的**备份-替换-回滚**事务范式：替换前先重命名备份为 `.bak_<ts>`，失败则毫秒级无损回滚还原，彻底消除了直接预删旧目标可能遭遇崩溃丢数据的红线隐患。

### 审查项 3：跨目录 `Directory.rename` 是否可靠兼容？
* **结论**：**可靠安全**。
* **原因**：
  1. `temp` 与 `levels` 同属 `appSupportDir`，在 Windows、macOS、Linux、iOS、Android 上皆处于同一物理挂载点；
  2. 针对目标目录已存在的情况，采用原子改名备份（`targetDir.renameSync(bakPath)`），Windows 下即使有文件读取句柄也不会因目标名冲突受阻；
  3. 分阶段防御性回退（Staging Fallback）：若跨卷 rename 失败，先完整拷贝至同级 `.staging_<ts>`，完成后同级原子 rename，避免直接拷入目标可能因中途崩溃造成目标目录损坏。

### 审查项 4：是否影响单飞（SingleFlight）与 UI 进度监听？
* **结论**：**完全不影响**。
* **原因**：单飞锁（`runSingleFlight`）和进度条通知（`progressNotifier`）均基于业务唯一 ID（`collection.id` / `event.id`），与落盘的物理文件夹路径完全解耦。

### 审查项 5：冷启动清理是否会阻塞主线程导致白屏？
* **结论**：**不会**。
* **原因**：`temp/` 下通常仅有 0 到几个上次残留的死文件，清理耗时通常在 1~5ms 之间，远低于普通文件缓存读取时间（10~15ms）。

---

## 5. 落地执行模块规划

1. **`TempStorageManager` 抽离**（`lib/logic/content/staging/temp_storage_manager.dart`）：
   - 管理 `temp/downloads` 与 `temp/extract` 路径生成；
   - 提供极简 `cleanStaleTempDirectory()` 与原子提升带回滚的 `promoteExtractDir()`。
2. **各管线路径收敛**：
   - `CollectionsContentPipeline`、`EventsContentPipeline`、`DailyContentPipeline`、`PackContentPipeline` 统一使用 `TempStorageManager` 获取下载与解压路径。
3. **`ContentManager.initialize()` 挂载清理**：
   - 在启动第一步执行暂存区清扫。
4. **测试验证**：
   - 编写单元测试验证隔离路径生成、原子提升、回滚机制与启动清扫。
