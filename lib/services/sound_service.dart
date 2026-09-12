// P1-4：服务层 best-effort：功能失败降级，不阻断主流程
// ignore_for_file: avoid_catches_without_on_clauses
import 'dart:async';
import 'dart:math';

import 'package:flame_audio/flame_audio.dart';
import 'package:flutter/widgets.dart';

import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';

/// 音效事件枚举，对应 `assets/audio/*.wav` 的语义映射
///
/// 保留原文件名不重命名，枚举做别名，避免资产链路断裂。
enum Sfx {
  /// 碎片吸附（磁吸）- 随机 glue1/2/3
  snap,

  /// 轻落位（未吸附）
  place,

  /// 小完成 sting
  clearShort,

  /// 普通胜利
  win,

  /// 大胜利（TrophySound）
  winBig,

  /// 华丽 jingle
  jingle,

  /// 主点击
  tap,

  /// 锁定/确认
  lock,

  /// 开关切换
  switchToggle,

  /// 旋转（预留）
  rotate,

  /// 预览切换（随机 preview1/2/3）
  preview,

  /// 提示
  hint,

  /// 错误否定
  negative,

  /// 边缘显
  edgesIn,

  /// 边缘隐
  edgesOut,

  /// 界面进入
  moveIn,

  /// 界面退出
  moveOut,

  /// 金币飞
  coinsFly,

  /// 金币消费
  coinsSpend,

  /// 单金币
  coinSingle,

  /// 数字跳变
  numbers,
}

/// 统一音效服务，内部自检 `GameRepository.soundEnabled`。
///
/// 使用 `flame_audio`（底层 `audioplayers`），与 Flame 原生契合。
/// 预加载在 [init] 中完成，失败不阻塞启动；未初始化时 [play] 静默。
/// 当前资产为纯 WAV（原始 27 个 `pcm_s16le 48kHz mono`），全平台统一，无需 OGG/WAV 双制与 Windows 编解码兜底。
class SoundService {
  SoundService._();

  static final SoundService instance = SoundService._();

  /// 快捷访问 `SoundService.instance`
  static SoundService get I => instance;

  final Random _rng = Random();
  bool _initialized = false;
  bool get isInitialized => _initialized;

  /// 已预加载的全部资产，与 `assets/audio` 实盘一致（27 wav）
  static const List<String> allAssets = [
    'clear-short.wav',
    'coins-fly.wav',
    'coins-spend.wav',
    'edges-in.wav',
    'edges-out.wav',
    'final.wav',
    'glue1.wav',
    'glue2.wav',
    'glue3.wav',
    'hint.wav',
    'jingle3.wav',
    'lock.wav',
    'move-in-long.wav',
    'move-out-long.wav',
    'negative.wav',
    'numbers.wav',
    'place.wav',
    'preview1.wav',
    'preview2.wav',
    'preview3.wav',
    'rotate.wav',
    'switch.wav',
    'tap.wav',
    'TrophySound.wav',
    'WidgetsCoinCollectSingle.wav',
    'win.wav',
    'WinSound.wav',
  ];

  // 固定容量复用播放器池（严格限制原生实例数，杜绝泄漏与流上限挤占）
  static const int _kPoolSize = 6;
  final List<SoundSlot> _pool = [];
  final Map<Sfx, int> _lastPlayMs = {};
  final _AsyncLock _lock = _AsyncLock();
  Completer<void>? _poolInitCompleter;
  int _generation = 0;

  /// 细粒度独立节流配置（毫秒），杜绝跨事件相互误吞与连击洪峰
  int _throttleMsFor(Sfx sfx) {
    switch (sfx) {
      case Sfx.snap:
        return 80;
      case Sfx.place:
        return 60; // 重点防拖拽未吸附落位抖动
      case Sfx.tap:
        return 70;
      case Sfx.switchToggle:
      case Sfx.lock:
        return 100;
      case Sfx.coinsFly:
      case Sfx.coinsSpend:
      case Sfx.coinSingle:
        return 200; // 批量成就解锁时防轰鸣
      case Sfx.preview:
      case Sfx.edgesIn:
      case Sfx.edgesOut:
        return 150;
      case Sfx.hint:
        return 300;
      case Sfx.win:
      case Sfx.winBig:
        return 1000;
      case Sfx.clearShort:
      case Sfx.jingle:
      case Sfx.rotate:
      case Sfx.negative:
      case Sfx.moveIn:
      case Sfx.moveOut:
      case Sfx.numbers:
        return 50;
    }
  }

  /// 音效实盘资产时长精准校准，避免 isBusy 窗口过长放大抢占率
  Duration _durationFor(Sfx sfx) {
    switch (sfx) {
      case Sfx.numbers:
        return const Duration(milliseconds: 100);
      case Sfx.place:
        return const Duration(milliseconds: 150); // 实盘 16ms，留足 150ms 缓冲
      case Sfx.snap:
        return const Duration(
          milliseconds: 200,
        ); // 实盘 27~40ms，留足 200ms 保证清脆吸附完整发声
      case Sfx.lock:
      case Sfx.switchToggle:
      case Sfx.tap:
      case Sfx.preview:
      case Sfx.rotate:
        return const Duration(milliseconds: 200);
      case Sfx.coinSingle:
        return const Duration(milliseconds: 250);
      case Sfx.edgesOut:
        return const Duration(milliseconds: 350);
      case Sfx.clearShort:
      case Sfx.edgesIn:
      case Sfx.negative:
        return const Duration(milliseconds: 400);
      case Sfx.moveIn:
        return const Duration(milliseconds: 500);
      case Sfx.moveOut:
        return const Duration(milliseconds: 600);
      case Sfx.coinsSpend:
        return const Duration(milliseconds: 1200);
      case Sfx.hint:
        return const Duration(milliseconds: 1300);
      case Sfx.win:
        return const Duration(
          milliseconds: 1500,
        ); // 实盘 win.wav 1233ms，设 1500ms 留足尾音
      case Sfx.coinsFly:
        return const Duration(milliseconds: 1500);
      case Sfx.jingle:
        return const Duration(milliseconds: 2000);
      case Sfx.winBig:
        return const Duration(milliseconds: 5000); // 实盘 TrophySound.wav 4767ms
    }
  }

  Future<void> _ensurePoolInitialized() async {
    if (_pool.isNotEmpty) return;
    if (_poolInitCompleter != null) {
      return _poolInitCompleter!.future;
    }
    final completer = Completer<void>();
    _poolInitCompleter = completer;
    try {
      final audioContext = AudioContextConfig(
        focus: AudioContextConfigFocus.mixWithOthers,
      ).build();
      for (var i = 0; i < _kPoolSize; i++) {
        final player = AudioPlayer();
        // 禁用每帧向原生平台查询播放进度的 FramePositionUpdater，彻底消除高频 MethodChannel 轮询与微任务开销
        player
          ..positionUpdater = null
          ..audioCache = FlameAudio.audioCache;
        await player.setAudioContext(audioContext);
        await player.setReleaseMode(ReleaseMode.stop);
        await player.setPlayerMode(PlayerMode.lowLatency);
        _pool.add(SoundSlot(i, player));
      }
      completer.complete();
    } catch (e, st) {
      AppLogger.sound.warning('init pool failed', e, st);
      _poolInitCompleter = null;
      completer.complete();
    }
  }

  /// 初始化并预加载全部音效资产。
  ///
  /// 原生播放器池采用懒加载策略：
  /// - 若用户开启了声音，启动后台异步预热建池；
  /// - 若用户静音，不创建原生播放器，节省 6 个音频通道与 EventChannel；首次需要发声时再按需建池。
  Future<void> init() async {
    if (_initialized) return;
    try {
      await FlameAudio.audioCache.loadAll(allAssets);
      _initialized = true;
      if (!_isTest && GameRepository.instance.soundEnabled) {
        unawaited(_ensurePoolInitialized());
      }
      AppLogger.sound.info(
        'preloaded ${allAssets.length} wav assets (lazy pool enabled)',
      );
    } catch (e, st) {
      AppLogger.sound.warning('preload failed', e, st);
      _initialized = true;
    }
  }

  bool get _isTest {
    try {
      return WidgetsBinding.instance.runtimeType.toString().contains('Test');
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  bool bypassTestGuard = false;

  /// 按事件播放音效（池化复用 + 串行选槽 + 锁外播放 + LRU 抢占 + 定时归还 + 超时熔断）。
  ///
  /// - 内部检查 `GameRepository.instance.soundEnabled`，静默开关实时生效
  /// - [ignoreMute] 为 true 时即使静音也播放（用于开关从开→关的反馈）
  /// - [volume] 可覆盖默认音量分级
  void play(Sfx sfx, {bool ignoreMute = false, double? volume}) {
    if (_isTest && !bypassTestGuard) return;
    if (!ignoreMute && !GameRepository.instance.soundEnabled) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final throttle = _throttleMsFor(sfx);
    final last = _lastPlayMs[sfx] ?? 0;
    if (now - last < throttle) {
      return;
    }
    _lastPlayMs[sfx] = now;

    final requestGen = _generation;
    unawaited(_dispatchPlay(sfx, requestGen: requestGen, volume: volume));
  }

  Future<void> _dispatchPlay(
    Sfx sfx, {
    required int requestGen,
    double? volume,
  }) async {
    if (_pool.isEmpty) {
      await _ensurePoolInitialized();
    }
    if (_pool.isEmpty || _generation != requestGen) return;

    SoundSlot? targetSlot;
    var currentSlotToken = 0;
    final file = _resolveFile(sfx);
    final vol = volume ?? _volumeFor(sfx);

    // 锁内仅执行纳秒级内存分配与状态占用，绝不把 player.play 放在锁内，杜绝排队堵死
    await _lock.synchronized(() async {
      if (_generation != requestGen) return;

      targetSlot = selectSlotForPlay(file);
      if (targetSlot != null) {
        targetSlot!.resetSync();
        targetSlot!.isBusy = true;
        targetSlot!.playedAtMs = DateTime.now().millisecondsSinceEpoch;
        targetSlot!.currentFile = file;
        currentSlotToken = targetSlot!.playToken;
      }
    });

    if (targetSlot == null || _generation != requestGen) return;

    final slot = targetSlot!;
    final token = currentSlotToken;

    // 调用前二次检查：若在锁释放至此的间隙被 stopAll() 或抢占，立刻放弃
    if (_generation != requestGen || slot.playToken != token) {
      slot.resetSync();
      return;
    }

    AppLogger.sound.fine(
      'play $file vol=$vol sfx=$sfx slot=${slot.id} token=$token',
    );

    try {
      // 超时熔断，防止平台通道 prepared 事件丢失导致槽位永久卡死。
      // 音效已前置到同步逻辑之前调用，正常情况下平台通道在毫秒级返回；
      // 800ms 足够覆盖极端 GC 抖动，同时避免长时间占用槽位。
      await slot.player
          .play(AssetSource(file), volume: vol, mode: PlayerMode.lowLatency)
          .timeout(const Duration(milliseconds: 800));
    } catch (e, st) {
      AppLogger.sound.warning(
        'play $file failed/timeout on slot ${slot.id}',
        e,
        st,
      );
      if (_generation == requestGen && slot.playToken == token) {
        await slot.stopAndReset();
      }
      return;
    }

    // 播放发起后检查：若在 await play 期间被外部 stopAll()，立即补发停止
    if (_generation != requestGen || slot.playToken != token) {
      unawaited(slot.player.stop().catchError((_) {}));
      return;
    }

    // 起播成功且代际有效，此时挂载安全占位保护期计时与完成监听。
    // 注意：自然播完只释放 isBusy 状态供后续复用，绝不调用 player.stop() 扼杀正在播放的尾音。
    final duration = _durationFor(sfx);
    slot.releaseTimer?.cancel();
    slot.releaseTimer = Timer(duration, () {
      if (_generation == requestGen && slot.playToken == token) {
        slot.isBusy = false;
        slot.currentFile = null;
      }
    });

    // 释放旧订阅返回的 Future 无需等待
    unawaited(slot.completeSub?.cancel());
    slot.completeSub = slot.player.onPlayerComplete.listen(
      (_) {
        if (_generation == requestGen && slot.playToken == token) {
          slot.isBusy = false;
          slot.currentFile = null;
        }
      },
      onError: (_) {
        if (_generation == requestGen && slot.playToken == token) {
          slot.isBusy = false;
          slot.currentFile = null;
        }
      },
    );
  }

  /// 槽位选取与 LRU 抢占策略：
  /// 1. 优先使用空闲槽位；
  /// 2. 若全忙，优先抢占最老发声的非胜利音效槽位；
  /// 3. 若全部为胜利音效，兜底抢占最老槽位。
  @visibleForTesting
  SoundSlot? selectSlotForPlay(String file) {
    for (final slot in _pool) {
      if (!slot.isBusy) {
        return slot;
      }
    }

    SoundSlot? oldestNonVictory;
    SoundSlot? oldestSlot;
    var minNonVictoryTime = 0x7fffffffffffffff;
    var minTime = 0x7fffffffffffffff;

    for (final slot in _pool) {
      if (slot.playedAtMs < minTime) {
        minTime = slot.playedAtMs;
        oldestSlot = slot;
      }
      final isVictory =
          slot.currentFile == 'win.wav' ||
          slot.currentFile == 'TrophySound.wav';
      if (!isVictory && slot.playedAtMs < minNonVictoryTime) {
        minNonVictoryTime = slot.playedAtMs;
        oldestNonVictory = slot;
      }
    }

    return oldestNonVictory ?? oldestSlot;
  }

  /// 立即停止所有活跃声音，取消归还计时，作废全部在途播放（代际失效）
  void stopAll() {
    _generation++;
    for (final slot in _pool) {
      final wasBusy = slot.isBusy;
      slot.resetSync();
      if (wasBusy) {
        unawaited(slot.player.stop().catchError((_) {}));
      }
    }
  }

  /// 销毁所有播放器实例并清空池
  /// 释放全部音频播放器（audioplayers 原生实例）。
  ///
  /// 由 main.dart 的 `onExitRequested`（点 X / Alt+F4）调用。
  /// 释放后 [_initialized] 复位，允许后续 [init] 重新建池（避免一次性失效）。
  Future<void> dispose() async {
    // 递增世代号：让所有在途的异步播放回调立即作废，等效于取消
    _generation++;
    for (final slot in _pool) {
      slot.resetSync();
    }
    final futures = _pool.map((s) => s.player.dispose()).toList();
    _pool.clear();
    _poolInitCompleter = null;
    _initialized = false;
    await Future.wait(futures);
    AppLogger.sound.info('SoundService disposed');
  }

  @visibleForTesting
  Duration durationFor(Sfx sfx) => _durationFor(sfx);

  @visibleForTesting
  int throttleMsFor(Sfx sfx) => _throttleMsFor(sfx);

  @visibleForTesting
  int get generation => _generation;

  @visibleForTesting
  int get poolCount => _pool.length;

  @visibleForTesting
  int get busyCount => _pool.where((s) => s.isBusy).length;

  @visibleForTesting
  void setupMockPool(int count) {
    _pool.clear();
    for (var i = 0; i < count; i++) {
      _pool.add(SoundSlot(i));
    }
  }

  @visibleForTesting
  List<SoundSlot> get testPool => _pool;

  /// 快捷：吸附
  void playSnap() => play(Sfx.snap);

  /// 快捷：点击
  void playTap() => play(Sfx.tap);

  /// 快捷：开关（带 ignoreMute，关前播一次）
  void playSwitchToggle() => play(Sfx.switchToggle, ignoreMute: true);

  /// 解析枚举到真实文件名，支持随机变体
  String _resolveFile(Sfx sfx) {
    switch (sfx) {
      case Sfx.snap:
        const variants = ['glue1.wav', 'glue2.wav', 'glue3.wav'];
        return variants[_rng.nextInt(variants.length)];
      case Sfx.place:
        return 'place.wav';
      case Sfx.clearShort:
        return 'clear-short.wav';
      case Sfx.win:
        return 'win.wav';
      case Sfx.winBig:
        return 'TrophySound.wav';
      case Sfx.jingle:
        return 'jingle3.wav';
      case Sfx.tap:
        return 'tap.wav';
      case Sfx.lock:
        return 'lock.wav';
      case Sfx.switchToggle:
        return 'switch.wav';
      case Sfx.rotate:
        return 'rotate.wav';
      case Sfx.preview:
        const variants = ['preview1.wav', 'preview2.wav', 'preview3.wav'];
        return variants[_rng.nextInt(variants.length)];
      case Sfx.hint:
        return 'hint.wav';
      case Sfx.negative:
        return 'negative.wav';
      case Sfx.edgesIn:
        return 'edges-in.wav';
      case Sfx.edgesOut:
        return 'edges-out.wav';
      case Sfx.moveIn:
        return 'move-in-long.wav';
      case Sfx.moveOut:
        return 'move-out-long.wav';
      case Sfx.coinsFly:
        return 'coins-fly.wav';
      case Sfx.coinsSpend:
        return 'coins-spend.wav';
      case Sfx.coinSingle:
        return 'WidgetsCoinCollectSingle.wav';
      case Sfx.numbers:
        return 'numbers.wav';
    }
  }

  double _volumeFor(Sfx sfx) {
    switch (sfx) {
      case Sfx.snap:
      case Sfx.place:
      case Sfx.tap:
      case Sfx.numbers:
        return 0.80;
      case Sfx.clearShort:
      case Sfx.preview:
        return 0.75;
      case Sfx.win:
        return 0.90;
      case Sfx.winBig:
      case Sfx.jingle:
        return 1;
      case Sfx.hint:
        return 0.85;
      case Sfx.negative:
        return 0.75;
      case Sfx.edgesIn:
      case Sfx.edgesOut:
      case Sfx.moveIn:
      case Sfx.moveOut:
        return 0.60;
      case Sfx.lock:
      case Sfx.switchToggle:
      case Sfx.rotate:
        return 0.70;
      case Sfx.coinsFly:
      case Sfx.coinsSpend:
      case Sfx.coinSingle:
        return 0.85;
    }
  }
}

/// 播放器池槽位实体，绑定单一 AudioPlayer 并管理其释放与归还生命周期
class SoundSlot {
  SoundSlot(this.id, [this.playerInstance]);
  final int id;
  final AudioPlayer? playerInstance;
  bool isBusy = false;
  int playedAtMs = 0;
  int playToken = 0;
  Timer? releaseTimer;
  StreamSubscription<void>? completeSub;
  String? currentFile;

  AudioPlayer get player => playerInstance!;

  /// 同步清空状态与计时器，递增 token 使在途回调失效
  void resetSync() {
    releaseTimer?.cancel();
    releaseTimer = null;
    unawaited(completeSub?.cancel());
    completeSub = null;
    isBusy = false;
    currentFile = null;
    playToken++;
  }

  /// 异步停止底层播放器并重置
  Future<void> stopAndReset() async {
    final wasBusy = isBusy;
    resetSync();
    if (wasBusy && playerInstance != null) {
      try {
        await player.stop();
      } catch (_) {}
    }
  }
}

/// 简易异步互斥锁，保障槽位选取、重置与播放状态更新串行安全
class _AsyncLock {
  Future<void>? _last;

  Future<T> synchronized<T>(Future<T> Function() fn) {
    final prev = _last;
    final completer = Completer<void>();
    _last = completer.future;

    Future<T> run() async {
      try {
        if (prev != null) {
          await prev;
        }
        return await fn();
      } finally {
        completer.complete();
      }
    }

    return run();
  }
}
