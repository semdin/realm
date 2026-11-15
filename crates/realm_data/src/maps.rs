//! Map pack files (`world/maps/<map>.realmmap`): a 4-byte magic, the pack
//! version, then zstd-compressed postcard of `realm_sim::pack::MapPack`.

use std::path::Path;

use realm_sim::pack::{MAGIC, MapPack, PACK_VERSION};

/// zstd level for packs: slow to write once, fast to read everywhere.
const LEVEL: i32 = 19;

pub fn write_pack(path: &Path, pack: &MapPack) -> Result<usize, String> {
    let mut stored = pack.clone();
    for grid in &mut stored.terrain {
        grid.heights = predict(&grid.heights, grid.cols as usize);
    }
    let raw = postcard::to_stdvec(&stored).map_err(|e| format!("encode {}: {e}", pack.map))?;
    let compressed =
        zstd::bulk::compress(&raw, LEVEL).map_err(|e| format!("compress {}: {e}", pack.map))?;
    let mut out = Vec::with_capacity(compressed.len() + 8);
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&PACK_VERSION.to_le_bytes());
    out.extend_from_slice(&compressed);
    std::fs::write(path, &out).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(out.len())
}

pub fn read_pack(path: &Path) -> Result<MapPack, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
    if bytes.len() < 8 || &bytes[..4] != MAGIC {
        return Err(format!("{}: not a map pack", path.display()));
    }
    let version = u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
    if version == 2 {
        return read_v2(path, &bytes);
    }
    if version == 3 {
        return read_v3(path, &bytes);
    }
    if version != PACK_VERSION {
        return Err(format!(
            "{}: pack version {version}, this build reads {PACK_VERSION}",
            path.display()
        ));
    }
    // Packs are tens of MB uncompressed at most; cap the output to refuse a
    // corrupt or hostile file instead of allocating without bound.
    let raw = zstd::bulk::decompress(&bytes[8..], 512 << 20)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    let mut pack: MapPack =
        postcard::from_bytes(&raw).map_err(|e| format!("{}: {e}", path.display()))?;
    for grid in &mut pack.terrain {
        let cols = grid.cols as usize;
        if cols == 0 || grid.heights.len() % cols != 0 {
            return Err(format!("{}: terrain grid size", path.display()));
        }
        grid.heights = unpredict(&grid.heights, cols);
    }
    Ok(pack)
}

/// A version 2 pack (before obstacles): read and brought to the current
/// layout with no obstacles.
fn read_v2(path: &Path, bytes: &[u8]) -> Result<MapPack, String> {
    #[derive(serde::Deserialize)]
    struct V2 {
        version: u32,
        map: String,
        flight_ceiling_y: f32,
        flight_max_above_ground: f32,
        terrain: Vec<realm_sim::pack::TerrainGrid>,
        water: Vec<realm_sim::pack::PackWater>,
        colliders: Vec<realm_sim::pack::PackCollider>,
        dynamic: Vec<realm_sim::pack::DynamicCollider>,
        nav: realm_sim::pack::NavMesh,
        staircases: Vec<realm_sim::pack::StairAnchor>,
    }
    let raw = zstd::bulk::decompress(&bytes[8..], 512 << 20)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    let old: V2 = postcard::from_bytes(&raw).map_err(|e| format!("{}: {e}", path.display()))?;
    let _ = old.version;
    let mut pack = MapPack {
        version: PACK_VERSION,
        map: old.map,
        flight_ceiling_y: old.flight_ceiling_y,
        flight_max_above_ground: old.flight_max_above_ground,
        terrain: old.terrain,
        water: old.water,
        colliders: old.colliders,
        obstacles: Vec::new(),
        patch_colliders: 0,
        dynamic: old.dynamic,
        nav: old.nav,
        staircases: old.staircases,
    };
    for grid in &mut pack.terrain {
        let cols = grid.cols as usize;
        if cols == 0 || grid.heights.len() % cols != 0 {
            return Err(format!("{}: terrain grid size", path.display()));
        }
        grid.heights = unpredict(&grid.heights, cols);
    }
    Ok(pack)
}

/// A version 3 pack (obstacles, no patch count): its patch boxes are not
/// told apart from the export's, so it reads with none counted.
fn read_v3(path: &Path, bytes: &[u8]) -> Result<MapPack, String> {
    #[derive(serde::Deserialize)]
    struct V3 {
        version: u32,
        map: String,
        flight_ceiling_y: f32,
        flight_max_above_ground: f32,
        terrain: Vec<realm_sim::pack::TerrainGrid>,
        water: Vec<realm_sim::pack::PackWater>,
        colliders: Vec<realm_sim::pack::PackCollider>,
        obstacles: Vec<realm_sim::pack::PackCollider>,
        dynamic: Vec<realm_sim::pack::DynamicCollider>,
        nav: realm_sim::pack::NavMesh,
        staircases: Vec<realm_sim::pack::StairAnchor>,
    }
    let raw = zstd::bulk::decompress(&bytes[8..], 512 << 20)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    let old: V3 = postcard::from_bytes(&raw).map_err(|e| format!("{}: {e}", path.display()))?;
    let _ = old.version;
    let mut pack = MapPack {
        version: PACK_VERSION,
        map: old.map,
        flight_ceiling_y: old.flight_ceiling_y,
        flight_max_above_ground: old.flight_max_above_ground,
        terrain: old.terrain,
        water: old.water,
        colliders: old.colliders,
        obstacles: old.obstacles,
        patch_colliders: 0,
        dynamic: old.dynamic,
        nav: old.nav,
        staircases: old.staircases,
    };
    for grid in &mut pack.terrain {
        let cols = grid.cols as usize;
        if cols == 0 || grid.heights.len() % cols != 0 {
            return Err(format!("{}: terrain grid size", path.display()));
        }
        grid.heights = unpredict(&grid.heights, cols);
    }
    Ok(pack)
}

/// Terrain heights are stored as the residual of a plane predictor (left +
/// up - up-left); on smooth ground most residuals are a few units, which
/// zstd packs several times smaller than the heights. Wrapping arithmetic
/// keeps holes and every value exactly reversible.
fn predict(heights: &[i32], cols: usize) -> Vec<i32> {
    let at = |i: usize, r: usize, c: usize| -> i32 {
        match (r, c) {
            (0, 0) => 0,
            (0, _) => heights[i - 1],
            (_, 0) => heights[i - cols],
            _ => heights[i - 1]
                .wrapping_add(heights[i - cols])
                .wrapping_sub(heights[i - cols - 1]),
        }
    };
    (0..heights.len())
        .map(|i| heights[i].wrapping_sub(at(i, i / cols, i % cols)))
        .collect()
}

fn unpredict(residuals: &[i32], cols: usize) -> Vec<i32> {
    let mut out: Vec<i32> = Vec::with_capacity(residuals.len());
    for (i, r) in residuals.iter().enumerate() {
        let (row, col) = (i / cols, i % cols);
        let guess = match (row, col) {
            (0, 0) => 0,
            (0, _) => out[i - 1],
            (_, 0) => out[i - cols],
            _ => out[i - 1]
                .wrapping_add(out[i - cols])
                .wrapping_sub(out[i - cols - 1]),
        };
        out.push(r.wrapping_add(guess));
    }
    out
}
