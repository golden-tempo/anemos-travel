package main

import (
	"net/http"
	"testing"
)

// specs/active-profile — the three fields added by migration 00063, driven
// through the real router so the whole chain (JSON tags -> normalizeChoice ->
// sqlc upsert -> response mapping) is exercised, not just the validators.

func TestPreferencesActiveProfileRoundTrip(t *testing.T) {
	resetDB(t)
	_, token := createTestUser(t, "active-profile@test.local")

	// Unset by default: the profile starts empty, not defaulted.
	got := decode(t, doJSON(t, "GET", "/api/v1/preferences", token, nil))
	for _, f := range []string{"fitness_routine", "outdoor_intensity"} {
		if got[f] != nil {
			t.Fatalf("new profile %s = %v, want null", f, got[f])
		}
	}
	// companions is a list since 00073, so "unset" is an empty array — the
	// same non-nil guarantee interests has, never null.
	if c, ok := got["companions"].([]any); !ok || len(c) != 0 {
		t.Fatalf("new profile companions = %v, want []", got["companions"])
	}

	rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{
		"interests":         []string{"hiking"},
		"fitness_routine":   "gym",
		"outdoor_intensity": "challenging",
		"companions":        []string{"solo", "family_with_kids"},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("PUT = %d: %s", rec.Code, rec.Body.String())
	}
	saved := decode(t, rec)
	if saved["fitness_routine"] != "gym" || saved["outdoor_intensity"] != "challenging" {
		t.Fatalf("PUT response = %v, want the scalars echoed back", saved)
	}
	if c := decodeStrings(t, saved["companions"]); len(c) != 2 || c[0] != "solo" || c[1] != "family_with_kids" {
		t.Fatalf("PUT companions = %v, want both shapes echoed back", saved["companions"])
	}

	// Persisted, not just echoed — and both members survive the round trip.
	got = decode(t, doJSON(t, "GET", "/api/v1/preferences", token, nil))
	if got["fitness_routine"] != "gym" || got["outdoor_intensity"] != "challenging" {
		t.Fatalf("GET after PUT = %v, want the scalars persisted", got)
	}
	if c := decodeStrings(t, got["companions"]); len(c) != 2 || c[0] != "solo" || c[1] != "family_with_kids" {
		t.Fatalf("GET companions = %v, want both shapes persisted", got["companions"])
	}

	// Partial update: an omitted field keeps its stored value (the merge
	// semantics every field on this profile shares).
	if rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{
		"interests":       []string{"hiking"},
		"fitness_routine": "running",
	}); rec.Code != http.StatusOK {
		t.Fatalf("partial PUT = %d: %s", rec.Code, rec.Body.String())
	}
	got = decode(t, doJSON(t, "GET", "/api/v1/preferences", token, nil))
	if got["fitness_routine"] != "running" {
		t.Fatalf("fitness_routine = %v, want the updated value", got["fitness_routine"])
	}
	if got["outdoor_intensity"] != "challenging" {
		t.Fatalf("omitted fields were not preserved: %v", got)
	}
	// An omitted LIST keeps its stored value too — the merge semantics have to
	// survive the type change, or a partial save would silently wipe it.
	if c := decodeStrings(t, got["companions"]); len(c) != 2 {
		t.Fatalf("omitted companions was not preserved: %v", got["companions"])
	}

	// "none" is a stored answer, distinct from unset.
	if rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{
		"interests": []string{"hiking"}, "fitness_routine": "none",
	}); rec.Code != http.StatusOK {
		t.Fatalf("PUT none = %d: %s", rec.Code, rec.Body.String())
	}
	got = decode(t, doJSON(t, "GET", "/api/v1/preferences", token, nil))
	if got["fitness_routine"] != "none" {
		t.Fatalf("fitness_routine = %v, want \"none\" stored", got["fitness_routine"])
	}

	// An explicit empty list CLEARS, where an omitted one keeps — the same
	// two-shape contract interests has, and the only way back to "not stated".
	if rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{
		"interests": []string{"hiking"}, "companions": []string{},
	}); rec.Code != http.StatusOK {
		t.Fatalf("PUT empty companions = %d: %s", rec.Code, rec.Body.String())
	}
	got = decode(t, doJSON(t, "GET", "/api/v1/preferences", token, nil))
	if c := decodeStrings(t, got["companions"]); len(c) != 0 {
		t.Fatalf("companions = %v, want cleared", got["companions"])
	}

	// "varies" is the whole answer when present: it says the same thing the
	// others do, about all of them at once.
	if rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{
		"interests": []string{"hiking"}, "companions": []string{"solo", "varies"},
	}); rec.Code != http.StatusOK {
		t.Fatalf("PUT varies = %d: %s", rec.Code, rec.Body.String())
	}
	got = decode(t, doJSON(t, "GET", "/api/v1/preferences", token, nil))
	if c := decodeStrings(t, got["companions"]); len(c) != 1 || c[0] != "varies" {
		t.Fatalf("companions = %v, want [varies] alone", got["companions"])
	}
}

// decodeStrings pulls a JSON string array out of a decoded response field.
func decodeStrings(t *testing.T, v any) []string {
	t.Helper()
	raw, ok := v.([]any)
	if !ok {
		t.Fatalf("field is not a JSON array: %#v", v)
	}
	out := make([]string, 0, len(raw))
	for _, e := range raw {
		s, ok := e.(string)
		if !ok {
			t.Fatalf("array member is not a string: %#v", e)
		}
		out = append(out, s)
	}
	return out
}

func TestPreferencesActiveProfileRejectsBadValues(t *testing.T) {
	resetDB(t)
	_, token := createTestUser(t, "active-profile-bad@test.local")

	bad := []map[string]any{
		{"fitness_routine": "lifting"},
		{"outdoor_intensity": "extreme"},
		// The pre-00063 spaced spelling, now inside a list: one bad member
		// rejects the whole save rather than being dropped into a partial
		// answer the caller would believe was stored.
		{"companions": []string{"solo", "family with kids"}},
	}
	for _, body := range bad {
		body["interests"] = []string{}
		rec := doJSON(t, "PUT", "/api/v1/preferences", token, body)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("PUT %v = %d, want 400: %s", body, rec.Code, rec.Body.String())
		}
	}
}
