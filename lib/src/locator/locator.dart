import '../discovery/ui_node.dart';

/// A declarative description of the element a test wants.
///
/// All given fields must match. When several elements match equally well,
/// resolution fails with an ambiguity error instead of picking one; narrow
/// the locator with [within] (structural context) or, as a last resort,
/// [nth] (explicit, positional).
class Locator {
  const Locator({
    this.type,
    this.role,
    this.text,
    this.textContains,
    this.label,
    this.semanticsLabel,
    this.key,
    this.within,
    this.nth,
  }) : assert(nth == null || nth >= 0);

  /// Widget type name, e.g. `ElevatedButton`. Generic arguments are ignored
  /// (`DropdownButton` matches `DropdownButton<String>`). Also matches
  /// form-field wrappers such as `TextFormField`.
  final String? type;
  final UiRole? role;

  /// Exact visible text (whitespace-trimmed). Case-insensitive matches are
  /// accepted but rank lower than exact ones.
  final String? text;
  final String? textContains;

  /// Field label, tooltip, `Semantics(label:)`, semantics-tree label or hint.
  final String? label;

  /// Label from the Semantics tree only.
  final String? semanticsLabel;

  /// Optional fallback: matches `Key.toString()` or a `ValueKey`'s value.
  final String? key;

  /// Structural context: the element must have an ancestor matching this.
  final Locator? within;

  /// Explicit zero-based pick among equally ranked candidates in document
  /// order. Positional and therefore fragile – prefer [within].
  final int? nth;

  bool get isEmpty =>
      type == null &&
      role == null &&
      text == null &&
      textContains == null &&
      label == null &&
      semanticsLabel == null &&
      key == null &&
      within == null;

  Locator copyWith({UiRole? role, Locator? within, int? nth}) => Locator(
        type: type,
        role: role ?? this.role,
        text: text,
        textContains: textContains,
        label: label,
        semanticsLabel: semanticsLabel,
        key: key,
        within: within ?? this.within,
        nth: nth ?? this.nth,
      );

  /// Locators are code, not data, but they may contain user-visible text;
  /// [redact] lets reports hide it.
  String describe([String Function(String) redact = _identity]) {
    final parts = <String>[
      if (type != null) 'type: $type',
      if (role != null) 'role: ${role!.name}',
      if (text != null) 'text: "${redact(text!)}"',
      if (textContains != null) 'textContains: "${redact(textContains!)}"',
      if (label != null) 'label: "${redact(label!)}"',
      if (semanticsLabel != null) 'semanticsLabel: "${redact(semanticsLabel!)}"',
      if (key != null) 'key: $key',
      if (within != null) 'within: ${within!.describe(redact)}',
      if (nth != null) 'nth: $nth',
    ];
    return 'Locator(${parts.join(', ')})';
  }

  Map<String, Object?> toJson() => {
        if (type != null) 'type': type,
        if (role != null) 'role': role!.name,
        if (text != null) 'text': text,
        if (textContains != null) 'textContains': textContains,
        if (label != null) 'label': label,
        if (semanticsLabel != null) 'semanticsLabel': semanticsLabel,
        if (key != null) 'key': key,
        if (within != null) 'within': within!.toJson(),
        if (nth != null) 'nth': nth,
      };

  factory Locator.fromJson(Map<String, Object?> json) {
    final roleName = json['role'] as String?;
    final within = json['within'];
    return Locator(
      type: json['type'] as String?,
      role: roleName == null ? null : UiRole.values.byName(roleName),
      text: json['text'] as String?,
      textContains: json['textContains'] as String?,
      label: json['label'] as String?,
      semanticsLabel: json['semanticsLabel'] as String?,
      key: json['key'] as String?,
      within: within == null ? null : Locator.fromJson((within as Map).cast<String, Object?>()),
      nth: json['nth'] as int?,
    );
  }

  @override
  String toString() => describe();
}

String _identity(String s) => s;
