import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../services/sound_service.dart';
import '../theme/app_palette.dart';
import '../theme/app_text_styles.dart';
import 'achievements_page.dart';
import 'how_to_play_page.dart';
import 'import_pack_page.dart';
import 'settings_page.dart';
import 'tabs/daily_tab_view.dart';
import 'tabs/events_tab_view.dart';
import 'tabs/home_tab_view.dart';
import 'tabs/my_puzzles_tab_view.dart';

/// Main screen featuring the 4-tab bottom navigation (Home / Daily / Events / My)
/// with game-styled bottom nav: filled icons + amber gold active state glow.
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  String get _appBarTitle {
    switch (_currentIndex) {
      case 0:
        return '异形拼图';
      case 1:
        return '每日挑战';
      case 2:
        return '活动专题';
      case 3:
        return '我的拼图';
      default:
        return '异形拼图';
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
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                gradient: AppPalette.brandGradient,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(
                child: Text('\u{1F98A}', style: TextStyle(fontSize: 16)),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _appBarTitle,
              style: styles.h3.copyWith(fontSize: 19),
            ),
          ],
        ),
        actions: [
          _CoinBadge(palette: palette),
          const SizedBox(width: 2),
          _TrophyButton(palette: palette),
          const SizedBox(width: 2),
          _SettingsButton(palette: palette),
          const SizedBox(width: 2),
          _MoreMenu(palette: palette),
          const SizedBox(width: 8),
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          HomeTabView(
            onSwitchToDaily: () {
              SoundService.I.play(Sfx.tap);
              setState(() => _currentIndex = 1);
            },
          ),
          const DailyTabView(),
          const EventsTabView(),
          const MyPuzzlesTabView(),
        ],
      ),
      bottomNavigationBar: _GameBottomNav(
        currentIndex: _currentIndex,
        onTap: (idx) {
          if (idx != _currentIndex) {
            SoundService.I.play(Sfx.tap);
          }
          setState(() => _currentIndex = idx);
        },
        palette: palette,
      ),
    );
  }
}

// ── Coin Badge ─────────────────────────────
class _CoinBadge extends StatelessWidget {
  const _CoinBadge({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: palette.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: palette.divider, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🪙', style: TextStyle(fontSize: 14)),
          const SizedBox(width: 4),
          Text(
            '1,280',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: palette.gold,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Trophy Button ──────────────────────────
class _TrophyButton extends StatelessWidget {
  const _TrophyButton({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(PhosphorIconsBold.trophy, color: palette.brand, size: 22),
      tooltip: '成就与统计',
      onPressed: () async {
        await AchievementsPage.open(context);
      },
    );
  }
}

// ── Settings Button (outline, no bg) ──────────
class _SettingsButton extends StatelessWidget {
  const _SettingsButton({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(PhosphorIconsBold.gear, color: palette.secondaryText, size: 22),
      tooltip: '设置',
      onPressed: () async {
        await SettingsPage.open(context);
      },
    );
  }
}

// ── More Menu (Import / Settings / Help) ───
class _MoreMenu extends StatelessWidget {
  const _MoreMenu({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: Icon(PhosphorIconsBold.dotsThree,
          color: palette.secondaryText, size: 24),
      tooltip: '更多选项',
      elevation: 8,
      shadowColor: palette.surfaceContainer,
      color: palette.surfaceContainer,
      offset: const Offset(0, 48),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: palette.divider, width: 1.2),
      ),
      menuPadding: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      onSelected: (val) async {
        if (val == 'import') {
          final pack = await ImportPackPage.push(context);
          if (pack != null && context.mounted) {
            SoundService.I.play(Sfx.tap);
          }
        } else if (val == 'help') {
          await HowToPlayPage.open(context);
        }
      },
      itemBuilder: (ctx) => [
        _menuItem(
          value: 'import',
          icon: PhosphorIconsBold.downloadSimple,
          iconBg: palette.success.withValues(alpha: 0.12),
          iconColor: palette.success,
          title: '导入关卡包',
          subtitle: '从本地 ZIP 或网络导入',
        ),
        PopupMenuDivider(height: 1, color: palette.divider),
        _menuItem(
          value: 'help',
          icon: PhosphorIconsBold.bookOpenText,
          iconBg: palette.info.withValues(alpha: 0.12),
          iconColor: palette.info,
          title: '玩法手册',
          subtitle: '拼图规则与技巧指引',
        ),
      ],
    );
  }

  PopupMenuItem<String> _menuItem({
    required String value,
    required IconData icon,
    required Color iconBg,
    required Color iconColor,
    required String title,
    required String subtitle,
  }) {
    return PopupMenuItem(
      value: value,
      height: 56,
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 17),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.bold,
                    color: palette.primaryText,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: palette.secondaryText,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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
    final items = [
      _NavItemData(icon: PhosphorIconsFill.house, label: '主页'),
      _NavItemData(icon: PhosphorIconsFill.calendarCheck, label: '每日'),
      _NavItemData(icon: PhosphorIconsFill.sparkle, label: '活动'),
      _NavItemData(icon: PhosphorIconsFill.images, label: '自制'),
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
                  onTap: () => onTap(i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
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
                          scale: isActive ? 1.1 : 1.0,
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOutBack,
                          child: Icon(
                            item.icon,
                            size: 24,
                            color: isActive ? palette.brand : palette.secondaryText,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.label,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                            color: isActive ? palette.brand : palette.disabledText,
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
