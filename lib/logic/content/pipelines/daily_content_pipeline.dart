import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import '../models/canonical_id.dart';
import '../models/puzzle_level_item.dart';
import '../network/content_http_client.dart';
import '../../../services/app_logger.dart';

/// 每日挑战关卡管线 (按月 Zip 下载解压 + 零元数据日期推导 + 客户端时间锁)
class DailyContentPipeline {
  DailyContentPipeline({
    required this.dailyStorageBaseDir,
    ContentHttpClient? httpClient,
  }) : _httpClient = httpClient ?? ContentHttpClient();

  final String dailyStorageBaseDir;
  final ContentHttpClient _httpClient;

  static final RegExp _dailyFileRegex = RegExp(r'^(\d{4})(\d{2})(\d{2})\.(webp|jpg|jpeg|png)$', caseSensitive: false);

  /// 确保某月份的每日关卡已就绪 (若本地不存在则尝试从远端 Zip 下载解压)
  Future<bool> ensureMonthReady({
    required String yyyyMm,
    required String zipUrlPattern,
    DateTime? overrideToday,
  }) async {
    final monthDir = Directory(p.join(dailyStorageBaseDir, yyyyMm));
    if (monthDir.existsSync() && monthDir.listSync().isNotEmpty) {
      AppLogger.daily.fine('ensureMonthReady $yyyyMm already ready files=${monthDir.listSync().length}');
      return true;
    }

    if (zipUrlPattern.isEmpty) {
      AppLogger.daily.warning('ensureMonthReady empty zipUrlPattern for $yyyyMm');
      return false;
    }
    final zipUrl = zipUrlPattern.replaceAll('{YYYYMM}', yyyyMm);
    AppLogger.daily.info('ensureMonthReady $yyyyMm url=${AppLogger.sanitizeUrl(zipUrl)}');

    final tempZipPath = p.join(dailyStorageBaseDir, 'temp_${yyyyMm}_${DateTime.now().millisecondsSinceEpoch}.zip');
    final tempExtractDir = Directory(p.join(dailyStorageBaseDir, 'temp_extract_$yyyyMm'));

    try {
      // 1. 下载月度 Zip
      AppLogger.daily.info('Downloading daily zip $yyyyMm');
      final zipFile = await _httpClient.downloadFile(zipUrl, tempZipPath);
      final bytes = await zipFile.readAsBytes();
      AppLogger.daily.info('Downloaded daily zip $yyyyMm bytes=${bytes.length}');

      // 2. 解压到临时目录
      final archive = ZipDecoder().decodeBytes(bytes);
      if (tempExtractDir.existsSync()) {
        tempExtractDir.deleteSync(recursive: true);
      }
      tempExtractDir.createSync(recursive: true);

      var extracted = 0;
      for (final file in archive) {
        final filename = p.basename(file.name);
        // 过滤掉 MacOS 隐藏文件和目录项
        if (file.isFile && _dailyFileRegex.hasMatch(filename)) {
          final outFile = File(p.join(tempExtractDir.path, filename));
          await outFile.writeAsBytes(file.content as List<int>, flush: true);
          extracted++;
        }
      }
      AppLogger.daily.info('Extracted $extracted files for $yyyyMm to ${AppLogger.sanitizePath(tempExtractDir.path)}');

      // 3. 移动/重命名到正式目录
      if (monthDir.existsSync()) {
        monthDir.deleteSync(recursive: true);
      }
      await tempExtractDir.rename(monthDir.path);

      // 4. 清理临时 Zip
      if (zipFile.existsSync()) {
        zipFile.deleteSync();
      }
      AppLogger.daily.info('ensureMonthReady success $yyyyMm extracted=$extracted');
      return true;
    } catch (e, st) {
      AppLogger.daily.severe('ensureMonthReady failed $yyyyMm url=${AppLogger.sanitizeUrl(zipUrl)}', e, st);
      // 异常清理残留
      if (tempExtractDir.existsSync()) {
        try {
          tempExtractDir.deleteSync(recursive: true);
        } catch (_) {}
      }
      final zf = File(tempZipPath);
      if (zf.existsSync()) {
        try {
          zf.deleteSync();
        } catch (_) {}
      }
      return false;
    }
  }

  static bool isValidDate(int year, int month, int day) {
    if (year < 2000 || year > 2100) return false;
    if (month < 1 || month > 12) return false;
    final maxDays = DateTime(year, month + 1, 0).day;
    return day >= 1 && day <= maxDays;
  }

  /// 获取指定月份的所有每日挑战关卡 (带时间锁计算、自然月份天数防溢出与升序排列)
  List<PuzzleLevelItem> getLevelsForMonth(
    String yyyyMm, {
    DateTime? overrideToday,
  }) {
    final monthDir = Directory(p.join(dailyStorageBaseDir, yyyyMm));
    if (!monthDir.existsSync()) return const [];

    final now = overrideToday ?? DateTime.now();
    final todayStr = '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';

    final items = <PuzzleLevelItem>[];
    final files = monthDir.listSync().whereType<File>();

    for (final file in files) {
      final filename = p.basename(file.path);
      final match = _dailyFileRegex.firstMatch(filename);
      if (match != null) {
        final year = int.tryParse(match.group(1)!) ?? 0;
        final month = int.tryParse(match.group(2)!) ?? 0;
        final day = int.tryParse(match.group(3)!) ?? 0;

        // 1. 容错拦截：如果文件日期超出该月自然天数 (如 2月30号、4月31号)，坚决丢弃
        if (!isValidDate(year, month, day)) {
          continue;
        }

        final dateStr = '${match.group(1)}${match.group(2)}${match.group(3)}';
        final canonicalId = CanonicalId.forDaily(dateStr);
        final isLocked = dateStr.compareTo(todayStr) > 0;

        items.add(
          PuzzleLevelItem(
            id: canonicalId,
            imagePathOrUrl: file.path,
            isLocalFile: true,
            sourceModule: CanonicalId.prefixDaily,
            dailyDate: dateStr,
            isTimeLocked: isLocked,
            order: int.tryParse(dateStr) ?? 0,
          ),
        );
      }
    }

    // 按日期升序排列 (只保留实际存在且合法的图片)
    items.sort((a, b) => (a.dailyDate ?? '').compareTo(b.dailyDate ?? ''));
    return items;
  }

  /// 获取今日的每日挑战关卡 (若已就绪)
  PuzzleLevelItem? getTodayLevel({DateTime? overrideToday}) {
    final now = overrideToday ?? DateTime.now();
    final yyyyMm = '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}';
    final levels = getLevelsForMonth(yyyyMm, overrideToday: now);
    final todayStr = '$yyyyMm${now.day.toString().padLeft(2, '0')}';
    try {
      return levels.firstWhere((l) => l.dailyDate == todayStr);
    } catch (_) {
      return null;
    }
  }
}
