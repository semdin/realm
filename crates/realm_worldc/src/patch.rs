//! Collider patches: solid things the old world draws but never gave a
//! collider (the stone flanks under some castle stairs, iron racks). They
//! live in `world/patches/<map>.json`, next to the packs, as boxes:
//!
//!   {"boxes": [{"note": "...", "center": [x, y, z], "half": [hx, hy, hz],
//!               "yaw_deg": 0, "obstacle": false}]}
//!
//! An `obstacle` box (a tree trunk, a spire) is solid to bodies and cut out
//! of the navmesh, but not ground for things placed from above (packs,
//! arrivals): it goes to the pack's `obstacles`, the others to `colliders`.
//!
//! `build` adds them to the map's static colliders before the navmesh is
//! baked; `patch` lays them on packs that are already built: the boxes an
//! earlier patch laid (the pack counts them) come out first, so the file is
//! always the one truth; then the navmesh is baked again.

use std::path::Path;

use realm_sim::pack::{MapPack, PackCollider, PackShape};
use serde_json::Value;

fn num(v: &Value, what: &str) -> Result<f32, String> {
    v.as_f64()
        .map(|x| x as f32)
        .ok_or_else(|| format!("patch: {what} is not a number"))
}

fn triple(v: &Value, what: &str) -> Result<[f32; 3], String> {
    let a = v
        .as_array()
        .filter(|a| a.len() == 3)
        .ok_or_else(|| format!("patch: {what} needs three numbers"))?;
    Ok([num(&a[0], what)?, num(&a[1], what)?, num(&a[2], what)?])
}

/// The patch boxes for `map` (none when it has no patch file), with
/// whether each is an obstacle.
pub fn boxes(patches_dir: &Path, map: &str) -> Result<Vec<(PackCollider, bool)>, String> {
    let path = patches_dir.join(format!("{map}.json"));
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Ok(Vec::new());
    };
    let doc: Value = serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut out = Vec::new();
    for b in doc["boxes"].as_array().into_iter().flatten() {
        let center = triple(&b["center"], "center")?;
        let half = triple(&b["half"], "half")?;
        if half.iter().any(|h| *h <= 0.0) {
            return Err(format!("{}: a box with no size", path.display()));
        }
        let yaw = b["yaw_deg"].as_f64().unwrap_or(0.0).to_radians() as f32;
        let (s, c) = (yaw * 0.5).sin_cos();
        out.push((
            PackCollider {
                translation: center,
                rotation: [0.0, s, 0.0, c],
                shape: PackShape::Box { half },
            },
            b["obstacle"].as_bool().unwrap_or(false),
        ));
    }
    Ok(out)
}

/// Lays `map`'s patch boxes on `pack` in place of the ones an earlier patch
/// laid: (boxes now, whether anything changed).
pub fn apply(pack: &mut MapPack, patches_dir: &Path, map: &str) -> Result<(usize, bool), String> {
    let keep = pack
        .colliders
        .len()
        .saturating_sub(pack.patch_colliders as usize);
    let before = (
        pack.colliders.split_off(keep),
        std::mem::take(&mut pack.obstacles),
    );
    let mut laid = 0;
    for (b, obstacle) in boxes(patches_dir, map)? {
        if obstacle {
            pack.obstacles.push(b);
        } else {
            pack.colliders.push(b);
            laid += 1;
        }
    }
    pack.patch_colliders = laid as u32;
    let total = laid + pack.obstacles.len();
    let same = |a: &[PackCollider], b: &[PackCollider]| {
        a.len() == b.len()
            && a.iter()
                .zip(b)
                .all(|(x, y)| format!("{x:?}") == format!("{y:?}"))
    };
    let changed = !same(&before.0, &pack.colliders[keep..]) || !same(&before.1, &pack.obstacles);
    Ok((total, changed))
}
