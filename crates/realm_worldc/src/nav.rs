//! Navigation mesh bake: the map's walkable surface as convex polygons,
//! built with rerecast (a Rust port of Recast) tile by tile, then stitched:
//! vertices welded, polygons sharing an edge joined, polygons meeting on a
//! tile border joined through the overlap of their border edges.

use std::collections::{BTreeMap, HashMap};

use glam::{UVec3, Vec3A};
use parry3d::shape::{Ball, Capsule, ConvexPolyhedron, Cuboid, Cylinder};
use realm_sim::Vec3;
use realm_sim::pack::{HOLE, MapPack, NavMesh, NavPortal, PackShape, v3};
use rerecast::{Aabb3d, AreaType, ConfigBuilder, HeightfieldBuilder, TriMesh};

/// Creatures and players share the player's capsule for paths.
const AGENT_RADIUS: f32 = 0.35;
const AGENT_HEIGHT: f32 = 1.85;
const AGENT_CLIMB: f32 = 0.45;
const AGENT_SLOPE_DEG: f32 = 48.0;
/// Voxels per tile side (0.35 m voxels: about 90 m tiles).
const TILE_CELLS: u16 = 256;

struct Triangles {
    vertices: Vec<[f32; 3]>,
    indices: Vec<[u32; 3]>,
    min: [f32; 3],
    max: [f32; 3],
}

fn bounds(vertices: &[[f32; 3]]) -> ([f32; 3], [f32; 3]) {
    let mut min = [f32::MAX; 3];
    let mut max = [f32::MIN; 3];
    for v in vertices {
        for k in 0..3 {
            min[k] = min[k].min(v[k]);
            max[k] = max[k].max(v[k]);
        }
    }
    (min, max)
}

/// Every collider as world-space triangles.
fn collider_triangles(pack: &MapPack) -> Vec<Triangles> {
    let mut out = Vec::new();
    for c in &pack.colliders {
        let (local, indices): (Vec<Vec3>, Vec<[u32; 3]>) = match &c.shape {
            PackShape::Box { half } => Cuboid::new(v3(*half)).to_trimesh(),
            PackShape::Sphere { radius } => Ball::new(*radius).to_trimesh(8, 8),
            PackShape::Capsule {
                half_height,
                radius,
            } => Capsule::new_y(*half_height, *radius).to_trimesh(8, 4),
            PackShape::Cylinder {
                half_height,
                radius,
            } => Cylinder::new(*half_height, *radius).to_trimesh(12),
            PackShape::Convex { points } => {
                let pts: Vec<Vec3> = points.iter().copied().map(v3).collect();
                match ConvexPolyhedron::from_convex_hull(&pts) {
                    Some(hull) => hull.to_trimesh(),
                    None => continue,
                }
            }
            PackShape::TriMesh { vertices, indices } => {
                (vertices.iter().copied().map(v3).collect(), indices.clone())
            }
        };
        let [x, y, z, w] = c.rotation;
        let rotation = realm_sim::world::rotation_from_xyzw(x, y, z, w);
        let t = v3(c.translation);
        let vertices: Vec<[f32; 3]> = local
            .iter()
            .map(|p| {
                let q = rotation * *p + t;
                [q.x, q.y, q.z]
            })
            .collect();
        let (min, max) = bounds(&vertices);
        out.push(Triangles {
            vertices,
            indices,
            min,
            max,
        });
    }
    out
}

/// Terrain cells overlapping `[min_x, max_x] x [min_z, max_z]` as triangles
/// (same diagonal as the movement rules), holes left out.
fn terrain_triangles(
    pack: &MapPack,
    min_x: f32,
    max_x: f32,
    min_z: f32,
    max_z: f32,
    out: &mut TriMesh,
) {
    for grid in &pack.terrain {
        let (rows, cols) = (grid.rows as i64, grid.cols as i64);
        let c0 = (((min_x - grid.min_x) / grid.spacing_x).floor() as i64).clamp(0, cols - 1);
        let c1 = (((max_x - grid.min_x) / grid.spacing_x).ceil() as i64).clamp(0, cols - 1);
        let r0 = (((min_z - grid.min_z) / grid.spacing_z).floor() as i64).clamp(0, rows - 1);
        let r1 = (((max_z - grid.min_z) / grid.spacing_z).ceil() as i64).clamp(0, rows - 1);
        let h = |r: i64, c: i64| grid.heights[(r * cols + c) as usize];
        let p = |r: i64, c: i64| {
            Vec3A::new(
                grid.min_x + c as f32 * grid.spacing_x,
                h(r, c) as f32 / realm_sim::WIRE_GRID,
                grid.min_z + r as f32 * grid.spacing_z,
            )
        };
        for r in r0..r1 {
            for c in c0..c1 {
                let (a, b, cc, d) = ((r, c), (r, c + 1), (r + 1, c + 1), (r + 1, c));
                for tri in [[a, cc, b], [a, d, cc]] {
                    if tri.iter().any(|&(rr, cc2)| h(rr, cc2) == HOLE) {
                        continue;
                    }
                    let base = out.vertices.len() as u32;
                    for &(rr, cc2) in &tri {
                        out.vertices.push(p(rr, cc2));
                    }
                    out.indices.push(UVec3::new(base, base + 1, base + 2));
                    out.area_types.push(AreaType::NOT_WALKABLE);
                }
            }
        }
    }
}

/// One baked polygon in world space, with the tile it came from.
struct RawPoly {
    tile: (i32, i32),
    vertices: Vec<[f32; 3]>,
}

pub struct BakeReport {
    pub tiles: usize,
    pub polygons: usize,
    pub portals: usize,
    pub border_links: usize,
}

pub fn bake(pack: &MapPack, y_min: f32, y_max: f32) -> Result<(NavMesh, BakeReport), String> {
    let colliders = collider_triangles(pack);
    // Planar extent: terrain grids and colliders.
    let (mut min_x, mut min_z, mut max_x, mut max_z) = (f32::MAX, f32::MAX, f32::MIN, f32::MIN);
    for g in &pack.terrain {
        min_x = min_x.min(g.min_x);
        min_z = min_z.min(g.min_z);
        max_x = max_x.max(g.min_x + (g.cols - 1) as f32 * g.spacing_x);
        max_z = max_z.max(g.min_z + (g.rows - 1) as f32 * g.spacing_z);
    }
    for t in &colliders {
        min_x = min_x.min(t.min[0]);
        min_z = min_z.min(t.min[2]);
        max_x = max_x.max(t.max[0]);
        max_z = max_z.max(t.max[2]);
    }
    if min_x > max_x {
        return Ok((
            NavMesh::default(),
            BakeReport {
                tiles: 0,
                polygons: 0,
                portals: 0,
                border_links: 0,
            },
        ));
    }

    let probe = ConfigBuilder {
        agent_radius: AGENT_RADIUS,
        agent_height: AGENT_HEIGHT,
        walkable_climb: AGENT_CLIMB,
        walkable_slope_angle: AGENT_SLOPE_DEG.to_radians(),
        cell_size_fraction: 1.0,
        cell_height_fraction: 4.0,
        tile_size: TILE_CELLS,
        tiling: true,
        ..ConfigBuilder::default()
    };
    let cs = probe.clone().build().cell_size;
    let tile_world = f32::from(TILE_CELLS) * cs;
    let tiles_x = ((max_x - min_x) / tile_world).ceil().max(1.0) as i32;
    let tiles_z = ((max_z - min_z) / tile_world).ceil().max(1.0) as i32;

    let mut raw: Vec<RawPoly> = Vec::new();
    let mut baked_tiles = 0;
    for tz in 0..tiles_z {
        for tx in 0..tiles_x {
            let tile_min_x = min_x + tx as f32 * tile_world;
            let tile_min_z = min_z + tz as f32 * tile_world;
            let border = probe.clone().build().border_size;
            let pad = f32::from(border) * cs;
            let (x0, x1) = (tile_min_x - pad, tile_min_x + tile_world + pad);
            let (z0, z1) = (tile_min_z - pad, tile_min_z + tile_world + pad);

            let mut mesh = TriMesh::default();
            terrain_triangles(pack, x0, x1, z0, z1, &mut mesh);
            for t in &colliders {
                if t.max[0] < x0
                    || t.min[0] > x1
                    || t.max[2] < z0
                    || t.min[2] > z1
                    || t.max[1] < y_min
                    || t.min[1] > y_max
                {
                    continue;
                }
                let base = mesh.vertices.len() as u32;
                mesh.vertices
                    .extend(t.vertices.iter().map(|v| Vec3A::new(v[0], v[1], v[2])));
                for tri in &t.indices {
                    mesh.indices
                        .push(UVec3::new(base + tri[0], base + tri[1], base + tri[2]));
                    mesh.area_types.push(AreaType::NOT_WALKABLE);
                }
            }
            if mesh.indices.is_empty() {
                continue;
            }
            let Some(geometry) = mesh.compute_aabb() else {
                continue;
            };
            let aabb = Aabb3d {
                min: glam::Vec3::new(x0, geometry.min.y.max(y_min), z0),
                max: glam::Vec3::new(x1, geometry.max.y.min(y_max), z1),
            };
            if aabb.min.y >= aabb.max.y {
                continue;
            }
            let config = ConfigBuilder {
                aabb,
                ..probe.clone()
            }
            .build();
            mesh.mark_walkable_triangles(config.walkable_slope_angle);
            let mut heightfield = HeightfieldBuilder {
                aabb,
                cell_size: config.cell_size,
                cell_height: config.cell_height,
            }
            .build()
            .map_err(|e| format!("tile {tx},{tz}: {e:?}"))?;
            heightfield
                .rasterize_triangles(&mesh, config.walkable_climb)
                .map_err(|e| format!("tile {tx},{tz}: {e:?}"))?;
            heightfield.filter_low_hanging_walkable_obstacles(config.walkable_climb);
            heightfield.filter_ledge_spans(config.walkable_height, config.walkable_climb);
            heightfield.filter_walkable_low_height_spans(config.walkable_height);
            let mut compact = heightfield
                .into_compact(config.walkable_height, config.walkable_climb)
                .map_err(|e| format!("tile {tx},{tz}: {e:?}"))?;
            compact.erode_walkable_area(config.walkable_radius);
            compact.build_distance_field();
            compact
                .build_regions(
                    config.border_size,
                    config.min_region_area,
                    config.merge_region_area,
                )
                .map_err(|e| format!("tile {tx},{tz}: {e:?}"))?;
            let contours = compact.build_contours(
                config.max_simplification_error,
                config.max_edge_len,
                config.contour_flags,
            );
            let polys = contours
                .into_polygon_mesh(config.max_vertices_per_polygon)
                .map_err(|e| format!("tile {tx},{tz}: {e:?}"))?;
            baked_tiles += 1;
            let to_world = |v: glam::U16Vec3| {
                [
                    polys.aabb.min.x + f32::from(v.x) * polys.cell_size,
                    polys.aabb.min.y + f32::from(v.y) * polys.cell_height,
                    polys.aabb.min.z + f32::from(v.z) * polys.cell_size,
                ]
            };
            for polygon in polys.polygons() {
                let vertices: Vec<[f32; 3]> = polygon
                    .map(|i| to_world(polys.vertices[usize::from(i)]))
                    .collect();
                if vertices.len() >= 3 {
                    raw.push(RawPoly {
                        tile: (tx, tz),
                        vertices,
                    });
                }
            }
        }
    }
    let (nav, portals, border_links) = stitch(raw, min_x, min_z, tile_world);
    let polygons = nav.polygons.len();
    Ok((
        nav,
        BakeReport {
            tiles: baked_tiles,
            polygons,
            portals,
            border_links,
        },
    ))
}

/// An open polygon edge on a tile border line: polygon, its extent along the
/// line, and its two ends.
type BorderEdge = (u32, f32, f32, [f32; 3], [f32; 3]);

/// Welds vertices (same planar spot within 1 cm and height within the climb),
/// joins polygons on shared edges, and links polygons whose edges overlap
/// along a tile border.
fn stitch(raw: Vec<RawPoly>, min_x: f32, min_z: f32, tile_world: f32) -> (NavMesh, usize, usize) {
    let mut vertices: Vec<[f32; 3]> = Vec::new();
    let mut by_spot: HashMap<(i64, i64), Vec<u32>> = HashMap::new();
    let mut weld = |p: [f32; 3]| -> u32 {
        let key = ((p[0] * 100.0).round() as i64, (p[2] * 100.0).round() as i64);
        let list = by_spot.entry(key).or_default();
        if let Some(&i) = list
            .iter()
            .find(|&&i| (vertices[i as usize][1] - p[1]).abs() <= AGENT_CLIMB)
        {
            return i;
        }
        vertices.push(p);
        let i = (vertices.len() - 1) as u32;
        list.push(i);
        i
    };
    let mut polygons: Vec<Vec<u32>> = Vec::new();
    let mut tiles: Vec<(i32, i32)> = Vec::new();
    for poly in raw {
        let mut ids: Vec<u32> = poly.vertices.iter().map(|&p| weld(p)).collect();
        ids.dedup();
        if ids.len() >= 3 {
            polygons.push(ids);
            tiles.push(poly.tile);
        }
    }

    // Shared edges.
    let mut edges: BTreeMap<(u32, u32), Vec<u32>> = BTreeMap::new();
    for (pi, poly) in polygons.iter().enumerate() {
        for k in 0..poly.len() {
            let (a, b) = (poly[k], poly[(k + 1) % poly.len()]);
            edges
                .entry((a.min(b), a.max(b)))
                .or_default()
                .push(pi as u32);
        }
    }
    let mut portals = Vec::new();
    let mut open: Vec<(u32, u32, u32)> = Vec::new();
    for (&(a, b), owners) in &edges {
        if owners.len() == 2 {
            portals.push(NavPortal {
                a: owners[0],
                b: owners[1],
                p0: vertices[a as usize],
                p1: vertices[b as usize],
            });
        } else if owners.len() == 1 {
            open.push((owners[0], a, b));
        }
    }
    let shared = portals.len();

    // Tile borders: open edges lying on a border line, grouped by line.
    let on_line = |v: f32, origin: f32| -> Option<i64> {
        let k = ((v - origin) / tile_world).round();
        ((v - (origin + k * tile_world)).abs() < 0.02).then_some(k as i64)
    };
    let mut lines: BTreeMap<(u8, i64), Vec<BorderEdge>> = BTreeMap::new();
    for &(poly, a, b) in &open {
        let (pa, pb) = (vertices[a as usize], vertices[b as usize]);
        if let (Some(ka), Some(kb)) = (on_line(pa[0], min_x), on_line(pb[0], min_x))
            && ka == kb
        {
            lines.entry((0, ka)).or_default().push((
                poly,
                pa[2].min(pb[2]),
                pa[2].max(pb[2]),
                pa,
                pb,
            ));
        } else if let (Some(ka), Some(kb)) = (on_line(pa[2], min_z), on_line(pb[2], min_z))
            && ka == kb
        {
            lines.entry((1, ka)).or_default().push((
                poly,
                pa[0].min(pb[0]),
                pa[0].max(pb[0]),
                pa,
                pb,
            ));
        }
    }
    let mut links = 0;
    for ((axis, _), list) in &lines {
        for i in 0..list.len() {
            for j in i + 1..list.len() {
                let (pa, lo_a, hi_a, a0, a1) = list[i];
                let (pb, lo_b, hi_b, b0, b1) = list[j];
                if tiles[pa as usize] == tiles[pb as usize] {
                    continue;
                }
                let (lo, hi) = (lo_a.max(lo_b), hi_a.min(hi_b));
                if hi - lo < AGENT_RADIUS {
                    continue;
                }
                let height = |p0: [f32; 3], p1: [f32; 3], t: f32| {
                    let (s0, s1) = if *axis == 0 {
                        (p0[2], p1[2])
                    } else {
                        (p0[0], p1[0])
                    };
                    let f = if (s1 - s0).abs() < 1e-6 {
                        0.0
                    } else {
                        (t - s0) / (s1 - s0)
                    };
                    p0[1] + (p1[1] - p0[1]) * f
                };
                let mid = (lo + hi) * 0.5;
                if (height(a0, a1, mid) - height(b0, b1, mid)).abs() > AGENT_CLIMB {
                    continue;
                }
                let fixed = if *axis == 0 { a0[0] } else { a0[2] };
                let point = |t: f32| {
                    let y = height(a0, a1, t);
                    if *axis == 0 {
                        [fixed, y, t]
                    } else {
                        [t, y, fixed]
                    }
                };
                portals.push(NavPortal {
                    a: pa,
                    b: pb,
                    p0: point(lo),
                    p1: point(hi),
                });
                links += 1;
            }
        }
    }
    let total = portals.len();
    let _ = shared;
    (
        NavMesh {
            vertices,
            polygons,
            portals,
        },
        total,
        links,
    )
}
