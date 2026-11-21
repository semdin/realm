// Thousand Realms launcher (GUI).
//
// The launcher only installs, updates and starts the game: signing in happens
// on the game's own login screen. On start it checks the signed release
// manifest (GitHub Releases, see common.h REALM_DEFAULT_RELEASE_BASE),
// replaces itself first when the release ships a newer launcher, downloads and
// activates a newer client when there is one, and then offers PLAY.
//
// The window is borderless and fully custom drawn with GDI+; the background
// art and the two fonts are embedded resources (app.rc), so a lone
// ThousandRealms_Launcher.exe renders the complete design. Every network call runs on a
// worker thread; the UI thread only reads the shared state under g_Mutex.
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <objidl.h>
#include <gdiplus.h>
#include <windowsx.h>
#include <shellapi.h>
#include <shlwapi.h>
#include <dwmapi.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "http.h"
#include "i18n.h"
#include "json.h"
#include "launcher_app.h"
#include "updater.h"

using namespace Gdiplus;

#define IDI_MAIN 101
#define IDR_BACKGROUND 201
#define IDR_FONT_TITLE 202
#define IDR_FONT_BODY 203
#define IDR_LOGO 204
#define IDR_NOTICES 205

#define WM_APP_REFRESH (WM_APP + 1)   // worker -> UI: state changed, repaint
#define WM_APP_EXIT (WM_APP + 2)      // worker -> UI: self-update handed off, quit
#define WM_APP_RESTORE (WM_APP + 3)   // the game failed: bring the launcher back

namespace {

using realm::app::Phase;
using realm::app::kGameTitle;
using realm::app::Snapshot;
using realm::app::TakeSnapshot;
using realm::app::PlayLabel;
using realm::app::PlayEnabled;
using realm::app::CurrentPhase;
using realm::app::StartWorker;
using realm::app::StartStatusPoll;

// ------------------------------------------------------------------ palette
// The GDI+ mirror of the game theme.
namespace Pal {
const Color Ink(255, 11, 13, 18);
const Color Night(255, 18, 20, 27);
const Color Steel(255, 58, 65, 82);
const Color Parchment(255, 236, 225, 192);
const Color Text(255, 207, 202, 186);
const Color Dim(255, 153, 152, 142);
const Color Gold(255, 168, 137, 47);
const Color GoldLt(255, 216, 182, 74);
const Color GoldHi(255, 244, 226, 160);
const Color GoldDk(255, 90, 69, 32);
const Color Blood(255, 92, 22, 32);
const Color BloodLt(255, 124, 31, 43);
const Color BloodDk(255, 58, 13, 18);
const Color Good(255, 92, 201, 74);
const Color Warn(255, 255, 189, 92);
const Color Bad(255, 236, 104, 92);
}  // namespace Pal

// One launcher at a time. Launchers from before the rename know only the old
// names, so this one holds and looks for both: old and new can never run side
// by side, whichever started first.
const wchar_t* const kInstanceMutexes[] = {L"Local\\ThousandRealms_Launcher_Singleton",
                                           L"Local\\HPMMO_Launcher_Singleton"};
const wchar_t kWindowClass[] = L"ThousandRealms_Launcher_Class";
const wchar_t kLegacyWindowClass[] = L"HPMMO_Launcher_Class";

constexpr int kBaseW = 980;
constexpr int kBaseH = 580;
constexpr int kTopBar = 44;
constexpr UINT_PTR kTimerAnim = 1;
constexpr UINT_PTR kTimerStatus = 2;
constexpr UINT_PTR kTimerGame = 3;
constexpr UINT_PTR kTimerRecheck = 4;
constexpr UINT kStatusPollMs = 30000;
constexpr UINT kRecheckMs = 10 * 60 * 1000;   // look for a new release while idle

// ------------------------------------------------------------------ state
enum class Hit { None, Play, Close, Minimize, Repair, Support, Licenses, Logs, Notes, SheetClose, Sheet, Backdrop };

HWND g_Wnd = NULL;
float g_Scale = 1.0f;
Hit g_Hover = Hit::None;
Hit g_Pressed = Hit::None;
float g_Anim = 0.0f;
bool g_Tracking = false;

// The notes sheet: the whole "what's new" text over the dimmed launcher,
// opened from the panel when its text does not fit there.
bool g_NotesCut = false;          // the panel had to cut the text (set by the paint)
bool g_SheetOpen = false;
float g_SheetOpenedAt = 0.0f;     // g_Anim when it opened (fade in)
float g_SheetScroll = 0.0f;       // px, eased towards g_SheetScrollTo
float g_SheetScrollTo = 0.0f;
float g_SheetScrollMax = 0.0f;    // set by the paint
float g_SheetPage = 0.0f;         // visible body height, for Page Up/Down
Gdiplus::RectF g_SheetCard, g_SheetClose;   // where the paint put them (hit tests)

ULONG_PTR g_GdiToken = 0;
PrivateFontCollection* g_Fonts = nullptr;
FontFamily* g_TitleFamily = nullptr;
FontFamily* g_BodyFamily = nullptr;
Bitmap* g_Background = nullptr;
// Everything that changes only with the window size, the scale or the
// language (key art, shades, crest, subtitle), painted once (BuildBase).
Bitmap* g_Base = nullptr;
std::wstring g_BaseKey;
Bitmap* g_Logo = nullptr;               // the crest: horizontal game logo


int S(float v) { return (int)std::lround(v * g_Scale); }
float SF(float v) { return v * g_Scale; }

// ------------------------------------------------------------------ resources
bool LoadResourceBytes(int id, const void** data, DWORD* size) {
    HRSRC res = FindResourceW(NULL, MAKEINTRESOURCEW(id), MAKEINTRESOURCEW(10) /* RT_RCDATA */);
    if (!res) return false;
    HGLOBAL h = LoadResource(NULL, res);
    if (!h) return false;
    *data = LockResource(h);
    *size = SizeofResource(NULL, res);
    return *data != nullptr && *size > 0;
}

FontFamily* FamilyOrFallback(const wchar_t* name, const wchar_t* fallback) {
    FontFamily* fam = new FontFamily(name, g_Fonts);
    if (fam->GetLastStatus() == Ok) return fam;
    delete fam;
    fam = new FontFamily(fallback);
    if (fam->GetLastStatus() == Ok) return fam;
    delete fam;
    return FontFamily::GenericSerif()->Clone();
}

// An embedded image, decoded and copied out of its stream (nullptr on failure).
Bitmap* LoadResourceBitmap(int id) {
    const void* data = nullptr;
    DWORD size = 0;
    if (!LoadResourceBytes(id, &data, &size)) return nullptr;
    IStream* stream = SHCreateMemStream((const BYTE*)data, (UINT)size);
    if (!stream) return nullptr;
    Bitmap* copy = nullptr;
    Bitmap* decoded = Bitmap::FromStream(stream);
    if (decoded && decoded->GetLastStatus() == Ok)
        copy = decoded->Clone(0, 0, decoded->GetWidth(), decoded->GetHeight(), PixelFormat32bppPARGB);
    delete decoded;
    stream->Release();
    return copy;
}

void LoadAssets() {
    g_Fonts = new PrivateFontCollection();
    const void* data = nullptr;
    DWORD size = 0;
    if (LoadResourceBytes(IDR_FONT_TITLE, &data, &size)) g_Fonts->AddMemoryFont(data, (INT)size);
    if (LoadResourceBytes(IDR_FONT_BODY, &data, &size)) g_Fonts->AddMemoryFont(data, (INT)size);
    // The game's face (Pretendard Std, official static Bold and Medium).
    g_TitleFamily = FamilyOrFallback(L"Pretendard Std", L"Segoe UI");
    g_BodyFamily = FamilyOrFallback(L"Pretendard Std Medium", L"Segoe UI");

    g_Background = LoadResourceBitmap(IDR_BACKGROUND);
    g_Logo = LoadResourceBitmap(IDR_LOGO);
}

void FreeAssets() {
    delete g_Base;
    g_Base = nullptr;
    delete g_Background;
    delete g_Logo;
    g_Logo = nullptr;
    delete g_TitleFamily;
    delete g_BodyFamily;
    delete g_Fonts;
    g_Background = nullptr;
    g_TitleFamily = g_BodyFamily = nullptr;
    g_Fonts = nullptr;
}

// A face at a size: the family's first available style (the title face only
// ships Bold), `px` already in client pixels.
struct TextFont {
    FontFamily* family = nullptr;
    INT style = FontStyleRegular;
    float px = 12.0f;
};

TextFont MakeFont(FontFamily* fam, float px, INT wanted = FontStyleRegular) {
    INT style = wanted;
    if (!fam->IsStyleAvailable(style)) style = fam->IsStyleAvailable(FontStyleBold) ? FontStyleBold : FontStyleRegular;
    return TextFont{fam, style, SF(px)};
}

// ------------------------------------------------------------------ drawing
void RoundedPath(GraphicsPath& path, const RectF& r, float radius) {
    float d = std::min(radius * 2.0f, std::min(r.Width, r.Height));
    if (d <= 0.5f) {
        path.AddRectangle(r);
        return;
    }
    path.AddArc(r.X, r.Y, d, d, 180, 90);
    path.AddArc(r.X + r.Width - d, r.Y, d, d, 270, 90);
    path.AddArc(r.X + r.Width - d, r.Y + r.Height - d, d, d, 0, 90);
    path.AddArc(r.X, r.Y + r.Height - d, d, d, 90, 90);
    path.CloseFigure();
}

void FillRound(Graphics& g, const RectF& r, float radius, const Brush& brush) {
    GraphicsPath path;
    RoundedPath(path, r, radius);
    g.FillPath(&brush, &path);
}

void StrokeRound(Graphics& g, const RectF& r, float radius, const Color& c, float width) {
    GraphicsPath path;
    RoundedPath(path, r, radius);
    Pen pen(c, width);
    g.DrawPath(&pen, &path);
}

Color WithAlpha(const Color& c, BYTE a) { return Color(a, c.GetR(), c.GetG(), c.GetB()); }

// GDI+ tiles a LinearGradientBrush past its end points (WrapModeTile): a shape
// that reaches beyond them takes its colour from the opposite end. The Play
// button's highlight band ran 2 px past its gradient, so those rows came back
// at the band's brightest - the light line across the middle of the button,
// whatever its label. Every gradient is made here: its line runs a pixel past
// both ends and mirrors there (TileFlipXY), so a shape's edge rows stay on the
// end colour.
struct Gradient {
    LinearGradientBrush brush;
    Gradient(PointF from, PointF to, const Color& a, const Color& b)
        : brush(Past(from, to, -1.0f), Past(to, from, -1.0f), a, b) {
        brush.SetWrapMode(WrapModeTileFlipXY);
    }
    // `p` moved `by` px along from `p` towards `q` (negative: away from it).
    static PointF Past(PointF p, PointF q, float by) {
        float dx = q.X - p.X, dy = q.Y - p.Y;
        float len = std::max(std::sqrt(dx * dx + dy * dy), 1e-3f);
        return PointF(p.X + dx / len * by, p.Y + dy / len * by);
    }
};

// ------------------------------------------------------------------ text
// Every string is filled as glyph outlines (GraphicsPath::AddString) with the
// 8x8 geometry antialiasing. GDI+'s own text rasteriser (DrawString with
// AntiAliasGridFit) snaps the glyphs to the pixel grid and shades them with
// only a few grey levels: the 12-13 px type of the top bar and the footer came
// out stair-stepped and uneven in weight, worst at 125 % where the sizes fall
// between whole pixels. Outlines keep the face's own shapes at every size, the
// way a browser draws text. Laying a string out costs more than filling it,
// so the paths are kept between frames.
std::map<std::wstring, std::unique_ptr<GraphicsPath>> g_TextPaths;

const GraphicsPath* TextPath(const std::wstring& text, const TextFont& f, const RectF& box, StringAlignment h,
                             StringAlignment v, bool ellipsis) {
    wchar_t head[192];
    swprintf(head, 192, L"%p|%d|%.3f|%.2f|%.2f|%.2f|%.2f|%d|%d|%d|", (void*)f.family, (int)f.style, f.px, box.X,
             box.Y, box.Width, box.Height, (int)h, (int)v, ellipsis ? 1 : 0);
    std::wstring key = head + text;
    auto it = g_TextPaths.find(key);
    if (it != g_TextPaths.end()) return it->second.get();
    if (g_TextPaths.size() > 400) g_TextPaths.clear();   // a resize or a long download: start over
    StringFormat fmt;
    fmt.SetAlignment(h);
    fmt.SetLineAlignment(v);
    if (ellipsis) {
        fmt.SetTrimming(StringTrimmingEllipsisCharacter);
        fmt.SetFormatFlags(StringFormatFlagsNoWrap);
    }
    auto path = std::make_unique<GraphicsPath>();
    path->AddString(text.c_str(), (INT)text.size(), f.family, f.style, f.px, box, &fmt);
    return (g_TextPaths[key] = std::move(path)).get();
}

// Fills an outline path smoothly, moved by (dx, dy).
void FillOutline(Graphics& g, const GraphicsPath* path, const Brush& brush, float dx = 0, float dy = 0,
                 SmoothingMode mode = SmoothingModeAntiAlias8x8) {
    GraphicsState state = g.Save();
    g.SetSmoothingMode(mode);
    if (dx != 0 || dy != 0) g.TranslateTransform(dx, dy);
    g.FillPath(&brush, path);
    g.Restore(state);
}

void DrawStr(Graphics& g, const std::wstring& text, const TextFont& font, const RectF& box, const Color& color,
             StringAlignment h = StringAlignmentNear, StringAlignment v = StringAlignmentNear, bool ellipsis = false) {
    if (text.empty()) return;
    SolidBrush brush(color);
    FillOutline(g, TextPath(text, font, box, h, v, ellipsis), brush);
}

// Text with a soft dark halo, for type laid straight over the key art. The
// halo is the same outline stamped around it (the coarser antialiasing is
// plenty for a shadow and keeps the frame cheap).
void DrawStrHalo(Graphics& g, const std::wstring& text, const TextFont& font, const RectF& box, const Color& color,
                 StringAlignment h = StringAlignmentNear) {
    if (text.empty()) return;
    const GraphicsPath* path = TextPath(text, font, box, h, StringAlignmentNear, false);
    SolidBrush shade(Color(70, 0, 0, 0));
    for (int dx = -2; dx <= 2; dx++) {
        for (int dy = -2; dy <= 2; dy++) {
            if (dx == 0 && dy == 0) continue;
            FillOutline(g, path, shade, dx * g_Scale * 0.6f, dy * g_Scale * 0.6f, SmoothingModeAntiAlias);
        }
    }
    SolidBrush brush(color);
    FillOutline(g, path, brush);
}

// Width of `text` as the outline path draws it (typographic, unhinted).
float MeasureWidth(const std::wstring& text, const TextFont& f) {
    if (text.empty()) return 0;
    static Bitmap* scratch = new Bitmap(4, 4, PixelFormat32bppPARGB);
    Graphics g(scratch);
    g.SetTextRenderingHint(TextRenderingHintAntiAlias);
    Font font(f.family, f.px, f.style, UnitPixel);
    StringFormat fmt(StringFormat::GenericTypographic());
    fmt.SetFormatFlags(fmt.GetFormatFlags() | StringFormatFlagsMeasureTrailingSpaces);
    RectF bounds;
    g.MeasureString(text.c_str(), (INT)text.size(), &font, PointF(0, 0), &fmt, &bounds);
    return bounds.Width;
}

// Word-wraps `text` (its own line breaks kept) into lines no wider than
// `width`. With `maxLines` (0: no limit) the last line kept ends with an
// ellipsis when text is left over; `cut` says whether any was.
std::vector<std::wstring> WrapText(const std::wstring& text, const TextFont& f, float width, size_t maxLines,
                                   bool* cut) {
    std::vector<std::wstring> all;
    size_t start = 0;
    while (start <= text.size()) {
        size_t end = text.find(L'\n', start);
        if (end == std::wstring::npos) end = text.size();
        std::wstring para = text.substr(start, end - start);
        if (!para.empty() && para.back() == L'\r') para.pop_back();
        start = end + 1;
        std::wstring line;
        size_t i = 0;
        while (i <= para.size()) {
            size_t sp = para.find(L' ', i);
            if (sp == std::wstring::npos) sp = para.size();
            std::wstring word = para.substr(i, sp - i);
            i = sp + 1;
            std::wstring trial = line.empty() ? word : line + L" " + word;
            if (line.empty() || MeasureWidth(trial, f) <= width) {
                line = trial;
            } else {
                all.push_back(line);
                line = word;
            }
        }
        all.push_back(line);
    }
    bool more = maxLines && all.size() > maxLines;
    if (more) {
        all.resize(maxLines);
        std::wstring& last = all.back();
        while (!last.empty() && MeasureWidth(last + L"\u2026", f) > width) {
            size_t sp = last.find_last_of(L' ');
            last.erase(sp == std::wstring::npos ? last.size() - 1 : sp);
        }
        while (!last.empty() && (last.back() == L' ' || last.back() == L',' || last.back() == L';' ||
                                 last.back() == L':'))
            last.pop_back();
        last += L"\u2026";
    }
    if (cut) *cut = more;
    return all;
}

// Paragraph text broken into lines by hand (GDI+ cannot space lines), laid out
// once per text and width and kept.
struct TextBlock {
    size_t lines = 0;
    float lineH = 0;
    bool cut = false;
    std::unique_ptr<GraphicsPath> path;   // every line, the block's top-left at (0, 0)
    float height() const { return lines * lineH; }
};

std::map<std::wstring, TextBlock> g_TextBlocks;

const TextBlock& LayoutBlock(const std::wstring& text, const TextFont& f, float width, float lineH, size_t maxLines) {
    auto& blocks = g_TextBlocks;
    wchar_t head[160];
    swprintf(head, 160, L"%p|%d|%.3f|%.2f|%.2f|%u|", (void*)f.family, (int)f.style, f.px, width, lineH,
             (unsigned)maxLines);
    std::wstring key = head + text;
    auto it = blocks.find(key);
    if (it != blocks.end()) return it->second;
    if (blocks.size() > 16) blocks.clear();
    // Inset 1/6 em at both ends like DrawString (and the single-line text
    // beside it); each line sits in the middle of its pitch.
    float inset = f.px / 6.0f;
    TextBlock b;
    std::vector<std::wstring> lines = WrapText(text, f, std::max(0.0f, width - 2 * inset), maxLines, &b.cut);
    b.lines = lines.size();
    b.lineH = lineH;
    b.path = std::make_unique<GraphicsPath>();
    StringFormat fmt(StringFormat::GenericTypographic());
    float pad = std::max(0.0f, (lineH - f.px * 1.2f) * 0.5f);
    for (size_t i = 0; i < lines.size(); i++) {
        if (lines[i].empty()) continue;
        b.path->AddString(lines[i].c_str(), (INT)lines[i].size(), f.family, f.style, f.px,
                          PointF(inset, i * lineH + pad), &fmt);
    }
    return blocks.emplace(key, std::move(b)).first->second;
}

// The kept text is GDI+ objects: gone before GdiplusShutdown, not after it in
// the static destructors.
void FreeTextCaches() {
    g_TextPaths.clear();
    g_TextBlocks.clear();
}

// Layout rectangles in client pixels.
struct Layout {
    float w = 0, h = 0;
    RectF close, minimize, play, progress, repair, support, licenses, logs, pill, notes;
};

Layout ComputeLayout(int cw, int ch) {
    Layout L;
    L.w = (float)cw;
    L.h = (float)ch;
    L.close = RectF(L.w - SF(46), 0, SF(46), SF(38));
    L.minimize = RectF(L.w - SF(92), 0, SF(46), SF(38));
    L.play = RectF(L.w - SF(48 + 250), L.h - SF(118), SF(250), SF(72));
    L.progress = RectF(SF(48), L.h - SF(58), L.play.X - SF(48) - SF(28), SF(10));
    L.repair = RectF(SF(48), L.h - SF(34), SF(100), SF(22));
    L.support = RectF(SF(152), L.h - SF(34), SF(58), SF(22));
    L.licenses = RectF(SF(214), L.h - SF(34), SF(66), SF(22));
    L.logs = RectF(SF(284), L.h - SF(34), SF(62), SF(22));
    L.pill = RectF(SF(52), SF(262), SF(230), SF(34));
    L.notes = RectF(SF(48), SF(316), SF(390), SF(110));
    return L;
}

Layout CurrentLayout() {
    RECT rc;
    GetClientRect(g_Wnd, &rc);
    return ComputeLayout(rc.right - rc.left, rc.bottom - rc.top);
}

bool Contains(const RectF& r, int x, int y) {
    return x >= r.X && y >= r.Y && x < r.X + r.Width && y < r.Y + r.Height;
}



void BuildBase(int cw, int ch) {
    wchar_t head[64];
    swprintf(head, 64, L"%d|%d|%.3f|", cw, ch, g_Scale);
    std::wstring key = head + std::wstring(realm::app::SubtitleText());
    if (g_Base && key == g_BaseKey) return;
    delete g_Base;
    g_Base = new Bitmap(cw, ch, PixelFormat32bppPARGB);
    g_BaseKey = key;
    Graphics g(g_Base);
    g.SetSmoothingMode(SmoothingModeAntiAlias);
    g.SetPixelOffsetMode(PixelOffsetModeHalf);
    Layout L = ComputeLayout(cw, ch);

    // --- backdrop
    if (g_Background) {
        g.SetInterpolationMode(InterpolationModeHighQualityBicubic);
        float iw = (float)g_Background->GetWidth(), ih = (float)g_Background->GetHeight();
        float scale = std::max(cw / iw, ch / ih);
        float dw = iw * scale, dh = ih * scale;
        // Anchor slightly right of centre: the hero stays in view on the right.
        float dx = (cw - dw) * 0.65f, dy = (ch - dh) * 0.5f;
        g.SetPixelOffsetMode(PixelOffsetModeDefault);
        g.DrawImage(g_Background, RectF(dx, dy, dw, dh));
        g.SetPixelOffsetMode(PixelOffsetModeHalf);
    } else {
        SolidBrush ink(Pal::Ink);
        g.FillRectangle(&ink, 0, 0, cw, ch);
    }
    {
        // Left shade behind the text column.
        float shadeW = L.w * 0.62f;
        Gradient left(PointF(0, 0), PointF(shadeW, 0), Color(235, 6, 7, 11), Color(0, 6, 7, 11));
        Color colors[] = {Color(235, 6, 7, 11), Color(190, 6, 7, 11), Color(0, 6, 7, 11)};
        REAL pos[] = {0.0f, 0.5f, 1.0f};
        left.brush.SetInterpolationColors(colors, pos, 3);
        g.FillRectangle(&left.brush, RectF(0, 0, shadeW, L.h));
        // Bottom deck.
        float deckTop = L.h - SF(170);
        Gradient deck(PointF(0, deckTop), PointF(0, L.h), Color(0, 5, 6, 10), Color(245, 5, 6, 10));
        g.FillRectangle(&deck.brush, RectF(0, deckTop, L.w, L.h - deckTop));
        // Top bar wash.
        Gradient top(PointF(0, 0), PointF(0, SF(70)), Color(170, 0, 0, 0), Color(0, 0, 0, 0));
        g.FillRectangle(&top.brush, RectF(0, 0, L.w, SF(70)));
    }

    // --- crest
    TextFont title = MakeFont(g_TitleFamily, 48, FontStyleBold);
    RectF titleBox(SF(44), SF(130), SF(560), SF(74));
    if (g_Logo) {
        g.SetInterpolationMode(InterpolationModeHighQualityBicubic);
        float lw = SF(384), lh = lw * g_Logo->GetHeight() / g_Logo->GetWidth();
        g.DrawImage(g_Logo, RectF(SF(40), SF(202) - lh, lw, lh));
    } else {
        // Without the logo: the name in gold, with a warm glow under it.
        for (int i = 6; i >= 1; i--) {
            float o = SF((float)i * 1.2f);
            for (float ox : {-o, o}) {
                DrawStr(g, kGameTitle, title, RectF(titleBox.X + ox, titleBox.Y, titleBox.Width, titleBox.Height),
                         Color((BYTE)(10 + i * 4), 255, 140, 40));
            }
        }
        DrawStr(g, kGameTitle, title, RectF(titleBox.X + SF(2), titleBox.Y + SF(3), titleBox.Width, titleBox.Height),
                 Color(200, 20, 8, 2));
        Gradient gold(PointF(0, titleBox.Y + SF(10)), PointF(0, titleBox.Y + SF(60)), Pal::GoldHi, Pal::GoldLt);
        FillOutline(g, TextPath(kGameTitle, title, titleBox, StringAlignmentNear, StringAlignmentNear, false),
                    gold.brush);
    }
    TextFont subtitle = MakeFont(g_TitleFamily, 15, FontStyleBold);
    DrawStrHalo(g, realm::app::SubtitleText(), subtitle, RectF(SF(54), SF(204), SF(520), SF(26)),
                 Pal::GoldLt);
    {
        Pen rule(WithAlpha(Pal::Gold, 200), SF(1));
        float y = SF(242);
        g.DrawLine(&rule, SF(54), y, SF(200), y);
        g.DrawLine(&rule, SF(222), y, SF(368), y);
        GraphicsPath gem;
        PointF pts[] = {PointF(SF(211), y - SF(5)), PointF(SF(216), y), PointF(SF(211), y + SF(5)),
                        PointF(SF(206), y)};
        gem.AddPolygon(pts, 4);
        SolidBrush gb(Pal::GoldLt);
        g.FillPath(&gb, &gem);
    }
}

Color Faded(const Color& c, float a) { return WithAlpha(c, (BYTE)std::lround(c.GetA() * std::clamp(a, 0.0f, 1.0f))); }

// The notes sheet: all of the panel's text on a card over the shaded
// launcher, scrolled by the wheel or the keys when it is long. Fades and
// rises in as it opens.
void PaintSheet(Graphics& g, const Layout& L, const Snapshot& s) {
    float t = std::clamp((g_Anim - g_SheetOpenedAt) / 0.18f, 0.0f, 1.0f);
    float a = 1.0f - (1.0f - t) * (1.0f - t) * (1.0f - t);

    SolidBrush shade(Color((BYTE)(165 * a), 3, 4, 7));
    g.FillRectangle(&shade, RectF(0, 0, L.w, L.h));

    TextFont head = MakeFont(g_TitleFamily, 15, FontStyleBold);
    TextFont body = MakeFont(g_BodyFamily, 14);
    float cardW = std::min(SF(600), L.w - SF(64));
    float padX = SF(32), top = SF(76), bottom = SF(30), bar = SF(14);
    float pitch = SF(23);
    const TextBlock& block = LayoutBlock(realm::app::PanelBody(s), body, cardW - padX * 2 - bar, pitch, 0);
    float maxH = L.h - SF(kTopBar) - SF(64);
    float cardH = std::min(maxH, top + block.height() + bottom);
    RectF card((L.w - cardW) / 2, SF(kTopBar) + (L.h - SF(kTopBar) - cardH) / 2 + (1.0f - a) * SF(12), cardW, cardH);
    g_SheetCard = card;

    // A soft drop shadow, then the card.
    for (int i = 3; i >= 1; i--) {
        RectF sh(card.X - SF(i * 3.0f), card.Y - SF(i * 3.0f) + SF(4), card.Width + SF(i * 6.0f),
                 card.Height + SF(i * 6.0f));
        SolidBrush sb(Color((BYTE)(26 * a), 0, 0, 0));
        FillRound(g, sh, SF(12 + i * 3.0f), sb);
    }
    Gradient fill(PointF(0, card.Y), PointF(0, card.Y + card.Height), Faded(Color(250, 15, 17, 24), a),
                  Faded(Color(250, 9, 10, 15), a));
    FillRound(g, card, SF(10), fill.brush);
    StrokeRound(g, card, SF(10), Faded(WithAlpha(Pal::Steel, 230), a), SF(1));

    // Caption with its accent, and a gold hairline fading to the right.
    Color accentColor = s.advice.empty() ? Pal::Gold : Pal::Warn;
    SolidBrush accent(Faded(accentColor, a));
    g.FillRectangle(&accent, RectF(card.X, card.Y + SF(26), SF(3), SF(20)));
    DrawStr(g, realm::app::PanelCaption(s), head, RectF(card.X + padX, card.Y + SF(24), cardW - padX * 2 - SF(40), SF(24)),
            Faded(Pal::GoldLt, a), StringAlignmentNear, StringAlignmentCenter);
    {
        float y = card.Y + SF(60);
        Gradient rule(PointF(card.X + padX, 0), PointF(card.X + card.Width - padX, 0), Faded(WithAlpha(Pal::Gold, 150), a),
                      Faded(WithAlpha(Pal::Gold, 0), a));
        g.FillRectangle(&rule.brush, RectF(card.X + padX, y, card.Width - padX * 2, SF(1)));
    }

    // Close.
    g_SheetClose = RectF(card.X + card.Width - SF(48), card.Y + SF(18), SF(34), SF(34));
    {
        bool hover = g_Hover == Hit::SheetClose;
        if (hover) {
            SolidBrush hb(Faded(Color(40, 255, 255, 255), a));
            FillRound(g, g_SheetClose, SF(6), hb);
        }
        Pen pen(Faded(hover ? Pal::Parchment : Pal::Dim, a), SF(1.4f));
        float cx = g_SheetClose.X + g_SheetClose.Width / 2, cy = g_SheetClose.Y + g_SheetClose.Height / 2, k = SF(5);
        g.DrawLine(&pen, cx - k, cy - k, cx + k, cy + k);
        g.DrawLine(&pen, cx - k, cy + k, cx + k, cy - k);
    }

    // Body, scrolled and clipped, fading out at a cut edge.
    RectF view(card.X + padX, card.Y + top, cardW - padX * 2 - bar, card.Height - top - bottom);
    g_SheetPage = view.Height;
    g_SheetScrollMax = std::max(0.0f, block.height() - view.Height);
    g_SheetScrollTo = std::clamp(g_SheetScrollTo, 0.0f, g_SheetScrollMax);
    g_SheetScroll = std::clamp(g_SheetScroll, 0.0f, g_SheetScrollMax);
    {
        GraphicsState st = g.Save();
        g.SetClip(RectF(view.X - SF(4), view.Y, view.Width + SF(8), view.Height));
        SolidBrush tb(Faded(Pal::Text, a));
        FillOutline(g, block.path.get(), tb, view.X, view.Y - std::round(g_SheetScroll));
        g.Restore(st);
        float fadeH = SF(20);
        Color edge(250, 12, 13, 19);
        if (g_SheetScroll > 0.5f) {
            Gradient f(PointF(0, view.Y), PointF(0, view.Y + fadeH), Faded(edge, a), Faded(WithAlpha(edge, 0), a));
            g.FillRectangle(&f.brush, RectF(view.X - SF(4), view.Y, view.Width + SF(8), fadeH));
        }
        if (g_SheetScroll < g_SheetScrollMax - 0.5f) {
            float y = view.Y + view.Height - fadeH;
            Gradient f(PointF(0, y), PointF(0, y + fadeH), Faded(WithAlpha(edge, 0), a), Faded(edge, a));
            g.FillRectangle(&f.brush, RectF(view.X - SF(4), y, view.Width + SF(8), fadeH));
        }
    }

    // Scroll bar: a slim steel track with a gold thumb.
    if (g_SheetScrollMax > 0.5f) {
        RectF track(card.X + card.Width - padX + SF(6), view.Y, SF(3), view.Height);
        SolidBrush tr(Faded(WithAlpha(Pal::Steel, 120), a));
        FillRound(g, track, SF(1.5f), tr);
        float thumbH = std::max(SF(28), track.Height * view.Height / block.height());
        float thumbY = track.Y + (track.Height - thumbH) * (g_SheetScroll / g_SheetScrollMax);
        SolidBrush th(Faded(WithAlpha(Pal::GoldLt, 200), a));
        FillRound(g, RectF(track.X, thumbY, track.Width, thumbH), SF(1.5f), th);
    }
}

void PaintFrame(Bitmap& frame, int cw, int ch) {
    Graphics g(&frame);
    g.SetSmoothingMode(SmoothingModeAntiAlias);
    g.SetTextRenderingHint(TextRenderingHintAntiAliasGridFit);
    g.SetPixelOffsetMode(PixelOffsetModeHalf);

    Layout L = ComputeLayout(cw, ch);
    Snapshot s = TakeSnapshot();

    // --- backdrop, crest, subtitle: the static layer, copied as it is
    BuildBase(cw, ch);
    if (g_Base) {
        g.SetCompositingMode(CompositingModeSourceCopy);
        g.DrawImage(g_Base, 0, 0);
        g.SetCompositingMode(CompositingModeSourceOver);
    }

    TextFont tiny = MakeFont(g_BodyFamily, 12);

    // --- server pill
    {
        Color dot = Pal::Dim;
        std::wstring text = realm::app::ServerLabel(s.server);
        if (s.server == L"ONLINE") dot = Pal::Good;
        else if (s.server == L"MAINTENANCE") dot = Pal::Warn;
        else if (s.server == L"OFFLINE") dot = Pal::Bad;
        SolidBrush bg(Color(190, 8, 10, 15));
        FillRound(g, L.pill, L.pill.Height / 2, bg);
        StrokeRound(g, L.pill, L.pill.Height / 2, WithAlpha(Pal::GoldDk, 230), SF(1));
        float pulse = (s.server == L"MAINTENANCE") ? (0.6f + 0.4f * std::sin(g_Anim * 4.0f)) : 1.0f;
        SolidBrush halo(WithAlpha(dot, (BYTE)(70 * pulse)));
        SolidBrush db(WithAlpha(dot, (BYTE)(255 * pulse)));
        float cx = L.pill.X + SF(18), cy = L.pill.Y + L.pill.Height / 2;
        g.FillEllipse(&halo, cx - SF(8), cy - SF(8), SF(16), SF(16));
        g.FillEllipse(&db, cx - SF(4.5f), cy - SF(4.5f), SF(9), SF(9));
        TextFont pf = MakeFont(g_BodyFamily, 14);
        DrawStr(g, text, pf, RectF(L.pill.X + SF(34), L.pill.Y, L.pill.Width - SF(40), L.pill.Height), Pal::Text,
                 StringAlignmentNear, StringAlignmentCenter);
    }

    // --- what's new: as many whole lines as fit; when the text goes on, the
    // panel opens the sheet with all of it
    bool panel = !s.notes.empty() || !s.release.empty() || !s.advice.empty();
    g_NotesCut = false;
    if (panel) {
        SolidBrush bg(Color(170, 8, 10, 15));
        FillRound(g, L.notes, SF(8), bg);
        SolidBrush accent(s.advice.empty() ? Pal::Gold : Pal::Warn);
        g.FillRectangle(&accent, RectF(L.notes.X, L.notes.Y + SF(12), SF(3), L.notes.Height - SF(24)));
        TextFont head = MakeFont(g_TitleFamily, 13, FontStyleBold);
        DrawStr(g, realm::app::PanelCaption(s), head,
                RectF(L.notes.X + SF(18), L.notes.Y + SF(12), L.notes.Width - SF(30), SF(20)), Pal::GoldLt);
        TextFont body = MakeFont(g_BodyFamily, 13);
        RectF nb(L.notes.X + SF(18), L.notes.Y + SF(38), L.notes.Width - SF(32), L.notes.Height - SF(48));
        float pitch = SF(18);
        size_t fit = std::max<size_t>(1, (size_t)(nb.Height / pitch));
        const TextBlock& block = LayoutBlock(realm::app::PanelBody(s), body, nb.Width, pitch, fit);
        SolidBrush tb(Pal::Text);
        FillOutline(g, block.path.get(), tb, nb.X, nb.Y);
        g_NotesCut = block.cut;
        bool hover = g_NotesCut && (g_Hover == Hit::Notes) && !g_SheetOpen;
        if (g_NotesCut) {
            std::wstring more = std::wstring(realm::app::ReadMoreLabel()) + L"  \u203A";
            DrawStr(g, more, tiny, RectF(L.notes.X + SF(18), L.notes.Y + SF(12), L.notes.Width - SF(34), SF(20)),
                    hover ? Pal::GoldHi : WithAlpha(Pal::GoldLt, 170), StringAlignmentFar, StringAlignmentNear);
        }
        StrokeRound(g, L.notes, SF(8), hover ? WithAlpha(Pal::Gold, 230) : WithAlpha(Pal::Steel, 200), SF(1));
    }

    // --- status block
    TextFont statusTitle = MakeFont(g_BodyFamily, 19);
    TextFont statusDetail = MakeFont(g_BodyFamily, 14);
    float statusY = L.h - SF(120);
    DrawStrHalo(g, s.title, statusTitle, RectF(SF(48), statusY, L.progress.Width, SF(28)), Pal::Parchment);
    Color detailColor = Pal::Dim;
    if (s.phase == Phase::Failed) detailColor = Pal::Bad;
    else if (s.phase == Phase::ReadyStale || s.problem != realm::app::Problem::None) detailColor = Pal::Warn;
    DrawStr(g, s.detail, statusDetail, RectF(SF(48), statusY + SF(30), L.progress.Width, SF(22)), detailColor,
             StringAlignmentNear, StringAlignmentNear, true);

    // --- progress bar
    {
        SolidBrush track(Color(200, 4, 5, 8));
        FillRound(g, L.progress, L.progress.Height / 2, track);
        StrokeRound(g, L.progress, L.progress.Height / 2, WithAlpha(Pal::Steel, 220), SF(1));
        float frac = -1.0f;   // < 0: indeterminate
        bool show = true;
        switch (s.phase) {
            case Phase::Downloading: {
                uint64_t t = realm::app::ProgressTotal(), d = realm::app::ProgressDone();
                frac = t ? std::min(1.0f, (float)d / (float)t) : -1.0f;
                break;
            }
            case Phase::Ready:
            case Phase::GameRunning: frac = 1.0f; break;
            case Phase::ReadyStale:
            case Phase::Failed: show = false; break;
            default: break;
        }
        if (show) {
            RectF inner(L.progress.X + SF(2), L.progress.Y + SF(2), L.progress.Width - SF(4), L.progress.Height - SF(4));
            RectF fill = inner;
            if (frac >= 0.0f) {
                fill.Width = std::max(inner.Height, inner.Width * frac);
            } else {
                float seg = inner.Width * 0.22f;
                float t = std::fmod(g_Anim * 0.45f, 1.0f);
                fill.X = inner.X + (inner.Width + seg) * t - seg;
                fill.Width = seg;
                float x0 = std::max(fill.X, inner.X);
                float x1 = std::min(fill.X + fill.Width, inner.X + inner.Width);
                fill.X = x0;
                fill.Width = std::max(0.0f, x1 - x0);
            }
            if (fill.Width > 0.5f) {
                Gradient fb(PointF(fill.X, 0), PointF(fill.X + std::max(fill.Width, 1.0f), 0), Pal::Gold, Pal::GoldHi);
                FillRound(g, fill, fill.Height / 2, fb.brush);
                if (frac > 0.0f && frac < 1.0f) {
                    // A travelling sheen on the filled part while downloading.
                    float sx = fill.X + std::fmod(g_Anim * SF(160), std::max(fill.Width, 1.0f));
                    Gradient sheen(PointF(sx - SF(30), 0), PointF(sx + SF(30), 0), Color(0, 255, 255, 255),
                                   Color(0, 255, 255, 255));
                    Color sc[] = {Color(0, 255, 255, 255), Color(120, 255, 250, 220), Color(0, 255, 255, 255)};
                    REAL sp[] = {0.0f, 0.5f, 1.0f};
                    sheen.brush.SetInterpolationColors(sc, sp, 3);
                    g.SetClip(fill);
                    g.FillRectangle(&sheen.brush, RectF(sx - SF(30), fill.Y, SF(60), fill.Height));
                    g.ResetClip();
                }
            }
        }
    }

    // --- repair link + launcher version
    {
        bool busy = !(s.phase == Phase::Ready || s.phase == Phase::ReadyStale || s.phase == Phase::Failed);
        Color c = busy ? WithAlpha(Pal::Dim, 110) : (g_Hover == Hit::Repair ? Pal::GoldHi : Pal::Dim);
        DrawStr(g, realm::app::RepairLabel(), tiny, L.repair, c, StringAlignmentNear, StringAlignmentCenter);
        auto link = [&](const wchar_t* text, const RectF& r, Hit which) {
            DrawStr(g, text, tiny, r, g_Hover == which ? Pal::GoldHi : Pal::Dim, StringAlignmentNear,
                    StringAlignmentCenter);
        };
        link(realm::app::SupportLabel(), L.support, Hit::Support);
        link(realm::app::LicensesLabel(), L.licenses, Hit::Licenses);
        link(realm::app::LogsLabel(), L.logs, Hit::Logs);
        std::wstring ver = realm::app::VersionLine(s);
        DrawStr(g, ver, tiny, RectF(L.play.X - SF(400), L.h - SF(34), SF(400) - SF(28), SF(22)),
                 WithAlpha(Pal::Dim, 200), StringAlignmentFar, StringAlignmentCenter);
    }

    // --- play button
    {
        bool enabled = PlayEnabled(s.phase);
        bool hover = enabled && g_Hover == Hit::Play;
        bool pressed = hover && g_Pressed == Hit::Play;
        RectF r = L.play;
        if (pressed) r.Y += SF(1);
        if (enabled) {
            // Outer glow, breathing while the button is the next step.
            float breathe = (s.phase == Phase::Ready) ? (0.55f + 0.45f * std::sin(g_Anim * 2.2f)) : 0.4f;
            for (int i = 4; i >= 1; i--) {
                RectF gr(r.X - SF(i * 2.5f), r.Y - SF(i * 2.5f), r.Width + SF(i * 5.0f), r.Height + SF(i * 5.0f));
                SolidBrush glow(Color((BYTE)((hover ? 26 : 16) * breathe * (5 - i)), 255, 170, 60));
                FillRound(g, gr, SF(10 + i * 2.5f), glow);
            }
        }
        Color top = enabled ? (hover ? Pal::BloodLt : Pal::Blood) : Color(255, 34, 34, 38);
        Color bottom = enabled ? (pressed ? Pal::BloodDk : Color(255, 58, 12, 20)) : Color(255, 24, 24, 28);
        Gradient fill(PointF(0, r.Y), PointF(0, r.Y + r.Height), top, bottom);
        FillRound(g, r, SF(9), fill.brush);
        // Inner bevel highlight: the upper half, fading out by the middle.
        RectF band(r.X + SF(2), r.Y + SF(2), r.Width - SF(4), r.Height * 0.5f - SF(2));
        Gradient bevel(PointF(0, band.Y), PointF(0, band.Y + band.Height), Color(enabled ? 60 : 20, 255, 230, 200),
                       Color(0, 255, 230, 200));
        FillRound(g, band, SF(8), bevel.brush);
        StrokeRound(g, r, SF(9), enabled ? (hover ? Pal::GoldHi : Pal::GoldLt) : Pal::Steel, SF(1.5f));
        StrokeRound(g, RectF(r.X + SF(4), r.Y + SF(4), r.Width - SF(8), r.Height - SF(8)), SF(6),
                    WithAlpha(enabled ? Pal::Gold : Pal::Steel, 110), SF(1));
        std::wstring label = PlayLabel(s.phase);
        TextFont pf = MakeFont(g_TitleFamily, label.size() > 6 ? 19.0f : 28.0f, FontStyleBold);
        const GraphicsPath* lp = TextPath(label, pf, r, StringAlignmentCenter, StringAlignmentCenter, false);
        SolidBrush shadow(Color(160, 20, 4, 4));
        FillOutline(g, lp, shadow, 0, SF(1));
        SolidBrush lb(enabled ? Pal::GoldHi : Pal::Dim);
        FillOutline(g, lp, lb);
    }

    if (g_SheetOpen && panel) PaintSheet(g, L, s);
    else g_SheetOpen = false;

    // --- top bar (over the sheet's shade: the window stays movable and closable)
    DrawStr(g, L"THOUSAND REALMS  \u00B7  LAUNCHER", MakeFont(g_BodyFamily, 13), RectF(SF(22), SF(12), SF(300), SF(22)),
            WithAlpha(Pal::GoldLt, 220));
    for (Hit which : {Hit::Minimize, Hit::Close}) {
        const RectF& r = which == Hit::Close ? L.close : L.minimize;
        if (g_Hover == which) {
            SolidBrush hb(which == Hit::Close ? Color(230, 180, 32, 40) : Color(60, 255, 255, 255));
            g.FillRectangle(&hb, r);
        }
        Pen pen(g_Hover == which ? Pal::Parchment : Pal::Text, SF(1.4f));
        float cx = r.X + r.Width / 2, cy = r.Y + r.Height / 2, k = SF(5.5f);
        if (which == Hit::Close) {
            g.DrawLine(&pen, cx - k, cy - k, cx + k, cy + k);
            g.DrawLine(&pen, cx - k, cy + k, cx + k, cy - k);
        } else {
            g.DrawLine(&pen, cx - k, cy, cx + k, cy);
        }
    }

    // Window edge.
    Pen edge(WithAlpha(Pal::GoldDk, 255), 1.0f);
    g.DrawRectangle(&edge, 0, 0, cw - 1, ch - 1);
}

void Paint(HDC hdc, int cw, int ch) {
    Bitmap frame(cw, ch, PixelFormat32bppPARGB);
    PaintFrame(frame, cw, ch);
    Graphics screen(hdc);
    screen.DrawImage(&frame, 0, 0);
}

void Repaint() {
    if (g_Wnd) InvalidateRect(g_Wnd, NULL, FALSE);
}


// ------------------------------------------------------------------ actions

void OpenSheet() {
    g_SheetOpen = true;
    g_SheetOpenedAt = g_Anim;
    g_SheetScroll = g_SheetScrollTo = 0.0f;
    Repaint();
}

void CloseSheet() {
    g_SheetOpen = false;
    Repaint();
}

void ScrollSheet(float by) {
    g_SheetScrollTo = std::clamp(g_SheetScrollTo + by, 0.0f, g_SheetScrollMax);
    Repaint();
}

Hit HitTest(int x, int y) {
    Layout L = CurrentLayout();
    if (Contains(L.close, x, y)) return Hit::Close;
    if (Contains(L.minimize, x, y)) return Hit::Minimize;
    if (g_SheetOpen) {
        // The sheet takes everything under the top bar; a click beside it closes it.
        if (Contains(g_SheetClose, x, y)) return Hit::SheetClose;
        if (Contains(g_SheetCard, x, y)) return Hit::Sheet;
        return y >= S(kTopBar) ? Hit::Backdrop : Hit::None;
    }
    if (g_NotesCut && Contains(L.notes, x, y)) return Hit::Notes;
    if (Contains(L.play, x, y)) return Hit::Play;
    if (Contains(L.repair, x, y)) return Hit::Repair;
    if (Contains(L.support, x, y)) return Hit::Support;
    if (Contains(L.licenses, x, y)) return Hit::Licenses;
    if (Contains(L.logs, x, y)) return Hit::Logs;
    return Hit::None;
}

void Activate(Hit h) {
    switch (h) {
        case Hit::Close: PostMessageW(g_Wnd, WM_CLOSE, 0, 0); break;
        case Hit::Minimize: ShowWindow(g_Wnd, SW_MINIMIZE); break;
        case Hit::Play:
            if (PlayEnabled(CurrentPhase()) && realm::app::OnPlay()) {
                SetTimer(g_Wnd, kTimerGame, 2500, NULL);
                ShowWindow(g_Wnd, SW_MINIMIZE);
            }
            break;
        case Hit::Repair:
            realm::app::RequestRepair();
            break;
        case Hit::Support: realm::app::OpenSupport(); break;
        case Hit::Licenses: realm::app::OpenLicenses(); break;
        case Hit::Logs: realm::app::OpenLogs(); break;
        case Hit::Notes: OpenSheet(); break;
        case Hit::SheetClose:
        case Hit::Backdrop: CloseSheet(); break;
        default: break;
    }
}

LRESULT CALLBACK WndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
        case WM_CREATE:
            g_Wnd = hWnd;
            SetTimer(hWnd, kTimerAnim, 33, NULL);
            SetTimer(hWnd, kTimerStatus, kStatusPollMs, NULL);
            SetTimer(hWnd, kTimerRecheck, kRecheckMs, NULL);
            StartWorker();
            StartStatusPoll();
            return 0;
        case WM_TIMER:
            if (wParam == kTimerAnim) {
                g_Anim += 0.033f;
                if (std::fabs(g_SheetScrollTo - g_SheetScroll) < 0.5f) g_SheetScroll = g_SheetScrollTo;
                else g_SheetScroll += (g_SheetScrollTo - g_SheetScroll) * 0.35f;
                if (!IsIconic(hWnd)) Repaint();
            } else if (wParam == kTimerStatus) {
                StartStatusPoll();
            } else if (wParam == kTimerGame) {
                if (!realm::app::PollGame()) KillTimer(hWnd, kTimerGame);
            } else if (wParam == kTimerRecheck) {
                realm::app::OnRecheckTimer();
            }
            return 0;
        case WM_APP_REFRESH:
            Repaint();
            return 0;
        case WM_APP_EXIT:
            DestroyWindow(hWnd);
            return 0;
        case WM_APP_RESTORE:
            ShowWindow(hWnd, SW_RESTORE);
            SetForegroundWindow(hWnd);
            return 0;
        case WM_NCHITTEST: {
            LRESULT r = DefWindowProcW(hWnd, msg, wParam, lParam);
            if (r != HTCLIENT) return r;
            POINT pt = {GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
            ScreenToClient(hWnd, &pt);
            if (pt.y < S(kTopBar) && HitTest(pt.x, pt.y) == Hit::None) return HTCAPTION;
            return HTCLIENT;
        }
        case WM_MOUSEMOVE: {
            if (!g_Tracking) {
                TRACKMOUSEEVENT tme = {sizeof(tme), TME_LEAVE, hWnd, 0};
                TrackMouseEvent(&tme);
                g_Tracking = true;
            }
            Hit h = HitTest(GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
            if (h != g_Hover) {
                g_Hover = h;
                Repaint();
            }
            return 0;
        }
        case WM_MOUSELEAVE:
            g_Tracking = false;
            g_Hover = Hit::None;
            g_Pressed = Hit::None;
            Repaint();
            return 0;
        case WM_SETCURSOR: {
            if (LOWORD(lParam) == HTCLIENT) {
                bool hand = g_Hover == Hit::Play ? PlayEnabled(CurrentPhase())
                                                 : g_Hover != Hit::None && g_Hover != Hit::Sheet && g_Hover != Hit::Backdrop;
                SetCursor(LoadCursor(NULL, hand ? IDC_HAND : IDC_ARROW));
                return TRUE;
            }
            break;
        }
        case WM_LBUTTONDOWN:
            g_Pressed = HitTest(GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
            SetCapture(hWnd);
            Repaint();
            return 0;
        case WM_LBUTTONUP: {
            ReleaseCapture();
            Hit h = HitTest(GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
            Hit pressed = g_Pressed;
            g_Pressed = Hit::None;
            Repaint();
            if (h == pressed) Activate(h);
            return 0;
        }
        case WM_KEYDOWN:
            if (g_SheetOpen) {
                float line = SF(23) * 2;
                switch (wParam) {
                    case VK_ESCAPE:
                    case VK_RETURN: CloseSheet(); break;
                    case VK_UP: ScrollSheet(-line); break;
                    case VK_DOWN: ScrollSheet(line); break;
                    case VK_PRIOR: ScrollSheet(-g_SheetPage * 0.9f); break;
                    case VK_NEXT:
                    case VK_SPACE: ScrollSheet(g_SheetPage * 0.9f); break;
                    case VK_HOME: ScrollSheet(-1e9f); break;
                    case VK_END: ScrollSheet(1e9f); break;
                    default: break;
                }
                return 0;
            }
            if (wParam == VK_RETURN || wParam == VK_SPACE) Activate(Hit::Play);
            if (wParam == VK_ESCAPE) ShowWindow(hWnd, SW_MINIMIZE);
            return 0;
        case WM_MOUSEWHEEL:
            if (g_SheetOpen) ScrollSheet(-(float)GET_WHEEL_DELTA_WPARAM(wParam) / WHEEL_DELTA * SF(23) * 3);
            return 0;
        case WM_ERASEBKGND:
            return 1;
        case WM_PAINT: {
            PAINTSTRUCT ps;
            HDC hdc = BeginPaint(hWnd, &ps);
            RECT rc;
            GetClientRect(hWnd, &rc);
            if (rc.right > 0 && rc.bottom > 0) Paint(hdc, rc.right, rc.bottom);
            EndPaint(hWnd, &ps);
            return 0;
        }
        case WM_CLOSE: {
            Phase p = CurrentPhase();
            if (p == Phase::Downloading || p == Phase::Installing) {
                int answer = MessageBoxW(hWnd, realm::app::CloseDuringUpdateText(), L"Thousand Realms",
                                         MB_YESNO | MB_ICONQUESTION);
                if (answer != IDYES) return 0;
                realm::app::Cancel();
            }
            DestroyWindow(hWnd);
            return 0;
        }
        case WM_DESTROY:
            KillTimer(hWnd, kTimerAnim);
            KillTimer(hWnd, kTimerStatus);
            KillTimer(hWnd, kTimerGame);
            KillTimer(hWnd, kTimerRecheck);
            PostQuitMessage(0);
            return 0;
    }
    return DefWindowProcW(hWnd, msg, wParam, lParam);
}

// Headless CLI modes: the GUI executable also answers --check/--update/...,
// --print-cert-pin and the self-update helper so a single distributed binary
// can act as its own updater bootstrap.
int RunHeadlessFromGuiArgs() {
    int argcW = 0;
    LPWSTR* argvW = CommandLineToArgvW(GetCommandLineW(), &argcW);
    if (!argvW || argcW < 2) {
        if (argvW) LocalFree(argvW);
        return -1;  // no updater arguments: continue to the GUI
    }
    std::vector<std::string> narrow;
    narrow.reserve(argcW);
    for (int i = 0; i < argcW; i++) narrow.push_back(realm::WideToUtf8(argvW[i]));
    std::vector<char*> argv;
    argv.reserve(argcW);
    for (auto& s : narrow) argv.push_back(&s[0]);
    LocalFree(argvW);

    realm::CliOptions opts;
    std::string err;
    if (!realm::ParseCliArgs(argcW, argv.data(), opts, err)) return -1;

    // A GUI-subsystem process only has console handles when the parent
    // redirected them; otherwise reattach to the parent console so operator
    // output is visible. Redirected pipes are left untouched.
    HANDLE stdoutHandle = GetStdHandle(STD_OUTPUT_HANDLE);
    bool haveStdout = stdoutHandle != NULL && stdoutHandle != INVALID_HANDLE_VALUE;
    if (!haveStdout && AttachConsole(ATTACH_PARENT_PROCESS)) {
        freopen("CONOUT$", "w", stdout);
        freopen("CONOUT$", "w", stderr);
    }

    if (opts.command == "help") {
        realm::PrintUsage(stdout);
        fflush(stdout);
        return 0;
    }
    if (opts.helper.empty() && opts.command.empty()) return -1;
    int code = 0;
    if (opts.helper == "self-update-swap") {
        code = realm::RunSelfUpdateSwap(realm::WideToUtf8(opts.helperPid), opts.helperTarget, realm::GetExePath(),
                                        opts.relaunch);
    } else if (opts.helper == "print-cert-pin") {
        code = realm::RunPrintCertPin(opts.helperUrl);
    } else {
        realm::CommandResult r = realm::RunCliCommand(opts);
        printf("%s\n", r.json.c_str());
        fflush(stdout);
        code = r.code;
    }
    return code;
}

// Takes every instance mutex, or none when another launcher holds one of them.
bool TakeInstanceMutexes(std::vector<HANDLE>& held) {
    for (const wchar_t* name : kInstanceMutexes) {
        HANDLE h = CreateMutexW(NULL, TRUE, name);
        bool taken = GetLastError() != ERROR_ALREADY_EXISTS;
        if (h && !taken) CloseHandle(h);
        if (!taken) {
            for (HANDLE other : held) {
                ReleaseMutex(other);
                CloseHandle(other);
            }
            held.clear();
            return false;
        }
        if (h) held.push_back(h);
    }
    return true;
}

// The value after a command-line flag, or "".
std::wstring ArgValue(const wchar_t* flag) {
    int argcW = 0;
    LPWSTR* argvW = CommandLineToArgvW(GetCommandLineW(), &argcW);
    std::wstring value;
    if (argvW) {
        for (int i = 1; i + 1 < argcW; i++)
            if (_wcsicmp(argvW[i], flag) == 0) value = argvW[i + 1];
        LocalFree(argvW);
    }
    return value;
}

void OpenWithShell(const std::wstring& target) {
    ShellExecuteW(NULL, L"open", target.c_str(), NULL, NULL, SW_SHOWNORMAL);
}

// --screenshot <file.png>: paints one frame (a --screenshot-state, or the live
// state after --screenshot-after ms) without opening a window.
int RunScreenshot(const std::wstring& out) {
    std::wstring state = ArgValue(L"--screenshot-state");
    if (!state.empty()) {
        if (!realm::app::ShowTestState(realm::WideToUtf8(state))) return 2;
    } else {
        realm::app::StartWorker();
        realm::app::StartStatusPoll();
        std::wstring after = ArgValue(L"--screenshot-after");
        Sleep(after.empty() ? 4000 : (DWORD)_wtoi(after.c_str()));
    }
    // --screenshot-scale 1.25: the frame a 120 DPI screen gets.
    std::wstring scale = ArgValue(L"--screenshot-scale");
    g_Scale = scale.empty() ? 1.0f : std::clamp((float)_wtof(scale.c_str()), 1.0f, 4.0f);
    g_Anim = 1.0f;
    int w = S(kBaseW), h = S(kBaseH);
    Bitmap frame(w, h, PixelFormat32bppPARGB);
    // --screenshot-hover notes: the notes panel under the pointer.
    if (ArgValue(L"--screenshot-hover") == L"notes") g_Hover = Hit::Notes;
    PaintFrame(frame, w, h);
    // --screenshot-sheet <top|end|px>: the notes sheet open, scrolled.
    std::wstring sheet = ArgValue(L"--screenshot-sheet");
    if (!sheet.empty()) {
        g_SheetOpen = true;
        g_SheetOpenedAt = g_Anim - 1.0f;
        g_Hover = Hit::None;
        PaintFrame(frame, w, h);   // lays the sheet out: its scroll range
        g_SheetScroll = sheet == L"end" ? g_SheetScrollMax : sheet == L"top" ? 0.0f : (float)_wtof(sheet.c_str());
        g_SheetScrollTo = g_SheetScroll;
        PaintFrame(frame, w, h);
    }
    static const CLSID kPng = {0x557cf406, 0x1a04, 0x11d3, {0x9a, 0x73, 0x00, 0x00, 0xf8, 0x1e, 0xf3, 0x2e}};
    bool ok = frame.Save(out.c_str(), &kPng, NULL) == Ok;
    fflush(nullptr);
    ExitProcess(ok ? 0 : 1);  // detached workers may still be in network calls
}

bool HasArg(const wchar_t* flag) {
    int argcW = 0;
    LPWSTR* argvW = CommandLineToArgvW(GetCommandLineW(), &argcW);
    bool found = false;
    if (argvW) {
        for (int i = 1; i < argcW; i++)
            if (_wcsicmp(argvW[i], flag) == 0) found = true;
        LocalFree(argvW);
    }
    return found;
}

}  // namespace

int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE, LPSTR, int nCmdShow) {
    {
        int headless = RunHeadlessFromGuiArgs();
        if (headless >= 0) return headless;
    }
    realm::i18n::Init();
    {
        std::wstring lang = ArgValue(L"--lang");
        if (!lang.empty())
            realm::i18n::Set(realm::i18n::IsTurkishTag(realm::WideToUtf8(lang)) ? realm::i18n::Lang::Turkish
                                                                                : realm::i18n::Lang::English);
    }
    std::wstring screenshot = ArgValue(L"--screenshot");
    if (HasArg(L"--post-self-update")) {
        realm::SetLogPath(realm::EarlyLogPath());
        realm::LogMsg("[Launcher] restarted after self-update");
        wchar_t flag[8] = {0};
        if (GetEnvironmentVariableW(L"REALM_TEST_NO_GUI", flag, 8) > 0) return 0;
    }

    // One launcher at a time: a second start brings the first to the front.
    // (A relaunch after self-update waits briefly for the old process to exit.)
    std::vector<HANDLE> single;
    for (int attempt = 0; screenshot.empty() && attempt < 20; attempt++) {
        if (TakeInstanceMutexes(single)) break;
        if (!HasArg(L"--post-self-update")) {
            HWND other = FindWindowW(kWindowClass, NULL);
            if (!other) other = FindWindowW(kLegacyWindowClass, NULL);
            if (other) {
                ShowWindow(other, SW_RESTORE);
                SetForegroundWindow(other);
            }
            return 0;
        }
        Sleep(250);
    }

    // Before LoadConfig: an exe still called by the old name takes the game's
    // name (and the player's shortcuts follow it).
    if (screenshot.empty()) {
        realm::SetLogPath(realm::EarlyLogPath());
        realm::MigrateLegacyLauncherFile();
    }

    SetProcessDPIAware();
    {
        HDC screen = GetDC(NULL);
        g_Scale = GetDeviceCaps(screen, LOGPIXELSX) / 96.0f;
        ReleaseDC(NULL, screen);
        if (g_Scale < 1.0f) g_Scale = 1.0f;
    }

    WSADATA wsaData;
    WSAStartup(MAKEWORD(2, 2), &wsaData);
    GdiplusStartupInput gdiplusStartupInput;
    GdiplusStartup(&g_GdiToken, &gdiplusStartupInput, NULL);
    LoadAssets();

    realm::LoadConfig();
    realm::app::Hooks hooks;
    hooks.refresh = [] {
        if (g_Wnd) PostMessageW(g_Wnd, WM_APP_REFRESH, 0, 0);
    };
    hooks.exitForSelfUpdate = [] { PostMessageW(g_Wnd, WM_APP_EXIT, 0, 0); };
    hooks.restoreWindow = [] {
        if (g_Wnd) PostMessageW(g_Wnd, WM_APP_RESTORE, 0, 0);
    };
    hooks.openUrl = OpenWithShell;
    hooks.openPath = OpenWithShell;
    realm::app::Init(realm::Config(), hooks);
    {
        const void* notices = nullptr;
        DWORD noticesSize = 0;
        if (LoadResourceBytes(IDR_NOTICES, &notices, &noticesSize)) realm::app::SetNotices(notices, noticesSize);
    }
    if (!screenshot.empty()) return RunScreenshot(screenshot);

    WNDCLASSEXW wcex = {sizeof(wcex)};
    wcex.style = CS_HREDRAW | CS_VREDRAW | CS_DROPSHADOW;
    wcex.lpfnWndProc = WndProc;
    wcex.hInstance = hInstance;
    wcex.hCursor = LoadCursor(NULL, IDC_ARROW);
    wcex.hbrBackground = NULL;
    wcex.lpszClassName = kWindowClass;
    wcex.hIcon = LoadIconW(hInstance, MAKEINTRESOURCEW(IDI_MAIN));
    if (!wcex.hIcon) wcex.hIcon = LoadIcon(NULL, IDI_APPLICATION);
    wcex.hIconSm = wcex.hIcon;
    RegisterClassExW(&wcex);

    int winW = S(kBaseW), winH = S(kBaseH);
    RECT work;
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    int posX = work.left + ((work.right - work.left) - winW) / 2;
    int posY = work.top + ((work.bottom - work.top) - winH) / 2;

    HWND hWnd = CreateWindowExW(WS_EX_APPWINDOW, kWindowClass, L"Thousand Realms",
                                WS_POPUP | WS_SYSMENU | WS_MINIMIZEBOX | WS_CLIPCHILDREN, posX, posY, winW, winH,
                                NULL, NULL, hInstance, NULL);
    if (!hWnd) return 1;
    // Windows 11: rounded corners on the borderless window (ignored elsewhere).
    DWORD corner = 2;  // DWMWCP_ROUND
    DwmSetWindowAttribute(hWnd, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, &corner, sizeof(corner));

    ShowWindow(hWnd, nCmdShow);
    UpdateWindow(hWnd);

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    realm::app::Cancel();
    FreeTextCaches();
    FreeAssets();
    GdiplusShutdown(g_GdiToken);
    WSACleanup();
    for (HANDLE h : single) {
        ReleaseMutex(h);
        CloseHandle(h);
    }
    return (int)msg.wParam;
}
