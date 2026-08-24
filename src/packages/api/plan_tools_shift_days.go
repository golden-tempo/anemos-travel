package main

// shift_days_from (specs/leg-departure-dates, ticket 3): move a SUFFIX of the
// traveler's saved trip by whole days, starting at one city's arrival. The
// missing primitive behind the four-city march of 2026-08-23: "give Prague
// another night" had to be four set_leg_dates calls, each endpoint-anchored
// and each taking the night off the city after it — set_leg_dates' own result
// instructs that chain, because one leg is all it can ever move. Here the cut
// is BY DAY, not by leg: every itinerary item on or after the pivot city's
// arrival day shifts, every stay/segment/booking-todo date on or after the
// pivot date rides along, and the trip's end date moves by the same delta.
// Cities before the pivot are untouched, so the city immediately before it
// gains (or loses) exactly `days` nights and nothing downstream is robbed.
//
// The writes are the set_trip_dates machinery with a day floor — the
// ShiftItineraryItemDaysFrom / Shift*DatesFrom queries, raw UPDATEs so auto
// drafts ride WITHOUT being confirmed (the per-row Update* statements all set
// auto = false). Two membership rules, deliberately different: a stay's two
// dates are two independent leg boundaries, so each date shifts on its own
// (a straddling stay keeps its check-in and rides its check-out — that IS the
// predecessor gaining its nights); a segment's two dates are one physical
// journey, so it moves as a unit, membership decided by where it LANDS.
// Booking-todo dates follow the stay rule (a round-trip flight todo departs
// before the pivot and returns after it; only the return moves).
//
// Transaction shape is set_leg_dates': GetTripForUpdate row lock, TouchTrip,
// trip_updated SSE, recordEvent, collaborator-edit signal. Addressing reuses
// legRuns/matchLegRuns plus replace_leg's parseLegAddress, so 'Lisbon#2'
// names a revisit instead of being refused. Guard derivations go through
// computeTripLegs — never a re-derived span, which is the defect this whole
// spec exists to remove.

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

var shiftDaysFromTool = anthropic.ToolParam{
	Name: "shift_days_from",
	Description: anthropic.String("Shift the rest of the traveler's saved trip by whole days, starting at one city — the way to give a city more or fewer nights without re-planning anything after it. " +
		"Everything from that city's arrival onward moves together in one step: itinerary days, stay check-ins/check-outs, transport, dated booking to-dos, and the trip's end date. Cities BEFORE it keep their dates exactly, so the city immediately before gains (positive days) or loses (negative days) that many nights. " +
		"'Give Prague another night' = one shift_days_from call with the city AFTER Prague and days=1 — never a chain of set_leg_dates calls city by city. " +
		"Use set_trip_dates to move the WHOLE trip, and set_leg_dates to change one city's dates in place. " +
		"Only the saved plan changes: anything already booked with a real provider keeps its original dates, so remind the traveler to re-check those bookings."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"city": map[string]any{
				"type":        "string",
				"description": "The first city that moves — everything from its arrival onward shifts. Use its name as it appears in the itinerary; if the trip visits it twice, say which visit with 'Lisbon#2'.",
			},
			"days": map[string]any{
				"type":        "integer",
				"description": "Whole days to shift by: positive pushes the rest of the trip later, negative pulls it earlier. Must not be 0.",
			},
		},
		Required: []string{"city", "days"},
	},
}

// renderedLegForRun maps a legRun onto the RenderLeg computeTripLegs derived
// for the same stretch of the itinerary. Positions are the join key: both
// walk items in position order, so a run's first item falls inside exactly
// one rendered leg's [FirstPos, LastPos]. The two groupings split hubless
// items differently, which is why this maps by position instead of assuming
// index parity. Nil when the run carries no items or no leg spans it.
func renderedLegForRun(legs []RenderLeg, run legRun) *RenderLeg {
	if len(run.items) == 0 {
		return nil
	}
	pos := run.items[0].Position
	for i := range legs {
		if legs[i].FirstPos <= pos && pos <= legs[i].LastPos {
			return &legs[i]
		}
	}
	return nil
}

// simulateShiftFrom applies the suffix shift to in-memory copies of the trip,
// its items and its stays — the same per-date rules the SQL writes use — so a
// guard can ask computeTripLegs about the post-state before anything is
// written. Pure; the inputs are never mutated.
func simulateShiftFrom(trip store.Trip, items []store.ItineraryItem, stays []store.Accommodation, pivotDay, days int) (store.Trip, []store.ItineraryItem, []store.Accommodation) {
	pivotDate := trip.StartDate.Time.AddDate(0, 0, pivotDay-1)
	simItems := make([]store.ItineraryItem, len(items))
	for i, it := range items {
		simItems[i] = it
		if it.Day != nil && int(*it.Day) >= pivotDay {
			d := *it.Day + int32(days)
			simItems[i].Day = &d
		}
	}
	simStays := make([]store.Accommodation, len(stays))
	for i, a := range stays {
		simStays[i] = a
		if a.CheckIn.Valid && !a.CheckIn.Time.Before(pivotDate) {
			simStays[i].CheckIn = pgtype.Date{Time: a.CheckIn.Time.AddDate(0, 0, days), Valid: true}
		}
		if a.CheckOut.Valid && !a.CheckOut.Time.Before(pivotDate) {
			simStays[i].CheckOut = pgtype.Date{Time: a.CheckOut.Time.AddDate(0, 0, days), Valid: true}
		}
	}
	simTrip := trip
	if trip.EndDate.Valid {
		simTrip.EndDate = pgtype.Date{Time: trip.EndDate.Time.AddDate(0, 0, days), Valid: true}
	}
	return simTrip, simItems, simStays
}

// shiftCollapseRefusal names the city a negative shift would swallow, or ""
// when the shift is safe. It simulates the shift and asks the ONE derivation
// (computeTripLegs) whether the leg rendered immediately before the pivot
// ends up at zero nights — never its own span math, so when the leg-end rule
// changes (specs/leg-departure-dates ticket 1) this guard's threshold moves
// with it, by construction.
func shiftCollapseRefusal(trip store.Trip, items []store.ItineraryItem, stays []store.Accommodation, run legRun, pivotDay, days int) string {
	simTrip, simItems, simStays := simulateShiftFrom(trip, items, stays, pivotDay, days)
	legs := computeTripLegs(simTrip, simItems, simStays)
	pivotLeg := renderedLegForRun(legs, run)
	if pivotLeg == nil {
		return ""
	}
	var prev *RenderLeg
	for i := range legs {
		if &legs[i] == pivotLeg {
			break
		}
		if legs[i].Start != nil && legs[i].End != nil {
			prev = &legs[i]
		}
	}
	if prev == nil {
		return ""
	}
	if prev.ZeroNight || nightsBetween(*prev.Start, *prev.End) <= 0 {
		return fmt.Sprintf("Refused: shifting everything from %s %d day(s) earlier would leave %s with ZERO nights — the shift would swallow the city before the pivot, which is exactly the theft this tool exists to prevent. Nothing was changed. Shift by fewer days, or if the traveler really wants %s shortened, change its dates deliberately with set_leg_dates.",
			run.hub, -days, prev.Label, prev.Label)
	}
	return ""
}

func runShiftDaysFromTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		City string `json:"city"`
		Days int    `json:"days"`
	}
	json.Unmarshal(input, &in)

	if !s.authed {
		return "The traveler isn't signed in, so there's no saved trip to change. Give the advice in your reply instead.", true
	}
	if dbPool == nil {
		return "Saved trips are unavailable right now (persistence offline).", true
	}
	if strings.TrimSpace(in.City) == "" {
		return "city is required — the first city that should move, as it appears in the itinerary.", true
	}

	tid, msg, failed := resolveDateShiftTrip(s)
	if failed {
		return msg, true
	}

	tx, err := dbPool.Begin(s.ctx)
	if err != nil {
		return "Could not shift the trip's days right now.", true
	}
	defer tx.Rollback(s.ctx)
	q := store.New(tx)

	// Same row lock replaceTripSection, set_trip_dates and set_leg_dates take:
	// serializes the suffix shift against concurrent rewrites and other date
	// moves on this trip.
	trip, err := q.GetTripForUpdate(s.ctx, tid)
	if err != nil {
		return "Could not load the trip to shift its days.", true
	}
	if !trip.StartDate.Valid {
		return "This trip has no dates yet, so there is no calendar to shift along. Set the trip's dates first with set_trip_dates.", true
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

	runs := legRuns(items)
	addr := parseLegAddress(in.City)
	matched := matchLegRuns(runs, addr.hub)
	if len(matched) == 0 {
		if legs := legsSummary(runs, stays, tripStart); legs != "" {
			return fmt.Sprintf("No leg for '%s' in this trip. The legs are: %s. Use the city name as it appears in the itinerary.", addr.hub, legs), true
		}
		return "This trip's itinerary has no day-numbered city legs to shift from. Use set_trip_dates to move the whole trip instead.", true
	}
	if addr.visit > len(matched) {
		return fmt.Sprintf("The itinerary has %d dated visit(s) to %s, so there is no visit #%d, and nothing was changed. Say the city bare for a single visit, or '%s#2' for the second.",
			len(matched), runs[matched[0]].hub, addr.visit, runs[matched[0]].hub), true
	}
	runIdx := matched[0]
	if addr.visit > 0 {
		runIdx = matched[addr.visit-1]
	} else if len(matched) > 1 {
		// Rendered spans, not raw item-day math, label the choices: anything
		// speaking about the dates on screen derives from the dates on screen
		// (plan_leg_dates.go's renderedLegRange rule).
		legsNow := computeTripLegs(trip, items, stays)
		var opts []string
		for n, i := range matched {
			label := fmt.Sprintf("%s#%d", runs[i].hub, n+1)
			if leg := renderedLegForRun(legsNow, runs[i]); leg != nil && leg.Start != nil && leg.End != nil {
				opts = append(opts, fmt.Sprintf("%s (%s)", label, legRangeText(*leg.Start, *leg.End)))
			} else {
				opts = append(opts, label)
			}
		}
		return fmt.Sprintf("The itinerary visits %s more than once, so '%s' doesn't say where the shift starts, and nothing was changed. Name one of: %s.",
			runs[matched[0]].hub, in.City, strings.Join(opts, ", ")), true
	}
	run := runs[runIdx]

	// The first dated city has no predecessor to gain or lose nights, and its
	// arrival IS the trip's start date — a shift "from" it is really a
	// whole-trip move wearing the wrong tool.
	if runIdx == firstDatedRunIdx(runs) {
		return fmt.Sprintf("%s is the trip's first city — there is no city before it to give nights to, and its arrival IS the trip's start date (%s). To move the WHOLE trip use set_trip_dates; to change how long %s is, call shift_days_from with the city AFTER it.",
			run.hub, tripStart.Format(dateLayout), run.hub), true
	}

	pivotDay := run.minDay
	pivotDate := tripStart.AddDate(0, 0, pivotDay-1)

	// Honest no-op (the set_leg_dates pattern): nothing is committed — no
	// touched updated_at, no trip_updated SSE (the client must not flash
	// "Trip updated"), no analytics — and the result reports the ACTUAL saved
	// state, never an echo of the request.
	if in.Days == 0 {
		var b strings.Builder
		fmt.Fprintf(&b, "No saved rows changed: days must be a non-zero whole number (positive = later, negative = earlier). %s's leg currently starts on trip day %d (%s)", run.hub, pivotDay, pivotDate.Format(dateLayout))
		if trip.EndDate.Valid {
			fmt.Fprintf(&b, " and the trip ends %s", trip.EndDate.Time.Format(dateLayout))
		}
		b.WriteString(". The trip page was NOT refreshed; never tell the traveler anything changed.")
		return b.String(), false
	}

	// Day floor: item days are anchored to the trip's first day. Refuse, never
	// clamp — a clamp would silently compress the very nights the caller is
	// trying to move — and name the city that would fall off the calendar.
	if pivotDay+in.Days < 1 {
		return fmt.Sprintf("Shifting by %d would move %s's arrival to trip day %d — before the trip's first day (%s). %s can move at most %d day(s) earlier. Nothing was changed; to start the whole trip earlier use set_trip_dates.",
			in.Days, run.hub, pivotDay+in.Days, tripStart.Format(dateLayout), run.hub, pivotDay-1), true
	}
	if in.Days < 0 {
		if refusal := shiftCollapseRefusal(trip, items, stays, run, pivotDay, in.Days); refusal != "" {
			return refusal, true
		}
	}

	days32 := int32(in.Days)
	itemsMoved, err := q.ShiftItineraryItemDaysFrom(s.ctx, store.ShiftItineraryItemDaysFromParams{
		TripID: tid, FromDay: int32(pivotDay), Days: days32,
	})
	if err != nil {
		return "Could not shift the itinerary's days.", true
	}
	fromDate := pgtype.Date{Time: pivotDate, Valid: true}
	staysMoved, err := q.ShiftAccommodationDatesFrom(s.ctx, store.ShiftAccommodationDatesFromParams{
		TripID: tid, FromDate: fromDate, Days: days32,
	})
	if err != nil {
		return "Could not shift the trip's stays with the days.", true
	}
	segsMoved, err := q.ShiftSegmentDatesFrom(s.ctx, store.ShiftSegmentDatesFromParams{
		TripID: tid, FromDate: fromDate, Days: days32,
	})
	if err != nil {
		return "Could not shift the trip's transport legs with the days.", true
	}
	todosMoved, err := q.ShiftBookingTodoDatesFrom(s.ctx, store.ShiftBookingTodoDatesFromParams{
		TripID: tid, FromDate: fromDate, Days: days32,
	})
	if err != nil {
		return "Could not shift the trip's booking to-dos with the days.", true
	}
	// The end date always rides the shift: keeping it fixed would just
	// relocate the theft to the last city.
	tripEndShifted := false
	var newEnd time.Time
	if trip.EndDate.Valid {
		newEnd = trip.EndDate.Time.AddDate(0, 0, in.Days)
		if err := q.SetTripDates(s.ctx, store.SetTripDatesParams{
			ID: tid, StartDate: trip.StartDate, EndDate: pgtype.Date{Time: newEnd, Valid: true},
		}); err != nil {
			return "Could not shift the trip's end date.", true
		}
		tripEndShifted = true
	}

	if err := q.TouchTrip(s.ctx, store.TouchTripParams{
		ID: tid, UpdatedBy: pgtype.UUID{Bytes: s.uid, Valid: true},
	}); err != nil {
		return "Could not shift the trip's days.", true
	}
	if err := tx.Commit(s.ctx); err != nil {
		return "Could not shift the trip's days.", true
	}

	sendSSE(s.w, "trip_updated", map[string]string{"trip_id": tid.String()})
	s.itineraryEmitted = true
	s.tripID = &tid
	ownerID := trip.UserID
	safeGo("recordEvent", func() {
		recordEvent(s.uid, "agent_days_shifted", &tid, map[string]any{
			"from_city":        run.hub,
			"days":             in.Days,
			"items":            itemsMoved,
			"stays":            staysMoved,
			"segments":         segsMoved,
			"todos":            todosMoved,
			"trip_end_shifted": tripEndShifted,
			"is_collaborator":  s.uid != ownerID,
		})
	})
	// Same collaborator-edit signal as touchTripAs; self-gated in SQL for
	// owner actors.
	if s.uid != ownerID {
		safeGo("notifyCollabEdit", func() { notifyCollabEdit(tid, s.uid) })
	}

	direction, n := "later", in.Days
	if n < 0 {
		direction, n = "earlier", -n
	}
	var b strings.Builder
	fmt.Fprintf(&b, "Everything from %s onward moved %d day(s) %s; cities before it kept their dates.", run.hub, n, direction)
	fmt.Fprintf(&b, " Moved: %d itinerary item(s), %d stay(s), %d transport leg(s), %d booking to-do(s); undated ones were left untouched.", itemsMoved, staysMoved, segsMoved, todosMoved)
	if tripEndShifted {
		fmt.Fprintf(&b, " The trip now ends %s.", newEnd.Format(dateLayout))
	} else {
		b.WriteString(" This trip has no end date saved, so only day numbers and dated children moved.")
	}
	// The post-state the traveler will SEE, from THE derivation — the
	// set_leg_dates result convention. legsRenderSummary leads with its
	// warning line, so a collapse the guard's derivation couldn't foresee is
	// named in this same result instead of surviving a successful write.
	if legs := postShiftRenderedLegs(s, tid); legs != "" {
		b.WriteString(" The page now renders these city legs:\n" + legs +
			"That, not day arithmetic, is what the traveler sees — relay any range that doesn't match what they asked for.")
	}
	b.WriteString(" IMPORTANT: anything already booked with a real provider (flights, hotels, ferries) still holds its ORIGINAL dates — remind the traveler to re-check and rebook those. The traveler's trip page has refreshed.")
	return b.String(), false
}

// postShiftRenderedLegs re-reads the trip a shift just committed and returns
// the rendered city legs (legsRenderSummary, warning line included). Best-
// effort by design: the write has already committed, so a failed read costs
// the extra sentences, never the result.
func postShiftRenderedLegs(s *planSession, tripID uuid.UUID) string {
	q := store.New(dbPool)
	trip, err := q.GetEditableTripByID(s.ctx, store.GetEditableTripByIDParams{ID: tripID, UserID: s.uid})
	if err != nil {
		return ""
	}
	items, err := q.GetItineraryItemsByTrip(s.ctx, tripID)
	if err != nil {
		return ""
	}
	stays, err := q.ListAccommodationsByTrip(s.ctx, tripID)
	if err != nil {
		return ""
	}
	return legsRenderSummary(trip, items, stays)
}
