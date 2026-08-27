package main

import (
	"bytes"
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// These tests pin the /optimize-route wire contract (specs artifact
// day-travel-times, ticket A) at the handler level, decoding into generic maps
// rather than the Go response structs: the pins are about the bytes a client
// receives, and the generic decode also lets every test compile — and fail for
// behavioral reasons, not compile errors — against the pre-fix code.

// postOptimizeRoute runs one request through optimizeRouteHandler and decodes
// the JSON body generically.
func postOptimizeRoute(t *testing.T, request RouteRequest) (int, map[string]any) {
	t.Helper()
	body, err := json.Marshal(request)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/api/v1/optimize-route", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	optimizeRouteHandler(rec, req)

	var decoded map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &decoded); err != nil {
		t.Fatalf("response is not JSON (HTTP %d): %v\n%s", rec.Code, err, rec.Body.String())
	}
	return rec.Code, decoded
}

// timingsOf pulls location_timings as a generic slice, failing loudly when the
// field is missing or null — the exact contract lie (200 + null) being pinned.
func timingsOf(t *testing.T, resp map[string]any) []any {
	t.Helper()
	raw, present := resp["location_timings"]
	if !present || raw == nil {
		t.Fatalf("location_timings is %v (present=%v) — a 200 must never carry a null timings array; body: %v",
			raw, present, resp)
	}
	timings, ok := raw.([]any)
	if !ok {
		t.Fatalf("location_timings is %T, want array", raw)
	}
	return timings
}

func timingEntry(t *testing.T, timings []any, i int) map[string]any {
	t.Helper()
	entry, ok := timings[i].(map[string]any)
	if !ok {
		t.Fatalf("location_timings[%d] is %T, want object", i, timings[i])
	}
	return entry
}

// timingNum reads a numeric field from a timing entry (JSON numbers decode as
// float64), treating an absent field as 0 the way the Dart parser does.
func timingNum(t *testing.T, entry map[string]any, key string) float64 {
	t.Helper()
	raw, present := entry[key]
	if !present {
		return 0
	}
	n, ok := raw.(float64)
	if !ok {
		t.Fatalf("%s is %T, want number", key, raw)
	}
	return n
}

// swapPlacesForRoute points the shared Places singleton at a canned Google
// response for the duration of one test (the same pattern as
// swapLodgingStub; placesDouble builds the service + counting transport).
func swapPlacesForRoute(t *testing.T, body string) *countingTransport {
	t.Helper()
	svc, rt := placesDouble(t, body)
	prev := placesService
	placesService = svc
	t.Cleanup(func() { placesService = prev })
	return rt
}

const placesZeroResultsJSON = `{"status":"ZERO_RESULTS","results":[]}`
const placesRequestDeniedJSON = `{"status":"REQUEST_DENIED","error_message":"key rejected"}`

// amsCoord builds a coordinate-carrying location (never billed to Places).
func amsCoord(id string, lat, lng float64) Location {
	return Location{ID: id, Name: id, Latitude: f64(lat), Longitude: f64(lng)}
}

// TestOptimizeRoutePartialResolutionKeepsOtherTimings is the Mode B pin: one
// unresolvable place must cost exactly its own legs, never the whole response.
// Pre-fix, this request came back 200 with status "error resolving location
// 'Grandmas apartment buzzer 3B'..." and location_timings null.
func TestOptimizeRoutePartialResolutionKeepsOtherTimings(t *testing.T) {
	rt := swapPlacesForRoute(t, placesZeroResultsJSON)

	code, resp := postOptimizeRoute(t, RouteRequest{
		PreserveOrder: true,
		Locations: []Location{
			amsCoord("a", 52.3579, 4.8686),
			amsCoord("b", 52.3739, 4.8875),
			{ID: "x", Name: "Grandmas apartment buzzer 3B"}, // name-only, unresolvable
			amsCoord("c", 52.3660, 4.8930),
		},
	})

	if code != http.StatusOK {
		t.Fatalf("HTTP %d, want 200 (partial resolution is a success); body: %v", code, resp)
	}
	if got := resp["status"]; got != "success" {
		t.Errorf("status = %v, want success", got)
	}

	timings := timingsOf(t, resp)
	if len(timings) != 4 {
		t.Fatalf("got %d timings, want 4 — preserve_order keeps one entry per input location, positionally aligned", len(timings))
	}

	// The a→b leg is between two resolved stops: it must carry real travel.
	first := timingEntry(t, timings, 0)
	if min := timingNum(t, first, "travel_to_next_minutes"); min <= 0 {
		t.Errorf("timings[0].travel_to_next_minutes = %v, want > 0 — the resolvable legs must survive the bad location", min)
	}
	if mode, ok := first["travel_to_next_mode"].(string); !ok || (mode != "walk" && mode != "transit") {
		t.Errorf("timings[0].travel_to_next_mode = %v, want walk|transit", first["travel_to_next_mode"])
	}

	// Legs touching the unresolved location are absent, never guessed: zero
	// minutes/km and no mode field at all.
	for _, i := range []int{1, 2} {
		entry := timingEntry(t, timings, i)
		if min := timingNum(t, entry, "travel_to_next_minutes"); min != 0 {
			t.Errorf("timings[%d].travel_to_next_minutes = %v, want 0 (leg touches the unresolved stop)", i, min)
		}
		if _, has := entry["travel_to_next_mode"]; has {
			t.Errorf("timings[%d] carries travel_to_next_mode %v — an uncomputed leg must not claim a mode", i, entry["travel_to_next_mode"])
		}
	}

	// The skip is reported by name.
	unresolved, ok := resp["unresolved"].([]any)
	if !ok || len(unresolved) != 1 || unresolved[0] != "Grandmas apartment buzzer 3B" {
		t.Errorf("unresolved = %v, want [Grandmas apartment buzzer 3B]", resp["unresolved"])
	}

	// preserve_order keeps every input location in the route, in order.
	route, ok := resp["optimized_route"].([]any)
	if !ok || len(route) != 4 {
		t.Fatalf("optimized_route = %v, want 4 entries", resp["optimized_route"])
	}
	for i, wantID := range []string{"a", "b", "x", "c"} {
		entry := route[i].(map[string]any)
		if entry["id"] != wantID {
			t.Errorf("optimized_route[%d].id = %v, want %s", i, entry["id"], wantID)
		}
	}

	// Coordinate-carrying locations never bill Google: exactly one lookup (x).
	if rt.calls != 1 {
		t.Errorf("Places called %d times, want 1 (only the name-only location resolves)", rt.calls)
	}
}

// TestOptimizeRouteAllUnresolvedIsNot200 pins the residual whole-request
// failure as an honest non-200. Pre-fix it was a 200 whose status field
// carried an error string and whose arrays were null.
func TestOptimizeRouteAllUnresolvedIsNot200(t *testing.T) {
	request := RouteRequest{
		PreserveOrder: true,
		Locations: []Location{
			{ID: "x1", Name: "Nonexistent Place One"},
			{ID: "x2", Name: "Nonexistent Place Two"},
		},
	}

	t.Run("places_finds_nothing_is_422", func(t *testing.T) {
		swapPlacesForRoute(t, placesZeroResultsJSON)
		code, resp := postOptimizeRoute(t, request)
		if code != http.StatusUnprocessableEntity {
			t.Fatalf("HTTP %d, want 422; body: %v", code, resp)
		}
		if resp["status"] != "error" {
			t.Errorf("status = %v, want error", resp["status"])
		}
		msg, _ := resp["message"].(string)
		if !strings.Contains(msg, "Nonexistent Place One") || !strings.Contains(msg, "Nonexistent Place Two") {
			t.Errorf("message %q does not name the unresolved locations", msg)
		}
	})

	t.Run("provider_outage_is_503", func(t *testing.T) {
		swapPlacesForRoute(t, placesRequestDeniedJSON)
		code, resp := postOptimizeRoute(t, request)
		if code != http.StatusServiceUnavailable {
			t.Fatalf("HTTP %d, want 503; body: %v", code, resp)
		}
		if resp["status"] != "error" {
			t.Errorf("status = %v, want error", resp["status"])
		}
	})
}

// TestOptimizeRouteTravelHeuristic pins the settled heuristic: detour factor
// 1.3 on haversine, walk at/below 1.5 corrected km at 5 km/h, transit above at
// 15 km/h, integer ceil minutes, icon mode carried per leg. Four stops on one
// meridian give exact straight-line distances (R·Δφ):
//
//	p0→p1 2.4 km → 3.12 corrected → transit → 12.48 → 13 min
//	p1→p2 1.0 km → 1.30 corrected → walk    → 15.60 → 16 min
//	p2→p3 1.2 km → 1.56 corrected → transit →  6.24 →  7 min  (threshold reads CORRECTED km)
//
// Pre-fix p0→p1 was "4 min" by car — the spec's Vondelpark→'t Smalle bug.
func TestOptimizeRouteTravelHeuristic(t *testing.T) {
	const kmPerDegLat = 111.19492664 // 2πR/360, R=6371
	lat0 := 52.0
	lat1 := lat0 + 2.4/kmPerDegLat
	lat2 := lat1 + 1.0/kmPerDegLat
	lat3 := lat2 + 1.2/kmPerDegLat

	code, resp := postOptimizeRoute(t, RouteRequest{
		PreserveOrder: true,
		Locations: []Location{
			amsCoord("p0", lat0, 4.9),
			amsCoord("p1", lat1, 4.9),
			amsCoord("p2", lat2, 4.9),
			amsCoord("p3", lat3, 4.9),
		},
	})
	if code != http.StatusOK {
		t.Fatalf("HTTP %d, want 200; body: %v", code, resp)
	}

	timings := timingsOf(t, resp)
	if len(timings) != 4 {
		t.Fatalf("got %d timings, want 4", len(timings))
	}

	wantLegs := []struct {
		minutes float64
		km      float64
		mode    string
	}{
		{13, 3.12, "transit"},
		{16, 1.30, "walk"},
		{7, 1.56, "transit"},
	}
	for i, want := range wantLegs {
		entry := timingEntry(t, timings, i)
		if got := timingNum(t, entry, "travel_to_next_minutes"); got != want.minutes {
			t.Errorf("leg %d minutes = %v, want %v", i, got, want.minutes)
		}
		if got := timingNum(t, entry, "travel_to_next_km"); math.Abs(got-want.km) > 0.011 {
			t.Errorf("leg %d km = %v, want ~%v (detour-corrected)", i, got, want.km)
		}
		if got, _ := entry["travel_to_next_mode"].(string); got != want.mode {
			t.Errorf("leg %d mode = %q, want %q", i, got, want.mode)
		}
	}

	// The last stop of a one-way route has no leg and therefore no mode.
	last := timingEntry(t, timings, 3)
	if _, has := last["travel_to_next_mode"]; has {
		t.Errorf("last timing carries a mode: %v", last["travel_to_next_mode"])
	}

	// Totals are the sum of the per-leg values the client can see.
	if got := resp["total_travel_time_minutes"].(float64); got != 13+16+7 {
		t.Errorf("total_travel_time_minutes = %v, want %d", got, 13+16+7)
	}
	if got := resp["total_distance_km"].(float64); math.Abs(got-(3.12+1.30+1.56)) > 0.02 {
		t.Errorf("total_distance_km = %v, want ~%v", got, 3.12+1.30+1.56)
	}
}

// TestOptimizeRouteOptimizeModeExcludesUnresolved pins the non-preserve-order
// arm: a location that failed resolution has no honest place in a COMPUTED
// order, so it is excluded from optimized_route/location_timings and reported
// in unresolved instead.
func TestOptimizeRouteOptimizeModeExcludesUnresolved(t *testing.T) {
	swapPlacesForRoute(t, placesZeroResultsJSON)

	code, resp := postOptimizeRoute(t, RouteRequest{
		Locations: []Location{
			amsCoord("a", 52.3579, 4.8686),
			{ID: "x", Name: "Grandmas apartment buzzer 3B"},
			amsCoord("b", 52.3739, 4.8875),
			amsCoord("c", 52.3660, 4.8930),
		},
	})
	if code != http.StatusOK {
		t.Fatalf("HTTP %d, want 200; body: %v", code, resp)
	}

	timings := timingsOf(t, resp)
	if len(timings) != 3 {
		t.Fatalf("got %d timings, want 3 (the unresolved location is excluded from a computed order)", len(timings))
	}
	route, _ := resp["optimized_route"].([]any)
	if len(route) != 3 {
		t.Fatalf("optimized_route has %d entries, want 3", len(route))
	}
	seen := map[any]bool{}
	for _, raw := range route {
		seen[raw.(map[string]any)["id"]] = true
	}
	if seen["x"] || !seen["a"] || !seen["b"] || !seen["c"] {
		t.Errorf("optimized_route ids = %v, want exactly {a,b,c}", seen)
	}
	unresolved, ok := resp["unresolved"].([]any)
	if !ok || len(unresolved) != 1 || unresolved[0] != "Grandmas apartment buzzer 3B" {
		t.Errorf("unresolved = %v, want the skipped location by name", resp["unresolved"])
	}

	// Every leg between the three resolved stops carries mode + minutes; the
	// route's final stop has neither (one-way).
	for i := 0; i < 2; i++ {
		entry := timingEntry(t, timings, i)
		if min := timingNum(t, entry, "travel_to_next_minutes"); min <= 0 {
			t.Errorf("timings[%d].travel_to_next_minutes = %v, want > 0", i, min)
		}
		if _, hasMode := entry["travel_to_next_mode"]; !hasMode {
			t.Errorf("timings[%d] missing travel_to_next_mode", i)
		}
	}
	if _, has := timingEntry(t, timings, 2)["travel_to_next_mode"]; has {
		t.Errorf("final stop carries a mode")
	}
}
