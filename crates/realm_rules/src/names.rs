//! Character names: the old game's rule (services/cpp app.cpp
//! character_name_problem), so the login service and anything else that
//! names a character agree. 2-20 characters of letters (any script) and
//! digits, at least one letter; spaces, hyphens and apostrophes only
//! between letters; no punctuation, symbols, private-use, invisible or
//! default-ignorable code points; the combining marks of U+0300-036F are
//! refused (a decomposed name would spell an existing one past the unique
//! check) and other combining marks never count as the visible letter.
//! Uniqueness is case-insensitive (`name_key`).

fn separator(c: char) -> bool {
    matches!(c, ' ' | '-' | '\'')
}

fn combining(cp: u32) -> bool {
    matches!(cp,
        0x0300..=0x036F | 0x0483..=0x0489 | 0x0591..=0x05C7 | 0x0610..=0x061A |
        0x064B..=0x065F | 0x0670 | 0x06D6..=0x06ED | 0x1AB0..=0x1AFF |
        0x1DC0..=0x1DFF | 0xFE20..=0xFE2F)
}

fn letter_or_digit(cp: u32) -> bool {
    if matches!(cp, 0x30..=0x39 | 0x41..=0x5A | 0x61..=0x7A) {
        return true;
    }
    if cp < 0xC0 || cp == 0xD7 || cp == 0xF7 {
        return false;
    }
    !matches!(cp,
        0x2000..=0x2BFF | 0x3000..=0x303F | 0xD800..=0xF8FF | 0xFE00..=0xFE0F |
        0xFE30..=0xFE6F | 0xFF00..=0xFF0F | 0xFEFF | 0xFFF0..=0x10FFFF |
        0x0300..=0x036F | 0x115F | 0x1160 | 0x3164 | 0xFFA0 | 0x061C | 0x1680 |
        0x17B4 | 0x17B5 | 0x180B..=0x180F)
}

/// What is wrong with `name` as a character's name (None: nothing).
#[must_use]
pub fn name_problem(name: &str) -> Option<&'static str> {
    let chars: Vec<char> = name.chars().collect();
    if chars.len() < 2 || chars.len() > 20 {
        return Some("Name must be 2-20 characters.");
    }
    let mut visible = false;
    for (i, &c) in chars.iter().enumerate() {
        let cp = c as u32;
        if separator(c) {
            if i == 0 || i + 1 == chars.len() || separator(chars[i - 1]) {
                return Some("Spaces, hyphens and apostrophes may only stand between letters.");
            }
        } else if !letter_or_digit(cp) {
            return Some("Names may only use letters, digits, spaces, hyphens and apostrophes.");
        } else if !combining(cp) && !c.is_ascii_digit() {
            visible = true;
        }
    }
    if !visible {
        return Some("Names need at least one letter.");
    }
    None
}

/// The key two names clash on (case ignored).
#[must_use]
pub fn name_key(name: &str) -> String {
    name.trim().to_lowercase()
}
