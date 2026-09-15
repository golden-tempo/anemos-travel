package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/mux"
	"github.com/jackc/pgx/v5"

	"travel-route-planner/store"
)

// Trip refine conversations (specs/trip-refine-memory). One ACTIVE saved
// conversation per traveler per trip: the chat behind the trip-detail refine
// panel, so closing the panel — or hitting back, which used to pop the whole
// page — never loses it. Since #639 up to 5 retired conversations are kept
// alongside it as history ("Previous chats"), so "New chat" archives the
// running conversation instead of destroying it; see the 00078 migration
// header for how is_active enforces "at most one active, at most 5 archived".
//
// Addressed by trip id and nothing else. There is deliberately no chat id in
// this table or on this wire: a refine transcript must never be resumable into
// the unbound Agent tab, where the trip binding would silently vanish and the
// agent would fall back to create_itinerary. See the 00069 migration header for
// why this is a separate table rather than a nullable column on
// plan_chat_sessions.

// tripRefineHistoryCap mirrors the 00078 migration's PruneTripRefineSessionHistory
// query (`LIMIT 5` / `OFFSET 5`, kept in sync by hand since SQL cannot take a
// Go constant): "at most five prior conversations for a single trip for a
// single user stored in the database" (#639).
const tripRefineHistoryCap = 5

// TripRefineChatSummary is presence + freshness, attached to full trip views as
// `refine_chat`. It carries NO identifier — that absence is the feature.
//
// Not to be confused with TripResponse.ChatID, which is the OWNER's itinerary
// version-lineage key: different entity, different lifetime, different
// visibility (collaborators never receive ChatID; they always receive their own
// RefineChat).
type TripRefineChatSummary struct {
	MessageCount int       `json:"message_count"`
	Preview      string    `json:"preview"`
	UpdatedAt    time.Time `json:"updated_at"`
}

// TripRefineChatResponse is the full transcript (GET /trips/{id}/refine-chat).
// Messages reuse PlanChatMessage so display labels and the data-less image
// markers round-trip exactly as they do for /chats/{chatId}.
type TripRefineChatResponse struct {
	TripID       string            `json:"trip_id"`
	Summary      string            `json:"summary"`
	Messages     []PlanChatMessage `json:"messages"`
	MessageCount int               `json:"message_count"`
	UpdatedAt    time.Time         `json:"updated_at"`
}

// TripRefineChatClearedResponse states the post-state a DELETE leaves behind
// (docs/zen.md: a mutating result must state what the consumer will observe).
// RefineChat is always null; the field exists so this shape names the same
// thing TripResponse does.
type TripRefineChatClearedResponse struct {
	TripID     string                 `json:"trip_id"`
	RefineChat *TripRefineChatSummary `json:"refine_chat"`
}

// TripRefineChatHistoryEntry is one archived conversation, as listed in the
// "Previous chats" menu (#639). Carries an id — unlike TripRefineChatSummary
// — because a history entry IS individually addressable: it is how the
// traveler picks which past conversation to resume.
type TripRefineChatHistoryEntry struct {
	ID           string    `json:"id"`
	Preview      string    `json:"preview"`
	MessageCount int       `json:"message_count"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
}

// TripRefineChatHistoryResponse is GET /trips/{id}/refine-chat/history: up to
// tripRefineHistoryCap past conversations, most recently active first.
type TripRefineChatHistoryResponse struct {
	TripID string                       `json:"trip_id"`
	Chats  []TripRefineChatHistoryEntry `json:"chats"`
}

// saveTripRefineSession upserts the whole transcript for one trip's refine
// conversation. Best-effort by design, exactly like savePlanChatSession: a
// failure is logged and the turn proceeds.
//
// One case is expected rather than exceptional: a trip deleted between the
// pre-stream authorization check and this deferred save fails the trip_id
// foreign key. The turn is already over and its edits are already gone with the
// trip, so the log line is the whole response.
func saveTripRefineSession(ctx context.Context, uid, tripID uuid.UUID, summary string, msgs []PlanChatMessage) {
	if dbPool == nil || len(msgs) == 0 {
		return
	}
	payload, _, preview, err := planTranscriptFields(msgs)
	if err != nil {
		log.Printf("failed to marshal refine session for trip %s: %v", tripID, err)
		return
	}
	if err := store.New(dbPool).UpsertTripRefineSession(ctx, store.UpsertTripRefineSessionParams{
		UserID:       uid,
		TripID:       tripID,
		Preview:      preview,
		Summary:      summary,
		Messages:     payload,
		MessageCount: int32(len(msgs)),
	}); err != nil {
		log.Printf("failed to persist refine session for trip %s: %v", tripID, err)
	}
}

// tripRefineChatSummary reads presence + freshness for one caller and trip.
// Returns nil when there is no conversation — an absence, not an error.
func tripRefineChatSummary(ctx context.Context, q *store.Queries, uid, tripID uuid.UUID) (*TripRefineChatSummary, error) {
	row, err := q.GetTripRefineSessionSummary(ctx, store.GetTripRefineSessionSummaryParams{
		UserID: uid, TripID: tripID,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &TripRefineChatSummary{
		MessageCount: int(row.MessageCount),
		Preview:      row.Preview,
		UpdatedAt:    row.UpdatedAt,
	}, nil
}

// getTripRefineChatHandler is GET /trips/{id}/refine-chat: the caller's own
// saved conversation about this trip, in full.
//
// editableTrip, not viewableTrip: only someone who may edit a trip can hold a
// refine conversation about it, so a downgraded or removed collaborator gets
// the same 404 as a stranger with no extra check. "No conversation", "no trip"
// and "not yours" are deliberately one answer.
func getTripRefineChatHandler(w http.ResponseWriter, r *http.Request) {
	user, _ := userFromContext(r.Context())
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	row, err := store.New(dbPool).GetTripRefineSession(r.Context(),
		store.GetTripRefineSessionParams{UserID: user.ID, TripID: trip.ID})
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "conversation not found")
		return
	}
	var msgs []PlanChatMessage
	if err := json.Unmarshal(row.Messages, &msgs); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load the conversation")
		return
	}
	writeJSON(w, http.StatusOK, TripRefineChatResponse{
		TripID:       trip.ID.String(),
		Summary:      row.Summary,
		Messages:     msgs,
		MessageCount: int(row.MessageCount),
		UpdatedAt:    row.UpdatedAt,
	})
}

// deleteTripRefineChatHandler is DELETE /trips/{id}/refine-chat — the "New
// chat" action.
//
// Since #639 this ARCHIVES the active conversation instead of deleting it: it
// becomes the newest entry in "Previous chats", and only the oldest archived
// conversation beyond tripRefineHistoryCap is actually removed. The response
// shape is unchanged — the caller only needs to know the trip no longer
// advertises a running conversation, which is exactly as true under archiving
// as it was under deletion.
//
// Deliberate divergence from its sibling DELETE /chats/{chatId}, which 404s
// when no row existed: this one answers 200 with the post-state whether or not
// there was a conversation. Clearing state the caller cannot observe beforehand
// must be idempotent — "New chat" tapped on a conversation that never completed
// a turn is not an error, and a client that retries after a dropped response
// must not see one either. (docs/zen.md: divergence gets a comment, a decision
// record in specs/trip-refine-memory/plan.md, and a test —
// TestDeleteTripRefineChatIsIdempotent.)
func deleteTripRefineChatHandler(w http.ResponseWriter, r *http.Request) {
	user, _ := userFromContext(r.Context())
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	q := store.New(dbPool)
	// ArchiveActiveTripRefineSession affecting 0 rows (no active conversation)
	// is exactly the case DeleteTripRefineSession's :execrows used to answer
	// with 0 too — idempotent either way, so pruning always still runs: a
	// retried "New chat" must not re-grow history past the cap.
	if _, err := q.ArchiveActiveTripRefineSession(r.Context(),
		store.ArchiveActiveTripRefineSessionParams{UserID: user.ID, TripID: trip.ID}); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not clear the conversation")
		return
	}
	if err := q.PruneTripRefineSessionHistory(r.Context(),
		store.PruneTripRefineSessionHistoryParams{UserID: user.ID, TripID: trip.ID}); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not clear the conversation")
		return
	}
	writeJSON(w, http.StatusOK, TripRefineChatClearedResponse{TripID: trip.ID.String()})
}

// getTripRefineChatHistoryHandler is GET /trips/{id}/refine-chat/history — the
// "Previous chats" menu (#639): the caller's own archived conversations about
// this trip, most recently active first.
func getTripRefineChatHistoryHandler(w http.ResponseWriter, r *http.Request) {
	user, _ := userFromContext(r.Context())
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	rows, err := store.New(dbPool).ListTripRefineSessionHistory(r.Context(),
		store.ListTripRefineSessionHistoryParams{UserID: user.ID, TripID: trip.ID})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load previous chats")
		return
	}
	out := make([]TripRefineChatHistoryEntry, 0, len(rows))
	for _, row := range rows {
		out = append(out, TripRefineChatHistoryEntry{
			ID:           row.ID.String(),
			Preview:      row.Preview,
			MessageCount: int(row.MessageCount),
			CreatedAt:    row.CreatedAt,
			UpdatedAt:    row.UpdatedAt,
		})
	}
	writeJSON(w, http.StatusOK, TripRefineChatHistoryResponse{
		TripID: trip.ID.String(),
		Chats:  out,
	})
}

// resumeTripRefineChatHistoryEntryHandler is
// POST /trips/{id}/refine-chat/history/{sessionId} — "bring up the previous
// conversation": makes one archived chat the active one again so the next
// turn appends to it, and hands back its full transcript exactly like GET
// /trips/{id}/refine-chat.
//
// The conversation it replaces does not vanish — it becomes the newest
// "Previous chats" entry in the same swap, so this can never grow the
// archived count past tripRefineHistoryCap and never needs to prune.
func resumeTripRefineChatHistoryEntryHandler(w http.ResponseWriter, r *http.Request) {
	user, _ := userFromContext(r.Context())
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	sessionID, err := uuid.Parse(mux.Vars(r)["sessionId"])
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "conversation not found")
		return
	}

	tx, err := dbPool.Begin(r.Context())
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not resume the conversation")
		return
	}
	defer tx.Rollback(r.Context())
	q := store.New(tx)

	// The row must exist, be archived, and belong to this (user, trip) BEFORE
	// anything is archived — a 404 here must leave today's active conversation
	// untouched.
	if _, err := q.GetTripRefineSessionHistoryEntry(r.Context(),
		store.GetTripRefineSessionHistoryEntryParams{ID: sessionID, UserID: user.ID, TripID: trip.ID}); err != nil {
		writeJSONError(w, http.StatusNotFound, "conversation not found")
		return
	}
	// Archive whatever is currently active first: the partial unique index on
	// (user_id, trip_id) WHERE is_active must never see two active rows for
	// this pair, even for the instant between two UPDATEs.
	if _, err := q.ArchiveActiveTripRefineSession(r.Context(),
		store.ArchiveActiveTripRefineSessionParams{UserID: user.ID, TripID: trip.ID}); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not resume the conversation")
		return
	}
	if n, err := q.ActivateTripRefineSessionHistoryEntry(r.Context(),
		store.ActivateTripRefineSessionHistoryEntryParams{ID: sessionID, UserID: user.ID, TripID: trip.ID}); err != nil || n == 0 {
		writeJSONError(w, http.StatusInternalServerError, "could not resume the conversation")
		return
	}
	row, err := q.GetTripRefineSession(r.Context(),
		store.GetTripRefineSessionParams{UserID: user.ID, TripID: trip.ID})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not resume the conversation")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not resume the conversation")
		return
	}
	var msgs []PlanChatMessage
	if err := json.Unmarshal(row.Messages, &msgs); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load the conversation")
		return
	}
	writeJSON(w, http.StatusOK, TripRefineChatResponse{
		TripID:       trip.ID.String(),
		Summary:      row.Summary,
		Messages:     msgs,
		MessageCount: int(row.MessageCount),
		UpdatedAt:    row.UpdatedAt,
	})
}
