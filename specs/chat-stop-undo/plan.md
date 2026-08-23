# Plan: Stop Undoes the Turn

> **HOW.** See `spec.md` for what and why, and `../../CLAUDE.md` for repo
> conventions referenced below.

## Technical Approach

Two files, no new provider, no new endpoint. The pieces this needs already
exist and were built for adjacent reasons:

- `PlanNotifier` already owns the transcript and already knows how to roll a
  user message back out of it — `retryLastSend` does exactly that so a retry
  doesn't double-append. Stop now does the same rollback and simply doesn't
  resend.
- `ChatPanel` already owns the composer, and `chatDraftProvider` already
  holds its text and attachments so they survive the panel being disposed.
  Putting a message back is `_send` run backwards.

The one new thing is the seam between them: **`stopStreaming()` returns the
message it took out**, and the panel puts it where it belongs. A return value
rather than a callback handed to the constructor (the shape
`onProfileFieldsChanged` uses) because there is nothing asynchronous here —
the panel calls stop and is the only caller — and because a plain result is
what the zen rule asks of a mutating operation: *state the post-state the
consumer will observe*.

### Where the message goes back to — one rule

The stopped message was at the head of the line of things waiting to be sent.
It goes back to the head of that line:

| Queue behind it | Goes back to | `stopStreaming()` returns |
|---|---|---|
| empty | the composer — the head of an empty line | the message |
| non-empty | the front of `queuedMessages` | `null` |

Handing it to the composer while messages sit in the queue would be the one
genuinely wrong answer: the user would resend it and `sendMessage` would
enqueue it at the *back*, so a message they sent second would be answered
first. The queue is the existing UI for "waiting to be sent" (chips with
remove buttons), so nothing new is needed to show it.

### Seeded turns

A `PlanMessage.displayLabel` means the content is a machine-written seed
behind a short chip label — "Refine Athens", "Plan from scratch". The turn is
undone like any other, but nothing goes to the composer: there is no composer
form of a seed, and dumping several hundred words of generated prompt into
the text box would be worse than the problem being solved. The chip that sent
it is still on screen, which is its way back. `stopStreaming()` returns
`null`, so the panel needs no knowledge of what a `displayLabel` means.

## Go API Changes

None.

## Flutter Changes

`src/packages/flutter-app/lib/`:

- **`providers/plan_provider.dart`** — `stopStreaming()` changes from
  `void` to `PlanMessage?`. It no longer commits the streamed partial as an
  assistant message; instead it drops the partial, removes the trailing user
  message, and routes that message per the table above. Unchanged: it
  supersedes the turn (`_turn++`) before anything else so the dying stream's
  tail is a no-op, ends the stream buffer before the state write so a pending
  48 ms flush can't resurrect a ghost bubble, fires the transport abort, and
  does **not** auto-drain the queue (stopping is not success).

  Two guards worth naming:
  - The trailing message is *checked* to be a user message rather than
    assumed. It always is — `_sendNow` appends it before the first event and
    nothing else appends while streaming — but if that ever stops holding,
    leaving the transcript alone beats deleting somebody else's message.
  - `compactedCount` is re-clamped to the shortened transcript. A compaction
    that landed mid-turn can already have counted the message now leaving,
    and a boundary past the end would make the next turn slice history past
    its own end.

- **`widgets/chat_panel.dart`** — new `_stop()`, the inverse of `_send()`,
  wired to the existing `onStop`. Assigns `_controller.value` (never
  `controller.text` — that setter parks the selection at −1 and the next
  keystroke lands in *front* of the restored text; the same trap
  `_restoreDraft` and `airport_field.dart` document), refills `_pending`,
  saves the attachment half of the draft, and focuses the field. The text
  half needs no explicit save: the controller's own listener mirrors it into
  `chatDraftProvider`, exactly as when the user types.

  Restoring wholesale is safe because the button is only a stop while the
  composer is empty, so there is no draft to clobber.

## Contract Parity

Not applicable — no wire contract changes.

## Testing

- `test/plan_provider_stop_test.dart` (rewritten, 8 tests) — the rollback and
  hand-back, the typing-indicator phase (stop before any text), idle/
  double-tap, attachments riding back by identity, seeded turns returning
  null, the queue going to the head with FIFO preserved through the next
  send, exactly one copy in history after a resend, and the `compactedCount`
  clamp.
- `test/chat_panel_stop_button_test.dart` (extended, 5 tests) — the existing
  send/stop swap tests plus: the bubble and partial leaving while the text
  lands in the field with the caret at the end and focus, attachments coming
  back as chips, and a seeded turn leaving the composer empty.

Per `CLAUDE.md`, no test asserts anything font-dependent.

## Known Gap — the server's copy

`plan_handler.go` upserts the whole transcript at turn **start**, on a
`context.Background()` with its own timeout, with the comment that a canceled
stream must not cancel the write "because the user's message surviving a dead
stream is the entire point of it." A deferred end-of-turn upsert follows with
whatever text streamed. Both survive the client's abort by design.

The client cannot undo either: `main.go` registers only
`GET`/`DELETE /trips/{id}/refine-chat` and `GET`/`DELETE /chats/{chatId}`.
There is no way to *write* a transcript except by running a turn.

Consequence, and it is a real one: after a stop, the stored conversation still
contains the stopped message (and any partial reply). The next successful turn
sends the rolled-back history and the wholesale upsert overwrites it, so the
window closes as soon as the traveler sends anything. It does **not** close on
its own — a full app reload inside that window resurrects the message, and it
can surface in the resumable-chats list.

Scoped out deliberately rather than overlooked. Closing it means either:

1. `PUT /chats/{chatId}` (and the trip-bound equivalent) so the client can
   push a corrected transcript — the general fix, and the one that would also
   let other client-side transcript edits persist; or
2. a narrower `DELETE .../last-turn` that drops the trailing user message and
   any assistant message after it — smaller surface, but a second way to say
   "what the transcript is", which is the shape `docs/zen.md` warns about.

(1) is the better shape. Neither is needed for the feature to be right in the
session it happens in, which is where stop is used.
