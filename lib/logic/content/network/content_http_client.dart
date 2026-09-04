import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';

import '../../../services/app_logger.dart';

/// 健壮的内容网络请求客户端 (带临时文件原子重命名与自动清理容错)
class ContentHttpClient {
  ContentHttpClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 15),
              responseType: ResponseType.plain,
            ),
          );

  final Dio _dio;

  /// 请求 JSON 字符串并解析为 Map 或 List
  Future<dynamic> fetchJson(String url, {Duration? timeout}) async {
    final sw = Stopwatch()..start();
    AppLogger.network.fine(
      'fetchJson start ${AppLogger.sanitizeUrl(url)} timeout=${timeout?.inSeconds}s',
    );
    try {
      final response = await _dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          receiveTimeout: timeout,
        ),
      );

      if (response.statusCode != 200 || response.data == null) {
        throw HttpException('HTTP ${response.statusCode}: Failed to load $url');
      }

      final raw = response.data!.trim();
      final decoded = jsonDecode(raw);
      AppLogger.network.info(
        'fetchJson success ${AppLogger.sanitizeUrl(url)} ${sw.elapsedMilliseconds}ms bytes=${raw.length}',
      );
      return decoded;
    } catch (e, st) {
      AppLogger.network.warning(
        'fetchJson failed ${AppLogger.sanitizeUrl(url)} ${sw.elapsedMilliseconds}ms',
        e,
        st,
      );
      if (e is FormatException) {
        throw FormatException('Malformed JSON from $url: ${e.message}');
      }
      rethrow;
    }
  }

  /// 下载文件并安全原子落盘 (写入 .part 临时文件，校验成功后重命名)
  Future<File> downloadFile(
    String url,
    String destinationPath, {
    Duration? timeout,
    void Function(int received, int total)? onProgress,
  }) async {
    AppLogger.network.info(
      'downloadFile start ${AppLogger.sanitizeUrl(url)} -> ${AppLogger.sanitizePath(destinationPath)}',
    );
    final sw = Stopwatch()..start();
    final destFile = File(destinationPath);
    final partFile = File('$destinationPath.part');

    // 确保父目录存在
    if (!destFile.parent.existsSync()) {
      destFile.parent.createSync(recursive: true);
    }

    // 清理可能遗留的旧临时文件
    if (partFile.existsSync()) {
      try {
        partFile.deleteSync();
      } catch (_) {}
    }

    try {
      // P06 流式下载：Dio.download 直接落盘，内存恒定几十KB
      await _dio.download(
        url,
        partFile.path,
        options: Options(
          receiveTimeout: timeout ?? const Duration(seconds: 60),
        ),
        onReceiveProgress: onProgress,
      );

      if (!partFile.existsSync() || await partFile.length() == 0) {
        throw HttpException('HTTP 200: Empty response for $url');
      }
      // 简单大小防护（防止 zip bomb 落盘撑爆）
      const maxDiskBytes = 200 * 1024 * 1024;
      final partLen = await partFile.length();
      if (partLen > maxDiskBytes) {
        try {
          await partFile.delete();
        } catch (_) {}
        throw HttpException('File too large $partLen > $maxDiskBytes for $url');
      }

      // 原子重命名为目标文件
      if (destFile.existsSync()) {
        destFile.deleteSync();
      }
      final finalFile = await partFile.rename(destinationPath);
      AppLogger.network.info(
        'downloadFile success ${AppLogger.sanitizeUrl(url)} ${sw.elapsedMilliseconds}ms bytes=$partLen',
      );
      return finalFile;
    } on DioException catch (e, st) {
      AppLogger.network.severe(
        'downloadFile DioError status=${e.response?.statusCode} ${AppLogger.sanitizeUrl(url)} ${sw.elapsedMilliseconds}ms',
        e,
        st,
      );
      if (partFile.existsSync()) {
        try {
          partFile.deleteSync();
        } catch (_) {}
      }
      // 统一转为 HttpException 保持调用方兼容
      throw HttpException(
        'HTTP ${e.response?.statusCode ?? "error"}: ${e.message} for $url',
      );
    } catch (e, st) {
      AppLogger.network.severe(
        'downloadFile failed ${AppLogger.sanitizeUrl(url)} ${sw.elapsedMilliseconds}ms',
        e,
        st,
      );
      // 异常清理临时残损文件
      if (partFile.existsSync()) {
        try {
          partFile.deleteSync();
        } catch (_) {}
      }
      rethrow;
    }
  }
}
