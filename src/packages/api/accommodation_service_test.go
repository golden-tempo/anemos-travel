package main

import (
	"net/url"
	"testing"
)

// TestAirbnbSearchURLPopulatesNights checks that check-in/check-out dates —
// which is how Airbnb derives the number of nights — always ride through to
// the query string untouched (issue #600).
func TestAirbnbSearchURLPopulatesNights(t *testing.T) {
	got := airbnbProvider{}.SearchURL(AccommodationQuery{
		Destination: "Paris",
		CheckIn:     "2026-06-01",
		CheckOut:    "2026-06-05",
	})
	u, err := url.Parse(got)
	if err != nil {
		t.Fatalf("SearchURL produced an unparseable URL: %v", err)
	}
	q := u.Query()
	if q.Get("checkin") != "2026-06-01" {
		t.Errorf("checkin = %q, want 2026-06-01", q.Get("checkin"))
	}
	if q.Get("checkout") != "2026-06-05" {
		t.Errorf("checkout = %q, want 2026-06-05", q.Get("checkout"))
	}
}

// TestAirbnbSearchURLDefaultsToSoloGuest ensures a solo traveler (no guests
// specified) still gets an explicit party size on the link, rather than
// leaving Airbnb to guess (issue #600).
func TestAirbnbSearchURLDefaultsToSoloGuest(t *testing.T) {
	got := airbnbProvider{}.SearchURL(AccommodationQuery{Destination: "Paris"})
	u, err := url.Parse(got)
	if err != nil {
		t.Fatalf("SearchURL produced an unparseable URL: %v", err)
	}
	if adults := u.Query().Get("adults"); adults != "1" {
		t.Errorf("adults = %q, want 1 (solo default)", adults)
	}
}

// TestAirbnbSearchURLHonorsExplicitGuests ensures a specified party size wins
// over the solo default.
func TestAirbnbSearchURLHonorsExplicitGuests(t *testing.T) {
	got := airbnbProvider{}.SearchURL(AccommodationQuery{Destination: "Paris", Guests: 3})
	u, err := url.Parse(got)
	if err != nil {
		t.Fatalf("SearchURL produced an unparseable URL: %v", err)
	}
	if adults := u.Query().Get("adults"); adults != "3" {
		t.Errorf("adults = %q, want 3", adults)
	}
}

// TestAirbnbSearchURLUsesExactDestination confirms a neighborhood/district
// destination (not just the city) is passed through into the search path
// unmodified, so the link opens already narrowed to that area (issue #600).
func TestAirbnbSearchURLUsesExactDestination(t *testing.T) {
	got := airbnbProvider{}.SearchURL(AccommodationQuery{Destination: "Le Marais, Paris"})
	want := "https://www.airbnb.com/s/" + url.PathEscape("Le Marais, Paris") + "/homes"
	u, err := url.Parse(got)
	if err != nil {
		t.Fatalf("SearchURL produced an unparseable URL: %v", err)
	}
	u.RawQuery = ""
	if u.String() != want {
		t.Errorf("path = %q, want %q", u.String(), want)
	}
}
