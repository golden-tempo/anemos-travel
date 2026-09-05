import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/dictation_provider.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/dictation_controller.dart';
import 'package:travel_route_planner/services/dictation_engine.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/utils/geolocation_types.dart';
import 'package:travel_route_planner/widgets/chat_panel.dart';
import 'package:travel_route_planner/widgets/trip_refine_panel.dart';

import 'support/l10n_test_app.dart';

/// The chat composer's location button: Home's near-me flow, available
/// mid-conversation on every ChatPanel host (the Plan tab and the trip-detail
/// refine dock build the same composer, so the ChatPanel fixture below IS
/// both; the docked trip chat gets its own host-level proof at the bottom).
///
/// Geolocation enters through the injected [ChatPanel.getPosition] seam —
/// the real lookup is a conditional import whose VM resolution always
/// reports unsupported (see near_me_chip_test.dart), so the success branch
/// is only reachable with a fake. The fallback branch needs no fake at all,
/// which is also what a permission-denied answer looks like.
///
/// The chip-unchanged guard lives in near_me_chip_test.dart (untouched by
/// the extraction and still green); here the composer exercises the SAME
/// shared helper's success branch, which the chip's own fixture cannot
/// reach in a VM test.

class _NoDictationEngine implements DictationEngine {
  @override
  Future<bool> initialize() async => false;
  @override
  Stream<DictationEvent> start() => const Stream.empty();
  @override
  Future<void> stop() async {}
  @override
  Future<void> cancel() async {}
}

/// Replies instantly with one delta; records every history payload.
class _RecordingPlanService extends PlanService {
  final List<List<Map<String, dynamic>>> histories = [];

  _RecordingPlanService() : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {
    histories.add(List.of(messages));
    yield PlanEvent(type: 'text_delta', data: {'text': 'ok'});
  }
}

class _Harness {
  final _RecordingPlanService service;

  /// Consumed by the next location-button tap. Defaults to the denied
  /// answer so an unwired test lands in the fallback dialog.
  Future<GeoResult> Function() nextPosition =
      () async => const GeoResult.fail(GeoErrorKind.denied);

  _Harness._(this.service);

  static Future<_Harness> build(WidgetTester tester) async {
    final service = _RecordingPlanService();
    final notifier = PlanNotifier(service, ApiClient());
    final provider =
        StateNotifierProvider<PlanNotifier, PlanState>((ref) => notifier);
    final harness = _Harness._(service);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dictationControllerFactoryProvider.overrideWithValue(
            (textController) => DictationController(
              textController: textController,
              primary: _NoDictationEngine(),
              fallback: null,
              fallbackAvailable: () async => false,
            ),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: Scaffold(
            body: ChatPanel(
              state: provider,
              notifier: provider.notifier,
              getPosition: () => harness.nextPosition(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return harness;
  }
}

final _locationButton = find.byTooltip('Share my location');

void main() {
  testWidgets('the composer has a location button beside the paperclip',
      (tester) async {
    await _Harness.build(tester);
    expect(_locationButton, findsOneWidget);
    expect(find.byIcon(Icons.my_location), findsOneWidget);
  });

  testWidgets(
      'a fix sends the seeded message WITH a displayLabel; the transcript '
      'shows the context chip, never the coordinates', (tester) async {
    final harness = await _Harness.build(tester);
    harness.nextPosition =
        () async => const GeoResult.ok(50.0875, 14.4207, 30.0);

    await tester.tap(_locationButton);
    await tester.pumpAndSettle();

    // The wire payload: full coordinates in the content (search_nearby reads
    // them server-side), plus the label metadata every turn resends.
    final sent = harness.service.histories.single.single;
    expect(sent['content'], contains('latitude 50.0875, longitude 14.4207'));
    expect(sent['display_label'], 'Near my current location');

    // The transcript: the compact context chip — and no coordinate bubble.
    expect(find.text('Near my current location'), findsOneWidget);
    expect(find.textContaining('50.0875'), findsNothing);
  });

  testWidgets('denied permission falls back to the typed-place dialog, '
      'which sends an unlabeled natural-language message', (tester) async {
    final harness = await _Harness.build(tester); // default: denied

    await tester.tap(_locationButton);
    await tester.pumpAndSettle();
    expect(find.text('Where are you?'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'Malá Strana');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();

    final sent = harness.service.histories.single.single;
    expect(sent['content'], contains('Malá Strana'));
    expect(sent['content'], isNot(contains('latitude')));
    expect(sent.containsKey('display_label'), isFalse,
        reason: 'a typed place renders as a normal bubble, not a chip');
    expect(find.textContaining('Malá Strana'), findsOneWidget);
  });

  testWidgets('while locating the button spins and a second tap is a no-op',
      (tester) async {
    final harness = await _Harness.build(tester);
    final pending = Completer<GeoResult>();
    var lookups = 0;
    harness.nextPosition = () {
      lookups++;
      return pending.future;
    };

    await tester.tap(_locationButton);
    await tester.pump(); // in-flight: spinner instead of the icon

    expect(
      find.descendant(
        of: _locationButton,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.my_location), findsNothing);
    // Disabled, so the tap below cannot start a second lookup. (byTooltip
    // resolves to the Tooltip; the IconButton is its ancestor.)
    final button = tester.widget<IconButton>(
        find.ancestor(of: _locationButton, matching: find.byType(IconButton)));
    expect(button.onPressed, isNull);

    await tester.tap(_locationButton);
    await tester.pump();
    expect(lookups, 1, reason: 'the mid-locate tap must not re-enter');

    pending.complete(const GeoResult.ok(50.0875, 14.4207, 30.0));
    await tester.pumpAndSettle();
    expect(harness.service.histories, hasLength(1));
    expect(find.text('Near my current location'), findsOneWidget);
  });

  group('the trip-detail host', () {
    // Future-dated by calendar-day arithmetic: fixed-date fixtures go red as
    // time passes (#576 folds departed cities by DateTime.now(); #579).
    String iso(DateTime d) => d.toIso8601String().substring(0, 10);
    final now = DateTime.now();

    final trip = Trip(
      id: 't1',
      title: 'Prague Week',
      startDate: iso(now.add(const Duration(days: 3))),
      endDate: iso(now.add(const Duration(days: 7))),
      createdAt: iso(now),
      updatedAt: iso(now),
      items: [
        ItineraryItem(
          id: 'i0',
          position: 0,
          name: 'Charles Bridge',
          address: 'Prague, Czechia',
          // Zero coords so the screen skips the map widget in the test env.
          latitude: 0,
          longitude: 0,
          category: 'attraction',
          day: 1,
          city: 'Prague',
        ),
      ],
    );

    Future<void> openDockedChat(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tripsApiServiceProvider
                .overrideWithValue(_FakeTripsApiService(trip)),
            tripRefineProvider.overrideWith((ref, tripId) =>
                PlanNotifier(_SilentPlanService(), ApiClient(),
                    tripId: tripId)),
          ],
          child: MaterialApp(
            localizationsDelegates: testLocalizationsDelegates,
            home: const TripDetailScreen(tripId: 't1'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
    }

    testWidgets('the docked refine composer has the location button',
        (tester) async {
      await openDockedChat(tester);
      expect(
        find.descendant(
            of: find.byType(TripRefinePanel), matching: _locationButton),
        findsOneWidget,
      );
    });

    testWidgets(
        'a labelled send renders as the context chip in the trip chat '
        'transcript — the refine displayLabel path end to end', (tester) async {
      await openDockedChat(tester);

      // The refine notifier is a PlanNotifier family member; its sendMessage
      // must carry displayLabel to the transcript just like the Plan tab's.
      final container = ProviderScope.containerOf(
          tester.element(find.byType(TripDetailScreen)));
      await container.read(tripRefineProvider('t1').notifier).sendMessage(
            'My current location is latitude 50.0875, longitude 14.4207. '
            "What's good near me?",
            displayLabel: 'Near my current location',
          );
      await tester.pumpAndSettle();

      // Two renderings, both label-driven: the transcript's context chip and
      // the panel header, which mirrors the newest labelled message as the
      // conversation's "chapter" (trip_refine_panel.dart _newestChapter).
      expect(
        find.descendant(
          of: find.byType(TripRefinePanel),
          matching: find.text('Near my current location'),
        ),
        findsNWidgets(2),
      );
      expect(
        find.descendant(
          of: find.byType(TripRefinePanel),
          matching: find.textContaining('50.0875'),
        ),
        findsNothing,
        reason: 'the coordinates stay out of the visible trip transcript',
      );
    });
  });
}

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

class _SilentPlanService extends PlanService {
  _SilentPlanService() : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {}
}
