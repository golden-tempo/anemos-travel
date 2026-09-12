# Spec: Trip Edit Architecture (audit, umbrella)

> **Documentation only — no code in this feature.** This spec catalogs the
> trip data model and the trip edit surface as they exist today, and the
> recurring inconsistency patterns that have shipped against them. It does not
> propose or implement a redesign; it is the shared reference a redesign
> decision (a follow-on spec + `plan.md`) would start from. Companion doc:
> [`README.md`](./README.md) — the same material written for a first read.

## Context

Issue #602: AI-chat edits to a saved trip — adding a destination, adding or
removing a day from a destination — regularly get something wrong, or change
one thing while silently changing something else the traveler didn't touch.
That is not one bug; the friction log (`docs/friction-log.md`) records it
recurring in different shapes across at least six dogfooding rounds between
2026-08-04 and 2026-08-23, each closed by a narrower, purpose-built primitive
(`set_leg_dates`, `shift_days_from`, `replace_leg`, the itinerary-item REST
endpoints, the `spliceSection` write guards). Each fix is documented in its
own spec. **No single document says, today, what the full edit surface is,
which failure shapes are closed, and which are still open** — which makes it
hard to judge whether the next "add/remove a destination" report is a new bug
or the same open gap reappearing, and impossible to decide where to invest
next without re-deriving the whole picture from source. This spec is that
document.

## Why a Trip resists being edited safely

A saved trip has exactly two stored entities: the `trips` row and its
`itinerary_items` rows (ordered by an explicit `position` column). Everything
a traveler thinks of as the *shape* of a trip — its destinations, how many
days each gets, which items belong to which day — is not stored anywhere. It
is **re-derived on every read** from three item columns (`city` /
`day_trip_from`, `day`, `position`), independently, in at least two languages
(Go server, Dart client), by rules that must produce byte-identical answers
(`specs/server-leg-dates`). "Edit the trip" therefore never means "change one
row"; it means "change the items such that every reader's re-derivation of
destinations/days still agrees, including readers you didn't touch." Most of
the incidents below are exactly that agreement breaking.

## Data Model (current state)

- **Trip** (`trips` table) — a single version of a plan.
  - *Identity & ownership:* `id`; `user_id` (owner, immutable);
    `chat_id` — the **lineage** key. A "trip" the traveler thinks of as one
    ongoing plan is, in storage, a chain of `trips` rows sharing a `chat_id`;
    the newest row is what `ListLatestTripsByOwner` shows and what agent tools
    bind to. `create_itinerary` **inserts a new row** (a new version, or a new
    lineage when `chat_id` is empty). Every other edit tool covered below
    mutates the bound trip's existing row **in place** — versioning happens
    once, at finalize, not per edit.
  - *Descriptive fields:* `title` (mutable, defaults from `summary` or the
    first destination); `summary` / `summary_source` (agent vs. traveler
    prose, `specs/trip-description`); `start_date` / `end_date`.
  - *Endpoints:* `origin`, `origin_airport`, `return_airport` — written only
    by `CreateTrip` and `SetTripEndpoints` (the `set_trip_origin` tool),
    deliberately **excluded** from the general trip PATCH's COALESCE set, so
    a partial update can never silently move where the trip starts/ends.
  - `travel_mode` (`specs/work-style`); `status` — retired
    (`specs/retire-trip-status`); `created_at` / `updated_at` (touched by
    every mutating write via `TouchTrip`).

- **Itinerary Item** (`itinerary_items` table) — one place, in an absolute,
  trip-wide `position` order.
  - Required: `name`, `latitude`, `longitude`.
  - Optional: `place_id`, `address`, `category` (attraction/restaurant),
    `time_of_day` (morning/afternoon/evening).
  - **Grouping fields** — the ones destinations and days are re-derived from:
    `city` (where the place physically is); `day_trip_from` (set when the
    place is a day trip from a hub the traveler is staying in — the item's
    *effective* city for grouping is `day_trip_from` if set, else `city`);
    `day` (an integer, trip-relative, starting at 1). `day`'s semantics are a
    **convention**, not a constraint: the day a traveler moves between two
    cities carries the *same* day number in both, and a city's *first* item
    day is its **arrival**, its *last* its **departure** — nothing in the
    schema enforces this, only a natural-language field description
    (`itineraryLocationSchema`) that an LLM reads to decide what number to
    write.
  - **Attribution snapshots:** `local_source_name`, `local_recommendation_id`
    — set once (`specs/add-to-itinerary`), never editable, and deliberately
    *not* validated against the source pin still existing.
  - **Positions are absolute and trip-wide**, not per-day/per-city — an insert
    anywhere shifts every later item's position by one
    (`ShiftItineraryItemPositions`).

- **City Leg — a computed projection, not a row.** Neither "destination" nor
  "day N of the trip" is stored; both are re-derived from the item columns
  above by `computeTripLegs` (Go, `trip_render_legs.go`) and its hand-mirrored
  Dart twin (`leg_ranges.dart` / `trip_legs.dart`), reconciled rule-by-rule in
  `specs/server-leg-dates`. The governing rule: a leg's calendar span is
  `[its own first item day (arrival) → the NEXT leg's first item day]` — a
  leg's *end* depends only on the *next* leg's start, never on its own items,
  so that moving a place around inside a city cannot move any city's dates.
  Revisiting a city produces a second, separate run, keyed `"City#2"`.
  `specs/trip-dates-truth` is an **in-progress, not-complete** program to make
  this the *only* derivation (today a third, semi-independent copy of trip
  dates lives in `booking_todos`, refreshed on some writes and not others) and
  to eventually store a real calendar date per item rather than a
  convention-only day integer.
  - Since `computeTripLegs` (and its Dart twin) return **zero legs when the
    item list is empty**, a "structure only, no activities yet" trip has no
    destinations, no map, and hidden tabs unless the writer maintains a
    minimum "spine" — at least an arrival and a move-on anchor item per city
    (`specs/shape-before-schedule`). A destination is not representable by
    dates alone; it needs enough items to be *derived* into existence.

- **Adjacent entities that read the same derivation without owning it:**
  `booking_todos`, `accommodations`, `trip_segments` — a confirmed stay
  outranks item-derived dates for its leg's span (`specs/server-leg-dates`
  precedence rule); booking-todo dates are synced from items on load today and
  are the freshness gap `specs/trip-dates-truth` waves 4–5 target.
  `trip_checklist_items`, `trip_budgets`/`trip_expenses`,
  `trip_collaborators`, and the per-trip refine-chat session
  (`specs/trip-refine-memory`) are trip-scoped but do not participate in the
  destination/day derivation and are out of scope for this audit beyond that.

## Trip Edit API Surface (current state)

Two callers mutate a trip's items today, through disjoint surfaces that both
end up writing the same `itinerary_items` table:

### 1. Agent tools (`/api/v1/plan`, `plan_tool_registry.go`) — what issue #602 is about

| Tool | Scope of a single call | Model authors positions/days? |
|---|---|---|
| `create_itinerary` | Whole new trip version | Yes (initial write) |
| `update_itinerary_section` (`scope: day\|city\|trip`) | A day, a city+its day trips, or **the entire trip** | **Yes** — the caller supplies the section's complete replacement item list; `scope: trip` means every position and every day number in the whole trip |
| `replace_leg` | One city's places, swapped for another's | No — server assigns positions/days, preserving the leg's existing `[a..d]` span exactly |
| `shift_days_from` | Every item/stay/segment/booking-todo on or after a pivot day | No — server shifts by a delta; nothing before the pivot moves |
| `set_leg_dates` | One leg's calendar span (endpoint-anchored) | No |
| `set_trip_dates` | The whole trip's span, as a single delta | No |
| `set_trip_origin` / `set_leg_gateway` / `set_leg_transport_mode` / `set_trip_description` | One scalar field | N/A |
| `move_itinerary_item` | One item, one position | No |
| `add_accommodation` / `add_transport_segment` / `add_booking_todo` / `update_booking_todo` / `remove_booking_todo` / `migrate_booking_todo` | One adjacent-entity row | N/A |

`update_itinerary_section` is the oldest and most general tool, and the only
one with **no dedicated primitive to fall back to** for structural edits that
aren't yet covered by a narrow tool — most notably **adding or removing an
entire destination**, and reordering destinations. Every narrower tool above
(`replace_leg`, `shift_days_from`, `set_leg_dates`, …) was added specifically
to take one class of edit *away* from `scope: trip`, because free-hand
re-authoring positions/days for the whole trip is the single largest source
of the incidents catalogued below.

### 2. Direct REST API (`/api/v1/trips/{id}/items/*`, human/UI editing, no model)

- `POST .../items` — add one item (`specs/add-to-itinerary`,
  `specs/itinerary-item-editing`).
- `PATCH .../items/{itemId}` — partial update of one item's fields (COALESCE
  semantics: omitted = unchanged; attribution snapshots are not updatable).
- `DELETE .../items/{itemId}` — remove one item, closing the position gap, in
  one transaction.
- `PUT .../items/order` — reorder via a full `item_ids` list; rejected `409`
  unless it is an exact permutation of the trip's current items, so a stale
  client can never silently drop or duplicate an agent-written item.
- `PATCH /api/v1/trips/{id}` — trip-level title/dates/status (not origin/
  airports — see Data Model above).

This surface is **granular and conflict-safe by construction** — each
endpoint touches one item or requires an exact match of the current set — and
was built explicitly *not* to repeat the whole-list-PUT shape, because items
are also written by the agent and a stale full-list sync would clobber
attribution snapshots it can't see (`specs/itinerary-item-editing` decision
log).

### 3. Read paths that must reflect what an edit actually did

`GET /api/v1/trips/{id}`, the `get_trip` tool, and every mutating tool's own
result string are expected to carry **rendered, derived post-state**
(specifically the leg date ranges) rather than echo the request — a lesson
from the incidents below, not a structural guarantee (see Cross-Cutting Rules
and Open Questions).

## Known Failure Patterns

Each entry: what happened, why, what closed it, what is still open. Dates are
the friction-log entries these are drawn from.

1. **Whole-trip rewrite fragments a city / duplicates entries** (2026-08-20).
   `update_itinerary_section scope: trip` let the model re-author every
   position and day number for an eight-city trip; asked to reorder two
   cities, it resubmitted both under one selector, so the non-selected city
   survived in the untouched remainder *and* arrived again in the
   replacement — one city rendered twice, once dated, once collapsed to a
   phantom zero-night stop. **Closed** by two write guards in `spliceSection`
   (`itinerary_section.go`): `errInvalidTripScopePayload` and the
   stray-item check (`errStraySectionItems`), both firing *before* any
   delete, plus `replace_leg` as a non-authoring alternative for the specific
   case of swapping one city. A one-off repair tool
   (`itinerary_repair.go` / `make api-repair-sections`) exists because trips
   corrupted before the guard shipped needed manual cleanup — evidence this
   was a real, not hypothetical, incident. **Open:** `scope: trip` is still
   reachable and still model-authored for edits none of the narrow tools
   cover (see Open Questions).

2. **Tool reports success; the page shows the old data** (2026-08-04 and
   2026-08-05, two separate rounds). A date-move tool acted on one axis (item
   day numbers under a placeholder-trip convention) while the renderer
   computed the visible dates from a different derivation (leg ranges built
   from confirmed stays/booking-todos on every load); a delta-of-zero
   "success" then read as a real success to both the model and the anti-
   fabrication guardrail. **Closed** by end-anchored, transactional
   renumbering plus **read-back** results (a write's result string is now
   built from what the DB contains after the write, never from what the
   caller asked for), and by making a genuine zero-change call say so
   explicitly instead of reporting a generic success. **Open:** this is a
   convention every new mutating tool must follow by hand; nothing fails a
   build if a future tool's result string echoes its input instead.

3. **Ambiguous day semantics silently no-op or clobber** (2026-08-06). The
   model's mental model of whether an item's `day` meant arrival or departure
   was wrong, so its "corrective" whole-trip rewrites reproduced the existing
   (wrong) day numbers seven turns in a row with zero visible effect, while
   quietly overwriting an earlier, correct single-leg edit each time.
   **Closed** by stating the arrival/departure convention explicitly in the
   tool schema's field description, and by every write result and `get_trip`
   call now carrying rendered leg ranges instead of raw day integers.
   **Open:** the convention is enforced by a sentence in a JSON-schema
   description read by an LLM — not by any structural check — so a new
   surface that skips that sentence can reintroduce the same
   misunderstanding.

4. **Two independent (Go/Dart) derivations of the same trip's dates
   diverged** (recurring across `specs/set-leg-dates` rounds 2–5 and the
   `specs/server-leg-dates`/`specs/trip-dates-truth` program). The client
   computed rendered dates from raw item days via roughly five grouping rules
   and eight independent day→date computations; the server's agent tools
   wrote against a related but not identical model; and a third, semi-
   independent copy of the same dates lived in `booking_todos`, refreshed on
   some code paths and stale on others. **Partially closed:**
   `specs/trip-dates-truth` (umbrella, explicitly **not yet complete** — its
   own checklist is unchecked) is consolidating on one Go derivation
   (`computeTripLegs`), calendar-parity-tested 1:1 against the Dart twin, with
   server-derived booking-todos as a still-pending wave. **Open:** the
   storage flip — a real calendar date per item, day number as a derived
   mirror only — is the program's final, not-yet-executed wave; until it
   lands, "day" carries two meanings (a UI grouping key and an implicit
   calendar offset) simultaneously.

5. **A destination/day is a re-derivation, not an address — naming "what to
   change" is itself ambiguous** (ongoing design constraint, not a single
   incident). Because destinations and days aren't rows, "remove day 3 of
   Rome" requires the model, the server, and the client to independently
   agree on which items constitute "day 3 of Rome." `itinerary_section.go`'s
   `sectionKey` / `keyOfItem` / `keyOfLocation` triple is the current
   single-definition attempt (one predicate, used for both selecting items to
   replace and validating what's submitted, so selection and enforcement
   cannot drift apart from each other) — but it only covers `update_itinerary
   _section`'s day/city/trip selectors. **Open:** there is still no
   dedicated primitive for "add a whole destination" or "remove a whole
   destination" — see Open Questions.

6. **Sparse ("spine") itineraries make destinations vanish** (2026-08-15).
   Because a destination is a projection of its items, and both derivations
   early-return no legs for an empty item list, a "structure only" trip
   (cities and dates picked, no activities yet) rendered as completely blank
   — no cities, no map pins, hidden tabs — even though the trip's `start_date`
   /`end_date` and the traveler's stated cities were saved correctly.
   **Closed** by requiring a minimum "spine" of anchor items (arrival + move-
   on per city, `specs/shape-before-schedule`) and refusing saves that would
   produce an unrepresentable shape (one-sided dates, a dated trip with an
   undated place, a mix of tagged/untagged places). **Open:** the invariant is
   enforced by prompt instructions plus validation inside `create_itinerary`/
   `update_itinerary_section` specifically — a future write path bypassing
   both could reintroduce a blank-looking trip.

## Cross-Cutting Design Rules

Extracted from the codebase's own accumulated comments and the friction log,
stated once here so they read as decisions rather than tribal knowledge:

- A **section** (day/city/trip scope) is a slice of items that already
  exist — it cannot be conjured. Filling an empty day is a city-scoped
  rewrite (add items tagged with that day), not a day-scoped one.
- A write's **result must echo actual, read-back post-state** — especially
  rendered leg date ranges — never the request it was given. A genuinely
  no-op call must say so explicitly, distinguishably from a failure.
- Wherever the server *can* own a derived value (a swapped leg's position/day
  assignment, a shifted suffix's deltas), it should — a tool description that
  asks the model to "preserve the existing day numbers" is a request; a tool
  that drops caller-sent values and assigns its own is a guarantee.
- A rejecting **guard must run before any delete** in a replace-style write,
  so a rejected edit always leaves the trip byte-identical to before the
  call, never partially applied.
- Any field added to the item/trip shape must land in the Go struct and the
  Dart model in the same change (the repo-wide contract-parity gate,
  `specs/README.md`) — Go/Dart drift is independently the most-cited bug
  class in this codebase.
- The **same predicate** must decide both "which items does this edit target"
  and "does this submission stay inside that target" — two independently
  maintained predicates for the same question is exactly what let the
  2026-08-20 duplication through.

## Open Questions

None of these are decided here; they are what a follow-on redesign spec would
need to resolve before any code changes.

- [NEEDS CLARIFICATION] Should `update_itinerary_section scope: trip` be
  deprecated once the common structural edits have dedicated primitives, or
  does it remain the necessary (model-authored, guard-protected) fallback for
  edits with no primitive yet — e.g. reordering destinations, splitting or
  merging a hub run?
- [NEEDS CLARIFICATION] Is "add a destination" / "remove a destination" worth
  first-class primitives (e.g. `add_leg` / `remove_leg`, mirroring
  `replace_leg`'s server-owns-positions-and-days approach), so the model never
  hand-authors positions/days for a structural change? If so, what happens to
  the nights a removed destination held — reclaimed by the previous city
  (`shift_days_from`'s semantics) or left as an explicit gap for the traveler
  to resolve?
- [NEEDS CLARIFICATION] Does completing `specs/trip-dates-truth`'s final wave
  (a real stored calendar date per item, day number as a pure derived mirror)
  unblock a safer add/remove-day primitive by removing the arrival/departure
  day-number ambiguity entirely — and should that wave be resequenced ahead of
  any new destination/day primitive rather than after it?
- [NEEDS CLARIFICATION] Should the (hub, day) section-key predicate
  (`sectionKey`/`keyOfItem`/`keyOfLocation`) become an enforced, harder-to-
  bypass invariant — e.g. a single shared package/type consumed by every
  write path — rather than a Go-only helper a new file could fail to call?
- [NEEDS CLARIFICATION] Is there appetite for standing structural tests over
  `spliceSection` / `computeTripLegs` (e.g. "for any valid before-state and
  any single edit, every *other* destination's span is byte-identical
  afterward") as a general regression guard, versus the current model of one
  hand-written fixture per past incident?

## Out of Scope

- Implementing any of the Open Questions above, or any redesign of the data
  model or edit API — this is the audit a redesign decision would start from.
- The trip refine chat's own memory/session model (`specs/trip-refine-memory`)
  and collaborator access (`specs/collaborator-refine`) — separate, already-
  speced concerns that don't affect item/leg derivation.
- Booking-todo, accommodation, budget, and checklist data models beyond how
  they consume the leg derivation (their own specs cover them).
- Completing `specs/trip-dates-truth` — referenced here as prior art and as
  the source of an open question, not restated or re-scoped.
