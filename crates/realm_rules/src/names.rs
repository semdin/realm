//! Character names, so the login service and anything else that names a
//! character agree. 2-20 characters of Latin letters (Turkish ones included)
//! and digits, at least one letter; spaces, hyphens and apostrophes only
//! between letters. Other scripts are refused: their look-alikes would spell
//! someone else's name. Uniqueness is case-insensitive (`name_key`), and no
//! two players' names may look alike (`name_skeleton`).

fn separator(c: char) -> bool {
    matches!(c, ' ' | '-' | '\'')
}

fn letter_or_digit(c: char) -> bool {
    let cp = c as u32;
    c.is_ascii_alphanumeric()
        || (matches!(cp, 0xC0..=0x17F) && cp != 0xD7 && cp != 0xF7 && c.is_alphabetic())
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
        if separator(c) {
            if i == 0 || i + 1 == chars.len() || separator(chars[i - 1]) {
                return Some("Spaces, hyphens and apostrophes may only stand between letters.");
            }
        } else if !letter_or_digit(c) {
            return Some("Names may only use letters, digits, spaces, hyphens and apostrophes.");
        } else if !c.is_ascii_digit() {
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

/// What a name looks like: case, accents and Turkish letters folded, letters
/// and digits that pass for each other made one, separators gone. `Ali`,
/// `ALİ`, `Alı` and `A1i` share a skeleton; two players' names may not.
#[must_use]
pub fn name_skeleton(name: &str) -> String {
    name.trim()
        .chars()
        .filter(|c| !separator(*c))
        .flat_map(char::to_lowercase)
        .filter_map(|c| {
            Some(match c {
                // `İ` lowercases to `i` and a combining dot.
                '\u{307}' => return None,
                'l' | '1' | 'ı' | 'î' | 'ï' | 'í' | 'ì' | 'ī' | 'į' | 'ĩ' | 'ĭ' | 'ł' | 'ĺ'
                | 'ļ' | 'ľ' | 'ŀ' => 'i',
                '0' | 'ö' | 'ô' | 'ò' | 'ó' | 'õ' | 'ø' | 'ō' | 'ŏ' | 'ő' => 'o',
                '5' | 'ş' | 'ś' | 'š' | 'ŝ' | 'ß' => 's',
                '9' | 'ğ' | 'ĝ' | 'ġ' | 'ģ' => 'g',
                'ç' | 'ć' | 'č' | 'ĉ' | 'ċ' => 'c',
                'ü' | 'û' | 'ù' | 'ú' | 'ū' | 'ŭ' | 'ů' | 'ű' | 'ũ' | 'ų' => 'u',
                '4' | 'â' | 'à' | 'á' | 'ä' | 'ã' | 'å' | 'ā' | 'ă' | 'ą' => 'a',
                '3' | 'ê' | 'è' | 'é' | 'ë' | 'ē' | 'ĕ' | 'ė' | 'ę' | 'ě' => 'e',
                'ñ' | 'ń' | 'ņ' | 'ň' => 'n',
                'ý' | 'ÿ' | 'ŷ' => 'y',
                'ž' | 'ź' | 'ż' => 'z',
                'ð' | 'đ' | 'ď' => 'd',
                'ř' | 'ŕ' | 'ŗ' => 'r',
                'ť' | 'ţ' | 'ŧ' => 't',
                'ķ' => 'k',
                'ĥ' | 'ħ' => 'h',
                'ĵ' => 'j',
                'ŵ' => 'w',
                other => other,
            })
        })
        .collect()
}
