import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/models/traveler_preferences.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/booking_todos_api_service.dart';
import 'package:travel_route_planner/services/preferences_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/preferences_provider.dart';
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

class _FakePrefsApi implements PreferencesApiService {
  @override
  ApiClient get apiClient => throw UnsupportedError('unused in tests');

  @override
  Future<TravelerPreferences> getPreferences() async =>
      const TravelerPreferences(homeAirport: 'EWR');

  @override
  Future<TravelerPreferences> savePreferences({
    String? budget,
    String? pace,
    required List<String> interests,
    String? homeAirport,
    String? profileNotes,
    String? workStyle,
    String? fitnessRoutine,
    String? outdoorIntensity,
    String? companions,
    String? baggage,
  }) async =>
      const TravelerPreferences(homeAirport: 'EWR');
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

void main() {
  testWidgets(
      'stay dates run to the next arrival, not the leg\'s own last item day',
      (WidgetTester tester) async {
    // Gothenburg's places stop on day 3 (Aug 26) but Madrid's single item —
    // its arrival — sits on day 5 (Aug 28). Under the boundary rule
    // (specs/leg-departure-dates) Gothenburg runs until that arrival, so its
    // stay covers Aug 24–28 and the leg into Madrid departs Aug 28. Madrid is
    // an arrive-the-last-day visit and its stay reads exactly that.
    final trip = Trip(
      id: 't1',
      title: 'Iberia',
      startDate: '2026-08-24',
      endDate: '2026-08-28',
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: [
        _item(0, 'Feskekôrka', 'Gothenburg', day: 1),
        _item(1, 'Liseberg', 'Gothenburg', day: 3),
        _item(2, 'Prado', 'Madrid', day: 5),
      ],
    );

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
    final derived = fake.syncedPayloads.first;

    final madridStay = derived.singleWhere((t) => t['todo_key'] == 'stay:madrid');
    expect(madridStay['subtitle'], 'Aug 28');
    expect(madridStay['depart_date'], '2026-08-28');
    expect(madridStay['return_date'], '2026-08-28');

    // The inbound leg departs when Gothenburg's rendered span ends — Madrid's
    // arrival day, not Gothenburg's own last item day (Aug 26).
    final leg = derived
        .singleWhere((t) => t['todo_key'] == 'transport:gothenburg>>madrid');
    expect(leg['depart_date'], '2026-08-28');

    // Gothenburg's stay covers the whole rendered span, including the two
    // unplanned nights before the move-on — the pin that stays and headers
    // read visibleLegRanges, not the raw item span.
    final gothenburgStay =
        derived.singleWhere((t) => t['todo_key'] == 'stay:gothenburg');
    expect(gothenburgStay['subtitle'], 'Aug 24 – Aug 28');
    expect(gothenburgStay['depart_date'], '2026-08-24');
    expect(gothenburgStay['return_date'], '2026-08-28');
  });

  testWidgets(
      'first leg anchors to the trip start when its items sit on a late day',
      (WidgetTester tester) async {
    // Prague's single item is on day 4 (Aug 27) of an Aug 24 trip — the
    // shape a set_leg_dates boundary extension leaves behind. The traveler
    // is in Prague from the trip's first day, so the header, stay todo, and
    // the EWR home leg must all read from Aug 24, never a bare "Aug 27" —
    // and under the boundary rule Prague runs until Kraków's day-9 arrival
    // (Sep 1), so the whole rendered span is Aug 24 – Sep 1.
    final trip = Trip(
      id: 't1',
      title: 'Big Summer',
      startDate: '2026-08-24',
      endDate: '2026-09-01',
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: [
        _item(0, 'Prague', 'Prague', day: 4),
        _item(1, 'Kraków', 'Kraków', day: 9),
      ],
    );

    final fake = _CapturingBookingTodosApiService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
          bookingTodosApiServiceProvider.overrideWithValue(fake),
          preferencesApiServiceProvider.overrideWithValue(_FakePrefsApi()),
        ],
        child: MaterialApp(
            localizationsDelegates: testLocalizationsDelegates,
            home: TripDetailScreen(tripId: 't1')),
      ),
    );
    await tester.pumpAndSettle();

    // Header shows the anchored range with its night count, not a bare
    // end date.
    // Scoped to Prague's row: the count must sit in the SAME chip as the
    // anchored range (nights from the same visibleLegRanges pair).
    expect(chipTextIn('Prague', 'Aug 24 – Sep 1'), findsOneWidget);
    expect(chipTextIn('Prague', '· 8 nights'), findsOneWidget);
    expect(find.text('Aug 27'), findsNothing);

    // The prefs load is async and can re-trigger the derivation — assert on
    // the last synced payload, which reflects the loaded home airport.
    expect(fake.syncedPayloads, isNotEmpty);
    final derived = fake.syncedPayloads.last;

    final pragueStay =
        derived.singleWhere((t) => t['todo_key'] == 'stay:prague');
    expect(pragueStay['subtitle'], 'Aug 24 – Sep 1');
    expect(pragueStay['depart_date'], '2026-08-24');
    expect(pragueStay['return_date'], '2026-09-01');

    final homeLeg =
        derived.singleWhere((t) => t['todo_key'] == 'transport:ewr>>prague');
    expect(homeLeg['title'], 'EWR → Prague');
    expect(homeLeg['depart_date'], '2026-08-24');

    // The second city's arrival is its own first item day (Sep 1) — the
    // boundary Prague's rendered end derives from.
    final krakowStay =
        derived.singleWhere((t) => t['todo_key'] == 'stay:kraków');
    expect(krakowStay['depart_date'], '2026-09-01');
  });

  testWidgets(
      'city header range is arrival-adjusted like the stay todos',
      (WidgetTester tester) async {
    // Same shape as above: Madrid's one item — its arrival — sits on day 5
    // (Aug 28), the trip's last day. The header must agree with the stay row
    // right beneath it: Gothenburg runs Aug 24–28 (the boundary rule) and
    // Madrid is a bare arrival-day visit.
    final trip = Trip(
      id: 't1',
      title: 'Iberia',
      startDate: '2026-08-24',
      endDate: '2026-08-28',
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: [
        _item(0, 'Feskekôrka', 'Gothenburg', day: 1),
        _item(1, 'Liseberg', 'Gothenburg', day: 3),
        _item(2, 'Prado', 'Madrid', day: 5),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
          bookingTodosApiServiceProvider
              .overrideWithValue(_CapturingBookingTodosApiService()),
        ],
        child: MaterialApp(
            localizationsDelegates: testLocalizationsDelegates,
            home: TripDetailScreen(tripId: 't1')),
      ),
    );
    await tester.pumpAndSettle();

    // Scoped per row: Gothenburg carries the whole counted range; Madrid's
    // zero-night chip is the bare arrival date with no nights text.
    expect(chipTextIn('Gothenburg', 'Aug 24 – Aug 28'), findsOneWidget);
    expect(chipTextIn('Gothenburg', '· 4 nights'), findsOneWidget);
    expect(chipTextIn('Madrid', 'Aug 28'), findsOneWidget);
    expect(find.textContaining('0 nights'), findsNothing);
  });

  testWidgets('a stated origin titles the home legs instead of the airport',
      (WidgetTester tester) async {
    // The saved home airport is a standing guess about how this traveler
    // usually leaves; the origin is what they said about THIS trip. Before
    // this, a stated drive from Lake George still produced "EWR → Montreal"
    // (2026-08-14).
    final trip = Trip(
      id: 't1',
      title: 'Montreal Weekend',
      startDate: '2026-08-15',
      endDate: '2026-08-17',
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      travelMode: 'car',
      origin: 'Lake George, NY',
      items: [
        _item(0, "Schwartz's Deli", 'Montreal', day: 1),
        _item(1, 'Jean-Talon Market', 'Montreal', day: 2),
      ],
    );

    final fake = _CapturingBookingTodosApiService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
          bookingTodosApiServiceProvider.overrideWithValue(fake),
          preferencesApiServiceProvider.overrideWithValue(_FakePrefsApi()),
        ],
        child: MaterialApp(
            localizationsDelegates: testLocalizationsDelegates,
            home: TripDetailScreen(tripId: 't1')),
      ),
    );
    await tester.pumpAndSettle();

    final derived = fake.syncedPayloads.last;
    final out = derived.singleWhere(
        (t) => t['todo_key'] == 'transport:lake george, ny>>montreal');
    expect(out['title'], 'Lake George, NY → Montreal');
    // A car trip routes through Rome2Rio, not a flight search.
    expect(out['provider'], 'rome2rio');

    // And home again, with the origin as the destination.
    final back = derived.singleWhere(
        (t) => t['todo_key'] == 'transport:montreal>>lake george, ny');
    expect(back['title'], 'Montreal → Lake George, NY');

    // The airport it would otherwise have assumed appears nowhere.
    expect(derived.any((t) => (t['todo_key'] as String).contains('ewr')), isFalse);
  });
}
