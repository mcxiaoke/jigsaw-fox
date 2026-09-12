// P1-4：外部内容（manifest/JSON/网络）解析防御：脏数据跳过降级，不中断启动
// ignore_for_file: avoid_catches_without_on_clauses
import 'dart:io';

import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:path/path.dart' as p;

/// v8 修 a：清理 [baseDir] 下由原子替换/下载产生的**本次运行产物残留**。
///
/// 仅清理两类，绝不动正式数据（红线 R1/R3）：
/// 1. `temp_*`：解压临时目录与临时 zip；
/// 2. `*.bak_<ts>`：`swapDirectoryAtomically` / `swapFileAtomically` 在
///    “改名为备份”与“删除备份”之间被强杀时留下的备份目录/文件。
///
/// 返回清理条数；任何单项失败仅告警，不影响其它项。
Future<int> cleanupStaleAtomicArtifacts(
  String baseDir, {
  String? logTag,
  bool includeTemp = true,
}) async {
  var cleaned = 0;
  final base = Directory(baseDir);
  try {
    if (!base.existsSync()) return 0;
    for (final entity in base.listSync()) {
      final name = p.basename(entity.path);
      final isTemp = includeTemp && name.startsWith('temp_');
      final isBackup = name.contains('.bak_');
      if (!isTemp && !isBackup) continue;
      try {
        if (entity.existsSync()) {
          entity.deleteSync(recursive: true);
          cleaned++;
        }
      } catch (e, st) {
        AppLogger.content.warning(
          'cleanupStaleAtomicArtifacts failed $name',
          e,
          st,
        );
      }
    }
  } catch (e, st) {
    AppLogger.content.warning(
      'cleanupStaleAtomicArtifacts scan failed ${logTag ?? baseDir}',
      e,
      st,
    );
  }
  if (cleaned > 0 && logTag != null && logTag.isNotEmpty) {
    AppLogger.content.info(
      'cleanupStaleAtomicArtifacts $logTag cleaned=$cleaned',
    );
  }
  return cleaned;
}

/// v8 修 a：回收**崩溃残留**的同级 `.bak_*`（名字含 `.bak_`）。
///
/// 只清扫 [minAge] 之前的备份，避免误删**并发中**另一次换图/换目录正在使用的
/// 备份（其回滚窗口只有毫秒级，10 分钟龄已远超它）。任何失败仅告警。
void sweepStaleBackupSiblings(
  Directory parent, {
  Duration minAge = const Duration(minutes: 10),
}) {
  try {
    if (!parent.existsSync()) return;
    final now = DateTime.now();
    for (final entity in parent.listSync()) {
      final name = p.basename(entity.path);
      if (!name.contains('.bak_')) continue;
      try {
        final age = now.difference(entity.statSync().modified);
        if (age < minAge) continue;
        entity.deleteSync(recursive: true);
        AppLogger.content.fine(
          'swept stale backup $name age=${age.inMinutes}m',
        );
      } catch (e, st) {
        AppLogger.content.warning('sweep stale backup failed $name', e, st);
      }
    }
  } catch (e, st) {
    AppLogger.content.warning('sweep stale backup scan failed', e, st);
  }
}

/// P0-4：带回滚的原子替换工具（目录 / 文件共用范式）。
///
/// 流程：旧目标改名备份（`.bak_<ts>`）→ 新产物落位 → 删备份；
/// 落位失败则回滚备份并抛出；备份删除失败仅告警，不视为错误。
/// 调用方须保证 [target] 与 [temp] 位于同一文件系统（同级目录内改名）。
Future<void> swapDirectoryAtomically(
  Directory target,
  Directory temp, {
  String? logTag,
}) async {
  final hasOld = target.existsSync();
  final bakPath = '${target.path}.bak_${DateTime.now().millisecondsSinceEpoch}';
  if (hasOld) {
    target.renameSync(bakPath);
  }
  try {
    await temp.rename(target.path);
  } catch (_) {
    if (hasOld) {
      final bak = Directory(bakPath);
      if (bak.existsSync()) {
        try {
          await bak.rename(target.path);
        } catch (_) {}
      }
    }
    rethrow;
  }
  if (hasOld) {
    try {
      final bak = Directory(bakPath);
      if (bak.existsSync()) bak.deleteSync(recursive: true);
    } catch (e) {
      AppLogger.content.warning('Delete dir backup failed $bakPath: $e');
    }
  }
  if (logTag != null && logTag.isNotEmpty) {
    AppLogger.content.fine('swapDirectoryAtomically ok $logTag');
  }
  // v8 修 a：顺带回收更早一次崩溃留下的同级 `.bak_*`（龄期保护，见函数注释）。
  sweepStaleBackupSiblings(target.parent);
}

/// 原子文件替换：与 [swapDirectoryAtomically] 同范式，适用于缓存 JSON 等单文件。
Future<void> swapFileAtomically(String targetPath, String tempPath) async {
  final target = File(targetPath);
  final temp = File(tempPath);
  final hasOld = target.existsSync();
  final bakPath = '$targetPath.bak_${DateTime.now().millisecondsSinceEpoch}';
  if (hasOld) {
    await target.rename(bakPath);
  }
  try {
    await temp.rename(targetPath);
  } catch (_) {
    if (hasOld) {
      final bak = File(bakPath);
      if (bak.existsSync()) {
        try {
          await bak.rename(targetPath);
        } catch (_) {}
      }
    }
    rethrow;
  }
  if (hasOld) {
    try {
      final bak = File(bakPath);
      if (bak.existsSync()) bak.deleteSync();
    } catch (e) {
      AppLogger.content.warning('Delete file backup failed $bakPath: $e');
    }
  }
  // v8 修 a：同上，回收同级残留的 `.bak_*`（主缓存 JSON 与图片共用此范式）。
  sweepStaleBackupSiblings(target.parent);
}
