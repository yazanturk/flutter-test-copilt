import 'dart:convert';

import '../discovery/sanitizer.dart';
import '../discovery/ui_node.dart';
import '../locator/locator.dart';
import '../locator/resolver.dart';

/// A sanitized, self-contained explanation of a failed step. Safe to log,
/// attach to CI artifacts, or hand to an analysis agent.
class FailureReport {
  FailureReport({
    required this.kind,
    required this.action,
    required this.message,
    this.locator,
    this.resolution,
    this.snapshot,
    this.sanitizer = const Sanitizer(),
  });

  /// `notFound`, `ambiguous`, `notInteractable`, `stale`, `assertion`.
  final String kind;

  /// The step that failed, e.g. `tap` or `enterText` (never includes typed values).
  final String action;
  final String message;
  final Locator? locator;
  final Resolution? resolution;
  final UiSnapshot? snapshot;
  final Sanitizer sanitizer;

  Map<String, Object?> toJson() => {
        'kind': kind,
        'action': action,
        'message': sanitizer.text(message),
        if (locator != null) 'locator': locator!.describe(sanitizer.text),
        if (resolution != null) ...{
          'candidates': resolution!.candidates.take(10).map(_candidateJson).toList(),
          'nearMisses': resolution!.nearMisses.map((n) => n.toJson(sanitizer)).toList(),
          'hints': resolution!.hints.map(sanitizer.text).toList(),
        },
        if (snapshot != null) 'snapshot': snapshot!.toJson(sanitizer: sanitizer, interactiveOnly: true),
      };

  Map<String, Object?> _candidateJson(Candidate c) => {
        ...c.node.toJson(sanitizer),
        'score': c.score,
        'matchedOn': c.reasons,
        'path': c.node.path(sanitizer),
      };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Human-readable report used as the exception message.
  String toText({int maxOutlineNodes = 60}) {
    final b = StringBuffer()
      ..writeln('SmartTester: $action failed – ${sanitizer.text(message)}');
    if (locator != null) b.writeln('  Locator: ${locator!.describe(sanitizer.text)}');
    final r = resolution;
    if (r != null) {
      if (r.status == ResolutionStatus.ambiguous) {
        b.writeln('  ${r.tied.length} equally good candidates:');
        for (final c in r.tied.take(8)) {
          b.writeln('    - ${c.node.runtimeId} ${c.node.path(sanitizer)}${_where(c.node)}');
        }
      }
      if (r.nearMisses.isNotEmpty) {
        b.writeln('  Closest elements on screen:');
        for (final n in r.nearMisses.take(8)) {
          b.writeln('    - ${n.runtimeId} ${n.path(sanitizer)}${_where(n)}');
        }
      }
      if (r.hints.isNotEmpty) {
        b.writeln('  Hints:');
        for (final h in r.hints) {
          b.writeln('    * ${sanitizer.text(h)}');
        }
      }
    }
    if (snapshot != null) {
      b
        ..writeln('  Current UI (snapshot ${snapshot!.generation}, ${snapshot!.nodes.length} nodes):')
        ..write(snapshot!
            .toOutline(sanitizer: sanitizer, maxNodes: maxOutlineNodes)
            .split('\n')
            .map((l) => l.isEmpty ? l : '    $l')
            .join('\n'));
    }
    return b.toString();
  }

  static String _where(UiNode n) {
    final r = n.rect;
    final pos = r == null ? '' : ' at (${r.left.round()},${r.top.round()})';
    final state = !n.onScreen ? ' off-screen' : (!n.hitTestable ? ' covered' : '');
    return '$pos$state';
  }
}

/// Base class for every SmartTester failure. Its message is the full,
/// sanitized [report].
class SmartTesterException implements Exception {
  SmartTesterException(this.report);

  final FailureReport report;

  @override
  String toString() => report.toText();
}

class ElementNotFoundException extends SmartTesterException {
  ElementNotFoundException(super.report);
}

class AmbiguousLocatorException extends SmartTesterException {
  AmbiguousLocatorException(super.report);
}

class ElementNotInteractableException extends SmartTesterException {
  ElementNotInteractableException(super.report);
}

class StaleElementException extends SmartTesterException {
  StaleElementException(super.report);
}

class SmartAssertionError extends SmartTesterException {
  SmartAssertionError(super.report);
}
