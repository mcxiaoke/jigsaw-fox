import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import 'achievements_page.dart';
import 'settings_page.dart';
import 'tabs/daily_tab_view.dart';
import 'tabs/events_tab_view.dart';
import 'tabs/home_tab_view.dart';
import 'tabs/my_puzzles_tab_view.dart';

/// Main screen featuring the 4-tab bottom navigation (Home / Daily / Events / My) with streamlined header.
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
        return '主页';
      case 1:
        return '每日';
      case 2:
        return '活动';
      case 3:
        return '自制';
      default:
        return '主页';
    }
  }

  @override
  Widget build(BuildContext context) {
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
          // Achievements Page
          IconButton(
            icon: Image.asset('assets/icons/trophy_3d.png', width: 22, height: 22),
            tooltip: '成就与统计',
            onPressed: () async {
              await AchievementsPage.open(context);
              setState(() {});
            },
          ),

          // Settings Page
          IconButton(
            icon: Image.asset('assets/icons/setting.png', width: 22, height: 22),
            tooltip: '设置',
            onPressed: () async {
              await SettingsPage.open(context);
              setState(() {});
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          HomeTabView(
            onSwitchToDaily: () => setState(() => _currentIndex = 1),
          ),
          const DailyTabView(),
          const EventsTabView(),
          const MyPuzzlesTabView(),
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
              icon: Icon(PhosphorIconsRegular.calendarCheck),
              selectedIcon: Icon(PhosphorIconsFill.calendarCheck, color: Color(0xFF2E7D32)),
              label: '每日',
            ),
            NavigationDestination(
              icon: Icon(PhosphorIconsRegular.sparkle),
              selectedIcon: Icon(PhosphorIconsFill.sparkle, color: Color(0xFF2E7D32)),
              label: '活动',
            ),
            NavigationDestination(
              icon: Icon(PhosphorIconsRegular.images),
              selectedIcon: Icon(PhosphorIconsFill.images, color: Color(0xFF2E7D32)),
              label: '自制',
            ),
          ],
        ),
      ),
    );
  }
}
