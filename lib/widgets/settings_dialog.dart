import 'package:flutter/material.dart';

import '../data/game_repository.dart';

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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Row(
        children: [
          Icon(Icons.settings, color: Color(0xFF2E7D32)),
          SizedBox(width: 10),
          Text('游戏设置'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(
            title: const Text('拼图吸附音效'),
            subtitle: const Text('碎片磁吸成功时播放音效'),
            value: _repo.soundEnabled,
            onChanged: (v) => setState(() => _repo.soundEnabled = v),
          ),
          SwitchListTile(
            title: const Text('触感震动反馈'),
            subtitle: const Text('拼图吸附与操作时的触觉微震'),
            value: _repo.hapticEnabled,
            onChanged: (v) => setState(() => _repo.hapticEnabled = v),
          ),
          SwitchListTile(
            title: const Text('切图网格预览'),
            subtitle: const Text('在选关与预览图上叠加异形切线'),
            value: _repo.gridPreviewEnabled,
            onChanged: (v) => setState(() => _repo.gridPreviewEnabled = v),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
            title: const Text('重置所有游戏数据', style: TextStyle(color: Colors.redAccent)),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('确认重置？'),
                  content: const Text('这将清除所有主线关卡进度、每日挑战与自制拼图记录。'),
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
                if (context.mounted) Navigator.pop(context);
              }
            },
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF2E7D32),
          ),
          child: const Text('完成'),
        ),
      ],
    );
  }
}
