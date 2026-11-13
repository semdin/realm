//! realm_worldc build <export_dir> <maps_dir> <content_dir>
//! realm_worldc check <maps_dir> <content_dir>
//!
//! `build` turns the Godot-side export (`tools/world_export`) into one map
//! pack per map: static colliders on the world layers, terrain grids snapped
//! to the 1/256 m grid, water, moving geometry kept apart. Then it runs
//! `check`.
//!
//! `check` loads every pack into a collision world and plays bodies from each
//! of the map's spawn points: they must come to rest on walkable ground within
//! two seconds, and walking four ways for three seconds must keep them inside
//! the map's height band.

mod nav;

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Instant;

use realm_data::Content;
use realm_data::maps::{read_pack, write_pack};
use realm_data::rename::{RenameMap, RenameReport, Renamer};
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
        _ => {
            eprintln!(
                "usage:\n  realm_worldc build <export_dir> <maps_dir> <content_dir>\n  realm_worldc check <maps_dir> <content_dir>"
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

/// The rename map next to the content folder (`content/rename_map.toml`):
/// the export still uses the old game's names.
fn renamer(content_dir: &Path) -> Result<Renamer, String> {
    let path = content_dir
        .parent()
        .unwrap_or(Path::new("."))
        .join("rename_map.toml");
    let text = std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    RenameMap::parse(&text)?.compile()
}

fn build(export: &Path, maps_dir: &Path, content_dir: &Path) -> Result<(), String> {
    let infos = map_infos(content_dir)?;
    let renamer = renamer(content_dir)?;
    let mut report = RenameReport::default();
    // Export file stem (old id) by the realm map id it renames to.
    let mut stems: BTreeMap<String, String> = BTreeMap::new();
    for entry in std::fs::read_dir(export).map_err(|e| format!("{}: {e}", export.display()))? {
        let path = entry.map_err(|e| e.to_string())?.path();
        if path.extension().and_then(|e| e.to_str()) == Some("json")
            && let Some(stem) = path.file_stem().and_then(|s| s.to_str())
        {
            stems.insert(renamer.rename_str(stem, &mut report), stem.to_owned());
        }
    }
    std::fs::create_dir_all(maps_dir).map_err(|e| e.to_string())?;
    for (map, info) in &infos {
        let stem = stems
            .get(map)
            .ok_or_else(|| format!("{map}: no export for this map in {}", export.display()))?;
        let json_path = export.join(format!("{stem}.json"));
        let text = std::fs::read_to_string(&json_path)
            .map_err(|e| format!("{}: {e}", json_path.display()))?;
        let doc: Value =
            serde_json::from_str(&text).map_err(|e| format!("{}: {e}", json_path.display()))?;
        let bin = std::fs::read(export.join(format!("{stem}.bin")))
            .map_err(|e| format!("{stem}.bin: {e}"))?;

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
            if item["kind"].as_str() == Some("dynamic") {
                dynamic.push(DynamicCollider {
                    source: renamer.rename_str(path, &mut report),
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
fn check_nav(map: &str, pack: &MapPack, problems: &mut Vec<String>) {
    let query = NavQuery::new(&pack.nav);
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
        check_nav(map, &pack, &mut problems);
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
