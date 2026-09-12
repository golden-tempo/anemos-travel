import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/main.dart';
import 'package:travel_route_planner/navigation/app_nav.dart';
import 'package:travel_route_planner/navigation/url_sync.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';

import 'support/url_sync_fakes.dart';

/// Trip detail is the densest phone screen in the app, and on a narrow
/// window the persistent Home/Plan/Trips bar used to sit fixed underneath it
/// for the whole visit, eating a row from a page that already scrolls
/// (issue #594). It now hides while that screen is the Trips tab's
/// foreground content on a phone, replaced by a small button that brings it
/// back — see [bottomNavVisibleProvider] and TripDetailScreen's
/// `_syncBottomNavVisible`. Revealing it is a two-way door (issue #610): a
/// second small button sits above the revealed bar to put it away again.
void main() {
  const phone = Size(390, 844);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    // AppShell's rail/bar switch reads MediaQuery, not raw layout
    // constraints, so — unlike most of this app's width-dependent widget
    // tests, which read constraints straight off a LayoutBuilder —
    // [TestWidgetsFlutterBinding.setSurfaceSize] does not move it: that call
    // resizes the render tree's root constraints without touching the
    // implicit view's own physicalSize, which is what MediaQuery is built
    // from. Setting [TestFlutterView.physicalSize] directly moves both.
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.platformDispatcher.defaultRouteNameTestValue = '/';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => FakeAuthNotifier(fakeUser())),
          tripsApiServiceProvider
              .overrideWithValue(FakeTripsApiService(fakeTrip('t1'))),
          liveTripProvider.overrideWithValue(null),
          resumableChatsProvider.overrideWith((ref) async => const []),
          urlReporterProvider.overrideWithValue((_) {}),
        ],
        child: const TravelRoutePlannerApp(),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
        tester.element(find.byType(TravelRoutePlannerApp)));
  }

  Finder barDestination(String label) => find.descendant(
      of: find.byType(NavigationBar), matching: find.text(label));

  Future<void> openTrip(WidgetTester tester) async {
    await tester.tap(barDestination('Trips'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lisbon long weekend'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'opening a trip on a phone hides the tab bar behind a reveal button, '
      'which brings it back', (tester) async {
    await pumpApp(tester);

    await openTrip(tester);
    expect(find.byType(TripDetailScreen), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    final reveal = find.byTooltip('Show navigation');
    expect(reveal, findsOneWidget);

    await tester.tap(reveal);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    // The reveal control stood in for the bar; once the bar is back, its
    // job is done.
    expect(find.byTooltip('Show navigation'), findsNothing);
  });

  testWidgets(
      'the revealed bar can be put away again, and the reveal button comes '
      'back', (tester) async {
    await pumpApp(tester);

    await openTrip(tester);
    await tester.tap(find.byTooltip('Show navigation'));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);

    final collapse = find.byTooltip('Hide navigation');
    expect(collapse, findsOneWidget);

    await tester.tap(collapse);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byTooltip('Hide navigation'), findsNothing);
    expect(find.byTooltip('Show navigation'), findsOneWidget);
  });

  testWidgets('backing out of the trip restores the bar without a tap',
      (tester) async {
    await pumpApp(tester);

    await openTrip(tester);
    expect(find.byType(NavigationBar), findsNothing);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(TripDetailScreen), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('switching tabs away from a still-open trip restores the bar too',
      (tester) async {
    // The trip screen stays mounted (hidden, ticker-frozen) behind Home once
    // the traveler switches tabs — app_shell.dart's lazy-tab contract — so
    // this pins that [bottomNavVisibleProvider] does not stay stuck hidden
    // for a screen that is no longer what the shell is showing.
    final container = await pumpApp(tester);

    await openTrip(tester);
    expect(find.byType(NavigationBar), findsNothing);

    container.read(navIndexProvider.notifier).state = AppTab.home.index;
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('the reveal button never appears at rail widths', (tester) async {
    tester.binding.platformDispatcher.defaultRouteNameTestValue = '/';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => FakeAuthNotifier(fakeUser())),
          tripsApiServiceProvider
              .overrideWithValue(FakeTripsApiService(fakeTrip('t1'))),
          liveTripProvider.overrideWithValue(null),
          resumableChatsProvider.overrideWith((ref) async => const []),
          urlReporterProvider.overrideWithValue((_) {}),
        ],
        child: const TravelRoutePlannerApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Default test surface (800x600) sits at the rail breakpoint.
    await tester.tap(find.descendant(
        of: find.byType(NavigationRail), matching: find.text('Trips')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lisbon long weekend'));
    await tester.pumpAndSettle();

    expect(find.byType(TripDetailScreen), findsOneWidget);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byTooltip('Show navigation'), findsNothing);
  });
}
