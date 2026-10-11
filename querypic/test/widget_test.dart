import 'package:flutter_test/flutter_test.dart';
import 'package:querypic/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('App smoke test: onboarding gate builds', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const QueryPicApp());
    await tester.pumpAndSettle();
    // First run (no accounts) shows the marketing landing page, whose
    // only exit is account creation.
    expect(find.text('Get started'), findsOneWidget);
    expect(find.textContaining('with words.'), findsOneWidget);
  });
}