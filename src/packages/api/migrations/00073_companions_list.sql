-- +goose Up
-- "Who you travel with" becomes a LIST.
--
-- It shipped as a single choice (migration 00063), which forces a false answer
-- from anyone whose travel is not all one shape: someone who flies solo for
-- work and takes the kids in August had to pick one and lose the other, and
-- the planning brief then tailored every trip to the half they kept.
--
-- Modelled on `interests` (migration 00004): text[] NOT NULL DEFAULT '{}', so
-- "never said" and "said nothing" have ONE representation — an empty array —
-- rather than the NULL-vs-empty pair a nullable array would invite.
--
-- Existing single values become one-element arrays, so nobody's stated answer
-- is lost and no traveler has to re-answer.
ALTER TABLE traveler_preferences
    ALTER COLUMN companions DROP DEFAULT;

ALTER TABLE traveler_preferences
    ALTER COLUMN companions TYPE text[]
        USING CASE
            WHEN companions IS NULL OR btrim(companions) = '' THEN '{}'::text[]
            ELSE ARRAY[companions]
        END;

UPDATE traveler_preferences SET companions = '{}'::text[] WHERE companions IS NULL;

ALTER TABLE traveler_preferences
    ALTER COLUMN companions SET DEFAULT '{}',
    ALTER COLUMN companions SET NOT NULL;

-- +goose Down
-- Narrowing back to one value keeps the FIRST selection and drops the rest —
-- lossy by nature, which is why this direction is dev-only. An empty array
-- becomes NULL, restoring "never said" to the shape the text column had.
ALTER TABLE traveler_preferences
    ALTER COLUMN companions DROP DEFAULT,
    ALTER COLUMN companions DROP NOT NULL;

ALTER TABLE traveler_preferences
    ALTER COLUMN companions TYPE text
        USING CASE
            WHEN companions IS NULL OR cardinality(companions) = 0 THEN NULL
            ELSE companions[1]
        END;
