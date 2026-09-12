# Plan: Chat Initial Context

> **HOW.** This is the technical trace behind `spec.md` — exactly where each
> block of context is assembled today, file by file. Nothing here is proposed;
> it is what already runs on `main`. See `../../CLAUDE.md` for repo
> conventions referenced below.

## Where a turn starts

Every turn — first message of a brand-new chat or the tenth reply in a
resumed one — is one `POST /api/v1/plan` (`plan_handler.go`). The handler is
stateless across calls: it re-derives everything below from `PlanRequest`
(`plan_handler.go:108`) and the database on every invocation. There is no
per-conversation cache of "the context for this chat" anywhere; "loaded at the
start of each chat" is really "rebuilt at the start of each turn."

`PlanRequest` carries the two fields that decide which surface a turn came
from:

- `chat_id` — a free planning chat's own id (specs/continue-where-you-left-off).
  Set by the Plan tab once a conversation exists; irrelevant to trip binding.
- `trip_id` — set **only** by the trip detail page's refine panel
  (`trip_refine_panel.dart` → `tripRefineProvider` → `PlanNotifier`, which
  posts `TripID` per `specs/trip-refine-memory`). A Plan-tab fresh chat never
  sends this field.

`plan_handler.go:393-408` resolves `boundTripID`:

```go
if strings.TrimSpace(req.TripID) != "" {
    tid, err := uuid.Parse(req.TripID)
    if err != nil || !authed { sendError("sign in to refine this trip"); return }
    boundTrip, err := store.New(dbPool).GetEditableTripByID(r.Context(), ...)
    if err != nil { sendError("trip not found"); return }
    boundTripID = &tid
    ...
}
```

`GetEditableTripByID` is the access gate: it succeeds only for the trip's
owner or an editor collaborator, so the entire trip-detail context below is
conditioned on the caller being allowed to edit *this specific trip*, checked
fresh on every turn — not cached from when the panel opened.

`boundTripID == nil` for the entire remainder of the request is exactly the
Plan-tab, fresh-chat case.

## 1. Traveler profile — identical on both surfaces

`plan_handler.go:554-565`, inside the `authed` branch (runs regardless of
`boundTripID`):

```go
systemPrompt := basePrompt
if authed {
    if prefs, err := store.New(dbPool).GetPreferences(ctx, uid); err == nil {
        systemPrompt = personalizedSystemPrompt(basePrompt, &prefs)
        session.bagPref = prefs.Baggage
    }
    systemPrompt += profileNotesInstruction
}
```

- `store.GetPreferences` reads the one-row-per-user `traveler_preferences`
  table (specs/traveler-preferences, specs/active-profile,
  specs/traveler-baggage) fresh every turn. A read error is swallowed (`err
  == nil` guard) — the turn proceeds unpersonalized rather than failing.
- `personalizedSystemPrompt` (`plan_handler.go:1123`, running to ~1250) folds in, only for
  fields that are actually set: `budget`, `pace`, `interests`, `gender`,
  `home_airport` (+ a "default flights from here" instruction, skipped for
  car/train/bus trips), `work_style` (+ note for `digital_nomad`/`workation`),
  `fitness_routine` (+ gym/running notes), `outdoor_intensity` (+ a
  distance/elevation-stating instruction per band), `companions` (+ a
  solo/friends/family note), `baggage` (+ a fare-inclusion note), and the
  free-text `profile_notes` the agent itself maintains.
- `session.bagPref = prefs.Baggage` also rides the session object (not just
  the prompt text) so `search_flights` resolves the baggage tier server-side
  (specs/traveler-baggage) instead of depending on the model relaying it.
- `profileNotesInstruction` (`plan_handler.go:1105`, a package-level const) is
  appended unconditionally for every authenticated turn on either surface —
  it is what tells the agent to call `save_preferences` with a merged,
  de-duplicated `profile_notes` field when it learns something durable.
- Nothing here reads `boundTripID`. This block is byte-identical in shape
  whether the request came from the Plan tab or the trip detail page; only
  the *contents* differ, per traveler.

Anonymous (`!authed`): none of this runs; `systemPrompt` stays `basePrompt`.

## 2. Refine-mode instructions and trip metadata — trip detail page only

Still in `plan_handler.go`, gated on `boundTripID != nil` (line 565):

```go
if boundTripID != nil {
    systemPrompt += "\n\nYou are refining an existing saved trip in place. ..."
    if boundTripTravelMode != nil && *boundTripTravelMode != "" {
        systemPrompt += "\n\nThis trip's travel mode is " + *boundTripTravelMode + "; ..."
    }
}
```

This is prose only — how to call `update_itinerary_section`, `replace_leg`,
`set_leg_dates`, `shift_days_from`, etc. — not trip data itself.

The trip **data** rides as a *second system block*, assembled once per turn
(`plan_handler.go:600` onward):

```go
var tripStateBlock string
if authed && boundTripID != nil && dbPool != nil {
    if rendered, failed := runGetTripTool(ctx, authed, uid, boundTripID, json.RawMessage(`{}`)); !failed {
        tripStateBlock = "CURRENT TRIP STATE — read fresh from the database for this turn. ..." + rendered
    }
}
```

- `runGetTripTool` (`plan_tools_extra.go:694-800+`) is the **same renderer**
  the `get_trip` tool itself uses — one render truth, so this block says
  exactly what a `get_trip` call would return. With `boundTripID` supplied and
  matching the requested id, it resolves via `GetEditableTripByID` (so a
  co-planner's context comes from the trip they are editing, not their own
  trip list), then renders: trip title + id, dates, travel mode, the
  origin/return-airport endpoint summary (`tripEndpointSummary`), the trip's
  own description and who wrote it (`tripDescriptionSummary`), and every
  itinerary item with its day/city/time-of-day/category tags.
- The block is appended **after** the first, cached system block
  (`anthropic.NewCacheControlEphemeralParam()` sits on block 1 only) — so a
  trip change between turns invalidates the cache starting from this block
  onward, never the instructions/profile block, keeping prompt-cache hit
  rates high across an ongoing conversation.
- Fetched once per turn (not once per tool-loop iteration inside a turn), so
  within-turn prompt caching over multiple tool-call iterations is untouched.
- On a read failure, `tripStateBlock` is simply the empty string — the
  request proceeds exactly as it would have before this block existed;
  `get_trip` remains callable as a fallback.
- The block's own text states two supersession rules the model is told to
  follow: this block outranks anything an earlier message or the compaction
  summary claims about the itinerary, and a **tool result from this same
  turn** outranks the block itself (because a tool call earlier in the same
  turn may have just changed the trip).

`boundTripID == nil` (Plan tab): `tripStateBlock` is never computed — the
`if` guard short-circuits on the nil check before `runGetTripTool` is ever
called. No trip data reaches the prompt on that surface, matching `spec.md`'s
table.

## 3. Client-built seed message — trip detail page only

Not server-side context injection — a synthetic **user message** the client
sends as the first (or first-after-subject-change) turn of a trip's refine
conversation, so it lives in `messages`, not `System`.

- `trip_detail_screen.dart:_buildSectionSeed` (~line 2445) builds the text:
  the trip's display title and dates (first turn only — `continuing: false`),
  or "Let's turn to another part of the same trip" (continuing an existing
  conversation), followed by either the full itinerary or the one section
  under discussion (each item rendered via `_seedLine`), followed by which
  `update_itinerary_section` scope/city/day to call back with.
- Sent through `PlanNotifier.appendSectionRefinement`
  (`plan_provider.dart:1020`), which first **stubs every earlier seed**
  still in the transcript (`_supersededSeedPrefix`, "(Earlier listing for
  …)") so only the newest itinerary listing among user messages is ever
  authoritative — this is a transcript-hygiene measure independent of the
  Current Trip State block, which handles freshness *within* a single turn's
  system prompt rather than across the stored history.
- Rendered as a context chip in the panel (`displayLabel`) — its actual text
  reaches the model but is never shown to the reader.
- The very first open of an **empty** trip's refine panel uses the same
  builder with a shape-first framing (`_buildSectionSeed`'s `items.isEmpty`
  branch) instead of listing places that don't exist yet.

The Plan tab has no analogous seed: there is no trip and no section to name
yet.

## 4. Response language and compaction — both surfaces, unconditional on trip binding

- `responseLanguageInstruction(requestLocale(ctx))`
  (`plan_handler.go:580`, function defined at `plan_handler.go:1113`) appends
  a respond-in-language instruction only for a non-English locale — omitted
  entirely for English so `TestSystemPromptEnglishUnchanged` keeps passing.
  Independent of `authed` and `boundTripID`.
- When the conversation has grown long enough, `plan_compactor.go` folds
  older turns into a summary; `req.Summary` is re-inserted as a synthetic
  leading message (`plan_handler.go:343`, `summaryAsMessage`) on both
  surfaces. This is a `messages` concern, not a `System` block, and is
  unrelated to `boundTripID`.

## Anonymous sessions (either surface)

`authed == false`: the profile block (§1), the refine-instructions/trip-state
blocks (§2 — both are gated on `authed &&` as well as `boundTripID != nil`),
and `profileNotesInstruction` are all skipped. `boundTripID` itself can never
be set unauthenticated (`err != nil || !authed` refuses it in the resolver
above). Only `basePrompt` plus the locale instruction ever reaches an
anonymous turn.

## Contract Parity

Not applicable — this plan documents an existing, unchanged read path. No new
request/response fields, no new Go struct, no new Dart model.

## Verification

Not applicable — no code changes accompany this spec. The acceptance criteria
in `spec.md` are already covered by existing tests, notably:

- `TestSystemPromptEnglishUnchanged` — the English-locale prompt is
  byte-stable.
- Existing `plan_handler_test.go` / `plan_tools_extra_test.go` coverage
  around `personalizedSystemPrompt`, `runGetTripTool`, and the
  `boundTripID` access gate.
- `plan_provider_refine_append_test.dart` — seed superseding behavior.

If a future change touches any file named above, re-read this plan first —
it is the map of what currently feeds the model at turn start, and a change
to one block's refresh rule (e.g., caching profile prefs across turns) should
update this document alongside the code.
