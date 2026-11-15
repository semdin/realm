-- The realm's store (realm_persist owns it; nothing else writes here).

CREATE TABLE accounts (
    id            bigserial PRIMARY KEY,
    username      text NOT NULL,
    password_hash text NOT NULL,                    -- argon2id PHC string
    created_at    timestamptz NOT NULL DEFAULT now(),
    last_login    timestamptz
);
CREATE UNIQUE INDEX accounts_username_key ON accounts (lower(username));

-- One row per character: the whole sheet as the game keeps it (jsonb), and
-- the few fields the services look things up by. A character made before
-- logins (a development character) has no account.
CREATE TABLE characters (
    id          bigint PRIMARY KEY,
    account_id  bigint REFERENCES accounts(id) ON DELETE CASCADE,
    name        text NOT NULL,
    name_key    text NOT NULL,                       -- lower(trim(name))
    house       text NOT NULL,
    level       integer NOT NULL,
    map         text,
    revision    bigint NOT NULL,
    sheet       jsonb NOT NULL CHECK (jsonb_typeof(sheet) = 'object'),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX characters_account ON characters (account_id);
-- Names are unique among players' characters, whatever the case.
CREATE UNIQUE INDEX characters_name_key ON characters (name_key) WHERE account_id IS NOT NULL;

-- What happened to whom, for valuable operations (filled from 7.0b on).
CREATE TABLE audit (
    id           bigserial PRIMARY KEY,
    character_id bigint,
    at           timestamptz NOT NULL DEFAULT now(),
    kind         text NOT NULL,
    detail       jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX audit_character ON audit (character_id, at);
