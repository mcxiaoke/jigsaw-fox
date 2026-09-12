/// 解码与缓存档位：所有图片统一从预定义档位中选择，
/// 按单边等比下采样解码，保证原图宽高比不被破坏。
enum ThumbnailDimension {
  /// 卡片 / 网格 / 列表预览图（默认档位，360px）
  card(360),

  /// 活动封面等宽幅横幅大卡（含首页今日挑战大卡，720px）
  eventCover(720);

  const ThumbnailDimension(this.pixels);

  /// 缩略图长边像素数
  final int pixels;
}

/// 默认缩略图档位
const ThumbnailDimension kDefaultThumbnailDimension = ThumbnailDimension.card;
