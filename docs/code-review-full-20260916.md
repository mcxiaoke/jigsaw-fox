# 全项目代码审查报告（2026-09-16）

> 范围：`lib/`（Flutter 主工程）、`studio/`（素材工作室，Python+JS）、`scripts/`（构建/发布脚本）
> 本报告与同日 `docs/code-review-audit-20260916.md` 互补：后者聚焦 `lib/` 的业务逻辑与 UI/UX 缺口（39 项），本报告聚焦**算法正确性量化分析、内容分发与数据安全、工具链与发布流水线、客观质量基线**，并覆盖后者未涉及的 `studio/` 与 `scripts/`。重叠项已在文中注明。

---

## 0. 审查方法与可信度声明

| 项 | 说明 |
|---|---|
| 审查方式 | 逐文件实读代码 + 多模块并行交叉审查 + **关键结论逐条回到源码复核** |
| 证据标准 | 每条结论附 `文件路径:行号`；正文标注 `[已复核]` 表示我亲自打开源码核对过，未标注者为交叉审查产出、尚未逐字复核 |
| 实测项 | `flutter analyze`、`flutter test`（全量）、依赖陈旧度、规模统计，均为本机实跑 |
| 未做 | 动态性能剖析、真机压测、渗透测试、历史 git 演进分析。**凡未实测的性能/安全推断均已标注"待实测确认"，不作为结论** |
| 工具链 | Flutter 3.44.8 / Dart 3.12.2 / Windows 10 |

**分级定义**：P1 严重（可致数据错误、资产损失或安全事件）｜P2 中等（功能降级、可恢复的资源浪费、明确技术债）｜P3 轻微（规范与体验）。

---

## 1. 结论摘要

| 维度 | 结论 |
|---|---|
| 静态质量 | **优秀**。`flutter analyze` = `No issues found!`（含 `very_good_analysis` 严格规则集） |
| 测试 | **优秀**。全量 `flutter test` = 373 通过 / 8 跳过 / 0 失败（需先解决本机代理，见 §3.2） |
| 工程成熟度 | **上乘**。持久层损坏自愈、关窗数据兜底、原子写、Isolate 卸载重活、生命周期适配均有专门设计且注释充分 |
| 主要风险 | ① 拼图判定存在**三套互不一致的容差常量**，高片数下可误判通关；② 内容分发**端到端完整性未闭环**；③ `studio/` 本地服务存在**路径穿越 + CORS 全开**；④ `lib/update` 残留**开发机硬编码路径** |
| 统计 | P1：6 项｜P2：16 项｜P3：11 项｜待确认：4 项 |

**一句话**：代码质量基线明显高于同类项目，问题集中在"局部常量缺乏统一口径"与"工具链/发布侧的安全与一致性"，而非架构缺陷。

---

## 2. 项目全景

### 2.1 规模

| 目录 | 文件数 | 行数 | 说明 |
|---|---:|---:|---|
| `lib/` | 101 Dart | 44,032 | 含生成代码 4,419 行（`l10n/gen`），手写约 39.6k |
| `studio/` | 42 | 20,019 | Python 服务端 + 前端 JS + 测试 |
| `scripts/` | 41 Python | 23,907 | 构建、质检、发布 |
| **合计** | 184 | **87,958** | |

`lib/` 最大文件：`jigsaw_puzzle_game.dart`(2,641)、`game_page.dart`(1,454)、`my_center_tab_view.dart`(1,296)、`choose_difficulty_sheet.dart`(1,080)、`daily_tab_view.dart`(1,078)。

### 2.2 分层

```
main.dart                 启动编排：日志→ImageCache 调优→生命周期钩子→Hive→分组初始化→首屏判定
├─ logic/
│  ├─ content/            内容分发：5 条管线（main/collections/events/daily/pack）+ 网络层 + 原子替换 + 暂存
│  ├─ engine/             拼图引擎：吸附判定、级联合并、撤销
│  ├─ geometry/           碎片几何：EdgeLayout（公母扣）、EdgeCurve、PieceShape
│  └─ cache/              关卡图解析、缩略图、本地定位
├─ game/                  Flame 游戏层（JigsawPuzzleGame / PuzzlePieceComponent）
├─ data/                  持久化：StorageManager(Hive) / Progress / Snapshot / Favorite / GameRepository
├─ services/              经济、成就、解锁、推荐、音效、日志、语言、WebView
├─ pages/ + widgets/      UI
└─ update/                自更新（Windows better-updater）
```

**启动编排质量高** `[已复核]`：`main.dart:44-72` 用 `AppLifecycleListener` 而非 `WidgetsBindingObserver`，并注释说明"Windows 上 `paused` 永不触发"这一真实踩坑；`:52-59` 关窗前 `waitPendingWrites → flushPendingWrites → backupNow → closeAll`，并正确指出 hive_ce `close()` 不 flush；`:92-95` 主动调优 `ImageCache`（500 张 / 150MB）防 OOM；`:133-139` 启动备份带"本轮有 box 重建则跳过"的守卫，避免空 box 覆盖历史好备份——这些是有工程品味的细节。

---

## 3. 客观基线（本机实测）

### 3.1 静态分析

```
flutter analyze → No issues found! (ran in 6.4s)
```

在启用 `very_good_analysis 10.3.0` 严格规则集下零告警，说明空安全、类型、lint 层面已经收敛。**本报告所列问题均为静态分析覆盖不到的逻辑、一致性、安全与运维问题。**

### 3.2 测试

```
flutter test → All tests passed! (373 passed / 8 skipped, 26s)
```

**重要环境发现** `[已复核]`：直接运行 `flutter test`，53 个测试文件**全部加载失败**：

```
Failed to load ".../test/..._test.dart": Unable to connect to flutter_tester process:
WebSocketException: Invalid WebSocket upgrade request
```

根因是本机设置了本地代理（`HTTP_PROXY=http://127.0.0.1:54094`），flutter_tester 与 runner 的本地 WebSocket 握手被代理拦截。设置 `NO_PROXY=127.0.0.1,localhost,::1` 后全部通过（已实测验证）。

> **建议**：在 `AGENTS.md` 的开发测试一节补充该环境要求，否则新人/AI 会话极易误判为"测试全红"。

### 3.3 依赖陈旧度

`flutter pub get` 报告 **52 个包有新版本但与当前约束不兼容**（`analyzer 12.1.0→14.4.0`、`file_picker 8.3.7→12.3.0`、`win32 5.15.0→6.4.0` 等）。跨大版本较多，建议排一次专项升级，避免累积到不可升级。

### 3.4 平台配置

`AndroidManifest.xml` `[已复核]`：仅 `INTERNET` + `REQUEST_INSTALL_PACKAGES` 两个权限，无冗余权限；未开 `usesCleartextTraffic`（Android 9+ 默认禁明文，符合预期）。但注意 §4.6：`update_models` 允许 `http://` 镜像，该风险在 Android 被系统默认阻断、在 Windows 不受限。

---

## 4. P1 严重问题（6 项）

### 4.1 三套容差常量互不一致，高片数下可误判通关

`[已复核]` 代码中存在**三套**归一化坐标容差，彼此无关联：

| 常量 | 位置 | 值 | 性质 |
|---|---|---|---|
| 吸附阈值 | `puzzle_engine.dart:80-88` + `jigsaw_puzzle_game.dart:1459-1467` | `min(1/cols,1/rows) × 0.40`（再叠加 48px 屏幕上限） | **随网格缩放** |
| 通关判定 | `puzzle_state.dart:69-75` | `epsilon = 0.035` | **绝对常量** |
| 吸附后坐标锁定 | `puzzle_engine.dart:237` | `dx <= 0.05 && dy <= 0.05` | **绝对常量** |

量化对比（1× 缩放、单格屏幕边长 < 120px 时，吸附阈值 ≈ `0.4/N`）：

| 网格 | 片数 | 格宽 `1/N` | 吸附阈值 `0.4/N` | 通关判定 `0.035` | 通关/吸附 |
|---|---:|---:|---:|---:|---:|
| 10×10 | 100 | 0.1000 | 0.0400 | 0.0350 | 0.88 ✅ |
| 12×12 | 144 | 0.0833 | 0.0333 | 0.0350 | **1.05 ⚠️** |
| 15×15 | 225 | 0.0667 | 0.0267 | 0.0350 | **1.31 ⚠️** |
| 20×20 | 400 | 0.0500 | 0.0200 | 0.0350 | **1.75 ⚠️** |
| 24×24 | 576 | 0.0417 | 0.0167 | 0.0350 | **2.10 ⚠️** |

难度档位确认 `puzzle_model.dart:70`：`square1x1` 的 `multipliers: [5,6,8,10,12,15,20,24]`，**最大 24×24 = 576 片**属正常可玩档位。

**后果链**：
1. 自 **12×12（144 片）起**，通关容差 > 吸附容差，即"碎片离正确槽位比吸附还远，却已判定为已就位"；
2. 且 `isSolved` 是**逐轴**判据（`|dx|<=0.035 && |dy|<=0.035`），等效欧氏半径最大 `0.035×√2 = 0.0495`，实际比上表更宽松；而吸附用的是**欧氏**距离（`puzzle_engine.dart:212-217`），两套度量口径也不统一；
3. `isSolved` 被 5 处关键逻辑消费：`computePlantedPieceIds`（`puzzle_engine.dart:102`）、`canSnapCluster`（`:139`）、进度 `solvedCount`（`jigsaw_puzzle_game.dart:232`）、提示选片（`:2584`）、通关判定（`:1993`、`:2511`）。

**可达触发路径**（不夸大，说明必要条件）：正常吸附成功后会走 `:228-243` 锁定为精确坐标（误差归零），因此常规游玩不会触发。触发需满足"碎片落在吸附容差之外、但在 0.035 容差之内"，这在两种情况下真实可达：
- `canSnapCluster` 返回 false 时（孤立内部碎片/未触边、未邻接已植入装配体）`:219` **明确拒绝吸附但位置仍可能落在 0.035 内**——设计上"不吸附"与"判定已就位"出现矛盾；
- 玩家拖动到接近但超出吸附半径后松手，且未触发邻居合并。

**建议**：将 `epsilon` 改为与吸附同源的 `min(1/cols, 1/rows) × k`（k ≈ 0.2，即吸附半径的一半），并统一为欧氏度量；同时复核 `:237` 的 0.05 是否应改为与吸附阈值联动。

### 4.2 级联合并只改 clusterId、不做平移对齐，且用绝对 epsilon

`[已复核]` `puzzle_engine.dart:438-450`：

```dart
if (dxErr <= epsilon && dyErr <= epsilon) {   // epsilon = 0.035，绝对常量
  ...
  for (var k = 0; k < result.length; k++) {
    if (result[k].clusterId == sourceId) {
      result[k] = result[k].copyWith(clusterId: targetId);  // 只改 id，不平移
```

对比阶段二正常合并路径（`:286-311`）是**先 `_translateCluster` 对齐再合并**的，级联路径却没有。后果：两个正交邻居在相对误差 ≤ 0.035（24×24 时 = 0.84 格宽）内即被"焊接"为同一刚体，且**残留偏移被永久固化**——此后整簇同步移动，错位再也无法修正，视觉出现裂缝。片数越高越明显。

**建议**：级联路径复用 `_translateCluster` 对齐后再改 id；`epsilon` 改为按格宽比例（同 4.1）。

### 4.3 下载落盘"先删旧文件再 rename"，异常路径造成新旧两空

`[已复核]` `content_http_client.dart:135-138`：

```dart
if (destFile.existsSync()) { destFile.deleteSync(); }
final finalFile = await partFile.rename(destinationPath);
```

若 `rename` 失败（Windows 上目标被杀软/索引服务占用、权限或跨卷），进入 `catch`（`:149-171`）删除 `.part` 后 rethrow——此时**旧文件已删、新文件被清**。

值得注意的是，这与项目自己的红线注释直接冲突（`main_content_pipeline.dart:442-443`）：

> `// P0-6（红线 R1）：此处不得预删旧图——downloadFile 经 .part 原子落盘，下载失败时旧图仍在；预删会制造"新旧两空"。`

**影响**（准确表述）：该图本地消失 → UI 降级为占位 → **下次同步会重新下载，属可自愈**，并非不可逆数据丢失；但在弱网/大图场景下表现为"已下载内容无故消失并重复下载"。

**建议**：改为"备份 → 落位 → 删备份"的 `swapFileAtomically`（项目已在 `main_content_pipeline.dart:709-712` 实现该函数，直接复用即可）。

### 4.4 zip 内容完整性校验形同虚设：`zipSha256` 定义了但零处校验

`[已复核]` 全 `lib/` 检索 `zipSha256` / `sha256`：

- `zipSha256` 仅出现在 `puzzle_event_item.dart`（`:18/55/106/218/243`）与 `puzzle_collection_item.dart`（`:25/77/126/267/296`）的**字段定义、`copyWith`、`toJson`**，**没有任何一处比较**；
- `crypto` 的实际使用仅两处：主线关卡图的 sha256（`main_content_pipeline.dart:722-730`）与更新包（`update_service.dart:277`）；
- `events`（`:318`）、`collections`（`:341`）、`daily`（`:111`）三条管线下载 zip 后**直接 `readAsBytes()` 解压**，无校验步骤；
- pack 网络导入连 sha256 字段都没有。

**影响**：manifest 已下发哈希却不校验，端到端完整性未闭环。需要说明威胁前提：三通道走 HTTPS（GitHub/Gitee/R2），实际利用需 MITM 或镜像被控；但**字段已存在而未使用**属明确的防护缺口，且成本极低。

**建议**：下载后校验 `zipSha256`，缺失时告警并支持配置强制；pack 侧补充哈希字段。

### 4.5 pack 导入缺解压上限，本地 ZIP 无体积闸

`[已复核]` 对比四条管线：

| 管线 | 条目数上限 | 落盘体积上限 | 累计解压上限 |
|---|---|---|---|
| events / collections / daily | ✅ `archive.length > 2000` 抛错 | ✅ 200MB（网络侧） | — |
| **pack（本地导入）** | ❌ 无 | ❌ 无（`pack_content_pipeline.dart:104` 直接 `readAsBytes()`） | ❌ 无 |

`pack_content_pipeline.dart:292` 虽有 `totalBytes += ...` 累加，但**该变量在循环后未参与任何判断**（`:297` 仅检查 `validImageFiles.isEmpty`）。ZipSlip 防护是有的（`:238` 过滤 `..` + `:249` 用 `p.basename`），这部分正确。

**影响**：本地导入恶意/损坏 ZIP 时内存与磁盘无上限。触发前提是用户主动导入，风险低于网络侧，但仍应补齐三重闸（体积 / 条目数 / 累计解压字节）。

### 4.6 `lib/update` 残留开发机硬编码路径，且 updater 执行前无校验

`[已复核]` `update_installer.dart:70-75`：

```dart
final candidatePaths = [
  targetUpdater,
  p.join(Directory.current.path, 'tools', 'windows', 'updater.exe'),
  r'C:\Home\Projects\mytools\tools\better-updater\target\release\updater.exe',
  r'C:\Home\Projects\mytools\tools\updater\rust\target\release\updater.exe',
];
```

命中任一候选即以 `Process.start(..., mode: detached)`（`:123-128`）执行，**无签名/哈希校验**。另有 `checkForCrashRecovery()`（`:42-48`）在每次更新检查时执行安装目录下的 `updater.exe`，同样无校验。

**影响**（准确表述，不夸大）：
1. 生产包残留开发者机器绝对路径，属隐私与合规问题（且 `:86` 的错误信息会把本机目录结构写入日志）；
2. 若安装目录非管理员可写（便携版 / 非 Program Files 安装），替换 `updater.exe` 即可在每次崩溃恢复时获得执行机会——**前提是攻击者已能写该目录**，非独立提权漏洞。

**建议**：删除硬编码绝对路径，仅保留安装目录与打包目录；对 `updater.exe` 增加 SHA256 白名单后再启动。

### 4.7 `studio/server.py` 静态目录路径穿越 + CORS 全开

`[已复核]`

**(a) 路径穿越** `server.py:625-631`：

```python
if path.startswith("/static/"):
    rel_path = path[len("/static/") :]
    target = STATIC_DIR / rel_path        # 无 .. 归一化、无包含性校验
    if target.exists() and target.is_file():
```

无 `resolve()`、`normpath` 或前缀比对，原生请求 `GET /static/../../../Windows/win.ini` 由 OS 解析 `..` 后可读任意文件。
（诚实说明：浏览器会先归一化 `..`，故主要被原生请求/脚本利用；且 `parsed.path` 未 `unquote`，`%2e%2e` 形式反而无效——两条缺陷互相掩盖，但仍是必须修的实现错误。）

**(b) CORS `*` + 零鉴权 + 允许根由请求参数指定** `server.py:574-577`：

```python
self.send_header("Access-Control-Allow-Origin", "*")
```

全文件无任何 `Origin`/`Host`/`Referer`/token 校验；而 `_resolve_image_path` 的允许根目录可由请求参数指定（`:1004-1011`）：

```python
dir_param = (qs.get("dir") or [""])[0].strip()
if dir_param:
    dp = Path(dir_param).resolve()
    if dp.is_dir(): allowed_roots.append(dp)
```

**影响**：用户在运行 studio 时浏览任意恶意网页，该页可发 `GET /api/file?dir=C:\Users\x\Documents&path=secret.txt`，因 `Access-Control-Allow-Origin: *` 而直接读到响应内容。

**缓解现状**（如实记录）：默认绑定 `127.0.0.1`（`:2504`，非 `0.0.0.0`），且 Windows 下关闭 `SO_REUSEADDR` + 设 `SO_EXCLUSIVEADDRUSE`（`:2391-2400`）防端口劫持——这两点是经过思考的加固，问题出在 CORS 与鉴权缺失。

**建议**：`_cors()` 改为仅回显白名单 Origin；非 GET 请求校验 `Origin`/`Host` 同源；`?dir=` 改为启动白名单或服务端会话固定根；`/static/` 加 `resolve()` + `STATIC_DIR in target.parents` 校验。

---

## 5. P2 中等问题（16 项）

> **复核范围说明**：以下条目中，`5.1 / 5.2 / 5.3 / 5.5 / 5.8 / 5.10 / 5.15 / 5.16` 已逐行回到源码核对；其余为交叉审查产出、未逐一复核，优先级判断请以实际代码为准。

### 数据一致性

| # | 问题 | 证据 | 说明 |
|---|---|---|---|
| 5.1 | `ProgressStore` 读-改-写无锁 | `progress_store.dart:449`→`510` | `game_page.dart:427-435` 的 autosave 是 fire-and-forget，与 `:601-623` 结算 `await` 路径交错即 lost update，星级/最佳时间/最少提示可能被旧值整体覆盖。项目已有 `_snapStatsLock`（`game_repository.dart:809`）可复用 |
| 5.2 | `EconomyService` 同样读-改-写无锁 | `economy_service.dart:142-143`、`:205-226` | `game_page.dart:667-689` 把发奖与成就评估 `Future.wait` 并行，与 achievement 共用 `app-state-v1`，并发可致金币回退/提示券超发 |
| 5.3 | 成就"先标记后发币" | `achievement_service.dart:536-538` | 先 `markClaimed` 再 `addCoins`：发币前崩溃则奖励永久丢失；且 `achievement_store.dart:181-191` 写盘失败仅记 warning 仍返回成功，重启后可重复领取。（与已有报告 D-3 同源，此处补充"写盘失败可重领"角度） |
| 5.4 | 快照目录无淘汰策略 | `snapshot_store.dart` 全文 | 只有 `delete/deleteAllFor/clearAll`，无 LRU/容量/时间淘汰。daily 的 canonicalId 每天一个新值（`canonical_id.dart:25-28`），长周期使用磁盘单调增长 |
| 5.5 | 反序列化对脏数据零容忍 | `progress_store.dart:724-728` | `?.map((e) => e as int)` 遇 `3.0` 或 `"64"` 即 TypeError，且 `init()` 仅 warning 后 `continue`，该条进度不在索引里，下次 `save()` 会被新记录覆盖 |
| 5.6 | 写盘 `unawaited` | `achievement_store.dart:88/96/110/126/139` | 一次性去重语义（markClaimed/addStarred）应 `await`；另 `getCounter/isUnlocked/isClaimed/hasStarred` 不触发 `init()`，漏调 `init` 会读到空缓存 |
| 5.7 | 删除绕过 `deleteRaw` | `favorite_store.dart:212`、`progress_store.dart:301` | 与 `storage_manager.dart:94-96` 的既定约定不符 |
| 5.8 | 原子替换崩溃窗口只清不恢复 | `atomic_replace.dart:100-104`、`temp_storage_manager.dart:113-115` | 先把 target rename 成 `.bak_<ts>` 再落位 temp，此窗口被杀则 `.bak_` 留存而 target 缺失；`sweepStaleBackupSiblings`（`atomic_replace.dart:62-86`）**只删不恢复**。数据来自网络可重新下载，但冷启动应"发现 bak 无 target 即回滚"而非删除 |
| 5.9 | 缓存 JSON 非原子写 | `events_content_pipeline.dart:527`、`collections_content_pipeline.dart:614`、`manifest_router.dart:134` | 均为 `writeAsString`，只有 `main_content_pipeline.dart:709-712` 走 `swapFileAtomically`。写一半崩溃 → 缓存截断 → 静默降级为空列表 |
| 5.10 | daily 管线缺空包守卫 | `daily_content_pipeline.dart:127-146` | 解压后不校验 `extracted == 0` 即 `promoteExtractDir`；而 `collections:371-397`、`events:345-367` 都有该守卫。可能产生"标记就绪但零关卡" |

### 网络与并发

| # | 问题 | 证据 | 说明 |
|---|---|---|---|
| 5.11 | 全项目无 `CancelToken` | 全 `lib` 检索 0 命中 | `app_content.dart:238-241/257-259/292-299` 用 `Future.timeout` 只丢弃 Future，底层 dio 仍跑到 `receiveTimeout`（默认 60s）。页面销毁后下载继续占用带宽并写盘 |
| 5.12 | Dio 实例分散，无全局并发闸门 | `content_manager.dart:47-83` | 管线未注入 httpClient 时各 `new ContentHttpClient()`；另有 `level_image_resolver.dart:26`、`download_manager.dart:27`。连接池不共享，并发下载无上限 |
| 5.13 | 远端 `id` 未净化即用于落盘路径 | `main_content_pipeline.dart:522-528`、`:563-579` | 仅 `replaceAll(':', '_')`，未过滤 `/ \ ..`。被篡改的 manifest 可用 `id: "../../../evil"` 写到沙盒外 |
| 5.14 | 磁盘缓存无配额 | `level_image_resolver.dart:62/162`、`download_manager.dart:125/223` | 无 LRU/配额；下架内容只标记不删（`events:206-222`、`collections:215-233`，该红线本身是对的），导致出口只剩用户显式删除 |
| 5.15 | Release 模式日志直写 `print` | `app_logger.dart:232-235` | `rec.level >= Level.INFO` 即 `print(line)`，生产环境 URL/路径/异常栈进 logcat/stdout，同设备其他应用可读。另 `:317-325` 落盘失败回灌 `_pendingLines` 无上限 |

### 发布流水线（`scripts/`）

| # | 问题 | 证据 | 说明 |
|---|---|---|---|
| 5.16 | Gitee Token 明文落盘到固定路径 | `gitee_publish.py:50-51` | `TEMP/_git_askpass.py` 写入含 token 的脚本且**从不清理**；`TEMP` 缺失时回落 `"."`（当前目录），有写进仓库并误提交的风险。应改 `tempfile.mkstemp()` + 0600 + `finally` 删除 |

**发布流水线值得肯定的部分** `[交叉审查]`：`release_app.py:1064-1129` 严格按"R2 上传 → HEAD 校验 → GitHub/Gitee 镜像 → 最后才切 `updates.json`"执行，镜像失败即中止、线上仍为旧版，可安全重试；`ledger.py:194-246` 状态门禁 + `reset_run` 逃生通道保证可重入；密钥全部走环境变量（全仓无硬编码 token）；两处 dry-run。**仅** 5.16 与下条需要修。

> 补充（P3）：`release_app.py:735-739` `_missing_assets` "同名视为同内容"，上次中断/截断的附件重跑时会被判定"已在"，导致三通道内容不一致。Gitee 侧已取到 size，应增加 size 比对。

---

## 6. P3 轻微与技术债（11 项）

1. **硬编码未翻译字符串** `[已复核]`：`daily_tab_view.dart:559` `'TODAY'`、`:1063` `'New'`、`home_tab_view.dart:914` `'New'`、`my_center_tab_view.dart:1049` `'By ${card.author}'`、`choose_background_sheet.dart:98` `'Color ${index + 1}'`。
2. **`lib/game/` 无资源释放路径** `[已复核]`：`jigsaw_puzzle_game.dart` 与 `puzzle_piece_component.dart` **完全没有** `dispose`/`onRemove` 覆写，2 个 `ValueNotifier`（含 `zoomNotifier`）未 dispose。Dart 层 GC 可回收 notifier，主要风险是 `ui.Image` 所有权分散在 `game_page.dart:1014` 与 576 个组件间，退出时理论存在 use-after-dispose 窗口——**待实测确认**。
3. **`rotateCluster` 缺陷（当前为死代码）** `[已复核]`：`puzzle_engine.dart:483-486` 包围盒初值 `minNx=1.0; maxNx=0.0`，整簇在左半区时 `maxNx` 恒为 0 → 旋转中心算错；`:499-507` 在归一化坐标直接做 `(x,y)→(-y,x)`，未做 H/W 比例换算。因 `rotationEnabled` 默认 false 且该函数无调用点，当前不可见，建议接线上线前修正或删除。
4. **吸附阈值各向异性** `jigsaw_puzzle_game.dart:1462-1466`：阈值统一用 `min(W,H)` 换算，但 nx 以 W 归一化、ny 以 H 归一化。非正方形画幅下长轴方向吸附半径被放大（2:3 时约 1.5×）。应返回 `(tx, ty)` 或改用椭圆判据。
5. **撤销语义边界**：纯移动不入栈（`jigsaw_puzzle_game.dart:2102` 仅 didSnap/didMerge 时 record）；`hintsUsed` 不退还 `[已复核]`（`:2560` `prevState.copyWith(hintsUsed: _boardState.hintsUsed)` 携带的是递增后的值），反复"提示→撤销"会持续拉低星级。
6. **提示先扣费后执行**：`game_page.dart:749-770`，`_game` 可能为 null（图片仍在解码）时照扣币。（已有报告 D-5 已列，此处确认代码位置一致）
7. **`AppCachedImage` 空路径回落示例图** `[已复核]` `app_cached_image.dart:69-72`：与 `my_center_tab_view.dart:293` 声明的"P0-1：失败一律返回 null，禁止以示例图替代"红线冲突，会出现"显示成功但数据缺失"。（已有报告 D-1 已列同一处代码）
8. **`daily_tab_view` build 内重计算** `[已复核]`：`:443-459` `_calculateStreak()` 最多 365 次 `getLevelProgress`，`:502-504` 在 build 内打日志，每次 setState 触发。（已有报告 U-9 已列）
9. **`FutureBuilder` future 在 build 中创建**：`collection_levels_page.dart:434-436`。（已有报告 D-13 已列）
10. **巨型文件职责膨胀**：`my_center_tab_view.dart` 1,296 行含 6 个 widget 类；`studio/server.py` 单 handler 最长 207 行（`:782`）；`scripts/build_v5_library.py` 2,769 行中约 1,900 行是字面量数据（建议外置为 JSON/YAML）。
11. **两套并行 Content Studio**：`scripts/packaging/server.py`(1,689) 与 `studio/server.py`(2,546) 功能重叠，前者仍是单线程 `HTTPServer` 且缺 `SO_EXCLUSIVEADDRUSE` 加固。应确认前者是否废弃。

---

## 7. `studio/` 与 `scripts/` 专项

### 7.1 git_guard 名不副实

`[交叉审查]` `studio/core/git_guard.py:6-10` 实际做的是：在 `<src_dir>/.studio` 建**独立** git 仓库，对 tags/ledger/logs 做版本化并在导出前后自动 checkpoint。**它不安装任何 git hook**（全仓检索 `hooks|pre-commit` 无安装逻辑），因此**无法阻止向主仓库误提交大文件/素材**。若期望的是提交拦截，需另做 `pre-commit`。建议改名（如 `studio_versioner`）或在文档显著位置说明。

该肯定的设计：`.gitignore` 采用托管区标记（`git_guard.py:41-42/249-281`），只替换标记之间内容，绝不吞掉用户自定义行；git 不可用时全部降级为 no-op 不阻塞业务。

### 7.2 测试覆盖分布

| 区域 | 用例数 | 覆盖情况 |
|---|---:|---|
| `studio/` | 136 | 覆盖 rollback/git_guard/ledger/image_proc/log_routing/frontend |
| `scripts/` | 11 | **仅** `test_release_app.py`。`ledger.py`（发布可重入核心）、`publish.py`、`verify_channels.py`、`check_local.py`、`deploy/validate_remote.py`、`build_v5_library.py`、`puzzle_quality_analyzer.py`、`verify_data.py` **全部零测试** |

发布可靠性核心无测试，建议优先补 `ledger.py` 的状态迁移用例。

### 7.3 其他

- `export_rollback.py:417-421`：`_restore_trash` 对单文件移动失败是 `except: continue` 静默跳过，随后 `shutil.rmtree(trash_dir)` 会销毁未能还原的产物 → release 产物永久丢失。建议仅当 restored 覆盖全部 trash 内容时才 rmtree。
- `scripts/release.py:51` 使用 `shell=True`（当前 4 个调用点均为字面量，暂无外部输入）。
- `scripts/packaging/server.py:1179` 临时文件名可预测且 `arc_name` 未过滤分隔符。

---

## 8. 值得肯定的工程实践（勿在这些处做"优化"）

1. **几何内核正确** `[交叉审查]`：`EdgeLayout` 让每条内部切割线只生成一次物理定义、邻居取 `complementary()`（`edge_layout.dart:149-163`），数学上保证公母扣零误差咬合——拼图项目最容易出错的地方做对了。
2. **重活全部卸载 Isolate** `[已复核]`：裁切走 `compute`（`thumbnail_generator.dart:57`）、超分走 `Isolate.run`（`image_upscaler.dart:52`）、ZIP 解码走 `compute`（`pack_content_pipeline.dart:210`），UI isolate 无阻塞。
3. **持久层损坏自愈分级清晰** `[交叉审查]`：`isCorruption` 区分格式损坏与瞬时 IO（`storage_manager.dart:42-53`）→ 隔离 `.corrupt-*` → 备份回滚 → 空库兜底 → 内存兜底，且损坏计数防死循环。全项目**零** `registerAdapter`/`@HiveType`，从根上规避了 typeId 冲突与嵌套 Map 退化崩溃。
4. **单飞收口质量高** `[已复核]`：`single_flight.dart:16-37` 用 `identical(inFlight[key], future)` 复核防 ABA（`:30-35`），并用 `.ignore()` 屏蔽 `whenComplete` 派生链避免未处理异步错误——细节到位；四条管线全部接入。
5. **`.part` 原子落盘 + 全异常路径清理**：`content_http_client.dart:96-171` 双 catch 分支都清理临时文件；空文件拒绝（`:121-123`）、200MB 落盘上限（`:125-132`）、镜像轮询（`:179-209`）。
6. **红线执行到位** `[交叉审查]`：远端内容缺失只标记下架、不删本地数据（`events:206-222`、`collections:215-233`），删除入口只有用户显式操作。
7. **版本比较正确** `[已复核]`：`update_service.dart:139/153` 用整型 `versionCode` 比较与 `minVersionCode` 强制判定，无字符串比较 `1.10 < 1.9` 的经典缺陷；`:277-298` 校验 SHA256 与 size。
8. **SoundService 设计优秀** `[交叉审查]`：固定 6 槽播放器池、世代号 `_generation` 作废在途回调、`dispose()` 由 `main.dart:62` 关窗接线。
9. **UI 资源释放与 mounted 检查普遍规范** `[交叉审查]`：victory_dialog 四个 AnimationController 全部 dispose；日志页、裁剪页、主页 Timer 均正确释放；异步间隙后 `mounted` 守卫覆盖良好。
10. **竞态防护手法成熟** `[交叉审查]`：`my_center_tab_view.dart:123-131` 的 `_reloadSeq` 代次校验、`log_viewer_page.dart:233/244` 的 `_clearEpoch`，均为正确实践。
11. **列表性能基线达标** `[交叉审查]`：全部网格/列表用 `SliverGrid`/`ListView.builder`，未发现长列表用 `children: [...]`。

---

## 9. 待确认（未下结论，需实测或作者确认）

1. `_applyBoardState`（`jigsaw_puzzle_game.dart:2351`）只校验 `rows/cols/pieces.length`，未校验 `seed`。若旧档 seed 与当前不同，`edgeLayout` 用新 seed 生成卡扣形状而存档坐标不变——需确认快照是否保证 seed 同源。
2. §6.2 的 `ui.Image` use-after-dispose 风险：Flutter 已提交帧持引擎引用，实际大概率安全，需实测确认。
3. `EdgeCurveDescriptor.maxOverhangRatio`（`edge_curve.dart:309`）与 `Overhang.fromEdges`（`piece_shape.dart:29`）两套口径，前者未查到调用点，疑似冗余。
4. `_mergeAllAdjacentClusters` 外层 `while(changed)` + 合并后从 `i=0` 重启，最坏 O(n³)。正常一次 drop 合并次数 ≤ 3，但大簇落地/hint 后可能劣化——需压测确认量级再定优先级。

---

## 10. 建议修复顺序

**第一批（本周）**——改动小、收益大：
1. §4.1 + §4.2 统一容差口径（吸附/通关/锁定三处联动，改 3 个常量）
2. §4.4 zip 下载后校验 `zipSha256`（成本极低，闭环完整性）
3. §4.3 `downloadFile` 改为备份-落位-删备份（复用已有 `swapFileAtomically`）
4. §4.6 删除 `update_installer.dart` 硬编码开发机路径
5. §4.7 `studio/server.py` 路径穿越 + CORS（两处十行级改动）

**第二批（本迭代）**：
6. §5.1 + §5.2 ProgressStore / EconomyService 串行锁（复用 `_snapStatsLock` 模式）
7. §5.3 成就改为"先发币成功后标记" + `markClaimed` 改 await
8. §5.16 Gitee token 改用 `tempfile.mkstemp()` + finally 删除
9. §5.10 daily 空包守卫、§5.9 缓存 JSON 统一原子写、§5.8 冷启动恢复 bak
10. §3.2 在 `AGENTS.md` 补充 `NO_PROXY` 测试环境要求

**第三批（排期）**：快照 LRU 淘汰（§5.4）、pack 三重解压闸（§4.5）、CancelToken 与 Dio 单例（§5.11/5.12）、release 日志脱敏（§5.15）、i18n 硬编码清理（§6.1）、巨型文件拆分与依赖升级（§6.10/§3.3）。

---

*报告生成：2026-09-16 23:28 (GMT+8)｜工具链：Flutter 3.44.8 / Dart 3.12.2｜所有 `[已复核]` 条目均已回到源码逐行核对*
