# Tasks: Personalized Trip Suggestions

> Dependency-ordered. `[P]` = can run in parallel with its siblings.

## Flutter

- [x] `trip_list_insights.dart`: add `visitedCountryCodes(trips, today)`.
- [x] `suggestions_provider.dart`: add `country` to `SuggestionPrompt`; tag
      every pool entry.
- [x] `suggestions_provider.dart`: `pickSuggestionIndices` gains an optional
      `visitedCountries` bias parameter (default empty ⇒ unchanged).
- [x] `suggestions_provider.dart`: add `personalizedSuggestionOrderProvider`.
- [x] `home_inspiration_rail.dart`: read the new provider.
- [x] `agent_screen.dart` (`_DestinationRail`): read the new provider.

## Tests

- [x] `trip_list_insights_test.dart`: `visitedCountryCodes` coverage.
- [x] `suggestion_pool_test.dart`: bias behavior, empty-set no-op,
      fully-visited pool, and the new provider (no history / seeded history).
- [x] `home_inspiration_rail_test.dart`: override the new provider.
- [x] `agent_empty_state_suggestions_test.dart`: override the new provider.

## Verification

- [x] `flutter analyze` — clean on every touched file.
- [x] `flutter test` — full suite passes.
