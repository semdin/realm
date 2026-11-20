# Hero head and hair pipeline

The player hero's head, face sliders and hairstyles. Everything here is a
script; the outputs land in `game/assets/models/characters/face/` and
`.../hair/`, and the game puts them on the body at run time
(`scripts/entities/hero_appearance.gd`: `install_head`, `_wear_hair`). The
body model (`hero_wizard.glb`) is not rebuilt for any of this.

## Tools and sources (all free, commercial use allowed)

| what | source | licence |
|---|---|---|
| head, neck, eyes, lashes, brows, skins, face targets | MakeHuman via MPFB2 2.0.18 + its system asset pack | CC0 |
| pore micro normal (`skin_micro.png`, already in the game) | HumanShaders, MatMADNESS | CC BY 4.0 (ASSET_CREDITS.md) |
| strand atlas, hair cards, shaders | these scripts | ours |

Blender 5.2 with MPFB2 installed as an extension and the CC0 asset pack
loaded (`bpy.ops.mpfb.load_pack`). The hero's source blend
(`art/characters/hero_q/hero_q_game.blend`, local, not in git) supplies the
game rig (`GameRig`, same rest pose as `hero_wizard.glb`) and the old kit
head's neck ring and neck weights.

## One command

```
bash tools/art/hero/build_hero_head.sh                    # head + atlas + every style
bash tools/art/hero/build_hero_head.sh --hair SimpleParted # one style (head built before)
```

Then let Godot import the new files (headless `godot --import`). New PNGs
get default import settings: set `compress/mode=2` (VRAM) and
`process/size_limit=0` on the face and hair textures, `compress/normal_map=1`
on `head_normal.png`, and import again.

## The head (`build_head.py`)

1. MPFB builds one human (`PHENOTYPE`, a light `BASE_FACE`) with high-poly
   eyes, eyelashes and every brow in `BROWS`; it is scaled to the hero's
   height and its neck centred on the body's neck.
2. Every face slider of `content/data/looks.json` is measured: its MakeHuman
   targets (`FACE_SLIDERS`, at ±1 × `SLIDER_GAIN`) are set on the base mesh,
   MPFB refits the eyes, brows and lashes, and the positions are stored. Face
   types (`FACE_TYPES`) the same at `FACE_TYPE_WEIGHT`. The game sets the keys
   at the slider's value (`FACE_KEY_GAIN` 1.0): tune strength here, in
   `SLIDER_GAIN`, not in the game.
3. Head and neck are cut from MakeHuman's head UV island plus the neck's
   sides (torso island) above `NECK_KEEP`; the bottom ring is extended under
   the collar (radius eased to the old neck's). One Catmull-Clark level (the
   keys subdivided the same way). Weights come from the old head (neck) and
   are all `Head` on the face.
4. Textures: the photo skin's head island is copied and the neck sides are
   unrolled into strips beside it (`head_albedo.png`, the dark skin's the
   same layout `head_albedo_dark.png`); `head_normal.png` is the photo's
   fine shading as height; `head_zones.png` R beard area, G oily zones, B
   redness, A MakeHuman's scalp - all generated from 3D landmarks.
5. Eyes: the lids' shadow on each eyeball vertex is baked by ray casts into
   the head (the eyes do not turn), and the cornea shell is split off
   (`Face_Cornea`, additive wet reflections).

Shaders: `hero_face_skin.gdshader`, `hero_face_eye.gdshader`,
`hero_face_cornea.gdshader`; brows and lashes use the hair card shader.

## Hair: cards from a groomed flow

A hairstyle is **data** in `hair_styles.py`: where hair grows (`hairline`,
multiplied by MakeHuman's scalp), which way it is combed (`flow`), how long it
is (`length`), how much it stands off the scalp (`lift`), and its card
`layers` (inside out: spacing, width, atlas columns, height over the scalp,
length, noise, twist, bow). The functions get `q`, the point relative to the
skull sphere (|q| ≈ 1; +x the hero's left, −y the face, +z up).

`hair_cards.py <style>`:
1. samples card roots per layer (Poisson disk at the layer's spacing; the
   inner layers stay where MakeHuman's scalp weight is over 0.7, the
   `edge` hairline layer only in the band where it fades out; `min_z` /
   `max_z` keep a layer to the top or to the sides);
2. grows each card's centre line along the flow, stepping over the scalp and
   re-projecting onto it every step - the root on the scalp, rising to the
   layer's height + the lift curve (a root floating at the layer's height
   showed its straight cut end); cards that run past the hairline end at the
   style's `overhang` (a fringe may fall over the forehead, the sides not);
3. sweeps a ribbon (3 vertices across, the middle bowed outward, a random
   twist, narrowing to the tip) with an atlas column across it and root →
   tip down it; cards rooted on the hairline take the fine columns;
4. writes the shader's card data: UV2 = (root..tip, layer depth), COLOR =
   (random, swing, occlusion), normals bent out of the skull (the hair lights
   as one volume); a layer's `depth` can be set (the hairline layer sits on
   the outside, never in the hair's shadow);
5. adds a shape key for each head key that moves the scalp (face types, age,
   ears, a fringe over the brows), so the hair follows the face sliders;
6. writes a far LOD (`Hair_<style>_far`: the sides, base and main layers,
   every other row, about 40 % of the triangles) into the same glb;
7. writes `scalp_<style>.png` (head UV, soft toward the hairline): the skin
   shader paints short hair in the hair colour under the style.

`strand_atlas.py` draws the shared atlas (`hair_atlas.png`): one column per
card type (dense, locks, fine, single, strays). A column holds LOCKS - many
parallel strands spread over a lock's width that taper together to a point,
staggered soft roots, a few strands ending early - not loose random strands
(those read as frizz or straw). R strand id, G the strand's place in its
lock (each lock shades round), A coverage, 4x supersampled.

### What made it look like hair (and what did not)

- Locks, not strands: an atlas of random thin strands read as straw; tubes
  of strands with strong round shading read as noodles; full locks with
  subtle shading read as hair.
- Matte: the Korean MMO reference (AION 2) hair is soft and matte; a broad
  white R lobe made grey plastic patches. One highlight shift per card broke
  the band into patches: shift per strand only.
- The light's own `light_specular` must scale the lobes (SPECULAR_AMOUNT):
  the camera's character fill has none.
- Short sides and back lie flat on the head as narrow, dense, overlapping
  cards (HairTool's short-hair advice); volume (lift) only on top.
- Roots grow out of the scalp; the hairline layer is lit like the outside.
- Brows (MakeHuman cards) need almost no sheen: their albedo is so dark that
  any broad lobe turned them grey.

### Shading (`hero_hair_card.gdshaderinc`)

Kajiya-Kay along the strand with two shifted lobes (a soft highlight toward
the root, a coloured one toward the tip), wrapped diffuse, transmission when
lit from behind, root-to-tip gradient, per-lock round shading, per-layer
depth. Two passes: the opaque pass cuts coverage at `alpha_cut` (depth +
strand-shaped shadows); its `next_pass` (`hero_hair_fringe`) blends only the
coverage below the cut over it - soft edges without TAA or MSAA, which this
game does not run. Far mips get more coverage (`mip_coverage`) so hair does
not thin out at a distance; the fringe stops past `fringe_far`; past
`HeroAppearance.HAIR_NEAR` the far LOD is drawn without a fringe pass. Tips
swing with the head (`HairSway`, one damped spring per hero → instance
uniform `hair_sway`; the vertex shader never pushes a tip into the head).

### Adding a style

1. Copy a style in `hair_styles.py`, give it a new name and change its
   functions and layers.
2. `bash tools/art/hero/build_hero_head.sh --hair <Name>`, import.
3. Add the name to `HeroAppearance.CARD_STYLES` (order = scalp mask layers)
   and, if new, to `content/data/looks.json` `hair_styles` **at the end**
   (saved looks keep their index; the server reads that list too, so a new
   entry ships with a server deploy).
4. Check offscreen renders from the front, side, back and top, in daylight
   and from behind the light.

Styles in `looks.json` that have no cards yet are drawn with
its stand-in (`HeroAppearance.STAND_INS`).
