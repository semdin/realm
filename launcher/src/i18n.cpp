#include "i18n.h"

#include <atomic>
#include <cctype>

#include "common.h"

namespace realm {
namespace i18n {

namespace {
std::atomic<Lang> g_Lang{Lang::English};
}

Lang Current() { return g_Lang.load(); }

const char* CurrentCode() { return Current() == Lang::Turkish ? "tr" : "en"; }

void Set(Lang lang) { g_Lang = lang; }

bool IsTurkishTag(const std::string& tag) {
    if (tag.size() < 2) return false;
    if (tolower((unsigned char)tag[0]) != 't' || tolower((unsigned char)tag[1]) != 'r') return false;
    return tag.size() == 2 || tag[2] == '-' || tag[2] == '_' || tag[2] == '.' || tag[2] == '@';
}

void Init(const std::string& osTag) {
    std::string forced = WideToUtf8(GetEnvW(L"THOUSANDREALMS_LANG"));
    std::string tag = !forced.empty() ? forced : !osTag.empty() ? osTag : SystemLocaleTag();
    Set(IsTurkishTag(tag) ? Lang::Turkish : Lang::English);
}

}  // namespace i18n
}  // namespace realm
