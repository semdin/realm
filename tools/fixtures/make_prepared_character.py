"""Writes the prepared character realm_netcheck uses for the paid item paths.

    python tools/fixtures/make_prepared_character.py build/characters 900002
    realm_server serve --map grounds --characters build/characters
    realm_netcheck --server 127.0.0.1:7777 --character 900002 --seconds 6

    python tools/fixtures/make_prepared_character.py build/travelcheck 900201 --travel-kit

The character stands at the Hearth Pavilion (its shop sells Hearth Dust), is
hurt (100 hp), has 10 000 oril, the starter wand, and in its bag: health
potions (cell 0), mana potions (1), Velkar Ash (2), imbue scrolls (3) and a
reweave scroll (4). The file is the CharacterSheet the server saves; run
again to reset it.

`--travel-kit` (the Godot client's --check-travel) also rides the Ashwood
Sweeper (broom slot), carries 5 Hearth Dust and a Waylink boot (cells 5 and
6), and stands on the grounds at the castle approach (spawn
`castle_approach`), facing the castle door.

    python tools/fixtures/make_prepared_character.py build/dungeoncheck 900301 --dungeon-kit

`--dungeon-kit` (the Godot client's --check-dungeon) is level 12 and stands
on the grounds beside the Trial Hall gate (portal `trial_entry`), where
realm_netcheck --dungeon seeds its own character.

    python tools/fixtures/make_prepared_character.py build/dungeoncheck 900302 --dungeon-kit --dungeon-cleared normal

`--dungeon-cleared <difficulty>` (with the kit) also writes a gold-medal clear
of the Trial Hall on that difficulty (and every easier one), so the next one
up is unlocked: `normal` opens Hard, the first difficulty with a curse
(--check-dungeon-difficulty 2).

    python tools/fixtures/make_prepared_character.py build/dungeoncheck 900303 --dungeon-kit --dungeon-cleared normal --seals 20

`--seals N` also carries N Dungeon Seals (cell 7) for the seal shop (the
Godot client's --check-guide).
"""
import json
import os
import sys

# realm_rules::dungeons difficulties in protocol order.
DIFFICULTIES = ["easy", "normal", "hard", "very_hard", "legendary"]


def item(item_id, amount=1, uid=0):
    return {"id": item_id, "amount": amount, "tier": 0, "uid": uid, "bonuses": []}


def main():
    argv = sys.argv[1:]
    cleared = ""
    if "--dungeon-cleared" in argv:
        at = argv.index("--dungeon-cleared")
        cleared = argv[at + 1]
        del argv[at:at + 2]
        if cleared not in DIFFICULTIES:
            sys.exit("--dungeon-cleared: one of " + ", ".join(DIFFICULTIES))
    seals = 0
    if "--seals" in argv:
        at = argv.index("--seals")
        seals = int(argv[at + 1])
        del argv[at:at + 2]
    args = [a for a in argv if not a.startswith("--")]
    travel_kit = "--travel-kit" in argv
    dungeon_kit = "--dungeon-kit" in argv
    folder, character = args[0], int(args[1])
    bag = [None] * 40
    bag[0] = item("potion_health", 5)
    bag[1] = item("potion_mana", 5)
    bag[2] = item("mat_phoenix_ash", 10)
    bag[3] = item("scroll_imbue", 5)
    bag[4] = item("scroll_reweave", 2)
    equipment = [None] * 10
    equipment[4] = item("wand_ashwood", uid=4242)  # main_hand
    sheet = {
        "id": character, "name": "Prepared %d" % (character % 10000), "house": "velkar",
        "level": 1, "exp": 0, "hp": 100, "mana": 300, "base_max_hp": 500, "base_max_mana": 300,
        "oril": 10000, "bag": bag, "equipment": equipment, "look": [],
        # Hearth Pavilion (travel.json), dropped onto the ground from above.
        "place": {"map": "grounds", "pos": [-21.0, 60.0, 20.0], "yaw": 0.0},
        "revision": 1,
    }
    if travel_kit:
        equipment[9] = item("broom_ashwood", uid=4243)  # broom
        bag[5] = item("hearth_dust", 5)
        bag[6] = item("waylink_boot", 1)
        # maps.json grounds spawn_points.castle_approach
        sheet["place"] = {"map": "grounds", "pos": [0.0, 58.49, 20.0], "yaw": 0.0}
    if dungeon_kit:
        sheet["level"] = 12
        # beside maps.json portal trial_entry (its trigger is at 70, 58, 69)
        sheet["place"] = {"map": "grounds", "pos": [70.0, 58.3, 63.0], "yaw": 0.0}
    if seals > 0:
        bag[7] = item("dungeon_seal", seals)
    if cleared:
        # realm_rules::dungeons DungeonLog: gold (rank 3) on every difficulty
        # up to `cleared`, no reward taken today.
        records = [{"dungeon": "trial", "difficulty": i, "rank": 3, "best_ms": 100000, "day": 0, "rewarded": 0}
                   for i in range(DIFFICULTIES.index(cleared) + 1)]
        sheet["dungeons"] = {"records": records, "last_rewarded_day": 0, "titles": []}
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, "%d.json" % character)
    with open(path, "w", encoding="utf-8", newline="\n") as out:
        json.dump(sheet, out, indent=2)
    print("wrote", path)


if __name__ == "__main__":
    main()
