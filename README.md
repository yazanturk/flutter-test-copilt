# flutter-test-copilt — `smart_flutter_tester`

Key-free integration testing for Flutter. It discovers UI elements from the live Element tree, finds them with readable locators, refuses to guess when a locator is ambiguous, and explains failures with sanitized reports. It's built only on public `flutter_test` and `integration_test` APIs, with no engine or SDK changes.

```dart
final smart = SmartTester(tester);

await smart.enterText(label: 'Email', text: 'test@example.com');
await smart.enterText(type: 'TextFormField', label: 'Password', text: password);
await smart.tap(type: 'ElevatedButton', text: 'Log in');
await smart.expectVisible(text: 'Welcome back');

// Duplicate "Add" buttons: say which row you mean.
await smart.scrollTo(type: 'ListTile', text: 'Product 80');
await smart.tap(text: 'Add', within: const Locator(type: 'ListTile', text: 'Product 80'));
```

## Install

Add it as a dev dependency (path or git) next to `flutter_test` and `integration_test`:

```yaml
dev_dependencies:
  flutter_test: { sdk: flutter }
  integration_test: { sdk: flutter }
  smart_flutter_tester:
    git: https://github.com/yazanturk/flutter-test-copilt.git
```

Requires Flutter ≥ 3.47.0 and Dart ≥ 3.13. It has been verified **only on Flutter 3.47.0**. There are no third-party runtime dependencies.

## Run

```bash
flutter test                       # unit/widget tests for the tool itself
cd example && flutter test         # sample-app flows, headless
cd example && flutter test integration_test -d <device-id>   # same flows on a simulator/device
```

Results on Flutter 3.47.0, macOS: tool tests **19/19 passed**, example flows headless **4/4 passed**, example flows on the iPhone 17 simulator (iOS 26.5) **4/4 passed**.

## API

| Method | Purpose |
|---|---|
| `tap(...)`, `enterText(text:, ...)` | Wait for one interactable match, scroll it into view, check it's hit-testable and enabled, act, then settle (bounded). |
| `expectVisible(...)`, `expectNotVisible(...)` | Wait-based assertions. Use `allowMultiple: true` to accept repeated labels. |
| `scrollTo(...)` | Drag the scrollable until a lazily built item exists and is on screen. |
| `waitFor(...)`, `settle()` | Bounded waiting that never hangs on infinite animations. |
| `snapshot()`, `describeUi()` | Structured `UiSnapshot` / sanitized outline of the current UI. |
| `finder(Locator)` | A regular `Finder`, e.g. `expect(smart.finder(l), findsOneWidget)`. |
| `nodeById(id)`, `tapById(id)` | Runtime IDs from the latest snapshot. Throws `StaleElementException` after a rebuild. |

**Locator fields:** `type` (also matches wrappers like `TextFormField`), `role` (`UiRole.button/textField/dialog/…`), `text` (exact; ranks a case-insensitive match lower), `textContains`, `label` (field label, tooltip, `Semantics` label or hint), `semanticsLabel`, `key` (optional fallback), `within` (ancestor locator), `nth` (explicit position, as a last resort).

**Failures** throw `ElementNotFoundException`, `AmbiguousLocatorException`, `ElementNotInteractableException` (covered or disabled), `StaleElementException` or `SmartAssertionError`. The message is the full report: the locator, tied candidates with their ancestor paths, the closest near misses, hints (scroll, offstage route, add `within`) and a UI outline. Pass `onFailure:` to collect `report.toJson()`. The integration test puts it in `binding.reportData`.

**Custom widgets:** `SmartTester(tester, discovery: UiDiscovery(classifiers: [(w) => w is MyButton ? const WidgetClassification(UiRole.button, actions: {UiAction.tap}, atomic: true) : null]))`.

**Sensitive data:** values from obscured fields are never captured. Emails and long digit sequences are redacted in all output. Pass `Sanitizer(secrets: {...})` or call `smart.addSecret()` for more.

## AI agent seam (optional)

`CommandRunner` runs **allow-listed JSON commands** (`snapshot`, `tap`, `enterText`, `scrollTo`, `expectVisible`, `expectNotVisible`) and returns sanitized snapshots and failure reports. Secrets are referenced as `{"secretRef": "pin"}` and resolved from values the *test author* supplies, so an agent never sees them. `TestAgent` is an interface only. The framework needs no AI service, and agents get no shell, network or code-change capability.

## Repository layout

```
lib/src/discovery/   UiDiscovery, UiNode/UiSnapshot, widget classifier, Sanitizer
lib/src/locator/     Locator, LocatorResolver, SmartFinder
lib/src/interaction/ SmartTester
lib/src/report/      FailureReport + exceptions
lib/src/agent/       AgentCommand, CommandRunner, TestAgent
test/                tests for the tool (discovery, duplicates, rebuilds, lazy lists, dialogs, nav, reports, agent)
example/             sample app without Keys + integration_test/flows.dart
doc/ARCHITECTURE.md  tree-by-tree assessment and design decisions
```

## Limitations

- **Custom-painted UI** (`CustomPaint`, games, charts) has no widgets to discover. Use semantics labels or a custom classifier.
- **Platform views and WebViews** (maps, `WebView`, native ads) are outside the Flutter tree and can't be inspected.
- **Lazy lists:** unbuilt items don't exist until you call `scrollTo`. `scrollTo` scrolls forward only, in the single scrollable you give it (default: the only one on screen).
- **Text locators depend on locale and copy.** Prefer labels or `role` + `within` for stable tests, and keep `key` as a fallback.
- **Semantics labels** are only read in debug/profile mode while semantics are enabled.
- **Classification** covers common Material and Cupertino widgets. Some widgets, such as `TabBar` tabs and chips, have no specific rules yet (at best they appear as generic tappable nodes). `DropdownButton` text may include every item, because unselected items are also built.
- **Obscured elements:** an element counts as covered when a hit test at its centre misses it. Partially covered elements are judged only at that point.
- **Runtime IDs** are not persistent across launches, snapshots or rebuilds.
- Discovery walks the whole tree on every poll. That's fine for typical screens but slower for very large trees (thousands of elements).
- Verified only on Flutter 3.47.0. Other versions may break where widget APIs changed (for example `BackButton` subclassing `IconButton`).

## Roadmap

1. An LLM-backed `TestAgent`: propose steps from `agentView(snapshot)`, run them through `CommandRunner`, and triage failures from `FailureReport.toJson()`, with suggestions only.
2. Scenario recording: turn a manual session into `Locator`-based Dart test code.
3. Stability scoring for locators (prefer label/role/within over text) and suggestions for more robust locators.
4. More widget coverage (tabs, chips, date pickers, Cupertino pickers), plus bidirectional `scrollTo` and nested scrollables.
5. A live inspector over the VM service / DevTools extension, for exploring snapshots while an app runs.
