---
paths:
  - "src/packages/api/plan_*.go"
  - "src/packages/api/places_photo_handler.go"
  - "src/packages/api/anthropic_client.go"
  - "src/packages/api/i18n.go"
  - "src/packages/flutter-app/lib/widgets/chat_panel.dart"
  - "src/packages/flutter-app/lib/widgets/place_photo_card.dart"
---

# The /plan SSE agent loop

- The `/plan` endpoint uses `text/event-stream` with `http.Flusher`; the server `WriteTimeout` must stay at `0`.

- **The `/plan` tool registry order is part of the prompt-cache prefix** (`plan_tool_registry.go` header comment): the registry is an ordered slice serialized as the tools array, covered by the system-prompt cache breakpoint — keep existing entries byte-stable and **append new tools at the tail**. One registry entry per tool (definition + optional availability gate + dispatcher); the handler generates the tools slice and dispatches `tool_use` blocks from it.

- **Conversation compaction** (`plan_compactor.go`, specs/conversation-compaction) replaced the old hard "conversation too long" failure: when a `/plan` request's history reaches 24 messages, all but the newest 10 are folded into a state summary via one forced-tool `aiModelLight()` call (default Haiku 4.5); the summary streams back as an SSE `compacted` event and **the client owns it** — later turns resend it as `PlanRequest.Summary` in place of the folded messages. `planMaxMessages = 60` remains only as a runaway/abusive-client backstop (friendly SSE `error` event, not a 500).

- **Plan chats persist from the very first turn** for authenticated, non-trip-bound sessions with a `chat_id` (`plan_chat_sessions` table, migration 00031; specs/continue-where-you-left-off): two best-effort whole-transcript upserts per turn (synchronous at start, deferred at end with the streamed assistant text). "Graduation" is read-time, not a write: `GET /api/v1/chats` excludes chats whose `chat_id` already belongs to a trip (`NOT EXISTS` against `trips.chat_id` in `query/chat_sessions.sql`). Anonymous, degraded-mode, and trip-bound sessions stay ephemeral; sessions idle for two months are pruned opportunistically by the list handler.

- **Chat photo cards**: `search_places` emits a `places` SSE side event (≤8 cards; photo refs are `json:"-"` on `PlaceSearchResult` so the model-facing tool_result and public `/places/search` JSON stay byte-identical), and `search_local_recommendations` enriches its SSE payload with venue `photo_ref`s via `fields=photo` details lookups (`enrichLocalRecPhotos`, bounded + time-boxed; agent path only — public `/local/*` browse responses never carry photo fields). Images load through `GET /api/v1/places/photo` (`places_photo_handler.go`), a 302-redirect proxy gated by `knownPhotoRefs` (only refs the process handed to a client are servable — every Place Photo call is billed) with its own rate bucket. Flutter renders the strips in `_ResultStrips` (`chat_panel.dart` → `place_photo_card.dart`, fixed 200×160 cards so images can never reflow the chat tail); the places strip is suppressed on itinerary turns (`search_places` doubles as geocoding there). Strips replaced the local-picks/events summary chips; flights/ferries/event-links keep chips.
