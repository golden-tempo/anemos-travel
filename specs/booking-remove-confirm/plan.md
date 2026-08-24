# Plan: Removing a Booking Asks First

> **HOW.** See `spec.md` for what and why, and `../../CLAUDE.md` for repo
> conventions referenced below.

## Technical Approach

Flutter only. The decisive finding is that **every fact the warning needs is
already on the client or already on the wire** — the app was simply throwing
one of them away:

| Stake | Where it already lives |
|---|---|
| `booked` | on `BookingTodo`, `Accommodation`, `TripSegment` alike |
| linked budget expense | `expensesProvider`, already loaded and already matched on `sourceId` by `_removeLinkedAutoExpense` and the booked-expense prompt |
| saved shortlist count | `booking_options` in the trip payload (`trip_handler.go` ships it to every non-viewer) — **received and dropped**, because the Dart `Trip` never modelled it |

So no endpoint, no query, no migration. The three stakes are not newly
invented either: they are exactly the ones `bookingTodoStateRefusal`
(`plan_tools_extra.go`) already refuses the *agent* over. The point of this
change is that both paths to the same destructive act now warn about the same
things, so there is one answer to "what does removing a booking cost", stated
in two places that agree rather than one place that is silent.

### Why a projection and not a `BookingOption` model

`Trip.bookingOptionTodoIds` keeps only each option's `booking_todo_id`. The
app reads exactly one thing from the shortlist today — how many hang off a
booking — and a partial `BookingOption` with four of its sixteen fields would
read as the whole object and invite someone to trust it. The field is named
for what it is, and when a shortlist UI needs the rest, it becomes a real
model and this goes with it.

It round-trips through `toJson` deliberately. `TripCache` stores `toJson` and
reads it back, so a projection that only parsed inbound would make a cached
(offline) trip report zero saved options — the dialog would promise the
removal costs nothing at the exact moment it costs the most. Lossless for
every consumer that exists, because there is no other one.

### Why the ask is unconditional

All three deletes are `DELETE FROM` with no soft delete anywhere in the schema
(`accommodations.sql`, `booking_todos.sql`), so there is nothing to recover
from and no basis for skipping the ask on a "cheap" row. What varies is the
*content*: a row carrying nothing gets the plain ask, and nothing is invented.

### Why stays and segments pass `savedOptions: 0`

`booking_options.booking_todo_id` is the only `ON DELETE CASCADE` in migration
00065. The pointers back at a confirmed record —
`promoted_accommodation_id`, `promoted_segment_id` — are `ON DELETE SET NULL`,
so removing a stay or a segment unlinks a promotion and destroys nothing. The
literal is passed with a comment at each call site rather than hidden behind a
default, so the reason is at the place it is claimed.

## Go API Changes

None.

## Flutter Changes

`src/packages/flutter-app/lib/`:

- **`models/trip.dart`** — `bookingOptionTodoIds` (`@JsonKey` with explicit
  `fromJson`/`toJson`, defaulting to `const []`) plus `savedOptionsFor(id)`,
  the one place the count is derived. Regenerate with
  `dart run build_runner build --delete-conflicting-outputs`; **never
  hand-edit `trip.g.dart`**. (The `make flutter-build-models` target lacks the
  delete-conflicting-outputs flag and fails on a dirty build cache.)
- **`widgets/trip_detail/bookings_tab.dart`** — `_confirmRemoval` (the one
  dialog, following the house `showDialog<bool>` + `AlertDialog` + error-tinted
  `FilledButton` pattern from `_delete`/`_leaveTrip` in
  `trip_detail_screen.dart`) and `_hasLinkedExpense`. Wired into all three of
  `_deleteTodo`, `_deleteStay`, `_deleteSegment`, each of which now returns
  early unless confirmed and re-checks `mounted` after the await.
- **`l10n/app_en.arb` + `app_es.arb`** — `bookingRemoveTitle` (placeholder),
  `bookingRemoveBody`, `bookingRemoveSavedOptions` (ICU plural),
  `bookingRemoveLinkedExpense`, `bookingRemoveBooked`. Cancel and Remove reuse
  the existing `commonCancel` / `bookingCardRemove`. Regenerate with
  `make flutter-gen-l10n`.

`_hasLinkedExpense` swallows a failed expense read and answers "no": a warning
that cannot be substantiated is not worth refusing a delete over, and the
dialog still asks.

## Contract Parity

No wire contract changes. The client now reads `booking_options[].
booking_todo_id`, which `BookingOptionResponse` (`booking_option_handler.go`)
already sends as a non-optional `string`.

## Testing

`test/trip_detail_booking_remove_confirm_test.dart`, 14 tests — 10 widget
tests through the real `TripDetailScreen` and 4 unit tests on the projection:

ask-before-delete and cancel-deletes-nothing · confirm deletes · a row
carrying nothing gets no invented warnings · the shortlist count, plural and
singular · a linked expense warned about · an expense pointing at a *different*
row not warned about · a booked row's provider warning · stays ask (and claim
no shortlist) · segments ask, titled by route · `savedOptionsFor` counts per
booking · it parses the payload the server actually sends · a viewer payload
with no shortlist counts zero rather than throwing · and the count survives the
`TripCache` round-trip.

Per `CLAUDE.md`, no test asserts anything font-dependent.

---

# Reservations sort by date

## Technical Approach

`othersByRun` in `screens/trip_detail_derivation.dart` is the one place a
city's reservations are collected, so it is the one place they are ordered.
Sorting at the source means the rendered rows and every count that walks
`bookingSlotEntries` read the same list and cannot disagree about order.

Three details the sort has to get right:

- **Dart's `List.sort` is not stable.** Same-day reservations could otherwise
  swap between builds, so the comparator falls back to the row's incoming
  index (server `position, created_at`) captured before the sort.
- **Undated rows sort last**, keeping their relative order. `depart_date` is
  optional, and a row with no date has no position in a date sequence; putting
  it anywhere among the dated ones would be inventing one.
- **Per run, not per label.** A revisited city owns two runs; each sorts alone,
  after the existing claim logic has decided which run a row belongs to. The
  sort never moves a row between runs.

## Go API Changes

`plan_tools_extra.go` — `add_booking_todo`'s `depart_date` description. It
said "Optional YYYY-MM-DD the booking is for", which is why the agent has been
omitting it and writing the date into the title instead. It now says to set it
whenever the booking is for a particular day, and that the trip page orders a
city's bookings by it. Description text only: no schema, no handler, no
migration, and `depart_date` stays out of `Required`.

## Flutter Changes

`screens/trip_detail_derivation.dart` only — the sort described above,
immediately after the claim loop. No widget, provider, or model change: the
Bookings tab already renders `slot.others` in list order.

## Testing

`test/trip_detail_derivation_test.dart`, 3 new tests in the existing city
grouping group: the screenshot's exact out-of-order case sorting correctly
with same-day ties preserved; undated rows last and in order; and each city
sorting alone.

One existing test moved — *"a revisited city claims once, into the dated
run"*. It is about WHICH run each reservation claims, and its expectation
happened to encode arrival order; the undated row now sorts behind the dated
ones. Updated with a note pointing at the sorting tests, so it keeps testing
claiming rather than silently re-pinning order.
