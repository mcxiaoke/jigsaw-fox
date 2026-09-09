import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/cache/image_cache_manager.dart';

/// 验证 L2 磁盘缓存的容量上限与 LRU 淘汰行为。
///
/// 通过 [ImageCacheManager.setDiskCacheLimitForTest] 下调上限，
/// 避免为触发淘汰而真实写入 500MB 数据。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory testTempDir;

  Future<Directory> prepareCacheDir() async {
    testTempDir = await Directory.systemTemp.createTemp('lru_evict_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
      return testTempDir.path;
    });
    final dir = Directory('${testTempDir.path}/thumbnail_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> writeThumb(
    Directory dir,
    String name,
    int size,
    DateTime modified,
  ) async {
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(List<int>.filled(size, 7));
    await file.setLastModified(modified);
  }

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    try {
      if (await testTempDir.exists()) {
        await testTempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  test('LRU eviction trims disk cache to limit, oldest first', () async {
    final dir = await prepareCacheDir();
    final base = DateTime(2026, 1, 1);

    // 5 个 1000 字节的缩略图，修改时间递增（_0 最旧、_4 最新）
    for (var i = 0; i < 5; i++) {
      await writeThumb(
        dir,
        'thumb_test_${i}_360.jpg',
        1000,
        base.add(Duration(hours: i)),
      );
    }

    final mgr = ImageCacheManager.instance;
    // 初始 5000B，上限 2500B → 应回落到 90% 水位 2250B
    mgr.diskCacheLimitForTest = 2500;
    await mgr.init();

    // 1. 总量已回落到水位内
    expect(mgr.diskCacheBytesForTest, lessThanOrEqualTo(2250));
    expect(mgr.diskCacheBytesForTest, greaterThan(0));

    // 2. 最旧的三个被淘汰（5000→2000 才落入 2250 水位），最新的保留
    //    即淘汰顺序严格按修改时间升序，LRU 语义正确
    expect(await File('${dir.path}/thumb_test_0_360.jpg').exists(), isFalse);
    expect(await File('${dir.path}/thumb_test_1_360.jpg').exists(), isFalse);
    expect(await File('${dir.path}/thumb_test_2_360.jpg').exists(), isFalse);
    expect(await File('${dir.path}/thumb_test_3_360.jpg').exists(), isTrue);
    expect(await File('${dir.path}/thumb_test_4_360.jpg').exists(), isTrue);

    // 3. 磁盘上仅剩 2 个文件，且计数与磁盘一致
    final remaining = await dir.list().where((e) => e is File).length;
    expect(remaining, 2);
    expect(mgr.diskCacheBytesForTest, 2000);

    // 4. 清空缓存后计数必须归零：否则计数虚高会让后续每次写入
    //    都触发一次删不到任何文件的全目录扫描，且无法自愈
    await mgr.clearCache();
    expect(mgr.diskCacheBytesForTest, 0);
    expect(await dir.list().where((e) => e is File).length, 0);
  });
}
