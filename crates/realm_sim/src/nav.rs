//! Paths on a map's navigation mesh: find the polygon under a point, A* over
//! polygons through their portals, then the funnel (string pulling) for the
//! shortest corner-to-corner line inside that corridor. Deterministic: ties
//! break on polygon index, so the same query gives the same path everywhere.

use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap};

use crate::Vec3;
use crate::pack::{NavMesh, v3};
use crate::world::World;

const CELL: f32 = 8.0;

/// The smallest connected walkable area (m²) that is ground for creatures.
/// A roof, a wall top or a crate's lid bakes into a small island of its own
/// (a greenhouse's glass roof is about 110 m²); the ground of a map, a
/// fortress yard or a cavern hall is far bigger.
pub const GROUND_GROUP_AREA: f32 = 1000.0;
/// How far the mesh's surface may lie from a spot on the terrain: its
/// polygons only approximate rolling ground, metres off in places (where a
/// polygon's flat face strays further, `TerrainFit` carries the terrain's
/// own heights).
const TERRAIN_SLACK: f32 = 8.0;
/// ... and from a spot on built floor (a collider's flat or stepped top),
/// which the mesh follows closely.
const FLOOR_SLACK: f32 = 1.0;
/// Steepest ground a creature is put on (the normal's up component).
pub const FLAT_ENOUGH: f32 = 0.72;
/// How far from any trunk or spire a creature is put (about a body).
pub const OBSTACLE_CLEARANCE: f32 = 0.5;
/// A polygon lies on the terrain when each of its corners is this close to
/// it (the bake puts walkable faces a voxel or so over the ground).
const ON_TERRAIN: f32 = 0.5;
/// A polygon on the terrain whose flat face strays further than this from
/// the terrain inside it follows the terrain's heights instead (a whole
/// 90 m tile of open ground is one polygon: over a hollow its face can hang
/// 12 m in the air, and nothing standing in the hollow would be on it).
const FIT_TOLERANCE: f32 = 1.0;
/// Spacing of those heights (m): the grounds keep about 4900 polygons'
/// worth, 1.8 MB.
const FIT_STEP: f32 = 4.0;

/// The terrain's heights over a polygon that lies on it, on a regular grid
/// over its bounds (NaN off the terrain).
struct TerrainFit {
    min: (f32, f32),
    cols: usize,
    rows: usize,
    heights: Vec<f32>,
}

impl TerrainFit {
    /// Bilinear height at (x, z); None off the grid or next to a hole.
    fn height(&self, x: f32, z: f32) -> Option<f32> {
        let fx = ((x - self.min.0) / FIT_STEP).max(0.0);
        let fz = ((z - self.min.1) / FIT_STEP).max(0.0);
        let c0 = (fx as usize).min(self.cols - 2);
        let r0 = (fz as usize).min(self.rows - 2);
        let (tx, tz) = ((fx - c0 as f32).min(1.0), (fz - r0 as f32).min(1.0));
        let h = |r: usize, c: usize| self.heights[r * self.cols + c];
        let (a, b, c, d) = (h(r0, c0), h(r0, c0 + 1), h(r0 + 1, c0), h(r0 + 1, c0 + 1));
        let y = (a * (1.0 - tx) + b * tx) * (1.0 - tz) + (c * (1.0 - tx) + d * tx) * tz;
        y.is_finite().then_some(y)
    }
}

struct Poly {
    vertices: Vec<Vec3>,
    center: Vec3,
    /// (neighbour, portal end, portal end)
    links: Vec<(u32, Vec3, Vec3)>,
    min: (f32, f32),
    max: (f32, f32),
    /// The connected group (island) it belongs to.
    group: u32,
    /// The terrain's heights, for a polygon on rolling terrain its flat
    /// face does not follow.
    fit: Option<Box<TerrainFit>>,
}

/// Reusable search state: entries are valid only where `stamp` equals the
/// current search's generation, so a search touches only what it visits
/// instead of clearing arrays the size of the whole mesh.
#[derive(Default)]
pub struct NavScratch {
    generation: u32,
    stamp: Vec<u32>,
    g: Vec<f32>,
    came: Vec<u32>,
    entry: Vec<Vec3>,
    heap: BinaryHeap<Open>,
}

impl NavScratch {
    fn begin(&mut self, n: usize) {
        if self.stamp.len() != n {
            self.stamp = vec![0; n];
            self.g = vec![0.0; n];
            self.came = vec![0; n];
            self.entry = vec![Vec3::ZERO; n];
            self.generation = 0;
        }
        self.generation = self.generation.wrapping_add(1);
        if self.generation == 0 {
            self.stamp.iter_mut().for_each(|s| *s = 0);
            self.generation = 1;
        }
        self.heap.clear();
    }

    fn g(&self, i: u32) -> f32 {
        if self.stamp[i as usize] == self.generation {
            self.g[i as usize]
        } else {
            f32::INFINITY
        }
    }

    fn set(&mut self, i: u32, g: f32, came: u32, entry: Vec3) {
        let k = i as usize;
        self.stamp[k] = self.generation;
        self.g[k] = g;
        self.came[k] = came;
        self.entry[k] = entry;
    }
}

pub struct NavQuery {
    polys: Vec<Poly>,
    grid: HashMap<(i32, i32), Vec<u32>>,
    /// Each connected group's walkable area (m², on the ground plane).
    group_area: Vec<f32>,
}

#[derive(PartialEq)]
pub(crate) struct Open {
    cost: f32,
    poly: u32,
}

impl Eq for Open {}

impl Ord for Open {
    fn cmp(&self, other: &Self) -> Ordering {
        other
            .cost
            .total_cmp(&self.cost)
            .then_with(|| other.poly.cmp(&self.poly))
    }
}

impl PartialOrd for Open {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

fn cross_xz(o: Vec3, a: Vec3, b: Vec3) -> f32 {
    (a.x - o.x) * (b.z - o.z) - (a.z - o.z) * (b.x - o.x)
}

impl NavQuery {
    /// The query for a map's mesh on its collision world's terrain.
    #[must_use]
    pub fn for_world(mesh: &NavMesh, world: &World) -> Self {
        Self::new(mesh, |x, z| world.terrain_at(x, z).map(|t| t.0))
    }

    /// The query for `mesh`; `terrain` gives the map's terrain height at a
    /// planar point (None off it or over a hole), which the polygons lying
    /// on rolling terrain follow (`TerrainFit`).
    #[must_use]
    pub fn new(mesh: &NavMesh, terrain: impl Fn(f32, f32) -> Option<f32>) -> Self {
        let mut polys: Vec<Poly> = mesh
            .polygons
            .iter()
            .map(|ids| {
                let vertices: Vec<Vec3> =
                    ids.iter().map(|&i| v3(mesh.vertices[i as usize])).collect();
                let center =
                    vertices.iter().fold(Vec3::ZERO, |a, v| a + *v) / vertices.len() as f32;
                let min = vertices
                    .iter()
                    .fold((f32::MAX, f32::MAX), |m, v| (m.0.min(v.x), m.1.min(v.z)));
                let max = vertices
                    .iter()
                    .fold((f32::MIN, f32::MIN), |m, v| (m.0.max(v.x), m.1.max(v.z)));
                Poly {
                    vertices,
                    center,
                    links: Vec::new(),
                    min,
                    max,
                    group: u32::MAX,
                    fit: None,
                }
            })
            .collect();
        for poly in &mut polys {
            poly.fit = terrain_fit(poly, &terrain);
        }
        for portal in &mesh.portals {
            let (p0, p1) = (v3(portal.p0), v3(portal.p1));
            polys[portal.a as usize].links.push((portal.b, p0, p1));
            polys[portal.b as usize].links.push((portal.a, p0, p1));
        }
        let mut grid: HashMap<(i32, i32), Vec<u32>> = HashMap::new();
        for (i, p) in polys.iter().enumerate() {
            for cx in ((p.min.0 / CELL).floor() as i32)..=((p.max.0 / CELL).floor() as i32) {
                for cz in ((p.min.1 / CELL).floor() as i32)..=((p.max.1 / CELL).floor() as i32) {
                    grid.entry((cx, cz)).or_default().push(i as u32);
                }
            }
        }
        // Connected groups and their areas.
        let mut group_area = Vec::new();
        for start in 0..polys.len() {
            if polys[start].group != u32::MAX {
                continue;
            }
            let group = group_area.len() as u32;
            let mut area = 0.0;
            let mut stack = vec![start];
            polys[start].group = group;
            while let Some(p) = stack.pop() {
                area += area_xz(&polys[p].vertices);
                for k in 0..polys[p].links.len() {
                    let n = polys[p].links[k].0 as usize;
                    if polys[n].group == u32::MAX {
                        polys[n].group = group;
                        stack.push(n);
                    }
                }
            }
            group_area.push(area);
        }
        Self {
            polys,
            grid,
            group_area,
        }
    }

    /// The walkable area (m²) of the connected group `poly` belongs to: a
    /// roof or a wall top is a small island, the map's ground a big one.
    #[must_use]
    pub fn group_area(&self, poly: u32) -> f32 {
        self.group_area[self.polys[poly as usize].group as usize]
    }

    /// Whether `spot` (feet, on the highest surface under the sky there, as
    /// `World::ground_height` finds it) is ground a creature may be put on:
    /// over a polygon of a big walkable group (`GROUND_GROUP_AREA`), not on
    /// a roof, a wall top or a prop, and not on ground too steep or too
    /// cramped to walk.
    #[must_use]
    pub fn on_ground(&self, world: &World, spot: Vec3) -> bool {
        let on_terrain = world
            .terrain_at(spot.x, spot.z)
            .is_some_and(|(height, _)| spot.y - height < 0.3);
        let slack = if on_terrain {
            TERRAIN_SLACK
        } else {
            FLOOR_SLACK
        };
        self.locate_surface(spot, slack)
            .is_some_and(|poly| self.group_area(poly) >= GROUND_GROUP_AREA)
    }

    /// Where a creature put down at (x, z) stands: the highest surface there
    /// under the sky (through trunks and spires), when that is ground for
    /// it (`on_ground`), flat enough, dry and clear of every obstacle; None
    /// on a roof, a prop, a steep slope, in water or in a trunk.
    #[must_use]
    pub fn creature_spot(&self, world: &World, x: f32, z: f32) -> Option<Vec3> {
        let spot = Vec3::new(x, world.ground_height(x, z)?, z);
        let flat = world
            .ray_down(spot + Vec3::new(0.0, 1.0, 0.0), 2.0)
            .is_some_and(|g| g.normal.y >= FLAT_ENOUGH);
        let wet = world.water_surface_at(x, z).is_some_and(|w| w > spot.y);
        (flat
            && !wet
            && !world.in_obstacle(spot, OBSTACLE_CLEARANCE)
            && self.on_ground(world, spot))
        .then_some(spot)
    }

    /// Every point of an area (centre, half extents) on a 1 m grid,
    /// nearest the centre first: where a placement that found nothing by
    /// chance looks through the whole area before giving up.
    fn area_points(center: (f32, f32), half: (f32, f32)) -> Vec<(f32, f32)> {
        let (nx, nz) = (half.0.max(0.0) as i32, half.1.max(0.0) as i32);
        let mut points: Vec<(i32, i32)> = (-nz..=nz)
            .flat_map(|j| (-nx..=nx).map(move |i| (i, j)))
            .collect();
        // Stable: ties keep row order, so every caller walks the same list.
        points.sort_by_key(|&(i, j)| i * i + j * j);
        points
            .into_iter()
            .map(|(i, j)| (center.0 + i as f32, center.1 + j as f32))
            .collect()
    }

    /// The creature spot (`creature_spot`) nearest an area's centre on its
    /// 1 m grid (`area_points`) that `accept` takes; None when the area
    /// holds no ground for creatures at all.
    #[must_use]
    pub fn ground_in_area(
        &self,
        world: &World,
        center: (f32, f32),
        half: (f32, f32),
        mut accept: impl FnMut(Vec3) -> bool,
    ) -> Option<Vec3> {
        Self::area_points(center, half)
            .into_iter()
            .filter_map(|(x, z)| self.creature_spot(world, x, z))
            .find(|spot| accept(*spot))
    }

    /// The largest connected group's area (m²).
    #[must_use]
    pub fn largest_group_area(&self) -> f32 {
        self.group_area.iter().copied().fold(0.0, f32::max)
    }

    /// Height of `poly`'s surface at the planar point (x, z): the terrain's
    /// for a polygon fitted to it, else the triangle fan of its vertices
    /// (the point is assumed inside it).
    #[must_use]
    pub fn surface_y(&self, poly: u32, x: f32, z: f32) -> f32 {
        if let Some(y) = self.polys[poly as usize]
            .fit
            .as_ref()
            .and_then(|f| f.height(x, z))
        {
            return y;
        }
        let p = &self.polys[poly as usize];
        face_y(&p.vertices, x, z).unwrap_or(p.center.y)
    }

    /// The polygon whose surface under `p` lies closest to `p`'s height
    /// (within `max_dy`): where something standing at `p` actually is on
    /// the mesh, unlike `locate`'s nearest polygon centre.
    #[must_use]
    pub fn locate_surface(&self, p: Vec3, max_dy: f32) -> Option<u32> {
        let cell = ((p.x / CELL).floor() as i32, (p.z / CELL).floor() as i32);
        let mut best: Option<(f32, u32)> = None;
        for &i in self.grid.get(&cell)? {
            let poly = &self.polys[i as usize];
            if p.x < poly.min.0 || p.x > poly.max.0 || p.z < poly.min.1 || p.z > poly.max.1 {
                continue;
            }
            if !inside_xz(&poly.vertices, p) {
                continue;
            }
            let dy = (self.surface_y(i, p.x, p.z) - p.y).abs();
            if dy <= max_dy && best.is_none_or(|(b, _)| dy < b) {
                best = Some((dy, i));
            }
        }
        best.map(|(_, i)| i)
    }

    #[must_use]
    pub fn polygon_count(&self) -> usize {
        self.polys.len()
    }

    /// Connected groups of polygons, largest first (a diagnostic for the
    /// world compiler).
    #[must_use]
    pub fn component_sizes(&self) -> Vec<usize> {
        let mut seen = vec![false; self.polys.len()];
        let mut sizes = Vec::new();
        for start in 0..self.polys.len() {
            if seen[start] {
                continue;
            }
            let mut stack = vec![start];
            seen[start] = true;
            let mut size = 0;
            while let Some(p) = stack.pop() {
                size += 1;
                for &(n, _, _) in &self.polys[p].links {
                    if !seen[n as usize] {
                        seen[n as usize] = true;
                        stack.push(n as usize);
                    }
                }
            }
            sizes.push(size);
        }
        sizes.sort_unstable_by(|a, b| b.cmp(a));
        sizes
    }

    /// The polygon under `p` whose surface is closest in height (within
    /// `max_dy`).
    #[must_use]
    pub fn locate(&self, p: Vec3, max_dy: f32) -> Option<u32> {
        let cell = ((p.x / CELL).floor() as i32, (p.z / CELL).floor() as i32);
        let mut best: Option<(f32, u32)> = None;
        for &i in self.grid.get(&cell)? {
            let poly = &self.polys[i as usize];
            if p.x < poly.min.0 || p.x > poly.max.0 || p.z < poly.min.1 || p.z > poly.max.1 {
                continue;
            }
            if !inside_xz(&poly.vertices, p) {
                continue;
            }
            let dy = (poly.center.y - p.y).abs();
            if dy <= max_dy && best.is_none_or(|(b, _)| dy < b) {
                best = Some((dy, i));
            }
        }
        best.map(|(_, i)| i)
    }

    /// A walkable path from `from` to `to` (both near the mesh), at most
    /// `max_nodes` polygons explored. Returns the corner points, ending at `to`.
    #[must_use]
    pub fn path(
        &self,
        from: Vec3,
        to: Vec3,
        max_nodes: usize,
        scratch: &mut NavScratch,
    ) -> Option<Vec<Vec3>> {
        // Where each end stands on the mesh: the polygon whose surface under
        // it lies closest (a polygon's centre can lie metres off the rolling
        // ground it spans, and a search that cannot start would leave the
        // walker a straight line through whatever stands between).
        let start = self.locate_surface(from, TERRAIN_SLACK)?;
        let goal = self.locate_surface(to, TERRAIN_SLACK)?;
        if start == goal {
            return Some(vec![to]);
        }
        scratch.begin(self.polys.len());
        scratch.set(start, 0.0, u32::MAX, from);
        scratch.heap.push(Open {
            cost: (to - from).length(),
            poly: start,
        });
        let mut explored = 0;
        let mut reached = false;
        while let Some(Open { poly, .. }) = scratch.heap.pop() {
            if poly == goal {
                reached = true;
                break;
            }
            explored += 1;
            if explored > max_nodes {
                return None;
            }
            let here = scratch.entry[poly as usize];
            let base = scratch.g[poly as usize];
            for &(next, p0, p1) in &self.polys[poly as usize].links {
                let mid = (p0 + p1) * 0.5;
                let cost = base + (mid - here).length();
                if cost < scratch.g(next) {
                    scratch.set(next, cost, poly, mid);
                    scratch.heap.push(Open {
                        cost: cost + (to - mid).length(),
                        poly: next,
                    });
                }
            }
        }
        if !reached {
            return None;
        }
        // Corridor from start to goal, then its portals in travel order.
        let mut corridor = vec![goal];
        while *corridor.last()? != start {
            corridor.push(scratch.came[*corridor.last()? as usize]);
        }
        corridor.reverse();
        let mut portals: Vec<(Vec3, Vec3)> = Vec::with_capacity(corridor.len());
        for pair in corridor.windows(2) {
            let (a, b) = (pair[0], pair[1]);
            let &(_, p0, p1) = self.polys[a as usize].links.iter().find(|l| l.0 == b)?;
            // Left and right as seen walking from a's centre into b.
            let dir_from = self.polys[a as usize].center;
            if cross_xz(dir_from, p0, p1) > 0.0 {
                portals.push((p1, p0))
            } else {
                portals.push((p0, p1))
            }
        }
        portals.push((to, to));
        Some(funnel(from, &portals))
    }
}

/// Inside a convex polygon on the ground plane; a point within 2 cm of an
/// edge counts as inside (shortest paths run along edges and corners).
fn inside_xz(vertices: &[Vec3], p: Vec3) -> bool {
    let mut sign = 0.0_f32;
    for k in 0..vertices.len() {
        let (a, b) = (vertices[k], vertices[(k + 1) % vertices.len()]);
        let c = cross_xz(a, b, p);
        let len = ((b.x - a.x) * (b.x - a.x) + (b.z - a.z) * (b.z - a.z)).sqrt();
        if len < 1e-6 || (c / len).abs() < 0.02 {
            continue;
        }
        if sign == 0.0 {
            sign = c.signum();
        } else if c.signum() != sign {
            return false;
        }
    }
    true
}

/// Height of the polygon's flat face (its corners' triangle fan) at the
/// planar point (x, z) inside it.
fn face_y(vertices: &[Vec3], x: f32, z: f32) -> Option<f32> {
    let p = Vec3::new(x, 0.0, z);
    for k in 1..vertices.len().saturating_sub(1) {
        let (a, b, c) = (vertices[0], vertices[k], vertices[k + 1]);
        let d = cross_xz(a, b, c);
        if d.abs() < 1e-8 {
            continue;
        }
        let wb = cross_xz(a, p, c) / d;
        let wc = cross_xz(a, b, p) / d;
        let wa = 1.0 - wb - wc;
        if wa >= -1e-3 && wb >= -1e-3 && wc >= -1e-3 {
            return Some(wa * a.y + wb * b.y + wc * c.y);
        }
    }
    None
}

/// The terrain's heights over `poly` when it lies on the terrain (every
/// corner within `ON_TERRAIN`) and its flat face strays more than
/// `FIT_TOLERANCE` from the terrain somewhere inside it; None otherwise (a
/// floor, a roof, or ground its face follows well enough).
fn terrain_fit(poly: &Poly, terrain: &impl Fn(f32, f32) -> Option<f32>) -> Option<Box<TerrainFit>> {
    let on_terrain = poly
        .vertices
        .iter()
        .all(|v| terrain(v.x, v.z).is_some_and(|t| (v.y - t).abs() <= ON_TERRAIN));
    if !on_terrain {
        return None;
    }
    let cols = ((poly.max.0 - poly.min.0) / FIT_STEP).ceil() as usize + 2;
    let rows = ((poly.max.1 - poly.min.1) / FIT_STEP).ceil() as usize + 2;
    let mut heights = Vec::with_capacity(cols * rows);
    let mut strays = false;
    for r in 0..rows {
        for c in 0..cols {
            let (x, z) = (
                poly.min.0 + c as f32 * FIT_STEP,
                poly.min.1 + r as f32 * FIT_STEP,
            );
            let t = terrain(x, z);
            if !strays
                && let Some(t) = t
                && inside_xz(&poly.vertices, Vec3::new(x, 0.0, z))
                && face_y(&poly.vertices, x, z).is_some_and(|y| (y - t).abs() > FIT_TOLERANCE)
            {
                strays = true;
            }
            heights.push(t.unwrap_or(f32::NAN));
        }
    }
    strays.then(|| {
        Box::new(TerrainFit {
            min: poly.min,
            cols,
            rows,
            heights,
        })
    })
}

/// Area of a convex polygon on the ground plane.
fn area_xz(vertices: &[Vec3]) -> f32 {
    let mut twice = 0.0;
    for k in 1..vertices.len().saturating_sub(1) {
        twice += cross_xz(vertices[0], vertices[k], vertices[k + 1]);
    }
    twice.abs() * 0.5
}

/// Twice the signed area of (a, b, c) on the ground plane, in the sign
/// convention of the reference funnel implementation.
fn triarea2(a: Vec3, b: Vec3, c: Vec3) -> f32 {
    (c.x - a.x) * (b.z - a.z) - (b.x - a.x) * (c.z - a.z)
}

fn same_xz(a: Vec3, b: Vec3) -> bool {
    (a.x - b.x).abs() < 1e-4 && (a.z - b.z).abs() < 1e-4
}

/// Simple stupid funnel algorithm (Mononen) over (left, right) portals; the
/// first portal is the start point, the last the end point.
fn funnel(start: Vec3, portals: &[(Vec3, Vec3)]) -> Vec<Vec3> {
    let mut all = Vec::with_capacity(portals.len() + 1);
    all.push((start, start));
    all.extend_from_slice(portals);
    let mut path = Vec::new();
    let (mut apex, mut left, mut right) = (start, start, start);
    let (mut left_i, mut right_i) = (0_usize, 0_usize);
    let mut i = 1;
    while i < all.len() {
        let (pl, pr) = all[i];
        // Right side.
        if triarea2(apex, right, pr) <= 0.0 {
            if same_xz(apex, right) || triarea2(apex, left, pr) > 0.0 {
                right = pr;
                right_i = i;
            } else {
                path.push(left);
                apex = left;
                let restart = left_i;
                right = apex;
                right_i = restart;
                i = restart + 1;
                continue;
            }
        }
        // Left side.
        if triarea2(apex, left, pl) >= 0.0 {
            if same_xz(apex, left) || triarea2(apex, right, pl) < 0.0 {
                left = pl;
                left_i = i;
            } else {
                path.push(right);
                apex = right;
                let restart = right_i;
                left = apex;
                left_i = restart;
                i = restart + 1;
                continue;
            }
        }
        i += 1;
    }
    let end = all.last().map_or(start, |p| p.0);
    if path.last().is_none_or(|p| !same_xz(*p, end)) {
        path.push(end);
    }
    path
}
