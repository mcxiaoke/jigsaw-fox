import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';

/// 健壮的内容网络请求客户端 (带临时文件原子重命名与自动清理容错)
class ContentHttpClient {
  ContentHttpClient({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 8),
                receiveTimeout: const Duration(seconds: 15),
                responseType: ResponseType.plain,
              ),
            );

  final Dio _dio;

  /// 请求 JSON 字符串并解析为 Map 或 List
  Future<dynamic> fetchJson(
    String url, {
    Duration? timeout,
  }) async {
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
      return jsonDecode(raw);
    } catch (e) {
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
      final response = await _dio.get<Uint8List>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: timeout ?? const Duration(seconds: 30),
        ),
        onReceiveProgress: onProgress,
      );

      if (response.statusCode != 200 || response.data == null || response.data!.isEmpty) {
        throw HttpException('HTTP ${response.statusCode}: Empty response for $url');
      }

      // 写入临时文件
      await partFile.writeAsBytes(response.data!, flush: true);

      // 原子重命名为目标文件
      if (destFile.existsSync()) {
        destFile.deleteSync();
      }
      final finalFile = await partFile.rename(destinationPath);
      return finalFile;
    } catch (e) {
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
