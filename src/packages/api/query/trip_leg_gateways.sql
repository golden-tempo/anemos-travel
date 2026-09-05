-- name: ListTripLegGateways :many
SELECT * FROM trip_leg_gateways WHERE trip_id = $1;

-- name: UpsertTripLegGateway :one
-- Provenance ladder in one statement: a 'traveler' row yields only to another
-- 'traveler' write; 'auto' and 'self' yield to anything newer. When the WHERE
-- on the conflict arm rejects the write, the statement updates nothing and
-- RETURNING yields NO row — callers must treat ErrNoRows as "an earlier
-- traveler decision won", never as a failure.
INSERT INTO trip_leg_gateways (trip_id, city_fold, airport, airport_label, source)
VALUES ($1, $2, $3, $4, $5)
ON CONFLICT (trip_id, city_fold) DO UPDATE
SET airport = EXCLUDED.airport,
    airport_label = EXCLUDED.airport_label,
    source = EXCLUDED.source,
    updated_at = now()
WHERE trip_leg_gateways.source <> 'traveler' OR EXCLUDED.source = 'traveler'
RETURNING *;
