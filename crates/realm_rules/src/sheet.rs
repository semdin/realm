//! The character record. One struct is what the store saves, what travels to
//! the owner, and what the server's systems change; there is no second copy
//! of a character anywhere.

use serde::{Deserialize, Serialize};

/// Bag cells.
pub const BAG_SLOTS: usize = 40;
/// Largest stack in one cell.
pub const MAX_STACK: u32 = 9999;

/// Equipment slots, in wire and save order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum Slot {
    Head,
    Chest,
    Hands,
    Feet,
    MainHand,
    OffHand,
    Neck,
    RingLeft,
    RingRight,
    Broom,
}

impl Slot {
    pub const ALL: [Self; 10] = [
        Self::Head,
        Self::Chest,
        Self::Hands,
        Self::Feet,
        Self::MainHand,
        Self::OffHand,
        Self::Neck,
        Self::RingLeft,
        Self::RingRight,
        Self::Broom,
    ];

    /// The content's name (`items.json` `slots`).
    #[must_use]
    pub fn name(self) -> &'static str {
        match self {
            Self::Head => "head",
            Self::Chest => "chest",
            Self::Hands => "hands",
            Self::Feet => "feet",
            Self::MainHand => "main_hand",
            Self::OffHand => "off_hand",
            Self::Neck => "neck",
            Self::RingLeft => "ring_left",
            Self::RingRight => "ring_right",
            Self::Broom => "broom",
        }
    }

    #[must_use]
    pub fn parse(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|s| s.name() == name)
    }
}

/// One bonus line on an item instance (an enchantment).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Bonus {
    pub stat: String,
    pub value: f32,
}

/// A stack (`uid` 0) or an item instance (its own `uid`, amount 1).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Item {
    pub id: String,
    pub amount: u32,
    /// Refinement +0..+9.
    pub tier: u8,
    pub uid: u64,
    pub bonuses: Vec<Bonus>,
}

/// Where a character stands when it is saved.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Place {
    pub map: String,
    pub pos: [f32; 3],
    pub yaw: f32,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct CharacterSheet {
    pub id: u64,
    pub name: String,
    pub house: String,
    pub level: u16,
    pub exp: u64,
    pub hp: u32,
    pub mana: u32,
    pub base_max_hp: u32,
    pub base_max_mana: u32,
    pub oril: u64,
    /// `BAG_SLOTS` cells.
    pub bag: Vec<Option<Item>>,
    /// One cell per `Slot`, in `Slot::ALL` order.
    pub equipment: Vec<Option<Item>>,
    /// Appearance (looks.json keys -> palette index or slider value).
    pub look: Vec<(String, f32)>,
    /// None until the character first enters a map.
    pub place: Option<Place>,
    /// Bumped by every change; a save older than the stored one is refused.
    pub revision: u64,
}

impl CharacterSheet {
    #[must_use]
    pub fn equipped(&self, slot: Slot) -> Option<&Item> {
        self.equipment.get(slot as usize).and_then(Option::as_ref)
    }

    /// Repairs a loaded sheet's shape (cell counts) so systems can index it.
    pub fn normalize(&mut self) {
        self.bag.resize(BAG_SLOTS, None);
        self.equipment.resize(Slot::ALL.len(), None);
    }
}
