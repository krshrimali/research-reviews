//! A tiny inline-markdown tokenizer so comment/description bodies read like GitHub:
//! `**bold**`, `*italic*`/`_italic_`, `` `code` ``, `[text](url)`, plus heading/bullet
//! line prefixes. Not a full CommonMark parser — just the common inline marks.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Md {
    Plain,
    Bold,
    Italic,
    Code,
    Link,
    Heading,
    Bullet,
}

/// Tokenize one line into (text, kind) spans, honoring line-level prefixes.
pub fn spans(line: &str) -> Vec<(String, Md)> {
    // Line-level: heading / bullet.
    let trimmed = line.trim_start();
    if let Some(rest) = trimmed
        .strip_prefix("# ")
        .or_else(|| trimmed.strip_prefix("## "))
        .or_else(|| trimmed.strip_prefix("### "))
    {
        return vec![(rest.to_string(), Md::Heading)];
    }
    if trimmed.starts_with("- ") || trimmed.starts_with("* ") {
        let indent = &line[..line.len() - trimmed.len()];
        let mut out = vec![(format!("{indent}• "), Md::Bullet)];
        out.extend(inline(&trimmed[2..]));
        return out;
    }
    inline(line)
}

fn inline(s: &str) -> Vec<(String, Md)> {
    let chars: Vec<char> = s.chars().collect();
    let mut out: Vec<(String, Md)> = Vec::new();
    let mut i = 0;
    let mut plain = String::new();
    let flush = |plain: &mut String, out: &mut Vec<(String, Md)>| {
        if !plain.is_empty() {
            out.push((std::mem::take(plain), Md::Plain));
        }
    };
    while i < chars.len() {
        // inline code
        if chars[i] == '`' {
            if let Some(end) = find(&chars, i + 1, '`') {
                flush(&mut plain, &mut out);
                out.push((chars[i + 1..end].iter().collect(), Md::Code));
                i = end + 1;
                continue;
            }
        }
        // bold **...**
        if i + 1 < chars.len() && chars[i] == '*' && chars[i + 1] == '*' {
            if let Some(end) = find_seq(&chars, i + 2, &['*', '*']) {
                flush(&mut plain, &mut out);
                out.push((chars[i + 2..end].iter().collect(), Md::Bold));
                i = end + 2;
                continue;
            }
        }
        // italic *...* or _..._
        if (chars[i] == '*' || chars[i] == '_') && i + 1 < chars.len() && chars[i + 1] != ' ' {
            if let Some(end) = find(&chars, i + 1, chars[i]) {
                flush(&mut plain, &mut out);
                out.push((chars[i + 1..end].iter().collect(), Md::Italic));
                i = end + 1;
                continue;
            }
        }
        // link [text](url) -> show text as a link
        if chars[i] == '[' {
            if let Some(rb) = find(&chars, i + 1, ']') {
                if rb + 1 < chars.len() && chars[rb + 1] == '(' {
                    if let Some(rp) = find(&chars, rb + 2, ')') {
                        flush(&mut plain, &mut out);
                        out.push((chars[i + 1..rb].iter().collect(), Md::Link));
                        i = rp + 1;
                        continue;
                    }
                }
            }
        }
        plain.push(chars[i]);
        i += 1;
    }
    flush(&mut plain, &mut out);
    if out.is_empty() {
        out.push((String::new(), Md::Plain));
    }
    out
}

fn find(chars: &[char], from: usize, c: char) -> Option<usize> {
    (from..chars.len()).find(|&j| chars[j] == c)
}

fn find_seq(chars: &[char], from: usize, seq: &[char]) -> Option<usize> {
    let n = seq.len();
    (from..chars.len().saturating_sub(n - 1)).find(|&j| chars[j..j + n] == *seq)
}
