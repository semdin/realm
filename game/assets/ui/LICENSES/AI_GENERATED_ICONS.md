# AI-generated icon provenance

Created: 2026-10-08. Tool: OpenAI Imagegen. Scope: the 64 `icon_<id>.png` files and
`icons_preview.jpg` under `assets/ui/icons/`, listed with their SHA-256 hashes in the
pack's own `icon_manifest.json`. All asset sources: `assets/ASSET_CREDITS.md`.

This is a provenance note, not a CC0 dedication and not a replacement for the
project's licence. No third-party icon set was used as an image input in generating
this pack: the images were produced from text prompts describing project ids and
visual directions, then scaled to a common delivery size with the alpha channel
preserved. User-supplied fictional names and visual descriptions guided generation;
this note does not grant rights in third-party names, characters or trademarks.

Retain existing third-party licence notices for assets that remain in use. The
gnola14 CC0 pack this set replaced is no longer distributed: its licence text stays
at `assets/ui/LICENSES/oga-rpg-icons-496.txt`. Do not delete those records automatically.

## 2026-10-13 additions (fal.ai)

Tool: fal.ai `fal-ai/nano-banana-2.1` (1K, 1:1), same text-prompt template as the
spell and potion icons. No third-party image was used as an input.

* `icon_menu_{inventory,mount,journal,map,settings}.png` - full-bleed
  square paintings for the bottom-right menu cells, resized to 256 px.
* `icon_minimap_{player,mob,boss,npc,monolith,zoom_in,zoom_out}.png` - single
  objects generated on flat white, cut out by `tools/ui/cutout_icons.py`
  (border-connected white removed, soft edge alpha with the white un-mixed),
  trimmed square and resized to 128 px. They replace the previous minimap set.

## 2026-10-16 additions (fal.ai) - broom tiers

Tool: fal.ai `google/nano-banana-2.1/edit` (1K, 1:1). Input image: the project's
own broom concept painting for that tier (generated the same day with
`openai/gpt-image-2.5/sunburst`, kept in `art/brooms/<tier>/views/main.png`);
no third-party image was used.

* `icon_broom_{ashwood,runebound,silverthorn,emberwing,moonveil}.png` - the
  tier's broom shown diagonally on flat white with its aura colour, cut out by
  `tools/ui/cutout_icons.py` (`item_<id>.png` sources) and resized to 512 px to
  match the earlier `icon_broom_*` icons. Sources: `art/brooms/icons_src/`.

## 2026-10-16 additions (fal.ai) - enchantment scrolls

Tool: fal.ai `google/nano-banana-2.1` (1K, 1:1), text prompt only (no input image).

* `icon_scroll_{imbue,reweave}.png` - the Rune of Imbuing (green) and Rune of
  Reweaving (violet) scrolls on flat white, cut out by `tools/ui/cutout_icons.py`
  (`item_<id>.png` sources in `art/enchant/icons_src/`), 512 px.

## 2026-10-16 additions (fal.ai) - cloak tiers

Tool: fal.ai `google/nano-banana-2.1/edit` (1K, 1:1). Input image: the project's own
cloak fabric texture for that tier (generated the same day with
`openai/gpt-image-2.5/sunburst`, shipped as `assets/models/cloaks/cloak_<tier>.png`);
no third-party image was used.

* `icon_cloak_{wool,runed,thornveil,phoenix,moonveil}.png` - the cloak seen from the
  back on flat white, cut out by `tools/ui/cutout_icons.py` (`item_<id>.png` sources
  in `art/cloaks/icons_src/`), 512 px.

## 2026-10-16 additions (fal.ai) - wand tiers

Tool: fal.ai `google/nano-banana-2.1/edit` (1K, 1:1). Input image: the project's own
wand concept for that tier (generated the same day with `openai/gpt-image-2.5/sunburst`,
kept in `art/wands/concepts/`); no third-party image was used.

* `icon_wand_{ashwood,runebound,silverthorn,emberwing,moonveil}.png` - the wand shown
  diagonally on flat white, cut out by `tools/ui/cutout_icons.py` (`item_<id>.png`
  sources in `art/wands/icons_src/`), 512 px. The in-game wand meshes themselves are
  procedural (`art/wands/scripts/build_wands.py`).

## 2026-10-18 additions (fal.ai) - accessory tiers T2-T5

Tool: fal.ai `fal-ai/nano-banana-2.1` (1K, 1:1), text prompt only (no input image):
"Square MMORPG inventory item icon of <object>. <tier look>. The object is isolated on
a pure flat white background, ... Style: rich hand-painted fantasy game icon like World
of Warcraft item icons ...".

* `icon_{hat,gloves,boots,focus,pendant,ring}_{runebound,silverthorn,emberwing,moonveil}.png`
  (24 icons) - generated on flat white and cut out by `tools/ui/cutout_icons.py`
  (`item_<id>.png` sources in `art/accessories/icons_src/`), 512 px. Tier looks follow
  the wand/cloak tiers: brass runes, silver thorns + emeralds, crimson-gold phoenix,
  moonlit mithril + star crystal.

## 2026-10-18 additions (fal.ai) - HUD menu buttons

Tool: fal.ai `google/nano-banana-2.1` (1K, 1:1), the same full-bleed menu-icon text
template as the 2026-10-13 menu set, text prompt only (no input image).

* `icon_menu_{skills,character,quests}.png` - full-bleed square paintings for
  the bottom-right menu cells (wand + spellbook, hooded wizard before a gold crest,
  sealed quest scroll), resized to 256 px by
  `tools/ui/cutout_icons.py` (`menu_<id>.png` sources in `art/ui_menu_icons_2026-10-18/src/`).

* `icon_queen_seal.png`, `icon_mat_weaver_venom.png`, `icon_mat_spider_silk.png` (2026-10-19,
  Blackweb Caverns materials) - `openai/gpt-image-2.5/sunburst/text-to-image` 1024 px with the
  standard full-bleed item-icon template (obsidian spider seal in silk; venom vial with a fang;
  spool of pearly silk), resized to 512 px. Sources in `art/spider_caverns/icons/`.
* `icon_ultimate.png` (2026-10-24, Starfall) - `fal-ai/nano-banana-2.1`
  full-bleed icon template (white-gold falling star over a violet spiral ring of starlight), 512 px.
  Source `art/vfx/stella_ruina/icon_b.png`.
* `icon_frost_grip.png` (2026-10-24, Frost_Grip) - `openai/gpt-image-2.5/sunburst/edit` with `icon_stun_bolt.png` and
  `icon_ultimate.png` as style references (pale-blue ice crystal bursting into a ring of frost shards
  on deep blue), resized from 1024 to 512 px. Source `art/vfx/frost_grip/icon_a.png`.
* `icon_dungeon_seal.png` (2026-10-30, dungeon rewards Z3) - `openai/gpt-image-2.5/sunburst/edit` with
  `icon_queen_seal.png` as the style reference (red wax seal with a portcullis on stone), resized from
  1024 to 512 px. Source `art/dungeons/icons/`.

## 2026-11-19 additions (fal.ai) - Seedream 5.5

Tool: fal.ai `bytedance/seedream/v5.5/edit` (Seedream 5.5, 1024 px, 1:1), a text prompt plus one of
the project's own images as the style reference (`icon_dungeon_seal.png`, `icon_flame_wave.png`,
`icon_boots_runebound.png` or `bestiary/armour_guard.png`). No third-party image was used as an input.
Cut-out files use the model's transparent-background output, trimmed and centred. Everything was
resized with Lanczos. For a file listed here, this entry is its current provenance.

Full-bleed icons, 512 px:

* `icon_light_of_ithrel.png` - Dawnbreak: white-gold dawn light fanning through grey mist.
* `icon_stun_bolt.png` - Starnail: a splinter of star crystal driven down into cracked stone.
* `icon_disarm.png` - Hushing Gale: a silver-blue gust spiralling out of an open gloved palm.
* `icon_ward_shield.png` - Shardglass Ward: a faceted wall of pale crystal catching a fiery bolt.
* `icon_hearth_dust.png` - Waycoal: a lump of coal with glowing amber cracks held in iron tongs.
* `icon_waylink_boot.png` - Waystake: a forged iron stake with a knotted blue-grey cord, driven into
  earth with a faint cold glow.
* `icon_key_sealed_wing.png` - Brine Vault Key: a corroded brass key with a sluice-wheel bow and salt
  crust on wet dark stone.
* `icon_key_trial.png` - Trial Hall Key: a heavy black iron key with a riveted square bow on flagstone.

Full-bleed menu icons, 256 px:

* `icon_menu_bestiary.png` - a leather field ledger with iron corners and a beast talon as its clasp.
* `icon_menu_kestrin.png` - a hammer striking a white-hot bar on an anvil.

Cut-out icons, 512 px:

* `icon_mat_phoenix_ash.png` - Forge Cinder: glowing cinders on a small iron shovel.
* `icon_mat_dragon_heartstring.png` - Deepvein Ore: a lump of dark ore split by a bright vein.
* `icon_mat_night_steed_hair.png` - Starfall Filings: silver filings in a leather-lined dish.
* `icon_mat_elder_core.png` - Keystone Ingot: a wedge-shaped ingot of dark star-metal.
* `icon_broom_windcutter_2000.png` - Reedrunner: bound lake reed on a bent pale ash haft.
* `icon_broom_skysplitter.png` - Thunderhaft: dark storm-seasoned oak with an iron keel.
* `icon_wand_hawthorn.png` - Thornbark Rod: a thorny bark rod wrapped in salt-cured cord.
* `icon_wand_ithrel_replica.png` - Starcore Rod: a forged iron bar with glowing seams.
* `icon_status_despair.png` - Numbed: frost creeping over a clenched hand.
* `icon_ui_kestrin.png` - a smith's hammer on a glowing bar across an anvil.

Bestiary portraits, `assets/ui/bestiary/`, cut-out, 320 px:

* `pallid.png` - Mistguard: empty salt-bleached plate armour leaking mist.
* `wheelwarden.png` - Wheelwarden: a brass and iron colossus with a great gear wheel, in flood water.
* `goblin_teller.png` - Goblin Scavenger: a goblin in patched leathers hauling a sack of scrap.
* `goblin_guard.png` - Goblin Bruiser: a goblin in scrap-metal armour with an improvised club.
* `goblin_hexer.png` - Goblin shard-burner: a goblin in patched leathers and scrap charms with glowing
  dust between its palms.
* `fidgetling.png` - Galeling: a grey-violet wind sprite trailing into a curl of air.
* `drowned_one.png` - Saltwight: a dried corpse crusted with lake salt on a salt shore.
* `drowned_warden.png` - Brine Warden: a salt-crusted dried corpse in rusted mail with a spear.
* `strangling_vine.png` - Brinebriar: a thorny salt-crusted briar growing through a broken floor.
