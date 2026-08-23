import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/main.dart';
import 'package:travel_route_planner/models/chat_session.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/navigation/app_nav.dart';
import 'package:travel_route_planner/navigation/url_sync.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/home_screen.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/continue_chats_section.dart';
import 'package:travel_route_planner/widgets/continue_trip_hero.dart';
import 'package:travel_route_planner/widgets/trip_map.dart';

import 'support/l10n_test_app.dart';
import 'support/url_sync_fakes.dart';

/// The continue hero's route imagery (home "Continue where you left off"):
/// renders the trip's overview map full-bleed behind the overlaid title, and
/// falls back to the brand-gradient card (same text block) when there is
/// nothing to draw.
///
/// The band was cache-ONLY until a cold cache was reported as a bug: a device
/// that had never opened this trip's DETAIL — first run, a fresh browser
/// profile, cleared site data, MRU eviction — showed a flat brand slab and had
/// no way to ever show anything else, since only the trip screen writes that
/// cache. A miss now fetches once and writes through; a fetch that fails
/// collapses exactly as a miss always did.
///
/// Seeding writes the raw prefs keys (recent_trip_provider storage format +
/// TripCache's entry format) in ONE setMockInitialValues call — never
/// `await cache.writeTrip(...)` mid-test: its deferred write queue has
/// wedged fake-async tests before (see trip_cache.dart's deferred-writes
/// note). Tile HTTP in widget tests 400s and is silently tolerated, so
/// assertions are structural (TripMap presence), never imagery.
class _FakeAuthNotifier extends StateNotifier<AuthState>
    implements AuthNotifier {
  _FakeAuthNotifier(UserModel? user)
      : super(AuthState(user: user, initialized: true));

  @override
  void clearError() => state = state.copyWith(clearError: true);

  @override
  Future<bool> login(String email, String password) async => false;

  @override
  Future<bool> register(String email, String password,
          {String? displayName}) async =>
      false;

  @override
  Future<void> completeOnboarding() async {}

  @override
  Future<void> logout() async {}

  @override
  Future<void> signOutLocally() async {}

  @override
  void setUser(UserModel user) {}

  @override
  Future<void> adoptSession(String token, UserModel user) async {}
}

UserModel _user() => UserModel(
      id: 'user-1',
      email: 'test@example.com',
      displayName: 'Brian',
      createdAt: DateTime(2026, 1, 1),
    );

ChatSessionSummary _chat(String id, String title) => ChatSessionSummary(
      chatId: id,
      title: title,
      preview: 'Thinking about a week of island hopping.',
      messageCount: 4,
      createdAt: '2026-07-01T10:00:00Z',
      updatedAt: '2026-07-02T10:00:00Z',
    );

/// Two geocoded cities — enough for TripMap's destination-overview mode.
Trip _mappableTrip(String id, String title) => Trip(
      id: id,
      title: title,
      startDate: '2026-09-01',
      endDate: '2026-09-06',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [
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

/// Same shape with the (0,0) "not geocoded" sentinel everywhere — nothing to
/// plot, so the band must not mount.
Trip _unmappableTrip(String id, String title) => Trip(
      id: id,
      title: title,
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [
        ItineraryItem(
          id: 'i0',
          position: 0,
          name: 'Acropolis',
          city: 'Athens',
          latitude: 0,
          longitude: 0,
          category: 'attraction',
        ),
      ],
    );

/// The recent-trip snapshot entry, as the detail screen records it.
MapEntry<String, Object> _recentTripEntry(String tripId, String title) =>
    MapEntry(
      'recent_trip.user-1',
      jsonEncode({'id': tripId, 'title': title}),
    );

/// A TripCache detail entry, as writeTrip persists it (trip_cache.dart).
MapEntry<String, Object> _cachedTripEntry(Trip trip) => MapEntry(
      'trip_cache.user-1.trip.${trip.id}',
      jsonEncode({
        'saved_at': '2026-08-01T10:00:00.000',
        'trip': trip.toJson(),
      }),
    );

void _seed(List<MapEntry<String, Object>> entries) =>
    SharedPreferences.setMockInitialValues(Map.fromEntries(entries));

/// Serves [trip] from `getTrip`, counting calls — the counter is what proves
/// a warm cache never reaches the network. A null [trip] throws instead,
/// standing in for offline / signed-out / deleted.
class _CountingTripsApi extends TripsApiService {
  final Trip? trip;
  int getTripCalls = 0;

  _CountingTripsApi(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async {
    getTripCalls++;
    final t = trip;
    if (t == null) throw Exception('offline');
    return t;
  }

  @override
  Future<List<Trip>> listTrips() async => const [];

  @override
  Future<List<Trip>> listSharedWithMe() async => const [];
}

Future<void> _pumpHome(
  WidgetTester tester, {
  List<ChatSessionSummary> chats = const [],
  _CountingTripsApi? api,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _FakeAuthNotifier(_user())),
        liveTripProvider.overrideWithValue(null),
        resumableChatsProvider.overrideWith((ref) async => chats),
        // Always overridden: without it a cache miss reaches the real client,
        // whose failure the band swallows — so a "no map" assertion would
        // pass for the wrong reason.
        if (api != null) tripsApiServiceProvider.overrideWithValue(api),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: const HomeScreen()),
    ),
  );
  // Flush the prefs read behind recentTripProvider, then the chained cache
  // read behind cachedTripDetailProvider (which only starts once the card —
  // and with it the band — is mounted).
  await tester.pump();
  await tester.pump();
  await tester.pump();
  await tester.pump();
  // Then settle, for the cold-cache path's extra hops: the getTrip that
  // follows the miss, and the deferred write-through it queues. That write is
  // a `Timer.run` whose drain body then awaits prefs several times
  // (trip_cache.dart's deferred-writes note), so a fixed pump count is a
  // guess — and leaving it undrained fails on `!timersPending`, and worse,
  // leaks into the NEXT test: _pendingWrites is static and readTrip drains it
  // first, so one test's unflushed write becomes the next test's cache hit.
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('cache hit renders the route imagery in the continue hero',
      (WidgetTester tester) async {
    final trip = _mappableTrip('t1', 'Lisbon Trip');
    _seed([_recentTripEntry('t1', 'Lisbon Trip'), _cachedTripEntry(trip)]);
    final api = _CountingTripsApi(trip);
    await _pumpHome(tester, api: api);

    expect(find.byType(TripMap), findsOneWidget);
    // The title overlays the imagery inside the same hero card.
    expect(
      find.descendant(
          of: find.byType(ContinueTripHero),
          matching: find.text('Lisbon Trip')),
      findsOneWidget,
    );
    // A warm cache never reaches the network.
    expect(api.getTripCalls, 0);
  });

  testWidgets('cache MISS fetches the trip and still draws the map',
      (WidgetTester tester) async {
    // The reported bug: on a device that had never opened this trip's detail,
    // the hero was a flat brand slab with no way to ever become a map.
    _seed([_recentTripEntry('t1', 'Lisbon Trip')]);
    final api = _CountingTripsApi(_mappableTrip('t1', 'Lisbon Trip'));
    await _pumpHome(tester, api: api);

    expect(api.getTripCalls, 1);
    expect(find.byType(TripMap), findsOneWidget);
    expect(find.text('Lisbon Trip'), findsOneWidget);
  });

  testWidgets('a fetch that fails keeps the gradient-fallback hero',
      (WidgetTester tester) async {
    // Offline, signed out, deleted, rate-limited — all the same answer, and
    // it is the answer every miss gave before the fetch existed. A flaky
    // connection must not degrade Home further than it already would.
    _seed([_recentTripEntry('t1', 'Lisbon Trip')]);
    final api = _CountingTripsApi(null);
    await _pumpHome(tester, api: api);

    expect(api.getTripCalls, 1);
    expect(find.byType(TripMap), findsNothing);
    expect(find.text('Lisbon Trip'), findsOneWidget);
  });

  testWidgets('a fetched trip with nothing mappable also falls back',
      (WidgetTester tester) async {
    _seed([_recentTripEntry('t1', 'Lisbon Trip')]);
    final api = _CountingTripsApi(_unmappableTrip('t1', 'Lisbon Trip'));
    await _pumpHome(tester, api: api);

    expect(api.getTripCalls, 1);
    expect(find.byType(TripMap), findsNothing);
    expect(find.text('Lisbon Trip'), findsOneWidget);
  });

  testWidgets('unmappable cached trip keeps the gradient-fallback hero',
      (WidgetTester tester) async {
    final trip = _unmappableTrip('t1', 'Lisbon Trip');
    _seed([_recentTripEntry('t1', 'Lisbon Trip'), _cachedTripEntry(trip)]);
    final api = _CountingTripsApi(trip);
    await _pumpHome(tester, api: api);

    expect(find.byType(TripMap), findsNothing);
    expect(find.text('Lisbon Trip'), findsOneWidget);
    // A hit that simply has nothing to plot is still a hit — no refetch.
    expect(api.getTripCalls, 0);
  });

  testWidgets('band keeps the section order: trip card above chats',
      (WidgetTester tester) async {
    final trip = _mappableTrip('t1', 'Lisbon Trip');
    _seed([_recentTripEntry('t1', 'Lisbon Trip'), _cachedTripEntry(trip)]);
    await _pumpHome(tester,
        chats: [_chat('c1', 'Greek islands')],
        api: _CountingTripsApi(trip));

    expect(find.byType(TripMap), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Lisbon Trip')).dy,
      lessThan(tester.getTopLeft(find.byType(ContinueChatCard)).dy),
    );
    // And the title genuinely OVERLAYS the imagery — the map's rect contains
    // the title's rect. This is the pin that fails if someone moves the text
    // back below the band (the old card's anatomy).
    expect(
      tester
          .getRect(find.byType(TripMap))
          .contains(tester.getRect(find.text('Lisbon Trip')).center),
      isTrue,
    );
  });

  testWidgets('tapping the map band opens the trip on the Trips tab',
      (WidgetTester tester) async {
    // Full-app pump (home_open_trip_on_trips_tab_test pattern): the band's
    // AbsorbPointer must swallow pin/attribution taps WITHOUT breaking the
    // ancestor InkWell — so tapping the map itself opens the trip.
    tester.binding.platformDispatcher.defaultRouteNameTestValue = '/';
    final trip = _mappableTrip('t2', 'Lisbon Trip');
    _seed([_recentTripEntry('t2', 'Lisbon Trip'), _cachedTripEntry(trip)]);
    final reports = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => FakeAuthNotifier(fakeUser())),
          tripsApiServiceProvider
              .overrideWithValue(FakeTripsApiService(fakeTrip('t2'))),
          liveTripProvider.overrideWithValue(null),
          resumableChatsProvider.overrideWith((ref) async => const []),
          urlReporterProvider.overrideWithValue(reports.add),
        ],
        child: const TravelRoutePlannerApp(),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
        tester.element(find.byType(TravelRoutePlannerApp)));

    expect(find.byType(TripMap), findsOneWidget);
    await tester.tap(find.byType(TripMap), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(container.read(navIndexProvider), AppTab.trips.index);
    expect(find.byType(TripDetailScreen), findsOneWidget);
    expect(reports.last, '/trips/t2');
  });
}
