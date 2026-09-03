import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jigsawpuzzle/data/favorite_store.dart';
import 'package:jigsawpuzzle/data/progress_store.dart';
import 'package:jigsawpuzzle/data/storage_manager.dart';
import 'package:jigsawpuzzle/logic/download_manager.dart';

/// 每个测试独立目录 + mock 单例（设计 §10.2）。
///
/// `flutter test` 的并发是 isolate 级隔离，真实风险是同一测试文件内
/// 多个 test() 共享同一 isolate 的全局单例——前者 Hive.init 被后者的目录
/// 覆盖、Hive.deleteFromDisk() 误删他测数据。故每个测试必须拥有独立数据目录
/// 与独立 box 实例。
Future<StorageManager> initTestStorage() async {
  final dir = await Directory.systemTemp.createTemp('jigsaw_test_');
  final sm = StorageManager.forTest(dir.path); // 已 Hive.init，不会再触
  // getApplicationSupportDirectory()
  StorageManager.setMockInstance(sm);
  await sm.openAll();
  return sm;
}

/// 备份开启版（用于 §7.8 备份/恢复用例）：目录仍为临时目录，
/// 但 [StorageManager.isTestInstance] 为 false，备份逻辑会真实执行。
Future<StorageManager> initTestStorageWithBackups() async {
  final dir = await Directory.systemTemp.createTemp('jigsaw_test_bk_');
  final sm = StorageManager.forTestWithBackups(dir.path);
  StorageManager.setMockInstance(sm);
  await sm.openAll();
  return sm;
}

/// 组合基建：临时 Hive 存储 + 业务单例内存重置（等价「应用冷启动空库」）。
///
/// 供原来只靠 `SharedPreferences.setMockInitialValues({})` 隔离的测试迁移使用：
/// box 为空、各 Store 内存缓存清零，随后再调 `GameRepository.instance.init()`
/// 即可重建与全新启动一致的内存态。
Future<StorageManager> initTestAppStorage() async {
  SharedPreferences.setMockInitialValues({});
  final sm = await initTestStorage();
  await ProgressStore.instance.reset(); // 清内存索引（box 为空，等价全新 init）
  await FavoriteStore.instance.reset(); // 清 _entriesCache + _initialized
  await DownloadManager.instance.reset(); // 清 itemsNotifier + _initialized
  return sm;
}

/// 与 [initTestStorage] / [initTestStorageWithBackups] 配对的清理：
/// 删除 box、物理删除临时目录、重置单例引用
Future<void> tearDownTestStorage(StorageManager sm) async {
  await Hive.deleteFromDisk(); // 关闭并删除当前所有打开的 box（须在 close 之前调，
  // close 后再调是 no-op）
  // 物理删除临时目录：若测试内验证过 closeAll()（如往返测试），
  // _boxes 已空、deleteFromDisk 是 no-op，不删目录会永久滞留系统临时文件夹
  final home = sm.homePathForTest;
  if (home != null) {
    final dir = Directory(home);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {} // best-effort
  }
  sm.resetForTest(); // 置空引用 + _hiveReady=false + 清 _homePathOverride
}
