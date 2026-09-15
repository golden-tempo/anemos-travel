-- name: UpsertPlanChatSession :exec
-- Whole-transcript upsert, twice per /plan turn (start + deferred end).
-- title is set once from the opening message and never overwritten, so the
-- entry keeps a stable identity in the continue list.
INSERT INTO plan_chat_sessions (
    user_id, chat_id, title, preview, summary, messages, message_count
) VALUES ($1, $2, $3, $4, $5, $6, $7)
ON CONFLICT (user_id, chat_id) DO UPDATE SET
    preview = EXCLUDED.preview,
    summary = EXCLUDED.summary,
    messages = EXCLUDED.messages,
    message_count = EXCLUDED.message_count,
    updated_at = now();

-- name: ListResumablePlanChatSessions :many
-- Summary columns only (messages can be large). A chat that already produced
-- a trip is represented by its trip card, so it is excluded here — this also
-- hides abandoned refine chats, whose chat_id belongs to an existing trip.
SELECT id, chat_id, title, preview, message_count, created_at, updated_at
FROM plan_chat_sessions s
WHERE s.user_id = $1
  AND NOT EXISTS (
      SELECT 1 FROM trips t
      WHERE t.user_id = s.user_id AND t.chat_id = s.chat_id
  )
ORDER BY s.updated_at DESC
LIMIT 10;

-- name: GetPlanChatSessionByChatID :one
SELECT * FROM plan_chat_sessions
WHERE user_id = $1 AND chat_id = $2;

-- name: DeletePlanChatSession :execrows
DELETE FROM plan_chat_sessions
WHERE user_id = $1 AND chat_id = $2;

-- name: DeleteStalePlanChatSessions :exec
-- Opportunistic prune (called from the list handler): a conversation idle for
-- two months is abandoned, not "in progress". Deliberately does NOT reach
-- trip_refine_sessions: a trip planned in August for next March must still
-- have its chat in November, so those are retained for the trip's lifetime and
-- collected by the FK cascade instead (specs/trip-refine-memory).
DELETE FROM plan_chat_sessions
WHERE updated_at < now() - interval '60 days';

-- name: UpsertTripRefineSession :exec
-- Whole-transcript upsert, twice per trip-bound /plan turn (start + deferred
-- end), under the same start→final ordering contract as
-- UpsertPlanChatSession. Keyed by (user, trip): the client's per-panel chat_id
-- is meaningless here and is deliberately not stored, which is what makes a
-- refine transcript unaddressable by chat id (specs/trip-refine-memory).
--
-- Targets the partial unique index on (user_id, trip_id) WHERE is_active
-- (#639/00078): a turn always appends to the ACTIVE conversation, never to an
-- archived one, so continuing to chat can never resurrect a "Previous chat"
-- entry out from under the traveler.
INSERT INTO trip_refine_sessions (
    user_id, trip_id, preview, summary, messages, message_count
) VALUES ($1, $2, $3, $4, $5, $6)
ON CONFLICT (user_id, trip_id) WHERE is_active DO UPDATE SET
    preview = EXCLUDED.preview,
    summary = EXCLUDED.summary,
    messages = EXCLUDED.messages,
    message_count = EXCLUDED.message_count,
    updated_at = now();

-- name: GetTripRefineSession :one
-- The active conversation — what opening the chat resumes.
SELECT * FROM trip_refine_sessions
WHERE user_id = $1 AND trip_id = $2 AND is_active;

-- name: GetTripRefineSessionSummary :one
-- Presence + freshness for GET /trips/{id} (the refine_chat object). Summary
-- columns only: the transcript can run to hundreds of KB and is fetched on
-- demand from GET /trips/{id}/refine-chat, never on every trip page load —
-- the same list/detail split as /chats. Active only — a trip only ever
-- advertises the conversation opening the chat would resume.
SELECT preview, message_count, updated_at FROM trip_refine_sessions
WHERE user_id = $1 AND trip_id = $2 AND is_active;

-- name: ArchiveActiveTripRefineSession :execrows
-- "New chat": retire the active conversation into history instead of
-- deleting it (#639). Idempotent — 0 rows affected when there was no active
-- conversation, which deleteTripRefineChatHandler treats the same as 1 (its
-- documented idempotence, unchanged since 00069).
UPDATE trip_refine_sessions SET is_active = false
WHERE user_id = $1 AND trip_id = $2 AND is_active;

-- name: PruneTripRefineSessionHistory :exec
-- Keeps at most 5 archived conversations per (user, trip) — "at most five
-- prior conversations ... stored in the database" (#639). Run once per "New
-- chat", right after ArchiveActiveTripRefineSession grows the history by one,
-- so this only ever has to remove at most that one oldest row.
DELETE FROM trip_refine_sessions
WHERE id IN (
    SELECT s.id FROM trip_refine_sessions s
    WHERE s.user_id = $1 AND s.trip_id = $2 AND NOT s.is_active
    ORDER BY s.updated_at DESC
    OFFSET 5
);

-- name: ListTripRefineSessionHistory :many
-- The "Previous chats" menu: past conversations about this trip, most
-- recently active first. Summary columns only, like the active summary above.
SELECT id, preview, message_count, created_at, updated_at
FROM trip_refine_sessions
WHERE user_id = $1 AND trip_id = $2 AND NOT is_active
ORDER BY updated_at DESC
LIMIT 5;

-- name: GetTripRefineSessionHistoryEntry :one
-- One archived conversation's full transcript, scoped to its (user, trip) the
-- same way GetTripRefineSession is, so a history entry can never be read
-- across trips or travelers by guessing its id.
SELECT * FROM trip_refine_sessions
WHERE id = $1 AND user_id = $2 AND trip_id = $3 AND NOT is_active;

-- name: ActivateTripRefineSessionHistoryEntry :execrows
-- Half of "resume a previous chat": promotes one archived row back to
-- active. Callers run ArchiveActiveTripRefineSession first (in the same
-- transaction) so the partial unique index never sees two active rows for
-- this (user, trip) at once. Total archived count is unchanged by a
-- resume — one leaves history, the conversation it replaces enters it — so
-- this never needs the 5-cap prune.
UPDATE trip_refine_sessions SET is_active = true
WHERE id = $1 AND user_id = $2 AND trip_id = $3 AND NOT is_active;
