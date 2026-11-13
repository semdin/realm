//! Static world geometry the rules move bodies through. The world compiler
//! (Phase 3) produces it from the Godot scenes; the servers, the client and the
//! bots load the same data. Only queries live here, no physics engine: a body
//! moves by sweeping its capsule and sliding along what it hits.

use parry3d::bounding_volume::Aabb;
use parry3d::math::Pose;
use parry3d::query::{self, Ray, ShapeCastOptions};
use parry3d::shape::{Capsule, SharedShape};
use parry3d::utils::Array2;

use crate::Vec3;

/// One static collider placed in the world.
#[derive(Clone)]
pub struct Collider {
    pub pose: Pose,
    pub shape: SharedShape,
    aabb: Aabb,
}

/// A body of water: inside the planar rectangle the surface sits at
/// `surface_y`.
#[derive(Clone, Copy, Debug)]
pub struct WaterArea {
    pub min_x: f32,
    pub max_x: f32,
    pub min_z: f32,
    pub max_z: f32,
    pub surface_y: f32,
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
    water: Vec<WaterArea>,
    /// Highest a broom may climb on this map (absolute y).
    pub flight_ceiling_y: f32,
    /// Highest a broom may climb above the ground under it.
    pub flight_max_above_ground: f32,
}

impl World {
    #[must_use]
    pub fn new(flight_ceiling_y: f32, flight_max_above_ground: f32) -> Self {
        Self {
            colliders: Vec::new(),
            water: Vec::new(),
            flight_ceiling_y,
            flight_max_above_ground,
        }
    }

    pub fn add(&mut self, pose: Pose, shape: SharedShape) {
        let aabb = shape.compute_aabb(&pose);
        self.colliders.push(Collider { pose, shape, aabb });
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

    /// A heightfield centred on `center`, `heights` laid out row by row along
    /// Z (`rows` rows of `cols` samples, row-major), spanning `size_x` by
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
        assert_eq!(heights.len(), rows * cols, "heightfield sample count");
        // parry's Array2 is column-major: index = row + col * rows.
        let mut column_major = vec![0.0; rows * cols];
        for row in 0..rows {
            for col in 0..cols {
                column_major[row + col * rows] = heights[row * cols + col];
            }
        }
        let shape = SharedShape::heightfield(
            Array2::new(rows, cols, column_major),
            Vec3::new(size_x, 1.0, size_z),
        );
        self.add(Pose::from_translation(center), shape);
    }

    pub fn add_water(&mut self, area: WaterArea) {
        self.water.push(area);
    }

    /// Water surface height at a planar point, if any water covers it.
    #[must_use]
    pub fn water_surface_at(&self, x: f32, z: f32) -> Option<f32> {
        self.water
            .iter()
            .find(|w| x >= w.min_x && x <= w.max_x && z >= w.min_z && z <= w.max_z)
            .map(|w| w.surface_y)
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
        for collider in &self.colliders {
            if !overlaps(&swept, &collider.aabb) {
                continue;
            }
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
        for collider in &self.colliders {
            if !overlaps(&bounds, &collider.aabb) {
                continue;
            }
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
    #[must_use]
    pub fn ray_down(&self, origin: Vec3, max_distance: f32) -> Option<GroundHit> {
        let ray = Ray::new(origin, Vec3::new(0.0, -1.0, 0.0));
        let mut best: Option<(f32, Vec3)> = None;
        for collider in &self.colliders {
            if origin.x < collider.aabb.mins.x
                || origin.x > collider.aabb.maxs.x
                || origin.z < collider.aabb.mins.z
                || origin.z > collider.aabb.maxs.z
                || origin.y - max_distance > collider.aabb.maxs.y
                || origin.y < collider.aabb.mins.y
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
