package main

import (
	"encoding/json"
	"fmt"
	"os"
	"testing"
)

// The corpus is independent truth, not a recording of this code's answers:
// testdata/country_lookup_cities.json is the largest city in every country
// GeoNames lists with a 15k+ settlement, plus the travel destinations that
// stress the hard parts — microstates, islands, border towns, and the coastal
// capitals that fall OUTSIDE a 1:50m coastline. Country codes come from
// GeoNames, so a regression in the table, the simplification tolerances, or
// the nearest-land fallback shows up here as a real disagreement.
type corpusCity struct {
	City    string  `json:"city"`
	Lat     float64 `json:"lat"`
	Lng     float64 `json:"lng"`
	Country string  `json:"country"`
}

// Where this lookup knowingly disagrees with GeoNames — 14 of 275, all of them
// DEPENDENT TERRITORIES that Natural Earth 1:50m either draws inside their
// sovereign state or is too coarse to draw at all. They are pinned as expected
// answers, so the test also fails if one silently starts resolving
// differently: that means the table moved and this list needs re-reading.
//
// Most are not even wrong. Réunion, Mayotte, Guadeloupe, Martinique and French
// Guiana ARE France (overseas departments), Svalbard IS Norway, Bonaire IS a
// Dutch municipality — ISO gives each its own code, and "Your travels" counts
// countries, not codes. The genuinely coarse ones are Gibraltar (no polygon at
// this scale, so it falls to Spain), the French half of Saint-Martin (the
// island's border is below 1:50m resolution), Pitcairn (absent entirely) and
// the Vatican (the source's polygon does not contain St. Peter's). Each costs
// a traveler at most one country in a lifetime count, and the alternative —
// hand-editing borders — is a position this app has no business taking.
var countryLookupDivergences = map[string]string{
	"Kralendijk":       "NL", // Bonaire — a special municipality of the Netherlands
	"West Island":      "AU", // Cocos (Keeling) Islands — Australian external territory
	"Flying Fish Cove": "AU", // Christmas Island — Australian external territory
	"Laayoune":         "MA", // Western Sahara — the source's disputed-territory coding
	"Cayenne":          "FR", // French Guiana — an overseas department
	"Les Abymes":       "FR", // Guadeloupe — an overseas department
	"Fort-de-France":   "FR", // Martinique — an overseas department
	"Saint-Denis":      "FR", // Réunion — an overseas department
	"Mamoudzou":        "FR", // Mayotte — an overseas department
	"Longyearbyen":     "NO", // Svalbard — Norwegian territory
	"Jerusalem":        "PS", // 1:50m draws the municipality inside the Palestinian polygon
	"Gibraltar":        "ES", // no Gibraltar polygon at 1:50m; nearest land is Spain
	"Marigot":          "SX", // Saint-Martin/Sint Maarten — the island border is sub-scale
	"Vatican City":     "IT", // the source's Vatican polygon does not contain St. Peter's
	"Adamstown":        "",   // Pitcairn — absent from the source entirely
}

func loadCorpus(t *testing.T) []corpusCity {
	t.Helper()
	raw, err := os.ReadFile("testdata/country_lookup_cities.json")
	if err != nil {
		t.Fatalf("read corpus: %v", err)
	}
	var cities []corpusCity
	if err := json.Unmarshal(raw, &cities); err != nil {
		t.Fatalf("parse corpus: %v", err)
	}
	if len(cities) < 200 {
		t.Fatalf("corpus shrank to %d cities — regenerate it, don't trim it", len(cities))
	}
	return cities
}

func TestCountryForPointMatchesGeoNames(t *testing.T) {
	for _, city := range loadCorpus(t) {
		want := city.Country
		if pinned, ok := countryLookupDivergences[city.City]; ok {
			want = pinned
		}
		if got := countryForPoint(city.Lat, city.Lng); got != want {
			t.Errorf("%s (%.4f, %.4f) = %q, want %q", city.City, city.Lat, city.Lng, got, want)
		}
	}
}

// Natural Earth codes Taiwan's feature "CN-TW", which is not an ISO 3166-1
// alpha-2 code; the generator rewrites it. Asserted on its own because the
// corpus passes either way — GeoNames says TW and so do we, so a regression in
// the rewrite would surface as a puzzling "CN-TW" on the wire instead.
func TestCountryForPointUsesAlpha2ForTaiwan(t *testing.T) {
	if got := countryForPoint(25.0478, 121.5319); got != "TW" {
		t.Errorf("Taipei = %q, want \"TW\"", got)
	}
}

// The fallback is load-bearing, not a safety net: containment alone misses
// every city centre that sits on a generalized coastline. If someone deletes
// it because "the polygons should cover this", these fail.
func TestCountryForPointResolvesCoastalCentres(t *testing.T) {
	coastal := map[string][2]float64{
		"PT": {38.7223, -9.1393},  // Lisbon, in the Tagus estuary at 1:50m
		"IT": {45.4408, 12.3155},  // Venice, in the lagoon
		"DK": {55.6761, 12.5683},  // Copenhagen, on the Øresund
		"SE": {59.3293, 18.0686},  // Stockholm, in the archipelago
		"TR": {41.0082, 28.9784},  // Istanbul, on the Bosphorus
		"US": {40.7128, -74.0060}, // New York, on the Hudson
		"IS": {64.1466, -21.9426}, // Reykjavík, on Faxaflói
	}
	for want, point := range coastal {
		if got := countryForPoint(point[0], point[1]); got != want {
			t.Errorf("(%.4f, %.4f) = %q, want %q", point[0], point[1], got, want)
		}
	}
}

// Enclaves have to beat the state around them, which is what the
// smallest-bounding-box-first ordering is for.
func TestCountryForPointPrefersEnclaves(t *testing.T) {
	for _, tc := range []struct {
		name      string
		lat, lng  float64
		want      string
		surrounds string
	}{
		{"San Marino", 43.9424, 12.4578, "SM", "IT"},
		{"Vaduz", 47.1410, 9.5209, "LI", "CH"},
		{"Monaco", 43.7384, 7.4246, "MC", "FR"},
		{"Maseru", -29.3151, 27.4869, "LS", "ZA"},
	} {
		if got := countryForPoint(tc.lat, tc.lng); got != tc.want {
			t.Errorf("%s = %q, want %q (not %q)", tc.name, got, tc.want, tc.surrounds)
		}
	}
}

// "" means "this pin contributes no country" — never an error, and never a
// guess. The (0,0) case matters most: Null Island is 570 km off Ghana, close
// enough to nothing but far enough that a bare nearest-land search would call
// it land.
func TestCountryForPointReportsNothingOffshore(t *testing.T) {
	for _, tc := range []struct {
		name     string
		lat, lng float64
	}{
		{"the no-location sentinel", 0, 0},
		{"mid-Pacific", -30, -140},
		{"mid-Atlantic", 30, -40},
		{"out of range latitude", 91, 10},
		{"out of range longitude", 10, 181},
	} {
		if got := countryForPoint(tc.lat, tc.lng); got != "" {
			t.Errorf("%s = %q, want \"\"", tc.name, got)
		}
	}
}

// Every code the table can emit is a plausible ISO 3166-1 alpha-2, because the
// client keys its distinct-country count on exactly this string.
func TestCountryTableEmitsAlpha2Codes(t *testing.T) {
	table := loadCountryTable()
	if table == nil {
		t.Fatal("embedded country table failed to load")
	}
	codes := map[string]bool{}
	for _, shape := range table.shapes {
		codes[shape.code] = true
	}
	if len(codes) < 200 {
		t.Errorf("table has %d countries, want at least 200", len(codes))
	}
	for code := range codes {
		if len(code) != 2 || code != fmt.Sprintf("%.2s", code) {
			t.Errorf("code %q is not alpha-2", code)
		}
		for _, r := range code {
			if r < 'A' || r > 'Z' {
				t.Errorf("code %q is not upper-case alpha-2", code)
			}
		}
	}
}

func BenchmarkCountryForPoint(b *testing.B) {
	// Athens (inside a polygon) and Venice (resolved by the fallback) — the
	// trips list runs one of these per pin per request.
	for b.Loop() {
		countryForPoint(37.9838, 23.7275)
		countryForPoint(45.4408, 12.3155)
	}
}
