# Spec: Booking Address Prompt

> **WHAT & WHY only.**

## Context

The itinerary already knows how to show a traveler what's near their hotel and
how long it takes to get from it to the day's first stop and back
("~15 min from the hotel" / "back to the hotel") — but only when the stay
booking carries an address with coordinates. Nothing ever asks the traveler
for that address. A stay is usually checked off ("booked") long before anyone
opens its details form, so the address is simply never entered, and the
hotel-anchor travel times stay silently absent on almost every trip.

This closes that gap at the moment it actually matters: right after the
traveler checks a stay booking item as booked, offer to add the address —
the same moment the budget prompt already offers to record the price. Once
saved, it feeds the existing hotel-anchor travel-time rows, and unlocks a new
"Nearby" action that suggests real places around the stay.

## User Stories

- As a **traveler**, when I check off my stay as booked, I want to be asked
  for its address, so my itinerary can show how far it is from my plans each
  day without me hunting for a separate form.
- As a **traveler**, I want to skip the prompt when I don't have the address
  handy yet, and be asked again next time I check that stay.
- As a **traveler** whose stay already has an address, I don't want to be
  asked again.
- As a **traveler**, once my stay has an address, I want a quick way to see
  real places nearby (food, things to do) without leaving the trip page.

## Acceptance Criteria

- [ ] Checking a stay-kind booking item as booked, when its stay has no saved
      address, opens a dialog offering to add one.
- [ ] The dialog accepts a free-typed address, or a picked real place (which
      also attaches coordinates); either way "Save" persists it against the
      stay.
- [ ] "Skip" (or dismissing) leaves the stay's address unset and does not
      block the rest of the booked flow (the existing budget prompt still
      runs).
- [ ] Checking a stay whose address is already saved never shows this prompt.
- [ ] Checking a stay that has no confirmed record yet (a derived, unbooked
      "Stay in {city}" row) and saving an address creates one, named and
      dated from that row, so it is recognized as this leg's stay from then
      on.
- [ ] Once a stay carries coordinates, its row offers a "Nearby" action that
      lists real places around it with an address and a way to get
      directions.
- [ ] A stay with no coordinates offers no "Nearby" action.
- [ ] Un-checking a stay never prompts for an address.

## API Surface

### `GET /api/v1/places/nearby`
- **Purpose:** real places near a coordinate — the "Nearby" action's backend,
  the same location-biased search the chat assistant's "what's near me"
  already uses.
- **Request:** `lat`, `lng` (required); `q` (optional free-text category —
  "coffee", "things to do" — defaults to a mixed dining/things-to-do search
  when omitted).
- **Response:** a list of places (name, address, coordinates, rating when
  known).
- **Errors:** missing or out-of-range `lat`/`lng` → bad request; upstream
  failure → server error, same shape as the existing place search endpoint.

## Data Model

No new entities. The existing accommodation's address and coordinates
(already present, already what the itinerary's hotel-anchor travel times and
map pin read) are simply written earlier — at the booked check — instead of
only through the pre-existing manual "Add details…" form.

## UI Behavior

- **Surface:** the trip page's Bookings tab and the itinerary's city sections,
  wherever a stay's checkbox appears.
- **Happy path:** traveler checks "Stay in Lisbon" as booked → address prompt
  → picks their hotel from search (or types the address) → Save → the
  existing budget prompt follows exactly as before → the itinerary's next
  load shows "~15 min from the hotel" on the day's first stop.
- **States:** Skip closes the dialog with nothing saved; a picked place shows
  an attached-location row (mirroring the existing "Add a stay" sheet) with
  an X to detach and go back to typing.
- **Nearby:** a confirmed stay's overflow menu gains a "Nearby" entry once it
  has coordinates; it opens a sheet listing places with a directions link per
  result, plus empty/error states.

## Edge Cases & Error States

- The address service is unavailable (no Places key): the dialog still
  accepts a hand-typed address with no coordinates; the "Nearby" action is
  simply never offered for that stay.
- Saving the address fails on the network: reported like any other save
  failure on this page; the checked state itself is unaffected (the flip
  already succeeded).
- A todo-only stay row's address save races a booking-todo sync: the create
  is a normal accommodation write, matched into its slot the same way a
  manual "Add details…" stay always has been (by name/address containing the
  city).

## Out of Scope

- No prompt for a personal/home address independent of a specific stay.
- No change to transport (flight/train/etc.) booking rows — address only
  applies to stays.
- The "Nearby" list is informational only this pass — no "add to itinerary"
  action from it.

## Open Questions

None outstanding.
