---
paths:
  - "src/packages/api/**/*.go"
---

# Environment Variables

Create `src/packages/api/.env` (see `.env.sample`):
```
GOOGLE_PLACES_API_KEY=...       # Required for /places/* endpoints
ANTHROPIC_API_KEY=...           # Required for /api/v1/plan SSE endpoint
DUFFEL_ACCESS_TOKEN=...         # Required for /flights/* endpoints (Duffel; test or live token)
FLIGHT_OFFERS_PROVIDER=...      # TEMPORARY: "serpapi" routes flight OFFER searches to SerpApi Google Flights (real data while the Duffel token is test-mode); unset = Duffel
SERPAPI_API_KEY=...             # SerpApi key for the temporary swap (free tier 250 searches/mo)
TICKETMASTER_API_KEY=...        # Required for /events/* endpoint (Ticketmaster Discovery; free key)
TRANSCRIPTION_API_KEY=...       # Voice-dictation fallback (/transcribe); any OpenAI-compatible /audio/transcriptions provider — defaults target Groq
TRANSCRIPTION_BASE_URL=...      # Default https://api.groq.com/openai/v1
TRANSCRIPTION_MODEL=...         # Default whisper-large-v3-turbo
GOOGLE_OAUTH_CLIENT_ID=...      # Sign in with Google (server-side OAuth), with...
GOOGLE_OAUTH_CLIENT_SECRET=...  # ...this; register <PUBLIC_BASE_URL>/api/v1/auth/google/callback as redirect URI
APPLE_TEAM_ID=...               # Sign in with Apple (specs/apple-sso): Team ID, plus...
APPLE_CLIENT_ID=...             # ...the Services ID, ...
APPLE_KEY_ID=...                # ...the .p8 key id, and...
APPLE_PRIVATE_KEY=...           # ...the .p8 PEM base64-encoded onto one line
SENTRY_DSN=...                  # Optional error alerting; empty => Sentry fully inert
DATABASE_URL=...                # Postgres connection; absent/unreachable => degraded mode (no persistence)
```

Without `GOOGLE_PLACES_API_KEY`, place search endpoints return errors. The `/plan` handler also calls `search_places` internally, which will fail without the key. Without `DUFFEL_ACCESS_TOKEN`, the `/flights/*` endpoints return a configured-error; the rest of the API is unaffected. Without `TICKETMASTER_API_KEY`, the `/events/search` endpoint (and the `/plan` agent's `search_events` tool) returns a configured-error; the rest of the API is unaffected. Without `TRANSCRIPTION_API_KEY`, the dictation fallback is disabled (`/transcribe/availability` reports it) and the mic only appears in browsers with built-in speech recognition. Without the `GOOGLE_OAUTH_*` pair, the Google button is hidden and `/auth/google` answers 503; likewise the four `APPLE_*` vars gate the Apple button and `/auth/apple`; email+password auth is unaffected either way. `FERRYHOPPER_AFFILIATE_ID` is optional — ferry links work without it (just unattributed). `.env.sample` documents further optional vars: `SMTP_*` (verification/reset email; empty => tokens are logged instead), `PUBLIC_BASE_URL`/`PUBLIC_APP_PATH`, `ALLOWED_ORIGINS` (CORS, dev-only), `BOOKING_AFFILIATE_ID`, `PORT`, free-cap tuning (`FREE_*`), `ANTHROPIC_BASE_URL` + `ANTHROPIC_MODEL` + `ANTHROPIC_MODEL_LIGHT` (Anthropic-compatible provider swap, e.g. Moonshot/Kimi — also the fake-Anthropic test seam; unset = real Anthropic with the default Claude models), and `SENTRY_RELEASE`. `SERPAPI_HOTEL_SEARCHES_PER_DAY` (default 8; an explicit `0` means zero, not "default") and `HOTEL_RATES_CURRENCY` (default USD) tune `search_hotels`, which shares `SERPAPI_API_KEY` but is independent of the flights swap. With `FLIGHT_OFFERS_PROVIDER=serpapi`, `SERPAPI_BASE_URL` (test seam) and `SERPAPI_SEARCHES_PER_DAY` (quota guard, default 50) also apply — see the temporary-swap bullet under Key Constraints.

# API Endpoints

| Method | Path | Handler |
|--------|------|---------|
| POST | `/api/v1/optimize-route` | Nearest Neighbor + 2-Opt; up to 50 locations |
| GET | `/api/v1/places/search?q=` | Google Places Text Search |
| GET | `/api/v1/places/nearby?lat=&lng=&q=` | Google Places Text Search biased to a coordinate (specs/booking-address-prompt); `q` defaults to a mixed dining/things-to-do query when omitted — powers the trip page's "Nearby" action on a confirmed stay |
| GET | `/api/v1/places/autocomplete?input=` | Google Places Autocomplete |
| GET | `/api/v1/places/details?place_id=` | Google Places Details |
| GET | `/api/v1/places/photo?ref=&w=` | Place Photo redirect: 302 to the googleusercontent image; only serves refs the server itself recently emitted (anti-abuse gate), `w` clamped to 200/400/800; own rate bucket |
| GET | `/api/v1/flights/airports?q=` | Duffel airport/city autocomplete (IATA codes) |
| POST | `/api/v1/flights/search` | Duffel flight offers, ranked by `optimize_for` (`cost`/`time`/`balanced`) |
| GET | `/api/v1/hotels/search?city=&check_in=&check_out=&adults=` | Lodging with live nightly rates (SerpApi Google Hotels); degrades to a no-prices Google Places `type=lodging` list when dates are absent, the day's cap is spent, or the provider fails. Own `strict` rate bucket |
| GET | `/api/v1/events/search?city=&start_date=&end_date=` | Ticketmaster Discovery events in a city for a date window (optional `category`) |
| GET | `/api/v1/ferries/search?origin=&destination=&date=` | Ferryhopper ferry booking link for a route (Greek island-hopping); returns `FerryOption[]` |
| GET | `/api/v1/local/recommendations?city=` | Published, locally-sourced recommendations for a city (optional `category`); returns `LocalRec[]` with attribution |
| GET | `/api/v1/local/guides?city=` | Published narrative guides for a city; `GET /api/v1/local/guides/{id}` returns the guide + its ordered pins |
| POST | `/api/v1/admin/local/ingest` | **Admin.** AI-extract draft recommendations from raw research text (source_id, city, kind, raw_text); verifies places via Google |
| GET/POST | `/api/v1/admin/local/sources` | **Admin.** List / create local sources (the named people content is attributed to) |
| GET | `/api/v1/admin/local/recommendations?status=` | **Admin.** Curation queue; `POST .../{id}/publish` publishes (blocked without coordinates), `PATCH .../{id}` edits |
| GET | `/api/v1/admin/local/coverage` | **Admin.** Per-city published/draft counts |
| GET | `/api/v1/admin/metrics` | **Admin.** Phase-1 funnel metrics; siblings `/admin/metrics/{timeseries,totals,activity,users}` power the tabbed analytics dashboard |
| GET | `/api/v1/admin/ops/uptime?days=` | **Admin.** 90-day per-component uptime history for the Health pane's status strip (specs/uptime-history), rolled up from `health_samples`; 503 in degraded mode, unlike its `/admin/ops/{health,metrics}` siblings |
| POST | `/api/v1/transcribe` | Voice-dictation fallback: audio clip → text via OpenAI-compatible transcription (Groq default); `GET /api/v1/transcribe/availability` gates the mic UI |
| GET | `/api/v1/auth/google` | Sign in with Google: server-side OAuth redirect flow (specs/google-sso); callback lands on `/sso/<one-time code>`, exchanged via `POST /auth/sso/exchange` (`/auth/google/exchange` is a legacy alias); `GET /auth/google/availability` gates the button |
| GET | `/api/v1/auth/apple` | Sign in with Apple (specs/apple-sso): same flow with a **POST** form_post callback, ES256 client-secret JWT, no PKCE; `GET /auth/apple/availability` gates the button |
| POST/GET/DELETE | `/mcp` (root-level) | **MCP connector** (specs/mcp-connector): Streamable HTTP MCP server that ChatGPT (Developer Mode) and claude.ai (custom connectors) drive with OAuth tokens; tools `create_trip`, `search_local_recommendations`, `list_trips`. Gated by `MCP_ENABLED`; discovery at `/.well-known/oauth-{protected-resource,authorization-server}` |
| — | `/api/v1/oauth/*` | OAuth 2.1 **provider** for the connector: `register` (RFC 7591 DCR), `authorize` (302 → app `/connect/<token>` consent), `authorize/context`, `authorize/decision`, `token` (PKCE S256, single-use codes, refresh rotation); `connections` GET/DELETE = Connected-apps list/revoke |
| POST/PATCH/DELETE | `/api/v1/trips/{id}/booking-options` | **Booking shortlist** (specs/booking-shortlist, migration 00065): the candidates a traveler is deciding between, per leg. `POST .../{optionId}/choose` promotes the winner into the real accommodation/segment + marks the leg booked in ONE transaction; `DELETE` on the same path reverses it. Options ride the `GET /trips/{id}` payload, editor-only |
| GET | `/api/v1/trips/{id}/budget/daily-spend?tier=` | **Daily food & drink guide** (specs/daily-spend-guide, migration 00070): per-person daily food estimate for each city leg, with its nights. Editor-only; degrades to an empty list + reason code, never errors |
| GET | `/api/v1/link-preview?url=` | OpenGraph prefill for a pasted booking link (auth, own rate bucket); SSRF-guarded, always 200 with `{ok:false,reason}` on failure |
| POST | `/api/v1/trips/import` | Paste an external-AI chat (ChatGPT/Claude) → persisted trip: one forced-tool Sonnet extraction + Places coordinate resolution + `persistTrip` (specs/import-trip-from-ai-chat); auth, own 5/min bucket, per-user `FREE_IMPORTS_PER_DAY` cap, 2 MiB body lane |
| GET | `/api/v1/chats` | Resumable (in-progress) plan conversations; excludes chats that produced a trip |
| GET/DELETE | `/api/v1/chats/{chatId}` | Full transcript for resume / dismiss a conversation |
| POST | `/api/v1/plan` | SSE stream; agent loop (`aiModel()`, default claude-sonnet-4-6) over an ordered tool registry (see `plan_tool_registry.go`) — notably `search_places`, `search_local_recommendations`, `search_flights`, `search_events`, `create_itinerary` / `update_itinerary_section` (mutually exclusive by session), `save_preferences`, booking-todo tools, and `suggest_replies` (one-tap quick-reply chips, specs/chat-quick-replies) |

The table above covers the product/provider surface; the authenticated account & trip CRUD surface (auth/*, trips/* incl. items, shares, collaborators, accommodations, segments, booking-todos, plus `/notifications`, `/preferences`, `/events` analytics ingest) is registered in `main.go` — read the route registrations there for the full list.
