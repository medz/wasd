import 'package:flutter_test/flutter_test.dart';

import 'package:doom_window/main.dart';

void main() {
  testWidgets('Doom window app builds', (WidgetTester tester) async {
    await tester.pumpWidget(const DoomWindowApp());
    await tester.pump();

    expect(find.text('Doom Wasm Window'), findsOneWidget);
  });
}
