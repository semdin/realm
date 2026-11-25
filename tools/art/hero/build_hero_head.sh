#!/usr/bin/env bash
# Rebuild the hero's head, then every hairstyle (or the ones named), into
# game/assets/models/characters/{face,hair}. Blender 5.2 + MPFB2 (with its
# CC0 asset pack) must be installed; see README.md.
#   bash tools/art/hero/build_hero_head.sh            # head + all styles
#   bash tools/art/hero/build_hero_head.sh --hair SimpleParted   # one style only
# Afterwards import in Godot (the new files get .import files; set the
# textures' compress/mode=2 the first time, see README.md) and check renders.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd -W 2>/dev/null || pwd)"
REALM="$(cd "$HERE/../../.." && pwd -W 2>/dev/null || pwd)"
B="${BLENDER:-/c/Program Files/Blender Foundation/Blender 5.2/blender.exe}"
# the hero source blend (art/, kept local) and a work folder for intermediates
SRC="${HERO_SOURCE:-C:/Users/mehme/Desktop/sem/projects/game/art/characters/hero_q/hero_q_game.blend}"
WORK="${HERO_WORK:-C:/Users/mehme/Desktop/sem/projects/game/art/characters/hero_face/work}"
FACE="$REALM/game/assets/models/characters/face"
HAIR="$REALM/game/assets/models/characters/hair"
mkdir -p "$WORK" "$FACE" "$HAIR"
STYLES=()
if [ "${1:-}" = "--hair" ]; then
    shift
    STYLES=("$@")
else
    "$B" -b "$SRC" --python "$HERE/build_head.py" -- "$FACE" "$WORK" > "$WORK/build_head.log" 2>&1
    grep -E "^\[head\] (skin pack|head keys|exported|done)|Error|Traceback" "$WORK/build_head.log" | cut -c1-200
    python "$HERE/strand_atlas.py" "$HAIR/hair_atlas.png"
    python "$HERE/clump_atlas.py" "$HAIR/hair_clumps.png"
    STYLES=($(cd "$HERE" && python -c "import hair_styles; print(' '.join(hair_styles.STYLES))"))
fi
for style in "${STYLES[@]}"; do
    "$B" -b "$WORK/hero_head_work.blend" --python "$HERE/hair_cards.py" -- "$style" "$HAIR" "$WORK" > "$WORK/hair_$style.log" 2>&1
    grep -E "^\[hair\] (cards|hair follows|exported)|Error|Traceback" "$WORK/hair_$style.log" | cut -c1-200
done
echo BUILD_DONE
