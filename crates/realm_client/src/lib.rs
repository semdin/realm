//! Rust side of the Godot client. Phase 0 exposes `RealmInfo` so the smoke
//! project can prove the extension loads in the pinned Godot version.

// The GDExtension entry point is an `unsafe impl` by design of the bindings.
#![allow(unsafe_code)]

use godot::prelude::*;

struct RealmExtension;

#[gdextension]
unsafe impl ExtensionLibrary for RealmExtension {}

/// Build facts the client can show or check at start-up.
#[derive(GodotClass)]
#[class(init, base = RefCounted)]
struct RealmInfo {}

#[godot_api]
impl RealmInfo {
    #[func]
    fn protocol_version() -> i64 {
        i64::from(realm_proto::PROTOCOL_VERSION)
    }

    #[func]
    fn sim_hz() -> i64 {
        i64::from(realm_sim::SIM_HZ)
    }
}
