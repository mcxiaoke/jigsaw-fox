import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/models/downloaded_image_item.dart';

/// Singleton manager for batch downloaded online images with local persistence,
/// deduplication, and metadata parsing.
class DownloadManager {
  DownloadManager._();
  static final DownloadManager instance = DownloadManager._();

  static const String _storageKey = 'cached_downloaded_images_v1';
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
      followRedirects: true,
      maxRedirects: 5,
    ),
  );

  final ValueNotifier<List<DownloadedImageItem>> itemsNotifier =
      ValueNotifier<List<DownloadedImageItem>>([]);

  List<DownloadedImageItem> get items => itemsNotifier.value;

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawJson = prefs.getString(_storageKey);
      if (rawJson != null && rawJson.isNotEmpty) {
        final list = (jsonDecode(rawJson) as List<dynamic>)
            .map((e) => DownloadedImageItem.fromJson(e as Map<String, dynamic>))
            .where((item) {
          final file = File(item.localPath);
          return file.existsSync();
        }).toList();

        itemsNotifier.value = list;
        debugPrint('[DownloadManager:Init] Loaded ${list.length} cached images.');
      }
    } catch (e) {
      debugPrint('[DownloadManager:Init] Failed to load cache: $e');
    }
  }

  Future<void> _saveToStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = itemsNotifier.value.map((e) => e.toJson()).toList();
      await prefs.setString(_storageKey, jsonEncode(jsonList));
    } catch (e) {
      debugPrint('[DownloadManager:Storage] Save failed: $e');
    }
  }

  /// Check if the image sourceUrl already exists in download drawer.
  bool isDownloaded(String sourceUrl) {
    if (sourceUrl.isEmpty) return false;
    return itemsNotifier.value.any((item) => item.sourceUrl == sourceUrl);
  }

  /// Download or save image bytes, extract metadata, and register to download drawer.
  Future<DownloadedImageItem> saveOrDownloadImage({
    required String sourceUrl,
    required String sourcePlatform,
    String? refererUrl,
    String? userAgent,
    String? cookie,
    Uint8List? directBytes,
    void Function(double progress)? onProgress,
  }) async {
    await init();
    debugPrint('[DownloadManager:Start] Platform: $sourcePlatform, URL: $sourceUrl, DirectBytes: ${directBytes != null ? "${directBytes.length} bytes" : "false"}');

    // Check duplicate
    final existing = itemsNotifier.value.where((item) => item.sourceUrl == sourceUrl);
    if (existing.isNotEmpty) {
      final item = existing.first;
      if (File(item.localPath).existsSync()) {
        debugPrint('[DownloadManager:CacheHit] Returning existing file: ${item.localPath}');
        return item;
      }
    }

    final appSupportDir = await getApplicationSupportDirectory();
    final cacheDir = Directory('${appSupportDir.path}/download_cache');
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }

    final id = 'dl_${DateTime.now().millisecondsSinceEpoch}';
    final filePath = '${cacheDir.path}/img_$id.jpg';
    final targetFile = File(filePath);

    Uint8List rawBytes;

    if (directBytes != null && directBytes.isNotEmpty) {
      rawBytes = directBytes;
      await targetFile.writeAsBytes(rawBytes);
      if (onProgress != null) onProgress(1.0);
      debugPrint('[DownloadManager:DirectSave] Written ${rawBytes.length} bytes to $filePath');
    } else {
      final headers = <String, dynamic>{
        'Accept': '*/*',
        'User-Agent': (userAgent != null && userAgent.isNotEmpty)
            ? userAgent
            : 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      };

      Response<List<int>> response;
      try {
        debugPrint('[DownloadManager:Dio] Requesting URL: $sourceUrl');
        response = await _dio.get<List<int>>(
          sourceUrl,
          options: Options(
            responseType: ResponseType.bytes,
            headers: headers,
          ),
          onReceiveProgress: (received, total) {
            if (total > 0 && onProgress != null) {
              onProgress(received / total);
            }
          },
        );
      } on DioException catch (dioErr) {
        debugPrint('[DownloadManager:DioError] Status: ${dioErr.response?.statusCode}, Error: $dioErr');
        // If 403 or error occurred, retry once with desktop browser headers and referer
        if (dioErr.response?.statusCode == 403 || dioErr.response?.statusCode == 401) {
          debugPrint('[DownloadManager:DioRetry] Retrying with desktop headers...');
          final retryHeaders = <String, dynamic>{
            'Accept': 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
            if (refererUrl != null && refererUrl.isNotEmpty) 'Referer': refererUrl,
          };
          response = await _dio.get<List<int>>(
            sourceUrl,
            options: Options(responseType: ResponseType.bytes, headers: retryHeaders),
          );
        } else {
          rethrow;
        }
      }

      final data = response.data;
      if (data == null || data.isEmpty) {
        throw Exception('下载数据为空');
      }
      rawBytes = Uint8List.fromList(data);
      await targetFile.writeAsBytes(rawBytes);
      debugPrint('[DownloadManager:DioSuccess] Downloaded ${rawBytes.length} bytes to $filePath');
    }

    // Parse and strictly validate image dimensions
    int width;
    int height;
    try {
      final codec = await ui.instantiateImageCodec(rawBytes);
      final frame = await codec.getNextFrame();
      width = frame.image.width;
      height = frame.image.height;
      frame.image.dispose();
      codec.dispose();
      debugPrint('[DownloadManager:Metadata] Parsed resolution: ${width}x$height');

      // Reject tiny placeholder/icon images
      if (width < 200 || height < 200) {
        if (targetFile.existsSync()) targetFile.deleteSync();
        debugPrint('[DownloadManager:ValidationError] Rejected image due to tiny resolution: ${width}x$height');
        throw Exception('图片分辨率过小 (${width}x$height)，并非有效的高清拼图素材');
      }
    } catch (e) {
      if (targetFile.existsSync()) targetFile.deleteSync();
      debugPrint('[DownloadManager:MetadataError] Could not decode valid image: $e');
      throw Exception('下载数据不是有效图片文件: $e');
    }

    final item = DownloadedImageItem(
      id: id,
      sourceUrl: sourceUrl,
      localPath: filePath,
      sourcePlatform: sourcePlatform,
      width: width,
      height: height,
      downloadedAt: DateTime.now(),
      fileSizeBytes: rawBytes.length,
    );

    itemsNotifier.value = [item, ...itemsNotifier.value];
    await _saveToStorage();
    debugPrint('[DownloadManager:Complete] Added item $id (${width}x$height, ${rawBytes.length} bytes). Total cached: ${itemsNotifier.value.length}');

    return item;
  }

  /// Delete a downloaded item from storage and file system.
  Future<void> deleteItem(String id) async {
    final list = List<DownloadedImageItem>.from(itemsNotifier.value);
    final idx = list.indexWhere((e) => e.id == id);
    if (idx != -1) {
      final item = list[idx];
      try {
        final f = File(item.localPath);
        if (f.existsSync()) {
          f.deleteSync();
        }
      } catch (e) {
        debugPrint('[DownloadManager:Delete] Error deleting file: $e');
      }
      list.removeAt(idx);
      itemsNotifier.value = list;
      await _saveToStorage();
      debugPrint('[DownloadManager:Delete] Removed item $id');
    }
  }

  /// Alias for deleteItem
  Future<void> removeItem(String id) => deleteItem(id);

  /// Clear all downloaded items
  Future<void> clearAll() async {
    for (final item in itemsNotifier.value) {
      try {
        final f = File(item.localPath);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    itemsNotifier.value = [];
    await _saveToStorage();
    debugPrint('[DownloadManager:ClearAll] All downloaded images cleared.');
  }
}
