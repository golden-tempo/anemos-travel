package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// The /plan terminal-frame contract: every stream the handler opens ends with
// exactly one turn_end frame stating how the turn ended, so the client can
// tell "the model finished" from "the connection died" — the ambiguity that
// used to commit (and persist) a half-streamed reply as a finished message.

// planEventsAssertTerminal parses the stream and asserts the turn_end contract:
// stream_start announces the protocol before any content, and the LAST event
// is a single turn_end with the given stop_reason.
func planEventsAssertTerminal(t *testing.T, body, stopReason string) []map[string]any {
	t.Helper()
	events := planEvents(t, body)
	if len(events) == 0 {
		t.Fatalf("stream carried no events: %q", body)
	}
	if events[0]["type"] != "stream_start" {
		t.Fatalf("first event = %v, want stream_start (the protocol announcement)", events[0])
	}
	if ends := eventsOfType(events, "turn_end"); len(ends) != 1 {
		t.Fatalf("turn_end events = %d, want exactly one", len(ends))
	}
	assertLastEventIsTurnEnd(t, body, stopReason)
	return events
}

// resetAnonPlanCap gives direct-handler tests headroom on the in-memory
// anonymous /plan counter (httptest requests share one RemoteAddr, so without
// this a run's earlier direct tests could exhaust the default per-IP cap).
func resetAnonPlanCap(t *testing.T) {
	t.Helper()
	anonPlanCounter.resetAll()
	t.Setenv("FREE_ANON_PLAN_PER_DAY", "100")
}

// swapPlanDrain replaces the process-wide drain signal for one test, so
// beginning a drain here cannot poison every later /plan test in the package
// (the real planDrainCtx, once canceled, stays canceled for process life).
func swapPlanDrain(t *testing.T) (begin func()) {
	t.Helper()
	oldCtx, oldBegin := planDrainCtx, planDrainBegin
	planDrainCtx, planDrainBegin = context.WithCancel(context.Background())
	t.Cleanup(func() { planDrainCtx, planDrainBegin = oldCtx, oldBegin })
	return planDrainBegin
}

// (a) The success path: a plain text turn ends with turn_end "end_turn" as the
// stream's final event — the frame that authorizes the client to commit.
func TestPlanSuccessStreamEndsWithTurnEnd(t *testing.T) {
	resetAnonPlanCap(t)
	newFakeAnthropic(t, textTurn("Lisbon in May sounds perfect."))

	rec := runPlanHandler(t, PlanRequest{
		Messages: []PlanChatMessage{{Role: "user", Content: "where in May?"}},
	})
	events := planEventsAssertTerminal(t, rec.Body.String(), "end_turn")
	if got := joinedText(events); got != "Lisbon in May sounds perfect." {
		t.Fatalf("reassembled text = %q", got)
	}
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}
}

// (b) A mid-turn model failure: the error frame is followed by turn_end
// "error" — an error always ends the turn, and the terminal frame rides with
// it on every exit path, not just validation rejects.
func TestPlanMidTurnModelErrorEndsWithTurnEnd(t *testing.T) {
	resetAnonPlanCap(t)
	resetAIHealth(t)
	newFakeAnthropic(t, errorTurn("overloaded"))

	rec := runPlanHandler(t, PlanRequest{
		Messages: []PlanChatMessage{{Role: "user", Content: "plan athens"}},
	})
	events := planEventsAssertTerminal(t, rec.Body.String(), "error")
	if errs := eventsOfType(events, "error"); len(errs) != 1 {
		t.Fatalf("error events = %d, want exactly one", len(errs))
	}
}

// (c) The graceful-shutdown drain: a stream parked mid-model-call is unwound
// when the drain begins and ends with turn_end "server_restart" — the reason
// the client discards the half-reply and offers a clean retry — with no error
// frame (the client localizes the copy from the stop_reason alone).
func TestPlanDrainEmitsServerRestartTurnEnd(t *testing.T) {
	resetAnonPlanCap(t)
	resetAIHealth(t)
	begin := swapPlanDrain(t)
	stalled := make(chan struct{})
	newFakeAnthropic(t, stallTurn("Half an answer that a deploy cuts", stalled))

	body, err := json.Marshal(PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "plan me a weekend in Athens"},
	}})
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/api/v1/plan", bytes.NewReader(body))

	done := make(chan struct{})
	go func() {
		defer close(done)
		planHandler(rec, req)
	}()

	// Deltas are on the wire and the model call is parked — begin the drain,
	// exactly what startServer's signal handler does on SIGTERM.
	<-stalled
	begin()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("planHandler did not return after drain began")
	}

	out := rec.Body.String()
	events := planEventsAssertTerminal(t, out, "server_restart")
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("stream = %q, want no error frame on a drain (turn_end carries the reason)", out)
	}
	// A drained turn is not an AI failure: the health tracker stays untouched,
	// same as a client abort.
	if s := aiHealth.state(); s.Failing || s.FatalTotal != 0 || s.TransientTotal != 0 {
		t.Fatalf("tracker after drain = %+v, want untouched", s)
	}
}

// (d) Persistence agreement, drain side: the deferred end-of-turn save stores
// the transcript WITHOUT the half-streamed assistant text — the client
// discarded it, and a stored stump is what the next turn's model would read
// back as its own finished message.
func TestPlanDrainDoesNotPersistPartialText(t *testing.T) {
	resetDB(t)
	begin := swapPlanDrain(t)
	stalled := make(chan struct{})
	newFakeAnthropic(t, stallTurn("Half an answer that a deploy cuts", stalled))
	user, token := createTestUser(t, "drained@example.com")

	body, err := json.Marshal(PlanRequest{
		ChatID:   "chat-drained",
		Messages: []PlanChatMessage{{Role: "user", Content: "plan me a week in Japan"}},
	})
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/api/v1/plan", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)

	done := make(chan struct{})
	go func() {
		defer close(done)
		planHandler(rec, req)
	}()
	<-stalled
	begin()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("planHandler did not return after drain began")
	}
	planEventsAssertTerminal(t, rec.Body.String(), "server_restart")

	msgs, _, _, found := chatSessionRow(t, user.ID, "chat-drained")
	if !found {
		t.Fatal("session missing after drained turn (the start-of-turn save must still run)")
	}
	if len(msgs) != 1 || msgs[0].Role != "user" {
		t.Fatalf("stored messages = %+v, want ONLY the user message (no half-streamed assistant text)", msgs)
	}
}

// (e) Persistence agreement, client-abort side: a stopped/closed turn stores
// no assistant stump either. Before the terminal-frame work the deferred save
// appended it, so reloading after a stop resurrected half a reply the client
// had rolled back (specs/chat-stop-undo documents the client side).
func TestPlanClientAbortDoesNotPersistPartialText(t *testing.T) {
	resetDB(t)
	stalled := make(chan struct{})
	newFakeAnthropic(t, stallTurn("Half an answer the stop button cuts", stalled))
	user, token := createTestUser(t, "stopped@example.com")

	body, err := json.Marshal(PlanRequest{
		ChatID:   "chat-stopped",
		Messages: []PlanChatMessage{{Role: "user", Content: "plan me a week in Japan"}},
	})
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/api/v1/plan", bytes.NewReader(body)).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer "+token)

	done := make(chan struct{})
	go func() {
		defer close(done)
		planHandler(rec, req)
	}()
	<-stalled
	cancel()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("planHandler did not return after client abort")
	}

	msgs, _, _, found := chatSessionRow(t, user.ID, "chat-stopped")
	if !found {
		t.Fatal("session missing after aborted turn (the start-of-turn save must still run)")
	}
	if len(msgs) != 1 || msgs[0].Role != "user" {
		t.Fatalf("stored messages = %+v, want ONLY the user message (no half-streamed assistant text)", msgs)
	}
}

// (f) Persistence agreement, error side: an error-frame turn KEEPS the partial
// — the client's error case commits it to the visible transcript, and the two
// sides must store the same conversation.
func TestPlanModelErrorPersistsPartialText(t *testing.T) {
	resetDB(t)
	resetAIHealth(t)
	newFakeAnthropic(t, errorTurn("overloaded"))
	user, token := createTestUser(t, "errored@example.com")

	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID:   "chat-errored",
		Messages: []PlanChatMessage{{Role: "user", Content: "plan me a week in Japan"}},
	})
	planEventsAssertTerminal(t, rec.Body.String(), "error")

	msgs, _, _, found := chatSessionRow(t, user.ID, "chat-errored")
	if !found {
		t.Fatal("session missing after error turn")
	}
	// errorTurn streams "One moment" before dying (fake_anthropic_test.go).
	if len(msgs) != 2 || msgs[1].Role != "assistant" || !strings.Contains(msgs[1].Content, "One moment") {
		t.Fatalf("stored messages = %+v, want user + the partial assistant text", msgs)
	}
}
