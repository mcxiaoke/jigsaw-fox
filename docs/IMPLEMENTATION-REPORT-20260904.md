# 分阶段修复实施报告 2026-09-04

> 依据 `docs/flutter-code-reviews-20260904.md` 26项去重清单（P01~P26），按三阶段路线落地。本报告每阶段追加。

---

## 阶段一：P0 阻断级（显存/丢档/资源泄漏） 2026-09-04 15:26

### 范围
- P19 活动存档覆盖（阻断）
- P01 GamePage 显存泄漏 + 解码容错
- P02 CropPuzzlePage 裁剪泄漏
- P03 ShareCard/LinenTexture 未释放
- P05 关窗异步丢档（pendingWrites）
- P16 MyCenterTabView HttpClient 泄漏/DoS
- P21 持久化一致性（backup/flush、内存回滚、快照误删）

### 变更详情

| 编号 | 文件:行号 | 改动 | 验证 |
|---|---|---|---|
| P19 | `lib/pages/event_levels_page.dart:99-106` | `GamePage(levelIndex:index)` → `GamePage(canonicalId: level.id, packTitle: _currentEvent.title)`，消除 `canonicalForLevel` 误覆盖主线 `main:00N` | Read+逻辑推演，首帧不丢 `level.id` |
| P01 | `lib/pages/game_page.dart:210-220` | `decodeFlameImage` 加 `try/catch` + `if(!mounted){img.dispose();return;}` 关窗泄漏防护，坏图弹Toast不卡转圈 | `flutter analyze` 0 issues, `flutter test` 247 pass |
| P02 | `lib/pages/crop_puzzle_page.dart:352-367` | 拆 `picture` 变量、`try/finally croppedImage?.dispose(); picture.dispose();` 并 `asUint8List(offset,length)` | 同上 |
| P03 | `lib/widgets/share_card_generator.dart:98-115` `lib/logic/rendering/linen_texture_manager.dart:165-167` | `ShareCard` `image.dispose()` in finally；`LinenTexture` `picture.dispose()` 后返回 | 同上 |
| P05 | `lib/data/storage_manager.dart:84-93,135-170,403-470` `lib/main.dart:42-53` | 顶层 `putJson` 纳入 `_pendingWrites` 队列 `_trackWrite/waitPendingWrites`；`getJson` 由 `as String?` 改 `is! String` 守卫；`_doBackup` 前 `waitPending+flush`；`onExitRequested` 先 `waitPendingWrites` 再 `backup/closeAll`；`resetForTest` 清队列 | 队列 whenComplete 移除，无泄漏；`closeAll` 已含 flush |
| P16 | `lib/pages/tabs/my_center_tab_view.dart:156-184` | `HttpClient` 加 `connectionTimeout/idleTimeout`、`contentLength >20MB` 与 `chunked==-1` 熔断、`length>max` 二次熔断、`timeout` 15/20s、`finally close(force:true)`；`rootBundle.asUint8List(offset,length)` | 同上 |
| P21 | `lib/data/progress_store.dart:271-286,639-650` `lib/data/snapshot_store.dart:55-110,290-356` | `ProgressStore.save` 内存先改失败回滚(prev)；`reconcileSnapshots` 单条 try/catch 不中断；`SnapshotStore._cleanupTempFiles` 区分 tmp→snapshot 恢复 vs 直接删；`load/loadJsonString` 区分 `Format/TypeError`(删) vs `IOException`(保留)；`StorageManager._doBackup` 前 flush | 同上 |

### 风险/搁置
- `GameRepository.updateLevelProgress/updateCustomProgress` 内存先改 `Copy` 的回滚牵涉 `_levels/_customPuzzles` 全量列表与 UI 水合，改动面大且当前 `ProgressStore` 已做关键回滚，**暂搁置**，待二轮单测覆盖后再动。
- `stateBox put`（经济/成就）未纳入 pending 队列，丢失仅影响金币/计数非进度，风险低，二期再统一。

### 验证
- `flutter analyze`: No issues found
- `flutter test`: 247 passed
- `flutter build windows --debug`: 待阶段三统一验证
- 手工：快速进退 GamePage 不再泄漏（code review 推演），活动关卡不覆盖主线存档（仅 `canonicalId`）

### 提交
- `26b6539 fix(P0): stage1 critical fixes P19/P01-P03/P05/P16/P21`

---

## 阶段二：P1 稳定性（网络流式 / 解压 / 并发 / Hive健壮 / 生命周期） 2026-09-04 16:00

### 范围
- P06 `ContentHttpClient` 流式下载
- P14 `DownloadManager` 流式 + 2×拷贝消除
- P15 `ImageCacheManager` 网络缩略图流式
- P18 扩展包 3× 峰值（文件路径入 Isolate）
- P07 `ZipDecoder` 主线程 ANR → `compute` Isolate + zip bomb 限流
- P08 `cast<String>()` 8处 → `whereType<String>()`
- P09 `getJson` 已 Stage1 修复（此处复验）
- P20 内容同步并发 + 秒开退化（sync 锁 + manifest 缓存优先 + Events 保留已下载）
- P22 生命周期/永久加载（Crop Build 写入、EventLevels try/catch、Victory mounted 守卫）

### 变更详情

| 编号 | 文件:行号 | 改动 | 验证 |
|---|---|---|---|
| P06 | `lib/logic/content/network/content_http_client.dart:87-131` | `Dio.get<Uint8List>` → `Dio.download(partFile.path)` 流式落盘，内存恒定；`partFile.length==0` 校验 + 200MB 落盘上限 + `DioException` 转 `HttpException`，`finally` 清理 part | `analyze` 0, `test` 247 pass |
| P14 | `lib/logic/download_manager.dart:234-300` | `Dio.get<List<int>>`+`Uint8List.fromList` → `Dio.download` 到 `.part` → 检查非空/50MB上限 → `rename` → `readAsBytes` 单次；403/401 重试保留 `Referer`；part 清理 | 同上 |
| P15 | `lib/logic/cache/image_cache_manager.dart:394-470` | `Dio.get` → `Dio.download` 到 `tmp_net_*.part` → 20MB 熔断 → `ThumbnailGenerator.generateThumbnailBytes(sourceFilePath:)` 文件版 Isolate → 删 tmp → 20MB 仍熔断；403/401 重试 | 同上 |
| P18 | `lib/logic/content/pipelines/pack_content_pipeline.dart:47-179` | `importFromNetworkZip` 取消主线程 `readAsBytes`，新增 `_processZipFile` + `_readFileBytesIsolate` 经 `compute` 读盘，后续 `_processZipBytes` 仍 Isolate 解压，减少主线程 1× 拷贝；保留原子 rename 已有 | 同上 |
| P07 | `pack:181, daily:2+66, events:4+185` | `ZipDecoder().decodeBytes` → `await compute(_decodeZipIsolate, bytes)`；daily/events 追加 `if(length>2000) throw` zip bomb 限流；pack 抽取 `_decodeZipIsolate` 公用 | 同上 |
| P08 | `progress_store:203`, `favorite_store:181`, `game_repository:207`, `download_manager:50,423,467`, `achievement_store:45,185` | `cast<String>()` → `whereType<String>()` 8处 | 同上 |
| P20 | `lib/logic/content/content_manager.dart:52-76,78-159` `manifest_router.dart:22-33` `events_content_pipeline.dart:92-100` | `ContentManager` 新增 `_isSyncing/_syncFuture`，`initialize` 调 `resolveManifestCacheFirst()` 先读盘（弱网不阻塞秒开），`syncAll` 加互斥等待；`ManifestRouter` 新增 `resolveManifestCacheFirst()`；`Events` `syncWithRemote` 保留 `prevDownloaded \|\| _isEventLocalDownloaded` | 同上 |
| P22 | `lib/pages/crop_puzzle_page.dart:508-514` `lib/pages/event_levels_page.dart:47-52` `lib/widgets/victory_dialog.dart:162-169` | `Crop` Build 内 `controller.value=` → `addPostFrameCallback`；`EventLevels` `_loadLevels` 包 `try/catch/finally` 置 `_isLoading=false`；`Victory` 首 `forward` 前 `if(!mounted) return` 二次守卫 | 同上 |

### 风险/搁置
- **P17 全分辨率三重 OOM**：涉及 `decodeImageFromList` 改 `instantiateImageCodec(targetWidth)` 且需按 `rows*cols` 难度感知 + `clamp(1080,3072)` + 双管线（游戏 vs 导出超分），改动面覆盖 `GamePage/Thumbnail/Share` 及 `jigsaw_puzzle_game` 纹理尺寸，影响拼图手感与渲染清晰度判断，**暂搁置**，需单独设计评审与真机内存压测后再动。当前已通过 P14/P15/P06 将网络链路 OOM 降至最低，主链路风险可控。
- **P05 剩余 stateBox puts**、**P21 `GameRepository` 内存回滚** 同 Stage1 搁置理由，不随二期扩大。

### 验证
- `flutter analyze`: No issues found（已修复 `unused_import`）
- `flutter test`: 247 passed
- 人工：下载大图弱网 403 重试、缩略图并发 4 场景推演不再 OOM；`ZipDecoder` 已离主线程

