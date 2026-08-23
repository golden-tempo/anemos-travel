package main

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

// booking_todo_city_integration_test.go — city_label (00074,
// specs/booking-city-grouping): the explicit city a booking files under, the
// sync-time date fallback that fills it, and the two writers that must stay
// one writer.

// seedAmsterdamPragueTrip builds the spec's own fixture: Amsterdam Aug 24–26
// and Prague Aug 26–29, sharing Aug 26 as their transition day. Stays anchor
// the leg ranges exactly (computeTripLegs' highest-precedence source), so the
// legs the fallback consults are these dates and not an allocation guess.
func seedAmsterdamPragueTrip(t *testing.T, trip store.Trip, owner uuid.UUID) {
	t.Helper()
	ctx := context.Background()
	q := store.New(dbPool)
	if _, err := q.UpdateTrip(ctx, store.UpdateTripParams{
		ID: trip.ID, UserID: owner,
		StartDate: validDate("2026-08-24"), EndDate: validDate("2026-08-29"),
	}); err != nil {
		t.Fatalf("seed trip dates: %v", err)
	}
	seed := func(pos int, name, city string, day int) {
		t.Helper()
		d := int32(day)
		if _, err := q.CreateItineraryItem(ctx, store.CreateItineraryItemParams{
			TripID: trip.ID, Position: int32(pos), Name: name, City: &city, Day: &d,
			Latitude: 52.37 + float64(pos)*0.01, Longitude: 4.9,
		}); err != nil {
			t.Fatalf("seed item %s: %v", name, err)
		}
	}
	seed(0, "Rijksmuseum", "Amsterdam", 1)
	seed(1, "Moeders", "Amsterdam", 2)
	seed(2, "Old Town Square", "Prague", 4)
	seed(3, "Door 74 of Prague", "Prague", 5)
	if _, err := q.CreateAccommodation(ctx, store.CreateAccommodationParams{
		TripID: trip.ID, Name: "Amsterdam Stay",
		CheckIn: validDate("2026-08-24"), CheckOut: validDate("2026-08-26"),
	}); err != nil {
		t.Fatalf("seed Amsterdam stay: %v", err)
	}
	if _, err := q.CreateAccommodation(ctx, store.CreateAccommodationParams{
		TripID: trip.ID, Name: "Prague Stay",
		CheckIn: validDate("2026-08-26"), CheckOut: validDate("2026-08-29"),
	}); err != nil {
		t.Fatalf("seed Prague stay: %v", err)
	}
}

// addOtherTodo creates a custom `other` booking through the public POST — the
// same door the "+ Add booking" dialog uses — and returns its id.
func addOtherTodo(t *testing.T, token, tripID, title string, departDate *string) string {
	t.Helper()
	body := map[string]any{"kind": "other", "title": title}
	if departDate != nil {
		body["depart_date"] = *departDate
	}
	rec := doJSON(t, "POST", "/api/v1/trips/"+tripID+"/booking-todos", token, body)
	if rec.Code != http.StatusCreated {
		t.Fatalf("add todo %q = %d: %s", title, rec.Code, rec.Body.String())
	}
	return decode(t, rec)["id"].(string)
}

// syncStays runs the derived-todo sync (any valid payload triggers the
// city-label fallback) and returns the response rows keyed by id.
func syncStays(t *testing.T, token, tripID string) map[string]map[string]any {
	t.Helper()
	payload := []map[string]any{
		{"kind": "stay", "todo_key": "stay:amsterdam", "title": "Stay in Amsterdam",
			"destination": "Amsterdam", "position": 0,
			"depart_date": "2026-08-24", "return_date": "2026-08-26", "guests": 2},
		{"kind": "stay", "todo_key": "stay:prague", "title": "Stay in Prague",
			"destination": "Prague", "position": 1,
			"depart_date": "2026-08-26", "return_date": "2026-08-29", "guests": 2},
	}
	rec := doJSON(t, "PUT", "/api/v1/trips/"+tripID+"/booking-todos", token, payload)
	if rec.Code != http.StatusOK {
		t.Fatalf("sync = %d: %s", rec.Code, rec.Body.String())
	}
	out := map[string]map[string]any{}
	for _, row := range decodeTodoList(t, rec) {
		out[row["id"].(string)] = row
	}
	return out
}

func storedCityLabel(t *testing.T, todoID string) *string {
	t.Helper()
	var label *string
	if err := dbPool.QueryRow(context.Background(),
		`SELECT city_label FROM booking_todos WHERE id = $1`, todoID).Scan(&label); err != nil {
		t.Fatalf("read city_label: %v", err)
	}
	return label
}

// The sync-time date fallback: an unambiguous date fills the city, the shared
// transition day refuses to guess, and an explicit value is never overwritten
// — the heart of the feature, in the owner's own fixture.
func TestSyncFillsCityLabelFromUnambiguousDate(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "citylabel@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	seedAmsterdamPragueTrip(t, trip, owner.ID)
	tripID := trip.ID.String()

	aug24, aug26 := "2026-08-24", "2026-08-26"
	moeders := addOtherTodo(t, token, tripID, "Reserve table at Moeders", &aug24)
	// Aug 26 is Amsterdam's last day AND Prague's arrival — the date cannot
	// say which city the lookout is in, so the server must not pick one.
	lookout := addOtherTodo(t, token, tripID, "Book A'DAM Lookout entry", &aug26)
	insurance := addOtherTodo(t, token, tripID, "Book travel insurance", nil)

	rows := syncStays(t, token, tripID)
	if got := rows[moeders]["city_label"]; got != "Amsterdam" {
		t.Fatalf("unambiguous Aug 24 booking city = %v, want Amsterdam", got)
	}
	if got := rows[lookout]["city_label"]; got != nil {
		t.Fatalf("transition-day booking must stay under Other bookings, got city %v", got)
	}
	if got := rows[insurance]["city_label"]; got != nil {
		t.Fatalf("undated booking must stay under Other bookings, got city %v", got)
	}

	// An explicit value survives every later sync — the fallback fills NULL
	// and nothing else. (Prague here is deliberately NOT what the date rule
	// would derive for Aug 24.)
	if rec := doJSON(t, "PATCH", "/api/v1/trips/"+tripID+"/booking-todos/"+moeders,
		token, map[string]any{"city_label": "Prague"}); rec.Code != http.StatusOK {
		t.Fatalf("patch city = %d: %s", rec.Code, rec.Body.String())
	}
	rows = syncStays(t, token, tripID)
	if got := rows[moeders]["city_label"]; got != "Prague" {
		t.Fatalf("explicit city overwritten by the date fallback: %v", got)
	}
	// And the transition-day row honours an explicit assignment too — the
	// spec's "derivation never overrides" case.
	if rec := doJSON(t, "PATCH", "/api/v1/trips/"+tripID+"/booking-todos/"+lookout,
		token, map[string]any{"city_label": "Amsterdam"}); rec.Code != http.StatusOK {
		t.Fatalf("patch city = %d: %s", rec.Code, rec.Body.String())
	}
	rows = syncStays(t, token, tripID)
	if got := rows[lookout]["city_label"]; got != "Amsterdam" {
		t.Fatalf("explicit transition-day city lost on sync: %v", got)
	}
}

// The PATCH lane: sets, clears (""), travels alone, and never touches an auto
// row — a derived leg's city is its identity, not a tag.
func TestPatchBookingTodoCityLabel(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "citypatch@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	seedAmsterdamPragueTrip(t, trip, owner.ID)
	tripID := trip.ID.String()

	todoID := addOtherTodo(t, token, tripID, "Reserve table at Renvy", nil)
	rec := doJSON(t, "PATCH", "/api/v1/trips/"+tripID+"/booking-todos/"+todoID,
		token, map[string]any{"city_label": "Amsterdam"})
	if rec.Code != http.StatusOK || decode(t, rec)["city_label"] != "Amsterdam" {
		t.Fatalf("set city = %d: %s", rec.Code, rec.Body.String())
	}
	// "" clears — the move back to "Other bookings". NULL, not empty string:
	// one representation of "no city" (the trip-summary rule).
	rec = doJSON(t, "PATCH", "/api/v1/trips/"+tripID+"/booking-todos/"+todoID,
		token, map[string]any{"city_label": ""})
	if rec.Code != http.StatusOK || decode(t, rec)["city_label"] != nil {
		t.Fatalf("clear city = %d: %s", rec.Code, rec.Body.String())
	}
	if got := storedCityLabel(t, todoID); got != nil {
		t.Fatalf("cleared city stored as %q, want NULL", *got)
	}

	// The lane travels alone, like mode.
	rec = doJSON(t, "PATCH", "/api/v1/trips/"+tripID+"/booking-todos/"+todoID,
		token, map[string]any{"city_label": "Amsterdam", "title": "Renamed"})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("city+title = %d, want 400: %s", rec.Code, rec.Body.String())
	}
	rec = doJSON(t, "PATCH", "/api/v1/trips/"+tripID+"/booking-todos/"+todoID,
		token, map[string]any{"mode": "train", "city_label": "Amsterdam",
			"origin": "A", "destination": "B"})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("mode+city = %d, want 400: %s", rec.Code, rec.Body.String())
	}

	// An auto row refuses: 404, indistinguishable from a missing row.
	rows := syncStays(t, token, tripID)
	var autoID string
	for id, row := range rows {
		if row["auto"] == true {
			autoID = id
			break
		}
	}
	if autoID == "" {
		t.Fatal("no auto row to test against")
	}
	rec = doJSON(t, "PATCH", "/api/v1/trips/"+tripID+"/booking-todos/"+autoID,
		token, map[string]any{"city_label": "Amsterdam"})
	if rec.Code != http.StatusNotFound {
		t.Fatalf("auto-row city patch = %d, want 404: %s", rec.Code, rec.Body.String())
	}
}

// The trip page's "Move to…" and the agent's update_booking_todo `city` are
// one writer (SetBookingTodoCityLabel) — same stored value, same clear.
// The endpoint/description parity pins' sibling.
func TestPageAndChatWriteTheSameCityLabel(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "cityparity@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	tripID := trip.ID.String()

	viaPage := addOtherTodo(t, token, tripID, "Reserve table at Moeders", nil)
	viaChat := addOtherTodo(t, token, tripID, "Book Rijksmuseum timed entry", nil)

	if rec := doJSON(t, "PATCH", "/api/v1/trips/"+tripID+"/booking-todos/"+viaPage,
		token, map[string]any{"city_label": "Amsterdam"}); rec.Code != http.StatusOK {
		t.Fatalf("page write = %d: %s", rec.Code, rec.Body.String())
	}
	s, _ := testPlanSession(true, owner.ID)
	input, _ := json.Marshal(map[string]any{
		"trip_id": tripID, "todo_id": viaChat, "city": "Amsterdam"})
	msg, isErr := runUpdateBookingTodoTool(s, input)
	if isErr {
		t.Fatalf("chat write errored: %s", msg)
	}
	// The tool result states the post-state the traveler will observe.
	if want := "under Amsterdam's bookings"; !strings.Contains(msg, want) {
		t.Fatalf("tool result %q does not state the filing %q", msg, want)
	}

	pageVal, chatVal := storedCityLabel(t, viaPage), storedCityLabel(t, viaChat)
	if strPtrVal(pageVal) != "Amsterdam" || strPtrVal(chatVal) != "Amsterdam" {
		t.Fatalf("stored city diverges: page %v vs chat %v", pageVal, chatVal)
	}

	// Both surfaces must also agree on clearing — the write COALESCE could
	// not carry.
	if rec := doJSON(t, "PATCH", "/api/v1/trips/"+tripID+"/booking-todos/"+viaPage,
		token, map[string]any{"city_label": ""}); rec.Code != http.StatusOK {
		t.Fatalf("page clear = %d: %s", rec.Code, rec.Body.String())
	}
	input, _ = json.Marshal(map[string]any{
		"trip_id": tripID, "todo_id": viaChat, "city": ""})
	if msg, isErr := runUpdateBookingTodoTool(s, input); isErr {
		t.Fatalf("chat clear errored: %s", msg)
	} else if want := `under "Other bookings"`; !strings.Contains(msg, want) {
		t.Fatalf("clear result %q does not state the filing %q", msg, want)
	}
	if p, c := storedCityLabel(t, viaPage), storedCityLabel(t, viaChat); p != nil || c != nil {
		t.Fatalf("clearing diverges: page %v vs chat %v", p, c)
	}
}

// add_booking_todo files the row at creation when the model names the city.
func TestAgentAddBookingTodoWithCity(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "cityadd@example.com")
	trip := createTestTrip(t, owner.ID, 0)

	s, _ := testPlanSession(true, owner.ID)
	input, _ := json.Marshal(map[string]any{
		"trip_id": trip.ID.String(), "kind": "other",
		"title": "Reserve table at Moeders", "depart_date": "2026-08-24",
		"city": "Amsterdam"})
	msg, isErr := runAddBookingTodoTool(s, input)
	if isErr {
		t.Fatalf("add errored: %s", msg)
	}
	if want := "under Amsterdam's bookings"; !strings.Contains(msg, want) {
		t.Fatalf("add result %q does not state the filing %q", msg, want)
	}
	var label *string
	if err := dbPool.QueryRow(context.Background(),
		`SELECT city_label FROM booking_todos WHERE trip_id = $1`, trip.ID).Scan(&label); err != nil {
		t.Fatalf("read row: %v", err)
	}
	if strPtrVal(label) != "Amsterdam" {
		t.Fatalf("stored city = %v, want Amsterdam", label)
	}
}

// cityLabelForDate is the pure heart of the fallback: exactly-one covers
// fills, a shared transition day refuses, and placeholder legs never claim.
func TestCityLabelForDate(t *testing.T) {
	day := func(s string) *time.Time {
		d, err := time.Parse("2006-01-02", s)
		if err != nil {
			t.Fatalf("parse %s: %v", s, err)
		}
		return &d
	}
	legs := []RenderLeg{
		{Label: "Amsterdam", Start: day("2026-08-24"), End: day("2026-08-26")},
		{Label: "Prague", Start: day("2026-08-26"), End: day("2026-08-29")},
		{Label: otherPlacesLabel, Start: day("2026-08-20"), End: day("2026-08-23")},
		{Label: "Undated"}, // no span — never covers
	}
	cases := []struct {
		date, want string
	}{
		{"2026-08-24", "Amsterdam"},
		{"2026-08-25", "Amsterdam"},
		{"2026-08-26", ""}, // the shared transition day: two covering legs
		{"2026-08-27", "Prague"},
		{"2026-08-29", "Prague"}, // inclusive end
		{"2026-08-21", ""},       // only the placeholder leg covers — no city
		{"2026-09-15", ""},       // outside every leg
	}
	for _, tc := range cases {
		if got := cityLabelForDate(legs, *day(tc.date)); got != tc.want {
			t.Errorf("cityLabelForDate(%s) = %q, want %q", tc.date, got, tc.want)
		}
	}
}
