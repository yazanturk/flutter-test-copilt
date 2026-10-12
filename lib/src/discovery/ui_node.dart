import 'package:flutter/widgets.dart';

import 'sanitizer.dart';

/// What a discovered element *is*, independent of its concrete widget type.
enum UiRole {
  button,
  textField,
  toggle,
  dropdown,
  slider,
  listItem,
  tab,
  menu,
  dialog,
  bottomSheet,
  appBar,
  scrollable,
  image,
  text,
}

/// What a test can *do* with a discovered element.
enum UiAction { tap, enterText, scroll }

/// A structured, serializable description of one discovered UI element.
///
/// A node is built from the Element tree (identity, ancestry), the Widget it
/// currently holds (type, text, callbacks), its RenderObject (geometry,
/// hit-testability) and – when semantics are enabled – its Semantics node
/// (accessibility label and flags). These are four different trees; the node
/// records which signal came from where.
///
/// [runtimeId] is only meaningful inside the [UiSnapshot] that produced it.
/// It is NOT stable across app launches, snapshots, or rebuilds.
class UiNode {
  UiNode({
    required this.runtimeId,
    required this.widgetType,
    required this.role,
    required this.actions,
    required this.texts,
    required this.labels,
    required this.wrapperTypes,
    required this.depth,
    required this.elementDepth,
    required this.parentId,
    required this.element,
    this.hint,
    this.semanticsLabel,
    this.keyDescription,
    this.enabled,
    this.obscured = false,
    this.rect,
    this.onScreen = false,
    this.hitTestable = false,
  });

  final String runtimeId;

  /// `runtimeType` of the widget, e.g. `ElevatedButton`, `DropdownButton<String>`.
  final String widgetType;

  /// Enclosing form/compound widget types that this node stands for, e.g. a
  /// `TextField` built by a `TextFormField` records `TextFormField` here.
  final List<String> wrapperTypes;

  final UiRole role;
  final Set<UiAction> actions;

  /// Visible text fragments owned by this node (for a button: its label; for
  /// a text field: its current value, never captured when obscured).
  final List<String> texts;

  /// Labels: InputDecoration.labelText, tooltips, `Semantics(label:)`.
  final List<String> labels;
  final String? hint;

  /// Label from the Semantics tree, when semantics are enabled.
  final String? semanticsLabel;

  /// `toString()` of the widget's Key, if the developer happened to set one.
  final String? keyDescription;

  final bool? enabled;
  final bool obscured;

  /// Global, logical-pixel bounds of the RenderBox, when laid out.
  final Rect? rect;
  final bool onScreen;

  /// Whether a pointer event at the centre would reach this element (i.e. it
  /// is not covered by a dialog barrier, another route, etc.).
  final bool hitTestable;

  /// Depth among discovered nodes; [elementDepth] is the raw Element depth.
  final int depth;
  final int elementDepth;
  final String? parentId;

  /// Live element for the duration of the snapshot. Never serialized.
  final Element element;

  final List<UiNode> children = <UiNode>[];
  UiNode? parent;

  String get text => texts.join(' ');
  bool get isInteractive => actions.isNotEmpty;
  int get siblingIndex => parent?.children.indexOf(this) ?? 0;

  Iterable<UiNode> get ancestors sync* {
    var current = parent;
    while (current != null) {
      yield current;
      current = current.parent;
    }
  }

  bool isDescendantOf(UiNode other) => ancestors.contains(other);

  /// Short human-readable label, e.g. `ElevatedButton "Login"`.
  String describe([Sanitizer sanitizer = const Sanitizer()]) {
    final buffer = StringBuffer(widgetType);
    if (texts.isNotEmpty) {
      buffer.write(' "${sanitizer.text(text)}"');
    }
    final label = labels.isNotEmpty ? labels.first : semanticsLabel;
    if (label != null && label != text) {
      buffer.write(' [label: ${sanitizer.text(label)}]');
    }
    return buffer.toString();
  }

  /// Ancestor chain of meaningful nodes, outermost first.
  String path([Sanitizer sanitizer = const Sanitizer()]) {
    final chain = ancestors.toList().reversed.map((n) => n.describe(sanitizer));
    return [...chain, describe(sanitizer)].join(' > ');
  }

  Map<String, Object?> toJson([Sanitizer sanitizer = const Sanitizer()]) {
    return <String, Object?>{
      'id': runtimeId,
      'type': widgetType,
      if (wrapperTypes.isNotEmpty) 'wrapperTypes': wrapperTypes,
      'role': role.name,
      if (actions.isNotEmpty) 'actions': actions.map((a) => a.name).toList(),
      if (texts.isNotEmpty) 'text': obscured ? Sanitizer.redacted : sanitizer.text(text),
      if (labels.isNotEmpty) 'labels': labels.map(sanitizer.text).toList(),
      if (hint != null) 'hint': sanitizer.text(hint!),
      if (semanticsLabel != null) 'semanticsLabel': sanitizer.text(semanticsLabel!),
      if (keyDescription != null) 'key': keyDescription,
      if (enabled != null) 'enabled': enabled,
      if (obscured) 'obscured': true,
      if (rect != null)
        'rect': <String, double>{
          'left': _round(rect!.left),
          'top': _round(rect!.top),
          'width': _round(rect!.width),
          'height': _round(rect!.height),
        },
      'onScreen': onScreen,
      'hitTestable': hitTestable,
      'depth': depth,
      if (parentId != null) 'parent': parentId,
      if (parent != null) 'siblingIndex': siblingIndex,
    };
  }

  static double _round(double v) => (v * 10).roundToDouble() / 10;

  @override
  String toString() => '$runtimeId ${describe()}';
}

/// The result of one discovery pass. Node ids are scoped to [generation].
class UiSnapshot {
  UiSnapshot({required this.generation, required this.nodes, required this.screenSize});

  final int generation;
  final List<UiNode> nodes;
  final Size screenSize;

  late final Map<String, UiNode> _byId = {for (final n in nodes) n.runtimeId: n};

  UiNode? byId(String id) => _byId[id];

  Iterable<UiNode> get roots => nodes.where((n) => n.parent == null);
  Iterable<UiNode> get interactive => nodes.where((n) => n.isInteractive);

  /// Sanitized, LLM/agent-safe representation of the snapshot.
  Map<String, Object?> toJson({Sanitizer sanitizer = const Sanitizer(), bool interactiveOnly = false}) {
    final selected = interactiveOnly ? interactive : nodes;
    return <String, Object?>{
      'generation': generation,
      'screen': {'width': screenSize.width, 'height': screenSize.height},
      'nodeCount': nodes.length,
      'nodes': selected.map((n) => n.toJson(sanitizer)).toList(),
    };
  }

  /// Indented outline, useful in failure reports and while writing tests.
  String toOutline({Sanitizer sanitizer = const Sanitizer(), int maxNodes = 200}) {
    final buffer = StringBuffer();
    var count = 0;
    void write(UiNode node, int indent) {
      if (count++ >= maxNodes) return;
      final flags = <String>[
        if (node.isInteractive) node.actions.map((a) => a.name).join('/'),
        if (!node.onScreen) 'off-screen',
        if (node.onScreen && !node.hitTestable) 'obscured',
        if (node.enabled == false) 'disabled',
      ];
      buffer.writeln('${'  ' * indent}${node.runtimeId} ${node.describe(sanitizer)}'
          '${flags.isEmpty ? '' : '  (${flags.join(', ')})'}');
      for (final child in node.children) {
        write(child, indent + 1);
      }
    }

    for (final root in roots) {
      write(root, 0);
    }
    if (count > maxNodes) buffer.writeln('… ${count - maxNodes} more nodes omitted');
    return buffer.toString();
  }
}
