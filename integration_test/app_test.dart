import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jigsawpuzzle/main.dart' as app;
import 'package:jigsawpuzzle/pages/main_screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app launches to home without error', (tester) async {
    // Launch full app (runZonedGuarded, LocaleService, StorageManager, etc.)
    app.main();
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.byType(MainScreen).evaluate().isNotEmpty) break;
    }

    expect(
      find.byType(MainScreen),
      findsOneWidget,
      reason: 'App should show MainScreen after launch',
    );
    expect(find.byType(Scaffold), findsWidgets);
    expect(find.byType(ErrorWidget), findsNothing);

    final hasZhHome = find.text('主页').evaluate().isNotEmpty;
    final hasEnHome = find.text('Home').evaluate().isNotEmpty;
    expect(
      hasZhHome || hasEnHome,
      isTrue,
      reason: 'Bottom nav should show Home label in either zh or en',
    );

    final myFinder = find.text('我的').evaluate().isNotEmpty
        ? find.text('我的')
        : find.text('My');
    if (myFinder.evaluate().isNotEmpty) {
      await tester.tap(myFinder.first);
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      expect(find.byType(MainScreen), findsOneWidget);
    }
  });
}
