-- +goose Up
-- A booking row learns which city it belongs to (specs/booking-city-grouping).
--
-- WHY. Restaurant, museum and activity reservations land under "Other
-- bookings" at the foot of the Bookings tab: `other`-kind rows carry no leg
-- semantics (booking_todo_identity.go clears role for them), so the client's
-- slot matching — which speaks only the `stay:<city>` / `transport:<a>>><b>`
-- key grammar — can never claim a `custom:`/`agent:` row into a city section.
--
-- WHAT. An explicit, authoritative city label, in the grammar 00064
-- established (origin_label / destination_label — cased display label, e.g.
-- "Amsterdam", matched case-insensitively). NOT an overload of
-- destination_label: that column means "where this leg arrives", and a dinner
-- reservation has no leg. The server fills it from depart_date only when it is
-- NULL and exactly ONE leg's date range covers the date (the sync fallback in
-- booking_todo_identity.go); a date two legs share — Amsterdam Aug 24–26,
-- Prague Aug 26–29, booking Aug 26 — is ambiguous and stays NULL, because the
-- date does not say which city the reservation is in. Explicit beats derived;
-- ambiguity refuses to guess (docs/zen.md).
ALTER TABLE booking_todos ADD COLUMN city_label text; -- cased display label, e.g. "Amsterdam"

-- Backfill, unambiguous rows only — the same exactly-one-covering-leg
-- predicate the runtime fallback applies, evaluated over the data this
-- migration can see: the trip's auto stay rows, whose depart/return dates ARE
-- the leg date ranges the client derived from visibleLegRanges (their
-- destination_label is the cased city, 00064). Rows left NULL here are picked
-- up by the runtime fallback on the trip's next sync, which sees the full leg
-- derivation (computeTripLegs).
--
-- Trips with a REVISITED city are skipped outright: the batch upsert collapses
-- both runs' stay rows onto one `stay:<city>` key (last wins), so the earlier
-- run's date range is not recoverable here, and a booking dated on that lost
-- run's transition day would read "exactly one covering leg" when the full
-- derivation says two. A revisit is visible in the transport chain — a city
-- that is the destination of two derived legs was arrived at twice. Wrongly
-- stamped is worse than unstamped: the fallback never overwrites a set value,
-- so a wrong label here would stick.
WITH stay_legs AS (
    SELECT trip_id, destination_label AS label, depart_date, return_date
    FROM booking_todos
    WHERE auto AND kind = 'stay' AND todo_key LIKE 'stay:%'
      AND destination_label IS NOT NULL
      AND depart_date IS NOT NULL AND return_date IS NOT NULL
), revisited AS (
    SELECT DISTINCT trip_id FROM (
        SELECT trip_id
        FROM booking_todos
        WHERE auto AND kind = 'transport' AND todo_key LIKE 'transport:%>>%'
        GROUP BY trip_id, split_part(substring(todo_key from 11), '>>', 2)
        HAVING count(*) > 1
    ) r
)
UPDATE booking_todos b
SET city_label = (
    SELECT l.label FROM stay_legs l
    WHERE l.trip_id = b.trip_id
      AND b.depart_date BETWEEN l.depart_date AND l.return_date
)
WHERE b.kind = 'other' AND b.auto = false
  AND b.city_label IS NULL AND b.depart_date IS NOT NULL
  AND b.trip_id NOT IN (SELECT trip_id FROM revisited)
  AND (SELECT count(*) FROM stay_legs l
       WHERE l.trip_id = b.trip_id
         AND b.depart_date BETWEEN l.depart_date AND l.return_date) = 1;

-- +goose Down
ALTER TABLE booking_todos DROP COLUMN IF EXISTS city_label;
