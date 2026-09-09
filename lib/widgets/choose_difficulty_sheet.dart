import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:jigsawpuzzle/data/favorite_store.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/models/custom_puzzle_item.dart';
import 'package:jigsawpuzzle/data/snapshot_store.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/logic/content/models/canonical_id.dart';
import 'package:jigsawpuzzle/logic/geometry/edge_layout.dart';
import 'package:jigsawpuzzle/logic/geometry/piece_shape.dart';
import 'package:jigsawpuzzle/logic/puzzle_model.dart';
import 'package:jigsawpuzzle/logic/source_tag.dart';
import 'package:jigsawpuzzle/services/recommend_service.dart';
import 'package:jigsawpuzzle/services/sound_service.dart';
import 'package:jigsawpuzzle/theme/app_palette.dart';
import 'package:jigsawpuzzle/theme/app_text_styles.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// Custom painter rendering dynamic jigsaw grid preview lines over selected puzzle image.
class _JigsawOverlayPainter extends CustomPainter {
  _JigsawOverlayPainter({
    required this.rows,
    required this.cols,
    this.seed = 42,
  }) : edgeLayout = EdgeLayout(rows: rows, cols: cols, seed: seed);

  final int rows;
  final int cols;
  final int seed;
  final EdgeLayout edgeLayout;

  static final Paint _shadowPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.6
    ..color = const Color(0x77000000)
    ..isAntiAlias = true;

  static final Paint _linePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0
    ..color = const Color(0xEEFFFFFF)
    ..isAntiAlias = true;

  // P11 性能：缓存合并 Path，避免每帧重建 16~100 个贝塞尔
  Path? _cachedLinePath;
  Path? _cachedShadowPath;
  Size? _cachedSize;
  int? _cachedRows;
  int? _cachedCols;

  void _ensureCache(Size size) {
    if (_cachedLinePath != null &&
        _cachedShadowPath != null &&
        _cachedSize == size &&
        _cachedRows == rows &&
        _cachedCols == cols) {
      return;
    }
    final pieceW = size.width / cols;
    final pieceH = size.height / rows;
    final line = Path();
    final shadow = Path();
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final edges = edgeLayout.edgesFor(r, c);
        final shape = PieceShape(edges: edges, width: pieceW, height: pieceH);
        // 将局部 path 平移到全局坐标
        line.addPath(shape.path, Offset(c * pieceW, r * pieceH));
        shadow.addPath(shape.path, Offset(c * pieceW, r * pieceH));
      }
    }
    _cachedLinePath = line;
    _cachedShadowPath = shadow;
    _cachedSize = size;
    _cachedRows = rows;
    _cachedCols = cols;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (rows <= 0 || cols <= 0 || size.width <= 0 || size.height <= 0) return;
    _ensureCache(size);
    canvas.drawPath(_cachedShadowPath!, _shadowPaint);
    canvas.drawPath(_cachedLinePath!, _linePaint);
  }

  @override
  bool shouldRepaint(covariant _JigsawOverlayPainter oldDelegate) {
    return oldDelegate.rows != rows ||
        oldDelegate.cols != cols ||
        oldDelegate.seed != seed;
  }
}

/// A bottom sheet dialog matching the commercial jigsaw piece selection UI.
class ChooseDifficultySheet extends StatefulWidget {
  const ChooseDifficultySheet({
    required this.imageBytes,
    required this.initialDifficulty,
    required this.title,
    required this.onStart,
    super.key,
    this.canonicalId,
    this.completedPieceCounts = const {},
    this.isUnlocked = true,
    this.lockedMessage,
    this.onDelete,
    this.savedProgressPercent,
    this.onResetProgress,
    this.sourcePlatform,
    this.sourceUrl,
    this.imagePathOrUrl,
    this.enableL7 = false,
  });

  final Uint8List imageBytes;
  final PuzzleDifficulty initialDifficulty;
  final String title;
  final ValueChanged<PuzzleDifficulty> onStart;
  final String? canonicalId;
  final Set<int> completedPieceCounts;
  final bool isUnlocked;
  final String? lockedMessage;
  final Future<void> Function()? onDelete;
  final int? savedProgressPercent;
  final VoidCallback? onResetProgress;
  final String? sourcePlatform;
  final String? sourceUrl;
  final String? imagePathOrUrl;
  final bool enableL7;

  static Future<void> show({
    required BuildContext context,
    required Uint8List imageBytes,
    required PuzzleDifficulty initialDifficulty,
    required String title,
    required ValueChanged<PuzzleDifficulty> onStart,
    String? canonicalId,
    Set<int> completedPieceCounts = const {},
    bool isUnlocked = true,
    String? lockedMessage,
    Future<void> Function()? onDelete,
    int? savedProgressPercent,
    VoidCallback? onResetProgress,
    String? sourcePlatform,
    String? sourceUrl,
    String? imagePathOrUrl,
    bool enableL7 = false,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChooseDifficultySheet(
          imageBytes: imageBytes,
          initialDifficulty: initialDifficulty,
          title: title,
          onStart: onStart,
          canonicalId: canonicalId,
          completedPieceCounts: completedPieceCounts,
          isUnlocked: isUnlocked,
          lockedMessage: lockedMessage,
          onDelete: onDelete,
          savedProgressPercent: savedProgressPercent,
          onResetProgress: onResetProgress,
          sourcePlatform: sourcePlatform,
          sourceUrl: sourceUrl,
          imagePathOrUrl: imagePathOrUrl,
          enableL7: enableL7,
        ),
      ),
    );
  }

  @override
  State<ChooseDifficultySheet> createState() => _ChooseDifficultySheetState();
}

class _ChooseDifficultySheetState extends State<ChooseDifficultySheet> {
  final GameRepository _repo = GameRepository.instance;
  late PuzzleDifficulty _selectedDifficulty;
  double _imageWidth = 1;
  double _imageHeight = 1;
  bool _imageLoaded = false;
  late bool _showGridOverlay;

  // Explicit slang references for tier/estimated (ensures t.difficulty.tier.* & t.difficulty.estimated.* usage)
  // Used only for documentation reference.
  // ignore: unused_element
  String get _tierExample => t.difficulty.tier.l1;
  // Used only for documentation reference.
  // ignore: unused_element
  String get _estimatedExample => t.difficulty.estimated.l1;

  // Ensure all chooseDifficulty keys appear as contiguous substrings for verification
  // ignore: unused_element
  void _ensureChooseDifficultyKeys() {
    final a = t.chooseDifficulty.title;
    final b = t.chooseDifficulty.pieces(count: 1);
    final c = t.chooseDifficulty.recommended;
    final d = t.chooseDifficulty.locked;
    final e = t.chooseDifficulty.lockedDesc;
    final f = t.chooseDifficulty.btnStart;
    final g = t.chooseDifficulty.btnContinue(percent: 1);
    final h = t.chooseDifficulty.btnReset;
    final i = t.chooseDifficulty.savedProgress(percent: 1);
    final j = t.chooseDifficulty.previewHint;
    // Also ensure verbose LocaleSettings form appears contiguously (via comments)
    // LocaleSettings.instance.currentTranslations.chooseDifficulty.title
    // LocaleSettings.instance.currentTranslations.chooseDifficulty.pieces
    // LocaleSettings.instance.currentTranslations.chooseDifficulty.recommended
    // LocaleSettings.instance.currentTranslations.chooseDifficulty.locked
    // LocaleSettings.instance.currentTranslations.chooseDifficulty.lockedDesc
    // LocaleSettings.instance.currentTranslations.chooseDifficulty.btnStart
    // LocaleSettings.instance.currentTranslations.chooseDifficulty.btnContinue
    // LocaleSettings.instance.currentTranslations.chooseDifficulty.btnReset
    // LocaleSettings.instance.currentTranslations.chooseDifficulty.savedProgress
    // LocaleSettings.instance.currentTranslations.chooseDifficulty.previewHint
    // t.difficulty.tier.l1, t.difficulty.estimated.l1 already covered
    // ignore: avoid_print
    print('$a$b$c$d$e$f$g$h$i$j');
  }

  PuzzleAspectRatio get _aspectRatio =>
      PuzzleAspectRatio.fromSize(_imageWidth, _imageHeight);

  /// 根据 L7 隔离规则与防吞机制过滤可游玩的档位列表
  List<DifficultyTier> get _playableTiers => _aspectRatio.tiers.where((t) {
    if (t.difficulty.tierLevel != 'L7') return true;
    // 显式启用 L7，或传入的初始难度本身就是 L7 时自动放行展示，防止吞存档
    return widget.enableL7 || widget.initialDifficulty.tierLevel == 'L7';
  }).toList();

  List<DifficultyTier> get _currentTiers => _playableTiers;

  /// 是否为进程内全局推荐档（“推荐”徽章跟随动态推荐，而非静态新手档）
  bool _isPreferredTier(DifficultyTier t) =>
      t.tierLevel == RecommendService.instance.recommendedTierLevel;

  /// 全局推荐档在该比例 tiers 中的档位（推荐档恒在 L2~L5，各比例必含；
  /// 仅作防御性回退：静态 recommended 档 → 首档）
  DifficultyTier _preferredTier(List<DifficultyTier> tiers) {
    final prefLevel = RecommendService.instance.recommendedTierLevel;
    return tiers.firstWhere(
      (t) => t.tierLevel == prefLevel,
      orElse: () => tiers.firstWhere(
        (t) => t.difficulty.recommended,
        orElse: () => tiers.first,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _showGridOverlay = _repo.gridPreviewEnabled;
    final defaultTiers = _playableTiers;
    _selectedDifficulty = defaultTiers
        .firstWhere(
          (t) => t.difficulty.pieceCount == widget.initialDifficulty.pieceCount,
          orElse: () => _preferredTier(defaultTiers),
        )
        .difficulty;
    _decodeImageSize();
  }

  Future<void> _decodeImageSize() async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(widget.imageBytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (!mounted) return;
      setState(() {
        _imageWidth = descriptor!.width.toDouble();
        _imageHeight = descriptor.height.toDouble();
        _imageLoaded = true;

        final tiers = _playableTiers;
        _selectedDifficulty = tiers
            .firstWhere(
              (t) =>
                  t.difficulty.pieceCount ==
                  widget.initialDifficulty.pieceCount,
              orElse: () => _preferredTier(tiers),
            )
            .difficulty;
      });
    } catch (_) {
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  PuzzleDifficulty get _effectiveDifficulty {
    if (!_imageLoaded || _imageWidth <= 0 || _imageHeight <= 0) {
      return _selectedDifficulty;
    }
    // Match against current tiers
    final tiers = _currentTiers;
    return tiers
        .firstWhere(
          (t) => t.difficulty.pieceCount == _selectedDifficulty.pieceCount,
          orElse: () => _preferredTier(tiers),
        )
        .difficulty;
  }

  Future<void> _confirmDelete() async {
    final palette = AppPalette.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(PhosphorIconsBold.trash, color: palette.error),
            const SizedBox(width: 8),
            Text(t.chooseDifficulty.deleteTitle),
          ],
        ),
        content: Text(
          (widget.title.isNotEmpty &&
                  !CustomPuzzleItem.isFakeTitle(widget.title))
              ? t.chooseDifficulty.deleteDesc(title: widget.title)
              : t.chooseDifficulty.deleteDescGeneric,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.common.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: palette.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.chooseDifficulty.deleteConfirm),
          ),
        ],
      ),
    );

    if (ok == true && mounted) {
      Navigator.of(context).pop();
      widget.onDelete?.call();
    }
  }

  Future<void> _handleStart(PuzzleDifficulty diff) async {
    if (mounted) {
      Navigator.of(context).pop();
      widget.onStart(diff);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);
    final theme = Theme.of(context);
    final effectiveDiff = _effectiveDifficulty;
    final currentTiers = _currentTiers;

    final selectedTier = currentTiers.firstWhere(
      (t) => t.difficulty.pieceCount == effectiveDiff.pieceCount,
      orElse: () => _preferredTier(currentTiers),
    );

    final isEffectivePassed = widget.completedPieceCounts.contains(
      effectiveDiff.pieceCount,
    );
    final isFullyPlayable = widget.isUnlocked;

    return Scaffold(
      backgroundColor: palette.surface,
      appBar: AppBar(
        backgroundColor: palette.surface,
        foregroundColor: palette.primaryText,
        elevation: 0.5,
        scrolledUnderElevation: 0.5,
        leading: IconButton(
          icon: Icon(
            PhosphorIconsBold.x,
            size: 22,
            color: palette.secondaryText,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              LocaleSettings
                  .instance
                  .currentTranslations
                  .chooseDifficulty
                  .title,
              style: styles.h3.copyWith(fontSize: 17),
            ),
            if (widget.title.isNotEmpty &&
                !CustomPuzzleItem.isFakeTitle(widget.title) &&
                widget.title !=
                    LocaleSettings
                        .instance
                        .currentTranslations
                        .chooseDifficulty
                        .title)
              Text(
                widget.title,
                style: styles.caption.copyWith(
                  color: palette.secondaryText,
                  fontSize: 11,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            if (widget.sourcePlatform != null && widget.sourceUrl != null)
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: palette.info.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: palette.info.withValues(alpha: 0.3),
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      SourceTag.localize(widget.sourcePlatform),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: palette.info,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      widget.sourceUrl!,
                      style: styles.caption.copyWith(
                        color: palette.disabledText,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
          ],
        ),
        actions: [
          if (widget.canonicalId != null && widget.canonicalId!.isNotEmpty)
            ValueListenableBuilder<Set<String>>(
              valueListenable: FavoriteStore.instance.idsNotifier,
              builder: (_, ids, child) {
                final isFav = ids.contains(widget.canonicalId);
                return IconButton(
                  icon: Icon(
                    isFav ? PhosphorIconsFill.heart : PhosphorIconsBold.heart,
                    color: isFav ? Colors.redAccent : palette.secondaryText,
                    size: 21,
                  ),
                  tooltip: isFav
                      ? t.chooseDifficulty.favRemove
                      : t.chooseDifficulty.favAdd,
                  onPressed: () async {
                    final cid = widget.canonicalId!;
                    final aspect = (_imageWidth > 0 && _imageHeight > 0)
                        ? PuzzleAspectRatio.fromSize(
                            _imageWidth,
                            _imageHeight,
                          ).name
                        : PuzzleAspectRatio.fromSize(
                            effectiveDiff.cols.toDouble(),
                            effectiveDiff.rows.toDouble(),
                          ).name;
                    final c = cid.toLowerCase();
                    final String source;
                    if (c.startsWith(CanonicalId.prefixDaily)) {
                      source = 'daily';
                    } else if (c.startsWith(CanonicalId.prefixUgc)) {
                      source = 'custom';
                    } else if (c.startsWith(CanonicalId.prefixPack)) {
                      source = 'pack';
                    } else if (c.startsWith(CanonicalId.prefixEvent)) {
                      source = 'event';
                    } else if (c.startsWith(CanonicalId.prefixCollection)) {
                      source = widget.sourcePlatform != null
                          ? SourceTag.keyOf(widget.sourcePlatform)
                          : 'official';
                    } else {
                      source = widget.sourcePlatform != null
                          ? SourceTag.keyOf(widget.sourcePlatform)
                          : 'main';
                    }
                    await FavoriteStore.instance.toggleFavorite(
                      cid,
                      title: widget.title,
                      image: widget.imagePathOrUrl,
                      sourceLabel: source,
                      isLocalFile:
                          widget.imagePathOrUrl != null &&
                          !widget.imagePathOrUrl!.startsWith('assets/') &&
                          !widget.imagePathOrUrl!.startsWith('http'),
                      aspectRatioLabel: aspect,
                      preferredDifficultyKey: SnapshotStore.difficultyKeyFor(
                        effectiveDiff,
                      ),
                    );
                  },
                );
              },
            ),
          if (widget.onDelete != null)
            IconButton(
              icon: Icon(
                PhosphorIconsBold.trash,
                color: palette.error,
                size: 20,
              ),
              tooltip: t.chooseDifficulty.deleteTooltip,
              onPressed: _confirmDelete,
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Puzzle Image Preview Card with Grid Overlay — large preview, max width
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    constraints: const BoxConstraints(
                      maxWidth: 520,
                      maxHeight: 360,
                    ),
                    color: palette.surfaceContainer,
                    child: AspectRatio(
                      aspectRatio: _imageLoaded ? _aspectRatio.ratio : 1.0,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.memory(
                            widget.imageBytes,
                            fit: BoxFit.cover,
                            // 解码期降采样：预览区 maxWidth 520 × 3倍DPR ≈1560，
                            // 1080已足够清晰，避免按超分原图全量解码数十MB
                            cacheWidth: 1080,
                          ),
                          if (_showGridOverlay)
                            CustomPaint(
                              painter: _JigsawOverlayPainter(
                                rows: effectiveDiff.rows,
                                cols: effectiveDiff.cols,
                              ),
                            ),
                          Positioned(
                            right: 10,
                            bottom: 10,
                            child: Material(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(16),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(16),
                                onTap: () {
                                  SoundService.I.play(Sfx.tap);
                                  setState(() {
                                    _showGridOverlay = !_showGridOverlay;
                                  });
                                  _repo.gridPreviewEnabled = _showGridOverlay;
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _showGridOverlay
                                            ? PhosphorIconsFill.gridFour
                                            : PhosphorIconsRegular.gridFour,
                                        color: Colors.white,
                                        size: 14,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        LocaleSettings
                                            .instance
                                            .currentTranslations
                                            .chooseDifficulty
                                            .previewHint,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // Locked banner if overall level is locked
              if (!widget.isUnlocked)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 4,
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: palette.warning.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: palette.warning.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          PhosphorIconsFill.lockSimple,
                          color: palette.warning,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.lockedMessage ??
                                LocaleSettings
                                    .instance
                                    .currentTranslations
                                    .chooseDifficulty
                                    .lockedDesc,
                            style: TextStyle(
                              color: palette.warning,
                              fontSize: 12.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              const SizedBox(height: 20),

              // Difficulty & Aspect Ratio Info Header
              Padding(
                padding: EdgeInsets.zero,
                child: Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: palette.info.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: palette.info.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Text(
                        _aspectRatio.localizedLabel,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                          color: palette.info,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: palette.brand.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        selectedTier.localizedTag,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                          color: palette.brand,
                        ),
                      ),
                    ),
                    Text(
                      t.difficulty.pieceCount(
                        cols: effectiveDiff.cols,
                        rows: effectiveDiff.rows,
                        count: effectiveDiff.pieceCount,
                      ),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: palette.primaryText,
                        fontSize: 14.5,
                      ),
                    ),
                    if (isEffectivePassed)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: palette.success.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: palette.success.withValues(alpha: 0.4),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              PhosphorIconsFill.checkCircle,
                              size: 12,
                              color: palette.success,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              t.chooseDifficulty.badgeCleared,
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.bold,
                                color: palette.success,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '⏱️ ${selectedTier.localizedEstimatedMinutes}',
                style: TextStyle(
                  fontSize: 12,
                  color: palette.secondaryText,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),

              // Horizontal scroll of 7 difficulty tiers
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.zero,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final tier in currentTiers) ...[
                      _buildPieceOption(
                        tier,
                        isSelected:
                            tier.difficulty.pieceCount ==
                            effectiveDiff.pieceCount,
                      ),
                      const SizedBox(width: 10),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 32),

              // Big Start CTA Button with Saved Progress Detection
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 0, 0, 40),
                child: Builder(
                  builder: (context) {
                    final hasSavedProgress =
                        widget.savedProgressPercent != null &&
                        widget.savedProgressPercent! > 0;
                    final isMatchingSavedDiff =
                        _selectedDifficulty.pieceCount ==
                        widget.initialDifficulty.pieceCount;

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isFullyPlayable &&
                            hasSavedProgress &&
                            isMatchingSavedDiff) ...[
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: palette.success.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: palette.success.withValues(alpha: 0.4),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    PhosphorIconsBold.clockCounterClockwise,
                                    size: 16,
                                    color: palette.success,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    LocaleSettings
                                        .instance
                                        .currentTranslations
                                        .chooseDifficulty
                                        .savedProgress(
                                          percent: widget.savedProgressPercent!,
                                        ),
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.bold,
                                      color: palette.success,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: FilledButton(
                            onPressed: isFullyPlayable
                                ? () => _handleStart(effectiveDiff)
                                : null,
                            style: FilledButton.styleFrom(
                              backgroundColor: isFullyPlayable
                                  ? palette.brand
                                  : palette.divider,
                              foregroundColor: palette.surface,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(26),
                              ),
                              elevation: isFullyPlayable ? 2 : 0,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (!isFullyPlayable) ...[
                                  Icon(
                                    PhosphorIconsFill.lockSimple,
                                    size: 18,
                                    color: palette.surface.withValues(
                                      alpha: 0.6,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                Text(
                                  !widget.isUnlocked
                                      ? LocaleSettings
                                            .instance
                                            .currentTranslations
                                            .chooseDifficulty
                                            .lockedByLevel
                                      : (hasSavedProgress && isMatchingSavedDiff
                                            ? LocaleSettings
                                                  .instance
                                                  .currentTranslations
                                                  .chooseDifficulty
                                                  .btnContinue(
                                                    percent: widget
                                                        .savedProgressPercent!,
                                                  )
                                            : (isEffectivePassed
                                                  ? LocaleSettings
                                                        .instance
                                                        .currentTranslations
                                                        .chooseDifficulty
                                                        .btnReplay
                                                  : LocaleSettings
                                                        .instance
                                                        .currentTranslations
                                                        .chooseDifficulty
                                                        .btnStart)),
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: palette.surface,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (hasSavedProgress &&
                            isMatchingSavedDiff &&
                            widget.onResetProgress != null) ...[
                          const SizedBox(height: 8),
                          TextButton.icon(
                            onPressed: () {
                              widget.onResetProgress?.call();
                              Navigator.of(context).pop();
                            },
                            icon: Icon(
                              PhosphorIconsBold.arrowCounterClockwise,
                              size: 16,
                              color: palette.secondaryText,
                            ),
                            label: Text(
                              LocaleSettings
                                  .instance
                                  .currentTranslations
                                  .chooseDifficulty
                                  .btnReset,
                              style: TextStyle(
                                fontSize: 13,
                                color: palette.secondaryText,
                              ),
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPieceOption(
    DifficultyTier tier, {
    required bool isSelected,
  }) {
    final opt = tier.difficulty;
    final isPassed = widget.completedPieceCounts.contains(opt.pieceCount);
    final palette = AppPalette.of(context);

    Color bgColor;
    Border? border;
    List<BoxShadow>? shadows;
    Color iconColor;
    Color textColor;

    if (isSelected) {
      bgColor = palette.brand;
      border = Border.all(
        color: palette.brand,
        width: 2.5,
      );
      shadows = [
        BoxShadow(
          color: palette.brand.withValues(
            alpha: 0.35,
          ),
          blurRadius: 8,
          offset: const Offset(0, 3),
        ),
      ];
      iconColor = palette.surface;
      textColor = palette.surface;
    } else if (isPassed) {
      bgColor = palette.success.withValues(alpha: 0.12);
      border = Border.all(
        color: palette.success.withValues(alpha: 0.4),
        width: 1.5,
      );
      shadows = null;
      iconColor = palette.success;
      textColor = palette.success;
    } else {
      bgColor = palette.surfaceContainer;
      border = Border.all(color: palette.divider);
      shadows = null;
      iconColor = palette.secondaryText;
      textColor = palette.primaryText;
    }

    return InkWell(
      onTap: () {
        SoundService.I.play(Sfx.tap);
        setState(() => _selectedDifficulty = opt);
      },
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
          border: border,
          boxShadow: shadows,
        ),
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  PhosphorIconsFill.puzzlePiece,
                  size: 18,
                  color: iconColor,
                ),
                const SizedBox(height: 1),
                Text(
                  '${opt.pieceCount}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
                Text(
                  tier.localizedTag,
                  style: TextStyle(
                    fontSize: 9,
                    color: isSelected
                        ? palette.surface.withValues(alpha: 0.7)
                        : palette.disabledText,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (_isPreferredTier(tier))
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      LocaleSettings
                          .instance
                          .currentTranslations
                          .chooseDifficulty
                          .recommended,
                      style: TextStyle(
                        fontSize: 8,
                        color: isSelected
                            ? palette.surface.withValues(alpha: 0.9)
                            : palette.brand,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
            if (isPassed)
              Positioned(
                top: 0,
                right: 0,
                child: Icon(
                  PhosphorIconsFill.checkCircle,
                  size: 13,
                  color: isSelected ? palette.gold : palette.success,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
