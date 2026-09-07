import 'package:flutter/material.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/pages/achievements_page.dart';
import 'package:jigsawpuzzle/pages/settings_page.dart';
import 'package:jigsawpuzzle/pages/tabs/collections_tab_view.dart';
import 'package:jigsawpuzzle/pages/tabs/daily_tab_view.dart';
import 'package:jigsawpuzzle/pages/tabs/home_tab_view.dart';
import 'package:jigsawpuzzle/pages/tabs/my_center_tab_view.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:jigsawpuzzle/services/locale_service.dart';
import 'package:jigsawpuzzle/services/sound_service.dart';
import 'package:jigsawpuzzle/theme/app_palette.dart';
import 'package:jigsawpuzzle/theme/app_text_styles.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// Main screen featuring the 4-tab bottom navigation (Home / Daily / Collections / My)
/// with game-styled bottom nav: filled icons + amber gold active state glow.
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    LocaleService.instance.addListener(_onLocaleChanged);
  }

  @override
  void dispose() {
    LocaleService.instance.removeListener(_onLocaleChanged);
    super.dispose();
  }

  void _onLocaleChanged() {
    if (mounted) setState(() {});
  }

  String _appBarTitle(BuildContext context) {
    final tr = LocaleSettings.instance.currentTranslations;
    switch (_currentIndex) {
      case 0:
        return tr.nav.titleHome;
      case 1:
        return tr.nav.titleDaily;
      case 2:
        return tr.nav.titleCollections;
      case 3:
        return tr.nav.titleMy;
      default:
        return tr.nav.titleHome;
    }
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
        title: Text(
          _appBarTitle(context),
          style: styles.h3.copyWith(fontSize: 19),
        ),
        actions: [
          _TrophyButton(palette: palette),
          if (_currentIndex == 3) ...[
            const SizedBox(width: 2),
            _SettingsButton(palette: palette),
          ],
          const SizedBox(width: 8),
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          HomeTabView(
            onSwitchToDaily: () {
              SoundService.I.play(Sfx.tap);
              AppLogger.debug(
                AppLogger.ui,
                'Main goto tab 1 daily from $_currentIndex',
              );
              setState(() => _currentIndex = 1);
            },
          ),
          const DailyTabView(),
          const CollectionsTabView(),
          MyCenterTabView(
            isActive: _currentIndex == 3,
            onGoExplore: () {
              SoundService.I.play(Sfx.tap);
              AppLogger.debug(
                AppLogger.ui,
                'Main goto tab 0 home from $_currentIndex',
              );
              setState(() => _currentIndex = 0);
            },
          ),
        ],
      ),
      bottomNavigationBar: _GameBottomNav(
        currentIndex: _currentIndex,
        onTap: (idx) {
          if (idx != _currentIndex) {
            SoundService.I.play(Sfx.tap);
            AppLogger.debug(
              AppLogger.ui,
              'Main tab switch $_currentIndex -> $idx',
            );
          }
          setState(() => _currentIndex = idx);
        },
        palette: palette,
      ),
    );
  }
}

// ── Coin Badge ─────────────────────────────
// class _CoinBadge extends StatelessWidget {
//   const _CoinBadge({required this.palette});
//   final AppPalette palette;

//   @override
//   Widget build(BuildContext context) {
//     return Container(
//       margin: const EdgeInsets.symmetric(vertical: 10),
//       padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
//       decoration: BoxDecoration(
//         color: palette.surfaceContainer,
//         borderRadius: BorderRadius.circular(20),
//         border: Border.all(color: palette.divider, width: 1),
//       ),
//       child: Row(
//         mainAxisSize: MainAxisSize.min,
//         children: [
//           const Text('🪙', style: TextStyle(fontSize: 14)),
//           const SizedBox(width: 4),
//           Text(
//             '1,280',
//             style: TextStyle(
//               fontSize: 12,
//               fontWeight: FontWeight.w700,
//               color: palette.gold,
//               fontFeatures: const [FontFeature.tabularFigures()],
//             ),
//           ),
//         ],
//       ),
//     );
//   }
// }

// ── Trophy Button ──────────────────────────
class _TrophyButton extends StatelessWidget {
  const _TrophyButton({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final tr = LocaleSettings.instance.currentTranslations;
    return IconButton(
      key: const Key('main_trophy_button'),
      icon: Icon(PhosphorIconsBold.trophy, color: palette.brand, size: 22),
      tooltip: tr.nav.tooltipAchievements,
      onPressed: () async {
        await AchievementsPage.open(context);
      },
    );
  }
}

// ── Settings Button ────────────────────────
class _SettingsButton extends StatelessWidget {
  const _SettingsButton({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final tr = LocaleSettings.instance.currentTranslations;
    return IconButton(
      key: const Key('main_settings_button'),
      icon: Icon(PhosphorIconsBold.gear, color: palette.brand, size: 22),
      tooltip: tr.nav.tooltipSettings,
      onPressed: () async {
        await SettingsPage.open(context);
      },
    );
  }
}

// ── Game-styled Bottom Nav ─────────────────
class _GameBottomNav extends StatelessWidget {
  const _GameBottomNav({
    required this.currentIndex,
    required this.onTap,
    required this.palette,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final tr = LocaleSettings.instance.currentTranslations;
    final items = [
      _NavItemData(icon: PhosphorIconsFill.house, label: tr.nav.home),
      _NavItemData(icon: PhosphorIconsFill.calendarCheck, label: tr.nav.daily),
      _NavItemData(
        icon: PhosphorIconsFill.squaresFour,
        label: tr.nav.collections,
      ),
      _NavItemData(icon: PhosphorIconsFill.user, label: tr.nav.my),
    ];

    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(top: BorderSide(color: palette.divider, width: 0.8)),
      ),
      child: SafeArea(
        child: SizedBox(
          height: 64,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: List.generate(items.length, (i) {
              final item = items[i];
              final isActive = i == currentIndex;
              return Expanded(
                child: InkWell(
                  key: Key('main_tab_$i'),
                  onTap: () => onTap(i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 6,
                      horizontal: 2,
                    ),
                    decoration: isActive
                        ? BoxDecoration(
                            color: palette.brand.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(14),
                          )
                        : null,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AnimatedScale(
                          scale: isActive ? 1.08 : 1.0,
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOutBack,
                          child: Icon(
                            item.icon,
                            size: 22,
                            color: isActive
                                ? palette.brand
                                : palette.secondaryText,
                          ),
                        ),
                        const SizedBox(height: 3),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            item.label,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: isActive
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: isActive
                                  ? palette.brand
                                  : palette.disabledText,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _NavItemData {
  const _NavItemData({required this.icon, required this.label});
  final IconData icon;
  final String label;
}
