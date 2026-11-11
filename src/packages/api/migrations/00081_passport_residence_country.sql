-- +goose Up
-- Entry requirements (visas, ESTA/ETA/ETIAS-class authorizations,
-- passport-validity windows) depend on which passport the traveler holds and
-- where they live, so later provider work has something to read. This is
-- storage only — no provider call, no todo card, no derivation yet
-- (specs/entry-requirements). Both nullable with no default: "not stated"
-- must stay distinguishable from any particular country, the same way the
-- other profile fields in this table treat unset as a first-class state.
ALTER TABLE traveler_preferences ADD COLUMN passport_country text; -- ISO 3166-1 alpha-2
ALTER TABLE traveler_preferences ADD COLUMN residence_country text; -- ISO 3166-1 alpha-2

-- +goose Down
ALTER TABLE traveler_preferences DROP COLUMN IF EXISTS passport_country;
ALTER TABLE traveler_preferences DROP COLUMN IF EXISTS residence_country;
