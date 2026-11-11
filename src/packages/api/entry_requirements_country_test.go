package main

import (
	"net/http"
	"strings"
	"testing"

	"travel-route-planner/store"
)

// specs/entry-requirements (00081/#686): storage only for the traveler's
// passport and residence country, so later provider work has something to
// read. Nullable, no default nationality — "not stated" is a first-class
// state, same shape as home_airport before it (unlike gender, these have no
// clear path yet: an omitted field keeps whatever is stored, matching
// budget/pace/work_style).

func TestPreferencesPassportResidenceCountryRoundTrip(t *testing.T) {
	resetDB(t)
	_, token := createTestUser(t, "entry-reqs@example.com")

	if rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{
		"passport_country": "us", "residence_country": "de",
	}); rec.Code != http.StatusOK {
		t.Fatalf("set = %d: %s", rec.Code, rec.Body.String())
	}
	got := getPrefs(t, token)
	if got["passport_country"] != "US" {
		t.Fatalf("passport_country after set = %v", got["passport_country"])
	}
	if got["residence_country"] != "DE" {
		t.Fatalf("residence_country after set = %v", got["residence_country"])
	}

	// Omitting a field in the PUT body leaves the stored value untouched —
	// the COALESCE contract both columns share with every other field here.
	if rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{"pace": "relaxed"}); rec.Code != http.StatusOK {
		t.Fatalf("unrelated save = %d", rec.Code)
	}
	got = getPrefs(t, token)
	if got["passport_country"] != "US" || got["residence_country"] != "DE" {
		t.Fatalf("country fields after unrelated save = %v / %v, want kept", got["passport_country"], got["residence_country"])
	}
}

func TestPreferencesPassportResidenceCountryDefaultsToNull(t *testing.T) {
	resetDB(t)
	_, token := createTestUser(t, "entry-reqs-null@example.com")

	got := getPrefs(t, token)
	if got["passport_country"] != nil {
		t.Fatalf("passport_country default = %v, want null (no default nationality)", got["passport_country"])
	}
	if got["residence_country"] != nil {
		t.Fatalf("residence_country default = %v, want null", got["residence_country"])
	}
}

func TestPreferencesPassportResidenceCountryRejectsInvalidShape(t *testing.T) {
	resetDB(t)
	_, token := createTestUser(t, "entry-reqs-bad@example.com")

	for field, bad := range map[string]string{
		"passport_country":  "USA",
		"residence_country": "1",
	} {
		rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{field: bad})
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("%s=%q = %d, want 400: %s", field, bad, rec.Code, rec.Body.String())
		}
	}
	got := getPrefs(t, token)
	if got["passport_country"] != nil || got["residence_country"] != nil {
		t.Fatalf("a rejected value wrote %v / %v", got["passport_country"], got["residence_country"])
	}
}

func TestSavePreferencesToolPassportResidenceCountry(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "entry-reqs-tool@example.com")

	s, _ := testPlanSession(true, user.ID)
	if msg, isErr := runSavePreferencesTool(s, []byte(`{"passport_country":"ca","residence_country":"mx"}`)); isErr {
		t.Fatalf("tool set errored: %s", msg)
	}
	got := getPrefs(t, token)
	if got["passport_country"] != "CA" || got["residence_country"] != "MX" {
		t.Fatalf("country fields after tool set = %v / %v", got["passport_country"], got["residence_country"])
	}

	// A rejected field is reported, not silently stored — the save itself
	// still succeeds (isErr stays false; see the rejected-fields channel in
	// runSavePreferencesTool).
	if msg, isErr := runSavePreferencesTool(s, []byte(`{"passport_country":"usa"}`)); isErr {
		t.Fatalf("tool call errored outright: %s", msg)
	} else if !strings.Contains(msg, "passport_country") {
		t.Fatalf("tool result missing the rejected field name: %s", msg)
	}
	got = getPrefs(t, token)
	if got["passport_country"] != "CA" {
		t.Fatalf("a rejected tool value overwrote passport_country: %v", got["passport_country"])
	}
}

// Storage only: listed in the personalization block for awareness, but no
// advice note is attached yet (that lands with the provider work).
func TestPersonalizedPromptCarriesStatedPassportResidenceCountry(t *testing.T) {
	us, de := "US", "DE"
	withPrefs := personalizedSystemPrompt("BASE", &store.TravelerPreference{PassportCountry: &us, ResidenceCountry: &de})
	if !strings.Contains(withPrefs, "passport country: US") {
		t.Fatalf("stated passport country missing from personalization:\n%s", withPrefs)
	}
	if !strings.Contains(withPrefs, "residence country: DE") {
		t.Fatalf("stated residence country missing from personalization:\n%s", withPrefs)
	}
	without := personalizedSystemPrompt("BASE", &store.TravelerPreference{})
	if strings.Contains(without, "passport country") || strings.Contains(without, "residence country") {
		t.Fatalf("unset country fields must not appear:\n%s", without)
	}
}
