// Launcher logic shared by the UI shells (main.cpp on Windows, main_sdl.cpp on
// Linux/macOS): what the launcher is doing (Phase), the update and server
// status workers, and the play / repair actions. Shells draw TakeSnapshot(),
// forward input here, and get told to repaint through Hooks.
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>

#include "common.h"

namespace realm {
namespace app {

enum class Phase {
    Checking,       // reading the manifest
    Downloading,    // fetching the client package (progress known)
    Installing,     // verifying / extracting / activating
    SelfUpdating,   // a newer launcher is being installed; we exit
    Ready,          // installed and current: PLAY
    ReadyStale,     // installed, but the update check or the update failed
    Failed,         // something needs the player: RETRY
    GameRunning,    // the game is open
};

// What went wrong, for the shells' colours and for the tests.
enum class Problem {
    None,
    Network,
    DiskFull,
    Verification,
    Incompatible,
    LauncherUpdate,
    Maintenance,
    ServerOffline,
    GameStart,
    GameCrashed,
    GameClosedEarly,
    Other,
};

struct Snapshot {
    Phase phase;
    Problem problem;
    std::wstring title, detail, notes, server;
    std::wstring advice;   // what the player can do; replaces the notes panel
    std::string installed, release;
};

// Called from worker threads: the shell must marshal them to its UI thread.
struct Hooks {
    std::function<void()> refresh;             // state changed: repaint
    std::function<void()> exitForSelfUpdate;   // the update helper took over: quit
    std::function<void()> restoreWindow;       // the game failed: show the launcher again
    std::function<void(const std::wstring&)> openUrl;   // https link in the browser
    std::function<void(const std::wstring&)> openPath;  // a file or folder
};

// The game's name as the shells draw it (crest, window title). Files and
// folders on disk are ThousandRealms*; launchers and installs from before the
// rename are moved over on start (legacy_names.cpp, MigrateLegacyInstallRoot).
inline constexpr const wchar_t* kGameTitle = L"Thousand Realms";
inline constexpr const wchar_t* kSupportUrl = L"https://github.com/semdin/realm/issues";

// How often the shells poll the server status and look for a new release.
constexpr unsigned kStatusPollMs = 30000;
constexpr unsigned kRecheckMs = 10 * 60 * 1000;
constexpr unsigned kGamePollMs = 2500;

void Init(const AppConfig& cfg, Hooks hooks);
// The third-party notices embedded in the executable (shown by "Licenses").
void SetNotices(const void* data, size_t size);

Snapshot TakeSnapshot();
Phase CurrentPhase();
std::wstring PlayLabel(Phase p);
bool PlayEnabled(Phase p);
uint64_t ProgressDone();
uint64_t ProgressTotal();

// Text the shells draw, in the launcher's language.
std::wstring ServerLabel(const std::wstring& server);
std::wstring PanelCaption(const Snapshot& s);
std::wstring PanelBody(const Snapshot& s);   // the notes in the launcher's language
std::wstring LocalizedNotes(const std::wstring& notes);
const wchar_t* ReadMoreLabel();
const wchar_t* CloseLabel();
std::wstring VersionLine(const Snapshot& s);
const wchar_t* SubtitleText();
const wchar_t* RepairLabel();
const wchar_t* SupportLabel();
const wchar_t* LicensesLabel();
const wchar_t* LogsLabel();
const wchar_t* CloseDuringUpdateText();
const wchar_t* YesLabel();
const wchar_t* NoLabel();

void StartWorker(bool repair = false);   // check -> (self-update | update) -> ready
void StartStatusPoll();
void OnRecheckTimer();
void RequestRepair();
void Cancel();                           // stop a running download (on exit)

// Starts the installed game; true when it is running (the shell then hides
// itself and calls PollGame every kGamePollMs until it returns false).
bool OnPlay();
bool PollGame();

void OpenSupport();
void OpenLicenses();
void OpenLogs();

// Screenshot hook: shows one state without touching the network. Names:
// ready, checking, downloading, network, disk, maintenance, offline, verify,
// start, crash, early, notes (long two-language notes). False for an unknown name.
bool ShowTestState(const std::string& name);

}  // namespace app
}  // namespace realm
