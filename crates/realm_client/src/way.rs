//! Way-finding for the view (slice 5.14): the walkable path from the player
//! to a point on the loaded map's navigation mesh, the walkable point nearest
//! any point, and the map's painted sheet that the minimap and the world map
//! draw. Presentation only: the server never asks for any of it, and nothing
//! here changes what the player may do.
//!
//! Every position in and out is in world coordinates: inside a dungeon copy
//! the map's own coordinates are shifted by the copy's offset, which is taken
//! off on the way in and put back on the way out.

use std::collections::HashMap;
use std::sync::mpsc::{Receiver, TryRecvError, channel};
use std::time::Instant;

use godot::classes::Image;
use godot::classes::image::Format;
use godot::prelude::*;
use realm_sim::Vec3;
use realm_sim::nav::{NavQuery, NavScratch};
use realm_sim::pack::{ColliderMesh, HOLE, MapPack, NavMesh, TerrainGrid};

use crate::RealmSession;

/// Grid cell of the walkable-point index (metres).
const CELL: f32 = 8.0;
/// Polygons a path search may open (a walk across the whole grounds opens a
/// few thousand).
const MAX_NODES: usize = 60_000;
/// How far the nearest-walkable search looks (cells out from the point).
const NEAREST_RINGS: i32 = 48;
/// A metre of height difference counts this much against a candidate in the
/// nearest-walkable search (one storey up loses to a floor a few metres off).
const HEIGHT_WEIGHT: f32 = 0.6;
/// The longest side of a sheet, in pixels.
const MAX_SHEET_PX: i64 = 4096;

/// What the way-finding keeps for the loaded map, built on first use and
/// again when another map's pack was loaded.
#[derive(Default)]
pub(crate) struct WayCache {
    /// The pack it was built from (map name, walkable polygon count).
    key: Option<(String, usize)>,
    query: Option<NavQuery>,
    scratch: NavScratch,
    index: Option<NavIndex>,
    /// Sheets being painted on worker threads, by job.
    jobs: HashMap<i64, Receiver<Painted>>,
    next_job: i64,
    last_ms: f64,
}

/// A finished sheet: its size, its pixels with every mipmap level after
/// them (RGBA8), and how long the painting took.
struct Painted {
    w: usize,
    h: usize,
    data: Vec<u8>,
    ms: f64,
}

impl WayCache {
    fn prepare(&mut self, pack: &MapPack) {
        let key = (pack.map.clone(), pack.nav.polygons.len());
        if self.key.as_ref() != Some(&key) {
            self.key = Some(key);
            self.query = None;
            self.index = None;
        }
    }

    fn query(&mut self, pack: &MapPack) -> (&NavQuery, &mut NavScratch, &NavIndex) {
        self.prepare(pack);
        let query = self.query.get_or_insert_with(|| NavQuery::new(&pack.nav));
        let index = self.index.get_or_insert_with(|| NavIndex::new(&pack.nav));
        (query, &mut self.scratch, index)
    }
}

/// The walkable polygons by grid cell, for the nearest walkable point and the
/// ground height on a polygon.
struct NavIndex {
    polys: Vec<NavPoly>,
    grid: HashMap<(i32, i32), Vec<u32>>,
}

struct NavPoly {
    vertices: Vec<Vec3>,
}

fn cell_of(x: f32, z: f32) -> (i32, i32) {
    ((x / CELL).floor() as i32, (z / CELL).floor() as i32)
}

impl NavIndex {
    fn new(mesh: &NavMesh) -> Self {
        let mut polys = Vec::with_capacity(mesh.polygons.len());
        let mut grid: HashMap<(i32, i32), Vec<u32>> = HashMap::new();
        for (i, ids) in mesh.polygons.iter().enumerate() {
            let vertices: Vec<Vec3> = ids
                .iter()
                .map(|&k| {
                    let v = mesh.vertices[k as usize];
                    Vec3::new(v[0], v[1], v[2])
                })
                .collect();
            let (mut lo, mut hi) = ((f32::MAX, f32::MAX), (f32::MIN, f32::MIN));
            for v in &vertices {
                lo = (lo.0.min(v.x), lo.1.min(v.z));
                hi = (hi.0.max(v.x), hi.1.max(v.z));
            }
            let (a, b) = (cell_of(lo.0, lo.1), cell_of(hi.0, hi.1));
            for cx in a.0..=b.0 {
                for cz in a.1..=b.1 {
                    grid.entry((cx, cz)).or_default().push(i as u32);
                }
            }
            polys.push(NavPoly { vertices });
        }
        Self { polys, grid }
    }

    /// The walkable point nearest `p`: nearest on the ground plane, a height
    /// difference weighing in (HEIGHT_WEIGHT), so a click on a storey lands
    /// on that storey. None when nothing is walkable within reach.
    fn nearest(&self, p: Vec3) -> Option<Vec3> {
        let (cx, cz) = cell_of(p.x, p.z);
        let mut best: Option<(f32, Vec3)> = None;
        for ring in 0..=NEAREST_RINGS {
            if let Some((score, _)) = best {
                let reach = (ring as f32 - 1.0).max(0.0) * CELL;
                if reach * reach > score {
                    break;
                }
            }
            for dx in -ring..=ring {
                for dz in -ring..=ring {
                    if dx.abs() != ring && dz.abs() != ring {
                        continue;
                    }
                    let Some(list) = self.grid.get(&(cx + dx, cz + dz)) else {
                        continue;
                    };
                    for &i in list {
                        let q = closest_on(&self.polys[i as usize].vertices, p);
                        let (fx, fz, fy) = (q.x - p.x, q.z - p.z, (q.y - p.y) * HEIGHT_WEIGHT);
                        let score = fx * fx + fz * fz + fy * fy;
                        if best.is_none_or(|(b, _)| score < b) {
                            best = Some((score, q));
                        }
                    }
                }
            }
        }
        best.map(|(_, q)| q)
    }

    /// Whether `p` stands on a polygon (within `max_dy` of its surface).
    fn on_mesh(&self, p: Vec3, max_dy: f32) -> bool {
        let Some(list) = self.grid.get(&cell_of(p.x, p.z)) else {
            return false;
        };
        list.iter().any(|&i| {
            let v = &self.polys[i as usize].vertices;
            inside_xz(v, p) && (surface_y(v, p.x, p.z) - p.y).abs() <= max_dy
        })
    }
}

fn cross_xz(a: Vec3, b: Vec3, p: Vec3) -> f32 {
    (b.x - a.x) * (p.z - a.z) - (b.z - a.z) * (p.x - a.x)
}

/// Inside a convex polygon on the ground plane (either winding).
fn inside_xz(v: &[Vec3], p: Vec3) -> bool {
    let mut sign = 0.0_f32;
    for k in 0..v.len() {
        let c = cross_xz(v[k], v[(k + 1) % v.len()], p);
        if c.abs() < 1e-6 {
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

/// The polygon's surface height at (x, z): the fan triangle under the point,
/// interpolated; the mean height when the point is off every triangle.
fn surface_y(v: &[Vec3], x: f32, z: f32) -> f32 {
    for k in 1..v.len().saturating_sub(1) {
        if let Some(y) = triangle_y(v[0], v[k], v[k + 1], x, z) {
            return y;
        }
    }
    v.iter().map(|p| p.y).sum::<f32>() / v.len().max(1) as f32
}

fn triangle_y(a: Vec3, b: Vec3, c: Vec3, x: f32, z: f32) -> Option<f32> {
    let d = (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z);
    if d.abs() < 1e-9 {
        return None;
    }
    let wa = ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / d;
    let wb = ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / d;
    let wc = 1.0 - wa - wb;
    let eps = -1e-4;
    (wa >= eps && wb >= eps && wc >= eps).then_some(wa * a.y + wb * b.y + wc * c.y)
}

/// The point of a convex polygon nearest `p` on the ground plane, on its
/// surface.
fn closest_on(v: &[Vec3], p: Vec3) -> Vec3 {
    if inside_xz(v, p) {
        return Vec3::new(p.x, surface_y(v, p.x, p.z), p.z);
    }
    let mut best = (f32::MAX, v[0]);
    for k in 0..v.len() {
        let (a, b) = (v[k], v[(k + 1) % v.len()]);
        let (ex, ez) = (b.x - a.x, b.z - a.z);
        let len2 = ex * ex + ez * ez;
        let t = if len2 < 1e-9 {
            0.0
        } else {
            (((p.x - a.x) * ex + (p.z - a.z) * ez) / len2).clamp(0.0, 1.0)
        };
        let q = a + (b - a) * t;
        let d = (q.x - p.x) * (q.x - p.x) + (q.z - p.z) * (q.z - p.z);
        if d < best.0 {
            best = (d, q);
        }
    }
    best.1
}

fn v3(v: Vector3) -> Vec3 {
    Vec3::new(v.x, v.y, v.z)
}

fn gv(v: Vec3) -> Vector3 {
    Vector3::new(v.x, v.y, v.z)
}

#[godot_api(secondary)]
impl RealmSession {
    /// The walkable path from where the player stands to `target` (world
    /// coordinates, both ends set onto the map's walkable mesh): the
    /// player's position first, then each corner, the last the walkable
    /// point nearest the target. Empty before the join, on a map without a
    /// walkable mesh, or when no walkable way connects the two.
    #[func]
    fn path_to(&mut self, target: Vector3) -> PackedVector3Array {
        let mut out = PackedVector3Array::new();
        let offset = self.way_offset();
        let (Some(pack), Some(core)) = (self.pack.as_ref(), self.core.as_ref()) else {
            return out;
        };
        let Some(me) = core.body().map(|b| b.pos) else {
            return out;
        };
        let (query, scratch, index) = self.way.query(pack);
        let local_me = me - offset;
        let from = if index.on_mesh(local_me, 2.0) {
            Some(local_me)
        } else {
            index.nearest(local_me)
        };
        let (Some(from), Some(to)) = (from, index.nearest(v3(target) - offset)) else {
            return out;
        };
        let Some(corners) = query.path(from, to, MAX_NODES, scratch) else {
            return out;
        };
        out.push(gv(me));
        if (from - local_me).length() > 0.3 {
            out.push(gv(from + offset));
        }
        for c in corners {
            out.push(gv(c + offset));
        }
        out
    }

    /// The walkable point nearest `at` (world coordinates; nearest on the
    /// ground plane, a storey's height counting against it), or `at` itself
    /// when the map has no walkable mesh near it.
    #[func]
    fn nav_point(&mut self, at: Vector3) -> Vector3 {
        let offset = self.way_offset();
        let Some(pack) = self.pack.as_ref() else {
            return at;
        };
        let (_, _, index) = self.way.query(pack);
        index
            .nearest(v3(at) - offset)
            .map_or(at, |p| gv(p + offset))
    }

    /// The map's extent on the ground plane (x, z; world coordinates): its
    /// terrain and its walkable mesh. Empty before the map pack is loaded.
    #[func]
    fn map_bounds(&self) -> Rect2 {
        let Some(pack) = self.pack.as_ref() else {
            return Rect2::default();
        };
        let offset = self.way_offset();
        let (mut lo, mut hi) = ((f32::MAX, f32::MAX), (f32::MIN, f32::MIN));
        for g in &pack.terrain {
            lo = (lo.0.min(g.min_x), lo.1.min(g.min_z));
            hi = (
                hi.0.max(g.min_x + (g.cols.max(1) - 1) as f32 * g.spacing_x),
                hi.1.max(g.min_z + (g.rows.max(1) - 1) as f32 * g.spacing_z),
            );
        }
        for v in &pack.nav.vertices {
            lo = (lo.0.min(v[0]), lo.1.min(v[2]));
            hi = (hi.0.max(v[0]), hi.1.max(v[2]));
        }
        if lo.0 > hi.0 {
            return Rect2::default();
        }
        Rect2::new(
            Vector2::new(lo.0 + offset.x, lo.1 + offset.z),
            Vector2::new(hi.0 - lo.0, hi.1 - lo.1),
        )
    }

    /// Starts painting the map as a sheet on a worker thread (the grounds'
    /// sheet takes longer than a frame); `map_image_take` hands it over.
    /// RGBA8 with its mipmaps, `px` wide; world `rect` on the ground plane,
    /// x right and z down:
    ///
    ///   * "terrain": the old world map's painting - hill shading, the
    ///     ground tinted by height (meadow, rock, snow), water by depth with
    ///     its shoreline, 20 m contours, a parchment wash - and the roofs of
    ///     every building and wall seen from above;
    ///   * "plan": a storey's floor plan in ink on parchment - the walkable
    ///     floor between `y_lo` (the storey's floor) and `y_hi` (the next
    ///     one's), its edges inked, and every wall and pillar standing in it;
    ///   * "cave": dark rock, the walkable floors between `y_lo` and `y_hi`
    ///     shaded by depth (the upper floors warm, the lower ones cold).
    ///
    /// Returns the job (0 before the map pack is loaded).
    #[func]
    fn map_image_start(
        &mut self,
        rect: Rect2,
        px: i64,
        y_lo: f64,
        y_hi: f64,
        style: GString,
    ) -> i64 {
        let offset = self.way_offset();
        let Some(pack) = self.pack.as_ref() else {
            return 0;
        };
        let w = px.clamp(16, MAX_SHEET_PX) as usize;
        let h = ((rect.size.y / rect.size.x.max(0.001)) * w as f32)
            .round()
            .clamp(16.0, MAX_SHEET_PX as f32) as usize;
        let sheet = Sheet {
            x0: rect.position.x - offset.x,
            z0: rect.position.y - offset.z,
            mpp: rect.size.x / w as f32,
            w,
            h,
        };
        let (lo, hi) = (y_lo as f32 - offset.y, y_hi as f32 - offset.y);
        let style = style.to_string();
        // the thread paints from its own copy of what the style needs
        let (terrain, nav, colliders) = match style.as_str() {
            "plan" => (false, true, true),
            "cave" => (true, true, false),
            _ => (true, false, true),
        };
        let part = MapPack {
            version: pack.version,
            map: pack.map.clone(),
            flight_ceiling_y: pack.flight_ceiling_y,
            flight_max_above_ground: pack.flight_max_above_ground,
            terrain: if terrain {
                pack.terrain.clone()
            } else {
                Vec::new()
            },
            water: pack.water.clone(),
            colliders: if colliders {
                pack.colliders.clone()
            } else {
                Vec::new()
            },
            // trees and spires are not painted as walls on the map sheet
            obstacles: Vec::new(),
            dynamic: Vec::new(),
            nav: if nav {
                pack.nav.clone()
            } else {
                NavMesh::default()
            },
            staircases: Vec::new(),
        };
        let (send, receive) = channel();
        std::thread::spawn(move || {
            let started = Instant::now();
            let meshes = part.collider_meshes();
            let rgba = match style.as_str() {
                "plan" => paint_plan(&part, &meshes, &sheet, lo, hi),
                "cave" => paint_cave(&part, &sheet, lo, hi),
                _ => paint_terrain(&part, &meshes, &sheet),
            };
            let data = with_mipmaps(rgba, sheet.w, sheet.h);
            let ms = started.elapsed().as_secs_f64() * 1000.0;
            // the receiver is gone when the session closed meanwhile
            let _ = send.send(Painted {
                w: sheet.w,
                h: sheet.h,
                data,
                ms,
            });
        });
        self.way.next_job += 1;
        let job = self.way.next_job;
        self.way.jobs.insert(job, receive);
        job
    }

    /// The sheet of `job` (with its mipmaps) once its thread finished, else
    /// None; a job is handed over once.
    #[func]
    fn map_image_take(&mut self, job: i64) -> Option<Gd<Image>> {
        let painted = match self.way.jobs.get(&job)?.try_recv() {
            Ok(p) => p,
            Err(TryRecvError::Empty) => return None,
            Err(TryRecvError::Disconnected) => {
                self.way.jobs.remove(&job);
                return None;
            }
        };
        self.way.jobs.remove(&job);
        self.way.last_ms = painted.ms;
        Image::create_from_data(
            painted.w as i32,
            painted.h as i32,
            true,
            Format::RGBA8,
            &PackedByteArray::from(painted.data),
        )
    }

    /// Whether `job` is still being painted (false once taken or failed).
    #[func]
    fn map_image_pending(&self, job: i64) -> bool {
        self.way.jobs.contains_key(&job)
    }

    /// How long the last sheet handed over took to paint (ms, on its
    /// thread).
    #[func]
    fn map_image_ms(&self) -> f64 {
        self.way.last_ms
    }
}

impl RealmSession {
    fn way_offset(&self) -> Vec3 {
        let o = realm_rules::dungeons::copy_offset(self.copy);
        Vec3::new(o[0], o[1], o[2])
    }
}

// ------------------------------------------------------------------ sheets

/// A sheet's pixels on the map: the map point at pixel (i, j) is
/// (x0 + (i + 0.5) mpp, z0 + (j + 0.5) mpp).
struct Sheet {
    x0: f32,
    z0: f32,
    mpp: f32,
    w: usize,
    h: usize,
}

impl Sheet {
    fn at(&self, i: usize, j: usize) -> (f32, f32) {
        (
            self.x0 + (i as f32 + 0.5) * self.mpp,
            self.z0 + (j as f32 + 0.5) * self.mpp,
        )
    }

    fn to_px(&self, x: f32, z: f32) -> (f32, f32) {
        ((x - self.x0) / self.mpp, (z - self.z0) / self.mpp)
    }

    /// Rows split over the machine's cores: `f(first_row, rows)` fills its
    /// band of `out` (rows of `w * stride`).
    fn rows<T: Send>(&self, out: &mut [T], stride: usize, f: impl Fn(usize, &mut [T]) + Sync) {
        let threads = std::thread::available_parallelism().map_or(4, |n| n.get().clamp(1, 16));
        let per = self.h.div_ceil(threads).max(1);
        std::thread::scope(|s| {
            for (k, band) in out.chunks_mut(per * self.w * stride).enumerate() {
                let f = &f;
                s.spawn(move || f(k * per, band));
            }
        });
    }
}

/// Terrain height at (x, z) on the map, bilinear; NaN outside every grid and
/// over a hole.
fn terrain_height(grids: &[TerrainGrid], x: f32, z: f32) -> f32 {
    for g in grids {
        let fx = (x - g.min_x) / g.spacing_x;
        let fz = (z - g.min_z) / g.spacing_z;
        let (cols, rows) = (g.cols as usize, g.rows as usize);
        if fx < 0.0 || fz < 0.0 || fx > (cols - 1) as f32 || fz > (rows - 1) as f32 {
            continue;
        }
        let (c0, r0) = (fx.floor() as usize, fz.floor() as usize);
        let (c1, r1) = ((c0 + 1).min(cols - 1), (r0 + 1).min(rows - 1));
        let (tx, tz) = (fx - c0 as f32, fz - r0 as f32);
        let s = |r: usize, c: usize| g.heights[r * cols + c];
        let q = [s(r0, c0), s(r0, c1), s(r1, c0), s(r1, c1)];
        if q.contains(&HOLE) {
            return f32::NAN;
        }
        let q = q.map(|v| v as f32 / realm_sim::WIRE_GRID);
        let top = q[0] + (q[1] - q[0]) * tx;
        let bottom = q[2] + (q[3] - q[2]) * tx;
        return top + (bottom - top) * tz;
    }
    f32::NAN
}

/// Smooth value noise in 0..1 (stable in map metres: the same ground looks
/// the same on every sheet).
fn value_noise(x: f32, z: f32, seed: u32) -> f32 {
    fn hash(ix: i32, iz: i32, seed: u32) -> f32 {
        let mut h = (ix as u32).wrapping_mul(0x8da6_b343)
            ^ (iz as u32).wrapping_mul(0xd816_3841)
            ^ seed.wrapping_mul(0xcb1a_b31f);
        h ^= h >> 13;
        h = h.wrapping_mul(0x5bd1_e995);
        h ^= h >> 15;
        (h & 0x00ff_ffff) as f32 / 16_777_216.0
    }
    let (fx, fz) = (x.floor(), z.floor());
    let (ix, iz) = (fx as i32, fz as i32);
    let (tx, tz) = (x - fx, z - fz);
    let (sx, sz) = (tx * tx * (3.0 - 2.0 * tx), tz * tz * (3.0 - 2.0 * tz));
    let a = hash(ix, iz, seed);
    let b = hash(ix + 1, iz, seed);
    let c = hash(ix, iz + 1, seed);
    let d = hash(ix + 1, iz + 1, seed);
    let top = a + (b - a) * sx;
    let bottom = c + (d - c) * sx;
    top + (bottom - top) * sz
}

/// Fractal noise of `octaves`, the first `scale` metres across, in 0..1.
fn fbm(x: f32, z: f32, scale: f32, octaves: u32, seed: u32) -> f32 {
    let (mut acc, mut amp, mut total, mut f) = (0.0, 1.0, 0.0, 1.0 / scale);
    for o in 0..octaves {
        acc += amp * value_noise(x * f, z * f, seed + o);
        total += amp;
        amp *= 0.5;
        f *= 2.0;
    }
    acc / total
}

/// Old world map's hill shading (light from the north-west, 40 degrees up,
/// slopes exaggerated 1.6 times): 0 (in shade) to 1 (lit).
fn hillshade(dhdx: f32, dhdz: f32) -> f32 {
    let (az, alt) = (315_f32.to_radians(), 40_f32.to_radians());
    let slope = std::f32::consts::FRAC_PI_2 - (dhdx.hypot(dhdz) * 1.6).atan();
    let aspect = (-dhdx).atan2(dhdz);
    (alt.sin() * slope.sin() + alt.cos() * slope.cos() * (az - aspect).cos()).clamp(0.0, 1.0)
}

type Rgb = [f32; 3];

fn mix(a: Rgb, b: Rgb, t: f32) -> Rgb {
    [
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
    ]
}

fn scale(a: Rgb, k: f32) -> Rgb {
    [a[0] * k, a[1] * k, a[2] * k]
}

fn put(out: &mut [u8], k: usize, c: Rgb) {
    out[k * 4] = c[0].clamp(0.0, 255.0) as u8;
    out[k * 4 + 1] = c[1].clamp(0.0, 255.0) as u8;
    out[k * 4 + 2] = c[2].clamp(0.0, 255.0) as u8;
    out[k * 4 + 3] = 255;
}

/// Every pixel centre inside triangle (a, b, c) (pixel coordinates; x, y
/// = height) gets `f(index, height there)`.
fn raster_triangle(
    sheet: &Sheet,
    a: (f32, f32, f32),
    b: (f32, f32, f32),
    c: (f32, f32, f32),
    mut f: impl FnMut(usize, f32),
) {
    let area = (b.0 - a.0) * (c.1 - a.1) - (b.1 - a.1) * (c.0 - a.0);
    if area.abs() < 1e-6 {
        return;
    }
    let min_x = a.0.min(b.0).min(c.0).floor().max(0.0) as usize;
    let max_x = (a.0.max(b.0).max(c.0).ceil() as isize).min(sheet.w as isize - 1);
    let min_y = a.1.min(b.1).min(c.1).floor().max(0.0) as usize;
    let max_y = (a.1.max(b.1).max(c.1).ceil() as isize).min(sheet.h as isize - 1);
    if max_x < 0 || max_y < 0 {
        return;
    }
    for j in min_y..=max_y as usize {
        let py = j as f32 + 0.5;
        for i in min_x..=max_x as usize {
            let px = i as f32 + 0.5;
            let w0 = ((b.0 - px) * (c.1 - py) - (b.1 - py) * (c.0 - px)) / area;
            let w1 = ((c.0 - px) * (a.1 - py) - (c.1 - py) * (a.0 - px)) / area;
            let w2 = 1.0 - w0 - w1;
            if w0 >= -1e-4 && w1 >= -1e-4 && w2 >= -1e-4 {
                f(j * sheet.w + i, w0 * a.2 + w1 * b.2 + w2 * c.2);
            }
        }
    }
}

/// Fills `f` for every pixel of the walkable polygons whose surface lies
/// between `lo` and `hi` (any vertex in the band).
fn raster_nav(sheet: &Sheet, mesh: &NavMesh, lo: f32, hi: f32, mut f: impl FnMut(usize, f32)) {
    for ids in &mesh.polygons {
        let v: Vec<(f32, f32, f32)> = ids
            .iter()
            .map(|&k| {
                let p = mesh.vertices[k as usize];
                let (x, y) = sheet.to_px(p[0], p[2]);
                (x, y, p[1])
            })
            .collect();
        if !v.iter().any(|p| p.2 >= lo && p.2 < hi) {
            continue;
        }
        for k in 1..v.len().saturating_sub(1) {
            raster_triangle(sheet, v[0], v[k], v[k + 1], &mut f);
        }
    }
}

/// The ground plane outline of the colliders that stand within the band
/// (`lo`..`hi` crosses their height): walls, pillars, furniture.
fn raster_standing(
    sheet: &Sheet,
    colliders: &[ColliderMesh],
    lo: f32,
    hi: f32,
    mut f: impl FnMut(usize),
) {
    for c in colliders {
        if c.max[1] < lo || c.min[1] > hi {
            continue;
        }
        let (x0, z0) = sheet.to_px(c.min[0], c.min[2]);
        let (x1, z1) = sheet.to_px(c.max[0], c.max[2]);
        if x1 < 0.0 || z1 < 0.0 || x0 > sheet.w as f32 || z0 > sheet.h as f32 {
            continue;
        }
        for t in &c.indices {
            let p = t.map(|k| {
                let v = c.vertices[k as usize];
                let (x, y) = sheet.to_px(v[0], v[2]);
                (x, y, 0.0)
            });
            raster_triangle(sheet, p[0], p[1], p[2], |k, _| f(k));
        }
    }
}

/// `rgba` (w x h) followed by each smaller level down to 1 x 1, every one a
/// box filter of the one before (Godot's mipmap layout for RGBA8).
fn with_mipmaps(rgba: Vec<u8>, w: usize, h: usize) -> Vec<u8> {
    let mut out = rgba;
    let (mut start, mut cw, mut ch) = (0_usize, w, h);
    while cw > 1 || ch > 1 {
        let (nw, nh) = ((cw / 2).max(1), (ch / 2).max(1));
        let mut level = vec![0_u8; nw * nh * 4];
        for j in 0..nh {
            for i in 0..nw {
                let (i0, j0) = ((i * 2).min(cw - 1), (j * 2).min(ch - 1));
                let (i1, j1) = ((i * 2 + 1).min(cw - 1), (j * 2 + 1).min(ch - 1));
                for c in 0..4 {
                    let at = |x: usize, y: usize| u32::from(out[start + (y * cw + x) * 4 + c]);
                    let sum = at(i0, j0) + at(i1, j0) + at(i0, j1) + at(i1, j1);
                    level[(j * nw + i) * 4 + c] = ((sum + 2) / 4) as u8;
                }
            }
        }
        start = out.len();
        out.extend_from_slice(&level);
        (cw, ch) = (nw, nh);
    }
    out
}

/// The terrain sheet (see `map_image_start`).
fn paint_terrain(pack: &MapPack, colliders: &[ColliderMesh], sheet: &Sheet) -> Vec<u8> {
    let (w, h) = (sheet.w, sheet.h);
    // heights, one per pixel and a pixel of border round them
    let (bw, bh) = (w + 2, h + 2);
    let mut ground = vec![f32::NAN; bw * bh];
    let border = Sheet {
        x0: sheet.x0 - sheet.mpp,
        z0: sheet.z0 - sheet.mpp,
        mpp: sheet.mpp,
        w: bw,
        h: bh,
    };
    border.rows(&mut ground, 1, |first, band| {
        for (k, v) in band.iter_mut().enumerate() {
            let (x, z) = border.at(k % bw, first + k / bw);
            *v = terrain_height(&pack.terrain, x, z);
        }
    });
    // roofs: the highest collider surface over each pixel (faces turned up
    // or down, not walls)
    let mut roof = vec![f32::NEG_INFINITY; w * h];
    for c in colliders {
        for t in &c.indices {
            let v = t.map(|k| c.vertices[k as usize]);
            let (e1, e2) = (
                [v[1][0] - v[0][0], v[1][1] - v[0][1], v[1][2] - v[0][2]],
                [v[2][0] - v[0][0], v[2][1] - v[0][1], v[2][2] - v[0][2]],
            );
            let n = [
                e1[1] * e2[2] - e1[2] * e2[1],
                e1[2] * e2[0] - e1[0] * e2[2],
                e1[0] * e2[1] - e1[1] * e2[0],
            ];
            let len = (n[0] * n[0] + n[1] * n[1] + n[2] * n[2]).sqrt();
            if len < 1e-9 || (n[1] / len).abs() < 0.2 {
                continue;
            }
            let p = v.map(|q| {
                let (x, y) = sheet.to_px(q[0], q[2]);
                (x, y, q[1])
            });
            raster_triangle(sheet, p[0], p[1], p[2], |k, y| {
                if y > roof[k] {
                    roof[k] = y;
                }
            });
        }
    }
    let water = &pack.water;
    let water_at = |x: f32, z: f32| -> Option<f32> {
        water
            .iter()
            .find(|q| x >= q.min_x && x <= q.max_x && z >= q.min_z && z <= q.max_z)
            .map(|q| q.surface_y)
    };
    let parch: Rgb = [226.0, 208.0, 166.0];
    let meadow: Rgb = [132.0, 146.0, 92.0];
    let rock: Rgb = [150.0, 140.0, 128.0];
    let snow: Rgb = [236.0, 232.0, 224.0];
    let shallow: Rgb = [92.0, 128.0, 150.0];
    let deep: Rgb = [58.0, 88.0, 112.0];
    let stone: Rgb = [176.0, 166.0, 150.0];
    let ink: Rgb = [70.0, 52.0, 36.0];
    let void: Rgb = [40.0, 38.0, 44.0];
    let (cx, cz) = (
        sheet.x0 + w as f32 * sheet.mpp * 0.5,
        sheet.z0 + h as f32 * sheet.mpp * 0.5,
    );
    let half = (w.max(h) as f32 * sheet.mpp * 0.5).max(1.0);
    let step = 2.0 * sheet.mpp;
    let mut out = vec![0_u8; w * h * 4];
    sheet.rows(&mut out, 4, |first, band| {
        for k in 0..band.len() / 4 {
            let (i, j) = (k % w, first + k / w);
            let g = |di: isize, dj: isize| {
                ground[(j as isize + 1 + dj) as usize * bw + (i as isize + 1 + di) as usize]
            };
            let hc = g(0, 0);
            let (x, z) = sheet.at(i, j);
            if hc.is_nan() {
                put(band, k, void);
                continue;
            }
            let pick = |a: f32| if a.is_nan() { hc } else { a };
            let dhdx = (pick(g(1, 0)) - pick(g(-1, 0))) / step;
            let dhdz = (pick(g(0, 1)) - pick(g(0, -1))) / step;
            let hs = hillshade(dhdx, dhdz);
            let mut col = scale(meadow, 0.88 + 0.24 * fbm(x, z, 340.0, 4, 5));
            col = mix(col, rock, ((hc - 95.0) / 50.0).clamp(0.0, 1.0));
            col = mix(col, snow, ((hc - 140.0) / 20.0).clamp(0.0, 1.0));
            let surface = water_at(x, z);
            let wet = surface.is_some_and(|s| hc < s - 0.2);
            if wet {
                let depth = ((surface.unwrap_or(0.0) - hc) / 12.0).clamp(0.0, 1.0);
                col = scale(mix(shallow, deep, depth), 0.92 + 0.1 * hs);
                // the shoreline: a darker rim where the next pixel is dry
                let s = surface.unwrap_or(0.0);
                if [g(1, 0), g(-1, 0), g(0, 1), g(0, -1)]
                    .iter()
                    .any(|n| !n.is_nan() && *n >= s - 0.2)
                {
                    col = mix(col, [40.0, 60.0, 80.0], 0.5);
                }
            } else {
                col = scale(col, 0.55 + 0.6 * hs);
                // contours every 20 m above the low ground
                let band_m = 0.45 * sheet.mpp.max(0.5);
                let m = hc.rem_euclid(20.0);
                if hc > 30.0 && (m < band_m || m > 20.0 - band_m) {
                    col = scale(col, 0.88);
                }
            }
            // roofs over the ground: stone, shaded by their own slopes, inked
            // where they meet the ground or a wall drops
            let r = roof[j * w + i];
            if r > hc + 0.6 && !(wet && r < surface.unwrap_or(0.0) + 0.3) {
                let rr = |di: isize, dj: isize| {
                    let (a, b) = (i as isize + di, j as isize + dj);
                    if a < 0 || b < 0 || a >= w as isize || b >= h as isize {
                        r
                    } else {
                        roof[b as usize * w + a as usize]
                    }
                };
                let near = [rr(1, 0), rr(-1, 0), rr(0, 1), rr(0, -1)];
                let edge = near.iter().any(|n| *n < r - 1.2);
                let rx = (near[0].max(r - 3.0) - near[1].max(r - 3.0)) / step;
                let rz = (near[2].max(r - 3.0) - near[3].max(r - 3.0)) / step;
                let lift = ((r - hc) / 25.0).clamp(0.0, 1.0);
                col = scale(
                    stone,
                    (0.62 + 0.5 * hillshade(rx, rz)) * (0.92 + 0.12 * lift),
                );
                if edge {
                    col = mix(col, ink, 0.7);
                }
            }
            // the parchment wash and the sheet's vignette
            col = mix(col, parch, 0.12);
            let rdist = ((x - cx).hypot(z - cz) / half - 0.85) * 0.9;
            col = scale(col, (1.0 - rdist).clamp(0.55, 1.0));
            put(band, k, col);
        }
    });
    out
}

/// The floor plan sheet (see `map_image_start`).
fn paint_plan(
    pack: &MapPack,
    colliders: &[ColliderMesh],
    sheet: &Sheet,
    lo: f32,
    hi: f32,
) -> Vec<u8> {
    let (w, h) = (sheet.w, sheet.h);
    let mut floor = vec![false; w * h];
    raster_nav(sheet, &pack.nav, lo - 0.6, hi - 0.6, |k, _| floor[k] = true);
    let mut wall = vec![false; w * h];
    raster_standing(sheet, colliders, lo + 1.0, lo + 1.8, |k| wall[k] = true);
    let parchment: Rgb = [227.0, 207.0, 163.0];
    let fill: Rgb = [242.0, 224.0, 184.0];
    let ink: Rgb = [74.0, 46.0, 23.0];
    // the ink line round the floor is about 0.35 m wide, at least a pixel
    let reach = (0.35 / sheet.mpp).round().max(1.0) as isize;
    let mut out = vec![0_u8; w * h * 4];
    sheet.rows(&mut out, 4, |first, band| {
        for k in 0..band.len() / 4 {
            let (i, j) = (k % w, first + k / w);
            let (x, z) = sheet.at(i, j);
            let at = j * w + i;
            // foxing: soft brown blotches so the sheet is not flat
            let fox = fbm(x, z, 28.0, 3, 11);
            let mut col = scale(parchment, 0.94 + 0.08 * fox);
            if floor[at] {
                col = scale(fill, 0.96 + 0.05 * fbm(x, z, 6.0, 2, 3));
            }
            let mut edge = false;
            'near: for dj in -reach..=reach {
                for di in -reach..=reach {
                    let (a, b) = (i as isize + di, j as isize + dj);
                    if a < 0 || b < 0 || a >= w as isize || b >= h as isize {
                        continue;
                    }
                    if floor[b as usize * w + a as usize] != floor[at] {
                        edge = true;
                        break 'near;
                    }
                }
            }
            if wall[at] {
                col = mix(col, ink, 0.78);
            } else if edge {
                col = mix(col, ink, if floor[at] { 0.85 } else { 0.55 });
            }
            put(band, k, col);
        }
    });
    out
}

/// The cave sheet (see `map_image_start`).
fn paint_cave(pack: &MapPack, sheet: &Sheet, lo: f32, hi: f32) -> Vec<u8> {
    let (w, h) = (sheet.w, sheet.h);
    let mut floor_y = vec![f32::NAN; w * h];
    raster_nav(sheet, &pack.nav, lo, hi, |k, y| {
        if floor_y[k].is_nan() || y > floor_y[k] {
            floor_y[k] = y;
        }
    });
    // the floors' heights: the walkable mesh's 10th and 90th percentiles
    // (a few ledges and ramps reach well above or below the floors)
    let mut heights: Vec<f32> = pack
        .nav
        .vertices
        .iter()
        .map(|v| v[1])
        .filter(|y| *y >= lo && *y < hi)
        .collect();
    heights.sort_by(f32::total_cmp);
    let quantile = |q: f32| {
        heights
            .get(((heights.len().max(1) - 1) as f32 * q) as usize)
            .copied()
            .unwrap_or(0.0)
    };
    let (ny0, ny1) = (quantile(0.1), quantile(0.9));
    let span = (ny1 - ny0).max(1.0);
    let warm: Rgb = [133.0, 120.0, 102.0];
    let cold: Rgb = [84.0, 107.0, 92.0];
    let rock_lo: Rgb = [18.0, 17.0, 18.0];
    let rock_hi: Rgb = [41.0, 38.0, 41.0];
    let step = 2.0 * sheet.mpp;
    let mut out = vec![0_u8; w * h * 4];
    sheet.rows(&mut out, 4, |first, band| {
        for k in 0..band.len() / 4 {
            let (i, j) = (k % w, first + k / w);
            let (x, z) = sheet.at(i, j);
            let t = |a: f32, b: f32| terrain_height(&pack.terrain, a, b);
            let hc = t(x, z);
            let at = j * w + i;
            let fy = floor_y[at];
            let (dhdx, dhdz) = if hc.is_nan() {
                (0.0, 0.0)
            } else {
                let pick = |a: f32| if a.is_nan() { hc } else { a };
                (
                    (pick(t(x + sheet.mpp, z)) - pick(t(x - sheet.mpp, z))) / step,
                    (pick(t(x, z + sheet.mpp)) - pick(t(x, z - sheet.mpp))) / step,
                )
            };
            let hs = hillshade(dhdx, dhdz);
            let col = if fy.is_nan() {
                let lift = if hc.is_nan() {
                    0.0
                } else {
                    ((hc - ny0) / (span + 30.0)).clamp(0.0, 1.0)
                };
                scale(
                    mix(rock_lo, rock_hi, lift),
                    0.8 + 0.4 * fbm(x, z, 9.0, 2, 7),
                )
            } else {
                let d = ((fy - ny0) / span).clamp(0.0, 1.0);
                let shade = (0.55 + 0.8 * hs).clamp(0.55, 1.35);
                let mut c = scale(
                    mix(cold, warm, d),
                    shade * (0.9 + 0.2 * fbm(x, z, 5.0, 2, 9)),
                );
                // the floor's rim: darker where the next pixel is rock
                let rim =
                    [(1, 0), (-1, 0), (0, 1), (0, -1)]
                        .iter()
                        .any(|(di, dj): &(isize, isize)| {
                            let (a, b) = (i as isize + di, j as isize + dj);
                            a >= 0
                                && b >= 0
                                && a < w as isize
                                && b < h as isize
                                && floor_y[b as usize * w + a as usize].is_nan()
                        });
                if rim {
                    c = scale(c, 0.55);
                }
                c
            };
            put(band, k, col);
        }
    });
    out
}
