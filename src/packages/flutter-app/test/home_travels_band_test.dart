import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/trip_cache_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trip_cache.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/home_travels_band.dart';
import 'package:travel_route_planner/widgets/travel_footprint_card.dart';

import 'support/l10n_test_app.dart';

/// Home's "Your travels" band, and the atlas door in its header.
///
/// The band and the door ask DIFFERENT questions, and that is what this pins.
/// The band wants 2+ OWNED trips, because below that an aggregate only
/// restates the hero above it. The door wants 2+ FINISHED trips, because below
/// that the atlas has no traveled pins, no Traveled colophon group (it does not
/// render at zero) and an index with no rows — a door onto nothing. A traveler
/// with two trips still ahead of them therefore gets the band and no door, and
/// these tests exist so that pair cannot quietly collapse into one number.
///
/// Deliberately the same three cases the trips-list header is held to in
/// trips_list_footprint_test, including the under-way trip: two doors onto one
/// screen that disagreed about when to appear would be worse than either rule.
/// The other end of the door — that it opens the atlas and comes BACK to Home
/// rather than to the Trips list — is asserted in travel_atlas_screen_test,
/// beside the trips-list door's own, because it needs the real shell.
///
/// Dates are relative to DateTime.now() so the past/ahead split stays
/// deterministic.
class _FixedTripsApiService extends TripsApiService {
  final List<Trip> trips;

  _FixedTripsApiService(this.trips) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<Trip>> listTrips() async => trips;
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

Trip _trip(String id, String title, {String? start, String? end}) => Trip(
      id: id,
      title: title,
      startDate: start,
      endDate: end,
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
    );

Future<void> _pumpBand(WidgetTester tester,
    {List<Trip> trips = const []}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FixedTripsApiService(trips)),
        tripCacheProvider.overrideWithValue(TripCache('u1')),
      ],
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        home: const Scaffold(body: HomeTravelsBand()),
      ),
    ),
  );

  // The band is a READER, never a fetcher — its dartdoc's whole point is that
  // the shell's mounted TripsListScreen already feeds tripsProvider, so Home
  // costs no request of its own. Nothing in this tree plays that part, so the
  // load is triggered here rather than papered over by overriding
  // tripsProvider itself, which would also stub out the notifier this band is
  // meant to be reading through.
  final container =
      ProviderScope.containerOf(tester.element(find.byType(HomeTravelsBand)));
  await container.read(tripsProvider.notifier).loadTrips();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('no band at all below two owned trips', (tester) async {
    await _pumpBand(tester, trips: [
      _trip('past', 'Iberia Loop', start: _rel(-30), end: _rel(-26)),
    ]);

    expect(find.byType(TravelFootprintCard), findsNothing);
    expect(find.byKey(kHomeTravelAtlasSeeAllKey), findsNothing);
  });

  group('the atlas door', () {
    testWidgets('absent with one finished trip', (tester) async {
      await _pumpBand(tester, trips: [
        _trip('past', 'Iberia Loop', start: _rel(-30), end: _rel(-26)),
        _trip('next', 'Madrid Trip', start: _rel(10), end: _rel(12)),
      ]);

      expect(find.byKey(kHomeTravelAtlasSeeAllKey), findsNothing);
      // The band itself is present — the two gates ask different questions.
      expect(find.byType(TravelFootprintCard), findsOneWidget);
    });

    testWidgets('present at two finished trips', (tester) async {
      await _pumpBand(tester, trips: [
        _trip('past', 'Iberia Loop', start: _rel(-30), end: _rel(-26)),
        _trip('older', 'Athens Trip', start: _rel(-90), end: _rel(-85)),
      ]);

      expect(find.byKey(kHomeTravelAtlasSeeAllKey), findsOneWidget);
    });

    testWidgets('absent when the second started trip is still under way',
        (tester) async {
      // travelStats reports two traveled trips here. One of them is happening
      // right now, and a retrospective is not where it belongs — the same
      // category error the trips list already refuses for "Past trips".
      await _pumpBand(tester, trips: [
        _trip('past', 'Iberia Loop', start: _rel(-30), end: _rel(-26)),
        _trip('live', 'Athens Now', start: _rel(-2), end: _rel(5)),
      ]);

      expect(find.byKey(kHomeTravelAtlasSeeAllKey), findsNothing);
      expect(find.byType(TravelFootprintCard), findsOneWidget);
    });
  });
}
