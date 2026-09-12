// P1-4：持久层防御式容错：损坏数据/IO 异常必须降级而非崩溃，本文件统一豁免裸 catch
// ignore_for_file: avoid_catches_without_on_clauses
import 'dart:convert';
import 'dart:io';

import 'package:jigsawpuzzle/logic/models/puzzle_state.dart';
import 'package:jigsawpuzzle/logic/puzzle_model.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 文件级快照存储（原子写、损坏自愈、短哈希防串档、版本前瞻兼容）
///
/// 设计要点（见 docs/save-resume-continue-design-20260830.md）：
/// - 主键 `<canonicalId>::<difficultyKey>`，文件名为安全化+短哈希后的 `<safeId>_<hash>__<RxC>.snapshot`
/// - 原子写：`tmp -> bak 保护 -> rename`，避免半写损坏和 Windows 覆盖失败风险
/// - 读取时 `PuzzleBoardState.fromJson` 的 `extra` 透传保证前瞻兼容
/// - 单关卡只留最新残局，保存新难度时自动清理同关旧快照
class SnapshotStore {
  SnapshotStore._();
  static final SnapshotStore instance = SnapshotStore._();

  Directory? _snapshotsDir;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    try {
      final support = await getApplicationSupportDirectory();
      _snapshotsDir = Directory(p.join(support.path, 'snapshots'));
      if (!await _snapshotsDir!.exists()) {
        await _snapshotsDir!.create(recursive: true);
      }
      _initialized = true;
      AppLogger.repo.info(
        'SnapshotStore init dir=${AppLogger.sanitizePath(_snapshotsDir!.path)}',
      );
      // 启动时清理残留临时文件
      await _cleanupTempFiles();
      _initialized = true;
    } catch (e, st) {
      AppLogger.repo.warning('SnapshotStore init failed', e, st);
      // 回退到临时目录（测试环境）
      _snapshotsDir = Directory(
        p.join(Directory.systemTemp.path, 'jigsaw_snapshots'),
      );
      try {
        if (!await _snapshotsDir!.exists()) {
          await _snapshotsDir!.create(recursive: true);
        }
      } catch (_) {}
      await _cleanupTempFiles();
      _initialized = true;
    }
  }

  /// 测试专用：跳过 path_provider，直接注入隔离快照目录并标记已初始化。
  ///
  /// 纯 Dart 测试环境缺少 path_provider 平台插件，[init] 会落入 catch 回退
  /// 分支、写全局 `%TEMP%\jigsaw_snapshots`——真实调试数据与各测试互相污染。
  /// 注入目录由测试基建（test_helper.dart）创建在临时 home 下，并随其清理；
  /// 注入后 `_initialized=true`，业务路径（如 GameRepository.init）中的
  /// init() 调用自动短路，不会再触全局回退目录。
  @visibleForTesting
  void initForTest(Directory dir) {
    // save() 不负责建目录（由 init() 承担），注入时同步建好（幂等）。
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    _snapshotsDir = dir;
    _initialized = true;
  }

  /// 清理残留的 .tmp / .bak 临时文件（P21 崩溃恢复）
  /// 若 mid-save 崩溃导致 `.snapshot` 缺失而 `.tmp`(新)+`.bak`(旧) 同时存在，
  /// 优先恢复新快照而非无条件双删导致新旧全丢。
  Future<void> _cleanupTempFiles() async {
    final dir = _snapshotsDir;
    if (dir == null) return;
    try {
      if (!await dir.exists()) return;
      final files = <File>[];
      await for (final f in dir.list()) {
        if (f is File) files.add(f);
      }
      // 先按基名分组处理 tmp/bak
      for (final f in files) {
        final name = p.basename(f.path);
        if (name.endsWith('.tmp')) {
          final baseName = name.substring(0, name.length - 4); // 去掉 .tmp
          final snapshotFile = File(p.join(dir.path, baseName));
          final snapshotExists = await snapshotFile.exists();
          if (!snapshotExists) {
            // 尝试用 tmp 恢复为正式快照（新数据）
            try {
              await f.rename(snapshotFile.path);
              AppLogger.repo.info(
                'Snapshot cleanup recovered tmp -> ${p.basename(snapshotFile.path)}',
              );
              // 保留 bak 作为旧备份，待下次备份轮转清理，不在此删除
              continue;
            } catch (_) {}
          }
          // snapshot 已存在或恢复失败，删除陈旧 tmp
          try {
            if (await f.exists()) await f.delete();
          } catch (_) {}
        } else if (name.endsWith('.bak')) {
          final baseName = name.substring(0, name.length - 4); // 去掉 .bak
          final snapshotFile = File(p.join(dir.path, baseName));
          if (await snapshotFile.exists()) {
            try {
              await f.delete();
            } catch (_) {}
          }
          // 若 snapshot 不存在则保留 bak，下次启动有机会经 tmp 恢复逻辑处理
        }
      }
    } catch (_) {}
  }

  static String _shortHash(String str) {
    // FNV-1a offset basis; safe on native (non-JS) targets.
    // ignore: avoid_js_rounded_ints
    var hash = 0xcbf29ce484222325;
    for (var i = 0; i < str.length; i++) {
      hash ^= str.codeUnitAt(i);
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0').substring(0, 8);
  }

  String _safePrefix(String canonicalId) {
    final safeId = canonicalId.replaceAll(RegExp('[^a-zA-Z0-9_-]'), '_');
    final hash = _shortHash(canonicalId);
    return '${safeId}_$hash';
  }

  String _safeFileName(String canonicalId, String difficultyKey) {
    final prefix = _safePrefix(canonicalId);
    final safeDiff = difficultyKey.replaceAll(RegExp('[^a-zA-Z0-9_-]'), '_');
    return '${prefix}__$safeDiff.snapshot';
  }

  File _fileFor(String canonicalId, String difficultyKey) {
    final dir =
        _snapshotsDir ??
        Directory(p.join(Directory.systemTemp.path, 'jigsaw_snapshots'));
    return File(p.join(dir.path, _safeFileName(canonicalId, difficultyKey)));
  }

  /// 供外部构造 canonicalId 时的辅助
  static String difficultyKeyFor(PuzzleDifficulty d) => '${d.rows}x${d.cols}';
  static String difficultyKeyForBoard(PuzzleBoardState s) =>
      s.effectiveDifficultyKey.isNotEmpty
      ? s.effectiveDifficultyKey
      : '${s.rows}x${s.cols}';

  Future<void> _ensureInit() async {
    if (!_initialized) await init();
  }

  /// 原子保存快照（带 .bak 备份回滚保护）
  Future<void> save(PuzzleBoardState state) async {
    await _ensureInit();
    final cid = state.effectiveCanonicalId;
    final dkey = state.effectiveDifficultyKey;
    if (cid.isEmpty || dkey.isEmpty) {
      AppLogger.repo.warning(
        'SnapshotStore.save skip empty cid/dkey cid=$cid dkey=$dkey',
      );
      return;
    }
    final file = _fileFor(cid, dkey);
    final toSave = state.copyWith(
      version: PuzzleBoardState.currentVersion,
      canonicalId: cid,
      difficultyKey: dkey,
      updatedAt: DateTime.now(),
      createdAt: state.createdAt ?? DateTime.now(),
    );
    final jsonStr = jsonEncode(toSave.toJson());
    final sw = Stopwatch()..start();
    final tmp = File('${file.path}.tmp');
    final bak = File('${file.path}.bak');
    try {
      await tmp.writeAsString(jsonStr, flush: true);
      // 原子重命名：若目标文件已存在，使用 .bak 保护防止 Windows 覆盖失败及零文件窗口
      if (await file.exists()) {
        try {
          if (await bak.exists()) await bak.delete();
          await file.rename(bak.path);
        } catch (_) {}
      }
      try {
        await tmp.rename(file.path);
        if (await bak.exists()) {
          try {
            await bak.delete();
          } catch (_) {}
        }
      } catch (e) {
        // 重命名失败，尝试恢复 .bak
        if (await bak.exists()) {
          try {
            await bak.rename(file.path);
          } catch (_) {}
        }
        rethrow;
      }

      // 方案 A：save 专注做单文件高效原子落盘，移出热路径全目录扫描（P1-6）
      AppLogger.repo.info(
        'SnapshotStore.save ok cid=$cid dkey=$dkey bytes=${jsonStr.length} ${sw.elapsedMilliseconds}ms file=${AppLogger.sanitizePath(file.path)}',
      );
    } catch (e, st) {
      AppLogger.repo.severe(
        'SnapshotStore.save failed cid=$cid dkey=$dkey',
        e,
        st,
      );
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// 同步保存（用于 dispose / lifecycle 同步兜底，避免 fire-and-forget 丢失）
  void saveSync(PuzzleBoardState state) {
    // P2-9：未初始化时直接返回。旧逻辑降级写入系统临时目录，与正式快照目录
    // 不一致，存档后续永远读不到（幽灵存档/首启强杀静默丢失）。丢弃比写错位置好。
    if (!_initialized || _snapshotsDir == null) {
      AppLogger.repo.warning(
        'SnapshotStore saveSync skipped: not initialized '
        'cid=${state.effectiveCanonicalId}',
      );
      return;
    }
    final targetDir = _snapshotsDir!;
    final cid = state.effectiveCanonicalId;
    final dkey = state.effectiveDifficultyKey;
    if (cid.isEmpty || dkey.isEmpty) return;
    final file = File(p.join(targetDir.path, _safeFileName(cid, dkey)));
    final toSave = state.copyWith(
      version: PuzzleBoardState.currentVersion,
      canonicalId: cid,
      difficultyKey: dkey,
      updatedAt: DateTime.now(),
      createdAt: state.createdAt ?? DateTime.now(),
    );
    final jsonStr = jsonEncode(toSave.toJson());
    final tmp = File('${file.path}.tmp');
    final bak = File('${file.path}.bak');
    try {
      tmp.writeAsStringSync(jsonStr, flush: true);
      if (file.existsSync()) {
        try {
          if (bak.existsSync()) bak.deleteSync();
          file.renameSync(bak.path);
        } catch (_) {}
      }
      try {
        tmp.renameSync(file.path);
        if (bak.existsSync()) {
          try {
            bak.deleteSync();
          } catch (_) {}
        }
      } catch (e) {
        if (bak.existsSync()) {
          try {
            bak.renameSync(file.path);
          } catch (_) {}
        }
        rethrow;
      }
      AppLogger.repo.info(
        'SnapshotStore.saveSync ok cid=$cid dkey=$dkey bytes=${jsonStr.length}',
      );
    } catch (e, st) {
      AppLogger.repo.warning(
        'SnapshotStore.saveSync failed cid=$cid dkey=$dkey',
        e,
        st,
      );
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
    }
  }

  /// 便利用 boardState + canonicalId 保存（自动补 canonicalId/difficultyKey）
  Future<void> saveFor(
    String canonicalId,
    PuzzleDifficulty difficulty,
    PuzzleBoardState state,
  ) async {
    final dkey = difficultyKeyFor(difficulty);
    final enriched = state.copyWith(
      canonicalId: canonicalId,
      difficultyKey: dkey,
    );
    await save(enriched);
  }

  /// 加载快照，损坏则删除并返回 null（P21 区分 IO 与格式错误）
  Future<PuzzleBoardState?> load(
    String canonicalId,
    String difficultyKey,
  ) async {
    await _ensureInit();
    final file = _fileFor(canonicalId, difficultyKey);
    if (!await file.exists()) return null;
    try {
      final str = await file.readAsString();
      final map = jsonDecode(str) as Map<String, dynamic>;
      final state = PuzzleBoardState.fromJson(map);
      AppLogger.repo.fine(
        'SnapshotStore.load hit cid=$canonicalId dkey=$difficultyKey pieces=${state.pieces.length} ver=${state.version}',
      );
      return state;
    } catch (e, st) {
      // 仅格式错误（JSON/结构损坏）才删文件；瞬时 IO（文件锁/杀毒扫描）保留
      final isFormat = e is FormatException || e is TypeError;
      if (isFormat) {
        AppLogger.repo.warning(
          'SnapshotStore.load corrupted delete cid=$canonicalId dkey=$difficultyKey',
          e,
          st,
        );
        try {
          await file.delete();
        } catch (_) {}
      } else {
        AppLogger.repo.warning(
          'SnapshotStore.load transient IO keep file cid=$canonicalId dkey=$difficultyKey',
          e,
          st,
        );
      }
      return null;
    }
  }

  Future<PuzzleBoardState?> loadForDifficulty(
    String canonicalId,
    PuzzleDifficulty d,
  ) => load(canonicalId, difficultyKeyFor(d));

  /// 直接以 JSON 字符串加载（用于 GamePage initialSnapshotJson 透传，消除重复编解码开销）
  Future<String?> loadJsonString(
    String canonicalId,
    String difficultyKey,
  ) async {
    await _ensureInit();
    final file = _fileFor(canonicalId, difficultyKey);
    if (!await file.exists()) return null;
    try {
      final str = await file.readAsString();
      final map = jsonDecode(str) as Map<String, dynamic>;
      PuzzleBoardState.fromJson(map); // 校验格式与完整性
      return str;
    } catch (e, st) {
      final isFormat = e is FormatException || e is TypeError;
      if (isFormat) {
        AppLogger.repo.warning(
          'SnapshotStore.loadJsonString corrupted delete cid=$canonicalId dkey=$difficultyKey',
          e,
          st,
        );
        try {
          await file.delete();
        } catch (_) {}
      } else {
        AppLogger.repo.warning(
          'SnapshotStore.loadJsonString transient IO keep cid=$canonicalId dkey=$difficultyKey',
          e,
          st,
        );
      }
      return null;
    }
  }

  Future<bool> hasSnapshot(String canonicalId, String difficultyKey) async {
    await _ensureInit();
    return _fileFor(canonicalId, difficultyKey).exists();
  }

  /// 异步非阻塞检查是否存在任意快照
  Future<bool> hasAnySnapshot(String canonicalId) async {
    await _ensureInit();
    final dir = _snapshotsDir;
    if (dir == null || !await dir.exists()) return false;
    final prefix = '${_safePrefix(canonicalId)}__';
    await for (final f in dir.list()) {
      if (f is File &&
          p.basename(f.path).startsWith(prefix) &&
          f.path.endsWith('.snapshot')) {
        return true;
      }
    }
    return false;
  }

  /// 异步非阻塞列出该关卡的所有难度 key
  Future<List<String>> listDifficultyKeys(String canonicalId) async {
    await _ensureInit();
    final dir = _snapshotsDir;
    if (dir == null || !await dir.exists()) return const [];
    final prefix = '${_safePrefix(canonicalId)}__';
    const suffix = '.snapshot';
    final keys = <String>[];
    await for (final f in dir.list()) {
      if (f is File) {
        final name = p.basename(f.path);
        if (name.startsWith(prefix) && name.endsWith(suffix)) {
          final inner = name.substring(
            prefix.length,
            name.length - suffix.length,
          );
          keys.add(inner);
        }
      }
    }
    return keys;
  }

  Future<void> delete(String canonicalId, String difficultyKey) async {
    await _ensureInit();
    final file = _fileFor(canonicalId, difficultyKey);
    try {
      if (await file.exists()) {
        await file.delete();
        AppLogger.repo.info(
          'SnapshotStore.delete cid=$canonicalId dkey=$difficultyKey',
        );
      }
    } catch (e, st) {
      AppLogger.repo.warning(
        'SnapshotStore.delete failed cid=$canonicalId dkey=$difficultyKey',
        e,
        st,
      );
    }
  }

  Future<void> deleteAllFor(String canonicalId) async {
    final keys = await listDifficultyKeys(canonicalId);
    for (final k in keys) {
      await delete(canonicalId, k);
    }
  }

  /// 清空所有快照与临时文件（用于 resetAllData）
  Future<void> clearAll() async {
    await _ensureInit();
    final dir = _snapshotsDir;
    if (dir == null || !await dir.exists()) return;
    try {
      await for (final f in dir.list()) {
        if (f is File) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
      AppLogger.repo.info('SnapshotStore.clearAll done');
    } catch (e, st) {
      AppLogger.repo.warning('SnapshotStore.clearAll failed', e, st);
    }
  }

  /// 计算进度百分比（用于轻量索引，避免全量解析也可）
  static int progressPercentOf(PuzzleBoardState s) {
    final total = s.totalPieces;
    if (total == 0) return 0;
    final solved = s.pieces.where((p) => p.isSolved(s.rows, s.cols)).length;
    return (solved * 100 ~/ total).clamp(0, 100);
  }
}
