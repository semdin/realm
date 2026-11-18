//! The Terms of Service and the Privacy Policy, English and Turkish, built
//! into the service from `docs/legal/` and served to browsers and to the game:
//!
//!   GET /api/legal                  -> {version, support_url, documents}
//!   GET /api/legal/<doc>/<lang>     -> the page (doc: terms, privacy; lang: en, tr)
//!   GET /api/legal/<doc>/<lang>.json -> {success, version, title, text} (the game shows `text`)
//!
//! `VERSION` is what an account accepts. Changing it asks every player to
//! accept again at their next login, so it moves with the documents' own
//! "Version:" line and only when their meaning changes.

use serde_json::json;

pub const VERSION: &str = "2026-11-19";
pub const SUPPORT_URL: &str = "https://github.com/semdin/realm/issues";

struct Doc {
    kind: &'static str,
    lang: &'static str,
    text: &'static str,
}

const DOCS: [Doc; 4] = [
    Doc {
        kind: "terms",
        lang: "en",
        text: include_str!("../../../docs/legal/terms.en.md"),
    },
    Doc {
        kind: "terms",
        lang: "tr",
        text: include_str!("../../../docs/legal/terms.tr.md"),
    },
    Doc {
        kind: "privacy",
        lang: "en",
        text: include_str!("../../../docs/legal/privacy.en.md"),
    },
    Doc {
        kind: "privacy",
        lang: "tr",
        text: include_str!("../../../docs/legal/privacy.tr.md"),
    },
];

/// An answer that is ready to send.
pub struct Page {
    pub content_type: &'static str,
    pub body: Vec<u8>,
}

fn title_of(text: &str) -> &str {
    text.lines()
        .find_map(|l| l.strip_prefix("# "))
        .unwrap_or("Thousand Realms")
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// `**bold**` and bare https links, on text already escaped.
fn inline(text: &str) -> String {
    let mut out = String::new();
    for (i, part) in text.split("**").enumerate() {
        let linked = link_urls(part);
        if i % 2 == 1 {
            out.push_str("<strong>");
            out.push_str(&linked);
            out.push_str("</strong>");
        } else {
            out.push_str(&linked);
        }
    }
    out
}

fn link_urls(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(at) = rest.find("https://") {
        out.push_str(&rest[..at]);
        let tail = &rest[at..];
        let end = tail.find(char::is_whitespace).unwrap_or(tail.len());
        let url = tail[..end].trim_end_matches(['.', ',', ';', ')']);
        out.push_str(&format!(r#"<a href="{url}">{url}</a>"#));
        rest = &tail[url.len()..];
    }
    out.push_str(rest);
    out
}

fn body_html(text: &str) -> String {
    let mut out = String::new();
    let mut in_list = false;
    let mut paragraph: Vec<&str> = Vec::new();
    let flush = |paragraph: &mut Vec<&str>, out: &mut String| {
        if !paragraph.is_empty() {
            out.push_str(&format!(
                "<p>{}</p>\n",
                inline(&escape(&paragraph.join(" ")))
            ));
            paragraph.clear();
        }
    };
    for line in text.lines() {
        let line = line.trim_end();
        let item = line.strip_prefix("- ");
        if item.is_none() && in_list {
            out.push_str("</ul>\n");
            in_list = false;
        }
        if let Some(item) = item {
            flush(&mut paragraph, &mut out);
            if !in_list {
                out.push_str("<ul>\n");
                in_list = true;
            }
            out.push_str(&format!("<li>{}</li>\n", inline(&escape(item))));
        } else if let Some(h) = line.strip_prefix("## ") {
            flush(&mut paragraph, &mut out);
            out.push_str(&format!("<h2>{}</h2>\n", escape(h)));
        } else if let Some(h) = line.strip_prefix("# ") {
            flush(&mut paragraph, &mut out);
            out.push_str(&format!("<h1>{}</h1>\n", escape(h)));
        } else if line.is_empty() {
            flush(&mut paragraph, &mut out);
        } else {
            paragraph.push(line);
        }
    }
    flush(&mut paragraph, &mut out);
    if in_list {
        out.push_str("</ul>\n");
    }
    out
}

const STYLE: &str = "body{margin:0;background:#0d1622;color:#e2ddd1;font:17px/1.6 Georgia,serif}\
main{max-width:46rem;margin:0 auto;padding:2rem 1.25rem 4rem}\
h1{color:#ffedba;font-size:1.8rem;line-height:1.25}h2{color:#e8c87a;font-size:1.2rem;margin-top:2rem}\
a{color:#7fceeb}nav{font:15px sans-serif;margin-bottom:1.5rem}nav a{margin-right:1rem}";

fn page_html(doc: &Doc) -> String {
    let nav: String = DOCS
        .iter()
        .filter(|d| d.kind != doc.kind || d.lang != doc.lang)
        .map(|d| {
            format!(
                r#"<a href="/api/legal/{}/{}">{}</a>"#,
                d.kind,
                d.lang,
                escape(title_of(d.text))
            )
        })
        .collect();
    format!(
        "<!doctype html>\n<html lang=\"{}\"><head><meta charset=\"utf-8\">\
         <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\
         <title>{}</title><style>{STYLE}</style></head>\
         <body><main><nav>{nav}</nav>\n{}</main></body></html>\n",
        doc.lang,
        escape(title_of(doc.text)),
        body_html(doc.text)
    )
}

/// The answer for a path under /api/legal (None: there is no such page).
pub fn page(path: &str) -> Option<Page> {
    let rest = path.strip_prefix("/api/legal")?;
    if rest.is_empty() {
        let documents: Vec<_> = DOCS
            .iter()
            .map(|d| {
                json!({
                    "document": d.kind,
                    "language": d.lang,
                    "title": title_of(d.text),
                    "url": format!("/api/legal/{}/{}", d.kind, d.lang),
                })
            })
            .collect();
        let body = json!({
            "success": true,
            "version": VERSION,
            "support_url": SUPPORT_URL,
            "documents": documents,
        });
        return Some(Page {
            content_type: "application/json",
            body: body.to_string().into_bytes(),
        });
    }
    let mut parts = rest.strip_prefix('/')?.split('/');
    let (kind, lang) = (parts.next()?, parts.next()?);
    if parts.next().is_some() {
        return None;
    }
    let (lang, as_json) = match lang.strip_suffix(".json") {
        Some(l) => (l, true),
        None => (lang, false),
    };
    let doc = DOCS.iter().find(|d| d.kind == kind && d.lang == lang)?;
    Some(if as_json {
        let body = json!({
            "success": true,
            "version": VERSION,
            "title": title_of(doc.text),
            "text": doc.text,
            "url": format!("/api/legal/{}/{}", doc.kind, doc.lang),
        });
        Page {
            content_type: "application/json",
            body: body.to_string().into_bytes(),
        }
    } else {
        Page {
            content_type: "text/html; charset=utf-8",
            body: page_html(doc).into_bytes(),
        }
    })
}
