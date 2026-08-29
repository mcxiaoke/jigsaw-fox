import 'dart:math';

import 'package:flame_audio/flame_audio.dart';
import 'package:flutter/widgets.dart';

import '../data/game_repository.dart';

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

  // 节流：glue/snap 类 80ms 内不重复叠放
  static const _snapThrottleMs = 80;
  int _lastSnapMs = 0;

  /// 初始化并预加载全部音效。
  ///
  /// 在 `main()` 中 `GameRepository.init()` 之后调用：
  /// ```dart
  /// await SoundService.I.init();
  /// ```
  Future<void> init() async {
    if (_initialized) return;
    try {
      await FlameAudio.audioCache.loadAll(allAssets);
      _initialized = true;
      debugPrint('[SoundService] preloaded ${allAssets.length} wav assets');
    } catch (e, st) {
      debugPrint('[SoundService] preload failed: $e\n$st');
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

  /// 按事件播放音效。
  ///
  /// - 内部检查 `GameRepository.instance.soundEnabled`，静默开关实时生效
  /// - [ignoreMute] 为 true 时即使静音也播放（用于开关从开→关的反馈）
  /// - [volume] 可覆盖默认音量分级
  void play(
    Sfx sfx, {
    bool ignoreMute = false,
    double? volume,
  }) {
    if (_isTest) return;
    if (!ignoreMute && !GameRepository.instance.soundEnabled) return;

    if (sfx == Sfx.snap) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastSnapMs < _snapThrottleMs) return;
      _lastSnapMs = now;
    }

    final file = _resolveFile(sfx);
    final vol = volume ?? _volumeFor(sfx);
    FlameAudio.play(file, volume: vol).then((_) {}, onError: (Object e, StackTrace st) {
      debugPrint('[SoundService] play $file failed: $e');
    });
  }

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
        return 1.0;
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
