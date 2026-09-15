# Plan: Trip Chat History

## Technical Approach

### One column narrows "one running conversation" to a partial index

`trip_refine_sessions` (00069) enforced "one conversation per (user, trip)"
with a table-level `UNIQUE (user_id, trip_id)`. Migration 00078 adds
`is_active boolean not null default true` and replaces that constraint with a
**partial** unique index, `(user_id, trip_id) WHERE is_active` — the same
invariant, narrowed to the running conversation, so archived rows for the same
pair are free to be many. A second partial index,
`(user_id, trip_id, updated_at desc) WHERE NOT is_active`, serves the history
list and its prune query.

No new table: archived and running rows share every column (transcript shape,
retention-by-trip-lifetime via the existing `ON DELETE CASCADE`), and
`is_active` is the one fact distinguishing "resume this" from "list this."

### Writes stay single-purpose

- `UpsertTripRefineSession` (a normal turn) now conflicts on the partial
  index — it only ever touches the active row, so appending to an ongoing
  conversation is unchanged.
- `ArchiveActiveTripRefineSession` (`is_active = false ... WHERE is_active`) is
  the whole of "New chat": idempotent (0 rows when nothing was running), and
  the row survives instead of being deleted.
- `PruneTripRefineSessionHistory` deletes archived rows beyond the 5 most
  recently updated, run once right after archiving grows history by one — it
  only ever has that one row to consider.
- `ActivateTripRefineSessionHistoryEntry` promotes one archived row back to
  active. The resume handler runs it in a transaction, archiving whatever is
  currently active FIRST, so the partial unique index never has to reject two
  active rows for an instant. A resume never changes the archived count (one
  leaves, the replaced one enters), so it never needs to prune.

### `trip_refine_handler.go` gains a history handler and a resume handler

`getTripRefineChatHistoryHandler` (`GET .../refine-chat/history`) and
`resumeTripRefineChatHistoryEntryHandler` (`POST
.../refine-chat/history/{sessionId}`) sit beside the existing
get/delete-as-clear handlers, both resolved through `editableTrip` like their
siblings. `deleteTripRefineChatHandler` swaps its single `DeleteTripRefineSession`
call for archive-then-prune; its response shape is unchanged.

## Go API Changes

`src/packages/api/`

- **Migration** `migrations/00078_trip_refine_session_history.sql`.
- **Queries** appended to `query/chat_sessions.sql`:
  `ArchiveActiveTripRefineSession`, `PruneTripRefineSessionHistory`,
  `ListTripRefineSessionHistory`, `GetTripRefineSessionHistoryEntry`,
  `ActivateTripRefineSessionHistoryEntry`; `UpsertTripRefineSession`,
  `GetTripRefineSession`, `GetTripRefineSessionSummary` gain `is_active`
  filters. Regenerated via `make api-sqlc`.
- **`trip_refine_handler.go`**: `TripRefineChatHistoryEntry`/
  `TripRefineChatHistoryResponse` types; `getTripRefineChatHistoryHandler`;
  `resumeTripRefineChatHistoryEntryHandler` (transactional archive + activate);
  `deleteTripRefineChatHandler` updated to archive + prune.
- **`main.go`**: two new routes under `/trips/{id}/refine-chat/history`.

## Flutter Changes

`src/packages/flutter-app/lib/`

- **Models**: `TripRefineChatHistoryEntry` / `TripRefineChatHistory` in
  `models/trip_refine_chat.dart` (`make flutter-build-models`).
- **Service**: `listTripRefineChatHistory` / `resumeTripRefineChatHistoryEntry`
  in `services/trips_api_service.dart`.
- **Provider**: `resumeTripRefineChatHistoryEntry` in `providers/plan_resume.dart`,
  sharing `planMessagesFrom` with the existing resume paths.
- **UI**: a new `widgets/trip_previous_chats_sheet.dart` (a modal bottom sheet,
  loading/empty/list states, returns the chosen id). "Previous chats" is
  offered next to "New chat" in two places that already gate on a
  conversation existing: the Continue-chat row's menu
  (`trip_header_card.dart`) and the open panel's header
  (`trip_refine_panel.dart`). `trip_detail_screen.dart`'s new
  `_showPreviousChats` opens the sheet, then resumes the chosen entry the same
  way an ordinary restore does (restoring/ready/failed phases), and
  re-fetches the trip so the Continue-chat row reflects the swap.

## Contract Parity

| JSON key | Go type | Dart type | Nullable? | ✓ |
|---|---|---|---|---|
| `chats[]` | `[]TripRefineChatHistoryEntry` | `List<TripRefineChatHistoryEntry>` | no | ✓ |
| `chats[].id` | `string` | `String` | no | ✓ |
| `chats[].preview` | `string` | `String` | no | ✓ |
| `chats[].message_count` | `int` | `int` | no | ✓ |
| `chats[].created_at` | `time.Time` | `String` | no | ✓ |
| `chats[].updated_at` | `time.Time` | `String` | no | ✓ |
| resume response | `TripRefineChatResponse` | `TripRefineChatDetail` | no | ✓ (reuses the existing `GET .../refine-chat` shape) |

## Decision records (divergences, per `docs/zen.md`)

- **Superseding `specs/trip-refine-memory`'s "no per-trip chat history or
  picker" Out of Scope line.** That line captured a real product decision at
  the time; #639 asks for the opposite. Rather than editing that spec's
  history, this feature is documented as an explicit extension, the same way
  `specs/trip-refine-memory` itself extended
  `specs/continue-where-you-left-off` (see that spec's own acceptance
  criteria referencing "a stronger mechanism").
