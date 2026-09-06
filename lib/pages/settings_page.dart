import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../data/game_repository.dart';
import '../data/progress_store.dart';
import '../l10n/gen/strings.g.dart';
import '../logic/cache/image_cache_manager.dart';
import '../services/app_logger.dart';
import '../services/economy_service.dart';
import '../services/locale_service.dart';
import '../services/sound_service.dart';
import '../theme/app_palette.dart';
import '../theme/app_text_styles.dart';
import '../widgets/choose_background_sheet.dart';
import '../widgets/game_toast.dart';
import 'how_to_play_page.dart';
import 'log_viewer_page.dart';

/// Full-screen Game Settings page with grouped settings cards.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
  }

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _repo = GameRepository.instance;
  int _totalSolved = 0;
  int _totalStars = 0;
  int _coins = 0;
  String _cacheSize = '';
  bool _clearingCache = false;

  @override
  void initState() {
    super.initState();
    // 初始化缓存大小占位文案需 context，延后到 didChangeDependencies
    _loadStats();
    _loadCacheSize();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_cacheSize.isEmpty) {
      // 使用全局 t，避免测试环境缺少 TranslationProvider 时崩溃
      _cacheSize = t.common.calculating;
    }
  }

  Translations get t => LocaleSettings.instance.currentTranslations;

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
      AppLogger.ui.info('Settings clear thumbnail cache start');
      await ImageCacheManager.instance.clearCache();
      await _loadCacheSize();
      AppLogger.ui.info('Settings clear thumbnail cache done');
      if (mounted) {
        GameToast.show(
          context,
          icon: PhosphorIconsFill.broom,
          message: t.settings.toastCacheCleared,
          type: GameToastType.success,
        );
      }
    } catch (e, st) {
      AppLogger.ui.warning('Settings clear thumbnail cache failed', e, st);
      if (mounted) {
        GameToast.show(
          context,
          icon: PhosphorIconsRegular.warning,
          message: t.settings.toastCacheClearFailed(error: '$e'),
          type: GameToastType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _clearingCache = false);
    }
  }

  String _formatPlayTime(int seconds) {
    if (seconds < 60) {
      return t.settings.timeSeconds(count: seconds);
    }
    final hours = seconds ~/ 3600;
    final mins = (seconds % 3600) ~/ 60;
    if (hours > 0) {
      return t.settings.timeHoursMinutes(hours: hours, minutes: mins);
    }
    return t.settings.timeMinutes(count: mins);
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
        title: Text(t.settings.title, style: styles.h3.copyWith(fontSize: 19)),
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
              _buildSectionHeader(t.settings.sectionsAudio, palette, styles),
              _buildCardContainer([
                SwitchListTile(
                  title: Text(
                    t.settings.snapSoundTitle,
                    style: styles.bodyBold,
                  ),
                  subtitle: Text(
                    t.settings.snapSoundDesc,
                    style: styles.caption,
                  ),
                  secondary: Icon(
                    PhosphorIconsBold.speakerHigh,
                    color: palette.brand,
                  ),
                  activeThumbColor: palette.brand,
                  value: _repo.soundEnabled,
                  onChanged: (v) {
                    if (v) {
                      _repo.soundEnabled = v;
                      SoundService.I.play(Sfx.switchToggle, ignoreMute: true);
                    } else {
                      SoundService.I.stopAll();
                      SoundService.I.play(Sfx.switchToggle, ignoreMute: true);
                      _repo.soundEnabled = v;
                    }
                    setState(() {});
                  },
                ),
                Divider(height: 1, indent: 56, color: palette.divider),
                SwitchListTile(
                  title: Text(t.settings.hapticTitle, style: styles.bodyBold),
                  subtitle: Text(t.settings.hapticDesc, style: styles.caption),
                  secondary: Icon(
                    PhosphorIconsBold.vibrate,
                    color: palette.brand,
                  ),
                  activeThumbColor: palette.brand,
                  value: _repo.hapticEnabled,
                  onChanged: (v) => setState(() => _repo.hapticEnabled = v),
                ),
                Divider(height: 1, indent: 56, color: palette.divider),
                SwitchListTile(
                  title: Text(
                    t.settings.gridPreviewTitle,
                    style: styles.bodyBold,
                  ),
                  subtitle: Text(
                    t.settings.gridPreviewDesc,
                    style: styles.caption,
                  ),
                  secondary: Icon(
                    PhosphorIconsBold.gridFour,
                    color: palette.brand,
                  ),
                  activeThumbColor: palette.brand,
                  value: _repo.gridPreviewEnabled,
                  onChanged: (v) =>
                      setState(() => _repo.gridPreviewEnabled = v),
                ),
                Divider(height: 1, indent: 56, color: palette.divider),
                ListTile(
                  leading: Icon(
                    PhosphorIconsBold.squaresFour,
                    color: palette.brand,
                  ),
                  title: Text(
                    t.settings.scatterModeTitle,
                    style: styles.bodyBold,
                  ),
                  subtitle: Text(
                    _repo.pieceScatterMode == 'tabletop'
                        ? t.settings.scatterModeDescTabletop
                        : t.settings.scatterModeDescTray,
                    style: styles.caption,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(
                          value: 'tray',
                          label: Text(
                            t.settings.scatterTray,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        ButtonSegment(
                          value: 'tabletop',
                          label: Text(
                            t.settings.scatterTabletop,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                      selected: {_repo.pieceScatterMode},
                      onSelectionChanged: (set) {
                        setState(() => _repo.pieceScatterMode = set.first);
                      },
                    ),
                  ),
                ),
              ], palette),

              const SizedBox(height: 18),

              // Group 2: Appearance & Background
              _buildSectionHeader(
                t.settings.sectionsAppearance,
                palette,
                styles,
              ),
              _buildCardContainer([
                ListTile(
                  leading: Icon(PhosphorIconsBold.image, color: palette.info),
                  title: Text(
                    t.settings.appearanceBgTitle,
                    style: styles.bodyBold,
                  ),
                  subtitle: Text(
                    t.settings.appearanceBgDesc,
                    style: styles.caption,
                  ),
                  trailing: Icon(
                    PhosphorIconsBold.caretRight,
                    size: 18,
                    color: palette.secondaryText,
                  ),
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

              // Group: Language
              _buildSectionHeader(t.settings.sectionsLanguage, palette, styles),
              _buildCardContainer([
                ListTile(
                  leading: Icon(
                    PhosphorIconsBold.translate,
                    color: palette.brand,
                  ),
                  title: Text(t.settings.languageTitle, style: styles.bodyBold),
                  subtitle: Text(
                    t.settings.languageDesc,
                    style: styles.caption,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: AnimatedBuilder(
                    animation: LocaleService.instance,
                    builder: (context, _) {
                      final lang = LocaleService.instance.language;
                      return FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: SegmentedButton<AppLanguage>(
                          showSelectedIcon: false,
                          segments: [
                            ButtonSegment(
                              value: AppLanguage.system,
                              label: Text(
                                t.settings.languageSystem,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            ButtonSegment(
                              value: AppLanguage.zh,
                              label: Text(
                                t.settings.languageZh,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            ButtonSegment(
                              value: AppLanguage.en,
                              label: Text(
                                t.settings.languageEn,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                          selected: {lang},
                          onSelectionChanged: (set) async {
                            final selected = set.first;
                            await LocaleService.instance.setLanguage(selected);
                            if (context.mounted) setState(() {});
                          },
                        ),
                      );
                    },
                  ),
                ),
              ], palette),

              const SizedBox(height: 18),

              // Group 3: Help & Guide
              _buildSectionHeader(t.settings.sectionsHelp, palette, styles),
              _buildCardContainer([
                ListTile(
                  leading: Icon(
                    PhosphorIconsBold.question,
                    color: palette.success,
                  ),
                  title: Text(t.settings.helpTitle, style: styles.bodyBold),
                  subtitle: Text(t.settings.helpDesc, style: styles.caption),
                  trailing: Icon(
                    PhosphorIconsBold.caretRight,
                    size: 18,
                    color: palette.secondaryText,
                  ),
                  onTap: () => HowToPlayPage.open(context),
                ),
              ], palette),

              const SizedBox(height: 18),

              // Group 4: Data Management
              _buildSectionHeader(t.settings.sectionsData, palette, styles),
              _buildCardContainer([
                ListTile(
                  leading: Icon(
                    PhosphorIconsBold.database,
                    color: palette.info,
                  ),
                  title: Text(
                    t.settings.dataCacheTitle,
                    style: styles.bodyBold,
                  ),
                  subtitle: Text(
                    t.settings.dataCacheDesc(size: _cacheSize),
                    style: styles.caption,
                  ),
                  trailing: _clearingCache
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : TextButton.icon(
                          onPressed: _clearThumbnailCache,
                          icon: Icon(PhosphorIconsBold.broom, size: 16),
                          label: Text(t.settings.dataClear),
                        ),
                ),
                Divider(height: 1, indent: 56, color: palette.divider),
                ListTile(
                  leading: Icon(
                    PhosphorIconsBold.fileText,
                    color: palette.info,
                  ),
                  title: Text(
                    t.settings.dataViewLogsTitle,
                    style: styles.bodyBold,
                  ),
                  subtitle: Text(
                    t.settings.dataViewLogsDesc,
                    style: styles.caption,
                  ),
                  trailing: Icon(
                    PhosphorIconsBold.caretRight,
                    size: 18,
                    color: palette.secondaryText,
                  ),
                  onTap: () => LogViewerPage.open(context),
                ),
                Divider(height: 1, indent: 56, color: palette.divider),
                ListTile(
                  leading: Icon(
                    PhosphorIconsBold.trashSimple,
                    color: palette.error,
                  ),
                  title: Text(
                    t.settings.dataResetTitle,
                    style: styles.bodyBold.copyWith(color: palette.error),
                  ),
                  subtitle: Text(
                    t.settings.dataResetDesc,
                    style: styles.caption,
                  ),
                  trailing: Icon(
                    PhosphorIconsBold.caretRight,
                    size: 18,
                    color: palette.error,
                  ),
                  onTap: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) {
                        final tt = LocaleSettings.instance.currentTranslations;
                        return AlertDialog(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          title: Text(tt.settings.dataResetConfirmTitle),
                          content: Text(tt.settings.dataResetConfirmDesc),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: Text(tt.settings.dataCancel),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              style: FilledButton.styleFrom(
                                backgroundColor: palette.error,
                              ),
                              child: Text(tt.settings.dataConfirmReset),
                            ),
                          ],
                        );
                      },
                    );
                    if (ok == true) {
                      AppLogger.ui.warning(
                        'Settings resetAllData coinsBefore=$_coins solvedBefore=$_totalSolved starsBefore=$_totalStars',
                      );
                      await _repo.resetAllData();
                      if (context.mounted) {
                        setState(() {});
                        GameToast.show(
                          context,
                          icon: PhosphorIconsFill.trashSimple,
                          message: t.settings.toastDataReset,
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
                child: Text(
                  t.settings.footerVersion(version: '1.0.0'),
                  style: styles.caption.copyWith(color: palette.disabledText),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(
    String title,
    AppPalette palette,
    AppTextStyles styles,
  ) {
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
    return Material(
      color: palette.surfaceContainer,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: palette.divider, width: 1),
      ),
      child: Column(children: children),
    );
  }

  Widget _buildPlayerIdentityCard(AppPalette palette, AppTextStyles styles) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [palette.surfaceContainer, palette.surfaceContainerLow],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: palette.brand.withValues(alpha: 0.25),
          width: 1.5,
        ),
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
              border: Border.all(
                color: palette.brand.withValues(alpha: 0.4),
                width: 2,
              ),
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
                Text(
                  t.settings.playerTitle,
                  style: styles.h3.copyWith(fontSize: 18),
                ),
                const SizedBox(height: 4),
                Text(
                  t.settings.playerPlayed(
                    time: _formatPlayTime(_repo.totalPlayTimeSeconds),
                  ),
                  style: styles.caption,
                ),
                const SizedBox(height: 10),
                // Asset HUD
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _buildAssetChip(
                      icon: PhosphorIconsFill.coins,
                      value: '$_coins',
                      color: palette.gold,
                      palette: palette,
                      styles: styles,
                    ),
                    _buildAssetChip(
                      icon: PhosphorIconsFill.star,
                      value: '$_totalStars',
                      color: palette.brand,
                      palette: palette,
                      styles: styles,
                    ),
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
