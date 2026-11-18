//! What players may call themselves and say in public. Server side only:
//! the login service, the map servers and the coordinator use it, the client
//! never links it, so the word list does not ship to players.
//!
//! Text is compared word by word after normalising: case, Turkish letters and
//! accents, look-alike letters from other scripts, digits and symbols standing
//! in for letters inside a word (`s1kt1r`, `f@ck`), repeated letters
//! (`fuuuck`), and letters spaced out one by one (`f u c k`, `s.i.k`). Whole
//! words and listed stems only, so `aşık`, `sıkıcı`, `grape` and `Scunthorpe`
//! pass. A chat line keeps its other words: only the offending ones become
//! asterisks. Names are refused outright, and are also read as one run of
//! letters (`G A`, `Ad Min`).
//!
//! The list is `words.txt`, plus REALM_FILTER_EXTRA (a file of the same form
//! on the host) when that is set.

use std::sync::OnceLock;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Exact,
    Prefix,
    Suffix,
    Anywhere,
}

struct Entry {
    kind: Kind,
    /// Written with Turkish letters: compared with the word as typed.
    literal: bool,
    /// The folded form, and with repeated letters collapsed.
    word: String,
    squashed: String,
}

/// One word of a text, in the forms the entries are compared with.
struct Token {
    start: usize,
    end: usize,
    /// Lowercase as typed (Turkish rules for I and İ).
    typed: String,
    /// Folded: case, accents, look-alikes, digits and symbols as letters.
    folded: String,
    /// `folded` with runs of one letter collapsed.
    squashed: String,
    /// Folded without reading digits as letters, the digits dropped.
    letters: String,
}

pub struct Filter {
    profanity: Vec<Entry>,
    reserved: Vec<Entry>,
}

/// A letter's plain Latin form: Turkish letters, accents, and the letters of
/// other scripts that look like Latin ones. Lowercase in, lowercase out.
fn plain(c: char) -> char {
    match c {
        'ı' | 'î' | 'ï' | 'í' | 'ì' | 'ī' | 'į' | 'і' | 'ї' | 'ι' => 'i',
        'ş' | 'ś' | 'š' | 'ß' | 'ѕ' => 's',
        'ğ' | 'ĝ' | 'ġ' | 'ɡ' => 'g',
        'ç' | 'ć' | 'č' | 'ĉ' | 'ċ' | 'с' => 'c',
        'ö' | 'ô' | 'ò' | 'ó' | 'õ' | 'ø' | 'ō' | 'ő' | 'о' | 'ο' => 'o',
        'ü' | 'û' | 'ù' | 'ú' | 'ū' | 'ů' | 'ű' | 'υ' => 'u',
        'â' | 'à' | 'á' | 'ä' | 'ã' | 'å' | 'ā' | 'ă' | 'ą' | 'а' | 'α' => 'a',
        'ê' | 'è' | 'é' | 'ë' | 'ē' | 'ė' | 'ę' | 'ě' | 'е' | 'ё' | 'ε' => 'e',
        'ñ' | 'ń' | 'ň' | 'η' => 'n',
        'ý' | 'ÿ' | 'у' => 'y',
        'ž' | 'ź' | 'ż' | 'ζ' => 'z',
        'ł' | 'ĺ' | 'ľ' => 'l',
        'đ' | 'ð' | 'ď' | 'ԁ' => 'd',
        'ř' | 'ŕ' | 'г' => 'r',
        'ť' | 'т' | 'τ' => 't',
        'в' | 'β' => 'b',
        'к' | 'κ' => 'k',
        'м' => 'm',
        'н' | 'һ' => 'h',
        'р' | 'ρ' => 'p',
        'х' | 'χ' => 'x',
        'ј' => 'j',
        'ν' => 'v',
        'ω' => 'w',
        // Fullwidth forms.
        'ａ'..='ｚ' => char::from_u32(c as u32 - 0xFF41 + 0x61).unwrap_or(c),
        '０'..='９' => char::from_u32(c as u32 - 0xFF10 + 0x30).unwrap_or(c),
        _ => c,
    }
}

/// What a digit or symbol stands for inside a word.
fn stand_in(c: char) -> Option<char> {
    Some(match c {
        '0' => 'o',
        '1' | '!' | '|' => 'i',
        '2' => 'z',
        '3' | '€' => 'e',
        '4' | '@' => 'a',
        '5' | '$' => 's',
        '6' | '9' => 'g',
        '7' | '+' => 't',
        '8' => 'b',
        '£' => 'l',
        _ => return None,
    })
}

fn lower(c: char, out: &mut String) {
    match c {
        'I' => out.push('ı'),
        'İ' => out.push('i'),
        // Fullwidth capitals become their lowercase forms.
        'Ａ'..='Ｚ' => out.extend(char::from_u32(c as u32 - 0xFF21 + 0xFF41)),
        _ => out.extend(c.to_lowercase()),
    }
}

fn invisible(c: char) -> bool {
    matches!(c, '\u{00AD}' | '\u{034F}' | '\u{200B}'..='\u{200F}' | '\u{2060}'..='\u{2064}' | '\u{FEFF}')
        || matches!(c, '\u{0300}'..='\u{036F}')
}

fn squash(word: &str) -> String {
    let mut out = String::with_capacity(word.len());
    let mut last = None;
    for c in word.chars() {
        if last != Some(c) {
            out.push(c);
        }
        last = Some(c);
    }
    out
}

fn token(start: usize, end: usize, raw: &str) -> Token {
    let mut typed = String::new();
    for c in raw.chars().filter(|c| !invisible(*c)) {
        lower(c, &mut typed);
    }
    let any_letter = typed.chars().any(char::is_alphabetic);
    let mut folded = String::with_capacity(typed.len());
    let mut letters = String::with_capacity(typed.len());
    for c in typed.chars().map(plain) {
        if !c.is_ascii_digit() && c.is_alphanumeric() {
            letters.push(c);
        }
        // A number alone stays a number.
        match stand_in(c).filter(|_| any_letter) {
            Some(letter) => folded.push(letter),
            None => folded.push(c),
        }
    }
    let squashed = squash(&folded);
    Token {
        start,
        end,
        typed,
        folded,
        squashed,
        letters,
    }
}

/// The words of `text`. A digit or symbol counts as part of a word when it
/// stands inside one (`f@ck`, `s1k`; `@ss` and `$hit` start with one); plain
/// punctuation around a word does not.
fn words(text: &str) -> Vec<Token> {
    let chars: Vec<(usize, char)> = text.char_indices().collect();
    let wordy = |c: char| c.is_alphanumeric() || invisible(c);
    let mut out = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let begins = wordy(chars[i].1)
            || (matches!(chars[i].1, '@' | '$')
                && chars.get(i + 1).is_some_and(|(_, c)| c.is_alphabetic()));
        if !begins {
            i += 1;
            continue;
        }
        let first = i;
        i += 1;
        while let Some((_, c)) = chars.get(i) {
            let inside = stand_in(*c).is_some()
                && chars.get(i + 1).is_some_and(|(_, n)| n.is_alphanumeric());
            if wordy(*c) || inside {
                i += 1;
            } else {
                break;
            }
        }
        let start = chars[first].0;
        let end = chars.get(i).map_or(text.len(), |(at, _)| *at);
        out.push(token(start, end, &text[start..end]));
    }
    out
}

/// Runs of three or more single letters (`f u c k`, `s.i.k`), read as one
/// word each.
fn spaced_out(text: &str, tokens: &[Token]) -> Vec<Token> {
    let single = |t: &Token| t.typed.chars().count() == 1;
    let mut out = Vec::new();
    let mut i = 0;
    while i < tokens.len() {
        if !single(&tokens[i]) {
            i += 1;
            continue;
        }
        let first = i;
        while i + 1 < tokens.len()
            && single(&tokens[i + 1])
            && text[tokens[i].end..tokens[i + 1].start].chars().count() <= 2
        {
            i += 1;
        }
        if i - first >= 2 {
            let joined: String = tokens[first..=i].iter().map(|t| t.typed.as_str()).collect();
            out.push(token(tokens[first].start, tokens[i].end, &joined));
        }
        i += 1;
    }
    out
}

fn compare(kind: Kind, word: &str, pattern: &str) -> bool {
    match kind {
        Kind::Exact => word == pattern,
        Kind::Prefix => word.starts_with(pattern),
        Kind::Suffix => word.ends_with(pattern),
        Kind::Anywhere => word.contains(pattern),
    }
}

impl Entry {
    fn parse(line: &str) -> Option<Self> {
        let starred = line.starts_with('*');
        let trailing = line.ends_with('*') && line.len() > 1;
        let body = line.trim_matches('*');
        if body.is_empty() {
            return None;
        }
        let kind = match (starred, trailing) {
            (true, true) => Kind::Anywhere,
            (true, false) => Kind::Suffix,
            (false, true) => Kind::Prefix,
            (false, false) => Kind::Exact,
        };
        let t = token(0, body.len(), body);
        let literal = !body.is_ascii();
        Some(Self {
            kind,
            literal,
            word: if literal { t.typed } else { t.folded },
            squashed: t.squashed,
        })
    }

    fn hits(&self, t: &Token) -> bool {
        if self.literal {
            return compare(self.kind, &t.typed, &self.word);
        }
        // Collapsed letters only for words long enough not to meet another
        // (`ass` is not `as`).
        compare(self.kind, &t.folded, &self.word)
            || (self.squashed.len() >= 4 && compare(self.kind, &t.squashed, &self.squashed))
    }

    /// For a name read as one run of letters.
    fn hits_text(&self, text: &str) -> bool {
        !self.literal && compare(self.kind, text, &self.word)
    }
}

impl Filter {
    fn from_text(lists: &[&str]) -> Self {
        let mut filter = Self {
            profanity: Vec::new(),
            reserved: Vec::new(),
        };
        for list in lists {
            let mut reserved = false;
            for line in list.lines() {
                let line = line.trim();
                if line.is_empty() || line.starts_with('#') {
                    continue;
                }
                match line {
                    "[profanity]" => reserved = false,
                    "[reserved]" => reserved = true,
                    _ => {
                        if let Some(entry) = Entry::parse(line) {
                            if reserved {
                                filter.reserved.push(entry);
                            } else {
                                filter.profanity.push(entry);
                            }
                        }
                    }
                }
            }
        }
        filter
    }

    /// `text` with every listed word replaced by asterisks (`None`: nothing
    /// to replace).
    #[must_use]
    pub fn mask(&self, text: &str) -> Option<String> {
        let tokens = words(text);
        let mut hits: Vec<(usize, usize)> = tokens
            .iter()
            .chain(spaced_out(text, &tokens).iter())
            .filter(|t| self.profanity.iter().any(|e| e.hits(t)))
            .map(|t| (t.start, t.end))
            .collect();
        if hits.is_empty() {
            return None;
        }
        hits.sort_unstable();
        let mut out = String::with_capacity(text.len());
        let mut at = 0;
        for (start, end) in hits {
            if start < at {
                // Inside a run already masked.
                if end > at {
                    out.extend(text[at..end].chars().map(|_| '*'));
                    at = end;
                }
                continue;
            }
            out.push_str(&text[at..start]);
            out.extend(text[start..end].chars().map(|_| '*'));
            at = end;
        }
        out.push_str(&text[at..]);
        Some(out)
    }

    /// Whether `name` (a character's or an account's) is refused: a reserved
    /// word, a look-alike of one, or a listed word.
    #[must_use]
    pub fn name_refused(&self, name: &str) -> bool {
        // Account names may use `_` and `-` between words.
        let spaced = name.replace('_', " ");
        let tokens = words(&spaced);
        let whole: String = tokens.iter().map(|t| t.folded.as_str()).collect();
        let whole_letters: String = tokens.iter().map(|t| t.letters.as_str()).collect();
        let whole_squashed = squash(&whole);
        let listed = |e: &Entry| {
            tokens.iter().any(|t| e.hits(t))
                || e.hits_text(&whole)
                || e.hits_text(&whole_letters)
                || (e.squashed.len() >= 4 && compare(e.kind, &whole_squashed, &e.squashed))
        };
        let by_letters =
            |e: &Entry| !e.literal && tokens.iter().any(|t| compare(e.kind, &t.letters, &e.word));
        self.reserved.iter().any(|e| listed(e) || by_letters(e))
            || self.profanity.iter().any(listed)
    }
}

/// The realm's filter: the built-in list and REALM_FILTER_EXTRA.
pub fn shared() -> &'static Filter {
    static FILTER: OnceLock<Filter> = OnceLock::new();
    FILTER.get_or_init(|| {
        let extra = std::env::var("REALM_FILTER_EXTRA")
            .ok()
            .and_then(|path| match std::fs::read_to_string(&path) {
                Ok(text) => Some(text),
                Err(e) => {
                    eprintln!("[filter] REALM_FILTER_EXTRA {path}: {e}");
                    None
                }
            })
            .unwrap_or_default();
        Filter::from_text(&[include_str!("words.txt"), &extra])
    })
}
