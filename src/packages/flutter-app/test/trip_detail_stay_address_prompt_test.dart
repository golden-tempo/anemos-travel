import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/models/budget.dart';
import 'package:travel_route_planner/models/expense.dart';
import 'package:travel_route_planner/services/accommodations_api_service.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/booking_todos_api_service.dart';
import 'package:travel_route_planner/services/budget_api_service.dart';
import 'package:travel_route_planner/services/transport_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/accommodations_provider.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/budget_provider.dart';
import 'package:travel_route_planner/providers/transport_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/booking_todo_card.dart';
import 'package:travel_route_planner/widgets/stay_address_prompt.dart';

import 'support/l10n_test_app.dart';

/// The stay-address prompt on the booked flip (specs/booking-address-
/// prompt): checking a stay row with no saved address offers to add one
/// before the (pre-existing) budget prompt runs — harness cloned from
/// trip_detail_booked_expense_prompt_test.dart.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

class _FakeBookingTodosApiService extends BookingTodosApiService {
  _FakeBookingTodosApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<BookingTodo>> syncTodos(
          String tripId, List<Map<String, dynamic>> derived) async =>
      throw Exception('offline test env');

  @override
  Future<BookingTodo> setBooked(
      String tripId, String todoId, bool booked) async {
    return BookingTodo(
        id: todoId, kind: 'stay', todoKey: 'k', title: 't', booked: booked);
  }
}

class _FakeAccommodationsApiService extends AccommodationsApiService {
  final List<Map<String, dynamic>> addCalls = [];
  final List<(String, Map<String, dynamic>)> updateCalls = [];
  _FakeAccommodationsApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Accommodation> add(String tripId, Map<String, dynamic> body) async {
    addCalls.add(body);
    return Accommodation(
      id: 'new-acc',
      name: body['name'] as String,
      address: body['address'] as String?,
      latitude: body['latitude'] as double?,
      longitude: body['longitude'] as double?,
    );
  }

  @override
  Future<Accommodation> update(
      String tripId, String accId, Map<String, dynamic> body) async {
    updateCalls.add((accId, body));
    return Accommodation(
      id: accId,
      name: 'Hotel Lutetia',
      address: body['address'] as String?,
      latitude: body['latitude'] as double?,
      longitude: body['longitude'] as double?,
    );
  }
}

class _FakeTransportApiService extends TransportApiService {
  _FakeTransportApiService() : super(ApiClient(baseUrl: 'http://test'));
}

class _FakeBudgetApiService extends BudgetApiService {
  final List<Map<String, dynamic>> addCalls = [];
  _FakeBudgetApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Budget> getBudget(String tripId) async =>
      Budget(currency: 'EUR', spent: 0);

  @override
  Future<List<Expense>> listExpenses(String tripId) async => const [];

  @override
  Future<Expense> addExpense(String tripId,
      {required String category,
      required String label,
      required double amount,
      bool planned = false,
      String? sourceKind,
      String? sourceId,
      String? legKey,
      bool legPlan = false}) async {
    addCalls.add({
      'category': category,
      'label': label,
      'amount': amount,
      'source_kind': sourceKind,
      'source_id': sourceId,
    });
    return Expense(
        id: 'new-1',
        category: category,
        label: label,
        amount: amount,
        actualAmount: amount,
        purchased: true,
        auto: sourceKind != null,
        sourceKind: sourceKind,
        sourceId: sourceId);
  }

  @override
  Future<void> deleteExpense(String tripId, String expenseId) async {}
}

ItineraryItem _item(int pos, String name) => ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: 'Paris, France',
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: 1,
      city: 'Paris',
    );

Trip _trip({List<BookingTodo>? todos, List<Accommodation>? accommodations}) =>
    Trip(
      id: 't1',
      title: 'Paris',
      startDate: '2026-06-10',
      endDate: '2026-06-12',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [_item(0, 'Louvre')],
      bookingTodos: todos,
      accommodations: accommodations ?? const [],
    );

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<
    (
      _FakeAccommodationsApiService,
      _FakeBudgetApiService,
    )> _pump(WidgetTester tester, Trip trip) async {
  final accApi = _FakeAccommodationsApiService();
  final budgetApi = _FakeBudgetApiService();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        bookingTodosApiServiceProvider
            .overrideWithValue(_FakeBookingTodosApiService()),
        accommodationsApiServiceProvider.overrideWithValue(accApi),
        transportApiServiceProvider
            .overrideWithValue(_FakeTransportApiService()),
        budgetApiServiceProvider.overrideWithValue(budgetApi),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
  return (accApi, budgetApi);
}

Future<void> _tickRow(WidgetTester tester, String title) async {
  final row = find.widgetWithText(BookingTodoRow, title);
  await tester.tap(find.descendant(of: row, matching: find.byType(Checkbox)));
  await tester.pumpAndSettle();
}

const _stayTodo = BookingTodo(
    id: 'td-stay', kind: 'stay', todoKey: 'stay:paris', title: 'Stay in Paris');

const _confirmedStayNoAddress =
    Accommodation(id: 'acc1', name: 'Hotel Lutetia', autoKey: 'stay:paris');

const _confirmedStayWithAddress = Accommodation(
    id: 'acc1', name: 'Hotel Lutetia', address: 'Paris, already known');

void main() {
  testWidgets(
      'ticking a todo-only stay (no matched accommodation) prompts for an '
      'address', (tester) async {
    _useTallViewport(tester);
    await _pump(tester, _trip(todos: const [_stayTodo]));

    await _tickRow(tester, 'Stay in Paris');

    expect(find.text("Add your stay's address?"), findsOneWidget);
    expect(find.textContaining('Stay in Paris'), findsWidgets);
  });

  testWidgets('a stay already carrying an address is never prompted',
      (tester) async {
    _useTallViewport(tester);
    await _pump(
      tester,
      _trip(
          todos: const [_stayTodo],
          accommodations: const [_confirmedStayWithAddress]),
    );

    await _tickRow(tester, 'Stay in Paris');

    expect(find.text("Add your stay's address?"), findsNothing);
    // The pre-existing budget prompt still runs, untouched by this feature.
    expect(find.text('Add to budget?'), findsOneWidget);
  });

  testWidgets('Skip leaves no accommodation created and still offers budget',
      (tester) async {
    _useTallViewport(tester);
    final (accApi, _) = await _pump(tester, _trip(todos: const [_stayTodo]));

    await _tickRow(tester, 'Stay in Paris');
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    expect(accApi.addCalls, isEmpty);
    // Falls through to the budget prompt exactly as before this feature.
    expect(find.text('Add to budget?'), findsOneWidget);
  });

  testWidgets(
      'saving a typed address creates an accommodation named after the todo, '
      'and the budget prompt then prefills from it', (tester) async {
    _useTallViewport(tester);
    final (accApi, budgetApi) =
        await _pump(tester, _trip(todos: const [_stayTodo]));

    await _tickRow(tester, 'Stay in Paris');
    await tester.enterText(
        find.byKey(kStayAddressPromptAddressFieldKey), '12 Rue de Rivoli');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(accApi.addCalls, hasLength(1));
    expect(accApi.addCalls.single['name'], 'Stay in Paris');
    expect(accApi.addCalls.single['address'], '12 Rue de Rivoli');
    expect(accApi.addCalls.single.containsKey('latitude'), isFalse);

    // Budget prompt follows, now prefilled from the freshly created stay
    // (lodging + its name) rather than the todo's own (identical) title.
    expect(find.text('Add to budget?'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Stay in Paris'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Amount (EUR)'), '150');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(budgetApi.addCalls.single['source_kind'], 'accommodation');
    expect(budgetApi.addCalls.single['source_id'], 'new-acc');
  });

  testWidgets('a matched stay with no address is patched, not re-created',
      (tester) async {
    _useTallViewport(tester);
    final (accApi, _) = await _pump(
      tester,
      _trip(
          todos: const [_stayTodo],
          accommodations: const [_confirmedStayNoAddress]),
    );

    await _tickRow(tester, 'Stay in Paris');
    expect(find.text("Add your stay's address?"), findsOneWidget);

    await tester.enterText(
        find.byKey(kStayAddressPromptAddressFieldKey), 'Rue de Rivoli 12');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(accApi.addCalls, isEmpty);
    // Two PATCHes on the same matched stay: the booked-flip lockstep write
    // (specs/next-step-cta), then this feature's address write.
    expect(accApi.updateCalls, hasLength(2));
    expect(accApi.updateCalls.first.$1, 'acc1');
    expect(accApi.updateCalls.first.$2, <String, dynamic>{'booked': true});
    final (id, body) = accApi.updateCalls.last;
    expect(id, 'acc1');
    expect(body['address'], 'Rue de Rivoli 12');
  });
}
