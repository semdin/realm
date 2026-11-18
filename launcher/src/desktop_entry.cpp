// Linux desktop integration. The launcher is one file the player can keep
// anywhere: on its first start it adds itself to the application menu, and on
// later starts it keeps that entry pointing at the file. An entry the player
// removed stays removed. Under the itch app nothing is added (itch makes its
// own shortcuts).
//
// The published ThousandRealms_Launcher-x86_64.AppImage is this same program
// with the AppImage marker and a small image of its desktop files appended, so
// it starts directly and never needs FUSE. The --appimage-* options below are
// what desktop tools ask an AppImage for.
#include "common.h"

#if defined(__linux__)

#include <sys/stat.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <string>

namespace realm {

namespace {

const wchar_t kEntryName[] = L"thousand-realms.desktop";
const wchar_t kIconName[] = L"thousand-realms.png";

std::wstring EntryPath(const std::wstring& data) { return JoinPath(JoinPath(data, L"applications"), kEntryName); }
std::wstring MarkerPath(const std::wstring& data) { return JoinPath(data, L".thousandrealms-menu-entry"); }
std::wstring IconPath(const std::wstring& data) {
    return JoinPath(JoinPath(data, L"icons/hicolor/256x256/apps"), kIconName);
}

// Quoted as the Desktop Entry spec wants an Exec argument; a backslash is
// doubled once more because the value is itself an escaped string.
std::string ExecQuoted(const std::string& path) {
    std::string out = "\"";
    for (char c : path) {
        if (c == '"' || c == '`' || c == '$') out += "\\\\";
        if (c == '\\') out += "\\\\\\";
        if (c == '%') out += '%';
        out += c;
    }
    return out + "\"";
}

std::string EntryText(const std::string& exec) {
    return "[Desktop Entry]\n"
           "Type=Application\n"
           "Name=Thousand Realms\n"
           "Comment=Online fantasy role-playing game\n"
           "Comment[tr]=Çevrim içi fantastik rol yapma oyunu\n"
           "Exec=" + exec + "\n"
           "Icon=thousand-realms\n"
           "Categories=Game;RolePlaying;\n"
           "Terminal=false\n"
           "StartupWMClass=thousand-realms\n";
}

// Where the appended image starts: the end of the ELF file proper.
uint64_t ElfEnd(const std::wstring& exe) {
    std::string head;
    FILE* f = OpenFileW(exe, L"rb");
    if (!f) return 0;
    unsigned char h[64] = {0};
    size_t got = fread(h, 1, sizeof(h), f);
    fclose(f);
    if (got != sizeof(h) || memcmp(h, "\177ELF", 4) != 0 || h[4] != 2) return 0;
    uint64_t shoff = 0;
    memcpy(&shoff, h + 0x28, 8);
    uint16_t entsize = 0, count = 0;
    memcpy(&entsize, h + 0x3A, 2);
    memcpy(&count, h + 0x3C, 2);
    return shoff + (uint64_t)entsize * count;
}

int ExtractAppDir(const void* icon, size_t iconSize) {
    std::wstring root = JoinPath(GetCwd(), L"squashfs-root");
    std::wstring bin = JoinPath(root, L"usr/bin");
    if (!CreateDirs(bin)) return 1;
    std::wstring exe = GetExePath();
    std::wstring inner = JoinPath(bin, L"ThousandRealms_Launcher");
    if (!CopyFilePlain(exe, inner) || !MakeExecutable(inner)) return 1;
    std::string text = EntryText("ThousandRealms_Launcher");
    if (!WriteFileBytes(JoinPath(root, kEntryName), text.data(), text.size())) return 1;
    if (!WriteFileBytes(JoinPath(root, kIconName), icon, iconSize)) return 1;
    std::string link = WideToUtf8(JoinPath(root, L"AppRun"));
    unlink(link.c_str());
    if (symlink("usr/bin/ThousandRealms_Launcher", link.c_str()) != 0) return 1;
    printf("squashfs-root\n");
    return 0;
}

}  // namespace

void EnsureDesktopEntry(const void* icon, size_t iconSize) {
    if (GetEnvW(L"ITCHIO_APP") == L"1") return;
    std::wstring data = UserDataRoot();
    std::wstring exe = GetExePath();
    if (data.empty() || exe.empty()) return;
    std::wstring entry = EntryPath(data);
    bool exists = FileExists(entry);
    if (!exists && FileExists(MarkerPath(data))) return;  // the player removed it
    std::string want = EntryText(ExecQuoted(WideToUtf8(exe)));
    std::string have;
    if (exists && ReadFileBytes(entry, have, 1u << 16) && have == want) return;
    if (!CreateDirs(JoinPath(data, L"applications")) || !WriteFileAtomic(entry, want)) {
        LogMsg("[Launcher] could not write the menu entry " + WideToUtf8(entry));
        return;
    }
    if (CreateDirs(JoinPath(data, L"icons/hicolor/256x256/apps"))) WriteFileBytes(IconPath(data), icon, iconSize);
    WriteFileBytes(MarkerPath(data), "1", 1);
    LogMsg("[Launcher] menu entry written: " + WideToUtf8(entry));
}

int RemoveDesktopEntry() {
    std::wstring data = UserDataRoot();
    if (data.empty()) return 1;
    DeleteFileQuiet(EntryPath(data));
    DeleteFileQuiet(IconPath(data));
    WriteFileBytes(MarkerPath(data), "1", 1);
    return 0;
}

int HandleAppImageOption(const char* option, const void* icon, size_t iconSize) {
    if (strcmp(option, "--appimage-offset") == 0) {
        printf("%llu\n", (unsigned long long)ElfEnd(GetExePath()));
        return 0;
    }
    if (strcmp(option, "--appimage-extract") == 0) return ExtractAppDir(icon, iconSize);
    return -1;
}

}  // namespace realm

#endif  // __linux__
