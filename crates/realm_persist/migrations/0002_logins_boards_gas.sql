-- 7.0b: the login service's characters, the coordinator's weekly boards and
-- game admins.

-- Characters the login service makes are numbered from here (development
-- characters live below; an id already taken is skipped).
CREATE SEQUENCE character_ids START WITH 10000000;

-- A dungeon's fastest clears at one difficulty this week
-- (realm_proto::coord::Board, whole, in `data`).
CREATE TABLE boards (
    dungeon     text NOT NULL,
    difficulty  integer NOT NULL,
    week        integer NOT NULL,
    data        jsonb NOT NULL CHECK (jsonb_typeof(data) = 'object'),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (dungeon, difficulty)
);

-- Game admins, by character name (lower(trim(name))).
CREATE TABLE gas (
    name_key  text PRIMARY KEY,
    added_at  timestamptz NOT NULL DEFAULT now()
);
