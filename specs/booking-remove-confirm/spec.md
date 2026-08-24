# Spec: Removing a Booking Asks First

> **WHAT & WHY only.** See `plan.md` for the technical approach.
>
> This lane also carries a second, smaller Bookings-tab fix — a city's
> reservations now render in date order. It rides here rather than in its own
> lane because `CLAUDE.md` allows at most one in-flight lane touching the
> `trip_detail_screen.dart` family, and both changes land in it. See
> **Reservations sort by date** at the end.

## Context

Removing anything from the Bookings tab took one tap of an overflow menu and
happened instantly, with no ask and no undo. Every one of those removals is a
hard delete server-side. Brian removed a booking by accident; it was gone.

There is already a considered answer in this codebase for how dangerous this
is — it just isn't applied to people. The **agent** may not remove a booking
that carries traveler state: it is refused and told the stakes
(`bookingTodoStateRefusal`), and must ask the traveler and retry with
`confirm: true`. A traveler using the UI got no such protection on the same
destructive act. This closes that asymmetry from the other side.

The ask is not a speed bump. It says what the removal costs beyond the row
itself, because the expensive parts are invisible: a saved shortlist is
deleted along with the booking it hangs off, and a linked budget expense is
*not* — it survives, still counted in what you've spent, pointing at a booking
that no longer exists.

## User Stories

- As a **traveler**, I want to be asked before a booking is removed, so a
  mis-tap in an overflow menu doesn't destroy something.
- As a **traveler who compared three hotels**, I want to be told that removing
  the booking deletes that shortlist too, because nothing else would tell me
  and I cannot get it back.
- As a **traveler with a budget**, I want to know a linked expense will stay
  in my spend after the booking is gone.
- As a **traveler with a real reservation**, I want it made clear that
  removing the row does not cancel anything with the provider — so I don't
  believe I have cancelled a hotel I have not.
- As a **traveler**, I don't want to be warned about things that aren't true
  of the booking I'm removing.

## Acceptance Criteria

- [ ] Removing a booking, a stay, or a transport segment opens a confirmation
  naming the thing being removed, and nothing is deleted until it's confirmed.
- [ ] Cancelling — or dismissing the dialog with Escape, the back gesture, or
  a tap outside — removes nothing and leaves the row in place.
- [ ] The dialog says the removal cannot be undone.
- [ ] When the booking has saved shortlist options, the dialog says how many
  are deleted with it, reading correctly for one ("Its 1 saved option is
  deleted with it") and for several.
- [ ] When a budget expense is linked to the row, the dialog says it stays in
  the budget, still counted in spend, with nothing pointing back at a booking.
- [ ] When the row is marked booked, the dialog says removing it cancels
  nothing with the provider and only the traveler can cancel a real
  reservation.
- [ ] A booking carrying none of the three gets the plain ask, with no
  warnings invented.
- [ ] Removing a stay or a segment never claims a shortlist is at stake —
  saved options belong to booking checklist rows, and the pointers back at a
  stay or a segment are cleared rather than deleted.
- [ ] A transport segment is named by its route ("JFK → Paris"), falling back
  to its travel mode when neither end is named.
- [ ] Auto (system-derived) bookings are unaffected — they have no remove
  action to begin with, and viewers can't remove anything.
- [ ] Works offline-cached: a trip loaded from cache still reports its saved
  options correctly rather than promising the removal is free.

## API Surface

None. No endpoint is added or changed — the shortlist the warning counts is
already in the trip payload, and the expense link is already loaded for the
Budget tab.

## Data Model

None server-side. The client starts reading a part of the trip payload it was
previously discarding.

## Out of Scope

- **No undo.** The delete stays a hard delete; this makes it deliberate rather
  than reversible. Undo would need the server to keep the row (and its
  CASCADEd shortlist) somewhere recoverable, which is a much larger change.
- **Recovering the booking already lost.** It was hard-deleted with no soft
  delete anywhere in the schema; there is nothing to restore it from.
- **Bulk removal**, which does not exist today.

---

# Reservations sort by date

## Context

A city's reservations rendered in the order they were written, which for
agent-created rows is effectively arbitrary. A real trip page showed Amsterdam
as *Aug 25, Aug 25, Aug 24, Aug 26, Aug 24* — a dated list in no order, which
the eye reads as broken. They should read in the order the traveler will
actually do them.

## User Stories

- As a **traveler**, I want a city's reservations listed earliest-first, so
  the list matches the shape of my days there.
- As a **traveler**, I don't want the order to change between visits to the
  page.

## Acceptance Criteria

- [ ] Within a city, reservations render earliest date first.
- [ ] Two reservations on the same day keep a stable relative order — the same
  one every render.
- [ ] A reservation with no date renders after every dated one, and two
  undated ones keep their relative order.
- [ ] Sorting is per city: one city's later reservation never outranks
  another city's earlier one, and no reservation moves between cities.
- [ ] A revisited city's runs each sort independently, and every reservation
  still attaches to exactly one run.
- [ ] Counts and filter chips continue to agree with what is rendered.

## Known limitation

The order comes from the row's `depart_date`. That field is **optional**, and
nothing on the card displays it — which is why the agent has been writing
human-readable dates into the title text ("Book Rijksmuseum timed entry (Aug
24)"). A reservation whose date exists only in its title cannot be placed in
time and sorts to the end with the other undated rows.

Reading a date back out of the title was rejected: `docs/zen.md` is explicit
that data semantics live in schema and types, never in a convention someone
must remember, and a title is free text the traveler can edit. The fix is to
make the field reliably present instead — the agent's `depart_date` is no
longer described as merely "optional", and now says why setting it matters.
Rows created before that change keep whatever they were given.

## Out of Scope

- **Showing the date on the row.** It would make the ordering legible and let
  the agent stop smuggling dates into titles, but it is a visual change to a
  dense row and wants a design pass.
- **Backfilling `depart_date`** on existing rows by parsing their titles.
- **Sorting anything else** — Other bookings stays hand-orderable by drag,
  which is a traveler's explicit choice and must not be overridden.
