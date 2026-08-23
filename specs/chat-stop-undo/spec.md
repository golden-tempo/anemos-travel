# Spec: Stop Undoes the Turn

> **WHAT & WHY only.** See `plan.md` for the technical approach.

## Context

Stopping a reply almost always means the traveler wants to *change what they
asked* — they hit send, watched the agent start answering the wrong question,
and killed it. Until now stop left the mistake behind: the message stayed in
the transcript with a truncated half-answer under it, and rephrasing meant
retyping the sentence from scratch while the abandoned pair sat above it
forever. The stop button was an emergency brake when what people reach for is
an undo.

This makes stop mean undo. The message comes out of the chat and goes back
into the composer, cursor at the end, exactly as it was — so the next thing
the traveler does is edit one word and send again.

No new button, no new surface: the same stop control that already appears
while a turn streams with an empty composer.

## User Stories

- As a **traveler**, when I stop a reply I want my message back in the text
  box so I can fix a word and resend, instead of retyping it.
- As a **traveler**, I want the stopped exchange to disappear from the chat,
  so my transcript is the conversation I meant to have.
- As a **traveler who attached photos**, I want them back on the composer too
  — re-picking four images is worse than retyping a sentence.
- As a **traveler**, I never want stopping to reorder my messages: anything I
  sent after the stopped one must still be answered after it.

## Acceptance Criteria

- [ ] While a turn is streaming and the composer is empty, the send button is
  a stop button (unchanged).
- [ ] Tapping stop removes the stopped message's bubble from the chat, along
  with whatever the agent had streamed so far. No truncated reply is left
  behind and no error banner appears.
- [ ] The stopped message's text appears in the composer, with the cursor at
  the end and the field focused, so typing continues the sentence rather than
  landing in front of it.
- [ ] Images attached to the stopped message reappear as removable chips
  above the composer.
- [ ] Because the composer now holds a draft, the button reads as send again.
- [ ] Sending the restored message puts exactly one copy of it in the
  conversation — no duplicate of the stopped attempt.
- [ ] If other messages were queued behind the stopped one, the stopped
  message goes back to the **front of that queue** instead of the composer,
  and the queue still runs oldest-first. Stopping never causes a later
  message to be answered before an earlier one.
- [ ] Stopping a turn started by a **chip** (e.g. "Refine Athens") removes the
  chip from the chat and leaves the composer empty — the chip's text was
  written by the app, not typed, and the chip itself is still there to tap.
- [ ] Tapping stop when nothing is streaming does nothing — in particular it
  never removes an already-finished exchange (covers a double-tap).
- [ ] The agent stops generating server-side, rather than finishing the reply
  into a closed connection.

## API Surface

None. No endpoint is added or changed.

## Data Model

None. The change is to which messages the client keeps, not to what a message
is.

## Out of Scope / Known Gap

- **The server's copy of the transcript is not rewound.** A conversation is
  saved server-side at the *start* of a turn, deliberately on a connection
  that a client abort cannot cancel — that write is why an interrupted
  message survives a dropped network at all. Nothing in the app can unwrite
  it: a stored conversation can only be read or deleted wholesale. So until
  the traveler's next successful turn (which overwrites the stored copy in
  full), a **full app reload** — not navigating away and back, which keeps the
  chat in memory — brings the stopped message back, and it can appear in
  "continue where you left off" in the meantime. Closing it needs a way to
  rewrite a stored conversation; see `plan.md` → Known Gap.
- **No confirmation or undo-the-undo.** Stop is treated as deliberate. The
  message is never lost — it is in the composer or the queue — so there is
  nothing to confirm.
