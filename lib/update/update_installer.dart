import 'dart:io';

import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

/// 平台安装器
class UpdateInstaller {
  UpdateInstaller._();

  /// 执行安装包
  static Future<void> install(File packageFile) async {
    if (!packageFile.existsSync()) {
      AppLogger.update.severe(
        'Install failed: file not found at ${packageFile.path}',
      );
      throw FileSystemException('安装包文件不存在', packageFile.path);
    }

    if (Platform.isWindows) {
      await _installWindows(packageFile);
    } else if (Platform.isAndroid) {
      await _installAndroid(packageFile);
    } else {
      AppLogger.update.warning(
        'Auto update not supported on platform: ${Platform.operatingSystem}',
      );
      throw UnsupportedError('当前平台不支持自动更新');
    }
  }

  static Future<void> _installWindows(File zipFile) async {
    AppLogger.update.info(
      'Preparing Windows in-place update using updater-rs for: ${zipFile.path}',
    );

    final currentExe = Platform.resolvedExecutable;
    final targetDir = p.dirname(currentExe);
    final exeName = p.basename(currentExe);

    // 1. 查找 updater.exe 二进制
    final candidatePaths = [
      p.join(targetDir, 'updater.exe'),
      p.join(Directory.current.path, 'tools', 'windows', 'updater.exe'),
      r'C:\Home\Projects\mytools\tools\updater\rust\target\release\updater.exe',
    ];

    String? foundUpdater;
    for (final candidate in candidatePaths) {
      if (File(candidate).existsSync()) {
        foundUpdater = candidate;
        break;
      }
    }

    if (foundUpdater == null) {
      final msg = '未找到自动更新工具 updater.exe，搜索路径: $candidatePaths';
      AppLogger.update.severe(msg);
      throw FileSystemException(msg);
    }

    try {
      // 2. 遵循最佳实践：将 updater.exe 复制到系统临时目录执行
      // 保证安装目录下的 updater.exe 也能随新版本 zip 覆盖更新
      final tempDir = p.join(Directory.systemTemp.path, 'jigsawfox_updater');
      final tempDirObj = Directory(tempDir);
      if (!tempDirObj.existsSync()) {
        await tempDirObj.create(recursive: true);
      }
      final tempUpdater = p.join(tempDir, 'updater.exe');
      await File(foundUpdater).copy(tempUpdater);

      final args = <String>[
        '--pid',
        '$pid',
        '--zip',
        zipFile.path,
        '--target',
        targetDir,
        '--launch',
        exeName,
        '--args',
        '--updated',
        '--gui',
        '--delete-zip',
      ];

      AppLogger.update.info(
        'Launching updater from $tempUpdater with args: $args',
      );

      // 3. 以 detached 模式启动，脱离当前主程序进程树
      await Process.start(
        tempUpdater,
        args,
        mode: ProcessStartMode.detached,
      );

      AppLogger.update.info(
        'Updater launched successfully. Exiting main process to release file locks...',
      );

      // 4. 短暂延时后退出主程序释放所有文件锁
      await Future<void>.delayed(const Duration(milliseconds: 200));
      exit(0);
    } catch (e, st) {
      AppLogger.update.severe('Failed to launch Windows updater', e, st);
      rethrow;
    }
  }

  static Future<void> _installAndroid(File file) async {
    AppLogger.update.info('Triggering Android APK install: ${file.path}');
    try {
      final result = await OpenFilex.open(
        file.path,
        type: 'application/vnd.android.package-archive',
      );
      AppLogger.update.info(
        'OpenFilex result: type=${result.type} message=${result.message}',
      );

      if (result.type != ResultType.done) {
        throw Exception('调起系统安装器失败: ${result.message} (${result.type})');
      }
    } catch (e, st) {
      AppLogger.update.severe('Failed to open APK via OpenFilex', e, st);
      rethrow;
    }
  }
}
