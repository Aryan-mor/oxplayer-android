import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:telecima_tv/app.dart';

void main() {
  testWidgets('app builds', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: TeleCimaApp()));
    await tester.pump();
    expect(find.text('TeleCima'), findsWidgets);
  });
}
