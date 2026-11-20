extends Node3D

## The realm client's first view. Everything that happens comes from the
## RealmSession extension node (Rust): this script reads the controls, hands
## them over, and draws what the session reports. Players are the real hero
## (HeroView); the map is still grey collision geometry and creatures are
## capsules until their scenes move over.
##
##   godot --path game -- [--server 127.0.0.1:7777] [--map grounds]
##   godot --headless --path game -- --check 20     joins, walks, prints, quits
##   [--cam-distance 4] [--cam-side 90]              camera framing (captures)
##   [--open-bag 1]                                   start with the inventory open
##   [--character 7]                                  play this dev character (saved when the
##                                                    server runs with --characters)
##   [--check-target stone_dark]                      the check fights the nearest of this
##                                                    species (a Dark Shard, a dummy) first
##   [--check-rise town|here|auto]                    how the check rises when it falls: the
##                                                    death panel's Return to Town (default) or
##                                                    Revive Here, or waiting for the server's
##                                                    own return to town
##   [--open-character 1]                             start with the character window open
##   [--check-quests]                                 the check walks the first chapter instead
##                                                    of fighting: talks to Master Teral Venn and
##                                                    hands in q001, wears the cloak (q002), hits
##                                                    a training dummy 5 times (q003), claiming
##                                                    each; fails unless all three are claimed
##   [--check-workshop]                               the check opens Kestrin's workshop (O), puts
##                                                    the wand on the anvil, refines it, imbues and
##                                                    reweaves it (WorkshopCheck); with q012 open it
##                                                    first talks to Kestrin and opens the workshop
##                                                    from his dialogue, and claims q012 / q013
##   [--check-social]                                 the check says a local line (its bubble),
##                                                    invites the scripted partner, sees the party
##                                                    and its frame, hears the partner's party line
##                                                    and shout, and leaves (SocialCheck); with
##                                                    --check-invite-from NAME it then answers
##                                                    NAME's invitation card and opens the player
##                                                    menu on NAME
##   [--social-guest NAME]                            this client says a local line and invites
##                                                    NAME (the second client for --check-social)
##   [--check-duel]                                   the check answers a duel challenge on its
##                                                    card, opens the player menu on the
##                                                    challenger, sees the countdown, the arena and
##                                                    the plaque, Tabs to the foe and casts until
##                                                    it is out, and sees the Victory banner
##                                                    (DuelCheck)
##   [--duel-guest NAME]                              this client challenges NAME to a duel and
##                                                    stands (the second client for --check-duel)
##   [--check-travel]                                 the check walks through the castle door and
##                                                    back, takes the Hearth Pavilion's hearth to
##                                                    Orvell Square and mounts and dismounts the
##                                                    broom there (TravelCheck; it carries on across
##                                                    the scene reload a map change makes)
##   [--check-dungeon]                                the check walks to the Trial Hall gate, opens the
##                                                    gate window, enters Normal, fights through the
##                                                    copy until the run's end shows a medal on the
##                                                    notice band and the rewards in the chat, opens
##                                                    the guide (K) on its "Run it again", and leaves
##                                                    by the reward exit (DungeonCheck; the servers
##                                                    run with --dev-dungeon-scale 0.05); with
##                                                    --check-dungeon-replay (Trial server
##                                                    --dev-dungeon-start done) it presses "Run it
##                                                    again" instead and ends at the launch
##   [--check-controls]                               the basic attack held (Ctrl, the left button),
##                                                    Ctrl on the broom, the loot keys, the zoom
##                                                    limits, damage numbers, the safe-ground cue's
##                                                    silence and the place signs' fade
##                                                    (ControlsCheck; build/logs/w22_stack.sh)
##   [--check-guide]                                  the check walks to the Trial Hall gate, buys a
##                                                    Trial Hall Key in the gate window's Seal Shop
##                                                    and opens the dungeon guide with K (GuideCheck;
##                                                    the character from --dungeon-kit
##                                                    --dungeon-cleared normal --seals 20)
##   [--check-boss]                                   the check goes through the Sealed Wing gate
##                                                    (castle_interior), walks to Threehead, rings
##                                                    the sleep chime until it sleeps and kills its
##                                                    heads one by one (BossCheck; the dungeon server
##                                                    runs with --dev-dungeon-start threehead
##                                                    --dev-dungeon-scale 0.05: build/logs/dup_boss.sh)
##   [--check-boss-step snare]                        the Strangling Vine instead (dup_boss.sh snare)
##   [--check-lair]                                   the check goes through the Web Mother's Lair gate
##                                                    (spider_caverns), lets the egg sacs split open
##                                                    and clears the egg cavern (LairCheck; the
##                                                    dungeon server runs with --dev-dungeon-start
##                                                    eggs --dev-dungeon-scale 0.05 --dev-cocoon-solo:
##                                                    build/logs/aup_lair.sh)
##   [--check-lair-step queen]                        the Web Mother instead: her cocoon round the
##                                                    player, the venom pools, her fall
##                                                    (aup_lair.sh queen)
##   [--check-ops]                                    the check drives the coordinator's admin surface
##                                                    (--check-admin 127.0.0.1:8094 --check-token
##                                                    check-token): becomes a GA, types /ga rain on and
##                                                    off, sees an update notice, a maintenance
##                                                    countdown called off, a full cycle to the closed
##                                                    connection and a refused rejoin (OpsCheck;
##                                                    build/logs/aup_ops.sh)
##   [--check-login]                                  the check goes through the front door against the login
##                                                    service (build/logs/aup_login.sh): registers an account,
##                                                    sees the empty roster, creates a character in the create
##                                                    card with a house and a look, sees it on the dais, enters
##                                                    the world and finds its name, house and look on the sheet;
##                                                    a second account is refused the same name (LoginCheck)
##   [--check-menu]                                   the check opens the Esc menu (after Escape closed a window and
##                                                    dropped the target), changes the master volume, the interface
##                                                    scale and a key in Settings, sees them kept after closing and
##                                                    in user://, opens Credits, sees Change character's countdown
##                                                    cancelled by walking, then lands on the login card while the
##                                                    coordinator counts the player gone (MenuCheck;
##                                                    build/logs/aup_menu.sh, --character 900701)
##   [--check-skills]                                 the check opens the skill window with V, raises a spell
##                                                    with its "+", learns another, and sees the levels, the
##                                                    free points and the taskbar badge follow the server's
##                                                    sheet (SkillsCheck; build/logs/aup_skills.sh,
##                                                    --character 900801)
##   [--check-others]                                 the check starts a second client (--others-guest NAME,
##                                                    character 900812) beside it, sees its nameplate (name,
##                                                    level, house, title) and its look and wand, then the
##                                                    partner changes its look and takes its wand off and the
##                                                    check sees both on its body (OthersCheck;
##                                                    build/logs/aup_others.sh, --character 900811)
##   [--check-map]                                    way-finding (MapCheck; build/logs/aup_map.sh, --character
##                                                    900901): the minimap, the world map (M) with its markers, a
##                                                    click that sets a waypoint, its footprints, the walk along
##                                                    its route until it clears, the zone banner on the way, and
##                                                    the dungeon guide's "Show the way to the gate"; with
##                                                    `aup_map.sh castle` / `caverns` and `--map castle_interior` /
##                                                    `--map spider_caverns` it surveys that map instead
##   [--check-audio]                                  the sound layers (AudioCheck; build/logs/aup_audio.sh,
##                                                    --character 901001): zone music and its cross-fade on a
##                                                    zone change, the ambience bed, footsteps walking and none
##                                                    standing, creature voices and the tension mix in a fight,
##                                                    the broom's wind by speed, a hearth trip's sound; the
##                                                    audio layer's frame cost
##   [--check-hud2]                                   the HUD parity pieces (Hud2Check; build/logs/aup_hud2.sh,
##                                                    --character 901101 --capture-dir build/captures/hud2): the
##                                                    low-health edge and the pointers, every taskbar window
##                                                    button, the character window's Status and Properties, the
##                                                    bestiary (B), Ward Shield on the effects bar, a "[World]"
##                                                    news line, the protected-ground cue in and out, then the
##                                                    Trial Hall run with the target ring, the "New title" toast
##                                                    and "Run it again" into a new copy
##   [--check-stairs]                                 the castle's moving staircases drawn, swinging and climbed
##                                                    (StairsCheck; build/logs/aup_stairs.sh, --map
##                                                    castle_interior --character 901201)
##   [--check-castle]                                 the castle interior drawn where the server's floors and
##                                                    walls are: feet on the drawn floor, five fixed views
##                                                    probed and captured with their frame times, memory
##                                                    (CastleCheck; build/logs/kup_castle.sh, --map
##                                                    castle_interior --character 901301)
##   [--check-caverns] / [--check-dungeons]           the Blackweb Caverns / the dungeon map joined drawn where
##                                                    the server's ground and walls are: feet, fixed views probed
##                                                    and captured with their frame times, memory (DrawnMapCheck;
##                                                    build/logs/dup6_caverns.sh, dup6_dungeons.sh)
##   [--check-light]                                  day and night, the rain's darkening and the quality presets
##                                                    (LightCheck; build/logs/lup6_light.sh check): four pinned
##                                                    hours, "/ga rain on|off", low / medium / high picked in
##                                                    Settings > Graphics and timed; with `--map castle_interior`
##                                                    the indoor rules (no sun, the fill on the hero)
##   [--time 19:30]                                   pin the hour of the day's light (captures; DayNight)
##   [--quality=low|medium|high]                      the graphics preset for this run (QualityPreset)
##   [--shader-warmup] / [--no-shader-warmup]         warm the pipelines on a dev join too / never
##                                                    (ShaderWarmup; a trip warms behind its loading screen)
##   [--check-polish]                                the small HUD pieces (PolishCheck; build/logs/aup_polish.sh,
##                                                    --character 902101): the debug readout hidden, then shown
##                                                    by its key; the ping; the broom icon and a refused
##                                                    landing in the air; Alt+Enter; an arrow key walks
##   [--others-guest NAME]                          this client waits until it sees NAME, then changes its
##                                                    look and takes its wand off (the second client for
##                                                    --check-others)
##   [--check-play USER PASSWORD]                     the release smoke check (PlayCheck; also in an exported
##                                                    game): through the front door, logs USER in (registers
##                                                    it when unknown), picks its first character (creates one
##                                                    when there is none), enters the world, sees it joined and
##                                                    drawn, quits 0; fails fast on any refusal
##   [--login-url http://127.0.0.1:7950]              the login service the front door talks to (an exported
##                                                    game defaults to LoginApi.RELEASE_URL)
##   [--capture-dir build/captures/travel]            where TravelCheck / DungeonCheck / BossCheck / LairCheck / OpsCheck / LoginCheck / MenuCheck save PNG frames
##
## Travel (MapTravel): F at a door, a hearth, a Twinned Cabinet, a passage or
## a Waylink; Shift mounts or dismounts the broom. A trip to another map
## rebuilds this scene for it: `map_name` is then the trip's map and the
## session joins with RealmSession.start_travel (the loading screen stays up
## across the reload until the new map is drawn).
##
## Dungeons (MapDungeon): F at a door into an instanced map opens its gate
## window. Inside a dungeon copy the whole map stands at
## RealmSession.copy_offset() (the pack's meshes and every content position on
## it are shifted by it; server positions are already absolute), with the
## copy's gates and the run tracker; the run's end is a notice line and chat
## lines, its replay in the dungeon guide (K).
##
## Controls: WASD move, Space jump, Ctrl descend (on the broom), right-drag
## turns the camera, wheel zooms (CAM_NEAR to CAM_FAR). Left-click picks under
## the cursor: a creature becomes the target and takes a basic cast, anything
## else takes the basic cast at that point; held, the basic cast repeats at
## its own cadence (_tick_basic_hold). Its key (Ctrl on foot, bindable) casts
## it at the target or the cursor's point and repeats the same way while held.
## A right-click on a loot chest (within 7 m) opens it; Z (or the key under
## Escape, by its place on any layout) takes everything from the nearest chest
## within 6 m. Tab cycles the nearest living creatures, Esc
## closes a window or drops the target, I opens the bag, C the character
## window, V the skill window, J the quest log, O Kestrin's workshop
## (anywhere), K the dungeon guide; the action bar reads 1-4, Q, E, 5, 6 and
## F1-F4.
## Over every player and creature in view floats its nameplate (Nameplates):
## a player's name, level, house crest and newest title (its GA emblem over
## them), a creature's level and name in its elite / boss colours. Every
## player and creature is asked what it is (RealmSession.inspect) as it comes
## into view; a player's answer also dresses its body (HeroView.wear: look,
## house, wand, cloak, broom) and comes again unasked when any of it changes.
## The map's NPCs (npcs.json) stand on the ground under their place: F talks
## to the nearest within TALK_KEY_REACH, a click on one talks from within the
## server's talk radius (less a little), and the dialogue card, the tracker,
## the quest log and the quest scroll show the server's quest log.
## Enter opens the chat (HudChat; Enter sends, Esc lets go); a local line rises
## over its speaker's head (SpeechBubble). An invitation shows its card, the
## party its frames. A right-click on another player within HudPlayerMenu.RANGE
## opens the player menu (invite, duel, group duel), a left-click puts it on
## the target card with "Invite to Party" (a ring of light lies under the
## target: TargetRing); both need the player's name, which
## the client learns from the server's answer when the player comes into view.
## In a duel (HudDuel) a standing foe is a target like a creature: Tab takes
## it, a left-click on it casts, and spells aim at it.
## A game admin wears the GA emblem (over its head, on its unit frame and on
## the target card); the realm's rain falls on the grounds (RealmWeather). A
## maintenance shows its countdown banner (MaintenanceUI), and a closed
## connection or a refused join the end screen with Reconnect and Quit Game.
## In through the front door, a join that never got in (no answer in 10 s,
## a ticket the map no longer takes, a realm still linking: RETRY_REASONS,
## or no answer at all in JOIN_TIMEOUT) is tried again with a fresh ticket
## behind the loading screen (retry_join, JOIN_RETRIES times); then the end
## screen offers Try Again, Return to Login (the loading screen goes with
## it) and Quit Game. The join's start, outcome and time are printed.
## The check mode also fights: it targets the nearest creature, learns and casts
## Shockwave once, then the basic cast every CHECK_CAST_SECONDS (or, with
## `--check-spells stun_bolt,flame_wave,...`, those spells in turn: a capture of
## the status looks on a character that knows them). It fails when none of its
## casts hit or when its Shockwave landed on a creature that can be thrown and
## none it hit was ever seen thrown (STATUS_KNOCKED; a boss, a Dark Shard or a
## dummy never is), when a chest dropped and it did not walk to it, take
## everything (a "reward" with items) and see the chest vanish, when it had a
## status point and did not spend it, or when it fell and did not rise;
## the final line prints the status bits seen on its target, then what it saw
## of the world: creature answers (bosses with the body and scale they wear),
## the map's notices, and the Dark Shards, dummies and bosses in view.
##
## The front door (FrontDoor): started without `--character`, `--server` or a
## check that needs the dev join, the game shows the login card, then the
## character screen; Enter World takes a ticket from the login service and the
## scene is rebuilt to join the character's map like a trip
## (RealmSession.join_ticket, start_travel). The world's end screen then goes
## back to the login card (return_to_login).
##
## Paths to keys/, content/data and world/maps default to RealmPaths.root():
## the realm checkout the project sits in for a dev run, the folder beside the
## executable (macOS: the bundle's Contents/Resources) for an exported game.
## An exported game takes no dev switches (the dev join, the dev checks: their
## scripts are not exported); `--check-play` is its smoke check.

## A join through the front door that never got in is tried again this many
## times with a fresh ticket before the end screen shows (retry_join).
const JOIN_RETRIES := 2
## A join not answered in this long has failed.
const JOIN_TIMEOUT := 30.0
## Refusals of a join that can pass (the map server's and the coordinator's
## words): another try with a fresh ticket may get in.
const RETRY_REASONS := ["ticket expired", "ticket already used", "the realm is not ready; try again",
	"the realm is restarting; try again", "still travelling; try again", "character could not be loaded"]

const KIND_COLORS := [Color(0.35, 0.65, 1.0), Color(0.85, 0.3, 0.25), Color(0.9, 0.6, 0.2),
	Color(0.55, 0.8, 0.3), Color(0.7, 0.4, 0.85), Color(0.9, 0.85, 0.3)]

const HeroViewScript := "res://scripts/view/hero_view.gd"
const PlayerSheetScript := "res://scripts/view/player_sheet.gd"
const HudScript := "res://scripts/ui/hud.gd"
const InventoryScript := "res://scripts/ui/inventory_arcane.gd"
const FeedbackScript := "res://scripts/ui/combat_feedback.gd"
const LootScript := "res://scripts/ui/loot_window.gd"
const CharacterScript := "res://scripts/ui/character_window.gd"
const WorkshopScript := "res://scripts/ui/workshop_window.gd"
const WorkshopCheckScript := "res://scripts/systems/workshop_check.gd"
const SocialCheckScript := "res://scripts/systems/social_check.gd"
const DuelCheckScript := "res://scripts/systems/duel_check.gd"
const TravelCheckScript := "res://scripts/systems/travel_check.gd"
const DungeonCheckScript := "res://scripts/systems/dungeon_check.gd"
const GuideCheckScript := "res://scripts/systems/guide_check.gd"
const BossCheckScript := "res://scripts/systems/boss_check.gd"
const LairCheckScript := "res://scripts/systems/lair_check.gd"
const OpsCheckScript := "res://scripts/systems/ops_check.gd"
const LoginCheckScript := "res://scripts/systems/login_check.gd"
const PlayCheckScript := "res://scripts/systems/play_smoke.gd"
const MenuCheckScript := "res://scripts/systems/menu_check.gd"
const SkillsCheckScript := "res://scripts/systems/skills_check.gd"
const OthersCheckScript := "res://scripts/systems/others_check.gd"
const MapCheckScript := "res://scripts/systems/map_check.gd"
const AudioCheckScript := "res://scripts/systems/audio_check.gd"
const Hud2CheckScript := "res://scripts/systems/hud2_check.gd"
const StairsCheckScript := "res://scripts/systems/stairs_check.gd"
const CastleCheckScript := "res://maps/castle_interior/castle_check.gd"
const DrawnMapCheckScript := "res://maps/dng_common/drawn_map_check.gd"
const LightCheckScript := "res://scripts/systems/light_check.gd"
const PolishCheckScript := "res://scripts/systems/polish_check.gd"
const ControlsCheckScript := "res://scripts/systems/controls_check.gd"
## Under a roof the lens stays on the hero's side of the walls: it comes in at
## once and goes back out gently. The open grounds keep the free camera.
const CAM_WALL_MARGIN := 0.35
const CAM_WALL_NEAREST := 1.0
const CAM_COME_IN := 40.0
const CAM_GO_OUT := 10.0
var _cam_room := -1.0

func _camera_room(from: Vector3, offset: Vector3, delta: float) -> float:
	var want := offset.length()
	if map_name == "grounds":
		_cam_room = -1.0
		return want
	var free: float = session.line_free(from, from + offset) * want
	var target := clampf(free - CAM_WALL_MARGIN, minf(CAM_WALL_NEAREST, want), want)
	if _cam_room < 0.0:
		_cam_room = target
	_cam_room = move_toward(_cam_room, target, delta * (CAM_COME_IN if target < _cam_room else CAM_GO_OUT))
	return minf(_cam_room, want)

## Another player on the target card (the old game's colours).
const PLAYER_TINT := Color(0.62, 0.84, 1.0)
const PLAYER_BAR := Color(0.24, 0.62, 0.30)
## A standing duel foe on the target card.
const DUEL_FOE_TINT := Color(1.0, 0.56, 0.48)
const DUEL_FOE_BAR := Color(0.80, 0.12, 0.10)
const ChestViewScript := "res://scripts/view/chest_view.gd"
## Entity kind of a player in snapshots (creatures carry their species index
## + 1 in the low bits, CreatureView ELITE_BIT / ENRAGED_BIT / BOSS_BIT above).
const KIND_PLAYER := 0
## A player's snapshot state: the pose in the low four bits, and this bit while
## it rides its broom (realm_proto STATE_MOUNTED).
const STATE_POSE_MASK := 15
const STATE_MOUNTED_BIT := 16
## An elite's name on the target card (the old game's elite label colour).
const ELITE_NAME_COLOR := Color(1.0, 0.9, 0.35)
## The target card per kind of target (the old game's colours and icons):
## [tint, bar, icon].
const CARD_BOSS := [Color(1.0, 0.84, 0.36), Color(0.86, 0.10, 0.06), "ui_boss"]
const CARD_ENRAGED := [Color(1.0, 0.52, 0.26), Color(0.92, 0.32, 0.06), "status_enraged"]
const CARD_STONE := [Color(0.62, 1.0, 0.68), Color(0.20, 0.74, 0.36), "minimap_monolith"]
const CARD_DUMMY := [Color(0.78, 0.95, 0.78), Color(0.30, 0.66, 0.24), "ui_target"]
## A camera shake's swing (old SkillFX.shake_camera) and how fast it settles.
const SHAKE_SWING := 0.4
const SHAKE_SETTLE := 0.3
## Where a cast aims on a creature, above its feet (the server's chest height).
const CHEST := 1.15
## How far the cursor's pick ray reaches, and how near Tab looks for creatures.
const PICK_REACH := 200.0
const TAB_RANGE := 30.0
const CHECK_CAST_SECONDS := 0.6
## A right-click that moves the pointer less than this is a click, not a turn.
const CLICK_SLOP := 5.0
## Z takes everything from the nearest chest this close (the old pickup reach).
const PICKUP_REACH := 6.0
## The check opens a chest from this close, and shows what it holds this long
## before it takes everything.
const CHECK_LOOT_REACH := 3.5
const CHECK_LOOT_SHOW := 1.5
const HELD_NOTICE_SECONDS := 0.8
## The camera's zoom range on the wheel (metres from the head): near enough
## to see the hero's back without the lens inside its hair or cloak, far
## enough to see a pack around it, not so far that the world shrinks to a map.
const CAM_NEAR := 1.4
const CAM_FAR := 20.0
## Nearer than CAM_LOOK_BLEND the point looked at rises from the neck (1.5 m)
## to CAM_NEAR_LOOK at the near limit.
const CAM_LOOK_BLEND := 5.0
const CAM_NEAR_LOOK := 1.8
## The basic cast held (the left button after a click on the world, or its
## key): the next one is asked for this soon after the last at the least (its
## cooldown sets the cadence; this keeps a lost answer from flooding).
const BASIC_REPEAT_MIN := 0.2
const NpcViewScript := "res://scripts/view/npc_view.gd"
const QuestManagerScript := "res://scripts/systems/quest_manager.gd"
const DialogueScript := "res://scripts/ui/npc_dialogue.gd"
const TrackerScript := "res://scripts/ui/hud_tracker.gd"
const QuestLogScript := "res://scripts/ui/hud_quest_log.gd"
const QuestScrollScript := "res://scripts/ui/hud_quest_scroll.gd"
## F talks to the nearest NPC this close; a click talks from within the
## server's talk radius less this margin (latency).
const TALK_KEY_REACH := 4.0
## A trip whose connection closed and whose next ticket has not come this long.
const TRIP_LOST_SECONDS := 15.0
const TALK_CLICK_MARGIN := 0.5
## `--check-quests`: how long it may take at most, how near it walks to an NPC
## and to a dummy, how long each window stays up for a capture, and how long
## it stands after the last claim (the toasts).
const CHECK_QUESTS_SECONDS := 240.0
const CHECK_NPC_REACH := 2.6
## The way into the training yard round the walls south-east of the
## courtyard: its fence is a solid slab on the north and south sides (a bolt
## cast over it strikes its top), the west side is open between posts. The
## last point is where the dummies face (creature_views.json
## `training_dummy.faces`).
const CHECK_YARD_ROUTE := [Vector2(40, 52), Vector2(62, 38), Vector2(60, 27), Vector2(78, 27)]
const CHECK_WAYPOINT_REACH := 1.5
const CHECK_SHOW := 2.0
const CHECK_LINGER := 4.0
const CHECK_WALK_REPORT := 5.0
## Less ground than this in CHECK_STALL_SECONDS of walking is a stall; the
## sidestep then lasts CHECK_SIDESTEP_SECONDS.
const CHECK_STALL_METRES := 0.6
const CHECK_STALL_SECONDS := 1.0
const CHECK_SIDESTEP_SECONDS := 1.2
## What a refused quest claim says (the server's reason).
# i18n-begin
const QUEST_REASONS := {
	"bag_full": "No room in your bag for the quest reward. Make space, then claim it again.",
}
# i18n-end

var session: Node
var player: Node3D
## The map this scene shows: `--map` (default grounds), or the map a trip
## brought the player to (RealmSession.pending_travel_map).
var map_name := "grounds"
## The map's own scene (Phase 6), when it has one.
var map_view: Node3D = null
## Doors, hearths, Waylinks, the broom key and the loading flow (MapTravel).
var travel: MapTravel
## `--check-travel`: the travel check.
var travel_check: Node = null
## Dungeon gates, the run tracker and the result (MapDungeon).
var dungeon: MapDungeon
## Way-finding: the minimap, the world map (M), the waypoint and its
## footprints, the zone banner (MapWay).
var way: MapWay
## `--check-map`: the way-finding check.
var map_check: Node = null
## The world's ear (zone, steps, creature voices, the fight and flight mix)
## and `--check-audio`'s check.
var world_audio: WorldAudio
var audio_check: Node = null
## `--check-dungeon`: the dungeon check (`--check-guide`: the guide check, in
## the same place: it walks and hears the same events).
var dungeon_check: Node = null
## Other players' heroes by entity id.
var heroes := {}
## Other players' names by entity id, as the server said them (asked when a
## hero comes into view; a local chat line carries its speaker's entity too).
## Forgotten when the player leaves view.
var player_names := {}
## Other players' {name, house, level, character} by entity id (Inspect).
var player_infos := {}
## The player's sheet for the windows, the HUD and the windows.
var sheet_view: PlayerSheet
var hud: Control
var inventory: Control
## Kestrin's workshop (O), docked beside the bag; it finds the bag and the HUD
## as its siblings.
var workshop: Control
## Toasts, the level-up moment and the death panel (CombatFeedback).
var feedback: Control
var loot_window: Control
var character_window: Control
## The skill window (V).
var skill_window: HudSkillWindow
## The overhead nameplates of every player and creature in view.
var plates: Nameplates
## The player's own info (asked at join, pushed when it changes): its plate.
var own_info := {}
## The snapshot kind each creature's plate was drawn for (an enrage redraws it).
var _plate_kinds := {}
## `--check-skills` / `--check-others` (and `--others-guest`).
var skills_check: Node = null
var others_check: Node = null
## The quest log as the interface sees it (QuestManager), and its windows: the
## NPC dialogue card, the tracker, the log (J) and the quest scroll.
var quests: QuestManager
var dialogue: NpcDialogue
var tracker: HudTracker
var quest_log: HudQuestLog
var quest_scroll: HudQuestScroll
## The controls introduction on a first entry (FirstSteps).
var first_steps: FirstSteps
## The map's NPCs (NpcView), drawn once the map is in.
var npcs: Array = []
## Loot chests on the ground by entity id (ChestView).
var chests := {}
## Casts, bolts, impacts, bursts, wards and damage numbers.
var combat: CombatView
## The selected creature (entity id, 0 = none).
var target := 0
## This frame's snapshot of everyone else (RealmSession.remote) and every
## body's drawn position by entity id, own included.
var others: Dictionary = {}
var drawn: Dictionary = {}
## Creatures with a model by entity id (CreatureView); species without one yet
## are drawn as capsules.
var beasts := {}
## Species kinds (marks masked) with no model in this client yet.
var no_model := {}
const CreatureViewScript := "res://scripts/view/creature_view.gd"
## Objects draw through their own views (creature_views.json "object").
const OBJECT_VIEWS := {"stone": "res://scripts/view/stone_view.gd", "dummy": "res://scripts/view/dummy_view.gd"}
## What the server said each creature is (RealmSession.take_creature_info),
## by entity id: boss_key, name, level, elite, boss.
var infos := {}
## World bosses by their name: {region, level} from the content (the notices
## name only the boss).
var _boss_sites := {}
var _shaking: Tween
var house_color := Color(0.85, 0.4, 0.11)
var crowd: MultiMeshInstance3D
var camera: Camera3D
## The debug readout (fps, tick, corrections, position, the sheet), bottom
## right: hidden unless its key (GameSettings.DEBUG_KEY) shows it or the
## `--check N` fight check runs (its verdict prints it).
var readout: Label
## When the ping on the minimap was last refreshed (twice a second).
var _ping_at := 0
var cam_yaw := 0.0
var cam_pitch := -0.35
var cam_distance := 9.0
## Extra camera turn around the player that does not steer (screenshots).
var cam_side := 0.0
var check_seconds := 0.0
var check_started := 0.0
var check_cast_wait := 0.0
## What the check saw of its own fight: casts begun, hits landed and the hp
## byte (0..255) its last hit left the creature at.
var check_casts := 0
var check_hits := 0
var check_hp := -1
## The check also learns Shockwave with its free skill point and casts it once
## (the skill request, an area burst).
var check_learn_sent := false
var check_shockwave_cast := false
var check_bursts := 0
## Status bits seen on each creature (entity id -> union), the creatures the
## check's own hits landed on, and the union seen on its target.
var check_statuses := {}
var check_hit_ids := {}
## The creatures the check's Shockwave (its throw) landed on, with their kind.
var check_thrown_at := {}
var check_target_statuses := 0
## The union of status bits the creatures put on the player.
var check_own_statuses := 0
## `--check-spells`: the rotation the check casts instead of the basic cast.
var check_spells: PackedStringArray = []
var check_spell_next := 0
## `--check-target stone_dark`: the species the check fights first (a Dark
## Shard's waves, a dummy), when one is in view.
var check_target_species := ""
## What the check saw of the world: creature answers, bosses with the body
## they wear (entity id -> "key model xscale"), notices by kind, and the
## objects in view (entity ids).
var check_infos := 0
var check_bosses := {}
var check_notices := {}
## The kill loop as the check saw it: experience and oril earned, levels,
## deaths and the rises it asked for.
var check_exp := 0
var check_oril := 0
var check_levels := 0
var check_deaths := 0
var check_rises_asked := 0
## When the check first fell (seconds, 0 = never) and how it rises.
var check_fell_at := 0.0
var check_rise := "town"
## Chests: seen in view, the one the check walks to (0 = none) and since when
## its window shows what it holds, rewards that brought items, chests seen to
## vanish, and loot answers by reason.
var check_chests_seen := {}
var check_loot_target := 0
var check_loot_shown_at := 0.0
var check_loot_taken := false
var check_loot_items := 0
var check_chests_vanished := 0
var check_loot_results := {}
## Status points: whether it had one, asked to spend it, and the answers.
var check_had_points := false
var check_spend_sent := false
var check_attribute_results := {}
var check_stones := {}
var check_dummies := {}
var built := false
## The missing-Vulkan warning was shown (once per run).
static var _graphics_warned := false
## When the connection was found closed in the middle of a trip (0: not).
var _closed_on_trip_at := 0.0
## The joined map is being built (it can take several frames).
var _map_building := false
## The player is a game admin (its own player info's `ga`).
var own_ga := false
## The realm's weather here (RealmWeather) and the maintenance banner and end
## screen (MaintenanceUI).
var weather: RealmWeather
## The hour's light, sky and fog outdoors and the character fill everywhere
## (DayNight; the rain darkens it).
var day_night: DayNight
var maintenance: MaintenanceUI
## `--check-ops`: the operations check.
var ops_check: Node = null
## The Esc menu and its Settings window (with Credits).
var game_menu: HudGameMenu
var settings_window: SettingsWindow
## `--check-menu`: the menu check (both sides of the scene reload).
var menu_check: Node = null
## The login card and the character screen, before any world (null in it).
var front_door: FrontDoor = null
## The join (connecting until joined): when it began, whether its outcome
## was printed, and a fresh ticket being fetched for another try
## (retry_join).
var _join_began := 0.0
var _join_told := false
var _retrying := false
## `--check-login`: the front door check (both sides of the scene reload).
var login_check: Node = null
## `--check-duel` / `--duel-guest`: the duel check, told of every combat event.
var duel_check: Node = null
## `--check-quests`: the check walks the first chapter (see _check_quest_walk):
## the step it is on and since when, the talks it opened, the quests the server
## paid and the claim answers by reason, and when it finished.
var check_quests := false
var check_quest_step := "start"
var check_step_since := 0.0
var check_talks := 0
var check_claimed: Array = []
var check_quest_results := {}
var check_quest_done_at := 0.0
var check_equip_sent := false
var check_dummy_id := 0
var check_dummy_casts := 0
var check_route_next := 0
## Casts the server refused, by reason.
var check_refusals := {}
var check_page_wait := 0.0
var check_tracker_pressed := false
var check_verdict_given := false
## When the walk last said where it is (every CHECK_WALK_REPORT seconds).
var check_walk_said := 0.0
## A walk that stops gaining ground (a trunk, a post square in its way)
## sidesteps for a while: where it last measured, when, and the sidestep
## (strafe direction and until when).
var check_walk_from := Vector3.INF
var check_walk_at := 0.0
var check_strafe := 0.0
var check_strafe_until := 0.0
var check_strafe_side := 1.0
## When the next "you are stunned" notice may show.
var _held_notice_at := 0.0
## The basic cast held: "" none, "target" (the click took a creature: it
## follows the target), "aim" (the click took the ground: it follows the
## cursor, as a click there would), "key" (its key: the target, else the
## cursor's point); when the next may be asked for (ticks clock, seconds).
var basic_hold := ""
var _basic_next_at := 0.0
## Basic casts the hold repeated (the polish check reads it).
var basic_repeats := 0
## The mark under the current target (TargetRing), the moving staircases
## (StairView), the screen's edge at low health (LowHpVignette), the
## protected-ground cue (SafeZoneCue) and the bestiary (B).
var target_ring: TargetRing
var stairs: StairView
var vignette: LowHpVignette
var safe_cue: SafeZoneCue
var bestiary: HudBestiary
## Titles shown as earned ("New title" toasts; the check reads them).
var titles_toasted: Array = []
## `--check-hud2` / `--check-stairs`: the HUD parity check and the staircase
## check.
var hud2_check: Node = null
var stairs_check: Node = null
var castle_check: Node = null
## `--check-caverns` / `--check-dungeons`: a drawn map's alignment and cost.
var drawn_check: Node = null
## `--check-light`: day and night, the rain's darkening, the quality presets.
var light_check: Node = null
## `--check-polish`: the small HUD pieces' check.
var polish_check: Node = null
var controls_check: Node = null
## Loot takes asked for by key (Z or its second key; the controls check).
var check_loot_presses := 0

func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback

func _ready() -> void:
	# the player's settings first: the interface scale, fullscreen and the keys
	# hold for the front door as for the world
	GameSettings.instance().apply_all()
	# the game's own pointers, the hand over every button
	CursorKit.apply()
	if not get_tree().node_added.is_connected(CursorKit.point_at_buttons):
		get_tree().node_added.connect(CursorKit.point_at_buttons)
	if RealmPaths.is_release():
		var refused := _dev_switch()
		if refused == "" and OS.get_cmdline_user_args().has("--check-login"):
			refused = "--check-login"
		if refused != "":
			printerr("realm: %s is for dev runs, not a release build" % refused)
			get_tree().quit(2)
			return
	var root := RealmPaths.root()
	if RealmPaths.is_release() and not Engine.has_meta(&"realm_root_told"):
		Engine.set_meta(&"realm_root_told", true)
		print("realm: release root %s, login service %s" % [root, _arg("--login-url", LoginApi.default_url())])
	check_seconds = float(_arg("--check", "0"))
	cam_distance = float(_arg("--cam-distance", str(cam_distance)))
	cam_side = deg_to_rad(float(_arg("--cam-side", "0")))
	check_target_species = _arg("--check-target", "")
	var rotation_arg := _arg("--check-spells", "")
	if rotation_arg != "":
		check_spells = rotation_arg.split(",", false)
	check_rise = _arg("--check-rise", check_rise)
	check_quests = OS.get_cmdline_user_args().has("--check-quests")
	if check_quests and check_seconds <= 0.0:
		check_seconds = CHECK_QUESTS_SECONDS
	if not ClassDB.class_exists("RealmSession"):
		printerr("realm: the realm_client extension did not load (cargo build --release -p realm_client)")
		_start_failed(2, tr("A part of the game could not be loaded. Open the launcher and let it check the installation."))
		return
	var trip_map := String(ClassDB.class_call_static("RealmSession", "pending_travel_map"))
	map_name = trip_map if trip_map != "" else _arg("--map", "grounds")
	if not ClassDB.class_call_static("RealmContent", "load", _arg("--content", root.path_join("content/data"))):
		printerr("realm: content/data could not be read")
		_start_failed(1, tr("The game's data could not be read. Open the launcher and let it check the installation."))
		return
	var houses: Variant = ClassDB.class_call_static("RealmContent", "table", "houses")
	if houses is Dictionary and (houses as Dictionary).has("velkar"):
		house_color = Color.html(String(houses["velkar"].get("primary_color", "#d9661c")))
	if trip_map == "" and (FrontDoor.wanted or _wants_front_door()):
		_show_front_door()
		return
	session = ClassDB.instantiate("RealmSession")
	add_child(session)
	var ok: bool
	if trip_map != "":
		# a trip brought the player here: join with its ticket
		ok = session.start_travel(_arg("--keys", root.path_join("keys")), _arg("--content", root.path_join("content/data")),
			_arg("--maps", root.path_join("world/maps")))
	else:
		ok = session.start_dev(_arg("--server", "127.0.0.1:7777"), _arg("--keys", root.path_join("keys")),
			_arg("--content", root.path_join("content/data")), _arg("--maps", root.path_join("world/maps")),
			map_name, int(_arg("--character", "0")))
	if not ok:
		printerr("realm: ", session.status())
		_start_failed(1, tr("The connection to the realm could not be prepared. Please log in again; if this keeps happening, let the launcher check the installation."))
		return
	_join_began = Time.get_ticks_msec() / 1000.0
	print("realm: joining %s%s" % [map_name, " (try %d)" % (FrontDoor.join_retries + 1) if FrontDoor.join_retries > 0 else ""])
	_build_view()
	if trip_map != "":
		travel.begin_arrival()

## The game cannot go on from here: a dev run or check ends with `code`, a
## player gets the end screen saying why, with the way back to the login card
## when there is one to go back to.
func _start_failed(code: int, why: String) -> void:
	if not _wants_front_door() and _quits_when_closed():
		get_tree().quit(code)
		return
	_problem_screen(tr("The game could not start"), why, ClassDB.class_exists("RealmSession") and code == 1 and session != null)

func _problem_screen(title: String, why: String, can_return: bool, go_on := Callable(), go_on_text := "") -> void:
	MapLoadingScreen.shared(get_tree()).dismiss()
	var screen := MaintenanceUI.new()
	add_child(screen)
	screen.setup(null)
	if can_return:
		screen.to_login = return_to_login
	screen.show_problem(title, why, go_on, go_on_text)

## No Vulkan or Metal: the engine fell back to its simple renderer, which the
## game's materials are not made for. Said once at the front door.
func _warn_old_graphics() -> void:
	if _graphics_warned or RenderingServer.get_rendering_device() != null or DisplayServer.get_name() == "headless":
		return
	_graphics_warned = true
	_problem_screen(tr("Your graphics driver is out of date"),
		tr("The game needs Vulkan (Metal on a Mac) and could not start it, so it may look wrong or fail. Updating your graphics driver usually fixes this."),
		false, func(): pass, tr("Continue anyway"))

## The pointers go back to the system's while the renderer still holds them
## (a scene rebuilt for a trip installs them again).
func _exit_tree() -> void:
	CursorKit.release()

## The dev join is for `--character`, `--server` and the checks that play a
## dev character; anything else starts at the login card.
func _wants_front_door() -> bool:
	return _dev_switch() == ""

## The first switch that needs the dev join or a dev check's script ("" when
## none): `--character`, `--server`, a `-guest` client, any `--check*` but
## the front door's own (`--check-login`, `--check-play`).
func _dev_switch() -> String:
	for arg: String in OS.get_cmdline_user_args():
		if arg == "--character" or arg == "--server" or arg.ends_with("-guest") \
				or (arg.begins_with("--check") and arg != "--check-login" and arg != "--check-play" \
					and arg != "--check-play-limit"):
			return arg
	return ""

func _show_front_door() -> void:
	_warn_old_graphics()
	# the world's sound fades; the front door plays the menu theme
	AudioManager.world_ended()
	AudioManager.set_music_state("menu")
	front_door = FrontDoor.new()
	add_child(front_door)
	front_door.setup(_arg("--login-url", LoginApi.default_url()))
	_add_login_check()
	_add_menu_check()

func _add_menu_check() -> void:
	if OS.get_cmdline_user_args().has("--check-menu") and menu_check == null:
		menu_check = load(MenuCheckScript).new()
		menu_check.name = "MenuCheck"
		menu_check.game = self
		add_child(menu_check)

## Leave the world (the menu's countdown ran out): the connection closes
## cleanly here - the server saves and releases the character as it ends -
## then the game quits, or goes back to the character screen when the player
## came in through the login card (its token still held), else (a dev join)
## to the login card.
func leave_world(quit: bool) -> void:
	before_reload()
	# nothing of the world runs again before the scene goes: no view asks the
	# freed session for anything
	process_mode = Node.PROCESS_MODE_DISABLED
	if session != null:
		# freeing the session closes the connection and waits for the server
		# to hear the goodbye (NetHandle's drop)
		session.free()
		session = null
	if quit:
		get_tree().quit()
		return
	FrontDoor.wanted = true
	FrontDoor.to_characters = LoginApi.token != ""
	get_tree().reload_current_scene.call_deferred()

func _add_login_check() -> void:
	if OS.get_cmdline_user_args().has("--check-play"):
		login_check = load(PlayCheckScript).new()
		login_check.name = "PlayCheck"
		login_check.game = self
		add_child(login_check)
	elif OS.get_cmdline_user_args().has("--check-login"):
		login_check = load(LoginCheckScript).new()
		login_check.name = "LoginCheck"
		login_check.game = self
		add_child(login_check)

## Back to the login card (the world's end screen, a check): the scene is
## rebuilt without a world; `kind` / `detail` say why on the card. The
## connection closes here (the server hears the goodbye), and the loading
## screen - it lives on the tree's root and outlives the reload - goes too,
## or it covered the card (a join that never got in left it up).
func return_to_login(kind := "", detail := "") -> void:
	FrontDoor.return_kind = kind
	FrontDoor.return_detail = detail
	FrontDoor.join_retries = 0
	before_reload()
	# nothing of the world asks the freed session anything before the scene goes
	process_mode = Node.PROCESS_MODE_DISABLED
	if session != null:
		session.free()
		session = null
	MapLoadingScreen.shared(get_tree()).dismiss()
	get_tree().reload_current_scene.call_deferred()

## A join that never got in may be tried again with a fresh ticket (in
## through the front door, a failure that can pass: no answer, a ticket the
## map no longer takes, a realm still linking or restarting), at most
## JOIN_RETRIES times by itself; the end screen's Try Again resets that.
func _join_can_retry(status: String) -> bool:
	if built or FrontDoor.playing_character <= 0 or LoginApi.token == "":
		return false
	if status.begins_with("closed"):
		return true
	var why := status.get_slice(": ", 1) if status.contains(": ") else status
	return RETRY_REASONS.has(why)

## Another try at the join: a fresh ticket from the login service (the
## character's map as it stands now), the scene rebuilt for it behind the
## loading screen, as Enter World does. A ticket that cannot be had shows
## the end screen with the service's reason.
func retry_join(why: String) -> void:
	if _retrying:
		return
	_retrying = true
	if why == "the player asked":
		FrontDoor.join_retries = 0
	else:
		FrontDoor.join_retries += 1
	print("realm: join failed (%s); fetching a fresh ticket (try %d)" % [why, FrontDoor.join_retries + 1])
	maintenance.clear_closed()
	var screen := MapLoadingScreen.shared(get_tree())
	if not screen.is_open():
		await screen.open(I18n.upper(TravelData.display_name(map_name)), tr("Entering the realm…"))
	screen.set_progress(25.0, tr("The game server did not answer; trying again…"))
	var api := LoginApi.new(_arg("--login-url", LoginApi.default_url()))
	add_child(api)
	var res: Dictionary = await api.play(FrontDoor.playing_character)
	api.queue_free()
	if not is_inside_tree():
		return
	var why_not := ""
	if res.maintenance:
		why_not = "maintenance"
	elif not res.ok:
		why_not = String(res.error)
	elif not ClassDB.class_call_static("RealmSession", "join_ticket", String(res.body.get("map", "")),
			String(res.body.get("address", "")), String(res.body.get("ticket", ""))):
		why_not = tr("The login server sent a ticket this client cannot read.")
	if why_not != "":
		_retrying = false
		print("realm: no fresh ticket: %s" % why_not)
		maintenance.show_closed("refused: " + why_not, false)
		return
	before_reload()
	get_tree().reload_current_scene()

func _build_view() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation = Vector3(deg_to_rad(-50), deg_to_rad(35), 0)
	sun.shadow_enabled = true
	add_child(sun)
	var env := WorldEnvironment.new()
	env.name = "WorldEnvironment"
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.68, 0.82)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.5, 0.52, 0.55)
	add_child(env)
	plates = Nameplates.new()
	add_child(plates)
	add_child(FloatingText.new())
	player = _new_hero()
	player.is_local_player = true
	crowd = MultiMeshInstance3D.new()
	crowd.multimesh = MultiMesh.new()
	crowd.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	crowd.multimesh.use_colors = true
	crowd.multimesh.mesh = _capsule(Color.WHITE)
	add_child(crowd)
	camera = Camera3D.new()
	camera.far = 3000.0
	add_child(camera)
	combat = CombatView.new()
	combat.player = player
	combat.heroes = heroes
	combat.beasts = beasts
	combat.session = session
	add_child(combat)
	world_audio = WorldAudio.new()
	world_audio.game = self
	add_child(world_audio)
	target_ring = TargetRing.new()
	add_child(target_ring)
	stairs = StairView.new()
	stairs.session = session
	add_child(stairs)
	StatusFX.warm_assets()
	readout = Label.new()
	# bottom right over the taskbar: the minimap holds the top right corner
	readout.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	readout.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	readout.grow_vertical = Control.GROW_DIRECTION_BEGIN
	readout.offset_right = -12
	readout.offset_bottom = -104
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	readout.add_theme_font_size_override("font_size", 12)
	readout.visible = check_seconds > 0.0
	var layer := CanvasLayer.new()
	layer.add_child(readout)
	add_child(layer)
	weather = RealmWeather.new()
	add_child(weather)
	weather.setup(session, map_name)
	day_night = DayNight.new()
	add_child(day_night)
	day_night.setup(self, map_name)
	# the quality preset on the viewport, the sun, the camera and the weather
	# (the map's own parts once it is built); a change in Settings applies live
	QualityPreset.apply(self)
	if not GameSettings.instance().changed.is_connected(_on_settings_changed):
		GameSettings.instance().changed.connect(_on_settings_changed)
	_build_ui()

## Settings > Graphics: the quality preset applies to the live world, a held
## time of day eases in (DayNight reads the setting).
func _on_settings_changed(what: String) -> void:
	if what == "graphics_quality" or what == "all":
		QualityPreset.apply(self)

## The interface: a full-screen root holding the HUD ("HUD", which the windows
## look for) and the inventory (I).
func _build_ui() -> void:
	# the low-health edge under every part of the interface
	var edge := CanvasLayer.new()
	edge.layer = 4
	add_child(edge)
	vignette = LowHpVignette.new()
	vignette.session = session
	edge.add_child(vignette)
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	var root := Control.new()
	root.name = "UI"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	sheet_view = load(PlayerSheetScript).new(session)
	add_child(sheet_view)
	hud = load(HudScript).new()
	root.add_child(hud)
	hud.setup(session, sheet_view, toggle_inventory)
	hud.action_bar.spell_requested.connect(cast_spell)
	inventory = load(InventoryScript).new()
	inventory.name = "Inventory"
	root.add_child(inventory)
	inventory.prepare(sheet_view)
	if _arg("--open-bag", "") != "":
		inventory.open_for_player(sheet_view)
	workshop = load(WorkshopScript).new()
	root.add_child(workshop)
	character_window = load(CharacterScript).new()
	character_window.setup(session)
	root.add_child(character_window)
	skill_window = HudSkillWindow.new()
	skill_window.setup(session, sheet_view, hud)
	root.add_child(skill_window)
	if _arg("--open-character", "") != "":
		character_window.open.call_deferred()
	loot_window = load(LootScript).new()
	loot_window.name = "LootWindow"
	loot_window.session = session
	loot_window.where = _chest_distance
	root.add_child(loot_window)
	feedback = load(FeedbackScript).new()
	feedback.name = "CombatFeedback"
	root.add_child(feedback)
	feedback.setup(session, hud, player)
	_build_quest_ui(root)
	travel = MapTravel.new()
	add_child(travel)
	travel.setup(self, map_name, root)
	dungeon = MapDungeon.new()
	add_child(dungeon)
	dungeon.setup(self, map_name, root)
	way = MapWay.new()
	add_child(way)
	way.setup(self, map_name, root)
	if OS.get_cmdline_user_args().has("--check-map"):
		map_check = load(MapCheckScript).new()
		map_check.name = "MapCheck"
		map_check.game = self
		add_child(map_check)
	if OS.get_cmdline_user_args().has("--check-audio"):
		audio_check = load(AudioCheckScript).new()
		audio_check.name = "AudioCheck"
		audio_check.game = self
		add_child(audio_check)
	var user_args := OS.get_cmdline_user_args()
	if user_args.has("--check-stairs"):
		stairs_check = load(StairsCheckScript).new()
		stairs_check.name = "StairsCheck"
		stairs_check.game = self
		add_child(stairs_check)
	if user_args.has("--check-light"):
		light_check = load(LightCheckScript).new()
		light_check.name = "LightCheck"
		light_check.game = self
		add_child(light_check)
	if user_args.has("--check-castle"):
		castle_check = load(CastleCheckScript).new()
		castle_check.name = "CastleCheck"
		castle_check.game = self
		add_child(castle_check)
	if user_args.has("--check-caverns") or user_args.has("--check-dungeons"):
		drawn_check = load(DrawnMapCheckScript).new()
		drawn_check.name = "DrawnMapCheck"
		drawn_check.game = self
		add_child(drawn_check)
	if user_args.has("--check-polish"):
		polish_check = load(PolishCheckScript).new()
		polish_check.name = "PolishCheck"
		polish_check.game = self
		add_child(polish_check)
	if user_args.has("--check-controls"):
		controls_check = load(ControlsCheckScript).new()
		controls_check.name = "ControlsCheck"
		controls_check.game = self
		add_child(controls_check)
	if user_args.has("--check-dungeon") or user_args.has("--check-guide") or user_args.has("--check-boss") \
			or user_args.has("--check-lair") or user_args.has("--check-hud2"):
		var script := DungeonCheckScript
		var check_name := "DungeonCheck"
		if user_args.has("--check-hud2"):
			# the HUD parity check walks the dungeon check's road (and more)
			script = Hud2CheckScript
			check_name = "Hud2Check"
		elif user_args.has("--check-lair"):
			script = LairCheckScript
			check_name = "LairCheck"
		elif user_args.has("--check-boss"):
			script = BossCheckScript
			check_name = "BossCheck"
		elif user_args.has("--check-guide"):
			script = GuideCheckScript
			check_name = "GuideCheck"
		dungeon_check = load(script).new()
		dungeon_check.name = check_name
		dungeon_check.game = self
		add_child(dungeon_check)
	if OS.get_cmdline_user_args().has("--check-travel"):
		travel_check = load(TravelCheckScript).new()
		travel_check.name = "TravelCheck"
		travel_check.game = self
		add_child(travel_check)
	if OS.get_cmdline_user_args().has("--check-workshop"):
		var check: Node = load(WorkshopCheckScript).new()
		check.name = "WorkshopCheck"
		check.game = self
		add_child(check)
	maintenance = MaintenanceUI.new()
	add_child(maintenance)
	maintenance.setup(hud)
	if LoginApi.token != "":
		# in through the front door: the end screen goes back to it, and
		# tries the join again with a fresh ticket
		maintenance.to_login = return_to_login
		if FrontDoor.playing_character > 0:
			maintenance.retry = retry_join.bind("the player asked")
	_add_login_check()
	if user_args.has("--check-ops"):
		ops_check = load(OpsCheckScript).new()
		ops_check.name = "OpsCheck"
		ops_check.game = self
		add_child(ops_check)
	settings_window = SettingsWindow.new()
	root.add_child(settings_window)
	game_menu = HudGameMenu.new()
	game_menu.game = self
	root.add_child(game_menu)
	game_menu.settings_requested.connect(settings_window.open)
	settings_window.language_apply_requested.connect(game_menu.leave_to_characters)
	bestiary = HudBestiary.new()
	bestiary.way = way
	bestiary.map_name = map_name
	root.add_child(bestiary)
	safe_cue = SafeZoneCue.new()
	safe_cue.game = self
	root.add_child(safe_cue)
	_connect_taskbar()
	_add_menu_check()
	_build_social_ui()
	if user_args.has("--check-skills"):
		skills_check = load(SkillsCheckScript).new()
		skills_check.name = "SkillsCheck"
		skills_check.game = self
		add_child(skills_check)
	var others_guest := _arg("--others-guest", "")
	if user_args.has("--check-others") or others_guest != "":
		others_check = load(OthersCheckScript).new()
		others_check.name = "OthersCheck"
		others_check.game = self
		others_check.guest_of = others_guest
		add_child(others_check)

## The taskbar's window buttons open what their keys open (the menu as
## Escape's last step does), and the Quests button pulses with a quest
## ready to hand in.
func _connect_taskbar() -> void:
	var buttons: Dictionary = hud.menu_buttons
	(buttons["workshop"] as Button).pressed.connect(func(): workshop.toggle(sheet_view))
	(buttons["quests"] as Button).pressed.connect(quest_log.toggle)
	(buttons["character"] as Button).pressed.connect(character_window.toggle)
	(buttons["skills"] as Button).pressed.connect(skill_window.toggle)
	(buttons["map"] as Button).pressed.connect(way.world_map.toggle)
	(buttons["bestiary"] as Button).pressed.connect(bestiary.toggle)
	(buttons["dungeons"] as Button).pressed.connect(dungeon.guide_window.toggle)
	(buttons["menu"] as Button).pressed.connect(func(): game_menu.close() if game_menu.visible else game_menu.open())
	hud.quests_ready = func() -> bool: return quests.needs_attention()

## The social pieces the HUD holds: the party frames know this map and push
## the tracker down when they grow; the player menu measures from the
## player's body. `--check-social` / `--social-guest` add their check.
func _build_social_ui() -> void:
	hud.party_frames.map_name = map_name
	hud.party_frames.rows_changed.connect(_on_party_rows)
	hud.player_menu.player = player
	hud.duel_view.player = player
	hud.duel_view.heroes = heroes
	var duel_guest := _arg("--duel-guest", "")
	if OS.get_cmdline_user_args().has("--check-duel") or duel_guest != "":
		duel_check = load(DuelCheckScript).new()
		duel_check.name = "DuelCheck"
		duel_check.game = self
		duel_check.guest_of = duel_guest
		add_child(duel_check)
	var guest := _arg("--social-guest", "")
	if OS.get_cmdline_user_args().has("--check-social") or guest != "":
		var check: Node = load(SocialCheckScript).new()
		check.name = "SocialCheck"
		check.game = self
		check.guest_of = guest
		check.invite_from = _arg("--check-invite-from", "")
		add_child(check)

## The tracker sits on the left edge above the middle; a party of five would
## run into it, so it moves below the last row.
func _on_party_rows(bottom: float) -> void:
	var middle := get_viewport().get_visible_rect().size.y * 0.5
	var top := maxf(HudTracker.AT.y, bottom + 10.0 - middle)
	tracker.offset_top = top
	tracker.offset_bottom = top + 10.0

## The quest log's view and windows: the tracker on the left edge, the NPC
## dialogue card, the log (J) and, over every window, the quest scroll.
func _build_quest_ui(root: Control) -> void:
	quests = load(QuestManagerScript).new()
	quests.name = "Quests"
	add_child(quests)
	quests.setup(session, sheet_view)
	quests.quest_updated.connect(_update_npc_arrows)
	tracker = load(TrackerScript).new()
	tracker.quests = quests
	root.add_child(tracker)
	root.move_child(tracker, hud.get_index() + 1)
	dialogue = load(DialogueScript).new()
	dialogue.quests = quests
	dialogue.can_serve = _can_serve
	root.add_child(dialogue)
	quest_log = load(QuestLogScript).new()
	quest_log.quests = quests
	root.add_child(quest_log)
	quest_scroll = load(QuestScrollScript).new()
	quest_scroll.quests = quests
	root.add_child(quest_scroll)
	quest_log.open_scroll = func(id: String): quest_scroll.open(id)
	tracker.quest_opened.connect(func(id: String): quest_scroll.open(id))
	tracker.log_opened.connect(quest_log.toggle)
	dialogue.quest_chosen.connect(func(id: String): quest_scroll.open(id))
	dialogue.service_chosen.connect(_open_service)
	first_steps = FirstSteps.new()
	first_steps.game = self
	root.add_child(first_steps)
	root.move_child(first_steps, tracker.get_index() + 1)

## A service an NPC offers (npcs.json `services`) opens its window: the
## workshop is the "WorkshopUI" window beside the bag.
func _service_window(service: String) -> Control:
	var root := hud.get_parent()
	match service:
		"workshop":
			return root.get_node_or_null("WorkshopUI") as Control
	return null

func _can_serve(service: String) -> bool:
	return _service_window(service) != null

func _open_service(service: String) -> void:
	var window := _service_window(service)
	if window != null:
		if window.has_method("open_for_player"):
			window.open_for_player(sheet_view)
		else:
			window.show()

func toggle_inventory() -> void:
	if inventory.visible:
		inventory.hide()
	else:
		inventory.open_for_player(sheet_view)

## The player's hero wears what its sheet says (HeroView.wear: the look, the
## house's cloth as on the dais, the wand in the hand, the chest's cloak and
## the broom it rides with its speed); only what changed is redrawn.
func _apply_sheet_look(sheet: Dictionary) -> void:
	player.wear(sheet["look"], String(sheet.get("house", "")), sheet["equipment"])

## Another player's body wears what its info says (the same HeroView.wear as
## the own hero's sheet), and its plate shows who it is.
func _dress_player(id: int) -> void:
	var info: Dictionary = player_infos.get(id, {})
	var hero: HeroView = heroes.get(id)
	if info.is_empty() or hero == null:
		return
	hero.set_ga(bool(info.get("ga", false)))
	hero.wear(HeroView.look_of_pairs(info.get("look", [])), String(info.get("house", "")),
		HeroView.equipment_of_gear(info.get("gear", [])))
	_plate_player(id, hero, info, false)

## A player's plate from its info: the newest title (a dungeon's
## first_clear_title or the weekly record's), the name, level and house.
func _plate_player(id: int, hero: HeroView, info: Dictionary, own: bool) -> void:
	var titles: Array = info.get("titles", [])
	var title := I18n.t(DungeonData.title_name(String(titles[-1]))) if not titles.is_empty() else ""
	plates.set_player(id, hero, String(info.get("name", "")), int(info.get("level", 0)), String(info.get("house", "")),
		title, own)

## A trip to another map rebuilds the scene: the old session goes with it.
func before_reload() -> void:
	set_process(false)
	if travel_check != null:
		travel_check.before_reload()
	if dungeon_check != null:
		dungeon_check.before_reload()

func _new_hero() -> Node3D:
	var hero: Node3D = load(HeroViewScript).new()
	add_child(hero)
	hero.setup(house_color)
	hero.screen_plate = Nameplates.enabled()
	return hero

func _capsule(color: Color) -> Mesh:
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.35
	mesh.height = 1.85
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.vertex_color_use_as_albedo = true
	mesh.material = material
	return mesh

## Map geometry arrives once the session has joined (it needs the pack). The
## pack's meshes are at the map's own coordinates: a dungeon copy draws them
## at its offset.
func _build_map() -> void:
	_map_building = true
	var offset: Vector3 = session.copy_offset()
	# Phase 6: a map's own scene (res://maps/<map>/<map>.tscn) draws it; the
	# pack's grey terrain and walls stand in where there is none yet, or
	# with --placeholder-world. The scene sits at the copy's offset and gets
	# setup(session, main) when it has one.
	var scene := "res://maps/%s/%s.tscn" % [map_name, map_name]
	if ResourceLoader.exists(scene) and not OS.get_cmdline_user_args().has("--placeholder-world"):
		var view := (load(scene) as PackedScene).instantiate() as Node3D
		view.name = "MapView"
		view.position = offset
		add_child(view)
		# a map may take frames over it behind the loading screen (a trip)
		if view.has_method("setup"):
			await view.call("setup", session, self)
		if not is_inside_tree() or session == null:
			return   # the scene went while the map was being built
		map_view = view
		QualityPreset.apply_map(map_view)
	else:
		_build_placeholder_world(offset)
	_map_building = false
	_map_built()

## The pack's own shapes, grey: terrain and every static collider.
func _build_placeholder_world(offset: Vector3) -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.42, 0.47, 0.38)
	var terrain: ArrayMesh = session.terrain_mesh(2)
	if terrain != null:
		var node := MeshInstance3D.new()
		node.name = "Terrain"
		node.mesh = terrain
		node.material_override = material
		node.position = offset
		add_child(node)
	var walls: ArrayMesh = session.collider_mesh()
	if walls != null:
		var node := MeshInstance3D.new()
		node.name = "Walls"
		node.mesh = walls
		var stone := StandardMaterial3D.new()
		stone.albedo_color = Color(0.62, 0.6, 0.56)
		node.material_override = stone
		node.position = offset
		add_child(node)

func _map_built() -> void:
	built = true
	# the player's own info: whether it is a game admin (its emblem)
	session.inspect(session.own_entity())
	weather.on_joined()
	day_night.snap()
	_spawn_npcs()
	travel.on_map_built()
	dungeon.on_map_built()
	way.on_map_built()

## ------------------------------------------------------------------- NPCs

## The NPCs of this map (npcs.json `map`), each on the ground under its place.
func _spawn_npcs() -> void:
	var table: Variant = RealmContent.table("npcs")
	if not (table is Dictionary):
		return
	var map := map_name
	var all: Dictionary = (table as Dictionary).get("npcs", {})
	for id: String in all:
		var data: Dictionary = all[id]
		if String(data.get("map", "")) != map:
			continue
		var at: Array = data.get("pos", [0.0, 0.0])
		var npc: NpcView = load(NpcViewScript).new()
		add_child(npc)
		npc.setup(id, data)
		npc.position = _ground_under(float(at[0]), float(at[1]))
		npcs.append(npc)
	_update_npc_arrows()

## The map's surface under (x, z): the first collider a ray from the sky
## meets (a creature passing under it is looked through).
func _ground_under(x: float, z: float) -> Vector3:
	var from := Vector3(x, 1500.0, z)
	for attempt in 4:
		var hit: Dictionary = session.pick(from, Vector3.DOWN, 3000.0)
		if hit.is_empty():
			break
		var point: Vector3 = hit["point"]
		if int(hit["entity"]) == 0:
			return point
		from = point - Vector3(0, 2.5, 0)
	return Vector3(x, 0.0, z)

## The gold arrow over every NPC an open talk quest names.
func _update_npc_arrows() -> void:
	for npc: NpcView in npcs:
		npc.set_wanted(quests.npc_wants_talk(npc.npc_name))

## The nearest NPC within `reach` (ground distance) of the player, or null.
func _npc_near(reach: float) -> NpcView:
	var me: Vector3 = session.own_position()
	var best: NpcView = null
	var best_distance := reach
	for npc: NpcView in npcs:
		var distance := Vector2(npc.position.x - me.x, npc.position.z - me.z).length()
		if distance < best_distance:
			best_distance = distance
			best = npc
	return best

## The NPC under the screen point `at` when no wall stands between: [npc,
## distance along the ray], or [] when there is none.
func _npc_at(at: Vector2) -> Array:
	var origin := camera.project_ray_origin(at)
	var dir := camera.project_ray_normal(at)
	var best: NpcView = null
	var best_t := PICK_REACH
	for npc: NpcView in npcs:
		var t := npc.ray_distance(origin, dir)
		if t < best_t:
			best_t = t
			best = npc
	if best == null:
		return []
	var hit := pick_at(at)
	if not hit.is_empty() and origin.distance_to(hit["point"]) < best_t:
		return []
	return [best, best_t]

## A click on an NPC: within the talk radius (less a little) its dialogue
## opens, farther away a notice says to come closer. True when the cursor was
## on an NPC, so the click does nothing else.
func click_npc(at: Vector2) -> bool:
	var found := _npc_at(at)
	if found.is_empty():
		return false
	var npc: NpcView = found[0]
	var me: Vector3 = session.own_position()
	if Vector2(npc.position.x - me.x, npc.position.z - me.z).length() <= quests.talk_radius() - TALK_CLICK_MARGIN:
		talk_to(npc)
	else:
		hud.show_notice(tr("Come closer to talk."), "info")
	return true

## Talk to `npc`: its dialogue card opens (F again on the same NPC turns the
## page) and the server hears of it (talk quests within its radius count).
func talk_to(npc: NpcView) -> void:
	if npc == null or feedback.is_dead():
		return
	if dialogue.is_open_for(npc):
		dialogue.advance()
		return
	dialogue.open(npc, player)
	npc.talk()
	session.talk(npc.npc_name)
	check_talks += 1

## Alt+Enter toggles fullscreen as F11 does, before a field or the chat
## takes the Enter (on the front door too).
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.physical_keycode != KEY_F11 and GameSettings.is_fullscreen_chord(event):
		GameSettings.instance().toggle_fullscreen()
		get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.physical_keycode == KEY_F11 and GameSettings.is_fullscreen_chord(event):
		GameSettings.instance().toggle_fullscreen()
		get_viewport().set_input_as_handled()
		return
	if hud == null:
		# the front door has the keys
		return
	if event is InputEventKey and GameSettings.is_system_chord(event):
		return
	# the developer's readout; players have Settings > Show frame rate
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == GameSettings.DEBUG_KEY \
			and not RealmPaths.is_release():
		toggle_readout()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ESCAPE:
			_on_escape()
			return
		if event.physical_keycode == KEY_KP_ENTER:
			hud.chat.open()
			return
		# the keys the settings may rebind (GameSettings.BINDABLE)
		match GameSettings.action_for(event.physical_keycode):
			"inventory":
				toggle_inventory()
			"character":
				character_window.toggle()
			"skills":
				skill_window.toggle()
			"quest_log":
				quest_log.toggle()
			"workshop":
				workshop.toggle(sheet_view)
			"world_map":
				way.world_map.toggle()
			"bestiary":
				bestiary.toggle()
			"dungeon_guide":
				dungeon.guide_window.toggle()
			"interact":
				if built and not travel.interact():
					talk_to(_npc_near(TALK_KEY_REACH))
			"ride":
				if built and not hud.chat.is_open():
					travel.toggle_ride()
			"pickup_loot":
				take_nearest_chest()
			"basic_attack":
				if built and _basic_key_ready() and not _held_refusal():
					basic_hold = "key"
					_basic_next_at = 0.0
					_tick_basic_hold()
			"target_cycle":
				cycle_target()
			"chat":
				hud.chat.open()
		return
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		var turn := GameSettings.sensitivity()
		cam_yaw -= event.relative.x * 0.005 * turn
		cam_pitch = clampf(cam_pitch - event.relative.y * 0.004 * turn * GameSettings.pitch_sign(), -1.3, 0.4)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		# the rotate glyph while the right button turns the camera
		CursorKit.set_rotating(event.pressed)
		if event.pressed:
			_right_pressed_at = event.position
		elif built and event.position.distance_to(_right_pressed_at) < CLICK_SLOP and not click_npc(event.position):
			right_click_world(event.position)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT and built and not click_npc(event.position):
			var took := click_world(event.position)
			if took != "":
				# held, it goes on at the cast's own cadence
				basic_hold = took
				_basic_next_at = Time.get_ticks_msec() / 1000.0 + _basic_interval()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_distance = clampf(cam_distance * 0.9, CAM_NEAR, CAM_FAR)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_distance = clampf(cam_distance * 1.1, CAM_NEAR, CAM_FAR)

## The debug readout on or off (its key; the polish check).
func toggle_readout() -> void:
	readout.visible = not readout.visible

## Escape closes what is open first (the newest kinds of window, then any
## other window), then drops the target; only when nothing took it does it
## open the game menu (and a second Escape closes the menu).
func _on_escape() -> void:
	if settings_window.visible:
		settings_window.close()
	elif game_menu.visible:
		game_menu.close()
	elif quest_scroll.is_open():
		quest_scroll.close()
	elif quest_log.visible:
		quest_log.close()
	elif loot_window.visible:
		loot_window.close()
	elif dungeon.gate_window.visible:
		dungeon.gate_window.close()
	elif dungeon.guide_window.visible:
		dungeon.guide_window.close()
	elif character_window.visible:
		character_window.card.close()
	elif workshop.visible:
		workshop.hide()
	elif inventory.visible:
		inventory.hide()
	elif dialogue.visible:
		dialogue.close()
	elif _close_top_window():
		pass
	elif target != 0:
		select_target(0)
	else:
		game_menu.open()

## Any other window of the UI that is open (the Hearth and Waylink windows,
## the dungeon run's cards): the topmost one closes. False when none was.
func _close_top_window() -> bool:
	var ui := hud.get_parent()
	for i in range(ui.get_child_count() - 1, -1, -1):
		var w := ui.get_child(i) as HudWindow
		if w != null and w.visible and w != game_menu and w != settings_window:
			w.close()
			return true
	return false

## ----------------------------------------------------------------- targeting

## Where the right button went down (a release near it is a click).
var _right_pressed_at := Vector2.ZERO

## What lies under the screen point `at`: {entity, point} (RealmSession.pick).
func pick_at(at: Vector2) -> Dictionary:
	var origin := camera.project_ray_origin(at)
	var dir := camera.project_ray_normal(at)
	var hit: Dictionary = session.pick(origin, dir, PICK_REACH)
	# A boss's head or vine is a ball round the point the server holds it at
	# (session.pick knows bodies as upright cylinders from the feet), nearer
	# than whatever the ray met first.
	var limit := PICK_REACH if hit.is_empty() else origin.distance_to(hit["point"])
	var best := 0
	for id: int in part_states.keys():
		var entry: Array = part_states[id]
		if int(entry[0]) == CreatureView.STATE_DEAD or not drawn.has(id):
			continue
		var to: Vector3 = (drawn[id] as Vector3) + Vector3(0, CHEST, 0) - origin
		var along := to.dot(dir)
		var radius := float(entry[1])
		if along <= 0.0 or along >= limit or to.length_squared() - along * along > radius * radius:
			continue
		limit = along
		best = id
	if best != 0:
		return {"entity": best, "point": origin + dir * limit}
	return hit

## A left click on the world: a creature (or a standing duel foe) under the
## cursor becomes the target and takes the basic cast; another player becomes
## the target; otherwise the basic cast goes to the point there. Returns what
## a held button repeats: "target", "aim", or "" (nothing was cast at).
func click_world(at: Vector2) -> String:
	var hit := pick_at(at)
	if hit.is_empty():
		return ""
	var entity := int(hit["entity"])
	if _creature_index(entity) >= 0 or is_duel_foe(entity):
		select_target(entity)
		cast_spell("basic_cast")
		return "target"
	elif heroes.has(entity) and not player_identity(entity).is_empty():
		select_target(entity)
		return ""
	elif not _held_refusal():
		session.cast("basic_cast", 0, hit["point"])
	return "aim"

## The basic cast's cadence while held: its cooldown for this character.
func _basic_interval() -> float:
	return maxf(BASIC_REPEAT_MIN, float(session.cooldown_total("basic_cast")))

## Whether the basic attack may be cast by its key or a held button now: on
## foot (Ctrl is the broom's descend), alive, not typing.
func _basic_key_ready() -> bool:
	if player.is_mounted or feedback.is_dead() or hud.chat.is_open():
		return false
	var focus := get_viewport().gui_get_focus_owner()
	return not (focus is LineEdit or focus is TextEdit)

## The held basic cast, every frame: while the left button (after a click
## that cast) or the key stays down, the next cast goes when the last one's
## cooldown is over - at the target, or where the cursor points now, as a
## click would. Mounted, dead, held (stunned) or typing, it waits quietly.
func _tick_basic_hold() -> void:
	if basic_hold == "":
		return
	var down := false
	if basic_hold == "key":
		down = GameSettings.pressed("basic_attack")
	else:
		down = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if not down or not built:
		basic_hold = ""
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now < _basic_next_at or not _basic_key_ready() or bool(session.own_body().get("held", false)):
		return
	var has_target := target != 0 and drawn.has(target) and (_creature_index(target) >= 0 or is_duel_foe(target))
	var sent := false
	if has_target and basic_hold != "aim":
		sent = session.cast("basic_cast", target, (drawn[target] as Vector3) + Vector3(0, CHEST, 0))
	else:
		var hit := pick_at(get_viewport().get_mouse_position())
		if hit.is_empty():
			return
		var entity := int(hit["entity"])
		if basic_hold != "key" and (_creature_index(entity) >= 0 or is_duel_foe(entity)):
			# the button swept onto a creature: it is taken, as on a click
			select_target(entity)
			basic_hold = "target"
			sent = session.cast("basic_cast", entity, (drawn[entity] as Vector3) + Vector3(0, CHEST, 0))
		elif not heroes.has(entity):
			sent = session.cast("basic_cast", 0, hit["point"])
	if sent:
		basic_repeats += 1
		_basic_next_at = now + _basic_interval()

## Casts `spell` at the target's chest (a creature, or a standing duel foe), or
## with no such target at the point under the cursor.
func cast_spell(spell: String) -> void:
	if _held_refusal():
		return
	if target != 0 and drawn.has(target) and (_creature_index(target) >= 0 or is_duel_foe(target)):
		session.cast(spell, target, (drawn[target] as Vector3) + Vector3(0, CHEST, 0))
		return
	var hit := pick_at(get_viewport().get_mouse_position())
	if not hit.is_empty():
		session.cast(spell, 0, hit["point"])

## Player `id` is a standing foe in the local player's duel (a target for
## spells, Tab and clicks like a creature).
func is_duel_foe(id: int) -> bool:
	return hud != null and hud.duel_view.is_foe(id) and _player_index(id) >= 0

## The index of living creature `id` in this frame's snapshot, -1 when it is
## not one (a player, a dead creature, gone).
func _creature_index(id: int) -> int:
	if id == 0 or others.is_empty():
		return -1
	var i := (others["ids"] as PackedInt32Array).find(id)
	if i < 0 or (others["kinds"] as PackedInt32Array)[i] == KIND_PLAYER \
			or ChestView.is_chest((others["kinds"] as PackedInt32Array)[i]) 			or (others["states"] as PackedInt32Array)[i] == CreatureView.STATE_DEAD:
		return -1
	return i

## ------------------------------------------------------- multi-part bosses

## The parts of multi-part bosses in this frame's snapshot (rig boss_part):
## entity -> [state, pick radius]. Each part is a creature of its own on the
## wire, drawn by nothing of its own: its boss's model wears it.
var part_states: Dictionary = {}
## Part entities seen standing (one that leaves the snapshot after that is
## down).
var _parts_seen: Dictionary = {}
## Species kind -> pick radius for a part kind, 0.0 for any other.
var _part_radius: Dictionary = {}
const PART_SIDES := {"L": "Left", "M": "Middle", "R": "Right", "T": "Upper"}

## The pick radius of a part species kind (0: not a part): from the label
## height creature_views.json gives it.
func _part_kind_radius(species_kind: int) -> float:
	if not _part_radius.has(species_kind):
		var id := CreatureView.species_for_kind(species_kind)
		var radius := 0.0
		if CreatureView.rig_of(id) == CreatureView.PART_RIG:
			radius = clampf(float(CreatureView.view_of(id).get("label_height", 1.5)) * 0.7, 0.6, 1.6)
		_part_radius[species_kind] = radius
	return float(_part_radius[species_kind])

## The boss a part belongs to (0: unknown), from the part's own answer or the
## boss's list of its parts.
func _part_body(id: int) -> int:
	var of := int((infos.get(id, {}) as Dictionary).get("part_of", 0))
	if of != 0:
		return of
	for body_id: int in beasts.keys():
		var body: Variant = beasts[body_id]
		if body is CreatureView and (body as CreatureView).parts.has(id):
			return body_id
	return 0

## A part's name: the server's own, else the species' with the part's side
## put in ("Threehead's Head" -> "Threehead's Left Head", the old game's
## rule), translated through I18n's composed patterns.
func _part_title(id: int, species: String, own_name: String) -> String:
	if own_name != "":
		return I18n.mob_name(own_name)
	var mobs: Variant = RealmContent.table("mobs")
	var entry: Dictionary = (mobs as Dictionary).get("mobs", {}).get(species, {}) if mobs is Dictionary else {}
	var display := String(entry.get("display", species.capitalize()))
	var body: Variant = beasts.get(_part_body(id))
	var key := String((body as CreatureView).parts.get(id, "")) if body is CreatureView else ""
	if not PART_SIDES.has(key):
		return I18n.mob_name(display)
	var words := display.split(" ")
	words.insert(words.size() - 1, String(PART_SIDES[key]))
	return I18n.mob_name(" ".join(words))

## Each multi-part boss in view bends the parts that are down: dead in the
## snapshot, or gone from it after being seen standing.
func _update_boss_parts() -> void:
	for body_id: int in beasts.keys():
		var body: Variant = beasts[body_id]
		if not (body is CreatureView) or (body as CreatureView).parts.is_empty():
			continue
		var down: Array = []
		var owned: Dictionary = (body as CreatureView).parts
		for part: int in owned.keys():
			var entry: Variant = part_states.get(part)
			if entry is Array and int(entry[0]) != CreatureView.STATE_DEAD:
				_parts_seen[part] = true
			elif entry is Array or _parts_seen.has(part):
				down.append(String(owned[part]))
		down.sort()
		(body as CreatureView).set_parts_down(down)

## Show creature `id` on the target card (0 clears the target) and ask the
## server what it is (its own name and its level come back as creature info).
## Another player whose name the client knows shows as itself.
func select_target(id: int) -> void:
	if _player_index(id) >= 0 and not player_identity(id).is_empty():
		target = id
		_show_player_card()
		return
	var i := _creature_index(id)
	target = id if i >= 0 else 0
	if target == 0:
		hud.set_target(0)
		return
	session.inspect(target)
	_show_target_card(i)

## The target card for snapshot index `i`: its name (a boss's, a Dark
## Shard's or a dummy's own, else the species'), what kind of target it is and
## its level, as far as the server has said.
func _show_target_card(i: int) -> void:
	var kind := (others["kinds"] as PackedInt32Array)[i]
	var info: Dictionary = infos.get(target, {})
	var species := CreatureView.species_for_kind(kind)
	var object := String(CreatureView.view_of(species).get("object", ""))
	var own_name := String(info.get("name", ""))
	var title := ""
	var look := {"level": int(info.get("level", 0))}
	var card: Array = []
	match object:
		"stone":
			var beast: Node = beasts.get(target)
			title = I18n.t(own_name if own_name != "" else (String(beast.stone_name) if beast != null else "Dark Shard"))
			look["rank"] = tr("Fallen Star Shard")
			card = CARD_STONE
		"dummy":
			title = I18n.t(own_name if own_name != "" else "Training Dummy")
			look["rank"] = tr("Practice target")
			look["level"] = 0
			card = CARD_DUMMY
		_ when part_states.has(target):
			# a boss's head or vine: its own name and health, under its boss's
			title = _part_title(target, species, own_name)
			var body_id := _part_body(target)
			var body_info: Dictionary = infos.get(body_id, {})
			var body: Variant = beasts.get(body_id)
			var boss_name := String(body_info.get("name", ""))
			if boss_name == "" and body is CreatureView:
				var mobs: Variant = RealmContent.table("mobs")
				boss_name = String((mobs as Dictionary).get("mobs", {}).get((body as CreatureView).species, {}).get("display", "")) 					if mobs is Dictionary else ""
			look["rank"] = I18n.mob_name(boss_name) if boss_name != "" else tr("Creature")
			if int(look["level"]) == 0:
				look["level"] = int(body_info.get("level", 0))
			card = CARD_BOSS
		_:
			title = _species_title(species, own_name)
			var enraged := kind & CreatureView.ENRAGED_BIT != 0
			if kind & CreatureView.BOSS_BIT != 0:
				look["rank"] = tr("World Boss")
				card = CARD_BOSS
			elif enraged:
				look["rank"] = tr("Enraged")
				card = CARD_ENRAGED
			else:
				look["rank"] = tr("Creature")
			if CreatureView.is_elite(kind) and own_name == "":
				title = tr("Elite %s") % title
				look["tint"] = ELITE_NAME_COLOR
			if enraged:
				title += tr(" • ENRAGED")
	if not card.is_empty():
		look["tint"] = card[0]
		look["bar"] = card[1]
		look["icon"] = card[2]
	_target_kind = kind
	hud.set_target(target, title, (others["hp"] as PackedInt32Array)[i], look)

## A creature's name as the player reads it: its own (a boss's) or its
## species' display name (mobs.json, read once: every creature that comes
## into view asks).
static var _mob_displays := {}

static func _species_title(species: String, own_name: String) -> String:
	if own_name != "":
		return I18n.mob_name(own_name)
	if _mob_displays.is_empty():
		var mobs: Variant = RealmContent.table("mobs")
		var entries: Dictionary = (mobs as Dictionary).get("mobs", {}) if mobs is Dictionary else {}
		for key: String in entries:
			_mob_displays[key] = String((entries[key] as Dictionary).get("display", ""))
	var display := String(_mob_displays.get(species, ""))
	return I18n.mob_name(display if display != "" else species.capitalize())

## A creature's plate: level and name ("Elite" before an elite's, " • ENRAGED"
## after an enraged one's) over its head, in its kind's colours. Objects (Dark
## Shards, dummies) carry their own label.
func _plate_creature(id: int, kind: int) -> void:
	var beast := beasts.get(id) as CreatureView
	if beast == null:
		return
	_plate_kinds[id] = kind
	var info: Dictionary = infos.get(id, {})
	var own_name := String(info.get("name", ""))
	var title := _species_title(beast.species, own_name)
	var elite := CreatureView.is_elite(kind)
	if elite and own_name == "":
		title = tr("Elite %s") % title
	if kind & CreatureView.ENRAGED_BIT != 0:
		title += tr(" • ENRAGED")
	plates.set_creature(id, beast, beast.head_height + 0.45, title, int(info.get("level", 0)), elite,
		kind & CreatureView.BOSS_BIT != 0)

## The kind the target card was drawn for (an enrage redraws it), and whether
## a player was drawn as a duel foe (the duel's turns redraw it).
var _target_kind := -1
var _target_foe := false

## The index of player `id` in this frame's snapshot, -1 when it is not one.
func _player_index(id: int) -> int:
	if id == 0 or others.is_empty():
		return -1
	var i := (others["ids"] as PackedInt32Array).find(id)
	return i if i >= 0 and (others["kinds"] as PackedInt32Array)[i] == KIND_PLAYER else -1

## The target card for another player: its name, its house (and "Party" when
## it is in the party) and level as far as the client knows them, and "Invite
## to Party" while it is not in the party.
func _show_player_card() -> void:
	var who := player_identity(target)
	var i := _player_index(target)
	if who.is_empty() or i < 0:
		select_target(0)
		return
	var who_name := String(who["name"])
	var in_party: bool = hud.party_frames.shown_members().any(func(m): return String(m["name"]) == who_name)
	var house := String(who["house"])
	var rank := HudQuestScroll.house_name(house) if house != "" else ""
	var look := {"level": int(who["level"]), "tint": PLAYER_TINT, "bar": PLAYER_BAR, "icon": "ui_target",
		"invite": "" if in_party else who_name, "ga": bool(who["ga"])}
	if in_party:
		rank = tr("%s · Party") % rank
	_target_foe = is_duel_foe(target)
	if _target_foe:
		rank = tr("%s · Duel opponent") % rank
		look["tint"] = DUEL_FOE_TINT
		look["bar"] = DUEL_FOE_BAR
	look["rank"] = rank
	_target_kind = KIND_PLAYER
	hud.set_target(target, who_name, (others["hp"] as PackedInt32Array)[i], look)

## Living creatures and standing duel foes within `reach` of the player,
## nearest first.
func _creatures_near(reach: float) -> Array:
	var me: Vector3 = drawn.get(session.own_entity(), Vector3.ZERO)
	var near: Array = []
	var ids: PackedInt32Array = others.get("ids", PackedInt32Array())
	for i in ids.size():
		if _creature_index(ids[i]) < 0 and not is_duel_foe(ids[i]):
			continue
		var distance := me.distance_to((others["positions"] as PackedVector3Array)[i])
		if distance <= reach:
			near.append([distance, ids[i]])
	near.sort_custom(func(a, b): return a[0] < b[0])
	return near.map(func(pair): return pair[1])

## Tab: the next of the nearest living creatures and standing duel foes, from
## the current target.
func cycle_target() -> void:
	var near := _creatures_near(TAB_RANGE)
	if near.is_empty():
		select_target(0)
		return
	select_target(near[(near.find(target) + 1) % near.size()])

## The target card follows the snapshot; a dead or vanished target is dropped.
func _follow_target() -> void:
	if target == 0:
		return
	var p := _player_index(target)
	if p >= 0 and not player_identity(target).is_empty():
		if is_duel_foe(target) != _target_foe:
			_show_player_card()
		hud.set_target_health((others["hp"] as PackedInt32Array)[p])
		hud.set_target_statuses((others["statuses"] as PackedInt32Array)[p])
		return
	var i := _creature_index(target)
	if i < 0:
		select_target(0)
		return
	if (others["kinds"] as PackedInt32Array)[i] != _target_kind:
		_show_target_card(i)
	hud.set_target_health((others["hp"] as PackedInt32Array)[i])
	hud.set_target_statuses((others["statuses"] as PackedInt32Array)[i])

## The ring under the target: a creature's sized to it (a boss wide, violet),
## another player's pale blue; a boss's head or vine rings its boss's feet.
func _follow_ring() -> void:
	var id := target
	if id == 0 or not drawn.has(id):
		target_ring.follow(0, Vector3.ZERO, 0.0, TargetRing.GOLD)
		return
	if _player_index(id) >= 0:
		target_ring.follow(id, drawn[id], 1.0, TargetRing.ALLY)
		return
	var feet: Vector3 = drawn[id]
	var kind := _target_kind
	var boss := kind >= 0 and kind & CreatureView.BOSS_BIT != 0
	var species := CreatureView.species_for_kind(kind) if kind >= 0 else ""
	if part_states.has(id):
		var body := _part_body(id)
		if drawn.has(body):
			feet = drawn[body]
		boss = true
	elif bool((infos.get(id, {}) as Dictionary).get("boss", false)):
		boss = true
	target_ring.follow(id, feet, TargetRing.radius_for(species, boss), TargetRing.BOSS if boss else TargetRing.GOLD)

## The frame's combat events, taken once and handed to everything that shows
## them.
func _show_combat() -> void:
	var own := int(session.own_entity())
	combat.own_id = own
	combat.drawn = drawn
	combat.note_health(session.vitals())
	for event: Dictionary in session.take_combat_events():
		combat.show_event(event)
		world_audio.on_combat(event)
		if audio_check != null:
			audio_check.on_combat(event)
		if duel_check != null:
			duel_check.on_combat(event)
		if game_menu != null:
			game_menu.on_combat(event)
		match String(event["kind"]):
			"hit":
				hud.on_hit(event)
				var body: Node = beasts.get(int(event["target"]))
				if body != null and body.has_method("on_hit"):
					body.on_hit(event, int(event["attacker"]) == own)
				if int(event["attacker"]) == own:
					check_hits += 1
					check_hp = int(event["hp"])
					check_hit_ids[int(event["target"])] = true
					var hit_index := _creature_index(int(event["target"]))
					if hit_index >= 0 and String(event["spell"]) == "shockwave":
						check_thrown_at[int(event["target"])] = (others["kinds"] as PackedInt32Array)[hit_index]
			"cast_started":
				if int(event["caster"]) == own:
					check_casts += 1
			"burst":
				if int(event["caster"]) == own:
					check_bursts += 1
			"cast_refused":
				var refused := String(event["reason"])
				check_refusals[refused] = int(check_refusals.get(refused, 0)) + 1
				_say_refusal(String(event["spell"]), refused)

## ------------------------------------------------------ creatures and the map

## The body for a creature of snapshot `kind`: its model (CreatureView), a Dark
## Shard (StoneView) or a dummy (DummyView); null when this client has no model
## for it yet. A boss or an object is asked what it is (its boss body's size,
## its own name) as it first appears.
func _new_beast(id: int, kind: int) -> Node3D:
	var view := CreatureView.view_for_kind(kind)
	var object := String(view.get("object", ""))
	var beast: Node3D = load(String(OBJECT_VIEWS.get(object, CreatureViewScript))).new()
	add_child(beast)
	if not beast.setup(kind):
		beast.queue_free()
		return null
	if object == "stone":
		beast.observer = player
		beast.shake = shake_camera
	if infos.has(id):
		beast.apply_info(infos[id])
	# What it is (its level for the plate, a boss's body and size, an object's
	# own name; a multi-part boss also says which entities are its parts),
	# asked again each time it comes into view.
	session.inspect(id)
	return beast

## Answers to inspect: kept, handed to the body, and the target card redrawn
## when it is the target's.
func _take_creature_info() -> void:
	for info: Dictionary in session.take_creature_info():
		var id := int(info["entity"])
		if bool(info.get("player", false)):
			# the player's own answer comes too (asked at join, and again
			# unasked when its GA emblem comes or goes)
			var ga := bool(info.get("ga", false))
			if others_check != null:
				others_check.on_player_info(info)
			if id == int(session.own_entity()):
				own_ga = ga
				# a title earned since the last answer (not the first: those
				# were held already)
				if not own_info.is_empty():
					for title: Variant in info.get("titles", []):
						if not (own_info.get("titles", []) as Array).has(title):
							_title_earned(String(title))
				own_info = info
				player.set_ga(ga)
				hud.unit_frame.set_ga(ga)
				_plate_player(id, player, info, true)
				continue
			player_infos[id] = info
			player_names[id] = String(info["name"])
			_dress_player(id)
			if id == target:
				_show_player_card()
			continue
		infos[id] = info
		check_infos += 1
		var beast: Node = beasts.get(id)
		if beast != null:
			beast.apply_info(info)
			if beast is CreatureView:
				_plate_creature(id, int(_plate_kinds.get(id, 0)))
			if bool(info.get("boss", false)) and beast is CreatureView:
				var body := beast as CreatureView
				check_bosses[id] = "%s %s x%.2f" % [info.get("boss_key", ""), body.model.scene_file_path.get_file(),
					body.model.scale.x]
		if id == target:
			var i := _creature_index(id)
			if i >= 0:
				_show_target_card(i)

## A new title (a first clear, the week's record): the old game's gold line
## rising over the player, and a toast that stays a while.
func _title_earned(id: String) -> void:
	var text := tr("New title: %s") % I18n.t(DungeonData.title_name(id))
	titles_toasted.append(id)
	FloatingText.word(player.global_position + Vector3(0, 2.6, 0), text, Color(1.0, 0.82, 0.4), 1.4, 2.2,
		Nameplates.HERO_HEIGHT - 2.6)
	feedback.toast(text, Color(1.0, 0.82, 0.4), "ui_quest")
	AudioManager.play_levelup()

## The kill loop's messages: a kill's reward (the toasts, the level-up moment),
## a chest's cells and the answers to takes (the chest window), a death (the
## death panel), the answer to a status point (the character window) and to a
## quest claim (a refusal on the notice band). The check counts them.
func _show_game_events() -> void:
	for event: Dictionary in session.take_game_events():
		if check_seconds > 0.0:
			# the frame each message lands on (a --write-movie capture's index)
			print("realm check event: frame %d %s" % [Engine.get_frames_drawn(), event["kind"]])
		match String(event["kind"]):
			"travel_result", "departing", "travel", "arrived", "waylink":
				travel.on_event(event)
				if travel_check != null:
					travel_check.on_event(event)
				if dungeon_check != null:
					dungeon_check.on_event(event)
			"dungeon":
				dungeon.on_event(event)
				if dungeon_check != null:
					dungeon_check.on_event(event)
			"reward":
				check_exp += int(event["exp"])
				check_oril += int(event["oril"])
				check_levels += int(event["levels"])
				if not (event["items"] as Array).is_empty():
					check_loot_items += 1
				feedback.on_reward(event)
			"chest":
				loot_window.on_chest(int(event["chest"]), event["slots"])
			"loot_result":
				var reason := String(event["reason"])
				check_loot_results[reason] = int(check_loot_results.get(reason, 0)) + 1
				if loot_window.visible and loot_window.chest_id == int(event["chest"]):
					loot_window.on_result(int(event["chest"]), bool(event["ok"]), reason)
				elif reason == "bag_full":
					# a Z take: the window is not there to say it (the deny
					# sound as the window's take has it)
					hud.show_notice(tr("Your bag is full."), "warn")
					AudioManager.play_deny()
				elif reason == "out_of_range":
					hud.show_notice(tr("Too far away."), "warn")
					AudioManager.play_deny()
			"death":
				check_deaths += 1
				if check_fell_at == 0.0:
					check_fell_at = Time.get_ticks_msec() / 1000.0
				loot_window.close()
				select_target(0)
				feedback.on_death(event)
			"attribute_result":
				var answer := String(event["reason"])
				check_attribute_results[answer] = int(check_attribute_results.get(answer, 0)) + 1
				if answer == "dead":
					# fell while the request was on its way: the check asks again
					check_spend_sent = false
				character_window.on_result(event)
			"party_invite":
				hud.invites.push("party", String(event["from"]))
			"duel_invite":
				hud.invites.push("group_duel" if bool(event["group"]) else "duel", String(event["from"]),
					int(event["size"]))
			"duel":
				# The duel names its sides: the player menu and the target card know them.
				for side: String in ["allies", "foes"]:
					for who: Dictionary in event.get(side, []):
						var id := int(who["entity"])
						if id != int(session.own_entity()) and not player_names.has(id):
							player_names[id] = String(who["name"])
				hud.duel_view.on_event(event)
			"party":
				hud.party_frames.show_party(session.party())
				if _player_index(target) >= 0:
					_show_player_card()
			"quest_result":
				var why := String(event["reason"])
				check_quest_results[why] = int(check_quest_results.get(why, 0)) + 1
				if bool(event["ok"]):
					check_claimed.append(String(event["quest"]))
				elif QUEST_REASONS.has(why):
					hud.show_notice(I18n.t(String(QUEST_REASONS[why])), "warn")

## ------------------------------------------------------------------ chat

## The frame's chat lines into the log; a local line also rises over its
## speaker's head and names that player for the menu and the target card.
func _show_chat() -> void:
	var own := int(session.own_entity())
	for line: Dictionary in session.take_chat():
		var channel := int(line["channel"])
		var from := String(line["from"])
		var text := String(line["text"])
		var speaker := int(line["speaker"])
		hud.chat.add_line(channel, from, text, _house_of(from))
		if channel != HudChat.LOCAL or speaker == 0:
			continue
		if speaker != own:
			player_names[speaker] = from
		var body: Node3D = player if speaker == own else heroes.get(speaker)
		if body != null:
			SpeechBubble.say(body, text)

## A speaker's house when the client knows it (the player, a party member),
## else empty.
func _house_of(who: String) -> String:
	var sheet: Dictionary = session.sheet()
	if not sheet.is_empty() and String(sheet["name"]) == who:
		return String(sheet["house"])
	return String(hud.party_frames.member_named(who).get("house", ""))

## ------------------------------------------------------------- loot chests

## A chest stands on the ground under the place the server gives it (it drops
## a chest a little above the creature's feet): a short ray down from just
## under that place, which leaves the chest's own body out.
func _ground(at: Vector3) -> Vector3:
	var start := at - Vector3(0, 0.25, 0)
	var hit: Dictionary = session.pick(start, Vector3.DOWN, 1.5)
	if hit.is_empty() or int(hit["entity"]) != 0:
		return at
	var point: Vector3 = hit["point"]
	return point if start.y - point.y < 1.49 else at

## How far chest `id` is from the player, on the ground (INF when it is gone).
func _chest_distance(id: int) -> float:
	var chest: Node3D = chests.get(id)
	if chest == null:
		return INF
	var me: Vector3 = session.own_position()
	return Vector2(chest.position.x - me.x, chest.position.z - me.z).length()

## A right click on the world: a chest under the cursor opens, another
## player gets the player menu.
func right_click_world(at: Vector2) -> void:
	var hit := pick_at(at)
	if hit.is_empty():
		return
	var entity := int(hit["entity"])
	if chests.has(entity):
		open_chest_window(entity)
	elif heroes.has(entity):
		open_player_menu(entity, at)

## The player menu on player `id` at screen point `at`: within
## HudPlayerMenu.RANGE of the player's body (the range that keeps it open),
## and only when the client knows that player's name.
func open_player_menu(id: int, at: Vector2) -> void:
	var who := player_identity(id)
	if heroes.has(id) and not who.is_empty():
		hud.player_menu.open(heroes[id], who, at)

## What the client knows of player `id`: {name, level, house} from the
## server's answer when it came into view (a party member's frame is newer
## for its level), or {} before that answer.
func player_identity(id: int) -> Dictionary:
	var who := String(player_names.get(id, ""))
	if who == "":
		return {}
	var info: Dictionary = player_infos.get(id, {})
	var member: Dictionary = hud.party_frames.member_named(who)
	return {"name": who, "level": int(member.get("level", info.get("level", 0))),
		"house": String(member.get("house", info.get("house", ""))), "ga": bool(info.get("ga", false))}

## The chest window on chest `id`, when the player stands close enough.
func open_chest_window(id: int) -> void:
	var chest: ChestView = chests.get(id)
	if chest == null or feedback.is_dead():
		return
	if _chest_distance(id) > ChestView.PICK_RANGE:
		FloatingText.word(player.global_position + Vector3(0, 2.4, 0), tr("Too far"), Color(1.0, 0.85, 0.5), 1.0, 1.0,
			Nameplates.HERO_HEIGHT - 2.4)
		return
	loot_window.open_chest(id, chest.chest_kind == "chest_rare")
	# the lid swings up and stays up while the window is on this chest
	chest.open_lid(func() -> bool: return loot_window.visible and loot_window.chest_id == id)

## Z: everything that fits from the nearest chest within PICKUP_REACH.
func take_nearest_chest() -> void:
	check_loot_presses += 1
	var best := 0
	var best_distance := PICKUP_REACH
	for id: int in chests:
		var distance := _chest_distance(id)
		if distance < best_distance:
			best_distance = distance
			best = id
	if best == 0:
		return
	(chests[best] as ChestView).open_lid()
	if loot_window.visible and loot_window.chest_id == best:
		loot_window.take(-1)   # the window's own take: its sound, its answers
		return
	session.take_loot(best, -1)
	AudioManager.play_sound_at("ui_loot", Vector3.ZERO, null, true)   # once, as the window's take

## What the map announced, on the notice band in the old game's words:
## a world boss stirring, rising and falling (with its horn), a Dark Shard's
## wave and its shatter. The server sends the numbers (seconds, level, wave)
## and who felled it; where a world boss rises comes from the content.
func _show_notices() -> void:
	for notice: Dictionary in session.take_notices():
		var kind := String(notice["kind"])
		check_notices[kind] = int(check_notices.get(kind, 0)) + 1
		if kind == "maintenance":
			maintenance.on_notice(notice)
			continue
		if kind in ["sanction", "social", "blocks"]:
			_moderation_notice(notice)
			continue
		if kind == "update_soon":
			var soon := tr("An update is on its way: the realm restarts in about %d minutes.") % int(notice["value"])
			hud.show_notice(soon, "update")
			hud.chat.add_system_line(soon)
			continue
		var said := notice_text(notice)
		var text := String(said[0])
		match kind:
			"boss_spawned":
				AudioManager.play_stinger("stinger_boss")
			"boss_slain":
				AudioManager.play_stinger("stinger_victory")
			"stone_wave":
				var stone: StoneView = _stone_named(String(notice["subject"]))
				if stone != null:
					stone.on_wave()
		if text == "":
			continue
		hud.show_notice(text, String(said[1]))
		# The realm's own news (a world boss anywhere, a Legendary gold) is
		# also written in the chat, as the old game did.
		if String(notice.get("place", "")) != "":
			hud.chat.add_system_line(tr("[World] ") + text)
			world_lines.append(text)

## World news lines written in the chat (the check reads them).
var world_lines: Array = []

## A notice in the old game's words: [text, band]. The server sends the
## numbers (seconds, level, wave), who felled it (`actor`) and, for the
## realm's own news, the map it came from (`place`); where a world boss
## rises comes from the content.
func notice_text(notice: Dictionary) -> Array:
	var kind := String(notice.get("kind", ""))
	var subject := String(notice.get("subject", ""))
	var name := I18n.t(subject)
	var actor := String(notice.get("actor", ""))
	match kind:
		"boss_soon":
			return [tr("%s stirs at %s - %d seconds!") % [name, I18n.t(_boss_site(subject)["region"]), int(notice.get("value", 0))],
				"boss"]
		"boss_spawned":
			return [tr("%s has appeared at %s (Lv %d)!") % [name, I18n.t(_boss_site(subject)["region"]), int(notice.get("value", 0))],
				"boss"]
		"boss_slain":
			if actor != "":
				return [tr("%s has been slain by %s!") % [name, actor], "boss"]
			return [tr("%s has fallen!") % name, "boss"]
		"dungeon_legend":
			# subject: the dungeon's name; actor: who ran it
			return [tr("%s won Legendary gold in %s!") % [actor, name], "boss"]
		"stone_wave":
			return [tr("%s: a wave of creatures answers its call! (Wave %d/%d)") % [name, int(notice.get("value", 0)),
				int(notice.get("of", 0))], "stone"]
		"stone_shattered":
			var by := actor if actor != "" else tr("A brave Wizard")
			return [tr("The %s has been shattered by %s! Riches shower the realm!") % [name, by], "stone"]
	return ["", ""]

## Where world boss `boss_name` rises: {region, level} from its pack
## (spawn_tables.json packs with world_boss, boss_overrides for the name,
## regions for the place's name).
func _boss_site(boss_name: String) -> Dictionary:
	if _boss_sites.is_empty():
		var tables: Variant = RealmContent.table("spawn_tables")
		if tables is Dictionary:
			var regions := {}
			for region: Dictionary in (tables as Dictionary).get("regions", []):
				regions[String(region.get("id", ""))] = String(region.get("display", region.get("id", "")))
			var bosses: Dictionary = (tables as Dictionary).get("boss_overrides", {})
			for pack: Dictionary in (tables as Dictionary).get("packs", []):
				if not bool(pack.get("world_boss", false)):
					continue
				var boss: Dictionary = bosses.get(String(pack.get("boss_key", "")), {})
				var zone := String(pack.get("zone", ""))
				_boss_sites[String(boss.get("name", ""))] = {"region": String(regions.get(zone, zone)),
					"level": int(pack.get("level", 1))}
	return _boss_sites.get(boss_name, {"region": "the wilds", "level": 1})

## The Dark Shard called `stone_name` nearest the player (the notice comes
## from one in view).
func _stone_named(stone_name: String) -> StoneView:
	var me: Vector3 = drawn.get(session.own_entity(), Vector3.ZERO)
	var best: StoneView = null
	var best_distance := INF
	for beast: Node3D in beasts.values():
		if beast is StoneView and (beast as StoneView).stone_name == stone_name:
			var distance := me.distance_to(beast.global_position)
			if distance < best_distance:
				best_distance = distance
				best = beast as StoneView
	return best

## A jolt of the camera that settles back (a Dark Shard landing close by).
func shake_camera(strength: float) -> void:
	if _shaking != null and _shaking.is_running():
		return
	strength *= GameSettings.shake_value()
	if strength <= 0.0:
		return
	camera.h_offset = randf_range(-strength, strength) * SHAKE_SWING
	camera.v_offset = randf_range(-strength, strength) * SHAKE_SWING
	_shaking = create_tween()
	_shaking.tween_property(camera, "h_offset", 0.0, SHAKE_SETTLE)
	_shaking.parallel().tween_property(camera, "v_offset", 0.0, SHAKE_SETTLE)

## Stunned or thrown (own_body `held`): the server refuses every cast, so none
## is sent and the notice band says why, at most every HELD_NOTICE_SECONDS.
func _held_refusal() -> bool:
	var own: Dictionary = session.own_body()
	if not bool(own.get("held", false)):
		return false
	var now := Time.get_ticks_msec() / 1000.0
	if now >= _held_notice_at:
		_held_notice_at = now + HELD_NOTICE_SECONDS
		var bits := int(own.get("status", 0))
		var text := tr("You are stunned!")
		if bits & StatusFX.STATUS_KNOCKED:
			text = tr("You were knocked off your feet!")
		elif bits & StatusFX.STATUS_FREEZE:
			text = tr("You are frozen!")
		hud.show_notice(text, "warn")
		AudioManager.play_deny()
	return true

## Why a cast of the player's was refused, on the notice band (a cooldown or an
## unknown spell needs no words).
func _say_refusal(spell: String, reason: String) -> void:
	var data: Dictionary = HudActionBar.spells().get(spell, {})
	var text := ""
	match reason:
		"no_mana":
			text = tr("Not enough Mana!")
		"mounted":
			text = tr("Not while mounted!")
		"no_wand":
			text = tr("Equip a wand first")
		"level":
			text = tr("Your level is too low for that spell")
		"skill_locked":
			text = tr("Learn %s first - click its slot to spend a skill point") % I18n.t(String(data.get("name", spell)))
	if text != "":
		hud.show_notice(text, "warn")
		AudioManager.play_deny()

## The check fights the nearest creature: a new target when it has none, a
## basic cast every CHECK_CAST_SECONDS.
func _check_fight(delta: float) -> void:
	check_cast_wait -= delta
	if check_cast_wait > 0.0:
		return
	check_cast_wait = CHECK_CAST_SECONDS
	if target == 0:
		var near := _creatures_near(INF)
		if check_target_species != "":
			# `--check-target`: the nearest of that species when one is in view
			var kinds: PackedInt32Array = others.get("kinds", PackedInt32Array())
			var ids: PackedInt32Array = others.get("ids", PackedInt32Array())
			var wanted := near.filter(func(id): return CreatureView.species_for_kind(kinds[ids.find(id)]) == check_target_species)
			if not wanted.is_empty():
				near = wanted
		if not near.is_empty():
			select_target(near[0])
	if bool(session.own_body().get("held", false)):
		# stunned or thrown: nothing can be cast until the body is free
		return
	if not check_learn_sent:
		check_learn_sent = true
		session.learn_skill("shockwave")
	if target != 0:
		if not check_shockwave_cast and int(session.skill_level("shockwave")) > 0:
			check_shockwave_cast = true
			cast_spell("shockwave")
		elif not check_spells.is_empty():
			cast_spell(check_spells[check_spell_next % check_spells.size()])
			check_spell_next += 1
		else:
			cast_spell("basic_cast")

## The check's side of the kill loop: fallen, it rises the way --check-rise
## says once the death panel lets it (or waits for the server's return to
## town); standing, it spends a status point when it has one.
func _check_kill_loop() -> void:
	if feedback.is_dead():
		if check_rise != "auto" and feedback.can_rise():
			check_rises_asked += 1
			feedback.press_rise(check_rise == "here")
		return
	var sheet: Dictionary = session.sheet()
	if not sheet.is_empty() and int(sheet.get("attribute_points", 0)) > 0:
		check_had_points = true
		if not check_spend_sent:
			check_spend_sent = true
			character_window.spend("vit")

## Chests the check gave up on (it could not take everything).
var check_loot_skip := {}
## Chests it asked to take from (a vanish after a take counts).
var check_taken_from := {}
var check_loot_since := 0.0

## The check walks to the nearest chest that dropped, opens it, shows what it
## holds for CHECK_LOOT_SHOW and takes everything. Returns the steering yaw
## toward the chest, INF to stand at it, NAN with no chest to go to.
func _check_loot_steer() -> float:
	if feedback.is_dead():
		check_loot_target = 0
		return NAN
	var now := Time.get_ticks_msec() / 1000.0
	if check_loot_target != 0 and (not chests.has(check_loot_target) or now - check_loot_since > 25.0):
		if chests.has(check_loot_target):
			check_loot_skip[check_loot_target] = true
		check_loot_target = 0
	if check_loot_target == 0:
		var best_distance := 60.0
		for id: int in chests:
			var distance := _chest_distance(id)
			if not check_loot_skip.has(id) and distance < best_distance:
				best_distance = distance
				check_loot_target = id
		check_loot_shown_at = 0.0
		check_loot_taken = false
		check_loot_since = now
	if check_loot_target == 0:
		return NAN
	var chest: ChestView = chests[check_loot_target]
	var me: Vector3 = session.own_position()
	var flat := Vector2(chest.position.x - me.x, chest.position.z - me.z)
	if flat.length() > CHECK_LOOT_REACH:
		return atan2(-flat.x, -flat.y)
	if not loot_window.visible or loot_window.chest_id != check_loot_target:
		if not check_loot_taken:
			open_chest_window(check_loot_target)
			check_loot_shown_at = now
	elif not check_loot_taken and now - check_loot_shown_at >= CHECK_LOOT_SHOW:
		check_loot_taken = true
		check_taken_from[check_loot_target] = true
		loot_window.take(-1)
	elif check_loot_taken and int(check_loot_results.get("bag_full", 0)) > 0:
		check_loot_skip[check_loot_target] = true
		check_loot_target = 0
	return INF

## The status bits every creature in view carries this frame, gathered for the
## check's verdict.
func _check_statuses(ids: PackedInt32Array, kinds: PackedInt32Array, statuses: PackedInt32Array) -> void:
	for i in ids.size():
		if kinds[i] == KIND_PLAYER or statuses[i] == 0:
			continue
		check_statuses[ids[i]] = int(check_statuses.get(ids[i], 0)) | statuses[i]
		if ids[i] == target:
			check_target_statuses |= statuses[i]

## The status bits seen on any creature the check's hits landed on.
func _check_hit_statuses() -> int:
	var seen := 0
	for id in check_hit_ids:
		seen |= int(check_statuses.get(id, 0))
	return seen

## Whether the check's Shockwave landed on a creature that can be thrown: the
## server never throws a boss, a Dark Shard, a dummy or a species with full
## displace_resist (mobs.json), so a blast on Grak or a stone alone shows none.
func _check_hit_throwable() -> bool:
	var mobs: Variant = RealmContent.table("mobs")
	for id in check_thrown_at:
		var kind := int(check_thrown_at[id])
		var species := CreatureView.species_for_kind(kind)
		if kind & CreatureView.BOSS_BIT != 0 or CreatureView.view_of(species).has("object"):
			continue
		var entry: Dictionary = (mobs as Dictionary).get("mobs", {}).get(species, {}) if mobs is Dictionary else {}
		if float(entry.get("displace_resist", 0.0)) < 1.0:
			return true
	return false

## Counts by key as "taken x2, bag_full x1".
static func _counts(table: Dictionary) -> String:
	return ", ".join(table.keys().map(func(k): return "%s x%d" % [k, table[k]]))

## The kill loop's part of the verdict: a chest that dropped early enough to
## be reached was emptied (a reward with items) and vanished; a status point
## it had was spent; a fall was followed by a rise once one was due.
func _check_loop_passed() -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	var reachable := check_chests_seen.values().any(func(at): return now - float(at) > 15.0)
	var loot_ok := not reachable or (check_loot_items > 0 and check_chests_vanished > 0)
	var points_ok := not check_had_points or check_attribute_results.has("spent")
	var death: Dictionary = ItemRules.combat().get("death", {})
	var due := float(death.get("auto_respawn_ms" if check_rise == "auto" else "respawn_ms", 3000)) / 1000.0 + 5.0
	var rise_ok: bool = check_fell_at == 0.0 or feedback.rises_shown > 0 or now - check_fell_at < due
	return loot_ok and points_ok and rise_ok

## Status bits as names: "stun+knocked".
static func _status_names(bits: int) -> String:
	var names := PackedStringArray()
	for pair in [[StatusFX.STATUS_STUN, "stun"], [StatusFX.STATUS_FREEZE, "freeze"], [StatusFX.STATUS_SLOW, "slow"],
			[StatusFX.STATUS_BLEED, "bleed"], [StatusFX.STATUS_BURN, "burn"], [StatusFX.STATUS_POISON, "poison"],
			[StatusFX.STATUS_KNOCKED, "knocked"], [StatusFX.STATUS_WEAK, "weak"]]:
		if bits & int(pair[0]):
			names.append(String(pair[1]))
	return "+".join(names) if not names.is_empty() else "none"

## ------------------------------------------------------ the quest check

## `--check-quests`: the first chapter the way a player walks it, one step at a
## time, each window left up for CHECK_SHOW so a capture sees it:
##   to_npc   walk to Master Teral Venn (his gold arrow) and press F: the
##            dialogue card opens and the server hears the talk (q001)
##   talk     turn the pages until q001 is ready, then its "Hand in" row
##   scroll1  the quest scroll; its gold seal claims q001 (the cloak)
##   equip    the bag opens and the cloak goes on (q002)
##   claim2   the ready tracker row claims q002, then the log (J) shows
##   to_dummy walk into the training yard (CHECK_YARD_ROUTE) and target
##            the nearest dummy
##   hit      basic casts until q003 is ready; its log card opens the scroll
##   scroll3  the seal claims q003; the check stands a little, then ends
## Returns whether to walk forward this frame (cam_yaw steers).
func _check_quest_walk(_delta: float) -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	var held := now - check_step_since
	var me: Vector3 = session.own_position()
	match check_quest_step:
		"start":
			if sheet_view.data.has("quests") and not npcs.is_empty():
				_check_step("to_npc")
		"to_npc":
			var npc := _npc_named("Master Teral Venn")
			if npc == null:
				return false
			var flat := Vector2(npc.position.x - me.x, npc.position.z - me.z)
			cam_yaw = atan2(-flat.x, -flat.y)
			if flat.length() > CHECK_NPC_REACH:
				return true
			if held > 0.5:
				talk_to(_npc_near(TALK_KEY_REACH))
				_check_step("talk")
		"talk":
			check_page_wait -= _delta
			if check_page_wait <= 0.0:
				check_page_wait = 1.0
				dialogue.advance()
			if quests.is_ready("q001") and held > CHECK_SHOW * 2.0:
				for row: Dictionary in dialogue.quest_rows:
					if String(row["id"]) == "q001":
						(row["button"] as Button).pressed.emit()
						_check_step("scroll1")
		"scroll1":
			if held > CHECK_SHOW and quest_scroll.can_claim():
				quest_scroll.press_claim()
				_check_step("claim1")
		"claim1":
			if check_claimed.has("q001") and held > 0.5:
				inventory.open_for_player(sheet_view)
				_check_step("equip")
		"equip":
			if not check_equip_sent and held > 1.0:
				for entry: Dictionary in sheet_view.inventory:
					if String(entry["id"]) == "cloak_wool":
						check_equip_sent = sheet_view.submit("equip", "chest", entry) != 0
						break
			if quests.is_ready("q002") and held > CHECK_SHOW:
				inventory.hide()
				_check_step("claim2")
		"claim2":
			if held > CHECK_SHOW and not check_tracker_pressed:
				check_tracker_pressed = true
				for i in HudTracker.MAX_ROWS:
					if tracker.row_id(i) == "q002":
						tracker._rows[i].pressed.emit()
						break
			if check_claimed.has("q002") and held > CHECK_SHOW + 0.5:
				quest_log.open()
				_check_step("log")
		"log":
			if held > CHECK_SHOW * 1.5:
				quest_log.close()
				_check_step("to_dummy")
		"to_dummy":
			if check_route_next < CHECK_YARD_ROUTE.size():
				var point: Vector2 = CHECK_YARD_ROUTE[check_route_next]
				var flat := Vector2(point.x - me.x, point.y - me.z)
				if flat.length() <= CHECK_WAYPOINT_REACH:
					check_route_next += 1
					print("realm check quests: waypoint %d at %s" % [check_route_next, me.snapped(Vector3(0.1, 0.1, 0.1))])
					return check_route_next < CHECK_YARD_ROUTE.size()
				else:
					cam_yaw = atan2(-flat.x, -flat.y)
					_check_say_walk(me, Vector3(point.x, me.y, point.y))
					return true
			_check_nearest_dummy()
			if check_dummy_id != 0:
				select_target(check_dummy_id)
				_check_step("hit")
		"hit":
			if drawn.has(check_dummy_id):
				var at: Vector3 = drawn[check_dummy_id]
				cam_yaw = atan2(-(at.x - me.x), -(at.z - me.z))
			if quests.is_ready("q003"):
				if held > 1.0:
					quest_log.open()
					quest_log.open_scroll.call("q003")
					_check_step("scroll3")
			else:
				check_cast_wait -= _delta
				if check_cast_wait <= 0.0:
					check_cast_wait = CHECK_CAST_SECONDS
					if target != check_dummy_id:
						select_target(check_dummy_id)
					check_dummy_casts += 1
					cast_spell("basic_cast")
		"scroll3":
			if held > CHECK_SHOW and quest_scroll.can_claim():
				quest_scroll.press_claim()
				quest_log.close()
				_check_step("claim3")
		"claim3":
			if check_claimed.has("q003"):
				check_quest_done_at = now
				_check_step("done")
	return false

## The check's sidestep: walking without gaining CHECK_STALL_METRES in
## CHECK_STALL_SECONDS strafes (alternating sides) for CHECK_SIDESTEP_SECONDS
## while it keeps walking forward, which slides it round what is in the way.
func _check_sidestep(walking: bool) -> float:
	var now := Time.get_ticks_msec() / 1000.0
	var me: Vector3 = session.own_position()
	if not walking:
		check_walk_from = Vector3.INF
		return 0.0
	if now < check_strafe_until:
		return check_strafe
	if check_walk_from == Vector3.INF:
		check_walk_from = me
		check_walk_at = now
	elif now - check_walk_at >= CHECK_STALL_SECONDS:
		if Vector2(me.x - check_walk_from.x, me.z - check_walk_from.z).length() < CHECK_STALL_METRES:
			check_strafe = check_strafe_side
			check_strafe_side = -check_strafe_side
			check_strafe_until = now + CHECK_SIDESTEP_SECONDS
			print("realm check quests: stalled at %s, sidestepping" % me.snapped(Vector3(0.1, 0.1, 0.1)))
		check_walk_from = me
		check_walk_at = now
	return 0.0

## Where the walk is, now and then (a walk that stalls shows where).
func _check_say_walk(me: Vector3, goal: Vector3) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if now - check_walk_said >= CHECK_WALK_REPORT:
		check_walk_said = now
		print("realm check quests: walking at %s, %.1f m to %s" % [me.snapped(Vector3(0.1, 0.1, 0.1)),
			Vector2(goal.x - me.x, goal.z - me.z).length(), goal.snapped(Vector3(0.1, 0.1, 0.1))])

func _check_step(step: String) -> void:
	print("realm check quests: frame %d step %s at %s" % [Engine.get_frames_drawn(), step,
		(session.own_position() as Vector3).snapped(Vector3(0.1, 0.1, 0.1))])
	check_quest_step = step
	check_step_since = Time.get_ticks_msec() / 1000.0

func _npc_named(npc_name: String) -> NpcView:
	for npc: NpcView in npcs:
		if npc.npc_name == npc_name:
			return npc
	return null

## The training dummy nearest the player among those in view becomes
## check_dummy_id (q003's target).
func _check_nearest_dummy() -> void:
	var me: Vector3 = session.own_position()
	var best_distance := INF
	for id: int in check_dummies:
		if beasts.has(id) and beasts[id] is DummyView and drawn.has(id):
			var distance := me.distance_to(drawn[id])
			if distance < best_distance:
				best_distance = distance
				check_dummy_id = id

## The quest check's verdict: the quests the server paid, the house standing,
## and the connection; it passes with q001-q003 claimed and no correction.
func _check_quests_verdict(stats: Dictionary, sheet: Dictionary) -> void:
	if check_verdict_given:
		return
	check_verdict_given = true
	var wanted := ["q001", "q002", "q003"]
	var missing := wanted.filter(func(id): return not check_claimed.has(id))
	print("realm check quests: claimed [%s], missing [%s] | house %s rep %d, rank %d %s (%d..%d) | done %s | open log [%s]" % [
			", ".join(check_claimed), ", ".join(missing), sheet.get("house", "-"), int(sheet.get("house_rep", 0)),
			int(sheet.get("house_rank", 0)), sheet.get("house_title", ""), int(sheet.get("rank_from", 0)), int(sheet.get("rank_to", -1)),
			", ".join(sheet.get("quests_done", [])),
			", ".join((sheet.get("quests", []) as Array).map(func(q): return "%s %s %d/%d" % [q["id"], q["state"], q["progress"], q["count"]]))],
		" | step %s, %d talks, %d claims sent, results [%s], %d dummy casts (%d started, refused [%s]), %d own hits" % [
			check_quest_step, check_talks, quests.claims_sent, _counts(check_quest_results), check_dummy_casts, check_casts,
			_counts(check_refusals), check_hits],
		" | level %d, +%d exp, +%d oril, %d toasts, last \"%s\", wears %s" % [int(sheet.get("level", 0)), check_exp, check_oril,
			feedback.toasts_shown, feedback.last_toast, (sheet.get("equipment", {}) as Dictionary).get("chest", {}).get("id", "-")],
		" | corrections %d (max %.3f m), snapshots %d" % [int(stats.get("corrections", 0)), float(stats.get("max_correction", 0.0)),
			int(stats.get("snapshots", 0))])
	var passed := missing.is_empty() and int(stats.get("corrections", 0)) == 0 and int(stats.get("snapshots", 0)) > 0
	get_tree().quit(0 if passed else 1)

## A check (other than `--check-ops`, which looks at the end screen itself)
## fails at once when its session is refused or closed.
func _quits_when_closed() -> bool:
	var args := OS.get_cmdline_user_args()
	if args.has("--check-ops"):
		return false
	# the release smoke goes the player's way: a failed join is tried again,
	# and the check fails on the end screen (PlayCheck)
	return check_seconds > 0.0 or Array(args).any(func(a): return (String(a).begins_with("--check") \
		and a != "--check-play") or String(a).ends_with("-guest"))

func _process(delta: float) -> void:
	if session == null:
		return
	var status: String = session.status()
	var clock := Time.get_ticks_msec() / 1000.0
	if status == "connecting" and not travel.leaving and clock - _join_began > JOIN_TIMEOUT:
		# the map server refuses a claim the coordinator never answers
		# sooner (20 s); a join still waiting now is not coming
		status = "closed: no answer to the join"
	if status != "joined":
		if readout != null:
			readout.text = "realm: " + status
		# a trip closes this connection itself and the next map's ticket follows;
		# when none comes, the player is told instead of waiting on the screen
		var closed_on_trip := false
		if travel.leaving and (status.begins_with("refused") or status.begins_with("closed")):
			if _closed_on_trip_at <= 0.0:
				_closed_on_trip_at = clock
			closed_on_trip = clock - _closed_on_trip_at > TRIP_LOST_SECONDS and not travel.reloading
		if (status.begins_with("refused") or status.begins_with("closed")) and (not travel.leaving or closed_on_trip):
			if not _join_told:
				_join_told = true
				print("realm: %s %s after %.1f s: %s" % [map_name, "left" if built else "not joined", clock - _join_began, status])
			if _quits_when_closed():
				printerr("realm: ", status)
				get_tree().quit(1)
				return
			if _retrying:
				return
			if _join_can_retry(status) and FrontDoor.join_retries < JOIN_RETRIES:
				retry_join(status)
				return
			# what the realm said last (DISCONNECTING) comes before the screen
			_show_notices()
			maintenance.show_closed(status, built)
		return
	if not _join_told:
		_join_told = true
		FrontDoor.join_retries = 0
		print("realm: joined %s in %.1f s" % [map_name, clock - _join_began])
	if not built:
		if _map_building or not travel.ready_to_build():
			return
		_build_map()
		check_started = Time.get_ticks_msec() / 1000.0
		if not built:
			return
	var strafe := 0.0
	var forward := 0.0
	var jump := false
	if check_quests:
		var walking := _check_quest_walk(delta)
		forward = 1.0 if walking else 0.0
		strafe = _check_sidestep(walking)
	elif check_seconds > 0.0:
		# Walks (and hops) for the first third, then stands and fights.
		var walking := Time.get_ticks_msec() / 1000.0 - check_started < check_seconds / 3.0 or target == 0
		forward = 1.0 if walking else 0.0
		cam_yaw += 0.004
		jump = walking and int(Time.get_ticks_msec() / 1500) % 4 == 3
		# A chest that dropped comes first: walk to it, then stand and take.
		var toward := _check_loot_steer()
		if is_inf(toward):
			forward = 0.0
			jump = false
		elif not is_nan(toward):
			cam_yaw = toward
			forward = 1.0
			jump = false
	elif duel_check != null and duel_check.walk_intent() > 0.0:
		forward = duel_check.walk_intent()
	elif travel_check != null:
		forward = travel_check.walk_intent()
		strafe = _check_sidestep(forward > 0.0)
		jump = travel_check.jump_intent()
	elif dungeon_check != null:
		forward = dungeon_check.walk_intent()
		strafe = _check_sidestep(forward > 0.0)
	elif stairs_check != null:
		forward = stairs_check.walk_intent()
		strafe = _check_sidestep(forward > 0.0)
	elif castle_check != null:
		forward = castle_check.walk_intent()
	elif drawn_check != null:
		forward = drawn_check.walk_intent()
	elif map_check != null:
		forward = map_check.walk_intent()
		strafe = _check_sidestep(forward > 0.0)
	elif audio_check != null:
		forward = audio_check.walk_intent()
		strafe = _check_sidestep(forward > 0.0)
		jump = audio_check.jump_intent()
	elif menu_check != null and menu_check.walk_intent() > 0.0:
		forward = menu_check.walk_intent()
	elif polish_check != null and polish_check.drives():
		forward = polish_check.walk_intent()
		jump = polish_check.jump_intent()
	elif controls_check != null and controls_check.drives():
		forward = controls_check.walk_intent()
	elif not hud.chat.is_open():
		# while the chat has the keys, typing does not walk
		strafe = float(GameSettings.pressed("move_right")) - float(GameSettings.pressed("move_left"))
		forward = float(GameSettings.pressed("move_forward")) - float(GameSettings.pressed("move_backward"))
		jump = GameSettings.pressed("jump")
	var descend: bool = GameSettings.pressed("descend") and not hud.chat.is_open()
	if travel_check != null:
		descend = travel_check.descend_intent()
	elif audio_check != null:
		descend = audio_check.descend_intent()
	elif polish_check != null and polish_check.drives():
		descend = polish_check.descend_intent()
	session.set_intent(strafe, forward, cam_yaw, jump, descend)

	var own: Dictionary = session.own_body()
	var me: Vector3 = own.get("position", Vector3.ZERO)
	if not own.is_empty():
		player.is_mounted = bool(own.get("mounted", false))
		player.drive_own(own, delta)
		player.set_status(int(own.get("status", 0)))
		check_own_statuses |= int(own.get("status", 0))
	# the eye looks at the neck from afar and rises to the head as it closes
	# in, so the near view goes over the hero's head rather than into its back
	var look_height := lerpf(CAM_NEAR_LOOK, 1.5, clampf((cam_distance - CAM_NEAR) / (CAM_LOOK_BLEND - CAM_NEAR), 0.0, 1.0))
	var look_at_point := me + Vector3(0, look_height, 0)
	var offset := Vector3(0, 0, cam_distance).rotated(Vector3.RIGHT, cam_pitch).rotated(Vector3.UP, cam_yaw + cam_side)
	camera.position = look_at_point + offset.normalized() * _camera_room(look_at_point, offset, delta)
	camera.look_at(look_at_point)

	others = session.remote()
	var ids: PackedInt32Array = others["ids"]
	var positions: PackedVector3Array = others["positions"]
	var kinds: PackedInt32Array = others["kinds"]
	var yaws: PackedFloat32Array = others["yaws"]
	var states: PackedInt32Array = others["states"]
	var statuses: PackedInt32Array = others["statuses"]
	var hps: PackedInt32Array = others["hp"]
	var seen := {}
	var seen_chests := {}
	var creatures := 0
	drawn = {session.own_entity(): me}
	part_states = {}
	crowd.multimesh.instance_count = positions.size()
	for i in positions.size():
		drawn[ids[i]] = positions[i]
		if ChestView.is_chest(kinds[i]):
			seen_chests[ids[i]] = true
			if not check_chests_seen.has(ids[i]):
				check_chests_seen[ids[i]] = Time.get_ticks_msec() / 1000.0
			if not chests.has(ids[i]):
				var chest: ChestView = load(ChestViewScript).new()
				add_child(chest)
				chest.setup(kinds[i])
				chest.drive(_ground(positions[i]))
				chests[ids[i]] = chest
			continue
		if kinds[i] == KIND_PLAYER:
			seen[ids[i]] = true
			if not heroes.has(ids[i]):
				heroes[ids[i]] = _new_hero()
				# Who it is: name, house, level, look and gear (the player
				# menu, the card, the plate, the body).
				session.inspect(ids[i])
			# the state byte: the pose in the low bits, STATE_MOUNTED_BIT
			# while it rides its broom
			heroes[ids[i]].is_mounted = states[i] & STATE_MOUNTED_BIT != 0
			heroes[ids[i]].drive_remote(positions[i], delta)
			heroes[ids[i]].set_status(statuses[i])
			heroes[ids[i]].set_dead(states[i] & STATE_POSE_MASK == CreatureView.STATE_DEAD)
			continue
		var species_kind := kinds[i] & CreatureView.SPECIES_MASK
		var part_radius := _part_kind_radius(species_kind)
		if part_radius > 0.0:
			# A boss's head or vine, drawn by its boss's model. Its feet are
			# taken CHEST under the point the server holds it at, so a bolt,
			# a spell's aim and a damage number land on the head itself.
			drawn[ids[i]] = positions[i] - Vector3(0, CHEST, 0)
			part_states[ids[i]] = [states[i], part_radius]
			continue
		if not no_model.has(species_kind):
			seen[ids[i]] = true
			# a body that turned boss (or stopped being one) changes body
			if beasts.has(ids[i]) and bool(beasts[ids[i]].is_boss) != (kinds[i] & CreatureView.BOSS_BIT != 0):
				beasts[ids[i]].queue_free()
				beasts.erase(ids[i])
			if not beasts.has(ids[i]):
				var beast := _new_beast(ids[i], kinds[i])
				if beast != null:
					beasts[ids[i]] = beast
					_plate_creature(ids[i], kinds[i])
				else:
					no_model[species_kind] = true
			if beasts.has(ids[i]):
				var beast: Node3D = beasts[ids[i]]
				if int(_plate_kinds.get(ids[i], kinds[i])) != kinds[i]:
					_plate_creature(ids[i], kinds[i])
				plates.set_hidden(ids[i], states[i] & STATE_POSE_MASK == CreatureView.STATE_DEAD)
				beast.set_kind(kinds[i])
				beast.set_status(statuses[i])
				beast.drive(positions[i], yaws[i], states[i], delta)
				if beast is StoneView:
					(beast as StoneView).set_health(hps[i])
					check_stones[ids[i]] = true
				elif beast is DummyView:
					(beast as DummyView).set_health(hps[i])
					check_dummies[ids[i]] = true
				continue
		crowd.multimesh.set_instance_transform(creatures, Transform3D(Basis(), positions[i] + Vector3(0, 0.925, 0)))
		crowd.multimesh.set_instance_color(creatures, KIND_COLORS[species_kind % KIND_COLORS.size()])
		creatures += 1
	crowd.multimesh.visible_instance_count = creatures
	for id: int in chests.keys():
		if not seen_chests.has(id):
			# emptied, expired or out of view: it shrinks away, its window closes
			if check_taken_from.has(id):
				check_chests_vanished += 1
			if loot_window.chest_id == id:
				loot_window.close()
			chests[id].despawn()
			chests.erase(id)
	for table: Dictionary in [heroes, beasts]:
		for id in table.keys():
			if not seen.has(id):
				# a corpse still burning away finishes on its own, out of
				# every table (nothing targets, names or voices it)
				if not (table[id].has_method("linger") and table[id].linger()):
					table[id].queue_free()
				table.erase(id)
				player_names.erase(id)
				player_infos.erase(id)
				plates.remove(id)
				_plate_kinds.erase(id)
	_take_creature_info()
	_update_boss_parts()
	_follow_target()
	plates.focus_id = target
	_follow_ring()
	if CursorKit.is_rotating() and not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		# released over a window, where the world never heard it
		CursorKit.set_rotating(false)
	if check_seconds > 0.0 and not check_quests:
		_check_kill_loop()
		if not feedback.is_dead():
			_check_fight(delta)
		_check_statuses(ids, kinds, statuses)
	_show_combat()
	_show_notices()
	_show_game_events()
	_show_chat()
	travel.tick(delta)
	dungeon.tick(delta)
	way.tick(delta)
	_tick_basic_hold()

	var stats: Dictionary = session.stats()
	var now_ms := Time.get_ticks_msec()
	if now_ms >= _ping_at:
		_ping_at = now_ms + 500
		way.minimap.set_ping(int(stats["rtt_ms"]) if stats.has("rtt_ms") else -1)
	var sheet: Dictionary = session.sheet()
	if not sheet.is_empty() and not CharacterSelect.look_on_entry.is_empty():
		# a look edited on the character screen: the server cleans and saves it
		var edited := {}
		for key: String in CharacterSelect.look_on_entry:
			edited[key] = float(CharacterSelect.look_on_entry[key])
		session.set_look(edited)
		CharacterSelect.look_on_entry = {}
	# the readout's text only while it is shown (or a fight check prints it)
	var show_readout := readout.visible or check_seconds > 0.0
	if show_readout:
		readout.text = "realm  %d fps  tick %d  hp %d  snapshots %d  corrections %d (max %.3f m)  server moves %d
%s  %d others in view" % [
			Engine.get_frames_per_second(), stats.get("tick", 0), stats.get("hp", 0), stats.get("snapshots", 0),
			stats.get("corrections", 0), stats.get("max_correction", 0.0), stats.get("server_moves", 0),
			str(me.snapped(Vector3(0.1, 0.1, 0.1))),
			positions.size()]
		if player.anim != null:
			readout.text += "  pose %s" % player.anim.current_clip
	if not sheet.is_empty():
		if show_readout:
			var bag: Array = sheet["bag"]
			var items := bag.filter(func(c): return c != null).map(
				func(c): return "%s x%d" % [c["id"], c["amount"]])
			readout.text += "
%s (%s)  level %d  hp %d/%d  mana %d/%d  %d oril  wields %s
bag: %s" % [
				sheet["name"], sheet["house"], sheet["level"], sheet["hp"], sheet["max_hp"], sheet["mana"],
				sheet["max_mana"], sheet["oril"], (sheet["equipment"] as Dictionary).get("main_hand", {}).get("id", "-"),
				", ".join(items)]
		_apply_sheet_look(sheet)

	if check_quests:
		var now := Time.get_ticks_msec() / 1000.0
		if now - check_started > check_seconds or (check_quest_done_at > 0.0 and now - check_quest_done_at > CHECK_LINGER):
			_check_quests_verdict(stats, sheet)
	elif check_seconds > 0.0 and Time.get_ticks_msec() / 1000.0 - check_started > check_seconds:
		print("realm check: ", readout.text.replace("
", " | "),
			" | fight: %d own casts started, %d own hits, %d own bursts, target hp %d/255" % [check_casts, check_hits, check_bursts, check_hp],
			" | loop: +%d exp, +%d oril, %d levels (%d level-ups shown), %d deaths (death panel %d, rises asked %d, rises shown %d), %d toasts, last \"%s\"" % [
				check_exp, check_oril, check_levels, feedback.level_ups_shown, check_deaths, feedback.deaths_shown,
				check_rises_asked, feedback.rises_shown, feedback.toasts_shown, feedback.last_toast],
			" | loot: %d chests seen, %d takes, %d rewards with items, %d chests vanished after a take, results [%s]" % [
				check_chests_seen.size(), loot_window.takes_sent, check_loot_items, check_chests_vanished, _counts(check_loot_results)],
			" | attributes: points %s, %d spends, answers [%s], vit %d" % [check_had_points, character_window.spends_sent,
				_counts(check_attribute_results), int((sheet.get("attributes", {}) as Dictionary).get("vit", 0)) if not sheet.is_empty() else 0],
			" | statuses: target %s (%d), hit creatures %s (%d), shockwave on a throwable %s" % [_status_names(check_target_statuses),
				check_target_statuses, _status_names(_check_hit_statuses()), _check_hit_statuses(), _check_hit_throwable()],
			" | creatures: %d telegraphs (%d released, %d called off), %d boulders, %d bolts, %d evades, own statuses %s" % [
				combat.telegraphs_seen, combat.telegraphs_released, combat.telegraphs_cancelled, combat.boulders_thrown,
				combat.creature_bolts, combat.evades_shown, _status_names(check_own_statuses)],
			" | world: target %s, %d creature infos, bosses [%s], notices [%s], %d stones, %d dummies in view, last notice \"%s\"" % [
				hud.target_name.text if target != 0 else "-", check_infos, ", ".join(check_bosses.values()),
				", ".join(check_notices.keys().map(func(k): return "%s x%d" % [k, check_notices[k]])),
				check_stones.size(), check_dummies.size(), hud.notices.last_text])
		var passed := int(stats.get("corrections", 0)) == 0 and int(stats.get("snapshots", 0)) > 0 and check_hits > 0 \
			and _check_loop_passed() \
			and check_bursts > 0 and (_check_hit_statuses() & StatusFX.STATUS_KNOCKED != 0 or not _check_hit_throwable())
		get_tree().quit(0 if passed else 1)

## What moderation says to this player: a kick or a ban is shown on the end
## screen when the connection closes, anything else in the chat log.
func _moderation_notice(notice: Dictionary) -> void:
	if String(notice["kind"]) == "sanction" and String(notice["state"]) in ["kick", "ban"]:
		maintenance.on_sanction(notice)
		return
	var line: String = hud.player_menu.social_notice(notice)
	if line != "":
		hud.chat.add_system_line(line)
