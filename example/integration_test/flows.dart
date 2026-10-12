import 'package:flutter_test/flutter_test.dart';
import 'package:smart_flutter_tester/smart_flutter_tester.dart';
import 'package:smart_tester_example/auth_api.dart';
import 'package:smart_tester_example/main.dart';

/// App flows written only with SmartTester – the app has no widget Keys.
///
/// Shared by `integration_test/app_flow_test.dart` (real device/simulator)
/// and `test/app_flow_test.dart` (headless, fake async).
void defineAppFlows({FailureCallback? onFailure}) {
  SmartTester smartFor(WidgetTester tester) => SmartTester(
        tester,
        onFailure: onFailure,
        // Test credentials are never printed in reports.
        sanitizer: const Sanitizer(secrets: {FakeAuthApi.validPassword}),
      );

  testWidgets('login with validation, network failure and retry, then shop and log out', (tester) async {
    final api = FakeAuthApi(failNextLogins: 1);
    await tester.pumpWidget(DemoApp(api: api));
    final smart = smartFor(tester);

    // Form validation.
    await smart.expectVisible(text: 'Sign in');
    await smart.tap(type: 'ElevatedButton', text: 'Log in');
    await smart.expectVisible(text: 'Enter a valid email');
    await smart.expectVisible(text: 'Password must be at least 6 characters');

    // Text fields located by their label; Password via its TextFormField wrapper.
    await smart.enterText(label: 'Email', text: FakeAuthApi.validEmail);
    await smart.enterText(type: 'TextFormField', label: 'Password', text: FakeAuthApi.validPassword);

    // First request fails (injected network error), retry succeeds.
    await smart.tap(type: 'ElevatedButton', text: 'Log in');
    await smart.expectVisible(textContains: 'Network error');
    await smart.tap(text: 'Retry');
    await smart.expectVisible(text: 'Welcome back'); // waits through two loading spinners
    expect(api.loginCalls, 2);

    // Every row has an "Add" button: the locator must refuse to guess.
    try {
      await smart.tap(text: 'Add');
      fail('an ambiguous locator must not tap anything');
    } on AmbiguousLocatorException catch (e) {
      expect(e.report.resolution!.tied.length, greaterThan(1));
    }

    // Bottom sheet + toggle.
    await smart.tap(label: 'Filter');
    await smart.expectVisible(role: UiRole.bottomSheet, textContains: 'Filters');
    await smart.tap(role: UiRole.toggle, text: 'Even products only');
    await smart.tap(text: 'Apply');
    await smart.expectNotVisible(role: UiRole.bottomSheet);
    await smart.expectVisible(text: 'Product 2');
    await smart.expectNotVisible(text: 'Product 1');

    // Lazy list: row 80 is not built until we scroll to it.
    await smart.scrollTo(type: 'ListTile', text: 'Product 80');
    await smart.tap(text: 'Add', within: const Locator(type: 'ListTile', text: 'Product 80'));
    await smart.expectVisible(textContains: 'Cart: 1');

    // Navigation to a details page and back.
    await smart.tap(type: 'ListTile', text: 'Product 80');
    await smart.expectVisible(text: 'Product 80 details');
    await smart.tap(text: 'Add to cart');
    await smart.expectVisible(text: 'Product 80 added'); // SnackBar
    await smart.tap(type: 'BackButton');
    await smart.expectVisible(textContains: 'Cart: 2');

    // Dialog: the icon button is found by its tooltip, the confirm button by text.
    await smart.tap(label: 'Log out');
    await smart.expectVisible(role: UiRole.dialog, textContains: 'Log out?');
    await smart.tap(text: 'Log out', within: const Locator(role: UiRole.dialog));
    await smart.expectVisible(text: 'Sign in');
  });

  testWidgets('wrong password shows an error and stays on the login screen', (tester) async {
    await tester.pumpWidget(DemoApp(api: FakeAuthApi()));
    final smart = smartFor(tester);
    await smart.enterText(label: 'Email', text: FakeAuthApi.validEmail);
    await smart.enterText(label: 'Password', text: 'wrong-password');
    await smart.tap(text: 'Log in');
    await smart.expectVisible(text: 'Wrong email or password.');
    await smart.expectNotVisible(text: 'Welcome back');
  });

  testWidgets('session expiry sends the user back to sign in', (tester) async {
    await tester.pumpWidget(DemoApp(api: FakeAuthApi(expireAfterRequests: 0)));
    final smart = smartFor(tester);
    await smart.enterText(label: 'Email', text: FakeAuthApi.validEmail);
    await smart.enterText(label: 'Password', text: FakeAuthApi.validPassword);
    await smart.tap(text: 'Log in');
    await smart.expectVisible(text: 'Session expired. Please sign in again.');
  });

  testWidgets('a missing element produces an actionable report', (tester) async {
    await tester.pumpWidget(DemoApp(api: FakeAuthApi()));
    final smart = SmartTester(tester, timeout: const Duration(milliseconds: 500), onFailure: onFailure);
    try {
      await smart.tap(type: 'ElevatedButton', text: 'Login'); // real label is "Log in"
      fail('should not find "Login"');
    } on ElementNotFoundException catch (e) {
      final report = e.toString();
      expect(report, contains('ElevatedButton "Log in"')); // near miss
      expect(report, contains('Current UI'));
    }
  });
}
