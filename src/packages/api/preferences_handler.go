package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5"

	"travel-route-planner/store"
)

var allowedBudgets = map[string]bool{"budget": true, "mid": true, "luxury": true}
var allowedPaces = map[string]bool{"relaxed": true, "balanced": true, "packed": true}
var allowedWorkStyles = map[string]bool{"digital_nomad": true, "workation": true, "leisure_only": true}

// "none" is a real answer, not an absence: it says the traveler has been asked
// and keeps no routine, so the agent should stop volunteering gyms and runs.
// (It also happens to be the one choice field on this profile with a way back
// to "no" — see specs/active-profile on the shared clear-to-unknown wart.)
var allowedFitnessRoutines = map[string]bool{"gym": true, "running": true, "both": true, "none": true}

// How demanding an active outing should be. Orthogonal to pace, which is how
// MANY things happen in a day rather than how hard they are.
var allowedOutdoorIntensities = map[string]bool{"easy": true, "moderate": true, "challenging": true}

var allowedCompanions = map[string]bool{"solo": true, "partner": true, "friends": true, "family_with_kids": true, "varies": true}

// "varies" answers the same question as the other four, but about all of them
// at once, so it cannot sit beside them: "solo AND it varies" states and
// unstates a fact in one breath, and the planning brief would tailor to both.
// It is the LAST word rather than an error — a traveler adding it is saying
// their earlier picks no longer hold, and rejecting the save would strand them
// on a selection they had already abandoned.
const companionsVaries = "varies"

type PreferencesResponse struct {
	Budget           *string  `json:"budget"`
	Pace             *string  `json:"pace"`
	Interests        []string `json:"interests"`
	HomeAirport      *string  `json:"home_airport"`
	ProfileNotes     *string  `json:"profile_notes"`
	WorkStyle        *string  `json:"work_style"`
	FitnessRoutine   *string  `json:"fitness_routine"`
	OutdoorIntensity *string  `json:"outdoor_intensity"`
	Companions       []string `json:"companions"`
	Baggage          *string  `json:"baggage"`
}

type PutPreferencesRequest struct {
	Budget *string `json:"budget"`
	Pace   *string `json:"pace"`
	// Pointer distinguishes omitted (nil -> keep) from cleared ([] -> clear).
	Interests   *[]string `json:"interests"`
	HomeAirport *string   `json:"home_airport"`
	// Pointer distinguishes omitted (nil -> keep) from cleared ("" -> clear).
	ProfileNotes     *string `json:"profile_notes"`
	WorkStyle        *string `json:"work_style"`
	FitnessRoutine   *string `json:"fitness_routine"`
	OutdoorIntensity *string `json:"outdoor_intensity"`
	// Pointer for the same reason as Interests: nil -> keep, [] -> clear.
	Companions *[]string `json:"companions"`
	Baggage    *string   `json:"baggage"`
}

func toPreferencesResponse(p store.TravelerPreference) PreferencesResponse {
	interests := p.Interests
	if interests == nil {
		interests = []string{}
	}
	// Same non-nil guarantee as interests: clients decode this into a list and
	// should never have to spell "absent" and "empty" differently.
	companions := p.Companions
	if companions == nil {
		companions = []string{}
	}
	return PreferencesResponse{
		Budget:           p.Budget,
		Pace:             p.Pace,
		Interests:        interests,
		HomeAirport:      p.HomeAirport,
		ProfileNotes:     p.ProfileNotes,
		WorkStyle:        p.WorkStyle,
		FitnessRoutine:   p.FitnessRoutine,
		OutdoorIntensity: p.OutdoorIntensity,
		Companions:       companions,
		Baggage:          p.Baggage,
	}
}

func getPreferencesHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	user, _ := userFromContext(r.Context())
	p, err := store.New(dbPool).GetPreferences(r.Context(), user.ID)
	if errors.Is(err, pgx.ErrNoRows) {
		// Both list fields spelled out: a profile that does not exist yet has
		// to answer with the same SHAPE as one that does, or a client decoding
		// [] everywhere else meets a null on the very first load.
		writeJSON(w, http.StatusOK, PreferencesResponse{
			Interests: []string{}, Companions: []string{},
		})
		return
	}
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load preferences")
		return
	}
	writeJSON(w, http.StatusOK, toPreferencesResponse(p))
}

func putPreferencesHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	user, _ := userFromContext(r.Context())

	var req PutPreferencesRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}

	budget, err := normalizeChoice(req.Budget, allowedBudgets, "budget")
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	pace, err := normalizeChoice(req.Pace, allowedPaces, "pace")
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	workStyle, err := normalizeChoice(req.WorkStyle, allowedWorkStyles, "work_style")
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	fitnessRoutine, err := normalizeChoice(req.FitnessRoutine, allowedFitnessRoutines, "fitness_routine")
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	outdoorIntensity, err := normalizeChoice(req.OutdoorIntensity, allowedOutdoorIntensities, "outdoor_intensity")
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	// nil companions -> leave unchanged; provided (incl. empty) -> set/clear.
	var companionsArg interface{}
	if req.Companions != nil {
		list, err := normalizeCompanions(*req.Companions)
		if err != nil {
			writeJSONError(w, http.StatusBadRequest, err.Error())
			return
		}
		companionsArg = list
	}
	// Same vocabulary as the flight-search tier (duffel_service.go) on purpose:
	// this preference IS the default for that field, and two spellings of one
	// enum would drift (docs/zen.md).
	baggage, err := normalizeChoice(req.Baggage, allowedBaggageTiers, "baggage")
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}

	homeAirport, clearHomeAirport, err := normalizeAirportCode(req.HomeAirport)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}

	// nil interests -> leave unchanged; provided (incl. empty) -> set/clear.
	var interestsArg interface{}
	if req.Interests != nil {
		interestsArg = normalizeInterests(*req.Interests)
	}

	p, err := store.New(dbPool).UpsertPreferences(r.Context(), store.UpsertPreferencesParams{
		UserID:           user.ID,
		Budget:           budget,
		Pace:             pace,
		Interests:        interestsArg,
		HomeAirport:      homeAirport,
		ClearHomeAirport: clearHomeAirport,
		ProfileNotes:     normalizeNotes(req.ProfileNotes),
		WorkStyle:        workStyle,
		FitnessRoutine:   fitnessRoutine,
		OutdoorIntensity: outdoorIntensity,
		Companions:       companionsArg,
		Baggage:          baggage,
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not save preferences")
		return
	}
	writeJSON(w, http.StatusOK, toPreferencesResponse(p))
}

// normalizeChoice lowercases/trims a choice field. Empty -> nil (omit, keep
// existing); an unrecognized value -> error.
func normalizeChoice(v *string, allowed map[string]bool, field string) (*string, error) {
	if v == nil {
		return nil, nil
	}
	s := strings.ToLower(strings.TrimSpace(*v))
	if s == "" {
		return nil, nil
	}
	if !allowed[s] {
		return nil, errors.New(field + " is not a recognized value")
	}
	return &s, nil
}

// normalizeAirportCode validates and upper-cases a home airport, and reports
// the three request shapes separately rather than folding two of them together:
//
//	nil        -> (nil, false, nil)  omitted: keep whatever is stored
//	"" / "  "  -> (nil, true,  nil)  explicit clear: write NULL
//	"bos"      -> ("BOS", false, nil)
//	anything else                    -> error
//
// The empty case used to collapse into the omitted case, which made a home
// airport impossible to remove: the upsert COALESCEs a nil back to the existing
// value, so clearing the field returned 200 with the old code still stored. The
// clear bool is what UpsertPreferences.ClearHomeAirport consumes. Mirrors the
// omitted-vs-cleared split already documented on PutPreferencesRequest's
// Interests and ProfileNotes.
func normalizeAirportCode(v *string) (value *string, clear bool, err error) {
	if v == nil {
		return nil, false, nil
	}
	s := strings.ToUpper(strings.TrimSpace(*v))
	if s == "" {
		return nil, true, nil
	}
	if len(s) != 3 || !isAlpha(s) {
		return nil, false, errors.New("home_airport must be a 3-letter IATA code")
	}
	return &s, false, nil
}

const maxProfileNotesLen = 2000

// normalizeNotes trims and caps the AI-maintained profile notes. nil -> nil
// (omit, keep existing); a provided value — including "" — replaces, so the
// user can clear notes. Truncation counts runes to avoid splitting characters.
func normalizeNotes(v *string) *string {
	if v == nil {
		return nil
	}
	s := strings.TrimSpace(*v)
	if r := []rune(s); len(r) > maxProfileNotesLen {
		s = string(r[:maxProfileNotesLen])
	}
	return &s
}

// normalizeInterests trims, drops blanks, and de-duplicates (case-insensitive,
// order-preserving). Always returns a non-nil slice so an empty input clears.
// normalizeCompanions validates a companions list: lowercased, trimmed, blanks
// dropped, deduped, order preserved. An unrecognized value is an error rather
// than a silent drop — this is a closed vocabulary, unlike interests, and a
// typo that vanished would look saved.
//
// "varies" wins alone (see [companionsVaries]): if it is present, it is the
// whole answer.
func normalizeCompanions(in []string) ([]string, error) {
	seen := map[string]bool{}
	out := []string{}
	for _, s := range in {
		v := strings.ToLower(strings.TrimSpace(s))
		if v == "" {
			continue
		}
		if !allowedCompanions[v] {
			return nil, errors.New("companions is not a recognized value")
		}
		if seen[v] {
			continue
		}
		seen[v] = true
		out = append(out, v)
	}
	if seen[companionsVaries] {
		return []string{companionsVaries}, nil
	}
	return out, nil
}

func normalizeInterests(in []string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, s := range in {
		t := strings.TrimSpace(s)
		if t == "" {
			continue
		}
		key := strings.ToLower(t)
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, t)
	}
	return out
}
