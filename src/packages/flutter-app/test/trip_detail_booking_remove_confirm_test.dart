import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/models/expense.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/trip_segment.dart';
import 'package:travel_route_planner/providers/accommodations_provider.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/budget_provider.dart';
import 'package:travel_route_planner/providers/transport_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/services/accommodations_api_service.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/booking_todos_api_service.dart';
import 'package:travel_route_planner/services/transport_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/booking_detail_row.dart';

import 'support/l10n_test_app.dart';

/// Removing a booking asks first, and the ask names what goes with the row —
/// the same three stakes the AGENT is held to before it may remove one
/// (bookingTodoStateRefusal, plan_tools_extra.go): a CASCADEd shortlist, a
/// surviving budget expense, and a reservation the provider still holds.
/// specs/booking-remove-confirm.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// Records deletes instead of issuing them — the assertion is whether one
/// happened at all.
class _RecordingBookingTodosApi extends BookingTodosApiService {
  final List<String> deleted = [];
  _RecordingBookingTodosApi() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<void> delete(String tripId, String todoId) async {
    deleted.add(todoId);
  }
}

/// A removable (non-auto) booking — the auto ones carry no delete affordance.
BookingTodo _todo({bool booked = false}) => BookingTodo(
      id: 'todo-1',
      kind: 'stay',
      todoKey: 'custom:museum',
      title: 'Museum tickets',
      auto: false,
      booked: booked,
    );

Trip _trip({
  bool booked = false,
  int savedOptions = 0,
}) =>
    Trip(
      id: 't1',
      title: 'Athens',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      bookingTodos: [_todo(booked: booked)],
      bookingOptionTodoIds: [for (var i = 0; i < savedOptions; i++) 'todo-1'],
    );

/// The bookings section sits below the default 800x600 viewport's fold and
/// the itinerary renders lazily, so a tall view keeps it built and findable.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<_RecordingBookingTodosApi> _pump(
  WidgetTester tester, {
  bool booked = false,
  int savedOptions = 0,
  List<Expense> expenses = const [],
}) async {
  _useTallViewport(tester);
  final api = _RecordingBookingTodosApi();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider
            .overrideWithValue(_FakeTripsApiService(_trip(
          booked: booked,
          savedOptions: savedOptions,
        ))),
        bookingTodosApiServiceProvider.overrideWithValue(api),
        expensesProvider('t1').overrideWith((ref) async => expenses),
      ],
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        home: const TripDetailScreen(tripId: 't1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

/// Records stay/segment deletes — the confirmed records, whose rows carry
/// their own "Remove stay" / "Remove transport" menu.
class _RecordingRecordsApi {
  final deletedStays = <String>[];
  final deletedSegments = <String>[];
}

class _FakeAccommodationsApi extends AccommodationsApiService {
  final _RecordingRecordsApi sink;
  _FakeAccommodationsApi(this.sink) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<void> delete(String tripId, String accId) async {
    sink.deletedStays.add(accId);
  }
}

class _FakeTransportApi extends TransportApiService {
  final _RecordingRecordsApi sink;
  _FakeTransportApi(this.sink) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<void> deleteSegment(String tripId, String segmentId) async {
    sink.deletedSegments.add(segmentId);
  }
}

/// A trip whose confirmed stay and leg both render a detail row with a
/// Remove affordance.
Future<_RecordingRecordsApi> _pumpRecords(WidgetTester tester) async {
  _useTallViewport(tester);
  final sink = _RecordingRecordsApi();
  final trip = Trip(
    id: 't1',
    title: 'Paris',
    startDate: '2026-06-10',
    endDate: '2026-06-12',
    createdAt: '2026-06-01',
    updatedAt: '2026-06-01',
    // The confirmed records render as detail rows inside the itinerary's city
    // groups, so the page needs an itinerary for them to hang off.
    items: const [
      ItineraryItem(
          id: 'i0',
          position: 0,
          name: 'Louvre',
          address: 'Paris, France',
          latitude: 0,
          longitude: 0,
          category: 'attraction',
          day: 1,
          city: 'Paris'),
      ItineraryItem(
          id: 'i1',
          position: 1,
          name: 'Café de Flore',
          address: 'Paris, France',
          latitude: 0,
          longitude: 0,
          category: 'restaurant',
          day: 2,
          city: 'Paris'),
    ],
    accommodations: const [
      Accommodation(
        id: 'acc1',
        name: 'Hotel Lutetia',
        address: 'Paris',
        checkIn: '2026-06-10',
        checkOut: '2026-06-12',
      ),
    ],
    segments: const [
      TripSegment(
        id: 'seg1',
        mode: 'flight',
        origin: 'JFK',
        destination: 'Paris',
        departDate: '2026-06-10',
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider
            .overrideWithValue(_FakeTripsApiService(trip)),
        accommodationsApiServiceProvider
            .overrideWithValue(_FakeAccommodationsApi(sink)),
        transportApiServiceProvider.overrideWithValue(_FakeTransportApi(sink)),
        expensesProvider('t1').overrideWith((ref) async => const <Expense>[]),
      ],
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        home: const TripDetailScreen(tripId: 't1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return sink;
}

/// Opens the booking card's overflow menu and picks Remove.
Future<void> _tapRemove(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_vert).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Remove').last);
  await tester.pumpAndSettle();
}

/// Opens the overflow menu belonging to the detail row titled [rowTitle] —
/// scoped, because the page renders several `more_vert`s.
Future<void> _openRowMenu(WidgetTester tester, String rowTitle) async {
  await tester.tap(find.descendant(
    of: find.widgetWithText(BookingDetailRow, rowTitle),
    matching: find.byIcon(Icons.more_vert),
  ));
  await tester.pumpAndSettle();
}

/// The dialog's own Remove — distinct from the menu entry of the same name.
Finder get _dialogRemove => find.descendant(
    of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Remove'));

void main() {
  testWidgets('removing asks first, and cancelling deletes nothing',
      (WidgetTester tester) async {
    final api = await _pump(tester);

    await _tapRemove(tester);

    // The ask, before anything has been sent.
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Remove "Museum tickets"?'), findsOneWidget);
    expect(find.text("This can't be undone."), findsOneWidget);
    expect(api.deleted, isEmpty);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(api.deleted, isEmpty, reason: 'cancel must not delete');
    expect(find.text('Museum tickets'), findsWidgets, reason: 'row still there');
  });

  testWidgets('confirming removes it', (WidgetTester tester) async {
    final api = await _pump(tester);

    await _tapRemove(tester);
    await tester.tap(_dialogRemove);
    await tester.pumpAndSettle();

    expect(api.deleted, ['todo-1']);
  });

  testWidgets('a booking carrying nothing gets the plain ask',
      (WidgetTester tester) async {
    await _pump(tester);
    await _tapRemove(tester);

    // No stakes invented where there are none.
    expect(find.textContaining('saved option'), findsNothing);
    expect(find.textContaining('linked expense'), findsNothing);
    expect(find.textContaining('cancel anything'), findsNothing);
  });

  testWidgets('the ask names a shortlist it is about to CASCADE away',
      (WidgetTester tester) async {
    await _pump(tester, savedOptions: 3);
    await _tapRemove(tester);

    expect(find.text('Its 3 saved options are deleted with it.'),
        findsOneWidget);
  });

  testWidgets('one saved option reads in the singular',
      (WidgetTester tester) async {
    await _pump(tester, savedOptions: 1);
    await _tapRemove(tester);

    expect(find.text('Its 1 saved option is deleted with it.'), findsOneWidget);
  });

  testWidgets('the ask names a linked expense that will survive the row',
      (WidgetTester tester) async {
    await _pump(tester, expenses: const [
      Expense(
        id: 'e1',
        category: 'activities',
        label: 'Museum',
        amount: 30,
        sourceKind: 'booking_todo',
        sourceId: 'todo-1',
      ),
    ]);
    await _tapRemove(tester);

    expect(find.textContaining('linked expense stays in your budget'),
        findsOneWidget);
  });

  testWidgets('an expense pointing at a DIFFERENT row is not warned about',
      (WidgetTester tester) async {
    await _pump(tester, expenses: const [
      Expense(
        id: 'e1',
        category: 'activities',
        label: 'Something else',
        amount: 30,
        sourceKind: 'booking_todo',
        sourceId: 'another-todo',
      ),
    ]);
    await _tapRemove(tester);

    expect(find.textContaining('linked expense'), findsNothing);
  });

  testWidgets('a booked row says the provider still holds the reservation',
      (WidgetTester tester) async {
    await _pump(tester, booked: true);
    await _tapRemove(tester);

    expect(find.textContaining("doesn't cancel anything with the provider"),
        findsOneWidget);
  });

  testWidgets('a stay asks too, and cancelling keeps it',
      (WidgetTester tester) async {
    final api = await _pumpRecords(tester);

    await _openRowMenu(tester, 'Hotel Lutetia');
    await tester.tap(find.text('Remove stay'));
    await tester.pumpAndSettle();

    expect(find.text('Remove "Hotel Lutetia"?'), findsOneWidget);
    // No shortlist claim: booking_options hangs off a booking todo, and the
    // pointer back at a stay is ON DELETE SET NULL, so nothing of its own dies.
    expect(find.textContaining('saved option'), findsNothing);
    expect(api.deletedStays, isEmpty);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(api.deletedStays, isEmpty);

    // And confirming does remove it.
    await _openRowMenu(tester, 'Hotel Lutetia');
    await tester.tap(find.text('Remove stay'));
    await tester.pumpAndSettle();
    await tester.tap(_dialogRemove);
    await tester.pumpAndSettle();
    expect(api.deletedStays, ['acc1']);
  });

  testWidgets('a transport segment asks too, titled by its route',
      (WidgetTester tester) async {
    final api = await _pumpRecords(tester);

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove transport'));
    await tester.pumpAndSettle();

    expect(find.text('Remove "JFK → Paris"?'), findsOneWidget);
    expect(api.deletedSegments, isEmpty);

    await tester.tap(_dialogRemove);
    await tester.pumpAndSettle();
    expect(api.deletedSegments, ['seg1']);
  });

  group('Trip.savedOptionsFor', () {
    test('counts only the options hanging off the given booking', () {
      final trip = Trip(
        id: 't1',
        title: 'Athens',
        createdAt: '2026-06-01',
        updatedAt: '2026-06-01',
        bookingOptionTodoIds: const ['a', 'b', 'a', 'a'],
      );
      expect(trip.savedOptionsFor('a'), 3);
      expect(trip.savedOptionsFor('b'), 1);
      expect(trip.savedOptionsFor('never-seen'), 0);
    });

    test('reads the shortlist the server actually sends', () {
      final trip = Trip.fromJson({
        'id': 't1',
        'title': 'Athens',
        'created_at': '2026-06-01',
        'updated_at': '2026-06-01',
        'booking_options': [
          {'id': 'o1', 'booking_todo_id': 'a', 'title': 'Hotel Grande'},
          {'id': 'o2', 'booking_todo_id': 'a', 'title': 'Hotel Petit'},
          {'id': 'o3', 'booking_todo_id': 'b', 'title': 'Ferry'},
        ],
      });
      expect(trip.savedOptionsFor('a'), 2);
      expect(trip.savedOptionsFor('b'), 1);
    });

    test('a viewer payload (no shortlist at all) counts zero, not null', () {
      final trip = Trip.fromJson({
        'id': 't1',
        'title': 'Athens',
        'created_at': '2026-06-01',
        'updated_at': '2026-06-01',
      });
      expect(trip.bookingOptionTodoIds, isEmpty);
      expect(trip.savedOptionsFor('a'), 0);
    });

    test('survives the offline cache round-trip', () {
      // TripCache stores toJson and reads it back. If the count did not
      // round-trip, a cached trip would promise a removal costs nothing.
      final trip = Trip.fromJson({
        'id': 't1',
        'title': 'Athens',
        'created_at': '2026-06-01',
        'updated_at': '2026-06-01',
        'booking_options': [
          {'id': 'o1', 'booking_todo_id': 'a'},
          {'id': 'o2', 'booking_todo_id': 'a'},
        ],
      });
      final cached = Trip.fromJson(trip.toJson());
      expect(cached.savedOptionsFor('a'), 2);
    });
  });
}
