import 'package:flutter/material.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/progress_store.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/logic/cache/image_cache_manager.dart';
import 'package:jigsawpuzzle/pages/how_to_play_page.dart';
import 'package:jigsawpuzzle/pages/log_viewer_page.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:jigsawpuzzle/services/economy_service.dart';
import 'package:jigsawpuzzle/services/locale_service.dart';
import 'package:jigsawpuzzle/services/sound_service.dart';
import 'package:jigsawpuzzle/theme/app_palette.dart';
import 'package:jigsawpuzzle/theme/app_text_styles.dart';
import 'package:jigsawpuzzle/widgets/choose_background_sheet.dart';
import 'package:jigsawpuzzle/widgets/game_toast.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

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
  final GameRepository _repo = GameRepository.instance;
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

  // 清空图片缓存入口暂时隐藏期间，此方法暂无调用方；保留代码待入口重新开放
  // ignore: unused_element
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
                  trailing: _CompactModeToggle(
                    value: _repo.pieceScatterMode,
                    onChanged: (mode) =>
                        setState(() => _repo.pieceScatterMode = mode),
                    trayLabel: t.settings.scatterTray,
                    tabletopLabel: t.settings.scatterTabletop,
                    palette: palette,
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
                  trailing: AnimatedBuilder(
                    animation: LocaleService.instance,
                    builder: (context, _) {
                      final lang = LocaleService.instance.language;
                      final name = switch (lang) {
                        AppLanguage.system => t.settings.languageSystem,
                        AppLanguage.zh => t.settings.languageZh,
                        AppLanguage.en => t.settings.languageEn,
                      };
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            name,
                            style: styles.captionBold.copyWith(
                              color: palette.brand,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            PhosphorIconsBold.caretRight,
                            size: 16,
                            color: palette.secondaryText,
                          ),
                        ],
                      );
                    },
                  ),
                  onTap: () =>
                      _showLanguageSelectionSheet(context, palette, styles),
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
                // 清空图片缓存入口暂时隐藏（代码保留，待后续版本再开放入口）
                // ListTile(
                //   leading: Icon(
                //     PhosphorIconsBold.database,
                //     color: palette.info,
                //   ),
                //   title: Text(
                //     t.settings.dataCacheTitle,
                //     style: styles.bodyBold,
                //   ),
                //   subtitle: Text(
                //     t.settings.dataCacheDesc(size: _cacheSize),
                //     style: styles.caption,
                //   ),
                //   trailing: _clearingCache
                //       ? const SizedBox(
                //           width: 20,
                //           height: 20,
                //           child: CircularProgressIndicator(strokeWidth: 2),
                //         )
                //       : TextButton.icon(
                //           onPressed: _clearThumbnailCache,
                //           icon: const Icon(PhosphorIconsBold.broom, size: 16),
                //           label: Text(t.settings.dataClear),
                //         ),
                // ),
                // Divider(height: 1, indent: 56, color: palette.divider),
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
        side: BorderSide(color: palette.divider),
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
        border: Border.all(color: color.withValues(alpha: 0.25)),
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

  void _showLanguageSelectionSheet(
    BuildContext context,
    AppPalette palette,
    AppTextStyles styles,
  ) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: palette.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: AnimatedBuilder(
              animation: LocaleService.instance,
              builder: (ctx, _) {
                final current = LocaleService.instance.language;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: palette.divider,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            PhosphorIconsBold.translate,
                            color: palette.brand,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            t.settings.languageTitle,
                            style: styles.h3.copyWith(
                              color: palette.primaryText,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildLanguageOption(
                      title: t.settings.languageSystem,
                      icon: PhosphorIconsRegular.globe,
                      selected: current == AppLanguage.system,
                      palette: palette,
                      styles: styles,
                      onTap: () async {
                        await LocaleService.instance.setLanguage(
                          AppLanguage.system,
                        );
                        if (sheetContext.mounted) Navigator.pop(sheetContext);
                        if (mounted) setState(() {});
                      },
                    ),
                    _buildLanguageOption(
                      title: t.settings.languageZh,
                      icon: PhosphorIconsRegular.textT,
                      selected: current == AppLanguage.zh,
                      palette: palette,
                      styles: styles,
                      onTap: () async {
                        await LocaleService.instance.setLanguage(
                          AppLanguage.zh,
                        );
                        if (sheetContext.mounted) Navigator.pop(sheetContext);
                        if (mounted) setState(() {});
                      },
                    ),
                    _buildLanguageOption(
                      title: t.settings.languageEn,
                      icon: PhosphorIconsRegular.textT,
                      selected: current == AppLanguage.en,
                      palette: palette,
                      styles: styles,
                      onTap: () async {
                        await LocaleService.instance.setLanguage(
                          AppLanguage.en,
                        );
                        if (sheetContext.mounted) Navigator.pop(sheetContext);
                        if (mounted) setState(() {});
                      },
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildLanguageOption({
    required String title,
    required IconData icon,
    required bool selected,
    required AppPalette palette,
    required AppTextStyles styles,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(
        icon,
        color: selected ? palette.brand : palette.secondaryText,
      ),
      title: Text(
        title,
        style: selected
            ? styles.bodyBold.copyWith(color: palette.brand)
            : styles.body.copyWith(color: palette.primaryText),
      ),
      trailing: selected
          ? Icon(PhosphorIconsBold.check, color: palette.brand, size: 20)
          : null,
      onTap: onTap,
    );
  }
}

class _CompactModeToggle extends StatelessWidget {
  const _CompactModeToggle({
    required this.value,
    required this.onChanged,
    required this.trayLabel,
    required this.tabletopLabel,
    required this.palette,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final String trayLabel;
  final String tabletopLabel;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final isTabletop = value == 'tabletop';
    return Container(
      width: 128,
      height: 32,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: palette.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.divider),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onChanged('tray'),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: !isTabletop ? palette.brand : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: !isTabletop
                      ? [
                          BoxShadow(
                            color: palette.brand.withValues(alpha: 0.3),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  trayLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: !isTabletop
                        ? FontWeight.bold
                        : FontWeight.normal,
                    color: !isTabletop
                        ? palette.surface
                        : palette.secondaryText,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onChanged('tabletop'),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isTabletop ? palette.brand : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: isTabletop
                      ? [
                          BoxShadow(
                            color: palette.brand.withValues(alpha: 0.3),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  tabletopLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: isTabletop
                        ? FontWeight.bold
                        : FontWeight.normal,
                    color: isTabletop ? palette.surface : palette.secondaryText,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
