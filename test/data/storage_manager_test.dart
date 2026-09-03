import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:path/path.dart' as p;

import 'package:jigsawpuzzle/data/storage_manager.dart';

import '../test_helper.dart';

/// 与 hive_ce 内部 Crc32 完全一致的实现（src/crypto/crc32.dart），
/// 用于构造「CRC 合法但内容非法」的损坏帧。
int _crc32(Uint8List bytes, {int crc = 0, int offset = 0, int? length}) {
  crc = crc ^ 0xffffffff;
  length ??= bytes.length;
  for (var i = offset; i < offset + length; i++) {
    crc = _crcTable[(crc ^ bytes[i]) & 0xff] ^ (crc >> 8);
  }
  return crc ^ 0xffffffff;
}

const _crcTable = <int>[
  0x00000000,
  0x77073096,
  0xee0e612c,
  0x990951ba,
  0x076dc419,
  0x706af48f,
  0xe963a535,
  0x9e6495a3,
  0x0edb8832,
  0x79dcb8a4,
  0xe0d5e91e,
  0x97d2d988,
  0x09b64c2b,
  0x7eb17cbd,
  0xe7b82d07,
  0x90bf1d91,
  0x1db71064,
  0x6ab020f2,
  0xf3b97148,
  0x84be41de,
  0x1adad47d,
  0x6ddde4eb,
  0xf4d4b551,
  0x83d385c7,
  0x136c9856,
  0x646ba8c0,
  0xfd62f97a,
  0x8a65c9ec,
  0x14015c4f,
  0x63066cd9,
  0xfa0f3d63,
  0x8d080df5,
  0x3b6e20c8,
  0x4c69105e,
  0xd56041e4,
  0xa2677172,
  0x3c03e4d1,
  0x4b04d447,
  0xd20d85fd,
  0xa50ab56b,
  0x35b5a8fa,
  0x42b2986c,
  0xdbbbc9d6,
  0xacbcf940,
  0x32d86ce3,
  0x45df5c75,
  0xdcd60dcf,
  0xabd13d59,
  0x26d930ac,
  0x51de003a,
  0xc8d75180,
  0xbfd06116,
  0x21b4f4b5,
  0x56b3c423,
  0xcfba9599,
  0xb8bda50f,
  0x2802b89e,
  0x5f058808,
  0xc60cd9b2,
  0xb10be924,
  0x2f6f7c87,
  0x58684c11,
  0xc1611dab,
  0xb6662d3d,
  0x76dc4190,
  0x01db7106,
  0x98d220bc,
  0xefd5102a,
  0x71b18589,
  0x06b6b51f,
  0x9fbfe4a5,
  0xe8b8d433,
  0x7807c9a2,
  0x0f00f934,
  0x9609a88e,
  0xe10e9818,
  0x7f6a0dbb,
  0x086d3d2d,
  0x91646c97,
  0xe6635c01,
  0x6b6b51f4,
  0x1c6c6162,
  0x856530d8,
  0xf262004e,
  0x6c0695ed,
  0x1b01a57b,
  0x8208f4c1,
  0xf50fc457,
  0x65b0d9c6,
  0x12b7e950,
  0x8bbeb8ea,
  0xfcb9887c,
  0x62dd1ddf,
  0x15da2d49,
  0x8cd37cf3,
  0xfbd44c65,
  0x4db26158,
  0x3ab551ce,
  0xa3bc0074,
  0xd4bb30e2,
  0x4adfa541,
  0x3dd895d7,
  0xa4d1c46d,
  0xd3d6f4fb,
  0x4369e96a,
  0x346ed9fc,
  0xad678846,
  0xda60b8d0,
  0x44042d73,
  0x33031de5,
  0xaa0a4c5f,
  0xdd0d7cc9,
  0x5005713c,
  0x270241aa,
  0xbe0b1010,
  0xc90c2086,
  0x5768b525,
  0x206f85b3,
  0xb966d409,
  0xce61e49f,
  0x5edef90e,
  0x29d9c998,
  0xb0d09822,
  0xc7d7a8b4,
  0x59b33d17,
  0x2eb40d81,
  0xb7bd5c3b,
  0xc0ba6cad,
  0xedb88320,
  0x9abfb3b6,
  0x03b6e20c,
  0x74b1d29a,
  0xead54739,
  0x9dd277af,
  0x04db2615,
  0x73dc1683,
  0xe3630b12,
  0x94643b84,
  0x0d6d6a3e,
  0x7a6a5aa8,
  0xe40ecf0b,
  0x9309ff9d,
  0x0a00ae27,
  0x7d079eb1,
  0xf00f9344,
  0x8708a3d2,
  0x1e01f268,
  0x6906c2fe,
  0xf762575d,
  0x806567cb,
  0x196c3671,
  0x6e6b06e7,
  0xfed41b76,
  0x89d32be0,
  0x10da7a5a,
  0x67dd4acc,
  0xf9b9df6f,
  0x8ebeeff9,
  0x17b7be43,
  0x60b08ed5,
  0xd6d6a3e8,
  0xa1d1937e,
  0x38d8c2c4,
  0x4fdff252,
  0xd1bb67f1,
  0xa6bc5767,
  0x3fb506dd,
  0x48b2364b,
  0xd80d2bda,
  0xaf0a1b4c,
  0x36034af6,
  0x41047a60,
  0xdf60efc3,
  0xa867df55,
  0x316e8eef,
  0x4669be79,
  0xcb61b38c,
  0xbc66831a,
  0x256fd2a0,
  0x5268e236,
  0xcc0c7795,
  0xbb0b4703,
  0x220216b9,
  0x5505262f,
  0xc5ba3bbe,
  0xb2bd0b28,
  0x2bb45a92,
  0x5cb36a04,
  0xc2d7ffa7,
  0xb5d0cf31,
  0x2cd99e8b,
  0x5bdeae1d,
  0x9b64c2b0,
  0xec63f226,
  0x756aa39c,
  0x026d930a,
  0x9c0906a9,
  0xeb0e363f,
  0x72076785,
  0x05005713,
  0x95bf4a82,
  0xe2b87a14,
  0x7bb12bae,
  0x0cb61b38,
  0x92d28e9b,
  0xe5d5be0d,
  0x7cdcefb7,
  0x0bdbdf21,
  0x86d3d2d4,
  0xf1d4e242,
  0x68ddb3f8,
  0x1fda836e,
  0x81be16cd,
  0xf6b9265b,
  0x6fb077e1,
  0x18b74777,
  0x88085ae6,
  0xff0f6a70,
  0x66063bca,
  0x11010b5c,
  0x8f659eff,
  0xf862ae69,
  0x616bffd3,
  0x166ccf45,
  0xa00ae278,
  0xd70dd2ee,
  0x4e048354,
  0x3903b3c2,
  0xa7672661,
  0xd06016f7,
  0x4969474d,
  0x3e6e77db,
  0xaed16a4a,
  0xd9d65adc,
  0x40df0b66,
  0x37d83bf0,
  0xa9bcae53,
  0xdebb9ec5,
  0x47b2cf7f,
  0x30b5ffe9,
  0xbdbdf21c,
  0xcabac28a,
  0x53b39330,
  0x24b4a3a6,
  0xbad03605,
  0xcdd70693,
  0x54de5729,
  0x23d967bf,
  0xb3667a2e,
  0xc4614ab8,
  0x5d681b02,
  0x2a6f2b94,
  0xb40bbe37,
  0xc30c8ea1,
  0x5a05df1b,
  0x2d02ef8d,
];

/// 构造一个**真正的损坏** .hive 文件：
/// 帧 CRC 完全合法（因此 crashRecovery 的「尾部半写帧」静默截断救不回来），
/// 但 keyType 字节非法（0xFF，合法值仅 0/1）→ 读取时抛
/// HiveError('Unsupported key type. Frame might be corrupted.')，
/// 该异常会被 [isCorruption] 判定为损坏（设计 §7.2 / §7.8）。
Uint8List buildCorruptHiveFile() {
  const frameLength = 12;
  final bytes = Uint8List(frameLength);
  // frameLength（uint32 小端）
  bytes[0] = frameLength;
  bytes[1] = 0;
  bytes[2] = 0;
  bytes[3] = 0;
  // 非法 keyType（合法值为 uintT=0 / utf8StringT=1）
  bytes[4] = 0xFF;
  bytes[5] = 0;
  bytes[6] = 0;
  bytes[7] = 0;
  // CRC 覆盖 [0, frameLength - 4)，即长度字段 + key + value
  final crc = _crc32(bytes, offset: 0, length: frameLength - 4);
  bytes[8] = crc & 0xff;
  bytes[9] = (crc >> 8) & 0xff;
  bytes[10] = (crc >> 16) & 0xff;
  bytes[11] = (crc >> 24) & 0xff;
  return bytes;
}

/// 写入损坏文件前必须先 closeAll，否则 Windows 下 box 持有写句柄会
/// ERROR_SHARING_VIOLATION
Future<void> corruptBox(StorageManager sm, String boxName) async {
  await sm.closeAll();
  await File(
    p.join(sm.homePathForTest!, '$boxName.hive'),
  ).writeAsBytes(buildCorruptHiveFile());
}

void main() {
  late StorageManager sm;

  tearDown(() async {
    await tearDownTestStorage(sm);
  });

  group('空数据初始化', () {
    test('3 个 box 可正常打开且为空', () async {
      sm = await initTestStorage();
      expect(sm.progress.name, kBoxProgress);
      expect(sm.collections.name, kBoxCollections);
      expect(sm.state.name, kBoxState);
      expect(sm.progress.isEmpty, isTrue);
      expect(sm.collections.isEmpty, isTrue);
      expect(sm.state.isEmpty, isTrue);
    });

    test('未 openAll 时非空 getter 抛 StateError（违规防护）', () async {
      final dir = await Directory.systemTemp.createTemp('jigsaw_guard_');
      sm = StorageManager.forTest(dir.path);
      StorageManager.setMockInstance(sm);
      expect(sm.isTestInstance, isTrue);
      expect(() => sm.progress, throwsA(isA<StateError>()));
      expect(() => sm.collections, throwsA(isA<StateError>()));
      expect(() => sm.state, throwsA(isA<StateError>()));
    });
  });

  group('往返（重启后不退化）', () {
    test('JSON String 对象值 close→重开后字段完整', () async {
      sm = await initTestStorage();
      await putJson(sm.progress, 'main:001', {
        'canonicalId': 'main:001',
        'records': {
          '5x5': {
            'bestStars': 3,
            'bestTimeSeconds': 42,
            'isCompleted': true,
            'playCount': 2,
            'minHintsUsed': 0,
          },
        },
        'completedPieceCounts': [25],
      });
      await sm.progress.flush();

      // 模拟重启：关闭全部 box 后重新 openBox
      await sm.closeAll();
      final reopened = await Hive.openBox<dynamic>(kBoxProgress);
      final back = getJson(reopened, 'main:001');
      expect(back, isNotNull);
      expect(back!['canonicalId'], 'main:001');
      // 关键点：嵌套 Map 未被退化为 Map<dynamic, dynamic> 导致 as 强转崩溃
      final records = back['records'] as Map<String, dynamic>;
      final r = records['5x5'] as Map<String, dynamic>;
      expect(r['bestStars'], 3);
      expect(r['minHintsUsed'], 0);
      expect(back['completedPieceCounts'], [25]);
    });

    test('app-state 原生类型重启后原样读出（无 JSON 包装）', () async {
      sm = await initTestStorage();
      await sm.state.put('econ:coins', 100);
      await sm.state.put('econ:starterGranted', true);
      await sm.state.put('ach:unlock:first_win', '2026-09-02T10:00:00.000');
      await sm.state.put('ach:claimed:ach_a', true);
      await sm.state.put('ach:counter:totalWins', 7);
      await sm.state.put('stat:totalPiecesSnapped', 999);
      await sm.state.flush();

      await sm.closeAll();
      final reopened = await Hive.openBox<dynamic>(kBoxState);
      expect(reopened.get('econ:coins'), isA<int>());
      expect(reopened.get('econ:coins'), 100);
      expect(reopened.get('econ:starterGranted'), isA<bool>());
      expect(reopened.get('econ:starterGranted'), true);
      expect(reopened.get('ach:unlock:first_win'), '2026-09-02T10:00:00.000');
      expect(reopened.get('ach:claimed:ach_a'), true);
      expect(reopened.get('ach:counter:totalWins'), 7);
      expect(reopened.get('stat:totalPiecesSnapped'), 999);
      // 回归 §3.1：值不得被 {"v":...} 包装
      expect(reopened.get('econ:coins'), isNot(isA<Map>()));
    });

    test('missing key 返回 null 而非抛异常', () async {
      sm = await initTestStorage();
      expect(getJson(sm.progress, 'main:999'), isNull);
      expect(sm.state.get('econ:coins'), isNull);
    });
  });

  group('损坏判定 isCorruption', () {
    test('FormatException / RangeError 判损坏', () {
      expect(isCorruption(const FormatException('bad header')), isTrue);
      expect(isCorruption(RangeError('Not enough bytes')), isTrue);
    });

    test('HiveError 含损坏关键字判损坏，其他不判', () {
      expect(isCorruption(HiveError('Invalid file format')), isTrue);
      expect(isCorruption(HiveError('Wrong CRC')), isTrue);
      expect(isCorruption(HiveError('Box may be corrupted')), isTrue);
      expect(isCorruption(HiveError('This operation is unsupported')), isFalse);
    });

    test('FileSystemException（锁冲突/磁盘满）不判损坏', () {
      expect(
        isCorruption(const FileSystemException('sharing violation')),
        isFalse,
      );
      expect(isCorruption(StateError('x')), isFalse);
    });
  });

  group('备份与恢复（§7.8）', () {
    Future<Directory> backupsRootOf(StorageManager m) async {
      final home = m.homePathForTest!;
      return Directory(p.join(home, 'hive_backups'));
    }

    /// 三个 box 都写入内容，确保备份时 3 个 .hive 均非空
    Future<void> seedAllBoxes(StorageManager m) async {
      await putJson(m.progress, 'main:001', {'canonicalId': 'main:001'});
      await putJson(m.collections, 'custom:s1', {'id': 's1'});
      await m.state.put('econ:coins', 55);
      await m.flushPendingWrites();
    }

    test('启动备份生成目录：仅 3 个 .hive，无 .lock', () async {
      sm = await initTestStorageWithBackups();
      await seedAllBoxes(sm);

      await sm.backupNow();

      final root = await backupsRootOf(sm);
      final dirs = (await root.list().toList())
          .whereType<Directory>()
          .where((d) => p.basename(d.path).startsWith('backup-'))
          .toList();
      expect(dirs.length, 1);
      final files = await dirs.single.list().toList();
      final names = files.map((f) => p.basename(f.path)).toList()..sort();
      // 备份目录内文件名按字典序（app-state < game-collections < game-progress）
      expect(names, [
        '$kBoxState.hive',
        '$kBoxCollections.hive',
        '$kBoxProgress.hive',
      ]);
      expect(names.any((n) => n.endsWith('.lock')), isFalse);
    });

    test('真实损坏文件能被 safeOpenBox 检出并抛 BoxCorruptException', () async {
      sm = await initTestStorageWithBackups();
      await sm.state.put('econ:coins', 42);
      await sm.flushPendingWrites();
      await corruptBox(sm, kBoxState);
      // safeOpenBox 抛的是 BoxCorruptException 而非原始 HiveError
      await expectLater(
        safeOpenBox<dynamic>(kBoxState),
        throwsA(isA<BoxCorruptException>()),
      );
    });

    test('恢复扫描跳过 .tmp 残留（原子落位）', () async {
      sm = await initTestStorageWithBackups();
      await sm.state.put('econ:coins', 1);
      await sm.flushPendingWrites();
      await sm.backupNow();

      final root = await backupsRootOf(sm);
      // 伪造一个被强杀留下的半成品目录
      await Directory(
        p.join(root.path, '.backup-20260902-101010-000.tmp'),
      ).create(recursive: true);

      await corruptBox(sm, kBoxState);
      await sm.openAll();
      // 自愈成功：无异常抛出，且数据来自正式备份
      expect(sm.state.get('econ:coins'), 1);
      // 残留 .tmp 未被提升为正式备份，也未被清理（清理只发生在下一次备份）
      final dirs = (await root.list().toList())
          .whereType<Directory>()
          .map((d) => p.basename(d.path))
          .toList();
      expect(dirs.where((n) => n.startsWith('backup-')).length, 1);
      expect(dirs.contains('.backup-20260902-101010-000.tmp'), isTrue);
    });

    test('单 box 损坏：只还原损坏 box，健康 box 数据不变', () async {
      sm = await initTestStorageWithBackups();
      await sm.state.put('econ:coins', 777);
      await putJson(sm.progress, 'main:002', {
        'canonicalId': 'main:002',
        'stars': 2,
      });
      await sm.flushPendingWrites();
      await sm.backupNow();

      // 只破坏 progress box
      await corruptBox(sm, kBoxProgress);

      await sm.openAll(); // 内部静默自愈，不向调用方抛异常
      expect(getJson(sm.progress, 'main:002')?['stars'], 2);
      // 健康 box 未被动过（未被回滚）
      expect(sm.state.get('econ:coins'), 777);
      // 备份还原成功 → 未走兜底重建，备份点 A 守卫不触发
      expect(sm.hasRecreatedBoxes, isFalse);
      // 损坏现场改名留证，未被强删
      final home = Directory(sm.homePathForTest!);
      final quarantined = (await home.list().toList())
          .whereType<File>()
          .map((f) => p.basename(f.path))
          .where((n) => n.startsWith('$kBoxProgress.hive.corrupt-'))
          .toList();
      expect(quarantined, hasLength(1));
    });

    test('连续 2 份备份均损坏 → 仅该 box 回落重建空 box', () async {
      sm = await initTestStorageWithBackups();
      await sm.state.put('econ:coins', 123);
      await putJson(sm.progress, 'main:003', {'canonicalId': 'main:003'});
      await sm.flushPendingWrites();
      await sm.backupNow();
      // 第二份备份
      await sm.state.put('econ:coins', 456);
      await sm.flushPendingWrites();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sm.backupNow();

      // 生产数据 + 两份备份全部损坏
      await corruptBox(sm, kBoxProgress);
      final root = await backupsRootOf(sm);
      final dirs = (await root.list().toList())
          .whereType<Directory>()
          .where((d) => p.basename(d.path).startsWith('backup-'))
          .toList();
      expect(dirs.length, 2);
      for (final d in dirs) {
        await File(
          p.join(d.path, '$kBoxProgress.hive'),
        ).writeAsBytes(buildCorruptHiveFile());
      }

      await sm.openAll();
      expect(sm.progress.isEmpty, isTrue);
      // 走了兜底重建 → 备份点 A 守卫必须触发（防止空箱覆盖历史备份）
      expect(sm.hasRecreatedBoxes, isTrue);
      // 其余健康 box 不受影响
      expect(sm.state.get('econ:coins'), 456);
    });

    test('双 box 同时损坏：各自从最新备份开始，不被前一 box 重试次数污染', () async {
      sm = await initTestStorageWithBackups();
      await sm.state.put('econ:coins', 5);
      await putJson(sm.progress, 'main:004', {'canonicalId': 'main:004'});
      await sm.flushPendingWrites();
      await sm.backupNow();

      await corruptBox(sm, kBoxProgress);
      await corruptBox(sm, kBoxState);

      await sm.openAll();
      // 两个 box 都从各自最新备份（tryIndex 0）还原成功
      expect(getJson(sm.progress, 'main:004')?['canonicalId'], 'main:004');
      expect(sm.state.get('econ:coins'), 5);
    });

    test('保留最近 5 份备份，超出删最旧', () async {
      sm = await initTestStorageWithBackups();
      await sm.state.put('econ:coins', 1);
      await sm.flushPendingWrites();
      for (var i = 0; i < 7; i++) {
        await sm.state.put('econ:coins', i);
        await sm.flushPendingWrites();
        await sm.backupNow();
        await Future<void>.delayed(const Duration(milliseconds: 3));
      }
      final root = await backupsRootOf(sm);
      final dirs = (await root.list().toList())
          .whereType<Directory>()
          .where((d) => p.basename(d.path).startsWith('backup-'))
          .toList();
      expect(dirs.length, kMaxBackups);
    });

    test('测试实例（forTest）不产生备份', () async {
      sm = await initTestStorage();
      await sm.state.put('econ:coins', 9);
      await sm.flushPendingWrites();
      await sm.backupNow();
      final root = Directory(p.join(sm.homePathForTest!, 'hive_backups'));
      expect(await root.exists(), isFalse);
    });
  });

  group('closeAll 前 flush（§7.1 v4.5）', () {
    test('close 后无尾部丢写', () async {
      sm = await initTestStorage();
      await sm.state.put('econ:coins', 321);
      // 不显式 flush，直接 closeAll
      await sm.closeAll();
      final reopened = await Hive.openBox<dynamic>(kBoxState);
      expect(reopened.get('econ:coins'), 321);
    });
  });

  group('keys 迭代安全（§5.4）', () {
    test('先收集后批量删：无异常且无漏删', () async {
      sm = await initTestStorage();
      for (var i = 0; i < 5; i++) {
        await putJson(sm.collections, 'material:m$i', {'id': 'm$i'});
      }
      await putJson(sm.collections, 'custom:s1', {'id': 's1'});

      final staleKeys = <String>[];
      for (final key in sm.collections.keys.cast<String>()) {
        if (key.startsWith('material:')) staleKeys.add(key);
      }
      expect(staleKeys.length, 5);
      for (final key in staleKeys) {
        await sm.collections.delete(key);
      }
      expect(
        sm.collections.keys.where((k) => '$k'.startsWith('material:')),
        isEmpty,
      );
      expect(getJson(sm.collections, 'custom:s1'), isNotNull);
    });

    test('JSON 值可直接 jsonDecode 出 Map[String, dynamic]', () async {
      sm = await initTestStorage();
      await sm.collections.put(
        'favorite:main:001',
        jsonEncode({'canonicalId': 'main:001', 'sortOrder': 0}),
      );
      final raw = sm.collections.get('favorite:main:001') as String;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect(decoded['canonicalId'], 'main:001');
    });
  });
}
