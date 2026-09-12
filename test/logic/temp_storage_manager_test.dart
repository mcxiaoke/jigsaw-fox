// Unit tests for TempStorageManager and cold startup cleanup / self-healing
// ignore_for_file: avoid_catches_without_on_clauses
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/content/content_manager.dart';
import 'package:jigsawpuzzle/logic/content/staging/temp_storage_manager.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String supportDir;
  late TempStorageManager storageManager;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('jigsaw_temp_storage_test_');
    supportDir = p.join(tempDir.path, 'support');
    Directory(supportDir).createSync(recursive: true);
    storageManager = TempStorageManager(appSupportDir: supportDir);
  });

  tearDown(() {
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('TempStorageConfig Constants', () {
    test('Configuration constants match architectural specifications', () {
      expect(TempStorageConfig.tempDirectoryName, equals('temp'));
      expect(TempStorageConfig.downloadsSubDirName, equals('downloads'));
      expect(TempStorageConfig.extractSubDirName, equals('extract'));
    });
  });

  group('TempStorageManager Path Generation & Promotion', () {
    test('generates download path in temp/downloads directory', () {
      final downloadPath = storageManager.createTempDownloadPath(
        'col',
        'my-collection-001',
      );

      expect(
        p.isWithin(storageManager.downloadsDir, downloadPath),
        isTrue,
      );
      expect(p.basename(downloadPath), startsWith('col_my-collection-001_'));
      expect(downloadPath.endsWith('.zip'), isTrue);
      expect(Directory(storageManager.downloadsDir).existsSync(), isTrue);
    });

    test('generates extract directory in temp/extract directory', () {
      final extractDir = storageManager.createTempExtractDir(
        'ev',
        'event/summer:fest',
      );

      expect(
        p.isWithin(storageManager.extractDir, extractDir.path),
        isTrue,
      );
      expect(
        p.basename(extractDir.path),
        startsWith('extract_ev_event_summer_fest_'),
      );
      expect(extractDir.existsSync(), isTrue);
    });

    test('promotes extract directory to target directory atomically', () async {
      final extractDir = storageManager.createTempExtractDir('col', 'art-001');
      final sampleFile = File(p.join(extractDir.path, 'image1.jpg'));
      sampleFile.writeAsStringSync('dummy content');

      final targetDir = Directory(
        p.join(supportDir, 'levels', 'collections', 'art-001'),
      );

      await storageManager.promoteExtractDir(extractDir, targetDir);

      expect(targetDir.existsSync(), isTrue);
      final promotedFile = File(p.join(targetDir.path, 'image1.jpg'));
      expect(promotedFile.existsSync(), isTrue);
      expect(promotedFile.readAsStringSync(), equals('dummy content'));
      expect(extractDir.existsSync(), isFalse);
    });

    test(
      'promotes extract directory overwriting pre-existing target',
      () async {
        final targetDir = Directory(
          p.join(supportDir, 'levels', 'collections', 'art-002'),
        );
        targetDir.createSync(recursive: true);
        File(p.join(targetDir.path, 'old.jpg')).writeAsStringSync('old');

        final extractDir = storageManager.createTempExtractDir(
          'col',
          'art-002',
        );
        File(p.join(extractDir.path, 'new.jpg')).writeAsStringSync('new');

        await storageManager.promoteExtractDir(extractDir, targetDir);

        expect(targetDir.existsSync(), isTrue);
        expect(File(p.join(targetDir.path, 'new.jpg')).existsSync(), isTrue);
        expect(File(p.join(targetDir.path, 'old.jpg')).existsSync(), isFalse);
      },
    );

    test(
      'promotes extract directory via staging copy fallback when rename fails',
      () async {
        final targetDir = Directory(
          p.join(supportDir, 'levels', 'collections', 'art-copy-fallback'),
        );
        targetDir.createSync(recursive: true);
        File(p.join(targetDir.path, 'old.jpg')).writeAsStringSync('old-data');

        final realExtractDir = storageManager.createTempExtractDir(
          'col',
          'art-copy-fallback',
        );
        File(
          p.join(realExtractDir.path, 'new.jpg'),
        ).writeAsStringSync('new-data');

        final mockDir = _RenameFailingDirectory(realExtractDir);
        await storageManager.promoteExtractDir(mockDir, targetDir);

        expect(targetDir.existsSync(), isTrue);
        expect(File(p.join(targetDir.path, 'new.jpg')).existsSync(), isTrue);
        expect(
          File(p.join(targetDir.path, 'new.jpg')).readAsStringSync(),
          equals('new-data'),
        );
        expect(File(p.join(targetDir.path, 'old.jpg')).existsSync(), isFalse);
      },
    );

    test(
      'rolls back old target directory cleanly with zero data loss when promotion fails (Redline R1)',
      () async {
        final targetDir = Directory(
          p.join(supportDir, 'levels', 'collections', 'art-rollback-test'),
        );
        targetDir.createSync(recursive: true);
        final oldFile = File(p.join(targetDir.path, 'original.jpg'));
        oldFile.writeAsStringSync('precious user data');

        final realExtractDir = storageManager.createTempExtractDir(
          'col',
          'art-rollback-test',
        );
        File(
          p.join(realExtractDir.path, 'partial.jpg'),
        ).writeAsStringSync('broken');

        final mockDir = _CompletelyFailingDirectory(realExtractDir);

        await expectLater(
          () => storageManager.promoteExtractDir(mockDir, targetDir),
          throwsA(isA<FileSystemException>()),
        );

        // 验证红线 R1：原目录内容完整恢复，没有任何数据丢失
        expect(targetDir.existsSync(), isTrue);
        expect(oldFile.existsSync(), isTrue);
        expect(oldFile.readAsStringSync(), equals('precious user data'));
        expect(
          File(p.join(targetDir.path, 'partial.jpg')).existsSync(),
          isFalse,
        );

        // 验证没有遗留孤儿 .bak_ 或 .staging_ 目录
        final parentDir = targetDir.parent;
        final siblings = parentDir.listSync().map((e) => p.basename(e.path));
        expect(siblings.any((name) => name.contains('.bak_')), isFalse);
        expect(siblings.any((name) => name.contains('.staging_')), isFalse);
      },
    );
  });

  group('TempStorageManager Cleanup & Self-Healing', () {
    test(
      'cleanStaleTempDirectory wipes all files and recreates skeleton',
      () async {
        storageManager.ensureTempDirectoriesExist();
        final dlFile = File(
          p.join(storageManager.downloadsDir, 'abandoned.zip.part'),
        );
        dlFile.writeAsStringSync('partial zip bytes');

        final extSubDir = Directory(
          p.join(storageManager.extractDir, 'abandoned_extract_123'),
        );
        extSubDir.createSync();
        File(p.join(extSubDir.path, 'frame.png')).writeAsStringSync('frame');

        final cleanedCount = await storageManager.cleanStaleTempDirectory();
        expect(cleanedCount, greaterThan(0));

        expect(Directory(storageManager.downloadsDir).existsSync(), isTrue);
        expect(Directory(storageManager.extractDir).existsSync(), isTrue);
        expect(Directory(storageManager.downloadsDir).listSync(), isEmpty);
        expect(Directory(storageManager.extractDir).listSync(), isEmpty);
      },
    );
  });

  group('ContentManager Startup GC Integration', () {
    test(
      'ContentManager.initialize cleans temp directory on cold startup',
      () async {
        // 注入残留到 temp/
        storageManager.ensureTempDirectoriesExist();
        final tempStale = File(
          p.join(storageManager.downloadsDir, 'temp_leftover.zip'),
        );
        tempStale.writeAsStringSync('temp leftover');

        final colDir = Directory(p.join(supportDir, 'levels', 'collections'));
        colDir.createSync(recursive: true);
        final validDir = Directory(p.join(colDir.path, 'my-valid-collection'));
        validDir.createSync();
        final validFile = File(p.join(validDir.path, 'art.jpg'));
        validFile.writeAsStringSync('keep me');

        final manager = ContentManager(
          bootstrapUrls: const [],
          appSupportDir: supportDir,
          tempStorageManager: storageManager,
        );

        await manager.initialize(offlineOnly: true);

        // temp 暂存区应已清空
        expect(tempStale.existsSync(), isFalse);
        // 正式业务目录必须保留
        expect(validDir.existsSync(), isTrue);
        expect(validFile.existsSync(), isTrue);
      },
    );
  });
}

class _RenameFailingDirectory implements Directory {
  _RenameFailingDirectory(this._real);
  final Directory _real;

  @override
  bool existsSync() => _real.existsSync();

  @override
  String get path => _real.path;

  @override
  Directory get parent => _real.parent;

  @override
  Future<Directory> rename(String newPath) => Future.error(
    const FileSystemException('Simulated cross-device rename failure'),
  );

  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) => _real.listSync(recursive: recursive, followLinks: followLinks);

  @override
  void deleteSync({bool recursive = false}) =>
      _real.deleteSync(recursive: recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CompletelyFailingDirectory implements Directory {
  _CompletelyFailingDirectory(this._real);
  final Directory _real;

  @override
  bool existsSync() => _real.existsSync();

  @override
  String get path => _real.path;

  @override
  Directory get parent => _real.parent;

  @override
  Future<Directory> rename(String newPath) =>
      Future.error(const FileSystemException('Simulated rename failure'));

  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) => throw const FileSystemException('Simulated copy failure');

  @override
  void deleteSync({bool recursive = false}) =>
      _real.deleteSync(recursive: recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
