/// Key-free UI discovery, smart locators and diagnostic reports for
/// flutter_test and integration_test.
library;

export 'src/agent/agent.dart';
export 'src/discovery/interactivity.dart' show WidgetClassification, WidgetClassifier, classifyWidget;
export 'src/discovery/sanitizer.dart';
export 'src/discovery/ui_discovery.dart' show UiDiscovery, isHitTestable;
export 'src/discovery/ui_node.dart';
export 'src/interaction/smart_tester.dart';
export 'src/locator/locator.dart';
export 'src/locator/resolver.dart';
export 'src/report/failure_report.dart';
