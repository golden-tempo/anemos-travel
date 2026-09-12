# Tasks: Web Push Notifications

> Dependency-ordered. `[P]` = can run in parallel with its siblings (no shared
> files / no ordering dependency). Work top to bottom; verification is last.

## Resolve first

- [ ] Resolve the three `[NEEDS CLARIFICATION]` items in `spec.md` (starting
      category set, VAPID key ownership, push/email opt-in independence)
      before starting the API task below.

## API (Go)

- [ ] Migration: `push_subscriptions` table
- [ ] `query/push_subscriptions.sql` (upsert by endpoint, delete by endpoint,
      delete-all-by-user, list-by-user)
- [ ] `push_service.go`: VAPID-signed send via a Go web-push library;
      deletes subscriptions the push service reports as gone
- [ ] `push_subscriptions_handler.go` + routes in `main.go`
- [ ] Wire `sendPush` into `notifyCollabEdit` (first category, per spec)
- [ ] Wire subscription cleanup into the existing sign-out /
      sign-out-everywhere / account-deletion paths
- [ ] Add `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` / `VAPID_SUBJECT` to
      `.env.sample`

## Models & codegen (Flutter)

- [ ] Hand-write Dart model(s) for the subscription payload in `models/`
- [ ] Run `make flutter-build-models` to regenerate `.g.dart`
- [ ] Complete the Contract Parity table in `plan.md` (every row ✓)

## UI (Flutter)

- [ ] [P] Web-only subscribe/unsubscribe util (conditional import, following
      `install_prompt_web.dart` / `install_prompt_stub.dart`)
- [ ] [P] `services/push_service.dart`
- [ ] [P] Provider tracking this device's subscription state
- [ ] Settings toggle in `account_settings_screen.dart`, hidden when
      unsupported (not shown disabled)
- [ ] Hand-written service-worker `push` / `notificationclick` listeners —
      pick the `importScripts` wrapper vs. Dockerfile-sed-patch approach
      (see `plan.md`) before writing this

## Verification

- [ ] `make api-fmt && make api-vet` clean
- [ ] `make flutter-analyze` clean
- [ ] `make flutter-test` / `make api-test` pass, covering: stale (410)
      subscription is deleted not retried; sign-out-everywhere clears every
      subscription; opted-out users see no behavior change
- [ ] Manual end-to-end via `make docker-dev`: subscribe, trigger a
      collaborator edit from a second account, confirm delivery + click-to-open
- [ ] Every acceptance criterion in `spec.md` checked off
