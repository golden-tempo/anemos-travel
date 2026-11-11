# Tasks: Entry Requirements

> Dependency-ordered. `[P]` = can run in parallel with its siblings (no shared
> files / no ordering dependency). Work top to bottom; verification is last.

## Pre-work

- [ ] Evaluate data providers (Sherpa° first): coverage for top ~50
      destinations, per-request cost, terms. Record the decision in plan.md.
- [ ] Confirm the profile store's migration pattern for the two new fields.

## API (Go)

- [ ] Migration: `entry_requirements` cache table
- [ ] Migration: `passport_country` + `residence_country` profile fields
- [ ] Define request/response types (explicit `unknown` status)
- [ ] Implement `entry_requirements_service.go` (provider client, cache,
      degraded fallback)
- [ ] Implement `entry_requirements_handler.go`
- [ ] Extend profile handlers/queries for the two fields
- [ ] Register route(s) + startup log line in `main.go`
- [ ] Add provider key to `.env.sample`
- [ ] Tests: cache hit/miss, provider failure → degraded, unsupported pair →
      unknown, profile round-trip

## Models & codegen (Flutter)

- [ ] Hand-write `EntryRequirement` model in `models/`
- [ ] Run `make flutter-build-models` to regenerate `.g.dart`
- [ ] Complete the Contract Parity table in `plan.md` (every row ✓)

## UI (Flutter)

- [ ] [P] Add service wrapper in `services/`
- [ ] [P] Add Riverpod provider in `providers/`
- [ ] Extend `_deriveTodos` with the `entry:<country>` kind (dedupe, ordering,
      domestic-leg skip)
- [ ] Todo row badge + detail sheet (class, conditions, official link,
      retrieval date, disclaimer)
- [ ] Nationality-unset prompt state → profile
- [ ] Profile screen: passport country + residence fields
- [ ] Loading / degraded / error states
- [ ] i18n strings (en + es)
- [ ] Tests: derivation (multi-city same-country dedupe, domestic skip,
      leg-change updates), sheet rendering of every status

## Verification

- [ ] `make api-fmt && make api-vet` clean
- [ ] `make flutter-analyze` clean
- [ ] Acceptance criteria in spec.md walked end-to-end on a 3-country trip,
      including one unsupported pair and one nationality-unset session
