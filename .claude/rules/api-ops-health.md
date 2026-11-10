---
paths:
  - "src/packages/api/ops_*.go"
  - "src/packages/api/ai_health.go"
  - "src/packages/api/*health*.go"
---

# Uptime history & provider health

- **Uptime history** (`health_samples`, migration 00059; specs/uptime-history): every health-monitor tick persists an **interval with a state** (`covers_from`→`observed_at`; `tick` rows carry the three signal booleans SEPARATELY — never a joined reasons string, so a stale backup structurally cannot tint the availability bar). The sampler can't observe its own downtime, so absence is written down, not inferred: at boot `bootstrapSamples` writes an explicit `gap` row whose cause comes from the release comparison (changed `SENTRY_RELEASE` = `deploy` → unobserved/unknown seconds; unchanged = `unknown` → downtime — deploys never dent the number, unexplained restarts do). A tick observing `db_ok=false` can't write (the DB is what's down); `writeSample`'s bounded in-memory buffer holds it and flushes with the ORIGINAL timestamp on recovery. `rollupUptime` (`ops_uptime.go`) is the ONE place any of this becomes per-day state; the wire carries dense 90-day arrays, `uptime_pct: null` (not 0) for `no_data` days, and stable reason codes localized client-side. Pruned at 100 days by the janitor.

- **AI-provider health** (`ai_health.go`): every Anthropic SDK call site (`Messages.New` / `NewStreaming`) must call `recordAIResult(err)` exactly once per call — nil records a success. The process-lifetime tracker feeds `computeHealthState`'s third signal, so fatal failures (billing/auth; the credit-balance outage class) flip the shared ops degraded verdict and the `ops_monitor.go` self-check alerts admins on any reason-set change (passive — the monitor never pings paid providers; recovery requires a successful AI call; transient/unknown errors count in `/admin/ops/metrics` `ai_*` but never alert; unrecognized provider envelopes — Kimi/Moonshot — never classify fatal). Cadence: `HEALTH_TICK_MINUTES` (default 5).
