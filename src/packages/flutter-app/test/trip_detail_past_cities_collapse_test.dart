import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/route_request.dart';
import 'package:travel_route_planner/models/route_response.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/weather.dart';
import 'package:travel_route_planner/providers/api_client_provider.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/providers/weather_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/booking_todos_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/services/weather_api_service.dart';

import 'support/l10n_test_app.dart';

/// Past cities land collapsed (specs/today-mode): opening an IN-PROGRESS trip
/// folds the city groups whose visible range ended before today, so the
/// screen opens at the trip's live edge instead of days of history. The fold
/// is a one-shot seed into the same session set a header tap edits — the
/// traveler re-expanding a past city wins — and trips that are undated, not
/// started, or already finished render exactly as before.
///
/// All assertions are structural (widget presence/absence, taps); nothing
/// measures rendered text (the widget-test font is not Inter; see CLAUDE.md).
/// Dates are built relative to the device's civil date, UTC-normalized like
/// utils/trip_days.dart's daysUntilTrip, so a DST transition inside the
/// fixture window cannot shift a day.

final DateTime _now = DateTime.now();
final DateTime _todayUtc = DateTime.utc(_now.year, _now.month, _now.day);

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// The civil date [days] from today, as the API's YYYY-MM-DD.
String _rel(int days) => _iso(_todayUtc.add(Duration(days: days)));

class _OneTripApiService extends TripsApiService {
  final Trip trip;
  _OneTripApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) => Future.value(trip);
}

class _InstantApiClient extends ApiClient {
  _InstantApiClient() : super(baseUrl: 'http://test');

  @override
  Future<RouteResponse> optimizeRoute(RouteRequest request) =>
      Future.value(RouteResponse(
        optimizedRoute: const [],
        totalDistanceKm: 0,
        totalTravelTimeMin: 0,
        totalVisitTimeMin: 0,
        totalTripTimeMin: 0,
        locationTimings: const [],
        algorithm: 'preserve_order',
        locationCount: 0,
        status: 'success',
      ));
}

class _InstantBookingTodosApiService extends BookingTodosApiService {
  _InstantBookingTodosApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<BookingTodo>> syncTodos(
          String tripId, List<Map<String, dynamic>> derived) =>
      Future.value(const <BookingTodo>[]);
}

class _InstantWeatherApiService extends WeatherApiService {
  _InstantWeatherApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<WeatherReport> getTripWeather(String city, String startDate,
          {String? endDate}) async =>
      const WeatherReport();
}

ItineraryItem _item(int pos, String name, {int? day, String? city}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: '$name street',
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

Trip _tripWith(String start, String end, List<ItineraryItem> items) => Trip(
      id: 't1',
      title: 'Long Trek',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      startDate: start,
      endDate: end,
      items: items,
    );

/// Day 4 of 6 today: Pastville departed the day before yesterday (its visible
/// range ends at Currenton's arrival, yesterday+1 back — strictly past),
/// Currenton holds today, Futureton is ahead.
Trip _midTrip() => _tripWith(_rel(-3), _rel(2), [
      _item(0, 'Old Fort', day: 1, city: 'Pastville'),
      _item(1, 'Old Cafe', day: 2, city: 'Pastville'),
      _item(2, 'Now Plaza', day: 3, city: 'Currenton'),
      _item(3, 'Now Museum', day: 4, city: 'Currenton'),
      _item(4, 'Next Pier', day: 5, city: 'Futureton'),
      _item(5, 'Next Park', day: 6, city: 'Futureton'),
    ]);

/// The city being departed TODAY: Leaveton's visible range ends at
/// Nextville's arrival — today, not strictly before it.
Trip _departingTodayTrip() => _tripWith(_rel(-1), _rel(1), [
      _item(0, 'Morning Walk', day: 1, city: 'Leaveton'),
      _item(1, 'Arrival Fair', day: 2, city: 'Nextville'),
    ]);

Future<void> _pump(WidgetTester tester, Trip trip) async {
  // Tall surface so every fixture lays out in full: slivers are lazy, and on
  // the default 600px window a below-fold item is simply never built — which
  // would make the collapsed-vs-rendered assertions here indistinguishable
  // from scroll position. At 2600px the whole list fits, the Today
  // auto-scroll has nothing to scroll, and absence means COLLAPSED.
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_OneTripApiService(trip)),
        apiClientProvider.overrideWithValue(_InstantApiClient()),
        bookingTodosApiServiceProvider
            .overrideWithValue(_InstantBookingTodosApiService()),
        weatherApiServiceProvider
            .overrideWithValue(_InstantWeatherApiService()),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('mid-trip: departed city lands collapsed, today and the future stay open',
      (WidgetTester tester) async {
    await _pump(tester, _midTrip());

    // Pastville folded to its header: the header renders, its items do not.
    expect(find.text('Pastville'), findsWidgets);
    expect(find.text('Old Fort'), findsNothing);
    expect(find.text('Old Cafe'), findsNothing);

    // Today's city and the one ahead render in full.
    expect(find.text('Now Plaza'), findsWidgets);
    expect(find.text('Now Museum'), findsWidgets);
    expect(find.text('Next Pier'), findsWidgets);
    expect(find.text('Next Park'), findsWidgets);
  });

  testWidgets('a header tap re-expands a folded past city, and it stays open',
      (WidgetTester tester) async {
    await _pump(tester, _midTrip());
    expect(find.text('Old Fort'), findsNothing);

    // The whole city header is the InkWell toggle.
    await tester.tap(find.text('Pastville').first);
    await tester.pumpAndSettle();
    expect(find.text('Old Fort'), findsWidgets);

    // The seed is one-shot: later frames must not re-fold the traveler's
    // choice (regression guard against seeding from build).
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Old Fort'), findsWidgets);
  });

  testWidgets('the city being departed today keeps its morning visible',
      (WidgetTester tester) async {
    await _pump(tester, _departingTodayTrip());
    expect(find.text('Morning Walk'), findsWidgets);
    expect(find.text('Arrival Fair'), findsWidgets);
  });

  testWidgets('a trip that has not started folds nothing',
      (WidgetTester tester) async {
    await _pump(
        tester,
        _tripWith(_rel(1), _rel(3), [
          _item(0, 'First Stop', day: 1, city: 'Alpha'),
          _item(1, 'Second Stop', day: 3, city: 'Beta'),
        ]));
    expect(find.text('First Stop'), findsWidgets);
    expect(find.text('Second Stop'), findsWidgets);
  });

  testWidgets('a finished trip folds nothing — a memento renders in full',
      (WidgetTester tester) async {
    await _pump(
        tester,
        _tripWith(_rel(-5), _rel(-3), [
          _item(0, 'Was First', day: 1, city: 'Alpha'),
          _item(1, 'Was Last', day: 3, city: 'Beta'),
        ]));
    expect(find.text('Was First'), findsWidgets);
    expect(find.text('Was Last'), findsWidgets);
  });
}
