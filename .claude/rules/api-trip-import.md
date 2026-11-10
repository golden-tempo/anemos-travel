---
paths:
  - "src/packages/api/trip_import*.go"
  - "src/packages/flutter-app/lib/screens/import_trip_screen.dart"
---

# Trip import from an external AI chat

- **Trip import** (`trip_import_service.go`, specs/import-trip-from-ai-chat): `importTripCore` is the reusable extract→resolve→persist pipeline (handler-free so a future MCP-connector tool can call it). Coordinate tiers: Google Places hit (authoritative) > plausible model coords (kept, flagged approximate) > dropped-with-named-warning; Places **outage/quota is distinguished from ZERO_RESULTS** (`isPlacesZeroResults`) — outage rides one aggregate warning + retryable 503, never per-place blame. Imported trips set `trips.chat_id` (fresh `chat-<token>` lineage) but write **no** `plan_chat_sessions` row — refine-in-chat binds via chat_id and the first refine creates the row. The `import.*` catalog keys are the documented exception to "writeJSONError strings are not localized" (i18n.go header); the Flutter screen shows only 422/429 server messages verbatim. Guards: own IP bucket, per-user `FREE_IMPORTS_PER_DAY` (default 10), trip-cap pre-check before any model/Places spend, `importMaxLocations` cap with a visible warning.
