# Spec: Trip Chat History

> **WHAT & WHY only.** See `plan.md` for the technical approach.

## Context

`specs/trip-refine-memory` gave a trip exactly one running conversation, and
"New chat" threw the old one away outright — a deliberate choice at the time
("there is one running conversation"), but travelers who reset the chat to
change direction (a different pace, a different budget) lose the earlier
discussion for good, with no way back if the new direction doesn't work out
either. This (#639) keeps the last few conversations instead of discarding
them: "New chat" retires the running conversation into a small history rather
than deleting it, and a "Previous chats" picker brings any of them back.

## User Stories

- As a **traveler editing a trip**, I want "New chat" to save my old
  conversation instead of deleting it, so that starting over doesn't cost me
  the discussion I already had.
- As a **traveler**, I want a "Previous chats" list beside "New chat", so that
  I can go back to an earlier conversation about this trip.
- As a **traveler**, I want the trip to only ever keep a handful of past
  conversations, so that history stays a quick list rather than an
  ever-growing archive.

## Acceptance Criteria

- [ ] "New chat" retires the current conversation into "Previous chats" rather
      than discarding it; the trip stops advertising it as the running
      conversation, exactly as before.
- [ ] "Previous chats" lists the trip's archived conversations for the caller,
      most recently active first, each with a preview of its last reply and
      how long ago it was active.
- [ ] Picking a previous chat brings back its full transcript as the running
      conversation; sending a message continues it. The conversation it
      replaces is not lost — it becomes the newest history entry.
- [ ] At most 5 archived conversations are kept per trip per traveler; once a
      6th would be added, the oldest is dropped.
- [ ] Each traveler's history is their own: an owner and a collaborator on the
      same trip never see each other's previous chats, matching
      `specs/trip-refine-memory`'s existing per-caller conversation.
- [ ] Deleting a trip deletes its history along with its running conversation.

## API Surface

### `GET /api/v1/trips/{id}/refine-chat/history`
- **Purpose:** the caller's own archived conversations about this trip.
- **Request:** authenticated; the caller must be allowed to edit the trip.
- **Response:** up to 5 entries, most recently active first — each an id, a
  preview of the last reply, a message count, and when it was created/last
  active.
- **Errors:** 404 when the trip is unreachable to this caller (same
  indistinguishable 404 as the rest of this surface).

### `POST /api/v1/trips/{id}/refine-chat/history/{historyId}`
- **Purpose:** resume one archived conversation — it becomes the running one.
- **Request:** authenticated; caller must be allowed to edit the trip; the
  history entry must belong to the caller and this trip.
- **Response:** the resumed conversation, in the same shape as
  `GET /trips/{id}/refine-chat`. The conversation it replaces is not deleted —
  it becomes the newest history entry.
- **Errors:** 404 when the trip is unreachable, or the id does not name one of
  the caller's archived conversations about it.

### `DELETE /api/v1/trips/{id}/refine-chat` (behavior change, no wire change)
"New chat" now retires the conversation into history instead of deleting it,
pruning the oldest entry past the 5-conversation cap. Idempotent as before.

## Data Model

- Extends `specs/trip-refine-memory`'s **trip refine session**: still one
  *running* conversation per (traveler, trip), but a traveler may also hold up
  to 5 *retired* ones for the same trip, kept only as history — one of them can
  become the running conversation again, but never two at once. Retired
  conversations share the running one's retention: deleted with the trip, not
  pruned on age.

## Out of Scope

- Renaming or otherwise labeling a saved conversation — history is ordered by
  recency only, with no picker beyond "most recent five."
- Any change to `specs/continue-where-you-left-off`'s free (non-trip-bound)
  planning chats, which already have their own list.

## Open Questions

None.
