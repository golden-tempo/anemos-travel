package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

// Gateway airports (specs/leg-gateway-airports, 00075): an inter-city FLIGHT
// leg whose endpoint city has no airport of its own is relabelled — title,
// endpoint labels, search link — with the nearest real airport, while the
// row's identity stays the city pair. The traveler's word (source
// 'traveler') beats the auto-resolver; ground legs and cities with their own
// airports are left exactly as before; and every Duffel failure degrades to
// the pre-feature rendering.

// fakeGatewayDuffel swaps the singleton for a scripted server. Text queries
// (`query=`) answer from byName; coordinate queries (`lat=`) answer nearby.
// The counter says how many requests actually hit the fake — the table is
// supposed to be the cache.
func fakeGatewayDuffel(t *testing.T, byName map[string]string, nearby string) *atomic.Int64 {
	t.Helper()
	var calls atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.Header().Set("Content-Type", "application/json")
		q := r.URL.Query()
		if q.Get("lat") != "" {
			w.Write([]byte(nearby))
			return
		}
		if body, ok := byName[strings.ToLower(q.Get("query"))]; ok {
			w.Write([]byte(body))
			return
		}
		w.Write([]byte(`{"data":[]}`))
	}))
	t.Cleanup(srv.Close)
	old := duffelService
	duffelService = &DuffelService{
		Token: "test-token", BaseURL: srv.URL, Version: "v2",
		Client:      &http.Client{Timeout: 5 * time.Second},
		placesCache: newTTLCache[[]Airport](time.Minute, 32),
	}
	t.Cleanup(func() { duffelService = old })
	return &calls
}

// gatewayTestTrip builds a signed-in trip whose itinerary renders two legs,
// Faraway → Tinyville, with transatlantic distance so the mode ladder lands
// on flight, and returns (tripID, sync payload). Tinyville is the airportless
// one.
func gatewayTestTrip(t *testing.T, ownerID uuid.UUID) (uuid.UUID, []map[string]any) {
	t.Helper()
	trip := createTestTrip(t, ownerID, 0)
	q := store.New(dbPool)
	city := func(pos int32, name, cityLabel string, lat, lng float64, day int32) {
		d := day
		c := cityLabel
		if _, err := q.CreateItineraryItem(context.Background(), store.CreateItineraryItemParams{
			TripID: trip.ID, Position: pos, Name: name,
			Latitude: lat, Longitude: lng, City: &c, Day: &d,
		}); err != nil {
			t.Fatalf("item %s: %v", name, err)
		}
	}
	city(0, "Big Museum", "Faraway", 40.7, -74.0, 1)
	city(1, "Tiny Lake", "Tinyville", 47.7, 13.6, 3)
	payload := []map[string]any{
		{"kind": "transport", "todo_key": "transport:faraway>>tinyville",
			"title": "Faraway → Tinyville", "origin": "Faraway",
			"destination": "Tinyville", "position": 0, "passengers": 1},
	}
	return trip.ID, payload
}

func syncTodosReq(t *testing.T, tripID uuid.UUID, token string, payload []map[string]any) []map[string]any {
	t.Helper()
	rec := doJSON(t, "PUT", "/api/v1/trips/"+tripID.String()+"/booking-todos", token, payload)
	if rec.Code != http.StatusOK {
		t.Fatalf("sync = %d: %s", rec.Code, rec.Body.String())
	}
	return decodeTodoList(t, rec)
}

func gatewayRows(t *testing.T, tripID uuid.UUID) map[string]store.TripLegGateway {
	t.Helper()
	rows, err := store.New(dbPool).ListTripLegGateways(context.Background(), tripID)
	if err != nil {
		t.Fatalf("list gateways: %v", err)
	}
	out := map[string]store.TripLegGateway{}
	for _, g := range rows {
		out[g.CityFold] = g
	}
	return out
}

func TestSyncRelabelsAirportlessCityFlightLeg(t *testing.T) {
	resetDB(t)
	calls := fakeGatewayDuffel(t,
		map[string]string{
			// Faraway has its own airport — a hit that NAMES the city.
			"faraway": `{"data":[{"name":"Faraway International","iata_code":"FAA","city_name":"Faraway","type":"airport"}]}`,
			// Tinyville: Duffel's fuzzy suggestions return the neighboring
			// hub, which does NOT name Tinyville — the no-airport signal.
			"tinyville": `{"data":[{"name":"Gateway City Airport","iata_code":"GTW","city_name":"Gateway City","type":"airport"}]}`,
		},
		`{"data":[{"name":"Gateway City Airport","iata_code":"GTW","city_name":"Gateway City","type":"airport"}]}`)

	owner, token := createTestUser(t, "gateway@example.com")
	tripID, payload := gatewayTestTrip(t, owner.ID)

	rows := syncTodosReq(t, tripID, token, payload)
	if len(rows) != 1 {
		t.Fatalf("rows = %d, want 1: %v", len(rows), rows)
	}
	row := rows[0]
	if row["todo_key"] != "transport:faraway>>tinyville" {
		t.Fatalf("identity moved: %v", row["todo_key"])
	}
	if row["title"] != "Faraway → Gateway City (GTW)" {
		t.Fatalf("title = %v, want the gateway label", row["title"])
	}
	if row["subtitle"] != "For Tinyville" {
		t.Fatalf("subtitle = %v, want the planned-city qualifier", row["subtitle"])
	}
	if u, _ := row["search_url"].(string); !strings.Contains(u, "GTW") {
		t.Fatalf("search link must target the gateway: %v", u)
	}

	gws := gatewayRows(t, tripID)
	if g := gws["tinyville"]; g.Airport != "GTW" || g.Source != "auto" {
		t.Fatalf("tinyville gateway = %+v, want auto GTW", g)
	}
	if g := gws["faraway"]; g.Airport != "FAA" || g.Source != "self" {
		t.Fatalf("faraway self-cache = %+v, want self FAA", g)
	}

	// The table is the cache: a second sync must not re-ask Duffel.
	before := calls.Load()
	syncTodosReq(t, tripID, token, payload)
	if calls.Load() != before {
		t.Fatalf("re-sync hit Duffel %d more times; the table should cache", calls.Load()-before)
	}
}

func TestTravelerGatewayBeatsAutoResolution(t *testing.T) {
	resetDB(t)
	fakeGatewayDuffel(t, map[string]string{
		"faraway": `{"data":[{"name":"Faraway International","iata_code":"FAA","city_name":"Faraway","type":"airport"}]}`,
	}, `{"data":[{"name":"Gateway City Airport","iata_code":"GTW","city_name":"Gateway City","type":"airport"}]}`)

	owner, token := createTestUser(t, "gateway-traveler@example.com")
	tripID, payload := gatewayTestTrip(t, owner.ID)
	vienna := "Vienna"
	if _, err := store.New(dbPool).UpsertTripLegGateway(context.Background(), store.UpsertTripLegGatewayParams{
		TripID: tripID, CityFold: "tinyville", Airport: "VIE", AirportLabel: &vienna, Source: "traveler",
	}); err != nil {
		t.Fatalf("seed traveler gateway: %v", err)
	}

	rows := syncTodosReq(t, tripID, token, payload)
	if rows[0]["title"] != "Faraway → Vienna (VIE)" {
		t.Fatalf("title = %v, want the traveler's airport", rows[0]["title"])
	}
	if g := gatewayRows(t, tripID)["tinyville"]; g.Airport != "VIE" || g.Source != "traveler" {
		t.Fatalf("traveler gateway overwritten: %+v", g)
	}
}

func TestGatewayDegradesWhenDuffelUnavailable(t *testing.T) {
	resetDB(t)
	old := duffelService
	duffelService = &DuffelService{Token: ""} // disabled, like a deploy without the env var
	t.Cleanup(func() { duffelService = old })

	owner, token := createTestUser(t, "gateway-off@example.com")
	tripID, payload := gatewayTestTrip(t, owner.ID)

	rows := syncTodosReq(t, tripID, token, payload)
	if rows[0]["title"] != "Faraway → Tinyville" {
		t.Fatalf("disabled Duffel must leave the pre-feature title: %v", rows[0]["title"])
	}
	if len(gatewayRows(t, tripID)) != 0 {
		t.Fatalf("disabled Duffel wrote gateway rows")
	}
}

func TestGroundLegKeepsCityLabels(t *testing.T) {
	resetDB(t)
	calls := fakeGatewayDuffel(t, map[string]string{
		"faraway": `{"data":[{"name":"Faraway International","iata_code":"FAA","city_name":"Faraway","type":"airport"}]}`,
	}, `{"data":[{"name":"Gateway City Airport","iata_code":"GTW","city_name":"Gateway City","type":"airport"}]}`)

	owner, token := createTestUser(t, "gateway-ground@example.com")
	tripID, payload := gatewayTestTrip(t, owner.ID)

	// First sync creates the row; the traveler then pins it to train — the
	// override rung the sync reads back — and re-syncs.
	rows := syncTodosReq(t, tripID, token, payload)
	id := rows[0]["id"].(string)
	rec := doJSON(t, "PATCH", "/api/v1/trips/"+tripID.String()+"/booking-todos/"+id, token,
		map[string]any{"mode": "train", "origin": "Faraway", "destination": "Tinyville"})
	if rec.Code != http.StatusOK {
		t.Fatalf("set mode = %d: %s", rec.Code, rec.Body.String())
	}
	resetCalls := calls.Load()
	if _, err := dbPool.Exec(context.Background(), `DELETE FROM trip_leg_gateways WHERE trip_id = $1`, tripID); err != nil {
		t.Fatalf("clear gateways: %v", err)
	}
	rows = syncTodosReq(t, tripID, token, payload)
	if rows[0]["title"] != "Faraway → Tinyville" {
		t.Fatalf("train leg must keep city labels: %v", rows[0]["title"])
	}
	if calls.Load() != resetCalls {
		t.Fatalf("a ground leg asked Duffel about airports")
	}
}

func TestSetLegGatewayToolRelabelsInPlace(t *testing.T) {
	resetDB(t)
	fakeGatewayDuffel(t,
		map[string]string{
			"faraway":   `{"data":[{"name":"Faraway International","iata_code":"FAA","city_name":"Faraway","type":"airport"}]}`,
			"tinyville": `{"data":[]}`,
		},
		`{"data":[{"name":"Gateway City Airport","iata_code":"GTW","city_name":"Gateway City","type":"airport"}]}`)

	owner, token := createTestUser(t, "gateway-tool@example.com")
	tripID, payload := gatewayTestTrip(t, owner.ID)
	syncTodosReq(t, tripID, token, payload) // rows exist, auto-labelled GTW

	fake := newFakeAnthropic(t,
		toolTurn("set_leg_gateway", `{"city":"Tinyville","airport":"VIE","airport_city":"Vienna"}`),
		textTurn("Recorded — flights for Tinyville go through Vienna."))
	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		TripID:   tripID.String(),
		Messages: []PlanChatMessage{{Role: "user", Content: "the airport is actually in Vienna"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d", rec.Code)
	}
	events := planEvents(t, rec.Body.String())
	if updated := eventsOfType(events, "trip_updated"); len(updated) != 1 {
		t.Fatalf("trip_updated events = %v, want exactly one", updated)
	}

	// The tool's result must state the post-state (docs/zen.md): the new
	// title and the code to search with.
	bodies := fake.requestBodies()
	last := string(bodies[len(bodies)-1])
	for _, want := range []string{"Tinyville now flies via Vienna (VIE)", "Faraway → Vienna (VIE)", "Search flights for these legs with VIE"} {
		if !strings.Contains(last, want) {
			t.Fatalf("tool result missing %q:\n%s", want, last)
		}
	}

	todos, _ := store.New(dbPool).ListBookingTodosByTrip(context.Background(), tripID)
	if len(todos) != 1 || todos[0].Title != "Faraway → Vienna (VIE)" || todos[0].TodoKey != "transport:faraway>>tinyville" {
		t.Fatalf("row after tool = %+v", todos)
	}
	if g := gatewayRows(t, tripID)["tinyville"]; g.Airport != "VIE" || g.Source != "traveler" {
		t.Fatalf("gateway after tool = %+v, want traveler VIE", g)
	}
}

func TestSetLegGatewayRefusesUnknownCity(t *testing.T) {
	resetDB(t)
	fakeGatewayDuffel(t, map[string]string{}, `{"data":[]}`)
	owner, token := createTestUser(t, "gateway-unknown@example.com")
	tripID, _ := gatewayTestTrip(t, owner.ID)

	fake := newFakeAnthropic(t,
		toolTurn("set_leg_gateway", `{"city":"Atlantis","airport":"VIE"}`),
		textTurn("ok"))
	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		TripID:   tripID.String(),
		Messages: []PlanChatMessage{{Role: "user", Content: "atlantis flies via vienna"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d", rec.Code)
	}
	bodies := fake.requestBodies()
	last := string(bodies[len(bodies)-1])
	if !strings.Contains(last, "no city named Atlantis") || !strings.Contains(last, "Faraway") {
		t.Fatalf("refusal must name the real cities:\n%s", last)
	}
}
