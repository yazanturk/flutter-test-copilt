import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_flutter_tester/smart_flutter_tester.dart';

Widget app(Widget home) => MaterialApp(home: home);

/// Short waits keep failure-path tests fast (fake async anyway).
SmartTester smartFor(WidgetTester tester, {FailureCallback? onFailure}) =>
    SmartTester(tester, timeout: const Duration(milliseconds: 300), onFailure: onFailure);

class Counter extends StatefulWidget {
  const Counter({super.key, required this.builder});
  final Widget Function(int count, VoidCallback increment) builder;
  @override
  State<Counter> createState() => _CounterState();
}

class _CounterState extends State<Counter> {
  int count = 0;
  @override
  Widget build(BuildContext context) => widget.builder(count, () => setState(() => count++));
}

void main() {
  group('discovery', () {
    testWidgets('discovers a button without a Key', (tester) async {
      await tester.pumpWidget(app(Scaffold(body: Center(child: ElevatedButton(onPressed: () {}, child: const Text('Login'))))));
      final snapshot = SmartTester(tester).snapshot();

      final buttons = snapshot.nodes.where((n) => n.role == UiRole.button).toList();
      expect(buttons, hasLength(1));
      final button = buttons.single;
      expect(button.widgetType, 'ElevatedButton');
      expect(button.text, 'Login');
      expect(button.actions, contains(UiAction.tap));
      expect(button.keyDescription, isNull);
      expect(button.enabled, isTrue);
      expect(button.hitTestable, isTrue);
      expect(button.rect, isNotNull);
      // Its label is folded into the button, not reported as a separate node,
      // and the button's internal InkWell is not reported either.
      expect(snapshot.nodes.where((n) => n.text == 'Login'), hasLength(1));
      expect(snapshot.nodes.where((n) => n.widgetType == 'InkWell'), isEmpty);
    });

    testWidgets('discovers a text field without a Key, with label, hint and wrapper type', (tester) async {
      await tester.pumpWidget(app(Scaffold(
        body: Form(
          child: TextFormField(decoration: const InputDecoration(labelText: 'Email', hintText: 'you@company.com')),
        ),
      )));
      final field = SmartTester(tester).snapshot().nodes.singleWhere((n) => n.role == UiRole.textField);
      expect(field.widgetType, 'TextField');
      expect(field.wrapperTypes, ['TextFormField']);
      expect(field.labels, contains('Email'));
      expect(field.hint, 'you@company.com');
      expect(field.actions, containsAll([UiAction.tap, UiAction.enterText]));
    });

    testWidgets('records parent/ancestor context, depth and sibling index', (tester) async {
      await tester.pumpWidget(app(Scaffold(
        body: ListView(children: [
          for (final name in ['Alpha', 'Beta'])
            ListTile(title: Text(name), trailing: TextButton(onPressed: () {}, child: const Text('Edit'))),
        ]),
      )));
      final snapshot = SmartTester(tester).snapshot();
      final edit = snapshot.nodes.where((n) => n.text == 'Edit').toList();
      expect(edit, hasLength(2));
      expect(edit[1].parent!.widgetType, 'ListTile');
      expect(edit[1].parent!.text, 'Beta');
      expect(edit[1].ancestors.map((a) => a.role), contains(UiRole.scrollable));
      expect(edit[1].depth, greaterThan(edit[1].parent!.depth));
      expect(edit[1].path(), contains('ListTile "Beta" > TextButton "Edit"'));
      expect(snapshot.byId(edit[1].runtimeId), same(edit[1]));
    });

    testWidgets('snapshot JSON is serializable and the outline is readable', (tester) async {
      await tester.pumpWidget(app(Scaffold(
        appBar: AppBar(title: const Text('Home')),
        body: ElevatedButton(onPressed: null, child: const Text('Disabled')),
      )));
      final smart = SmartTester(tester);
      final json = jsonEncode(smart.snapshot().toJson());
      expect(json, contains('"role":"appBar"'));
      expect(smart.describeUi(), contains('ElevatedButton "Disabled"  (tap, disabled)'));
    });
  });

  group('locator', () {
    testWidgets('taps a button by type and text', (tester) async {
      await tester.pumpWidget(app(Counter(
        builder: (count, inc) => Scaffold(
          body: Column(children: [
            Text('Count: $count'),
            OutlinedButton(onPressed: inc, child: const Text('Increment')),
            OutlinedButton(onPressed: () {}, child: const Text('Other')),
          ]),
        ),
      )));
      final smart = smartFor(tester);
      await smart.tap(type: 'OutlinedButton', text: 'Increment');
      await smart.expectVisible(text: 'Count: 1');
    });

    testWidgets('enters text by label and verifies the result', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(app(Scaffold(
        body: Column(children: [
          TextField(controller: controller, decoration: const InputDecoration(labelText: 'Email')),
          const TextField(decoration: InputDecoration(labelText: 'Name')),
        ]),
      )));
      final smart = smartFor(tester);
      await smart.enterText(label: 'Email', text: 'a@b.co');
      expect(controller.text, 'a@b.co');
      // The field's value is now visible to discovery (and sanitized in output).
      final field = smart.snapshot().nodes.firstWhere((n) => n.labels.contains('Email'));
      expect(field.text, 'a@b.co');
      expect(field.toJson()['text'], '<email>');
    });

    testWidgets('duplicate buttons: refuses to guess, then resolves via parent context', (tester) async {
      final added = <String>[];
      await tester.pumpWidget(app(Scaffold(
        body: ListView(children: [
          for (final item in ['Apples', 'Bananas', 'Cherries'])
            ListTile(title: Text(item), trailing: ElevatedButton(onPressed: () => added.add(item), child: const Text('Add'))),
        ]),
      )));
      final smart = smartFor(tester);

      final error = await _throws<AmbiguousLocatorException>(() => smart.tap(text: 'Add'));
      expect(added, isEmpty, reason: 'must not tap anything when ambiguous');
      expect(error.report.resolution!.tied, hasLength(3));
      expect(error.toString(), contains('3 equally good candidates'));
      expect(error.toString(), contains("within: Locator(type: 'ListTile', text: 'Apples')"));

      await smart.tap(text: 'Add', within: const Locator(type: 'ListTile', text: 'Bananas'));
      expect(added, ['Bananas']);

      // Explicit positional choice is allowed, but only when asked for.
      await smart.tap(text: 'Add', nth: 2);
      expect(added, ['Bananas', 'Cherries']);
    });

    testWidgets('missing element: actionable not-found diagnostics', (tester) async {
      FailureReport? reported;
      await tester.pumpWidget(app(Scaffold(body: ElevatedButton(onPressed: () {}, child: const Text('Login')))));
      final smart = smartFor(tester, onFailure: (r) => reported = r);

      final error = await _throws<ElementNotFoundException>(() => smart.tap(type: 'ElevatedButton', text: 'Logn'));
      final text = error.toString();
      expect(text, contains('No element matches the locator'));
      expect(text, contains('Locator(type: ElevatedButton, text: "Logn")'));
      expect(text, contains('Closest elements on screen'));
      expect(text, contains('ElevatedButton "Login"'));
      expect(text, contains('waitFor'));
      expect(reported, isNotNull);
      final json = jsonDecode(reported!.toJsonString()) as Map<String, Object?>;
      expect(json['kind'], 'notFound');
      expect((json['nearMisses']! as List).first, containsPair('text', 'Login'));
    });

    testWidgets('survives rebuilds that replace the element', (tester) async {
      await tester.pumpWidget(app(Counter(
        builder: (count, inc) {
          final button = TextButton(onPressed: inc, child: Text(count.isEven ? 'Even' : 'Odd'));
          // Change the tree shape on every tap so the button's Element is replaced.
          return Scaffold(body: Center(child: count.isEven ? button : Padding(padding: const EdgeInsets.all(8), child: button)));
        },
      )));
      final smart = smartFor(tester);
      final before = smart.snapshot().nodes.singleWhere((n) => n.text == 'Even');

      await smart.tap(text: 'Even');
      await smart.tap(text: 'Odd');
      await smart.expectVisible(type: 'TextButton', text: 'Even');

      expect(before.element.mounted, isFalse);
      expect(() => smart.nodeById(before.runtimeId), throwsA(isA<StaleElementException>()));
      final fresh = smart.snapshot().nodes.singleWhere((n) => n.text == 'Even');
      await smart.tapById(fresh.runtimeId);
      await smart.expectVisible(text: 'Odd');
    });

    testWidgets('off-screen lazy list items: not found until scrolled to', (tester) async {
      final tapped = <int>[];
      await tester.pumpWidget(app(Scaffold(
        body: ListView.builder(
          itemCount: 200,
          itemBuilder: (_, i) => ListTile(title: Text('Row $i'), onTap: () => tapped.add(i)),
        ),
      )));
      final smart = smartFor(tester);

      final error = await _throws<ElementNotFoundException>(() => smart.expectVisible(text: 'Row 150'));
      expect(error.toString(), contains('scrollTo'));

      final node = await smart.scrollTo(text: 'Row 150');
      expect(node.hitTestable, isTrue);
      await smart.tap(text: 'Row 150');
      expect(tapped, [150]);
    });

    testWidgets('dialogs: covered page elements lose to the dialog; within role works', (tester) async {
      var deleted = false;
      await tester.pumpWidget(app(Builder(
        builder: (context) => Scaffold(
          body: Column(children: [
            ElevatedButton(onPressed: () {}, child: const Text('Delete')),
            ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('Are you sure?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
                    ElevatedButton(
                        onPressed: () {
                          deleted = true;
                          Navigator.pop(dialogContext);
                        },
                        child: const Text('Delete')),
                  ],
                ),
              ),
              child: const Text('Open'),
            ),
          ]),
        ),
      )));
      final smart = smartFor(tester);
      // Without the dialog, two buttons are not equally plausible: only one says Delete.
      await smart.tap(text: 'Open');
      await smart.expectVisible(role: UiRole.dialog, textContains: 'Are you sure?');

      final page = smart.snapshot().nodes.firstWhere((n) => n.text == 'Delete' && n.parent?.role != UiRole.dialog);
      expect(page.hitTestable, isFalse, reason: 'covered by the modal barrier');

      final resolution = smart.resolve(const Locator(text: 'Delete'));
      expect(resolution.status, ResolutionStatus.found);
      expect(resolution.match!.ancestors.any((a) => a.role == UiRole.dialog), isTrue);
      expect(resolution.hints.single, contains('covered'));

      await smart.tap(text: 'Delete', within: const Locator(role: UiRole.dialog));
      expect(deleted, isTrue);
      await smart.expectNotVisible(role: UiRole.dialog);
    });

    testWidgets('navigation: push a route, go back with the implicit BackButton', (tester) async {
      await tester.pumpWidget(app(Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                    builder: (_) => Scaffold(appBar: AppBar(title: const Text('Details')), body: const Text('Detail body')))),
            child: const Text('Go'),
          ),
        ),
      )));
      final smart = smartFor(tester);
      await smart.tap(text: 'Go');
      await smart.expectVisible(text: 'Detail body');
      // The previous route is offstage and therefore not part of discovery.
      expect(smart.resolve(const Locator(text: 'Go')).status, ResolutionStatus.notFound);
      final offstage = await _throws<ElementNotFoundException>(() => smart.tap(text: 'Go'));
      expect(offstage.toString(), contains('offstage'));

      await smart.tap(type: 'BackButton');
      await smart.expectVisible(text: 'Go');
    });

    testWidgets('async loading: waits through a never-ending spinner without hanging', (tester) async {
      await tester.pumpWidget(app(Scaffold(
        body: FutureBuilder<String>(
          future: Future.delayed(const Duration(seconds: 2), () => 'Loaded'),
          builder: (_, s) => s.hasData ? Text(s.data!) : const CircularProgressIndicator(),
        ),
      )));
      final smart = SmartTester(tester, timeout: const Duration(seconds: 5));
      await smart.expectVisible(text: 'Loaded');
    });

    testWidgets('a disabled button is reported, not tapped', (tester) async {
      await tester.pumpWidget(app(const Scaffold(body: ElevatedButton(onPressed: null, child: Text('Submit')))));
      final error = await _throws<ElementNotInteractableException>(() => smartFor(tester).tap(text: 'Submit'));
      expect(error.toString(), contains('disabled'));
    });

    testWidgets('keys are an optional fallback, and SmartFinder composes with flutter_test', (tester) async {
      await tester.pumpWidget(app(Scaffold(
        body: Column(children: [
          ElevatedButton(key: const ValueKey('save'), onPressed: () {}, child: const Text('Save')),
          ElevatedButton(onPressed: () {}, child: const Text('Save')),
        ]),
      )));
      final smart = smartFor(tester);
      expect(smart.finder(const Locator(key: 'save')), findsOneWidget);
      expect(smart.finder(const Locator(text: 'Save')), findsNWidgets(2)); // ambiguous => both, never one
      expect(smart.finder(const Locator(text: 'Nope')), findsNothing);
    });

    testWidgets('labels from tooltips and semantics identify icon-only buttons', (tester) async {
      var searched = false;
      await tester.pumpWidget(app(Scaffold(
        appBar: AppBar(actions: [
          IconButton(tooltip: 'Search', onPressed: () => searched = true, icon: const Icon(Icons.search)),
          Semantics(label: 'Profile', child: IconButton(onPressed: () {}, icon: const Icon(Icons.person))),
        ]),
      )));
      final smart = smartFor(tester);
      await smart.tap(label: 'Search');
      expect(searched, isTrue);
      expect(smart.resolve(const Locator(label: 'Profile')).match?.widgetType, 'IconButton');
    });
  });

  group('sanitization', () {
    testWidgets('obscured values never reach snapshots or reports', (tester) async {
      await tester.pumpWidget(app(const Scaffold(
        body: Column(children: [
          TextField(decoration: InputDecoration(labelText: 'Password'), obscureText: true),
        ]),
      )));
      final smart = smartFor(tester);
      await smart.enterText(label: 'Password', text: 'hunter2-secret');
      final json = jsonEncode(smart.snapshot().toJson(sanitizer: const Sanitizer.none()));
      expect(json, isNot(contains('hunter2-secret')));

      final error = await _throws<ElementNotFoundException>(() => smart.tap(text: 'hunter2-secret'));
      expect(error.toString(), isNot(contains('hunter2-secret')));
      expect(error.report.toJsonString(), isNot(contains('hunter2-secret')));
    });

    test('redacts emails, long numbers and registered secrets', () {
      const s = Sanitizer(secrets: {'tok_123'});
      expect(s.text('Hi jane.doe@example.com'), 'Hi <email>');
      expect(s.text('Card 4242 4242 4242 4242'), 'Card <number>');
      expect(s.text('Order 12'), 'Order 12');
      expect(s.text('token tok_123'), 'token <redacted>');
    });
  });

  group('agent seam', () {
    testWidgets('runs allow-listed JSON commands and returns sanitized failures', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(app(Counter(
        builder: (count, inc) => Scaffold(
          body: Column(children: [
            TextField(controller: controller, obscureText: true, decoration: const InputDecoration(labelText: 'PIN')),
            ElevatedButton(onPressed: inc, child: const Text('Go')),
            Text('Pressed $count'),
          ]),
        ),
      )));
      final runner = CommandRunner(smartFor(tester), secrets: {'pin': '987654'});
      final commands = [
        {'op': 'snapshot'},
        {'op': 'enterText', 'locator': {'label': 'PIN'}, 'secretRef': 'pin'},
        {'op': 'tap', 'locator': {'type': 'ElevatedButton', 'text': 'Go'}},
        {'op': 'expectVisible', 'locator': {'text': 'Pressed 1'}},
        {'op': 'tap', 'locator': {'text': 'Missing'}},
      ].map(AgentCommand.fromJson);

      final results = await runner.runAll(commands);
      expect(results.map((r) => r.ok), [true, true, true, true, false]);
      expect(controller.text, '987654');
      expect(results.first.snapshot!['nodes'], isNotEmpty);
      expect(results.last.report!['kind'], 'notFound');
      expect(jsonEncode(results.map((r) => r.toJson()).toList()), isNot(contains('987654')));

      expect(() => AgentCommand.fromJson({'op': 'shell', 'cmd': 'rm -rf /'}), throwsFormatException);
    });
  });
}

Future<T> _throws<T extends Object>(Future<void> Function() body) async {
  try {
    await body();
  } on T catch (e) {
    return e;
  }
  fail('Expected $T');
}
