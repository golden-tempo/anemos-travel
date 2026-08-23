# Plan: Composer History Recall

> **HOW.** See `spec.md` for what and why, and `../../CLAUDE.md` for repo
> conventions referenced below.

## Technical Approach

One file (`widgets/chat_panel.dart`), no new provider, no new storage. Three
decisions carry the whole feature:

### 1. The transcript *is* the history

`_sentHistory()` reads `PlanState.messages` (plus `queuedMessages`) on each
keystroke rather than maintaining a list. A second copy would be a second
source of truth for "what the user sent" — the exact shape `docs/zen.md`
warns about — and it would drift the moment a turn lands, a conversation is
resumed, or `stopStreaming` undoes a turn (`specs/chat-stop-undo`, which
*removes* a message the user must not then find in their history).

Cheap enough to not need caching: it runs once per Up/Down keypress, not per
frame.

Filters: `role == user` (obviously) and `displayLabel == null` — a display
label means the content is a machine-written seed behind a chip, which is not
something the user typed. Queued messages are included: they were sent, they
are only waiting.

### 2. The kept draft *is* the stash

Shell-style recall needs somewhere to park the half-written message while the
user browses. `chatDraftProvider` is already exactly "what someone has composed
but not sent yet" and already outlives the panel, so recall simply **doesn't
write to it**: `_recalling` is set around the controller write, and
`_saveDraft` returns early when it sees it. Stepping back to index −1 reads the
draft provider and finds the user's words untouched.

No second field to keep in sync, and it survives the panel being disposed
mid-browse — the kept draft still holds what the user was writing, not the
message they were looking at.

The corollary is that `_saveDraft` became the one place that can tell the user
typed, which is what ends a browse. That needed one more guard: a
`TextEditingController` notifies for a **caret move** exactly as for a
keystroke, and clicking into a recalled message to edit it is ordinary. So
`_saveDraft` compares against `_composerText` (the text it last saw) and does
nothing when only the selection moved — otherwise a click would end the browse
*and* overwrite the stash with the message being browsed.

### 3. The handler goes on the field's own focus node

`_inputFocus.onKeyEvent`, set in `initState` — **not** a `Focus` widget wrapped
around the `TextField`. `konami_listener.dart` documents this trap from the
other side: an ancestor handler "sits above the focused node in the bubble
chain and would therefore never see arrow keys while a text field has focus."
The focused node is dispatched first, which also puts this ahead of
`DefaultTextEditingShortcuts` near the root.

Returning `KeyEventResult.ignored` is what leaves ordinary caret movement
completely untouched, so every "don't recall here" case is a decline rather
than a re-implementation:

| Case | Result |
|---|---|
| not Up/Down, or a key-up event | ignored |
| any modifier held (Shift/Alt/Ctrl/Meta) | ignored |
| selection not collapsed | ignored |
| caret not on the first line (Up) / last line (Down) | ignored |
| already at the oldest (Up) / already at the draft (Down) | ignored |
| otherwise | recall, `handled` |

The first/last-line test is `!text.substring(0, offset).contains('\n')` (and
its mirror) — *logical* lines, so a long soft-wrapped single line still
recalls. That matches readline's `up-line-or-history` and is deterministic to
test, which a visual-line test would not be.

## Go API Changes

None.

## Flutter Changes

`src/packages/flutter-app/lib/widgets/chat_panel.dart` only:

- **State:** `_historyIndex` (−1 = not browsing, otherwise a position in the
  history newest-first), `_recalling`, `_composerText`.
- **`initState`:** assigns `_inputFocus.onKeyEvent`.
- **`_restoreDraft`:** seeds `_composerText` alongside the controller.
- **`_saveDraft`:** gains the caret-move guard, the `_recalling` guard, and
  the `_historyIndex = -1` reset. Behaviour for an ordinary keystroke is
  unchanged.
- **New:** `_sentHistory()`, `_recallHistory(delta)`, `_onComposerKey(event)`.
- **Imports:** `package:flutter/services.dart` (shown-scoped:
  `HardwareKeyboard`, `KeyDownEvent`, `KeyEvent`, `KeyRepeatEvent`,
  `LogicalKeyboardKey`).

`_InputBar` is untouched — it stays a layout widget, and all recall policy
lives in one method on the panel State.

Per-conversation history and per-conversation drafts both fall out of
`chatDraftKeyFor` / the notifier the panel was handed; no new key.

## Contract Parity

Not applicable — no wire contract changes.

## Testing

`test/chat_panel_history_recall_test.dart`, 11 widget tests driving **real key
events** (`tester.sendKeyEvent`) through the focus tree — which is the only way
to prove the interception point in decision 3 actually works, and the main risk
in this change:

walk back and stop at the oldest · caret at the end · Down forward and back to
the half-written draft (and no further) · typing restarts the browse and
becomes the new stash · a caret move does not · Up only from the first line ·
Down only from the last line · each modifier declines while the bare key
recalls · empty chat · chip-seeded turns excluded · a queued message is
recallable.

Per `CLAUDE.md`, no test asserts anything font-dependent — the multi-line cases
use explicit `\n` and offsets, never wrap positions.
