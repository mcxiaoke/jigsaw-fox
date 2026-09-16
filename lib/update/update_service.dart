import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:jigsawpuzzle/update/update_installer.dart';
import 'package:jigsawpuzzle/update/update_models.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App 自动更新核心服务
class UpdateService {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  static const String _defaultUpdatesUrl =
      'https://jigsawdata.umao.top/app/updates.json';
  static const String _defaultR2Base = 'https://jigsawdata.umao.top/';
  static const String _prefSkippedVersionCodeKey =
      'autoupdate_skipped_version_code';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: <String, String>{'Cache-Control': 'no-cache'},
    ),
  );

  PackageInfo? _cachedPackageInfo;

  List<String>? _cachedSupportedAbis;

  /// 获取当前 Android 设备支持的 CPU 架构列表（按优先级降序排列，如 [arm64-v8a, armeabi-v7a]）
  Future<List<String>> getSupportedAbis() async {
    if (!Platform.isAndroid) return const [];
    if (_cachedSupportedAbis != null) return _cachedSupportedAbis!;
    try {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      final abis = androidInfo.supportedAbis;
      if (abis.isNotEmpty) {
        _cachedSupportedAbis = abis;
        return abis;
      }
    } on Object catch (e) {
      AppLogger.update.warning(
        'Failed to detect device ABIs via device_info_plus',
        e,
      );
    }
    return const [];
  }

  /// 获取本地应用版本信息
  Future<PackageInfo> getPackageInfo() async {
    if (_cachedPackageInfo != null) {
      return _cachedPackageInfo!;
    }
    try {
      _cachedPackageInfo = await PackageInfo.fromPlatform();
      return _cachedPackageInfo!;
    } on Object catch (e) {
      AppLogger.update.warning('Failed to load PackageInfo from platform', e);
      // Fallback 兼容
      _cachedPackageInfo = PackageInfo(
        appName: 'JigsawPuzzle',
        packageName: 'com.example.jigsawpuzzle',
        version: '1.0.0',
        buildNumber: '1',
      );
      return _cachedPackageInfo!;
    }
  }

  /// 检查是否有可用更新
  ///
  /// [isSilent] 为 true 时表示后台/启动静默检查，发生错误时不抛异常
  Future<UpdateCheckResult> checkForUpdate({
    bool isSilent = false,
    String updatesUrl = _defaultUpdatesUrl,
  }) async {
    final pkg = await getPackageInfo();
    final currentVersion = pkg.version;
    final currentCode = int.tryParse(pkg.buildNumber) ?? 1;
    final supportedAbis = await getSupportedAbis();

    // Windows 平台崩溃自愈探测
    UpdateInstaller.checkForCrashRecovery();

    AppLogger.update.info(
      'Check update started: source=${isSilent ? "silent" : "manual"}, '
      'local=$currentVersion+$currentCode, abis=$supportedAbis, url=$updatesUrl',
    );

    try {
      final response = await _dio.get<String>(
        updatesUrl,
        options: Options(responseType: ResponseType.plain),
      );

      if (response.statusCode != 200 || response.data == null) {
        throw DioException(
          requestOptions: response.requestOptions,
          response: response,
          message: 'HTTP response code: ${response.statusCode}',
        );
      }

      final jsonMap = jsonDecode(response.data!) as Map<String, dynamic>;
      final manifest = UpdateManifest.fromJson(jsonMap);

      AppLogger.update.info(
        'Fetched remote updates.json: remoteVersion=${manifest.version}+${manifest.versionCode}, '
        'minVersionCode=${manifest.minVersionCode}',
      );

      final platformInfo = manifest.getPackageForPlatform(
        supportedAbis: supportedAbis,
      );
      if (platformInfo == null) {
        AppLogger.update.info(
          'No update package found for current platform (${Platform.operatingSystem}, abis: $supportedAbis)',
        );
        return UpdateCheckResult(
          status: UpdateStatus.noUpdate,
          manifest: manifest,
          currentVersion: currentVersion,
          currentVersionCode: currentCode,
        );
      }

      // 版本比对：remote.versionCode > local.versionCode
      if (manifest.versionCode <= currentCode) {
        AppLogger.update.info(
          'Already on the latest version ($currentCode >= ${manifest.versionCode})',
        );
        return UpdateCheckResult(
          status: UpdateStatus.noUpdate,
          manifest: manifest,
          platformInfo: platformInfo,
          currentVersion: currentVersion,
          currentVersionCode: currentCode,
        );
      }

      // 检查是否强制更新
      final isForce = currentCode < manifest.minVersionCode;

      // 检查是否用户此前忽略了此版本（仅在非强制且静默检查时生效）
      if (!isForce && isSilent) {
        final skippedCode = await getSkippedVersionCode();
        if (skippedCode == manifest.versionCode) {
          AppLogger.update.info(
            'Update available (${manifest.versionCode}), but user skipped this version',
          );
          return UpdateCheckResult(
            status: UpdateStatus.skipped,
            manifest: manifest,
            platformInfo: platformInfo,
            currentVersion: currentVersion,
            currentVersionCode: currentCode,
          );
        }
      }

      final status = isForce
          ? UpdateStatus.forceUpdateRequired
          : UpdateStatus.updateAvailable;

      AppLogger.update.info(
        'Update found: status=$status, remote=${manifest.version}+${manifest.versionCode}',
      );

      return UpdateCheckResult(
        status: status,
        manifest: manifest,
        platformInfo: platformInfo,
        currentVersion: currentVersion,
        currentVersionCode: currentCode,
      );
    } catch (e, st) {
      AppLogger.update.warning('Check update failed: $e', e, st);
      if (isSilent) {
        return UpdateCheckResult(
          status: UpdateStatus.error,
          currentVersion: currentVersion,
          currentVersionCode: currentCode,
          errorMessage: e.toString(),
        );
      }
      rethrow;
    }
  }

  /// 下载并强校验安装包
  ///
  /// 会自动尝试主源，失败则按序回退到备用镜像。下载完毕计算 SHA256 强校验。
  Future<File> downloadAndVerify(
    PlatformUpdateInfo info, {
    void Function(int received, int total)? onProgress,
    String r2Base = _defaultR2Base,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final ext = Platform.isWindows ? '.exe' : '.apk';
    final targetPath = p.join(
      tempDir.path,
      'app_update_${DateTime.now().millisecondsSinceEpoch}$ext',
    );
    final targetFile = File(targetPath);

    // 候选源地址列表：主源先行，备源兜底
    final candidateUrls = <String>[
      info.fullUrl(r2Base),
      ...info.mirrors,
    ];

    AppLogger.update.info(
      'Starting download: ${candidateUrls.length} candidate URLs, targetSize=${info.size}, '
      'expectedSha256=${info.sha256}',
    );

    DioException? lastError;
    var downloadSucceeded = false;

    for (var i = 0; i < candidateUrls.length; i++) {
      final currentUrl = candidateUrls[i];
      final isMirror = i > 0;
      AppLogger.update.info(
        'Attempting download [${i + 1}/${candidateUrls.length}] '
        '(${isMirror ? "mirror" : "main"}): $currentUrl',
      );

      try {
        if (targetFile.existsSync()) {
          targetFile.deleteSync();
        }

        await _dio.download(
          currentUrl,
          targetPath,
          onReceiveProgress: onProgress,
          options: Options(responseType: ResponseType.stream),
        );

        downloadSucceeded = true;
        AppLogger.update.info('Download completed from: $currentUrl');
        break;
      } on DioException catch (e) {
        lastError = e;
        AppLogger.update.warning(
          'Failed downloading from $currentUrl: ${e.message}',
        );
      } on Object catch (e) {
        AppLogger.update.warning(
          'Unexpected error downloading $currentUrl: $e',
        );
      }
    }

    if (!downloadSucceeded || !targetFile.existsSync()) {
      if (targetFile.existsSync()) {
        targetFile.deleteSync();
      }
      throw lastError ?? Exception('所有下载镜像均连接失败');
    }

    // 强校验 SHA256 与文件大小
    AppLogger.update.info('Verifying downloaded package sha256 and size...');
    final downloadedBytes = await targetFile.readAsBytes();
    final actualSize = downloadedBytes.length;
    final actualSha256 = sha256
        .convert(downloadedBytes)
        .toString()
        .toLowerCase();
    final expectedSha256 = info.sha256.trim().toLowerCase();

    if (actualSize != info.size) {
      targetFile.deleteSync();
      final msg = '文件大小不匹配！预期: ${info.size}, 实际: $actualSize bytes';
      AppLogger.update.severe(msg);
      throw StateError(msg);
    }

    if (actualSha256 != expectedSha256) {
      targetFile.deleteSync();
      final msg = 'SHA256 哈希校验失败！\n预期: $expectedSha256\n实际: $actualSha256';
      AppLogger.update.severe(msg);
      throw StateError(msg);
    }

    AppLogger.update.info(
      'Package integrity verification passed! size=$actualSize, sha256=$actualSha256',
    );
    return targetFile;
  }

  /// 一键安装
  Future<void> executeInstall(File packageFile) async {
    await UpdateInstaller.install(packageFile);
  }

  /// 标记忽略某个版本
  Future<void> skipVersion(int versionCode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefSkippedVersionCodeKey, versionCode);
    AppLogger.update.info('User skipped update versionCode=$versionCode');
  }

  /// 获取此前用户忽略的版本号
  Future<int?> getSkippedVersionCode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_prefSkippedVersionCodeKey);
  }

  /// 清除已忽略的版本
  Future<void> clearSkippedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefSkippedVersionCodeKey);
  }
}
