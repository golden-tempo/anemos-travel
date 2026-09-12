import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/booking_todos_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/booking_todo_card.dart';

import 'support/l10n_test_app.dart';

/// #623: the itinerary's booking checklist rows exist only to remind the
/// traveler of what's still outstanding — once a leg is booked (checked) or
/// dismissed ("removed — no booking needed"), it has nothing left to remind
/// them of there, so it drops out of the itinerary entirely. The full history
/// (booked, struck-through; dismissed, tagged and restorable) still lives on
/// the Bookings tab.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// Sync fails (mirroring the screen's swallow-on-error), so the todos seeded
/// on the trip payload survive verbatim.
class _FakeBookingTodosApiService extends BookingTodosApiService {
  _FakeBookingTodosApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<BookingTodo>> syncTodos(
          String tripId, List<Map<String, dynamic>> derived) async =>
      throw Exception('offline test env');
}

ItineraryItem _item(int pos, String name, String city, {int? day}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: '$name, $city',
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pump(WidgetTester tester, Trip trip) async {
  _useTallViewport(tester);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        bookingTodosApiServiceProvider
            .overrideWithValue(_FakeBookingTodosApiService()),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
}

Trip _trip({required List<BookingTodo> todos}) => Trip(
      id: 't1',
      title: 'Bad Ischl trip',
      startDate: '2026-09-07',
      endDate: '2026-09-11',
      createdAt: '2026-09-01',
      updatedAt: '2026-09-01',
      items: [_item(0, 'Kaiservilla', 'Bad Ischl', day: 1)],
      bookingTodos: todos,
    );

void main() {
  testWidgets(
      'a dismissed stay row is gone from the itinerary, not shown "Removed"',
      (tester) async {
    await _pump(
        tester,
        _trip(todos: const [
          BookingTodo(
              id: 'td-stay',
              kind: 'stay',
              todoKey: 'stay:bad ischl',
              title: 'Stay in Bad Ischl',
              dismissed: true),
        ]));

    expect(find.text('Stay in Bad Ischl'), findsNothing);
    expect(find.textContaining('Removed'), findsNothing);
    // The rest of the itinerary is untouched.
    expect(find.text('Kaiservilla'), findsOneWidget);

    // The Bookings tab is where a dismissed row still lives, tagged and
    // restorable.
    await tester.tap(find.text('Bookings'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(BookingTodoRow, 'Stay in Bad Ischl'),
        findsOneWidget);
    expect(find.textContaining('Removed'), findsOneWidget);
  });

  testWidgets('a booked flight row is gone from the itinerary, not struck out',
      (tester) async {
    await _pump(
        tester,
        _trip(todos: const [
          BookingTodo(
              id: 'td-flight',
              kind: 'transport',
              todoKey: 'transport:belgrade>>bad ischl',
              title: 'Belgrade → Salzburg (SZG)',
              booked: true),
        ]));

    expect(find.text('Belgrade → Salzburg (SZG)'), findsNothing);
    expect(find.text('Kaiservilla'), findsOneWidget);

    // Still on the Bookings tab, struck through.
    await tester.tap(find.text('Bookings'));
    await tester.pumpAndSettle();
    expect(
        find.widgetWithText(BookingTodoRow, 'Belgrade → Salzburg (SZG)'),
        findsOneWidget);
  });

  testWidgets('an unbooked, live row still renders inline on the itinerary',
      (tester) async {
    await _pump(
        tester,
        _trip(todos: const [
          BookingTodo(
              id: 'td-stay',
              kind: 'stay',
              todoKey: 'stay:bad ischl',
              title: 'Stay in Bad Ischl'),
        ]));

    expect(find.widgetWithText(BookingTodoRow, 'Stay in Bad Ischl'),
        findsOneWidget);
  });
}
