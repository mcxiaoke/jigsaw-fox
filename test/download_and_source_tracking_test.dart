import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/models/custom_puzzle_item.dart';
import 'package:jigsawpuzzle/data/models/downloaded_image_item.dart';
import 'package:jigsawpuzzle/logic/puzzle_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('DownloadedImageItem Model Tests', () {
    test('qualityTag and fileSizeLabel format correctly', () {
      final item4K = DownloadedImageItem(
        id: 'dl_1',
        localPath: '/tmp/test.jpg',
        sourcePlatform: 'Unsplash',
        sourceUrl: 'https://images.unsplash.com/photo-1',
        width: 3840,
        height: 2160,
        fileSizeBytes: 3 * 1024 * 1024 + 500 * 1024, // ~3.5 MB
        downloadedAt: DateTime.now(),
      );

      expect(item4K.qualityTag, '4K 超清');
      expect(item4K.resolutionLabel, '3840 × 2160');
      expect(item4K.fileSizeLabel, '3.5 MB');

      final itemFHD = item4K.copyWith(
        width: 1920,
        height: 1080,
        fileSizeBytes: 800 * 1024,
      );
      expect(itemFHD.qualityTag, 'FHD 全高清');
      expect(itemFHD.fileSizeLabel, '800.0 KB');
    });

    test('toJson and fromJson roundtrip serialization', () {
      final now = DateTime.now();
      final item = DownloadedImageItem(
        id: 'dl_123',
        localPath: '/data/app/img_123.jpg',
        sourcePlatform: 'Pixabay',
        sourceUrl: 'https://pixabay.com/photos/sample.jpg',
        width: 1920,
        height: 1280,
        fileSizeBytes: 1540000,
        downloadedAt: now,
      );

      final json = item.toJson();
      final restored = DownloadedImageItem.fromJson(json);

      expect(restored.id, item.id);
      expect(restored.localPath, item.localPath);
      expect(restored.sourcePlatform, item.sourcePlatform);
      expect(restored.sourceUrl, item.sourceUrl);
      expect(restored.width, item.width);
      expect(restored.height, item.height);
      expect(restored.fileSizeBytes, item.fileSizeBytes);
    });
  });

  group('CustomPuzzleItem Source Tracking & Backwards Compatibility Tests', () {
    test('New source fields serialize and deserialize correctly', () {
      const item = CustomPuzzleItem(
        id: 'ugc_1',
        title: '美丽山脉',
        imagePathOrUrl: '/data/custom/img.png',
        isLocalFile: true,
        difficulty: PuzzleDifficulty(label: '4 × 4 (16 块)', rows: 4, cols: 4),
        sourceType: 'online',
        sourcePlatform: 'Unsplash',
        sourceUrl: 'https://unsplash.com/photos/mountains',
      );

      final json = item.toJson();
      expect(json['sourceType'], 'online');
      expect(json['sourcePlatform'], 'Unsplash');
      expect(json['sourceUrl'], 'https://unsplash.com/photos/mountains');

      final restored = CustomPuzzleItem.fromJson(json);
      expect(restored.sourceType, 'online');
      expect(restored.sourcePlatform, 'Unsplash');
      expect(restored.sourceUrl, 'https://unsplash.com/photos/mountains');
    });

    test('Old legacy JSON without sourceType falls back smoothly', () {
      final legacyGalleryJson = {
        'id': 'ugc_old',
        'title': '旧相册拼图',
        'imagePathOrUrl': '/data/user/legacy.png',
        'isLocalFile': true,
        'rows': 4,
        'cols': 4,
      };

      final restored = CustomPuzzleItem.fromJson(legacyGalleryJson);
      expect(restored.sourceType, 'gallery');
      expect(restored.sourcePlatform, '本地相册');

      final legacyPresetJson = {
        'id': 'preset_old',
        'title': '预置拼图',
        'imagePathOrUrl': 'assets/images/sample1.jpg',
        'isLocalFile': false,
        'rows': 4,
        'cols': 4,
      };

      final restoredPreset = CustomPuzzleItem.fromJson(legacyPresetJson);
      expect(restoredPreset.sourceType, 'preset');
      expect(restoredPreset.sourcePlatform, '官方预置');
    });
  });
}
