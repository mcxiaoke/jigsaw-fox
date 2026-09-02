import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../data/game_repository.dart';
import '../data/progress_store.dart';
import '../logic/cache/image_cache_manager.dart';
import '../services/economy_service.dart';
import '../services/sound_service.dart';
import '../theme/app_palette.dart';
import '../theme/app_text_styles.dart';
import '../widgets/choose_background_sheet.dart';
import '../widgets/game_toast.dart';
import 'how_to_play_page.dart';

/// Full-screen Game Settings page with grouped settings cards.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
    );
  }

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _repo = GameRepository.instance;
  int _totalSolved = 0;
  int _totalStars = 0;
  int _coins = 0;
  String _cacheSize = '计算中…';
  bool _clearingCache = false;

  @override
  void initState() {
    super.initState();
    _loadStats();
    _loadCacheSize();
  }

  Future<void> _loadStats() async {
    final solved = await ProgressStore.instance.getTotalSolved();
    final stars = await ProgressStore.instance.getTotalStars();
    if (mounted) {
      setState(() {
        _totalSolved = solved;
        _totalStars = stars;
        _coins = EconomyService.instance.coins;
      });
    }
  }

  /// 异步统计缩略图磁盘缓存占用（列表目录累加字节数，可能耗时数百毫秒）
  Future<void> _loadCacheSize() async {
    final size = await ImageCacheManager.instance.getFormattedCacheSize();
    if (mounted) {
      setState(() => _cacheSize = size);
    }
  }

  Future<void> _clearThumbnailCache() async {
    if (_clearingCache) return;
    setState(() => _clearingCache = true);
    try {
      await ImageCacheManager.instance.clearCache();
      await _loadCacheSize();
      if (mounted) {
        GameToast.show(
          context,
          icon: PhosphorIconsFill.broom,
          message: '缩略图缓存已清空，下次浏览时会自动重新生成',
          type: GameToastType.success,
        );
      }
    } catch (e) {
      if (mounted) {
        GameToast.show(
          context,
          icon: PhosphorIconsRegular.warning,
          message: '清理缓存失败: $e',
          type: GameToastType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _clearingCache = false);
    }
  }

  String _formatPlayTime(int seconds) {
    if (seconds < 60) return '$seconds 秒';
    final hours = seconds ~/ 3600;
    final mins = (seconds % 3600) ~/ 60;
    if (hours > 0) return '$hours 小时 $mins 分';
    return '$mins 分';
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);

    return Scaffold(
      backgroundColor: palette.surface,
      appBar: AppBar(
        backgroundColor: palette.surface,
        foregroundColor: palette.primaryText,
        elevation: 0.5,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(PhosphorIconsFill.gearSix, color: palette.brand, size: 24),
            const SizedBox(width: 8),
            Text('游戏设置', style: styles.h3.copyWith(fontSize: 19)),
          ],
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            children: [
              // Player Identity Card
              _buildPlayerIdentityCard(palette, styles),

              const SizedBox(height: 18),

              // Group 1: Audio & Haptics
              _buildSectionHeader('音效与交互', palette, styles),
              _buildCardContainer([
                SwitchListTile(
                  title: Text('拼图吸附音效', style: styles.bodyBold),
                  subtitle: Text('碎片对齐磁吸时播放清脆音效', style: styles.caption),
                  secondary: Icon(PhosphorIconsBold.speakerHigh, color: palette.brand),
                  activeThumbColor: palette.brand,
                  value: _repo.soundEnabled,
                  onChanged: (v) {
                    if (v) {
                      _repo.soundEnabled = v;
                      SoundService.I.play(Sfx.switchToggle, ignoreMute: true);
                    } else {
                      SoundService.I.play(Sfx.switchToggle, ignoreMute: true);
                      _repo.soundEnabled = v;
                    }
                    setState(() {});
                  },
                ),
                Divider(height: 1, indent: 56, color: palette.divider),
                SwitchListTile(
                  title: Text('触感震动反馈', style: styles.bodyBold),
                  subtitle: Text('拼图吸附与操作时的触觉微震', style: styles.caption),
                  secondary: Icon(PhosphorIconsBold.vibrate, color: palette.brand),
                  activeThumbColor: palette.brand,
                  value: _repo.hapticEnabled,
                  onChanged: (v) => setState(() => _repo.hapticEnabled = v),
                ),
                Divider(height: 1, indent: 56, color: palette.divider),
                SwitchListTile(
                  title: Text('选关切图网格预览', style: styles.bodyBold),
                  subtitle: Text('在难度选择预览图上叠加异形切线', style: styles.caption),
                  secondary: Icon(PhosphorIconsBold.gridFour, color: palette.brand),
                  activeThumbColor: palette.brand,
                  value: _repo.gridPreviewEnabled,
                  onChanged: (v) => setState(() => _repo.gridPreviewEnabled = v),
                ),
                Divider(height: 1, indent: 56, color: palette.divider),
                ListTile(
                  leading: Icon(PhosphorIconsBold.squaresFour, color: palette.brand),
                  title: Text('碎片初始排布模式', style: styles.bodyBold),
                  subtitle: Text(_repo.pieceScatterMode == 'tabletop'
                      ? '桌面环形散落（推荐宽屏/平板）'
                      : '底部托盘收纳（默认/推荐手机）', style: styles.caption),
                  trailing: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'tray', label: Text('托盘')),
                      ButtonSegment(value: 'tabletop', label: Text('桌面')),
                    ],
                    selected: {_repo.pieceScatterMode},
                    onSelectionChanged: (set) {
                      setState(() => _repo.pieceScatterMode = set.first);
                    },
                  ),
                ),
              ], palette),

              const SizedBox(height: 18),

              // Group 2: Appearance & Background
              _buildSectionHeader('外观与背景', palette, styles),
              _buildCardContainer([
                ListTile(
                  leading: Icon(PhosphorIconsBold.image, color: palette.info),
                  title: Text('默认壁纸背景', style: styles.bodyBold),
                  subtitle: Text('选择拼图对局时的全屏桌面背景', style: styles.caption),
                  trailing: Icon(PhosphorIconsBold.caretRight, size: 18, color: palette.secondaryText),
                  onTap: () {
                    ChooseBackgroundSheet.show(
                      context: context,
                      selectedBackground: _repo.selectedBackground,
                      onBackgroundSelected: (bg) {
                        setState(() => _repo.selectedBackground = bg);
                      },
                    );
                  },
                ),
              ], palette),

              const SizedBox(height: 18),

              // Group 3: Help & Guide
              _buildSectionHeader('玩法与帮助', palette, styles),
              _buildCardContainer([
                ListTile(
                  leading: Icon(PhosphorIconsBold.question, color: palette.success),
                  title: Text('玩法技巧与操作指引', style: styles.bodyBold),
                  subtitle: Text('手势操作、组队拖拽、底图透视、整理工具说明', style: styles.caption),
                  trailing: Icon(PhosphorIconsBold.caretRight, size: 18, color: palette.secondaryText),
                  onTap: () => HowToPlayPage.open(context),
                ),
              ], palette),

              const SizedBox(height: 18),

              // Group 4: Data Management
              _buildSectionHeader('数据管理', palette, styles),
              _buildCardContainer([
                ListTile(
                  leading: Icon(PhosphorIconsBold.database, color: palette.info),
                  title: Text('缩略图缓存', style: styles.bodyBold),
                  subtitle: Text('卡片预览图的本地缓存，当前占用 $_cacheSize', style: styles.caption),
                  trailing: _clearingCache
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : TextButton.icon(
                          onPressed: _clearThumbnailCache,
                          icon: Icon(PhosphorIconsBold.broom, size: 16),
                          label: const Text('清理'),
                        ),
                ),
                Divider(height: 1, indent: 56, color: palette.divider),
                ListTile(
                  leading: Icon(PhosphorIconsBold.trashSimple, color: palette.error),
                  title: Text('重置所有游戏数据', style: styles.bodyBold.copyWith(color: palette.error)),
                  subtitle: Text('清除所有关卡记录、每日挑战与自制拼图', style: styles.caption),
                  trailing: Icon(PhosphorIconsBold.caretRight, size: 18, color: palette.error),
                  onTap: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        title: const Text('确认重置全部数据？'),
                        content: const Text('该操作不可逆，将清除所有主线关卡进度、每日挑战与自制拼图记录。'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            style: FilledButton.styleFrom(backgroundColor: palette.error),
                            child: const Text('确定重置'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) {
                      await _repo.resetAllData();
                      if (context.mounted) {
                        setState(() {});
                        GameToast.show(
                          context,
                          icon: PhosphorIconsFill.trashSimple,
                          message: '所有游戏数据已重置为初始状态',
                          type: GameToastType.warning,
                        );
                      }
                    }
                  },
                ),
              ], palette),

              const SizedBox(height: 24),

              // App Footer
              Center(
                child: Column(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: palette.brand.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(PhosphorIconsFill.puzzlePiece, color: palette.brand, size: 28),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '异形拼图 Jigsaw Puzzle',
                      style: styles.captionBold.copyWith(color: palette.secondaryText),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '版本 1.0.0',
                      style: styles.caption.copyWith(color: palette.disabledText),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, AppPalette palette, AppTextStyles styles) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: styles.captionBold.copyWith(
          color: palette.secondaryText,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildCardContainer(List<Widget> children, AppPalette palette) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: palette.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.divider, width: 1),
      ),
      child: Column(
        children: children,
      ),
    );
  }

  Widget _buildPlayerIdentityCard(AppPalette palette, AppTextStyles styles) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            palette.surfaceContainer,
            palette.surfaceContainerLow,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: palette.brand.withValues(alpha: 0.25), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: palette.brand.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          // Fox avatar
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: palette.brand.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: palette.brand.withValues(alpha: 0.4), width: 2),
            ),
            child: const Center(
              child: Text('🦊', style: TextStyle(fontSize: 32)),
            ),
          ),
          const SizedBox(width: 16),
          // Player info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('拼图玩家', style: styles.h3.copyWith(fontSize: 18)),
                const SizedBox(height: 4),
                Text(
                  '已游玩 ${_formatPlayTime(_repo.totalPlayTimeSeconds)}',
                  style: styles.caption,
                ),
                const SizedBox(height: 10),
                // Asset HUD
                Row(
                  children: [
                    _buildAssetChip(
                      icon: PhosphorIconsFill.coins,
                      value: '$_coins',
                      color: palette.gold,
                      palette: palette,
                      styles: styles,
                    ),
                    const SizedBox(width: 8),
                    _buildAssetChip(
                      icon: PhosphorIconsFill.star,
                      value: '$_totalStars',
                      color: palette.brand,
                      palette: palette,
                      styles: styles,
                    ),
                    const SizedBox(width: 8),
                    _buildAssetChip(
                      icon: PhosphorIconsFill.trophy,
                      value: '$_totalSolved',
                      color: palette.success,
                      palette: palette,
                      styles: styles,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAssetChip({
    required IconData icon,
    required String value,
    required Color color,
    required AppPalette palette,
    required AppTextStyles styles,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            value,
            style: styles.captionBold.copyWith(color: color, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
