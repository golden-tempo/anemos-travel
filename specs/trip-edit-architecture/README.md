# Trip Data Structure & Edit API — a plain-language walkthrough

This is the reviewable write-up requested in issue #602. The exhaustive,
citable version of everything below lives in [`spec.md`](./spec.md) in this
same directory; this file is the "read this first" summary. **Nothing here
changes any code** — it's documentation of what already exists, so the next
decision about "make editing a trip more consistently seamless" can be made
from one place instead of re-derived from a dozen files and specs.

## The one idea that explains most of the bug reports

A saved trip is stored as almost nothing: a `trips` row, and a flat, ordered
list of `itinerary_items` rows. There is no "destinations" table and no
"days" table. **A destination and a day are both things the app calculates,
fresh, every time it reads the trip** — from three columns on each item
(`city`/`day_trip_from`, `day`, and its position in the list) — and it does
that calculation *twice*, once in the Go server and once in the Flutter app,
using rules that have to agree with each other exactly.

So "the AI added a destination and something else broke" is almost never the
AI breaking one thing on purpose. It's the AI (or a tool, or the client)
changing the raw item list in a way that's valid on its own, but that shifts
what the *next* calculation of "which items make up Rome" or "which day is
day 3" comes out to. Six different real incidents below are all this same
shape wearing different clothes.

## What a Trip actually looks like today

- **Trip row:** owner, title, optional dates, optional origin/return
  airports, a `chat_id` that groups versions of "the same ongoing plan"
  together (each *finalize* — `create_itinerary` — writes a brand-new trip
  row; every other edit below changes the existing row in place, it does not
  version).
- **Itinerary items:** an absolute, trip-wide ordered list. Each item has a
  name, coordinates, and optionally a category, time of day, city, "day trip
  from" hub, and a `day` number. The `day` number's meaning (a city's first
  day is its arrival, its last is its departure, the changeover day carries
  the same number on both sides) is a *convention* written into a tool's
  description for the AI to read — nothing in the database enforces it.
- **Destinations ("legs") and their date ranges are computed, not stored** —
  by `computeTripLegs` on the server and a hand-mirrored twin in the Flutter
  app. A destination's last day is defined as "the day before the *next*
  destination starts," specifically so that editing a place inside a city
  can never accidentally move that city's dates.

## What "editing a trip" means today

Two different front doors write to the same item list:

1. **The AI chat, via `/api/v1/plan`.** This is a growing set of narrow,
   single-purpose tools (move a city's dates, swap one city for another,
   shift everything after a point by N days, change the transport mode for
   one leg, …) plus one very old, very general tool —
   `update_itinerary_section` — that can be asked to rewrite an entire day, an
   entire city, or **the entire trip's item list at once**, with the AI
   itself deciding every position number and every day number. Every narrow
   tool that exists today was built specifically to take one *kind* of edit
   away from that whole-trip rewrite, because letting the model hand-author
   the whole list is where almost every incident below started.
2. **The trip page UI, via REST endpoints** (`PATCH`/`DELETE` one item,
   reorder the list). These are deliberately small and safe: they touch one
   item, or require the reordered list to be an exact match of what's
   currently there (rejecting a stale reorder instead of guessing).

## Six real incidents, and what closes each one

| # | What happened | Root cause | Fixed by | Still open |
|---|---|---|---|---|
| 1 | A city got duplicated — once with dates, once collapsed to a fake "0 nights" | Rewriting the whole trip let the model resubmit a city it wasn't supposed to touch, alongside the untouched copy already kept | Guards that reject a bad whole-trip rewrite *before* deleting anything, plus a dedicated "swap this city" tool that never touches other cities | The whole-trip rewrite tool still exists as a fallback for edits nothing else covers |
| 2 | The AI said "done" seven times; nothing visibly changed | The tool moved a different axis than the one the screen actually displays | Every write now reports back what the database actually contains, not what was asked for; a true no-op says so explicitly | This is a rule every *future* tool has to remember to follow — nothing enforces it automatically |
| 3 | The AI kept "fixing" a date and silently undoing a real earlier fix | It had the wrong mental model of what a "day" number means | The convention is now spelled out to the AI, and every result shows real calendar-ish ranges instead of raw day numbers | The convention still lives in a sentence the AI has to read, not a rule the system enforces |
| 4 | The same trip's dates disagreed across the server, the app, and the booking checklist | Three separate places computed dates from the raw data, slightly differently | An in-progress project (`specs/trip-dates-truth`) is consolidating on one server-side calculation, checked to match the app's exactly | Not finished — the final step (storing a real date instead of just a day number) hasn't shipped yet |
| 5 | No clean way to say "delete this destination" or "add one" | Destinations aren't rows you can point at — they're recalculated from item tags | A shared definition of "which items count as this city/day" is used both to pick items and to check what's submitted, so the two can't disagree | There is still no dedicated "add/remove a whole destination" tool — see below |
| 6 | A trip with only cities-and-dates picked (no activities yet) rendered completely blank | An empty item list computes to zero destinations | The AI is now required to write a minimal skeleton (an arrival + a move-on stop per city) so a bare-bones trip still shows up | This safety net lives in prompt/validation logic, not a hard schema rule |

## The open decisions (this is the part that needs your call)

This document deliberately stops short of proposing a redesign — that's the
next spec, once these are answered:

1. **Should the "rewrite the whole trip" tool go away?** It's the common
   ancestor of most incidents, but it's also the only thing that currently
   covers edits with no dedicated tool yet (reordering cities, splitting a
   city into two visits, etc.).
2. **Should adding/removing a whole destination get its own tool** — the way
   "swap one city for another" already does — so the AI never hand-writes
   position/day numbers for that kind of change? And if a destination is
   removed, do its nights get absorbed by the previous city automatically, or
   left as a gap the traveler resolves?
3. **Should the in-progress "one source of truth for dates" project be
   finished first?** Its last step — storing a real date on each item instead
   of just a day number — would remove the arrival/departure ambiguity that
   caused incident #3 and #4, which might make a destination add/remove tool
   meaningfully simpler and safer to build.
4. **Should the "which items belong to this city/day" definition be harder to
   bypass** — right now it's a shared helper function that every write path
   has to remember to call, the same way the pre-guard code that caused
   incident #1 simply didn't.
5. **Is it worth adding automated tests that check a general property** — "any
   single edit leaves every *other* destination's dates untouched" — instead
   of relying on one hand-written regression test per past incident?

## Where to look next

- The full catalog with file names, function names, and friction-log
  citations: [`spec.md`](./spec.md) in this directory.
- The in-flight, not-yet-finished consolidation of trip dates:
  `specs/trip-dates-truth/spec.md`.
- The most recent narrow tool built to take an edit away from the whole-trip
  rewrite tool: `specs/itinerary-item-editing/spec.md` (human/UI editing) and
  `src/packages/api/replace_leg_splice.go` (the AI-facing "swap one city"
  tool's own account of the incident it was built to prevent).
- The running list of real incidents this document draws from:
  `docs/friction-log.md`.
