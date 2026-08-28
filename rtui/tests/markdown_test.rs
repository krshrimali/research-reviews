//! Unit tests for the light inline-markdown tokenizer used to render comment and
//! PR-description bodies GitHub-style.

use prtui::markdown::{spans, Md};

/// Collect only the spans of a given kind, as their text.
fn of_kind(line: &str, kind: Md) -> Vec<String> {
    spans(line)
        .into_iter()
        .filter(|(_, k)| *k == kind)
        .map(|(t, _)| t)
        .collect()
}

#[test]
fn plain_text_is_one_plain_span() {
    let s = spans("just some words");
    assert_eq!(s, vec![("just some words".to_string(), Md::Plain)]);
}

#[test]
fn bold_italic_and_code_are_tokenized() {
    assert_eq!(of_kind("a **bold** b", Md::Bold), vec!["bold"]);
    assert_eq!(of_kind("a *italic* b", Md::Italic), vec!["italic"]);
    assert_eq!(of_kind("use `code` here", Md::Code), vec!["code"]);
    // underscore italics too
    assert_eq!(of_kind("an _emph_ word", Md::Italic), vec!["emph"]);
}

#[test]
fn bold_is_not_mistaken_for_italic() {
    // "**x**" must be one Bold span, and produce no Italic spans.
    assert_eq!(of_kind("**x**", Md::Bold), vec!["x"]);
    assert!(of_kind("**x**", Md::Italic).is_empty());
}

#[test]
fn link_shows_text_not_url() {
    let s = spans("see [the docs](https://example.com/x) now");
    assert_eq!(
        of_kind("see [the docs](https://example.com/x) now", Md::Link),
        vec!["the docs"]
    );
    // the URL must not leak into any span's text
    assert!(!s.iter().any(|(t, _)| t.contains("example.com")));
}

#[test]
fn heading_and_bullet_prefixes() {
    assert_eq!(spans("## Title"), vec![("Title".to_string(), Md::Heading)]);
    let bullet = spans("- item one");
    assert_eq!(bullet[0].1, Md::Bullet);
    assert!(bullet[0].0.contains('•'));
    // bullet content is still inline-parsed
    assert_eq!(of_kind("- an **item**", Md::Bold), vec!["item"]);
}

#[test]
fn unterminated_marks_stay_literal() {
    // A lone '*' or backtick with no closer must not panic or eat the rest.
    assert_eq!(
        spans("2 * 3 = 6"),
        vec![("2 * 3 = 6".to_string(), Md::Plain)]
    );
    assert_eq!(spans("a `b c"), vec![("a `b c".to_string(), Md::Plain)]);
}
