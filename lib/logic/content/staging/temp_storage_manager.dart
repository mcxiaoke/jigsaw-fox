// 专用临时暂存区与冷启动清理管理器
// ignore_for_file: avoid_catches_without_on_clauses
import 'dart:io';
import 'package:jigsawpuzzle/logic/content/pipelines/atomic_replace.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:path/path.dart' as p;

/// 临时存储与清理配置常量
///
/// 集中定义下载临时文件与解压目录名规则。
class TempStorageConfig {
  TempStorageConfig._();

  /// 专用暂存根目录相对名称（位于 appSupportDir 下）
  static const String tempDirectoryName = 'temp';

  /// 下载暂存子目录相对名称（存放 *.zip 与流式写入中的 *.part）
  static const String downloadsSubDirName = 'downloads';

  /// 解压暂存子目录相对名称（存放后台解压与校验中的临时目录）
  static const String extractSubDirName = 'extract';
}

/// 负责统筹应用下载暂存、解压暂存、原子提升与冷启动清扫
class TempStorageManager {
  TempStorageManager({required this.appSupportDir});

  final String appSupportDir;

  /// 暂存根目录路径：appSupportDir/temp
  String get tempRootDir =>
      p.join(appSupportDir, TempStorageConfig.tempDirectoryName);

  /// 下载暂存目录路径：appSupportDir/temp/downloads
  String get downloadsDir =>
      p.join(tempRootDir, TempStorageConfig.downloadsSubDirName);

  /// 解压暂存目录路径：appSupportDir/temp/extract
  String get extractDir =>
      p.join(tempRootDir, TempStorageConfig.extractSubDirName);

  /// 确保暂存根目录及其子目录在磁盘上就绪
  void ensureTempDirectoriesExist() {
    try {
      final dDir = Directory(downloadsDir);
      if (!dDir.existsSync()) {
        dDir.createSync(recursive: true);
      }
      final eDir = Directory(extractDir);
      if (!eDir.existsSync()) {
        eDir.createSync(recursive: true);
      }
    } catch (e, st) {
      AppLogger.content.warning('ensureTempDirectoriesExist failed', e, st);
    }
  }

  /// 为下载任务生成唯一的临时文件路径（位于 temp/downloads）
  String createTempDownloadPath(String modulePrefix, String id) {
    ensureTempDirectoriesExist();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final sanitizedId = id.replaceAll(RegExp(r'[^\w\-]'), '_');
    return p.join(downloadsDir, '${modulePrefix}_${sanitizedId}_$ts.zip');
  }

  /// 为解压任务生成唯一的临时目录（位于 temp/extract）
  Directory createTempExtractDir(String modulePrefix, String id) {
    ensureTempDirectoriesExist();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final sanitizedId = id.replaceAll(RegExp(r'[^\w\-]'), '_');
    final dirPath = p.join(
      extractDir,
      'extract_${modulePrefix}_${sanitizedId}_$ts',
    );
    final dir = Directory(dirPath);
    if (dir.existsSync()) {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
    dir.createSync(recursive: true);
    return dir;
  }

  /// 将已在 temp/extract 校验合格的临时目录原子提升（Promote）移入正式目标目录
  ///
  /// 遵循红线 R1（绝不丢失合法已有数据）：
  /// 1. 若目标目录已存在，先将其重命名为同级备份目录 `.bak_<ts>`。
  /// 2. 尝试执行同卷原子重命名（`extractDir.rename(targetDir.path)`）。
  /// 3. 若重命名失败（跨卷或特殊文件系统环境），执行分阶段拷贝回退：
  ///    先拷贝至 targetDir 同级暂存目录 `.staging_<ts>`，拷贝完毕后再同级原子重命名至 `targetDir.path`。
  /// 4. 提升落位成功后，安全删除旧备份并扫描回收过期兄弟备份（[sweepStaleBackupSiblings]）。
  /// 5. 任何一步异常失败，均自动清理 staging 残留并将 `.bak_<ts>` 回滚还原为 targetDir，最后重新抛出异常。
  Future<void> promoteExtractDir(
    Directory extractDir,
    Directory targetDir,
  ) async {
    if (!extractDir.existsSync()) {
      throw StateError(
        'promoteExtractDir failed: extractDir does not exist ${extractDir.path}',
      );
    }

    if (!targetDir.parent.existsSync()) {
      targetDir.parent.createSync(recursive: true);
    }

    final hasOld = targetDir.existsSync();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final bakPath = '${targetDir.path}.bak_$ts';
    final stagingPath = '${targetDir.path}.staging_$ts';

    if (hasOld) {
      targetDir.renameSync(bakPath);
    }

    try {
      try {
        // 同驱动器跨目录 rename：微秒级原子指针修改
        await extractDir.rename(targetDir.path);
      } catch (renameErr, renameSt) {
        AppLogger.content.warning(
          'promoteExtractDir rename failed, attempting staging copy fallback: ${extractDir.path} -> ${targetDir.path}',
          renameErr,
          renameSt,
        );

        // 跨卷回退：拷入同级 staging 临时目录
        final stagingDir = Directory(stagingPath);
        if (stagingDir.existsSync()) {
          try {
            stagingDir.deleteSync(recursive: true);
          } catch (_) {}
        }
        await _copyDirectory(extractDir, stagingDir);

        // 拷完后同级原子 rename 至正式目标
        await stagingDir.rename(targetDir.path);

        // 拷贝与重命名均成功，清理源 extractDir
        try {
          if (extractDir.existsSync()) {
            extractDir.deleteSync(recursive: true);
          }
        } catch (_) {}
      }
    } catch (err, st) {
      AppLogger.content.severe(
        'promoteExtractDir failed: ${extractDir.path} -> ${targetDir.path}',
        err,
        st,
      );

      // 清理 staging 临时残留
      try {
        final stagingDir = Directory(stagingPath);
        if (stagingDir.existsSync()) {
          stagingDir.deleteSync(recursive: true);
        }
      } catch (_) {}

      // 清理可能部分生成的目标目录
      try {
        if (targetDir.existsSync()) {
          targetDir.deleteSync(recursive: true);
        }
      } catch (_) {}

      // 红线 R1：回滚恢复原有备份
      if (hasOld) {
        final bakDir = Directory(bakPath);
        if (bakDir.existsSync()) {
          try {
            await bakDir.rename(targetDir.path);
            AppLogger.content.info(
              'promoteExtractDir rolled back successfully: $bakPath -> ${targetDir.path}',
            );
          } catch (rollbackErr, rollbackSt) {
            AppLogger.content.severe(
              'promoteExtractDir rollback failed $bakPath -> ${targetDir.path}',
              rollbackErr,
              rollbackSt,
            );
          }
        }
      }
      rethrow;
    }

    // 成功后删除备份
    if (hasOld) {
      try {
        final bakDir = Directory(bakPath);
        if (bakDir.existsSync()) {
          bakDir.deleteSync(recursive: true);
        }
      } catch (e) {
        AppLogger.content.warning(
          'promoteExtractDir delete backup failed $bakPath: $e',
        );
      }
    }

    // 回收可能更早遗留的过期兄弟备份（带 10 分钟龄期保护）
    sweepStaleBackupSiblings(targetDir.parent);
  }

  /// 冷启动清理：清空整个 temp 暂存区（在所有前后台网络任务启动前执行）
  ///
  /// 返回清理的文件与目录数量。
  Future<int> cleanStaleTempDirectory() async {
    final root = Directory(tempRootDir);
    if (!root.existsSync()) {
      ensureTempDirectoriesExist();
      return 0;
    }

    var cleaned = 0;
    try {
      final entries = root.listSync();
      for (final entry in entries) {
        try {
          if (entry.existsSync()) {
            entry.deleteSync(recursive: true);
            cleaned++;
          }
        } catch (e, st) {
          AppLogger.content.warning(
            'cleanStaleTempDirectory failed for ${entry.path}',
            e,
            st,
          );
        }
      }
    } catch (e, st) {
      AppLogger.content.warning('cleanStaleTempDirectory scan failed', e, st);
    }

    // 清理后重新重建空目录结构
    ensureTempDirectoriesExist();

    if (cleaned > 0) {
      AppLogger.content.info(
        'cleanStaleTempDirectory cleaned $cleaned entries',
      );
    }
    return cleaned;
  }

  /// 递归拷贝目录（跨卷 fallback 用）
  Future<void> _copyDirectory(Directory src, Directory dst) async {
    if (!dst.existsSync()) {
      dst.createSync(recursive: true);
    }
    final entities = src.listSync();
    for (final entity in entities) {
      final name = p.basename(entity.path);
      final destPath = p.join(dst.path, name);
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(destPath));
      } else if (entity is File) {
        await entity.copy(destPath);
      }
    }
  }
}
