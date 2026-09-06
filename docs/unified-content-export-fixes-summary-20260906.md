# 统一内容导出与存储架构三方审查修复总结报告 (v2.3.0)

> 日期：2026-09-06  
> 基准审查文档：  
> 1. `docs/unified-content-export-and-storage-architecture-review-ms.md` (微软架构审查)  
> 2. `docs/unified-content-export-architecture-code-review-bd.md` (百度代码审查)  
> 3. `docs/unified-content-export-implementation-code-review-ds-20260906.md` (DeepSeek 实现审查)

---

## 一、 核心架构原则与设计决议

根据项目设计原则与用户明确指令，本次修复遵循以下硬性架构准则：

1. **彻底消除旧代码兼容分支**：项目处于快速演进与未发版阶段，不引入任何双向兼容或历史遗留 fallback。所有模块数据格式与逻辑全部统一为最新规范。
2. **容器键名全局大一统 (`items`)**：废除多套不一致的顶层键名（`levels`、`batches`、`months`、`events`、`collections`），主清单、不可变分卷、月份包、活动包、合集包统一使用 `"items": [...]`。
3. **彻底解耦不可变 `url` 与本地物理 `localPath`**：
   - `url` 仅用于网络远程寻址，严禁在下载或解压后被覆盖为本地物理路径；
   - `localPath` 显式记录本地缓存/解压的实际绝对路径；
   - 关卡换图与版本更新严格依据 `hash` 对比，不依赖易发生误判的 URL 覆盖。
4. **源素材库工作区自包含与源根目录零杂质**：
   - 隐藏工作区 `.studio/` 收敛所有元数据、缓存与账本：`cache/`、`ledger/`、`logs/`、`staging/`、`release/`；
   - 严禁在源目录根部生成 `exported.json` 等散落文件；
   - 缩略图缓存收敛至当前工作区 `.studio/cache/thumbs/`。
5. **不可变构建与 CDN 强缓存防冲突**：
   - 当重导同名 pack 或 daily 月份且内容发生改变时，自动递增输出修订后缀（如 `packs/{pack_id}-r{rev}.zip`、`zips/{month}-r{rev}.zip`），杜绝因覆盖同名文件而被 CDN 长期强缓存截流。
6. **导出前强制图片格式双重校验**：
   - 关卡图与封面导出前必须通过 Pillow 严格解码校验，杜绝 0 字节、损坏或截断的破损图片流出。

---

## 二、 审查问题项与修复落地对照表

| 编号 | 优先级 | 问题描述与来源 | 修复方案与改动文件 | 修复状态 |
| :--- | :---: | :--- | :--- | :---: |
| **P0-1** | **P0** | **ExportsLedger 逻辑 ID 倒排索引失效**<br>（ms §1.1, bd §3.1）<br>`_by_logical_id` 为标量覆盖字典，导致同 logicalId 历史记录被覆盖，`get_next_revision` 沦为 O(N) 线性遍历。 | 改造为 `dict[str, list[dict]]`，追加记录时同步累加历史记录列表，使 `get_active_record` 与 `get_next_revision` 全程保持 O(1) 查询效率。<br>📄 `studio/core/exports_ledger.py` | **已完成** |
| **P0-2** | **P0** | **Windows 文件锁与瞬时并发冲突**<br>（ms §1.2, bd §3.2）<br>原子写入 `.tmp -> replace` 在 Windows 环境若遇杀毒软件或文件句柄未完全关闭会抛出 `PermissionError`。 | 增加 3 次指数退避重试（50ms/100ms/200ms），并在解析严重损坏账本时自动备份为 `.corrupt` 并重置，防止进程彻底卡死。<br>📄 `studio/core/exports_ledger.py` | **已完成** |
| **P0-3** | **P0** | **历史月份 ZIP 懒加载 URL 寻址断链**<br>（ms §2.1, bd §2.1）<br>v2.3.0 规范取消了 `zipUrlPattern`，但客户端此前仅解析当前月份，导致历史月份懒加载无法获取下载链接。 | `ContentManager` 增加 `_dailyMonthZipUrls` 缓存并提取 `resolveDailyMonthZipUrl(yyyyMm)`，统一从 `daily/index.json` 解析并绝对化任意月份 `zipUrl`，打通历史月份下载闭环。<br>📄 `lib/logic/content/content_manager.dart` | **已完成** |
| **P0-4** | **P0** | **MainContentPipeline 判脏空值穿透**<br>（ms §2.2, bd §2.2）<br>判脏条件若写为 `existing.hash != level.hash`，当客户端旧缓存未落地 hash (`null`) 且远程有 hash 时可能引发误判或换图失效。 | 完善判脏表达式：`(level.hash != existing.hash) \|\| (level.url.isNotEmpty && existing.url.isNotEmpty && level.url != existing.url)`，有效覆盖首次哈希迁移与换图检测。<br>📄 `lib/logic/content/pipelines/main_content_pipeline.dart` | **已完成** |
| **P1-1** | **P1** | **Workspace 拓扑与未闭环方法清理**<br>（ds §2.1）<br>多余 `export_dir` 与未实现的 `promote_staging`，且 `thumbs_dir` 缺失。 | 移除无用的 `export_dir`；增加标准 `thumbs_dir`（指向 `.studio/cache/thumbs`）；实现 `promote_staging(module)` 并提供 `ws.ledger` 快捷属性。<br>📄 `studio/core/workspace.py` | **已完成** |
| **P1-2** | **P1** | **源根目录导出残留与杂质**<br>（ds §2.1, ms §1.1）<br>`ExportTracker` 在源目录根部新建 `exported.json`，破坏源库纯净。 | 彻底反转读取优先级，优先读取 `.studio/ledger/exports.json`，禁止在源根目录自动新建 `exported.json`，并同步维护 `total_exported`。<br>📄 `studio/core/export_tracker.py` | **已完成** |
| **P1-3** | **P1** | **缩略图缓存全局泄露**<br>（ms §1.1）<br>`image_proc.py` 的缩略图缓存在全局系统临时目录，非工作区自包含。 | 缩略图缓存改为向上寻找最近工作区的 `.studio/cache/thumbs/`，实现缩略图自包含与跟随素材库迁移。<br>📄 `studio/core/image_proc.py` | **已完成** |
| **P1-4** | **P1** | **Daily 缺少修订机制致 CDN 缓存冲突**<br>（ms §1.4）<br>重新导出同月份 ZIP 时直接覆盖，被 CDN 长期强缓存拦截。 | 引入内容哈希比对与修订后缀机制 `zips/{month}-r{rev}.zip`，并在 `index.json` 中指向新文件。<br>📄 `studio/exporters/daily_exporter.py` | **已完成** |
| **P1-5** | **P1** | **Pack 导出逻辑 ID 粒度过粗**<br>（ms §1.3）<br>原以 pack 维度记账，无法精准审计包内单图变更。 | 细化记账 `logicalId` 为图片级 `f"{module}:{pack_id}:{p.name}"`；输出规范 `type: "zip"` 与 `revision: rev`。<br>📄 `studio/exporters/pack_exporter_base.py` | **已完成** |
| **P1-6** | **P1** | **Pack 导出修订后缀防 CDN 冲突**<br>（ms §1.4）<br>合集与活动重新打包后同名覆盖。 | 支持检测修订并生成 `packs/{pack_id}-r{rev}.zip` 与 `covers/{pack_id}-r{rev}.webp`。<br>📄 `studio/exporters/pack_exporter_base.py` | **已完成** |
| **P1-7** | **P1** | **客户端模型缺失规范字段**<br>（ms §2.3, bd §2.3）<br>`PuzzleEventItem` 缺 `totalCount`/`fileSizeBytes`；`PuzzleCollectionItem` 缺 `unlockCoins`。 | 在两模型中完整补齐字段、构造参数、`copyWith`、`fromJson`、`toJson` 及辅助 getter。<br>📄 `puzzle_event_item.dart` / `puzzle_collection_item.dart` | **已完成** |
| **P1-8** | **P1** | **RootManifest 缺少 count/totalCount/hash**<br>（ds §3.3）<br>客户端根清单配置模型未完整映射各模块统计与哈希。 | 四大模块配置类补充 `totalCount`、`count` 与 `hash` 字段及序列化反序列化。<br>📄 `lib/logic/content/models/root_manifest.dart` | **已完成** |
| **P1-9** | **P1** | **MainContentPipeline 写死 .webp 扩展名**<br>（ds §3.1）<br>主线本地图片缓存文件名固定拼 `.webp`，遇到 jpg/png 时扩展名不匹配。 | 依据 `level.url` 的实际文件扩展名动态生成本地存储路径，旧文件删除同步适配本地路径。<br>📄 `lib/logic/content/pipelines/main_content_pipeline.dart` | **已完成** |
| **P2-1** | **P2** | **MainExporter 步骤编号与模块引用冗余**<br>（ds §2.2）<br>注释步骤错位，存在未使用的 `import shutil`。 | 修正步骤编号至 9，清理未使用引用，统一通过 `ws.ledger.append_records` 记账。<br>📄 `studio/exporters/main_exporter.py` | **已完成** |
| **P2-2** | **P2** | **DailyExporter 遗留废弃键与目录创建防御**<br>（ds §2.2）<br>`months` 废弃键未清理，`zips_dir` 目录缺失直接写入风险。 | 确保 `zips_dir.mkdir(parents=True, exist_ok=True)`；彻底清理遗留 `months` 键，仅输出 `items`。<br>📄 `studio/exporters/daily_exporter.py` | **已完成** |
| **P2-3** | **P2** | **ManifestManager 缺失 appConfig 与 count 规范**<br>（ds §2.3）<br>缺少规范所要求的默认 `appConfig` 结构，模块数量键名未严格遵循规范。 | 输出标准默认 `appConfig: {notice: "", minAppVersion: 1}`；主模块输出 `totalCount`，其他模块输出 `count`。<br>📄 `studio/exporters/manifest_manager.py` | **已完成** |
| **P2-4** | **P2** | **UI 残留 imagePathOrUrl 遗留兼容**<br>（ds §3.2）<br>`DailyTabView` 仍然使用旧字段判断本地文件存在性。 | 彻底改用 `level.localPath` 判断本地文件存在性，图片渲染统一走 `level.displayPath`。<br>📄 `lib/pages/tabs/daily_tab_view.dart` | **已完成** |
| **P2-5** | **P2** | **Pack item_entry 冗余输出 self.id_field**<br>（P5 / 遗留项）<br>条目字典同时输出 `"id"` 与 `self.id_field`（`eventId`/`collectionId`），存在冗余。 | 经核查客户端已全面基于 `"id"` 键反序列化，从 `item_entry` 中彻底删除 `self.id_field`，输入参数支持 `id` 优先。<br>📄 `studio/exporters/pack_exporter_base.py` | **已完成** |

---

## 三、 核心模块改造明细

### 1. Python Studio 侧改造

1. **`studio/core/workspace.py`**:
   - 废除顶层冗余的 `export_dir`，规范工作区内部结构；
   - 增加 `thumbs_dir` 属性，定位至 `self.studio_dir / "cache" / "thumbs"`；
   - 新增 `promote_staging(module)` 接口，实现 staging 暂存区向 release 正式区的安全晋级；
   - 新增 `ws.ledger` 动态属性，统一挂载 `ExportsLedger(self.src_dir)`；
   - 在日志记录器（`log_operation` / `log_export`）中将传入的 `Path` 对象安全转为 `str`，避免 JSON 序列化崩溃。

2. **`studio/core/exports_ledger.py`**:
   - `_by_logical_id` 内部结构由 `dict[str, dict]` 升级为 `dict[str, list[dict]]`；
   - `get_active_record` 与 `get_next_revision` 直接通过字典查找历史列表，查询时间复杂度降为 $O(1)$；
   - `_save_unlocked` 引入 3 次指数退避重试，攻克 Windows 下杀软占锁引发的 `PermissionError`；
   - 账本加载发生 JSON 解析损坏时，自动将损坏文件安全重命名备份为 `exports.json.corrupt.{timestamp}`，确保工作区自愈。

3. **`studio/core/export_tracker.py`**:
   - 读取优先级翻转：优先读取 `.studio/ledger/exports.json`，仅在不存在时向下回退旧账本；
   - 导出记录逻辑完全委托给 `ExportsLedger`，彻底废除在源根目录自动新建 `exported.json` 的行为；
   - 修复总导出数统计 `total_exported` 属性。

4. **`studio/core/image_proc.py`**:
   - 缩略图磁盘缓存路径改为向上逐级查找 `.studio` 工作区目录并缓存入 `.studio/cache/thumbs/`；
   - 严格落实单图与封面完整性校验。

5. **`studio/exporters/pack_exporter_base.py` & `daily_exporter.py`**:
   - `PackExporterBase`: 细化导出记账粒度为图片级 `f"{module}:{pack_id}:{p.name}"`；引入包修订机制（`packs/{pack_id}-r{rev}.zip` 与 `covers/{pack_id}-r{rev}.webp`），生成封面后增加 `validate_image` 校验；彻底删除条目中冗余的 `self.id_field`，统一仅输出 `id`；
   - `DailyExporter`: 引入月份修订机制（`zips/{month}-r{rev}.zip`），防御 CDN 缓存穿透与覆盖冲突；确保输出目录先建立；彻底清理遗留 `months` 键。

6. **`studio/exporters/manifest_manager.py`**:
   - 规范化 `manifest.json` 导出：生成默认 `appConfig: {notice: "", minAppVersion: 1}`；
   - 规范化计数输出：主线为 `totalCount`，日历、活动、合集为 `count`。

### 2. Flutter Client 侧改造

1. **`lib/logic/content/pipelines/main_content_pipeline.dart`**:
   - 修复 Hash 判脏逻辑空值穿透问题：不仅比对 `hash`，同时补充远端 `url` 变更比对；
   - 移除写死 `.webp`，提取 `_getFileExtension(url)` 动态生成本地文件名；
   - 缓存刷新删除旧文件时安全使用 `existing.localPath ?? _getLocalImagePath(...)`；
   - 彻底删除旧版单体裸列表兼容分支，严格仅解析 `items`。

2. **`lib/logic/content/content_manager.dart`**:
   - 增加 `_dailyMonthZipUrls` 运行时内存索引；
   - 抽取公共方法 `resolveDailyMonthZipUrl(yyyyMm)`，统一由 `daily/index.json` 解析并标准绝对化各月份 `zipUrl`；
   - `syncAll` 与 `ensureDailyMonthReady` 统一复用该方法，彻底打通历史月份懒加载下载闭环。

3. **`lib/logic/content/models/`**:
   - `root_manifest.dart`: 四大模块配置类全面支持 `totalCount`、`count`、`hash` 解析；
   - `puzzle_event_item.dart`: 补齐 `totalCount`、`fileSizeBytes`、`displayFileSize` 字段与序列化；
   - `puzzle_collection_item.dart`: 补齐 `unlockCoins` 字段与序列化。

4. **`lib/pages/tabs/daily_tab_view.dart`**:
   - 彻底移除 `level.imagePathOrUrl`；
   - 本地状态检查全面使用 `level.localPath != null && await File(level.localPath!).exists()`；
   - 图片渲染统一走 `level.displayPath`。

5. **`lib/logic/content/pipelines/events_content_pipeline.dart` & `collections_content_pipeline.dart`**:
   - 彻底移除 `else if (json is List<dynamic>)` 遗留分支，仅严格支持 `items: [...]`。

---

## 四、 自动化质量验证结果

### 1. Python Studio 自动化套件
- **执行命令**: `python -m unittest discover studio`
- **执行结果**: `Ran 40 tests in 11.198s`
- **结论**: **40/40 全部通过 (OK)**。涵盖工作区拓扑、权威账本查重与并发锁、不可变分卷导出、ZIP内容哈希校验、图片有效性拦截等。

### 2. Flutter 静态代码分析
- **执行命令**: `flutter analyze`
- **执行结果**: `No issues found! (ran in 5.0s)`
- **结论**: **0 Error, 0 Warning, 0 Lint Issue**。

### 3. Flutter 全量单元测试
- **执行命令**: `flutter test`
- **执行结果**: `00:10 +262: All tests passed!`
- **结论**: **262/262 全部通过**。涵盖数据模型序列化、RFC 3986 相对路径解析、管道分卷拉取、原子写盘、离线降级、UI 交互与渲染。

### 4. Windows 平台 Debug 编译验证
- **执行命令**: `flutter build windows --debug`
- **执行结果**: `Built build\windows\x64\runner\Debug\JigsawFox.exe` (耗时 16.0s)
- **结论**: **编译通过，无任何 C++/CMake 或 Dart 编译期错误**。

---

## 五、 后续部署建议

1. **GitHub Pages / Releases 部署**:
   - 按照规范 7.2 节规划，`main/batches/`、`main/images/`、`daily/zips/`、`packs/` 将来发布至 GitHub Releases 或 CDN 时，直接通过 `manifest.json` 的基准 URI 进行相对解析，无需修改代码；
2. **测试服务端状态**:
   - `test2` (`X:\www\game\test2\`) 为当前开发与联调的最新标准端点，完全符合 v2.3.0 规范；`test` 可在所有开发工作稳固后统一由自动化脚本刷新或废弃。
