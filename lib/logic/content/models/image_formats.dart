/// P1-5：图片扩展名白名单单一来源。
///
/// 四条管线（events / collections / daily / pack）的“已下载判定 + zip 解压
/// 过滤”共用同一白名单，避免再次漂移。注意该正则同时决定“解压哪些文件”，
/// 放宽白名单会同步改变解压行为，回归时需一并验证（空包由 P1-7 兜住）。
///
/// 扩展名选择：Flutter 引擎可解 webp/jpg/jpeg/png/gif/bmp；jfif 实为 JPEG
/// 变体（仅扩展名差异）；avif 与在线搜图页的拦截口径保持一致
///（`online_image_picker_page` 已接受 avif）。
const List<String> kImageExtensions = <String>[
  'webp',
  'jpg',
  'jpeg',
  'png',
  'gif',
  'bmp',
  'jfif',
  'avif',
];

/// 通用图片文件匹配（events / collections / pack 共用，不区分大小写）。
final RegExp kImageFileRegex = RegExp(
  r'\.(webp|jpg|jpeg|png|gif|bmp|jfif|avif)$',
  caseSensitive: false,
);

/// 每日挑战文件名匹配 `yyyyMMdd.<ext>`（daily 专用，不区分大小写）。
final RegExp kDailyFileRegex = RegExp(
  r'^(\d{4})(\d{2})(\d{2})\.(webp|jpg|jpeg|png|gif|bmp|jfif|avif)$',
  caseSensitive: false,
);

/// 用户可见的格式说明文案（图包导入报错等场景共用）。
const String kImageFormatsLabel = 'webp / jpg / png / gif / bmp / avif';
