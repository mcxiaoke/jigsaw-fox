# JigsawFox 声音系统深度重构与全链路故障收口总结报告

- **日期**：2026-09-04
- **状态**：已落地、全量单测通过、构建通过、准备提交
- **影响范围**：`lib/services/sound_service.dart`, `lib/pages/game_page.dart`, `lib/pages/settings_page.dart`, `lib/widgets/victory_dialog.dart`, `test/services/sound_service_test.dart`

---

## 一、背景与问题综述

在此前版本中，声音系统暴露出严重的偶发与必现故障：
1. **连响与静默交替**：快速拖动或频繁拼放碎片时，声音突然全部静默；过一段时间或切出切入后台时，积压的声音瞬间集中连响并伴随界面卡顿；
2. **退主界面延迟残余补播**：拼图通关或返回主界面瞬间，此前未播出的音效与金币音在退出后数秒仍持续补播；
3. **吸附与落位音大部分时候消失**：两个碎片相对吸附或碎片吸附到棋盘边缘槽位时，吸附音（`snap`）几乎听不到或偶发性丢失；
4. **胜利 sting 尾音被截断**：拼通时的胜利音效（`win.wav`）在约 0.9s 时被强制掐断，末尾 ~330ms 和弦消散缺失；
5. **静音用户依然承担开销**：关闭声音的用户在启动应用时依然会被动创建多个原生播放器，占用操作系统音频流与平台通道；
6. **手势防重入与主线程积压**：返回键/左滑快速连续触发时，多轮并发的 Hive 快照写入与音频处理导致主线程卡顿乃至 ANR 黑屏。

---

## 二、深层根因与时序链条剖析

经过对代码、实盘音频文件、PlatformChannel 传输时延以及操作系统原生音频特性的多轮核验，锁定了以下 5 条核心故障链：

### 1. 原生实例无界线性泄漏（P0 根因）
- **代码缺陷**：此前直接调用 `FlameAudio.play(lowLatency)`，底层 `audioplayers` 每次发声均 `new AudioPlayer()`，并且火后即忘、永不 `dispose()`。
- **平台击穿**：
  - **Android**：在 `PlayerMode.lowLatency` 下采用 `SoundPool`，Android 系统的 `SoundPool` 最大并发流限制为 32 路（`MAX_STREAMS=32`）。超过 32 个流后，系统静默抛弃新请求，导致“静默”；
  - **Windows**：每个实例持有一组 COM `MFPlatform` 与 `MediaEngineWrapper`，并向 Flutter 引擎注册每帧回调 `FramePositionUpdater`。实例数达到数十甚至上百后，Windows Media Foundation 线程池耗尽，音频准备进入 30s 超时死锁。

### 2. 定时器超前赛跑与双重掐断自毁闭环（短音效丢失根因）
通过读取实盘 WAV 文件 Header 发现：`glue1.wav`（39.9ms）、`glue2.wav`（27.1ms）、`glue3.wav`（27.7ms）、`place.wav`（16.0ms）均为极短音频。
- **旧逻辑漏洞**：
  1. `_durationFor(Sfx.snap)` 误配为 60ms 极值；
  2. `releaseTimer = Timer(60ms, ...)` 在执行 `await slot.player.play(...)` **之前** 就已开启计时；
  3. 在 Windows/Android 平台上，跨线程通信与底层音频引擎准备播放的往返耗时（PlatformChannel latency）正常情况下即为 **40ms ~ 80ms**；
  4. 当一次跨通道调用耗时 65ms 时：
     - **第 60ms**：定时器超时到达，触发 `slot.stopAndReset()`，向原生层发送 `player.stop()` 并将 `slot.playToken` 加 1；
     - **第 65ms**：`await play` 终于返回，紧接着检查 `slot.playToken != token` 成立，判定在途被取消，**再度补发一次 `player.stop()`**；
  5. **结果**：吸附音刚到扬声器门口就被双重 `stop()` 掐死，导致碎片吸附和边缘吸附“大部分时候没有”。

### 3. 全局锁内等待 I/O 导致的排队堵死
- 此前引入的互斥锁将 `await player.play(...)` 包裹在锁内。一旦底层平台通道丢失 prepared 事件（audioplayers 默认 30s 超时），整个队列被堵死，后续所有发声与 `stopAll()` 均排在队尾无法执行。

### 4. 胜利音定时器过早截尾
- 实盘 `win.wav` 为 78,978 字节（32kHz 单声道 16bit），真实物理时长为 **1.233s**。
- Android `SoundPool` 底层不回调 `onPlayerComplete`，槽位回收必须依赖定时器。此前定时器设为 900ms，在 0.9s 时主动 `player.stop()`，直接截断了最后 330ms 的和弦尾音。

### 5. 返回手势未防重与页面退出音频未掐断
- 返回键与 `PopScope` 连点并发多次执行全盘快照 JSON 编码与 Hive 写盘；
- 退出页面时未调用统一的停止接口，积压在各通道和锁队列中的在途播放继续向喇叭输出。

---

## 三、系统重构核心架构设计

针对上述所有根因，对 `SoundService` 及交互组件实施了彻底重构：

```
                      +-----------------------------+
                      |   GamePage / UI / Dialog    |
                      +-----------------------------+
                                     |
                                     v
                      +-----------------------------+
                      |     SoundService (I)        |
                      |  - 独立细粒度节流表         |
                      |  - 全局代际 _generation     |
                      |  - 懒加载池 _ensurePool     |
                      +-----------------------------+
                                     |
                         [ 微秒级内存锁 _lock ]
                                     |
                                     v
                 +---------------------------------------+
                 | 6 实例固定复用池 (List<SoundSlot>)    |
                 | - Slot 0 ~ 5 (低延迟 / 循环复用)      |
                 | - 优先挑选空闲槽位                    |
                 | - 全忙时 LRU 抢占最早非胜利槽位       |
                 +---------------------------------------+
                                     |
                       [ 释放全局锁，出锁异步播放 ]
                                     |
                                     v
                 +---------------------------------------+
                 | 异步底层出声 (带超时熔断, 现为 800ms)  |
                 | - play前双重代际/Token检查            |
                 | - play成功后才挂载释放计时器          |
                 | - 自然到期仅释放 isBusy (免调 stop)   |
                 +---------------------------------------+
```

### 1. 固定 6 槽位常驻复用池（`List<SoundSlot>`）
- 彻底废除每声新建 `AudioPlayer` 的无界泄漏模式；
- 池大小严格锁定为 6（`_kPoolSize = 6`），原生音频句柄数恒定有界，远低于 Android 的 32 流上限与 Windows 线程池阈值；
- 统一配置 `AudioContextConfig(focus: mixWithOthers)`，避免与系统其他音频产生独占冲突。

### 2. 细粒度同步锁（选槽即释放）
- `_AsyncLock` 仅包裹微秒级内存槽位挑选、状态标记与代际递增，**锁内绝不调用 `player.play()` 底层 I/O**；
- 选定槽位后瞬间释放全局锁，后续音效请求毫无阻碍，彻底消除排队堵死。

### 3. 全局代际与槽位 Token（前后双重守卫）
- `SoundService` 维护全局 `_generation`，每个 `SoundSlot` 维护独立的 `playToken`；
- 离开页面调用 `stopAll()` 时，立即 `_generation++`；
- 槽位在出锁后发起底层 `play` **前**，以及 `play` 返回 **后**，进行双重代际比对：
  - 发起前失效：直接 `slot.resetSync(); return;`，绝不起播；
  - 发起后失效：立即补发 `player.stop()` 刹车；
- 彻底消灭退出页面后延迟补播的顽疾。

### 4. 计时器时序纠正与“自然归还免调 stop”
- **时机后移**：`releaseTimer` 移至底层 `await slot.player.play(...)` **起播成功后**才启动计时，跨通道通信时延不再扣减音频时长；
- **免调 stop**：归还定时器与 `onPlayerComplete` 回调只执行 `slot.isBusy = false; slot.currentFile = null;`，**绝对不调用 `player.stop()`**！
- 短音频播完采样数据后扬声器自然静音，免调 stop 确保尾音完整、绝无腰斩；仅在被新音效抢占或主动 `stopAll()` 时才执行底层 stop。

### 5. 时长与节流安全期全面实测校准
根据实盘 27 个 WAV 的真实物理采样时长（Python 读取 Header），留足安全保护期：
- `snap`: 200ms (真实 27~40ms，留足 200ms 保证清脆完整)
- `place`: 150ms (真实 16ms)
- `tap / lock / switchToggle`: 200ms
- `win`: 1500ms (真实 1233ms，彻底消除截尾)
- `winBig`: 5000ms (真实 4767ms)
- 独立节流：`snap 80ms`, `place 60ms`, `tap 70ms`, `coinsFly 200ms`, `hint 300ms`, `win 1000ms`。

### 6. 静音用户零成本懒建池
- `init()` 中检测 `soundEnabled`，静音用户完全不创建原生播放器实例，节省 6 个 WAV 解码通道与 EventChannel；
- 首次需要发声且开启声音时，通过并发安全的 `Completer` 懒初始化池；并在 `catch` 异常时重置 `_poolInitCompleter = null`，支持故障自愈重试。

### 7. 生命周期与页面交互收口
- **剥离 `inactive`**：`didChangeAppLifecycleState` 仅在 `paused / hidden / detached` 时调用 `stopAll()` 与快照保存，Android 下拉通知栏与权限弹窗等瞬时失焦不再误掐胜利音；
- **设置页即刻安静**：用户关闭声音开关时先执行 `stopAll()` 掐灭正在播放的声音，再播放关前切换反馈音；
- **胜利弹窗监听精准注销**：具名方法注册监听，`dispose()` 时精准 `removeListener`，移除星星发声 `ignoreMute` 尊重用户偏好；
- **返回防重入**：`_isPopping` 在异常或未退出时安全回退 `_isPopping = false`，杜绝返回死锁；`_handleSolved` 使用 `Future.wait` 统一强类型捕获结算异常。

---

## 四、实测校验数据

| 验证环节 | 执行命令 | 结果数据 | 状态 |
| :--- | :--- | :--- | :--- |
| **代码静态分析** | `flutter analyze` | **0 issues found** (0 warning, 0 error) | PASS |
| **全量单元测试** | `flutter test` | **259 passed** (原有 247 项 + 新增 12 项行为单测全绿) | PASS |
| **Windows 构建** | `flutter build windows --debug` | 19.4s 成功编译生成 `JigsawFox.exe` | PASS |
| **真实时间变更日志** | `docs/CHANGES-20260904.md` | 已在顶部追加 GMT+8 详细记录 | PASS |

---

## 五、后续扩展与维护避坑规范

1. **绝对禁止在自然播放归还时调用 `player.stop()`**：
   音频自然播放完毕即静音，调用 `player.stop()` 在跨平台通道上存在调度延迟，极易引发短音效被掐断或产生无谓的 IPC 通道负载；
2. **绝对禁止在全局互斥锁内 await 底层 I/O**：
   锁只用于保护内存槽位的扫描与状态分配，耗时应在微秒级；所有 `player.play`、`player.stop` 均必须在出锁后执行；
3. **新增音效资产规范**：
   若后续增加新音效，须在 `Sfx` 枚举、`allAssets`、`_resolveFile`、`_volumeFor`、`_throttleMsFor` 与 `_durationFor` 中完整注册，并为其留出比物理时长宽 `100ms ~ 300ms` 的保护期。
