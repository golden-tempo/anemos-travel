import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/image_attachment_pipeline.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/chat_panel.dart';

import 'support/l10n_test_app.dart';

/// Contextual send/stop swap: while a turn streams with nothing drafted the
/// send button becomes a stop button; typing a follow-up flips it back to send
/// so queue-ahead keeps working. Tapping stop UNDOES the turn — the message
/// leaves the chat and lands back in the composer, ready to edit and resend.

/// Plays [script] in order: [PlanEvent]s are yielded, [Completer]s are
/// awaited — so a test can park the stream mid-turn and observe the UI.
class _StagedPlanService extends PlanService {
  final List<Object> script;

  _StagedPlanService(this.script) : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {
    for (final step in script) {
      if (step is Completer<void>) {
        await step.future;
      } else {
        yield step as PlanEvent;
      }
    }
  }
}

/// A 1×1 PNG — real bytes for Image.memory to render in a chip.
final _tinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

/// Echoes bytes through unchanged — engine image decoding can't complete
/// inside a widget test's fake-async zone (see chat_panel_attachments_test).
class _EchoPipeline extends ImageAttachmentPipeline {
  const _EchoPipeline();

  @override
  Future<PlanAttachment?> process(Uint8List bytes, String mediaType) async =>
      PlanAttachment(bytes: bytes, mediaType: mediaType);
}

/// Files the next paperclip tap will "pick".
List<(Uint8List, String)> _nextPick = [];

Future<PlanNotifier> _pumpPanel(
    WidgetTester tester, _StagedPlanService service) async {
  _nextPick = [];
  final notifier = PlanNotifier(service, ApiClient());
  final provider =
      StateNotifierProvider<PlanNotifier, PlanState>((ref) => notifier);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        home: Scaffold(
          body: ChatPanel(
            state: provider,
            notifier: provider.notifier,
            attachmentPipeline: const _EchoPipeline(),
            pickImages: () async => _nextPick,
          ),
        ),
      ),
    ),
  );
  return notifier;
}

Future<void> _send(WidgetTester tester, [String text = 'hi']) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.tap(find.byIcon(Icons.send));
  await tester.pump();
}

TextField _field(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField));

void main() {
  testWidgets('idle shows send; streaming with an empty composer shows stop',
      (WidgetTester tester) async {
    final gate = Completer<void>();
    final service = _StagedPlanService([
      const PlanEvent(type: 'text_delta', data: {'text': 'Hello there'}),
      gate,
    ]);
    await _pumpPanel(tester, service);

    expect(find.byIcon(Icons.send), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsNothing);

    // _send clears the composer, so the swap lands the instant a turn starts.
    await _send(tester);
    expect(find.byIcon(Icons.stop), findsOneWidget);
    expect(find.byIcon(Icons.send), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.send), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsNothing);
  });

  testWidgets('typing a follow-up mid-stream flips stop back to send',
      (WidgetTester tester) async {
    final gate = Completer<void>();
    final service = _StagedPlanService([
      const PlanEvent(type: 'text_delta', data: {'text': 'Hello there'}),
      gate,
    ]);
    await _pumpPanel(tester, service);

    await _send(tester);
    expect(find.byIcon(Icons.stop), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'queue this too');
    await tester.pump();
    expect(find.byIcon(Icons.send), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsNothing);

    // Whitespace is not a draft.
    await tester.enterText(find.byType(TextField), '  ');
    await tester.pump();
    expect(find.byIcon(Icons.stop), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('stop takes the message out of the chat and back to the composer',
      (WidgetTester tester) async {
    final gate = Completer<void>();
    final service = _StagedPlanService([
      const PlanEvent(type: 'text_delta', data: {'text': 'Hello there'}),
      gate,
    ]);
    final notifier = await _pumpPanel(tester, service);

    await _send(tester, 'move Xplore Fitness to thursday');
    // Let the 48ms flush render the live streaming bubble first.
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('move Xplore Fitness to thursday'), findsOneWidget);
    expect(find.text('Hello there'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.stop));
    await tester.pump();

    // Both halves of the turn leave the transcript: the user bubble and the
    // half-streamed reply the old contract used to commit.
    expect(notifier.state.messages, isEmpty);
    expect(find.text('Hello there'), findsNothing);

    // The words are back in the text box — the one place they now live, so
    // finding them still finds exactly one widget (the TextField's own text).
    expect(_field(tester).controller!.text, 'move Xplore Fitness to thursday');
    expect(find.text('move Xplore Fitness to thursday'), findsOneWidget);

    // Ready to edit: caret parked at the END (assigning `controller.text`
    // instead would leave it at -1 and the next keystroke would land in
    // front), and the field has focus so typing goes straight in.
    expect(_field(tester).controller!.selection.baseOffset,
        'move Xplore Fitness to thursday'.length);
    expect(_field(tester).focusNode!.hasFocus, isTrue);

    // A restored draft is a draft: the button is a Send again, not a Stop.
    expect(find.byIcon(Icons.send), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsNothing);

    // No ghost streaming bubble once the late flush timer fires.
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('Hello there'), findsNothing);
    await tester.pumpAndSettle();
  });

  testWidgets('stop brings attached images back as pending chips',
      (WidgetTester tester) async {
    final gate = Completer<void>();
    final service = _StagedPlanService([gate]);
    final notifier = await _pumpPanel(tester, service);

    _nextPick = [(_tinyPng, 'image/png')];
    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget, reason: 'pending chip');

    await _send(tester, 'what is this?');
    expect(notifier.state.messages.single.attachments, hasLength(1));

    await tester.tap(find.byIcon(Icons.stop));
    await tester.pumpAndSettle();

    // Re-picking four photos is worse than retyping a sentence, so the image
    // comes back with the text rather than being dropped on the floor.
    expect(notifier.state.messages, isEmpty);
    expect(_field(tester).controller!.text, 'what is this?');
    expect(find.byType(Image), findsOneWidget, reason: 'chip, not a bubble');
  });

  testWidgets('stopping a chip-seeded turn leaves the composer empty',
      (WidgetTester tester) async {
    final gate = Completer<void>();
    final service = _StagedPlanService([gate]);
    final notifier = await _pumpPanel(tester, service);

    // What a "Refine Athens" chip sends: a machine-written seed behind a short
    // label. Nobody typed it, so nothing belongs in the text box.
    unawaited(notifier.sendMessage('<long machine-written seed prompt>',
        displayLabel: 'Refine Athens'));
    await tester.pump();
    expect(find.text('Refine Athens'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.stop));
    await tester.pump();

    expect(notifier.state.messages, isEmpty);
    expect(find.text('Refine Athens'), findsNothing);
    expect(_field(tester).controller!.text, isEmpty);
    expect(find.text('<long machine-written seed prompt>'), findsNothing);
    await tester.pumpAndSettle();
  });
}
