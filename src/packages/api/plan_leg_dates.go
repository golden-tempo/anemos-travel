package main

// set_leg_dates (specs/set-leg-dates): the /plan agent's way to change WHEN
// one city leg of a saved trip happens without moving the rest of the trip.
// set_trip_dates shifts everything by one delta; shift_days_from moves a
// suffix; this tool moves ONE leg.
//
// Under the boundary rule (specs/leg-departure-dates) a leg's items carry its
// ARRIVAL and nothing else: the page renders a leg from its own arrival (first
// item day / stay check-in, the trip's start for the first city) until the
// NEXT city's arrival, with the last city running through the trip's end. So
// a start move renumbers the run's item days START-anchored — every item
// keeps its within-leg offset, and no item is ever dragged onto a departure
// day (the old END-anchored renumber moved places the traveler deliberately
// kept off the travel day; ticket 2 removed it). One transaction renumbers
// the items, moves the leg's matched confirmed stays and the transport the
// leg OWNS, and extends the trip's end date when the leg now runs past it.
//
// Transport ownership follows the same rule (ticket 5): a boundary segment's
// day belongs to the ARRIVAL it serves. A segment arriving at this city rides
// this leg's start; one departing to another city of the trip is that city's
// arrival transport and moves only with that city's own call — never here,
// which is how a chained repair once moved one flight twice. A departing
// segment with no arrival-side owner (the journey home) rides this leg's end
// only when this call moved a REAL stored end — the confirmed stay's
// check-out or the final leg's trip-end extension — because on any other move
// endDelta is the length-preserving synthetic, an end the call did not
// change, and moving a confirmed booking by it desyncs the flight from the
// page.
//
// An explicit end_date is honoured only where the departure actually lives on
// this leg's own rows: a confirmed stay's check-out, or — for the trip's
// final rendered leg — the trip's end date. Any other leg's end IS the next
// city's arrival, so an end-change there refuses and steers to the call that
// moves it (set_leg_dates on the next city, or shift_days_from); an end_date
// merely echoing what the page already renders is treated as omitted.
//
// A PREVIOUS leg pinned by a confirmed stay has its check-out extended to
// meet a later start in the same transaction — computeTripLegs closes a gap
// after a stay by pulling THIS leg's rendered start back to the check-out, so
// without the write the move would be invisible on screen. Item-dated
// neighbours need no write at all: their rendered end is this leg's arrival,
// wherever it lands. The FIRST dated leg's visible start is the trip's start
// date (anchored) so a first-leg start change steers to set_trip_dates. A
// zero-change call commits nothing and reports actual saved state — never
// the requested range, and no trip_updated SSE.
//
// Everything a result says about what the traveler SEES derives from
// computeTripLegs (renderedLegForRun) — the derivation the page, the `legs`
// payload and legsRenderSummary share. The leg-dates arc paid for this rule:
// the renumbering math above needs item-day semantics, but anything speaking
// about the dates on screen derives from the dates on screen; quoting raw
// item spans as neighbour dates is how the tool once reported a "2-night gap"
// the page never drew. Gated authedOnly (per-conversation stable,
// prompt-cache safe); target-trip resolution reuses resolveDateShiftTrip.

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	anthropic "github.com/anthropics/anthropic-sdk-go"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

var setLegDatesTool = anthropic.ToolParam{
	Name: "set_leg_dates",
	Description: anthropic.String("Change when ONE city's leg of the traveler's saved trip happens — 'arrive in Rome a day later' — without moving the rest of the trip. " +
		"start_date moves the city's ARRIVAL: its itinerary days shift together, its stay's dates move, and the transport INTO the city follows. " +
		"A city's departure day is the NEXT city's arrival, so to change when the traveler LEAVES a city, move the next city's start_date (or use shift_days_from to push it and everything after it together) — transport onward to another city of the trip rides THAT city's arrival and moves with it, never with this call. " +
		"end_date is honoured only where the departure lives on this city's own plan: its confirmed stay's check-out, or — for the trip's final city — the trip's end date, which extends when the leg runs past it. Anywhere else an explicit end_date is refused with the call to make instead. Omit end_date to keep the leg's saved length. " +
		"When the WHOLE trip moves, use set_trip_dates instead. " +
		"The result reports the dates the trip page now renders — relay any range that doesn't match what the traveler asked for. " +
		"Only the saved plan changes: anything already booked with a real provider keeps its original dates, so remind the traveler to re-check those bookings."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"city": map[string]any{
				"type":        "string",
				"description": "The city whose leg is changing, exactly as it appears in the itinerary, e.g. 'Los Angeles'",
			},
			"start_date": map[string]any{
				"type":        "string",
				"description": "The leg's new first day in that city as YYYY-MM-DD",
			},
			"end_date": map[string]any{
				"type":        "string",
				"description": "Optional new departure day as YYYY-MM-DD; only honoured when this city's departure lives on its own plan (a confirmed stay's check-out, or the trip's end for the final city). Must not be before start_date. Omit to keep the leg's saved length.",
			},
		},
		Required: []string{"city", "start_date"},
	},
}

// legRun is one contiguous run of itinerary items sharing a hub city, in
// position order. minDay/maxDay span the run's dated items (0 when none —
// such a run has no calendar footprint and can't be moved).
type legRun struct {
	hub    string
	items  []store.ItineraryItem
	minDay int
	maxDay int
}

// legRuns walks items in position order and splits on hub change (itemHub:
// day_trip_from else city, so day trips ride their hub). An empty hub never
// splits — it adopts the current run, and a run started by hubless items
// adopts the first named hub it meets, same as checkLodging's night runs.
func legRuns(items []store.ItineraryItem) []legRun {
	var runs []legRun
	for _, it := range items {
		hub := itemHub(it)
		if len(runs) == 0 {
			runs = append(runs, legRun{hub: hub})
		} else if cur := &runs[len(runs)-1]; hub != "" && cur.hub != "" && !strings.EqualFold(hub, cur.hub) {
			runs = append(runs, legRun{hub: hub})
		} else if cur.hub == "" {
			cur.hub = hub
		}
		cur := &runs[len(runs)-1]
		cur.items = append(cur.items, it)
		if it.Day != nil {
			d := int(*it.Day)
			if cur.minDay == 0 || d < cur.minDay {
				cur.minDay = d
			}
			if d > cur.maxDay {
				cur.maxDay = d
			}
		}
	}
	return runs
}

// matchLegRuns returns the dated runs whose hub matches the requested city —
// exact (case-insensitive) matches win outright; only when there are none
// does the lenient fuzzyMatch pass run, so "Los Angeles" never accidentally
// pulls in "East Los Angeles" when an exact leg exists.
func matchLegRuns(runs []legRun, city string) []int {
	var exact, fuzzy []int
	cityLower := strings.ToLower(strings.TrimSpace(city))
	for i, r := range runs {
		if r.minDay < 1 {
			continue
		}
		if strings.EqualFold(strings.TrimSpace(r.hub), strings.TrimSpace(city)) {
			exact = append(exact, i)
		} else if fuzzyMatch(strings.ToLower(r.hub), cityLower) {
			fuzzy = append(fuzzy, i)
		}
	}
	if len(exact) > 0 {
		return exact
	}
	return fuzzy
}

// stayMatchesHub mirrors the Flutter trip screen's stay-to-city matching
// (address fuzzy match), with the name as a fallback for agent-added stays
// that carry no address ("Stay in Los Angeles").
func stayMatchesHub(a store.Accommodation, hubLower string) bool {
	if addr := strings.ToLower(strings.TrimSpace(strPtrVal(a.Address))); addr != "" && fuzzyMatch(addr, hubLower) {
		return true
	}
	name := strings.ToLower(strings.TrimSpace(a.Name))
	return name != "" && fuzzyMatch(name, hubLower)
}

// matchedConfirmedStay finds the stay that anchors a leg's displayed span:
// the first confirmed (non-auto) hub-matched stay with both dates. Nil means
// the leg's span comes from its item days — whoever moves a leg boundary must
// edit the same source that produced the span, so this is shared by
// legDisplayRange and the previous-boundary extension.
func matchedConfirmedStay(run legRun, stays []store.Accommodation) *store.Accommodation {
	hubLower := strings.ToLower(run.hub)
	for i, a := range stays {
		if a.Auto || !a.CheckIn.Valid || !a.CheckOut.Valid {
			continue
		}
		if stayMatchesHub(a, hubLower) {
			return &stays[i]
		}
	}
	return nil
}

// legDisplayRange resolves the calendar span a leg currently occupies, with
// the same precedence the trip screen renders: the first confirmed matched
// stay with both dates, else the dated items' day range off the trip anchor.
func legDisplayRange(run legRun, stays []store.Accommodation, tripStart time.Time) (time.Time, time.Time) {
	if a := matchedConfirmedStay(run, stays); a != nil {
		return a.CheckIn.Time, a.CheckOut.Time
	}
	return tripStart.AddDate(0, 0, run.minDay-1), tripStart.AddDate(0, 0, run.maxDay-1)
}

// firstDatedRunIdx finds the lowest-index movable run — the leg whose arrival
// IS the trip's start date. -1 when none. Same dated-run criteria as
// prevDatedRunIdx/nextDatedRunIdx.
func firstDatedRunIdx(runs []legRun) int {
	for i, r := range runs {
		if r.minDay >= 1 && r.hub != "" {
			return i
		}
	}
	return -1
}

// anchoredLegDisplayRange is legDisplayRange plus the first-leg anchor: the
// first dated run's visible start pulls back to the trip start when its span
// is item-derived — the traveler is in the first city from the trip's first
// day, so a single late item must not read as a late arrival. A confirmed
// stay still wins, mirroring the client's _locationGroupRanges clamp
// (trip_detail_screen.dart). Item days are >= 1, so the anchor only ever
// pulls the start back, never forward.
func anchoredLegDisplayRange(runs []legRun, i int, stays []store.Accommodation, tripStart time.Time) (time.Time, time.Time) {
	s, e := legDisplayRange(runs[i], stays, tripStart)
	if i == firstDatedRunIdx(runs) && matchedConfirmedStay(runs[i], stays) == nil && tripStart.Before(s) {
		s = tripStart
	}
	return s, e
}

// prevSpannedRenderedLeg / nextSpannedRenderedLeg find the spanned leg the
// page renders immediately before/after `at` (a pointer into legs, the
// renderedLegForRun convention). Nil when there is none, in which case the
// caller must say nothing rather than quote a number from the wrong
// derivation. These are how neighbour narration reads the screen: the
// renumbering twins above keep item-day semantics, but anything speaking
// about the dates on screen derives from the dates on screen.
func prevSpannedRenderedLeg(legs []RenderLeg, at *RenderLeg) *RenderLeg {
	var prev *RenderLeg
	for i := range legs {
		if &legs[i] == at {
			return prev
		}
		if legs[i].Start != nil && legs[i].End != nil {
			prev = &legs[i]
		}
	}
	return nil
}

func nextSpannedRenderedLeg(legs []RenderLeg, at *RenderLeg) *RenderLeg {
	seen := false
	for i := range legs {
		if &legs[i] == at {
			seen = true
			continue
		}
		if seen && legs[i].Start != nil && legs[i].End != nil {
			return &legs[i]
		}
	}
	return nil
}

// legDateChange is the pure outcome of a leg move: the resolved new span,
// the endpoint-anchored day deltas, and the leg's new 1-based trip-day
// indices.
type legDateChange struct {
	newStart, newEnd       time.Time
	startDelta, endDelta   int
	newStartIdx, newEndIdx int
}

var (
	errLegEndBeforeStart  = fmt.Errorf("end_date must not be before start_date")
	errLegBeforeTripStart = fmt.Errorf("leg start precedes trip start")
)

// computeLegDateChange resolves the new leg span and both deltas. A nil
// newEnd preserves the leg's current length. All values are civil dates as
// UTC midnights, so hour math is exact — no DST.
func computeLegDateChange(tripStart, oldLegStart, oldLegEnd, newStart time.Time, newEnd *time.Time) (legDateChange, error) {
	end := newStart.Add(oldLegEnd.Sub(oldLegStart))
	if newEnd != nil {
		end = *newEnd
	}
	if end.Before(newStart) {
		return legDateChange{}, errLegEndBeforeStart
	}
	startIdx := int(newStart.Sub(tripStart).Hours()/24) + 1
	if startIdx < 1 {
		return legDateChange{}, errLegBeforeTripStart
	}
	return legDateChange{
		newStart:    newStart,
		newEnd:      end,
		startDelta:  int(newStart.Sub(oldLegStart).Hours() / 24),
		endDelta:    int(end.Sub(oldLegEnd).Hours() / 24),
		newStartIdx: startIdx,
		newEndIdx:   int(end.Sub(tripStart).Hours()/24) + 1,
	}, nil
}

func legRangeText(start, end time.Time) string {
	return start.Format(dateLayout) + " to " + end.Format(dateLayout)
}

// nightsText spells a leg's night count the way the trip page's chip does —
// the unit the rest of the app measures a stay in, and the one the traveler
// agreed to when they approved the trip's shape.
func nightsText(nights int) string {
	if nights == 1 {
		return "1 night"
	}
	return fmt.Sprintf("%d nights", nights)
}

// legsSummary lists the trip's movable city legs with the spans the trip page
// RENDERS for them (computeTripLegs) — the honest error payload when the
// requested city doesn't resolve. Only legs a set_leg_dates/shift_days_from
// call can actually address are listed: a named hub and at least one dated
// item (matchLegRuns' criteria); hubless "Other places" legs are skipped.
func legsSummary(trip store.Trip, items []store.ItineraryItem, stays []store.Accommodation) string {
	var parts []string
	for _, leg := range computeTripLegs(trip, items, stays) {
		if leg.Hub == nil || leg.Start == nil || leg.End == nil || len(leg.itemDays) == 0 {
			continue
		}
		parts = append(parts, fmt.Sprintf("%s (%s)", leg.Label, legRangeText(*leg.Start, *leg.End)))
	}
	return strings.Join(parts, ", ")
}

// legsRenderSummary lists every spanned leg with the calendar range the trip
// page RENDERS for it — one "- City: X to Y" line. This is the model-facing
// render truth: it goes into get_trip and into update_itinerary_section's
// result so a wrong day-number mental model is falsifiable from tool output
// instead of surviving successful writes. Since stage 1b
// (specs/server-leg-dates) it runs over computeTripLegs — the same
// computation the `legs` payload serializes — so what the model reads is
// exactly what the page shows. Spanless legs are skipped; hubless legs with
// spans print under the "Other places" label. Empty when nothing is spanned.
//
// Each line carries the range, its NIGHT COUNT and how the span was decided —
// not the range alone (specs/shape-before-schedule). The ways a span goes
// wrong all read as ordinary output unless they are named: two cities sharing
// an arrival day render a zero-night stop the model can only catch by doing
// arithmetic on dates it half-trusts (before the boundary rule, a city that
// lost its travel-day place collapsed the same way), and a city whose places
// carry no day numbers gets an equal share of the trip invented for it, which
// looks exactly like a real range. Nights make the first arithmetic-free,
// provenance makes the second visible, and legsRenderWarning puts the ones
// that matter above the list.
func legsRenderSummary(trip store.Trip, items []store.ItineraryItem, stays []store.Accommodation) string {
	legs := computeTripLegs(trip, items, stays)
	var b strings.Builder
	b.WriteString(legsRenderWarning(trip, legs))
	for _, leg := range legs {
		if leg.Start == nil || leg.End == nil {
			continue
		}
		fmt.Fprintf(&b, "- %s: %s (%s, %s)\n", leg.Label, legRangeText(*leg.Start, *leg.End),
			nightsText(nightsBetween(*leg.Start, *leg.End)), legDateSourceText(leg.DateSource))
	}
	return b.String()
}

// legTransportSummary lists how the traveler crosses between consecutive city
// legs — one "- Rome → Florence: train" line — resolved by the ONE ladder
// (resolveLegMode, leg_transport_mode.go), so what the model reads is what the
// page's checklist row shows.
//
// It rides the same three model-facing surfaces as legsRenderSummary for the
// same reason that one exists: a planner who never sees the app's answer
// cannot correct it. The Italy trip that started this had no way to tell
// anyone its Rome → Florence row had become a flight search, so the model
// narrated flights to match. A leg the model disagrees with is now visible in
// the tool result, and set_leg_transport_mode is the reply.
//
// `overrides` maps a derived transport key to the mode somebody chose (the
// row menu, or this tool); pass nil when the caller has no checklist in hand —
// a fresh trip has no rows yet. Empty when the trip has fewer than two named
// cities, i.e. nothing to cross.
//
// Unlike legsRenderSummary this does NOT require a calendar span: a leg with
// no dates still has to be crossed, and naming the crossing promises nothing
// about when. Hubless runs ("Other places") are skipped — a leg with no city
// is not somewhere the traveler travels to.
func legTransportSummary(trip store.Trip, items []store.ItineraryItem, stays []store.Accommodation, overrides map[string]string) string {
	var cities []RenderLeg
	for _, leg := range computeTripLegs(trip, items, stays) {
		if leg.Hub != nil && strings.TrimSpace(*leg.Hub) != "" {
			cities = append(cities, leg)
		}
	}
	if len(cities) < 2 {
		return ""
	}
	coords := legCoordIndex(cities)
	var b strings.Builder
	for i := 1; i < len(cities); i++ {
		from, to := cities[i-1].Label, cities[i].Label
		var override *string
		if m, ok := overrides[transportTodoKey(from, to)]; ok {
			override = &m
		}
		fmt.Fprintf(&b, "- %s → %s: %s\n", from, to,
			resolveLegMode(trip, legEndpointFrom(from, coords), legEndpointFrom(to, coords), override))
	}
	return b.String()
}

// legModeOverrides indexes a trip's checklist by derived-transport key for the
// modes somebody actually chose — the top rung resolveLegMode takes.
func legModeOverrides(todos []store.BookingTodo) map[string]string {
	out := map[string]string{}
	for _, t := range todos {
		if m := strings.TrimSpace(strPtrVal(t.Mode)); allowedLegModes[m] {
			out[t.TodoKey] = m
		}
	}
	return out
}

// legDateSourceText says in words where a leg's span came from — RenderLeg's
// DateSource, which rides the trip payload but has never reached the model.
// "auto" is the one that must not read like a fact: it is the weighted split of
// the trip span that fires when no place on the leg carries a day, and it is
// indistinguishable from a real range once rendered.
func legDateSourceText(source string) string {
	switch source {
	case "stay":
		return "dated by its confirmed stay"
	case "items":
		return "dated by its places"
	case "auto":
		return "dates GUESSED — no place on this leg carries a day"
	default:
		return "no date source"
	}
}

// legsRenderWarning names, ABOVE the list, the legs whose rendered spans
// contradict the traveler's plan in the three ways that are silent on every
// other surface — two cities sharing an arrival day (ZeroNight: the next
// leg's arrival is on or before this leg's own), a place dated after the day
// its leg ends on the page (itemsPastEnd — read from the derivation, never
// re-derived here: a second derivation of the same condition is the defect
// specs/leg-departure-dates exists to kill), and a span that was guessed
// because no place carries a day. It leads because the last-day arc showed a
// rule buried under a table gets averaged away ("putting it FIRST fixed it
// outright"). The remedy deliberately never says to add a place: a
// placeholder invented to hold a date is the corruption the boundary rule
// retired (the Prague Airport Starbucks), and a leg's dates move by moving
// arrivals, not by planting items.
//
// A second, SOFT block follows for unplanned stretches — a leg whose last
// place sits two or more nights before its rendered end. That is a true fact
// about the page, not a render defect: under the boundary rule a leg runs to
// the next city's arrival whether or not its tail nights hold plans, and the
// honest narration for what used to be misreported as a "gap between legs"
// (unrepresentable on screen) is unplanned nights INSIDE a leg. ONE night
// stays silent: a place-free departure morning is the normal spine — every
// correctly-built trip has one — and a line that fires on everything gets
// averaged away with the hard warning above it.
func legsRenderWarning(trip store.Trip, legs []RenderLeg) string {
	var problems, unplanned []string
	for i := range legs {
		leg := &legs[i]
		if leg.Start == nil || leg.End == nil {
			continue
		}
		if leg.ZeroNight {
			nextLabel := "the next city"
			if next := nextSpannedRenderedLeg(legs, leg); next != nil {
				nextLabel = next.Label
			}
			problems = append(problems, fmt.Sprintf("%s renders ZERO nights — the next city (%s) arrives on or before it, so the traveler arrives and moves straight on", leg.Label, nextLabel))
			continue
		}
		if leg.itemsPastEnd {
			problems = append(problems, fmt.Sprintf("%s has a place dated after %s, the day it ends on the page — that place sits outside its own city's rendered dates", leg.Label, leg.End.Format(dateLayout)))
			continue
		}
		if leg.DateSource == "auto" {
			problems = append(problems, fmt.Sprintf("%s has no dated place, so its range is a guess, not the nights that were agreed", leg.Label))
			continue
		}
		if trip.StartDate.Valid && len(leg.itemDays) > 0 {
			last := leg.itemDays[0]
			for _, d := range leg.itemDays[1:] {
				if d > last {
					last = d
				}
			}
			lastDate := trip.StartDate.Time.AddDate(0, 0, int(last)-1)
			if n := nightsBetween(lastDate, *leg.End); n >= 2 {
				unplanned = append(unplanned, fmt.Sprintf("%s renders %s (%s) but its last place is %s — %d nights with nothing planned", leg.Label, legRangeText(*leg.Start, *leg.End), nightsText(nightsBetween(*leg.Start, *leg.End)), lastDate.Format(dateLayout), n))
			}
		}
	}
	var b strings.Builder
	if len(problems) > 0 {
		b.WriteString("WARNING — the page is not rendering what the traveler agreed to: " +
			strings.Join(problems, "; ") +
			". Fix it before you reply: a leg ends at the NEXT city's arrival, so adjust arrivals with set_leg_dates (start_date) or shift the schedule with shift_days_from — never add a place just to hold a date.\n")
	}
	if len(unplanned) > 0 {
		b.WriteString("Unplanned stretches — true on the page, fine if intended (mention, don't fix): " +
			strings.Join(unplanned, "; ") + ".\n")
	}
	return b.String()
}

func runSetLegDatesTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		City      string `json:"city"`
		StartDate string `json:"start_date"`
		EndDate   string `json:"end_date"`
	}
	json.Unmarshal(input, &in)

	if !s.authed {
		return "The traveler isn't signed in, so there's no saved trip to change. Give the advice in your reply instead.", true
	}
	if dbPool == nil {
		return "Saved trips are unavailable right now (persistence offline).", true
	}

	city := strings.TrimSpace(in.City)
	if city == "" {
		return "city is required — the city whose leg is changing, as it appears in the itinerary.", true
	}
	start, err := parseDateParam(&in.StartDate)
	if err != nil || !start.Valid {
		return "start_date is required and must be YYYY-MM-DD.", true
	}
	var newEnd *time.Time
	if endParam, err := parseDateParam(&in.EndDate); err != nil {
		return "end_date must be YYYY-MM-DD.", true
	} else if endParam.Valid {
		newEnd = &endParam.Time
	}

	tid, msg, failed := resolveDateShiftTrip(s)
	if failed {
		return msg, true
	}

	tx, err := dbPool.Begin(s.ctx)
	if err != nil {
		return "Could not update the leg's dates right now.", true
	}
	defer tx.Rollback(s.ctx)
	q := store.New(tx)

	// Same row lock replaceTripSection and set_trip_dates take: serializes
	// leg moves against concurrent rewrites and whole-trip shifts.
	trip, err := q.GetTripForUpdate(s.ctx, tid)
	if err != nil {
		return "Could not load the trip to update its dates.", true
	}
	if !trip.StartDate.Valid {
		return "This trip has no dates yet, so one city's dates can't be placed on its calendar. Set the trip's dates first with set_trip_dates.", true
	}
	tripStart := trip.StartDate.Time

	items, err := q.GetItineraryItemsByTrip(s.ctx, tid)
	if err != nil {
		return "Could not load the trip's itinerary.", true
	}
	stays, err := q.ListAccommodationsByTrip(s.ctx, tid)
	if err != nil {
		return "Could not load the trip's stays.", true
	}
	segs, err := q.ListSegmentsByTrip(s.ctx, tid)
	if err != nil {
		return "Could not load the trip's transport legs.", true
	}

	runs := legRuns(items)
	matched := matchLegRuns(runs, city)
	if len(matched) == 0 {
		if legs := legsSummary(trip, items, stays); legs != "" {
			return fmt.Sprintf("No leg for '%s' in this trip. The legs are: %s. Use the city name as it appears in the itinerary.", city, legs), true
		}
		return "This trip's itinerary has no day-numbered city legs to move. Use set_trip_dates for the whole trip instead.", true
	}
	// Rendered spans, not raw item-day math, label the pre-move state: anything
	// speaking about the dates on screen derives from the dates on screen.
	legsNow := computeTripLegs(trip, items, stays)
	if len(matched) > 1 {
		var spans []string
		for _, i := range matched {
			if leg := renderedLegForRun(legsNow, runs[i]); leg != nil && leg.Start != nil && leg.End != nil {
				spans = append(spans, legRangeText(*leg.Start, *leg.End))
			}
		}
		return fmt.Sprintf("The itinerary visits %s more than once (%s), and moving just one of several visits isn't supported yet — tell the traveler plainly what you couldn't do.", runs[matched[0]].hub, strings.Join(spans, "; ")), true
	}

	run := runs[matched[0]]
	hubLower := strings.ToLower(run.hub)
	oldLegStart, oldLegEnd := anchoredLegDisplayRange(runs, matched[0], stays, tripStart)
	movedLegNow := renderedLegForRun(legsNow, run)
	var nextSpannedNow *RenderLeg
	if movedLegNow != nil {
		nextSpannedNow = nextSpannedRenderedLeg(legsNow, movedLegNow)
	}
	// The one stay that anchors this leg's rendered end (and start) — the
	// predicate the first-leg carve-out, the end_date gate, transport
	// ownership and the no-op report all share.
	runStay := matchedConfirmedStay(run, stays)

	// The first leg's arrival IS the trip's start date (its span is anchored
	// there), so a different start is really a trip-start change — steer to
	// set_trip_dates rather than silently re-numbering items into a shape the
	// screen can't show. Carve-out: a confirmed stay anchors the leg's start
	// instead, and its check-in stays movable like any other leg's.
	if matched[0] == firstDatedRunIdx(runs) && runStay == nil && !start.Time.Equal(tripStart) {
		return fmt.Sprintf("%s is the trip's first city, so its arrival IS the trip's start date (%s). To move when the trip begins, use set_trip_dates; a city's departure day is the NEXT city's arrival, so to change when the traveler leaves %s, move the next city's start_date instead.",
			run.hub, tripStart.Format(dateLayout), run.hub), true
	}

	// What an explicit end_date means changed with the boundary rule
	// (specs/leg-departure-dates): the page renders a leg's end as the NEXT
	// city's arrival, its own confirmed stay's check-out, or — for the final
	// leg — the trip's end date. Only the last two live on rows this leg owns,
	// so those are the only end-moves this tool performs. An end_date merely
	// echoing what the page already renders is treated as omitted ("make LA
	// Sep 24 to 27" when Sep 27 is already the on-screen end is a start move);
	// anything else refuses with the call that actually moves the boundary —
	// applying the start half anyway would be the tool fighting the traveler.
	// endOwned: this call moves a REAL stored end — the leg's confirmed
	// stay's check-out (the stays loop moves it by endDelta on every accepted
	// move, rigid or endpoint-anchored), or the final leg's trip-end
	// extension below. Only such an end may carry departing transport; on
	// every other move endDelta is the length-preserving synthetic.
	endBasis := oldLegEnd
	endOwned := runStay != nil
	if newEnd != nil && runStay == nil {
		switch {
		case movedLegNow != nil && movedLegNow.End != nil && newEnd.Equal(*movedLegNow.End):
			newEnd = nil
		case nextSpannedNow != nil:
			steer := fmt.Sprintf("move those items to other days or use shift_days_from(city=%q, days=N)", nextSpannedNow.Label)
			if nextSpannedNow.Hub != nil {
				steer = fmt.Sprintf("call set_leg_dates(city=%q, start_date=%q) to move %s (keeping its length), or shift_days_from(city=%q, days=N) to push it and everything after it together",
					nextSpannedNow.Label, newEnd.Format(dateLayout), nextSpannedNow.Label, nextSpannedNow.Label)
			}
			onScreen := ""
			if movedLegNow.End != nil {
				onScreen = fmt.Sprintf(" — the page currently shows %s ending %s because %s arrives then", run.hub, movedLegNow.End.Format(dateLayout), nextSpannedNow.Label)
			}
			return fmt.Sprintf("%s's departure day is the next city's arrival, not a date of its own%s. Nothing was changed. To have the traveler leave %s on %s, %s. To change only %s's arrival, call set_leg_dates again with start_date and no end_date.",
				run.hub, onScreen, run.hub, newEnd.Format(dateLayout), steer, run.hub), true
		case trip.EndDate.Valid && newEnd.Before(trip.EndDate.Time):
			return fmt.Sprintf("%s is the trip's last city, so it runs through the trip's end date (%s) — an earlier end_date would shorten the whole trip. Nothing was changed. Use set_trip_dates (start_date=%s, end_date=%s) to end the trip on %s, or call set_leg_dates again with start_date only to move just %s's arrival.",
				run.hub, trip.EndDate.Time.Format(dateLayout), tripStart.Format(dateLayout), newEnd.Format(dateLayout), newEnd.Format(dateLayout), run.hub), true
		case trip.EndDate.Valid:
			// Extending the final leg: the departure being moved is the trip's
			// end date, so the end delta (departing transport) is measured off
			// it — the raw last item day runs short of it by however many
			// place-free tail nights the leg holds.
			endBasis = trip.EndDate.Time
			endOwned = true
		}
	}

	// A confirmed stay on the PREVIOUS leg pins that leg's rendered end to its
	// check-out (explicit dates never chase an arrival), and computeTripLegs
	// closes a gap after such a stay by pulling THIS leg's rendered start BACK
	// to the check-out — which would silently undo the move on screen. So a
	// later start extends that check-out in the same transaction: the write
	// edits the same source that renders the boundary. Item-dated neighbours
	// need no write at all — their rendered end IS this leg's arrival,
	// wherever it lands. (The old items-case drag — the previous leg's last
	// item moved onto the new boundary day — died with the end-anchored
	// renumber: both wrote the retired "last item day = departure" convention
	// onto days the traveler chose deliberately.) Resolve before any writes.
	var prevRun *legRun
	var prevStay *store.Accommodation
	if pi := prevDatedRunIdx(runs, matched[0]); pi >= 0 {
		prevRun = &runs[pi]
		prevStay = matchedConfirmedStay(*prevRun, stays)
	}

	ch, err := computeLegDateChange(tripStart, oldLegStart, endBasis, start.Time, newEnd)
	switch err {
	case nil:
	case errLegEndBeforeStart:
		return "end_date must not be before start_date.", true
	case errLegBeforeTripStart:
		return fmt.Sprintf("The new start is before the trip begins on %s — itinerary days are anchored to the trip's first day. To start the whole trip earlier use set_trip_dates.", tripStart.Format(dateLayout)), true
	default:
		return "Could not compute the leg's new dates.", true
	}

	// Renumber the run's dated items START-anchored: a leg's items carry its
	// ARRIVAL and nothing else under the boundary rule, so every item keeps
	// its within-leg offset and rides the start's delta — a single-item
	// placeholder leg is a start-carrier. No item is ever dragged onto the new
	// end: the old END-anchored drag encoded the retired "last item day = the
	// departure day" convention and moved places the traveler deliberately
	// kept off the travel day (the Prague Saturday loop). The leg's rendered
	// end comes from its neighbour, its stay, or the trip's end — never from
	// where its own items land. When the window shrinks (a stay's check-out
	// moved earlier), items past the new end fold onto it and the result says
	// so (the item-beyond-span review finding covers the same shape for
	// manual edits). The shift is the DISPLAY start's delta, not min-item-day
	// anchored: for the trip-start-anchored first leg a same-start ask yields
	// zero, so items hold still; item-anchored legs get the identical value
	// either way.
	dayShift := ch.startDelta
	itemsMoved, itemsClamped := 0, 0
	for _, it := range run.items {
		if it.Day == nil {
			continue
		}
		nd := int(*it.Day) + dayShift
		clamped := false
		if nd > ch.newEndIdx {
			nd, clamped = ch.newEndIdx, true
		} else if nd < ch.newStartIdx {
			nd = ch.newStartIdx
		}
		if nd == int(*it.Day) {
			continue
		}
		if clamped {
			itemsClamped++
		}
		d32 := int32(nd)
		if _, err := q.UpdateItineraryItem(s.ctx, store.UpdateItineraryItemParams{Day: &d32, ID: it.ID, TripID: tid}); err != nil {
			return "Could not move the leg's itinerary days.", true
		}
		itemsMoved++
	}

	// Move matched CONFIRMED stays, endpoint-anchored. Auto drafts are
	// skipped on purpose: UpdateAccommodation confirms a row (auto=false),
	// which would silently adopt a suggestion the traveler never chose — and
	// the client re-derives drafts from the refreshed itinerary anyway.
	staysMoved := 0
	movedStayIDs := map[uuid.UUID]bool{}
	for _, a := range stays {
		if a.Auto || !stayMatchesHub(a, hubLower) {
			continue
		}
		var newIn, newOut pgtype.Date
		if a.CheckIn.Valid {
			newIn = pgtype.Date{Time: a.CheckIn.Time.AddDate(0, 0, ch.startDelta), Valid: true}
		}
		if a.CheckOut.Valid {
			newOut = pgtype.Date{Time: a.CheckOut.Time.AddDate(0, 0, ch.endDelta), Valid: true}
		}
		if newIn.Valid && newOut.Valid && !newOut.Time.After(newIn.Time) {
			newOut.Time = newIn.Time.AddDate(0, 0, 1)
		}
		if (!newIn.Valid || newIn.Time.Equal(a.CheckIn.Time)) && (!newOut.Valid || newOut.Time.Equal(a.CheckOut.Time)) {
			continue
		}
		if _, err := q.UpdateAccommodation(s.ctx, store.UpdateAccommodationParams{CheckIn: newIn, CheckOut: newOut, ID: a.ID, TripID: tid}); err != nil {
			return "Could not move the leg's stay dates.", true
		}
		movedStayIDs[a.ID] = true
		staysMoved++
	}

	// Boundary transport (confirmed only): a segment's calendar day belongs
	// to the ARRIVAL it serves — the boundary rule, applied to transport. One
	// arriving at the hub rides this leg's start; one inside the leg rides
	// the start. One DEPARTING the hub toward another dated city of the trip
	// is THAT city's arrival transport and moves only with that city's own
	// call — moving it here too is how a chained repair (stay-checkout end,
	// then next city's start) used to move one flight twice, and within a
	// call it is the same ownership the movedStayIDs guard gives stays. What
	// remains (the journey home, a destination outside the trip) rides this
	// leg's end only when endOwned — a real stored end this call moved. On a
	// start-only items-leg move endDelta is the length-preserving synthetic
	// for an end that post-boundary-rule is the next city's arrival, and
	// moving a confirmed booking by it silently desyncs the flight from the
	// page (specs/leg-departure-dates ticket 5).
	arrMoved, depMoved := 0, 0
	var depLeftForArrival []string
	for _, seg := range segs {
		if seg.Auto {
			continue
		}
		origMatch := fuzzyMatch(strings.ToLower(strings.TrimSpace(strPtrVal(seg.Origin))), hubLower)
		destMatch := fuzzyMatch(strings.ToLower(strings.TrimSpace(strPtrVal(seg.Destination))), hubLower)
		delta, departure := 0, false
		switch {
		case destMatch:
			delta = ch.startDelta
		case origMatch:
			if owner := segDestLegHub(runs, matched[0], strPtrVal(seg.Destination)); owner != "" {
				// Arrival-owned. Named in the result only when this call DID
				// move a real end (the model may expect the flight to follow
				// the check-out it just moved); a bare arrival move skipping
				// it is not an event — the segment already sits where the
				// page says the boundary is.
				if endOwned && ch.endDelta != 0 {
					depLeftForArrival = append(depLeftForArrival, owner)
				}
				continue
			}
			if !endOwned {
				continue
			}
			delta, departure = ch.endDelta, true
		default:
			continue
		}
		if delta == 0 || (!seg.DepartDate.Valid && !seg.ArriveDate.Valid) {
			continue
		}
		var newDep, newArr pgtype.Date
		if seg.DepartDate.Valid {
			newDep = pgtype.Date{Time: seg.DepartDate.Time.AddDate(0, 0, delta), Valid: true}
		}
		if seg.ArriveDate.Valid {
			newArr = pgtype.Date{Time: seg.ArriveDate.Time.AddDate(0, 0, delta), Valid: true}
		}
		if _, err := q.UpdateSegment(s.ctx, store.UpdateSegmentParams{DepartDate: newDep, ArriveDate: newArr, ID: seg.ID, TripID: tid}); err != nil {
			return "Could not move the leg's transport dates.", true
		}
		if departure {
			depMoved++
		} else {
			arrMoved++
		}
	}

	// Previous-boundary extension, stay case only (see the resolution comment
	// above): a later start drags a pinned check-out along so the page's
	// arrival matches the ask. Gap-only: an earlier start (overlap between two
	// explicit stays) renders as it is and the result's legs block shows it —
	// neighbors never shrink. Skipped when prevStay already moved as part of
	// THIS leg (degenerate double-hub match): never move a boundary twice.
	prevExtended := false
	var prevWasEnd time.Time
	if prevStay != nil && !movedStayIDs[prevStay.ID] && ch.newStart.After(prevStay.CheckOut.Time) {
		prevWasEnd = prevStay.CheckOut.Time
		// UpdateAccommodation flips auto=false — harmless, prevStay is
		// already confirmed; COALESCE keeps check_in.
		if _, err := q.UpdateAccommodation(s.ctx, store.UpdateAccommodationParams{
			CheckOut: pgtype.Date{Time: ch.newStart, Valid: true},
			ID:       prevStay.ID, TripID: tid,
		}); err != nil {
			return "Could not extend the previous leg's stay.", true
		}
		prevExtended = true
	}

	tripEndExtended := false
	if trip.EndDate.Valid && ch.newEnd.After(trip.EndDate.Time) {
		if err := q.SetTripDates(s.ctx, store.SetTripDatesParams{
			ID:        tid,
			StartDate: trip.StartDate,
			EndDate:   pgtype.Date{Time: ch.newEnd, Valid: true},
		}); err != nil {
			return "Could not extend the trip's end date.", true
		}
		tripEndExtended = true
	}

	// Honest no-op: nothing changed, so nothing is committed — no touched
	// updated_at, no trip_updated SSE (the client must not flash "Trip
	// updated"), no analytics. The result reports the ACTUAL saved state,
	// never the requested range echoed back as if achieved: this branch is
	// exactly where a mismatch between what the traveler sees and what the
	// tool tracks surfaces, and the model needs the real numbers to explain
	// it (the deferred tx.Rollback discards the open transaction).
	if itemsMoved+staysMoved+arrMoved+depMoved == 0 && !prevExtended && !tripEndExtended {
		itemStart := tripStart.AddDate(0, 0, run.minDay-1)
		itemEnd := tripStart.AddDate(0, 0, run.maxDay-1)
		var b strings.Builder
		fmt.Fprintf(&b, "No saved rows changed. Actual saved state for %s: itinerary items sit on %s (trip days %d-%d)", run.hub, legRangeText(itemStart, itemEnd), run.minDay, run.maxDay)
		if runStay != nil {
			fmt.Fprintf(&b, "; its confirmed stay %q runs %s", runStay.Name, legRangeText(runStay.CheckIn.Time, runStay.CheckOut.Time))
		}
		if prevSpanned := prevSpannedRenderedLeg(legsNow, movedLegNow); prevSpanned != nil {
			fmt.Fprintf(&b, "; on the page the previous leg (%s) runs through %s", prevSpanned.Label, prevSpanned.End.Format(dateLayout))
		}
		if movedLegNow != nil && movedLegNow.Start != nil && movedLegNow.End != nil {
			fmt.Fprintf(&b, ". The trip page shows this leg as %s (a leg runs from its own arrival — its first place's day, its stay's check-in, or the trip's start date for the first city — until the NEXT city's arrival; the LAST leg runs through the trip's end date; a leg's own last place never sets its departure) and was NOT refreshed.", legRangeText(*movedLegNow.Start, *movedLegNow.End))
		} else {
			b.WriteString(". The trip page was NOT refreshed.")
		}
		b.WriteString(" Never tell the traveler anything changed; if this state doesn't match what they asked for, tell them the actual dates and ask how to adjust.")
		return b.String(), false
	}

	if err := q.TouchTrip(s.ctx, store.TouchTripParams{
		ID: tid, UpdatedBy: pgtype.UUID{Bytes: s.uid, Valid: true},
	}); err != nil {
		return "Could not update the leg's dates.", true
	}
	if err := tx.Commit(s.ctx); err != nil {
		return "Could not update the leg's dates.", true
	}

	sendSSE(s.w, "trip_updated", map[string]string{"trip_id": tid.String()})
	s.itineraryEmitted = true
	s.tripID = &tid
	ownerID := trip.UserID
	safeGo("recordEvent", func() {
		recordEvent(s.uid, "agent_leg_dates_set", &tid, map[string]any{
			"city":              run.hub,
			"start_delta_days":  ch.startDelta,
			"end_delta_days":    ch.endDelta,
			"items":             itemsMoved,
			"items_clamped":     itemsClamped,
			"stays":             staysMoved,
			"segments":          arrMoved + depMoved,
			"trip_end_extended": tripEndExtended,
			"prev_leg_extended": prevExtended,
			"is_collaborator":   s.uid != ownerID,
		})
	})
	// Same collaborator-edit signal as touchTripAs; self-gated in SQL for
	// owner actors.
	if s.uid != ownerID {
		safeGo("notifyCollabEdit", func() { notifyCollabEdit(tid, s.uid) })
	}

	// The result speaks in the ranges the PAGE now renders, re-read after the
	// commit (the in-scope items and stays are the pre-move values this
	// function loaded before the transaction). ch.newStart/newEnd are item-day
	// arithmetic; quoting them as leg dates is how a call that worked once
	// reported a span the traveler's screen contradicted, and quoting raw
	// neighbour spans is how the tool reported a "2-night gap" the page never
	// drew — a date gap between legs is unrepresentable, the boundary rule
	// closes it inside the earlier leg. renderedLegForRun keys by position, so
	// a revisited hub cannot alias.
	post, postOK := postMoveState(s, tid)
	var postLegs []RenderLeg
	var movedAfter *RenderLeg
	if postOK {
		postLegs = computeTripLegs(post.trip, post.items, post.stays)
		movedAfter = renderedLegForRun(postLegs, run)
	}

	var b strings.Builder
	if movedAfter != nil && movedAfter.Start != nil && movedAfter.End != nil {
		fmt.Fprintf(&b, "%s is now %s on the trip page (%s).", run.hub, legRangeText(*movedAfter.Start, *movedAfter.End), nightsText(nightsBetween(*movedAfter.Start, *movedAfter.End)))
	} else {
		fmt.Fprintf(&b, "%s's saved dates changed; call get_trip to read the range the page now renders.", run.hub)
	}
	var parts []string
	if itemsMoved > 0 {
		parts = append(parts, fmt.Sprintf("%d itinerary item(s) onto new days", itemsMoved))
	}
	if staysMoved > 0 {
		parts = append(parts, fmt.Sprintf("%d stay(s) (check-in %s, check-out %s)", staysMoved, ch.newStart.Format(dateLayout), ch.newEnd.Format(dateLayout)))
	}
	if arrMoved+depMoved > 0 {
		parts = append(parts, fmt.Sprintf("%d arriving and %d departing transport leg(s)", arrMoved, depMoved))
	}
	if len(parts) > 0 {
		fmt.Fprintf(&b, " Moved: %s.", strings.Join(parts, ", "))
	}
	if staysMoved == 0 {
		fmt.Fprintf(&b, " No saved stay matched %s.", run.hub)
	}
	if itemsClamped > 0 {
		fmt.Fprintf(&b, " The leg got shorter, so %d item(s) past its new last day were folded onto %s.", itemsClamped, ch.newEnd.Format(dateLayout))
	}
	if tripEndExtended {
		fmt.Fprintf(&b, " Trip end extended to %s.", ch.newEnd.Format(dateLayout))
	}
	if prevExtended {
		fmt.Fprintf(&b, " %s now ends %s (was %s) — its stay's check-out moved to match this leg's arrival.", prevRun.hub, ch.newStart.Format(dateLayout), prevWasEnd.Format(dateLayout))
	}
	if len(depLeftForArrival) > 0 {
		fmt.Fprintf(&b, " NOTE: the confirmed transport out of %s (to %s) was deliberately left in place — a boundary segment rides its destination city's arrival, so it moves when that city's dates do.", run.hub, strings.Join(depLeftForArrival, ", "))
	}

	// Overlaps ARE representable on the page (an explicit stay running past a
	// neighbour's arrival), so they are the one neighbour condition still
	// named here — from the RENDERED spans, never raw item math. Contiguous
	// legs compare equal (prev.End == this.Start) and stay silent.
	if movedAfter != nil && movedAfter.Start != nil && movedAfter.End != nil {
		if prev := prevSpannedRenderedLeg(postLegs, movedAfter); prev != nil && prev.End.After(*movedAfter.Start) {
			fmt.Fprintf(&b, " NOTE: %s still runs through %s on the page, overlapping this leg's new start — point that out and offer to shorten one of them.", prev.Label, prev.End.Format(dateLayout))
		}
		if next := nextSpannedRenderedLeg(postLegs, movedAfter); next != nil && movedAfter.End.After(*next.Start) {
			fmt.Fprintf(&b, " NOTE: this leg now runs through %s, past %s's arrival (%s) — the two overlap on the page; point that out and offer to fix one of them.", movedAfter.End.Format(dateLayout), next.Label, next.Start.Format(dateLayout))
		}
	}

	// The full rendered picture, warning lines included (zero-night arrivals,
	// stranded places, unplanned tail nights): what used to be bespoke
	// gap/squeeze NOTEs computed from raw item spans — numbers the page never
	// drew — is now the ONE summary every legs surface shares (the
	// shift_days_from result convention).
	if postOK {
		if block := legsRenderSummary(post.trip, post.items, post.stays); block != "" {
			b.WriteString(" The page now renders these city legs:\n" + block +
				"That, not day arithmetic, is what the traveler sees — relay any range that doesn't match what they asked for, and act on any WARNING above the list.")
		}
	}

	b.WriteString(" IMPORTANT: anything already booked with a real provider (flights, hotels, ferries) still holds its ORIGINAL dates — remind the traveler to re-check and rebook those. If any manually added booking to-dos carry the old dates, update them with update_booking_todo. The traveler's trip page has refreshed.")
	return b.String(), false
}

// postMoveTripState is a trip re-read after a leg-date move committed — the
// state the traveler's refreshed page derives from.
type postMoveTripState struct {
	trip  store.Trip
	items []store.ItineraryItem
	stays []store.Accommodation
}

// postMoveState re-reads a trip a leg-date move just committed. Best-effort
// by design: the write has already committed, so a failed read costs the
// rendered-range sentences, never the result — and the fallback text sends
// the model to get_trip rather than letting it quote unverified spans.
func postMoveState(s *planSession, tripID uuid.UUID) (postMoveTripState, bool) {
	q := store.New(dbPool)
	trip, err := q.GetEditableTripByID(s.ctx, store.GetEditableTripByIDParams{ID: tripID, UserID: s.uid})
	if err != nil {
		return postMoveTripState{}, false
	}
	items, err := q.GetItineraryItemsByTrip(s.ctx, tripID)
	if err != nil {
		return postMoveTripState{}, false
	}
	stays, err := q.ListAccommodationsByTrip(s.ctx, tripID)
	if err != nil {
		return postMoveTripState{}, false
	}
	return postMoveTripState{trip: trip, items: items, stays: stays}, true
}

// segDestLegHub resolves whether a departing segment's destination is another
// dated named city leg of this trip — the leg whose ARRIVAL the segment
// serves, and therefore its owner: that city's own set_leg_dates destMatches
// it and moves it by that leg's start delta. Returns the owning run's hub
// ("" when the destination matches no other dated named run — a journey-home
// or out-of-trip destination, which the end side may carry). Any other run
// qualifies, not just the next one: a revisit's return segment belongs to the
// revisit leg, and the matching is the same fuzzyMatch the loop applies to
// this hub's own endpoints.
func segDestLegHub(runs []legRun, selfIdx int, dest string) string {
	destLower := strings.ToLower(strings.TrimSpace(dest))
	if destLower == "" {
		return ""
	}
	for i, r := range runs {
		if i == selfIdx || r.minDay < 1 || r.hub == "" {
			continue
		}
		if fuzzyMatch(destLower, strings.ToLower(r.hub)) {
			return r.hub
		}
	}
	return ""
}

// prevDatedRunIdx finds the nearest movable neighbor before a run — the leg
// whose confirmed stay, when it has one, pins the boundary this leg's start
// must drag along. Hubless or undated filler runs are skipped. -1 when there
// is none. (Its next-side twin died with the raw-span neighbour narration:
// everything said about a following leg now reads the rendered legs.)
func prevDatedRunIdx(runs []legRun, i int) int {
	for j := i - 1; j >= 0; j-- {
		if runs[j].minDay >= 1 && runs[j].hub != "" {
			return j
		}
	}
	return -1
}
