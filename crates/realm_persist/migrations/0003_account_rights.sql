-- Consent, password changes and recovery codes. Only adds nullable columns,
-- so it is instant on a live table and an older binary keeps working after a
-- rollback. Existing accounts start with no accepted terms (they are asked
-- at their next login) and no recovery code (they can make one in the game).

ALTER TABLE accounts
    ADD COLUMN terms_version        text,        -- the version last accepted
    ADD COLUMN terms_accepted_at    timestamptz,
    ADD COLUMN age_confirmed_at     timestamptz, -- "I am 16 or older"; no birth date is kept
    ADD COLUMN recovery_hash        text,        -- sha256 of a one-time code of 150 random bits
    ADD COLUMN recovery_created_at  timestamptz,
    ADD COLUMN password_changed_at  timestamptz;

-- Deletions leave one anonymous row each: `kind`, the time and a count.
CREATE INDEX audit_kind ON audit (kind, at);
