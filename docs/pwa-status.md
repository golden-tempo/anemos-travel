# PWA status (2026-09-12, updated same day — #629)

> **Update:** action items #1–#4 below have shipped (this same PR wave); #5
> is scheduled as `specs/web-push-notifications`. The "What's missing" list
> below is left as written for the record of what the investigation found —
> see "Action items" for current status.

Investigation for #627 — "since it's built with Flutter, I'm assuming there's
a chance it has a service worker." It does, and it goes further than that: the
web app already meets the browser installability bar and ships a fair amount
of hand-tuned infrastructure around the service worker Flutter generates. This
doc is the map of what exists, what's missing, and what a next step would
look like.

## Verdict

**Anemos is already an installable PWA today**, at `https://anemos.travel/app/`.
Chrome/Edge will offer the native "Install Anemos" affordance, and the app
launches standalone (no browser chrome) with the right icon and a branded
boot splash. iOS Safari gets a home-screen icon via legacy meta tags (Apple
never adopted the Web App Manifest / installability event). What's missing is
the *engagement* layer on top of installability — push notifications, a
custom install prompt, richer manifest metadata — not the PWA foundation
itself.

## What's already in place

- **Web app manifest** (`src/packages/flutter-app/web/manifest.json`) — name,
  short name, description, `display: standalone`, themed `background_color`/
  `theme_color`, portrait orientation, and `start_url`/`scope`/`id` all scoped
  to `/app/`. Icon set covers 192/512 regular *and* maskable variants, so
  Android's adaptive-icon mask doesn't clip or letterbox the mark.
- **Service worker** — Flutter's own build step emits
  `build/web/flutter_service_worker.js` (not checked in; generated per build).
  It precaches the app shell (`index.html`, `flutter_bootstrap.js`,
  `main.dart.js`/`.wasm`/`.mjs`, `manifest.json`, `version.json`, fonts,
  assets) and serves it network-first with a cache fallback, which is what
  makes the app launch (shell-only) with no connectivity after a first visit.
  A registered service worker with a fetch handler, served over HTTPS, is the
  actual Chrome installability requirement — the manifest alone isn't enough.
- **Build-time correctness patches** (`dockerize/deployment/Dockerfile`) — the
  generated service worker is patched on every image build to fix a
  `--base-href /app/` cache-key bug (stock Flutter never reads its own
  precache under a non-root base href), to force cache-miss fetches to bypass
  the HTTP cache (`{cache: "reload"}`), and to carry a one-shot,
  guard-railed cache-eviction lever (`flutter-app-manifest-vN`) for repairing
  clients poisoned by a past CDN misconfiguration.
- **CDN/nginx tuned around the SW cache**
  (`dockerize/deployment/nginx/snippets/app-locations.conf`) — the app shell
  and asset tree are served `no-cache` (never `immutable`), specifically
  because `flutter build web` doesn't content-hash filenames, so an
  aggressively-cached asset tree silently poisons the service worker's cache
  forever. `scripts/verify-edge-parity.sh` asserts, for every resource the
  *deployed* service worker declares, that the edge and origin bytes match,
  and `sw-manifest-bump-guard` in CI blocks a PR from spending the one-shot
  eviction lever while the edge disagrees with origin.
- **iOS home-screen support** (`web/index.html`) —
  `apple-mobile-web-app-capable`, status-bar style, and `apple-touch-icon`
  meta tags for "Add to Home Screen" on iOS Safari, which never implemented
  the manifest/installability APIs Chrome/Edge use.
- **Boot splash** pixel-matched to the in-app `SplashScreen` widget, so the
  handoff from static HTML to the booted Flutter app is a single continuous
  screen rather than a flash of a different composition — this is PWA-adjacent
  polish (perceived performance / "feels native"), not required for
  installability.
- **Offline *data*, not just offline *shell*** (`specs/offline-trips`,
  shipped) — `TripCache` write-through caches the trip list and trip detail
  payloads to `shared_preferences` (web-backed by `localStorage`); on a
  network-classified failure the UI falls back to the cached copy read-only,
  with an "Offline — showing saved copy" banner and disabled mutations. This
  sits above the service worker: the SW gets the app shell to boot offline,
  `TripCache` gets a previously-viewed trip to render offline.
- **COOP/COEP headers** on `/app/` for the `--wasm` build's multithreaded
  `skwasm` path — not a PWA requirement per se, but part of the same
  "make the installed app feel native" effort.

## What's missing / not covered

1. **No push notifications.** The in-app Notification Center
   (`notifications_writer.go`, `NotificationCenterScreen`) is pull/REST only.
   There's no `PushManager` subscription, no VAPID keys, and no `push` /
   `notificationclick` handlers — Flutter's generated service worker doesn't
   add any, and nothing here layers a custom one on top. An installed PWA
   can't be reached while it isn't open.
2. **No custom install UX.** Install relies entirely on the browser's native
   UI (omnibox icon / menu item). There's no `beforeinstallprompt` capture and
   no in-app "Install Anemos" call-to-action, so users who don't already know
   to look for the browser's install affordance never see one.
3. **Thin manifest metadata.** No `screenshots` (blocks Chrome's richer
   install dialog on desktop/Android), no `categories`, no `shortcuts`
   (long-press app-icon quick actions, e.g. "New trip"), no `share_target`
   (the OS share sheet can't hand a URL to Anemos, even though the app has its
   own share/invite links — see `specs/import-trip-from-ai-chat`).
4. **Offline is shell + last-viewed trip data only.** Everything else — auth,
   search, chat/AI planning, images, a *first-ever* load with no
   connectivity — needs the network. Offline mutations/write-queueing were
   explicitly deferred in `specs/offline-trips`.
5. **No PWA/installability check in CI.** `scripts/verify-edge-parity.sh`
   verifies the *deployed* service worker's declared bytes match the edge; it
   says nothing about installability or Lighthouse's PWA best-practices score,
   so a regression (e.g. a manifest field silently dropped) wouldn't be
   caught before it reached users.
6. **iOS's story is thinner and headed toward a different fix.** iOS Safari's
   PWA install has real limits (no install prompt event, historically
   restrictive storage/push support), and `specs/ios-app-store` is already
   building a native App Store app as iPhone's primary channel — worth
   confirming that's still the intended split before investing further in
   iOS-specific PWA polish.

## Action items, roughly in effort order

1. ✅ **Custom install prompt** — captures `beforeinstallprompt` in
   `web/index.html`, read from Dart via
   `lib/utils/install_prompt_web.dart`/`install_prompt_stub.dart`; an
   "Install Anemos" row appears in Account settings only once the browser has
   actually offered an install.
2. ✅ **Manifest metadata** — `categories`, and a `shortcuts` entry ("New
   trip" → `/app/plan`) added to `manifest.json`. `screenshots` deliberately
   NOT added: they need real, current production UI captures (Chrome's
   richer install dialog shows them full-size), which isn't something to
   fabricate from an agent session — a follow-up for whoever owns the visual
   assets pipeline (see the icons/splash-art tooling this doc already
   references).
3. ✅ **Lighthouse PWA check in CI** — a `flutter` job step serves the
   built `build/web` bundle under `/app/` and runs `lighthouse@11`'s `pwa`
   category against it (pinned: Lighthouse 12+ removed the PWA category and
   its installability audits outright), failing the build if any weighted
   audit (`installable-manifest`, `viewport`, `maskable-icon`,
   `themed-omnibox`, `splash-screen`) regresses. Catches metadata/manifest
   regressions before deploy, the same role `sw-manifest-bump-guard` plays
   for the cache-eviction lever.
4. ✅ **`share_target`** in the manifest, landing on the existing "Import
   from AI chat" screen (`/app/import`) — the OS share sheet can hand Anemos
   a shared URL/text/title, which prefills the paste box
   (`lib/utils/share_target.dart`).
5. **Web push notifications** — the largest item, scheduled as
   `specs/web-push-notifications` rather than built here. Needs VAPID keys, a
   subscription-capture + storage path wired into the existing
   `notifications_writer.go` pipeline, and a *hand-written* service-worker
   layer for `push`/`notificationclick` (Flutter's generated SW is
   regenerated whole on every build, so it can't carry hand edits the way the
   Dockerfile's sed patches do for existing behavior — this would need either
   a wrapper SW that `importScripts`s the generated one, or a build step that
   appends the extra listeners the same way the Dockerfile already patches
   other parts of the file). Backend + per-user consent + a third-party push
   exchange is enough surface area to want its own spec review before code,
   rather than riding along in a docs-driven PWA-polish PR.

## Where the pieces live

- Manifest, icons, splash, iOS meta tags: `src/packages/flutter-app/web/`
- Service-worker generation & build-time patches: `dockerize/deployment/Dockerfile`
- Cache headers / SW-aware nginx rules: `dockerize/deployment/nginx/snippets/app-locations.conf`
- Edge cache-parity check: `scripts/verify-edge-parity.sh`
- CI guard for the one-shot manifest-cache bump: `.github/workflows/ci.yml` (`sw-manifest-bump-guard`)
- App-level offline trip-data cache: `src/packages/flutter-app/lib/services/trip_cache.dart`, `specs/offline-trips/`
- iOS native app plan (separate track from the PWA): `specs/ios-app-store/`
- Custom install prompt: `src/packages/flutter-app/web/index.html`,
  `src/packages/flutter-app/lib/utils/install_prompt_web.dart`,
  `src/packages/flutter-app/lib/screens/account_settings_screen.dart`
- Share-target landing: `src/packages/flutter-app/lib/utils/share_target.dart`,
  `src/packages/flutter-app/lib/screens/import_trip_screen.dart`
- Lighthouse installability check: `.github/workflows/ci.yml` (`flutter` job)
- Web push notifications (scheduled, not yet built): `specs/web-push-notifications/`
