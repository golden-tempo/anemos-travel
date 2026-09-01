-- +goose Up
-- Gateway airports for cities too small to have one (specs/leg-gateway-airports).
--
-- A derived flight leg's endpoints are itinerary CITY labels, so a stay in
-- Bad Ischl produced checklist rows reading "Belgrade → Bad Ischl" — a flight
-- that does not exist. The traveler flies via Salzburg (SZG), told the agent
-- so, and the agent had nowhere to put that fact (the transcript that
-- triggered this feature has it apologizing that it "can't rename those
-- legs").
--
-- This table is that somewhere: per trip, per itinerary city, the airport the
-- traveler actually flies through. Row identity stays the city pair
-- (booking_todo_identity.go — labels are content, keys are identity), and the
-- sync path substitutes the gateway into the LABELS, title and search link of
-- inter-city flight legs, exactly the way trips.origin_airport already flows
-- into the two home legs (00064).
--
-- city_fold is lower(trim(city)) — the derivation's own keyspace, matching
-- transportTodoKey's folding, so a gateway follows its city through date
-- moves and reorders and simply stops matching if the city is replaced
-- (the same harmless-orphan behavior as every other city-keyed side record).
--
-- source records who decided, because the three provenances have different
-- overwrite rights:
--   'auto'     — resolved by the server (city has no airport of its own;
--                nearest bookable airport by the leg's coordinates). May be
--                replaced by ANY later write.
--   'traveler' — stated by the traveler (via the agent's set_leg_gateway).
--                Never overwritten by 'auto'; only another traveler
--                statement replaces it.
--   'self'     — negative cache: the city resolved to an airport of its own,
--                so NO relabeling happens ("Belgrade" must not become
--                "Belgrade (BEG)" uninvited). Exists so the sync path asks
--                Duffel once per (trip, city), not once per sync.
CREATE TABLE trip_leg_gateways (
    trip_id uuid NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
    city_fold text NOT NULL,
    airport text NOT NULL,
    -- The airport's own city/name for copy ("Salzburg"), when known. The
    -- label renders as "Salzburg (SZG)"; a NULL falls back to the bare code.
    airport_label text,
    source text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (trip_id, city_fold),
    CONSTRAINT trip_leg_gateways_iata CHECK (airport ~ '^[A-Z]{3}$'),
    CONSTRAINT trip_leg_gateways_source CHECK (source IN ('auto', 'traveler', 'self')),
    CONSTRAINT trip_leg_gateways_city CHECK (city_fold <> '' AND city_fold = lower(btrim(city_fold)))
);

-- +goose Down
DROP TABLE trip_leg_gateways;
