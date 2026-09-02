import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flame/game.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../data/game_repository.dart';
import '../data/progress_store.dart';
import '../data/snapshot_store.dart';
import '../game/jigsaw_puzzle_game.dart';
import '../logic/models/puzzle_state.dart';
import '../logic/puzzle_model.dart';
import '../logic/star_calculator.dart';
import '../services/achievement_service.dart';
import '../services/app_logger.dart';
import '../services/economy_service.dart';
import '../services/sound_service.dart';
import '../widgets/choose_background_sheet.dart';
import '../widgets/game_toast.dart';
import '../widgets/share_card_generator.dart';
import '../widgets/victory_dialog.dart';

/// Full-screen in-game puzzle page matching commercial Jigsaw experience.
class GamePage extends StatefulWidget {
  const GamePage({
    super.key,
    required this.imageBytes,
    required this.difficulty,
    this.levelIndex,
    this.dailyDateStr,
    this.customId,
    this.initialSnapshotJson,
    this.canonicalId,
    this.packTitle,
  });

  final Uint8List imageBytes;
  final PuzzleDifficulty difficulty;
  final int? levelIndex;
  final String? dailyDateStr;
  final String? customId;
  final String? initialSnapshotJson;

  /// 通用扩展包/活动等使用的全局唯一主键，优先级高于 levelIndex/daily/customId
  final String? canonicalId;
  final String? packTitle;

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage> with WidgetsBindingObserver {
  final _repo = GameRepository.instance;
  JigsawPuzzleGame? _game;
  ui.Image? _gameImage;
  bool _gameFadeIn = false;

  bool _isSolved = false;
  bool _isPaused = false;
  int _seconds = 0;
  final _secondsNotifier = ValueNotifier<int>(0);
  Timer? _timer;
  DateTime? _hintPauseUntil;
  int _solvedPieces = 0;

  /// 已上报的游玩秒数游标（playSeconds 生命周期增量上报，设计 §8.1）
  int _reportedPlaySeconds = 0;
  bool _showOriginalImage = false;
  late String _selectedBackground;
  // 顶部导航条背景色跟随所选自适应，随背景贴图近似色（默认白、炭灰前景）
  Color _headerBarColor = Colors.white;
  Color _headerIconColor = const Color(0xFF1F2937);
  PuzzleDifficulty? _effectiveDifficulty;
  int get _totalPieces =>
      (_effectiveDifficulty ?? widget.difficulty).pieceCount;

  // Multi-touch tracking for pinch-to-zoom & two-finger pan
  final Map<int, Offset> _pointerPositions = {};
  double _baseDistance = 0.0;
  double _baseZoom = 1.0;
  Offset _baseFocalPoint = Offset.zero;
  Vector2 _basePan = Vector2.zero();
  final FocusNode _focusNode = FocusNode();

  Timer? _saveDebounce;
  static const Duration _saveDebounceDuration = Duration(milliseconds: 800);
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selectedBackground = _repo.selectedBackground;
    _loadHeaderColor();
    _startTimer();
    _loadImage();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.inactive) {
      AppLogger.game.info('GamePage lifecycle $state -> flushSync save');
      _reportPlaySeconds(); // 切后台/暂停：上报游玩时长增量（设计 §8.1）
      _flushSync();
    }
  }

  /// 上报自上次上报以来的游玩秒数增量（暂停/切后台/结算/退出时调用）。
  /// 由 [_reportedPlaySeconds] 游标保证不重不漏；弃局挂机时间同样计入。
  void _reportPlaySeconds() {
    final delta = _seconds - _reportedPlaySeconds;
    if (delta <= 0) return;
    _reportedPlaySeconds = _seconds;
    unawaited(AchievementService.instance.onPlaySecondsElapsed(delta));
  }

  /// 解析背景贴图资产取其近似平均色，与主题 primaryContainer 混合作为顶部导航条背景色，
  /// 并按合成色亮度自动选择前景（深/浅），保证标题与图标可读。
  Future<void> _loadHeaderColor() async {
    final assetPath = _selectedBackground;
    ui.Codec? codec;
    try {
      final data = await rootBundle.load(assetPath);
      final buffer = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      codec = await ui.instantiateImageCodec(
        buffer,
        targetWidth: 48,
        targetHeight: 48,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final w = image.width;
      final h = image.height;
      final pixelData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      image.dispose();
      if (pixelData == null) return;
      final bytes = pixelData.buffer.asUint8List();
      final pixelCount = w * h;
      if (pixelCount <= 0) return;
      var r = 0, g = 0, b = 0;
      for (var i = 0; i < bytes.length; i += 4) {
        r += bytes[i];
        g += bytes[i + 1];
        b += bytes[i + 2];
      }
      final avg = Color.fromARGB(
        255,
        r ~/ pixelCount,
        g ~/ pixelCount,
        b ~/ pixelCount,
      );
      if (!mounted) return;
      final scheme = Theme.of(context).colorScheme;
      final blended = Color.lerp(scheme.primaryContainer, avg, 0.45)!;
      final luminance =
          (0.299 * blended.r + 0.587 * blended.g + 0.114 * blended.b) * 255;
      final isDarkBar = luminance <= 150;
      // 网格页无 AppBar，需主动让系统状态栏/导航栏跟随顶部导航条颜色与图标亮度
      SystemChrome.setSystemUIOverlayStyle(
        SystemUiOverlayStyle(
          statusBarColor: blended,
          statusBarIconBrightness: isDarkBar
              ? Brightness.light
              : Brightness.dark,
          statusBarBrightness: isDarkBar ? Brightness.dark : Brightness.light,
          systemNavigationBarColor: blended,
          systemNavigationBarIconBrightness: isDarkBar
              ? Brightness.light
              : Brightness.dark,
        ),
      );
      setState(() {
        _headerBarColor = blended;
        _headerIconColor = isDarkBar ? Colors.white : scheme.onPrimaryContainer;
      });
    } catch (_) {
      // 解析失败时保持默认白底/深色前景
    } finally {
      codec?.dispose();
    }
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_isSolved && !_isPaused && mounted) {
        final now = DateTime.now();
        if (_hintPauseUntil != null && now.isBefore(_hintPauseUntil!)) {
          // 提示动画时停期间不累加用时
          return;
        }
        _seconds++;
        _secondsNotifier.value = _seconds;
      }
    });
  }

  Future<void> _loadImage() async {
    final img = await decodeFlameImage(widget.imageBytes);
    _gameImage = img;
    PuzzleDifficulty effectiveDiff;
    // 若有快照，优先使用快照中的 rows/cols，避免 adaptive 覆盖导致 _applyBoardState 静默丢弃（P0-1）
    if (widget.initialSnapshotJson != null) {
      try {
        final map =
            jsonDecode(widget.initialSnapshotJson!) as Map<String, dynamic>;
        if (map['elapsedSeconds'] is int) {
          _seconds = map['elapsedSeconds'] as int;
          _secondsNotifier.value = _seconds;
        }
        if (map['rows'] is int && map['cols'] is int) {
          final r = map['rows'] as int;
          final c = map['cols'] as int;
          effectiveDiff = PuzzleDifficulty.presets.firstWhere(
            (d) => d.rows == r && d.cols == c,
            orElse: () => PuzzleDifficulty(
              label: '$r x $c (${r * c}块)',
              rows: r,
              cols: c,
            ),
          );
          AppLogger.game.info(
            'Use snapshot rows/cols r=$r c=$c for effectiveDiff, skip adaptive (P0-1)',
          );
        } else {
          effectiveDiff = widget.difficulty.adaptiveForSize(
            img.width.toDouble(),
            img.height.toDouble(),
          );
        }
      } catch (e, st) {
        AppLogger.game.warning('Failed to parse initialSnapshotJson', e, st);
        effectiveDiff = widget.difficulty.adaptiveForSize(
          img.width.toDouble(),
          img.height.toDouble(),
        );
      }
    } else {
      effectiveDiff = widget.difficulty.adaptiveForSize(
        img.width.toDouble(),
        img.height.toDouble(),
      );
    }
    _effectiveDifficulty = effectiveDiff;

    final game = JigsawPuzzleGame(
      image: img,
      rows: effectiveDiff.rows,
      cols: effectiveDiff.cols,
      scatterMode: _repo.pieceScatterMode,
      initialSnapshotJson: widget.initialSnapshotJson,
      initialGhostOpacity: 0.0,
      onSolved: _handleSolved,
      onPieceSnapped: _onPieceSnapped,
      onProgressChanged: (count) {
        if (mounted) setState(() => _solvedPieces = count);
        _scheduleSave(immediate: false);
      },
      onStateUpdated: () {
        if (mounted) {
          setState(() {
            if (_game != null) {
              _isSolved = _game!.isSolved;
            }
          });
        }
        // 自由摆放等非吸附位移也需要保存
        _scheduleSave(immediate: false);
      },
    );

    if (mounted) {
      setState(() {
        _game = game;
        _gameFadeIn = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _gameFadeIn = true;
          });
        }
      });
    }
  }

  void _onPieceSnapped() {
    SoundService.I.play(Sfx.snap);
    if (_repo.hapticEnabled) {
      HapticFeedback.lightImpact();
    }
    _repo.recordSnapStats(pieceCount: 1);
  }

  void _scheduleSave({bool immediate = false}) {
    if (_game == null || _isSolved) return;
    if (immediate) {
      _saveDebounce?.cancel();
      _doSave();
      return;
    }
    _saveDebounce?.cancel();
    _saveDebounce = Timer(_saveDebounceDuration, _doSave);
  }

  Future<void> _flushSave() async {
    _saveDebounce?.cancel();
    await _doSave();
  }

  /// 同步兜底（用于 dispose / lifecycle 同步落盘，避免 fire-and-forget 丢失）
  void _flushSync() {
    _saveDebounce?.cancel();
    if (_game == null || _isSolved) return;
    try {
      final total = _totalPieces;
      final liveSolved = _game!.solvedCount;
      final percent = total > 0 ? (liveSolved * 100 ~/ total) : 0;
      final boardForCheck = _game!.boardState;
      final isTrivial =
          percent == 0 &&
          boardForCheck.hintsUsed == 0 &&
          _seconds < 5 &&
          boardForCheck.pieces.every((p) => p.clusterId == p.id);
      if (isTrivial) return;
      final snapshot = _game!.exportSnapshotJson(elapsedSeconds: _seconds);
      final map = jsonDecode(snapshot) as Map<String, dynamic>;
      final state = PuzzleBoardState.fromJson(map);
      SnapshotStore.instance.saveSync(state);
      final canonicalId = _canonicalIdForSave();
      if (canonicalId.isNotEmpty) {
        // ignore: discarded_futures
        _repo.updateGenericProgress(
          canonicalId: canonicalId,
          progressPercent: percent,
          snapshotJson: snapshot,
          difficultyHint: _effectiveDifficulty ?? widget.difficulty,
        );
      }
    } catch (_) {}
  }

  String _canonicalIdForSave() {
    if (widget.canonicalId != null && widget.canonicalId!.isNotEmpty) {
      return widget.canonicalId!;
    }
    if (widget.levelIndex != null) {
      return GameRepository.canonicalForLevel(widget.levelIndex!);
    }
    if (widget.dailyDateStr != null) {
      return GameRepository.canonicalForDaily(widget.dailyDateStr!);
    }
    if (widget.customId != null) {
      return GameRepository.canonicalForCustom(widget.customId!);
    }
    return '';
  }

  Future<void> _doSave() async {
    if (_game == null || _isSolved) return;
    if (_isSaving) {
      // 若正在保存，稍后重试（但 dispose 已取消 debounce，不会逃逸）
      _saveDebounce?.cancel();
      _saveDebounce = Timer(const Duration(milliseconds: 300), () => _doSave());
      return;
    }
    _isSaving = true;
    final total = _totalPieces;
    final liveSolved = _game!.solvedCount;
    if (liveSolved != _solvedPieces && mounted) {
      _solvedPieces = liveSolved;
    }
    final percent = total > 0 ? (liveSolved * 100 ~/ total) : 0;
    // 过滤"点进去即退"的无意义残局，避免"只要点进去就有记录"
    final boardForCheck = _game!.boardState;
    final isTrivial =
        percent == 0 &&
        boardForCheck.hintsUsed == 0 &&
        _seconds < 5 &&
        boardForCheck.pieces.every((p) => p.clusterId == p.id);
    if (isTrivial) {
      _isSaving = false;
      return;
    }
    String snapshot;
    try {
      snapshot = _game!.exportSnapshotJson(elapsedSeconds: _seconds);
    } catch (e, st) {
      AppLogger.game.warning('exportSnapshot failed', e, st);
      _isSaving = false;
      return;
    }

    try {
      if (widget.canonicalId != null && widget.canonicalId!.isNotEmpty) {
        await _repo.updateGenericProgress(
          canonicalId: widget.canonicalId!,
          progressPercent: percent,
          snapshotJson: snapshot,
          difficultyHint: _effectiveDifficulty ?? widget.difficulty,
        );
      } else if (widget.levelIndex != null) {
        await _repo.updateLevelProgress(
          levelIndex: widget.levelIndex!,
          progressPercent: percent,
          snapshotJson: snapshot,
        );
      } else if (widget.dailyDateStr != null) {
        await _repo.updateDailyProgress(
          dateStr: widget.dailyDateStr!,
          progressPercent: percent,
          snapshotJson: snapshot,
        );
      } else if (widget.customId != null) {
        await _repo.updateCustomProgress(
          id: widget.customId!,
          progressPercent: percent,
          snapshotJson: snapshot,
        );
      } else {
        return;
      }
    } catch (e, st) {
      AppLogger.game.warning('doSave updateProgress failed', e, st);
    } finally {
      _isSaving = false;
    }
  }

  int _calculateStars() {
    final hints = _game?.boardState.hintsUsed ?? 0;
    final actualPieces =
        _effectiveDifficulty?.pieceCount ?? widget.difficulty.pieceCount;
    final secPerPiece =
        _effectiveDifficulty?.secPerPiece ?? widget.difficulty.secPerPiece;
    return StarCalculator.calcStars(
      actualPieces: actualPieces,
      secPerPiece: secPerPiece,
      hints: hints,
      seconds: _seconds,
    );
  }

  Future<void> _handleSolved() async {
    if (_isSolved) return;
    _timer?.cancel();
    _saveDebounce?.cancel();

    if (_repo.hapticEnabled) {
      HapticFeedback.heavyImpact();
    }

    final hints = _game?.boardState.hintsUsed ?? 0;
    final actualPieces =
        _effectiveDifficulty?.pieceCount ?? widget.difficulty.pieceCount;
    final secPerPiece =
        _effectiveDifficulty?.secPerPiece ?? widget.difficulty.secPerPiece;

    // 双轴评星打分
    final stars = StarCalculator.calcStars(
      actualPieces: actualPieces,
      secPerPiece: secPerPiece,
      hints: hints,
      seconds: _seconds,
    );

    // 胜利音：大规格或满星用 TrophySound，否则普通 win
    final isBigWin = actualPieces >= 100 || stars == 3;
    SoundService.I.play(isBigWin ? Sfx.winBig : Sfx.win);

    setState(() {
      _isSolved = true;
      _solvedPieces = _totalPieces;
    });

    _repo.recordSnapStats(durationSeconds: _seconds);
    final dkey = SnapshotStore.difficultyKeyFor(
      _effectiveDifficulty ?? widget.difficulty,
    );
    final cid = _canonicalIdForSave();

    // 1. 原子更新 ProgressStore 档位记录并获得 deltaStars 与 minHintsUsed 状态
    final updateResult = await ProgressStore.instance
        .recordDifficultyCompletion(
          canonicalId: cid,
          difficultyKey: dkey,
          stars: stars,
          timeSeconds: _seconds,
          hintsUsed: hints,
          completedPieceCount: actualPieces,
          moves: _solvedPieces,
        );

    // 2. 同步更新 GameRepository 关卡状态与内存列表
    if (widget.canonicalId != null && widget.canonicalId!.isNotEmpty) {
      await _repo.updateGenericProgress(
        canonicalId: widget.canonicalId!,
        progressPercent: 100,
        isCompleted: true,
        completedPieceCount: actualPieces,
        difficultyKey: dkey,
        timeSeconds: _seconds,
        difficultyHint: _effectiveDifficulty ?? widget.difficulty,
      );
    } else if (widget.levelIndex != null) {
      await _repo.updateLevelProgress(
        levelIndex: widget.levelIndex!,
        progressPercent: 100,
        isCompleted: true,
        completedPieceCount: actualPieces,
        difficultyKey: dkey,
        stars: stars,
        timeSeconds: _seconds,
      );
    } else if (widget.dailyDateStr != null) {
      await _repo.updateDailyProgress(
        dateStr: widget.dailyDateStr!,
        progressPercent: 100,
        isCompleted: true,
        completedPieceCount: actualPieces,
        difficultyKey: dkey,
        timeSeconds: _seconds,
      );
    } else if (widget.customId != null) {
      await _repo.updateCustomProgress(
        id: widget.customId!,
        progressPercent: 100,
        isCompleted: true,
        completedPieceCount: actualPieces,
        difficultyKey: dkey,
        timeSeconds: _seconds,
      );
    }

    // 3. 经济与金币发奖
    final tier = (_effectiveDifficulty ?? widget.difficulty).tierIndex;
    final reward = await EconomyService.instance.calculateAndAwardCompletion(
      tierIndex: tier,
      stars: stars,
      isFirstCompletion: updateResult.record.playCount <= 1,
      deltaStars: updateResult.deltaStars,
    );

    // 4. 成就系统事件评估
    // （playSeconds 已在结算前上报，onPuzzleSolved 不再重复累加时长）
    _reportPlaySeconds();
    final ptype = widget.dailyDateStr != null
        ? 'daily'
        : (widget.customId != null
              ? 'custom'
              : (widget.packTitle != null ? 'pack' : 'main'));
    final newAchievements = await AchievementService.instance.onPuzzleSolved(
      actualPieces: actualPieces,
      elapsedSeconds: _seconds,
      hintsUsed: hints,
      stars: stars,
      puzzleType: ptype,
      tierIndex: tier,
      canonicalId: cid,
      isFirstNoHintWin: updateResult.isFirstNoHintWin,
    );

    // 5. 删除快照
    await SnapshotStore.instance.delete(cid, dkey);

    // 6. 显示通关弹窗
    if (mounted) {
      _showVictoryDialog(
        stars: stars,
        deltaStars: updateResult.deltaStars,
        earnedCoins: reward.earnedCoins,
        newAchievements: newAchievements,
      );
    }
  }

  Future<void> _onHintPressed() async {
    if (_isSolved || _isPaused) return;

    final tier = (_effectiveDifficulty ?? widget.difficulty).tierIndex;
    final canUse = await EconomyService.instance.consumeHint(tierIndex: tier);
    if (!canUse) {
      if (mounted) {
        final price = EconomyService
            .kHintPrices[tier.clamp(0, EconomyService.kHintPrices.length - 1)];
        GameToast.show(
          context,
          icon: PhosphorIconsRegular.coins,
          message:
              '金币不足（当前难度提示需 $price 金币，当前拥有 ${EconomyService.instance.coins}）',
          type: GameToastType.warning,
        );
      }
      return;
    }

    // 提示动画期间暂停计时 1.5 秒
    _hintPauseUntil = DateTime.now().add(const Duration(milliseconds: 1500));
    _game?.hint();
    SoundService.I.play(Sfx.hint);
  }

  String get _timeString {
    final m = (_seconds ~/ 60).toString().padLeft(2, '0');
    final s = (_seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String get _pageTitle {
    if (widget.packTitle != null && widget.packTitle!.isNotEmpty) {
      return widget.packTitle!;
    }
    if (widget.levelIndex != null) {
      return '第 ${widget.levelIndex} 关';
    } else if (widget.dailyDateStr != null) {
      return '${widget.dailyDateStr} 每日挑战';
    } else {
      return '自制拼图';
    }
  }

  void _openBackgroundSelector() {
    SoundService.I.play(Sfx.moveIn);
    ChooseBackgroundSheet.show(
      context: context,
      selectedBackground: _selectedBackground,
      onBackgroundSelected: (newBg) {
        setState(() => _selectedBackground = newBg);
        _repo.selectedBackground = newBg;
        _loadHeaderColor();
      },
    );
  }

  Future<void> _playNextLevel() async {
    if (widget.levelIndex == null) return;
    final nextIndex = widget.levelIndex! + 1;
    if (nextIndex > _repo.levels.length) return;

    final nextLevel = _repo.levels[nextIndex - 1];
    final bytes = await rootBundle.load(nextLevel.assetPath);
    final imgBytes = bytes.buffer.asUint8List();

    if (!mounted) return;
    // 尝试从文件级快照读取（新链路优先）
    String? snapJson = nextLevel.savedSnapshotJson;
    try {
      final s = await _repo.loadLevelSnapshotJson(
        nextIndex,
        nextLevel.difficulty,
      );
      if (s != null) snapJson = s;
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => GamePage(
          imageBytes: imgBytes,
          difficulty: nextLevel.difficulty,
          levelIndex: nextLevel.index,
          initialSnapshotJson: snapJson,
        ),
      ),
    );
  }

  void _showVictoryDialog({
    int? stars,
    int deltaStars = 0,
    int earnedCoins = 0,
    List<AchievementDefinition> newAchievements = const [],
  }) {
    setState(() => _isPaused = true);
    final earnedStars = stars ?? _calculateStars();
    final hasNext =
        widget.levelIndex != null && widget.levelIndex! < _repo.levels.length;

    VictoryDialog.show(
      context: context,
      imageBytes: widget.imageBytes,
      stars: earnedStars,
      elapsedSeconds: _seconds,
      pieceCount: _totalPieces,
      rewardCoins: earnedCoins,
      newAchievements: newAchievements,
      onNextLevel: hasNext ? _playNextLevel : null,
      onShare: () {
        ShareCardGenerator.open(
          context,
          imageBytes: widget.imageBytes,
          elapsedSeconds: _seconds,
          pieceCount: _totalPieces,
          starCount: earnedStars,
          stepCount: _solvedPieces,
          levelTitle: _pageTitle,
        );
      },
      onViewPuzzle: () {
        setState(() {}); // 停留在游戏内自由缩放欣赏完整拼图
      },
      onExit: () {
        Navigator.of(context).pop();
      },
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    // 鼠标右键点击：若当前有吸附抓取的碎片，立即取消抓取并复位
    if ((event.buttons & kSecondaryMouseButton) != 0 && _game != null) {
      if (_game!.holdingPiece != null) {
        _game!.cancelHoldingPiece();
        if (mounted) setState(() {});
        return;
      }
    }

    _pointerPositions[event.pointer] = event.localPosition;
    if (_pointerPositions.length >= 2) {
      _game?.isPinching = true;
      _game?.cancelHoldingPiece();
      _game?.cancelAllPieceDragging();
    }
    if (_pointerPositions.length == 2) {
      final p1 = _pointerPositions.values.first;
      final p2 = _pointerPositions.values.last;
      _baseDistance = (p1 - p2).distance;
      _baseZoom = _game?.zoom ?? 1.0;
      _baseFocalPoint = (p1 + p2) / 2;
      _basePan = _game?.panOffset.clone() ?? Vector2.zero();
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    _pointerPositions[event.pointer] = event.localPosition;
    if (_pointerPositions.length >= 2 && _game != null) {
      final p1 = _pointerPositions.values.first;
      final p2 = _pointerPositions.values.last;
      final curDist = (p1 - p2).distance;
      final curFocal = (p1 + p2) / 2;
      if (_baseDistance > 10.0) {
        final scaleFactor = curDist / _baseDistance;
        final newZoom = (_baseZoom * scaleFactor).clamp(1.0, _game!.maxZoom);

        // 精准定点缩放几何变换：保持两指中心点在缩放过程中与棋盘内容像素严格锁定
        final baseTopLeft = _game!.boardTopLeft + _basePan;
        final focalOffset =
            _baseFocalPoint - Offset(baseTopLeft.x, baseTopLeft.y);
        final zoomRatio = newZoom / _baseZoom;
        final newTopLeftX = curFocal.dx - focalOffset.dx * zoomRatio;
        final newTopLeftY = curFocal.dy - focalOffset.dy * zoomRatio;
        final newPan = Vector2(
          newTopLeftX - _game!.boardTopLeft.x,
          newTopLeftY - _game!.boardTopLeft.y,
        );

        _game!.setZoomAndPan(newZoom, newPan);
      }
    } else if ((event.buttons & kMiddleMouseButton) != 0 && _game != null) {
      _game!.panBy(Vector2(event.delta.dx, event.delta.dy));
    } else if (_game != null &&
        _game!.zoom > 1.0 &&
        _pointerPositions.length == 1 &&
        !_game!.isDraggingAnyPiece &&
        (_game!.isTabletop || event.localPosition.dy < _game!.trayPosition.y)) {
      // 放大状态下，鼠标左键或单指按住空白区域拖动 -> 实时平移棋盘画布
      // 使用 Listener 原生 pointer delta 直接驱动，避免 Flame PanDetector 与 DragCallbacks 的手势竞技场冲突
      _game!.panBy(Vector2(event.delta.dx, event.delta.dy));
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    _pointerPositions.remove(event.pointer);
    if (_pointerPositions.length < 2) {
      _baseDistance = 0.0;
      Future.delayed(const Duration(milliseconds: 60), () {
        if (_pointerPositions.length < 2 && mounted) {
          _game?.isPinching = false;
        }
      });
    }
    if (mounted) setState(() {});
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _pointerPositions.remove(event.pointer);
    if (_pointerPositions.length < 2) {
      _baseDistance = 0.0;
      Future.delayed(const Duration(milliseconds: 60), () {
        if (_pointerPositions.length < 2 && mounted) {
          _game?.isPinching = false;
        }
      });
    }
    if (mounted) setState(() {});
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent && _game != null) {
      final isCtrl =
          HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed;
      final mousePos = event.localPosition;
      final inTray = !_game!.isTabletop && mousePos.dy >= _game!.trayPosition.y;

      if (inTray) {
        // 托盘区域直接响应鼠标滚轮与触摸板水平/垂直滚动
        final delta = event.scrollDelta.dx != 0
            ? -event.scrollDelta.dx
            : -event.scrollDelta.dy;
        _game!.scrollTray(delta * 0.8);
      } else if (isCtrl || event.scrollDelta.dy.abs() > 0) {
        final zoomDelta = -event.scrollDelta.dy * 0.003;
        _game!.zoomAt(Vector2(mousePos.dx, mousePos.dy), zoomDelta);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveDebounce?.cancel();
    _reportPlaySeconds(); // 退出/弃局：上报剩余游玩时长（设计 §8.1 弃局同样计入）
    // 最后机会同步保存（避免 dispose 逃逸 Timer）
    if (!_isSolved) {
      try {
        _flushSync();
      } catch (_) {}
    }
    _timer?.cancel();
    _secondsNotifier.dispose();
    _focusNode.dispose();
    _gameImage?.dispose();
    // 恢复浅色主题的默认系统状态栏/导航栏样式（浅底 + 深色图标）
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
    super.dispose();
  }

  /// 标准 AppBar：左侧返回，右侧收敛 6 个图标（左到右）：
  /// 1) 边缘碎片  2) 提示  3) 遮罩  4) 眼睛看原图  5) 扫把整理  6) 换背景
  AppBar _buildAppBar() {
    final ghostOpacity = _game?.boardGhostOpacity ?? 0.0;
    final isBorderActive = _game?.isBorderFilterActive ?? false;
    return AppBar(
      backgroundColor: _headerBarColor,
      elevation: 2,
      scrolledUnderElevation: 2,
      surfaceTintColor: Colors.transparent,
      titleSpacing: 0,
      automaticallyImplyLeading: false,
      leading: IconButton(
        icon: Icon(PhosphorIconsBold.arrowLeft, color: _headerIconColor),
        tooltip: '返回',
        onPressed: () async {
          SoundService.I.play(Sfx.tap);
          await _flushSave();
          if (mounted) Navigator.of(context).pop();
        },
      ),
      title: const SizedBox.shrink(),
      actions: [
        // 1. 显示边缘碎片
        IconButton(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 5),
          constraints: const BoxConstraints(minWidth: 38, minHeight: 40),
          icon: Icon(
            isBorderActive
                ? PhosphorIconsFill.cornersOut
                : PhosphorIconsBold.cornersOut,
            size: 21,
            color: isBorderActive ? const Color(0xFF2E7D32) : _headerIconColor,
          ),
          tooltip: isBorderActive ? '显示全部碎片' : '仅显示边缘碎片',
          onPressed: () {
            _game?.toggleBorderFilter();
            final active = _game?.isBorderFilterActive ?? false;
            SoundService.I.play(active ? Sfx.edgesIn : Sfx.edgesOut);
            setState(() {});
          },
        ),
        // 2. 提示
        IconButton(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 5),
          constraints: const BoxConstraints(minWidth: 38, minHeight: 40),
          icon: const Icon(
            PhosphorIconsFill.lightbulb,
            size: 21,
            color: Colors.amber,
          ),
          tooltip: '智能提示',
          onPressed: _onHintPressed,
        ),
        // 3. 显示遮罩（底图透视 0%/20%/45%）
        IconButton(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 5),
          constraints: const BoxConstraints(minWidth: 38, minHeight: 40),
          icon: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                ghostOpacity > 0.01
                    ? PhosphorIconsFill.stack
                    : PhosphorIconsBold.stack,
                color: ghostOpacity > 0.01
                    ? const Color(0xFF2E7D32)
                    : _headerIconColor,
                size: 21,
              ),
              if (ghostOpacity > 0.01)
                Positioned(
                  bottom: -1,
                  right: -2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 2,
                      vertical: 0,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2E7D32),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${(ghostOpacity * 100).toInt()}',
                      style: const TextStyle(
                        fontSize: 7,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          tooltip: '底图透视参考 (0%/20%/45%)',
          onPressed: () {
            _game?.toggleGhostOpacity();
            SoundService.I.play(Sfx.preview);
            setState(() {});
          },
        ),
        // 4. 显示眼睛（看原图）
        IconButton(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 5),
          constraints: const BoxConstraints(minWidth: 38, minHeight: 40),
          icon: Icon(
            _showOriginalImage ? PhosphorIconsFill.eye : PhosphorIconsBold.eye,
            size: 21,
            color: _showOriginalImage
                ? const Color(0xFF0288D1)
                : _headerIconColor,
          ),
          tooltip: '查看原图',
          onPressed: () {
            SoundService.I.play(Sfx.preview);
            setState(() {
              _showOriginalImage = !_showOriginalImage;
              _isPaused = _showOriginalImage;
            });
          },
        ),
        // 5. 扫把一键整理
        IconButton(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 5),
          constraints: const BoxConstraints(minWidth: 38, minHeight: 40),
          icon: Icon(
            PhosphorIconsBold.broom,
            size: 21,
            color: _headerIconColor,
          ),
          tooltip: '一键整理托盘',
          onPressed: () {
            _game?.organizeTray();
            SoundService.I.play(Sfx.tap);
          },
        ),
        // 6. 换背景图
        IconButton(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 5),
          constraints: const BoxConstraints(minWidth: 38, minHeight: 40),
          icon: const Icon(
            PhosphorIconsBold.image,
            size: 21,
            color: Color(0xFF2E7D32),
          ),
          tooltip: '更换壁纸背景',
          onPressed: _openBackgroundSelector,
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildProgressLine() {
    final total = _totalPieces;
    return LinearProgressIndicator(
      value: total > 0 ? _solvedPieces / total : 0.0,
      minHeight: 2.0,
      backgroundColor: Colors.black12,
      valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF2E7D32)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        SoundService.I.play(Sfx.tap);
        await _flushSave();
        if (context.mounted) Navigator.of(context).pop(result);
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFE2E6EA),
        appBar: _buildAppBar(),
        body: Stack(
          children: [
            // 1. Full-Screen Seamless Tiled Background
            Positioned.fill(
              child: Image.asset(
                _selectedBackground,
                repeat: ImageRepeat.repeat,
                errorBuilder: (ctx, err, stack) =>
                    Container(color: const Color(0xFFE2E6EA)),
              ),
            ),

            // 2. Progress Line + Flame Game Canvas
            // Keep as non-positioned Column so Stack fills the entire available screen
            Column(
              children: [
                _buildProgressLine(),
                Expanded(
                  child: _game != null
                      ? KeyboardListener(
                          focusNode: _focusNode,
                          autofocus: true,
                          onKeyEvent: (keyEvent) {
                            if (keyEvent is KeyDownEvent &&
                                keyEvent.logicalKey ==
                                    LogicalKeyboardKey.escape &&
                                _game?.holdingPiece != null) {
                              _game?.cancelHoldingPiece();
                              if (mounted) setState(() {});
                            }
                          },
                          child: Listener(
                            onPointerDown: _onPointerDown,
                            onPointerMove: _onPointerMove,
                            onPointerUp: _onPointerUp,
                            onPointerCancel: _onPointerCancel,
                            onPointerSignal: _onPointerSignal,
                            behavior: HitTestBehavior.translucent,
                            child: AnimatedOpacity(
                              opacity: _gameFadeIn ? 1.0 : 0.0,
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeOutCubic,
                              child: ClipRect(
                                child: GameWidget<JigsawPuzzleGame>(
                                  game: _game!,
                                ),
                              ),
                            ),
                          ),
                        )
                      : const Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFF2E7D32),
                          ),
                        ),
                ),
              ],
            ),

            // 3. Full-Screen Original Image Overlay (toggled via eye icon)
            if (_showOriginalImage)
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => setState(() {
                    _showOriginalImage = false;
                    _isPaused = false;
                  }),
                  child: Container(
                    color: Colors.black87,
                    padding: const EdgeInsets.fromLTRB(20, 50, 20, 24),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            constraints: BoxConstraints(
                              maxHeight:
                                  MediaQuery.sizeOf(context).height * 0.72,
                              maxWidth: MediaQuery.sizeOf(context).width * 0.92,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: const [
                                BoxShadow(
                                  color: Colors.black54,
                                  blurRadius: 20,
                                  offset: Offset(0, 8),
                                ),
                              ],
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Image.memory(
                              widget.imageBytes,
                              fit: BoxFit.contain,
                              // 解码期降采样：全屏预览 0.92W×0.72H 约 1000~1400px，
                              // 1440 已留足余量，避免超分图全量解码（可达50MiB）
                              cacheWidth: 1440,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Text(
                              '点击任意处返回拼图',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            // 5. Floating Zoom Level Badge and Reset Button when zoomed
            if (_game != null)
              ValueListenableBuilder<double>(
                valueListenable: _game!.zoomNotifier,
                builder: (context, zoom, _) {
                  if (zoom <= 1.02) return const SizedBox.shrink();
                  return Positioned(
                    top: 12,
                    right: 12,
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.68),
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () {
                          _game?.resetZoom();
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                PhosphorIconsBold.magnifyingGlassPlus,
                                color: Colors.white,
                                size: 16,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${(zoom * 100).toInt()}%',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 6),
                              const Text(
                                '重置',
                                style: TextStyle(
                                  color: Colors.amberAccent,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),

            // 6. Floating Victory Banner when solved and dialog closed
            if (_isSolved)
              Positioned(
                bottom: 16,
                left: 20,
                right: 20,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1F2937),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black38,
                        blurRadius: 10,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '🎉 通关！耗时 $_timeString',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      Row(
                        children: [
                          TextButton(
                            onPressed: _showVictoryDialog,
                            child: const Text(
                              '结算成绩',
                              style: TextStyle(color: Colors.amber),
                            ),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context),
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.white,
                            ),
                            child: const Text(
                              '返回',
                              style: TextStyle(color: Color(0xFF1F2937)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
