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
- Stage1 commit 待执行（见 git log）

---
