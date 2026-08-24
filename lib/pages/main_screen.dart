import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../data/game_repository.dart';
import '../widgets/achievements_dialog.dart';
import '../widgets/how_to_play_dialog.dart';
import '../widgets/settings_dialog.dart';
import 'tabs/daily_tab_view.dart';
import 'tabs/home_tab_view.dart';
import 'tabs/my_puzzles_tab_view.dart';

/// Main screen featuring the 3-tab bottom navigation (Home / My / Daily) with header stats.
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final _repo = GameRepository.instance;
  int _currentIndex = 0;

  String get _appBarTitle {
    switch (_currentIndex) {
      case 0:
        return '关卡画廊';
      case 1:
        return '我的自制';
      case 2:
        return '每日拼图';
      default:
        return '异形拼图';
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalStars = _repo.levels.fold<int>(0, (sum, l) => sum + l.stars);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/icons/puzzle_piece_3d.png', width: 24, height: 24),
            const SizedBox(width: 8),
            Text(
              _appBarTitle,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 19),
            ),
          ],
        ),
        centerTitle: false,
        backgroundColor: Colors.white,
        elevation: 0.5,
        actions: [
          // Total Stars Counter
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.amber.shade300),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset('assets/icons/star_3d.png', width: 18, height: 18),
                const SizedBox(width: 4),
                Text(
                  '$totalStars',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: Colors.orange,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),

          // Help / How to Play
          IconButton(
            icon: const Icon(PhosphorIconsBold.question, color: Color(0xFF0288D1)),
            tooltip: '玩法指引',
            onPressed: () => HowToPlayDialog.show(context),
          ),

          // Achievements
          IconButton(
            icon: Image.asset('assets/icons/trophy_3d.png', width: 22, height: 22),
            tooltip: '成就与统计',
            onPressed: () async {
              await AchievementsDialog.show(context);
              setState(() {});
            },
          ),

          // Settings
          IconButton(
            icon: Image.asset('assets/icons/control_knobs_3d.png', width: 22, height: 22),
            tooltip: '设置',
            onPressed: () async {
              await SettingsDialog.show(context);
              setState(() {});
            },
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          HomeTabView(
            onSwitchToDaily: () => setState(() => _currentIndex = 2),
          ),
          const MyPuzzlesTabView(),
          const DailyTabView(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE5E7EB), width: 0.8)),
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (idx) => setState(() => _currentIndex = idx),
          backgroundColor: Colors.white,
          indicatorColor: const Color(0xFFE8F5E9),
          destinations: const [
            NavigationDestination(
              icon: Icon(PhosphorIconsRegular.house),
              selectedIcon: Icon(PhosphorIconsFill.house, color: Color(0xFF2E7D32)),
              label: '主页',
            ),
            NavigationDestination(
              icon: Icon(PhosphorIconsRegular.images),
              selectedIcon: Icon(PhosphorIconsFill.images, color: Color(0xFF2E7D32)),
              label: '我的自制',
            ),
            NavigationDestination(
              icon: Icon(PhosphorIconsRegular.calendarCheck),
              selectedIcon: Icon(PhosphorIconsFill.calendarCheck, color: Color(0xFF2E7D32)),
              label: '每日拼图',
            ),
          ],
        ),
      ),
    );
  }
}
