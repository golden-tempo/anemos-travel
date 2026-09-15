import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/booking_todos_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';

import 'support/l10n_test_app.dart';

/// The day sub-header on a phone: no calendar glyph (the city header's pin
/// two rows up already anchors the section, and two calendars said less than
/// one indent column does), and the month spelled out on EVERY row — issue
/// #642: a header that drops the month whenever it "hasn't changed" reads
/// as inconsistent next to the ones that keep it. Desktop keeps the icon and
/// always spelled the full date, so both widths now agree on the label.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// Swallows the derived-payload sync like the offline test env.
class _FakeBookingTodosApiService extends BookingTodosApiService {
  _FakeBookingTodosApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<BookingTodo>> syncTodos(
          String tripId, List<Map<String, dynamic>> derived) async =>
      throw Exception('offline test env');
}

ItineraryItem _item(int pos, String name, String city, int day) =>
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

/// Kraków Aug 29 → Sep 2: one city whose days cross a month boundary, the
/// case that used to trip up the now-removed running-month rule. Days 1..5
/// of the trip map to Aug 29, 30, 31, Sep 1, Sep 2.
Trip _monthCrossingTrip() => Trip(
      id: 't1',
      title: 'Kraków',
      startDate: '2037-08-29',
      endDate: '2037-09-02',
      createdAt: '2037-08-01',
      updatedAt: '2037-08-01',
      items: [
        _item(0, 'Rynek Główny', 'Kraków', 1),
        _item(1, 'Wawel', 'Kraków', 2),
        _item(2, 'Kazimierz', 'Kraków', 3),
        _item(3, 'Wieliczka', 'Kraków', 4),
        _item(4, 'Planty', 'Kraków', 5),
      ],
    );

Future<void> _pump(WidgetTester tester, Trip trip, Size size,
    {Locale? locale}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        bookingTodosApiServiceProvider
            .overrideWithValue(_FakeBookingTodosApiService()),
      ],
      child: localizedTestApp(
        home: TripDetailScreen(tripId: 't1'),
        locale: locale,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _phone = Size(390, 1600);
// 800 is the wide floor: _narrow is strictly `< kRailBreakpoint`.
const _desktop = Size(800, 1600);

void main() {
  testWidgets('phone: every day header spells out the month',
      (WidgetTester tester) async {
    await _pump(tester, _monthCrossingTrip(), _phone);

    // Every dated day states the full weekday + month + day, including the
    // days that follow the first one inside the same month — no row is
    // shortened just because an earlier row already said the month.
    expect(find.text('Sat, Aug 29'), findsOneWidget);
    expect(find.text('Sun, Aug 30'), findsOneWidget);
    expect(find.text('Mon, Aug 31'), findsOneWidget);
    expect(find.text('Tue, Sep 1'), findsOneWidget);
    expect(find.text('Wed, Sep 2'), findsOneWidget);
    // The old, month-dropping short labels never appear.
    expect(find.text('Sun 30'), findsNothing);
    expect(find.text('Mon 31'), findsNothing);
    expect(find.text('Wed 2'), findsNothing);
  });

  testWidgets('phone: the day header drops its calendar glyph',
      (WidgetTester tester) async {
    await _pump(tester, _monthCrossingTrip(), _phone);

    expect(find.byIcon(Icons.today), findsNothing,
        reason: 'the pin on the city header above is the section anchor');
  });

  testWidgets('desktop keeps the icon; phone and desktop labels now agree',
      (WidgetTester tester) async {
    // The icon is still the one thing narrow gives up (the padding rule
    // above it); the date label itself is identical at both widths now.
    await _pump(tester, _monthCrossingTrip(), _desktop);

    expect(find.byIcon(Icons.today), findsWidgets);
    expect(find.text('Sat, Aug 29'), findsOneWidget);
    expect(find.text('Sun, Aug 30'), findsOneWidget);
    expect(find.text('Mon, Aug 31'), findsOneWidget);
    expect(find.text('Tue, Sep 1'), findsOneWidget);
    expect(find.text('Wed, Sep 2'), findsOneWidget);
  });

  testWidgets('an undated trip still falls back to "Day N"',
      (WidgetTester tester) async {
    // No start date => no calendar date to spell out; the fallback label is
    // untouched by the always-show-the-month rule.
    await _pump(
      tester,
      Trip(
        id: 't1',
        title: 'Someday',
        createdAt: '2037-08-01',
        updatedAt: '2037-08-01',
        items: [
          _item(0, 'Rynek Główny', 'Kraków', 1),
          _item(1, 'Wawel', 'Kraków', 2),
        ],
      ),
      _phone,
    );

    expect(find.text('Day 1'), findsOneWidget);
    expect(find.text('Day 2'), findsOneWidget);
  });
}
