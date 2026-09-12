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

/// Enter alone submits the composer; Shift+Enter and Option(Alt)+Enter write
/// a newline instead, matching ChatGPT and Claude.

/// Answers every turn instantly, so a send can be told apart from a newline
/// by whether the composer emptied out.
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

/// Presses Enter through the same channel the platform uses to report a
/// submit — `receiveAction`, not a raw key event, since the field declares
/// [TextInputAction.send] and that is what actually triggers `onSubmitted`.
Future<void> _pressEnter(WidgetTester tester) async {
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pump();
}

/// Holds [key] down for the duration of [body], mirroring how a modifier key
/// is actually held while Enter is pressed.
Future<void> _withKeyDown(
  WidgetTester tester,
  LogicalKeyboardKey key,
  Future<void> Function() body,
) async {
  await tester.sendKeyDownEvent(key);
  await tester.pump();
  await body();
  await tester.sendKeyUpEvent(key);
  await tester.pump();
}

void main() {
  testWidgets('plain enter sends and clears the composer',
      (WidgetTester tester) async {
    await _pumpPanel(tester, _InstantPlanService());
    await tester.enterText(find.byType(TextField), 'hello there');
    await tester.pump();

    await _pressEnter(tester);

    expect(_text(tester), isEmpty, reason: 'enter alone should send');
  });

  testWidgets('shift+enter writes a newline instead of sending',
      (WidgetTester tester) async {
    await _pumpPanel(tester, _InstantPlanService());
    await tester.enterText(find.byType(TextField), 'first line');
    await tester.pump();

    await _withKeyDown(tester, LogicalKeyboardKey.shiftLeft, () async {
      await _pressEnter(tester);
    });

    expect(_text(tester), 'first line\n',
        reason: 'shift+enter should add a newline, not submit');
  });

  testWidgets('option(alt)+enter writes a newline instead of sending',
      (WidgetTester tester) async {
    await _pumpPanel(tester, _InstantPlanService());
    await tester.enterText(find.byType(TextField), 'first line');
    await tester.pump();

    await _withKeyDown(tester, LogicalKeyboardKey.altLeft, () async {
      await _pressEnter(tester);
    });

    expect(_text(tester), 'first line\n',
        reason: 'option+enter should add a newline, not submit');
  });

  testWidgets('the newline lands at the caret, replacing any selection',
      (WidgetTester tester) async {
    await _pumpPanel(tester, _InstantPlanService());
    await tester.enterText(find.byType(TextField), 'foo bar');
    await tester.pump();
    _controller(tester).selection = const TextSelection(baseOffset: 3, extentOffset: 7);
    await tester.pump();

    await _withKeyDown(tester, LogicalKeyboardKey.shiftLeft, () async {
      await _pressEnter(tester);
    });

    expect(_text(tester), 'foo\n');
    expect(_controller(tester).selection, const TextSelection.collapsed(offset: 4));
  });

  testWidgets('shift+enter leaves the composer focused for the next line',
      (WidgetTester tester) async {
    await _pumpPanel(tester, _InstantPlanService());
    await tester.enterText(find.byType(TextField), 'first line');
    await tester.pump();

    await _withKeyDown(tester, LogicalKeyboardKey.shiftLeft, () async {
      await _pressEnter(tester);
    });

    final editable = tester.state<EditableTextState>(find.descendant(
        of: find.byType(TextField), matching: find.byType(EditableText)));
    expect(editable.widget.focusNode.hasFocus, isTrue,
        reason: 'the composer must stay focused to keep typing');
  });
}
