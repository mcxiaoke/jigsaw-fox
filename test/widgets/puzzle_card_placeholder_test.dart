import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/widgets/puzzle_card_placeholder.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

void main() {
  testWidgets('PuzzleCardPlaceholder renders puzzle piece icon and order number', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PuzzleCardPlaceholder(
            orderNumber: 101,
            showShimmer: false,
          ),
        ),
      ),
    );

    expect(find.byIcon(PhosphorIconsFill.puzzlePiece), findsOneWidget);
    expect(find.text('101'), findsOneWidget);
  });
}
