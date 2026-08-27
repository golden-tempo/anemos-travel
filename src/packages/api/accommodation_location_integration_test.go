package main

import (
	"net/http"
	"testing"
)

// Manually-entered stays carrying coordinates (specs day-travel-times,
// ticket C): a place picked in the stay sheet rides POST/PATCH as a
// latitude/longitude pair; detaching rides as clear_location, which exists
// because UpdateAccommodation's COALESCE can overwrite coordinates but never
// write NULL from an omitted key.

// Regression guard, not a new-behavior pin: the wire fields and columns
// predate this change (AI-sourced stays already used them), so this test
// passes against the pre-change server. It pins the edit-upgrade path the
// sheet now drives — coordinates through create, through update, and
// surviving an unrelated PATCH.
func TestStayCoordinatesPersistThroughCreateAndUpdate(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 2)
	id := trip.ID.String()

	// Create carries the pair (the sheet's search-pick on a fresh stay).
	rec := doJSON(t, "POST", "/api/v1/trips/"+id+"/accommodations", token, map[string]any{
		"name": "Hotel Estherea", "address": "Singel 303, Amsterdam",
		"latitude": 52.5, "longitude": 4.875,
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("add stay = %d: %s", rec.Code, rec.Body.String())
	}
	stay := decode(t, rec)
	if stay["latitude"] != 52.5 || stay["longitude"] != 4.875 {
		t.Fatalf("created stay coords = %v / %v", stay["latitude"], stay["longitude"])
	}
	stayID := stay["id"].(string)

	// A hand-typed stay picks up a place later (the edit-upgrade flow).
	rec = doJSON(t, "POST", "/api/v1/trips/"+id+"/accommodations", token, map[string]any{
		"name": "Some hotel near Old Town",
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("add ungeocoded stay = %d: %s", rec.Code, rec.Body.String())
	}
	plain := decode(t, rec)
	if _, ok := plain["latitude"]; ok {
		t.Fatalf("ungeocoded stay should carry no latitude: %v", plain)
	}
	plainID := plain["id"].(string)
	rec = doJSON(t, "PATCH", "/api/v1/trips/"+id+"/accommodations/"+plainID, token, map[string]any{
		"name": "Hotel Krasnapolsky", "latitude": 52.25, "longitude": 4.75,
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("upgrade stay = %d: %s", rec.Code, rec.Body.String())
	}
	if got := decode(t, rec); got["latitude"] != 52.25 || got["longitude"] != 4.75 {
		t.Fatalf("upgraded stay coords = %v / %v", got["latitude"], got["longitude"])
	}

	// An unrelated PATCH must not disturb stored coordinates (COALESCE keep).
	rec = doJSON(t, "PATCH", "/api/v1/trips/"+id+"/accommodations/"+stayID, token, map[string]any{
		"booked": true,
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("book stay = %d: %s", rec.Code, rec.Body.String())
	}
	if got := decode(t, rec); got["latitude"] != 52.5 || got["longitude"] != 4.875 {
		t.Fatalf("coords should survive a booked-only PATCH: %v / %v",
			got["latitude"], got["longitude"])
	}

	// And both stays read back through the trip payload the map pins render
	// from.
	tripView := decode(t, doJSON(t, "GET", "/api/v1/trips/"+id, token, nil))
	stays := listOf(t, tripView, "accommodations")
	byName := map[string]map[string]any{}
	for _, s := range stays {
		byName[s["name"].(string)] = s
	}
	if s := byName["Hotel Estherea"]; s == nil || s["latitude"] != 52.5 {
		t.Fatalf("trip read lost Estherea coords: %v", s)
	}
	if s := byName["Hotel Krasnapolsky"]; s == nil || s["longitude"] != 4.75 {
		t.Fatalf("trip read lost Krasnapolsky coords: %v", s)
	}
}

// New-behavior pin: PATCH {clear_location:true} NULLs both coordinates.
// Against the pre-change server the key is silently ignored and the
// coordinates survive, so the absence assertions below go red.
func TestStayLocationClearDetachesPlace(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 2)
	id := trip.ID.String()

	rec := doJSON(t, "POST", "/api/v1/trips/"+id+"/accommodations", token, map[string]any{
		"name": "Hotel Estherea", "latitude": 52.5, "longitude": 4.875,
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("add stay = %d: %s", rec.Code, rec.Body.String())
	}
	stayID := decode(t, rec)["id"].(string)

	rec = doJSON(t, "PATCH", "/api/v1/trips/"+id+"/accommodations/"+stayID, token, map[string]any{
		"clear_location": true,
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("clear_location PATCH = %d: %s", rec.Code, rec.Body.String())
	}
	got := decode(t, rec)
	if v, ok := got["latitude"]; ok {
		t.Fatalf("latitude should be cleared, still present: %v", v)
	}
	if v, ok := got["longitude"]; ok {
		t.Fatalf("longitude should be cleared, still present: %v", v)
	}
	// Other fields survive the detach — clear_location says one thing only.
	if got["name"] != "Hotel Estherea" {
		t.Fatalf("name should survive clear_location: %v", got["name"])
	}

	tripView := decode(t, doJSON(t, "GET", "/api/v1/trips/"+id, token, nil))
	stays := listOf(t, tripView, "accommodations")
	if len(stays) != 1 {
		t.Fatalf("stays = %v", stays)
	}
	if v, ok := stays[0]["latitude"]; ok {
		t.Fatalf("trip read still carries cleared latitude: %v", v)
	}
}

// New-behavior pin: clearing and setting coordinates in one body has no
// coherent meaning and is refused. Pre-change server: 200 (key ignored).
func TestStayLocationClearConflictsWithCoordinates(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 2)
	id := trip.ID.String()

	rec := doJSON(t, "POST", "/api/v1/trips/"+id+"/accommodations", token, map[string]any{
		"name": "Hotel Estherea", "latitude": 52.5, "longitude": 4.875,
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("add stay = %d: %s", rec.Code, rec.Body.String())
	}
	stayID := decode(t, rec)["id"].(string)

	rec = doJSON(t, "PATCH", "/api/v1/trips/"+id+"/accommodations/"+stayID, token, map[string]any{
		"clear_location": true, "latitude": 48.5, "longitude": 2.25,
	})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("clear_location+coords should 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

// New-behavior pin: coordinates arrive together or not at all. A lone
// latitude can never render a pin but would occupy the column, and on PATCH
// it would COALESCE-merge with a stored longitude from a different place.
// Pre-change server accepted one-sided pairs (201/200), so both legs go red.
func TestStayCoordinatesRequirePair(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 2)
	id := trip.ID.String()

	rec := doJSON(t, "POST", "/api/v1/trips/"+id+"/accommodations", token, map[string]any{
		"name": "Hotel Estherea", "latitude": 52.5,
	})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("one-sided create should 400, got %d: %s", rec.Code, rec.Body.String())
	}

	rec = doJSON(t, "POST", "/api/v1/trips/"+id+"/accommodations", token, map[string]any{
		"name": "Hotel Estherea", "latitude": 52.5, "longitude": 4.875,
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("add stay = %d: %s", rec.Code, rec.Body.String())
	}
	stayID := decode(t, rec)["id"].(string)

	rec = doJSON(t, "PATCH", "/api/v1/trips/"+id+"/accommodations/"+stayID, token, map[string]any{
		"longitude": 4.75,
	})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("one-sided update should 400, got %d: %s", rec.Code, rec.Body.String())
	}
}
