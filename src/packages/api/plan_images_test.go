package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// Image attachments on /plan (specs/chat-image-attachments): request
// validation, conversion to Anthropic image content blocks (asserted on the
// fake's request bodies), and base64 stripping in the persisted transcript.

// tinyPNGBase64 is a valid-enough stand-in for image data; the handler never
// decodes it, so content is irrelevant — only shape and size are.
var tinyPNGBase64 = base64.StdEncoding.EncodeToString([]byte("png-bytes"))

func planImage() PlanImage {
	return PlanImage{MediaType: "image/png", Data: tinyPNGBase64}
}

// anthropicMessages parses the messages array of a captured /v1/messages
// request body into role + raw content-block list.
func anthropicMessages(t *testing.T, body []byte) []struct {
	Role    string            `json:"role"`
	Content []json.RawMessage `json:"content"`
} {
	t.Helper()
	var req struct {
		Messages []struct {
			Role    string            `json:"role"`
			Content []json.RawMessage `json:"content"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		t.Fatalf("unparseable fake-anthropic request body: %v", err)
	}
	return req.Messages
}

func blockType(t *testing.T, raw json.RawMessage) string {
	t.Helper()
	var b struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(raw, &b); err != nil {
		t.Fatalf("unparseable content block %s: %v", raw, err)
	}
	return b.Type
}

// (a) A user message with an image sends the image block BEFORE the text
// block, base64 source intact.
func TestPlanImageBlockPrecedesText(t *testing.T) {
	fa := newFakeAnthropic(t, textTurn("That looks like Lisbon."))

	rec := runPlanHandler(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "where is this?", Images: []PlanImage{planImage()}},
	}})
	if errs := eventsOfType(planEvents(t, rec.Body.String()), "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}

	bodies := fa.requestBodies()
	if len(bodies) != 1 {
		t.Fatalf("anthropic calls = %d, want 1", len(bodies))
	}
	msgs := anthropicMessages(t, bodies[0])
	if len(msgs) != 1 || msgs[0].Role != "user" {
		t.Fatalf("messages = %+v, want one user message", msgs)
	}
	if len(msgs[0].Content) != 2 {
		t.Fatalf("content blocks = %d, want image + text", len(msgs[0].Content))
	}
	if got := blockType(t, msgs[0].Content[0]); got != "image" {
		t.Fatalf("first block type = %q, want image (images precede text)", got)
	}
	if got := blockType(t, msgs[0].Content[1]); got != "text" {
		t.Fatalf("second block type = %q, want text", got)
	}
	var img struct {
		Source struct {
			Type      string `json:"type"`
			MediaType string `json:"media_type"`
			Data      string `json:"data"`
		} `json:"source"`
	}
	if err := json.Unmarshal(msgs[0].Content[0], &img); err != nil {
		t.Fatalf("unparseable image block: %v", err)
	}
	if img.Source.Type != "base64" || img.Source.MediaType != "image/png" || img.Source.Data != tinyPNGBase64 {
		t.Fatalf("image source = %+v, want base64 image/png with the sent data", img.Source)
	}
}

// (b) An image-only message (no text) sends a single image block and no empty
// text block — the API rejects empty text.
func TestPlanImageOnlyMessageOmitsTextBlock(t *testing.T) {
	fa := newFakeAnthropic(t, textTurn("A lovely beach."))

	rec := runPlanHandler(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "", Images: []PlanImage{planImage()}},
	}})
	if errs := eventsOfType(planEvents(t, rec.Body.String()), "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}

	msgs := anthropicMessages(t, fa.requestBodies()[0])
	if len(msgs[0].Content) != 1 {
		t.Fatalf("content blocks = %d, want just the image", len(msgs[0].Content))
	}
	if got := blockType(t, msgs[0].Content[0]); got != "image" {
		t.Fatalf("block type = %q, want image", got)
	}
}

// (c) Stripped resume placeholders (empty Data) are skipped — no image block,
// no media-type validation, the turn proceeds.
func TestPlanStrippedPlaceholderImageSkipped(t *testing.T) {
	fa := newFakeAnthropic(t, textTurn("Continuing where we left off."))

	rec := runPlanHandler(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "look at this", Images: []PlanImage{{MediaType: "image/png"}}},
		{Role: "assistant", Content: "Nice photo!"},
		{Role: "user", Content: "so where should I stay?"},
	}})
	if errs := eventsOfType(planEvents(t, rec.Body.String()), "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}

	msgs := anthropicMessages(t, fa.requestBodies()[0])
	if len(msgs) != 3 {
		t.Fatalf("messages = %d, want 3", len(msgs))
	}
	if len(msgs[0].Content) != 1 || blockType(t, msgs[0].Content[0]) != "text" {
		t.Fatalf("first message blocks = %v, want a single text block (placeholder image skipped)", msgs[0].Content)
	}
}

// (d) A resumed image-only message whose pixels were stripped would be empty —
// it gets the marker text instead, keeping the transcript API-valid.
func TestPlanStrippedImageOnlyMessageGetsMarker(t *testing.T) {
	fa := newFakeAnthropic(t, textTurn("Got it."))

	rec := runPlanHandler(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "", Images: []PlanImage{{MediaType: "image/jpeg"}}},
		{Role: "assistant", Content: "What a view!"},
		{Role: "user", Content: "plan me two days there"},
	}})
	if errs := eventsOfType(planEvents(t, rec.Body.String()), "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}

	msgs := anthropicMessages(t, fa.requestBodies()[0])
	if len(msgs[0].Content) != 1 || blockType(t, msgs[0].Content[0]) != "text" {
		t.Fatalf("first message blocks = %v, want a single marker text block", msgs[0].Content)
	}
	var txt struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(msgs[0].Content[0], &txt); err != nil {
		t.Fatalf("unparseable text block: %v", err)
	}
	if !strings.Contains(txt.Text, "no longer available") {
		t.Fatalf("marker text = %q, want the image-unavailable marker", txt.Text)
	}
}

// assertSingleFriendlyError asserts the handler wrote exactly one SSE error
// event containing want, and stopped there (no model call happened — the fake
// would fail the test on an unscripted turn). The reject stream is exactly
// stream_start + error + the terminal turn_end every stream must end with.
func assertSingleFriendlyError(t *testing.T, rec interface{ String() string }, want string) {
	t.Helper()
	out := rec.String()
	if !strings.Contains(out, `"type":"error"`) || !strings.Contains(out, want) {
		t.Fatalf("stream = %q, want an SSE error containing %q", out, want)
	}
	if strings.Count(out, "data: ") != 3 {
		t.Fatalf("stream = %q, want exactly stream_start + error + turn_end", out)
	}
	assertLastEventIsTurnEnd(t, out, "error")
}

func TestPlanRejectsImagesOnAssistantMessage(t *testing.T) {
	newFakeAnthropic(t) // no scripted turns: any model call fails the test
	rec := runPlanHandler(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "hi"},
		{Role: "assistant", Content: "hello", Images: []PlanImage{planImage()}},
	}})
	assertSingleFriendlyError(t, rec.Body, "your own messages")
}

func TestPlanRejectsTooManyImagesPerMessage(t *testing.T) {
	newFakeAnthropic(t)
	imgs := make([]PlanImage, planMaxImagesPerMessage+1)
	for i := range imgs {
		imgs[i] = planImage()
	}
	rec := runPlanHandler(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "hi", Images: imgs},
	}})
	assertSingleFriendlyError(t, rec.Body, "at most 4 images")
}

func TestPlanRejectsTooManyImagesPerRequest(t *testing.T) {
	newFakeAnthropic(t)
	var msgs []PlanChatMessage
	for images := 0; images <= planMaxImagesPerRequest; images += planMaxImagesPerMessage {
		msgs = append(msgs,
			PlanChatMessage{Role: "user", Content: "hi", Images: []PlanImage{
				planImage(), planImage(), planImage(), planImage(),
			}},
			PlanChatMessage{Role: "assistant", Content: "ok"})
	}
	rec := runPlanHandler(t, PlanRequest{Messages: msgs})
	assertSingleFriendlyError(t, rec.Body, "too many images")
}

func TestPlanRejectsUnsupportedImageMediaType(t *testing.T) {
	newFakeAnthropic(t)
	rec := runPlanHandler(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "hi", Images: []PlanImage{{MediaType: "image/bmp", Data: tinyPNGBase64}}},
	}})
	assertSingleFriendlyError(t, rec.Body, "isn't supported")
}

func TestPlanRejectsOversizedImage(t *testing.T) {
	newFakeAnthropic(t)
	rec := runPlanHandler(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "hi", Images: []PlanImage{
			{MediaType: "image/png", Data: strings.Repeat("A", planMaxImageBase64Len+1)},
		}},
	}})
	assertSingleFriendlyError(t, rec.Body, "too large")
}

// (e) Persisted transcripts keep each image's media type but never its data —
// the JSONB row must stay small under twice-per-turn wholesale upserts.
func TestChatSessionStripsImageData(t *testing.T) {
	resetDB(t)
	newFakeAnthropic(t, textTurn("Beautiful — that's the Algarve."))
	user, token := createTestUser(t, "image-chat@example.com")

	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID: "chat-with-image",
		Messages: []PlanChatMessage{
			{Role: "user", Content: "where is this beach?", Images: []PlanImage{planImage()}},
		},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}

	msgs, _, _, found := chatSessionRow(t, user.ID, "chat-with-image")
	if !found {
		t.Fatal("no chat session persisted")
	}
	if len(msgs) != 2 || len(msgs[0].Images) != 1 {
		t.Fatalf("persisted messages = %+v, want user message with one image marker", msgs)
	}
	img := msgs[0].Images[0]
	if img.Data != "" {
		t.Fatalf("persisted image data = %d bytes, want stripped to empty", len(img.Data))
	}
	if img.MediaType != "image/png" {
		t.Fatalf("persisted media type = %q, want image/png retained", img.MediaType)
	}
}
