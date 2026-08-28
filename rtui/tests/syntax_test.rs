//! Built-in syntax tokenizer.

use prtui::syntax::{ext_of, highlight, Tok};

fn kinds(spans: &[(String, Tok)]) -> Vec<Tok> {
    spans.iter().map(|(_, k)| *k).collect()
}

#[test]
fn tokenizes_rust_line() {
    let s = highlight("fn main() { let x = \"hi\"; } // done", "rs");
    let ks = kinds(&s);
    assert!(ks.contains(&Tok::Keyword), "fn/let are keywords");
    assert!(ks.contains(&Tok::Str), "string literal detected");
    assert!(ks.contains(&Tok::Comment), "trailing // comment detected");
    // the comment must include the // marker and reach end of line
    let comment = s.iter().find(|(_, k)| *k == Tok::Comment).unwrap();
    assert!(comment.0.contains("// done"));
}

#[test]
fn python_hash_comment_and_number() {
    let s = highlight("x = 42  # count", "py");
    let ks = kinds(&s);
    assert!(ks.contains(&Tok::Number), "42 is a number");
    assert!(ks.contains(&Tok::Comment), "# comment");
}

#[test]
fn ext_extraction() {
    assert_eq!(ext_of("src/auth.lua"), "lua");
    assert_eq!(ext_of("Makefile"), "");
    assert_eq!(ext_of("a/b/c.TS"), "ts");
}

#[test]
fn reassembles_the_line_exactly() {
    let line = "let v = foo(1, \"two\") // three";
    let joined: String = highlight(line, "rs").into_iter().map(|(t, _)| t).collect();
    assert_eq!(joined, line, "spans concatenate back to the original text");
}
