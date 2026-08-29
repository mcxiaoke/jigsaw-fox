import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../services/sound_service.dart';

import 'achievements_page.dart';
import 'how_to_play_page.dart';
import 'import_pack_page.dart';
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

          // 更多菜单 (精致游戏风格下拉菜单：导入关卡包、系统设置、玩法手册)
          PopupMenuButton<String>(
            icon: Image.asset('assets/icons/setting.png', width: 22, height: 22),
            tooltip: '更多选项',
            elevation: 8,
            shadowColor: Colors.black38,
            color: Colors.white,
            offset: const Offset(0, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: const BorderSide(color: Color(0xFFE5E7EB), width: 1.2),
            ),
            // 去掉默认的 8px 垂直内边距，让首/末行按压高亮触达菜单圆角边界并被裁剪，
            // 避免按下高亮仍是直角（与 clipBehavior: Clip.antiAlias 配合）。
            menuPadding: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            onSelected: (val) async {
              if (val == 'import') {
                final pack = await ImportPackPage.push(context);
                if (pack != null && mounted) {
                  SoundService.I.play(Sfx.tap);
                  setState(() => _currentIndex = 3); // 切换到自制 Tab 查看
                }
              } else if (val == 'settings') {
                await SettingsPage.open(context);
                if (mounted) setState(() {});
              } else if (val == 'help') {
                await HowToPlayPage.open(context);
              }
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'import',
                height: 52,
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE8F5E9),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(PhosphorIconsBold.downloadSimple, color: Color(0xFF2E7D32), size: 17),
                    ),
                    const SizedBox(width: 12),
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '导入关卡包',
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: Color(0xFF1F2937)),
                        ),
                        Text(
                          '从本地 ZIP 或网络导入',
                          style: TextStyle(fontSize: 10.5, color: Color(0xFF6B7280)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const PopupMenuDivider(height: 1),
              PopupMenuItem(
                value: 'settings',
                height: 52,
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(PhosphorIconsBold.gearSix, color: Color(0xFF4B5563), size: 17),
                    ),
                    const SizedBox(width: 12),
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '游戏设置',
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: Color(0xFF1F2937)),
                        ),
                        Text(
                          '音效、排布与触感设置',
                          style: TextStyle(fontSize: 10.5, color: Color(0xFF6B7280)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const PopupMenuDivider(height: 1),
              PopupMenuItem(
                value: 'help',
                height: 52,
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE0F2FE),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(PhosphorIconsBold.bookOpenText, color: Color(0xFF0284C7), size: 17),
                    ),
                    const SizedBox(width: 12),
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '玩法手册',
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: Color(0xFF1F2937)),
                        ),
                        Text(
                          '拼图规则与技巧指引',
                          style: TextStyle(fontSize: 10.5, color: Color(0xFF6B7280)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
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
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE5E7EB), width: 0.8)),
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (idx) {
            if (idx != _currentIndex) {
              SoundService.I.play(Sfx.tap);
            }
            setState(() => _currentIndex = idx);
          },
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
