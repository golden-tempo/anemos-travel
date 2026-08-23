import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/booking_todos_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';

import 'support/chip_finders.dart';
import 'support/l10n_test_app.dart';

/// Returns a fixed trip without hitting the network, so we can exercise the
/// real TripDetailScreen render path (and its booking-todo derivation).
class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// Records the derived payload the screen tries to sync, then fails like the
/// offline test env (the screen swallows the error).
class _CapturingBookingTodosApiService extends BookingTodosApiService {
  final List<List<Map<String, dynamic>>> syncedPayloads = [];
  _CapturingBookingTodosApiService()
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<BookingTodo>> syncTodos(
      String tripId, List<Map<String, dynamic>> derived) async {
    syncedPayloads.add(derived);
    throw Exception('offline test env');
  }
}

ItineraryItem _item(int pos, String name, String city, {int? day}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: '$city address',
      // Zero coords so the screen skips the map widget in the test env.
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

Trip _trip(List<ItineraryItem> items, {List<Accommodation>? stays}) => Trip(
      id: 't1',
      title: 'Squeeze',
      startDate: '2026-09-01',
      endDate: '2026-09-07',
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: items,
      accommodations: stays,
    );

Future<List<Map<String, dynamic>>> _pumpAndCapture(
    WidgetTester tester, Trip trip) async {
  final fake = _CapturingBookingTodosApiService();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        bookingTodosApiServiceProvider.overrideWithValue(fake),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
  expect(fake.syncedPayloads, isNotEmpty);
  return fake.syncedPayloads.last;
}

void main() {
  testWidgets(
      'an out-of-order item strands; booking dates follow the rendered spans',
      (WidgetTester tester) async {
    // Medellín holds a stray day-6 item while Quito's own item sits on day 5
    // — the shape the old derivation answered by collapsing Quito to a
    // zero-night stop at Sep 6. Under the boundary rule
    // (specs/leg-departure-dates) each leg runs to the next arrival: the
    // stray item strands outside Medellín's window and every booking date
    // rides the spans the page renders.
    final derived = await _pumpAndCapture(
      tester,
      _trip([
        _item(0, 'Museo', 'Medellín', day: 1),
        _item(1, 'Comuna 13', 'Medellín', day: 6),
        _item(2, 'Quito', 'Quito', day: 5),
        _item(3, 'Mitad del Mundo', 'Galápagos', day: 6),
        _item(4, 'Tortuga Bay', 'Galápagos', day: 7),
      ]),
    );

    final quitoStay =
        derived.singleWhere((t) => t['todo_key'] == 'stay:quito');
    expect(quitoStay['depart_date'], '2026-09-05');
    expect(quitoStay['return_date'], '2026-09-06');
    expect(quitoStay['subtitle'], 'Sep 5 – Sep 6');

    expect(
        derived.singleWhere(
            (t) => t['todo_key'] == 'transport:medellín>>quito')['depart_date'],
        '2026-09-05');
    // The onward flight rides Quito's VISIBLE end — Galápagos's arrival day.
    expect(
        derived.singleWhere((t) =>
            t['todo_key'] == 'transport:quito>>galápagos')['depart_date'],
        '2026-09-06');

    final galStay =
        derived.singleWhere((t) => t['todo_key'] == 'stay:galápagos');
    expect(galStay['depart_date'], '2026-09-06');
    expect(galStay['return_date'], '2026-09-07');

    // Headers: every leg carries a real range and a night count — the
    // stray item collapses nothing.
    expect(chipTextIn('Medellín', 'Sep 1 – Sep 5'), findsOneWidget);
    expect(chipTextIn('Medellín', '· 4 nights'), findsOneWidget);
    expect(chipTextIn('Quito', 'Sep 5 – Sep 6'), findsOneWidget);
    expect(chipTextIn('Quito', '· 1 night'), findsOneWidget);
    expect(chipTextIn('Galápagos', 'Sep 6 – Sep 7'), findsOneWidget);
    expect(chipTextIn('Galápagos', '· 1 night'), findsOneWidget);
  });

  testWidgets('each leg hands off at the next arrival, out of order or not',
      (WidgetTester tester) async {
    final derived = await _pumpAndCapture(
      tester,
      _trip([
        _item(0, 'Museo', 'Medellín', day: 1),
        _item(1, 'Comuna 13', 'Medellín', day: 6),
        _item(2, 'Quito', 'Quito', day: 4),
        _item(3, 'Guayaquil', 'Guayaquil', day: 5),
      ]),
    );

    final quitoStay = derived.singleWhere((t) => t['todo_key'] == 'stay:quito');
    expect(quitoStay['depart_date'], '2026-09-04');
    expect(quitoStay['return_date'], '2026-09-05');
    final guayaquilStay =
        derived.singleWhere((t) => t['todo_key'] == 'stay:guayaquil');
    expect(guayaquilStay['depart_date'], '2026-09-05');
    expect(guayaquilStay['return_date'], '2026-09-07');
    expect(
        derived.singleWhere(
            (t) => t['todo_key'] == 'transport:medellín>>quito')['depart_date'],
        '2026-09-04');
    expect(
        derived.singleWhere((t) =>
            t['todo_key'] == 'transport:quito>>guayaquil')['depart_date'],
        '2026-09-05');
  });

  testWidgets('a confirmed stay is never collapsed by a neighbour\'s items',
      (WidgetTester tester) async {
    // Quito carries an explicit confirmed stay (Sep 3–5); Medellín's stray
    // day-6 item strands rather than moving the traveler's own dates.
    final derived = await _pumpAndCapture(
      tester,
      _trip(
        [
          _item(0, 'Museo', 'Medellín', day: 1),
          _item(1, 'Comuna 13', 'Medellín', day: 6),
          _item(2, 'Quito', 'Quito', day: 5),
        ],
        stays: const [
          Accommodation(
            id: 'a1',
            name: 'Hotel Quito',
            address: 'Av. González Suárez, Quito, Ecuador',
            checkIn: '2026-09-03',
            checkOut: '2026-09-05',
          ),
        ],
      ),
    );

    final quitoStay =
        derived.singleWhere((t) => t['todo_key'] == 'stay:quito');
    expect(quitoStay['depart_date'], '2026-09-03');
    expect(quitoStay['return_date'], '2026-09-05');
    expect(chipTextIn('Quito', 'Sep 3 – Sep 5'), findsOneWidget);
    expect(chipTextIn('Quito', '· 2 nights'), findsOneWidget);
  });
}
