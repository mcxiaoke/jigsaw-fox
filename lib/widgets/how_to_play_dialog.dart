import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// Interactive tutorial & tips dialog explaining gameplay mechanics and controls.
class HowToPlayDialog extends StatelessWidget {
  const HowToPlayDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const HowToPlayDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Row(
        children: [
          Icon(PhosphorIconsBold.question, color: Color(0xFF2E7D32)),
          SizedBox(width: 10),
          Text('玩法与操作技巧', style: TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildTipItem(
                icon: PhosphorIconsBold.handTap,
                color: const Color(0xFF2E7D32),
                title: '拖拽与磁吸',
                desc: '单指拖拽碎片到棋盘正确位置附近，会自动发出清脆吸附声并精准归位。',
              ),
              const SizedBox(height: 12),
              _buildTipItem(
                icon: PhosphorIconsBold.stack,
                color: const Color(0xFF0288D1),
                title: '碎片组队合并 (Cluster)',
                desc: '相连的碎片即使未放在正确格子也可以互相拼合，合并后可整体拖动。',
              ),
              const SizedBox(height: 12),
              _buildTipItem(
                icon: PhosphorIconsBold.magnifyingGlassPlus,
                color: const Color(0xFFE65100),
                title: '双指缩放与平移',
                desc: '双指捏合可放大/缩小棋盘，双指滑动或鼠标中键拖拽可平移画布，方便专注局部。',
              ),
              const SizedBox(height: 12),
              _buildTipItem(
                icon: PhosphorIconsFill.stack,
                color: const Color(0xFF7B1FA2),
                title: '底图透视参考 (Ghost)',
                desc: '点击顶部透视图标可在棋盘开启 20%/45% 半透明底图，辅助快速定位。',
              ),
              const SizedBox(height: 12),
              _buildTipItem(
                icon: PhosphorIconsBold.cornersOut,
                color: const Color(0xFF00897B),
                title: '边缘碎片筛选',
                desc: '点击边框筛选图标，可高亮所有外围平边碎片，助你先拼好框架。',
              ),
              const SizedBox(height: 12),
              _buildTipItem(
                icon: PhosphorIconsBold.broom,
                color: const Color(0xFF5D4037),
                title: '一键整理托盘',
                desc: '散落在棋盘上的单块碎片，点击扫把图标即可瞬间整齐归纳至下方托盘。',
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('我知道了'),
        ),
      ],
    );
  }

  Widget _buildTipItem({
    required IconData icon,
    required Color color,
    required String title,
    required String desc,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 2),
              Text(
                desc,
                style: const TextStyle(fontSize: 12.5, color: Colors.black87, height: 1.3),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
