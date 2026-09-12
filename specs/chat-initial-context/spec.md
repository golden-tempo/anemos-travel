# Spec: Chat Initial Context

> **Documentation exception:** this spec does not propose new behavior. It
> describes, for review, what the app **already does today** — the context an
> already-shipped `/api/v1/plan` call assembles before the model ever sees a
> traveler's message. Nothing here is a file name or a code snippet by
> accident: this is the one spec whose job is to say precisely what already
> ships, so `plan.md` is the primary deliverable, not a follow-on. There is no
> `tasks.md` — there is nothing queued to build; any gap this review surfaces
> becomes its own follow-up spec.

## Context

Ferdinand (the planning agent) is stateless between HTTP calls: every
`POST /api/v1/plan` rebuilds its context from scratch out of what the database
and the request carry, then throws it away when the response finishes
streaming. Two different screens open that conversation, and each one gives
the agent a different starting point:

- **The Plan tab**, a fresh, unbound conversation — no trip exists yet, so
  there is nothing trip-shaped to load. This is the request Brian's summary
  calls "the trip planning page when it's a fresh chat for a trip."
- **A trip's detail page**, a conversation about one already-saved trip,
  reopened potentially days or weeks later — "the trip detail page for an
  existing chat."

Brian's stated understanding is that the traveler's profile loads at the start
of both, and the trip's own data loads additionally for the trip-detail case.
That is correct, and is worth writing down precisely because it is assembled
across several files with different refresh rules, and because "at the start"
undersells it — most of it is rebuilt on **every turn**, not just the first.
This spec is the read-time counterpart to specs/trip-refine-memory (which
covers *persistence* — where a turn is saved) and specs/active-profile /
specs/traveler-preferences (which cover what the profile *contains*); none of
those specs describe the assembly process end to end, which is the gap this
fills.

## What Loads, By Surface

| Context block | Plan tab, fresh chat | Trip detail, existing chat |
|---|---|---|
| Traveler profile (budget, pace, interests, gender, home airport, work style, fitness routine, outdoor intensity, companions, baggage tier, free-text profile notes) | ✅ signed-in only | ✅ signed-in only (identical) |
| Profile-keeping instruction (tells the agent how to save new durable facts) | ✅ signed-in only | ✅ signed-in only |
| Response-language instruction | ✅ non-English locale only | ✅ non-English locale only |
| Refine-mode instructions (how to apply an in-place edit: sections, leg replacement, date tools) | ❌ | ✅ |
| This trip's travel mode | ❌ | ✅ when set |
| **Current Trip State** block — the trip read fresh from the database this turn: title, dates, travel mode, origin/return airports, description (and who wrote it), and every itinerary item with its day/city/time-of-day/category | ❌ | ✅ |
| Client-built seed message naming the trip and listing the section under discussion | ❌ (nothing to name yet) | ✅ once per subject change |
| Compacted-conversation summary | ✅ once the conversation is long enough | ✅ once the conversation is long enough |

An anonymous session on either surface gets none of the profile or
trip-specific rows — only the base instructions, a plain planning agent with
no memory of who is asking.

## User Stories

- As **Brian**, reviewing what the agent is told before it ever answers, I
  want a single place that states which facts load on which screen, so I can
  confirm the behavior matches what the product is supposed to do.
- As a **returning traveler opening a trip I saved weeks ago**, I want the
  agent to already know my preferences and to be looking at the trip exactly
  as it stands today, so I don't have to restate either.
- As a **traveler starting a brand-new trip idea**, I want the agent to already
  know my preferences, so a first-time planning conversation is still
  personalized even though there is no trip yet to describe.
- As a **traveler who changed my trip in one browser tab**, I want a
  conversation about that trip in another tab to see the change on its very
  next reply, not a copy from when the chat opened.

## Acceptance Criteria — current, observable behavior

- [x] A signed-in traveler's saved preferences (whichever of the fields above
      are set) are present in the system prompt on every turn, on both
      surfaces, whenever the account has a preferences row — never only on
      the first turn of a conversation.
- [x] The profile-keeping instruction (how to call `save_preferences` with an
      updated, de-duplicated notes field) is present on every authenticated
      turn, on both surfaces.
- [x] On the Plan tab, no trip data is loaded — a fresh chat has no `trip_id`
      to load one for.
- [x] On the trip detail page, the conversation is only ever assembled once
      the caller's edit access to that specific trip has been verified for
      this request; it is refused otherwise.
- [x] On the trip detail page, the Current Trip State block is re-read from
      the database on every turn, never only once when the panel opened — a
      change made through the trip page mid-conversation (or by a co-planner,
      or in another tab) is visible on the very next reply.
- [x] The Current Trip State block states explicitly that it supersedes
      anything an earlier message in the same conversation claimed about the
      itinerary, and that a tool result from *this* turn supersedes the
      block itself.
- [x] Opening a saved trip's chat for the first time, or switching what part
      of the trip is being discussed, sends one seed message naming the trip
      (first time only) and listing the section under discussion; an earlier
      seed's listing is marked superseded rather than removed, so exactly one
      itinerary listing in the transcript is ever authoritative.
- [x] Reading the traveler's profile is best-effort: a lookup failure is
      treated the same as "no profile row yet" — the agent still answers,
      without personalization, rather than failing the turn.

## Data Model

No new entities. This spec cites, without changing, `traveler_preferences`
(specs/traveler-preferences, specs/active-profile, specs/traveler-baggage) and
`trips` + `itinerary_items` (specs/trip-model). See `plan.md` for exactly which
columns feed which line of the prompt.

## Edge Cases & Behavior Worth Flagging For Review

These are true today and are **not** proposed changes — flagged here because
Brian's summary implies a symmetry ("for both of these the user's travel
profile should be loaded... in addition to the traveler profile... the trip
metadata") that the Plan tab does not fully deliver once a trip exists:

- **A trip created from the Plan tab keeps no live link to it afterward.**
  `create_itinerary` saves the trip, but the fresh-chat conversation itself
  never starts sending a `trip_id` — that only happens when the same trip is
  later reopened from its own detail page. So continuing to talk about that
  trip in the *same* Plan-tab conversation runs on the in-message copy
  (whatever the last tool result or message said), not a fresh per-turn read.
  The trip detail page is the only surface with the live Current Trip State
  block.
- **Anonymous sessions get no profile and no trip state** on either surface,
  by construction — there is no account to read one from.
- **A degraded database** (persistence offline) drops the profile, the
  profile-keeping instruction is still issued but has nothing to act on
  usefully, and a trip detail conversation cannot bind to a trip at all
  (the edit-access check itself requires the database).
- **The client-built seed message and the Current Trip State block overlap on
  purpose.** The seed sets *what the conversation is about* (which section,
  first-turn framing) and is sent once; the state block keeps *the facts*
  fresh every turn. Removing either changes different things: dropping the
  seed loses the subject framing, dropping the state block reintroduces the
  stale-copy problem the block exists to solve.

## Out of Scope

- Any change to what is loaded, on either surface. This spec documents; it
  does not propose.
- The write path — how the agent updates the profile (`save_preferences`) or
  distills it after a trip is created (`profile_distiller.go`). That is the
  inverse of this spec and belongs in specs/active-profile /
  specs/traveler-preferences.
- Conversation *persistence* (where a turn is saved, resumed, or compacted) —
  covered by specs/trip-refine-memory, specs/continue-where-you-left-off, and
  specs/conversation-compaction.

## Open Questions

- [NEEDS CLARIFICATION] Is the Plan-tab asymmetry above (no live trip-state
  read-back once a trip exists, until the traveler reopens it from the trip
  page) intended, or should a fresh-chat session that has just created a trip
  start sending `trip_id` on later turns in the same tab?
