"""Writes the prepared character realm_netcheck uses for the paid item paths.

    python tools/fixtures/make_prepared_character.py build/characters 900002
    realm_server serve --map grounds --characters build/characters
    realm_netcheck --server 127.0.0.1:7777 --character 900002 --seconds 6

The character stands at the Hearth Pavilion (its shop sells Hearth Dust), is
hurt (100 hp), has 10 000 oril, the starter wand, and in its bag: health
potions (cell 0), mana potions (1), Velkar Ash (2), imbue scrolls (3) and a
reweave scroll (4). The file is the CharacterSheet the server saves; run
again to reset it.
"""
import json
import os
import sys


def item(item_id, amount=1, uid=0):
    return {"id": item_id, "amount": amount, "tier": 0, "uid": uid, "bonuses": []}


def main():
    folder, character = sys.argv[1], int(sys.argv[2])
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
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, "%d.json" % character)
    with open(path, "w", encoding="utf-8", newline="\n") as out:
        json.dump(sheet, out, indent=2)
    print("wrote", path)


if __name__ == "__main__":
    main()
