import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';

import 'package:jigsawpuzzle/services/app_logger.dart';

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

  /// RFC 3986 规范级 URL 递归解析：
  /// - 若 targetUrl 为绝对地址 (带 http/https 协议头)，直接原样返回；
  /// - 否则以 baseUrl 为基准递归解析相对路径 (完美支持 ../images/ 等相对导航)。
  static String resolveUrl(String baseUrl, String targetUrl) {
    final trimmed = targetUrl.trim();
    if (trimmed.isEmpty) return baseUrl;
    final parsed = Uri.tryParse(trimmed);
    if (parsed != null && parsed.hasScheme) {
      if (parsed.scheme == 'http' || parsed.scheme == 'https') {
        return trimmed;
      }
    }
    final baseUri = Uri.parse(baseUrl);
    return baseUri.resolve(trimmed).toString();
  }

  /// 请求 JSON 字符串并解析为 Map 或 List
  Future<dynamic> fetchJson(String url, {Duration? timeout}) async {
    if (url.trim().isEmpty) {
      throw ArgumentError('url must not be empty');
    }
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
    if (url.trim().isEmpty) {
      throw ArgumentError('url must not be empty');
    }
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

  /// 按序尝试多个镜像 URL 下载同一文件（`zipUrls` 备用镜像契约，D10）。
  ///
  /// 第一个可用镜像成功即返回；单个镜像失败（网络/404/超时）自动切换到下一个，
  /// 全部失败则抛出最后一次异常。dest 已由 [downloadFile] 保证 .part 原子落盘，
  /// 镜像切换不会残留损坏文件。
  Future<File> downloadFileWithMirrors(
    List<String> urls,
    String destinationPath, {
    Duration? timeout,
    void Function(int received, int total)? onProgress,
  }) async {
    final candidates = urls.where((u) => u.trim().isNotEmpty).toList();
    if (candidates.isEmpty) {
      throw ArgumentError('urls must not be empty');
    }
    HttpException? lastError;
    for (var i = 0; i < candidates.length; i++) {
      try {
        return await downloadFile(
          candidates[i],
          destinationPath,
          timeout: timeout,
          onProgress: onProgress,
        );
      } catch (e) {
        lastError = e is HttpException
            ? e
            : HttpException('$e for ${candidates[i]}');
        AppLogger.network.warning(
          'downloadFileWithMirrors mirror $i/${candidates.length} failed: '
          '${AppLogger.sanitizeUrl(candidates[i])} -> retry next mirror',
        );
      }
    }
    throw lastError!;
  }
}
