# Spec: Web Push Notifications

> **WHAT & WHY only.** No tech choices, file names, libraries, or code. If a
> sentence names a file or a package, it belongs in `plan.md`, not here.

## Context

Anemos already has an in-app Notification Center (collaborator edits, invite
accepted, price alerts, etc. — see `notifications_writer.go`), but it's
pull/REST only: a traveler only sees a notification if they happen to open the
app. `docs/pwa-status.md` (the PWA investigation from #627/#628, action items
#1–#4 of which shipped alongside this spec) flagged this as the one PWA gap
that's a real feature, not polish — installed apps are supposed to be
reachable while closed, and Anemos currently cannot reach anyone who isn't
already looking at it. This is the last, largest item from that investigation,
deliberately scheduled here rather than built blind: it touches the backend
(new persistent subscriptions, a third-party push exchange), a hand-maintained
addition to a build-generated service worker, and per-user consent — each
worth its own review before code, not bundled into a docs-driven PWA-polish
PR.

## User Stories

- As a traveler with Anemos installed, I opt in to notifications once and
  then receive them (e.g. "your collaborator changed the itinerary") even
  when the app isn't open, the same way I would from a native app.
- As a traveler, I can turn push notifications off from the same settings
  screen where I turned them on, and stop receiving them immediately.
- As a traveler using Anemos on a device/browser that doesn't support web
  push (e.g. iOS Safari below its push-capable versions, or a browser where I
  never installed the app), I never see a broken or confusing opt-in prompt —
  the feature quietly isn't offered.

## Acceptance Criteria

- [ ] A signed-in user on a supporting browser can turn on push notifications
      from Account settings and sees a confirmation once the OS permission
      prompt is accepted.
- [ ] Turning push on/off in one browser tab/device does not affect a
      different signed-in device for the same account — each device/browser's
      subscription is independent.
- [ ] Uninstalling the app, revoking the OS notification permission, or an
      expired push subscription all stop delivery without producing user-
      visible errors or repeated retries against a dead subscription.
- [ ] Signing out (including "sign out everywhere" and account deletion)
      stops push delivery to the signed-out device(s).
- [ ] At least one existing in-app notification category (candidate:
      collaborator edit, per `notifyCollabEdit`) is also delivered as a push
      notification when the recipient isn't actively in the app, and clicking
      it opens the relevant trip.
- [ ] A user who never opts in sees no change in behavior — push is strictly
      additive to the existing in-app Notification Center, which keeps
      working for everyone exactly as it does today.

## API Surface

### `POST /api/v1/push/subscriptions` (auth required)
- **Purpose:** register (or refresh) this browser/device's push endpoint so
  the server can deliver notifications to it.
- **Request:** the browser's push subscription (endpoint URL + encryption
  keys) and enough client context to identify the device on the settings
  screen (e.g. a user-agent-derived label).
- **Response:** confirmation; no client-visible id is required beyond success.
- **Errors:** `401` unauthenticated; `400` malformed subscription payload.

### `DELETE /api/v1/push/subscriptions` (auth required)
- **Purpose:** unregister this browser/device's subscription (explicit
  opt-out).
- **Request:** the subscription endpoint URL being removed.
- **Response:** `204`.
- **Errors:** `401` unauthenticated.

## Data Model

- **Push subscription** — one per (user, browser/device): the push service
  endpoint URL, its encryption keys, when it was created/last confirmed
  working, and which user it belongs to. Deleted on explicit opt-out, on
  sign-out of that device, and automatically once the push service reports
  the endpoint as gone (410/404 on send).

## UI Behavior

- **Surface:** Account settings, alongside the existing email notification
  toggles (`settingsEmailPrefsSection` — trip reminders, weekly ideas) — push
  is a peer of those, not a separate flow.
- **Happy path:** toggle on → browser's native permission prompt → on accept,
  the subscription round-trips to the server and the toggle shows on;
  on the toggle showing on, the browser's push permission is granted for this
  device.
- **States:** unsupported browser/context → the toggle is not shown, exactly
  like `docs/pwa-status.md`'s custom-install-prompt row already does for
  `beforeinstallprompt`. Permission denied → toggle stays off with a message
  explaining the OS blocked it (not an app error). Already granted (e.g. a
  second device) → toggle reflects this device's own subscription state, not
  the account's.

## Edge Cases & Error States

- Push service (browser vendor's endpoint) unreachable or rejects a
  send: best-effort, matching every existing notification writer
  (`notifications_writer.go`'s "must never block the edit that triggered
  it" invariant) — a failed push is logged, never surfaced to the actor, and
  never retried in a way that could look like a broken notification storm.
  A `410 Gone` / `404` response from the push service means the subscription
  is stale and is deleted server-side, matching "expired subscriptions stop
  delivery" above.
- A user with multiple installed devices gets the push on every still-valid
  subscription; one device's stale/expired subscription doesn't block
  delivery to the others.
- Text content of a push notification is a short, generic summary (e.g. "X
  changed your trip") — never trip content, matching how in-app notification
  payloads already avoid embedding traveler-authored trip data in anything
  that could be logged or cached upstream of the app.

## Out of Scope

- Native (iOS/Android) push — `specs/ios-app-store` is the separate native
  channel; this spec is web push only.
- A push-specific notification-preferences UI beyond the on/off toggle
  described above (e.g. per-category push toggles) — start with "push
  mirrors whatever's already in the Notification Center", refine later once
  there's usage data.
- Rewriting the existing in-app Notification Center or its read/mark API —
  push is an additional delivery channel for the same underlying events, not
  a replacement.

## Open Questions

- [NEEDS CLARIFICATION] Which notification categories should ship first
  (all of them, or a smaller starting set — e.g. collaborator edits and price
  alerts, deferring lower-urgency ones like weekly ideas)?
- [NEEDS CLARIFICATION] Who owns generating and rotating the VAPID key pair
  the push protocol requires, and where does the private key live
  operationally (alongside the other secrets in `.env.sample`, or a separate
  process)?
- [NEEDS CLARIFICATION] Should the settings toggle also gate the *existing*
  email reminders (`settingsTripReminders`), or are push and email fully
  independent opt-ins?
