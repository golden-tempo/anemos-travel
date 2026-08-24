package main

// CROSS-LANGUAGE CONTRACT (specs/trip-dates-truth): these fixtures and
// expected values hand-mirror test/leg_ranges_test.dart in the Flutter suite
// (the calendar-parity convention) — same trips, same expected spans, city
// names and all. Change either side and you must change both. The two cases
// the Dart suite pins with "diverges:" markers appear here with the SERVER
// expected values (the reconciled post-cutover rules): an address-less
// confirmed stay DOES anchor (name fallback), and a spanless interior leg
// does NOT reset the arrival chain.

import (
	"testing"
	"time"

	"travel-route-planner/store"
)

func rlItem(pos int, name string, city *string, day int) store.ItineraryItem {
	it := store.ItineraryItem{Position: int32(pos), Name: name, City: city,
		Latitude: 1, Longitude: 1}
	if day > 0 {
		d := int32(day)
		it.Day = &d
	}
	return it
}

func rlCity(c string) *string { return &c }

func rlTrip(start, end string) store.Trip {
	t := store.Trip{}
	if start != "" {
		t.StartDate = validDate(start)
	}
	if end != "" {
		t.EndDate = validDate(end)
	}
	return t
}

func rlStay(name, address, checkIn, checkOut string) store.Accommodation {
	a := store.Accommodation{Name: name,
		CheckIn: validDate(checkIn), CheckOut: validDate(checkOut)}
	if address != "" {
		a.Address = &address
	}
	return a
}

func rlDate(iso string) time.Time { return civilDate(iso) }

func assertSpan(t *testing.T, leg RenderLeg, start, end string) {
	t.Helper()
	if leg.Start == nil || leg.End == nil {
		t.Fatalf("%s: span = %v/%v, want %s/%s", leg.Key, leg.Start, leg.End, start, end)
	}
	if !leg.Start.Equal(rlDate(start)) || !leg.End.Equal(rlDate(end)) {
		t.Fatalf("%s: span = %s/%s, want %s/%s", leg.Key,
			leg.Start.Format(dateLayout), leg.End.Format(dateLayout), start, end)
	}
}

func TestComputeTripLegsItemDayRanges(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-08-24", "2026-08-28"), []store.ItineraryItem{
		rlItem(0, "Feskekôrka", rlCity("Gothenburg"), 1),
		rlItem(1, "Liseberg", rlCity("Gothenburg"), 3),
		rlItem(2, "Prado", rlCity("Madrid"), 5),
	}, nil)
	if len(legs) != 2 {
		t.Fatalf("legs = %d, want 2", len(legs))
	}
	// Gothenburg runs until Madrid's arrival (its first item day, Aug 28) —
	// the boundary rule; its own last item day (Aug 26) sets nothing.
	assertSpan(t, legs[0], "2026-08-24", "2026-08-28")
	// Madrid arrives the day the trip ends: a genuine zero-night visit.
	assertSpan(t, legs[1], "2026-08-28", "2026-08-28")
	if legs[0].Key != "Gothenburg" || legs[1].Key != "Madrid" {
		t.Fatalf("keys = %s/%s", legs[0].Key, legs[1].Key)
	}
	if legs[0].DateSource != "items" || legs[1].DateSource != "items" {
		t.Fatalf("date sources = %s/%s, want items/items", legs[0].DateSource, legs[1].DateSource)
	}
	if legs[0].FirstPos != 0 || legs[0].LastPos != 1 || legs[1].FirstPos != 2 {
		t.Fatalf("positions = %d-%d / %d-%d", legs[0].FirstPos, legs[0].LastPos, legs[1].FirstPos, legs[1].LastPos)
	}
}

func TestComputeTripLegsFirstLegAnchor(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-08-24", "2026-09-01"), []store.ItineraryItem{
		rlItem(0, "Prague", rlCity("Prague"), 4),
		rlItem(1, "Kraków", rlCity("Kraków"), 9),
	}, nil)
	// Prague starts at the trip start (first-leg anchor) and runs until
	// Kraków's arrival, its first item day — Sep 1, also the trip's last day.
	assertSpan(t, legs[0], "2026-08-24", "2026-09-01")
	assertSpan(t, legs[1], "2026-09-01", "2026-09-01")
}

// The tail case of the boundary rule: the planner leaves the day home empty
// (it's a travel day), so the last leg's item-derived end falls short of the
// trip's own end date. Amsterdam must still read Aug 23 – Aug 25 · 2 nights,
// not Aug 23 – Aug 24 · 1 night — and Paris runs until Amsterdam's arrival
// (day 4), not its own last item day.
func TestComputeTripLegsLastLegAnchor(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-08-20", "2026-08-25"), []store.ItineraryItem{
		rlItem(0, "Louvre", rlCity("Paris"), 1),
		rlItem(1, "Musée d'Orsay", rlCity("Paris"), 2),
		rlItem(2, "Rijksmuseum", rlCity("Amsterdam"), 4),
		rlItem(3, "Anne Frank House", rlCity("Amsterdam"), 5),
		// Day 6 (Aug 25) is the journey home and carries nothing.
	}, nil)
	assertSpan(t, legs[0], "2026-08-20", "2026-08-23")
	assertSpan(t, legs[1], "2026-08-23", "2026-08-25")
}

// A confirmed stay's dates are explicit on both ends: its check-in is the
// arrival Paris extends to, and its checkout is never stretched to the trip's
// Aug 25.
func TestComputeTripLegsLastLegAnchorSkipsConfirmedStay(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-08-20", "2026-08-25"), []store.ItineraryItem{
		rlItem(0, "Louvre", rlCity("Paris"), 1),
		rlItem(1, "Rijksmuseum", rlCity("Amsterdam"), 4),
	}, []store.Accommodation{
		rlStay("Hotel Pulitzer", "Prinsengracht, Amsterdam", "2026-08-23", "2026-08-24"),
	})
	assertSpan(t, legs[0], "2026-08-20", "2026-08-23")
	assertSpan(t, legs[1], "2026-08-23", "2026-08-24")
}

// An item dated past the next city's arrival no longer widens its own leg (the
// old rule read Medellín's day-6 item as a Sep 6 departure and collapsed Quito
// to a zero-night stop). The leg ends at the next arrival, the item STRANDS —
// named on the leg, surfaced by checkLegShape — and Quito keeps its nights.
func TestComputeTripLegsOutOfOrderItemStrandsInsteadOfCollapsing(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-09-01", "2026-09-07"), []store.ItineraryItem{
		rlItem(0, "Museo", rlCity("Medellín"), 1),
		rlItem(1, "Comuna 13", rlCity("Medellín"), 6),
		rlItem(2, "Quito", rlCity("Quito"), 4),
	}, nil)
	assertSpan(t, legs[0], "2026-09-01", "2026-09-04")
	if !legs[0].itemsPastEnd {
		t.Fatal("the day-6 item sits past Medellín's Sep 4 end and was not named")
	}
	assertSpan(t, legs[1], "2026-09-04", "2026-09-07")
	if legs[0].ZeroNight || legs[1].ZeroNight {
		t.Fatal("an out-of-order item must strand, not collapse a leg")
	}
	if legs[1].itemsPastEnd {
		t.Fatal("Quito's items are inside its span; itemsPastEnd is wrong")
	}
}

func TestComputeTripLegsConfirmedStayAnchors(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-09-01", "2026-09-07"), []store.ItineraryItem{
		rlItem(0, "Museo", rlCity("Medellín"), 1),
		rlItem(1, "Quito", rlCity("Quito"), 5),
	}, []store.Accommodation{
		rlStay("Hotel Quito", "Av. González Suárez, Quito, Ecuador", "2026-09-03", "2026-09-05"),
	})
	// The stay's check-in IS Quito's arrival, and Medellín runs to meet it —
	// the check-in is the strongest arrival evidence there is, so the two
	// unplanned nights before it sit with Medellín, the city the traveler is
	// still in (the old chain rendered Quito from Sep 1, two days before its
	// own booking).
	assertSpan(t, legs[0], "2026-09-01", "2026-09-03")
	assertSpan(t, legs[1], "2026-09-03", "2026-09-05")
	if legs[1].DateSource != "stay" {
		t.Fatalf("date source = %s, want stay", legs[1].DateSource)
	}
}

// diverges (Dart pins the opposite pre-cutover): an address-LESS confirmed
// stay anchors via the NAME fallback — the reconciled server rule, so
// agent-added "Stay in Quito" rows anchor their leg.
func TestComputeTripLegsAddressLessStayAnchorsByName(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-09-01", "2026-09-05"), []store.ItineraryItem{
		rlItem(0, "Quito", rlCity("Quito"), 3),
	}, []store.Accommodation{
		rlStay("Stay in Quito", "", "2026-09-02", "2026-09-04"),
	})
	assertSpan(t, legs[0], "2026-09-02", "2026-09-04")
	if legs[0].DateSource != "stay" {
		t.Fatalf("date source = %s, want stay (name fallback)", legs[0].DateSource)
	}
}

func TestComputeTripLegsAutoAllocation(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-06-01", "2026-06-08"), []store.ItineraryItem{
		rlItem(0, "Louvre", rlCity("Paris"), 0),
		rlItem(1, "Orsay", rlCity("Paris"), 0),
		rlItem(2, "Marais walk", rlCity("Paris"), 0),
		rlItem(3, "Colosseum", rlCity("Rome"), 0),
	}, nil)
	// Rome's auto slice starts Jun 7, so that is its arrival and Paris runs
	// to meet it (checkout-day semantics, like every other leg).
	assertSpan(t, legs[0], "2026-06-01", "2026-06-07")
	assertSpan(t, legs[1], "2026-06-07", "2026-06-08")
	if legs[0].DateSource != "auto" || legs[1].DateSource != "auto" {
		t.Fatalf("date sources = %s/%s, want auto/auto", legs[0].DateSource, legs[1].DateSource)
	}
}

func TestComputeTripLegsMoreLocationsThanDays(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-06-01", "2026-06-02"), []store.ItineraryItem{
		rlItem(0, "A", rlCity("Alpha"), 0),
		rlItem(1, "B", rlCity("Beta"), 0),
		rlItem(2, "C", rlCity("Gamma"), 0),
	}, nil)
	// Alpha and Beta share the Jun 1 arrival — genuinely two cities in one
	// day, so Alpha is a zero-night stop; Beta runs to Gamma's Jun 2 arrival.
	assertSpan(t, legs[0], "2026-06-01", "2026-06-01")
	if !legs[0].ZeroNight {
		t.Fatal("a leg sharing its arrival day with the next was not marked zero_night")
	}
	assertSpan(t, legs[1], "2026-06-01", "2026-06-02")
	assertSpan(t, legs[2], "2026-06-02", "2026-06-02")
}

func TestComputeTripLegsDatelessTrip(t *testing.T) {
	legs := computeTripLegs(rlTrip("", ""), []store.ItineraryItem{
		rlItem(0, "Louvre", rlCity("Paris"), 1),
	}, nil)
	if legs[0].Start != nil || legs[0].End != nil || legs[0].DateSource != "" {
		t.Fatalf("dateless legs = %+v, want nil span", legs[0])
	}
}

// The out-of-order trip the old rule answered with a loud zero-night collapse
// (Medellín's day-6 item read as a Sep 6 departure, Quito squeezed to nothing).
// Under the boundary rule every leg runs to the next arrival, the stranded
// item is named, and no city loses its nights to a neighbour's stray day tag.
func TestComputeTripLegsOutOfOrderTripRendersForward(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-09-01", "2026-09-07"), []store.ItineraryItem{
		rlItem(0, "Museo", rlCity("Medellín"), 1),
		rlItem(1, "Comuna 13", rlCity("Medellín"), 6),
		rlItem(2, "Quito", rlCity("Quito"), 5),
		rlItem(3, "Mitad del Mundo", rlCity("Galápagos"), 6),
		rlItem(4, "Tortuga Bay", rlCity("Galápagos"), 7),
	}, nil)
	assertSpan(t, legs[0], "2026-09-01", "2026-09-05")
	if !legs[0].itemsPastEnd {
		t.Fatal("Medellín's day-6 item sits past its Sep 5 end and was not named")
	}
	assertSpan(t, legs[1], "2026-09-05", "2026-09-06")
	assertSpan(t, legs[2], "2026-09-06", "2026-09-07")
	for _, leg := range legs {
		if leg.ZeroNight {
			t.Fatalf("%s wrongly marked zero_night", leg.Label)
		}
	}
}

// Cities sharing one arrival day pinch to genuine zero-night stops, and the
// pinches chain: the traveler reaches Quito, Guayaquil and Cartagena all on
// Sep 4, so the first two hold zero nights each.
func TestComputeTripLegsSharedArrivalDayPinchesChain(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-09-01", "2026-09-07"), []store.ItineraryItem{
		rlItem(0, "Museo", rlCity("Medellín"), 1),
		rlItem(1, "Quito", rlCity("Quito"), 4),
		rlItem(2, "Guayaquil", rlCity("Guayaquil"), 4),
		rlItem(3, "Cartagena", rlCity("Cartagena"), 4),
	}, nil)
	assertSpan(t, legs[0], "2026-09-01", "2026-09-04")
	assertSpan(t, legs[1], "2026-09-04", "2026-09-04")
	assertSpan(t, legs[2], "2026-09-04", "2026-09-04")
	if !legs[1].ZeroNight || !legs[2].ZeroNight {
		t.Fatal("shared-arrival legs not both zero_night")
	}
	assertSpan(t, legs[3], "2026-09-04", "2026-09-07")
	if legs[0].ZeroNight || legs[3].ZeroNight {
		t.Fatal("neighbouring legs wrongly marked zero_night")
	}
}

// A confirmed stay's explicit dates hold against a neighbour's items: Quito
// keeps Sep 3–5, Medellín ends at that check-in, and Medellín's day-6 item —
// dated inside the stay it contradicts — strands rather than moving anything.
func TestComputeTripLegsStayNeverCollapses(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-09-01", "2026-09-07"), []store.ItineraryItem{
		rlItem(0, "Museo", rlCity("Medellín"), 1),
		rlItem(1, "Comuna 13", rlCity("Medellín"), 6),
		rlItem(2, "Quito", rlCity("Quito"), 5),
	}, []store.Accommodation{
		rlStay("Hotel Quito", "Av. González Suárez, Quito, Ecuador", "2026-09-03", "2026-09-05"),
	})
	assertSpan(t, legs[0], "2026-09-01", "2026-09-03")
	if !legs[0].itemsPastEnd {
		t.Fatal("Medellín's day-6 item sits past its Sep 3 end and was not named")
	}
	assertSpan(t, legs[1], "2026-09-03", "2026-09-05")
	if legs[1].ZeroNight {
		t.Fatal("stay-anchored leg wrongly collapsed")
	}
}

// diverges (Dart pins the opposite pre-cutover): a spanless interior leg is
// SKIPPED by the boundary rule, which closes the boundary ACROSS it — the
// reconciled server rule (the client resets its chain there instead). Note
// the auto lattice needs no trip end here, so the hubless leg has no span at
// all, and with no trip end Gamma's provisional own end (its single item day)
// stands.
func TestComputeTripLegsSpanlessLegDoesNotResetChain(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-06-01", ""), []store.ItineraryItem{
		rlItem(0, "A", rlCity("Alpha"), 1),
		rlItem(1, "mystery", nil, 0),
		rlItem(2, "C", rlCity("Gamma"), 5),
	}, nil)
	if len(legs) != 3 {
		t.Fatalf("legs = %d, want 3", len(legs))
	}
	if legs[1].Start != nil || legs[1].Label != otherPlacesLabel || legs[1].Hub != nil {
		t.Fatalf("hubless leg = %+v, want spanless Other places", legs[1])
	}
	// Alpha still runs to Gamma's arrival across the spanless leg.
	assertSpan(t, legs[0], "2026-06-01", "2026-06-05")
	assertSpan(t, legs[2], "2026-06-05", "2026-06-05")
}

func TestComputeTripLegsRevisitKeysAndHubs(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-06-01", "2026-06-06"), []store.ItineraryItem{
		rlItem(0, "Acropolis", rlCity("Athens"), 1),
		rlItem(1, "Oia", rlCity("Santorini"), 3),
		rlItem(2, "Plaka dinner", rlCity("Athens"), 5),
	}, nil)
	if legs[0].Key != "Athens" || legs[1].Key != "Santorini" || legs[2].Key != "Athens#2" {
		t.Fatalf("keys = %s/%s/%s, want Athens/Santorini/Athens#2", legs[0].Key, legs[1].Key, legs[2].Key)
	}
	if legs[2].Label != "Athens" {
		t.Fatalf("revisit label = %s, want Athens", legs[2].Label)
	}
}

func TestAllocateLegDays(t *testing.T) {
	if got := allocateLegDays(8, []int{3, 1}); got[0] != 6 || got[1] != 2 {
		t.Fatalf("allocateLegDays(8, [3 1]) = %v, want [6 2]", got)
	}
	if got := allocateLegDays(10, []int{1, 1, 1}); got[0] != 4 || got[1] != 3 || got[2] != 3 {
		t.Fatalf("allocateLegDays(10, [1 1 1]) = %v, want [4 3 3]", got)
	}
	if got := allocateLegDays(2, []int{5, 5, 5}); got[0] != 1 || got[1] != 1 || got[2] != 1 {
		t.Fatalf("allocateLegDays(2, [5 5 5]) = %v, want [1 1 1]", got)
	}
}

// A SPINE (specs/shape-before-schedule): two places a city — one on the day the
// traveler arrives, one on the day they move on — except the last city, which
// gets only its arrival because the day you leave it is the journey home. Five
// places for three cities, and the days in between deliberately empty.
//
// The point of the fixture is that a SPARSE itinerary renders the SAME ranges a
// dense one would. Only each leg's min and max item day is read, so the empty
// middle days change nothing; the move-on place is what dates each city, and
// the last-leg anchor carries Madrid through the trip's end.
func TestComputeTripLegsSparseSpineRanges(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-09-01", "2026-09-08"), []store.ItineraryItem{
		rlItem(0, "Time Out Market", rlCity("Lisbon"), 1),
		rlItem(1, "Pastéis de Belém", rlCity("Lisbon"), 4), // move-on day
		rlItem(2, "Livraria Lello", rlCity("Porto"), 4),    // same day, arriving
		rlItem(3, "Cais da Ribeira", rlCity("Porto"), 6),   // move-on day
		rlItem(4, "Museo del Prado", rlCity("Madrid"), 6),  // arrival only
		// Days 2-3, 5 and 7 carry nothing; day 8 is the journey home.
	}, nil)
	if len(legs) != 3 {
		t.Fatalf("legs = %d, want 3", len(legs))
	}
	assertSpan(t, legs[0], "2026-09-01", "2026-09-04")
	assertSpan(t, legs[1], "2026-09-04", "2026-09-06")
	assertSpan(t, legs[2], "2026-09-06", "2026-09-08")
	for _, leg := range legs {
		if leg.DateSource != "items" {
			t.Fatalf("%s date source = %q, want items", leg.Label, leg.DateSource)
		}
		if leg.ZeroNight {
			t.Fatalf("%s collapsed to a zero-night stop", leg.Label)
		}
	}
}

// A one-city spine is a single arrival place. Its own span is that one day; the
// last-leg anchor is the whole reason the trip still reads as a week — which is
// also why create_itinerary refuses a write that omits end_date (plan_spine.go):
// without a stored end there is nothing here to anchor against.
func TestComputeTripLegsOneCitySpine(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-09-01", "2026-09-08"), []store.ItineraryItem{
		rlItem(0, "Museo del Prado", rlCity("Madrid"), 1),
	}, nil)
	assertSpan(t, legs[0], "2026-09-01", "2026-09-08")
}

// The same trip as the sparse spine above, built from arrival anchors ALONE —
// no move-on places. Under the boundary rule each leg runs to the next
// arrival, so this renders byte-identical to the full spine: the move-on
// place stopped being load-bearing. (Before specs/leg-departure-dates this
// was a characterization test pinning the collapse the "move-on place is NOT
// optional" prompt rule existed to prevent — Lisbon lost all three nights to
// Porto.)
func TestComputeTripLegsArrivalAnchorsAloneRenderTheFullSpine(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-09-01", "2026-09-08"), []store.ItineraryItem{
		rlItem(0, "Time Out Market", rlCity("Lisbon"), 1),
		rlItem(1, "Livraria Lello", rlCity("Porto"), 4),
		rlItem(2, "Museo del Prado", rlCity("Madrid"), 6),
	}, nil)
	assertSpan(t, legs[0], "2026-09-01", "2026-09-04")
	assertSpan(t, legs[1], "2026-09-04", "2026-09-06")
	assertSpan(t, legs[2], "2026-09-06", "2026-09-08")
	for _, leg := range legs {
		if leg.ZeroNight || leg.itemsPastEnd {
			t.Fatalf("%s flagged on a well-formed arrival-anchor trip", leg.Label)
		}
	}
}

// The reported shape (specs/leg-departure-dates): "move the items from
// Saturday to Friday". Prague's places sit on days 3-5 and NOTHING sits on
// day 6, the Saturday the traveler flies — the state the old derivation read
// as a Friday departure, handing Saturday night to Kraków. Prague's end is
// Kraków's arrival, so it holds three nights with its last day empty.
func TestComputeTripLegsDepartureIsNextArrival(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-08-24", "2026-08-31"), []store.ItineraryItem{
		rlItem(0, "Rijksmuseum", rlCity("Amsterdam"), 1),
		rlItem(1, "Jordaan walk", rlCity("Amsterdam"), 3),
		rlItem(2, "Old Town Square", rlCity("Prague"), 3),
		rlItem(3, "Prague Castle", rlCity("Prague"), 4),
		rlItem(4, "Charles Bridge Walk", rlCity("Prague"), 5),
		rlItem(5, "Main Market Square", rlCity("Kraków"), 6),
		rlItem(6, "Wawel Castle", rlCity("Kraków"), 7),
	}, nil)
	assertSpan(t, legs[0], "2026-08-24", "2026-08-26")
	assertSpan(t, legs[1], "2026-08-26", "2026-08-29") // three nights, day 6 empty
	assertSpan(t, legs[2], "2026-08-29", "2026-08-31")
	for _, leg := range legs {
		if leg.ZeroNight || leg.itemsPastEnd {
			t.Fatalf("%s flagged on the reported trip", leg.Label)
		}
	}
}

// The travel day emptied (acceptance 2 and 3): the same trip WITH a place on
// Prague's day 6 renders the identical spans, so deleting that place — or
// never inventing one — changes no city's dates. This is the fixture that
// makes the Prague-airport Starbucks unnecessary.
func TestComputeTripLegsEmptiedTravelDayHoldsEveryLegsSpan(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-08-24", "2026-08-31"), []store.ItineraryItem{
		rlItem(0, "Rijksmuseum", rlCity("Amsterdam"), 1),
		rlItem(1, "Jordaan walk", rlCity("Amsterdam"), 3),
		rlItem(2, "Old Town Square", rlCity("Prague"), 3),
		rlItem(3, "Prague Castle", rlCity("Prague"), 4),
		rlItem(4, "Charles Bridge Walk", rlCity("Prague"), 5),
		rlItem(5, "Airport coffee", rlCity("Prague"), 6),
		rlItem(6, "Main Market Square", rlCity("Kraków"), 6),
		rlItem(7, "Wawel Castle", rlCity("Kraków"), 7),
	}, nil)
	assertSpan(t, legs[0], "2026-08-24", "2026-08-26")
	assertSpan(t, legs[1], "2026-08-26", "2026-08-29")
	assertSpan(t, legs[2], "2026-08-29", "2026-08-31")
}

// A multi-day gap: Lisbon's places stop on day 2 and Porto begins day 5. The
// unplanned days belong to Lisbon — the city the traveler is still in — not
// to a city they haven't reached (the old chain dragged Porto back to day 2).
func TestComputeTripLegsMultiDayGapBelongsToEarlierLeg(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-09-01", "2026-09-08"), []store.ItineraryItem{
		rlItem(0, "Time Out Market", rlCity("Lisbon"), 1),
		rlItem(1, "Alfama walk", rlCity("Lisbon"), 2),
		rlItem(2, "Livraria Lello", rlCity("Porto"), 5),
	}, nil)
	assertSpan(t, legs[0], "2026-09-01", "2026-09-05")
	assertSpan(t, legs[1], "2026-09-05", "2026-09-08")
}

// The convention's shared transition day still renders identically: a place on
// the move-on morning stops being load-bearing, it does not stop being valid.
func TestComputeTripLegsSharedTransitionDayUnchanged(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-08-24", "2026-08-29"), []store.ItineraryItem{
		rlItem(0, "Rijksmuseum", rlCity("Amsterdam"), 1),
		rlItem(1, "Jordaan walk", rlCity("Amsterdam"), 3),
		rlItem(2, "Old Town Square", rlCity("Prague"), 3),
		rlItem(3, "Charles Bridge Walk", rlCity("Prague"), 6),
	}, nil)
	assertSpan(t, legs[0], "2026-08-24", "2026-08-26")
	assertSpan(t, legs[1], "2026-08-26", "2026-08-29")
}

// A genuine revisit keeps three runs with correct boundaries — a hub in two
// runs is not corruption (itinerary_repair.go), and each run's arrival is its
// own first item day.
func TestComputeTripLegsRevisitBoundaries(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-06-01", "2026-06-08"), []store.ItineraryItem{
		rlItem(0, "Louvre", rlCity("Paris"), 1),
		rlItem(1, "Orsay", rlCity("Paris"), 2),
		rlItem(2, "Colosseum", rlCity("Rome"), 3),
		rlItem(3, "Trastevere", rlCity("Rome"), 5),
		rlItem(4, "Marais walk", rlCity("Paris"), 6),
		rlItem(5, "Montmartre", rlCity("Paris"), 7),
	}, nil)
	if legs[0].Key != "Paris" || legs[1].Key != "Rome" || legs[2].Key != "Paris#2" {
		t.Fatalf("keys = %s/%s/%s, want Paris/Rome/Paris#2", legs[0].Key, legs[1].Key, legs[2].Key)
	}
	assertSpan(t, legs[0], "2026-06-01", "2026-06-03")
	assertSpan(t, legs[1], "2026-06-03", "2026-06-06")
	assertSpan(t, legs[2], "2026-06-06", "2026-06-08")
}

// A gap AFTER a confirmed stay closes from the other side: the checkout is
// explicit and cannot extend, so the next leg's start pulls back to it — the
// one boundary that still resolves toward the earlier leg's end.
func TestComputeTripLegsStayGapPullsNextLegBack(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-09-01", "2026-09-08"), []store.ItineraryItem{
		rlItem(0, "Time Out Market", rlCity("Lisbon"), 1),
		rlItem(1, "Livraria Lello", rlCity("Porto"), 7),
	}, []store.Accommodation{
		rlStay("Lisbon Loft", "Alfama, Lisbon", "2026-09-01", "2026-09-05"),
	})
	assertSpan(t, legs[0], "2026-09-01", "2026-09-05")
	assertSpan(t, legs[1], "2026-09-05", "2026-09-08")
}

// A confirmed stay whose checkout runs past the next leg's arrival renders as
// the overlap it is: both spans as stated, no collapse, no invented dates —
// the explicit booking and the contradicting item days are both shown. (The
// old chain answered this with a zero-night collapse of the next leg.)
func TestComputeTripLegsStayOverlapRendersAsStated(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-09-01", "2026-09-08"), []store.ItineraryItem{
		rlItem(0, "Time Out Market", rlCity("Lisbon"), 1),
		rlItem(1, "Livraria Lello", rlCity("Porto"), 3),
	}, []store.Accommodation{
		rlStay("Lisbon Loft", "Alfama, Lisbon", "2026-09-01", "2026-09-05"),
	})
	assertSpan(t, legs[0], "2026-09-01", "2026-09-05")
	assertSpan(t, legs[1], "2026-09-03", "2026-09-08")
	if legs[1].ZeroNight {
		t.Fatal("an overlapped leg must render as stated, not collapse")
	}
}
