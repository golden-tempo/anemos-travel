package main

import (
	"strconv"
	"strings"
	"testing"
)

func strPtr(s string) *string { return &s }

func TestNormalizeNotes(t *testing.T) {
	long := strings.Repeat("a", maxProfileNotesLen+50)
	// Multibyte runes: truncation must count runes, not bytes.
	multibyte := strings.Repeat("é", maxProfileNotesLen+1)

	tests := []struct {
		name string
		in   *string
		want *string
	}{
		{"nil keeps existing", nil, nil},
		{"empty clears", strPtr(""), strPtr("")},
		{"whitespace-only clears", strPtr("  \n\t "), strPtr("")},
		{"trims surrounding whitespace", strPtr("  - likes food\n"), strPtr("- likes food")},
		{"under cap unchanged", strPtr("- vegetarian"), strPtr("- vegetarian")},
		{"over cap truncated", strPtr(long), strPtr(long[:maxProfileNotesLen])},
		{"multibyte truncated at rune boundary", strPtr(multibyte), strPtr(strings.Repeat("é", maxProfileNotesLen))},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := normalizeNotes(tt.in)
			if (got == nil) != (tt.want == nil) {
				t.Fatalf("normalizeNotes() = %v, want %v", got, tt.want)
			}
			if got != nil && *got != *tt.want {
				t.Fatalf("normalizeNotes() = %q (len %d), want %q (len %d)", *got, len(*got), *tt.want, len(*tt.want))
			}
		})
	}
}

func TestNormalizeWorkStyle(t *testing.T) {
	for _, v := range []string{"digital_nomad", "workation", "leisure_only"} {
		got, err := normalizeChoice(strPtr(v), allowedWorkStyles, "work_style")
		if err != nil || got == nil || *got != v {
			t.Fatalf("normalizeChoice(%q) = %v, %v; want accepted", v, got, err)
		}
	}
	if _, err := normalizeChoice(strPtr("nomad"), allowedWorkStyles, "work_style"); err == nil {
		t.Fatal("normalizeChoice(\"nomad\") should be rejected")
	}
	if got, err := normalizeChoice(nil, allowedWorkStyles, "work_style"); got != nil || err != nil {
		t.Fatalf("normalizeChoice(nil) = %v, %v; want nil, nil (keep existing)", got, err)
	}
}

// specs/active-profile. Each field goes through the same normalizeChoice
// boundary as budget/pace/work_style, so these pin the value sets rather than
// the mechanism.
func TestNormalizeActiveProfileChoices(t *testing.T) {
	cases := []struct {
		field   string
		allowed map[string]bool
		valid   []string
		invalid string
	}{
		{"fitness_routine", allowedFitnessRoutines, []string{"gym", "running", "both", "none"}, "lifting"},
		{"outdoor_intensity", allowedOutdoorIntensities, []string{"easy", "moderate", "challenging"}, "extreme"},
		// companions left this table at 00073 — it is a list now, with its own
		// normalizer and its own rules. See TestNormalizeCompanions.
		// Shares its vocabulary with the flight-search tier (duffel_service.go)
		// because it IS that field's default — two spellings would drift.
		{"baggage", allowedBaggageTiers, []string{"personal_item", "carry_on", "checked"}, "carryon"},
	}
	for _, c := range cases {
		t.Run(c.field, func(t *testing.T) {
			for _, v := range c.valid {
				got, err := normalizeChoice(strPtr(v), c.allowed, c.field)
				if err != nil || got == nil || *got != v {
					t.Fatalf("normalizeChoice(%q) = %v, %v; want accepted", v, got, err)
				}
			}
			if _, err := normalizeChoice(strPtr(c.invalid), c.allowed, c.field); err == nil {
				t.Fatalf("normalizeChoice(%q) should be rejected", c.invalid)
			}
			if got, err := normalizeChoice(nil, c.allowed, c.field); got != nil || err != nil {
				t.Fatalf("normalizeChoice(nil) = %v, %v; want nil, nil (keep existing)", got, err)
			}
			// Empty string means "omit", never "clear" — shared with every
			// other choice field on this profile.
			if got, err := normalizeChoice(strPtr(""), c.allowed, c.field); got != nil || err != nil {
				t.Fatalf("normalizeChoice(\"\") = %v, %v; want nil, nil", got, err)
			}
		})
	}
}

// companions is a LIST since 00073 — travel is often more than one shape, and
// a single choice forced anyone whose isn't to pick one and lose the rest.
func TestNormalizeCompanions(t *testing.T) {
	t.Run("keeps every selection, in order", func(t *testing.T) {
		got, err := normalizeCompanions([]string{"solo", "family_with_kids"})
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if len(got) != 2 || got[0] != "solo" || got[1] != "family_with_kids" {
			t.Fatalf("got %v, want [solo family_with_kids]", got)
		}
	})

	t.Run("trims, lowercases and dedupes", func(t *testing.T) {
		got, _ := normalizeCompanions([]string{" Solo ", "solo", "", "  ", "FRIENDS"})
		if len(got) != 2 || got[0] != "solo" || got[1] != "friends" {
			t.Fatalf("got %v, want [solo friends]", got)
		}
	})

	t.Run("varies swallows the rest — it answers for all of them", func(t *testing.T) {
		// "solo AND it varies" states and unstates a fact in one breath, and
		// the planning brief would tailor to both.
		got, _ := normalizeCompanions([]string{"solo", "varies", "friends"})
		if len(got) != 1 || got[0] != "varies" {
			t.Fatalf("got %v, want [varies]", got)
		}
	})

	t.Run("an unknown member rejects the whole list", func(t *testing.T) {
		// A closed vocabulary, unlike interests: a typo that vanished silently
		// would look saved. The pre-00063 spaced spelling is the live example.
		if _, err := normalizeCompanions([]string{"solo", "family with kids"}); err == nil {
			t.Fatal("spaced spelling should be rejected, not dropped")
		}
	})

	t.Run("empty clears rather than erroring", func(t *testing.T) {
		got, err := normalizeCompanions([]string{})
		if err != nil || got == nil || len(got) != 0 {
			t.Fatalf("got %v, %v; want an empty non-nil list", got, err)
		}
	})
}

// Home airport is the one field on this profile that CAN be emptied, so its
// normalizer has to report three request shapes, not two. Before the clear
// flag existed, "" collapsed into nil and the upsert COALESCEd nil back to the
// stored value — a traveler could set or replace a home airport but never
// remove one, and the attempt returned 200 with the old code still in the
// response. Untested until now.
func TestNormalizeAirportCode(t *testing.T) {
	t.Run("nil keeps existing", func(t *testing.T) {
		got, clear, err := normalizeAirportCode(nil)
		if got != nil || clear || err != nil {
			t.Fatalf("got %v, clear=%v, err=%v; want nil, false, nil", got, clear, err)
		}
	})

	// The distinction the whole change turns on: empty is a request, not an
	// omission.
	for _, empty := range []string{"", "   ", "\t"} {
		t.Run("empty clears "+strconv.Quote(empty), func(t *testing.T) {
			got, clear, err := normalizeAirportCode(strPtr(empty))
			if got != nil || !clear || err != nil {
				t.Fatalf("got %v, clear=%v, err=%v; want nil, true, nil", got, clear, err)
			}
		})
	}

	for _, in := range []string{"bos", "BOS", "  bos  ", "Bos"} {
		t.Run("accepts "+strconv.Quote(in), func(t *testing.T) {
			got, clear, err := normalizeAirportCode(strPtr(in))
			if err != nil || got == nil || *got != "BOS" || clear {
				t.Fatalf("got %v, clear=%v, err=%v; want BOS, false, nil", got, clear, err)
			}
		})
	}

	// A rejection must not read as a clear: answering (nil, true) here would
	// wipe a good home airport because the model spelled the city out.
	for _, bad := range []string{"Boston", "KBOS", "B", "BO", "B0S", "B S", "BÓS"} {
		t.Run("rejects "+strconv.Quote(bad), func(t *testing.T) {
			got, clear, err := normalizeAirportCode(strPtr(bad))
			if err == nil {
				t.Fatalf("normalizeAirportCode(%q) = %v; want an error", bad, got)
			}
			if clear {
				t.Fatalf("normalizeAirportCode(%q) set clear; a bad value must never empty the column", bad)
			}
		})
	}
}
