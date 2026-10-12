import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../discovery/ui_discovery.dart';
import '../discovery/ui_node.dart';
import 'locator.dart';

enum ResolutionStatus { found, notFound, ambiguous }

class Candidate {
  Candidate(this.node, this.score, this.reasons);

  final UiNode node;
  final int score;
  final List<String> reasons;

  /// On screen but covered (dialog barrier, another route, overlay).
  bool get obscured => node.onScreen && !node.hitTestable;
}

/// Outcome of resolving a [Locator] against a [UiSnapshot], including
/// everything needed to explain a failure.
class Resolution {
  Resolution({
    required this.locator,
    required this.snapshot,
    required this.status,
    required this.candidates,
    required this.tied,
    this.match,
    this.nearMisses = const [],
    this.hints = const [],
  });

  final Locator locator;
  final UiSnapshot snapshot;
  final ResolutionStatus status;

  /// Every node that satisfied the locator, best first.
  final List<Candidate> candidates;

  /// The candidates that share the best rank (more than one => ambiguous).
  final List<Candidate> tied;
  final UiNode? match;
  final List<UiNode> nearMisses;
  final List<String> hints;
}

/// Deterministic, rule-based locator resolution. No AI involved.
class LocatorResolver {
  const LocatorResolver();

  Resolution resolve(Locator locator, UiSnapshot snapshot, {UiDiscovery? discovery}) {
    if (locator.isEmpty) {
      throw ArgumentError('A locator needs at least one of type, role, text, label, semanticsLabel, key or within.');
    }
    var candidates = <Candidate>[];
    for (final node in snapshot.nodes) {
      final reasons = <String>[];
      final score = _score(node, locator, reasons);
      if (score != null) candidates.add(Candidate(node, score, reasons));
    }

    // A Text inside a matching button/list item is the same thing seen twice:
    // keep the outer, more meaningful node.
    final matched = candidates.map((c) => c.node).toSet();
    candidates = candidates
        .where((c) => !(c.node.role == UiRole.text && c.node.ancestors.any(matched.contains)))
        .toList();

    if (candidates.isEmpty) {
      return Resolution(
        locator: locator,
        snapshot: snapshot,
        status: ResolutionStatus.notFound,
        candidates: const [],
        tied: const [],
        nearMisses: _nearMisses(locator, snapshot),
        hints: _notFoundHints(locator, snapshot, discovery),
      );
    }

    // Rank: covered elements can't receive input, so they lose to uncovered
    // ones. Everything else is decided purely by how well the locator matched.
    int tier(Candidate c) => c.obscured ? 0 : 1;
    candidates.sort((a, b) {
      final t = tier(b).compareTo(tier(a));
      return t != 0 ? t : b.score.compareTo(a.score);
    });
    final best = candidates.first;
    final tied = candidates.where((c) => tier(c) == tier(best) && c.score == best.score).toList()
      ..sort((a, b) => snapshot.nodes.indexOf(a.node).compareTo(snapshot.nodes.indexOf(b.node)));

    final hints = <String>[
      if (candidates.any((c) => c.obscured) && tier(best) == 1)
        '${candidates.where((c) => c.obscured).length} other match(es) are covered (e.g. by a dialog) and were ranked lower.',
    ];

    if (locator.nth != null) {
      if (locator.nth! < tied.length) {
        return Resolution(
            locator: locator,
            snapshot: snapshot,
            status: ResolutionStatus.found,
            candidates: candidates,
            tied: tied,
            match: tied[locator.nth!].node,
            hints: hints);
      }
      return Resolution(
        locator: locator,
        snapshot: snapshot,
        status: ResolutionStatus.notFound,
        candidates: candidates,
        tied: tied,
        hints: ['nth: ${locator.nth} is out of range; only ${tied.length} equally ranked candidate(s) exist.'],
      );
    }

    if (tied.length > 1) {
      return Resolution(
        locator: locator,
        snapshot: snapshot,
        status: ResolutionStatus.ambiguous,
        candidates: candidates,
        tied: tied,
        hints: [...hints, ..._disambiguationHints(tied)],
      );
    }
    return Resolution(
        locator: locator,
        snapshot: snapshot,
        status: ResolutionStatus.found,
        candidates: candidates,
        tied: tied,
        match: best.node,
        hints: hints);
  }

  /// Null when [node] does not satisfy [locator]; otherwise a match score.
  int? _score(UiNode node, Locator locator, [List<String>? reasons]) {
    var score = 0;
    void add(int points, String reason) {
      score += points;
      reasons?.add(reason);
    }

    if (locator.type != null) {
      final wanted = _baseType(locator.type!);
      if (_baseType(node.widgetType) == wanted) {
        add(3, 'type');
      } else if (node.wrapperTypes.map(_baseType).contains(wanted)) {
        add(3, 'wrapper type');
      } else {
        return null;
      }
    }
    if (locator.role != null) {
      if (node.role != locator.role) return null;
      add(1, 'role');
    }
    if (locator.text != null) {
      final wanted = locator.text!.trim();
      if (node.text == wanted) {
        add(4, 'text');
      } else if (node.texts.contains(wanted)) {
        add(3, 'text fragment');
      } else if (node.text.toLowerCase() == wanted.toLowerCase() ||
          node.texts.any((t) => t.toLowerCase() == wanted.toLowerCase())) {
        add(2, 'text (case-insensitive)');
      } else {
        return null;
      }
    }
    if (locator.textContains != null) {
      final wanted = locator.textContains!;
      if (node.text.contains(wanted)) {
        add(2, 'text contains');
      } else if (node.text.toLowerCase().contains(wanted.toLowerCase())) {
        add(1, 'text contains (case-insensitive)');
      } else {
        return null;
      }
    }
    if (locator.label != null) {
      final wanted = locator.label!.trim();
      final labels = [...node.labels, ?node.semanticsLabel, ?node.hint];
      if (labels.contains(wanted)) {
        add(4, 'label');
      } else if (labels.any((l) => l.toLowerCase() == wanted.toLowerCase())) {
        add(2, 'label (case-insensitive)');
      } else {
        return null;
      }
    }
    if (locator.semanticsLabel != null) {
      final actual = node.semanticsLabel;
      if (actual == locator.semanticsLabel) {
        add(4, 'semantics label');
      } else if (actual != null && actual.toLowerCase() == locator.semanticsLabel!.toLowerCase()) {
        add(2, 'semantics label (case-insensitive)');
      } else {
        return null;
      }
    }
    if (locator.key != null) {
      final k = node.keyDescription;
      if (k == null || !(k == locator.key || k == "[<'${locator.key}'>]" || k == '[<${locator.key}>]')) {
        return null;
      }
      add(5, 'key');
    }
    if (locator.within != null) {
      final container = node.ancestors.where((a) => _score(a, locator.within!) != null);
      if (container.isEmpty) return null;
      add(1, 'within');
    }
    return score;
  }

  bool matches(UiNode node, Locator locator) => _score(node, locator) != null;

  List<UiNode> _nearMisses(Locator locator, UiSnapshot snapshot) {
    final results = <UiNode>{};
    // Same type/role, different text or label.
    if (locator.type != null || locator.role != null) {
      final relaxed = Locator(type: locator.type, role: locator.role);
      results.addAll(snapshot.nodes.where((n) => _score(n, relaxed) != null).take(5));
    }
    // Similar text/label anywhere.
    final wanted = (locator.text ?? locator.textContains ?? locator.label ?? locator.semanticsLabel)?.toLowerCase();
    if (wanted != null) {
      for (final node in snapshot.nodes) {
        final values = [...node.texts, ...node.labels, ?node.semanticsLabel, ?node.hint].map((v) => v.toLowerCase());
        if (values.any((v) => v.contains(wanted) || wanted.contains(v) && v.length > 2 || _distance(v, wanted) <= 2)) {
          results.add(node);
        }
        if (results.length >= 10) break;
      }
    }
    return results.take(10).toList();
  }

  List<String> _notFoundHints(Locator locator, UiSnapshot snapshot, UiDiscovery? discovery) {
    final hints = <String>[];
    if (locator.within != null && !snapshot.nodes.any((n) => matches(n, locator.within!))) {
      hints.add('The "within" container itself was not found: ${locator.within!.describe()}.');
    }
    if (discovery != null && discovery.skipOffstage) {
      final everything = UiDiscovery(classifiers: discovery.classifiers, skipOffstage: false).capture();
      final offstage = everything.nodes.where((n) => matches(n, locator)).length;
      if (offstage > 0) {
        hints.add('$offstage matching element(s) exist offstage (an inactive route or an Offstage widget). '
            'Navigate to that screen first.');
      }
    }
    if (snapshot.nodes.any((n) => n.role == UiRole.scrollable)) {
      hints.add('Lazy lists only build visible items. If the element is further down a list, use scrollTo(...) first.');
    }
    hints.add('The UI may still be loading: use waitFor(...) or increase the timeout.');
    return hints;
  }

  List<String> _disambiguationHints(List<Candidate> tied) {
    final hints = <String>[];
    final ancestorTexts = <Candidate, UiNode?>{
      for (final c in tied) c: c.node.ancestors.where((a) => a.texts.isNotEmpty).firstOrNull,
    };
    final distinct = ancestorTexts.values.whereType<UiNode>().map((a) => a.texts.first).toSet();
    if (distinct.length == tied.length) {
      final example = ancestorTexts.values.first!;
      hints.add('Add structural context, e.g. within: Locator(type: \'${_baseType(example.widgetType)}\', '
          'text: \'${example.texts.first}\').');
    }
    final types = tied.map((c) => _baseType(c.node.widgetType)).toSet();
    if (types.length > 1) hints.add('Candidates have different types (${types.join(', ')}): add type: to the locator.');
    hints.add('If position really is what you mean, pass nth: 0..${tied.length - 1} explicitly.');
    return hints;
  }

  static String _baseType(String type) {
    final i = type.indexOf('<');
    return i < 0 ? type : type.substring(0, i);
  }

  static int _distance(String a, String b) {
    if ((a.length - b.length).abs() > 2) return 3;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        cur[j] = math.min(math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
      }
      prev = cur;
    }
    return prev[b.length];
  }
}

/// Exposes a [Locator] as a regular flutter_test [Finder], so it composes
/// with `expect(..., findsOneWidget)`, `find.descendant`, etc.
///
/// It re-runs discovery on every evaluation, so it never holds stale
/// elements. When the locator is ambiguous it yields all tied elements,
/// which makes `findsOneWidget` fail loudly rather than pick one.
class SmartFinder extends Finder {
  SmartFinder(this.locator, {UiDiscovery? discovery, this.resolver = const LocatorResolver()})
      : discovery = discovery ?? UiDiscovery(),
        super(skipOffstage: true);

  final Locator locator;
  final UiDiscovery discovery;
  final LocatorResolver resolver;

  @override
  String get description => locator.describe();

  @override
  String describeMatch(Plurality plurality) => 'element(s) matching ${locator.describe()}';

  @override
  Iterable<Element> findInCandidates(Iterable<Element> candidates) {
    final resolution = resolver.resolve(locator, discovery.capture());
    return switch (resolution.status) {
      ResolutionStatus.found => [resolution.match!.element],
      ResolutionStatus.ambiguous => resolution.tied.map((c) => c.node.element),
      ResolutionStatus.notFound => const <Element>[],
    };
  }
}
