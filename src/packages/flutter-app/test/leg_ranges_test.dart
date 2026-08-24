import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/utils/leg_ranges.dart';

// CROSS-LANGUAGE CONTRACT (specs/trip-dates-truth): these fixtures and
// expected values are hand-mirrored in the Go twin suite
// (api/trip_render_legs_test.go, stage 0b) — same trips, same expected
// spans, city names and all. Pinning both sides to the same literals means a
// drift on either side fails a test instead of shipping silently (the
// calendar-title parity convention). Divergences that are DELIBERATE are
// marked "diverges:" below with the decision.

ItineraryItem _item(int pos, String name, String? city, {int? day}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: city == null ? null : '$city address',
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

Trip _trip(
  List<ItineraryItem> items, {
  String? startDate,
  String? endDate,
  List<Accommodation>? stays,
}) =>
    Trip(
      id: 't1',
      title: 'Fixture',
      startDate: startDate,
      endDate: endDate,
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      items: items,
      accommodations: stays,
    );

DateTime _d(String iso) => DateTime.parse(iso);

void main() {
  group('rawLegRanges', () {
    test('item-day ranges anchored to the trip start', () {
      final ranges = rawLegRanges(_trip(
        [
          _item(0, 'Feskekôrka', 'Gothenburg', day: 1),
          _item(1, 'Liseberg', 'Gothenburg', day: 3),
          _item(2, 'Prado', 'Madrid', day: 5),
        ],
        startDate: '2026-08-24',
        endDate: '2026-08-28',
      ));
      expect(ranges.length, 2);
      expect(ranges[0].start, _d('2026-08-24'));
      expect(ranges[0].end, _d('2026-08-26'));
      // Madrid's raw range collapses to its single item day — the visible
      // pass, not this one, pulls its start back to the arrival.
      expect(ranges[1].start, _d('2026-08-28'));
      expect(ranges[1].end, _d('2026-08-28'));
      expect(ranges[1].stayAnchored, isFalse);
    });

    test('first leg anchors to the trip start when items sit late', () {
      final ranges = rawLegRanges(_trip(
        [
          _item(0, 'Prague', 'Prague', day: 4),
          _item(1, 'Kraków', 'Kraków', day: 9),
        ],
        startDate: '2026-08-24',
        endDate: '2026-09-01',
      ));
      expect(ranges[0].start, _d('2026-08-24'));
      expect(ranges[0].end, _d('2026-08-27'));
    });

    test('a confirmed stay overrides item days and sets stayAnchored', () {
      final ranges = rawLegRanges(_trip(
        [
          _item(0, 'Museo', 'Medellín', day: 1),
          _item(1, 'Quito', 'Quito', day: 5),
        ],
        startDate: '2026-09-01',
        endDate: '2026-09-07',
        stays: const [
          Accommodation(
            id: 'a1',
            name: 'Hotel Quito',
            address: 'Av. González Suárez, Quito, Ecuador',
            checkIn: '2026-09-03',
            checkOut: '2026-09-05',
          ),
        ],
      ));
      expect(ranges[1].start, _d('2026-09-03'));
      expect(ranges[1].end, _d('2026-09-05'));
      expect(ranges[1].stayAnchored, isTrue);
    });

    // diverges: stay matching is address-only client-side today; the Go twin
    // also matches by NAME (agent-added stays carry no address). The unified
    // rule after the payload cutover is address-then-name — this pin
    // documents the pre-cutover client behavior.
    test('an address-less stay does not anchor (client rule, pre-cutover)',
        () {
      final ranges = rawLegRanges(_trip(
        [_item(0, 'Quito', 'Quito', day: 3)],
        startDate: '2026-09-01',
        endDate: '2026-09-05',
        stays: const [
          Accommodation(
            id: 'a1',
            name: 'Stay in Quito',
            checkIn: '2026-09-02',
            checkOut: '2026-09-04',
          ),
        ],
      ));
      expect(ranges[0].stayAnchored, isFalse);
      // First-leg anchor applies instead: start = trip start.
      expect(ranges[0].start, _d('2026-09-01'));
      expect(ranges[0].end, _d('2026-09-03'));
    });

    test('undated legs take the weighted auto-allocation slice', () {
      final ranges = rawLegRanges(_trip(
        [
          _item(0, 'Louvre', 'Paris'),
          _item(1, 'Orsay', 'Paris'),
          _item(2, 'Marais walk', 'Paris'),
          _item(3, 'Colosseum', 'Rome'),
        ],
        startDate: '2026-06-01',
        endDate: '2026-06-08', // 8 days: Paris (3 items) 6, Rome (1 item) 2
      ));
      expect(ranges[0].start, _d('2026-06-01'));
      expect(ranges[0].end, _d('2026-06-06'));
      expect(ranges[1].start, _d('2026-06-07'));
      expect(ranges[1].end, _d('2026-06-08'));
    });

    test('more locations than days maps each to one ascending day', () {
      final ranges = rawLegRanges(_trip(
        [
          _item(0, 'A', 'Alpha'),
          _item(1, 'B', 'Beta'),
          _item(2, 'C', 'Gamma'),
        ],
        startDate: '2026-06-01',
        endDate: '2026-06-02', // 2 days, 3 cities
      ));
      expect(ranges[0].start, _d('2026-06-01'));
      expect(ranges[1].start, _d('2026-06-01'));
      expect(ranges[2].start, _d('2026-06-02'));
      for (final r in ranges) {
        expect(r.start, r.end);
      }
    });

    test('a dateless trip yields null ranges', () {
      final ranges = rawLegRanges(_trip(
        [_item(0, 'Louvre', 'Paris', day: 1)],
      ));
      expect(ranges.single.start, isNull);
      expect(ranges.single.end, isNull);
    });
  });

  group('visibleLegRanges', () {
    test('the earlier leg runs until the next arrival', () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Feskekôrka', 'Gothenburg', day: 1),
          _item(1, 'Liseberg', 'Gothenburg', day: 3),
          _item(2, 'Prado', 'Madrid', day: 5),
        ],
        startDate: '2026-08-24',
        endDate: '2026-08-28',
      ));
      // Gothenburg's own last item day (Aug 26) sets nothing — its end is
      // Madrid's arrival; Madrid arrives the day the trip ends.
      expect(ranges[0].start, _d('2026-08-24'));
      expect(ranges[0].end, _d('2026-08-28'));
      expect(ranges[1].start, _d('2026-08-28'));
      expect(ranges[1].end, _d('2026-08-28'));
    });

    test('the first leg anchors to the trip start and runs to the arrival',
        () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Prague', 'Prague', day: 4),
          _item(1, 'Kraków', 'Kraków', day: 9),
        ],
        startDate: '2026-08-24',
        endDate: '2026-09-01',
      ));
      expect(ranges[0].start, _d('2026-08-24'));
      expect(ranges[0].end, _d('2026-09-01'));
      expect(ranges[1].start, _d('2026-09-01'));
      expect(ranges[1].end, _d('2026-09-01'));
    });

    // The out-of-order trip the old rule answered with a loud zero-night
    // collapse (Medellín's day-6 item read as a Sep 6 departure, Quito
    // squeezed to nothing). Every leg now runs to the next arrival; the
    // day-6 item strands outside Medellín's window and moves no leg.
    test('an out-of-order item strands; no leg collapses', () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Museo', 'Medellín', day: 1),
          _item(1, 'Comuna 13', 'Medellín', day: 6),
          _item(2, 'Quito', 'Quito', day: 5),
          _item(3, 'Mitad del Mundo', 'Galápagos', day: 6),
          _item(4, 'Tortuga Bay', 'Galápagos', day: 7),
        ],
        startDate: '2026-09-01',
        endDate: '2026-09-07',
      ));
      expect(ranges[0].start, _d('2026-09-01'));
      expect(ranges[0].end, _d('2026-09-05'));
      expect(ranges[1].start, _d('2026-09-05'));
      expect(ranges[1].end, _d('2026-09-06'));
      expect(ranges[2].start, _d('2026-09-06'));
      expect(ranges[2].end, _d('2026-09-07'));
    });

    test('cities sharing one arrival day pinch to zero-night stops', () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Museo', 'Medellín', day: 1),
          _item(1, 'Quito', 'Quito', day: 4),
          _item(2, 'Guayaquil', 'Guayaquil', day: 4),
          _item(3, 'Cartagena', 'Cartagena', day: 4),
        ],
        startDate: '2026-09-01',
        endDate: '2026-09-07',
      ));
      expect(ranges[0].start, _d('2026-09-01'));
      expect(ranges[0].end, _d('2026-09-04'));
      expect(ranges[1].start, _d('2026-09-04'));
      expect(ranges[1].end, _d('2026-09-04'));
      expect(ranges[2].start, _d('2026-09-04'));
      expect(ranges[2].end, _d('2026-09-04'));
      expect(ranges[3].start, _d('2026-09-04'));
      expect(ranges[3].end, _d('2026-09-07'));
    });

    // The tail case of the boundary rule: the planner leaves the day home
    // empty (it's a travel day), so the last leg's item-derived end falls
    // short of the trip's own end date. Amsterdam must still read
    // Aug 23 – Aug 25 · 2 nights — and Paris runs until Amsterdam's day-4
    // arrival, not its own last item day.
    test('the last leg runs through the trip end when its day home is empty',
        () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Louvre', 'Paris', day: 1),
          _item(1, "Musée d'Orsay", 'Paris', day: 2),
          _item(2, 'Rijksmuseum', 'Amsterdam', day: 4),
          _item(3, 'Anne Frank House', 'Amsterdam', day: 5),
          // Day 6 (Aug 25) is the journey home and carries nothing.
        ],
        startDate: '2026-08-20',
        endDate: '2026-08-25',
      ));
      expect(ranges[0].start, _d('2026-08-20'));
      expect(ranges[0].end, _d('2026-08-23'));
      expect(ranges[1].start, _d('2026-08-23'));
      expect(ranges[1].end, _d('2026-08-25'));
    });

    // A confirmed stay's dates are explicit on both ends: its check-in is the
    // arrival Paris extends to, and its checkout is never stretched to the
    // trip's Aug 25.
    test('the last-leg anchor leaves a confirmed stay alone', () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Louvre', 'Paris', day: 1),
          _item(1, 'Rijksmuseum', 'Amsterdam', day: 4),
        ],
        startDate: '2026-08-20',
        endDate: '2026-08-25',
        stays: const [
          Accommodation(
            id: 'a1',
            name: 'Hotel Pulitzer',
            address: 'Prinsengracht, Amsterdam',
            checkIn: '2026-08-23',
            checkOut: '2026-08-24',
          ),
        ],
      ));
      expect(ranges[0].start, _d('2026-08-20'));
      expect(ranges[0].end, _d('2026-08-23'));
      expect(ranges[1].start, _d('2026-08-23'));
      expect(ranges[1].end, _d('2026-08-24'));
    });

    // An item dated past the next city's arrival no longer widens its own leg
    // (the old rule read Medellín's day-6 item as a Sep 6 departure and
    // collapsed Quito to a zero-night stop). The item strands outside
    // Medellín's window and Quito keeps its nights.
    test('an item past the next arrival strands; the next leg keeps its nights',
        () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Museo', 'Medellín', day: 1),
          _item(1, 'Comuna 13', 'Medellín', day: 6),
          _item(2, 'Quito', 'Quito', day: 4),
        ],
        startDate: '2026-09-01',
        endDate: '2026-09-07',
      ));
      expect(ranges[0].start, _d('2026-09-01'));
      expect(ranges[0].end, _d('2026-09-04'));
      expect(ranges[1].start, _d('2026-09-04'));
      expect(ranges[1].end, _d('2026-09-07'));
    });

    // A confirmed stay's explicit dates hold against a neighbour's items:
    // Quito keeps Sep 3–5, and Medellín ends at that check-in (its day-6
    // item — dated inside the stay it contradicts — strands rather than
    // moving anything).
    test('a confirmed stay is never collapsed', () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Museo', 'Medellín', day: 1),
          _item(1, 'Comuna 13', 'Medellín', day: 6),
          _item(2, 'Quito', 'Quito', day: 5),
        ],
        startDate: '2026-09-01',
        endDate: '2026-09-07',
        stays: const [
          Accommodation(
            id: 'a1',
            name: 'Hotel Quito',
            address: 'Av. González Suárez, Quito, Ecuador',
            checkIn: '2026-09-03',
            checkOut: '2026-09-05',
          ),
        ],
      ));
      expect(ranges[0].start, _d('2026-09-01'));
      expect(ranges[0].end, _d('2026-09-03'));
      expect(ranges[1].start, _d('2026-09-03'));
      expect(ranges[1].end, _d('2026-09-05'));
    });

    // A gap AFTER a confirmed stay closes from the other side: the checkout
    // is explicit and cannot extend, so the next leg's start pulls back to it
    // — the one boundary that still resolves toward the earlier leg's end.
    test('a gap after a confirmed stay pulls the next leg back', () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Time Out Market', 'Lisbon', day: 1),
          _item(1, 'Livraria Lello', 'Porto', day: 7),
        ],
        startDate: '2026-09-01',
        endDate: '2026-09-08',
        stays: const [
          Accommodation(
            id: 'a1',
            name: 'Lisbon Loft',
            address: 'Alfama, Lisbon',
            checkIn: '2026-09-01',
            checkOut: '2026-09-05',
          ),
        ],
      ));
      expect(ranges[0].start, _d('2026-09-01'));
      expect(ranges[0].end, _d('2026-09-05'));
      expect(ranges[1].start, _d('2026-09-05'));
      expect(ranges[1].end, _d('2026-09-08'));
    });

    // A confirmed stay whose checkout runs past the next leg's arrival
    // renders as the overlap it is: both spans as stated, no collapse, no
    // invented dates. (The old chain collapsed the next leg to the checkout.)
    test('a stay overlapping the next arrival renders both as stated', () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Time Out Market', 'Lisbon', day: 1),
          _item(1, 'Livraria Lello', 'Porto', day: 3),
        ],
        startDate: '2026-09-01',
        endDate: '2026-09-08',
        stays: const [
          Accommodation(
            id: 'a1',
            name: 'Lisbon Loft',
            address: 'Alfama, Lisbon',
            checkIn: '2026-09-01',
            checkOut: '2026-09-05',
          ),
        ],
      ));
      expect(ranges[0].start, _d('2026-09-01'));
      expect(ranges[0].end, _d('2026-09-05'));
      expect(ranges[1].start, _d('2026-09-03'));
      expect(ranges[1].end, _d('2026-09-08'));
    });

    // Auto slices: Rome's slice starts Jun 7, so that is its arrival and
    // Paris runs to meet it (checkout-day semantics, like every other leg).
    test('auto-allocated legs share the later slice\'s first day', () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Louvre', 'Paris'),
          _item(1, 'Orsay', 'Paris'),
          _item(2, 'Marais walk', 'Paris'),
          _item(3, 'Colosseum', 'Rome'),
        ],
        startDate: '2026-06-01',
        endDate: '2026-06-08',
      ));
      expect(ranges[0].start, _d('2026-06-01'));
      expect(ranges[0].end, _d('2026-06-07'));
      expect(ranges[1].start, _d('2026-06-07'));
      expect(ranges[1].end, _d('2026-06-08'));
    });

    // More locations than days: Alpha and Beta share the Jun 1 arrival —
    // genuinely two cities in one day — so Alpha pinches to a zero-night
    // stop and Beta runs to Gamma's Jun 2 arrival.
    test('more locations than days pinches the shared-day legs', () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'A', 'Alpha'),
          _item(1, 'B', 'Beta'),
          _item(2, 'C', 'Gamma'),
        ],
        startDate: '2026-06-01',
        endDate: '2026-06-02',
      ));
      expect(ranges[0].start, _d('2026-06-01'));
      expect(ranges[0].end, _d('2026-06-01'));
      expect(ranges[1].start, _d('2026-06-01'));
      expect(ranges[1].end, _d('2026-06-02'));
      expect(ranges[2].start, _d('2026-06-02'));
      expect(ranges[2].end, _d('2026-06-02'));
    });

    // diverges: client-side a null-range leg still participates in the chain
    // (it adopts the previous end as its start, and its null end disables
    // adjustment downstream); the Go twin SKIPS spanless legs and closes the
    // boundary ACROSS them — there Alpha would run to Gamma's arrival. The
    // unified payload rule is the Go one; this pin documents the pre-cutover
    // client behavior so the cutover diff is deliberate.
    test('a dateless interior leg resets the chain (client rule, pre-cutover)',
        () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'A', 'Alpha', day: 1),
          _item(1, 'mystery', null),
          _item(2, 'C', 'Gamma', day: 5),
        ],
        startDate: '2026-06-01',
        // No end date: no auto-allocation, so the hubless leg has null range.
      ));
      expect(ranges.length, 3);
      // Chain break: Alpha cannot see an arrival past the null leg, so it
      // keeps its own end (the Go twin extends it to Jun 5).
      expect(ranges[0].end, _d('2026-06-01'));
      expect(ranges[1].start, _d('2026-06-01')); // adopts prev end...
      expect(ranges[1].end, isNull); // ...but its own end is null
      // Chain reset: Gamma keeps its raw start, un-adjusted.
      expect(ranges[2].start, _d('2026-06-05'));
    });
  });

  group('allocateDays', () {
    test('splits by weight with largest-remainder distribution', () {
      expect(allocateDays(8, [3, 1]), [6, 2]);
      expect(allocateDays(10, [1, 1, 1]), [4, 3, 3]);
    });

    test('floors at one day each and handles totalDays <= n', () {
      expect(allocateDays(2, [5, 5, 5]), [1, 1, 1]);
    });
  });

  // nightsBetween is a client-display helper only — deliberately NOT part of
  // the hand-mirrored Go-twin contract above; the legs payload carries no
  // nights field.
  group('nightsBetween', () {
    test('checkout-exclusive whole nights', () {
      expect(nightsBetween(DateTime(2026, 8, 24), DateTime(2026, 8, 27)), 3);
      expect(nightsBetween(DateTime(2026, 8, 27), DateTime(2026, 9, 1)), 5);
    });

    test('same day is zero nights', () {
      expect(nightsBetween(DateTime(2026, 9, 6), DateTime(2026, 9, 6)), 0);
    });

    test('DST spring-forward does not drop a night', () {
      // US DST starts Mar 8 2026; a raw local-midnight Duration diff reads
      // ~1.96 days and would truncate to 1.
      expect(nightsBetween(DateTime(2026, 3, 7), DateTime(2026, 3, 9)), 2);
    });
  });

  // MIRRORED from api/trip_render_legs_test.go (the calendar-parity
  // convention): same trip, same cities, same expected spans. Change either
  // side and you must change both.
  group('a spine itinerary (specs/shape-before-schedule)', () {
    // Two places a city — one on the day the traveler arrives, one on the day
    // they move on — except the last city, whose move-on day is the journey
    // home. Days 2-3, 5 and 7 carry nothing.
    Trip spine() => _trip(
          [
            _item(0, 'Time Out Market', 'Lisbon', day: 1),
            _item(1, 'Pastéis de Belém', 'Lisbon', day: 4),
            _item(2, 'Livraria Lello', 'Porto', day: 4),
            _item(3, 'Cais da Ribeira', 'Porto', day: 6),
            _item(4, 'Museo del Prado', 'Madrid', day: 6),
          ],
          startDate: '2026-09-01',
          endDate: '2026-09-08',
        );

    test('renders the same ranges a dense itinerary would', () {
      final ranges = visibleLegRanges(spine());
      expect(ranges.length, 3);
      expect(ranges[0].start, _d('2026-09-01'));
      expect(ranges[0].end, _d('2026-09-04'));
      expect(ranges[1].start, _d('2026-09-04'));
      expect(ranges[1].end, _d('2026-09-06'));
      // The last-leg anchor carries Madrid through the trip's end; its own
      // items stop on the day it was reached.
      expect(ranges[2].start, _d('2026-09-06'));
      expect(ranges[2].end, _d('2026-09-08'));
    });

    test('a one-city spine is one arrival place stretched by the trip end', () {
      final ranges = visibleLegRanges(_trip(
        [_item(0, 'Museo del Prado', 'Madrid', day: 1)],
        startDate: '2026-09-01',
        endDate: '2026-09-08',
      ));
      expect(ranges.single.start, _d('2026-09-01'));
      expect(ranges.single.end, _d('2026-09-08'));
    });

    // The same trip built from arrival anchors ALONE — no move-on places.
    // Under the boundary rule each leg runs to the next arrival, so this
    // renders byte-identical to the full spine above: the move-on place
    // stopped being load-bearing. (Before specs/leg-departure-dates this was
    // a characterization test pinning the collapse — Lisbon lost all three
    // nights to Porto.)
    test('arrival anchors alone render the full spine', () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Time Out Market', 'Lisbon', day: 1),
          _item(1, 'Livraria Lello', 'Porto', day: 4),
          _item(2, 'Museo del Prado', 'Madrid', day: 6),
        ],
        startDate: '2026-09-01',
        endDate: '2026-09-08',
      ));
      expect(ranges[0].start, _d('2026-09-01'));
      expect(ranges[0].end, _d('2026-09-04'));
      expect(ranges[1].start, _d('2026-09-04'));
      expect(ranges[1].end, _d('2026-09-06'));
      expect(ranges[2].start, _d('2026-09-06'));
      expect(ranges[2].end, _d('2026-09-08'));
    });
  });

  // MIRRORED from api/trip_render_legs_test.go: the reported shape
  // (specs/leg-departure-dates) and its variants. Same trips, same expected
  // spans — change either side and you must change both.
  group('a leg runs until the next city\'s arrival', () {
    // "move the items from Saturday to Friday": Prague's places sit on days
    // 3-5 and NOTHING sits on day 6, the Saturday the traveler flies. Prague's
    // end is Kraków's arrival, so it holds three nights with its last day
    // empty — the state the old derivation read as a Friday departure.
    test('the reported shape: an empty last day keeps its nights', () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Rijksmuseum', 'Amsterdam', day: 1),
          _item(1, 'Jordaan walk', 'Amsterdam', day: 3),
          _item(2, 'Old Town Square', 'Prague', day: 3),
          _item(3, 'Prague Castle', 'Prague', day: 4),
          _item(4, 'Charles Bridge Walk', 'Prague', day: 5),
          _item(5, 'Main Market Square', 'Kraków', day: 6),
          _item(6, 'Wawel Castle', 'Kraków', day: 7),
        ],
        startDate: '2026-08-24',
        endDate: '2026-08-31',
      ));
      expect(ranges[0].start, _d('2026-08-24'));
      expect(ranges[0].end, _d('2026-08-26'));
      expect(ranges[1].start, _d('2026-08-26'));
      expect(ranges[1].end, _d('2026-08-29')); // three nights, day 6 empty
      expect(ranges[2].start, _d('2026-08-29'));
      expect(ranges[2].end, _d('2026-08-31'));
    });

    // The travel day emptied (acceptance 2 and 3): the same trip WITH a place
    // on Prague's day 6 renders identical spans, so deleting that place — or
    // never inventing one — changes no city's dates.
    test('emptying the travel day changes no city\'s dates', () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Rijksmuseum', 'Amsterdam', day: 1),
          _item(1, 'Jordaan walk', 'Amsterdam', day: 3),
          _item(2, 'Old Town Square', 'Prague', day: 3),
          _item(3, 'Prague Castle', 'Prague', day: 4),
          _item(4, 'Charles Bridge Walk', 'Prague', day: 5),
          _item(5, 'Airport coffee', 'Prague', day: 6),
          _item(6, 'Main Market Square', 'Kraków', day: 6),
          _item(7, 'Wawel Castle', 'Kraków', day: 7),
        ],
        startDate: '2026-08-24',
        endDate: '2026-08-31',
      ));
      expect(ranges[0].start, _d('2026-08-24'));
      expect(ranges[0].end, _d('2026-08-26'));
      expect(ranges[1].start, _d('2026-08-26'));
      expect(ranges[1].end, _d('2026-08-29'));
      expect(ranges[2].start, _d('2026-08-29'));
      expect(ranges[2].end, _d('2026-08-31'));
    });

    // A multi-day gap belongs to the city the traveler is still in, not to a
    // city they haven't reached (the old chain dragged Porto back to day 2).
    test('a multi-day gap belongs to the earlier leg', () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Time Out Market', 'Lisbon', day: 1),
          _item(1, 'Alfama walk', 'Lisbon', day: 2),
          _item(2, 'Livraria Lello', 'Porto', day: 5),
        ],
        startDate: '2026-09-01',
        endDate: '2026-09-08',
      ));
      expect(ranges[0].start, _d('2026-09-01'));
      expect(ranges[0].end, _d('2026-09-05'));
      expect(ranges[1].start, _d('2026-09-05'));
      expect(ranges[1].end, _d('2026-09-08'));
    });

    // The convention's shared transition day still renders identically: a
    // place on the move-on morning stops being load-bearing, not valid.
    test('a shared transition day renders unchanged', () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Rijksmuseum', 'Amsterdam', day: 1),
          _item(1, 'Jordaan walk', 'Amsterdam', day: 3),
          _item(2, 'Old Town Square', 'Prague', day: 3),
          _item(3, 'Charles Bridge Walk', 'Prague', day: 6),
        ],
        startDate: '2026-08-24',
        endDate: '2026-08-29',
      ));
      expect(ranges[0].start, _d('2026-08-24'));
      expect(ranges[0].end, _d('2026-08-26'));
      expect(ranges[1].start, _d('2026-08-26'));
      expect(ranges[1].end, _d('2026-08-29'));
    });

    // A genuine revisit keeps three runs with correct boundaries — a hub in
    // two runs is not corruption, and each run's arrival is its own first
    // item day.
    test('a revisit keeps three runs with correct boundaries', () {
      final ranges = visibleLegRanges(_trip(
        [
          _item(0, 'Louvre', 'Paris', day: 1),
          _item(1, 'Orsay', 'Paris', day: 2),
          _item(2, 'Colosseum', 'Rome', day: 3),
          _item(3, 'Trastevere', 'Rome', day: 5),
          _item(4, 'Marais walk', 'Paris', day: 6),
          _item(5, 'Montmartre', 'Paris', day: 7),
        ],
        startDate: '2026-06-01',
        endDate: '2026-06-08',
      ));
      expect(ranges.length, 3);
      expect(ranges[0].start, _d('2026-06-01'));
      expect(ranges[0].end, _d('2026-06-03'));
      expect(ranges[1].start, _d('2026-06-03'));
      expect(ranges[1].end, _d('2026-06-06'));
      expect(ranges[2].start, _d('2026-06-06'));
      expect(ranges[2].end, _d('2026-06-08'));
    });
  });
}
