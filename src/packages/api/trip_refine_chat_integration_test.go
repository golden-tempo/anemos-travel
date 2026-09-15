package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"

	"github.com/google/uuid"
)

// Trip refine conversations (specs/trip-refine-memory): the /plan persistence
// hook for trip-bound turns, the /trips/{id}/refine-chat surface, and the
// boundary that keeps a refine transcript out of the freeform /chats world.

// refineRow reads the ACTIVE trip refine session straight from the table —
// what GetTripRefineSession itself would resume.
func refineRow(t *testing.T, userID, tripID uuid.UUID) (msgs []PlanChatMessage, preview, summary string, count int, found bool) {
	t.Helper()
	var raw []byte
	err := dbPool.QueryRow(context.Background(),
		`SELECT messages, preview, summary, message_count FROM trip_refine_sessions
		 WHERE user_id = $1 AND trip_id = $2 AND is_active`, userID, tripID).Scan(&raw, &preview, &summary, &count)
	if err != nil {
		return nil, "", "", 0, false
	}
	if err := json.Unmarshal(raw, &msgs); err != nil {
		t.Fatalf("stored refine messages unparseable: %v", err)
	}
	return msgs, preview, summary, count, true
}

// boundTurn drives one trip-bound /plan turn that rewrites the itinerary.
func boundTurn(t *testing.T, token, tripID, userText, reply string) {
	t.Helper()
	newFakeAnthropic(t, toolTurn("update_itinerary_section",
		`{"scope":"trip","items":[{"name":"Cafe","latitude":1,"longitude":2,"day":1}]}`),
		textTurn(reply))
	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		// A throwaway chat id, exactly as the panel sends one. The server must
		// ignore it for a bound turn.
		ChatID:   "chat-" + uuid.NewString(),
		TripID:   tripID,
		Messages: []PlanChatMessage{{Role: "user", Content: userText}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d: %s", rec.Code, rec.Body.String())
	}
}

// (a) A trip-bound turn is saved — under (user, trip), with both sides of the
// turn — and it is saved in trip_refine_sessions, not plan_chat_sessions.
func TestTripBoundPlanTurnPersistsRefineSession(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "refiner@example.com")
	trip := createTestTrip(t, user.ID, 2)

	boundTurn(t, token, trip.ID.String(), "make day 2 more relaxed", "Done — day 2 is lighter now.")

	msgs, preview, _, count, found := refineRow(t, user.ID, trip.ID)
	if !found {
		t.Fatal("no trip_refine_sessions row after a bound turn")
	}
	if count != 2 || len(msgs) != 2 {
		t.Fatalf("stored %d messages (count %d), want 2 — the user turn and the reply", len(msgs), count)
	}
	if msgs[0].Content != "make day 2 more relaxed" || msgs[1].Role != "assistant" {
		t.Fatalf("stored messages = %+v, want the user message then the assistant reply", msgs)
	}
	if preview != "Done — day 2 is lighter now." {
		t.Fatalf("preview = %q, want the last assistant message", preview)
	}

	var planRows int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM plan_chat_sessions`).Scan(&planRows); err != nil {
		t.Fatalf("count query: %v", err)
	}
	if planRows != 0 {
		t.Fatalf("plan_chat_sessions rows = %d, want 0 — a bound turn belongs in trip_refine_sessions", planRows)
	}
}

// (b) The append contract: more turns, including a fresh section seed, keep
// ONE row and grow it. This is what "one running (active) chat per trip"
// means in storage, and it is enforced by the partial UNIQUE index on
// (user_id, trip_id) WHERE is_active (00078) — the ARCHIVED rows a "New chat"
// leaves behind (TestNewChatArchivesInsteadOfDeleting) are a different,
// deliberately unbounded-by-this-constraint story.
func TestTripRefineSessionIsOneRowPerUserPerTrip(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "appender@example.com")
	trip := createTestTrip(t, user.ID, 2)

	boundTurn(t, token, trip.ID.String(), "first ask", "First answer.")

	// A second turn resends the whole transcript, as the client does, plus a
	// new section seed.
	newFakeAnthropic(t, textTurn("Second answer."))
	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID: "chat-" + uuid.NewString(),
		TripID: trip.ID.String(),
		Messages: []PlanChatMessage{
			{Role: "user", Content: "first ask"},
			{Role: "assistant", Content: "First answer."},
			{Role: "user", Content: "now Day 3", DisplayLabel: "Refining Day 3 — Rome"},
		},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("second /plan = %d: %s", rec.Code, rec.Body.String())
	}

	var rows int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM trip_refine_sessions`).Scan(&rows); err != nil {
		t.Fatalf("count query: %v", err)
	}
	if rows != 1 {
		t.Fatalf("trip_refine_sessions rows = %d, want 1 (upsert, not insert)", rows)
	}
	msgs, _, _, count, _ := refineRow(t, user.ID, trip.ID)
	if count != 4 {
		t.Fatalf("message_count = %d, want 4 — the conversation grows, it is not replaced", count)
	}
	if msgs[0].Content != "first ask" {
		t.Fatalf("first stored message = %q, want the original ask still there", msgs[0].Content)
	}
	if msgs[2].DisplayLabel != "Refining Day 3 — Rome" {
		t.Fatalf("seed label = %q, want it round-tripped", msgs[2].DisplayLabel)
	}
}

// (c) The structural boundary: a refine transcript has no chat id, so nothing
// in the freeform /chats world can name it. Without this, /plan/<chatId> would
// rehydrate it into the unbound Agent tab and silently drop the trip binding.
func TestTripRefineChatUnreachableAsPlanChat(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "unaddressable@example.com")
	trip := createTestTrip(t, user.ID, 2)

	newFakeAnthropic(t, textTurn("Sure."))
	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID:   "chat-panel-session",
		TripID:   trip.ID.String(),
		Messages: []PlanChatMessage{{Role: "user", Content: "tighten day 1"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d", rec.Code)
	}

	list := doJSON(t, "GET", "/api/v1/chats", token, nil)
	if list.Code != http.StatusOK {
		t.Fatalf("GET /chats = %d", list.Code)
	}
	var summaries []ChatSessionSummaryResponse
	if err := json.Unmarshal(list.Body.Bytes(), &summaries); err != nil {
		t.Fatalf("decode /chats: %v", err)
	}
	if len(summaries) != 0 {
		t.Fatalf("resumable list = %+v, want empty — a trip's chat lives on the trip", summaries)
	}
	if got := doJSON(t, "GET", "/api/v1/chats/chat-panel-session", token, nil); got.Code != http.StatusNotFound {
		t.Fatalf("GET /chats/chat-panel-session = %d, want 404", got.Code)
	}
	_, _, _, _, found := refineRow(t, user.ID, trip.ID)
	if !found {
		t.Fatal("the conversation should still exist — just not as a plan chat")
	}
}

// (d) GET /trips/{id} advertises the conversation with presence + freshness,
// and carries no identifier for it.
func TestGetTripIncludesRefineChatSummary(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "advertised@example.com")
	trip := createTestTrip(t, user.ID, 2)

	before := decode(t, doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), token, nil))
	if _, ok := before["refine_chat"]; ok {
		t.Fatalf("refine_chat present with no conversation: %v", before["refine_chat"])
	}

	boundTurn(t, token, trip.ID.String(), "swap the museum", "Swapped for a park.")

	body := decode(t, doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), token, nil))
	chat, ok := body["refine_chat"].(map[string]any)
	if !ok {
		t.Fatalf("refine_chat = %v, want an object", body["refine_chat"])
	}
	if chat["message_count"] != float64(2) {
		t.Fatalf("message_count = %v, want 2", chat["message_count"])
	}
	if chat["preview"] != "Swapped for a park." {
		t.Fatalf("preview = %v, want the last reply", chat["preview"])
	}
	if _, bad := chat["chat_id"]; bad {
		t.Fatal("refine_chat carries a chat_id — the absence of one is the whole boundary")
	}
	if _, bad := chat["id"]; bad {
		t.Fatal("refine_chat carries an id — it must not be addressable")
	}
}

// (e) The transcript endpoint, its access boundary, and the clear.
func TestTripRefineChatGetDeleteAndAccess(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "reader@example.com")
	_, strangerToken := createTestUser(t, "stranger@example.com")
	trip := createTestTrip(t, user.ID, 2)
	path := "/api/v1/trips/" + trip.ID.String() + "/refine-chat"

	if rec := doJSON(t, "GET", path, token, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("GET with no conversation = %d, want 404", rec.Code)
	}

	boundTurn(t, token, trip.ID.String(), "add a bakery", "Added Boulangerie X.")

	get := doJSON(t, "GET", path, token, nil)
	if get.Code != http.StatusOK {
		t.Fatalf("GET = %d: %s", get.Code, get.Body.String())
	}
	var detail TripRefineChatResponse
	if err := json.Unmarshal(get.Body.Bytes(), &detail); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if detail.TripID != trip.ID.String() || len(detail.Messages) != 2 {
		t.Fatalf("detail = %+v, want this trip and both messages", detail)
	}

	if rec := doJSON(t, "GET", path, strangerToken, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("stranger GET = %d, want 404", rec.Code)
	}
	if rec := doJSON(t, "DELETE", path, strangerToken, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("stranger DELETE = %d, want 404", rec.Code)
	}

	del := doJSON(t, "DELETE", path, token, nil)
	if del.Code != http.StatusOK {
		t.Fatalf("DELETE = %d: %s", del.Code, del.Body.String())
	}
	cleared := decode(t, del)
	if cleared["trip_id"] != trip.ID.String() {
		t.Fatalf("DELETE trip_id = %v, want the trip", cleared["trip_id"])
	}
	if v, ok := cleared["refine_chat"]; !ok || v != nil {
		t.Fatalf("DELETE refine_chat = %v (present=%v), want an explicit null post-state", v, ok)
	}
	if rec := doJSON(t, "GET", path, token, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("GET after DELETE = %d, want 404", rec.Code)
	}
	body := decode(t, doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), token, nil))
	if _, ok := body["refine_chat"]; ok {
		t.Fatal("the trip still advertises a conversation the traveler cleared")
	}
}

// (f) Clearing is idempotent: the traveler cannot know whether a row existed,
// so "New chat" on a conversation that never completed a turn is not an error.
// This is the documented divergence from DELETE /chats/{chatId}'s 404.
func TestDeleteTripRefineChatIsIdempotent(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "clearer@example.com")
	trip := createTestTrip(t, user.ID, 1)
	path := "/api/v1/trips/" + trip.ID.String() + "/refine-chat"

	for i, want := range []int{http.StatusOK, http.StatusOK} {
		if rec := doJSON(t, "DELETE", path, token, nil); rec.Code != want {
			t.Fatalf("DELETE #%d = %d, want %d — clearing nothing is not an error", i+1, rec.Code, want)
		}
	}
}

// (g) Owner and editor co-planner each keep their own conversation about the
// same trip, and neither can read the other's.
func TestTripRefineChatIsPerUser(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	_, editorToken := createTestUser(t, "editor@example.com")
	trip := createTestTrip(t, owner.ID, 2)
	shareToken := createShare(t, ownerToken, trip.ID.String(), "editor")
	if rec := joinShare(t, editorToken, shareToken); rec.Code >= 300 {
		t.Fatalf("join = %d: %s", rec.Code, rec.Body.String())
	}

	boundTurn(t, ownerToken, trip.ID.String(), "owner's ask", "Owner's answer.")
	boundTurn(t, editorToken, trip.ID.String(), "editor's ask", "Editor's answer.")

	var rows int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM trip_refine_sessions WHERE trip_id = $1`, trip.ID).Scan(&rows); err != nil {
		t.Fatalf("count query: %v", err)
	}
	if rows != 2 {
		t.Fatalf("rows for one trip = %d, want 2 — one conversation each", rows)
	}

	path := "/api/v1/trips/" + trip.ID.String() + "/refine-chat"
	ownerMsgs := decode(t, doJSON(t, "GET", path, ownerToken, nil))
	editorMsgs := decode(t, doJSON(t, "GET", path, editorToken, nil))
	if !strings.Contains(toJSONString(t, ownerMsgs), "owner's ask") ||
		strings.Contains(toJSONString(t, ownerMsgs), "editor's ask") {
		t.Fatalf("owner sees the wrong transcript: %v", ownerMsgs)
	}
	if !strings.Contains(toJSONString(t, editorMsgs), "editor's ask") ||
		strings.Contains(toJSONString(t, editorMsgs), "owner's ask") {
		t.Fatalf("editor sees the wrong transcript: %v", editorMsgs)
	}

	// The editor's trip view still withholds the owner's lineage chat_id while
	// carrying their own conversation.
	body := decode(t, doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), editorToken, nil))
	if _, leaked := body["chat_id"]; leaked {
		t.Fatal("editor received the owner's chat_id")
	}
	if _, ok := body["refine_chat"].(map[string]any); !ok {
		t.Fatalf("editor's refine_chat = %v, want their own conversation", body["refine_chat"])
	}
}

// (h) Retention is the trip: deleting it takes the conversations with it.
func TestTripRefineChatCascadesOnTripDelete(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "deleter@example.com")
	trip := createTestTrip(t, user.ID, 1)

	boundTurn(t, token, trip.ID.String(), "one more stop", "Added.")
	if _, _, _, _, found := refineRow(t, user.ID, trip.ID); !found {
		t.Fatal("no conversation to cascade")
	}

	if rec := doJSON(t, "DELETE", "/api/v1/trips/"+trip.ID.String(), token, nil); rec.Code >= 300 {
		t.Fatalf("DELETE trip = %d: %s", rec.Code, rec.Body.String())
	}
	var rows int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM trip_refine_sessions`).Scan(&rows); err != nil {
		t.Fatalf("count query: %v", err)
	}
	if rows != 0 {
		t.Fatalf("trip_refine_sessions rows = %d after the trip was deleted, want 0", rows)
	}
}

// (i) A revoked collaborator loses access to their conversation — but we do
// not destroy a person's own writing as a side effect of someone else's action.
func TestRevokedCollaboratorLosesAccessButKeepsTheirRow(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	editor, editorToken := createTestUser(t, "editor@example.com")
	trip := createTestTrip(t, owner.ID, 2)
	shareToken := createShare(t, ownerToken, trip.ID.String(), "editor")
	if rec := joinShare(t, editorToken, shareToken); rec.Code >= 300 {
		t.Fatalf("join = %d", rec.Code)
	}
	boundTurn(t, editorToken, trip.ID.String(), "editor's ask", "Editor's answer.")

	rec := doJSON(t, "DELETE",
		"/api/v1/trips/"+trip.ID.String()+"/collaborators/"+editor.ID.String(), ownerToken, nil)
	if rec.Code >= 300 {
		t.Fatalf("revoke = %d: %s", rec.Code, rec.Body.String())
	}

	path := "/api/v1/trips/" + trip.ID.String() + "/refine-chat"
	if got := doJSON(t, "GET", path, editorToken, nil); got.Code != http.StatusNotFound {
		t.Fatalf("revoked editor GET = %d, want 404", got.Code)
	}
	if _, _, _, _, found := refineRow(t, editor.ID, trip.ID); !found {
		t.Fatal("the revoked editor's own conversation was destroyed by someone else's action")
	}
}

// (j) The parity contract (docs/zen.md): the two transcript tables must store
// the same bytes for the same conversation, because they share one derivation
// (planTranscriptFields). If someone re-rolls either saver, this goes red.
func TestTranscriptFieldsParityAcrossTables(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "parity@example.com")
	trip := createTestTrip(t, user.ID, 1)

	transcript := []PlanChatMessage{
		{Role: "user", Content: "look at this", DisplayLabel: "Refining Day 1 — Rome",
			Images: []PlanImage{{MediaType: "image/png", Data: "QUJD"}}},
	}

	newFakeAnthropic(t, textTurn("Same answer."))
	doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID: "chat-free", Messages: transcript,
	})
	newFakeAnthropic(t, textTurn("Same answer."))
	doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID: "chat-throwaway", TripID: trip.ID.String(), Messages: transcript,
	})

	var planRaw, refineRaw []byte
	var planPreview, refinePreview string
	if err := dbPool.QueryRow(context.Background(),
		`SELECT messages, preview FROM plan_chat_sessions WHERE user_id = $1 AND chat_id = 'chat-free'`,
		user.ID).Scan(&planRaw, &planPreview); err != nil {
		t.Fatalf("plan chat row: %v", err)
	}
	if err := dbPool.QueryRow(context.Background(),
		`SELECT messages, preview FROM trip_refine_sessions WHERE user_id = $1 AND trip_id = $2`,
		user.ID, trip.ID).Scan(&refineRaw, &refinePreview); err != nil {
		t.Fatalf("refine row: %v", err)
	}
	if string(planRaw) != string(refineRaw) {
		t.Fatalf("stored transcripts diverged:\n plan   = %s\n refine = %s", planRaw, refineRaw)
	}
	if planPreview != refinePreview {
		t.Fatalf("previews diverged: plan = %q, refine = %q", planPreview, refinePreview)
	}
	if strings.Contains(string(refineRaw), "QUJD") {
		t.Fatal("image bytes reached the refine table")
	}
}

// (k) The freshness contract: a bound session is told its own earlier messages
// may be stale and to build writes from the CURRENT TRIP STATE block that is
// injected fresh each turn (the block itself is pinned by
// TestPlanBoundTurnCarriesCurrentTripState). Without this a resumed
// conversation reverts edits made since — including a co-planner's.
func TestBoundPromptSteersToCurrentTripState(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "fresh@example.com")
	trip := createTestTrip(t, user.ID, 2)

	fa := newFakeAnthropic(t, textTurn("ok"))
	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID:   "chat-bound-prompt",
		TripID:   trip.ID.String(),
		Messages: []PlanChatMessage{{Role: "user", Content: "tweak day 1"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d", rec.Code)
	}
	bodies := fa.requestBodies()
	if len(bodies) == 0 {
		t.Fatal("fake anthropic received no requests")
	}
	prompt := systemPromptFrom(t, bodies[0])
	for _, want := range []string{
		"may be resumed days later",
		"AS IT WAS",
		"CURRENT TRIP STATE block",
		"never from an earlier message",
		// #434's scope guard, pinned here after #442's integration restored it
		// by hand: a cross-section reorder must be scope 'trip'. A rewrite
		// replaces its section IN PLACE, so mixing another section's places
		// into a 'city' or 'day' call duplicates them instead of moving them.
		// Unpinned, a prompt restructure deletes this and the duplication bug
		// #434 fixed comes back silently.
		"is a whole-trip change",
		"would duplicate those places rather than move them",
	} {
		if !strings.Contains(prompt, want) {
			t.Errorf("bound prompt lost %q:\n%s", want, prompt)
		}
	}
}

// (l) get_trip with no arguments, in a bound session, means THIS trip. Before
// this it listed the caller's own trips — which for a co-planner never
// contained the trip being refined.
func TestGetTripToolReturnsBoundTripWithoutArgs(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	editor, editorToken := createTestUser(t, "editor@example.com")
	trip := createTestTrip(t, owner.ID, 2)
	// The collaborator has a trip of their own, which is what the old listing
	// would have answered with.
	createTestTrip(t, editor.ID, 1)
	shareToken := createShare(t, ownerToken, trip.ID.String(), "editor")
	if rec := joinShare(t, editorToken, shareToken); rec.Code >= 300 {
		t.Fatalf("join = %d", rec.Code)
	}

	out, isErr := runGetTripTool(context.Background(), true, owner.ID, &trip.ID, json.RawMessage(`{}`))
	if isErr {
		t.Fatalf("owner get_trip errored: %s", out)
	}
	if strings.Contains(out, "saved trips (") {
		t.Fatalf("owner got a listing in a bound session:\n%s", out)
	}
	if !strings.Contains(out, "Place 1") {
		t.Fatalf("owner get_trip did not return the bound trip's itinerary:\n%s", out)
	}

	out, isErr = runGetTripTool(context.Background(), true, editor.ID, &trip.ID, json.RawMessage(`{}`))
	if isErr {
		t.Fatalf("collaborator get_trip errored: %s", out)
	}
	if !strings.Contains(out, "Place 1") {
		t.Fatalf("collaborator get_trip did not return the trip being refined:\n%s", out)
	}
}

func toJSONString(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return string(b)
}

// --- Trip chat history (#639): "New chat" archives instead of destroying,
// up to tripRefineHistoryCap past conversations are kept per (user, trip),
// and any one of them can be brought back as the active conversation. ---

// historyRows lists the caller's archived conversations for one trip in the
// same shape GET /trips/{id}/refine-chat/history hands back.
func historyRows(t *testing.T, token, tripID string) []TripRefineChatHistoryEntry {
	t.Helper()
	rec := doJSON(t, "GET", "/api/v1/trips/"+tripID+"/refine-chat/history", token, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET history = %d: %s", rec.Code, rec.Body.String())
	}
	var body TripRefineChatHistoryResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode history: %v", err)
	}
	return body.Chats
}

// (m) "New chat" archives the running conversation rather than destroying
// it: it shows up in history, and the trip stops advertising it as active.
func TestNewChatArchivesInsteadOfDeleting(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "archiver@example.com")
	trip := createTestTrip(t, user.ID, 1)

	boundTurn(t, token, trip.ID.String(), "first conversation", "First reply.")

	del := doJSON(t, "DELETE", "/api/v1/trips/"+trip.ID.String()+"/refine-chat", token, nil)
	if del.Code != http.StatusOK {
		t.Fatalf("DELETE (new chat) = %d: %s", del.Code, del.Body.String())
	}

	// No longer active: gone from the row GetTripRefineSession would read,
	// and off the trip's advertised refine_chat.
	if _, _, _, _, found := refineRow(t, user.ID, trip.ID); found {
		t.Fatal("the archived conversation is still reported active")
	}
	body := decode(t, doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), token, nil))
	if _, ok := body["refine_chat"]; ok {
		t.Fatal("a trip with only an archived conversation should not advertise one")
	}

	// But it still exists — as history, not as a deleted row.
	var rows int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM trip_refine_sessions WHERE user_id = $1 AND trip_id = $2`,
		user.ID, trip.ID).Scan(&rows); err != nil {
		t.Fatalf("count query: %v", err)
	}
	if rows != 1 {
		t.Fatalf("trip_refine_sessions rows = %d, want 1 — archived, not deleted", rows)
	}

	history := historyRows(t, token, trip.ID.String())
	if len(history) != 1 {
		t.Fatalf("history = %+v, want the one archived conversation", history)
	}
	if history[0].Preview != "First reply." || history[0].MessageCount != 2 {
		t.Fatalf("history entry = %+v, want the archived transcript's own preview/count", history[0])
	}
	if history[0].ID == "" {
		t.Fatal("a history entry must carry an id — it is how the traveler picks it")
	}
}

// (n) The cap: a 6th "New chat" prunes the oldest archived conversation, so
// at most tripRefineHistoryCap (5) prior conversations are ever stored.
func TestNewChatPrunesHistoryPastTheCap(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "prune@example.com")
	trip := createTestTrip(t, user.ID, 1)

	for i := 0; i < tripRefineHistoryCap+1; i++ {
		boundTurn(t, token, trip.ID.String(),
			fmt.Sprintf("conversation %d", i), fmt.Sprintf("Reply %d.", i))
		del := doJSON(t, "DELETE", "/api/v1/trips/"+trip.ID.String()+"/refine-chat", token, nil)
		if del.Code != http.StatusOK {
			t.Fatalf("DELETE #%d = %d: %s", i, del.Code, del.Body.String())
		}
	}

	var rows int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM trip_refine_sessions WHERE user_id = $1 AND trip_id = $2`,
		user.ID, trip.ID).Scan(&rows); err != nil {
		t.Fatalf("count query: %v", err)
	}
	if rows != tripRefineHistoryCap {
		t.Fatalf("stored conversations = %d, want at most %d", rows, tripRefineHistoryCap)
	}

	history := historyRows(t, token, trip.ID.String())
	if len(history) != tripRefineHistoryCap {
		t.Fatalf("history length = %d, want %d", len(history), tripRefineHistoryCap)
	}
	// The oldest ("conversation 0") was pruned; the newest survived.
	previews := make([]string, len(history))
	for i, h := range history {
		previews[i] = h.Preview
	}
	if strings.Contains(strings.Join(previews, ","), "Reply 0.") {
		t.Fatalf("the oldest conversation should have been pruned: %v", previews)
	}
	last := fmt.Sprintf("Reply %d.", tripRefineHistoryCap)
	if previews[0] != last {
		t.Fatalf("newest history entry = %q, want the most recently archived one %q", previews[0], last)
	}
}

// (o) Resuming a previous chat makes it active again — the next turn appends
// to IT, not to the one it replaced — and the replaced one becomes the newest
// history entry instead of vanishing.
func TestResumePreviousChatSwapsActiveConversation(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "resumer@example.com")
	trip := createTestTrip(t, user.ID, 1)

	boundTurn(t, token, trip.ID.String(), "older ask", "Older reply.")
	if del := doJSON(t, "DELETE", "/api/v1/trips/"+trip.ID.String()+"/refine-chat", token, nil); del.Code != http.StatusOK {
		t.Fatalf("DELETE = %d", del.Code)
	}
	boundTurn(t, token, trip.ID.String(), "newer ask", "Newer reply.")

	history := historyRows(t, token, trip.ID.String())
	if len(history) != 1 || history[0].Preview != "Older reply." {
		t.Fatalf("history = %+v, want the older conversation only", history)
	}
	targetID := history[0].ID

	resumePath := "/api/v1/trips/" + trip.ID.String() + "/refine-chat/history/" + targetID
	resume := doJSON(t, "POST", resumePath, token, nil)
	if resume.Code != http.StatusOK {
		t.Fatalf("POST resume = %d: %s", resume.Code, resume.Body.String())
	}
	var detail TripRefineChatResponse
	if err := json.Unmarshal(resume.Body.Bytes(), &detail); err != nil {
		t.Fatalf("decode resume response: %v", err)
	}
	if len(detail.Messages) != 2 || detail.Messages[0].Content != "older ask" {
		t.Fatalf("resumed transcript = %+v, want the older conversation restored", detail.Messages)
	}

	// The active row is now the older conversation...
	msgs, preview, _, _, found := refineRow(t, user.ID, trip.ID)
	if !found || preview != "Older reply." || msgs[0].Content != "older ask" {
		t.Fatalf("active conversation after resume = %+v/%q, want the older one", msgs, preview)
	}
	// ...and the newer one it replaced is now history, not gone.
	history = historyRows(t, token, trip.ID.String())
	if len(history) != 1 || history[0].Preview != "Newer reply." {
		t.Fatalf("history after resume = %+v, want the replaced (newer) conversation", history)
	}

	// A further turn appends to the RESUMED (older) conversation.
	newFakeAnthropic(t, textTurn("Another reply."))
	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID: "chat-" + uuid.NewString(),
		TripID: trip.ID.String(),
		Messages: []PlanChatMessage{
			{Role: "user", Content: "older ask"},
			{Role: "assistant", Content: "Older reply."},
			{Role: "user", Content: "one more thing"},
		},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("follow-up /plan = %d: %s", rec.Code, rec.Body.String())
	}
	msgs, _, _, count, _ := refineRow(t, user.ID, trip.ID)
	if count != 4 || msgs[0].Content != "older ask" {
		t.Fatalf("follow-up landed on the wrong conversation: %+v (count %d)", msgs, count)
	}
}

// (p) Access and not-found boundaries on the history surface mirror
// editableTrip's existing rules: a stranger, a wrong id, and an id belonging
// to someone else's (or another trip's) conversation are all 404.
func TestTripRefineChatHistoryAccessAndNotFound(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "historyowner@example.com")
	_, strangerToken := createTestUser(t, "historystranger@example.com")
	trip := createTestTrip(t, user.ID, 1)

	boundTurn(t, token, trip.ID.String(), "ask", "Reply.")
	doJSON(t, "DELETE", "/api/v1/trips/"+trip.ID.String()+"/refine-chat", token, nil)
	history := historyRows(t, token, trip.ID.String())
	if len(history) != 1 {
		t.Fatalf("history = %+v, want one entry", history)
	}
	entryID := history[0].ID

	if rec := doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String()+"/refine-chat/history", strangerToken, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("stranger GET history = %d, want 404", rec.Code)
	}
	resumePath := "/api/v1/trips/" + trip.ID.String() + "/refine-chat/history/" + entryID
	if rec := doJSON(t, "POST", resumePath, strangerToken, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("stranger POST resume = %d, want 404", rec.Code)
	}
	badPath := "/api/v1/trips/" + trip.ID.String() + "/refine-chat/history/" + uuid.NewString()
	if rec := doJSON(t, "POST", badPath, token, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("resume of a nonexistent entry = %d, want 404", rec.Code)
	}

	// The conversation just archived above has no active counterpart right
	// now — confirming that, so a reader trusts the 404 checks above weren't
	// accidentally exercising a self-resume instead of the id/access checks
	// they claim to.
	if _, _, _, _, found := refineRow(t, user.ID, trip.ID); found {
		t.Fatal("expected no active conversation at this point in the test")
	}
}
