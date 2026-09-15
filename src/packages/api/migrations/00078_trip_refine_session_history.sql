-- +goose Up
-- Trip chat history (#639): a trip's refine conversation used to be a single
-- row that "New chat" destroyed outright. It is now the ACTIVE row of a small
-- per-(user, trip) history — up to 5 past conversations kept alongside it, so
-- starting fresh no longer throws the old thread away.
--
-- is_active carries the "one running conversation" invariant that 00069's
-- table-level UNIQUE (user_id, trip_id) used to: exactly one row per
-- (user, trip) may be active at a time, enforced the same way — a database
-- constraint, not a convention — just narrowed to a partial index so the
-- ARCHIVED rows for that same pair are free to be many. GetTripRefineSession
-- and the panel-facing summary keep reading "AND is_active" (they mean "the
-- conversation you'd resume by opening the chat"); nothing about their
-- contract changes.
--
-- No new table for the archive: the archived rows and the active one share
-- every column (transcript shape, retention-by-trip-lifetime via the
-- existing ON DELETE CASCADE), and is_active is the one fact that
-- distinguishes "resume this" from "list this in Previous chats". Splitting
-- them would duplicate 00069's whole header for zero new invariant.
ALTER TABLE trip_refine_sessions ADD COLUMN is_active BOOLEAN NOT NULL DEFAULT true;

ALTER TABLE trip_refine_sessions
    DROP CONSTRAINT IF EXISTS trip_refine_sessions_user_id_trip_id_key;
CREATE UNIQUE INDEX trip_refine_sessions_active_idx
    ON trip_refine_sessions (user_id, trip_id) WHERE is_active;

-- Previous-chats listing/pruning always filters to one (user, trip) pair and
-- orders by recency; user_id-leading like 00069's trip_idx reasoning, just
-- for the archived side instead of the cascade side.
CREATE INDEX trip_refine_sessions_history_idx
    ON trip_refine_sessions (user_id, trip_id, updated_at DESC) WHERE NOT is_active;

-- +goose Down
DROP INDEX IF EXISTS trip_refine_sessions_history_idx;
DROP INDEX IF EXISTS trip_refine_sessions_active_idx;
-- Down is a dev affordance (production only runs goose.Up); archived rows
-- would collide with 00069's original UNIQUE, so they are dropped rather than
-- folded back into "the" one conversation the old schema could only name one of.
DELETE FROM trip_refine_sessions WHERE NOT is_active;
ALTER TABLE trip_refine_sessions ADD CONSTRAINT trip_refine_sessions_user_id_trip_id_key
    UNIQUE (user_id, trip_id);
ALTER TABLE trip_refine_sessions DROP COLUMN is_active;
