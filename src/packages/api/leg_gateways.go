package main

// leg_gateways.go — gateway airports for cities too small to have one
// (specs/leg-gateway-airports, migration 00075).
//
// A derived transport row's endpoints are itinerary CITY labels. For a city
// with no airport that made the checklist promise a flight that cannot be
// booked ("Belgrade → Bad Ischl"), and gave the agent nowhere to record the
// traveler's correction. This module owns the trip_leg_gateways side table:
// the sync path consults it to relabel inter-city FLIGHT legs — identity
// keys never change (booking_todo_identity.go) — and resolves unknown cities
// once via Duffel: a city whose text lookup finds an airport is cached as
// 'self' (no relabeling, ask once); a city with none gets its nearest
// bookable airport by the leg's own coordinates, cached as 'auto'. The
// traveler's word (source 'traveler', written by set_leg_gateway) outranks
// both and is never overwritten by resolution.

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"travel-route-planner/store"
)

// gatewayCityFold is the table's keyspace — the same folding
// transportTodoKey applies, stated once here so the two can't drift.
func gatewayCityFold(city string) string {
	return strings.ToLower(strings.TrimSpace(city))
}

// gatewayLabel renders a gateway for titles, labels and search links:
// "Salzburg (SZG)", or the bare code when the airport's own city is unknown.
// The parenthesized IATA is load-bearing: the client's Find Flights prefill
// extracts it and skips the text-resolution dance entirely.
func gatewayLabel(g store.TripLegGateway) string {
	if l := strings.TrimSpace(strPtrVal(g.AirportLabel)); l != "" {
		return l + " (" + g.Airport + ")"
	}
	return g.Airport
}

// gatewayRelabelsRow reports whether this gateway changes what a leg
// displays. 'self' rows exist only as a negative cache — a city with its own
// airport keeps its name ("Belgrade" must not grow a "(BEG)" nobody asked
// for).
func gatewayRelabelsRow(g store.TripLegGateway) bool {
	return g.Source == "auto" || g.Source == "traveler"
}

// resolveBudget bounds what one sync is willing to spend on Duffel: cities
// beyond the cap stay unresolved this sync and retry on the next (the table
// is the cache, so a busy first sync converges over a couple of visits
// rather than stalling the checklist behind N lookups).
const (
	gatewayResolveTimeout = 3 * time.Second
	gatewayResolveCap     = 4
)

// gatewayResolver resolves and caches gateways for one sync request.
type gatewayResolver struct {
	q       *store.Queries
	tripID  uuid.UUID
	known   map[string]store.TripLegGateway // by city_fold; misses resolved lazily
	misses  map[string]bool                 // cities that failed resolution THIS sync — don't re-ask Duffel in the same request
	spent   int
	duffel  *DuffelService
	nowCtx  context.Context
	enabled bool
}

func newGatewayResolver(ctx context.Context, q *store.Queries, tripID uuid.UUID, duffel *DuffelService) *gatewayResolver {
	r := &gatewayResolver{
		q: q, tripID: tripID, duffel: duffel, nowCtx: ctx,
		known: map[string]store.TripLegGateway{}, misses: map[string]bool{},
		enabled: duffel != nil && duffel.Token != "",
	}
	if rows, err := q.ListTripLegGateways(ctx, tripID); err == nil {
		for _, g := range rows {
			r.known[g.CityFold] = g
		}
	}
	return r
}

// gatewayFor returns the gateway that should RELABEL this endpoint city, or
// nil. Unknown cities are resolved at most gatewayResolveCap times per sync,
// each under its own short timeout; every failure degrades to "no relabel" —
// exactly the pre-feature behavior — and is retried on a later sync.
func (r *gatewayResolver) gatewayFor(city string, coord legEndpoint) *store.TripLegGateway {
	fold := gatewayCityFold(city)
	if fold == "" {
		return nil
	}
	if g, ok := r.known[fold]; ok {
		if gatewayRelabelsRow(g) {
			return &g
		}
		return nil
	}
	if !r.enabled || r.misses[fold] || r.spent >= gatewayResolveCap {
		return nil
	}
	r.spent++
	g, ok := r.resolve(fold, city, coord)
	if !ok {
		r.misses[fold] = true
		return nil
	}
	r.known[fold] = g
	if gatewayRelabelsRow(g) {
		return &g
	}
	return nil
}

// resolve asks Duffel about one city and writes the answer through the
// provenance-laddered upsert. ErrNoRows from the upsert means a 'traveler'
// row appeared since our List — that row wins; re-read it.
func (r *gatewayResolver) resolve(fold, city string, coord legEndpoint) (store.TripLegGateway, bool) {
	ctx, cancel := context.WithTimeout(r.nowCtx, gatewayResolveTimeout)
	defer cancel()

	params := store.UpsertTripLegGatewayParams{TripID: r.tripID, CityFold: fold}
	hits, err := r.duffel.SearchAirports(ctx, city)
	if err != nil {
		return store.TripLegGateway{}, false // transient — retry next sync
	}
	// "Has its own airport" demands a hit that actually NAMES this city —
	// Duffel's suggestions are fuzzy, and a query for Bad Ischl that comes
	// back with Salzburg entries is the no-airport signal, not a match.
	// (resolveIATA takes the first hit unchecked, but it answers a different
	// question: "which code for the place the model already chose".)
	if own := airportMatchingCity(hits, fold); own != nil {
		// The city has an airport of its own: cache the fact, relabel nothing.
		params.Airport = strings.ToUpper(own.IataCode)
		params.AirportLabel = strPtrOrNil(own.City)
		params.Source = "self"
	} else {
		// No airport under this name — the "too small" signal. The nearest
		// bookable airport to the leg's own representative point is the
		// gateway. No coordinates, no guess.
		if coord.Lat == nil || coord.Lng == nil {
			return store.TripLegGateway{}, false
		}
		near, err := r.duffel.NearbyAirports(ctx, *coord.Lat, *coord.Lng)
		if err != nil || len(near) == 0 {
			return store.TripLegGateway{}, false
		}
		params.Airport = strings.ToUpper(near[0].IataCode)
		params.AirportLabel = strPtrOrNil(near[0].City)
		params.Source = "auto"
	}
	if params.Airport == "" || len(params.Airport) != 3 {
		return store.TripLegGateway{}, false
	}
	g, err := r.q.UpsertTripLegGateway(ctx, params)
	if errors.Is(err, pgx.ErrNoRows) {
		// A traveler decision beat us to the row; use it.
		if rows, lerr := r.q.ListTripLegGateways(ctx, r.tripID); lerr == nil {
			for _, existing := range rows {
				if existing.CityFold == fold {
					return existing, true
				}
			}
		}
		return store.TripLegGateway{}, false
	}
	if err != nil {
		return store.TripLegGateway{}, false
	}
	return g, true
}

// gatewaySubtitle prefixes the itinerary-city qualifier onto a row's posted
// subtitle, so a relabelled leg never loses the city the traveler actually
// planned: "For Bad Ischl · Sep 7 · 2 travelers". English by the same
// precedent as the server-composed "A → B" titles.
func gatewaySubtitle(qualifiers []string, posted *string) *string {
	if len(qualifiers) == 0 {
		return posted
	}
	q := strings.Join(qualifiers, " · ")
	if s := strings.TrimSpace(strPtrVal(posted)); s != "" {
		q += " · " + s
	}
	return &q
}

// gatewayQualifier words one endpoint's swap for the subtitle.
func gatewayQualifier(preposition, city string) string {
	return fmt.Sprintf("%s %s", preposition, strings.TrimSpace(city))
}

// airportMatchingCity finds a suggestion whose own name or city contains the
// queried city (fold-insensitive), preferring city-type entries the way
// resolveIATA does. Nil means no suggestion is actually FOR this city.
func airportMatchingCity(hits []Airport, cityFold string) *Airport {
	matches := func(a Airport) bool {
		return a.IataCode != "" &&
			(strings.Contains(strings.ToLower(a.Name), cityFold) ||
				strings.Contains(strings.ToLower(a.City), cityFold))
	}
	for i := range hits {
		if hits[i].SubType == "city" && matches(hits[i]) {
			return &hits[i]
		}
	}
	for i := range hits {
		if matches(hits[i]) {
			return &hits[i]
		}
	}
	return nil
}
