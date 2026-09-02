import '../logic/image_source.dart';

/// Pre-populated 30-day daily puzzle challenge dataset featuring Bing & Unsplash landscape/nature photography.
class BingDailyItem {
  const BingDailyItem({
    required this.dayNumber,
    required this.dateStr,
    required this.title,
    required this.author,
    required this.location,
    required this.imageUrl,
    required this.fallbackAsset,
    required this.defaultRows,
    required this.defaultCols,
  });

  final int dayNumber;
  final String dateStr;
  final String title;
  final String author;
  final String location;
  final String imageUrl;
  final String fallbackAsset;
  final int defaultRows;
  final int defaultCols;

  int get pieceCount => defaultRows * defaultCols;
}

/// 动态生成当前月及前 2 个月的每日挑战数据集 (按日期倒序排列)
/// 确保无论何时打开 app，当前月份的每日挑战均可用
List<BingDailyItem> get kBingDailyAll {
  final now = DateTime.now();
  final all = <BingDailyItem>[];
  for (var offset = 0; offset <= 2; offset++) {
    final date = DateTime(now.year, now.month - offset, 1);
    all.addAll(_generateMonthDaily(date.year, date.month));
  }
  return all;
}

List<BingDailyItem> _generateMonthDaily(int year, int month) {
  final daysInMonth = DateTime(year, month + 1, 0).day;
  return List.generate(daysInMonth, (index) {
    final day = daysInMonth - index;
    final asset = assetSamples[(day + month * 3 - 1) % assetSamples.length];
    final dateStr =
        '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';

    final titles = [
      '高山翡翠湖泊与针叶林',
      '浓缩拉花咖啡与肉桂香料',
      '阳光花丛中的蓬松小狗',
      '中世纪古堡与阿尔卑斯山麓',
      '新鲜树莓蓝莓松饼塔',
      '初夏晨光微曦的花园',
      '蔚蓝海岸线与白色灯塔',
      '热带雨林中的彩羽金刚鹦鹉',
      '壮丽极光下的北欧木屋',
      '古老书店与暖黄灯影',
    ];

    final title = titles[(day - 1) % titles.length];

    int rows, cols;
    if (day % 3 == 0) {
      rows = 8;
      cols = 8; // 64
    } else if (day % 2 == 0) {
      rows = 6;
      cols = 6; // 36
    } else {
      rows = 4;
      cols = 4; // 16
    }

    return BingDailyItem(
      dayNumber: day,
      dateStr: dateStr,
      title: '$day 日 · $title',
      author: 'Bing Featured',
      location: 'Global Nature',
      imageUrl:
          'https://images.unsplash.com/photo-1506744038136-46273834b3fb?w=1200&q=80',
      fallbackAsset: asset,
      defaultRows: rows,
      defaultCols: cols,
    );
  });
}
