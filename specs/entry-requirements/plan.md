# Plan: Entry Requirements

> **HOW.** Translates `spec.md` into a file-level technical approach. Every
> decision should trace back to an acceptance criterion. See `../../CLAUDE.md`
> for repo conventions referenced below — don't restate them, point to them.

## Technical Approach

Three pieces: (1) a server-side requirements lookup service with an external
data provider, cached with provenance; (2) two new optional profile fields
(passport country, residence country); (3) a new derived booking-todo kind in
the Flutter client, reusing the existing derivation, ordering, and
claimed-by machinery.

Key decisions:

- **External provider, never the model.** Visa rules from an LLM violate
  "degrade, never invent" — stale training data and confident fabrication are
  the exact failure this feature exists to counter. The model is not involved
  in classification at all.
- **Cache with visible provenance.** Requirements change slowly; cache per
  (passport, destination) pair with a retrieval timestamp, and render the
  date in the UI (acceptance: staleness visible). Suggested TTL 30 days.
- **Degrade to a generic todo, never omit.** Provider down, unsupported pair,
  or stale cache → the todo still renders as "verify entry requirements" with
  official links. The todo existing is the value; the classification is a
  bonus.
- **Client-side derivation, matching existing todos.** Existing booking todos
  are derived in the client (`_deriveTodos`) with `todo_key` prefixes
  (`stay:<city>`, `transport:<a>>><b>`). Entry todos follow the same pattern
  (`entry:<country>`), which gets dedupe, ordering, and `todoClaimed`
  behavior for free.

### Data provider options (decide at implementation start)

| Option | Fit | Notes |
|--------|-----|-------|
| Sherpa° API (or similar travel-requirements API) | **Recommended** | Purpose-built: passport × destination → requirement class + conditions + official links. Per-request cost; cache makes volume tiny. Evaluate coverage for the top ~50 destination countries before committing. |
| Curated static rules table | Fallback / v0 | Manually maintained rows for the top destinations; zero marginal cost; goes stale — only acceptable with the retrieval-date UI and a refresh chore. |
| LLM classification | **Rejected** | Violates the architecture's core principle; this feature is the proof of that principle. |

Whichever provider: the response contract is the app's own (spec §API), so
swapping providers later touches only the service file.

## Go API Changes

`src/packages/api/` (all files are `package main`):

- **Service:** new `entry_requirements_service.go` — provider client,
  response normalization into the API contract, cache read/write, degraded
  fallback path. Follow the existing provider-service patterns (budget caps,
  degrade-with-reason-code).
- **Handler:** `GET /api/v1/entry-requirements` in a new
  `entry_requirements_handler.go`; register in `main.go` with a startup log
  line.
- **Cache:** new migration — `entry_requirements` table keyed by
  (passport_country, destination_country, purpose) with payload JSON,
  provider name, retrieved_at. Reuse the goose migration pattern.
- **Profile:** migration adding `passport_country` / `residence_country` to
  the profile/preferences store; extend the existing profile handlers and
  sqlc queries rather than a parallel endpoint.
- **Types:** request/response structs in the handler file; an explicit
  `status: unknown` value distinct from any real class.
- **Env:** provider API key; document in `.env.sample`.

Convention reminders (see CLAUDE.md → Key Constraints):
- New secrets are read from env vars — document them in `.env.sample`.
- New CORS headers go in `corsMiddleware` (not expected here).

## Flutter Changes

`src/packages/flutter-app/lib/`:

- **Models** (`models/`): `EntryRequirement` model; run
  `make flutter-build-models`. **Never hand-edit `.g.dart`.**
- **Service** (`services/`): wrapper for the lookup endpoint.
- **Provider** (`providers/`): one Riverpod provider; cache per trip.
- **Derivation:** extend `_deriveTodos` in `utils/trip_format.dart` — new
  `entry:<country>` todo kind, one per distinct foreign destination country
  across legs, ordered with booking todos (before `stay:` items — entry
  lead times are longer than booking lead times). Skip domestic legs.
- **UI:** todo row with an entry badge; detail sheet (class, conditions,
  lead time, official link, retrieval date, disclaimer); nationality-prompt
  state linking to profile; profile screen gains the two fields.
- **i18n:** strings in both English and Spanish, per repo convention.

## Contract Parity

| API field | Dart model field | Notes |
|-----------|------------------|-------|
| `status` | `status` | enum incl. `unknown` |
| `conditions` | `conditions` | nullable |
| `official_url` | `officialUrl` | nullable in degraded state → generic links |
| `source` / `retrieved_at` | `source` / `retrievedAt` | always shown |

## Open implementation questions

- Provider selection + pricing (evaluate Sherpa° first; confirm coverage and
  per-request cost against the free-tier COGS budget — target < $0.02/trip
  after caching).
- Whether transit-country detection is feasible from current flight data
  (connection airports are known; airside-vs-entry distinction may need
  provider support) — v1 may flag connections with generic wording.
