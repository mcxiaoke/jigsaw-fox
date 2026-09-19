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

  /// 检查是否存在上次崩溃未完成的事务，若存在则执行自愈恢复
  static void checkForCrashRecovery() {
    if (!Platform.isWindows) return;
    try {
      final targetDir = p.dirname(Platform.resolvedExecutable);
      final journalFile = File(p.join(targetDir, '.updater', 'journal'));
      if (journalFile.existsSync()) {
        AppLogger.update.warning(
          'Found uncommitted .updater/journal from previous crash, recovering...',
        );
        final updaterPath = p.join(targetDir, 'updater.exe');
        if (File(updaterPath).existsSync()) {
          final res = Process.runSync(
            updaterPath,
            <String>['--recover', '--target', targetDir, '--silent'],
            workingDirectory: targetDir,
          );
          AppLogger.update.info(
            'Crash recovery completed with exitCode=${res.exitCode}',
          );
        }
      }
    } on Object catch (e, st) {
      AppLogger.update.warning('Crash recovery attempt failed', e, st);
    }
  }

  static Future<void> _installWindows(File zipFile) async {
    AppLogger.update.info(
      'Preparing Windows in-place update using better-updater for: ${zipFile.path}',
    );

    final currentExe = Platform.resolvedExecutable;
    final targetDir = p.dirname(currentExe);
    final exeName = p.basename(currentExe);

    // 1. 查找 updater.exe 二进制
    final targetUpdater = p.join(targetDir, 'updater.exe');
    final candidatePaths = [
      targetUpdater,
      p.join(Directory.current.path, 'tools', 'windows', 'updater.exe'),
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
      // 2. 保证安装目录下存在 updater.exe。
      // better-updater 原生支持影子 Worker（Shadow Worker），即使在安装目录下运行，
      // 它也会自动把自身复制到运行期临时目录派生 Worker，释放原可执行文件句柄，因此支持自我更新。
      final execUpdater = File(targetUpdater);
      if (!execUpdater.existsSync() && foundUpdater != targetUpdater) {
        await File(foundUpdater).copy(targetUpdater);
      }

      final executableToRun = execUpdater.existsSync()
          ? targetUpdater
          : foundUpdater;

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
      ];

      AppLogger.update.info(
        'Launching better-updater from $executableToRun with args: $args',
      );

      // 3. 按照契约：必须以 detached 模式启动，工作目录设为 targetDir
      await Process.start(
        executableToRun,
        args,
        mode: ProcessStartMode.detached,
        workingDirectory: targetDir,
      );

      AppLogger.update.info(
        'Updater launched. Exiting host process immediately to hand over locks...',
      );

      // 4. 关键契约：必须立即退出自身，绝不能等待 updater 的退出码
      // （影子 Worker 派生后主实例瞬间返回 0 仅代表交接完成，等待退出码会导致文件锁冲突）
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
