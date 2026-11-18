//! The watch kept over the game from outside its main thread.
//!
//! **Stalls.** A first start on Metal can hold the main thread for minutes
//! inside one draw, and nobody will run diagnostics on a player's Mac. Every
//! finished frame leaves a mark here; a thread of ours notices when the marks
//! stop and writes what it knows (the phase the game said it was in, for how
//! long, the platform; on macOS also how busy Apple's shader compiler is) to
//! `user://logs/stall_reports.jsonl` and to standard output. The next start
//! prints what the last run left. There is no channel to the realm for this
//! (the login service and the protocol have no such message), so the reports
//! stay on the player's machine. They hold no name, path or address.
//!
//! **Exit.** Once the main loop has ended, the engine's shutdown gets
//! `EXIT_LIMIT` to finish; a shutdown that hangs is ended with the operating
//! system's plain exit call, without a crash dialog. By then the settings are
//! on disk (they are saved when changed) and the goodbye to the server is sent
//! as the scene is freed, within a second.
//!
//! The hang this was built for is Godot's (4.8 beta 3):
//! `WorkerThreadPool::exit_languages_threads` waits for every pool thread to
//! report idle, a thread reports only while both task queues are empty, and
//! threads that found low-priority tasks still queued go back to sleep with
//! nothing left to wake them. Quitting while background pipeline compiles were
//! queued therefore hung the process for good. `begin_exit` lets that queue run
//! out first, which avoids the hang; the limit is there for what remains.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use godot::classes::{Engine, Os, ProjectSettings, RenderingServer, Time, WorkerThreadPool};
use godot::prelude::*;
use serde_json::{Value, json};

use crate::guard_sys;

const POLL: Duration = Duration::from_millis(250);
/// No finished frame for this long is a stall worth writing down; it is written
/// again each time the wait doubles, so a killed game leaves its last figure.
const STALL_FIRST_MS: u64 = 20_000;
/// The watch thread itself slept this much too long: the machine was asleep.
const ASLEEP_MS: u64 = 5_000;
/// What the engine's shutdown may take, from the end of the main loop.
const EXIT_LIMIT_MS: u64 = 10_000;
/// How long the shutdown waits for queued low-priority tasks to start.
const DRAIN_LIMIT: Duration = Duration::from_secs(2);
const REPORT_FILE: &str = "stall_reports.jsonl";
const SAMPLE_FILE: &str = "stall_sample.txt";
const REPORTS_KEPT: usize = 12;

static STARTED: AtomicBool = AtomicBool::new(false);
static CLOCK: OnceLock<Instant> = OnceLock::new();
/// When the last frame ended, in `now_ms` time.
static LAST_FRAME_MS: AtomicU64 = AtomicU64::new(0);
/// When the shutdown runs out of time (0: not quitting).
static EXIT_AT_MS: AtomicU64 = AtomicU64::new(0);
static EXIT_CODE: AtomicI32 = AtomicI32::new(0);
static PHASE: Mutex<String> = Mutex::new(String::new());

fn now_ms() -> u64 {
    CLOCK.get_or_init(Instant::now).elapsed().as_millis() as u64
}

fn phase() -> String {
    PHASE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone()
}

fn set_phase_text(text: &str) {
    let mut phase = PHASE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    phase.clear();
    phase.push_str(text);
}

/// Standard output, which may be closed: the watch never fails over it.
fn say(line: &str) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{line}");
    let _ = out.flush();
}

/// What a report says about the machine (filled on the main thread, which alone
/// may ask the engine). Technical facts only.
fn platform_facts() -> Value {
    let os = Os::singleton();
    let rendering = RenderingServer::singleton();
    let version = ProjectSettings::singleton()
        .get_setting("application/config/version")
        .to_string();
    json!({
        "game": version,
        "engine": Engine::singleton().get_version_info().get("string").map(|v| v.to_string()),
        "os": os.get_name().to_string(),
        "os_version": os.get_version().to_string(),
        "arch": std::env::consts::ARCH,
        "cpu": os.get_processor_name().to_string(),
        "gpu": rendering.get_video_adapter_name().to_string(),
        "driver": rendering.get_current_rendering_driver_name().to_string(),
        "renderer": rendering.get_current_rendering_method().to_string(),
    })
}

/// The report file: one JSON object per line, newest last.
struct Reports {
    file: PathBuf,
    lines: Vec<Value>,
}

impl Reports {
    fn load(dir: &Path) -> Self {
        let file = dir.join(REPORT_FILE);
        let lines = std::fs::read_to_string(&file)
            .unwrap_or_default()
            .lines()
            .filter_map(|line| serde_json::from_str(line).ok())
            .collect();
        Self { file, lines }
    }

    fn save(&mut self) {
        let extra = self.lines.len().saturating_sub(REPORTS_KEPT);
        self.lines.drain(..extra);
        let mut text = String::new();
        for line in &self.lines {
            text.push_str(&line.to_string());
            text.push('\n');
        }
        let fresh = self.file.with_extension("tmp");
        if std::fs::write(&fresh, text).is_ok() {
            let _ = std::fs::rename(&fresh, &self.file);
        }
    }
}

/// How busy this process and Apple's shader compiler are (macOS): a busy
/// compiler is a slow first start, everything idle looks like a lock. Numbers
/// only; the process names stay out of the report.
fn compiler_load() -> Option<Value> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let output = Command::new("ps")
        .args(["-A", "-o", "pid=,pcpu=,comm="])
        .output()
        .ok()?;
    let own = std::process::id();
    let mut game = 0.0;
    let mut compilers = Vec::new();
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let mut parts = line.split_whitespace();
        let (Some(pid), Some(cpu)) = (parts.next(), parts.next()) else {
            continue;
        };
        let Ok(cpu) = cpu.parse::<f64>() else {
            continue;
        };
        if pid.parse::<u32>().ok() == Some(own) {
            game = cpu;
        } else if line.trim_end().ends_with("MTLCompilerService") {
            compilers.push(cpu);
        }
    }
    Some(json!({"game": game, "metal_compilers": compilers}))
}

/// A native stack sample next to the reports (macOS), home folder removed.
fn sample_stacks(dir: &Path) {
    if !cfg!(target_os = "macos") {
        return;
    }
    let file = dir.join(SAMPLE_FILE);
    let done = Command::new("sample")
        .arg(std::process::id().to_string())
        .arg("3")
        .arg("-file")
        .arg(&file)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    if done.is_ok()
        && let (Ok(text), Ok(home)) = (std::fs::read_to_string(&file), std::env::var("HOME"))
        && !home.is_empty()
    {
        let _ = std::fs::write(&file, text.replace(&home, "~"));
    }
}

/// The watch thread. Touches no engine API: the engine may be stuck or gone.
struct Watch {
    dir: PathBuf,
    facts: Value,
    reports: Reports,
    /// The stall under way: its next report is due at this wait.
    next_report_ms: u64,
    /// The longest wait for a frame seen since the last stall ended.
    longest_ms: u64,
    stalled: bool,
    sampled: bool,
}

impl Watch {
    fn report(&mut self, kind: &str, state: &str, waited_ms: u64, replace: bool) {
        let at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |t| t.as_secs());
        let mut entry = json!({
            "kind": kind,
            "state": state,
            "at_unix": at,
            "seconds": (waited_ms / 100) as f64 / 10.0,
            "phase": phase(),
            "platform": self.facts,
            "reported": false,
        });
        if let Some(load) = compiler_load() {
            entry["load"] = load;
        }
        if replace {
            self.reports.lines.pop();
        }
        self.reports.lines.push(entry);
        self.reports.save();
    }

    fn check_stall(&mut self, now: u64) {
        let waited = now.saturating_sub(LAST_FRAME_MS.load(Ordering::Relaxed));
        self.longest_ms = self.longest_ms.max(waited);
        if waited >= self.next_report_ms {
            let first = !self.stalled;
            self.stalled = true;
            self.next_report_ms = self.next_report_ms.saturating_mul(2);
            say(&format!(
                "realm watch: no frame finished for {} s (phase: {})",
                waited / 1000,
                phase()
            ));
            self.report("stall", "ongoing", waited, !first);
            if !first && !self.sampled {
                self.sampled = true;
                sample_stacks(&self.dir);
            }
        } else if self.stalled && waited < POLL.as_millis() as u64 * 4 {
            let total = self.longest_ms;
            say(&format!(
                "realm watch: frames are back after a stall of {} s (phase: {})",
                total / 1000,
                phase()
            ));
            self.report("stall", "resumed", total, true);
            self.stalled = false;
            self.next_report_ms = STALL_FIRST_MS;
            self.longest_ms = 0;
        } else if !self.stalled {
            self.longest_ms = 0;
        }
    }

    fn run(mut self) {
        let mut last_wake = now_ms();
        loop {
            std::thread::sleep(POLL);
            let now = now_ms();
            let exit_at = EXIT_AT_MS.load(Ordering::Acquire);
            if exit_at != 0 {
                if now >= exit_at {
                    let code = EXIT_CODE.load(Ordering::Relaxed);
                    say(&format!(
                        "realm watch: the engine's shutdown did not finish in {} s; ending the process (code {code})",
                        EXIT_LIMIT_MS / 1000
                    ));
                    self.report("exit_hang", "ended", EXIT_LIMIT_MS, false);
                    guard_sys::exit_now(code);
                }
            } else if now.saturating_sub(last_wake) > ASLEEP_MS {
                // The machine slept: that gap says nothing about the game.
                LAST_FRAME_MS.store(now, Ordering::Relaxed);
                self.stalled = false;
                self.next_report_ms = STALL_FIRST_MS;
                self.longest_ms = 0;
            } else {
                self.check_stall(now);
            }
            last_wake = now;
        }
    }
}

/// What the last run left, told once in this run's log.
fn tell_previous(dir: &Path) {
    let mut reports = Reports::load(dir);
    let mut told = false;
    for entry in &mut reports.lines {
        if entry["reported"].as_bool() != Some(false) {
            continue;
        }
        godot_print!(
            "realm watch: an earlier run had {} ({}) of {} s in phase '{}' on {} {}",
            entry["kind"].as_str().unwrap_or("?"),
            entry["state"].as_str().unwrap_or("?"),
            entry["seconds"],
            entry["phase"].as_str().unwrap_or(""),
            entry["platform"]["os"].as_str().unwrap_or("?"),
            entry["platform"]["gpu"].as_str().unwrap_or("?"),
        );
        entry["reported"] = Value::Bool(true);
        told = true;
    }
    if told {
        reports.save();
    }
}

/// The main loop is about to run (the engine is up): the watch starts.
pub fn main_loop_started() {
    if Engine::singleton().is_editor_hint() {
        return;
    }
    let dir = PathBuf::from(Os::singleton().get_user_data_dir().to_string()).join("logs");
    let _ = std::fs::create_dir_all(&dir);
    tell_previous(&dir);
    if !guard_sys::pin_this_library() {
        godot_warn!("realm watch: the library cannot be pinned; no stall or exit watch");
        return;
    }
    LAST_FRAME_MS.store(now_ms(), Ordering::Relaxed);
    set_phase_text("start");
    let watch = Watch {
        reports: Reports::load(&dir),
        dir,
        facts: platform_facts(),
        next_report_ms: STALL_FIRST_MS,
        longest_ms: 0,
        stalled: false,
        sampled: false,
    };
    let spawned = std::thread::Builder::new()
        .name("realm-watch".into())
        .spawn(move || watch.run());
    STARTED.store(spawned.is_ok(), Ordering::Release);
}

/// A frame finished.
pub fn frame_finished() {
    LAST_FRAME_MS.store(now_ms(), Ordering::Relaxed);
}

/// The main loop has ended and the engine's shutdown is next: the clock starts,
/// and the low-priority queue is given a moment to run out (see the file's
/// head: a task still queued hangs the shutdown).
pub fn begin_exit() {
    if !STARTED.load(Ordering::Acquire) {
        return;
    }
    set_phase_text("exit");
    EXIT_AT_MS.store(now_ms() + EXIT_LIMIT_MS, Ordering::Release);
    let mut pool = WorkerThreadPool::singleton();
    // An engine method as the task: no script or Rust runs on the pool thread.
    let mark = Callable::from_object_method(&Time::singleton(), "get_ticks_usec");
    // It goes behind everything queued, so its turn means the queue is empty.
    let task = pool
        .add_task_ex(&mark)
        .high_priority(false)
        .description("realm: low-priority queue drained")
        .done();
    let began = Instant::now();
    while !pool.is_task_completed(task) {
        if began.elapsed() >= DRAIN_LIMIT {
            say("realm watch: background tasks still queued at exit");
            return;
        }
        std::thread::sleep(Duration::from_millis(1));
    }
    pool.wait_for_task_completion(task);
}

/// What scripts tell the watch.
#[derive(GodotClass)]
#[class(init, base = RefCounted)]
struct RealmGuard {}

#[godot_api]
impl RealmGuard {
    /// What the game is doing now, in a few words (no names or paths): a stall
    /// report says this.
    #[func]
    fn set_phase(text: GString) {
        set_phase_text(&text.to_string());
    }

    /// The exit code a shutdown ended by the watch leaves (`SceneTree.quit`'s
    /// own cannot be read back).
    #[func]
    fn set_exit_code(code: i64) {
        EXIT_CODE.store(code as i32, Ordering::Relaxed);
    }
}
