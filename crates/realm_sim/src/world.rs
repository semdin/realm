//! Static world geometry the rules move bodies through. The world compiler
//! produces it from the authoring scenes (`pack::MapPack`); the servers, the
//! client and the bots load the same data. Only queries live here, no physics
//! engine: a body moves by sweeping its capsule and sliding along what it hits.
//!
//! Colliders are filed in a planar grid so a query only looks at the few near
//! it; terrain is a height function evaluated directly (exact for its
//! triangles, far cheaper than sweeping a heightfield shape). Every query
//! visits candidates in ascending index order, so ties resolve the same way
//! on every platform.

use std::collections::HashMap;

use parry3d::bounding_volume::Aabb;
use parry3d::math::{Mat3, Pose, Rot3};
use parry3d::query::{self, Ray, ShapeCastOptions};
use parry3d::shape::{Capsule, SharedShape};

use crate::Vec3;
use crate::pack::{PackCollider, PackShape, v3};

/// Planar size of a collider grid cell, metres.
const CELL: f32 = 16.0;

/// One static collider placed in the world.
#[derive(Clone)]
pub struct Collider {
    pub pose: Pose,
    pub shape: SharedShape,
    aabb: Aabb,
}

/// A body of water: inside the planar rectangle the surface sits at
/// `surface_y`; with `min_depth`, only where the terrain lies at least that
/// far under the surface.
#[derive(Clone, Copy, Debug)]
pub struct WaterArea {
    pub min_x: f32,
    pub max_x: f32,
    pub min_z: f32,
    pub max_z: f32,
    pub surface_y: f32,
    pub min_depth: Option<f32>,
}

/// What a capsule sweep ran into.
#[derive(Clone, Copy, Debug)]
pub struct SweepHit {
    /// Fraction of the requested motion travelled before the contact, `0..=1`.
    pub fraction: f32,
    /// Surface normal at the contact, pointing out of the obstacle.
    pub normal: Vec3,
    /// Contact point on the obstacle, world space.
    pub point: Vec3,
}

/// Where a downward ray met the ground.
#[derive(Clone, Copy, Debug)]
pub struct GroundHit {
    pub point: Vec3,
    pub normal: Vec3,
}

/// The collision world of one map.
#[derive(Clone, Default)]
pub struct World {
    colliders: Vec<Collider>,
    /// Colliders a rule moves or switches (staircases); replaced every tick,
    /// always tested after the static ones.
    moving: Vec<Collider>,
    grid: HashMap<(i32, i32), Vec<u32>>,
    terrain: Vec<Terrain>,
    water: Vec<WaterArea>,
    /// Highest a broom may climb on this map (absolute y).
    pub flight_ceiling_y: f32,
    /// Highest a broom may climb above the ground under it.
    pub flight_max_above_ground: f32,
}

fn cell_range(min: f32, max: f32) -> core::ops::RangeInclusive<i32> {
    ((min / CELL).floor() as i32)..=((max / CELL).floor() as i32)
}

impl World {
    #[must_use]
    pub fn new(flight_ceiling_y: f32, flight_max_above_ground: f32) -> Self {
        Self {
            flight_ceiling_y,
            flight_max_above_ground,
            ..Self::default()
        }
    }

    #[must_use]
    pub fn collider_count(&self) -> usize {
        self.colliders.len()
    }

    pub fn add(&mut self, pose: Pose, shape: SharedShape) {
        let aabb = shape.compute_aabb(&pose);
        let index = self.colliders.len() as u32;
        for cx in cell_range(aabb.mins.x, aabb.maxs.x) {
            for cz in cell_range(aabb.mins.z, aabb.maxs.z) {
                self.grid.entry((cx, cz)).or_default().push(index);
            }
        }
        self.colliders.push(Collider { pose, shape, aabb });
    }

    /// Replaces the moving colliders (call once per tick, before bodies move).
    pub fn set_moving(&mut self, colliders: &[(Pose, SharedShape)]) {
        self.moving.clear();
        for (pose, shape) in colliders {
            let aabb = shape.compute_aabb(pose);
            self.moving.push(Collider {
                pose: *pose,
                shape: shape.clone(),
                aabb,
            });
        }
    }

    /// An axis-aligned box from its centre and half extents.
    pub fn add_box(&mut self, center: Vec3, half_extents: Vec3) {
        self.add(
            Pose::from_translation(center),
            SharedShape::cuboid(half_extents.x, half_extents.y, half_extents.z),
        );
    }

    /// A box rotated about the X axis by `angle` radians (a ramp along Z).
    pub fn add_tilted_box(&mut self, center: Vec3, half_extents: Vec3, angle_x: f32) {
        let pose = Pose::new(center, Vec3::new(angle_x, 0.0, 0.0));
        self.add(
            pose,
            SharedShape::cuboid(half_extents.x, half_extents.y, half_extents.z),
        );
    }

    /// A collider from a map pack.
    pub fn add_pack_collider(&mut self, c: &PackCollider) -> Result<(), String> {
        let [x, y, z, w] = c.rotation;
        let pose = Pose::from_parts(v3(c.translation), Rot3::from_xyzw(x, y, z, w));
        let shape = match &c.shape {
            PackShape::Box { half } => SharedShape::cuboid(half[0], half[1], half[2]),
            PackShape::Sphere { radius } => SharedShape::ball(*radius),
            PackShape::Capsule {
                half_height,
                radius,
            } => SharedShape::capsule_y(*half_height, *radius),
            PackShape::Cylinder {
                half_height,
                radius,
            } => SharedShape::cylinder(*half_height, *radius),
            PackShape::Convex { points } => {
                let points: Vec<Vec3> = points.iter().copied().map(v3).collect();
                SharedShape::convex_hull(&points).ok_or("degenerate convex hull")?
            }
            PackShape::TriMesh { vertices, indices } => {
                SharedShape::trimesh(vertices.iter().copied().map(v3).collect(), indices.clone())
                    .map_err(|e| format!("trimesh: {e:?}"))?
            }
        };
        self.add(pose, shape);
        Ok(())
    }

    /// Terrain: a height grid centred on `center`, `heights` laid out row by
    /// row along Z (`rows` rows of `cols` samples), spanning `size_x` by
    /// `size_z` metres.
    pub fn add_heightfield(
        &mut self,
        center: Vec3,
        rows: usize,
        cols: usize,
        heights: &[f32],
        size_x: f32,
        size_z: f32,
    ) {
        assert!(
            rows > 1 && cols > 1,
            "heightfield needs two rows and columns"
        );
        let heights = heights.iter().map(|h| h + center.y).collect();
        self.add_terrain_grid(
            center.x - size_x * 0.5,
            center.z - size_z * 0.5,
            size_x / (cols - 1) as f32,
            size_z / (rows - 1) as f32,
            rows,
            cols,
            heights,
        );
    }

    /// Terrain from its corner and spacing; NaN heights are holes.
    #[allow(clippy::too_many_arguments)]
    pub fn add_terrain_grid(
        &mut self,
        min_x: f32,
        min_z: f32,
        spacing_x: f32,
        spacing_z: f32,
        rows: usize,
        cols: usize,
        heights: Vec<f32>,
    ) {
        assert_eq!(heights.len(), rows * cols, "terrain sample count");
        assert!(rows > 1 && cols > 1, "terrain needs two rows and columns");
        self.terrain.push(Terrain {
            min_x,
            min_z,
            cell_x: spacing_x,
            cell_z: spacing_z,
            rows,
            cols,
            heights,
        });
    }

    /// Terrain height and surface normal under a planar point.
    #[must_use]
    pub fn terrain_at(&self, x: f32, z: f32) -> Option<(f32, Vec3)> {
        self.terrain.iter().find_map(|t| t.sample(x, z))
    }

    pub fn add_water(&mut self, area: WaterArea) {
        self.water.push(area);
    }

    /// Water surface height at a planar point, if water covers it.
    #[must_use]
    pub fn water_surface_at(&self, x: f32, z: f32) -> Option<f32> {
        self.water
            .iter()
            .find(|w| {
                x >= w.min_x
                    && x <= w.max_x
                    && z >= w.min_z
                    && z <= w.max_z
                    && w.min_depth.is_none_or(|depth| {
                        self.terrain_at(x, z)
                            .is_some_and(|(ground, _)| ground < w.surface_y - depth)
                    })
            })
            .map(|w| w.surface_y)
    }

    /// The collider with this candidate index: static ones first, then the
    /// moving ones numbered after them.
    fn collider(&self, index: u32) -> &Collider {
        let i = index as usize;
        if i < self.colliders.len() {
            &self.colliders[i]
        } else {
            &self.moving[i - self.colliders.len()]
        }
    }

    /// Indices of colliders whose bounds may overlap `bounds`, ascending.
    fn candidates(&self, bounds: &Aabb) -> Vec<u32> {
        let mut out = Vec::new();
        for cx in cell_range(bounds.mins.x, bounds.maxs.x) {
            for cz in cell_range(bounds.mins.z, bounds.maxs.z) {
                if let Some(list) = self.grid.get(&(cx, cz)) {
                    out.extend(
                        list.iter()
                            .copied()
                            .filter(|&i| overlaps(bounds, &self.colliders[i as usize].aabb)),
                    );
                }
            }
        }
        out.sort_unstable();
        out.dedup();
        let base = self.colliders.len() as u32;
        out.extend(
            self.moving
                .iter()
                .enumerate()
                .filter(|(_, c)| overlaps(bounds, &c.aabb))
                .map(|(i, _)| base + i as u32),
        );
        out
    }

    /// Sweeps a vertical capsule (`center` is its middle) along `motion` and
    /// returns the first contact. Contacts the capsule is already moving away
    /// from are ignored, so a body resting on a surface can leave it.
    #[must_use]
    pub fn sweep(&self, capsule: &Capsule, center: Vec3, motion: Vec3) -> Option<SweepHit> {
        let pose = Pose::from_translation(center);
        let start = capsule_aabb(capsule, center);
        let end = capsule_aabb(capsule, center + motion);
        let swept = Aabb::new(start.mins.min(end.mins), start.maxs.max(end.maxs));
        let options = ShapeCastOptions {
            max_time_of_impact: 1.0,
            target_distance: 0.0,
            stop_at_penetration: false,
            compute_impact_geometry_on_penetration: true,
        };
        let mut best: Option<SweepHit> = None;
        for index in self.candidates(&swept) {
            let collider = self.collider(index);
            let Ok(Some(hit)) = query::cast_shapes(
                &pose,
                motion,
                capsule,
                &collider.pose,
                Vec3::ZERO,
                collider.shape.as_ref(),
                options,
            ) else {
                continue;
            };
            if best.is_none_or(|b| hit.time_of_impact < b.fraction) {
                // normal1 is the capsule's outward normal in its own (unrotated)
                // frame; the obstacle's surface normal is its opposite.
                best = Some(SweepHit {
                    fraction: hit.time_of_impact,
                    normal: -hit.normal1.normalize_or_zero(),
                    point: collider.pose * hit.witness2,
                });
            }
        }
        best
    }

    /// How far a capsule at `center` sinks into the world, as the push that
    /// gets it out (zero when it is clear). Resolves the deepest contact only;
    /// callers repeat it a few times for corners.
    #[must_use]
    pub fn depenetration(&self, capsule: &Capsule, center: Vec3) -> Vec3 {
        let pose = Pose::from_translation(center);
        let bounds = capsule_aabb(capsule, center);
        let mut push = Vec3::ZERO;
        let mut deepest = 0.0_f32;
        for index in self.candidates(&bounds) {
            let collider = self.collider(index);
            if let Ok(Some(contact)) =
                query::contact(&pose, capsule, &collider.pose, collider.shape.as_ref(), 0.0)
                && contact.dist < deepest
            {
                deepest = contact.dist;
                // normal1 points from the capsule toward the obstacle.
                push = -contact.normal1 * contact.dist.abs();
            }
        }
        push
    }

    /// Casts a ray straight down from `origin` for at most `max_distance`.
    /// A vertical ray stays in one grid cell, whose list is already in
    /// ascending order: no candidate list to build.
    #[must_use]
    pub fn ray_down(&self, origin: Vec3, max_distance: f32) -> Option<GroundHit> {
        let ray = Ray::new(origin, Vec3::new(0.0, -1.0, 0.0));
        let cell = (
            (origin.x / CELL).floor() as i32,
            (origin.z / CELL).floor() as i32,
        );
        let mut best: Option<(f32, Vec3)> = None;
        for &index in self.grid.get(&cell).map_or(&[][..], Vec::as_slice) {
            let collider = &self.colliders[index as usize];
            let b = &collider.aabb;
            if origin.x < b.mins.x
                || origin.x > b.maxs.x
                || origin.z < b.mins.z
                || origin.z > b.maxs.z
                || origin.y < b.mins.y
                || origin.y - max_distance > b.maxs.y
            {
                continue;
            }
            if let Some(hit) =
                collider
                    .shape
                    .cast_ray_and_get_normal(&collider.pose, &ray, max_distance, true)
                && best.is_none_or(|(toi, _)| hit.time_of_impact < toi)
            {
                best = Some((hit.time_of_impact, hit.normal));
            }
        }
        for collider in &self.moving {
            let b = &collider.aabb;
            if origin.x < b.mins.x
                || origin.x > b.maxs.x
                || origin.z < b.mins.z
                || origin.z > b.maxs.z
            {
                continue;
            }
            if origin.y < b.mins.y || origin.y - max_distance > b.maxs.y {
                continue;
            }
            if let Some(hit) =
                collider
                    .shape
                    .cast_ray_and_get_normal(&collider.pose, &ray, max_distance, true)
                && best.is_none_or(|(toi, _)| hit.time_of_impact < toi)
            {
                best = Some((hit.time_of_impact, hit.normal));
            }
        }
        if let Some((height, normal)) = self.terrain_at(origin.x, origin.z) {
            let toi = origin.y - height;
            if (0.0..=max_distance).contains(&toi) && best.is_none_or(|(b, _)| toi < b) {
                best = Some((toi, normal));
            }
        }
        best.map(|(toi, normal)| GroundHit {
            point: origin - Vec3::new(0.0, toi, 0.0),
            normal,
        })
    }

    /// Height of the highest surface under a planar point (for the broom
    /// ceiling), or `None` over the void.
    #[must_use]
    pub fn ground_height(&self, x: f32, z: f32) -> Option<f32> {
        self.ray_down(
            Vec3::new(x, self.flight_ceiling_y + 1.0, z),
            self.flight_ceiling_y + 2000.0,
        )
        .map(|hit| hit.point.y)
    }
}

/// Rotation of an orthonormal basis given as its three columns (the world
/// compiler's conversion from authoring transforms).
#[must_use]
pub fn basis_rotation(x: Vec3, y: Vec3, z: Vec3) -> [f32; 4] {
    let q = Rot3::from_mat3(&Mat3::from_cols(x, y, z)).normalize();
    [q.x, q.y, q.z, q.w]
}

/// A rotation from quaternion components (x, y, z, w).
#[must_use]
pub fn rotation_from_xyzw(x: f32, y: f32, z: f32, w: f32) -> Rot3 {
    Rot3::from_xyzw(x, y, z, w)
}

/// A regular height grid split into triangles along the (x0,z0)-(x1,z1)
/// diagonal of every cell.
#[derive(Clone)]
struct Terrain {
    min_x: f32,
    min_z: f32,
    cell_x: f32,
    cell_z: f32,
    rows: usize,
    cols: usize,
    heights: Vec<f32>,
}

impl Terrain {
    fn sample(&self, x: f32, z: f32) -> Option<(f32, Vec3)> {
        let gx = (x - self.min_x) / self.cell_x;
        let gz = (z - self.min_z) / self.cell_z;
        let max_x = (self.cols - 1) as f32;
        let max_z = (self.rows - 1) as f32;
        if !(0.0..=max_x).contains(&gx) || !(0.0..=max_z).contains(&gz) {
            return None;
        }
        let col = (gx as usize).min(self.cols - 2);
        let row = (gz as usize).min(self.rows - 2);
        let fx = gx - col as f32;
        let fz = gz - row as f32;
        let h = |r: usize, c: usize| self.heights[r * self.cols + c];
        let (h00, h10, h01, h11) = (
            h(row, col),
            h(row, col + 1),
            h(row + 1, col),
            h(row + 1, col + 1),
        );
        // Slopes along x and z inside the triangle the point is in; a triangle
        // touching a hole is not ground.
        let (dx, dz) = if fx >= fz {
            if h00.is_nan() || h10.is_nan() || h11.is_nan() {
                return None;
            }
            (h10 - h00, h11 - h10)
        } else {
            if h00.is_nan() || h01.is_nan() || h11.is_nan() {
                return None;
            }
            (h11 - h01, h01 - h00)
        };
        let height = h00 + fx * dx + fz * dz;
        let normal = Vec3::new(-dx / self.cell_x, 1.0, -dz / self.cell_z).normalize();
        Some((height, normal))
    }
}

fn capsule_aabb(capsule: &Capsule, center: Vec3) -> Aabb {
    let r = capsule.radius;
    let half = capsule.half_height();
    let extent = Vec3::new(r, half + r, r);
    Aabb::new(center - extent, center + extent)
}

fn overlaps(a: &Aabb, b: &Aabb) -> bool {
    a.mins.x <= b.maxs.x
        && a.maxs.x >= b.mins.x
        && a.mins.y <= b.maxs.y
        && a.maxs.y >= b.mins.y
        && a.mins.z <= b.maxs.z
        && a.maxs.z >= b.mins.z
}
