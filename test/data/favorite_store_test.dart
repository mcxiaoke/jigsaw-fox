import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/favorite_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await FavoriteStore.instance.init();
  });

  group('FavoriteStore & FavoriteEntry Unit Tests', () {
    test('FavoriteEntry serialization and extra preservation', () {
      final now = DateTime.now();
      final entry = FavoriteEntry(
        canonicalId: 'main:001',
        favoritedAt: now,
        titleSnapshot: '晨曦森林',
        imageSnapshot: 'assets/samples/animal_01.webp',
        sourceLabelSnapshot: '主线',
        aspectRatioLabel: 'portrait2x3',
        author: '官方艺术家',
        tags: const ['自然', '动物'],
        preferredDifficultyKey: '6x6',
        extra: const {'customMeta': 'xyz'},
      );

      final json = entry.toJson();
      expect(json['canonicalId'], equals('main:001'));
      expect(json['titleSnapshot'], equals('晨曦森林'));
      expect(json['aspectRatioLabel'], equals('portrait2x3'));
      expect(json['customMeta'], equals('xyz'));

      final fromJson = FavoriteEntry.fromJson(json);
      expect(fromJson.canonicalId, equals('main:001'));
      expect(fromJson.titleSnapshot, equals('晨曦森林'));
      expect(fromJson.aspectRatioLabel, equals('portrait2x3'));
      expect(fromJson.author, equals('官方艺术家'));
      expect(fromJson.tags, contains('自然'));
      expect(fromJson.extra['customMeta'], equals('xyz'));
    });

    test('toggleFavorite adds, notifies, and removes properly', () async {
      final store = FavoriteStore.instance;
      const cid = 'daily:20260902';

      expect(store.isFavorite(cid), isFalse);
      expect(store.idsNotifier.value.contains(cid), isFalse);

      // 1. Toggle on
      final added = await store.toggleFavorite(
        cid,
        title: '每日精选',
        sourceLabel: '每日',
      );
      expect(added, isTrue);
      expect(store.isFavorite(cid), isTrue);
      expect(store.idsNotifier.value.contains(cid), isTrue);

      final list = await store.favoritesSortedByTime();
      expect(list.length, equals(1));
      expect(list.first.canonicalId, equals(cid));
      expect(list.first.titleSnapshot, equals('每日精选'));

      // 2. Toggle off
      final removed = await store.toggleFavorite(cid);
      expect(removed, isFalse);
      expect(store.isFavorite(cid), isFalse);
      expect(store.idsNotifier.value.contains(cid), isFalse);

      final listEmpty = await store.favoritesSortedByTime();
      expect(listEmpty.isEmpty, isTrue);
    });

    test('pruneOrphans clears removed canonical IDs', () async {
      final store = FavoriteStore.instance;

      await store.toggleFavorite('main:001', title: '关卡1');
      await store.toggleFavorite('main:002', title: '关卡2');
      await store.toggleFavorite('ugc:deleted_pic', title: '已删除图片');

      expect((await store.favoritesSortedByTime()).length, equals(3));

      // 仅保留 main:001 和 main:002
      await store.pruneOrphans({'main:001', 'main:002'});

      final remaining = await store.favoritesSortedByTime();
      expect(remaining.length, equals(2));
      expect(store.isFavorite('ugc:deleted_pic'), isFalse);
      expect(store.isFavorite('main:001'), isTrue);
    });

    test(
      'toggleFavorite preserves all snapshot fields for orphan fallback',
      () async {
        final store = FavoriteStore.instance;
        const cid = 'ugc:snapshot_test';

        await store.toggleFavorite(
          cid,
          title: '狗狗近照',
          image: '/storage/dog.png',
          sourceLabel: '自制',
          isLocalFile: true,
          aspectRatioLabel: 'landscape3x2',
          author: '主人',
          tags: ['宠物', '自制'],
          preferredDifficultyKey: '8x8',
        );

        final list = await store.favoritesSortedByTime();
        final entry = list.firstWhere((e) => e.canonicalId == cid);
        expect(entry.titleSnapshot, equals('狗狗近照'));
        expect(entry.imageSnapshot, equals('/storage/dog.png'));
        expect(entry.sourceLabelSnapshot, equals('自制'));
        expect(entry.isLocalFileSnapshot, isTrue);
        expect(entry.aspectRatioLabel, equals('landscape3x2'));
        expect(entry.author, equals('主人'));
        expect(entry.tags, contains('宠物'));
        expect(entry.preferredDifficultyKey, equals('8x8'));
      },
    );
  });
}
