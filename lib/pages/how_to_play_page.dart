import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// Full-screen Gameplay Guide & Tips Page.
class HowToPlayPage extends StatelessWidget {
  const HowToPlayPage({super.key});

  /// Navigates to [HowToPlayPage] as a standard full-screen route.
  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const HowToPlayPage(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tips = [
      _TipItemData(
        icon: PhosphorIconsBold.handTap,
        color: const Color(0xFF2E7D32),
        title: '拖拽与磁吸',
        desc: '单指拖拽碎片到棋盘正确位置附近，会自动发出清脆吸附声并精准归位锁定。',
      ),
      _TipItemData(
        icon: PhosphorIconsBold.stack,
        color: const Color(0xFF0288D1),
        title: '碎片组队合并 (Cluster)',
        desc: '相连的碎片即使尚未放在棋盘正确格子，也可以在托盘或画布任意处互相拼合，合并后可整体拖动调整。',
      ),
      _TipItemData(
        icon: PhosphorIconsBold.magnifyingGlassPlus,
        color: const Color(0xFFE65100),
        title: '双指缩放与平移',
        desc: '双指捏合可无级放大/缩小棋盘，双指滑动或鼠标中键拖拽可平移画布，助你轻松对齐细节局部。',
      ),
      _TipItemData(
        icon: PhosphorIconsFill.stack,
        color: const Color(0xFF7B1FA2),
        title: '底图透视参考 (Ghost)',
        desc: '点击顶部透视图标可在棋盘开启 20%/45% 半透明底图，辅助观察画面线条与色彩快速定位。',
      ),
      _TipItemData(
        icon: PhosphorIconsBold.cornersOut,
        color: const Color(0xFF00897B),
        title: '边缘碎片筛选',
        desc: '点击边框筛选图标，可高亮所有外围平边碎片并暗淡内部碎片，助你先拼好外层框架。',
      ),
      _TipItemData(
        icon: PhosphorIconsBold.broom,
        color: const Color(0xFF5D4037),
        title: '一键整理托盘',
        desc: '散落在棋盘画布上的单块碎片，点击扫把图标即可瞬间整齐归纳至下方托盘，恢复整洁视野。',
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(PhosphorIconsBold.question, color: Color(0xFF2E7D32), size: 22),
            SizedBox(width: 8),
            Text('玩法与操作技巧', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 19)),
          ],
        ),
        centerTitle: false,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            children: [
              // Welcome Banner
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFE8F5E9), Color(0xFFE1F5FE)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFC8E6C9)),
                ),
                child: Row(
                  children: [
                    Image.asset('assets/icons/sparkle_3d.png', width: 32, height: 32),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '轻松上手异形拼图',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF1B5E20)),
                          ),
                          SizedBox(height: 2),
                          Text(
                            '熟悉以下核心操作手势与辅助工具，能让你在挑战高难度拼图时事半功倍！',
                            style: TextStyle(fontSize: 12.5, color: Colors.black87, height: 1.3),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 18),

              // Tips list
              for (final tip in tips) ...[
                _buildTipCard(tip),
                const SizedBox(height: 12),
              ],

              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTipCard(_TipItemData tip) {
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Colors.black12, width: 0.8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: tip.color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(tip.icon, color: tip.color, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tip.title,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tip.desc,
                    style: const TextStyle(fontSize: 13, color: Colors.black87, height: 1.4),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TipItemData {
  const _TipItemData({
    required this.icon,
    required this.color,
    required this.title,
    required this.desc,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String desc;
}
