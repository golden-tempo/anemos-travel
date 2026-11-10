# Spec: Personalized Trip Suggestions

> **WHAT & WHY only.** See `plan.md` for the technical approach.

## Context

Home's "Somewhere new" rail and the Plan tab's opening destination rail
(specs/destination-suggestion-cards) both draw the same curated pool of a
dozen destinations in a fresh random order every visit. That spec explicitly
left "personalising which destinations are suggested" out of scope. For a
traveler who has already logged real travel history — a past trip booked
through the app, or one they typed in through specs/log-past-trip — the rail
has no memory of it: Rome can lead the very first time a traveler opens the
planner and again after their fifth trip there, while a country they have
never set foot in sits no more prominent than one they already know well.

This feature gives the two in-app rails a memory of where the traveler has
actually been, so "somewhere new" starts meaning it: a destination in a
country still new to this traveler leads, without ever hiding the ones they
already know — a traveler planning a return trip to a place they loved can
still find it by scrolling.

## User Stories

- As a **returning traveler with trip history**, I want the destination
  suggestions I'm shown to favor places I haven't been, so "somewhere new"
  is an invitation instead of a repeat of what I already know.
- As a **traveler who wants to revisit a country I loved**, I want that
  destination still reachable in the rail, just not leading it, so going back
  somewhere is never blocked by the feature meant to suggest somewhere new.
- As a **brand-new traveler with no trips yet**, I want the suggestions to
  look exactly as they always have, so a feature with nothing to personalize
  against never shows me something arbitrary in its place.
- As a **signed-out visitor on the marketing/landing page**, I want the
  destination rail there unaffected, since there is no trip history to read.

## Acceptance Criteria

- [x] On Home's "Somewhere new" rail, for a signed-in traveler with at least
      one trip whose destinations resolved to a country, every destination in
      a country the traveler has never traveled to appears ahead of every
      destination in a country they have.
- [x] The same rule applies to the Plan tab's opening destination rail.
- [x] No destination ever disappears from either rail because of this — the
      traveler can still scroll (or, on the Plan tab, the rail still carries)
      to a destination in a country they've already visited.
- [x] Within "still new" and "already visited", the order is unchanged from
      today: a fresh shuffle on every visit/remount.
- [x] A traveler with no trips, or whose trips carry no resolved destination
      country (an undated draft, a name-only logged destination, an offline
      cache from before country resolution shipped), sees the plain shuffle
      exactly as before — nothing is reordered.
- [x] "Visited" is judged the same way "Your travels" already judges it
      (specs/trips-page-insights): a trip counts once it has started, not only
      once it is finished.
- [x] The landing page's signed-out destination rail (specs/landing-redesign)
      and the home hero's 3-chip sample are unchanged — neither surface can
      read a signed-in traveler's trip history, so personalizing them is out
      of reach of this feature.

## API Surface

None. No new endpoint. The ordering is derived entirely from data the client
already holds (the trips list each surface already loads for other reasons —
"Your travels", the live-trip card).

## Data Model

No new entities and no schema change. This feature reads two things that
already exist:

- The destination pool's dozen curated entries, each of which now also names
  the one country it sits in (an app-bundled fact, not server data).
- Each trip's located destinations' countries (`CityPin.country`, resolved
  server-side today for every trip, logged or AI-planned) and whether the
  trip has started — the same two facts "Your travels" already reads to build
  its traveled/planned split.

## UI Behavior

- **Surface:** Home's "Somewhere new" rail and the Plan tab's opening
  destination rail — the two in-app rails that run inside a signed-in
  session with the traveler's trips already loaded.
- **Unaffected:** the landing page's rail (signed out, no trips exist to
  read) and the home hero's 3-chip sample (a different, smaller draw that
  this feature does not touch).
- **Happy path:** the rail draws once per mount, same as before; a traveler
  with travel history simply finds new-to-them destinations toward the front
  instead of anywhere in the shuffle.
- **No history yet:** identical to today — nothing to personalize against.

## Edge Cases & Error States

- **Every destination in the pool is in a country the traveler has already
  visited** — the rail still shows the whole pool, now in the one order
  (the plain shuffle), since there is no "still new" half to lead with.
- **A trip with a named-only destination** (specs/log-past-trip: a place
  typed by name, with no coordinates and so no resolved country) contributes
  nothing to the visited-country set — it is not mistaken for "everywhere is
  new", it is simply silent on the question.
- **An in-progress trip** counts as visited the moment it starts, matching
  "Your travels"' own traveled/planned rule, not waiting for it to finish.
- **Offline / degraded trips list** — whatever the trips list already shows
  (a cached copy, or nothing yet) is what personalization reads; this feature
  adds no new failure mode of its own.

## Out of Scope

- Any new copy, badge, or explanation on the rail saying suggestions are
  personalized — the acceptance criteria above are about order, not about
  telling the traveler why.
- Personalizing by anything finer than country (specific regions, past
  activity/interest tags, budget, trip length).
- The home hero's 3-chip sample or the landing page's rail (see above).
- Removing or hiding any destination — this feature only ever reorders.
- Any change to how a trip's destination country is resolved
  (`countryForPoint`, specs/trips-page-insights) — this feature reads that
  fact, it does not produce it.

## Open Questions

None.
