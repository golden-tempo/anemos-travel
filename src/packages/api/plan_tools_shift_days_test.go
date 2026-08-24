package main

// shift_days_from (specs/leg-departure-dates ticket 3): the suffix shift.
// The DB tests assert against RULE-INDEPENDENT state wherever possible — raw
// item day numbers, stay/segment/todo dates, the trip's end date — because
// ticket 1 changes what computeTripLegs renders and those writes do not move
// with it. Where a rendered span is genuinely the subject (the collapse
// guard, the night-count acceptance test), the fixture is a sparse SPINE
// (arrival + move-on only), whose collapse and night counts are identical
// under the current rule and ticket 1's arrival-chain rule — flagged in the
// lane report for the integrator to re-check after ticket 1 merges anyway.

import (
	"context"
	"net/http"
	"reflect"
	"strings"
	"testing"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

// seedShiftTrip builds the rich suffix-shift fixture on 2026-09-01..09:
// Lisbon days 1-2-4 (interior day + move-on), Porto 4-6, Madrid 6-8 plus one
// undated idea; a straddling Lisbon stay (Sep 1-4), a Porto stay (Sep 4-6),
// an AUTO Madrid draft stay (Sep 6-9); a prefix arrival flight, an overnight
// train INTO Porto (Sep 3 -> Sep 4), the flight home (Sep 9, no arrive date);
// a round-trip flights todo (Sep 1 out, Sep 9 back), an AUTO transport todo
// on the pivot date, and an undated todo.
func seedShiftTrip(t *testing.T, trip store.Trip, owner uuid.UUID) {
	t.Helper()
	ctx := context.Background()
	q := store.New(dbPool)
	if _, err := q.UpdateTrip(ctx, store.UpdateTripParams{
		ID: trip.ID, UserID: owner,
		StartDate: validDate("2026-09-01"), EndDate: validDate("2026-09-09"),
	}); err != nil {
		t.Fatalf("seed trip dates: %v", err)
	}
	seed := func(pos int, name, city string, day int) {
		t.Helper()
		p := store.CreateItineraryItemParams{
			TripID: trip.ID, Position: int32(pos), Name: name, City: &city,
			Latitude: 38.7 + float64(pos)*0.01, Longitude: -9.1,
		}
		if day > 0 {
			d := int32(day)
			p.Day = &d
		}
		if _, err := q.CreateItineraryItem(ctx, p); err != nil {
			t.Fatalf("seed item %s: %v", name, err)
		}
	}
	seed(0, "Lisbon Arrival", "Lisbon", 1)
	seed(1, "Lisbon Museum", "Lisbon", 2)
	seed(2, "Lisbon Move-on Cafe", "Lisbon", 4)
	seed(3, "Porto Arrival", "Porto", 4)
	seed(4, "Porto Move-on", "Porto", 6)
	seed(5, "Madrid Arrival", "Madrid", 6)
	seed(6, "Madrid Last", "Madrid", 8)
	seed(7, "Madrid Someday", "Madrid", 0) // undated: must never move

	lisbonAddr := "Baixa, Lisbon, Portugal"
	if _, err := q.CreateAccommodation(ctx, store.CreateAccommodationParams{
		TripID: trip.ID, Name: "Lisbon Hotel", Address: &lisbonAddr,
		CheckIn: validDate("2026-09-01"), CheckOut: validDate("2026-09-04"),
	}); err != nil {
		t.Fatalf("seed Lisbon stay: %v", err)
	}
	if _, err := q.CreateAccommodation(ctx, store.CreateAccommodationParams{
		TripID: trip.ID, Name: "Stay in Porto",
		CheckIn: validDate("2026-09-04"), CheckOut: validDate("2026-09-06"),
	}); err != nil {
		t.Fatalf("seed Porto stay: %v", err)
	}
	draftKey := "stay:madrid"
	if _, err := q.UpsertDraftAccommodation(ctx, store.UpsertDraftAccommodationParams{
		TripID: trip.ID, Name: "Suggested stay in Madrid", AutoKey: &draftKey,
		CheckIn: validDate("2026-09-06"), CheckOut: validDate("2026-09-09"),
	}); err != nil {
		t.Fatalf("seed Madrid draft: %v", err)
	}
	if _, err := q.CreateAccommodation(ctx, store.CreateAccommodationParams{
		TripID: trip.ID, Name: "Undated Stay",
	}); err != nil {
		t.Fatalf("seed undated stay: %v", err)
	}

	home, lisbon, porto, madrid := "Newark", "Lisbon", "Porto", "Madrid"
	if _, err := q.CreateSegment(ctx, store.CreateSegmentParams{
		TripID: trip.ID, Mode: "flight", Origin: &home, Destination: &lisbon,
		DepartDate: validDate("2026-09-01"), ArriveDate: validDate("2026-09-01"),
	}); err != nil {
		t.Fatalf("seed arrival flight: %v", err)
	}
	if _, err := q.CreateSegment(ctx, store.CreateSegmentParams{
		TripID: trip.ID, Mode: "train", Origin: &lisbon, Destination: &porto,
		DepartDate: validDate("2026-09-03"), ArriveDate: validDate("2026-09-04"),
	}); err != nil {
		t.Fatalf("seed overnight train: %v", err)
	}
	if _, err := q.CreateSegment(ctx, store.CreateSegmentParams{
		TripID: trip.ID, Mode: "flight", Origin: &madrid, Destination: &home,
		DepartDate: validDate("2026-09-09"),
	}); err != nil {
		t.Fatalf("seed flight home: %v", err)
	}

	if _, err := q.CreateBookingTodo(ctx, store.CreateBookingTodoParams{
		TripID: trip.ID, Kind: "flight", TodoKey: "seed:flights", Title: "Book flights",
		DepartDate: validDate("2026-09-01"), ReturnDate: validDate("2026-09-09"), Position: 1,
	}); err != nil {
		t.Fatalf("seed flights todo: %v", err)
	}
	if _, err := q.UpsertBookingTodo(ctx, store.UpsertBookingTodoParams{
		TripID: trip.ID, Kind: "transport", TodoKey: "transport:lisbon>>porto",
		Title: "Lisbon → Porto", DepartDate: validDate("2026-09-04"), Position: 2,
	}); err != nil {
		t.Fatalf("seed auto todo: %v", err)
	}
	if _, err := q.CreateBookingTodo(ctx, store.CreateBookingTodoParams{
		TripID: trip.ID, Kind: "stay", TodoKey: "seed:undated", Title: "Undated todo", Position: 3,
	}); err != nil {
		t.Fatalf("seed undated todo: %v", err)
	}
}

// seedShiftSpineTrip is the sparse-spine fixture for the rendered-span guards:
// arrival + move-on only, no interior items, so its zero-night collapse is
// IDENTICAL under the current last-item-day rule and ticket 1's arrival-chain
// rule. Lisbon {1,4}, Porto {4,6}, Madrid {6,8} on 2026-09-01..09.
func seedShiftSpineTrip(t *testing.T, trip store.Trip, owner uuid.UUID) {
	t.Helper()
	ctx := context.Background()
	q := store.New(dbPool)
	if _, err := q.UpdateTrip(ctx, store.UpdateTripParams{
		ID: trip.ID, UserID: owner,
		StartDate: validDate("2026-09-01"), EndDate: validDate("2026-09-09"),
	}); err != nil {
		t.Fatalf("seed trip dates: %v", err)
	}
	seed := func(pos int, name, city string, day int) {
		t.Helper()
		d := int32(day)
		if _, err := q.CreateItineraryItem(ctx, store.CreateItineraryItemParams{
			TripID: trip.ID, Position: int32(pos), Name: name, City: &city, Day: &d,
			Latitude: 38.7 + float64(pos)*0.01, Longitude: -9.1,
		}); err != nil {
			t.Fatalf("seed item %s: %v", name, err)
		}
	}
	seed(0, "Lisbon Arrival", "Lisbon", 1)
	seed(1, "Lisbon Move-on", "Lisbon", 4)
	seed(2, "Porto Arrival", "Porto", 4)
	seed(3, "Porto Move-on", "Porto", 6)
	seed(4, "Madrid Arrival", "Madrid", 6)
	seed(5, "Madrid Last", "Madrid", 8)
}

// snapshotShiftState captures every date-bearing row the tool may touch, as
// one comparable map — the "nothing was committed" and round-trip oracle.
func snapshotShiftState(t *testing.T, tripID uuid.UUID) map[string]string {
	t.Helper()
	ctx := context.Background()
	snap := map[string]string{}
	var tripDates string
	if err := dbPool.QueryRow(ctx,
		`SELECT COALESCE(start_date::text,'')||'/'||COALESCE(end_date::text,'') FROM trips WHERE id = $1`,
		tripID).Scan(&tripDates); err != nil {
		t.Fatalf("snapshot trip: %v", err)
	}
	snap["trip"] = tripDates
	collect := func(label, query string) {
		rows, err := dbPool.Query(ctx, query, tripID)
		if err != nil {
			t.Fatalf("snapshot %s: %v", label, err)
		}
		defer rows.Close()
		for rows.Next() {
			var k, v string
			if err := rows.Scan(&k, &v); err != nil {
				t.Fatalf("snapshot %s scan: %v", label, err)
			}
			snap[label+":"+k] = v
		}
	}
	collect("item", `SELECT name, COALESCE(day::text,'') FROM itinerary_items WHERE trip_id = $1`)
	collect("stay", `SELECT name, COALESCE(check_in::text,'')||'/'||COALESCE(check_out::text,'')||'/'||auto::text FROM accommodations WHERE trip_id = $1`)
	collect("seg", `SELECT COALESCE(origin,'')||'>'||COALESCE(destination,''), COALESCE(depart_date::text,'')||'/'||COALESCE(arrive_date::text,'') FROM trip_segments WHERE trip_id = $1`)
	collect("todo", `SELECT todo_key, COALESCE(depart_date::text,'')||'/'||COALESCE(return_date::text,'')||'/'||auto::text FROM booking_todos WHERE trip_id = $1`)
	return snap
}

// requireUnchanged asserts a refused (or no-op) call committed nothing.
func requireUnchanged(t *testing.T, before map[string]string, tripID uuid.UUID) {
	t.Helper()
	if after := snapshotShiftState(t, tripID); !reflect.DeepEqual(before, after) {
		t.Fatalf("state changed on a call that must commit nothing:\nbefore=%v\nafter=%v", before, after)
	}
}

// The headline path via the full /plan round-trip: +2 from Porto. Every
// assertion below is storage-level and rule-independent: the predecessor's
// move-on item and straddling stay checkout ride, its check-in and everything
// earlier hold still, segments move as units, todo dates move per-date, auto
// rows move WITHOUT being confirmed, undated rows never move.
func TestPlanShiftDaysFromShiftsSuffix(t *testing.T) {
	resetDB(t)
	fa := newFakeAnthropic(t,
		toolTurn("shift_days_from", `{"city":"Porto","days":2}`),
		textTurn("Lisbon has two more nights; everything from Porto moved two days later."))

	user, token := createTestUser(t, "shiftsuffix@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedShiftTrip(t, trip, user.ID)

	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		TripID:   trip.ID.String(),
		Messages: []PlanChatMessage{{Role: "user", Content: "give lisbon two more nights"}},
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

	reqs := fa.requestBodies()
	if len(reqs) < 2 {
		t.Fatalf("model requests = %d, want >= 2 (tool round-trip)", len(reqs))
	}
	followUp := string(reqs[1])
	for _, want := range []string{
		"Everything from Porto onward moved 2 day(s) later",
		"5 itinerary item(s)", "3 stay(s)", "2 transport leg(s)", "2 booking to-do(s)",
		"The trip now ends 2026-09-11", "ORIGINAL dates",
	} {
		if !strings.Contains(followUp, want) {
			t.Fatalf("tool_result round-trip missing %q:\n%s", want, followUp)
		}
	}

	// Trip anchor: start holds, end rides.
	if start, end := tripDates(t, trip.ID); start != "2026-09-01" || end != "2026-09-11" {
		t.Fatalf("trip dates = %s/%s, want 2026-09-01/2026-09-11", start, end)
	}
	// Item days: prefix (day < 4) holds, suffix (day >= 4) +2, undated stays.
	snap := snapshotShiftState(t, trip.ID)
	wantItems := map[string]string{
		"item:Lisbon Arrival": "1", "item:Lisbon Museum": "2", "item:Lisbon Move-on Cafe": "6",
		"item:Porto Arrival": "6", "item:Porto Move-on": "8",
		"item:Madrid Arrival": "8", "item:Madrid Last": "10", "item:Madrid Someday": "",
	}
	for k, want := range wantItems {
		if snap[k] != want {
			t.Fatalf("%s = %q, want %q (full: %v)", k, snap[k], want, snap)
		}
	}
	// Stays: the straddling predecessor keeps check-in and rides check-out;
	// the auto draft moves and REMAINS a draft.
	wantStays := map[string]string{
		"stay:Lisbon Hotel":             "2026-09-01/2026-09-06/false",
		"stay:Stay in Porto":            "2026-09-06/2026-09-08/false",
		"stay:Suggested stay in Madrid": "2026-09-08/2026-09-11/true",
		"stay:Undated Stay":             "//false",
	}
	for k, want := range wantStays {
		if snap[k] != want {
			t.Fatalf("%s = %q, want %q", k, snap[k], want)
		}
	}
	// Segments: units — the overnight train into Porto departs later too; the
	// prefix arrival flight holds still.
	wantSegs := map[string]string{
		"seg:Newark>Lisbon": "2026-09-01/2026-09-01",
		"seg:Lisbon>Porto":  "2026-09-05/2026-09-06",
		"seg:Madrid>Newark": "2026-09-11/",
	}
	for k, want := range wantSegs {
		if snap[k] != want {
			t.Fatalf("%s = %q, want %q", k, snap[k], want)
		}
	}
	// Todos: per-date — the round trip's outbound holds, its return rides;
	// the auto row moves and stays auto.
	wantTodos := map[string]string{
		"todo:seed:flights":            "2026-09-01/2026-09-11/false",
		"todo:transport:lisbon>>porto": "2026-09-06//true",
		"todo:seed:undated":            "//false",
	}
	for k, want := range wantTodos {
		if snap[k] != want {
			t.Fatalf("%s = %q, want %q", k, snap[k], want)
		}
	}

	waitForEventCount(t, user.ID, "agent_days_shifted", 1)
}

// The strongest invariant: +n then -n is byte-identical across every table
// the tool touches, straddling rows included. Rule-independent by nature —
// it reads no rendered spans at all.
func TestShiftDaysFromRoundTripByteIdentical(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "roundtrip@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedShiftTrip(t, trip, user.ID)
	before := snapshotShiftState(t, trip.ID)

	s, _ := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	if msg, isErr := runShiftDaysFromTool(s, []byte(`{"city":"Porto","days":3}`)); isErr {
		t.Fatalf("+3 errored: %s", msg)
	}
	if after := snapshotShiftState(t, trip.ID); reflect.DeepEqual(before, after) {
		t.Fatal("+3 changed nothing")
	}
	s2, _ := testPlanSession(true, user.ID)
	s2.boundTripID = &trip.ID
	if msg, isErr := runShiftDaysFromTool(s2, []byte(`{"city":"Porto","days":-3}`)); isErr {
		t.Fatalf("-3 errored: %s", msg)
	}
	if after := snapshotShiftState(t, trip.ID); !reflect.DeepEqual(before, after) {
		t.Fatalf("round trip is not byte-identical:\nbefore=%v\nafter=%v", before, after)
	}
}

// Acceptance 4: "give Porto another night" is ONE call — shift_days_from on
// the city after it — and no other city's night count changes. Nights are
// read through computeTripLegs at test runtime, so the assertion follows the
// in-repo derivation across the ticket-1 rule change instead of pinning
// today's ranges.
func TestShiftDaysFromNightCountsAcceptance(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "nights@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedShiftTrip(t, trip, user.ID)

	nightsByLabel := func() map[string]int {
		t.Helper()
		ctx := context.Background()
		q := store.New(dbPool)
		tr, err := q.GetTripByIDAndOwner(ctx, store.GetTripByIDAndOwnerParams{ID: trip.ID, UserID: user.ID})
		if err != nil {
			t.Fatalf("load trip: %v", err)
		}
		items, err := q.GetItineraryItemsByTrip(ctx, trip.ID)
		if err != nil {
			t.Fatalf("load items: %v", err)
		}
		stays, err := q.ListAccommodationsByTrip(ctx, trip.ID)
		if err != nil {
			t.Fatalf("load stays: %v", err)
		}
		out := map[string]int{}
		for _, leg := range computeTripLegs(tr, items, stays) {
			if leg.Start != nil && leg.End != nil {
				out[leg.Label] = nightsBetween(*leg.Start, *leg.End)
			}
		}
		return out
	}

	before := nightsByLabel()
	s, _ := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runShiftDaysFromTool(s, []byte(`{"city":"Madrid","days":1}`))
	if isErr {
		t.Fatalf("shift errored: %s", msg)
	}
	after := nightsByLabel()

	if after["Porto"] != before["Porto"]+1 {
		t.Fatalf("Porto nights = %d, want %d (+1): before=%v after=%v", after["Porto"], before["Porto"]+1, before, after)
	}
	for _, label := range []string{"Lisbon", "Madrid"} {
		if after[label] != before[label] {
			t.Fatalf("%s nights changed %d -> %d; only Porto may change (before=%v after=%v)", label, before[label], after[label], before, after)
		}
	}
}

// A negative shift that would collapse the city before the pivot to zero
// nights refuses, names it, and commits nothing; one day short of the
// collapse still works. Spine fixture: identical verdicts under the current
// derivation and ticket 1's.
func TestShiftDaysFromZeroNightPredecessorRefusal(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "collapse@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedShiftSpineTrip(t, trip, user.ID)
	before := snapshotShiftState(t, trip.ID)

	s, rec := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runShiftDaysFromTool(s, []byte(`{"city":"Porto","days":-3}`))
	if !isErr {
		t.Fatalf("collapse shift succeeded: %s", msg)
	}
	if !strings.Contains(msg, "Lisbon") || !strings.Contains(msg, "ZERO nights") {
		t.Fatalf("refusal must name the swallowed city: %s", msg)
	}
	if strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("refusal must not emit trip_updated")
	}
	requireUnchanged(t, before, trip.ID)

	// One day less is legal: Lisbon keeps a night.
	s2, _ := testPlanSession(true, user.ID)
	s2.boundTripID = &trip.ID
	if msg, isErr := runShiftDaysFromTool(s2, []byte(`{"city":"Porto","days":-2}`)); isErr {
		t.Fatalf("-2 should be allowed: %s", msg)
	}
	snap := snapshotShiftState(t, trip.ID)
	for k, want := range map[string]string{
		"item:Lisbon Arrival": "1", "item:Lisbon Move-on": "2",
		"item:Porto Arrival": "2", "item:Porto Move-on": "4",
		"item:Madrid Arrival": "4", "item:Madrid Last": "6",
		"trip": "2026-09-01/2026-09-07",
	} {
		if snap[k] != want {
			t.Fatalf("%s = %q, want %q", k, snap[k], want)
		}
	}
}

// No item may land before day 1: refuse (never clamp), name the pivot city,
// commit nothing. Porto arrives day 4, so -4 would put it on day 0.
func TestShiftDaysFromDayFloorRefusal(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "floor@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedShiftTrip(t, trip, user.ID)
	before := snapshotShiftState(t, trip.ID)

	s, rec := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runShiftDaysFromTool(s, []byte(`{"city":"Porto","days":-4}`))
	if !isErr {
		t.Fatalf("below-day-1 shift succeeded: %s", msg)
	}
	if !strings.Contains(msg, "Porto") || !strings.Contains(msg, "before the trip's first day") {
		t.Fatalf("refusal must name the city falling off the calendar: %s", msg)
	}
	if strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("refusal must not emit trip_updated")
	}
	requireUnchanged(t, before, trip.ID)
}

// days=0 is the honest no-op: not an error, nothing committed, no
// trip_updated SSE, and the result reports actual saved state — never an echo
// of the request as if achieved.
func TestShiftDaysFromZeroDaysHonestNoOp(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "zerodays@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedShiftTrip(t, trip, user.ID)
	before := snapshotShiftState(t, trip.ID)

	s, rec := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runShiftDaysFromTool(s, []byte(`{"city":"Porto","days":0}`))
	if isErr {
		t.Fatalf("zero-days no-op must not be a tool error: %s", msg)
	}
	if !strings.Contains(msg, "No saved rows changed") || !strings.Contains(msg, "never tell the traveler anything changed") {
		t.Fatalf("no-op must report actual saved state: %s", msg)
	}
	if strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("no-op must not emit trip_updated")
	}
	requireUnchanged(t, before, trip.ID)
}

// An unknown city refuses with the trip's legs listed, and commits nothing.
func TestShiftDaysFromUnknownCityListsLegs(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "unknowncity@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedShiftTrip(t, trip, user.ID)
	before := snapshotShiftState(t, trip.ID)

	s, _ := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runShiftDaysFromTool(s, []byte(`{"city":"Barcelona","days":1}`))
	if !isErr {
		t.Fatalf("unknown city succeeded: %s", msg)
	}
	if !strings.Contains(msg, "No leg for 'Barcelona'") || !strings.Contains(msg, "The legs are:") {
		t.Fatalf("refusal must list the legs: %s", msg)
	}
	requireUnchanged(t, before, trip.ID)
}

// The first dated city has no predecessor to give nights to; the tool steers
// to set_trip_dates instead of inventing semantics, and commits nothing.
func TestShiftDaysFromFirstCityRefusal(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "firstcity@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedShiftTrip(t, trip, user.ID)
	before := snapshotShiftState(t, trip.ID)

	s, _ := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runShiftDaysFromTool(s, []byte(`{"city":"Lisbon","days":1}`))
	if !isErr {
		t.Fatalf("first-city shift succeeded: %s", msg)
	}
	if !strings.Contains(msg, "first city") || !strings.Contains(msg, "set_trip_dates") {
		t.Fatalf("refusal must steer to set_trip_dates: %s", msg)
	}
	requireUnchanged(t, before, trip.ID)
}

// Revisits: a bare name that matches two visits refuses and offers the #N
// spelling; City#2 addresses the second visit — and only the suffix from ITS
// arrival moves; a visit number past the count refuses.
func TestShiftDaysFromRevisitAddressing(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "revisit@example.com")
	trip := createTestTrip(t, user.ID, 0)
	ctx := context.Background()
	q := store.New(dbPool)
	if _, err := q.UpdateTrip(ctx, store.UpdateTripParams{
		ID: trip.ID, UserID: user.ID,
		StartDate: validDate("2026-09-01"), EndDate: validDate("2026-09-08"),
	}); err != nil {
		t.Fatalf("seed trip dates: %v", err)
	}
	seed := func(pos int, name, city string, day int) {
		t.Helper()
		d := int32(day)
		if _, err := q.CreateItineraryItem(ctx, store.CreateItineraryItemParams{
			TripID: trip.ID, Position: int32(pos), Name: name, City: &city, Day: &d,
			Latitude: 48.85 + float64(pos)*0.01, Longitude: 2.35,
		}); err != nil {
			t.Fatalf("seed item %s: %v", name, err)
		}
	}
	seed(0, "Paris One Arrival", "Paris", 1)
	seed(1, "Paris One Move-on", "Paris", 3)
	seed(2, "Rome Arrival", "Rome", 3)
	seed(3, "Rome Move-on", "Rome", 5)
	seed(4, "Paris Two Arrival", "Paris", 5)
	seed(5, "Paris Two Last", "Paris", 7)
	before := snapshotShiftState(t, trip.ID)

	s, _ := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runShiftDaysFromTool(s, []byte(`{"city":"Paris","days":1}`))
	if !isErr {
		t.Fatalf("ambiguous revisit succeeded: %s", msg)
	}
	if !strings.Contains(msg, "Paris#1") || !strings.Contains(msg, "Paris#2") {
		t.Fatalf("ambiguity refusal must offer the #N spelling: %s", msg)
	}
	requireUnchanged(t, before, trip.ID)

	s2, _ := testPlanSession(true, user.ID)
	s2.boundTripID = &trip.ID
	msg, isErr = runShiftDaysFromTool(s2, []byte(`{"city":"Paris#3","days":1}`))
	if !isErr || !strings.Contains(msg, "no visit #3") {
		t.Fatalf("visit past the count must refuse: %s (err=%v)", msg, isErr)
	}
	requireUnchanged(t, before, trip.ID)

	s3, _ := testPlanSession(true, user.ID)
	s3.boundTripID = &trip.ID
	msg, isErr = runShiftDaysFromTool(s3, []byte(`{"city":"Paris#2","days":1}`))
	if isErr {
		t.Fatalf("Paris#2 errored: %s", msg)
	}
	snap := snapshotShiftState(t, trip.ID)
	for k, want := range map[string]string{
		// First visit untouched; Rome's move-on (the second visit's arrival
		// day) rides, as every day on or after the pivot does.
		"item:Paris One Arrival": "1", "item:Paris One Move-on": "3",
		"item:Rome Arrival": "3", "item:Rome Move-on": "6",
		"item:Paris Two Arrival": "6", "item:Paris Two Last": "8",
		"trip": "2026-09-01/2026-09-09",
	} {
		if snap[k] != want {
			t.Fatalf("%s = %q, want %q (full: %v)", k, snap[k], want, snap)
		}
	}
}

// Session guards that need no trip: anonymous, offline-persistence handled by
// authed gate upstream, missing city, and the no-trip resolution ladder.
func TestShiftDaysFromToolGuards(t *testing.T) {
	s, _ := testPlanSession(false, uuid.Nil)
	if msg, isErr := runShiftDaysFromTool(s, []byte(`{"city":"Porto","days":1}`)); !isErr || !strings.Contains(msg, "signed in") {
		t.Fatalf("anonymous = %q (err=%v)", msg, isErr)
	}

	resetDB(t)
	user, _ := createTestUser(t, "shiftguards@example.com")
	s2, _ := testPlanSession(true, user.ID)
	if msg, isErr := runShiftDaysFromTool(s2, []byte(`{"days":1}`)); !isErr || !strings.Contains(msg, "city is required") {
		t.Fatalf("missing city = %q (err=%v)", msg, isErr)
	}
	if msg, isErr := runShiftDaysFromTool(s2, []byte(`{"city":"Porto","days":1}`)); !isErr || !strings.Contains(msg, "No trip has been saved") {
		t.Fatalf("no-trip = %q (err=%v)", msg, isErr)
	}

	// A dateless trip has no calendar to shift along.
	trip := createTestTrip(t, user.ID, 2)
	s3, _ := testPlanSession(true, user.ID)
	s3.boundTripID = &trip.ID
	if msg, isErr := runShiftDaysFromTool(s3, []byte(`{"city":"Porto","days":1}`)); !isErr || !strings.Contains(msg, "no dates yet") {
		t.Fatalf("dateless trip = %q (err=%v)", msg, isErr)
	}
}

// simulateShiftFrom is pure and must not mutate its inputs — the guard reads
// the same slices the writes will use.
func TestSimulateShiftFromPure(t *testing.T) {
	d4 := int32(4)
	items := []store.ItineraryItem{
		{Position: 0, Name: "a", Day: &d4},
	}
	stays := []store.Accommodation{
		{Name: "s", CheckIn: validDate("2026-09-04"), CheckOut: validDate("2026-09-06")},
	}
	trip := store.Trip{StartDate: validDate("2026-09-01"), EndDate: validDate("2026-09-09")}

	simTrip, simItems, simStays := simulateShiftFrom(trip, items, stays, 4, 2)
	if *items[0].Day != 4 || !stays[0].CheckIn.Time.Equal(civilDate("2026-09-04")) || !trip.EndDate.Time.Equal(civilDate("2026-09-09")) {
		t.Fatal("simulateShiftFrom mutated its inputs")
	}
	if *simItems[0].Day != 6 {
		t.Fatalf("sim item day = %d, want 6", *simItems[0].Day)
	}
	if !simStays[0].CheckIn.Time.Equal(civilDate("2026-09-06")) || !simStays[0].CheckOut.Time.Equal(civilDate("2026-09-08")) {
		t.Fatalf("sim stay = %s/%s, want 2026-09-06/2026-09-08",
			simStays[0].CheckIn.Time.Format(dateLayout), simStays[0].CheckOut.Time.Format(dateLayout))
	}
	if !simTrip.EndDate.Time.Equal(civilDate("2026-09-11")) {
		t.Fatalf("sim trip end = %s, want 2026-09-11", simTrip.EndDate.Time.Format(dateLayout))
	}
}
