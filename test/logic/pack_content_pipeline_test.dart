import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/content/models/canonical_id.dart';
import 'package:jigsawpuzzle/logic/content/pipelines/pack_content_pipeline.dart';
import 'package:path/path.dart' as p;

Future<Uint8List> _createMockPngBytes(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
  canvas.drawRect(ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), ui.Paint()..color = const ui.Color(0xFF2196F3));
  final picture = recorder.endRecording();
  final img = await picture.toImage(width, height);
  final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
  return byteData!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String packsBaseDir;
  late PackContentPipeline pipeline;
  late Uint8List testPngBytes;

  setUpAll(() async {
    testPngBytes = await _createMockPngBytes(200, 200);
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('jigsaw_pack_test_');
    packsBaseDir = p.join(tempDir.path, 'packs');
    pipeline = PackContentPipeline(packsBaseDir: packsBaseDir);
  });

  tearDown(() {
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('PackContentPipeline End-to-End Tests', () {
    test('1. Import local pure images ZIP (Zero-metadata self-derivation)', () async {
      // 构造纯图片 zip (无任何 json)
      final zipPath = p.join(tempDir.path, 'cat_photos.zip');
      final archive = Archive();
      archive.addFile(ArchiveFile('cat_01.png', testPngBytes.length, testPngBytes));
      archive.addFile(ArchiveFile('cat_02.png', testPngBytes.length, testPngBytes));
      archive.addFile(ArchiveFile('cat_03.png', testPngBytes.length, testPngBytes));
      final zipData = ZipEncoder().encode(archive);
      File(zipPath).writeAsBytesSync(zipData);

      // 执行导入
      final pack = await pipeline.importFromLocalZip(zipPath);

      expect(pack.id.startsWith('pack_'), isTrue);
      expect(pack.title, equals('cat_photos'));
      expect(pack.levelCount, equals(3));
      expect(pack.sourceType, equals('local_file'));
      expect(pack.sourceOrigin, equals(zipPath));
      expect(pack.displaySource, equals('相册 / 本地'));
      expect(File(pack.coverPath).existsSync(), isTrue);

      // 验证关卡 Canonical ID
      final levels = pipeline.getPackLevels(pack);
      expect(levels.length, equals(3));
      expect(levels.first.id, equals(CanonicalId.forPack(pack.id, 'cat_01')));
      expect(levels.first.sourceModule, equals('pack'));
      expect(levels.first.isLocalFile, isTrue);
      expect(File(levels.first.imagePathOrUrl).existsSync(), isTrue);
    });

    test('2. Import creator ZIP with pack.json manifest', () async {
      // 构造带 pack.json 的 zip
      final zipPath = p.join(tempDir.path, 'cyberpunk.zip');
      final archive = Archive();
      archive.addFile(ArchiveFile('cover.png', testPngBytes.length, testPngBytes));
      archive.addFile(ArchiveFile('neon_01.png', testPngBytes.length, testPngBytes));
      archive.addFile(ArchiveFile('neon_02.png', testPngBytes.length, testPngBytes));

      final manifest = {
        'id': 'cyber_2026',
        'title': '赛博霓虹都市',
        'description': '未来夜景摄影精选',
        'author': 'CyberMaster',
        'cover': 'cover.png',
        'tags': ['科幻', '夜景'],
      };
      final manifestBytes = utf8.encode(jsonEncode(manifest));
      archive.addFile(ArchiveFile('pack.json', manifestBytes.length, manifestBytes));

      final zipData = ZipEncoder().encode(archive);
      File(zipPath).writeAsBytesSync(zipData);

      // 执行导入
      final pack = await pipeline.importFromLocalZip(zipPath);

      expect(pack.title, equals('赛博霓虹都市'));
      expect(pack.description, equals('未来夜景摄影精选'));
      expect(pack.author, equals('CyberMaster'));
      expect(pack.levelCount, equals(3)); // cover.png + 2 levels
      expect(pack.tags, contains('科幻'));
      expect(p.basename(pack.coverPath), equals('cover.png'));
    });

    test('3. Duplicate name ZIPs are isolated with unique physical IDs', () async {
      final zipPath1 = p.join(tempDir.path, 'same_name.zip');
      final archive1 = Archive();
      archive1.addFile(ArchiveFile('a.png', testPngBytes.length, testPngBytes));
      File(zipPath1).writeAsBytesSync(ZipEncoder().encode(archive1));

      final zipPath2 = p.join(tempDir.path, 'same_name_2.zip');
      final archive2 = Archive();
      archive2.addFile(ArchiveFile('b.png', testPngBytes.length, testPngBytes));
      File(zipPath2).writeAsBytesSync(ZipEncoder().encode(archive2));

      final pack1 = await pipeline.importFromLocalZip(zipPath1);
      final pack2 = await pipeline.importFromLocalZip(zipPath2);

      // 验证物理 ID 互不相同，完全隔离
      expect(pack1.id, isNot(equals(pack2.id)));

      final allPacks = await pipeline.loadAllPacks();
      expect(allPacks.length, equals(2));
    });

    test('4. Whole pack physical deletion releases disk storage and updates index', () async {
      final zipPath = p.join(tempDir.path, 'to_delete.zip');
      final archive = Archive();
      archive.addFile(ArchiveFile('del_01.png', testPngBytes.length, testPngBytes));
      archive.addFile(ArchiveFile('del_02.png', testPngBytes.length, testPngBytes));
      File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive));

      final pack = await pipeline.importFromLocalZip(zipPath);
      final packDir = Directory(p.join(packsBaseDir, pack.id));
      expect(packDir.existsSync(), isTrue);

      // 执行整包删除
      final success = await pipeline.deletePack(pack.id);
      expect(success, isTrue);

      // 验证目录已被物理清理
      expect(packDir.existsSync(), isFalse);

      final currentPacks = await pipeline.loadAllPacks();
      expect(currentPacks.any((p) => p.id == pack.id), isFalse);
    });

    test('5. Anti-ZipSlip and system junk files filtering', () async {
      final zipPath = p.join(tempDir.path, 'malicious_and_junk.zip');
      final archive = Archive();
      archive.addFile(ArchiveFile('__MACOSX/._hidden.png', 10, [1, 2, 3]));
      archive.addFile(ArchiveFile('.DS_Store', 10, [1, 2, 3]));
      archive.addFile(ArchiveFile('../escaped.png', testPngBytes.length, testPngBytes)); // 路径穿越
      archive.addFile(ArchiveFile('valid_image.png', testPngBytes.length, testPngBytes));
      File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive));

      final pack = await pipeline.importFromLocalZip(zipPath);
      expect(pack.levelCount, equals(1)); // 仅 valid_image.png 被安全提取

      final levels = pipeline.getPackLevels(pack);
      expect(levels.length, equals(1));
      expect(p.basename(levels.first.imagePathOrUrl), equals('valid_image.png'));
    });
  });
}
