package main

// set_leg_dates (specs/set-leg-dates + specs/leg-departure-dates ticket 2):
// one city leg's dates move, the rest of the trip doesn't. Items are
// START-anchored — they carry the leg's arrival and are never dragged onto a
// departure day — and a PREVIOUS leg pinned by a confirmed stay has its
// check-out extended to meet a later start (computeTripLegs would otherwise
// pull the moved leg's rendered start back to that check-out). An explicit
// end_date is honoured only where the departure lives on this leg's own rows
// (stay check-out, or the trip end for the final leg); elsewhere it refuses
// and steers. Every range a result states about any leg comes from
// computeTripLegs — the acceptance-5 sweep below asserts it date by date.
// Unit tables cover the pure run-splitting and delta math; the DB tests
// assert the headline dogfood scenario (Panama City -> LA -> EWR, "change LA
// to Sep 24-27"), the placeholder start-carrier shape, honest zero-change
// results (no commit, no trip_updated), the end_date gate's three verdicts,
// the shrink clamp, the auto-draft skip, overlap narration from rendered
// spans, validation atomicity, collaborator authz, and lineage resolution on
// a later turn.

import (
	"context"
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

func TestComputeLegDateChange(t *testing.T) {
	newEnd := func(s string) *time.Time { d := civilDate(s); return &d }
	cases := []struct {
		name           string
		tripStart      string
		oldStart       string
		oldEnd         string
		newStart       string
		newEnd         *time.Time
		wantStartDelta int
		wantEndDelta   int
		wantStartIdx   int
		wantEndIdx     int
		wantErr        error
	}{
		// The dogfood case: leg length changes, so the deltas differ (+4/+3).
		{"grow-shift differing deltas", "2026-09-15", "2026-09-20", "2026-09-24", "2026-09-24", newEnd("2026-09-27"), 4, 3, 10, 13, nil},
		{"omitted end preserves length", "2026-09-15", "2026-09-20", "2026-09-24", "2026-09-24", nil, 4, 4, 10, 14, nil},
		{"shift earlier is negative", "2026-09-15", "2026-09-20", "2026-09-24", "2026-09-18", nil, -2, -2, 4, 8, nil},
		{"leg to trip's first day", "2026-09-15", "2026-09-20", "2026-09-24", "2026-09-15", newEnd("2026-09-18"), -5, -6, 1, 4, nil},
		{"end before start errors", "2026-09-15", "2026-09-20", "2026-09-24", "2026-09-24", newEnd("2026-09-23"), 0, 0, 0, 0, errLegEndBeforeStart},
		{"start before trip errors", "2026-09-15", "2026-09-20", "2026-09-24", "2026-09-14", nil, 0, 0, 0, 0, errLegBeforeTripStart},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ch, err := computeLegDateChange(civilDate(tc.tripStart), civilDate(tc.oldStart), civilDate(tc.oldEnd), civilDate(tc.newStart), tc.newEnd)
			if tc.wantErr != nil {
				if err != tc.wantErr {
					t.Fatalf("err = %v, want %v", err, tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if ch.startDelta != tc.wantStartDelta || ch.endDelta != tc.wantEndDelta {
				t.Fatalf("deltas = %d/%d, want %d/%d", ch.startDelta, ch.endDelta, tc.wantStartDelta, tc.wantEndDelta)
			}
			if ch.newStartIdx != tc.wantStartIdx || ch.newEndIdx != tc.wantEndIdx {
				t.Fatalf("indices = %d/%d, want %d/%d", ch.newStartIdx, ch.newEndIdx, tc.wantStartIdx, tc.wantEndIdx)
			}
		})
	}
}

// legItem builds an in-memory item for the pure run-splitting tests.
func legItem(pos int, city, dayTripFrom string, day int) store.ItineraryItem {
	it := store.ItineraryItem{Position: int32(pos), Name: fmt.Sprintf("p%d", pos)}
	if city != "" {
		it.City = &city
	}
	if dayTripFrom != "" {
		it.DayTripFrom = &dayTripFrom
	}
	if day > 0 {
		d := int32(day)
		it.Day = &d
	}
	return it
}

func TestLegRunsAndMatching(t *testing.T) {
	items := []store.ItineraryItem{
		legItem(0, "", "", 1), // hubless start adopts the first named hub
		legItem(1, "Panama City", "", 1),
		legItem(2, "Panama City", "", 2),
		legItem(3, "Taboga Island", "Panama City", 3), // day trip rides its hub
		legItem(4, "Los Angeles", "", 4),
		legItem(5, "", "", 0), // hubless, undated: adopts current run
		legItem(6, "Los Angeles", "", 5),
		legItem(7, "Panama City", "", 6), // revisit: a separate third run
	}
	runs := legRuns(items)
	if len(runs) != 3 {
		t.Fatalf("runs = %d (%+v), want 3", len(runs), runs)
	}
	if runs[0].hub != "Panama City" || runs[0].minDay != 1 || runs[0].maxDay != 3 || len(runs[0].items) != 4 {
		t.Fatalf("run 0 = %s days %d-%d (%d items), want Panama City 1-3 (4 items)", runs[0].hub, runs[0].minDay, runs[0].maxDay, len(runs[0].items))
	}
	if runs[1].hub != "Los Angeles" || runs[1].minDay != 4 || runs[1].maxDay != 5 || len(runs[1].items) != 3 {
		t.Fatalf("run 1 = %s days %d-%d (%d items), want Los Angeles 4-5 (3 items)", runs[1].hub, runs[1].minDay, runs[1].maxDay, len(runs[1].items))
	}
	if runs[2].hub != "Panama City" || runs[2].minDay != 6 {
		t.Fatalf("run 2 = %s day %d, want the Panama City revisit on 6", runs[2].hub, runs[2].minDay)
	}

	if got := matchLegRuns(runs, "los angeles"); len(got) != 1 || got[0] != 1 {
		t.Fatalf("matchLegRuns(los angeles) = %v, want [1]", got)
	}
	// A revisited city matches both of its runs — the handler errors on that.
	if got := matchLegRuns(runs, "Panama City"); len(got) != 2 {
		t.Fatalf("matchLegRuns(Panama City) = %v, want two runs", got)
	}
	// Fuzzy fallback only when nothing matches exactly.
	if got := matchLegRuns(runs, "Angeles"); len(got) != 1 || got[0] != 1 {
		t.Fatalf("matchLegRuns(Angeles) = %v, want fuzzy [1]", got)
	}
	if got := matchLegRuns(runs, "Tokyo"); len(got) != 0 {
		t.Fatalf("matchLegRuns(Tokyo) = %v, want none", got)
	}

	// An all-undated run has no calendar footprint and is unmatchable.
	undated := legRuns([]store.ItineraryItem{legItem(0, "Lima", "", 0)})
	if got := matchLegRuns(undated, "Lima"); len(got) != 0 {
		t.Fatalf("matchLegRuns on undated run = %v, want none", got)
	}
}

// legsRenderSummary is the model-facing render truth: first-leg anchor and the
// boundary rule (a leg runs until the next leg's arrival) both flow through,
// one line per dated leg — each carrying its NIGHT COUNT and how its span was
// decided (specs/shape-before-schedule). A city whose places carry no day
// numbers gets an equal share of the trip invented for it, which looks exactly
// like a real range unless its provenance is named.
//
// Berlin lands zero-night here and raises no warning on purpose: it renders
// LAST (the trip has no end date, so its single item day is all it has), and
// the last leg legitimately ends on the day the traveler flies home.
// TestLegsRenderWarning covers the case that does warn.
//
// The "Unplanned stretches" soft block leads on this placeholder-shaped trip
// and that is deliberate: each city's single item is its arrival marker, so
// the tail nights genuinely hold no plans — a true, softly-framed fact
// ("mention, don't fix"), not a render defect. It is also the honest
// replacement for the retired "gap between legs" narration: the unplanned
// nights sit INSIDE Prague, they are not a hole between Prague and Kraków.
func TestLegsRenderSummary(t *testing.T) {
	items := []store.ItineraryItem{
		legItem(0, "Prague", "", 4),  // first leg, anchored to trip start
		legItem(1, "Kraków", "", 10), // Sep 2 — Prague runs to this arrival
		legItem(2, "Berlin", "", 12), // Sep 4
	}
	got := legsRenderSummary(rlTrip("2026-08-24", ""), items, nil)
	want := "Unplanned stretches — true on the page, fine if intended (mention, don't fix): " +
		"Prague renders 2026-08-24 to 2026-09-02 (9 nights) but its last place is 2026-08-27 — 6 nights with nothing planned; " +
		"Kraków renders 2026-09-02 to 2026-09-04 (2 nights) but its last place is 2026-09-02 — 2 nights with nothing planned.\n" +
		"- Prague: 2026-08-24 to 2026-09-02 (9 nights, dated by its places)\n" +
		"- Kraków: 2026-09-02 to 2026-09-04 (2 nights, dated by its places)\n" +
		"- Berlin: 2026-09-04 to 2026-09-04 (0 nights, dated by its places)\n"
	if got != want {
		t.Fatalf("legsRenderSummary =\n%s\nwant\n%s", got, want)
	}
	if legsRenderSummary(rlTrip("2026-08-24", ""), nil, nil) != "" {
		t.Fatal("empty itinerary should yield an empty summary")
	}
}

// seedMultiCityTrip builds the dogfood trip: Sep 15-24, Panama City days 1-6
// then Los Angeles days 6-9, confirmed stays for both (PC by address, LA by
// name), the two boundary flights, and one auto draft stay for LA that must
// never move or confirm.
func seedMultiCityTrip(t *testing.T, trip store.Trip, owner uuid.UUID) {
	t.Helper()
	ctx := context.Background()
	q := store.New(dbPool)
	if _, err := q.UpdateTrip(ctx, store.UpdateTripParams{
		ID: trip.ID, UserID: owner,
		StartDate: validDate("2026-09-15"), EndDate: validDate("2026-09-24"),
	}); err != nil {
		t.Fatalf("seed trip dates: %v", err)
	}
	seed := func(pos int, name, city string, day int) {
		t.Helper()
		d := int32(day)
		if _, err := q.CreateItineraryItem(ctx, store.CreateItineraryItemParams{
			TripID: trip.ID, Position: int32(pos), Name: name, City: &city, Day: &d,
			Latitude: 8.98 + float64(pos)*0.01, Longitude: -79.52,
		}); err != nil {
			t.Fatalf("seed item %s: %v", name, err)
		}
	}
	for i := 0; i < 6; i++ {
		seed(i, fmt.Sprintf("PC Spot %d", i+1), "Panama City", i+1)
	}
	for i := 0; i < 4; i++ {
		seed(6+i, fmt.Sprintf("LA Spot %d", i+1), "Los Angeles", 6+i)
	}
	pcAddr := "Casco Viejo, Panama City, Panama"
	if _, err := q.CreateAccommodation(ctx, store.CreateAccommodationParams{
		TripID: trip.ID, Name: "Hotel Casco Viejo", Address: &pcAddr,
		CheckIn: validDate("2026-09-15"), CheckOut: validDate("2026-09-20"),
	}); err != nil {
		t.Fatalf("seed PC stay: %v", err)
	}
	if _, err := q.CreateAccommodation(ctx, store.CreateAccommodationParams{
		TripID: trip.ID, Name: "Stay in Los Angeles",
		CheckIn: validDate("2026-09-20"), CheckOut: validDate("2026-09-24"),
	}); err != nil {
		t.Fatalf("seed LA stay: %v", err)
	}
	draftKey := "stay:los angeles"
	if _, err := q.UpsertDraftAccommodation(ctx, store.UpsertDraftAccommodationParams{
		TripID: trip.ID, Name: "Suggested stay in Los Angeles", AutoKey: &draftKey,
		CheckIn: validDate("2026-09-20"), CheckOut: validDate("2026-09-24"),
	}); err != nil {
		t.Fatalf("seed LA draft: %v", err)
	}
	pc, la, ewr := "Panama City", "Los Angeles", "Newark"
	if _, err := q.CreateSegment(ctx, store.CreateSegmentParams{
		TripID: trip.ID, Mode: "flight", Origin: &pc, Destination: &la,
		DepartDate: validDate("2026-09-20"), ArriveDate: validDate("2026-09-20"),
	}); err != nil {
		t.Fatalf("seed arrival segment: %v", err)
	}
	if _, err := q.CreateSegment(ctx, store.CreateSegmentParams{
		TripID: trip.ID, Mode: "flight", Origin: &la, Destination: &ewr,
		DepartDate: validDate("2026-09-24"),
	}); err != nil {
		t.Fatalf("seed departure segment: %v", err)
	}
}

func legDays(t *testing.T, tripID uuid.UUID, city string) []int {
	t.Helper()
	rows, err := dbPool.Query(context.Background(),
		`SELECT day FROM itinerary_items WHERE trip_id = $1 AND city = $2 ORDER BY position`, tripID, city)
	if err != nil {
		t.Fatalf("legDays query: %v", err)
	}
	defer rows.Close()
	var days []int
	for rows.Next() {
		var d int
		if err := rows.Scan(&d); err != nil {
			t.Fatalf("legDays scan: %v", err)
		}
		days = append(days, d)
	}
	return days
}

func daysEqual(a []int, b ...int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

var legDateRe = regexp.MustCompile(`\d{4}-\d{2}-\d{2}`)

// assertDatesFromRenderedLegs is acceptance 5 of specs/leg-departure-dates,
// date by date: every YYYY-MM-DD a set_leg_dates result states must be a date
// the trip's CURRENT rendered legs also state — or the trip row's own dates,
// a saved item's calendar day (results may cite where places sit), or a date
// the caller's ask itself supplied (extra). Anything else is a number from a
// derivation the page doesn't render, the class of defect that produced the
// "2-night gap" report over a gapless screen.
func assertDatesFromRenderedLegs(t *testing.T, msg string, tripID, ownerID uuid.UUID, extra ...string) {
	t.Helper()
	ctx := context.Background()
	q := store.New(dbPool)
	trip, err := q.GetEditableTripByID(ctx, store.GetEditableTripByIDParams{ID: tripID, UserID: ownerID})
	if err != nil {
		t.Fatalf("sweep trip read: %v", err)
	}
	items, err := q.GetItineraryItemsByTrip(ctx, tripID)
	if err != nil {
		t.Fatalf("sweep items read: %v", err)
	}
	stays, err := q.ListAccommodationsByTrip(ctx, tripID)
	if err != nil {
		t.Fatalf("sweep stays read: %v", err)
	}
	allowed := map[string]bool{}
	for _, d := range extra {
		allowed[d] = true
	}
	if trip.StartDate.Valid {
		allowed[trip.StartDate.Time.Format(dateLayout)] = true
		for _, it := range items {
			if it.Day != nil && *it.Day >= 1 {
				allowed[trip.StartDate.Time.AddDate(0, 0, int(*it.Day)-1).Format(dateLayout)] = true
			}
		}
	}
	if trip.EndDate.Valid {
		allowed[trip.EndDate.Time.Format(dateLayout)] = true
	}
	for _, leg := range computeTripLegs(trip, items, stays) {
		if leg.Start != nil {
			allowed[leg.Start.Format(dateLayout)] = true
		}
		if leg.End != nil {
			allowed[leg.End.Format(dateLayout)] = true
		}
	}
	for _, d := range legDateRe.FindAllString(msg, -1) {
		if !allowed[d] {
			t.Fatalf("result states %s, a date neither the rendered legs, the trip row, the saved items, nor the ask carries:\n%s", d, msg)
		}
	}
}

// The headline dogfood scenario: "change LA to Sep 24-27" moves the LA items,
// stay, and boundary flights (by DIFFERENT deltas), extends the trip end,
// drags Panama City's stay check-out to the new arrival (boundary extension),
// and leaves PC's items and the auto draft untouched.
func TestPlanSetLegDatesMovesOneLeg(t *testing.T) {
	resetDB(t)
	fa := newFakeAnthropic(t,
		toolTurn("set_leg_dates", `{"city":"Los Angeles","start_date":"2026-09-24","end_date":"2026-09-27"}`),
		textTurn("LA is now Sep 24-27; that opens a gap after Panama City — want me to extend that stay?"))

	user, token := createTestUser(t, "legmover@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedMultiCityTrip(t, trip, user.ID)

	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		TripID:   trip.ID.String(),
		Messages: []PlanChatMessage{{Role: "user", Content: "change the dates for LA to sep 24-27"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}
	events := planEvents(t, rec.Body.String())
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}
	updated := eventsOfType(events, "trip_updated")
	if len(updated) != 1 || eventData(updated[0])["trip_id"] != trip.ID.String() {
		t.Fatalf("trip_updated events = %v, want exactly one for trip %s", updated, trip.ID)
	}

	// SSE tool_result events carry only the tool name; the result text rides
	// the follow-up model request. The gap narration must be deterministic.
	reqs := fa.requestBodies()
	if len(reqs) < 2 {
		t.Fatalf("model requests = %d, want >= 2 (tool round-trip)", len(reqs))
	}
	followUp := string(reqs[1])
	for _, want := range []string{
		// The headline and every neighbour range are the PAGE's — from
		// computeTripLegs, re-read after the commit (acceptance 5).
		"Los Angeles is now 2026-09-24 to 2026-09-27 on the trip page (3 nights)",
		"Trip end extended to 2026-09-27",
		"Panama City now ends 2026-09-24 (was 2026-09-20)",
		"check-out moved to match this leg's arrival",
		"The page now renders these city legs:",
		"- Panama City: 2026-09-15 to 2026-09-24",
		"- Los Angeles: 2026-09-24 to 2026-09-27",
		"ORIGINAL dates",
	} {
		if !strings.Contains(followUp, want) {
			t.Fatalf("tool_result round-trip missing %q:\n%s", want, followUp)
		}
	}
	// A date gap between two legs is unrepresentable on the page — no result
	// may claim one. (followUp is the whole model request, and the system
	// prompt still says "gap" until ticket 4 rewrites it, so this pins the
	// retired TOOL strings; TestPlanSetLegDatesResultQuotesOnlyRenderedDates
	// sweeps the bare result text.)
	for _, stale := range []string{"uncovered night(s)", "has no nights left", "set_leg_dates once per leg in order"} {
		if strings.Contains(followUp, stale) {
			t.Fatalf("result carries the retired raw-span NOTE %q:\n%s", stale, followUp)
		}
	}

	if got := legDays(t, trip.ID, "Los Angeles"); !daysEqual(got, 10, 11, 12, 13) {
		t.Fatalf("LA days = %v, want [10 11 12 13]", got)
	}
	if got := legDays(t, trip.ID, "Panama City"); !daysEqual(got, 1, 2, 3, 4, 5, 6) {
		t.Fatalf("PC days = %v, want [1 2 3 4 5 6] untouched", got)
	}
	if start, end := tripDates(t, trip.ID); start != "2026-09-15" || end != "2026-09-27" {
		t.Fatalf("trip dates = %s/%s, want 2026-09-15/2026-09-27", start, end)
	}
	if in, out := scanDates(t, `SELECT check_in, check_out FROM accommodations WHERE trip_id = $1 AND name = $2`, trip.ID, "Stay in Los Angeles"); in != "2026-09-24" || out != "2026-09-27" {
		t.Fatalf("LA stay = %s/%s, want 2026-09-24/2026-09-27", in, out)
	}
	// Boundary extension: PC's check-out follows the new LA arrival; the
	// check-in stays put.
	if in, out := scanDates(t, `SELECT check_in, check_out FROM accommodations WHERE trip_id = $1 AND name = $2`, trip.ID, "Hotel Casco Viejo"); in != "2026-09-15" || out != "2026-09-24" {
		t.Fatalf("PC stay = %s/%s, want 2026-09-15/2026-09-24 (check-out extended)", in, out)
	}
	// The auto draft neither moved nor got confirmed.
	var draftIn *time.Time
	var draftAuto bool
	if err := dbPool.QueryRow(context.Background(),
		`SELECT check_in, auto FROM accommodations WHERE trip_id = $1 AND name = $2`,
		trip.ID, "Suggested stay in Los Angeles").Scan(&draftIn, &draftAuto); err != nil {
		t.Fatalf("draft query: %v", err)
	}
	if !draftAuto || draftIn == nil || draftIn.Format(dateLayout) != "2026-09-20" {
		t.Fatalf("draft = check_in %v auto %v, want untouched 2026-09-20/true", draftIn, draftAuto)
	}
	// Arrival rides the leg start (+4), departure rides the leg end (+3).
	if dep, _ := scanDates(t, `SELECT depart_date, arrive_date FROM trip_segments WHERE trip_id = $1 AND destination = $2`, trip.ID, "Los Angeles"); dep != "2026-09-24" {
		t.Fatalf("arrival segment departs %s, want 2026-09-24", dep)
	}
	if dep, _ := scanDates(t, `SELECT depart_date, arrive_date FROM trip_segments WHERE trip_id = $1 AND origin = $2`, trip.ID, "Los Angeles"); dep != "2026-09-27" {
		t.Fatalf("departure segment departs %s, want 2026-09-27", dep)
	}

	waitForEventCount(t, user.ID, "agent_leg_dates_set", 1)
}

// seedPlaceholderTwoCityTrip is the shape import + placeholder itineraries
// produce (and the real dogfood trip that exposed the invisible-move bug):
// one city-filler item per city, no stays or segments at all. The day values
// were historically written to encode each leg's DEPARTURE; the boundary rule
// reads a leg's items as its ARRIVAL evidence, so this same shape renders
// Panama City Sep 15–24 and Los Angeles Sep 24–27 (the trip end).
func seedPlaceholderTwoCityTrip(t *testing.T, trip store.Trip, owner uuid.UUID) {
	t.Helper()
	ctx := context.Background()
	q := store.New(dbPool)
	if _, err := q.UpdateTrip(ctx, store.UpdateTripParams{
		ID: trip.ID, UserID: owner,
		StartDate: validDate("2026-09-15"), EndDate: validDate("2026-09-27"),
	}); err != nil {
		t.Fatalf("seed trip dates: %v", err)
	}
	for i, leg := range []struct {
		city string
		day  int
	}{{"Panama City", 6}, {"Los Angeles", 10}} {
		d := int32(leg.day)
		city := leg.city
		if _, err := q.CreateItineraryItem(ctx, store.CreateItineraryItemParams{
			TripID: trip.ID, Position: int32(i), Name: leg.city,
			City: &city, Day: &d, Latitude: 8.98, Longitude: -79.52,
		}); err != nil {
			t.Fatalf("seed item %s: %v", leg.city, err)
		}
	}
}

// A single-item placeholder leg is a START-carrier under the boundary rule:
// its one day is the ARRIVAL the screen renders, its end comes from the trip
// (or the next city). "LA Sep 24-27" on this trip asks for exactly what the
// page already shows — LA's item sits on Sep 24 and the trip ends Sep 27 — so
// the honest answer is a no-op that SAYS the page already shows it. The old
// end-anchored renumber instead dragged LA's item to Sep 27 and Panama
// City's to Sep 24, "succeeding" into a corrupted spine that rendered LA as
// a Sep 27 arrival-day visit.
func TestPlanSetLegDatesPlaceholderAlreadyRenderedIsNoOp(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "placeholder@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedPlaceholderTwoCityTrip(t, trip, user.ID)

	s, rec := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runSetLegDatesTool(s, []byte(`{"city":"Los Angeles","start_date":"2026-09-24","end_date":"2026-09-27"}`))
	if isErr {
		t.Fatalf("placeholder no-op errored: %s", msg)
	}
	for _, want := range []string{
		"No saved rows changed",
		"shows this leg as 2026-09-24 to 2026-09-27",
		"was NOT refreshed",
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("result missing %q: %s", want, msg)
		}
	}
	if strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("no-op emitted trip_updated")
	}
	if got := legDays(t, trip.ID, "Los Angeles"); !daysEqual(got, 10) {
		t.Fatalf("LA day = %v, want [10] (Sep 24, the arrival) unmoved", got)
	}
	if got := legDays(t, trip.ID, "Panama City"); !daysEqual(got, 6) {
		t.Fatalf("PC day = %v, want [6] unmoved — item-dated neighbours need no boundary write", got)
	}
	if start, end := tripDates(t, trip.ID); start != "2026-09-15" || end != "2026-09-27" {
		t.Fatalf("trip dates = %s/%s, want unchanged 2026-09-15/2026-09-27", start, end)
	}
}

// A real placeholder move rides the START: "arrive LA Sep 22" lands LA's
// single item on Sep 22 and touches nothing else — Panama City's rendered end
// follows LA's arrival by derivation, with no physical write to its items.
func TestPlanSetLegDatesPlaceholderRidesTheStart(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "placestart@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedPlaceholderTwoCityTrip(t, trip, user.ID)

	s, rec := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runSetLegDatesTool(s, []byte(`{"city":"Los Angeles","start_date":"2026-09-22"}`))
	if isErr {
		t.Fatalf("placeholder start move errored: %s", msg)
	}
	for _, want := range []string{
		"Los Angeles is now 2026-09-22 to 2026-09-27 on the trip page (5 nights)",
		"- Panama City: 2026-09-15 to 2026-09-22",
		"- Los Angeles: 2026-09-22 to 2026-09-27",
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("result missing %q: %s", want, msg)
		}
	}
	if !strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("start move did not emit trip_updated")
	}
	if got := legDays(t, trip.ID, "Los Angeles"); !daysEqual(got, 8) {
		t.Fatalf("LA day = %v, want [8] (Sep 22, the arrival — never an end anchor)", got)
	}
	if got := legDays(t, trip.ID, "Panama City"); !daysEqual(got, 6) {
		t.Fatalf("PC day = %v, want [6] unmoved", got)
	}
	if start, end := tripDates(t, trip.ID); start != "2026-09-15" || end != "2026-09-27" {
		t.Fatalf("trip dates = %s/%s, want unchanged 2026-09-15/2026-09-27", start, end)
	}
}

// Asking for a state the trip already holds must commit nothing, emit NO
// trip_updated (no phantom "Trip updated" chip), and report the ACTUAL saved
// state — the raw item positions labelled as such, the neighbour's RENDERED
// end, and the range the page shows — never echo the requested range as if it
// were achieved. Under the boundary rule "LA Sep 24-27" on this placeholder
// trip is already what the page renders, so the very first call is a no-op:
// the old renumber instead "succeeded" by dragging both cities' items.
func TestPlanSetLegDatesNoOpIsHonest(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "noophonest@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedPlaceholderTwoCityTrip(t, trip, user.ID)
	var touchedAt time.Time
	if err := dbPool.QueryRow(context.Background(),
		`SELECT updated_at FROM trips WHERE id = $1`, trip.ID).Scan(&touchedAt); err != nil {
		t.Fatalf("updated_at query: %v", err)
	}

	s, rec := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runSetLegDatesTool(s, []byte(`{"city":"Los Angeles","start_date":"2026-09-24","end_date":"2026-09-27"}`))
	if isErr {
		t.Fatalf("no-op errored: %s", msg)
	}
	for _, want := range []string{
		"No saved rows changed",
		"itinerary items sit on 2026-09-24 to 2026-09-24 (trip days 10-10)",
		"on the page the previous leg (Panama City) runs through 2026-09-24",
		"shows this leg as 2026-09-24 to 2026-09-27",
		"was NOT refreshed",
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("no-op result missing %q: %s", want, msg)
		}
	}
	if strings.Contains(msg, "already spans") {
		t.Fatalf("no-op result echoes the request as achieved: %s", msg)
	}
	if strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("no-op emitted trip_updated")
	}
	if s.tripID != nil || s.itineraryEmitted {
		t.Fatal("no-op set session itinerary state")
	}
	if got := legDays(t, trip.ID, "Los Angeles"); !daysEqual(got, 10) {
		t.Fatalf("LA day = %v, want [10] unchanged", got)
	}
	var after time.Time
	if err := dbPool.QueryRow(context.Background(),
		`SELECT updated_at FROM trips WHERE id = $1`, trip.ID).Scan(&after); err != nil {
		t.Fatalf("updated_at requery: %v", err)
	}
	if !after.Equal(touchedAt) {
		t.Fatalf("no-op touched the trip: %v -> %v", touchedAt, after)
	}
}

// Moving a leg EARLIER than the previous leg's end never shrinks the
// neighbor — the overlap (two explicit stays covering the same nights, which
// the page really does draw) is narrated from the RENDERED spans for the
// agent to raise instead.
func TestPlanSetLegDatesOverlapNarratesOnly(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "overlap@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedMultiCityTrip(t, trip, user.ID)

	s, _ := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runSetLegDatesTool(s, []byte(`{"city":"Los Angeles","start_date":"2026-09-18","end_date":"2026-09-20"}`))
	if isErr {
		t.Fatalf("overlap move errored: %s", msg)
	}
	for _, want := range []string{
		"Los Angeles is now 2026-09-18 to 2026-09-20 on the trip page (2 nights)",
		"NOTE: Panama City still runs through 2026-09-20 on the page, overlapping this leg's new start",
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("result missing %q: %s", want, msg)
		}
	}
	if in, out := scanDates(t, `SELECT check_in, check_out FROM accommodations WHERE trip_id = $1 AND name = $2`, trip.ID, "Hotel Casco Viejo"); in != "2026-09-15" || out != "2026-09-20" {
		t.Fatalf("PC stay = %s/%s, want untouched (neighbors never shrink)", in, out)
	}
}

// seedPragueKrakowBerlinTrip is Brian's real post-move trip head: single
// placeholder items (read as each city's ARRIVAL evidence under the boundary
// rule), the first city's item sitting past day 1, no stays or segments.
// krakowDay parameterizes the middle leg (9 = sharing Berlin's arrival day,
// 6 = a clean chain, 10 = inverted past Berlin).
func seedPragueKrakowBerlinTrip(t *testing.T, trip store.Trip, owner uuid.UUID, krakowDay int) {
	t.Helper()
	ctx := context.Background()
	q := store.New(dbPool)
	if _, err := q.UpdateTrip(ctx, store.UpdateTripParams{
		ID: trip.ID, UserID: owner,
		StartDate: validDate("2026-08-24"), EndDate: validDate("2026-09-27"),
	}); err != nil {
		t.Fatalf("seed trip dates: %v", err)
	}
	for i, leg := range []struct {
		city string
		day  int
	}{{"Prague", 4}, {"Kraków", krakowDay}, {"Berlin", 9}} {
		d := int32(leg.day)
		city := leg.city
		if _, err := q.CreateItineraryItem(ctx, store.CreateItineraryItemParams{
			TripID: trip.ID, Position: int32(i), Name: leg.city,
			City: &city, Day: &d, Latitude: 50.08, Longitude: 14.44,
		}); err != nil {
			t.Fatalf("seed item %s: %v", leg.city, err)
		}
	}
}

// The first leg's visible start is the trip's start date: asking for exactly
// that state must be an honest no-op whose report QUOTES the anchored range —
// not the collapsed item day — so the model can tell the traveler the page
// already shows what they asked for.
func TestPlanSetLegDatesFirstLegNoOpReportsAnchoredRange(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "firstleg@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedPragueKrakowBerlinTrip(t, trip, user.ID, 9)

	s, rec := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runSetLegDatesTool(s, []byte(`{"city":"Prague","start_date":"2026-08-24"}`))
	if isErr {
		t.Fatalf("first-leg no-op errored: %s", msg)
	}
	for _, want := range []string{
		"No saved rows changed",
		"itinerary items sit on 2026-08-27 to 2026-08-27 (trip days 4-4)",
		// The anchored START is still quoted; the end is Kraków's day-9
		// arrival (Sep 1), the boundary rule — not Prague's own item day.
		"shows this leg as 2026-08-24 to 2026-09-01",
		"was NOT refreshed",
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("no-op result missing %q: %s", want, msg)
		}
	}
	if strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("first-leg no-op emitted trip_updated")
	}
	if got := legDays(t, trip.ID, "Prague"); !daysEqual(got, 4) {
		t.Fatalf("Prague day = %v, want [4] unchanged", got)
	}
}

// An explicit end_date on a leg whose departure belongs to its neighbour
// refuses and steers — including on the FIRST leg, whose old steer text
// promised "call again with the new end_date", a promise the tool no longer
// keeps. The refusal names the next city, quotes only rendered dates, and
// spells the exact replacement call.
func TestPlanSetLegDatesFirstLegEndSteersToNextArrival(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "firstlegend@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedPragueKrakowBerlinTrip(t, trip, user.ID, 9)

	s, rec := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runSetLegDatesTool(s, []byte(`{"city":"Prague","start_date":"2026-08-24","end_date":"2026-08-27"}`))
	if !isErr {
		t.Fatalf("first-leg end change did not refuse: %s", msg)
	}
	for _, want := range []string{
		"Prague's departure day is the next city's arrival",
		"shows Prague ending 2026-09-01 because Kraków arrives then",
		`set_leg_dates(city="Kraków", start_date="2026-08-27")`,
		"shift_days_from",
		"Nothing was changed",
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("steer missing %q: %s", want, msg)
		}
	}
	if strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("refusal emitted trip_updated")
	}
	if got := legDays(t, trip.ID, "Prague"); !daysEqual(got, 4) {
		t.Fatalf("Prague day = %v, want [4] untouched", got)
	}
	if got := legDays(t, trip.ID, "Kraków"); !daysEqual(got, 9) {
		t.Fatalf("Kraków day = %v, want [9] untouched", got)
	}
}

// A first-leg start other than the trip's start date is really a trip-start
// change — honest steer to set_trip_dates, in BOTH directions, nothing moves.
func TestPlanSetLegDatesFirstLegStartSteersToTripDates(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "firststeer@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedPragueKrakowBerlinTrip(t, trip, user.ID, 9)

	s, _ := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	for _, startDate := range []string{"2026-08-25", "2026-08-23"} {
		msg, isErr := runSetLegDatesTool(s, []byte(`{"city":"Prague","start_date":"`+startDate+`","end_date":"2026-08-27"}`))
		if !isErr {
			t.Fatalf("first-leg start %s did not error: %s", startDate, msg)
		}
		for _, want := range []string{"first city", "2026-08-24", "set_trip_dates"} {
			if !strings.Contains(msg, want) {
				t.Fatalf("steer for %s missing %q: %s", startDate, want, msg)
			}
		}
	}
	if got := legDays(t, trip.ID, "Prague"); !daysEqual(got, 4) {
		t.Fatalf("Prague day = %v, want [4] untouched", got)
	}
}

// The squeeze, in its post-boundary-rule shape: an END can no longer consume
// the next leg (an interior end_date refuses), but a START moved onto the
// next city's arrival pinches the MOVED leg to zero nights. The result's
// rendered-legs block carries the warning — computed by the one derivation,
// naming the city that shares the day — and the moved leg's own headline
// states the zero-night range. The acceptance-5 sweep runs here: every date
// this success result states is a date the rendered legs (or the saved
// items, or the trip row) also state.
func TestPlanSetLegDatesStartOntoNextArrivalWarnsZeroNight(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "squeeze@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedPragueKrakowBerlinTrip(t, trip, user.ID, 6)

	s, rec := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runSetLegDatesTool(s, []byte(`{"city":"Kraków","start_date":"2026-09-01"}`))
	if isErr {
		t.Fatalf("zero-night move errored: %s", msg)
	}
	for _, want := range []string{
		"Kraków is now 2026-09-01 to 2026-09-01 on the trip page (0 nights)",
		"WARNING",
		"Kraków renders ZERO nights — the next city (Berlin) arrives on or before it",
		"- Prague: 2026-08-24 to 2026-09-01",
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("result missing %q: %s", want, msg)
		}
	}
	for _, stale := range []string{"has no nights left", "set_leg_dates once per leg in order", "uncovered night(s)"} {
		if strings.Contains(msg, stale) {
			t.Fatalf("result carries the retired raw-span NOTE %q: %s", stale, msg)
		}
	}
	if !strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("zero-night move did not emit trip_updated")
	}
	assertDatesFromRenderedLegs(t, msg, trip.ID, user.ID)
	if got := legDays(t, trip.ID, "Kraków"); !daysEqual(got, 9) {
		t.Fatalf("Kraków day = %v, want [9] (Sep 1, the new arrival)", got)
	}
	if got := legDays(t, trip.ID, "Prague"); !daysEqual(got, 4) {
		t.Fatalf("Prague day = %v, want [4] (item-dated neighbours get no boundary write)", got)
	}
	if got := legDays(t, trip.ID, "Berlin"); !daysEqual(got, 9) {
		t.Fatalf("Berlin day = %v, want [9] (next leg never auto-moves)", got)
	}
}

// An INVERTED pair (Kraków's item day sits past Berlin's) no longer collapses
// Berlin: under the boundary rule Berlin's day-9 item is its ARRIVAL and the
// trip-end anchor runs it to Sep 27, while Kraków is the leg that pinches.
// The no-op report must quote the range the page actually renders — and the
// neighbour's RENDERED end, not its raw item day; and the natural fix ask
// (move Berlin's arrival to Sep 2) must be a real move, not a no-op.
func TestPlanSetLegDatesInvertedLegNoOpQuotesRenderedRange(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "inverted@example.com")
	trip := createTestTrip(t, user.ID, 0)
	// Kraków day 10 (Sep 2) sits AFTER Berlin's day 9 (Sep 1): strict inversion.
	seedPragueKrakowBerlinTrip(t, trip, user.ID, 10)

	s1, rec1 := testPlanSession(true, user.ID)
	s1.boundTripID = &trip.ID
	msg, isErr := runSetLegDatesTool(s1, []byte(`{"city":"Berlin","start_date":"2026-09-01"}`))
	if isErr {
		t.Fatalf("inverted no-op errored: %s", msg)
	}
	for _, want := range []string{
		"No saved rows changed",
		"itinerary items sit on 2026-09-01 to 2026-09-01 (trip days 9-9)",
		// Kraków pinches to a zero-night stop at its own Sep 2 arrival — that
		// is its rendered end, and the only end a result may quote.
		"on the page the previous leg (Kraków) runs through 2026-09-02",
		"shows this leg as 2026-09-01 to 2026-09-27",
		"was NOT refreshed",
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("no-op result missing %q: %s", want, msg)
		}
	}
	if strings.Contains(rec1.Body.String(), "trip_updated") {
		t.Fatal("inverted no-op emitted trip_updated")
	}
	if got := legDays(t, trip.ID, "Berlin"); !daysEqual(got, 9) {
		t.Fatalf("Berlin day = %v, want [9] unchanged", got)
	}

	// The fix: move Berlin's arrival to Sep 2 — a real move.
	s2, rec2 := testPlanSession(true, user.ID)
	s2.boundTripID = &trip.ID
	msg, isErr = runSetLegDatesTool(s2, []byte(`{"city":"Berlin","start_date":"2026-09-02"}`))
	if isErr {
		t.Fatalf("fix move errored: %s", msg)
	}
	if !strings.Contains(msg, "Berlin is now 2026-09-02 to 2026-09-27 on the trip page") {
		t.Fatalf("fix result missing new rendered range: %s", msg)
	}
	if !strings.Contains(rec2.Body.String(), "trip_updated") {
		t.Fatal("fix move did not emit trip_updated")
	}
	if got := legDays(t, trip.ID, "Berlin"); !daysEqual(got, 10) {
		t.Fatalf("Berlin day = %v, want [10] (Sep 2)", got)
	}
}

// Shrinking a leg folds trailing items onto its new last day and says so.
func TestPlanSetLegDatesShrinkClampsItems(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "shrinker@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedMultiCityTrip(t, trip, user.ID)

	s, _ := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runSetLegDatesTool(s, []byte(`{"city":"Los Angeles","start_date":"2026-09-24","end_date":"2026-09-25"}`))
	if isErr {
		t.Fatalf("shrink errored: %s", msg)
	}
	// Items ride the start (+4 → days 10..13); the window ends day 11, so days
	// 12 and 13 both fold — no end-carrier exemption exists anymore.
	for _, want := range []string{"folded onto 2026-09-25", "2 item(s)"} {
		if !strings.Contains(msg, want) {
			t.Fatalf("result missing %q: %s", want, msg)
		}
	}
	if got := legDays(t, trip.ID, "Los Angeles"); !daysEqual(got, 10, 11, 11, 11) {
		t.Fatalf("LA days = %v, want [10 11 11 11]", got)
	}
	if in, out := scanDates(t, `SELECT check_in, check_out FROM accommodations WHERE trip_id = $1 AND name = $2`, trip.ID, "Stay in Los Angeles"); in != "2026-09-24" || out != "2026-09-25" {
		t.Fatalf("LA stay = %s/%s, want 2026-09-24/2026-09-25", in, out)
	}
	// The later start still drags PC's boundary along, shrink or not.
	if in, out := scanDates(t, `SELECT check_in, check_out FROM accommodations WHERE trip_id = $1 AND name = $2`, trip.ID, "Hotel Casco Viejo"); in != "2026-09-15" || out != "2026-09-24" {
		t.Fatalf("PC stay = %s/%s, want 2026-09-15/2026-09-24", in, out)
	}
}

// Invalid input is a tool error and the transaction leaves nothing behind.
func TestPlanSetLegDatesValidationLeavesDBUntouched(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "leginvalid@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedMultiCityTrip(t, trip, user.ID)

	s, _ := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	cases := []struct {
		name, input, want string
	}{
		{"end before start", `{"city":"Los Angeles","start_date":"2026-09-24","end_date":"2026-09-23"}`, "end_date must not be before start_date"},
		{"unknown city lists legs", `{"city":"Tokyo","start_date":"2026-09-24"}`, "The legs are: Panama City (2026-09-15 to 2026-09-20), Los Angeles (2026-09-20 to 2026-09-24)"},
		{"start before trip", `{"city":"Los Angeles","start_date":"2026-09-10"}`, "before the trip begins on 2026-09-15"},
		{"missing city", `{"start_date":"2026-09-24"}`, "city is required"},
		{"bad start date", `{"city":"Los Angeles","start_date":"Sep 24"}`, "start_date is required and must be YYYY-MM-DD"},
	}
	for _, tc := range cases {
		msg, isErr := runSetLegDatesTool(s, []byte(tc.input))
		if !isErr || !strings.Contains(msg, tc.want) {
			t.Fatalf("%s = %q (err=%v), want error containing %q", tc.name, msg, isErr, tc.want)
		}
	}
	if got := legDays(t, trip.ID, "Los Angeles"); !daysEqual(got, 6, 7, 8, 9) {
		t.Fatalf("LA days changed on invalid input: %v", got)
	}
	if start, end := tripDates(t, trip.ID); start != "2026-09-15" || end != "2026-09-24" {
		t.Fatalf("trip dates changed on invalid input: %s/%s", start, end)
	}
	if in, _ := scanDates(t, `SELECT check_in, check_out FROM accommodations WHERE trip_id = $1 AND name = $2`, trip.ID, "Stay in Los Angeles"); in != "2026-09-20" {
		t.Fatalf("LA stay moved on invalid input: %s", in)
	}
}

// A city the itinerary visits twice is ambiguous — honest error, nothing moves.
func TestPlanSetLegDatesAmbiguousCity(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "revisit@example.com")
	trip := createTestTrip(t, user.ID, 0)
	ctx := context.Background()
	q := store.New(dbPool)
	if _, err := q.UpdateTrip(ctx, store.UpdateTripParams{
		ID: trip.ID, UserID: user.ID,
		StartDate: validDate("2026-09-15"), EndDate: validDate("2026-09-19"),
	}); err != nil {
		t.Fatalf("seed trip dates: %v", err)
	}
	for i, leg := range []struct {
		city string
		day  int
	}{{"Athens", 1}, {"Santorini", 2}, {"Athens", 4}} {
		d := int32(leg.day)
		city := leg.city
		if _, err := q.CreateItineraryItem(ctx, store.CreateItineraryItemParams{
			TripID: trip.ID, Position: int32(i), Name: fmt.Sprintf("%s stop", leg.city),
			City: &city, Day: &d, Latitude: 37.97, Longitude: 23.72,
		}); err != nil {
			t.Fatalf("seed item: %v", err)
		}
	}

	s, _ := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runSetLegDatesTool(s, []byte(`{"city":"Athens","start_date":"2026-09-16"}`))
	if !isErr || !strings.Contains(msg, "more than once") {
		t.Fatalf("ambiguous = %q (err=%v), want a more-than-once error", msg, isErr)
	}
	if got := legDays(t, trip.ID, "Athens"); !daysEqual(got, 1, 4) {
		t.Fatalf("Athens days changed on ambiguous input: %v", got)
	}
}

// Unit-level guards that need no seeded leg.
func TestSetLegDatesToolGuards(t *testing.T) {
	// Anonymous session.
	s, _ := testPlanSession(false, uuid.Nil)
	if msg, isErr := runSetLegDatesTool(s, []byte(`{"city":"LA","start_date":"2026-09-24"}`)); !isErr || !strings.Contains(msg, "signed in") {
		t.Fatalf("anonymous = %q (err=%v)", msg, isErr)
	}

	resetDB(t)
	user, _ := createTestUser(t, "legnotrip@example.com")

	// Authed but no trip anywhere in the session.
	s2, _ := testPlanSession(true, user.ID)
	if msg, isErr := runSetLegDatesTool(s2, []byte(`{"city":"LA","start_date":"2026-09-24"}`)); !isErr || !strings.Contains(msg, "create_itinerary") {
		t.Fatalf("no-trip = %q (err=%v)", msg, isErr)
	}

	// A dateless trip has no calendar to place a leg on.
	trip := createTestTrip(t, user.ID, 2)
	s3, _ := testPlanSession(true, user.ID)
	s3.boundTripID = &trip.ID
	if msg, isErr := runSetLegDatesTool(s3, []byte(`{"city":"LA","start_date":"2026-09-24"}`)); !isErr || !strings.Contains(msg, "set_trip_dates") {
		t.Fatalf("dateless trip = %q (err=%v), want a set_trip_dates redirect", msg, isErr)
	}
}

// An editor collaborator refining the owner's trip may move a leg; the
// analytics event marks the actor as a collaborator.
func TestPlanSetLegDatesEditorCollaborator(t *testing.T) {
	resetDB(t)
	newFakeAnthropic(t,
		toolTurn("set_leg_dates", `{"city":"Los Angeles","start_date":"2026-09-24","end_date":"2026-09-27"}`),
		textTurn("Moved LA for you both."))

	owner, _ := createTestUser(t, "legowner@example.com")
	editor, editorToken := createTestUser(t, "legeditor@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	seedMultiCityTrip(t, trip, owner.ID)
	if _, err := store.New(dbPool).CreateTripCollaborator(context.Background(), store.CreateTripCollaboratorParams{
		ChatID: *trip.ChatID, OwnerID: owner.ID, UserID: editor.ID, Role: "editor",
	}); err != nil {
		t.Fatalf("seed collaborator: %v", err)
	}

	rec := doJSON(t, "POST", "/api/v1/plan", editorToken, PlanRequest{
		TripID:   trip.ID.String(),
		Messages: []PlanChatMessage{{Role: "user", Content: "change LA to sep 24-27"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}
	events := planEvents(t, rec.Body.String())
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}
	if got := legDays(t, trip.ID, "Los Angeles"); !daysEqual(got, 10, 11, 12, 13) {
		t.Fatalf("LA days = %v, want [10 11 12 13]", got)
	}
	waitForEventCount(t, editor.ID, "agent_leg_dates_set", 1)
}

// Fresh chat, NEXT turn: a later /plan request in the same conversation has
// no bound trip and no s.tripID — the chat lineage resolves the target.
func TestPlanSetLegDatesFreshChatNextTurnLineage(t *testing.T) {
	resetDB(t)
	// The fake keys turn selection off tool_result count, so a second /plan
	// request would replay turn 0 — script each request with its own fake.
	newFakeAnthropic(t,
		// Explicit end_date: create_itinerary now refuses a one-sided date pair
		// (plan_spine.go). 2026-06-03 is what the old day-span derivation gave
		// this itinerary, so the leg day numbers asserted below are unchanged.
		toolTurn("create_itinerary", `{"title":"Greek Hop","start_date":"2026-06-01","end_date":"2026-06-03","locations":[{"name":"Acropolis","latitude":37.97,"longitude":23.72,"day":1,"city":"Athens"},{"name":"Oia","latitude":36.46,"longitude":25.37,"day":2,"city":"Santorini"},{"name":"Red Beach","latitude":36.35,"longitude":25.39,"day":3,"city":"Santorini"}]}`),
		textTurn("Saved!"))

	user, token := createTestUser(t, "leglineage@example.com")
	first := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID:   "chat-leg-lineage",
		Messages: []PlanChatMessage{{Role: "user", Content: "athens then santorini june 1"}},
	})
	if first.Code != http.StatusOK {
		t.Fatalf("first /plan = %d, want 200", first.Code)
	}

	fa2 := newFakeAnthropic(t,
		toolTurn("set_leg_dates", `{"city":"Santorini","start_date":"2026-06-03","end_date":"2026-06-04"}`),
		textTurn("Santorini moved."))
	second := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID: "chat-leg-lineage",
		Messages: []PlanChatMessage{
			{Role: "user", Content: "athens then santorini june 1"},
			{Role: "assistant", Content: "Saved!"},
			{Role: "user", Content: "push santorini a day later"},
		},
	})
	if second.Code != http.StatusOK {
		t.Fatalf("second /plan = %d, want 200", second.Code)
	}
	events := planEvents(t, second.Body.String())
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}
	updated := eventsOfType(events, "trip_updated")
	if len(updated) != 1 {
		t.Fatalf("trip_updated events = %d, want 1", len(updated))
	}
	tid, err := uuid.Parse(eventData(updated[0])["trip_id"].(string))
	if err != nil {
		t.Fatalf("trip_updated trip_id: %v", err)
	}
	if got := legDays(t, tid, "Santorini"); !daysEqual(got, 3, 4) {
		t.Fatalf("Santorini days = %v, want [3 4]", got)
	}
	// Athens is item-dated, so it needs NO boundary write: its rendered end IS
	// Santorini's new arrival, and the result's legs block states it. (The old
	// items-case extension physically dragged Athens' day-1 item to day 3.)
	if got := legDays(t, tid, "Athens"); !daysEqual(got, 1) {
		t.Fatalf("Athens days = %v, want [1] untouched", got)
	}
	if reqs := fa2.requestBodies(); len(reqs) < 2 || !strings.Contains(string(reqs[1]), "- Athens: 2026-06-01 to 2026-06-03") {
		t.Fatalf("missing Athens rendered range in follow-up request")
	}
	if _, end := tripDates(t, tid); end != "2026-06-04" {
		t.Fatalf("trip end = %s, want extended to 2026-06-04", end)
	}
	var trips int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM trips WHERE user_id = $1`, user.ID).Scan(&trips); err != nil {
		t.Fatalf("trips count: %v", err)
	}
	if trips != 1 {
		t.Fatalf("trips = %d, want 1 (set_leg_dates must never create a version)", trips)
	}
}

// The ticket's spine — the Berlin/Gothenburg incident, replayed against the
// gate. The observed failure: Berlin's places end Sep 10, Gothenburg's first
// place is Sep 12, and the tool reported "a 2-night gap between Berlin (ends
// Sep 10) and Gothenburg (starts Sep 12)" while the page drew Berlin running
// to Sep 12 — raw item spans quoted as screen dates. Now: the end-change
// refuses (Berlin's departure IS Gothenburg's arrival), the refusal quotes
// only rendered dates, names the exact replacement call, and claims no gap.
func TestPlanSetLegDatesEndOnInteriorLegRefusesAndSteers(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "berlingot@example.com")
	trip := createTestTrip(t, user.ID, 0)
	ctx := context.Background()
	q := store.New(dbPool)
	if _, err := q.UpdateTrip(ctx, store.UpdateTripParams{
		ID: trip.ID, UserID: user.ID,
		StartDate: validDate("2026-09-07"), EndDate: validDate("2026-09-15"),
	}); err != nil {
		t.Fatalf("seed trip dates: %v", err)
	}
	for i, seed := range []struct {
		name, city string
		day        int
	}{
		{"Museum Island", "Berlin", 1},
		{"East Side Gallery", "Berlin", 4}, // Sep 10 — Berlin's last place
		{"Haga District", "Gothenburg", 6}, // Sep 12 — Berlin's rendered end
		{"Liseberg", "Gothenburg", 8},
	} {
		d := int32(seed.day)
		city := seed.city
		if _, err := q.CreateItineraryItem(ctx, store.CreateItineraryItemParams{
			TripID: trip.ID, Position: int32(i), Name: seed.name,
			City: &city, Day: &d, Latitude: 52.51, Longitude: 13.39,
		}); err != nil {
			t.Fatalf("seed item %s: %v", seed.name, err)
		}
	}

	s, rec := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runSetLegDatesTool(s, []byte(`{"city":"Berlin","start_date":"2026-09-07","end_date":"2026-09-10"}`))
	if !isErr {
		t.Fatalf("interior end change did not refuse: %s", msg)
	}
	for _, want := range []string{
		"Berlin's departure day is the next city's arrival",
		"shows Berlin ending 2026-09-12 because Gothenburg arrives then",
		`set_leg_dates(city="Gothenburg", start_date="2026-09-10")`,
		"shift_days_from",
		"Nothing was changed",
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("steer missing %q: %s", want, msg)
		}
	}
	// No result text claims a date gap between two legs — a gap is
	// unrepresentable on the page under the boundary rule.
	for _, banned := range []string{"gap", "uncovered"} {
		if strings.Contains(msg, banned) {
			t.Fatalf("refusal claims a between-legs %s the page cannot draw: %s", banned, msg)
		}
	}
	assertDatesFromRenderedLegs(t, msg, trip.ID, user.ID, "2026-09-10")
	if strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("refusal emitted trip_updated")
	}
	if got := legDays(t, trip.ID, "Berlin"); !daysEqual(got, 1, 4) {
		t.Fatalf("Berlin days = %v, want [1 4] untouched", got)
	}
	if got := legDays(t, trip.ID, "Gothenburg"); !daysEqual(got, 6, 8) {
		t.Fatalf("Gothenburg days = %v, want [6 8] untouched", got)
	}
}

// A place on the leg's last item day survives a set_leg_dates call unmoved —
// the ticket's headline regression. An end-only move on a stay-anchored leg
// used to drag the last item onto the new check-out day; now the check-out
// (and the departing transport, and the trip end) move while every place
// stays exactly where the traveler put it.
func TestPlanSetLegDatesEndMoveLeavesItemsAlone(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "endonly@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedMultiCityTrip(t, trip, user.ID)

	s, rec := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runSetLegDatesTool(s, []byte(`{"city":"Los Angeles","start_date":"2026-09-20","end_date":"2026-09-26"}`))
	if isErr {
		t.Fatalf("end-only move errored: %s", msg)
	}
	for _, want := range []string{
		"Los Angeles is now 2026-09-20 to 2026-09-26 on the trip page (6 nights)",
		"Trip end extended to 2026-09-26",
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("result missing %q: %s", want, msg)
		}
	}
	if strings.Contains(msg, "folded onto") {
		t.Fatalf("a lengthening end move folded items: %s", msg)
	}
	if !strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("end-only move did not emit trip_updated")
	}
	assertDatesFromRenderedLegs(t, msg, trip.ID, user.ID)
	if got := legDays(t, trip.ID, "Los Angeles"); !daysEqual(got, 6, 7, 8, 9) {
		t.Fatalf("LA days = %v, want [6 7 8 9] — no place rides a departure day", got)
	}
	if in, out := scanDates(t, `SELECT check_in, check_out FROM accommodations WHERE trip_id = $1 AND name = $2`, trip.ID, "Stay in Los Angeles"); in != "2026-09-20" || out != "2026-09-26" {
		t.Fatalf("LA stay = %s/%s, want 2026-09-20/2026-09-26", in, out)
	}
	if dep, _ := scanDates(t, `SELECT depart_date, arrive_date FROM trip_segments WHERE trip_id = $1 AND origin = $2`, trip.ID, "Los Angeles"); dep != "2026-09-26" {
		t.Fatalf("departure segment departs %s, want 2026-09-26 (rides the check-out)", dep)
	}
	if _, end := tripDates(t, trip.ID); end != "2026-09-26" {
		t.Fatalf("trip end = %s, want extended to 2026-09-26", end)
	}
}

// Shortening the FINAL leg is shortening the trip: its rendered end is the
// trip's end date, which this tool only extends. The refusal steers to
// set_trip_dates with the exact dates, and start-only remains offered.
func TestPlanSetLegDatesLastLegShrinkSteersToTripDates(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "lastshrink@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedPragueKrakowBerlinTrip(t, trip, user.ID, 6)

	s, rec := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runSetLegDatesTool(s, []byte(`{"city":"Berlin","start_date":"2026-09-01","end_date":"2026-09-05"}`))
	if !isErr {
		t.Fatalf("last-leg shrink did not refuse: %s", msg)
	}
	for _, want := range []string{
		"Berlin is the trip's last city",
		"2026-09-27",
		"set_trip_dates",
		"end_date=2026-09-05",
		"start_date only",
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("steer missing %q: %s", want, msg)
		}
	}
	if strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("refusal emitted trip_updated")
	}
	if got := legDays(t, trip.ID, "Berlin"); !daysEqual(got, 9) {
		t.Fatalf("Berlin day = %v, want [9] untouched", got)
	}
	if _, end := tripDates(t, trip.ID); end != "2026-09-27" {
		t.Fatalf("trip end = %s, want untouched 2026-09-27", end)
	}
}

// The ways a spine's rendered dates go wrong, named ABOVE the leg list so the
// model meets them before the ranges they describe — plus the SOFT unplanned-
// stretches block and its one-night silence threshold.
func TestLegsRenderWarning(t *testing.T) {
	// Porto and Madrid share the Sep 4 arrival: Porto is a genuine zero-night
	// stop (ZeroNight, read from the derivation), it is NOT the last leg, and
	// the line names the city that arrives with it. The remedy must steer to
	// arrival moves — never to planting a place on a day (the retired
	// convention that produced the Prague Airport Starbucks).
	collapsed := legsRenderSummary(rlTrip("2026-09-01", "2026-09-08"), []store.ItineraryItem{
		rlItem(0, "Time Out Market", rlCity("Lisbon"), 1),
		rlItem(1, "Livraria Lello", rlCity("Porto"), 4),
		rlItem(2, "Museo del Prado", rlCity("Madrid"), 4),
	}, nil)
	if !strings.HasPrefix(collapsed, "WARNING") {
		t.Fatalf("a zero-night interior leg did not lead with a warning:\n%s", collapsed)
	}
	for _, want := range []string{
		"Porto renders ZERO nights",
		"the next city (Madrid) arrives on or before it",
		"set_leg_dates", "shift_days_from",
		"never add a place just to hold a date",
	} {
		if !strings.Contains(collapsed, want) {
			t.Fatalf("warning missing %q:\n%s", want, collapsed)
		}
	}
	for _, stale := range []string{"no place sits on the day they move on", "give the city a place"} {
		if strings.Contains(collapsed, stale) {
			t.Fatalf("warning still carries the retired convention %q:\n%s", stale, collapsed)
		}
	}

	// A place dated after the day its leg ends on the page: the boundary rule
	// strands it instead of widening the leg, and the warning reads the
	// derivation's own finding (RenderLeg.itemsPastEnd) — never a re-derived
	// condition. Kraków ends at Berlin's Sep 1 arrival; its Sep 2 item is
	// outside its own city's dates.
	stranded := legsRenderSummary(rlTrip("2026-08-24", "2026-09-27"), []store.ItineraryItem{
		rlItem(0, "Old Town Square", rlCity("Prague"), 4),
		rlItem(1, "Wawel Castle", rlCity("Kraków"), 6),
		rlItem(2, "Schindler's Factory", rlCity("Kraków"), 10),
		rlItem(3, "Brandenburg Gate", rlCity("Berlin"), 9),
	}, nil)
	for _, want := range []string{"WARNING", "Kraków has a place dated after 2026-09-01", "outside its own city's rendered dates"} {
		if !strings.Contains(stranded, want) {
			t.Fatalf("stranded-item warning missing %q:\n%s", want, stranded)
		}
	}

	// Undated places: the span is the weighted split of the trip, not a choice.
	guessed := legsRenderSummary(rlTrip("2026-06-01", "2026-06-08"), []store.ItineraryItem{
		rlItem(0, "Louvre", rlCity("Paris"), 0),
		rlItem(1, "Colosseum", rlCity("Rome"), 0),
	}, nil)
	if !strings.Contains(guessed, "its range is a guess") {
		t.Fatalf("an auto-dated leg did not warn:\n%s", guessed)
	}
	if !strings.Contains(guessed, "dates GUESSED") {
		t.Fatalf("an auto-dated leg's line did not state its provenance:\n%s", guessed)
	}

	// The unplanned-stretches threshold, both sides of it. ONE place-free
	// night before a departure is the normal spine — every correctly-built
	// trip has one — and must stay silent or the block fires on everything
	// and gets averaged away. TWO earn the soft line (the Berlin/Gothenburg
	// shape: Berlin's last place Sep 10, Gothenburg arrives Sep 12 — the
	// nights are unplanned INSIDE Berlin; there is no gap between legs).
	oneNight := legsRenderSummary(rlTrip("2026-09-01", "2026-09-06"), []store.ItineraryItem{
		rlItem(0, "Time Out Market", rlCity("Lisbon"), 1),
		rlItem(1, "Pastéis de Belém", rlCity("Lisbon"), 3), // departs Sep 4: 1 free night
		rlItem(2, "Livraria Lello", rlCity("Porto"), 4),
		rlItem(3, "Cais da Ribeira", rlCity("Porto"), 5), // trip ends Sep 6: 1 free night
	}, nil)
	if strings.Contains(oneNight, "Unplanned") || strings.Contains(oneNight, "WARNING") {
		t.Fatalf("the normal one-night spine was not silent:\n%s", oneNight)
	}
	twoNights := legsRenderSummary(rlTrip("2026-09-07", "2026-09-14"), []store.ItineraryItem{
		rlItem(0, "Museum Island", rlCity("Berlin"), 1),
		rlItem(1, "East Side Gallery", rlCity("Berlin"), 4), // Sep 10
		rlItem(2, "Haga District", rlCity("Gothenburg"), 6), // arrives Sep 12
	}, nil)
	for _, want := range []string{
		"Unplanned stretches",
		"Berlin renders 2026-09-07 to 2026-09-12 (5 nights) but its last place is 2026-09-10 — 2 nights with nothing planned",
		"mention, don't fix",
	} {
		if !strings.Contains(twoNights, want) {
			t.Fatalf("two free nights missing %q:\n%s", want, twoNights)
		}
	}
	if strings.Contains(twoNights, "WARNING") {
		t.Fatalf("an unplanned stretch is not a render defect and must not be a WARNING:\n%s", twoNights)
	}
	if strings.Contains(twoNights, "gap") {
		t.Fatalf("no result text may claim a date gap between legs:\n%s", twoNights)
	}

	// A healthy spine says nothing extra — the warning must not become noise
	// every itinerary write carries.
	clean := legsRenderSummary(rlTrip("2026-09-01", "2026-09-08"), []store.ItineraryItem{
		rlItem(0, "Time Out Market", rlCity("Lisbon"), 1),
		rlItem(1, "Pastéis de Belém", rlCity("Lisbon"), 4),
		rlItem(2, "Livraria Lello", rlCity("Porto"), 4),
		rlItem(3, "Cais da Ribeira", rlCity("Porto"), 6),
		rlItem(4, "Museo del Prado", rlCity("Madrid"), 6),
		rlItem(5, "Mercado San Miguel", rlCity("Madrid"), 7),
	}, nil)
	if strings.Contains(clean, "WARNING") || strings.Contains(clean, "Unplanned") {
		t.Fatalf("a well-formed spine warned:\n%s", clean)
	}
}
