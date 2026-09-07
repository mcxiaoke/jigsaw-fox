import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/services/achievement_service.dart';
import 'package:jigsawpuzzle/widgets/victory_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LocaleSettings.setPluralResolver(
    language: 'zh',
    cardinalResolver: (n, {zero, one, two, few, many, other}) => other ?? '',
  );

  final dummyImageBytes = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
  ]);

  testWidgets('VictoryDialog renders without Material/underline exceptions and adapts to English/Chinese', (tester) async {
    LocaleSettings.setLocale(AppLocale.en);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(360, 640)),
          child: Scaffold(
            body: VictoryDialog(
              imageBytes: dummyImageBytes,
              elapsedSeconds: 45,
              moveCount: 16,
              pieceCount: 16,
              rewardCoins: 50,
              newAchievements: const [
                AchievementDefinition(
                  id: 'first_win',
                  title: '初露锋芒',
                  description: '通关首张拼图',
                  type: AchievementType.accumulative,
                  target: 1,
                  metricKey: 'win_count',
                  coinReward: 50,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // Pump until animation finishes
    await tester.pump(const Duration(seconds: 3));

    // Verify localized title in English ('First Win', NOT Chinese)
    expect(find.textContaining('First Win'), findsOneWidget);
    expect(find.textContaining('初露锋芒'), findsNothing);
    expect(find.text('3 Stars'), findsOneWidget);

    final texts = tester.widgetList<Text>(find.byType(Text));
    for (final t in texts) {
      if (t.style != null) {
        expect(t.style!.decoration, isNot(TextDecoration.underline));
      }
    }

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(360, 640)),
          child: Scaffold(
            body: VictoryDialog(
              key: const ValueKey('1star'),
              imageBytes: dummyImageBytes,
              stars: 1,
              elapsedSeconds: 120,
              moveCount: 30,
              pieceCount: 16,
              rewardCoins: 10,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('1 Star'), findsOneWidget);

    LocaleSettings.setLocale(AppLocale.zh);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(360, 640)),
          child: Scaffold(
            body: VictoryDialog(
              key: const ValueKey('zh3stars'),
              imageBytes: dummyImageBytes,
              elapsedSeconds: 45,
              moveCount: 16,
              pieceCount: 16,
              rewardCoins: 50,
              newAchievements: const [
                AchievementDefinition(
                  id: 'first_win',
                  title: '初露锋芒',
                  description: '通关首张拼图',
                  type: AchievementType.accumulative,
                  target: 1,
                  metricKey: 'win_count',
                  coinReward: 50,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('3 星'), findsOneWidget);
    expect(find.textContaining('初露锋芒'), findsOneWidget);
  });
}
