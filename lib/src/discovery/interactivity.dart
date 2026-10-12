import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'ui_node.dart';

/// How the discovery walker should treat one widget.
class WidgetClassification {
  const WidgetClassification(
    this.role, {
    this.actions = const <UiAction>{},
    this.enabled,
    this.labels = const <String>[],
    this.hint,
    this.atomic = false,
    this.generic = false,
  });

  final UiRole role;
  final Set<UiAction> actions;
  final bool? enabled;
  final List<String> labels;
  final String? hint;

  /// Atomic controls own their whole subtree: nested buttons/ink/text inside
  /// them are implementation details (e.g. the InkWell inside ElevatedButton)
  /// and are folded into this node instead of becoming nodes themselves.
  final bool atomic;

  /// Generic gesture widgets (InkWell, GestureDetector) only become nodes
  /// when no more specific interactive node already owns them.
  final bool generic;
}

/// Lets apps teach discovery about custom widgets. Return null to fall
/// through to the built-in rules.
typedef WidgetClassifier = WidgetClassification? Function(Widget widget);

const Set<UiAction> _tap = <UiAction>{UiAction.tap};

/// Built-in rules for Material, Cupertino and core widgets. Every check is a
/// plain `is` test against public widget classes and public fields, so it
/// does not depend on framework internals.
WidgetClassification? classifyWidget(Widget w) {
  // Buttons. BackButton & co. subclass IconButton with a null onPressed (they
  // pop the route by default), so they must be checked first.
  if (w is BackButton || w is CloseButton || w is DrawerButton || w is EndDrawerButton) {
    return const WidgetClassification(UiRole.button, actions: _tap, atomic: true);
  }
  if (w is ButtonStyleButton) {
    return WidgetClassification(UiRole.button,
        actions: _tap, enabled: w.onPressed != null || w.onLongPress != null, atomic: true);
  }
  if (w is IconButton) {
    return WidgetClassification(UiRole.button,
        actions: _tap, enabled: w.onPressed != null, labels: [?w.tooltip], atomic: true);
  }
  if (w is FloatingActionButton) {
    return WidgetClassification(UiRole.button,
        actions: _tap, enabled: w.onPressed != null, labels: [?w.tooltip], atomic: true);
  }
  if (w is CupertinoButton) {
    return WidgetClassification(UiRole.button, actions: _tap, enabled: w.onPressed != null, atomic: true);
  }
  if (w is NavigationDestination) {
    return WidgetClassification(UiRole.tab, actions: _tap, enabled: w.enabled, labels: [w.label], atomic: true);
  }

  // Menus and dropdowns.
  if (w is PopupMenuButton) {
    return WidgetClassification(UiRole.menu,
        actions: _tap, enabled: w.enabled, labels: [?w.tooltip], atomic: true);
  }
  if (w is PopupMenuItem) {
    return WidgetClassification(UiRole.menu, actions: _tap, enabled: w.enabled, atomic: true);
  }
  if (w is DropdownButton) {
    return WidgetClassification(UiRole.dropdown,
        actions: _tap, enabled: w.onChanged != null, hint: _plainText(w.hint), atomic: true);
  }
  if (w is DropdownMenu) {
    return WidgetClassification(UiRole.dropdown,
        actions: _tap, enabled: w.enabled, labels: [?_plainText(w.label)], hint: w.hintText, atomic: true);
  }
  if (w is DropdownMenuItem) {
    return WidgetClassification(UiRole.menu, actions: _tap, enabled: w.enabled, atomic: true);
  }

  // Toggles.
  if (w is Checkbox) {
    return WidgetClassification(UiRole.toggle, actions: _tap, enabled: w.onChanged != null, atomic: true);
  }
  if (w is Switch) {
    return WidgetClassification(UiRole.toggle, actions: _tap, enabled: w.onChanged != null, atomic: true);
  }
  if (w is CheckboxListTile || w is SwitchListTile || w is RadioListTile || w is Radio || w is CupertinoSwitch) {
    return const WidgetClassification(UiRole.toggle, actions: _tap, atomic: true);
  }
  if (w is Slider) {
    return WidgetClassification(UiRole.slider, actions: _tap, enabled: w.onChanged != null, atomic: true);
  }

  // Text input. The value is read from the inner EditableText by the walker.
  if (w is TextField) {
    return WidgetClassification(UiRole.textField,
        actions: const {UiAction.tap, UiAction.enterText},
        enabled: w.enabled ?? w.decoration?.enabled ?? true,
        labels: [?w.decoration?.labelText, ?_plainText(w.decoration?.label)],
        hint: w.decoration?.hintText,
        atomic: true);
  }
  if (w is CupertinoTextField) {
    return WidgetClassification(UiRole.textField,
        actions: const {UiAction.tap, UiAction.enterText}, enabled: w.enabled, hint: w.placeholder, atomic: true);
  }
  if (w is EditableText) {
    return const WidgetClassification(UiRole.textField,
        actions: {UiAction.tap, UiAction.enterText}, atomic: true);
  }

  // Containers that give context.
  if (w is ListTile) {
    final tappable = w.onTap != null || w.onLongPress != null;
    return WidgetClassification(UiRole.listItem, actions: tappable ? _tap : const {}, enabled: w.enabled);
  }
  if (w is AlertDialog || w is SimpleDialog || w is Dialog || w is CupertinoAlertDialog) {
    return const WidgetClassification(UiRole.dialog);
  }
  if (w is BottomSheet) return const WidgetClassification(UiRole.bottomSheet);
  if (w is AppBar || w is SliverAppBar || w is CupertinoNavigationBar) {
    return const WidgetClassification(UiRole.appBar);
  }
  if (w is Scrollable) {
    return const WidgetClassification(UiRole.scrollable, actions: {UiAction.scroll});
  }

  // Generic gesture handlers.
  if (w is InkResponse) {
    if (w.onTap == null && w.onLongPress == null) return null;
    return const WidgetClassification(UiRole.button, actions: _tap, generic: true);
  }
  if (w is GestureDetector) {
    if (w.onTap == null && w.onLongPress == null) return null;
    return const WidgetClassification(UiRole.button, actions: _tap, generic: true);
  }
  return null;
}

String? _plainText(Widget? widget) {
  if (widget is Text) return widget.data ?? widget.textSpan?.toPlainText();
  return null;
}
