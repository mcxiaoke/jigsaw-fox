import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_collection_item.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_event_item.dart';
import 'package:jigsawpuzzle/utils/locale_helper.dart';

void main() {
  group('PuzzleCollectionItem Bilingual Tests', () {
    test('fromJson and toJson with bilingual fields', () {
      final json = {
        'id': 'col_masterpieces',
        'title': 'World Masterpieces',
        'titleZh': '世界名画经典',
        'desc': 'Classic art puzzles',
        'descZh': '大师名画拼图精选',
        'type': 'zip',
        'status': 'active',
        'totalCount': 10,
      };

      final item = PuzzleCollectionItem.fromJson(json);
      expect(item.id, equals('col_masterpieces'));
      expect(item.title, equals('World Masterpieces'));
      expect(item.titleZh, equals('世界名画经典'));
      expect(item.desc, equals('Classic art puzzles'));
      expect(item.descZh, equals('大师名画拼图精选'));

      final outJson = item.toJson();
      expect(outJson['title'], equals('World Masterpieces'));
      expect(outJson['titleZh'], equals('世界名画经典'));
      expect(outJson['desc'], equals('Classic art puzzles'));
      expect(outJson['descZh'], equals('大师名画拼图精选'));
    });

    test('backward compatibility without titleZh and descZh', () {
      final legacyJson = {
        'id': 'col_legacy',
        'title': 'Legacy Collection',
        'desc': 'Old description',
      };

      final item = PuzzleCollectionItem.fromJson(legacyJson);
      expect(item.title, equals('Legacy Collection'));
      expect(item.titleZh, isNull);
      expect(item.desc, equals('Old description'));
      expect(item.descZh, isNull);

      // 中文环境下回退到默认英文 title 和 desc
      expect(item.localizedTitle('zh'), equals('Legacy Collection'));
      expect(item.localizedDesc('zh'), equals('Old description'));

      // 英文环境返回默认英文
      expect(item.localizedTitle('en'), equals('Legacy Collection'));
      expect(item.localizedDesc('en'), equals('Old description'));
    });

    test('localizedTitle and localizedDesc fallback logic', () {
      const itemWithBoth = PuzzleCollectionItem(
        id: 'c1',
        title: 'Nature Wonders',
        titleZh: '大自然奇观',
        desc: 'Beautiful nature scenes',
        descZh: '壮丽大自然风光拼图',
      );

      // 中文语言：使用中文
      expect(itemWithBoth.localizedTitle('zh'), equals('大自然奇观'));
      expect(itemWithBoth.localizedTitle('zh-CN'), equals('大自然奇观'));
      expect(itemWithBoth.localizedDesc('zh'), equals('壮丽大自然风光拼图'));

      // 英文语言：使用英文
      expect(itemWithBoth.localizedTitle('en'), equals('Nature Wonders'));
      expect(
        itemWithBoth.localizedDesc('en'),
        equals('Beautiful nature scenes'),
      );

      // titleZh 为空字符串时降级回退
      const itemEmptyZh = PuzzleCollectionItem(
        id: 'c2',
        title: 'Only English',
        titleZh: '   ',
        desc: 'English only desc',
        descZh: '',
      );
      expect(itemEmptyZh.localizedTitle('zh'), equals('Only English'));
      expect(itemEmptyZh.localizedDesc('zh'), equals('English only desc'));
    });
  });

  group('PuzzleEventItem Bilingual Tests', () {
    test('fromJson and toJson with bilingual fields', () {
      final json = {
        'id': 'halloween_2026',
        'title': 'Spooky Halloween',
        'titleZh': '万圣节奇妙夜',
        'desc': 'Explore spooky pumpkins',
        'descZh': '探索神秘南瓜灯与糖果世界',
        'status': 'active',
        'type': 'zip',
      };

      final item = PuzzleEventItem.fromJson(json);
      expect(item.title, equals('Spooky Halloween'));
      expect(item.titleZh, equals('万圣节奇妙夜'));
      expect(item.desc, equals('Explore spooky pumpkins'));
      expect(item.descZh, equals('探索神秘南瓜灯与糖果世界'));

      final outJson = item.toJson();
      expect(outJson['titleZh'], equals('万圣节奇妙夜'));
      expect(outJson['descZh'], equals('探索神秘南瓜灯与糖果世界'));
    });

    test('localizedTitle and localizedDesc logic', () {
      const event = PuzzleEventItem(
        id: 'e1',
        title: 'Spring Festival',
        titleZh: '新春大促',
        status: 'active',
        type: 'zip',
        desc: 'Celebrate New Year',
        descZh: '欢度新春佳节',
      );

      // 中文环境下优先使用中文
      expect(event.localizedTitle('zh'), equals('新春大促'));
      expect(event.localizedDesc('zh'), equals('欢度新春佳节'));

      // 其它语言环境使用英文
      expect(event.localizedTitle('en'), equals('Spring Festival'));
      expect(event.localizedDesc('en'), equals('Celebrate New Year'));

      // 无中文时回退
      const noZhEvent = PuzzleEventItem(
        id: 'e2',
        title: 'Cyberpunk 2026',
        status: 'active',
        type: 'zip',
        desc: 'Sci-fi puzzle challenge',
      );
      expect(noZhEvent.localizedTitle('zh'), equals('Cyberpunk 2026'));
      expect(noZhEvent.localizedDesc('zh'), equals('Sci-fi puzzle challenge'));
    });
  });

  group('Tag Localization Tests (LocaleHelper)', () {
    test('isChinese checks', () {
      expect(LocaleHelper.isChinese('zh'), isTrue);
      expect(LocaleHelper.isChinese('zh-CN'), isTrue);
      expect(LocaleHelper.isChinese('zh-TW'), isTrue);
      expect(LocaleHelper.isChinese('en'), isFalse);
      expect(LocaleHelper.isChinese('ja'), isFalse);
    });

    test('getLocalizedTagName translates correctly based on language', () {
      // 1. 中文语言环境：转为中文
      expect(getLocalizedTagName('Landscapes', 'zh'), equals('风光'));
      expect(getLocalizedTagName('Nature', 'zh'), equals('自然'));
      expect(getLocalizedTagName('Animals', 'zh'), equals('动物'));
      expect(getLocalizedTagName('all', 'zh'), equals('全部'));
      // 本身就是中文，保持中文
      expect(getLocalizedTagName('风光', 'zh'), equals('风光'));

      // 2. 其它语言环境：转为英文
      expect(getLocalizedTagName('风光', 'en'), equals('Landscapes'));
      expect(getLocalizedTagName('自然', 'en'), equals('Nature'));
      expect(getLocalizedTagName('动物', 'en'), equals('Animals'));
      expect(getLocalizedTagName('all', 'en'), equals('All'));
      // 本身就是英文，保持英文
      expect(getLocalizedTagName('Landscapes', 'en'), equals('Landscapes'));
    });

    test(
      'getLocalizedHomeTags returns 18 tags with correct localized labels',
      () {
        final zhTags = getLocalizedHomeTags('zh');
        expect(zhTags.length, equals(18));
        expect(zhTags.first['id'], equals('all'));
        expect(zhTags.first['label'], equals('全部'));
        expect(zhTags[1]['id'], equals('Landscapes'));
        expect(zhTags[1]['label'], equals('风光'));

        final enTags = getLocalizedHomeTags('en');
        expect(enTags.length, equals(18));
        expect(enTags.first['id'], equals('all'));
        expect(enTags.first['label'], equals('All'));
        expect(enTags[1]['id'], equals('Landscapes'));
        expect(enTags[1]['label'], equals('Landscapes'));
      },
    );
  });
}
