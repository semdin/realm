//! Paths on a map's navigation mesh: find the polygon under a point, A* over
//! polygons through their portals, then the funnel (string pulling) for the
//! shortest corner-to-corner line inside that corridor. Deterministic: ties
//! break on polygon index, so the same query gives the same path everywhere.

use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap};

use crate::Vec3;
use crate::pack::{NavMesh, v3};

const CELL: f32 = 8.0;

struct Poly {
    vertices: Vec<Vec3>,
    center: Vec3,
    /// (neighbour, portal end, portal end)
    links: Vec<(u32, Vec3, Vec3)>,
    min: (f32, f32),
    max: (f32, f32),
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
    #[must_use]
    pub fn new(mesh: &NavMesh) -> Self {
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
                }
            })
            .collect();
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
        Self { polys, grid }
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
        let start = self.locate(from, 2.5)?;
        let goal = self.locate(to, 2.5)?;
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
