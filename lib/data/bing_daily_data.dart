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

final List<BingDailyItem> kBingDaily30Days = List.generate(31, (index) {
  final day = 31 - index;
  final asset = assetSamples[(day - 1) % assetSamples.length];
  final dateStr = '2026-08-${day.toString().padLeft(2, '0')}';

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
    imageUrl: 'https://images.unsplash.com/photo-1506744038136-46273834b3fb?w=1200&q=80',
    fallbackAsset: asset,
    defaultRows: rows,
    defaultCols: cols,
  );
});
