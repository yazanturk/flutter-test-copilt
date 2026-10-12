import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../discovery/sanitizer.dart';
import '../discovery/ui_discovery.dart';
import '../discovery/ui_node.dart';
import '../locator/locator.dart';
import '../locator/resolver.dart';
import '../report/failure_report.dart';

/// Called with every failure report before the exception is thrown – e.g. to
/// attach it to `IntegrationTestWidgetsFlutterBinding.reportData`.
typedef FailureCallback = void Function(FailureReport report);

/// Key-free interaction layer over [WidgetTester].
///
/// Every action re-discovers the UI and re-resolves its locator, so nothing
/// holds on to an Element across rebuilds. Waiting is bounded and explicit:
/// no unbounded `pumpAndSettle`, which hangs on infinite animations.
///
/// Works with both `flutter_test` (fake async) and `integration_test` (real
/// device, live binding) because it only uses `WidgetTester` APIs.
class SmartTester {
  SmartTester(
    this.tester, {
    UiDiscovery? discovery,
    this.resolver = const LocatorResolver(),
    Sanitizer sanitizer = const Sanitizer(),
    this.timeout = const Duration(seconds: 5),
    this.settleTimeout = const Duration(seconds: 3),
    this.pumpStep = const Duration(milliseconds: 100),
    this.onFailure,
  })  : discovery = discovery ?? UiDiscovery(),
        _baseSanitizer = sanitizer;

  final WidgetTester tester;
  final UiDiscovery discovery;
  final LocatorResolver resolver;

  /// How long actions and expectations wait for their element to appear.
  final Duration timeout;

  /// Upper bound for letting animations finish after an action.
  final Duration settleTimeout;
  final Duration pumpStep;
  final FailureCallback? onFailure;

  final Sanitizer _baseSanitizer;
  final Set<String> _typedSecrets = <String>{};
  UiSnapshot? _lastSnapshot;

  /// Sanitizer for reports; also redacts anything typed into obscured fields.
  Sanitizer get sanitizer => _baseSanitizer.withSecrets(_typedSecrets);

  /// Registers a value (test password, token…) to redact from every report.
  void addSecret(String value) => _typedSecrets.add(value);

  // ---------------------------------------------------------------------------
  // Discovery
  // ---------------------------------------------------------------------------

  /// Captures the current UI. Runtime ids in it stay valid until the next
  /// call to [snapshot] or until their element is unmounted.
  UiSnapshot snapshot() => _lastSnapshot = discovery.capture();

  /// Sanitized outline of the current UI, handy while writing a test.
  String describeUi({int maxNodes = 200}) => snapshot().toOutline(sanitizer: sanitizer, maxNodes: maxNodes);

  /// A flutter_test [Finder] for the locator (re-resolved on each evaluation).
  SmartFinder finder(Locator locator) => SmartFinder(locator, discovery: discovery, resolver: resolver);

  /// Resolves without waiting. Never throws for not-found/ambiguous: inspect
  /// [Resolution.status].
  Resolution resolve(Locator locator) => resolver.resolve(locator, discovery.capture(), discovery: discovery);

  /// The element behind a runtime id from the latest [snapshot].
  ///
  /// Throws [StaleElementException] if the id comes from an older snapshot,
  /// or if its element has since been unmounted or replaced by a rebuild.
  UiNode nodeById(String runtimeId) {
    final last = _lastSnapshot;
    final node = last?.byId(runtimeId);
    if (last == null || node == null) {
      throw _fail(StaleElementException.new, 'stale', 'lookup',
          'Unknown runtime id "$runtimeId". Ids are only valid within the latest snapshot()'
          '${last == null ? ' and no snapshot was taken' : ' (generation ${last.generation})'}.');
    }
    final fresh = discovery.capture();
    final same = fresh.nodes.where((n) => identical(n.element, node.element)).firstOrNull;
    if (!node.element.mounted || same == null) {
      throw _fail(StaleElementException.new, 'stale', 'lookup',
          'Runtime id "$runtimeId" (${node.describe(sanitizer)}) is stale: its element was unmounted or replaced. '
          'Take a new snapshot() or use a Locator.',
          snapshot: fresh);
    }
    return same;
  }

  // ---------------------------------------------------------------------------
  // Waiting
  // ---------------------------------------------------------------------------

  /// Pumps until the locator resolves to exactly one element.
  Future<UiNode> waitFor({
    String? type,
    UiRole? role,
    String? text,
    String? textContains,
    String? label,
    String? semanticsLabel,
    String? key,
    Locator? within,
    int? nth,
    Locator? locator,
    Duration? timeout,
  }) async {
    final l = locator ?? _locator(type, role, text, textContains, label, semanticsLabel, key, within, nth);
    final r = await _resolveWaiting(l, (r) => r.status == ResolutionStatus.found, timeout);
    return _requireFound(r, 'waitFor');
  }

  /// Pumps frames until nothing is scheduled or [settleTimeout] elapses.
  /// Unlike `pumpAndSettle`, it does not throw on never-ending animations.
  Future<void> settle({Duration? timeout}) async {
    final limit = timeout ?? settleTimeout;
    await tester.pump();
    var elapsed = Duration.zero;
    while (tester.binding.hasScheduledFrame && elapsed < limit) {
      await tester.pump(pumpStep);
      elapsed += pumpStep;
    }
  }

  // ---------------------------------------------------------------------------
  // Interaction
  // ---------------------------------------------------------------------------

  Future<void> tap({
    String? type,
    UiRole? role,
    String? text,
    String? textContains,
    String? label,
    String? semanticsLabel,
    String? key,
    Locator? within,
    int? nth,
    Locator? locator,
  }) async {
    final l = locator ?? _locator(type, role, text, textContains, label, semanticsLabel, key, within, nth);
    final node = await _interactable(l, 'tap', UiAction.tap);
    await tester.tapAt(node.rect!.center);
    await settle();
  }

  /// Taps an element by runtime id from the latest [snapshot] (agent use).
  Future<void> tapById(String runtimeId) async {
    var node = nodeById(runtimeId);
    if (!node.hitTestable) {
      await tester.ensureVisible(_exact(node.element));
      await tester.pump();
      node = nodeById(runtimeId);
    }
    await tester.tapAt(node.rect!.center);
    await settle();
  }

  /// Enters [text] into a text field. The field is located by [label],
  /// [semanticsLabel], hint, [type], [within]… – not by its current text.
  /// Values typed into obscured fields are redacted from all reports.
  Future<void> enterText({
    required String text,
    String? type,
    String? label,
    String? semanticsLabel,
    String? key,
    Locator? within,
    int? nth,
    Locator? locator,
  }) async {
    final l = locator ?? _locator(type, null, null, null, label, semanticsLabel, key, within, nth);
    final fieldLocator = l.role == null && l.type == null ? l.copyWith(role: UiRole.textField) : l;
    final node = await _interactable(fieldLocator, 'enterText', UiAction.enterText);
    if (node.obscured) _typedSecrets.add(text);
    await tester.enterText(_exact(node.element), text);
    await settle();
  }

  /// Scrolls [scrollable] (default: the only scrollable on screen) until the
  /// target is built and on screen. Required for lazy lists, whose
  /// off-screen items do not exist in the Element tree.
  Future<UiNode> scrollTo({
    String? type,
    UiRole? role,
    String? text,
    String? textContains,
    String? label,
    String? semanticsLabel,
    String? key,
    Locator? within,
    int? nth,
    Locator? locator,
    Locator scrollable = const Locator(role: UiRole.scrollable),
    double delta = 250,
    int maxScrolls = 60,
  }) async {
    final l = locator ?? _locator(type, role, text, textContains, label, semanticsLabel, key, within, nth);
    for (var i = 0; i <= maxScrolls; i++) {
      final r = resolve(l);
      if (r.status == ResolutionStatus.ambiguous) throw _fromResolution(r, 'scrollTo');
      if (r.status == ResolutionStatus.found) {
        if (!r.match!.hitTestable) {
          await tester.ensureVisible(_exact(r.match!.element));
          await settle();
        }
        return _requireFound(resolve(l), 'scrollTo');
      }
      final s = resolve(scrollable);
      if (s.status != ResolutionStatus.found) throw _fromResolution(s, 'scrollTo (scrollable)');
      final state = (s.match!.element as StatefulElement).state as ScrollableState;
      final before = state.position.pixels;
      final step = switch (state.axisDirection) {
        AxisDirection.down => Offset(0, -delta),
        AxisDirection.up => Offset(0, delta),
        AxisDirection.right => Offset(-delta, 0),
        AxisDirection.left => Offset(delta, 0),
      };
      await tester.drag(_exact(s.match!.element), step);
      await settle();
      if (state.position.pixels == before) break; // reached the end
    }
    final r = resolve(l);
    if (r.status == ResolutionStatus.found) return r.match!;
    throw _fromResolution(r, 'scrollTo', extraHint: 'Scrolled to the end of ${scrollable.describe()} without finding it.');
  }

  // ---------------------------------------------------------------------------
  // Assertions
  // ---------------------------------------------------------------------------

  /// Waits until exactly one matching element is on screen.
  /// Pass [allowMultiple] to accept several (e.g. repeated list labels).
  Future<UiNode> expectVisible({
    String? type,
    UiRole? role,
    String? text,
    String? textContains,
    String? label,
    String? semanticsLabel,
    String? key,
    Locator? within,
    int? nth,
    Locator? locator,
    bool allowMultiple = false,
    Duration? timeout,
  }) async {
    final l = locator ?? _locator(type, role, text, textContains, label, semanticsLabel, key, within, nth);
    bool visible(Resolution r) =>
        (r.status == ResolutionStatus.found && r.match!.onScreen) ||
        (allowMultiple && r.status == ResolutionStatus.ambiguous && r.tied.any((c) => c.node.onScreen));
    final r = await _resolveWaiting(l, visible, timeout);
    if (visible(r)) return r.match ?? r.tied.firstWhere((c) => c.node.onScreen).node;
    if (r.status == ResolutionStatus.found) {
      throw _fail(SmartAssertionError.new, 'assertion', 'expectVisible',
          'Element exists but is not on screen: ${r.match!.describe(sanitizer)}. Use scrollTo(...) first.',
          locator: l, resolution: r);
    }
    throw _fromResolution(r, 'expectVisible');
  }

  /// Waits until no matching element is on screen.
  Future<void> expectNotVisible({
    String? type,
    UiRole? role,
    String? text,
    String? textContains,
    String? label,
    String? semanticsLabel,
    String? key,
    Locator? within,
    Locator? locator,
    Duration? timeout,
  }) async {
    final l = locator ?? _locator(type, role, text, textContains, label, semanticsLabel, key, within, null);
    bool gone(Resolution r) => r.candidates.every((c) => !c.node.onScreen);
    final r = await _resolveWaiting(l, gone, timeout);
    if (!gone(r)) {
      throw _fail(SmartAssertionError.new, 'assertion', 'expectNotVisible',
          'Expected no visible match, found ${r.candidates.where((c) => c.node.onScreen).length}.',
          locator: l, resolution: r);
    }
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  Locator _locator(String? type, UiRole? role, String? text, String? textContains, String? label,
          String? semanticsLabel, String? key, Locator? within, int? nth) =>
      Locator(
          type: type,
          role: role,
          text: text,
          textContains: textContains,
          label: label,
          semanticsLabel: semanticsLabel,
          key: key,
          within: within,
          nth: nth);

  Future<Resolution> _resolveWaiting(Locator l, bool Function(Resolution) done, Duration? timeout) async {
    final limit = timeout ?? this.timeout;
    var elapsed = Duration.zero;
    while (true) {
      final r = resolver.resolve(l, discovery.capture());
      if (done(r)) return r;
      // Ambiguity in an idle UI will not resolve itself; only keep waiting
      // while something is still animating (e.g. a route transition).
      if (r.status == ResolutionStatus.ambiguous && !tester.binding.hasScheduledFrame) {
        return resolver.resolve(l, discovery.capture(), discovery: discovery);
      }
      if (elapsed >= limit) {
        // Final pass with the (more expensive) offstage hints.
        return resolver.resolve(l, discovery.capture(), discovery: discovery);
      }
      await tester.pump(pumpStep);
      elapsed += pumpStep;
    }
  }

  Future<UiNode> _interactable(Locator l, String action, UiAction capability) async {
    var node = _requireFound(await _resolveWaiting(l, (r) => r.status == ResolutionStatus.found, null), action);
    if (!node.actions.contains(capability)) {
      throw _fail(ElementNotInteractableException.new, 'notInteractable', action,
          '${node.describe(sanitizer)} does not support $action (role: ${node.role.name}).',
          locator: l);
    }
    if (!node.hitTestable) {
      // Off screen inside a scroll view: bring it into view, then re-resolve
      // because scrolling can rebuild and replace the element.
      if (node.rect != null) {
        await tester.ensureVisible(_exact(node.element));
        await settle();
      }
      final again = resolver.resolve(l, discovery.capture());
      if (again.status != ResolutionStatus.found) throw _fromResolution(again, action);
      node = again.match!;
    }
    if (!node.hitTestable) {
      throw _fail(ElementNotInteractableException.new, 'notInteractable', action,
          '${node.describe(sanitizer)} is ${node.onScreen ? 'covered by another widget (dialog, overlay…)' : 'not on screen'} '
          'and cannot receive a tap.',
          locator: l, snapshot: discovery.capture());
    }
    if (node.enabled == false) {
      throw _fail(ElementNotInteractableException.new, 'notInteractable', action,
          '${node.describe(sanitizer)} is disabled.',
          locator: l);
    }
    return node;
  }

  UiNode _requireFound(Resolution r, String action) {
    if (r.status == ResolutionStatus.found) return r.match!;
    throw _fromResolution(r, action);
  }

  SmartTesterException _fromResolution(Resolution r, String action, {String? extraHint}) {
    final resolution = extraHint == null
        ? r
        : Resolution(
            locator: r.locator,
            snapshot: r.snapshot,
            status: r.status,
            candidates: r.candidates,
            tied: r.tied,
            match: r.match,
            nearMisses: r.nearMisses,
            hints: [extraHint, ...r.hints]);
    return switch (r.status) {
      ResolutionStatus.ambiguous => _fail(AmbiguousLocatorException.new, 'ambiguous', action,
          '${r.tied.length} elements match equally well; refusing to guess.',
          locator: r.locator, resolution: resolution, snapshot: r.snapshot),
      _ => _fail(ElementNotFoundException.new, 'notFound', action, 'No element matches the locator.',
          locator: r.locator, resolution: resolution, snapshot: r.snapshot),
    };
  }

  T _fail<T extends SmartTesterException>(
    T Function(FailureReport) create,
    String kind,
    String action,
    String message, {
    Locator? locator,
    Resolution? resolution,
    UiSnapshot? snapshot,
  }) {
    final report = FailureReport(
      kind: kind,
      action: action,
      message: message,
      locator: locator,
      resolution: resolution,
      snapshot: snapshot,
      sanitizer: sanitizer,
    );
    onFailure?.call(report);
    return create(report);
  }

  static Finder _exact(Element element) =>
      find.byElementPredicate((e) => identical(e, element), description: 'discovered element');
}

/// Debug helper: prints the sanitized UI outline to the test log.
void debugPrintUi(SmartTester smart) => debugPrint(smart.describeUi());
