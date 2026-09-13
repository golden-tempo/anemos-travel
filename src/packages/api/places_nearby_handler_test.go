package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPlacesNearbyHandlerMissingCoords400(t *testing.T) {
	for _, url := range []string{
		"/api/v1/places/nearby",
		"/api/v1/places/nearby?lat=37.98",
		"/api/v1/places/nearby?lng=23.72",
		"/api/v1/places/nearby?lat=abc&lng=23.72",
		"/api/v1/places/nearby?lat=37.98&lng=xyz",
		"/api/v1/places/nearby?lat=999&lng=23.72",
		"/api/v1/places/nearby?lat=37.98&lng=999",
	} {
		rec := httptest.NewRecorder()
		placesNearbyHandler(rec, httptest.NewRequest(http.MethodGet, url, nil))
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("%s: status = %d, want 400", url, rec.Code)
		}
	}
}

// A caller who names no query gets a sensible default rather than an empty
// result set, and the coordinates ride as a location bias the same way
// SearchPlacesNearby's own test already pins.
func TestPlacesNearbyHandlerDefaultsQueryAndBiasesLocation(t *testing.T) {
	rt := &urlRecordingTransport{body: fakeTextSearchJSON}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.Client = &http.Client{Transport: rt}
	swapPlacesService(t, svc)

	rec := httptest.NewRecorder()
	placesNearbyHandler(rec, httptest.NewRequest(http.MethodGet,
		"/api/v1/places/nearby?lat=37.98381&lng=23.72759", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	if len(rt.urls) != 1 {
		t.Fatalf("Google called %d times, want 1", len(rt.urls))
	}
	if !strings.Contains(rt.urls[0], "location=37.9838%2C23.7276") {
		t.Fatalf("nearby URL missing location bias: %s", rt.urls[0])
	}
	if !strings.Contains(rec.Body.String(), `"status":"success"`) {
		t.Fatalf("response missing success status: %s", rec.Body.String())
	}
}

// An explicit q overrides the default query.
func TestPlacesNearbyHandlerHonorsExplicitQuery(t *testing.T) {
	rt := &urlRecordingTransport{body: fakeTextSearchJSON}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.Client = &http.Client{Transport: rt}
	swapPlacesService(t, svc)

	rec := httptest.NewRecorder()
	placesNearbyHandler(rec, httptest.NewRequest(http.MethodGet,
		"/api/v1/places/nearby?lat=37.98381&lng=23.72759&q=coffee", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	if len(rt.urls) != 1 || !strings.Contains(rt.urls[0], "query=coffee") {
		t.Fatalf("expected the explicit query in the Google request, got: %v", rt.urls)
	}
}
