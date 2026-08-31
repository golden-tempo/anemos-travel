import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/l10n/l10n.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/booking_todos_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/booking_todos_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/utils/date_formats.dart';

import 'support/chip_finders.dart';
import 'support/city_groups.dart';
import 'support/l10n_test_app.dart';

/// Returns a fixed trip without hitting the network, so we can exercise the
/// real TripDetailScreen render path (and its booking-todo derivation).
class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// getTrip answers from a queue, so a pull-to-refresh can deliver a
/// DIFFERENT trip (the re-measure-on-refresh test).
class _QueuedTripsApiService extends TripsApiService {
  final List<Trip> responses;
  int calls = 0;
  _QueuedTripsApiService(this.responses)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async {
    final next =
        responses[calls < responses.length ? calls : responses.length - 1];
    calls++;
    return next;
  }
}

/// Swallows the derived-payload sync like the offline test env.
class _FakeBookingTodosApiService extends BookingTodosApiService {
  _FakeBookingTodosApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<BookingTodo>> syncTodos(
          String tripId, List<Map<String, dynamic>> derived) async =>
      throw Exception('offline test env');
}

ItineraryItem _item(int pos, String name, String city, {int? day}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: '$city address',
      // Zero coords so the screen skips the map widget in the test env.
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

Future<void> _pump(WidgetTester tester, Trip trip, {Locale? locale}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        bookingTodosApiServiceProvider
            .overrideWithValue(_FakeBookingTodosApiService()),
      ],
      child: localizedTestApp(
        home: TripDetailScreen(tripId: 't1'),
        locale: locale,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Calendar-day anchor for every fixture trip below: tonight + 7, so the
/// trip is always UPCOMING. The fixed Aug/Sep 2026 windows went red the week
/// the calendar crossed them (#579 all over again: #576 folds departed cities
/// by DateTime.now(), and a city whose days are all past renders nothing like
/// the expanded group these tests pin). Offsets from the anchor keep each
/// fixture's original leg structure — day numbers and night counts are
/// unchanged, only the absolute dates moved.
final _anchor = DateUtils.dateOnly(DateTime.now()).add(const Duration(days: 7));

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// The city-header chip's range text for a leg running [from]–[to] days after
/// [_anchor] — computed with the same helper the chip renders through.
String _range(int from, int to) => formatShortRange(
    _anchor.add(Duration(days: from)), _anchor.add(Duration(days: to)));

/// A bare single-date chip (the zero-night squeeze), [offset] days after
/// [_anchor].
String _chipDate(int offset) => mmmd().format(_anchor.add(Duration(days: offset)));

/// Prague day 1, Kraków day 4 — the canonical example the feature was asked
/// for. Day numbers encode each city's ARRIVAL: a leg runs until the next
/// leg's first item day (specs/leg-departure-dates), with the last leg
/// carried to the trip end. Prague gets 3 nights, Kraków 5.
Trip _pragueKrakowTrip() => Trip(
      id: 't1',
      title: 'Big Summer',
      startDate: _iso(_anchor),
      endDate: _iso(_anchor.add(const Duration(days: 8))),
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: [
        _item(0, 'Prague', 'Prague', day: 1),
        _item(1, 'Kraków', 'Kraków', day: 4),
      ],
    );

/// [_pragueKrakowTrip] with Kraków run to day 20 (16 nights) plus Vienna for
/// the trip's last 2 nights. Kraków's chip is the strict widest (26 glyphs
/// under the uniform-advance test font vs 25 for the others), so a regression
/// to per-row intrinsic widths misaligns its row against the other two, and
/// the shared width here is one glyph wider than [_pragueKrakowTrip]'s — the
/// re-measure-on-refresh test depends on that inequality.
Trip _threeCityTrip() => Trip(
      id: 't1',
      title: 'Big Summer',
      startDate: _iso(_anchor),
      endDate: _iso(_anchor.add(const Duration(days: 21))),
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: [
        _item(0, 'Prague', 'Prague', day: 1),
        _item(1, 'Kraków', 'Kraków', day: 4),
        _item(2, 'Vienna', 'Vienna', day: 20),
      ],
    );

/// Quito shares Galápagos's day-6 arrival — a genuine zero-night leg
/// (specs/leg-departure-dates) with a bare single-date chip between two
/// counted legs.
Trip _squeezeTrip() => Trip(
      id: 't1',
      title: 'Squeeze',
      startDate: _iso(_anchor),
      endDate: _iso(_anchor.add(const Duration(days: 6))),
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: [
        _item(0, 'Museo', 'Medellín', day: 1),
        _item(1, 'Comuna 13', 'Medellín', day: 6),
        _item(2, 'Quito', 'Quito', day: 6),
        _item(3, 'Mitad del Mundo', 'Galápagos', day: 6),
        _item(4, 'Tortuga Bay', 'Galápagos', day: 7),
      ],
    );

/// Prague plus an item whose locality can't be resolved — the 'Other places'
/// group, whose header has no refine sparkle to align against. Its day-4
/// arrival ends Prague at day 3 and the last-leg anchor runs it to the trip
/// end (5 nights).
Trip _pragueMysteryTrip() => Trip(
      id: 't1',
      title: 'Big Summer',
      startDate: _iso(_anchor),
      endDate: _iso(_anchor.add(const Duration(days: 8))),
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: [
        _item(0, 'Prague', 'Prague', day: 1),
        // No city AND no address: cityOf falls back to parsing the address,
        // so only a fully unlocatable item lands in 'Other places'.
        ItineraryItem(
          id: 'i1',
          position: 1,
          name: 'Mystery beach',
          latitude: 0,
          longitude: 0,
          category: 'attraction',
          day: 4,
        ),
      ],
    );

/// Left x of the chip's calendar icon in a city's header row.
double _eventIconX(WidgetTester tester, String cityLabel) => tester
    .getTopLeft(find.descendant(
        of: headerRowOf(cityLabel), matching: find.byIcon(Icons.event)))
    .dx;

/// Shrinks text so the shared chip width is intrinsic-driven. Under the
/// square test font every realistic chip exceeds the 200px pathological cap,
/// where per-row (broken) and shared (correct) widths are geometrically
/// identical and alignment assertions would pass vacuously. This also
/// exercises the textScaler-aware measurement path in _dateChipWidth.
void _shrinkText(WidgetTester tester) {
  tester.platformDispatcher.textScaleFactorTestValue = 0.4;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

void main() {
  testWidgets('city headers carry a night count next to the date range',
      (WidgetTester tester) async {
    await _pump(tester, _pragueKrakowTrip());

    // Scoped per row: the count must sit in the SAME chip as its range.
    expect(chipTextIn('Prague', _range(0, 3)), findsOneWidget);
    expect(chipTextIn('Prague', '· 3 nights'), findsOneWidget);
    expect(chipTextIn('Kraków', _range(3, 8)), findsOneWidget);
    expect(chipTextIn('Kraków', '· 5 nights'), findsOneWidget);
  });

  testWidgets('a squeezed zero-night leg keeps its bare single-date chip',
      (WidgetTester tester) async {
    // No "0 nights" noise on the squeezed Quito leg, while the following
    // Galápagos leg still gets its counter.
    await _pump(tester, _squeezeTrip());

    expect(chipTextIn('Quito', _chipDate(5)), findsOneWidget);
    expect(find.textContaining('0 nights'), findsNothing);
    expect(chipTextIn('Galápagos', _range(5, 6)), findsOneWidget);
    expect(chipTextIn('Galápagos', '· 1 night'), findsOneWidget);
  });

  testWidgets('night counts pluralize in Spanish',
      (WidgetTester tester) async {
    // Only the nights half is pinned: the date half comes from
    // DateFormat.MMMd(), which reads Intl.defaultLocale (English in the
    // test env) rather than the widget locale.
    await _pump(tester, _pragueKrakowTrip(), locale: const Locale('es'));

    expect(find.textContaining('3 noches'), findsOneWidget);
    expect(find.textContaining('5 noches'), findsOneWidget);
  });

  testWidgets('date chips sit flush right with aligned chevrons',
      (WidgetTester tester) async {
    // Regression: wrapping the chip in Flexible gave the header Row two
    // flex children, so the label's Expanded only claimed half the free
    // space and the chip+chevron cluster drifted left by a per-row amount.
    // The chevron must end exactly where its Row ends, on every row.
    await _pump(tester, _pragueKrakowTrip());

    double chevronRightIn(String city) {
      final row = headerRowOf(city);
      // Groups land expanded, so the header chevron is expand_more (a
      // collapsed row would show chevron_right); geometry is the same slot.
      final chevron = find.descendant(
          of: row, matching: find.byIcon(Icons.expand_more));
      expect(chevron, findsOneWidget);
      expect(
        tester.getTopRight(chevron).dx,
        moreOrLessEquals(tester.getTopRight(row).dx, epsilon: 0.1),
        reason: 'chevron of "$city" must be flush with its row end',
      );
      return tester.getTopRight(chevron).dx;
    }

    final prague = chevronRightIn('Prague');
    final krakow = chevronRightIn('Kraków');
    expect(prague, moreOrLessEquals(krakow, epsilon: 0.1),
        reason: 'chevrons must align across rows');
  });

  testWidgets('phone width: the city name gets the row, dates go beneath it',
      (WidgetTester tester) async {
    // The regression this pass exists to kill: the chip is rigid and the
    // label's Expanded is the only flex child, so on a phone the chip took
    // its measured width first and "Prague" rendered as "Pra…". The test font
    // renders every glyph as a full-size square, so the squeeze here is
    // harsher than any real font — if the name survives this, it survives.
    await tester.binding.setSurfaceSize(const Size(375, 667));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _pragueKrakowTrip());

    // The dates still belong to Prague's header (chipTextIn scopes to the
    // row), but they now sit on a SECOND line under the name.
    final name = cityHeaderLabel('Prague');
    final dates = chipTextIn('Prague', _range(0, 3));
    expect(dates, findsOneWidget);
    expect(chipTextIn('Prague', '· 3 nights'), findsOneWidget);
    expect(
      tester.getTopLeft(dates).dy,
      greaterThan(tester.getTopLeft(name).dy),
      reason: 'the date range must stack BELOW the city name on a phone',
    );

    // The name is not truncated: it paints its full intrinsic width. A
    // regression to the one-line layout clamps this well under it.
    final painted = tester.getSize(name).width;
    final intrinsic = (tester.renderObject(name) as RenderParagraph)
        .getMaxIntrinsicWidth(double.infinity);
    expect(painted, moreOrLessEquals(intrinsic, epsilon: 0.5),
        reason: '"Prague" must render whole, never ellipsized, at 375px');

    // And the row still ends where it always did.
    final row = headerRowOf('Prague');
    // expand_more: groups land expanded (see the chevron test above).
    final chevron = find.descendant(
        of: row, matching: find.byIcon(Icons.expand_more));
    expect(
      tester.getTopRight(chevron).dx,
      moreOrLessEquals(tester.getTopRight(row).dx, epsilon: 0.1),
      reason: 'chevron must stay flush with the row end at phone width',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone width: no calendar chip icon, and no ghost refine slot',
      (WidgetTester tester) async {
    // The chip's Icons.event is gone with the chip; the pin above the second
    // line is the row's only anchor. And 'Other places' no longer holds an
    // invisible ~40px IconButton — that placeholder exists to keep the chip
    // columns aligned, and narrow has no columns to keep. (The wide twin of
    // this test, below, asserts the opposite on both counts.)
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _pragueMysteryTrip());

    expect(find.descendant(
            of: headerRowOf('Prague'), matching: find.byIcon(Icons.event)),
        findsNothing);

    final ghosts = find.descendant(
        of: headerRowOf('Other places'),
        matching: find.widgetWithIcon(IconButton, Icons.auto_awesome));
    expect(ghosts, findsNothing,
        reason: "'Other places' must not reserve a refine slot on a phone");
    // The real button still renders on a city that HAS a hub.
    expect(
        find.descendant(
            of: headerRowOf('Prague'),
            matching: find.widgetWithIcon(IconButton, Icons.auto_awesome)),
        findsOneWidget);
  });

  testWidgets('chip columns align across rows', (WidgetTester tester) async {
    // The point of the shared chip width: calendar icons, range starts, and
    // nights suffixes each form a column across header rows even though the
    // strings differ in length per row.
    _shrinkText(tester);
    await _pump(tester, _threeCityTrip());

    final iconX = _eventIconX(tester, 'Prague');
    expect(_eventIconX(tester, 'Kraków'),
        moreOrLessEquals(iconX, epsilon: 0.1),
        reason: 'calendar icons must form a column');
    expect(_eventIconX(tester, 'Vienna'),
        moreOrLessEquals(iconX, epsilon: 0.1),
        reason: 'calendar icons must form a column');

    final rangeX = tester.getTopLeft(find.text(_range(0, 3))).dx;
    expect(tester.getTopLeft(find.text(_range(3, 19))).dx,
        moreOrLessEquals(rangeX, epsilon: 0.1),
        reason: 'range starts must form a column');
    expect(tester.getTopLeft(find.text(_range(19, 21))).dx,
        moreOrLessEquals(rangeX, epsilon: 0.1),
        reason: 'range starts must form a column');

    final nightsRight = tester.getTopRight(find.text('· 3 nights')).dx;
    expect(tester.getTopRight(find.text('· 16 nights')).dx,
        moreOrLessEquals(nightsRight, epsilon: 0.1),
        reason: 'nights suffixes must share a right edge');
    expect(tester.getTopRight(find.text('· 2 nights')).dx,
        moreOrLessEquals(nightsRight, epsilon: 0.1),
        reason: 'nights suffixes must share a right edge');
  });

  testWidgets('a refresh that widens the longest chip re-measures the width',
      (WidgetTester tester) async {
    // Pins the W-is-a-build-local invariant (_dateChipWidth doc): a
    // State-cached width would survive a silent refresh that changes the
    // legs (a set_leg_dates refine), leaving stale columns until remount.
    _shrinkText(tester);
    final service =
        _QueuedTripsApiService([_pragueKrakowTrip(), _threeCityTrip()]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider.overrideWithValue(service),
          bookingTodosApiServiceProvider
              .overrideWithValue(_FakeBookingTodosApiService()),
        ],
        child: localizedTestApp(home: TripDetailScreen(tripId: 't1')),
      ),
    );
    await tester.pumpAndSettle();
    final iconXBefore = _eventIconX(tester, 'Prague');

    // Pull-to-refresh delivers _threeCityTrip, whose widest chip (Kraków)
    // is one glyph wider than the widest before.
    await tester.fling(
        find.byType(CustomScrollView), const Offset(0, 400), 1000);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(service.calls, greaterThan(1));

    // The mutation-killing inequality: the whole column must move left for
    // the wider chip. A cached width leaves iconX unchanged.
    final iconXAfter = _eventIconX(tester, 'Prague');
    expect(iconXAfter, lessThan(iconXBefore - 1),
        reason: 'shared width must be re-measured for the wider chip');

    // And the columns re-form at the new width.
    expect(_eventIconX(tester, 'Kraków'),
        moreOrLessEquals(iconXAfter, epsilon: 0.1));
    expect(_eventIconX(tester, 'Vienna'),
        moreOrLessEquals(iconXAfter, epsilon: 0.1));
    expect(tester.getTopRight(find.text('· 16 nights')).dx,
        moreOrLessEquals(tester.getTopRight(find.text('· 3 nights')).dx,
            epsilon: 0.1));
  });

  testWidgets('columns hold under the boldText accessibility flag',
      (WidgetTester tester) async {
    // Text applies boldText internally; _dateChipWidth merges it into the
    // measured style. Exercises that branch end-to-end: columns must still
    // form and nothing may overflow (an undershoot surfaces as a RenderFlex
    // exception in this harness).
    _shrinkText(tester);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(boldText: true);
    addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _pump(tester, _threeCityTrip());

    final iconX = _eventIconX(tester, 'Prague');
    expect(_eventIconX(tester, 'Kraków'),
        moreOrLessEquals(iconX, epsilon: 0.1));
    expect(_eventIconX(tester, 'Vienna'),
        moreOrLessEquals(iconX, epsilon: 0.1));
  });

  testWidgets('zero-night bare chip joins the icon column, with no nights text',
      (WidgetTester tester) async {
    _shrinkText(tester);
    await _pump(tester, _squeezeTrip());

    final iconX = _eventIconX(tester, 'Medellín');
    expect(_eventIconX(tester, 'Quito'),
        moreOrLessEquals(iconX, epsilon: 0.1),
        reason: 'the bare-date chip must keep the icon column');
    expect(_eventIconX(tester, 'Galápagos'),
        moreOrLessEquals(iconX, epsilon: 0.1),
        reason: 'the bare-date chip must keep the icon column');

    // The squeezed row renders the bare date only — no nights widget exists.
    expect(
        find.descendant(
            of: headerRowOf('Quito'), matching: find.textContaining('night')),
        findsNothing);
  });

  testWidgets("'Other places' keeps the columns without a refine sparkle",
      (WidgetTester tester) async {
    // That header has no refine button; it reserves an invisible
    // width-identical slot so its chip cluster can't sit a button-slot right
    // of the other rows.
    _shrinkText(tester);
    await _pump(tester, _pragueMysteryTrip());

    expect(_eventIconX(tester, 'Other places'),
        moreOrLessEquals(_eventIconX(tester, 'Prague'), epsilon: 0.1),
        reason: "the 'Other places' chip must keep the icon column");
    expect(tester.getTopRight(find.text('· 5 nights')).dx,
        moreOrLessEquals(tester.getTopRight(find.text('· 3 nights')).dx,
            epsilon: 0.1),
        reason: "the 'Other places' nights suffix must share the right edge");

    // The phantom slot is width-only. Scoped to the two header rows: with
    // groups expanded by default the day sub-headers mount too, and their
    // own live refine buttons would alias a global count.
    Iterable<IconButton> refinesIn(String city) =>
        tester.widgetList<IconButton>(find.descendant(
            of: headerRowOf(city),
            matching: find.widgetWithIcon(IconButton, Icons.auto_awesome)));
    expect(refinesIn('Prague').where((b) => b.onPressed != null).length, 1,
        reason: 'the real city header keeps its live refine button');
    final other = refinesIn('Other places').toList();
    expect(other.length, 1,
        reason: "the 'Other places' slot must exist (width-identical)");
    expect(other.single.onPressed, isNull,
        reason: 'the Other-places placeholder must stay inert');
  });

  // The only tests that pin the separator and order — if the format ever
  // changes, the ARB lines and these literals are the whole diff.
  test('message-level plural forms in en and es', () async {
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    expect(en.tripLegNights(1), '· 1 night');
    expect(en.tripLegNights(3), '· 3 nights');

    final es = await AppLocalizations.delegate.load(const Locale('es'));
    expect(es.tripLegNights(1), '· 1 noche');
    expect(es.tripLegNights(5), '· 5 noches');
  });
}
