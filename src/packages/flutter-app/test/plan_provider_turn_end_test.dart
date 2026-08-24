import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';

/// The terminal-frame contract, client side: a server that announces the
/// protocol (`stream_start`) ends every turn with `turn_end`. Only turn_end
/// "end_turn" lets the streamed text commit as a finished reply; the stream
/// closing without it means the connection died mid-reply (a deploy, a crash),
/// and committing the half-reply is exactly the transcript corruption this
/// exists to prevent — the next turn's model read its own half-sentence back
/// as a finished message and apologised for it.

const _streamStart = PlanEvent(type: 'stream_start', data: {'protocol': 2});
const _turnEndOk = PlanEvent(type: 'turn_end', data: {'stop_reason': 'end_turn'});

/// Replays canned events; each sendMessage consumes the next script in order,
/// so a retry can be given a different (healthy) stream than the failed turn.
class _ScriptedPlanService extends PlanService {
  final List<List<PlanEvent>> scripts;
  int sends = 0;

  _ScriptedPlanService(this.scripts) : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {
    final script = scripts[sends >= scripts.length ? scripts.length - 1 : sends];
    sends++;
    for (final e in script) {
      yield e;
    }
  }
}

void main() {
  test('turn_end end_turn commits the streamed text as a finished reply',
      () async {
    final notifier = PlanNotifier(
        _ScriptedPlanService([
          const [
            _streamStart,
            PlanEvent(type: 'text_delta', data: {'text': 'A full reply.'}),
            _turnEndOk,
          ]
        ]),
        ApiClient());

    await notifier.sendMessage('plan athens');
    expect(notifier.state.error, isNull);
    expect(notifier.state.isStreaming, isFalse);
    expect(notifier.state.messages.map((m) => m.role).toList(),
        [MessageRole.user, MessageRole.assistant]);
    expect(notifier.state.messages.last.content, 'A full reply.');
  });

  test(
      'a protocol stream that closes WITHOUT turn_end discards the half-reply '
      'and surfaces the interrupted error',
      () async {
    final notifier = PlanNotifier(
        _ScriptedPlanService([
          const [
            _streamStart,
            PlanEvent(type: 'text_delta', data: {'text': 'But Berlin Mon'}),
            PlanEvent(type: 'suggest_replies', data: {
              'replies': ['Sounds good']
            }),
            // Connection dies here: no turn_end.
          ]
        ]),
        ApiClient());

    await notifier.sendMessage('plan berlin');
    // The stump is NOT a message: only the user turn remains, the error is
    // the typed marker (localized at render time), streaming state cleared,
    // and no reply chips compete with the banner's Try again.
    expect(notifier.state.messages.map((m) => m.role).toList(),
        [MessageRole.user]);
    expect(notifier.state.error, isA<StreamInterruptedException>());
    expect(notifier.state.isStreaming, isFalse);
    expect(notifier.state.streamingText, isNull);
    expect(notifier.state.suggestedReplies, isEmpty);
  });

  test('turn_end server_restart (graceful drain) discards and offers retry',
      () async {
    final notifier = PlanNotifier(
        _ScriptedPlanService([
          const [
            _streamStart,
            PlanEvent(type: 'text_delta', data: {'text': 'Half a th'}),
            PlanEvent(type: 'turn_end', data: {'stop_reason': 'server_restart'}),
          ],
          // The retry (after the deploy) gets a healthy stream.
          const [
            _streamStart,
            PlanEvent(type: 'text_delta', data: {'text': 'The whole thought.'}),
            _turnEndOk,
          ],
        ]),
        ApiClient());

    await notifier.sendMessage('plan berlin');
    expect(notifier.state.error, isA<StreamInterruptedException>());
    expect(notifier.state.messages.map((m) => m.role).toList(),
        [MessageRole.user]);

    // retryLastSend rolls back to just before the user message and re-sends:
    // exactly one copy of the user message, then the full reply commits.
    await notifier.retryLastSend();
    expect(notifier.state.error, isNull);
    expect(notifier.state.messages.map((m) => m.role).toList(),
        [MessageRole.user, MessageRole.assistant]);
    expect(notifier.state.messages.first.content, 'plan berlin');
    expect(notifier.state.messages.last.content, 'The whole thought.');
  });

  test(
      'a pre-protocol stream (no stream_start) keeps the old commit-on-close '
      'behavior, so a rolled-back API degrades instead of erroring every turn',
      () async {
    final notifier = PlanNotifier(
        _ScriptedPlanService([
          const [
            PlanEvent(type: 'text_delta', data: {'text': 'Legacy reply.'}),
            // Old server: stream just closes, no terminal frame.
          ]
        ]),
        ApiClient());

    await notifier.sendMessage('plan athens');
    expect(notifier.state.error, isNull);
    expect(notifier.state.messages.map((m) => m.role).toList(),
        [MessageRole.user, MessageRole.assistant]);
    expect(notifier.state.messages.last.content, 'Legacy reply.');
  });

  test('an interrupted turn does not drain queued messages', () async {
    final notifier = PlanNotifier(
        _ScriptedPlanService([
          const [
            _streamStart,
            PlanEvent(type: 'text_delta', data: {'text': 'Half'}),
          ]
        ]),
        ApiClient());

    final first = notifier.sendMessage('plan berlin');
    // Queued while streaming; must still be queued after the interruption —
    // the queue drains only on success, same as the explicit-error path.
    final second = notifier.sendMessage('and munich');
    await Future.wait([first, second]);

    expect(notifier.state.error, isA<StreamInterruptedException>());
    expect(notifier.state.queuedMessages, hasLength(1));
    expect(notifier.state.queuedMessages.single.text, 'and munich');
  });
}
