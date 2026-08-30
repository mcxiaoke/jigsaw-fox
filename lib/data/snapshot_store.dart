import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../logic/models/puzzle_state.dart';
import '../logic/puzzle_model.dart';
import '../services/app_logger.dart';

/// 文件级快照存储（原子写、损坏自愈、gzip 透传、版本前瞻兼容）
///
/// 设计要点（见 docs/save-resume-continue-design-20260830.md）：
/// - 主键 `<canonicalId>::<difficultyKey>`，文件名为安全化后的 `<safeId>_<RxC>.snapshot`
/// - 原子写：`tmp -> rename`，避免半写损坏
/// - 读取时 `PuzzleBoardState.fromJson` 的 `extra` 透传保证前瞻兼容
/// - 未来可无痛切换到加密/云后端（实现 SnapshotBackend 即可）
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
      AppLogger.repo.info('SnapshotStore init dir=${AppLogger.sanitizePath(_snapshotsDir!.path)}');
    } catch (e, st) {
      AppLogger.repo.warning('SnapshotStore init failed', e, st);
      // 回退到临时目录（测试环境）
      _snapshotsDir = Directory(p.join(Directory.systemTemp.path, 'jigsaw_snapshots'));
      try {
        if (!await _snapshotsDir!.exists()) await _snapshotsDir!.create(recursive: true);
      } catch (_) {}
      _initialized = true;
    }
  }

  String _safeFileName(String canonicalId, String difficultyKey) {
    final safeId = canonicalId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final safeDiff = difficultyKey.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return '${safeId}__$safeDiff.snapshot';
  }

  File _fileFor(String canonicalId, String difficultyKey) {
    final dir = _snapshotsDir ?? Directory(p.join(Directory.systemTemp.path, 'jigsaw_snapshots'));
    return File(p.join(dir.path, _safeFileName(canonicalId, difficultyKey)));
  }

  /// 供外部构造 canonicalId 时的辅助
  static String difficultyKeyFor(PuzzleDifficulty d) => '${d.rows}x${d.cols}';
  static String difficultyKeyForBoard(PuzzleBoardState s) =>
      s.effectiveDifficultyKey.isNotEmpty ? s.effectiveDifficultyKey : '${s.rows}x${s.cols}';

  Future<void> _ensureInit() async {
    if (!_initialized) await init();
  }

  /// 原子保存快照
  Future<void> save(PuzzleBoardState state) async {
    await _ensureInit();
    final cid = state.effectiveCanonicalId;
    final dkey = state.effectiveDifficultyKey;
    if (cid.isEmpty || dkey.isEmpty) {
      AppLogger.repo.warning('SnapshotStore.save skip empty cid/dkey cid=$cid dkey=$dkey');
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
    try {
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonStr, flush: true);
      // 原子重命名
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }
      await tmp.rename(file.path);
      AppLogger.repo.info('SnapshotStore.save ok cid=$cid dkey=$dkey bytes=${jsonStr.length} ${sw.elapsedMilliseconds}ms file=${AppLogger.sanitizePath(file.path)}');
    } catch (e, st) {
      AppLogger.repo.severe('SnapshotStore.save failed cid=$cid dkey=$dkey', e, st);
      rethrow;
    }
  }

  /// 便利用 boardState + canonicalId 保存（自动补 canonicalId/difficultyKey）
  Future<void> saveFor(String canonicalId, PuzzleDifficulty difficulty, PuzzleBoardState state) async {
    final dkey = difficultyKeyFor(difficulty);
    final enriched = state.copyWith(
      canonicalId: canonicalId,
      difficultyKey: dkey,
    );
    await save(enriched);
  }

  /// 加载快照，损坏则删除并返回 null
  Future<PuzzleBoardState?> load(String canonicalId, String difficultyKey) async {
    await _ensureInit();
    final file = _fileFor(canonicalId, difficultyKey);
    if (!await file.exists()) return null;
    try {
      final str = await file.readAsString();
      final map = jsonDecode(str) as Map<String, dynamic>;
      final state = PuzzleBoardState.fromJson(map);
      AppLogger.repo.fine('SnapshotStore.load hit cid=$canonicalId dkey=$difficultyKey pieces=${state.pieces.length} ver=${state.version}');
      return state;
    } catch (e, st) {
      AppLogger.repo.warning('SnapshotStore.load corrupted delete cid=$canonicalId dkey=$difficultyKey', e, st);
      try {
        await file.delete();
      } catch (_) {}
      return null;
    }
  }

  Future<PuzzleBoardState?> loadForDifficulty(String canonicalId, PuzzleDifficulty d) =>
      load(canonicalId, difficultyKeyFor(d));

  /// 直接以 JSON 字符串加载（用于 GamePage initialSnapshotJson 透传）
  Future<String?> loadJsonString(String canonicalId, String difficultyKey) async {
    final s = await load(canonicalId, difficultyKey);
    if (s == null) return null;
    return jsonEncode(s.toJson());
  }

  Future<bool> hasSnapshot(String canonicalId, String difficultyKey) async {
    await _ensureInit();
    return _fileFor(canonicalId, difficultyKey).exists();
  }

  Future<bool> hasAnySnapshot(String canonicalId) async {
    await _ensureInit();
    final dir = _snapshotsDir;
    if (dir == null || !await dir.exists()) return false;
    final safeId = canonicalId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final files = dir.listSync().whereType<File>();
    for (final f in files) {
      if (p.basename(f.path).startsWith('${safeId}__')) return true;
    }
    return false;
  }

  Future<List<String>> listDifficultyKeys(String canonicalId) async {
    await _ensureInit();
    final dir = _snapshotsDir;
    if (dir == null || !await dir.exists()) return const [];
    final safeId = canonicalId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final prefix = '${safeId}__';
    final suffix = '.snapshot';
    final keys = <String>[];
    for (final f in dir.listSync().whereType<File>()) {
      final name = p.basename(f.path);
      if (name.startsWith(prefix) && name.endsWith(suffix)) {
        final inner = name.substring(prefix.length, name.length - suffix.length);
        // inner 为 safeDiff 如 10x10，恢复为原始 dkey（safe 转换可逆仅替换非字母数字）
        keys.add(inner.replaceAll('_', 'x').replaceAll('xx', 'x')); // 保守还原
        // 实际上我们存的就是 10x10 -> 10x10 safe 不变，直接用 inner
        // 修正：直接用 inner
        keys[keys.length - 1] = inner;
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
        AppLogger.repo.info('SnapshotStore.delete cid=$canonicalId dkey=$difficultyKey');
      }
    } catch (e, st) {
      AppLogger.repo.warning('SnapshotStore.delete failed cid=$canonicalId dkey=$difficultyKey', e, st);
    }
  }

  Future<void> deleteAllFor(String canonicalId) async {
    final keys = await listDifficultyKeys(canonicalId);
    for (final k in keys) {
      await delete(canonicalId, k);
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
