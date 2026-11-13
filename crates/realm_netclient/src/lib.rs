//! The game client's logic, independent of the engine that draws it: the
//! Godot extension, the network checks and future tools all use this crate.

pub mod core;
pub mod net;

pub use core::{ClientCore, ClientStats, RemoteEntity};
pub use net::{NetEvent, NetHandle};
