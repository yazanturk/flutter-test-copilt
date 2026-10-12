import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'interactivity.dart';
import 'ui_node.dart';

/// Walks the mounted Element tree and produces a [UiSnapshot].
///
/// * Element tree: traversal order, ancestry, mounted state.
/// * Widget (via `element.widget`): type, text, callbacks, decoration.
/// * RenderObject (via `element.renderObject`): geometry and hit testing.
/// * Semantics (via `RenderObject.debugSemantics`, debug/profile only and
///   only while semantics are enabled): accessibility label.
///
/// Discovery is read-only: it never registers inherited-widget dependencies
/// or otherwise changes what the app rebuilds.
class UiDiscovery {
  UiDiscovery({this.classifiers = const <WidgetClassifier>[], this.skipOffstage = true});

  /// Custom classifiers, consulted before the built-in rules.
  final List<WidgetClassifier> classifiers;

  /// Skip `Offstage` subtrees and inactive routes, like flutter_test finders do.
  final bool skipOffstage;

  static int _generation = 0;

  /// The generation of the most recent snapshot taken by any [UiDiscovery].
  static int get currentGeneration => _generation;

  UiSnapshot capture() {
    final generation = ++_generation;
    final root = WidgetsBinding.instance.rootElement;
    final screen = _screenSize();
    if (root == null) {
      return UiSnapshot(generation: generation, nodes: const [], screenSize: screen);
    }
    final walker = _Walker(this, generation, screen);
    walker.visit(root, _Context.root);
    return UiSnapshot(generation: generation, nodes: walker.materialize(), screenSize: screen);
  }

  WidgetClassification? classify(Widget widget) {
    for (final classifier in classifiers) {
      final result = classifier(widget);
      if (result != null) return result;
    }
    return classifyWidget(widget);
  }

  static Size _screenSize() {
    final views = RendererBinding.instance.renderViews;
    return views.isEmpty ? Size.zero : views.first.size;
  }
}

/// Roles that gather visible text from their (non-interactive) descendants.
const Set<UiRole> _textCollectingContainers = {UiRole.listItem, UiRole.appBar, UiRole.dialog, UiRole.bottomSheet};

/// Container roles that a widget of the same role nests inside itself
/// (AlertDialog builds a Dialog) and which should not be reported twice.
const Set<UiRole> _singletonContainers = {UiRole.dialog, UiRole.appBar, UiRole.bottomSheet};

class _PendingNode {
  _PendingNode({
    required this.id,
    required this.element,
    required this.classification,
    required this.parent,
    required this.depth,
    required this.wrappers,
    required this.labels,
  });

  final String id;
  final Element element;
  final WidgetClassification classification;
  final _PendingNode? parent;
  final int depth;
  final List<String> wrappers;
  final List<String> labels;
  final List<String> texts = <String>[];
  String? value;
  bool obscured = false;
  UiNode? built;

  UiRole get role => classification.role;
  bool get atomic => classification.atomic;
  bool get ownsGestures => classification.actions.contains(UiAction.tap);
}

class _Context {
  const _Context({
    this.node,
    this.atomic,
    this.insideText = false,
    this.pendingLabels = const [],
    this.pendingWrappers = const [],
  });

  static const _Context root = _Context();

  final _PendingNode? node;
  final _PendingNode? atomic;
  final bool insideText;
  final List<String> pendingLabels;
  final List<String> pendingWrappers;

  _Context copyWith({
    _PendingNode? node,
    _PendingNode? atomic,
    bool? insideText,
    List<String>? pendingLabels,
    List<String>? pendingWrappers,
  }) {
    return _Context(
      node: node ?? this.node,
      atomic: atomic ?? this.atomic,
      insideText: insideText ?? this.insideText,
      pendingLabels: pendingLabels ?? this.pendingLabels,
      pendingWrappers: pendingWrappers ?? this.pendingWrappers,
    );
  }
}

class _Walker {
  _Walker(this.discovery, this.generation, this.screen);

  final UiDiscovery discovery;
  final int generation;
  final Size screen;
  final List<_PendingNode> pending = <_PendingNode>[];

  void visit(Element element, _Context ctx) {
    final widget = element.widget;
    var next = ctx;

    // --- Text: becomes a node unless it is the label of an atomic control.
    final text = _textOf(widget);
    if (text != null && !ctx.insideText) {
      final trimmed = text.trim();
      if (trimmed.isNotEmpty) {
        _contributeText(ctx, trimmed);
        final ownedByControl = ctx.atomic != null && ctx.atomic!.role != UiRole.textField;
        if (!ownedByControl) {
          final node = _create(element, const WidgetClassification(UiRole.text), ctx);
          node.texts.add(trimmed);
          next = next.copyWith(node: node);
        }
      }
      next = next.copyWith(insideText: true);
      _visitChildren(element, next);
      return;
    }

    // --- Icons render their glyph as RichText; that is not visible text.
    if (widget is Icon) {
      final semanticLabel = widget.semanticLabel?.trim();
      if (semanticLabel != null && semanticLabel.isNotEmpty) ctx.atomic?.labels.add(semanticLabel);
      _visitChildren(element, ctx.copyWith(insideText: true));
      return;
    }

    // --- Labels from Tooltip / Semantics / Image: attach to the owning control
    // or hand down to the next node.
    final label = _labelOf(widget);
    if (label != null && label.trim().isNotEmpty) {
      if (ctx.atomic != null) {
        ctx.atomic!.labels.add(label.trim());
      } else {
        next = next.copyWith(pendingLabels: [...ctx.pendingLabels, label.trim()]);
      }
    }

    // --- Form-field wrappers (TextFormField, DropdownButtonFormField…).
    if (widget is FormField && ctx.atomic == null) {
      next = next.copyWith(pendingWrappers: [...ctx.pendingWrappers, _typeName(widget)]);
    }

    // --- Text field value lives on the inner EditableText.
    if (widget is EditableText && ctx.atomic?.role == UiRole.textField) {
      final field = ctx.atomic!;
      field.obscured = widget.obscureText;
      // Never capture the value of an obscured field.
      field.value = widget.obscureText ? null : widget.controller.text;
      _visitChildren(element, next);
      return;
    }

    final classification = ctx.atomic == null ? discovery.classify(widget) : null;
    if (classification != null && !_suppressed(classification, ctx)) {
      final node = _create(element, classification, next);
      next = next.copyWith(
        node: node,
        atomic: classification.atomic ? node : null,
        pendingLabels: const [],
        pendingWrappers: const [],
      );
    }
    _visitChildren(element, next);
  }

  bool _suppressed(WidgetClassification c, _Context ctx) {
    final parent = ctx.node;
    if (parent == null) return false;
    // InkWell inside a ListTile is the ListTile's own gesture handler.
    if (c.generic && parent.ownsGestures) return true;
    if (_singletonContainers.contains(c.role) && parent.role == c.role) return true;
    return false;
  }

  void _visitChildren(Element element, _Context ctx) {
    void visitor(Element child) => visit(child, ctx);
    if (discovery.skipOffstage) {
      element.debugVisitOnstageChildren(visitor);
    } else {
      element.visitChildren(visitor);
    }
  }

  _PendingNode _create(Element element, WidgetClassification c, _Context ctx) {
    final node = _PendingNode(
      id: 's$generation:n${pending.length}',
      element: element,
      classification: c,
      parent: ctx.node,
      depth: ctx.node == null ? 0 : ctx.node!.depth + 1,
      wrappers: [...ctx.pendingWrappers],
      labels: [...c.labels, ...ctx.pendingLabels],
    );
    pending.add(node);
    return node;
  }

  void _contributeText(_Context ctx, String text) {
    // An atomic control (button, toggle…) owns its label text.
    final atomic = ctx.atomic;
    if (atomic != null) {
      if (atomic.role != UiRole.textField && atomic.texts.length < 10) atomic.texts.add(text);
      return;
    }
    // Containers (list items, dialogs, app bars) collect text for context.
    for (var n = ctx.node; n != null; n = n.parent) {
      if (_textCollectingContainers.contains(n.role) && n.texts.length < 10) n.texts.add(text);
      if (n.role == UiRole.listItem) break; // nearest list item is enough context
    }
  }

  List<UiNode> materialize() {
    final nodes = <UiNode>[];
    for (final p in pending) {
      final element = p.element;
      final geometry = _geometry(element);
      final texts = p.role == UiRole.textField ? [if (p.value != null && p.value!.isNotEmpty) p.value!] : p.texts;
      final node = UiNode(
        runtimeId: p.id,
        widgetType: _typeName(element.widget),
        role: p.role,
        actions: p.classification.actions,
        texts: List.unmodifiable(texts),
        labels: List.unmodifiable(p.labels.toSet()),
        wrapperTypes: List.unmodifiable(p.wrappers),
        hint: p.classification.hint,
        // A Text's semantics node is usually its container's merged node.
        semanticsLabel: p.role == UiRole.text ? null : _semanticsLabel(element),
        keyDescription: element.widget.key?.toString(),
        enabled: p.classification.enabled,
        obscured: p.obscured,
        depth: p.depth,
        elementDepth: element.depth,
        parentId: p.parent?.id,
        element: element,
        rect: geometry.rect,
        onScreen: geometry.onScreen,
        hitTestable: geometry.hitTestable,
      );
      p.built = node;
      final parent = p.parent?.built;
      if (parent != null) {
        node.parent = parent;
        parent.children.add(node);
      }
      nodes.add(node);
    }
    return nodes;
  }

  ({Rect? rect, bool onScreen, bool hitTestable}) _geometry(Element element) {
    final object = element.renderObject;
    if (object is! RenderBox || !object.attached || !object.hasSize) {
      return (rect: null, onScreen: false, hitTestable: false);
    }
    final topLeft = object.localToGlobal(Offset.zero);
    final rect = topLeft & object.size;
    final onScreen = rect.overlaps(Offset.zero & screen) && !rect.isEmpty;
    return (rect: rect, onScreen: onScreen, hitTestable: onScreen && isHitTestable(element));
  }

  String? _semanticsLabel(Element element) {
    if (!SemanticsBinding.instance.semanticsEnabled) return null;
    RenderObject? object = element.renderObject;
    var node = object?.debugSemantics;
    while (object != null && (node == null || node.isMergedIntoParent)) {
      object = object.parent;
      node = object?.debugSemantics;
    }
    final label = node?.getSemanticsData().label.replaceAll(RegExp(r'\s+'), ' ').trim();
    return (label == null || label.isEmpty) ? null : label;
  }
}

/// Whether a pointer down at the centre of [element] would reach it.
/// Mirrors flutter_test's `Finder.hitTestable()` for a single element.
bool isHitTestable(Element element, {Alignment at = Alignment.center}) {
  final object = element.renderObject;
  if (object is! RenderBox || !object.attached || !object.hasSize) return false;
  final view = element.findAncestorWidgetOfExactType<View>();
  if (view == null) return false;
  final position = object.localToGlobal(at.alongSize(object.size));
  final result = HitTestResult();
  WidgetsBinding.instance.hitTestInView(result, position, view.view.viewId);
  for (final entry in result.path) {
    final target = entry.target;
    if (target is! RenderObject) continue;
    for (RenderObject? o = target; o != null; o = o.parent) {
      if (identical(o, object)) return true;
    }
  }
  return false;
}

String _typeName(Widget widget) => widget.runtimeType.toString();

String? _textOf(Widget widget) {
  if (widget is Text) return widget.data ?? widget.textSpan?.toPlainText();
  if (widget is RichText) return widget.text.toPlainText();
  return null;
}

String? _labelOf(Widget widget) {
  if (widget is Tooltip) return widget.message;
  if (widget is Semantics) return widget.properties.label;
  if (widget is Image) return widget.semanticLabel;
  return null;
}
