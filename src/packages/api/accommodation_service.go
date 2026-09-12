package main

import (
	"net/url"
	"os"
	"strconv"
)

// AccommodationQuery describes a lodging search for a destination and stay.
type AccommodationQuery struct {
	Destination string
	CheckIn     string // YYYY-MM-DD (optional)
	CheckOut    string // YYYY-MM-DD (optional)
	Guests      int    // optional
}

// AccommodationProvider yields a way to find stays. Today's implementations
// return a deep link (handoff). A future listing-returning provider (e.g. the
// Booking Demand API) can be added behind this same package without changing callers.
type AccommodationProvider interface {
	Name() string
	SearchURL(q AccommodationQuery) string
}

type ProviderLink struct {
	Provider string `json:"provider"`
	URL      string `json:"url"`
}

type airbnbProvider struct{}

func (airbnbProvider) Name() string { return "airbnb" }

func (airbnbProvider) SearchURL(q AccommodationQuery) string {
	u := "https://www.airbnb.com/s/" + url.PathEscape(q.Destination) + "/homes"
	params := url.Values{}
	if q.CheckIn != "" {
		params.Set("checkin", q.CheckIn)
	}
	if q.CheckOut != "" {
		params.Set("checkout", q.CheckOut)
	}
	// Airbnb's own default when "adults" is absent is inconsistent across
	// surfaces, so a party size is always sent explicitly — 1 (solo) when the
	// caller didn't specify one, never left to Airbnb to guess.
	adults := q.Guests
	if adults <= 0 {
		adults = 1
	}
	params.Set("adults", strconv.Itoa(adults))
	// No affiliate param: Airbnb shut down its affiliate program in 2021
	// (docs/business-model.md) — these links are pure user value, $0 revenue.
	if enc := params.Encode(); enc != "" {
		u += "?" + enc
	}
	return u
}

type bookingProvider struct{}

func (bookingProvider) Name() string { return "booking" }

func (bookingProvider) SearchURL(q AccommodationQuery) string {
	params := url.Values{}
	params.Set("ss", q.Destination)
	if q.CheckIn != "" {
		params.Set("checkin", q.CheckIn)
	}
	if q.CheckOut != "" {
		params.Set("checkout", q.CheckOut)
	}
	if q.Guests > 0 {
		params.Set("group_adults", strconv.Itoa(q.Guests))
		// Booking.com splits a party across multiple rooms once it decides
		// group_adults won't fit in one — silently changing the per-night
		// price the traveler sees from what search_hotels/summarizeHotels
		// just quoted them. Airbnb has no such split (a listing is booked as
		// one unit for however many guests), so pinning one room is what
		// parity with the Airbnb link actually requires here.
		params.Set("no_rooms", "1")
	}
	// Same reasoning as the SerpApi hotels fetch's gl/hl pins
	// (hotel_search_service.go): without this, Booking.com infers the point
	// of sale from the visitor's IP/locale, and a price can silently drift
	// from the currency the app just quoted.
	params.Set("selected_currency", hotelRatesCurrency())
	if id := os.Getenv("BOOKING_AFFILIATE_ID"); id != "" {
		params.Set("aid", id)
	}
	return "https://www.booking.com/searchresults.html?" + params.Encode()
}

func accommodationProviders() []AccommodationProvider {
	return []AccommodationProvider{airbnbProvider{}, bookingProvider{}}
}

// providerLinks builds a browse link per provider for the given query.
func providerLinks(q AccommodationQuery) []ProviderLink {
	provs := accommodationProviders()
	links := make([]ProviderLink, 0, len(provs))
	for _, p := range provs {
		links = append(links, ProviderLink{Provider: p.Name(), URL: p.SearchURL(q)})
	}
	return links
}
