import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:querypic/screens/settings_screen.dart';
import 'package:querypic/services/account_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression: switching to the admin profile with the RIGHT pin must
/// not red-screen (_dependents.isEmpty assertion, seen on device).
void main() {
  testWidgets('admin switch with correct PIN completes cleanly', (
    WidgetTester tester,
  ) async {
    const salt = 'testsalt';
    final pinHash = AccountStore.hashPin(salt, '1234');
    final profiles = [
      const AccountProfile(
        id: 'admin1',
        name: 'Admin',
        isAdmin: true,
        createdMs: 1,
      ).toJson(),
      const AccountProfile(
        id: 'user1',
        name: 'Normal',
        isAdmin: false,
        createdMs: 2,
      ).toJson(),
    ];
    SharedPreferences.setMockInitialValues({
      AccountStore.keyProfiles: json.encode(profiles),
      AccountStore.keyActive: 'user1',
      AccountStore.keyPinSalt: salt,
      AccountStore.keyPinHash: pinHash,
    });
    // Tall surface: the whole settings list renders, no scrolling needed
    // (matches the device sequence: tap, dialogs, switch — no scroll).
    tester.binding.window.physicalSizeTestValue = const Size(800, 3000);
    tester.binding.window.devicePixelRatioTestValue = 1.0;
    addTearDown(tester.binding.window.clearPhysicalSizeTestValue);
    await tester.pumpWidget(
      const MaterialApp(home: SettingsScreen()),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Open the switcher (Accounts row shows the active profile name).
    await tester.tap(find.text('Normal'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Switch account'), findsOneWidget);

    // Pick the admin profile.
    await tester.tap(find.text('Admin'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Admin PIN required'), findsOneWidget);

    // Enter the RIGHT pin and confirm.
    await tester.enterText(find.byType(TextField), '1234');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Switched: settings now shows the admin profile, no error dialog.
    expect(find.text('Admin'), findsWidgets);
    expect(find.text('Wrong PIN'), findsNothing);
  });
}
