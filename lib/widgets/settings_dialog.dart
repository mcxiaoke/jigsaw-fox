import 'package:flutter/material.dart';

import '../data/game_repository.dart';
import 'choose_background_sheet.dart';
import 'how_to_play_dialog.dart';

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const SettingsDialog(),
    );
  }

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  final _repo = GameRepository.instance;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: const Row(
        children: [
          Icon(Icons.settings, color: Color(0xFF2E7D32)),
          SizedBox(width: 10),
          Text('游戏设置', style: TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                title: const Text('拼图吸附音效'),
                subtitle: const Text('碎片对齐磁吸时播放清脆音效'),
                value: _repo.soundEnabled,
                activeTrackColor: const Color(0xFF81C784),
                activeThumbColor: const Color(0xFF2E7D32),
                onChanged: (v) => setState(() => _repo.soundEnabled = v),
              ),
              SwitchListTile(
                title: const Text('触感震动反馈'),
                subtitle: const Text('拼图吸附与操作时的触觉微震'),
                value: _repo.hapticEnabled,
                activeTrackColor: const Color(0xFF81C784),
                activeThumbColor: const Color(0xFF2E7D32),
                onChanged: (v) => setState(() => _repo.hapticEnabled = v),
              ),
              SwitchListTile(
                title: const Text('选关切图网格预览'),
                subtitle: const Text('在难度选择预览图上叠加异形切线'),
                value: _repo.gridPreviewEnabled,
                activeTrackColor: const Color(0xFF81C784),
                activeThumbColor: const Color(0xFF2E7D32),
                onChanged: (v) => setState(() => _repo.gridPreviewEnabled = v),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.wallpaper, color: Color(0xFF2E7D32)),
                title: const Text('默认壁纸背景'),
                subtitle: const Text('选择拼图对局时的全屏桌面背景'),
                trailing: const Icon(Icons.chevron_right),
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
              ListTile(
                leading: const Icon(Icons.help_outline, color: Color(0xFF0288D1)),
                title: const Text('玩法技巧与操作指引'),
                subtitle: const Text('手势操作、组队拖拽、底图透视说明'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => HowToPlayDialog.show(context),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.redAccent),
                title: const Text('重置所有游戏数据', style: TextStyle(color: Colors.redAccent)),
                subtitle: const Text('清除所有关卡记录、每日挑战与自制拼图'),
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
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('所有游戏数据已重置为初始状态')),
                      );
                    }
                  }
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF2E7D32),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('完成'),
        ),
      ],
    );
  }
}
