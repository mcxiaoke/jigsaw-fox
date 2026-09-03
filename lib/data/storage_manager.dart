import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/app_logger.dart';

/// 三个 box 的名称（版本后缀 -v1，见设计 §6.1）
const String kBoxProgress = 'game-progress-v1';
const String kBoxCollections = 'game-collections-v1';
const String kBoxState = 'app-state-v1';

/// 全部 box 名称（备份/清理遍历用）
const List<String> kAllBoxNames = [kBoxProgress, kBoxCollections, kBoxState];

/// 保留的最近备份份数
const int kMaxBackups = 5;

/// 损坏专用异常：safeOpenBox 检测到损坏时抛出，中断当前 open 尝试，
/// 由 StorageManager.openAll() 内部的恢复循环统一处理；
/// 对 main() 等调用方完全不可见（设计 §7.2）。
class BoxCorruptException implements Exception {
  BoxCorruptException(this.boxName);

  final String boxName;

  @override
  String toString() => 'BoxCorruptException: $boxName';
}

/// 异常类型优先的损坏判定（设计 §7.2 v4.6）。
///
/// 类型层级说明：`HiveError extends Error`，`FormatException implements Exception`、
/// `RangeError extends ArgumentError`，三者平级——只 catch HiveError 接不住后两者
/// （文件头损坏/字节截断会直接穿透闪退），故此处用通用 catch + 类型分流。
bool isCorruption(Object e) {
  if (e is FormatException) return true; // 文件头/帧格式不合法
  if (e is RangeError) return true; // 字节截断（binary_reader 'Not enough bytes'）
  if (e is HiveError) {
    final s = e.toString().toLowerCase();
    return s.contains('invalid file format') ||
        s.contains('crc') ||
        s.contains('corrupt') ||
        s.contains('truncated');
  }
  return false;
}

/// 安全开箱：只负责「检测」——区分损坏与瞬时 I/O 错误。
///
/// 损坏 → 抛 [BoxCorruptException] 上交 openAll 恢复循环；
/// 瞬时错误（磁盘满/锁冲突抛 FileSystemException）→ 重试一次，绝不删盘。
Future<Box<T>> safeOpenBox<T>(String name) async {
  if (Hive.isBoxOpen(name)) return Hive.box<T>(name);
  try {
    return await Hive.openBox<T>(name);
  } catch (e, st) {
    if (isCorruption(e)) {
      AppLogger.repo.severe('Box $name corrupted', e, st);
      throw BoxCorruptException(name);
    }
    AppLogger.repo.warning('Box $name open transient error, retry', e, st);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    try {
      return await Hive.openBox<T>(name);
    } catch (retryErr, retrySt) {
      if (isCorruption(retryErr)) {
        AppLogger.repo.severe('Box $name corrupted (retry)', retryErr, retrySt);
        throw BoxCorruptException(name);
      }
      rethrow; // 瞬时错误持续存在 → 由 main() 兜底，绝不静默清空
    }
  }
}

/// 对象型 box（progress / collections）统一写入：值统一为 JSON String，
/// 根除「未注册 TypeAdapter 的嵌套 Map 重启后退化成 Map[dynamic,dynamic]」崩溃
/// （设计 §3.2）。
Future<void> putJson(
  Box<dynamic> box,
  String key,
  Map<String, dynamic> value,
) => box.put(key, jsonEncode(value));

/// 与 [putJson] 配对的读取（jsonDecode 任何层级都返回 Map[String, dynamic]）。
Map<String, dynamic>? getJson(Box<dynamic> box, String key) {
  final raw = box.get(key) as String?;
  if (raw == null) return null;
  try {
    return jsonDecode(raw) as Map<String, dynamic>;
  } catch (e, st) {
    AppLogger.repo.warning('getJson decode fail key=$key', e, st);
    return null;
  }
}

String _millisStamp(DateTime t) {
  String pad(int v, int w) => v.toString().padLeft(w, '0');
  return '${pad(t.year, 4)}${pad(t.month, 2)}${pad(t.day, 2)}'
      '-${pad(t.hour, 2)}${pad(t.minute, 2)}${pad(t.second, 2)}'
      '-${pad(t.millisecond, 3)}';
}

String _randSuffix() => math.Random().nextInt(10000).toString().padLeft(4, '0');

/// 统一存储管理：3 个 box 的**唯一打开点**（设计 §7.1）。
///
/// 禁止各 Store 自由调用 open/delete，避免启动并发竞争与
/// 「一方捕获异常 deleteBox、另一方正在 open」的灾难场景。
/// 损坏检测 + 备份恢复 + 空库兜底全部内聚于 [openAll]，
/// 调用方（main.dart）永不接触 [BoxCorruptException]。
class StorageManager {
  // v4.3：非 final，测试可 setMockInstance 替换
  static StorageManager instance = StorageManager._();

  @visibleForTesting
  static void setMockInstance(StorageManager mock) => instance = mock;

  Box<dynamic>? progressBox;
  Box<dynamic>? collectionsBox;
  Box<dynamic>? stateBox;

  String? _homePathOverride; // forTest 注入；生产恒 null
  // 目录覆盖（测试用）。与 _homePathOverride 分离，使「临时目录 + 备份开启」
  // 的组合可测（forTestWithBackups）：isTestInstance 只看 _homePathOverride。
  Directory? _dirOverride;
  bool _hiveReady = false;
  // 本次 openAll 期间被兜底重建过的 box 名（备份点 A 守卫用）
  final Set<String> _recreatedBoxes = <String>{};
  // 兜底重建次数按 box 计数（防御极端 IO 故障下的死循环）
  final Set<String> _fallbackDone = <String>{};
  Future<void>? _backupLock;

  Directory? _hiveDirCache;
  Directory? _backupsRootCache;
  Directory? _appSupport;

  StorageManager._();

  /// 测试专用构造：注入临时目录并完成 Hive.init，
  /// 绕过 getApplicationSupportDirectory()（其在 flutter test 下抛 MissingPluginException）
  @visibleForTesting
  StorageManager.forTest(String homePath) {
    _homePathOverride = homePath;
    _dirOverride = Directory(homePath);
    Hive.init(homePath);
    _hiveReady = true;
  }

  /// 测试专用构造（备份开启版）：目录注入到临时路径，但 `isTestInstance` 为 false，
  /// 因此 §7.8 的备份/恢复逻辑会真实执行——用于备份与两阶段恢复的用例回归。
  @visibleForTesting
  StorageManager.forTestWithBackups(String homePath) {
    _dirOverride = Directory(homePath);
    Hive.init(homePath);
    _hiveReady = true;
  }

  /// 测试实例判定：本 Flutter SDK foundation 无 kTestMode，
  /// 据此关闭备份（§7.8 备份点 A/B），不引入不存在的 API。
  bool get isTestInstance => _homePathOverride != null;

  /// 测试 tearDown 物理删除临时目录用（覆盖 forTest / forTestWithBackups 两种实例）
  @visibleForTesting
  String? get homePathForTest => _homePathOverride ?? _dirOverride?.path;

  /// 强类型非空 getter：业务侧禁止散布 `!`，未 open 即访问直接 fail-fast
  Box<dynamic> get progress =>
      progressBox ??
      (throw StateError('StorageManager.openAll() must be called first'));
  Box<dynamic> get collections =>
      collectionsBox ??
      (throw StateError('StorageManager.openAll() must be called first'));
  Box<dynamic> get state =>
      stateBox ??
      (throw StateError('StorageManager.openAll() must be called first'));

  /// 本次 openAll 是否发生过兜底重建（供备份点 A 守卫读取）
  bool get hasRecreatedBoxes => _recreatedBoxes.isNotEmpty;

  // --- 目录解析 ---

  Future<Directory> _hiveDirectory() async {
    final cached = _hiveDirCache;
    if (cached != null) return cached;
    final base = _dirOverride;
    final Directory dir;
    if (base != null) {
      dir = base; // 测试：home 目录本身即 hive 数据目录
    } else {
      final support = _appSupport ??= await getApplicationSupportDirectory();
      dir = Directory(p.join(support.path, 'hive_data'));
    }
    if (!await dir.exists()) await dir.create(recursive: true);
    _hiveDirCache = dir;
    return dir;
  }

  Future<Directory> _backupsRoot() async {
    final cached = _backupsRootCache;
    if (cached != null) return cached;
    final base = _dirOverride;
    final Directory dir;
    if (base != null) {
      dir = Directory(p.join(base.path, 'hive_backups'));
    } else {
      final support = _appSupport ??= await getApplicationSupportDirectory();
      dir = Directory(p.join(support.path, 'hive_backups'));
    }
    _backupsRootCache = dir;
    return dir;
  }

  /// 生产端显式指定 {appSupport}/hive_data。
  ///
  /// 不用 Hive.initFlutter()：hive_ce_flutter 的 initFlutter 用
  /// getApplicationDocumentsDirectory()（文档目录），不传 subDir 时 box 直接散落
  /// {appDoc} 根目录，与 §7.8 的 {appSupport}/hive_data/ 约定矛盾；
  /// 本工程只存 int/bool/String/JSON String，也不需要它注册的 Color/TimeOfDay
  /// 适配器。
  Future<void> _ensureHiveInit() async {
    if (_hiveReady) return;
    final hiveDir = await _hiveDirectory();
    Hive.init(hiveDir.path);
    _hiveReady = true;
  }

  /// 唯一公开入口：损坏检测 + 备份恢复 + 空库兜底全部内聚于此（设计 §7.1）。
  Future<void> openAll() async {
    await _ensureHiveInit();
    const maxBackupTries = 2;
    // 按 box 独立计数：双 box 同时损坏时，第二个 box 首次损坏即被传入
    // tryIndex:1 跳过最新备份，若本地仅 1 份备份会误判「无备份」直接兜底删库。
    final restoreTriesPerBox = <String, int>{};
    _recreatedBoxes.clear();
    _fallbackDone.clear();
    while (true) {
      try {
        progressBox = await safeOpenBox<dynamic>(kBoxProgress);
        collectionsBox = await safeOpenBox<dynamic>(kBoxCollections);
        stateBox = await safeOpenBox<dynamic>(kBoxState);
        return; // 3 个全部打开成功
      } on BoxCorruptException catch (e, st) {
        AppLogger.repo.severe('Corrupt box detected: ${e.boxName}', e, st);
        // 1. 关闭所有已打开 box（含健康 box），释放 .hive/.lock 句柄
        await closeAll();
        _clearBoxRefs();
        // 2. 先判后做：超限直接兜底，不再多复制一份即丢弃（v4.5 off-by-one 修复）
        final boxTries = restoreTriesPerBox[e.boxName] ?? 0;
        if (boxTries >= maxBackupTries) {
          await _fallbackRecreate(e.boxName);
          continue;
        }
        await _quarantineBox(e.boxName); // 幂等：文件不存在则跳过
        final restored = await _restoreBoxFile(e.boxName, tryIndex: boxTries);
        restoreTriesPerBox[e.boxName] = boxTries + 1;
        if (restored) continue; // 还原成功 → 回到循环顶部重新打开 3 个 box
        // 3. 还原失败（无该 box 备份 / 复制异常）→ 兜底（不再二次改名）
        await _fallbackRecreate(e.boxName);
        // 循环继续：重建后的空 box 必然能打开；若另一 box 也损坏，同流程再走一遍
      }
    }
  }

  /// 兜底重建：登记 _recreatedBoxes（触发 §7.8 备份点 A 一次性守卫）。
  /// 不自行 openBox——回到 while 顶部由 safeOpenBox 天然创建干净空 box；
  /// 也不重复改名留证（_quarantineBox 已幂等完成）。
  Future<void> _fallbackRecreate(String boxName) async {
    AppLogger.repo.severe('Fallback: recreating empty box $boxName');
    _recreatedBoxes.add(boxName);
    // 防御：同一 box 二次兜底说明磁盘存在持续故障，上抛交 main() 兜底，绝不死循环
    if (!_fallbackDone.add(boxName)) {
      throw StateError(
        'StorageManager: box $boxName still corrupt after recreate, aborting',
      );
    }
    try {
      await Hive.deleteBoxFromDisk(boxName); // 内部会 close + 删 .hive/.lock
    } catch (e, st) {
      AppLogger.repo.severe('deleteBoxFromDisk failed for $boxName', e, st);
      rethrow;
    }
  }

  /// 留证隔离（幂等）：{box}.hive 改名 .corrupt-{ts}，
  /// 并删除残留的 {box}.lock（Hive 异常路径可能遗留，Windows 下引发锁冲突）。
  /// 不做还原、不重建（v4.6 单一职责）。
  Future<void> _quarantineBox(String boxName) async {
    final hiveDir = await _hiveDirectory();
    final hiveFile = File(p.join(hiveDir.path, '$boxName.hive'));
    if (await hiveFile.exists()) {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final corruptFile = File('${hiveFile.path}.corrupt-$ts');
      for (var i = 0; i < 3; i++) {
        try {
          await hiveFile.rename(corruptFile.path);
          break;
        } catch (e, st) {
          if (i == 2) {
            // 3 次重试仍失败：仅记录，不阻断——后续 _restoreBoxFile 的 copy
            // 会覆盖目标文件，仍有机会还原成功
            AppLogger.repo.warning(
              'quarantine rename failed for $boxName',
              e,
              st,
            );
          } else {
            // 消化 Windows 下 Hive backend 句柄异步关闭的 sharing violation
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
      }
    }
    final lockFile = File(p.join(hiveDir.path, '$boxName.lock'));
    if (await lockFile.exists()) {
      try {
        await lockFile.delete();
      } catch (_) {}
    }
  }

  /// 仅负责复制：从 hive_backups 第 tryIndex 新的 backup-*/ 把 {box}.hive
  /// 复制回 hive_data/。无可用备份 / 复制异常返回 false。不改名、不删源。
  Future<bool> _restoreBoxFile(String boxName, {required int tryIndex}) async {
    try {
      final backupsRoot = await _backupsRoot();
      if (!await backupsRoot.exists()) return false;
      final dirs =
          (await backupsRoot.list().toList())
              .whereType<Directory>()
              .where((d) => p.basename(d.path).startsWith('backup-'))
              .toList()
            // 倒序：最新在前（时间戳定宽，字典序即时间序）
            ..sort((a, b) => b.path.compareTo(a.path));
      if (tryIndex >= dirs.length) return false;
      final src = File(p.join(dirs[tryIndex].path, '$boxName.hive'));
      if (!await src.exists()) return false;
      final hiveDir = await _hiveDirectory();
      await src.copy(p.join(hiveDir.path, '$boxName.hive'));
      AppLogger.repo.warning(
        'Restored $boxName from backup ${p.basename(dirs[tryIndex].path)}',
      );
      return true;
    } catch (e, st) {
      AppLogger.repo.warning('restoreBoxFile failed for $boxName', e, st);
      return false;
    }
  }

  /// 终极兜底入口（main() 使用）：磁盘持续故障时以**内存 box** 启动，
  /// 保证 UI 可用（默认数据），**绝不删盘、绝不静默清空用户数据**（设计 §7.2）。
  ///
  /// [openAll] 抛出的都是「重试后仍失败」的持续 IO 故障（磁盘满/权限/锁），
  /// 此时若直接崩溃用户什么都做不了；内存 box 让本会话仍可游玩，
  /// 磁盘上的原数据原封不动保留，下次启动继续尝试恢复。
  Future<void> openAllWithMemoryFallback() async {
    try {
      await openAll();
    } catch (e, st) {
      AppLogger.repo.severe(
        'StorageManager.openAll failed, falling back to in-memory boxes',
        e,
        st,
      );
      try {
        _clearBoxRefs();
        progressBox = await Hive.openBox<dynamic>(
          kBoxProgress,
          bytes: Uint8List(0),
        );
        collectionsBox = await Hive.openBox<dynamic>(
          kBoxCollections,
          bytes: Uint8List(0),
        );
        stateBox = await Hive.openBox<dynamic>(kBoxState, bytes: Uint8List(0));
      } catch (e2, st2) {
        AppLogger.repo.severe('in-memory fallback failed', e2, st2);
        rethrow;
      }
    }
  }

  void _clearBoxRefs() {
    progressBox = null;
    collectionsBox = null;
    stateBox = null;
  }

  /// 逐 box try/catch 刷盘：一个 box flush 失败不阻断其余
  Future<void> flushPendingWrites() async {
    final boxes = [
      progressBox,
      collectionsBox,
      stateBox,
    ].whereType<Box<dynamic>>().toList();
    await Future.wait(
      boxes.map((b) async {
        try {
          await b.flush();
        } catch (e, st) {
          AppLogger.repo.warning('Box ${b.name} flush failed', e, st);
        }
      }),
    );
  }

  /// 测试专用：置空 3 个 box 引用与初始化标志，避免单例状态跨测试串留
  @visibleForTesting
  void resetForTest() {
    _clearBoxRefs();
    _hiveReady = false;
    _homePathOverride = null;
    _dirOverride = null;
    _recreatedBoxes.clear();
    _fallbackDone.clear();
    _hiveDirCache = null;
    _backupsRootCache = null;
    _appSupport = null;
    _backupLock = null;
  }

  /// hive_ce 的 Hive.close() **不 flush**——storage_backend_vm._closeInternal
  /// 只 close 三个 RAF 并删 lock 文件，全程无 writeRaf.flush()。
  /// close 前必须先 flushPendingWrites()，否则 Dart RandomAccessFile
  /// 缓冲中的尾部写入直接丢失。
  Future<void> closeAll() async {
    await flushPendingWrites();
    await Hive.close();
  }

  // --- 备份（设计 §7.8） ---

  /// 链式互斥锁：串行化桌面端 onHide/onInactive/onExitRequested 的并发触发，
  /// 防止边复制边写撕裂与同秒目录冲突。
  Future<void> backupNow() {
    final prev = _backupLock ?? Future<void>.value();
    // catchError 防止一次失败「毒化」整条链
    final next = prev.catchError((Object _) {}).then((_) => _doBackup());
    _backupLock = next;
    return next;
  }

  /// 原子目录备份（.tmp + 单次 rename，只复制 .hive）。
  /// isTestInstance 直接 return。写失败静默降级，不阻塞启动。
  Future<void> _doBackup() async {
    if (isTestInstance) return;
    try {
      final hiveDir = await _hiveDirectory();
      final backupsRoot = await _backupsRoot();
      if (!await backupsRoot.exists()) {
        await backupsRoot.create(recursive: true);
      }
      final ts = _millisStamp(DateTime.now());
      var tmpDir = Directory(p.join(backupsRoot.path, '.backup-$ts.tmp'));
      if (await tmpDir.exists()) {
        tmpDir = Directory('${tmpDir.path}-${_randSuffix()}');
      }
      await tmpDir.create(recursive: true);
      for (final name in kAllBoxNames) {
        final src = File(p.join(hiveDir.path, '$name.hive'));
        // 仅复制 .hive 且跳过空文件（空 box 的 .hive 仅文件头数十字节）
        if (await src.exists() && await src.length() > 0) {
          await src.copy(p.join(tmpDir.path, '$name.hive'));
        }
      }
      var dst = Directory(p.join(backupsRoot.path, 'backup-$ts'));
      if (await dst.exists()) {
        dst = Directory('${dst.path}-${_randSuffix()}');
      }
      // 单次 rename 原子落位：复制中途被强杀只留 .tmp 残骸，不会被恢复扫描认领
      await tmpDir.rename(dst.path);
      await _cleanupTempBackupDirs(backupsRoot);
      await _retainRecentBackups(backupsRoot);
      AppLogger.repo.info('Hive backup created ${p.basename(dst.path)}');
    } catch (e, st) {
      AppLogger.repo.warning('Hive backup failed', e, st);
    }
  }

  /// 清理历史残留的 .backup-*.tmp/ 目录
  Future<void> _cleanupTempBackupDirs(Directory root) async {
    try {
      final entries = await root.list().toList();
      for (final e in entries) {
        if (e is! Directory) continue;
        final name = p.basename(e.path);
        if (name.startsWith('.backup-') && name.endsWith('.tmp')) {
          try {
            await e.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// 仅保留最近 [kMaxBackups] 份备份，超出删最旧
  Future<void> _retainRecentBackups(Directory root) async {
    try {
      final all =
          (await root.list().toList())
              .whereType<Directory>()
              .where((d) => p.basename(d.path).startsWith('backup-'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      for (var i = 0; i < all.length - kMaxBackups; i++) {
        try {
          await all[i].delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }
}
