import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/trip_cache_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trips_list_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trip_cache.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/collapsible_section.dart';

import 'support/l10n_test_app.dart';

/// The trips list orders by travel date and folds finished trips into a
/// collapsed "Past trips" row (utils/trip_list_order.dart): upcoming cards on
/// top soonest-first, past cards hidden until the row is expanded. The
/// collapsed row teases its MOST RECENT trip (specs/trips-page-insights) —
/// "where you just were" is what earns the expand tap, and the lifetime
/// aggregate lives in the "Your travels" band one card up.
class _FixedTripsApiService extends TripsApiService {
  final List<Trip> trips;
  _FixedTripsApiService(this.trips)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<Trip>> listTrips() => Future.value(trips);
}

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

// Calendar-day arithmetic, never Duration: adding 24h days lands a
// calendar day short in the midnight hour when the span crosses a DST
// fall-back (the trips_list_header "34 days" flake of 2026-08-23).
String _rel(int days) {
  final now = DateTime.now();
  return _iso(DateTime(now.year, now.month, now.day + days));
}

Trip _trip(String id, String title,
        {String? start, String? end, List<String>? cities}) =>
    Trip(
      id: id,
      title: title,
      startDate: start,
      endDate: end,
      cities: cities,
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
    );

Future<void> _pumpList(WidgetTester tester, List<Trip> trips) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FixedTripsApiService(trips)),
        tripCacheProvider.overrideWithValue(TripCache('u1')),
        resumableChatsProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: const TripsListScreen()),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('past trip hides behind a collapsed row and expands on tap',
      (WidgetTester tester) async {
    await _pumpList(tester, [
      // Server order: newest-created first, i.e. the past trip on top.
      _trip('past', 'Guadalajara', start: _rel(-16), end: _rel(-15)),
      _trip('future', 'Prague Trip', start: _rel(18), end: _rel(52)),
    ]);
    await tester.pumpAndSettle();

    // Collapsed: the row and its count pill show, the past card doesn't.
    expect(find.text('Past trips'), findsOneWidget);
    expect(find.text('1 trip'), findsOneWidget);
    expect(find.text('Prague Trip'), findsOneWidget);
    expect(find.text('Guadalajara'), findsNothing);

    // The upcoming card renders above the collapsed row.
    expect(
      tester.getTopLeft(find.text('Prague Trip')).dy,
      lessThan(tester.getTopLeft(find.text('Past trips')).dy),
    );

    await tester.tap(find.text('Past trips'));
    await tester.pumpAndSettle();
    expect(find.text('Guadalajara'), findsOneWidget);

    // Toggling closed hides it again.
    await tester.tap(find.text('Past trips'));
    await tester.pumpAndSettle();
    expect(find.text('Guadalajara'), findsNothing);
  });

  testWidgets('upcoming trips reorder soonest-first, ignoring server order',
      (WidgetTester tester) async {
    await _pumpList(tester, [
      _trip('far', 'December Trip', start: _rel(120), end: _rel(125)),
      _trip('near', 'Next Week Trip', start: _rel(7), end: _rel(9)),
    ]);
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('Next Week Trip')).dy,
      lessThan(tester.getTopLeft(find.text('December Trip')).dy),
    );
    // Nothing is past, so no collapsed row appears.
    expect(find.byType(CollapsibleSection), findsNothing);
  });

  testWidgets('all-past account still reaches its trips', (tester) async {
    await _pumpList(tester, [
      _trip('past', 'Old Trip', start: _rel(-9), end: _rel(-2)),
    ]);
    await tester.pumpAndSettle();

    // Not the empty state: the Upcoming header (deliberately kept — it
    // carries the list's only create affordance) sits above the collapsed
    // row, which holds every trip.
    expect(find.text('No trips yet'), findsNothing);
    expect(find.text('Past trips'), findsOneWidget);

    await tester.tap(find.text('Past trips'));
    await tester.pumpAndSettle();
    expect(find.text('Old Trip'), findsOneWidget);
  });

  testWidgets('the collapsed row summarizes the most recent past trip',
      (WidgetTester tester) async {
    await _pumpList(tester, [
      // Finished nine days ago, 12 days long — the newest past trip.
      _trip('recent', 'Iberia Loop',
          start: _rel(-20), end: _rel(-9), cities: const ['Lisbon', 'Porto']),
      // Older and longer: recency picks the tease, not size.
      _trip('older', 'Andes Trek',
          start: _rel(-200), end: _rel(-180), cities: const ['Lima', 'Cusco']),
      _trip('future', 'Prague Trip', start: _rel(18), end: _rel(52)),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Lisbon & Porto · 12 days'), findsOneWidget);
    expect(find.textContaining('Lima & Cusco'), findsNothing);
    expect(find.text('2 trips'), findsOneWidget);
  });

  testWidgets('the summarized row still toggles open and closed',
      (WidgetTester tester) async {
    await _pumpList(tester, [
      _trip('recent', 'Iberia Loop',
          start: _rel(-20), end: _rel(-9), cities: const ['Lisbon', 'Porto']),
      _trip('future', 'Prague Trip', start: _rel(18), end: _rel(52)),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Iberia Loop'), findsNothing);

    await tester.ensureVisible(find.text('Past trips'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Past trips'));
    await tester.pumpAndSettle();
    expect(find.text('Iberia Loop'), findsOneWidget);
    // The tease rides the row, so it stays put while expanded.
    expect(find.text('Lisbon & Porto · 12 days'), findsOneWidget);

    await tester.tap(find.text('Past trips'));
    await tester.pumpAndSettle();
    expect(find.text('Iberia Loop'), findsNothing);
  });

  testWidgets('a city-less legacy past trip falls back to its title',
      (WidgetTester tester) async {
    // Segments drop out individually: no cities ⇒ the headline carries the
    // slot, and the day count still trails it.
    await _pumpList(tester, [
      _trip('past', 'Old Trip', start: _rel(-9), end: _rel(-2)),
      _trip('future', 'Prague Trip', start: _rel(18), end: _rel(52)),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Old Trip · 8 days'), findsOneWidget);
  });

  // Issue #671: an account with years of trips turned the expanded "Past
  // trips" row into an unbounded column. It now pages in kPastTripsPageSize
  // (5) at a time instead of rendering every finished trip at once.
  testWidgets(
      'a past list longer than one page hides the rest behind "Show more"',
      (WidgetTester tester) async {
    // Tall surface so every row in the expanded section (plus its "Show
    // more" button) is on-screen without the test driving the page's own
    // scroll — the assertions below are about the SECTION's content, not
    // the outer ListView's viewport. devicePixelRatio pinned to 1.0 so the
    // logical width stays the default 800 (trip_detail_view_tabs_test's
    // _useTallViewport convention).
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Seven past trips, most-recent-first by construction (end date closest
    // to today is "Past 1"): partitionTripsForList re-sorts the same way, so
    // the order here just has to match what the section is expected to show.
    await _pumpList(tester, [
      for (var i = 1; i <= 7; i++)
        _trip('past$i', 'Past $i',
            start: _rel(-10 * i - 2), end: _rel(-10 * i)),
      _trip('future', 'Prague Trip', start: _rel(18), end: _rel(52)),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('7 trips'), findsOneWidget);

    await tester.tap(find.text('Past trips'));
    await tester.pumpAndSettle();

    // First page: the five most recent past trips.
    for (var i = 1; i <= 5; i++) {
      expect(find.text('Past $i'), findsOneWidget);
    }
    // The rest stay off until "Show more" is tapped.
    expect(find.text('Past 6'), findsNothing);
    expect(find.text('Past 7'), findsNothing);
    expect(find.text('Show 2 more trips'), findsOneWidget);

    await tester.tap(find.text('Show 2 more trips'));
    await tester.pumpAndSettle();

    for (var i = 1; i <= 7; i++) {
      expect(find.text('Past $i'), findsOneWidget);
    }
    // Everything is showing now, so the pagination button is gone.
    expect(find.text('Show 2 more trips'), findsNothing);
  });

  testWidgets('a past list within one page shows no "Show more" button',
      (WidgetTester tester) async {
    await _pumpList(tester, [
      for (var i = 1; i <= 3; i++)
        _trip('past$i', 'Past $i',
            start: _rel(-10 * i - 2), end: _rel(-10 * i)),
      _trip('future', 'Prague Trip', start: _rel(18), end: _rel(52)),
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Past trips'));
    await tester.pumpAndSettle();

    for (var i = 1; i <= 3; i++) {
      expect(find.text('Past $i'), findsOneWidget);
    }
    expect(find.textContaining('Show'), findsNothing);
  });
}
