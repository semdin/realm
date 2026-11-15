//! Collider patches: solid things the old world draws but never gave a
//! collider (the stone flanks under some castle stairs, iron racks). They
//! live in `world/patches/<map>.json`, next to the packs, as boxes:
//!
//!   {"boxes": [{"note": "...", "center": [x, y, z], "half": [hx, hy, hz],
//!               "yaw_deg": 0}]}
//!
//! `build` adds them to the map's static colliders before the navmesh is
//! baked; `patch` adds them to packs that are already built (a box already
//! in the pack is not added twice) and bakes the navmesh again.

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

/// The patch boxes for `map` (none when it has no patch file).
pub fn boxes(patches_dir: &Path, map: &str) -> Result<Vec<PackCollider>, String> {
    let path = patches_dir.join(format!("{map}.json"));
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Ok(Vec::new());
    };
    let doc: Value =
        serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut out = Vec::new();
    for b in doc["boxes"].as_array().into_iter().flatten() {
        let center = triple(&b["center"], "center")?;
        let half = triple(&b["half"], "half")?;
        if half.iter().any(|h| *h <= 0.0) {
            return Err(format!("{}: a box with no size", path.display()));
        }
        let yaw = b["yaw_deg"].as_f64().unwrap_or(0.0).to_radians() as f32;
        let (s, c) = (yaw * 0.5).sin_cos();
        out.push(PackCollider {
            translation: center,
            rotation: [0.0, s, 0.0, c],
            shape: PackShape::Box { half },
        });
    }
    Ok(out)
}

fn same(a: &PackCollider, b: &PackCollider) -> bool {
    let close = |x: &[f32], y: &[f32]| x.iter().zip(y).all(|(p, q)| (p - q).abs() < 1e-4);
    let shapes = match (&a.shape, &b.shape) {
        (PackShape::Box { half: h1 }, PackShape::Box { half: h2 }) => close(h1, h2),
        _ => false,
    };
    shapes && close(&a.translation, &b.translation) && close(&a.rotation, &b.rotation)
}

/// Adds `map`'s patch boxes to `pack`; how many were new.
pub fn apply(pack: &mut MapPack, patches_dir: &Path, map: &str) -> Result<usize, String> {
    let mut added = 0;
    for b in boxes(patches_dir, map)? {
        if !pack.colliders.iter().any(|c| same(c, &b)) {
            pack.colliders.push(b);
            added += 1;
        }
    }
    Ok(added)
}
