package main

// Which country a coordinate is in — the one derivation behind the countries
// count in "Your travels" (specs/trips-page-insights).
//
// The trips-list payload's only geographic fact is a hub city's coordinate,
// the same one the footprint map already pins, so the country is derived from
// THAT rather than stored: no per-city geocoding request, no column to
// backfill, and every trip already in the database reports its countries the
// moment this ships. The invariant that buys is worth stating plainly —
// **every pin has a country, so countries <= pins <= cities, always**. Reading
// a country name out of Google's formatted_address instead would have made the
// count depend on whether a hub's first item happened to carry an address at
// all, which is a number nobody can check.
//
// The table is Natural Earth 1:50m, trimmed and embedded by
// scripts/build-country-boundaries.py — read that file for the source, the
// simplification tolerances, and the three features whose ISO code is
// overridden. Validated against GeoNames' 34,106 cities over 15k population:
// 99.2% agree. The residual is almost entirely Natural Earth's territorial
// coding (Taiwan, Crimea, Jerusalem, the French overseas departments), not
// geometry error — country_lookup_test.go names the divergences it knows of.

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"io"
	"log"
	"math"
	"sort"
	"sync"

	_ "embed"
)

//go:embed data/country_boundaries.json.gz
var countryBoundariesGz []byte

// countryNearestLandDegrees is how far off land a coordinate may sit and still
// take the nearest country's code. 1:50m coastlines are generalized by a
// kilometre or more, and a city centre is routinely ON that line — Lisbon,
// Venice, Copenhagen, Stockholm, Istanbul, Rio and New York all fall OUTSIDE
// every polygon at this scale. Containment alone answered 65 of the 81 cities
// in the test battery; containment plus this fallback answers 80.
//
// One degree (~111 km at the equator, less toward the poles) is generous
// enough for those and still tight enough that a mid-ocean coordinate — which
// is what a bad (0,0)-adjacent sentinel looks like — resolves to nothing.
const countryNearestLandDegrees = 1.0

// countryGridDegrees is the bucket size of the lookup's spatial index. The
// world at 1° is 48k polygon references over ~64k cells, so a containment test
// examines a handful of candidates instead of all 1,631 rings.
const countryGridDegrees = 1.0

// countryShape is one landmass: an outer ring, its holes (12 of them
// world-wide — Lesotho, San Marino, the Vatican and friends), and the
// bounding box that rejects it cheaply. Rings are FLAT lng,lat pairs, which is
// how the table encodes them: one allocation per ring instead of one per
// vertex.
type countryShape struct {
	code                   string
	outer                  []float64
	holes                  [][]float64
	minX, minY, maxX, maxY float64
}

type countryTable struct {
	// shapes are ordered SMALLEST bounding box first, so an enclave answers
	// before the state that surrounds it — the Vatican before Italy, Lesotho
	// before South Africa. The holes make that redundant where the source
	// draws one, and the ordering covers the cases where it does not.
	shapes []countryShape
	// grid maps a 1° cell to the shapes whose bounding box touches it, in the
	// same smallest-first order.
	grid map[int32][]int32
}

var (
	countryTableOnce sync.Once
	countryTableData *countryTable
)

// countryForPoint returns the ISO 3166-1 alpha-2 code for a coordinate, or ""
// when it belongs to no country the table knows — open ocean, Antarctica's
// unclaimed sector, or a caller passing the (0,0) no-location sentinel.
//
// Callers treat "" as "this pin contributes no country", never as an error:
// the pin still draws, and the count is simply of the pins that resolved.
func countryForPoint(lat, lng float64) string {
	// The no-location sentinel the itinerary uses (computeTripLegs). Null
	// Island is in the Gulf of Guinea, ~570 km off Ghana, so the nearest-land
	// fallback would otherwise happily call it Ghana.
	if lat == 0 && lng == 0 {
		return ""
	}
	if lat < -90 || lat > 90 || lng < -180 || lng > 180 {
		return ""
	}
	table := loadCountryTable()
	if table == nil {
		return ""
	}
	if code := table.containing(lat, lng); code != "" {
		return code
	}
	return table.nearest(lat, lng)
}

func loadCountryTable() *countryTable {
	countryTableOnce.Do(func() {
		table, err := parseCountryTable(countryBoundariesGz)
		if err != nil {
			// Degraded, not fatal: the countries stat disappears from "Your
			// travels" and every other surface keeps working. A panic here
			// would take the whole API down over a caption.
			log.Printf("country lookup: %v (countries will not be reported)", err)
			return
		}
		countryTableData = table
	})
	return countryTableData
}

// parseCountryTable decodes the embedded table and builds its grid index. It
// returns an error rather than logging one so the degrade-vs-fail decision
// stays in loadCountryTable, where the sync.Once makes it once.
func parseCountryTable(gz []byte) (*countryTable, error) {
	reader, err := gzip.NewReader(bytes.NewReader(gz))
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	raw, err := io.ReadAll(reader)
	if err != nil {
		return nil, err
	}
	var decoded struct {
		Countries []struct {
			Code     string `json:"c"`
			Polygons []struct {
				Outer []float64   `json:"o"`
				Holes [][]float64 `json:"h"`
			} `json:"p"`
		} `json:"countries"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return nil, err
	}

	table := &countryTable{grid: make(map[int32][]int32)}
	for _, country := range decoded.Countries {
		for _, polygon := range country.Polygons {
			if len(polygon.Outer) < 8 { // fewer than 4 vertices encloses nothing
				continue
			}
			shape := countryShape{
				code:  country.Code,
				outer: polygon.Outer,
				holes: polygon.Holes,
				minX:  math.Inf(1), minY: math.Inf(1),
				maxX: math.Inf(-1), maxY: math.Inf(-1),
			}
			for i := 0; i+1 < len(polygon.Outer); i += 2 {
				x, y := polygon.Outer[i], polygon.Outer[i+1]
				shape.minX = math.Min(shape.minX, x)
				shape.maxX = math.Max(shape.maxX, x)
				shape.minY = math.Min(shape.minY, y)
				shape.maxY = math.Max(shape.maxY, y)
			}
			table.shapes = append(table.shapes, shape)
		}
	}
	// Smallest bounding box first — see countryTable.shapes. Stable so the
	// order of equal-area shapes follows the table, and the answer for a
	// coordinate is the same on every process.
	sort.SliceStable(table.shapes, func(a, b int) bool {
		return boundingArea(table.shapes[a]) < boundingArea(table.shapes[b])
	})

	for i := range table.shapes {
		shape := &table.shapes[i]
		for gx := cellIndex(shape.minX); gx <= cellIndex(shape.maxX); gx++ {
			for gy := cellIndex(shape.minY); gy <= cellIndex(shape.maxY); gy++ {
				key := cellKey(gx, gy)
				table.grid[key] = append(table.grid[key], int32(i))
			}
		}
	}
	return table, nil
}

// containing returns the code of the smallest shape the point falls inside,
// or "" when it falls inside none.
func (t *countryTable) containing(lat, lng float64) string {
	for _, i := range t.grid[cellKey(cellIndex(lng), cellIndex(lat))] {
		shape := &t.shapes[i]
		if lng < shape.minX || lng > shape.maxX || lat < shape.minY || lat > shape.maxY {
			continue
		}
		if !pointInRing(shape.outer, lng, lat) {
			continue
		}
		inHole := false
		for _, hole := range shape.holes {
			if pointInRing(hole, lng, lat) {
				inHole = true
				break
			}
		}
		if !inHole {
			return shape.code
		}
	}
	return ""
}

// nearest returns the code of the closest coastline within
// countryNearestLandDegrees, or "" when nothing is that close.
func (t *countryTable) nearest(lat, lng float64) string {
	// Longitude degrees shrink toward the poles; scaling x by cos(lat) keeps
	// "closest" meaning closest on the ground rather than closest on an
	// equirectangular projection, which would drag high-latitude points
	// sideways (Reykjavík, Anchorage, Tromsø).
	kx := math.Cos(lat * math.Pi / 180)
	best := ""
	bestDist := countryNearestLandDegrees * countryNearestLandDegrees
	// The cell window has to cover the search radius in DEGREES, and because
	// distance is measured with longitude scaled by kx, 1 scaled degree is
	// 1/kx degrees of longitude — three cells wide at 70°N, not one. Clamped
	// so a coordinate near a pole doesn't sweep the whole latitude band.
	radiusY := int32(math.Ceil(countryNearestLandDegrees / countryGridDegrees))
	radiusX := radiusY
	if kx > 0.05 {
		radiusX = int32(math.Ceil(countryNearestLandDegrees / countryGridDegrees / kx))
	} else {
		radiusX = int32(math.Ceil(180 / countryGridDegrees))
	}
	gx0, gy0 := cellIndex(lng), cellIndex(lat)
	seen := make(map[int32]struct{})
	// Not wrapped at the antimeridian: a coordinate within 1° of ±180 sees
	// only the side of the seam it is on. Every inhabited place out there —
	// Fiji, Kiribati, Chukotka — resolves by containment, so the seam has
	// never reached this path.
	for dx := -radiusX; dx <= radiusX; dx++ {
		for dy := -radiusY; dy <= radiusY; dy++ {
			for _, i := range t.grid[cellKey(gx0+dx, gy0+dy)] {
				if _, done := seen[i]; done {
					continue
				}
				seen[i] = struct{}{}
				shape := &t.shapes[i]
				if d := ringDistanceSquared(shape.outer, lng, lat, kx); d < bestDist {
					bestDist = d
					best = shape.code
				}
			}
		}
	}
	return best
}

// pointInRing is the even-odd (ray casting) test over a flat lng,lat ring.
func pointInRing(ring []float64, x, y float64) bool {
	inside := false
	n := len(ring) / 2
	j := n - 1
	for i := 0; i < n; i++ {
		xi, yi := ring[2*i], ring[2*i+1]
		xj, yj := ring[2*j], ring[2*j+1]
		if (yi > y) != (yj > y) && x < (xj-xi)*(y-yi)/(yj-yi)+xi {
			inside = !inside
		}
		j = i
	}
	return inside
}

// ringDistanceSquared is the squared distance from a point to a ring's nearest
// EDGE (not its nearest vertex — a simplified coastline can put its vertices
// hundreds of kilometres apart), in degrees with longitude scaled by kx.
func ringDistanceSquared(ring []float64, x, y, kx float64) float64 {
	best := math.Inf(1)
	n := len(ring) / 2
	j := n - 1
	px := x * kx
	for i := 0; i < n; i++ {
		ax, ay := ring[2*j]*kx, ring[2*j+1]
		bx, by := ring[2*i]*kx, ring[2*i+1]
		j = i
		dx, dy := bx-ax, by-ay
		var qx, qy float64
		if dx == 0 && dy == 0 {
			qx, qy = ax, ay
		} else {
			t := ((px-ax)*dx + (y-ay)*dy) / (dx*dx + dy*dy)
			t = math.Max(0, math.Min(1, t))
			qx, qy = ax+t*dx, ay+t*dy
		}
		if d := (px-qx)*(px-qx) + (y-qy)*(y-qy); d < best {
			best = d
		}
	}
	return best
}

func boundingArea(s countryShape) float64 {
	return (s.maxX - s.minX) * (s.maxY - s.minY)
}

func cellIndex(degrees float64) int32 {
	return int32(math.Floor(degrees / countryGridDegrees))
}

// cellKey packs a cell's two indices into one map key. Longitude spans 360
// cells at 1°, so 1024 leaves room for a finer grid without a collision.
func cellKey(gx, gy int32) int32 {
	return gx*1024 + gy
}
