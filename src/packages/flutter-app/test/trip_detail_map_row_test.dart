import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/trip_refine_chat.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip_finding.dart';
import 'package:travel_route_planner/providers/trip_review_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trip_review_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/trip_map.dart';

import 'support/l10n_test_app.dart';

// The wide map row (map-row redesign, 2026-08-26): inside the content cap
// the map card sits LEFT at ~55% with the Next Step and Continue-chat cards
// stacked beside it, the whole row scrolls away with the page, and only the
// tab row still pins. With neither card (read-only / no conversation /
// review empty) the map spans the full content width. The narrow layout is
// untouched: the scroll-away preview card survives byte-for-byte.
//
// All assertions are structural or geometric relations between widget
// rects — never rendered-text sizes (the widget-test font is not Inter).

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

class _FakeReviewApiService extends TripReviewApiService {
  final TripReview review;
  _FakeReviewApiService(this.review) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<TripReview> getReview(String tripId, {bool checkHours = false}) async =>
      review;
}

ItineraryItem _item(
  int pos,
  String name,
  String city,
  double lat,
  double lng,
  int day,
) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      latitude: lat,
      longitude: lng,
      category: 'attraction',
      day: day,
      city: city,
    );

/// Two geocoded cities (the leg strip renders) with enough Rome stops that
/// the page has real scroll extent at 800px tall.
Trip _trip({TripRefineChat? chat}) => Trip(
      id: 't1',
      title: 'Grand tour',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      startDate: '2026-09-01',
      endDate: '2026-09-05',
      refineChat: chat,
      items: [
        _item(0, 'Louvre', 'Paris', 48.8606, 2.3376, 1),
        _item(1, 'Orsay', 'Paris', 48.8600, 2.3266, 2),
        for (var k = 0; k < 8; k++)
          _item(2 + k, 'Roman Forum $k', 'Rome', 41.89 + k * 0.001, 12.49, 3),
      ],
    );

const _lodgingReview = TripReview(
  findings: [],
  nextStep: NextStep(
    kind: 'add_lodging',
    title: 'Book a place to stay',
    detail: '2 unbooked nights in Rome',
    seedPrompt: 'Help me find lodging.',
  ),
  planProgress: PlanProgress(done: 2, total: 6),
);

Future<void> _pump(
  WidgetTester tester, {
  required Trip trip,
  required TripReview review,
  required Size surface,
}) async {
  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        tripReviewApiServiceProvider
            .overrideWithValue(_FakeReviewApiService(review)),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
}

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(find
        .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable))
        .first)
    .position;

void main() {
  testWidgets(
      'wide: map left beside the stacked Next Step + Continue chat cards; '
      'scrolling moves the row off while the tab row stays pinned',
      (tester) async {
    await _pump(
      tester,
      trip: _trip(
          chat: const TripRefineChat(
        messageCount: 17,
        preview: 'Great choice! Go ahead and add it.',
        updatedAt: '2026-08-25T10:00:00Z',
      )),
      review: _lodgingReview,
      surface: const Size(1200, 800),
    );

    final mapRect = tester.getRect(find.byType(TripMap));
    final nextRect =
        tester.getRect(find.byKey(const ValueKey('next-step-card')));
    final chatRect =
        tester.getRect(find.byKey(const ValueKey('continue-chat-row')));

    // Side by side, map LEFT: both cards start right of the map's right
    // edge, and the map is the wider column (flex 6:5).
    expect(mapRect.right, lessThanOrEqualTo(nextRect.left),
        reason: 'the map column must sit left of the Next Step card');
    expect(mapRect.right, lessThanOrEqualTo(chatRect.left),
        reason: 'the map column must sit left of the Continue-chat card');
    expect(mapRect.width, greaterThan(nextRect.width),
        reason: 'the map takes the larger share of the row (~55%)');
    // The two cards stack in one column, top edges tied to the map row.
    expect(nextRect.bottom, lessThanOrEqualTo(chatRect.top),
        reason: 'Next Step stacks above Continue chat');
    expect((nextRect.top - mapRect.top).abs(), lessThanOrEqualTo(1),
        reason: 'the column tops align with the map');
    expect((chatRect.bottom - mapRect.bottom).abs(), lessThanOrEqualTo(1),
        reason: 'the column stretches to the map\'s bottom edge');

    // The stacked card keeps its full wiring at column width — the action
    // buttons are present (wrapped below the text, but presence is the
    // structural fact worth pinning here).
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('next-step-card')),
            matching: find.byKey(const ValueKey('next-step-primary'))),
        findsOneWidget);

    // Scrolling: the whole row leaves; the tab row keeps pinning alone.
    final position = _position(tester);
    expect(position.maxScrollExtent, greaterThan(0),
        reason: 'premise: the fixture must scroll');
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    final mapGone = find.byType(TripMap);
    if (mapGone.evaluate().isNotEmpty) {
      expect(tester.getRect(mapGone).bottom, lessThanOrEqualTo(0),
          reason: 'the map row must scroll fully off (it used to pin)');
    }
    expect(find.text('Itinerary'), findsOneWidget,
        reason: 'the tab row is the one piece of chrome that still pins');
  });

  testWidgets(
      'wide with no next step and no conversation: the map spans the full '
      'content width — and still scrolls away', (tester) async {
    // No refineChat; the review resolves with NO next step, so the right
    // column has nothing to hold and must not reserve its 45%.
    await _pump(
      tester,
      trip: _trip(),
      review: const TripReview(findings: []),
      surface: const Size(1200, 800),
    );

    expect(find.byKey(const ValueKey('next-step-card')), findsNothing);
    expect(find.byKey(const ValueKey('continue-chat-row')), findsNothing);

    // Full content width: the 1200px body caps content at 900 (gutters
    // 150 each side), so the map card's box spans ~900 — not the ~55%
    // (~490px) row share.
    final mapWidth = tester.getRect(find.byType(TripMap)).width;
    expect(mapWidth, greaterThan(850),
        reason: 'with both cards absent the map takes the whole row');

    // And it is page flow, not chrome: scrolling carries it off.
    final position = _position(tester);
    expect(position.maxScrollExtent, greaterThan(0),
        reason: 'premise: the fixture must scroll');
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    final mapGone = find.byType(TripMap);
    if (mapGone.evaluate().isNotEmpty) {
      expect(tester.getRect(mapGone).bottom, lessThanOrEqualTo(0),
          reason: 'the full-width map must scroll away too');
    }
  });

  testWidgets(
      'narrow guard rail: the scroll-away tap-to-expand preview is unchanged',
      (tester) async {
    // This pin PASSES against the pre-redesign code too — it is the guard
    // that the phone layout stayed byte-for-byte, not a fail-against-old
    // probe like the two above.
    await _pump(
      tester,
      trip: _trip(
          chat: const TripRefineChat(
        messageCount: 3,
        preview: 'Naxos then Paros.',
        updatedAt: '2026-08-25T10:00:00Z',
      )),
      review: _lodgingReview,
      surface: const Size(375, 800),
    );

    // Cards stack full-width ABOVE the map preview (no side-by-side row).
    final mapRect = tester.getRect(find.byType(TripMap));
    final nextRect =
        tester.getRect(find.byKey(const ValueKey('next-step-card')));
    expect(nextRect.bottom, lessThanOrEqualTo(mapRect.top),
        reason: 'phones keep the stacked header: cards above the preview');
    expect(nextRect.width, greaterThan(300),
        reason: 'phone cards keep the full content width');

    // The preview is the pointer-absorbing tap-to-expand card: no inline
    // zoom controls, an expand affordance, and a page scroll moves it.
    expect(
        find.descendant(
            of: find.byType(TripMap), matching: find.byIcon(Icons.add)),
        findsNothing,
        reason: 'the phone preview absorbs pointers — no zoom controls');
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);
    final position = _position(tester);
    position.jumpTo(200);
    await tester.pumpAndSettle();
    final mapAfter = find.byType(TripMap);
    if (mapAfter.evaluate().isNotEmpty) {
      expect(tester.getRect(mapAfter).top, lessThan(mapRect.top),
          reason: 'the preview scrolls with the page, as it always has');
    }
  });
}
