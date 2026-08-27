import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/place_search_result.dart';
import 'package:travel_route_planner/providers/places_api_provider.dart';
import 'package:travel_route_planner/widgets/booking_sheets.dart';

import 'support/l10n_test_app.dart';

/// Place-backed manual stays (specs day-travel-times, ticket C). The rule
/// these tests pin: **coordinates ride with a pick, visibly** — picking a
/// search result fills name + address and attaches lat/lng; the attached row
/// is the only detach; free-typing never touches coordinates; a detached
/// edit sends `clear_location` because the PATCH's COALESCE cannot clear.
///
/// All layout-free by design: presence, controller text, and the popped body
/// map — never a wrap point or pixel position (the widget-test font rule).

PlaceSearchResult _estherea() => const PlaceSearchResult(
      placeId: 'pid-estherea',
      name: 'Hotel Estherea',
      address: 'Singel 303-309, Amsterdam',
      latitude: 52.5,
      longitude: 4.875,
      types: ['lodging'],
    );

PlaceSearchResult _door74() => const PlaceSearchResult(
      placeId: 'pid-door74',
      name: 'Door 74',
      address: 'Reguliersdwarsstraat 74, Amsterdam',
      latitude: 52.25,
      longitude: 4.75,
      types: ['bar'],
    );

const _ungeocoded = Accommodation(id: 'a1', name: 'Some hotel near Old Town');

const _placed = Accommodation(
  id: 'a2',
  name: 'Hotel Estherea',
  address: 'Singel 303-309, Amsterdam',
  latitude: 52.5,
  longitude: 4.875,
);

class _Popped {
  Map<String, dynamic>? body;
  bool closed = false;
}

class _SheetHost extends StatelessWidget {
  final Accommodation? initial;
  final _Popped popped;
  const _SheetHost({this.initial, required this.popped});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () async {
            final body = await showModalBottomSheet<Map<String, dynamic>>(
              context: context,
              isScrollControlled: true,
              builder: (_) => AddStaySheet(initial: initial),
            );
            popped
              ..body = body
              ..closed = true;
          },
          child: const Text('open'),
        ),
      ),
    );
  }
}

/// Pumps a host inside ProviderScope (the sheet's search results watch
/// [placeSearchProvider]) and opens the sheet, returning the pop capture.
Future<_Popped> _openSheet(
  WidgetTester tester, {
  Accommodation? initial,
  List<PlaceSearchResult> results = const [],
}) async {
  final popped = _Popped();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        placeSearchProvider.overrideWith((ref, query) async => results),
      ],
      child: localizedTestApp(
        home: _SheetHost(initial: initial, popped: popped),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return popped;
}

/// Types into the search field and lets the 350 ms debounce fire.
Future<void> _search(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(kStaySearchFieldKey), text);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

/// The sheet can outgrow the 600 px test viewport, and a bare tap on an
/// off-screen button only warns — scroll it into view first.
Future<void> _tapSheetButton(WidgetTester tester, String label) async {
  final button = find.widgetWithText(FilledButton, label);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

String _nameFieldText(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(kStayNameFieldKey))
    .controller!
    .text;

void main() {
  testWidgets('picking a search result fills the fields and saves coordinates',
      (tester) async {
    final popped = await _openSheet(tester, results: [_estherea()]);

    // Fresh sheet: search offered, nothing attached.
    expect(find.byKey(kStaySearchFieldKey), findsOneWidget);
    expect(find.byKey(kStayPlacedRowKey), findsNothing);

    await _search(tester, 'Estherea');
    await tester.tap(find.text('Hotel Estherea'));
    await tester.pumpAndSettle();

    // The pick filled the manual fields and swapped search for the
    // attached-location row.
    expect(_nameFieldText(tester), 'Hotel Estherea');
    expect(find.byKey(kStayPlacedRowKey), findsOneWidget);
    expect(find.byKey(kStaySearchFieldKey), findsNothing);

    await _tapSheetButton(tester, 'Add stay');
    expect(popped.closed, isTrue);
    expect(popped.body, isNotNull);
    expect(popped.body!['name'], 'Hotel Estherea');
    expect(popped.body!['address'], 'Singel 303-309, Amsterdam');
    expect(popped.body!['latitude'], 52.5);
    expect(popped.body!['longitude'], 4.875);
    expect(popped.body!.containsKey('clear_location'), isFalse);
  });

  testWidgets('a hand-typed stay upgrades to a placed stay via edit',
      (tester) async {
    final popped =
        await _openSheet(tester, initial: _ungeocoded, results: [_estherea()]);

    // An ungeocoded stay opens unattached, search offered.
    expect(find.byKey(kStayPlacedRowKey), findsNothing);

    await _search(tester, 'Estherea');
    await tester.tap(find.text('Hotel Estherea'));
    await tester.pumpAndSettle();
    await _tapSheetButton(tester, 'Save');

    expect(popped.body!['name'], 'Hotel Estherea');
    expect(popped.body!['latitude'], 52.5);
    expect(popped.body!['longitude'], 4.875);
  });

  testWidgets('re-picking replaces the coordinates', (tester) async {
    final popped =
        await _openSheet(tester, initial: _placed, results: [_door74()]);

    // A placed stay opens attached; detaching brings the search field back.
    expect(find.byKey(kStayPlacedRowKey), findsOneWidget);
    expect(find.byKey(kStaySearchFieldKey), findsNothing);
    await tester.tap(find.byKey(kStayPlacedRemoveKey));
    await tester.pumpAndSettle();
    expect(find.byKey(kStaySearchFieldKey), findsOneWidget);

    await _search(tester, 'Door');
    await tester.tap(find.text('Door 74'));
    await tester.pumpAndSettle();
    await _tapSheetButton(tester, 'Save');

    expect(popped.body!['name'], 'Door 74');
    expect(popped.body!['latitude'], 52.25);
    expect(popped.body!['longitude'], 4.75);
    expect(popped.body!.containsKey('clear_location'), isFalse);
  });

  testWidgets('detaching without re-picking sends clear_location',
      (tester) async {
    final popped = await _openSheet(tester, initial: _placed);

    await tester.tap(find.byKey(kStayPlacedRemoveKey));
    await tester.pumpAndSettle();
    expect(find.byKey(kStayPlacedRowKey), findsNothing);

    await _tapSheetButton(tester, 'Save');

    expect(popped.body!['clear_location'], isTrue);
    expect(popped.body!.containsKey('latitude'), isFalse);
    expect(popped.body!.containsKey('longitude'), isFalse);
  });

  testWidgets('typing a different name keeps the attachment', (tester) async {
    final popped = await _openSheet(tester, initial: _placed);

    await tester.enterText(
        find.byKey(kStayNameFieldKey), 'Estherea (canal room)');
    // Free-typing never touches the attachment — the row stays, coordinates
    // ride the save unchanged.
    expect(find.byKey(kStayPlacedRowKey), findsOneWidget);

    await _tapSheetButton(tester, 'Save');
    expect(popped.body!['name'], 'Estherea (canal room)');
    expect(popped.body!['latitude'], 52.5);
    expect(popped.body!['longitude'], 4.875);
  });

  testWidgets('manual entry saves exactly as today', (tester) async {
    // Guard, not a new-behavior pin: the body shape it asserts predates this
    // change (only the finder keys are new). A no-pick save must stay
    // byte-identical to the pre-search sheet — no latitude, no longitude,
    // no clear_location.
    final popped = await _openSheet(tester);

    await tester.enterText(find.byKey(kStayNameFieldKey), 'Casa do Brian');
    await _tapSheetButton(tester, 'Add stay');

    expect(popped.body, {'name': 'Casa do Brian'});
  });

  testWidgets('a junk (0,0) stay opens unattached and stays untouched',
      (tester) async {
    // The (0,0) sentinel is not a pin (TripMap.stayHasCoords); the sheet
    // must not show an attachment for it, and saving without picking must
    // not "detach" it either — clear_location says the traveler removed a
    // real attachment, which never existed here.
    const junk = Accommodation(
        id: 'a3', name: 'Mystery stay', latitude: 0, longitude: 0);
    final popped = await _openSheet(tester, initial: junk);

    expect(find.byKey(kStayPlacedRowKey), findsNothing);
    expect(find.byKey(kStaySearchFieldKey), findsOneWidget);

    await _tapSheetButton(tester, 'Save');
    expect(popped.body!.containsKey('clear_location'), isFalse);
    expect(popped.body!.containsKey('latitude'), isFalse);
  });

  testWidgets('search unavailable steers to the manual fields',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          placeSearchProvider.overrideWith(
              (ref, query) async => throw Exception('no key')),
        ],
        child: localizedTestApp(
          home: _SheetHost(popped: _Popped()),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await _search(tester, 'Estherea');
    expect(
        find.text('Search unavailable — add the place manually below.'),
        findsOneWidget);
    // The manual path is still live.
    expect(find.byKey(kStayNameFieldKey), findsOneWidget);
  });
}
