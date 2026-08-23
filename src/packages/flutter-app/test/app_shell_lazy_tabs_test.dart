import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/main.dart';
import 'package:travel_route_planner/navigation/app_nav.dart';
import 'package:travel_route_planner/navigation/app_routes.dart';
import 'package:travel_route_planner/navigation/url_sync.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/agent_screen.dart';
import 'package:travel_route_planner/screens/home_screen.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/screens/trips_list_screen.dart';

import 'support/url_sync_fakes.dart';

/// Lazy tab lifecycle (2026-08 perf audit, finding-3 hardening): the shell
/// builds a tab's subtree on FIRST VISIT — boot builds one tab, not three —
/// and a visited tab stays mounted through later switches exactly as the
/// always-mounted shell did. Hidden visited tabs leave the semantics tree:
/// what a screen reader can read is the tab on screen, nothing else.
///
/// The programmatic switch+push contract rides on the same mechanism and is
/// pinned here too: writing navIndexProvider is what builds the slot, so a
/// push targeting a never-visited tab lands once pushOnTabWhenReady's
/// frame-retries meet the freshly built navigator.
void main() {
  late List<String> reports;

  Finder railDestination(String label) => find.descendant(
      of: find.byType(NavigationRail), matching: find.text(label));

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    tester.binding.platformDispatcher.defaultRouteNameTestValue = '/';
    reports = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => FakeAuthNotifier(fakeUser())),
          tripsApiServiceProvider
              .overrideWithValue(FakeTripsApiService(fakeTrip('t1'))),
          liveTripProvider.overrideWithValue(null),
          resumableChatsProvider.overrideWith((ref) async => const []),
          urlReporterProvider.overrideWithValue(reports.add),
        ],
        child: const TravelRoutePlannerApp(),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
        tester.element(find.byType(TravelRoutePlannerApp)));
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('boot builds only the boot tab; a visit builds and keeps',
      (tester) async {
    await pumpApp(tester);

    // skipOffstage: false throughout — the claim is about what EXISTS in the
    // tree, not what is on screen. An unvisited tab must not exist at all.
    expect(find.byType(HomeScreen, skipOffstage: false), findsOneWidget);
    expect(find.byType(AgentScreen, skipOffstage: false), findsNothing);
    expect(find.byType(TripsListScreen, skipOffstage: false), findsNothing);

    await tester.tap(railDestination('Trips'));
    await tester.pumpAndSettle();

    expect(find.byType(TripsListScreen), findsOneWidget);
    expect(reports.last, kTripsLocation);
    // Lazy is first-BUILD only: the tab switched away from stays mounted.
    expect(find.byType(HomeScreen, skipOffstage: false), findsOneWidget);
    // Never-visited Plan still builds nothing.
    expect(find.byType(AgentScreen, skipOffstage: false), findsNothing);
  });

  testWidgets('the boot trips load no longer depends on the trips tab',
      (tester) async {
    // Home's live-trip hero, travels band and returning-user gate all read
    // tripsProvider, which the mounted-at-boot TripsListScreen used to feed.
    // Under lazy build that screen may never mount, so the SHELL owns the
    // boot load — pinned by watching the provider fill while the Trips tab
    // stays unbuilt.
    final container = await pumpApp(tester);

    expect(find.byType(TripsListScreen, skipOffstage: false), findsNothing);
    expect(
      container.read(tripsProvider).trips.map((t) => t.id),
      contains('t1'),
      reason: 'the shell must load trips without the trips list mounting',
    );
  });

  testWidgets('a visited tab keeps its pushed stack across switches',
      (tester) async {
    // Trips-keeps-your-place survives lazy build: visit, open a trip, leave,
    // come back — the detail is parked, not rebuilt and not discarded.
    final container = await pumpApp(tester);

    await tester.tap(railDestination('Trips'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lisbon long weekend'));
    await tester.pumpAndSettle();
    expect(find.byType(TripDetailScreen), findsOneWidget);

    await tester.tap(railDestination('Home'));
    await tester.pumpAndSettle();
    expect(container.read(navIndexProvider), AppTab.home.index);
    // Hidden, not gone:
    expect(find.byType(TripDetailScreen, skipOffstage: false), findsOneWidget);

    await tester.tap(railDestination('Trips'));
    await tester.pumpAndSettle();
    expect(find.byType(TripDetailScreen), findsOneWidget);
    expect(reports.last, '/trips/t1');
  });

  testWidgets('a hidden visited tab leaves the semantics tree', (tester) async {
    // The probe is a marker page pushed inside the Trips tab, so the claim
    // cannot be confused by strings Home and the trips list share (the trip
    // title renders on both). Mounted-but-unreadable is the contract.
    final handle = tester.ensureSemantics();
    final container = await pumpApp(tester);

    List<String> readable() => tester.semantics
        .simulatedAccessibilityTraversal()
        .map((node) => node.label)
        .where((label) => label.isNotEmpty)
        .toList();

    await tester.tap(railDestination('Trips'));
    await tester.pumpAndSettle();
    container
        .read(tabNavKeysProvider)[AppTab.trips.index]
        .currentState!
        .push(MaterialPageRoute(
            builder: (_) =>
                const Scaffold(body: Text('inside the trips tab'))));
    await tester.pumpAndSettle();
    expect(readable(), anyElement(contains('inside the trips tab')));

    await tester.tap(railDestination('Home'));
    await tester.pumpAndSettle();
    // Still mounted — state intact — but nothing of it is readable.
    expect(find.text('inside the trips tab', skipOffstage: false),
        findsOneWidget);
    expect(readable(), isNot(anyElement(contains('inside the trips tab'))));

    // Reveal restores the exact same subtree to the semantics tree.
    await tester.tap(railDestination('Trips'));
    await tester.pumpAndSettle();
    expect(readable(), anyElement(contains('inside the trips tab')));

    handle.dispose();
  });

  testWidgets('a programmatic push builds the never-visited tab it targets',
      (tester) async {
    // The raw switch+push pattern every programmatic flow uses (Home trip
    // cards, boot restore, shared-trip join): write navIndexProvider, then
    // pushOnTabWhenReady — here against a tab whose navigator does not exist
    // yet. The index write force-builds the slot; the push retries must land
    // on the fresh navigator, never be dropped.
    final container = await pumpApp(tester);

    expect(find.byType(TripsListScreen, skipOffstage: false), findsNothing);
    final navKeys = container.read(tabNavKeysProvider);
    expect(navKeys[AppTab.trips.index].currentState, isNull,
        reason: 'the premise: no navigator exists to push onto yet');

    container.read(navIndexProvider.notifier).state = AppTab.trips.index;
    pushOnTabWhenReady(
        navKeys,
        AppTab.trips,
        () => instantRoute(
            TripDetailScreen(tripId: 't1'), tripDetailLocation('t1')));
    await tester.pumpAndSettle();

    expect(find.byType(TripsListScreen, skipOffstage: false), findsOneWidget,
        reason: 'targeting the tab must have built it');
    expect(find.byType(TripDetailScreen), findsOneWidget);
    expect(reports.last, '/trips/t1');
  });
}
