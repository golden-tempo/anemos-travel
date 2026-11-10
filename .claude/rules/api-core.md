---
paths:
  - "src/packages/api/**/*.go"
  - "src/packages/api/query/*.sql"
  - "src/packages/api/migrations/*.sql"
---

# API core invariants

- `Location.Latitude` and `Location.Longitude` in the Go API are `*float64` (pointers) to distinguish "not provided" from zero — coordinate validation is skipped when nil to support name-only location resolution.

- `/transcribe` has its own request lanes: a 10 MiB body-limit branch in `bodyLimitMiddleware` (`middleware.go`; default is 256 KiB, `/plan` gets 20 MiB for chat history incl. images) and its own IP rate-limiter bucket in `main.go`, separate from the `strict` (5/min) bucket so dictation traffic doesn't starve `/plan`.

- Persistence uses **pgx + sqlc + goose** (Postgres). The `store/` package is sqlc-generated — run `make api-sqlc` after editing `query/*.sql` or the schema; never hand-edit it. UUID primary keys; migrations run on boot and via `make api-migrate`.
