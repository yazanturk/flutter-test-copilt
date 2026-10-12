import 'package:integration_test/integration_test.dart';

import 'flows.dart';

/// Run on a simulator/device:
///   cd example && flutter test integration_test -d DEVICE_ID
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  defineAppFlows(onFailure: (report) {
    // Sanitized failure reports are collected into the integration test's
    // report data (written out by `flutter drive` / CI tooling).
    final failures = (binding.reportData ??= <String, dynamic>{})
        .putIfAbsent('smartTesterFailures', () => <Map<String, Object?>>[]) as List;
    failures.add(report.toJson());
  });
}
