package main

import (
	"time"

	"github.com/jackc/pgx/v5/pgtype"
)

// tripDayNumberOn (issue #641): the 1-based trip day that a calendar date
// falls on — the server-side twin of the Flutter app's tripDayOn
// (utils/trip_days.dart, specs/today-mode). It exists so the agent can be
// TOLD which trip day "today" is instead of deriving it itself from the
// trip's start_date and every city leg's rendered range.
//
// Before this, the only "day N ↔ calendar date" fact in the model's context
// was legsRenderSummary's per-CITY spans — correct, but it makes "what day
// number is today" a multi-step inference (find the leg spanning today, read
// its start, count forward). For a same-city move a couple of days wide
// ("move today's museum to tomorrow") that inference is pure overhead: the
// model would walk itself through it in the reply ("day 1 was August 24,
// we're now on day 22…") because that IS the derivation, not because the
// move itself needed it. Stating the answer directly removes the reason to
// show the work.
//
// Mirrors tripDayOn's rules exactly so the two never disagree: date-only
// (time of day ignored), false before day 1, false past a valid end date, and
// an unbounded trip (no end date) never rolls over once started.
func tripDayNumberOn(start, end pgtype.Date, when time.Time) (int, bool) {
	if !start.Valid {
		return 0, false
	}
	startDay := dateOnly(start.Time)
	day := int(dateOnly(when).Sub(startDay).Hours()/24) + 1
	if day < 1 {
		return 0, false
	}
	if end.Valid {
		lastDay := int(dateOnly(end.Time).Sub(startDay).Hours()/24) + 1
		if day > lastDay {
			return 0, false
		}
	}
	return day, true
}

// dateOnly truncates to the calendar date in UTC — pgtype.Date values are
// already date-only (no wall-clock/timezone component to preserve), so this
// just drops time.Now()'s time-of-day before the subtraction above.
func dateOnly(t time.Time) time.Time {
	return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.UTC)
}
