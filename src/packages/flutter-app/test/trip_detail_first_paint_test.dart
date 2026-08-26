import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/route_request.dart';
import 'package:travel_route_planner/models/route_response.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/trip_finding.dart';
import 'package:travel_route_planner/models/weather.dart';
import 'package:travel_route_planner/providers/api_client_provider.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/trip_cache_provider.dart';
import 'package:travel_route_planner/providers/trip_review_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/providers/weather_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/booking_todos_api_service.dart';
import 'package:travel_route_planner/services/trip_cache.dart';
import 'package:travel_route_planner/services/trip_review_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/services/weather_api_service.dart';
import 'package:travel_route_planner/widgets/app_map.dart';
import 'package:travel_route_planner/widgets/trip_map.dart';

import 'support/l10n_test_app.dart';

/// Trip-detail time-to-interactive (this lane's three levers):
///  1. the first frame gates on the trip GET alone — travel times and the
///     booking-todo sync land in place behind it and degrade silently;
///  2. a cached trip paints immediately (no spinner) with the network fetch
///     running behind it, updating in place;
///  3. the live tile map and the enhancement fetches (review, weather) mount
///     one frame AFTER first paint, so the first frame costs only what it
///     shows — except providers that are already alive (warm revisit), whose
///     cached value renders in the first frame for free.
///
/// All assertions here are structural (widget presence, call counts, scroll
/// offsets set programmatically) — nothing measures rendered text (the
/// widget-test font is not Inter; see CLAUDE.md).

/// getTrip answers from a queue: a Trip resolves, a Completer stays pending
/// until the test completes it, anything else throws.
class _QueuedTripsApiService extends TripsApiService {
  final List<Object> responses;
  int calls = 0;

  _QueuedTripsApiService(this.responses)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) {
    final next =
        responses[calls < responses.length ? calls : responses.length - 1];
    calls++;
    if (next is Trip) return Future.value(next);
    if (next is Completer<Trip>) return next.future;
    return Future.error(next);
  }
}

/// /optimize-route held pending or failing, so lever 1 can observe the
/// screen render while travel times are still (or never) landing.
class _GatedApiClient extends ApiClient {
  /// A Completer<RouteResponse> serves its future; anything else throws.
  final Object gate;
  int calls = 0;

  _GatedApiClient(this.gate) : super(baseUrl: 'http://test');

  @override
  Future<RouteResponse> optimizeRoute(RouteRequest request) {
    calls++;
    final g = gate;
    if (g is Completer<RouteResponse>) return g.future;
    return Future.error(g);
  }
}

/// Booking-todo sync held pending, failing, or answering instantly.
class _GatedBookingTodosApiService extends BookingTodosApiService {
  /// List<BookingTodo> resolves, a Completer serves its future, anything
  /// else throws.
  final Object gate;
  int calls = 0;

  _GatedBookingTodosApiService(this.gate)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<BookingTodo>> syncTodos(
      String tripId, List<Map<String, dynamic>> derived) {
    calls++;
    final g = gate;
    if (g is List<BookingTodo>) return Future.value(g);
    if (g is Completer<List<BookingTodo>>) return g.future;
    return Future.error(g);
  }
}

/// Counts review fetches, so lever 3 can pin WHEN the fetch fires.
class _CountingReviewApiService extends TripReviewApiService {
  final TripReview review;
  int calls = 0;

  _CountingReviewApiService(this.review)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<TripReview> getReview(String tripId,
      {bool checkHours = false}) async {
    calls++;
    return review;
  }
}

/// Counts weather fetches (returns an empty report — count is the point).
class _CountingWeatherApiService extends WeatherApiService {
  int calls = 0;

  _CountingWeatherApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<WeatherReport> getTripWeather(String city, String startDate,
      {String? endDate}) async {
    calls++;
    return const WeatherReport();
  }
}

ItineraryItem _item(int pos, String name,
        {double lat = 0, double lng = 0, int? day, String? city}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: '$name street, ${city ?? 'Athens'}',
      latitude: lat,
      longitude: lng,
      category: 'attraction',
      day: day,
      city: city,
    );

/// Undated, zero-coord single stop: no map, no weather, no events — the
/// minimal screen for levers 1–2.
Trip _trip(String title) => Trip(
      id: 't1',
      title: title,
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [_item(0, 'Acropolis')],
    );

/// Two coordinated stops: the map band renders and travel times fire.
Trip _coordTrip() => Trip(
      id: 't1',
      title: 'Paris Trip',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [
        _item(0, 'Louvre', lat: 48.86, lng: 2.33, city: 'Paris'),
        _item(1, 'Orsay', lat: 48.85, lng: 2.32, city: 'Paris'),
      ],
    );

/// Dated city trip: visible leg ranges carry dates, so the weather lookups
/// (wear action + day chips) have a real query to fire.
Trip _datedTrip() => Trip(
      id: 't1',
      title: 'Paris Trip',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      startDate: '2026-09-10',
      endDate: '2026-09-11',
      items: [
        _item(0, 'Louvre', day: 1, city: 'Paris'),
        _item(1, 'Orsay', day: 2, city: 'Paris'),
      ],
    );

/// Enough zero-coord stops that the itinerary scrolls in any font.
Trip _longTrip(String title) => Trip(
      id: 't1',
      title: title,
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [for (var i = 0; i < 30; i++) _item(i, 'Stop $i')],
    );

/// The header's Refine entry (ActionChip since the wave-2 redesign): its
/// onPressed is the screen's clearest "not in offline mode" signal.
ActionChip _refineChip(WidgetTester tester) =>
    tester.widget<ActionChip>(find.ancestor(
      of: find.text('Refine with AI'),
      matching: find.byType(ActionChip),
    ));

Future<void> _pumpDetail(WidgetTester tester, List<Override> overrides) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TripDetailScreen(tripId: 't1')),
    ),
  );
}

/// Pumps single frames until [finder] matches (bounded), leaving the tree on
/// the exact frame where it first appeared. For a content finder that means
/// the FIRST content frame: the fan-out flag flips in that frame's post-frame
/// callback, so what's deferred is still absent from the tree under test —
/// the next pump is the fan-out frame.
Future<void> _pumpUntil(WidgetTester tester, Finder finder,
    {int maxPumps = 12}) async {
  for (var i = 0; i < maxPumps && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsWidgets);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('lever 1 — first frame gates on the trip GET alone', () {
    testWidgets(
        'content renders while travel times and the todo sync are still in flight',
        (WidgetTester tester) async {
      final optimizeGate = Completer<RouteResponse>();
      final syncGate = Completer<List<BookingTodo>>();
      final api = _GatedApiClient(optimizeGate);
      final sync = _GatedBookingTodosApiService(syncGate);

      await _pumpDetail(tester, [
        tripsApiServiceProvider
            .overrideWithValue(_QueuedTripsApiService([_coordTrip()])),
        apiClientProvider.overrideWithValue(api),
        bookingTodosApiServiceProvider.overrideWithValue(sync),
      ]);
      await _pumpUntil(tester, find.text('Paris Trip'));

      // The old gate held the spinner until optimize-route AND the
      // prefs→todo-sync chain completed; both are provably still pending.
      expect(optimizeGate.isCompleted, isFalse);
      expect(syncGate.isCompleted, isFalse);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Could not load this trip'), findsNothing);

      // The follow-ups land in place afterwards — no spinner, no blanking.
      optimizeGate.complete(RouteResponse(
        optimizedRoute: const [],
        totalDistanceKm: 0,
        totalTravelTimeMin: 0,
        totalVisitTimeMin: 0,
        totalTripTimeMin: 0,
        locationTimings: const [],
        algorithm: 'preserve_order',
        locationCount: 2,
        status: 'success',
      ));
      syncGate.complete(<BookingTodo>[]);
      await tester.pumpAndSettle();
      expect(find.text('Paris Trip'), findsWidgets);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Could not load this trip'), findsNothing);
    });

    testWidgets('failing follow-up calls degrade silently behind the screen',
        (WidgetTester tester) async {
      await _pumpDetail(tester, [
        tripsApiServiceProvider
            .overrideWithValue(_QueuedTripsApiService([_coordTrip()])),
        apiClientProvider.overrideWithValue(_GatedApiClient(const ApiException(
            statusCode: 503, message: 'shed', endpoint: '/optimize-route'))),
        bookingTodosApiServiceProvider.overrideWithValue(
            _GatedBookingTodosApiService(http.ClientException('down'))),
      ]);
      await tester.pumpAndSettle();

      // Rendered screen, never blanked: no error page, no offline banner,
      // no re-spinner — and mutations stay armed (not offline mode).
      expect(find.text('Paris Trip'), findsWidgets);
      expect(find.text('Could not load this trip'), findsNothing);
      expect(find.textContaining('Offline — showing saved copy from'),
          findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(_refineChip(tester).onPressed, isNotNull);
    });
  });

  group('lever 2 — cache-first render', () {
    testWidgets(
        'a cached trip paints immediately with no spinner while the fetch runs behind',
        (WidgetTester tester) async {
      final cache = TripCache('u1');
      await cache.writeTrip(_trip('Athens Trip'));
      final pending = Completer<Trip>();
      final sync = _GatedBookingTodosApiService(<BookingTodo>[]);

      await _pumpDetail(tester, [
        tripsApiServiceProvider
            .overrideWithValue(_QueuedTripsApiService([pending])),
        tripCacheProvider.overrideWithValue(cache),
        bookingTodosApiServiceProvider.overrideWithValue(sync),
      ]);
      await _pumpUntil(tester, find.text('Athens Trip'));

      // Cached content on screen, fetch still in flight: no spinner, no
      // offline banner (mutations stay armed), no error page — and none of
      // the network side-effects have run against the cached copy.
      expect(find.text('Acropolis'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('Offline — showing saved copy from'),
          findsNothing);
      expect(find.text('Could not load this trip'), findsNothing);
      expect(sync.calls, 0,
          reason: 'the todo sync must wait for the fresh payload');

      // The fresh payload lands in place — new data, no spinner, no banner.
      pending.complete(_trip('Athens Trip (fresh)'));
      await tester.pumpAndSettle();
      expect(find.text('Athens Trip (fresh)'), findsWidgets);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('Offline — showing saved copy from'),
          findsNothing);
      expect(sync.calls, 1, reason: 'sync runs once the fresh trip landed');
    });

    testWidgets('the cached→fresh swap preserves scroll position',
        (WidgetTester tester) async {
      final cache = TripCache('u1');
      await cache.writeTrip(_longTrip('Athens Trip'));
      final pending = Completer<Trip>();

      await _pumpDetail(tester, [
        tripsApiServiceProvider
            .overrideWithValue(_QueuedTripsApiService([pending])),
        tripCacheProvider.overrideWithValue(cache),
        bookingTodosApiServiceProvider
            .overrideWithValue(_GatedBookingTodosApiService(<BookingTodo>[])),
      ]);
      await _pumpUntil(tester, find.text('Athens Trip'));

      // The traveler scrolls the cached copy…
      final scrollView =
          tester.widget<CustomScrollView>(find.byType(CustomScrollView));
      scrollView.controller!.jumpTo(150);
      await tester.pump();
      expect(scrollView.controller!.offset, 150);

      // …and the fresh payload landing must not move them.
      pending.complete(_longTrip('Athens Trip (fresh)'));
      await tester.pumpAndSettle();
      expect(find.text('Athens Trip (fresh)'), findsWidgets);
      expect(scrollView.controller!.offset, 150);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets(
        'cached render + network failure keeps the content and adds the offline affordance',
        (WidgetTester tester) async {
      final cache = TripCache('u1');
      await cache.writeTrip(_trip('Athens Trip'));
      final pending = Completer<Trip>();

      await _pumpDetail(tester, [
        tripsApiServiceProvider
            .overrideWithValue(_QueuedTripsApiService([pending])),
        tripCacheProvider.overrideWithValue(cache),
      ]);
      await _pumpUntil(tester, find.text('Athens Trip'));
      expect(find.textContaining('Offline — showing saved copy from'),
          findsNothing);

      pending.completeError(http.ClientException('down'));
      await tester.pumpAndSettle();

      // Same cached content, now clearly marked offline — never an error
      // page, never a blank.
      expect(find.text('Acropolis'), findsOneWidget);
      expect(find.textContaining('Offline — showing saved copy from'),
          findsOneWidget);
      expect(find.text('Could not load this trip'), findsNothing);
      expect(_refineChip(tester).onPressed, isNull,
          reason: 'offline mode disables mutations');
    });

    testWidgets(
        'cached render + a stable 404 still shows the error page (no resurrected trip)',
        (WidgetTester tester) async {
      final cache = TripCache('u1');
      await cache.writeTrip(_trip('Athens Trip'));
      final pending = Completer<Trip>();

      await _pumpDetail(tester, [
        tripsApiServiceProvider
            .overrideWithValue(_QueuedTripsApiService([pending])),
        tripCacheProvider.overrideWithValue(cache),
      ]);
      await _pumpUntil(tester, find.text('Athens Trip'));

      pending.completeError(const ApiException(
          statusCode: 404, message: 'gone', endpoint: '/trips/t1'));
      await tester.pumpAndSettle();

      expect(find.text('Could not load this trip'), findsOneWidget);
      expect(find.text('Acropolis'), findsNothing);
      expect(find.textContaining('Offline — showing saved copy from'),
          findsNothing);
    });
  });

  group('lever 3 — deferred first-frame fan-out', () {
    testWidgets('the live map mounts one frame after first paint, same canvas',
        (WidgetTester tester) async {
      await _pumpDetail(tester, [
        tripsApiServiceProvider
            .overrideWithValue(_QueuedTripsApiService([_coordTrip()])),
        bookingTodosApiServiceProvider
            .overrideWithValue(_GatedBookingTodosApiService(<BookingTodo>[])),
      ]);
      await _pumpUntil(tester, find.text('Paris Trip'));

      // First content frame: no live map — the band paints the exact canvas
      // an unloaded map paints, so the swap is invisible.
      expect(find.byType(TripMap), findsNothing);
      expect(
          find.byWidgetPredicate(
              (w) => w is ColoredBox && w.color == appMapBackground),
          findsOneWidget);

      // One frame later the live map is up.
      await tester.pump();
      expect(find.byType(TripMap), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byType(TripMap), findsOneWidget);
    });

    testWidgets('cold visit: the review fetch fires after first paint, not in it',
        (WidgetTester tester) async {
      final review =
          _CountingReviewApiService(const TripReview(findings: []));
      // Sync held pending so _load's end-of-load review invalidation can't
      // fire a second fetch and blur the count under assertion.
      final syncGate = Completer<List<BookingTodo>>();

      await _pumpDetail(tester, [
        tripsApiServiceProvider
            .overrideWithValue(_QueuedTripsApiService([_trip('Athens Trip')])),
        tripReviewApiServiceProvider.overrideWithValue(review),
        bookingTodosApiServiceProvider
            .overrideWithValue(_GatedBookingTodosApiService(syncGate)),
      ]);
      await _pumpUntil(tester, find.text('Athens Trip'));

      // First content frame: no review fetch, no badge.
      expect(review.calls, 0);
      expect(find.byIcon(Icons.fact_check_outlined), findsNothing);

      // The fan-out frame creates the watch → exactly one fetch.
      await tester.pump();
      expect(review.calls, 1);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.fact_check_outlined), findsOneWidget);
      expect(review.calls, 1);
    });

    testWidgets('warm revisit: an already-fetched review renders in frame one',
        (WidgetTester tester) async {
      final review =
          _CountingReviewApiService(const TripReview(findings: []));
      final container = ProviderContainer(overrides: [
        tripsApiServiceProvider
            .overrideWithValue(_QueuedTripsApiService([_trip('Athens Trip')])),
        tripReviewApiServiceProvider.overrideWithValue(review),
        bookingTodosApiServiceProvider.overrideWithValue(
            _GatedBookingTodosApiService(Completer<List<BookingTodo>>())),
      ]);
      addTearDown(container.dispose);

      // A previous visit fetched the review (non-autoDispose: it stays).
      await container
          .read(tripReviewProvider(const TripReviewKey('t1')).future);
      expect(review.calls, 1);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
              localizationsDelegates: testLocalizationsDelegates,
              home: TripDetailScreen(tripId: 't1')),
        ),
      );
      await _pumpUntil(tester, find.text('Athens Trip'));

      // The badge is up in the FIRST content frame — reading alive state is
      // free; only fetch creation is deferred — and nothing refetched.
      expect(find.byIcon(Icons.fact_check_outlined), findsOneWidget);
      expect(review.calls, 1);
    });

    testWidgets('weather lookups fire after first paint, not in it',
        (WidgetTester tester) async {
      final weather = _CountingWeatherApiService();
      final syncGate = Completer<List<BookingTodo>>();

      await _pumpDetail(tester, [
        tripsApiServiceProvider
            .overrideWithValue(_QueuedTripsApiService([_datedTrip()])),
        weatherApiServiceProvider.overrideWithValue(weather),
        bookingTodosApiServiceProvider
            .overrideWithValue(_GatedBookingTodosApiService(syncGate)),
      ]);
      await _pumpUntil(tester, find.text('Paris Trip'));

      // First content frame: no weather traffic (the wear action and the
      // day chips both build a byte-identical query, so one call total once
      // allowed).
      expect(weather.calls, 0);

      await tester.pump();
      expect(weather.calls, 1);
      await tester.pumpAndSettle();
      expect(weather.calls, 1);
    });
  });
}
