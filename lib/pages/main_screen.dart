import 'package:flutter/material.dart';

import '../widgets/achievements_dialog.dart';
import '../widgets/settings_dialog.dart';
import 'tabs/daily_tab_view.dart';
import 'tabs/home_tab_view.dart';
import 'tabs/my_puzzles_tab_view.dart';

/// Main screen featuring the 3-tab bottom navigation (Home / My / Daily).
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
        return '我的自制';
      case 2:
        return '每日拼图';
      default:
        return '拼图游戏';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        title: Text(
          _appBarTitle,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
        ),
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 0.5,
        actions: [
          IconButton(
            icon: const Icon(Icons.emoji_events_outlined, color: Color(0xFF2E7D32)),
            tooltip: '成就与统计',
            onPressed: () => AchievementsDialog.show(context),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Colors.black87),
            tooltip: '设置',
            onPressed: () => SettingsDialog.show(context),
          ),
          const SizedBox(width: 4),
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
          border: Border(top: BorderSide(color: Color(0xFFE0E0E0), width: 0.5)),
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (idx) => setState(() => _currentIndex = idx),
          backgroundColor: Colors.white,
          indicatorColor: const Color(0xFFE8F5E9),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home, color: Color(0xFF2E7D32)),
              label: '主页',
            ),
            NavigationDestination(
              icon: Icon(Icons.collections_outlined),
              selectedIcon: Icon(Icons.collections, color: Color(0xFF2E7D32)),
              label: '我的',
            ),
            NavigationDestination(
              icon: Icon(Icons.calendar_month_outlined),
              selectedIcon: Icon(Icons.calendar_month, color: Color(0xFF2E7D32)),
              label: '每日拼图',
            ),
          ],
        ),
      ),
    );
  }
}
