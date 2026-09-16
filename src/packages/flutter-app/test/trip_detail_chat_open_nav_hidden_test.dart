import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/main.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/navigation/url_sync.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/trip_refine_panel.dart';

import 'support/url_sync_fakes.dart';

/// Issue #651: on a phone, [TripDetailScreen] stands its own small
/// up/down-chevron button in for the persistent Home/Plan/Trips bar
/// (issue #594/#610). That stand-in used to keep showing even while the
/// refine chat's own composer was the last thing on screen — a multi-line
/// draft grew toward the very row the arrow sat in, and the arrow read as
/// covering the traveler's own typing. Both this screen's own bar and the
/// persistent one it stands in for must stay hidden for as long as the chat
/// is open.
void main() {
  const phone = Size(390, 844);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  ItineraryItem tripItem(int pos, String name) => ItineraryItem(
        id: 'i$pos',
        position: pos,
        name: name,
        address: 'Lisbon, Portugal',
        latitude: 0,
        longitude: 0,
        category: 'attraction',
      );

  Trip tripWithItems() => Trip(
        id: 't1',
        title: 'Lisbon long weekend',
        startDate: '2037-08-01',
        endDate: '2037-08-05',
        createdAt: '2037-07-01',
        updatedAt: '2037-07-01',
        items: [tripItem(0, 'Belém Tower')],
      );

  Future<void> pumpApp(WidgetTester tester) async {
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
              .overrideWithValue(FakeTripsApiService(tripWithItems())),
          liveTripProvider.overrideWithValue(null),
          resumableChatsProvider.overrideWith((ref) async => const []),
          urlReporterProvider.overrideWithValue((_) {}),
          tripRefineProvider.overrideWith((ref, tripId) => PlanNotifier(
              PlanService('http://unused'), ApiClient(),
              tripId: tripId)),
        ],
        child: const TravelRoutePlannerApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openTripAndChat(WidgetTester tester) async {
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text('Trips')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lisbon long weekend'));
    await tester.pumpAndSettle();
    // The stand-in reveal button, since the bar is hidden as soon as the
    // trip is the Trips tab's foreground content (issue #594).
    expect(find.byTooltip('Show navigation'), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.byType(TripRefinePanel), findsOneWidget);
  }

  testWidgets(
      'opening the trip chat on a phone hides both the persistent bar and '
      'its reveal stand-in', (tester) async {
    await pumpApp(tester);
    await openTripAndChat(tester);

    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byTooltip('Show navigation'), findsNothing);
    expect(find.byTooltip('Hide navigation'), findsNothing);
  });

  testWidgets('closing the chat brings the reveal stand-in back',
      (tester) async {
    await pumpApp(tester);
    await openTripAndChat(tester);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    expect(find.byType(TripRefinePanel), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byTooltip('Show navigation'), findsOneWidget);
  });

  testWidgets(
      'a previously-revealed bar stays hidden once the chat is reopened',
      (tester) async {
    await pumpApp(tester);
    await openTripAndChat(tester);

    // Close the chat, then reveal this screen's own stand-in bar.
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show navigation'));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);

    // Reopening the chat must hide it again — a stale reveal from before the
    // chat opened is exactly the state that let the arrow sit under the
    // composer.
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.byType(TripRefinePanel), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byTooltip('Hide navigation'), findsNothing);
  });
}
