# 声音系统介绍

> 对应 `assets/audio/*.wav` 27 个原始 PCM 音效与 `lib/services/sound_service.dart` 事件驱动实现，底层 `flame_audio: ^2.12.2`（`audioplayers: ^6.8.1`），全平台统一 WAV

## 一、概述

- 资源：`assets/audio/` 27 个 `*.wav`（`pcm_s16le 48kHz mono` 原始文件，未转 OGG），`pubspec.yaml` 依赖段引入 `flame_audio: ^2.12.2`（传递依赖 `audioplayers 6.8.1`），assets 段声明 `assets/audio/` 目录自动收录
- 服务：`lib/services/sound_service.dart:1` 单例 `SoundService.I`，按**事件名** `Sfx` 播放，内部统一判断 `GameRepository.soundEnabled`，`WidgetsBinding.runtimeType.contains('Test')` 时静默（避免 `flutter test` 的 `MissingPluginException` 误报）
- 特性：多变体随机（`glue1/2/3`、`preview1/2/3`）、80ms 节流防爆音、音量分级（短促 0.8 / 胜利 0.9~1.0 / whoosh 0.6）、预加载失败不阻塞
- 决策：经评估 `flutter_soloud`（自带解码、低延迟）暂不引入；采用自主设计的固定容量 LRU 复用池（`_kPoolSize = 6`），彻底杜绝无界 `new AudioPlayer` 导致的句柄与 COM/SoundPool 流泄漏；当前 WAV 资产全平台统一，无需双格式与 Windows 编解码兜底

## 二、架构

```
GamePage / JigsawPuzzleGame / MainScreen Tab / Settings UI
        ↓  SoundService.I.play(Sfx.xxx)
SoundService
   ├─ 静音拦截 (读取 GameRepository.instance.soundEnabled 实时静默)
   ├─ 独立细粒度节流 (snap 80ms, place 60ms, tap 70ms, coinsFly 200ms, hint 300ms...)
   └─ 固定容量播放器池 (6 槽位 _SoundSlot)
         ├─ 空闲槽位分配 / LRU 非胜利音效抢占
         ├─ Random 变体 + 音量分级 + 预估时长自动归还 (兼容 Android SoundPool 无完成回调)
         └─ onPlayerComplete 平台提前归还双保险
```

- 初始化：`lib/main.dart` 中 `SoundService.I.init()` 仅预加载 27 个 wav 资源；6 个播放器池**按需懒建**（静音用户零原生播放器开销，首次发声才建池）
- 单例：`SoundService.instance` / `SoundService.I`，`_initialized` 哨兵，`_rng` 内部持有，`_isTest` 静默
- 生命周期：提供 `stopAll()`，在页面销毁与进入后台时立即切断挂起声音

## 三、API

```dart
enum Sfx {
  snap, place, clearShort,
  win, winBig, jingle,
  tap, lock, switchToggle, rotate,
  preview, hint, negative,
  edgesIn, edgesOut, moveIn, moveOut,
  coinsFly, coinsSpend, coinSingle, numbers,
}

class SoundService {
  static final SoundService instance = SoundService._();
  static SoundService get I => instance;
  Future<void> init(); // 仅预加载 allAssets；6 个复用播放器按需懒建
  void play(Sfx sfx, {bool ignoreMute = false, double? volume});
  void stopAll(); // 立即停止所有活跃声音并重置池状态
  Future<void> dispose(); // 完全释放播放器池
  void playSnap() => play(Sfx.snap);
  void playTap()  => play(Sfx.tap);
  void playSwitchToggle() => play(Sfx.switchToggle, ignoreMute: true);
}
```

- `enum` 避免字符串拼写错，保留原文件名不重命名，`_resolveFile()` 内映射 `.wav`
- `ignoreMute` 仅用于开关从开→关时“关前播一次”；其余一律受 `soundEnabled` 控制
- 与 `hapticEnabled` 正交，仅 SFX，无 BGM 通道

## 四、资源与事件映射

| 事件 `Sfx` | 文件 | 当前触发点 | 备注 |
|---|---|---|---|
| `snap` | `glue1/2/3.wav` 随机 | `lib/game/jigsaw_puzzle_game.dart:2100` 拖拽吸附/合并成功、`:2563` 提示吸附 | 80ms 节流 |
| `place` | `place.wav` | `lib/game/jigsaw_puzzle_game.dart:2112` 未吸附轻放回棋盘 | 轻落位 |
| `clearShort` | `clear-short.wav` | 预留 | 集群小完成，可与 snap 二选一 |
| `win` | `win.wav` | `lib/pages/game_page.dart:578` 普通规格胜利 |  |
| `winBig` | `TrophySound.wav` | `lib/pages/game_page.dart:578` `pieces>=100 \|\| stars==3` 时大胜利 | 单播，不延迟叠放；`final.wav`/`WinSound.wav` 备用 |
| `jingle` | `jingle3.wav` | 预留 | 成就/每日二段庆祝 |
| `tap` | `tap.wav` | 核心页面主点击 + `lib/pages/main_screen.dart:99,112,126` 底部 Tab 切换 | 仅核心页面与 Tab，切 Tab 时 `idx!=current` 才播 |
| `lock` | `lock.wav` | 预留 | 锁定/确认 |
| `switchToggle` | `switch.wav` | `lib/pages/settings_page.dart:116,119` 开关 | `ignoreMute:true` |
| `rotate` | `rotate.wav` | 预留 | `rotationEnabled=false` |
| `preview` | `preview1/2/3.wav` 随机 | `lib/pages/game_page.dart:1137` 底图透视、`:1155` 原图切换 |  |
| `hint` | `hint.wav` | `lib/pages/game_page.dart:771` 智能提示 |  |
| `negative` | `negative.wav` | 预留 | 错误否定 |
| `edgesIn` | `edges-in.wav` | `lib/pages/game_page.dart:1074` 仅显示边缘开 |  |
| `edgesOut` | `edges-out.wav` | 同上关 |  |
| `moveIn` | `move-in-long.wav` | `lib/pages/game_page.dart:789` 壁纸选择器进入 |  |
| `moveOut` | `move-out-long.wav` | 预留 | 弹窗退出 |
| `coinsFly` / `coinsSpend` / `coinSingle` | `coins-fly/spend/WidgetsCoinCollectSingle.wav` | `coinsFly` 已接入成就解锁（`lib/services/achievement_service.dart:391` 等）；`coinsSpend` / `coinSingle` 预留 | 金币到账动画 |
| `numbers` | `numbers.wav` | 预留 | 5ms 极短 |

音量：短促 0.80、预览/否定 0.75、胜利 0.90~1.0、whoosh 0.60、开关/锁定 0.70、金币 0.85。

## 五、当前埋点

- `lib/main.dart:164` `SoundService.I.init()` 预加载（行号随 main.dart 演进漂移，以符号 `SoundService.I.init` 为准）
- `lib/game/jigsaw_puzzle_game.dart:2100` 吸附/合并、`:2112` 轻放、`:2563` 提示吸附
- `lib/pages/game_page.dart:578` 胜利（大/小规格）、`:1039` 返回键、`:1214` PopScope 返回、`:1074` 边缘筛选、`:771` 提示、`:1137` 底图透视、`:1155` 原图、`:1175` 整理、`:789` 壁纸选择器
- `lib/pages/settings_page.dart:116,119` 设置开关
- `lib/pages/main_screen.dart:99` onSwitchToDaily、`:112` onGoExplore、`:126` 底部 `NavigationBar` 切 Tab（`tap`，`idx!=current` 时播）
- `lib/services/achievement_service.dart:391` 成就解锁 `coinsFly`
- `lib/widgets/victory_dialog.dart:193` 胜利弹窗星星 `snap`

静音统一：`play()` 首行 `if (!ignoreMute && !GameRepository.instance.soundEnabled) return;`，开关音效先播后改值。

## 六、注意事项

- 全平台统一 WAV，无需 Windows `Web Media Extensions` 与 OGG→WAV 动态切分，`flame_audio` 的 `lowLatency` 对 PCM 最稳；`assets/audio/*.ogg` 已清理
- 测试环境：`WidgetsBinding.runtimeType.contains('Test')` 直接静默，`then(onError)` 双保险，不阻断 `flutter test`
- 仅 SFX，不引入 `FlameAudio.bgm`，与触感 `HapticFeedback` 独立；`flutter_soloud` 已评估暂缓，若后续需 3D/低延迟可再切
- 参考分析：`temp/sound_effects_analysis_20260829.md:19`

## 七、校验

- `flutter analyze` 1 warning（既有 `_showPauseMenu unused`）无 Error
- `flutter test` 103 passed
- `flutter build windows --debug` 成功
