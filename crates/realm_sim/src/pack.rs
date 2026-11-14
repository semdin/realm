//! Map packs: the compiled collision world of one map, as the world compiler
//! (`realm_worldc`) writes it and the servers, the client and the bots load
//! it. Pure data with serde; the caller does the file reading and the
//! compression. Every number is stored exactly as the world will use it, so
//! a pack builds the same `World` on every platform.

use serde::{Deserialize, Serialize};

use parry3d::shape::{Ball, Capsule, ConvexPolyhedron, Cuboid, Cylinder};

use crate::Vec3;
use crate::world::{WaterArea, World};

/// Bumped whenever the layout changes.
pub const PACK_VERSION: u32 = 2;

/// Height grid value meaning "no terrain here" (a hole).
pub const HOLE: i32 = i32::MIN;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MapPack {
    pub version: u32,
    pub map: String,
    pub flight_ceiling_y: f32,
    pub flight_max_above_ground: f32,
    pub terrain: Vec<TerrainGrid>,
    pub water: Vec<PackWater>,
    pub colliders: Vec<PackCollider>,
    /// Moving geometry the export found outside any rule: kept out of the
    /// static world.
    pub dynamic: Vec<DynamicCollider>,
    /// Polygons creatures path on (empty until baked).
    pub nav: NavMesh,
    /// Where each moving staircase stands (its spec is in the content).
    pub staircases: Vec<StairAnchor>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub struct StairAnchor {
    /// Entry of the content's `staircases` list.
    pub spec_index: u32,
    pub id: u32,
    pub translation: [f32; 3],
    /// Yaw about +Y, radians.
    pub yaw: f32,
}

/// Heights in 1/256 m, row by row along +Z, `cols` samples per row.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TerrainGrid {
    pub min_x: f32,
    pub min_z: f32,
    pub spacing_x: f32,
    pub spacing_z: f32,
    pub rows: u32,
    pub cols: u32,
    pub heights: Vec<i32>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub struct PackWater {
    pub min_x: f32,
    pub max_x: f32,
    pub min_z: f32,
    pub max_z: f32,
    pub surface_y: f32,
    /// Water only where the terrain lies at least this far under the surface.
    pub min_depth: Option<f32>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PackCollider {
    pub translation: [f32; 3],
    /// Rotation quaternion (x, y, z, w).
    pub rotation: [f32; 4],
    pub shape: PackShape,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DynamicCollider {
    /// Where it came from in the authoring scene, for the rules to find it.
    pub source: String,
    pub collider: PackCollider,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub enum PackShape {
    Box {
        half: [f32; 3],
    },
    Sphere {
        radius: f32,
    },
    /// Along Y; `half_height` is the half length of the straight part.
    Capsule {
        half_height: f32,
        radius: f32,
    },
    Cylinder {
        half_height: f32,
        radius: f32,
    },
    Convex {
        points: Vec<[f32; 3]>,
    },
    TriMesh {
        vertices: Vec<[f32; 3]>,
        indices: Vec<[u32; 3]>,
    },
}

/// Convex polygons creatures walk on, and the portals between neighbours:
/// a shared edge, or the overlap of two edges on a tile border.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct NavMesh {
    pub vertices: Vec<[f32; 3]>,
    pub polygons: Vec<Vec<u32>>,
    pub portals: Vec<NavPortal>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub struct NavPortal {
    pub a: u32,
    pub b: u32,
    /// The opening's two ends.
    pub p0: [f32; 3],
    pub p1: [f32; 3],
}

/// One collider as world-space triangles (navigation bake, debug drawing).
pub struct ColliderMesh {
    pub vertices: Vec<[f32; 3]>,
    pub indices: Vec<[u32; 3]>,
    pub min: [f32; 3],
    pub max: [f32; 3],
}

impl MapPack {
    /// Every static collider as world-space triangles.
    #[must_use]
    pub fn collider_meshes(&self) -> Vec<ColliderMesh> {
        let mut out = Vec::new();
        for c in &self.colliders {
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
            let rotation = crate::world::rotation_from_xyzw(x, y, z, w);
            let t = v3(c.translation);
            let vertices: Vec<[f32; 3]> = local
                .iter()
                .map(|p| {
                    let q = rotation * *p + t;
                    [q.x, q.y, q.z]
                })
                .collect();
            let (min, max) = bounds(&vertices);
            out.push(ColliderMesh {
                vertices,
                indices,
                min,
                max,
            });
        }
        out
    }

    /// Builds the collision world.
    pub fn world(&self) -> Result<World, String> {
        if self.version != PACK_VERSION {
            return Err(format!(
                "map pack version {} (this build reads {PACK_VERSION})",
                self.version
            ));
        }
        let mut world = World::new(self.flight_ceiling_y, self.flight_max_above_ground);
        for grid in &self.terrain {
            let heights: Vec<f32> = grid
                .heights
                .iter()
                .map(|&h| {
                    if h == HOLE {
                        f32::NAN
                    } else {
                        h as f32 / crate::WIRE_GRID
                    }
                })
                .collect();
            world.add_terrain_grid(
                grid.min_x,
                grid.min_z,
                grid.spacing_x,
                grid.spacing_z,
                grid.rows as usize,
                grid.cols as usize,
                heights,
            );
        }
        for w in &self.water {
            world.add_water(WaterArea {
                min_x: w.min_x,
                max_x: w.max_x,
                min_z: w.min_z,
                max_z: w.max_z,
                surface_y: w.surface_y,
                min_depth: w.min_depth,
            });
        }
        for (index, collider) in self.colliders.iter().enumerate() {
            world
                .add_pack_collider(collider)
                .map_err(|e| format!("collider {index}: {e}"))?;
        }
        Ok(world)
    }

    /// The collision world with the map's colliders laid down once per
    /// `offset` (copies of a dungeon side by side; terrain and water once).
    pub fn world_copies(&self, offsets: &[Vec3]) -> Result<World, String> {
        let mut copy = self.clone();
        copy.colliders.clear();
        let mut world = copy.world()?;
        for offset in offsets {
            for (index, collider) in self.colliders.iter().enumerate() {
                let (pose, shape) = crate::world::pack_shape(collider, *offset)
                    .map_err(|e| format!("collider {index}: {e}"))?;
                world.add(pose, shape);
            }
        }
        Ok(world)
    }

    /// The dungeon gates (`gate:<id>` dynamic colliders) for each copy:
    /// copy `i + 1` at `offsets[i]`. All start closed.
    pub fn gates(&self, offsets: &[Vec3]) -> Result<crate::gates::Gates, String> {
        let mut gates = Vec::new();
        for (i, offset) in offsets.iter().enumerate() {
            for d in &self.dynamic {
                let Some(id) = d.source.strip_prefix("gate:") else {
                    continue;
                };
                let (pose, shape) = crate::world::pack_shape(&d.collider, *offset)?;
                gates.push(crate::gates::Gate {
                    id: id.to_owned(),
                    copy: (i + 1) as u8,
                    pose,
                    shape,
                    changes: Vec::new(),
                });
            }
        }
        Ok(crate::gates::Gates::new(gates))
    }

    /// The navigation mesh laid down once per offset.
    #[must_use]
    pub fn nav_copies(&self, offsets: &[Vec3]) -> NavMesh {
        let mut out = NavMesh::default();
        for offset in offsets {
            let base = out.vertices.len() as u32;
            let poly_base = out.polygons.len() as u32;
            let o = [offset.x, offset.y, offset.z];
            let add = |p: [f32; 3]| [p[0] + o[0], p[1] + o[1], p[2] + o[2]];
            out.vertices
                .extend(self.nav.vertices.iter().map(|v| add(*v)));
            out.polygons.extend(
                self.nav
                    .polygons
                    .iter()
                    .map(|p| p.iter().map(|i| i + base).collect::<Vec<u32>>()),
            );
            out.portals
                .extend(self.nav.portals.iter().map(|p| NavPortal {
                    a: p.a + poly_base,
                    b: p.b + poly_base,
                    p0: add(p.p0),
                    p1: add(p.p1),
                }));
        }
        out
    }
}

/// File header: magic, then the pack version, then zstd(postcard(MapPack)).
pub const MAGIC: &[u8; 4] = b"RMAP";

pub fn v3(a: [f32; 3]) -> Vec3 {
    Vec3::new(a[0], a[1], a[2])
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
