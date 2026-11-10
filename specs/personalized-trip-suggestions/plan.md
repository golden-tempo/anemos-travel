# Plan: Personalized Trip Suggestions

> **HOW.** Translates `spec.md` into a file-level technical approach.

## Technical Approach

Client-only — the pool, the trips list, and the country each already resolves
to all exist today; this feature is a pure reordering function plus a second,
in-app-only provider that reads it.

Three decisions carry the design:

1. **A sibling provider, not a parameter on the existing one.** The rail's
   provider graph (`suggestionOrderProvider`) is also read, unmodified, by the
   signed-out landing page. Threading trip-history data through it would pull
   `tripsProvider` → `tripCacheProvider` → `authProvider` into a page that has
   no account to read one from, for a parameter that page would always pass
   as empty. A new `personalizedSuggestionOrderProvider` (same shape:
   `Provider<List<int> Function()>`) keeps that coupling out of the
   unauthenticated surface entirely — exactly the precedent
   `suggestionOrderProvider` itself set beside `suggestionPickerProvider`.
2. **Bias, never filter.** `pickSuggestionIndices` still shuffles the whole
   pool first, then stably partitions it into "not yet visited" ahead of
   "already visited" — a stable partition of an already-random list is still
   a valid shuffle within each half, and nothing is dropped, which is what
   lets a traveler scroll back to a country they loved.
3. **Country, not city, and hand-tagged.** The pool is a dozen curated
   entries (not twelve geocoded ones), and `CityPin.country` is already an
   ISO 3166-1 alpha-2 code (`countryForPoint`, specs/trips-page-insights) — so
   each `SuggestionPrompt` just names the same code directly, no lookup table
   needed. Two entries (Rome, Amalfi) share `IT` on purpose: it is the one
   case in the pool where "visited this country but not this city" can be
   observed at all.

## Go API Changes

None.

## Flutter Changes

`src/packages/flutter-app/`:

- **`lib/utils/trip_list_insights.dart`** — new `visitedCountryCodes(trips,
  today)`: every `CityPin.country` on a trip that has started
  (`tripHasStarted`, the same rule `travelStats` partitions traveled/planned
  on). Pure, and the ONE place this set is derived, so it can never disagree
  with "Your travels"' own `traveled.countries` count.
- **`lib/providers/suggestions_provider.dart`**:
  - `SuggestionPrompt` gains a `country` field (ISO alpha-2); every pool entry
    is hand-tagged (see Divergences for why this isn't generated).
  - `pickSuggestionIndices` gains an optional `visitedCountries` set
    (default `{}` — unchanged behavior when omitted, which is every existing
    caller). Non-empty: shuffle, then stably move every index whose
    `SuggestionPrompt.country` is in the set behind every index whose isn't.
  - New `personalizedSuggestionOrderProvider`: same shape as
    `suggestionOrderProvider`, reads `tripsProvider` (already loaded
    app-wide — no request of its own, the `HomeTravelsBand` precedent) and
    passes `visitedCountryCodes(trips, DateTime.now())` through.
    `suggestionOrderProvider` itself is untouched.
- **`lib/widgets/home_inspiration_rail.dart`** — `RandomSuggestions.picker`
  switched from `suggestionOrderProvider` to
  `personalizedSuggestionOrderProvider`.
- **`lib/screens/agent_screen.dart`** — `_DestinationRail`'s `picker` switched
  the same way.
- **Unchanged:** `lib/screens/landing/landing_destination_rail.dart`,
  `lib/screens/landing/landing_hero.dart`, `lib/screens/home_screen.dart`'s
  hero chips — all keep reading `suggestionOrderProvider` /
  `suggestionPickerProvider` exactly as before.

No model, service, or `.g.dart` change. No new l10n strings — per spec.md,
Out of Scope, there is no new copy.

## Divergences ← per docs/zen.md, written down and pinned

**A dedicated provider, not a parameter.** The smaller-looking change was a
`personalize: bool` (or a `WidgetRef`) parameter on `suggestionOrderProvider`
itself. That would make every reader — including the landing page's, which
has no account — depend on the trips/auth provider chain to answer "false",
and it would make `suggestion_pool_test.dart`'s bare `ProviderContainer()` (no
overrides at all) reach into `authProvider`'s real session-restore path,
which calls `flutter_secure_storage` with no platform channel registered in a
plain Dart test. Keeping the two providers siblings — the same shape
`suggestionPickerProvider`/`suggestionOrderProvider` already are — means a
surface's dependency on trip history is stated by which provider it reads,
never inherited.

## Testing

- `test/trip_list_insights_test.dart` — new `group('visitedCountryCodes')`:
  started-trips-only, dedupe across trips/cities, and that an unresolved
  (name-only/undated) destination contributes nothing.
- `test/suggestion_pool_test.dart` — `pickSuggestionIndices` with a
  `visitedCountries` set: every visited-country index sorts behind every
  other one with no destination lost; empty set is byte-identical to the
  no-argument call; a fully-visited pool still returns everything.
  `personalizedSuggestionOrderProvider`: no-ops against an empty trips list,
  and demonstrably reorders against a seeded one (via a `TripsNotifier`
  subclass that seeds state directly — no network, no auth chain).
- `test/home_inspiration_rail_test.dart` / `test/agent_empty_state_suggestions_test.dart`
  — updated to override `personalizedSuggestionOrderProvider` (the provider
  each rail now actually reads) instead of `suggestionOrderProvider`.

## Rollout

No migration, no flag, no server deploy coupling. Reverting is a code revert.
