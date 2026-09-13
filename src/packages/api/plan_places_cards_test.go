package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// runPlanHandlerFromIP posts like runPlanHandler but from a unique client IP,
// so these anonymous /plan tests never share the per-IP daily plan cap
// (abuse_caps.go, in-memory) with the rest of the suite.
func runPlanHandlerFromIP(t *testing.T, req PlanRequest) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	rec := httptest.NewRecorder()
	httpReq := httptest.NewRequest("POST", "/api/v1/plan", bytes.NewReader(body))
	httpReq.Header.Set("X-Forwarded-For", nextTestIP())
	planHandler(rec, httpReq)
	return rec
}

// Photo cards for chat recommendations: search_places must emit a `places`
// SSE side event (capped, gate-registered) while the model-facing tool_result
// stays free of photo refs.

// fakeSearchBodyWithPhotos builds a Text Search response with n results, each
// carrying photo_reference "REF-<i>".
func fakeSearchBodyWithPhotos(n int) string {
	var results []string
	for i := 0; i < n; i++ {
		results = append(results, fmt.Sprintf(
			`{"place_id":"p%d","name":"Taverna %d","formatted_address":"Athens %d","geometry":{"location":{"lat":37.9,"lng":23.7}},"types":["restaurant"],"rating":4.5,"price_level":2,"photos":[{"photo_reference":"REF-%d","html_attributions":["<a href=\"x\">Snapper %d</a>"]}]}`,
			i, i, i, i, i))
	}
	return `{"status":"OK","results":[` + strings.Join(results, ",") + `]}`
}

func TestPlanSearchPlacesEmitsCappedPlacesCards(t *testing.T) {
	fa := newFakeAnthropic(t,
		toolTurn("search_places", `{"query":"dinner in athens"}`),
		textTurn("Here are some tavernas."),
	)

	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.Client = &http.Client{Transport: &countingTransport{body: fakeSearchBodyWithPhotos(10)}}
	swapPlacesService(t, svc)

	rec := runPlanHandlerFromIP(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "where should I eat in Athens?"},
	}})
	events := planEvents(t, rec.Body.String())
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}

	placesEvents := eventsOfType(events, "places")
	if len(placesEvents) != 1 {
		t.Fatalf("places events = %d, want 1", len(placesEvents))
	}
	data := eventData(placesEvents[0])
	if got := data["query"]; got != "dinner in athens" {
		t.Fatalf("query = %v", got)
	}
	cards, ok := data["places"].([]any)
	if !ok || len(cards) != planPlacesCardCap {
		t.Fatalf("cards = %T len %d, want %d (capped)", data["places"], len(cards), planPlacesCardCap)
	}
	first, _ := cards[0].(map[string]any)
	for _, key := range []string{"name", "place_id", "address", "lat", "lng", "rating", "price_level", "category", "photo_ref", "photo_attribution"} {
		if _, present := first[key]; !present {
			t.Fatalf("card missing %q: %v", key, first)
		}
	}
	if first["category"] != "restaurant" {
		t.Fatalf("category = %v, want restaurant", first["category"])
	}
	if first["photo_ref"] != "REF-0" || first["photo_attribution"] != "Snapper 0" {
		t.Fatalf("photo fields = %v / %v", first["photo_ref"], first["photo_attribution"])
	}

	// Emitted refs are servable; the ninth result fell outside the cap, so its
	// ref was never handed to a client and must stay gated.
	if !placesService.photoRefAllowed("REF-0") || !placesService.photoRefAllowed("REF-7") {
		t.Fatal("emitted card refs not registered with the photo gate")
	}
	if placesService.photoRefAllowed("REF-8") {
		t.Fatal("ref beyond the card cap must not be gate-registered")
	}

	// The model's tool_result (second Anthropic request carries it) must not
	// contain photo refs — they are client-only payload.
	bodies := fa.requestBodies()
	if len(bodies) != 2 {
		t.Fatalf("anthropic calls = %d, want 2", len(bodies))
	}
	if strings.Contains(string(bodies[1]), "REF-0") || strings.Contains(string(bodies[1]), "photo_ref") {
		t.Fatalf("tool_result leaks photo refs to the model")
	}
	// The full (uncapped) result list still reaches the model.
	if !strings.Contains(string(bodies[1]), "Taverna 9") {
		t.Fatalf("tool_result missing uncapped results")
	}
}

// TestRankPlacesByRating covers the pure sort: descending by rating, unrated
// places pushed to the back, ties (including nil-vs-nil) keeping their
// original relative order — the same contract rankParkingResults documents
// for parking, applied here to search_places/search_nearby results.
func TestRankPlacesByRating(t *testing.T) {
	rating := func(v float64) *float64 { return &v }
	in := []PlaceSearchResult{
		{Name: "Mid", Rating: rating(4.0)},
		{Name: "Unrated A"},
		{Name: "Top", Rating: rating(4.9)},
		{Name: "Tie A", Rating: rating(4.5)},
		{Name: "Tie B", Rating: rating(4.5)},
		{Name: "Unrated B"},
	}
	got := rankPlacesByRating(in)
	var order []string
	for _, r := range got {
		order = append(order, r.Name)
	}
	want := []string{"Top", "Tie A", "Tie B", "Mid", "Unrated A", "Unrated B"}
	if len(order) != len(want) {
		t.Fatalf("order = %v, want %v", order, want)
	}
	for i := range want {
		if order[i] != want[i] {
			t.Fatalf("order = %v, want %v", order, want)
		}
	}
	// The input slice itself is untouched — callers that hold onto the
	// original (rankParkingResults' merge step, tests) must not see it
	// reordered out from under them.
	if in[0].Name != "Mid" {
		t.Fatalf("rankPlacesByRating mutated its input: in[0] = %v", in[0].Name)
	}
}

// fakeSearchBodyWithRatings builds a Text Search response where each result's
// rating is given explicitly by index, so a test can put the "best" place
// wherever Google's raw relevance order would bury it.
func fakeSearchBodyWithRatings(ratings []float64) string {
	var results []string
	for i, rating := range ratings {
		results = append(results, fmt.Sprintf(
			`{"place_id":"p%d","name":"Place %d","formatted_address":"Athens %d","geometry":{"location":{"lat":37.9,"lng":23.7}},"types":["restaurant"],"rating":%v,"price_level":2,"photos":[{"photo_reference":"REF-%d","html_attributions":["<a href=\"x\">Snapper %d</a>"]}]}`,
			i, i, i, rating, i, i))
	}
	return `{"status":"OK","results":[` + strings.Join(results, ",") + `]}`
}

// TestRankPlacesByRatingTieBreaksByReviewCount covers the addition on top of
// TestRankPlacesByRating: Google ratings only carry one decimal digit, so
// equally-rated results are the norm at the top of a search, not an edge
// case, and a rating-only sort left them in Google's raw (non-quality) order
// — exactly how a traveler's actual top pick could rating-tie its way behind
// a card nobody asked about. Reviews-total settles the tie, most-reviewed
// first; a genuine tie on both keeps Google's original relative order.
func TestRankPlacesByRatingTieBreaksByReviewCount(t *testing.T) {
	rating := func(v float64) *float64 { return &v }
	reviews := func(n int) *int { return &n }
	in := []PlaceSearchResult{
		{Name: "Raw-first, thin reviews", Rating: rating(4.9), UserRatingsTotal: reviews(6)},
		{Name: "Raw-second, well-reviewed", Rating: rating(4.9), UserRatingsTotal: reviews(2400)},
		{Name: "No review count", Rating: rating(4.9)},
		{Name: "Lower rating, huge review count", Rating: rating(4.7), UserRatingsTotal: reviews(50000)},
	}
	got := rankPlacesByRating(in)
	var order []string
	for _, r := range got {
		order = append(order, r.Name)
	}
	want := []string{
		"Raw-second, well-reviewed",
		"Raw-first, thin reviews",
		"No review count",
		"Lower rating, huge review count",
	}
	if len(order) != len(want) {
		t.Fatalf("order = %v, want %v", order, want)
	}
	for i := range want {
		if order[i] != want[i] {
			t.Fatalf("order = %v, want %v", order, want)
		}
	}
}

// TestPlanSearchPlacesRanksCardsByRatingSurvivingCap reproduces the reported
// defect: the traveler's best option (the highest-rated result) sat beyond
// planPlacesCardCap in Google's raw order and never reached the client's
// tiles at all, even though the model itself could see and recommend it from
// the uncapped tool_result. Ranking by rating before slicing means the best
// place always survives the cap, and leads the strip.
func TestPlanSearchPlacesRanksCardsByRatingSurvivingCap(t *testing.T) {
	fa := newFakeAnthropic(t,
		toolTurn("search_places", `{"query":"coffee shop gothenburg"}`),
		textTurn("I'd lean Place 9 if you want a spot to sit and wind down."),
	)

	// 10 results, Google-relevance-ordered; the best-rated one (4.9) sits at
	// index 9 — past the 8-card cap — while the first 8 are all mediocre.
	ratings := []float64{3.9, 4.0, 4.1, 4.0, 3.8, 4.2, 4.0, 4.1, 3.7, 4.9}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.Client = &http.Client{Transport: &countingTransport{body: fakeSearchBodyWithRatings(ratings)}}
	swapPlacesService(t, svc)

	rec := runPlanHandlerFromIP(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "best quiet coffee shop near me in Gothenburg?"},
	}})
	events := planEvents(t, rec.Body.String())
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}

	placesEvents := eventsOfType(events, "places")
	if len(placesEvents) != 1 {
		t.Fatalf("places events = %d, want 1", len(placesEvents))
	}
	data := eventData(placesEvents[0])
	cards, ok := data["places"].([]any)
	if !ok || len(cards) != planPlacesCardCap {
		t.Fatalf("cards = %T len %d, want %d (capped)", data["places"], len(cards), planPlacesCardCap)
	}
	first, _ := cards[0].(map[string]any)
	if first["name"] != "Place 9" {
		t.Fatalf("first card = %v, want the 4.9-rated Place 9 to lead despite its raw position", first["name"])
	}
	if first["rating"] != 4.9 {
		t.Fatalf("first card rating = %v, want 4.9", first["rating"])
	}

	// The model's own tool_result carries the same ranked order, so its
	// recommendation is drawn from a list that already leads with the best
	// option — not just the client's cards.
	bodies := fa.requestBodies()
	if len(bodies) != 2 {
		t.Fatalf("anthropic calls = %d, want 2", len(bodies))
	}
	firstIdx := strings.Index(string(bodies[1]), `\"name\":\"Place 9\"`)
	if firstIdx == -1 {
		firstIdx = strings.Index(string(bodies[1]), `"name":"Place 9"`)
	}
	otherIdx := strings.Index(string(bodies[1]), `"name":"Place 0"`)
	if otherIdx == -1 {
		otherIdx = strings.Index(string(bodies[1]), `\"name\":\"Place 0\"`)
	}
	if firstIdx == -1 || otherIdx == -1 || firstIdx > otherIdx {
		t.Fatalf("tool_result did not rank Place 9 ahead of Place 0: %s", string(bodies[1]))
	}
}

// fakeSearchBodyWithRatingsAndReviews is fakeSearchBodyWithRatings plus an
// explicit user_ratings_total per result, for tie-break scenarios.
func fakeSearchBodyWithRatingsAndReviews(ratings []float64, reviewCounts []int) string {
	var results []string
	for i, rating := range ratings {
		results = append(results, fmt.Sprintf(
			`{"place_id":"p%d","name":"Place %d","formatted_address":"Athens %d","geometry":{"location":{"lat":37.9,"lng":23.7}},"types":["restaurant"],"rating":%v,"user_ratings_total":%d,"price_level":2,"photos":[{"photo_reference":"REF-%d","html_attributions":["<a href=\"x\">Snapper %d</a>"]}]}`,
			i, i, i, rating, reviewCounts[i], i, i))
	}
	return `{"status":"OK","results":[` + strings.Join(results, ",") + `]}`
}

// TestPlanSearchPlacesTiedRatingLeadsWithMoreReviews reproduces the follow-up
// defect reported in #633: rating alone survived the cap (#631/#632) but two
// results tied at the SAME rating — the norm at the top of a search, since
// Google ratings only carry one decimal digit — still left the client's lead
// card at the mercy of Google's raw (non-quality) order. The place with far
// more reviews at the same rating is the more trustworthy "top recommendation"
// and must lead, in both the client's cards and the model's own tool_result.
func TestPlanSearchPlacesTiedRatingLeadsWithMoreReviews(t *testing.T) {
	fa := newFakeAnthropic(t,
		toolTurn("search_places", `{"query":"speakeasy cocktail bar naples italy"}`),
		textTurn("I'd suggest Place 3 as your first stop."),
	)

	// All four rate 4.9 (a real tie); Place 3 sits last in Google's raw
	// order despite having far more reviews than the other three.
	ratings := []float64{4.9, 4.9, 4.9, 4.9}
	reviewCounts := []int{40, 12, 5, 900}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.Client = &http.Client{Transport: &countingTransport{body: fakeSearchBodyWithRatingsAndReviews(ratings, reviewCounts)}}
	swapPlacesService(t, svc)

	rec := runPlanHandlerFromIP(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "best speakeasy cocktail bar in Naples?"},
	}})
	events := planEvents(t, rec.Body.String())
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}

	placesEvents := eventsOfType(events, "places")
	if len(placesEvents) != 1 {
		t.Fatalf("places events = %d, want 1", len(placesEvents))
	}
	data := eventData(placesEvents[0])
	cards, ok := data["places"].([]any)
	if !ok || len(cards) == 0 {
		t.Fatalf("cards = %T len %d, want > 0", data["places"], len(cards))
	}
	first, _ := cards[0].(map[string]any)
	if first["name"] != "Place 3" {
		t.Fatalf("first card = %v, want the 900-review Place 3 to lead its rating-tied peers", first["name"])
	}

	bodies := fa.requestBodies()
	if len(bodies) != 2 {
		t.Fatalf("anthropic calls = %d, want 2", len(bodies))
	}
	firstIdx := strings.Index(string(bodies[1]), `\"name\":\"Place 3\"`)
	if firstIdx == -1 {
		firstIdx = strings.Index(string(bodies[1]), `"name":"Place 3"`)
	}
	otherIdx := strings.Index(string(bodies[1]), `\"name\":\"Place 0\"`)
	if otherIdx == -1 {
		otherIdx = strings.Index(string(bodies[1]), `"name":"Place 0"`)
	}
	if firstIdx == -1 || otherIdx == -1 || firstIdx > otherIdx {
		t.Fatalf("tool_result did not rank the most-reviewed tied place first: %s", string(bodies[1]))
	}
}

func TestPlanSearchPlacesEmptyResultsNoPlacesEvent(t *testing.T) {
	newFakeAnthropic(t,
		toolTurn("search_places", `{"query":"nothing here"}`),
		textTurn("I found nothing."),
	)

	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.Client = &http.Client{Transport: &countingTransport{body: `{"status":"OK","results":[]}`}}
	swapPlacesService(t, svc)

	rec := runPlanHandlerFromIP(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "food on the moon?"},
	}})
	events := planEvents(t, rec.Body.String())
	if got := eventsOfType(events, "places"); len(got) != 0 {
		t.Fatalf("places events for empty results = %d, want 0", len(got))
	}
}
