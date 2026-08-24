// The client-side leg DATE-RANGE derivation: the calendar span each city leg
// occupies, raw ([rawLegRanges]) and as rendered ([visibleLegRanges]).
// Extracted verbatim from trip_detail_screen.dart (specs/trip-dates-truth,
// stage 0a) so the trip screen, its booking-todo derivation, and the upcoming
// Go twin (trip_render_legs.go) share one testable definition.
//
// Pure like trip_legs.dart / trip_days.dart: no widget/l10n imports. The
// server mirrors [visibleLegRanges] in visibleLegDisplayRange
// (plan_leg_dates.go) today and in the trip_render_legs.go module once the
// legs payload ships — the twin tests hand-mirror this file's fixtures.

import '../models/accommodation.dart';
import '../models/itinerary_item.dart';
import '../models/trip.dart';
import 'trip_legs.dart';

/// One leg's date range. [stayAnchored] marks a range taken from a confirmed
/// accommodation's explicit dates, which exempts the leg from the
/// visible-range zero-night collapse. [itemDerived] marks one computed from
/// the leg's own item day numbers rather than a stay or the auto slice — the
/// provenance the last-leg trip-end anchor keys on, mirroring the server's
/// `RenderLeg.DateSource == "items"` (trip_render_legs.go). The two together
/// carry what one `DateSource` string carries there; keep them in step.
typedef LegRange = ({
  String label,
  DateTime? start,
  DateTime? end,
  ({double lat, double lng})? coord,
  bool stayAnchored,
  bool itemDerived,
});

/// Per-location-group label and date range. Each location gets a contiguous
/// slice of the trip's start–end span, weighted by how many places it has; an
/// accommodation with its own dates overrides the computed slice (and sets
/// [LegRange.stayAnchored]). Computed over the full itinerary so category
/// filters don't shift the allocation.
List<LegRange> rawLegRanges(Trip trip) {
  final items = trip.items ?? const <ItineraryItem>[];
  if (items.isEmpty) return const [];
  // Confirmed only: a suggested draft's dates come FROM this derivation, so
  // letting them back in via _accDateRangeFor would freeze the ranges. Same
  // !auto rule as the trip screen's _confirmedStays.
  final stays = (trip.accommodations ?? const <Accommodation>[])
      .where((a) => !a.auto)
      .toList();

  // Canonical locality runs over the full itinerary (shared split).
  final legs = tripLegs(items);

  // Auto-split the trip span across groups, weighted by item count.
  final start = DateTime.tryParse(trip.startDate ?? '');
  final end = DateTime.tryParse(trip.endDate ?? '');
  final auto = List<({DateTime start, DateTime end})?>.filled(legs.length, null);
  if (start != null && end != null && !end.isBefore(start)) {
    final totalDays = end.difference(start).inDays + 1;
    final n = legs.length;
    if (n <= totalDays) {
      // Enough days: give each location a contiguous slice weighted by size.
      final counts =
          allocateDays(totalDays, [for (final leg in legs) leg.items.length]);
      var cursor = start;
      for (var i = 0; i < n; i++) {
        final rStart = cursor.isAfter(end) ? end : cursor;
        var rEnd = rStart.add(Duration(days: counts[i] - 1));
        if (rEnd.isAfter(end)) rEnd = end;
        auto[i] = (start: rStart, end: rEnd);
        cursor = rEnd.add(const Duration(days: 1));
      }
    } else {
      // More locations than days: map each to a single day in order, so dates
      // stay ascending and within the trip (some days carry several stops).
      for (var i = 0; i < n; i++) {
        final d = start
            .add(Duration(days: (i * totalDays ~/ n).clamp(0, totalDays - 1)));
        auto[i] = (start: d, end: d);
      }
    }
  }

  final result = <LegRange>[];
  for (var i = 0; i < legs.length; i++) {
    final leg = legs[i];
    // The raw nullable locality feeds the stay-address match — the
    // 'Other places' placeholder label would falsely substring-match.
    final accRange = _accDateRangeFor(leg.locality, stays);
    final dayRange = _dayRangeFor(leg.items, start);
    final a = auto[i];
    var rangeStart = accRange?.start ?? dayRange?.start ?? a?.start;
    // First-leg trip-start anchor: the traveler is in the first city from
    // the trip's first day, so an item-derived range must not start later
    // (a single late item would render a bare "Aug 27" on an Aug 24 trip).
    // A confirmed stay's check-in still wins; the server mirrors this in
    // anchoredLegDisplayRange (plan_leg_dates.go).
    if (i == 0 &&
        accRange == null &&
        start != null &&
        rangeStart != null &&
        start.isBefore(rangeStart)) {
      rangeStart = start;
    }
    result.add((
      label: leg.label,
      start: rangeStart,
      end: accRange?.end ?? dayRange?.end ?? a?.end,
      coord: leg.coord,
      stayAnchored: accRange != null,
      itemDerived: accRange == null && dayRange != null,
    ));
  }
  return result;
}

/// The ranges the page RENDERS: [rawLegRanges] plus the boundary rule
/// (specs/leg-departure-dates), as one forward pass. A leg runs until the
/// NEXT leg's arrival — that leg's own raw start: its stay's check-in, its
/// first item day, or its auto-slice start. A leg's end is written by its
/// neighbour, never by its own last item day, so "Friday is my last planned
/// day, Saturday I fly" renders three nights with Saturday empty, and moving
/// a place inside a city cannot change any city's dates. When the next
/// arrival is on (or before) a leg's own, the span pinches to a genuine
/// zero-night stop — two cities sharing one arrival day.
///
/// Two carve-outs, both pre-existing. A confirmed stay's explicit dates never
/// move: its checkout is not extended, so a gap AFTER a stay closes from the
/// other side — the next leg's start pulls back to the checkout (a gap
/// between legs is unrepresentable on the page under either rule) — and stay
/// dates that contradict a neighbour's places render as the overlap they are.
/// A leg with no range adopts the previous end as its start and RESETS the
/// chain (the documented pre-cutover divergence: the server skips spanless
/// legs and closes the boundary across them).
///
/// Stay todos, inter-city leg dates, header chips, and the per-city weather
/// and events lookups consume THIS — anything that makes a promise about the
/// dates ON SCREEN has to be derived from the dates on screen (a "while
/// you're here" events section on the raw ranges queried one day of a
/// four-day Berlin stay; friction-log 2026-08-14). Map pins stay on the raw
/// ranges: a pin is a point.
///
/// Then the LAST-leg trip-end anchor, the tail case of the same rule (the
/// first-leg anchor in [rawLegRanges] is the head case): the leg that renders
/// last, when item-derived, runs through the trip's end date. The traveler is
/// in the final city until the day they travel home, and that day carries no
/// places — the planner reserves it for the journey — so its item-derived end
/// falls a day or more short. Stretch-only, and no collapsed-leg check is
/// needed: a zero-night pinch requires a NEXT ranged leg, so the tail leg can
/// never carry one.
///
/// The server mirrors the whole function in computeTripLegs (steps 5 and 6,
/// trip_render_legs.go).
List<LegRange> visibleLegRanges(Trip trip) {
  final raw = rawLegRanges(trip);
  final result = <LegRange>[];
  DateTime? prevEnd;
  var prevStay = false;
  for (var i = 0; i < raw.length; i++) {
    final r = raw[i];
    var start = r.start;
    var end = r.end;
    if (start == null) {
      // Rangeless leg: adopt the previous end as the start, keep the null
      // end, and break the chain for whatever follows (pre-cutover client
      // rule — the Go twin skips these legs instead).
      result.add((
        label: r.label,
        start: prevEnd,
        end: end,
        coord: r.coord,
        stayAnchored: r.stayAnchored,
        itemDerived: r.itemDerived,
      ));
      prevEnd = end;
      prevStay = false;
      continue;
    }
    // A gap after a confirmed stay closes on THIS side: the checkout is
    // explicit and cannot extend forward.
    if (prevStay && prevEnd != null && prevEnd.isBefore(start)) {
      start = prevEnd;
    }
    // The boundary rule: this leg's end is the next leg's arrival. The next
    // leg's RAW start is its arrival evidence (check-in / first item day /
    // auto start); a rangeless next leg extends nothing (the chain-reset
    // divergence above).
    if (!r.stayAnchored && i + 1 < raw.length) {
      final nextArrival = raw[i + 1].start;
      if (nextArrival != null) {
        end = nextArrival.isAfter(start) ? nextArrival : start;
      }
    }
    result.add((
      label: r.label,
      start: start,
      end: end,
      coord: r.coord,
      stayAnchored: r.stayAnchored,
      itemDerived: r.itemDerived,
    ));
    prevEnd = end;
    prevStay = r.stayAnchored;
  }

  // Walks from the tail the way the first-leg anchor sits at the head, so it
  // lands on whichever leg renders last. A confirmed stay's checkout wins and
  // an auto slice already ends at the trip's end, so only item-derived ranges
  // move — [LegRange.itemDerived], the server's DateSource == "items".
  final tripEnd = DateTime.tryParse(trip.endDate ?? '');
  if (tripEnd != null) {
    for (var i = result.length - 1; i >= 0; i--) {
      final r = result[i];
      if (r.end == null) continue;
      if (r.itemDerived && r.end!.isBefore(tripEnd)) {
        result[i] = (
          label: r.label,
          start: r.start,
          end: tripEnd,
          coord: r.coord,
          stayAnchored: r.stayAnchored,
          itemDerived: r.itemDerived,
        );
      }
      break;
    }
  }
  return result;
}

/// Date range for a location group from its items' AI-assigned day numbers,
/// anchored to the trip start: day N -> startDate + (N-1). Null when the trip
/// has no start date or none of the items carry a day.
({DateTime start, DateTime end})? _dayRangeFor(
    List<ItineraryItem> items, DateTime? tripStart) {
  if (tripStart == null) return null;
  int? lo, hi;
  for (final it in items) {
    final d = it.day;
    if (d == null || d < 1) continue;
    if (lo == null || d < lo) lo = d;
    if (hi == null || d > hi) hi = d;
  }
  if (lo == null || hi == null) return null;
  return (
    start: tripStart.add(Duration(days: lo - 1)),
    end: tripStart.add(Duration(days: hi - 1)),
  );
}

/// First accommodation in [locality] with both check-in/out dates, as DateTimes.
({DateTime start, DateTime end})? _accDateRangeFor(
    String? locality, List<Accommodation> stays) {
  if (locality == null) return null;
  final key = locality.toLowerCase();
  for (final acc in stays) {
    final addr = acc.address?.toLowerCase();
    if (addr == null) continue;
    if ((addr.contains(key) || key.contains(addr)) &&
        acc.checkIn != null &&
        acc.checkOut != null) {
      final ci = DateTime.tryParse(acc.checkIn!);
      final co = DateTime.tryParse(acc.checkOut!);
      if (ci != null && co != null) return (start: ci, end: co);
    }
  }
  return null;
}

/// Splits [totalDays] across groups proportional to [weights], each group at
/// least 1 day, summing to totalDays (largest-remainder; trims overflow from
/// the largest groups when the min-1 floor pushes the total over). Public for
/// direct unit tests; [rawLegRanges] is its only production caller.
List<int> allocateDays(int totalDays, List<int> weights) {
  final n = weights.length;
  if (n == 0) return const [];
  if (totalDays <= n) {
    return List.filled(n, 1); // ranges clamp to the trip end
  }
  final totalW = weights.fold<int>(0, (s, w) => s + (w <= 0 ? 1 : w));
  final exact = [
    for (final w in weights) totalDays * (w <= 0 ? 1 : w) / totalW
  ];
  final counts = [for (final e in exact) e.floor() < 1 ? 1 : e.floor()];
  var used = counts.fold<int>(0, (s, c) => s + c);
  // Hand out any remaining days to the largest fractional remainders.
  final byRemainder = List<int>.generate(n, (i) => i)
    ..sort((a, b) =>
        (exact[b] - exact[b].floor()).compareTo(exact[a] - exact[a].floor()));
  for (var k = 0; used < totalDays; k++) {
    counts[byRemainder[k % n]] += 1;
    used++;
  }
  // Or trim back from the largest groups if min-1 overshot.
  final byCount = List<int>.generate(n, (i) => i)
    ..sort((a, b) => counts[b].compareTo(counts[a]));
  for (var k = 0; used > totalDays; k++) {
    final j = byCount[k % n];
    if (counts[j] > 1) {
      counts[j]--;
      used--;
    }
  }
  return counts;
}

/// Whole nights between two local-midnight dates, checkout-exclusive
/// (Aug 24 -> Aug 27 = 3; same day = 0). UTC-normalized so a DST
/// transition inside the range can't skew the count. Client display
/// only — NOT part of the Go-twin contract; the legs payload carries
/// no nights field.
int nightsBetween(DateTime a, DateTime b) =>
    DateTime.utc(b.year, b.month, b.day)
        .difference(DateTime.utc(a.year, a.month, a.day))
        .inDays;
