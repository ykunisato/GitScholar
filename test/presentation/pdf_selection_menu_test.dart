import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitscholar/domain/entities/entities.dart';
import 'package:gitscholar/presentation/viewers/pdf/pdf_selection_menu.dart';

void main() {
  // pdfrx builds the selection menu inside its own stack, where a lookup of
  // MaterialLocalizations throws. The menu must therefore build with no
  // MaterialApp and no Localizations at all.
  testWidgets('builds and reacts without MaterialLocalizations', (
    tester,
  ) async {
    var copied = false;
    var asked = false;
    HighlightColor? picked;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(),
          child: Center(
            child: PdfSelectionMenu(
              copyLabel: 'Copy',
              markerLabel: 'Highlight',
              askAiLabel: 'Ask AI',
              onCopy: () => copied = true,
              onAskAi: () => asked = true,
              onHighlight: (c) => picked = c,
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Highlight'), findsOneWidget);
    expect(find.byKey(const Key('marker-yellow')), findsOneWidget);

    await tester.tap(find.text('Copy'));
    await tester.tap(find.text('Ask AI'));
    await tester.tap(find.byKey(const Key('marker-green')));
    await tester.pump();

    expect(copied, isTrue);
    expect(asked, isTrue);
    expect(picked, HighlightColor.green);
  });
}
