import '../discovery/ui_node.dart';
import '../interaction/smart_tester.dart';
import '../locator/locator.dart';
import '../report/failure_report.dart';

/// The AI seam. An agent sees only sanitized JSON and answers with
/// deterministic [AgentCommand]s; it never touches the WidgetTester, the
/// shell, the network or real credentials. No implementation ships with the
/// MVP – the framework runs without any AI service.
abstract interface class TestAgent {
  /// Propose steps toward [goal] given a sanitized UI snapshot.
  Future<List<AgentCommand>> proposeSteps({required String goal, required Map<String, Object?> snapshot});

  /// Explain a failure from its sanitized report. Suggestions only – the
  /// runner never applies code changes.
  Future<String> analyzeFailure(Map<String, Object?> report);
}

/// Allow-listed commands. Anything else is rejected at parse time.
sealed class AgentCommand {
  const AgentCommand();

  static const Set<String> allowedOps = {'snapshot', 'tap', 'enterText', 'scrollTo', 'expectVisible', 'expectNotVisible'};

  /// Parses `{"op": "tap", "locator": {...}}` etc. Throws [FormatException]
  /// for unknown ops or malformed input.
  factory AgentCommand.fromJson(Map<String, Object?> json) {
    final op = json['op'];
    if (op is! String || !allowedOps.contains(op)) {
      throw FormatException('Command op "$op" is not allowed. Allowed: ${allowedOps.join(', ')}.');
    }
    Locator? locator() {
      final raw = json['locator'];
      return raw is Map ? Locator.fromJson(raw.cast<String, Object?>()) : null;
    }

    Locator requireLocator() => locator() ?? (throw FormatException('"$op" needs a "locator" object.'));
    return switch (op) {
      'snapshot' => const SnapshotCommand(),
      'tap' => json['id'] is String ? TapCommand.byId(json['id']! as String) : TapCommand(requireLocator()),
      'enterText' => EnterTextCommand(
          requireLocator(),
          text: json['text'] as String?,
          secretRef: json['secretRef'] as String?,
        ),
      'scrollTo' => ScrollToCommand(requireLocator()),
      'expectVisible' => ExpectVisibleCommand(requireLocator()),
      'expectNotVisible' => ExpectNotVisibleCommand(requireLocator()),
      _ => throw StateError('unreachable'),
    };
  }
}

class SnapshotCommand extends AgentCommand {
  const SnapshotCommand();
}

class TapCommand extends AgentCommand {
  const TapCommand(Locator this.locator) : id = null;
  const TapCommand.byId(String this.id) : locator = null;
  final Locator? locator;
  final String? id;
}

/// Either a literal (non-secret) [text] or a [secretRef] that the runner
/// resolves from secrets the *test author* supplied. The agent never sees
/// secret values.
class EnterTextCommand extends AgentCommand {
  const EnterTextCommand(this.locator, {this.text, this.secretRef})
      : assert((text == null) != (secretRef == null), 'Provide exactly one of text or secretRef');
  final Locator locator;
  final String? text;
  final String? secretRef;
}

class ScrollToCommand extends AgentCommand {
  const ScrollToCommand(this.locator);
  final Locator locator;
}

class ExpectVisibleCommand extends AgentCommand {
  const ExpectVisibleCommand(this.locator);
  final Locator locator;
}

class ExpectNotVisibleCommand extends AgentCommand {
  const ExpectNotVisibleCommand(this.locator);
  final Locator locator;
}

class CommandResult {
  const CommandResult({required this.ok, this.snapshot, this.report});
  final bool ok;

  /// Sanitized snapshot (for [SnapshotCommand]).
  final Map<String, Object?>? snapshot;

  /// Sanitized failure report when [ok] is false.
  final Map<String, Object?>? report;

  Map<String, Object?> toJson() => {'ok': ok, 'snapshot': ?snapshot, 'report': ?report};
}

/// Executes allow-listed commands through [SmartTester]. Failures are
/// returned as sanitized reports instead of being thrown, so an agent loop
/// can inspect them.
class CommandRunner {
  CommandRunner(this.smart, {Map<String, String> secrets = const {}}) : _secrets = Map.unmodifiable(secrets) {
    _secrets.values.forEach(smart.addSecret);
  }

  final SmartTester smart;
  final Map<String, String> _secrets;

  Future<CommandResult> run(AgentCommand command) async {
    try {
      switch (command) {
        case SnapshotCommand():
          final snapshot = smart.snapshot();
          return CommandResult(ok: true, snapshot: snapshot.toJson(sanitizer: smart.sanitizer));
        case TapCommand(:final id?):
          await smart.tapById(id);
        case TapCommand(:final locator):
          await smart.tap(locator: locator);
        case EnterTextCommand(:final locator, :final text, :final secretRef):
          final value = secretRef != null
              ? (_secrets[secretRef] ?? (throw ArgumentError('Unknown secretRef "$secretRef".')))
              : text!;
          await smart.enterText(locator: locator, text: value);
        case ScrollToCommand(:final locator):
          await smart.scrollTo(locator: locator);
        case ExpectVisibleCommand(:final locator):
          await smart.expectVisible(locator: locator);
        case ExpectNotVisibleCommand(:final locator):
          await smart.expectNotVisible(locator: locator);
      }
      return const CommandResult(ok: true);
    } on SmartTesterException catch (e) {
      return CommandResult(ok: false, report: e.report.toJson());
    }
  }

  Future<List<CommandResult>> runAll(Iterable<AgentCommand> commands, {bool stopOnFailure = true}) async {
    final results = <CommandResult>[];
    for (final c in commands) {
      final r = await run(c);
      results.add(r);
      if (!r.ok && stopOnFailure) break;
    }
    return results;
  }
}

/// Convenience for agents: the interactive part of a snapshot only.
Map<String, Object?> agentView(UiSnapshot snapshot, SmartTester smart) =>
    snapshot.toJson(sanitizer: smart.sanitizer, interactiveOnly: true);
