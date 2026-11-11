# Spec: Entry Requirements

> **WHAT & WHY only.** No tech choices, file names, libraries, or code. If a
> sentence names a file or a package, it belongs in `plan.md`, not here.

## Context

Booking todos track what a traveler has *paid for*, but nothing tracks whether
they're *allowed in*. Visas, electronic authorizations (ESTA/ETA/ETIAS-class),
passport-validity windows, and onward-ticket rules are the highest-stakes
pre-trip task — miss one and the trip ends at the check-in desk. Every AI
travel planner tested in market research misses this category entirely, and
Anemos's differentiator is practical reliability ("degrade, never invent"). A
per-destination entry-requirement todo, derived automatically from the trip's
legs and the traveler's nationality, is cheap trust: it extends the existing
booking-todo surface users already know, and it covers a documented
competitor weakness with days of work, not weeks.

## User Stories

- As a **traveler planning a multi-country trip**, I want a per-destination
  entry-requirement todo to appear automatically alongside my booking todos so
  that I discover visa/authorization needs while there's still time to act.
- As a **traveler**, I want the todo to tell me *what* applies to me (visa
  required, e-visa, electronic authorization, visa-free with conditions) based
  on my nationality, so that I don't have to research generic rules that may
  not apply to my passport.
- As a **traveler**, I want the todo to carry lead-time guidance and a link to
  the official source so that I can act on it and verify it — I understand the
  app is not a legal authority.
- As a **traveler with dual nationality or non-US residence**, I want to set my
  passport country (and optionally residence) so the requirements shown are the
  right ones.
- As a **traveler transiting through a country**, I want transit-entry flags to
  be distinguishable from destination-entry requirements so I neither ignore
  them nor over-react to them.

## Acceptance Criteria

- [ ] A trip with legs in a foreign country shows an entry-requirement todo per
  destination country, positioned with (not buried below) the booking todos.
- [ ] The todo states the requirement class for the user's passport (visa
  required / e-visa / electronic travel authorization / visa-free / unknown)
  plus any conditions (max stay, passport-validity window, onward-ticket rule)
  when known.
- [ ] Each todo links to the official government source for verification, and
  the UI carries a "verify — not legal advice" disclaimer.
- [ ] When the requirement cannot be determined (unsupported country pair,
  provider failure, stale data), the todo still appears, marked as "verify
  entry requirements," with official links — the app never asserts a
  requirement it doesn't have data for.
- [ ] The user can set passport country and country of residence in profile;
  requirements reflect those. When unset, the todo prompts for nationality
  instead of guessing.
- [ ] Todos update when legs change (new destination country adds one; removing
  a country removes it) and dedupe correctly (three cities in Japan = one
  Japan todo).
- [ ] Marking the todo done/booked behaves like other booking todos (counts
  toward trip readiness, next-step logic).

## API Surface

### `GET /api/v1/entry-requirements`
- **Purpose:** fetch the entry requirement for a destination country given the
  traveler's passport country (and optionally residence).
- **Request:** destination country; passport country; optional residence
  country; optional purpose (tourism default).
- **Response:** requirement class, conditions text (max stay, passport
  validity, onward ticket), official-source URL, data provenance (source +
  retrieval date). When unknown: an explicit "unknown" status — never a
  fabricated class.
- **Errors:** provider failure or unsupported pair returns the explicit
  unknown/degraded state, not an error that blocks the todo from rendering.

### Profile fields (extension of the existing profile/preferences endpoints)
- **Purpose:** store passport country and country of residence.
- **Behavior:** optional; omitted means entry todos render in
  "set your nationality" prompt mode.

## Data Model

- **EntryRequirement** — one destination/passport pair lookup: requirement
  class, conditions, official-source URL, source name, retrieval date.
  Cacheable; requirements change slowly, so cached-with-provenance is
  acceptable, but staleness must be visible (show retrieval date).
- **Profile additions** — passport country; country of residence. Optional.
- **Entry todo** — a derived booking todo of a new kind keyed by destination
  country, sharing the existing todo lifecycle (open/done, claimed-by logic).

## UI Behavior

- **Surface:** the trip's existing todo list, plus a detail sheet on tap:
  requirement class, conditions, lead-time guidance, official-source link,
  retrieval date, disclaimer.
- **Happy path:** user adds a leg to a new country → entry todo appears → tap
  → detail sheet → act externally → mark done.
- **States:** unknown/degraded (still renders, clearly marked); nationality
  unset (prompt state); loading; provider error (renders as degraded, not
  broken).
- **Settings:** passport country and residence fields in profile; surfaced as
  a prompt from any entry todo when unset.

## Edge Cases & Error States

- Schengen and similar zones: requirement is per-zone, not per-country —
  three Schengen legs should not produce three independent max-stay clocks.
  (Minimum viable: one todo per country with zone wording in conditions; full
  90/180 tracking is out of scope.)
- Transit-only presence in a country (layover) — flag separately from
  destination entry; do not generate alarm for airside transits unless data
  says a transit visa is required.
- Dual nationals: user picks which passport the trip uses; default to the
  profile's passport country.
- Provider down / unsupported pair / stale cache: degrade to the generic
  "verify entry requirements" todo with official links. Never invent a class.
- Domestic legs: no todo.

## Out of Scope

- Visa application processing, form filling, or document upload.
- Schengen 90/180-day accumulation tracking across trips.
- Health/vaccination requirements and customs rules (a later spec, same
  pattern).
- Multi-passenger requirements (traveling party members' nationalities).
- Legal advice — the feature is a pointer with provenance, not an authority.
