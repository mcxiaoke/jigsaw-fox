// P1-4：外部内容（manifest/JSON/网络）解析防御：脏数据跳过降级，不中断启动
// ignore_for_file: avoid_catches_without_on_clauses
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:jigsawpuzzle/logic/content/models/canonical_id.dart';
import 'package:jigsawpuzzle/logic/content/models/image_formats.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_level_item.dart';
import 'package:jigsawpuzzle/logic/content/network/content_http_client.dart';
import 'package:jigsawpuzzle/logic/content/pipelines/atomic_replace.dart';
import 'package:jigsawpuzzle/logic/content/staging/temp_storage_manager.dart';
import 'package:jigsawpuzzle/logic/single_flight.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:path/path.dart' as p;

/// 每日挑战关卡管线 (按月 Zip 下载解压 + 零元数据日期推导 + 客户端时间锁)
class DailyContentPipeline {
  DailyContentPipeline({
    required this.dailyStorageBaseDir,
    TempStorageManager? tempStorageManager,
    ContentHttpClient? httpClient,
  }) : _tempStorage = tempStorageManager,
       _httpClient = httpClient ?? ContentHttpClient();

  final String dailyStorageBaseDir;
  final TempStorageManager? _tempStorage;
  final ContentHttpClient _httpClient;

  /// 进行中的下载单飞表 (同月并发 ensure 复用同一 Future，防互删临时目录)
  final Map<String, Future<bool>> _inFlightDownloads = {};

  // P1-5：图片白名单收敛为共享常量（大小写不敏感已是现状，勿重复改）。
  static final RegExp _dailyFileRegex = kDailyFileRegex;

  /// 确保某月份的每日关卡已就绪 (若本地不存在则尝试从远端 Zip 下载解压)。
  ///
  /// 单飞（P1-7）：同月份进行中的调用复用同一 Future，避免并发下载互删
  /// temp_extract 临时目录。
  Future<bool> ensureMonthReady({
    required String yyyyMm,
    String zipUrlPattern = '',
    String? explicitZipUrl,
    List<String> mirrorUrls = const [],
    DateTime? overrideToday,
  }) {
    return runSingleFlight(
      _inFlightDownloads,
      yyyyMm,
      () => _ensureMonthReadyImpl(
        yyyyMm: yyyyMm,
        zipUrlPattern: zipUrlPattern,
        explicitZipUrl: explicitZipUrl,
        mirrorUrls: mirrorUrls,
        overrideToday: overrideToday,
      ),
    );
  }

  Future<bool> _ensureMonthReadyImpl({
    required String yyyyMm,
    String zipUrlPattern = '',
    String? explicitZipUrl,
    List<String> mirrorUrls = const [],
    DateTime? overrideToday,
  }) async {
    final monthDir = Directory(p.join(dailyStorageBaseDir, yyyyMm));
    if (monthDir.existsSync() && monthDir.listSync().isNotEmpty) {
      AppLogger.daily.info(
        'ensureMonthReady $yyyyMm already ready files=${monthDir.listSync().length}',
      );
      return true;
    }

    final String zipUrl;
    if (explicitZipUrl != null && explicitZipUrl.isNotEmpty) {
      zipUrl = explicitZipUrl;
    } else if (zipUrlPattern.isNotEmpty) {
      zipUrl = zipUrlPattern.replaceAll('{YYYYMM}', yyyyMm);
    } else {
      AppLogger.daily.warning(
        'ensureMonthReady empty zipUrl/zipUrlPattern for $yyyyMm',
      );
      return false;
    }
    AppLogger.daily.info(
      'ensureMonthReady $yyyyMm url=${AppLogger.sanitizeUrl(zipUrl)}',
    );

    final tempZipPath = _tempStorage != null
        ? _tempStorage.createTempDownloadPath('daily', yyyyMm)
        : p.join(
            dailyStorageBaseDir,
            'temp_${yyyyMm}_${DateTime.now().millisecondsSinceEpoch}.zip',
          );
    final tempExtractDir = _tempStorage != null
        ? _tempStorage.createTempExtractDir('daily', yyyyMm)
        : Directory(
            p.join(dailyStorageBaseDir, 'temp_extract_$yyyyMm'),
          );

    try {
      // 1. 下载月度 Zip (D10：explicit zip + mirrorUrls 备用镜像按序轮询)
      AppLogger.daily.info(
        'Downloading daily zip $yyyyMm mirrors=${mirrorUrls.length + 1}',
      );
      final zipFile = await _httpClient.downloadFileWithMirrors(
        [zipUrl, ...mirrorUrls.where((u) => u != zipUrl)],
        tempZipPath,
      );
      final bytes = await zipFile.readAsBytes();
      AppLogger.daily.info(
        'Downloaded daily zip $yyyyMm bytes=${bytes.length}',
      );

      // 2. 解压到临时目录（P07 后台 Isolate 避免 ANR）
      final archive = await compute(_decodeZipIsolate, bytes);
      // zip bomb 防护
      if (archive.length > 2000) {
        throw Exception('Zip file count excessive ${archive.length}');
      }
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
      AppLogger.daily.info(
        'Extracted $extracted files for $yyyyMm to ${AppLogger.sanitizePath(tempExtractDir.path)}',
      );

      // 3. 原子落位到正式目录（若配置了 TempStorage 则经由原子提升，否则采用本地双向交换）
      if (_tempStorage != null) {
        await _tempStorage.promoteExtractDir(tempExtractDir, monthDir);
      } else {
        await swapDirectoryAtomically(monthDir, tempExtractDir, logTag: yyyyMm);
      }

      // 4. 清理临时 Zip
      if (zipFile.existsSync()) {
        zipFile.deleteSync();
      }
      AppLogger.daily.info(
        'ensureMonthReady success $yyyyMm extracted=$extracted',
      );
      return true;
    } catch (e, st) {
      AppLogger.daily.severe(
        'ensureMonthReady failed $yyyyMm url=${AppLogger.sanitizeUrl(zipUrl)}',
        e,
        st,
      );
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
    final cleanMm = yyyyMm.replaceAll('-', '');
    final dashMm = cleanMm.length == 6
        ? '${cleanMm.substring(0, 4)}-${cleanMm.substring(4, 6)}'
        : yyyyMm;
    var monthDir = Directory(p.join(dailyStorageBaseDir, yyyyMm));
    if (!monthDir.existsSync()) {
      final altDir = Directory(p.join(dailyStorageBaseDir, cleanMm));
      if (altDir.existsSync()) {
        monthDir = altDir;
      } else {
        final altDir2 = Directory(p.join(dailyStorageBaseDir, dashMm));
        if (altDir2.existsSync()) {
          monthDir = altDir2;
        } else {
          return const [];
        }
      }
    }

    final now = overrideToday ?? DateTime.now();
    final todayStr =
        '${now.year.toString().padLeft(4, '0')}'
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
            localPath: file.path,
            isLocalFile: true,
            sourceModule: CanonicalId.prefixDaily,
            dailyDate: dateStr,
            isTimeLocked: isLocked,
            order: int.tryParse(dateStr) ?? 0,
            addedAt: DateTime(year, month, day),
          ),
        );
      }
    }

    // 按日期升序排列 (只保留实际存在且合法的图片)
    items.sort((a, b) => (a.dailyDate ?? '').compareTo(b.dailyDate ?? ''));
    AppLogger.daily.fine(
      'DailyPipeline: getLevelsForMonth $yyyyMm found ${items.length} levels in ${monthDir.path}',
    );
    return items;
  }

  /// 获取本地所有已就绪且关卡非空的月份列表 (格式为 YYYYMM，按降序排列)
  List<String> getLocalReadyMonths() {
    final baseDir = Directory(dailyStorageBaseDir);
    if (!baseDir.existsSync()) return const [];

    final monthSet = <String>{};
    try {
      final subDirs = baseDir.listSync().whereType<Directory>().toList();
      for (final dir in subDirs) {
        final dirName = p.basename(dir.path);
        if (RegExp(r'^\d{6}$').hasMatch(dirName) ||
            RegExp(r'^\d{4}-\d{2}$').hasMatch(dirName)) {
          final normalized = dirName.replaceAll('-', '');
          if (getLevelsForMonth(normalized).isNotEmpty) {
            monthSet.add(normalized);
          }
        }
      }
    } catch (e, st) {
      AppLogger.daily.warning('getLocalReadyMonths failed', e, st);
    }
    return monthSet.toList()..sort((a, b) => b.compareTo(a));
  }

  /// 获取所有本地实际已就绪的历史每日挑战关卡 (按日期升序排序)
  List<PuzzleLevelItem> getAllLocalHistoryLevels({DateTime? overrideToday}) {
    final readyMonths = getLocalReadyMonths();
    if (readyMonths.isEmpty) return const [];

    final result = <PuzzleLevelItem>[];
    for (final month in readyMonths) {
      final levels = getLevelsForMonth(month, overrideToday: overrideToday);
      result.addAll(levels);
    }
    result.sort((a, b) => (a.dailyDate ?? '').compareTo(b.dailyDate ?? ''));
    return result;
  }

  /// 获取当天官方发布的正式每日挑战关卡 (严格模式：本地无则返回 null，不进行离线兜底)
  PuzzleLevelItem? getOfficialTodayLevel({DateTime? overrideToday}) {
    final now = overrideToday ?? DateTime.now();
    final yyyyMm =
        '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}';
    final levels = getLevelsForMonth(yyyyMm, overrideToday: now);
    final todayStr = '$yyyyMm${now.day.toString().padLeft(2, '0')}';
    try {
      return levels.firstWhere((l) => l.dailyDate == todayStr);
    } catch (_) {
      return null;
    }
  }

  /// 获取用于 Banner / 推荐展示的每日挑战关卡。
  ///
  /// 若当天官方正式关卡已就绪，直接返回；
  /// 若当天关卡因离线多天等原因在本地不存在，则从本地所有历史关卡中按当天日期确定性选择一张历史关卡作为今日挑战。
  /// 严禁使用内置 demo 静态样本图（assetSamples）。
  PuzzleLevelItem? getDailyBannerLevel({
    DateTime? overrideToday,
    List<PuzzleLevelItem>? fallbackLocalLevels,
  }) {
    final official = getOfficialTodayLevel(overrideToday: overrideToday);
    if (official != null) return official;

    final now = overrideToday ?? DateTime.now();
    final yyyyMm =
        '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}';
    final todayStr = '$yyyyMm${now.day.toString().padLeft(2, '0')}';
    return _deriveFallbackDailyLevel(
      todayStr: todayStr,
      now: now,
      extraFallbacks: fallbackLocalLevels,
    );
  }

  /// 从本地已下载的历史关卡中按日期确定性选取一张作为当天的每日挑战
  PuzzleLevelItem? _deriveFallbackDailyLevel({
    required String todayStr,
    required DateTime now,
    List<PuzzleLevelItem>? extraFallbacks,
  }) {
    // 1. 优先从历史每日挑战关卡中选取
    final history = getAllLocalHistoryLevels(overrideToday: now);
    final candidates = history.where((l) {
      if (l.localPath == null || !File(l.localPath!).existsSync()) return false;
      return (l.dailyDate ?? '').compareTo(todayStr) <= 0;
    }).toList();

    if (candidates.isNotEmpty) {
      final index = todayStr.hashCode.abs() % candidates.length;
      final picked = candidates[index];
      AppLogger.daily.info(
        'DailyPipeline: Derived offline today daily level from history level ${picked.dailyDate} (${picked.localPath}) for $todayStr',
      );
      return PuzzleLevelItem(
        id: CanonicalId.forDaily(todayStr),
        localPath: picked.localPath,
        isLocalFile: true,
        sourceModule: CanonicalId.prefixDaily,
        dailyDate: todayStr,
        order: int.tryParse(todayStr) ?? 0,
        addedAt: now,
      );
    }

    // 2. 若无历史每日挑战，从传入的本地历史关卡（如已就绪的主线关卡）选取
    if (extraFallbacks != null && extraFallbacks.isNotEmpty) {
      final validExtra = extraFallbacks.where((l) {
        return l.localPath != null && File(l.localPath!).existsSync();
      }).toList();
      if (validExtra.isNotEmpty) {
        final index = todayStr.hashCode.abs() % validExtra.length;
        final picked = validExtra[index];
        AppLogger.daily.info(
          'DailyPipeline: Derived offline today daily level from local extra level ${picked.id} (${picked.localPath}) for $todayStr',
        );
        return PuzzleLevelItem(
          id: CanonicalId.forDaily(todayStr),
          localPath: picked.localPath,
          isLocalFile: true,
          sourceModule: CanonicalId.prefixDaily,
          dailyDate: todayStr,
          order: int.tryParse(todayStr) ?? 0,
          addedAt: now,
        );
      }
    }

    // 严禁使用内置样本 demo 图，无历史数据时返回 null
    AppLogger.daily.warning(
      'DailyPipeline: No local history levels found to derive offline daily for $todayStr',
    );
    return null;
  }

  static Archive _decodeZipIsolate(List<int> bytes) {
    return ZipDecoder().decodeBytes(bytes);
  }
}
