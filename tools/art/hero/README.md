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

6. Eyelashes: MakeHuman's lash proxy only gives the lid margins (its
   vertices touching the skin, binned along each lid). Our lash strips run
   along them, leave the lid forward and curl away from the eye (upper
   5.5-10 mm, longest on the outer third; lower 2-4 mm), mapped onto
   `lash_atlas.png` (`strand_atlas.py --lashes`: tapered lashes in clumps
   of two or three, a dense lash line at the roots). Each lash column rides
   the head vertex nearest its root through the eye sliders. The skin gets
   a thin lash-line shadow along the upper lid.

Shaders: `hero_face_skin.gdshader`, `hero_face_eye.gdshader`,
`hero_face_cornea.gdshader`; brows and lashes use the hair card shader.

Lighting: `HeroAppearance.add_character_fill` puts two shadowless lights on
the camera that light only the character layer: the fill (no specular) and
`CharacterRim`, a cool light from behind the characters toward the camera
that draws the thin bright edge round the hair, shoulders and face. DayNight
drives both with the hour. The world's lights are untouched.

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
   `max_z` keep a layer to the top or to the sides; cards rooted near the
   hairline are narrower and take the fine columns);
2. grows each card's centre line along the flow, stepping over the scalp and
   re-projecting onto it every step - the root on the scalp, rising to the
   layer's height + the lift curve (a root floating at the layer's height
   showed its straight cut end); cards that run past the hairline end at the
   style's `overhang` (a fringe may fall over the forehead, the sides not),
   and a card left shorter than `MIN_CARD` is dropped (a lock squeezed into
   a few mm is a dark chip: the hair cap carries the edge there);
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
7. writes `cap_<style>.png`, the style's **hair cap** in the head's UV:
   70 000 short strands (3-7 mm) walked along the same flow and drawn on the
   head texture (2x supersampled), thinner and shorter toward the hairline;
   R strand coverage, G shade, B the hair's shadow on the scalp. The skin
   shader composites it under the cards: the hairline, the part, the crown
   and the nape end in single hairs (a fade) with no extra geometry. The
   game gives each built style its own head material (`_head_material`).

`strand_atlas.py` draws the shared atlas (`hair_atlas.png`): one column per
card type (dense, locks, fine, single, strays). A column holds LOCKS - many
parallel strands spread over a lock's width that taper together to a point,
staggered soft roots, a few strands ending early - not loose random strands
(those read as frizz or straw). R strand id, G the strand's place in its
lock (each lock shades round), A coverage, 4x supersampled.

### Style keys beyond the basics

- `release` (q -> q.z): below it hair leaves the scalp and falls free; `fall`
  is how fast it turns down; free hair is kept clear of the head, the neck
  and the body (Hero_*_Body); `drop_skin` (z head, z chest) lets long ends
  ride Neck / UpperChest instead of the Head bone.
- `wave` (amplitude, wavelength) and `curl` (radius, period) are laid on each
  card's centre line (Wavy, Curly).
- A layer with `tail` (a point on the head in q) is a ponytail: `count` cards
  round the tie falling free, and `wraps` short cards wrapped round the tie.
- `region: "beard"` grows a style in build_head.py's beard zone (lips and
  nose bare; no style uses it since the beards were removed); its
  `hairline` function is then a density. `cap_shadow` / `cap_alpha` scale
  the cap's B (the soft hair shadow under the skin) and its strands. A
  style with no layers is drawn by its cap (and `shells`) alone (Buzzed).
- Layer keys: `min_z` / `max_z` (in q) keep a layer to a band, `depth`
  fixes its shade depth, `root_fade` fades the card in from its root (no
  visible cut root row), `edge_fade` (style, default 0.55-0.97 of the scalp
  weight) is where cards within 2 cm of the skin fade out toward the
  hairline, strand by strand (the hair cap draws the edge; hair that has
  fallen past `release` is never faded).

The game (`HeroAppearance`): `CARD_STYLES` lists every built style; the look's
hair is worn as "Hair"/"HairFar"; the head material is chosen per hair cap.

### Beards: removed (the owner, 2026-11-21)

Heroes are clean-shaven. The look keeps its `beard` pick (looks.json and the
server unchanged, saved looks still load) but the game draws no beard and
the character screen offers none. What was tried, for a later attempt:
- hand-placed cards hugging the jaw: flakes on the cheeks, straw hanging;
- shells (the cage risen in 6-12 layers, strand dots): a fuzzy velvet, cheap
  (+25 ms on a full-screen face, llvmpipe), judged far from a real beard;
- a real strand groom (160 000 numpy-grown hairs with clumps, noise, curl,
  stray and messy hairs, rendered in Cycles: right) baked into 800 cards,
  each card carrying its own clump's hairs in a per-style atlas: a real
  beard's clumps and strands, but woolly and dark in the game and 2.5x the
  shells' cost; shells baked from the same groom: slabs and spikes.
  Lessons: strands must be at least a texel wide in a card's tile (thinner,
  lone hairs never pass the alpha cut and clumps draw as solid shards); no
  per-card root darkening (fish scales); a dense groom needs its albedo
  lifted (multiple scattering) or brown reads black.

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
- On dark hair a lock lit evenly is a grey blob: the R lobe is modulated per
  strand (most strands catch little, a few a lot), so it reads as glints.
- UV seams: cap strands are drawn segment by segment (a strand crossing a
  seam was dropped whole: a bare line along every seam, e.g. under the
  jaw), and the cap is grown past the islands' edges.
- The neck's two UV islands disagree at their seams: build_head.py gives the
  neck under the jaw one mean skin and a flat detail normal.
- The neck is MakeHuman's own down to the collar (with its Adam's apple):
  widening it to the kit neck's girth made a ledge under the jaw, folds and
  a skirt; the side faces are taken within `NECK_SIDE_R` of the neck's axis
  and the notches that leaves are closed (a face sharing two edges with the
  kept ones is added); a straight two-row extension reaches into the shirt's
  V; behind and beside the neck the skin is pulled under the shirts (capped
  at 8 mm and smoothed over the neighbours: an uncapped push crumpled it).
- The kit's bare arms are brought to the MakeHuman face's mean colour and
  take the skin tone the face's way (`face_tone`, `ARM_TONE_MATCH`).
- The hairline, part and nape come from the hair cap texture, not from
  cards: card ends on the edge read as torn paper without TAA.

### Shading (`hero_hair_card.gdshaderinc`)

Kajiya-Kay along the strand with two shifted lobes (a soft highlight toward
the root, a coloured one toward the tip), wrapped diffuse, transmission when
lit from behind, root-to-tip gradient, per-lock round shading, per-layer
depth. Two passes: the opaque pass cuts coverage at `alpha_cut` (depth +
strand-shaped shadows); its `next_pass` (`hero_hair_fringe`) blends only the
coverage below the cut over it - soft edges without TAA or MSAA, which this
game does not run. Far mips get more coverage (`mip_coverage`) so hair does
not thin out at a distance; the fringe stops past `fringe_far`; past
`HeroAppearance.HAIR_NEAR` the far LOD is drawn without a fringe pass. The
atlas is sampled trilinear, not anisotropic (several cards deep, the extra
taps cost ~10 % of a full-screen face for no visible difference). Tips
swing with the head (`HairSway`, one damped spring per hero → instance
uniform `hair_sway`; the vertex shader never pushes a tip into the head).

### Adding a style

1. Copy a style in `hair_styles.py`, give it a new name and change its
   functions and layers.
2. `bash tools/art/hero/build_hero_head.sh --hair <Name>`, import.
3. Add the name to `HeroAppearance.CARD_STYLES` and, if new, to `content/data/looks.json` `hair_styles` **at the end**
   (saved looks keep their index; the server reads that list too, so a new
   entry ships with a server deploy).
4. Check offscreen renders from the front, side, back and top, in daylight
   and from behind the light.

Every style in `looks.json` is built (SimpleParted, Buzzed, Long, Wavy,
Tousled, Neat, Ponytail, Curly). A style added to `looks.json` before its
cards are built is drawn with its stand-in (`HeroAppearance.STAND_INS`).

Measured (llvmpipe, relative only; 16 heroes, mixed styles and beards):
141 ms a frame vs 136-146 ms with the old kit head - within the noise; a
face filling the screen with Long hair 229 ms vs 265 ms before. The rim
light is about 2 % of a crowd frame.

Cost: near meshes 16-28k triangles (drawn within `HAIR_NEAR`, 7 m, with
the fringe pass), far meshes 8-13k; Buzzed is its cap and shells. Small face parts stop drawing past `FACE_PART_REACH`
(lashes 9 m, corneas 12 m, brows 30 m, eyeballs 40 m).
