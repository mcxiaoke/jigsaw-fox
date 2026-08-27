import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../data/game_repository.dart';
import '../widgets/choose_background_sheet.dart';
import 'how_to_play_page.dart';

/// Full-screen Game Settings page with grouped settings cards.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  /// Navigates to [SettingsPage] as a standard full-screen route.
  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const SettingsPage(),
      ),
    );
  }

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _repo = GameRepository.instance;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/icons/setting.png', width: 24, height: 24),
            const SizedBox(width: 8),
            const Text('游戏设置', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 19)),
          ],
        ),
        centerTitle: false,
        backgroundColor: Colors.white,
        elevation: 0.5,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            children: [
              // Group 1: Audio & Haptics
              _buildSectionHeader('音效与交互'),
              _buildCardContainer([
                SwitchListTile(
                  title: const Text('拼图吸附音效', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
                  subtitle: const Text('碎片对齐磁吸时播放清脆音效'),
                  secondary: const Icon(PhosphorIconsBold.speakerHigh, color: Color(0xFF2E7D32)),
                  value: _repo.soundEnabled,
                  activeTrackColor: const Color(0xFF81C784),
                  activeThumbColor: const Color(0xFF2E7D32),
                  onChanged: (v) => setState(() => _repo.soundEnabled = v),
                ),
                const Divider(height: 1, indent: 56),
                SwitchListTile(
                  title: const Text('触感震动反馈', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
                  subtitle: const Text('拼图吸附与操作时的触觉微震'),
                  secondary: const Icon(PhosphorIconsBold.vibrate, color: Color(0xFF2E7D32)),
                  value: _repo.hapticEnabled,
                  activeTrackColor: const Color(0xFF81C784),
                  activeThumbColor: const Color(0xFF2E7D32),
                  onChanged: (v) => setState(() => _repo.hapticEnabled = v),
                ),
                const Divider(height: 1, indent: 56),
                SwitchListTile(
                  title: const Text('选关切图网格预览', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
                  subtitle: const Text('在难度选择预览图上叠加异形切线'),
                  secondary: const Icon(PhosphorIconsBold.gridFour, color: Color(0xFF2E7D32)),
                  value: _repo.gridPreviewEnabled,
                  activeTrackColor: const Color(0xFF81C784),
                  activeThumbColor: const Color(0xFF2E7D32),
                  onChanged: (v) => setState(() => _repo.gridPreviewEnabled = v),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(PhosphorIconsBold.squaresFour, color: Color(0xFF2E7D32)),
                  title: const Text('碎片初始排布模式', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
                  subtitle: Text(_repo.pieceScatterMode == 'tabletop'
                      ? '桌面环形散落（推荐宽屏/平板）'
                      : '底部托盘收纳（默认/推荐手机）'),
                  trailing: SegmentedButton<String>(
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(
                      selectedBackgroundColor: const Color(0xFF2E7D32),
                      selectedForegroundColor: Colors.white,
                      visualDensity: VisualDensity.compact,
                    ),
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
              ]),

              const SizedBox(height: 18),

              // Group 2: Appearance & Background
              _buildSectionHeader('外观与背景'),
              _buildCardContainer([
                ListTile(
                  leading: const Icon(PhosphorIconsBold.image, color: Color(0xFF0288D1)),
                  title: const Text('默认壁纸背景', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
                  subtitle: const Text('选择拼图对局时的全屏桌面背景'),
                  trailing: const Icon(PhosphorIconsBold.caretRight, size: 18),
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
              ]),

              const SizedBox(height: 18),

              // Group 3: Help & Guide (Main Entry)
              _buildSectionHeader('玩法与帮助'),
              _buildCardContainer([
                ListTile(
                  leading: const Icon(PhosphorIconsBold.question, color: Color(0xFF2E7D32)),
                  title: const Text('玩法技巧与操作指引', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
                  subtitle: const Text('手势操作、组队拖拽、底图透视、整理工具说明'),
                  trailing: const Icon(PhosphorIconsBold.caretRight, size: 18),
                  onTap: () => HowToPlayPage.open(context),
                ),
              ]),

              const SizedBox(height: 18),

              // Group 4: Data Management
              _buildSectionHeader('数据管理'),
              _buildCardContainer([
                ListTile(
                  leading: const Icon(PhosphorIconsBold.trashSimple, color: Colors.redAccent),
                  title: const Text('重置所有游戏数据', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5, color: Colors.redAccent)),
                  subtitle: const Text('清除所有关卡记录、每日挑战与自制拼图'),
                  trailing: const Icon(PhosphorIconsBold.caretRight, size: 18, color: Colors.redAccent),
                  onTap: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('确认重置全部数据？'),
                        content: const Text('该操作不可逆，将清除所有主线关卡进度、每日挑战与自制拼图记录。'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            style: FilledButton.styleFrom(backgroundColor: Colors.red),
                            child: const Text('确定重置'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) {
                      await _repo.resetAllData();
                      if (context.mounted) {
                        setState(() {});
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('所有游戏数据已重置为初始状态')),
                        );
                      }
                    }
                  },
                ),
              ]),

              const SizedBox(height: 24),

              // App Footer Info
              Center(
                child: Column(
                  children: [
                    Image.asset('assets/icons/puzzle_piece_3d.png', width: 32, height: 32),
                    const SizedBox(height: 6),
                    const Text(
                      '异形拼图 Jigsaw Puzzle',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.black54),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      '版本 1.0.0',
                      style: TextStyle(fontSize: 11.5, color: Colors.black38),
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

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: Colors.black54),
      ),
    );
  }

  Widget _buildCardContainer(List<Widget> children) {
    return Material(
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Colors.black12, width: 0.8),
      ),
      child: Column(
        children: children,
      ),
    );
  }
}
