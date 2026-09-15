import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/widgets/chat_panel.dart';

import 'support/l10n_test_app.dart';

/// Streams one text_delta per [chunks] entry, parking after each on a
/// [Completer] the test completes one at a time — lets a test drive a reply
/// in as many discrete growth steps as it likes, with control over exactly
/// when each one lands.
class _StepPlanService extends PlanService {
  _StepPlanService(this.chunks) : super('http://unused');

  final List<String> chunks;
  final List<Completer<void>> gates = [];

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {
    for (final chunk in chunks) {
      final gate = Completer<void>();
      gates.add(gate);
      yield PlanEvent(type: 'text_delta', data: {'text': chunk});
      await gate.future;
    }
  }
}

Future<void> _pumpPanel(
    WidgetTester tester, _StepPlanService service, double height) async {
  final notifier = PlanNotifier(service, ApiClient());
  final provider =
      StateNotifierProvider<PlanNotifier, PlanState>((ref) => notifier);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        home: Scaffold(
          body: SizedBox(
            height: height,
            child: ChatPanel(state: provider, notifier: provider.notifier),
          ),
        ),
      ),
    ),
  );
}

void main() {
  // Each chunk is long enough to wrap several lines, so a handful of them
  // reliably overflow the 260px viewport this test constrains the panel to.
  final longLine = '${'word ' * 40}\n';

  testWidgets(
      'scrolling up mid-stream pauses autoscroll; the bottom resumes it',
      (WidgetTester tester) async {
    final service = _StepPlanService(List.generate(12, (_) => longLine));
    await _pumpPanel(tester, service, 260);

    await tester.enterText(find.byType(TextField), 'plan athens');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    // Stream flushes land every 48ms (PlanNotifier._streamFlushInterval);
    // drive enough of them for the transcript to overflow the viewport.
    for (var i = 0; i < 6; i++) {
      service.gates[i].complete();
      await tester.pump(const Duration(milliseconds: 60));
    }

    final position =
        tester.widget<ListView>(find.byType(ListView)).controller!.position;
    expect(position.maxScrollExtent, greaterThan(0));
    // Nothing has scrolled the traveler away yet, so the stream should have
    // kept the transcript pinned to its own growing bottom.
    expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));

    // A mouse-wheel/trackpad tick up — same code path a real "scroll to
    // re-read" takes (ScrollPosition.pointerScroll), and unambiguous where a
    // raw drag risks landing on SelectionArea's own gesture handling instead.
    position.pointerScroll(-80);
    await tester.pump();
    final scrolledUpTo = position.pixels;
    expect(scrolledUpTo, lessThan(position.maxScrollExtent - 40));

    // More of the reply streams in. Before this fix, a completed scroll this
    // close to (within 50px of) the bottom re-armed autoscroll on its own —
    // the very next flush then yanked the transcript straight back down.
    for (var i = 6; i < 9; i++) {
      service.gates[i].complete();
      await tester.pump(const Duration(milliseconds: 60));
      expect(position.pixels, scrolledUpTo,
          reason: 'autoscroll must not resume on its own mid-stream');
    }

    // Scrolling all the way back to the edge resumes the follow.
    position.pointerScroll(position.maxScrollExtent);
    await tester.pump();
    expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));

    for (var i = 9; i < 12; i++) {
      service.gates[i].complete();
      // One pump is the whole point: the corrected offset is what the very
      // first layout after this flush produces, not a jump a frame later.
      await tester.pump(const Duration(milliseconds: 60));
      expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
    }
  });

  testWidgets('sending while scrolled up snaps back to the new message',
      (WidgetTester tester) async {
    final service = _StepPlanService(List.generate(2, (_) => longLine));
    await _pumpPanel(tester, service, 260);

    // Two short turns, fully settled, so the transcript overflows the
    // viewport by a modest amount rather than one towering single message —
    // the point here is the send-while-scrolled-up snap, not stress-testing
    // ListView.builder's lazy-extent estimate for a message screens away.
    var completed = 0;
    for (final text in ['plan athens', 'also add delphi']) {
      await tester.enterText(find.byType(TextField), text);
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      while (completed < service.gates.length) {
        service.gates[completed].complete();
        completed++;
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.pumpAndSettle();
    }

    final position =
        tester.widget<ListView>(find.byType(ListView)).controller!.position;
    expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
    position.pointerScroll(-40);
    await tester.pump();
    expect(position.pixels, lessThan(position.maxScrollExtent - 20));

    await tester.enterText(find.byType(TextField), 'one more');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    expect(find.text('one more'), findsOneWidget);
    expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
  });
}
