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
import 'package:travel_route_planner/utils/date_formats.dart';

import 'support/l10n_test_app.dart';

/// The day sub-header on a phone: no calendar glyph (the city header's pin
/// two rows up already anchors the section, and two calendars said less than
/// one indent column does), and the month spelled out only where dropping it
/// would lose something — the first dated day of a group, and every month
/// rollover after it. Desktop keeps the icon and the full date on every row.

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

/// One city whose days cross a month boundary — the case the running-month
/// rule exists for. Days 1..5 map to S..S+4: three days at the tail of one
/// month, two into the next.
///
/// S is computed, never fixed (a fixed window went red the midnight the
/// calendar walked into it, #579-style): the next month boundary minus three
/// days, rolled a boundary forward whenever that would NOT leave the trip
/// safely upcoming — an in-progress fixture renders the live-trip "today"
/// affordances the narrow assertions below forbid (#576 folds/marks by
/// DateTime.now()).
DateTime _monthCrossingStart() {
  final today = DateUtils.dateOnly(DateTime.now());
  var firstOfNext = DateTime(today.year, today.month + 1, 1);
  var s = firstOfNext.subtract(const Duration(days: 3));
  while (!s.isAfter(today.add(const Duration(days: 2)))) {
    firstOfNext = DateTime(firstOfNext.year, firstOfNext.month + 1, 1);
    s = firstOfNext.subtract(const Duration(days: 3));
  }
  return s;
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Trip _monthCrossingTrip() {
  final s = _monthCrossingStart();
  return Trip(
    id: 't1',
    title: 'Kraków',
    startDate: _iso(s),
    endDate: _iso(s.add(const Duration(days: 4))),
    createdAt: '2026-08-01',
    updatedAt: '2026-08-01',
    items: [
      _item(0, 'Rynek Główny', 'Kraków', 1),
      _item(1, 'Wawel', 'Kraków', 2),
      _item(2, 'Kazimierz', 'Kraków', 3),
      _item(3, 'Wieliczka', 'Kraków', 4),
      _item(4, 'Planty', 'Kraków', 5),
    ],
  );
}

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
  testWidgets('phone: the month is stated once, then again when it changes',
      (WidgetTester tester) async {
    await _pump(tester, _monthCrossingTrip(), _phone);
    final s = _monthCrossingStart();
    String full(int offset) => mmmed().format(s.add(Duration(days: offset)));
    String short(int offset) => weekdayDay(s.add(Duration(days: offset)));

    // First dated day of the group keeps the month...
    expect(find.text(full(0)), findsOneWidget);
    // ...the days that follow inside the same month drop it...
    expect(find.text(short(1)), findsOneWidget);
    expect(find.text(short(2)), findsOneWidget);
    expect(find.text(full(1)), findsNothing);
    expect(find.text(full(2)), findsNothing);
    // ...and the rollover states it again, because "Mon 31 / Tue 1" is
    // genuinely ambiguous and that is exactly where a traveler is checking.
    expect(find.text(full(3)), findsOneWidget);
    expect(find.text(short(4)), findsOneWidget);
    expect(find.text(full(4)), findsNothing);
  });

  testWidgets('phone: the day header drops its calendar glyph',
      (WidgetTester tester) async {
    await _pump(tester, _monthCrossingTrip(), _phone);

    expect(find.byIcon(Icons.today), findsNothing,
        reason: 'the pin on the city header above is the section anchor');
  });

  testWidgets('desktop keeps the icon and spells every date',
      (WidgetTester tester) async {
    // The wide layout is deliberately untouched by this pass: it has the
    // width to say the whole thing on every row, and the chip columns that
    // narrow gives up are worth having there.
    await _pump(tester, _monthCrossingTrip(), _desktop);
    final s = _monthCrossingStart();

    expect(find.byIcon(Icons.today), findsWidgets);
    for (var i = 0; i < 5; i++) {
      expect(find.text(mmmed().format(s.add(Duration(days: i)))),
          findsOneWidget);
    }
    expect(find.text(weekdayDay(s.add(const Duration(days: 1)))), findsNothing);
  });

  testWidgets('phone: the short label localizes', (WidgetTester tester) async {
    // weekdayDay composes DateFormat.E() + DateFormat.d(); both shipped
    // locales lead with the weekday, so one order serves both. The month-
    // bearing label comes from DateFormat.MMMEd(), which reads
    // Intl.defaultLocale (English in the test env) rather than the widget
    // locale — so only the short half is assertable here.
    await _pump(tester, _monthCrossingTrip(), _phone,
        locale: const Locale('es'));

    expect(find.text(weekdayDay(_monthCrossingStart().add(const Duration(days: 1)))),
        findsOneWidget);
  });

  testWidgets('an undated trip still falls back to "Day N"',
      (WidgetTester tester) async {
    // No start date => no calendar date to shorten; the fallback label is
    // untouched by the running-month rule.
    await _pump(
      tester,
      Trip(
        id: 't1',
        title: 'Someday',
        createdAt: '2026-08-01',
        updatedAt: '2026-08-01',
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
