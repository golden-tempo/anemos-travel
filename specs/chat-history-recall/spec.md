# Spec: Composer History Recall

> **WHAT & WHY only.** See `plan.md` for the technical approach.

## Context

Chat messages get resent constantly with a word changed — a date moved, a city
swapped, a question rephrased after the agent misread it. Today every one of
those means retyping the whole sentence, because the words are visible in the
bubble above but there is no way to get them back into the composer.

Every terminal, every REPL, and every chat client people already use answers
this the same way: **Up recalls what you sent last.** This adds that, with the
behaviour people already have muscle memory for — Up walks back, Down walks
forward, and the half-written message you were in the middle of is waiting
where you left it.

It pairs directly with `specs/chat-stop-undo`: stopping a turn hands the
message back for editing, and Up does the same for any message that already
got an answer.

## User Stories

- As a **traveler**, I want to press Up in the chat box to get my last message
  back, so I can change one word and send it again instead of retyping it.
- As a **traveler**, I want to keep pressing Up to reach older messages, and
  Down to come back toward the newest.
- As a **traveler part-way through typing**, I want the message I was writing
  to still be there after I look through my history — pressing Down past the
  newest brings it back.
- As a **traveler writing a long multi-line message**, I want Up and Down to
  move the cursor through my own text the way they do in every other text
  box, not yank it away.

## Acceptance Criteria

- [ ] Pressing Up with the chat box focused replaces its contents with the
  most recent message the traveler sent in this conversation. Pressing Up
  again reaches the one before it, and so on.
- [ ] The cursor lands at the **end** of the recalled text, so typing
  continues the message rather than landing in front of it.
- [ ] Pressing Up at the oldest message does nothing further.
- [ ] Pressing Down walks back toward the newest; pressing Down past the
  newest restores whatever the traveler had typed but not sent before they
  started looking. Pressing Down again does nothing further.
- [ ] Typing (or dictating, or pasting) ends the browse: the next Up starts
  again from the most recent message, and the text now in the box is what
  Down returns to.
- [ ] Moving the cursor — clicking into a recalled message, arrowing
  left/right — is **not** typing: it does not end the browse and does not
  destroy the unsent draft.
- [ ] In a multi-line draft, Up only recalls when the cursor is on the first
  line and Down only when it is on the last line. Anywhere else they move the
  cursor as usual.
- [ ] Holding a modifier (Shift, Alt/Option, Ctrl, Cmd) never recalls — those
  are selection and word/document navigation.
- [ ] Pressing Up in a conversation with nothing sent yet does nothing.
- [ ] Messages sent by a **chip** (e.g. "Refine Athens") are not in the
  history — the traveler did not write them.
- [ ] A message sent while an earlier turn is still answering (queued) is
  recallable straight away.
- [ ] History is per conversation: the Agent tab and a trip's chat each recall
  their own messages.

## API Surface

None. No endpoint is added or changed.

## Data Model

None. History is the conversation that is already on screen, read backwards.

## Out of Scope

- **Text only.** Images attached to a recalled message do not come back —
  Up recalls what you *wrote*, and silently re-attaching old photos on the way
  to editing a sentence would be a surprise. (Stopping a turn *does* return
  attachments; there the message was never sent to completion. See
  `specs/chat-stop-undo`.)
- **No history beyond the conversation.** Starting a new chat starts empty;
  history is not carried across conversations or persisted separately. The
  transcript is the only copy, which is also why a resumed conversation's
  messages are recallable with no extra work.
- **No search or numbered recall** (no Ctrl-R, no `!!`). Up and Down only.
- **No duplicate collapsing.** Sending the same message twice puts it in the
  history twice, because that is what happened.
