import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';

import 'support/l10n_test_app.dart';

ItineraryItem _item(int pos, String name, String category,
        {int? day, String? city}) =>
    ItineraryItem(
      id: 'i-$name',
      position: pos,
      name: name,
      address: '$name address',
      // Zero coords so the screen skips the map widget in the test env.
      latitude: 0,
      longitude: 0,
      category: category,
      day: day,
      city: city,
    );

Trip _tripWith(List<ItineraryItem> items) => Trip(
      id: 't1',
      title: 'Paris',
      startDate: '2026-09-01',
      endDate: '2026-09-03',
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: items,
    );

/// Serves the seeded trip and mirrors the server: a successful DELETE drops
/// the item from the served list, a successful add (undo) appends it back,
/// so the screen's silent refresh after either call sees the new state.
///
/// [getTripGate] can hold a fetch mid-flight, which is what lets a test
/// observe the frame a loud `_load()` would have spent on the full-screen
/// spinner.
class _FakeTripsApiService extends TripsApiService {
  List<ItineraryItem> items;
  final List<String> deletedIds = [];
  final List<List<String>> reorderCalls = [];
  final List<Map<String, dynamic>> updateCalls = [];
  Completer<void>? getTripGate;
  bool getTripInFlight = false;
  _FakeTripsApiService(Trip trip)
      : items = trip.items!,
        super(ApiClient(baseUrl: 'http://test'));

  // A fresh list per fetch, like a real JSON parse.
  @override
  Future<Trip> getTrip(String id) async {
    final gate = getTripGate;
    if (gate != null) {
      getTripInFlight = true;
      await gate.future;
    }
    return _tripWith(List.of(items));
  }

  @override
  Future<void> deleteItineraryItem(String tripId, String itemId) async {
    deletedIds.add(itemId);
    items = items.where((it) => it.id != itemId).toList();
  }

  @override
  Future<void> reorderItineraryItems(
      String tripId, List<String> itemIds) async {
    reorderCalls.add(itemIds);
    final byId = {for (final it in items) it.id: it};
    items = [for (final id in itemIds) byId[id]!];
  }

  @override
  Future<ItineraryItem> updateItineraryItem(
      String tripId, String itemId, Map<String, dynamic> body) async {
    updateCalls.add(body);
    items = [
      for (final it in items)
        if (it.id == itemId)
          ItineraryItem(
            id: it.id,
            position: it.position,
            name: (body['name'] as String?) ?? it.name,
            address: it.address,
            latitude: it.latitude,
            longitude: it.longitude,
            category: (body['category'] as String?) ?? it.category,
            day: (body['day'] as int?) ?? it.day,
            city: (body['city'] as String?) ?? it.city,
            timeOfDay: (body['time_of_day'] as String?) ?? it.timeOfDay,
          )
        else
          it,
    ];
    return items.firstWhere((it) => it.id == itemId);
  }

  @override
  Future<Trip> addItineraryItem(String tripId, Map<String, dynamic> body) async {
    items = [
      ...items,
      ItineraryItem(
        id: 'i-restored-${body['name']}',
        position: items.length,
        name: body['name'] as String,
        address: body['address'] as String?,
        latitude: (body['latitude'] as num?)?.toDouble() ?? 0,
        longitude: (body['longitude'] as num?)?.toDouble() ?? 0,
        category: body['category'] as String?,
        day: body['day'] as int?,
        city: body['city'] as String?,
      ),
    ];
    return _tripWith(List.of(items));
  }
}

/// Item rows render inside lazy slivers; a tall viewport keeps the whole
/// itinerary built and findable.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<_FakeTripsApiService> _pump(WidgetTester tester, Trip trip) async {
  final fake = _FakeTripsApiService(trip);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [tripsApiServiceProvider.overrideWithValue(fake)],
      child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
  return fake;
}

/// Opens [name]'s kebab menu and taps [action]. Returns without waiting, so
/// the caller can observe frames while the action's reload is still in
/// flight.
Future<void> _tapMenuAction(
    WidgetTester tester, String name, String action) async {
  final row =
      find.ancestor(of: find.text(name), matching: find.byType(ListTile));
  await tester.tap(
      find.descendant(of: row, matching: find.byIcon(Icons.more_vert)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(action));
}

Future<void> _deleteViaMenu(WidgetTester tester, String name) =>
    _tapMenuAction(tester, name, 'Remove');

/// Drives frames until the fake reports a gated getTrip in flight, then one
/// more so the frame asserting against reflects any setState the reload
/// issued on its way in (the loud _load() flips _loading synchronously
/// before awaiting getTrip).
Future<void> _pumpUntilReloadInFlight(
    WidgetTester tester, _FakeTripsApiService fake) async {
  for (var i = 0; i < 40 && !fake.getTripInFlight; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
  expect(fake.getTripInFlight, isTrue,
      reason: 'the mutation should be followed by a reload');
  await tester.pump();
}

void main() {
  testWidgets('deleting an item removes it in place — no full-screen reload',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final fake = await _pump(
      tester,
      _tripWith([
        _item(0, 'Louvre', 'attraction', day: 1, city: 'Paris'),
        _item(1, 'Orsay', 'attraction', day: 1, city: 'Paris'),
      ]),
    );

    fake.getTripGate = Completer<void>();
    await _deleteViaMenu(tester, 'Louvre');
    await _pumpUntilReloadInFlight(tester, fake);

    // Mid-reload: the list stays on screen. The loud _load() this replaced
    // swapped the whole body for a spinner on exactly this frame.
    expect(find.text('Orsay'), findsOneWidget);

    fake.getTripGate!.complete();
    await tester.pumpAndSettle();
    expect(fake.deletedIds, ['i-Louvre']);
    expect(find.text('Louvre'), findsNothing);
    expect(find.text('Orsay'), findsOneWidget);
    expect(find.text('Removed Louvre'), findsOneWidget);
  });

  testWidgets('undo restores the item in place — no full-screen reload',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final fake = await _pump(
      tester,
      _tripWith([
        _item(0, 'Louvre', 'attraction', day: 1, city: 'Paris'),
        _item(1, 'Orsay', 'attraction', day: 1, city: 'Paris'),
      ]),
    );

    await _deleteViaMenu(tester, 'Louvre');
    await tester.pumpAndSettle();
    expect(find.text('Louvre'), findsNothing);

    fake.getTripGate = Completer<void>();
    await tester.tap(find.text('Undo'));
    await _pumpUntilReloadInFlight(tester, fake);

    // Same contract on the way back: the undo's reload never replaces the
    // list with a spinner.
    expect(find.text('Orsay'), findsOneWidget);

    fake.getTripGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Louvre'), findsOneWidget);
    expect(find.text('Orsay'), findsOneWidget);
  });

  testWidgets('moving an item down swaps in place — no full-screen reload',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final fake = await _pump(
      tester,
      _tripWith([
        _item(0, 'Louvre', 'attraction', day: 1, city: 'Paris'),
        _item(1, 'Orsay', 'attraction', day: 1, city: 'Paris'),
      ]),
    );

    fake.getTripGate = Completer<void>();
    await _tapMenuAction(tester, 'Louvre', 'Move down');
    await _pumpUntilReloadInFlight(tester, fake);

    // Same contract as delete: the reload behind a one-swap move never
    // replaces the list with the full-screen spinner.
    expect(find.text('Orsay'), findsOneWidget);

    fake.getTripGate!.complete();
    await tester.pumpAndSettle();
    expect(fake.reorderCalls, [
      ['i-Orsay', 'i-Louvre']
    ]);
    final orsayTop = tester
        .getTopLeft(find.ancestor(
            of: find.text('Orsay'), matching: find.byType(ListTile)))
        .dy;
    final louvreTop = tester
        .getTopLeft(find.ancestor(
            of: find.text('Louvre'), matching: find.byType(ListTile)))
        .dy;
    expect(orsayTop, lessThan(louvreTop));
  });

  testWidgets(
      'adding a place via the dialog updates in place — no full-screen reload',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final fake = await _pump(
      tester,
      _tripWith([
        _item(0, 'Louvre', 'attraction', day: 1, city: 'Paris'),
        _item(1, 'Orsay', 'attraction', day: 1, city: 'Paris'),
      ]),
    );

    await tester.tap(find.text('Add place').first);
    await tester.pumpAndSettle();
    // The dialog's manual-entry path: no search round-trip needed.
    await tester.tap(find.text("Can't find it? Add manually"));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Place name'), 'Pompidou');

    fake.getTripGate = Completer<void>();
    await tester.tap(find.text('Add'));
    await _pumpUntilReloadInFlight(tester, fake);
    // Let the dialog's pop animation finish — the reload is still gated, so
    // this is the frame a loud _load() would have spent on the spinner.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    // Mid-reload: the dialog is gone and the list stays on screen.
    expect(find.text('Orsay'), findsOneWidget);

    fake.getTripGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Pompidou'), findsOneWidget);
    expect(find.text('Orsay'), findsOneWidget);
  });

  testWidgets(
      'saving the reorder-section sheet updates in place — no full-screen reload',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    // Three items in one section: the "Reorder section" menu entry only
    // renders for sections longer than two.
    final fake = await _pump(
      tester,
      _tripWith([
        _item(0, 'Louvre', 'attraction', day: 1, city: 'Paris'),
        _item(1, 'Orsay', 'attraction', day: 1, city: 'Paris'),
        _item(2, 'Pompidou', 'attraction', day: 1, city: 'Paris'),
      ]),
    );

    await _tapMenuAction(tester, 'Louvre', 'Reorder section');
    await tester.pumpAndSettle();
    expect(find.text('Reorder places'), findsOneWidget);

    fake.getTripGate = Completer<void>();
    await tester.tap(find.text('Save order'));
    await _pumpUntilReloadInFlight(tester, fake);
    // Let the sheet's exit animation finish — the reload is still gated, so
    // this is the frame a loud _load() would have spent on the spinner.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    // Mid-reload: the sheet is gone and the list stays on screen.
    expect(find.text('Orsay'), findsOneWidget);

    fake.getTripGate!.complete();
    await tester.pumpAndSettle();
    // Save submits the sheet's order through the same PUT /items/order path
    // as Move up/down (unchanged here — the reload contract is the subject).
    expect(fake.reorderCalls, [
      ['i-Louvre', 'i-Orsay', 'i-Pompidou']
    ]);
    expect(find.text('Louvre'), findsOneWidget);
    expect(find.text('Pompidou'), findsOneWidget);
  });

  testWidgets('editing an item updates in place — no full-screen reload',
      (WidgetTester tester) async {
    _useTallViewport(tester);
    final fake = await _pump(
      tester,
      _tripWith([
        _item(0, 'Louvre', 'attraction', day: 1, city: 'Paris'),
        _item(1, 'Orsay', 'attraction', day: 1, city: 'Paris'),
      ]),
    );

    await _tapMenuAction(tester, 'Louvre', 'Edit');
    await tester.pumpAndSettle();
    // The edit sheet: rename in the Name field and save.
    await tester.enterText(
        find.widgetWithText(TextField, 'Name'), 'Louvre Museum');

    fake.getTripGate = Completer<void>();
    await tester.tap(find.text('Save'));
    await _pumpUntilReloadInFlight(tester, fake);

    expect(find.text('Orsay'), findsOneWidget);

    fake.getTripGate!.complete();
    await tester.pumpAndSettle();
    expect(fake.updateCalls, [
      {'name': 'Louvre Museum'}
    ]);
    expect(find.text('Louvre Museum'), findsOneWidget);
    expect(find.text('Orsay'), findsOneWidget);
  });
}
