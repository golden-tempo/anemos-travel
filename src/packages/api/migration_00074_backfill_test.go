package main

import (
	"database/sql"
	"strings"
	"testing"

	"github.com/pressly/goose/v3"
)

// migration_00074_backfill_test.go — the part of 00074 that touches live data
// (specs/booking-city-grouping). "Migrations apply from zero" proves the SQL
// parses against an empty table; this proves what it does to rows that exist.
// The backfill writes a value the runtime then treats as EXPLICIT — the sync
// fallback fills only NULL — so a wrong stamp here would stick forever, which
// is why the ambiguous and unrecoverable cases must provably stay NULL.
//
// The leg ranges available to SQL are the auto stay rows' dates (the client
// wrote them from visibleLegRanges); their destination_label carries the cased
// city (00064).

// seedCityTrip inserts a trip whose derived checklist is already in the
// post-00064 shape: auto stay rows carrying the leg date ranges, auto
// transport rows carrying the chain, plus the custom rows under test.
func seedCityTrip(t *testing.T, db *sql.DB, email string) string {
	t.Helper()
	var userID, tripID string
	if err := db.QueryRow(`INSERT INTO users (email) VALUES ($1) RETURNING id`,
		strings.ToLower(email)).Scan(&userID); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	if err := db.QueryRow(`INSERT INTO trips (user_id, title) VALUES ($1, 'City trip') RETURNING id`,
		userID).Scan(&tripID); err != nil {
		t.Fatalf("seed trip: %v", err)
	}
	return tripID
}

func seedAutoStay(t *testing.T, db *sql.DB, tripID, city, checkIn, checkOut string, pos int) {
	t.Helper()
	if _, err := db.Exec(
		`INSERT INTO booking_todos (trip_id, kind, todo_key, title, position, auto,
		                            destination_label, depart_date, return_date)
		 VALUES ($1, 'stay', $2, $3, $4, true, $5, $6, $7)`,
		tripID, "stay:"+strings.ToLower(city), "Stay in "+city, pos, city, checkIn, checkOut); err != nil {
		t.Fatalf("seed stay %s: %v", city, err)
	}
}

func seedAutoTransport(t *testing.T, db *sql.DB, tripID, key string, pos int) {
	t.Helper()
	if _, err := db.Exec(
		`INSERT INTO booking_todos (trip_id, kind, todo_key, title, position, auto)
		 VALUES ($1, 'transport', $2, $3, $4, true)`,
		tripID, key, key, pos); err != nil {
		t.Fatalf("seed transport %s: %v", key, err)
	}
}

func seedCustom(t *testing.T, db *sql.DB, tripID, kind, title string, departDate *string, pos int) {
	t.Helper()
	if _, err := db.Exec(
		`INSERT INTO booking_todos (trip_id, kind, todo_key, title, position, auto, depart_date)
		 VALUES ($1, $2, $3, $4, $5, false, $6)`,
		tripID, kind, "custom:"+title, title, pos, departDate); err != nil {
		t.Fatalf("seed custom %s: %v", title, err)
	}
}

func readCityLabels(t *testing.T, db *sql.DB, tripID string) map[string]*string {
	t.Helper()
	rows, err := db.Query(`SELECT title, city_label FROM booking_todos WHERE trip_id = $1`, tripID)
	if err != nil {
		t.Fatalf("read rows: %v", err)
	}
	defer rows.Close()
	out := map[string]*string{}
	for rows.Next() {
		var title string
		var label *string
		if err := rows.Scan(&title, &label); err != nil {
			t.Fatalf("scan: %v", err)
		}
		out[title] = label
	}
	return out
}

// The spec's own fixture: five reservations against Amsterdam Aug 24–26 and
// Prague Aug 26–29. Four are unambiguous and move; the A'DAM Lookout booking
// sits on the shared transition day and must stay in "Other bookings".
func TestMigration00074BackfillsUnambiguousRows(t *testing.T) {
	db := migrateScratchDB(t, 72)

	trip := seedCityTrip(t, db, "backfill74@example.com")
	seedAutoStay(t, db, trip, "Amsterdam", "2026-08-24", "2026-08-26", 1)
	seedAutoStay(t, db, trip, "Prague", "2026-08-26", "2026-08-29", 3)
	d := func(s string) *string { return &s }
	seedCustom(t, db, trip, "other", "Reserve table at Moeders", d("2026-08-24"), 10)
	seedCustom(t, db, trip, "other", "Book Rijksmuseum timed entry", d("2026-08-24"), 11)
	seedCustom(t, db, trip, "other", "Book Door 74 speakeasy slot", d("2026-08-25"), 12)
	seedCustom(t, db, trip, "other", "Reserve table at Renvy", d("2026-08-25"), 13)
	seedCustom(t, db, trip, "other", "Book A'DAM Lookout entry", d("2026-08-26"), 14)
	// Guards: a dated custom STAY row is not a reservation (other-kind only),
	// and an undated reservation has nothing to derive from.
	seedCustom(t, db, trip, "stay", "Book hostel night", d("2026-08-24"), 15)
	seedCustom(t, db, trip, "other", "Book travel insurance", nil, 16)

	if err := goose.UpTo(db, "migrations", 74); err != nil {
		t.Fatalf("apply 00074: %v", err)
	}

	got := readCityLabels(t, db, trip)
	want := map[string]*string{
		"Reserve table at Moeders":     ptr("Amsterdam"),
		"Book Rijksmuseum timed entry": ptr("Amsterdam"),
		"Book Door 74 speakeasy slot":  ptr("Amsterdam"),
		"Reserve table at Renvy":       ptr("Amsterdam"),
		"Book A'DAM Lookout entry":     nil, // the transition day: two legs cover Aug 26
		"Book hostel night":            nil,
		"Book travel insurance":        nil,
		"Stay in Amsterdam":            nil, // auto rows carry identity, not tags
		"Stay in Prague":               nil,
	}
	for title, wantLabel := range want {
		gotLabel, ok := got[title]
		if !ok {
			t.Fatalf("row %q vanished in the backfill", title)
		}
		if strPtrVal(gotLabel) != strPtrVal(wantLabel) {
			t.Errorf("%q city = %v, want %v", title, strPtrVal(gotLabel), strPtrVal(wantLabel))
		}
	}
}

// A revisited city collapses its two stay rows onto one key before this
// migration ever runs, so the earlier run's range is unrecoverable in SQL —
// the whole trip is skipped (detected from the transport chain) and left to
// the runtime fallback, which sees the full leg derivation. A stamp that
// LOOKS unambiguous here could contradict it, and a wrong stamp is permanent.
func TestMigration00074SkipsRevisitedCityTrips(t *testing.T) {
	db := migrateScratchDB(t, 72)

	trip := seedCityTrip(t, db, "backfill74-revisit@example.com")
	// Prague (Aug 24–26) → Amsterdam (Aug 26–28) → Prague again (Aug 28–29).
	// The batch upsert collapsed both Prague runs onto one stay:prague key,
	// last wins — so run 1's Aug 24–26 range no longer exists in this table.
	seedAutoStay(t, db, trip, "Amsterdam", "2026-08-26", "2026-08-28", 1)
	seedAutoStay(t, db, trip, "Prague", "2026-08-28", "2026-08-29", 3)
	seedAutoTransport(t, db, trip, "transport:@home>>prague", 0)
	seedAutoTransport(t, db, trip, "transport:prague>>amsterdam", 2)
	seedAutoTransport(t, db, trip, "transport:amsterdam>>prague", 4)
	seedAutoTransport(t, db, trip, "transport:prague>>@home", 5)
	d := func(s string) *string { return &s }
	// Aug 26 looks unambiguous against the SURVIVING rows (only Amsterdam's
	// stay covers it) — but it is really the transition day between run-1
	// Prague and Amsterdam, which the full derivation would refuse. Stamping
	// "Amsterdam" here would be permanent; the trip must be skipped.
	seedCustom(t, db, trip, "other", "Reserve canal tour", d("2026-08-26"), 10)

	if err := goose.UpTo(db, "migrations", 74); err != nil {
		t.Fatalf("apply 00074: %v", err)
	}
	if got := readCityLabels(t, db, trip)["Reserve canal tour"]; got != nil {
		t.Fatalf("revisited-city trip was stamped %q; must be left to the runtime fallback", *got)
	}
}

func ptr(s string) *string { return &s }
