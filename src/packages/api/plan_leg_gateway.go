package main

// set_leg_gateway — where a city's flights actually operate
// (specs/leg-gateway-airports, migration 00075).
//
// A derived flight leg's endpoints are itinerary CITY labels, and for a city
// with no airport the checklist promised a flight that cannot be booked
// ("Belgrade → Bad Ischl"). The sync path now auto-detects such cities and
// labels their legs with the nearest real airport; this tool is the
// traveler's word on top of that — "the airport is in Salzburg", "we'd
// rather fly into Vienna" — written as source='traveler', which the
// auto-resolver never overwrites. It relabels the affected checklist rows in
// place (content only; identity, booked state, mode and expense links ride
// along, per booking_todo_identity.go), so the correction is visible
// immediately rather than after the next page sync.

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/anthropics/anthropic-sdk-go"

	"travel-route-planner/store"
)

var setLegGatewayTool = anthropic.ToolParam{
	Name: "set_leg_gateway",
	Description: anthropic.String("Record which AIRPORT a saved trip's city actually flies through, when the city is too small to have its own — 'the airport is in Salzburg', 'Bad Ischl doesn't have an airport', 'fly into Vienna instead for that stop'. " +
		"The app already detects airportless cities and labels their flight legs with the nearest real airport; call this when the traveler states the airport or corrects a wrong pick — never say the legs cannot be changed. " +
		"It relabels that city's flight legs on the checklist in place — titles and booking links switch to the gateway airport while the itinerary keeps the city itself — and later searches for those legs should use the gateway's code. " +
		"city is the itinerary city as it appears in the trip; airport is the 3-letter IATA code when you know it, otherwise the airport city's name."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"city":         map[string]any{"type": "string", "description": "The itinerary city whose flights operate elsewhere, exactly as it appears in the trip"},
			"airport":      map[string]any{"type": "string", "description": "The gateway airport: a 3-letter IATA code (SZG) or the airport city's name (Salzburg)"},
			"airport_city": map[string]any{"type": "string", "description": "The gateway airport's own city name for display, e.g. 'Salzburg' — include it when you passed a bare IATA code"},
		},
		Required: []string{"city", "airport"},
	},
}

func runSetLegGatewayTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		City        string `json:"city"`
		Airport     string `json:"airport"`
		AirportCity string `json:"airport_city"`
	}
	json.Unmarshal(input, &in)

	if !s.authed {
		return "The traveler isn't signed in, so there's no saved trip to change. Note the airport in your reply instead.", true
	}
	if dbPool == nil {
		return "Saved trips are unavailable right now (persistence offline).", true
	}
	tripID, msg, failed := resolveDateShiftTrip(s)
	if failed {
		return msg, true
	}

	q := store.New(dbPool)
	trip, err := q.GetEditableTripByID(s.ctx, store.GetEditableTripByIDParams{ID: tripID, UserID: s.uid})
	if err != nil {
		return "That trip can't be edited by this traveler.", true
	}
	items, err := q.GetItineraryItemsByTrip(s.ctx, tripID)
	if err != nil {
		return "Could not load that trip's itinerary.", true
	}
	stays, _ := q.ListAccommodationsByTrip(s.ctx, tripID)
	legs := computeTripLegs(trip, items, stays)

	idx := legIndexOf(legs, in.City)
	if idx < 0 {
		return fmt.Sprintf("This trip has no city named %s. Its cities, in order, are: %s.",
			strings.TrimSpace(in.City), legLabelList(legs)), true
	}
	city := legs[idx].Label

	// A 3-letter input IS the code; anything longer resolves by name. The
	// refusal names the fix, so a failed lookup never dead-ends the model.
	airport := strings.ToUpper(strings.TrimSpace(in.Airport))
	if len(airport) != 3 || !isAlpha(airport) {
		airport = resolveIATA(s.ctx, in.Airport)
		if airport == "" {
			return fmt.Sprintf("Could not find an airport matching %q. Pass the 3-letter IATA code (e.g. SZG) in `airport`, with the airport city's name in `airport_city`.", in.Airport), true
		}
	}
	label := strPtrOrNil(strings.TrimSpace(in.AirportCity))

	g, err := q.UpsertTripLegGateway(s.ctx, store.UpsertTripLegGatewayParams{
		TripID: tripID, CityFold: gatewayCityFold(city),
		Airport: airport, AirportLabel: label, Source: "traveler",
	})
	if err != nil {
		return "Could not save the gateway airport.", true
	}

	// Relabel the city's flight legs in place — the same content-only rewrite
	// set_trip_origin performs on the journey endpoints. Rows keyed on the
	// city pair; a leg ridden by ground mode is deliberately left alone, and
	// a trip that has never synced has no rows yet (the first sync labels
	// them from the stored gateway).
	gateways := map[string]store.TripLegGateway{}
	if rows, err := q.ListTripLegGateways(s.ctx, tripID); err == nil {
		for _, row := range rows {
			gateways[row.CityFold] = row
		}
	}
	display := func(cityLabel string) string {
		if gw, ok := gateways[gatewayCityFold(cityLabel)]; ok && gatewayRelabelsRow(gw) {
			return gatewayLabel(gw)
		}
		return cityLabel
	}

	todos, _ := q.ListBookingTodosByTrip(s.ctx, tripID)
	byKey := map[string]*store.BookingTodo{}
	for i := range todos {
		byKey[todos[i].TodoKey] = &todos[i]
	}

	var updated, skipped []string
	for _, pair := range [][2]int{{idx - 1, idx}, {idx, idx + 1}} {
		a, b := pair[0], pair[1]
		if a < 0 || b >= len(legs) {
			continue
		}
		from, to := legs[a].Label, legs[b].Label
		row, ok := byKey[transportTodoKey(from, to)]
		if !ok {
			continue
		}
		mode := strings.TrimSpace(strPtrVal(row.Mode))
		if !allowedLegModes[mode] {
			mode = strings.TrimSpace(strPtrVal(row.DerivedMode))
		}
		if mode != "flight" {
			skipped = append(skipped, fmt.Sprintf("%s → %s stays as-is (a %s leg needs no airport)", from, to, mode))
			continue
		}
		o, dNew := display(from), display(to)
		title := o + " → " + dNew
		var departStr *string
		if legs[a].End != nil {
			ds := legs[a].End.Format(dateLayout)
			departStr = &ds
		}
		url, provider := transportModeLink("flight", dNew, &o, departStr, 1)
		if _, err := q.RelabelBookingTodo(s.ctx, store.RelabelBookingTodoParams{
			ID: row.ID, TripID: tripID,
			OriginLabel: strPtrOrNil(o), DestinationLabel: strPtrOrNil(dNew),
			Title: title, SearchUrl: strPtrOrNil(url), Provider: strPtrOrNil(provider),
		}); err != nil {
			return "Could not relabel that city's flight legs.", true
		}
		booked := ""
		if row.Booked {
			booked = " (already marked booked — flag it to the traveler if the booking names the wrong airport)"
		}
		updated = append(updated, fmt.Sprintf("%q now reads %q and its link searches %s%s", row.Title, title, airport, booked))
	}

	touchTripAs(s.ctx, tripID, s.uid)
	sendSSE(s.w, "trip_updated", map[string]string{"trip_id": tripID.String()})
	safeGo("recordEvent", func() {
		recordEvent(s.uid, "agent_leg_gateway_set", &tripID, map[string]any{"airport": airport})
	})

	// Post-state, not just success (docs/zen.md): every row as the traveler
	// will now see it, what was left alone and why, and the code to search
	// flights with.
	result := fmt.Sprintf("%s now flies via %s.", city, gatewayLabel(g))
	for _, u := range updated {
		result += "\n- " + u
	}
	for _, sk := range skipped {
		result += "\n- " + sk
	}
	if len(updated) == 0 && len(skipped) == 0 {
		result += " No checklist rows exist yet; the first page sync will label the flight legs with it."
	}
	result += fmt.Sprintf("\nSearch flights for these legs with %s, not %q.", airport, city)
	return result, false
}
