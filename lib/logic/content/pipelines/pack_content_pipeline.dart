import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../../../services/app_logger.dart';
import '../models/canonical_id.dart';
import '../models/puzzle_level_item.dart';
import '../models/puzzle_pack_item.dart';
import '../network/content_http_client.dart';

/// 扩展图包内容管理管线 (支持本地 ZIP / 网络 ZIP 安全导入、零元数据推导、来源追踪与整包物理删除)
class PackContentPipeline {
  PackContentPipeline({
    required this.packsBaseDir,
    ContentHttpClient? httpClient,
  }) : _httpClient = httpClient ?? ContentHttpClient();

  final String packsBaseDir;
  final ContentHttpClient _httpClient;

  final ValueNotifier<List<PuzzlePackItem>> packsNotifier = ValueNotifier<List<PuzzlePackItem>>([]);

  static final RegExp _imageRegex = RegExp(r'\.(webp|jpg|jpeg|png)$', caseSensitive: false);

  /// 初始化并加载本地所有已导入的图包
  Future<List<PuzzlePackItem>> loadAllPacks() async {
    final baseDir = Directory(packsBaseDir);
    if (!baseDir.existsSync()) {
      baseDir.createSync(recursive: true);
      packsNotifier.value = const [];
      AppLogger.pack.info('loadAllPacks base dir created empty ${AppLogger.sanitizePath(packsBaseDir)}');
      return const [];
    }
    AppLogger.pack.fine('loadAllPacks scanning ${AppLogger.sanitizePath(packsBaseDir)}');

    final packs = <PuzzlePackItem>[];
    final subDirs = baseDir.listSync().whereType<Directory>();

    for (final dir in subDirs) {
      final packJsonFile = File(p.join(dir.path, 'pack.json'));
      if (packJsonFile.existsSync()) {
        try {
          final content = packJsonFile.readAsStringSync();
          final jsonMap = jsonDecode(content) as Map<String, dynamic>;
          final item = PuzzlePackItem.fromJson(jsonMap);
          // 确保封面存在或重新推导
          final coverPath = item.coverPath.isNotEmpty && File(item.coverPath).existsSync()
              ? item.coverPath
              : _findFirstImage(dir.path);
          packs.add(item.copyWith(coverPath: coverPath));
        } catch (e, st) {
          AppLogger.pack.warning('Failed to parse pack.json in ${AppLogger.sanitizePath(dir.path)}', e, st);
        }
      }
    }

    // 按导入时间倒序排列 (最新导入在最前)
    packs.sort((a, b) => b.importedAt.compareTo(a.importedAt));
    packsNotifier.value = List.unmodifiable(packs);
    AppLogger.pack.info('loadAllPacks done count=${packs.length}');
    return packs;
  }

  /// 从本地 ZIP 压缩包导入扩展图包
  Future<PuzzlePackItem> importFromLocalZip(String zipFilePath) async {
    AppLogger.pack.info('importFromLocalZip ${AppLogger.sanitizePath(zipFilePath)}');
    final zipFile = File(zipFilePath);
    if (!zipFile.existsSync()) {
      AppLogger.pack.warning('importFromLocalZip not found ${AppLogger.sanitizePath(zipFilePath)}');
      throw Exception('指定的 ZIP 文件不存在: $zipFilePath');
    }

    final bytes = await zipFile.readAsBytes();
    final zipName = p.basenameWithoutExtension(zipFilePath);

    return _processZipBytes(
      bytes: bytes,
      defaultTitle: zipName.isEmpty ? '自定义图包' : zipName,
      sourceType: 'local_file',
      sourceOrigin: zipFilePath,
    );
  }

  /// 从网络下载 URL 导入扩展图包
  Future<PuzzlePackItem> importFromNetworkZip(String zipUrl) async {
    AppLogger.pack.info('importFromNetworkZip ${AppLogger.sanitizeUrl(zipUrl)}');
    if (zipUrl.isEmpty || !zipUrl.startsWith('http')) {
      AppLogger.pack.warning('importFromNetworkZip invalid url $zipUrl');
      throw Exception('无效的网络下载 URL: $zipUrl');
    }

    final tempZipPath = p.join(packsBaseDir, 'temp_download_${DateTime.now().millisecondsSinceEpoch}.zip');
    try {
      final downloadedZip = await _httpClient.downloadFile(zipUrl, tempZipPath);
      final bytes = await downloadedZip.readAsBytes();
      final uriName = p.basenameWithoutExtension(Uri.parse(zipUrl).path);
      final defaultTitle = uriName.isEmpty ? '网络图包' : uriName;

      final pack = await _processZipBytes(
        bytes: bytes,
        defaultTitle: defaultTitle,
        sourceType: 'network_url',
        sourceOrigin: zipUrl,
      );

      // 清理临时文件
      if (downloadedZip.existsSync()) {
        downloadedZip.deleteSync();
      }
      return pack;
    } catch (e, st) {
      AppLogger.pack.severe('importFromNetworkZip failed ${AppLogger.sanitizeUrl(zipUrl)}', e, st);
      final tf = File(tempZipPath);
      if (tf.existsSync()) {
        try {
          tf.deleteSync();
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// 核心解压、安全审查、元数据推导与落盘
  Future<PuzzlePackItem> _processZipBytes({
    required List<int> bytes,
    required String defaultTitle,
    required String sourceType,
    required String sourceOrigin,
  }) async {
    AppLogger.pack.info('_processZipBytes title=$defaultTitle source=$sourceType bytes=${bytes.length}');
    final archive = ZipDecoder().decodeBytes(bytes);
    if (archive.isEmpty) {
      AppLogger.pack.warning('_processZipBytes empty archive title=$defaultTitle');
      throw Exception('压缩包内容为空');
    }

    // 1. 生成全局唯一物理 ID (彻底防同名物理冲突)
    final randomSuffix = (Random().nextInt(9000) + 1000).toRadixString(16);
    final packId = 'pack_${DateTime.now().millisecondsSinceEpoch}_$randomSuffix';
    final targetDir = Directory(p.join(packsBaseDir, packId));
    if (targetDir.existsSync()) {
      targetDir.deleteSync(recursive: true);
    }
    targetDir.createSync(recursive: true);

    Map<String, dynamic>? manifestJson;
    String? explicitCoverName;
    final validImageFiles = <String>[];
    var totalBytes = 0;

    // 2. 解压与过滤系统垃圾文件，防御 ZipSlip
    for (final file in archive) {
      final filename = file.name.replaceAll('\\', '/');

      // 防御 ZipSlip 路径穿越
      if (filename.contains('..')) continue;

      // 忽略 MacOS 隐藏文件和系统垃圾
      if (filename.startsWith('__MACOSX/') ||
          filename.contains('/.DS_Store') ||
          filename.endsWith('.DS_Store') ||
          filename.endsWith('Thumbs.db')) {
        continue;
      }

      if (file.isFile) {
        final baseName = p.basename(filename);

        // 如果包含 pack.json 或 manifest.json
        if (baseName.toLowerCase() == 'pack.json' || baseName.toLowerCase() == 'manifest.json') {
          try {
            final str = utf8.decode(file.content as List<int>);
            manifestJson = jsonDecode(str) as Map<String, dynamic>;
          } catch (_) {}
          continue;
        }

        // 识别支持的图片格式
        if (_imageRegex.hasMatch(baseName)) {
          final outFile = File(p.join(targetDir.path, baseName));
          await outFile.writeAsBytes(file.content as List<int>, flush: true);
          validImageFiles.add(outFile.path);
          totalBytes += (file.content as List<int>).length;
        }
      }
    }

    if (validImageFiles.isEmpty) {
      // 若无有效图片，清理目录并抛出异常
      targetDir.deleteSync(recursive: true);
      AppLogger.pack.warning('_processZipBytes no valid images title=$defaultTitle totalFiles=${archive.length}');
      throw Exception('压缩包内未找到支持的图片文件 (支持 jpg, png, webp)');
    }
    AppLogger.pack.info('_processZipBytes extracted ${validImageFiles.length} images bytes=$totalBytes packId=$packId');

    // 排序图片
    validImageFiles.sort();

    // 3. 元数据解析与友好展示名推导
    var title = defaultTitle;
    var description = '';
    var author = '';
    var tags = <String>[];

    if (manifestJson != null) {
      if (manifestJson['title'] != null && manifestJson['title'].toString().trim().isNotEmpty) {
        title = manifestJson['title'].toString().trim();
      }
      if (manifestJson['description'] != null) {
        description = manifestJson['description'].toString();
      }
      if (manifestJson['author'] != null) {
        author = manifestJson['author'].toString();
      }
      if (manifestJson['cover'] != null) {
        explicitCoverName = manifestJson['cover'].toString();
      }
      if (manifestJson['tags'] is List) {
        tags = (manifestJson['tags'] as List).map((e) => e.toString()).toList();
      }
    }

    // 确定封面图片
    var coverPath = validImageFiles.first;
    if (explicitCoverName != null && explicitCoverName.isNotEmpty) {
      final explicitFile = File(p.join(targetDir.path, explicitCoverName));
      if (explicitFile.existsSync()) {
        coverPath = explicitFile.path;
      }
    }

    final packItem = PuzzlePackItem(
      id: packId,
      title: title,
      description: description,
      author: author,
      coverPath: coverPath,
      levelCount: validImageFiles.length,
      fileSizeBytes: totalBytes > 0 ? totalBytes : bytes.length,
      importedAt: DateTime.now().toIso8601String(),
      sourceType: sourceType,
      sourceOrigin: sourceOrigin,
      tags: tags,
    );

    // 4. 将标准 pack.json 落盘至图包沙盒目录
    final packJsonFile = File(p.join(targetDir.path, 'pack.json'));
    await packJsonFile.writeAsString(jsonEncode(packItem.toJson()), flush: true);

    // 5. 刷新内存列表
    await loadAllPacks();
    return packItem;
  }

  /// 一键整包物理删除 (释放磁盘存储并从索引中移除)
  Future<bool> deletePack(String packId) async {
    final packDir = Directory(p.join(packsBaseDir, packId));
    AppLogger.pack.info('deletePack $packId dir=${AppLogger.sanitizePath(packDir.path)}');
    try {
      if (packDir.existsSync()) {
        packDir.deleteSync(recursive: true);
      }
      await loadAllPacks();
      AppLogger.pack.info('deletePack success $packId');
      return true;
    } catch (e, st) {
      AppLogger.pack.severe('Failed to delete pack $packId', e, st);
      return false;
    }
  }

  /// 获取指定图包下的所有关卡列表 (按 Canonical ID 规范化封装)
  List<PuzzleLevelItem> getPackLevels(PuzzlePackItem pack) {
    final packDir = Directory(p.join(packsBaseDir, pack.id));
    if (!packDir.existsSync()) return const [];

    final files = packDir.listSync().whereType<File>().where((f) => _imageRegex.hasMatch(f.path)).toList();
    files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

    final levels = <PuzzleLevelItem>[];
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      final filename = p.basename(file.path);
      final canonicalId = CanonicalId.forPack(pack.id, filename);

      levels.add(
        PuzzleLevelItem(
          id: canonicalId,
          imagePathOrUrl: file.path,
          isLocalFile: true,
          sourceModule: CanonicalId.prefixPack,
          order: i + 1,
          tags: pack.tags,
        ),
      );
    }

    return levels;
  }

  String _findFirstImage(String dirPath) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return '';
    final files = dir.listSync().whereType<File>().where((f) => _imageRegex.hasMatch(f.path)).toList();
    if (files.isEmpty) return '';
    files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    return files.first.path;
  }
}
