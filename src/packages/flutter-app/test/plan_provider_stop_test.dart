import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';

/// stopStreaming() undoes the in-flight turn: the half-streamed reply is
/// dropped, the user message that started it leaves the transcript, and it
/// goes back to where it was in line — returned for the composer, or onto the
/// FRONT of the queue when other messages are already waiting behind it. The
/// transport is aborted and the turn superseded, so any tail from the dying
/// stream touches nothing.

/// Plays [script] in order — [PlanEvent]s yield, [Completer]s park the stream
/// — and records the abort trigger each turn hands to the transport.
class _StagedPlanService extends PlanService {
  List<Object> script;
  bool aborted = false;

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
    abortTrigger?.whenComplete(() => aborted = true);
    for (final step in script) {
      if (step is Completer<void>) {
        await step.future;
      } else {
        yield step as PlanEvent;
      }
    }
  }
}

void main() {
  test('stop mid-stream undoes the turn, hands the text back, and aborts',
      () async {
    final gate = Completer<void>();
    final service = _StagedPlanService([
      const PlanEvent(type: 'text_delta', data: {'text': 'Half an ans'}),
      gate,
      const PlanEvent(type: 'text_delta', data: {'text': 'wer, never seen'}),
      const PlanEvent(type: 'suggest_replies', data: {
        'replies': ['Ghost chip']
      }),
    ]);
    final notifier = PlanNotifier(service, ApiClient());

    final send = notifier.sendMessage('plan athens');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(notifier.state.isStreaming, isTrue);

    final restored = notifier.stopStreaming();

    // Handed back verbatim, for the composer to put in the text box.
    expect(restored?.content, 'plan athens');
    expect(restored?.role, MessageRole.user);
    // Both halves of the turn are gone: the user message AND the partial the
    // old contract used to commit as an assistant bubble.
    expect(notifier.state.messages, isEmpty);
    expect(notifier.state.isStreaming, isFalse);
    expect(notifier.state.streamingText, isNull);
    expect(notifier.state.error, isNull);
    await Future<void>.delayed(Duration.zero);
    expect(service.aborted, isTrue);

    // Release the parked stream: the superseded turn must change nothing.
    gate.complete();
    await send;
    expect(notifier.state.messages, isEmpty);
    expect(notifier.state.suggestedReplies, isEmpty);
    expect(notifier.state.isStreaming, isFalse);

    // A late flush timer must not resurrect a ghost streaming bubble.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(notifier.state.streamingText, isNull);
  });

  test('stop before any text undoes the turn too (typing-indicator phase)',
      () async {
    final gate = Completer<void>();
    final service = _StagedPlanService([gate]);
    final notifier = PlanNotifier(service, ApiClient());

    unawaited(notifier.sendMessage('plan athens'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(notifier.state.isStreaming, isTrue);

    final restored = notifier.stopStreaming();

    expect(restored?.content, 'plan athens');
    expect(notifier.state.messages, isEmpty);
    expect(notifier.state.isStreaming, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(service.aborted, isTrue);
  });

  test('stop while idle returns null and changes nothing (covers double-tap)',
      () async {
    final service = _StagedPlanService([
      const PlanEvent(type: 'text_delta', data: {'text': 'Done.'}),
    ]);
    final notifier = PlanNotifier(service, ApiClient());

    // Never started: nothing happens, and nothing comes back.
    expect(notifier.stopStreaming(), isNull);
    expect(notifier.state.messages, isEmpty);

    await notifier.sendMessage('hi');
    final settled = notifier.state.messages.length;

    // Turn already ended naturally: the second "tap" must not eat the
    // completed exchange now sitting at the transcript tail.
    expect(notifier.stopStreaming(), isNull);
    expect(notifier.state.messages.length, settled);
    expect(notifier.state.isStreaming, isFalse);
  });

  test('attachments ride back with the message', () async {
    final gate = Completer<void>();
    final service = _StagedPlanService([gate]);
    final notifier = PlanNotifier(service, ApiClient());

    final photo = PlanAttachment(
        bytes: Uint8List.fromList([1, 2, 3]), mediaType: 'image/png');
    unawaited(notifier.sendMessage('what is this', attachments: [photo]));
    await Future<void>.delayed(const Duration(milliseconds: 5));

    final restored = notifier.stopStreaming();

    // Same objects, so the composer's chips come back without re-picking.
    expect(restored?.attachments, hasLength(1));
    expect(restored!.attachments.single, same(photo));
    expect(notifier.state.messages, isEmpty);
  });

  test('a chip-seeded turn is undone with nothing handed back', () async {
    final gate = Completer<void>();
    final service = _StagedPlanService([gate]);
    final notifier = PlanNotifier(service, ApiClient());

    // What a "Refine Athens" chip sends: a long machine-written seed behind a
    // short label. There is no composer form of it to restore.
    unawaited(notifier.sendMessage('<long machine-written seed prompt>',
        displayLabel: 'Refine Athens'));
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(notifier.stopStreaming(), isNull);
    // Undone all the same — the chip leaves the transcript.
    expect(notifier.state.messages, isEmpty);
    expect(notifier.state.isStreaming, isFalse);
  });

  test('with a queue the message goes back to the HEAD, not the composer',
      () async {
    final gate = Completer<void>();
    final service = _StagedPlanService([
      const PlanEvent(type: 'text_delta', data: {'text': 'First reply cut'}),
      gate,
    ]);
    final notifier = PlanNotifier(service, ApiClient());

    unawaited(notifier.sendMessage('one'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await notifier.sendMessage('two'); // queued behind the live turn

    // Nothing for the composer: handing 'one' to the text box would let the
    // user resend it BEHIND 'two', inverting the order they were sent in.
    expect(notifier.stopStreaming(), isNull);
    expect(notifier.state.messages, isEmpty);
    expect(notifier.state.queuedMessages.map((m) => m.text).toList(),
        ['one', 'two']);
    expect(notifier.state.isStreaming, isFalse);

    // Stopping is still not "success": no auto-drain of a turn just killed.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(notifier.state.isStreaming, isFalse);

    // A fresh explicit send drains the backlog FIFO ahead of itself, and the
    // stopped message is first in line again.
    service.script = [
      const PlanEvent(type: 'text_delta', data: {'text': 'ok'}),
    ];
    await notifier.sendMessage('three');
    expect(notifier.state.queuedMessages, isEmpty);
    expect(
      notifier.state.messages
          .where((m) => m.role == MessageRole.user)
          .map((m) => m.content)
          .toList(),
      ['one', 'two', 'three'],
    );
  });

  test('re-sending a stopped message leaves exactly one copy in history',
      () async {
    final gate = Completer<void>();
    final service = _StagedPlanService([
      const PlanEvent(type: 'text_delta', data: {'text': 'Stale half'}),
      gate,
    ]);
    final notifier = PlanNotifier(service, ApiClient());

    unawaited(notifier.sendMessage('plan athens'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final restored = notifier.stopStreaming();

    service.script = [
      const PlanEvent(type: 'text_delta', data: {'text': 'Fresh answer.'}),
    ];
    // The composer would send an edited version of what came back.
    await notifier.sendMessage('${restored!.content}, in autumn');

    expect(
      notifier.state.messages
          .where((m) => m.role == MessageRole.user)
          .map((m) => m.content)
          .toList(),
      ['plan athens, in autumn'],
    );
    expect(notifier.state.messages.last.content, 'Fresh answer.');
    expect(notifier.state.error, isNull);
  });

  test('a mid-turn compaction cannot outlive the message it counted',
      () async {
    final gate = Completer<void>();
    final service = _StagedPlanService([
      const PlanEvent(type: 'compacted', data: {
        'through_index': 1,
        'summary': 'They asked about Athens.',
      }),
      gate,
    ]);
    final notifier = PlanNotifier(service, ApiClient());

    unawaited(notifier.sendMessage('plan athens'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    // The boundary now covers the one message in the transcript.
    expect(notifier.state.compactedCount, 1);

    notifier.stopStreaming();

    // That message is gone, so the boundary cannot still claim it — otherwise
    // the next turn slices history past its own end.
    expect(notifier.state.messages, isEmpty);
    expect(notifier.state.compactedCount, 0);
  });
}
