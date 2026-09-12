# Plan: Web Push Notifications

> **HOW.** Translates `spec.md` into a file-level technical approach. Every
> decision should trace back to an acceptance criterion. See `../../CLAUDE.md`
> for repo conventions referenced below — don't restate them, point to them.

## Technical Approach

Standard Web Push (VAPID + the browser's push service — no proprietary
FCM/APNs SDK needed for Chrome/Edge/Firefox): the client asks
`ServiceWorkerRegistration.pushManager` for a subscription and posts it to the
API; the server stores it and, on the existing notification writers'
call sites, additionally sends an encrypted push payload to that
subscription's endpoint using a Go web-push library (`SubscriptionResource`
pattern below). No new external account/vendor is required — VAPID is a
self-signed key pair the server generates once. Delivery is additive: it
never replaces or blocks the existing `notifications_writer.go` DB writes
that feed the in-app Notification Center, matching "must never block the
edit that triggered it."

Deliberately NOT reusing the generated `flutter_service_worker.js` in place —
Flutter regenerates that file whole on every build (see
`docs/pwa-status.md`), so it can't carry hand-written `push` /
`notificationclick` listeners directly. Two options, to decide during
implementation rather than pre-committing here:
(a) a thin hand-written service worker that `self.importScripts()`s the
generated one, registered instead of it, or (b) a Dockerfile sed patch —
same mechanism already used for the cache-key and `{cache: "reload"}` fixes —
that appends the extra listeners to the generated file at image build time.
(a) is more isolated from Flutter upgrades; (b) matches existing precedent.

## Go API Changes

`src/packages/api/` (all files are `package main`):

- **Migration:** new `push_subscriptions` table — `id`, `user_id` (FK →
  `users`), `endpoint` (unique), `p256dh` / `auth` keys, `created_at`,
  `last_seen_at`. One row per (user, endpoint); re-subscribing the same
  endpoint upserts rather than duplicating.
- **Routes:** `POST /api/v1/push/subscriptions`, `DELETE
  /api/v1/push/subscriptions` in `main.go`, alongside the other
  `/api/v1/push/...`-style additions, both auth-required.
- **Handler:** new `push_subscriptions_handler.go` — parse/validate the
  subscription payload, upsert/delete via a new `sqlc` query file
  (`query/push_subscriptions.sql`).
- **Service:** new `push_service.go` wrapping a Go web-push library
  (VAPID-signing + the encrypted-payload POST to the subscription's
  endpoint); exposes one function, `sendPush(ctx, userID, payload)`, that
  fans out to every subscription for that user and deletes any subscription
  the push service reports as gone (`410`/`404`).
- **Wiring:** `notifications_writer.go`'s existing writers (starting with
  `notifyCollabEdit`, per the spec's first-category acceptance criterion)
  call `sendPush` alongside their existing DB insert — same
  best-effort/fire-and-forget posture (own timeout off
  `context.Background()`, logged not surfaced).
- **Sign-out integration:** the account handlers already funnel through
  the sign-out paths the spec calls out (sign out everywhere, account
  deletion) — add subscription cleanup there, scoped to (a) this device only
  for a normal sign-out, (b) all of the user's subscriptions for
  sign-out-everywhere/deletion.
- **New env vars** (`.env.sample`): `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`,
  `VAPID_SUBJECT` (a `mailto:` contact required by the push protocol).

## Flutter Changes

`src/packages/flutter-app/lib/`:

- **Web-only subscribe/unsubscribe util**, following the conditional-import
  pattern `install_prompt_web.dart`/`install_prompt_stub.dart` already
  establish for browser-only capabilities: wraps
  `ServiceWorkerRegistration.pushManager.subscribe()` (needs
  `VAPID_PUBLIC_KEY` exposed to the client, e.g. via a `/api/v1/push/config`
  GET or a build-time `--dart-define`) and posts the resulting subscription
  to the two new endpoints.
- **Service** (`services/push_service.dart`): thin wrapper over the two new
  endpoints, matching `account_api_service.dart`'s shape.
- **Provider**: tracks this device's subscription state (subscribed /
  not-supported / permission-denied) for the settings toggle to read.
- **UI**: a new toggle row in `account_settings_screen.dart`'s
  `settingsEmailPrefsSection` card (or a dedicated card, if the "push mirrors
  email prefs" open question resolves to keeping them visually distinct) —
  same visibility-gated pattern the install-prompt row added in this same PR
  wave uses (hidden entirely when unsupported, not shown disabled).

## Contract Parity

| JSON key | Go type | Dart type | Nullable? | ✓ |
|----------|---------|-----------|-----------|---|
| `endpoint` | `string` | `String` | no | ☐ |
| `keys.p256dh` | `string` | `String` | no | ☐ |
| `keys.auth` | `string` | `String` | no | ☐ |

## Cross-cutting

- **Env vars:** `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT`
  added to `.env.sample`.
- **Gateway:** no new proxy config — new paths are under the existing
  `/api/v1/` prefix.
- **CI:** no new job — this rides the existing `go` and `flutter` jobs.

## Verification

- `make api-fmt && make api-vet` clean.
- `make flutter-build-models` then `make flutter-analyze` clean.
- `make flutter-test` / `make api-test`, including: a stale (410) subscription
  is deleted rather than retried; sign-out-everywhere clears every
  subscription for the user; a user who never opts in sees no behavior change.
- Manual end-to-end via `make docker-dev`: subscribe on one browser, trigger a
  collaborator edit from a second account, confirm the OS notification
  appears and clicking it opens the trip.
