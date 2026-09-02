import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/favorite_store.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/progress_store.dart';
import 'package:jigsawpuzzle/pages/tabs/my_center_tab_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await GameRepository.instance.init();
    await ProgressStore.instance.init();
    await FavoriteStore.instance.init();
  });

  group('MyCenterTabView Widget Tests', () {
    testWidgets(
      'Renders 3 tabs, displays empty states and reacts to tab switching',
      (tester) async {
        var goExploreCalled = false;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MyCenterTabView(
                onGoExplore: () {
                  goExploreCalled = true;
                },
              ),
            ),
          ),
        );

        await tester.pumpAndSettle();

        // 1. Verify 3 tab headers
        expect(find.text('进行中 (0)'), findsOneWidget);
        expect(find.text('收藏 (0)'), findsOneWidget);
        expect(find.text('已完成 (0)'), findsOneWidget);

        // 2. Initial tab is '进行中', should show empty title & action button
        expect(find.text('暂无进行中的拼图'), findsOneWidget);
        expect(find.text('去挑选拼图'), findsOneWidget);

        // 3. Tap '去挑选拼图'
        await tester.tap(find.text('去挑选拼图'));
        await tester.pumpAndSettle();
        expect(goExploreCalled, isTrue);

        // 4. Switch to '收藏' tab
        await tester.tap(find.textContaining('收藏'));
        await tester.pumpAndSettle();
        expect(find.text('还没有收藏的拼图'), findsOneWidget);

        // 5. Switch to '已完成' tab
        await tester.tap(find.textContaining('已完成'));
        await tester.pumpAndSettle();
        expect(find.text('还没有完成过拼图'), findsOneWidget);
      },
    );
  });
}
