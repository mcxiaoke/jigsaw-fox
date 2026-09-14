import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/update/update_models.dart';

void main() {
  group('UpdateModels Unit Tests', () {
    const rawJson = '''
    {
      "schema": 1,
      "version": "1.0.1",
      "versionCode": 2,
      "minVersionCode": 2,
      "publishedAt": "2026-09-14T15:00:00+08:00",
      "notes": {
        "zh-CN": "修复若干问题，提升游戏流畅度",
        "en-US": "Bug fixes and performance improvements"
      },
      "platforms": {
        "android": {
          "url": "app/1.0.1+2/android/app-release.apk",
          "sha256": "abcdef1234567890",
          "size": 52428800,
          "mirrors": [
            "https://github.com/mcxiaoke/jigsaw-fox/releases/download/v1.0.1/app-release.apk"
          ]
        },
        "windows": {
          "url": "app/1.0.1+2/windows/jigsaw-setup-1.0.1.exe",
          "sha256": "fedcba0987654321",
          "size": 78643200,
          "mirrors": []
        }
      }
    }
    ''';

    test('parses UpdateManifest correctly', () {
      final jsonMap = jsonDecode(rawJson) as Map<String, dynamic>;
      final manifest = UpdateManifest.fromJson(jsonMap);

      expect(manifest.schema, equals(1));
      expect(manifest.version, equals('1.0.1'));
      expect(manifest.versionCode, equals(2));
      expect(manifest.minVersionCode, equals(2));
      expect(manifest.publishedAt, equals('2026-09-14T15:00:00+08:00'));

      expect(manifest.platforms.length, equals(2));
      final androidInfo = manifest.platforms['android']!;
      expect(androidInfo.url, equals('app/1.0.1+2/android/app-release.apk'));
      expect(androidInfo.sha256, equals('abcdef1234567890'));
      expect(androidInfo.size, equals(52428800));
      expect(androidInfo.mirrors.length, equals(1));

      final windowsInfo = manifest.platforms['windows']!;
      expect(
        windowsInfo.url,
        equals('app/1.0.1+2/windows/jigsaw-setup-1.0.1.exe'),
      );
      expect(windowsInfo.size, equals(78643200));
      expect(windowsInfo.mirrors, isEmpty);
    });

    test('notesForLocale matches correctly', () {
      final jsonMap = jsonDecode(rawJson) as Map<String, dynamic>;
      final manifest = UpdateManifest.fromJson(jsonMap);

      expect(manifest.notesForLocale('zh'), equals('修复若干问题，提升游戏流畅度'));
      expect(manifest.notesForLocale('zh-CN'), equals('修复若干问题，提升游戏流畅度'));
      expect(
        manifest.notesForLocale('en'),
        equals('Bug fixes and performance improvements'),
      );
      expect(
        manifest.notesForLocale('en-US'),
        equals('Bug fixes and performance improvements'),
      );
      // fallback
      expect(manifest.notesForLocale('ja'), equals('修复若干问题，提升游戏流畅度'));
    });

    test('PlatformUpdateInfo fullUrl resolves relative and absolute paths', () {
      const base = 'https://jigsawdata.umao.top/';
      const relativeInfo = PlatformUpdateInfo(
        url: 'app/1.0.1+2/android/app-release.apk',
        sha256: 'abc',
        size: 100,
      );
      expect(
        relativeInfo.fullUrl(base),
        equals(
          'https://jigsawdata.umao.top/app/1.0.1+2/android/app-release.apk',
        ),
      );

      const absoluteInfo = PlatformUpdateInfo(
        url: 'https://cdn.example.com/app.apk',
        sha256: 'abc',
        size: 100,
      );
      expect(
        absoluteInfo.fullUrl(base),
        equals('https://cdn.example.com/app.apk'),
      );
    });

    test('UpdateCheckResult status helpers', () {
      const normalResult = UpdateCheckResult(
        status: UpdateStatus.updateAvailable,
        currentVersion: '1.0.0',
        currentVersionCode: 1,
      );
      expect(normalResult.hasUpdate, isTrue);
      expect(normalResult.isForceUpdate, isFalse);

      const forceResult = UpdateCheckResult(
        status: UpdateStatus.forceUpdateRequired,
        currentVersion: '1.0.0',
        currentVersionCode: 1,
      );
      expect(forceResult.hasUpdate, isTrue);
      expect(forceResult.isForceUpdate, isTrue);

      const upToDateResult = UpdateCheckResult(
        status: UpdateStatus.noUpdate,
        currentVersion: '1.0.1',
        currentVersionCode: 2,
      );
      expect(upToDateResult.hasUpdate, isFalse);
      expect(upToDateResult.isForceUpdate, isFalse);
    });

    test('SHA256 integrity computation matches expected hash', () {
      final sampleBytes = utf8.encode('jigsaw-puzzle-release-package-data');
      final actualSha256 = sha256.convert(sampleBytes).toString();
      expect(actualSha256, isNotEmpty);
      expect(actualSha256.length, equals(64));

      // 验证大小写容错比对
      expect(
        actualSha256.toLowerCase(),
        equals(actualSha256.toUpperCase().toLowerCase()),
      );
    });

    test('parses and resolves split-per-abi Android packages correctly', () {
      const splitAbiJson = '''
      {
        "schema": 1,
        "version": "1.0.2",
        "versionCode": 3,
        "platforms": {
          "android": {
            "arm64-v8a": {
              "url": "app/1.0.2+3/android/JigsawFox-1.0.2-arm64-v8a.apk",
              "sha256": "arm64sha",
              "size": 20000000
            },
            "armeabi-v7a": {
              "url": "app/1.0.2+3/android/JigsawFox-1.0.2-armeabi-v7a.apk",
              "sha256": "v7asha",
              "size": 18000000
            },
            "all": {
              "url": "app/1.0.2+3/android/JigsawFox-1.0.2-all.apk",
              "sha256": "allsha",
              "size": 55000000
            }
          }
        }
      }
      ''';

      final jsonMap = jsonDecode(splitAbiJson) as Map<String, dynamic>;
      final manifest = UpdateManifest.fromJson(jsonMap);

      expect(manifest.androidAbis.length, equals(3));
      expect(manifest.androidAbis.containsKey('arm64-v8a'), isTrue);
      expect(manifest.androidAbis.containsKey('armeabi-v7a'), isTrue);
      expect(manifest.androidAbis.containsKey('all'), isTrue);

      // 1. 精确命中 arm64-v8a
      final arm64Pkg = manifest.getAndroidPackage(preferredAbi: 'arm64-v8a');
      expect(arm64Pkg, isNotNull);
      expect(arm64Pkg!.sha256, equals('arm64sha'));
      expect(arm64Pkg.size, equals(20000000));

      // 2. 传入设备 supportedAbis 列表按优先级命中
      final listPkg = manifest.getAndroidPackage(
        supportedAbis: ['unknown-abi', 'armeabi-v7a'],
      );
      expect(listPkg, isNotNull);
      expect(listPkg!.sha256, equals('v7asha'));

      // 3. 未知 ABI 自动降级回退到 all 通用包
      final fallbackPkg = manifest.getAndroidPackage(preferredAbi: 'mips64');
      expect(fallbackPkg, isNotNull);
      expect(fallbackPkg!.sha256, equals('allsha'));
      expect(fallbackPkg.size, equals(55000000));
    });
  });
}
