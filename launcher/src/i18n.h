// The launcher's two languages. Text lives where it is used, as a Turkish /
// English pair: Tx(L"Oyna", L"Play"). The language comes from the operating
// system (Turkish on a Turkish system, English everywhere else) and can be
// forced with --lang <tr|en> or THOUSANDREALMS_LANG.
#pragma once

#include <string>

namespace realm {
namespace i18n {

enum class Lang { Turkish, English };

Lang Current();
// "tr" for Turkish, "en" for English: what the game is told on its first start.
const char* CurrentCode();
void Set(Lang lang);

// True for "tr", "tr-TR", "tr_TR.UTF-8", "TR"; false for anything else.
bool IsTurkishTag(const std::string& tag);

// Picks the language: THOUSANDREALMS_LANG when set, else osTag, else what the
// platform reports (SystemLocaleTag in common.h).
void Init(const std::string& osTag = "");

inline const wchar_t* Tx(const wchar_t* turkish, const wchar_t* english) {
    return Current() == Lang::Turkish ? turkish : english;
}

}  // namespace i18n
}  // namespace realm
