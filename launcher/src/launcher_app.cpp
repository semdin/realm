// Launcher logic shared by every UI shell (Windows GDI+ main.cpp, SDL
// main_sdl.cpp): the update/status workers, the play action and the state the
// shells draw. The shells only draw TakeSnapshot() and forward input.
#include "launcher_app.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cwctype>
#include <mutex>
#include <string>
#include <thread>

#ifndef _WIN32
#include <errno.h>
#include <signal.h>
#endif

#include "http.h"
#include "i18n.h"
#include "json.h"
#include "updater.h"

namespace realm {
namespace app {

using i18n::Tx;

namespace {

Hooks g_Hooks;

void PostRefresh() {
    if (g_Hooks.refresh) g_Hooks.refresh();
}

// A game that ends sooner than this after starting did not really run -
// unless it says the player quit (CleanExitMark).
constexpr int64_t kEarlyExitMs = 20 * 1000;

// The game writes this in its user folder when it shuts down in order (the
// Quit button, the window's close: game/scripts/autoload/exit_mark.gd); it is
// deleted before each start, so after an early end it tells a player who
// quit at once from a game that did not start. Empty when the folder is
// unknown.
std::wstring CleanExitMark() {
    std::wstring dir = realm::GameUserDataDir();
    return dir.empty() ? L"" : realm::JoinPath(dir, L"clean_exit");
}

std::mutex g_Mutex;
Phase g_Phase = Phase::Checking;
Problem g_Problem = Problem::None;
std::wstring g_Title;
std::wstring g_Detail;
std::wstring g_Advice;
std::wstring g_Notes;          // release notes of the newest release
std::string g_InstalledVersion;
std::string g_ReleaseVersion;
std::wstring g_ServerState = L"UNKNOWN";  // ONLINE | MAINTENANCE | OFFLINE | UNKNOWN
std::atomic<uint64_t> g_Done{0};
std::atomic<uint64_t> g_Total{0};
std::atomic<bool> g_WorkerBusy{false};
std::atomic<bool> g_StatusBusy{false};
std::atomic<bool> g_Cancel{false};

realm::AppConfig g_Cfg;
const void* g_NoticesData = nullptr;
size_t g_NoticesSize = 0;

// Only the UI thread starts and polls the game.
GameLaunch g_Game;
std::chrono::steady_clock::time_point g_GameStarted;

// A failure as the player reads it.
struct Report {
    Problem problem = Problem::Other;
    std::wstring title, detail, advice;
};

}  // namespace

Snapshot TakeSnapshot() {
    std::lock_guard<std::mutex> lock(g_Mutex);
    std::wstring title = g_Title.empty() ? std::wstring(Tx(L"Güncellemeler kontrol ediliyor", L"Checking for updates"))
                                         : g_Title;
    return Snapshot{g_Phase, g_Problem, title, g_Detail, g_Notes, g_ServerState, g_Advice, g_InstalledVersion,
                    g_ReleaseVersion};
}

std::wstring PlayLabel(Phase p) {
    switch (p) {
        case Phase::Ready:
        case Phase::ReadyStale: return Tx(L"OYNA", L"PLAY");
        case Phase::Failed: return Tx(L"TEKRAR DENE", L"TRY AGAIN");
        case Phase::GameRunning: return Tx(L"OYUN AÇIK", L"RUNNING");
        case Phase::Downloading:
        case Phase::Installing:
        case Phase::SelfUpdating: return Tx(L"GÜNCELLENİYOR", L"UPDATING");
        default: return Tx(L"KONTROL…", L"CHECKING…");
    }
}

bool PlayEnabled(Phase p) {
    return p == Phase::Ready || p == Phase::ReadyStale || p == Phase::Failed;
}

std::wstring ServerLabel(const std::wstring& server) {
    if (server == L"ONLINE") return Tx(L"Sunucu çevrimiçi", L"Server online");
    if (server == L"MAINTENANCE") return Tx(L"Sunucu bakımda", L"Under maintenance");
    if (server == L"OFFLINE") return Tx(L"Sunucuya ulaşılamıyor", L"Server unreachable");
    return Tx(L"Sunucu durumu alınıyor…", L"Checking the server…");
}

std::wstring PanelCaption(const Snapshot& s) {
    if (!s.advice.empty()) return Tx(L"NE YAPABİLİRSİN", L"WHAT YOU CAN DO");
    std::wstring caption = Tx(L"YENİLİKLER", L"WHAT'S NEW");
    if (!s.release.empty()) caption += L"  ·  v" + realm::Utf8ToWide(s.release);
    return caption;
}

// Release notes come in both languages, each part opened by "TR:" or "EN:" at
// the start of a line; the launcher shows its own language's part. Notes
// without the markers are shown whole.
std::wstring LocalizedNotes(const std::wstring& notes) {
    const wchar_t* want = i18n::Current() == i18n::Lang::Turkish ? L"TR:" : L"EN:";
    auto marker = [](const std::wstring& line) -> std::wstring {
        size_t i = line.find_first_not_of(L" \t");
        if (i == std::wstring::npos || line.size() < i + 3 || line[i + 2] != L':') return L"";
        std::wstring tag = line.substr(i, 3);
        for (wchar_t& c : tag) c = (wchar_t)towupper(c);
        return (tag == L"TR:" || tag == L"EN:") ? tag : L"";
    };
    std::wstring out, current;
    bool any = false;
    size_t start = 0;
    while (start <= notes.size()) {
        size_t end = notes.find(L'\n', start);
        if (end == std::wstring::npos) end = notes.size();
        std::wstring line = notes.substr(start, end - start);
        if (!line.empty() && line.back() == L'\r') line.pop_back();
        std::wstring tag = marker(line);
        if (!tag.empty()) {
            any = true;
            current = tag;
            line = line.substr(line.find(L':') + 1);
            size_t first = line.find_first_not_of(L" \t");
            line = first == std::wstring::npos ? L"" : line.substr(first);
        }
        if (current == want) {
            if (!out.empty()) out += L"\n";
            out += line;
        }
        start = end + 1;
    }
    if (!any) return notes;
    size_t last = out.find_last_not_of(L" \t\r\n");
    out = last == std::wstring::npos ? L"" : out.substr(0, last + 1);
    return out.empty() ? notes : out;
}

std::wstring PanelBody(const Snapshot& s) {
    if (!s.advice.empty()) return s.advice;
    if (!s.notes.empty()) return LocalizedNotes(s.notes);
    return Tx(L"Bu sürüm için not eklenmemiş.", L"No notes for this version.");
}

const wchar_t* ReadMoreLabel() { return Tx(L"Devamını oku", L"Read more"); }
const wchar_t* CloseLabel() { return Tx(L"Kapat", L"Close"); }

std::wstring VersionLine(const Snapshot& s) {
    std::wstring line = L"Launcher v" + realm::Utf8ToWide(realm::kLauncherVersion);
    if (!s.installed.empty())
        line = std::wstring(Tx(L"Oyun v", L"Game v")) + realm::Utf8ToWide(s.installed) + L"   ·   " + line;
    return line;
}

const wchar_t* SubtitleText() { return Tx(L"B Ü Y Ü C Ü L Ü K   D İ Y A R I", L"R E A L M   O F   S O R C E R Y"); }
const wchar_t* RepairLabel() { return Tx(L"Dosyaları onar", L"Repair files"); }
const wchar_t* SupportLabel() { return Tx(L"Destek", L"Support"); }
const wchar_t* LicensesLabel() { return Tx(L"Lisanslar", L"Licenses"); }
const wchar_t* LogsLabel() { return Tx(L"Kayıtlar", L"Logs"); }
const wchar_t* YesLabel() { return Tx(L"Evet", L"Yes"); }
const wchar_t* NoLabel() { return Tx(L"Hayır", L"No"); }
const wchar_t* CloseDuringUpdateText() {
    return Tx(L"Güncelleme sürüyor. Şimdi kapatırsan indirme bir sonraki açılışta kaldığı yerden devam eder.\n\nKapatılsın mı?",
              L"An update is running. If you close now, the download continues from where it stopped next time.\n\nClose the launcher?");
}

void SetState(Phase p, const std::wstring& title, const std::wstring& detail, const std::wstring& advice = L"",
              Problem problem = Problem::None) {
    {
        std::lock_guard<std::mutex> lock(g_Mutex);
        g_Phase = p;
        g_Title = title;
        g_Detail = detail;
        g_Advice = advice;
        g_Problem = problem;
    }
    PostRefresh();
}

Phase CurrentPhase() {
    std::lock_guard<std::mutex> lock(g_Mutex);
    return g_Phase;
}

// ------------------------------------------------------------------ workers
// "24.2 MB": one decimal, integer arithmetic only (no printf dialect issues).
std::wstring BytesText(uint64_t v) {
    const wchar_t* unit = L"KB";
    uint64_t div = 1024;
    if (v >= (1ull << 30)) {
        unit = L"GB";
        div = 1ull << 30;
    } else if (v >= (1ull << 20)) {
        unit = L"MB";
        div = 1ull << 20;
    }
    uint64_t tenths = (v * 10 + div / 2) / div;
    return std::to_wstring(tenths / 10) + (i18n::Current() == i18n::Lang::Turkish ? L"," : L".") +
           std::to_wstring(tenths % 10) + L" " + unit;
}

namespace {

// The numbers in CheckDiskSpace's "need N bytes, M available" message.
bool ParseDiskNumbers(const std::string& raw, uint64_t& need, uint64_t& available) {
    size_t at = raw.find("need ");
    size_t mid = raw.find(" bytes, ");
    if (at == std::string::npos || mid == std::string::npos || mid < at) return false;
    need = strtoull(raw.c_str() + at + 5, nullptr, 10);
    available = strtoull(raw.c_str() + mid + 8, nullptr, 10);
    return need > 0;
}

Report DiskReport(uint64_t need, uint64_t available) {
    Report r;
    r.problem = Problem::DiskFull;
    r.title = Tx(L"Diskte yeterli yer yok", L"Not enough disk space");
    if (need > 0) {
        r.detail = BytesText(need) + Tx(L" gerekiyor, ", L" needed, ") + BytesText(available) +
                   Tx(L" boş.", L" free.");
    } else {
        r.detail = Tx(L"Dosyalar diske yazılamadı.", L"The files could not be written to the disk.");
    }
    r.advice = std::wstring(Tx(L"Bu diskte yer açıp yeniden dene: ", L"Free up space on this drive and try again: ")) +
               realm::ResolvePathsForGui(g_Cfg).installRoot;
    return r;
}

// A full disk can also surface as a failed write deep inside an update.
bool DiskLooksFull() {
    std::wstring root = realm::ResolvePathsForGui(g_Cfg).installRoot;
    std::wstring probe = root;
    while (!probe.empty() && !realm::DirExists(probe)) {
        size_t slash = probe.find_last_of(L"\\/");
        if (slash == std::wstring::npos) return false;
        probe.resize(slash);
    }
    return !probe.empty() && realm::FreeDiskSpaceBytes(probe) < 32ull * 1024 * 1024;
}

Report DescribeError(const std::string& raw, int code) {
    Report r;
    const wchar_t* retry = Tx(L"Yeniden dene. Sorun sürerse Destek'ten bize yaz.",
                              L"Try again. If it keeps happening, contact Support.");
    // Linux loads libcurl at run time (http_curl.cpp); a system without it
    // would otherwise read as a network problem.
    if (raw.find("libcurl is not installed") != std::string::npos) {
        r.title = Tx(L"libcurl bulunamadı", L"libcurl is missing");
        r.detail = Tx(L"Launcher indirme yapmak için bu sistem kitaplığına ihtiyaç duyar.",
                      L"The launcher needs this system library to download.");
        r.advice = Tx(L"Paket yöneticinden \"curl\" paketini kurup launcher'ı yeniden aç.",
                      L"Install the \"curl\" package with your package manager, then reopen the launcher.");
        return r;
    }
    uint64_t need = 0, available = 0;
    if (code == realm::kExitDiskSpace) {
        ParseDiskNumbers(raw, need, available);
        return DiskReport(need, available);
    }
    if ((code == realm::kExitDownload || code == realm::kExitIntegrity) && DiskLooksFull()) return DiskReport(0, 0);
    switch (code) {
        case realm::kExitNetwork:
            r.problem = Problem::Network;
            r.title = Tx(L"Güncelleme sunucusuna ulaşılamadı", L"Can't reach the update server");
            r.detail = Tx(L"İnternet bağlantısı kurulamadı.", L"The connection failed.");
            r.advice = Tx(L"İnternet bağlantını, VPN'ini ve güvenlik duvarını kontrol edip yeniden dene.",
                          L"Check your internet connection, VPN and firewall, then try again.");
            break;
        case realm::kExitDownload:
            r.problem = Problem::Network;
            r.title = Tx(L"İndirme tamamlanamadı", L"The download did not finish");
            r.detail = Tx(L"Bağlantı indirme sırasında kesildi.", L"The connection dropped during the download.");
            r.advice = Tx(L"Bağlantını kontrol edip yeniden dene. İndirme kaldığı yerden sürer.",
                          L"Check your connection and try again. The download continues where it stopped.");
            break;
        case realm::kExitSignature:
            r.problem = Problem::Verification;
            r.title = Tx(L"Güncelleme doğrulanamadı", L"The update could not be verified");
            r.detail = Tx(L"İmza veya sertifika denetimi başarısız oldu.", L"The signature or certificate check failed.");
            r.advice = Tx(L"Bilgisayarının tarih ve saatini kontrol et. Sorun sürerse Destek'ten bize yaz.",
                          L"Check your computer's date and time. If it keeps happening, contact Support.");
            break;
        case realm::kExitIntegrity:
            r.problem = Problem::Verification;
            r.title = Tx(L"İndirilen dosya bozuk", L"A downloaded file is damaged");
            r.detail = Tx(L"Dosya denetimden geçemedi; kurulmadı.", L"It failed its check and was not installed.");
            r.advice = retry;
            break;
        case realm::kExitProtocol:
            r.problem = Problem::Incompatible;
            r.title = Tx(L"Yeni sürüm bekleniyor", L"Waiting for a new version");
            r.detail = Tx(L"Bu sürüm sunucuyla uyumsuz.", L"This version does not match the server.");
            r.advice = Tx(L"Sunucu güncelleniyor olabilir. Birkaç dakika sonra yeniden dene.",
                          L"The server may be updating. Try again in a few minutes.");
            break;
        case realm::kExitSelfUpdateFailed:
            r.problem = Problem::LauncherUpdate;
            r.title = Tx(L"Launcher güncellenemedi", L"The launcher could not update");
            r.detail = Tx(L"Bu sürüm daha yeni bir launcher istiyor.", L"This version needs a newer launcher.");
            r.advice = realm::GetEnvW(L"ITCHIO_APP") == L"1"
                           ? Tx(L"itch uygulamasından oyunun güncellemesini kur.",
                                L"Install the game's update from the itch app.")
                           : Tx(L"Launcher'ı indirme sayfasından yeniden indirip kur.",
                                L"Download the launcher again from the download page.");
            break;
        case realm::kExitGameRunning:
            r.title = Tx(L"Oyun açık", L"The game is open");
            r.detail = Tx(L"Oyun açıkken güncelleme yapılamaz.", L"It can't be updated while it is running.");
            r.advice = Tx(L"Oyunu kapatıp yeniden dene.", L"Close the game and try again.");
            break;
        case realm::kExitConfig:
            r.title = Tx(L"Launcher ayarları hatalı", L"The launcher's settings are invalid");
            r.detail = Tx(L"Yapılandırma dosyası okunamadı.", L"Its configuration could not be used.");
            r.advice = retry;
            break;
        default:
            r.title = Tx(L"Bir sorun oluştu", L"Something went wrong");
            r.detail = raw.empty() ? std::wstring(Tx(L"Bilinmeyen bir hata.", L"An unknown error."))
                                   : realm::Utf8ToWide(raw);
            r.advice = retry;
            break;
    }
    return r;
}

// The user-facing reason a repair failed. RepairImpl answers kExitLocalVerify
// two ways: before it starts (no installation, or one older than the release
// when the release has no package for it - an update fixes both) and after it
// ran but files are still missing/corrupt (the answer then lists them).
Report RepairReport(const realm::CommandResult& r) {
    std::string message;
    realm::JsonValue root;
    std::string perr;
    bool parsed = realm::JsonValue::Parse(r.json, root, perr) && root.isObject();
    if (parsed) message = root.str("message");
    if (r.code != realm::kExitLocalVerify) return DescribeError(message, r.code);
    Report out;
    out.title = Tx(L"Onarım başarısız", L"The repair failed");
    const auto* missing = parsed ? root.arr("missing") : nullptr;
    const auto* corrupt = parsed ? root.arr("corrupt") : nullptr;
    if (missing || corrupt) {
        size_t n = (missing ? missing->size() : 0) + (corrupt ? corrupt->size() : 0);
        if (const auto* failed = root.arr("failed")) n = std::max(n, failed->size());
        out.detail = std::to_wstring(n) + Tx(L" dosya onarılamadı.", L" file(s) could not be repaired.");
        out.advice = Tx(L"Oyunu ve launcher'ı kapatıp yeniden aç, sonra Dosyaları onar'ı tekrar dene.",
                        L"Close the game and the launcher, reopen the launcher and run Repair files again.");
    } else {
        out.detail = Tx(L"Oyun eksik ya da güncel değil.", L"The game is missing or out of date.");
        out.advice = Tx(L"TEKRAR DENE ile oyunu güncelle.", L"Press TRY AGAIN to update the game.");
    }
    return out;
}

void ShowReport(Phase phase, const Report& r, const std::wstring& detailSuffix = L"") {
    SetState(phase, r.title, r.detail + detailSuffix, r.advice, r.problem);
}

bool InstalledGamePresent() {
    realm::UpdaterPaths paths = realm::ResolvePathsForGui(g_Cfg);
    return !paths.gameExe.empty() && realm::FileExists(paths.gameExe);
}

void ApplySummary(const realm::CheckSummary& s) {
    std::lock_guard<std::mutex> lock(g_Mutex);
    g_InstalledVersion = s.installedVersion;
    g_ReleaseVersion = s.releaseVersion;
    g_Notes = realm::Utf8ToWide(s.releaseNotes);
    // The server pill belongs to StatusWorker (it understands services that
    // predate /api/status); the check may only add "under maintenance".
    if (s.maintenance) g_ServerState = L"MAINTENANCE";
}

// Phase::Ready as the server allows it right now.
void ShowReady() {
    std::wstring server, version;
    {
        std::lock_guard<std::mutex> lock(g_Mutex);
        server = g_ServerState;
        version = std::wstring(Tx(L"Sürüm ", L"Version ")) + realm::Utf8ToWide(g_InstalledVersion);
    }
    if (server == L"MAINTENANCE") {
        SetState(Phase::Ready, Tx(L"Sunucu bakımda", L"The server is under maintenance"),
                 version + Tx(L"  ·  Oyun güncel.", L"  ·  Your game is up to date."),
                 Tx(L"Bakım bitince giriş yapabilirsin. Bu pencere açık kalırsa durum kendiliğinden güncellenir.",
                    L"You can log in when it ends. Leave this window open and the status updates by itself."),
                 Problem::Maintenance);
    } else if (server == L"OFFLINE") {
        SetState(Phase::Ready, Tx(L"Oyun sunucusuna ulaşılamıyor", L"Can't reach the game server"),
                 version + Tx(L"  ·  Oyun güncel.", L"  ·  Your game is up to date."),
                 Tx(L"İnternet bağlantını kontrol et. Bağlantın sağlamsa sunucu geçici olarak kapalı olabilir.",
                    L"Check your internet connection. If it works, the server may be down for a moment."),
                 Problem::ServerOffline);
    } else {
        std::wstring advice;
        if (realm::LauncherRunsFromTemporaryLocation())
            advice = Tx(L"Launcher'ı Uygulamalar klasörüne taşı; böylece kendini güncelleyebilir.",
                        L"Move the launcher to your Applications folder so it can update itself.");
        SetState(Phase::Ready, Tx(L"Oyun hazır", L"Ready to play"),
                 version + Tx(L"  ·  Her şey hazır.", L"  ·  All set."), advice);
    }
}

}  // namespace

// Check -> (self-update | download + install) -> ready. Runs on its own thread.
void UpdateWorker(bool repair) {
    g_Cancel = false;
    realm::CliOptions cli;
    auto status = [](const std::wstring&) {};
    auto progress = [](uint64_t done, uint64_t total) {
        g_Done = done;
        g_Total = total;
        Phase p = CurrentPhase();
        if (p == Phase::Downloading || p == Phase::SelfUpdating) {
            int pct = total ? (int)((done * 100) / total) : 0;
            std::wstring percent = i18n::Current() == i18n::Lang::Turkish ? L"%" + std::to_wstring(pct)
                                                                         : std::to_wstring(pct) + L"%";
            std::wstring d = percent + L"  ·  " + BytesText(done) + L" / " + BytesText(total);
            std::lock_guard<std::mutex> lock(g_Mutex);
            g_Detail = d;
        }
        PostRefresh();
    };
    const wchar_t* playAnyway = Tx(L" Mevcut sürümle oynayabilirsin.", L" You can still play the installed version.");

    if (repair) {
        g_Done = 0;
        g_Total = 0;
        SetState(Phase::Installing, Tx(L"Oyun dosyaları onarılıyor", L"Repairing the game files"),
                 Tx(L"Dosyalar doğrulanıyor ve eksikler indiriliyor…", L"Checking files and downloading what is missing…"));
        realm::CommandResult r = realm::DoRepair(cli, g_Cfg, &g_Cancel, status);
        if (r.code != realm::kExitOk) {
            // A failed repair must never read as "ready": the check below only
            // compares versions, so it would report a broken install as fine.
            realm::LogMsg("[Launcher] repair failed: " + r.json);
            ShowReport(Phase::Failed, RepairReport(r));
            g_WorkerBusy = false;
            PostRefresh();
            return;
        }
    }

    SetState(Phase::Checking, Tx(L"Güncellemeler kontrol ediliyor", L"Checking for updates"),
             Tx(L"Yeni sürüm olup olmadığına bakılıyor…", L"Looking for a new version…"));
    realm::CheckSummary s = realm::DoCheck(cli, g_Cfg, &g_Cancel, status);
    if (!s.ok) {
        realm::LogMsg("[Launcher] update check failed: " + s.error);
        Report report = DescribeError(s.error, s.errorCode);
        if (InstalledGamePresent()) {
            ShowReport(Phase::ReadyStale, report, playAnyway);
        } else {
            ShowReport(Phase::Failed, report);
        }
        g_WorkerBusy = false;
        PostRefresh();
        return;
    }
    ApplySummary(s);

    if (s.gameRunning) {
        SetState(Phase::GameRunning, Tx(L"Oyun şu an açık", L"The game is open"),
                 Tx(L"Güncelleme, oyun kapandıktan sonra yapılacak.", L"Updates wait until it closes."));
        g_WorkerBusy = false;
        PostRefresh();
        return;
    }

    if (s.launcherBlocked) {
        Report report = DescribeError("", realm::kExitSelfUpdateFailed);
        ShowReport(InstalledGamePresent() ? Phase::ReadyStale : Phase::Failed, report);
        g_WorkerBusy = false;
        PostRefresh();
        return;
    }

    if (s.selfUpdateRequired || s.updateRequired || s.updateAvailable) {
        g_Done = 0;
        g_Total = 0;
        if (s.selfUpdateRequired) {
            SetState(Phase::SelfUpdating, Tx(L"Launcher güncelleniyor", L"Updating the launcher"),
                     Tx(L"Yeni launcher indiriliyor…", L"Downloading the new launcher…"));
        } else {
            std::wstring what = s.installedVersion.empty() ? Tx(L"Oyun indiriliyor", L"Downloading the game")
                                                           : Tx(L"Güncelleme indiriliyor", L"Downloading the update");
            SetState(Phase::Downloading, what + L"  ·  v" + realm::Utf8ToWide(s.releaseVersion),
                     Tx(L"Başlıyor…", L"Starting…"));
        }
        std::atomic<bool> installingShown{false};
        auto status2 = [&](const std::wstring& text) {
            if (!installingShown && text.find(L"Verifying") != std::wstring::npos) {
                installingShown = true;
                SetState(Phase::Installing, Tx(L"Güncelleme kuruluyor", L"Installing the update"),
                         Tx(L"Dosyalar doğrulanıyor ve yerleştiriliyor…", L"Checking and placing the files…"));
            }
        };
        realm::CommandResult r = realm::DoUpdate(cli, g_Cfg, &g_Cancel, status2, progress);
        if (r.code == realm::kExitSelfUpdateDone) {
            SetState(Phase::SelfUpdating, Tx(L"Launcher güncellendi", L"Launcher updated"),
                     Tx(L"Yeniden başlatılıyor…", L"Restarting…"));
            if (g_Hooks.exitForSelfUpdate) g_Hooks.exitForSelfUpdate();
            return;
        }
        if (r.code != realm::kExitOk) {
            realm::LogMsg("[Launcher] update failed: " + r.json);
            std::string message;
            realm::JsonValue root;
            std::string perr;
            if (realm::JsonValue::Parse(r.json, root, perr) && root.isObject()) message = root.str("message");
            Report report = DescribeError(message, r.code);
            if (InstalledGamePresent() && r.code != realm::kExitProtocol) {
                ShowReport(Phase::ReadyStale, report, playAnyway);
            } else {
                ShowReport(Phase::Failed, report);
            }
            g_WorkerBusy = false;
            PostRefresh();
            return;
        }
        // What is installed now comes from the update's own answer: a third
        // full check (manifest, signature and status over fresh connections)
        // only to learn the version just installed cost about a second.
        realm::JsonValue done;
        std::string derr;
        if (realm::JsonValue::Parse(r.json, done, derr) && done.isObject()) {
            std::string v = done.str("installed_version");
            if (v.empty()) v = done.str("to_version");
            if (!v.empty()) {
                std::lock_guard<std::mutex> lock(g_Mutex);
                g_InstalledVersion = v;
            }
        }
    }

    ShowReady();
    g_WorkerBusy = false;
    PostRefresh();
}

void StartWorker(bool repair) {
    bool expected = false;
    if (!g_WorkerBusy.compare_exchange_strong(expected, true)) return;
    std::thread(UpdateWorker, repair).detach();
}

// Server status only (cheap, plain HTTP): keeps the pill honest while idle.
void StatusWorker() {
    realm::HttpRequestOptions opts;
    opts.url = realm::StatusUrl(realm::CliOptions{}, g_Cfg);
    opts.allowPlainHttp = true;
    opts.systemTrust = true;
    opts.maxBodyBytes = 64 * 1024;
    opts.receiveTimeoutMs = 8000;
    std::string body;
    realm::HttpOutcome out = realm::HttpGetToString(opts, body);
    std::wstring state = L"OFFLINE";
    if (out.ok) {
        realm::JsonValue root;
        std::string err;
        if (realm::JsonValue::Parse(body, root, err) && root.isObject()) {
            state = root.boolean("maintenance", false) ? L"MAINTENANCE" : L"ONLINE";
        }
    } else if (out.status == 404) {
        state = L"ONLINE";   // a service that predates /api/status
    } else if (out.status == 503) {
        state = L"MAINTENANCE";
    }
    {
        std::lock_guard<std::mutex> lock(g_Mutex);
        g_ServerState = state;
    }
    if (CurrentPhase() == Phase::Ready) ShowReady();
    g_StatusBusy = false;
    PostRefresh();
}

void StartStatusPoll() {
    if (realm::StatusUrl(realm::CliOptions{}, g_Cfg).empty()) return;
    bool expected = false;
    if (!g_StatusBusy.compare_exchange_strong(expected, true)) return;
    std::thread(StatusWorker).detach();
}

namespace {

Report GameStartReport(int error) {
    Report r;
    r.problem = Problem::GameStart;
    r.title = Tx(L"Oyun başlatılamadı", L"The game could not start");
    r.detail = Tx(L"Oyun dosyaları eksik ya da engellenmiş olabilir.", L"Its files may be missing or blocked.");
    r.advice = Tx(L"Dosyaları onar'ı dene. Sorun sürerse Destek'ten bize yaz.",
                  L"Try Repair files. If it keeps happening, contact Support.");
#ifdef _WIN32
    if (error == 5 || error == 225) {  // access denied, blocked as a threat
        r.detail = Tx(L"Windows ya da bir güvenlik programı oyunu engelledi.",
                      L"Windows or a security program blocked the game.");
        r.advice = Tx(L"Güvenlik programının engellenenler listesine bak, sonra Dosyaları onar'ı dene.",
                      L"Check your security program's blocked items, then try Repair files.");
    }
#else
    if (error == EACCES || error == EPERM) {
        r.detail = Tx(L"Sistem, oyunun bu klasörden çalışmasına izin vermedi.",
                      L"The system did not allow the game to run from its folder.");
        r.advice = std::wstring(Tx(L"Bu klasörün bulunduğu disk program çalıştırmaya kapalı olabilir: ",
                                   L"The drive holding this folder may not allow programs to run: ")) +
                   realm::ResolvePathsForGui(g_Cfg).installRoot;
    }
#endif
    return r;
}

std::wstring ExitText(const GameExit& exit) {
#ifndef _WIN32
    if (exit.signal != 0)
        return std::wstring(Tx(L"Sinyal ", L"Signal ")) + std::to_wstring(exit.signal);
#endif
    wchar_t hex[16];
    unsigned value = (unsigned)exit.code;
    if (value >= 0x10000u) {
        swprintf(hex, 16, L"0x%08X", value);
        return std::wstring(Tx(L"Çıkış kodu ", L"Exit code ")) + hex;
    }
    return std::wstring(Tx(L"Çıkış kodu ", L"Exit code ")) + std::to_wstring(exit.code);
}

bool ExitLooksLikeCrash(const GameExit& exit) {
#ifndef _WIN32
    if (exit.signal == SIGTERM || exit.signal == SIGHUP || exit.signal == SIGINT) return false;
    if (exit.signal != 0) return true;
#endif
    return exit.code != 0;
}

void ShowGameEnded(bool crashed, const GameExit& exit) {
    Report r;
    const wchar_t* advice = Tx(L"Dosyaları onar'ı dene ve grafik sürücünü güncelle. Sürerse Kayıtlar klasöründeki "
                               L"godot.log dosyasıyla Destek'ten bize yaz.",
                               L"Try Repair files and update your graphics driver. If it keeps happening, contact "
                               L"Support with godot.log from the Logs folder.");
    if (crashed) {
        r.problem = Problem::GameCrashed;
        r.title = Tx(L"Oyun beklenmedik şekilde kapandı", L"The game closed unexpectedly");
    } else {
        r.problem = Problem::GameClosedEarly;
        r.title = Tx(L"Oyun açılır açılmaz kapandı", L"The game closed right after starting");
    }
    r.detail = ExitText(exit);
    r.advice = advice;
    ShowReport(Phase::Failed, r);
    if (g_Hooks.restoreWindow) g_Hooks.restoreWindow();
}

}  // namespace

bool OnPlay() {
    Phase p = CurrentPhase();
    if (p == Phase::Failed) {
        StartWorker();
        return false;
    }
    if (p != Phase::Ready && p != Phase::ReadyStale) return false;
    realm::UpdaterPaths paths = realm::ResolvePathsForGui(g_Cfg);
    std::wstring mark = CleanExitMark();
    if (!mark.empty()) realm::DeleteFileQuiet(mark);
    if (!realm::LaunchGameClient(paths, g_Game)) {
        ShowReport(Phase::Failed, GameStartReport(g_Game.error));
        return false;
    }
    g_GameStarted = std::chrono::steady_clock::now();
    SetState(Phase::GameRunning, Tx(L"Oyun açık", L"The game is open"),
             Tx(L"İyi oyunlar! Launcher arka planda bekliyor.", L"Have fun! The launcher waits in the background."));
    return true;
}

bool PollGame() {
    if (CurrentPhase() != Phase::GameRunning) return false;
    realm::UpdaterPaths paths = realm::ResolvePathsForGui(g_Cfg);
    GameExit exit;
    if (realm::PollGameExit(g_Game, exit)) {
        auto ranMs = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() -
                                                                           g_GameStarted).count();
        realm::LogMsg("[Launcher] game ended after " + std::to_string(ranMs) + " ms, code " +
                      std::to_string(exit.code) + ", signal " + std::to_string(exit.signal));
        // The game may have restarted itself (renderer fallback): the new
        // process is then followed by the scan below.
        if (realm::IsGameRunningNow(paths, g_Cfg, nullptr)) return true;
        bool crashed = ExitLooksLikeCrash(exit);
        std::wstring mark = CleanExitMark();
        bool quit = !crashed && !mark.empty() && realm::FileExists(mark);
        if (quit) realm::LogMsg("[Launcher] the game says the player quit");
        if (crashed || (ranMs < kEarlyExitMs && !quit)) {
            ShowGameEnded(crashed, exit);
            return false;
        }
        StartWorker();
        return false;
    }
    if (g_Game.tracked) return true;
    if (!realm::IsGameRunningNow(paths, g_Cfg, nullptr)) {
        // The game closed: look for an update that may have landed meanwhile.
        StartWorker();
        return false;
    }
    return true;
}

void Init(const AppConfig& cfg, Hooks hooks) {
    g_Cfg = cfg;
    g_Hooks = std::move(hooks);
}

void SetNotices(const void* data, size_t size) {
    g_NoticesData = data;
    g_NoticesSize = size;
}

uint64_t ProgressDone() { return g_Done.load(); }
uint64_t ProgressTotal() { return g_Total.load(); }
void Cancel() { g_Cancel = true; }

void RequestRepair() {
    Phase p = CurrentPhase();
    if (p == Phase::Ready || p == Phase::ReadyStale || p == Phase::Failed) StartWorker(true);
}

void OnRecheckTimer() {
    Phase p = CurrentPhase();
    if (p == Phase::Ready || p == Phase::ReadyStale) StartWorker();
}

void OpenSupport() {
    if (g_Hooks.openUrl) g_Hooks.openUrl(kSupportUrl);
}

void OpenLicenses() {
    if (!g_NoticesData || !g_Hooks.openPath) return;
    std::wstring path = realm::JoinPath(realm::TempDirPath(), L"ThousandRealms-Third-Party-Notices.txt");
    if (realm::WriteFileBytes(path, g_NoticesData, g_NoticesSize)) g_Hooks.openPath(path);
}

void OpenLogs() {
    if (!g_Hooks.openPath) return;
    std::wstring gameDir = realm::GameUserDataDir();
    std::wstring logs = gameDir.empty() ? L"" : realm::JoinPath(gameDir, L"logs");
    if (logs.empty() || !realm::DirExists(logs)) logs = realm::ResolvePathsForGui(g_Cfg).installRoot;
    realm::CreateDirs(logs);
    g_Hooks.openPath(logs);
}

bool ShowTestState(const std::string& name) {
    {
        std::lock_guard<std::mutex> lock(g_Mutex);
        g_InstalledVersion = "2.0.12";
        g_ReleaseVersion = "2.0.13";
        g_Notes = Tx(L"Zindan dengesi, yeni görevler ve daha akıcı giriş ekranı.",
                     L"Dungeon balance, new quests and a smoother login screen.");
        g_ServerState = L"ONLINE";
    }
    GameExit crash;
    crash.code = (int)0xC0000005u;
    const wchar_t* playAnyway = Tx(L" Mevcut sürümle oynayabilirsin.", L" You can still play the installed version.");
    if (name == "ready") {
        ShowReady();
    } else if (name == "checking") {
        SetState(Phase::Checking, Tx(L"Güncellemeler kontrol ediliyor", L"Checking for updates"),
                 Tx(L"Yeni sürüm olup olmadığına bakılıyor…", L"Looking for a new version…"));
    } else if (name == "downloading") {
        g_Done = 512ull << 20;
        g_Total = 2048ull << 20;
        SetState(Phase::Downloading, std::wstring(Tx(L"Oyun indiriliyor", L"Downloading the game")) + L"  ·  v2.0.13",
                 (i18n::Current() == i18n::Lang::Turkish ? L"%25  ·  " : L"25%  ·  ") + BytesText(g_Done) + L" / " +
                     BytesText(g_Total));
    } else if (name == "network") {
        ShowReport(Phase::Failed, DescribeError("", realm::kExitNetwork));
    } else if (name == "stale") {
        ShowReport(Phase::ReadyStale, DescribeError("", realm::kExitNetwork), playAnyway);
    } else if (name == "disk") {
        ShowReport(Phase::Failed, DiskReport(2300ull << 20, 512ull << 20));
    } else if (name == "verify") {
        ShowReport(Phase::Failed, DescribeError("", realm::kExitSignature));
    } else if (name == "maintenance" || name == "offline") {
        {
            std::lock_guard<std::mutex> lock(g_Mutex);
            g_ServerState = name == "offline" ? L"OFFLINE" : L"MAINTENANCE";
        }
        ShowReady();
    } else if (name == "start") {
        ShowReport(Phase::Failed, GameStartReport(0));
    } else if (name == "crash") {
        ShowGameEnded(true, crash);
    } else if (name == "early") {
        ShowGameEnded(false, GameExit{});
    } else if (name == "notes") {
        // Notes as a release writes them: both languages, longer than the panel.
        {
            std::lock_guard<std::mutex> lock(g_Mutex);
            g_InstalledVersion = g_ReleaseVersion = "2.0.24";
            g_Notes =
                L"TR: Yeni ölüm ekranı: dünya grileşip kararır, seni kimin alt ettiği yazar, zindanda ölüm cezası ve "
                L"kaçıncı ölüm olduğu görünür; \"Burada Diril\" ve \"Girişe/Şehre Dön\" geri sayım halkalı kartlarla "
                L"seçilir. Dirilince 3 saniye mavi, saydam bir ruh olursun ve kalkarken yürüyemezsin. Öldüğünde "
                L"canavarlar saldırıyı bırakıp oldukları yerde bekler, eve kaçmaz.\n"
                L"EN: New death screen: the world drains to grey, it names who struck you down, and in a dungeon shows "
                L"the death penalty and which death this is; \"Revive Here\" and \"Return to the Entrance/Town\" are "
                L"cards with a countdown ring. For 3 seconds after rising you are a translucent blue spirit and cannot "
                L"walk while you stand up. When you fall, creatures stop attacking and wait where they are instead of "
                L"running home.";
        }
        ShowReady();
    } else {
        return false;
    }
    return true;
}

}  // namespace app
}  // namespace realm
