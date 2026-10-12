# Architecture

## Assessment (Phase A/B)

| Item | Finding |
|---|---|
| Repository | Empty apart from `README.md`. No app, test package, runner or SDK fork, so we built a standalone package plus a sample app. |
| Toolchain | Flutter 3.47.0 stable, Dart 3.13.0 (only version verified). |
| Engine changes | **None needed.** The Widget and Element trees, RenderObjects and the Semantics tree are all owned by the Flutter **framework** (Dart). The engine only receives the composited layers and the semantics *updates*. |
| VM service / inspector bridge | Not needed for the MVP. Everything runs inside the test isolate using `flutter_test` APIs, which also run on devices through `integration_test`. |

### The four trees and what we read from each

| Tree | What we use | API | Status |
|---|---|---|---|
| **Widget** (immutable configuration) | Type, `Text.data`, `onPressed`/`onTap`, `InputDecoration`, `obscureText`, `Key` | `Element.widget` | Public |
| **Element** (mounted instances) | Traversal, ancestry, identity, `mounted`, depth | `WidgetsBinding.rootElement`, `Element.debugVisitOnstageChildren` (same walk `flutter_test` finders use; not debug-only despite its name), `Element.visitChildren` | Public |
| **RenderObject** (layout and paint) | Global rect, hit-testability | `RenderBox.localToGlobal`, `WidgetsBinding.hitTestInView` | Public |
| **Semantics** (accessibility) | Merged accessibility label | `RenderObject.debugSemantics` (debug and profile modes; `null` in release), only when semantics are enabled (`testWidgets` enables them by default) | Public, documented "for testing" |

Semantics are **one signal among several**, never the only one. Many widgets have no label, and in release builds semantics data is unavailable to us.

## Layers

```
 ┌───────────────────────────── test code ─────────────────────────────┐
 │ smart.tap(type:'ElevatedButton', text:'Log in')                     │
 └──────────────┬──────────────────────────────────────────────────────┘
                ▼
 Interaction    SmartTester           wait (bounded pump loop) → resolve → ensureVisible →
 (lib/src/interaction)                re-resolve → hit-test/enabled check → tapAt / enterText → settle
                ▼
 Location       LocatorResolver       filter by every given field → score → collapse duplicates
 (lib/src/locator)                    → rank (covered elements lose) → found / ambiguous / notFound
                ▼
 Discovery      UiDiscovery           Element walk → classify widget → UiNode (type, role, texts,
 (lib/src/discovery)                  labels, wrapper types, rect, hitTestable, semantics label)
                ▼
 Reporting      FailureReport         sanitized text + JSON: locator, candidates, near misses,
 (lib/src/report)                     hints, UI outline → exception message + onFailure hook
                ▼
 Agent seam     CommandRunner         allow-listed JSON commands, secretRef indirection,
 (lib/src/agent)                      sanitized snapshots/reports; TestAgent interface (no LLM)
```

These layers stay separate on purpose. App assertions (`expectVisible`) only check the UI. Backend and API behaviour is the job of the app's own test doubles (see `FakeAuthApi` in the example), not the discovery layer.

## Key decisions

- **Nothing is cached between actions.** Every action captures a fresh snapshot and re-resolves its locator. This is why rebuilds that replace Elements are harmless. `SmartFinder` does the same each time it's evaluated.
- **Runtime IDs** (`s12:n34`) are scoped to one snapshot. `nodeById` rejects an ID from an older snapshot, or one whose Element was unmounted or replaced, with `StaleElementException`. IDs are for agents and debugging, not for test code.
- **Atomic controls.** A button owns its internals (InkWell, its label Text, the Tooltip). Those are folded into the button node so one visible control means one node. Generic `InkWell`/`GestureDetector` only become nodes when no more specific control owns them.
- **Wrapper types.** `TextFormField` and `DropdownButtonFormField` build their inner control. The inner node records the wrapper, so `type: 'TextFormField'` still works.
- **Ranking without guessing.** Candidates are scored by how well each field matched: exact beats fragment beats case-insensitive. The only non-locator signal is whether an element is **covered** (on screen but not hit-testable, e.g. under a modal barrier), because the user physically can't interact with it. Off-screen duplicates are *not* demoted, since that would be a silent positional guess. A tie at the top is an `AmbiguousLocatorException`. `nth:` is an explicit opt-in.
- **Bounded waiting.** `settle()` pumps until no frame is scheduled *or* a timeout passes, and never throws. That makes it safe with never-ending animations like `CircularProgressIndicator`, where `pumpAndSettle` would fail. Expectations and actions poll with `pump(step)`, so the same code works under fake async (`flutter test`) and real time (`integration_test`).
- **Ambiguity fails fast** once the UI is idle, and keeps waiting only while frames are still scheduled (e.g. both routes are visible during a transition).
- **Sanitization happens at output, not at match time.** Locators match raw text, but every snapshot, report and agent payload goes through `Sanitizer`. Obscured fields are never read at all, and values typed into them are added to the redaction list automatically.
