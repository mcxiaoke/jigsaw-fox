import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/pages/tabs/events_tab_view.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

void main() {
  testWidgets('EventsTabView displays empty state and refresh button when no events', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: EventsTabView(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂无正在进行的活动'), findsOneWidget);
    expect(find.text('刷新同步'), findsOneWidget);
    expect(find.byIcon(PhosphorIconsRegular.calendarBlank), findsOneWidget);
  });

  testWidgets('EventsTabView empty state adapts to wide and narrow screens', (tester) async {
    // 1. Narrow screen (< 600)
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: EventsTabView(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂无正在进行的活动'), findsOneWidget);

    // 2. Wide screen (>= 600, e.g. 1000x800)
    tester.view.physicalSize = const Size(1000, 800);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: EventsTabView(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂无正在进行的活动'), findsOneWidget);
  });
}
