package main

import (
	"net/url"
	"strings"
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

func TestBookingSearchURLPrePopulatesDestinationDatesAndGuests(t *testing.T) {
	got := bookingProvider{}.SearchURL(AccommodationQuery{
		Destination: "Athens",
		CheckIn:     "2026-09-03",
		CheckOut:    "2026-09-07",
		Guests:      3,
	})
	u, err := url.Parse(got)
	if err != nil {
		t.Fatalf("SearchURL produced an invalid URL: %v", err)
	}
	if u.Host != "www.booking.com" || u.Path != "/searchresults.html" {
		t.Fatalf("unexpected base URL: %q", got)
	}
	q := u.Query()
	if q.Get("ss") != "Athens" {
		t.Errorf("ss = %q, want the destination", q.Get("ss"))
	}
	if q.Get("checkin") != "2026-09-03" {
		t.Errorf("checkin = %q, want 2026-09-03", q.Get("checkin"))
	}
	if q.Get("checkout") != "2026-09-07" {
		t.Errorf("checkout = %q, want 2026-09-07", q.Get("checkout"))
	}
	if q.Get("group_adults") != "3" {
		t.Errorf("group_adults = %q, want 3", q.Get("group_adults"))
	}
}

// TestBookingSearchURLKeepsPartyInOneRoom guards against Booking.com's default
// behaviour of splitting group_adults across several rooms once it decides
// the party won't fit in one — a silent per-night price change from what the
// traveler was just quoted. Airbnb never does this (a listing is booked as
// one unit), so no_rooms=1 is what parity with the Airbnb link requires.
func TestBookingSearchURLKeepsPartyInOneRoom(t *testing.T) {
	got := bookingProvider{}.SearchURL(AccommodationQuery{Destination: "Rome", Guests: 5})
	u, err := url.Parse(got)
	if err != nil {
		t.Fatalf("SearchURL produced an invalid URL: %v", err)
	}
	if no := u.Query().Get("no_rooms"); no != "1" {
		t.Errorf("no_rooms = %q, want 1 (else Booking.com may split the party and change the price)", no)
	}
}

func TestBookingSearchURLOmitsRoomCountWithoutGuests(t *testing.T) {
	got := bookingProvider{}.SearchURL(AccommodationQuery{Destination: "Rome"})
	u, err := url.Parse(got)
	if err != nil {
		t.Fatalf("SearchURL produced an invalid URL: %v", err)
	}
	q := u.Query()
	if q.Has("group_adults") {
		t.Errorf("group_adults should be absent with no guest count, got %q", q.Get("group_adults"))
	}
	if q.Has("no_rooms") {
		t.Errorf("no_rooms should be absent with no guest count, got %q", q.Get("no_rooms"))
	}
}

func TestBookingSearchURLPinsCurrency(t *testing.T) {
	t.Setenv("HOTEL_RATES_CURRENCY", "EUR")
	got := bookingProvider{}.SearchURL(AccommodationQuery{Destination: "Rome"})
	u, err := url.Parse(got)
	if err != nil {
		t.Fatalf("SearchURL produced an invalid URL: %v", err)
	}
	if c := u.Query().Get("selected_currency"); c != "EUR" {
		t.Errorf("selected_currency = %q, want EUR (matches HOTEL_RATES_CURRENCY, the same knob search_hotels prices against)", c)
	}
}

func TestBookingSearchURLDefaultsCurrencyToUSD(t *testing.T) {
	got := bookingProvider{}.SearchURL(AccommodationQuery{Destination: "Rome"})
	u, err := url.Parse(got)
	if err != nil {
		t.Fatalf("SearchURL produced an invalid URL: %v", err)
	}
	if c := u.Query().Get("selected_currency"); c != "USD" {
		t.Errorf("selected_currency = %q, want USD default", c)
	}
}

func TestBookingSearchURLAddsAffiliateID(t *testing.T) {
	t.Setenv("BOOKING_AFFILIATE_ID", "12345")
	got := bookingProvider{}.SearchURL(AccommodationQuery{Destination: "Rome"})
	if !strings.Contains(got, "aid=12345") {
		t.Errorf("SearchURL %q should carry the affiliate id", got)
	}
}

// TestAccommodationProviderLinksMatchAirbnbParity documents the parity the
// issue asked for: both providers pre-populate destination, dates and guests
// for the same query.
func TestAccommodationProviderLinksMatchAirbnbParity(t *testing.T) {
	links := providerLinks(AccommodationQuery{
		Destination: "Lisbon",
		CheckIn:     "2026-05-01",
		CheckOut:    "2026-05-04",
		Guests:      2,
	})
	byProvider := map[string]string{}
	for _, l := range links {
		byProvider[l.Provider] = l.URL
	}
	for _, provider := range []string{"airbnb", "booking"} {
		u, ok := byProvider[provider]
		if !ok {
			t.Fatalf("missing %s link", provider)
		}
		if !strings.Contains(u, "2026-05-01") || !strings.Contains(u, "2026-05-04") {
			t.Errorf("%s link %q should carry both dates", provider, u)
		}
	}
}
