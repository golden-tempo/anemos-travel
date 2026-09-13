# Tasks: Booking Address Prompt

> Dependency-ordered. `[P]` = can run in parallel with its siblings.

## API (Go)

- [x] Implement `placesNearbyHandler` in `main.go` (validated `lat`/`lng`,
      optional `q` defaulting to `defaultNearbyQuery`)
- [x] Register `GET /places/nearby` + startup log line
- [x] Handler tests: missing/invalid/out-of-range coords → 400; default query
      + location bias sent to the provider; explicit `q` honored

## UI (Flutter)

- [x] [P] `PlacesApiService.searchNearby` + `nearbyPlacesProvider`
- [x] [P] `stay_address_prompt.dart` (`showStayAddressPrompt`,
      `StayAddressDraft`) with search-attaches-coordinates behavior
- [x] [P] `nearby_places_sheet.dart` (`showNearbyPlacesSheet`) with
      loading/empty/error states and a Directions action per result
- [x] `BookingDetailRow` gains `onNearby`, folded into the existing kebab
- [x] `bookings_tab.dart`: `_maybePromptStayAddress` wired into
      `_setRowBooked` ahead of the existing budget prompt; `_detailRowFor`
      wires `onNearby` gated on `TripMap.stayHasCoords`
- [x] ARB keys added to `app_en.arb` + `app_es.arb`; `flutter gen-l10n` run
      and generated files committed

## Verification

- [x] `make api-fmt && make api-vet` clean
- [x] `flutter analyze` clean (pre-existing infos only)
- [x] `flutter test` — full suite green, including new tests:
      `stay_address_prompt_test.dart`, `nearby_places_sheet_test.dart`,
      `trip_detail_stay_address_prompt_test.dart`, additions to
      `booking_detail_row_actions_test.dart`
- [x] `go test ./...` — full suite green, including
      `places_nearby_handler_test.go`
