import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/map_leg_chips.dart';
import 'package:travel_route_planner/widgets/trip_map.dart';

import 'support/chip_finders.dart';
import 'support/city_groups.dart';
import 'support/l10n_test_app.dart';

// The map/list decoupling contract (specs/map-city-focus, decoupled rev;
// scroll semantics per the map-row redesign, which unpinned the wide band):
//   * city groups default EXPANDED; expansion is list-only state
//     (_collapsedGroups) — a header tap is a pure toggle of that ONE group:
//     it never writes map focus, never moves the camera, never touches
//     other groups;
//   * map focus (_focusedLegKey) is MAP-only state: a chip tap focuses the
//     leg and un-collapses its group, and NEVER scrolls the list — at any
//     width, the chips ride a map card that scrolls with the page, so a
//     scroll would carry the just-focused map away (the accepted tradeoff
//     in the map-row ticket). The All chip resets the MAP only;
//   * a map pin tap reveals its run in the list WITHOUT moving the camera
//     (reveal-only), and a focus change clears the map pin selection;
//   * a destination (region) pin tap on the All overview scrolls the list
//     to the region's group — an explicit "take me there" — with no focus
//     write; the camera never moves;
//   * bookings lenses (no city headers) get map-only chips, lens kept;
//   * revisited cities focus per RUN key; single-leg trips have no focus.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// getTrip flips from [v1] to [v2] once addItineraryItem is called, so the
/// screen's post-add `_load()` sees the new item (the Add-place flow).
class _AddingTripsApiService extends TripsApiService {
  final Trip v1;
  final Trip v2;
  bool added = false;
  _AddingTripsApiService(this.v1, this.v2)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => added ? v2 : v1;

  @override
  Future<Trip> addItineraryItem(String tripId, Map<String, dynamic> body) async {
    added = true;
    return v2;
  }
}

ItineraryItem _item(
  int pos,
  String name,
  String city,
  double lat,
  double lng,
  int day,
) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      latitude: lat,
      longitude: lng,
      category: 'attraction',
      day: day,
      city: city,
    );

/// Paris (2 items) → Rome (8 items — enough scroll extent for the desktop
/// rest-below-chrome assertion) → Berlin (1 item), all geocoded.
Trip _threeCityTrip() => Trip(
      id: 't1',
      title: 'Grand tour',
      createdAt: '2037-06-01',
      updatedAt: '2037-06-01',
      startDate: '2037-09-01',
      endDate: '2037-09-05',
      items: [
        _item(0, 'Louvre', 'Paris', 48.8606, 2.3376, 1),
        _item(1, 'Orsay', 'Paris', 48.8600, 2.3266, 2),
        for (var k = 0; k < 8; k++)
          _item(2 + k, 'Roman Forum $k', 'Rome', 41.89 + k * 0.001, 12.49, 3),
        _item(10, 'Brandenburg Gate', 'Berlin', 52.5163, 13.3777, 4),
      ],
    );

Future<void> _pump(WidgetTester tester, Trip trip) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
      ],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapChip(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(
    of: find.byType(MapLegChips),
    matching: find.text(label),
  ));
  // Settles the post-frame camera re-fit (chip taps never scroll the page).
  await tester.pumpAndSettle();
}

TripMap _map(WidgetTester tester) =>
    tester.widget<TripMap>(find.byType(TripMap));

void _useSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// The screen's own pinned tab-row extent (`_listHeaderHeight`, private to
/// the screen) — since the map-row redesign the ONLY chrome above a resting
/// header: the map band scrolls with the page at every width now, so the
/// old `mapBandHeaderHeight` term (and the constant itself) is gone.
const double _tabRowHeight = 56;

/// Where a city header comes to rest: below the pinned tab row, measured
/// from the viewport top (the app bar's bottom — the scroll math lives in
/// viewport coordinates).
double _pinnedSlot(WidgetTester tester) =>
    tester.getBottomLeft(find.byType(AppBar)).dy + _tabRowHeight;

void main() {
  testWidgets(
      'header taps are pure list toggles: the map never moves, focused '
      'or not', (tester) async {
    // Tall surface: with the map band pinned, expanded sections push
    // later headers below an 800px fold and header taps would miss.
    _useSurface(tester, const Size(1200, 2200));
    await _pump(tester, _threeCityTrip());

    expect(_map(tester).fitSignature, isNull);
    expect(find.text('Louvre'), findsOneWidget); // groups default expanded

    // Collapse Paris → the LIST folds; the map stays the All overview.
    await toggleCity(tester, 'Paris');
    expect(find.text('Louvre'), findsNothing);
    expect(_map(tester).fitSignature, isNull);
    expect(_map(tester).items, hasLength(11));

    // Re-expand: still not a focus write.
    await toggleCity(tester, 'Paris');
    expect(find.text('Louvre'), findsOneWidget);
    expect(_map(tester).fitSignature, isNull);
    expect(_map(tester).items, hasLength(11));

    // Under an active focus the toggle is just as map-inert: collapsing
    // the focused Rome folds the list, but the camera and its leg filter
    // both hold — there is no accordion tying the two together anymore.
    await _tapChip(tester, 'Rome');
    expect(_map(tester).fitSignature, 'Rome');
    await toggleCity(tester, 'Rome');
    expect(find.text('Roman Forum 0'), findsNothing);
    expect(_map(tester).fitSignature, 'Rome',
        reason: 'collapsing a group must not reset the map');
    expect(_map(tester).items, hasLength(8));
  });

  testWidgets(
      'wide chip tap focuses the map without scrolling the list '
      '(the band scrolls with the page — the map-row tradeoff)', (tester) async {
    _useSurface(tester, const Size(1200, 800));
    await _pump(tester, _threeCityTrip());

    final scrollable = find
        .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable))
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(0),
        reason: 'premise: the page must have somewhere to scroll — '
            'otherwise "did not scroll" is vacuous');
    expect(position.pixels, 0);

    await _tapChip(tester, 'Rome');

    expect(_map(tester).fitSignature, 'Rome');
    // The page did not move: wide adopted the phone's unpinned semantics
    // when the band stopped pinning — a scroll here would carry the
    // just-focused map (and the chip under the pointer) off screen. The
    // full-screen map's report-back is where selection still pre-scrolls
    // (trip_detail_map_expand_test).
    expect(position.pixels, 0);
  });

  testWidgets('a chip tap still re-opens its collapsed group (no scroll)',
      (tester) async {
    // Tall surface so every header is tappable without scrolling — the
    // scroll-suppression half lives in the 800px test above, where the page
    // actually has extent.
    _useSurface(tester, const Size(1200, 2200));
    await _pump(tester, _threeCityTrip());

    await collapseCity(tester, 'Rome');
    expect(find.text('Roman Forum 0'), findsNothing);

    await _tapChip(tester, 'Rome');

    expect(_map(tester).fitSignature, 'Rome');
    expect(find.text('Roman Forum 0'), findsOneWidget,
        reason: 'a chip tap must still re-open its collapsed group');
  });

  testWidgets('the map reset resets the map only: the list is untouched',
      (tester) async {
    // Tall surface: with the map row in the page flow (nothing pins above
    // the tab row anymore) and chip taps no longer scrolling, Rome's tiles
    // must fit on screen at rest for the list-untouched assertions to see
    // them build.
    _useSurface(tester, const Size(1200, 2200));
    await _pump(tester, _threeCityTrip());

    expect(mapResetButton, findsNothing,
        reason: 'nothing to reset until a leg is focused');
    await _tapChip(tester, 'Rome');
    expect(_map(tester).fitSignature, 'Rome');
    expect(find.text('Roman Forum 0'), findsOneWidget);

    // Clearing the focus returns the camera to the overview, but expansion
    // is list-only state — nothing collapses, no scroll happens.
    await tapMapReset(tester);
    expect(_map(tester).fitSignature, isNull);
    expect(_map(tester).items, hasLength(11));
    expect(find.text('Roman Forum 0'), findsOneWidget,
        reason: 'the reset must leave the list untouched');
    expect(mapResetButton, findsNothing);
  });

  testWidgets('phone chip tap focuses the map without scrolling the list',
      (tester) async {
    _useSurface(tester, const Size(375, 800));
    await _pump(tester, _threeCityTrip());

    final scrollable = find
        .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable))
        .first;
    expect(tester.state<ScrollableState>(scrollable).position.pixels, 0);

    await _tapChip(tester, 'Rome');

    expect(_map(tester).fitSignature, 'Rome');
    // The page did not move — the chips ride the scroll-away preview card,
    // and scrolling would hide the map itself. (No item assert: with every
    // group expanded, Rome's lazy tiles sit beyond the unscrolled cache
    // extent and never build.)
    expect(tester.state<ScrollableState>(scrollable).position.pixels, 0);
  });

  testWidgets('a focus change clears the map pin selection', (tester) async {
    _useSurface(tester, const Size(1200, 2200));
    await _pump(tester, _threeCityTrip());

    // Tapping an item row selects its pin on the map (the row is already
    // built: groups land expanded).
    await tester.tap(find.text('Roman Forum 1'));
    await tester.pumpAndSettle();
    expect(_map(tester).selectedPosition, 3);

    // Focusing another leg clears the selection: a lingering one would
    // suppress content refits and keep a ghost highlight.
    await _tapChip(tester, 'Paris');
    expect(_map(tester).selectedPosition, isNull);
    expect(_map(tester).fitSignature, 'Paris');
  });

  testWidgets('a pin tap reveals its run without moving the camera',
      (tester) async {
    _useSurface(tester, const Size(1200, 2200));
    await _pump(tester, _threeCityTrip());

    // A collapsed Rome is the case that matters: the reveal must re-open it.
    await collapseCity(tester, 'Rome');
    expect(find.text('Roman Forum 1'), findsNothing);

    // From the All view, tap a Rome pin (invoked directly — marker hit
    // boxes cluster-shift): its run un-collapses so the highlighted row is
    // reachable, but the camera must NOT refit out from under the
    // zoom-to-pin move — fitSignature stays All, focus is never written.
    _map(tester).onPinTap!(2);
    await tester.pumpAndSettle();
    expect(_map(tester).selectedPosition, 2);
    expect(_map(tester).fitSignature, isNull);
    // A sibling row, not the tapped item's name — that one also renders in
    // the pin-tap snackbar.
    expect(find.text('Roman Forum 1'), findsOneWidget);
  });

  testWidgets(
      'a destination pin tap scrolls to the region without touching the map',
      (tester) async {
    // Tall enough that Rome's header sits above the fold for the collapse
    // tap, short enough that the fixture still has the scroll extent the
    // rest-below-chrome assertion needs (a 2200 surface swallows the whole
    // trip: maxScrollExtent 0, nothing can scroll). 900 rather than the
    // old 1100: the in-flow map row moved Rome's reveal offset ~300 lower,
    // and at 1100 the scroll clamped at maxScrollExtent ~134px short of
    // the slot.
    _useSurface(tester, const Size(1200, 900));
    await _pump(tester, _threeCityTrip());

    await collapseCity(tester, 'Rome');
    expect(find.text('Roman Forum 0'), findsNothing);
    expect(_map(tester).fitSignature, isNull);

    // A region pin on the All overview reads as "take me there in the
    // LIST" (invoked directly — the robust pattern at this level; the
    // trip_map suite covers real taps): un-collapse + scroll, with NO
    // focus write — focusing would swap the map to per-item pins and
    // delete the very pins under the pointer.
    _map(tester).onDestinationTap!('Rome');
    await tester.pumpAndSettle();

    expect(find.text('Roman Forum 0'), findsOneWidget,
        reason: 'the region tap re-opens its collapsed group');
    // The rest slot is the pinned tab row alone (the band scrolled away
    // with the page), ±2 for the one correction pass.
    final slot = _pinnedSlot(tester);
    final headerTop = tester
        .getTopLeft(find
            .ancestor(
                of: cityHeaderLabel('Rome'), matching: find.byType(Material))
            .first)
        .dy;
    expect((headerTop - slot).abs(), lessThanOrEqualTo(2),
        reason: 'Rome header should rest below the pinned tab row');
    final position = tester
        .state<ScrollableState>(find
            .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable))
            .first)
        .position;
    expect(position.pixels, greaterThan(0));
    // The landed page has scrolled the in-flow map row out of the build —
    // return to the top to read the map's state (focus lives in notifiers,
    // so it survives the card unmounting).
    position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(_map(tester).fitSignature, isNull,
        reason: 'a region tap never moves the camera');
  });

  testWidgets('a pin tap while a leg is focused keeps the camera and selection',
      (tester) async {
    _useSurface(tester, const Size(1200, 2200));
    await _pump(tester, _threeCityTrip());

    // Focus Rome, then tap a Rome pin: keepCamera must be a no-op on the
    // focus (a focused map already renders only that leg's pins), so the
    // camera stays on Rome AND the selection is NOT cleared — the pin-tap
    // camera invariant.
    await _tapChip(tester, 'Rome');
    expect(_map(tester).fitSignature, 'Rome');

    _map(tester).onPinTap!(3);
    await tester.pumpAndSettle();
    expect(_map(tester).fitSignature, 'Rome', reason: 'camera must not refit');
    expect(_map(tester).selectedPosition, 3,
        reason: 'keepCamera must not clear the selection');
    // Rome's rows stay in place (a pin tap never collapses anything).
    expect(find.text('Roman Forum 1'), findsWidgets);
  });

  testWidgets('bookings lens: a chip tap filters the map and keeps the lens',
      (tester) async {
    _useSurface(tester, const Size(1200, 800));
    await _pump(tester, _threeCityTrip());

    // Enter the Bookings view (header tab; the trip has no todos, so the
    // label carries no count): the city groups leave the tree.
    await tester.tap(find.text('Bookings'));
    await tester.pumpAndSettle();
    expect(cityHeaderLabel('Paris'), findsNothing);

    // The chip still drives the map — and does NOT exit the lens.
    await _tapChip(tester, 'Rome');
    expect(_map(tester).fitSignature, 'Rome');
    expect(_map(tester).items, hasLength(8));
    expect(cityHeaderLabel('Paris'), findsNothing,
        reason: 'a map chip must not exit the bookings lens');
  });

  testWidgets('revisited city: each chip run focuses its own leg',
      (tester) async {
    _useSurface(tester, const Size(1200, 2200));
    await _pump(
      tester,
      Trip(
        id: 't1',
        title: 'Paris twice',
        createdAt: '2037-06-01',
        updatedAt: '2037-06-01',
        startDate: '2037-09-01',
        endDate: '2037-09-03',
        items: [
          _item(0, 'Louvre', 'Paris', 48.8606, 2.3376, 1),
          _item(1, 'Colosseum', 'Rome', 41.8902, 12.4922, 2),
          _item(2, 'Marmottan', 'Paris', 48.8592, 2.2670, 3),
        ],
      ),
    );

    // Header taps no longer focus, so the two same-label Paris CHIPS drive
    // per-run focus. The second chip focuses the SECOND run only.
    final parisChips = find.descendant(
        of: find.byType(MapLegChips), matching: find.text('Paris'));
    await tester.tap(parisChips.at(1));
    await tester.pumpAndSettle();
    expect(_map(tester).fitSignature, 'Paris#2');
    expect(_map(tester).items.map((i) => i.name), ['Marmottan']);

    // And the first run stays its own focus target.
    await tester.tap(parisChips.at(0));
    await tester.pumpAndSettle();
    expect(_map(tester).fitSignature, 'Paris');
    expect(_map(tester).items.map((i) => i.name), ['Louvre']);
  });

testWidgets('adding a place focuses the added city on the map',
      (tester) async {
    _useSurface(tester, const Size(1200, 2200));
    final v1 = _threeCityTrip();
    // v2 inserts a fresh Rome item (consecutive with the existing Rome run,
    // so it stays leg 'Rome'), Berlin shifted after it.
    final v2 = Trip(
      id: 't1',
      title: 'Grand tour',
      createdAt: '2037-06-01',
      updatedAt: '2037-06-01',
      startDate: '2037-09-01',
      endDate: '2037-09-05',
      items: [
        _item(0, 'Louvre', 'Paris', 48.8606, 2.3376, 1),
        _item(1, 'Orsay', 'Paris', 48.8600, 2.3266, 2),
        for (var k = 0; k < 8; k++)
          _item(2 + k, 'Roman Forum $k', 'Rome', 41.89 + k * 0.001, 12.49, 3),
        // Fresh item: a unique id (NOT position-derived, which would collide
        // with v1's Berlin id 'i10'); consecutive with Rome so it stays
        // leg 'Rome'.
        const ItineraryItem(
          id: 'fresh-trevi',
          position: 10,
          name: 'Trevi Fountain',
          latitude: 41.9009,
          longitude: 12.4833,
          category: 'attraction',
          day: 3,
          city: 'Rome',
        ),
        // Berlin keeps its v1 id ('i10') so it is NOT seen as fresh; only
        // the position shifts.
        const ItineraryItem(
          id: 'i10',
          position: 11,
          name: 'Brandenburg Gate',
          latitude: 52.5163,
          longitude: 13.3777,
          category: 'attraction',
          day: 4,
          city: 'Berlin',
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider
              .overrideWithValue(_AddingTripsApiService(v1, v2)),
        ],
        child: MaterialApp(
            localizationsDelegates: testLocalizationsDelegates,
            home: TripDetailScreen(tripId: 't1')),
      ),
    );
    await tester.pumpAndSettle();

    // Focus Paris first, so the add provably REfocuses the map (the item
    // lands in Rome).
    await _tapChip(tester, 'Paris');
    expect(_map(tester).fitSignature, 'Paris');
    expect(find.text('Louvre'), findsOneWidget);

    // Header "Add place" → manual entry → name → Add.
    await tester.tap(find.text('Add place'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Can't find it? Add manually"));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Place name').first, 'Trevi Fountain');
    await tester.tap(
        find.descendant(of: find.byType(AlertDialog), matching: find.text('Add')));
    await tester.pumpAndSettle();

    // The new item's leg (Rome) is now focused so the fresh pin is visible;
    // Paris stays expanded — expansion is not the map's state, so a focus
    // change collapses nothing.
    expect(_map(tester).fitSignature, 'Rome');
    expect(find.text('Trevi Fountain'), findsWidgets);
    expect(find.text('Louvre'), findsOneWidget,
        reason: 'a focus change must not collapse any group');
  });

  testWidgets('single-leg trip: no chip strip, header taps never focus',
      (tester) async {
    _useSurface(tester, const Size(1200, 800));
    await _pump(
      tester,
      Trip(
        id: 't1',
        title: 'Just Paris',
        createdAt: '2037-06-01',
        updatedAt: '2037-06-01',
        startDate: '2037-09-01',
        endDate: '2037-09-03',
        items: [
          _item(0, 'Louvre', 'Paris', 48.8606, 2.3376, 1),
          _item(1, 'Orsay', 'Paris', 48.8600, 2.3266, 2),
        ],
      ),
    );

    // The strip renders nothing below two legs.
    expect(
      find.descendant(
          of: find.byType(MapLegChips), matching: find.byType(ChoiceChip)),
      findsNothing,
    );

    // The sole group lands expanded like every other; toggling it never
    // writes focus — with one leg, the overview and the leg are the same map,
    // and a fit bump would snap a user-panned camera for no visible
    // change. The LIST still toggles through the same pure-toggle path
    // every header tap takes.
    expect(find.text('Louvre'), findsOneWidget); // expanded by default
    await collapseCity(tester, 'Paris');
    expect(_map(tester).fitSignature, isNull);
    expect(find.text('Louvre'), findsNothing, reason: 'list collapsed');
    await toggleCity(tester, 'Paris'); // expand again
    expect(_map(tester).fitSignature, isNull);
    expect(find.text('Louvre'), findsOneWidget, reason: 'list reopened');
  });
}
