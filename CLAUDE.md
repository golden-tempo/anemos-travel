# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A travel route planning platform with two packages:
- **Go API** (`src/packages/api/`) — REST + SSE backend for route optimization, Google Places, and AI planning
- **Flutter app** (`src/packages/flutter-app/`) — Material 3 web/mobile frontend using Riverpod

A single **nginx gateway** on port **3000** serves the Flutter UI and proxies `/api/v1/` to the Go API, keeping everything same-origin.

## Coding Principles

This repo codes by the Zen of Python — see [`docs/zen.md`](docs/zen.md) for
the full text and the repo-specific lessons attached to it. The headline,
paid for by the leg-dates arc: **explicit is better than implicit** — data
semantics live in schema/types/enforced boundaries, never in conventions
someone must remember; derived state is computed in exactly one place; a
mutating tool's result states the post-state its consumer will observe.
Read `docs/zen.md` before designing a data model, tool contract, or
derivation.

## Spec-Driven Development

Non-trivial features start as a spec under `specs/<feature-name>/` (copied from
`specs/_template/`). Before implementing a feature, read its `spec.md` (what &
why) and `plan.md` (how); treat the spec's acceptance criteria as the definition
of done and surface any `[NEEDS CLARIFICATION]` before starting. See
[`specs/README.md`](specs/README.md) for the workflow.

## Design References

UI is designed against the project's visual reference library:
read `.claude/skills/design-inspiration/SKILL.md` — and actually look at its
`references/` images — before creating or restyling any screen, widget, or
theme value, the same way `docs/zen.md` precedes a data model. The skill's
ADD mode captures new references when the owner names a design worth keeping;
theme tokens themselves live in `src/packages/flutter-app/lib/theme/`.

Every UI change is then held to the brand rulebook: load
`.claude/skills/brand-guidelines/SKILL.md` (the enforceable digest of
[`docs/branding/brand-guidelines.html`](docs/branding/brand-guidelines.html))
whenever an interface is created, updated, or reviewed, and run its
`scripts/check.sh` on touched Dart files before shipping. Taste
(design-inspiration) → values (`lib/theme/`) → conformance (brand-guidelines);
a rule that must break gets written into the guideline doc in the same PR.

## Parallel Development

Feature waves run as parallel **lanes**: one lane = one branch = one git
worktree (`make wt-new NAME=…`, own dev stack on its own ports) = one PR. Lane
agents STOP at PR-open (`ship pr` — never merge); one integrator session
(`/integrate`) merges them serially **in the order the PRs were opened** —
checking each for conflicts with `main` first and merging straight away when
there are none, otherwise merging `main` in, resolving hub files and
regenerating generated code (`store/`, `lib/l10n/app_localizations*.dart`,
`*.g.dart` are NEVER hand-merged — regen LAST) before it merges. Nothing is
rebased or force-pushed. Deploys run in the background and never block the next
merge; a red one stops the queue. Wave planning reserves goose migration
numbers; at most one in-flight lane may touch
`trip_detail_screen.dart` or append to `plan_tool_registry.go`. Full rules and
runbooks: [`docs/parallel-dev.md`](docs/parallel-dev.md). Triggers: `/wave`
(orchestrate a wave; also `status`/`abort`) and `/lane` (bootstrap one lane).

**Auto-lane on execute**: when executing an approved plan (or starting any
multi-file feature work) from the **main checkout**, first create a lane —
`make wt-new NAME=<feature-slug>` — and do all the work inside that worktree;
`ship` then stops at PR-open automatically and the integrator merges.
Single-file fixes and doc touch-ups may stay on a main-checkout branch.

## Common Commands

```bash
make help               # List all available commands
make setup              # Install all dependencies (Go + Flutter)

# Development (hot reload)
make docker-dev         # Full stack: Flutter + API + gateway at http://localhost:3000
make api-run            # API only on http://localhost:8080
make flutter-run        # Flutter only (points to localhost:8080)

# Testing & linting
make api-test           # Run test_examples.sh against the API
make api-fmt            # go fmt ./...
make api-vet            # go vet ./...
make api-migrate        # Apply DB migrations (also run automatically on API boot)
make api-sqlc           # Regenerate type-safe DB code from SQL (requires sqlc)
make flutter-test       # flutter test
make flutter-analyze    # flutter analyze

# Code generation (run after modifying model files with @JsonSerializable)
make flutter-build-models  # dart run build_runner build

# Health checks
make health             # curl API health via gateway
make test-route         # POST test route optimization via gateway
make test-places        # GET place search via gateway
```

## Architecture

### Go API (`src/packages/api/`)

All files in `package main`. Key files:
- `main.go` — HTTP server (gorilla/mux), middleware, and all route handlers
- `route_optimizer.go` — Nearest Neighbor + 2-Opt algorithm for location-level routes; defines `RouteRequest`, `RouteResponse`, `Location`, `OperatingHours`
- `places_service.go` — Google Places API integration (Text Search, Autocomplete, Details); reads `GOOGLE_PLACES_API_KEY` env var
- `plan_handler.go` — Streaming SSE endpoint (`POST /api/v1/plan`) backed by `anthropic-sdk-go`; agent loop (`aiModel()`, default claude-sonnet-4-6) dispatches through the ordered tool registry in `plan_tool_registry.go`; `plan_compactor.go` summarizes long histories with `aiModelLight()` (default Haiku 4.5); reads `ANTHROPIC_API_KEY` env var. Models and base URL are env-swappable to any Anthropic-compatible provider (see `anthropic_client.go` + `.env.sample`; e.g. Moonshot/Kimi)
- `db.go` — pgx connection pool (`dbPool`) + embedded goose migrations (`migrations/*.sql`); reads `DATABASE_URL`
- `store/` — **sqlc-generated** type-safe DB code; the only non-`package main` code in the API. Generated by `make api-sqlc` from `query/*.sql` + the migration schema; never hand-edit. (Created with the first queries; not present until then.)

The API runs on port **8080**. `WriteTimeout` is set to `0` (unlimited) to support the streaming `/plan` endpoint. Migrations apply automatically on boot; a missing/unreachable `DATABASE_URL` starts the API in **degraded mode** (stateless endpoints still work; `/health` returns 503 with the DB status).

### Flutter App (`src/packages/flutter-app/`)

State management: **Riverpod** (`ProviderScope` wraps the whole app).

- `lib/services/api_client.dart` — HTTP client; base URL configured via `--dart-define=API_BASE_URL` (defaults to `http://localhost:8080/api/v1`)
- `lib/services/places_api_service.dart` — Wraps places endpoints
- `lib/services/plan_service.dart` — SSE streaming client for `/plan`
- `lib/providers/` — Riverpod providers (one per feature: route, country, places, plan, api_client)
- `lib/screens/` — `HomeScreen`, `AgentScreen` (plan chat), `TripsListScreen`, `TripDetailScreen`
- `lib/models/` — Dart models matching Go API JSON; `.dart` files are hand-written, `.g.dart` files are generated by `json_serializable`

**Model code generation**: Any change to a model annotated with `@JsonSerializable` requires running `make flutter-build-models` to regenerate the `.g.dart` file.

### Docker / Gateway

- `dockerize/development/` — Flutter dev server + API + nginx (hot reload)
- `dockerize/deployment/` — Multi-stage: builds Flutter web, serves static, proxies API

Flutter is built with `--dart-define=API_BASE_URL=/api/v1` in Docker, so API calls are same-origin relative paths through the nginx proxy.

## Key Constraints & Reference (path-scoped rules)

The hard-won invariants that used to live in this file are now one topic file
each under [`.claude/rules/`](.claude/rules/), with `paths:` frontmatter. A rule
loads automatically when Claude reads, writes, or edits a file it governs — so a
constraint arrives with the code it constrains instead of competing for attention
on every unrelated task. **Nothing was dropped in the split.**

Read the rule yourself (it is a plain file) when you are reasoning about one of
these areas without yet opening its files — notably before designing a data model
or tool contract, where `docs/zen.md` applies too:

| Rule | Covers | Loads when you touch |
|---|---|---|
| [`api-core.md`](.claude/rules/api-core.md) | API core invariants | `src/packages/api/**/*.go`, `src/packages/api/query/*.sql`, +1 more |
| [`api-env-and-endpoints.md`](.claude/rules/api-env-and-endpoints.md) | API environment variables & endpoint map | `src/packages/api/**/*.go` |
| [`api-plan-agent.md`](.claude/rules/api-plan-agent.md) | The /plan SSE agent loop | `src/packages/api/plan_*.go`, `src/packages/api/places_photo_handler.go`, +4 more |
| [`api-booking-legs.md`](.claude/rules/api-booking-legs.md) | Derived legs, booking todos & transport mode | `src/packages/api/booking_todo*.go`, `src/packages/api/booking_option*.go`, +6 more |
| [`api-trip-content.md`](.claude/rules/api-trip-content.md) | A trip's description & daily spend | `src/packages/api/trip_summary.go`, `src/packages/api/plan_trip_description.go`, +3 more |
| [`api-providers-flights.md`](.claude/rules/api-providers-flights.md) | Flight search providers (Duffel / SerpApi swap) | `src/packages/api/duffel_service.go`, `src/packages/api/flight*.go`, +3 more |
| [`api-providers-lodging.md`](.claude/rules/api-providers-lodging.md) | Hotel search (two tiers) | `src/packages/api/hotel_search_service.go`, `src/packages/api/hotel_handler.go` |
| [`api-providers-local.md`](.claude/rules/api-providers-local.md) | Events, Greece, local-sourced content & link preview | `src/packages/api/events_service.go`, `src/packages/api/greece_events_service.go`, +3 more |
| [`api-ops-health.md`](.claude/rules/api-ops-health.md) | Uptime history & provider health | `src/packages/api/ops_*.go`, `src/packages/api/ai_health.go`, +1 more |
| [`api-mcp-oauth.md`](.claude/rules/api-mcp-oauth.md) | MCP connector & OAuth provider | `src/packages/api/mcp_*.go`, `src/packages/api/oauth_provider_handler.go`, +2 more |
| [`api-trip-import.md`](.claude/rules/api-trip-import.md) | Trip import from an external AI chat | `src/packages/api/trip_import*.go`, `src/packages/flutter-app/lib/screens/import_trip_screen.dart` |
| [`flutter-models.md`](.claude/rules/flutter-models.md) | Flutter model codegen | `src/packages/flutter-app/lib/models/*.dart` |
| [`flutter-tests.md`](.claude/rules/flutter-tests.md) | What a Flutter widget test can and cannot prove | `src/packages/flutter-app/test/**/*.dart` |
| [`gateway-edge-cache.md`](.claude/rules/gateway-edge-cache.md) | Gateway asset caching & edge parity | `dockerize/**/*`, `scripts/verify-edge-parity.sh` |

Two that bite hardest, worth knowing before you open the file:

- **`plan_tool_registry.go` is a prompt-cache prefix** — append new tools at the
  TAIL, keep existing entries byte-stable (`api-plan-agent.md`).
- **A widget test lays out in a stand-in font, so it cannot answer a layout
  question** — never write or restore an assertion that depends on rendered text
  size (`flutter-tests.md`).
