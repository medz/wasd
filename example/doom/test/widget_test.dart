import 'package:flutter_test/flutter_test.dart';

import 'package:wasd_doom_example/main.dart';

void main() {
  testWidgets('DOOM app renders initial shell', (WidgetTester tester) async {
    await tester.pumpWidget(const DoomWindowApp());

    expect(find.text('DOOM // WASD'), findsAtLeastNWidgets(1));
  });
}
