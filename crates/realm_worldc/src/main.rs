//! realm_worldc build <export_dir> <maps_dir> <content_dir>
//! realm_worldc check <maps_dir> <content_dir>
//! realm_worldc patch <maps_dir> <content_dir> [map ...]
//! realm_worldc dump <maps_dir> <map> <out.json>
//!
//! `dump` writes a pack's static colliders and obstacles as world-space
//! triangles (JSON: `colliders` [{index, source "export" | "patch" |
//! "obstacle", note (a patch box's), shape, min, max, vertices, indices}],
//! `terrain` [{min_x, min_z, spacing_x, spacing_z, rows, cols, offset}]: the
//! grids' heights in metres as float32 in `<out>.terrain.bin` from `offset`
//! (bytes), NaN for a hole) for the client's placement check
//! (game/maps/dng_common/placement_check.gd), which lays them against the
//! drawn map.
//!
//! `patch` adds `<maps_dir>/../patches/<map>.json` collider boxes to built
//! packs (patch.rs; `build` adds them too) and bakes their navmesh again.
//!
//! `build` turns the Godot-side export (`tools/world_export`) into one map
//! pack per map: static colliders on the world layers, terrain grids snapped
//! to the 1/256 m grid, water, moving geometry kept apart. Then it runs
//! `check`.
//!
//! `check` loads every pack into a collision world and plays bodies from each
//! of the map's spawn points: they must come to rest on walkable ground within
//! two seconds, and walking four ways for three seconds must keep them inside
//! the map's height band. It samples every creature pack's area the way the
//! server places creatures: each must find walkable ground there, never a
//! roof or a prop (`check_creature_ground`).

mod nav;
mod patch;

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Instant;

use realm_data::Content;
use realm_data::maps::{read_pack, write_pack};
use realm_sim::input::MoveInput;
use realm_sim::movement::{self, Body, MoveParams};
use realm_sim::nav::NavQuery;
use realm_sim::pack::v3;
use realm_sim::pack::{
    DynamicCollider, HOLE, MapPack, NavMesh, PACK_VERSION, PackCollider, PackShape, PackWater,
    StairAnchor, TerrainGrid,
};
use realm_sim::world::basis_rotation;
use realm_sim::{Vec3, WIRE_GRID};
use serde_json::Value;

/// Layers that are world geometry: the player's mask (39) without layer 2,
/// which holds players, creatures and other entity bodies.
const WORLD_LAYERS: u64 = 1 | 4 | 32;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.as_slice() {
        [cmd, export, maps, content] if cmd == "build" => {
            build(Path::new(export), Path::new(maps), Path::new(content))
                .and_then(|()| check(Path::new(maps), Path::new(content)))
        }
        [cmd, maps, content] if cmd == "check" => check(Path::new(maps), Path::new(content)),
        [cmd, maps, content, only @ ..] if cmd == "patch" => {
            patch_packs(Path::new(maps), Path::new(content), only)
                .and_then(|()| check(Path::new(maps), Path::new(content)))
        }
        [cmd, maps, map, out] if cmd == "dump" => dump(Path::new(maps), map, Path::new(out)),
        [cmd, maps, map, x, z] if cmd == "probe" => probe(Path::new(maps), map, x, z),
        _ => {
            eprintln!(
                "usage:\n  realm_worldc build <export_dir> <maps_dir> <content_dir>\n  realm_worldc check <maps_dir> <content_dir>\n  realm_worldc patch <maps_dir> <content_dir> [map ...]"
            );
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("realm_worldc: {e}");
            ExitCode::FAILURE
        }
    }
}

fn map_infos(content_dir: &Path) -> Result<BTreeMap<String, Value>, String> {
    let content = Content::load(content_dir)?;
    let maps = content
        .file("maps.json")
        .ok_or("content: maps.json missing")?;
    Ok(maps["maps"]
        .as_object()
        .ok_or("maps.json: no maps")?
        .iter()
        .filter(|(k, _)| !k.starts_with('_'))
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect())
}

fn f(v: &Value) -> Result<f32, String> {
    v.as_f64()
        .map(|x| x as f32)
        .ok_or_else(|| format!("expected a number, got {v}"))
}

fn floats<'a>(bin: &'a [u8], blob: &Value) -> Result<impl Iterator<Item = f32> + 'a, String> {
    let offset = blob["offset"].as_u64().ok_or("blob offset")? as usize;
    let count = blob["floats"].as_u64().ok_or("blob count")? as usize;
    let end = offset + count * 4;
    if end > bin.len() {
        return Err(format!("blob {offset}+{count} runs past the data file"));
    }
    Ok(bin[offset..end]
        .as_chunks::<4>()
        .0
        .iter()
        .map(|c| f32::from_le_bytes(*c)))
}

fn points(bin: &[u8], blob: &Value) -> Result<Vec<[f32; 3]>, String> {
    let all: Vec<f32> = floats(bin, blob)?.collect();
    Ok(all.as_chunks::<3>().0.to_vec())
}

fn quantize(h: f32) -> i32 {
    if h.is_nan() {
        HOLE
    } else {
        (h * WIRE_GRID).round() as i32
    }
}

/// An authoring transform: basis columns and origin. Colliders must not be
/// scaled (scale is baked into shapes in the editor); a scaled one is an
/// authoring error to fix there, not something to guess at here.
fn pose(xform: &Value, what: &str) -> Result<([f32; 3], [f32; 4]), String> {
    let x: Vec<f32> = xform
        .as_array()
        .ok_or("xform")?
        .iter()
        .map(f)
        .collect::<Result<_, _>>()?;
    if x.len() != 12 {
        return Err(format!("{what}: transform has {} numbers", x.len()));
    }
    let cols = [
        Vec3::new(x[0], x[1], x[2]),
        Vec3::new(x[3], x[4], x[5]),
        Vec3::new(x[6], x[7], x[8]),
    ];
    for c in &cols {
        if (c.length() - 1.0).abs() > 1e-3 {
            return Err(format!(
                "{what}: scaled collider (axis length {:.4}); apply the scale to the shape",
                c.length()
            ));
        }
    }
    Ok((
        [x[9], x[10], x[11]],
        basis_rotation(cols[0], cols[1], cols[2]),
    ))
}

fn shape(item: &Value, bin: &[u8], what: &str) -> Result<PackShape, String> {
    let s = &item["shape"];
    Ok(match s["type"].as_str().unwrap_or_default() {
        "box" => PackShape::Box {
            half: [
                f(&s["size"][0])? * 0.5,
                f(&s["size"][1])? * 0.5,
                f(&s["size"][2])? * 0.5,
            ],
        },
        "sphere" => PackShape::Sphere {
            radius: f(&s["radius"])?,
        },
        "capsule" => {
            let (radius, height) = (f(&s["radius"])?, f(&s["height"])?);
            PackShape::Capsule {
                half_height: (height * 0.5 - radius).max(0.0),
                radius,
            }
        }
        "cylinder" => PackShape::Cylinder {
            half_height: f(&s["height"])? * 0.5,
            radius: f(&s["radius"])?,
        },
        "convex" => PackShape::Convex {
            points: points(bin, &s["points"])?,
        },
        "trimesh" => {
            let corners = points(bin, &s["faces"])?;
            let mut index: HashMap<[u32; 3], u32> = HashMap::new();
            let mut vertices = Vec::new();
            let mut flat = Vec::with_capacity(corners.len());
            for p in corners {
                let key = [p[0].to_bits(), p[1].to_bits(), p[2].to_bits()];
                let i = *index.entry(key).or_insert_with(|| {
                    vertices.push(p);
                    (vertices.len() - 1) as u32
                });
                flat.push(i);
            }
            let indices = flat
                .as_chunks::<3>()
                .0
                .iter()
                .copied()
                .filter(|t| t[0] != t[1] && t[1] != t[2] && t[0] != t[2])
                .collect();
            PackShape::TriMesh { vertices, indices }
        }
        other => return Err(format!("{what}: unsupported shape '{other}'")),
    })
}

/// Adds the patch boxes to the built packs that have a patch, and bakes
/// their navmesh again.
/// `only`: the maps to patch (none: every map).
fn patch_packs(maps_dir: &Path, content_dir: &Path, only: &[String]) -> Result<(), String> {
    let infos = map_infos(content_dir)?;
    let patches = maps_dir.parent().unwrap_or(maps_dir).join("patches");
    if let Some(unknown) = only.iter().find(|m| !infos.contains_key(*m)) {
        return Err(format!("patch: no map {unknown}"));
    }
    for (map, info) in &infos {
        if !only.is_empty() && !only.contains(map) {
            continue;
        }
        let path = maps_dir.join(format!("{map}.realmmap"));
        let mut pack = read_pack(&path)?;
        let (added, changed) = patch::apply(&mut pack, &patches, map)?;
        if !changed {
            // Written again all the same: an older pack comes out in the
            // current layout.
            write_pack(&path, &pack)?;
            continue;
        }
        let y_max = info["y_max"].as_f64().unwrap_or(1000.0) as f32;
        let y_min = info["y_min"].as_f64().unwrap_or(-1000.0) as f32;
        pack.world().map_err(|e| format!("{map}: {e}"))?;
        let (navmesh, report) =
            nav::bake(&pack, y_min, y_max).map_err(|e| format!("{map} navmesh: {e}"))?;
        pack.nav = navmesh;
        write_pack(&path, &pack)?;
        println!(
            "{map:<24} {added} patch boxes -> {} colliders, {} obstacles; navmesh {} polygons",
            pack.colliders.len(),
            pack.obstacles.len(),
            report.polygons
        );
    }
    Ok(())
}

fn build(export: &Path, maps_dir: &Path, content_dir: &Path) -> Result<(), String> {
    let infos = map_infos(content_dir)?;
    std::fs::create_dir_all(maps_dir).map_err(|e| e.to_string())?;
    for (map, info) in &infos {
        // The export names its files after the map ids.
        let json_path = export.join(format!("{map}.json"));
        if !json_path.is_file() {
            return Err(format!(
                "{map}: no export for this map in {}",
                export.display()
            ));
        }
        let text = std::fs::read_to_string(&json_path)
            .map_err(|e| format!("{}: {e}", json_path.display()))?;
        let doc: Value =
            serde_json::from_str(&text).map_err(|e| format!("{}: {e}", json_path.display()))?;
        let bin = std::fs::read(export.join(format!("{map}.bin")))
            .map_err(|e| format!("{map}.bin: {e}"))?;

        let mut colliders = Vec::new();
        let mut dynamic = Vec::new();
        let mut entity_bodies = 0;
        for item in doc["colliders"].as_array().into_iter().flatten() {
            let path = item["path"].as_str().unwrap_or("?");
            let layer = item["layer"].as_u64().unwrap_or(0);
            if layer & WORLD_LAYERS == 0 {
                entity_bodies += 1;
                continue;
            }
            let (translation, rotation) = pose(&item["xform"], path)?;
            let collider = PackCollider {
                translation,
                rotation,
                shape: shape(item, &bin, path)?,
            };
            // A dungeon gate (a `Gate_<id>` portcullis) opens and closes with
            // the run: kept out of the static world, named `gate:<id>` for the
            // dungeon rules.
            let gate = path
                .rsplit('/')
                .next()
                .and_then(|name| name.strip_prefix("Gate_"));
            if let Some(id) = gate {
                dynamic.push(DynamicCollider {
                    source: format!("gate:{id}"),
                    collider,
                });
            } else if item["kind"].as_str() == Some("dynamic") {
                dynamic.push(DynamicCollider {
                    source: path.to_owned(),
                    collider,
                });
            } else {
                colliders.push(collider);
            }
        }

        let mut terrain = Vec::new();
        for grid in doc["terrain"].as_array().into_iter().flatten() {
            let rows = grid["rows"].as_u64().ok_or("terrain rows")? as u32;
            let cols = grid["cols"].as_u64().ok_or("terrain cols")? as u32;
            let raw: Vec<f32> = floats(&bin, &grid["heights"])?.collect();
            if raw.len() != (rows * cols) as usize {
                return Err(format!(
                    "{map}: terrain has {} heights for {rows}x{cols}",
                    raw.len()
                ));
            }
            terrain.push(if grid.get("spacing").is_some() {
                // Terrain3D: corner and spacing, absolute heights.
                let spacing = f(&grid["spacing"])?;
                TerrainGrid {
                    min_x: f(&grid["min_x"])?,
                    min_z: f(&grid["min_z"])?,
                    spacing_x: spacing,
                    spacing_z: spacing,
                    rows,
                    cols,
                    heights: raw.into_iter().map(quantize).collect(),
                }
            } else {
                // HeightMapShape3D: centred on its transform, heights relative.
                let (origin, _) = pose(&grid["xform"], "heightmap")?;
                TerrainGrid {
                    min_x: origin[0] - (cols - 1) as f32 * 0.5,
                    min_z: origin[2] - (rows - 1) as f32 * 0.5,
                    spacing_x: 1.0,
                    spacing_z: 1.0,
                    rows,
                    cols,
                    heights: raw.into_iter().map(|h| quantize(h + origin[1])).collect(),
                }
            });
        }

        let water = doc["water"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|w| {
                Ok(PackWater {
                    min_x: f(&w["min_x"])?,
                    max_x: f(&w["max_x"])?,
                    min_z: f(&w["min_z"])?,
                    max_z: f(&w["max_z"])?,
                    surface_y: f(&w["surface_y"])?,
                    min_depth: w["min_depth"].as_f64().map(|d| d as f32),
                })
            })
            .collect::<Result<Vec<_>, String>>()?;

        let flight = info["flight_allowed"].as_bool().unwrap_or(false);
        let y_max = info["y_max"].as_f64().unwrap_or(1000.0) as f32;
        let y_min = info["y_min"].as_f64().unwrap_or(-1000.0) as f32;
        let mut staircases = Vec::new();
        for anchor in doc["staircases"].as_array().into_iter().flatten() {
            let x: Vec<f32> = anchor["xform"]
                .as_array()
                .ok_or("staircase xform")?
                .iter()
                .map(f)
                .collect::<Result<_, _>>()?;
            // Yaw-only anchors: the basis x column is (cos, 0, -sin).
            if x.len() != 12 || x[4] < 0.999 {
                return Err(format!("{map}: staircase anchor is not upright"));
            }
            staircases.push(StairAnchor {
                spec_index: anchor["spec_index"]
                    .as_u64()
                    .ok_or("staircase spec_index")? as u32,
                id: anchor["id"].as_u64().ok_or("staircase id")? as u32,
                translation: [x[9], x[10], x[11]],
                yaw: (-x[2]).atan2(x[0]),
            });
        }
        let patches = maps_dir.parent().unwrap_or(maps_dir).join("patches");
        let mut obstacles = Vec::new();
        let mut patch_colliders = 0;
        patch::remove_inside(&mut colliders, &patch::removals(&patches, map)?);
        for (b, obstacle) in patch::boxes(&patches, map)? {
            if obstacle {
                obstacles.push(b);
            } else {
                colliders.push(b);
                patch_colliders += 1;
            }
        }
        let mut pack = MapPack {
            version: PACK_VERSION,
            map: map.clone(),
            // The old game's broom limits (player.gd): 120 m over the ground,
            // never above 175 on the grounds; indoors the map's top.
            flight_ceiling_y: if flight { 175.0 } else { y_max },
            flight_max_above_ground: if flight { 120.0 } else { 0.0 },
            terrain,
            water,
            colliders,
            obstacles,
            patch_colliders,
            dynamic,
            nav: NavMesh::default(),
            staircases,
        };
        pack.world().map_err(|e| format!("{map}: {e}"))?;
        let started = Instant::now();
        let (navmesh, report) =
            nav::bake(&pack, y_min, y_max).map_err(|e| format!("{map} navmesh: {e}"))?;
        pack.nav = navmesh;
        println!(
            "{map:<24} navmesh: {} tiles, {} polygons, {} portals ({} across tile borders) in {:.1} s",
            report.tiles,
            report.polygons,
            report.portals,
            report.border_links,
            started.elapsed().as_secs_f32()
        );
        let path = maps_dir.join(format!("{map}.realmmap"));
        let bytes = write_pack(&path, &pack)?;
        println!(
            "{map:<24} {:>5} colliders, {:>3} moving, {} terrain, {} water, {} entity bodies left out -> {:.2} MB",
            pack.colliders.len(),
            pack.dynamic.len(),
            pack.terrain.len(),
            pack.water.len(),
            entity_bodies,
            bytes as f64 / 1_048_576.0
        );
    }
    Ok(())
}

/// Navigation: how connected the mesh is, and whether paths between random
/// points of the main area exist and stay on the mesh all the way.
fn check_nav(
    map: &str,
    pack: &MapPack,
    world: &realm_sim::world::World,
    problems: &mut Vec<String>,
) {
    let query = NavQuery::for_world(&pack.nav, world);
    if query.polygon_count() == 0 {
        problems.push(format!("{map}: no navigation mesh"));
        return;
    }
    let sizes = query.component_sizes();
    let main = sizes[0];
    let centers: Vec<Vec3> = pack
        .nav
        .polygons
        .iter()
        .map(|ids| {
            ids.iter()
                .map(|&i| v3(pack.nav.vertices[i as usize]))
                .fold(Vec3::ZERO, |a, v| a + v)
                / ids.len() as f32
        })
        .collect();
    let mut rng = 0x2545_F491_u32;
    let mut next = || {
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        rng
    };
    let (mut tried, mut found, mut off_mesh, mut length) = (0, 0, 0, 0.0_f32);
    let mut scratch = realm_sim::nav::NavScratch::default();
    for _ in 0..200 {
        let a = centers[next() as usize % centers.len()];
        let b = centers[next() as usize % centers.len()];
        tried += 1;
        let Some(path) = query.path(a, b, 200_000, &mut scratch) else {
            continue;
        };
        found += 1;
        let mut prev = a;
        for corner in &path {
            let seg = *corner - prev;
            let steps = (seg.length() / 0.5).ceil().max(1.0) as usize;
            for s in 1..steps {
                let p = prev + seg * (s as f32 / steps as f32);
                if query.locate(p, 1.0e6).is_none() {
                    off_mesh += 1;
                    break;
                }
            }
            length += seg.length();
            prev = *corner;
        }
    }
    println!(
        "check {map:<24} navmesh {} polygons, {} groups (largest {main}, {:.0}%), {found}/{tried} random paths found (same group needed), {off_mesh} leave the mesh, mean {:.0} m",
        query.polygon_count(),
        sizes.len(),
        main as f32 * 100.0 / query.polygon_count() as f32,
        if found > 0 {
            length / found as f32
        } else {
            0.0
        }
    );
    if off_mesh > 0 {
        problems.push(format!(
            "{map}: {off_mesh} path segments leave the navigation mesh"
        ));
    }
}

/// Obstacles (trunks, spires) are not ground for what is placed from the
/// sky, so nothing placed at a fixed point may stand inside one: the map's
/// spawn points, its creature packs' area centres, its Dark Shard sites and
/// training dummies (spawn_tables.json) must lie outside every obstacle box
/// grown by a body's radius.
fn check_obstacle_points(
    map: &str,
    info: &Value,
    content: &Content,
    pack: &MapPack,
    world: &realm_sim::world::World,
    problems: &mut Vec<String>,
) {
    if pack.obstacles.is_empty() {
        return;
    }
    let num = |v: &Value| v.as_f64().map(|x| x as f32);
    let mut points: Vec<(String, f32, Option<f32>, f32)> = Vec::new();
    for (name, p) in info["spawn_points"].as_object().into_iter().flatten() {
        if let (Some(x), Some(y), Some(z)) = (num(&p[0]), num(&p[1]), num(&p[2])) {
            points.push((format!("spawn '{name}'"), x, Some(y), z));
        }
    }
    let spawns = content.file("spawn_tables.json");
    let spawns = spawns.unwrap_or(&Value::Null);
    for p in spawns["packs"].as_array().into_iter().flatten() {
        if p["map"].as_str() == Some(map)
            && let (Some(x), Some(z)) = (num(&p["area"][0]), num(&p["area"][1]))
        {
            points.push((format!("pack {} centre", p["id"]), x, None, z));
        }
    }
    for m in spawns["monoliths"].as_array().into_iter().flatten() {
        let on = if m["zone"].as_str().unwrap_or("").starts_with("caverns") {
            "spider_caverns"
        } else {
            "grounds"
        };
        if on == map
            && let (Some(x), Some(y), Some(z)) =
                (num(&m["pos"][0]), num(&m["pos"][1]), num(&m["pos"][2]))
        {
            points.push((format!("Dark Shard {}", m["id"]), x, Some(y), z));
        }
    }
    if map == "grounds" {
        for d in spawns["dummies"].as_array().into_iter().flatten() {
            if let (Some(x), Some(y), Some(z)) =
                (num(&d["pos"][0]), num(&d["pos"][1]), num(&d["pos"][2]))
            {
                points.push((format!("dummy {}", d["id"]), x, Some(y), z));
            }
        }
    }
    let reach = movement::CAPSULE_RADIUS;
    let mut inside = 0;
    for (what, x, y, z) in &points {
        // the ground the server puts it on (through obstacles)
        let y = world.ground_height(*x, *z).or(*y).unwrap_or(0.0);
        let at = glam::Vec3::new(*x, y, *z);
        for o in &pack.obstacles {
            let PackShape::Box { half } = o.shape else {
                continue;
            };
            let [qx, qy, qz, qw] = o.rotation;
            let local = glam::Quat::from_xyzw(qx, qy, qz, qw).inverse()
                * (at - glam::Vec3::from_array(o.translation));
            if local.x.abs() <= half[0] + reach
                && local.z.abs() <= half[2] + reach
                && local.y.abs() <= half[1] + reach
            {
                inside += 1;
                problems.push(format!(
                    "{map}: {what} at ({x:.1}, {y:.1}, {z:.1}) is inside an obstacle at {:?}",
                    o.translation
                ));
                break;
            }
        }
    }
    println!(
        "check {map:<24} {} obstacles, {} fixed points (spawns, pack centres, shards, dummies), {inside} inside one",
        pack.obstacles.len(),
        points.len()
    );
}

/// Samples taken in each open-world pack's area.
const GROUND_SAMPLES: usize = 32;

/// Creatures stand on the walkable ground: never on a roof, a wall top or a
/// prop, in a trunk or in the air. Every open-world pack's area
/// (spawn_tables.json) is sampled the way the server puts its members down
/// (`NavQuery::creature_spot`): each pack must find ground in its area on
/// the 1 m grid the server searches when its draws miss
/// (`NavQuery::ground_in_area`), and each spot taken must rest on the
/// surface under it, clear of obstacles. A
/// dungeon group (dungeons.json) settles on the floor under its authored
/// point, which must be ground as well. Spots the highest
/// surface offers but that stand on a structure off the walkable mesh (more
/// than 1.5 m over the terrain) are counted as refused roofs; spots taken
/// that high are on built floors the mesh walks (a bridge, a yard).
fn check_creature_ground(
    map: &str,
    content: &Content,
    pack: &MapPack,
    world: &realm_sim::world::World,
    problems: &mut Vec<String>,
) {
    let query = NavQuery::for_world(&pack.nav, world);
    let num = |v: &Value| v.as_f64().map_or(0.0, |x| x as f32);
    let mut rng = 0x6C8E_9CF5_u32;
    let mut unit = || {
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        rng as f32 / u32::MAX as f32
    };
    let (mut packs, mut taken, mut roofs, mut floors) = (0, 0, 0, 0);
    // Packs with ground in under a quarter of their area (they stand up
    // crowded into what there is).
    let mut scarce: Vec<String> = Vec::new();
    let fail = |what: String, problems: &mut Vec<String>| problems.push(format!("{map}: {what}"));
    let spawns = content.file("spawn_tables.json").unwrap_or(&Value::Null);
    for p in spawns["packs"].as_array().into_iter().flatten() {
        if p["map"].as_str() != Some(map) {
            continue;
        }
        packs += 1;
        let area = &p["area"];
        let (cx, cz) = (num(&area[0]), num(&area[1]));
        let (hx, hz) = (num(&area[2]).max(1.0), num(&area[3]).max(1.0));
        let mut found = 0;
        for _ in 0..GROUND_SAMPLES {
            let x = cx + (unit() * 2.0 - 1.0) * hx;
            let z = cz + (unit() * 2.0 - 1.0) * hz;
            let Some(spot) = query.creature_spot(world, x, z) else {
                let terrain = world.terrain_at(x, z).map(|t| t.0);
                if let (Some(top), Some(t)) = (world.ground_height(x, z), terrain)
                    && top - t > 1.5
                {
                    roofs += 1;
                }
                continue;
            };
            found += 1;
            if world
                .terrain_at(x, z)
                .is_some_and(|(t, _)| spot.y - t > 1.5)
            {
                floors += 1;
                // A built floor is ground only as part of the map's main
                // walkable network (a bridge, a rampart walk), never an
                // island of its own (a roof).
                let main = query
                    .locate_surface(spot, 1.0)
                    .is_some_and(|poly| query.group_area(poly) >= query.largest_group_area());
                if !main {
                    fail(
                        format!("pack {} would stand on a structure at {spot}", p["id"]),
                        problems,
                    );
                }
            }
            let rests = world
                .ray_down(spot + Vec3::new(0.0, 0.2, 0.0), 0.5)
                .is_some_and(|g| (g.point.y - spot.y).abs() < 0.05);
            if !rests || world.in_obstacle(spot, realm_sim::nav::OBSTACLE_CLEARANCE) {
                fail(
                    format!("pack {} would stand off the ground at {spot}", p["id"]),
                    problems,
                );
            }
        }
        taken += found;
        // The server's last resort at boot when its draws miss: the whole
        // area on a 1 m grid (`NavQuery::ground_in_area`). A pack it finds
        // nothing for is left out of the world.
        if query
            .ground_in_area(world, (cx, cz), (hx, hz), |_| true)
            .is_none()
        {
            fail(
                format!(
                    "pack {} ({}) finds no ground in its area around ({cx}, {cz}): the server leaves it out",
                    p["id"], p["mob"]
                ),
                problems,
            );
        } else if found < GROUND_SAMPLES / 4 {
            scarce.push(format!("{} {}/{GROUND_SAMPLES}", p["id"], found));
        }
    }
    let mut groups = 0;
    let dungeons = content.file("dungeons.json").unwrap_or(&Value::Null);
    for (key, d) in dungeons["dungeons"].as_object().into_iter().flatten() {
        if d["map"].as_str() != Some(map) {
            continue;
        }
        for step in d["steps"].as_array().into_iter().flatten() {
            for e in step["spawn"].as_array().into_iter().flatten() {
                groups += 1;
                // The pack holds one copy in the dungeon's own frame (the
                // server lays the copies side by side).
                let at = Vec3::new(num(&e["at"][0]), num(&e["at"][1]), num(&e["at"][2]));
                // The server's settle: the floor up to 1.5 m over the point
                // or 6.5 m under it.
                let floor = world
                    .ray_down(at + Vec3::new(0.0, 1.5, 0.0), 8.0)
                    .map(|g| g.point);
                if !floor.is_some_and(|f| query.on_ground(world, f)) {
                    fail(
                        format!(
                            "dungeon {key} step {} group of {} at {:?} is not on the ground ({floor:?})",
                            step["id"], e["mob"], e["at"]
                        ),
                        problems,
                    );
                }
            }
        }
    }
    if packs + groups > 0 {
        println!(
            "check {map:<24} creature ground: {packs} packs, {taken}/{} samples on the ground ({floors} on built floors over the terrain), {roofs} roof spots refused; {groups} dungeon groups",
            packs * GROUND_SAMPLES
        );
    }
    if !scarce.is_empty() {
        println!(
            "check {map:<24} packs with ground in under a quarter of their area: {}",
            scarce.join(", ")
        );
    }
}

fn check(maps_dir: &Path, content_dir: &Path) -> Result<(), String> {
    let infos = map_infos(content_dir)?;
    let content = Content::load(content_dir)?;
    let mut problems = Vec::new();
    let params = MoveParams::default();
    for (map, info) in &infos {
        let path: PathBuf = maps_dir.join(format!("{map}.realmmap"));
        let pack = read_pack(&path)?;
        let mut world = pack.world().map_err(|e| format!("{map}: {e}"))?;
        // Moving staircases run as in the game: placed every tick, carrying
        // bodies on their decks.
        let mut stairs = realm_data::staircases(&content, &pack)?;
        let mut tick = 0_u32;
        let mut step = |body: &mut Body, input: MoveInput, world: &mut realm_sim::world::World| {
            tick += 1;
            stairs.apply(world, tick);
            stairs.carry(body, tick);
            movement::step(body, input, &params, world);
        };
        let y_min = info["y_min"].as_f64().unwrap_or(-1e6) as f32;
        let y_max = info["y_max"].as_f64().unwrap_or(1e6) as f32;
        let spawns: Vec<(String, Vec3)> = info["spawn_points"]
            .as_object()
            .into_iter()
            .flatten()
            .filter_map(|(name, p)| {
                Some((
                    name.clone(),
                    Vec3::new(f(&p[0]).ok()?, f(&p[1]).ok()?, f(&p[2]).ok()?),
                ))
            })
            .collect();
        let mut rested = 0;
        for (name, spawn) in &spawns {
            let mut body = Body::at(*spawn + Vec3::new(0.0, 0.5, 0.0));
            for _ in 0..60 {
                step(&mut body, MoveInput::default(), &mut world);
            }
            if !body.on_floor {
                problems.push(format!(
                    "{map}: spawn '{name}' at {spawn} did not come to rest (now {})",
                    body.pos
                ));
                continue;
            }
            rested += 1;
            for quarter in 0..4_u16 {
                let mut walker = body;
                let input = MoveInput {
                    strafe: 0,
                    forward: 127,
                    yaw: quarter * 16_384,
                    buttons: 0,
                };
                for _ in 0..90 {
                    step(&mut walker, input, &mut world);
                }
                if walker.pos.y < y_min || walker.pos.y > y_max {
                    problems.push(format!(
                        "{map}: walking from spawn '{name}' (yaw {}) left the map's height band: {}",
                        quarter * 90,
                        walker.pos
                    ));
                }
            }
        }
        println!(
            "check {map:<24} {:>5} colliders, {} staircases, {} spawn points, {rested} came to rest and walked four ways",
            world.collider_count(),
            pack.staircases.len(),
            spawns.len()
        );
        check_nav(map, &pack, &world, &mut problems);
        check_obstacle_points(map, info, &content, &pack, &world, &mut problems);
        check_creature_ground(map, &content, &pack, &world, &mut problems);
    }
    if problems.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "{} problem(s):\n  {}",
            problems.len(),
            problems.join("\n  ")
        ))
    }
}

/// `dump`: the pack's static colliders and obstacles as world-space
/// triangles, each with where it came from (the export, the patch file with
/// its note, an obstacle box), for the client's placement check.
fn dump(maps_dir: &Path, map: &str, out: &Path) -> Result<(), String> {
    let pack = read_pack(&maps_dir.join(format!("{map}.realmmap")))?;
    let patches = maps_dir.parent().unwrap_or(maps_dir).join("patches");
    let notes: Vec<(String, bool)> = std::fs::read_to_string(patches.join(format!("{map}.json")))
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .map(|doc| {
            doc["boxes"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|b| {
                    (
                        b["note"].as_str().unwrap_or("").to_owned(),
                        b["obstacle"].as_bool().unwrap_or(false),
                    )
                })
                .collect()
        })
        .unwrap_or_default();
    let (patch_notes, obstacle_notes): (Vec<_>, Vec<_>) = notes.into_iter().partition(|(_, o)| !o);
    let first_patch = pack.colliders.len() - pack.patch_colliders as usize;
    let mut list = Vec::new();
    for (i, (c, m)) in pack
        .colliders
        .iter()
        .chain(&pack.obstacles)
        .zip(pack.collider_meshes())
        .enumerate()
    {
        let (source, note) = if i >= pack.colliders.len() {
            let k = i - pack.colliders.len();
            (
                "obstacle",
                obstacle_notes.get(k).map_or("", |n| n.0.as_str()),
            )
        } else if i >= first_patch {
            (
                "patch",
                patch_notes
                    .get(i - first_patch)
                    .map_or("", |n| n.0.as_str()),
            )
        } else {
            ("export", "")
        };
        let shape = match c.shape {
            PackShape::Box { .. } => "box",
            PackShape::Sphere { .. } => "sphere",
            PackShape::Capsule { .. } => "capsule",
            PackShape::Cylinder { .. } => "cylinder",
            PackShape::Convex { .. } => "convex",
            PackShape::TriMesh { .. } => "trimesh",
        };
        list.push(serde_json::json!({
            "index": i,
            "source": source,
            "note": note,
            "shape": shape,
            "min": m.min,
            "max": m.max,
            "vertices": m.vertices.iter().flatten().collect::<Vec<_>>(),
            "indices": m.indices.iter().flatten().collect::<Vec<_>>(),
        }));
    }
    let mut grids = Vec::new();
    let mut bin: Vec<u8> = Vec::new();
    for g in &pack.terrain {
        grids.push(serde_json::json!({
            "min_x": g.min_x, "min_z": g.min_z, "spacing_x": g.spacing_x, "spacing_z": g.spacing_z,
            "rows": g.rows, "cols": g.cols, "offset": bin.len(),
        }));
        for &h in &g.heights {
            let m = if h == HOLE {
                f32::NAN
            } else {
                h as f32 / WIRE_GRID
            };
            bin.extend_from_slice(&m.to_le_bytes());
        }
    }
    let terrain_path = PathBuf::from(format!("{}.terrain.bin", out.display()));
    std::fs::write(&terrain_path, &bin).map_err(|e| format!("{}: {e}", terrain_path.display()))?;
    let doc = serde_json::json!({ "map": map, "colliders": list, "terrain": grids });
    std::fs::write(out, doc.to_string()).map_err(|e| format!("{}: {e}", out.display()))?;
    println!(
        "dump {map}: {} colliders ({} from the patch file), {} obstacles -> {}",
        pack.colliders.len(),
        pack.patch_colliders,
        pack.obstacles.len(),
        out.display()
    );
    Ok(())
}

/// `probe`: what the pack has under (x, z): the terrain, the highest surface
/// (through obstacles and not), and what a client's vertical `pick` from the
/// sky returns there (World::line_hit, the line test RealmSession.pick runs).
fn probe(maps_dir: &Path, map: &str, x: &str, z: &str) -> Result<(), String> {
    let x: f32 = x.parse().map_err(|_| "x")?;
    let z: f32 = z.parse().map_err(|_| "z")?;
    let pack = read_pack(&maps_dir.join(format!("{map}.realmmap")))?;
    let world = pack.world().map_err(|e| format!("{map}: {e}"))?;
    println!("terrain {:?}", world.terrain_at(x, z).map(|t| t.0));
    let top = Vec3::new(x, 1500.0, z);
    println!(
        "ray_down {:?}",
        world.ray_down(top, 3000.0).map(|h| h.point.y)
    );
    println!(
        "ray_down_ground {:?}",
        world.ray_down_ground(top, 3000.0).map(|h| h.point.y)
    );
    let mut from = top;
    for attempt in 0..8 {
        let reach = from.y + 200.0;
        let end = from + Vec3::new(0.0, -reach, 0.0);
        let t = world.line_hit(from, end).unwrap_or(1.0) * reach;
        let point = from - Vec3::new(0.0, t, 0.0);
        println!("pick {attempt} from {:.3} -> {:.3}", from.y, point.y);
        from = point - Vec3::new(0.0, 0.3, 0.0);
    }
    Ok(())
}
