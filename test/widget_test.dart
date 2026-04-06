import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:oxplayer/app.dart';

void main() {
  testWidgets('app builds', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: OxplayerApp()));
    await tester.pump();
    expect(find.text('OXPlayer'), findsWidgets);
  });
}
