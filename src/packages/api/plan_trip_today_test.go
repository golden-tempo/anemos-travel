package main

import (
	"testing"

	"github.com/jackc/pgx/v5/pgtype"
)

// tripDayNumberOn (issue #641): pure date math, table-driven against the
// Dart twin's own rules (tripDayOn, utils/trip_days.dart) — the first day
// IS day 1 (not day 0), a date before the trip's start or past a valid end
// is "no answer" rather than a negative/out-of-range number, and a trip with
// no end date never rolls over once started (an ongoing trip's last leg has
// no stored close).
func TestTripDayNumberOn(t *testing.T) {
	cases := []struct {
		name    string
		start   pgtype.Date
		end     pgtype.Date
		when    string
		wantDay int
		wantOK  bool
	}{
		{"arrival day is day 1", validDate("2026-08-24"), validDate("2026-09-27"), "2026-08-24", 1, true},
		{"three weeks in, per the issue", validDate("2026-08-24"), validDate("2026-09-27"), "2026-09-14", 22, true},
		{"last day is still in range", validDate("2026-08-24"), validDate("2026-09-27"), "2026-09-27", 35, true},
		{"the day after the trip ends", validDate("2026-08-24"), validDate("2026-09-27"), "2026-09-28", 0, false},
		{"before the trip starts", validDate("2026-08-24"), validDate("2026-09-27"), "2026-08-23", 0, false},
		{"no start date at all", pgtype.Date{}, pgtype.Date{}, "2026-09-14", 0, false},
		{"open-ended trip, started, no rollover", validDate("2026-08-24"), pgtype.Date{}, "2026-09-14", 22, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			day, ok := tripDayNumberOn(c.start, c.end, civilDate(c.when))
			if ok != c.wantOK || day != c.wantDay {
				t.Fatalf("tripDayNumberOn(%v, %v, %s) = (%d, %v), want (%d, %v)",
					c.start, c.end, c.when, day, ok, c.wantDay, c.wantOK)
			}
		})
	}
}
