import 'package:flutter_test/flutter_test.dart';

import 'package:wasd_flutter_example/main.dart';

void main() {
  testWidgets('DOOM app renders initial shell', (WidgetTester tester) async {
    await tester.pumpWidget(const DoomApp());

    expect(find.text('DOOM (0)'), findsOneWidget);
    expect(find.text('DOOM is not running'), findsOneWidget);
  });
}
