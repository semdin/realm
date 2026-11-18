-- Moderation: what stands against an account, who it blocks, what players
-- reported. History of every action is in `audit`. Only adds tables and one
-- nullable column, so an older binary keeps working after a rollback.

-- One live ban and one live mute per account; `until_unix` 0 means permanent.
CREATE TABLE sanctions (
    account_id  bigint NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    kind        text NOT NULL CHECK (kind IN ('ban', 'mute')),
    until_unix  bigint NOT NULL DEFAULT 0,
    reason      text NOT NULL DEFAULT '',
    by_name     text NOT NULL DEFAULT '',
    at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, kind)
);

-- Who an account does not want to hear from. `name` is the character it was
-- blocked by, for the list the player sees.
CREATE TABLE account_blocks (
    account_id  bigint NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    blocked_id  bigint NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    name        text NOT NULL DEFAULT '',
    at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, blocked_id)
);

-- A player's report with the chat around it at that moment.
CREATE TABLE reports (
    id                  bigserial PRIMARY KEY,
    at                  timestamptz NOT NULL DEFAULT now(),
    reporter_account    bigint REFERENCES accounts(id) ON DELETE SET NULL,
    reporter_character  bigint,
    reporter_name       text NOT NULL DEFAULT '',
    target_account      bigint REFERENCES accounts(id) ON DELETE SET NULL,
    target_character    bigint,
    target_name         text NOT NULL DEFAULT '',
    category            text NOT NULL,
    body                text NOT NULL DEFAULT '',
    map                 text NOT NULL DEFAULT '',
    context             jsonb NOT NULL DEFAULT '[]'::jsonb,
    status              text NOT NULL DEFAULT 'open'
);
CREATE INDEX reports_open ON reports (status, at DESC);

-- A character name with look-alike letters folded (realm_rules::names):
-- `Ali`, `Alı` and `A1i` share one. Filled at start for existing rows.
ALTER TABLE characters ADD COLUMN name_skeleton text;
CREATE INDEX characters_skeleton ON characters (name_skeleton) WHERE account_id IS NOT NULL;
