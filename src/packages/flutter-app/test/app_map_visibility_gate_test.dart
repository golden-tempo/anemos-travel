import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/main.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/navigation/app_nav.dart';
import 'package:travel_route_planner/navigation/url_sync.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/trip_cache_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/home_screen.dart';
import 'package:travel_route_planner/screens/trips_list_screen.dart';
import 'package:travel_route_planner/services/trip_cache.dart';
import 'package:travel_route_planner/widgets/app_map.dart';
import 'package:travel_route_planner/widgets/travel_footprint_card.dart';
import 'package:travel_route_planner/widgets/trip_map.dart';
import 'package:travel_route_planner/widgets/trip_map_band.dart';

import 'support/l10n_test_app.dart';
import 'support/url_sync_fakes.dart';

/// The hidden-tab map gate (2026-08 perf audit, finding 3): AppShell keeps
/// every tab mounted in its IndexedStack, so before the gate a hidden tab's
/// map bands kept live FlutterMaps — two tile layers each — fetching imagery
/// nobody could see. [AppMapVisibilityGate] reads TickerMode, the shell's
/// per-tab visibility signal (which Flutter's Overlay also disables for a
/// route kept alive under an opaque pushed route), and swaps the map for a
/// same-size [appMapBackground] fill.
///
/// The tests drive TickerMode directly rather than a full AppShell: the
/// shell's own wrapping is already pinned by app_shell_ticker_mode_test, so
/// these only need the band half of the contract — gated bands mount no map,
/// keep their box, and get the map back when the tab does. Tile HTTP in
/// widget tests 400s and is silently tolerated, so map assertions are
/// structural, never imagery.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('AppMapVisibilityGate', () {
    Future<void> pumpGated(WidgetTester tester, {required bool enabled}) {
      return tester.pumpWidget(
        MaterialApp(
          home: TickerMode(
            enabled: enabled,
            child: const AppMapVisibilityGate(child: Text('live map')),
          ),
        ),
      );
    }

    testWidgets('mounts its child only while tickers are enabled',
        (WidgetTester tester) async {
      await pumpGated(tester, enabled: false);
      expect(find.text('live map'), findsNothing);
      // The placeholder is the map canvas color — the same field an unloaded
      // map paints, so a transition frame reads as "not lit yet".
      final fill = tester.widget<ColoredBox>(find.descendant(
          of: find.byType(AppMapVisibilityGate),
          matching: find.byType(ColoredBox)));
      expect(fill.color, appMapBackground);

      // The tab comes back: the same tree remounts the child.
      await pumpGated(tester, enabled: true);
      expect(find.text('live map'), findsOneWidget);
    });
  });

  group('travel footprint band', () {
    const pins = [
      (city: 'Lisbon', lat: 38.7, lng: -9.1, visited: true),
      (city: 'Athens', lat: 37.9, lng: 23.7, visited: false),
    ];
    const traveled = (trips: 1, travelDays: 5, cities: 1);
    const planned = (trips: 1, travelDays: 3, cities: 1);

    Future<void> pumpCard(WidgetTester tester, {required bool enabled}) {
      return tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TickerMode(
            enabled: enabled,
            child: const Scaffold(
              body: TravelFootprintCard(
                pins: pins,
                traveled: traveled,
                planned: planned,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('hidden tab mounts no FlutterMap and keeps the band box',
        (WidgetTester tester) async {
      await pumpCard(tester, enabled: false);

      expect(find.byType(TravelFootprintCard), findsOneWidget);
      expect(find.byType(FlutterMap), findsNothing);
      // Zero layout shift while hidden: the gate occupies the exact band box,
      // so the hidden tab's scroll geometry can never move.
      expect(
          tester.getSize(find.byType(AppMapVisibilityGate)).height, 140);
    });

    testWidgets('visible tab mounts the map; hiding swaps it back out',
        (WidgetTester tester) async {
      await pumpCard(tester, enabled: true);
      expect(find.byType(FlutterMap), findsOneWidget);

      await pumpCard(tester, enabled: false);
      expect(find.byType(FlutterMap), findsNothing);

      await pumpCard(tester, enabled: true);
      expect(find.byType(FlutterMap), findsOneWidget);
    });
  });

  group('trip map band', () {
    Trip mappableTrip() => Trip(
          id: 't1',
          title: 'Lisbon Trip',
          startDate: '2026-09-01',
          endDate: '2026-09-06',
          createdAt: '2026-06-01',
          updatedAt: '2026-06-01',
          items: const [
            ItineraryItem(
              id: 'i0',
              position: 0,
              name: 'Alfama',
              city: 'Lisbon',
              latitude: 38.7139,
              longitude: -9.1334,
              category: 'attraction',
            ),
            ItineraryItem(
              id: 'i1',
              position: 1,
              name: 'Alhambra',
              city: 'Granada',
              latitude: 37.1761,
              longitude: -3.5881,
              category: 'attraction',
            ),
          ],
        );

    Future<void> pumpBand(WidgetTester tester, {required bool enabled}) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tripCacheProvider.overrideWithValue(TripCache('u1')),
          ],
          child: MaterialApp(
            localizationsDelegates: testLocalizationsDelegates,
            home: TickerMode(
              enabled: enabled,
              child: const Scaffold(body: TripMapBand(tripId: 't1')),
            ),
          ),
        ),
      );
      // Flush the cache read behind cachedTripDetailProvider.
      await tester.pump();
      await tester.pump();
    }

    testWidgets('cache hit on a hidden tab keeps the box but no TripMap',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        'trip_cache.u1.trip.t1': jsonEncode({
          'saved_at': '2026-08-01T10:00:00.000',
          'trip': mappableTrip().toJson(),
        }),
      });

      await pumpBand(tester, enabled: false);
      expect(find.byType(TripMap), findsNothing);
      // The band still resolved the cache and holds its 160 slot — the
      // collapse-on-miss contract is untouched by the gate.
      expect(tester.getSize(find.byType(TripMapBand)).height, 160);

      await pumpBand(tester, enabled: true);
      expect(find.byType(TripMap), findsOneWidget);
    });

    testWidgets('cache miss still collapses to nothing, gated or not',
        (WidgetTester tester) async {
      await pumpBand(tester, enabled: false);
      expect(tester.getSize(find.byType(TripMapBand)), Size.zero);
    });
  });

  group('in the real shell', () {
    // One dated future trip that BOTH tabs promote: Home's continue hero and
    // the trips list's "Up next" hero each host a TripMapBand for it, and its
    // detail is cached, so before the gate the hidden tab's copy was a second
    // live FlutterMap racing the visible one for the same tiles.
    testWidgets('only the active tab mounts a map; switching hands it over',
        (WidgetTester tester) async {
      tester.binding.platformDispatcher.defaultRouteNameTestValue = '/';
      String iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
      final trip = Trip(
        id: 't1',
        title: 'Lisbon Trip',
        startDate: iso(DateTime.now().add(const Duration(days: 10))),
        endDate: iso(DateTime.now().add(const Duration(days: 13))),
        createdAt: '2026-06-01',
        updatedAt: '2026-06-01',
        items: const [
          ItineraryItem(
            id: 'i0',
            position: 0,
            name: 'Alfama',
            city: 'Lisbon',
            latitude: 38.7139,
            longitude: -9.1334,
            category: 'attraction',
          ),
          ItineraryItem(
            id: 'i1',
            position: 1,
            name: 'Alhambra',
            city: 'Granada',
            latitude: 37.1761,
            longitude: -3.5881,
            category: 'attraction',
          ),
        ],
      );
      SharedPreferences.setMockInitialValues({
        'recent_trip.user-1': jsonEncode({'id': 't1', 'title': 'Lisbon Trip'}),
        'trip_cache.user-1.trip.t1': jsonEncode({
          'saved_at': '2026-08-01T10:00:00.000',
          'trip': trip.toJson(),
        }),
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith((ref) => FakeAuthNotifier(fakeUser())),
            tripsApiServiceProvider
                .overrideWithValue(FakeTripsApiService(trip)),
            liveTripProvider.overrideWithValue(null),
            resumableChatsProvider.overrideWith((ref) async => const []),
            urlReporterProvider.overrideWithValue((_) {}),
          ],
          child: const TravelRoutePlannerApp(),
        ),
      );
      await tester.pumpAndSettle();

      // Boot lands on Home: its continue hero carries the ONLY live map —
      // the hidden trips tab's up-next hero band is gated, not mounted.
      expect(
        find.descendant(
            of: find.byType(HomeScreen), matching: find.byType(TripMap)),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: find.byType(TripsListScreen), matching: find.byType(TripMap)),
        findsNothing,
      );

      // Switch tabs: the map follows the visible tab, one alive at a time.
      final container = ProviderScope.containerOf(
          tester.element(find.byType(TravelRoutePlannerApp)));
      container.read(navIndexProvider.notifier).state = AppTab.trips.index;
      await tester.pumpAndSettle();

      expect(
        find.descendant(
            of: find.byType(TripsListScreen), matching: find.byType(TripMap)),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: find.byType(HomeScreen), matching: find.byType(TripMap)),
        findsNothing,
      );
    });
  });
}
