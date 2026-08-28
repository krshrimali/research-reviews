//! A tiny, dependency-free syntax highlighter (offline: no syntect/tree-sitter). It's
//! deliberately approximate — tokenizes comments, strings, numbers and a broad keyword
//! set across common languages — enough to make diffs read in color like GitHub.

use std::cell::RefCell;
use std::collections::HashMap;

type CacheKey = (String, String);
type Tokens = Vec<(String, Tok)>;

thread_local! {
    static CACHE: RefCell<HashMap<CacheKey, Tokens>> = RefCell::new(HashMap::new());
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tok {
    Plain,
    Keyword,
    Str,
    Comment,
    Number,
}

/// Line-comment prefix(es) for a file extension.
fn comment_prefixes(ext: &str) -> &'static [&'static str] {
    match ext {
        "rs" | "c" | "cpp" | "cc" | "h" | "hpp" | "go" | "js" | "ts" | "tsx" | "jsx" | "java"
        | "kt" | "swift" | "scala" | "php" | "cs" => &["//"],
        "py" | "rb" | "sh" | "bash" | "zsh" | "yaml" | "yml" | "toml" | "conf" | "r" => &["#"],
        "lua" | "sql" | "hs" => &["--"],
        "vim" => &["\""],
        _ => &["//", "#"],
    }
}

const KEYWORDS: &[&str] = &[
    "if",
    "else",
    "elif",
    "for",
    "while",
    "loop",
    "return",
    "break",
    "continue",
    "match",
    "case",
    "switch",
    "default",
    "fn",
    "func",
    "function",
    "def",
    "let",
    "const",
    "var",
    "mut",
    "class",
    "struct",
    "enum",
    "impl",
    "trait",
    "interface",
    "type",
    "pub",
    "use",
    "mod",
    "import",
    "from",
    "export",
    "package",
    "new",
    "self",
    "this",
    "super",
    "true",
    "false",
    "null",
    "nil",
    "none",
    "None",
    "True",
    "False",
    "and",
    "or",
    "not",
    "in",
    "of",
    "is",
    "as",
    "async",
    "await",
    "try",
    "catch",
    "except",
    "finally",
    "raise",
    "throw",
    "with",
    "do",
    "then",
    "end",
    "local",
    "require",
    "static",
    "public",
    "private",
    "protected",
    "void",
    "int",
    "float",
    "bool",
    "string",
    "str",
    "unsafe",
    "where",
    "move",
];

/// Tokenize a single line into (text, kind) spans. Coalesces runs.
pub fn highlight(line: &str, ext: &str) -> Vec<(String, Tok)> {
    let key = (line.to_string(), ext.to_string());
    if let Some(hit) = CACHE.with(|cache| cache.borrow().get(&key).cloned()) {
        return hit;
    }
    let prefixes = comment_prefixes(ext);
    let chars: Vec<char> = line.chars().collect();
    let mut out: Vec<(String, Tok)> = Vec::new();
    let mut i = 0;

    let push = |out: &mut Vec<(String, Tok)>, s: &str, k: Tok| {
        if s.is_empty() {
            return;
        }
        if let Some(last) = out.last_mut() {
            if last.1 == k {
                last.0.push_str(s);
                return;
            }
        }
        out.push((s.to_string(), k));
    };

    while i < chars.len() {
        // Line comment?
        let rest: String = chars[i..].iter().collect();
        if let Some(p) = prefixes.iter().find(|p| rest.starts_with(**p)) {
            let _ = p;
            push(&mut out, &rest, Tok::Comment);
            break;
        }
        let c = chars[i];
        if c == '"' || c == '\'' || c == '`' {
            // string until the matching quote (handles \" escapes)
            let quote = c;
            let mut j = i + 1;
            let mut s = String::from(c);
            while j < chars.len() {
                s.push(chars[j]);
                if chars[j] == '\\' && j + 1 < chars.len() {
                    s.push(chars[j + 1]);
                    j += 2;
                    continue;
                }
                if chars[j] == quote {
                    j += 1;
                    break;
                }
                j += 1;
            }
            push(&mut out, &s, Tok::Str);
            i = j;
        } else if c.is_ascii_digit() {
            let mut j = i;
            let mut s = String::new();
            while j < chars.len()
                && (chars[j].is_ascii_alphanumeric() || chars[j] == '.' || chars[j] == '_')
            {
                s.push(chars[j]);
                j += 1;
            }
            push(&mut out, &s, Tok::Number);
            i = j;
        } else if c.is_ascii_alphabetic() || c == '_' {
            let mut j = i;
            let mut s = String::new();
            while j < chars.len() && (chars[j].is_ascii_alphanumeric() || chars[j] == '_') {
                s.push(chars[j]);
                j += 1;
            }
            let kind = if KEYWORDS.contains(&s.as_str()) {
                Tok::Keyword
            } else {
                Tok::Plain
            };
            push(&mut out, &s, kind);
            i = j;
        } else {
            push(&mut out, &c.to_string(), Tok::Plain);
            i += 1;
        }
    }
    CACHE.with(|cache| {
        let mut cache = cache.borrow_mut();
        if cache.len() >= 4096 {
            cache.clear();
        }
        cache.insert(key, out.clone());
    });
    out
}

/// Extract a lowercase file extension.
pub fn ext_of(path: &str) -> String {
    path.rsplit('.')
        .next()
        .filter(|e| *e != path)
        .unwrap_or("")
        .to_lowercase()
}
