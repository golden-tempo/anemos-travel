# Plan: Booking Address Prompt

> **HOW.** See `../../CLAUDE.md` for repo conventions referenced below.

## Technical Approach

Two independent, small additions, wired together at one call site:

1. **The prompt itself** — a new dialog (`stay_address_prompt.dart`), shown
   from `bookings_tab.dart`'s existing `_setRowBooked` right after the booked
   flip is accepted and before the pre-existing budget prompt, mirroring that
   prompt's own "only after accept, skippable, never blocks" shape. It only
   fires for a stay-kind row with no address yet. Saving either PATCHes the
   matched accommodation (when one exists) or POSTs a new one named from the
   todo's title (when the row is still todo-only) — the same two write paths
   `AccommodationsApiService` already exposes, reused as-is. A reload
   (`_load()`) after the write is what re-derives the itinerary's hotel-anchor
   travel times and the map pin — no new computation needed; that machinery
   (`_computeTravelTimes`, `TripMap.stayHasCoords`) already reads exactly
   these fields.

2. **"Nearby"** — a new server endpoint (`GET /places/nearby`), a thin wrapper
   around the existing `GooglePlacesService.SearchPlacesNearby` (already used
   by `find_parking` and the chat agent's `search_nearby` tool, just never
   exposed to a plain REST caller), plus a bottom sheet
   (`nearby_places_sheet.dart`) rendering its results. Wired as one more
   overflow-menu entry on `BookingDetailRow`'s existing kebab (`onNearby`),
   offered only when `TripMap.stayHasCoords` is true for the stay — the same
   predicate the map already uses to decide whether a stay is pin-worthy.

No new data model, no new migration: the accommodation's `address` /
`latitude` / `longitude` columns already exist and are already read by every
downstream consumer this feature turns on.

## Go API Changes

`src/packages/api/` (all files are `package main`):

- **Handler:** `placesNearbyHandler` in `main.go`, next to the existing
  `placesSearchHandler`. Reads `lat`, `lng` (required `float64`, validated
  with the existing `validateCoords`), `q` (optional, defaults to
  `defaultNearbyQuery`).
- **Service:** none new — calls `placesService.SearchPlacesNearby` directly
  (already exists in `places_service.go`, already handles its own cache
  keying and Google location-bias params).
- **Route:** `api.HandleFunc("/places/nearby", placesNearbyHandler).Methods("GET")`
  registered alongside `/places/search`, plus a startup log line. No new rate
  bucket — same general tier as its `/places/*` siblings.
- **Types:** response shape matches `placesSearchHandler`'s
  `{"results": [...], "status": "success"}` exactly — same `PlaceSearchResult`
  wire type, so the Dart side needs no new model.

## Flutter Changes

`src/packages/flutter-app/lib/`:

- **Service** (`services/places_api_service.dart`): `searchNearby(lat, lng, {query})`
  wrapping the new endpoint, returning `List<PlaceSearchResult>` (the
  existing model — no new `@JsonSerializable` type, no codegen needed).
- **Provider** (`providers/places_api_provider.dart`): `nearbyPlacesProvider`,
  a `FutureProvider.family` keyed by a `NearbyQuery` record
  (`{latitude, longitude, query}`).
- **Widgets:**
  - `widgets/stay_address_prompt.dart` — `showStayAddressPrompt` +
    `StayAddressDraft`, mirroring `booked_expense_prompt.dart`'s shape
    (pure dialog, no network calls of its own) and `AddStaySheet`'s
    place-search-attaches-coordinates behavior from `booking_sheets.dart`.
  - `widgets/nearby_places_sheet.dart` — `showNearbyPlacesSheet`, a bottom
    sheet over `nearbyPlacesProvider`; each result's "Directions" button opens
    a Google Maps search URL via the existing `trackedLaunchUrl` (provider
    `google_maps`, surface `bookings_nearby`).
  - `widgets/booking_detail_row.dart` — new optional `onNearby` constructor
    param on `.stay` (not `.segment`), folded into the existing edit/delete
    `PopupMenuButton` kebab as one more item — no new icon, per that file's
    own "action, overflow, then state" trailing-grammar rule.
- **Trigger site** (`widgets/trip_detail/bookings_tab.dart`):
  - `_setRowBooked` calls a new `_maybePromptStayAddress` right after the
    booked-flip network call is accepted (before `_maybePromptBudgetExpense`,
    which now reads its returned accommodation instead of the original
    `stay` param, so a freshly-created stay's name flows into the budget
    prefill too).
  - `_detailRowFor` passes `onNearby` for a stay, gated on
    `TripMap.stayHasCoords(stay)`.

## Contract Parity

| JSON key | Go type (`main.go`) | Dart type (`place_search_result.dart`) | Nullable? | ✓ |
|----------|----------------------|------------------------------------------|-----------|---|
| `results[].place_id` | `string` | `String` | no | ✓ |
| `results[].name` | `string` | `String` | no | ✓ |
| `results[].formatted_address` | `string` | `String` (`address`) | no (defaultValue) | ✓ |
| `results[].lat` / `.lng` | `float64` | `double` | no | ✓ |
| `status` | `string` | n/a (checked, not modeled) | no | ✓ |

No new fields: `placesNearbyHandler` returns the same `PlaceSearchResult`
struct `placesSearchHandler` already returns, so the existing Dart model
covers it without changes.

## Cross-cutting

- **Env vars:** none new (`GOOGLE_PLACES_API_KEY` already gates all
  `/places/*` endpoints, including this one).
- **Gateway:** `/api/v1/places/nearby` needs no extra nginx config — it's
  under the already-proxied `/api/v1/` prefix.
- **l10n:** new ARB keys (`stayAddressPromptTitle`, `stayAddressPromptBody`,
  `bookingsNearby`, `nearbyTitle`, `nearbyEmpty`, `nearbyError`,
  `nearbyDirections`) added to both `app_en.arb` and `app_es.arb` in the same
  change (translation coverage is a CI gate) and regenerated with
  `flutter gen-l10n`.

## Verification

- `make api-fmt && make api-vet` — Go formatting/vet clean.
- `make flutter-build-models` — no model changes, but confirms no other
  pending codegen.
- `flutter gen-l10n` — `l10n_untranslated.json` empty, generated files
  committed.
- `make flutter-analyze` — clean.
- `make flutter-test` / `make api-test` — full suites pass, including new
  tests for the prompt, the nearby sheet, the booked-flip wiring, and the
  handler.
