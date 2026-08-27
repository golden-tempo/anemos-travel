import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/location_timing.dart';
import 'package:travel_route_planner/models/route_request.dart';
import 'package:travel_route_planner/models/route_response.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/api_client_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';

import 'support/l10n_test_app.dart';

/// Day travel times under PER-DAY compute (specs/day-travel-times): the
/// failure modes that kept the feature dark for weeks — a >50-location trip
/// 400ing the single whole-trip request (Mode A), and one unresolvable place
/// nulling every day's timings (Mode B) — are pinned here as local, not
/// global; plus the settled density rule and the v2 hotel anchor rows.
///
/// Every fixture is FUTURE-dated via calendar-day arithmetic (the #570 rule,
/// re-learnt in #579): #576 folds departed cities by DateTime.now(), so a
/// fixed near-past date ages into the fold and the assertions go red on a
/// clean main overnight.

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

// Calendar-day arithmetic, never Duration: Duration-based day addition lands
// a calendar day short in the midnight hour across a DST fall-back.
String _rel(int days) {
  final now = DateTime.now();
  return _iso(DateTime(now.year, now.month, now.day + days));
}

DateTime _relDate(int days) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day + days);
}

/// The trip starts 30 days out, safely clear of #576's departed-city fold.
const int _kStart = 30;

/// Returns a fixed trip without hitting the network, so the real
/// TripDetailScreen render path runs.
class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

typedef _Leg = ({int min, double km, String? mode});

/// Serves per-leg timings for /optimize-route keyed by the FROM location's
/// name, so every per-day request shape gets the same legs; the last location
/// of each request is zeroed like the real one-way preserve-order response.
/// Mirrors the server's 50-location cap as a 400 so Mode A is a real failure
/// here, and [failWhen] simulates a request-level loss for one day.
class _FakeRouteApi extends ApiClient {
  final Map<String, _Leg> legsByFrom;
  final bool Function(RouteRequest request)? failWhen;
  final List<RouteRequest> requests = [];
  _FakeRouteApi(this.legsByFrom, {this.failWhen})
      : super(baseUrl: 'http://test');

  @override
  Future<RouteResponse> optimizeRoute(RouteRequest request) async {
    requests.add(request);
    if (request.locations.length > 50) {
      throw const ApiException(
          statusCode: 400,
          message: 'Maximum 50 locations supported',
          endpoint: 'optimize-route');
    }
    final f = failWhen;
    if (f != null && f(request)) {
      throw const ApiException(
          statusCode: 422,
          message: 'no locations resolved',
          endpoint: 'optimize-route');
    }
    final timings = <LocationTiming>[];
    for (var i = 0; i < request.locations.length; i++) {
      final leg = i < request.locations.length - 1
          ? legsByFrom[request.locations[i].name]
          : null;
      timings.add(LocationTiming(
        location: request.locations[i],
        arrivalTime: '09:00',
        departureTime: '10:00',
        visitDurationMin: 60,
        travelToNextMin: leg?.min ?? 0,
        travelToNextKm: leg?.km ?? 0,
        travelToNextMode: leg?.mode,
      ));
    }
    return RouteResponse(
      optimizedRoute: request.locations,
      totalDistanceKm: 0,
      totalTravelTimeMin: 0,
      totalVisitTimeMin: 0,
      totalTripTimeMin: 0,
      locationTimings: timings,
      algorithm: 'preserve_order',
      locationCount: request.locations.length,
      status: 'success',
    );
  }
}

ItineraryItem _item(int pos, String name, {required int day}) => ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: 'Paris, France',
      // Nonzero, plausibly-Paris coords so the screen requests travel times.
      latitude: 48.85 + pos * 0.001,
      longitude: 2.35 + pos * 0.001,
      category: 'attraction',
      day: day,
      city: 'Paris',
    );

Trip _trip(List<ItineraryItem> items,
        {List<Accommodation>? stays, int lengthDays = 12}) =>
    Trip(
      id: 't1',
      title: 'Paris Trip',
      startDate: _rel(_kStart),
      endDate: _rel(_kStart + lengthDays),
      createdAt: _rel(-1),
      updatedAt: _rel(-1),
      items: items,
      accommodations: stays,
    );

/// Hop labels scoped to the itinerary's stop batches. The MAP renders the
/// same travel store as unthresholded "~N min" segment labels (by design —
/// segmentLabels read _travelByPos), so a global text finder would count
/// those too; the density rule under test lives on the list side only.
Finder _inList(Finder matching) =>
    find.descendant(of: find.byType(SliverReorderableList), matching: matching);

Future<void> _pump(WidgetTester tester, Trip trip, _FakeRouteApi api,
    {Size size = const Size(1200, 3000)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        apiClientProvider.overrideWithValue(api),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'Mode A dead: a 60-item trip goes out as per-day requests under the '
      'API cap and still renders travel times', (WidgetTester tester) async {
    // 10 days x 6 stops. The old compute posted all 60 in ONE request; the
    // fake, like the real server, 400s past 50 locations — so against the old
    // code this fixture renders no travel label at all (red), and against
    // per-day compute every request stays small (green).
    final items = <ItineraryItem>[
      for (var d = 1; d <= 10; d++)
        for (var s = 0; s < 6; s++)
          _item((d - 1) * 6 + s, 'Stop ${(d - 1) * 6 + s}', day: d),
    ];
    final api = _FakeRouteApi({
      for (var p = 0; p < 60; p++) 'Stop $p': (min: 12, km: 1.0, mode: 'walk'),
    });
    await _pump(tester, _trip(items), api);

    expect(api.requests.length, 10,
        reason: 'one request per day-run, not one per trip');
    expect(api.requests.every((r) => r.locations.length <= 50), isTrue,
        reason: 'no request may cross the API\'s 50-location cap');
    // Travel labels render (the lazily-built list shows the first days).
    expect(find.text('~12 min'), findsWidgets);
    // Day totals render: 5 in-day legs x 12 min = ~1h per day.
    expect(find.text('~1h travel'), findsWidgets);
  });

  testWidgets('a failing day darkens only its own day, and the miss is logged',
      (WidgetTester tester) async {
    // Capture debugPrint in the body and restore it BEFORE the test ends:
    // the binding asserts foundation debug vars are back before tearDowns
    // run, so addTearDown is too late for this one.
    final logs = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      logs.add(message ?? '');
    };

    final items = [
      _item(0, 'Alpha', day: 1),
      _item(1, 'Beta', day: 1),
      _item(2, 'Gamma', day: 1),
      _item(3, 'Delta', day: 2),
      _item(4, 'Poison Cellar', day: 2),
      _item(5, 'Epsilon', day: 2),
    ];
    // Day 2's request (it carries Poison Cellar) fails wholesale — the
    // per-day analogue of Mode B. Against the old whole-trip compute the ONE
    // request contains the poison and every label on the trip goes dark (red
    // here); per-day, day 1 keeps its labels.
    final api = _FakeRouteApi(
      {
        'Alpha': (min: 12, km: 1.0, mode: 'walk'),
        'Beta': (min: 12, km: 1.0, mode: 'walk'),
        'Delta': (min: 12, km: 1.0, mode: 'walk'),
        'Poison Cellar': (min: 12, km: 1.0, mode: 'walk'),
      },
      failWhen: (r) => r.locations.any((l) => l.name == 'Poison Cellar'),
    );
    try {
      await _pump(tester, _trip(items), api);
    } finally {
      debugPrint = original;
    }

    // Day 1's two legs render; day 2 contributes none (its 12-min legs would
    // have made this 4).
    expect(_inList(find.text('~12 min')), findsNWidgets(2));
    expect(find.text('~24 min travel'), findsOneWidget,
        reason: 'day 1 total present');
    expect(logs.any((m) => m.contains('failed')), isTrue,
        reason: 'a dark day must be diagnosable — catch (_) alone was the bug');
  });

  testWidgets('the day travel total renders at narrow width, shortened',
      (WidgetTester tester) async {
    final items = [
      _item(0, 'Alpha', day: 1),
      _item(1, 'Beta', day: 1),
      _item(2, 'Gamma', day: 1),
    ];
    final api = _FakeRouteApi({
      'Alpha': (min: 12, km: 1.0, mode: 'walk'),
      'Beta': (min: 12, km: 1.0, mode: 'walk'),
    });
    // Below kRailBreakpoint (800): the old code hid the total entirely here
    // (red against it); the density decision was to shorten the string, not
    // hide the number.
    await _pump(tester, _trip(items), api, size: const Size(500, 2400));

    expect(find.text('~24 min'), findsOneWidget,
        reason: 'narrow keeps the total, without the "travel" suffix');
    expect(find.text('~24 min travel'), findsNothing);
    expect(_inList(find.text('~12 min')), findsNWidgets(2),
        reason: 'per-hop labels above threshold render at narrow too');
  });

  testWidgets(
      'a 2.4 km hop reads as transit ~13 min — mode icon, time-only label, '
      'no hard-coded car anywhere', (WidgetTester tester) async {
    final items = [
      _item(0, 'Vondelpark', day: 1),
      _item(1, 'Cafe Smalle', day: 1),
      _item(2, 'Door 74', day: 1),
    ];
    // The literal spec numbers (#577's heuristic): 2.41 km straight-line
    // x1.3 detour = 3.13 km at 15 km/h transit = ceil(12.5) = 13 min. The
    // old client showed this hop as "13 min · 3.1 km" WITH A CAR (km > 1.2).
    final api = _FakeRouteApi({
      'Vondelpark': (min: 13, km: 3.13, mode: 'transit'),
      'Cafe Smalle': (min: 17, km: 1.86, mode: 'walk'),
    });
    await _pump(tester, _trip(items), api);

    expect(_inList(find.text('~13 min')), findsOneWidget);
    expect(_inList(find.textContaining('km')), findsNothing,
        reason: 'distance dropped from ordinary hop labels');
    expect(find.byIcon(Icons.directions_transit_outlined), findsOneWidget,
        reason: 'the hop icon follows the computed mode');
    // Dominant mode is walk (tie on count, walk wins on minutes 17 v 13), so
    // the day header icon is a walker — and no surface hard-codes a car.
    expect(find.byIcon(Icons.directions_walk), findsNWidgets(2),
        reason: 'walk connector + day-header dominant-mode icon');
    expect(find.byIcon(Icons.directions_car_outlined), findsNothing,
        reason: 'the hard-coded day-header car is gone');
  });

  testWidgets(
      'hotel anchor rows render for a coordinated confirmed stay — both '
      'directions, distance kept, exempt from the threshold, in the total',
      (WidgetTester tester) async {
    final items = [
      _item(0, 'Musee A', day: 1),
      _item(1, 'Bistro B', day: 1),
    ];
    final stay = Accommodation(
      id: 'a1',
      name: 'Hotel du Nord',
      address: 'Paris',
      latitude: 48.87,
      longitude: 2.36,
      checkIn: _rel(_kStart),
      checkOut: _rel(_kStart + 2),
    );
    final api = _FakeRouteApi({
      // The stay is the request's first waypoint; its leg is the "from the
      // hotel" hop. The last item's leg is the "back to the hotel" hop — at
      // 9 min it sits UNDER the 10-min hop threshold and must render anyway
      // (anchors are exempt).
      'Hotel du Nord': (min: 15, km: 1.1, mode: 'walk'),
      'Musee A': (min: 12, km: 1.0, mode: 'walk'),
      'Bistro B': (min: 9, km: 0.8, mode: 'walk'),
    });
    await _pump(tester, _trip(items, stays: [stay]), api);

    expect(find.text('~15 min · 1.1 km from the hotel'), findsOneWidget);
    expect(find.text('~9 min · 0.8 km back to the hotel'), findsOneWidget);
    // The day total counts the anchor legs: 15 + 12 + 9.
    expect(find.text('~36 min travel'), findsOneWidget);
  });

  testWidgets('no stay coordinates, no hotel rows — and no placeholder',
      (WidgetTester tester) async {
    final items = [
      _item(0, 'Musee A', day: 1),
      _item(1, 'Bistro B', day: 1),
    ];
    // Same stay, ungeocoded (the pre-#578 manual-sheet shape).
    final stay = Accommodation(
      id: 'a1',
      name: 'Hotel du Nord',
      address: 'Paris',
      checkIn: _rel(_kStart),
      checkOut: _rel(_kStart + 2),
    );
    final api = _FakeRouteApi({
      'Hotel du Nord': (min: 15, km: 1.1, mode: 'walk'),
      'Musee A': (min: 12, km: 1.0, mode: 'walk'),
      'Bistro B': (min: 9, km: 0.8, mode: 'walk'),
    });
    await _pump(tester, _trip(items, stays: [stay]), api);

    expect(find.textContaining('from the hotel'), findsNothing);
    expect(find.textContaining('back to the hotel'), findsNothing);
    // Un-anchored, the day total is the in-day legs alone.
    expect(find.text('~12 min travel'), findsOneWidget);
  });

  testWidgets('a collapsed day renders no hotel rows (folded days stay bare)',
      (WidgetTester tester) async {
    final items = [
      _item(0, 'Musee A', day: 1),
      _item(1, 'Bistro B', day: 1),
    ];
    final stay = Accommodation(
      id: 'a1',
      name: 'Hotel du Nord',
      address: 'Paris',
      latitude: 48.87,
      longitude: 2.36,
      checkIn: _rel(_kStart),
      checkOut: _rel(_kStart + 2),
    );
    final api = _FakeRouteApi({
      'Hotel du Nord': (min: 15, km: 1.1, mode: 'walk'),
      'Musee A': (min: 12, km: 1.0, mode: 'walk'),
      'Bistro B': (min: 9, km: 0.8, mode: 'walk'),
    });
    await _pump(tester, _trip(items, stays: [stay]), api);
    expect(find.textContaining('from the hotel'), findsOneWidget);

    // Collapse day 1 via its header (the calendar-date label).
    final dayLabel = DateFormat.MMMEd().format(_relDate(_kStart));
    await tester.tap(find.text(dayLabel));
    await tester.pumpAndSettle();

    expect(find.textContaining('from the hotel'), findsNothing);
    expect(find.textContaining('back to the hotel'), findsNothing);
    expect(find.text(dayLabel), findsOneWidget, reason: 'header remains');
    expect(find.text('~36 min travel'), findsOneWidget,
        reason: 'the collapsed header keeps its glanceable total');
  });

  testWidgets(
      'the threshold suppresses a 3-minute hop; a short hop in a differing '
      'mode still earns its label', (WidgetTester tester) async {
    final items = [
      _item(0, 'Alpha', day: 1),
      _item(1, 'Beta', day: 1),
      _item(2, 'Gamma', day: 1),
      _item(3, 'Delta', day: 1),
    ];
    final api = _FakeRouteApi({
      'Alpha': (min: 3, km: 0.25, mode: 'walk'),
      'Beta': (min: 12, km: 1.0, mode: 'walk'),
      // 4 min but transit on a walking day: decision-changing, so labelled.
      'Gamma': (min: 4, km: 1.9, mode: 'transit'),
    });
    await _pump(tester, _trip(items), api);

    // Substring-match, deliberately: the OLD label for this hop was
    // "3 min · 0.3 km", which this catches too — red against the old code,
    // where every hop rendered a label.
    expect(_inList(find.textContaining('3 min')), findsNothing,
        reason: 'a 3-minute hop is the hairline, not a row');
    expect(_inList(find.text('~12 min')), findsOneWidget);
    expect(_inList(find.text('~4 min')), findsOneWidget,
        reason: 'mode-differs overrides the minutes threshold');
  });
}
