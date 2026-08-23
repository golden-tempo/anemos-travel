import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/chat_panel.dart';

import 'support/l10n_test_app.dart';

/// Shell-style history recall in the composer: Up walks back through what the
/// user has sent in this chat, Down walks forward and finally back to the
/// draft they were part-way through writing. Only from the edge of the text,
/// so a multi-line draft still navigates by line.

/// Answers every turn instantly, so messages land in the transcript (which is
/// the history) without a test having to drive a stream.
class _InstantPlanService extends PlanService {
  _InstantPlanService() : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {
    yield const PlanEvent(type: 'text_delta', data: {'text': 'ok'});
  }
}

/// Parks every turn, so a test can leave messages sitting in the queue.
class _ParkedPlanService extends PlanService {
  final gate = Completer<void>();

  _ParkedPlanService() : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {
    await gate.future;
  }
}

Future<PlanNotifier> _pumpPanel(WidgetTester tester, PlanService service) async {
  final notifier = PlanNotifier(service, ApiClient());
  final provider =
      StateNotifierProvider<PlanNotifier, PlanState>((ref) => notifier);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        home: Scaffold(
          body: ChatPanel(state: provider, notifier: provider.notifier),
        ),
      ),
    ),
  );
  return notifier;
}

TextEditingController _controller(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!;

String _text(WidgetTester tester) => _controller(tester).text;

/// Types [text] and sends it, leaving the composer focused and empty.
Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.tap(find.byIcon(Icons.send));
  await tester.pumpAndSettle();
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
}

Future<void> _up(WidgetTester tester) =>
    _press(tester, LogicalKeyboardKey.arrowUp);
Future<void> _down(WidgetTester tester) =>
    _press(tester, LogicalKeyboardKey.arrowDown);

void main() {
  testWidgets('up walks back through sent messages and stops at the oldest',
      (WidgetTester tester) async {
    await _pumpPanel(tester, _InstantPlanService());

    await _send(tester, 'first');
    await _send(tester, 'second');
    await _send(tester, 'third');
    expect(_text(tester), isEmpty);

    await _up(tester);
    expect(_text(tester), 'third', reason: 'newest first');
    await _up(tester);
    expect(_text(tester), 'second');
    await _up(tester);
    expect(_text(tester), 'first');

    // Nowhere further back: the key falls through rather than dead-ending.
    await _up(tester);
    expect(_text(tester), 'first');
  });

  testWidgets('the caret lands at the end, so editing continues the message',
      (WidgetTester tester) async {
    await _pumpPanel(tester, _InstantPlanService());
    await _send(tester, 'move Xplore Fitness to wednesday');

    await _up(tester);

    expect(_text(tester), 'move Xplore Fitness to wednesday');
    expect(_controller(tester).selection.baseOffset,
        'move Xplore Fitness to wednesday'.length);
  });

  testWidgets('down walks forward and back to the half-written draft',
      (WidgetTester tester) async {
    await _pumpPanel(tester, _InstantPlanService());
    await _send(tester, 'first');
    await _send(tester, 'second');

    // Part-way through a new message when they reach for history.
    await tester.enterText(find.byType(TextField), 'half-writ');
    await tester.pump();

    await _up(tester);
    expect(_text(tester), 'second');
    await _up(tester);
    expect(_text(tester), 'first');
    await _down(tester);
    expect(_text(tester), 'second');

    // Past the newest is the draft they were writing — never lost.
    await _down(tester);
    expect(_text(tester), 'half-writ');

    // And no further.
    await _down(tester);
    expect(_text(tester), 'half-writ');
  });

  testWidgets('typing ends the browse; the next up starts from the newest',
      (WidgetTester tester) async {
    await _pumpPanel(tester, _InstantPlanService());
    await _send(tester, 'first');
    await _send(tester, 'second');

    await _up(tester);
    await _up(tester);
    expect(_text(tester), 'first');

    // Editing a recalled message makes it the draft.
    await tester.enterText(find.byType(TextField), 'first, but in autumn');
    await tester.pump();

    await _up(tester);
    expect(_text(tester), 'second', reason: 'browse restarted from the newest');
    await _down(tester);
    expect(_text(tester), 'first, but in autumn', reason: 'the edit is the draft');
  });

  testWidgets('a caret move is not an edit and keeps the browse alive',
      (WidgetTester tester) async {
    await _pumpPanel(tester, _InstantPlanService());
    await _send(tester, 'first');
    await _send(tester, 'second');

    await tester.enterText(find.byType(TextField), 'half-writ');
    await tester.pump();
    await _up(tester);
    expect(_text(tester), 'second');

    // Clicking into a recalled message to edit it notifies the controller
    // exactly as a keystroke does. It must not eat the stash.
    _controller(tester).selection = const TextSelection.collapsed(offset: 3);
    await tester.pump();

    await _down(tester);
    expect(_text(tester), 'half-writ');
  });

  testWidgets('up only recalls from the first line of a multi-line draft',
      (WidgetTester tester) async {
    await _pumpPanel(tester, _InstantPlanService());
    await _send(tester, 'first');

    await tester.enterText(find.byType(TextField), 'line one\nline two');
    await tester.pump();
    // enterText leaves the caret at the end — on the last line.
    expect(_controller(tester).selection.baseOffset, 17);

    // Caret sits on the last line: Up belongs to the caret, not to history.
    await _up(tester);
    expect(_text(tester), 'line one\nline two');
    // And declining really does leave the default behaviour intact — the
    // caret moved up a line rather than the key being swallowed.
    expect(_controller(tester).selection.baseOffset, lessThan(9),
        reason: 'caret should have moved onto line one');

    // On the first line it recalls.
    _controller(tester).selection = const TextSelection.collapsed(offset: 2);
    await tester.pump();
    await _up(tester);
    expect(_text(tester), 'first');
  });

  testWidgets('down only recalls from the last line of a multi-line draft',
      (WidgetTester tester) async {
    await _pumpPanel(tester, _InstantPlanService());
    await _send(tester, 'first');

    await tester.enterText(find.byType(TextField), 'line one\nline two');
    await tester.pump();
    _controller(tester).selection = const TextSelection.collapsed(offset: 2);
    await tester.pump();

    await _up(tester);
    expect(_text(tester), 'first');

    // Back to a multi-line draft, caret on the FIRST line: Down moves it.
    await _down(tester);
    expect(_text(tester), 'line one\nline two');
    _controller(tester).selection = const TextSelection.collapsed(offset: 2);
    await tester.pump();
    await _down(tester);
    expect(_text(tester), 'line one\nline two', reason: 'caret moved instead');
  });

  testWidgets('a modifier makes it a different gesture, never a recall',
      (WidgetTester tester) async {
    await _pumpPanel(tester, _InstantPlanService());
    await _send(tester, 'first');

    // Set up the exact state a bare Up WOULD recall from, so the only thing
    // under test is the modifier.
    await tester.enterText(find.byType(TextField), 'draft');
    await tester.pump();

    for (final modifier in [
      LogicalKeyboardKey.shiftLeft, // extends a selection
      LogicalKeyboardKey.altLeft, // moves by word / paragraph
      LogicalKeyboardKey.metaLeft, // jumps to the start of the document
    ]) {
      await tester.sendKeyDownEvent(modifier);
      await _up(tester);
      await tester.sendKeyUpEvent(modifier);
      expect(_text(tester), 'draft', reason: '${modifier.keyLabel}+up recalled');
    }

    // The same keystroke without one does recall — so it really is the
    // modifier doing the work above, not some other guard.
    await _up(tester);
    expect(_text(tester), 'first');
  });

  testWidgets('up on an empty chat does nothing', (WidgetTester tester) async {
    await _pumpPanel(tester, _InstantPlanService());
    await tester.tap(find.byType(TextField));
    await tester.pump();

    await _up(tester);
    expect(_text(tester), isEmpty);
  });

  testWidgets('chip-seeded turns are not in history',
      (WidgetTester tester) async {
    final notifier = await _pumpPanel(tester, _InstantPlanService());

    await _send(tester, 'typed this');
    // What a "Refine Athens" chip sends: the app's words, not the user's.
    await notifier.sendMessage('<long machine-written seed prompt>',
        displayLabel: 'Refine Athens');
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await _up(tester);
    expect(_text(tester), 'typed this');

    // The seed is not one step further back either — it is not in the list.
    await _up(tester);
    expect(_text(tester), 'typed this');
  });

  testWidgets('a queued message is recallable before it has been answered',
      (WidgetTester tester) async {
    final service = _ParkedPlanService();
    await _pumpPanel(tester, service);

    // First turn parks; the second message queues behind it.
    await tester.enterText(find.byType(TextField), 'streaming one');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'queued two');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    await _up(tester);
    expect(_text(tester), 'queued two', reason: 'sent, just waiting its turn');
    await _up(tester);
    expect(_text(tester), 'streaming one');

    service.gate.complete();
    await tester.pumpAndSettle();
  });
}
