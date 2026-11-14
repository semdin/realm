//! Dungeon gates: portcullises a run opens and closes. The server schedules
//! every change a moment ahead (a server tick) and tells the run's players
//! at once, so a client's prediction moves through, or stops at, a gate on
//! the same input tick as the server does. Closed gates are the world's
//! moving colliders (a dungeon map has no staircases).

use parry3d::math::Pose;
use parry3d::shape::SharedShape;

use crate::world::World;

/// One gate of one copy of a dungeon.
#[derive(Clone)]
pub struct Gate {
    pub id: String,
    /// The copy it belongs to (0 on a client: its own).
    pub copy: u8,
    pub pose: Pose,
    pub shape: SharedShape,
    /// (tick, open) changes, oldest first; closed before the first.
    pub changes: Vec<(u32, bool)>,
}

impl Gate {
    #[must_use]
    pub fn open_at(&self, tick: u32) -> bool {
        self.changes
            .iter()
            .rev()
            .find(|(t, _)| *t <= tick)
            .is_some_and(|(_, open)| *open)
    }
}

/// The gates of a map, and which were closed when last applied.
#[derive(Clone, Default)]
pub struct Gates {
    pub gates: Vec<Gate>,
    applied: Option<Vec<bool>>,
}

/// Changes kept per gate (older ones are long past).
const KEEP: usize = 6;

impl Gates {
    #[must_use]
    pub fn new(gates: Vec<Gate>) -> Self {
        Self {
            gates,
            applied: None,
        }
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.gates.is_empty()
    }

    /// Opens (or closes) gate `id` of `copy` from `tick` on. Returns
    /// whether such a gate exists.
    pub fn schedule(&mut self, copy: u8, id: &str, tick: u32, open: bool) -> bool {
        let Some(g) = self.gates.iter_mut().find(|g| g.copy == copy && g.id == id) else {
            return false;
        };
        g.changes.retain(|(t, _)| *t < tick);
        g.changes.push((tick, open));
        if g.changes.len() > KEEP {
            g.changes.remove(0);
        }
        self.applied = None;
        true
    }

    /// Every gate of `copy` closed again from `tick` (a copy reused).
    pub fn reset(&mut self, copy: u8) {
        for g in self.gates.iter_mut().filter(|g| g.copy == copy) {
            g.changes.clear();
        }
        self.applied = None;
    }

    /// The ground footprints (min x, min z, max x, max z) of the gates
    /// closed at `tick`, for creatures (they walk the navigation mesh, which
    /// does not know gates).
    #[must_use]
    pub fn closed_footprints(&self, tick: u32) -> Vec<[f32; 4]> {
        self.gates
            .iter()
            .filter(|g| !g.open_at(tick))
            .map(|g| {
                let b = g.shape.compute_aabb(&g.pose);
                [b.mins.x, b.mins.z, b.maxs.x, b.maxs.z]
            })
            .collect()
    }

    /// Makes the world's moving colliders the gates closed at `tick`.
    pub fn apply(&mut self, world: &mut World, tick: u32) {
        let closed: Vec<bool> = self.gates.iter().map(|g| !g.open_at(tick)).collect();
        if self.applied.as_ref() == Some(&closed) {
            return;
        }
        let colliders: Vec<(Pose, SharedShape)> = self
            .gates
            .iter()
            .zip(&closed)
            .filter(|(_, c)| **c)
            .map(|(g, _)| (g.pose, g.shape.clone()))
            .collect();
        world.set_moving(&colliders);
        self.applied = Some(closed);
    }
}
