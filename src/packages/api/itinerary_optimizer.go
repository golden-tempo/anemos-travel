package main

import "strconv"

// reorderItineraryByDistance reorders the places Claude returns so that
// geographically close stops are consecutive, while leaving Claude's day and
// time-of-day scheduling untouched. Reordering happens only within each
// (day, time_of_day, day_trip_from) block, so meal timing and pacing are
// preserved and the order can never read as e.g. dinner before breakfast.
//
// Each place's tags travel with its map entry (entries are moved whole), so
// day/time_of_day/city/category survive. Blocks with fewer than two
// coordinate-bearing places, or whose places lack coordinates, are left in
// their original order.
func reorderItineraryByDistance(locations []map[string]any) []map[string]any {
	if len(locations) < 2 {
		return locations
	}

	// Group indices into blocks keyed by (day, time_of_day, day_trip_from),
	// preserving the first-seen order of both blocks and their members.
	type blockKey struct {
		day         string
		timeOfDay   string
		dayTripFrom string
	}
	keyOf := func(loc map[string]any) blockKey {
		var k blockKey
		if v, ok := loc["day"].(float64); ok {
			k.day = strconv.FormatFloat(v, 'f', -1, 64)
		}
		if s, ok := loc["time_of_day"].(string); ok {
			k.timeOfDay = s
		}
		if s, ok := loc["day_trip_from"].(string); ok {
			k.dayTripFrom = s
		}
		return k
	}

	var order []blockKey
	blocks := make(map[blockKey][]int)
	for i, loc := range locations {
		k := keyOf(loc)
		if _, seen := blocks[k]; !seen {
			order = append(order, k)
		}
		blocks[k] = append(blocks[k], i)
	}

	result := make([]map[string]any, 0, len(locations))
	for _, k := range order {
		idxs := blocks[k]
		result = append(result, optimizeBlockOrder(locations, idxs)...)
	}
	return result
}

// optimizeBlockOrder returns the maps at idxs reordered to shorten the walking
// path between them. If fewer than two of them have coordinates it returns them
// in their original order.
func optimizeBlockOrder(locations []map[string]any, idxs []int) []map[string]any {
	locs := make([]Location, 0, len(idxs))
	for _, gi := range idxs {
		lat, latOK := locations[gi]["latitude"].(float64)
		lng, lngOK := locations[gi]["longitude"].(float64)
		if !latOK || !lngOK {
			// A coordinate-less place means we can't optimize this block
			// reliably; keep Claude's order.
			return collect(locations, idxs)
		}
		locs = append(locs, Location{
			ID:        strconv.Itoa(len(locs)),
			Latitude:  &lat,
			Longitude: &lng,
		})
	}
	if len(locs) < 2 {
		return collect(locations, idxs)
	}

	// Reuse the location-route optimizer's lower-level steps directly; we only
	// need the reordered sequence, not its timing/Places-resolution machinery.
	// Every loc has coordinates (guarded above), so all indices are candidates.
	ro := NewRouteOptimizer(locs)
	all := make([]int, len(locs))
	for i := range all {
		all[i] = i
	}
	route := ro.optimizeWith2Opt(ro.nearestNeighborRoute(0, all), false, 100)

	out := make([]map[string]any, 0, len(idxs))
	for _, local := range route {
		out = append(out, locations[idxs[local]])
	}
	return out
}

// collect returns the maps at idxs in their original order.
func collect(locations []map[string]any, idxs []int) []map[string]any {
	out := make([]map[string]any, 0, len(idxs))
	for _, gi := range idxs {
		out = append(out, locations[gi])
	}
	return out
}
