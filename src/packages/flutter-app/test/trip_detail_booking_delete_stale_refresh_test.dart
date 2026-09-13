import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/budget_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/booking_todos_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';

import 'support/l10n_test_app.dart';

/// Regression test for #635: an "other booking" removed from the Bookings
/// (or Itinerary) tab kept reappearing shortly after. The cause was a race
/// between the delete's own optimistic local update and a silent background
/// refresh (the shared-trip status poll / a `trip_updated` bump) whose GET
/// was already in flight when the delete happened: whichever response
/// landed LAST won, and a fetch that started before the delete still
/// carried the booking. See _loadGeneration in trip_detail_screen.dart.
///
/// getTrip answers from a queue: a Trip resolves immediately, a Completer
/// stays pending until the test completes it — mirrors
/// trip_detail_silent_refresh_test.dart's fake.
class _QueuedTripsApiService extends TripsApiService {
  final List<Object> responses;
  int calls = 0;
  _QueuedTripsApiService(this.responses)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) {
    final next =
        responses[calls < responses.length ? calls : responses.length - 1];
    calls++;
    if (next is Trip) return Future.value(next);
    if (next is Completer<Trip>) return next.future;
    return Future.error(next);
  }
}

class _RecordingBookingTodosApi extends BookingTodosApiService {
  final List<String> deleted = [];
  _RecordingBookingTodosApi() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<void> delete(String tripId, String todoId) async {
    deleted.add(todoId);
  }
}

BookingTodo _todo() => const BookingTodo(
      id: 'todo-1',
      kind: 'other',
      todoKey: 'custom:salzburg-gothenburg',
      title: 'Salzburg - Gothenburg',
      auto: false,
      booked: false,
    );

Trip _trip() => Trip(
      id: 't1',
      title: 'Europe Trip',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      bookingTodos: [_todo()],
      items: const [
        // Zero coords so the screen skips the map widget in the test env.
        // Gives the scroll view enough content for a pull-to-refresh fling
        // to arm — an empty itinerary otherwise leaves nothing to overscroll.
        ItineraryItem(
          id: 'i0',
          position: 0,
          name: 'Acropolis',
          address: 'Athens, Greece',
          latitude: 0,
          longitude: 0,
          category: 'attraction',
        ),
      ],
    );

/// Arms and crosses the pull-to-refresh threshold — the same trigger
/// trip_detail_silent_refresh_test.dart uses for a silent background reload.
Future<void> _triggerPullToRefresh(WidgetTester tester) async {
  await tester.fling(
      find.byType(CustomScrollView).first, const Offset(0, 400), 1000);
  await tester.pump(); // start the indicator
  await tester.pump(const Duration(seconds: 1)); // cross the arm threshold
}

Finder get _dialogRemove => find.descendant(
    of: find.byType(AlertDialog),
    matching: find.widgetWithText(FilledButton, 'Remove'));

/// pumpAndSettle never settles while the pending refresh's Completer is
/// unresolved (the RefreshIndicator keeps animating), so menu/dialog
/// transitions in between are driven by a bounded number of plain pumps
/// instead.
Future<void> _pumpABit(WidgetTester tester, [int times = 10]) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets(
      'removing an other booking stays removed even when a stale refresh lands after (#635)',
      (WidgetTester tester) async {
    final pendingRefresh = Completer<Trip>();
    final tripsApi = _QueuedTripsApiService([_trip(), pendingRefresh]);
    final bookingTodosApi = _RecordingBookingTodosApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(tripsApi),
          bookingTodosApiServiceProvider.overrideWithValue(bookingTodosApi),
          expensesProvider('t1').overrideWith((ref) async => const []),
        ],
        child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: const TripDetailScreen(tripId: 't1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Salzburg - Gothenburg'), findsOneWidget);

    // A background refresh (e.g. the shared-trip status poll) starts and its
    // GET is still in flight when the delete below happens — it will
    // eventually resolve with the pre-delete trip.
    await _triggerPullToRefresh(tester);
    expect(tripsApi.calls, 2);

    // While that fetch is pending, the traveler removes the booking. Scoped
    // to the booking's own card — the itinerary item above also carries a
    // kebab menu.
    final cardMenu = find.descendant(
        of: find.widgetWithText(Card, 'Salzburg - Gothenburg'),
        matching: find.byIcon(Icons.more_vert));
    await tester.tap(cardMenu);
    await _pumpABit(tester);
    await tester.tap(find.text('Remove').last);
    await _pumpABit(tester);
    await tester.tap(_dialogRemove);
    await _pumpABit(tester);

    expect(bookingTodosApi.deleted, ['todo-1']);
    expect(find.text('Salzburg - Gothenburg'), findsNothing);

    // The stale refresh finally lands, still carrying the (now deleted)
    // booking — it must not resurrect it.
    pendingRefresh.complete(_trip());
    await tester.pumpAndSettle();

    expect(find.text('Salzburg - Gothenburg'), findsNothing);
  });
}
