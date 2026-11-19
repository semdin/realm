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
//! `"remove": [{"note": "...", "min": [x, y, z], "max": [x, y, z]}]` takes
//! out the export's colliders whose bounds lie wholly inside one of those
//! world-space boxes: solids the old world had that the drawn map no longer
//! has (the Feast Hall's old long tables and benches, moved). A removal is
//! for good on a built pack (`build` from the export applies it again).
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

/// A world-space box: min and max corners.
pub type Bounds = ([f32; 3], [f32; 3]);

/// The `remove` boxes for `map`.
pub fn removals(patches_dir: &Path, map: &str) -> Result<Vec<Bounds>, String> {
    let path = patches_dir.join(format!("{map}.json"));
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Ok(Vec::new());
    };
    let doc: Value = serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut out = Vec::new();
    for b in doc["remove"].as_array().into_iter().flatten() {
        let lo = triple(&b["min"], "remove min")?;
        let hi = triple(&b["max"], "remove max")?;
        if (0..3).any(|i| hi[i] <= lo[i]) {
            return Err(format!("{}: a remove box with no size", path.display()));
        }
        out.push((lo, hi));
    }
    Ok(out)
}

/// `v` turned by the unit quaternion `q` (x, y, z, w).
fn rotate(q: [f32; 4], v: [f32; 3]) -> [f32; 3] {
    let u = [q[0], q[1], q[2]];
    let cross = |a: [f32; 3], b: [f32; 3]| {
        [
            a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0],
        ]
    };
    let t = cross(u, v).map(|c| 2.0 * c);
    let ut = cross(u, t);
    [
        v[0] + q[3] * t[0] + ut[0],
        v[1] + q[3] * t[1] + ut[1],
        v[2] + q[3] * t[2] + ut[2],
    ]
}

/// A collider's world-space bounds.
fn bounds(c: &PackCollider) -> Bounds {
    let local: Vec<[f32; 3]> = match &c.shape {
        PackShape::Box { half } => (0..8)
            .map(|k| {
                [
                    if k & 1 == 0 { -half[0] } else { half[0] },
                    if k & 2 == 0 { -half[1] } else { half[1] },
                    if k & 4 == 0 { -half[2] } else { half[2] },
                ]
            })
            .collect(),
        PackShape::Sphere { radius } => {
            vec![[-radius, -radius, -radius], [*radius, *radius, *radius]]
        }
        PackShape::Capsule {
            half_height,
            radius,
        } => vec![
            [-radius, -half_height - radius, -radius],
            [*radius, half_height + radius, *radius],
        ],
        PackShape::Cylinder {
            half_height,
            radius,
        } => vec![
            [-radius, -half_height, -radius],
            [*radius, *half_height, *radius],
        ],
        PackShape::Convex { points } => points.clone(),
        PackShape::TriMesh { vertices, .. } => vertices.clone(),
    };
    let mut lo = [f32::MAX; 3];
    let mut hi = [f32::MIN; 3];
    for p in local {
        let w = rotate(c.rotation, p);
        for i in 0..3 {
            lo[i] = lo[i].min(w[i] + c.translation[i]);
            hi[i] = hi[i].max(w[i] + c.translation[i]);
        }
    }
    (lo, hi)
}

/// Takes out of `colliders` every one lying wholly inside a `remove` box;
/// how many went.
pub fn remove_inside(colliders: &mut Vec<PackCollider>, boxes: &[Bounds]) -> usize {
    let before = colliders.len();
    colliders.retain(|c| {
        let (lo, hi) = bounds(c);
        !boxes
            .iter()
            .any(|(blo, bhi)| (0..3).all(|i| lo[i] >= blo[i] - 1e-3 && hi[i] <= bhi[i] + 1e-3))
    });
    before - colliders.len()
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
    let removed = remove_inside(&mut pack.colliders, &removals(patches_dir, map)?);
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
    let keep = keep - removed;
    let changed = removed > 0
        || !same(&before.0, &pack.colliders[keep..])
        || !same(&before.1, &pack.obstacles);
    Ok((total, changed))
}
